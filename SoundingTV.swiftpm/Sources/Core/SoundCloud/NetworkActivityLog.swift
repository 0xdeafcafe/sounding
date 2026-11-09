import Foundation
import os
import Synchronization
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

struct NetworkFeature: RawRepresentable, Hashable, Comparable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static let feed: Self = "feed"
    static let search: Self = "search"
    static let scout: Self = "scout"
    static let streamResolve: Self = "stream-resolve"
    static let media: Self = "media"
    static let waveform: Self = "waveform"
    static let artwork: Self = "artwork"
    static let download: Self = "download"
    static let promotedImpression: Self = "promoted-impression"
    static let promotedPlay: Self = "promoted-play"
    static let promotedClick: Self = "promoted-click"
    static let auth: Self = "auth"
    static let signOut: Self = "sign-out"
    static let sonos: Self = "sonos"
    static let profile: Self = "profile"
    static let likes: Self = "likes"
    static let playlists: Self = "playlists"
    static let comments: Self = "comments"
    static let messages: Self = "messages"
    static let activity: Self = "activity"
    static let followers: Self = "followers"
    static let discover: Self = "discover"
    static let tracks: Self = "tracks"
    static let history: Self = "history"
    static let api: Self = "api"

    var isPromoted: Bool { rawValue.hasPrefix("promoted") }

    var mayRunInBackground: Bool {
        switch self {
        case .streamResolve, .media, .download, .auth, .sonos, .scout, .promotedPlay: return true
        default: return false
        }
    }

    static func soundCloud(path: String, lane: String) -> Self {
        if path == "/sign-out" || path == "/disconnect" { return .signOut }
        switch lane {
        case "authentication": return .auth
        case "streamResolution": return .streamResolve
        case "waveform": return .waveform
        case "media": return .media
        case "messaging": return .messages
        case "followers": return .followers
        default: break
        }
        let parts = path.lowercased().split(separator: "/")
        func has(_ names: String...) -> Bool { parts.contains { names.contains(String($0)) } }
        if has("oauth", "oauth2", "token") { return .auth }
        if has("search") || parts.first?.hasPrefix("search") == true { return .search }
        if has("play-history", "recently-played") { return .history }
        if has("streams") { return .streamResolve }
        if has("stream", "feed") || lane == "feed" { return .feed }
        if has("activities", "notifications") { return .activity }
        if has("conversations", "messages") { return .messages }
        if has("comments") { return .comments }
        if has("followers", "followings", "likers", "favoriters", "reposters") { return .followers }
        if has("likes", "track_likes", "playlist_likes", "favorites", "reposts") { return .likes }
        if has("related", "recommended", "mixed-selections", "stations", "charts", "discover") { return .discover }
        if has("playlists") { return .playlists }
        if has("me", "users") { return .profile }
        if has("tracks", "resolve") { return .tracks }
        return .api
    }
}

struct NetworkIssues: OptionSet, Hashable, Sendable {
    let rawValue: UInt16

    static let failed = Self(rawValue: 1 << 0)
    static let rateLimited = Self(rawValue: 1 << 1)
    static let backoff = Self(rawValue: 1 << 2)
    static let duplicate = Self(rawValue: 1 << 3)
    static let background = Self(rawValue: 1 << 4)
    static let repeatedPing = Self(rawValue: 1 << 5)
    static let unexpectedHost = Self(rawValue: 1 << 6)

    static let ordered: [Self] = [.rateLimited, .backoff, .failed, .duplicate, .repeatedPing, .background, .unexpectedHost]

    var title: String {
        switch self {
        case .failed: return "Failed"
        case .rateLimited: return "Rate Limited"
        case .backoff: return "Backoff"
        case .duplicate: return "Duplicate"
        case .background: return "In Background"
        case .repeatedPing: return "Repeated Ping"
        case .unexpectedHost: return "Unexpected Host"
        default: return Self.ordered.filter(contains).map(\.title).joined(separator: ", ")
        }
    }

