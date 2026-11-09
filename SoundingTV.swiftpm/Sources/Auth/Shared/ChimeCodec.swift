import Foundation
import Accelerate
import Security

struct ChimeCode: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let byteCount = 16

    let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    static func random() -> ChimeCode? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else { return nil }
        return ChimeCode(bytes: bytes)
    }

    var description: String { "ChimeCode(redacted)" }
    var debugDescription: String { description }
}

// MARK: - Reed–Solomon

struct GaloisField: Sendable {
    let bits: Int
    let size: Int
    let order: Int
    private let exponents: [UInt8]
    private let logarithms: [Int]

    init(bits: Int, primitive: Int) {
        self.bits = bits
        size = 1 << bits
        order = size - 1
        var exponents = [UInt8](repeating: 0, count: 2 * order)
        var logarithms = [Int](repeating: 0, count: size)
        var x = 1
        for i in 0..<order {
            exponents[i] = UInt8(x)
            exponents[i + order] = UInt8(x)
            logarithms[x] = i
            x <<= 1
            if x & size != 0 { x ^= primitive }
        }
        self.exponents = exponents
        self.logarithms = logarithms
    }

    static let gf16 = GaloisField(bits: 4, primitive: 0x13)
    static let gf64 = GaloisField(bits: 6, primitive: 0x43)

    func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        guard a != 0, b != 0 else { return 0 }
        return exponents[logarithms[Int(a)] + logarithms[Int(b)]]
    }

    func inverse(_ a: UInt8) -> UInt8 {
        exponents[(order - logarithms[Int(a)]) % order]
    }

    func alpha(_ power: Int) -> UInt8 {
        exponents[((power % order) + order) % order]
    }

    func power(_ x: UInt8, _ n: Int) -> UInt8 {
        var result: UInt8 = 1
        for _ in 0..<n { result = multiply(result, x) }
        return result
    }
}

struct ReedSolomon: Sendable {
    let field: GaloisField
    let parityCount: Int
    private let generator: [UInt8]

    init(field: GaloisField, parityCount: Int) {
        self.field = field
        self.parityCount = parityCount
        var polynomial: [UInt8] = [1]
        for i in 1...parityCount {
            var next = [UInt8](repeating: 0, count: polynomial.count + 1)
            for (j, coefficient) in polynomial.enumerated() {
                next[j] ^= coefficient
                next[j + 1] ^= field.multiply(coefficient, field.alpha(i))
            }
            polynomial = next
        }
        generator = polynomial
    }

    private var mask: UInt8 { UInt8(field.order) }

    private func evaluateHighFirst(_ polynomial: [UInt8], at x: UInt8) -> UInt8 {
        polynomial.reduce(0) { field.multiply($0, x) ^ $1 }
    }

    private func evaluateLowFirst(_ polynomial: [UInt8], at x: UInt8) -> UInt8 {
        polynomial.reversed().reduce(0) { field.multiply($0, x) ^ $1 }
    }

    func encode(_ message: [UInt8]) -> [UInt8] {
        var remainder = [UInt8](repeating: 0, count: parityCount)
        for symbol in message {
            let feedback = (symbol & mask) ^ remainder[0]
            remainder.removeFirst()
            remainder.append(0)
            guard feedback != 0 else { continue }
            for j in 0..<parityCount {
                remainder[j] ^= field.multiply(generator[j + 1], feedback)
            }
        }
        return message.map { $0 & mask } + remainder
    }

    func decode(_ received: [UInt8]) -> (codeword: [UInt8], corrections: Int)? {
        let n = received.count
        guard n > parityCount, n <= field.order, received.allSatisfy({ Int($0) < field.size }) else { return nil }

        let syndromes = (1...parityCount).map { evaluateHighFirst(received, at: field.alpha($0)) }
        guard syndromes.contains(where: { $0 != 0 }) else { return (received, 0) }

        var locator: [UInt8] = [1]
        var previous: [UInt8] = [1]
        var length = 0
        var shift = 1
        var previousDiscrepancy: UInt8 = 1
        for k in 0..<parityCount {
            var discrepancy = syndromes[k]
            if length > 0 {
                for i in 1...length where i < locator.count {
                    discrepancy ^= field.multiply(locator[i], syndromes[k - i])
                }
            }
            guard discrepancy != 0 else {
                shift += 1
                continue
            }
            let factor = field.multiply(discrepancy, field.inverse(previousDiscrepancy))
            var adjusted = locator
            if adjusted.count < previous.count + shift {
                adjusted += [UInt8](repeating: 0, count: previous.count + shift - adjusted.count)
            }
            for (i, coefficient) in previous.enumerated() {
                adjusted[i + shift] ^= field.multiply(factor, coefficient)
            }
            if 2 * length <= k {
                previous = locator
                length = k + 1 - length
                previousDiscrepancy = discrepancy
                shift = 1
            } else {
                shift += 1
            }
            locator = adjusted
        }
        while locator.count > 1, locator.last == 0 { locator.removeLast() }
        let degree = locator.count - 1
        guard degree == length, degree <= parityCount / 2 else { return nil }

        let positions = (0..<n).filter { evaluateLowFirst(locator, at: field.alpha(-(n - 1 - $0))) == 0 }
        guard positions.count == degree else { return nil }

        var evaluator = [UInt8](repeating: 0, count: parityCount)
        for i in 0..<parityCount {
            for j in 0...i where j < locator.count {
                evaluator[i] ^= field.multiply(locator[j], syndromes[i - j])
            }
        }

        var corrected = received
        for index in positions {
            let inverseLocation = field.alpha(-(n - 1 - index))
            var derivative: UInt8 = 0
            var k = 1
            while k < locator.count {
                derivative ^= field.multiply(locator[k], field.power(inverseLocation, k - 1))
                k += 2
            }
            guard derivative != 0 else { return nil }
            corrected[index] ^= field.multiply(evaluateLowFirst(evaluator, at: inverseLocation), field.inverse(derivative))
        }

        guard (1...parityCount).allSatisfy({ evaluateHighFirst(corrected, at: field.alpha($0)) == 0 }) else { return nil }
        return (corrected, positions.count)
    }
}

// MARK: - Frame

enum ChimeFrame {
    static let symbolBits = 6
    static let checkBits = 4
    static let messageSymbols = (ChimeCode.byteCount * 8 + checkBits) / symbolBits
    static let reedSolomon = ReedSolomon(field: .gf64, parityCount: 7)
    static var codewordSymbols: Int { messageSymbols + reedSolomon.parityCount }

    private static let whitening: [UInt8] = {
        var state: UInt32 = 0x2F6B_1C35
        return (0..<63).map { _ in
            state = state &* 1_103_515_245 &+ 12_345
            return UInt8(truncatingIfNeeded: state >> 16) & 0x3F
        }
    }()

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0x5A
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }

    private static func check(_ bytes: [UInt8]) -> UInt8 {
        crc8(bytes) >> 4
    }

    static func symbols(for code: ChimeCode) -> [UInt8] {
        var bits = code.bytes.flatMap { byte in (0..<8).reversed().map { (byte >> UInt8($0)) & 1 } }
        let tag = check(code.bytes)
        bits += (0..<checkBits).reversed().map { (tag >> UInt8($0)) & 1 }
        let message = stride(from: 0, to: bits.count, by: symbolBits).map { start in
            bits[start..<(start + symbolBits)].reduce(UInt8(0)) { $0 << 1 | $1 }
        }
        return zip(reedSolomon.encode(message), whitening).map { $0 ^ $1 }
    }

    static func decode(_ symbols: [UInt8]) -> (code: ChimeCode, corrections: Int)? {
        guard symbols.count == codewordSymbols else { return nil }
        let codeword = zip(symbols, whitening).map { ($0 ^ $1) & 0x3F }
        guard let (corrected, corrections) = reedSolomon.decode(codeword) else { return nil }
        let bits = corrected.prefix(messageSymbols).flatMap { symbol in
            (0..<symbolBits).reversed().map { (symbol >> UInt8($0)) & 1 }
        }
        let bytes = stride(from: 0, to: ChimeCode.byteCount * 8, by: 8).map { start in
            bits[start..<(start + 8)].reduce(UInt8(0)) { $0 << 1 | $1 }
        }
        let tag = bits[(ChimeCode.byteCount * 8)...].reduce(UInt8(0)) { $0 << 1 | $1 }
        guard tag == check(bytes), let code = ChimeCode(bytes: bytes) else { return nil }
        return (code, corrections)
    }
}

// MARK: - Layers

struct ChimeLayer: Sendable {
    enum Kind: String, Sendable {
        case audible
        case carrier
    }

    let kind: Kind
    let tones: [Double]
    let voicePattern: [[[Int]]]
    let preamble: [[Int]]
    var symbolDuration: Double
    let pooling: Double
    let timeScales: [Double]
    let samplePoint: Double
    let normalisesTones: Bool
    let fftSize: Int
    let minimumPreambleRatio: Float
    let tailSuppression: Float
    var bands: [[Double]] = []
    var bandHalfWidth: Double = 0
    var slotWidth: Double = 0.1
    var bandCompression: Float = 1

    var isSpread: Bool { !bands.isEmpty }
    var lowestFrequency: Double { isSpread ? (bands.joined().min() ?? 0) - bandHalfWidth : tones.min() ?? 0 }
    var highestFrequency: Double { isSpread ? (bands.joined().max() ?? 0) + bandHalfWidth : tones.max() ?? 0 }

    func voices(at step: Int) -> [[Int]] { voicePattern[step % voicePattern.count] }
    var voiceCount: Int { voicePattern[0].count }
    var voiceBits: [Int] { voicePattern[0].map { Int(log2(Double($0.count)).rounded()) } }
    var bitsPerStep: Int { voiceBits.reduce(0, +) }
    var dataBits: Int { ChimeFrame.codewordSymbols * ChimeFrame.symbolBits }
    var dataStepCount: Int { (dataBits + bitsPerStep - 1) / bitsPerStep }
    var frameStepCount: Int { preamble.count + dataStepCount }
    var frameDuration: Double { Double(frameStepCount) * symbolDuration }

    func steps(for code: ChimeCode) -> [[Int]] {
        var bits = ChimeFrame.symbols(for: code).flatMap { symbol in
            (0..<ChimeFrame.symbolBits).reversed().map { Int((symbol >> UInt8($0)) & 1) }
        }
        bits += [Int](repeating: 0, count: dataStepCount * bitsPerStep - bits.count)
        var data: [[Int]] = []
        var cursor = 0
        for index in 0..<dataStepCount {
            let sets = voices(at: preamble.count + index)
            var step: [Int] = []
            for (voice, width) in voiceBits.enumerated() {
                let choice = bits[cursor..<(cursor + width)].reduce(0) { $0 << 1 | $1 }
                step.append(sets[voice][choice])
                cursor += width
            }
            data.append(step)
        }
        return preamble + data
    }

    func symbols(fromDecisions decisions: [[Int]]) -> [UInt8] {
        var bits: [UInt8] = []
        for step in decisions {
            for (voice, width) in voiceBits.enumerated() {
                bits += (0..<width).reversed().map { UInt8((step[voice] >> $0) & 1) }
            }
        }
        let usable = min(bits.count, dataBits)
        return stride(from: 0, to: usable - ChimeFrame.symbolBits + 1, by: ChimeFrame.symbolBits).map { start in
            bits[start..<(start + ChimeFrame.symbolBits)].reduce(UInt8(0)) { $0 << 1 | $1 }
        }
    }

    static let pentatonic: [Double] = [
        783.99, 880.00, 1046.50, 1174.66, 1318.51, 1567.98, 1760.00, 2093.00,
        2349.32, 2637.02, 3135.96, 3520.00, 4186.01, 4698.64, 5274.04, 6271.93,
    ]

    static func pentatonic(fromMIDI root: Int, count: Int) -> [Double] {
        scale(fromMIDI: root, degrees: [0, 2, 4, 7, 9], count: count)
    }

    static func scale(fromMIDI root: Int, degrees: [Int], count: Int) -> [Double] {
        (0..<count).map { 440 * pow(2, Double(root + 12 * ($0 / degrees.count) + degrees[$0 % degrees.count] - 69) / 12) }
    }

    private static let audibleScales = stride(from: 0.97, through: 1.0301, by: 0.005).map { $0 }

    static let bell = ChimeLayer(
        kind: .audible,
        tones: pentatonic,
        voicePattern: [[Array(0..<8), Array(8..<16)]],
        preamble: [[2, 10], [4, 12]],
        symbolDuration: 60.0 / 128 / 4,
        pooling: 0.03,
        timeScales: audibleScales,
        samplePoint: 0.45,
        normalisesTones: false,
        fftSize: 2048,
        minimumPreambleRatio: 1.6,
        tailSuppression: 0.45
    )

    static let bloom = ChimeLayer(
        kind: .audible,
        tones: pentatonic,
        voicePattern: [[[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11], [12, 13, 14, 15]]],
        preamble: [[2, 4, 10, 12], [3, 6, 9, 15]],
        symbolDuration: 0.15,
        pooling: 0.03,
        timeScales: audibleScales,
        samplePoint: 0.5,
        normalisesTones: false,
        fftSize: 2048,
        minimumPreambleRatio: 1.6,
        tailSuppression: 0.5
    )

