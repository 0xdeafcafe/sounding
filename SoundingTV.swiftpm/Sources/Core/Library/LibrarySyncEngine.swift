import Foundation
import Combine

struct SoundCloudLibraryRemote: LibraryRemote {
    static let pageSize = 200

    func page(_ collection: LibraryCollection, from url: URL?) async throws -> LibraryPage {
        try await Self.fetchPage(collection, from: url)
    }

    func playlistManifest(id: String) async throws -> LibraryPlaylistManifest {
        try await Self.fetchPlaylist(id: id)
    }

    func tracks(ids: [String]) async throws -> [LibraryRecord] {
        try await Self.fetchTracks(ids: ids)
    }

    func expectedCounts() async -> [LibraryCollection: Int] {
        await Self.counts()
    }

    @MainActor
    private static func counts() -> [LibraryCollection: Int] {
        guard let user = SoundCloudAPI.credentials?.currentUser else { return [:] }
        var counts: [LibraryCollection: Int] = [
            .followings: user.followingsCount,
            .followers: user.followersCount,
            .ownTracks: user.trackCount,
        ]
        if let likes = user.publicFavoritesCount { counts[.likes] = likes }
        return counts
    }

    @MainActor
    private static func userID() async throws -> String {
        guard let user = await SoundCloudAPI.credentials?.waitForCurrentUser() else {
            throw LibraryRemoteError.stop(until: nil)
        }
        return user.id
    }

    @MainActor
    private static func fetchPage(_ collection: LibraryCollection, from url: URL?) async throws -> LibraryPage {
        let api = SoundCloudAPI.shared
        do {
            switch collection {
            case .likes:
                let page: Page<Like<Track>>
                if let url { page = try await api.getLikesPage(from: url) } else { page = try await api.getLikedTracks(limit: pageSize) }
                return LibraryPage(records: page.collection.compactMap { LibraryRecords.track($0.item, at: $0.createdAt) }, next: page.nextHref, droppedCount: page.droppedCount)
            case .likedPlaylists:
                let page: Page<Like<Playlist>>
                if let url { page = try await api.getPage(Like<Playlist>.self, from: url) } else { page = try await api.getPlaylistLikes(limit: pageSize) }
                return LibraryPage(records: page.collection.compactMap { LibraryRecords.playlist($0.item, at: $0.createdAt) }, next: page.nextHref, droppedCount: page.droppedCount)
            case .ownPlaylists:
                let id = try await userID()
                let page: Page<Playlist>
                if let url { page = try await api.getPage(Playlist.self, from: url) } else { page = try await api.getUserPlaylists(userId: id, limit: pageSize) }
                return LibraryPage(records: page.collection.compactMap { LibraryRecords.playlist($0, at: nil) }, next: page.nextHref, droppedCount: page.droppedCount)
            case .followings, .followers:
                let id = try await userID()
                let page: Page<User>
                if let url {
                    page = try await api.getPage(User.self, from: url)
                } else if collection == .followings {
                    page = try await api.getUserFollowings(userId: id, limit: pageSize)
                } else {
                    page = try await api.getUserFollowers(userId: id, limit: pageSize)
                }
                return LibraryPage(records: page.collection.compactMap(LibraryRecords.user), next: page.nextHref, droppedCount: page.droppedCount)
            case .ownTracks:
                let id = try await userID()
                let page: Page<Track>
                if let url { page = try await api.getPage(Track.self, from: url) } else { page = try await api.getUserTracks(userId: id, limit: pageSize) }
                return LibraryPage(records: page.collection.compactMap { LibraryRecords.track($0, at: nil) }, next: page.nextHref, droppedCount: page.droppedCount)
            case .reposts:
                let id = try await userID()
                let page: Page<StreamItem>
                if let url { page = try await api.getPage(StreamItem.self, from: url) } else { page = try await api.getUserReposts(userId: id, limit: pageSize) }
                let records = page.collection.compactMap { item -> LibraryRecord? in
                    if let track = item.track { return LibraryRecords.track(track, at: item.createdAt) }
                    if let playlist = item.playlist { return LibraryRecords.playlist(playlist, at: item.createdAt) }
                    return nil
                }
                return LibraryPage(records: records, next: page.nextHref, droppedCount: page.droppedCount)
            case .playlist:
                throw LibraryRemoteError.gone
            }
        } catch {
            throw LibraryRecords.classify(error)
        }
    }

    @MainActor
    private static func fetchPlaylist(id: String) async throws -> LibraryPlaylistManifest {
        do {
            let playlist = try await SoundCloudAPI.shared.getPlaylist(id: id)
            let ids = playlist.trackIDs ?? playlist.loadedTracks.map(\.id)
            return LibraryPlaylistManifest(
                trackIDs: ids,
                hydrated: playlist.loadedTracks.compactMap { LibraryRecords.track($0, at: nil) },
                changeKey: LibraryRecords.changeKey(playlist)
            )
        } catch {
            throw LibraryRecords.classify(error)
        }
    }

