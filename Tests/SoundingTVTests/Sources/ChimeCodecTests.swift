import XCTest
@testable import SoundingTV

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func gaussian() -> Float {
        let u1 = Double.random(in: 1e-12..<1, using: &self)
        let u2 = Double.random(in: 0..<1, using: &self)
        return Float(sqrt(-2 * log(u1)) * cos(2 * Double.pi * u2))
    }

    mutating func code() -> ChimeCode {
        ChimeCode(bytes: (0..<ChimeCode.byteCount).map { _ in UInt8.random(in: 0...255, using: &self) })!
    }
}

private enum Channel {
    static let sampleRate = 48_000.0

    static func rms(_ x: [Float]) -> Float {
        sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count)))
    }

    static func padded(_ x: [Float], before: Double = 0.7, after: Double = 0.6) -> [Float] {
        [Float](repeating: 0, count: Int(before * sampleRate)) + x + [Float](repeating: 0, count: Int(after * sampleRate))
    }

    static func carrierSeconds(_ layer: ChimeLayer = .carrier) -> Double {
        layer.frameDuration * 2 + 0.8
    }

    static func chime(_ code: ChimeCode, style: ChimeSynth.Style = ChimeSynth.shipping) -> [Float] {
        padded(ChimeSynth.renderAudible(code, sampleRate: sampleRate, style: style))
    }

    static func noise(_ x: [Float], snr: Float, rng: inout SeededGenerator) -> [Float] {
        let level = rms(x.filter { abs($0) > 1e-6 }) / pow(10, snr / 20)
        return x.map { $0 + level * rng.gaussian() }
    }

    static func whiteNoise(_ x: [Float], dBFS: Float, rng: inout SeededGenerator) -> [Float] {
        let level = pow(10, dBFS / 20)
        return x.map { $0 + level * rng.gaussian() }
    }

    static func drift(_ x: [Float], factor: Double) -> [Float] {
        let count = Int(Double(x.count) / factor)
        return (0..<count).map { i in
            let position = Double(i) * factor
            let j = Int(position)
            let fraction = Float(position - Double(j))
            guard j + 1 < x.count else { return 0 }
            return x[j] * (1 - fraction) + x[j + 1] * fraction
        }
    }

    static func reverb(_ x: [Float], rt60: Double, wet: Float) -> [Float] {
        let input = x + [Float](repeating: 0, count: Int(rt60 * sampleRate))
        var y = input
        for (delay, gain) in [(0.011, Float(0.5)), (0.023, 0.35), (0.041, 0.25)] {
            let offset = Int(delay * sampleRate)
            for n in 0..<(input.count - offset) { y[n + offset] += gain * input[n] }
        }
        var diffuse = [Float](repeating: 0, count: input.count)
        for delay in [0.0297, 0.0371, 0.0411, 0.0437] {
            let length = Int(delay * sampleRate)
            let feedback = Float(pow(10, -3 * delay / rt60))
            var comb = [Float](repeating: 0, count: input.count)
            for n in input.indices {
                comb[n] = input[n] + (n >= length ? feedback * comb[n - length] : 0)
                diffuse[n] += comb[n] * 0.25
            }
        }
        for delay in [0.005, 0.0017] {
            let length = Int(delay * sampleRate)
            var output = [Float](repeating: 0, count: diffuse.count)
            for n in diffuse.indices {
                let delayedIn = n >= length ? diffuse[n - length] : 0
                let delayedOut = n >= length ? output[n - length] : 0
                output[n] = -0.7 * diffuse[n] + delayedIn + 0.7 * delayedOut
            }
            diffuse = output
        }
        let scale = wet * rms(x) / max(rms(diffuse), 1e-9)
        return zip(y, diffuse).map { $0 + $1 * scale }
    }

    static func music(count: Int, level: Float, rng: inout SeededGenerator) -> [Float] {
        var y = [Float](repeating: 0, count: count)
        let scale: [Double] = [261.63, 293.66, 329.63, 349.23, 392.0, 440.0, 493.88, 523.25, 587.33, 659.25,
                               698.46, 783.99, 880.0, 987.77, 1046.5, 1174.66, 1318.51, 1567.98]
        var start = 0
        while start < count {
            let frequency = scale.randomElement(using: &rng)!
            let duration = [0.125, 0.25, 0.25, 0.5].randomElement(using: &rng)!
            let length = min(Int(duration * 1.5 * sampleRate), count - start)
            for n in 0..<max(0, length) {
                let t = Double(n) / sampleRate
                let envelope = Float(exp(-t / (duration * 0.6)) * min(1, t / 0.005))
                var sample: Float = 0
                for harmonic in 1...6 {
                    sample += Float(sin(2 * Double.pi * frequency * Double(harmonic) * t)) / Float(harmonic * harmonic) * 1.4
                }
                y[start + n] += envelope * sample
            }
            if Double.random(in: 0..<1, using: &rng) < 0.5 {
                for n in 0..<max(0, min(Int(0.06 * sampleRate), count - start)) {
                    y[start + n] += 0.6 * rng.gaussian() * Float(exp(-Double(n) / (0.015 * sampleRate)))
                }
            }
            for n in 0..<max(0, min(Int(duration * sampleRate), count - start)) {
                y[start + n] += 0.5 * Float(sin(2 * Double.pi * scale[0] / 2 * Double(n) / sampleRate))
            }
            start += Int(duration * sampleRate)
        }
        let current = rms(y)
        return y.map { $0 * level / max(current, 1e-9) }
    }

    static func withMusic(_ x: [Float], relativeLevel: Float, rng: inout SeededGenerator) -> [Float] {
        let interference = music(count: x.count, level: rms(x) * relativeLevel, rng: &rng)
        return zip(x, interference).map { $0 + $1 }
    }

    static func lowpass(_ x: [Float], cutoff: Double, stages: Int) -> [Float] {
        var y = x
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * 0.7071)
        let b0 = (1 - cos(w0)) / 2, b1 = 1 - cos(w0), b2 = (1 - cos(w0)) / 2
        let a0 = 1 + alpha, a1 = -2 * cos(w0), a2 = 1 - alpha
        for _ in 0..<stages {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for n in y.indices {
                let xn = Double(y[n])
                let yn = (b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
                x2 = x1; x1 = xn; y2 = y1; y1 = yn
                y[n] = Float(yn)
            }
        }
        return y
    }

    static func toneLoss(_ frequency: Double, cutoff: Double, stages: Int) -> Float {
        let probe = (0..<Int(0.5 * sampleRate)).map { Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
        let filtered = lowpass(probe, cutoff: cutoff, stages: stages)
        let settled = Int(0.25 * sampleRate)
        return 20 * log10(rms(Array(filtered[settled...])) / rms(Array(probe[settled...])))
    }

    static func decode(_ signal: [Float], layer: ChimeLayer, sampleRate: Double = sampleRate) -> [ChimeDecoder.Detection] {
        let decoder = ChimeDecoder(sampleRate: sampleRate, layers: [layer])
        var detections: [ChimeDecoder.Detection] = []
        var index = 0
        while index < signal.count {
            let end = min(signal.count, index + 4096)
            detections += decoder.process(Array(signal[index..<end]))
            index = end
        }
        return detections
    }

    static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8))
        u32(UInt32(samples.count * 2))
        for sample in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32767))) }
        return data
    }
}