    static let ripple = ChimeLayer(
        kind: .audible,
        tones: pentatonic(fromMIDI: 72, count: 18),
        voicePattern: (0..<4).map { [Array((2 * $0)..<(2 * $0 + 4)), Array((2 * $0 + 8)..<(2 * $0 + 12))] },
        preamble: [[0, 8], [4, 12], [7, 15], [9, 17]],
        symbolDuration: 0.075,
        pooling: 0.03,
        timeScales: audibleScales,
        samplePoint: 0.5,
        normalisesTones: false,
        fftSize: 2048,
        minimumPreambleRatio: 1.6,
        tailSuppression: 0.4
    )

    static let descent = ChimeLayer(
        kind: .audible,
        tones: scale(fromMIDI: 69, degrees: [0, 3, 5, 7, 10], count: 18),
        voicePattern: (0..<4).reversed().map { [Array((2 * $0)..<(2 * $0 + 4)), Array((2 * $0 + 8)..<(2 * $0 + 12))] },
        preamble: [[8, 15], [6, 13], [5, 11], [0, 10]],
        symbolDuration: 0.075,
        pooling: 0.03,
        timeScales: audibleScales,
        samplePoint: 0.5,
        normalisesTones: false,
        fftSize: 2048,
        minimumPreambleRatio: 1.6,
        tailSuppression: 0.4
    )

    static let eclipse = ChimeLayer(
        kind: .audible,
        tones: scale(fromMIDI: 69, degrees: [0, 3, 6, 9], count: 12),
        voicePattern: [[[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]]],
        preamble: [[0, 4, 8], [2, 6, 10]],
        symbolDuration: 0.116,
        pooling: 0.03,
        timeScales: audibleScales,
        samplePoint: 0.5,
        normalisesTones: false,
        fftSize: 2048,
        minimumPreambleRatio: 1.6,
        tailSuppression: 0.45
    )

    static let veil = spread(lowest: 380, spacing: 55, symbolDuration: 0.14)

    static func spread(lowest: Double, spacing: Double, symbolDuration: Double, groups: Int = 4, states: Int = 4, perState: Int = 4,
                       patterns: Int = 8, seed: UInt64 = 0x5EED_0F0E) -> ChimeLayer {
        let count = groups * states * perState
        let centres = (0..<count).map { lowest + spacing * Double($0) }
        var state = seed
        func random(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        func shuffled(_ values: [Int]) -> [Int] {
            var values = values
            for i in stride(from: values.count - 1, to: 0, by: -1) { values.swapAt(i, random(i + 1)) }
            return values
        }
        var bands: [[Double]] = []
        var pattern: [[[Int]]] = []
        for _ in 0..<patterns {
            var voices: [[Int]] = []
            for group in 0..<groups {
                let members = Array(stride(from: group, to: count, by: groups))
                let tiers = (0..<perState).map { tier in shuffled(Array(members[(tier * states)..<((tier + 1) * states)])) }
                var choices: [Int] = []
                for choice in 0..<states {
                    choices.append(bands.count)
                    bands.append(tiers.map { centres[$0[choice]] })
                }
                voices.append(choices)
            }
            pattern.append(voices)
        }
        return ChimeLayer(
            kind: .audible,
            tones: bands.map { band in exp(band.map(log).reduce(0, +) / Double(band.count)) },
            voicePattern: pattern,
            preamble: [pattern[0].enumerated().map { $1[$0 % states] }, pattern[1 % patterns].enumerated().map { $1[($0 + 2) % states] }],
            symbolDuration: symbolDuration,
            pooling: 0.0025,
            timeScales: audibleScales,
            samplePoint: 0.5,
            normalisesTones: false,
            fftSize: 4096,
            minimumPreambleRatio: 1.6,
            tailSuppression: 0.45,
            bands: bands,
            bandHalfWidth: 10,
            slotWidth: 0.2,
            bandCompression: 0.4
        )
    }

    static var audible: ChimeLayer { ChimeSynth.shipping.layer }

    static var listening: [ChimeLayer] {
        var styles: [ChimeSynth.Style] = []
        for style in [ChimeSynth.shipping.decodeStyle, .eclipse, .ripple, .bell] where !styles.contains(style) { styles.append(style) }
        return styles.map(\.layer) + [.carrier]
    }

    static func carrier(lowestTone: Double = 18_200, spacing: Double = 400, toneCount: Int = 4, symbolDuration: Double = 0.05) -> ChimeLayer {
        let top = toneCount - 1
        return ChimeLayer(
            kind: .carrier,
            tones: (0..<toneCount).map { lowestTone + Double($0) * spacing },
            voicePattern: [[Array(0..<toneCount)]],
            preamble: [[top], [0], [top], [0]],
            symbolDuration: symbolDuration,
            pooling: min(0.006, spacing * 0.3 / lowestTone),
            timeScales: [0.995, 1.0, 1.005],
            samplePoint: 0.5,
            normalisesTones: true,
            fftSize: 1024,
            minimumPreambleRatio: 1.4,
            tailSuppression: 0.2
        )
    }

    static let carrier = carrier()
}

// MARK: - Synthesis

struct ChimeStereo: Sendable {
    var left: [Float]
    var right: [Float]

    init(seconds: Double, sampleRate: Double) {
        left = [Float](repeating: 0, count: max(0, Int(seconds * sampleRate)))
        right = left
    }

    var count: Int { left.count }
    var mono: [Float] { zip(left, right).map { ($0 + $1) / 2 } }

    var peak: Float {
        max(left.reduce(0) { max($0, abs($1)) }, right.reduce(0) { max($0, abs($1)) })
    }

    mutating func scale(to level: Float) {
        let current = peak
        guard current > 0 else { return }
        let gain = level / current
        for i in left.indices {
            left[i] *= gain
            right[i] *= gain
        }
    }

    mutating func fadeOut(_ seconds: Double, sampleRate: Double) {
        let fade = min(count, Int(seconds * sampleRate))
        guard fade > 0 else { return }
        for n in (count - fade)..<count {
            let gain = Float(0.5 - 0.5 * cos(Double.pi * Double(count - 1 - n) / Double(fade)))
            left[n] *= gain
            right[n] *= gain
        }
    }

    mutating func append(_ other: ChimeStereo) {
        left += other.left
        right += other.right
    }

    mutating func truncate(to samples: Int) {
        left = Array(left.prefix(samples))
        right = Array(right.prefix(samples))
    }
}

enum ChimeSynth {
    nonisolated static func renderWelcomeTone(sampleRate: Double, success: Bool = false) -> ChimeStereo {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return ChimeStereo(seconds: 0, sampleRate: 48_000)
        }
        let duration = success ? 1.15 : 1.45
        let frequencies = success ? [329.63, 392.00, 523.25] : [261.63, 329.63, 392.00]
        var output = ChimeStereo(seconds: duration, sampleRate: sampleRate)
        for (index, frequency) in frequencies.enumerated() {
            let onset = Double(index) * 0.14
            let decay = 0.26 + Double(index) * 0.035
            for frame in Int(onset * sampleRate)..<output.count {
                let time = Double(frame) / sampleRate - onset
                let attack = min(1, max(0, time / 0.035))
                let rise = 0.5 - 0.5 * cos(.pi * attack)
                let envelope = rise * exp(-max(0, time - 0.035) / decay)
                let phase = 2 * Double.pi * frequency * time
                let fundamental = sin(phase)
                let overtone = 0.12 * sin(2 * phase) * exp(-time / 0.12)
                let sample = Float(envelope * (fundamental + overtone))
                output.left[frame] += sample
                output.right[frame] += sample
            }
        }
        output.fadeOut(0.18, sampleRate: sampleRate)
        output.scale(to: 0.16)
        return output
    }

    enum Style: String, CaseIterable, Codable, Sendable {
        case bell
        case bloom
        case ripple
        case undertow
        case descent
        case eclipse
        case slide
        case pulse
        case click
        case omen
        case abyss
        case grit

        var layer: ChimeLayer {
            switch self {
            case .bell: .bell
            case .bloom: .bloom
            case .ripple, .undertow: .ripple
            case .descent: .descent
            case .eclipse, .slide, .pulse, .click: .eclipse
            case .omen, .abyss, .grit: .veil
            }
        }

        var decodeStyle: Style {
            switch self {
            case .undertow: .ripple
            case .slide, .pulse, .click: .eclipse
            case .abyss, .grit: .omen
            default: self
            }
        }

        var isDark: Bool { [.undertow, .descent, .eclipse].contains(self) }

        var isBass: Bool { [.slide, .pulse, .click, .omen, .abyss, .grit].contains(self) }

        var isVeiled: Bool { [.omen, .abyss, .grit].contains(self) }

        var pingPeriod: Double {
            switch self {
            case .bell: 2.6
            case .bloom: 3.0
            case .ripple: 2.8
            case .undertow, .descent, .eclipse, .slide, .pulse, .click, .omen, .abyss, .grit: 3.4
            }
        }
    }

    static let audiblePings = 2

    static let shipping: Style = .omen
    static let audibleLevel: Float = 0.8
    static let carrierLevel: Float = 0.05
    static let pingLevel: Float = 0.07
    static let successLevel: Float = 0.5
    static let audibleTail: Double = 0.36

    static func audibleDuration(style: Style = shipping) -> Double {
        style.layer.frameDuration + audibleTail
    }

    private struct Note {
        var frequency: Double
        var start: Double
        var amplitude: Double
        var attack: Double
        var decay: Double
        var pan: Double = 0
        var detuneCents: Double = 0
        var glide: Double = 0
        var partials: [(ratio: Double, gain: Double, decay: Double)] = []
        var lowpass: Double = .infinity
    }

    private static func add(_ note: Note, to output: inout ChimeStereo, sampleRate: Double, bandTop: Double, bandBottom: Double = 0) {
        var components: [(frequency: Double, gain: Double, decay: Double)] = [(note.frequency, 1, note.decay)]
        for partial in note.partials {
            let frequency = note.frequency * partial.ratio
            guard frequency < 0.45 * sampleRate, frequency > bandTop || frequency < bandBottom else { continue }
            components.append((frequency, partial.gain, note.decay * partial.decay))
        }
        let first = Int(note.start * sampleRate)
        guard first >= 0 else { return }
        let leftGain = note.amplitude * min(1, 1 - note.pan)
        let rightGain = note.amplitude * min(1, 1 + note.pan)
        let detune = pow(2, note.detuneCents / 2400)
        let attack = max(1, note.attack * sampleRate)
        for component in components {
            let tone = note.lowpass.isFinite ? 1 / (1 + pow(component.frequency / note.lowpass, 4)).squareRoot() : 1
            let length = min(Int((note.attack + component.decay * 7) * sampleRate), output.count - first)
            guard length > 0 else { continue }
            var leftPhase = 0.0
            var rightPhase = 0.0
            for n in 0..<length {
                let t = Double(n) / sampleRate
                let position = Double(n)
                let rise = position < attack ? 0.5 - 0.5 * cos(Double.pi * position / attack) : 1
                let envelope = component.gain * tone * rise * exp(-max(0, t - note.attack) / component.decay)
                let frequency = component.frequency * (1 + note.glide * (1 - exp(-t / 0.08)))
                leftPhase += 2 * Double.pi * frequency / detune / sampleRate
                rightPhase += 2 * Double.pi * frequency * detune / sampleRate
                output.left[first + n] += Float(leftGain * envelope * sin(leftPhase))
                output.right[first + n] += Float(rightGain * envelope * sin(rightPhase))
            }
        }
    }

    private static func bandTop(_ layer: ChimeLayer) -> Double {
        layer.highestFrequency * (1 + layer.pooling) / (layer.timeScales.min() ?? 1) + 400
    }

    private static func bandBottom(_ layer: ChimeLayer) -> Double {
        layer.lowestFrequency * (1 - layer.pooling) / (layer.timeScales.max() ?? 1) * 0.9
    }

    private static func dataAmplitude(_ frequency: Double, _ scale: Double) -> Double {
        scale * pow(1000 / frequency, 0.3)
    }

    private static func addPad(into output: inout ChimeStereo, entries: [(Double, Double)], level: Double, below: Double, sampleRate: Double) {
        let pans = [-0.5, 0.4, -0.25, 0.55, -0.6, 0.2]
        for (index, entry) in entries.enumerated() {
            add(
                Note(frequency: entry.0, start: entry.1, amplitude: level, attack: 0.45, decay: 3.2,
                     pan: pans[index % pans.count], detuneCents: 7, partials: [(2, 0.3, 0.8), (3, 0.08, 0.6)]),
                to: &output, sampleRate: sampleRate, bandTop: .infinity, bandBottom: below
            )
        }
    }

    private static let addNine: [Double] = [130.81, 196.00, 293.66, 329.63, 392.00]

    static func renderAudible(_ code: ChimeCode, sampleRate: Double, style: Style = shipping) -> [Float] {
        renderAudibleStereo(code, sampleRate: sampleRate, style: style).mono
    }