    var exportName: String {
        switch self {
        case .failed: return "failed"
        case .rateLimited: return "rate-limited"
        case .backoff: return "backoff"
        case .duplicate: return "duplicate"
        case .background: return "background"
        case .repeatedPing: return "repeated-ping"
        case .unexpectedHost: return "unexpected-host"
        default: return Self.ordered.filter(contains).map(\.exportName).joined(separator: ",")
        }
    }
}

struct NetworkActivityEntry: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case request
        case trafficStop
        case backgroundPause
        case playbackPause
        case laneCooldown
    }

    enum Source: String, Sendable {
        case network
        case cache
        case shared
        case revalidated
        case held
        case rejected
        case player
    }

    let id: Int
    let date: Date
    let kind: Kind
    let feature: NetworkFeature
    let method: String
    let host: String
    let path: String
    let query: String
    let lane: String
    let intent: String
    let status: Int?
    let duration: TimeInterval?
    let bytes: Int?
    let source: Source
    let retried: Bool
    let error: String?
    let until: Date?
    let issues: NetworkIssues
    var detail: String? = nil

    var hasIssues: Bool { !issues.isEmpty }
    var isWire: Bool { kind == .request && source == .network }
    var isRateLimit: Bool { issues.contains(.rateLimited) || issues.contains(.backoff) }
    var hostAndPath: String { host + path }
    var displayURL: String { query.isEmpty ? hostAndPath : hostAndPath + "?" + query }
}

struct NetworkRequestRecord: Sendable {
    var feature: NetworkFeature
    var method: String = "GET"
    var url: URL
    var lane: String = ""
    var intent: String = ""
    var status: Int?
    var duration: TimeInterval?
    var bytes: Int?
    var source: NetworkActivityEntry.Source = .network
    var error: (any Error)?
    var allowsBackground: Bool?
    var detectsDuplicates = true
    var issues: NetworkIssues = []
    var detail: String? = nil
}

enum NetworkRedaction {
    static let placeholder = "REDACTED"

    private static let sensitiveFragments = [
        "token", "secret", "password", "passwd", "signature", "oauth", "auth", "credential",
        "client_id", "clientid", "client-id", "apikey", "api_key", "api-key", "key-pair", "policy", "cookie", "session", "jwt",
    ]
    private static let sensitiveNames: Set<String> = ["sig", "key", "code", "s", "hmac", "nonce", "assertion", "ticket"]

    static func isSensitive(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return sensitiveNames.contains(lowered) || sensitiveFragments.contains { lowered.contains($0) }
    }

    static func looksOpaque(_ value: String) -> Bool {
        if value.hasPrefix("eyJ") { return true }
        guard value.count >= 40 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || "-_.~%+/=".contains($0) }
            && !value.contains("%2F") && !value.contains("/")
    }

    static func redact(_ url: URL) -> (host: String, path: String, query: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (url.host?.lowercased() ?? "", "", "")
        }
        let host = (components.host ?? "").lowercased() + (components.port.map { ":\($0)" } ?? "")
        let path = redactPath(components.percentEncodedPath)
        let query = (components.percentEncodedQueryItems ?? []).map { item -> String in
            guard let value = item.value else { return item.name }
            let decoded = value.removingPercentEncoding ?? value
            if isSensitive(item.name) || looksOpaque(decoded) { return "\(item.name)=\(placeholder)" }
            return "\(item.name)=\(value)"
        }.joined(separator: "&")
        return (host, path, query)
    }

    private static func redactPath(_ path: String) -> String {
        guard path.contains("eyJ") || path.split(separator: "/").contains(where: { looksOpaque(String($0)) && $0.count >= 64 }) else {
            return path
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            let value = String(segment)
            return value.hasPrefix("eyJ") || (value.count >= 64 && looksOpaque(value)) ? placeholder : value
        }.joined(separator: "/")
    }
}

enum NetworkHostPolicy {
    static func isExpected(host rawHost: String, feature: NetworkFeature) -> Bool {
        let host = rawHost.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        if feature == .sonos { return isLocal(host) }
        if feature.isPromoted { return !host.isEmpty }
        if isSoundCloud(host) { return true }
        #if DEBUG
        if host == "127.0.0.1" || host == "localhost" { return true }
        #endif
        return false
    }

