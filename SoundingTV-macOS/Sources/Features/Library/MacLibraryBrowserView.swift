import SwiftUI
import AppKit
import Combine

enum MacBrowsableRoute {
    case search
    case home

    var section: MacRootView.Section {
        switch self {
        case .search: return .search
        case .home: return .home
        }
    }

    var label: String {
        switch self {
        case .search: return "Search SoundCloud"
        case .home: return "Browse Home"
        }
    }
}

struct MacSignedOutEmptyState: View {
    var icon: String = "person.crop.circle.badge.xmark"
    let title: String
    let message: String
    var browsableRoute: MacBrowsableRoute = .search

    @State private var isSigningIn = false

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            Button("Sign In…") { isSigningIn = true }
                .buttonStyle(.borderedProminent)
                .tint(MacOnboardingView.signInTint)
            Button(browsableRoute.label) {
                MacRootSelection.shared.request(browsableRoute.section)
            }
        }
        .macFillsPane()
        .sheet(isPresented: $isSigningIn) {
            MacSoundCloudSignInView(peerName: nil, forHandoff: false, isReauthentication: false) {
                isSigningIn = false
            }
        }
    }
}

extension MacRootView.Section {
    var signInTopic: SoundCloudSignInTopic {
        switch self {
        case .recentlyAdded: .recentlyAdded
        case .likes: .likes
        case .friendsWithADJ: .privateShares
        case .artists: .artists
        case .sets: .sets
        case .playlists, .myPlaylists, .likedPlaylists, .playlist: .playlists
        case .profile: .profile
        case .messages: .messages
        case .followers: .followers
        case .following: .following
        case .myTracks: .myTracks
        case .stations: .stations
        default: .account
        }
    }
}

extension View {
    func soundCloudSignIn(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            MacSoundCloudSignInView(peerName: nil, forHandoff: false, isReauthentication: false) {
                isPresented.wrappedValue = false
            }
        }
    }
}

struct MacAccountRecoveryEmptyState: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @State private var isShowingReconnection = false

    let sectionName: String

    var body: some View {
        ContentUnavailableView {
            Label(
                credentials.sessionRecoveryTitle ?? "Reconnect SoundCloud",
                systemImage: credentials.canRetrySession ? "arrow.clockwise.circle" : "person.crop.circle.badge.exclamationmark"
            )
        } description: {
            Text(recoveryMessage)
        } actions: {
            Button(credentials.sessionRecoveryActionTitle ?? "Reconnect") {
                recover()
            }
            .buttonStyle(.borderedProminent)
        }
        .macFillsPane()
        .sheet(isPresented: $isShowingReconnection) {
            MacSoundCloudSignInView(
                peerName: nil,
                forHandoff: false,
                isReauthentication: true
            ) {
                isShowingReconnection = false
            }
        }
    }

    private var recoveryMessage: String {
        let state = credentials.sessionRecoveryMessage
            ?? "Sounding couldn’t verify this SoundCloud sign-in."
        return "\(sectionName) is unavailable right now. \(state)"
    }

    private func recover() {
        if credentials.canRetrySession {
            Task { await credentials.revalidate() }
        } else {
            isShowingReconnection = true
        }
    }
}

extension Error {
    var macUserFacingMessage: String {
        if let api = self as? APIError {
            switch api {
            case .unauthorized, .forbidden:
                return "SoundCloud didn’t accept this sign-in. Sign in again to continue."
            case .notFound:
                return "SoundCloud couldn’t find that."
            case .rateLimited, .temporarilyBlocked:
                return "SoundCloud is limiting requests right now. Try again in a few minutes."
            case .noStreamURL:
                return "This track can’t be played on this account."
            case .invalidURL, .networkError, .decodingError, .serverError:
                break
            }
        }
        if (self as NSError).domain == NSURLErrorDomain {
            return "Couldn’t reach SoundCloud. Check your connection and try again."
        }
        return "Something went wrong talking to SoundCloud. Try again."
    }
}

@MainActor
final class MacDeckTrackRegistry: ObservableObject {
    static let shared = MacDeckTrackRegistry()

    @Published private(set) var tracks: [Int: Track] = [:]
    @Published private(set) var loadingDecks: Set<Int> = []
    @Published private(set) var loadErrors: [Int: String] = [:]
    @Published private(set) var autoManagedDecks: Set<Int> = []

    private var cancellables = Set<AnyCancellable>()

    private init() {
        Publishers.CombineLatest3(
            MixEngine.shared.$decks,
            PlayerService.shared.djDirector.$snapshot,
            PlayerService.shared.$queue
        )
        .sink { [weak self] decks, snapshot, queue in
            self?.reconcileAutoSession(decks: decks, snapshot: snapshot, queue: queue)
        }
        .store(in: &cancellables)
    }

    private func reconcileAutoSession(decks: [MixEngine.DeckState], snapshot: DJSessionSnapshot?, queue: [Track]) {
        guard let snapshot, snapshot.isAutoMixEnabled else {
            if !autoManagedDecks.isEmpty { autoManagedDecks.removeAll() }
            return
        }

        for deck in MixEngine.Deck.allCases {
            let engineTrackId = decks[deck.rawValue].trackId

            guard let engineTrackId else {
                if autoManagedDecks.contains(deck.rawValue) {
                    autoManagedDecks.remove(deck.rawValue)
                    clear(deck)
                }
                continue
            }

            guard tracks[deck.rawValue]?.id != engineTrackId else { continue }

            let resolved = [PlayerService.shared.currentTrack, PlayerService.shared.upcomingTrack]
                .compactMap { $0 }
                .first { $0.id == engineTrackId }
                ?? queue.first { $0.id == engineTrackId }

            guard let resolved else { continue }

            tracks[deck.rawValue] = resolved
            loadingDecks.remove(deck.rawValue)
            loadErrors[deck.rawValue] = nil
            autoManagedDecks.insert(deck.rawValue)
        }
    }

    func track(for deck: MixEngine.Deck) -> Track? { tracks[deck.rawValue] }

    func set(_ track: Track, for deck: MixEngine.Deck) {
        tracks[deck.rawValue] = track
        loadingDecks.remove(deck.rawValue)
        loadErrors[deck.rawValue] = nil
        autoManagedDecks.remove(deck.rawValue)
    }

    func beginLoading(_ track: Track, for deck: MixEngine.Deck) {
        tracks[deck.rawValue] = track
        loadErrors[deck.rawValue] = nil
        loadingDecks.insert(deck.rawValue)
        autoManagedDecks.remove(deck.rawValue)
    }

    func finishLoading(_ deck: MixEngine.Deck) {
        loadingDecks.remove(deck.rawValue)
        loadErrors[deck.rawValue] = nil
    }

    func failLoading(_ deck: MixEngine.Deck, reason: String) {
        loadingDecks.remove(deck.rawValue)
        loadErrors[deck.rawValue] = reason
    }

    func isLoading(_ deck: MixEngine.Deck) -> Bool {
        loadingDecks.contains(deck.rawValue)
    }

    func loadError(for deck: MixEngine.Deck) -> String? {
        loadErrors[deck.rawValue]
    }

    func clear(_ deck: MixEngine.Deck) {
        tracks[deck.rawValue] = nil
        loadingDecks.remove(deck.rawValue)
        loadErrors[deck.rawValue] = nil
        autoManagedDecks.remove(deck.rawValue)
    }

    func nextAvailableDeck() -> MixEngine.Deck {
        track(for: .a) == nil ? .a : (track(for: .b) == nil ? .b : .a)
    }
}

enum MacMixLoader {
    @MainActor
    static func load(_ track: Track, into deck: MixEngine.Deck) async throws {
        if let denial = MacDeckControlSurface.djDenial(.decks, source: track.source) {
            PlayerService.shared.entitlementPrompt = denial
            throw denial
        }
        let registry = MacDeckTrackRegistry.shared
        registry.beginLoading(track, for: deck)

        do {
            try await PlayerService.shared.loadManualDeck(track, into: deck)
            registry.finishLoading(deck)
        } catch let denial as SoundCloudEntitlementError {
            registry.failLoading(deck, reason: denial.errorDescription ?? "Couldn’t load track")
            PlayerService.shared.entitlementPrompt = denial
            throw denial
        } catch {
            registry.failLoading(deck, reason: "Couldn’t load track")
            throw error
        }

        if let localFileURL = MixEngine.shared.localFileURL(for: deck) {
            AutomaticAnalysisScheduler.shared.schedule(
                track,
                trigger: .deckLoaded,
                localFileURL: localFileURL,
                transcoding: track.mixSource
            )
        }
    }

}