    static func renderAudibleStereo(_ code: ChimeCode, sampleRate: Double, style: Style = shipping) -> ChimeStereo {
        if style.isBass { return renderBassAudible(code, sampleRate: sampleRate, style: style) }
        if style.isDark { return renderDarkAudible(code, sampleRate: sampleRate, style: style) }
        let layer = style.layer
        var output = ChimeStereo(seconds: audibleDuration(style: style), sampleRate: sampleRate)
        let top = bandTop(layer)
        let steps = layer.steps(for: code)
        let step = layer.symbolDuration
        let resolution = Double(steps.count) * step
        let padTimes = (0..<addNine.count).map { resolution * 0.9 * Double($0) / Double(addNine.count) }
        let below = bandBottom(layer)
        addPad(into: &output, entries: Array(zip(addNine, padTimes)), level: 0.035, below: below, sampleRate: sampleRate)

        for (index, chord) in steps.enumerated() {
            for (voice, tone) in chord.enumerated() {
                let frequency = layer.tones[tone]
                let note: Note
                switch style {
                case .bell:
                    note = Note(frequency: frequency, start: Double(index) * step, amplitude: dataAmplitude(frequency, 0.3),
                                attack: 0.008, decay: 0.12, partials: [(2, 0.16, 0.6), (3, 0.05, 0.4)])
                case .bloom:
                    note = Note(frequency: frequency, start: Double(index) * step + Double(voice) * 0.011,
                                amplitude: dataAmplitude(frequency, 0.22), attack: 0.012, decay: 0.17,
                                partials: [(2, 0.14, 0.5)])
                default:
                    note = Note(frequency: frequency, start: Double(index) * step, amplitude: dataAmplitude(frequency, 0.3),
                                attack: 0.004, decay: 0.07, partials: [(2, 0.12, 0.5)])
                }
                add(note, to: &output, sampleRate: sampleRate, bandTop: top)
            }
        }

        let bloom: [Double]
        let spacing: Double
        switch style {
        case .bell:
            bloom = [1567.98, 2093.00, 2349.32, 2637.02]
            spacing = 0.05
        case .bloom:
            bloom = [1046.50, 1318.51, 1567.98, 2349.32, 3135.96]
            spacing = 0.03
        default:
            bloom = [2093.00, 2349.32, 2637.02, 3135.96, 3520.00, 4186.01]
            spacing = 0.03
        }
        for (index, frequency) in bloom.enumerated() {
            add(Note(frequency: frequency, start: resolution + Double(index) * spacing,
                     amplitude: dataAmplitude(frequency, 0.16), attack: 0.006, decay: 0.3,
                     pan: Double(index % 2 == 0 ? -1 : 1) * 0.25, detuneCents: 4, partials: [(2, 0.12, 0.5)]),
                to: &output, sampleRate: sampleRate, bandTop: top)
        }
        addPad(into: &output, entries: [(261.63, resolution), (392.00, resolution + 0.04)], level: 0.03, below: below, sampleRate: sampleRate)

        output.fadeOut(0.12, sampleRate: sampleRate)
        output.scale(to: audibleLevel)
        return output
    }

    static func renderSearchBeep(style: Style = shipping, sampleRate: Double) -> ChimeStereo {
        if style.isBass { return renderBassBeep(style: style, sampleRate: sampleRate) }
        if style.isDark { return renderDarkBeep(style: style, sampleRate: sampleRate) }
        var output = ChimeStereo(seconds: 0.35, sampleRate: sampleRate)
        let frequency: Double = style == .bloom ? 1567.98 : 2637.02
        add(Note(frequency: frequency, start: 0.005, amplitude: 1, attack: 0.002, decay: 0.03),
            to: &output, sampleRate: sampleRate, bandTop: 0)
        output.fadeOut(0.05, sampleRate: sampleRate)
        output.scale(to: pingLevel * 0.8)
        return output
    }

    static func renderPing(style: Style = shipping, sampleRate: Double) -> ChimeStereo {
        if style.isBass { return renderBassPing(style: style, sampleRate: sampleRate) }
        if style.isDark { return renderDarkPing(style: style, sampleRate: sampleRate) }
        var output = ChimeStereo(seconds: style.pingPeriod, sampleRate: sampleRate)
        let notes: [Note]
        switch style {
        case .bell:
            notes = [Note(frequency: 2093.00, start: 0, amplitude: 1, attack: 0.004, decay: 0.24, glide: -0.006,
                          partials: [(2, 0.1, 0.5)])]
        case .bloom:
            notes = [
                Note(frequency: 1567.98, start: 0, amplitude: 0.8, attack: 0.01, decay: 0.32, glide: -0.004),
                Note(frequency: 2349.32, start: 0.012, amplitude: 0.6, attack: 0.01, decay: 0.3, glide: -0.004),
            ]
        default:
            notes = [
                Note(frequency: 2349.32, start: 0, amplitude: 0.6, attack: 0.003, decay: 0.03),
                Note(frequency: 3135.96, start: 0.07, amplitude: 1, attack: 0.003, decay: 0.2, glide: -0.005),
            ]
        }
        let echoes = notes.flatMap { note -> [Note] in
            [(0.19, 0.32, -0.7), (0.38, 0.12, 0.7)].map { delay, gain, pan in
                var echo = note
                echo.start += delay
                echo.amplitude *= gain
                echo.pan = pan
                return echo
            }
        }
        for note in notes + echoes { add(note, to: &output, sampleRate: sampleRate, bandTop: 0) }
        output.scale(to: pingLevel)
        return output
    }

    static func renderSearching(style: Style = shipping, sampleRate: Double, seconds: Double) -> ChimeStereo {
        var output = renderSearchBeep(style: style, sampleRate: sampleRate)
        let cycle = renderPing(style: style, sampleRate: sampleRate)
        while output.count < Int(seconds * sampleRate) { output.append(cycle) }
        output.truncate(to: Int(seconds * sampleRate))
        return output
    }

    static func renderSuccess(style: Style = shipping, sampleRate: Double) -> ChimeStereo {
        if style.isBass { return renderBassSuccess(style: style, sampleRate: sampleRate) }
        if style.isDark { return renderDarkSuccess(style: style, sampleRate: sampleRate) }
        var output = ChimeStereo(seconds: 1.0, sampleRate: sampleRate)
        var notes: [Note] = []
        let rise: [Double]
        let rest: [Double]
        let riseSpacing: Double
        let restStart: Double
        switch style {
        case .bell:
            rise = [1318.51, 1567.98, 2093.00]
            riseSpacing = 0.075
            rest = [2093.00, 2637.02, 3135.96, 2349.32]
            restStart = 0.225
        case .bloom:
            rise = [1567.98, 1760.00, 2349.32]
            riseSpacing = 0.014
            rest = [2093.00, 2349.32, 2637.02, 3135.96]
            restStart = 0.26
        default:
            rise = [1046.50, 1318.51, 1567.98, 2093.00, 2637.02]
            riseSpacing = 0.04
            rest = [3135.96, 2093.00, 2637.02]
            restStart = 0.2
        }
        for (index, frequency) in rise.enumerated() {
            notes.append(Note(frequency: frequency, start: Double(index) * riseSpacing, amplitude: dataAmplitude(frequency, 0.9),
                              attack: 0.005, decay: style == .ripple ? 0.08 : 0.13, partials: [(2, 0.1, 0.5)]))
        }
        for (index, frequency) in rest.enumerated() {
            notes.append(Note(frequency: frequency, start: restStart + Double(index) * 0.013, amplitude: dataAmplitude(frequency, 0.7),
                              attack: 0.007, decay: 0.28, pan: index % 2 == 0 ? -0.3 : 0.3, detuneCents: 5, partials: [(2, 0.12, 0.5)]))
        }
        for note in notes { add(note, to: &output, sampleRate: sampleRate, bandTop: 0) }
        addPad(into: &output, entries: [(130.81, 0), (196.00, 0.05), (329.63, 0.2)], level: 0.06, below: 1_000, sampleRate: sampleRate)
        output.fadeOut(0.3, sampleRate: sampleRate)
        output.scale(to: successLevel)
        return output
    }
}

// MARK: - Dark styles

extension ChimeSynth {
    private struct Bed {
        var root: Double
        var colour: [(frequency: Double, at: Double, level: Double)]
        var outro: [Double]
        var sonar: Double
        var run: [Double]
    }

    private static func bed(_ style: Style) -> Bed {
        switch style {
        case .descent:
            Bed(root: 55, colour: [(130.81, 0.15, 0.03), (164.81, 0.4, 0.026), (116.54, 0.65, 0.024)],
                outro: [1046.50, 880.00, 659.26, 523.25, 440.00], sonar: 659.26, run: [659.26, 587.33, 523.25, 440.00])
        case .eclipse:
            Bed(root: 55, colour: [(155.56, 0.2, 0.034), (130.81, 0.45, 0.026), (185.00, 0.7, 0.02)],
                outro: [1479.98, 1244.51, 1046.50, 880.00, 739.99, 622.25], sonar: 622.25, run: [739.99, 622.25, 523.25, 440.00])
        default:
            Bed(root: 55, colour: [(116.54, 0.2, 0.028), (130.81, 0.45, 0.026), (155.56, 0.7, 0.022)],
                outro: [1318.51, 1046.50, 880.00, 659.26, 523.25], sonar: 440.00, run: [659.26, 523.25, 440.00])
        }
    }

    private static func toll(_ frequency: Double, at start: Double, level: Double, decay: Double, below: Double,
                             into output: inout ChimeStereo, sampleRate: Double) {
        add(Note(frequency: frequency, start: start, amplitude: level, attack: 0.006, decay: decay, detuneCents: 4,
                 partials: [(0.5, 0.6, 1.4), (1.19, 0.55, 0.8), (1.5, 0.3, 0.6), (2.0, 0.45, 0.55), (2.52, 0.18, 0.4), (2.98, 0.14, 0.35)]),
            to: &output, sampleRate: sampleRate, bandTop: .infinity, bandBottom: below)
    }

    private static func swell(_ frequency: Double, at start: Double, level: Double, attack: Double, decay: Double, below: Double,
                              pan: Double = 0, into output: inout ChimeStereo, sampleRate: Double) {
        add(Note(frequency: frequency, start: start, amplitude: level, attack: attack, decay: decay, pan: pan, detuneCents: 6,
                 partials: [(2, 0.45, 0.9), (3, 0.22, 0.8), (4, 0.12, 0.7), (5, 0.06, 0.6)]),
            to: &output, sampleRate: sampleRate, bandTop: .infinity, bandBottom: below)
    }

    private static func addDarkBed(_ bed: Bed, into output: inout ChimeStereo, length: Double, below: Double, sampleRate: Double) {
        swell(bed.root, at: 0, level: 0.15, attack: 1.4, decay: 3.5, below: below, into: &output, sampleRate: sampleRate)
        swell(bed.root * 2, at: 0.1, level: 0.07, attack: 1.0, decay: 3, below: below, pan: -0.3, into: &output, sampleRate: sampleRate)
        for (index, colour) in bed.colour.enumerated() {
            swell(colour.frequency, at: colour.at * length, level: colour.level * 1.6, attack: 0.9, decay: 2.5, below: below,
                  pan: index % 2 == 0 ? 0.45 : -0.45, into: &output, sampleRate: sampleRate)
        }
        toll(bed.root * 2, at: 0, level: 0.1, decay: 1.6, below: below, into: &output, sampleRate: sampleRate)
    }

    static func renderDarkAudible(_ code: ChimeCode, sampleRate: Double, style: Style) -> ChimeStereo {
        let layer = style.layer
        let bed = bed(style)
        var output = ChimeStereo(seconds: audibleDuration(style: style), sampleRate: sampleRate)
        let top = bandTop(layer)
        let below = bandBottom(layer)
        let steps = layer.steps(for: code)
        let step = layer.symbolDuration
        let resolution = Double(steps.count) * step
        addDarkBed(bed, into: &output, length: resolution, below: below, sampleRate: sampleRate)
        let pans = [-0.3, 0.3, 0]
        for (index, chord) in steps.enumerated() {
            for (voice, tone) in chord.enumerated() {
                let frequency = layer.tones[tone]
                var note = Note(frequency: frequency, start: Double(index) * step, amplitude: dataAmplitude(frequency, 0.3),
                                attack: 0.005, decay: 0.08, glide: -0.003, partials: [(2, 0.08, 0.5), (3, 0.03, 0.4)])
                switch style {
                case .descent:
                    note.attack = 0.006
                    note.decay = 0.09
                    note.pan = voice == 0 ? -0.2 : 0.2
                case .eclipse:
                    note.attack = 0.008
                    note.decay = 0.1
                    note.glide = -0.004
                    note.pan = pans[voice % pans.count]
                default:
                    break
                }
                add(note, to: &output, sampleRate: sampleRate, bandTop: top)
            }
        }
        for (index, frequency) in bed.outro.enumerated() {
            add(Note(frequency: frequency, start: resolution + Double(index) * 0.045, amplitude: dataAmplitude(frequency, 0.12),
                     attack: 0.008, decay: 0.3, pan: index % 2 == 0 ? -0.3 : 0.3, detuneCents: 4, glide: -0.004),
                to: &output, sampleRate: sampleRate, bandTop: top)
        }
        toll(bed.root * 2, at: resolution, level: 0.14, decay: 1.4, below: below, into: &output, sampleRate: sampleRate)
        swell(bed.root, at: resolution - 0.05, level: 0.08, attack: 0.06, decay: 0.5, below: below, into: &output, sampleRate: sampleRate)
        output.fadeOut(0.15, sampleRate: sampleRate)
        output.scale(to: audibleLevel)
        return output
    }