final class ChimeCodecTests: XCTestCase {
    private struct Outcome {
        var trials = 0
        var decoded = 0
        var wrong = 0
        var errorRate: Double { Double(trials - decoded) / Double(max(1, trials)) }
    }

    private var report: [String] = []

    override func tearDown() {
        if !report.isEmpty { print(report.joined(separator: "\n")) }
        super.tearDown()
    }

    private func measure(
        _ name: String,
        trials: Int,
        layer: ChimeLayer,
        seed: UInt64,
        maximumErrorRate: Double,
        make: (ChimeCode, inout SeededGenerator) -> [Float]
    ) {
        var rng = SeededGenerator(state: seed)
        var outcome = Outcome()
        for _ in 0..<trials {
            let code = rng.code()
            let detections = Channel.decode(make(code, &rng), layer: layer)
            outcome.trials += 1
            if detections.contains(where: { $0.code == code }) { outcome.decoded += 1 }
            if detections.contains(where: { $0.code != code }) { outcome.wrong += 1 }
        }
        report.append(String(format: "[chime] %@: %d/%d decoded, %d wrong, error rate %.1f%%", name, outcome.decoded, outcome.trials, outcome.wrong, outcome.errorRate * 100))
        XCTAssertLessThanOrEqual(outcome.errorRate, maximumErrorRate, name)
        XCTAssertEqual(outcome.wrong, 0, "\(name) produced a wrong code")
    }

    private final class Work: @unchecked Sendable {
        let body: () -> Void

        init(_ body: @escaping () -> Void) {
            self.body = body
        }
    }

    private func offMain(_ body: @escaping () -> Void) {
        let work = Work(body)
        let done = expectation(description: "decode")
        DispatchQueue.global(qos: .userInitiated).async {
            work.body()
            done.fulfill()
        }
        wait(for: [done], timeout: 3_600)
    }

    // MARK: - Robustness

    func testAudibleChimeRoundTripsThroughImpairments() {
        offMain { self.audibleChimeRoundTripsThroughImpairments() }
    }

    func testEveryStyleSurvivesDriftAndEcho() {
        offMain { self.everyStyleSurvivesDriftAndEcho() }
    }

    func testAudibleChimeDecodesAt44kHz() {
        offMain { self.audibleChimeDecodesAt44kHz() }
    }

    func testListeningDecoderHearsTheShippingAndOlderChime() {
        offMain {
            var rng = SeededGenerator(state: 50)
            for style in Set([ChimeSynth.shipping.decodeStyle, .eclipse, .ripple, .bell]) {
                for _ in 0..<4 {
                    let code = rng.code()
                    let heard = Channel.reverb(Channel.chime(code, style: style), rt60: 0.5, wet: 0.8)
                    let decoder = ChimeDecoder(sampleRate: Channel.sampleRate)
                    let detections = decoder.process(heard)
                    XCTAssertTrue(detections.contains { $0.code == code }, style.rawValue)
                    XCTAssertFalse(detections.contains { $0.code != code }, style.rawValue)
                }
            }
        }
    }