enum MacAnalysisEngineKind: Hashable, Sendable {
    case musicUnderstanding
    case genreTaxonomy
    case soundCloudWaveform
    case userCorrection
    case other(String)

    init(engineName: String) {
        switch engineName {
        case AnalysisEngineIdentity.musicUnderstanding().name: self = .musicUnderstanding
        case AnalysisEngineIdentity.genreTaxonomy().name: self = .genreTaxonomy
        case AnalysisEngineIdentity.soundCloudWaveform().name: self = .soundCloudWaveform
        case AnalysisEngineIdentity.userCorrection().name: self = .userCorrection
        default: self = .other(engineName)
        }
    }

    init(authority: AnalysisAuthority) {
        switch authority {
        case .corrected: self = .userCorrection
        case .measured: self = .musicUnderstanding
        case .estimated: self = .genreTaxonomy
        }
    }

    var displayName: String {
        switch self {
        case .musicUnderstanding: return "On-device analysis"
        case .genreTaxonomy: return "Genre taxonomy"
        case .soundCloudWaveform: return "SoundCloud waveform"
        case .userCorrection: return "Corrected by you"
        case .other(let name): return name
        }
    }

    var tempoAndKeyProvenance: SCAnalysisProvenance {
        switch self {
        case .userCorrection: return .stated
        case .musicUnderstanding: return .measured
        case .genreTaxonomy, .soundCloudWaveform, .other: return .inferred
        }
    }
}

struct MacAnalysisRecord: Identifiable, Sendable, Equatable {
    let cacheKey: String
    let trackId: String
    let engine: MacAnalysisEngineKind
    let engineVersion: Int
    let schemaVersion: Int
    let byteSize: Int
    let producedAt: Date
    let lastUsedAt: Date
    let producerId: String
    let isFromThisDevice: Bool
    let bpm: Double?
    let key: CamelotKey?
    let genre: String?
    let preset: String
    let bitrate: Int
    let codec: String

    var id: String { cacheKey }

    var hasIndexedValue: Bool { bpm != nil || key != nil || genre != nil }
}

struct MacAnalysisResult: Sendable, Equatable {
    var bpm: Double?
    var bpmEngine: MacAnalysisEngineKind?
    var key: CamelotKey?
    var keyEngine: MacAnalysisEngineKind?
    var genre: String?
    var genreEngine: MacAnalysisEngineKind?

    init(_ summary: AnalysisFeatureSummary) {
        bpm = summary.bpm
        bpmEngine = summary.bpmAuthority.map(MacAnalysisEngineKind.init(authority:))
        key = summary.key
        keyEngine = summary.keyAuthority.map(MacAnalysisEngineKind.init(authority:))
        genre = summary.genre
        genreEngine = summary.genreAuthority.map(MacAnalysisEngineKind.init(authority:))
    }

    var isEmpty: Bool { bpm == nil && key == nil && genre == nil }
    var summary: TrackAnalysisSummary {
        TrackAnalysisSummary(
            bpm: bpm, key: key, genre: genre,
            bpmProvenance: bpmProvenance, keyProvenance: keyProvenance, genreProvenance: genreProvenance
        )
    }

    var bpmProvenance: SCAnalysisProvenance {
        guard bpm != nil, let bpmEngine else { return .unavailable }
        return bpmEngine.tempoAndKeyProvenance
    }

    var keyProvenance: SCAnalysisProvenance {
        guard key != nil, let keyEngine else { return .unavailable }
        return keyEngine.tempoAndKeyProvenance
    }

    var genreProvenance: SCAnalysisProvenance {
        guard genre != nil else { return .unavailable }
        return genreEngine == .userCorrection ? .stated : .inferred
    }
}

struct MacAnalysisCorrection: Codable, Sendable, Equatable {
    var bpm: Double?
    var keyLabel: String?
    var genre: String?
    var updatedAt: Date = Date()

    var isEmpty: Bool {
        bpm == nil && (keyLabel?.isEmpty != false) && (genre?.isEmpty != false)
    }

    var key: CamelotKey? { keyLabel.flatMap(CamelotKey.parse) }
}

@MainActor
final class MacAnalysisCorrectionStore: ObservableObject {
    static let shared = MacAnalysisCorrectionStore()

    private static let defaultsKey = "red.forbes.sounding.mac.analysisCorrections"

