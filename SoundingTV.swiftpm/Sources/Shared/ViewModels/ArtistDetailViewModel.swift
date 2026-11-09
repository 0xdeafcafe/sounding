import Foundation
import Combine
import Observation
import os

enum ArtistDetailSection: String, CaseIterable {
    case tracks    = "Tracks"
    case playlists = "Playlists"
    case reposts   = "Reposts"
    case likes     = "Likes"
}

struct ArtistRepostEntry: Identifiable {
    let item: StreamItem

    var id: String { "\(item.createdAt.timeIntervalSince1970)-\(item.track?.id ?? item.playlist?.id ?? "")" }
}

struct ArtistLikeEntry: Identifiable {
    let track: Track
    let like: Like<Track>?

    var id: String { track.id }

    init(like: Like<Track>) {
        self.track = like.item
        self.like = like
    }

    init(track: Track) {
        self.track = track
        self.like = nil
    }
}

@MainActor
fileprivate protocol ArtistSectionPaging: AnyObject {
    var isLoadingFirst: Bool { get }
    var isLoadingMore: Bool { get }
    var hasLoadedFirst: Bool { get }
    var hasMore: Bool { get }
    var firstError: Error? { get }
    var didFailLoadingMore: Bool { get }
    var isPaused: Bool { get }
    func reload() async
    func loadMore() async
    func requestMore()
}

extension Paginator: ArtistSectionPaging {}

@MainActor
final class ArtistDetailViewModel: ObservableObject {
    private struct CacheEntry {
        let savedAt: Date
        let tracks: [Track]
        let playlists: [Playlist]
        let reposts: [ArtistRepostEntry]
        let likes: [ArtistLikeEntry]
        let loadedSections: Set<ArtistDetailSection>
        let tracksCursor: PagedCursor?
        let playlistsCursor: PagedCursor?
        let repostsCursor: PagedCursor?
        let likesCursor: PagedCursor?
    }

    private static let cacheLifetime: TimeInterval = 15 * 60
    private static var profileCache: [String: CacheEntry] = [:]

    let user: User

    @Published var selectedSection: ArtistDetailSection = .tracks
    @Published private(set) var popularTracks: [Track] = []
    private var didLoadPopular = false

    let tracksPager: Paginator<Track>
    let playlistsPager: Paginator<Playlist>
    let repostsPager: Paginator<ArtistRepostEntry>
    let likesPager: Paginator<ArtistLikeEntry>

    var tracks: [Track] { tracksPager.items }
    var playlists: [Playlist] { playlistsPager.items }
    var repostItems: [StreamItem] { repostsPager.items.map(\.item) }
    var repostedTracks: [Track] {
        var result: [Track] = []
        result.appendUnique(contentsOf: repostsPager.items.compactMap(\.item.track))
        return result
    }
    var repostedPlaylists: [Playlist] {
        var result: [Playlist] = []
        result.appendUnique(contentsOf: repostsPager.items.compactMap(\.item.playlist))
        return result
    }
    var likeItems: [Like<Track>] { likesPager.items.compactMap(\.like) }
    var likedTracks: [Track] { likesPager.items.map(\.track) }

    var loadingMore: Set<ArtistDetailSection> {
        Set(ArtistDetailSection.allCases.filter { pager(for: $0).isLoadingMore })
    }

    private var loadedSections: Set<ArtistDetailSection> = []
    private var cancellables: Set<AnyCancellable> = []

    private let api = SoundCloudAPI.shared