    func testCarrierRoundTripsThroughSpeakerRollOffAndRoomNoise() {
        offMain { self.carrierRoundTripsThroughSpeakerRollOffAndRoomNoise() }
    }

    func testCarrierBandMargin() {
        offMain { self.carrierBandMargin() }
    }

    func testMusicAndNoiseDoNotProduceCodes() {
        offMain { self.musicAndNoiseDoNotProduceCodes() }
    }

    // MARK: - Frame

    func testReedSolomonCorrectsUpToHalfItsParity() {
        var rng = SeededGenerator(state: 1)
        for (field, parity, length) in [(GaloisField.gf16, 4, 12), (.gf64, 8, ChimeFrame.codewordSymbols)] {
            let code = ReedSolomon(field: field, parityCount: parity)
            for _ in 0..<400 {
                let message = (0..<(length - parity)).map { _ in UInt8.random(in: 0...UInt8(field.order), using: &rng) }
                let codeword = code.encode(message)
                XCTAssertEqual(code.decode(codeword)?.corrections, 0)
                var damaged = codeword
                let positions = Array((0..<length).shuffled(using: &rng).prefix(Int.random(in: 1...(parity / 2), using: &rng)))
                for position in positions { damaged[position] ^= UInt8.random(in: 1...UInt8(field.order), using: &rng) }
                let decoded = code.decode(damaged)
                XCTAssertEqual(decoded?.codeword, codeword)
                XCTAssertEqual(decoded?.corrections, positions.count)
            }
        }
    }

    func testFrameCarries128BitsAndRejectsCorruption() {
        var rng = SeededGenerator(state: 2)
        var accepted = 0
        XCTAssertEqual(ChimeFrame.messageSymbols * ChimeFrame.symbolBits, 128 + ChimeFrame.checkBits)
        for _ in 0..<2_000 {
            let code = rng.code()
            let symbols = ChimeFrame.symbols(for: code)
            XCTAssertEqual(symbols.count, ChimeFrame.codewordSymbols)
            XCTAssertEqual(ChimeFrame.decode(symbols)?.code, code)
            for layer in ChimeSynth.Style.allCases.map(\.layer) + [.carrier] {
                let steps = layer.steps(for: code)
                let decisions = steps.indices.dropFirst(layer.preamble.count).map { index in
                    steps[index].enumerated().map { layer.voices(at: index)[$0.offset].firstIndex(of: $0.element)! }
                }
                XCTAssertEqual(layer.symbols(fromDecisions: decisions), symbols)
            }
            let garbage = (0..<ChimeFrame.codewordSymbols).map { _ in UInt8.random(in: 0...63, using: &rng) }
            if let decoded = ChimeFrame.decode(garbage), decoded.corrections <= ChimeLayerDetector.confidentChanges { accepted += 1 }
        }
        report.append("[chime] random 30-symbol words accepted by RS + check: \(accepted)/2000")
        XCTAssertLessThan(accepted, 3, "random symbol strings should almost never pass RS + check")
    }

    func testFrameLengths() {
        let audible = ChimeLayer.audible
        let carrier = ChimeLayer.carrier
        report.append(String(format: "[chime] audible frame %d steps = %.2f s, clip %.2f s; carrier loop %d symbols = %.2f s",
                             audible.frameStepCount, audible.frameDuration, ChimeSynth.audibleDuration(),
                             carrier.frameStepCount, carrier.frameDuration))
        XCTAssertLessThanOrEqual(carrier.frameDuration, 6)
        XCTAssertTrue(carrier.tones.allSatisfy { $0 >= 18_000 && $0 <= 19_600 })
        for style in ChimeSynth.Style.allCases {
            XCTAssertLessThanOrEqual(ChimeSynth.audibleDuration(style: style), 4, style.rawValue)
            let success = ChimeSynth.renderSuccess(style: style, sampleRate: Channel.sampleRate)
            XCTAssertLessThanOrEqual(Double(success.count) / Channel.sampleRate, style.isBass ? ChimeSynth.bassSuccessDuration : style.isDark ? ChimeSynth.darkSuccessDuration : 1, style.rawValue)
            XCTAssertLessThanOrEqual(success.peak, ChimeSynth.successLevel + 0.001, style.rawValue)
            let ping = ChimeSynth.renderPing(style: style, sampleRate: Channel.sampleRate)
            XCTAssertLessThanOrEqual(ping.peak, 0.1, style.rawValue)
            XCTAssertGreaterThanOrEqual(style.pingPeriod, 2.5, style.rawValue)
        }
    }

    // MARK: - Audible chime

