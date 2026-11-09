import SwiftUI

struct WatchPlaylistDetailView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @StateObject private var viewModel: PlaylistDetailViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

            if viewModel.tracks.isEmpty {
                Section {
                    if viewModel.isLoading {
                        WatchLoadingState()
                    } else if let errorMessage = viewModel.errorMessage {
                        WatchErrorState(message: errorMessage) { Task { await viewModel.load() } }
                    } else {
                        ContentUnavailableView("No Tracks", systemImage: "music.note.list")
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.tracks) { track in
                        trackRow(track)
                            .onAppear {
                                viewModel.pager.loadMoreIfNeeded(after: track, lead: 8)
                            }
                    }
                    PagedFooter(pager: viewModel.pager)
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
        VStack(spacing: 8) {
            WatchArtwork(
                url: playlist.largeArtworkURL ?? playlist.artworkURL,
                size: 72,
                corner: 10,
                identity: playlist.id
            )

            Text("\(playlist.user.displayName) · \(playlist.totalTrackCount) tracks")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)

            WatchPlayShuffleButtons(subject: "this playlist") {
                link.play(collectionId: playlist.id)
            } shuffle: {
                link.play(collectionId: playlist.id, shuffled: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func trackRow(_ track: Track) -> some View {
        Button {
            link.play(trackId: track.id, collectionId: playlist.id)
        } label: {
            WatchTrackRow(
                title: track.title,
                subtitle: track.user.displayName,
                artIdentity: track.id,
                artworkURL: track.artworkURL,
                duration: track.duration,
                isPlaying: link.nowPlaying.trackId == track.id
            )
        }
        .watchQueueActions(trackId: track.id)
    }
}
