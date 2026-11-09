import Combine
import Foundation

@MainActor
final class RecentlyPlayed: ObservableObject {
    static let shared = RecentlyPlayed()

    struct Item: Identifiable, Equatable {
        let track: Track
        let playedAt: Date

        var id: String { track.id }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var history: [Item] = []

    var tracks: [Track] { items.map(\.track) }

    static let shelfLimit = 20

    private static let cacheSection = "home.recentlyPlayed.tracks"
    private static let remoteLimit = 25
    private static let remoteStaleAfter: TimeInterval = 5 * 60
    private static let lookupBatch = 50

    private let settings: SettingsStore
    private let api: SoundCloudAPI
    private let cache: LibraryCache
    private let defaults: UserDefaults
    private var known: [String: Track] = [:]
    private var attempted: Set<String> = []
    private var remotePlays: [RecentPlay] = []
    private var remoteAccountID: String?
    private var remoteFetchedAt: Date?
    private var remoteTask: Task<Bool, Never>?
    private var guestPlays: [RecentPlay] = []
    private var resolveTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: SettingsStore = .shared,
        api: SoundCloudAPI = .shared,
        cache: LibraryCache = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.settings = settings
        self.api = api
        self.cache = cache
        self.defaults = defaults
        hydrateFromCache()
        settings.$recentPlays
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleReconcile() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AccountDataVault.didForgetAccountData)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.forget() }
            .store(in: &cancellables)
        SoundCloudCredentialSource.shared.$state
            .map { $0.currentUser?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleReconcile() }
            .store(in: &cancellables)
        rebuild()
    }

    private var accountID: String? { SoundCloudAPI.credentials?.currentUser?.id }

    // MARK: - Recording

    func record(_ track: Track, at date: Date = Date()) {
        let play = RecentPlay(track: track, playedAt: date)
        known[track.id] = track
        guard let accountID else {
            guestPlays = RecentPlays.recording(play, into: guestPlays)
            rebuild()
            return
        }
        let own = RecentPlays.recording(play, into: ownPlays(accountID))
        saveOwnPlays(own, accountID: accountID)
        settings.setRecentPlays(RecentPlays.merging([[play], settings.recentPlays, own]))
        rebuild()
    }

    func refreshFromSoundCloud(force: Bool = false) async {
        guard SoundCloudCredentialSource.shared.hasConfirmedAccount, let account = accountID else { return }
        if !force, remoteAccountID == account, let remoteFetchedAt,
           Date().timeIntervalSince(remoteFetchedAt) < Self.remoteStaleAfter { return }
        if let remoteTask {
            _ = await remoteTask.value
            return
        }
        let api = self.api
        let task = Task { @MainActor [weak self] () -> Bool in
            do {
                let page = try await api.getPlayHistory(limit: Self.remoteLimit)
                guard let self, self.accountID == account else { return false }
                for item in page.collection { self.known[item.track.id] = item.track }
                self.remotePlays = RecentPlays.fromSoundCloud(page.collection)
                self.remoteAccountID = account
                self.remoteFetchedAt = Date()
                return true
            } catch {
                Log.ui.info("Recently Played: SoundCloud history unavailable (\(DiscoverySourceFailure.withoutQueryValues(String(describing: error)), privacy: .public))")
                return false
            }
        }
        remoteTask = task
        let updated = await task.value
        remoteTask = nil
        if updated { rebuild() }
    }

    private func forget() {
        remotePlays = []
        remoteAccountID = nil
        remoteFetchedAt = nil
        guestPlays = []
        known = [:]
        attempted = []
        items = []
        history = []
        persistTask?.cancel()
        Task { await cache.replaceSection(Self.cacheSection, rows: []) }
    }

    // MARK: - Sync

    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.reconcileTask = nil
            self.reconcile()
        }
    }

    private func reconcile() {
        if let accountID {
            let synced = settings.recentPlays
            let merged = RecentPlays.merging([synced, ownPlays(accountID)])
            if merged != synced { settings.setRecentPlays(merged) }
        }
        rebuild()
    }

    private func ownPlaysKey(_ accountID: String) -> String {
        "red.forbes.sounding.recentPlays.device.\(AccountDataVault.storageSuffix(for: accountID))"
    }

    private func ownPlays(_ accountID: String) -> [RecentPlay] {
        guard let data = defaults.data(forKey: ownPlaysKey(accountID)) else { return [] }
        return (try? JSONDecoder().decode([RecentPlay].self, from: data)) ?? []
    }

    private func saveOwnPlays(_ plays: [RecentPlay], accountID: String) {
        guard let data = try? JSONEncoder().encode(plays) else { return }
        defaults.set(data, forKey: ownPlaysKey(accountID))
    }

    private var plays: [RecentPlay] {
        guard let accountID else { return guestPlays }
        let remote = remoteAccountID == accountID ? remotePlays : []
        return RecentPlays.merging([settings.recentPlays, ownPlays(accountID), remote, guestPlays])
    }

    // MARK: - Tracks

    private func rebuild() {
        var built: [Item] = []
        var missing: [RecentPlay] = []
        let plays = self.plays
        let local = localTracks(for: plays.filter(\.isLocal))
        for play in plays {
            if let track = known[play.trackID] ?? local[play.trackID] {
                built.append(Item(track: track, playedAt: play.playedAt))
            } else if !play.isLocal, !attempted.contains(play.trackID) {
                missing.append(play)
            }
        }
        let next = Array(built.prefix(Self.shelfLimit))
        if next.isEmpty, !items.isEmpty, plays.isEmpty || !missing.isEmpty {
            if !missing.isEmpty { resolve(missing.map(\.trackID)) }
            return
        }
        if built != history { history = built }
        if next != items {
            items = next
            schedulePersist()
        }
        if !missing.isEmpty { resolve(missing.map(\.trackID)) }
    }

    private func resolve(_ ids: [String]) {
        guard resolveTask == nil else { return }
        let wanted = Array(ids.prefix(Self.lookupBatch))
        let api = self.api
        resolveTask = Task { @MainActor [weak self] in
            let cached = await LibraryDB.cachedTracks(ids: wanted)
            guard let self else { return }
            for (id, track) in cached { self.known[id] = track }
            let remaining = wanted.filter { cached[$0] == nil }
            self.attempted.formUnion(remaining)
            if !remaining.isEmpty, api.hasCredentials {
                let fetched = try? await SoundCloudRequestEnvironment.autonomous(lane: .metadata) {
                    try await api.getTracks(ids: remaining)
                }
                for track in fetched ?? [] { self.known[track.id] = track }
            }
            self.resolveTask = nil
            self.rebuild()
        }
    }

    private func localTracks(for plays: [RecentPlay]) -> [String: Track] {
        #if os(watchOS)
        return [:]
        #else
        guard !plays.isEmpty else { return [:] }
        let library = LocalMusicLibrary.shared.allTracks + RemoteLocalMusic.shared.allTracks
        guard !library.isEmpty else { return [:] }
        var byID: [String: Track] = [:]
        var byName: [String: [Track]] = [:]
        for track in library {
            if byID[track.id] == nil { byID[track.id] = track }
            byName[Self.nameKey(title: track.title, artist: track.publisher?.artist ?? track.user.displayName), default: []].append(track)
        }
        var found: [String: Track] = [:]
        for play in plays {
            if let track = byID[play.trackID] {
                found[play.trackID] = track
                continue
            }
            let candidates = byName[Self.nameKey(title: play.title, artist: play.artist)] ?? []
            let match = candidates.first { candidate in
                guard let duration = play.duration, candidate.duration > 0 else { return true }
                return abs(candidate.duration - duration) <= 2
            }
            if let match { found[play.trackID] = match }
        }
        return found
        #endif
    }

    private static func nameKey(title: String, artist: String) -> String {
        LibraryCache.fold(title) + "\u{1F}" + LibraryCache.fold(artist)
    }

    // MARK: - Cache

    private func hydrateFromCache() {
        let decoder = LikesSyncEngine.makeDecoder()
        var cached: [Item] = []
        for row in cache.loadSection(Self.cacheSection, limit: Self.shelfLimit) {
            guard let track = try? decoder.decode(Track.self, from: row.payload) else { continue }
            known[track.id] = track
            guard let millis = row.likedAtMillis else { continue }
            cached.append(Item(track: track, playedAt: Date(timeIntervalSince1970: TimeInterval(millis) / 1000)))
        }
        items = cached
    }

    private func schedulePersist() {
        persistTask?.cancel()
        let played = items.map { (track: $0.track, millis: Int64($0.playedAt.timeIntervalSince1970 * 1000)) }
        let cache = self.cache
        let section = Self.cacheSection
        persistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let encoder = LikesSyncEngine.makeEncoder()
            let rows = played.compactMap { entry -> LibraryCache.WriteRow? in
                guard let payload = try? encoder.encode(entry.track) else { return nil }
                return LibraryCache.WriteRow(id: entry.track.id, payload: payload, likedAtMillis: entry.millis)
            }
            await cache.replaceSection(section, rows: rows)
        }
    }
}