    static func renderDarkBeep(style: Style, sampleRate: Double) -> ChimeStereo {
        let bed = bed(style)
        var output = ChimeStereo(seconds: 0.45, sampleRate: sampleRate)
        add(Note(frequency: bed.sonar, start: 0.005, amplitude: 0.6, attack: 0.004, decay: 0.05, glide: -0.01),
            to: &output, sampleRate: sampleRate, bandTop: 0)
        add(Note(frequency: bed.root * 2, start: 0.005, amplitude: 1, attack: 0.004, decay: 0.09, partials: [(2, 0.5, 0.8), (3, 0.25, 0.6)]),
            to: &output, sampleRate: sampleRate, bandTop: 0)
        output.fadeOut(0.08, sampleRate: sampleRate)
        output.scale(to: pingLevel * 0.8)
        return output
    }

    static func renderDarkPing(style: Style, sampleRate: Double) -> ChimeStereo {
        let bed = bed(style)
        var output = ChimeStereo(seconds: style.pingPeriod, sampleRate: sampleRate)
        toll(bed.root * 2, at: 0, level: 0.45, decay: 1.1, below: .infinity, into: &output, sampleRate: sampleRate)
        toll(bed.root * 4, at: 0.01, level: 0.3, decay: 0.7, below: .infinity, into: &output, sampleRate: sampleRate)
        swell(bed.root, at: 0, level: 0.15, attack: 0.08, decay: 0.6, below: .infinity, into: &output, sampleRate: sampleRate)
        let sonar = Note(frequency: bed.sonar, start: 0.02, amplitude: 0.8, attack: 0.02, decay: 0.32, glide: -0.012)
        let echoes = [(0.24, 0.3, -0.7), (0.48, 0.12, 0.7)].map { delay, gain, pan -> Note in
            var echo = sonar
            echo.start += delay
            echo.amplitude *= gain
            echo.pan = pan
            return echo
        }
        for note in [sonar] + echoes { add(note, to: &output, sampleRate: sampleRate, bandTop: 0) }
        output.scale(to: pingLevel)
        return output
    }

    static let darkSuccessDuration: Double = 1.8

    static func renderDarkSuccess(style: Style, sampleRate: Double) -> ChimeStereo {
        let bed = bed(style)
        var output = ChimeStereo(seconds: darkSuccessDuration, sampleRate: sampleRate)
        let spacing = 0.085
        for (index, frequency) in bed.run.enumerated() {
            add(Note(frequency: frequency, start: Double(index) * spacing, amplitude: dataAmplitude(frequency, 0.55),
                     attack: 0.006, decay: 0.22, pan: index % 2 == 0 ? -0.25 : 0.25, detuneCents: 4, glide: -0.004,
                     partials: [(2, 0.1, 0.5)]),
                to: &output, sampleRate: sampleRate, bandTop: 0)
        }
        let land = Double(bed.run.count) * spacing
        toll(bed.root * 2, at: land, level: 0.5, decay: 1.2, below: .infinity, into: &output, sampleRate: sampleRate)
        swell(bed.root, at: land - 0.02, level: 0.3, attack: 0.05, decay: 0.8, below: .infinity, into: &output, sampleRate: sampleRate)
        for (index, frequency) in [110.0, 164.81, 220.0, 261.63].enumerated() {
            swell(frequency, at: land + Double(index) * 0.02, level: 0.16, attack: 0.04, decay: 0.7, below: .infinity,
                  pan: index % 2 == 0 ? -0.35 : 0.35, into: &output, sampleRate: sampleRate)
        }
        add(Note(frequency: 440, start: land, amplitude: 0.25, attack: 0.006, decay: 0.5, detuneCents: 5,
                 partials: [(2, 0.15, 0.5), (3, 0.05, 0.4)]),
            to: &output, sampleRate: sampleRate, bandTop: 0)
        output.fadeOut(0.5, sampleRate: sampleRate)
        output.scale(to: successLevel)
        return output
    }
}

// MARK: - Bass styles

struct ChimeBass {
    var pitch: [(Double, Double)]
    var cutoff: [(Double, Double)]
    var level: [(Double, Double)]
    var chord: [Double] = [1]
    var saw = 0.6
    var drive = 1.0
    var wobbleRate = 0.0
    var wobbleDepth = 0.0
    var pulseRate = 0.0
    var pulseDepth = 0.0
    var grain = 0.0
    var phaserRate = 0.0
    var phaserMix = 0.0
    var detuneCents = 6.0
    var seed: UInt64 = 1

    static func value(_ points: [(Double, Double)], at t: Double, exponential: Bool) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if t <= first.0 { return first.1 }
        for (a, b) in zip(points, points.dropFirst()) where t < b.0 {
            let shape = 0.5 - 0.5 * cos(Double.pi * (t - a.0) / max(b.0 - a.0, 1e-9))
            return exponential ? a.1 * pow(b.1 / a.1, shape) : a.1 + (b.1 - a.1) * shape
        }
        return last.1
    }

    func render(seconds: Double, sampleRate: Double, ceiling: Double) -> ChimeStereo {
        var output = ChimeStereo(seconds: seconds, sampleRate: sampleRate)
        var state = seed
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        for channel in 0..<2 {
            let side = channel == 0 ? -1.0 : 1.0
            let detune = pow(2, side * detuneCents / 2400)
            var phases = [Double](repeating: 0, count: chord.count)
            var low = 0.0
            var band = 0.0
            var held = 0.0
            var smooth = 0.0
            var holdLeft = 0
            var allpassIn = [Double](repeating: 0, count: 4)
            var allpassOut = [Double](repeating: 0, count: 4)
            var samples = [Float](repeating: 0, count: output.count)
            for n in 0..<output.count {
                let t = Double(n) / sampleRate
                let root = Self.value(pitch, at: t, exponential: true) * detune
                var x = 0.0
                for index in chord.indices {
                    phases[index] += root * chord[index] / sampleRate
                    phases[index] -= floor(phases[index])
                    let phase = phases[index]
                    x += (1 - saw) * sin(2 * Double.pi * phase) + saw * (2 * phase - 1)
                }
                x /= Double(chord.count).squareRoot()
                if grain > 0 {
                    if holdLeft <= 0 {
                        held = random()
                        holdLeft = Int((0.006 + 0.01 * random()) * sampleRate)
                    }
                    holdLeft -= 1
                    smooth += (held - smooth) * 0.01
                    x = x * (1 - grain * smooth) + grain * 0.3 * (2 * random() - 1)
                }
                let wobble = wobbleDepth * sin(2 * Double.pi * wobbleRate * t + side * 0.2)
                let frequency = min(Self.value(cutoff, at: t, exponential: true) * pow(2, wobble), sampleRate / 8)
                let coefficient = 2 * sin(Double.pi * frequency / sampleRate)
                low += coefficient * band
                band += coefficient * (x - low - 0.8 * band)
                var y = low
                if drive > 1 { y = tanh(drive * y) / tanh(drive) }
                if phaserMix > 0 {
                    let sweep = 0.5 + 0.5 * sin(2 * Double.pi * phaserRate * t + side * 0.55)
                    let k = tan(Double.pi * 90 * pow(2, 2.2 * sweep) / sampleRate)
                    let a = (k - 1) / (k + 1)
                    var stage = y
                    for index in 0..<4 {
                        let out = a * stage + allpassIn[index] - a * allpassOut[index]
                        allpassIn[index] = stage
                        allpassOut[index] = out
                        stage = out
                    }
                    y = y * (1 - phaserMix / 2) + stage * phaserMix / 2
                }
                let pulse = 1 - pulseDepth * (0.5 - 0.5 * cos(2 * Double.pi * pulseRate * t))
                samples[n] = Float(y * pulse * Self.value(level, at: t, exponential: false))
            }
            Self.lowpass(&samples, cutoff: ceiling, stages: 4, sampleRate: sampleRate)
            if channel == 0 { output.left = samples } else { output.right = samples }
        }
        return output
    }

    static func thump(from high: Double, to low: Double, drop: Double, decay: Double, tick: Double, seconds: Double, sampleRate: Double) -> ChimeStereo {
        var output = ChimeStereo(seconds: seconds, sampleRate: sampleRate)
        var phase = 0.0
        for n in 0..<output.count {
            let t = Double(n) / sampleRate
            let frequency = low + (high - low) * exp(-t / drop)
            phase += 2 * Double.pi * frequency / sampleRate
            let body = tanh(2 * sin(phase)) / tanh(2) * min(1, t / 0.0015) * exp(-t / decay)
            let click = t < 0.002 ? 0.35 * sin(2 * Double.pi * tick * t) * (0.5 - 0.5 * cos(2 * Double.pi * t / 0.002)) : 0
            output.left[n] = Float(body + click)
            output.right[n] = output.left[n]
        }
        return output
    }

    static func lowpass(_ x: inout [Float], cutoff: Double, stages: Int, sampleRate: Double) {
        let w0 = 2 * Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * 0.7071)
        let b0 = (1 - cos(w0)) / 2, b1 = 1 - cos(w0), b2 = (1 - cos(w0)) / 2
        let a0 = 1 + alpha, a1 = -2 * cos(w0), a2 = 1 - alpha
        for _ in 0..<stages {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for n in x.indices {
                let input = Double(x[n])
                let output = (b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
                x2 = x1
                x1 = input
                y2 = y1
                y1 = output
                x[n] = Float(output)
            }
        }
    }
}

extension ChimeStereo {
    mutating func mix(_ other: ChimeStereo, at seconds: Double = 0, gain: Float, sampleRate: Double) {
        let offset = Int(seconds * sampleRate)
        guard offset >= 0 else { return }
        for n in 0..<max(0, min(other.count, count - offset)) {
            left[offset + n] += other.left[n] * gain
            right[offset + n] += other.right[n] * gain
        }
    }
}

extension ChimeSynth {
    static let bassSuccessDuration: Double = 2.4

    static func renderBassAudible(_ code: ChimeCode, sampleRate: Double, style: Style) -> ChimeStereo {
        renderHandshake(code, design: ChimeDesign(style: style), sampleRate: sampleRate)
    }

    static func renderBassBeep(style: Style, sampleRate: Double) -> ChimeStereo {
        var output: ChimeStereo
        switch style {
        case .omen, .abyss:
            output = ChimeBass.thump(from: 150, to: 41.2, drop: 0.025, decay: 0.13, tick: 1_400, seconds: 0.45, sampleRate: sampleRate)
            ChimeBass.lowpass(&output.left, cutoff: 1_500, stages: 2, sampleRate: sampleRate)
            output.right = output.left
        case .grit:
            output = ChimeBass(pitch: [(0, 82.4), (0.12, 41.2), (0.45, 41.2)], cutoff: [(0, 700), (0.45, 110)], level: [(0, 0), (0.004, 1), (0.45, 0)],
                               chord: [1, 2], saw: 0.85, drive: 3.5, grain: 0.4, phaserRate: 3, phaserMix: 0.8, seed: 41)
                .render(seconds: 0.45, sampleRate: sampleRate, ceiling: 1_500)
        case .click:
            output = ChimeBass.thump(from: 260, to: 98, drop: 0.02, decay: 0.07, tick: 900, seconds: 0.4, sampleRate: sampleRate)
        case .pulse:
            output = ChimeBass(pitch: [(0, 55), (0.4, 55)], cutoff: [(0, 600), (0.4, 150)], level: [(0, 0), (0.01, 1), (0.4, 0)],
                               chord: [1, 2], saw: 0.8, drive: 3.5, grain: 0.4, phaserRate: 2, phaserMix: 0.8, seed: 11)
                .render(seconds: 0.4, sampleRate: sampleRate, ceiling: 1_500)
        default:
            output = ChimeBass(pitch: [(0, 110), (0.25, 55)], cutoff: [(0, 900), (0.3, 120)], level: [(0, 0), (0.01, 1), (0.38, 0)],
                               saw: 0.7, drive: 2)
                .render(seconds: 0.4, sampleRate: sampleRate, ceiling: 1_500)
        }
        output.fadeOut(0.05, sampleRate: sampleRate)
        output.scale(to: bassPingLevel * 0.8)
        return output
    }

    static let bassPingLevel: Float = 0.09

