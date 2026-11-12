import Foundation
import Combine
import CryptoKit
import os

enum SoundCloudTrafficSafetyState: Equatable, Sendable {
    case ready
    case waiting(statusCode: Int, until: Date)
}

enum SoundCloudRateLimitPayload {
    static func resetDate(from data: Data) -> Date? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = root["errors"] as? [[String: Any]] else { return nil }
        let raw = errors.lazy.compactMap { error -> String? in
            guard let meta = error["meta"] as? [String: Any] else { return nil }
            return meta["reset_time"] as? String
        }.first
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss Z"
        return formatter.date(from: raw)
    }
}

enum SoundCloudApplicationActivity: String, Sendable {
    case unknown
    case foreground
    case background
}

enum SoundCloudRequestIntent: String, Sendable {
    case userInitiated
    case playback
    case autonomous
}

enum SoundCloudRequestLane: String, CaseIterable, Sendable {
    case metadata
    case feed
    case followers
    case messaging
    case social
    case streamResolution
    case media
    case waveform
    case authentication
}

/// Task-local request purpose lets a complete paginated workflow inherit one
/// admission policy without adding policy arguments to every API method.
enum SoundCloudRequestEnvironment {
    @TaskLocal static var intent: SoundCloudRequestIntent = .userInitiated
    @TaskLocal static var lane: SoundCloudRequestLane = .metadata
    @TaskLocal static var allowsBackground: Bool?
    #if DEBUG
    @TaskLocal static var debugCaller: String?
    #endif

    static func autonomous<T: Sendable>(
        lane: SoundCloudRequestLane,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await $intent.withValue(.autonomous) {
            try await $lane.withValue(lane) {
                try await operation()
            }
        }
    }

    static func systemInitiated<T: Sendable>(
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await $intent.withValue(.autonomous) {
            try await $allowsBackground.withValue(true) {
                try await operation()
            }
        }
    }

    static func playback<T: Sendable>(
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await $intent.withValue(.playback) {
            try await $lane.withValue(.streamResolution) {
                try await operation()
            }
        }
    }
}

struct SoundCloudRequestContext: Sendable {
    let intent: SoundCloudRequestIntent
    let lane: SoundCloudRequestLane
    let allowsBackground: Bool
    let coalesces: Bool

    init(
        intent: SoundCloudRequestIntent = SoundCloudRequestEnvironment.intent,
        lane: SoundCloudRequestLane = SoundCloudRequestEnvironment.lane,
        allowsBackground: Bool? = nil,
        coalesces: Bool = true
    ) {
        self.intent = intent
        self.lane = lane
        self.allowsBackground = allowsBackground ?? SoundCloudRequestEnvironment.allowsBackground ?? (intent != .autonomous)
        self.coalesces = coalesces
    }

    static func current(lane: SoundCloudRequestLane? = nil) -> Self {
        .init(lane: lane ?? SoundCloudRequestEnvironment.lane)
    }
}

enum SoundCloudGatewayError: Error, LocalizedError, Equatable, Sendable {
    case autonomousWorkSuspended
    case backgroundPaused(until: Date)
    case endpointCoolingDown(lane: SoundCloudRequestLane, until: Date)
    case untrustedDestination(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .autonomousWorkSuspended:
            return "SoundCloud background updates are paused until the app is active."
        case .backgroundPaused(let until):
            return "SoundCloud background updates are paused until \(until.formatted(date: .omitted, time: .shortened))."
        case .endpointCoolingDown(let lane, let until):
            return "SoundCloud \(lane.rawValue) requests are paused until \(until.formatted(date: .abbreviated, time: .shortened))."
        case .untrustedDestination:
            return "SoundCloud returned an untrusted network destination."
        case .invalidResponse:
            return "SoundCloud returned an invalid network response."
        }
    }
}

enum SoundCloudHostPolicy {
    private static let oauthHosts: Set<String> = [
        "api.soundcloud.com",
        "api-v2.soundcloud.com",
        "secure.soundcloud.com",
    ]
    private static let modernMediaHosts: Set<String> = [
        // SoundCloud's AAC/HLS streams moved off sndcdn.com in 2025.
        // Keep this exact-host allow-list separate from OAuth destinations.
        "playback.media-streaming.soundcloud.cloud",
        "license.media-streaming.soundcloud.cloud",
    ]

    static func mayReceiveOAuth(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return oauthHosts.contains(host)
    }

    static func allows(_ url: URL, lane: SoundCloudRequestLane) -> Bool {
        #if DEBUG
        // The opt-in local media harness exercises the real resolver and
        // AVPlayer byte path. Trust only the exact origin explicitly supplied
        // for that launch; credentials are never attached to this host.
        if isConfiguredDebugMediaOrigin(url) { return lane != .authentication }
        #endif
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        switch lane {
        case .waveform:
            return host == "sndcdn.com" || host.hasSuffix(".sndcdn.com")
        case .media:
            return host == "sndcdn.com"
                || host.hasSuffix(".sndcdn.com")
                || modernMediaHosts.contains(host)
        case .metadata, .feed, .followers, .messaging, .social, .streamResolution, .authentication:
            return oauthHosts.contains(host)
        }
    }

