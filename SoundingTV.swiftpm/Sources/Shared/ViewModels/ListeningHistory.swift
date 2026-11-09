import Combine
import Foundation

struct ListeningHistoryEntry: Identifiable, Equatable {
    let track: Track
    let playedAt: Date?

    var id: String { "\(track.id)@\(playedAt.map { String(RecentPlay.millis($0)) } ?? "recent")" }

    var timeText: String? { playedAt?.formatted(date: .omitted, time: .shortened) }
}

struct ListeningHistoryCollection: Identifiable, Equatable {
    let entry: DiscoveryEntry
    let playedAt: Date

    var id: String { entry.id }
}

struct ListeningHistoryDay: Identifiable, Equatable {
    let id: Date
    let title: String
    let entries: [ListeningHistoryEntry]
}

enum ListeningHistoryMerge {
    static let reportSlack: TimeInterval = 60
    static let undatedTitle = "Recently Played"

    static func merged(
        remote: [ListeningHistoryEntry],
        local: [ListeningHistoryEntry],
        remoteHasMore: Bool
    ) -> [ListeningHistoryEntry] {
        let undated = remote.filter { $0.playedAt == nil }
        let dated = remote.filter { $0.playedAt != nil }
        let undatedIDs = Set(undated.map(\.track.id))
        let floor = remoteHasMore ? dated.compactMap(\.playedAt).min() : nil
        var newestRemote: [String: Date] = [:]
        for entry in dated {
            guard let played = entry.playedAt, (newestRemote[entry.track.id] ?? .distantPast) < played else { continue }
            newestRemote[entry.track.id] = played
        }
        let extra = local.filter { entry in
            guard let played = entry.playedAt, !entry.track.isPreviewOnly else { return false }
            if let floor, played < floor { return false }
            if entry.track.isLocal || LocalTrackFile.isLocalTrackID(entry.track.id) { return true }
            if undatedIDs.contains(entry.track.id) { return false }
            guard let reported = newestRemote[entry.track.id] else { return true }
            return reported < played.addingTimeInterval(-reportSlack)
        }
        var seen = Set<String>()
        let timeline = (dated + extra).sorted { ($0.playedAt ?? .distantPast) > ($1.playedAt ?? .distantPast) }
        return (undated + timeline).filter { seen.insert($0.id).inserted }
    }

    static func collections(_ contexts: [PlayHistoryContext]) -> [ListeningHistoryCollection] {
        var seen = Set<String>()
        return contexts
            .sorted { $0.playedAt > $1.playedAt }
            .filter { seen.insert($0.entry.id).inserted }
            .map { ListeningHistoryCollection(entry: $0.entry, playedAt: $0.playedAt) }
    }

    static func filtered(_ entries: [ListeningHistoryEntry], search: String) -> [ListeningHistoryEntry] {
        let needle = LibraryCache.fold(search.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            let track = entry.track
            let artist = track.publisher?.artist ?? track.user.displayName
            return LibraryCache.fold(track.title).contains(needle)
                || LibraryCache.fold(artist).contains(needle)
                || LibraryCache.fold(track.user.displayName).contains(needle)
        }
    }

    static func days(
        _ entries: [ListeningHistoryEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ListeningHistoryDay] {
        var order: [Date] = []
        var grouped: [Date: [ListeningHistoryEntry]] = [:]
        for entry in entries {
            let day = entry.playedAt.map { calendar.startOfDay(for: $0) } ?? .distantFuture
            if grouped[day] == nil { order.append(day) }
            grouped[day, default: []].append(entry)
        }
        return order.map { day in
            ListeningHistoryDay(
                id: day,
                title: day == .distantFuture ? undatedTitle : title(for: day, now: now, calendar: calendar),
                entries: grouped[day] ?? []
            )
        }
    }

    static func title(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day ?? 0
        switch age {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2...6:
            var style = Date.FormatStyle().weekday(.wide)
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            return day.formatted(style)
        default:
            var style = calendar.isDate(day, equalTo: now, toGranularity: .year)
                ? Date.FormatStyle().day().month(.wide)
                : Date.FormatStyle().day().month(.wide).year()
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            return day.formatted(style)
        }
    }

    static func queue(_ entries: [ListeningHistoryEntry]) -> [Track] {
        var seen = Set<String>()
        return entries.map(\.track).filter { seen.insert($0.id).inserted }
    }
}

@MainActor
final class ListeningHistory: ObservableObject {
    static let shared = ListeningHistory()

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum Source: Equatable {
        case playHistory
        case recentlyPlayed
    }

    @Published private(set) var entries: [ListeningHistoryEntry] = []
    @Published private(set) var collections: [ListeningHistoryCollection] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var source: Source = .playHistory
    @Published private(set) var isLoadingMore = false
    @Published private(set) var revision = 0

    static let collectionID = "sounding:history"
    static let queueSource = PlaybackQueueSource(id: collectionID, kind: .other, title: "History")

    private static let pageSize = 50
    private static let contextLimit = 24
    private static let staleAfter: TimeInterval = 5 * 60

