import Foundation

enum SoundCloudEndpoint {
    static func isAPIHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "api-v2.soundcloud.com" || host == "api.soundcloud.com" || host == "secure.soundcloud.com"
    }

    static func template(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let prefix: String
        switch host {
        case "api-v2.soundcloud.com": prefix = "v2"
        case "api.soundcloud.com": prefix = "api"
        case "secure.soundcloud.com": prefix = "auth"
        default:
            if host.hasSuffix("sndcdn.com") || host.hasSuffix("soundcloud.cloud") {
                prefix = "cdn:" + (host.split(separator: ".").first.map(String.init) ?? host)
            } else {
                prefix = host
            }
        }
        let components = url.path.split(separator: "/").map(String.init)
        if prefix.hasPrefix("cdn:") {
            return prefix + "/" + (url.pathExtension.isEmpty ? "*" : "*." + url.pathExtension)
        }
        if components.first == "media" {
            return prefix + "/media/:urn/…"
        }
        let normalized = components.map { component -> String in
            if component.allSatisfy(\.isNumber) { return ":id" }
            if component.contains("soundcloud:") || component.contains("soundcloud%3A") { return ":urn" }
            if component.count >= 20, component.contains(where: \.isNumber) { return ":key" }
            return component
        }
        var template = prefix + "/" + normalized.joined(separator: "/")
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           query.contains(where: { $0.name == "ids" }) {
            template += "?ids"
        }
        return template
    }

    private static let secretQueryNames: Set<String> = ["oauth_token", "access_token", "refresh_token", "client_secret", "code"]

    static func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.queryItems = components.queryItems?.map { item in
            secretQueryNames.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: "redacted")
                : item
        }
        return components.url?.absoluteString ?? url.absoluteString
    }
}

struct SoundCloudBackoff: Sendable {
    let base: TimeInterval
    let cap: TimeInterval
    let jitter: Double

    init(base: TimeInterval, cap: TimeInterval, jitter: Double = 0.5) {
        self.base = base
        self.cap = cap
        self.jitter = min(max(jitter, 0), 1)
    }

    func delay(attempt: Int, unit: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponent = Double(max(0, attempt))
        let ceiling = min(cap, base * pow(2, min(exponent, 30)))
        let spread = ceiling * jitter
        return ceiling - spread + spread * min(max(unit, 0), 1)
    }

    func duration(attempt: Int, unit: Double = Double.random(in: 0...1)) -> Duration {
        .milliseconds(Int64((delay(attempt: attempt, unit: unit) * 1000).rounded()))
    }
}

struct SoundCloudRequestBudget: Sendable {
    struct Configuration: Equatable, Sendable {
        var capacity: Double
        var refillPerSecond: Double
        var autonomousCapacity: Double
        var autonomousRefillPerSecond: Double
        var autonomousReserve: Double
        var hourlyCapacity: Int = 900
        var autonomousHourlyCapacity: Int = 180

        static let standard = Configuration(
            capacity: 6,
            refillPerSecond: 0.5,
            autonomousCapacity: 2,
            autonomousRefillPerSecond: 1.0 / 6.0,
            autonomousReserve: 3,
            hourlyCapacity: 900,
            autonomousHourlyCapacity: 180
        )

        static let careful = Configuration(
            capacity: 2,
            refillPerSecond: 0.2,
            autonomousCapacity: 0,
            autonomousRefillPerSecond: 0,
            autonomousReserve: 2,
            hourlyCapacity: 900,
            autonomousHourlyCapacity: 0
        )
    }

    static let window: TimeInterval = 60 * 60

    private(set) var configuration: Configuration
    private(set) var tokens: Double
    private(set) var autonomousTokens: Double
    private var updatedAt: Date
    private(set) var admitted: [Date] = []
    private(set) var admittedAutonomous: [Date] = []

    init(configuration: Configuration = .standard, now: Date = Date()) {
        self.configuration = configuration
        tokens = configuration.capacity
        autonomousTokens = configuration.autonomousCapacity
        updatedAt = now
    }

    mutating func reconfigure(_ configuration: Configuration, now: Date) {
        guard configuration != self.configuration else { return }
        refill(now: now)
        self.configuration = configuration
        tokens = min(tokens, configuration.capacity)
        autonomousTokens = min(autonomousTokens, configuration.autonomousCapacity)
    }

    mutating func reserve(_ intent: SoundCloudRequestIntent, now: Date) -> TimeInterval {
        refill(now: now)
        prune(now: now)
        switch intent {
        case .userInitiated, .playback:
            let hourlyWait = windowWait(admitted, limit: configuration.hourlyCapacity, now: now)
            if tokens >= 1, hourlyWait <= 0 {
                tokens -= 1
                admitted.append(now)
                return 0
            }
            return max(wait(for: 1 - tokens, rate: configuration.refillPerSecond), hourlyWait, 0.05)
        case .autonomous:
            let needed = configuration.autonomousReserve + 1
            let hourlyWait = max(
                windowWait(admittedAutonomous, limit: configuration.autonomousHourlyCapacity, now: now),
                windowWait(admitted, limit: configuration.hourlyCapacity * 2 / 3, now: now)
            )
            if tokens >= needed, autonomousTokens >= 1, hourlyWait <= 0 {
                tokens -= 1
                autonomousTokens -= 1
                admitted.append(now)
                admittedAutonomous.append(now)
                return 0
            }
            let sharedWait = wait(for: needed - tokens, rate: configuration.refillPerSecond)
            let ownWait = wait(for: 1 - autonomousTokens, rate: configuration.autonomousRefillPerSecond)
            return max(sharedWait, ownWait, hourlyWait, 0.05)
        }
    }

