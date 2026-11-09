import AVFoundation
import Foundation
#if canImport(CreateMLComponents)
import CreateMLComponents
#endif

enum Pipe {
    static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    static func chunks(_ samples: [Float], _ body: (UnsafeBufferPointer<Float>) -> Void) {
        samples.withUnsafeBufferPointer { all in
            var offset = 0
            while offset < all.count {
                let end = min(all.count, offset + 8192)
                body(UnsafeBufferPointer(rebasing: all[offset..<end]))
                offset = end
            }
        }
    }

    static func timbreFromFile(_ url: URL) async throws -> Int {
        #if AFTER
        return try await TimbreFeatureSink.embed(fileURL: url).frames
        #else
        let buffers = try AudioReader.read(contentsOf: url)
        let printer = AudioFeaturePrint(windowDuration: 0.975, overlapFactor: 0)
        var count = 0
        for try await _ in try printer.applied(to: buffers) { count += 1 }
        return count
        #endif
    }

    static func run(entries: [Entry], output: URL, limit: Int) async throws {
        let stride = max(1, entries.count / limit)
        let chosen = Swift.stride(from: 0, to: entries.count, by: stride).prefix(limit).map { entries[$0] }
        let wall = Stages(), cpu = Stages()
        var audio = 0.0
        func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let t = now(), c = processCPU()
            let v = try body()
            wall.add(name, now() - t)
            cpu.add(name, processCPU() - c)
            return v
        }
        func timedAsync<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
            let t = now(), c = processCPU()
            let v = try await body()
            wall.add(name, now() - t)
            cpu.add(name, processCPU() - c)
            return v
        }
        _ = AnalysisBackend.isGPUAvailable
        for (n, entry) in chosen.enumerated() {
            let url = URL(fileURLWithPath: entry.path)
            guard let samples = try? await timedAsync("decode 22.05k mono", { try await decodeMono(url) }) else { continue }
            let seconds = Double(samples.count) / BeatTracker.sampleRate
            audio += seconds
            var features = timed("features gpu (onset+chroma)") { extract(samples, backend: .gpu) }
            let curve: [Float]? = timed("vocal pre-filter + SoundAnalysis") {
                guard let voice = VocalClassifier(sampleRate: BeatTracker.sampleRate) else { return nil }
                chunks(samples) { voice.consume($0) }
                return voice.finish()
            }
            if let curve {
                features.vocalCurve = curve
                features.vocalRanges = VocalClassifier.ranges(curve)
            }
            let result = timed("tracker + arrangement (ours)") { () -> BeatTrackerResult in
                let r = BeatTracker.analyze(features, tempoPrior: nil)
                _ = TrackArrangement.build(r, ai: nil)
                return r
            }
            #if AFTER
            _ = try? await timedAsync("timbre AudioFeaturePrint") { () -> Int in
                guard let sink = TimbreFeatureSink() else { return 0 }
                chunks(samples) { sink.consume($0) }
                return try await sink.finish().frames
            }
            #else
            _ = try? await timedAsync("timbre AudioFeaturePrint") { try await timbreFromFile(url) }
            #endif
            if let source = timed("decode 44.1k stereo (plan time)", { () -> MixSource? in
                guard let s = try? MixSource(url: url, synchronous: true) else { return nil }
                for i in 0..<s.chunkCount { _ = s.chunk(i) }
                return s
            }) {
                let downbeats = result.downbeats.sorted()
                _ = timed("per-bar K-weighted loudness (plan time)") { LocalLoudness.measure(source: source, barStarts: downbeats, bars: 0..<downbeats.count) }
            }
            let options = AnalysisFeatureBackend.options(BeatTracker.Options())
            _ = try? await timedAsync("E2E track analysis (beats+vocal+timbre)") { () -> Int in
                #if AFTER
                let sink = TimbreFeatureSink()!
                let f = try await BeatTracker.extractFeatures(fileURL: url, options: options, sinks: [sink])
                let r = BeatTracker.analyze(f, tempoPrior: nil)
                return try await sink.finish().frames + r.beats.count
                #else
                let f = try await BeatTracker.extractFeatures(fileURL: url, options: options)
                let r = BeatTracker.analyze(f, tempoPrior: nil)
                return try await timbreFromFile(url) + r.beats.count
                #endif
            }
            print("[\(n + 1)/\(chosen.count)] \(Int(seconds)) s \(url.lastPathComponent)")
        }
        let minutes = audio / 60
        var lines = ["stage\twall_ms_per_audio_min\tcpu_ms_per_audio_min"]
        for name in wall.order {
            lines.append("\(name)\t\(String(format: "%.1f", wall.seconds[name]! / minutes * 1000))\t\(String(format: "%.1f", cpu.seconds[name]! / minutes * 1000))")
        }
        lines.append("audio minutes\t\(String(format: "%.1f", minutes))\t")
        let text = lines.joined(separator: "\n")
        print(text)
        try text.write(to: output.appendingPathComponent("pipe.tsv"), atomically: true, encoding: .utf8)
    }
}
