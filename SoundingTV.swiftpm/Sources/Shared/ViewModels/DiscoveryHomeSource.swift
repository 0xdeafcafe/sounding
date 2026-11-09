import Foundation
import Combine

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
        var recentlyPlayed = "Recently Played"

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
    private let retryAfter: TimeInterval = 30
    private var lastAttempt: Date?

    private let maxItemsPerShelf = 20

    private let api = SoundCloudAPI.shared
    private let cache = LibraryCache.shared
    private let recentlyPlayed = RecentlyPlayed.shared
    private var discoveryShelves: [DiscoveryShelf] = []
    private var recentObservation: AnyCancellable?
    private var didHydrateCache = false
    private var loadedAccountKey: String?
    private var accountObservation: AnyCancellable?
    private var identityObservation: AnyCancellable?
    private var inflight: Task<Void, Never>?
    private var personalAccountID: String?
    private var accountEpoch = 0
    private static let cacheSection = "discovery.home"
    private static let personalKinds: [DiscoveryShelf.Kind] = [.related, .station]

    enum FeedAction: Equatable {
        case load
        case keepCached
    }

    static func feedAction(accountStatus: SoundCloudAccountStatus, canAuthenticate: Bool) -> FeedAction {
        switch accountStatus {
        case .signedOut: return .load
        case .needsReconnect: return .keepCached
        case .signedIn: return canAuthenticate ? .load : .keepCached
        }
    }

    static func confirmedAccountKey(_ state: SoundCloudCredentialSource.PublishedAuthState) -> String? {
        guard state.isAuthenticated, state.sessionHealth == .healthy, let id = state.currentUser?.id else { return nil }
        return "\(id)#\(state.signInGeneration)"
    }

    init() {
        hydrateCacheImmediately()
        accountObservation = SoundCloudCredentialSource.shared.$state
            .map(Self.confirmedAccountKey)
            .removeDuplicates()
            .compactMap { $0 }
            .sink { [weak self] key in
                guard let self, self.loadedAccountKey != key else { return }
                Log.auth.notice("Home reloading for the confirmed account")
                Task {
                    await self.inflight?.value
                    self.lastLoaded = nil
                    await self.load(quietly: !self.shelves.isEmpty)
                }
            }
        identityObservation = SoundCloudCredentialSource.shared.$state
            .map { $0.isSignedOut ? "" : $0.currentUser?.id }
            .removeDuplicates()
            .sink { [weak self] id in
                guard let self, let id else { return }
                if id.isEmpty || self.personalAccountID.map({ $0 != id }) == true {
                    self.forgetPersonalShelves()
                }
            }
        recentObservation = recentlyPlayed.$items
            .map { $0.map(\.track) }
            .removeDuplicates()
            .sink { [weak self] tracks in self?.compose(recent: tracks) }
    }

    private func publish(_ discovery: [DiscoveryShelf]) {
        discoveryShelves = discovery
        compose(recent: recentlyPlayed.tracks)
    }

    private func compose(recent: [Track]) {
        #if DEBUG
        if VisualFixtures.isEnabled { return }
        #endif
        shelves = Self.composed(discovery: discoveryShelves, recent: recent, title: titles.recentlyPlayed)
    }

    static func composed(discovery: [DiscoveryShelf], recent: [Track], title: String) -> [DiscoveryShelf] {
        var composed = discovery.filter { $0.kind != .recent }
        guard !recent.isEmpty else { return composed }
        let shelf = DiscoveryShelf(
            id: "discovery.recent",
            title: title,
            subtitle: nil,
            kind: .recent,
            content: .tracks(recent)
        )
        composed.insert(shelf, at: min(1, composed.count))
        return composed
    }

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
            if let lastAttempt, Date().timeIntervalSince(lastAttempt) < retryAfter { return }
            await load(seed: seed, quietly: !shelves.isEmpty)
            return
        }
        if Date().timeIntervalSince(lastLoaded) > staleAfter {
            await load(seed: seed, quietly: !shelves.isEmpty)
        }
    }

    func load(seed: Seed = Seed(), quietly: Bool = false) async {
        #if DEBUG
        if installVisualFixturesIfNeeded() { return }
        #endif
        await hydrateCacheIfNeeded()
        if let inflight {
            await inflight.value
            return
        }
        let intent: SoundCloudRequestIntent = quietly ? .autonomous : SoundCloudRequestEnvironment.intent
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await SoundCloudRequestEnvironment.$intent.withValue(intent) {
                await self.performLoad(seed: seed)
            }
            self.inflight = nil
        }
        inflight = task
        await task.value
    }

    private func performLoad(seed: Seed) async {
        let credentials = SoundCloudCredentialSource.shared
        if Self.feedAction(
            accountStatus: credentials.accountStatus,
            canAuthenticate: credentials.accessToken != nil
        ) == .keepCached {
            Log.auth.notice("Home kept its cached feed: account \(String(describing: credentials.accountStatus), privacy: .public)")
            loadedAccountKey = nil
            if shelves.isEmpty {
                failures = [DiscoverySourceFailure(id: "account", reason: "sign-in needs reconnecting", isCredentialRejection: true)]
            }
            return
        }
        isLoading = true
        lastAttempt = Date()
        defer { isLoading = false }

        let epoch = accountEpoch
        var recorded: [DiscoverySourceFailure] = []
        var fresh: [(kind: DiscoveryShelf.Kind, shelves: [DiscoveryShelf])] = []

        async let resolvedSeedValue = resolvedSeed(from: seed)
        async let editorial = fetchEditorial()
        async let chartCollections = fetchChartCollections()
        async let trending = fetchTrending()

        for (kind, result) in [(DiscoveryShelf.Kind.editorial, await editorial), (DiscoveryShelf.Kind.chartCollections, await chartCollections), (DiscoveryShelf.Kind.trending, await trending)] {
            recorded.append(contentsOf: result.failures)
            let shelves = result.shelves.filter { !$0.isEmpty }
            if !shelves.isEmpty { fresh.append((kind, shelves)) }
        }
        if !fresh.isEmpty, !accountLostMidLoad { publish(Self.applying(fresh, to: discoveryShelves)) }

        let resolved = await resolvedSeedValue
        async let related = fetchRelated(seed: resolved)
        async let station = fetchStation(seed: resolved)
        var personal: [(kind: DiscoveryShelf.Kind, shelves: [DiscoveryShelf])] = []
        for (kind, result) in [(DiscoveryShelf.Kind.related, await related), (DiscoveryShelf.Kind.station, await station)] {
            recorded.append(contentsOf: result.failures)
            let shelves = result.shelves.filter { !$0.isEmpty }
            if !shelves.isEmpty { personal.append((kind, shelves)) }
        }
        if epoch == accountEpoch { fresh.append(contentsOf: personal) }

        if accountLostMidLoad {
            Log.auth.notice("Home discarded a load that finished after the sign-in stopped working")
            loadedAccountKey = nil
            return
        }
        if !fresh.isEmpty {
            publish(Self.applying(fresh, to: discoveryShelves))
            lastLoaded = Date()
            loadedAccountKey = Self.confirmedAccountKey(SoundCloudCredentialSource.shared.state)
            if epoch == accountEpoch, !personal.isEmpty, credentials.hasConfirmedAccount {
                personalAccountID = credentials.currentUser?.id
            }
            await persistCache(discoveryShelves)
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

    static func applying(
        _ fresh: [(kind: DiscoveryShelf.Kind, shelves: [DiscoveryShelf])],
        to current: [DiscoveryShelf]
    ) -> [DiscoveryShelf] {
        var merged = current
        for update in fresh where !update.shelves.isEmpty {
            merged.removeAll { $0.kind == update.kind }
            merged.append(contentsOf: update.shelves)
        }
        return ordered(merged.deduplicatedByID())
    }

    private func forgetPersonalShelves() {
        accountEpoch += 1
        personalAccountID = nil
        loadedAccountKey = nil
        let kept = discoveryShelves.filter { !Self.personalKinds.contains($0.kind) }
        guard kept.count != discoveryShelves.count else { return }
        publish(kept)
    }

    private var accountLostMidLoad: Bool {
        let credentials = SoundCloudCredentialSource.shared
        return Self.feedAction(
            accountStatus: credentials.accountStatus,
            canAuthenticate: credentials.accessToken != nil
        ) == .keepCached
    }

    private func hydrateCacheIfNeeded() async {
        hydrateCacheImmediately()
    }

    private func hydrateCacheImmediately() {
        guard !didHydrateCache else { return }
        didHydrateCache = true
        let rows = cache.loadSection(Self.cacheSection, limit: 24)
        guard !rows.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let cached = rows.compactMap { try? decoder.decode(DiscoveryShelf.self, from: $0.payload) }
        guard !cached.isEmpty else { return }
        publish(Self.ordered(cached.filter { $0.kind != .recent }))
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
        accountEpoch += 1
        personalAccountID = nil
        loadedAccountKey = nil
        publish([])
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

    static func ordered(_ built: [DiscoveryShelf]) -> [DiscoveryShelf] {
        func rank(_ kind: DiscoveryShelf.Kind) -> Int {
            switch kind {
            case .editorial: return 0
            case .related: return 1
            case .station: return 2
            case .trending: return 3
            case .chartCollections: return 4
            case .recent: return 5
            }
        }
        return built.enumerated()
            .sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }
            .map(\.element)
    }

    private func resolvedSeed(from seed: Seed) async -> Seed {
        guard SoundCloudCredentialSource.shared.hasConfirmedAccount else { return seed }
        await recentlyPlayed.refreshFromSoundCloud()
        guard seed.isEmpty else { return seed }
        guard let recent = recentlyPlayed.tracks.first(where: { !$0.isLocal }) else {
            Log.ui.info("Home: no seed supplied and no recent SoundCloud play; personal shelves will be absent")
            return seed
        }
        return Seed(track: recent)
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

@MainActor
final class HomeStore {
    static let shared = HomeStore()

    let forYou = DiscoveryHomeSource()
    private(set) lazy var following = FeedViewModel()

    private init() {}
}