    init(user: User) {
        self.user = user
        tracksPager = Paginator(soundCloudSource: Self.emptySource())
        playlistsPager = Paginator(soundCloudSource: Self.emptySource())
        repostsPager = Paginator(soundCloudSource: Self.emptySource())
        likesPager = Paginator(soundCloudSource: Self.emptySource())

        let api = api
        let userID = user.id
        tracksPager.setSource(Self.source(
            first: { try await api.getUserTracks(userId: userID, limit: 50) },
            next: { try await api.getPage(Track.self, from: $0) },
            transform: { $0 }
        ))
        playlistsPager.setSource(Self.source(
            first: { try await api.getUserPlaylists(userId: userID, limit: 50) },
            next: { try await api.getPage(Playlist.self, from: $0) },
            transform: { $0 }
        ))
        repostsPager.setSource(Self.source(
            first: { try await api.getUserReposts(userId: userID, limit: 50) },
            next: { try await api.getPage(StreamItem.self, from: $0) },
            transform: { ArtistRepostEntry(item: $0) }
        ))
        likesPager.setSource(Self.source(
            first: { try await api.getUserLikes(userId: userID, limit: 50) },
            next: { try await api.getPage(Like<Track>.self, from: $0) },
            transform: { ArtistLikeEntry(like: $0) }
        ))

        if let cached = Self.profileCache[user.id], Date().timeIntervalSince(cached.savedAt) < Self.cacheLifetime {
            tracksPager.prime(items: cached.tracks, cursor: cached.tracksCursor)
            playlistsPager.prime(items: cached.playlists, cursor: cached.playlistsCursor)
            repostsPager.prime(items: cached.reposts, cursor: cached.repostsCursor)
            likesPager.prime(items: cached.likes, cursor: cached.likesCursor)
            loadedSections = cached.loadedSections
        }

        tracksPager.objectWillChange
            .merge(with: playlistsPager.objectWillChange, repostsPager.objectWillChange, likesPager.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        tracksPager.$cursor
            .map { _ in () }
            .merge(
                with: playlistsPager.$cursor.map { _ in () },
                repostsPager.$cursor.map { _ in () },
                likesPager.$cursor.map { _ in () }
            )
            .dropFirst(4)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, !self.loadedSections.isEmpty else { return }
                self.persistCache()
            }
            .store(in: &cancellables)
    }

    private static func emptySource<Item>() -> PagedSource<Item> {
        PagedSource(first: { PagedChunk(items: []) }, next: { _ in PagedChunk(items: []) })
    }

    private static func source<Raw: Codable, Item>(
        first: @escaping @MainActor () async throws -> Page<Raw>,
        next: @escaping @MainActor (URL) async throws -> Page<Raw>,
        transform: @escaping @MainActor (Raw) -> Item
    ) -> PagedSource<Item> {
        func chunk(_ page: Page<Raw>) -> PagedChunk<Item> {
            PagedChunk(items: page.collection.map(transform), next: page.nextHref.map { .url($0) })
        }
        return PagedSource(
            first: { chunk(try await first()) },
            next: { cursor in
                guard case .url(let url) = cursor else { return chunk(try await first()) }
                return chunk(try await next(url))
            }
        )
    }

    private func pager(for section: ArtistDetailSection) -> any ArtistSectionPaging {
        switch section {
        case .tracks:    return tracksPager
        case .playlists: return playlistsPager
        case .reposts:   return repostsPager
        case .likes:     return likesPager
        }
    }

    func isLoading(_ section: ArtistDetailSection) -> Bool {
        let pager = pager(for: section)
        return pager.isLoadingFirst || (pager.isPaused && !pager.hasLoadedFirst)
    }

    func errorMessage(_ section: ArtistDetailSection) -> String? {
        guard pager(for: section).firstError != nil else { return nil }
        return "Couldn't reach SoundCloud. Check your connection and try again."
    }

