import SwiftUI

struct WatchLibraryView: View {
    var body: some View {
        List {
            WatchOnThisWatchLibrarySection()

            Section {
                NavigationLink {
                    WatchLibraryPlaylistsView()
                } label: {
                    Label("Playlists", systemImage: "music.note.list")
                }
                NavigationLink {
                    WatchLibraryArtistsView()
                } label: {
                    Label("Artists", systemImage: "music.microphone")
                }
                NavigationLink {
                    WatchLibrarySongsView()
                } label: {
                    Label("Tracks", systemImage: "music.note")
                }
                NavigationLink {
                    WatchDownloadsView()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
            }
        }
        .navigationTitle("Library")
        .watchNavigationTint()
    }
}

@MainActor
private final class WatchPlaylistsSource {
    private var likedNext: URL?

    var source: PagedSource<Playlist> {
        PagedSource(
            first: { [self] in try await first() },
            next: { [self] cursor in try await next(cursor) }
        )
    }

    private func first() async throws -> PagedChunk<Playlist> {
        var owned: [Playlist] = []
        var ownedNext: URL?
        if let user = try? await SoundCloudAPI.shared.getCurrentUser() {
            let page = try await SoundCloudAPI.shared.getUserPlaylists(userId: user.id, limit: 50)
            owned = page.collection
            ownedNext = page.nextHref
        }
        let liked = try await SoundCloudAPI.shared.getLikedPlaylists(limit: 50)
        likedNext = liked.nextHref
        return chunk(owned + liked.collection, ownedNext: ownedNext)
    }

    private func next(_ cursor: PagedCursor) async throws -> PagedChunk<Playlist> {
        switch cursor {
        case .url(let url):
            let page = try await SoundCloudAPI.shared.getPage(Playlist.self, from: url)
            return chunk(page.collection, ownedNext: page.nextHref)
        case .offset:
            guard let url = likedNext else { return PagedChunk(items: []) }
            let page = try await SoundCloudAPI.shared.getPage(Like<Playlist>.self, from: url).map(\.item)
            likedNext = page.nextHref
            return chunk(page.collection, ownedNext: nil)
        case .start:
            return try await first()
        }
    }

    private func chunk(_ items: [Playlist], ownedNext: URL?) -> PagedChunk<Playlist> {
        let next: PagedCursor? = ownedNext.map { .url($0) } ?? (likedNext == nil ? nil : .offset(1))
        return PagedChunk(items: items.filter { !$0.isAlbum }, next: next)
    }
}

struct WatchLibraryPlaylistsView: View {
    @StateObject private var pager: Paginator<Playlist>
    @State private var didLoad = false

    init() {
        _pager = StateObject(wrappedValue: Paginator(soundCloudSource: WatchPlaylistsSource().source))
    }

    var body: some View {
        List {
            ForEach(pager.items) { playlist in
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
                .onAppear { pager.loadMoreIfNeeded(after: playlist, lead: 6) }
            }
            if !pager.items.isEmpty {
                PagedFooter(pager: pager)
            }
        }
        .overlay {
            if pager.items.isEmpty {
                if pager.firstError != nil {
                    WatchErrorState { Task { await pager.reload() } }
                } else if pager.hasLoadedFirst {
                    ContentUnavailableView("No Playlists", systemImage: "music.note.list")
                } else {
                    WatchLoadingState()
                }
            }
        }
        .navigationTitle("Playlists")
        .task {
            guard !didLoad else { return }
            didLoad = true
            #if DEBUG
            if VisualFixtures.isEnabled {
                pager.prime(items: VisualFixtures.playlists, cursor: nil)
                return
            }
            #endif
            await pager.reload()
        }
        .refreshable {
            await pager.reload()
        }
    }
}

struct WatchLibraryArtistsView: View {
    @StateObject private var pager = Paginator<User>(soundCloudSource: PagedSource(
        first: {
            let user = try await SoundCloudAPI.shared.getCurrentUser()
            let page = try await SoundCloudAPI.shared.getUserFollowings(userId: user.id, limit: 50)
            return PagedChunk(items: page.collection, next: page.nextHref.map { .url($0) })
        },
        next: { cursor in
            guard case .url(let url) = cursor else { return PagedChunk(items: []) }
            let page = try await SoundCloudAPI.shared.getPage(User.self, from: url)
            return PagedChunk(items: page.collection, next: page.nextHref.map { .url($0) })
        }
    ))
    @State private var didLoad = false

    var body: some View {
        List {
            ForEach(pager.items) { user in
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
                .onAppear { pager.loadMoreIfNeeded(after: user, lead: 6) }
            }
            if !pager.items.isEmpty {
                PagedFooter(pager: pager)
            }
        }
        .overlay {
            if pager.items.isEmpty {
                if pager.firstError != nil {
                    WatchErrorState { Task { await pager.reload() } }
                } else if pager.hasLoadedFirst {
                    ContentUnavailableView(
                        "No Artists",
                        systemImage: "music.microphone",
                        description: Text("Artists you follow appear here.")
                    )
                } else {
                    WatchLoadingState()
                }
            }
        }
        .navigationTitle("Artists")
        .task {
            guard !didLoad else { return }
            didLoad = true
            #if DEBUG
            if VisualFixtures.isEnabled {
                pager.prime(items: VisualFixtures.artists, cursor: nil)
                return
            }
            #endif
            await pager.reload()
        }
        .refreshable {
            await pager.reload()
        }
    }
}

struct WatchLibrarySongsView: View {
    @EnvironmentObject private var link: WatchLinkClient

    @StateObject private var pager = Paginator<Track>(soundCloudSource: PagedSource(
        first: {
            let page = try await SoundCloudAPI.shared.getLikedTracks(limit: 50)
            return PagedChunk(items: page.collection.map(\.item), next: page.nextHref.map { .url($0) })
        },
        next: { cursor in
            guard case .url(let url) = cursor else { return PagedChunk(items: []) }
            let page = try await SoundCloudAPI.shared.getPage(Like<Track>.self, from: url)
            return PagedChunk(items: page.collection.map(\.item), next: page.nextHref.map { .url($0) })
        }
    ))
    @State private var didLoad = false

    var body: some View {
        List {
            ForEach(pager.items) { track in
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
                .onAppear { pager.loadMoreIfNeeded(after: track, lead: 6) }
            }
            if !pager.items.isEmpty {
                PagedFooter(pager: pager)
            }
        }
        .overlay {
            if pager.items.isEmpty {
                if pager.firstError != nil {
                    WatchErrorState { Task { await pager.reload() } }
                } else if pager.hasLoadedFirst {
                    ContentUnavailableView(
                        "No Tracks",
                        systemImage: "heart",
                        description: Text("Tracks you like appear here.")
                    )
                } else {
                    WatchLoadingState()
                }
            }
        }
        .navigationTitle("Tracks")
        .task {
            guard !didLoad else { return }
            didLoad = true
            #if DEBUG
            if VisualFixtures.isEnabled {
                pager.prime(items: VisualFixtures.tracks, cursor: nil)
                return
            }
            #endif
            await pager.reload()
        }
        .refreshable {
            await pager.reload()
        }
    }
}
