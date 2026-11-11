import Foundation
import Network
import Combine
import SwiftUI

@MainActor
final class CompanionTelemetry: ObservableObject {
    @Published fileprivate(set) var playback: PlaybackStatePayload?
    @Published fileprivate(set) var djState: DJStatePayload?
    @Published fileprivate(set) var autoMixLive: AutoMixLiveState?
    @Published fileprivate(set) var anchorDate: Date?
    @Published fileprivate(set) var isLive = false

    var isDJControlLive: Bool { isLive && playback?.isDJEngineLive == true }

    var isPlaying: Bool { isLive && playback?.isPlaying == true }

    var playbackModes: PlaybackModesPayload? { playback?.modes }

    func estimatedPosition(at date: Date = Date()) -> TimeInterval {
        guard let playback else { return 0 }
        guard isLive, let anchorDate else { return playback.positionSeconds }
        return playback.estimatedPosition(elapsed: date.timeIntervalSince(anchorDate))
    }
}

private extension PlaybackStatePayload {
    func frozen(at position: Double) -> PlaybackStatePayload {
        PlaybackStatePayload(
            isPlaying: isPlaying, positionSeconds: position, durationSeconds: durationSeconds,
            trackId: trackId, title: title, artist: artist, artworkURL: artworkURL,
            isDJEngineLive: isDJEngineLive, revision: revision, issuedAtMillis: issuedAtMillis,
            signature: signature, rate: rate, modes: modes, volume: volume, sleepTimer: sleepTimer
        )
    }
}

@MainActor
final class CompanionDecksFeed: ObservableObject {
    @Published fileprivate(set) var state: DJStatePayload?
    @Published fileprivate(set) var receivedAt: Date?
    @Published fileprivate(set) var decksOpen: Bool?
    fileprivate(set) var isAttached = false
    fileprivate var telemetryPublishedAt = Date.distantPast

    var supportsRemoteMixing: Bool { decksOpen != nil }

    fileprivate func reset() {
        state = nil
        receivedAt = nil
        decksOpen = nil
    }

    fileprivate func shouldPublishTelemetry(_ next: DJStatePayload, replacing current: DJStatePayload?, at now: Date) -> Bool {
        guard isAttached, let current else { return true }
        if now.timeIntervalSince(telemetryPublishedAt) >= 1 { return true }
        return current.isEnabled != next.isEnabled
            || current.isEngineLive != next.isEngineLive
            || current.isAutoMixEnabled != next.isAutoMixEnabled
            || current.automaticMix != next.automaticMix
            || current.plan != next.plan
            || Self.deckShape(current.deckA) != Self.deckShape(next.deckA)
            || Self.deckShape(current.deckB) != Self.deckShape(next.deckB)
    }

    private struct DeckShape: Equatable {
        let trackId: String?
        let isPlaying: Bool
        let role: DJDeckRole?
    }

    private static func deckShape(_ deck: DJDeckStatePayload) -> DeckShape {
        DeckShape(trackId: deck.trackId, isPlaying: deck.isPlaying, role: deck.role)
    }
}

struct CompanionTelemetryReader<Content: View>: View {
    @ObservedObject private var telemetry: CompanionTelemetry
    private let content: (CompanionTelemetry) -> Content

    init(_ telemetry: CompanionTelemetry, @ViewBuilder content: @escaping (CompanionTelemetry) -> Content) {
        _telemetry = ObservedObject(wrappedValue: telemetry)
        self.content = content
    }

    var body: some View { content(telemetry) }
}

struct OutputModesReader<Content: View>: View {
    @ObservedObject private var router: OutputRouter
    @ObservedObject private var client: CompanionClient
    @ObservedObject private var telemetry: CompanionTelemetry
    private let content: (OutputRouter) -> Content

    init(_ router: OutputRouter, @ViewBuilder content: @escaping (OutputRouter) -> Content) {
        _router = ObservedObject(wrappedValue: router)
        _client = ObservedObject(wrappedValue: router.client)
        _telemetry = ObservedObject(wrappedValue: router.client.telemetry)
        self.content = content
    }

    var body: some View { content(router) }
}

@MainActor
final class CompanionClient: ObservableObject {
    private lazy var volumeChannel: RemoteVolumeChannel = {
        let channel = RemoteVolumeChannel { [weak self] level in self?.transmitVolume(level) }
        channel.willChange = { [weak self] in self?.objectWillChange.send() }
        return channel
    }()

    private let synchronization: SynchronizationCoordinator
    private let gateway: SynchronizationGateway
    private let likes: LikesSyncEngine
    private let library: LibraryCache
    private let downloads: DownloadManager

