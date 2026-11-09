import Foundation
import Combine

enum SearchScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case library
    case soundCloud

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "All"
        case .library: return "Library"
        case .soundCloud: return "SoundCloud"
        }
    }

    var includesLibrary: Bool { self != .soundCloud }
    var includesSoundCloud: Bool { self != .library }

    static let browsable: [SearchScope] = [.soundCloud, .library]
}

enum SearchLibraryReason: String, CaseIterable, Hashable, Sendable {
    case liked
    case reposted
    case playlist
    case followed
    case downloaded
    case local

    var title: String {
        switch self {
        case .liked: return "Liked"
        case .reposted: return "Reposted"
        case .playlist: return "Your Playlist"
        case .followed: return "Following"
        case .downloaded: return "Downloaded"
        case .local: return LocalMusicLibrary.displayName
        }
    }
}

enum SearchHit: Identifiable, Hashable, Sendable {
    case track(Track)
    case playlist(Playlist)
    case artist(User)

    var id: String {
        switch self {
        case .track(let track): return "track:\(track.id)"
        case .playlist(let playlist): return "playlist:\(playlist.id)"
        case .artist(let user): return "artist:\(user.id)"
        }
    }

    var title: String {
        switch self {
        case .track(let track): return track.title
        case .playlist(let playlist): return playlist.title
        case .artist(let user): return user.displayName
        }
    }

    var artworkURL: URL? {
        switch self {
        case .track(let track): return track.artworkURL
        case .playlist(let playlist): return playlist.displayArtworkURL
        case .artist(let user): return user.largeAvatarURL ?? user.avatarURL
        }
    }

    var track: Track? {
        if case .track(let track) = self { return track }
        return nil
    }
}

struct SearchLibraryHit: Identifiable, Hashable, Sendable {
    let hit: SearchHit
    let reason: SearchLibraryReason
    var id: String { hit.id }
}

struct SearchLibrarySnapshot: Sendable {
    var likes: [Track] = []
    var reposts: [Track] = []
    var downloads: [Track] = []
    var local: [Track] = []
    var playlists: [Playlist] = []
    var followings: [User] = []

    var isEmpty: Bool {
        likes.isEmpty && reposts.isEmpty && downloads.isEmpty && local.isEmpty && playlists.isEmpty && followings.isEmpty
    }
}

struct SearchRemoteResults: Equatable, Sendable {
    var tracks: [Track]?
    var artists: [User]?
    var playlists: [Playlist]?

    var hasArrived: Bool { tracks != nil || artists != nil || playlists != nil }
    var isComplete: Bool { tracks != nil && artists != nil && playlists != nil }
}

struct SearchResults: Equatable, Sendable {
    var topResult: SearchHit?
    var topReason: SearchLibraryReason?
    var library: [SearchLibraryHit] = []
    var tracks: [Track] = []
    var sets: [Track] = []
    var artists: [User] = []
    var playlists: [Playlist] = []

    static let empty = SearchResults()

    var isEmpty: Bool {
        topResult == nil && library.isEmpty && tracks.isEmpty && sets.isEmpty && artists.isEmpty && playlists.isEmpty
    }

    var playableTracks: [Track] {
        var seen = Set<String>()
        var out: [Track] = []
        var candidates: [Track] = []
        if let track = topResult?.track { candidates.append(track) }
        candidates.append(contentsOf: library.compactMap(\.hit.track))
        candidates.append(contentsOf: tracks)
        candidates.append(contentsOf: sets)
        for track in candidates where seen.insert(track.id).inserted {
            out.append(track)
        }
        return out
    }
}

