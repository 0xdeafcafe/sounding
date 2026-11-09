import SwiftUI

struct WatchTrackInfoView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @ObservedObject private var details = WatchNowPlayingDetails.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let track = details.track
        let isLoading = details.isLoading
        let loadFailed = details.didFail

        List {
            Section {
                HStack(spacing: 8) {
                    WatchArtwork(url: track?.artworkURL ?? link.nowPlaying.artworkURL, size: 48, corner: 10, identity: track?.id ?? link.nowPlaying.title)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track?.title ?? link.nowPlaying.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(track?.user.displayName ?? link.nowPlaying.artist)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }

            if isLoading, track == nil {
                WatchLoadingState()
            } else if let track {
                Section {
                    LabeledContent("Posted", value: SCStatFormat.relativeDate(track.createdAt))
                    if let playbackCount = track.playbackCount {
                        LabeledContent("Plays", value: SCStatFormat.compactCount(playbackCount))
                    }
                    LabeledContent("Likes", value: SCStatFormat.compactCount(track.likeCount))
                }

                if let description = track.description, !description.isEmpty {
                    Section("Description") {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 6)
                    }
                }
            } else if loadFailed {
                ContentUnavailableView("No Details", systemImage: "info.circle", description: Text("Couldn’t load this track."))
            }
        }
        .watchNowPlayingScreen("About")
        .task(id: link.nowPlaying.trackId) { details.load(trackId: link.nowPlaying.trackId) }
    }
}
