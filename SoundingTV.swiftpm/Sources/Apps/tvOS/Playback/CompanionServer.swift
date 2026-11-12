import Foundation
import Network
import Combine
import Security
import os

@MainActor
final class CompanionServer: ObservableObject {
    static let shared = CompanionServer()

    static let maximumClients = 8
    static let pingInterval: Duration = .seconds(5)
    static let liveDeckRefreshInterval: Duration = .seconds(2)
    static let remoteDecksInterval: Duration = .milliseconds(100)
    static let remoteDecksLease: Duration = .seconds(12)
    static let driftTolerance: TimeInterval = 1.0

    @Published private(set) var devices: [LinkedDevice] = []

    @Published private(set) var connectedSessionIds: Set<String> = []

    @Published private(set) var isPhoneConnected = false

    @Published private(set) var connectedClientCount = 0

    @Published private(set) var lastError: String?
    @Published private(set) var authHandoffDeviceName: String?
    private var authHandoffID: UUID?

    @Published private(set) var decksRemote: DecksRemote?

    @Published private(set) var controllerAccounts: [String: PeerAccount] = [:]
    @Published private(set) var accountNotice: AccountNotice?
    @Published private(set) var switchRequest: TVAccountSwitchGate.Request?
    @Published private(set) var switchingTo: PeerAccount?