enum SearchRanking {
    static let libraryLimit = 8
    static let tracksLimit = 20
    static let setsLimit = 12
    static let artistsLimit = 10
    static let playlistsLimit = 10
    static let topResultFloor = 400
    static let libraryBoost = 150

    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func score(query: String, primary: String, secondary: String = "") -> Int {
        let needle = normalized(query)
        guard !needle.isEmpty else { return 0 }
        let first = normalized(primary)
        let second = normalized(secondary)
        if first == needle { return 1000 }
        if !second.isEmpty, second == needle { return 700 }
        if first.hasPrefix(needle) { return 600 }
        if first.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 450 }
        if !second.isEmpty, second.hasPrefix(needle) { return 420 }
        if first.contains(needle) { return 300 }
        if !second.isEmpty, second.contains(needle) { return 220 }
        let tokens = needle.split(separator: " ")
        guard tokens.count > 1 else { return 0 }
        let haystack = first + " " + second
        let found = tokens.filter { haystack.contains($0) }.count
        return found == tokens.count ? 150 + found : 0
    }

    static func score(_ track: Track, query: String) -> Int {
        let base = score(query: query, primary: track.title, secondary: track.user.displayName)
        if base > 0 { return base }
        let username = score(query: query, primary: track.user.username)
        return username > 0 ? min(username, 220) : 0
    }

    static func score(_ user: User, query: String) -> Int {
        max(score(query: query, primary: user.displayName), score(query: query, primary: user.username) - 10)
    }

    static func score(_ playlist: Playlist, query: String) -> Int {
        score(query: query, primary: playlist.title, secondary: playlist.user.displayName)
    }

    static func score(_ hit: SearchHit, query: String) -> Int {
        switch hit {
        case .track(let track): return score(track, query: query)
        case .playlist(let playlist): return score(playlist, query: query)
        case .artist(let user): return score(user, query: query) + (score(user, query: query) >= 1000 ? 50 : 0)
        }
    }

    static func ranked<Item>(_ items: [Item], by score: (Item) -> Int) -> [Item] {
        var scored: [(offset: Int, item: Item, score: Int)] = []
        for (offset, item) in items.enumerated() {
            let value = score(item)
            if value > 0 { scored.append((offset, item, value)) }
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.offset < rhs.offset : lhs.score > rhs.score
        }
        return scored.map(\.item)
    }

    static func libraryHits(query: String, in snapshot: SearchLibrarySnapshot, limit: Int = libraryLimit) -> [SearchLibraryHit] {
        var candidates: [(hit: SearchLibraryHit, score: Int, order: Int)] = []
        var seen = Set<String>()
        var order = 0
        func consider(_ hit: SearchHit, _ reason: SearchLibraryReason) {
            order += 1
            let value = score(hit, query: query)
            guard value > 0, seen.insert(hit.id).inserted else { return }
            candidates.append((SearchLibraryHit(hit: hit, reason: reason), value + reasonWeight(reason), order))
        }
        for user in snapshot.followings { consider(.artist(user), .followed) }
        for playlist in snapshot.playlists { consider(.playlist(playlist), .playlist) }
        for track in snapshot.likes { consider(.track(track), track.userReposted ? .reposted : .liked) }
        for track in snapshot.reposts { consider(.track(track), .reposted) }
        for track in snapshot.downloads { consider(.track(track), .downloaded) }
        for track in snapshot.local { consider(.track(track), .local) }
        return candidates
            .sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
            .prefix(limit)
            .map(\.hit)
    }

    static func localTracks(_ tracks: [Track], matching query: String, limit: Int = 40) -> [Track] {
        Array(ranked(tracks) { score($0, query: query) }.prefix(limit))
    }

    private static func reasonWeight(_ reason: SearchLibraryReason) -> Int {
        switch reason {
        case .followed: return 30
        case .liked, .reposted: return 20
        case .playlist: return 15
        case .downloaded, .local: return 10
        }
    }

    static func merge(
        query: String,
        scope: SearchScope,
        library: [SearchLibraryHit],
        remote: SearchRemoteResults,
        setMinimumDuration: TimeInterval
    ) -> SearchResults {
        var results = SearchResults()
        let libraryHits = scope.includesLibrary ? library : []

        var remoteTracks: [Track] = []
        var remoteSets: [Track] = []
        var remoteArtists: [User] = []
        var remotePlaylists: [Playlist] = []
        if scope.includesSoundCloud {
            let ranked = Self.ranked(dedupe(remote.tracks ?? [])) { score($0, query: query) }
            remoteTracks = ranked.filter { $0.duration < setMinimumDuration }
            remoteSets = ranked.filter { $0.duration >= setMinimumDuration }
            remoteArtists = Self.ranked(dedupe(remote.artists ?? [])) { score($0, query: query) }
            remotePlaylists = Self.ranked(dedupe(remote.playlists ?? [])) { score($0, query: query) }
        }

        var best: (hit: SearchHit, reason: SearchLibraryReason?, score: Int)?
        func propose(_ hit: SearchHit, reason: SearchLibraryReason?, bonus: Int) {
            let value = score(hit, query: query)
            guard value >= topResultFloor else { return }
            let total = value + bonus
            if best == nil || total > best!.score { best = (hit, reason, total) }
        }
        for hit in libraryHits.prefix(3) { propose(hit.hit, reason: hit.reason, bonus: libraryBoost) }
        if let artist = remoteArtists.first { propose(.artist(artist), reason: nil, bonus: popularity(artist.followersCount)) }
        if let track = remoteTracks.first { propose(.track(track), reason: nil, bonus: popularity(track.playbackCount ?? 0)) }
        if let set = remoteSets.first { propose(.track(set), reason: nil, bonus: popularity(set.playbackCount ?? 0)) }
        if let playlist = remotePlaylists.first { propose(.playlist(playlist), reason: nil, bonus: 0) }

        let topID = best?.hit.id
        results.topResult = best?.hit
        results.topReason = best?.reason

        let listed = scope == .library ? libraryHits : Array(libraryHits.prefix(libraryLimit))
        results.library = listed.filter { $0.id != topID }
        let shown = Set(listed.map(\.id))
        func keep(_ hit: SearchHit) -> Bool { hit.id != topID && !shown.contains(hit.id) }
        results.tracks = Array(remoteTracks.filter { keep(.track($0)) }.prefix(tracksLimit))
        results.sets = Array(remoteSets.filter { keep(.track($0)) }.prefix(setsLimit))
        results.artists = Array(remoteArtists.filter { keep(.artist($0)) }.prefix(artistsLimit))
        results.playlists = Array(remotePlaylists.filter { keep(.playlist($0)) }.prefix(playlistsLimit))
        return results
    }

    private static func popularity(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(60, Int(log10(Double(count)) * 10))
    }

    private static func dedupe<Item: Identifiable>(_ items: [Item]) -> [Item] where Item.ID == String {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    static func suggestions(
        query: String,
        recents: [String],
        library: SearchLibrarySnapshot,
        results: SearchResults,
        limit: Int = 4
    ) -> [String] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return [] }
        var candidates: [String] = recents
        candidates.append(contentsOf: library.followings.map(\.displayName))
        candidates.append(contentsOf: results.artists.map(\.displayName))
        candidates.append(contentsOf: library.playlists.map(\.title))
        candidates.append(contentsOf: library.likes.map(\.user.displayName))
        candidates.append(contentsOf: library.likes.map(\.title))
        candidates.append(contentsOf: results.tracks.map(\.title))
        var seen = Set<String>([needle])
        var prefixed: [String] = []
        var contained: [String] = []
        for candidate in candidates {
            let key = normalized(candidate)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if key.hasPrefix(needle) || key.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
                prefixed.append(candidate)
            } else if key.contains(needle) {
                contained.append(candidate)
            }
        }
        return Array((prefixed + contained).prefix(limit))
    }
}

