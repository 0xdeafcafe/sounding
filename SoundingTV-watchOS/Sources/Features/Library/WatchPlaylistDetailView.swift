import SwiftUI

struct WatchPlaylistDetailView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @StateObject private var viewModel: PlaylistDetailViewModel

    init(playlist: Playlist) {
        _viewModel = StateObject(wrappedValue: PlaylistDetailViewModel(playlist: playlist))
    }

    private var playlist: Playlist { viewModel.playlist }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowBackground(Color.clear)

            if viewModel.tracks.isEmpty, viewModel.isLoading {
                WatchLoadingRow()
            } else if viewModel.tracks.isEmpty {
                if let errorMessage = viewModel.errorMessage {
                    WatchEmptyState(systemImage: "wifi.slash", title: "Couldn't Load", message: errorMessage)
                } else {
                    WatchEmptyState(systemImage: "music.note.list", title: "No Tracks")
                }
            } else {
                Section {
                    ForEach(viewModel.tracks) { track in
                        trackRow(track)
                            .task {
                                if viewModel.tracks.isNearEnd(track, lead: 8) {
                                    await viewModel.loadMore()
                                }
                            }
                    }
                    if viewModel.isLoadingMore {
                        WatchLoadingRow()
                    }
                } header: {
                    WatchSectionHeader(title: "Tracks")
                }
            }
        }
        .navigationTitle(playlist.title)
        .task {
            await viewModel.loadIfNeeded()
        }
        .refreshable {
            await viewModel.load()
        }
    }

    private var header: some View {
        VStack(spacing: WatchStyle.style.spaceSnug) {
            WatchArtwork(
                url: playlist.largeArtworkURL ?? playlist.artworkURL,
                size: 96,
                corner: WatchStyle.style.cornerHero
            )

            VStack(spacing: 1) {
                Text(playlist.title)
                    .font(WatchStyle.style.fontHeadline)
                    .foregroundStyle(WatchStyle.style.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("\(playlist.user.displayName) · \(playlist.totalTrackCount) track\(playlist.totalTrackCount == 1 ? "" : "s")")
                    .font(WatchStyle.style.fontCaption)
                    .foregroundStyle(WatchStyle.style.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: WatchStyle.style.spaceTight) {
                Button {
                    link.play(collectionId: playlist.id)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(WatchStyle.style.accent)

                Button {
                    link.play(collectionId: playlist.id, shuffled: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)
                .tint(WatchStyle.style.accentMuted)
            }
            .font(WatchStyle.style.fontCaptionEmphasis)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WatchStyle.style.spaceTight)
    }

    private func trackRow(_ track: Track) -> some View {
        Button {
            link.play(trackId: track.id, collectionId: playlist.id)
        } label: {
            WatchTrackRow(
                title: track.title,
                subtitle: track.user.displayName,
                artworkURL: track.artworkURL,
                isPlaying: link.nowPlaying.trackId == track.id
            )
        }
        .swipeActions(edge: .trailing) {
            Button {
                link.enqueue(trackId: track.id, action: .playNext)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(WatchStyle.style.accent)
        }
    }
}
