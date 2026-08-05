import Foundation
import Network
import Combine
import Security
import CryptoKit
import os

@MainActor
final class LinkClient: ObservableObject {

    enum State: Equatable {
        case idle
        case discovering
        case connecting
        case sending
        case completed
        case failed(String)
        case rejected(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.discovering, .discovering),
                 (.connecting, .connecting),
                 (.sending, .sending),
                 (.completed, .completed):
                return true
            case (.failed(let a), .failed(let b)):
                return a == b
            case (.rejected(let a), .rejected(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    private nonisolated(unsafe) var browser: NWBrowser?
    private nonisolated(unsafe) var connection: NWConnection?
    private nonisolated(unsafe) var discoveryTimeout: Task<Void, Never>?
    private nonisolated(unsafe) var ackTimeout: Task<Void, Never>?
    private nonisolated(unsafe) var handshakeTimeout: Task<Void, Never>?

    private var framer = MessageFramer()

    private nonisolated(unsafe) var connectionSecured = false

    private let sessionId: String
    private let sessionSecret: Data
    private let peerName: String?
    private let peerClass: DeviceClass

    init(sessionId: String, sessionSecret: Data, peerName: String? = nil, peerClass: DeviceClass = .tv) {
        self.sessionId = sessionId
        self.sessionSecret = sessionSecret
        self.peerName = peerName
        self.peerClass = peerClass
    }

    deinit {
        stop()
    }

    func startDiscovery() {
        stop()
        state = .discovering

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        browser = NWBrowser(
            for: .bonjour(
                type: BonjourConstants.serviceType,
                domain: BonjourConstants.serviceDomain
            ),
            using: parameters
        )

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }

        browser?.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor in
                self?.handleBrowserState(browserState)
            }
        }

        browser?.start(queue: .main)

        discoveryTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.state == .discovering else { return }
            self.state = .failed("Could not find Apple TV. Make sure both devices are on the same Wi-Fi network.")
            self.stop()
        }
    }

    func sendToken(_ token: String, refreshToken: String?, clientId: String?, expiresAt: Date?) {
        guard connection != nil else {
            state = .failed("Not connected to Apple TV")
            return
        }

        state = .sending

        let session = StoredSession(
            oauthToken: token,
            refreshToken: refreshToken,
            clientId: clientId,
            expiresAt: expiresAt
        )

        guard session.shouldRefreshBeforeHandoff else {
            transmit(session)
            return
        }

        Task { @MainActor [weak self] in
            let renewed = await DeviceSessionRefresher.shared.refreshIfNeeded(session)
            guard let self, self.state == .sending else { return }
            self.transmit(renewed)
        }
    }

    private func transmit(_ session: StoredSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            guard await self.waitForSecureConnection() else {
                return
            }

            guard let connection = self.connection else {
                self.state = .failed("Not connected to Apple TV")
                return
            }

            let payload = TokenPayload.create(
                token: session.oauthToken,
                refreshToken: session.refreshToken,
                clientId: session.clientId,
                expiresAt: session.expiresAt,
                sessionId: self.sessionId,
                secret: self.sessionSecret
            )

            let message = TokenTransferMessage.tokenTransfer(sessionId: self.sessionId, payload: payload)

            guard let data = try? message.framed() else {
                self.state = .failed("Failed to encode token")
                return
            }

            Log.link.debug("[LinkClient] Sending token (\(data.count, privacy: .public) bytes)")
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    if let error = error {
                        Log.link.error("[LinkClient] Send failed: \(error.localizedDescription, privacy: .public)")
                        self?.state = .failed("Failed to send: \(error.localizedDescription)")
                    } else {
                        Log.link.info("[LinkClient] Send completed, awaiting ack")
                        self?.receiveAcknowledgment()
                        self?.startAckTimeout()
                    }
                }
            })
        }
    }

    private func startHandshakeTimeout() {
        handshakeTimeout?.cancel()
        handshakeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, !self.connectionSecured else { return }
            self.failHandshake(
                "Couldn't securely verify this Apple TV. Make sure it's on the same Wi-Fi network and running the latest version of SoundingTV, then try again."
            )
        }
    }

    private func failHandshake(_ message: String) {
        handshakeTimeout?.cancel()
        state = .failed(message)
        stop()
    }

    private func waitForSecureConnection() async -> Bool {
        for _ in 0..<150 {
            if connectionSecured { return true }
            if case .failed = state { return false }
            if connection == nil { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func startAckTimeout() {
        ackTimeout?.cancel()
        ackTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.state == .sending else { return }
            self.state = .failed("Apple TV did not acknowledge the token. Try again.")
        }
    }

    nonisolated func stop() {
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        ackTimeout?.cancel()
        ackTimeout = nil
        handshakeTimeout?.cancel()
        handshakeTimeout = nil

        browser?.cancel()
        browser = nil

        connection?.cancel()
        connection = nil

        connectionSecured = false
    }

    private func handleBrowserState(_ browserState: NWBrowser.State) {
        switch browserState {
        case .failed(let error):
            state = .failed("Discovery failed: \(error.localizedDescription)")
            stop()
        default:
            break
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        let sessionPrefix = String(sessionId.prefix(8))

        for result in results {
            if case .service(let name, _, _, _) = result.endpoint {
                if name.hasPrefix(BonjourConstants.serviceName), name.contains(sessionPrefix) {
                    discoveryTimeout?.cancel()
                    connectToService(result.endpoint)
                    return
                }
            }
        }
    }

    private func connectToService(_ endpoint: NWEndpoint) {
        state = .connecting
        framer = MessageFramer()
        connectionSecured = false // Fresh per attempt — a retry must not inherit a stale `true`.

        let parameters = LinkTLS.makeParameters(sessionId: sessionId, secret: sessionSecret)

        connection = NWConnection(to: endpoint, using: parameters)

        connection?.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor in
                self?.handleConnectionState(connectionState)
            }
        }

        connection?.start(queue: .main)
        startHandshakeTimeout()
    }

    private func handleConnectionState(_ connectionState: NWConnection.State) {
        switch connectionState {
        case .ready:
            Log.link.info("[LinkClient] Connected to Apple TV (TLS-PSK verified)")
            handshakeTimeout?.cancel()
            connectionSecured = true
        case .failed(let error):
            state = .failed("Couldn't establish a secure connection with this Apple TV: \(error.localizedDescription)")
            connection = nil
        case .cancelled:
            connection = nil
        default:
            break
        }
    }

    private func receiveAcknowledgment() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self = self else { return }
                Log.link.debug("[LinkClient] receive callback: bytes=\(data?.count ?? 0, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)")

                if let error = error {
                    self.state = .failed("Error receiving acknowledgment: \(error.localizedDescription)")
                    return
                }

                guard let data, !data.isEmpty else {
                    self.state = .failed("Invalid response from Apple TV")
                    return
                }

                self.framer.append(data)
                guard let message = try? self.framer.next() else {
                    self.receiveAcknowledgment() // Partial frame — keep reading.
                    return
                }

                self.ackTimeout?.cancel()
                switch message.type {
                case .acknowledgment:
                    if let renewed = message.payload,
                       renewed.verify(sessionId: self.sessionId, secret: self.sessionSecret) {
                        DeviceSessionStore.save(StoredSession(
                            oauthToken: renewed.oauthToken,
                            refreshToken: renewed.refreshToken,
                            clientId: renewed.clientId,
                            expiresAt: renewed.expiresAt
                        ))
                        DeviceSessionRefresher.shared.reset() // The remembered verdict was about credentials just replaced.
                        Log.link.info("[LinkClient] adopted credentials refreshed by the Apple TV")
                    }

                    LinkedCompanionStore.save(
                        sessionId: self.sessionId,
                        secret: self.sessionSecret,
                        deviceClass: self.peerClass,
                        displayName: self.peerName
                    )
                    self.state = .completed
                    self.stop()
                case .tokenRejected:
                    self.state = .rejected(
                        message.error ?? "That SoundCloud login is no longer valid."
                    )
                    self.stop()
                case .error:
                    self.state = .failed(message.error ?? "Apple TV rejected the token")
                default:
                    break
                }
            }
        }
    }
}

enum LinkedCompanionStore {
    private static let service = "red.forbes.sounding.phone"
    private static let account = "paired_tv"

    private static let sharedAccessGroup = "6Z49PF6642.red.forbes.sounding.shared"

