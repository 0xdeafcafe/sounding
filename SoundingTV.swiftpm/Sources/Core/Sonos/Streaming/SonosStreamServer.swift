import Foundation
import Network
import Darwin
import Security
import Synchronization

final class SonosStreamServer: @unchecked Sendable {
    static let prerollSeconds: TimeInterval = 0.5
    static let maximumPendingBytes = 1 << 20
    static let requestLimit = 16 * 1024
    static let streamName = "Sounding"

    let format: SonosStreamFormat
    let sampleRate: Double
    let ringBuffer: SonosAudioRingBuffer
    let token: String
    private let requestedPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "red.forbes.sounding.sonos-stream", qos: .userInitiated)
    private let encoder: SonosStreamEncoder?
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var currentClient: ObjectIdentifier?
    private var preroll: [SonosEncodedPacket] = []
    private var title = SonosStreamServer.streamName
    private let served = Atomic<UInt64>(0)
    private let streamStart = Atomic<UInt64>(0)
    private let clientCount = Atomic<Int>(0)
    private let changeHandler = Mutex<(@Sendable (Int) -> Void)?>(nil)
    private let publishedURL = Mutex<URL?>(nil)

    init(format: SonosStreamFormat = .aacADTS, port: NWEndpoint.Port = .any, sampleRate: Double = 44_100, bufferSeconds: TimeInterval = 4) {
        self.format = format
        self.sampleRate = sampleRate
        requestedPort = port
        ringBuffer = SonosAudioRingBuffer(capacityFrames: Int(sampleRate * bufferSeconds), channels: 2)
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        encoder = try? SonosStreamEncoder(ring: ringBuffer, format: format, sampleRate: sampleRate, queue: queue)
        encoder?.onPackets = { [weak self] packets in self?.distribute(packets) }
    }

    deinit {
        listener?.cancel()
        encoder?.stop()
    }

    var path: String { "/sounding/\(token).\(format.fileExtension)" }

    var url: URL? { publishedURL.withLock { $0 } }

    var sonosURI: String? { url.map(format.sonosURI(for:)) }

    var framesServedToClient: UInt64 { served.load(ordering: .acquiring) }

    var clientStreamStartFrame: UInt64 { streamStart.load(ordering: .acquiring) }

    var producedFrame: UInt64 { encoder?.producedFrame ?? ringBuffer.framesWritten }

    var connectedClientCount: Int { clientCount.load(ordering: .acquiring) }

    var onClientChange: (@Sendable (Int) -> Void)? {
        get { changeHandler.withLock { $0 } }
        set { changeHandler.withLock { $0 = newValue } }
    }

    func setStreamTitle(_ title: String) {
        queue.async { [self] in
            self.title = title.isEmpty ? Self.streamName : title
        }
    }

    func start() async throws -> URL {
        guard let encoder else { throw SonosStreamError.encoderUnavailable }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: requestedPort)
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            let resumed = Atomic<Bool>(false)
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    guard !resumed.exchange(true, ordering: .acquiringAndReleasing) else { return }
                    if let port = listener?.port {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: SonosStreamError.listenerFailed("no port"))
                    }
                case .failed(let error):
                    guard !resumed.exchange(true, ordering: .acquiringAndReleasing) else { return }
                    continuation.resume(throwing: SonosStreamError.listenerFailed(error.localizedDescription))
                case .cancelled:
                    guard !resumed.exchange(true, ordering: .acquiringAndReleasing) else { return }
                    continuation.resume(throwing: SonosStreamError.alreadyStopped)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            queue.async { [self] in
                self.listener?.cancel()
                self.listener = listener
                listener.start(queue: queue)
            }
        }
        encoder.start()
        let host = Self.lanIPv4Address() ?? "127.0.0.1"
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port.rawValue)
        components.path = path
        guard let url = components.url else { throw SonosStreamError.listenerFailed("bad url") }
        publishedURL.withLock { $0 = url }
        return url
    }

    func stop() {
        encoder?.stop()
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for client in clients.values {
                client.connection.cancel()
            }
            let hadClients = !clients.isEmpty
            clients.removeAll()
            currentClient = nil
            preroll.removeAll()
            publishedURL.withLock { $0 = nil }
            if hadClients { publishCount() }
        }
    }

    // MARK: - Connections

    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var request = Data()
        var streaming = false
        var icy: SonosICYInterleaver?
        var pendingBytes = 0

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private func accept(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        let client = Client(connection: connection)
        let id = ObjectIdentifier(client)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.drop(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(client, id: id)
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak client] in
            guard let self, let client, !client.streaming, self.clients[id] != nil else { return }
            client.connection.cancel()
        }
    }

    private func receiveRequest(_ client: Client, id: ObjectIdentifier) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { client.request.append(data) }
            if let request = SonosHTTPRequest(client.request) {
                self.respond(to: request, client: client, id: id)
                return
            }
            if error != nil || isComplete || client.request.count > Self.requestLimit {
                if client.request.count > Self.requestLimit {
                    self.sendFinal(client, Self.simpleResponse(status: "400 Bad Request"))
                } else {
                    client.connection.cancel()
                }
                return
            }
            self.receiveRequest(client, id: id)
        }
    }

    private func watchForClose(_ client: Client, id: ObjectIdentifier) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                client.connection.cancel()
                self.drop(id)
                return
            }
            self.watchForClose(client, id: id)
        }
    }

    private func respond(to request: SonosHTTPRequest, client: Client, id: ObjectIdentifier) {
        guard request.path == path else {
            sendFinal(client, Self.simpleResponse(status: "404 Not Found"))
            return
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            sendFinal(client, Self.simpleResponse(status: "405 Method Not Allowed", extra: "Allow: GET, HEAD\r\n"))
            return
        }
        let header = streamHeader(icy: request.wantsICYMetadata)
        if request.method == "HEAD" {
            sendFinal(client, header)
            return
        }
        client.streaming = true
        if request.wantsICYMetadata {
            client.icy = SonosICYInterleaver()
        }
        send(header, to: client)
        let startFrame = preroll.first?.timelineFrame ?? encoder?.nextPacketFrame ?? 0
        currentClient = id
        streamStart.store(startFrame, ordering: .releasing)
        served.store(0, ordering: .releasing)
        if !preroll.isEmpty {
            send(packets: preroll, to: client, id: id)
        }
        watchForClose(client, id: id)
        publishCount()
    }

    private func distribute(_ packets: [SonosEncodedPacket]) {
        dispatchPrecondition(condition: .onQueue(queue))
        preroll.append(contentsOf: packets)
        let keep = Int((Self.prerollSeconds * sampleRate) / Double(format.framesPerPacket)) + 1
        if preroll.count > keep {
            preroll.removeFirst(preroll.count - keep)
        }
        for (id, client) in clients where client.streaming {
            send(packets: packets, to: client, id: id)
        }
    }

    private func send(packets: [SonosEncodedPacket], to client: Client, id: ObjectIdentifier) {
        var audio = Data(capacity: packets.reduce(0) { $0 + $1.bytes.count })
        for packet in packets {
            audio.append(packet.bytes)
        }
        var payload = audio
        if var icy = client.icy {
            payload = icy.interleave(audio, title: title)
            client.icy = icy
        }
        if id == currentClient {
            served.add(UInt64(packets.reduce(0) { $0 + $1.frames }), ordering: .releasing)
        }
        send(payload, to: client)
    }

    private func send(_ data: Data, to client: Client) {
        guard client.pendingBytes + data.count <= Self.maximumPendingBytes else {
            client.connection.cancel()
            return
        }
        client.pendingBytes += data.count
        let count = data.count
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let client else { return }
            client.pendingBytes -= count
            if error != nil {
                client.connection.cancel()
                self?.drop(ObjectIdentifier(client))
            }
        })
    }

    private func sendFinal(_ client: Client, _ data: Data) {
        client.connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            client.connection.cancel()
        })
    }

    private func drop(_ id: ObjectIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let client = clients.removeValue(forKey: id) else { return }
        if currentClient == id {
            currentClient = clients.first(where: { $0.value.streaming })?.key
        }
        if client.streaming { publishCount() }
    }

    private func publishCount() {
        let count = clients.values.filter(\.streaming).count
        clientCount.store(count, ordering: .releasing)
        onClientChange?(count)
    }

    // MARK: - HTTP

    private func streamHeader(icy: Bool) -> Data {
        var lines = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(format.mimeType)",
            "Cache-Control: no-cache, no-store",
            "Pragma: no-cache",
            "Accept-Ranges: none",
            "Connection: close",
            "Server: Sounding",
        ]
        if icy {
            lines.append("icy-metaint: \(SonosICYInterleaver.defaultMetaInterval)")
            lines.append("icy-name: \(Self.streamName)")
            lines.append("icy-br: \(format.bitRate / 1000)")
            lines.append("icy-sr: \(Int(sampleRate))")
            lines.append("icy-pub: 0")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    static func simpleResponse(status: String, extra: String = "") -> Data {
        let body = status.drop(while: { $0 != " " }).dropFirst()
        return Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n\(extra)Connection: close\r\n\r\n\(body)".utf8)
    }

    // MARK: - Addressing

    static func lanIPv4Addresses() -> [(interface: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [(interface: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !text.hasPrefix("169.254.") else { continue }
            found.append((name, text))
        }
        return found.sorted { lhs, rhs in
            if lhs.interface.hasPrefix("en") != rhs.interface.hasPrefix("en") { return lhs.interface.hasPrefix("en") }
            return lhs.interface.localizedStandardCompare(rhs.interface) == .orderedAscending
        }
    }

    static func lanIPv4Address() -> String? {
        lanIPv4Addresses().first?.address
    }
}

struct SonosHTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let headers: [String: String]

    var wantsICYMetadata: Bool { headers["icy-metadata"]?.trimmingCharacters(in: .whitespaces) == "1" }

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }
        method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        if let components = URLComponents(string: target), !components.path.isEmpty {
            path = components.path
        } else {
            path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        self.headers = headers
    }
}
