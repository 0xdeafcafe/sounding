import Foundation
import AVFoundation
import CoreMedia
import MusicUnderstanding

struct AnalysisProducerContext: Sendable {
    let track: Track
    let transcoding: Transcoding

    let genreField: String?
    let tags: [String]

    let waveformSamples: [Float]

    let localFileURL: URL?

    let refresh: Bool

    let decodeShare: AnalysisDecodeShare?

    init(
        track: Track,
        transcoding: Transcoding,
        genreField: String? = nil,
        tags: [String] = [],
        waveformSamples: [Float] = [],
        localFileURL: URL? = nil,
        refresh: Bool = false,
        decodeShare: AnalysisDecodeShare? = nil
    ) {
        self.track = track
        self.transcoding = transcoding
        self.genreField = genreField
        self.tags = tags
        self.waveformSamples = waveformSamples
        self.localFileURL = localFileURL
        self.refresh = refresh
        self.decodeShare = decodeShare
    }
}

enum AnalysisTier: String, Sendable {
    case metadata
    case materialisedAudio
}

enum AnalysisProducerOutcome: Sendable {
    case stored(AnalysisFeatures)
    case skipped(String)
    case failed(String)
}

extension AnalysisFeatures: Equatable {
    static func == (a: AnalysisFeatures, b: AnalysisFeatures) -> Bool {
        a.bpm == b.bpm && a.key == b.key && a.genre == b.genre
    }
}

extension AnalysisProducerOutcome: Equatable {
    static func == (a: AnalysisProducerOutcome, b: AnalysisProducerOutcome) -> Bool {
        switch (a, b) {
        case (.stored(let x), .stored(let y)): return x == y
        case (.skipped(let x), .skipped(let y)): return x == y
        case (.failed(let x), .failed(let y)): return x == y
        default: return false
        }
    }
}

protocol AnalysisProducer: Sendable {
    var id: String { get }
    var tier: AnalysisTier { get }

    var generation: AnalysisGeneration { get }

    func isApplicable(_ context: AnalysisProducerContext) -> Bool

    func run(_ context: AnalysisProducerContext, cache: AnalysisCache) async -> AnalysisProducerOutcome
}

extension AnalysisProducer {
    var engine: AnalysisEngineIdentity { generation.engine }
    var schemaVersion: Int { generation.schemaVersion }
}

struct AnalysisProducerGeneration: Sendable, Hashable {
    let producerId: String
    let tier: AnalysisTier
    let generation: AnalysisGeneration
}

struct AnalysisProducerRegistry: Sendable {
    private(set) var producers: [any AnalysisProducer]

    init(_ producers: [any AnalysisProducer]) {
        self.producers = producers
    }

    mutating func register(_ producer: any AnalysisProducer) {
        producers.append(producer)
    }

    static var v1: AnalysisProducerRegistry {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            return AnalysisProducerRegistry([
                GenreTaxonomyProducer(),
                WaveformEnvelopeProducer(),
                MusicUnderstandingProducer(),
                BeatTrackerProducer()
            ] + onDeviceAI)
        }
        return AnalysisProducerRegistry([
            GenreTaxonomyProducer(),
            WaveformEnvelopeProducer(),
            BeatTrackerProducer()
        ] + onDeviceAI)
    }

    static var audioTier: AnalysisProducerRegistry {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *), MusicUnderstandingProducer.isSupportedOnThisPlatform {
            return AnalysisProducerRegistry([MusicUnderstandingProducer()] + onDeviceAI)
        }
        return AnalysisProducerRegistry([BeatTrackerProducer()] + onDeviceAI)
    }

    static var onDeviceAI: [any AnalysisProducer] {
        #if canImport(MLX) && os(macOS)
        return AIAudioSettings.isActive ? [AIAudioProducer()] : []
        #else
        return []
        #endif
    }

    static let metadataOnly = AnalysisProducerRegistry([
        GenreTaxonomyProducer(),
        WaveformEnvelopeProducer()
    ])

    var liveGenerations: [AnalysisProducerGeneration] {
        producers.map {
            AnalysisProducerGeneration(producerId: $0.id, tier: $0.tier, generation: $0.generation)
        }
    }
}