    static func allowsMedia(_ url: URL) -> Bool { allows(url, lane: .media) }

    static func allowsRedirect(from source: URL, to destination: URL) -> Bool {
        #if DEBUG
        if isConfiguredDebugMediaOrigin(source) {
            return isConfiguredDebugMediaOrigin(destination)
        }
        #endif
        if mayReceiveOAuth(source) { return mayReceiveOAuth(destination) }
        if allowsMedia(source) { return allowsMedia(destination) }
        return false
    }

    #if DEBUG
    private static func isConfiguredDebugMediaOrigin(_ url: URL) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_STREAM_HOST"],
              let configured = URL(string: raw),
              let configuredHost = configured.host?.lowercased(),
              let host = url.host?.lowercased() else { return false }
        return url.scheme?.lowercased() == configured.scheme?.lowercased()
            && host == configuredHost
            && url.port == configured.port
    }
    #endif
}

private final class SoundCloudSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: "red.forbes.sounding", category: "soundcloud-gateway")

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let source = response.url,
              let destination = request.url,
              SoundCloudHostPolicy.allowsRedirect(from: source, to: destination) else {
            logger.error("Rejected redirect from \(response.url?.host ?? "(missing)", privacy: .public) to \(request.url?.host ?? "(missing)", privacy: .public)")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct SoundCloudGatewaySnapshot: Sendable {
    let activity: SoundCloudApplicationActivity
    let globalBlock: SoundCloudTrafficSafetyState
    let wireRequests: Int
    let coalescedRequests: Int
    let replayedResponses: Int
    let rejectedRequests: Int
    let requestsByLane: [SoundCloudRequestLane: Int]
}

struct SoundCloudHTTPTransport: Sendable {
    let data: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func live(session: URLSession) -> Self {
        Self(data: { request in try await session.data(for: request) })
    }
}

struct SoundCloudResponseCache<Key: Hashable> {
    struct Entry {
        let data: Data
        let response: HTTPURLResponse
        let url: URL
        var expiresAt: Date
        let retainUntil: Date
        let entityTag: String?
        let lastModified: String?
    }

    let maximumBytes: Int
    let maximumEntries: Int
    private(set) var entries: [Key: Entry] = [:]
    private(set) var totalBytes = 0

    init(maximumBytes: Int = 16 * 1_024 * 1_024, maximumEntries: Int = 512) {
        self.maximumBytes = maximumBytes
        self.maximumEntries = maximumEntries
    }

    func fresh(_ key: Key, now: Date) -> Entry? {
        guard let entry = entries[key], now < entry.expiresAt else { return nil }
        return entry
    }

    func revalidatable(_ key: Key, now: Date) -> Entry? {
        guard let entry = entries[key], now < entry.retainUntil,
              entry.entityTag != nil || entry.lastModified != nil else { return nil }
        return entry
    }

    mutating func store(_ data: Data, response: HTTPURLResponse, for key: Key, lifetime: TimeInterval, now: Date) {
        guard lifetime > 0, data.count <= maximumBytes / 4 else { return }
        let entityTag = response.value(forHTTPHeaderField: "ETag")
        let lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        let hasValidator = entityTag != nil || lastModified != nil
        remove(key)
        entries[key] = Entry(
            data: data,
            response: response,
            url: response.url ?? URL(fileURLWithPath: "/"),
            expiresAt: now.addingTimeInterval(lifetime),
            retainUntil: now.addingTimeInterval(hasValidator ? max(lifetime, 24 * 60 * 60) : lifetime),
            entityTag: entityTag,
            lastModified: lastModified
        )
        totalBytes += data.count
        evict(now: now)
    }

    mutating func extend(_ key: Key, lifetime: TimeInterval, now: Date) {
        entries[key]?.expiresAt = now.addingTimeInterval(lifetime)
    }

    mutating func removeAll(where shouldRemove: (Entry) -> Bool) {
        for (key, entry) in entries where shouldRemove(entry) { remove(key) }
    }

    private mutating func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalBytes -= entry.data.count
    }

    private mutating func evict(now: Date) {
        removeAll { now >= $0.retainUntil }
        while totalBytes > maximumBytes || entries.count > maximumEntries,
              let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            remove(oldest)
        }
    }
}

/// The sole control-plane transport for SoundCloud.
///
/// AVPlayer and background URLSession still own long-lived media byte transfer,
/// but URL admission and every request that obtains or refreshes a SoundCloud
/// resource pass through this gateway first.
@MainActor
final class SoundCloudGateway: ObservableObject {
    static let shared = SoundCloudGateway(networkLog: .shared)

    struct RequestKey: Hashable {
        let method: String
        let url: String
        let authorizationDigest: String
        let bodyDigest: String
    }

