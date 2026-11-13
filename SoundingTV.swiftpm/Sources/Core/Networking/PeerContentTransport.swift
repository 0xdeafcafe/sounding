import Foundation
import Network
import CryptoKit

@MainActor
protocol PeerContentSessionProvider: AnyObject {
    var peerContentEndpoint: (endpoint: NWEndpoint, sessionId: String, secret: Data)? { get }
    func peerContentEndpoint(forDeviceId deviceId: String) -> (endpoint: NWEndpoint, sessionId: String, secret: Data)?
}

extension PeerContentSessionProvider {
    func peerContentEndpoint(forDeviceId deviceId: String) -> (endpoint: NWEndpoint, sessionId: String, secret: Data)? {
        peerContentEndpoint
    }
}

enum PeerContentStatus: String, Codable, Equatable {
    case ok
    case notFound
    case notEntitled
    case ioError
}

struct PeerContentAccountCredential: Sendable {
    let accountId: String
    fileprivate let proofKey: Data

    static func derive(accountId: String, accessToken: String) -> Self? {
        guard !accountId.isEmpty, !accessToken.isEmpty else { return nil }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(accessToken.utf8)),
            salt: Data(accountId.utf8),
            info: Data("SoundingTV-Peer-Account-Proof-v1".utf8),
            outputByteCount: 32
        )
        return Self(accountId: accountId, proofKey: key.withUnsafeBytes { Data($0) })
    }

    static let grantPrefix = "grant:"

    var isGrant: Bool { accountId.hasPrefix(Self.grantPrefix) }

    static func grant(id: String, key: Data) -> Self? {
        guard !id.isEmpty, key.count >= 16 else { return nil }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            salt: Data(id.utf8),
            info: Data("SoundingTV-Peer-Grant-Proof-v1".utf8),
            outputByteCount: 32
        )
        return Self(accountId: grantPrefix + id, proofKey: derived.withUnsafeBytes { Data($0) })
    }

    static func grantId(fromAccountId accountId: String) -> String? {
        guard accountId.hasPrefix(grantPrefix) else { return nil }
        let id = String(accountId.dropFirst(grantPrefix.count))
        return id.isEmpty ? nil : id
    }

    @MainActor
    static func current() -> Self? {
        guard let source = SoundCloudAPI.credentials,
              let accountId = source.currentUser?.id,
              let accessToken = source.accessToken else { return nil }
        return derive(accountId: accountId, accessToken: accessToken)
    }
}

struct PeerContentAccountProof: Codable, Equatable {
    static let maximumClockSkew: TimeInterval = 5 * 60

    let accountId: String
    let issuedAtMillis: Int64
    let authenticationCode: String

    static func make(
        requestId: String,
        trackId: String,
        offset: Int64,
        length: Int64,
        credential: PeerContentAccountCredential,
        now: Date = Date()
    ) -> Self {
        let issuedAtMillis = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let payload = requestPayload(
            requestId: requestId,
            accountId: credential.accountId,
            trackId: trackId,
            offset: offset,
            length: length,
            issuedAtMillis: issuedAtMillis
        )
        return Self(
            accountId: credential.accountId,
            issuedAtMillis: issuedAtMillis,
            authenticationCode: authenticate(payload, credential: credential)
        )
    }

    func isValid(
        requestId: String,
        trackId: String,
        offset: Int64,
        length: Int64,
        credential: PeerContentAccountCredential,
        now: Date = Date()
    ) -> Bool {
        guard accountId == credential.accountId,
              abs(Date(timeIntervalSince1970: Double(issuedAtMillis) / 1_000).timeIntervalSince(now))
                <= Self.maximumClockSkew else { return false }
        let payload = Self.requestPayload(
            requestId: requestId,
            accountId: accountId,
            trackId: trackId,
            offset: offset,
            length: length,
            issuedAtMillis: issuedAtMillis
        )
        return Self.verify(authenticationCode, payload: payload, credential: credential)
    }