    private static let legacyAccessGroup = "6Z49PF6642.red.forbes.sounding"

    struct LinkRecord: Codable, Equatable {
        var sessionId: String
        var secretBase64: String
        var pairedAt: Date
        var deviceClass: DeviceClass?
        var displayName: String?

        var secret: Data? { Data(base64Encoded: secretBase64) }
        var peerClass: DeviceClass { deviceClass ?? .tv }
        var peerName: String { displayName ?? peerClass.displayName }
    }

    static func load() -> LinkRecord? {
        if let link = load(accessGroup: sharedAccessGroup) {
            return link
        }

        guard let legacy = load(accessGroup: legacyAccessGroup), let secret = legacy.secret else {
            return nil
        }

        save(sessionId: legacy.sessionId, secret: secret)
        deleteLegacy()
        return legacy
    }

    private static func load(accessGroup: String) -> LinkRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let link = try? JSONDecoder().decode(LinkRecord.self, from: data),
              link.secret != nil else {
            return nil
        }
        return link
    }

    static func save(sessionId: String, secret: Data, deviceClass: DeviceClass = .tv, displayName: String? = nil) {
        let link = LinkRecord(
            sessionId: sessionId,
            secretBase64: secret.base64EncodedString(),
            pairedAt: Date(),
            deviceClass: deviceClass,
            displayName: displayName
        )
        guard let data = try? JSONEncoder().encode(link) else { return }

        clear(notify: false)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: sharedAccessGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            Log.link.error("[LinkedCompanionStore] save failed: \(status, privacy: .public)")
            return
        }
        if let offer = LinkOfferStore.fetchLatest(), offer.sessionId == sessionId {
            LinkOfferStore.discard(offer)
        }
        NotificationCenter.default.post(name: .pairedTVDidChange, object: nil)
    }

    static func clear() {
        clear(notify: true)
    }

    private static func clear(notify: Bool) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: sharedAccessGroup,
        ]
        SecItemDelete(query as CFDictionary)
        if notify {
            NotificationCenter.default.post(name: .pairedTVDidChange, object: nil)
        }
    }

    private static func deleteLegacy() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: legacyAccessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension Notification.Name {
    static let pairedTVDidChange = Notification.Name("red.forbes.sounding.paired-tv-did-change")
}

enum LinkOfferStore {
    private static let service = "red.forbes.sounding.pairing-offer"
    private static let account = "pairing_offer"
    private static let sharedAccessGroup = "6Z49PF6642.red.forbes.sounding.shared"

    static func fetchLatest() -> LinkOffer? {
        if let shared = fetch(accessGroup: sharedAccessGroup) {
            return validate(shared)
        }
        // Read the old app-private item once so an in-flight link from a
        // previous build is not lost during the shared-keychain migration.
        guard let legacy = fetch(accessGroup: nil) else { return nil }
        return validate(legacy)
    }

    private static func fetch(accessGroup: String?) -> LinkOffer? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let offer = try? JSONDecoder().decode(LinkOffer.self, from: data) else {
            if status != errSecSuccess && status != errSecItemNotFound {
                Log.link.error("[LinkOfferStore] fetch failed: \(status, privacy: .public)")
            }
            return nil
        }
        return offer
    }

    private static func validate(_ offer: LinkOffer) -> LinkOffer? {
        guard !offer.isExpired else {
            discard(offer)
            return nil
        }
        return offer
    }

    static func discard(_ offer: LinkOffer) {
        delete(accessGroup: sharedAccessGroup)
        delete(accessGroup: nil)
    }

    private static func delete(accessGroup: String?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.link.error("[LinkOfferStore] delete failed: \(status, privacy: .public)")
        }
    }
}

/// One secure, reusable path for an already-authenticated iPhone, Mac, or
/// Apple Watch to authorize a waiting Apple TV. The transfer remains
/// TLS-PSK authenticated and refreshes expiring credentials before handoff.
@MainActor
final class CompanionLinker: ObservableObject {
    enum State: Equatable {
        case idle
        case findingTV
        case connecting
        case transferring
        case completed(tvName: String)
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .findingTV, .connecting, .transferring: return true
            case .idle, .completed, .failed: return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    private var client: LinkClient?

