import Foundation

enum DiscoveryEntry: Identifiable, Equatable, Codable {
    case playlist(Playlist)
    case station(SystemPlaylist)
    case user(User)

    var id: String {
        switch self {
        case .playlist(let p): return p.id
        case .station(let s): return s.id
        case .user(let u): return "user:\(u.id)"
        }
    }

    var cardTitle: String {
        switch self {
        case .playlist(let p): return p.title
        case .station(let s):
            if let short = s.shortTitle, !short.isEmpty { return short }
            return s.title
        case .user(let u): return u.displayName
        }
    }

    var cardSubtitle: String? {
        switch self {
        case .playlist(let p): return p.user.displayName
        case .station(let s):
            if let short = s.shortDescription, !short.isEmpty { return short }
            return s.description
        case .user(let u): return "\(u.formattedFollowers) followers"
        }
    }

    var artworkURL: URL? {
        switch self {
        case .playlist(let p): return p.largeDisplayArtworkURL
        case .station(let s): return s.artworkURL
        case .user(let u): return u.largeAvatarURL ?? u.avatarURL
        }
    }

    var crownUser: User? {
        switch self {
        case .playlist(let playlist): return playlist.user
        case .user(let user): return user
        case .station: return nil
        }
    }
}

struct DiscoveryShelf: Identifiable, Equatable, Codable {

    enum Content: Equatable, Codable {
        case tracks([Track])
        case playlists([Playlist])

        case stations([SystemPlaylist])

        case users([User])

        case mixed([DiscoveryEntry])
    }

    enum Kind: Equatable, Codable {
        case editorial
        case chartCollections
        case trending
        case related
        case station
    }

    let id: String

    let title: String

    let subtitle: String?

    let kind: Kind
    let content: Content

    var count: Int {
        switch content {
        case .tracks(let t): return t.count
        case .playlists(let p): return p.count
        case .stations(let s): return s.count
        case .users(let u): return u.count
        case .mixed(let e): return e.count
        }
    }

    var isEmpty: Bool { count == 0 }
}

@MainActor
final class DiscoveryHomeSource: ObservableObject {

    struct Seed: Equatable, Sendable {
        var trackID: String?

        var trackTitle: String?

        var stationURN: String?

        init(trackID: String? = nil, trackTitle: String? = nil, stationURN: String? = nil) {
            self.trackID = trackID
            self.trackTitle = trackTitle
            self.stationURN = stationURN
        }

        init(track: Track) {
            self.trackID = track.id
            self.trackTitle = track.title
            self.stationURN = track.stationURN
        }

        var isEmpty: Bool { trackID == nil && stationURN == nil }
    }

    struct Titles {
        var trending = "Trending"
        var relatedFormat = "More Like %@"
        var relatedFallback = "More Like This"

        init() {}
    }

    @Published private(set) var shelves: [DiscoveryShelf] = []
    @Published private(set) var isLoading = false

    @Published private(set) var failures: [DiscoverySourceFailure] = []

    private(set) var lastLoaded: Date?

    var titles = Titles()

    var didFailCompletely: Bool { shelves.isEmpty && !failures.isEmpty }

    var didFailForCredentials: Bool {
        didFailCompletely && failures.allSatisfy(\.isCredentialRejection)
    }

    private let staleAfter: TimeInterval = 5 * 60

    private let maxItemsPerShelf = 20

    private let api = SoundCloudAPI.shared
    private let cache = LibraryCache.shared
    private var didHydrateCache = false
    private static let cacheSection = "discovery.home"

    /// Makes the last useful Home snapshot available before network refreshes
    /// begin. Callers can render it immediately while `load` updates quietly.
    func hydrateCachedContent() async {
        #if DEBUG
        if installVisualFixturesIfNeeded() { return }
        #endif
        await hydrateCacheIfNeeded()
    }

    func refreshIfStale(seed: Seed = Seed()) async {
        #if DEBUG
        if installVisualFixturesIfNeeded() { return }
        #endif
        await hydrateCacheIfNeeded()
        guard let lastLoaded else {
            await load(seed: seed)
            return
        }
        if Date().timeIntervalSince(lastLoaded) > staleAfter {
            await load(seed: seed)
        }
    }

