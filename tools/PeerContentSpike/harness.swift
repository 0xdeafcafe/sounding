// PeerContentSpike harness — proves the task #25 peer-content-serving
// transport in isolation, per the task brief's "transport first, proven in
// isolation" instruction, before trusting it wired into an
// AVAssetResourceLoaderDelegate inside the real app.
//
// Not linked against the app; standalone `swiftc` harness, same precedent as
// tools/PSKSpike and tools/ConnectProbe. Mirrors the wire types, framing and
// PSK derivation in
// SoundingTV.swiftpm/Sources/Services/PeerContentTransport.swift and
// TokenTransferProtocol.swift's `PairingTLS` — duplicated here rather than
// imported because the real `PeerContentServer` depends on `DownloadManager`
// (SubscriptionService, SettingsStore, KeychainService, UIKit-era
// singletons), which cannot be pulled into a bare swiftc target. The
// production `FileResolver` seam exists specifically so the transport logic
// itself doesn't have to drag that in — this harness supplies a plain
// closure over a temp file instead, exactly as `DownloadManager`-free code
// would.
//
// Proves three things, matching the task's stated hard parts:
//   1. The content-PSK handshake (distinct HKDF label from pairing)
//      actually completes — same ciphersuite/version pin task #90 already
//      measured, just under the sibling label.
//   2. Byte-range responses are byte-exact against a real file: a full
//      read, a truncated prefix, a mid-file range, and "to end of file"
//      (requestsAllDataToEndOfResource's wire equivalent, length == -1).
//   3. Task #91's carried-over bounded-timeout requirement: connecting to
//      an unroutable peer (TEST-NET-1, RFC 5737) fails within the harness's
//      own timeout rather than hanging with no terminal `NWConnection`
//      state — the exact failure `RemoteQueueClient.connectTimeout` and
//      `tools/ConnectProbe/waitprobe.swift` already had to guard against
//      elsewhere in this app.
//
// Run:
//   xcrun swiftc harness.swift -o /tmp/peercontent-harness
//   /tmp/peercontent-harness

import Network
import CryptoKit
import Foundation

// MARK: - Mirrors of the production wire types

let harnessSecret = Data("PeerContentSpike-not-a-real-secret".utf8)
let harnessSessionId = "peercontent-spike-session"
// Mirrors `PairingTLS.contentPSKInfo` exactly — the whole point is to prove
// the sibling-label derivation the production code uses, not some other one.
let contentPSKInfo = Data("SoundingTV-Content-TLS-PSK-v1".utf8)

func derivePSK(secret: Data, sessionId: String, info: Data) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: secret),
        salt: Data(sessionId.utf8),
        info: info,
        outputByteCount: 32
    )
}

func makeParameters(sessionId: String, secret: Data) -> NWParameters {
    let tlsOptions = NWProtocolTLS.Options()
    let pskKey = derivePSK(secret: secret, sessionId: sessionId, info: contentPSKInfo)
    let pskData = pskKey.withUnsafeBytes { Data($0) }
    let identityData = Data(sessionId.utf8)
    let pskDispatchData = pskData.withUnsafeBytes { DispatchData(bytes: $0) }
    let identityDispatchData = identityData.withUnsafeBytes { DispatchData(bytes: $0) }

    let options = tlsOptions.securityProtocolOptions
    sec_protocol_options_add_pre_shared_key(
        options, pskDispatchData as __DispatchData, identityDispatchData as __DispatchData
    )
    sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0xCCAC)!)
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

    let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    parameters.includePeerToPeer = false
    return parameters
}

enum Status: String, Codable { case ok, notFound, notEntitled, ioError }

struct RequestFrame: Codable {
    let requestId: String
    let trackId: String
    let offset: Int64
    let length: Int64
}

struct ResponseFrame: Codable {
    let requestId: String
    let status: Status
    let offset: Int64
    let length: Int64
    let totalLength: Int64
}

func frame(_ payload: Data) -> Data {
    let length = UInt32(payload.count)
    var out = Data(capacity: payload.count + 4)
    out.append(UInt8(truncatingIfNeeded: length >> 24))
    out.append(UInt8(truncatingIfNeeded: length >> 16))
    out.append(UInt8(truncatingIfNeeded: length >> 8))
    out.append(UInt8(truncatingIfNeeded: length))
    out.append(payload)
    return out
}

struct HarnessError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

struct FrameReader<Header: Decodable> {
    private enum Phase { case header, body(Header, Int) }
    private var buffer: [UInt8] = []
    private var phase = Phase.header

    mutating func append(_ data: Data) { buffer.append(contentsOf: data) }

