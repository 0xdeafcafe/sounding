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

struct PeerContentRequestFrame: Codable, Equatable {
    let requestId: String
    let trackId: String
    let offset: Int64
    let length: Int64
}

struct PeerContentResponseFrame: Codable, Equatable {
    let requestId: String
    let status: PeerContentStatus
    let offset: Int64
    let length: Int64
    let totalLength: Int64
}

enum PeerContentError: Error, Equatable, Sendable {
    case notFound
    case notEntitled
    case ioError
    case malformedResponse
    case connectTimedOut
    case notConnected
    case transportFailed(String)
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

@MainActor
final class PeerContentServer {
    typealias FileResolver = (String) async -> URL?

    nonisolated static func defaultResolver(trackId: String) async -> URL? {
        await DownloadManager.shared.localFileURL(forTrackId: trackId)
    }

    private nonisolated(unsafe) var listener: NWListener?
    private var connections: [ObjectIdentifier: PeerContentServerConnection] = [:]
    private let resolveFile: FileResolver
    private(set) var advertisedServiceName: String?

    init(resolveFile: @escaping FileResolver = PeerContentServer.defaultResolver) {
        self.resolveFile = resolveFile
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
            type: BonjourConstants.serviceType
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
    private let onFinished: () -> Void
    private var reader = PeerContentFrameReader<PeerContentRequestFrame>()
    private var finished = false

    init(connection: NWConnection, resolveFile: @escaping PeerContentServer.FileResolver, onFinished: @escaping () -> Void) {
        self.connection = connection
        self.resolveFile = resolveFile
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
        guard let fileURL = await resolveFile(request.trackId) else {
            respond(requestId: request.requestId, status: .notFound, offset: request.offset, body: nil, totalLength: 0)
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            respond(requestId: request.requestId, status: .ioError, offset: request.offset, body: nil, totalLength: 0)
            return
        }
        defer { try? handle.close() }

        guard let totalLength = try? handle.seekToEnd() else {
            respond(requestId: request.requestId, status: .ioError, offset: request.offset, body: nil, totalLength: 0)
            return
        }
        let total = Int64(totalLength)
        let offset = max(0, request.offset)
        guard offset < total else {
            respond(requestId: request.requestId, status: .ok, offset: offset, body: Data(), totalLength: total)
            return
        }

        let remaining = total - offset
        let wanted = request.length < 0 ? remaining : min(remaining, request.length)
        do {
            try handle.seek(toOffset: UInt64(offset))
            let body = try handle.read(upToCount: Int(wanted)) ?? Data()
            respond(requestId: request.requestId, status: .ok, offset: offset, body: body, totalLength: total)
        } catch {
            respond(requestId: request.requestId, status: .ioError, offset: offset, body: nil, totalLength: total)
        }
    }

    private func respond(requestId: String, status: PeerContentStatus, offset: Int64, body: Data?, totalLength: Int64) {
        let header = PeerContentResponseFrame(
            requestId: requestId, status: status, offset: offset,
            length: Int64(body?.count ?? 0), totalLength: totalLength
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
    private var connection: NWConnection?
    private var reader = PeerContentFrameReader<PeerContentResponseFrame>()
    private var pending: [String: PendingRequest] = [:]
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var connectCompletion: (@Sendable (Result<Void, PeerContentError>) -> Void)?

    init(queue: DispatchQueue = DispatchQueue(label: "red.forbes.sounding.peercontent.client")) {
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
            let request = PeerContentRequestFrame(requestId: requestId, trackId: trackId, offset: offset, length: length)
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

private actor PeerContentFileSink {
    let url: URL
    private let handle: FileHandle

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    func finish() throws {
        try handle.synchronize()
        try handle.close()
    }

    func discard() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

enum PeerContentTransfer {
    static let chunkSize: Int64 = 1 << 20

    static func stage(
        trackId: String,
        endpoint: NWEndpoint,
        sessionId: String,
        secret: Data,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> URL {
        let client = PeerContentClient()
        try await client.connect(to: endpoint, sessionId: sessionId, secret: secret)
        defer { client.disconnect() }

        let probe = try await client.fetchRange(trackId: trackId, offset: 0, length: 0, timeout: 10)
        guard probe.totalLength > 0 else { throw PeerContentError.notFound }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeerDownload-\(UUID().uuidString)")
        let sink = try PeerContentFileSink(url: destination)
        do {
            var offset: Int64 = 0
            while offset < probe.totalLength {
                try Task.checkCancellation()
                let wanted = min(chunkSize, probe.totalLength - offset)
                let response = try await client.fetchRange(
                    trackId: trackId, offset: offset, length: wanted, timeout: 30
                )
                guard !response.data.isEmpty, response.totalLength == probe.totalLength else {
                    throw PeerContentError.malformedResponse
                }
                try await sink.append(response.data)
                offset += Int64(response.data.count)
                await progress(min(1, Double(offset) / Double(probe.totalLength)))
            }
            try await sink.finish()
            return destination
        } catch {
            await sink.discard()
            throw error
        }
    }
}