// MARK: - Summary

enum AnalysisAuthority: Int, Comparable, Sendable {
    case corrected = 0
    case measured = 1
    case estimated = 2

    static func < (lhs: AnalysisAuthority, rhs: AnalysisAuthority) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct AnalysisFeatureSummary: Sendable, Equatable {
    var bpm: Double?
    var key: CamelotKey?
    var genre: String?
    var bpmAuthority: AnalysisAuthority?
    var keyAuthority: AnalysisAuthority?
    var genreAuthority: AnalysisAuthority?

    var bpmIsMeasured: Bool { bpmAuthority.map { $0 <= .measured } ?? false }
    var keyIsMeasured: Bool { keyAuthority.map { $0 <= .measured } ?? false }
    var genreIsMeasured: Bool { genreAuthority.map { $0 <= .measured } ?? false }

    var isEmpty: Bool { bpm == nil && key == nil && genre == nil }
}

enum AnalysisSummaryStore {
    static let durationToleranceMillis = 2_000

    static var liveGenerations: [AnalysisProducerGeneration] {
        AnalysisProducerRegistry.v1.liveGenerations + [
            AnalysisProducerGeneration(
                producerId: "user",
                tier: .materialisedAudio,
                generation: AnalysisGeneration(engine: .userCorrection(), schemaVersion: 1)
            )
        ]
    }

    static func preferredFingerprint(for track: Track) -> AnalyzedAudioFingerprint? {
        AnalyzedAudioFingerprint(
            duration: track.duration,
            transcoding: track.transcodings.max { $0.playbackRank < $1.playbackRank }
        )
    }

    static func authority(
        of engine: AnalysisEngineIdentity,
        live: [AnalysisProducerGeneration] = liveGenerations
    ) -> AnalysisAuthority? {
        if engine == .userCorrection() { return .corrected }
        guard let entry = live.first(where: { $0.generation.engine == engine }) else { return nil }
        return entry.tier == .materialisedAudio ? .measured : .estimated
    }

    static func summarise(
        _ rows: [AnalysisRecallRow],
        expectedDurationMillis: Int?,
        preferred: AnalyzedAudioFingerprint? = nil,
        live: [AnalysisProducerGeneration] = liveGenerations
    ) -> AnalysisFeatureSummary? {
        struct Candidate {
            let row: AnalysisRecallRow
            let authority: AnalysisAuthority
            let isPreferred: Bool
        }

        let candidates = rows.compactMap { row -> Candidate? in
            guard let authority = authority(of: row.generation.engine, live: live) else { return nil }
            if let expectedDurationMillis,
               abs(row.fingerprint.durationMillis - expectedDurationMillis) > durationToleranceMillis {
                return nil
            }
            return Candidate(row: row, authority: authority, isPreferred: preferred.map { $0 == row.fingerprint } ?? true)
        }.sorted { lhs, rhs in
            if lhs.authority != rhs.authority { return lhs.authority < rhs.authority }
            if lhs.isPreferred != rhs.isPreferred { return lhs.isPreferred }
            if lhs.row.generation.schemaVersion != rhs.row.generation.schemaVersion {
                return lhs.row.generation.schemaVersion > rhs.row.generation.schemaVersion
            }
            return lhs.row.producedAt > rhs.row.producedAt
        }

        var summary = AnalysisFeatureSummary()
        for candidate in candidates {
            let row = candidate.row
            if summary.bpm == nil, let bpm = row.bpm, bpm.isFinite, bpm > 0 {
                summary.bpm = bpm
                summary.bpmAuthority = candidate.authority
            }
            if summary.key == nil, let key = row.key {
                summary.key = key
                summary.keyAuthority = candidate.authority
            }
            if summary.genre == nil, let genre = row.genre, !genre.isEmpty {
                summary.genre = genre
                summary.genreAuthority = candidate.authority
            }
        }
        return summary.isEmpty ? nil : summary
    }