    func authorize(offer: LinkOffer, session: StoredSession) async {
        guard let secret = offer.secret else {
            state = .failed("The TV's authorization request could not be verified.")
            return
        }
        await authorize(
            sessionId: offer.sessionId,
            secret: secret,
            tvName: offer.tvName,
            session: session
        )
        if case .completed = state { LinkOfferStore.discard(offer) }
    }

    func authorize(
        sessionId: String,
        secret: Data,
        tvName: String,
        session: StoredSession
    ) async {
        cancel(resetState: false)

        let transfer = LinkClient(sessionId: sessionId, sessionSecret: secret, peerName: tvName)
        client = transfer
        state = .findingTV
        transfer.startDiscovery()

        for _ in 0..<60 {
            guard !Task.isCancelled, transfer === client else { return }
            switch transfer.state {
            case .connecting:
                state = .connecting
                transfer.sendToken(
                    session.oauthToken,
                    refreshToken: session.refreshToken,
                    clientId: session.clientId,
                    expiresAt: session.expiresAt
                )
                break
            case .failed(let message), .rejected(let message):
                state = .failed(message)
                client = nil
                return
            case .idle, .discovering:
                try? await Task.sleep(for: .milliseconds(500))
                continue
            case .sending:
                break
            case .completed:
                state = .completed(tvName: tvName)
                client = nil
                return
            }
            break
        }

        guard transfer === client else { return }
        if transfer.state == .discovering {
            state = .failed("Could not find \(tvName). Make sure both devices are on the same network.")
            client = nil
            return
        }

        state = .transferring
        for _ in 0..<90 {
            guard !Task.isCancelled, transfer === client else { return }
            switch transfer.state {
            case .completed:
                state = .completed(tvName: tvName)
                client = nil
                return
            case .failed(let message), .rejected(let message):
                state = .failed(message)
                client = nil
                return
            default:
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        guard transfer === client else { return }
        state = .failed("\(tvName) did not finish authorization. Try again while its sign-in screen is open.")
        transfer.stop()
        client = nil
    }

    func reset() { cancel(resetState: true) }

    private func cancel(resetState: Bool) {
        client?.stop()
        client = nil
        if resetState { state = .idle }
    }
}

@MainActor
final class LinkOfferBrowser: ObservableObject {
    struct Offer: Equatable {
        let claimedName: String
        let kind: DeviceClass
        // Some Bonjour paths (including cross-simulator discovery) resolve the
        // service endpoint but omit its TXT record. Numeric comparison still
        // authenticates the channel in that case; the commitment is an extra
        // early binding when the TXT record is available.
        let commitment: Data?
        let sessionIdPrefix: String
        let endpoint: NWEndpoint

        var displayIdentity: String {
            "\(claimedName) (\(kind.displayName))"
        }
    }

    @Published private(set) var offer: Offer?

    private nonisolated(unsafe) var browser: NWBrowser?
    private nonisolated(unsafe) var pairingObserver: NSObjectProtocol?

    init() {
        pairingObserver = NotificationCenter.default.addObserver(
            forName: .pairedTVDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pairingDidChange() }
        }
    }

    deinit {
        if let pairingObserver {
            NotificationCenter.default.removeObserver(pairingObserver)
        }
        stop()
    }

    func start() {
        stop()

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let newBrowser = NWBrowser(
            for: .bonjour(type: BonjourConstants.serviceType, domain: BonjourConstants.serviceDomain),
            using: parameters
        )
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handleResults(results) }
        }
        newBrowser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Log.link.info("[LinkOfferBrowser] ready")
            case .failed(let error):
                Log.link.error("[LinkOfferBrowser] failed: \(error.localizedDescription, privacy: .public)")
            case .waiting(let error):
                Log.link.info("[LinkOfferBrowser] waiting: \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        newBrowser.start(queue: .main)
        browser = newBrowser
    }