    static func responseCode(
        requestId: String,
        status: PeerContentStatus,
        offset: Int64,
        length: Int64,
        totalLength: Int64,
        body: Data,
        credential: PeerContentAccountCredential
    ) -> String {
        authenticate(
            responsePayload(
                requestId: requestId,
                status: status,
                offset: offset,
                length: length,
                totalLength: totalLength,
                body: body
            ),
            credential: credential
        )
    }

    static func verifyResponse(
        _ authenticationCode: String,
        requestId: String,
        status: PeerContentStatus,
        offset: Int64,
        length: Int64,
        totalLength: Int64,
        body: Data,
        credential: PeerContentAccountCredential
    ) -> Bool {
        verify(
            authenticationCode,
            payload: responsePayload(
                requestId: requestId,
                status: status,
                offset: offset,
                length: length,
                totalLength: totalLength,
                body: body
            ),
            credential: credential
        )
    }

    private static func requestPayload(
        requestId: String,
        accountId: String,
        trackId: String,
        offset: Int64,
        length: Int64,
        issuedAtMillis: Int64
    ) -> Data {
        Data("request-v1\n\(requestId)\n\(accountId)\n\(trackId)\n\(offset)\n\(length)\n\(issuedAtMillis)".utf8)
    }

    private static func responsePayload(
        requestId: String,
        status: PeerContentStatus,
        offset: Int64,
        length: Int64,
        totalLength: Int64,
        body: Data
    ) -> Data {
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Data("response-v1\n\(requestId)\n\(status.rawValue)\n\(offset)\n\(length)\n\(totalLength)\n\(digest)".utf8)
    }

    private static func authenticate(_ payload: Data, credential: PeerContentAccountCredential) -> String {
        Data(HMAC<SHA256>.authenticationCode(
            for: payload,
            using: SymmetricKey(data: credential.proofKey)
        )).base64EncodedString()
    }

    private static func verify(
        _ authenticationCode: String,
        payload: Data,
        credential: PeerContentAccountCredential
    ) -> Bool {
        guard let code = Data(base64Encoded: authenticationCode) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            code,
            authenticating: payload,
            using: SymmetricKey(data: credential.proofKey)
        )
    }
}

struct PeerContentRequestFrame: Codable, Equatable {
    let requestId: String
    let trackId: String
    let offset: Int64
    let length: Int64
    let accountProof: PeerContentAccountProof
}

struct PeerContentResponseFrame: Codable, Equatable {
    let requestId: String
    let status: PeerContentStatus
    let offset: Int64
    let length: Int64
    let totalLength: Int64
    let accountAuthenticationCode: String
}

enum PeerContentError: Error, LocalizedError, Equatable, Sendable {
    case notFound
    case notEntitled
    case ioError
    case malformedResponse
    case connectTimedOut
    case notConnected
    case transportFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "The paired device does not have this track."
        case .notEntitled: return "The paired device could not prove it is using the same SoundCloud account."
        case .ioError: return "The paired device could not read this track."
        case .malformedResponse: return "The paired device returned an invalid content response."
        case .connectTimedOut: return "The paired device did not respond in time."
        case .notConnected: return "The paired device is not connected."
        case .transportFailed(let reason): return "The paired-device transfer failed: \(reason)"
        }
    }
}

enum PeerContentFraming {
    static let maxHeaderBytes = 1 << 16

    static func frame(_ payload: Data) -> Data {
        let length = UInt32(payload.count)
        var out = Data(capacity: payload.count + 4)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }
}

struct PeerContentFrameReader<Header: Decodable> {
    enum ReadError: Error, Equatable {
        case oversizedHeader(Int)
        case malformedHeader
    }

    private enum Phase {
        case header
        case body(Header, needed: Int)
    }

    private var buffer: [UInt8] = []
    private var phase = Phase.header

    mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    mutating func next(bodyLength: (Header) -> Int) throws -> (Header, Data)? {
        while true {
            switch phase {
            case .header:
                guard buffer.count >= 4 else { return nil }
                let length = (Int(buffer[0]) << 24) | (Int(buffer[1]) << 16)
                    | (Int(buffer[2]) << 8) | Int(buffer[3])
                guard length > 0, length <= PeerContentFraming.maxHeaderBytes else {
                    throw ReadError.oversizedHeader(length)
                }
                guard buffer.count >= 4 + length else { return nil }
                let headerData = Data(buffer[4..<(4 + length)])
                buffer.removeFirst(4 + length)
                guard let header = try? JSONDecoder().decode(Header.self, from: headerData) else {
                    throw ReadError.malformedHeader
                }
                let needed = max(0, bodyLength(header))
                if needed == 0 {
                    return (header, Data())
                }
                phase = .body(header, needed: needed)
            case .body(let header, let needed):
                guard buffer.count >= needed else { return nil }
                let body = Data(buffer[0..<needed])
                buffer.removeFirst(needed)
                phase = .header
                return (header, body)
            }
        }
    }
}

protocol PeerContentByteSource: AnyObject, Sendable {
    var length: Int64 { get }
    func read(offset: Int64, length: Int) throws -> Data
}

@MainActor
final class PeerContentServer {
    typealias FileResolver = (String) async -> (any PeerContentByteSource)?
    typealias AccountCredentialProvider = () -> PeerContentAccountCredential?
    typealias GrantCredentialProvider = (String) -> PeerContentAccountCredential?

    private nonisolated(unsafe) var listener: NWListener?
    private var connections: [ObjectIdentifier: PeerContentServerConnection] = [:]
    private let resolveFile: FileResolver
    private let accountCredential: AccountCredentialProvider
    private var grantCredential: GrantCredentialProvider = { _ in nil }
    private var resolveGrantedFile: FileResolver = { _ in nil }
    private(set) var advertisedServiceName: String?

    init(
        resolveFile: @escaping FileResolver,
        accountCredential: @escaping AccountCredentialProvider = { PeerContentAccountCredential.current() }
    ) {
        self.resolveFile = resolveFile
        self.accountCredential = accountCredential
    }

    func serveGrants(credential: @escaping GrantCredentialProvider, resolve: @escaping FileResolver) {
        grantCredential = credential
        resolveGrantedFile = resolve
    }

    deinit {
        cancelNetworkResources()
    }

    private nonisolated func cancelNetworkResources() {
        listener?.cancel()
    }

    func start(sessionId: String, secret: Data, deviceId: String? = nil) throws {
        stop()

        let parameters = LinkTLS.makeParameters(
            sessionId: sessionId, secret: secret, info: LinkTLS.contentPSKInfo
        )
        let newListener = try NWListener(using: parameters)
        let serviceName = Self.serviceName(sessionId: sessionId, deviceId: deviceId)
        newListener.service = NWListener.Service(
            name: serviceName,
            type: BuildFlavor.current.bonjourServiceType
        )
        newListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        newListener.start(queue: .main)
        listener = newListener
        advertisedServiceName = serviceName
    }

    var boundPort: NWEndpoint.Port? { listener?.port }

    func stop() {
        listener?.cancel()
        listener = nil
        advertisedServiceName = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let handler = PeerContentServerConnection(
            connection: connection,
            resolveFile: resolveFile,
            accountCredential: accountCredential,
            grantCredential: grantCredential,
            resolveGrantedFile: resolveGrantedFile,
            onFinished: { [weak self] in
                Task { @MainActor in self?.connections[id] = nil }
            }
        )
        connections[id] = handler
        handler.start()
    }