    static func summaries(
        for tracks: [Track],
        cache: AnalysisCache = .shared
    ) async -> [String: AnalysisFeatureSummary] {
        guard !tracks.isEmpty else { return [:] }
        let live = liveGenerations
        let rowsByTrack = await cache.recallRows(
            forTrackIds: tracks.map(\.id),
            scope: .engines(Array(Set(live.map(\.generation.engine))))
        )
        var result: [String: AnalysisFeatureSummary] = [:]
        for track in tracks {
            guard let rows = rowsByTrack[track.id],
                  let summary = summarise(
                      rows,
                      expectedDurationMillis: Int((track.duration * 1000).rounded()),
                      preferred: preferredFingerprint(for: track),
                      live: live
                  ) else { continue }
            result[track.id] = summary
        }
        return result
    }

    static func summaries(
        forTrackIds trackIds: [String],
        cache: AnalysisCache = .shared
    ) async -> [String: AnalysisFeatureSummary] {
        guard !trackIds.isEmpty else { return [:] }
        let live = liveGenerations
        let rowsByTrack = await cache.recallRows(
            forTrackIds: trackIds,
            scope: .engines(Array(Set(live.map(\.generation.engine))))
        )
        return rowsByTrack.compactMapValues { summarise($0, expectedDurationMillis: nil, live: live) }
    }

    static func summaries(
        grouping rows: [AnalysisRecallRow]
    ) -> [String: AnalysisFeatureSummary] {
        let live = liveGenerations
        return Dictionary(grouping: rows, by: \.trackId)
            .compactMapValues { summarise($0, expectedDurationMillis: nil, live: live) }
    }
}

@MainActor
final class AnalysisSummaries: ObservableObject {
    static let shared = AnalysisSummaries()

    @Published private(set) var byTrackId: [String: AnalysisFeatureSummary] = [:]

    private static let batchSize = 200
    private var knownTracks: [String: Track] = [:]
    private var resolvedTrackIds: Set<String> = []
    private var pending: [String: Track] = [:]
    private var pendingOrder: [String] = []
    private var drainTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .analysisDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let trackIds = note.userInfo?[AnalysisDataChange.trackIdsKey] as? [String]
            MainActor.assumeIsolated { self?.invalidate(trackIds) }
        }
    }

    func summary(for trackId: String) -> AnalysisFeatureSummary? {
        byTrackId[trackId]
    }

    func summary(for track: Track) -> AnalysisFeatureSummary? {
        if !resolvedTrackIds.contains(track.id), pending[track.id] == nil { request([track]) }
        return byTrackId[track.id]
    }

    func request(_ tracks: some Sequence<Track>) {
        for track in tracks {
            knownTracks[track.id] = track
            guard !resolvedTrackIds.contains(track.id), pending[track.id] == nil else { continue }
            pending[track.id] = track
            pendingOrder.append(track.id)
        }
        scheduleDrain()
    }

    func summaries(for tracks: [Track]) async -> [String: AnalysisFeatureSummary] {
        guard !tracks.isEmpty else { return [:] }
        for track in tracks { knownTracks[track.id] = track }
        let fresh = await AnalysisSummaryStore.summaries(for: tracks)
        publish(fresh, for: tracks.map(\.id))
        return fresh
    }

    func refresh(_ tracks: [Track]) async {
        _ = await summaries(for: tracks)
    }

    private func invalidate(_ trackIds: [String]?) {
        let targets = trackIds.map(Set.init) ?? resolvedTrackIds.union(byTrackId.keys)
        var orphaned: [String] = []
        for trackId in targets {
            resolvedTrackIds.remove(trackId)
            if let track = knownTracks[trackId] {
                if pending[trackId] == nil {
                    pending[trackId] = track
                    pendingOrder.append(trackId)
                }
            } else if byTrackId[trackId] != nil {
                orphaned.append(trackId)
            }
        }
        if !orphaned.isEmpty {
            Task { [weak self] in
                let fresh = await AnalysisSummaryStore.summaries(forTrackIds: orphaned)
                self?.publish(fresh, for: orphaned)
            }
        }
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard drainTask == nil, !pending.isEmpty else { return }
        drainTask = Task { [weak self] in
            while let batch = self?.takeBatch() {
                let fresh = await AnalysisSummaryStore.summaries(for: batch)
                self?.publish(fresh, for: batch.map(\.id))
            }
            self?.drainTask = nil
        }
    }

    private func takeBatch() -> [Track]? {
        guard !pending.isEmpty else { return nil }
        var batch: [Track] = []
        while batch.count < Self.batchSize, !pendingOrder.isEmpty {
            let trackId = pendingOrder.removeFirst()
            if let track = pending.removeValue(forKey: trackId) { batch.append(track) }
        }
        if pendingOrder.isEmpty { pending.removeAll() }
        return batch.isEmpty ? nil : batch
    }

    private func publish(_ fresh: [String: AnalysisFeatureSummary], for trackIds: [String]) {
        var next = byTrackId
        for trackId in trackIds {
            next[trackId] = fresh[trackId]
            resolvedTrackIds.insert(trackId)
        }
        if next != byTrackId { byTrackId = next }
    }
}

