import SwiftUI

enum MacNowPlayingAutoMixMetrics {
    static let decksExtra: CGFloat = 240
    static let lineWidth: CGFloat = 520

    static func lineHeight(for state: AutoMixLiveState) -> CGFloat {
        AutoMixLiveScale.mac.nextMixHeight
    }

    static func reserved(for state: AutoMixLiveState?, ratingPending: Bool = false) -> CGFloat {
        guard let state else { return ratingPending ? 74 + 14 : 0 }
        return lineHeight(for: state) + 14 + (showsDecks(state) ? decksExtra : 0)
    }

    static func showsDecks(_ state: AutoMixLiveState) -> Bool {
        state.stage == .mixing && state.outgoing != nil
    }
}

struct MacNowPlayingAutoMixLine: View {
    let state: AutoMixLiveState
    var tint: Color = .white

    @State private var showingPlan = false

    var body: some View {
        Button {
            showingPlan = true
        } label: {
            AutoMixNextMixCapsule(state: state, scale: .mac, tint: tint) {
                ArtworkThumbnail(url: artworkURL, identity: state.incomingTrackId ?? state.incomingTitle, size: 32, cornerRadius: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.capsule)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .help(state.stage == .mixing ? "Show the plan for this mix" : "Show the plan for the next mix")
        .popover(isPresented: $showingPlan, arrowEdge: .bottom) {
            MacAutoMixPlanPopover(isPresented: $showingPlan)
        }
    }

    private var artworkURL: URL? {
        guard let id = state.incomingTrackId else { return nil }
        return PlaybackQueueStore.shared.queue.first { $0.id == id }?.artworkURL
    }
}

struct MacAutoMixPlanPopover: View {
    @Binding var isPresented: Bool

    var body: some View {
        Group {
            if let state = AutoMixLive.shared.state {
                AutoMixPlanForm(
                    state: state,
                    onMixNow: {
                        PlayerService.shared.startMix()
                        isPresented = false
                    },
                    onExtend: { PlayerService.shared.extendMix() },
                    onSkip: {
                        Task { await Self.skip(state) }
                        isPresented = false
                    }
                )
            } else {
                ContentUnavailableView("No Mix Planned", systemImage: "arrow.triangle.merge")
            }
        }
        .frame(width: 340, height: 420)
    }

    private static func skip(_ state: AutoMixLiveState) async {
        let player = PlayerService.shared
        guard let id = state.incomingTrackId,
              let index = player.queue.indices.first(where: { $0 > player.currentIndex && player.queue[$0].id == id }) else { return }
        await player.removeFromQueue(at: index)
    }
}

struct MacNowPlayingAutoMixDecks: View {
    let state: AutoMixLiveState
    let tint: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            AutoMixDecksView(state: state, scale: .mac, tint: tint, showsTransition: false)
            Button("Show in Decks", systemImage: "slider.horizontal.3") {
                MacRootSelection.shared.request(.console)
                MacNowPlayingPresentation.shared.requestClose()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}
