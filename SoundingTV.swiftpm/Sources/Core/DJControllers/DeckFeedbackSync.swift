import Foundation

@MainActor
enum DeckFeedbackSync {
    static func isTempoMatched(_ deck: MixEngine.Deck, in engine: MixEngine) -> Bool {
        let other = deck == .a ? MixEngine.Deck.b : .a
        guard engine[deck].status.isReady, engine[other].status.isReady,
              let grid = engine.beatGrid(for: deck), let otherGrid = engine.beatGrid(for: other) else { return false }
        return DeckFeedbackMath.isTempoMatched(
            beatPeriod: grid.beatPeriod,
            rate: engine[deck].rate,
            otherBeatPeriod: otherGrid.beatPeriod,
            otherRate: engine[other].rate
        )
    }

    static func beatPhase(_ deck: MixEngine.Deck, at position: TimeInterval, in engine: MixEngine) -> Double? {
        guard let grid = engine.beatGrid(for: deck) else { return nil }
        return DeckFeedbackMath.beatPhase(position: position, anchor: grid.anchor, beatPeriod: grid.beatPeriod)
    }
}
