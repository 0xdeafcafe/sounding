import Foundation
import os

enum ArtistDetailSection: String, CaseIterable {
    case tracks    = "Tracks"
    case playlists = "Playlists"
    case reposts   = "Reposts"
    case likes     = "Likes"
}

@MainActor
final class ArtistDetailViewModel: ObservableObject {
    private struct CacheEntry {
        let savedAt: Date
        let tracks: [Track]
        let playlists: [Playlist]
        let repostedTracks: [Track]
        let repostedPlaylists: [Playlist]
        let repostItems: [StreamItem]
        let likedTracks: [Track]
        let likeItems: [Like<Track>]
        let loadedSections: Set<ArtistDetailSection>
        let tracksPage: Page<Track>?
        let playlistsPage: Page<Playlist>?
        let repostsPage: Page<StreamItem>?
        let likesPage: Page<Like<Track>>?
    }

    private static let cacheLifetime: TimeInterval = 15 * 60
    private static var profileCache: [String: CacheEntry] = [:]

    let user: User

    @Published var selectedSection: ArtistDetailSection = .tracks
    @Published var tracks: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var repostedTracks: [Track] = []
    @Published var repostedPlaylists: [Playlist] = []
    @Published var repostItems: [StreamItem] = []
    @Published var likedTracks: [Track] = []
    @Published var likeItems: [Like<Track>] = []
    @Published private(set) var loadingMore: Set<ArtistDetailSection> = []

    private var loadingStates: [ArtistDetailSection: Bool] = [:]
    private var errorMessages: [ArtistDetailSection: String] = [:]
    private var loadedSections: Set<ArtistDetailSection> = []

    private let api = SoundCloudAPI.shared
    private var tracksCursor = PageCursor<Track>()
    private var playlistsCursor = PageCursor<Playlist>()
    private var repostsCursor = PageCursor<StreamItem>()
    private var likesCursor = PageCursor<Like<Track>>()

    init(user: User) {
        self.user = user
        guard let cached = Self.profileCache[user.id],
              Date().timeIntervalSince(cached.savedAt) < Self.cacheLifetime else { return }
        tracks = cached.tracks
        playlists = cached.playlists
        repostedTracks = cached.repostedTracks
        repostedPlaylists = cached.repostedPlaylists
        repostItems = cached.repostItems
        likedTracks = cached.likedTracks
        likeItems = cached.likeItems
        loadedSections = cached.loadedSections
        if let page = cached.tracksPage { tracksCursor.advance(to: page) }
        if let page = cached.playlistsPage { playlistsCursor.advance(to: page) }
        if let page = cached.repostsPage { repostsCursor.advance(to: page) }
        if let page = cached.likesPage { likesCursor.advance(to: page) }
    }

    func isLoading(_ section: ArtistDetailSection) -> Bool { loadingStates[section] ?? false }
    func errorMessage(_ section: ArtistDetailSection) -> String? { errorMessages[section] }

    func loadIfNeeded() async {
        guard !loadedSections.contains(selectedSection) else { return }
        await reload(section: selectedSection)
    }

    func loadOverviewIfNeeded() async {
        if !loadedSections.contains(.tracks) {
            await reload(section: .tracks)
        }
        if !loadedSections.contains(.playlists) {
            await reload(section: .playlists)
        }
    }

    func loadActivityIfNeeded() async {
        if !loadedSections.contains(.tracks) {
            await reload(section: .tracks)
        }
        if !loadedSections.contains(.reposts) {
            await reload(section: .reposts)
        }
        if !loadedSections.contains(.likes) {
            await reload(section: .likes)
        }
    }

