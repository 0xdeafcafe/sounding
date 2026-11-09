#if DEBUG
import Foundation
import Darwin

struct SoundCloudLedgerEntry: Codable, Sendable {
    let t: Double
    let method: String
    let host: String
    let endpoint: String
    let url: String
    let lane: String
    let intent: String
    let caller: String
    let outcome: String
    let status: Int?
}

final class SoundCloudRequestLedger: @unchecked Sendable {
    static let shared = SoundCloudRequestLedger()

    let isEnabled: Bool
    private let lock = NSLock()
    private let started = Date()
    private var entries: [SoundCloudLedgerEntry] = []
    private var handle: FileHandle?
    private let echoes: Bool
    private var reporter: Task<Void, Never>?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isEnabled = environment["SOUNDING_TV_TRAFFIC_LEDGER"] == "1"
            || environment["SOUNDING_TV_SC_MOCK"] == "1"
        echoes = environment["SOUNDING_TV_TRAFFIC_ECHO"] != "0"
        guard isEnabled else { return }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let file = caches.appendingPathComponent("sounding-traffic.jsonl")
            try? FileManager.default.removeItem(at: file)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            handle = try? FileHandle(forWritingTo: file)
            print("[SCTraffic] ledger file \(file.path)")
        }
        let reportAfter = environment["SOUNDING_TV_TRAFFIC_REPORT_AFTER"].flatMap(Double.init)
        let exits = environment["SOUNDING_TV_TRAFFIC_EXIT"] == "1"
        reporter = Task.detached(priority: .utility) { [weak self] in
            var elapsed: Double = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                elapsed += 60
                guard let self else { return }
                print(self.summary(title: "minute \(Int(elapsed / 60))"))
                if let reportAfter, elapsed >= reportAfter {
                    print(self.summary(title: "final", detailed: true))
                    fflush(stdout)
                    if exits { exit(0) }
                    return
                }
            }
        }
    }

    var elapsed: Double { Date().timeIntervalSince(started) }

    func record(
        _ request: URLRequest,
        lane: String,
        intent: String,
        outcome: String,
        status: Int? = nil,
        caller: String? = nil,
        startedAt: Double? = nil
    ) {
        guard isEnabled, let url = request.url else { return }
        let entry = SoundCloudLedgerEntry(
            t: startedAt ?? elapsed,
            method: request.httpMethod?.uppercased() ?? "GET",
            host: url.host ?? "",
            endpoint: SoundCloudEndpoint.template(for: url),
            url: SoundCloudEndpoint.redacted(url),
            lane: lane,
            intent: intent,
            caller: caller ?? "unknown",
            outcome: outcome,
            status: status
        )
        lock.lock()
        entries.append(entry)
        if let data = try? JSONEncoder().encode(entry) {
            handle?.write(data + Data("\n".utf8))
        }
        lock.unlock()
        if echoes {
            print(String(
                format: "[SCTraffic] %7.2fs %@ %@ %@ %@/%@ %@ %@",
                entry.t, entry.outcome, entry.method, entry.endpoint, entry.intent, entry.lane,
                entry.status.map(String.init) ?? "-", entry.caller
            ))
        }
    }

    func snapshot() -> [SoundCloudLedgerEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func summary(title: String, detailed: Bool = false, duplicateWindow: Double = 300) -> String {
        let all = snapshot()
        let wire = all.filter { $0.outcome == "wire" }
        let api = wire.filter { SoundCloudEndpoint.isAPIHost($0.host) }
        let minutes = max(1, elapsed / 60)
        var lines = [
            "[SCTraffic] ==== \(title) after \(Int(elapsed))s ====",
            String(format: "[SCTraffic] wire=%d api=%d cdn=%d replayed=%d coalesced=%d rejected=%d api/min=%.1f",
                   wire.count, api.count, wire.count - api.count,
                   all.filter { $0.outcome == "replayed" }.count,
                   all.filter { $0.outcome == "coalesced" }.count,
                   all.filter { $0.outcome.hasPrefix("rejected") }.count,
                   Double(api.count) / minutes),
        ]
        var perMinute: [Int: Int] = [:]
        for entry in api { perMinute[Int(entry.t / 60), default: 0] += 1 }
        lines.append("[SCTraffic] api per minute: " + perMinute.keys.sorted().map { "m\($0)=\(perMinute[$0]!)" }.joined(separator: " "))

        var lastSeen: [String: Double] = [:]
        var duplicates: [String: Int] = [:]
        for entry in wire.sorted(by: { $0.t < $1.t }) {
            let key = entry.method + " " + entry.url
            if let previous = lastSeen[key], entry.t - previous <= duplicateWindow {
                duplicates[entry.endpoint, default: 0] += 1
            }
            lastSeen[key] = entry.t
        }
        let grouped = Dictionary(grouping: wire, by: { "\($0.method) \($0.endpoint)" })
        let rows = grouped.sorted { $0.value.count > $1.value.count }
        lines.append("[SCTraffic] endpoint | wire | dupes<=\(Int(duplicateWindow))s | top callers")
        for (endpoint, items) in rows.prefix(detailed ? 60 : 15) {
            let endpointOnly = items.first?.endpoint ?? endpoint
            let callers = Dictionary(grouping: items, by: \.caller)
                .sorted { $0.value.count > $1.value.count }
                .prefix(3)
                .map { "\($0.key)×\($0.value.count)" }
                .joined(separator: ", ")
            lines.append("[SCTraffic] \(endpoint) | \(items.count) | \(duplicates[endpointOnly] ?? 0) | \(callers)")
        }
        if detailed {
            let byCaller = Dictionary(grouping: api, by: \.caller).sorted { $0.value.count > $1.value.count }
            lines.append("[SCTraffic] api by caller:")
            for (caller, items) in byCaller.prefix(30) {
                lines.append("[SCTraffic]   \(items.count) \(caller)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func caller() -> String {
        let skipped = [
            "SoundCloudGateway", "SoundCloudAPI.request", "rawGet", "TrackActionsClient",
            "SoundCloudRequestLedger", "SoundCloudRequestEnvironment", "messagingRequest",
            "performSocialRequest", "performLikeRequest", "performFollowingRequest", "fetchTracks",
            "SoundCloudAPI.getTracks", "SoundCloudAPI.getPlaylistTracks", "SoundCloudAPI.getSystemPlaylistTracks",
            "SoundCloudAPI.getStreamURL", "SoundCloudAPI.getNextPage", "SoundCloudAPI.getLikesPage",
            "SoundCloudTokenRefresh", "WaveformService", "SoundCloudCredentialRefreshBarrier",
        ]
        var fallback: String?
        for raw in Thread.callStackSymbols.dropFirst(2) {
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4 else { continue }
            let mangled = String(parts[3])
            guard mangled.hasPrefix("$s") else { continue }
            let name = demangle(mangled)
            guard name.contains("Sounding") else { continue }
            let trimmed = shorten(name)
            if skipped.contains(where: { name.contains($0) }) {
                if fallback == nil, !name.contains("SoundCloudGateway"), !name.contains("SoundCloudRequestLedger") {
                    fallback = trimmed
                }
                continue
            }
            return trimmed
        }
        return fallback ?? "async"
    }

    private static let symbolPattern = try? NSRegularExpression(
        pattern: #"Sounding[A-Za-z0-9_]*\.((?:[A-Za-z_][A-Za-z0-9_]*\.)*[A-Za-z_][A-Za-z0-9_]*)(?:<[^>]*>)?\("#
    )

    private static func shorten(_ symbol: String) -> String {
        let range = NSRange(symbol.startIndex..., in: symbol)
        guard let match = symbolPattern?.firstMatch(in: symbol, range: range),
              let name = Range(match.range(at: 1), in: symbol) else {
            return String(symbol.prefix(80))
        }
        return String(symbol[name])
    }

    private typealias Demangler = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static let demangler: Demangler? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangler.self)
    }()

    private static func demangle(_ mangled: String) -> String {
        guard let demangler else { return mangled }
        return mangled.withCString { pointer in
            guard let result = demangler(pointer, strlen(pointer), nil, nil, 0) else { return mangled }
            defer { free(result) }
            return String(cString: result)
        }
    }
}
#endif