enum AnalysisCoordinator {
    struct RunResult: Sendable, Equatable {
        var outcomes: [String: AnalysisProducerOutcome] = [:]
        var isEntitled: Bool = true

        var stored: [String: AnalysisFeatures] {
            outcomes.compactMapValues {
                if case .stored(let features) = $0 { return features }
                return nil
            }
        }
    }

    static func analyze(
        track: Track,
        transcoding: Transcoding? = nil,
        genreField: String? = nil,
        tags: [String] = [],
        waveformSamples: [Float] = [],
        localFileURL: URL? = nil,
        refresh: Bool = false,
        registry: AnalysisProducerRegistry = .v1,
        decodeShare: AnalysisDecodeShare? = nil,
        cache: AnalysisCache
    ) async -> RunResult {
        guard let resolvedTranscoding = transcoding
            ?? track.transcodings.max(by: { $0.playbackRank < $1.playbackRank }) else {
            return RunResult(outcomes: [:], isEntitled: false)
        }

        let context = AnalysisProducerContext(
            track: track,
            transcoding: resolvedTranscoding,
            genreField: genreField,
            tags: tags,
            waveformSamples: waveformSamples,
            localFileURL: localFileURL,
            refresh: refresh,
            decodeShare: decodeShare
        )

        var result = RunResult()
        for producer in registry.producers {
            guard producer.isApplicable(context) else {
                result.outcomes[producer.id] = .skipped("not applicable")
                continue
            }
            result.outcomes[producer.id] = await producer.run(context, cache: cache)
        }
        return result
    }
}

struct GenreAnalysisPayload: Codable, Sendable {
    let genre: MusicGenre
    let family: GenreFamily
    let confidenceValue: Double
    let source: GenreEvidenceSource
    let bpmHint: Double?
    let evidence: [String]

    init(resolution: GenreResolution) {
        genre = resolution.genre
        family = resolution.family
        confidenceValue = resolution.confidenceValue
        source = resolution.source
        bpmHint = resolution.bpmHint
        evidence = resolution.evidence
    }

    var features: AnalysisFeatures {
        let confident = genre != .unknown && GenreConfidence(confidenceValue) != .none
        return AnalysisFeatures(bpm: bpmHint, key: nil, genre: confident ? genre.rawValue : nil)
    }
}

struct GenreTaxonomyProducer: AnalysisProducer {
    let id = "genreTaxonomy"
    let tier: AnalysisTier = .metadata
    let generation = AnalysisGeneration(engine: .genreTaxonomy(version: 1), schemaVersion: 2)