    struct AccountNotice: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let symbol: String
    }

    static let lastAccountKey = "red.forbes.sounding.tv.lastAccount.v1"

    struct DecksRemote: Equatable {
        var name: String
        var touchedAt: Date?
    }

    var isLinked: Bool { !devices.isEmpty }

    private final class TrustedSession {
        let sessionId: String
        let secret: Data
        let contentServer: PeerContentServer
        var listener: NWListener?
        var listenerRestart: Task<Void, Never>?
        var isListening = false
        var replayGuard = ReplayGuard()
        var sessionReplayGuard = ReplayGuard()
        var cueReplayGuard = ReplayGuard()
        var likesReplayGuard = ReplayGuard()
        var localMusicReplayGuard = ReplayGuard()
        var continueSessionReplayGuard = ReplayGuard()
        var analysisReplayGuard = ReplayGuard()

        init(sessionId: String, secret: Data, contentServer: PeerContentServer) {
            self.sessionId = sessionId
            self.secret = secret
            self.contentServer = contentServer
        }

        func cancelNetwork() {
            listenerRestart?.cancel()
            listenerRestart = nil
            listener?.cancel()
            listener = nil
            isListening = false
        }
    }

    private final class Peer {
        let id: Int
        let connection: NWConnection
        let ownerID: String
        let sessionId: String
        var framer = MessageFramer()
        var sequenceGate = SequenceGate()
        var cuePushHighWaterMark: Int64 = 0
        var isReady = false
        var hasContinueSession = false
        var sendsHeartbeats = false
        let connectedAt = ContinuousClock.now
        var lastActivityAt = ContinuousClock.now
        var decksLeaseUntil: ContinuousClock.Instant?
        var announcedAccount = false

        init(id: Int, connection: NWConnection, ownerID: String, sessionId: String) {
            self.id = id
            self.connection = connection
            self.ownerID = ownerID
            self.sessionId = sessionId
        }
    }

    private struct PlaybackAnchor {
        let position: TimeInterval
        let date: Date
        let rate: Double
        let isPlaying: Bool

        func expectedPosition(at now: Date) -> TimeInterval {
            isPlaying ? position + now.timeIntervalSince(date) * rate : position
        }
    }

    private nonisolated(unsafe) var sessions: [String: TrustedSession] = [:]
    private nonisolated(unsafe) var peers: [Int: Peer] = [:]
    private nonisolated(unsafe) var contentBrowser: NWBrowser?
    private var nextPeerID = 0

    private let player: PlayerService
    private let downloads: DownloadManager
    private let synchronization: SynchronizationCoordinator
    private let gateway: SynchronizationGateway
    private let scheduler: WorkScheduler
    private let api: SoundCloudAPI
    private let store: LinkedDeviceStore
    private let revokedStore: RevokedLinkStore
    private var beacons: [String: LinkRevocationBeacon] = [:]
    private var contentBrowseResults: Set<NWBrowser.Result> = []
    private var remoteContentEndpoints: [String: (endpoint: NWEndpoint, sessionId: String)] = [:]
    private var cancellables = Set<AnyCancellable>()

    private let synchronizationID = "companion.server.\(UUID().uuidString)"

    private var queueRevision = 0
    private var playbackRevision = 0
    private var djRevision = 0
    private var queueFingerprint: Int?
    private var playbackFingerprint: Int?
    private var djFingerprint: Int?
    private var queueFrames: [String: Data] = [:]
    private var playbackFrames: [String: Data] = [:]
    private var djFrames: [String: Data] = [:]
    private var pendingQueueBump = false
    private var pendingPlaybackForce = false
    private var pendingDJForce = false
    private var anchor: PlaybackAnchor?
    private var decksVisibleCount = 0
    private var isStreamingDecks = false

    private let commands = CompanionCommandPipeline()

    private var pendingAuthHandoffSessionContinuation: CheckedContinuation<AuthHandoffSessionOfferPayload?, Never>?

    private let credentials: SoundCloudCredentialSource
    private var signInObservation: AnyCancellable?
    private var announcedNeedsSignIn: Bool?
    private var announcedAccountStatus: String?
    private var switchGate = TVAccountSwitchGate()
    private var switchExpiry: Task<Void, Never>?

    private init(
        player: PlayerService = .shared,
        downloads: DownloadManager = .shared,
        synchronization: SynchronizationCoordinator = .shared,
        gateway: SynchronizationGateway = .shared,
        scheduler: WorkScheduler = .shared,
        api: SoundCloudAPI = .shared,
        store: LinkedDeviceStore = LinkedDeviceStore(),
        revokedStore: RevokedLinkStore = RevokedLinkStore(),
        credentials: SoundCloudCredentialSource = .shared
    ) {
        self.player = player
        self.downloads = downloads
        self.synchronization = synchronization
        self.gateway = gateway
        self.scheduler = scheduler
        self.api = api
        self.store = store
        self.revokedStore = revokedStore
        self.credentials = credentials
        signInObservation = credentials.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.announceDeviceStatusIfChanged()
                self?.announceAccountStatusIfChanged()
            }
        RemoteLocalMusic.shared.endpoints = self
        RemoteLocalMusic.shared.requestOffers = { [weak self] in self?.requestLocalMusicOffers() }
    }

    deinit {
        cancelNetworkResources()
    }

    private nonisolated func cancelNetworkResources() {
        for peer in peers.values { peer.connection.cancel() }
        for session in sessions.values {
            session.listenerRestart?.cancel()
            session.listener?.cancel()
        }
        contentBrowser?.cancel()
    }

    func pair(with credentials: SessionCredentials, identity: LinkPeerIdentity? = nil) {
        var device = LinkedDevice(sessionId: credentials.sessionId, secret: credentials.secret)
        if let identity, identity.verify(sessionId: credentials.sessionId, secret: credentials.secret) {
            _ = device.adopt(identity)
        }
        let change = store.add(device)
        revokedStore.settle(sessionId: credentials.sessionId)
        devices = change.devices
        for removed in change.removed { revokeWithNotice(removed, reason: "replaced by a newer link", revokeReason: .replaced) }
        activate(sessionId: credentials.sessionId, secret: credentials.secret)
        Log.link.info("[CompanionServer] linked a device; \(change.devices.count, privacy: .public) linked")
    }

    func startIfPaired() {
        Self.discardLegacyPairingOffer()
        for link in revokedStore.load() where beacons[link.sessionId] == nil {
            startBeacon(for: link)
        }
        guard sessions.isEmpty else { return }
        devices = store.load()
        for device in devices {
            guard let secret = device.secret else { continue }
            activate(sessionId: device.sessionId, secret: secret)
        }
    }

    func forget(_ device: LinkedDevice) {
        let change = store.revoke(sessionId: device.sessionId)
        devices = change.devices
        RemoteLocalMusic.shared.forget(sessionId: device.sessionId)
        revokeWithNotice(device, reason: "forgotten", revokeReason: .forgotten)
        controllerAccounts[device.sessionId] = nil
        Log.link.info("[CompanionServer] forgot a device; \(change.devices.count, privacy: .public) linked")
    }

    func unpair() {
        let forgotten = devices.isEmpty ? store.load() : devices
        store.removeAll()
        devices = []
        for device in forgotten { RemoteLocalMusic.shared.forget(sessionId: device.sessionId) }
        for device in forgotten { revokeWithNotice(device, reason: "signed out", revokeReason: .signedOut) }
        controllerAccounts = [:]
        for sessionId in Array(sessions.keys) where !forgotten.contains(where: { $0.sessionId == sessionId }) {
            deactivate(sessionId: sessionId, reason: "signed out")
        }
    }

    private func revokeWithNotice(_ device: LinkedDevice, reason: String, revokeReason: LinkRevokePayload.Reason) {
        guard let secret = device.secret,
              let frame = try? TokenTransferMessage.linkRevoke(sessionId: device.sessionId, secret: secret, reason: revokeReason).framed() else {
            deactivate(sessionId: device.sessionId, reason: reason)
            return
        }
        let ready = peers.values.filter { $0.sessionId == device.sessionId && $0.isReady }
        guard !ready.isEmpty else {
            deactivate(sessionId: device.sessionId, reason: reason)
            startBeacon(for: RevokedLink(device, reason: revokeReason))
            return
        }
        let tally = RevokeTally(remaining: ready.count)
        let sessionId = device.sessionId
        for peer in ready {
            peer.connection.send(content: frame, completion: .contentProcessed { error in
                Task { @MainActor [weak self] in
                    guard let self, tally.record(delivered: error == nil) else { return }
                    self.deactivate(sessionId: sessionId, reason: reason)
                    if !tally.delivered { self.startBeacon(for: RevokedLink(device, reason: revokeReason)) }
                }
            })
        }
    }

    private func startBeacon(for link: RevokedLink) {
        revokedStore.add(link)
        beacons[link.sessionId]?.cancelNetwork()
        let beacon = LinkRevocationBeacon(link: link) { [weak self] sessionId in
            guard let self else { return }
            self.revokedStore.settle(sessionId: sessionId)
            self.beacons[sessionId]?.cancelNetwork()
            self.beacons[sessionId] = nil
            Log.link.info("[CompanionServer] a forgotten device acknowledged it was removed")
        }
        beacons[link.sessionId] = beacon
        beacon.start()
    }

    private static func discardLegacyPairingOffer() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "red.forbes.sounding.pairing-offer",
        ]
        SoundingKeychain.delete(query)
    }

    func requestAuthHandoffSession() async -> AuthHandoffSessionOfferPayload? {
        guard !readyPeers.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            pendingAuthHandoffSessionContinuation = continuation
            for peer in readyPeers {
                send(.authHandoffSessionRequest(sessionId: peer.sessionId), to: peer)
            }

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, let pending = self.pendingAuthHandoffSessionContinuation else { return }
                self.pendingAuthHandoffSessionContinuation = nil
                pending.resume(returning: nil)
            }
        }
    }

    private func adoptAuthHandoffSession(_ offer: AuthHandoffSessionOfferPayload, from peer: Peer) {
        let handoffID = UUID()
        authHandoffID = handoffID
        authHandoffDeviceName = devices.first(where: { $0.sessionId == peer.sessionId })?.displayName ?? "your device"
        let provisional = StoredSession(
            oauthToken: offer.oauthToken,
            refreshToken: offer.refreshToken,
            clientId: offer.clientId,
            expiresAt: offer.expiresAtMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        )
        Task { @MainActor in
            defer {
                if self.authHandoffID == handoffID {
                    self.authHandoffID = nil
                    self.authHandoffDeviceName = nil
                }
            }
            let session: StoredSession
            if provisional.isExpired {
                guard let refreshed = await DeviceSessionRefresher.shared.refresh(
                    provisional, trigger: "companion handoff, offered pair expired", adoptsNewerStored: false
                ) else {
                    Log.link.error("[CompanionServer] companion handoff token could not be refreshed, refusing it")
                    return
                }
                session = refreshed
            } else {
                guard case .valid = await SoundCloudAPI.shared.validateToken(provisional.oauthToken) else {
                    Log.link.error("[CompanionServer] companion handoff token was not accepted, refusing it")
                    return
                }
                session = provisional
            }
            guard self.authHandoffID == handoffID, !Task.isCancelled else { return }
            SessionProvenance.record(.guest)
            DeviceSessionStore.save(session)
            DeviceSessionRefresher.shared.reset()
            SoundCloudCredentialSource.shared.didCompleteSignIn()
            Log.link.info("[CompanionServer] adopted the auth handoff session from the companion")
            _ = await SoundCloudCredentialSource.shared.waitForCurrentUser()
            await Task.yield()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, self.authHandoffID == handoffID else { return }
            self.authHandoffID = nil
            self.authHandoffDeviceName = nil
        }
    }

    func stop() {
        authHandoffID = nil
        authHandoffDeviceName = nil
        for peer in Array(peers.values) { removePeer(peer, reason: "stopped") }
        for session in Array(sessions.values) {
            session.cancelNetwork()
            session.contentServer.stop()
        }
        sessions.removeAll()
        stopSharedWork()
    }

    private func stopSharedWork() {
        commands.cancelAll()
        contentBrowser?.cancel()
        contentBrowser = nil
        contentBrowseResults = []
        remoteContentEndpoints.removeAll()
        scheduler.cancelPeriodic(id: "\(synchronizationID).ping")
        scheduler.cancelPeriodic(id: "\(synchronizationID).decks")
        scheduler.cancelPeriodic(id: "\(synchronizationID).remoteDecks")
        isStreamingDecks = false
        gateway.cancel(keyPrefix: synchronizationID)
        cancellables.removeAll()
        resetStateFrames()
        synchronization.unregisterNearbySink(id: synchronizationID)
        ContinueFrom.shared.unregisterRelay(id: synchronizationID)
        updateConnectedCount()
    }

    private func resetStateFrames() {
        queueFingerprint = nil
        playbackFingerprint = nil
        djFingerprint = nil
        queueFrames = [:]
        playbackFrames = [:]
        djFrames = [:]
        pendingQueueBump = false
        pendingPlaybackForce = false
        pendingDJForce = false
        anchor = nil
    }

    private func activate(sessionId: String, secret: Data) {
        sessions[sessionId]?.cancelNetwork()
        sessions[sessionId]?.contentServer.stop()
        let session = TrustedSession(
            sessionId: sessionId,
            secret: secret,
            contentServer: PeerContentServer(resolveFile: { [downloads] trackID in
                await downloads.peerContentSource(forTrackId: trackID)
            })
        )
        sessions[sessionId] = session
        resetStateFrames()
        startListener(for: session)
        startContentServer(for: session)
        startContentBrowsing()
        recomputeContentEndpoints()
        observePlayer()
        startPeriodicWork()
        synchronization.registerNearbySink(id: synchronizationID) { [weak self] domain in
            if domain == .cues { self?.pushCueChanges() }
        }
        ContinueFrom.shared.registerRelay(id: synchronizationID) { [weak self] session in
            self?.broadcastContinueSession(session)
        }
    }

    private func deactivate(sessionId: String, reason: String) {
        for peer in Array(peers.values) where peer.sessionId == sessionId {
            removePeer(peer, reason: reason)
        }
        guard let session = sessions.removeValue(forKey: sessionId) else { return }
        session.cancelNetwork()
        session.contentServer.stop()
        resetStateFrames()
        recomputeContentEndpoints()
        if sessions.isEmpty { stopSharedWork() }
    }

    private func startContentServer(for session: TrustedSession) {
        do {
            try session.contentServer.start(
                sessionId: session.sessionId,
                secret: session.secret,
                deviceId: DownloadManifestDeviceIdentity.deviceId()
            )
        } catch {
            lastError = "Failed to start content server: \(error.localizedDescription)"
        }
    }

    private func startContentBrowsing() {
        guard contentBrowser == nil else { return }
        let browser = CompanionEndpoint.makeBrowser()
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                self.contentBrowseResults = results
                self.recomputeContentEndpoints()
            }
        }
        contentBrowser = browser
        browser.start(queue: .main)
    }

    private func recomputeContentEndpoints() {
        let ownNames = Set(sessions.values.compactMap(\.contentServer.advertisedServiceName))
        var endpoints: [String: (endpoint: NWEndpoint, sessionId: String)] = [:]
        for result in contentBrowseResults {
            guard case .service(let name, _, _, _) = result.endpoint, !ownNames.contains(name) else { continue }
            for sessionId in sessions.keys.sorted() {
                guard let token = PeerContentServer.serviceToken(fromServiceName: name, sessionId: sessionId) else { continue }
                endpoints[token] = (result.endpoint, sessionId)
                break
            }
        }
        remoteContentEndpoints = endpoints
        RemoteLocalMusic.shared.endpointsChanged()
    }

    private func startListener(for session: TrustedSession) {
        session.cancelNetwork()

        do {
            let newListener = try NWListener(
                using: CompanionEndpoint.listenerParameters(sessionId: session.sessionId, secret: session.secret)
            )
            newListener.service = NWListener.Service(
                name: CompanionEndpoint.serviceName(sessionId: session.sessionId),
                type: BonjourConstants.serviceType
            )

            let sessionId = session.sessionId
            let listenerID = ObjectIdentifier(newListener)
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state, sessionId: sessionId, listenerID: listenerID)
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.sessions[sessionId] != nil else {
                        connection.cancel()
                        return
                    }
                    self.handleNewConnection(connection, sessionId: sessionId)
                }
            }

            session.listener = newListener
            newListener.start(queue: .main)
            lastError = nil
        } catch {
            lastError = "Failed to start remote listener: \(error.localizedDescription)"
        }
    }

    private func handleListenerState(_ state: NWListener.State, sessionId: String, listenerID: ObjectIdentifier) {
        guard let session = sessions[sessionId], let listener = session.listener,
              ObjectIdentifier(listener) == listenerID else { return }
        switch state {
        case .ready:
            session.isListening = true
            Log.link.info("[CompanionServer] Advertising remote control service")
        case .failed(let error):
            session.isListening = false
            lastError = "Remote listener failed: \(error.localizedDescription)"
            scheduleListenerRestart(sessionId: sessionId)
        case .cancelled:
            session.isListening = false
            Log.link.info("[CompanionServer] remote control service stopped unexpectedly; restarting")
            scheduleListenerRestart(sessionId: sessionId)
        case .waiting(let error):
            session.isListening = false
            Log.link.info("[CompanionServer] remote control service waiting: \(error.localizedDescription, privacy: .public)")
        default:
            break
        }
    }

    func setActive(_ active: Bool) {
        guard active, !sessions.isEmpty else { return }
        sweepUnresponsivePeers()
        for session in sessions.values where !session.isListening && session.listenerRestart == nil {
            Log.link.info("[CompanionServer] back in the foreground; restarting the remote control service")
            startListener(for: session)
        }
        for peer in readyPeers {
            sendSnapshot(to: peer)
            sendDeviceStatus(to: peer)
        }
    }

    private func sweepUnresponsivePeers() {
        let now = ContinuousClock.now
        for peer in Array(peers.values) {
            let unresponsive = CompanionHeartbeat.peerIsUnresponsive(
                isReady: peer.isReady,
                sendsHeartbeats: peer.sendsHeartbeats,
                connectedFor: Self.seconds(now - peer.connectedAt),
                silentFor: Self.seconds(now - peer.lastActivityAt)
            )
            if unresponsive { removePeer(peer, reason: "stopped responding") }
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func scheduleListenerRestart(sessionId: String) {
        guard let session = sessions[sessionId] else { return }

        session.cancelNetwork()
        session.listenerRestart = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, let session,
                  self.sessions[sessionId] === session, session.listener == nil else { return }
            self.startListener(for: session)
        }
    }
    // MARK: - Clients

    private var readyPeers: [Peer] {
        peers.values.filter(\.isReady).sorted { $0.id < $1.id }
    }

    private func isCurrent(_ peer: Peer) -> Bool {
        peers[peer.id] === peer
    }

    private func handleNewConnection(_ connection: NWConnection, sessionId: String) {
        for peer in peers.values where CompanionClientEviction.isDead(peer.connection.state) {
            removePeer(peer, reason: "connection ended")
        }
        while peers.count >= Self.maximumClients {
            let candidates = peers.values.map {
                CompanionClientEviction.Candidate(
                    id: $0.id,
                    isDead: CompanionClientEviction.isDead($0.connection.state),
                    lastActivityAt: $0.lastActivityAt
                )
            }
            guard let id = CompanionClientEviction.victim(among: candidates), let victim = peers[id] else { break }
            removePeer(victim, reason: "evicted for a newer client")
        }

        nextPeerID &+= 1
        let peer = Peer(
            id: nextPeerID,
            connection: connection,
            ownerID: "\(synchronizationID).peer.\(nextPeerID)",
            sessionId: sessionId
        )
        peers[peer.id] = peer

        let peerID = peer.id
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, let peer = self.peers[peerID] else { return }
                self.handleConnectionState(state, for: peer)
            }
        }

        connection.start(queue: .main)
        receiveData(on: peer)
    }

    private func handleConnectionState(_ state: NWConnection.State, for peer: Peer) {
        guard isCurrent(peer) else { return }

        switch state {
        case .ready:
            peer.isReady = true
            updateConnectedCount()
            Log.link.info("[CompanionServer] client \(peer.id, privacy: .public) connected; \(self.connectedClientCount, privacy: .public) connected")
            sendSnapshot(to: peer)
            sendDeviceStatus(to: peer)
            sendAccountStatus(to: peer)
            pushCueChanges(to: peer)
        case .failed, .cancelled:
            removePeer(peer, reason: "connection ended")
        default:
            break
        }
    }

    private func removePeer(_ peer: Peer, reason: String) {
        guard isCurrent(peer) else { return }
        peers[peer.id] = nil
        commands.retire(lane: peer.id)
        if !peers.values.contains(where: { $0.sessionId == peer.sessionId }), switchGate.drop(sessionId: peer.sessionId) != nil {
            switchRequest = nil
            switchExpiry?.cancel()
        }
        peer.connection.stateUpdateHandler = nil
        peer.connection.cancel()
        gateway.cancel(keyPrefix: "\(peer.ownerID).")
        updateConnectedCount()
        updateDecksStreaming()
        Log.link.info("[CompanionServer] client \(peer.id, privacy: .public) \(reason, privacy: .public); \(self.connectedClientCount, privacy: .public) connected")
    }

    private func updateConnectedCount() {
        let ready = readyPeers
        let count = ready.count
        let connected = Set(ready.map(\.sessionId))
        if connectedSessionIds != connected { connectedSessionIds = connected }
        if connectedClientCount != count { connectedClientCount = count }
        if isPhoneConnected != (count > 0) { isPhoneConnected = count > 0 }
        if count == 0 { resetStateFrames() }
    }

    private func receiveData(on peer: Peer) {
        let peerID = peer.id
        let connection = peer.connection
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, let peer = self.peers[peerID], peer.connection === connection else { return }

                if error != nil {
                    self.removePeer(peer, reason: "receive failed")
                    return
                }

                if let data, !data.isEmpty {
                    self.processReceivedData(data, from: peer)
                }

                guard self.isCurrent(peer) else { return }
                if isComplete {
                    self.removePeer(peer, reason: "closed the connection")
                } else {
                    self.receiveData(on: peer)
                }
            }
        }
    }

    private func processReceivedData(_ data: Data, from peer: Peer) {
        peer.lastActivityAt = .now
        peer.framer.append(data)

        while isCurrent(peer) {
            let message: TokenTransferMessage?
            do {
                message = try peer.framer.next()
            } catch is MessageFramer.FramingError {
                sendError("Malformed frame", to: peer)
                removePeer(peer, reason: "sent a malformed frame")
                return
            } catch {
                sendError("Failed to parse message: \(error.localizedDescription)", to: peer)
                continue
            }
            guard let message else { return }
            handle(message, from: peer)
        }
    }

    private func handle(_ message: TokenTransferMessage, from peer: Peer) {
        guard let session = sessions[peer.sessionId] else {
            removePeer(peer, reason: "is no longer linked")
            return
        }

        let trust = LinkedDeviceTrust(devices: devices)
        guard trust.admits(message, onSession: session.sessionId) else {
            sendError("Session ID mismatch", to: peer)
            return
        }

        if let identity = message.peer {
            noteIdentity(identity, for: session)
        }

        if message.type == .queueLoad {
            handleQueueLoad(message, from: peer, session: session)
        } else if message.type.isQueueCommand {
            handleQueueCommand(message, from: peer, session: session)
        } else if message.type.isControlCommand {
            handleControlCommand(message, from: peer, session: session)
        } else if message.type == .sessionRequest {
            handleSessionRequest(message, from: peer, session: session)
        } else if message.type == .cueSync {
            handleCueSync(message, from: peer, session: session)
        } else if message.type == .likesSync {
            handleLikesSync(message, from: peer, session: session)
        } else if message.type == .localMusicOffer {
            handleLocalMusicOffer(message, from: peer, session: session)
        } else if message.type == .continueSession {
            handleContinueSession(message, from: peer, session: session)
        } else if message.type == .analysisSync {
            handleAnalysisSync(message, from: peer, session: session)
        } else if message.type == .authHandoffSessionOffer {
            handleAuthHandoffSessionOffer(message, from: peer, session: session)
        } else if message.type == .linkRevoke {
            handleLinkRevoke(message, from: peer, session: session)
        } else if message.type == .sessionRevoke {
            handleSessionRevoke(message, from: peer, session: session)
        } else if message.type == .accountStatus {
            handleControllerAccountStatus(message, from: peer, session: session)
        } else if message.type == .accountSwitchRequest {
            handleAccountSwitchRequest(message, from: peer, session: session)
        } else if message.type == .accountSwitchCredentials {
            handleAccountSwitchCredentials(message, from: peer, session: session)
        } else if message.type == .acknowledgment {
            peer.sendsHeartbeats = true
            return
        } else {
            sendError("Unsupported message", to: peer)
        }
    }

    private func noteIdentity(_ identity: LinkPeerIdentity, for session: TrustedSession) {
        guard identity.verify(sessionId: session.sessionId, secret: session.secret),
              let updated = store.update(sessionId: session.sessionId, identity: identity) else { return }
        devices = updated
    }

    private func handleCueSync(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        let sessionId = session.sessionId
        let secret = session.secret
        guard let payload = message.cueSync else {
            sendError("Unsupported message", to: peer)
            return
        }

        guard payload.verify(sessionId: sessionId, secret: secret) else {
            sendError("Invalid signature", to: peer)
            return
        }

        guard payload.isFresh() else {
            sendError("Command expired", to: peer)
            return
        }

        guard session.cueReplayGuard.admit(payload.nonce) else {
            sendError("Duplicate command", to: peer)
            return
        }

        guard let body = CueSyncBody.decode(payload.body) else {
            sendError("Unsupported message", to: peer)
            return
        }

        commands.prepare(lane: peer.id) { [weak self] in
            await self?.synchronization.adoptNearbyCueState(body)
            return nil
        }
    }

    private func handleAnalysisSync(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        guard let payload = message.analysisSync,
              payload.verify(sessionId: session.sessionId, secret: session.secret),
              payload.isFresh(),
              session.analysisReplayGuard.admit(payload.nonce),
              let body = AnalysisPeerBody.decode(payload.body),
              payload.recordCount == body.records.count else {
            sendError("Analysis sync rejected", code: CompanionErrorCode.syncRefused, to: peer)
            return
        }
        Task.detached(priority: .utility) {
            let adopted = await AnalysisPeerPush.adopt(body, into: AnalysisCache.shared)
            Log.analysis.info("Adopted \(adopted, privacy: .public) of \(body.records.count, privacy: .public) analysis records over Companion")
        }
    }

    private func handleLikesSync(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        let sessionId = session.sessionId
        let secret = session.secret
        if let payload = message.likesSync, let library = LibraryPeerBody.decode(payload.body) {
            handleLibrarySync(payload, library, from: peer, session: session)
            return
        }
        guard let payload = message.likesSync,
              payload.verify(sessionId: sessionId, secret: secret),
              payload.isFresh(),
              session.likesReplayGuard.admit(payload.nonce),
              let body = LikesPeerBody.decode(payload.body),
              payload.accountId == body.accountId,
              payload.recordCount == body.records.count,
              payload.isComplete == body.isComplete,
              let localAccountId = SoundCloudCredentialSource.shared.currentUser?.id
                ?? SubscriptionService.shared.authenticatedAccountID,
              localAccountId == body.accountId else {
            sendError("Likes sync rejected", code: CompanionErrorCode.syncRefused, to: peer)
            return
        }

        commands.prepare(lane: peer.id) { [weak self] in
            _ = await self?.synchronization.adoptNearbyLikes(body, expectedAccountID: localAccountId)
            return nil
        }
    }

    private func handleLibrarySync(_ payload: LikesSyncPayload, _ body: LibraryPeerBody, from peer: Peer, session: TrustedSession) {
        guard payload.verify(sessionId: session.sessionId, secret: session.secret),
              payload.isFresh(),
              session.likesReplayGuard.admit(payload.nonce),
              payload.accountId == body.accountId,
              payload.recordCount == body.chunks.count,
              payload.isComplete == body.isComplete,
              let localAccountId = SoundCloudCredentialSource.shared.currentUser?.id
                ?? SubscriptionService.shared.authenticatedAccountID,
              localAccountId == body.accountId else {
            sendError("Library sync rejected", code: CompanionErrorCode.syncRefused, to: peer)
            return
        }
        commands.prepare(lane: peer.id) {
            _ = await LibrarySyncEngine.shared.adopt(body.decodedChunks(), expectedAccount: localAccountId)
            return nil
        }
    }

    private func handleLocalMusicOffer(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        guard let payload = message.localMusicOffer,
              payload.verify(sessionId: session.sessionId, secret: session.secret),
              payload.isFresh(),
              session.localMusicReplayGuard.admit(payload.nonce),
              let offer = LocalMusicOffer.decode(payload.body) else {
            sendError("Local music offer rejected", code: CompanionErrorCode.syncRefused, to: peer)
            return
        }
        RemoteLocalMusic.shared.adopt(offer, sessionId: session.sessionId)
    }

    private func handleContinueSession(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        guard let payload = message.continueSession,
              payload.verify(sessionId: session.sessionId, secret: session.secret),
              payload.isFresh(),
              session.continueSessionReplayGuard.admit(payload.nonce) else {
            sendError("Continue session rejected", code: CompanionErrorCode.syncRefused, to: peer)
            return
        }
        ContinueFrom.shared.adoptNearby(payload.body)
        guard !peer.hasContinueSession else { return }
        peer.hasContinueSession = true
        if let own = ContinueFrom.shared.latestOwn {
            sendContinueSession(own, to: peer, session: session)
        }
    }

    private func broadcastContinueSession(_ continueSession: ContinueSession) {
        for peer in readyPeers {
            guard let session = sessions[peer.sessionId] else { continue }
            sendContinueSession(continueSession, to: peer, session: session)
        }
    }

    private func sendContinueSession(_ continueSession: ContinueSession, to peer: Peer, session: TrustedSession) {
        guard let body = continueSession.encoded() else { return }
        send(
            .continueSession(
                sessionId: session.sessionId,
                payload: ContinueSessionPayload.create(body: body, sessionId: session.sessionId, secret: session.secret)
            ),
            to: peer
        )
    }

    func requestLocalMusicOffers() {
        for peer in readyPeers {
            send(.localMusicRequest(sessionId: peer.sessionId), to: peer)
        }
    }

    private func handleSessionRequest(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        let sessionId = session.sessionId
        let secret = session.secret
        guard let request = message.sessionRequest else {
            sendError("Unsupported message", to: peer)
            return
        }

        guard request.verify(sessionId: sessionId, secret: secret) else {
            sendError("Invalid signature", to: peer)
            return
        }

        guard request.isFresh() else {
            sendError("Command expired", to: peer)
            return
        }

        guard session.sessionReplayGuard.admit(request.nonce) else {
            sendError("Duplicate command", to: peer)
            return
        }

        Log.link.info("[CompanionServer] declined outbound session request; Apple TV is receiver-only")
        send(.sessionUnavailable(sessionId: sessionId), to: peer)
    }

    private func handleLinkRevoke(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        guard let revoke = message.verifiedRevoke(sessionId: session.sessionId, secret: session.secret),
              session.sessionReplayGuard.admit(revoke.nonce) else {
            sendError("Invalid signature", to: peer)
            return
        }
        let sessionId = session.sessionId
        let change = store.revoke(sessionId: sessionId)
        devices = change.devices
        Log.link.info("[CompanionServer] a linked device forgot this Apple TV; \(change.devices.count, privacy: .public) linked")
        acknowledge(peer) { [weak self] in
            self?.deactivate(sessionId: sessionId, reason: "forgot this Apple TV")
        }
    }

    private func handleSessionRevoke(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        guard let revoke = message.verifiedRevoke(sessionId: session.sessionId, secret: session.secret),
              session.sessionReplayGuard.admit(revoke.nonce) else {
            sendError("Invalid signature", to: peer)
            return
        }
        let localAccount = credentials.currentUser?.id ?? SubscriptionService.shared.authenticatedAccountID
        let localLineage = SessionSyncBookkeeping.lineageDigest(refreshToken: DeviceSessionStore.load()?.refreshToken)
        let matches = revoke.matchesAccount(accountId: localAccount, lineageDigest: localLineage)
        acknowledge(peer) {}
        guard matches, !credentials.isSignedOut else {
            Log.link.info("[CompanionServer] ignored a sign-out for a different SoundCloud account")
            return
        }
        Log.link.info("[CompanionServer] a linked device signed out everywhere; signing out and keeping links")
        Task { await AuthenticationService.shared.signOutKeepingLinks() }
    }

    private func acknowledge(_ peer: Peer, then completion: @escaping @MainActor () -> Void) {
        guard let data = try? TokenTransferMessage.acknowledgment(sessionId: peer.sessionId).framed() else {
            completion()
            return
        }
        peer.connection.send(content: data, completion: .contentProcessed { _ in
            Task { @MainActor in completion() }
        })
    }

    private func handleAuthHandoffSessionOffer(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        let sessionId = session.sessionId
        let secret = session.secret
        guard let offer = message.authHandoffSessionOffer else {
            sendError("Unsupported message", to: peer)
            return
        }

        guard offer.verify(sessionId: sessionId, secret: secret) else {
            sendError("Invalid signature", to: peer)
            return
        }

        guard offer.isFresh() else {
            sendError("Session offer expired", to: peer)
            return
        }

        if let continuation = pendingAuthHandoffSessionContinuation {
            pendingAuthHandoffSessionContinuation = nil
            continuation.resume(returning: offer)
        } else if TVControllerAccount.acceptsAuthHandoff(needsSignIn: credentials.needsSignIn, requestOutstanding: announcedNeedsSignIn == true) {
            adoptAuthHandoffSession(offer, from: peer)
        } else {
            Log.link.info("[CompanionServer] refused an auth handoff it didn't ask for")
            sendError("Session offer not expected", code: CompanionErrorCode.notExpected, to: peer)
        }
    }

    private func handleQueueLoad(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        let sessionId = session.sessionId
        let secret = session.secret
        guard let load = message.queueLoad,
              load.trackIds.indices.contains(load.startIndex),
              load.trackIds.count <= QueueLoadPayload.maximumTrackCount else {
            sendError("Unsupported message", to: peer)
            return
        }

        guard load.verify(sessionId: sessionId, secret: secret) else {
            sendError("Invalid signature", to: peer)
            return
        }

        guard load.isFresh() else {
            sendError("Command expired", to: peer)
            return
        }

        guard session.replayGuard.admit(load.nonce) else {
            sendError("Duplicate command", to: peer)
            return
        }

        Log.link.info("[CompanionServer] client \(peer.id, privacy: .public) loads \(load.trackIds.count, privacy: .public) tracks at \(load.startIndex, privacy: .public), position \(load.positionSeconds, privacy: .public), autoplay \(load.autoplay, privacy: .public)")
        commands.prepare(lane: peer.id) { [weak self, weak peer] in
            guard let self else { return nil }
            let tracks = await self.resolveTracks(ids: load.trackIds)
            let startID = load.trackIds[load.startIndex]
            guard let index = tracks.firstIndex(where: { $0.id == startID }) else {
                if let peer {
                    self.sendError("Could not load the queue", code: CompanionErrorCode.trackUnavailable, trackId: startID, to: peer)
                }
                return nil
            }
            return { [weak self] in await self?.applyLoad(load, tracks: tracks, index: index) }
        }
    }

    private func applyLoad(_ load: QueueLoadPayload, tracks: [Track], index: Int) async {
        let track = tracks[index]
        let source = load.sourceTitle.map {
            PlaybackQueueSource(id: nil, kind: load.sourceKind.flatMap(PlaybackQueueSource.Kind.init(rawValue:)) ?? .other, title: $0)
        }
        if load.autoplay, load.positionSeconds < 1 {
            await player.play(track, in: tracks, source: source)
        } else {
            await player.adoptOutputSession(
                track: track,
                queue: tracks,
                index: index,
                position: load.positionSeconds,
                autoplay: load.autoplay
            )
            player.setQueueSource(source)
        }
        scheduleQueueBroadcast(bump: true)
        schedulePlaybackBroadcast(force: true)
    }

    private func resolveTracks(ids: [String]) async -> [Track] {
        var byID: [String: Track] = [:]
        for offset in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[offset..<min(offset + 50, ids.count)])
            guard let tracks = try? await api.getTracks(ids: batch) else { continue }
            for track in tracks { byID[track.id] = track }
        }
        for id in ids where byID[id] == nil {
            if let cached = downloads.cachedTrack(forTrackId: id) { byID[id] = cached }
        }
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
    }

    private func handleQueueCommand(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        let sessionId = session.sessionId
        let secret = session.secret
        guard let command = message.command else {
            sendError("Unsupported message", to: peer)
            return
        }

        guard command.verify(type: message.type, sessionId: sessionId, secret: secret) else {
            sendError("Invalid signature", to: peer)
            return
        }

        guard command.isFresh() else {
            sendError("Command expired", to: peer)
            return
        }

        guard session.replayGuard.admit(command.nonce) else {
            sendError("Duplicate command", to: peer)
            return
        }

        switch message.type {
        case .queueRequest:
            sendQueueState(to: peer)
        case .queueReorder:
            applyReorder(command, from: peer)
        case .queueRemove:
            applyRemove(command, from: peer)
        case .queueJump:
            applyJump(command, from: peer)
        case .queueAdd:
            applyAdd(command, from: peer)
        case .queueReplace:
            applyReplace(command, from: peer)
        default:
            break
        }
    }

    private func handleControlCommand(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        let sessionId = session.sessionId
        let secret = session.secret
        guard let control = message.control else {
            sendError("Unsupported message", to: peer)
            return
        }

        guard control.verify(type: message.type, sessionId: sessionId, secret: secret) else {
            sendError("Invalid signature", to: peer)
            return
        }

        guard control.isFresh() else {
            sendError("Command expired", to: peer)
            return
        }

        if message.type.isContinuousControl {
            guard peer.sequenceGate.admit(control.sequence, type: message.type, deck: control.deck) else {
                return
            }
        } else {
            guard session.replayGuard.admit(control.nonce) else {
                sendError("Duplicate command", to: peer)
                return
            }
        }

        commands.submit(lane: peer.id) { [weak self, weak peer] in
            await self?.applyControl(message.type, control, from: peer)
        }
    }

    // MARK: - Cues

    private func pushCueChanges() {
        for peer in readyPeers { pushCueChanges(to: peer) }
    }

    private func pushCueChanges(to peer: Peer) {
        gateway.submit(
            lane: .companionBulk,
            key: "\(peer.ownerID).cues"
        ) { [weak self, weak peer] in
            guard let self, let peer else { return }
            await self.runCuePush(to: peer)
        }
    }

    private func runCuePush(to peer: Peer) async {
        while isCurrent(peer) {
            guard let session = sessions[peer.sessionId] else { return }
            let sessionId = session.sessionId
            let secret = session.secret
            let batch = await synchronization.nearbyCueBatch(
                changedSince: peer.cuePushHighWaterMark,
                limit: CueSyncChunking.maxBatchSize
            )
            let cues = batch.cues
            let dismissals = batch.dismissals
            if cues.isEmpty && dismissals.isEmpty { return }

            guard let body = CueSyncBody(cues: cues, dismissals: dismissals).encoded() else { return }
            let payload = CueSyncPayload.create(
                body: body, cueCount: cues.count, dismissalCount: dismissals.count,
                sessionId: sessionId, secret: secret
            )
            guard let data = try? TokenTransferMessage.cueSync(sessionId: sessionId, payload: payload).framed() else { return }
            transmit(data, to: peer)

            let batchMax = max(cues.map(\.updatedAtMillis).max() ?? 0, dismissals.map(\.dismissedAtMillis).max() ?? 0)
            if batchMax <= peer.cuePushHighWaterMark { return }
            peer.cuePushHighWaterMark = batchMax
        }
    }

    // MARK: - Queue commands

    private func applyReorder(_ command: QueueCommandPayload, from peer: Peer) {
        commands.submit(lane: peer.id) { [weak self, weak peer] in
            guard let self, self.targetIsStillValid(command, for: peer) else { return }
            let current = self.player.currentIndex
            if command.toIndex == current + 1, command.fromIndex > current + self.player.playingNextCount {
                self.player.moveToPlayingNext(at: command.fromIndex)
            } else {
                self.player.moveQueueItem(from: command.fromIndex, to: command.toIndex)
            }
            self.scheduleQueueBroadcast(bump: true)
        }
    }

    private func applyRemove(_ command: QueueCommandPayload, from peer: Peer) {
        commands.submit(lane: peer.id) { [weak self, weak peer] in
            guard let self, self.targetIsStillValid(command, for: peer) else { return }
            await self.player.removeFromQueue(at: command.fromIndex)
            self.scheduleQueueBroadcast(bump: true)
        }
    }

    private func applyJump(_ command: QueueCommandPayload, from peer: Peer) {
        commands.submit(lane: peer.id) { [weak self, weak peer] in
            guard let self, self.targetIsStillValid(command, for: peer) else { return }
            await self.player.playTrackAt(index: command.fromIndex)
            self.scheduleQueueBroadcast(bump: true)
            self.schedulePlaybackBroadcast(force: true)
        }
    }

    private func applyAdd(_ command: QueueCommandPayload, from peer: Peer) {
        commands.prepare(lane: peer.id) { [weak self, weak peer] in
            guard let self else { return nil }
            let track: Track
            do {
                track = try await self.api.getTrack(id: command.trackId)
            } catch {
                if let peer { self.sendError("Could not add track: \(error.localizedDescription)", code: CompanionErrorCode.trackUnavailable, trackId: command.trackId, to: peer) }
                return nil
            }
            return { [weak self] in
                guard let self else { return }
                let queue = self.player.queue
                if queue.isEmpty {
                    await self.player.play(track, in: [track])
                } else if command.toIndex < 0 || command.toIndex >= queue.count {
                    self.player.addToQueue(track)
                } else {
                    self.player.insertIntoQueue(track, at: command.toIndex)
                }
                self.scheduleQueueBroadcast(bump: true)
            }
        }
    }

    private func applyReplace(_ command: QueueCommandPayload, from peer: Peer) {
        commands.prepare(lane: peer.id) { [weak self, weak peer] in
            guard let self else { return nil }
            let track: Track
            do {
                track = try await self.api.getTrack(id: command.trackId)
            } catch {
                if let peer { self.sendError("Could not play track: \(error.localizedDescription)", code: CompanionErrorCode.trackUnavailable, trackId: command.trackId, to: peer) }
                return nil
            }
            return { [weak self] in
                guard let self else { return }
                await self.player.play(track, in: [track])
                self.scheduleQueueBroadcast(bump: true)
                self.schedulePlaybackBroadcast(force: true)
            }
        }
    }

    private func targetIsStillValid(_ command: QueueCommandPayload, for peer: Peer?) -> Bool {
        let queue = player.queue
        guard command.fromIndex >= 0,
              command.fromIndex < queue.count,
              queue[command.fromIndex].id == command.trackId else {
            if let peer {
                sendError("Queue has changed", to: peer)
                sendQueueState(to: peer)
            }
            return false
        }
        return true
    }

    // MARK: - Control commands

    private func applyDiscreteControl(_ body: () -> Void) {
        body()
        schedulePlaybackBroadcast(force: true)
        scheduleDJBroadcast(force: true)
    }

    private func applyMixEngineCommand(discrete: Bool, from peer: Peer?, _ body: () -> Void) {
        guard player.isMixEngineLive else {
            if discrete, let peer { sendError("DJ engine is not live", to: peer) }
            return
        }
        body()
        refreshDecksRemote(touchedBy: peer)
    }

    private func applyControl(_ type: MessageType, _ control: ControlCommandPayload, from peer: Peer?) async {
        switch type {
        case .transportPlay:
            applyDiscreteControl { player.play() }
        case .transportPause:
            applyDiscreteControl { player.pause() }
        case .transportSeek:
            applyDiscreteControl { player.seek(to: control.value) }
        case .transportNext:
            await player.playNext()
            schedulePlaybackBroadcast(force: true)
            scheduleQueueBroadcast(bump: false)
        case .transportPrevious:
            await player.playPrevious()
            schedulePlaybackBroadcast(force: true)
            scheduleQueueBroadcast(bump: false)
        case .transportShuffle:
            let enabled = control.value >= 0.5
            if player.isShuffleEnabled != enabled { player.toggleShuffle() }
            schedulePlaybackBroadcast(force: true)
            scheduleQueueBroadcast(bump: true)
        case .transportRepeat:
            guard let mode = RemoteRepeatMode(wireValue: control.value),
                  let repeatMode = RepeatMode(rawValue: mode.rawValue) else {
                if let peer { sendError("Unsupported repeat mode", to: peer) }
                return
            }
            applyDiscreteControl { player.repeatMode = repeatMode }
        case .transportVolume:
            player.setVolume(control.value)
            schedulePlaybackBroadcast(force: true)
        case .transportSleepTimer:
            if let mode = SleepTimerMode(wireKind: control.value, minutes: control.value2) {
                SleepTimer.shared.start(mode)
            } else {
                SleepTimer.shared.cancel()
            }
            schedulePlaybackBroadcast(force: true)

        case .djEnable:
            applyDiscreteControl { player.setDJSessionEnabled(true) }
        case .djDisable:
            applyDiscreteControl { player.endDJSession() }
        case .djAutoEnable:
            applyDiscreteControl { player.setAutomaticMixEnabled(true) }
        case .djAutoDisable:
            applyDiscreteControl { player.setAutomaticMixEnabled(false) }
        case .sceneParty:
            applyDiscreteControl { PartyScenes.performPartyHere(lights: LightingIntensity(wireValue: control.value)) }
        case .sceneWindDown:
            applyDiscreteControl { PartyScenes.performWindDownHere(minutes: control.value) }
        case .djProfile:
            applyDiscreteControl {
                let index = Int(control.value.rounded())
                guard DJProfile.all.indices.contains(index) else { return }
                player.setDJProfile(DJProfile.all[index].id)
            }

        case .djMixNow:
            refreshDecksRemote(touchedBy: peer)
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true, from: peer) {
                    player.startMix()
                }
            }
        case .djExtend:
            refreshDecksRemote(touchedBy: peer)
            applyDiscreteControl { player.extendMix() }
        case .djEnergy:
            applyDiscreteControl {
                AutoMixEnergy.shared.receiveRemote(
                    level: Int(control.value.rounded()),
                    heartRate: control.value2 > 0 ? control.value2 : nil
                )
            }
        case .djCue:
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true, from: peer) {
                    guard let deck = Self.mixEngineDeck(control.deck) else { return }
                    MixEngine.shared.seek(deck: deck, to: control.value)
                }
            }
        case .djHotCueSet:
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true, from: peer) {
                    guard let deck = Self.mixEngineDeck(control.deck),
                          let trackId = MixEngine.shared[deck].trackId else { return }
                    let index = min(CuePoint.hotCueSlotCount - 1, max(0, Int(control.value.rounded())))
                    let millis = CueTime.millis(fromSeconds: max(0, control.value2))
                    Task {
                        await synchronization.setNearbyHotCue(
                            trackID: trackId,
                            index: index,
                            positionMillis: millis
                        )
                    }
                }
            }
        case .djDeckPlayPause:
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true, from: peer) {
                    guard let deck = Self.mixEngineDeck(control.deck) else { return }
                    MixEngine.shared.togglePlayPause(deck: deck)
                }
            }
        case .djLoopSet:
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true, from: peer) {
                    guard let deck = Self.mixEngineDeck(control.deck) else { return }
                    if control.parameter == .loopBeats {
                        MixEngine.shared.setQuantizedLoop(
                            on: deck,
                            near: MixEngine.shared[deck].position,
                            beats: Double(control.value.rounded())
                        )
                    } else {
                        MixEngine.shared.setLoop(on: deck, startSeconds: control.value, lengthSeconds: control.value2)
                    }
                }
            }
        case .djLoopClear:
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true, from: peer) {
                    guard let deck = Self.mixEngineDeck(control.deck) else { return }
                    MixEngine.shared.clearLoop(on: deck)
                }
            }
        case .djSync:
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true, from: peer) {
                    guard let deck = Self.mixEngineDeck(control.deck) else { return }
                    _ = MixEngine.shared.sync(
                        deck,
                        to: deck.other,
                        maxPercent: player.djProfile?.maxAbsRatePercent
                            ?? MixEngine.maxTempoMatchPercent
                    )
                }
            }

        case .djCrossfader:
            applyMixerWrite(.crossfader, from: peer) {
                MixEngine.shared.clearAutomation(.crossfade)
                MixEngine.shared.crossfade = control.value
            }
        case .djEQ:
            guard let deck = Self.mixEngineDeck(control.deck),
                  let band = Self.eqBand(for: control.parameter) else { return }
            applyMixerWrite(MixControl(Self.mixKind(for: band), deck: deck), from: peer) {
                MixEngine.shared.setEQ(band, on: deck, toDecibels: control.value)
            }
        case .djFilter:
            guard let deck = Self.mixEngineDeck(control.deck) else { return }
            applyMixerWrite(MixControl(.filter, deck: deck), from: peer) {
                switch control.parameter {
                case .filterCutoff:
                    MixEngine.shared.setFilterCutoff(control.value, on: deck)
                case .highPassCutoff:
                    MixEngine.shared.setHighPassCutoff(control.value, on: deck)
                case .filterResonance:
                    MixEngine.shared.setFilterResonance(control.value, on: deck)
                default:
                    break
                }
            }
        case .djRate:
            guard let deck = Self.mixEngineDeck(control.deck) else { return }
            applyMixerWrite(MixControl(.tempo, deck: deck), from: peer) {
                MixEngine.shared.setRate(control.value, on: deck)
            }
        case .djHandBack:
            applyDiscreteControl { MixEngine.shared.handBackAll() }
            refreshDecksRemote(touchedBy: peer)
        case .djRemoteAttach:
            guard let peer else { return }
            peer.decksLeaseUntil = control.value >= 0.5 ? ContinuousClock.now + Self.remoteDecksLease : nil
            updateDecksStreaming()
            scheduleDJBroadcast(force: true)
        case .djJog:
            applyMixEngineCommand(discrete: false, from: peer) {
                guard let deck = Self.mixEngineDeck(control.deck) else { return }
                if control.parameter == .nudge {
                    if MixEngine.shared[deck].isPlaying {
                        MixEngine.shared.nudge(deck: deck, amount: control.value)
                    } else {
                        MixEngine.shared.seek(deck: deck, byNudging: control.value)
                    }
                }
            }

        default:
            break
        }
    }

    private static func mixEngineDeck(_ deck: ControlDeck) -> MixEngine.Deck? {
        switch deck {
        case .a: return .a
        case .b: return .b
        case .none: return nil
        }
    }

    private func applyMixerWrite(_ control: MixControl, from peer: Peer?, _ body: () -> Void) {
        applyMixEngineCommand(discrete: false, from: peer) {
            let engine = MixEngine.shared
            if player.isAutoMixEnabled { engine.takeOver(control) }
            engine.asUser(body)
        }
    }

    private static func mixKind(for band: MixEngine.EQBand) -> MixControl.Kind {
        switch band {
        case .low: return .low
        case .mid: return .mid
        case .high: return .high
        }
    }

    // MARK: - Decks on a remote

    func noteDecksVisible(_ visible: Bool) {
        decksVisibleCount = max(0, decksVisibleCount + (visible ? 1 : -1))
        scheduleDJBroadcast(force: true)
    }

    private var hasDecksLease: Bool {
        let now = ContinuousClock.now
        return readyPeers.contains { ($0.decksLeaseUntil ?? now) > now }
    }

    private func refreshDecksRemote(touchedBy peer: Peer? = nil) {
        let now = ContinuousClock.now
        guard let holder = readyPeers.first(where: { ($0.decksLeaseUntil ?? now) > now }) else {
            if decksRemote != nil { decksRemote = nil }
            return
        }
        let name = devices.first { $0.sessionId == holder.sessionId }?.displayName ?? "Linked Device"
        var next = DecksRemote(name: name, touchedAt: decksRemote?.touchedAt)
        if let peer, peer === holder, (next.touchedAt.map { Date().timeIntervalSince($0) > 2 } ?? true) {
            next.touchedAt = Date()
        }
        if next != decksRemote { decksRemote = next }
    }

    private func updateDecksStreaming() {
        refreshDecksRemote()
        let wanted = hasDecksLease
        guard wanted != isStreamingDecks else { return }
        isStreamingDecks = wanted
        let id = "\(synchronizationID).remoteDecks"
        guard wanted else {
            scheduler.cancelPeriodic(id: id)
            return
        }
        scheduler.registerPeriodic(
            id: id,
            scope: "synchronization",
            interval: Self.remoteDecksInterval
        ) { [weak self] in
            guard let self else { return }
            guard self.hasDecksLease else {
                self.updateDecksStreaming()
                return
            }
            self.transmitRemoteDecks()
        }
    }

    private func transmitRemoteDecks() {
        let sample = currentDJState()
        guard djFrames.isEmpty || sample.fingerprint != djFingerprint else { return }
        buildDJFrame(sample)
        for peer in readyPeers {
            if let frame = djFrames[peer.sessionId] { transmit(frame, to: peer) }
        }
    }

    private static func eqBand(for parameter: ControlParameter) -> MixEngine.EQBand? {
        switch parameter {
        case .eqLow: return .low
        case .eqMid: return .mid
        case .eqHigh: return .high
        default: return nil
        }
    }

    // MARK: - State broadcast

    private func observePlayer() {
        guard cancellables.isEmpty else { return }

        player.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.scheduleQueueBroadcast(bump: false)
                    self?.schedulePlaybackBroadcast(force: false)
                    self?.scheduleDJBroadcast(force: false)
                }
            }
            .store(in: &cancellables)

        player.clock.$duration
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.schedulePlaybackBroadcast(force: false)
                }
            }
            .store(in: &cancellables)

        SleepTimer.shared.$status
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.schedulePlaybackBroadcast(force: true)
                }
            }
            .store(in: &cancellables)

        player.clock.$currentTime
            .sink { [weak self] time in
                self?.checkPlaybackDrift(time)
            }
            .store(in: &cancellables)
    }

    private func startPeriodicWork() {
        scheduler.registerPeriodic(
            id: "\(synchronizationID).ping",
            scope: "synchronization",
            initialDelay: Self.pingInterval,
            interval: Self.pingInterval
        ) { [weak self] in
            self?.sendLivenessPing()
        }
        scheduler.registerPeriodic(
            id: "\(synchronizationID).decks",
            scope: "synchronization",
            initialDelay: Self.liveDeckRefreshInterval,
            interval: Self.liveDeckRefreshInterval,
            condition: { [weak self] in
                guard let self else { return false }
                return !self.peers.isEmpty && self.player.isMixEngineLive
            }
        ) { [weak self] in
            self?.scheduleDJBroadcast(force: false)
        }
    }

    private func sendLivenessPing() {
        sweepUnresponsivePeers()
        let targets = readyPeers
        guard !targets.isEmpty else { return }
        if playbackFrames.isEmpty { buildPlaybackFrame() }
        for peer in targets {
            if let frame = playbackFrames[peer.sessionId] { transmit(frame, to: peer) }
        }
        Log.link.debug("[CompanionServer] tx ping rev=\(self.playbackRevision, privacy: .public) clients=\(targets.count, privacy: .public)")
    }

    private func sendSnapshot(to peer: Peer) {
        sendQueueState(to: peer)
        buildPlaybackFrame()
        broadcast(playbackFrames, label: "playback_state", revision: playbackRevision)
        let dj = currentDJState()
        if djFrames[peer.sessionId] == nil || dj.fingerprint != djFingerprint { buildDJFrame(dj) }
        if let frame = djFrames[peer.sessionId] { transmit(frame, to: peer) }
    }

    private func sendQueueState(to peer: Peer) {
        let fingerprint = currentQueueFingerprint()
        if queueFrames[peer.sessionId] == nil || fingerprint != queueFingerprint { buildQueueFrame(fingerprint: fingerprint) }
        if let frame = queueFrames[peer.sessionId] { transmit(frame, to: peer) }
    }

    private func signedFrames(_ make: (_ sessionId: String, _ secret: Data) -> TokenTransferMessage) -> [String: Data] {
        var frames: [String: Data] = [:]
        for session in sessions.values {
            frames[session.sessionId] = try? make(session.sessionId, session.secret).framed()
        }
        return frames
    }

    private func broadcast(_ frames: [String: Data], label: StaticString, revision: Int) {
        let targets = readyPeers
        guard !targets.isEmpty else { return }
        for peer in targets {
            if let data = frames[peer.sessionId] { transmit(data, to: peer) }
        }
        Log.link.info("[CompanionServer] tx \(label, privacy: .public) rev=\(revision, privacy: .public) clients=\(targets.count, privacy: .public)")
    }

    private func scheduleQueueBroadcast(bump: Bool) {
        guard !readyPeers.isEmpty else { return }
        pendingQueueBump = pendingQueueBump || bump
        gateway.submit(
            lane: .companionState,
            key: "\(synchronizationID).queue",
            urgency: bump ? .immediate : .normal
        ) { [weak self] in
            self?.transmitQueueState()
        }
    }

    private func transmitQueueState() {
        let bump = pendingQueueBump
        pendingQueueBump = false
        let fingerprint = currentQueueFingerprint()
        guard bump || queueFrames.isEmpty || fingerprint != queueFingerprint else { return }
        buildQueueFrame(fingerprint: fingerprint)
        broadcast(queueFrames, label: "queue_state", revision: queueRevision)
    }

    private func buildQueueFrame(fingerprint: Int) {
        guard !sessions.isEmpty else { return }
        queueRevision &+= 1
        queueFingerprint = fingerprint
        let tracks = player.queue.map(Self.wireTrack)
        let currentIndex = player.currentIndex
        let isPlaying = player.isPlaying
        let revision = queueRevision
        let source = player.queueSource
        let playingNextCount = player.playingNextCount
        queueFrames = signedFrames { sessionId, secret in
            .queueState(sessionId: sessionId, queue: QueueStatePayload.create(
                tracks: tracks,
                currentIndex: currentIndex,
                isPlaying: isPlaying,
                revision: revision,
                sourceTitle: source?.title,
                sourceKind: source?.kind.rawValue,
                playingNextCount: playingNextCount,
                sessionId: sessionId,
                secret: secret
            ))
        }
    }

    private func currentQueueFingerprint() -> Int {
        var hasher = Hasher()
        for track in player.queue {
            hasher.combine(track.id)
        }
        hasher.combine(player.currentIndex)
        hasher.combine(player.isPlaying)
        hasher.combine(player.queueSource)
        hasher.combine(player.playingNextCount)
        return hasher.finalize()
    }

    private static func wireTrack(_ track: Track) -> QueueTrack {
        QueueTrack(
            id: track.id,
            title: track.title,
            artist: track.user.displayName,
            artworkURL: track.artworkURL,
            duration: track.duration
        )
    }

    private func schedulePlaybackBroadcast(force: Bool) {
        guard !readyPeers.isEmpty else { return }
        pendingPlaybackForce = pendingPlaybackForce || force
        gateway.submit(
            lane: .companionState,
            key: "\(synchronizationID).playback",
            urgency: force ? .immediate : .normal
        ) { [weak self] in
            self?.transmitPlaybackState()
        }
    }

    private func transmitPlaybackState() {
        let force = pendingPlaybackForce
        pendingPlaybackForce = false
        guard force || playbackFrames.isEmpty || currentPlaybackFingerprint() != playbackFingerprint else { return }
        buildPlaybackFrame()
        broadcast(playbackFrames, label: "playback_state", revision: playbackRevision)
    }

    private func checkPlaybackDrift(_ time: TimeInterval) {
        guard let anchor, !readyPeers.isEmpty, !pendingPlaybackForce else { return }
        let drift = abs(time - anchor.expectedPosition(at: Date()))
        guard drift > Self.driftTolerance else { return }
        Log.link.debug("[CompanionServer] playback drifted \(drift, privacy: .public)s from the anchor")
        schedulePlaybackBroadcast(force: true)
    }

    private var currentRate: Double {
        player.isMixEngineLive ? MixEngine.shared[player.liveDeck].rate : 1
    }

    private func currentPlaybackFingerprint() -> Int {
        var hasher = Hasher()
        hasher.combine(player.currentTrack?.id)
        hasher.combine(player.isPlaying)
        hasher.combine(Int((player.duration * 10).rounded()))
        hasher.combine(player.isMixEngineLive)
        hasher.combine(Int((currentRate * 1000).rounded()))
        hasher.combine(player.isShuffleEnabled)
        hasher.combine(player.repeatMode)
        hasher.combine(Int((player.volume * 100).rounded()))
        hasher.combine(SleepTimer.shared.status?.mode)
        hasher.combine(SleepTimer.shared.status?.endsAt.map { Int($0.timeIntervalSince1970) })
        return hasher.finalize()
    }

    private func buildPlaybackFrame() {
        guard !sessions.isEmpty else { return }
        let now = Date()
        let rate = currentRate
        let isPlaying = player.isPlaying
        let clock = player.clock
        let sinceTick = isPlaying ? min(1, max(0, now.timeIntervalSince(clock.updatedAt))) : 0
        let position = max(0, clock.currentTime + sinceTick * rate)

        playbackRevision &+= 1
        playbackFingerprint = currentPlaybackFingerprint()
        anchor = PlaybackAnchor(position: position, date: now, rate: rate, isPlaying: isPlaying)

        let track = player.currentTrack
        let duration = player.duration
        let isDJEngineLive = player.isMixEngineLive
        let isShuffleEnabled = player.isShuffleEnabled
        let repeatMode = RemoteRepeatMode(rawValue: player.repeatMode.rawValue)
        let volume = player.volume
        let sleepTimer = SleepTimer.shared.status
        let revision = playbackRevision
        playbackFrames = signedFrames { sessionId, secret in
            .playbackState(sessionId: sessionId, playback: PlaybackStatePayload.create(
                isPlaying: isPlaying,
                positionSeconds: position,
                durationSeconds: duration,
                trackId: track?.id,
                title: track?.title,
                artist: track?.user.displayName,
                artworkURL: track?.artworkURL?.absoluteString,
                isDJEngineLive: isDJEngineLive,
                rate: rate,
                isShuffleEnabled: isShuffleEnabled,
                repeatMode: repeatMode,
                volume: volume,
                sleepTimer: sleepTimer,
                revision: revision,
                sessionId: sessionId,
                secret: secret
            ))
        }
    }

    private struct DJStateSample {
        let isEnabled: Bool
        let isEngineLive: Bool
        let isAutoMixEnabled: Bool
        let crossfade: Double
        let deckA: DJDeckStatePayload
        let deckB: DJDeckStatePayload
        let automaticMix: DJAutomaticMixDecision
        let plan: DJPlanPayload?
        var live: Data? = nil
        let decksOpen: Bool
        let fingerprint: Int
    }

    private func scheduleDJBroadcast(force: Bool) {
        guard !readyPeers.isEmpty else { return }
        pendingDJForce = pendingDJForce || force
        gateway.submit(
            lane: .companionState,
            key: "\(synchronizationID).dj",
            urgency: force ? .immediate : .normal
        ) { [weak self] in
            self?.transmitDJState()
        }
    }

    private func transmitDJState() {
        let force = pendingDJForce
        pendingDJForce = false
        let sample = currentDJState()
        guard force || djFrames.isEmpty || sample.fingerprint != djFingerprint else { return }
        buildDJFrame(sample)
        let targets = readyPeers
        for peer in targets {
            if let frame = djFrames[peer.sessionId] { transmit(frame, to: peer) }
        }
        Log.link.debug("[CompanionServer] tx dj_state rev=\(self.djRevision, privacy: .public) clients=\(targets.count, privacy: .public)")
    }

    private func buildDJFrame(_ sample: DJStateSample) {
        guard !sessions.isEmpty else { return }
        djRevision &+= 1
        djFingerprint = sample.fingerprint
        let revision = djRevision
        djFrames = signedFrames { sessionId, secret in
            .djState(sessionId: sessionId, dj: DJStatePayload.create(
                isEnabled: sample.isEnabled,
                isEngineLive: sample.isEngineLive,
                isAutoMixEnabled: sample.isAutoMixEnabled,
                crossfade: sample.crossfade,
                deckA: sample.deckA,
                deckB: sample.deckB,
                automaticMix: sample.automaticMix,
                plan: sample.plan,
                live: sample.live,
                decksOpen: sample.decksOpen,
                revision: revision,
                sessionId: sessionId,
                secret: secret
            ))
        }
    }

    private func currentDJState() -> DJStateSample {
        let player = player
        let engine = MixEngine.shared
        let deckA = deckPayload(.a, player: player, engine: engine)
        let deckB = deckPayload(.b, player: player, engine: engine)
        let automaticMix = player.automaticMixDecision
        let sessionSnapshot = player.djSessionSnapshot
        let sessionPlan = sessionSnapshot?.activePlan ?? sessionSnapshot?.upcomingPlan
        let plan = sessionPlan.map {
            DJPlanPayload(
                plan: $0,
                profileName: sessionSnapshot?.profile?.styleName ?? player.djProfile?.styleName
            )
        }
        let fingerprint = djFingerprint(
            isEnabled: player.isDJSessionEnabled,
            isEngineLive: player.isMixEngineLive,
            isAutoMixEnabled: player.isAutoMixEnabled,
            crossfade: engine.crossfade,
            deckA: deckA,
            deckB: deckB,
            automaticMix: automaticMix,
            plan: plan
        )
        let live = AutoMixLive.shared.state?.encoded()
        let decksOpen = decksVisibleCount > 0
        return DJStateSample(
            isEnabled: player.isDJSessionEnabled,
            isEngineLive: player.isMixEngineLive,
            isAutoMixEnabled: player.isAutoMixEnabled,
            crossfade: engine.crossfade,
            deckA: deckA,
            deckB: deckB,
            automaticMix: automaticMix,
            plan: plan,
            live: live,
            decksOpen: decksOpen,
            fingerprint: fingerprint ^ (live?.hashValue ?? 0) ^ (decksOpen ? 0x5DEC : 0)
        )
    }

    private func deckPayload(
        _ deck: MixEngine.Deck,
        player: PlayerService,
        engine: MixEngine
    ) -> DJDeckStatePayload {
        let trackId = engine[deck].trackId
        let track = trackId.flatMap { id in player.queue.first(where: { $0.id == id }) }
            ?? (player.currentTrack?.id == trackId ? player.currentTrack : nil)
        let gridBPM = engine.beatGrid(for: deck).map { 60 / $0.beatPeriod }
        let analysedBPM: Double? = trackId.flatMap { id in
            if case .analyzed(let analysis) = DJTransitionService.shared.state(for: id) {
                return analysis.bpm
            }
            return nil
        }
        let role: DJDeckRole = trackId == nil
            ? .idle
            : (deck == player.liveDeck ? .live : .incoming)
        let phase = engine[deck.other].isPlaying
            ? engine.phaseErrorSeconds(deck, relativeTo: deck.other)
            : nil
        let base = engine.deckStatePayload(
            deck,
            title: track?.title,
            artist: track?.user.displayName,
            bpm: gridBPM ?? analysedBPM,
            role: role,
            phaseErrorSeconds: phase
        )
        let deckState = engine[deck]
        return DJDeckStatePayload(
            trackId: base.trackId, title: base.title, artist: base.artist,
            positionSeconds: base.positionSeconds, durationSeconds: base.durationSeconds,
            isPlaying: base.isPlaying,
            eqLowDb: base.eqLowDb, eqMidDb: base.eqMidDb, eqHighDb: base.eqHighDb,
            filterCutoffHz: base.filterCutoffHz, filterResonance: base.filterResonance,
            rate: base.rate, bpm: base.bpm,
            loopStartSeconds: base.loopStartSeconds, loopLengthSeconds: base.loopLengthSeconds,
            role: base.role, level: base.level, peak: base.peak,
            isClipping: base.isClipping, phaseErrorSeconds: base.phaseErrorSeconds,
            highPassCutoffHz: deckState.highPassCutoff, delayWetMix: deckState.delayWet
        )
    }

    private func djFingerprint(
        isEnabled: Bool,
        isEngineLive: Bool,
        isAutoMixEnabled: Bool,
        crossfade: Double,
        deckA: DJDeckStatePayload,
        deckB: DJDeckStatePayload,
        automaticMix: DJAutomaticMixDecision,
        plan: DJPlanPayload?
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(isEnabled)
        hasher.combine(isEngineLive)
        hasher.combine(isAutoMixEnabled)
        hasher.combine(crossfade)
        Self.combine(deckA, into: &hasher, includesMeters: isEngineLive)
        Self.combine(deckB, into: &hasher, includesMeters: isEngineLive)
        hasher.combine(automaticMix.phase.rawValue)
        hasher.combine(automaticMix.profileName)
        hasher.combine(automaticMix.templateName)
        hasher.combine(automaticMix.headline)
        hasher.combine(automaticMix.reasoning)
        hasher.combine(automaticMix.incomingTrackId)
        hasher.combine(automaticMix.mixPointSeconds)
        hasher.combine(automaticMix.transitionSeconds)
        hasher.combine(automaticMix.entrySeconds)
        hasher.combine(automaticMix.score)
        hasher.combine(automaticMix.isFallback)
        hasher.combine(plan?.templateName)
        hasher.combine(plan?.profileName)
        hasher.combine(plan?.mixPointSeconds)
        hasher.combine(plan?.transitionSeconds)
        hasher.combine(plan?.entrySeconds)
        hasher.combine(plan?.reasoning)
        hasher.combine(plan?.score)
        for stage in plan?.stages ?? [] {
            hasher.combine(stage.atSeconds)
            hasher.combine(stage.deck)
            hasher.combine(stage.action)
            hasher.combine(stage.snap)
        }
        return hasher.finalize()
    }

    private static func combine(_ deck: DJDeckStatePayload, into hasher: inout Hasher, includesMeters: Bool) {
        hasher.combine(deck.trackId)
        hasher.combine(deck.title)
        hasher.combine(deck.artist)
        hasher.combine(deck.durationSeconds)
        hasher.combine(deck.isPlaying)
        hasher.combine(deck.eqLowDb)
        hasher.combine(deck.eqMidDb)
        hasher.combine(deck.eqHighDb)
        hasher.combine(deck.filterCutoffHz)
        hasher.combine(deck.filterResonance)
        hasher.combine(deck.rate)
        hasher.combine(deck.bpm)
        hasher.combine(deck.loopStartSeconds)
        hasher.combine(deck.loopLengthSeconds)
        hasher.combine(deck.role?.rawValue)
        hasher.combine(deck.isClipping)
        guard includesMeters else { return }
        hasher.combine(deck.positionSeconds)
        hasher.combine(deck.level)
        hasher.combine(deck.peak)
        hasher.combine(deck.phaseErrorSeconds)
    }

    // MARK: - Transport

    private func send(_ message: TokenTransferMessage, to peer: Peer) {
        guard let data = try? message.framed() else { return }
        gateway.sendCompanionFrame(
            data,
            type: message.type,
            ownerID: peer.ownerID,
            connection: peer.connection
        ) { [weak self, weak peer] in
            guard let self, let peer else { return false }
            return self.isCurrent(peer)
        }
    }

    private func transmit(_ data: Data, to peer: Peer) {
        gateway.transmitAdmittedCompanionFrame(
            data,
            connection: peer.connection
        ) { [weak self, weak peer] in
            guard let self, let peer else { return false }
            return self.isCurrent(peer) && peer.isReady
        }
    }

    private func sendError(_ text: String, code: String? = nil, trackId: String? = nil, to peer: Peer) {
        send(.error(sessionId: peer.sessionId, message: text, code: code, trackId: trackId), to: peer)
    }

    // MARK: - Device status

    private func announceDeviceStatusIfChanged() {
        let needsSignIn = credentials.needsSignIn
        guard needsSignIn != announcedNeedsSignIn else { return }
        announcedNeedsSignIn = needsSignIn
        Log.link.info("[CompanionServer] sign-in needed=\(needsSignIn, privacy: .public); telling \(self.readyPeers.count, privacy: .public) connected")
        for peer in readyPeers { sendDeviceStatus(to: peer) }
    }

    private func sendDeviceStatus(to peer: Peer) {
        guard let session = sessions[peer.sessionId] else { return }
        let status = DeviceStatusPayload.create(
            needsSignIn: credentials.needsSignIn,
            sessionId: session.sessionId,
            secret: session.secret
        )
        send(.deviceStatus(sessionId: session.sessionId, status: status), to: peer)
    }

    // MARK: - Account status

    var localAccount: PeerAccount? {
        guard !credentials.needsSignIn else { return nil }
        return credentials.accountUser.map(PeerAccount.init(user:))
    }

    static var lastAccount: PeerAccount? {
        PeerAccount.decode(UserDefaults.standard.data(forKey: lastAccountKey))
    }

    private static func rememberLastAccount(_ account: PeerAccount) {
        guard lastAccount != account, let data = account.encoded() else { return }
        UserDefaults.standard.set(data, forKey: lastAccountKey)
    }

    private var localAccountState: (state: AccountStatusPayload.State, account: PeerAccount?, last: PeerAccount?)? {
        if credentials.needsSignIn { return (.needsSignIn, nil, Self.lastAccount) }
        if let user = credentials.accountUser {
            let account = PeerAccount(user: user)
            Self.rememberLastAccount(account)
            return (.signedIn, account, nil)
        }
        return credentials.isSignedOut ? (.signedOut, nil, nil) : nil
    }

    private func announceAccountStatusIfChanged() {
        guard let local = localAccountState else { return }
        let fingerprint = [local.state.rawValue, local.account?.tag ?? "", local.account?.name ?? "", local.last?.tag ?? ""].joined(separator: "|")
        guard fingerprint != announcedAccountStatus else { return }
        announcedAccountStatus = fingerprint
        Log.link.info("[CompanionServer] account is now \(local.state.rawValue, privacy: .public); telling \(self.readyPeers.count, privacy: .public) connected")
        for peer in readyPeers { sendAccountStatus(to: peer) }
    }

    private func sendAccountStatus(to peer: Peer) {
        guard let session = sessions[peer.sessionId], let local = localAccountState else { return }
        let status = AccountStatusPayload.create(
            state: local.state,
            account: local.account?.encoded(),
            last: local.last?.encoded(),
            sessionId: session.sessionId,
            secret: session.secret
        )
        send(.accountStatus(sessionId: session.sessionId, status: status), to: peer)
    }

    private func handleControllerAccountStatus(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        guard let status = message.verifiedAccountStatus(sessionId: session.sessionId, secret: session.secret) else { return }
        let account = status.state == .signedIn ? PeerAccount.decode(status.account) : nil
        if controllerAccounts[session.sessionId] != account { controllerAccounts[session.sessionId] = account }
        guard !peer.announcedAccount else { return }
        peer.announcedAccount = true
        let device = devices.first { $0.sessionId == session.sessionId }
        guard let text = TVControllerAccount.connectedCapsule(device: device?.displayName ?? "A device", controller: account, tv: localAccount) else { return }
        accountNotice = AccountNotice(text: text, symbol: PeerDevice(deviceClass: device?.deviceClass).symbolName)
    }

    // MARK: - Account switch

    private func handleAccountSwitchRequest(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        guard let payload = message.verifiedAccountSwitch(sessionId: session.sessionId, secret: session.secret),
              let account = PeerAccount.decode(payload.account) else { return }
        if let current = localAccount, current.isSameAccount(as: account) {
            sendSwitchAnswer(.switched, nonce: payload.nonce, to: peer, session: session)
            return
        }
        let name = devices.first { $0.sessionId == session.sessionId }?.displayName ?? "A device"
        guard localAccount != nil,
              switchGate.receive(nonce: payload.nonce, sessionId: session.sessionId, account: account, deviceName: name, at: Date()) else {
            sendSwitchAnswer(.declined, nonce: payload.nonce, to: peer, session: session)
            return
        }
        Log.link.info("[CompanionServer] a linked device asked to switch this Apple TV's account")
        switchRequest = switchGate.asking
        scheduleSwitchExpiry(after: AccountSwitchPayload.answerTimeout)
    }

    func answerSwitch(accept: Bool) {
        let request = accept ? switchGate.accept(at: Date()) : switchGate.decline()
        switchRequest = nil
        guard let request else { return }
        guard let session = sessions[request.sessionId],
              let peer = readyPeers.first(where: { $0.sessionId == request.sessionId }) else {
            _ = switchGate.drop(sessionId: request.sessionId)
            switchExpiry?.cancel()
            return
        }
        sendSwitchAnswer(accept ? .accepted : .declined, nonce: request.nonce, to: peer, session: session)
        if accept {
            switchingTo = request.account
            scheduleSwitchExpiry(after: AccountSwitchPayload.credentialsTimeout)
        } else {
            switchExpiry?.cancel()
        }
    }

    private func scheduleSwitchExpiry(after seconds: TimeInterval) {
        switchExpiry?.cancel()
        switchExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.switchGate.expire(at: Date()) != nil else { return }
            self.switchRequest = nil
            self.switchingTo = nil
        }
    }

    private func handleAccountSwitchCredentials(_ message: TokenTransferMessage, from peer: Peer, session: TrustedSession) {
        guard let payload = message.verifiedAccountSwitch(sessionId: session.sessionId, secret: session.secret),
              let token = payload.credentials,
              let request = switchGate.credentials(nonce: payload.nonce, sessionId: session.sessionId, at: Date()) else {
            sendError("Switch not expected", code: CompanionErrorCode.notExpected, to: peer)
            return
        }
        switchExpiry?.cancel()
        let nonce = payload.nonce
        let sessionId = session.sessionId
        Task { @MainActor [weak self] in
            let answer: AccountSwitchPayload.Answer
            switch await SoundCloudAPI.shared.validateToken(token.oauthToken) {
            case .valid:
                await AuthenticationService.shared.signOutKeepingLinks()
                await AuthenticationService.shared.authenticate(
                    token: token.oauthToken,
                    refreshToken: token.refreshToken,
                    clientId: token.clientId,
                    expiry: token.expiresAt
                )
                SessionProvenance.record(.guest)
                answer = .switched
            case .rejected:
                answer = .refused
            default:
                answer = .unavailable
            }
            guard let self else { return }
            self.switchingTo = nil
            Log.link.info("[CompanionServer] account switch finished: \(answer.rawValue, privacy: .public)")
            if answer == .switched {
                self.accountNotice = AccountNotice(text: TVAccountCopy.signedInAs(request.account), symbol: "person.crop.circle.badge.checkmark")
            }
            guard let session = self.sessions[sessionId],
                  let peer = self.readyPeers.first(where: { $0.sessionId == sessionId }) else { return }
            self.sendSwitchAnswer(answer, nonce: nonce, to: peer, session: session)
        }
    }

    private func sendSwitchAnswer(_ answer: AccountSwitchPayload.Answer, nonce: String, to peer: Peer, session: TrustedSession) {
        let payload = AccountSwitchPayload.answer(answer, nonce: nonce, sessionId: session.sessionId, secret: session.secret)
        send(.accountSwitch(.accountSwitchAnswer, sessionId: session.sessionId, payload: payload), to: peer)
    }
}

