import Foundation

enum MixEngine {
    static let filterCutoffRange: ClosedRange<Double> = 30...20_000
    static let filterOpenHertz: Double = 19_000
    static let bassKillDecibels: Double = -60
}

enum PhantomDJEngine {
    typealias Accent = TransitionAccent
}

struct CueHint: Equatable, Sendable {}

enum MixTransitionPerformer {
    static func quantizedSourceSeconds(nominal: TimeInterval, snap: StageSnap, grid: BeatGrid?) -> TimeInterval { nominal }
}

enum MixPerformanceLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case subtle
    case lively

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .lively: return "Lively"
        }
    }

    var maximumMoves: Int {
        switch self {
        case .off: return 0
        case .subtle: return 1
        case .lively: return 2
        }
    }

    var trackChance: Double {
        switch self {
        case .off: return 0
        case .subtle: return 0.5
        case .lively: return 0.9
        }
    }

    var minimumGapBars: Int {
        switch self {
        case .off, .subtle: return 64
        case .lively: return 32
        }
    }
}

struct AnalysisEngineIdentity: Codable, Hashable, Sendable {
    let name: String
    let version: Int
}