    struct WireResult: Sendable {
        let data: Data
        let response: HTTPURLResponse
        let duration: TimeInterval
    }

    @MainActor
    private final class Flight {
        let task: Task<WireResult, Error>
        var waiters = 0

        init(task: Task<WireResult, Error>) {
            self.task = task
        }
    }

    private struct EndpointFailure {
        var consecutiveFailures: Int
        var until: Date
    }

    private enum DefaultsKey {
        static let blockedUntil = "red.forbes.sounding.soundcloud.trafficBlockedUntil"
        static let blockedStatus = "red.forbes.sounding.soundcloud.trafficBlockedStatus"
        static let blockedReason = "red.forbes.sounding.soundcloud.trafficBlockedReason"
        static let backgroundPausedUntil = "red.forbes.sounding.soundcloud.backgroundPausedUntil"
        static let playbackPausedUntil = "red.forbes.sounding.soundcloud.playbackPausedUntil"
        static let rateLimitStrikes = "red.forbes.sounding.soundcloud.rateLimitStrikes"
        static let backgroundRateLimitStrikes = "red.forbes.sounding.soundcloud.backgroundRateLimitStrikes"
        static let challengeStrikes = "red.forbes.sounding.soundcloud.challengeStrikes"
    }

    private enum BlockReason {
        static let rateLimit = "rate-limit"
        static let challenge = "verified-bot-challenge"
    }

    static let rateLimitBackoff = SoundCloudBackoff(base: 2 * 60, cap: 60 * 60, jitter: 0.25)
    static let challengeBackoff = SoundCloudBackoff(base: 30 * 60, cap: 6 * 60 * 60, jitter: 0.25)
    static let briefStopBackoff = SoundCloudBackoff(base: 60, cap: 60, jitter: 0.25)
    static let maximumServerRetryAfter: TimeInterval = 6 * 60 * 60
    static let maximumPlaybackPause: TimeInterval = 24 * 60 * 60
    static let laneRateLimitBackoff = SoundCloudBackoff(base: 2 * 60, cap: 30 * 60, jitter: 0.25)

    private let transport: SoundCloudHTTPTransport
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let networkLog: NetworkActivityLog?
    private let budgetConfiguration: SoundCloudRequestBudget.Configuration
    private let logger = Logger(subsystem: "red.forbes.sounding", category: "soundcloud-gateway")

    private var activity: SoundCloudApplicationActivity = .unknown
    private var inFlight: [RequestKey: Flight] = [:]
    private var responseCache = SoundCloudResponseCache<RequestKey>()
    private var endpointFailures: [SoundCloudRequestLane: EndpointFailure] = [:]
    private var budget: SoundCloudRequestBudget

    private var wireRequests = 0
    private var coalescedRequests = 0
    private var replayedResponses = 0
    private var revalidatedResponses = 0
    private var rejectedRequests = 0
    private var requestsByLane: [SoundCloudRequestLane: Int] = [:]
    @Published private(set) var trafficSafety: SoundCloudTrafficSafetyState = .ready