    private actor SnapshotWriter {
        private var writtenGeneration: UInt64 = 0

        func write(_ snapshot: PersistedSnapshot, generation: UInt64, key: String) {
            guard generation > writtenGeneration,
                  let data = try? JSONEncoder().encode(snapshot) else { return }
            writtenGeneration = generation
            UserDefaults.standard.set(data, forKey: key)
        }

        func remove(generation: UInt64, key: String) {
            guard generation > writtenGeneration else { return }
            writtenGeneration = generation
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private struct PersistedSnapshot: Codable, Sendable {
        let sessionId: String
        let tracks: [QueueTrack]
        let currentIndex: Int
        let isPlaying: Bool
        var playingNextCount: Int? = nil
        let playback: PlaybackStatePayload?
        let djState: DJStatePayload?
        let savedAt: Date
    }

    private static let snapshotDefaultsKey = "red.forbes.sounding.remoteNowPlaying.v1"
    private static let snapshotPersistInterval: Duration = .seconds(5)
    private static let inactiveGrace: Duration = .seconds(30)
    private let snapshotWriter = SnapshotWriter()
    private var snapshotGeneration: UInt64 = 0

    enum State: Equatable {
        case unlinked
        case idle
        case searching
        case connecting
        case connected
        case failed(CompanionFailure)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var tracks: [QueueTrack] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var playingNextCount = 0
    private var reportsPlayingNext = false
    @Published private(set) var isPlaying = false
    @Published private(set) var rejection: String?
    @Published private(set) var hasSnapshot = false
    @Published private(set) var queueSource: PlaybackQueueSource?
    @Published private(set) var authHandoffRequest: AuthHandoffRequest?
    @Published private(set) var peerNeedsSignIn = false
    @Published private(set) var isRequestingPeerSignIn = false

    let telemetry = CompanionTelemetry()
    let decks = CompanionDecksFeed()

    private let playbackConfirmations = PlaybackConfirmationTracker()

    fileprivate var controlSequence: Int64 = 0

    private struct PendingContinuousControl {
        let type: MessageType
        let deck: ControlDeck
        let parameter: ControlParameter
        let value: Double
        let value2: Double
    }

    private var pendingContinuousControls: [String: PendingContinuousControl] = [:]

    private enum PendingCommand {
        case queue(MessageType, fromIndex: Int, toIndex: Int, trackId: String)
        case control(MessageType, deck: ControlDeck, parameter: ControlParameter, value: Double, value2: Double)
    }

    private var pendingCommands = CompanionCommandOutbox<PendingCommand>()
    private nonisolated(unsafe) var pendingCommandsExpiry: Task<Void, Never>?
    private var lastHeartbeatAt: Date?
    private var connectedAt: Date?
    #if os(iOS)
    private var backgroundCommandTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    private var cueReplayGuard = ReplayGuard()
    private var cuePushHighWaterMark: Int64 = 0
    private var libraryPushHighWaterMark: Int64?
    private var libraryPushMarks: [String: Int64] = [:]
    private let synchronizationID = "companion.client.\(UUID().uuidString)"

    private nonisolated(unsafe) var browser: NWBrowser?
    private var channel: CompanionChannel?
    private var connection: NWConnection? { channel?.connection }

    private var contentEndpoint: NWEndpoint?
    private var contentEndpointsByDeviceToken: [String: NWEndpoint] = [:]
    private var companionServiceName: String?
    private let localContentServer: PeerContentServer
    private nonisolated(unsafe) var searchTimeout: Task<Void, Never>?
    private nonisolated(unsafe) var rejectionTimeout: Task<Void, Never>?
    private nonisolated(unsafe) var connectTimeout: Task<Void, Never>?
    private nonisolated(unsafe) var reconnectTask: Task<Void, Never>?
    private nonisolated(unsafe) var inactiveGraceTask: Task<Void, Never>?
    private nonisolated(unsafe) var persistTask: Task<Void, Never>?
    private nonisolated(unsafe) var peerSignInTimeout: Task<Void, Never>?
    private var lastDeviceStatusMillis: Int64 = 0
    private var lastContinueSessionMillis: Int64 = 0

    private static let initialReconnectDelay: TimeInterval = 5
    private static let maximumReconnectDelay: TimeInterval = 30

    private var reconnectDelay = CompanionClient.initialReconnectDelay

    private var lastWaitingError: NWError?

    private nonisolated(unsafe) var livenessWatchdog: Task<Void, Never>?

    private var lastFrameAt = Date.distantPast

    @Published fileprivate var link: LinkedCompanionStore.LinkRecord?
    @Published fileprivate(set) var links: [LinkedCompanionStore.LinkRecord] = []
    @Published private(set) var advertisedSessionIds: Set<String> = []
    @Published private(set) var needsSignInSessionIds: Set<String> = []
    private var advertisedEndpoints: [String: NWEndpoint] = [:]
    private var couriersInFlight: Set<String> = []
    private var probesInFlight: Set<String> = []
    private var pairingSubscription: AnyCancellable?
    private var likesRevisionSubscription: AnyCancellable?
    private var localMusicSubscription: AnyCancellable?
    private var backgroundSubscription: AnyCancellable?
    private var appliedPlaybackRevision = 0
    private var appliedDJRevision = 0
    private var appliedRevision = -1
    private var observedPlayback: PlaybackStatePayload?
    private var observedAt = Date.distantPast
    private(set) var intents = RemotePlaybackIntents()
    private var intentSettleTask: Task<Void, Never>?
    #if DEBUG
    private var isFixture = false
    private var fixtureRevision = 0
    private var fixtureVolume: Double = 0.8
    private var fixtureSleepTimer: SleepTimerStatus?
    private var fixtureShuffle = false
    private var fixtureRepeat: RemoteRepeatMode = .off
    #endif

    var isLinked: Bool { link != nil }
    var linkedClass: DeviceClass { link?.peerClass ?? .tv }
    var linkedName: String { link?.peerName ?? DeviceClass.tv.displayName }
    var activeSessionId: String? { link?.sessionId }

    var linkedOutputDevice: OutputDevice? {
        link.flatMap(Self.outputDevice(for:))
    }

    var linkedOutputDevices: [OutputDevice] {
        links.compactMap(Self.outputDevice(for:))
    }

    static func outputDevice(for link: LinkedCompanionStore.LinkRecord) -> OutputDevice? {
        guard OutputDevice.deviceClassesThatAcceptOutput.contains(link.peerClass) else { return nil }
        return .linked(sessionId: link.sessionId, name: link.peerName, deviceClass: link.peerClass)
    }

    func isActive(_ sessionId: String) -> Bool { link?.sessionId == sessionId }

    func status(of sessionId: String) -> LinkStatus {
        if isActive(sessionId) {
            switch state {
            case .connected: return peerNeedsSignIn ? .needsSignIn : .connected
            case .searching, .connecting: return .connecting
            case .failed(let failure): return .unreachable(failure)
            case .idle, .unlinked: return advertisedSessionIds.contains(sessionId) ? .available : .unreachable(.notFound)
            }
        }
        guard advertisedSessionIds.contains(sessionId) else { return .unreachable(.notFound) }
        return needsSignInSessionIds.contains(sessionId) ? .needsSignIn : .available
    }

    init(
        synchronization: SynchronizationCoordinator = .shared,
        gateway: SynchronizationGateway = .shared,
        likes: LikesSyncEngine = .shared,
        library: LibraryCache = .shared,
        downloads: DownloadManager = .shared
    ) {
        self.synchronization = synchronization
        self.gateway = gateway
        self.likes = likes
        self.library = library
        self.downloads = downloads
        self.localContentServer = PeerContentServer(resolveFile: { trackID in
            await downloads.peerContentSource(forTrackId: trackID)
        })
        self.localContentServer.serveGrants(
            credential: { LocalMusicShareHost.shared.credential(forGrantId: $0) },
            resolve: { await LocalMusicShareHost.shared.source(for: $0) }
        )
        links = LinkedCompanionStore.loadAll()
        link = links.first
        state = link == nil ? .unlinked : .idle
        restorePersistedSnapshot()
        #if DEBUG
        if let fixture = RemoteFixture.current { installRemoteFixture(fixture) }
        #endif
        pairingSubscription = LinkedCompanionStore.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pairingDidChange() }
        #if os(iOS)
        backgroundSubscription = NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.didEnterBackground() }
            }
        #endif
        LocalMusicCloudUploader.shared.refresh()
        localMusicSubscription = LocalMusicShareHost.shared.changes
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard self?.state == .connected else { return }
                    self?.sendLocalMusicOffer()
                }
            }
        likesRevisionSubscription = LibrarySyncEngine.shared.$revision
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                guard self?.state == .connected else { return }
                self?.scheduleLikesPushIfSupported()
            }
        }
    }

    deinit {
        cancelNetworkResources()
    }

    private nonisolated func cancelNetworkResources() {
        searchTimeout?.cancel()
        rejectionTimeout?.cancel()
        connectTimeout?.cancel()
        reconnectTask?.cancel()
        livenessWatchdog?.cancel()
        inactiveGraceTask?.cancel()
        persistTask?.cancel()
        peerSignInTimeout?.cancel()
        pendingCommandsExpiry?.cancel()
        browser?.cancel()
    }

    func connect() {
        #if DEBUG
        guard !isFixture else { return }
        #endif
        links = LinkedCompanionStore.loadAll()
        if let active = link, let updated = links.first(where: { $0.sessionId == active.sessionId }) {
            link = updated
        } else {
            link = links.first
        }
        guard let link, link.secret != nil else {
            localContentServer.stop()
            clearPersistedSnapshot()
            state = .unlinked
            if !LinkedCompanionStore.pendingMessages().isEmpty, browser == nil { startBrowsing() }
            return
        }
        startLocalContentServer(for: link)
        guard channel == nil else { return }
        guard let browser else {
            startBrowsing()
            return
        }
        guard state != .connecting, state != .searching else { return }
        state = .searching
        startSearchTimeout()
        handleBrowseResults(browser.browseResults)
    }

    func setActive(_ active: Bool) {
        #if DEBUG
        guard !isFixture else { return }
        #endif
        if active {
            let wasSuspended = inactiveGraceTask != nil
            inactiveGraceTask?.cancel()
            inactiveGraceTask = nil
            if state == .connected, CompanionHeartbeat.controllerIsStale(lastFrameAt: lastFrameAt, now: Date()) {
                Log.link.info("[CompanionClient] connection went quiet while inactive; reconnecting")
                retry()
            } else {
                connect()
            }
            if wasSuspended { Log.link.debug("[CompanionClient] active again within the grace period") }
            return
        }
        #if os(macOS)
        if LocalMusicShareHost.shared.hasMusic { return }
        #endif
        guard inactiveGraceTask == nil else { return }
        inactiveGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.inactiveGrace)
            guard !Task.isCancelled, let self else { return }
            self.inactiveGraceTask = nil
            Log.link.info("[CompanionClient] inactive past the grace period; disconnecting")
            self.disconnect()
        }
    }

    private func didEnterBackground() {
        guard channel != nil || browser != nil else { return }
        inactiveGraceTask?.cancel()
        inactiveGraceTask = nil
        Log.link.info("[CompanionClient] entered the background; disconnecting before suspension")
        disconnect()
    }

    private func pairingDidChange() {
        #if DEBUG
        guard !isFixture else { return }
        #endif
        let previous = links
        links = LinkedCompanionStore.loadAll()
        let known = Set(previous.map(\.sessionId))
        let added = links.first { !known.contains($0.sessionId) }
        let active = link.flatMap { current in links.first { $0.sessionId == current.sessionId } }
        let next = added ?? active ?? links.first
        guard next?.sessionId != link?.sessionId else {
            link = next
            return
        }
        activate(next)
    }

    func select(sessionId: String) {
        #if DEBUG
        if isFixture {
            if let chosen = links.first(where: { $0.sessionId == sessionId }) { link = chosen }
            return
        }
        #endif
        guard let chosen = links.first(where: { $0.sessionId == sessionId }) else { return }
        LinkedCompanionStore.markUsed(sessionId: sessionId)
        guard chosen.sessionId != link?.sessionId else {
            if case .failed = state { retry() } else { connect() }
            return
        }
        activate(chosen)
    }

    func waitUntilReachable(timeout: Duration) async -> Bool {
        if state == .idle { connect() }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isReachable { return true }
            if case .failed = state { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return isReachable
    }

    func waitUntilLive(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isReachable, telemetry.isLive { return true }
            if !isReachable, case .failed = state { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return isReachable && telemetry.isLive
    }

    var connectionPhase: CompanionConnectionPhase {
        let hasFailed: Bool
        if case .failed = state { hasFailed = true } else { hasFailed = false }
        return .resolve(isReachable: isReachable, isLive: telemetry.isLive, hasFailed: hasFailed)
    }

    private func activate(_ next: LinkedCompanionStore.LinkRecord?) {
        teardown()
        discardPendingCommands()
        resetMirroredState()
        link = next
        guard next != nil else {
            localContentServer.stop()
            clearPersistedSnapshot()
            state = .unlinked
            connect()
            return
        }
        restorePersistedSnapshot()
        state = .idle
        reconnectDelay = Self.initialReconnectDelay
        connect()
    }

    private func resetMirroredState() {
        persistTask?.cancel()
        persistTask = nil
        tracks = []
        currentIndex = 0
        playingNextCount = 0
        reportsPlayingNext = false
        isPlaying = false
        hasSnapshot = false
        queueSource = nil
        telemetry.playback = nil
        telemetry.djState = nil
        telemetry.autoMixLive = nil
        telemetry.anchorDate = nil
        telemetry.isLive = false
        decks.reset()
    }

    func retry() {
        #if DEBUG
        guard !isFixture else { return }
        #endif
        teardown()
        connect()
    }

    func disconnect() {
        #if DEBUG
        guard !isFixture else { return }
        #endif
        teardown()
        localContentServer.stop()
        if state != .unlinked {
            state = .idle
        }
    }

    func forget(sessionId: String) {
        #if DEBUG
        if isFixture {
            links.removeAll { $0.sessionId == sessionId }
            if link?.sessionId == sessionId {
                link = links.first
                if link == nil { state = .unlinked }
            }
            return
        }
        #endif
        guard let record = links.first(where: { $0.sessionId == sessionId }) else { return }
        LinkedCompanionStore.enqueue(PendingLinkMessage(kind: .linkRevoke, link: record))
        LinkedCompanionStore.remove(sessionId: sessionId)
        needsSignInSessionIds.remove(sessionId)
        Log.link.info("[CompanionClient] forgot \(record.peerName, privacy: .public); telling it on next contact")
        flushOutbox()
    }

    func forgetAllLinks() {
        for record in links { forget(sessionId: record.sessionId) }
    }

    @discardableResult
    func queueSignOutEverywhere(accountId: String?, lineageDigest: String?) -> [String] {
        let names = links.map(\.peerName)
        for record in links {
            LinkedCompanionStore.enqueue(PendingLinkMessage(
                kind: .sessionRevoke,
                link: record,
                accountId: accountId,
                lineageDigest: lineageDigest
            ))
        }
        flushOutbox()
        return names
    }

    func refreshLinkStatuses() {
        #if DEBUG
        guard !isFixture else { return }
        #endif
        if browser == nil { connect() }
        for record in links where !isActive(record.sessionId) {
            probe(record)
        }
        flushOutbox()
    }

    private func flushOutbox() {
        let pending = LinkedCompanionStore.pendingMessages()
        guard !pending.isEmpty else { return }
        if browser == nil {
            startBrowsing()
            return
        }
        for message in pending {
            guard !couriersInFlight.contains(message.id),
                  let endpoint = advertisedEndpoints[message.servicePrefix],
                  let secret = message.secret,
                  let outgoing = message.message() else { continue }
            couriersInFlight.insert(message.id)
            Task { @MainActor [weak self] in
                let outcome = await LinkCourier.deliver(outgoing, to: endpoint, sessionId: message.sessionId, secret: secret)
                guard let self else { return }
                self.couriersInFlight.remove(message.id)
                switch outcome {
                case .delivered, .revoked:
                    LinkedCompanionStore.settle(messageId: message.id)
                    if outcome == .revoked { self.drop(sessionId: message.sessionId) }
                    Log.link.info("[CompanionClient] told \(message.peerName, privacy: .public): \(message.kind.rawValue, privacy: .public)")
                case .status, .unreachable:
                    break
                }
            }
        }
    }

    private func probe(_ record: LinkedCompanionStore.LinkRecord) {
        guard !probesInFlight.contains(record.sessionId),
              let endpoint = advertisedEndpoints[record.servicePrefix],
              let secret = record.secret else { return }
        probesInFlight.insert(record.sessionId)
        Task { @MainActor [weak self] in
            let outcome = await LinkCourier.probe(endpoint, sessionId: record.sessionId, secret: secret)
            guard let self else { return }
            self.probesInFlight.remove(record.sessionId)
            switch outcome {
            case .status(let needsSignIn):
                if needsSignIn {
                    self.needsSignInSessionIds.insert(record.sessionId)
                } else {
                    self.needsSignInSessionIds.remove(record.sessionId)
                }
            case .revoked:
                self.drop(sessionId: record.sessionId)
            case .delivered, .unreachable:
                break
            }
        }
    }

    private func drop(sessionId: String) {
        needsSignInSessionIds.remove(sessionId)
        guard LinkedCompanionStore.remove(sessionId: sessionId) != nil else { return }
        Log.link.info("[CompanionClient] a linked device forgot this one; removed its link")
    }

    private func startBrowsing() {
        if link != nil { state = .searching }

        let newBrowser = CompanionEndpoint.makeBrowser()

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }

        newBrowser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor in
                guard let self else { return }
                switch browserState {
                case .failed(let error):
                    self.teardown()
                    self.fail(CompanionFailure.classify(error, fallback: .networkUnavailable))
                case .waiting(let error):
                    self.lastWaitingError = error
                default:
                    break
                }
            }
        }

        browser = newBrowser
        newBrowser.start(queue: .main)
        if link != nil { startSearchTimeout() }
    }

    private func startSearchTimeout() {
        searchTimeout?.cancel()
        searchTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.state == .searching else { return }
            self.fail(CompanionFailure.classify(self.lastWaitingError, fallback: .notFound))
        }
    }

    private func fail(_ failure: CompanionFailure) {
        guard link != nil else { return }
        state = .failed(failure)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(Self.maximumReconnectDelay, delay * 2)

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard case .failed = self.state else { return }
            self.retry()
        }
    }

    private func startLivenessWatchdog() {
        livenessWatchdog?.cancel()
        livenessWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard case .connected = self.state else { continue }
                let now = Date()
                guard CompanionHeartbeat.controllerIsStale(lastFrameAt: self.lastFrameAt, now: now) else {
                    self.sendHeartbeatIfDue(at: now)
                    continue
                }

                Log.link.info("[CompanionClient] no frames for \(Int(CompanionHeartbeat.controllerStaleAfter), privacy: .public)s; reconnecting")
                self.teardown()
                self.connect()
                return
            }
        }
    }

    private func teardown() {
        dropConnection()
        searchTimeout?.cancel()
        searchTimeout = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        browser?.cancel()
        browser = nil
        contentEndpoint = nil
        contentEndpointsByDeviceToken.removeAll()
        advertisedEndpoints.removeAll()
        if !advertisedSessionIds.isEmpty { advertisedSessionIds = [] }
    }

    private func startLocalContentServer(for link: LinkedCompanionStore.LinkRecord) {
        guard let secret = link.secret else { return }
        do {
            try localContentServer.start(
                sessionId: link.sessionId,
                secret: secret,
                deviceId: DownloadManifestDeviceIdentity.deviceId()
            )
        } catch {
            Log.link.error("[CompanionClient] download sharing unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var signer: CompanionCommandSigner? {
        guard let link, let secret = link.secret else { return nil }
        return CompanionCommandSigner(sessionId: link.sessionId, secret: secret)
    }

    private func send(_ message: TokenTransferMessage) {
        guard let connection, let data = try? message.framed() else { return }
        gateway.sendCompanionFrame(
            data,
            type: message.type,
            ownerID: synchronizationID,
            connection: connection
        ) { [weak self, weak connection] in
            guard let self, let connection else { return false }
            return self.connection === connection
        }
    }

    private func transmitNow(_ message: TokenTransferMessage) {
        guard let connection, let data = try? message.framed() else { return }
        gateway.transmitAdmittedCompanionFrame(
            data,
            connection: connection
        ) { [weak self, weak connection] in
            guard let self, let connection else { return false }
            return self.connection === connection
        }
    }

    private func sendHeartbeatIfDue(at now: Date) {
        guard let link, CompanionHeartbeat.isDue(lastSentAt: lastHeartbeatAt, now: now) else { return }
        lastHeartbeatAt = now
        transmitNow(.acknowledgment(sessionId: link.sessionId))
    }

    // MARK: - Pending commands

    private func hold(_ command: PendingCommand, key: String?) {
        guard link != nil else { return }
        pendingCommands.enqueue(command, key: key, at: Date())
        Log.link.info("[CompanionClient] holding a command until \(self.linkedName, privacy: .public) is connected")
        holdForBackgroundCommands()
        schedulePendingCommandsExpiry()
        switch state {
        case .idle, .failed:
            if case .failed = state { reconnectDelay = Self.initialReconnectDelay }
            connect()
        case .unlinked, .searching, .connecting, .connected:
            break
        }
    }

    private func flushPendingCommands() {
        let commands = pendingCommands.drain(at: Date())
        pendingCommandsExpiry?.cancel()
        pendingCommandsExpiry = nil
        if !commands.isEmpty {
            Log.link.info("[CompanionClient] sending \(commands.count, privacy: .public) held commands to \(self.linkedName, privacy: .public)")
        }
        for command in commands {
            switch command {
            case let .queue(type, fromIndex, toIndex, trackId):
                guard let signer else { continue }
                transmitCommand(signer.queue(type, fromIndex: fromIndex, toIndex: toIndex, trackId: trackId, revision: appliedRevision))
            case let .control(type, deck, parameter, value, value2):
                transmitControl(type, deck: deck, parameter: parameter, value: value, value2: value2, continuous: false)
            }
        }
        releaseBackgroundCommandsSoon()
    }

    private func discardPendingCommands() {
        pendingCommands.removeAll()
        pendingCommandsExpiry?.cancel()
        pendingCommandsExpiry = nil
        releaseBackgroundCommands()
    }

    private func schedulePendingCommandsExpiry() {
        guard pendingCommandsExpiry == nil, let deadline = pendingCommands.nextExpiry else { return }
        let delay = max(0.1, deadline.timeIntervalSinceNow + 0.05)
        pendingCommandsExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.pendingCommandsExpiry = nil
            let dropped = self.pendingCommands.expire(at: Date())
            if dropped > 0 {
                Log.link.info("[CompanionClient] dropped \(dropped, privacy: .public) held commands; \(self.linkedName, privacy: .public) didn't connect in time")
            }
            if self.pendingCommands.isEmpty {
                self.releaseBackgroundCommands()
            } else {
                self.schedulePendingCommandsExpiry()
            }
        }
    }

    private func holdForBackgroundCommands() {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .background, backgroundCommandTask == .invalid else { return }
        backgroundCommandTask = UIApplication.shared.beginBackgroundTask(withName: "Sounding Remote") { [weak self] in
            Task { @MainActor in self?.releaseBackgroundCommands() }
        }
        #endif
    }

    private func releaseBackgroundCommandsSoon() {
        #if os(iOS)
        guard backgroundCommandTask != .invalid else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.releaseBackgroundCommands()
        }
        #endif
    }

    private func releaseBackgroundCommands() {
        #if os(iOS)
        guard backgroundCommandTask != .invalid else { return }
        let task = backgroundCommandTask
        backgroundCommandTask = .invalid
        if UIApplication.shared.applicationState == .background, pendingCommands.isEmpty {
            disconnect()
        }
        UIApplication.shared.endBackgroundTask(task)
        #endif
    }

    private static func pendingKey(for type: MessageType) -> String? {
        switch type {
        case .transportPlay, .transportPause: return "transport.playing"
        case .transportSeek: return "transport.seek"
        case .transportShuffle: return "transport.shuffle"
        case .transportRepeat: return "transport.repeat"
        case .transportSleepTimer: return "transport.sleep"
        case .djEnable, .djDisable: return "dj.enabled"
        case .djAutoEnable, .djAutoDisable: return "dj.auto"
        default: return nil
        }
    }

    private static func holdsWhileDisconnected(_ type: MessageType) -> Bool {
        switch type {
        case .transportPlay, .transportPause, .transportNext, .transportPrevious, .transportSeek,
             .transportShuffle, .transportRepeat, .transportSleepTimer,
             .djEnable, .djDisable, .djAutoEnable, .djAutoDisable,
             .queueAdd, .queueRemove, .queueReorder, .queueJump:
            return true
        default:
            return false
        }
    }

    private func dropConnection() {
        livenessWatchdog?.cancel()
        livenessWatchdog = nil
        lastHeartbeatAt = nil
        connectedAt = nil
        pendingContinuousControls.removeAll()
        connectTimeout?.cancel()
        connectTimeout = nil
        lastWaitingError = nil
        companionServiceName = nil
        channel?.cancel()
        channel = nil
        appliedRevision = -1
        appliedPlaybackRevision = 0
        appliedDJRevision = 0
        cuePushHighWaterMark = 0
        libraryPushHighWaterMark = nil
        lastDeviceStatusMillis = 0
        lastContinueSessionMillis = 0
        if peerNeedsSignIn { peerNeedsSignIn = false }
        endPeerSignInRequest()
        playbackConfirmations.observeDisconnect()
        gateway.cancel(keyPrefix: synchronizationID)
        LocalMusicShareHost.shared.revokeAll()
        synchronization.unregisterNearbySink(id: synchronizationID)
        ContinueFrom.shared.unregisterRelay(id: synchronizationID)
        intents.clear()
        intentSettleTask?.cancel()
        intentSettleTask = nil
        observedPlayback = nil
        if telemetry.isLive {
            let now = Date()
            if let playback = telemetry.playback, playback.isPlaying, let anchorDate = telemetry.anchorDate {
                telemetry.playback = playback.frozen(
                    at: playback.estimatedPosition(elapsed: now.timeIntervalSince(anchorDate))
                )
                telemetry.anchorDate = now
            }
            telemetry.isLive = false
            isPlaying = false
            persistSnapshotNow()
        }
        decks.reset()
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        noteAdvertisedLinks(results)
        guard let link, let secret = link.secret else { return }
        let prefix = String(link.sessionId.prefix(8))
        let ownServiceName = localContentServer.advertisedServiceName
        var discovered: [String: NWEndpoint] = [:]
        var fallback: NWEndpoint?
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  name.hasPrefix(BonjourConstants.contentServiceName),
                  name.contains(prefix),
                  name != ownServiceName else { continue }
            fallback = fallback ?? result.endpoint
            if let token = PeerContentServer.serviceToken(fromServiceName: name, sessionId: link.sessionId) {
                discovered[token] = result.endpoint
            }
        }
        contentEndpointsByDeviceToken = discovered
        contentEndpoint = fallback

        let match = results.first { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return false }
            return CompanionEndpoint.isCompanionService(name, sessionId: link.sessionId)
        }

        guard let match, case .service(let name, _, _, _) = match.endpoint else { return }
        guard channel == nil || companionServiceName != name else { return }

        searchTimeout?.cancel()
        searchTimeout = nil
        connect(to: match.endpoint, serviceName: name, sessionId: link.sessionId, secret: secret)
    }

    private func noteAdvertisedLinks(_ results: Set<NWBrowser.Result>) {
        let prefixes = Set(links.map(\.servicePrefix) + LinkedCompanionStore.pendingMessages().map(\.servicePrefix))
        var endpoints: [String: NWEndpoint] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  name.hasPrefix(BonjourConstants.companionServiceName + "-") else { continue }
            let prefix = String(name.dropFirst(BonjourConstants.companionServiceName.count + 1).prefix(8))
            guard prefixes.contains(prefix) else { continue }
            endpoints[prefix] = result.endpoint
        }
        advertisedEndpoints = endpoints
        let advertised = Set(links.filter { endpoints[$0.servicePrefix] != nil }.map(\.sessionId))
        if advertised != advertisedSessionIds { advertisedSessionIds = advertised }
        flushOutbox()
    }

    private func connect(to endpoint: NWEndpoint, serviceName: String, sessionId: String, secret: Data) {
        channel?.cancel()
        channel = nil
        connectTimeout?.cancel()
        connectTimeout = nil

        companionServiceName = serviceName
        state = .connecting
        cuePushHighWaterMark = 0
        libraryPushHighWaterMark = libraryPushMarks[sessionId]

        let newChannel = CompanionChannel(to: endpoint, sessionId: sessionId, secret: secret)
        channel = newChannel
        newChannel.start(
            onEvent: { [weak self, weak newChannel] event in
                guard let self, let newChannel, self.channel === newChannel else { return }
                self.handleChannelEvent(event)
            },
            onMessage: { [weak self, weak newChannel] message in
                guard let self, let newChannel, self.channel === newChannel else { return }
                await self.handle(message)
            }
        )
        startConnectTimeout(for: newChannel)
    }

    private func startConnectTimeout(for source: CompanionChannel) {
        connectTimeout?.cancel()
        connectTimeout = Task { [weak self, weak source] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, let source, source === self.channel else { return }
            guard self.state == .connecting else { return }

            let failure = CompanionFailure.classify(source.lastError ?? self.lastWaitingError, fallback: .notFound)
            self.dropConnection()
            self.fail(failure)
        }
    }

    private func handleChannelEvent(_ event: CompanionChannel.Event) {
        switch event {
        case .ready:
            connectTimeout?.cancel()
            connectTimeout = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectDelay = Self.initialReconnectDelay
            lastWaitingError = nil
            state = .connected
            lastFrameAt = Date()
            connectedAt = lastFrameAt
            Log.link.info("[CompanionClient] connected to \(self.linkedName, privacy: .public)")
            startLivenessWatchdog()
            announceAndRequestQueue()
            flushPendingCommands()
            synchronization.registerNearbySink(id: synchronizationID) { [weak self] domain in
                guard domain == .cues else { return }
                self?.scheduleCuePush()
            }
            scheduleCuePush()
            scheduleLikesPushIfSupported()
            sendLocalMusicOffer()
            ContinueFrom.shared.registerRelay(id: synchronizationID) { [weak self] session in
                self?.sendContinueSession(session)
            }
            if let own = ContinueFrom.shared.latestOwn { sendContinueSession(own) }
        case .waiting:
            lastWaitingError = channel?.lastError
        case .failed:
            let failure = CompanionFailure.classify(channel?.lastError)
            let reconnectsAtOnce = connectionWasSettled
            dropConnection()
            reconnectAfterDrop(failure, atOnce: reconnectsAtOnce)
        case .closed:
            let reconnectsAtOnce = connectionWasSettled
            dropConnection()
            reconnectAfterDrop(.closed, atOnce: reconnectsAtOnce)
        }
    }

    private var connectionWasSettled: Bool {
        guard state == .connected, let readyAt = connectedAt else { return false }
        return Date().timeIntervalSince(readyAt) >= CompanionHeartbeat.interval
    }

    private func reconnectAfterDrop(_ failure: CompanionFailure, atOnce: Bool) {
        guard atOnce, link != nil else {
            fail(failure)
            return
        }
        Log.link.info("[CompanionClient] connection to \(self.linkedName, privacy: .public) dropped; reconnecting")
        state = .idle
        connect()
    }

    private func handle(_ message: TokenTransferMessage) async {
        lastFrameAt = Date()

        guard let link, let secret = link.secret else { return }
        guard message.sessionId == link.sessionId else { return }

        switch message.type {
        case .queueState:
            guard let queue = message.queue else { return }
            guard queue.verify(sessionId: link.sessionId, secret: secret) else { return }
            guard queue.revision > appliedRevision else { return }

            appliedRevision = queue.revision
            if tracks != queue.tracks { tracks = queue.tracks }
            if currentIndex != queue.currentIndex { currentIndex = queue.currentIndex }
            let nextPlayingNextCount = queue.playingNextCount ?? 0
            if playingNextCount != nextPlayingNextCount { playingNextCount = nextPlayingNextCount }
            if reportsPlayingNext != (queue.playingNextCount != nil) {
                objectWillChange.send()
                reportsPlayingNext = queue.playingNextCount != nil
            }
            if isPlaying != queue.isPlaying { isPlaying = queue.isPlaying }
            let nextSource = Self.queueSource(title: queue.sourceTitle, kind: queue.sourceKind)
            if queueSource != nextSource { queueSource = nextSource }
            if !hasSnapshot { hasSnapshot = true }
            Log.link.debug("[CompanionClient] rx queue_state rev=\(queue.revision, privacy: .public) tracks=\(queue.tracks.count, privacy: .public)")
            schedulePersistSnapshot()

        case .playbackState:
            guard let playback = message.playback else { return }
            guard playback.verify(sessionId: link.sessionId, secret: secret) else { return }
            guard playback.revision > appliedPlaybackRevision else { return }
            appliedPlaybackRevision = playback.revision
            ingest(playback)
            Log.link.debug("[CompanionClient] rx playback_state rev=\(playback.revision, privacy: .public) playing=\(playback.isPlaying, privacy: .public) position=\(playback.positionSeconds, privacy: .public)")

        case .djState:
            guard let dj = message.dj else { return }
            guard dj.verify(sessionId: link.sessionId, secret: secret) else { return }
            guard dj.revision > appliedDJRevision else { return }
            appliedDJRevision = dj.revision
            let now = Date()
            let decksOpen = dj.verifiedDecksOpen(sessionId: link.sessionId, secret: secret)
            if decks.decksOpen != decksOpen { decks.decksOpen = decksOpen }
            decks.state = dj
            decks.receivedAt = now
            guard decks.shouldPublishTelemetry(dj, replacing: telemetry.djState, at: now) else { return }
            decks.telemetryPublishedAt = now
            telemetry.djState = dj
            let live = AutoMixLiveState.decode(dj.verifiedLive(sessionId: link.sessionId, secret: secret))
            if telemetry.autoMixLive != live { telemetry.autoMixLive = live }
            schedulePersistSnapshot()

        case .cueSync:
            guard let payload = message.cueSync else { return }
            guard payload.verify(sessionId: link.sessionId, secret: secret) else { return }
            guard payload.isFresh() else { return }
            guard cueReplayGuard.admit(payload.nonce) else { return }
            guard let body = CueSyncBody.decode(payload.body) else { return }
            await synchronization.adoptNearbyCueState(body)

        case .linkRevoke:
            guard message.verifiedRevoke(sessionId: link.sessionId, secret: secret) != nil else { return }
            transmitNow(.acknowledgment(sessionId: link.sessionId))
            Log.link.info("[CompanionClient] \(self.linkedName, privacy: .public) forgot this device")
            drop(sessionId: link.sessionId)

        case .authHandoffSessionRequest:
            await handleAuthHandoffRequest(toPeerWith: link, secret: secret)

        case .localMusicRequest:
            sendLocalMusicOffer()

        case .continueSession:
            guard let payload = message.continueSession,
                  payload.verify(sessionId: link.sessionId, secret: secret),
                  payload.isFresh(),
                  payload.issuedAtMillis > lastContinueSessionMillis else { return }
            lastContinueSessionMillis = payload.issuedAtMillis
            ContinueFrom.shared.adoptNearby(payload.body)

        case .deviceStatus:
            guard let status = message.deviceStatus,
                  status.verify(sessionId: link.sessionId, secret: secret),
                  status.isFresh(),
                  status.issuedAtMillis >= lastDeviceStatusMillis else { return }
            lastDeviceStatusMillis = status.issuedAtMillis
            if peerNeedsSignIn != status.needsSignIn { peerNeedsSignIn = status.needsSignIn }
            if !status.needsSignIn { endPeerSignInRequest() }
            Log.link.info("[CompanionClient] \(self.linkedName, privacy: .public) needs sign-in=\(status.needsSignIn, privacy: .public)")

        case .error:
            Log.link.info("[CompanionClient] \(self.linkedName, privacy: .public) rejected a command: \(message.error ?? "", privacy: .public)")
            rejection = message.error
            playbackConfirmations.observeRejection(message.error ?? "")
            rejectionTimeout?.cancel()
            rejectionTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.rejection = nil
            }

        default:
            break
        }
    }

    private func handleAuthHandoffRequest(toPeerWith link: LinkedCompanionStore.LinkRecord, secret: Data) async {
        guard self.link?.sessionId == link.sessionId else { return }
        publishAuthHandoffRequest(for: link, secret: secret)
        Log.link.info("[CompanionClient] peer asked for auth handoff; published sign-in request state")
    }

    func requestPeerSignIn() {
        guard state == .connected, let link, let secret = link.secret, !isRequestingPeerSignIn else { return }
        isRequestingPeerSignIn = true
        publishAuthHandoffRequest(for: link, secret: secret)
        peerSignInTimeout?.cancel()
        peerSignInTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.endPeerSignInRequest()
        }
        Log.link.info("[CompanionClient] signing in \(self.linkedName, privacy: .public) over the link")
    }

    private func publishAuthHandoffRequest(for link: LinkedCompanionStore.LinkRecord, secret: Data) {
        authHandoffRequest = AuthHandoffRequest(
            sessionId: link.sessionId,
            secret: secret,
            peerName: link.displayName,
            peerClass: link.peerClass
        )
    }

    private func endPeerSignInRequest() {
        peerSignInTimeout?.cancel()
        peerSignInTimeout = nil
        if isRequestingPeerSignIn { isRequestingPeerSignIn = false }
    }

    func sendAuthHandoffSession(_ session: StoredSession) {
        guard let link, let secret = link.secret else {
            Log.link.error("[CompanionClient] cannot send auth handoff session: no active companion link")
            return
        }

        let offer = AuthHandoffSessionOfferPayload.create(
            token: session.oauthToken,
            refreshToken: session.refreshToken,
            clientId: session.clientId,
            expiresAt: session.expiresAt,
            sessionId: link.sessionId,
            secret: secret
        )
        send(.authHandoffSessionOffer(sessionId: link.sessionId, offer: offer))
        Log.link.info("[CompanionClient] sent fresh auth handoff session over companion link")
    }

    // MARK: - Snapshot persistence

    private func restorePersistedSnapshot() {
        guard let link,
              let data = UserDefaults.standard.data(forKey: Self.snapshotDefaultsKey),
              let snapshot = try? JSONDecoder().decode(PersistedSnapshot.self, from: data),
              snapshot.sessionId == link.sessionId else { return }
        tracks = snapshot.tracks
        currentIndex = min(max(0, snapshot.currentIndex), max(0, tracks.count - 1))
        playingNextCount = snapshot.playingNextCount ?? 0
        reportsPlayingNext = snapshot.playingNextCount != nil
        isPlaying = false
        telemetry.playback = snapshot.playback
        telemetry.djState = snapshot.djState
        telemetry.anchorDate = snapshot.savedAt
        telemetry.isLive = false
        hasSnapshot = !tracks.isEmpty || snapshot.playback?.trackId != nil
    }

    private func schedulePersistSnapshot() {
        guard persistTask == nil else { return }
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.snapshotPersistInterval)
            guard !Task.isCancelled, let self else { return }
            self.persistTask = nil
            self.writeSnapshot()
        }
    }

    private func persistSnapshotNow() {
        persistTask?.cancel()
        persistTask = nil
        writeSnapshot()
    }

    private func writeSnapshot() {
        guard let link else { return }
        let snapshot = PersistedSnapshot(
            sessionId: link.sessionId,
            tracks: tracks,
            currentIndex: currentIndex,
            isPlaying: isPlaying,
            playingNextCount: playingNextCount,
            playback: telemetry.playback,
            djState: telemetry.djState,
            savedAt: Date()
        )
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        let writer = snapshotWriter
        let key = Self.snapshotDefaultsKey
        Task.detached(priority: .utility) {
            await writer.write(snapshot, generation: generation, key: key)
        }
    }

    private func clearPersistedSnapshot() {
        persistTask?.cancel()
        persistTask = nil
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        let writer = snapshotWriter
        let key = Self.snapshotDefaultsKey
        Task.detached(priority: .utility) {
            await writer.remove(generation: generation, key: key)
        }
        tracks = []
        currentIndex = 0
        playingNextCount = 0
        reportsPlayingNext = false
        isPlaying = false
        telemetry.playback = nil
        telemetry.djState = nil
        telemetry.autoMixLive = nil
        telemetry.anchorDate = nil
        telemetry.isLive = false
        decks.reset()
        hasSnapshot = false
        queueSource = nil
    }

    // MARK: - Queue

    func requestQueue() {
        sendQueueCommand(.queueRequest)
    }

    private func announceAndRequestQueue() {
        guard let link, let secret = link.secret, let signer else { return }
        var message = signer.queue(.queueRequest, revision: appliedRevision)
        message.peer = LinkPeerIdentity.local(sessionId: link.sessionId, secret: secret)
        transmitCommand(message)
    }

    @discardableResult
    nonisolated static func queueSource(title: String?, kind: String?) -> PlaybackQueueSource? {
        guard let title, !title.isEmpty else { return nil }
        return PlaybackQueueSource(
            id: nil,
            kind: kind.flatMap(PlaybackQueueSource.Kind.init(rawValue:)) ?? .other,
            title: title
        )
    }

    func load(
        trackIds: [String],
        startIndex: Int,
        positionSeconds: Double,
        autoplay: Bool,
        source: PlaybackQueueSource? = nil
    ) -> Bool {
        guard trackIds.indices.contains(startIndex), let signer else { return false }
        return transmitCommand(signer.load(
            trackIds: trackIds,
            startIndex: startIndex,
            positionSeconds: max(0, positionSeconds),
            autoplay: autoplay,
            sourceTitle: source?.title,
            sourceKind: source?.kind.rawValue
        ))
    }

    func awaitPlayback(trackId: String, timeout: Duration) async -> PlaybackConfirmationTracker.Outcome {
        await playbackConfirmations.confirm(trackId: trackId, timeout: timeout) { isReachable }
    }

    func loadConfirmingPlayback(
        trackIds: [String],
        startIndex: Int,
        positionSeconds: Double,
        autoplay: Bool,
        source: PlaybackQueueSource? = nil,
        timeout: Duration
    ) async -> PlaybackConfirmationTracker.Outcome {
        guard trackIds.indices.contains(startIndex) else { return .rejected("Could not load the queue") }
        return await playbackConfirmations.confirm(trackId: trackIds[startIndex], timeout: timeout) {
            load(trackIds: trackIds, startIndex: startIndex, positionSeconds: positionSeconds, autoplay: autoplay, source: source)
        }
    }

    func addToQueue(trackId: String, atIndex: Int = -1, optimistic track: QueueTrack? = nil) {
        if let track, hasSnapshot {
            if tracks.isEmpty {
                tracks.append(track)
            } else {
                let queuedEnd = min(tracks.count, currentIndex + 1 + playingNextCount)
                let appendsAt = reportsPlayingNext ? queuedEnd : tracks.count
                let target = atIndex < 0 || atIndex >= tracks.count ? appendsAt : atIndex
                if reportsPlayingNext, target > currentIndex, target <= queuedEnd { playingNextCount += 1 }
                tracks.insert(track, at: target)
                if target <= currentIndex { currentIndex += 1 }
            }
        }
        sendQueueCommand(.queueAdd, toIndex: atIndex, trackId: trackId)
    }

    func playNext(trackId: String, optimistic track: QueueTrack? = nil) {
        let index = tracks.isEmpty ? -1 : min(currentIndex + 1, tracks.count)
        addToQueue(trackId: trackId, atIndex: index, optimistic: track)
    }

    func move(from source: Int, to destination: Int) {
        guard source >= 0, source < tracks.count else { return }
        let target = max(0, min(destination, tracks.count - 1))
        guard target != source else { return }

        let trackId = tracks[source].id
        let playingId = tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : nil

        let track = tracks.remove(at: source)
        tracks.insert(track, at: target)
        if let playingId, let index = tracks.firstIndex(where: { $0.id == playingId }) {
            currentIndex = index
        }

        sendQueueCommand(.queueReorder, fromIndex: source, toIndex: target, trackId: trackId)
    }

    func remove(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        let trackId = tracks[index].id
        let playingId = tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : nil

        if index > currentIndex, index <= currentIndex + playingNextCount { playingNextCount -= 1 }
        tracks.remove(at: index)
        if let playingId, let newIndex = tracks.firstIndex(where: { $0.id == playingId }) {
            currentIndex = newIndex
        } else {
            currentIndex = min(index, max(0, tracks.count - 1))
        }

        sendQueueCommand(.queueRemove, fromIndex: index, trackId: trackId)
    }

    func jump(to index: Int) {
        guard tracks.indices.contains(index) else { return }
        let trackId = tracks[index].id
        let target = tracks[index]
        noteIntent {
            $0.noteSkip(to: target, observed: $1, observedAt: $2, at: $3)
            $0.notePlaying(true, observed: $1, observedAt: $2, at: $3)
        }
        currentIndex = index
        isPlaying = true
        sendQueueCommand(.queueJump, fromIndex: index, trackId: trackId)
    }

    private func sendQueueCommand(_ type: MessageType, fromIndex: Int = -1, toIndex: Int = -1, trackId: String = "") {
        #if DEBUG
        if isFixture {
            simulateFixtureQueue(type, fromIndex: fromIndex)
            return
        }
        #endif
        guard let signer else { return }
        guard isReachable else {
            if Self.holdsWhileDisconnected(type) {
                hold(.queue(type, fromIndex: fromIndex, toIndex: toIndex, trackId: trackId), key: nil)
            }
            return
        }
        transmitCommand(signer.queue(type, fromIndex: fromIndex, toIndex: toIndex, trackId: trackId, revision: appliedRevision))
    }

    @discardableResult
    private func transmitCommand(_ message: TokenTransferMessage) -> Bool {
        guard connection != nil, isReachable else {
            Log.link.info("[CompanionClient] dropped \(message.type.rawValue, privacy: .public); \(self.linkedName, privacy: .public) isn't connected")
            return false
        }
        Log.link.info("[CompanionClient] tx \(message.type.rawValue, privacy: .public)")
        send(message)
        return true
    }

    // MARK: - Bulk sync

    private func scheduleCuePush() {
        gateway.submit(
            lane: .companionBulk,
            key: "\(synchronizationID).cues"
        ) { [weak self] in
            await self?.runCuePush()
        }
    }

    private func runCuePush() async {
        guard let link, let secret = link.secret else { return }
        while connection != nil {
            let batch = await synchronization.nearbyCueBatch(
                changedSince: cuePushHighWaterMark,
                limit: CueSyncChunking.maxBatchSize
            )
            let cues = batch.cues
            let dismissals = batch.dismissals
            if cues.isEmpty && dismissals.isEmpty { return }

            guard let body = CueSyncBody(cues: cues, dismissals: dismissals).encoded() else { return }
            let payload = CueSyncPayload.create(
                body: body, cueCount: cues.count, dismissalCount: dismissals.count,
                sessionId: link.sessionId, secret: secret
            )
            transmitNow(.cueSync(sessionId: link.sessionId, payload: payload))

            let batchMax = max(cues.map(\.updatedAtMillis).max() ?? 0, dismissals.map(\.dismissedAtMillis).max() ?? 0)
            if batchMax <= cuePushHighWaterMark { return }
            cuePushHighWaterMark = batchMax
        }
    }

    private func sendLocalMusicOffer() {
        guard let link, let secret = link.secret,
              let body = LocalMusicShareHost.shared.offer().encoded() else { return }
        transmitNow(.localMusicOffer(
            sessionId: link.sessionId,
            payload: LocalMusicOfferPayload.create(body: body, sessionId: link.sessionId, secret: secret)
        ))
    }

    private func sendContinueSession(_ session: ContinueSession) {
        guard state == .connected, let link, let secret = link.secret,
              let body = session.encoded() else { return }
        transmitNow(.continueSession(
            sessionId: link.sessionId,
            payload: ContinueSessionPayload.create(body: body, sessionId: link.sessionId, secret: secret)
        ))
    }

    private func scheduleLikesPushIfSupported() {
        guard [DeviceClass.phone, .pad, .mac].contains(DeviceClass.current) else { return }
        gateway.submit(
            lane: .companionBulk,
            key: "\(synchronizationID).likes"
        ) { [weak self] in
            await self?.runLikesPush()
        }
    }

    private func runLikesPush() async {
        guard let link,
              let secret = link.secret,
              let accountId = SoundCloudCredentialSource.shared.currentUser?.id
                ?? SubscriptionService.shared.authenticatedAccountID else { return }

        let since = libraryPushHighWaterMark
        let chunks = await LibrarySyncEngine.shared.peerChunks(since: since)
        let rowChunks = chunks.filter { $0.carriesRows && $0.account == accountId }
        if since != nil, rowChunks.isEmpty { return }
        let sessionId = link.sessionId
        let owned = chunks.filter { $0.account == accountId }
        let payloads = await Task.detached(priority: .utility) {
            Self.libraryPushPayloads(owned, accountId: accountId, sessionId: sessionId, secret: secret)
        }.value
        for payload in payloads {
            guard connection != nil, !Task.isCancelled else { return }
            transmitNow(.likesSync(sessionId: link.sessionId, payload: payload))
            await Task.yield()
        }
        let sent = rowChunks.map(\.updatedAtMillis).max() ?? 0
        libraryPushHighWaterMark = max(since ?? 0, sent)
        libraryPushMarks[link.sessionId] = libraryPushHighWaterMark
    }

    nonisolated private static func libraryPushPayloads(_ chunks: [LibraryChunk], accountId: String, sessionId: String, secret: Data) -> [LikesSyncPayload] {
        let batches = LibraryPeerBody.batches(chunks)
        var payloads: [LikesSyncPayload] = []
        for (index, batch) in batches.enumerated() {
            let isComplete = index == batches.count - 1
            guard let encoded = LibraryPeerBody(accountId: accountId, chunks: batch, isComplete: isComplete).encoded() else { break }
            payloads.append(LikesSyncPayload.create(
                body: encoded,
                accountId: accountId,
                recordCount: batch.count,
                isComplete: isComplete,
                sessionId: sessionId,
                secret: secret
            ))
        }
        return payloads
    }
}

