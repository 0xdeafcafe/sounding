import Foundation
import Network
import Combine

@MainActor
final class CompanionClient: ObservableObject {

    private struct PersistedSnapshot: Codable {
        let sessionId: String
        let tracks: [QueueTrack]
        let currentIndex: Int
        let isPlaying: Bool
        let playback: PlaybackStatePayload?
        let djState: DJStatePayload?
        let savedAt: Date
    }

    private static let snapshotDefaultsKey = "red.forbes.sounding.remoteNowPlaying.v1"

    enum State: Equatable {
        case unlinked
        case idle
        case searching
        case connecting
        case connected
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.unlinked, .unlinked), (.idle, .idle), (.searching, .searching),
                 (.connecting, .connecting), (.connected, .connected):
                return true
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var tracks: [QueueTrack] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var rejection: String?
    @Published private(set) var hasSnapshot = false

    @Published private(set) var playback: PlaybackStatePayload?
    @Published private(set) var djState: DJStatePayload?

    var isDJControlLive: Bool { playback?.isDJEngineLive == true }

    fileprivate var controlSequence: Int64 = 0

    private struct PendingContinuousControl {
        let type: MessageType
        let deck: ControlDeck
        let parameter: ControlParameter
        let value: Double
        let value2: Double
    }

    private var pendingContinuousControls: [String: PendingContinuousControl] = [:]
    private var continuousFlushTask: Task<Void, Never>?

    private var cueReplayGuard = ReplayGuard()
    private var cuePushHighWaterMark: Int64 = 0
    private var cuePushWork: Task<Void, Never> = Task {}
    private var cuePushDebounceTask: Task<Void, Never>?
    private var likesPushTask: Task<Void, Never>?

    private nonisolated(unsafe) var browser: NWBrowser?
    fileprivate nonisolated(unsafe) var connection: NWConnection?

    private var contentEndpoint: NWEndpoint?
    private var contentEndpointsByDeviceToken: [String: NWEndpoint] = [:]
    private var companionServiceName: String?
    private let localContentServer = PeerContentServer()
    private nonisolated(unsafe) var searchTimeout: Task<Void, Never>?
    private nonisolated(unsafe) var rejectionTimeout: Task<Void, Never>?
    private nonisolated(unsafe) var connectTimeout: Task<Void, Never>?
    private nonisolated(unsafe) var reconnectTask: Task<Void, Never>?

    private static let initialReconnectDelay: TimeInterval = 5
    private static let maximumReconnectDelay: TimeInterval = 30

    private var reconnectDelay = CompanionClient.initialReconnectDelay

    private var pendingSessionNonce: String?

    private var lastWaitingReason: String?

    private nonisolated(unsafe) var livenessWatchdog: Task<Void, Never>?

    private var lastFrameAt = Date.distantPast

    private var framer = MessageFramer()
    @Published fileprivate var link: LinkedCompanionStore.LinkRecord?
    /// Same-account phone links are intentionally memory-only. Unlike an
    /// Apple TV pairing they do not need a second keychain credential.
    private var sharedSessionLink: LinkedCompanionStore.LinkRecord?
    private nonisolated(unsafe) var pairingObserver: NSObjectProtocol?
    private nonisolated(unsafe) var likesObserver: NSObjectProtocol?
    private var appliedPlaybackRevision = 0
    private var appliedDJRevision = 0
    private var appliedRevision = -1

    private var activeLink: LinkedCompanionStore.LinkRecord? { sharedSessionLink ?? link }

    var isLinked: Bool { activeLink != nil }
    var linkSessionId: String? { activeLink?.sessionId }
    var linkedClass: DeviceClass { activeLink?.peerClass ?? .tv }
    var linkedName: String { activeLink?.peerName ?? DeviceClass.tv.displayName }
    var isSharingWithPhone: Bool { sharedSessionLink != nil }

