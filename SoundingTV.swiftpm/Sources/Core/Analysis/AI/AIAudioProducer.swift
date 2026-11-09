#if canImport(MLX) && os(macOS)
import Foundation

struct AIAudioProducer: AnalysisProducer {
    let id = "aiAudio"
    let tier: AnalysisTier = .materialisedAudio
    let generation = AnalysisGeneration(engine: .aiAudio(), schemaVersion: 1)

    func isApplicable(_ context: AnalysisProducerContext) -> Bool {
        AIAudioSettings.isActive && context.localFileURL != nil
    }

    func run(_ context: AnalysisProducerContext, cache: AnalysisCache) async -> AnalysisProducerOutcome {
        guard AIAudioSettings.isActive, let url = context.localFileURL else {
            return .skipped("on-device AI analysis is off")
        }
        guard let key = AnalysisCacheKey(track: context.track, transcoding: context.transcoding, generation: generation) else {
            return .skipped("not entitled — no playable transcoding")
        }
        let prior = BeatTrackerProducer.tempoPrior(for: context.track)
        let trackId = context.track.id
        let share = context.decodeShare
        do {
            let result = try await cache.value(
                for: key,
                as: AIAudioAnalysisResult.self,
                refresh: context.refresh,
                compute: { try await AIAudioRunner.analyze(url: url, tempoPrior: prior, share: share) },
                features: { Self.projectFeatures($0) }
            )
            return .stored(Self.projectFeatures(result))
        } catch is CancellationError {
            return .skipped("cancelled")
        } catch {
            Log.analysis.error("aiAudio: \(trackId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .failed(String(describing: error))
        }
    }

    static func projectFeatures(_ result: AIAudioAnalysisResult) -> AnalysisFeatures {
        AnalysisFeatures(bpm: result.isBeatGridTrusted ? result.grid?.bpm : nil, key: nil, genre: nil)
    }
}

enum AIAudioRunner {
    private static let queue = DispatchQueue(label: "red.forbes.sounding.aiAudio", qos: .utility)

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    static var thermalAllows: Bool {
        ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    static func analyze(url: URL, tempoPrior: Double?, share: AnalysisDecodeShare? = nil) async throws -> AIAudioAnalysisResult {
        await AnalysisPlaybackGuard.waitWhilePlaybackCritical()
        let sinks = share?.makeSinks() ?? []
        let features: BeatTrackerFeatures
        do {
            features = try await BeatTracker.extractFeatures(
                fileURL: url,
                options: AnalysisFeatureBackend.options(BeatTracker.Options()),
                sinks: sinks,
                yield: { await AnalysisPlaybackGuard.waitWhilePlaybackCritical() }
            )
        } catch {
            share?.cancel(sinks)
            throw error
        }
        await share?.finish(sinks)
        try Task.checkCancellation()
        let base = BeatTracker.analyze(features, tempoPrior: tempoPrior)
        let stemsWanted = AIAudioSettings.stemsActive
        let cancelled = Flag()
        let inference = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(BeatThisResult, StemTimeline?), Error>) in
                queue.async {
                    let keepGoing = { !cancelled.isSet && thermalAllows }
                    do {
                        let beats = try autoreleasepool { () -> BeatThisResult? in
                            let model = try BeatThisModel(weights: AIModelStore.directory(.beatThis).appendingPathComponent("model.safetensors"))
                            return try BeatThisAnalyzer.analyze(fileURL: url, model: model, shouldContinue: keepGoing)
                        }
                        guard let beats else { throw CancellationError() }
                        var stems: StemTimeline?
                        if stemsWanted, keepGoing() {
                            stems = try autoreleasepool { () -> StemTimeline? in
                                let model = try OpenUnmixModel(directory: AIModelStore.directory(.openUnmix))
                                return try OpenUnmixAnalyzer.analyze(fileURL: url, model: model, shouldContinue: keepGoing).map(StemTimeline.init)
                            }
                        }
                        continuation.resume(returning: (beats, stems))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
        try Task.checkCancellation()
        let (beats, stems) = inference
        let grid = BeatTracker.imposing(
            beats: beats.beats,
            downbeats: beats.barDownbeats,
            beatConfidence: beats.confidence,
            downbeatConfidence: beats.downbeatConfidence,
            on: features,
            base: base
        )
        let barStarts = grid?.downbeats ?? []
        func spans(_ list: [StemTimeline.Span]) -> [AIAudioAnalysisResult.Span] {
            list.map { .init(start: $0.start, end: $0.end) }
        }
        return AIAudioAnalysisResult(
            version: AIAudioAnalysisResult.version,
            grid: grid,
            gridConfidence: beats.confidence,
            downbeatConfidence: beats.downbeatConfidence,
            beatsPerBar: beats.beatsPerBar,
            stems: stems.map { timeline in
                AIAudioAnalysisResult.Stems(
                    vocals: spans(timeline.vocalRanges),
                    drumsOnly: spans(timeline.snapped(timeline.drumsOnlyRanges, to: barStarts)),
                    bass: spans(timeline.bassRanges)
                )
            }
        )
    }
}
#endif