extension CompanionServer: PeerContentSessionProvider {
    var peerContentEndpoint: (endpoint: NWEndpoint, sessionId: String, secret: Data)? {
        for key in remoteContentEndpoints.keys.sorted() {
            guard let match = remoteContentEndpoints[key],
                  let session = sessions[match.sessionId] else { continue }
            return (match.endpoint, session.sessionId, session.secret)
        }
        return nil
    }

    func peerContentEndpoint(forDeviceId deviceId: String) -> (endpoint: NWEndpoint, sessionId: String, secret: Data)? {
        let token = PeerContentServer.serviceToken(for: deviceId)
        guard let match = remoteContentEndpoints[token], let session = sessions[match.sessionId] else { return nil }
        return (match.endpoint, session.sessionId, session.secret)
    }
}

// MARK: - Command ordering

@MainActor
final class CompanionCommandPipeline {
    typealias Operation = @MainActor () async -> Void

    private var lanes: [Int: Task<Void, Never>] = [:]
    private var applying: Task<Void, Never> = Task {}
    private var generation = 0

    var laneCount: Int { lanes.count }

    func submit(lane: Int, _ operation: @escaping Operation) {
        prepare(lane: lane) { operation }
    }

    func prepare(lane: Int, _ preparation: @escaping @MainActor () async -> Operation?) {
        let previous = lanes[lane]
        let generation = generation
        lanes[lane] = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled, let operation = await preparation(), !Task.isCancelled else { return }
            await self?.apply(operation, generation: generation)
        }
    }

    func retire(lane: Int) {
        lanes[lane] = nil
    }

    func cancelAll() {
        generation &+= 1
        for task in lanes.values { task.cancel() }
        lanes.removeAll()
        applying.cancel()
        applying = Task {}
    }

    private func apply(_ operation: @escaping Operation, generation: Int) async {
        guard generation == self.generation else { return }
        let previous = applying
        let task = Task { @MainActor in
            await previous.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        applying = task
        await task.value
    }
}