    @MainActor
    private static func fetchTracks(ids: [String]) async throws -> [LibraryRecord] {
        do {
            return try await SoundCloudAPI.shared.getTracks(ids: ids).compactMap { LibraryRecords.track($0, at: nil) }
        } catch {
            throw LibraryRecords.classify(error)
        }
    }
}

enum LibraryRecords {
    nonisolated(unsafe) private static let encoder = LikesSyncEngine.makeEncoder()

    static func millis(_ date: Date?) -> Int64? {
        date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }

    static func track(_ track: Track, at date: Date?) -> LibraryRecord? {
        guard let payload = try? encoder.encode(track) else { return nil }
        return LibraryRecord(
            kind: .track,
            id: track.id,
            payload: payload,
            title: track.title,
            artist: "\(track.user.displayName) \(track.user.username)",
            timestampMillis: millis(date),
            changeKey: nil
        )
    }

    static func playlist(_ playlist: Playlist, at date: Date?) -> LibraryRecord? {
        guard let payload = try? encoder.encode(playlist) else { return nil }
        return LibraryRecord(
            kind: .playlist,
            id: playlist.id,
            payload: payload,
            title: playlist.title,
            artist: "\(playlist.user.displayName) \(playlist.user.username)",
            timestampMillis: millis(date),
            changeKey: changeKey(playlist)
        )
    }

    static func user(_ user: User) -> LibraryRecord? {
        guard let payload = try? encoder.encode(user) else { return nil }
        return LibraryRecord(
            kind: .user,
            id: user.id,
            payload: payload,
            title: user.displayName,
            artist: user.username,
            timestampMillis: nil,
            changeKey: nil
        )
    }

    static func changeKey(_ playlist: Playlist) -> String {
        "\(millis(playlist.lastModified).map(String.init) ?? "")|\(playlist.totalTrackCount)"
    }

    static func classify(_ error: Error) -> LibraryRemoteError {
        if let error = error as? LibraryRemoteError { return error }
        if error is CancellationError { return .stop(until: nil) }
        if error is SoundCloudAuthHold { return .stop(until: nil) }
        if let gateway = error as? SoundCloudGatewayError {
            switch gateway {
            case .backgroundPaused(let until): return .stop(until: until)
            case .endpointCoolingDown(_, let until): return .stop(until: until)
            default: return .stop(until: nil)
            }
        }
        if let api = error as? APIError {
            switch api {
            case .rateLimited(let resetAt): return .stop(until: resetAt)
            case .temporarilyBlocked(let until, _): return .stop(until: until)
            case .unauthorized: return .stop(until: nil)
            case .notFound, .forbidden: return .gone
            default: return .transient
            }
        }
        return .transient
    }
}

actor SoundCloudLibraryPacer: LibraryPacer {
    static let minimumSpacing: TimeInterval = 1.5
    static let spacingJitter: TimeInterval = 1
    static let urgentSpacing: TimeInterval = 1.5
    static let hourlyLimit = 150
    static let dailyLikeListLimit = 300

    private let store: LibrarySQLiteStore
    private var recent: [Date] = []
    private var last: Date?
    private var lastUrgent: Date?

    init(store: LibrarySQLiteStore) {
        self.store = store
    }

    func admit(_ collection: LibraryCollection) async -> Bool {
        guard await Self.mayRun(), !Task.isCancelled else { return false }
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0) > 3600 }
        guard recent.count < Self.hourlyLimit else { return false }
        if collection.isLikeList {
            guard await takeLikeListBudget(now: now) else { return false }
        }
        let spacing = Self.minimumSpacing + Double.random(in: 0...Self.spacingJitter)
        if let last {
            let wait = spacing - Date().timeIntervalSince(last)
            if wait > 0 {
                self.last = last.addingTimeInterval(spacing)
                try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            }
        }
        guard await Self.mayRun(), !Task.isCancelled else { return false }
        last = max(last ?? Date(), Date())
        recent.append(Date())
        return true
    }

    func admit(_ collection: LibraryCollection, urgent: Bool) async -> Bool {
        guard urgent else { return await admit(collection) }
        guard await Self.mayRun(), !Task.isCancelled else { return false }
        let started = Date()
        recent.removeAll { started.timeIntervalSince($0) > 3600 }
        guard recent.count < Self.hourlyLimit else { return false }
        if collection.isLikeList {
            guard await takeLikeListBudget(now: Date()) else { return false }
        }
        if let lastUrgent {
            let wait = Self.urgentSpacing - Date().timeIntervalSince(lastUrgent)
            if wait > 0 {
                try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            }
        }
        guard !Task.isCancelled else { return false }
        lastUrgent = Date()
        recent.append(Date())
        return true
    }

    func retryDelay(attempt: Int) async {
        let seconds = min(60, 4 * pow(2, Double(attempt))) * Double.random(in: 0.75...1.25)
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func takeLikeListBudget(now: Date) async -> Bool {
        let day = Int64(now.timeIntervalSince1970 / 86_400)
        let parts = (await store.meta("budget.likeLists") ?? "").split(separator: "|")
        var used = 0
        if parts.count == 2, Int64(parts[0]) == day { used = Int(parts[1]) ?? 0 }
        guard used < Self.dailyLikeListLimit else { return false }
        await store.setMeta("\(day)|\(used + 1)", forKey: "budget.likeLists")
        return true
    }

    @MainActor
    private static func mayRun() -> Bool {
        SoundCloudGateway.shared.isApplicationForeground && SoundCloudAPI.shared.hasCredentials
    }
}

