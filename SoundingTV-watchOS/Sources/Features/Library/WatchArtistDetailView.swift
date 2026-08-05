import SwiftUI

struct WatchArtistDetailView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @StateObject private var viewModel: ArtistDetailViewModel

    init(user: User) {
        _viewModel = StateObject(wrappedValue: ArtistDetailViewModel(user: user))
    }

    private var user: User { viewModel.user }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowBackground(Color.clear)

            if viewModel.isLoading(.tracks), viewModel.tracks.isEmpty, viewModel.playlists.isEmpty {
                WatchLoadingRow()
            } else {
                if !viewModel.tracks.isEmpty {
                    Section {
                        ForEach(viewModel.tracks.prefix(10)) { track in
                            trackRow(track)
                        }
                    } header: {
                        WatchSectionHeader(title: "Popular")
                    }
                }

                if !viewModel.playlists.isEmpty {
                    Section {
                        ForEach(viewModel.playlists) { playlist in
                            NavigationLink {
                                WatchPlaylistDetailView(playlist: playlist)
                            } label: {
                                WatchTrackRow(
                                    title: playlist.title,
                                    subtitle: "\(playlist.totalTrackCount) track\(playlist.totalTrackCount == 1 ? "" : "s")",
                                    artworkURL: playlist.artworkURL
                                )
                            }
                        }
                    } header: {
                        WatchSectionHeader(title: "Playlists")
                    }
                }

                if viewModel.tracks.isEmpty, viewModel.playlists.isEmpty {
                    WatchEmptyState(
                        systemImage: viewModel.errorMessage(.tracks) != nil ? "wifi.slash" : "music.mic",
                        title: viewModel.errorMessage(.tracks) != nil ? "Couldn't Load" : "Nothing Here",
                        message: viewModel.errorMessage(.tracks)
                    )
                }
            }
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
        VStack(spacing: WatchStyle.style.spaceSnug) {
            WatchArtwork(
                url: user.largeAvatarURL ?? user.avatarURL,
                size: 72,
                corner: 36
            )

            VStack(spacing: 1) {
                Text(user.displayName)
                    .font(WatchStyle.style.fontHeadline)
                    .foregroundStyle(WatchStyle.style.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("\(user.formattedFollowers) followers")
                    .font(WatchStyle.style.fontCaption)
                    .foregroundStyle(WatchStyle.style.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WatchStyle.style.spaceTight)
    }

    private func trackRow(_ track: Track) -> some View {
        Button {
            link.play(trackId: track.id)
        } label: {
            WatchTrackRow(
                title: track.title,
                subtitle: track.formattedDuration,
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