    init(
        transport: SoundCloudHTTPTransport? = nil,
        defaults: UserDefaults = .standard,
        budget: SoundCloudRequestBudget.Configuration = .standard,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .milliseconds(Int64($0 * 1000))) },
        networkLog: NetworkActivityLog? = nil
    ) {
        #if DEBUG
        let debugTransport: SoundCloudHTTPTransport? = transport ?? (SoundCloudMockService.isEnabled ? SoundCloudMockService.transport() : nil)
        #else
        let debugTransport: SoundCloudHTTPTransport? = transport
        #endif
        if let transport = debugTransport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 120
            configuration.waitsForConnectivity = false
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            let session = URLSession(
                configuration: configuration,
                delegate: SoundCloudSessionDelegate(),
                delegateQueue: nil
            )
            self.transport = .live(session: session)
        }
        self.defaults = defaults
        self.now = now
        self.random = random
        self.sleep = sleep
        self.networkLog = networkLog
        self.budgetConfiguration = budget
        self.budget = SoundCloudRequestBudget(configuration: budget, now: now())
        clampPersistedRateLimitStop()
        if let until = blockedUntil, until > now() {
            let status = defaults.integer(forKey: DefaultsKey.blockedStatus)
            trafficSafety = .waiting(statusCode: status == 0 ? 429 : status, until: until)
        }
    }

    static func installAsTokenRefreshTransport() {
        SoundCloudTokenRefresh.requestTransport = { request in
            try await SoundCloudGateway.shared.data(
                for: request,
                context: .init(lane: .authentication, coalesces: false)
            )
        }
    }

    func setApplicationActivity(_ activity: SoundCloudApplicationActivity) {
        guard self.activity != activity else { return }
        self.activity = activity
        logger.info("Application activity is now \(activity.rawValue, privacy: .public)")
    }

    var isApplicationForeground: Bool { activity == .foreground }

    var backgroundWorkPausedUntil: Date? {
        storedDate(DefaultsKey.backgroundPausedUntil).flatMap { $0 > now() ? $0 : nil }
    }

    var playbackResolutionPausedUntil: Date? {
        storedDate(DefaultsKey.playbackPausedUntil).flatMap { $0 > now() ? $0 : nil }
    }

    func snapshot() -> SoundCloudGatewaySnapshot {
        SoundCloudGatewaySnapshot(
            activity: activity,
            globalBlock: trafficSafetyState(),
            wireRequests: wireRequests,
            coalescedRequests: coalescedRequests,
            replayedResponses: replayedResponses + revalidatedResponses,
            rejectedRequests: rejectedRequests,
            requestsByLane: requestsByLane
        )
    }

    func data(
        for request: URLRequest,
        context: SoundCloudRequestContext = .current()
    ) async throws -> (Data, HTTPURLResponse) {
        #if DEBUG
        let ledger = SoundCloudRequestLedger.shared
        let caller = ledger.isEnabled ? (SoundCloudRequestEnvironment.debugCaller ?? SoundCloudRequestLedger.caller()) : nil
        func note(_ outcome: String, status: Int? = nil, startedAt: Double? = nil) {
            ledger.record(request, lane: context.lane.rawValue, intent: context.intent.rawValue,
                          outcome: outcome, status: status, caller: caller, startedAt: startedAt)
        }
        #endif
        guard let url = request.url, SoundCloudHostPolicy.allows(url, lane: context.lane) else {
            #if DEBUG
            note("rejected-host")
            #endif
            rejectedRequests += 1
            log(request, context: context, source: .rejected)
            logger.error("Rejected \(context.lane.rawValue, privacy: .public) destination \(request.url?.host ?? "(missing)", privacy: .public)")
            throw SoundCloudGatewayError.untrustedDestination(request.url?.host ?? "(missing)")
        }
        do {
            try enforceGates(context)
        } catch {
            #if DEBUG
            note("rejected-gate")
            #endif
            log(request, context: context, source: .held, error: error)
            throw error
        }

        let key = Self.requestKey(request)
        let method = request.httpMethod?.uppercased() ?? "GET"
        let canCoalesce = context.coalesces && method == "GET"
        if canCoalesce, let cached = responseCache.fresh(key, now: now()) {
            replayedResponses += 1
            #if DEBUG
            note("replayed", status: cached.response.statusCode)
            #endif
            log(request, context: context, status: cached.response.statusCode, bytes: cached.data.count, source: .cache)
            return (cached.data, cached.response)
        }
        if canCoalesce, let existing = inFlight[key] {
            coalescedRequests += 1
            #if DEBUG
            note("coalesced")
            #endif
            let shared = try await join(existing, key: key)
            log(request, context: context, status: shared.response.statusCode, bytes: shared.data.count, source: .shared)
            return (shared.data, shared.response)
        }

        var outgoing = request
        let validator = canCoalesce ? responseCache.revalidatable(key, now: now()) : nil
        if let validator {
            if let tag = validator.entityTag { outgoing.setValue(tag, forHTTPHeaderField: "If-None-Match") }
            if let modified = validator.lastModified { outgoing.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }

        let task = Task<WireResult, Error> { [weak self, transport] in
            try await self?.admit(context, url: url)
            try Task.checkCancellation()
            self?.noteWireStart(context)
            let started = ContinuousClock.now
            let (data, response) = try await transport.data(outgoing)
            guard let http = response as? HTTPURLResponse else {
                throw SoundCloudGatewayError.invalidResponse
            }
            return WireResult(data: data, response: http, duration: Self.seconds(since: started))
        }
        let flight = Flight(task: task)
        if canCoalesce { inFlight[key] = flight }

        #if DEBUG
        let ledgerStartedAt = ledger.elapsed
        #endif
        let started = ContinuousClock.now
        do {
            let wire = try await join(flight, key: canCoalesce ? key : nil)
            var result = (wire.data, wire.response)
            if canCoalesce, inFlight[key] === flight { inFlight[key] = nil }
            #if DEBUG
            note("wire", status: result.1.statusCode, startedAt: ledgerStartedAt)
            #endif
            let lifetime = cacheLifetime(url: url, context: context)
            let revalidated = result.1.statusCode == 304 && validator != nil
            if result.1.statusCode == 304, let validator {
                revalidatedResponses += 1
                responseCache.extend(key, lifetime: lifetime, now: now())
                result = (validator.data, validator.response)
            }
            log(
                request, context: context, status: wire.response.statusCode, duration: wire.duration,
                bytes: wire.data.count, source: revalidated ? .revalidated : .network,
                body: wire.data
            )
            observe(data: result.0, response: result.1, context: context, method: method)
            if canCoalesce, (200..<300).contains(result.1.statusCode)
                || (result.1.statusCode == 404 && SoundCloudCachePolicy.cachesNotFound(url)) {
                responseCache.store(result.0, response: result.1, for: key, lifetime: lifetime, now: now())
            }
            return result
        } catch {
            if canCoalesce, inFlight[key] === flight { inFlight[key] = nil }
            let gated = error is SoundCloudGatewayError || error is APIError
            #if DEBUG
            note(gated ? "rejected-gate" : "wire", status: gated ? nil : -1, startedAt: ledgerStartedAt)
            #endif
            if !Self.isCancellation(error), !gated {
                log(request, context: context, duration: Self.seconds(since: started), source: .network, error: error)
                recordFailure(context: context, response: nil)
            } else if gated {
                log(request, context: context, source: .held, error: error)
            }
            throw error
        }
    }

    private func join(_ flight: Flight, key: RequestKey?) async throws -> WireResult {
        flight.waiters += 1
        let task = flight.task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { [weak self] in
            Task { @MainActor in self?.release(flight, key: key) }
        }
    }

    private func release(_ flight: Flight, key: RequestKey?) {
        flight.waiters -= 1
        guard flight.waiters <= 0 else { return }
        flight.task.cancel()
        if let key, inFlight[key] === flight { inFlight[key] = nil }
    }

    /// Background URLSession and AVPlayer own their transfer lifecycle, but
    /// URLs handed to them still pass the same allow-list and global gate.
    func admitMediaURL(_ url: URL) throws {
        #if DEBUG
        SoundCloudRequestLedger.shared.record(
            URLRequest(url: url), lane: "media", intent: "playback", outcome: "admitted",
            caller: SoundCloudRequestLedger.shared.isEnabled ? SoundCloudRequestLedger.caller() : nil
        )
        #endif
        guard SoundCloudHostPolicy.allowsMedia(url) else {
            networkLog?.record(NetworkRequestRecord(feature: .media, url: url, lane: "media", intent: "playback", source: .rejected), now: now())
            rejectedRequests += 1
            logger.error("Rejected media destination \(url.host ?? "(missing)", privacy: .public)")
            throw SoundCloudGatewayError.untrustedDestination(url.host ?? "(missing)")
        }
        networkLog?.record(NetworkRequestRecord(feature: .media, url: url, lane: "media", intent: "playback", source: .player), now: now())
        guard defaults.string(forKey: DefaultsKey.blockedReason) == BlockReason.challenge else { return }
        try enforceTrafficSafety()
    }

    func enforceTrafficSafety(now suppliedNow: Date? = nil) throws {
        let current = suppliedNow ?? now()
        guard let until = blockedUntil else { return }
        if current < until {
            let status = defaults.integer(forKey: DefaultsKey.blockedStatus)
            throw APIError.temporarilyBlocked(until: until, statusCode: status == 0 ? 429 : status)
        }
        clearGlobalBlock()
    }

    func trafficSafetyState(now suppliedNow: Date? = nil) -> SoundCloudTrafficSafetyState {
        let current = suppliedNow ?? now()
        guard let until = blockedUntil, current < until else { return .ready }
        let status = defaults.integer(forKey: DefaultsKey.blockedStatus)
        return .waiting(statusCode: status == 0 ? 429 : status, until: until)
    }

    @discardableResult
    func recordGlobalBlock(
        statusCode: Int,
        response: HTTPURLResponse,
        preferredUntil: Date? = nil,
        reason: String,
        now suppliedNow: Date? = nil
    ) -> Date {
        let current = suppliedNow ?? now()
        let until = preferredUntil
            ?? Self.retryAfterDate(from: response, now: current).map { min($0, current.addingTimeInterval(Self.maximumServerRetryAfter)) }
            ?? current.addingTimeInterval(Self.rateLimitBackoff.delay(attempt: 0, unit: random()))
        let effective = max(blockedUntil ?? current, until)
        defaults.set(effective.timeIntervalSince1970, forKey: DefaultsKey.blockedUntil)
        defaults.set(statusCode, forKey: DefaultsKey.blockedStatus)
        defaults.set(reason, forKey: DefaultsKey.blockedReason)
        trafficSafety = .waiting(statusCode: statusCode, until: effective)
        logger.error("Global traffic stop: HTTP \(statusCode), reason \(reason, privacy: .public), until \(effective)")
        return effective
    }

    static func isBotChallenge(response: HTTPURLResponse, data: Data) -> Bool {
        guard !(200..<300).contains(response.statusCode), response.statusCode != 304 else { return false }
        if response.value(forHTTPHeaderField: "X-DataDome") != nil,
           response.statusCode == 403 || response.statusCode == 429 { return true }
        guard !data.isEmpty else { return false }
        let prefix = data.prefix(256 * 1024)
        guard let body = String(data: prefix, encoding: .utf8)?.lowercased() else { return false }
        if body.contains("captcha-delivery.com") { return true }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            ?? response.mimeType?.lowercased()
            ?? ""
        guard contentType.contains("text/html") else { return false }
        return body.contains("datadome")
            || body.contains("please enable javascript and disable any ad blocker")
    }

    private var blockedUntil: Date? { storedDate(DefaultsKey.blockedUntil) }

    private func storedDate(_ key: String) -> Date? {
        let value = defaults.double(forKey: key)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    private func clearGlobalBlock() {
        defaults.removeObject(forKey: DefaultsKey.blockedUntil)
        defaults.removeObject(forKey: DefaultsKey.blockedStatus)
        defaults.removeObject(forKey: DefaultsKey.blockedReason)
        trafficSafety = .ready
    }

    private func clampPersistedRateLimitStop() {
        guard let until = blockedUntil,
              defaults.string(forKey: DefaultsKey.blockedReason) != BlockReason.challenge else { return }
        let ceiling = now().addingTimeInterval(Self.rateLimitBackoff.cap)
        guard until > ceiling else { return }
        defaults.set(ceiling.timeIntervalSince1970, forKey: DefaultsKey.blockedUntil)
        logger.notice("Clamped a persisted SoundCloud traffic stop to the \(Int(Self.rateLimitBackoff.cap / 60)) minute ceiling")
    }

    private func enforceGates(_ context: SoundCloudRequestContext) throws {
        try enforceTrafficSafety()
        try enforceLifecycle(context)
        try enforceBackgroundPause(context)
        try enforcePlaybackPause(context)
        try enforceEndpointCooldown(context)
    }

    private func enforceLifecycle(_ context: SoundCloudRequestContext) throws {
        guard context.intent == .autonomous, !context.allowsBackground else { return }
        guard activity != .foreground else { return }
        rejectedRequests += 1
        throw SoundCloudGatewayError.autonomousWorkSuspended
    }

    private func enforceBackgroundPause(_ context: SoundCloudRequestContext) throws {
        guard context.intent == .autonomous, let until = backgroundWorkPausedUntil else { return }
        rejectedRequests += 1
        throw SoundCloudGatewayError.backgroundPaused(until: until)
    }

    private func enforcePlaybackPause(_ context: SoundCloudRequestContext) throws {
        guard context.lane == .streamResolution, let until = playbackResolutionPausedUntil else { return }
        rejectedRequests += 1
        throw APIError.rateLimited(resetAt: until)
    }

    private func enforceEndpointCooldown(_ context: SoundCloudRequestContext) throws {
        guard context.intent == .autonomous || Self.coolsDownAlone(context.lane) else { return }
        guard let failure = endpointFailures[context.lane] else { return }
        let current = now()
        if current < failure.until {
            rejectedRequests += 1
            throw SoundCloudGatewayError.endpointCoolingDown(lane: context.lane, until: failure.until)
        }
        endpointFailures[context.lane] = nil
    }

    private func admit(_ context: SoundCloudRequestContext, url: URL) async throws {
        guard context.lane != .authentication, SoundCloudHostPolicy.mayReceiveOAuth(url) else { return }
        while true {
            try enforceGates(context)
            budget.reconfigure(backgroundWorkPausedUntil == nil ? budgetConfiguration : .careful, now: now())
            let wait = budget.reserve(context.intent, now: now())
            if wait <= 0 { return }
            try await sleep(min(wait, 5))
        }
    }

    private func noteWireStart(_ context: SoundCloudRequestContext) {
        wireRequests += 1
        requestsByLane[context.lane, default: 0] += 1
    }

    private func cacheLifetime(url: URL, context: SoundCloudRequestContext) -> TimeInterval {
        SoundCloudCachePolicy.lifetime(
            for: url,
            lane: context.lane,
            intent: context.intent,
            currentUserID: SoundCloudAPI.credentials?.currentUser?.id
        )
    }

    private func observe(data: Data, response: HTTPURLResponse, context: SoundCloudRequestContext, method: String) {
        if Self.isBotChallenge(response: response, data: data) {
            recordChallenge(response: response, context: context)
            return
        }
        if response.statusCode == 429 {
            recordRateLimit(data: data, response: response, context: context)
            return
        }
        if (200..<400).contains(response.statusCode) {
            endpointFailures[context.lane] = nil
            if SoundCloudHostPolicy.mayReceiveOAuth(response.url ?? URL(fileURLWithPath: "/")) {
                if context.intent == .autonomous {
                    defaults.removeObject(forKey: DefaultsKey.backgroundRateLimitStrikes)
                } else {
                    defaults.removeObject(forKey: DefaultsKey.rateLimitStrikes)
                }
                defaults.removeObject(forKey: DefaultsKey.challengeStrikes)
            }
            if method != "GET", (200..<300).contains(response.statusCode) {
                let mutated = response.url
                responseCache.removeAll { SoundCloudCachePolicy.invalidates($0.url, afterMutationOf: mutated) }
            }
        } else if response.statusCode == 403 || response.statusCode >= 500 {
            recordFailure(context: context, response: response)
        }
    }

    private func recordChallenge(response: HTTPURLResponse, context: SoundCloudRequestContext) {
        let current = now()
        let ongoing = blockedUntil.map { $0 > current } ?? false
            && defaults.string(forKey: DefaultsKey.blockedReason) == BlockReason.challenge
        let recorded = defaults.integer(forKey: DefaultsKey.challengeStrikes)
        let strikes = ongoing ? max(0, recorded - 1) : recorded
        if !ongoing { defaults.set(recorded + 1, forKey: DefaultsKey.challengeStrikes) }
        var until = current.addingTimeInterval(Self.challengeBackoff.delay(attempt: strikes, unit: random()))
        if let retryAfter = Self.retryAfterDate(from: response, now: current) {
            until = max(until, min(retryAfter, current.addingTimeInterval(Self.maximumServerRetryAfter)))
        }
        let endpoint = response.url.map(SoundCloudEndpoint.template(for:)) ?? "unknown"
        let stop = recordGlobalBlock(statusCode: response.statusCode, response: response, preferredUntil: until, reason: BlockReason.challenge)
        logger.error("Bot challenge (HTTP \(response.statusCode)) from \(endpoint, privacy: .public) stopped SoundCloud traffic until \(stop)")
        logStop(.trafficStop, endpoint: endpoint, context: context, until: stop)
    }

    static func coolsDownAlone(_ lane: SoundCloudRequestLane) -> Bool {
        lane == .waveform || lane == .media || lane == .authentication
    }

    private func recordRateLimit(data: Data, response: HTTPURLResponse, context: SoundCloudRequestContext) {
        let current = now()
        let signal = SoundCloudRateLimitSignal.parse(data)
        let retryAfter = Self.retryAfterDate(from: response, now: current)
        let endpoint = response.url.map(SoundCloudEndpoint.template(for:)) ?? "unknown"

        if Self.coolsDownAlone(context.lane) {
            let previous = endpointFailures[context.lane]
            let ongoing = previous.map { $0.until > current } ?? false
            let failures = ongoing
                ? max(1, previous?.consecutiveFailures ?? 1)
                : min((previous?.consecutiveFailures ?? 0) + 1, 8)
            var until = current.addingTimeInterval(Self.laneRateLimitBackoff.delay(attempt: failures - 1, unit: random()))
            if let retryAfter {
                until = max(until, min(retryAfter, current.addingTimeInterval(Self.maximumServerRetryAfter)))
            }
            until = max(previous?.until ?? current, until)
            endpointFailures[context.lane] = EndpointFailure(consecutiveFailures: failures, until: until)
            logger.error("SoundCloud \(context.lane.rawValue, privacy: .public) lane paused after HTTP 429 from \(endpoint, privacy: .public) until \(until); other traffic is unaffected")
            logStop(.laneCooldown, endpoint: endpoint, context: context, until: until)
            return
        }

        if signal.isPlaysBucket || context.lane == .streamResolution {
            let backoffUntil = current.addingTimeInterval(Self.rateLimitBackoff.delay(attempt: 0, unit: random()))
            let until = min(
                retryAfter ?? signal.resetAt ?? backoffUntil,
                current.addingTimeInterval(Self.maximumPlaybackPause)
            )
            let effective = max(playbackResolutionPausedUntil ?? current, max(until, current.addingTimeInterval(60)))
            defaults.set(effective.timeIntervalSince1970, forKey: DefaultsKey.playbackPausedUntil)
            logger.error("Playback resolution paused after HTTP 429 from \(endpoint, privacy: .public) (bucket \(signal.bucket ?? "unknown", privacy: .public), intent \(context.intent.rawValue, privacy: .public)) until \(effective)")
            logStop(.playbackPause, endpoint: endpoint, context: context, until: effective)
            guard context.intent != .autonomous else { return }
            let briefStop = current.addingTimeInterval(Self.briefStopBackoff.delay(attempt: 0, unit: random()))
            let stop = recordGlobalBlock(statusCode: 429, response: response, preferredUntil: min(briefStop, effective), reason: BlockReason.rateLimit)
            logStop(.trafficStop, endpoint: endpoint, context: context, until: stop)
            return
        }

        let isBackground = context.intent == .autonomous
        let strikesKey = isBackground ? DefaultsKey.backgroundRateLimitStrikes : DefaultsKey.rateLimitStrikes
        let ongoingUntil = isBackground ? backgroundWorkPausedUntil : blockedUntil.flatMap { $0 > current ? $0 : nil }
        let recorded = defaults.integer(forKey: strikesKey)
        let strikes = ongoingUntil == nil ? recorded : max(0, recorded - 1)
        if ongoingUntil == nil { defaults.set(recorded + 1, forKey: strikesKey) }

        var until = current.addingTimeInterval(Self.rateLimitBackoff.delay(attempt: strikes, unit: random()))
        if let retryAfter {
            until = max(until, min(retryAfter, current.addingTimeInterval(Self.maximumServerRetryAfter)))
        } else if let reset = signal.resetAt {
            until = max(current.addingTimeInterval(60), min(until, reset))
        }
        let paused = max(backgroundWorkPausedUntil ?? current, until)
        defaults.set(paused.timeIntervalSince1970, forKey: DefaultsKey.backgroundPausedUntil)
        if isBackground {
            logger.error("Background SoundCloud work paused after HTTP 429 from \(endpoint, privacy: .public) (strike \(strikes + 1)) until \(paused); interactive requests are unaffected")
            logStop(.backgroundPause, endpoint: endpoint, context: context, until: paused)
            return
        }
        let stop = recordGlobalBlock(statusCode: 429, response: response, preferredUntil: until, reason: BlockReason.rateLimit)
        logger.error("Interactive HTTP 429 from \(endpoint, privacy: .public) (lane \(context.lane.rawValue, privacy: .public), intent \(context.intent.rawValue, privacy: .public), strike \(strikes + 1)) stopped SoundCloud traffic until \(stop)")
        logStop(.trafficStop, endpoint: endpoint, context: context, until: stop)
    }

    private func log(
        _ request: URLRequest,
        context: SoundCloudRequestContext,
        status: Int? = nil,
        duration: TimeInterval? = nil,
        bytes: Int? = nil,
        source: NetworkActivityEntry.Source,
        error: (any Error)? = nil,
        body: Data? = nil
    ) {
        guard let networkLog, let url = request.url else { return }
        let detail = [NetworkActivityLog.detail, Self.oauthErrorDetail(context: context, status: status, body: body)]
            .compactMap { $0 }
            .joined(separator: "; ")
        let allowsBackground = context.intent == .autonomous
            ? context.allowsBackground
            : context.intent == .playback || Self.coolsDownAlone(context.lane) || context.lane == .streamResolution
        networkLog.record(NetworkRequestRecord(
            feature: NetworkActivityLog.feature ?? NetworkFeature.soundCloud(path: url.path, lane: context.lane.rawValue),
            method: request.httpMethod?.uppercased() ?? "GET",
            url: url,
            lane: context.lane.rawValue,
            intent: context.intent.rawValue,
            status: status,
            duration: duration,
            bytes: bytes,
            source: source,
            error: error,
            allowsBackground: allowsBackground,
            issues: source == .held && Self.isBackoff(error) ? .backoff : [],
            detail: detail.isEmpty ? nil : detail
        ), now: now())
    }

    static func oauthErrorDetail(context: SoundCloudRequestContext, status: Int?, body: Data?) -> String? {
        guard context.lane == .authentication, let status, !(200..<300).contains(status), let body else { return nil }
        guard let code = SoundCloudTokenRefresh.oauthErrorCode(in: body) else { return "oauth error unreadable" }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz_-0123456789")
        guard code.count <= 40, code.allSatisfy({ allowed.contains($0) }) else { return "oauth error unreadable" }
        return "oauth error \(code)"
    }

    private func logStop(_ kind: NetworkActivityEntry.Kind, endpoint: String, context: SoundCloudRequestContext, until: Date) {
        networkLog?.recordStop(kind, endpoint: endpoint, lane: context.lane.rawValue, intent: context.intent.rawValue, until: until, now: now())
    }

    private static func isBackoff(_ error: (any Error)?) -> Bool {
        switch error {
        case let gateway as SoundCloudGatewayError: return gateway != .autonomousWorkSuspended
        case is APIError: return true
        default: return false
        }
    }

    nonisolated private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func recordFailure(context: SoundCloudRequestContext, response: HTTPURLResponse?) {
        guard context.intent == .autonomous else { return }
        let previous = endpointFailures[context.lane]?.consecutiveFailures ?? 0
        let failures = min(previous + 1, 8)
        let backoff = context.lane == .messaging
            ? SoundCloudBackoff(base: 30 * 60, cap: 24 * 60 * 60, jitter: 0.25)
            : SoundCloudBackoff(base: 60, cap: 60 * 60, jitter: 0.25)
        let delay = backoff.delay(attempt: failures - 1, unit: random())
        let retryAfter = response.flatMap { Self.retryAfterDate(from: $0, now: now()) }
        endpointFailures[context.lane] = EndpointFailure(
            consecutiveFailures: failures,
            until: max(retryAfter ?? now(), now().addingTimeInterval(delay))
        )
        if let until = endpointFailures[context.lane]?.until {
            logger.notice(
                "Endpoint lane \(context.lane.rawValue, privacy: .public) cooling down after \(failures) failure(s), until \(until)"
            )
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    static func requestKey(_ request: URLRequest) -> RequestKey {
        RequestKey(
            method: request.httpMethod?.uppercased() ?? "GET",
            url: request.url?.absoluteString ?? "",
            authorizationDigest: digest(request.value(forHTTPHeaderField: "Authorization")),
            bodyDigest: digest(request.httpBody.map { $0.base64EncodedString() })
        )
    }

    private static func digest(_ value: String?) -> String {
        guard let value else { return "" }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func retryAfterDate(from response: HTTPURLResponse, now: Date) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return now.addingTimeInterval(max(0, seconds))
        }
        return httpDateFormatter.date(from: value)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
