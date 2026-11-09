import Foundation
import Combine
import os

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var loadedOnce = false

    let pager: Paginator<FeedActivity>

    var items: [FeedActivity] { pager.items }
    var isLoadingMore: Bool { pager.isLoadingMore }
    var error: Error? { pager.firstError }

    private let api = SoundCloudAPI.shared
    private let cache = LibraryCache.shared
    private var lastLoaded: Date?
    private var isFetching = false
    private var didHydrateCache = false

    private let staleAfter: TimeInterval = 5 * 60
    private var loadedWithConfirmedAccount = false
    private var accountObservation: AnyCancellable?
    private var signOutObservation: AnyCancellable?
    private var pagerObservation: AnyCancellable?
    private var inflight: Task<Void, Never>?
    private var inflightToken: UUID?
    private static let cacheSection = "feed.activities"

    init() {
        pager = Paginator(soundCloudSource: PagedSource(first: { PagedChunk(items: []) }, next: { _ in PagedChunk(items: []) }))
        pager.setSource(PagedSource(
            first: { [weak self] in
                guard let self else { return PagedChunk(items: []) }
                return try await self.fetchFirstPage()
            },
            next: { [weak self] cursor in
                guard let self else { return PagedChunk(items: []) }
                guard case .url(let url) = cursor else { return try await self.fetchFirstPage() }
                let page = try await self.api.getPage(FeedActivity.self, from: url)
                return PagedChunk(items: page.collection, next: page.nextHref.map { .url($0) })
            }
        ))
        pagerObservation = pager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        hydrateCacheImmediately()
        accountObservation = SoundCloudCredentialSource.shared.$state
            .map { $0.isAuthenticated && $0.sessionHealth == .healthy && $0.currentUser != nil }
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self, !self.loadedWithConfirmedAccount else { return }
                Task {
                    await self.inflight?.value
                    self.lastLoaded = nil
                    await self.loadContent()
                }
            }
        signOutObservation = SoundCloudCredentialSource.shared.$state
            .map(\.isSignedOut)
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self else { return }
                self.loadedWithConfirmedAccount = false
                self.reset()
            }
    }

    func loadContentIfNeeded() async {
        await refreshIfStale()
    }

    func refreshIfStale() async {
        await hydrateCacheIfNeeded()
        guard let lastLoaded else {
            await loadContent()
            return
        }
        if Date().timeIntervalSince(lastLoaded) > staleAfter {
            await loadContent()
        }
    }

    func reset() {
        inflight?.cancel()
        inflight = nil
        pager.reset()
        lastLoaded = nil
        loadedOnce = false
    }

    func loadContent() async {
        #if DEBUG
        if VisualFixtures.isEnabled {
            pager.prime(items: VisualFixtures.feed, cursor: nil)
            loadedOnce = true
            lastLoaded = Date()
            return
        }
        #endif

        await hydrateCacheIfNeeded()
        if let inflight {
            await inflight.value
            return
        }
        let token = UUID()
        inflightToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad()
            if self.inflightToken == token { self.inflight = nil }
        }
        inflight = task
        await task.value
    }

    private func performLoad() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        loadedOnce = true
        isLoading = true
        defer { isLoading = false }

        await pager.reload()

        if pager.firstError == nil, pager.hasLoadedFirst, !Task.isCancelled {
            lastLoaded = Date()
            loadedWithConfirmedAccount = SoundCloudCredentialSource.shared.hasConfirmedAccount
        }
    }

    private func fetchFirstPage() async throws -> PagedChunk<FeedActivity> {
        let page = try await api.getFeed(limit: 20)
        if page.collection.isEmpty, !pager.items.isEmpty {
            return PagedChunk(items: pager.items, next: pager.cursor)
        }
        #if os(iOS) || os(macOS)
        ScoutMonitor.shared.observe(feed: page.collection)
        #endif
        await persistCache(page.collection)
        await cache.markSectionProgress(Self.cacheSection, nextHref: page.nextHref, completed: page.nextHref == nil)
        return PagedChunk(items: page.collection, next: page.nextHref.map { .url($0) })
    }

    private func hydrateCacheIfNeeded() async {
        hydrateCacheImmediately()
    }

    private func hydrateCacheImmediately() {
        guard !didHydrateCache else { return }
        didHydrateCache = true

        let rows = cache.loadSection(Self.cacheSection, limit: 20)
        let decoder = JSONDecoder()
        let cached = rows.compactMap { try? decoder.decode(FeedActivity.self, from: $0.payload) }
        guard !cached.isEmpty else { return }

        pager.prime(items: cached, cursor: nil)
        loadedOnce = true
        lastLoaded = .distantPast

        Task { [weak self] in
            guard let self else { return }
            let next = await self.cache.sectionState(Self.cacheSection).nextHref
            guard let next, self.pager.cursor == nil, !self.pager.isLoadingFirst,
                  self.pager.items.count == cached.count else { return }
            self.pager.prime(items: cached, cursor: .url(next))
        }
    }

    private func persistCache(_ activities: [FeedActivity]) async {
        let encoder = JSONEncoder()
        let rows = activities.compactMap { activity -> LibraryCache.WriteRow? in
            guard let payload = try? encoder.encode(activity) else { return nil }
            return LibraryCache.WriteRow(id: activity.id, payload: payload)
        }
        await cache.replaceSection(Self.cacheSection, rows: rows)
    }

    func loadMore() async {
        guard !isLoading else { return }
        await pager.loadMore()
    }

    func requestMore() {
        guard !isLoading else { return }
        pager.requestMore()
    }
}