protocol SearchLibrarySource: Sendable {
    func snapshot(matching query: String) async -> SearchLibrarySnapshot
}

protocol SearchRemoteSource: Sendable {
    func tracks(_ query: String) async throws -> [Track]
    func artists(_ query: String) async throws -> [User]
    func playlists(_ query: String) async throws -> [Playlist]
}

struct LiveSearchLibrarySource: SearchLibrarySource {
    func snapshot(matching query: String) async -> SearchLibrarySnapshot {
        #if DEBUG
        if VisualFixtures.isEnabled { return FixtureSearchSources.library }
        #endif
        let catalog = DeviceLocalCatalog()
        let likes = await catalog.searchLikedTracks(query, limit: 40)
        let playlists = await catalog.cachedPlaylists()
        let followings = await catalog.followedArtists()
        let downloads = await MainActor.run {
            DownloadManager.shared.entries.values.filter(\.isDownloaded).map(\.track)
        }
        var local: [Track] = []
        if LocalMusicLibrary.isSupported {
            let files = await MainActor.run { LocalMusicLibrary.shared.allTracks }
            local = SearchRanking.localTracks(files, matching: query)
        }
        let identity = LibraryIdentity.current
        let localIDs = Set(local.map(\.id))
        var linkedLocal: [Track] = []
        let mergedLikes = likes.filter { liked in
            guard let copy = identity.localCopy(of: liked) else { return true }
            if !localIDs.contains(copy.id) { linkedLocal.append(copy) }
            return false
        }
        return SearchLibrarySnapshot(
            likes: mergedLikes,
            downloads: downloads,
            local: local + linkedLocal,
            playlists: playlists,
            followings: followings
        )
    }
}