extension CompanionClient {

    var isReachable: Bool {
        if case .connected = state { return true }
        return false
    }

    func play() {
        noteIntent { $0.notePlaying(true, observed: $1, observedAt: $2, at: $3) }
        sendControl(.transportPlay)
    }

    func pause() {
        noteIntent { $0.notePlaying(false, observed: $1, observedAt: $2, at: $3) }
        sendControl(.transportPause)
    }

    func togglePlayPause() {
        telemetry.playback?.isPlaying == true ? pause() : play()
    }

    func next() {
        let target = RemoteSkipPlanner.nextTarget(
            tracks: tracks,
            currentIndex: currentIndex,
            presentedTrackId: telemetry.playback?.trackId
        )
        if let target {
            noteIntent { $0.noteSkip(to: target, observed: $1, observedAt: $2, at: $3) }
        }
        sendControl(.transportNext)
    }

    func previous() {
        let plan = RemoteSkipPlanner.previous(
            tracks: tracks,
            currentIndex: currentIndex,
            presentedTrackId: telemetry.playback?.trackId,
            position: telemetry.estimatedPosition()
        )
        switch plan {
        case .restart:
            noteIntent { $0.noteSkip(to: nil, observed: $1, observedAt: $2, at: $3) }
        case .track(let target):
            noteIntent { $0.noteSkip(to: target, observed: $1, observedAt: $2, at: $3) }
        case .unknown:
            break
        }
        sendControl(.transportPrevious)
    }

