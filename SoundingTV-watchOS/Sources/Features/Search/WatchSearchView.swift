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
            if trimmedQuery.isEmpty {
                WatchEmptyState(
                    systemImage: "magnifyingglass",
                    title: "Search SoundCloud",
                    message: "Find tracks, playlists and artists."
                )
            } else if isSearching, !hasResults {
                WatchLoadingRow()
            } else if !hasResults {
                if searchFailed {
                    WatchEmptyState(
                        systemImage: "wifi.slash",
                        title: "Couldn't Search",
                        message: "Check your connection and try again."
                    )
                } else {
                    WatchEmptyState(
                        systemImage: "questionmark.circle",
                        title: "No Results",
                        message: "Nothing matched \"\(trimmedQuery)\"."
                    )
                }
            } else {
                if !tracks.isEmpty {
                    Section {
                        ForEach(tracks) { track in
                            trackRow(track)
                        }
                    } header: {
                        WatchSectionHeader(title: "Songs")
                    }
                }
                if !playlists.isEmpty {
                    Section {
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
                    } header: {
                        WatchSectionHeader(title: "Playlists")
                    }
                }
                if !users.isEmpty {
                    Section {
                        ForEach(users) { user in
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
                    } header: {
                        WatchSectionHeader(title: "Artists")
                    }
                }
            }
        }
        .navigationTitle("Search")
        .containerBackground(WatchStyle.style.accent.gradient.opacity(0.28), for: .navigation)
        .searchable(text: $query, prompt: "Songs, playlists, artists")
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
