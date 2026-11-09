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
    static func quantizedSourceSeconds(nominal: TimeInterval, snap: StageSnap, grid: BeatGrid?) -> TimeInterval {
        guard let grid, grid.beatPeriod > 0 else { return nominal }
        let unit: TimeInterval
        switch snap {
        case .beat: unit = grid.beatPeriod
        case .bar: unit = grid.barDuration > 0 ? grid.barDuration : grid.beatPeriod
        case .phrase: unit = grid.phraseDuration > 0 ? grid.phraseDuration : grid.beatPeriod
        case .free: return nominal
        }
        guard unit > 0 else { return nominal }
        let steps = ((nominal - grid.firstDownbeat) / unit - 1e-9).rounded(.up)
        return max(nominal, grid.firstDownbeat + steps * unit)
    }
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


enum DJQueueOrderPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case profileDefault
    case preserve
    case mayReorder
    case random

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .profileDefault: return "Use Profile Default"
        case .preserve:       return "Preserve Playlist Order"
        case .mayReorder:     return "Choose the Best Next Track"
        case .random:         return "Random Order"
        }
    }
}

enum DJBlendLength: String, Codable, CaseIterable, Identifiable, Sendable {
    case short
    case normal
    case long

    var id: String { rawValue }

    var bars: Int {
        switch self {
        case .short: return 8
        case .normal: return 16
        case .long: return 32
        }
    }

    var displayName: String {
        switch self {
        case .short: return "Short"
        case .normal: return "Normal"
        case .long: return "Long"
        }
    }
}

struct CollectionPolicy: Equatable, Sendable {
    var avoidVocalOverlap = false
    var queueOrder: DJQueueOrderPolicy = .profileDefault
    var maximumTransitionBars = 64
}

enum EnergyTerm {
    static func level(from features: TrackFeatures) -> (level: Int, measured: Bool)? {
        if let level = features.energyLevel { return (level, true) }
        guard !features.envelope.isEmpty else { return nil }
        let sorted = features.envelope.sorted()
        let p95 = Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
        return (min(10, max(1, Int((p95 * 11).rounded()))), false)
    }
}

extension DJProfile {
    static let automaticDJ = DJProfile(
        id: .automatic, displayName: "Auto Mix", blurb: "",
        exitRegionFloor: 0.45, allowMidTrackExit: false, entryRegionCeiling: 0.35, minimumPlayFraction: 0.55,
        admissibleTemplates: [], repeatTemplateCooldown: 2,
        maxAbsRatePercent: 3.0, allowVarispeed: false, requireMeasuredBPMForRate: true, maxDriftMs: 15, minGridConfidence: 0.65,
        maxCamelotSteps: 1, allowEnergyBoost: true, genreCeiling: 0.65,
        mayReorderQueue: false, lookaheadCandidates: 1, analysisBudgetPerTrack: 2,
        maxLoopBars: 8, maxLoopHalvings: 1,
        weights: [:], minimumScoreToFire: 0.55, transitionBarsRange: 16...32,
        energyStepLimit: 2, timbreTargetDistance: 0.24, honoursUserTransitionLength: false
    )
}
