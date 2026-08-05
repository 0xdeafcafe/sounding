import Foundation
import Network
import Combine
import os

@MainActor
final class CompanionServer: ObservableObject {
    static let shared = CompanionServer()

    @Published private(set) var isLinked = false

    @Published private(set) var isPhoneConnected = false

    @Published private(set) var lastError: String?

    private nonisolated(unsafe) var listener: NWListener?
    private nonisolated(unsafe) var connection: NWConnection?
    private nonisolated(unsafe) var contentBrowser: NWBrowser?

    private let contentServer = PeerContentServer()
    private var remoteContentEndpoints: [String: NWEndpoint] = [:]

    private var sessionId: String?
    private var secret: Data?

    private var framer = MessageFramer()
    private var replayGuard = ReplayGuard()
    private var sessionReplayGuard = ReplayGuard()
    private var cueReplayGuard = ReplayGuard()
    private var likesReplayGuard = ReplayGuard()
    private var sequenceGate = SequenceGate()
    private var cancellables = Set<AnyCancellable>()

    private var cuePushHighWaterMark: Int64 = 0
    private var cuePushWork: Task<Void, Never> = Task {}

    private var revision = 0
    private var playbackRevision = 0
    private var djRevision = 0

    private var work: Task<Void, Never> = Task {}

    private var lastFingerprint: Int?
    private var lastPlaybackFingerprint: Int?
    private var lastDJFingerprint: Int?

    private var pendingAuthHandoffSessionContinuation: CheckedContinuation<AuthHandoffSessionOfferPayload?, Never>?

    private nonisolated(unsafe) var stateTickTask: Task<Void, Never>?
    private nonisolated(unsafe) var listenerRestart: Task<Void, Never>?

    private init() {}

    deinit {
        cancelNetworkResources()
    }

    private nonisolated func cancelNetworkResources() {
        connection?.cancel()
        listener?.cancel()
        contentBrowser?.cancel()
        stateTickTask?.cancel()
        listenerRestart?.cancel()
    }

    func pair(with credentials: SessionCredentials) {
        #if os(tvOS)
        self.store(sessionId: credentials.sessionId, secret: credentials.secret)
        #endif
        activate(sessionId: credentials.sessionId, secret: credentials.secret)
    }

    func startIfPaired() {
        #if os(tvOS)
        guard listener == nil, let stored = loadStoredPairing() else { return }
        activate(sessionId: stored.sessionId, secret: stored.secret)
        #endif
    }

    /// iPhone uses the same authenticated companion protocol as Apple TV,
    /// but the shared SoundCloud session supplies the ephemeral local-network
    /// credential. Nothing is written to the keychain for this mode.
    func startForSharedSession() {
        guard listener == nil, let credentials = SharedSessionCompanionLink.current() else { return }
        activate(sessionId: credentials.sessionId, secret: credentials.secret)
    }

    func unpair() {
        #if os(tvOS)
        do {
            try KeychainService.shared.delete(forKey: Keys.sessionId)
            try KeychainService.shared.delete(forKey: Keys.secret)
        } catch {
            Log.auth.error("[CompanionServer] unpair keychain delete failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        stop()
        isLinked = false
    }

    /// Ask the paired companion to broker a fresh SoundCloud session for this
    /// device. The companion runs a sign-in flow and returns a brand-new token
    /// pair that belongs to this device, not to the companion.
    func requestAuthHandoffSession() async -> AuthHandoffSessionOfferPayload? {
        guard isPhoneConnected, let sessionId else { return nil }

        return await withCheckedContinuation { continuation in
            pendingAuthHandoffSessionContinuation = continuation
            send(.authHandoffSessionRequest(sessionId: sessionId))

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, let pending = self.pendingAuthHandoffSessionContinuation else { return }
                self.pendingAuthHandoffSessionContinuation = nil
                pending.resume(returning: nil)
            }
        }
    }

    private func adoptAuthHandoffSession(_ offer: AuthHandoffSessionOfferPayload) {
        let provisional = StoredSession(
            oauthToken: offer.oauthToken,
            refreshToken: offer.refreshToken,
            clientId: offer.clientId,
            expiresAt: offer.expiresAtMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        )
        Task { @MainActor in
            let session = await DeviceSessionRefresher.shared.refresh(provisional) ?? provisional
            DeviceSessionStore.save(session)
            DeviceSessionRefresher.shared.reset()
            SoundCloudCredentialSource.shared.didCompleteSignIn()
            Log.link.info("[CompanionServer] adopted fresh auth handoff session from companion and refreshed once")
        }
    }

    func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        listenerRestart?.cancel()
        listenerRestart = nil
        contentServer.stop()
        contentBrowser?.cancel()
        contentBrowser = nil
        remoteContentEndpoints.removeAll()
        stateTickTask?.cancel()
        stateTickTask = nil
        cancellables.removeAll()
        framer = MessageFramer()
        sequenceGate.reset()
        lastFingerprint = nil
        lastPlaybackFingerprint = nil
        lastDJFingerprint = nil
        isPhoneConnected = false
        cuePushHighWaterMark = 0
        CueSyncTarget.requestCompanionPush = nil
    }

