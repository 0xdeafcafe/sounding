import SwiftUI

struct WatchDownloadsView: View {
    @EnvironmentObject private var link: WatchLinkClient

    var body: some View {
        Group {
            if link.downloads.items.isEmpty {
                WatchEmptyState(
                    systemImage: "arrow.down.circle",
                    title: "No Downloads",
                    message: "Downloads live on iPhone. Save one there and it lands here."
                )
            } else {
                List {
                    Section {
                        ForEach(link.downloads.items) { item in
                            Button {
                                link.play(trackId: item.id)
                            } label: {
                                WatchTrackRow(
                                    title: item.title,
                                    subtitle: item.artist,
                                    artworkURL: item.artworkURL,
                                    isPlaying: link.nowPlaying.trackId == item.id && link.nowPlaying.isPlaying
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        WatchSectionHeader(
                            title: "\(link.downloads.items.count) Tracks · \(link.downloads.totalBytes.watchByteString)"
                        )
                    }
                }
            }
        }
        .navigationTitle("Downloaded")
    }
}
