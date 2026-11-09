import AVFoundation
import Foundation

// MARK: - Manifest

enum ABJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ABJSON])
    case object([String: ABJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([ABJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ABJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    static func from<T: Encodable>(_ value: T) -> ABJSON? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(ABJSON.self, from: data)
    }
}

struct ABTrack: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    var source: String?
    var bpm: Double?
}

struct ABRegion: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
}

struct ABProvenance: Codable, Equatable, Sendable {
    var analysisVersion: String
    var engineCommit: String?
    var lane: String?
    var renderer: String?
    var notes: String?
}

struct ABRender: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case transition, long }

    var id: String
    var pair: String
    var kind: Kind
    var variant: String
    var audio: String
    var transitions: [ABRegion]
    var tracks: [ABTrack]
    var plans: [ABJSON]
    var executions: [ABJSON]?
    var provenance: ABProvenance
}

struct ABManifest: Codable, Equatable, Sendable {
    static let currentFormat = "automix-ab/1"

    var format = ABManifest.currentFormat
    var name: String
    var created: Date
    var renders: [ABRender]

    static func load(_ url: URL) throws -> ABManifest {
        try ABCoding.decoder.decode(ABManifest.self, from: Data(contentsOf: url))
    }

    func save(_ url: URL) throws {
        try ABCoding.encoder.encode(self).write(to: url, options: .atomic)
    }

    mutating func upsert(_ render: ABRender) {
        if let index = renders.firstIndex(where: { $0.id == render.id }) { renders[index] = render } else { renders.append(render) }
    }

    var variants: [String] { Array(Set(renders.map(\.variant))).sorted() }

    static func audioURL(_ render: ABRender, manifest: URL) -> URL {
        render.audio.hasPrefix("/") ? URL(fileURLWithPath: render.audio) : manifest.deletingLastPathComponent().appendingPathComponent(render.audio)
    }
}

enum ABCoding {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - Results

enum ABFault: String, Codable, CaseIterable, Sendable {
    case flamPhase, muddyBass, bassHole, vocalClash, levelDipSwell, pumping, badLanding, tooLong, tooShort, gimmickyEffect

    var label: String {
        switch self {
        case .flamPhase: return "Flam or phase"
        case .muddyBass: return "Muddy bass"
        case .bassHole: return "Bass hole"
        case .vocalClash: return "Vocal clash"
        case .levelDipSwell: return "Level dip or swell"
        case .pumping: return "Pumping"
        case .badLanding: return "Bad landing"
        case .tooLong: return "Too long"
        case .tooShort: return "Too short"
        case .gimmickyEffect: return "Gimmicky effect"
        }
    }
}

enum ABPreference: String, Codable, Sendable { case a, b, neither = "none" }

struct ABJudgment: Codable, Equatable, Sendable {
    var trial: Int
    var pair: String
    var kind: ABRender.Kind
    var aRender: String
    var bRender: String
    var aVariant: String
    var bVariant: String
    var preference: ABPreference
    var preferredVariant: String?
    var aFaults: [ABFault]
    var bFaults: [ABFault]
    var note: String?
    var aLoudnessLUFS: Double
    var bLoudnessLUFS: Double
    var aGainDB: Double
    var bGainDB: Double
    var listenedA: Double
    var listenedB: Double
    var tracks: [ABTrack]
    var date: Date
}

struct ABSession: Codable, Equatable, Sendable {
    var format = "automix-ab-results/1"
    var manifest: String
    var manifestName: String
    var session: UUID
    var seed: UInt64
    var mode: ABRender.Kind
    var variants: [String]
    var padSeconds: Double
    var started: Date
    var judgments: [ABJudgment]
}

// MARK: - Trials

struct ABRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func shuffle<T>(_ xs: inout [T]) {
        guard xs.count > 1 else { return }
        for i in stride(from: xs.count - 1, to: 0, by: -1) { xs.swapAt(i, below(i + 1)) }
    }
}

struct ABTrial: Identifiable, Equatable {
    var id: Int
    var pair: String
    var kind: ABRender.Kind
    var a: ABRender
    var b: ABRender
    var aWindow: ABRegion
    var bWindow: ABRegion
}

