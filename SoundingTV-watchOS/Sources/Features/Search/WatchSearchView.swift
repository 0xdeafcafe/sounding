import SwiftUI

struct WatchSearchView: View {
    @EnvironmentObject private var link: WatchLinkClient

    @State private var query = ""
    @State private var tracks: [Track] = []
    @State private var playlists: [Playlist] = []
    @State private var users: [User] = []
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var searchTask: Task<Void, Never>?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasResults: Bool {
        !tracks.isEmpty || !playlists.isEmpty || !users.isEmpty
    }

    var body: some View {
        List {
            if !tracks.isEmpty {
                Section("Tracks") {
                    ForEach(tracks) { track in
                        trackRow(track)
                    }
                }
            }
            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            WatchPlaylistDetailView(playlist: playlist)
                        } label: {
                            WatchTrackRow(
                                title: playlist.title,
                                subtitle: playlist.user.displayName,
                                artIdentity: playlist.id,
                                artworkURL: playlist.artworkURL
                            )
                        }
                    }
                }
            }
            if !users.isEmpty {
                Section("Artists") {
                    ForEach(users) { user in
                        NavigationLink {
                            WatchArtistDetailView(user: user)
                        } label: {
                            WatchTrackRow(
                                title: user.displayName,
                                subtitle: "\(user.formattedFollowers) followers",
                                artIdentity: user.id,
                                artworkURL: user.largeAvatarURL ?? user.avatarURL,
                                isCircular: true
                            )
                        }
                    }
                }
            }
        }
        .overlay {
            if trimmedQuery.isEmpty {
                ContentUnavailableView(
                    "Search",
                    systemImage: "magnifyingglass",
                    description: Text("Tracks, playlists and artists.")
                )
            } else if isSearching, !hasResults {
                WatchLoadingState(title: "Searching")
            } else if !hasResults {
                if searchFailed {
                    WatchErrorState(title: "Couldn’t Search") { scheduleSearch(for: query) }
                } else {
                    ContentUnavailableView.search(text: trimmedQuery)
                }
            }
        }
        .navigationTitle("Search")
        .watchNavigationTint()
        .searchable(text: $query, prompt: "Tracks, Playlists, Artists")
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func trackRow(_ track: Track) -> some View {
        Button {
            link.play(trackId: track.id)
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

    private func scheduleSearch(for text: String) {
        searchTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            tracks = []
            playlists = []
            users = []
            searchFailed = false
            isSearching = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ text: String) async {
        isSearching = true
        defer { isSearching = false }
        do {
            async let trackPage = SoundCloudAPI.shared.searchTracks(query: text, limit: 20)
            async let playlistPage = SoundCloudAPI.shared.searchPlaylists(query: text, limit: 10)
            async let userPage = SoundCloudAPI.shared.searchUsers(query: text, limit: 10)
            let (trackResult, playlistResult, userResult) = try await (trackPage, playlistPage, userPage)

            guard !Task.isCancelled else { return }
            tracks = trackResult.collection
            playlists = playlistResult.collection
            users = userResult.collection
            searchFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            searchFailed = true
        }
    }
}
