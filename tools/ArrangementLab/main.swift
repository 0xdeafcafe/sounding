import Foundation

struct LabTrack: Codable {
    let id: String
    let path: String
    let title: String
    var result: BeatTrackerResult
    var extractSeconds: Double
    var analyseSeconds: Double
    var ai: AIAudioAnalysisResult.Stems?
    var aiDownbeats: [Double]?
    var mtime: Double?
    var version: Int?
    var cacheName: String?
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let mode = args[2]
let tracksDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARRANGEMENT_CACHE"] ?? "/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/automix-corpus/cache/beattracker-v\(BeatTracker.version)")
let pngDir = out.appendingPathComponent("png")
try FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: pngDir, withIntermediateDirectories: true)

func loadTracks() -> [LabTrack] {
    let files = (try? FileManager.default.contentsOfDirectory(at: tracksDir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap {
        try? JSONDecoder().decode(LabTrack.self, from: Data(contentsOf: $0))
    }.sorted { $0.id < $1.id }
}

func cacheName(_ path: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
    return String(format: "%016llx", hash)
}

func loadAnnotations() -> [String: Annotation] {
    let sets = (ProcessInfo.processInfo.environment["ANNOTATION_SETS"] ?? "A,B1,B2,C").split(separator: ",")
    var out: [String: Annotation] = [:]
    for set in sets {
        let url = URL(fileURLWithPath: "/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/arrangement/annotations-\(set).json")
        guard let data = try? Data(contentsOf: url) else { continue }
        do {
            out.merge(try JSONDecoder().decode([String: Annotation].self, from: data)) { a, _ in a }
        } catch {
            print("annotations-\(set).json: \(error)")
        }
    }
    return out
}

func evidence(_ track: LabTrack, useAI: Bool) -> TrackArrangement.Evidence {
    guard useAI, let stems = track.ai else { return TrackArrangement.Evidence() }
    return TrackArrangement.Evidence(
        vocals: stems.vocals.compactMap(\.seconds), vocalSource: .openUnmix,
        drumsOnly: stems.drumsOnly.compactMap(\.seconds), bass: stems.bass.compactMap(\.seconds)
    )
}

func arrangement(_ track: LabTrack, useAI: Bool = false) -> TrackArrangement? {
    TrackArrangement.build(track.result, evidence: evidence(track, useAI: useAI))
}

switch mode {
case "analyse":
    let list = try String(contentsOfFile: args[3], encoding: .utf8)
    for (index, line) in list.split(separator: "\n").enumerated() where !line.isEmpty {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let id = String(format: "c%03d", index + 1), path = parts[1]
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let name = cacheName(path)
        let target = tracksDir.appendingPathComponent("\(name).json")
        if let data = try? Data(contentsOf: target), let cached = try? JSONDecoder().decode(LabTrack.self, from: data),
           cached.mtime == mtime, cached.version == BeatTracker.version { continue }
        let start = Date()
        guard let features = try? await BeatTracker.extractFeatures(fileURL: URL(fileURLWithPath: path)) else {
            print("\(id) failed to decode \(path)")
            continue
        }
        let extracted = Date()
        let result = BeatTracker.analyze(features, tempoPrior: nil)
        let analysed = Date()
        let title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var track = LabTrack(id: id, path: path, title: title, result: result,
                             extractSeconds: extracted.timeIntervalSince(start), analyseSeconds: analysed.timeIntervalSince(extracted))
        track.mtime = mtime
        track.version = BeatTracker.version
        track.cacheName = name
        try JSONEncoder().encode(track).write(to: target)
        print("\(id) \(title): \(String(format: "%.0f", result.analysedSeconds)) s audio, extract \(String(format: "%.2f", track.extractSeconds)) s, analyse \(String(format: "%.2f", track.analyseSeconds)) s, bars \(result.downbeats.count), conf \(result.confidence)")
    }
case "ai":
    let dir = URL(fileURLWithPath: args[3])
    for var track in loadTracks() {
        let stemsURL = dir.appendingPathComponent("stems-\(track.id).json")
        guard let data = try? Data(contentsOf: stemsURL), let timeline = try? JSONDecoder().decode(StemFile.self, from: data) else { continue }
        func spans(_ s: [StemFile.Span]) -> [AIAudioAnalysisResult.Span] { s.map { .init(start: $0.start, end: $0.end) } }
        track.ai = .init(vocals: spans(timeline.vocalRanges), drumsOnly: spans(timeline.drumsOnlyRanges), bass: spans(timeline.bassRanges))
        try JSONEncoder().encode(track).write(to: tracksDir.appendingPathComponent("\(track.cacheName ?? track.id).json"))
        print("\(track.id): ai vocals \(timeline.vocalRanges.count) spans")
    }
case "plot":
    let annotations = loadAnnotations()
    let selection = args.count > 3 ? Set((try? String(contentsOfFile: args[3], encoding: .utf8))?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []) : []
    for track in loadTracks() where selection.isEmpty || selection.contains(track.id) {
        let a = arrangement(track)
        let aiA = track.ai == nil ? nil : arrangement(track, useAI: true)
        let plain = pngDir.appendingPathComponent("\(track.id)-plain.png")
        if !FileManager.default.fileExists(atPath: plain.path) {
            plot(track, arrangement: nil, aiArrangement: nil, annotation: nil, to: plain)
        }
        plot(track, arrangement: a, aiArrangement: aiA, annotation: annotations[track.id], to: pngDir.appendingPathComponent("\(track.id)-roles.png"))
    }
    print("plotted to \(pngDir.path)")
case "dump":
    for track in loadTracks() where args.count < 4 || args[3] == track.id {
        guard let a = arrangement(track, useAI: args.count > 4) else { print("\(track.id): no arrangement"); continue }
        print("\(track.id) \(track.title) bars \(a.barCount) grid \(a.coverage.gridConfidence) vocals \(a.coverage.vocals?.rawValue ?? "unknown")")
        print("  " + a.intervals.map { "\($0.bars.lowerBound)-\($0.bars.upperBound) \($0.role.rawValue) \($0.confidence)" }.joined(separator: " | "))
    }
case "score":
    evaluate(loadTracks(), annotations: loadAnnotations(), useAI: args.count > 3 && args[3] == "ai")
case "bench":
    let tracks = loadTracks()
    let start = Date()
    var built = 0
    for _ in 0..<20 { for t in tracks where arrangement(t) != nil { built += 1 } }
    let elapsed = Date().timeIntervalSince(start)
    let audio = tracks.reduce(0) { $0 + $1.result.analysedSeconds }
    let extract = tracks.reduce(0) { $0 + $1.extractSeconds }
    let analyse = tracks.reduce(0) { $0 + $1.analyseSeconds }
    let bars = tracks.reduce(0) { $0 + $1.result.downbeats.count }
    print(String(format: "tracks %d, audio %.0f s, bars %d", tracks.count, audio, bars))
    print(String(format: "beat tracker (existing): extract %.1f s + analyse %.1f s = %.1fx realtime on this Mac", extract, analyse, audio / max(1e-9, extract + analyse)))
    print(String(format: "arrangement: %.3f ms per track (mean over %d builds), %.4f%% of the beat tracker's cost", elapsed / Double(max(1, built)) * 1000, built, elapsed / Double(max(1, built)) / max(1e-9, (extract + analyse) / Double(tracks.count)) * 100))
    if let t = tracks.first, let a = arrangement(t) {
        let bytes = try JSONEncoder().encode(a).count
        print("encoded size for \(t.id) (\(a.barCount) bars): \(bytes) bytes")
    }
default:
    print("unknown mode \(mode)")
}

struct StemFile: Decodable {
    struct Span: Decodable { let start: Double; let end: Double }
    let vocalRanges: [Span]
    let drumsOnlyRanges: [Span]
    let bassRanges: [Span]
}
