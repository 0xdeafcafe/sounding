import SwiftUI

struct WatchArtistDetailView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @StateObject private var viewModel: ArtistDetailViewModel

    init(user: User) {
        _viewModel = StateObject(wrappedValue: ArtistDetailViewModel(user: user))
    }

    private var user: User { viewModel.user }

    private var isEmpty: Bool {
        viewModel.tracks.isEmpty && viewModel.playlists.isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    header
                }
                .listRowBackground(Color.clear)

                if !viewModel.tracks.isEmpty {
                    Section("Popular") {
                        ForEach(viewModel.tracks.prefix(10)) { track in
                            trackRow(track)
                        }
                    }
                    .id("popular")
                }

                if !viewModel.playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(viewModel.playlists) { playlist in
                            NavigationLink {
                                WatchPlaylistDetailView(playlist: playlist)
                            } label: {
                                WatchTrackRow(
                                    title: playlist.title,
                                    subtitle: "\(playlist.totalTrackCount) tracks",
                                    artIdentity: playlist.id,
                                    artworkURL: playlist.artworkURL
                                )
                            }
                        }
                    }
                }

                if isEmpty {
                    Section {
                        if viewModel.isLoading(.tracks) {
                            WatchLoadingState()
                        } else if let message = viewModel.errorMessage(.tracks) {
                            WatchErrorState(message: message) { Task { await viewModel.reload(section: .tracks) } }
                        } else {
                            ContentUnavailableView("No Tracks", systemImage: "music.microphone")
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .task { await proxy.scrollToPreviewTarget() }
        }
        .navigationTitle(user.displayName)
        .task {
            await viewModel.loadOverviewIfNeeded()
        }
        .refreshable {
            await viewModel.reload(section: .tracks)
            await viewModel.reload(section: .playlists)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            WatchArtwork(
                url: user.largeAvatarURL ?? user.avatarURL,
                size: 72,
                corner: 36,
                identity: user.id
            )

            Text("\(user.formattedFollowers) followers")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !viewModel.tracks.isEmpty {
                WatchPlayShuffleButtons(subject: "\(user.displayName)’s tracks") {
                    link.play(artistId: user.id)
                } shuffle: {
                    link.play(artistId: user.id, shuffled: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func trackRow(_ track: Track) -> some View {
        Button {
            link.play(trackId: track.id)
        } label: {
            WatchTrackRow(
                title: track.title,
                subtitle: track.formattedDuration,
                artIdentity: track.id,
                artworkURL: track.artworkURL,
                isPlaying: link.nowPlaying.trackId == track.id
            )
            .accessibilityLabel("\(track.title), \(user.displayName), \(track.duration.watchSpokenDuration)")
        }
        .watchQueueActions(trackId: track.id)
    }
}
