import AVFoundation
import Foundation

let args = CommandLine.arguments

func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
}

func analyse(audio: URL, source: SetLearningSource, out: URL) async throws {
    let started = Date()
    let features = try await BeatTracker.extractFeatures(fileURL: audio)
    let result = BeatTracker.analyze(features, tempoPrior: nil)
    let (report, bars) = SetLearning.analyse(source: source, features: features, result: result)
    try FileManager.default.createDirectory(at: out.appendingPathComponent("png"), withIntermediateDirectories: true)
    try encoder().encode(report).write(to: out.appendingPathComponent("\(source.id).json"))
    for t in report.transitions {
        let from = max(0, t.blendStartSeconds - 40), to = t.blendEndSeconds + 40
        let env = SetLearning.envelope(features: features, from: from, to: to)
        let title = "\(source.artist) – \(source.title) · transition \(t.index + 1) at \(Int(t.boundarySeconds) / 60):\(String(format: "%02d", Int(t.boundarySeconds) % 60))"
        SetLearningPlot.render(t, envelope: env, bars: bars, title: title, to: out.appendingPathComponent("png/\(source.id)-\(String(format: "%02d", t.index + 1)).png"))
    }
    print("\(source.id): \(report.bars) bars, \(report.transitions.count) transitions, bpm \(report.bpmMedian ?? 0), \(Int(Date().timeIntervalSince(started)))s")
}

func localSource(_ url: URL, genre: String?) async -> SetLearningSource {
    let asset = AVURLAsset(url: url)
    let duration = (try? await asset.load(.duration).seconds) ?? 0
    var title = url.deletingPathExtension().lastPathComponent
    var artist = ""
    if let items = try? await asset.load(.commonMetadata) {
        for item in items {
            if item.commonKey == .commonKeyTitle, let v = try? await item.load(.stringValue), !v.isEmpty { title = v }
            if item.commonKey == .commonKeyArtist, let v = try? await item.load(.stringValue), !v.isEmpty { artist = v }
        }
    }
    let id = "local-" + String(url.path.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }, radix: 16)
    return SetLearningSource(id: id, title: title, artist: artist, genre: genre, origin: "local:\(url.path)", durationSeconds: duration, cues: [])
}

struct Dataset: Codable {
    struct Pair: Codable {
        var id: String
        var fault: String?
        var good: Bool
        var rating: Double
        var estimated: AutoMixNetObservation
        var measured: AutoMixNetObservation
    }
    var samples: [Pair]
}

func aggregate(reportsDirectory: URL, priorsURL: URL, labelsURL: URL, statsURL: URL) throws {
    let files = try FileManager.default.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    let reports = files.compactMap { try? JSONDecoder().decode(SetLearningReport.self, from: Data(contentsOf: $0)) }
    let stats = SetLearningAggregate(reports: reports)
    try encoder().encode(stats.priors).write(to: priorsURL)
    var samples: [Dataset.Pair] = []
    for r in reports {
        for t in r.transitions where SetLearningAggregate.kept(t, in: r) {
            let o = SetLearning.observation(t)
            samples.append(.init(id: "\(r.source.id)-\(t.index + 1)", fault: nil, good: true, rating: 4, estimated: o, measured: o))
        }
    }
    try encoder().encode(Dataset(samples: samples)).write(to: labelsURL)
    try stats.markdown.write(to: statsURL, atomically: true, encoding: .utf8)
    print("aggregated \(reports.count) sets, \(stats.transitions.count) transitions, \(samples.count) labelled")
}

switch args.count > 1 ? args[1] : "" {
case "analyse":
    let audio = URL(fileURLWithPath: args[2])
    let out = URL(fileURLWithPath: args[3])
    let genre = args.count > 4 ? args[4] : nil
    let source = await localSource(audio, genre: genre)
    try await analyse(audio: audio, source: source, out: out)
case "analyse-source":
    let audio = URL(fileURLWithPath: args[2])
    let source = try JSONDecoder().decode(SetLearningSource.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
    try await analyse(audio: audio, source: source, out: URL(fileURLWithPath: args[4]))
case "effects":
    guard let priors = LearnedSetPriors.load(from: URL(fileURLWithPath: args[2])) else { fatalError("unreadable priors") }
    let moves = ["longBlend": "blend", "cutOnTheOne": "cut", "loopMix": "loop", "dropIn": "drop", "echoOut": "echo", "tempoBlend": "tempo"]
    print("| move (group) | 4 bars | 8 bars | 16 bars | 32 bars | 64 bars |")
    print("|---|---|---|---|---|---|")
    for (move, group) in moves.sorted(by: { $0.value < $1.value }) {
        let row = [4.0, 8, 16, 32, 64].map { String(format: "%+.4f", priors.adjustment(moveType: move, bars: $0, exitSection: "drop", entrySection: "drop")) }
        print("| \(move) (\(group)) | " + row.joined(separator: " | ") + " |")
    }
    print("")
    print("| exit → entry (32-bar blend) | adjustment |")
    print("|---|---|")
    for exit in ["outro", "drop", "breakdown"] {
        for entry in ["intro", "drop", "breakdown"] {
            print("| \(exit) → \(entry) | " + String(format: "%+.4f", priors.adjustment(moveType: "longBlend", bars: 32, exitSection: exit, entrySection: entry)) + " |")
        }
    }
case "aggregate":
    try aggregate(reportsDirectory: URL(fileURLWithPath: args[2]), priorsURL: URL(fileURLWithPath: args[3]), labelsURL: URL(fileURLWithPath: args[4]), statsURL: URL(fileURLWithPath: args[5]))
default:
    print("usage: set-learning analyse <audio> <out dir> [genre] | analyse-source <audio> <source.json> <out dir> | aggregate <reports dir> <priors.json> <labels.json> <stats.md>")
}