    func canAutoLoadMore(_ section: ArtistDetailSection) -> Bool {
        let pager = pager(for: section)
        return pager.hasMore && !pager.didFailLoadingMore && !pager.isPaused
    }

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
        await loadPopularIfNeeded()
    }

    var topTracks: [Track] {
        let source = popularTracks.isEmpty ? tracks : popularTracks
        return source.enumerated().sorted { lhs, rhs in
            let left = lhs.element.playbackCount ?? 0
            let right = rhs.element.playbackCount ?? 0
            return left == right ? lhs.offset < rhs.offset : left > right
        }
        .map(\.element)
    }

    private func loadPopularIfNeeded() async {
        guard !didLoadPopular else { return }
        #if DEBUG
        if VisualFixtures.isEnabled { return }
        #endif
        guard !tracks.isEmpty, tracksPager.hasMore else {
            didLoadPopular = true
            return
        }
        didLoadPopular = true
        do {
            popularTracks = try await api.getUserTopTracks(userId: user.id, limit: 10).collection
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { didLoadPopular = false }
        }
    }

    func hasLoaded(_ section: ArtistDetailSection) -> Bool {
        loadedSections.contains(section)
    }

    func loadSectionIfNeeded(_ section: ArtistDetailSection) async {
        guard !loadedSections.contains(section), !pager(for: section).isLoadingFirst else { return }
        await reload(section: section)
    }

    var albums: [Playlist] {
        playlists.filter { $0.isAlbum && !ArtistReleaseKind.isSingleOrEP($0) }
    }

    var singlesAndEPs: [Playlist] {
        playlists.filter(ArtistReleaseKind.isSingleOrEP)
    }

    var otherPlaylists: [Playlist] {
        playlists.filter { !$0.isAlbum && !ArtistReleaseKind.isSingleOrEP($0) }
    }

    var latestRelease: ArtistLatestRelease? {
        let releases = playlists.filter { $0.isAlbum || ArtistReleaseKind.isSingleOrEP($0) }
        if let release = releases.max(by: { $0.createdAt < $1.createdAt }) { return .collection(release) }
        if let track = tracks.max(by: { $0.createdAt < $1.createdAt }) { return .single(track) }
        return nil
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
        #if DEBUG
        if VisualFixtures.isEnabled {
            switch section {
            case .tracks:
                var fixture = VisualFixtures.tracks.filter { $0.user.id == user.id }
                if fixture.isEmpty { fixture = Array(VisualFixtures.tracks.prefix(8)) }
                tracksPager.prime(items: fixture, cursor: nil)
            case .playlists:
                playlistsPager.prime(
                    items: VisualFixtures.albums.filter { $0.user.id == user.id } + Array(VisualFixtures.playlists.prefix(3)),
                    cursor: nil
                )
            case .reposts:
                let now = Date()
                let tracks = Array(VisualFixtures.tracks.dropFirst(4).prefix(8)).enumerated().map {
                    StreamItem(createdAt: now.addingTimeInterval(Double(-$0.offset * 600)), track: $0.element, playlist: nil)
                }
                let playlists = Array(VisualFixtures.playlists.prefix(4)).enumerated().map {
                    StreamItem(createdAt: now.addingTimeInterval(Double(-$0.offset * 600 - 300)), track: nil, playlist: $0.element)
                }
                repostsPager.prime(items: (playlists + tracks).map { ArtistRepostEntry(item: $0) }, cursor: nil)
            case .likes:
                likesPager.prime(
                    items: Array(VisualFixtures.tracks.dropFirst(2).prefix(10)).map { ArtistLikeEntry(track: $0) },
                    cursor: nil
                )
            }
            loadedSections.insert(section)
            return
        }
        #endif

        let pager = pager(for: section)
        await pager.reload()
        if pager.hasLoadedFirst, pager.firstError == nil, !Task.isCancelled {
            loadedSections.insert(section)
            persistCache()
        }
    }

    func loadMore(section: ArtistDetailSection) async {
        await pager(for: section).loadMore()
        persistCache()
    }

    func requestMore(section: ArtistDetailSection) {
        pager(for: section).requestMore()
    }

    func setPlaylistSharing(_ playlist: Playlist, to sharing: String) async throws {
        let updated = try await api.setPlaylistSharing(sharing, playlistId: playlist.id)
        var items = playlistsPager.items
        if let index = items.firstIndex(where: { $0.id == updated.id }) {
            items[index] = updated
            playlistsPager.prime(items: items, cursor: playlistsPager.cursor, total: playlistsPager.total)
        }
        persistCache()
    }

    private func persistCache() {
        Self.profileCache[user.id] = CacheEntry(
            savedAt: Date(),
            tracks: tracks,
            playlists: playlists,
            reposts: repostsPager.items,
            likes: likesPager.items,
            loadedSections: loadedSections,
            tracksCursor: tracksPager.cursor,
            playlistsCursor: playlistsPager.cursor,
            repostsCursor: repostsPager.cursor,
            likesCursor: likesPager.cursor
        )
    }
}