    func seek(toSeconds seconds: Double) {
        noteIntent { $0.noteSeek(to: seconds, observed: $1, observedAt: $2, at: $3) }
        sendControl(.transportSeek, parameter: .position, value: seconds)
    }

    var upNext: [(index: Int, track: QueueTrack)] {
        RemoteQueueProjection.upNext(tracks: tracks, currentIndex: currentIndex, presentedTrackId: telemetry.playback?.trackId)
    }

    var upNextLayout: UpNextLayout {
        let count = upNext.count
        let queued = RemoteQueueProjection.playingNextCount(
            playingNextCount, tracks: tracks, currentIndex: currentIndex, presentedTrackId: telemetry.playback?.trackId
        )
        let autoMixOn = telemetry.autoMixLive != nil || telemetry.djState?.isAutoMixEnabled == true
        return UpNextLayout.make(upcomingCount: count, playingNextCount: queued, autoMixOn: autoMixOn)
    }

    func playNext(queueIndex index: Int) {
        guard let destination = RemoteQueueProjection.playNextDestination(
            for: index,
            tracks: tracks,
            currentIndex: currentIndex,
            presentedTrackId: telemetry.playback?.trackId
        ) else { return }
        move(from: index, to: destination)
    }

    private func noteIntent(_ record: (inout RemotePlaybackIntents, PlaybackStatePayload?, Date, Date) -> Void) {
        guard isReachable, telemetry.isLive else { return }
        record(&intents, observedPlayback, observedAt, Date())
        publishPlayback()
    }