    private func activate(sessionId: String, secret: Data) {
        self.sessionId = sessionId
        self.secret = secret
        isLinked = true
        startListener(sessionId: sessionId, secret: secret)
        startContentServer(sessionId: sessionId, secret: secret)
        startContentBrowsing(sessionId: sessionId)
        observePlayer()
        startStateTicking()
        CueSyncTarget.requestCompanionPush = { [weak self] in
            self?.pushCueChanges()
        }
    }

    private func startContentServer(sessionId: String, secret: Data) {
        do {
            try contentServer.start(
                sessionId: sessionId,
                secret: secret,
                deviceId: DownloadManifestDeviceIdentity.deviceId()
            )
        } catch {
            lastError = "Failed to start content server: \(error.localizedDescription)"
        }
    }

    private func startContentBrowsing(sessionId: String) {
        contentBrowser?.cancel()
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: BonjourConstants.serviceType, domain: BonjourConstants.serviceDomain),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                let ownName = self.contentServer.advertisedServiceName
                var endpoints: [String: NWEndpoint] = [:]
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint,
                          name != ownName,
                          let token = PeerContentServer.serviceToken(
                            fromServiceName: name, sessionId: sessionId
                          ) else { continue }
                    endpoints[token] = result.endpoint
                }
                self.remoteContentEndpoints = endpoints
            }
        }
        contentBrowser = browser
        browser.start(queue: .main)
    }

    private func startListener(sessionId: String, secret: Data) {
        listener?.cancel()
        listener = nil
        listenerRestart?.cancel()
        listenerRestart = nil

        do {
            let parameters = LinkTLS.makeParameters(
                sessionId: sessionId, secret: secret, info: LinkTLS.companionPSKInfo
            )
            parameters.includePeerToPeer = false

            let newListener = try NWListener(using: parameters)
            newListener.service = NWListener.Service(
                name: "\(BonjourConstants.companionServiceName)-\(sessionId.prefix(8))",
                type: BonjourConstants.serviceType
            )

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state)
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }

            listener = newListener
            newListener.start(queue: .main)
            lastError = nil
        } catch {
            lastError = "Failed to start remote listener: \(error.localizedDescription)"
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            Log.link.info("[CompanionServer] Advertising remote control service")
        case .failed(let error):
            lastError = "Remote listener failed: \(error.localizedDescription)"
            scheduleListenerRestart()
        default:
            break
        }
    }

    private func scheduleListenerRestart() {
        guard let sessionId, let secret else { return }

        listener?.cancel()
        listener = nil
        listenerRestart?.cancel()
        listenerRestart = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.listener == nil else { return }
            guard self.sessionId == sessionId else { return }
            self.startListener(sessionId: sessionId, secret: secret)
        }
    }

    private func handleNewConnection(_ newConnection: NWConnection) {
        connection?.cancel()
        connection = newConnection
        framer = MessageFramer()
        sequenceGate.reset()
        cuePushHighWaterMark = 0

        newConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state, for: newConnection)
            }
        }

        newConnection.start(queue: .main)
        receiveData(on: newConnection)
    }

    private func handleConnectionState(_ state: NWConnection.State, for source: NWConnection) {
        guard source === connection else { return }

        switch state {
        case .ready:
            isPhoneConnected = true
            publish(force: true)
            publishPlaybackAndDJState(force: true)
            pushCueChanges()
        case .failed, .cancelled:
            isPhoneConnected = false
            connection = nil
        default:
            break
        }
    }

    private func receiveData(on source: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, source === self.connection else { return }

                if error != nil {
                    self.isPhoneConnected = false
                    self.connection = nil
                    return
                }

                if let data, !data.isEmpty {
                    self.processReceivedData(data)
                }

                if isComplete {
                    self.isPhoneConnected = false
                    source.cancel()
                    self.connection = nil
                } else {
                    self.receiveData(on: source)
                }
            }
        }
    }

    private func processReceivedData(_ data: Data) {
        framer.append(data)

        while true {
            let message: TokenTransferMessage?
            do {
                message = try framer.next()
            } catch is MessageFramer.FramingError {
                sendError("Malformed frame")
                connection?.cancel()
                connection = nil
                isPhoneConnected = false
                return
            } catch {
                sendError("Failed to parse message: \(error.localizedDescription)")
                continue
            }
            guard let message else { return }
            handle(message)
        }
    }

    private func handle(_ message: TokenTransferMessage) {
        guard let sessionId, let secret else { return }

        guard message.sessionId == sessionId else {
            sendError("Session ID mismatch")
            return
        }

        if message.type.isQueueCommand {
            handleQueueCommand(message, sessionId: sessionId, secret: secret)
        } else if message.type.isControlCommand {
            handleControlCommand(message, sessionId: sessionId, secret: secret)
        } else if message.type == .sessionRequest {
            handleSessionRequest(message, sessionId: sessionId, secret: secret)
        } else if message.type == .cueSync {
            handleCueSync(message, sessionId: sessionId, secret: secret)
        } else if message.type == .likesSync {
            handleLikesSync(message, sessionId: sessionId, secret: secret)
        } else if message.type == .authHandoffSessionOffer {
            handleAuthHandoffSessionOffer(message, sessionId: sessionId, secret: secret)
        } else {
            sendError("Unsupported message")
        }
    }

    private func handleCueSync(_ message: TokenTransferMessage, sessionId: String, secret: Data) {
        guard let payload = message.cueSync else {
            sendError("Unsupported message")
            return
        }

        guard payload.verify(sessionId: sessionId, secret: secret) else {
            sendError("Invalid signature")
            return
        }

        guard payload.isFresh() else {
            sendError("Command expired")
            return
        }

        guard cueReplayGuard.admit(payload.nonce) else {
            sendError("Duplicate command")
            return
        }

        guard let body = CueSyncBody.decode(payload.body) else {
            sendError("Unsupported message")
            return
        }

        enqueue {
            _ = await CueStore.shared.adopt(body.cues)
            _ = await CueStore.shared.adoptDismissals(body.dismissals)
        }
    }

    private func handleLikesSync(_ message: TokenTransferMessage, sessionId: String, secret: Data) {
        guard let payload = message.likesSync,
              payload.verify(sessionId: sessionId, secret: secret),
              payload.isFresh(),
              likesReplayGuard.admit(payload.nonce),
              let body = LikesPeerBody.decode(payload.body),
              payload.accountId == body.accountId,
              payload.recordCount == body.records.count,
              payload.isComplete == body.isComplete,
              let localAccountId = SoundCloudCredentialSource.shared.currentUser?.id
                ?? SubscriptionService.shared.authenticatedAccountID,
              localAccountId == body.accountId else {
            sendError("Likes sync rejected")
            return
        }

        enqueue {
            _ = await LikesPeerImportCoordinator.shared.adopt(
                body, expectedAccountId: localAccountId
            )
        }
    }

    private func handleSessionRequest(_ message: TokenTransferMessage, sessionId: String, secret: Data) {
        guard let request = message.sessionRequest else {
            sendError("Unsupported message")
            return
        }

        guard request.verify(sessionId: sessionId, secret: secret) else {
            sendError("Invalid signature")
            return
        }

        guard request.isFresh() else {
            sendError("Command expired")
            return
        }

        guard sessionReplayGuard.admit(request.nonce) else {
            sendError("Duplicate command")
            return
        }

        // An Apple TV is strictly a credential receiver. Pairing can establish
        // remote control, but a request from another device must never export
        // the TV's SoundCloud session or refresh token.
        Log.link.info("[CompanionServer] declined outbound session request; Apple TV is receiver-only")
        send(.sessionUnavailable(sessionId: sessionId))
    }

    private func handleAuthHandoffSessionOffer(_ message: TokenTransferMessage, sessionId: String, secret: Data) {
        guard let offer = message.authHandoffSessionOffer else {
            sendError("Unsupported message")
            return
        }

        guard offer.verify(sessionId: sessionId, secret: secret) else {
            sendError("Invalid signature")
            return
        }

        guard offer.isFresh() else {
            sendError("Session offer expired")
            return
        }

        if let continuation = pendingAuthHandoffSessionContinuation {
            pendingAuthHandoffSessionContinuation = nil
            continuation.resume(returning: offer)
        } else {
            adoptAuthHandoffSession(offer)
        }
    }

    private func handleQueueCommand(_ message: TokenTransferMessage, sessionId: String, secret: Data) {
        guard let command = message.command else {
            sendError("Unsupported message")
            return
        }

        guard command.verify(type: message.type, sessionId: sessionId, secret: secret) else {
            sendError("Invalid signature")
            return
        }

        guard command.isFresh() else {
            sendError("Command expired")
            return
        }

        guard replayGuard.admit(command.nonce) else {
            sendError("Duplicate command")
            return
        }

        switch message.type {
        case .queueRequest:
            publish(force: true)
        case .queueReorder:
            applyReorder(command)
        case .queueRemove:
            applyRemove(command)
        case .queueJump:
            applyJump(command)
        case .queueAdd:
            applyAdd(command)
        case .queueReplace:
            applyReplace(command)
        default:
            break
        }
    }

    private func handleControlCommand(_ message: TokenTransferMessage, sessionId: String, secret: Data) {
        guard let control = message.control else {
            sendError("Unsupported message")
            return
        }

        guard control.verify(type: message.type, sessionId: sessionId, secret: secret) else {
            sendError("Invalid signature")
            return
        }

        guard control.isFresh() else {
            sendError("Command expired")
            return
        }

        if message.type.isContinuousControl {
            guard sequenceGate.admit(control.sequence, type: message.type, deck: control.deck) else {
                return
            }
        } else {
            guard replayGuard.admit(control.nonce) else {
                sendError("Duplicate command")
                return
            }
        }

        applyControl(message.type, control)
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task { @MainActor in
            await previous.value
            await operation()
        }
    }

    private func pushCueChanges() {
        let previous = cuePushWork
        cuePushWork = Task { @MainActor [weak self] in
            await previous.value
            await self?.runCuePush()
        }
    }

    private func runCuePush() async {
        guard let sessionId, let secret else { return }
        while connection != nil {
            let cues = await CueStore.shared.syncRecords(changedSince: cuePushHighWaterMark, limit: CueSyncChunking.maxBatchSize)
            let dismissals = await CueStore.shared.dismissalRecords(changedSince: cuePushHighWaterMark, limit: CueSyncChunking.maxBatchSize)
            if cues.isEmpty && dismissals.isEmpty { return }

            guard let body = CueSyncBody(cues: cues, dismissals: dismissals).encoded() else { return }
            let payload = CueSyncPayload.create(
                body: body, cueCount: cues.count, dismissalCount: dismissals.count,
                sessionId: sessionId, secret: secret
            )
            send(.cueSync(sessionId: sessionId, payload: payload))

            let batchMax = max(cues.map(\.updatedAtMillis).max() ?? 0, dismissals.map(\.dismissedAtMillis).max() ?? 0)
            if batchMax <= cuePushHighWaterMark { return }
            cuePushHighWaterMark = batchMax
        }
    }

    private func applyReorder(_ command: QueueCommandPayload) {
        enqueue { [weak self] in
            guard let self, self.targetIsStillValid(command) else { return }
            PlayerService.shared.moveQueueItem(from: command.fromIndex, to: command.toIndex)
            self.publish(force: true)
        }
    }

    private func applyRemove(_ command: QueueCommandPayload) {
        enqueue { [weak self] in
            guard let self, self.targetIsStillValid(command) else { return }
            await PlayerService.shared.removeFromQueue(at: command.fromIndex)
            self.publish(force: true)
        }
    }

    private func applyJump(_ command: QueueCommandPayload) {
        enqueue { [weak self] in
            guard let self, self.targetIsStillValid(command) else { return }
            await PlayerService.shared.playTrackAt(index: command.fromIndex)
            self.publish(force: true)
        }
    }

    private func applyAdd(_ command: QueueCommandPayload) {
        enqueue { [weak self] in
            guard let self else { return }
            do {
                let track = try await SoundCloudAPI.shared.getTrack(id: command.trackId)
                let queue = PlayerService.shared.queue
                if command.toIndex < 0 || command.toIndex >= queue.count {
                    PlayerService.shared.addToQueue(track)
                } else {
                    PlayerService.shared.insertIntoQueue(track, at: command.toIndex)
                }
                self.publish(force: true)
            } catch {
                self.sendError("Could not add track: \(error.localizedDescription)")
            }
        }
    }

    private func applyReplace(_ command: QueueCommandPayload) {
        enqueue { [weak self] in
            guard let self else { return }
            do {
                let track = try await SoundCloudAPI.shared.getTrack(id: command.trackId)
                await PlayerService.shared.play(track, in: [track])
                self.publish(force: true)
            } catch {
                self.sendError("Could not play track: \(error.localizedDescription)")
            }
        }
    }

    private func targetIsStillValid(_ command: QueueCommandPayload) -> Bool {
        let queue = PlayerService.shared.queue
        guard command.fromIndex >= 0,
              command.fromIndex < queue.count,
              queue[command.fromIndex].id == command.trackId else {
            sendError("Queue has changed")
            publish(force: true)
            return false
        }
        return true
    }

    private func applyDiscreteControl(_ body: () -> Void) {
        body()
        publishPlaybackAndDJState(force: true)
    }

    private func applyMixEngineCommand(discrete: Bool, _ body: () -> Void) {
        guard PlayerService.shared.isMixEngineLive else {
            if discrete { sendError("DJ engine is not live") }
            return
        }
        body()
    }

    private func applyControl(_ type: MessageType, _ control: ControlCommandPayload) {
        switch type {
        case .transportPlay:
            applyDiscreteControl { PlayerService.shared.play() }
        case .transportPause:
            applyDiscreteControl { PlayerService.shared.pause() }
        case .transportSeek:
            applyDiscreteControl { PlayerService.shared.seek(to: control.value) }
        case .transportNext:
            enqueue { [weak self] in
                await PlayerService.shared.playNext()
                self?.publishPlaybackAndDJState(force: true)
            }
        case .transportPrevious:
            enqueue { [weak self] in
                await PlayerService.shared.playPrevious()
                self?.publishPlaybackAndDJState(force: true)
            }

        case .djEnable:
            applyDiscreteControl {
                DJTransitionService.shared.isEnabled = true
                PlayerService.shared.setDJSessionEnabled(true)
            }
        case .djDisable:
            applyDiscreteControl {
                DJTransitionService.shared.isEnabled = false
                PlayerService.shared.setAutomaticMixEnabled(false)
                PlayerService.shared.setDJSessionEnabled(false)
            }
        case .djAutoEnable:
            applyDiscreteControl { PlayerService.shared.setAutomaticMixEnabled(true) }
        case .djAutoDisable:
            applyDiscreteControl { PlayerService.shared.setAutomaticMixEnabled(false) }
        case .djProfile:
            applyDiscreteControl {
                let index = Int(control.value.rounded())
                guard DJProfile.all.indices.contains(index) else { return }
                PlayerService.shared.setDJProfile(DJProfile.all[index].id)
            }

        case .djMixNow:
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true) {
                    PlayerService.shared.startMix()
                }
            }
        case .djCue:
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true) {
                    guard let deck = Self.mixEngineDeck(control.deck) else { return }
                    MixEngine.shared.seek(deck: deck, to: control.value)
                }
            }
        case .djHotCueSet:
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true) {
                    guard let deck = Self.mixEngineDeck(control.deck),
                          let trackId = MixEngine.shared[deck].trackId else { return }
                    let index = min(CuePoint.hotCueSlotCount - 1, max(0, Int(control.value.rounded())))
                    let millis = CueTime.millis(fromSeconds: max(0, control.value2))
                    Task { await CueStore.shared.setHotCue(trackId: trackId, index: index, positionMillis: millis) }
                }
            }
        case .djDeckPlayPause:
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true) {
                    guard let deck = Self.mixEngineDeck(control.deck) else { return }
                    MixEngine.shared.togglePlayPause(deck: deck)
                }
            }
        case .djLoopSet:
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true) {
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
                self.applyMixEngineCommand(discrete: true) {
                    guard let deck = Self.mixEngineDeck(control.deck) else { return }
                    MixEngine.shared.clearLoop(on: deck)
                }
            }
        case .djSync:
            applyDiscreteControl {
                self.applyMixEngineCommand(discrete: true) {
                    guard let deck = Self.mixEngineDeck(control.deck) else { return }
                    _ = MixEngine.shared.sync(
                        deck,
                        to: deck.other,
                        maxPercent: PlayerService.shared.djProfile?.maxAbsRatePercent
                            ?? MixEngine.maxTempoMatchPercent
                    )
                }
            }

        case .djCrossfader:
            applyMixEngineCommand(discrete: false) {
                MixEngine.shared.crossfade = control.value
            }
        case .djEQ:
            applyMixEngineCommand(discrete: false) {
                guard let deck = Self.mixEngineDeck(control.deck),
                      let band = Self.eqBand(for: control.parameter) else { return }
                MixEngine.shared.setEQ(band, on: deck, toDecibels: control.value)
            }
        case .djFilter:
            applyMixEngineCommand(discrete: false) {
                guard let deck = Self.mixEngineDeck(control.deck) else { return }
                switch control.parameter {
                case .filterCutoff:
                    MixEngine.shared.setFilterCutoff(control.value, on: deck)
                case .filterResonance:
                    MixEngine.shared.setFilterResonance(control.value, on: deck)
                default:
                    break
                }
            }
        case .djRate:
            applyMixEngineCommand(discrete: false) {
                guard let deck = Self.mixEngineDeck(control.deck) else { return }
                MixEngine.shared.setRate(control.value, on: deck)
            }
        case .djJog:
            applyMixEngineCommand(discrete: false) {
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

    private static func eqBand(for parameter: ControlParameter) -> MixEngine.EQBand? {
        switch parameter {
        case .eqLow: return .low
        case .eqMid: return .mid
        case .eqHigh: return .high
        default: return nil
        }
    }

    private func observePlayer() {
        guard cancellables.isEmpty else { return }

        PlayerService.shared.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.publish(force: false)
                }
            }
            .store(in: &cancellables)
    }

    private func publish(force: Bool) {
        guard let sessionId, let secret, connection != nil else { return }

        let player = PlayerService.shared
        let fingerprint = fingerprint(of: player)
        if !force && fingerprint == lastFingerprint { return }

        if fingerprint != lastFingerprint {
            revision &+= 1
            lastFingerprint = fingerprint
        }

        let payload = QueueStatePayload.create(
            tracks: player.queue.map(Self.wireTrack),
            currentIndex: player.currentIndex,
            isPlaying: player.isPlaying,
            revision: revision,
            sessionId: sessionId,
            secret: secret
        )

        send(.queueState(sessionId: sessionId, queue: payload))
    }

    private func fingerprint(of player: PlayerService) -> Int {
        var hasher = Hasher()
        for track in player.queue {
            hasher.combine(track.id)
        }
        hasher.combine(player.currentIndex)
        hasher.combine(player.isPlaying)
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

    // The phone interpolates deck clocks locally. Four state snapshots per
    // second keep controls honest without making the TV serialize and sign two
    // full payloads every display frame.
    private static let stateTickNanoseconds: UInt64 = 250_000_000
    private static let keepaliveTicks = 8 // 4 Hz ticker → every 2s

    private func startStateTicking() {
        guard stateTickTask == nil else { return }
        stateTickTask = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                tick &+= 1
                let keepalive = tick % Self.keepaliveTicks == 0
                self.publishPlaybackAndDJState(force: keepalive)
                try? await Task.sleep(nanoseconds: Self.stateTickNanoseconds)
            }
        }
    }

    private func publishPlaybackAndDJState(force: Bool) {
        guard let sessionId, let secret, connection != nil else { return }

        let player = PlayerService.shared

        let playbackFingerprint = playbackFingerprint(of: player)
        if force || playbackFingerprint != lastPlaybackFingerprint {
            lastPlaybackFingerprint = playbackFingerprint
            playbackRevision &+= 1

            let track = player.currentTrack
            let payload = PlaybackStatePayload.create(
                isPlaying: player.isPlaying,
                positionSeconds: player.currentTime,
                durationSeconds: player.duration,
                trackId: track?.id,
                title: track?.title,
                artist: track?.user.displayName,
                artworkURL: track?.artworkURL?.absoluteString,
                isDJEngineLive: player.isMixEngineLive,
                revision: playbackRevision,
                sessionId: sessionId,
                secret: secret
            )
            send(.playbackState(sessionId: sessionId, playback: payload))
        }

        let engine = MixEngine.shared
        let dj = DJTransitionService.shared
        let deckA = deckPayload(.a, player: player, engine: engine)
        let deckB = deckPayload(.b, player: player, engine: engine)
        let automaticMix = player.automaticMixDecision

        let djFingerprint = djFingerprint(
            isEnabled: dj.isEnabled,
            isEngineLive: player.isMixEngineLive,
            isAutoMixEnabled: player.isAutoMixEnabled,
            crossfade: engine.crossfade,
            deckA: deckA,
            deckB: deckB,
            automaticMix: automaticMix
        )
        if force || djFingerprint != lastDJFingerprint {
            lastDJFingerprint = djFingerprint
            djRevision &+= 1

            let payload = DJStatePayload.create(
                isEnabled: dj.isEnabled,
                isEngineLive: player.isMixEngineLive,
                isAutoMixEnabled: player.isAutoMixEnabled,
                crossfade: engine.crossfade,
                deckA: deckA,
                deckB: deckB,
                automaticMix: automaticMix,
                revision: djRevision,
                sessionId: sessionId,
                secret: secret
            )
            send(.djState(sessionId: sessionId, dj: payload))
        }
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
        return engine.deckStatePayload(
            deck,
            title: track?.title,
            artist: track?.user.displayName,
            bpm: gridBPM ?? analysedBPM,
            role: role,
            phaseErrorSeconds: phase
        )
    }

    private func playbackFingerprint(of player: PlayerService) -> Int {
        var hasher = Hasher()
        hasher.combine(player.currentTrack?.id)
        hasher.combine(player.isPlaying)
        hasher.combine(player.currentTime)
        hasher.combine(player.duration)
        hasher.combine(player.isMixEngineLive)
        return hasher.finalize()
    }

    private func djFingerprint(
        isEnabled: Bool,
        isEngineLive: Bool,
        isAutoMixEnabled: Bool,
        crossfade: Double,
        deckA: DJDeckStatePayload,
        deckB: DJDeckStatePayload,
        automaticMix: DJAutomaticMixDecision
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(isEnabled)
        hasher.combine(isEngineLive)
        hasher.combine(isAutoMixEnabled)
        hasher.combine(crossfade)
        Self.combine(deckA, into: &hasher)
        Self.combine(deckB, into: &hasher)
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
        return hasher.finalize()
    }

    private static func combine(_ deck: DJDeckStatePayload, into hasher: inout Hasher) {
        hasher.combine(deck.trackId)
        hasher.combine(deck.title)
        hasher.combine(deck.artist)
        hasher.combine(deck.positionSeconds)
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
        hasher.combine(deck.level)
        hasher.combine(deck.peak)
        hasher.combine(deck.isClipping)
        hasher.combine(deck.phaseErrorSeconds)
    }

    private func send(_ message: TokenTransferMessage) {
        guard let data = try? message.framed() else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendError(_ text: String) {
        guard let sessionId else { return }
        send(.error(sessionId: sessionId, message: text))
    }

    #if os(tvOS)
    private enum Keys {
        static let sessionId = "remote_pair_session_id"
        static let secret = "remote_pair_secret"
    }

    private func store(sessionId: String, secret: Data) {
        do {
            try KeychainService.shared.save(sessionId, forKey: Keys.sessionId)
            try KeychainService.shared.save(secret.base64EncodedString(), forKey: Keys.secret)
        } catch {
            Log.auth.error("[CompanionServer] store keychain save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadStoredPairing() -> (sessionId: String, secret: Data)? {
        guard let sessionId = KeychainService.shared.get(forKey: Keys.sessionId),
              let encoded = KeychainService.shared.get(forKey: Keys.secret),
              let secret = Data(base64Encoded: encoded),
              !sessionId.isEmpty,
              !secret.isEmpty else {
            return nil
        }
        return (sessionId, secret)
    }
    #endif
}

extension CompanionServer: PeerContentSessionProvider {
    var peerContentEndpoint: (endpoint: NWEndpoint, sessionId: String, secret: Data)? {
        guard let endpoint = remoteContentEndpoints.values.first,
              let sessionId, let secret else { return nil }
        return (endpoint, sessionId, secret)
    }

    func peerContentEndpoint(forDeviceId deviceId: String) -> (endpoint: NWEndpoint, sessionId: String, secret: Data)? {
        let token = PeerContentServer.serviceToken(for: deviceId)
        guard let endpoint = remoteContentEndpoints[token], let sessionId, let secret else { return nil }
        return (endpoint, sessionId, secret)
    }
}
