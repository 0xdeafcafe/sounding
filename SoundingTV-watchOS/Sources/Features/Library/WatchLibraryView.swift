import SwiftUI

struct WatchLibraryView: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    WatchLibraryPlaylistsView(kind: .playlists)
                } label: {
                    WatchDestinationRow(title: "Playlists", systemImage: "music.note.list")
                }
                NavigationLink {
                    WatchLibraryArtistsView()
                } label: {
                    WatchDestinationRow(title: "Artists", systemImage: "person.2.fill")
                }
                NavigationLink {
                    WatchLibrarySongsView()
                } label: {
                    WatchDestinationRow(title: "Songs", systemImage: "music.note")
                }
                NavigationLink {
                    WatchDownloadsView()
                } label: {
                    WatchDestinationRow(title: "Downloaded", systemImage: "arrow.down.circle.fill")
                }
            }
        }
        .navigationTitle("Library")
        .containerBackground(WatchStyle.style.accent.gradient.opacity(0.28), for: .navigation)
    }
}

private enum WatchLibraryCollectionKind {
    case playlists

    var title: String {
        switch self {
        case .playlists: return "Playlists"
        }
    }

    var emptySystemImage: String {
        switch self {
        case .playlists: return "music.note.list"
        }
    }
}

private struct WatchLibraryPlaylistsView: View {
    let kind: WatchLibraryCollectionKind

    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var loadFailed = false

    var body: some View {
        List {
            if isLoading, playlists.isEmpty {
                WatchLoadingRow()
            } else if playlists.isEmpty {
                WatchEmptyState(
                    systemImage: loadFailed ? "wifi.slash" : kind.emptySystemImage,
                    title: loadFailed ? "Couldn't Load" : "No \(kind.title)",
                    message: loadFailed ? "Check your connection and try again." : nil
                )
            } else {
                ForEach(playlists) { playlist in
                    NavigationLink {
                        WatchPlaylistDetailView(playlist: playlist)
                    } label: {
                        WatchTrackRow(
                            title: playlist.title,
                            subtitle: playlist.user.displayName,
                            artworkURL: playlist.artworkURL
                        )
                    }
                }
            }
        }
        .navigationTitle(kind.title)
        .containerBackground(WatchStyle.style.accent.gradient.opacity(0.28), for: .navigation)
        .task {
            guard !didLoad else { return }
            didLoad = true
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            var owned: [Playlist] = []
            if let user = try? await SoundCloudAPI.shared.getCurrentUser() {
                owned = try await SoundCloudAPI.shared.getUserPlaylists(userId: user.id, limit: 50).collection
            }
            let liked = try await SoundCloudAPI.shared.getLikedPlaylists(limit: 50).collection
            playlists = (owned + liked)
                .deduplicatedByID()
                .filter { !$0.isAlbum }
            loadFailed = false
        } catch {
            loadFailed = playlists.isEmpty
        }
    }
}

extension WatchLibraryCollectionKind: Equatable {}

private struct WatchLibraryArtistsView: View {
    @State private var artists: [User] = []
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var loadFailed = false

    var body: some View {
        List {
            if isLoading, artists.isEmpty {
                WatchLoadingRow()
            } else if artists.isEmpty {
                WatchEmptyState(
                    systemImage: loadFailed ? "wifi.slash" : "person.2",
                    title: loadFailed ? "Couldn't Load" : "No Artists",
                    message: loadFailed
                        ? "Check your connection and try again."
                        : "Artists you follow land here."
                )
            } else {
                ForEach(artists) { user in
                    NavigationLink {
                        WatchArtistDetailView(user: user)
                    } label: {
                        WatchTrackRow(
                            title: user.displayName,
                            subtitle: "\(user.formattedFollowers) followers",
                            artworkURL: user.largeAvatarURL ?? user.avatarURL
                        )
                    }
                }
            }
        }
        .navigationTitle("Artists")
        .containerBackground(WatchStyle.style.accent.gradient.opacity(0.28), for: .navigation)
        .task {
            guard !didLoad else { return }
            didLoad = true
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let user = try await SoundCloudAPI.shared.getCurrentUser()
            artists = try await SoundCloudAPI.shared.getUserFollowings(userId: user.id, limit: 100).collection
            loadFailed = false
        } catch {
            loadFailed = artists.isEmpty
        }
    }
}

private struct WatchLibrarySongsView: View {
    @EnvironmentObject private var link: WatchLinkClient

    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var loadFailed = false

    var body: some View {
        List {
            if isLoading, tracks.isEmpty {
                WatchLoadingRow()
            } else if tracks.isEmpty {
                WatchEmptyState(
                    systemImage: loadFailed ? "wifi.slash" : "heart",
                    title: loadFailed ? "Couldn't Load" : "No Liked Songs",
                    message: loadFailed
                        ? "Check your connection and try again."
                        : "Tracks you like on SoundCloud land here."
                )
            } else {
                ForEach(tracks) { track in
                    Button {
                        link.play(trackId: track.id)
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
        }
        .navigationTitle("Songs")
        .containerBackground(WatchStyle.style.accent.gradient.opacity(0.28), for: .navigation)
        .task {
            guard !didLoad else { return }
            didLoad = true
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            tracks = try await SoundCloudAPI.shared.getLikedTracks(limit: 100).collection.map(\.item)
            loadFailed = false
        } catch {
            loadFailed = tracks.isEmpty
        }
    }
}