    func admittedInLastHour(now: Date) -> Int {
        admitted.filter { now.timeIntervalSince($0) < Self.window }.count
    }

    private mutating func prune(now: Date) {
        let horizon = now.addingTimeInterval(-Self.window)
        if let index = admitted.firstIndex(where: { $0 > horizon }) {
            admitted.removeFirst(index)
        } else {
            admitted.removeAll()
        }
        if let index = admittedAutonomous.firstIndex(where: { $0 > horizon }) {
            admittedAutonomous.removeFirst(index)
        } else {
            admittedAutonomous.removeAll()
        }
    }

    private func windowWait(_ log: [Date], limit: Int, now: Date) -> TimeInterval {
        guard log.count >= limit else { return 0 }
        guard limit > 0 else { return 60 }
        let release = log[log.count - limit].addingTimeInterval(Self.window)
        return max(0.05, release.timeIntervalSince(now))
    }

    private mutating func refill(now: Date) {
        let elapsed = max(0, now.timeIntervalSince(updatedAt))
        updatedAt = max(updatedAt, now)
        tokens = min(configuration.capacity, tokens + elapsed * configuration.refillPerSecond)
        autonomousTokens = min(
            configuration.autonomousCapacity,
            autonomousTokens + elapsed * configuration.autonomousRefillPerSecond
        )
    }

    private func wait(for deficit: Double, rate: Double) -> TimeInterval {
        guard deficit > 0 else { return 0 }
        guard rate > 0 else { return 60 }
        return deficit / rate
    }
}

enum SoundCloudCachePolicy {
    static func lifetime(
        for url: URL,
        lane: SoundCloudRequestLane,
        intent: SoundCloudRequestIntent,
        currentUserID: String?
    ) -> TimeInterval {
        switch lane {
        case .waveform: return 24 * 60 * 60
        case .media, .social, .authentication: return 0
        case .streamResolution: return 10
        case .messaging: return 30
        case .metadata, .feed, .followers: break
        }
        guard SoundCloudEndpoint.isAPIHost(url.host ?? "") else { return 0 }
        let path = url.path.split(separator: "/").map(String.init)
        let personal: TimeInterval = intent == .autonomous ? 5 * 60 : 60
        guard let head = path.first else { return 0 }
        switch head {
        case "me", "stream":
            return personal
        case "mixed-selections", "charts":
            return 30 * 60
        case "search", "resolve":
            return 5 * 60
        case "tracks":
            if path.count >= 3, path[2] == "comments" { return 3 * 60 }
            return 10 * 60
        case "playlists", "system-playlists":
            return 10 * 60
        case "users":
            guard path.count >= 2 else { return 0 }
            if path.count == 2 { return 10 * 60 }
            if path.count == 4, path[2] == "followings" { return 10 * 60 }
            let isCurrentUser = currentUserID.map { $0 == path[1] } ?? false
            return isCurrentUser ? personal : 5 * 60
        default:
            return 60
        }
    }

    static func cachesNotFound(_ url: URL) -> Bool {
        let path = url.path.split(separator: "/").map(String.init)
        return path.count == 4 && path[0] == "users" && path[2] == "followings"
    }

    static func isPlayHistory(_ url: URL) -> Bool {
        guard SoundCloudEndpoint.isAPIHost(url.host ?? "") else { return false }
        let path = url.path.split(separator: "/").map(String.init)
        return path.count >= 2 && path[0] == "me" && path[1] == "play-history"
    }

    static func invalidates(_ cached: URL, afterMutationOf mutated: URL?) -> Bool {
        if let mutated, isPlayHistory(mutated) { return isPlayHistory(cached) }
        return !survivesMutation(cached)
    }

    static func survivesMutation(_ url: URL) -> Bool {
        guard SoundCloudEndpoint.isAPIHost(url.host ?? "") else { return true }
        let path = url.path.split(separator: "/").map(String.init)
        switch path.first {
        case "mixed-selections", "charts", "search", "system-playlists": return true
        case "tracks": return path.count <= 2 || path[2] == "related"
        default: return false
        }
    }
}

struct SoundCloudRateLimitSignal: Equatable, Sendable {
    let bucket: String?
    let resetAt: Date?

    var isPlaysBucket: Bool { bucket?.lowercased() == "plays" }

    static func parse(_ data: Data) -> SoundCloudRateLimitSignal {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = root["errors"] as? [[String: Any]] else {
            return SoundCloudRateLimitSignal(bucket: nil, resetAt: nil)
        }
        var bucket: String?
        var reset: String?
        for error in errors {
            guard let meta = error["meta"] as? [String: Any] else { continue }
            if bucket == nil, let limit = meta["rate_limit"] as? [String: Any] {
                bucket = limit["name"] as? String
            }
            if reset == nil { reset = meta["reset_time"] as? String }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss Z"
        return SoundCloudRateLimitSignal(bucket: bucket, resetAt: reset.flatMap(formatter.date(from:)))
    }
}

enum SoundCloudSignedURLExpiry {
    static func expiry(of url: URL) -> Date? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        for item in items {
            switch item.name.lowercased() {
            case "expires", "expiry", "exp":
                if let value = item.value.flatMap(TimeInterval.init) { return Date(timeIntervalSince1970: value) }
            case "policy":
                if let date = item.value.flatMap(policyExpiry) { return date }
            default:
                continue
            }
        }
        return nil
    }

    private static func policyExpiry(_ encoded: String) -> Date? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "=")
            .replacingOccurrences(of: "~", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #""AWS:EpochTime"\s*:\s*\d+"#, options: .regularExpression) else { return nil }
        let digits = text[range].split(separator: ":").last?.filter(\.isNumber) ?? ""
        return TimeInterval(String(digits)).map(Date.init(timeIntervalSince1970:))
    }
}