    fileprivate func ingest(_ playback: PlaybackStatePayload) {
        observedPlayback = playback
        observedAt = Date()
        if !telemetry.isLive { telemetry.isLive = true }
        publishPlayback()
        playbackConfirmations.observePlayback(trackId: playback.trackId)
        schedulePersistSnapshot()
    }

    private func publishPlayback() {
        guard let observed = observedPlayback else { return }
        let now = Date()
        intents.settle(observed: observed, observedAt: observedAt, isLive: telemetry.isLive, at: now)
        let presentation = intents.present(observed, observedAt: observedAt, at: now)
        telemetry.playback = presentation.playback
        telemetry.anchorDate = presentation.anchorDate
        scheduleIntentSettle()
    }

    private func scheduleIntentSettle() {
        intentSettleTask?.cancel()
        intentSettleTask = nil
        guard let deadline = intents.nextDeadline else { return }
        let delay = max(0.05, deadline.timeIntervalSinceNow + 0.01)
        intentSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.intentSettleTask = nil
            self.publishPlayback()
        }
    }

    var canChangePlaybackModes: Bool { isReachable && telemetry.playbackModes != nil }

    func setShuffle(_ enabled: Bool) {
        guard canChangePlaybackModes else { return }
        sendControl(.transportShuffle, value: enabled ? 1 : 0)
    }

    func setRepeat(_ mode: RemoteRepeatMode) {
        guard canChangePlaybackModes else { return }
        sendControl(.transportRepeat, value: mode.wireValue)
    }

    var volume: Double? {
        guard let reported = telemetry.playback?.effectiveVolume else { return nil }
        return volumeChannel.value(echo: reported)
    }


    func setVolume(_ value: Double) {
        guard isReachable else { return }
        volumeChannel.set(value)
    }

    func beginVolumeChange() {
        volumeChannel.begin()
    }

    func endVolumeChange() {
        volumeChannel.end()
    }

    func stepVolume(_ steps: Int) {
        guard isReachable, let reported = telemetry.playback?.effectiveVolume else { return }
        volumeChannel.step(steps, echo: reported)
    }

    private func transmitVolume(_ value: Double) {
        guard isReachable else { return }
        sendControl(.transportVolume, value: min(1, max(0, value)), continuous: true)
    }

    var sleepTimer: SleepTimerStatus? { telemetry.playback?.sleepTimerStatus }

    func setSleepTimer(_ mode: SleepTimerMode?) {
        guard isReachable else { return }
        sendControl(.transportSleepTimer, value: mode?.wireKind ?? 0, value2: mode?.wireMinutes ?? 0)
    }

    func setDJEnabled(_ enabled: Bool) { sendControl(enabled ? .djEnable : .djDisable) }
    func setAutoMixEnabled(_ enabled: Bool) { sendControl(enabled ? .djAutoEnable : .djAutoDisable) }
    func startPartyScene(lights: LightingIntensity) { sendControl(.sceneParty, value: lights.wireValue) }
    func startWindDown(minutes: Double) { sendControl(.sceneWindDown, value: minutes) }
    func setDJProfile(_ profileId: DJProfileID) {
        guard let index = DJProfile.all.firstIndex(where: { $0.id == profileId }) else { return }
        sendControl(.djProfile, parameter: .profile, value: Double(index))
    }
    func mixNow()                      { sendControl(.djMixNow) }
    func extendMix()                   { sendControl(.djExtend) }
    func sendEnergyTarget(level: Int, heartRate: Double?) {
        sendControl(.djEnergy, value: Double(level), value2: heartRate ?? 0)
    }

    func seek(deck: ControlDeck, toSeconds seconds: Double) {
        sendControl(.djCue, deck: deck, parameter: .position, value: seconds)
    }

    func cue(deck: ControlDeck, toSeconds seconds: Double) {
        seek(deck: deck, toSeconds: seconds)
    }

    func setHotCue(deck: ControlDeck, index: Int, atSeconds seconds: Double) {
        sendControl(.djHotCueSet, deck: deck, value: Double(index), value2: seconds)
    }

    func togglePlayPause(deck: ControlDeck) {
        sendControl(.djDeckPlayPause, deck: deck)
    }

    func setLoop(deck: ControlDeck, startSeconds: Double, lengthSeconds: Double) {
        sendControl(
            .djLoopSet, deck: deck, parameter: .loopStart,
            value: startSeconds, value2: lengthSeconds
        )
    }

    func setLoop(deck: ControlDeck, beats: Int) {
        sendControl(.djLoopSet, deck: deck, parameter: .loopBeats, value: Double(beats))
    }

    func clearLoop(deck: ControlDeck) { sendControl(.djLoopClear, deck: deck) }

    func sync(deck: ControlDeck) { sendControl(.djSync, deck: deck) }

    func setCrossfade(_ value: Double) {
        sendControl(.djCrossfader, parameter: .crossfade, value: value, continuous: true)
    }

    func setEQ(deck: ControlDeck, band: ControlParameter, decibels: Double) {
        sendControl(.djEQ, deck: deck, parameter: band, value: decibels, continuous: true)
    }

    func setFilterCutoff(deck: ControlDeck, hertz: Double) {
        sendControl(.djFilter, deck: deck, parameter: .filterCutoff, value: hertz, continuous: true)
    }

    func setFilterResonance(deck: ControlDeck, value: Double) {
        sendControl(.djFilter, deck: deck, parameter: .filterResonance, value: value, continuous: true)
    }

    func setRate(deck: ControlDeck, multiplier: Double) {
        sendControl(.djRate, deck: deck, parameter: .rate, value: multiplier, continuous: true)
    }

    func jog(deck: ControlDeck, bySeconds seconds: Double) {
        sendControl(.djJog, deck: deck, parameter: .nudge, value: seconds, continuous: true)
    }

    func setHighPassCutoff(deck: ControlDeck, hertz: Double) {
        guard decks.supportsRemoteMixing else { return }
        sendControl(.djFilter, deck: deck, parameter: .highPassCutoff, value: hertz, continuous: true)
    }

    func handBackDecks() {
        guard decks.supportsRemoteMixing else { return }
        sendControl(.djHandBack)
    }

    func attachDecks(_ attached: Bool) {
        let changed = decks.isAttached != attached
        decks.isAttached = attached
        guard decks.supportsRemoteMixing, attached || changed else { return }
        sendControl(.djRemoteAttach, value: attached ? 1 : 0)
    }

    private func sendControl(
        _ type: MessageType,
        deck: ControlDeck = .none,
        parameter: ControlParameter = .none,
        value: Double = 0,
        value2: Double = 0,
        continuous: Bool = false
    ) {
        #if DEBUG
        if isFixture {
            simulateFixtureControl(type, value: value, value2: value2)
            return
        }
        #endif
        if continuous {
            let key = "\(type.rawValue)#\(deck.rawValue)#\(parameter.rawValue)"
            if type == .djJog, let pending = pendingContinuousControls[key] {
                pendingContinuousControls[key] = PendingContinuousControl(
                    type: type, deck: deck, parameter: parameter,
                    value: pending.value + value, value2: value2
                )
            } else {
                pendingContinuousControls[key] = PendingContinuousControl(
                    type: type, deck: deck, parameter: parameter, value: value, value2: value2
                )
            }
            scheduleContinuousFlush()
            return
        }

        guard isReachable else {
            if Self.holdsWhileDisconnected(type) {
                hold(
                    .control(type, deck: deck, parameter: parameter, value: value, value2: value2),
                    key: Self.pendingKey(for: type)
                )
            } else {
                Log.link.info("[CompanionClient] dropped \(type.rawValue, privacy: .public); \(self.linkedName, privacy: .public) isn't connected")
            }
            return
        }

        transmitControl(
            type, deck: deck, parameter: parameter, value: value, value2: value2,
            continuous: type.isContinuousControl
        )
    }

    private func scheduleContinuousFlush() {
        gateway.submit(
            lane: .companionContinuous,
            key: "\(synchronizationID).controls"
        ) { [weak self] in
            guard let self else { return }
            let batch = Array(self.pendingContinuousControls.values)
            self.pendingContinuousControls.removeAll(keepingCapacity: true)
            for control in batch {
                self.transmitControl(
                    control.type,
                    deck: control.deck,
                    parameter: control.parameter,
                    value: control.value,
                    value2: control.value2,
                    continuous: true,
                    bypassGateway: true
                )
            }
        }
    }

    private func transmitControl(
        _ type: MessageType,
        deck: ControlDeck,
        parameter: ControlParameter,
        value: Double,
        value2: Double,
        continuous: Bool,
        bypassGateway: Bool = false
    ) {
        guard let signer, connection != nil, isReachable else { return }

        if continuous { controlSequence &+= 1 }

        let message = signer.control(
            type, deck: deck, parameter: parameter, value: value, value2: value2,
            sequence: continuous ? controlSequence : 0
        )

        if bypassGateway {
            transmitNow(message)
        } else {
            if !continuous { Log.link.info("[CompanionClient] tx \(type.rawValue, privacy: .public)") }
            send(message)
        }
    }
}