@MainActor
final class LibrarySyncEngine: ObservableObject, SoundCloudLibraryActionHook {
    static let shared = LibrarySyncEngine()

    @Published private(set) var progress = LibraryProgress.idle
    @Published private(set) var revision = 0
    @Published private(set) var lastChanged: Set<LibraryCollection> = []
    @Published private(set) var readyCollections: Set<LibraryCollection> = []
    @Published private(set) var backfillRole = LibraryBackfillRole.undecided
    @Published private(set) var hasFinishedFirstRun = false
    @Published private(set) var lastRunFailed = false
    @Published private(set) var itemCounts = LibraryItemCounts()

    let store: LibrarySQLiteStore
    private let core: LibrarySyncCore
    private let scheduler = WorkScheduler.shared
    private var activated = false
    private var runner: Task<Void, Never>?
    private var followUp: Task<Void, Never>?
    private var pendingActions: [UUID: Task<LibraryActionUndo?, Never>] = [:]
    private var resumeAt: Date?
    private var consecutiveParks = 0
    private var changeSinks: [String: @MainActor (Set<LibraryCollection>) -> Void] = [:]
    private let backfillPolicy = LibraryBackfillPolicy.standard
    private var activatedAt: Date?
    private var lease: LibraryBackfillLease?
    private var leaseAccount: String?
    private var localCandidate: LibraryBackfillCandidate?
    private var rosterPeers: [LibraryBackfillCandidate] = []
    private var writerPeers: [String: LibraryBackfillCandidate] = [:]
    private var vacantSince: Date?
    private var leaseChannelOpen = false
    private var lastManifestExport: Date?
    private var lastRunMode: LibrarySyncMode?
    private var priorityTask: Task<Void, Never>?
    private var priorityQueue: [LibraryCollection] = []
    private var userRequested: Set<LibraryCollection> = []
    private var likesUpFront = false

    static let tickInterval: Duration = .seconds(60)
    static let reconcileDelay: Duration = .seconds(5)

    init(store: LibrarySQLiteStore = .shared) {
        self.store = store
        core = LibrarySyncCore(
            store: store,
            remote: SoundCloudLibraryRemote(),
            pacer: SoundCloudLibraryPacer(store: store)
        )
    }

    var accountID: String? { SoundCloudAPI.credentials?.currentUser?.id }

    var writerID: String { DeviceClass.current.rawValue + "." + Self.installID }

    private static let installID: String = {
        let key = "red.forbes.sounding.library.installID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    func activate() {
        guard !activated else { return }
        activated = true
        activatedAt = Date()
        SoundCloudAPI.libraryActionHook = self
        Task {
            await core.setObservers(
                progress: { value in Task { @MainActor in LibrarySyncEngine.shared.receive(progress: value) } },
                change: { collections in Task { @MainActor in LibrarySyncEngine.shared.receive(changes: collections) } }
            )
        }
        refreshReadiness()
        scheduler.registerPeriodic(
            id: "library.db.refresh",
            scope: "library",
            interval: Self.tickInterval,
            condition: { SoundCloudGateway.shared.isApplicationForeground }
        ) { [weak self] in
            self?.kick()
        }
        kick()
    }

    func handleDidBecomeActive() {
        kick()
    }

    func registerChangeSink(id: String, _ sink: @escaping @MainActor (Set<LibraryCollection>) -> Void) {
        changeSinks[id] = sink
    }

    func unregisterChangeSink(id: String) {
        changeSinks[id] = nil
    }

    static func currentAccountID() async -> String? {
        await SoundCloudAPI.credentials?.waitForCurrentUser()?.id
    }

    func kick() {
        guard activated,
              runner == nil,
              priorityTask == nil,
              SoundCloudAPI.shared.hasCredentials,
              SoundCloudGateway.shared.isApplicationForeground else { return }
        let now = Date()
        if let resumeAt, resumeAt > now { return }
        if !likesUpFront, backfillRole == .backfiller {
            likesUpFront = true
            prioritise(.likes, byUser: false)
            return
        }
        let mode = syncMode(now: now)
        if mode == .follow, let lease = currentLease(), lease.isPaused(at: now) {
            if !hasFinishedFirstRun { hasFinishedFirstRun = true }
            return
        }
        lastRunMode = mode
        let core = self.core
        runner = Task { [weak self] in
            let outcome: LibraryRunOutcome = await SoundCloudRequestEnvironment.autonomous(lane: .metadata) {
                guard let account = await LibrarySyncEngine.currentAccountID() else {
                    return LibraryRunOutcome.accountMismatch
                }
                return await core.run(account: account, mode: mode)
            }
            self?.finish(outcome)
        }
    }

