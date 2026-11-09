import Foundation
import Combine
import UserNotifications
import os
#if os(iOS)
import BackgroundTasks
#endif

@MainActor
final class ScoutMonitor: ObservableObject {
    static let shared = ScoutMonitor()

    @Published private(set) var artists: [ScoutArtist] = []
    @Published private(set) var isEnabled = true
    @Published private(set) var lastCheck: Date?
    @Published var isPriming = false

    private struct Stored: Codable {
        var artists: [ScoutArtist] = []
        var isEnabled = true
        var ledger = ScoutLedger()
    }

    private var stored = Stored()
    private var accountID: String?
    private var isChecking = false
    private var accountObservation: AnyCancellable?

    static let checkInterval: TimeInterval = 30 * 60

    private init() {
        accountObservation = SoundCloudCredentialSource.shared.$state
            .map { $0.currentUser?.id }
            .removeDuplicates()
            .sink { [weak self] id in self?.activate(accountID: id) }
    }

    var hasActiveScouts: Bool { isEnabled && artists.contains(where: \.isEnabled) }

    func isScouting(_ artistID: String) -> Bool {
        artists.contains { $0.id == artistID && $0.isEnabled }
    }

    func toggle(_ user: User, isFollowed: Bool? = nil) {
        if let index = stored.artists.firstIndex(where: { $0.id == user.id }) {
            if stored.artists[index].isEnabled {
                stored.artists.remove(at: index)
            } else {
                stored.artists[index].isEnabled = true
            }
        } else {
            stored.artists.append(ScoutArtist(
                id: user.id,
                name: user.displayName,
                permalinkURL: user.permalinkURL,
                avatarURL: user.avatarURL,
                isEnabled: true,
                isFollowed: isFollowed ?? false,
                addedAt: Date()
            ))
            stored.artists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !stored.isEnabled { stored.isEnabled = true }
            Task { await ScoutNotifications.shared.primeIfNeeded() }
        }
        save()
    }

    func setEnabled(_ enabled: Bool, artistID: String) {
        guard let index = stored.artists.firstIndex(where: { $0.id == artistID }) else { return }
        stored.artists[index].isEnabled = enabled
        save()
    }

    func remove(artistIDs: [String]) {
        stored.artists.removeAll { artistIDs.contains($0.id) }
        save()
    }

    func setMasterEnabled(_ enabled: Bool) {
        stored.isEnabled = enabled
        save()
        if enabled { Task { await ScoutNotifications.shared.primeIfNeeded() } }
    }

    func observe(feed activities: [FeedActivity], now: Date = Date()) {
        guard accountID != nil, hasActiveScouts else { return }
        let result = Self.result(from: activities)
        stored.ledger.lastFeedSeenAt = now
        markFollowed(result.followedArtistIDs)
        let alerts = ScoutDetector.detect(result.posts, scouts: stored.artists, ledger: &stored.ledger, now: now)
        save()
        Task { await ScoutNotifications.shared.deliver(alerts) }
    }

    @discardableResult
    func check(now: Date = Date()) async -> [ScoutAlert] {
        guard let accountID, hasActiveScouts, !isChecking,
              SoundCloudAPI.credentials?.currentUser?.id == accountID else { return [] }
        isChecking = true
        defer { isChecking = false }
        let scouts = stored.artists
        let ledger = stored.ledger
        let names = Dictionary(scouts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let fetch = Self.liveFetch(names: names)
        let outcome = await SoundCloudRequestEnvironment.systemInitiated {
            await SoundCloudRequestEnvironment.$lane.withValue(.feed) {
                await NetworkActivityLog.$feature.withValue(.scout) {
                    await ScoutRunner.run(scouts: scouts, ledger: ledger, now: now, fetch: fetch)
                }
            }
        }
        guard self.accountID == accountID else { return [] }
        stored.ledger = outcome.ledger
        markFollowed(outcome.followedArtistIDs)
        save()
        if outcome.requestsMade > 0 {
            Log.api.info("[Scout] checked with \(outcome.requestsMade) requests, \(outcome.alerts.count) alerts")
        }
        await ScoutNotifications.shared.deliver(outcome.alerts)
        return outcome.alerts
    }

    nonisolated private static func liveFetch(names: [String: String]) -> ScoutRunner.Fetcher {
        { step in
            switch step {
            case .feed:
                let page = try await SoundCloudAPI.shared.getFeed(limit: 50)
                return result(from: page.collection)
            case .artist(let id):
                let page = try await SoundCloudAPI.shared.getUserTracks(userId: id, limit: 10)
                return ScoutFetchResult(posts: page.collection.map(post(from:)))
            case .search(let id):
                guard let name = names[id] else { return ScoutFetchResult(posts: []) }
                let page = try await SoundCloudAPI.shared.searchTracks(query: name, limit: 20)
                return ScoutFetchResult(posts: [], candidates: page.collection.map(candidate(from:)))
            }
        }
    }

    nonisolated static func candidate(from track: Track) -> ScoutCandidate {
        ScoutCandidate(
            itemID: track.id,
            title: track.title,
            description: track.description,
            uploaderID: track.user.id,
            uploaderName: track.user.displayName,
            duration: track.duration,
            postedAt: track.createdAt
        )
    }

    nonisolated static func result(from activities: [FeedActivity]) -> ScoutFetchResult {
        var posts: [ScoutPost] = []
        var followed = Set<String>()
        for activity in activities {
            followed.insert(activity.actor.id)
            if let track = activity.track {
                posts.append(post(from: track))
            } else if let playlist = activity.playlist {
                posts.append(ScoutPost(
                    kind: .playlist,
                    itemID: playlist.id,
                    artistID: playlist.user.id,
                    artistName: playlist.user.displayName,
                    title: playlist.title,
                    duration: playlist.duration,
                    postedAt: playlist.createdAt
                ))
            }
        }
        return ScoutFetchResult(posts: posts, followedArtistIDs: followed)
    }

    nonisolated static func post(from track: Track) -> ScoutPost {
        ScoutPost(
            kind: .track,
            itemID: track.id,
            artistID: track.user.id,
            artistName: track.user.displayName,
            title: track.title,
            duration: track.duration,
            postedAt: track.createdAt
        )
    }

    private func markFollowed(_ ids: Set<String>) {
        for index in stored.artists.indices where ids.contains(stored.artists[index].id) {
            stored.artists[index].isFollowed = true
        }
    }

    private func activate(accountID: String?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        stored = accountID.flatMap(Self.load) ?? Stored()
        publish()
    }

    private func save() {
        publish()
        guard let accountID, let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey(accountID: accountID))
    }

