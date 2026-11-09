#if AFTER
import AVFoundation
import CreateMLComponents
import Foundation

final class TimbreFramesSink: AnalysisPCMSink, @unchecked Sendable {
    private struct Chunk: @unchecked Sendable {
        let id: TemporalSegmentIdentifier
        let buffer: AVAudioPCMBuffer
    }

    private let format = AVAudioFormat(standardFormatWithSampleRate: BeatTracker.sampleRate, channels: 1)!
    private let continuation: AsyncStream<Chunk>.Continuation
    private let task: Task<[[Float]], Error>
    private var position = 0

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Chunk.self)
        self.continuation = continuation
        task = Task.detached {
            let printer = AudioFeaturePrint(windowDuration: TimbreFeatureSink.windowSeconds, overlapFactor: 0)
            let input = AnyTemporalSequence(stream.map { TemporalFeature(id: $0.id, feature: $0.buffer) }, count: nil)
            var frames: [[Float]] = []
            for try await frame in try printer.applied(to: input) { frames.append(frame.feature.scalars) }
            return frames
        }
    }

    func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let id = TemporalSegmentIdentifier(source: "pcm", range: position..<(position + samples.count), timescale: Int(format.sampleRate))
        position += samples.count
        continuation.yield(Chunk(id: id, buffer: buffer))
    }

    func finish() async throws -> [[Float]] {
        continuation.finish()
        return try await task.value
    }
}

enum Labels {
    static func run(entries: [Entry], output: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        let shard = Int(env["LABEL_SHARD"] ?? "0") ?? 0
        let shards = Int(env["LABEL_SHARDS"] ?? "1") ?? 1
        let options = AnalysisFeatureBackend.options(BeatTracker.Options(), backend: .gpu)
        for (index, entry) in entries.enumerated() where index % shards == shard {
            let file = output.appendingPathComponent(String(format: "%03d.bin", index))
            if FileManager.default.fileExists(atPath: file.path) { continue }
            let url = URL(fileURLWithPath: entry.path)
            guard let melSink = GPUMelSink() else { print("no gpu"); return }
            let timbreSink = TimbreFramesSink()
            let t0 = now()
            guard let features = try? await BeatTracker.extractFeatures(fileURL: url, options: options, sinks: [melSink, timbreSink]),
                  let mel = melSink.finish(), let timbre = try? await timbreSink.finish() else { print("skip \(entry.path)"); continue }
            let result = BeatTracker.analyze(features, tempoPrior: nil)
            let curve = features.vocalCurve ?? []
            let dim = timbre.first?.count ?? 0
            var data = Data()
            func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
            func putArray<T>(_ v: [T]) { v.withUnsafeBytes { data.append(contentsOf: $0) } }
            put(Int32(mel.frames)); put(Int32(AnalysisMel.bands)); put(Int32(curve.count)); put(Int32(timbre.count)); put(Int32(dim))
            put(Int32(result.downbeats.count)); put(Int64(mel.sampleCount)); put(features.analysedSeconds)
            putArray(mel.values)
            putArray(curve)
            putArray(timbre.flatMap { $0 })
            putArray(result.downbeats)
            try data.write(to: file)
            print("[\(shard)] \(index) \(String(format: "%.1f", features.analysedSeconds))s frames \(mel.frames) curve \(curve.count) timbre \(timbre.count)x\(dim) samples \(mel.sampleCount) \(String(format: "%.1f", now() - t0))s")
        }
    }
}
#endif