    private func finish(_ outcome: LibraryRunOutcome) {
        runner = nil
        if Task.isCancelled { return }
        hasFinishedFirstRun = true
        switch outcome {
        case .parked, .accountMismatch: lastRunFailed = true
        case .finished, .outOfBudget: lastRunFailed = false
        }
        defer {
            if lastRunMode == .follow, backfillRole == .backfiller { kick() }
        }
        switch outcome {
        case .parked(let until):
            consecutiveParks += 1
            let backoff = min(3600, 120 * pow(2, Double(min(consecutiveParks - 1, 5))))
            resumeAt = until ?? Date().addingTimeInterval(backoff)
            Log.library.info("Library sync parked; resumes from its cursor later")
        case .finished, .outOfBudget, .accountMismatch:
            consecutiveParks = 0
            resumeAt = nil
        }
    }

    func prioritise(_ collection: LibraryCollection, byUser: Bool = true) {
        guard collection.playlistID == nil,
              activated,
              SoundCloudAPI.shared.hasCredentials,
              SoundCloudGateway.shared.isApplicationForeground else { return }
        if let resumeAt, resumeAt > Date() { return }
        if collection == .likes { likesUpFront = true }
        if byUser { userRequested.insert(collection) }
        if !priorityQueue.contains(collection) { priorityQueue.append(collection) }
        startPriorityFill()
    }

    func prioritise(_ collections: [LibraryCollection]) {
        for collection in collections { prioritise(collection) }
        kick()
    }

    private func startPriorityFill() {
        guard priorityTask == nil, !priorityQueue.isEmpty else { return }
        let core = self.core
        priorityTask = Task { [weak self] in
            guard let account = await LibrarySyncEngine.currentAccountID() else {
                self?.endPriorityFill()
                return
            }
            while let collection = self?.nextPriority() {
                if await core.isFilled(collection) { continue }
                if let running = self?.runner {
                    running.cancel()
                    await running.value
                }
                let asked = self?.takeUserRequest(collection) ?? false
                let outcome: LibraryRunOutcome
                if asked {
                    outcome = await SoundCloudRequestEnvironment.userVisible {
                        await core.fill(collection, account: account)
                    }
                } else {
                    outcome = await SoundCloudRequestEnvironment.autonomous(lane: .metadata) {
                        await core.fill(collection, account: account)
                    }
                }
                if case .parked(let until) = outcome {
                    self?.parkPriority(until: until)
                    break
                }
            }
            self?.endPriorityFill()
        }
    }

    private func nextPriority() -> LibraryCollection? {
        guard !Task.isCancelled, !priorityQueue.isEmpty else { return nil }
        return priorityQueue.removeFirst()
    }

    private func takeUserRequest(_ collection: LibraryCollection) -> Bool {
        userRequested.remove(collection) != nil
    }

    private func parkPriority(until: Date?) {
        priorityQueue.removeAll()
        userRequested.removeAll()
        consecutiveParks += 1
        let backoff = min(3600, 120 * pow(2, Double(min(consecutiveParks - 1, 5))))
        resumeAt = until ?? Date().addingTimeInterval(backoff)
        Log.library.info("Library fill stopped by SoundCloud; resumes from its cursor later")
    }

    private func endPriorityFill() {
        priorityTask = nil
        refreshReadiness()
        if !priorityQueue.isEmpty {
            startPriorityFill()
        } else {
            kick()
        }
    }

    func handleSignOut() async {
        priorityTask?.cancel()
        priorityTask = nil
        priorityQueue = []
        likesUpFront = false
        runner?.cancel()
        runner = nil
        followUp?.cancel()
        followUp = nil
        resumeAt = nil
        resetBackfillElection()
        await store.wipe()
        progress = .idle
        lastChanged = Set(LibraryCollection.backfillOrder)
        readyCollections = []
        hasFinishedFirstRun = false
        lastRunFailed = false
        itemCounts = LibraryItemCounts()
        revision &+= 1
    }

    private func receive(progress value: LibraryProgress) {
        guard value != progress else { return }
        progress = value
        refreshReadiness()
    }

    private func receive(changes: Set<LibraryCollection>) {
        if lastChanged != changes { lastChanged = changes }
        revision &+= 1
        refreshReadiness()
        if changes.contains(.likes) {
            Task { await LikesSyncEngine.shared.didAdoptPeerLikes() }
        }
        for sink in changeSinks.values { sink(changes) }
    }

    var statusText: String? {
        if backfillRole == .follower, !progress.isBackfilling, !progress.isComplete,
           let lease = currentLease(), lease.isValid(at: Date()), lease.holderId != selfID {
            return "Your \(lease.deviceClass.displayName) is syncing your library…"
        }
        if progress.isBackfilling, let collection = progress.collection {
            let noun = Self.noun(for: collection)
            let fetched = progress.fetched.formatted()
            if let expected = progress.expected, expected >= progress.fetched {
                return "Syncing your library… \(fetched) of \(expected.formatted()) \(noun)"
            }
            return "Syncing your library… \(fetched) \(noun)"
        }
        if progress.isComplete { return "Library up to date" }
        return nil
    }