    @Published private(set) var corrections: [String: MacAnalysisCorrection] = [:]

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: MacAnalysisCorrection].self, from: data)
        else { return }
        corrections = decoded
    }

    func correction(for trackId: String) -> MacAnalysisCorrection? { corrections[trackId] }

    func set(_ correction: MacAnalysisCorrection?, for trackId: String) {
        if let correction, !correction.isEmpty {
            var stamped = correction
            stamped.updatedAt = Date()
            corrections[trackId] = stamped
        } else {
            corrections[trackId] = nil
        }
        persist()
    }

    func removeAll() {
        corrections = [:]
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(corrections) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
final class MacAnalysisIndex: ObservableObject {
    static let shared = MacAnalysisIndex()

    @Published private(set) var recordsByTrack: [String: [MacAnalysisRecord]] = [:]
    @Published private(set) var summariesByTrack: [String: AnalysisFeatureSummary] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var usedBytes: Int64 = 0
    @Published private(set) var maxBytes: Int64 = AnalysisCache.defaultMaxBytes
    @Published private(set) var isTruncated = false

    private var refreshTask: Task<Void, Never>?

    private init() {}

    var rowCount: Int { recordsByTrack.values.reduce(0) { $0 + $1.count } }
    var analysedTrackCount: Int { recordsByTrack.count }

    func records(for trackId: String) -> [MacAnalysisRecord] { recordsByTrack[trackId] ?? [] }

    func result(forTrackId trackId: String) -> MacAnalysisResult? {
        summariesByTrack[trackId].map(MacAnalysisResult.init)
    }

    func refresh(limit: Int = 5_000) async {
        refreshTask?.cancel()
        let task = Task { @MainActor in
            isRefreshing = true
            defer { isRefreshing = false }

            let rows = await AnalysisCache.shared.allRecallRows(limit: limit)
            let used = await AnalysisCache.shared.usedBytes
            let max = await AnalysisCache.shared.maxBytes
            guard !Task.isCancelled else { return }

            let localProducerId = AnalysisSyncIdentity.producerId(defaults: .standard)
            let (grouped, summaries) = await Task.detached(priority: .utility) {
                var grouped: [String: [MacAnalysisRecord]] = [:]
                for row in rows {
                    let producerId = row.producerId ?? localProducerId
                    grouped[row.trackId, default: []].append(
                        MacAnalysisRecord(
                            cacheKey: row.cacheKey,
                            trackId: row.trackId,
                            engine: MacAnalysisEngineKind(engineName: row.generation.engine.name),
                            engineVersion: row.generation.engine.version,
                            schemaVersion: row.generation.schemaVersion,
                            byteSize: row.byteSize,
                            producedAt: row.producedAt,
                            lastUsedAt: row.lastAccessedAt,
                            producerId: producerId,
                            isFromThisDevice: producerId == localProducerId,
                            bpm: row.bpm,
                            key: row.key,
                            genre: row.genre,
                            preset: row.fingerprint.preset,
                            bitrate: row.fingerprint.bitrate,
                            codec: row.fingerprint.codec
                        )
                    )
                }
                return (grouped, AnalysisSummaryStore.summaries(grouping: rows))
            }.value
            guard !Task.isCancelled else { return }

            recordsByTrack = grouped
            summariesByTrack = summaries
            usedBytes = used
            maxBytes = max
            isTruncated = rows.count >= limit
            lastRefreshedAt = Date()
        }
        refreshTask = task
        await task.value
    }

    func forgetAnalysis(forTrackId trackId: String) async {
        await AnalysisCache.shared.invalidate(trackId: trackId)
        await refresh()
    }
}

@MainActor
enum MacAnalysisRunner {
    @discardableResult
    static func analyse(_ track: Track, force: Bool) async -> AnalysisWorkState {
        let state = await AutomaticAnalysisScheduler.shared.analyseNow(track, refresh: force)
        await MacAnalysisIndex.shared.refresh()
        return state
    }
}

struct MacLibraryRow: Identifiable {
    let track: Track
    let analysis: MacAnalysisResult?
    let dateAdded: Date
    let isLoadable: Bool

    init(track: Track, analysis: MacAnalysisResult?, dateAdded: Date? = nil) {
        self.isLoadable = track.mixSource != nil
        self.track = track
        self.analysis = analysis
        self.dateAdded = dateAdded ?? track.createdAt
    }

    var id: String { track.id }

    var titleKey: String { track.title }
    var artistKey: String { track.user.displayName }
    var genreKey: String { analysis?.genre ?? track.genre ?? "" }

    var genreBadge: (value: String, provenance: SCAnalysisProvenance, source: String)? {
        if let resolved = analysis?.genre {
            return (resolved, analysis?.genreProvenance ?? .inferred, analysis?.genreEngine == .userCorrection ? "Genre you set" : "Genre")
        }
        if let tag = track.genre, !tag.isEmpty {
            return (tag, .inferred, "Genre from SoundCloud")
        }
        return nil
    }
}

struct LibraryRowComparator: TrackKeyedSortComparator {
    var key: TrackSortKey
    var order: SortOrder = .forward

    init(key: TrackSortKey, order: SortOrder = .forward) {
        self.key = key
        self.order = order
    }

    func compare(_ lhs: MacLibraryRow, _ rhs: MacLibraryRow) -> ComparisonResult {
        if key == .dateAdded {
            return TrackSort.rank(lhs.dateAdded, rhs.dateAdded, order: order, by: <)
        }
        return TrackSort.compare(
            lhs.track,
            rhs.track,
            key: key,
            order: order,
            lhsAnalysis: lhs.analysis?.summary,
            rhsAnalysis: rhs.analysis?.summary
        )
    }
}

@MainActor
final class MacLibraryModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case liked = "Liked"
        case mine = "My Uploads"
        case friends = "Private Shares"
        case search = "Search"
        var id: String { rawValue }
    }

    @Published private(set) var mode: Mode = .liked {
        didSet { rebuildDerivedRows() }
    }
    @Published var filterText = "" {
        didSet {
            rebuildDerivedRows()
            if mode == .search {
                scheduleSearch(filterText)
            } else if !filterText.isEmpty {
                Task { await loadLocalRemainder() }
            }
        }
    }
    @Published var genreFilter: String? {
        didSet {
            rebuildDerivedRows()
            if genreFilter != nil { Task { await loadLocalRemainder() } }
        }
    }
    @Published var collectionFilter = TrackCollectionQuery.collectionOrder {
        didSet {
            guard collectionFilter != oldValue else { return }
            UserDefaults.standard.set(collectionFilter.rawValue, forKey: Self.filterStorageKey(mode))
            rebuildDerivedRows()
            if collectionFilter.isFiltering { Task { await loadLocalRemainder() } }
        }
    }

    private static func filterStorageKey(_ mode: Mode) -> String {
        "mac.library.filters.\(mode.rawValue)"
    }

    private func restoreFilter() {
        let stored = UserDefaults.standard.string(forKey: Self.filterStorageKey(mode)).flatMap(TrackCollectionQuery.init(rawValue:))
        collectionFilter = stored ?? .collectionOrder
    }

    @Published private(set) var tracks: [Track] = [] {
        didSet { rebuildDerivedRows() }
    }
    @Published private(set) var likedAtByTrackID: [String: Date] = [:] {
        didSet { rebuildDerivedRows() }
    }
    @Published private(set) var analysis: [String: MacAnalysisResult] = [:] {
        didSet { rebuildDerivedRows() }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let paginator: Paginator<Track>
    private var subscriptions = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private static let pageSize = 100

    private(set) var filteredRows: [MacLibraryRow] = []
    private(set) var distinctGenres: [String] = []

    private let cache = LibraryCache.shared

    var canLoadMore: Bool { paginator.hasMore }
    var isLoadingMore: Bool { paginator.isLoadingMore }

    init(mode: Mode = .liked) {
        self.mode = mode
        paginator = Paginator(soundCloudSource: PagedSource(
            first: { PagedChunk(items: []) },
            next: { _ in PagedChunk(items: []) }
        ))
        paginator.$items
            .dropFirst()
            .sink { [weak self] in self?.tracks = $0 }
            .store(in: &subscriptions)
        paginator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        paginator.onAppend = { [weak self] _ in
            Task { await self?.refreshAnalysis() }
        }
        LibrarySyncEngine.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        LibrarySyncEngine.shared.$revision
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.mode == .mine, LibrarySyncEngine.shared.lastChanged.contains(.ownTracks) else { return }
                Task { await self.paginator.reload() }
            }
            .store(in: &subscriptions)
        hydrateFromCacheImmediately(mode)
        restoreFilter()
        rebuildDerivedRows()
    }

    private static let cacheDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    private static let cacheEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(cacheDateFormatter)
        return encoder
    }()

    var awaitsLibrarySync: Bool {
        switch mode {
        case .liked: return LibrarySyncEngine.shared.isAwaitingFirstSync(.likes)
        case .mine: return LibrarySyncEngine.shared.isAwaitingFirstSync(.ownTracks)
        case .friends, .search: return false
        }
    }

    private static func cacheSection(for mode: Mode) -> String? {
        switch mode {
        case .liked:  return nil
        case .mine:   return nil
        case .friends: return "friends-with-a-dj"
        case .search: return nil
        }
    }

    private func hydrateFromCacheImmediately(_ mode: Mode) {
        guard let section = Self.cacheSection(for: mode) else { return }
        let rows = cache.loadSection(section, limit: Self.pageSize)
        guard !rows.isEmpty else { return }
        let decoder = LikesSyncEngine.makeDecoder()
        let decoded = rows.compactMap { try? decoder.decode(Track.self, from: $0.payload) }
        guard !decoded.isEmpty else { return }
        paginator.prime(items: decoded, cursor: rows.count == Self.pageSize ? .offset(rows.count) : nil)
    }

    private func cachedChunk(section: String, offset: Int) async -> PagedChunk<Track> {
        let rows = cache.loadSection(section, offset: offset, limit: Self.pageSize)
        guard !rows.isEmpty else { return PagedChunk(items: []) }
        let decoded = await Task.detached(priority: .userInitiated) {
            let decoder = LikesSyncEngine.makeDecoder()
            return rows.compactMap { try? decoder.decode(Track.self, from: $0.payload) }
        }.value
        let state = await cache.sectionState(section)
        let end = offset + rows.count
        let next: PagedCursor? = end < state.itemCount && rows.count == Self.pageSize
            ? .offset(end)
            : state.nextHref.map { .url($0) }
        return PagedChunk(items: decoded, next: next)
    }

    private func persist(_ section: String, tracks: [Track], nextHref: URL?) async {
        let rows: [LibraryCache.WriteRow] = tracks.compactMap { track in
            guard let payload = try? Self.cacheEncoder.encode(track) else { return nil }
            return LibraryCache.WriteRow(id: track.id, payload: payload)
        }
        await cache.mergeSection(section, rows: rows)
        await cache.markSectionProgress(section, nextHref: nextHref, completed: nextHref == nil)
    }

    private func likedIndexChunk(offset: Int, limit: Int) async -> PagedChunk<Track> {
        let indexed = await LikesSyncEngine.shared.indexedLikes(offset: offset, limit: limit)
        likedAtByTrackID.merge(indexed.likedAt) { _, incoming in incoming }
        let count = await cache.likesCount()
        let complete = await LikesSyncEngine.shared.indexCompletedAt() != nil
        let end = offset + limit
        let next: PagedCursor? = end < count ? .offset(end) : nil
        let total = complete ? count : max(count, SoundCloudCredentialSource.shared.currentUser?.publicFavoritesCount ?? count)
        return PagedChunk(items: indexed.tracks, next: next, total: total)
    }

    private func likedNetworkChunk(from url: URL?) async throws -> PagedChunk<Track> {
        let api = SoundCloudAPI.shared
        let page: Page<Like<Track>>
        if let url {
            page = try await api.getPage(Like<Track>.self, from: url)
            await LikesSyncEngine.shared.integrate(laterPage: page.collection)
        } else {
            page = try await api.getLikedTracks(limit: Self.pageSize)
            await LikesSyncEngine.shared.integrate(firstPage: page.collection)
        }
        for like in page.collection { likedAtByTrackID[like.item.id] = like.createdAt }
        let hint = SoundCloudCredentialSource.shared.currentUser?.publicFavoritesCount
        return PagedChunk(items: page.collection.map(\.item), next: page.nextHref.map { .url($0) }, total: hint)
    }

    private func likedSource() -> PagedSource<Track> {
        PagedSource(
            first: { [unowned self] in await likedIndexChunk(offset: 0, limit: Self.pageSize) },
            next: { [unowned self] cursor in
                guard case .offset(let offset) = cursor else { return PagedChunk(items: []) }
                return await likedIndexChunk(offset: offset, limit: Self.pageSize)
            }
        )
    }

    private func mineSource(userId: String) -> PagedSource<Track> {
        LibraryDB.trackSource(.ownTracks, pageSize: Self.pageSize)
    }

    private func friendsSource(ownerID: String) -> PagedSource<Track> {
        let section = "friends-with-a-dj"
        func shares(_ page: Page<LibraryItem>) async -> [Track] {
            let items = page.collection
            return await Task.detached(priority: .utility) {
                Self.privateShares(in: items, excludingOwner: ownerID)
            }.value
        }
        return PagedSource(
            first: { [unowned self] in
                let page = try await SoundCloudAPI.shared.getLibrary(limit: Self.pageSize)
                let found = await shares(page)
                await persist(section, tracks: found, nextHref: page.nextHref)
                return PagedChunk(items: found, next: page.nextHref.map { .url($0) })
            },
            next: { [unowned self] cursor in
                switch cursor {
                case .offset(let offset): return await cachedChunk(section: section, offset: offset)
                case .start: throw APIError.notFound
                case .url(let url):
                    let page = try await SoundCloudAPI.shared.getPage(LibraryItem.self, from: url)
                    let found = await shares(page)
                    await persist(section, tracks: found, nextHref: page.nextHref)
                    return PagedChunk(items: found, next: page.nextHref.map { .url($0) })
                }
            }
        )
    }

    private func searchSource(query: String) -> PagedSource<Track> {
        PagedSource(
            first: {
                let page = try await SoundCloudAPI.shared.searchTracks(query: query)
                return PagedChunk(items: page.collection, next: page.nextHref.map { .url($0) })
            },
            next: { cursor in
                guard case .url(let url) = cursor else { return PagedChunk(items: []) }
                let page = try await SoundCloudAPI.shared.getPage(Track.self, from: url)
                return PagedChunk(items: page.collection, next: page.nextHref.map { .url($0) })
            }
        )
    }

    func refreshLikedIndex(force: Bool = false) async {
        guard mode == .liked else { return }
        if !force {
            guard !paginator.isLoading else { return }
            switch paginator.cursor {
            case .url?, .start?: return
            default: break
            }
        }
        let want = max(Self.pageSize, paginator.items.count)
        let chunk = await likedIndexChunk(offset: 0, limit: want)
        guard !Task.isCancelled, mode == .liked, !chunk.items.isEmpty else { return }
        paginator.prime(items: chunk.items, cursor: chunk.next, total: chunk.total)
        await refreshAnalysis()
    }

    func loadLocalRemainder() async {
        guard mode != .search else { return }
        while case .offset? = paginator.cursor, paginator.hasLoadedFirst, !paginator.didFailLoadingMore, !Task.isCancelled {
            if paginator.isLoadingMore {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let before = paginator.cursor
            await paginator.loadMore()
            if paginator.cursor == before { break }
        }
    }

    func loadMore() {
        paginator.requestMore()
    }

    func retryLoadMore() {
        Task { await paginator.retry() }
    }

    private func rebuildDerivedRows() {
        let present = tracks.compactMap { analysis[$0.id]?.genre ?? $0.genre }
        distinctGenres = Array(Set(present)).sorted()

        var rows = tracks.map {
            MacLibraryRow(
                track: $0,
                analysis: analysis[$0.id],
                dateAdded: mode == .liked ? (likedAtByTrackID[$0.id] ?? $0.createdAt) : $0.createdAt
            )
        }

        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty, mode != .search {
            rows = rows.filter {
                $0.titleKey.lowercased().contains(needle) || $0.artistKey.lowercased().contains(needle)
            }
        }
        if let genreFilter {
            rows = rows.filter { $0.genreKey == genreFilter }
        }
        if collectionFilter.isFiltering {
            let context = TrackCollectionLoader.context()
            rows = rows.filter {
                TrackCollection.matches($0.track, query: collectionFilter, analysis: $0.analysis?.summary, context: context)
            }
        }
        filteredRows = rows
    }

    func setMode(_ newMode: Mode, currentUserId: String?, isSignedOut: Bool) {
        guard newMode != mode else { return }
        loadTask?.cancel()
        searchTask?.cancel()
        mode = newMode
        restoreFilter()
        paginator.reset()
        tracks = []
        likedAtByTrackID = [:]
        errorMessage = nil
        switch newMode {
        case .liked, .mine, .friends: load(currentUserId: currentUserId, isSignedOut: isSignedOut)
        case .search: break
        }
    }

    func load(currentUserId: String?, isSignedOut: Bool = false) {
        loadTask?.cancel()
        #if DEBUG
        if VisualFixtures.isEnabled, mode == .liked {
            errorMessage = nil
            paginator.prime(items: VisualFixtures.tracks, cursor: nil)
            return
        }
        #endif
        guard !isSignedOut else {
            paginator.reset()
            tracks = []
            errorMessage = nil
            Task { await cache.clearAll() }
            return
        }
        switch mode {
        case .liked: LibrarySyncEngine.shared.prioritise([.likes])
        case .mine: LibrarySyncEngine.shared.prioritise([.ownTracks])
        case .friends, .search: LibrarySyncEngine.shared.kick()
        }
        switch mode {
        case .liked:
            paginator.setSource(likedSource())
            loadTask = Task { await loadLiked() }
        case .mine:
            guard let currentUserId else {
                errorMessage = "Sign in on this Mac to see your uploads."
                return
            }
            paginator.setSource(mineSource(userId: currentUserId))
            loadTask = Task { await loadCachedThenNetwork(.mine) }
        case .friends:
            guard let currentUserId else {
                errorMessage = "Sign in to see private tracks shared with this account."
                return
            }
            paginator.setSource(friendsSource(ownerID: currentUserId))
            loadTask = Task { await loadCachedThenNetwork(.friends) }
        case .search:
            break
        }
    }

    private func loadLiked() async {
        let hadIndex = await cache.likesCount() > 0
        if hadIndex { await refreshLikedIndex(force: true) }
        guard !Task.isCancelled, mode == .liked else { return }
        if paginator.items.isEmpty {
            isLoading = true
            defer { isLoading = false }
            await paginator.reload()
            guard !Task.isCancelled, mode == .liked else { return }
            if paginator.isPaused {
                let resumes = paginator.pausedUntil.map { " at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
                errorMessage = "SoundCloud is limiting requests. Your sign-in is saved. Likes load automatically\(resumes)."
            } else {
                errorMessage = paginator.firstError.map(\.macUserFacingMessage)
            }
            await refreshAnalysis()
            return
        }
        errorMessage = nil
    }

    private func topUpLikedFromNetwork() async {
        do {
            let page = try await SoundCloudAPI.shared.getLikedTracks(limit: Self.pageSize)
            guard !Task.isCancelled, mode == .liked else { return }
            for like in page.collection { likedAtByTrackID[like.item.id] = like.createdAt }
            await LikesSyncEngine.shared.integrate(firstPage: page.collection)
            await refreshLikedIndex()
        } catch {
        }
    }

    private func loadCachedThenNetwork(_ target: Mode) async {
        if let section = Self.cacheSection(for: target), paginator.items.isEmpty {
            let cached = await cachedChunk(section: section, offset: 0)
            guard !Task.isCancelled, mode == target else { return }
            if !cached.items.isEmpty {
                paginator.prime(items: cached.items, cursor: cached.next)
                await refreshAnalysis()
            }
        }
        guard !Task.isCancelled, mode == target else { return }
        isLoading = paginator.items.isEmpty
        defer { isLoading = false }
        await paginator.reload()
        guard !Task.isCancelled, mode == target else { return }
        if let error = paginator.firstError, paginator.items.isEmpty {
            errorMessage = error.macUserFacingMessage
        } else {
            errorMessage = nil
        }
        await refreshAnalysis()
    }

    private nonisolated static func privateShares(in items: [LibraryItem], excludingOwner ownerID: String) -> [Track] {
        items.compactMap(\.track).filter { $0.isPrivate && $0.user.id != ownerID }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            paginator.reset()
            tracks = []
            errorMessage = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            paginator.setSource(searchSource(query: trimmed))
            isLoading = true
            defer { isLoading = false }
            await paginator.reload()
            guard !Task.isCancelled else { return }
            errorMessage = paginator.firstError.map(\.macUserFacingMessage)
        }
    }

    func refreshAnalysis(rereadStore: Bool = true) async {
        if rereadStore { await MacAnalysisIndex.shared.refresh() }
        var results: [String: MacAnalysisResult] = [:]
        for track in tracks {
            results[track.id] = MacAnalysisIndex.shared.result(forTrackId: track.id)
        }
        analysis = results.compactMapValues { $0 }
    }

}

