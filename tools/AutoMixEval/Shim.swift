import Foundation

enum MixEngine {
    nonisolated static let eqGainRange: ClosedRange<Double> = -60...12
    nonisolated static let filterCutoffRange: ClosedRange<Double> = 30...20_000
    nonisolated static let filterOpenHertz: Double = 19_000
    nonisolated static let bassKillDecibels: Double = -60
}

enum DJQueueOrderPolicy { case profileDefault, preserve, random, mayReorder }

enum DJBlendLength {
    case short, normal, long
    var bars: Int { self == .short ? 8 : self == .normal ? 16 : 32 }
}

struct CollectionPolicy {
    var avoidVocalOverlap = false
    var queueOrder: DJQueueOrderPolicy = .profileDefault
    var maximumTransitionBars = 64
}

struct CueHint: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case exit
        case entry
    }

    let seconds: TimeInterval
    let role: Role
    let confidence: Double
    var label: String = ""
}

enum MixTransitionPerformer {
    nonisolated static func quantizedSourceSeconds(nominal: TimeInterval, snap: StageSnap, grid: BeatGrid?) -> TimeInterval {
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

struct MixTrackSnapshot {
    var id: String
    var title: String
    var artist: String
    var bpm: Double?
    var camelot: String?
    var energyLevel: Int?
}

struct MixHistoryEntry {
    var id: UUID
    var date: Date
    var sessionID: UUID
    var outgoing: MixTrackSnapshot
    var incoming: MixTrackSnapshot
    var plan: MixPlanRecord
    var execution: MixExecutionRecord
    var performance: [MixPerformanceMove]
}

final class MixHistoryStore: @unchecked Sendable {
    static let shared = MixHistoryStore()
    var entries: [MixHistoryEntry] = []
    func rateLatest(liked: Bool) {}
}

extension AutoMixMove {
    static func of(templateId: TransitionTemplateID?, move: MixMove?) -> AutoMixMove? {
        if let move {
            if move.kind == .fxBuild, move.effect == .echo { return .echoOut }
            return of(moveType: move.kind.rawValue)
        }
        return templateId.flatMap { of(moveType: $0.rawValue) }
    }
}