struct LiveSearchRemoteSource: SearchRemoteSource {
    func tracks(_ query: String) async throws -> [Track] {
        #if DEBUG
        if VisualFixtures.isEnabled { return FixtureSearchSources.remote.tracks ?? [] }
        #endif
        return try await SoundCloudAPI.shared.searchTracks(query: query, limit: 30).collection
    }

    func artists(_ query: String) async throws -> [User] {
        #if DEBUG
        if VisualFixtures.isEnabled { return FixtureSearchSources.remote.artists ?? [] }
        #endif
        return try await SoundCloudAPI.shared.searchUsers(query: query, limit: 10).collection
    }

    func playlists(_ query: String) async throws -> [Playlist] {
        #if DEBUG
        if VisualFixtures.isEnabled { return FixtureSearchSources.remote.playlists ?? [] }
        #endif
        return try await SoundCloudAPI.shared.searchPlaylists(query: query, limit: 10).collection
    }
}

#if DEBUG
enum FixtureSearchSources {
    static var library: SearchLibrarySnapshot {
        SearchLibrarySnapshot(
            likes: Array(VisualFixtures.tracks.prefix(6)),
            downloads: Array(VisualFixtures.tracks[6..<8]),
            playlists: VisualFixtures.playlists,
            followings: Array(VisualFixtures.artists.prefix(4))
        )
    }

    static var remote: SearchRemoteResults {
        SearchRemoteResults(
            tracks: VisualFixtures.tracks + [VisualFixtures.nowPlayingMix],
            artists: VisualFixtures.artists,
            playlists: VisualFixtures.albums + VisualFixtures.playlists
        )
    }
}
#endif