struct MacPagedStatusBar<Item: Identifiable>: View {
    @ObservedObject var pager: Paginator<Item>

    var body: some View {
        if pager.isLoadingMore || pager.didFailLoadingMore || pager.isPaused {
            PagedFooter(
                isLoading: pager.isLoadingMore,
                failed: pager.didFailLoadingMore,
                isPaused: pager.isPaused,
                resumesAt: pager.pausedUntil,
                retry: { Task { await pager.retry() } },
                reachedEnd: {}
            )
            .font(.callout)
            .padding(.vertical, 2)
        }
    }
}

struct MacTableScrollEndObserver: NSViewRepresentable {
    let rowCount: Int
    let onNearEnd: () -> Void

    func makeNSView(context: Context) -> Anchor {
        Anchor()
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.onNearEnd = onNearEnd
        view.contentDidChange()
    }

    final class Anchor: NSView {
        var onNearEnd: () -> Void = {}
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var attachAttempts = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                detach()
            } else {
                attach()
            }
        }

        func contentDidChange() {
            if scrollView == nil, window != nil {
                attach()
            } else {
                DispatchQueue.main.async { [weak self] in self?.check() }
            }
        }

        private func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            scrollView = nil
            attachAttempts = 0
        }

        private func attach() {
            guard scrollView == nil, let content = window?.contentView else { return }
            guard let found = Self.table(in: content, matching: convert(bounds, to: nil)) else {
                attachAttempts += 1
                guard attachAttempts < 20 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.attach() }
                return
            }
            scrollView = found
            found.contentView.postsBoundsChangedNotifications = true
            if let document = found.documentView { document.postsFrameChangedNotifications = true }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: found.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
            if let document = found.documentView {
                observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check() }
                })
            }
            check()
        }

        private func check() {
            guard let scrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.contentView.bounds
            guard visible.height > 0 else { return }
            let remaining = document.frame.height - visible.maxY
            if remaining < visible.height * 1.5 { onNearEnd() }
        }

        private static func table(in root: NSView, matching rect: NSRect) -> NSScrollView? {
            var best: (NSScrollView, CGFloat)?
            func visit(_ view: NSView) {
                if let scroll = view as? NSScrollView, scroll.documentView is NSTableView {
                    let overlap = scroll.convert(scroll.bounds, to: nil).intersection(rect)
                    let area = overlap.isNull ? 0 : overlap.width * overlap.height
                    if area > (best?.1 ?? 0) { best = (scroll, area) }
                }
                for child in view.subviews { visit(child) }
            }
            visit(root)
            return best?.0
        }
    }
}