    private func audibleChimeRoundTripsThroughImpairments() {
        let trials = 24
        measure("audible clean", trials: trials, layer: .audible, seed: 10, maximumErrorRate: 0) { code, _ in Channel.chime(code) }
        measure("audible white noise 0 dB SNR", trials: trials, layer: .audible, seed: 11, maximumErrorRate: 0.05) { code, rng in
            Channel.noise(Channel.chime(code), snr: 0, rng: &rng)
        }
        measure("audible music-like interference at -6 dB", trials: trials, layer: .audible, seed: 12, maximumErrorRate: 0.05) { code, rng in
            Channel.withMusic(Channel.chime(code), relativeLevel: 0.5, rng: &rng)
        }
        measure("audible music-like interference as loud as the whole chime, bass included", trials: trials, layer: .audible, seed: 13, maximumErrorRate: 0.3) { code, rng in
            Channel.withMusic(Channel.chime(code), relativeLevel: 1, rng: &rng)
        }
        measure("audible speed and pitch +2%", trials: trials, layer: .audible, seed: 14, maximumErrorRate: 0.05) { code, _ in
            Channel.drift(Channel.chime(code), factor: 1.02)
        }
        measure("audible speed and pitch -2%", trials: trials, layer: .audible, seed: 15, maximumErrorRate: 0.05) { code, _ in
            Channel.drift(Channel.chime(code), factor: 0.98)
        }
        measure("audible room echo RT60 0.8 s, reverb louder than the chime", trials: trials, layer: .audible, seed: 23, maximumErrorRate: 0.1) { code, _ in
            Channel.reverb(Channel.chime(code), rt60: 0.8, wet: 1.2)
        }
        measure("audible room echo RT60 0.5 s", trials: trials, layer: .audible, seed: 16, maximumErrorRate: 0.05) { code, _ in
            Channel.reverb(Channel.chime(code), rt60: 0.5, wet: 0.8)
        }
        measure("audible level -40 dB with noise at 6 dB SNR", trials: trials, layer: .audible, seed: 17, maximumErrorRate: 0.05) { code, rng in
            Channel.noise(Channel.chime(code).map { $0 * 0.01 }, snr: 6, rng: &rng)
        }
        measure("audible everything: +1.5% drift, echo, music, noise, -26 dB", trials: trials, layer: .audible, seed: 18, maximumErrorRate: 0.15) { code, rng in
            let echoed = Channel.reverb(Channel.drift(Channel.chime(code), factor: 1.015), rt60: 0.5, wet: 0.8)
            return Channel.noise(Channel.withMusic(echoed, relativeLevel: 0.4, rng: &rng).map { $0 * 0.05 }, snr: 10, rng: &rng)
        }
        measure("audible small speaker: 4th-order 5 kHz roll-off, 10 dB SNR", trials: trials, layer: .audible, seed: 24, maximumErrorRate: 0.05) { code, rng in
            Channel.noise(Channel.lowpass(Channel.chime(code), cutoff: 5_000, stages: 2), snr: 10, rng: &rng)
        }
        measure("audible tiny speaker: 8th-order 4 kHz roll-off, echo, 10 dB SNR", trials: trials, layer: .audible, seed: 25, maximumErrorRate: 0.15) { code, rng in
            Channel.noise(Channel.reverb(Channel.lowpass(Channel.chime(code), cutoff: 4_000, stages: 4), rt60: 0.5, wet: 0.8), snr: 10, rng: &rng)
        }
    }

    private func everyStyleSurvivesDriftAndEcho() {
        for style in ChimeSynth.Style.allCases {
            measure("style \(style.rawValue): -2% drift, RT60 0.5 s echo, 6 dB SNR", trials: 12, layer: style.layer, seed: 70, maximumErrorRate: 0.1) { code, rng in
                Channel.noise(Channel.reverb(Channel.drift(Channel.chime(code, style: style), factor: 0.98), rt60: 0.5, wet: 0.8), snr: 6, rng: &rng)
            }
        }
    }

    private func audibleChimeDecodesAt44kHz() {
        var rng = SeededGenerator(state: 19)
        for _ in 0..<6 {
            let code = rng.code()
            let resampled = Channel.drift(Channel.chime(code), factor: 48_000.0 / 44_100.0)
            XCTAssertTrue(Channel.decode(resampled, layer: .audible, sampleRate: 44_100).contains { $0.code == code })
        }
    }

    // MARK: - Ultrasonic carrier

    private func carrierRoundTripsThroughSpeakerRollOffAndRoomNoise() {
        let trials = 16
        measure("carrier clean", trials: trials, layer: .carrier, seed: 20, maximumErrorRate: 0) { code, _ in
            CarrierOscillator.render(code, sampleRate: Channel.sampleRate, seconds: Channel.carrierSeconds())
        }
        measure("carrier 4th-order 16 kHz roll-off, room noise and music", trials: trials, layer: .carrier, seed: 21, maximumErrorRate: 0.05) { code, rng in
            let carrier = Channel.lowpass(CarrierOscillator.render(code, sampleRate: Channel.sampleRate, seconds: Channel.carrierSeconds()), cutoff: 16_000, stages: 2)
            let room = Channel.music(count: carrier.count, level: 0.1, rng: &rng)
            return Channel.whiteNoise(zip(carrier, room).map { $0 + $1 }, dBFS: -70, rng: &rng)
        }
        measure("carrier ±0.3% clock drift and echo", trials: trials, layer: .carrier, seed: 22, maximumErrorRate: 0.05) { code, rng in
            let drifted = Channel.drift(CarrierOscillator.render(code, sampleRate: Channel.sampleRate, seconds: Channel.carrierSeconds()), factor: 1.003)
            return Channel.whiteNoise(Channel.reverb(drifted, rt60: 0.3, wet: 0.5), dBFS: -80, rng: &rng)
        }
        measure("carrier 4th-order 16 kHz roll-off, white noise at -45 dBFS", trials: trials, layer: .carrier, seed: 26, maximumErrorRate: 0.05) { code, rng in
            let carrier = Channel.lowpass(CarrierOscillator.render(code, sampleRate: Channel.sampleRate, seconds: Channel.carrierSeconds()), cutoff: 16_000, stages: 2)
            return Channel.whiteNoise(carrier, dBFS: -45, rng: &rng)
        }
        measure("carrier level -20 dB, white noise at -60 dBFS, echo", trials: trials, layer: .carrier, seed: 27, maximumErrorRate: 0.1) { code, rng in
            let quiet = CarrierOscillator.render(code, sampleRate: Channel.sampleRate, seconds: Channel.carrierSeconds()).map { $0 * 0.1 }
            return Channel.whiteNoise(Channel.reverb(quiet, rt60: 0.5, wet: 0.8), dBFS: -60, rng: &rng)
        }
    }