    func reload(section: ArtistDetailSection) async {
        #if DEBUG && os(tvOS)
        if VisualFixtures.isEnabled {
            switch section {
            case .tracks:
                tracks = VisualFixtures.tracks.filter { $0.user.id == user.id }
                if tracks.isEmpty { tracks = Array(VisualFixtures.tracks.prefix(8)) }
            case .playlists:
                playlists = VisualFixtures.albums.filter { $0.user.id == user.id }
                    + Array(VisualFixtures.playlists.prefix(3))
            case .reposts:
                repostedTracks = Array(VisualFixtures.tracks.dropFirst(4).prefix(8))
                repostedPlaylists = Array(VisualFixtures.playlists.prefix(4))
            case .likes:
                likedTracks = Array(VisualFixtures.tracks.dropFirst(2).prefix(10))
            }
            loadedSections.insert(section)
            return
        }
        #endif

        loadingStates[section] = true
        errorMessages[section] = nil
        defer { loadingStates[section] = false }

        do {
            switch section {
            case .tracks:
                let page = try await api.getUserTracks(userId: user.id, limit: 50)
                tracks = page.collection
                tracksCursor.advance(to: page)
            case .playlists:
                let page = try await api.getUserPlaylists(userId: user.id, limit: 50)
                playlists = page.collection
                playlistsCursor.advance(to: page)
            case .reposts:
                let page = try await api.getUserReposts(userId: user.id, limit: 50)
                repostItems = page.collection
                repostedTracks = page.collection.compactMap(\.track)
                repostedPlaylists = page.collection.compactMap(\.playlist)
                repostsCursor.advance(to: page)
            case .likes:
                let page = try await api.getUserLikes(userId: user.id, limit: 50)
                likeItems = page.collection
                likedTracks = page.collection.map(\.item)
                likesCursor.advance(to: page)
            }
            loadedSections.insert(section)
            persistCache()
        } catch {
            errorMessages[section] = "Couldn't reach SoundCloud. Check your connection and try again."
        }
    }

    func loadMore(section: ArtistDetailSection) async {
        guard !loadingMore.contains(section), canLoadMore(section) else { return }
        loadingMore.insert(section)
        defer { loadingMore.remove(section) }

        do {
            switch section {
            case .tracks:
                guard let page = tracksCursor.lastPage else { return }
                let next = try await api.getNextPage(page)
                tracksCursor.advance(to: next)
                tracks.appendUnique(contentsOf: next.collection)
            case .playlists:
                guard let page = playlistsCursor.lastPage else { return }
                let next = try await api.getNextPage(page)
                playlistsCursor.advance(to: next)
                playlists.appendUnique(contentsOf: next.collection)
            case .reposts:
                guard let page = repostsCursor.lastPage else { return }
                let next = try await api.getNextPage(page)
                repostsCursor.advance(to: next)
                let existing = Set(repostItems.map { "\($0.createdAt.timeIntervalSince1970)-\($0.track?.id ?? $0.playlist?.id ?? "")" })
                repostItems += next.collection.filter {
                    !existing.contains("\($0.createdAt.timeIntervalSince1970)-\($0.track?.id ?? $0.playlist?.id ?? "")")
                }
                repostedTracks.appendUnique(contentsOf: next.collection.compactMap(\.track))
                repostedPlaylists.appendUnique(contentsOf: next.collection.compactMap(\.playlist))
            case .likes:
                guard let page = likesCursor.lastPage else { return }
                let next = try await api.getNextPage(page)
                likesCursor.advance(to: next)
                let existing = Set(likeItems.map { "\($0.item.id)-\($0.createdAt.timeIntervalSince1970)" })
                likeItems += next.collection.filter {
                    !existing.contains("\($0.item.id)-\($0.createdAt.timeIntervalSince1970)")
                }
                likedTracks.appendUnique(contentsOf: next.collection.map(\.item))
            }
            persistCache()
        } catch {
            Log.ui.error("Artist detail load-more error (\(self.user.id, privacy: .public)/\(String(describing: section), privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    func setPlaylistSharing(_ playlist: Playlist, to sharing: String) async throws {
        let updated = try await api.setPlaylistSharing(sharing, playlistId: playlist.id)
        if let index = playlists.firstIndex(where: { $0.id == updated.id }) {
            playlists[index] = updated
        }
        persistCache()
    }

    private func persistCache() {
        Self.profileCache[user.id] = CacheEntry(
            savedAt: Date(),
            tracks: tracks,
            playlists: playlists,
            repostedTracks: repostedTracks,
            repostedPlaylists: repostedPlaylists,
            repostItems: repostItems,
            likedTracks: likedTracks,
            likeItems: likeItems,
            loadedSections: loadedSections,
            tracksPage: tracksCursor.lastPage,
            playlistsPage: playlistsCursor.lastPage,
            repostsPage: repostsCursor.lastPage,
            likesPage: likesCursor.lastPage
        )
    }

    private func canLoadMore(_ section: ArtistDetailSection) -> Bool {
        switch section {
        case .tracks:    return tracksCursor.canLoadMore
        case .playlists: return playlistsCursor.canLoadMore
        case .reposts:   return repostsCursor.canLoadMore
        case .likes:     return likesCursor.canLoadMore
        }
    }
}