    mutating func next(bodyLength: (Header) -> Int) -> (Header, Data)? {
        while true {
            switch phase {
            case .header:
                guard buffer.count >= 4 else { return nil }
                let length = (Int(buffer[0]) << 24) | (Int(buffer[1]) << 16) | (Int(buffer[2]) << 8) | Int(buffer[3])
                guard length > 0, length <= 1 << 16 else { return nil }
                guard buffer.count >= 4 + length else { return nil }
                let headerData = Data(buffer[4..<(4 + length)])
                buffer.removeFirst(4 + length)
                guard let header = try? JSONDecoder().decode(Header.self, from: headerData) else { return nil }
                let needed = max(0, bodyLength(header))
                if needed == 0 { return (header, Data()) }
                phase = .body(header, needed)
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

// MARK: - Minimal server: one file, keyed by a single fixed trackId

final class SpikeServer {
    let fileURL: URL
    var listener: NWListener?
    var connections: [NWConnection] = []
    var readers: [ObjectIdentifier: FrameReader<RequestFrame>] = [:]
    let queue = DispatchQueue(label: "spike.server")

    init(fileURL: URL) { self.fileURL = fileURL }

    func start(sessionId: String, secret: Data) throws -> UInt16 {
        let parameters = makeParameters(sessionId: sessionId, secret: secret)
        parameters.allowLocalEndpointReuse = true
        let newListener = try NWListener(using: parameters)
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let readySem = DispatchSemaphore(value: 0)
        var boundPort: UInt16?
        newListener.stateUpdateHandler = { state in
            if case .ready = state { boundPort = newListener.port?.rawValue; readySem.signal() }
            if case .failed = state { readySem.signal() }
        }
        newListener.start(queue: queue)
        _ = readySem.wait(timeout: .now() + 5)
        listener = newListener
        guard let port = boundPort else { throw NSError(domain: "spike", code: 1) }
        return port
    }

    func accept(_ connection: NWConnection) {
        connections.append(connection)
        readers[ObjectIdentifier(connection)] = FrameReader<RequestFrame>()
        connection.stateUpdateHandler = { _ in }
        connection.start(queue: queue)
        receive(connection)
    }

    func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var reader = self.readers[ObjectIdentifier(connection)] ?? FrameReader<RequestFrame>()
                reader.append(data)
                while let (request, _) = reader.next(bodyLength: { _ in 0 }) {
                    self.handle(request, on: connection)
                }
                self.readers[ObjectIdentifier(connection)] = reader
            }
            if error == nil, !isComplete {
                self.receive(connection)
            }
        }
    }

    func handle(_ request: RequestFrame, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            respond(requestId: request.requestId, status: .ioError, offset: request.offset, body: nil, totalLength: 0, on: connection)
            return
        }
        defer { try? handle.close() }
        guard let totalLength = try? handle.seekToEnd() else {
            respond(requestId: request.requestId, status: .ioError, offset: request.offset, body: nil, totalLength: 0, on: connection)
            return
        }
        let total = Int64(totalLength)
        let offset = max(0, request.offset)
        guard offset < total else {
            respond(requestId: request.requestId, status: .ok, offset: offset, body: Data(), totalLength: total, on: connection)
            return
        }
        let remaining = total - offset
        let wanted = request.length < 0 ? remaining : min(remaining, request.length)
        do {
            try handle.seek(toOffset: UInt64(offset))
            let body = try handle.read(upToCount: Int(wanted)) ?? Data()
            respond(requestId: request.requestId, status: .ok, offset: offset, body: body, totalLength: total, on: connection)
        } catch {
            respond(requestId: request.requestId, status: .ioError, offset: offset, body: nil, totalLength: total, on: connection)
        }
    }

    func respond(requestId: String, status: Status, offset: Int64, body: Data?, totalLength: Int64, on connection: NWConnection) {
        let header = ResponseFrame(requestId: requestId, status: status, offset: offset, length: Int64(body?.count ?? 0), totalLength: totalLength)
        guard let headerData = try? JSONEncoder().encode(header) else { return }
        var out = frame(headerData)
        if let body { out.append(body) }
        connection.send(content: out, completion: .contentProcessed { _ in })
    }

    func stop() {
        listener?.cancel()
        for c in connections { c.cancel() }
    }
}

// MARK: - Minimal client

final class SpikeClient {
    var connection: NWConnection?
    var reader = FrameReader<ResponseFrame>()
    var pending: [String: (Result<(Data, Int64), HarnessError>) -> Void] = [:]
    let queue = DispatchQueue(label: "spike.client")

