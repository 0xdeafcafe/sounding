import Foundation
import Network
import Combine
import Security
import UIKit
import CryptoKit
import os

@MainActor
final class LinkServer: ObservableObject {

    enum Fault: Equatable {
        case cannotListen(String)
        case localNetworkDenied
        case cannotGenerateSession
        case connectionLost(String)
        case rejected(String)
        case validationUnavailable(String)

        var codeIsStillLive: Bool {
            switch self {
            case .cannotListen, .localNetworkDenied, .cannotGenerateSession: return false
            case .connectionLost, .rejected, .validationUnavailable:         return true
            }
        }

        var detail: String? {
            switch self {
            case .cannotListen(let d), .connectionLost(let d), .rejected(let d),
                 .validationUnavailable(let d):
                return d.isEmpty ? nil : d
            case .localNetworkDenied, .cannotGenerateSession:
                return nil
            }
        }
    }

    enum State: Equatable {
        case idle
        case advertising
        case connected
        case receivingToken
        case completed
        case failed(Fault)
        case timeout

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.advertising, .advertising),
                 (.connected, .connected),
                 (.receivingToken, .receivingToken),
                 (.completed, .completed),
                 (.timeout, .timeout):
                return true
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .timeout: return true
            default:                            return false
            }
        }
    }

    @Published private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            if state.isTerminal {
                finishLinkProgress()
                if state != .completed { validationTask?.cancel() }
                validationTask = nil
            }
            if case .failed = state { events.send(.failed) }
            if state == .completed { events.send(.signedIn) }
        }
    }

    let events = PassthroughSubject<SignInEvent, Never>()
    private var hasIssuedCode = false
    @Published private(set) var credentials: SessionCredentials?

    @Published private(set) var numericComparisonCode: String?
    @Published private(set) var isLinkInProgress = false
    @Published private(set) var connectingDeviceName: String?
    @Published private(set) var peerDevice = PeerDevice.unknown

    private var awaitingHandoff = false
    private nonisolated(unsafe) var linkProgressTimeout: Task<Void, Never>?

    @Published private(set) var linkApproval: LinkApproval?

    @Published private(set) var chimeCode: ChimeCode?

    struct LinkApproval: Equatable, Identifiable {
        enum Account: Equatable {
            case none
            case same
            case different
        }

        let id = UUID()
        let deviceName: String
        let code: String
        var account: Account = .none
    }

    static let chimeRedeemGrace: TimeInterval = 45

    private nonisolated(unsafe) var listener: NWListener?
    private nonisolated(unsafe) var connection: NWConnection?
    private nonisolated(unsafe) var timeoutTask: Task<Void, Never>?
    private nonisolated(unsafe) var validationTask: Task<Void, Never>?

    private var framer = MessageFramer()

    private nonisolated(unsafe) var offerListener: NWListener?
    private nonisolated(unsafe) var offerConnection: NWConnection?
    private var offerFramer = MessageFramer()
    private var offerEphemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private var offerCommitNonce: Data?
    private var offerSharedSecret: SharedSecret?
    private var offerPhonePublicKey: Data?
    private var numericPeerName = ""
    private var numericApprovedOnTV = false
    private var numericConfirmedByPeer = false
    private var numericOwnerKey: LinkOwnerKey?
    private var ownerProvenLink = false
    private var numericOwnerTranscript: LinkOwnerProof.Transcript?
    private var numericPendingApproval: LinkApproval?
    private nonisolated(unsafe) var offerConnectionIdleTimeout: Task<Void, Never>?
    private nonisolated(unsafe) var chimeRotation: Task<Void, Never>?
    private nonisolated(unsafe) var chimeResume: Task<Void, Never>?
    private var chimeLedger = ChimeCodeLedger()
    private var chimePending: ChimeCodeLedger.Pending?
    private var lastRequestedChime: ContinuousClock.Instant?
    private static let requestedChimeSpacing: Duration = .seconds(10)

    private static var localTVName: String {
        String(UIDevice.current.name.prefix(ChimeLinkCrypto.maximumNameLength))
    }

    private let refreshCoordinator = TokenRefreshCoordinator()

    private static let maxListenerRecoveryAttempts = 3

    private var listenerRecoveryAttempts = 0

    private var isRecoveringListener = false

    private static func isRecoverableListenerFailure(_ error: NWError) -> Bool {
        guard case .dns(let code) = error else { return false }
        return code == -65569 || code == -65563
    }

    private static func isLocalNetworkPolicyFailure(_ error: NWError) -> Bool {
        switch error {
        case .dns(let code):
            return code == -65570 // kDNSServiceErr_PolicyDenied
        case .posix(let code):
            return code == .EPERM || code == .EACCES
        default:
            return false
        }
    }

    var onTokenReceived: ((String, String?, String?, Date?) -> Void)?

    var onLinked: (() -> Void)?

    var keepsOwnSession: Bool { CompanionServer.shared.localAccount != nil }

    var rendezvous: String?

    var accountHint: LinkAccountHint.Advert?

    var ownerAccountId: String?

    @Published private(set) var linkedPeerName: String?

    var playsChime = true

    var sessionLifetime: TimeInterval = BonjourConstants.sessionTimeout

    var onChimeRequested: (() -> Void)?

    func requestChime() {
        guard chimeCode != nil else { return }
        onChimeRequested?()
    }

    deinit {
        cancelNetworkResources()
    }

    private nonisolated func cancelNetworkResources() {
        linkProgressTimeout?.cancel()
        timeoutTask?.cancel()
        validationTask?.cancel()
        connection?.cancel()
        listener?.cancel()
        offerConnection?.cancel()
        offerListener?.cancel()
        offerConnectionIdleTimeout?.cancel()
        chimeRotation?.cancel()
        chimeResume?.cancel()
    }

    func start() {
        stop()

        if hasIssuedCode { events.send(.codeRotated) }
        hasIssuedCode = true

        listenerRecoveryAttempts = 0

        state = .idle

        guard let newCredentials = SessionCredentials.generate() else {
            state = .failed(.cannotGenerateSession)
            return
        }
        self.credentials = newCredentials

        refreshCoordinator.reset()

        do {
            let parameters = LinkTLS.makeParameters(
                sessionId: newCredentials.sessionId,
                secret: newCredentials.secret
            )

            listener = try NWListener(using: parameters)

            listener?.service = NWListener.Service(
                name: BonjourConstants.linkServiceName(sessionId: newCredentials.sessionId),
                type: BuildFlavor.current.bonjourServiceType
            )

            listener?.stateUpdateHandler = { [weak self] listenerState in
                Task { @MainActor in
                    self?.handleListenerState(listenerState)
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }

            listener?.start(queue: .main)
            state = .advertising

            startTimeoutTimer()

            applyDebugStateOverride()

        } catch {
            state = .failed(.cannotListen(error.localizedDescription))
        }

        startPushOfferListener()
        if playsChime { rotateChimeCode() }
    }

    static var debugStateOverride: State? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_PAIRING_STATE"] {
        case "advertising": return .advertising
        case "connected":   return .connected
        case "receiving":   return .receivingToken
        case "completed":   return .completed
        case "timeout":     return .timeout
        case "nolisten":    return .failed(.cannotListen("nw_listener_start_failed [48: Address already in use]"))
        case "lost":        return .failed(.connectionLost("Software caused connection abort"))
        case "rejected":    return .failed(.rejected("Invalid signature"))
        case "nosession":   return .failed(.cannotGenerateSession)
        default:            return nil
        }
        #else
        return nil
        #endif
    }

    private func applyDebugStateOverride() {
        guard let override = Self.debugStateOverride else { return }
        state = override
    }

    func stop() {
        finishLinkProgress()
        ownerProvenLink = false
        connectingDeviceName = nil
        peerDevice = .unknown
        linkedPeerName = nil
        timeoutTask?.cancel()
        timeoutTask = nil

        validationTask?.cancel()
        validationTask = nil

        connection?.cancel()
        connection = nil

        listener?.cancel()
        listener = nil

        stopPushOfferListener()
        stopChime()

        if !state.isTerminal {
            state = .idle
        }
        credentials = nil
    }

    private func handleListenerState(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            Log.link.info("[LinkServer] Listener ready, advertising service")
            listenerRecoveryAttempts = 0
        case .failed(let error):
            if Self.isLocalNetworkPolicyFailure(error) {
                state = .failed(.localNetworkDenied)
                stop()
                return
            }
            if Self.isRecoverableListenerFailure(error),
               listenerRecoveryAttempts < Self.maxListenerRecoveryAttempts {
                recoverDefunctListener(error)
                return
            }
            state = .failed(.cannotListen(error.localizedDescription))
            stop()
        case .waiting(let error):
            if Self.isLocalNetworkPolicyFailure(error) {
                state = .failed(.localNetworkDenied)
                stop()
            } else {
                Log.link.error("[LinkServer] listener waiting: \(String(describing: error), privacy: .public)")
            }
        case .cancelled:
            Log.link.debug("[LinkServer] Listener cancelled")
        default:
            break
        }
    }

    private func recoverDefunctListener(_ error: NWError) {
        guard !isRecoveringListener else { return }
        isRecoveringListener = true
        listenerRecoveryAttempts += 1
        let attempt = listenerRecoveryAttempts
        Log.link.error("[LinkServer] listener went defunct (\(String(describing: error), privacy: .public)); re-arming with a fresh session, attempt \(attempt, privacy: .public)/\(Self.maxListenerRecoveryAttempts, privacy: .public)")

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            guard let self else { return }
            self.isRecoveringListener = false
            self.start()
            self.listenerRecoveryAttempts = attempt
        }
    }

    private func handleNewConnection(_ newConnection: NWConnection) {
        Log.link.debug("[LinkServer] new connection arrived; current connection nil=\(self.connection == nil, privacy: .public)")
        guard connection == nil else {
            newConnection.cancel()
            return
        }

        connection = newConnection
        beginLinkProgress()
        framer = MessageFramer()
        events.send(.scanned)
        state = .connected

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] connectionState in
            Task { @MainActor in
                guard let self, let newConnection, self.connection === newConnection else { return }
                self.handleConnectionState(connectionState)
            }
        }

        newConnection.start(queue: .main)
        receiveData()
    }

    private func handleConnectionState(_ connectionState: NWConnection.State) {
        switch connectionState {
        case .ready:
            Log.link.info("[LinkServer] Connection ready (TLS-PSK verified)")
            state = .receivingToken
        case .failed(let error):
            state = .failed(.connectionLost(error.localizedDescription))
            connection = nil
        case .cancelled:
            Log.link.debug("[LinkServer] Connection cancelled")
            connection = nil
            if !state.isTerminal { state = .failed(.connectionLost("")) }
        default:
            break
        }
    }

    private func receiveData() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                Log.link.debug("[LinkServer] receive: bytes=\(data?.count ?? 0, privacy: .public) complete=\(isComplete, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)")

                if let error = error {
                    self.state = .failed(.connectionLost(error.localizedDescription))
                    return
                }

                if let data = data, !data.isEmpty {
                    self.processReceivedData(data)
                }

                if isComplete {
                    self.connection?.cancel()
                    self.connection = nil
                    if !self.state.isTerminal, self.validationTask == nil {
                        self.state = .failed(.connectionLost(""))
                    }
                } else {
                    self.receiveData()
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
        guard let credentials = credentials else {
            sendError("No active session")
            return
        }

        guard !credentials.isExpired else {
            sendError("Session expired")
            state = .timeout
            return
        }

        guard message.sessionId == credentials.sessionId else {
            sendError("Session ID mismatch")
            return
        }

        switch message.type {
        case .linkEstablish:
            handleLinkEstablish(message, session: credentials)

        case .tokenTransfer:
            guard let payload = message.payload else {
                sendError("Missing token payload")
                return
            }

            guard payload.verify(sessionId: credentials.sessionId, secret: credentials.secret) else {
                sendError("Invalid signature")
                return
            }

            state = .receivingToken
            let identity = message.peer
            if let identity, identity.verify(sessionId: credentials.sessionId, secret: credentials.secret) {
                connectingDeviceName = Self.displayName(identity.name, deviceClass: identity.deviceClass)
                peerDevice = PeerDevice(rawClass: identity.deviceClass, name: identity.name)
            }
            validationTask = Task { [weak self] in
                let validation = await Self.validate(payload.oauthToken)
                guard !Task.isCancelled, let self else { return }

                if validation == .valid {
                    self.accept(payload, renewed: nil, session: credentials, identity: identity)
                    return
                }

                if case .unavailable(let detail) = validation {
                    self.sendValidationUnavailable(detail)
                    return
                }

                guard payload.refreshToken?.isEmpty == false,
                      payload.clientId?.isEmpty == false else {
                    self.sendTokenRejected(TVPairingCopy.signInAgain(on: self.peerDevice))
                    return
                }

                let outcome = await self.refreshCoordinator.refresh(
                    refreshToken: payload.refreshToken,
                    clientId: payload.clientId
                )
                guard !Task.isCancelled else { return }

                switch outcome {
                case .succeeded(let renewed):
                    self.accept(payload, renewed: renewed, session: credentials, identity: identity)

                case .transient:
                    self.sendError("Couldn't reach SoundCloud to renew your login. Check the network and try again.")

                case .unrecoverable:
                    self.sendTokenRejected(TVPairingCopy.signInAgain(on: self.peerDevice))
                }
            }

        default:
            break
        }
    }

    private static func validate(_ token: String) async -> SoundCloudTokenValidation {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_LINK_FIXTURE_TOKEN"] == "1", token == BonjourConstants.fixtureLinkToken {
            return .valid
        }
        #endif
        return await SoundCloudAPI.shared.validateToken(token)
    }

    private func accept(
        _ payload: TokenPayload,
        renewed: SoundCloudTokenRefresh.Credentials?,
        session: SessionCredentials,
        identity: LinkPeerIdentity?
    ) {
        let token = renewed?.accessToken ?? payload.oauthToken
        let refreshToken = renewed?.refreshToken ?? payload.refreshToken
        let expiresAt = renewed == nil ? payload.expiresAt : renewed?.expiresAt

        var echo: TokenPayload?
        if renewed != nil {
            echo = TokenPayload.create(
                token: token,
                refreshToken: refreshToken,
                clientId: payload.clientId,
                expiresAt: expiresAt,
                sessionId: session.sessionId,
                secret: session.secret
            )
        }

        sendAcknowledgment(payload: echo)
        state = .completed
        timeoutTask?.cancel()

        stopChime()

        CompanionServer.shared.pair(with: session, identity: identity)

        if keepsOwnSession {
            Log.link.info("[LinkServer] linked a device while signed in; keeping this Apple TV's own session")
            onLinked?()
            return
        }
        SessionProvenance.record(ownerProvenLink ? .linkedPeer : .guest)
        onTokenReceived?(token, refreshToken, payload.clientId, expiresAt)
    }

    private func handleLinkEstablish(_ message: TokenTransferMessage, session: SessionCredentials) {
        guard let establish = message.linkEstablish,
              establish.verify(sessionId: session.sessionId, secret: session.secret),
              establish.isFresh() else {
            sendError("Invalid signature")
            return
        }
        let identity = message.peer.flatMap { $0.verify(sessionId: session.sessionId, secret: session.secret) ? $0 : nil }
        if let identity {
            connectingDeviceName = Self.displayName(identity.name, deviceClass: identity.deviceClass)
            peerDevice = PeerDevice(rawClass: identity.deviceClass, name: identity.name)
        }
        let account = CompanionServer.shared.localAccount
        let reply = LinkEstablishedPayload.create(
            needsCredentials: account == nil,
            account: account?.encoded(),
            sessionId: session.sessionId,
            secret: session.secret
        )
        if let data = try? TokenTransferMessage.linkEstablished(sessionId: session.sessionId, payload: reply).framed() {
            connection?.send(content: data, completion: .contentProcessed { _ in })
        }
        guard account != nil else {
            Log.link.info("[LinkServer] a device asked to link; this Apple TV needs its sign-in")
            state = .receivingToken
            return
        }
        state = .completed
        timeoutTask?.cancel()
        stopChime()
        CompanionServer.shared.pair(with: session, identity: identity)
        Log.link.info("[LinkServer] linked a device without a token")
        onLinked?()
    }

    private func sendAcknowledgment(payload: TokenPayload? = nil) {
        guard let credentials = credentials else { return }

        let ack = TokenTransferMessage.acknowledgment(
            sessionId: credentials.sessionId,
            payload: payload
        )
        if let data = try? ack.framed() {
            connection?.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func sendTokenRejected(_ message: String) {
        guard let credentials else { return }
        let rejection = TokenTransferMessage.tokenRejected(
            sessionId: credentials.sessionId, message: message
        )
        if let data = try? rejection.framed() {
            connection?.send(content: data, completion: .contentProcessed { _ in })
        }
        state = .failed(.rejected(message))
    }

    private func sendValidationUnavailable(_ detail: String) {
        guard let credentials else { return }
        let message = "This Apple TV couldn't reach SoundCloud to verify the sign-in. Check its internet connection and try again."
        let response = TokenTransferMessage.error(sessionId: credentials.sessionId, message: message)
        if let data = try? response.framed() {
            connection?.send(content: data, completion: .contentProcessed { _ in })
        }
        state = .failed(.validationUnavailable(detail))
    }

    private func sendError(_ message: String) {
        guard let credentials = credentials else { return }

        let error = TokenTransferMessage.error(sessionId: credentials.sessionId, message: message)
        if let data = try? error.framed() {
            connection?.send(content: data, completion: .contentProcessed { _ in })
        }
        state = .failed(.rejected(message))
    }

    private func startTimeoutTimer() {
        timeoutTask?.cancel()
        let lifetime = sessionLifetime
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(lifetime))

            guard !Task.isCancelled else { return }

            switch state {
            case .advertising:
                stop()
                state = .timeout
            case .failed(let fault) where fault.codeIsStillLive:
                stop()
                state = .timeout
            default:
                break
            }
        }
    }

    private func startPushOfferListener() {
        guard let credentials else { return }

        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()

        var nonceBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else {
            Log.link.error("[LinkServer] push-offer listener failed to start: couldn't generate a commit nonce")
            return
        }
        let commitNonce = Data(nonceBytes)

        offerEphemeralKey = ephemeralKey
        offerCommitNonce = commitNonce
        offerSharedSecret = nil
        offerPhonePublicKey = nil
        offerFramer = MessageFramer()

        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let newListener = try NWListener(using: parameters)
            newListener.service = NWListener.Service(
                name: BonjourConstants.linkOfferServiceName(sessionId: credentials.sessionId),
                type: BuildFlavor.current.bonjourServiceType,
                txtRecord: NWTXTRecord(LinkOfferTXT.dictionary(
                    name: UIDevice.current.name,
                    kind: .current,
                    commitment: LinkConfirmationCrypto.commitment(
                        nonce: commitNonce,
                        publicKey: ephemeralKey.publicKey.rawRepresentation
                    ),
                    rendezvous: rendezvous,
                    accountHint: accountHint
                ))
            )
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.handleOfferConnection(connection) }
            }
            newListener.stateUpdateHandler = { [signedIn = accountHint != nil] state in
                switch state {
                case .ready:
                    Log.link.info("[LinkServer] offer advertised (signedIn=\(signedIn, privacy: .public))")
                case .failed(let error), .waiting(let error):
                    Log.link.error("[LinkServer] offer listener: \(String(describing: error), privacy: .public)")
                default:
                    break
                }
            }
            newListener.start(queue: .main)
            offerListener = newListener
        } catch {
            Log.link.error("[LinkServer] push-offer listener failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopPushOfferListener() {
        clearOfferConnection()
        offerListener?.cancel()
        offerListener = nil
        offerEphemeralKey = nil
        offerCommitNonce = nil
        offerFramer = MessageFramer()
    }

    private func clearNumericExchange() {
        offerSharedSecret = nil
        offerPhonePublicKey = nil
        numericPeerName = ""
        numericApprovedOnTV = false
        numericConfirmedByPeer = false
        numericOwnerKey = nil
        numericOwnerTranscript = nil
        numericPendingApproval = nil
        numericComparisonCode = nil
        linkApproval = nil
    }

    private func clearOfferConnection() {
        if isLinkInProgress && !awaitingHandoff && connection == nil && !state.isTerminal {
            state = .failed(.connectionLost(""))
        }
        if offerConnection != nil { events.send(.offerClosed) }
        chimePending = nil
        clearNumericExchange()
        offerConnection?.cancel()
        offerConnection = nil
        offerConnectionIdleTimeout?.cancel()
        offerConnectionIdleTimeout = nil
    }

    private func armOfferConnectionIdleTimeout(seconds: Double = 20) {
        offerConnectionIdleTimeout?.cancel()
        offerConnectionIdleTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.clearOfferConnection()
        }
    }

    private func handleOfferConnection(_ newConnection: NWConnection) {
        guard offerConnection == nil else {
            Log.link.error("[LinkServer] offer connection refused: another exchange is in progress")
            newConnection.cancel()
            return
        }

        Log.link.info("[LinkServer] offer connection from \(String(describing: newConnection.endpoint), privacy: .public)")
        offerConnection = newConnection
        beginLinkProgress(timeout: 20)
        offerFramer = MessageFramer()
        events.send(.offerReceived)

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] connectionState in
            Task { @MainActor in
                guard let self, let newConnection, self.offerConnection === newConnection else { return }
                switch connectionState {
                case .failed, .cancelled:
                    self.clearOfferConnection()
                default:
                    break
                }
            }
        }
        newConnection.start(queue: .main)
        receiveOfferData()
        armOfferConnectionIdleTimeout()
    }

    private func receiveOfferData() {
        guard let offerConnection else { return }
        offerConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.offerConnection === offerConnection else { return }
                if error != nil {
                    self.clearOfferConnection()
                    return
                }
                if let data, !data.isEmpty {
                    self.offerFramer.append(data)
                    while let message = try? self.offerFramer.next() {
                        self.handleOfferMessage(message)
                    }
                }
                if isComplete {
                    self.clearOfferConnection()
                } else {
                    self.receiveOfferData()
                }
            }
        }
    }

    private func handleOfferMessage(_ message: TokenTransferMessage) {
        guard let credentials else { return }
        let sessionIdSalt = String(credentials.sessionId.prefix(8))

        switch message.type {
        case .numericComparisonHello:
            handleNumericHello(message, sessionIdSalt: sessionIdSalt)

        case .numericComparisonConfirm:
            guard offerSharedSecret != nil else {
                sendOfferError()
                return
            }
            if let ownerKey = numericOwnerKey, let transcript = numericOwnerTranscript,
               !numericApprovedOnTV, linkApproval == nil {
                if LinkOwnerProof.verify(message.numericConfirm?.ownerProof, role: .initiator, key: ownerKey.material, transcript: transcript) {
                    numericApprovedOnTV = true
                    ownerProvenLink = true
                    Log.link.info("[LinkServer] same owner verified; linking without asking")
                } else {
                    Log.link.info("[LinkServer] no same-owner proof; asking on this Apple TV")
                    linkApproval = numericPendingApproval
                    numericComparisonCode = numericPendingApproval?.code
                }
            }
            guard linkApproval != nil || numericApprovedOnTV else {
                sendOfferError()
                return
            }
            numericConfirmedByPeer = true
            armOfferConnectionIdleTimeout(seconds: BonjourConstants.linkApprovalTimeout)
            releaseNumericCredentialsIfApproved()

        case .numericComparisonDeclined:
            clearOfferConnection()

        case .chimeHello:
            handleChimeHello(message, credentials: credentials, sessionIdSalt: sessionIdSalt)

        case .chimeConfirm:
            handleChimeConfirm(message, credentials: credentials, sessionIdSalt: sessionIdSalt)

        case .chimePlayRequest:
            handleChimePlayRequest(sessionIdSalt: sessionIdSalt)

        default:
            break
        }
    }

    // MARK: - Numeric comparison

    private func handleNumericHello(_ message: TokenTransferMessage, sessionIdSalt: String) {
        guard offerSharedSecret == nil,
              chimeLedger.admitHello(at: .now),
              let hello = message.numericHello,
              let phonePublicKeyRaw = Data(base64Encoded: hello.ephemeralPublicKeyBase64),
              let ephemeralKey = offerEphemeralKey,
              let commitNonce = offerCommitNonce,
              let phonePublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phonePublicKeyRaw),
              let shared = try? ephemeralKey.sharedSecretFromKeyAgreement(with: phonePublicKey) else {
            Log.link.error("[LinkServer] numeric_hello refused")
            sendOfferError()
            return
        }
        let peerName = hello.deviceName ?? ""
        guard peerName.count <= LinkPeerIdentity.maximumNameLength else {
            sendOfferError()
            return
        }
        let code = LinkConfirmationCrypto.code(
            sharedSecret: shared,
            publicKeyA: ephemeralKey.publicKey.rawRepresentation,
            publicKeyB: phonePublicKeyRaw,
            sessionId: sessionIdSalt,
            peerName: peerName
        )
        offerSharedSecret = shared
        offerPhonePublicKey = phonePublicKeyRaw
        numericPeerName = peerName
        numericApprovedOnTV = false
        numericConfirmedByPeer = false
        let approvalAccount: LinkApproval.Account
        if let ownerAccountId, !ownerAccountId.isEmpty {
            approvalAccount = LinkEstablishPolicy.isSameAccountApproval(digest: hello.accountDigest, salt: accountHint?.salt, accountId: ownerAccountId) ? .same : .different
        } else {
            approvalAccount = .none
        }
        let approval = LinkApproval(deviceName: Self.displayName(peerName, deviceClass: hello.deviceClass), code: code, account: approvalAccount)
        beginLinkProgress(name: approval.deviceName, timeout: BonjourConstants.linkApprovalTimeout)
        peerDevice = PeerDevice(rawClass: hello.deviceClass, name: peerName)
        numericPendingApproval = approval
        let tvPublicKey = ephemeralKey.publicKey.rawRepresentation.base64EncodedString()
        let owner = ownerProof(
            hello,
            transcript: LinkOwnerProof.Transcript(
                sessionId: sessionIdSalt,
                initiatorKey: phonePublicKeyRaw.base64EncodedString(),
                responderKey: tvPublicKey,
                commitNonce: commitNonce.base64EncodedString(),
                initiatorName: peerName,
                initiatorClass: hello.deviceClass ?? "",
                accountId: ownerAccountId ?? ""
            )
        )
        linkApproval = owner == nil ? approval : nil
        numericComparisonCode = owner == nil ? code : nil
        sendOfferMessage(.numericComparisonHelloAck(
            sessionId: sessionIdSalt,
            payload: LinkConfirmationHelloAckPayload(
                ephemeralPublicKeyBase64: tvPublicKey,
                commitNonceBase64: commitNonce.base64EncodedString(),
                ownerKeyTag: owner?.tag,
                ownerProof: owner?.proof
            )
        ))
        events.send(.exchangeStarted)
        armOfferConnectionIdleTimeout(seconds: BonjourConstants.linkApprovalTimeout)
    }

    private func ownerProof(
        _ hello: LinkConfirmationHelloPayload,
        transcript: LinkOwnerProof.Transcript
    ) -> (tag: String, proof: String)? {
        guard let tags = hello.ownerKeyTags, !tags.isEmpty, !transcript.accountId.isEmpty,
              let match = LinkOwnerKeyStore.load().key(
                  matching: tags,
                  sessionId: transcript.sessionId,
                  initiatorKey: transcript.initiatorKey,
                  at: Date()
              ),
              let proof = LinkOwnerProof.sign(.responder, key: match.key.material, transcript: transcript) else { return nil }
        numericOwnerKey = match.key
        numericOwnerTranscript = transcript
        Log.link.info("[LinkServer] the device asking shares this Apple ID's link key; waiting for its proof")
        return (match.tag, proof)
    }

    private static func displayName(_ name: String, deviceClass: String?) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if !trimmed.isEmpty { return trimmed }
        return deviceClass.flatMap(DeviceClass.init(rawValue:))?.displayName ?? "A nearby device"
    }

    func approveLink() {
        guard linkApproval != nil, offerSharedSecret != nil else { return }
        linkApproval = nil
        numericApprovedOnTV = true
        numericComparisonCode = nil
        releaseNumericCredentialsIfApproved()
    }

    func declineLink() {
        guard linkApproval != nil || numericApprovedOnTV else { return }
        if let credentials {
            sendOfferMessage(
                .numericComparisonDeclined(sessionId: String(credentials.sessionId.prefix(8))),
                closeAfterSending: true
            )
        }
        clearNumericExchange()
        state = .failed(.rejected(""))
        events.send(.failed)
    }

    private func releaseNumericCredentialsIfApproved() {
        guard numericApprovedOnTV, numericConfirmedByPeer else { return }
        guard let credentials, !credentials.isExpired,
              let shared = offerSharedSecret,
              let ephemeralKey = offerEphemeralKey,
              let phonePublicKey = offerPhonePublicKey else {
            sendOfferError()
            clearNumericExchange()
            return
        }
        let sessionIdSalt = String(credentials.sessionId.prefix(8))
        let transportKey = LinkConfirmationCrypto.transportKey(
            sharedSecret: shared,
            publicKeyA: ephemeralKey.publicKey.rawRepresentation,
            publicKeyB: phonePublicKey,
            sessionId: sessionIdSalt,
            peerName: numericPeerName
        )
        let approvedName = numericPendingApproval?.deviceName
        beginLinkProgress(name: approvedName)
        awaitingHandoff = true
        clearNumericExchange()
        linkedPeerName = approvedName
        let offer = LinkOffer(
            sessionId: credentials.sessionId,
            secretBase64: credentials.secret.base64EncodedString(),
            createdAt: credentials.createdAt,
            tvName: UIDevice.current.name
        )
        guard let encoded = try? JSONEncoder().encode(offer),
              let sealed = try? LinkConfirmationCrypto.seal(encoded, key: transportKey) else {
            sendOfferError()
            return
        }
        sendOfferMessage(.numericComparisonCredentials(
            sessionId: sessionIdSalt,
            payload: LinkConfirmationCredentialsPayload(sealedBase64: sealed.base64EncodedString())
        ), closeAfterSending: true)
        events.send(.confirmed)
    }

    // MARK: - Chime

    private func rotateChimeCode() {
        chimeResume?.cancel()
        chimeResume = nil
        chimeRotation?.cancel()
        chimeRotation = nil
        chimePending = nil
        guard credentials != nil, let code = ChimeCode.random() else {
            stopChime()
            return
        }
        chimeLedger.rotate(to: code, at: .now)
        chimeCode = code
        chimeRotation = Task { [weak self] in
            try? await Task.sleep(for: ChimeCodeLedger.lifetime)
            guard !Task.isCancelled, let self, self.chimeCode != nil else { return }
            self.events.send(.codeRotated)
            self.rotateChimeCode()
        }
    }

    private func stopChime() {
        chimeRotation?.cancel()
        chimeRotation = nil
        chimeResume?.cancel()
        chimeResume = nil
        chimeLedger.retire()
        chimePending = nil
        chimeCode = nil
    }

    private func redeemChimeCode() {
        stopChime()
        chimeResume = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.chimeRedeemGrace))
            guard !Task.isCancelled, let self, self.credentials != nil, !self.state.isTerminal else { return }
            self.rotateChimeCode()
        }
    }

    private func handleChimeHello(_ message: TokenTransferMessage, credentials: SessionCredentials, sessionIdSalt: String) {
        let now = ContinuousClock.now
        chimePending = nil
        guard chimeLedger.admitHello(at: now),
              let live = chimeLedger.live(at: now),
              let payload = message.chime,
              payload.version == ChimeLinkCrypto.protocolVersion,
              let phoneNonce = payload.nonceBase64.flatMap({ Data(base64Encoded: $0) }),
              let tvNonce = ChimeLinkCrypto.makeNonce() else {
            Log.link.error("[LinkServer] chime_hello refused (budget, no live code, or bad version)")
            sendOfferError()
            return
        }
        Log.link.info("[LinkServer] chime_hello accepted")
        let transcript = ChimeLinkCrypto.Transcript(
            version: ChimeLinkCrypto.protocolVersion,
            sessionId: credentials.sessionId,
            tvDeviceId: LinkPeerIdentity.localDeviceId(defaults: .sounding),
            tvName: Self.localTVName,
            tvKind: DeviceClass.current.rawValue,
            phoneNonce: phoneNonce,
            tvNonce: tvNonce
        )
        guard let session = ChimeLinkCrypto.session(code: live.code, transcript: transcript),
              let pending = chimeLedger.pending(session, at: now) else {
            sendOfferError()
            return
        }
        chimePending = pending
        beginLinkProgress(timeout: 60)
        sendOfferMessage(.chime(.chimeHelloAck, sessionId: sessionIdSalt, payload: ChimeLinkPayload(
            version: transcript.version,
            nonceBase64: tvNonce.base64EncodedString(),
            sessionId: transcript.sessionId,
            tvName: transcript.tvName,
            tvKind: transcript.tvKind,
            tvDeviceId: transcript.tvDeviceId,
            confirmationBase64: ChimeLinkCrypto.confirmation(session, role: .tv).base64EncodedString()
        )))
        events.send(.exchangeStarted)
        armOfferConnectionIdleTimeout(seconds: 60)
    }

    private func handleChimeConfirm(_ message: TokenTransferMessage, credentials: SessionCredentials, sessionIdSalt: String) {
        let now = ContinuousClock.now
        guard let pending = chimePending, chimeLedger.isRedeemable(pending, at: now) else {
            chimePending = nil
            sendOfferError()
            return
        }
        chimePending = nil
        guard let confirmation = message.chime?.confirmationBase64.flatMap({ Data(base64Encoded: $0) }),
              ChimeLinkCrypto.verifyConfirmation(confirmation, session: pending.session, role: .phone) else {
            Log.link.error("[LinkServer] chime_confirm failed verification")
            if chimeLedger.recordFailure() {
                events.send(.codeRotated)
                rotateChimeCode()
            }
            sendOfferError()
            return
        }
        guard !credentials.isExpired, chimeLedger.redeem(pending, at: now) else {
            sendOfferError()
            return
        }

        let offer = LinkOffer(
            sessionId: credentials.sessionId,
            secretBase64: credentials.secret.base64EncodedString(),
            createdAt: credentials.createdAt,
            tvName: pending.session.transcript.tvName
        )
        guard let encoded = try? JSONEncoder().encode(offer),
              let sealed = try? ChimeLinkCrypto.seal(encoded, session: pending.session) else {
            sendOfferError()
            return
        }
        beginLinkProgress()
        awaitingHandoff = true
        sendOfferMessage(
            .chime(.chimeCredentials, sessionId: sessionIdSalt, payload: ChimeLinkPayload(
                version: ChimeLinkCrypto.protocolVersion,
                sealedBase64: sealed.base64EncodedString()
            )),
            closeAfterSending: true
        )
        events.send(.confirmed)
        redeemChimeCode()
    }

    private func handleChimePlayRequest(sessionIdSalt: String) {
        let now = ContinuousClock.now
        guard chimeCode != nil, onChimeRequested != nil, chimeLedger.admitHello(at: now) else {
            Log.link.error("[LinkServer] chime request refused (no live code, no player, or budget)")
            sendOfferMessage(.error(sessionId: sessionIdSalt, message: "Invalid request"), closeAfterSending: true)
            return
        }
        beginLinkProgress()
        awaitingHandoff = true
        if lastRequestedChime.map({ now - $0 >= Self.requestedChimeSpacing }) ?? true {
            lastRequestedChime = now
            Log.link.info("[LinkServer] chime requested by a nearby device")
            requestChime()
        }
        sendOfferMessage(
            .chime(.chimePlaying, sessionId: sessionIdSalt, payload: ChimeLinkPayload(version: ChimeLinkCrypto.protocolVersion)),
            closeAfterSending: true
        )
    }

    private func sendOfferMessage(
        _ message: TokenTransferMessage,
        closeAfterSending: Bool = false
    ) {
        guard let data = try? message.framed(), let offerConnection else {
            if closeAfterSending { clearOfferConnection() }
            return
        }

        offerConnection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, self.offerConnection === offerConnection else { return }
                if let error {
                    Log.link.error("[LinkServer] push-offer send failed: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed(.connectionLost(error.localizedDescription))
                }
                if closeAfterSending {
                    self.clearOfferConnection()
                }
            }
        })
    }

    private func beginLinkProgress(name: String? = nil, timeout: Double = 30) {
        linkProgressTimeout?.cancel()
        if case .failed = state { state = .advertising }
        if let name { connectingDeviceName = name }
        isLinkInProgress = true
        awaitingHandoff = false
        linkProgressTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled, self.isLinkInProgress else { return }
            self.state = .failed(.connectionLost("The connection timed out."))
            self.validationTask?.cancel()
            self.validationTask = nil
            self.connection?.cancel()
            self.connection = nil
            self.clearOfferConnection()
        }
    }

    private func finishLinkProgress() {
        linkProgressTimeout?.cancel()
        linkProgressTimeout = nil
        isLinkInProgress = false
        connectingDeviceName = nil
        awaitingHandoff = false
    }

    private func sendOfferError() {
        guard let credentials else { return }
        state = .failed(.rejected(""))
        sendOfferMessage(
            .error(sessionId: String(credentials.sessionId.prefix(8)), message: "Invalid request"),
            closeAfterSending: true
        )
    }
}