enum ArtistReleaseKind {
    static func isSingleOrEP(_ playlist: Playlist) -> Bool {
        switch playlist.setType?.lowercased() {
        case "ep", "single": return true
        default: return false
        }
    }
}

enum ArtistLatestRelease {
    case collection(Playlist)
    case single(Track)

    var id: String {
        switch self {
        case .collection(let playlist): return playlist.id
        case .single(let track): return track.id
        }
    }

    var date: Date {
        switch self {
        case .collection(let playlist): return playlist.createdAt
        case .single(let track): return track.createdAt
        }
    }

    var title: String {
        switch self {
        case .collection(let playlist): return playlist.title
        case .single(let track): return track.title
        }
    }

    var artworkURL: URL? {
        switch self {
        case .collection(let playlist): return playlist.largeDisplayArtworkURL
        case .single(let track): return track.largeArtworkURL ?? track.artworkURL
        }
    }

    var detail: String {
        switch self {
        case .collection(let playlist):
            let count = playlist.totalTrackCount
            let kind = ArtistReleaseKind.isSingleOrEP(playlist)
                ? (playlist.setType?.lowercased() == "ep" ? "EP" : "Single")
                : CollectionPageKind(playlist: playlist).label
            return count > 0 ? "\(kind) · \(count) \(count == 1 ? "track" : "tracks")" : kind
        case .single(let track):
            guard let genre = track.genre, !genre.isEmpty else { return "Single" }
            return "Single · \(genre)"
        }
    }
}

@MainActor
final class ArtistSimilarModel: ObservableObject {
    private struct CacheValue {
        let savedAt: Date
        let artists: [User]
    }

    private static let cacheLifetime: TimeInterval = 15 * 60
    private static var cache: [String: CacheValue] = [:]
    private static let limit = 12

    let user: User
    @Published private(set) var artists: [User] = []
    @Published private(set) var hasFinished = false
    private var isLoading = false

    init(user: User) {
        self.user = user
        if let cached = Self.cache[user.id], Date().timeIntervalSince(cached.savedAt) < Self.cacheLifetime {
            artists = cached.artists
            hasFinished = true
        }
    }

    func loadIfNeeded() async {
        guard !hasFinished, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        #if DEBUG
        if VisualFixtures.isEnabled {
            finish(VisualFixtures.artists.filter { $0.id != user.id })
            return
        }
        #endif
        let api = SoundCloudAPI.shared
        do {
            let related = try await api.getUserRelatedArtists(userId: user.id, limit: Self.limit).collection
            if !related.isEmpty {
                finish(related)
                return
            }
        } catch {
            if Self.isCancellation(error) { return }
            if Self.isTrafficStop(error) {
                finish([])
                return
            }
        }
        do {
            let followings = try await api.getUserFollowings(userId: user.id, limit: 50).collection
            finish(followings.filter { $0.trackCount > 0 }.sorted { $0.followersCount > $1.followersCount })
        } catch {
            if Self.isCancellation(error) { return }
            finish([])
        }
    }

    private func finish(_ found: [User]) {
        var seen = Set<String>()
        let unique = found.filter { $0.id != user.id && seen.insert($0.id).inserted }
        artists = Array(unique.prefix(Self.limit))
        hasFinished = true
        Self.cache[user.id] = CacheValue(savedAt: Date(), artists: artists)
    }