    nonisolated func stop() {
        browser?.cancel()
        browser = nil
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        guard LinkedCompanionStore.load() == nil else {
            offer = nil
            return
        }

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  name.hasPrefix(BonjourConstants.linkOfferServiceName + "-") else { continue }

            let decoded: (name: String, kind: DeviceClass, commitment: Data)?
            if case .bonjour(let record) = result.metadata {
                decoded = LinkOfferTXT.decode(record)
            } else {
                decoded = nil
            }

            let prefix = name.count > BonjourConstants.linkOfferServiceName.count + 1
                ? String(name.dropFirst(BonjourConstants.linkOfferServiceName.count + 1))
                : name

            // The auth offer and the remote-control link intentionally use
            // the same session. Bonjour can briefly retain an offer after the
            // TV has completed sign-in, so never surface that completed
            // session as a fresh request.
            if let pairedSession = LinkedCompanionStore.load()?.sessionId,
               String(pairedSession.prefix(8)) == prefix {
                Log.link.debug("[LinkOfferBrowser] ignoring completed link offer \(name, privacy: .public)")
                continue
            }

            offer = Offer(
                claimedName: decoded?.name ?? "Nearby Apple TV",
                kind: decoded?.kind ?? .tv,
                commitment: decoded?.commitment,
                sessionIdPrefix: prefix,
                endpoint: result.endpoint
            )
            Log.link.info("[LinkOfferBrowser] found \(name, privacy: .public); TXT record present=\(decoded != nil, privacy: .public)")
            return
        }

        offer = nil
    }

    private func pairingDidChange() {
        if LinkedCompanionStore.load() != nil {
            offer = nil
            stop()
        } else {
            // A forgotten television may already be present in NWBrowser's
            // cached result set, so restart to surface it without relaunching.
            start()
        }
    }
}

