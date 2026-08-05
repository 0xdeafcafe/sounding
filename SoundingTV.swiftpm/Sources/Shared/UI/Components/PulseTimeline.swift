import SwiftUI

struct PulseTimeline<Content: View>: View {
    let isActive: Bool
    let reduceMotion: Bool
    var minimumInterval: Double = 1.0 / 30.0
    @ViewBuilder var content: (Pulse) -> Content

    var body: some View {
        if reduceMotion || !isActive {
            content(MusicPulse.shared.resting)
        } else {
            TimelineView(.animation(minimumInterval: minimumInterval)) { context in
                content(MusicPulse.shared.sample(at: context.date))
            }
        }
    }
}
