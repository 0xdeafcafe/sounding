import Foundation
#if canImport(CreateMLComponents) && !os(watchOS)
import AVFoundation
import CreateMLComponents
#endif

struct TimbreEmbedding: Codable, Sendable, Equatable {
    static let scale: Float = 127

    let whole: [Int8]
    let opening: [Int8]
    let closing: [Int8]
    let frames: Int

    init(whole: [Int8], opening: [Int8], closing: [Int8], frames: Int) {
        self.whole = whole
        self.opening = opening
        self.closing = closing
        self.frames = frames
    }

    init?(frames vectors: [[Float]], edgeShare: Double = 0.3) {
        guard let dimension = vectors.first?.count, dimension > 0,
              vectors.allSatisfy({ $0.count == dimension }) else { return nil }
        let edge = max(1, Int((Double(vectors.count) * edgeShare).rounded()))
        whole = Self.quantised(Self.pooled(vectors[...]))
        opening = Self.quantised(Self.pooled(vectors.prefix(edge)))
        closing = Self.quantised(Self.pooled(vectors.suffix(edge)))
        frames = vectors.count
    }

    static func pooled(_ vectors: ArraySlice<[Float]>) -> [Float] {
        guard let dimension = vectors.first?.count else { return [] }
        var sum = [Float](repeating: 0, count: dimension)
        for vector in vectors {
            for i in 0..<dimension { sum[i] += vector[i] }
        }
        let count = Float(vectors.count)
        return sum.map { $0 / count }
    }

    static func quantised(_ vector: [Float]) -> [Int8] {
        let unit = normalised(vector)
        return unit.map { Int8(max(-127, min(127, ($0 * scale).rounded()))) }
    }

    static func normalised(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    static func cosine(_ a: [Int8], _ b: [Int8]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for i in 0..<a.count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for i in 0..<a.count {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    func similarity(to other: TimbreEmbedding) -> Double? {
        Self.cosine(whole, other.whole)
    }

    func seam(into incoming: TimbreEmbedding) -> Double? {
        Self.cosine(closing, incoming.opening)
    }
}

struct EnergyTrajectory: Sendable, Equatable {
    let opening: Double
    let closing: Double
    let peak: Double

    var slope: Double { closing - opening }

    init(opening: Double, closing: Double, peak: Double) {
        self.opening = opening
        self.closing = closing
        self.peak = peak
    }

    init?(envelope: [Float], edgeShare: Double = 0.25) {
        guard envelope.count >= 4 else { return nil }
        let edge = max(1, Int(Double(envelope.count) * edgeShare))
        func level(_ slice: ArraySlice<Float>) -> Double {
            let sorted = slice.sorted()
            let p90 = Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))])
            return min(10, max(1, p90 * 11))
        }
        let trimmed = envelope.dropFirst(min(2, envelope.count / 8)).dropLast(min(2, envelope.count / 8))
        opening = level(trimmed.prefix(edge))
        closing = level(trimmed.suffix(edge))
        peak = level(trimmed[...])
    }
}

enum TimbreScoring {
    static let similarCosine = 0.93
    static let distantCosine = 0.8
    static let weight = 0.7
    static let unknownCost = 0.1
    static let seamWeight = 0.35

    static func cost(from: TimbreEmbedding?, to: TimbreEmbedding?) -> Double {
        guard let from, let to else { return unknownCost }
        let overall = from.similarity(to: to) ?? similarCosine
        let seam = from.seam(into: to) ?? overall
        let blended = (1 - seamWeight) * overall + seamWeight * seam
        let distance = (similarCosine - blended) / (similarCosine - distantCosine)
        return min(1, max(0, distance)) * weight
    }

    static func trajectoryCost(from: EnergyTrajectory?, to: EnergyTrajectory?) -> Double {
        guard let from, let to else { return 0 }
        let jump = abs(to.opening - from.closing)
        return min(1, max(0, (jump - 1.5) / 4)) * 0.4
    }
}

#if canImport(CreateMLComponents) && !os(watchOS)
final class TimbreFeatureSink: AnalysisPCMSink, @unchecked Sendable {
    static let windowSeconds = 0.975

    private struct Chunk: @unchecked Sendable {
        let id: TemporalSegmentIdentifier
        let buffer: AVAudioPCMBuffer
    }

    enum SinkError: Error {
        case noFrames
    }

    private let format: AVAudioFormat
    private let continuation: AsyncStream<Chunk>.Continuation
    private let task: Task<TimbreEmbedding, Error>
    private var position = 0

    init?(sampleRate: Double = BeatTracker.sampleRate) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        self.format = format
        let (stream, continuation) = AsyncStream.makeStream(of: Chunk.self)
        self.continuation = continuation
        task = Task.detached(priority: Task.currentPriority) {
            let printer = AudioFeaturePrint(windowDuration: Self.windowSeconds, overlapFactor: 0)
            let input = AnyTemporalSequence(stream.map { TemporalFeature(id: $0.id, feature: $0.buffer) }, count: nil)
            var frames: [[Float]] = []
            for try await frame in try printer.applied(to: input) {
                frames.append(frame.feature.scalars)
            }
            guard let embedding = TimbreEmbedding(frames: frames) else { throw SinkError.noFrames }
            return embedding
        }
    }

    deinit {
        continuation.finish()
    }

    func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty, let base = samples.baseAddress,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0] else { return }
        out.update(from: base, count: samples.count)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let id = TemporalSegmentIdentifier(source: "pcm", range: position..<(position + samples.count), timescale: Int(format.sampleRate))
        position += samples.count
        continuation.yield(Chunk(id: id, buffer: buffer))
    }

    func finish() async throws -> TimbreEmbedding {
        continuation.finish()
        return try await task.value
    }

    func cancel() {
        continuation.finish()
        task.cancel()
    }

    static func embed(fileURL: URL, maxSeconds: TimeInterval = BeatTracker.maxAnalysisSeconds) async throws -> TimbreEmbedding {
        guard let sink = TimbreFeatureSink() else { throw SinkError.noFrames }
        do {
            try await AnalysisPCMDecode.read(fileURL: fileURL, maxSeconds: maxSeconds, yield: nil, begin: { _ in }, consume: sink.consume)
        } catch {
            sink.cancel()
            throw error
        }
        return try await sink.finish()
    }
}
#endif