    static func isSoundCloud(_ host: String) -> Bool {
        ["soundcloud.com", "sndcdn.com", "soundcloud.cloud"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isAPI(_ host: String) -> Bool {
        host == "api-v2.soundcloud.com" || host == "api.soundcloud.com" || host == "secure.soundcloud.com"
    }

    static func isLocal(_ host: String) -> Bool {
        if host.hasSuffix(".local") || host == "localhost" { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return host.hasPrefix("fe80") || host.hasPrefix("[fe80") }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, let second): return (16...31).contains(second)
        default: return false
        }
    }
}

final class NetworkActivityLog: Sendable {
    static let shared = NetworkActivityLog(sessionDirectory: defaultSessionDirectory)

    static let capacity = 2_000
    static let duplicateWindow: TimeInterval = 3
    static let sessionFileDefaultsKey = "red.forbes.sounding.networkActivity.sessionFile"

    @TaskLocal static var feature: NetworkFeature?
    @TaskLocal static var detail: String?

    static func sanitizedDetail(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = String(value.map { $0 == "\t" || $0 == "\n" || $0 == "\r" ? " " : $0 }.prefix(120))
        guard !cleaned.isEmpty, !cleaned.contains("eyJ"), !cleaned.contains("://"),
              !cleaned.split(separator: " ").contains(where: { NetworkRedaction.looksOpaque(String($0)) }) else { return nil }
        return cleaned
    }

    static var isVisible: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    private struct Recent {
        var date: Date
        var failed: Bool
    }

    private struct State {
        var entries: [NetworkActivityEntry] = []
        var head = 0
        var nextID = 1
        var version = 0
        var paused = false
        var foreground = true
        var recent: [Int: Recent] = [:]
        var pings: Set<Int> = []
        var pendingLines: [String] = []
        var flushScheduled = false
        var savesSession = false
        var lastEntry: NetworkActivityEntry?
    }

    private let state = Mutex(State())
    private let capacity: Int
    private let logger = Logger(subsystem: "red.forbes.sounding", category: "network")
    private let sessionFileURL: URL?
    private let writeQueue = DispatchQueue(label: "red.forbes.sounding.network-log", qos: .utility)

    init(capacity: Int = NetworkActivityLog.capacity, sessionDirectory: URL? = nil) {
        self.capacity = capacity
        if let sessionDirectory {
            let stamp = Int(Date().timeIntervalSince1970)
            sessionFileURL = sessionDirectory.appendingPathComponent("network-\(stamp).log")
            let legacy = sessionDirectory.deletingLastPathComponent().appendingPathComponent("SoundCloudNetworkActivity.json")
            writeQueue.async { Self.prune(sessionDirectory, legacy: legacy) }
            let saves = UserDefaults.standard.bool(forKey: Self.sessionFileDefaultsKey)
            state.withLock { $0.savesSession = saves }
            observeApplicationState()
        } else {
            sessionFileURL = nil
        }
    }

