import Foundation

struct DJDeckSnapshot: Equatable {
    let deck: MixEngine.Deck
    let isLive: Bool
    let state: MixEngine.DeckState
    let beatGrid: BeatGrid?

    var trackId: String? { state.trackId }
    var position: TimeInterval { state.position }
    var duration: TimeInterval { state.duration }
    var rate: Double { state.rate }
    var level: Float { state.level }
    var peak: Float { state.peak }
}

struct DJSessionSnapshot: Equatable {
    let mixEngineState: MixEngineState
    let isAutoMixEnabled: Bool
    let liveDeck: MixEngine.Deck
    let decks: [DJDeckSnapshot]
    let crossfade: Double
    let masterVolume: Double
    let mixWindow: MixWindow?
    let activity: PhantomActivity
    let activePlan: PhantomDJEngine.Plan?
    let upcomingPlan: PhantomDJEngine.Plan?
    let profile: DJProfile?

    var liveDeckSnapshot: DJDeckSnapshot? { decks.first { $0.isLive } }
    var incomingDeckSnapshot: DJDeckSnapshot? { decks.first { !$0.isLive } }
}