    init() {
        link = LinkedCompanionStore.load()
        state = link == nil ? .unlinked : .idle
        restorePersistedSnapshot()
        pairingObserver = NotificationCenter.default.addObserver(
            forName: .pairedTVDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pairingDidChange() }
        }
        likesObserver = NotificationCenter.default.addObserver(
            forName: .likesIndexDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.state == .connected else { return }
                self?.scheduleLikesPushIfSupported()
            }
        }
    }

    deinit {
        if let pairingObserver {
            NotificationCenter.default.removeObserver(pairingObserver)
        }
        if let likesObserver {
            NotificationCenter.default.removeObserver(likesObserver)
        }
        cancelNetworkResources()
    }

    private nonisolated func cancelNetworkResources() {
        searchTimeout?.cancel()
        rejectionTimeout?.cancel()
        connectTimeout?.cancel()
        reconnectTask?.cancel()
        livenessWatchdog?.cancel()
        browser?.cancel()
        connection?.cancel()
    }

    func connect() {
        if sharedSessionLink == nil {
            link = LinkedCompanionStore.load()
        }
        guard let activeLink, activeLink.secret != nil else {
            localContentServer.stop()
            clearPersistedSnapshot()
            state = .unlinked
            return
        }
        startLocalContentServer(for: activeLink)
        guard connection == nil, browser == nil else { return }
        startBrowsing()
    }

    /// Connect to the iPhone that shares this SoundCloud session. The iPhone
    /// advertises the existing CompanionServer protocol while the app is
    /// active, so queue, playback and DJ state remain real remote state.
    func connectToSharedPhone(named name: String = "iPhone") {
        guard let credentials = SharedSessionCompanionLink.current() else {
            state = .unlinked
            return
        }
        sharedSessionLink = LinkedCompanionStore.LinkRecord(
            sessionId: credentials.sessionId,
            secretBase64: credentials.secret.base64EncodedString(),
            pairedAt: Date(),
            deviceClass: .phone,
            displayName: name
        )
        retry()
    }

    func stopSharingWithPhone() {
        guard sharedSessionLink != nil else { return }
        teardown()
        sharedSessionLink = nil
        link = LinkedCompanionStore.load()
        state = link == nil ? .unlinked : .idle
        connect()
    }

    private func pairingDidChange() {
        guard sharedSessionLink == nil else { return }
        let updated = LinkedCompanionStore.load()
        guard updated != link else { return }

        teardown()
        link = updated

        guard updated != nil else {
            localContentServer.stop()
            clearPersistedSnapshot()
            state = .unlinked
            return
        }

        state = .idle
        connect()
    }

    func retry() {
        teardown()
        connect()
    }

    func disconnect() {
        teardown()
        localContentServer.stop()
        if state != .unlinked {
            state = .idle
        }
    }

    private func startBrowsing() {
        state = .searching

        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let newBrowser = NWBrowser(
            for: .bonjour(
                type: BonjourConstants.serviceType,
                domain: BonjourConstants.serviceDomain
            ),
            using: parameters
        )

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }

        newBrowser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor in
                guard case .failed(let error) = browserState, let self else { return }
                self.teardown()
                self.fail("Couldn't search the network: \(error.localizedDescription)")
            }
        }

        browser = newBrowser
        newBrowser.start(queue: .main)

        searchTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.state == .searching else { return }
            self.fail("Couldn't find your Apple TV. Make sure it's awake and on the same Wi‑Fi network.")
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
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
            let staleAfter: TimeInterval = 10
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard case .connected = self.state else { continue }
                guard Date().timeIntervalSince(self.lastFrameAt) > staleAfter else { continue }

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

    private var canAdoptRemoteSession: Bool {
        DeviceSessionStore.load()?.isUsable != true && !DeviceSessionStore.hasLocalSignOut
    }

    private func requestSessionIfNeeded() {
        guard let link = activeLink, let secret = link.secret else { return }
        guard canAdoptRemoteSession else {
            pendingSessionNonce = nil
            return
        }

        let request = SessionRequestPayload.create(sessionId: link.sessionId, secret: secret)
        pendingSessionNonce = request.nonce
        send(.sessionRequest(sessionId: link.sessionId, request: request))
    }

    private func adoptSession(_ offer: SessionOfferPayload) {
        guard canAdoptRemoteSession else { return }

        DeviceSessionStore.save(StoredSession(
            oauthToken: offer.oauthToken,
            refreshToken: offer.refreshToken,
            clientId: offer.clientId,
            expiresAt: offer.expiresAt
        ))
        DeviceSessionRefresher.shared.reset()
        SoundCloudCredentialSource.shared.didCompleteSignIn()
        Log.link.info("[CompanionClient] adopted the Apple TV's SoundCloud session over the paired link")
    }

    private func send(_ message: TokenTransferMessage) {
        guard let connection, let data = try? message.framed() else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func dropConnection() {
        livenessWatchdog?.cancel()
        livenessWatchdog = nil
        continuousFlushTask?.cancel()
        continuousFlushTask = nil
        pendingContinuousControls.removeAll()
        connectTimeout?.cancel()
        connectTimeout = nil
        lastWaitingReason = nil
        companionServiceName = nil
        pendingSessionNonce = nil
        connection?.cancel()
        connection = nil
        framer = MessageFramer()
        appliedRevision = -1
        appliedPlaybackRevision = 0
        appliedDJRevision = 0
        cuePushDebounceTask?.cancel()
        cuePushDebounceTask = nil
        cuePushHighWaterMark = 0
        likesPushTask?.cancel()
        likesPushTask = nil
        CueSyncTarget.requestCompanionPush = nil
        // Keep the last verified queue and Now Playing state visible while the
        // phone reconnects. Fresh signed revisions replace it after .ready.
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        guard let link = activeLink, let secret = link.secret else { return }
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
            return name.hasPrefix(BonjourConstants.companionServiceName) && name.contains(prefix)
        }

        guard let match, case .service(let name, _, _, _) = match.endpoint else { return }
        guard connection == nil || companionServiceName != name else { return }

        searchTimeout?.cancel()
        searchTimeout = nil
        connect(to: match.endpoint, serviceName: name, sessionId: link.sessionId, secret: secret)
    }

    private func connect(to endpoint: NWEndpoint, serviceName: String, sessionId: String, secret: Data) {
        connection?.cancel()
        connection = nil
        connectTimeout?.cancel()
        connectTimeout = nil

        companionServiceName = serviceName
        state = .connecting
        framer = MessageFramer()
        cuePushHighWaterMark = 0

        let parameters = LinkTLS.makeParameters(
            sessionId: sessionId, secret: secret, info: LinkTLS.companionPSKInfo
        )
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveInterval = 3
            tcp.keepaliveCount = 3
        }

        let newConnection = NWConnection(to: endpoint, using: parameters)
        newConnection.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor in
                self?.handleConnectionState(connectionState, for: newConnection)
            }
        }

        connection = newConnection
        newConnection.start(queue: .main)
        receive(on: newConnection)
        startConnectTimeout(for: newConnection)
    }

    private func startConnectTimeout(for source: NWConnection) {
        connectTimeout?.cancel()
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, source === self.connection else { return }
            guard self.state == .connecting else { return }

            let detail = self.lastWaitingReason.map { " (\($0))" } ?? ""
            self.dropConnection()
            self.fail(
                "Couldn't reach your Apple TV\(detail). Make sure it's awake and on the same Wi‑Fi network."
            )
        }
    }

    private func handleConnectionState(_ connectionState: NWConnection.State, for source: NWConnection) {
        guard source === connection else { return }

        switch connectionState {
        case .ready:
            connectTimeout?.cancel()
            connectTimeout = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectDelay = Self.initialReconnectDelay
            lastWaitingReason = nil
            state = .connected
            lastFrameAt = Date()
            startLivenessWatchdog()
            requestQueue()
            requestSessionIfNeeded()
            CueSyncTarget.requestCompanionPush = { [weak self] in
                self?.scheduleCuePush()
            }
            scheduleCuePush()
            scheduleLikesPushIfSupported()
        case .waiting(let error):
            lastWaitingReason = error.localizedDescription
        case .failed(let error):
            dropConnection()
            fail("Lost the connection: \(error.localizedDescription)")
        case .cancelled:
            connectTimeout?.cancel()
            connectTimeout = nil
            connection = nil
        default:
            break
        }
    }

    private func receive(on source: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, source === self.connection else { return }

                if let error {
                    self.dropConnection()
                    self.fail("Lost the connection: \(error.localizedDescription)")
                    return
                }

                if let data, !data.isEmpty {
                    self.framer.append(data)
                    while let message = try? self.framer.next() {
                        await self.handle(message)
                    }
                }

                if isComplete {
                    self.dropConnection()
                    self.fail("Your Apple TV closed the connection.")
                } else {
                    self.receive(on: source)
                }
            }
        }
    }

    private func handle(_ message: TokenTransferMessage) async {
        lastFrameAt = Date()

        guard let link = activeLink, let secret = link.secret else { return }
        guard message.sessionId == link.sessionId else { return }

        switch message.type {
        case .queueState:
            guard let queue = message.queue else { return }
            guard queue.verify(sessionId: link.sessionId, secret: secret) else { return }
            guard queue.revision > appliedRevision else { return }

            appliedRevision = queue.revision
            tracks = queue.tracks
            currentIndex = queue.currentIndex
            isPlaying = queue.isPlaying
            hasSnapshot = true
            persistSnapshot()

        case .playbackState:
            guard let playback = message.playback else { return }
            guard playback.verify(sessionId: link.sessionId, secret: secret) else { return }
            guard playback.revision > appliedPlaybackRevision else { return }
            appliedPlaybackRevision = playback.revision
            self.playback = playback
            persistSnapshot()

        case .djState:
            guard let dj = message.dj else { return }
            guard dj.verify(sessionId: link.sessionId, secret: secret) else { return }
            guard dj.revision > appliedDJRevision else { return }
            appliedDJRevision = dj.revision
            self.djState = dj
            persistSnapshot()

        case .cueSync:
            guard let payload = message.cueSync else { return }
            guard payload.verify(sessionId: link.sessionId, secret: secret) else { return }
            guard payload.isFresh() else { return }
            guard cueReplayGuard.admit(payload.nonce) else { return }
            guard let body = CueSyncBody.decode(payload.body) else { return }
            _ = await CueStore.shared.adopt(body.cues)
            _ = await CueStore.shared.adoptDismissals(body.dismissals)

        case .sessionOffer:
            guard let offer = message.sessionOffer else { return }
            guard let expected = pendingSessionNonce, offer.requestNonce == expected else { return }
            guard offer.verify(sessionId: link.sessionId, secret: secret) else { return }
            guard offer.isFresh() else { return }
            pendingSessionNonce = nil
            adoptSession(offer)

        case .sessionUnavailable:
            pendingSessionNonce = nil

        case .authHandoffSessionRequest:
            await handleAuthHandoffRequest(toPeerWith: link, secret: secret)

        case .error:
            rejection = message.error
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
        guard activeLink?.sessionId == link.sessionId else { return }

        NotificationCenter.default.post(
            name: .companionClientAuthHandoffRequest,
            object: self,
            userInfo: [
                CompanionClientAuthHandoffRequestSessionIdKey: link.sessionId,
                CompanionClientAuthHandoffRequestSecretKey: secret.base64EncodedString()
            ]
        )
        Log.link.info("[CompanionClient] peer asked for auth handoff; posted sign-in request notification")
    }

    /// Send a freshly captured token pair back to the peer. This is used after
    /// the user completes the "sign in for device" flow on the companion.
    func sendAuthHandoffSession(_ session: StoredSession) {
        guard let link = activeLink, let secret = link.secret else {
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

    private func restorePersistedSnapshot() {
        guard let link = activeLink,
              let data = UserDefaults.standard.data(forKey: Self.snapshotDefaultsKey),
              let snapshot = try? JSONDecoder().decode(PersistedSnapshot.self, from: data),
              snapshot.sessionId == link.sessionId else { return }
        tracks = snapshot.tracks
        currentIndex = min(max(0, snapshot.currentIndex), max(0, tracks.count - 1))
        isPlaying = false
        playback = snapshot.playback
        djState = snapshot.djState
        hasSnapshot = !tracks.isEmpty || snapshot.playback?.trackId != nil
    }

    private func persistSnapshot() {
        guard let link = activeLink else { return }
        let snapshot = PersistedSnapshot(
            sessionId: link.sessionId,
            tracks: tracks,
            currentIndex: currentIndex,
            isPlaying: isPlaying,
            playback: playback,
            djState: djState,
            savedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.snapshotDefaultsKey)
    }

    private func clearPersistedSnapshot() {
        UserDefaults.standard.removeObject(forKey: Self.snapshotDefaultsKey)
        tracks = []
        currentIndex = 0
        isPlaying = false
        playback = nil
        djState = nil
        hasSnapshot = false
    }

    func addToQueue(trackId: String, atIndex: Int = -1) {
        send(.queueAdd, fromIndex: -1, toIndex: atIndex, trackId: trackId)
    }

    func requestQueue() {
        send(.queueRequest, fromIndex: -1, toIndex: -1, trackId: "")
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

        send(.queueReorder, fromIndex: source, toIndex: target, trackId: trackId)
    }

    func remove(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        let trackId = tracks[index].id
        let playingId = tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : nil

        tracks.remove(at: index)
        if let playingId, let newIndex = tracks.firstIndex(where: { $0.id == playingId }) {
            currentIndex = newIndex
        } else {
            currentIndex = min(index, max(0, tracks.count - 1))
        }

        send(.queueRemove, fromIndex: index, toIndex: -1, trackId: trackId)
    }

    func jump(to index: Int) {
        guard tracks.indices.contains(index) else { return }
        let trackId = tracks[index].id
        currentIndex = index
        isPlaying = true
        send(.queueJump, fromIndex: index, toIndex: -1, trackId: trackId)
    }

    private func scheduleCuePush() {
        guard cuePushDebounceTask == nil else { return }
        cuePushDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.cuePushDebounceTask = nil
            self.enqueueCuePush()
        }
    }

    private func enqueueCuePush() {
        let previous = cuePushWork
        cuePushWork = Task { @MainActor [weak self] in
            await previous.value
            await self?.runCuePush()
        }
    }

    private func runCuePush() async {
        guard let link = activeLink, let secret = link.secret else { return }
        while connection != nil {
            let cues = await CueStore.shared.syncRecords(changedSince: cuePushHighWaterMark, limit: CueSyncChunking.maxBatchSize)
            let dismissals = await CueStore.shared.dismissalRecords(changedSince: cuePushHighWaterMark, limit: CueSyncChunking.maxBatchSize)
            if cues.isEmpty && dismissals.isEmpty { return }

            guard let body = CueSyncBody(cues: cues, dismissals: dismissals).encoded() else { return }
            let payload = CueSyncPayload.create(
                body: body, cueCount: cues.count, dismissalCount: dismissals.count,
                sessionId: link.sessionId, secret: secret
            )
            send(.cueSync(sessionId: link.sessionId, payload: payload))

            let batchMax = max(cues.map(\.updatedAtMillis).max() ?? 0, dismissals.map(\.dismissedAtMillis).max() ?? 0)
            if batchMax <= cuePushHighWaterMark { return }
            cuePushHighWaterMark = batchMax
        }
    }

    private func scheduleLikesPushIfSupported() {
        guard DeviceClass.current == .phone || DeviceClass.current == .pad else { return }
        likesPushTask?.cancel()
        likesPushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.runLikesPush()
        }
    }

    private func runLikesPush() async {
        guard let link = activeLink,
              let secret = link.secret,
              let accountId = SoundCloudCredentialSource.shared.currentUser?.id
                ?? SubscriptionService.shared.authenticatedAccountID else { return }

        let snapshotId = UUID().uuidString
        let batchSize = 25
        var offset = 0
        while connection != nil, !Task.isCancelled {
            let records = await LibraryCache.shared.loadLikesForPeer(offset: offset, limit: batchSize)
            let isComplete = records.count < batchSize
            let body = LikesPeerBody(
                accountId: accountId,
                snapshotId: snapshotId,
                records: records,
                isComplete: isComplete
            )
            guard let encoded = body.encoded() else { return }
            let payload = LikesSyncPayload.create(
                body: encoded,
                accountId: accountId,
                recordCount: records.count,
                isComplete: isComplete,
                sessionId: link.sessionId,
                secret: secret
            )
            send(.likesSync(sessionId: link.sessionId, payload: payload))
            if isComplete { return }
            offset += records.count
            await Task.yield()
        }
    }

    private func send(_ type: MessageType, fromIndex: Int, toIndex: Int, trackId: String) {
        guard let link = activeLink, let secret = link.secret, let connection else { return }

        let command = QueueCommandPayload.create(
            type: type,
            fromIndex: fromIndex,
            toIndex: toIndex,
            trackId: trackId,
            revision: max(0, appliedRevision),
            sessionId: link.sessionId,
            secret: secret
        )

        guard let data = try? TokenTransferMessage
            .queueCommand(type, sessionId: link.sessionId, command: command)
            .framed() else { return }

        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

extension CompanionClient {

    func play()     { sendControl(.transportPlay) }
    func pause()    { sendControl(.transportPause) }
    func next()     { sendControl(.transportNext) }
    func previous() { sendControl(.transportPrevious) }

    func seek(toSeconds seconds: Double) {
        sendControl(.transportSeek, parameter: .position, value: seconds)
    }

    func setDJEnabled(_ enabled: Bool) { sendControl(enabled ? .djEnable : .djDisable) }
    func setAutoMixEnabled(_ enabled: Bool) { sendControl(enabled ? .djAutoEnable : .djAutoDisable) }
    func setDJProfile(_ profileId: DJProfileID) {
        guard let index = DJProfile.all.firstIndex(where: { $0.id == profileId }) else { return }
        sendControl(.djProfile, parameter: .profile, value: Double(index))
    }
    func mixNow()                      { sendControl(.djMixNow) }

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

    private func sendControl(
        _ type: MessageType,
        deck: ControlDeck = .none,
        parameter: ControlParameter = .none,
        value: Double = 0,
        value2: Double = 0,
        continuous: Bool = false
    ) {
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

        transmitControl(
            type, deck: deck, parameter: parameter, value: value, value2: value2,
            continuous: type.isContinuousControl
        )
    }

    /// UI controls can produce updates at display-link speed. Sending only the
    /// newest value once per frame prevents a slow Wi-Fi link from building a
    /// stale command backlog while preserving responsive controls.
    private func scheduleContinuousFlush() {
        guard continuousFlushTask == nil else { return }
        continuousFlushTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled else { return }
                let batch = Array(self.pendingContinuousControls.values)
                self.pendingContinuousControls.removeAll(keepingCapacity: true)
                for control in batch {
                    self.transmitControl(
                        control.type,
                        deck: control.deck,
                        parameter: control.parameter,
                        value: control.value,
                        value2: control.value2,
                        continuous: true
                    )
                }
                if self.pendingContinuousControls.isEmpty {
                    self.continuousFlushTask = nil
                    return
                }
            }
        }
    }

    private func transmitControl(
        _ type: MessageType,
        deck: ControlDeck,
        parameter: ControlParameter,
        value: Double,
        value2: Double,
        continuous: Bool
    ) {
        guard let link = activeLink, let secret = link.secret, let connection else { return }

        if continuous { controlSequence &+= 1 }

        let control = ControlCommandPayload.create(
            type: type,
            deck: deck,
            parameter: parameter,
            value: value,
            value2: value2,
            sequence: continuous ? controlSequence : 0,
            sessionId: link.sessionId,
            secret: secret
        )

        guard let data = try? TokenTransferMessage
            .controlCommand(type, sessionId: link.sessionId, control: control)
            .framed()
        else { return }

        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

extension CompanionClient: CompanionOutputTarget {
    var isReachable: Bool {
        if case .connected = state { return true }
        return false
    }

    func sendPlayback(track: Track, queue: [Track], index: Int, position: TimeInterval, isPlaying: Bool) {
        guard isReachable else { return }

        let upcoming = queue.indices.contains(index)
            ? Array(queue[index...])
            : [track]
        for item in upcoming {
            addToQueue(trackId: item.id)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard let landed = self.tracks.firstIndex(where: { $0.id == track.id }) else { return }
            self.jump(to: landed)
            try? await Task.sleep(for: .milliseconds(300))
            if position > 1 { self.seek(toSeconds: position) }
            if !isPlaying { self.pause() }
        }
    }

    func pausePlayback() {
        guard isReachable else { return }
        pause()
    }
}

extension CompanionClient: PeerContentSessionProvider {
    var peerContentEndpoint: (endpoint: NWEndpoint, sessionId: String, secret: Data)? {
        guard let contentEndpoint, let link = activeLink, let secret = link.secret else { return nil }
        return (contentEndpoint, link.sessionId, secret)
    }

    func peerContentEndpoint(forDeviceId deviceId: String) -> (endpoint: NWEndpoint, sessionId: String, secret: Data)? {
        guard let link = activeLink, let secret = link.secret else { return nil }
        let token = PeerContentServer.serviceToken(for: deviceId)
        guard let endpoint = contentEndpointsByDeviceToken[token] else { return nil }
        return (endpoint, link.sessionId, secret)
    }
}

extension CompanionClient {
    func playNext(trackId: String) {
        addToQueue(trackId: trackId, atIndex: min(currentIndex + 1, tracks.count))
    }

    func addToEnd(trackId: String) {
        addToQueue(trackId: trackId, atIndex: -1)
    }

    func replaceQueue(withTrackId trackId: String) {
        send(.queueReplace, fromIndex: -1, toIndex: -1, trackId: trackId)
    }
}

extension Notification.Name {
    static let companionClientAuthHandoffRequest = Notification.Name("red.forbes.sounding.companion.auth-handoff-request")
}

let CompanionClientAuthHandoffRequestSessionIdKey = "sessionId"
let CompanionClientAuthHandoffRequestSecretKey = "secret"