    private func publish() {
        artists = stored.artists
        isEnabled = stored.isEnabled
        lastCheck = stored.ledger.lastFeedSeenAt
    }

    private static func load(accountID: String) -> Stored? {
        guard let data = UserDefaults.standard.data(forKey: storageKey(accountID: accountID)) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func storageKey(accountID: String) -> String {
        "red.forbes.sounding.scout.v1.\(AccountDataVault.storageSuffix(for: accountID))"
    }
}

@MainActor
final class ScoutNotifications: ObservableObject {
    static let shared = ScoutNotifications()

    @Published private(set) var status: UNAuthorizationStatus = .notDetermined

    nonisolated static let kindKey = "scoutKind"
    nonisolated static let itemKey = "scoutItemID"
    nonisolated static let threadPrefix = "scout."

    private let center = UNUserNotificationCenter.current()

    func refresh() async {
        status = await center.notificationSettings().authorizationStatus
    }

    var isAllowed: Bool {
        #if os(iOS)
        if status == .ephemeral { return true }
        #endif
        return status == .authorized || status == .provisional
    }

    func primeIfNeeded() async {
        await refresh()
        if status == .notDetermined { ScoutMonitor.shared.isPriming = true }
    }

    func requestAuthorization() async {
        ScoutMonitor.shared.isPriming = false
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
    }

    func deliver(_ alerts: [ScoutAlert]) async {
        guard !alerts.isEmpty else { return }
        await refresh()
        guard isAllowed else { return }
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            if let reason = alert.reason { content.subtitle = reason }
            content.sound = .default
            content.threadIdentifier = Self.threadPrefix + alert.artistID
            content.userInfo = [Self.kindKey: alert.kind.rawValue, Self.itemKey: alert.itemID]
            let request = UNNotificationRequest(identifier: "scout.\(alert.postID)", content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    nonisolated static func isScout(_ userInfo: [AnyHashable: Any]) -> Bool {
        target(from: userInfo) != nil
    }

    nonisolated static func target(from userInfo: [AnyHashable: Any]) -> (kind: ScoutPost.Kind, id: String)? {
        guard let raw = userInfo[kindKey] as? String,
              let kind = ScoutPost.Kind(rawValue: raw),
              let id = userInfo[itemKey] as? String, !id.isEmpty else { return nil }
        return (kind, id)
    }

    static func open(_ userInfo: [AnyHashable: Any]) async {
        guard let target = target(from: userInfo) else { return }
        await open(kind: target.kind, id: target.id)
    }

    static func open(kind: ScoutPost.Kind, id: String) async {
        do {
            switch kind {
            case .track: try await IntentPlayback.playTrack(id: id)
            case .playlist: try await IntentPlayback.playPlaylist(id: id)
            }
        } catch {
            Log.api.error("[Scout] couldn't play from notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#if os(iOS)
enum ScoutBackgroundRefresh {
    static let identifier = "red.forbes.sounding.scout.refresh"

    @MainActor
    static func schedule() {
        guard ScoutMonitor.shared.hasActiveScouts else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(ScoutMonitor.checkInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.api.info("[Scout] background refresh not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func run() async {
        await MainActor.run { schedule() }
        _ = await ScoutMonitor.shared.check()
    }
}
#endif

#if os(macOS)
enum ScoutMacSchedule {
    static let jobID = "scout.check"

    @MainActor
    static func start() {
        WorkScheduler.shared.registerPeriodic(
            id: jobID,
            scope: "scout",
            initialDelay: .seconds(60),
            interval: .seconds(Int(ScoutMonitor.checkInterval)),
            jitterFraction: 0.1
        ) {
            _ = await ScoutMonitor.shared.check()
        }
    }

    @MainActor
    static func stop() {
        WorkScheduler.shared.cancelPeriodic(id: jobID)
    }
}
#endif