    private func observeApplicationState() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setApplicationForeground(false)
        }
        _ = center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setApplicationForeground(true)
        }
        #endif
    }

    var version: Int { state.withLock { $0.version } }
    var isPaused: Bool { state.withLock { $0.paused } }

    var savesSessionFile: Bool {
        get { sessionFileURL != nil && state.withLock { $0.savesSession } }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.sessionFileDefaultsKey)
            state.withLock {
                $0.savesSession = newValue
                $0.version += 1
            }
        }
    }

    var existingSessionFile: URL? {
        guard let sessionFileURL, FileManager.default.fileExists(atPath: sessionFileURL.path) else { return nil }
        return sessionFileURL
    }

    func setPaused(_ paused: Bool) {
        state.withLock {
            $0.paused = paused
            $0.version += 1
        }
    }

    func setApplicationForeground(_ foreground: Bool) {
        state.withLock { $0.foreground = foreground }
    }

    func clear() {
        state.withLock {
            $0.entries.removeAll(keepingCapacity: true)
            $0.head = 0
            $0.lastEntry = nil
            $0.recent.removeAll()
            $0.version += 1
        }
    }

    func snapshot() -> [NetworkActivityEntry] {
        state.withLock { state in
            guard state.entries.count == capacity, state.head > 0 else { return state.entries }
            return Array(state.entries[state.head...] + state.entries[..<state.head])
        }
    }

    func requests(since date: Date) -> Int {
        state.withLock { state in
            state.entries.reduce(0) { $0 + ($1.isWire && $1.date >= date && NetworkHostPolicy.isAPI($1.host) ? 1 : 0) }
        }
    }

    @discardableResult
    func record(_ record: NetworkRequestRecord, now: Date = Date()) -> NetworkActivityEntry? {
        let (host, path, query) = NetworkRedaction.redact(record.url)
        let errorText = record.error.flatMap(Self.describe)
        let badStatus = record.status.map { !(200..<400).contains($0) && $0 != 429 } ?? false
        let failed = record.source == .network && ((errorText != nil && errorText != "cancelled") || badStatus)
        var issues = record.issues
        if failed { issues.insert(.failed) }
        if record.status == 429 { issues.insert(.rateLimited) }
        if record.source == .rejected || !NetworkHostPolicy.isExpected(host: host, feature: record.feature) {
            issues.insert(.unexpectedHost)
        }
        let isNetwork = record.source == .network
        let fingerprint = isNetwork ? Self.fingerprint(method: record.method, url: record.url) : 0

        let entry: NetworkActivityEntry? = state.withLock { state in
            guard !state.paused else { return nil }
            if record.source == .held, let last = state.lastEntry, last.source == .held,
               last.host == host, last.path == path, now.timeIntervalSince(last.date) < 5 {
                return nil
            }
            var issues = issues
            var retried = false
            if isNetwork {
                #if !os(macOS)
                if !state.foreground, !(record.allowsBackground ?? record.feature.mayRunInBackground) {
                    issues.insert(.background)
                }
                #endif
                if record.feature.isPromoted {
                    if !state.pings.insert(fingerprint).inserted { issues.insert(.repeatedPing) }
                    if state.pings.count > 4_096 { state.pings.removeAll() }
                } else if record.detectsDuplicates {
                    if let previous = state.recent[fingerprint], now.timeIntervalSince(previous.date) < Self.duplicateWindow {
                        if previous.failed { retried = true } else { issues.insert(.duplicate) }
                    }
                    state.recent[fingerprint] = Recent(date: now, failed: failed || record.status == 429)
                    if state.recent.count > 512 {
                        state.recent = state.recent.filter { now.timeIntervalSince($0.value.date) < Self.duplicateWindow }
                        if state.recent.count > 256 { state.recent.removeAll(keepingCapacity: true) }
                    }
                }
            }
            let entry = NetworkActivityEntry(
                id: state.nextID, date: now, kind: .request, feature: record.feature,
                method: record.method.uppercased(), host: host, path: path, query: query,
                lane: record.lane, intent: record.intent, status: record.status,
                duration: record.duration, bytes: record.bytes, source: record.source,
                retried: retried, error: errorText, until: nil, issues: issues,
                detail: Self.sanitizedDetail(record.detail)
            )
            append(entry, to: &state)
            return entry
        }
        if let entry { emit(entry) }
        return entry
    }

    @discardableResult
    func recordStop(_ kind: NetworkActivityEntry.Kind, endpoint: String, lane: String, intent: String, until: Date, now: Date = Date()) -> NetworkActivityEntry? {
        let entry: NetworkActivityEntry? = state.withLock { state in
            guard !state.paused else { return nil }
            let entry = NetworkActivityEntry(
                id: state.nextID, date: now, kind: kind, feature: NetworkFeature.soundCloud(path: endpoint, lane: lane),
                method: "-", host: "", path: endpoint, query: "", lane: lane, intent: intent,
                status: 429, duration: nil, bytes: nil, source: .held, retried: false,
                error: nil, until: until, issues: .backoff
            )
            append(entry, to: &state)
            return entry
        }
        if let entry { emit(entry) }
        return entry
    }

    private func append(_ entry: NetworkActivityEntry, to state: inout State) {
        state.lastEntry = entry
        state.nextID += 1
        state.version += 1
        if state.entries.count < capacity {
            state.entries.append(entry)
        } else {
            state.entries[state.head] = entry
            state.head = (state.head + 1) % capacity
        }
    }

    private func emit(_ entry: NetworkActivityEntry) {
        let status = entry.status.map(String.init) ?? "-"
        let milliseconds = entry.duration.map { Int($0 * 1_000) } ?? -1
        if entry.hasIssues {
            logger.error("\(entry.feature.rawValue, privacy: .public) \(entry.method, privacy: .public) \(entry.host, privacy: .public)\(entry.path, privacy: .private)?\(entry.query, privacy: .private) \(status, privacy: .public) \(milliseconds, privacy: .public)ms \(entry.source.rawValue, privacy: .public) issues=\(entry.issues.exportName, privacy: .public)")
        } else {
            logger.info("\(entry.feature.rawValue, privacy: .public) \(entry.method, privacy: .public) \(entry.host, privacy: .public)\(entry.path, privacy: .private)?\(entry.query, privacy: .private) \(status, privacy: .public) \(milliseconds, privacy: .public)ms \(entry.source.rawValue, privacy: .public)")
        }
        guard savesSessionFile, let sessionFileURL else { return }
        let line = Self.exportLine(entry)
        let shouldSchedule = state.withLock { state -> Bool in
            state.pendingLines.append(line)
            guard !state.flushScheduled else { return false }
            state.flushScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        writeQueue.asyncAfter(deadline: .now() + 2) { [self] in
            let lines = state.withLock { state -> [String] in
                state.flushScheduled = false
                defer { state.pendingLines.removeAll(keepingCapacity: true) }
                return state.pendingLines
            }
            Self.append(lines, to: sessionFileURL)
        }
    }

    func exportText(now: Date = Date()) -> String {
        let entries = snapshot()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let summary = NetworkIssueSummary(entries)
        var lines = [
            "Sounding network activity, exported \(formatter.string(from: now))",
            "Last minute: \(requests(since: now.addingTimeInterval(-60))) API requests; last hour: \(requests(since: now.addingTimeInterval(-3600))) API requests",
            "Issues: " + (summary.isEmpty ? "none" : summary.counts.map { "\($0.issue.exportName) \($0.count)" }.joined(separator: ", ")),
            Self.exportHeader,
        ]
        lines.reserveCapacity(entries.count + 4)
        for entry in entries { lines.append(Self.exportLine(entry, formatter: formatter)) }
        return lines.joined(separator: "\n")
    }

    static let exportHeader = "time\tkind\tfeature\tmethod\turl\tstatus\tms\tbytes\tsource\tretried\tissues\terror\tlane\tintent\tuntil\tdetail"

    static func exportLine(_ entry: NetworkActivityEntry, formatter: ISO8601DateFormatter = lineFormatter) -> String {
        [
            formatter.string(from: entry.date),
            entry.kind.rawValue,
            entry.feature.rawValue,
            entry.method,
            entry.displayURL,
            entry.status.map(String.init) ?? "-",
            entry.duration.map { String(Int($0 * 1_000)) } ?? "-",
            entry.bytes.map(String.init) ?? "-",
            entry.source.rawValue,
            entry.retried ? "yes" : "no",
            entry.issues.isEmpty ? "-" : entry.issues.exportName,
            entry.error ?? "-",
            entry.lane.isEmpty ? "-" : entry.lane,
            entry.intent.isEmpty ? "-" : entry.intent,
            entry.until.map { formatter.string(from: $0) } ?? "-",
            entry.detail ?? "-",
        ].joined(separator: "\t")
    }

    nonisolated(unsafe) private static let lineFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func describe(_ error: any Error) -> String? {
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? "cancelled" : "URLError \(urlError.code.rawValue)"
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return "URLError \(nsError.code)" }
        let typeName = String(describing: type(of: error))
        let text = String(describing: error)
        guard text.count <= 80, !text.contains("eyJ"), !text.contains("://"), !text.lowercased().contains("token") else { return typeName }
        return typeName + "." + text
    }

    private static func fingerprint(method: String, url: URL) -> Int {
        var hasher = Hasher()
        hasher.combine(method.uppercased())
        hasher.combine(url.absoluteString)
        return hasher.finalize()
    }

    private static var defaultSessionDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NetworkActivity", isDirectory: true)
    }

    private static func append(_ lines: [String], to url: URL) {
        guard !lines.isEmpty else { return }
        let fileManager = FileManager.default
        let payload = Data((lines.joined(separator: "\n") + "\n").utf8)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data((exportHeader + "\n").utf8).write(to: url, options: .atomic)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: payload)
    }

    private static func prune(_ directory: URL, legacy: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: legacy)
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(3) {
            try? fileManager.removeItem(at: file)
        }
    }
}

