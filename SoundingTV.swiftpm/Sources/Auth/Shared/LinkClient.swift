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

    @Published private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            Self.transfers.send(Transfer(sessionId: sessionId, state: state))
        }
    }

    struct Transfer: Equatable {
        let sessionId: String
        let state: State
    }

    static let transfers = PassthroughSubject<Transfer, Never>()

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

    private var retry = LinkRetryPolicy()

    static var fixtureSession: StoredSession? {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SOUNDING_TV_LINK_FIXTURE_TOKEN"] == "1" else { return nil }
        return StoredSession(
            oauthToken: BonjourConstants.fixtureLinkToken,
            refreshToken: "fixture-refresh",
            clientId: "fixture-client",
            expiresAt: Date().addingTimeInterval(3600)
        )
        #else
        return nil
        #endif
    }

    func startDiscovery() {
        retry = LinkRetryPolicy()
        beginDiscovery()
    }

    private func beginDiscovery() {
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
            try? await Task.sleep(for: .seconds(LinkStep.findingTV.timeout))
            guard !Task.isCancelled, let self, self.state == .discovering else { return }
            Log.link.error("[LinkClient] discovery timed out after 30 s")
            self.state = .failed(LinkStep.findingTV.timedOutMessage(peer: self.peerClass.displayName))
            self.stop()
        }
    }

    func sendToken(_ token: String, refreshToken: String?, clientId: String?, expiresAt: Date?) {
        guard connection != nil else {
            state = .failed("Not connected to your \(peerClass.displayName)")
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
            let renewed = await DeviceSessionRefresher.shared.refreshIfNeeded(session, trigger: "link handoff")
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
                self.state = .failed("Not connected to your \(self.peerClass.displayName)")
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

            let message = TokenTransferMessage.tokenTransfer(
                sessionId: self.sessionId,
                payload: payload,
                peer: LinkPeerIdentity.local(sessionId: self.sessionId, secret: self.sessionSecret)
            )

            guard let data = try? message.framed() else {
                self.state = .failed("Couldn't prepare the sign-in. Try again.")
                return
            }

            Log.link.debug("[LinkClient] Sending token (\(data.count, privacy: .public) bytes)")
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    if let error = error {
                        Log.link.error("[LinkClient] Send failed: \(String(describing: error), privacy: .public)")
                        self?.state = .failed(LinkFailureCopy.message(for: error, peer: self?.peerClass ?? .tv))
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
            try? await Task.sleep(for: .seconds(LinkStep.securing.timeout))
            guard !Task.isCancelled, let self, !self.connectionSecured else { return }
            Log.link.error("[LinkClient] TLS-PSK not ready within \(LinkStep.securing.timeout, privacy: .public) s")
            self.failHandshake(LinkStep.securing.timedOutMessage(peer: self.peerClass.displayName))
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
            Log.link.error("[LinkClient] no ack within 15 s")
            self.state = .failed(LinkStep.waitingForTV.timedOutMessage(peer: self.peerClass.displayName))
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
            Log.link.error("[LinkClient] browser failed: \(String(describing: error), privacy: .public)")
            state = .failed(LinkFailureCopy.message(for: error, peer: peerClass))
            stop()
        case .waiting(let error):
            Log.link.error("[LinkClient] browser waiting: \(String(describing: error), privacy: .public)")
            if LinkFailureCopy.isLocalNetworkDenied(error) {
                state = .failed(LinkFailureCopy.message(for: error, peer: peerClass))
                stop()
            }
        default:
            break
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        guard connection == nil, state == .discovering else { return }
        let expected = BonjourConstants.linkServiceName(sessionId: sessionId)
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint, name == expected else { continue }
            Log.link.info("[LinkClient] found \(name, privacy: .public); opening TLS-PSK")
            discoveryTimeout?.cancel()
            connectToService(result.endpoint)
            return
        }
        Log.link.debug("[LinkClient] \(results.count, privacy: .public) services seen, none is \(expected, privacy: .public)")
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
            Log.link.error("[LinkClient] TLS-PSK connection failed: \(String(describing: error), privacy: .public)")
            if !LinkFailureCopy.isLocalNetworkDenied(error), let delay = retry.nextDelay() {
                Log.link.info("[LinkClient] retrying in \(delay, privacy: .public) s (attempt \(self.retry.attempts, privacy: .public)/\(LinkRetryPolicy.maximumAttempts, privacy: .public))")
                stop()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, self.state == .connecting else { return }
                    self.beginDiscovery()
                }
                return
            }
            state = .failed(LinkFailureCopy.message(for: error, peer: peerClass))
            stop()
        case .waiting(let error):
            Log.link.error("[LinkClient] TLS-PSK connection waiting: \(String(describing: error), privacy: .public)")
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
                    Log.link.error("[LinkClient] ack receive failed: \(String(describing: error), privacy: .public)")
                    self.state = .failed(LinkFailureCopy.message(for: error, peer: self.peerClass))
                    return
                }

                guard let data, !data.isEmpty else {
                    Log.link.error("[LinkClient] connection closed before the ack")
                    self.state = .failed(LinkFailureCopy.droppedMessage(peer: self.peerClass))
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
                    Log.link.error("[LinkClient] peer answered error: \(message.error ?? "nil", privacy: .public)")
                    self.state = .failed("\(self.peerClass.displayName) couldn't use this sign-in. Try again.")
                    self.stop()
                default:
                    break
                }
            }
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
        var rendezvous: String? = nil
        var accountHint: LinkAccountHint.Advert? = nil

        var isSignedIn: Bool { accountHint != nil }

        var displayIdentity: String {
            claimedName.localizedCaseInsensitiveContains(kind.displayName)
                ? claimedName
                : "\(claimedName) (\(kind.displayName))"
        }
    }

    @Published private(set) var offer: Offer?
    @Published private(set) var offers: [Offer] = []
    @Published private(set) var localNetworkDenied = false

    private var firstSeen: [String: Date] = [:]
    private nonisolated(unsafe) var browser: NWBrowser?
    private var pairingSubscription: AnyCancellable?
    private let allowsRelinking: Bool

    init(allowsRelinking: Bool = false) {
        self.allowsRelinking = allowsRelinking
        pairingSubscription = LinkedCompanionStore.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pairingDidChange() }
    }

    deinit {
        stop()
    }

    func start() {
        stop()

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let newBrowser = NWBrowser(
            for: .bonjourWithTXTRecord(type: BonjourConstants.serviceType, domain: BonjourConstants.serviceDomain),
            using: parameters
        )
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handleResults(results) }
        }
        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.localNetworkDenied = false
                case .failed(let error), .waiting(let error): self?.localNetworkDenied = LinkFailureCopy.isLocalNetworkDenied(error)
                default: break
                }
            }
            switch state {
            case .ready:
                Log.link.info("[LinkOfferBrowser] ready")
            case .failed(let error):
                Log.link.error("[LinkOfferBrowser] failed: \(error.localizedDescription, privacy: .public)")
            case .waiting(let error):
                Log.link.error("[LinkOfferBrowser] waiting: \(String(describing: error), privacy: .public)")
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

    func startIfNeeded() {
        guard browser == nil else { return }
        start()
    }

    func suspend() {
        stop()
        offer = nil
        offers = []
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        let linked = LinkedCompanionStore.loadAll()
        guard allowsRelinking || linked.isEmpty else {
            offer = nil
            offers = []
            return
        }
        let pairedPrefixes = Set(linked.map(\.servicePrefix))

        var found: [Offer] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  name.hasPrefix(BonjourConstants.linkOfferServiceName + "-") else { continue }

            let decoded: (name: String, kind: DeviceClass, commitment: Data)?
            var rendezvous: String?
            var accountHint: LinkAccountHint.Advert?
            if case .bonjour(let record) = result.metadata {
                decoded = LinkOfferTXT.decode(record)
                rendezvous = LinkOfferTXT.rendezvous(record)
                accountHint = LinkAccountHint.decode(record)
            } else {
                decoded = nil
            }

            let prefix = name.count > BonjourConstants.linkOfferServiceName.count + 1
                ? String(name.dropFirst(BonjourConstants.linkOfferServiceName.count + 1))
                : name

            if pairedPrefixes.contains(prefix) {
                Log.link.debug("[LinkOfferBrowser] ignoring completed link offer \(name, privacy: .public)")
                continue
            }

            found.append(Offer(
                claimedName: decoded?.name ?? "Nearby Apple TV",
                kind: decoded?.kind ?? .tv,
                commitment: decoded?.commitment,
                sessionIdPrefix: prefix,
                endpoint: result.endpoint,
                rendezvous: rendezvous,
                accountHint: accountHint
            ))
            Log.link.info("[LinkOfferBrowser] found \(name, privacy: .public); TXT=\(decoded != nil, privacy: .public) signedIn=\(accountHint != nil, privacy: .public)")
        }

        found.sort { $0.sessionIdPrefix < $1.sessionIdPrefix }
        let now = Date()
        let live = Set(found.map(\.sessionIdPrefix))
        firstSeen = firstSeen.filter { live.contains($0.key) }
        for prefix in live where firstSeen[prefix] == nil { firstSeen[prefix] = now }
        offers = found
        offer = found.first
    }

    var distinctOffers: [Offer] {
        var freshest: [String: Offer] = [:]
        for offer in offers {
            let key = SameAccountLinkOffer.identity(name: offer.claimedName, kind: offer.kind)
            guard let current = freshest[key] else {
                freshest[key] = offer
                continue
            }
            if seenAt(offer) > seenAt(current) { freshest[key] = offer }
        }
        var emitted: Set<String> = []
        return offers.compactMap { offer in
            let key = SameAccountLinkOffer.identity(name: offer.claimedName, kind: offer.kind)
            guard let pick = freshest[key], pick.sessionIdPrefix == offer.sessionIdPrefix,
                  emitted.insert(key).inserted else { return nil }
            return pick
        }
    }

    private func seenAt(_ offer: Offer) -> Date {
        firstSeen[offer.sessionIdPrefix] ?? .distantPast
    }

    private func pairingDidChange() {
        offer = nil
        offers = []
        if !LinkedCompanionStore.loadAll().isEmpty, !allowsRelinking {
            stop()
        } else {
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
    private var ownerKeys: [String: LinkOwnerKey] = [:]
    private var ownerKey: LinkOwnerKey?
    private var ownerTranscript: LinkOwnerProof.Transcript?

    @Published private(set) var isOwnerVerified = false

    private let offer: LinkOfferBrowser.Offer
    private let localName = String(LinkPeerIdentity.localName.prefix(LinkPeerIdentity.maximumNameLength))

    init(offer: LinkOfferBrowser.Offer) {
        self.offer = offer
    }

    deinit { stopNetworking() }

    func start() {
        stop()
        state = .connecting
        isOwnerVerified = false
        ownerKey = nil
        ownerTranscript = nil

        let key = Curve25519.KeyAgreement.PrivateKey()
        ephemeralKey = key
        let sameAccount = SameAccountLinkModel.accountId.map { offer.accountHint?.matches(accountId: $0) == true } ?? false
        ownerKeys = sameAccount
            ? LinkOwnerProof.tags(
                for: LinkOwnerKeyStore.usableKeys(),
                sessionId: offer.sessionIdPrefix,
                initiatorKey: key.publicKey.rawRepresentation.base64EncodedString()
            )
            : [:]

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
            Log.link.error("[LinkConfirmationHandshake] connection failed: \(String(describing: error), privacy: .public)")
            state = .failed(LinkFailureCopy.message(for: error, peer: offer.kind))
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
            ephemeralPublicKeyBase64: ephemeralKey.publicKey.rawRepresentation.base64EncodedString(),
            deviceName: localName,
            deviceClass: DeviceClass.current.rawValue,
            ownerKeyTags: ownerKeys.isEmpty ? nil : ownerKeys.keys.sorted()
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
                    Log.link.error("[LinkConfirmationHandshake] send failed: \(String(describing: error), privacy: .public)")
                    self.state = .failed(LinkFailureCopy.message(for: error, peer: self.offer.kind))
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
                    switch self.state {
                    case .connecting, .awaitingComparison, .confirming:
                        Log.link.error("[LinkConfirmationHandshake] receive failed: \(String(describing: error), privacy: .public)")
                        self.state = .failed(LinkFailureCopy.droppedMessage(peer: self.offer.kind))
                        self.stopNetworking()
                    default:
                        break
                    }
                    return
                }
                if let data, !data.isEmpty {
                    self.framer.append(data)
                    while let message = try? self.framer.next() {
                        self.handle(message)
                    }
                }
                if isComplete {
                    switch self.state {
                    case .connecting, .awaitingComparison, .confirming:
                        self.state = .failed("\(self.claimedName) stopped responding. Open its sign-in screen and try again.")
                        self.stopNetworking()
                    default:
                        self.connection?.cancel()
                    }
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
                sessionId: offer.sessionIdPrefix,
                peerName: localName
            )
            state = .awaitingComparison(code: code)
            if let owner = verifiedOwner(ack, tvPublicKey: tvPublicKeyRaw, commitNonce: commitNonce) {
                ownerKey = owner.key
                ownerTranscript = owner.transcript
                isOwnerVerified = true
                Log.link.info("[LinkConfirmationHandshake] same owner verified; linking without a code")
                confirm()
            }

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
            sessionId: offer.sessionIdPrefix,
            peerName: localName
        )
        state = .confirming

        let ownerProof = ownerKey.flatMap { key in
            ownerTranscript.flatMap { LinkOwnerProof.sign(.initiator, key: key.material, transcript: $0) }
        }
        guard let data = try? TokenTransferMessage.numericComparisonConfirm(
            sessionId: offer.sessionIdPrefix,
            ownerProof: ownerProof
        ).framed() else {
            state = .failed("Couldn't confirm.")
            stopNetworking()
            return
        }
        connection?.send(content: data, completion: .contentProcessed { _ in })

        credentialsTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(BonjourConstants.linkApprovalTimeout))
            guard !Task.isCancelled, let self, self.state == .confirming else { return }
            self.state = .failed("That device didn't finish signing you in. Try again.")
            self.stopNetworking()
        }
    }

    private func verifiedOwner(
        _ ack: LinkConfirmationHelloAckPayload,
        tvPublicKey: Data,
        commitNonce: Data
    ) -> (key: LinkOwnerKey, transcript: LinkOwnerProof.Transcript)? {
        guard let tag = ack.ownerKeyTag, let key = ownerKeys[tag], let ephemeralKey,
              let accountId = SameAccountLinkModel.accountId, !accountId.isEmpty else { return nil }
        let transcript = LinkOwnerProof.Transcript(
            sessionId: offer.sessionIdPrefix,
            initiatorKey: ephemeralKey.publicKey.rawRepresentation.base64EncodedString(),
            responderKey: tvPublicKey.base64EncodedString(),
            commitNonce: commitNonce.base64EncodedString(),
            initiatorName: localName,
            initiatorClass: DeviceClass.current.rawValue,
            accountId: accountId
        )
        guard LinkOwnerProof.verify(ack.ownerProof, role: .responder, key: key.material, transcript: transcript) else {
            Log.link.info("[LinkConfirmationHandshake] same-owner proof didn't verify; comparing codes instead")
            return nil
        }
        return (key, transcript)
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

enum LinkFailureCopy {
    static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        switch error {
        case .dns(let code): return code == -65570
        case .posix(let code): return code == .EPERM || code == .EACCES
        default: return false
        }
    }

    static func message(for error: NWError, peer: DeviceClass) -> String {
        if isLocalNetworkDenied(error) {
            return "Sounding can't use the local network. Turn on Local Network for Sounding in Settings › Privacy & Security, then try again."
        }
        switch error {
        case .tls:
            return "Couldn't verify this \(peer.displayName). Open Sounding on it, choose Add a Device again, then try again."
        case .posix(let code) where code == .ECONNREFUSED || code == .ETIMEDOUT || code == .EHOSTUNREACH || code == .ENETUNREACH:
            return "Couldn't reach your \(peer.displayName). Check it's on the same Wi-Fi network, then try again."
        default:
            return droppedMessage(peer: peer)
        }
    }

    static func droppedMessage(peer: DeviceClass) -> String {
        "The connection to your \(peer.displayName) dropped. Keep both devices on the same Wi-Fi network and try again."
    }
}