    private func carrierBandMargin() {
        let speakers: [(String, Double, Int)] = [("flat", 0, 0), ("4th-order 16 kHz", 16_000, 2), ("8th-order 15 kHz", 15_000, 4)]
        let bands: [(String, ChimeLayer)] = [
            ("18.0–19.2 kHz", .carrier(lowestTone: 18_000)),
            ("18.2–19.4 kHz (shipping)", .carrier),
            ("18.6–19.8 kHz", .carrier(lowestTone: 18_600)),
        ]
        let carrierRMS = 20 * log10(ChimeSynth.carrierLevel / sqrt(2))
        let pathGain: Float = -28
        let micFloor: Float = -80
        var rng = SeededGenerator(state: 30)
        var shippingMildMargin: Float = -.infinity
        for (bandName, layer) in bands {
            for (speakerName, cutoff, stages) in speakers {
                let losses = layer.tones.map { stages == 0 ? Float(0) : Channel.toneLoss($0, cutoff: cutoff, stages: stages) }
                var threshold: Float = -100
                for noise in stride(from: Float(-20), through: -100, by: -5) {
                    var decoded = 0
                    for _ in 0..<6 {
                        let code = rng.code()
                        var signal = CarrierOscillator.render(code, sampleRate: Channel.sampleRate, seconds: Channel.carrierSeconds(layer), layer: layer)
                        if stages > 0 { signal = Channel.lowpass(signal, cutoff: cutoff, stages: stages) }
                        if Channel.decode(Channel.whiteNoise(signal, dBFS: noise, rng: &rng), layer: layer).contains(where: { $0.code == code }) {
                            decoded += 1
                        }
                    }
                    if decoded >= 5 {
                        threshold = noise
                        break
                    }
                }
                let margin = threshold + pathGain - micFloor
                if layer.tones == ChimeLayer.carrier.tones, stages == 2 { shippingMildMargin = margin }
                report.append(String(
                    format: "[carrier] %@, %@: tone loss %@ dB; decodes with white noise up to %.0f dBFS; modelled margin %.0f dB (carrier %.0f dBFS RMS, path %.0f dB, mic floor %.0f dBFS)",
                    bandName, speakerName, losses.map { String(format: "%.0f", $0) }.joined(separator: "/"),
                    threshold, margin, carrierRMS, pathGain, micFloor
                ))
            }
        }
        XCTAssertGreaterThan(shippingMildMargin, 6)
    }

    // MARK: - Waiting

    func testWaitingPingsAtMostTwiceThenOnlyTheCarrierKeepsRunning() {
        let sampleRate = Channel.sampleRate
        var rng = SeededGenerator(state: 80)
        let code = rng.code()
        let ping = ChimeSynth.renderPing(sampleRate: sampleRate)
        let rest = Int(ChimePlayer.pingRestSeconds * sampleRate)
        let fade = Float(1 / (ChimePlayer.fadeSeconds * sampleRate))
        let frames = rest + ping.count * (ChimeSynth.audiblePings + 4)
        func run(pinging: Bool) -> (output: [Float], state: ChimePlayer.RenderState) {
            var render = ChimePlayer.RenderState()
            render.carrier = CarrierOscillator(code: code, sampleRate: sampleRate)
            render.carrierWanted = true
            render.ping = ping
            render.pingPosition = -rest
            render.pingWanted = pinging
            let output = (0..<frames).map { _ in ChimePlayer.nextFrame(&render, fadeStep: fade, pingRest: rest).0 }
            return (output, render)
        }
        let carrierOnly = run(pinging: false).output
        let (heard, state) = run(pinging: true)
        let periods = stride(from: rest, to: frames, by: ping.count).map { start in
            (start..<min(frames, start + ping.count)).contains { abs(heard[$0] - carrierOnly[$0]) > 1e-6 }
        }
        XCTAssertLessThanOrEqual(ChimeSynth.audiblePings, 2)
        XCTAssertEqual(periods.filter { $0 }.count, ChimeSynth.audiblePings)
        XCTAssertEqual(Array(periods.prefix(ChimeSynth.audiblePings)), Array(repeating: true, count: ChimeSynth.audiblePings))
        XCTAssertFalse(state.pingWanted)
        XCTAssertEqual(state.pingsLeft, 0)
        XCTAssertTrue(state.carrierWanted)
        let tail = Array(heard.suffix(Int(ChimeLayer.carrier.frameDuration * 2 + 1) * Int(sampleRate)))
        XCTAssertEqual(Channel.rms(tail), ChimeSynth.carrierLevel / sqrt(2), accuracy: 0.003)
        XCTAssertTrue(Channel.decode(tail, layer: .carrier).contains { $0.code == code })
        report.append(String(format: "[chime] waiting: %d audible pings in %.1f s, then the carrier alone", periods.filter { $0 }.count, Double(frames) / sampleRate))
    }

