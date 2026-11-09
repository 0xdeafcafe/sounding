import Foundation

@MainActor
enum MacDJPlayersDeckSource {
    static func leadDeck(decks: [MixEngine.DeckState], crossfade: Double, focused: MixEngine.Deck) -> MixEngine.Deck? {
        let ready = MixEngine.Deck.allCases.filter { decks[$0.rawValue].status.isReady }
        let playing = ready.filter { decks[$0.rawValue].isPlaying }
        if playing.count == 1 { return playing[0] }
        if playing.count > 1 { return crossfade <= 0.5 ? .a : .b }
        if ready.contains(focused) { return focused }
        return ready.first
    }

    static func snapshot(decks: [MixEngine.DeckState], now: TimeInterval) -> DJVirtualDeckSnapshot {
        let engine = MixEngine.shared
        guard let deck = leadDeck(decks: decks, crossfade: engine.crossfade, focused: MacConsoleController.shared.focusedDeck) else {
            return .empty
        }
        let state = decks[deck.rawValue]
        let grid = engine.beatGrid(for: deck).flatMap { $0.beatPeriod > 0 ? $0 : nil }
        return DJVirtualDeckSnapshot(
            isLoaded: true,
            isPlaying: state.isPlaying,
            trackBPM: grid?.bpm,
            rate: state.rate,
            positionSeconds: engine.currentPlayhead(for: deck),
            anchorTime: now,
            gridAnchorSeconds: grid?.anchor ?? 0,
            downbeatOffset: grid?.downbeatOffset ?? 0,
            durationSeconds: state.duration
        )
    }
}

@MainActor
enum MacDJPlayersTempoFollower {
    static let phaseTolerance: Double = 0.006
    static let maxPercent: Double = MixEngine.maxTempoMatchPercent
    private static var appliedRatios: [Int: Double] = [:]

    static func reset() {
        appliedRatios.removeAll()
    }

    static func followsTempo(_ deck: MixEngine.Deck, autoManaged: Set<Int>, player: PlayerService) -> Bool {
        guard autoManaged.contains(deck.rawValue) else { return true }
        return player.isAutoMixEnabled && deck == player.liveDeck && !player.djDirector.isCrossfading
    }

    static func follow(_ tempo: DJPlayersTempoReference, now: TimeInterval) {
        let engine = MixEngine.shared
        let autoManaged = MacDeckTrackRegistry.shared.autoManagedDecks
        let player = PlayerService.shared
        for deck in MixEngine.Deck.allCases where followsTempo(deck, autoManaged: autoManaged, player: player) {
            let state = engine[deck]
            guard state.status.isReady, state.isPlaying,
                  let grid = engine.beatGrid(for: deck), grid.beatPeriod > 0,
                  let ratio = tempo.playbackRatio(forTrackBPM: grid.bpm, maxPercent: maxPercent) else { continue }
            let needsRate = appliedRatios[deck.rawValue].map { abs($0 - ratio) > 0.0005 || abs(state.rate - ratio) >= 0.09 } ?? true
            if needsRate {
                appliedRatios[deck.rawValue] = ratio
                engine.setRate(ratio, on: deck, over: 0.12)
                continue
            }
            let deckPhase = grid.beatPhase(at: engine.currentPlayhead(for: deck)) / grid.beatPeriod
            guard let difference = tempo.beatPhaseDifference(ofDeck: deckPhase, at: now) else { continue }
            let errorSeconds = difference * tempo.beatPeriod
            guard abs(errorSeconds) > phaseTolerance else { continue }
            engine.nudge(deck: deck, amount: -difference * 8, releaseSeconds: 0.24)
        }
    }
}
