#if AFTER
import AVFoundation
import Foundation
#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

enum Lanes {
    struct Config {
        let label: String
        let lanes: Int
        let yield: Duration
        let priority: TaskPriority
        let pipelined: Bool
    }

    final class Queue: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Entry]
        init(_ items: [Entry]) { self.items = items.reversed() }
        func next() -> Entry? { lock.withLock { items.popLast() } }
    }

    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var tracks = 0
        private(set) var audioSeconds = 0.0
        private(set) var failures = 0
        private(set) var running = 0
        private(set) var peak = 0
        func begin() { lock.withLock { running += 1; peak = max(peak, running) } }
        func end(seconds: Double?) {
            lock.withLock {
                running -= 1
                if let seconds { tracks += 1; audioSeconds += seconds } else { failures += 1 }
            }
        }
    }

    static func loadAverage() -> String {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return String(format: "%.1f", load[0])
    }

    static func chosen(_ entries: [Entry], limit: Int) -> [Entry] {
        let stride = max(1, entries.count / limit)
        return Swift.stride(from: 0, to: entries.count, by: stride).prefix(limit).map { entries[$0] }
    }

    static func parse(_ token: String, unthrottled: Bool) -> Config {
        var spec = Substring(token)
        let pipelined = spec.hasSuffix("p")
        if pipelined { spec = spec.dropLast() }
        let yielding = spec.hasSuffix("y")
        if yielding { spec = spec.dropLast() }
        let background = spec.hasSuffix("b")
        if background { spec = spec.dropLast() }
        let lanes = Int(spec) ?? 1
        return Config(
            label: token, lanes: lanes, yield: yielding ? .seconds(2) : .zero,
            priority: background ? .background : (unthrottled ? .utility : .background), pipelined: pipelined
        )
    }

    static func trackerJob(url: URL) async throws -> Double {
        let options = AnalysisFeatureBackend.options(BeatTracker.Options())
        guard let sink = TimbreFeatureSink() else { throw BeatTracker.TrackerError.readerFailed }
        let features = try await BeatTracker.extractFeatures(fileURL: url, options: options, sinks: [sink])
        let result = BeatTracker.analyze(features, tempoPrior: nil)
        _ = try await sink.finish()
        _ = TrackArrangement.build(result, ai: nil)
        return result.analysedSeconds
    }

    static func trackerFromPCM(_ samples: [Float]) async throws -> (BeatTrackerResult, TimbreEmbedding) {
        let seconds = Double(samples.count) / BeatTracker.sampleRate
        let hop = BeatTracker.hop(forDuration: seconds, options: .init())
        let extractor = AnalysisFeatureBackend.makeExtractor(hop: hop, expectedSeconds: seconds, backend: .preferred)
        guard let voice = VocalClassifier(sampleRate: BeatTracker.sampleRate),
              let sink = TimbreFeatureSink() else { throw BeatTracker.TrackerError.readerFailed }
        Pipe.chunks(samples) { slice in
            extractor.consume(slice)
            voice.consume(slice)
            sink.consume(slice)
        }
        var features = extractor.finish()
        if let curve = voice.finish() {
            features.vocalCurve = curve
            features.vocalRanges = VocalClassifier.ranges(curve)
        }
        let result = BeatTracker.analyze(features, tempoPrior: nil)
        return (result, try await sink.finish())
    }

    static func musicUnderstandingJob(url: URL) async throws -> Double {
        #if canImport(MusicUnderstanding)
        let session = try await MusicUnderstandingSession(asset: AVURLAsset(url: url))
        let raw = try await session.analyze(for: [.rhythm, .key, .loudness, .structure, .instrumentActivity])
        _ = try await TimbreFeatureSink.embed(fileURL: url)
        return (raw.rhythm?.beats.last?.seconds ?? 0)
        #else
        throw BeatTracker.TrackerError.readerFailed
        #endif
    }

    static func audioSeconds(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        return min(BeatTracker.maxAnalysisSeconds, (try? await asset.load(.duration).seconds) ?? 0)
    }

    static func run(entries: [Entry], output: URL, limit: Int) async throws {
        let environment = ProcessInfo.processInfo.environment
        let engine = environment["LANES_ENGINE"] ?? "tracker"
        let tokens = (environment["LANES"] ?? "1y,6").split(separator: ",").map(String.init)
        let tracks = chosen(entries, limit: limit)
        _ = AnalysisBackend.isGPUAvailable
        _ = VocalClassifier(sampleRate: BeatTracker.sampleRate)
        let policyLanes = AnalysisLanePolicy.backgroundLanes(.init(device: .mac, isOnPower: true, isPlaying: false))
        print("engine \(engine), \(tracks.count) tracks, perf cores \(AnalysisLanePolicy.performanceCoreCount), policy lanes on power \(policyLanes)")
        var lines = ["config\tlanes\tyield_s\tpriority\tpipelined\ttracks\tfailures\tpeak\taudio_min\twall_s\ttracks_per_min\taudio_min_per_wall_min\tload_start\tload_end"]
        for token in tokens {
            let config = parse(token, unthrottled: true)
            let queue = Queue(tracks)
            let tally = Tally()
            let loadStart = loadAverage()
            let start = now()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<config.lanes {
                    group.addTask(priority: config.priority) {
                        await lane(queue: queue, tally: tally, config: config, engine: engine)
                    }
                }
            }
            let wall = now() - start
            let loadEnd = loadAverage()
            let line = [
                config.label, "\(config.lanes)", "\(config.yield.components.seconds)",
                config.priority == .background ? "background" : "utility", config.pipelined ? "yes" : "no",
                "\(tally.tracks)", "\(tally.failures)", "\(tally.peak)",
                String(format: "%.1f", tally.audioSeconds / 60), String(format: "%.1f", wall),
                String(format: "%.2f", Double(tally.tracks) / wall * 60),
                String(format: "%.2f", tally.audioSeconds / wall),
                loadStart, loadEnd
            ].joined(separator: "\t")
            print(line)
            lines.append(line)
            try lines.joined(separator: "\n").write(to: output.appendingPathComponent("lanes-\(engine).tsv"), atomically: true, encoding: .utf8)
        }
    }

    static func lane(queue: Queue, tally: Tally, config: Config, engine: String) async {
        var prefetched: Task<(Entry, [Float]?), Never>?
        func fetch(_ entry: Entry) -> Task<(Entry, [Float]?), Never> {
            Task { (entry, try? await decodeMono(URL(fileURLWithPath: entry.path))) }
        }
        if config.pipelined, let first = queue.next() { prefetched = fetch(first) }
        while true {
            var seconds: Double?
            if config.pipelined {
                guard let current = prefetched else { break }
                let (_, samples) = await current.value
                prefetched = queue.next().map(fetch)
                tally.begin()
                if let samples, (try? await trackerFromPCM(samples)) != nil {
                    seconds = Double(samples.count) / BeatTracker.sampleRate
                }
            } else {
                guard let entry = queue.next() else { break }
                tally.begin()
                let url = URL(fileURLWithPath: entry.path)
                switch engine {
                case "mu":
                    if (try? await musicUnderstandingJob(url: url)) != nil { seconds = await audioSeconds(url) }
                default:
                    seconds = try? await trackerJob(url: url)
                }
            }
            tally.end(seconds: seconds)
            if config.yield > .zero { try? await Task.sleep(for: config.yield) }
        }
    }

    static func parity(entries: [Entry], output: URL, limit: Int) async throws {
        let lanes = Int(ProcessInfo.processInfo.environment["LANES"] ?? "6") ?? 6
        let tracks = chosen(entries, limit: limit)
        _ = AnalysisBackend.isGPUAvailable
        var decoded: [(Entry, [Float])] = []
        for entry in tracks {
            if let samples = try? await decodeMono(URL(fileURLWithPath: entry.path)) { decoded.append((entry, samples)) }
        }
        print("decoded \(decoded.count) tracks once; serial pass")
        var serial: [Int: (BeatTrackerResult, TimbreEmbedding)] = [:]
        for (index, item) in decoded.enumerated() {
            serial[index] = try? await trackerFromPCM(item.1)
        }
        print("concurrent pass, \(lanes) lanes")
        let concurrent = await withTaskGroup(of: (Int, (BeatTrackerResult, TimbreEmbedding)?).self) { group in
            var next = 0
            var results: [Int: (BeatTrackerResult, TimbreEmbedding)] = [:]
            func add() {
                guard next < decoded.count else { return }
                let index = next
                let samples = decoded[index].1
                next += 1
                group.addTask(priority: .utility) { (index, try? await trackerFromPCM(samples)) }
            }
            for _ in 0..<lanes { add() }
            while let (index, value) = await group.next() {
                results[index] = value
                add()
            }
            return results
        }
        var identical = 0, trackerDiff = 0, timbreDiff = 0, missing = 0
        var rows = ["track\ttracker_identical\ttimbre_identical"]
        for index in decoded.indices {
            guard let a = serial[index], let b = concurrent[index] else { missing += 1; continue }
            let sameTracker = a.0 == b.0
            let sameTimbre = a.1 == b.1
            if sameTracker && sameTimbre { identical += 1 }
            if !sameTracker { trackerDiff += 1 }
            if !sameTimbre { timbreDiff += 1 }
            rows.append("\(decoded[index].0.path.split(separator: "/").last ?? "")\t\(sameTracker)\t\(sameTimbre)")
        }
        let summary = "parity \(decoded.count) tracks, \(lanes) lanes: identical \(identical), tracker differs \(trackerDiff), timbre differs \(timbreDiff), missing \(missing)"
        print(summary)
        try (rows + [summary]).joined(separator: "\n").write(to: output.appendingPathComponent("lanes-parity.tsv"), atomically: true, encoding: .utf8)
    }
}
#endif
