import AVFoundation
import Accelerate
import Foundation
#if canImport(CreateMLComponents)
import CreateMLComponents
#endif

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "profile"
let corpusFile = URL(fileURLWithPath: args.count > 2 ? args[2] : "tracks.tsv")
let outputDirectory = URL(fileURLWithPath: args.count > 3 ? args[3] : "/tmp/gpu-analysis-bench")
let limit = args.count > 4 ? Int(args[4]) ?? 30 : 30
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

struct Entry { var seconds: Double; var path: String }

let entries: [Entry] = try String(contentsOf: corpusFile, encoding: .utf8).split(separator: "\n").compactMap { line in
    let parts = line.split(separator: "\t", maxSplits: 1)
    guard parts.count == 2, let seconds = Double(parts[0]) else { return nil }
    return Entry(seconds: seconds, path: String(parts[1]))
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func decodeMono(_ url: URL, maxSeconds: Double = BeatTracker.maxAnalysisSeconds) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard let track = tracks.first else { throw BeatTracker.TrackerError.noAudioTrack }
    let assetDuration = (try? await asset.load(.duration).seconds) ?? 0
    let duration = min(maxSeconds, assetDuration.isFinite && assetDuration > 0 ? assetDuration : maxSeconds)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: BeatTracker.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 1000))
    guard reader.startReading() else { throw BeatTracker.TrackerError.readerFailed }
    let cap = Int(BeatTracker.sampleRate * duration)
    var samples = [Float]()
    samples.reserveCapacity(cap)
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        let count = min(length / MemoryLayout<Float>.size, cap - samples.count)
        guard count > 0 else { break }
        let start = samples.count
        samples.append(contentsOf: repeatElement(0, count: count))
        samples.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: raw.baseAddress! + start * 4)
        }
        if samples.count >= cap { break }
    }
    reader.cancelReading()
    return samples
}

func extract(_ samples: [Float], backend: AnalysisBackend) -> BeatTrackerFeatures {
    let seconds = Double(samples.count) / BeatTracker.sampleRate
    let hop = BeatTracker.hop(forDuration: seconds, options: .init())
    return samples.withUnsafeBufferPointer { AnalysisFeatureBackend.extract($0, hop: hop, expectedSeconds: seconds, backend: backend) }
}

final class Stages {
    var order: [String] = []
    var seconds: [String: Double] = [:]
    func time<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let t = now()
        let value = try body()
        add(name, now() - t)
        return value
    }
    func add(_ name: String, _ value: Double) {
        if seconds[name] == nil { order.append(name) }
        seconds[name, default: 0] += value
    }
}

func prefilterOnly(_ samples: [Float]) {
    let hp = VocalClassifier.biquad(highPass: true, cutoff: 250, sampleRate: BeatTracker.sampleRate)
    let lp = VocalClassifier.biquad(highPass: false, cutoff: 5_000, sampleRate: BeatTracker.sampleRate)
    let filters = [hp, hp, lp, lp]
    var states = Array(repeating: (0.0, 0.0, 0.0, 0.0), count: 4)
    var out = [Float](repeating: 0, count: 8192)
    var offset = 0
    var sink: Float = 0
    while offset < samples.count {
        let end = min(samples.count, offset + 8192)
        for i in offset..<end {
            var x = Double(samples[i])
            for k in 0..<filters.count {
                let f = filters[k]
                let s = states[k]
                let y = f.0 * x + f.1 * s.0 + f.2 * s.1 - f.3 * s.2 - f.4 * s.3
                states[k] = (x, s.0, y, s.2)
                x = y
            }
            out[i - offset] = Float(x)
        }
        sink += out[0]
        offset = end
    }
    if sink.isNaN { print("") }
}