struct NetworkIssueSummary: Equatable, Sendable {
    struct Count: Equatable, Sendable {
        let issue: NetworkIssues
        let count: Int
    }

    let counts: [Count]

    init(_ entries: [NetworkActivityEntry]) {
        var tally = [UInt16: Int]()
        for entry in entries where entry.hasIssues {
            for issue in NetworkIssues.ordered where entry.issues.contains(issue) {
                tally[issue.rawValue, default: 0] += 1
            }
        }
        counts = NetworkIssues.ordered.compactMap { issue in
            tally[issue.rawValue].map { Count(issue: issue, count: $0) }
        }
    }

    var isEmpty: Bool { counts.isEmpty }
}

final class NetworkActivityTaskObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let feature: NetworkFeature
    private let log: NetworkActivityLog
    private let metrics = Mutex([Int: (TimeInterval, Int, Bool)]())

    init(feature: NetworkFeature, log: NetworkActivityLog = .shared) {
        self.feature = feature
        self.log = log
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let last = metrics.transactionMetrics.last
        let bytes = metrics.transactionMetrics.reduce(0) { $0 + Int($1.countOfResponseBodyBytesReceived) }
        let cached = last?.resourceFetchType == .localCache
        self.metrics.withLock { $0[task.taskIdentifier] = (metrics.taskInterval.duration, bytes, cached) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        observeCompletion(task: task, error: error)
    }

    func observeCompletion(task: URLSessionTask, error: (any Error)?) {
        guard let url = task.originalRequest?.url ?? task.currentRequest?.url else { return }
        let collected = metrics.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        log.record(NetworkRequestRecord(
            feature: feature,
            method: task.originalRequest?.httpMethod ?? "GET",
            url: url,
            status: (task.response as? HTTPURLResponse)?.statusCode,
            duration: collected?.0,
            bytes: collected?.1 ?? Int(task.countOfBytesReceived),
            source: collected?.2 == true ? .cache : .network,
            error: error
        ))
    }
}

extension URLSession {
    func loggedData(
        for request: URLRequest,
        feature: NetworkFeature,
        log: NetworkActivityLog = .shared
    ) async throws -> (Data, URLResponse) {
        let started = ContinuousClock.now
        func seconds() -> TimeInterval {
            let elapsed = ContinuousClock.now - started
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        guard let url = request.url else { return try await data(for: request) }
        do {
            let (body, response) = try await self.data(for: request)
            log.record(NetworkRequestRecord(
                feature: NetworkActivityLog.feature ?? feature,
                method: request.httpMethod ?? "GET",
                url: url,
                status: (response as? HTTPURLResponse)?.statusCode,
                duration: seconds(),
                bytes: body.count
            ))
            return (body, response)
        } catch {
            log.record(NetworkRequestRecord(
                feature: NetworkActivityLog.feature ?? feature,
                method: request.httpMethod ?? "GET",
                url: url,
                duration: seconds(),
                error: error
            ))
            throw error
        }
    }

    func loggedData(from url: URL, feature: NetworkFeature, log: NetworkActivityLog = .shared) async throws -> (Data, URLResponse) {
        try await loggedData(for: URLRequest(url: url), feature: feature, log: log)
    }
}
