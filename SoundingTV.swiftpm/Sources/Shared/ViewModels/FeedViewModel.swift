import Foundation
import os

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var items: [FeedActivity] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var loadedOnce = false
    @Published var error: Error?

    private let api = SoundCloudAPI.shared
    private let cache = LibraryCache.shared
    private var cursor = PageCursor<FeedActivity>()
    private var lastLoaded: Date?
    private var isFetching = false
    private var didHydrateCache = false

    private let staleAfter: TimeInterval = 5 * 60
    private static let cacheSection = "feed.activities"

    func loadContentIfNeeded() async {
        await hydrateCacheIfNeeded()
        guard !loadedOnce else { return }
        await loadContent()
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
        items = []
        error = nil
        lastLoaded = nil
        loadedOnce = false
        cursor.reset()
    }

    func loadContent() async {
        #if DEBUG && os(tvOS)
        if VisualFixtures.isEnabled {
            items = VisualFixtures.feed
            loadedOnce = true
            error = nil
            lastLoaded = Date()
            return
        }
        #endif

        await hydrateCacheIfNeeded()
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        loadedOnce = true
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await api.getFeed(limit: 20)
            items = page.collection
            cursor.advance(to: page)
            error = nil
            lastLoaded = Date()
            await persistCache(page.collection)
        } catch {
            if Self.isCancellation(error) {
                loadedOnce = false
                return
            }
            self.error = error
        }
    }

    /// Keeps the most recently seen stream available while the network wakes
    /// up.  This is deliberately cache-first: a transient offline response
    /// must never replace a useful stream with an empty/error screen.
    private func hydrateCacheIfNeeded() async {
        guard !didHydrateCache else { return }
        didHydrateCache = true

        let rows = await cache.loadSection(Self.cacheSection)
        let decoder = JSONDecoder()
        let cached = rows.compactMap { try? decoder.decode(FeedActivity.self, from: $0.payload) }
        guard !cached.isEmpty else { return }

        items = cached
        loadedOnce = true
        error = nil
        lastLoaded = .distantPast
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
        guard !isLoading, !isLoadingMore, cursor.canLoadMore, let page = cursor.lastPage else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let next = try await api.getNextPage(page)
            cursor.advance(to: next)
            items.appendUnique(contentsOf: next.collection)
        } catch {
            Log.ui.error("Feed load-more error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let apiError = error as? APIError, case .networkError(let underlying) = apiError {
            return isCancellation(underlying)
        }
        return false
    }
}

// MARK: - Conservative account activity polling

/// A local inbox item synthesized from authenticated SoundCloud surfaces.
/// SoundCloud does not expose a public push-notification API, so these events
/// are deliberately cursor-backed and never intercept SoundCloud web push.
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
    private static let feedInterval: TimeInterval = 10 * 60
    private static let followerInterval: TimeInterval = 60 * 60
    private static let messageInterval: TimeInterval = 5 * 60

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

    /// Returns only newly synthesized events, making platform delivery a
    /// simple, idempotent operation. The first successful request for each
    /// source establishes a baseline and intentionally emits nothing.
    func poll(accountID: String, now: Date = Date(), force: Bool = false) async -> [SoundCloudInboxEvent] {
        activate(accountID: accountID)
        guard snapshot.circuitOpenUntil.map({ $0 <= now }) ?? true else { return [] }

        let currentUser = SoundCloudAPI.credentials?.currentUser
        guard currentUser?.id == accountID else { return [] }

        var candidates = [SoundCloudInboxEvent]()
        var dueSources = 0
        var successfulSources = 0

        if force || isDue(snapshot.lastFeedPoll, interval: Self.feedInterval, now: now) {
            dueSources += 1
            do {
                let page = try await api.getFeed(limit: 50)
                candidates.append(contentsOf: ingestFeed(page.collection))
                snapshot.lastFeedPoll = now
                successfulSources += 1
            } catch {
                Log.api.error("[ActivityPoller] Feed poll failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if force || isDue(snapshot.lastFollowerPoll, interval: Self.followerInterval, now: now) {
            dueSources += 1
            do {
                let page = try await api.getUserFollowers(userId: accountID, limit: 100)
                candidates.append(contentsOf: ingestFollowers(page.collection, currentUserID: accountID, now: now))
                snapshot.lastFollowerPoll = now
                successfulSources += 1
            } catch {
                Log.api.error("[ActivityPoller] Follower poll failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if force || isDue(snapshot.lastMessagePoll, interval: Self.messageInterval, now: now) {
            dueSources += 1
            do {
                let page = try await api.getConversations(limit: 50)
                candidates.append(contentsOf: ingestMessages(page.collection, currentUserID: accountID))
                snapshot.lastMessagePoll = now
                successfulSources += 1
            } catch {
                Log.api.error("[ActivityPoller] Message poll failed: \(error.localizedDescription, privacy: .public)")
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

    private func ingestMessages(
        _ conversations: [SoundCloudConversation], currentUserID: String
    ) -> [SoundCloudInboxEvent] {
        let messages = conversations.compactMap { conversation -> (SoundCloudConversation, SoundCloudDirectMessage)? in
            guard conversation.unreadCount > 0, let message = conversation.latestMessage else { return nil }
            return (conversation, message)
        }
        let prior = snapshot.messageIDs
        snapshot.messageIDs = Set(messages.map { $0.1.id })
        guard snapshot.messageBaselineComplete else {
            snapshot.messageBaselineComplete = true
            return []
        }
        return messages.compactMap { conversation, message in
            guard !prior.contains(message.id), message.sender?.id != currentUserID else { return nil }
            let sender = message.sender?.username
                ?? conversation.participants.first(where: { $0.id != currentUserID })?.username
                ?? "SoundCloud user"
            return SoundCloudInboxEvent(
                id: "message:\(message.id)", kind: .message,
                title: sender,
                body: message.body.isEmpty ? "Sent you a message" : message.body,
                date: message.createdAt,
                destination: SoundCloudAPI.webInboxURL,
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