func profile() async throws {
    let stride = max(1, entries.count / limit)
    let chosen = Swift.stride(from: 0, to: entries.count, by: stride).prefix(limit).map { entries[$0] }
    let stages = Stages()
    var audioSeconds = 0.0
    var rows: [String] = []
    for (n, entry) in chosen.enumerated() {
        let url = URL(fileURLWithPath: entry.path)
        let rowStages = Stages()
        func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let t = now()
            let v = try body()
            let d = now() - t
            stages.add(name, d)
            rowStages.add(name, d)
            return v
        }
        let t0 = now()
        guard let samples = try? await decodeMono(url) else { print("skip \(entry.path)"); continue }
        let decode = now() - t0
        stages.add("decode 22.05k mono", decode)
        rowStages.add("decode 22.05k mono", decode)
        let seconds = Double(samples.count) / BeatTracker.sampleRate
        audioSeconds += seconds
        var features = timed("features cpu (stft+onset+chroma)") { extract(samples, backend: .cpu) }
        _ = timed("features gpu (stft+onset+chroma)") { extract(samples, backend: .gpu) }
        timed("vocal prefilter (ours)") { prefilterOnly(samples) }
        let curve: [Float]? = timed("vocal SoundAnalysis+prefilter") {
            guard let voice = VocalClassifier(sampleRate: BeatTracker.sampleRate) else { return nil }
            samples.withUnsafeBufferPointer { all in
                var offset = 0
                while offset < all.count {
                    let end = min(all.count, offset + 8192)
                    voice.consume(UnsafeBufferPointer(rebasing: all[offset..<end]))
                    offset = end
                }
            }
            return voice.finish()
        }
        if let curve {
            features.vocalCurve = curve
            features.vocalRanges = VocalClassifier.ranges(curve)
        }
        let rate = features.frameRate
        let frames = features.frameCount
        let (low, lowMid, mid, high, odf) = timed("odf prep") { () -> ([Float], [Float], [Float], [Float], [Float]) in
            let low = BeatTracker.normalisedByMean(features.low)
            let lowMid = BeatTracker.normalisedByMean(features.lowMid)
            let mid = BeatTracker.normalisedByMean(features.mid)
            let high = BeatTracker.normalisedByMean(features.high)
            var odf = [Float](repeating: 0, count: frames)
            for t in 0..<frames { odf[t] = low[t] + 0.6 * lowMid[t] + 0.8 * mid[t] + 0.35 * high[t] }
            odf = BeatTracker.highPassed(odf, radius: Int(rate * 0.25))
            BeatTracker.normaliseByStd(&odf)
            return (low, lowMid, mid, high, odf)
        }
        if let tempo = timed("tempo search (acf)", { BeatTracker.estimateTempo(odf, rate: rate, prior: nil) }) {
            let beatFrames = timed("beat DP") { BeatTracker.trackBeats(odf, periods: tempo.framePeriods) }
            if beatFrames.count >= 16 {
                var sharp = [Float](repeating: 0, count: frames)
                for t in 0..<frames { sharp[t] = low[t] + 0.5 * lowMid[t] + 0.8 * mid[t] }
                let map = timed("tempo map") {
                    BeatTracker.buildTempoMap(beatFrames: beatFrames, sharp: sharp, features: features, periodSeconds: { Double(tempo.framePeriod(at: $0)) / rate })
                }
                if map.beats.count >= 16 {
                    let bar = timed("downbeats") { BeatTracker.estimateDownbeats(beats: map.beats, features: features, low: low, mid: mid, high: high) }
                    _ = timed("phrases") { BeatTracker.estimatePhrases(beats: map.beats, downbeatIndices: bar.downbeatIndices, features: features, high: high) }
                    let downbeats = bar.downbeatIndices.map { BeatTracker.round4(map.beats[$0]) }
                    _ = timed("bar profile") { BarProfile.measure(features, downbeats: downbeats) }
                }
            }
        }
        let result = timed("analyze total (core)") { BeatTracker.analyze(features, tempoPrior: nil) }
        _ = timed("arrangement sections") { TrackArrangement.build(result, ai: nil) }
        if let source = timed("decode 44.1k stereo", { () -> MixSource? in
            guard let s = try? MixSource(url: url, synchronous: true) else { return nil }
            for i in 0..<s.chunkCount { _ = s.chunk(i) }
            return s
        }) {
            let downbeats = result.downbeats.sorted()
            _ = timed("per-bar K-weighted loudness") { LocalLoudness.measure(source: source, barStarts: downbeats, bars: 0..<downbeats.count) }
        }
        #if canImport(CreateMLComponents)
        let tt = now()
        if let buffers = try? AudioReader.read(contentsOf: url) {
            let printer = AudioFeaturePrint(windowDuration: 0.975, overlapFactor: 0)
            var count = 0
            if let seq = try? printer.applied(to: buffers) {
                do { for try await _ in seq { count += 1 } } catch {}
            }
        }
        stages.add("timbre AudioFeaturePrint (Apple)", now() - tt)
        rowStages.add("timbre AudioFeaturePrint (Apple)", now() - tt)
        #endif
        let row = rowStages.order.map { String(format: "%.3f", rowStages.seconds[$0]! / seconds * 60) }.joined(separator: "\t")
        rows.append("\(String(format: "%.1f", seconds))\t\(row)\t\(url.lastPathComponent)")
        print("[\(n + 1)/\(chosen.count)] \(Int(seconds)) s  \(url.lastPathComponent)")
    }
    let minutes = audioSeconds / 60
    var lines = ["stage\tms_per_audio_minute\ttotal_s"]
    for name in stages.order {
        let s = stages.seconds[name]!
        lines.append("\(name)\t\(String(format: "%.1f", s / minutes * 1000))\t\(String(format: "%.2f", s))")
    }
    lines.append("audio minutes\t\(String(format: "%.1f", minutes))\t")
    let text = lines.joined(separator: "\n")
    print(text)
    try text.write(to: outputDirectory.appendingPathComponent("profile.tsv"), atomically: true, encoding: .utf8)
    try (["seconds\t" + stages.order.joined(separator: "\t") + "\tfile"] + rows).joined(separator: "\n")
        .write(to: outputDirectory.appendingPathComponent("profile-per-track.tsv"), atomically: true, encoding: .utf8)
}

