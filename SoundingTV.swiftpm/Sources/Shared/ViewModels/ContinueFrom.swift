import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class ContinueFrom: ObservableObject {
    static let shared = ContinueFrom()

    struct Offer: Equatable, Identifiable {
        let session: ContinueSession
        let position: TimeInterval

        var id: String { session.dismissalKey }

        var deviceName: String {
            session.deviceName.isEmpty ? session.deviceClass.displayName : session.deviceName
        }

        var title: String { "Continue from \(deviceName)" }

        var detail: String {
            session.title.isEmpty
                ? ContinueSessions.clock(position)
                : "\(session.title) \u{00B7} \(ContinueSessions.clock(position))"
        }

        var miniCaption: String {
            let verb = session.isPlaying ? "Playing on" : "Paused on"
            return "\(verb) \(deviceName) \u{00B7} \(ContinueSessions.clock(position))"
        }

        func heroCaption(now: Date = Date()) -> String {
            let age = max(0, now.timeIntervalSince(session.updatedAt))
            guard age >= 60 else { return "From \(deviceName) \u{00B7} Just now" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "From \(deviceName) \u{00B7} \(formatter.localizedString(for: session.updatedAt, relativeTo: now))"
        }

        var progress: Double? {
            guard session.duration > 0 else { return nil }
            return min(1, max(0, position / session.duration))
        }
    }

    @Published private(set) var offer: Offer?
    @Published private(set) var loading: Offer?
    @Published private(set) var expandRequest = 0
    @Published private(set) var isAdvertising = false
    @Published private(set) var advertisedRevision = 0

    private static let heartbeat: Duration = .seconds(30)
    private static let coalesce: Duration = .seconds(1)
    private static let dismissedLimit = 24
    private static let nearbyLimit = 8
    private static let lookupLimit = 50
    private static let launchGrace: Duration = .seconds(5)

    private let settings: SettingsStore
    private let api: SoundCloudAPI
    private let defaults: UserDefaults
    private weak var player: PlayerService?
    private var cancellables = Set<AnyCancellable>()
    private var playerObservation = Set<AnyCancellable>()
    private var heartbeatTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var nearby: [String: ContinueSession] = [:]
    private var relays: [String: @MainActor (ContinueSession) -> Void] = [:]
    private var sessionID = UUID().uuidString
    private var sessionQueue: Set<String> = []
    private var sessionCollection: String?
    private var loadTask: Task<Void, Never>?
    private var acceptedThrough: Date?
    private var activeThrough: Date?
    private var isLaunchSettled = false
    private var launchGraceTask: Task<Void, Never>?
    private lazy var deviceName = LinkPeerIdentity.localName

    init(settings: SettingsStore = .shared, api: SoundCloudAPI = .shared, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.api = api
        self.defaults = defaults
        settings.$continueSessions
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleReconcile() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AccountDataVault.didForgetAccountData)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.forget() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Self.didBecomeActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshOffer() }
            .store(in: &cancellables)
    }

    private static var didBecomeActive: Notification.Name {
        #if canImport(UIKit)
        UIApplication.didBecomeActiveNotification
        #else
        NSApplication.didBecomeActiveNotification
        #endif
    }

    private var accountID: String? { SoundCloudAPI.credentials?.currentUser?.id }

    private var deviceID: String { LinkPeerIdentity.localDeviceId(defaults: defaults) }

    private var isSuppressed: Bool {
        #if DEBUG
        return VisualFixtures.isEnabled
        #else
        return false
        #endif
    }

    // MARK: - Publishing

    func attach(to player: PlayerService) {
        guard self.player !== player else { return }
        self.player = player
        playerObservation.removeAll()
        player.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] playing in self?.playingDidChange(playing) }
            .store(in: &playerObservation)
        player.$currentTrack
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] track in self?.trackDidChange(track) }
            .store(in: &playerObservation)
        player.$hasResolvedLaunchRestore
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.settleLaunch() }
            .store(in: &playerObservation)
        startLaunchGrace()
        refreshOffer()
    }

    private func startLaunchGrace() {
        guard !isLaunchSettled, launchGraceTask == nil else { return }
        launchGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.launchGrace)
            guard !Task.isCancelled else { return }
            self?.settleLaunch()
        }
    }

    private func settleLaunch() {
        guard !isLaunchSettled else { return }
        isLaunchSettled = true
        launchGraceTask?.cancel()
        launchGraceTask = nil
        refreshOffer()
    }

    private func trackDidChange(_ track: Track?) {
        updateAdvertising(hasTrack: track != nil)
        guard let track, let player else { return }
        settleLaunch()
        let collection = player.activeCollectionId ?? player.queueSource?.id
        if !sessionQueue.contains(track.id) || collection != sessionCollection {
            sessionID = UUID().uuidString
            sessionCollection = collection
        }
        sessionQueue = Set(player.queue.map(\.id))
        if player.isPlaying { schedulePublish() }
    }

    private func playingDidChange(_ playing: Bool) {
        activeThrough = Date()
        schedulePublish()
        if playing {
            offer = nil
            startHeartbeat()
        } else {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            refreshOffer(playing: false)
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeat)
                guard !Task.isCancelled, let self, self.player?.isPlaying == true else { return }
                self.publishNow()
            }
        }
    }

    private func schedulePublish() {
        publishTask?.cancel()
        publishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.coalesce)
            guard !Task.isCancelled, let self else { return }
            self.publishTask = nil
            self.publishNow()
        }
    }

    private func publishNow() {
        guard !isSuppressed, let accountID, let session = liveSession(accountID: accountID) else { return }
        saveOwn(session, accountID: accountID)
        settings.setContinueSessions(ContinueSessions.merging([[session], settings.continueSessions], now: Date()))
        advertisedRevision &+= 1
        for relay in relays.values { relay(session) }
    }

    private func liveSession(accountID: String) -> ContinueSession? {
        guard let player, let track = player.currentTrack,
              !player.isPlayingSoundCloudPreview, !track.isPreviewOnly else { return nil }
        let source = player.queueSource
        return ContinueSession(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceClass: DeviceClass.current,
            account: AccountDataVault.storageSuffix(for: accountID),
            sessionID: sessionID,
            trackID: track.id,
            title: track.title,
            artist: track.publisher?.artist ?? track.user.displayName,
            artworkURL: track.artworkURL,
            duration: track.duration > 0 ? track.duration : player.duration,
            position: player.currentTime,
            queueTrackIDs: player.queue.map(\.id),
            queueIndex: player.currentIndex,
            collectionID: player.activeCollectionId,
            sourceID: source?.id,
            sourceKind: source?.kind.rawValue,
            sourceTitle: source?.title,
            isAutoMix: player.isAutoMixEnabled,
            isPlaying: player.isPlaying,
            updatedAt: Date()
        )
    }

    private func updateAdvertising(hasTrack: Bool? = nil) {
        let advertising = !isSuppressed && accountID != nil && (hasTrack ?? (player?.currentTrack != nil))
        if advertising != isAdvertising { isAdvertising = advertising }
    }

    // MARK: - Link

    var latestOwn: ContinueSession? {
        guard let accountID else { return nil }
        return ownSession(accountID)
    }

    func registerRelay(id: String, _ send: @escaping @MainActor (ContinueSession) -> Void) {
        relays[id] = send
    }

    func unregisterRelay(id: String) {
        relays[id] = nil
    }

    func adoptNearby(_ data: Data) {
        guard let session = ContinueSession.decode(data), let accountID,
              session.account == AccountDataVault.storageSuffix(for: accountID),
              session.deviceID != deviceID else { return }
        if let existing = nearby[session.deviceID], !session.isNewer(than: existing) { return }
        nearby[session.deviceID] = session
        if nearby.count > Self.nearbyLimit {
            let kept = ContinueSessions.merging([Array(nearby.values)], now: Date(), limit: Self.nearbyLimit)
            nearby = Dictionary(uniqueKeysWithValues: kept.map { ($0.deviceID, $0) })
        }
        refreshOffer()
    }

    // MARK: - Offer

    func refreshOffer(playing: Bool? = nil) {
        updateAdvertising()
        guard !isSuppressed, isLaunchSettled, let accountID, (playing ?? player?.isPlaying) != true else {
            if offer != nil { offer = nil }
            return
        }
        let now = Date()
        let candidates = ContinueSessions.merging([settings.continueSessions, Array(nearby.values)], now: now)
        let next = ContinueSessions.offer(
            in: candidates,
            ownDeviceID: deviceID,
            account: AccountDataVault.storageSuffix(for: accountID),
            ownLatest: [ownSession(accountID)?.updatedAt, acceptedThrough, activeThrough].compactMap { $0 }.max(),
            dismissed: dismissed(accountID),
            now: now
        )
        guard next != offer?.session else { return }
        offer = next.map { Offer(session: $0, position: $0.position(at: now)) }
    }

    func dismiss(_ offer: Offer) {
        guard let accountID else {
            self.offer = nil
            return
        }
        var keys = dismissedList(accountID)
        keys.removeAll { $0 == offer.id }
        keys.append(offer.id)
        defaults.set(Array(keys.suffix(Self.dismissedLimit)), forKey: dismissedKey(accountID))
        if self.offer?.id == offer.id { self.offer = nil }
        refreshOffer()
    }

    func accept(_ offer: Offer, play: Bool = false, expand: Bool = false) {
        acceptedThrough = max(acceptedThrough ?? .distantPast, offer.session.updatedAt)
        loading = offer
        dismiss(offer)
        load(offer.session, position: offer.session.position(at: Date()), play: play, expand: expand)
    }

    func load(_ session: ContinueSession, position: TimeInterval, play: Bool, expand: Bool = false) {
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            await self?.perform(session, position: position, play: play, expand: expand)
            guard !Task.isCancelled else { return }
            self?.loading = nil
            self?.loadTask = nil
        }
    }

    private func perform(_ session: ContinueSession, position: TimeInterval, play: Bool, expand: Bool) async {
        let player = self.player ?? PlayerService.shared
        let byID = await resolve(session)
        guard !Task.isCancelled else { return }
        guard let current = byID[session.trackID] else {
            Log.playback.info("continue skipped: the track from \(session.deviceClass.rawValue, privacy: .public) is not available here")
            return
        }
        let queue = session.queueTrackIDs.compactMap { byID[$0] }
        let index = queue.firstIndex { $0.id == current.id } ?? 0
        await player.adoptOutputSession(
            track: current,
            queue: queue.isEmpty ? [current] : queue,
            index: index,
            position: position,
            autoplay: play
        )
        if let kind = session.sourceKind.flatMap(PlaybackQueueSource.Kind.init(rawValue:)),
           let title = session.sourceTitle, !title.isEmpty {
            player.setQueueSource(PlaybackQueueSource(id: session.sourceID, kind: kind, title: title))
        }
        if session.isAutoMix, !player.isAutoMixEnabled {
            player.setAutomaticMixEnabled(true)
        }
        if expand { expandRequest &+= 1 }
    }

    private func resolve(_ session: ContinueSession) async -> [String: Track] {
        let ids = session.queueTrackIDs.isEmpty ? [session.trackID] : session.queueTrackIDs
        var byID: [String: Track] = [:]
        for track in RecentlyPlayed.shared.tracks where ids.contains(track.id) { byID[track.id] = track }
        let localIDs = Set(ids.filter(LocalTrackFile.isLocalTrackID))
        if !localIDs.isEmpty {
            let library = LocalMusicLibrary.shared.allTracks + RemoteLocalMusic.shared.allTracks
            for track in library where localIDs.contains(track.id) && byID[track.id] == nil {
                byID[track.id] = track
            }
        }
        let remote = ids.filter { byID[$0] == nil && !LocalTrackFile.isLocalTrackID($0) }
        if !remote.isEmpty {
            let cached = await LibraryDB.cachedTracks(ids: remote)
            byID.merge(cached) { current, _ in current }
        }
        guard !Task.isCancelled else { return byID }
        let missing = Self.lookupOrder(ids, current: session.trackID).filter {
            byID[$0] == nil && !LocalTrackFile.isLocalTrackID($0)
        }
        if !missing.isEmpty, api.hasCredentials {
            let wanted = Array(missing.prefix(Self.lookupLimit))
            do {
                let fetched = try await api.getTracks(ids: wanted)
                for track in fetched where byID[track.id] == nil { byID[track.id] = track }
            } catch {
                Log.playback.info("continue lookup failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        return byID
    }

    private static func lookupOrder(_ ids: [String], current: String) -> [String] {
        guard let index = ids.firstIndex(of: current) else { return [current] + ids }
        return Array(ids[index...]) + ids[..<index].reversed()
    }

    // MARK: - Handoff

    func configure(_ activity: NSUserActivity) {
        guard let accountID, let session = liveSession(accountID: accountID) else { return }
        activity.title = session.title
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        var info: [String: Any] = [
            "trackId": session.trackID,
            "position": session.position,
        ]
        if let data = session.encoded() { info["session"] = data }
        if let collectionID = session.collectionID { info["collectionId"] = collectionID }
        if let sourceID = session.sourceID { info["sourceId"] = sourceID }
        if let sourceKind = session.sourceKind { info["sourceKind"] = sourceKind }
        if let sourceTitle = session.sourceTitle { info["sourceTitle"] = sourceTitle }
        activity.userInfo = info
        activity.requiredUserInfoKeys = ["trackId", "position"]
    }

    func continueActivity(_ activity: NSUserActivity) {
        let info = activity.userInfo ?? [:]
        let session: ContinueSession?
        if let data = info["session"] as? Data, let decoded = ContinueSession.decode(data) {
            session = decoded
        } else if let trackID = info["trackId"] as? String {
            session = ContinueSession(
                deviceID: "",
                deviceName: "",
                deviceClass: .phone,
                account: "",
                sessionID: UUID().uuidString,
                trackID: trackID,
                title: "",
                artist: "",
                duration: 0,
                position: (info["position"] as? TimeInterval) ?? 0,
                queueTrackIDs: [trackID],
                queueIndex: 0,
                collectionID: info["collectionId"] as? String,
                sourceID: info["sourceId"] as? String,
                sourceKind: info["sourceKind"] as? String,
                sourceTitle: info["sourceTitle"] as? String,
                isPlaying: false,
                updatedAt: Date()
            )
        } else {
            session = nil
        }
        guard let session, accountID != nil else { return }
        acceptedThrough = max(acceptedThrough ?? .distantPast, session.updatedAt)
        if let offer, offer.session.deviceID == session.deviceID { dismiss(offer) }
        load(session, position: session.position(at: Date()), play: false)
    }

    // MARK: - Storage

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
        if let accountID, let own = ownSession(accountID) {
            let synced = settings.continueSessions
            let merged = ContinueSessions.merging([synced, [own]], now: Date())
            if merged != synced { settings.setContinueSessions(merged) }
        }
        refreshOffer()
    }

    private func forget() {
        nearby = [:]
        offer = nil
        loading = nil
        sessionQueue = []
        sessionCollection = nil
        sessionID = UUID().uuidString
        acceptedThrough = nil
        activeThrough = nil
        loadTask?.cancel()
        updateAdvertising()
    }

    private func ownKey(_ accountID: String) -> String {
        "red.forbes.sounding.continue.own.\(AccountDataVault.storageSuffix(for: accountID))"
    }

    private func dismissedKey(_ accountID: String) -> String {
        "red.forbes.sounding.continue.dismissed.\(AccountDataVault.storageSuffix(for: accountID))"
    }

    private func ownSession(_ accountID: String) -> ContinueSession? {
        defaults.data(forKey: ownKey(accountID)).flatMap(ContinueSession.decode)
    }

    private func saveOwn(_ session: ContinueSession, accountID: String) {
        guard let data = session.encoded() else { return }
        defaults.set(data, forKey: ownKey(accountID))
    }

    private func dismissedList(_ accountID: String) -> [String] {
        defaults.stringArray(forKey: dismissedKey(accountID)) ?? []
    }

    private func dismissed(_ accountID: String) -> Set<String> {
        Set(dismissedList(accountID))
    }
}
