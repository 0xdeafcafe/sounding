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

    @Published private(set) var state: State = .idle
    @Published private(set) var credentials: SessionCredentials?

    @Published private(set) var numericComparisonCode: String?

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
    private nonisolated(unsafe) var offerConnectionIdleTimeout: Task<Void, Never>?

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

    deinit {
        cancelNetworkResources()
    }

    private nonisolated func cancelNetworkResources() {
        timeoutTask?.cancel()
        validationTask?.cancel()
        connection?.cancel()
        listener?.cancel()
        offerConnection?.cancel()
        offerListener?.cancel()
        offerConnectionIdleTimeout?.cancel()
    }

    func start() {
        stop()

        listenerRecoveryAttempts = 0

        state = .idle

        guard let newCredentials = SessionCredentials.generate() else {
            state = .failed(.cannotGenerateSession)
            return
        }
        self.credentials = newCredentials

        refreshCoordinator.reset()

        LinkOfferKeychainStore.publish(LinkOffer(
            sessionId: newCredentials.sessionId,
            secretBase64: newCredentials.secret.base64EncodedString(),
            createdAt: newCredentials.createdAt,
            tvName: UIDevice.current.name
        ))

        do {
            let parameters = LinkTLS.makeParameters(
                sessionId: newCredentials.sessionId,
                secret: newCredentials.secret
            )

            listener = try NWListener(using: parameters)

            listener?.service = NWListener.Service(
                name: "\(BonjourConstants.serviceName)-\(newCredentials.sessionId.prefix(8))",
                type: BonjourConstants.serviceType
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
        timeoutTask?.cancel()
        timeoutTask = nil

        validationTask?.cancel()
        validationTask = nil

        connection?.cancel()
        connection = nil

        listener?.cancel()
        listener = nil

        stopPushOfferListener()

        if !state.isTerminal {
            state = .idle
        }
        credentials = nil

        LinkOfferKeychainStore.clear()
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
        framer = MessageFramer()
        state = .connected

        newConnection.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor in
                self?.handleConnectionState(connectionState)
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
        default:
            break
        }
    }

    private func receiveData() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }
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
            LinkOfferKeychainStore.clear()
            return
        }

        guard message.sessionId == credentials.sessionId else {
            sendError("Session ID mismatch")
            return
        }

        switch message.type {
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
            validationTask = Task { [weak self] in
                let validation = await SoundCloudAPI.shared.validateToken(payload.oauthToken)
                guard !Task.isCancelled, let self else { return }

                if validation == .valid {
                    self.accept(payload, renewed: nil, session: credentials)
                    return
                }

                if case .unavailable(let detail) = validation {
                    self.sendValidationUnavailable(detail)
                    return
                }

                guard payload.refreshToken?.isEmpty == false,
                      payload.clientId?.isEmpty == false else {
                    self.sendTokenRejected(
                        "Your SoundCloud login has expired. Please sign in again on your iPhone."
                    )
                    return
                }

                let outcome = await self.refreshCoordinator.refresh(
                    refreshToken: payload.refreshToken,
                    clientId: payload.clientId
                )
                guard !Task.isCancelled else { return }

                switch outcome {
                case .succeeded(let renewed):
                    self.accept(payload, renewed: renewed, session: credentials)

                case .transient:
                    self.sendError("Couldn't reach SoundCloud to renew your login. Check the network and try again.")

                case .unrecoverable:
                    self.sendTokenRejected(
                        "Your SoundCloud login has expired. Please sign in again on your iPhone."
                    )
                }
            }

        default:
            break
        }
    }

    private func accept(
        _ payload: TokenPayload,
        renewed: SoundCloudTokenRefresh.Credentials?,
        session: SessionCredentials
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

        LinkOfferKeychainStore.clear()

        CompanionServer.shared.pair(with: session)

        onTokenReceived?(token, refreshToken, payload.clientId, expiresAt)
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
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(BonjourConstants.sessionTimeout))

            guard !Task.isCancelled else { return }

            if state == .advertising {
                stop()
                state = .timeout
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
                name: "\(BonjourConstants.linkOfferServiceName)-\(credentials.sessionId.prefix(8))",
                type: BonjourConstants.serviceType,
                txtRecord: NWTXTRecord(LinkOfferTXT.dictionary(
                    name: UIDevice.current.name,
                    kind: .current,
                    commitment: LinkConfirmationCrypto.commitment(
                        nonce: commitNonce,
                        publicKey: ephemeralKey.publicKey.rawRepresentation
                    )
                ))
            )
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.handleOfferConnection(connection) }
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
        offerSharedSecret = nil
        offerPhonePublicKey = nil
        offerFramer = MessageFramer()
        numericComparisonCode = nil
    }

    private func clearOfferConnection() {
        offerConnection?.cancel()
        offerConnection = nil
        offerConnectionIdleTimeout?.cancel()
        offerConnectionIdleTimeout = nil
    }

    private func armOfferConnectionIdleTimeout() {
        offerConnectionIdleTimeout?.cancel()
        offerConnectionIdleTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            self.numericComparisonCode = nil
            self.clearOfferConnection()
        }
    }

    private func handleOfferConnection(_ newConnection: NWConnection) {
        guard offerConnection == nil else {
            newConnection.cancel()
            return
        }

        offerConnection = newConnection
        offerFramer = MessageFramer()

        newConnection.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor in
                switch connectionState {
                case .failed, .cancelled:
                    self?.clearOfferConnection()
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
        offerConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
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
            guard let hello = message.numericHello,
                  let phonePublicKeyRaw = Data(base64Encoded: hello.ephemeralPublicKeyBase64),
                  let ephemeralKey = offerEphemeralKey,
                  let commitNonce = offerCommitNonce,
                  let phonePublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phonePublicKeyRaw),
                  let shared = try? ephemeralKey.sharedSecretFromKeyAgreement(with: phonePublicKey) else {
                sendOfferError()
                return
            }
            offerSharedSecret = shared
            offerPhonePublicKey = phonePublicKeyRaw
            numericComparisonCode = LinkConfirmationCrypto.code(
                sharedSecret: shared,
                publicKeyA: ephemeralKey.publicKey.rawRepresentation,
                publicKeyB: phonePublicKeyRaw,
                sessionId: sessionIdSalt
            )
            sendOfferMessage(.numericComparisonHelloAck(
                sessionId: sessionIdSalt,
                payload: LinkConfirmationHelloAckPayload(
                    ephemeralPublicKeyBase64: ephemeralKey.publicKey.rawRepresentation.base64EncodedString(),
                    commitNonceBase64: commitNonce.base64EncodedString()
                )
            ))
            armOfferConnectionIdleTimeout()

        case .numericComparisonConfirm:
            guard let shared = offerSharedSecret,
                  let ephemeralKey = offerEphemeralKey,
                  let phonePublicKey = offerPhonePublicKey else {
                sendOfferError()
                return
            }
            let transportKey = LinkConfirmationCrypto.transportKey(
                sharedSecret: shared,
                publicKeyA: ephemeralKey.publicKey.rawRepresentation,
                publicKeyB: phonePublicKey,
                sessionId: sessionIdSalt
            )
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
            numericComparisonCode = nil

        case .numericComparisonDeclined:
            numericComparisonCode = nil
            clearOfferConnection()

        default:
            break
        }
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
                if let error {
                    Log.link.error("[LinkServer] push-offer send failed: \(error.localizedDescription, privacy: .public)")
                }
                if closeAfterSending {
                    self?.clearOfferConnection()
                }
            }
        })
    }

    private func sendOfferError() {
        guard let credentials else { return }
        sendOfferMessage(
            .error(sessionId: String(credentials.sessionId.prefix(8)), message: "Invalid request"),
            closeAfterSending: true
        )
    }
}

enum LinkOfferKeychainStore {
    private static let service = "red.forbes.sounding.pairing-offer"
    private static let account = "pairing_offer"
    private static let sharedAccessGroup = "6Z49PF6642.red.forbes.sounding.shared"

    static func publish(_ offer: LinkOffer) {
        guard let data = try? JSONEncoder().encode(offer) else { return }
        clear()

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: sharedAccessGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            Log.link.error("[LinkOfferKeychainStore] publish failed: \(status, privacy: .public)")
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: sharedAccessGroup,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.link.error("[LinkOfferKeychainStore] clear failed: \(status, privacy: .public)")
        }
    }
}