@MainActor
final class SameAccountLinkModel: ObservableObject {
    @Published private(set) var offer = SameAccountLinkOffer()

    private let browser: LinkOfferBrowser
    private var subscriptions: Set<AnyCancellable> = []
    private var presence: NWListener?
    private var presenceKey: String?
    private var isForeground = false

    init(browser: LinkOfferBrowser) {
        self.browser = browser
        browser.$offers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] offers in self?.observe(offers) }
            .store(in: &subscriptions)
        LinkClient.transfers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transfer in self?.track(transfer) }
            .store(in: &subscriptions)
    }

    static var accountId: String? {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["SOUNDING_TV_LINK_ACCOUNT"], !forced.isEmpty { return forced }
        #endif
        return SoundCloudCredentialSource.shared.currentUser?.id
    }

    static func linkedIdentities() -> Set<String> {
        Set(LinkedCompanionStore.loadAll().map { SameAccountLinkOffer.identity(name: $0.peerName, kind: $0.peerClass) })
    }

    var suggestedOffer: LinkOfferBrowser.Offer? {
        guard let candidate = offer.suggestion else { return nil }
        return browser.offers.first { $0.sessionIdPrefix == candidate.sessionIdPrefix }
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        updatePresence()
    }

    func accept() -> LinkOfferBrowser.Offer? {
        let offer = suggestedOffer
        guard self.offer.accept(now: .now) != nil else { return nil }
        Log.link.info("[SameAccountLink] user chose Link")
        return offer
    }

    func dismiss() {
        offer.dismiss()
        updatePresence()
    }

    func retry() {
        offer.retry()
    }

    func handshakeEnded(succeeded: Bool) {
        guard !succeeded else { return }
        if case .linking = offer.phase { offer.finish(succeeded: false) }
        offer.retry()
    }

    func transferFailed(message: String) {
        if case .linking = offer.phase { offer.finish(succeeded: false, message: message) }
    }

    private func observe(_ offers: [LinkOfferBrowser.Offer]) {
        let candidates = SameAccountLinkOffer.candidates(
            from: offers.map { SameAccountLinkOffer.Advertised(sessionIdPrefix: $0.sessionIdPrefix, name: $0.claimedName, kind: $0.kind, accountHint: $0.accountHint) },
            accountId: Self.accountId,
            deviceId: LinkPeerIdentity.localDeviceId(),
            linked: Self.linkedIdentities()
        )
        let before = offer.suggestion
        offer.observe(candidates, now: .now)
        if offer.suggestion != before {
            Log.link.info("[SameAccountLink] suggestion: \(self.offer.suggestion?.name ?? "none", privacy: .public) of \(candidates.count, privacy: .public) same-account TVs")
        }
        updatePresence()
    }

    private func track(_ transfer: LinkClient.Transfer) {
        guard case .linking(let candidate, _) = offer.phase,
              transfer.sessionId.hasPrefix(candidate.sessionIdPrefix) else { return }
        switch transfer.state {
        case .completed:
            offer.finish(succeeded: true)
        case .failed(let message), .rejected(let message):
            offer.finish(succeeded: false, message: message)
        default:
            break
        }
    }

    private func updatePresence() {
        let wanted = isForeground && offer.suggestion != nil ? Self.accountId : nil
        guard wanted != presenceKey else { return }
        presence?.cancel()
        presence = nil
        presenceKey = wanted
        guard let accountId = wanted,
              let salt = LinkAccountHint.makeSalt(),
              let advert = LinkAccountHint.advert(accountId: accountId, linkedDeviceIds: [LinkPeerIdentity.localDeviceId()], salt: salt) else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            var entries = advert.entries
            entries[LinkAccountHint.nameKey] = String(LinkPeerIdentity.localName.prefix(LinkPeerIdentity.maximumNameLength))
            let suffix = salt.prefix(4).map { String(format: "%02x", $0) }.joined()
            listener.service = NWListener.Service(
                name: "\(BonjourConstants.nearbyServiceName)-\(suffix)",
                type: BonjourConstants.serviceType,
                txtRecord: NWTXTRecord(entries)
            )
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: .main)
            presence = listener
            Log.link.info("[SameAccountLink] advertising presence to same-account TVs")
        } catch {
            Log.link.error("[SameAccountLink] presence listener: \(String(describing: error), privacy: .public)")
        }
    }
}

extension LinkConfirmationHandshake {
    var instruction: String {
        switch state {
        case .awaitingComparison: return "Make sure this matches the code on \(claimedName)."
        case .confirming where isOwnerVerified: return "Linking \(claimedName)…"
        case .confirming:         return "On \(claimedName), choose Allow to finish."
        case .failed:             return "Couldn't reach \(claimedName). Make sure it's still showing its code."
        default:                  return "Connecting to \(claimedName)…"
        }
    }

    nonisolated static func codeGroups(_ code: String) -> [String] {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return [code] }
        let midpoint = digits.index(digits.startIndex, offsetBy: 3)
        return [String(digits[..<midpoint]), String(digits[midpoint...])]
    }
}