extension CompanionClient: PeerContentSessionProvider {
    var peerContentEndpoint: (endpoint: NWEndpoint, sessionId: String, secret: Data)? {
        guard let contentEndpoint, let link, let secret = link.secret else { return nil }
        return (contentEndpoint, link.sessionId, secret)
    }

    func peerContentEndpoint(forDeviceId deviceId: String) -> (endpoint: NWEndpoint, sessionId: String, secret: Data)? {
        guard let link, let secret = link.secret else { return nil }
        let token = PeerContentServer.serviceToken(for: deviceId)
        guard let endpoint = contentEndpointsByDeviceToken[token] else { return nil }
        return (endpoint, link.sessionId, secret)
    }
}

extension QueueTrack {
    init(_ track: Track) {
        self.init(
            id: track.id,
            title: track.title,
            artist: track.user.displayName,
            artworkURL: track.artworkURL,
            duration: track.duration
        )
    }
}

// MARK: - Output

@MainActor
final class OutputRouter: ObservableObject {
    static let moveConfirmationTimeout: Duration = .seconds(5)
    static let lateMoveWindow: Duration = .seconds(30)

    let client: CompanionClient
    private let player: PlayerService
    private let api: SoundCloudAPI

    @Published private(set) var current: OutputDevice = .thisDevice
    @Published private(set) var isMoving = false
    @Published private(set) var notice: String?
    @Published private(set) var entries: [OutputListEntry] = []

    private let preference: OutputPreference
    private let now: () -> Date
    private var presence = OutputPresence()
    private var restore: OutputRestore?
    private var outputsRefreshScheduled = false
    private var outputsWakeTask: Task<Void, Never>?
    private static let outputsDebounce: Duration = .milliseconds(400)

    static func localTracksNotice(on device: OutputDevice, playingHere: Bool) -> String {
        let place = device.deviceClass.displayName
        #if os(macOS)
        let line = "On This Mac tracks can't play on \(place) yet."
        #else
        let line = "Tracks in Files can't play on \(place) yet."
        #endif
        return playingHere ? "Playing on this \(DeviceClass.current.displayName). \(line)" : line
    }

    var sleepTimer: SleepTimerStatus? {
        current.isLocal ? SleepTimer.shared.status : client.sleepTimer
    }