    func isApplicable(_ context: AnalysisProducerContext) -> Bool { true }

    func run(_ context: AnalysisProducerContext, cache: AnalysisCache) async -> AnalysisProducerOutcome {
        guard let key = AnalysisCacheKey(
            track: context.track,
            transcoding: context.transcoding,
            generation: generation
        ) else {
            return .skipped("not entitled — no playable transcoding")
        }

        do {
            let genreField = context.genreField
            let tags = context.tags
            let payload = try await cache.value(
                for: key,
                as: GenreAnalysisPayload.self,
                compute: {
                    GenreAnalysisPayload(resolution: GenreDetector.resolve(genreField: genreField, tags: tags))
                },
                features: { $0.features }
            )
            return .stored(payload.features)
        } catch {
            return .failed(String(describing: error))
        }
    }
}

struct WaveformAnalysisPayload: Codable, Sendable {
    let samples: [Float]
}

struct WaveformEnvelopeProducer: AnalysisProducer {
    let id = "waveformEnvelope"
    let tier: AnalysisTier = .metadata
    let generation = AnalysisGeneration(engine: .soundCloudWaveform(version: 1), schemaVersion: 1)

    func isApplicable(_ context: AnalysisProducerContext) -> Bool {
        !context.waveformSamples.isEmpty
    }

    func run(_ context: AnalysisProducerContext, cache: AnalysisCache) async -> AnalysisProducerOutcome {
        guard !context.waveformSamples.isEmpty else {
            return .skipped("no waveform samples supplied")
        }
        guard let key = AnalysisCacheKey(
            track: context.track,
            transcoding: context.transcoding,
            generation: generation
        ) else {
            return .skipped("not entitled — no playable transcoding")
        }

        let samples = context.waveformSamples
        do {
            _ = try await cache.value(
                for: key,
                as: WaveformAnalysisPayload.self,
                compute: { WaveformAnalysisPayload(samples: samples) },
                features: { _ in AnalysisFeatures() }
            )
            return .stored(AnalysisFeatures())
        } catch {
            return .failed(String(describing: error))
        }
    }
}

struct BeatTrackerProducer: AnalysisProducer {
    let id = "beatTracker"
    let tier: AnalysisTier = .materialisedAudio
    let generation = AnalysisGeneration(engine: .beatTracker(version: BeatTracker.version), schemaVersion: 1)

    func isApplicable(_ context: AnalysisProducerContext) -> Bool {
        context.localFileURL != nil
    }

    func run(_ context: AnalysisProducerContext, cache: AnalysisCache) async -> AnalysisProducerOutcome {
        guard let localFileURL = context.localFileURL else {
            return .skipped("no local file")
        }
        guard let key = AnalysisCacheKey(track: context.track, transcoding: context.transcoding, generation: generation) else {
            return .skipped("not entitled — no playable transcoding")
        }
        let prior = Self.tempoPrior(for: context.track)
        let share = context.decodeShare
        do {
            let result = try await cache.value(
                for: key,
                as: BeatTrackerResult.self,
                refresh: context.refresh,
                compute: {
                    let sinks = share?.makeSinks() ?? []
                    do {
                        let result = try await BeatTracker.analyze(
                            fileURL: localFileURL,
                            options: AnalysisFeatureBackend.options(BeatTracker.Options(tempoPrior: prior)),
                            sinks: sinks,
                            yield: { await AnalysisPlaybackGuard.waitWhilePlaybackCritical() }
                        )
                        await share?.finish(sinks)
                        return result
                    } catch {
                        share?.cancel(sinks)
                        throw error
                    }
                },
                features: { Self.projectFeatures($0) }
            )
            return .stored(Self.projectFeatures(result))
        } catch is CancellationError {
            return .skipped("cancelled")
        } catch {
            Log.analysis.error("beatTracker: \(context.track.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .failed(String(describing: error))
        }
    }

    static func projectFeatures(_ result: BeatTrackerResult) -> AnalysisFeatures {
        AnalysisFeatures(bpm: result.isTempoReliable ? result.bpm : nil, key: nil, genre: nil)
    }

    static func tempoPrior(for track: Track) -> Double? {
        let resolution = GenreDetector.resolve(genreField: track.genre, tags: track.tags + [track.title])
        guard resolution.genre != .unknown else { return nil }
        return GenreProfile.of(resolution.genre).bpmCenter
    }
}

enum AnalysisPlaybackGuard {
    static func waitWhilePlaybackCritical() async {
        var waited = 0
        while await MainActor.run(body: { isPlaybackCritical }), waited < 240 {
            try? await Task.sleep(for: .milliseconds(500))
            waited += 1
        }
    }