@MainActor
final class SameAccountLinkAdvertiser: ObservableObject {
    static let shared = SameAccountLinkAdvertiser()

    let server = LinkServer()

    @Published private(set) var isAdvertising = false
    @Published private(set) var linkedName: String?
    @Published private(set) var linkedClass: DeviceClass?

    private var accountId: String?
    private var isActive = false
    private var holds = 0
    private var restart: Task<Void, Never>?
    private var stateSubscription: AnyCancellable?
    private var approvalSubscription: AnyCancellable?
    private var approvedName: String?
    private var devicesSubscription: AnyCancellable?
    private var advertisedLinkedIds: Set<String>?
    private var linkedPeersRefresh: Task<Void, Never>?

    nonisolated static let advertLifetime: TimeInterval = 30 * 60
    nonisolated static let linkedPeersSettle: Duration = .seconds(2)

    init() {
        server.playsChime = false
        server.sessionLifetime = Self.advertLifetime
        devicesSubscription = CompanionServer.shared.$devices
            .map { Set($0.compactMap(\.deviceId)) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshLinkedPeers() }
        stateSubscription = server.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.serverChanged(state) }
        approvalSubscription = server.$linkedPeerName
            .compactMap { $0 }
            .sink { [weak self] name in self?.approvedName = name }
    }

    static var currentAccountId: String? {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["SOUNDING_TV_LINK_ACCOUNT"], !forced.isEmpty { return forced }
        #endif
        return SoundCloudCredentialSource.shared.currentUser?.id
    }

    func update(accountId: String?, isActive: Bool) {
        self.accountId = accountId
        self.isActive = isActive
        if isActive, accountId?.isEmpty == false { LinkOwnerKeyCloud.shared.refreshIfNeeded() }
        reconcile()
    }

    func hold() {
        holds += 1
        reconcile()
    }

    func release() {
        holds = max(0, holds - 1)
        reconcile()
    }

    func refreshLinkedPeers() {
        linkedPeersRefresh?.cancel()
        linkedPeersRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.linkedPeersSettle)
            guard !Task.isCancelled, let self else { return }
            self.linkedPeersRefresh = nil
            let linked = Set(CompanionServer.shared.devices.compactMap(\.deviceId))
            guard self.isAdvertising, self.server.state == .advertising, self.server.linkApproval == nil,
                  linked != self.advertisedLinkedIds else { return }
            self.begin()
        }
    }

    private var wantsAdvert: Bool { isActive && holds == 0 && accountId?.isEmpty == false }

    private func reconcile() {
        if wantsAdvert {
            if !isAdvertising { begin() }
        } else if isAdvertising {
            Log.link.info("[SameAccountLink] stop advertising")
            restart?.cancel()
            linkedPeersRefresh?.cancel()
            linkedPeersRefresh = nil
            server.stop()
            isAdvertising = false
            advertisedLinkedIds = nil
        }
    }

    private func begin() {
        guard let accountId, let salt = LinkAccountHint.makeSalt() else { return }
        let linked = CompanionServer.shared.devices.compactMap(\.deviceId)
        server.accountHint = LinkAccountHint.advert(accountId: accountId, linkedDeviceIds: linked, salt: salt)
        server.ownerAccountId = accountId
        server.onTokenReceived = { [weak self] _, _, _, _ in
            Log.link.info("[SameAccountLink] linked; keeping this Apple TV's own session")
            self?.linkedClass = self?.server.peerDevice.deviceClass
            self?.linkedName = self?.approvedName
        }
        server.onLinked = { [weak self] in
            self?.linkedClass = self?.server.peerDevice.deviceClass
            self?.linkedName = self?.approvedName ?? self?.server.connectingDeviceName
        }
        Log.link.info("[SameAccountLink] advertising for \(linked.count, privacy: .public) linked devices")
        server.start()
        isAdvertising = true
        advertisedLinkedIds = Set(linked)
    }

    private func serverChanged(_ state: LinkServer.State) {
        guard isAdvertising, state.isTerminal else { return }
        restart?.cancel()
        let delay: Double
        switch state {
        case .completed: delay = 2
        case .timeout: delay = 1
        default: delay = 30
        }
        restart = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.isAdvertising, self.wantsAdvert else { return }
            self.begin()
        }
    }
}

