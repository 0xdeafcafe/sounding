import Accelerate
import Foundation

enum LabClip: String, CaseIterable, Sendable {
    case handshake = "Handshake"
    case beep = "Beep"
    case ping = "Ping"
    case success = "Success"
    case sequence = "Whole Sequence"
}

struct LabPreset: Identifiable, Hashable {
    let name: String
    let design: ChimeDesign

    var id: String { name }

    static func == (lhs: LabPreset, rhs: LabPreset) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    static var bassOnly: ChimeDesign {
        var design = ChimeDesign(style: .slide)
        design.voice.enabled = false
        design.bed.lowpass = 340
        design.bed.levelDB = 0
        return design
    }

    static let all: [LabPreset] = [
        LabPreset(name: "Omen, pulse only", design: ChimeSynth.Handshake.pulse.design),
        LabPreset(name: "Omen, code on replay", design: ChimeSynth.Handshake.coded.design),
        LabPreset(name: "Omen: one throbbing pulse", design: ChimeDesign(style: .omen)),
        LabPreset(name: "Abyss: one sliding sub", design: ChimeDesign(style: .abyss)),
        LabPreset(name: "Grit: one grainy pulse", design: ChimeDesign(style: .grit)),
        LabPreset(name: "Slide", design: ChimeDesign(style: .slide)),
        LabPreset(name: "Pulse", design: ChimeDesign(style: .pulse)),
        LabPreset(name: "Click", design: ChimeDesign(style: .click)),
        LabPreset(name: "Eclipse", design: ChimeDesign(style: .eclipse)),
        LabPreset(name: "Ripple", design: ChimeDesign(style: .ripple)),
        LabPreset(name: "Bass only, data in ultrasonic", design: bassOnly),
    ]
}

struct LabChannel: Identifiable, Sendable {
    let name: String
    let apply: @Sendable ([Float], inout SeededGenerator) -> (signal: [Float], sampleRate: Double)

    var id: String { name }

    static let quick: [LabChannel] = [
        LabChannel(name: "Clean") { x, _ in (x, 48_000) },
        LabChannel(name: "Tiny speaker, 4 kHz") { x, rng in
            (Channel.noise(Channel.reverb(Channel.lowpass(x, cutoff: 4_000, stages: 4), rt60: 0.5, wet: 0.8), snr: 10, rng: &rng), 48_000)
        },
        LabChannel(name: "TV speaker, cut above 15 kHz") { x, rng in
            (Channel.whiteNoise(Channel.reverb(Channel.lowpass(x, cutoff: 15_000, stages: 4), rt60: 0.4, wet: 0.6), dBFS: -70, rng: &rng), 48_000)
        },
        LabChannel(name: "Phone mic at 4 m, quiet room") { x, rng in phone(x, rng: &rng, snr: nil) },
        LabChannel(name: "Phone mic at 4 m, noisy room") { x, rng in phone(x, rng: &rng, snr: 8) },
        LabChannel(name: "Music as loud as the chime") { x, rng in (Channel.withMusic(x, relativeLevel: 1, rng: &rng), 48_000) },
    ]

    static func phone(_ x: [Float], rng: inout SeededGenerator, snr: Float?) -> (signal: [Float], sampleRate: Double) {
        let room = Channel.reverb(Channel.drift(x, factor: 48_000.0 / 44_100.0), rt60: 0.6, wet: 0.8).map { $0 * 0.0316 }
        if let snr { return (Channel.noise(room, snr: snr, rng: &rng), 44_100) }
        return (Channel.whiteNoise(room, dBFS: -80, rng: &rng), 44_100)
    }
}

struct LabCheckRow: Identifiable, Sendable {
    let channel: String
    let notes: Int?
    let carrier: Int?
    let either: Int
    let trials: Int
    let wrong: Int

    var id: String { channel }
}

enum Lab {
    static let sampleRate = 48_000.0
    static let handshakeLead = 0.5
    static let pingRest = 1.4
    static let carrierTail = 3.0

    static func previewCode() -> ChimeCode {
        ChimeCode.random() ?? ChimeCode(bytes: [UInt8](repeating: 0x5A, count: ChimeCode.byteCount))!
    }

    static func carrier(_ code: ChimeCode, design: ChimeDesign, seconds: Double) -> ChimeStereo {
        var output = ChimeStereo(seconds: seconds, sampleRate: sampleRate)
        guard design.carrierLevel > 0 else { return output }
        let tone = CarrierOscillator.render(code, sampleRate: sampleRate, seconds: seconds, level: design.carrierLevel)
        output.left = tone
        output.right = tone
        return output
    }