    var isBackfilling: Bool { progress.isBackfilling || priorityTask != nil }

    var itemsText: String? {
        if backfillRole == .follower, !itemCounts.isComplete,
           let lease = currentLease(), lease.isValid(at: Date()), lease.holderId != selfID {
            return "Your \(lease.deviceClass.displayName) is syncing your library…"
        }
        return itemCounts.label
    }

    func isAwaitingFirstSync(_ collection: LibraryCollection) -> Bool {
        SoundCloudAPI.shared.hasCredentials && !readyCollections.contains(collection)
    }

    func requestRefresh(_ collections: [LibraryCollection]) {
        let core = self.core
        Task {
            for collection in collections { await core.requestPatch(collection) }
            resumeAt = nil
            kick()
        }
    }

    private func refreshReadiness() {
        let store = self.store
        Task {
            var ready = Set<LibraryCollection>()
            var counts = LibraryItemCounts()
            for collection in LibraryCollection.backfillOrder {
                let cursor = await store.cursor(collection)
                let count = await store.count(collection)
                if cursor.hasCompletedOnce { ready.insert(collection) }
                counts.add(collection, cursor: cursor, count: count)
            }
            counts.isComplete = ready.count == LibraryCollection.backfillOrder.count
            if ready != readyCollections { readyCollections = ready }
            if counts != itemCounts { itemCounts = counts }
        }
    }

    private static func noun(for collection: LibraryCollection) -> String {
        switch collection {
        case .likes: return "likes"
        case .likedPlaylists, .ownPlaylists: return "playlists"
        case .followings: return "people you follow"
        case .followers: return "followers"
        case .reposts: return "reposts"
        case .ownTracks, .playlist: return "tracks"
        }
    }

    func begin(_ action: SoundCloudLibraryAction) -> UUID {
        let id = UUID()
        let local = Self.localAction(action)
        pendingActions[id] = Task { [core = self.core] in
            guard let local else { return nil }
            return await core.apply(local)
        }
        if local == nil, case .follow = action {
            Task { [core = self.core] in await core.requestPatch(.followings) }
        }
        return id
    }

    func finish(_ id: UUID, succeeded: Bool) {
        guard let task = pendingActions.removeValue(forKey: id) else { return }
        Task { [core = self.core] in
            guard let undo = await task.value else { return }
            await core.settle(undo, succeeded: succeeded)
            if !succeeded { await core.revert(undo) }
        }
        scheduleReconcile()
    }

    func reassertPending(_ collection: LibraryCollection) async {
        await core.reassertPending(collection)
    }

    func pendingMutations(_ collection: LibraryCollection) async -> [String: Bool] {
        await core.pendingMutations(collection)
    }

    private func scheduleReconcile() {
        followUp?.cancel()
        followUp = Task { [weak self] in
            try? await Task.sleep(for: Self.reconcileDelay)
            guard !Task.isCancelled else { return }
            self?.kick()
        }
    }

    private static func localAction(_ action: SoundCloudLibraryAction) -> LibraryLocalAction? {
        switch action {
        case .trackLike(let track, true):
            return LibraryRecords.track(track, at: Date()).map(LibraryLocalAction.like)
        case .trackLike(let track, false):
            return .unlike(trackID: track.id)
        case .follow(let userID, false):
            return .unfollow(userID: userID)
        case .follow(_, true):
            return nil
        case .playlistLike(let playlist, true):
            return LibraryRecords.playlist(playlist, at: Date()).map(LibraryLocalAction.likePlaylist)
        case .playlistLike(let playlist, false):
            return .unlikePlaylist(playlistID: playlist.id)
        case .trackRepost(let track, true):
            return LibraryRecords.track(track, at: Date()).map(LibraryLocalAction.repost)
        case .trackRepost(let track, false):
            return .unrepost(kind: .track, id: track.id)
        case .playlistRepost(let playlist, true):
            return LibraryRecords.playlist(playlist, at: Date()).map(LibraryLocalAction.repost)
        case .playlistRepost(let playlist, false):
            return .unrepost(kind: .playlist, id: playlist.id)
        case .createPlaylist(let playlist):
            return LibraryRecords.playlist(playlist, at: Date()).map(LibraryLocalAction.addOwnPlaylist)
        case .updatePlaylist(let playlist, let trackIDs):
            return LibraryRecords.playlist(playlist, at: nil).map { LibraryLocalAction.updateOwnPlaylist($0, trackOrder: trackIDs) }
        case .deletePlaylist(let playlist):
            return .removeOwnPlaylist(playlistID: playlist.id)
        }
    }

