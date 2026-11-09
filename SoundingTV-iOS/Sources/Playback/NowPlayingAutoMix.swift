import SwiftUI

enum NowPlayingAutoMixMetrics {
    static let decksHeight: CGFloat = 190

    static func lineHeight(for state: AutoMixLiveState) -> CGFloat {
        AutoMixLiveScale.phone.nextMixHeight
    }
}

struct NowPlayingAutoMixLine: View {
    let state: AutoMixLiveState
    var tint: Color = .white
    let onTap: () -> Void

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    var body: some View {
        Button(action: onTap) {
            AutoMixNextMixCapsule(state: state, scale: .phone, tint: tint) {
                ArtworkThumbnail(url: artworkURL, size: 36, cornerRadius: 7, identity: state.incomingTrackId ?? state.incomingTitle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.capsule)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .foregroundStyle(NPInk.primary)
        .accessibilityHint("Shows the plan for the next mix")
    }

    private var artworkURL: URL? {
        guard let id = state.incomingTrackId else { return nil }
        if let nowPlaying = coordinator.nowPlaying, nowPlaying.trackId == id {
            return nowPlaying.artworkURL.flatMap { URL(string: $0) }
        }
        return coordinator.upNextEntries.first { $0.trackID == id }?.artworkURL.flatMap { URL(string: $0) }
    }
}

struct NowPlayingAutoMixDecks: View {
    let state: AutoMixLiveState
    let tint: Color

    var body: some View {
        AutoMixDecksView(state: state, scale: .phone, tint: tint, showsTransition: false)
            .foregroundStyle(NPInk.primary)
    }
}

struct NowPlayingAutoMixPlanSheet: View {
    @Binding var isPresented: Bool

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    var body: some View {
        NavigationStack {
            Group {
                if let state = coordinator.autoMixLive {
                    AutoMixPlanForm(
                        state: state,
                        onMixNow: {
                            coordinator.mixNow()
                            isPresented = false
                        },
                        onExtend: { coordinator.extendMix() },
                        onSkip: {
                            coordinator.skipUpcomingMix(state)
                            isPresented = false
                        }
                    )
                } else {
                    ContentUnavailableView("No Mix Planned", systemImage: "arrow.triangle.merge")
                }
            }
            .navigationTitle(coordinator.autoMixLive?.stage == .mixing ? "Mixing" : "Next Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