    func load(seed: Seed = Seed()) async {
        #if DEBUG
        if installVisualFixturesIfNeeded() { return }
        #endif
        await hydrateCacheIfNeeded()
        if isLoading {
            while isLoading, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return
        }
        isLoading = true
        defer { isLoading = false }

        var recorded: [DiscoverySourceFailure] = []
        var built: [DiscoveryShelf] = []

        // Begin personal seed lookup concurrently, but never make public Home
        // wait for it. Guests skip the lookup in resolvedSeed entirely.
        async let resolvedSeedValue = resolvedSeed(from: seed)
        async let editorial = fetchEditorial()
        async let chartCollections = fetchChartCollections()
        async let trending = fetchTrending()

        for result in [await editorial, await chartCollections, await trending] {
            built.append(contentsOf: result.shelves)
            recorded.append(contentsOf: result.failures)
        }
        let publicShelves = reorder(built.filter { !$0.isEmpty })
        if !publicShelves.isEmpty { shelves = publicShelves }

        let resolved = await resolvedSeedValue
        async let related = fetchRelated(seed: resolved)
        async let station = fetchStation(seed: resolved)
        for result in [await related, await station] {
            built.append(contentsOf: result.shelves)
            recorded.append(contentsOf: result.failures)
        }

        let refreshed = reorder(built.filter { !$0.isEmpty })
        if !refreshed.isEmpty {
            shelves = refreshed
            lastLoaded = Date()
            await persistCache(refreshed)
        }
        failures = recorded

        Log.ui.info(
            "Home: \(self.shelves.count, privacy: .public) shelf/shelves, \(recorded.count, privacy: .public) source(s) contributed none"
        )
        for failure in recorded {
            Log.ui.error(
                "Home source \(failure.id, privacy: .public) contributed no shelf: \(failure.reason, privacy: .public)"
            )
        }
    }

    private func hydrateCacheIfNeeded() async {
        guard !didHydrateCache else { return }
        didHydrateCache = true
        let rows = await cache.loadSection(Self.cacheSection)
        guard !rows.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let cached = rows.compactMap { try? decoder.decode(DiscoveryShelf.self, from: $0.payload) }
        guard !cached.isEmpty else { return }
        shelves = cached
        // A disk snapshot is immediately useful, but should always be refreshed in the background.
        lastLoaded = .distantPast
    }

