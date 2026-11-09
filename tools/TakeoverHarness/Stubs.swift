import Foundation

enum PlayerService {
    static func storedVolume(_ defaults: UserDefaults = .standard) -> Double { 1 }
}

enum DJDeckRole: String, Codable, Equatable {
    case live
    case incoming
    case idle
}

struct DJDeckStatePayload: Codable, Equatable {
    let trackId: String?
    let title: String?
    let artist: String?
    let positionSeconds: Double
    let durationSeconds: Double
    let isPlaying: Bool
    let eqLowDb: Double
    let eqMidDb: Double
    let eqHighDb: Double
    let filterCutoffHz: Double
    let filterResonance: Double
    let rate: Double
    let bpm: Double?
    let loopStartSeconds: Double?
    let loopLengthSeconds: Double?
    let role: DJDeckRole?
    let level: Double?
    let peak: Double?
    let isClipping: Bool?
    let phaseErrorSeconds: Double?
}

enum SourceImporter {
    static func protect(cacheKey: String, in directory: URL) {}
    static func unprotect(cacheKey: String, in directory: URL) {}
    static func pruneCache(in directory: URL) {}
    static func clearCache(in directory: URL) {}
    static func hasCachedSource(cacheKey: String, in directory: URL) -> Bool { false }
    static func materialise(
        remoteURL: URL,
        cacheKey: String,
        in directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        throw CancellationError()
    }
}

struct CueHint: Equatable, Sendable {}

enum PhantomDJEngine {
    typealias Accent = TransitionAccent
}

enum MixTransitionPerformer {
    static func quantizedSourceSeconds(nominal: TimeInterval, snap: StageSnap, grid: BeatGrid?) -> TimeInterval { nominal }
}
