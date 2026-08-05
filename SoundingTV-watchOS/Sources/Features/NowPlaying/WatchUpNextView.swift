import SwiftUI

struct WatchUpNextView: View {
    @EnvironmentObject private var link: WatchLinkClient

    var body: some View {
        content
            .navigationTitle("Up Next")
            .containerBackground(WatchStyle.style.accent.gradient.opacity(0.22), for: .navigation)
    }

    @ViewBuilder
    private var content: some View {
        // The phone link does not publish the queue itself — only a count
        // (WatchNowPlaying.queueCount) and the Auto DJ's single planned next
        // track (WatchDJState.nextTitle/nextArtist). Only those genuine
        // entries are shown; individual queued tracks are not on the wire.
        let dj = link.djState
        let queueCount = link.nowPlaying.queueCount

        List {
            if dj.nextTitle == nil, queueCount == 0 {
                WatchEmptyState(
                    systemImage: "music.note.list",
                    title: "Nothing Queued Yet",
                    message: "Queue something from Search or Library."
                )
            } else {
                if let nextTitle = dj.nextTitle {
                    Section {
                        WatchTrackRow(
                            title: nextTitle,
                            subtitle: dj.nextArtist ?? "",
                            artworkURL: dj.nextArtworkURL,
                            trailingSystemImage: "arrow.turn.down.right"
                        )
                    } header: {
                        WatchSectionHeader(title: "Auto DJ")
                    }
                }

                if queueCount > 0 {
                    Section {
                        Label(
                            queueCount == 1 ? "1 track queued on iPhone" : "\(queueCount) tracks queued on iPhone",
                            systemImage: "iphone"
                        )
                        .font(WatchStyle.style.fontCaption)
                        .foregroundStyle(WatchStyle.style.textSecondary)
                    } footer: {
                        Text("The full queue lives on iPhone.")
                            .font(WatchStyle.style.fontCaption)
                            .foregroundStyle(WatchStyle.style.textTertiary)
                    }
                }
            }
        }
    }
}