    func peerChunks(since millis: Int64?) async -> [LibraryChunk] {
        guard let account = accountID else { return [] }
        let manifest = await core.manifestChunk(account: account, writerId: writerID)
        let rows: [LibraryChunk]
        if let millis {
            rows = await core.chunks(account: account, writerId: writerID, cloud: false, since: millis, limit: nil)
        } else {
            rows = await core.allChunks(account: account, writerId: writerID)
        }
        var leaseChunks: [LibraryChunk] = []
        if let lease = currentLease(), lease.isValid(at: Date()) {
            leaseChunks.append(.leaseChunk(account: account, lease: lease))
        }
        return [manifest] + leaseChunks + rows
    }

    func cloudChunks(limit: Int) async -> [LibraryChunk] {
        guard let account = accountID else { return [] }
        let rows = await core.chunks(account: account, writerId: writerID, cloud: true, since: 0, limit: limit)
        guard !rows.isEmpty else { return [] }
        return [await core.manifestChunk(account: account, writerId: writerID)] + rows
    }

    func markCloudExported(_ chunks: [LibraryChunk]) async {
        if chunks.contains(where: \.isManifest) { lastManifestExport = Date() }
        await core.markCloudExported(chunks)
    }

    func markCloudPending(_ chunks: [LibraryChunk]) async {
        if chunks.contains(where: \.isManifest) { lastManifestExport = nil }
        for chunk in chunks where !chunk.isManifest && !chunk.isLease {
            guard let collection = LibraryCollection(key: chunk.collection) else { continue }
            await store.markCloudPending(collection, bucket: chunk.bucket)
        }
    }

    @discardableResult
    func adopt(_ chunks: [LibraryChunk], expectedAccount: String) async -> Int {
        if expectedAccount == accountID { observePeers(in: chunks, account: expectedAccount) }
        let bound = await store.boundAccount()
        if bound == nil {
            guard accountID == expectedAccount else { return 0 }
            _ = await store.bind(account: expectedAccount)
        } else if bound != expectedAccount {
            return 0
        }
        let applied = await core.adopt(chunks, expectedAccount: expectedAccount)
        if applied > 0 { kick() }
        return applied
    }
}

// MARK: - One backfiller per account

extension LibrarySyncEngine {
    private var selfID: String { localCandidate?.id ?? writerID }

    func leaseRound(local: LibraryBackfillCandidate, roster: [LibraryBackfillCandidate]) -> LibraryChunk? {
        leaseChannelOpen = true
        localCandidate = local
        rosterPeers = roster.filter { $0.id != local.id }
        guard activated, SoundCloudAPI.shared.hasCredentials, let account = accountID else { return nil }
        syncLeaseAccount(account)
        let now = Date()
        let decision = decide(now: now)
        let canWork = SoundCloudGateway.shared.isApplicationForeground
        switch decision {
        case .follow:
            setRole(.follower)
            return nil
        case .hold:
            setRole(.backfiller)
            return nil
        case .renew:
            setRole(.backfiller)
            guard canWork else { return nil }
        case .claim:
            guard canWork else {
                setRole(.follower)
                return nil
            }
        }
        let proposal = LibraryBackfillElection.lease(for: local, pausedUntil: sharedPause(now: now), now: now, policy: backfillPolicy)
        return LibraryChunk.leaseChunk(account: account, lease: proposal)
    }

    func leaseResult(proposal: LibraryChunk, saved: Bool, server: LibraryChunk?) {
        guard proposal.account == accountID else { return }
        if saved, let written = proposal.lease {
            lease = written
            vacantSince = nil
            setRole(.backfiller)
            return
        }
        if let current = server?.lease, server?.account == proposal.account {
            lease = current
        }
        let decision = decide(now: Date())
        setRole(decision == .claim ? .follower : decision.role)
    }

    func leaseRoundFailed() {
        leaseChannelOpen = false
    }

    func noteLeaseChannelClosed() {
        leaseChannelOpen = false
    }

    func cloudManifestIfDue() async -> LibraryChunk? {
        guard backfillRole == .backfiller, let account = accountID else { return nil }
        if let lastManifestExport, Date().timeIntervalSince(lastManifestExport) < backfillPolicy.manifestRefreshInterval {
            return nil
        }
        return await core.manifestChunk(account: account, writerId: writerID)
    }

    func noteManifestExported() {
        lastManifestExport = Date()
    }

    func syncMode(now: Date) -> LibrarySyncMode {
        if let account = accountID { syncLeaseAccount(account) }
        if !leaseChannelOpen, deadlinePassed(now: now) {
            backfillRole = decide(now: now).role
        }
        return backfillRole == .backfiller ? .backfill : .follow
    }

    func currentLease() -> LibraryBackfillLease? {
        guard let leaseAccount, leaseAccount == accountID else { return nil }
        return lease
    }

    func observePeers(in chunks: [LibraryChunk], account: String) {
        syncLeaseAccount(account)
        var observed = currentLease()
        for chunk in chunks where chunk.account == account {
            if chunk.isLease, let incoming = chunk.lease {
                observed = LibraryBackfillElection.newer(observed, incoming)
            } else if chunk.isManifest, chunk.writerId != writerID,
                      let peer = LibraryBackfillElection.writerCandidate(writerId: chunk.writerId, seenAtMillis: chunk.updatedAtMillis) {
                if let known = writerPeers[peer.id], known.lastSeen >= peer.lastSeen { continue }
                writerPeers[peer.id] = peer
            }
        }
        guard observed != lease else { return }
        lease = observed
        if let observed, observed.isValid(at: Date()), observed.holderId != selfID {
            setRole(.follower)
        }
    }

