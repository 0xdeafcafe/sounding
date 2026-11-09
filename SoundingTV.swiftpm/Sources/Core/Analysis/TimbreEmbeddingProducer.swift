import Foundation

final class AnalysisDecodeShare: @unchecked Sendable {
    private let lock = NSLock()
    private let wantsTimbre: Bool
    private var timbre: TimbreEmbedding?

    init(wantsTimbre: Bool) {
        self.wantsTimbre = wantsTimbre
    }

    func makeSinks() -> [any AnalysisPCMSink] {
        #if canImport(CreateMLComponents) && !os(watchOS)
        guard wantsTimbre, lock.withLock({ timbre == nil }), let sink = TimbreFeatureSink() else { return [] }
        return [sink]
        #else
        return []
        #endif
    }

    func finish(_ sinks: [any AnalysisPCMSink]) async {
        #if canImport(CreateMLComponents) && !os(watchOS)
        for case let sink as TimbreFeatureSink in sinks {
            guard let embedding = try? await sink.finish() else { continue }
            lock.withLock { timbre = embedding }
        }
        #endif
    }

    func cancel(_ sinks: [any AnalysisPCMSink]) {
        #if canImport(CreateMLComponents) && !os(watchOS)
        for case let sink as TimbreFeatureSink in sinks { sink.cancel() }
        #endif
    }

    func takeTimbre() -> TimbreEmbedding? {
        lock.withLock {
            defer { timbre = nil }
            return timbre
        }
    }
}

extension AnalysisEngineIdentity {
    static func audioFeaturePrint(version: Int = 1) -> AnalysisEngineIdentity {
        .init(name: "apple.audioFeaturePrint", version: version)
    }
}

struct TimbreEmbeddingProducer: AnalysisProducer {
    let id = "timbreEmbedding"
    let tier: AnalysisTier = .materialisedAudio
    let generation = AnalysisGeneration(engine: .audioFeaturePrint(version: 2), schemaVersion: 1)

    static var isSupportedOnThisPlatform: Bool {
        #if canImport(CreateMLComponents) && !os(watchOS)
        return true
        #else
        return false
        #endif
    }

    func isApplicable(_ context: AnalysisProducerContext) -> Bool {
        Self.isSupportedOnThisPlatform && context.localFileURL != nil
    }

    func run(_ context: AnalysisProducerContext, cache: AnalysisCache) async -> AnalysisProducerOutcome {
        guard let url = context.localFileURL else { return .skipped("no local file") }
        guard let key = AnalysisCacheKey(track: context.track, transcoding: context.transcoding, generation: generation) else {
            return .skipped("not entitled — no playable transcoding")
        }
        do {
            _ = try await cache.value(
                for: key,
                as: TimbreEmbedding.self,
                refresh: context.refresh,
                compute: {
                    if let shared = context.decodeShare?.takeTimbre() { return shared }
                    return try await Self.embed(url: url)
                },
                features: { _ in AnalysisFeatures() }
            )
            return .stored(AnalysisFeatures())
        } catch {
            return .failed(String(describing: error))
        }
    }

    static func embed(url: URL) async throws -> TimbreEmbedding {
        #if canImport(CreateMLComponents) && !os(watchOS)
        return try await TimbreFeatureSink.embed(fileURL: url)
        #else
        throw EmbeddingError.unsupported
        #endif
    }

    enum EmbeddingError: Error {
        case noFrames
        case unsupported
    }

    static func hasStored(track: Track, transcoding: Transcoding?) async -> Bool {
        guard isSupportedOnThisPlatform else { return true }
        let generation = TimbreEmbeddingProducer().generation
        guard let transcoding = transcoding ?? track.transcodings.max(by: { $0.playbackRank < $1.playbackRank }),
              let key = AnalysisCacheKey(track: track, transcoding: transcoding, generation: generation) else { return true }
        return await AnalysisCache.shared.peek(TimbreEmbedding.self, for: key) != nil
    }

    static func cached(for track: Track) async -> TimbreEmbedding? {
        let generation = TimbreEmbeddingProducer().generation
        let candidates = [track.mixSource] + track.transcodings
            .sorted { $0.playbackRank > $1.playbackRank }
            .map { Optional($0) }
        var seen = Set<String>()
        for transcoding in candidates {
            guard let key = AnalysisCacheKey(track: track, transcoding: transcoding, generation: generation),
                  seen.insert(key.stableKey).inserted else { continue }
            if let embedding = await AnalysisCache.shared.peek(TimbreEmbedding.self, for: key) {
                return embedding
            }
        }
        return nil
    }
}