    // MARK: - False detections

    private func musicAndNoiseDoNotProduceCodes() {
        var rng = SeededGenerator(state: 40)
        var detections = 0
        for _ in 0..<4 {
            let music = Channel.music(count: Int(20 * Channel.sampleRate), level: 0.2, rng: &rng)
            let signal = Channel.whiteNoise(music, dBFS: -50, rng: &rng)
            detections += Channel.decode(signal, layer: .audible).count + Channel.decode(signal, layer: .carrier).count
        }
        report.append("[chime] false detections in 80 s of music-like audio: \(detections)")
        XCTAssertEqual(detections, 0)
        for style in ChimeSynth.Style.allCases {
            let cues = ChimeSynth.renderSearching(style: style, sampleRate: Channel.sampleRate, seconds: 10).mono
                + ChimeSynth.renderSuccess(style: style, sampleRate: Channel.sampleRate).mono
            let heard = Channel.whiteNoise(Channel.padded(cues), dBFS: -70, rng: &rng)
            XCTAssertTrue(Channel.decode(heard, layer: style.layer).isEmpty, "\(style.rawValue) searching or success cue decoded as a code")
        }
    }

    // MARK: - Renders

    func testRendersListenableFiles() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHIME_WAV_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let code = ChimeCode(bytes: Array(0..<16).map { UInt8(truncatingIfNeeded: $0 * 17 + 3) })!
        for style in ChimeSynth.Style.allCases {
            let chime = ChimeSynth.renderAudible(code, sampleRate: Channel.sampleRate, style: style)
            try Channel.wav(chime, sampleRate: 48_000).write(to: directory.appendingPathComponent("chime-\(style.rawValue).wav"))
            XCTAssertTrue(Channel.decode(Channel.padded(chime), layer: style.layer).contains { $0.code == code })
            XCTAssertLessThanOrEqual(chime.map(abs).max() ?? 0, 0.81)
            XCTAssertFalse(chime.contains { !$0.isFinite })
            let success = ChimeSynth.renderSuccess(style: style, sampleRate: Channel.sampleRate).mono
            try Channel.wav(success, sampleRate: 48_000).write(to: directory.appendingPathComponent("chime-\(style.rawValue)-success.wav"))
            let searching = ChimeSynth.renderSearching(style: style, sampleRate: Channel.sampleRate, seconds: 10).mono
            try Channel.wav(searching, sampleRate: 48_000).write(to: directory.appendingPathComponent("chime-\(style.rawValue)-searching.wav"))
        }
        let carrier = CarrierOscillator.render(code, sampleRate: Channel.sampleRate, seconds: 12)
        try Channel.wav(carrier, sampleRate: 48_000).write(to: directory.appendingPathComponent("sounding-carrier.wav"))
        report.append("[chime] wrote chime-<style>.wav, -success.wav, -searching.wav and sounding-carrier.wav to \(directory.path)")
        XCTAssertTrue(Channel.decode(carrier, layer: .carrier).contains { $0.code == code })
    }

    func testDesignsReproduceTheShippedStylesExactly() throws {
        let code = ChimeCode(bytes: Array(0..<16).map { UInt8(truncatingIfNeeded: $0 * 29 + 5) })!
        for style in [ChimeSynth.Style.omen, .abyss, .grit, .slide, .pulse, .click, .eclipse, .ripple] {
            let design = ChimeDesign(style: style)
            let decoded = try JSONDecoder().decode(ChimeDesign.self, from: JSONEncoder().encode(design))
            XCTAssertEqual(decoded, design, style.rawValue)
            for sampleRate in [48_000.0, 44_100.0] {
                let shipped = ChimeSynth.renderAudibleStereo(code, sampleRate: sampleRate, style: style)
                let designed = ChimeSynth.renderHandshake(code, design: decoded, sampleRate: sampleRate)
                XCTAssertEqual(shipped.left, designed.left, style.rawValue)
                XCTAssertEqual(shipped.right, designed.right, style.rawValue)
            }
        }
    }

    func testCarrierAloneCarriesTheCodeWhenTheDataNotesAreOff() {
        var design = ChimeDesign(style: .slide)
        design.voice.enabled = false
        let code = ChimeCode(bytes: Array(0..<16).map { UInt8(truncatingIfNeeded: $0 * 7 + 1) })!
        let handshake = ChimeSynth.renderHandshake(code, design: design, sampleRate: Channel.sampleRate).mono
        XCTAssertTrue(Channel.decode(Channel.padded(handshake), layer: .audible).isEmpty)
        var mix = CarrierOscillator.render(code, sampleRate: Channel.sampleRate, seconds: Channel.carrierSeconds(), level: design.carrierLevel)
        for (n, sample) in handshake.enumerated() { mix[n + 24_000] += sample }
        XCTAssertTrue(Channel.decode(mix, layer: .carrier).contains { $0.code == code })
    }

    // MARK: - Pulse

    func testPulseDataSpreadsEveryChoiceAcrossTheBandInsteadOfNotes() {
        let layer = ChimeLayer.veil
        XCTAssertTrue(ChimeSynth.shipping.isVeiled)
        XCTAssertEqual(ChimeSynth.shipping.layer.bands, layer.bands)
        XCTAssertGreaterThanOrEqual(layer.lowestFrequency, 300)
        XCTAssertLessThanOrEqual(layer.highestFrequency, 4_000)
        XCTAssertLessThanOrEqual(layer.frameDuration, 3.5)
        for index in 0..<layer.voicePattern.count {
            let choices = layer.voices(at: index).flatMap { $0 }.map { layer.bands[$0] }
            XCTAssertEqual(Set(choices.flatMap { $0 }).count, choices.count * choices[0].count, "slots overlap in pattern \(index)")
            for band in choices {
                XCTAssertGreaterThanOrEqual(band.max()! / band.min()!, 2.4, "a choice should span well over an octave")
            }
        }
    }

    func testPulseDecodesWithoutTheCarrierThroughSmallSpeakersAndTheOlderLayoutsStillDecode() {
        offMain {
            var rng = SeededGenerator(state: 90)
            for style in [ChimeSynth.Style.omen, .abyss, .grit] {
                for _ in 0..<3 {
                    let code = rng.code()
                    let clip = Channel.chime(code, style: style)
                    let twelve = Channel.whiteNoise(Channel.reverb(Channel.lowpass(clip, cutoff: 12_000, stages: 4), rt60: 0.4, wet: 0.6), dBFS: -70, rng: &rng)
                    let tiny = Channel.noise(Channel.reverb(Channel.lowpass(clip, cutoff: 4_000, stages: 4), rt60: 0.5, wet: 0.8), snr: 10, rng: &rng)
                    for heard in [twelve, tiny] {
                        let detections = ChimeDecoder(sampleRate: Channel.sampleRate).process(heard)
                        XCTAssertTrue(detections.contains { $0.code == code && $0.layer == .audible }, style.rawValue)
                        XCTAssertFalse(detections.contains { $0.code != code }, style.rawValue)
                    }
                }
            }
            let code = rng.code()
            let slide = Channel.drift(Channel.chime(code, style: .slide), factor: 48_000.0 / 44_100.0)
            XCTAssertTrue(ChimeDecoder(sampleRate: 44_100).process(slide).contains { $0.code == code })
        }
    }

    // MARK: - Pulse alone

    private static func veilBandPower(_ x: [Float]) -> Double {
        ChimeLayer.veil.bands.flatMap { $0 }.reduce(0) { total, centre in
            let coefficient = 2 * cos(2 * Double.pi * centre / Channel.sampleRate)
            var s1 = 0.0, s2 = 0.0
            for sample in x {
                let s = Double(sample) + coefficient * s1 - s2
                s2 = s1
                s1 = s
            }
            return total + (s1 * s1 + s2 * s2 - coefficient * s1 * s2) / Double(x.count * x.count)
        }
    }

    func testDefaultHandshakeHasNoCodeTextureBeyondThePulseAlone() {
        let code = ChimeCode(bytes: Array(0..<16).map { UInt8(truncatingIfNeeded: $0 * 41 + 9) })!
        var pulseAlone = ChimeDesign(style: .omen)
        pulseAlone.voice.enabled = false
        let reference = Self.veilBandPower(ChimeSynth.renderHandshake(code, design: pulseAlone, sampleRate: Channel.sampleRate).mono)
        let heard = Self.veilBandPower(ChimeSynth.renderHandshake(code, .pulse, sampleRate: Channel.sampleRate).mono)
        let coded = Self.veilBandPower(ChimeSynth.renderHandshake(code, .coded, sampleRate: Channel.sampleRate).mono)
        XCTAssertFalse(ChimeSynth.Handshake.pulse.design.audibleData)
        XCTAssertLessThanOrEqual(heard, reference * 1.05)
        XCTAssertGreaterThan(coded, reference * 4)
        report.append(String(format: "[chime] veil band: pulse alone %.1f dB, default %+.1f dB, fallback %+.1f dB",
                             10 * log10(reference), 10 * log10(heard / reference), 10 * log10(coded / reference)))
    }

    func testDefaultHandshakeDecodesThroughTheCarrier() {
        offMain {
            var rng = SeededGenerator(state: 120)
            for _ in 0..<3 {
                let code = rng.code()
                let handshake = ChimeSynth.renderHandshake(code, .pulse, sampleRate: Channel.sampleRate).mono
                var mix = CarrierOscillator.render(code, sampleRate: Channel.sampleRate, seconds: Channel.carrierSeconds() + 1,
                                                   level: ChimeSynth.Handshake.pulse.design.carrierLevel)
                for (n, sample) in handshake.enumerated() { mix[n + 24_000] += sample }
                let heard = Channel.whiteNoise(Channel.reverb(Channel.lowpass(mix, cutoff: 16_000, stages: 2), rt60: 0.4, wet: 0.6), dBFS: -70, rng: &rng)
                let detections = ChimeDecoder(sampleRate: Channel.sampleRate).process(heard)
                XCTAssertTrue(detections.contains { $0.code == code && $0.layer == .carrier })
                XCTAssertFalse(detections.contains { $0.layer == .audible })
                XCTAssertFalse(detections.contains { $0.code != code })
            }
        }
    }

    func testFallbackDecodesThroughA12kHzTVAndATinySpeaker() {
        offMain {
            var rng = SeededGenerator(state: 130)
            XCTAssertTrue(ChimeSynth.Handshake.coded.design.voice.followsPulse)
            for _ in 0..<3 {
                let code = rng.code()
                let clip = Channel.padded(ChimeSynth.renderHandshake(code, .coded, sampleRate: Channel.sampleRate).mono)
                let twelve = Channel.whiteNoise(Channel.reverb(Channel.lowpass(clip, cutoff: 12_000, stages: 4), rt60: 0.4, wet: 0.6), dBFS: -70, rng: &rng)
                let tiny = Channel.noise(Channel.reverb(Channel.lowpass(clip, cutoff: 4_000, stages: 4), rt60: 0.5, wet: 0.8), snr: 10, rng: &rng)
                for heard in [twelve, tiny] {
                    let detections = ChimeDecoder(sampleRate: Channel.sampleRate).process(heard)
                    XCTAssertTrue(detections.contains { $0.code == code && $0.layer == .audible })
                    XCTAssertFalse(detections.contains { $0.code != code })
                }
            }
        }
    }

    func testReplayUsesTheFallbackAfterTheTimeoutAndOnPlaySound() {
        XCTAssertEqual(ChimeReplay.handshake(for: .opening), .pulse)
        XCTAssertEqual(ChimeReplay.handshake(for: .playSound), .coded)
        XCTAssertEqual(ChimeReplay.handshake(for: .automatic), .coded)
        XCTAssertEqual(ChimeReplay.carrierGain(for: .opening), 1)
        XCTAssertEqual(ChimeReplay.carrierGain(for: .playSound), 2, accuracy: 0.01)
        XCTAssertLessThanOrEqual(ChimeReplay.automaticDelay, 20)

        var replay = ChimeReplay()
        XCTAssertFalse(replay.automaticIsDue(at: 100))
        replay.opened(at: 10)
        XCTAssertFalse(replay.automaticIsDue(at: 10 + ChimeReplay.automaticDelay - 0.1))
        XCTAssertTrue(replay.automaticIsDue(at: 10 + ChimeReplay.automaticDelay))
        XCTAssertFalse(replay.automaticIsDue(at: 60))

        var found = ChimeReplay()
        found.opened(at: 0)
        found.phoneFound()
        XCTAssertFalse(found.automaticIsDue(at: 60))

        var pressed = ChimeReplay()
        pressed.opened(at: 0)
        pressed.replayed()
        XCTAssertFalse(pressed.automaticIsDue(at: 60))

        let sampleRate = Channel.sampleRate
        let code = ChimeCode(bytes: Array(0..<16).map { UInt8(truncatingIfNeeded: $0 * 13 + 2) })!
        let fade = Float(1 / (ChimePlayer.fadeSeconds * sampleRate))
        var render = ChimePlayer.RenderState()
        render.carrier = CarrierOscillator(code: code, sampleRate: sampleRate)
        render.carrierWanted = true
        render.pingsLeft = 0
        render.carrierBoostTarget = ChimeReplay.carrierGain(for: .automatic)
        render.carrierBoostHold = Int(2 * sampleRate)
        let output = (0..<Int(4 * sampleRate)).map { _ in ChimePlayer.nextFrame(&render, fadeStep: fade, pingRest: 0).0 }
        let boosted = Channel.rms(Array(output[Int(1 * sampleRate)..<Int(1.9 * sampleRate)]))
        let settled = Channel.rms(Array(output[Int(3 * sampleRate)...]))
        XCTAssertEqual(boosted / settled, 2, accuracy: 0.1)
        XCTAssertEqual(settled, ChimeSynth.carrierLevel / sqrt(2), accuracy: 0.003)
    }

    // MARK: - Wire

    func testChimeMessagesRoundTripOnTheWire() throws {
        let message = TokenTransferMessage.chime(.chimeHello, sessionId: "0F1E2D3C", payload: ChimeLinkPayload(version: 2, nonceBase64: "bm9uY2U="))
        var framer = MessageFramer()
        framer.append(try message.framed())
        let decoded = try XCTUnwrap(try framer.next())
        XCTAssertEqual(decoded.type, .chimeHello)
        XCTAssertEqual(decoded.chime?.version, 2)
        XCTAssertEqual(decoded.chime?.nonceBase64, "bm9uY2U=")
        XCTAssertNil(decoded.chime?.sealedBase64)
    }
}