    static func renderBassPing(style: Style, sampleRate: Double) -> ChimeStereo {
        var output = ChimeStereo(seconds: style.pingPeriod, sampleRate: sampleRate)
        let sound: ChimeStereo
        switch style {
        case .omen:
            sound = ChimeBass(pitch: [(0, 41.2), (0.4, 55), (1.8, 41.2)], cutoff: [(0, 60), (0.6, 280), (1.8, 60)],
                              level: [(0, 0), (0.45, 1), (1.1, 0.75), (1.8, 0)], chord: [1, 2, 3], saw: 0.75, drive: 2.4,
                              pulseRate: 1 / 0.14, pulseDepth: 0.55, grain: 0.12, phaserRate: 0.45, phaserMix: 0.8, seed: 43)
                .render(seconds: 1.8, sampleRate: sampleRate, ceiling: 1_200)
        case .abyss:
            sound = ChimeBass(pitch: [(0, 27.5), (0.6, 55), (1.8, 36.7)], cutoff: [(0, 50), (0.6, 320), (1.8, 60)],
                              level: [(0, 0), (0.3, 1), (1.2, 0.7), (1.8, 0)], chord: [1, 2], saw: 0.7, drive: 1.8,
                              wobbleRate: 1.7, wobbleDepth: 0.9, pulseRate: 1 / 0.14, pulseDepth: 0.25, grain: 0.05, seed: 47)
                .render(seconds: 1.8, sampleRate: sampleRate, ceiling: 1_200)
        case .grit:
            sound = ChimeBass(pitch: [(0, 55), (1.8, 46.2)], cutoff: [(0, 80), (0.7, 420), (1.8, 80)],
                              level: [(0, 0), (0.5, 1), (1.1, 0.8), (1.8, 0)], chord: [1, 1.5, 2], saw: 0.85, drive: 3.5,
                              pulseRate: 0.5 / 0.14, pulseDepth: 0.5, grain: 0.4, phaserRate: 0.7, phaserMix: 0.9, seed: 53)
                .render(seconds: 1.8, sampleRate: sampleRate, ceiling: 1_200)
        case .click:
            sound = ChimeBass.thump(from: 220, to: 82.4, drop: 0.035, decay: 0.22, tick: 700, seconds: 1.2, sampleRate: sampleRate)
        case .pulse:
            sound = ChimeBass(pitch: [(0, 55), (1.8, 55)], cutoff: [(0, 100), (0.9, 600), (1.8, 120)], level: [(0, 0), (0.6, 1), (1.1, 0.8), (1.8, 0)],
                              chord: [1, 1.5, 2.378], saw: 0.8, drive: 3, pulseRate: 7.4, pulseDepth: 0.5, grain: 0.4,
                              phaserRate: 0.6, phaserMix: 0.9, seed: 13)
                .render(seconds: 1.8, sampleRate: sampleRate, ceiling: 1_200)
        default:
            sound = ChimeBass(pitch: [(0, 36.7), (0.25, 55), (0.9, 55), (1.4, 36.7)], cutoff: [(0, 90), (0.3, 500), (1.4, 120)],
                              level: [(0, 0), (0.08, 1), (1.0, 0.7), (1.6, 0)], saw: 0.7, drive: 2, wobbleRate: 2.2, wobbleDepth: 1.0)
                .render(seconds: 1.6, sampleRate: sampleRate, ceiling: 1_200)
        }
        output.mix(sound, gain: 1, sampleRate: sampleRate)
        output.scale(to: bassPingLevel)
        return output
    }

    static func renderBassSuccess(style: Style, sampleRate: Double) -> ChimeStereo {
        var output = ChimeStereo(seconds: bassSuccessDuration, sampleRate: sampleRate)
        switch style {
        case .omen:
            output.mix(ChimeBass(pitch: [(0, 41.2), (0.35, 55), (2.4, 55)], cutoff: [(0, 70), (0.5, 900), (1.2, 300), (2.4, 60)],
                                 level: [(0, 0), (0.3, 1), (1.2, 0.8), (2.4, 0)], chord: [1, 2, 3, 4], saw: 0.75, drive: 2.6,
                                 pulseRate: 1 / 0.14, pulseDepth: 0.4, grain: 0.1, phaserRate: 0.3, phaserMix: 0.8, seed: 59)
                .render(seconds: bassSuccessDuration, sampleRate: sampleRate, ceiling: 1_500), gain: 1, sampleRate: sampleRate)
        case .abyss:
            output.mix(ChimeBass(pitch: [(0, 110), (0.4, 27.5), (0.7, 55), (2.4, 55)], cutoff: [(0, 1_000), (0.4, 300), (2.4, 60)],
                                 level: [(0, 0), (0.02, 1), (0.6, 0.9), (2.4, 0)], chord: [1, 2], saw: 0.7, drive: 2.2,
                                 wobbleRate: 1.2, wobbleDepth: 0.7, seed: 61)
                .render(seconds: bassSuccessDuration, sampleRate: sampleRate, ceiling: 1_500), gain: 1, sampleRate: sampleRate)
        case .grit:
            output.mix(ChimeBass(pitch: [(0, 55), (2.4, 55)], cutoff: [(0, 100), (0.6, 1_000), (2.4, 120)],
                                 level: [(0, 0), (0.4, 1), (1.3, 0.8), (2.4, 0)], chord: [1, 1.5, 2, 3], saw: 0.85, drive: 3.5,
                                 pulseRate: 0.5 / 0.14, pulseDepth: 0.4, grain: 0.35, phaserRate: 0.4, phaserMix: 0.9, seed: 67)
                .render(seconds: bassSuccessDuration, sampleRate: sampleRate, ceiling: 1_500), gain: 1, sampleRate: sampleRate)
        case .click:
            output.mix(ChimeBass.thump(from: 240, to: 98, drop: 0.03, decay: 0.12, tick: 800, seconds: 0.8, sampleRate: sampleRate), gain: 0.7, sampleRate: sampleRate)
            output.mix(ChimeBass.thump(from: 196, to: 73.4, drop: 0.05, decay: 0.45, tick: 600, seconds: 2.2, sampleRate: sampleRate), at: 0.16, gain: 1, sampleRate: sampleRate)
        case .pulse:
            output.mix(ChimeBass(pitch: [(0, 110), (0.25, 55), (2.4, 55)], cutoff: [(0, 120), (0.8, 900), (2.4, 140)],
                                 level: [(0, 0), (0.5, 1), (1.4, 0.8), (2.4, 0)], chord: [1, 1.5, 2, 2.378, 3], saw: 0.8, drive: 3,
                                 pulseRate: 3.7, pulseDepth: 0.35, grain: 0.3, phaserRate: 0.4, phaserMix: 0.9, seed: 17)
                .render(seconds: bassSuccessDuration, sampleRate: sampleRate, ceiling: 1_500), gain: 1, sampleRate: sampleRate)
        default:
            output.mix(ChimeBass(pitch: [(0, 164.8), (0.35, 41.2), (0.5, 55), (2.4, 55)], cutoff: [(0, 1_200), (0.35, 700), (0.6, 300), (2.4, 90)],
                                 level: [(0, 0), (0.02, 1), (0.5, 0.9), (2.4, 0)], chord: [1, 2], saw: 0.7, drive: 2.5,
                                 wobbleRate: 1.5, wobbleDepth: 0.6, seed: 19)
                .render(seconds: bassSuccessDuration, sampleRate: sampleRate, ceiling: 1_500), gain: 1, sampleRate: sampleRate)
        }
        output.fadeOut(0.4, sampleRate: sampleRate)
        output.scale(to: successLevel)
        return output
    }
}

// MARK: - Designs

struct ChimeLayerDesign: Codable, Equatable, Sendable {
    enum Base: String, Codable, CaseIterable, Sendable {
        case eclipse
        case ripple
        case descent
        case bell
        case veil

        var shipped: ChimeLayer {
            switch self {
            case .veil: .veil
            case .eclipse: .eclipse
            case .ripple: .ripple
            case .descent: .descent
            case .bell: .bell
            }
        }
    }

    var base: Base
    var lowestMIDI: Int
    var rangeSemitones: Int
    var noteLength: Double

    init(base: Base) {
        let layer = base.shipped
        self.base = base
        lowestMIDI = Int((69 + 12 * log2(layer.tones[0] / 440)).rounded())
        rangeSemitones = Int((12 * log2(layer.tones[layer.tones.count - 1] / layer.tones[0])).rounded())
        noteLength = layer.symbolDuration
    }

    var isShipped: Bool { self == ChimeLayerDesign(base: base) }

    var layer: ChimeLayer {
        let original = base.shipped
        guard !isShipped else { return original }
        if original.isSpread {
            var layer = original
            layer.symbolDuration = noteLength
            return layer
        }
        let offsets = original.tones.map { 12 * log2($0 / original.tones[0]) }
        let span = max(offsets[offsets.count - 1], 1)
        let tones = offsets.map { 440 * pow(2, (Double(lowestMIDI) - 69 + $0 * Double(rangeSemitones) / span) / 12) }
        let spacing = zip(tones, tones.dropFirst()).map { $1 - $0 }.min() ?? 100
        var fftSize = original.fftSize
        while fftSize < 8192, 48_000 / Double(fftSize) > spacing / 3.5, Double(fftSize * 2) <= noteLength * 48_000 * 1.5 { fftSize *= 2 }
        return ChimeLayer(
            kind: .audible, tones: tones, voicePattern: original.voicePattern, preamble: original.preamble,
            symbolDuration: noteLength, pooling: original.pooling, timeScales: original.timeScales,
            samplePoint: original.samplePoint, normalisesTones: original.normalisesTones, fftSize: fftSize,
            minimumPreambleRatio: original.minimumPreambleRatio, tailSuppression: original.tailSuppression
        )
    }

    var isHeardByShippingDecoder: Bool {
        isShipped && ChimeLayer.listening.contains { $0.tones == base.shipped.tones && $0.symbolDuration == base.shipped.symbolDuration }
    }
}

struct ChimeVoiceSettings: Codable, Equatable, Sendable {
    enum Timbre: String, Codable, CaseIterable, Sendable {
        case sine
        case softSine
        case filteredSaw
        case bell
        case mutedPluck

        var partials: [(ratio: Double, gain: Double, decay: Double)] {
            switch self {
            case .sine: []
            case .softSine: [(2, 0.08, 0.5), (3, 0.03, 0.4)]
            case .filteredSaw: (2...12).map { (Double($0), 1 / Double($0), 1 - 0.04 * Double($0)) }
            case .bell: [(2, 0.35, 0.55), (2.76, 0.22, 0.4), (5.4, 0.1, 0.25)]
            case .mutedPluck: [(2, 0.12, 0.5)]
            }
        }
    }

    var enabled = true
    var levelDB = 0.0
    var tilt = 0.45
    var timbre = Timbre.sine
    var attack = 0.014
    var release = 0.1
    var glide = -0.004
    var spread = 0.3
    var lowpass = 20_000.0
    var overtonesInBand = false
    var followsPulse = false

    static let bass = ChimeVoiceSettings()
    static let eclipse = ChimeVoiceSettings(tilt: 0.3, timbre: .softSine, attack: 0.008, release: 0.1, glide: -0.004)
    static let ripple = ChimeVoiceSettings(tilt: 0.3, timbre: .mutedPluck, attack: 0.004, release: 0.07, glide: 0, spread: 0)
    static func veil(levelDB: Double) -> ChimeVoiceSettings {
        ChimeVoiceSettings(levelDB: levelDB, tilt: 0.4, timbre: .sine, attack: 0.025, release: 0.14, glide: 0, spread: 0.6)
    }

    static let silentDB = -60.0

    var gain: Double { !enabled || levelDB <= Self.silentDB ? 0 : pow(10, levelDB / 20) }
}

struct ChimeBedDesign: Codable, Equatable, Sendable {
    enum Style: String, Codable, CaseIterable, Sendable {
        case slide
        case pulse
        case click
        case drone
        case omen
        case abyss
        case grit
        case toll
        case pad
        case none

        var isBass: Bool { [.slide, .pulse, .click, .drone, .omen, .abyss, .grit].contains(self) }
    }

    var style: Style
    var rootMIDI = 33
    var slideRange = 1.0
    var slideTime = 1.0
    var wobbleRate = 0.0
    var wobbleDepth = 0.0
    var throbRate = 0.0
    var throbDepth = 0.0
    var drive = 1.0
    var grain = 0.0
    var phaserRate = 0.0
    var phaserDepth = 0.0
    var lowpass = 260.0
    var levelDB = 0.0
    var flourish = true

    init(style: Style) {
        self.style = style
        switch style {
        case .slide:
            wobbleRate = 1.7; wobbleDepth = 0.9; throbRate = 1.7; throbDepth = 0.25; drive = 1.6; grain = 0.05; lowpass = 260
        case .pulse:
            throbRate = 3.7; throbDepth = 0.45; drive = 3; grain = 0.35; phaserRate = 0.25; phaserDepth = 0.8; lowpass = 280
        case .click:
            lowpass = 120
        case .drone:
            rootMIDI = 36; wobbleRate = 1.66; wobbleDepth = 0.5; throbRate = 7.4; throbDepth = 0.55; drive = 2.2; grain = 0.15
            phaserRate = 0.8; phaserDepth = 0.7; lowpass = 140
        case .omen:
            throbRate = 1 / 0.14; throbDepth = 0.55; drive = 2.4; grain = 0.12; phaserRate = 0.45; phaserDepth = 0.8; lowpass = 240
        case .abyss:
            wobbleRate = 1.7; wobbleDepth = 0.9; throbRate = 1 / 0.14; throbDepth = 0.25; drive = 1.8; grain = 0.05; lowpass = 240
        case .grit:
            throbRate = 0.5 / 0.14; throbDepth = 0.5; drive = 3.5; grain = 0.4; phaserRate = 0.7; phaserDepth = 0.9; lowpass = 240
        case .toll, .pad, .none:
            break
        }
    }

