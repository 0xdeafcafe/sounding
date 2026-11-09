import SwiftUI

/// Observes a PlaybackClock so only the progress UI inside `content`
/// re-renders at tick cadence; the parent keeps its slower PlayerService
/// cadence instead of invalidating twice a second during playback.
struct PlaybackClockView<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    @ViewBuilder let content: (PlaybackClock) -> Content

    var body: some View { content(clock) }
}