    func resetBackfillElection() {
        lease = nil
        leaseAccount = nil
        writerPeers = [:]
        vacantSince = nil
        lastManifestExport = nil
        backfillRole = .undecided
        activatedAt = activated ? Date() : nil
    }

    private func decide(now: Date) -> LibraryBackfillDecision {
        let me = localCandidate ?? LibraryBackfillCandidate(
            id: selfID,
            deviceClass: DeviceClass.current,
            isOnPower: DeviceClass.current == .tv,
            lastSeen: now
        )
        let current = currentLease()
        if current?.isValid(at: now) == true {
            vacantSince = nil
        } else if vacantSince == nil {
            vacantSince = now
        }
        return LibraryBackfillElection.decide(
            me: me,
            peers: rosterPeers + Array(writerPeers.values),
            lease: current,
            pausedUntil: sharedPause(now: now),
            vacantSince: vacantSince,
            now: now,
            policy: backfillPolicy
        )
    }

    private func deadlinePassed(now: Date) -> Bool {
        guard let activatedAt else { return false }
        return now.timeIntervalSince(activatedAt) >= backfillPolicy.decisionDeadline
    }

    private func sharedPause(now: Date) -> Date? {
        guard backfillRole == .backfiller, let resumeAt, resumeAt > now else { return nil }
        return resumeAt
    }

    private func syncLeaseAccount(_ account: String) {
        guard leaseAccount != account else { return }
        let wasActive = activatedAt
        resetBackfillElection()
        activatedAt = wasActive
        leaseAccount = account
    }

    private func setRole(_ role: LibraryBackfillRole) {
        guard role != backfillRole else { return }
        let wasBackfiller = backfillRole == .backfiller
        backfillRole = role
        if wasBackfiller, role != .backfiller, lastRunMode == .backfill {
            runner?.cancel()
        }
        if role == .backfiller {
            Log.library.info("This device now backfills the library for the account")
            kick()
        }
    }
}

extension SoundCloudRequestEnvironment {
    static func userVisible<T: Sendable>(
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await $intent.withValue(.userInitiated) {
            try await operation()
        }
    }
}

struct LibraryItemCounts: Equatable, Sendable {
    static let followerCap = 2_000

    var stored = 0
    var expected = 0
    var isComplete = false

    mutating func add(_ collection: LibraryCollection, cursor: LibraryCursor, count: Int) {
        stored += count
        if cursor.hasCompletedOnce, cursor.phase != .walking {
            expected += count
        } else if let total = cursor.expectedTotal {
            let capped = collection == .followers ? min(total, Self.followerCap) : total
            expected += max(capped, count)
        } else {
            expected += count
        }
    }

    var label: String? {
        if isComplete { return "Library: \(stored.formatted()) items" }
        guard stored > 0 || expected > 0 else { return nil }
        guard expected > stored else { return "Library: \(stored.formatted()) items" }
        return "Library: \(stored.formatted()) of \(expected.formatted()) items"
    }
}

enum LibraryDB {
    struct TrackPage: Sendable {
        var tracks: [Track]
        var likedAt: [String: Date]
        var rowCount: Int
    }

    static var store: LibrarySQLiteStore { LibrarySQLiteStore.shared }

    static func count(_ collection: LibraryCollection) async -> Int {
        await store.count(collection)
    }

    static func playlistCount() async -> Int {
        await store.count(.ownPlaylists) + store.count(.likedPlaylists)
    }

    static func tracks(_ collection: LibraryCollection, offset: Int, limit: Int) async -> TrackPage {
        let rows = await store.page(collection, offset: offset, limit: limit)
        return await Task.detached(priority: .userInitiated) {
            let decoder = LikesSyncEngine.makeDecoder()
            var tracks: [Track] = []
            var likedAt: [String: Date] = [:]
            for row in rows where row.record.kind == .track {
                guard let track = try? decoder.decode(Track.self, from: row.record.payload) else { continue }
                tracks.append(track)
                if let millis = row.record.timestampMillis {
                    likedAt[track.id] = Date(timeIntervalSince1970: Double(millis) / 1000)
                }
            }
            return TrackPage(tracks: tracks, likedAt: likedAt, rowCount: rows.count)
        }.value
    }