    var baseLevel: Float { style == .click ? 0.4 : 1.0 }

    var gain: Float { Float(Double(baseLevel) * pow(10, levelDB / 20)) }

    func bass(length: Double, reference: Double) -> ChimeBass? {
        let preset = ChimeBedDesign(style: style)
        let end = length + ChimeSynth.audibleTail
        let k = length / reference
        let transpose = pow(2, Double(rootMIDI - preset.rootMIDI) / 12)
        let c = lowpass / preset.lowpass
        func f(_ frequency: Double, _ root: Double) -> Double { frequency * pow(frequency / root, slideRange - 1) * transpose }
        func at(_ t: Double, slide: Bool = false) -> Double { min(length, t * k * (slide ? slideTime : 1)) }
        var bass: ChimeBass
        switch style {
        case .slide:
            bass = ChimeBass(
                pitch: [(0, f(41.2, 55)), (at(0.5, slide: true), f(55, 55)), (at(1.5, slide: true), f(55, 55)), (at(1.9, slide: true), f(82.4, 55)),
                        (at(2.6, slide: true), f(77.8, 55)), (at(3.0, slide: true), f(58.3, 55)), (length, f(55, 55)), (end, f(27.5, 55))],
                cutoff: [(0, 70 * c), (at(0.5), 160 * c), (at(2.0), 260 * c), (at(3.0), 180 * c), (length, 220 * c), (end, 60 * c)],
                level: [(0, 0), (0.35, 1), (length - 0.1, 0.9), (end, 0)],
                saw: 0.7, seed: 3
            )
        case .pulse:
            bass = ChimeBass(
                pitch: [(0, f(55, 55)), (length, f(55, 55)), (end, f(41.2, 55))],
                cutoff: [(0, 90 * c), (at(2.2), 280 * c), (length, 200 * c), (end, 60 * c)],
                level: [(0, 0), (at(1.6), 1), (length, 0.9), (end, 0)],
                chord: [1, 1.5, 2, 2.378], saw: 0.8, seed: 7
            )
        case .click:
            bass = ChimeBass(
                pitch: [(0, f(55, 55)), (end, f(55, 55))],
                cutoff: [(0, 120 * c), (end, 120 * c)],
                level: [(0, 0), (at(1.2), 1), (length, 0.8), (end, 0)],
                saw: 0.1
            )
        case .drone:
            bass = ChimeBass(
                pitch: [(0, f(65.41, 65.41)), (length, f(65.41, 65.41)), (end, f(49, 65.41))],
                cutoff: [(0, 70 * c), (at(0.8), 140 * c), (length, 140 * c), (end, 60 * c)],
                level: [(0, 0), (at(0.6), 1), (length, 0.9), (end, 0)],
                chord: [1, 2, 3], saw: 0.75, seed: 23
            )
        case .omen:
            bass = ChimeBass(
                pitch: [(0, f(41.2, 55)), (length * 0.3, f(55, 55)), (length, f(55, 55)), (end, f(36.7, 55))],
                cutoff: [(0, 60 * c), (length * 0.5, 220 * c), (length * 0.85, 260 * c), (end, 50 * c)],
                level: [(0, 0), (length * 0.35, 1), (length, 0.95), (end, 0)],
                chord: [1, 2, 3], saw: 0.75, seed: 29
            )
        case .abyss:
            bass = ChimeBass(
                pitch: [(0, f(27.5, 55)), (length * 0.45, f(55, 55)), (length * 0.75, f(49, 55)), (length, f(41.2, 55)), (end, f(27.5, 55))],
                cutoff: [(0, 50 * c), (length * 0.4, 220 * c), (length, 170 * c), (end, 40 * c)],
                level: [(0, 0), (length * 0.3, 1), (length, 0.9), (end, 0)],
                chord: [1, 2], saw: 0.7, seed: 31
            )
        case .grit:
            bass = ChimeBass(
                pitch: [(0, f(55, 55)), (length, f(55, 55)), (end, f(41.2, 55))],
                cutoff: [(0, 80 * c), (length * 0.5, 260 * c), (length, 200 * c), (end, 50 * c)],
                level: [(0, 0), (length * 0.4, 1), (length, 0.9), (end, 0)],
                chord: [1, 1.5, 2], saw: 0.85, seed: 37
            )
        case .toll, .pad, .none:
            return nil
        }
        bass.drive = drive
        bass.wobbleRate = wobbleRate
        bass.wobbleDepth = wobbleDepth
        bass.pulseRate = throbRate
        bass.pulseDepth = throbDepth
        bass.grain = grain
        bass.phaserRate = phaserRate
        bass.phaserMix = phaserDepth
        return bass
    }

    func thumps(length: Double) -> [(at: Double, high: Double, low: Double, gain: Float)] {
        guard style == .click else { return [] }
        let transpose = pow(2, Double(rootMIDI - 33) / 12)
        return [(0.0, 140.0, 55.0, Float(0.35)), (length, 110.0, 41.2, 0.5)].map {
            ($0.0, $0.1 * transpose, $0.2 * pow($0.2 / 55, slideRange - 1) * transpose, $0.3)
        }
    }
}

struct ChimeCueDesign: Codable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case beep
        case ping
        case success
    }

    var style: ChimeSynth.Style?
    var pitch = 0.0
    var levelDB = 0.0

    func render(_ kind: Kind, sampleRate: Double) -> ChimeStereo {
        guard let style else {
            return ChimeStereo(seconds: kind == .ping ? ChimeSynth.Style.slide.pingPeriod : 0.4, sampleRate: sampleRate)
        }
        var output = switch kind {
        case .beep: ChimeSynth.renderSearchBeep(style: style, sampleRate: sampleRate)
        case .ping: ChimeSynth.renderPing(style: style, sampleRate: sampleRate)
        case .success: ChimeSynth.renderSuccess(style: style, sampleRate: sampleRate)
        }
        if pitch != 0 {
            let ratio = pow(2, pitch / 12)
            let length = kind == .ping ? output.count : Int(Double(output.count) / ratio)
            func shift(_ x: [Float]) -> [Float] {
                (0..<length).map { n in
                    let position = Double(n) * ratio
                    let j = Int(position)
                    guard j + 1 < x.count else { return 0 }
                    let fraction = Float(position - Double(j))
                    return x[j] * (1 - fraction) + x[j + 1] * fraction
                }
            }
            output.left = shift(output.left)
            output.right = shift(output.right)
        }
        if levelDB != 0 {
            let gain = Float(pow(10, levelDB / 20))
            for n in 0..<output.count {
                output.left[n] *= gain
                output.right[n] *= gain
            }
        }
        return output
    }
}

struct ChimeDesign: Codable, Equatable, Sendable {
    var layer: ChimeLayerDesign
    var voice: ChimeVoiceSettings
    var bed: ChimeBedDesign
    var carrier = true
    var carrierLevelDB = 0.0
    var beep: ChimeCueDesign
    var ping: ChimeCueDesign
    var success: ChimeCueDesign

    init(layer: ChimeLayerDesign, voice: ChimeVoiceSettings, bed: ChimeBedDesign, cues: ChimeSynth.Style?) {
        self.layer = layer
        self.voice = voice
        self.bed = bed
        beep = ChimeCueDesign(style: cues)
        ping = ChimeCueDesign(style: cues)
        success = ChimeCueDesign(style: cues)
    }

    init(style: ChimeSynth.Style) {
        switch style {
        case .eclipse:
            self.init(layer: ChimeLayerDesign(base: .eclipse), voice: .eclipse, bed: ChimeBedDesign(style: .toll), cues: style)
        case .ripple:
            self.init(layer: ChimeLayerDesign(base: .ripple), voice: .ripple, bed: ChimeBedDesign(style: .pad), cues: style)
        case .pulse, .click:
            self.init(layer: ChimeLayerDesign(base: .eclipse), voice: .bass, bed: ChimeBedDesign(style: style == .pulse ? .pulse : .click), cues: style)
        case .omen:
            self.init(layer: ChimeLayerDesign(base: .veil), voice: .veil(levelDB: -11), bed: ChimeBedDesign(style: .omen), cues: style)
        case .abyss:
            self.init(layer: ChimeLayerDesign(base: .veil), voice: .veil(levelDB: -8), bed: ChimeBedDesign(style: .abyss), cues: style)
        case .grit:
            self.init(layer: ChimeLayerDesign(base: .veil), voice: .veil(levelDB: -8), bed: ChimeBedDesign(style: .grit), cues: style)
        default:
            self.init(layer: ChimeLayerDesign(base: .eclipse), voice: .bass, bed: ChimeBedDesign(style: .slide), cues: .slide)
        }
    }

    var audibleData: Bool { voice.gain > 0 }

    var carrierLevel: Float { carrier ? Float(Double(ChimeSynth.carrierLevel) * pow(10, carrierLevelDB / 20)) : 0 }

    var handshakeDuration: Double { layer.layer.frameDuration + ChimeSynth.audibleTail }
}

extension ChimeSynth {
    static func renderHandshake(_ code: ChimeCode, design: ChimeDesign, sampleRate: Double) -> ChimeStereo {
        let layer = design.layer.layer
        let voice = design.voice
        let bedDesign = design.bed
        var output = ChimeStereo(seconds: design.handshakeDuration, sampleRate: sampleRate)
        let top = bandTop(layer)
        let below = bandBottom(layer)
        let steps = layer.steps(for: code)
        let step = layer.symbolDuration
        let resolution = Double(steps.count) * step
        let ceiling = design.audibleData ? below * 0.75 : 1_500
        let gain = bedDesign.gain

        func ornament(_ body: (inout ChimeStereo) -> Void) {
            guard gain != 1 else { return body(&output) }
            var layerOutput = ChimeStereo(seconds: design.handshakeDuration, sampleRate: sampleRate)
            body(&layerOutput)
            output.mix(layerOutput, gain: gain, sampleRate: sampleRate)
        }

        switch bedDesign.style {
        case .toll:
            ornament { addDarkBed(bed(.eclipse), into: &$0, length: resolution, below: below, sampleRate: sampleRate) }
        case .pad:
            let padTimes = (0..<addNine.count).map { resolution * 0.9 * Double($0) / Double(addNine.count) }
            ornament { addPad(into: &$0, entries: Array(zip(addNine, padTimes)), level: 0.035, below: below, sampleRate: sampleRate) }
        case .none:
            break
        case .slide, .pulse, .click, .drone, .omen, .abyss, .grit:
            if let bass = bedDesign.bass(length: resolution, reference: ChimeLayer.eclipse.frameDuration) {
                output.mix(bass.render(seconds: design.handshakeDuration, sampleRate: sampleRate, ceiling: ceiling), gain: gain, sampleRate: sampleRate)
            }
            for thump in bedDesign.thumps(length: resolution) {
                var sound = ChimeBass.thump(from: thump.high, to: thump.low, drop: 0.03, decay: 0.16, tick: 0, seconds: 0.6, sampleRate: sampleRate)
                ChimeBass.lowpass(&sound.left, cutoff: ceiling, stages: 4, sampleRate: sampleRate)
                sound.right = sound.left
                output.mix(sound, at: thump.at, gain: thump.gain * (gain / bedDesign.baseLevel), sampleRate: sampleRate)
            }
        }

        if design.audibleData, layer.isSpread {
            if voice.followsPulse {
                addPulseVeil(steps, layer: layer, voice: voice, bed: bedDesign, into: &output, sampleRate: sampleRate)
            } else {
                addVeil(steps, layer: layer, voice: voice, into: &output, sampleRate: sampleRate)
            }
        } else if design.audibleData {
            let scale = voice.gain
            let pans = [-1.0, 1.0, 0]
            let lowpass = voice.lowpass >= 20_000 ? Double.infinity : voice.lowpass
            for (index, chord) in steps.enumerated() {
                for (slot, tone) in chord.enumerated() {
                    let frequency = layer.tones[tone]
                    add(Note(frequency: frequency, start: Double(index) * step, amplitude: 0.3 * pow(1000 / frequency, voice.tilt) * scale,
                             attack: voice.attack, decay: voice.release, pan: pans[slot % pans.count] * voice.spread, glide: voice.glide,
                             partials: voice.timbre.partials, lowpass: lowpass),
                        to: &output, sampleRate: sampleRate, bandTop: voice.overtonesInBand ? 0 : top)
                }
            }
        }

        switch bedDesign.style {
        case .toll:
            let dark = bed(.eclipse)
            if bedDesign.flourish {
                for (index, frequency) in dark.outro.enumerated() {
                    add(Note(frequency: frequency, start: resolution + Double(index) * 0.045, amplitude: dataAmplitude(frequency, 0.12),
                             attack: 0.008, decay: 0.3, pan: index % 2 == 0 ? -0.3 : 0.3, detuneCents: 4, glide: -0.004),
                        to: &output, sampleRate: sampleRate, bandTop: top)
                }
            }
            ornament {
                toll(dark.root * 2, at: resolution, level: 0.14, decay: 1.4, below: below, into: &$0, sampleRate: sampleRate)
                swell(dark.root, at: resolution - 0.05, level: 0.08, attack: 0.06, decay: 0.5, below: below, into: &$0, sampleRate: sampleRate)
            }
        case .pad:
            if bedDesign.flourish {
                for (index, frequency) in [2093.00, 2349.32, 2637.02, 3135.96, 3520.00, 4186.01].enumerated() {
                    add(Note(frequency: frequency, start: resolution + Double(index) * 0.03,
                             amplitude: dataAmplitude(frequency, 0.16), attack: 0.006, decay: 0.3,
                             pan: Double(index % 2 == 0 ? -1 : 1) * 0.25, detuneCents: 4, partials: [(2, 0.12, 0.5)]),
                        to: &output, sampleRate: sampleRate, bandTop: top)
                }
            }
            ornament { addPad(into: &$0, entries: [(261.63, resolution), (392.00, resolution + 0.04)], level: 0.03, below: below, sampleRate: sampleRate) }
        default:
            break
        }

        output.fadeOut(bedDesign.style == .pad ? 0.12 : 0.15, sampleRate: sampleRate)
        output.scale(to: audibleLevel)
        return output
    }

