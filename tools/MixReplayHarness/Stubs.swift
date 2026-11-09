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