    static func cachedTracks(ids: [String]) async -> [String: Track] {
        guard !ids.isEmpty else { return [:] }
        let records = await store.cachedTracks(ids: ids)
        guard !records.isEmpty else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            let decoder = LikesSyncEngine.makeDecoder()
            var tracks: [String: Track] = [:]
            for (id, record) in records {
                guard let track = try? decoder.decode(Track.self, from: record.payload) else { continue }
                tracks[id] = track
            }
            return tracks
        }.value
    }

    static func playlists(_ collection: LibraryCollection, offset: Int, limit: Int) async -> (playlists: [Playlist], rowCount: Int) {
        let rows = await store.page(collection, offset: offset, limit: limit)
        let decoded = await Task.detached(priority: .userInitiated) {
            let decoder = LikesSyncEngine.makeDecoder()
            return rows.filter { $0.record.kind == .playlist }.compactMap { try? decoder.decode(Playlist.self, from: $0.record.payload) }
        }.value
        return (decoded, rows.count)
    }

    static func allPlaylists(offset: Int, limit: Int) async -> (playlists: [Playlist], rowCount: Int) {
        let own = await store.count(.ownPlaylists)
        if offset < own {
            let first = await playlists(.ownPlaylists, offset: offset, limit: limit)
            let remaining = limit - first.rowCount
            guard remaining > 0 else { return first }
            let second = await playlists(.likedPlaylists, offset: 0, limit: remaining)
            let ownIDs = Set(first.playlists.map(\.id))
            return (first.playlists + second.playlists.filter { !ownIDs.contains($0.id) }, first.rowCount + second.rowCount)
        }
        return await playlists(.likedPlaylists, offset: offset - own, limit: limit)
    }

    static func users(_ collection: LibraryCollection, offset: Int, limit: Int) async -> (users: [User], rowCount: Int) {
        let rows = await store.page(collection, offset: offset, limit: limit)
        let decoded = await Task.detached(priority: .userInitiated) {
            let decoder = LikesSyncEngine.makeDecoder()
            return rows.filter { $0.record.kind == .user }.compactMap { try? decoder.decode(User.self, from: $0.record.payload) }
        }.value
        return (decoded, rows.count)
    }

    static func playlistTracks(id: String) async -> [Track]? {
        let collection = LibraryCollection.playlist(id)
        guard await store.cursor(collection).hasCompletedOnce else { return nil }
        return await tracks(collection, offset: 0, limit: 10_000).tracks
    }

    @MainActor
    static func trackSource(
        _ collection: LibraryCollection,
        pageSize: Int = 100,
        onLikedAt: (@MainActor ([String: Date]) -> Void)? = nil
    ) -> PagedSource<Track> {
        func load(_ offset: Int) async -> PagedChunk<Track> {
            let total = await count(collection)
            let limit = offset == 0 ? pageSize : max(pageSize, total - offset)
            let page = await tracks(collection, offset: offset, limit: limit)
            onLikedAt?(page.likedAt)
            let end = offset + page.rowCount
            return PagedChunk(items: page.tracks, next: page.rowCount > 0 && end < total ? .offset(end) : nil, total: total)
        }
        return PagedSource(
            first: { await load(0) },
            next: { cursor in
                guard case .offset(let offset) = cursor else { return PagedChunk(items: []) }
                return await load(offset)
            },
            fillsEagerly: true
        )
    }

    @MainActor
    static func playlistSource(_ collection: LibraryCollection? = nil, pageSize: Int = 100) -> PagedSource<Playlist> {
        func load(_ offset: Int) async -> PagedChunk<Playlist> {
            let page: (playlists: [Playlist], rowCount: Int)
            let total: Int
            if let collection {
                total = await count(collection)
                page = await playlists(collection, offset: offset, limit: offset == 0 ? pageSize : max(pageSize, total - offset))
            } else {
                total = await playlistCount()
                page = await allPlaylists(offset: offset, limit: offset == 0 ? pageSize : max(pageSize, total - offset))
            }
            let end = offset + page.rowCount
            return PagedChunk(items: page.playlists, next: page.rowCount > 0 && end < total ? .offset(end) : nil, total: total)
        }
        return PagedSource(
            first: { await load(0) },
            next: { cursor in
                guard case .offset(let offset) = cursor else { return PagedChunk(items: []) }
                return await load(offset)
            },
            fillsEagerly: true
        )
    }

    @MainActor
    static func userSource(_ collection: LibraryCollection, pageSize: Int = 100) -> PagedSource<User> {
        func load(_ offset: Int) async -> PagedChunk<User> {
            let total = await count(collection)
            let page = await users(collection, offset: offset, limit: offset == 0 ? pageSize : max(pageSize, total - offset))
            let end = offset + page.rowCount
            return PagedChunk(items: page.users, next: page.rowCount > 0 && end < total ? .offset(end) : nil, total: total)
        }
        return PagedSource(
            first: { await load(0) },
            next: { cursor in
                guard case .offset(let offset) = cursor else { return PagedChunk(items: []) }
                return await load(offset)
            },
            fillsEagerly: true
        )
    }

    static func isCollectionReady(_ collection: LibraryCollection) async -> Bool {
        await store.cursor(collection).hasCompletedOnce
    }

    static func identityLinks() async -> [LibraryIdentityLink] {
        await store.identityLinks()
    }

    static func saveIdentityLinks(_ links: [LibraryIdentityLink], removing removed: [(kind: LibraryIdentityLink.Kind, localKey: String)] = []) async {
        await store.saveIdentityLinks(links, removing: removed)
    }
}