enum ABTrials {
    static func window(_ render: ABRender, pad: Double, duration: Double) -> ABRegion {
        guard render.kind == .transition, let first = render.transitions.first, let last = render.transitions.last else {
            return ABRegion(start: 0, end: duration)
        }
        return ABRegion(start: max(0, first.start - pad), end: min(duration, last.end + pad))
    }

    static func build(_ manifest: ABManifest, manifestURL: URL, kind: ABRender.Kind, variants: [String], pad: Double, rng: inout ABRandom) throws -> [ABTrial] {
        guard variants.count == 2 else { throw ABError("choose exactly two variants; this manifest has: \(manifest.variants.joined(separator: ", "))") }
        var pairs: [String: [String: ABRender]] = [:]
        for r in manifest.renders where r.kind == kind && variants.contains(r.variant) { pairs[r.pair, default: [:]][r.variant] = r }
        var trials: [ABTrial] = []
        for pair in pairs.keys.sorted() {
            guard let x = pairs[pair]?[variants[0]], let y = pairs[pair]?[variants[1]] else { continue }
            let flip = rng.below(2) == 1
            let a = flip ? y : x
            let b = flip ? x : y
            let da = try ABAudio.duration(ABManifest.audioURL(a, manifest: manifestURL))
            let db = try ABAudio.duration(ABManifest.audioURL(b, manifest: manifestURL))
            trials.append(ABTrial(id: 0, pair: pair, kind: kind, a: a, b: b, aWindow: window(a, pad: pad, duration: da), bWindow: window(b, pad: pad, duration: db)))
        }
        rng.shuffle(&trials)
        for k in trials.indices { trials[k].id = k + 1 }
        return trials
    }
}

struct ABError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

// MARK: - Loudness (ITU-R BS.1770-4)

enum ABAudio {
    static func duration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    static func read(_ url: URL, window: ABRegion) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(max(0, window.start) * rate)
        let count = AVAudioFrameCount(max(0, min(Double(file.length - start), (window.end - window.start) * rate)))
        file.framePosition = start
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return ([], rate) }
        try file.read(into: buffer, frameCount: count)
        let n = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: n)) }
        return (channels, rate)
    }

    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        func run(_ x: [Float]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in x.indices {
                let v = Double(x[i])
                let o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = v; y2 = y1; y1 = o
                y[i] = o
            }
            return y
        }
        func run(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in x.indices {
                let v = x[i]
                let o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = v; y2 = y1; y1 = o
                y[i] = o
            }
            return y
        }
    }

    static func kWeighting(_ fs: Double) -> (Biquad, Biquad) {
        let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        var k = tan(.pi * f0 / fs)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        let f1 = 38.13547087602444, q1 = 0.5003270373238773
        k = tan(.pi * f1 / fs)
        a0 = 1 + k / q1 + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q1 + k * k) / a0)
        return (shelf, highPass)
    }

    static func integratedLoudness(_ channels: [[Float]], sampleRate fs: Double) -> Double {
        guard let n = channels.first?.count, n > Int(fs * 0.4) else { return -70 }
        let (shelf, highPass) = kWeighting(fs)
        let weighted = channels.prefix(2).map { highPass.run(shelf.run($0)) }
        let block = Int(fs * 0.4), hop = Int(fs * 0.1)
        var energies: [Double] = []
        var start = 0
        while start + block <= n {
            var z = 0.0
            for ch in weighted {
                var s = 0.0
                for i in start..<(start + block) { s += ch[i] * ch[i] }
                z += s / Double(block)
            }
            energies.append(z)
            start += hop
        }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-12)) }
        let absolute = energies.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return -70 }
        let relative = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relative }
        guard !gated.isEmpty else { return -70 }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    static func loudness(_ url: URL, window: ABRegion) throws -> Double {
        let (channels, rate) = try read(url, window: window)
        return integratedLoudness(channels, sampleRate: rate)
    }

    static func matchedGains(_ a: Double, _ b: Double) -> (Double, Double) {
        let target = min(a, b)
        return (target - a, target - b)
    }
}