switch mode {
case "profile":
    try await profile()
case "parity":
    try await Parity.run(entries: entries, output: outputDirectory, limit: limit)
case "pipe":
    try await Pipe.run(entries: entries, output: outputDirectory, limit: limit)
case "mixcpu":
    try MixCPU.run(entries: entries, output: outputDirectory, minutes: 10)
default:
    #if AFTER
    switch mode {
    case "wave":
        try await Wave.run(entries: entries, output: outputDirectory)
    case "loud":
        try await LoudGate.run(entries: entries, output: outputDirectory)
    case "lanes":
        try await Lanes.run(entries: entries, output: outputDirectory, limit: limit)
    case "lanesparity":
        try await Lanes.parity(entries: entries, output: outputDirectory, limit: limit)
    case "dethash":
        try await DecodeDeterminism.run(entries: entries, output: outputDirectory)
    case "modelgate":
        try await ModelGate.run(entries: entries, output: outputDirectory)
    case "modelspeed":
        try await ModelSpeed.run(entries: entries, output: outputDirectory, limit: limit)
    case "modelgatesum":
        try ModelGate.summarise(output: outputDirectory)
    case "labels2":
        try await Labels2.run(entries: entries, output: outputDirectory)
    case "labelcheck":
        try await Labels2.check(entries: entries, limit: limit)
    case "labels":
        try await Labels.run(entries: entries, output: outputDirectory)
    case "wavesum":
        try Wave.summarise(output: outputDirectory)
    default:
        print("usage: bench profile|parity|pipe|wave|wavesum|dethash|lanes|lanesparity|mixcpu <tracks.tsv> <out> [limit]")
    }
    #else
    print("usage: bench profile|parity|pipe|mixcpu <tracks.tsv> <out> [limit]")
    #endif
}