    @MainActor
    static var isPlaybackCritical: Bool {
        let engine = MixEngine.shared
        if engine.decks.contains(where: { $0.status.isLoading }) { return true }
        let fader = engine.crossfade
        return fader > 0.001 && fader < 0.999
    }
}

struct MusicUnderstandingDistilledResult: Codable, Sendable {
    struct Range: Codable, Sendable {
        let start: Double
        let end: Double
    }

    struct KeyRange: Codable, Sendable {
        let start: Double
        let end: Double
        let wheelPosition: Int
        let mode: Int
    }

    let beatSeconds: [Double]
    let barSeconds: [Double]
    let beatsPerMinute: Double?
    let phraseStartSeconds: [Double]
    let structureRanges: [Range]
    let keyRanges: [KeyRange]
    let vocalRanges: [Range]?
    let bassRanges: [Range]?
    let drumRanges: [Range]?
    let integratedLUFS: Float?
}

@available(iOS 27.0, macOS 27.0, tvOS 27.0, *)
struct MusicUnderstandingProducer: AnalysisProducer {
    let id = "musicUnderstanding"
    let tier: AnalysisTier = .materialisedAudio
    let generation = AnalysisGeneration(engine: .musicUnderstanding(version: 1), schemaVersion: 3)
    static let analysisTypes: Set<AnalysisType> = [.rhythm, .key, .loudness, .structure, .instrumentActivity]

    static var isSupportedOnThisPlatform: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }

    func isApplicable(_ context: AnalysisProducerContext) -> Bool {
        guard Self.isSupportedOnThisPlatform else { return false }
        return context.localFileURL != nil
    }

