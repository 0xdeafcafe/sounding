import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

struct AIGrid: Decodable {
    let beats: [Double]
    let downbeats: [Double]
    let barDownbeats: [Double]
    let bpm: Double?
    let confidence: Double
    let downbeatConfidence: Double
    let beatsPerBar: Int?

    var trusted: Bool { confidence >= 0.8 && downbeatConfidence >= 0.5 && beatsPerBar == 4 && barDownbeats.count >= 16 }
}

struct Annotation: Decodable {
    let segments: [String]
    var boundaries: [Int] {
        segments.compactMap { s in s.split(separator: " ").first?.split(separator: "-").first.flatMap { Int($0) } }.filter { $0 > 0 }
    }
}

struct CachedTrack: Decodable {
    let result: BeatTrackerResult
}

func readTracks(_ path: String) -> [(id: String, path: String)] {
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (String(format: "c%03d", index + 1), parts[1])
    }
}

func cacheName(_ path: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
    return String(format: "%016llx", hash)
}

// MARK: - Feature cache

func write(_ features: BeatTrackerFeatures, to url: URL) throws {
    var data = Data()
    func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
    func array(_ a: [Float]) {
        append(Int64(a.count))
        a.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: a.count * 4)) }
    }
    append(Int64(features.hop))
    append(features.analysedSeconds)
    for a in [features.low, features.lowMid, features.mid, features.high, features.chroma, features.bandEnergy, features.level] { array(a) }
    try data.write(to: url)
}

func read(_ url: URL) -> BeatTrackerFeatures? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    var offset = 0
    func take<T>(_: T.Type) -> T {
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += MemoryLayout<T>.size
        return v
    }
    func array() -> [Float] {
        let n = Int(take(Int64.self))
        var out = [Float](repeating: 0, count: n)
        out.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset..<(offset + n * 4)])) } }
        offset += n * 4
        return out
    }
    let hop = Int(take(Int64.self))
    let seconds = take(Double.self)
    let arrays = (0..<7).map { _ in array() }
    return BeatTrackerFeatures(
        hop: hop, sampleRate: BeatTracker.sampleRate, slowStride: BeatTracker.slowStrideHops,
        low: arrays[0], lowMid: arrays[1], mid: arrays[2], high: arrays[3],
        chroma: arrays[4], bandEnergy: arrays[5], analysedSeconds: seconds, level: arrays[6]
    )
}

func extract(_ path: String) async throws -> BeatTrackerFeatures {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw BeatTracker.TrackerError.noAudioTrack }
    let assetDuration = (try? await asset.load(.duration).seconds) ?? 0
    let duration = min(BeatTracker.maxAnalysisSeconds, assetDuration.isFinite && assetDuration > 0 ? assetDuration : BeatTracker.maxAnalysisSeconds)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: BeatTracker.sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
    ])
    reader.add(output)
    reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 1000))
    reader.startReading()
    let extractor = BeatTrackerFeatureExtractor(hop: BeatTracker.hop(forDuration: duration, options: .init()), expectedSeconds: duration)
    let cap = Int(BeatTracker.sampleRate * duration)
    var scratch = [Float]()
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let count = CMBlockBufferGetDataLength(block) / 4
        guard count > 0 else { continue }
        if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
        scratch.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }
        let usable = min(count, max(0, cap - extractor.consumedSamples))
        scratch.withUnsafeBufferPointer { extractor.consume(UnsafeBufferPointer(rebasing: $0[0..<usable])) }
        if extractor.consumedSamples >= cap { break }
    }
    reader.cancelReading()
    return extractor.finish()
}

// MARK: - Metrics

func nearest(_ values: [Double], _ t: Double) -> Int {
    var lo = 0, hi = values.count
    while lo < hi { let m = (lo + hi) / 2; if values[m] < t { lo = m + 1 } else { hi = m } }
    if lo == 0 { return 0 }
    if lo == values.count { return values.count - 1 }
    return abs(values[lo] - t) < abs(values[lo - 1] - t) ? lo : lo - 1
}

func fMeasure(_ reference: [Double], _ estimate: [Double], tolerance: Double = 0.07) -> Double {
    guard !reference.isEmpty, !estimate.isEmpty else { return 0 }
    var hits = 0
    for r in reference where abs(estimate[nearest(estimate, r)] - r) <= tolerance { hits += 1 }
    let p = Double(hits) / Double(estimate.count), q = Double(hits) / Double(reference.count)
    return p + q == 0 ? 0 : 2 * p * q / (p + q)
}