enum CompanionClientEviction {
    struct Candidate: Equatable {
        let id: Int
        let isDead: Bool
        let lastActivityAt: ContinuousClock.Instant
    }

    static func isDead(_ state: NWConnection.State) -> Bool {
        switch state {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    static func victim(among candidates: [Candidate]) -> Int? {
        candidates.min { lhs, rhs in
            if lhs.isDead != rhs.isDead { return lhs.isDead }
            if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt < rhs.lastActivityAt }
            return lhs.id < rhs.id
        }?.id
    }
}

@MainActor
private final class RevokeTally {
    private var remaining: Int
    private(set) var delivered = false

    init(remaining: Int) {
        self.remaining = remaining
    }

    func record(delivered success: Bool) -> Bool {
        delivered = delivered || success
        remaining -= 1
        return remaining == 0
    }
}

@MainActor
private final class LinkRevocationBeacon {
    private let link: RevokedLink
    private let onDelivered: @MainActor (String) -> Void
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var restart: Task<Void, Never>?

    init(link: RevokedLink, onDelivered: @escaping @MainActor (String) -> Void) {
        self.link = link
        self.onDelivered = onDelivered
    }

    func start() {
        guard let secret = link.secret else { return }
        do {
            let listener = try NWListener(using: CompanionEndpoint.listenerParameters(sessionId: link.sessionId, secret: secret))
            listener.service = NWListener.Service(
                name: CompanionEndpoint.serviceName(sessionId: link.sessionId),
                type: BonjourConstants.serviceType
            )
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed = state else { return }
                Task { @MainActor in self?.scheduleRestart() }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            Log.link.error("[CompanionServer] couldn't advertise a removal notice: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancelNetwork() {
        restart?.cancel()
        restart = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func scheduleRestart() {
        listener?.cancel()
        listener = nil
        restart?.cancel()
        restart = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.listener == nil else { return }
            self.start()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let secret = link.secret else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        let sessionId = link.sessionId
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    guard let frame = try? TokenTransferMessage.linkRevoke(sessionId: sessionId, secret: secret, reason: self.link.reason).framed() else { return }
                    connection.send(content: frame, completion: .contentProcessed { _ in })
                case .failed, .cancelled:
                    self.connections[key] = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, framer: MessageFramer())
        Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, let connection, self.connections[key] != nil else { return }
            connection.cancel()
            self.connections[key] = nil
        }
    }

    private func receive(on connection: NWConnection, framer: MessageFramer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var framer = framer
                if let data, !data.isEmpty { framer.append(data) }
                while let message = try? framer.next() {
                    if message.type == .acknowledgment, message.sessionId == self.link.sessionId {
                        connection.cancel()
                        self.onDelivered(self.link.sessionId)
                        return
                    }
                }
                guard error == nil, !isComplete else {
                    connection.cancel()
                    return
                }
                self.receive(on: connection, framer: framer)
            }
        }
    }
}