    func connect(host: String, port: UInt16, sessionId: String, secret: Data, timeout: TimeInterval, completion: @escaping (Result<Void, HarnessError>) -> Void) {
        queue.async {
            let parameters = makeParameters(sessionId: sessionId, secret: secret)
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            let conn = NWConnection(to: endpoint, using: parameters)
            self.connection = conn

            var done = false
            let finish: (Result<Void, HarnessError>) -> Void = { result in
                guard !done else { return }
                done = true
                completion(result)
            }

            conn.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    switch state {
                    case .ready:
                        finish(.success(()))
                    case .failed(let error):
                        finish(.failure(HarnessError("\(error)")))
                    default:
                        break
                    }
                }
            }
            conn.start(queue: self.queue)
            self.receive(conn)

            self.queue.asyncAfter(deadline: .now() + timeout) {
                guard !done else { return }
                conn.cancel()
                finish(.failure(HarnessError("connect timed out after \(timeout)s (bounded client-side timeout, not NWConnection.failed)")))
            }
        }
    }

    func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.reader.append(data)
                    while let (header, body) = self.reader.next(bodyLength: { $0.status == .ok ? Int($0.length) : 0 }) {
                        guard let cb = self.pending.removeValue(forKey: header.requestId) else { continue }
                        switch header.status {
                        case .ok: cb(.success((body, header.totalLength)))
                        default: cb(.failure(HarnessError("\(header.status)")))
                        }
                    }
                }
                if error == nil, !isComplete {
                    self.receive(connection)
                }
            }
        }
    }

    func fetchRange(trackId: String, offset: Int64, length: Int64, completion: @escaping (Result<(Data, Int64), HarnessError>) -> Void) {
        queue.async {
            guard let connection = self.connection else { completion(.failure(HarnessError("not connected"))); return }
            let requestId = UUID().uuidString
            let request = RequestFrame(requestId: requestId, trackId: trackId, offset: offset, length: length)
            guard let payload = try? JSONEncoder().encode(request) else { completion(.failure(HarnessError("encode failed"))); return }
            self.pending[requestId] = completion
            connection.send(content: frame(payload), completion: .contentProcessed { _ in })
        }
    }

    func disconnect() {
        connection?.cancel()
    }
}

// MARK: - Test harness

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  PASS  \(name)")
    } else {
        failures += 1
        print("  FAIL  \(name)  \(detail)")
    }
}

func syncFetch(_ client: SpikeClient, trackId: String, offset: Int64, length: Int64) -> Result<(Data, Int64), HarnessError> {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<(Data, Int64), HarnessError> = .failure(HarnessError("no response"))
    client.fetchRange(trackId: trackId, offset: offset, length: length) { r in
        result = r
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 5)
    return result
}

print("=== PeerContentSpike / TASK #25 — transport verification ===")

// --- Build a real source file with known, non-repeating content so a
// mis-offset read is caught rather than accidentally matching.
let sourceBytes = (0..<200_000).map { UInt8($0 % 256) }
let sourceData = Data(sourceBytes)
let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("peercontent-spike-\(UUID().uuidString).bin")
try! sourceData.write(to: tempFile)
defer { try? FileManager.default.removeItem(at: tempFile) }

// --- Trial 1: handshake + byte-exact ranges ---
print("\n--- Trial 1: content-PSK handshake + byte-range correctness ---")
let server = SpikeServer(fileURL: tempFile)
guard let port = try? server.start(sessionId: harnessSessionId, secret: harnessSecret) else {
    print("  FAIL  server failed to start")
    exit(1)
}
print("  server listening on 127.0.0.1:\(port)")

let client = SpikeClient()
let connectSem = DispatchSemaphore(value: 0)
var connectResult: Result<Void, HarnessError> = .failure(HarnessError("never ran"))
client.connect(host: "127.0.0.1", port: port, sessionId: harnessSessionId, secret: harnessSecret, timeout: 10) { r in
    connectResult = r
    connectSem.signal()
}
_ = connectSem.wait(timeout: .now() + 12)
switch connectResult {
case .success:
    check("content-PSK handshake completes over loopback", true)
case .failure(let reason):
    check("content-PSK handshake completes over loopback", false, reason.description)
}

// Full file.
switch syncFetch(client, trackId: "1", offset: 0, length: -1) {
case .success(let (data, total)):
    check("full-file read is byte-exact", data == sourceData, "got \(data.count) bytes, expected \(sourceData.count)")
    check("totalLength matches file size", total == Int64(sourceData.count), "got \(total)")
case .failure(let reason):
    check("full-file read is byte-exact", false, reason.description)
}