    static let veilPartialOffsets: [Double] = [-6, 0, 6]

    static func addVeil(_ steps: [[Int]], layer: ChimeLayer, voice: ChimeVoiceSettings, into output: inout ChimeStereo, sampleRate: Double) {
        let step = layer.symbolDuration
        let taper = max(0.004, voice.attack)
        let length = step + taper
        let samples = Int(length * sampleRate)
        let rise = max(1, Int(taper * sampleRate))
        let envelope = (0..<samples).map { n -> Double in
            let edge = min(n, samples - 1 - n)
            return edge < rise ? 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(rise)) : 1
        }
        let total = Double(steps.count) * step
        let contour = [(0.0, 0.55), (0.5, 1.0), (max(0.5, total - 0.4), 1.0), (total, 0.75)]
        let partials = Double(layer.voiceCount * (layer.bands.first?.count ?? 1) * veilPartialOffsets.count)
        let level = 0.6 * voice.gain / partials.squareRoot()
        var state: UInt64 = 0x0DD5_EED5
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        for (index, chord) in steps.enumerated() {
            let start = Double(index) * step - taper / 2
            let first = Int((start * sampleRate).rounded())
            let gain = level * ChimeBass.value(contour, at: Double(index) * step + step / 2, exponential: false)
            for tone in chord {
                for centre in layer.bands[tone] {
                    for offset in veilPartialOffsets {
                        let frequency = centre + offset + (random() - 0.5) * 3
                        let phase = random() * 2 * Double.pi
                        let pan = (2 * random() - 1) * voice.spread
                        let amplitude = gain * pow(1000 / centre, voice.tilt)
                        let leftGain = Float(amplitude * min(1, 1 - pan))
                        let rightGain = Float(amplitude * min(1, 1 + pan))
                        let w = 2 * Double.pi * frequency / sampleRate
                        for n in max(0, -first)..<min(samples, output.count - first) {
                            let value = Float(sin(phase + w * Double(n)) * envelope[n])
                            output.left[first + n] += leftGain * value
                            output.right[first + n] += rightGain * value
                        }
                    }
                }
            }
        }
    }
}

extension ChimeSynth {
    static let pulseVeilGateDepth = 0.8
    static let pulseVeilFloor = 0.35
    static let pulseVeilShelf = 1_500.0
    static let pulseVeilShelfSlope = 1.5

    static func pulseVeilWeight(_ centre: Double, tilt: Double) -> Double {
        pow(1000 / centre, tilt) * (centre > pulseVeilShelf ? pow(pulseVeilShelf / centre, pulseVeilShelfSlope) : 1)
    }

    static func pulseVeilDelay(step: Double, period: Double) -> Double {
        let offset = (step / 2).truncatingRemainder(dividingBy: period)
        return (period - offset).truncatingRemainder(dividingBy: period)
    }

    static func addPulseVeil(_ steps: [[Int]], layer: ChimeLayer, voice: ChimeVoiceSettings, bed: ChimeBedDesign,
                             into output: inout ChimeStereo, sampleRate: Double) {
        let step = layer.symbolDuration
        let total = Double(steps.count) * step
        let period = bed.throbRate > 0 ? 1 / bed.throbRate : step
        let delay = pulseVeilDelay(step: step, period: period)
        let swell = bed.bass(length: total, reference: ChimeLayer.eclipse.frameDuration)?.level ?? [(0, 1)]
        let centres = layer.bands.flatMap { $0 }
        let oldPower = centres.map { pow(pow(1000 / $0, voice.tilt), 2) }.reduce(0, +) / Double(centres.count)
        let newPower = centres.map { pow(pulseVeilWeight($0, tilt: voice.tilt), 2) }.reduce(0, +) / Double(centres.count)
        let balance = (oldPower / newPower).squareRoot()
        let taper = max(0.004, voice.attack)
        let samples = Int((step + taper) * sampleRate)
        let rise = max(1, Int(taper * sampleRate))
        let edges = (0..<samples).map { n -> Double in
            let edge = min(n, samples - 1 - n)
            return edge < rise ? 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(rise)) : 1
        }
        let partials = Double(layer.voiceCount * (layer.bands.first?.count ?? 1) * veilPartialOffsets.count)
        let level = 0.6 * voice.gain / partials.squareRoot() * balance
        var veil = ChimeStereo(seconds: Double(output.count) / sampleRate, sampleRate: sampleRate)
        var state: UInt64 = 0x0DD5_EED5
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        for (index, chord) in steps.enumerated() {
            let start = delay + Double(index) * step - taper / 2
            let first = Int((start * sampleRate).rounded())
            let centreTime = delay + Double(index) * step + step / 2
            let contour = pulseVeilFloor + (1 - pulseVeilFloor) * min(1, ChimeBass.value(swell, at: centreTime, exponential: false))
            let envelope = (0..<samples).map { n -> Double in
                let t = Double(first + n) / sampleRate
                return edges[n] * (1 - pulseVeilGateDepth * (0.5 - 0.5 * cos(2 * Double.pi * t / period)))
            }
            for tone in chord {
                for centre in layer.bands[tone] {
                    for offset in veilPartialOffsets {
                        let frequency = centre + offset + (random() - 0.5) * 3
                        let phase = random() * 2 * Double.pi
                        let pan = (2 * random() - 1) * voice.spread
                        let amplitude = level * contour * pulseVeilWeight(centre, tilt: voice.tilt)
                        let leftGain = Float(amplitude * min(1, 1 - pan))
                        let rightGain = Float(amplitude * min(1, 1 + pan))
                        let w = 2 * Double.pi * frequency / sampleRate
                        for n in max(0, -first)..<min(samples, veil.count - first) {
                            let value = Float(sin(phase + w * Double(n)) * envelope[n])
                            veil.left[first + n] += leftGain * value
                            veil.right[first + n] += rightGain * value
                        }
                    }
                }
            }
        }
        let drive = Float(max(1, bed.drive))
        let before = max(veil.peak, 1e-9)
        let quiet = (veil.left + veil.right).reduce(Float(0)) { $0 + $1 * $1 }
        if drive > 1 {
            let norm = tanh(drive)
            for n in 0..<veil.count {
                veil.left[n] = before * tanh(drive * veil.left[n] / before) / norm
                veil.right[n] = before * tanh(drive * veil.right[n] / before) / norm
            }
        }
        let loud = (veil.left + veil.right).reduce(Float(0)) { $0 + $1 * $1 }
        let restore = loud > 0 ? (quiet / loud).squareRoot() : 1
        output.mix(veil, gain: restore, sampleRate: sampleRate)
    }

    enum Handshake: String, Sendable, CaseIterable {
        case pulse
        case coded

        var design: ChimeDesign {
            var design = ChimeDesign(style: ChimeSynth.shipping)
            switch self {
            case .pulse:
                design.voice.enabled = false
            case .coded:
                design.voice.followsPulse = true
                design.carrierLevelDB = ChimeReplay.carrierBoostDB
            }
            return design
        }
    }

    static func renderHandshake(_ code: ChimeCode, _ handshake: Handshake, sampleRate: Double) -> ChimeStereo {
        renderHandshake(code, design: handshake.design, sampleRate: sampleRate)
    }
}

struct ChimeReplay: Sendable {
    enum Trigger: Sendable {
        case opening
        case playSound
        case automatic
    }

    static let automaticDelay: Double = 18
    static let carrierBoostDB = 6.0

    static func handshake(for trigger: Trigger) -> ChimeSynth.Handshake {
        trigger == .opening ? .pulse : .coded
    }

    static func carrierGain(for trigger: Trigger) -> Float {
        trigger == .opening ? 1 : Float(pow(10, carrierBoostDB / 20))
    }

    private(set) var openedAt: Double?
    private(set) var automaticUsed = false
    private(set) var phoneEngaged = false

    mutating func opened(at time: Double) {
        guard openedAt == nil else { return }
        openedAt = time
    }

    mutating func phoneFound() {
        phoneEngaged = true
    }

    mutating func replayed() {
        automaticUsed = true
    }

    mutating func automaticIsDue(at time: Double) -> Bool {
        guard let openedAt, !automaticUsed, !phoneEngaged, time - openedAt >= Self.automaticDelay else { return false }
        automaticUsed = true
        return true
    }
}

struct CarrierOscillator {
    private let frequencies: [Double]
    private let samplesPerSymbol: Double
    private let glideSamples: Double
    private let sampleRate: Double
    private var phase: Double = 0
    private var position: Double = 0

    init(code: ChimeCode, sampleRate: Double, layer: ChimeLayer = .carrier) {
        frequencies = layer.steps(for: code).map { layer.tones[$0[0]] }
        samplesPerSymbol = layer.symbolDuration * sampleRate
        glideSamples = 0.006 * sampleRate
        self.sampleRate = sampleRate
    }

    mutating func next() -> Float {
        let count = frequencies.count
        let symbol = min(count - 1, Int(position / samplesPerSymbol))
        let within = position - Double(symbol) * samplesPerSymbol
        let half = glideSamples / 2
        var frequency = frequencies[symbol]
        if within < half {
            let earlier = frequencies[(symbol + count - 1) % count]
            let weight = 0.5 - 0.5 * cos(Double.pi * (within + half) / glideSamples)
            frequency = earlier + (frequency - earlier) * weight
        } else if within > samplesPerSymbol - half {
            let later = frequencies[(symbol + 1) % count]
            let weight = 0.5 - 0.5 * cos(Double.pi * (within - (samplesPerSymbol - half)) / glideSamples)
            frequency += (later - frequency) * weight
        }
        phase += 2 * Double.pi * frequency / sampleRate
        if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        position += 1
        if position >= samplesPerSymbol * Double(count) { position -= samplesPerSymbol * Double(count) }
        return Float(sin(phase))
    }

    static func render(_ code: ChimeCode, sampleRate: Double, seconds: Double, layer: ChimeLayer = .carrier, level: Float = ChimeSynth.carrierLevel) -> [Float] {
        var oscillator = CarrierOscillator(code: code, sampleRate: sampleRate, layer: layer)
        let count = Int(seconds * sampleRate)
        let fade = 0.4 * sampleRate
        return (0..<count).map { n in
            let position = Double(n)
            let edge = min(position, Double(count - 1) - position)
            let gain = edge < fade ? 0.5 - 0.5 * cos(Double.pi * edge / fade) : 1
            return oscillator.next() * level * Float(gain)
        }
    }
}

// MARK: - Analysis

final class ChimeSpectrumAnalyzer {
    let size: Int
    let hop: Int
    let binHz: Double
    let lowBin: Int
    let highBin: Int

    private(set) var frames: [[Float]] = []
    private(set) var firstFrame = 0
    var endFrame: Int { firstFrame + frames.count }

    private let maximumFrames: Int
    private let setup: FFTSetup
    private let log2Size: vDSP_Length
    private let window: [Float]
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private var windowed: [Float]
    private var pending: [Float] = []
    private var pendingOffset = 0

    init(size: Int, hop: Int, sampleRate: Double, lowHz: Double, highHz: Double, maximumFrames: Int) {
        self.size = size
        self.hop = hop
        self.maximumFrames = maximumFrames
        binHz = sampleRate / Double(size)
        lowBin = max(1, Int(lowHz / binHz))
        highBin = min(size / 2 - 1, Int(ceil(highHz / binHz)))
        log2Size = vDSP_Length(log2(Double(size)).rounded())
        setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        real = .allocate(capacity: size / 2)
        imaginary = .allocate(capacity: size / 2)
        windowed = [Float](repeating: 0, count: size)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        real.deallocate()
        imaginary.deallocate()
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        pending.append(contentsOf: samples)
        while pending.count - pendingOffset >= size {
            analyse(at: pendingOffset)
            pendingOffset += hop
        }
        if pendingOffset > 1 << 15 {
            pending.removeFirst(pendingOffset)
            pendingOffset = 0
        }
        if frames.count > maximumFrames {
            let excess = frames.count - maximumFrames
            frames.removeFirst(excess)
            firstFrame += excess
        }
    }