func barOffsets(tracker: [Double], downbeats: [Double], ai: AIGrid) -> [Int] {
    var counts = [0, 0, 0, 0]
    let aiDown = Set(ai.barDownbeats)
    var lastDown = -1
    var position = [Int](repeating: -1, count: ai.beats.count)
    for (i, b) in ai.beats.enumerated() {
        if aiDown.contains(b) { lastDown = i }
        if lastDown >= 0 { position[i] = (i - lastDown) % 4 }
    }
    for d in downbeats {
        let i = nearest(ai.beats, d)
        guard abs(ai.beats[i] - d) <= 0.07, position[i] >= 0 else { continue }
        counts[position[i]] += 1
    }
    return counts
}

func kickAt(_ f: BeatTrackerFeatures, _ beats: [Double]) -> Double {
    let low = BeatTracker.normalisedByMean(f.low)
    let r = max(2, Int((0.02 * f.frameRate).rounded()))
    let v = beats.compactMap { t -> Double? in
        let i = Int(f.frame(ofTime: t).rounded())
        guard i >= r, i < low.count - r else { return nil }
        return Double(low[(i - r)...(i + r)].max() ?? 0)
    }
    return v.reduce(0, +) / Double(max(1, v.count))
}

func lagSeconds(_ tracker: [Double], _ ai: [Double]) -> Double {
    guard ai.count > 8, tracker.count > 8 else { return 0 }
    let period = (ai[ai.count - 1] - ai[0]) / Double(ai.count - 1)
    let diffs = tracker.map { t in t - ai[nearest(ai, t)] }.filter { abs($0) < period / 2 }.sorted()
    return diffs.isEmpty ? 0 : diffs[diffs.count / 2]
}

func kickContrast(_ f: BeatTrackerFeatures, beats: [Double]) -> Double {
    let low = BeatTracker.normalisedByMean(f.low)
    func at(_ t: Double) -> Double {
        let i = Int(f.frame(ofTime: t).rounded())
        guard i >= 3, i < low.count - 3 else { return 0 }
        return Double(low[(i - 3)...(i + 3)].max() ?? 0)
    }
    let on = beats.map(at)
    let off = zip(beats, beats.dropFirst()).map { at(($0 + $1) / 2) }
    let a = on.reduce(0, +) / Double(max(1, on.count)), b = off.reduce(0, +) / Double(max(1, off.count))
    return a / max(1e-6, b)
}

func s(_ x: Double, _ d: Int = 3) -> String { String(format: "%.\(d)f", x) }

// MARK: - Modes

let args = CommandLine.arguments
let mode = args[1]
let root = "/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d"
let tracksPath = ProcessInfo.processInfo.environment["TRACKS"] ?? "\(root)/automix-corpus/tracks.tsv"
let featureDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FEATURES"] ?? "\(root)/downbeat-lab/features")
let aiDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BEATTHIS"] ?? "\(root)/downbeat-lab/beatthis")
let tracks = readTracks(tracksPath)

