import SwiftUI

struct WatchTrackInfoView: View {
    @EnvironmentObject private var link: WatchLinkClient

    @State private var track: Track?
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        List {
            Section {
                HStack(spacing: WatchStyle.style.spaceTight) {
                    WatchArtwork(url: track?.artworkURL ?? link.nowPlaying.artworkURL, size: 48, corner: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track?.title ?? link.nowPlaying.title)
                            .font(WatchStyle.style.fontBodyEmphasis)
                            .foregroundStyle(WatchStyle.style.textPrimary)
                            .lineLimit(2)
                        Text(track?.user.displayName ?? link.nowPlaying.artist)
                            .font(WatchStyle.style.fontCaption)
                            .foregroundStyle(WatchStyle.style.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }

            if isLoading, track == nil {
                WatchLoadingRow()
            } else if let track {
                Section {
                    Label(SCStatFormat.relativeDate(track.createdAt), systemImage: "calendar")
                    if let playbackCount = track.playbackCount {
                        Label("\(SCStatFormat.compactCount(playbackCount)) plays", systemImage: "play.fill")
                    }
                    Label("\(SCStatFormat.compactCount(track.likeCount)) likes", systemImage: "heart.fill")
                }
                .font(WatchStyle.style.fontCaption)
                .foregroundStyle(WatchStyle.style.textSecondary)

                if let description = track.description, !description.isEmpty {
                    Section {
                        Text(description)
                            .font(WatchStyle.style.fontCaption)
                            .foregroundStyle(WatchStyle.style.textSecondary)
                            .lineLimit(3)
                    } header: {
                        WatchSectionHeader(title: "Description")
                    }
                }
            } else if loadFailed {
                Section {
                    Text("No details for this track.")
                        .font(WatchStyle.style.fontCaption)
                        .foregroundStyle(WatchStyle.style.textTertiary)
                }
            }
        }
        .navigationTitle("About")
        .containerBackground(WatchStyle.style.accent.gradient.opacity(0.22), for: .navigation)
        .task(id: link.nowPlaying.trackId) { await load() }
    }

    private func load() async {
        guard let trackId = link.nowPlaying.trackId else {
            track = nil
            loadFailed = false
            return
        }
        // Reload when the playing track changes, even if we already cached one.
        guard track == nil || track?.id != trackId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            track = try await SoundCloudAPI.shared.getTrack(id: trackId)
            loadFailed = false
        } catch {
            track = nil
            loadFailed = true
        }
    }
}