    func run(_ context: AnalysisProducerContext, cache: AnalysisCache) async -> AnalysisProducerOutcome {
        guard Self.isSupportedOnThisPlatform else {
            return .skipped("MusicUnderstanding is disabled on tvOS — MusicUnderstandingSession(asset:) aborts the process (task #168)")
        }
        guard let localFileURL = context.localFileURL else {
            return .skipped("no local file — MusicUnderstanding accepts local file:// assets only")
        }
        guard let key = AnalysisCacheKey(
            track: context.track,
            transcoding: context.transcoding,
            generation: generation
        ) else {
            return .skipped("not entitled — no playable transcoding")
        }

        do {
            let result = try await cache.value(
                for: key,
                as: MusicUnderstandingDistilledResult.self,
                refresh: context.refresh,
                compute: {
                    let asset = AVURLAsset(url: localFileURL)
                    let session = try await MusicUnderstandingSession(asset: asset)
                    let raw = try await session.analyze(for: Self.analysisTypes)
                    return Self.distill(raw)
                },
                features: { Self.projectFeatures($0) }
            )
            return .stored(Self.projectFeatures(result))
        } catch let error as MusicUnderstandingError {
            switch error {
            case .invalidAsset, .hasProtectedContent, .emptyAnalysisSet:
                return .skipped("MusicUnderstanding: \(error)")
            case .sessionInProgress, .internalError:
                return .failed("MusicUnderstanding: \(error)")
            @unknown default:
                return .failed("MusicUnderstanding: \(error)")
            }
        } catch {
            Log.analysis.error("musicUnderstanding: \(context.track.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .failed(String(describing: error))
        }
    }

    static func distill(_ result: MusicUnderstandingSession.SessionResult) -> MusicUnderstandingDistilledResult {
        func validRange(_ range: CMTimeRange) -> MusicUnderstandingDistilledResult.Range? {
            let lower = range.start.seconds
            let upper = range.end.seconds
            guard lower.isFinite, upper.isFinite, upper > lower else { return nil }
            return MusicUnderstandingDistilledResult.Range(start: lower, end: upper)
        }

        func instrumentRanges(_ instrument: InstrumentActivityResult.Instrument) -> [MusicUnderstandingDistilledResult.Range]? {
            result.instrumentActivity.map { activity in
                (activity.ranges[instrument] ?? []).compactMap { range -> MusicUnderstandingDistilledResult.Range? in
                    let lower = range.start.seconds
                    let upper = range.end.seconds
                    guard lower.isFinite, upper.isFinite, upper >= lower else { return nil }
                    return MusicUnderstandingDistilledResult.Range(start: lower, end: upper)
                }
            }
        }

        let keyRanges: [MusicUnderstandingDistilledResult.KeyRange] = (result.key?.ranges ?? []).compactMap { ranged in
            guard let range = validRange(ranged.range), let camelot = camelotKey(for: ranged.value) else { return nil }
            return MusicUnderstandingDistilledResult.KeyRange(
                start: range.start, end: range.end,
                wheelPosition: camelot.wheelPosition, mode: camelot.mode.rawValue
            )
        }

        return MusicUnderstandingDistilledResult(
            beatSeconds: (result.rhythm?.beats ?? []).map(\.seconds).filter { $0.isFinite },
            barSeconds: (result.rhythm?.bars ?? []).map(\.seconds).filter { $0.isFinite },
            beatsPerMinute: result.rhythm?.beatsPerMinute.map(Double.init),
            phraseStartSeconds: (result.structure?.phrases ?? [])
                .map(\.start.seconds).filter { $0.isFinite && $0 >= 0 },
            structureRanges: (result.structure?.sections ?? []).compactMap(validRange),
            keyRanges: keyRanges,
            vocalRanges: instrumentRanges(.vocal),
            bassRanges: instrumentRanges(.bass),
            drumRanges: instrumentRanges(.drum),
            integratedLUFS: result.loudness?.integrated.value
        )
    }

    static func projectFeatures(_ result: MusicUnderstandingDistilledResult) -> AnalysisFeatures {
        AnalysisFeatures(bpm: result.beatsPerMinute, key: majorityKey(result), genre: nil)
    }

    static func majorityKey(_ result: MusicUnderstandingDistilledResult) -> CamelotKey? {
        guard !result.keyRanges.isEmpty else { return nil }
        var best: (key: CamelotKey, duration: Double)?
        for range in result.keyRanges {
            let duration = range.end - range.start
            guard duration.isFinite, duration > 0 else { continue }
            guard let mode = CamelotKey.CamelotMode(rawValue: range.mode) else { continue }
            let camelot = CamelotKey(wheelPosition: range.wheelPosition, mode: mode)
            if best == nil || duration > best!.duration {
                best = (camelot, duration)
            }
        }
        return best?.key
    }

    static func camelotKey(for signature: KeyResult.KeySignature) -> CamelotKey? {
        guard let pitchClass = pitchClass(for: signature.tonic) else { return nil }
        return CamelotKey(pitchClass: pitchClass, isMinor: signature.mode == .minor)
    }

    static func pitchClass(for tonic: KeyResult.Tonic) -> Int? {
        switch tonic {
        case .c: return 0
        case .cSharp, .dFlat: return 1
        case .d: return 2
        case .dSharp, .eFlat: return 3
        case .e: return 4
        case .f: return 5
        case .fSharp, .gFlat: return 6
        case .g: return 7
        case .gSharp, .aFlat: return 8
        case .a: return 9
        case .aSharp, .bFlat: return 10
        case .b: return 11
        }
    }
}