    nonisolated static func serviceToken(for deviceId: String) -> String {
        SHA256.hash(data: Data(deviceId.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func serviceName(sessionId: String, deviceId: String?) -> String {
        let base = "\(BonjourConstants.contentServiceName)-\(sessionId.prefix(8))"
        guard let deviceId, !deviceId.isEmpty else { return base }
        return "\(base)-\(serviceToken(for: deviceId))"
    }

    nonisolated static func serviceToken(fromServiceName name: String, sessionId: String) -> String? {
        let prefix = "\(BonjourConstants.contentServiceName)-\(sessionId.prefix(8))-"
        guard name.hasPrefix(prefix) else { return nil }
        let token = String(name.dropFirst(prefix.count))
        return token.isEmpty ? nil : token
    }
}

@MainActor
private final class PeerContentServerConnection {
    private let connection: NWConnection
    private let resolveFile: PeerContentServer.FileResolver
    private let accountCredential: PeerContentServer.AccountCredentialProvider
    private let grantCredential: PeerContentServer.GrantCredentialProvider
    private let resolveGrantedFile: PeerContentServer.FileResolver
    private let onFinished: () -> Void
    private var reader = PeerContentFrameReader<PeerContentRequestFrame>()
    private var finished = false
    private var acceptedRequestIds = Set<String>()
    private var acceptedRequestOrder = [String]()
    private static let maxResponseLength: Int64 = 2 << 20

    init(
        connection: NWConnection,
        resolveFile: @escaping PeerContentServer.FileResolver,
        accountCredential: @escaping PeerContentServer.AccountCredentialProvider,
        grantCredential: @escaping PeerContentServer.GrantCredentialProvider,
        resolveGrantedFile: @escaping PeerContentServer.FileResolver,
        onFinished: @escaping () -> Void
    ) {
        self.connection = connection
        self.grantCredential = grantCredential
        self.resolveGrantedFile = resolveGrantedFile
        self.resolveFile = resolveFile
        self.accountCredential = accountCredential
        self.onFinished = onFinished
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleState(state) }
        }
        connection.start(queue: .main)
        receive()
    }

    func cancel() {
        connection.cancel()
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            finish()
        default:
            break
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil {
                    self.finish()
                    return
                }
                if let data, !data.isEmpty {
                    self.reader.append(data)
                    await self.drain()
                }
                if isComplete {
                    self.connection.cancel()
                    self.finish()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func drain() async {
        while true {
            let next: (PeerContentRequestFrame, Data)?
            do {
                next = try reader.next { _ in 0 }
            } catch {
                connection.cancel()
                finish()
                return
            }
            guard let (request, _) = next else { return }
            await handle(request)
        }
    }

    private func handle(_ request: PeerContentRequestFrame) async {
        let claimsGrant = request.accountProof.accountId.hasPrefix(PeerContentAccountCredential.grantPrefix)
        let grantId = PeerContentAccountCredential.grantId(fromAccountId: request.accountProof.accountId)
        let credential = claimsGrant ? grantId.flatMap(grantCredential) : accountCredential()
        let resolve = claimsGrant ? resolveGrantedFile : resolveFile
        guard let credential,
              request.accountProof.isValid(
                requestId: request.requestId,
                trackId: request.trackId,
                offset: request.offset,
                length: request.length,
                credential: credential
              ),
              acceptOnce(request.requestId) else {
            respond(
                requestId: request.requestId, status: .notEntitled,
                offset: request.offset, body: nil, totalLength: 0,
                credential: credential
            )
            return
        }

        guard let source = await resolve(request.trackId) else {
            respond(requestId: request.requestId, status: .notFound, offset: request.offset, body: nil, totalLength: 0, credential: credential)
            return
        }

        let total = source.length
        let offset = max(0, request.offset)
        guard offset < total else {
            respond(requestId: request.requestId, status: .ok, offset: offset, body: Data(), totalLength: total, credential: credential)
            return
        }

        let remaining = total - offset
        let wanted = min(Self.maxResponseLength, request.length < 0 ? remaining : min(remaining, request.length))
        do {
            let body = try await Task.detached(priority: .userInitiated) {
                try source.read(offset: offset, length: Int(wanted))
            }.value
            respond(requestId: request.requestId, status: .ok, offset: offset, body: body, totalLength: total, credential: credential)
        } catch {
            respond(requestId: request.requestId, status: .ioError, offset: offset, body: nil, totalLength: total, credential: credential)
        }
    }

    private func acceptOnce(_ requestId: String) -> Bool {
        guard acceptedRequestIds.insert(requestId).inserted else { return false }
        acceptedRequestOrder.append(requestId)
        if acceptedRequestOrder.count > 2_048 {
            acceptedRequestIds.remove(acceptedRequestOrder.removeFirst())
        }
        return true
    }

    private func respond(
        requestId: String,
        status: PeerContentStatus,
        offset: Int64,
        body: Data?,
        totalLength: Int64,
        credential: PeerContentAccountCredential?
    ) {
        let responseBody = body ?? Data()
        let length = Int64(responseBody.count)
        let accountCode = credential.map {
            PeerContentAccountProof.responseCode(
                requestId: requestId, status: status, offset: offset,
                length: length, totalLength: totalLength, body: responseBody,
                credential: $0
            )
        } ?? ""
        let header = PeerContentResponseFrame(
            requestId: requestId, status: status, offset: offset,
            length: length, totalLength: totalLength,
            accountAuthenticationCode: accountCode
        )
        guard let headerData = try? JSONEncoder().encode(header) else { return }
        var out = PeerContentFraming.frame(headerData)
        if let body { out.append(body) }
        connection.send(content: out, completion: .contentProcessed { _ in })
    }
}

final class PeerContentClient: @unchecked Sendable {
    private struct PendingRequest {
        let completion: @Sendable (Result<(data: Data, totalLength: Int64), PeerContentError>) -> Void
        let timeoutWorkItem: DispatchWorkItem?
    }

    private let queue: DispatchQueue
    private let accountCredential: PeerContentAccountCredential
    private var connection: NWConnection?
    private var reader = PeerContentFrameReader<PeerContentResponseFrame>()
    private var pending: [String: PendingRequest] = [:]
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var connectCompletion: (@Sendable (Result<Void, PeerContentError>) -> Void)?

    init(
        accountCredential: PeerContentAccountCredential,
        queue: DispatchQueue = DispatchQueue(label: "red.forbes.sounding.peercontent.client")
    ) {
        self.accountCredential = accountCredential
        self.queue = queue
    }

    deinit {
        connection?.cancel()
    }

    func connect(
        to endpoint: NWEndpoint,
        sessionId: String,
        secret: Data,
        timeout: TimeInterval = 15,
        completion: @escaping @Sendable (Result<Void, PeerContentError>) -> Void
    ) {
        queue.async { [self] in
            teardown()
            connectCompletion = completion

            let parameters = LinkTLS.makeParameters(
                sessionId: sessionId, secret: secret, info: LinkTLS.contentPSKInfo
            )
            let newConnection = NWConnection(to: endpoint, using: parameters)
            connection = newConnection
            reader = PeerContentFrameReader<PeerContentResponseFrame>()

            newConnection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async { [self] in handleState(state, for: newConnection) }
            }
            newConnection.start(queue: queue)
            receive(on: newConnection)

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.connection === newConnection, self.connectCompletion != nil else { return }
                newConnection.cancel()
                self.finishConnect(.failure(.connectTimedOut))
            }
            connectTimeoutWorkItem = work
            queue.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    func disconnect() {
        queue.async { [self] in teardown() }
    }

    private func teardown() {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        connection?.cancel()
        connection = nil
        failAllPending(.notConnected)
        finishConnect(.failure(.notConnected))
    }

    private func handleState(_ state: NWConnection.State, for source: NWConnection) {
        guard source === connection else { return }
        switch state {
        case .ready:
            finishConnect(.success(()))
        case .failed(let error):
            let reason = PeerContentError.transportFailed(error.localizedDescription)
            finishConnect(.failure(reason))
            failAllPending(reason)
            connection = nil
        case .cancelled:
            failAllPending(.transportFailed("cancelled"))
            connection = nil
        default:
            break
        }
    }

    private func finishConnect(_ result: Result<Void, PeerContentError>) {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        guard let completion = connectCompletion else { return }
        connectCompletion = nil
        completion(result)
    }

    func fetchRange(
        trackId: String,
        offset: Int64,
        length: Int64,
        timeout: TimeInterval? = nil,
        completion: @escaping @Sendable (Result<(data: Data, totalLength: Int64), PeerContentError>) -> Void
    ) {
        queue.async { [self] in
            guard let connection else {
                completion(.failure(.notConnected))
                return
            }
            let requestId = UUID().uuidString
            let proof = PeerContentAccountProof.make(
                requestId: requestId,
                trackId: trackId,
                offset: offset,
                length: length,
                credential: accountCredential
            )
            let request = PeerContentRequestFrame(
                requestId: requestId, trackId: trackId, offset: offset,
                length: length, accountProof: proof
            )
            guard let payload = try? JSONEncoder().encode(request) else {
                completion(.failure(.malformedResponse))
                return
            }
            let timeoutWorkItem = timeout.map { timeout in
                DispatchWorkItem { [weak self] in
                    guard let self, let request = self.pending.removeValue(forKey: requestId) else { return }
                    request.completion(.failure(.transportFailed("request timed out")))
                }
            }
            pending[requestId] = PendingRequest(completion: completion, timeoutWorkItem: timeoutWorkItem)
            if let timeoutWorkItem, let timeout {
                queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
            }
            connection.send(content: PeerContentFraming.frame(payload), completion: .contentProcessed { _ in })
        }
    }

    private func receive(on source: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async { [self] in
                guard source === connection else { return }
                if let error {
                    failAllPending(.transportFailed(error.localizedDescription))
                    return
                }
                if let data, !data.isEmpty {
                    reader.append(data)
                    drain()
                }
                if isComplete {
                    source.cancel()
                    connection = nil
                    failAllPending(.transportFailed("peer closed the connection"))
                } else {
                    receive(on: source)
                }
            }
        }
    }

    private func drain() {
        while true {
            let next: (PeerContentResponseFrame, Data)?
            do {
                next = try reader.next { header in header.status == .ok ? Int(header.length) : 0 }
            } catch {
                failAllPending(.malformedResponse)
                return
            }
            guard let (header, body) = next else { return }
            guard let request = pending.removeValue(forKey: header.requestId) else { continue }
            request.timeoutWorkItem?.cancel()
            guard PeerContentAccountProof.verifyResponse(
                header.accountAuthenticationCode,
                requestId: header.requestId,
                status: header.status,
                offset: header.offset,
                length: header.length,
                totalLength: header.totalLength,
                body: body,
                credential: accountCredential
            ) else {
                request.completion(.failure(.notEntitled))
                continue
            }
            switch header.status {
            case .ok: request.completion(.success((body, header.totalLength)))
            case .notFound: request.completion(.failure(.notFound))
            case .notEntitled: request.completion(.failure(.notEntitled))
            case .ioError: request.completion(.failure(.ioError))
            }
        }
    }

    private func failAllPending(_ error: PeerContentError) {
        let all = pending
        pending.removeAll()
        for request in all.values {
            request.timeoutWorkItem?.cancel()
            request.completion(.failure(error))
        }
    }
}

extension PeerContentClient {
    func connect(to endpoint: NWEndpoint, sessionId: String, secret: Data, timeout: TimeInterval = 15) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connect(to: endpoint, sessionId: sessionId, secret: secret, timeout: timeout) { result in
                continuation.resume(with: result)
            }
        }
    }

    func fetchRange(trackId: String, offset: Int64, length: Int64, timeout: TimeInterval? = nil) async throws -> (data: Data, totalLength: Int64) {
        try await withCheckedThrowingContinuation { continuation in
            fetchRange(trackId: trackId, offset: offset, length: length, timeout: timeout) { result in
                continuation.resume(with: result)
            }
        }
    }
}