    static func render(_ clip: LabClip, design: ChimeDesign, code: ChimeCode) -> ChimeStereo {
        switch clip {
        case .handshake:
            let handshake = ChimeSynth.renderHandshake(code, design: design, sampleRate: sampleRate)
            var output = carrier(code, design: design, seconds: Double(handshake.count) / sampleRate + 0.4)
            output.mix(handshake, gain: 1, sampleRate: sampleRate)
            return output
        case .beep:
            return design.beep.render(.beep, sampleRate: sampleRate)
        case .ping:
            return design.ping.render(.ping, sampleRate: sampleRate)
        case .success:
            return design.success.render(.success, sampleRate: sampleRate)
        case .sequence:
            var cue = design.beep.render(.beep, sampleRate: sampleRate)
            let lead = max(0, Int(handshakeLead * sampleRate) - cue.count)
            cue.append(ChimeStereo(seconds: Double(lead) / sampleRate, sampleRate: sampleRate))
            cue.append(ChimeSynth.renderHandshake(code, design: design, sampleRate: sampleRate))
            cue.append(ChimeStereo(seconds: pingRest, sampleRate: sampleRate))
            let ping = design.ping.render(.ping, sampleRate: sampleRate)
            for _ in 0..<ChimeSynth.audiblePings { cue.append(ping) }
            cue.append(ChimeStereo(seconds: carrierTail, sampleRate: sampleRate))
            let carrierSeconds = Double(cue.count) / sampleRate
            cue.append(design.success.render(.success, sampleRate: sampleRate))
            var output = carrier(code, design: design, seconds: carrierSeconds)
            output.append(ChimeStereo(seconds: Double(cue.count - output.count) / sampleRate, sampleRate: sampleRate))
            output.mix(cue, gain: 1, sampleRate: sampleRate)
            return output
        }
    }

    static func listeningMix(_ code: ChimeCode, design: ChimeDesign) -> [Float] {
        let handshake = ChimeSynth.renderHandshake(code, design: design, sampleRate: sampleRate).mono
        let seconds = max(ChimeLayer.carrier.frameDuration * 2 + 0.8, Double(handshake.count) / sampleRate + 1.3)
        var mix = design.carrierLevel > 0
            ? CarrierOscillator.render(code, sampleRate: sampleRate, seconds: seconds, level: design.carrierLevel)
            : [Float](repeating: 0, count: Int(seconds * sampleRate))
        let offset = Int(0.7 * sampleRate)
        for (n, sample) in handshake.enumerated() where n + offset < mix.count { mix[n + offset] += sample }
        return mix
    }

    static func check(_ design: ChimeDesign, channels: [LabChannel] = LabChannel.quick, trials: Int = 16, seed: UInt64 = 1) -> [LabCheckRow] {
        let layer = design.layer.layer
        let wantsNotes = design.audibleData
        let wantsCarrier = design.carrierLevel > 0
        return channels.enumerated().map { channelIndex, channel in
            let results = UnsafeMutableBufferPointer<(Bool, Bool, Bool)>.allocate(capacity: trials)
            defer { results.deallocate() }
            DispatchQueue.concurrentPerform(iterations: trials) { trial in
                var rng = SeededGenerator(state: seed &+ UInt64(channelIndex * 1_000 + trial) &* 7_919)
                let code = rng.code()
                let heard = channel.apply(listeningMix(code, design: design), &rng)
                var layers: [ChimeLayer] = []
                if wantsNotes { layers.append(layer) }
                if wantsCarrier { layers.append(.carrier) }
                let decoder = ChimeDecoder(sampleRate: heard.sampleRate, layers: layers)
                var detections: [ChimeDecoder.Detection] = []
                var index = 0
                while index < heard.signal.count {
                    let end = min(heard.signal.count, index + 4096)
                    detections += decoder.process(Array(heard.signal[index..<end]))
                    index = end
                }
                let notes = detections.contains { $0.layer == .audible && $0.code == code }
                let carrier = detections.contains { $0.layer == .carrier && $0.code == code }
                let wrong = detections.contains { $0.code != code }
                results[trial] = (notes, carrier, wrong)
            }
            let all = Array(results)
            return LabCheckRow(
                channel: channel.name,
                notes: wantsNotes ? all.filter(\.0).count : nil,
                carrier: wantsCarrier ? all.filter(\.1).count : nil,
                either: all.filter { $0.0 || $0.1 }.count,
                trials: trials,
                wrong: all.filter(\.2).count
            )
        }
    }

    static func spectrum(_ stereo: ChimeStereo, points: Int = 160) -> [(frequency: Double, level: Double)] {
        let size = 8192
        let x = stereo.mono
        guard x.count >= size else { return [] }
        let log2n = vDSP_Length(13)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        var power = [Double](repeating: 0, count: size / 2)
        var real = [Float](repeating: 0, count: size / 2)
        var imaginary = [Float](repeating: 0, count: size / 2)
        var frames = 0
        var start = 0
        while start + size <= x.count {
            let windowed = vDSP.multiply(Array(x[start..<(start + size)]), window)
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    windowed.withUnsafeBufferPointer { w in
                        w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            for bin in 1..<(size / 2) { power[bin] += Double(real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) }
            frames += 1
            start += size / 2
        }
        let binHz = sampleRate / Double(size)
        let low = log10(20.0)
        let high = log10(23_000.0)
        let reference = Double(size) * Double(size) / 4
        return (0..<points).map { index in
            let a = pow(10, low + (high - low) * Double(index) / Double(points))
            let b = pow(10, low + (high - low) * Double(index + 1) / Double(points))
            let first = max(1, Int(a / binHz))
            let last = max(first, min(size / 2 - 1, Int(b / binHz)))
            let peak = (first...last).map { power[$0] }.max() ?? 0
            let level = 10 * log10(max(peak / Double(max(frames, 1)) / reference, 1e-12))
            return ((a * b).squareRoot(), max(-100, level))
        }
    }

    static func wav(_ stereo: ChimeStereo) -> Data {
        var data = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        data.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + stereo.count * 4))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        data.append(contentsOf: Array("data".utf8))
        u32(UInt32(stereo.count * 4))
        for n in 0..<stereo.count {
            for sample in [stereo.left[n], stereo.right[n]] {
                u16(UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32_767)))
            }
        }
        return data
    }

    static func json(_ design: ChimeDesign) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(design)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