@MainActor
final class UnifiedSearchModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case searching
        case loaded
        case failed
    }

    @Published var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    @Published var scope: SearchScope = .all {
        didSet { if scope != oldValue { scopeChanged() } }
    }
    @Published var filter: SearchResultFilter = .top {
        didSet { if filter != oldValue { restorePaging() } }
    }
    @Published private(set) var results = SearchResults.empty
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isRemoteLoading = false
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var recents: [RecentSearchEntry] {
        didSet { decodeRecentHits() }
    }
    @Published private(set) var paged: [SearchResultItem] = []
    @Published private(set) var isPaging = false
    private(set) var recentHits: [String: SearchHit] = [:]

    static let debounce: Duration = .milliseconds(250)
    static let minimumRemoteLength = 2
    static let libraryScopeLimit = 150
    private static let maxRecents = 12
    private static let memoryLimit = 24
    private static let pageSize = 50
    private static let pageLimit = 10

    private let library: any SearchLibrarySource
    private let remote: any SearchRemoteSource
    private let debounce: Duration
    private let setMinimumDuration: () -> TimeInterval
    private let persistRecents: Bool

    private var task: Task<Void, Never>?
    private var generation = 0
    private var libraryHits: [SearchLibraryHit] = []
    private var librarySnapshot = SearchLibrarySnapshot()
    private var remoteResults = SearchRemoteResults()
    private var remoteMemory: [String: SearchRemoteResults] = [:]
    private var remoteMemoryOrder: [String] = []
    private var pagingKey: String?
    private var pagingState = PagingState()
    private var pagingMemory: [String: PagingState] = [:]
    private var pagingMemoryOrder: [String] = []
    private var pagingTask: Task<Void, Never>?

    private struct PagingState {
        var items: [SearchResultItem] = []
        var next: URL?
        var pages = 0
        var isExhausted = false
    }

    init(
        library: any SearchLibrarySource = LiveSearchLibrarySource(),
        remote: any SearchRemoteSource = LiveSearchRemoteSource(),
        debounce: Duration = UnifiedSearchModel.debounce,
        recents: [RecentSearchEntry]? = nil,
        scope: SearchScope = .all,
        setMinimumDuration: (() -> TimeInterval)? = nil
    ) {
        self.library = library
        self.remote = remote
        self.debounce = debounce
        self.persistRecents = recents == nil
        self.recents = recents ?? SettingsStore.shared.recentSearchQueries
        self.scope = scope
        self.setMinimumDuration = setMinimumDuration ?? { SettingsStore.shared.setMinimumDurationSeconds }
        decodeRecentHits()
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearching: Bool { !trimmedQuery.isEmpty }

    var visibleItems: [SearchResultItem] {
        let text = trimmedQuery
        let base = SearchRanking.items(results, filter: filter, query: text, setMinimumDuration: setMinimumDuration())
        guard filter != .top, !paged.isEmpty else { return base }
        var seen = Set(base.map(\.id))
        return base + paged.filter { seen.insert($0.id).inserted }
    }

    var availableFilters: [SearchResultFilter] {
        guard scope == .library else { return SearchResultFilter.allCases }
        let found = results.availableFilters(setMinimumDuration: setMinimumDuration())
        return SearchResultFilter.allCases.filter { found.contains($0) || $0 == filter }
    }

    var canPage: Bool {
        scope.includesSoundCloud && filter != .top && !pagingState.isExhausted && phase == .loaded && !isRemoteLoading
    }

    func retry() {
        let key = SearchRanking.normalized(trimmedQuery)
        remoteMemory[key] = nil
        schedule(immediate: true)
    }

    func search(_ text: String) {
        query = text
        schedule(immediate: true)
    }

    func waitForIdle() async {
        await task?.value
    }

    private func schedule(immediate: Bool = false) {
        task?.cancel()
        generation &+= 1
        let issued = generation
        let text = trimmedQuery
        restorePaging()
        guard !text.isEmpty else {
            if filter != .top { filter = .top }
            libraryHits = []
            librarySnapshot = SearchLibrarySnapshot()
            remoteResults = SearchRemoteResults()
            results = .empty
            suggestions = []
            phase = .idle
            isRemoteLoading = false
            return
        }

        let key = SearchRanking.normalized(text)
        let remembered = remoteMemory[key]
        remoteResults = remembered ?? SearchRemoteResults()
        let needsRemote = scope.includesSoundCloud && remembered == nil && text.count >= Self.minimumRemoteLength
        isRemoteLoading = needsRemote
        if phase == .idle || phase == .failed { phase = .searching }

        let library = library
        let remote = remote
        let delay = immediate ? nil : debounce
        task = Task { [weak self] in
            let snapshot = await library.snapshot(matching: text)
            guard let self, !Task.isCancelled, issued == self.generation else { return }
            self.librarySnapshot = snapshot
            self.libraryHits = SearchRanking.libraryHits(query: text, in: snapshot, limit: Self.libraryScopeLimit)
            self.republish()
            if !needsRemote {
                self.phase = .loaded
                return
            }
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, issued == self.generation else { return }
            }
            await self.fetchRemote(text, key: key, generation: issued, remote: remote)
        }
    }

    private enum Arrival: Sendable {
        case tracks([Track]?)
        case artists([User]?)
        case playlists([Playlist]?)
    }

    private func fetchRemote(_ text: String, key: String, generation issued: Int, remote: any SearchRemoteSource) async {
        var failures = 0
        await withTaskGroup(of: Arrival.self) { group in
            group.addTask { .tracks(try? await remote.tracks(text)) }
            group.addTask { .artists(try? await remote.artists(text)) }
            group.addTask { .playlists(try? await remote.playlists(text)) }
            for await arrival in group {
                guard !Task.isCancelled, issued == self.generation else { continue }
                switch arrival {
                case .tracks(let value):
                    if value == nil { failures += 1 }
                    self.remoteResults.tracks = value ?? []
                case .artists(let value):
                    if value == nil { failures += 1 }
                    self.remoteResults.artists = value ?? []
                case .playlists(let value):
                    if value == nil { failures += 1 }
                    self.remoteResults.playlists = value ?? []
                }
                self.republish()
            }
        }
        guard !Task.isCancelled, issued == generation else { return }
        isRemoteLoading = false
        if failures == 3 {
            remoteResults = SearchRemoteResults()
            republish()
            phase = results.isEmpty ? .failed : .loaded
            return
        }
        if failures == 0 { remember(remoteResults, for: key) }
        phase = .loaded
    }

    private func remember(_ value: SearchRemoteResults, for key: String) {
        remoteMemory[key] = value
        remoteMemoryOrder.removeAll { $0 == key }
        remoteMemoryOrder.append(key)
        while remoteMemoryOrder.count > Self.memoryLimit {
            remoteMemory[remoteMemoryOrder.removeFirst()] = nil
        }
    }

    private func republish() {
        let text = trimmedQuery
        guard !text.isEmpty else { return }
        let merged = SearchRanking.merge(
            query: text,
            scope: scope,
            library: libraryHits,
            remote: remoteResults,
            setMinimumDuration: setMinimumDuration()
        )
        if merged != results { results = merged }
        let next = SearchRanking.suggestions(
            query: text,
            recents: recents.map(\.query),
            library: scope.includesLibrary ? librarySnapshot : SearchLibrarySnapshot(),
            results: merged
        )
        if next != suggestions { suggestions = next }
        if phase == .searching, !merged.isEmpty { phase = .loaded }
    }

    func rememberCurrentQuery() {
        let text = trimmedQuery
        guard !text.isEmpty else { return }
        let entry: RecentSearchEntry
        if case .artist(let user) = results.topResult,
           SearchRanking.normalized(user.displayName) == SearchRanking.normalized(text) {
            entry = RecentSearchEntry(query: text, avatarURL: user.avatarURL, subtitle: user.kindLabel)
        } else {
            entry = RecentSearchEntry(query: text, avatarURL: nil, subtitle: "Search")
        }
        var next = recents.filter { $0.query.caseInsensitiveCompare(text) != .orderedSame }
        next.insert(entry, at: 0)
        setRecents(Array(next.prefix(Self.maxRecents)))
    }

    func remember(_ hit: SearchHit) {
        let entry = RecentSearchEntry(hit: hit)
        var next = recents.filter { $0.id != entry.id }
        next.insert(entry, at: 0)
        setRecents(Array(next.prefix(Self.maxRecents)))
    }

    func clearRecents() {
        setRecents([])
    }

    func removeRecents(at offsets: IndexSet) {
        var next = recents
        next.remove(atOffsets: offsets)
        setRecents(next)
    }

    func removeRecent(_ entry: RecentSearchEntry) {
        setRecents(recents.filter { $0.id != entry.id })
    }

    private func setRecents(_ next: [RecentSearchEntry]) {
        recents = next
        if persistRecents { SettingsStore.shared.setRecentSearchQueries(next) }
    }

    func reloadRecents() {
        guard persistRecents else { return }
        let stored = SettingsStore.shared.recentSearchQueries
        if stored != recents { recents = stored }
    }

    private func decodeRecentHits() {
        var decoded: [String: SearchHit] = [:]
        for entry in recents {
            if let hit = recentHits[entry.id] ?? entry.hit { decoded[entry.id] = hit }
        }
        recentHits = decoded
    }

    // MARK: - Scope and paging

    private func scopeChanged() {
        restorePaging()
        let text = trimmedQuery
        let remoteMissing = !remoteResults.isComplete && remoteMemory[SearchRanking.normalized(text)] == nil
        if scope.includesSoundCloud, !text.isEmpty, remoteMissing, !isRemoteLoading {
            schedule(immediate: true)
            return
        }
        republish()
    }

    private func restorePaging() {
        pagingTask?.cancel()
        pagingTask = nil
        isPaging = false
        if let pagingKey {
            pagingMemory[pagingKey] = pagingState
            pagingMemoryOrder.removeAll { $0 == pagingKey }
            pagingMemoryOrder.append(pagingKey)
            while pagingMemoryOrder.count > Self.memoryLimit {
                pagingMemory[pagingMemoryOrder.removeFirst()] = nil
            }
        }
        let text = trimmedQuery
        guard filter != .top, scope.includesSoundCloud, !text.isEmpty else {
            pagingKey = nil
            pagingState = PagingState()
            if !paged.isEmpty { paged = [] }
            return
        }
        let key = "\(filter.rawValue)|\(SearchRanking.normalized(text))"
        pagingKey = key
        pagingState = pagingMemory[key] ?? PagingState()
        if paged != pagingState.items { paged = pagingState.items }
    }

    func loadMoreIfNeeded(after item: SearchResultItem) {
        guard canPage, pagingTask == nil else { return }
        let items = visibleItems
        guard let index = items.firstIndex(where: { $0.id == item.id }), index >= items.count - 6 else { return }
        loadMore()
    }

    func loadMore() {
        guard canPage, pagingTask == nil, pagingState.pages < Self.pageLimit else { return }
        #if DEBUG
        if VisualFixtures.isEnabled {
            pagingState.isExhausted = true
            return
        }
        #endif
        let text = trimmedQuery
        let filter = filter
        let key = pagingKey
        let start = pagingState.next
        let alreadyPaged = pagingState.pages
        let minimum = setMinimumDuration()
        isPaging = true
        pagingTask = Task { [weak self] in
            var next = start
            var pages = alreadyPaged
            var found: [SearchResultItem] = []
            var exhausted = false
            var failed = false
            repeat {
                do {
                    let page = try await Self.fetchPage(filter: filter, query: text, next: next)
                    pages += 1
                    next = page.next
                    found += page.hits
                        .filter { SearchResultFilter.of($0, setMinimumDuration: minimum) == filter }
                        .map { SearchResultItem(hit: $0) }
                    if next == nil { exhausted = true }
                } catch {
                    failed = true
                }
            } while !Task.isCancelled && !failed && !exhausted && found.count < 12 && pages - alreadyPaged < 3 && pages < Self.pageLimit
            guard let self, !Task.isCancelled, key == self.pagingKey else { return }
            var seen = Set(self.pagingState.items.map(\.id))
            self.pagingState.items += found.filter { seen.insert($0.id).inserted }
            self.pagingState.next = next
            self.pagingState.pages = pages
            self.pagingState.isExhausted = exhausted || failed || pages >= Self.pageLimit
            self.paged = self.pagingState.items
            self.isPaging = false
            self.pagingTask = nil
        }
    }

    private struct FetchedPage: Sendable {
        let hits: [SearchHit]
        let next: URL?
    }

    private static func fetchPage(filter: SearchResultFilter, query: String, next: URL?) async throws -> FetchedPage {
        let api = SoundCloudAPI.shared
        switch filter {
        case .top:
            return FetchedPage(hits: [], next: nil)
        case .tracks, .sets:
            let page: Page<Track>
            if let next {
                page = try await api.getPage(Track.self, from: next)
            } else {
                page = try await api.searchTracks(query: query, limit: pageSize)
            }
            return FetchedPage(hits: page.collection.map { SearchHit.track($0) }, next: page.nextHref)
        case .artists, .people:
            let page: Page<User>
            if let next {
                page = try await api.getPage(User.self, from: next)
            } else {
                page = try await api.searchUsers(query: query, limit: pageSize)
            }
            return FetchedPage(hits: page.collection.map { SearchHit.artist($0) }, next: page.nextHref)
        case .playlists, .albums:
            let page: Page<Playlist>
            if let next {
                page = try await api.getPage(Playlist.self, from: next)
            } else {
                page = try await api.searchPlaylists(query: query, limit: pageSize)
            }
            return FetchedPage(hits: page.collection.map { SearchHit.playlist($0) }, next: page.nextHref)
        }
    }
}
