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

    init(
        track: Track,
        transcoding: Transcoding,
        genreField: String? = nil,
        tags: [String] = [],
        waveformSamples: [Float] = [],
        localFileURL: URL? = nil
    ) {
        self.track = track
        self.transcoding = transcoding
        self.genreField = genreField
        self.tags = tags
        self.waveformSamples = waveformSamples
        self.localFileURL = localFileURL
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
                MusicUnderstandingProducer()
            ])
        }
        return .metadataOnly
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
        registry: AnalysisProducerRegistry = .v1,
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
            localFileURL: localFileURL
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

@available(iOS 27.0, macOS 27.0, tvOS 27.0, *)
struct MusicUnderstandingProducer: AnalysisProducer {
    let id = "musicUnderstanding"
    let tier: AnalysisTier = .materialisedAudio
    let generation = AnalysisGeneration(engine: .musicUnderstanding(version: 1), schemaVersion: 2)
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
                as: MusicUnderstandingSession.SessionResult.self,
                compute: {
                    let asset = AVURLAsset(url: localFileURL)
                    let session = try await MusicUnderstandingSession(asset: asset)
                    return try await session.analyze(for: Self.analysisTypes)
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

    static func projectFeatures(_ result: MusicUnderstandingSession.SessionResult) -> AnalysisFeatures {
        let bpm = result.rhythm?.beatsPerMinute.map(Double.init)
        return AnalysisFeatures(bpm: bpm, key: majorityKey(result.key), genre: nil)
    }

    static func majorityKey(_ result: KeyResult?) -> CamelotKey? {
        guard let result, !result.ranges.isEmpty else { return nil }
        var best: (key: CamelotKey, duration: Double)?
        for range in result.ranges {
            let duration = range.range.duration.seconds
            guard duration.isFinite, duration > 0 else { continue }
            guard let camelot = camelotKey(for: range.value) else { continue }
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