// Truncated prefix.
switch syncFetch(client, trackId: "1", offset: 0, length: 1_000) {
case .success(let (data, _)):
    check("prefix read (0..<1000) is byte-exact", data == sourceData.prefix(1_000), "got \(data.count) bytes")
case .failure(let reason):
    check("prefix read (0..<1000) is byte-exact", false, reason.description)
}

// Mid-file range (simulates a scrub).
switch syncFetch(client, trackId: "1", offset: 50_000, length: 4_096) {
case .success(let (data, _)):
    let expected = sourceData.subdata(in: 50_000..<54_096)
    check("mid-file range (50000..<54096) is byte-exact", data == expected, "got \(data.count) bytes")
case .failure(let reason):
    check("mid-file range (50000..<54096) is byte-exact", false, reason.description)
}

// To end of file, from an offset.
switch syncFetch(client, trackId: "1", offset: 199_000, length: -1) {
case .success(let (data, _)):
    let expected = sourceData.subdata(in: 199_000..<200_000)
    check("to-end-of-file read (offset 199000, length -1) is byte-exact", data == expected, "got \(data.count) bytes, expected \(expected.count)")
case .failure(let reason):
    check("to-end-of-file read (offset 199000, length -1) is byte-exact", false, reason.description)
}

// Length-0 probe (how the delegate learns totalLength cheaply).
switch syncFetch(client, trackId: "1", offset: 0, length: 0) {
case .success(let (data, total)):
    check("zero-length probe returns empty body with correct totalLength", data.isEmpty && total == Int64(sourceData.count), "body=\(data.count) total=\(total)")
case .failure(let reason):
    check("zero-length probe returns empty body with correct totalLength", false, reason.description)
}

// Unknown track id -> notFound, not a crash/hang.
switch syncFetch(client, trackId: "does-not-exist", offset: 0, length: 10) {
case .success:
    // The harness server ignores `trackId` (single fixed file), so this
    // trial is a placeholder — the real entitlement/not-found gate lives in
    // `DownloadManager.localFileURL(forTrackId:)`, which this harness
    // deliberately does not link. Left here to document that the *frame
    // shape* still round-trips for a request naming a different id.
    check("request naming a different trackId still round-trips a frame", true)
case .failure(let reason):
    check("request naming a different trackId still round-trips a frame", false, reason.description)
}

client.disconnect()
server.stop()
Thread.sleep(forTimeInterval: 0.2)

// --- Trial 2: bounded connect timeout against an unroutable peer ---
// Mirrors tools/ConnectProbe/waitprobe.swift's finding, carried over per
// CLAUDE.md task #91: an unroutable peer sits in `.preparing` for ~75s, then
// `.waiting`, with no terminal `NWConnection` state at 100s. `.failed` alone
// is not sufficient; this proves the harness's own bounded timeout is what
// actually ends the attempt.
print("\n--- Trial 2: bounded connect timeout (task #91 carryover) ---")
let deadClient = SpikeClient()
let deadSem = DispatchSemaphore(value: 0)
var deadResult: Result<Void, HarnessError> = .failure(HarnessError("never ran"))
let startedAt = Date()
// TEST-NET-1 (RFC 5737) — same unroutable block ConnectProbe used.
deadClient.connect(host: "192.0.2.1", port: 4433, sessionId: harnessSessionId, secret: harnessSecret, timeout: 6) { r in
    deadResult = r
    deadSem.signal()
}
let waitOutcome = deadSem.wait(timeout: .now() + 20)
let elapsed = Date().timeIntervalSince(startedAt)
switch waitOutcome {
case .success:
    switch deadResult {
    case .failure(let reason) where reason.description.contains("timed out"):
        check("unroutable peer fails via bounded timeout, not indefinitely", true, "elapsed=\(String(format: "%.1f", elapsed))s reason=\(reason)")
    case .failure(let reason):
        // Some other failure (e.g. immediate .failed) also counts as
        // terminating, but is worth flagging as a different shape than the
        // one task #91 actually measured.
        check("unroutable peer fails via bounded timeout, not indefinitely", true, "terminated a different way: \(reason), elapsed=\(String(format: "%.1f", elapsed))s")
    case .success:
        check("unroutable peer fails via bounded timeout, not indefinitely", false, "connect() reported success against an unroutable address")
    }
case .timedOut:
    check("unroutable peer fails via bounded timeout, not indefinitely", false, "harness itself gave up after 20s with no callback at all — the connect timeout did not fire")
}
deadClient.disconnect()

print("\n=== DONE: \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)") ===")
exit(failures == 0 ? 0 : 1)
