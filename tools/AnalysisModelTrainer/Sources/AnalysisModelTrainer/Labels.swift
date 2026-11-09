import Foundation

enum Split {
    case train, validation, test, excluded

    static func corpus(_ index: Int) -> Split {
        if index % 5 == 0 { return .test }
        if index % 10 == 1 { return .validation }
        return .train
    }
}

final class LabelTrack {
    let source: String
    let index: Int
    let frames: Int
    let bands: Int
    let mel: [Float16]
    let curve: [Float]
    let timbreCount: Int
    let timbreDim: Int
    let timbre: [Float16]
    let downbeats: [Double]
    let classWindows: Int
    let classCount: Int
    let classes: [Float16]
    let sampleCount: Int
    let seconds: Double
    var split: Split
    var excluded: [(Double, Double)] = []
    lazy var sung: [Bool] = VocalRules.sung(curve, bars: downbeats, end: seconds)

    var key: String { "\(source)/\(String(format: "%04d", index))" }

    init(url: URL, source: String, index: Int) throws {
        let data = try Data(contentsOf: url)
        var offset = 4
        func read<T>(_ type: T.Type) -> T {
            defer { offset += MemoryLayout<T>.size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
        func readArray<T>(_ type: T.Type, _ count: Int) -> [T] {
            defer { offset += count * MemoryLayout<T>.size }
            return [T](unsafeUninitializedCapacity: count) { buffer, initialised in
                data.withUnsafeBytes { raw in
                    _ = memcpy(buffer.baseAddress!, raw.baseAddress! + offset, count * MemoryLayout<T>.size)
                }
                initialised = count
            }
        }
        guard data.count > 56, String(decoding: data.prefix(4), as: UTF8.self) == "SLB2" else { throw CocoaError(.fileReadCorruptFile) }
        self.source = source
        self.index = index
        frames = Int(read(Int32.self))
        bands = Int(read(Int32.self))
        let curveCount = Int(read(Int32.self))
        timbreCount = Int(read(Int32.self))
        timbreDim = Int(read(Int32.self))
        let downbeatCount = Int(read(Int32.self))
        classWindows = Int(read(Int32.self))
        classCount = Int(read(Int32.self))
        sampleCount = Int(read(Int64.self))
        seconds = read(Double.self)
        mel = readArray(Float16.self, frames * bands)
        curve = readArray(Float.self, curveCount)
        timbre = readArray(Float16.self, timbreCount * timbreDim)
        downbeats = readArray(Double.self, downbeatCount)
        classes = readArray(Float16.self, classWindows * classCount)
        split = source == "corpus" ? Split.corpus(index) : .train
    }

    func melValue(_ t: Int, _ c: Int) -> Float { Float(mel[t * bands + c]) }

    func isExcluded(from: Double, to: Double) -> Bool {
        excluded.contains { $0.0 < to && $0.1 > from }
    }

    var hours: Double { seconds / 3600 }
}

func loadTracks(_ root: URL, sources: [String]) throws -> [LabelTrack] {
    var tracks: [LabelTrack] = []
    for source in sources {
        let directory = root.appendingPathComponent(source)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
        for url in files.filter({ $0.pathExtension == "lb2" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let index = Int(url.deletingPathExtension().lastPathComponent),
                  let track = try? LabelTrack(url: url, source: source, index: index), track.frames > 0 else { continue }
            tracks.append(track)
        }
    }
    let exclusions = root.appendingPathComponent("exclusions.tsv")
    if let text = try? String(contentsOf: exclusions, encoding: .utf8) {
        var byKey: [String: [(Double, Double)]] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 3, let a = Double(parts[1]), let b = Double(parts[2]) else { continue }
            byKey[String(parts[0]), default: []].append((a, b))
        }
        for track in tracks where track.split == .train {
            guard let ranges = byKey[track.key] else { continue }
            track.excluded = ranges
            if ranges.contains(where: { $0.0 <= 0 && $0.1 >= track.seconds }) { track.split = .excluded }
        }
    }
    return tracks
}

func subsample(_ tracks: [LabelTrack], hours: Double?) -> [LabelTrack] {
    guard let hours else { return tracks }
    var rng = SplitMix(seed: 7)
    let shuffled = tracks.shuffled(using: &rng)
    var total = 0.0
    var out: [LabelTrack] = []
    for track in shuffled where total < hours {
        out.append(track)
        total += track.hours
    }
    return out
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
