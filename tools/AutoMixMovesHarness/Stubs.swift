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