// MARK: - Conservative account activity polling

struct SoundCloudInboxEvent: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case feed
        case follower
        case message
    }

    let id: String
    let kind: Kind
    let title: String
    let body: String
    let date: Date
    let destination: URL?
    var readAt: Date?
}

@MainActor
final class SoundCloudActivityPoller: ObservableObject {
    static let shared = SoundCloudActivityPoller()

    @Published private(set) var inbox: [SoundCloudInboxEvent] = []
    @Published private(set) var lastSuccessfulPoll: Date?
    @Published private(set) var circuitOpenUntil: Date?

    private struct Snapshot: Codable {
        var feedBaselineComplete = false
        var followerBaselineComplete = false
        var messageBaselineComplete = false
        var feedIDs = Set<String>()
        var followerIDs = Set<String>()
        var messageIDs = Set<String>()
        var deliveredIDs = [String]()
        var inbox = [SoundCloudInboxEvent]()
        var lastFeedPoll: Date?
        var lastFollowerPoll: Date?
        var lastMessagePoll: Date?
        var lastSuccessfulPoll: Date?
        var consecutiveFailures = 0
        var circuitOpenUntil: Date?
    }

    private let api = SoundCloudAPI.shared
    private var activeAccountID: String?
    private var snapshot = Snapshot()

    private static let purpose = "soundcloud.activity-poller.v1"
    private static let feedInterval: TimeInterval = 60 * 60
    private static let followerInterval: TimeInterval = 12 * 60 * 60

    var unreadCount: Int { inbox.lazy.filter { $0.readAt == nil }.count }

    func unreadCount(kind: SoundCloudInboxEvent.Kind) -> Int {
        inbox.lazy.filter { $0.kind == kind && $0.readAt == nil }.count
    }

    func markAllRead(kind: SoundCloudInboxEvent.Kind, at date: Date = Date()) {
        guard activeAccountID != nil else { return }
        snapshot.inbox = snapshot.inbox.map { event in
            guard event.kind == kind, event.readAt == nil else { return event }
            var copy = event
            copy.readAt = date
            return copy
        }
        persist()
        publishSnapshot()
    }

    func poll(accountID: String, now: Date = Date(), force: Bool = false) async -> [SoundCloudInboxEvent] {
        await SoundCloudRequestEnvironment.autonomous(lane: .feed) {
            await self.performPoll(accountID: accountID, now: now, force: force)
        }
    }