    private let api: SoundCloudAPI
    private let cache: LibraryCache
    private let recents: RecentlyPlayed
    private var remote: [ListeningHistoryEntry] = []
    private var nextHref: URL?
    private var remoteAccountID: String?
    private var fetchedAt: Date?
    private var haltedUntil: Date?
    private var loadTask: Task<Void, Never>?
    private var isWanted = false
    private var cancellables = Set<AnyCancellable>()

    init(api: SoundCloudAPI = .shared, cache: LibraryCache = .shared, recents: RecentlyPlayed = .shared) {
        self.api = api
        self.cache = cache
        self.recents = recents
        hydrate()
        recents.$history
            .removeDuplicates()
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AccountDataVault.didForgetAccountData)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.forget() }
            .store(in: &cancellables)
        SoundCloudCredentialSource.shared.$state
            .map { $0.currentUser?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.resetRemote()
                self.hydrate()
                guard self.isWanted else { return }
                Task { await self.load() }
            }
            .store(in: &cancellables)
    }

    private var accountID: String? { SoundCloudAPI.credentials?.currentUser?.id }

    var isSignedIn: Bool { SoundCloudCredentialSource.shared.hasConfirmedAccount && accountID != nil }

    var hasMore: Bool { nextHref != nil && !isHalted }

    var tracks: [Track] { ListeningHistoryMerge.queue(entries) }

    private var isHalted: Bool {
        guard let haltedUntil else { return false }
        return haltedUntil > Date()
    }

    // MARK: - Loading

    func load(force: Bool = false) async {
        isWanted = true
        if let loadTask {
            await loadTask.value
            return
        }
        guard isSignedIn, let account = accountID else {
            rebuild()
            phase = .loaded
            return
        }
        if !force, remoteAccountID == account, let fetchedAt,
           Date().timeIntervalSince(fetchedAt) < Self.staleAfter { return }
        if isHalted {
            if entries.isEmpty { phase = .failed(Self.busyMessage) } else if phase != .loaded { phase = .loaded }
            return
        }
        if entries.isEmpty { phase = .loading }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchFirstPage(account: account)
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func fetchFirstPage(account: String) async {
        do {
            let page = try await Self.logged("play history") {
                try await self.api.getPlayHistory(limit: Self.pageSize)
            }
            guard accountID == account else { return }
            adopt(page.collection.map { ListeningHistoryEntry(track: $0.track, playedAt: $0.playedAt) }, next: page.nextHref, source: .playHistory, account: account)
        } catch let error where Self.wantsFallback(error) {
            guard accountID == account else { return }
            note(error)
            await fetchRecentlyPlayed(account: account)
            return
        } catch {
            guard accountID == account else { return }
            fail(error)
            return
        }
        if !isHalted {
            do {
                let contexts = try await Self.logged("played from") {
                    try await self.api.getPlayHistoryContexts(limit: Self.contextLimit)
                }
                if accountID == account { collections = ListeningHistoryMerge.collections(contexts.collection) }
            } catch {
                note(error)
            }
        }
        phase = .loaded
        persist(account: account)
    }

    private func fetchRecentlyPlayed(account: String) async {
        do {
            let tracks = try await Self.logged("recently played, official API") {
                try await self.api.getRecentlyPlayedTracks()
            }
            guard accountID == account else { return }
            collections = []
            adopt(tracks.map { ListeningHistoryEntry(track: $0, playedAt: nil) }, next: nil, source: .recentlyPlayed, account: account)
            phase = .loaded
        } catch {
            guard accountID == account else { return }
            fail(error)
        }
    }

    private func adopt(_ entries: [ListeningHistoryEntry], next: URL?, source: Source, account: String) {
        remote = entries
        nextHref = next
        self.source = source
        remoteAccountID = account
        fetchedAt = Date()
        haltedUntil = nil
        rebuild()
    }

    private func fail(_ error: Error) {
        note(error)
        phase = entries.isEmpty ? .failed(Self.message(for: error)) : .loaded
    }

    func loadMore() {
        guard !isLoadingMore, loadTask == nil, source == .playHistory, let next = nextHref, !isHalted,
              let account = accountID, remoteAccountID == account else { return }
        isLoadingMore = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLoadingMore = false }
            do {
                let page = try await Self.logged("play history, next page") {
                    try await self.api.getPage(PlayHistoryItem.self, from: next)
                }
                guard self.accountID == account, self.nextHref == next else { return }
                self.remote.append(contentsOf: page.collection.map { ListeningHistoryEntry(track: $0.track, playedAt: $0.playedAt) })
                self.nextHref = page.nextHref
            } catch {
                self.note(error)
                if !Self.isRateLimit(error) { self.nextHref = nil }
            }
            self.rebuild()
        }
    }

    private static func logged<T>(_ detail: String, _ work: () async throws -> T) async rethrows -> T {
        try await NetworkActivityLog.$feature.withValue(.history) {
            try await NetworkActivityLog.$detail.withValue("History: \(detail)") {
                try await work()
            }
        }
    }

    private func note(_ error: Error) {
        guard Self.isRateLimit(error) else {
            Log.ui.info("History: SoundCloud history unavailable (\(DiscoverySourceFailure.withoutQueryValues(String(describing: error)), privacy: .public))")
            return
        }
        haltedUntil = SoundCloudGateway.shared.backgroundWorkPausedUntil ?? Date().addingTimeInterval(15 * 60)
        Log.ui.info("History: paused after a SoundCloud rate limit")
    }

    private static func wantsFallback(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        switch api {
        case .unauthorized, .forbidden, .notFound: return true
        default: return false
        }
    }

    private static func isRateLimit(_ error: Error) -> Bool {
        if let api = error as? APIError {
            switch api {
            case .rateLimited, .temporarilyBlocked: return true
            default: return false
            }
        }
        if let gateway = error as? SoundCloudGatewayError {
            switch gateway {
            case .backgroundPaused, .endpointCoolingDown: return true
            default: return false
            }
        }
        return false
    }

    private static let busyMessage = "SoundCloud is busy. Try again in a few minutes."

    static func message(for error: Error) -> String {
        if isRateLimit(error) { return busyMessage }
        if let api = error as? APIError, case .unauthorized = api { return "Sign in to SoundCloud again to see your history." }
        return "Check your connection and try again."
    }

    // MARK: - Merge

    private func rebuild() {
        let local = recents.history.map { ListeningHistoryEntry(track: $0.track, playedAt: $0.playedAt) }
        let remote = remoteAccountID == accountID ? self.remote : []
        let next = ListeningHistoryMerge.merged(remote: remote, local: local, remoteHasMore: nextHref != nil)
        guard next != entries else { return }
        entries = next
        revision &+= 1
    }

    private func resetRemote() {
        loadTask?.cancel()
        remote = []
        nextHref = nil
        remoteAccountID = nil
        fetchedAt = nil
        haltedUntil = nil
        source = .playHistory
        collections = []
        phase = .idle
        rebuild()
    }

    private func forget() {
        let account = remoteAccountID
        resetRemote()
        if let account {
            let cache = self.cache
            let sections = Self.sections(account)
            Task {
                await cache.replaceSection(sections.tracks, rows: [])
                await cache.replaceSection(sections.contexts, rows: [])
            }
        }
    }

    // MARK: - Cache

    private static func sections(_ account: String) -> (tracks: String, contexts: String) {
        let suffix = AccountDataVault.storageSuffix(for: account)
        return ("history.tracks.\(suffix)", "history.contexts.\(suffix)")
    }

    private func hydrate() {
        guard let account = accountID else {
            rebuild()
            return
        }
        let sections = Self.sections(account)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let items = cache.loadSection(sections.tracks, limit: Self.pageSize)
            .compactMap { try? decoder.decode(PlayHistoryItem.self, from: $0.payload) }
        let contexts = cache.loadSection(sections.contexts, limit: Self.contextLimit)
            .compactMap { try? decoder.decode(PlayHistoryContext.self, from: $0.payload) }
        if !items.isEmpty {
            remote = items.map { ListeningHistoryEntry(track: $0.track, playedAt: $0.playedAt) }
            remoteAccountID = account
            nextHref = nil
        }
        collections = ListeningHistoryMerge.collections(contexts)
        rebuild()
    }

    private func persist(account: String) {
        guard source == .playHistory else { return }
        let sections = Self.sections(account)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let trackRows = remote.prefix(Self.pageSize).compactMap { entry -> LibraryCache.WriteRow? in
            guard let playedAt = entry.playedAt,
                  let payload = try? encoder.encode(PlayHistoryItem(playedAt: playedAt, track: entry.track)) else { return nil }
            return LibraryCache.WriteRow(id: entry.id, payload: payload, likedAtMillis: RecentPlay.millis(playedAt))
        }
        let contextRows = collections.compactMap { collection -> LibraryCache.WriteRow? in
            let context = PlayHistoryContext(playedAt: collection.playedAt, entry: collection.entry)
            guard let payload = try? encoder.encode(context) else { return nil }
            return LibraryCache.WriteRow(id: context.id, payload: payload, likedAtMillis: RecentPlay.millis(context.playedAt))
        }
        let cache = self.cache
        Task(priority: .utility) {
            await cache.replaceSection(sections.tracks, rows: trackRows)
            await cache.replaceSection(sections.contexts, rows: contextRows)
        }
    }

    // MARK: - Playback

    static func stationTracks(_ station: SystemPlaylist) async throws -> [Track] {
        PlaybackQueueSourceDirectory.note(station)
        let source = station.trackIDs.isEmpty
            ? try await SoundCloudAPI.shared.getSystemPlaylist(urn: station.id)
            : station
        return try await SoundCloudAPI.shared.getSystemPlaylistTracks(source, limit: 50)
    }

    static func notePlayback() {
        PlaybackQueueSourceDirectory.note(queueSource)
    }
}