    private static func isTrafficStop(_ error: Error) -> Bool {
        switch error as? APIError {
        case .rateLimited?, .temporarilyBlocked?: return true
        default: return false
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

enum ArtistConnectionKind: String, Identifiable, CaseIterable, Sendable {
    case following = "Following"
    case followers = "Followers"

    var id: Self { self }
    var systemImage: String {
        switch self {
        case .following: "person.crop.circle.badge.checkmark"
        case .followers: "person.2"
        }
    }
}

@MainActor
@Observable
final class ArtistConnectionsModel {
    private struct CacheKey: Hashable {
        let userID: String
        let kind: ArtistConnectionKind
    }

    private struct CacheValue {
        let savedAt: Date
        let users: [User]
        let cursor: PagedCursor?
    }

    private static let cacheLifetime: TimeInterval = 15 * 60
    private static var cache: [CacheKey: CacheValue] = [:]

    private(set) var users: [User] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    let userID: String
    let kind: ArtistConnectionKind
    @ObservationIgnored let pager: Paginator<User>
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(userID: String, kind: ArtistConnectionKind) {
        self.userID = userID
        self.kind = kind
        if SoundCloudAPI.credentials?.currentUser?.id == userID {
            pager = Paginator(source: LibraryDB.userSource(kind == .following ? .followings : .followers), maxUnattendedPages: 1_000)
        } else {
            pager = Paginator(soundCloudSource: PagedSource(
            first: {
                let page: Page<User>
                switch kind {
                case .following: page = try await SoundCloudAPI.shared.getUserFollowings(userId: userID, limit: 100)
                case .followers: page = try await SoundCloudAPI.shared.getUserFollowers(userId: userID, limit: 100)
                }
                return PagedChunk(items: page.collection, next: page.nextHref.map { .url($0) })
            },
            next: { cursor in
                guard case .url(let url) = cursor else { return PagedChunk(items: []) }
                let page = try await SoundCloudAPI.shared.getPage(User.self, from: url)
                return PagedChunk(items: page.collection, next: page.nextHref.map { .url($0) })
            }
            ))
        }
        let key = CacheKey(userID: userID, kind: kind)
        if SoundCloudAPI.credentials?.currentUser?.id != userID, let cached = Self.cache[key], Date().timeIntervalSince(cached.savedAt) < Self.cacheLifetime {
            pager.prime(items: cached.users, cursor: cached.cursor)
            users = cached.users
            hasLoaded = true
        }

        pager.$items
            .sink { [weak self] in self?.users = $0 }
            .store(in: &cancellables)
        pager.$cursor
            .dropFirst()
            .sink { [weak self] cursor in
                guard let self, !self.pager.items.isEmpty else { return }
                Self.cache[key] = CacheValue(savedAt: Date(), users: self.pager.items, cursor: cursor)
            }
            .store(in: &cancellables)
        pager.$isLoadingFirst
            .combineLatest(pager.$isLoadingMore)
            .sink { [weak self] first, more in self?.isLoading = first || more }
            .store(in: &cancellables)
        pager.$firstError
            .combineLatest(pager.$loadMoreError)
            .sink { [weak self] first, more in
                if first != nil {
                    self?.errorMessage = "Couldn’t reach SoundCloud. Check your connection and try again."
                } else if more != nil {
                    self?.errorMessage = "Couldn’t load more people. Try again."
                } else {
                    self?.errorMessage = nil
                }
            }
            .store(in: &cancellables)
    }

    func loadIfNeeded(force: Bool = false) async {
        guard force || !hasLoaded else { return }
        guard !pager.isLoadingFirst else { return }
        #if DEBUG
        if VisualFixtures.isEnabled {
            pager.prime(items: VisualFixtures.artists.filter { $0.id != userID }, cursor: nil)
            hasLoaded = true
            return
        }
        #endif
        await pager.reload()
        if pager.firstError == nil, pager.hasLoadedFirst {
            hasLoaded = true
        }
    }

    func loadMore() {
        pager.requestMore()
    }

    func filtered(_ query: String) -> [User] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return users }
        return users.filter {
            $0.displayName.localizedStandardContains(needle) || $0.username.localizedStandardContains(needle)
        }
    }

    func loadMoreWhileSearching(_ query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(500))
        var pages = 0
        while !Task.isCancelled, pages < 10, filtered(query).isEmpty, pager.hasMore, !pager.didFailLoadingMore, !pager.isPaused {
            if pager.isLoadingMore {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            pages += 1
            let before = pager.items.count
            await pager.loadMore()
            if pager.items.count == before { return }
        }
    }
}