    private func performPoll(accountID: String, now: Date, force: Bool) async -> [SoundCloudInboxEvent] {
        activate(accountID: accountID)
        guard snapshot.circuitOpenUntil.map({ $0 <= now }) ?? true else { return [] }

        let currentUser = SoundCloudAPI.credentials?.currentUser
        guard currentUser?.id == accountID else { return [] }

        var candidates = [SoundCloudInboxEvent]()
        var dueSources = 0
        var successfulSources = 0

        if force || isDue(snapshot.lastFeedPoll, interval: Self.feedInterval, now: now) {
            dueSources += 1
            snapshot.lastFeedPoll = now
            do {
                let page = try await api.getFeed(limit: 50)
                candidates.append(contentsOf: ingestFeed(page.collection))
                #if os(iOS) || os(macOS)
                ScoutMonitor.shared.observe(feed: page.collection, now: now)
                #endif
                successfulSources += 1
            } catch {
                Log.api.error("[ActivityPoller] Feed poll failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if force || isDue(snapshot.lastFollowerPoll, interval: Self.followerInterval, now: now) {
            dueSources += 1
            snapshot.lastFollowerPoll = now
            do {
                let page = try await api.getUserFollowers(userId: accountID, limit: 100)
                candidates.append(contentsOf: ingestFollowers(page.collection, currentUserID: accountID, now: now))
                successfulSources += 1
            } catch {
                Log.api.error("[ActivityPoller] Follower poll failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard dueSources > 0 else { return [] }
        if successfulSources == 0 {
            recordFailure(now: now)
            persist()
            publishSnapshot()
            return []
        }

        snapshot.consecutiveFailures = 0
        snapshot.circuitOpenUntil = nil
        snapshot.lastSuccessfulPoll = now

        let delivered = deduplicate(candidates)
            .sorted { $0.date < $1.date }
            .suffix(12)
        let newEvents = Array(delivered)
        if !newEvents.isEmpty {
            snapshot.inbox = Array((Array(newEvents.reversed()) + snapshot.inbox).prefix(200))
        }
        persist()
        publishSnapshot()
        return newEvents
    }

    func markAllRead(at date: Date = Date()) {
        guard activeAccountID != nil else { return }
        snapshot.inbox = snapshot.inbox.map { event in
            var copy = event
            if copy.readAt == nil { copy.readAt = date }
            return copy
        }
        persist()
        publishSnapshot()
    }

    func markRead(id: String, at date: Date = Date()) {
        guard activeAccountID != nil,
              let index = snapshot.inbox.firstIndex(where: { $0.id == id }),
              snapshot.inbox[index].readAt == nil else { return }
        snapshot.inbox[index].readAt = date
        persist()
        publishSnapshot()
    }

    private func ingestFeed(_ activities: [FeedActivity]) -> [SoundCloudInboxEvent] {
        let prior = snapshot.feedIDs
        snapshot.feedIDs = Set(activities.prefix(200).map(\.id))
        guard snapshot.feedBaselineComplete else {
            snapshot.feedBaselineComplete = true
            return []
        }
        return activities.filter { !prior.contains($0.id) }.map { activity in
            let item = activity.track?.title ?? activity.playlist?.title ?? "New activity"
            let action = activity.isRepost ? "reposted" : "shared"
            return SoundCloudInboxEvent(
                id: "feed:\(activity.id)", kind: .feed,
                title: activity.actor.displayName,
                body: "\(action.capitalized) \(item)",
                date: activity.createdAt,
                destination: activity.track?.permalinkURL ?? activity.playlist?.permalinkURL,
                readAt: nil
            )
        }
    }

    private func ingestFollowers(_ followers: [User], currentUserID: String, now: Date) -> [SoundCloudInboxEvent] {
        let prior = snapshot.followerIDs
        snapshot.followerIDs = Set(followers.prefix(200).map(\.id))
        guard snapshot.followerBaselineComplete else {
            snapshot.followerBaselineComplete = true
            return []
        }
        return followers.filter { !prior.contains($0.id) && $0.id != currentUserID }.map { follower in
            SoundCloudInboxEvent(
                id: "follower:\(follower.id)", kind: .follower,
                title: "New follower",
                body: "\(follower.displayName) followed you",
                date: now,
                destination: follower.permalinkURL,
                readAt: nil
            )
        }
    }

    private func deduplicate(_ events: [SoundCloudInboxEvent]) -> [SoundCloudInboxEvent] {
        var delivered = Set(snapshot.deliveredIDs)
        let fresh = events.filter { delivered.insert($0.id).inserted }
        snapshot.deliveredIDs = Array(delivered).sorted().suffix(500).map { $0 }
        return fresh
    }

    private func recordFailure(now: Date) {
        snapshot.consecutiveFailures += 1
        let exponent = min(snapshot.consecutiveFailures - 1, 7)
        let delay = min(6 * 60 * 60, 60 * pow(2, Double(exponent)))
        snapshot.circuitOpenUntil = now.addingTimeInterval(delay)
    }

    private func isDue(_ date: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let date else { return true }
        return now.timeIntervalSince(date) >= interval
    }

    private func activate(accountID: String) {
        guard activeAccountID != accountID else { return }
        activeAccountID = accountID
        snapshot = Self.load(accountID: accountID) ?? Snapshot()
        publishSnapshot()
    }

    private func publishSnapshot() {
        inbox = snapshot.inbox
        lastSuccessfulPoll = snapshot.lastSuccessfulPoll
        circuitOpenUntil = snapshot.circuitOpenUntil
    }

    private func persist() {
        guard let accountID = activeAccountID,
              let data = try? JSONEncoder().encode(snapshot),
              let sealed = AccountDataVault.seal(data, accountID: accountID, purpose: Self.purpose) else { return }
        UserDefaults.standard.set(sealed, forKey: Self.storageKey(accountID: accountID))
    }

    private static func load(accountID: String) -> Snapshot? {
        guard let sealed = UserDefaults.standard.data(forKey: storageKey(accountID: accountID)),
              let data = AccountDataVault.open(sealed, accountID: accountID, purpose: purpose) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func storageKey(accountID: String) -> String {
        "red.forbes.sounding.activity-poller.v1.\(AccountDataVault.storageSuffix(for: accountID))"
    }
}