    private func persistCache(_ shelves: [DiscoveryShelf]) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let rows = shelves.compactMap { shelf -> LibraryCache.WriteRow? in
            guard let payload = try? encoder.encode(shelf) else { return nil }
            return LibraryCache.WriteRow(id: shelf.id, payload: payload)
        }
        guard !rows.isEmpty else { return }
        await cache.replaceSection(Self.cacheSection, rows: rows)
    }

    func reset() {
        shelves = []
        failures = []
        lastLoaded = nil
    }

    #if DEBUG
    private func installVisualFixturesIfNeeded() -> Bool {
        guard VisualFixtures.isEnabled else { return false }
        shelves = VisualFixtures.discoveryShelves
        failures = []
        isLoading = false
        lastLoaded = Date()
        return true
    }
    #endif

    private func reorder(_ built: [DiscoveryShelf]) -> [DiscoveryShelf] {
        func rank(_ kind: DiscoveryShelf.Kind) -> Int {
            switch kind {
            case .editorial: return 0
            case .related: return 1
            case .station: return 2
            case .trending: return 3
            case .chartCollections: return 4
            }
        }
        return built.enumerated()
            .sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }
            .map(\.element)
    }

    private func resolvedSeed(from seed: Seed) async -> Seed {
        guard seed.isEmpty else { return seed }
        guard SoundCloudCredentialSource.shared.hasConfirmedAccount else { return seed }
        do {
            let page = try await api.getPlayHistory(limit: 1)
            guard let recent = page.collection.first else { return seed }
            return Seed(track: recent.track)
        } catch {
            Log.ui.info(
                "Home: no seed supplied and play history unavailable (\(DiscoverySourceFailure.withoutQueryValues(String(describing: error)), privacy: .public)); personal shelves will be absent"
            )
            return seed
        }
    }

    private struct SourceResult {
        var shelves: [DiscoveryShelf] = []
        var failures: [DiscoverySourceFailure] = []

        static func none(_ id: String, _ reason: String) -> SourceResult {
            SourceResult(shelves: [], failures: [DiscoverySourceFailure(id: id, reason: reason)])
        }

        static func none(_ id: String, error: Error) -> SourceResult {
            SourceResult(shelves: [], failures: [DiscoverySourceFailure(id: id, error: error)])
        }
    }

    private func shelf(
        for selection: Selection,
        idPrefix: String,
        kind: DiscoveryShelf.Kind
    ) -> DiscoveryShelf? {
        var entries: [DiscoveryEntry] = []
        for item in selection.items.collection {
            switch item {
            case .playlist(let playlist): entries.append(.playlist(playlist))
            case .systemPlaylist(let station): entries.append(.station(station))
            case .user(let user): entries.append(.user(user))
            }
        }
        entries = Array(entries.deduplicatedByID().prefix(maxItemsPerShelf))
        guard !entries.isEmpty else { return nil }

        let playlists = entries.compactMap { if case .playlist(let p) = $0 { return p } else { return nil } }
        let stations = entries.compactMap { if case .station(let s) = $0 { return s } else { return nil } }
        let users = entries.compactMap { if case .user(let u) = $0 { return u } else { return nil } }

        let content: DiscoveryShelf.Content
        if stations.isEmpty && users.isEmpty {
            content = .playlists(playlists)
        } else if playlists.isEmpty && users.isEmpty {
            content = .stations(stations)
        } else if playlists.isEmpty && stations.isEmpty {
            content = .users(users)
        } else {
            content = .mixed(entries)
        }

        return DiscoveryShelf(
            id: "\(idPrefix).\(selection.id)",
            title: selection.title,
            subtitle: selection.description,
            kind: kind,
            content: content
        )
    }

    private func fetchEditorial() async -> SourceResult {
        do {
            let page = try await api.getMixedSelections()
            var result = SourceResult()
            for selection in page.collection {
                guard let built = shelf(
                    for: selection, idPrefix: "discovery.selection", kind: .editorial
                ) else { continue }
                result.shelves.append(built)
            }
            if result.shelves.isEmpty {
                return .none("mixed-selections", "no selection held a renderable playlist or station")
            }
            return result
        } catch {
            return .none("mixed-selections", error: error)
        }
    }

    private func fetchChartCollections() async -> SourceResult {
        do {
            let page = try await api.getChartSelections()
            var result = SourceResult()
            for selection in page.collection {
                guard let built = shelf(
                    for: selection, idPrefix: "discovery.chartselection", kind: .chartCollections
                ) else { continue }
                result.shelves.append(built)
            }
            if result.shelves.isEmpty {
                return .none("charts/selections", "no chart selection held a renderable playlist or station")
            }
            return result
        } catch {
            return .none("charts/selections", error: error)
        }
    }

    private func fetchTrending() async -> SourceResult {
        do {
            let page = try await api.getCharts(limit: maxItemsPerShelf)
            let tracks = page.collection.map(\.track).deduplicatedByID()
            guard !tracks.isEmpty else {
                return .none("charts", "empty chart")
            }
            return SourceResult(shelves: [DiscoveryShelf(
                id: "discovery.charts.trending.\(ChartGenre.allMusic)",
                title: titles.trending,
                subtitle: nil,
                kind: .trending,
                content: .tracks(tracks)
            )])
        } catch {
            return .none("charts", error: error)
        }
    }

    private func fetchRelated(seed: Seed) async -> SourceResult {
        guard let trackID = seed.trackID else { return SourceResult() }
        do {
            let page = try await api.getRelatedTracks(trackID: trackID, limit: maxItemsPerShelf)
            let tracks = page.collection.deduplicatedByID()
            guard !tracks.isEmpty else {
                return .none("tracks/:id/related", "no related tracks for \(trackID)")
            }
            let title = seed.trackTitle.map { String(format: titles.relatedFormat, $0) }
                ?? titles.relatedFallback
            return SourceResult(shelves: [DiscoveryShelf(
                id: "discovery.related.\(trackID)",
                title: title,
                subtitle: nil,
                kind: .related,
                content: .tracks(tracks)
            )])
        } catch {
            return .none("tracks/:id/related", error: error)
        }
    }

    private func fetchStation(seed: Seed) async -> SourceResult {
        guard let urn = seed.stationURN else { return SourceResult() }
        do {
            let station = try await api.getSystemPlaylist(urn: urn)
            let tracks = try await api.getSystemPlaylistTracks(station, limit: maxItemsPerShelf)
                .deduplicatedByID()
            guard !tracks.isEmpty else {
                return .none("system-playlists", "station \(urn) hydrated to nothing")
            }
            return SourceResult(shelves: [DiscoveryShelf(
                id: "discovery.station.\(station.id)",
                title: station.description ?? station.title,
                subtitle: station.shortDescription,
                kind: .station,
                content: .tracks(tracks)
            )])
        } catch {
            return .none("system-playlists", error: error)
        }
    }
}

extension Array where Element: Identifiable {
    func deduplicatedByID() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}