@MainActor
final class SameAccountPhoneBrowser: ObservableObject {
    static let shared = SameAccountPhoneBrowser()

    struct Advertised: Equatable {
        let serviceName: String
        let entries: [String: String]?
    }

    @Published private(set) var nearbyName: String?

    private nonisolated(unsafe) var browser: NWBrowser?
    private var accountId: String?
    private var linkedDeviceIds: [String] = []
    private var adverts: [Advertised] = []
    private var restart: Task<Void, Never>?
    private var devicesSubscription: AnyCancellable?

    init() {
        devicesSubscription = CompanionServer.shared.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.linkedDeviceIds = devices.compactMap(\.deviceId)
                self?.rematch()
            }
    }

    static func nearbyName(in adverts: [Advertised], accountId: String?, linkedDeviceIds: [String]) -> String? {
        guard let accountId, !accountId.isEmpty else { return nil }
        for advert in adverts.sorted(by: { $0.serviceName < $1.serviceName }) {
            guard advert.serviceName.hasPrefix(BonjourConstants.nearbyServiceName + "-"),
                  let entries = advert.entries,
                  let hint = LinkAccountHint.decode(entries),
                  hint.matches(accountId: accountId),
                  !linkedDeviceIds.contains(where: { hint.isLinked(toDeviceId: $0) }) else { continue }
            let name = entries[LinkAccountHint.nameKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? TVPairingCopy.unnamedDevice : String(name.prefix(LinkPeerIdentity.maximumNameLength))
        }
        return nil
    }

    func update(accountId: String?) {
        guard accountId != self.accountId || (accountId != nil && browser == nil) else { return }
        self.accountId = accountId
        stopBrowsing()
        guard accountId != nil else { return }
        startBrowsing()
    }

    private func stopBrowsing() {
        restart?.cancel()
        restart = nil
        browser?.cancel()
        browser = nil
        adverts = []
        rematch()
    }

    private func startBrowsing() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let newBrowser = NWBrowser(
            for: .bonjourWithTXTRecord(type: BuildFlavor.current.bonjourServiceType, domain: BonjourConstants.serviceDomain),
            using: parameters
        )
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            let adverts = results.compactMap(Self.advertised)
            Task { @MainActor in self?.receive(adverts) }
        }
        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.browserChanged(state) }
        }
        newBrowser.start(queue: .main)
        browser = newBrowser
    }

    private nonisolated static func advertised(_ result: NWBrowser.Result) -> Advertised? {
        guard case .service(let name, _, _, _) = result.endpoint,
              name.hasPrefix(BonjourConstants.nearbyServiceName + "-") else { return nil }
        if case .bonjour(let record) = result.metadata { return Advertised(serviceName: name, entries: record.dictionary) }
        return Advertised(serviceName: name, entries: nil)
    }

    private func browserChanged(_ state: NWBrowser.State) {
        switch state {
        case .failed(let error):
            Log.link.error("[SameAccountLink] nearby browser failed: \(String(describing: error), privacy: .public)")
            browser?.cancel()
            browser = nil
            restart?.cancel()
            restart = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.accountId != nil, self.browser == nil else { return }
                self.startBrowsing()
            }
        case .waiting(let error):
            Log.link.error("[SameAccountLink] nearby browser waiting: \(String(describing: error), privacy: .public)")
        default:
            break
        }
    }

    private func receive(_ adverts: [Advertised]) {
        guard browser != nil else { return }
        if adverts != self.adverts {
            let withoutTXT = adverts.filter { $0.entries == nil }.count
            Log.link.info("[SameAccountLink] nearby adverts: \(adverts.count, privacy: .public), without TXT: \(withoutTXT, privacy: .public)")
        }
        self.adverts = adverts
        rematch()
    }

    private func rematch() {
        let name = Self.nearbyName(in: adverts, accountId: accountId, linkedDeviceIds: linkedDeviceIds)
        if name != nearbyName {
            Log.link.info("[SameAccountLink] nearby same-account device: \(name ?? "none", privacy: .public)")
            nearbyName = name
        }
    }
}

@MainActor
final class NearbyPhonePresence: ObservableObject {
    @Published private(set) var name: String?
    @Published private(set) var kind: DeviceClass?

    private nonisolated(unsafe) var browser: NWBrowser?

    deinit {
        browser?.cancel()
    }

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let newBrowser = NWBrowser(
            for: .bonjourWithTXTRecord(type: BuildFlavor.current.bonjourServiceType, domain: BonjourConstants.serviceDomain),
            using: parameters
        )
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handle(results) }
        }
        newBrowser.start(queue: .main)
        browser = newBrowser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        name = nil
        kind = nil
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        let nearby = results.compactMap { result -> (name: String, kind: DeviceClass?)? in
            guard case .service(let service, _, _, _) = result.endpoint,
                  service.hasPrefix(BonjourConstants.nearbyServiceName + "-"),
                  case .bonjour(let record) = result.metadata,
                  let name = NearbyPresenceTXT.name(record) else { return nil }
            return (name, NearbyPresenceTXT.kind(record))
        }
        let next = nearby.min { $0.name < $1.name }
        if next?.name != name {
            Log.link.info("[NearbyPhonePresence] nearby: \(next?.name ?? "none", privacy: .public)")
        }
        name = next?.name
        kind = next?.kind
    }
}