struct MacLibraryTable: View {
    let rows: [MacLibraryRow]
    var showsArtwork = true
    var usesCompactRows = false
    var loadTarget: MixEngine.Deck? = nil
    let onLoad: (Track, MixEngine.Deck) -> Void
    let onDoubleClick: (Track) -> Void
    var onShowSetlist: ((Track) -> Void)? = nil
    var onAnalysisChanged: () -> Void = {}
    var onNearEnd: () -> Void = {}
    var onSortNeedsEverything: () -> Void = {}
    var pager: Paginator<Track>? = nil
    var storageKey: String? = nil
    var showsSource = false

    @State private var sortOrder = [LibraryRowComparator(key: .dateAdded, order: .reverse)]
    @State private var columns = TableColumnCustomization<MacLibraryRow>()
    @State private var didRestore = false
    @AppStorage(TrackColumnLayout.storageKey) private var layout = TrackColumnLayout.standard
    @State private var selection = Set<String>()
    @State private var editingTrackId: String?
    @ObservedObject private var analysisWork = AutomaticAnalysisStatus.shared

    private static let artworkWarmupCount = 18

    var body: some View {
        let presentedRows = rows.sorted(using: sortOrder)

        VStack(spacing: 0) {
            table(presentedRows)
            if let pager {
                MacPagedStatusBar(pager: pager)
            }
            Text(summary)
                .font(.footnote)
                .foregroundStyle(MacSecondaryStyle())
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
    }

    private var summary: String {
        let count = "\(rows.count) \(rows.count == 1 ? "track" : "tracks")"
        let total = rows.reduce(0) { $0 + $1.track.duration }
        let duration = Duration.seconds(total).formatted(.units(allowed: [.hours, .minutes], width: .wide))
        return "\(count), \(duration)"
    }

    private func table(_ presentedRows: [MacLibraryRow]) -> some View {
        Table(presentedRows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn(TrackTableColumn.title.title(), sortUsing: LibraryRowComparator(key: TrackTableColumn.title.sortKey)) { row in
                titleCell(for: row)
                .trackDragSource(row.track, selection: dragSelection(including: row, in: presentedRows))
                .onAppear {
                    guard presentedRows.suffix(25).contains(where: { $0.id == row.id }) else { return }
                    onNearEnd()
                }
            }
            .trackColumn(.title)
            .disabledCustomizationBehavior([.visibility, .reorder])

            if let loadTarget {
                TableColumn("Load") { row in
                    Button("Load") { onLoad(row.track, loadTarget) }
                        .controlSize(.small)
                        .disabled(!row.isLoadable)
                        .help(row.isLoadable ? "Load into Deck \(loadTarget.label)" : "Not playable on this account")
                }
                .width(min: 60, ideal: 66, max: 80)
                .customizationID("load")
            }

            if let onShowSetlist {
                TableColumn("Setlist") { row in
                    Button {
                        onShowSetlist(row.track)
                    } label: {
                        Label("View", systemImage: "list.number")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("View the identified setlist for \(row.track.title)")
                }
                .width(min: 66, ideal: 74, max: 88)
                .customizationID("setlist")
            }

            TableColumnForEach(tableColumns) { column in
                TableColumn(column.title(), sortUsing: LibraryRowComparator(key: column.sortKey)) { row in
                    cell(column, row)
                }
                .trackColumn(column)
                .defaultVisibility(layout.isVisible(column) ? .visible : .hidden)
                .disabledCustomizationBehavior(.reorder)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(MacTableScrollEndObserver(rowCount: rows.count, onNearEnd: onNearEnd))
        .onAppear {
            restoreTableState()
            applyLayout()
        }
        .onChange(of: sortOrder) { _, newValue in
            guard didRestore, let storageKey else { return }
            var stored = TrackCollectionQuery.collectionOrder
            stored.adoptTableSort(newValue)
            if stored.sortKey != nil {
                UserDefaults.standard.set(stored.rawValue, forKey: "mac.table.sort.\(storageKey)")
                if TrackCollection.needsFullCollection(stored, naturalOrder: .newestFirst) { onSortNeedsEverything() }
            }
        }
        .onChange(of: columns) { _, newValue in
            adoptColumnVisibility(newValue)
        }
        .onChange(of: layout) { _, _ in
            applyLayout()
        }
        .foregroundStyle(.primary)
        .environment(\.defaultMinListRowHeight, usesCompactRows && !showsArtwork ? 24 : 36)
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            if let row = presentedRows.first(where: { selectedIDs.contains($0.id) }) {
                MacTrackContextMenu(track: row.track, presentsTempoKey: { onEditAnalysis($0.id) })
            }
        } primaryAction: { selectedIDs in
            guard let row = presentedRows.first(where: { selectedIDs.contains($0.id) }) else { return }
            onDoubleClick(row.track)
        }
        .sheet(
            item: Binding(get: { editingTrackId.map(IdentifiedString.init) }, set: { editingTrackId = $0?.value }),
            onDismiss: {
                Task {
                    await MacAnalysisIndex.shared.refresh()
                    onAnalysisChanged()
                    await MacSyncCoordinator.shared.runOnce()
                }
            }
        ) { wrapped in
            if let track = rows.first(where: { $0.track.id == wrapped.value })?.track {
                TrackTempoKeySheet(track: track)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .analysisDataDidChange)
                .debounce(for: .seconds(2), scheduler: RunLoop.main)
                .throttle(for: .seconds(10), scheduler: RunLoop.main, latest: true)
        ) { _ in
            guard editingTrackId == nil else { return }
            Task {
                await MacAnalysisIndex.shared.refresh()
                onAnalysisChanged()
            }
        }
        .prefetchArtwork(
            showsArtwork
                ? presentedRows.prefix(Self.artworkWarmupCount).compactMap(\.track.artworkURL)
                : [],
            variant: .thumbnail
        )
    }

    private func onEditAnalysis(_ trackId: String) { editingTrackId = trackId }

    private func restoreTableState() {
        defer { didRestore = true }
        guard !didRestore, let storageKey else { return }
        if let raw = UserDefaults.standard.string(forKey: "mac.table.sort.\(storageKey)"),
           let stored = TrackCollectionQuery(rawValue: raw),
           stored.sortKey != nil {
            sortOrder = stored.tableSortOrder()
            if TrackCollection.needsFullCollection(stored, naturalOrder: .newestFirst) { onSortNeedsEverything() }
        }
    }

    private var tableColumns: [TrackTableColumn] {
        layout.movable.filter { $0 != .source || showsSource }
    }

    private func applyLayout() {
        var updated = columns
        for column in tableColumns {
            updated[visibility: column.customizationID] = layout.isVisible(column) ? .visible : .hidden
        }
        if updated != columns { columns = updated }
    }

    private func adoptColumnVisibility(_ customization: TableColumnCustomization<MacLibraryRow>) {
        var next = layout
        for column in tableColumns {
            switch customization[visibility: column.customizationID] {
            case .visible: next.setVisible(column, true)
            case .hidden: next.setVisible(column, false)
            default: break
            }
        }
        if next != layout { layout = next }
    }

    @ViewBuilder
    private func cell(_ column: TrackTableColumn, _ row: MacLibraryRow) -> some View {
        switch column {
        case .artist:
            HStack(spacing: 7) {
                if showsArtwork {
                    ArtworkThumbnail(
                        url: row.track.user.avatarURL,
                        identity: row.track.user.id,
                        size: 22,
                        cornerRadius: 11
                    )
                }
                Text(row.track.user.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(MacSecondaryStyle())
            }
        case .bpm, .key, .genre:
            MacLibraryAnalysisCell(
                row: row,
                kind: column == .bpm ? .bpm : column == .key ? .key : .genre,
                state: analysisWork.state(for: row.track.id),
                onEditAnalysis: { onEditAnalysis(row.track.id) },
                onAnalysisChanged: onAnalysisChanged
            )
        case .time:
            TrackDurationLabel(track: row.track)
                .foregroundStyle(MacSecondaryStyle())
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .source:
            Label(TrackValueFormat.sourceLabel(row.track), systemImage: TrackValueFormat.sourceSymbol(row.track))
                .foregroundStyle(MacSecondaryStyle())
                .lineLimit(1)
        case .added:
            Text(TrackValueFormat.added(row.dateAdded))
                .foregroundStyle(MacSecondaryStyle())
                .lineLimit(1)
        default:
            Text(TrackValueFormat.value(column, track: row.track, analysis: row.analysis?.summary, dateAdded: row.dateAdded))
                .foregroundStyle(MacSecondaryStyle())
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: column.isNumeric ? .trailing : .leading)
        }
    }

    private func dragSelection(including row: MacLibraryRow, in rows: [MacLibraryRow]) -> [Track] {
        guard selection.contains(row.id), selection.count > 1 else { return [row.track] }
        return rows.filter { selection.contains($0.id) }.map(\.track)
    }

    @ViewBuilder
    private func titleCell(for row: MacLibraryRow) -> some View {
        HStack(spacing: 10) {
            if showsArtwork {
                ArtworkCell(
                    track: row.track,
                    isAvailable: row.isLoadable,
                    action: { onDoubleClick(row.track) }
                )
            } else {
                RowPlayAffordance(track: row.track, isAvailable: row.isLoadable) {
                    onDoubleClick(row.track)
                }
            }
            Text(row.track.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
        .macTrackAccessibility(track: row.track, bpm: row.analysis?.bpm)
    }

    private struct ArtworkCell: View {
        let track: Track
        let isAvailable: Bool
        let action: () -> Void
        @State private var artwork: NSImage?
        @State private var isHovering = false

        private var displayedArtwork: NSImage? {
            if let artwork { return artwork }
            guard let url = track.artworkURL else { return nil }
            return ArtworkCache.shared.cachedImage(for: url, variant: .thumbnail)
        }

        var body: some View {
            Button(action: action) {
                ZStack {
                    SCArtwork(
                        image: displayedArtwork.map { Image(nsImage: $0) },
                        identity: track.id,
                        isAvailable: isAvailable,
                        style: .mac,
                        cornerRadius: 3
                    )

                    if isHovering, isAvailable {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(.black.opacity(0.42))
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .onHover { hovering in
                isHovering = hovering
                if hovering, isAvailable { PlayerService.shared.preparePlayback(for: track) }
            }
            .help(isAvailable ? "Play \(track.title)" : "Not playable")
            .accessibilityLabel(isAvailable ? "Play \(track.title)" : "Not playable")
            .task(id: track.id) {
                guard let url = track.artworkURL else {
                    artwork = nil
                    return
                }
                if let cached = ArtworkCache.shared.cachedImage(for: url, variant: .thumbnail) {
                    artwork = cached
                    return
                }
                artwork = await ArtworkCache.shared.image(for: url, variant: .thumbnail)
            }
        }
    }

    private struct RowPlayAffordance: View {
        let track: Track
        let isAvailable: Bool
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isHovering && isAvailable ? Color.primary : Color.secondary.opacity(0.58))
                    .frame(width: 22, height: 22)
                    .background(isHovering && isAvailable ? Color.primary.opacity(0.10) : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .onHover { hovering in
                isHovering = hovering
                if hovering, isAvailable { PlayerService.shared.preparePlayback(for: track) }
            }
            .help(isAvailable ? "Play" : "Not playable on this account")
            .accessibilityLabel(isAvailable ? "Play \(track.title)" : "Not playable")
        }
    }

}

private enum MacLibraryAnalysisColumnKind {
    case bpm, key, genre
}

private struct MacLibraryAnalysisCell: View {
    let row: MacLibraryRow
    let kind: MacLibraryAnalysisColumnKind
    let state: AnalysisWorkState?
    let onEditAnalysis: () -> Void
    let onAnalysisChanged: () -> Void

    private var value: String? {
        switch kind {
        case .bpm: TrackValueFormat.bpm(row.analysis?.bpm)
        case .key: TrackValueFormat.key(row.analysis?.key)
        case .genre: row.genreBadge?.value
        }
    }

    private var isEdited: Bool {
        switch kind {
        case .bpm: row.analysis?.bpmEngine == .userCorrection
        case .key: row.analysis?.keyEngine == .userCorrection
        case .genre: row.analysis?.genreEngine == .userCorrection
        }
    }

    var body: some View {
        Group {
            if let value, !value.isEmpty {
                HStack(spacing: 3) {
                    Text(kind == .genre ? GenrePresentation.displayName(for: value) : value)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isEdited {
                        TrackAnalysisEditedMark()
                    }
                }
                .help(isEdited ? "Set by you" : valueHelp)
            } else if kind != .genre {
                TrackAnalysisPendingMark(track: row.track)
            } else if let state, state == .analysing || state.isQueued {
                ProgressView()
                    .controlSize(.mini)
                    .help(state == .analysing ? "Analysing…" : "Waiting to analyse")
                    .accessibilityLabel(state == .analysing ? "Analysing" : "Waiting to analyse")
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .help(emptyHelp)
                    .accessibilityLabel(emptyHelp)
            }
        }
        .font(.callout)
    }

    private var emptyHelp: String {
        if let state {
            switch state {
            case .notEligible: return "Analysis isn’t available for this track"
            case .failed: return "Analysis didn’t finish. Choose Analyse Again from the track’s menu."
            case .complete: return kind == .genre ? "No genre" : "No \(kind == .bpm ? "tempo" : "key") found"
            case .queued, .analysing: break
            }
        }
        switch kind {
        case .bpm: return "Not analysed yet"
        case .key: return "Not analysed yet"
        case .genre: return "No genre"
        }
    }

    private var valueHelp: String {
        switch kind {
        case .bpm:
            return row.analysis?.bpmProvenance == .measured || row.analysis?.bpmProvenance == .stated ? "Tempo" : "Estimated tempo"
        case .key:
            return row.analysis?.keyProvenance == .measured || row.analysis?.keyProvenance == .stated ? "Key" : "Estimated key"
        case .genre:
            return row.genreBadge?.source ?? "Genre"
        }
    }
}

struct MacLibraryPaneView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var model: MacLibraryModel
    @ObservedObject private var findFocus = MacFindFocus.shared
    @State private var isSearchPresented = false
    @State private var isShowingLikesPolicy = false
    @AppStorage("mac.library.showsArtwork") private var showsArtwork = true
    @AppStorage("mac.library.compactRows") private var usesCompactRows = true

    private let pinnedMode: MacLibraryModel.Mode?

    init(model: MacLibraryModel, pinnedMode: MacLibraryModel.Mode? = nil) {
        self.model = model
        self.pinnedMode = pinnedMode
    }

    var body: some View {
        content
        .toolbar {
            if model.mode != .liked {
                ToolbarItem(id: "library-view", placement: .primaryAction) {
                    libraryViewMenu
                }
            }

            ToolbarItem(id: "library-filter", placement: .primaryAction) {
                libraryFilterMenu
            }

            if model.mode == .liked {
                ToolbarItem(id: "library-download", placement: .primaryAction) {
                    CollectionDownloadButton(
                        collectionId: CollectionPolicyID.likedTracks,
                        tracks: { model.tracks }
                    )
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .foregroundStyle(MacSecondaryStyle())
                    .frame(width: 34, height: 34)
                    .help("Download liked tracks")
                    .accessibilityLabel("Download Liked Tracks")
                }

                ToolbarItem(id: "library-more", placement: .primaryAction) {
                    libraryMoreMenu
                }
            }
        }
        .navigationTitle(paneTitle)
        .navigationSubtitle(model.filteredRows.isEmpty ? "" : headerSubtitle)
        .searchable(
            text: $model.filterText,
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: searchPrompt
        )
        .onReceive(findFocus.$request.dropFirst()) { _ in isSearchPresented = true }
        .background(Color.primary.opacity(0.001))
        .task(id: "\(credentials.isSignedOut)|\(credentials.isSessionRejected)|\(credentials.isAuthenticated)") {
            if model.filteredRows.isEmpty {
                model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
            }
        }
        .task(id: model.tracks.map(\.id)) {
            guard model.mode == .liked else { return }
            DownloadManager.shared.applyCollectionPolicy(
                tracks: model.tracks,
                collectionId: CollectionPolicyID.likedTracks
            )
        }
        .onReceive(LikesSyncEngine.shared.$revision.dropFirst()) { _ in
            Task { await model.refreshLikedIndex() }
        }
        .sheet(isPresented: $isShowingLikesPolicy) {
            CollectionPolicyEditor(
                collectionId: CollectionPolicyID.likedTracks,
                collectionName: "Liked Tracks",
                collectionKind: .playlist,
                tracks: model.tracks,
                applier: DownloadManager.shared
            )
        }
    }

    private var searchPrompt: String {
        switch model.mode {
        case .search: return "Search SoundCloud"
        case .liked: return "Filter Liked Tracks"
        case .mine: return "Filter My Uploads"
        case .friends: return "Filter Private Shares"
        }
    }

    private var paneTitle: String {
        switch model.mode {
        case .search: return "Search"
        case .liked: return "Likes"
        case .mine: return "My Uploads"
        case .friends: return "Private Shares"
        }
    }

    private var headerSubtitle: String {
        let query = model.filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty, !isFilteringLibrary else {
            let count = model.filteredRows.count
            let countText = "\(count)\(model.canLoadMore ? "+" : "") track\(count == 1 ? "" : "s")"
            return query.isEmpty ? countText : "\(countText) matching “\(query)”"
        }
        return model.paginator.countText(singular: "track", plural: "tracks")
    }

    private var libraryViewMenu: some View {
        Menu {
            Toggle(isOn: $showsArtwork) {
                Label("Show Artwork", systemImage: "photo")
            }
            Toggle(isOn: $usesCompactRows) {
                Label("Compact Rows", systemImage: "rectangle.compress.vertical")
            }
            .disabled(showsArtwork)
        } label: {
            Image(systemName: "rectangle.grid.1x2")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(MacSecondaryStyle())
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .frame(width: 34, height: 34)
        .help("View options")
        .accessibilityLabel("View Options")
    }

    private var isFilteringLibrary: Bool {
        model.genreFilter != nil || model.collectionFilter.isFiltering
    }

    private func filterToggle(_ filter: TrackFilter) -> some View {
        Toggle(isOn: Binding(
            get: { model.collectionFilter.filters.contains(filter) },
            set: { _ in model.collectionFilter.toggle(filter) }
        )) {
            Label(filter.title, systemImage: filter.icon)
        }
    }

    private var libraryFilterMenu: some View {
        Menu {
            Section("Show") {
                ForEach(TrackFilter.sourceFilters) { filterToggle($0) }
            }
            Section {
                ForEach(TrackFilter.propertyFilters) { filterToggle($0) }
                Picker("Tempo", selection: $model.collectionFilter.bpmRange) {
                    Text("Any Tempo").tag(TrackBPMRange?.none)
                    ForEach(TrackBPMRange.presets) { range in
                        Text(range.label).tag(TrackBPMRange?.some(range))
                    }
                }
                Menu("Genre") {
                    Button {
                        model.genreFilter = nil
                    } label: {
                        Label("All Genres", systemImage: model.genreFilter == nil ? "checkmark" : "line.3.horizontal.decrease")
                    }
                    if model.distinctGenres.isEmpty {
                        Divider()
                        Text("No genres in this view")
                    } else {
                        Divider()
                        ForEach(model.distinctGenres, id: \.self) { genre in
                            Button {
                                model.genreFilter = genre
                            } label: {
                                Label(
                                    GenrePresentation.displayName(for: genre),
                                    systemImage: model.genreFilter == genre ? "checkmark" : "music.note"
                                )
                            }
                        }
                    }
                }
            }
            if isFilteringLibrary {
                Section {
                    Button("Clear Filters") {
                        model.genreFilter = nil
                        model.collectionFilter.clearFilters()
                    }
                }
            }
        } label: {
            Image(systemName: isFilteringLibrary ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(MacSecondaryStyle())
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .frame(width: 34, height: 34)
        .help("Filter")
        .accessibilityLabel("Filter")
        .accessibilityValue(isFilteringLibrary ? "On" : "Off")
    }

    private var libraryMoreMenu: some View {
        Menu {
            Button {
                playLibrary(shuffled: false)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(playableTracks.isEmpty)

            Button {
                playLibrary(shuffled: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(playableTracks.isEmpty)

            Button {
                MacPlayback.playLast(playableTracks)
            } label: {
                Label("Add All to Up Next", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .disabled(playableTracks.isEmpty)

            Divider()

            Toggle(isOn: $showsArtwork) {
                Label("Show Artwork", systemImage: "photo")
            }
            Toggle(isOn: $usesCompactRows) {
                Label("Compact Rows", systemImage: "rectangle.compress.vertical")
            }
            .disabled(showsArtwork)

            Divider()

            Button {
                model.load(
                    currentUserId: credentials.currentUser?.id,
                    isSignedOut: credentials.isSignedOut
                )
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                isShowingLikesPolicy = true
            } label: {
                Label("Download Settings…", systemImage: "arrow.down.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(MacSecondaryStyle())
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .frame(width: 34, height: 34)
        .help("More library actions")
        .accessibilityLabel("More Library Actions")
    }

    private var playableTracks: [Track] {
        model.filteredRows.map(\.track).filter { $0.streamURL != nil }
    }

    private func playLibrary(shuffled: Bool) {
        var tracks = playableTracks
        if shuffled { tracks.shuffle() }
        guard let first = tracks.first else { return }
        play(first, in: tracks)
    }

    private func play(_ track: Track, in tracks: [Track]? = nil) {
        let queue = tracks ?? playableTracks
        guard queue.contains(where: { $0.id == track.id }) else { return }
        Task {
            await MacPlayback.play(
                track,
                in: queue,
                collectionId: model.mode == .liked ? CollectionPolicyID.likedTracks : nil
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if credentials.isSessionRejected {
            MacAccountRecoveryEmptyState(sectionName: recoverySectionName)
        } else if credentials.isSignedOut {
            MacSignedOutEmptyState(
                title: pinnedMode == .liked ? "Likes Need an Account" : "Library Needs an Account",
                message: pinnedMode == .liked
                    ? "Sign in to see the tracks you've liked. Search works without an account."
                    : "Sign in to see your library. Search works without an account.",
                browsableRoute: .search
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isLoading || model.awaitsLibrarySync, model.filteredRows.isEmpty {
            LoadingPlaceholder(.trackList(.mac), showsSyncStatus: true)
        } else if let errorMessage = model.errorMessage, model.filteredRows.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load \(paneTitle)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
                }
            }
            .macFillsPane()
        } else if model.filteredRows.isEmpty, !model.filterText.isEmpty {
            ContentUnavailableView.search(text: model.filterText)
                .macFillsPane()
        } else if model.filteredRows.isEmpty, isFilteringLibrary {
            ContentUnavailableView {
                Label("No Matching Tracks", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No tracks match these filters.")
            } actions: {
                Button("Clear Filters") {
                    model.genreFilter = nil
                    model.collectionFilter.clearFilters()
                }
            }
            .macFillsPane()
        } else if model.filteredRows.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "music.note.list", description: Text(emptyDescription))
                .macFillsPane()
        } else {
            VStack(spacing: 0) {
                MacLibraryTable(
                    rows: model.filteredRows,
                    showsArtwork: showsArtwork,
                    usesCompactRows: usesCompactRows,
                    onLoad: { track, deck in
                        Task { try? await MacMixLoader.load(track, into: deck) }
                    },
                    onDoubleClick: { track in
                        play(track)
                    },
                    onAnalysisChanged: {
                        Task { await model.refreshAnalysis(rereadStore: false) }
                    },
                    onNearEnd: { model.loadMore() },
                    onSortNeedsEverything: { Task { await model.loadLocalRemainder() } },
                    pager: model.paginator,
                    storageKey: "library.\(model.mode.rawValue)"
                )
                if model.mode == .liked || model.mode == .mine {
                    LibrarySyncStatusLine()
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private var recoverySectionName: String {
        switch model.mode {
        case .liked: return "Likes"
        case .friends: return "Private Shares"
        case .mine: return "Uploads"
        case .search: return "Library"
        }
    }

    private var emptyTitle: String {
        switch model.mode {
        case .search: return model.filterText.isEmpty ? "Search SoundCloud" : "No Results"
        case .liked: return "No Liked Tracks"
        case .mine: return "No Uploads"
        case .friends: return "No Private Shares"
        }
    }

    private var emptyDescription: String {
        switch model.mode {
        case .search: return model.filterText.isEmpty ? "Type to search SoundCloud." : "Try a different search."
        case .liked: return "Tracks you like on SoundCloud show up here."
        case .mine: return "Tracks you upload show up here."
        case .friends: return "Private tracks shared with you show up here."
        }
    }
}

struct MacLibraryBrowserView: View {
    var targetDeck: MixEngine.Deck = .a
    let onLoad: (Track, MixEngine.Deck) -> Void

    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MacLibraryModel()
    @AppStorage("mac.library.showsArtwork") private var showsArtwork = true
    @AppStorage("mac.library.compactRows") private var usesCompactRows = true

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Load Track into Deck \(targetDeck.label)")
                .searchable(
                    text: $model.filterText,
                    placement: .toolbar,
                    prompt: model.mode == .search ? "Search SoundCloud" : "Filter"
                )
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        MacGlassTabs(
                            "Source",
                            selection: modeBinding,
                            options: Array(MacLibraryModel.Mode.allCases),
                            compact: true,
                            title: \.rawValue
                        )
                        .controlSize(.small)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .frame(minWidth: 760, minHeight: 540)
        .task {
            if credentials.isSignedOut, model.mode != .search {
                model.setMode(.search, currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
            }
            if model.filteredRows.isEmpty {
                model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
            }
        }
    }

    private var modeBinding: Binding<MacLibraryModel.Mode> {
        Binding(
            get: { model.mode },
            set: { model.setMode($0, currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut) }
        )
    }

    @ViewBuilder
    private var content: some View {
        if credentials.isSignedOut, model.mode != .search {
            ContentUnavailableView(
                model.mode == .liked ? "Likes Need an Account" : "Uploads Need an Account",
                systemImage: "person.crop.circle.badge.xmark",
                description: Text("Switch to Search to browse SoundCloud without an account.")
            )
            .macFillsPane()
        } else if model.isLoading || model.awaitsLibrarySync, model.filteredRows.isEmpty {
            LoadingPlaceholder(.trackList(.mac), showsSyncStatus: true)
        } else if let errorMessage = model.errorMessage, model.filteredRows.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load Tracks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
            .macFillsPane()
        } else if model.filteredRows.isEmpty, !model.filterText.isEmpty {
            ContentUnavailableView.search(text: model.filterText)
                .macFillsPane()
        } else if model.filteredRows.isEmpty {
            ContentUnavailableView(
                model.mode == .search ? "Search SoundCloud" : "No Liked Tracks",
                systemImage: model.mode == .search ? "magnifyingglass" : "music.note.list",
                description: Text(model.mode == .search ? "Type to search SoundCloud." : "Tracks you like on SoundCloud show up here.")
            )
            .macFillsPane()
        } else {
            MacLibraryTable(
                rows: model.filteredRows,
                showsArtwork: showsArtwork,
                usesCompactRows: usesCompactRows,
                loadTarget: targetDeck,
                onLoad: { track, deck in onLoad(track, deck) },
                onDoubleClick: { track in onLoad(track, targetDeck) },
                onNearEnd: { model.loadMore() },
                pager: model.paginator
            )
        }
    }
}