switch mode {
case "extract":
    let workers = 4
    await withTaskGroup(of: Void.self) { group in
        for w in 0..<workers {
            group.addTask {
                for (k, t) in tracks.enumerated() where k % workers == w {
                    let url = featureDir.appendingPathComponent("\(t.id).bin")
                    if FileManager.default.fileExists(atPath: url.path) { continue }
                    let start = Date()
                    do {
                        let f = try await extract(t.path)
                        try write(f, to: url)
                        print("\(t.id) \(s(f.analysedSeconds, 0)) s in \(s(Date().timeIntervalSince(start), 2)) s")
                    } catch {
                        print("\(t.id) failed: \(error)")
                    }
                }
            }
        }
    }
case "score":
    let out = args[2]
    var annotations: [String: Annotation] = [:]
    for set in ["A", "B1", "B2", "C"] {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(root)/arrangement/annotations-\(set).json")),
           let a = try? JSONDecoder().decode([String: Annotation].self, from: data) { annotations.merge(a) { x, _ in x } }
    }
    let header = ["id", "bpm", "aiBpm", "beatConf", "downConf", "conf", "parityConf", "phaseConf", "clarity", "salient", "residualMs",
                  "parityS", "parityA", "halfS", "halfA", "chgS", "chgA", "kick", "tempoRel", "beatRel", "phaseRel", "parityRel", "barRel",
                  "aiConf", "aiDown", "aiTrusted", "beatF", "downF", "off0", "off1", "off2", "off3", "annBound", "annHit", "analyseMs", "seconds", "lagMs", "beatFLag", "kickTr", "kickAI"]
    var lines = [header.joined(separator: "\t")]
    var totalMs = 0.0, totalAudio = 0.0
    for t in tracks {
        guard let f = read(featureDir.appendingPathComponent("\(t.id).bin")) else { continue }
        let start = Date()
        let (r, d) = BeatTracker.analyzeWithDiagnostics(f, tempoPrior: nil)
        let ms = Date().timeIntervalSince(start) * 1000
        totalMs += ms
        totalAudio += f.analysedSeconds
        let ai = (try? Data(contentsOf: aiDir.appendingPathComponent("\(t.id).json"))).flatMap { try? JSONDecoder().decode(AIGrid.self, from: $0) }
        let ev = r.parityEvidence ?? [0, 0, 0, 0, 0, 0]
        var row: [String] = [t.id, s(r.bpm ?? 0, 2), s(ai?.bpm ?? 0, 2), s(r.beatConfidence), s(r.downbeatConfidence), s(r.confidence),
                             s(r.parityConfidence ?? 0), s(r.phaseConfidence ?? r.downbeatConfidence), s(d.tempoClarity), s(d.salientFraction), s(d.residualMs, 1),
                             s(ev[0]), s(ev[1]), s(ev[4]), s(ev[5]), s(ev[2]), s(ev[3]), s(kickContrast(f, beats: r.beats), 2),
                             r.isTempoReliable ? "1" : "0", r.isBeatReliable ? "1" : "0", r.isPhaseReliable ? "1" : "0", r.isParityReliable ? "1" : "0", r.isBarPhaseReliable ? "1" : "0"]
        if let ai {
            let o = barOffsets(tracker: r.beats, downbeats: r.downbeats, ai: ai)
            row += [s(ai.confidence), s(ai.downbeatConfidence), ai.trusted ? "1" : "0", s(fMeasure(ai.beats, r.beats)), s(fMeasure(ai.barDownbeats, r.downbeats))] + o.map(String.init)
        } else {
            row += ["", "", "", "", "", "", "", "", ""]
        }
        if let a = annotations[t.id],
           let data = try? Data(contentsOf: URL(fileURLWithPath: "\(root)/automix-corpus/cache/beattracker-v2/\(cacheName(t.path)).json")),
           let cached = try? JSONDecoder().decode(CachedTrack.self, from: data) {
            let times = a.boundaries.compactMap { $0 < cached.result.downbeats.count ? cached.result.downbeats[$0] : nil }
            let hits = times.filter { !r.downbeats.isEmpty && abs(r.downbeats[nearest(r.downbeats, $0)] - $0) <= 0.07 }.count
            row += [String(times.count), String(hits)]
        } else {
            row += ["", ""]
        }
        row += [s(ms, 1), s(f.analysedSeconds, 1)]
        if let ai { let lag = lagSeconds(r.beats, ai.beats); row += [s(lag * 1000, 1), s(fMeasure(ai.beats, r.beats.map { $0 - lag })), s(kickAt(f, r.beats), 2), s(kickAt(f, ai.beats), 2)] }
        lines.append(row.joined(separator: "\t"))
    }
    try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    print("tracks \(lines.count - 1), analyse \(s(totalMs / 1000, 1)) s for \(s(totalAudio / 60, 0)) min audio (\(s(totalAudio / max(1e-9, totalMs / 1000), 0))x realtime)")
case "rekordbox":
    let out = URL(fileURLWithPath: args[2])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let byPath = Dictionary(tracks.map { (($0.path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping, $0.id) }, uniquingKeysWith: { a, _ in a })
    let enumerator = FileManager.default.enumerator(atPath: "/Users/afr/Library/Pioneer/rekordbox/share")
    var matched = 0, files = 0
    while let rel = enumerator?.nextObject() as? String {
        guard rel.hasSuffix("ANLZ0000.DAT") else { continue }
        files += 1
        let url = URL(fileURLWithPath: "/Users/afr/Library/Pioneer/rekordbox/share/" + rel)
        guard let data = try? Data(contentsOf: url), let file = try? ANLZCodec.read(data).file,
              let path = file.path, let grid = file.beatGrid, grid.count >= 16,
              let id = byPath[(path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping] else {
            if files <= 5 { print("unmatched", (try? ANLZCodec.read(Data(contentsOf: url)).file.path) ?? "nil") }
            continue
        }
        let beats = grid.map { Double($0.timeMillis) / 1000 }
        let downs = grid.filter { $0.beatNumber == 1 }.map { Double($0.timeMillis) / 1000 }
        let bpm = Double(grid[grid.count / 2].tempo) / 100
        let json: [String: Any] = ["beats": beats, "downbeats": downs, "barDownbeats": downs, "bpm": bpm, "confidence": 1.0, "downbeatConfidence": 1.0, "beatsPerBar": 4]
        try JSONSerialization.data(withJSONObject: json).write(to: out.appendingPathComponent("\(id).json"))
        matched += 1
    }
    print("ANLZ files \(files), matched corpus tracks \(matched)")
case "fitoff":
    let rbDir = URL(fileURLWithPath: "\(root)/downbeat-lab/rekordbox")
    let btDir = URL(fileURLWithPath: "\(root)/downbeat-lab/beatthis")
    var samples: [OffSample] = []
    for t in tracks {
        guard let f = read(featureDir.appendingPathComponent("\(t.id).bin")),
              let rb = (try? Data(contentsOf: rbDir.appendingPathComponent("\(t.id).json"))).flatMap({ try? JSONDecoder().decode(AIGrid.self, from: $0) }) else { continue }
        let (r, d) = BeatTracker.analyzeWithDiagnostics(f, tempoPrior: nil)
        guard let bpm = r.bpm, d.offbeat.count == 6 else { continue }
        let period = 60 / bpm
        let lag = lagSeconds(r.beats, rb.beats)
        guard fMeasure(rb.beats, r.beats.map { $0 - lag }) >= 0.8 else { continue }
        let off = abs(lag) / period >= 0.4
        guard off || abs(lag) < 0.06 else { continue }
        var confirmed = false
        if let bt = (try? Data(contentsOf: btDir.appendingPathComponent("\(t.id).json"))).flatMap({ try? JSONDecoder().decode(AIGrid.self, from: $0) }) {
            let btLag = lagSeconds(r.beats, bt.beats)
            confirmed = (abs(btLag) / period >= 0.4) == off && fMeasure(bt.beats, r.beats.map { $0 - btLag }) >= 0.8
        }
        samples.append(OffSample(id: t.id, x: d.offbeat, off: off, confirmed: confirmed))
    }
    runOffFit(samples)
case "long":
    guard let f = read(featureDir.appendingPathComponent("\(args[2]).bin")) else { break }
    let k = Int(args[3]) ?? 12
    func tile(_ a: [Float]) -> [Float] { Array((0..<k).map { _ in a }.joined()) }
    let long = BeatTrackerFeatures(hop: f.hop, sampleRate: f.sampleRate, slowStride: f.slowStride, low: tile(f.low), lowMid: tile(f.lowMid), mid: tile(f.mid), high: tile(f.high), chroma: tile(f.chroma), bandEnergy: tile(f.bandEnergy), analysedSeconds: f.analysedSeconds * Double(k), level: tile(f.level))
    let start = Date()
    let r = BeatTracker.analyze(long, tempoPrior: nil)
    print("long \(s(long.analysedSeconds / 60, 1)) min: \(s(Date().timeIntervalSince(start), 2)) s, beats \(r.beats.count), conf \(r.confidence)")
case "fit":
    var samples: [FitSample] = []
    for t in tracks {
        guard let f = read(featureDir.appendingPathComponent("\(t.id).bin")),
              let ai = (try? Data(contentsOf: aiDir.appendingPathComponent("\(t.id).json"))).flatMap({ try? JSONDecoder().decode(AIGrid.self, from: $0) }),
              ai.confidence >= 0.75, ai.beatsPerBar == 4 else { continue }
        let (r, d) = BeatTracker.analyzeWithDiagnostics(f, tempoPrior: nil)
        guard fMeasure(ai.beats, r.beats) >= 0.8, d.shiftScores.count == 8 else { continue }
        let o = barOffsets(tracker: r.beats, downbeats: r.downbeats, ai: ai)
        let total = o.reduce(0, +)
        guard total >= 8, let top = o.indices.max(by: { o[$0] < o[$1] }), Double(o[top]) / Double(total) >= 0.6 else { continue }
        samples.append(FitSample(id: t.id, cues: d.shiftScores, parity: d.parityStrength, halfBar: d.halfBarStrength, truth: ((4 - top) % 4 + d.phaseShift) % 4, baselineConfidence: r.downbeatConfidence))
    }
    runFit(samples)
case "summary":
    summarise(args[2], baseline: args.count > 3 ? args[3] : nil)
default:
    print("modes: extract | score <out.tsv> | summary <tsv> [baseline tsv]")
}