    func setSleepTimer(_ mode: SleepTimerMode?) {
        if current.isLocal {
            if let mode { SleepTimer.shared.start(mode) } else { SleepTimer.shared.cancel() }
        } else {
            client.setSleepTimer(mode)
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var lateMoveGuard: Task<Void, Never>?
    private var routedTrackId: String?
    private var systemSyncScheduled = false
    private var remoteWasAudible = false
    private var localLastPlayedAt: Date?
    private var followScheduled = false

    init(
        client: CompanionClient,
        player: PlayerService = .shared,
        api: SoundCloudAPI = .shared,
        preference: OutputPreference = OutputPreference(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.client = client
        self.player = player
        self.api = api
        self.preference = preference
        self.now = now
        if let saved = preference.savedID, saved != OutputDevice.localID {
            if let linked = client.linkedOutputDevices.first(where: { $0.id == saved }),
               let sessionId = linked.linkSessionId {
                if !client.isActive(sessionId) { client.select(sessionId: sessionId) }
                current = linked
                restore = OutputRestore(savedID: saved, startedAt: now())
                Log.link.info("[OutputRouter] restoring output \(linked.name, privacy: .public)")
            }
        }
        #if DEBUG
        if RemoteFixture.current != nil,
           ProcessInfo.processInfo.environment["SOUNDING_TV_REMOTE_OUTPUT"] == "1",
           let linked = client.linkedOutputDevice {
            current = linked
        }
        #endif
        client.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.reconcileWithLink()
                    self?.scheduleOutputsRefresh()
                }
            }
            .store(in: &cancellables)
        $current
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleSystemNowPlaying()
                Task { @MainActor in self?.refreshOutputs() }
            }
            .store(in: &cancellables)
        player.$currentTrack
            .map { $0?.isLocal == true }
            .removeDuplicates()
            .sink { [weak self] isLocal in
                if !isLocal { self?.notice = nil }
            }
            .store(in: &cancellables)
        client.telemetry.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleSystemNowPlaying()
                self?.scheduleFollowCheck()
            }
            .store(in: &cancellables)
        player.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.localLastPlayedAt = self.now()
            }
            .store(in: &cancellables)
        refreshOutputs()
        scheduleSystemNowPlaying()
    }

    private func scheduleFollowCheck() {
        guard !followScheduled else { return }
        followScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.followScheduled = false
            self.followRemotePlaybackIfIdle()
        }
    }

    private func followRemotePlaybackIfIdle() {
        let playback = client.telemetry.playback
        let audible = client.isReachable && client.telemetry.isLive
            && playback?.isPlaying == true && playback?.trackId != nil
        let wasAudible = remoteWasAudible
        remoteWasAudible = audible
        guard let device = linkedDevice,
              OutputFollow.shouldFollow(
                currentIsLocal: current.isLocal,
                isMoving: isMoving,
                localIsPlaying: player.isPlaying,
                localLastPlayedAt: localLastPlayedAt,
                remoteIsAudible: audible,
                remoteWasAudible: wasAudible,
                now: now()
              ) else { return }
        Log.link.info("[OutputRouter] \(device.name, privacy: .public) is playing and this device isn't; following it")
        select(device, remember: false)
    }

    private func scheduleSystemNowPlaying() {
        guard !systemSyncScheduled else { return }
        systemSyncScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.systemSyncScheduled = false
            self.syncSystemNowPlaying()
        }
    }

    private func syncSystemNowPlaying() {
        guard isRemote else {
            if player.isSystemNowPlayingRouted { player.routeSystemNowPlaying(to: nil) }
            routedTrackId = nil
            return
        }
        let client = self.client
        if !player.isSystemNowPlayingRouted {
            routedTrackId = nil
            player.routeSystemNowPlaying(to: SystemTransportHandlers(
                play: { client.play() },
                pause: { client.pause() },
                togglePlayPause: { client.togglePlayPause() },
                next: { client.next() },
                previous: { client.previous() },
                seek: { client.seek(toSeconds: $0) }
            ))
        }
        guard let playback = client.telemetry.playback, let trackId = playback.trackId else {
            if routedTrackId != nil { player.publishRoutedNowPlaying(nil) }
            routedTrackId = nil
            return
        }
        if routedTrackId != trackId {
            routedTrackId = trackId
            player.publishRoutedNowPlaying(SystemNowPlayingItem(
                trackId: trackId,
                title: playback.title ?? "",
                artist: playback.artist ?? "",
                artworkURL: playback.artworkURL.flatMap(URL.init(string:)),
                queueIndex: nil,
                queueCount: nil
            ))
        }
        player.publishRoutedPlayback(
            SystemPlaybackStatus(
                elapsed: client.telemetry.estimatedPosition(),
                duration: playback.durationSeconds,
                isPlaying: client.telemetry.isPlaying
            ),
            hasNext: !client.upNext.isEmpty
        )
    }

    var linkedDevice: OutputDevice? { client.linkedOutputDevice }

    var linkedDevices: [OutputDevice] { client.linkedOutputDevices }

    var devices: [OutputDevice] { entries.map(\.device) }

    var isRemote: Bool { !current.isLocal }

    var isRestoring: Bool { restore != nil }

    func availability(of device: OutputDevice) -> OutputAvailability? {
        if device.isLocal { return .available }
        return entries.first { $0.id == device.id }?.availability
    }

    func isReachable(_ device: OutputDevice) -> Bool {
        availability(of: device)?.isSelectable ?? false
    }

    // MARK: Presence

    private var liveOutputIDs: Set<String> {
        Set(linkedDevices.compactMap { device -> String? in
            guard let sessionId = device.linkSessionId else { return nil }
            let advertised = client.advertisedSessionIds.contains(sessionId)
            if client.isActive(sessionId) { return client.isReachable || advertised ? device.id : nil }
            return advertised ? device.id : nil
        })
    }

    private func scheduleOutputsRefresh() {
        guard !outputsRefreshScheduled else { return }
        outputsRefreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.outputsDebounce)
            guard let self else { return }
            self.outputsRefreshScheduled = false
            self.refreshOutputs()
        }
    }

    private func refreshOutputs() {
        let moment = now()
        let linked = linkedDevices
        let live = liveOutputIDs
        presence.retain(only: Set(linked.map(\.id)))
        presence.observe(live: live, at: moment)
        resolveRestore(linkedIDs: Set(linked.map(\.id)), liveIDs: live, at: moment)
        let next = OutputList.entries(
            local: .thisDevice,
            linked: linked,
            current: current,
            preferredID: linkedDevice?.id,
            presence: presence,
            at: moment
        )
        if next != entries { entries = next }
        scheduleOutputsWake(after: moment)
    }

    private func resolveRestore(linkedIDs: Set<String>, liveIDs: Set<String>, at moment: Date) {
        guard let pending = restore else { return }
        guard current.id == pending.savedID else {
            restore = nil
            return
        }
        switch pending.decide(linkedIDs: linkedIDs, liveIDs: liveIDs, at: moment) {
        case .wait:
            break
        case .restored:
            restore = nil
            Log.link.info("[OutputRouter] restored output \(self.current.name, privacy: .public)")
        case .fallBack:
            restore = nil
            Log.link.info("[OutputRouter] \(self.current.name, privacy: .public) didn't appear; output stays on this device")
            select(.thisDevice, remember: false)
        }
    }

    private func scheduleOutputsWake(after moment: Date) {
        outputsWakeTask?.cancel()
        outputsWakeTask = nil
        let wake = [presence.nextChange(after: moment), restore?.deadline].compactMap { $0 }.min()
        guard let wake else { return }
        let delay = max(0.1, wake.timeIntervalSince(moment) + 0.05)
        outputsWakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refreshOutputs()
        }
    }

    private func focus(on device: OutputDevice) async -> String? {
        guard let sessionId = device.linkSessionId, linkedDevices.contains(device) else {
            return "\(device.name) isn't linked to this \(DeviceClass.current.displayName)."
        }
        if !client.isActive(sessionId) { client.select(sessionId: sessionId) }
        guard await client.waitUntilReachable(timeout: Self.focusTimeout) else {
            return "\(device.name) isn't reachable right now."
        }
        return nil
    }

    private static let focusTimeout: Duration = .seconds(8)
    private static let remoteStateTimeout: Duration = .seconds(2)

    private func reconcileWithLink() {
        guard !current.isLocal else { return }
        if let linked = linkedDevice, linked.id == current.id {
            if linked != current { current = linked }
            return
        }
        Log.link.info("[OutputRouter] linked device changed; output returns to this device")
        select(.thisDevice, remember: false)
    }

    private func select(_ device: OutputDevice, remember: Bool = true) {
        if remember {
            restore = nil
            preference.remember(device)
            if device.isLocal { localLastPlayedAt = now() }
        }
        guard device != current else { return }
        if !device.isLocal { notice = nil }
        current = device
    }

    @discardableResult
    func move(to device: OutputDevice) async -> String? {
        guard device != current else { return nil }
        guard !isMoving else { return "Playback is already moving." }
        isMoving = true
        defer { isMoving = false }
        lateMoveGuard?.cancel()
        lateMoveGuard = nil

        if device.isLocal {
            return await moveHere()
        }
        if isRemote {
            return await moveBetweenLinked(to: device)
        }
        if player.isPlaying, player.currentTrack?.isLocal == true {
            return Self.localTracksNotice(on: device, playingHere: false)
        }
        if let problem = await focus(on: device) { return problem }
        _ = await client.waitUntilLive(timeout: Self.remoteStateTimeout)

        let remote = client.telemetry.isLive ? client.telemetry.playback : nil
        let handover = OutputHandover.plan(
            localIsPlaying: player.isPlaying,
            localHasTrack: player.currentTrack != nil,
            remoteIsPlaying: remote?.isPlaying == true,
            remoteHasTrack: remote?.trackId != nil
        )
        guard handover == .sendThisDevice, let track = player.currentTrack else {
            Log.link.info("[OutputRouter] output is now \(device.name, privacy: .public); controlling what it plays")
            select(device)
            return nil
        }
        if track.isLocal {
            return Self.localTracksNotice(on: device, playingHere: false)
        }

        let ids = player.queue.filter { !$0.isLocal }.map(\.id)
        let index = ids.indices.contains(player.currentIndex) && ids[player.currentIndex] == track.id
            ? player.currentIndex
            : (ids.firstIndex(of: track.id) ?? 0)
        let trackIds = ids.isEmpty ? [track.id] : ids
        let position = player.currentTime
        let wasPlaying = player.isPlaying
        Log.link.info("[OutputRouter] moving \(trackIds.count, privacy: .public) tracks to \(device.name, privacy: .public) at \(position, privacy: .public)s")
        let outcome = await client.loadConfirmingPlayback(
            trackIds: trackIds,
            startIndex: index,
            positionSeconds: position,
            autoplay: wasPlaying,
            source: player.queueSource,
            timeout: Self.moveConfirmationTimeout
        )
        let here = DeviceClass.current.displayName
        switch outcome {
        case .confirmed:
            if wasPlaying, player.isPlaying, player.currentTrack?.id == track.id,
               abs(player.currentTime - position) > 1 {
                client.seek(toSeconds: player.currentTime)
            }
            player.pause()
            select(device)
            Log.link.info("[OutputRouter] \(device.name, privacy: .public) confirmed playback")
            return nil
        case .rejected(let reason):
            Log.link.info("[OutputRouter] \(device.name, privacy: .public) rejected the move: \(reason, privacy: .public)")
            return "\(device.name) couldn’t play this, so playback stayed on this \(here)."
        case .timedOut:
            Log.link.info("[OutputRouter] \(device.name, privacy: .public) didn't confirm the move in time")
            if wasPlaying { pauseIfMoveLands(trackId: track.id) }
            return "\(device.name) didn’t respond, so playback stayed on this \(here)."
        case .disconnected:
            return "\(device.name) isn't reachable right now."
        }
    }

    private func moveBetweenLinked(to device: OutputDevice) async -> String? {
        let ids = client.tracks.map(\.id)
        let playback = client.telemetry.playback
        let wasPlaying = client.telemetry.isPlaying
        let position = client.telemetry.estimatedPosition()
        let index = playback?.trackId.flatMap { ids.firstIndex(of: $0) } ?? client.currentIndex
        if wasPlaying { client.pause() }
        select(.thisDevice)
        if let problem = await focus(on: device) { return problem }
        guard !ids.isEmpty, ids.indices.contains(index) else {
            select(device)
            return nil
        }
        let outcome = await client.loadConfirmingPlayback(
            trackIds: ids,
            startIndex: index,
            positionSeconds: position,
            autoplay: wasPlaying,
            source: client.queueSource,
            timeout: Self.moveConfirmationTimeout
        )
        switch outcome {
        case .confirmed:
            select(device)
            return nil
        case .rejected:
            return "\(device.name) couldn’t play this."
        case .timedOut:
            return "\(device.name) didn’t respond."
        case .disconnected:
            return "\(device.name) isn't reachable right now."
        }
    }

    private func pauseIfMoveLands(trackId: String) {
        lateMoveGuard = Task { @MainActor [client] in
            let outcome = await client.awaitPlayback(trackId: trackId, timeout: Self.lateMoveWindow)
            guard outcome == .confirmed, !Task.isCancelled else { return }
            Log.link.info("[OutputRouter] a timed-out move landed late; pausing the remote copy")
            client.pause()
        }
    }

    private func moveHere() async -> String? {
        let remoteName = current.name
        guard let playback = client.telemetry.playback, let trackId = playback.trackId else {
            select(.thisDevice)
            return nil
        }
        let remoteIDs = client.tracks.map(\.id)
        let tracksByID = await Self.fetchTracks(ids: remoteIDs, currentTrackID: trackId, api: api)
        if let latest = client.telemetry.playback?.trackId, latest != trackId {
            return await moveHere()
        }
        guard let track = tracksByID[trackId] else {
            return "Couldn't load the \(remoteName) track on this \(DeviceClass.current.displayName)."
        }
        var queue: [Track] = []
        var playingIndex: Int?
        for (offset, id) in remoteIDs.enumerated() {
            guard let resolved = tracksByID[id] else { continue }
            if offset == client.currentIndex, id == trackId { playingIndex = queue.count }
            queue.append(resolved)
        }
        if playingIndex == nil {
            playingIndex = queue.firstIndex(where: { $0.id == trackId })
        }
        if playingIndex == nil {
            queue.insert(track, at: 0)
            playingIndex = 0
        }
        let index = playingIndex ?? 0

        let wasLive = client.telemetry.isLive
        let autoplay = wasLive && (client.telemetry.playback?.isPlaying ?? playback.isPlaying)
        let position = client.telemetry.estimatedPosition()
        if wasLive { client.pause() }
        select(.thisDevice)
        Log.link.info("[OutputRouter] moving \(queue.count, privacy: .public) tracks from \(remoteName, privacy: .public) here at \(position, privacy: .public)s")
        await player.adoptOutputSession(
            track: track,
            queue: queue,
            index: index,
            position: position,
            autoplay: autoplay
        )
        return player.playbackErrorMessage
    }

    nonisolated private static func fetchTracks(
        ids: [String],
        currentTrackID: String,
        api: SoundCloudAPI
    ) async -> [String: Track] {
        var tracksByID: [String: Track] = [:]
        for offset in stride(from: 0, to: ids.count, by: 50) {
            let end = min(offset + 50, ids.count)
            let batch = Array(ids[offset..<end])
            guard let tracks = try? await api.getTracks(ids: batch) else { continue }
            for track in tracks { tracksByID[track.id] = track }
        }
        if tracksByID[currentTrackID] == nil,
           let current = try? await api.getTrack(id: currentTrackID) {
            tracksByID[current.id] = current
        }
        return tracksByID
    }

    // MARK: Transport

    func play() {
        isRemote ? client.play() : player.play()
    }

    func pause() {
        if player.isPlaying || !isRemote { player.pause() }
        if isRemote { client.pause() }
    }

    func next() {
        if isRemote { client.next() } else { Task { await player.playNext() } }
    }

    func previous() {
        if isRemote { client.previous() } else { Task { await player.playPrevious() } }
    }

    func seek(to seconds: TimeInterval) {
        isRemote ? client.seek(toSeconds: seconds) : player.seek(to: seconds)
    }

    // MARK: Modes

    var canChangePlaybackModes: Bool { !isRemote || client.canChangePlaybackModes }

    var isShuffleEnabled: Bool {
        isRemote ? client.telemetry.playbackModes?.isShuffleEnabled == true : player.isShuffleEnabled
    }

    var repeatMode: RepeatMode {
        guard isRemote else { return player.repeatMode }
        return client.telemetry.playbackModes?.remoteRepeatMode.flatMap { RepeatMode(rawValue: $0.rawValue) } ?? .off
    }

    func toggleShuffle() {
        if isRemote { client.setShuffle(!isShuffleEnabled) } else { player.toggleShuffle() }
    }

    func cycleRepeatMode() {
        guard isRemote else {
            player.cycleRepeatMode()
            return
        }
        let next: RemoteRepeatMode
        switch repeatMode {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        client.setRepeat(next)
    }

    // MARK: Queue

    @discardableResult
    func play(_ track: Track, in context: [Track], collectionId: String? = nil) async -> String? {
        await play(track, in: context, collectionId: collectionId, source: nil)
    }

    @discardableResult
    func play(_ track: Track, in context: [Track], collectionId: String?, source: PlaybackQueueSource?) async -> String? {
        guard isRemote else {
            await player.play(track, in: context, collectionId: collectionId, source: source)
            return player.playbackErrorMessage
        }
        if track.isLocal {
            return await playHere(track, in: context, collectionId: collectionId, source: source, instead: current)
        }
        if !client.isReachable, client.connectionPhase == .connecting {
            _ = await client.waitUntilReachable(timeout: Self.focusTimeout)
        }
        guard client.isReachable else { return "\(current.name) isn't reachable right now." }
        if let source { PlaybackQueueSourceDirectory.note(source) }
        var ids = context.filter { !$0.isLocal }.map(\.id)
        if !ids.contains(track.id) { ids.insert(track.id, at: 0) }
        let index = ids.firstIndex(of: track.id) ?? 0
        client.load(
            trackIds: ids, startIndex: index, positionSeconds: 0, autoplay: true,
            source: source ?? PlaybackQueueSourceDirectory.source(for: collectionId)
        )
        return nil
    }

    private func playHere(
        _ track: Track,
        in context: [Track],
        collectionId: String?,
        source: PlaybackQueueSource?,
        instead device: OutputDevice
    ) async -> String? {
        if isRemote {
            if client.telemetry.isPlaying { client.pause() }
            select(.thisDevice)
        }
        await player.play(track, in: context, collectionId: collectionId, source: source)
        notice = Self.localTracksNotice(on: device, playingHere: true)
        return player.playbackErrorMessage
    }

    var playOnDevice: OutputDevice? { playOnDevices.first }

    var playOnDevices: [OutputDevice] {
        entries.filter { !$0.device.isLocal && $0.id != current.id && $0.availability.isSelectable }.map(\.device)
    }

    @discardableResult
    func play(_ track: Track, in context: [Track], on device: OutputDevice, source: PlaybackQueueSource? = nil) async -> String? {
        guard !device.isLocal else { return await play(track, in: context, collectionId: nil, source: source) }
        if track.isLocal {
            return await playHere(track, in: context, collectionId: nil, source: source, instead: device)
        }
        guard !isMoving else { return "Playback is already moving." }
        isMoving = true
        defer { isMoving = false }
        lateMoveGuard?.cancel()
        lateMoveGuard = nil
        if isRemote, current != device { select(.thisDevice) }
        if let problem = await focus(on: device) { return problem }

        var ids = context.filter { !$0.isLocal }.map(\.id)
        if !ids.contains(track.id) { ids.insert(track.id, at: 0) }
        let index = ids.firstIndex(of: track.id) ?? 0
        Log.link.info("[OutputRouter] playing \(ids.count, privacy: .public) tracks on \(device.name, privacy: .public)")
        let outcome = await client.loadConfirmingPlayback(
            trackIds: ids,
            startIndex: index,
            positionSeconds: 0,
            autoplay: true,
            source: source,
            timeout: Self.moveConfirmationTimeout
        )
        switch outcome {
        case .confirmed:
            player.pause()
            select(device)
            return nil
        case .rejected:
            return "\(device.name) couldn’t play this."
        case .timedOut:
            return "\(device.name) didn’t respond."
        case .disconnected:
            return "\(device.name) isn't reachable right now."
        }
    }

    @discardableResult
    func play(shuffled tracks: [Track], collectionId: String? = nil) async -> String? {
        await play(shuffled: tracks, collectionId: collectionId, source: nil)
    }

    @discardableResult
    func play(shuffled tracks: [Track], collectionId: String?, source: PlaybackQueueSource?) async -> String? {
        guard let start = tracks.randomElement() else { return "There are no playable tracks here." }
        guard isRemote else {
            player.isShuffleEnabled = true
            await player.play(start, in: tracks, collectionId: collectionId, source: source)
            return player.playbackErrorMessage
        }
        guard let pick = tracks.filter({ !$0.isLocal }).randomElement() else {
            player.isShuffleEnabled = true
            return await playHere(start, in: tracks, collectionId: collectionId, source: source, instead: current)
        }
        var rest = tracks.filter { $0.id != pick.id && !$0.isLocal }
        rest.shuffle()
        return await play(pick, in: [pick] + rest, collectionId: collectionId, source: source)
    }

    func playNext(_ track: Track) {
        if isRemote, track.isLocal {
            notice = Self.localTracksNotice(on: current, playingHere: false)
        } else if isRemote {
            client.playNext(trackId: track.id, optimistic: QueueTrack(track))
        } else if player.queue.isEmpty {
            Task { await player.play(track, in: [track]) }
        } else {
            player.insertIntoQueue(track, at: player.currentIndex + 1)
        }
    }

    func addToQueue(_ track: Track) {
        if isRemote, track.isLocal {
            notice = Self.localTracksNotice(on: current, playingHere: false)
        } else if isRemote {
            client.addToQueue(trackId: track.id, optimistic: QueueTrack(track))
        } else {
            player.addToQueue(track)
        }
    }

    func insertIntoQueue(_ tracks: [Track], at index: Int) {
        if isRemote {
            var position = index
            for track in tracks {
                if track.isLocal {
                    notice = Self.localTracksNotice(on: current, playingHere: false)
                    continue
                }
                client.addToQueue(trackId: track.id, atIndex: position, optimistic: QueueTrack(track))
                position += 1
            }
        } else if player.queue.isEmpty {
            guard let first = tracks.first else { return }
            Task { await player.play(first, in: tracks) }
        } else {
            var position = index
            for track in tracks {
                player.insertIntoQueue(track, at: position)
                position += 1
            }
        }
    }

    func moveQueueItem(from source: Int, to destination: Int) {
        isRemote ? client.move(from: source, to: destination) : player.moveQueueItem(from: source, to: destination)
    }

    func removeQueueItem(at index: Int) {
        if isRemote { client.remove(at: index) } else { Task { await player.removeFromQueue(at: index) } }
    }

    func jump(to index: Int) {
        if isRemote { client.jump(to: index) } else { Task { await player.playTrackAt(index: index) } }
    }
}