@MainActor
final class LinkConfirmationHandshake: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case awaitingComparison(code: String)
        case confirming
        case succeeded(sessionId: String, secret: Data, tvName: String)
        case failed(String)
        case declined
    }

    @Published private(set) var state: State = .idle

    var claimedName: String { offer.claimedName }
    var kind: DeviceClass { offer.kind }

    private nonisolated(unsafe) var connection: NWConnection?
    private nonisolated(unsafe) var connectTimeout: Task<Void, Never>?
    private nonisolated(unsafe) var ackTimeout: Task<Void, Never>?
    private nonisolated(unsafe) var credentialsTimeout: Task<Void, Never>?

    private var framer = MessageFramer()
    private var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private var sharedSecret: SharedSecret?
    private var transportKey: SymmetricKey?
    private var verifiedTVPublicKey: Data?

    private let offer: LinkOfferBrowser.Offer

    init(offer: LinkOfferBrowser.Offer) {
        self.offer = offer
    }

    deinit { stopNetworking() }

    func start() {
        stop()
        state = .connecting

        ephemeralKey = Curve25519.KeyAgreement.PrivateKey()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let newConnection = NWConnection(to: offer.endpoint, using: parameters)
        connection = newConnection

        newConnection.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor in self?.handleConnectionState(connectionState) }
        }
        newConnection.start(queue: .main)

        connectTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.state == .connecting else { return }
            self.state = .failed("Couldn't reach that device. Make sure it's still on its sign-in screen.")
            self.stopNetworking()
        }
    }

    private func handleConnectionState(_ connectionState: NWConnection.State) {
        switch connectionState {
        case .ready:
            connectTimeout?.cancel()
            sendHello()
        case .failed(let error):
            state = .failed("Couldn't reach that device: \(error.localizedDescription)")
            stopNetworking()
        case .cancelled:
            break
        default:
            break
        }
    }

    private func sendHello() {
        guard let ephemeralKey else { return }
        let hello = LinkConfirmationHelloPayload(
            ephemeralPublicKeyBase64: ephemeralKey.publicKey.rawRepresentation.base64EncodedString()
        )
        guard let data = try? TokenTransferMessage.numericComparisonHello(
            sessionId: offer.sessionIdPrefix, payload: hello
        ).framed() else {
            state = .failed("Couldn't prepare the request.")
            stopNetworking()
            return
        }

        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .failed("Couldn't send: \(error.localizedDescription)")
                    self.stopNetworking()
                } else {
                    self.receive()
                    self.startAckTimeout()
                }
            }
        })
    }

    private func startAckTimeout() {
        ackTimeout?.cancel()
        ackTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.state == .connecting else { return }
            self.state = .failed("That device didn't respond. Try again.")
            self.stopNetworking()
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .failed("Connection lost: \(error.localizedDescription)")
                    self.stopNetworking()
                    return
                }
                if let data, !data.isEmpty {
                    self.framer.append(data)
                    while let message = try? self.framer.next() {
                        self.handle(message)
                    }
                }
                if isComplete {
                    self.connection?.cancel()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func handle(_ message: TokenTransferMessage) {
        switch message.type {
        case .numericComparisonHelloAck:
            ackTimeout?.cancel()
            guard let ephemeralKey,
                  let ack = message.numericHelloAck,
                  let tvPublicKeyRaw = Data(base64Encoded: ack.ephemeralPublicKeyBase64),
                  let commitNonce = Data(base64Encoded: ack.commitNonceBase64) else {
                state = .failed("Received something we couldn't verify. Try again.")
                stopNetworking()
                return
            }

            guard offer.commitment.map({
                LinkConfirmationCrypto.commitment(nonce: commitNonce, publicKey: tvPublicKeyRaw) == $0
            }) ?? true else {
                state = .failed("Received something we couldn't verify. Try again.")
                stopNetworking()
                return
            }

            guard let peerPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: tvPublicKeyRaw),
                  let secret = try? ephemeralKey.sharedSecretFromKeyAgreement(with: peerPublicKey) else {
                state = .failed("Couldn't establish a secure channel with this device.")
                stopNetworking()
                return
            }
            sharedSecret = secret
            verifiedTVPublicKey = tvPublicKeyRaw

            let code = LinkConfirmationCrypto.code(
                sharedSecret: secret,
                publicKeyA: ephemeralKey.publicKey.rawRepresentation,
                publicKeyB: tvPublicKeyRaw,
                sessionId: offer.sessionIdPrefix
            )
            state = .awaitingComparison(code: code)

        case .numericComparisonCredentials:
            credentialsTimeout?.cancel()
            guard let payload = message.numericCredentials,
                  let sealed = Data(base64Encoded: payload.sealedBase64),
                  let transportKey,
                  let opened = try? LinkConfirmationCrypto.open(sealed, key: transportKey),
                  let decoded = try? JSONDecoder().decode(LinkOffer.self, from: opened),
                  !decoded.isExpired,
                  let secret = decoded.secret else {
                state = .failed("Received something we couldn't verify. Try again.")
                stopNetworking()
                return
            }
            state = .succeeded(sessionId: decoded.sessionId, secret: secret, tvName: decoded.tvName)
            stopNetworking()

        case .numericComparisonDeclined:
            state = .failed("That device declined the request.")
            stopNetworking()

        case .error:
            state = .failed(message.error ?? "That device rejected the request.")
            stopNetworking()

        default:
            break
        }
    }

    func confirm() {
        guard case .awaitingComparison = state,
              let sharedSecret, let ephemeralKey, let verifiedTVPublicKey else { return }

        transportKey = LinkConfirmationCrypto.transportKey(
            sharedSecret: sharedSecret,
            publicKeyA: ephemeralKey.publicKey.rawRepresentation,
            publicKeyB: verifiedTVPublicKey,
            sessionId: offer.sessionIdPrefix
        )
        state = .confirming

        guard let data = try? TokenTransferMessage.numericComparisonConfirm(sessionId: offer.sessionIdPrefix).framed() else {
            state = .failed("Couldn't confirm.")
            stopNetworking()
            return
        }
        connection?.send(content: data, completion: .contentProcessed { _ in })

        credentialsTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.state == .confirming else { return }
            self.state = .failed("That device didn't finish signing you in. Try again.")
            self.stopNetworking()
        }
    }

    func decline() {
        if let data = try? TokenTransferMessage.numericComparisonDeclined(sessionId: offer.sessionIdPrefix).framed() {
            connection?.send(content: data, completion: .contentProcessed { _ in })
        }
        state = .declined
        stopNetworking()
    }

    func stop() {
        stopNetworking()
        state = .idle
    }

    private nonisolated func stopNetworking() {
        connectTimeout?.cancel()
        connectTimeout = nil
        ackTimeout?.cancel()
        ackTimeout = nil
        credentialsTimeout?.cancel()
        credentialsTimeout = nil
        connection?.cancel()
        connection = nil
    }
}