    func frame(_ index: Int) -> [Float]? {
        let local = index - firstFrame
        guard local >= 0, local < frames.count else { return nil }
        return frames[local]
    }

    private func analyse(at offset: Int) {
        pending.withUnsafeBufferPointer { source in
            vDSP_vmul(source.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(size))
        }
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        windowed.withUnsafeBufferPointer { samples in
            samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complex in
                vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(size / 2))
            }
        }
        vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
        var power = [Float](repeating: 0, count: highBin - lowBin + 1)
        for bin in lowBin...highBin {
            power[bin - lowBin] = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
        }
        frames.append(power)
    }
}

final class ChimeLayerDetector {
    struct Candidate {
        let code: ChimeCode
        let changes: Int
        let score: Float
        let startFrame: Int
    }

    let layer: ChimeLayer
    private let analyzer: ChimeSpectrumAnalyzer
    private let framesPerSymbol: Double
    private let halfWidth: Int
    private let spanFrames: Int
    private var nextStart = 0
    private var baseline: [[Float]] = []
    private var baselineFirst = 0
    private var scaledEnergies: [Int: [Float]] = [:]
    private var scaledFor: Double = .nan
    private var spreadCache: [Double: [Int: [Float]]] = [:]

    init(layer: ChimeLayer, sampleRate: Double) {
        self.layer = layer
        let hop = max(1, Int((sampleRate * 0.005).rounded()))
        framesPerSymbol = layer.symbolDuration * sampleRate / Double(hop)
        halfWidth = max(1, Int(layer.slotWidth * framesPerSymbol))
        let maximumScale = layer.timeScales.max() ?? 1
        spanFrames = Int(ceil(maximumScale * Double(layer.frameStepCount) * framesPerSymbol + framesPerSymbol / 2)) + halfWidth + 2
        let lowHz = layer.lowestFrequency * (1 - layer.pooling) / (layer.timeScales.max() ?? 1) - 50
        let highHz = layer.highestFrequency * (1 + layer.pooling) / (layer.timeScales.min() ?? 1) + 50
        analyzer = ChimeSpectrumAnalyzer(
            size: layer.fftSize,
            hop: hop,
            sampleRate: sampleRate,
            lowHz: lowHz,
            highHz: highHz,
            maximumFrames: spanFrames * 2 + 200
        )
    }

    func process(_ samples: UnsafeBufferPointer<Float>) -> [Candidate] {
        analyzer.append(samples)
        if layer.isSpread {
            let first = analyzer.firstFrame
            for scale in spreadCache.keys { spreadCache[scale] = spreadCache[scale]?.filter { $0.key >= first } }
        }
        updateBaseline()
        var found: [Candidate] = []
        if nextStart < analyzer.firstFrame { nextStart = analyzer.firstFrame }
        while nextStart + spanFrames < analyzer.endFrame {
            guard preambleMatches(at: nextStart) else {
                nextStart += 1
                continue
            }
            if let candidate = decode(from: nextStart) {
                found.append(candidate)
                nextStart = candidate.startFrame + Int(Double(layer.frameStepCount) * framesPerSymbol * 0.9)
            } else {
                nextStart += max(1, Int(framesPerSymbol / 2))
            }
        }
        return found
    }

    private func updateBaseline() {
        if baseline.isEmpty { baselineFirst = analyzer.firstFrame }
        if baselineFirst < analyzer.firstFrame {
            let drop = min(baseline.count, analyzer.firstFrame - baselineFirst)
            baseline.removeFirst(drop)
            baselineFirst += drop
        }
        while baselineFirst + baseline.count < analyzer.endFrame {
            baseline.append(toneEnergies(frame: baselineFirst + baseline.count, scale: 1) ?? [])
        }
    }

    private func toneEnergies(frame index: Int, scale: Double) -> [Float]? {
        if layer.isSpread { return spreadEnergies(frame: index, scale: scale) }
        if scale == 1, index >= baselineFirst, index < baselineFirst + baseline.count {
            let cached = baseline[index - baselineFirst]
            if !cached.isEmpty { return cached }
        }
        if scale != 1 {
            if scale != scaledFor {
                scaledEnergies.removeAll(keepingCapacity: true)
                scaledFor = scale
            }
            if let cached = scaledEnergies[index] { return cached }
        }
        guard let power = analyzer.frame(index) else { return nil }
        let energies = layer.tones.map { tone -> Float in
            let frequency = tone / scale
            let low = max(analyzer.lowBin, Int(floor(frequency * (1 - layer.pooling) / analyzer.binHz)))
            let high = min(analyzer.highBin, Int(ceil(frequency * (1 + layer.pooling) / analyzer.binHz)))
            guard low <= high else { return 0 }
            var peak: Float = 0
            for bin in low...high { peak = max(peak, power[bin - analyzer.lowBin]) }
            return peak
        }
        if scale != 1 { scaledEnergies[index] = energies }
        return energies
    }

    private func rawSlotEnergies(start: Int, symbol: Int, scale: Double) -> [Float]? {
        let centre = Int((Double(start) + scale * (Double(symbol) + layer.samplePoint) * framesPerSymbol).rounded())
        var sum = [Float](repeating: 0, count: layer.tones.count)
        for frame in (centre - halfWidth)...(centre + halfWidth) {
            guard let energies = toneEnergies(frame: frame, scale: scale) else { return nil }
            for i in sum.indices { sum[i] += energies[i] }
        }
        return sum
    }

    private func slotEnergies(start: Int, symbol: Int, scale: Double) -> [Float]? {
        guard var current = rawSlotEnergies(start: start, symbol: symbol, scale: scale) else { return nil }
        guard layer.tailSuppression > 0,
              let earlier = rawSlotEnergies(start: start, symbol: symbol - 1, scale: scale) else { return current }
        for i in current.indices {
            current[i] = max(current[i] - layer.tailSuppression * earlier[i], current[i] * 0.05)
        }
        return current
    }

    private func spreadEnergies(frame index: Int, scale: Double) -> [Float]? {
        if let cached = spreadCache[scale]?[index] { return cached }
        guard let power = analyzer.frame(index) else { return nil }
        let compression = layer.bandCompression
        let energies = layer.bands.map { band -> Float in
            var sum: Float = 0
            for centre in band {
                let low = max(analyzer.lowBin, Int(ceil((centre - layer.bandHalfWidth) * (1 - layer.pooling) / scale / analyzer.binHz)))
                let high = min(analyzer.highBin, Int(floor((centre + layer.bandHalfWidth) * (1 + layer.pooling) / scale / analyzer.binHz)))
                guard low <= high else { continue }
                var part: Float = 0
                for bin in low...high { part += power[bin - analyzer.lowBin] }
                sum += compression == 1 ? part : pow(part, compression)
            }
            return sum
        }
        spreadCache[scale, default: [:]][index] = energies
        return energies
    }

    private func preambleMatches(at start: Int) -> Bool {
        guard layer.isSpread else { return preambleMatches(at: start, scale: 1) }
        return layer.timeScales.sorted { abs($0 - 1) < abs($1 - 1) }.contains { preambleMatches(at: start, scale: $0) }
    }

    private func preambleMatches(at start: Int, scale: Double) -> Bool {
        for (index, expected) in layer.preamble.enumerated() {
            guard let energies = slotEnergies(start: start, symbol: index, scale: scale) else { return false }
            for (voice, tones) in layer.voices(at: index).enumerated() {
                let values = tones.map { energies[$0] }
                let ranked = Self.rank(values)
                guard tones[ranked.top] == expected[voice], values[ranked.top] > 1e-9,
                      values[ranked.top] >= layer.minimumPreambleRatio * max(values[ranked.second], 1e-12) else { return false }
            }
        }
        return true
    }

    private static func rank(_ energies: [Float]) -> (top: Int, second: Int) {
        var top = 0
        var second = -1
        for i in 1..<energies.count {
            if energies[i] > energies[top] {
                second = top
                top = i
            } else if second < 0 || energies[i] > energies[second] {
                second = i
            }
        }
        return (top, max(second, 0))
    }

    private func decode(from start: Int) -> Candidate? {
        var best: Candidate?
        let offsets = 0...max(1, Int(framesPerSymbol / 2))
        defer {
            scaledEnergies.removeAll(keepingCapacity: true)
            scaledFor = .nan
        }
        for scale in layer.timeScales {
            for offset in offsets {
                guard let candidate = decode(start: start + offset, scale: scale) else { continue }
                if let current = best {
                    if candidate.changes < current.changes
                        || (candidate.changes == current.changes && candidate.score > current.score) {
                        best = candidate
                    }
                } else {
                    best = candidate
                }
            }
        }
        return best
    }

    private func preambleLeads(_ slots: [[Float]]) -> Bool {
        for (index, expected) in layer.preamble.enumerated() {
            for (voice, tones) in layer.voices(at: index).enumerated() where tones[Self.rank(tones.map { slots[index][$0] }).top] != expected[voice] {
                return false
            }
        }
        return true
    }

    private func decode(start: Int, scale: Double) -> Candidate? {
        var slots: [[Float]] = []
        slots.reserveCapacity(layer.frameStepCount)
        for symbol in 0..<layer.frameStepCount {
            guard let energies = slotEnergies(start: start, symbol: symbol, scale: scale) else { return nil }
            slots.append(energies)
            if !layer.normalisesTones, slots.count == layer.preamble.count, !preambleLeads(slots) { return nil }
        }
        if layer.normalisesTones { slots = Self.normalise(slots) }
        guard preambleLeads(slots) else { return nil }

        var decisions: [Int] = []
        var alternatives: [Int] = []
        var confidences: [Float] = []
        for (index, slot) in slots.enumerated().dropFirst(layer.preamble.count) {
            for tones in layer.voices(at: index) {
                let values = tones.map { slot[$0] }
                let ranked = Self.rank(values)
                decisions.append(ranked.top)
                alternatives.append(ranked.second)
                confidences.append(log(max(values[ranked.top], 1e-12) / max(values[ranked.second], 1e-12)))
            }
        }

        let weakest = confidences.indices.sorted { confidences[$0] < confidences[$1] }.prefix(3)
        let patterns: [[Int]] = [[], [0], [1], [0, 1], [2], [0, 2], [1, 2]]
        let sortedConfidences = confidences.sorted()
        let median = sortedConfidences[sortedConfidences.count / 2]
        let score = confidences.reduce(0, +)
        let voiceCount = layer.voiceCount

        for pattern in patterns where pattern.allSatisfy({ $0 < weakest.count }) {
            var trial = decisions
            for choice in pattern {
                let position = weakest[weakest.startIndex + choice]
                trial[position] = alternatives[position]
            }
            let steps = stride(from: 0, to: trial.count, by: voiceCount).map { Array(trial[$0..<($0 + voiceCount)]) }
            guard let decoded = ChimeFrame.decode(layer.symbols(fromDecisions: steps)) else { continue }
            let changes = decoded.corrections + pattern.count
            guard changes <= Self.acceptedChanges || (changes <= Self.confidentChanges && median >= Self.confidentMedian) else { continue }
            return Candidate(code: decoded.code, changes: changes, score: score, startFrame: start)
        }
        return nil
    }

    static let acceptedChanges = 3
    static let confidentChanges = 5
    static let confidentMedian: Float = 1.2

    private static func normalise(_ slots: [[Float]]) -> [[Float]] {
        guard let toneCount = slots.first?.count else { return slots }
        let keep = max(2, slots.count / (toneCount * 2))
        var levels = [Float](repeating: 1, count: toneCount)
        for tone in 0..<toneCount {
            let values = slots.map { $0[tone] }.sorted(by: >)
            levels[tone] = max(values.prefix(keep).reduce(0, +) / Float(keep), 1e-12)
        }
        return slots.map { slot in slot.indices.map { slot[$0] / levels[$0] } }
    }
}

final class ChimeDecoder {
    struct Detection: Equatable, Sendable {
        let code: ChimeCode
        let layer: ChimeLayer.Kind
        let corrections: Int
    }

    private let detectors: [ChimeLayerDetector]

    init(sampleRate: Double, layers: [ChimeLayer] = ChimeLayer.listening) {
        detectors = layers
            .filter { $0.highestFrequency * (1 + $0.pooling) < sampleRate / 2 }
            .map { ChimeLayerDetector(layer: $0, sampleRate: sampleRate) }
    }

    func process(_ samples: UnsafeBufferPointer<Float>) -> [Detection] {
        detectors.flatMap { detector in
            detector.process(samples).map {
                Detection(code: $0.code, layer: detector.layer.kind, corrections: $0.changes)
            }
        }
    }

    func process(_ samples: [Float]) -> [Detection] {
        samples.withUnsafeBufferPointer { process($0) }
    }
}