// MARK: - Sign out

@MainActor
enum AccountSignOut {
    static func devicesStayingSignedIn(client: CompanionClient) -> [String] {
        var names = client.links.map(\.peerName)
        let local = CompanionRegistry.shared.localDeviceId
        for peer in CompanionRegistry.shared.peers where peer.deviceId != local && peer.deviceClass != .tv {
            if !names.contains(peer.displayName) { names.append(peer.displayName) }
        }
        return names
    }

    static func tokenIsShared(client: CompanionClient) async -> Bool {
        if !devicesStayingSignedIn(client: client).isEmpty { return true }
        return await SynchronizationCoordinator.shared.latestSyncedSession() != nil
    }

    static func signOutThisDevice(client: CompanionClient, credentials: SoundCloudCredentialSource) async {
        let shared = await tokenIsShared(client: client)
        await credentials.signOutThisDevice(tokenIsShared: shared)
    }

    static func stayingSignedInMessage(client: CompanionClient) -> String? {
        let names = devicesStayingSignedIn(client: client)
        guard !names.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: Array(names.prefix(3)) + (names.count > 3 ? ["\(names.count - 3) more"] : []))
        return "\(list) \(names.count == 1 ? "stays" : "stay") signed in."
    }

    static func everywhereMessage(client: CompanionClient) -> String {
        "Signs you out of SoundCloud in Sounding on all your devices."
    }

    static func signOutEverywhere(client: CompanionClient, credentials: SoundCloudCredentialSource) async {
        let accountId = credentials.currentUser?.id ?? SubscriptionService.shared.authenticatedAccountID
        let lineage = SessionSyncBookkeeping.lineageDigest(refreshToken: DeviceSessionStore.load()?.refreshToken)
        client.queueSignOutEverywhere(accountId: accountId, lineageDigest: lineage)
        await SynchronizationCoordinator.shared.clearSyncedSession()
        await credentials.signOutEverywhere()
    }
}

#if DEBUG
enum RemoteFixture: String {
    case playing
    case paused
    case nothing
    case needsSignIn
    case connecting
    case reconnecting
    case unreachable
    case unlinked

    static let current: RemoteFixture? = ProcessInfo.processInfo.environment["SOUNDING_TV_REMOTE_FIXTURE"].flatMap(RemoteFixture.init(rawValue:))

    static var hasSecondTV: Bool {
        ProcessInfo.processInfo.environment["SOUNDING_TV_REMOTE_FIXTURE_TVS"] == "2"
    }
}

extension CompanionClient {
    fileprivate func installRemoteFixture(_ fixture: RemoteFixture) {
        isFixture = true
        if fixture != .unlinked {
            let livingRoom = LinkedCompanionStore.LinkRecord(
                sessionId: "fixture",
                secretBase64: Data(repeating: 7, count: 32).base64EncodedString(),
                pairedAt: .now,
                deviceClass: .tv,
                displayName: "Living Room"
            )
            link = livingRoom
            links = [livingRoom]
            if RemoteFixture.hasSecondTV {
                let bedroom = LinkedCompanionStore.LinkRecord(
                    sessionId: "fixture-bedroom",
                    secretBase64: Data(repeating: 9, count: 32).base64EncodedString(),
                    pairedAt: .now.addingTimeInterval(-86_400),
                    deviceClass: .tv,
                    displayName: "Bedroom"
                )
                links.append(bedroom)
                advertisedSessionIds = [livingRoom.sessionId, bedroom.sessionId]
            }
        }
        switch fixture {
        case .unlinked:
            link = nil
            links = []
            state = .unlinked
        case .connecting:
            state = .connecting
        case .nothing:
            state = .connected
            telemetry.isLive = true
        case .needsSignIn:
            state = .connected
            peerNeedsSignIn = true
        case .playing, .paused, .reconnecting, .unreachable:
            tracks = ([VisualFixtures.nowPlayingMix] + VisualFixtures.tracks.prefix(7)).map(QueueTrack.init)
            currentIndex = 0
            playingNextCount = ProcessInfo.processInfo.environment["SOUNDING_TV_FIXTURE_PLAYING_NEXT"].flatMap(Int.init) ?? 0
            reportsPlayingNext = true
            hasSnapshot = true
            queueSource = PlaybackQueueSource(id: nil, kind: .playlist, title: "Late Night Drive")
            state = .connected
            publishFixtureFrame(index: 0, position: 1834, isPlaying: fixture != .paused)
            if fixture == .reconnecting {
                state = .connecting
                telemetry.isLive = false
            }
            if fixture == .unreachable {
                state = .failed(.notFound)
                telemetry.isLive = false
            }
        }
    }

    private func publishFixtureFrame(index: Int, position: TimeInterval, isPlaying: Bool) {
        guard tracks.indices.contains(index) else { return }
        let track = tracks[index]
        fixtureRevision += 1
        ingest(PlaybackStatePayload(
            isPlaying: isPlaying,
            positionSeconds: track.duration > 0 ? min(track.duration, max(0, position)) : max(0, position),
            durationSeconds: track.duration,
            trackId: track.id,
            title: track.title,
            artist: track.artist,
            artworkURL: track.artworkURL?.absoluteString,
            isDJEngineLive: false,
            revision: fixtureRevision,
            issuedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            signature: "",
            modes: PlaybackModesPayload(
                isShuffleEnabled: fixtureShuffle,
                repeatMode: fixtureRepeat.rawValue,
                signature: ""
            ),
            volume: fixtureVolume,
            sleepTimer: fixtureSleepTimer.map {
                SleepTimerStatePayload(
                    kind: Int($0.mode.wireKind),
                    minutes: Int($0.mode.wireMinutes),
                    endsAtMillis: $0.endsAt.map { Int64($0.timeIntervalSince1970 * 1000) },
                    signature: ""
                )
            }
        ))
    }

    private func fixtureIndex() -> Int {
        RemoteQueueProjection.playingIndex(
            tracks: tracks,
            currentIndex: currentIndex,
            presentedTrackId: observedPlayback?.trackId
        ) ?? currentIndex
    }

    fileprivate func simulateFixtureControl(_ type: MessageType, value: Double, value2: Double = 0) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, let observed = self.observedPlayback else { return }
            let position = observed.estimatedPosition(elapsed: Date().timeIntervalSince(self.observedAt))
            let index = self.fixtureIndex()
            switch type {
            case .transportPlay:
                self.publishFixtureFrame(index: index, position: position, isPlaying: true)
            case .transportPause:
                self.publishFixtureFrame(index: index, position: position, isPlaying: false)
            case .transportSeek:
                self.publishFixtureFrame(index: index, position: value, isPlaying: observed.isPlaying)
            case .transportNext:
                let next = min(index + 1, self.tracks.count - 1)
                self.currentIndex = next
                self.publishFixtureFrame(index: next, position: 0, isPlaying: true)
            case .transportVolume:
                self.fixtureVolume = min(1, max(0, value))
                self.publishFixtureFrame(index: index, position: position, isPlaying: observed.isPlaying)
            case .transportSleepTimer:
                self.fixtureSleepTimer = SleepTimerMode(wireKind: value, minutes: value2).map { mode in
                    let track = self.tracks.indices.contains(index) ? self.tracks[index] : nil
                    let seconds: TimeInterval
                    if case .minutes(let minutes) = mode {
                        seconds = TimeInterval(minutes) * 60
                    } else {
                        seconds = max(0, (track?.duration ?? 0) - position)
                    }
                    return SleepTimerStatus(mode: mode, endsAt: Date().addingTimeInterval(seconds))
                }
                self.publishFixtureFrame(index: index, position: position, isPlaying: observed.isPlaying)
            case .transportShuffle:
                self.fixtureShuffle = value != 0
                self.publishFixtureFrame(index: index, position: position, isPlaying: observed.isPlaying)
            case .transportRepeat:
                self.fixtureRepeat = RemoteRepeatMode(wireValue: value) ?? .off
                self.publishFixtureFrame(index: index, position: position, isPlaying: observed.isPlaying)
            case .transportPrevious:
                let previous = position > RemotePlaybackIntents.restartThreshold ? index : max(0, index - 1)
                self.currentIndex = previous
                self.publishFixtureFrame(index: previous, position: 0, isPlaying: true)
            default:
                break
            }
        }
    }

    fileprivate func simulateFixtureQueue(_ type: MessageType, fromIndex: Int) {
        guard type == .queueJump else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.publishFixtureFrame(index: fromIndex, position: 0, isPlaying: true)
        }
    }
}
#endif
