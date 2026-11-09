import Foundation

enum HeavyWorkUrgency: Int, Codable, Sendable, Comparable {
    case background = 0
    case user = 1

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum HeavyWorkPause: String, Codable, Sendable, Equatable {
    case lowPower
    case thermal
    case battery
    case cellular
    case playback
    case listening
    case rateLimited

    var label: String {
        switch self {
        case .lowPower: return "paused for Low Power Mode"
        case .thermal: return "paused while the device cools"
        case .battery: return "paused on battery"
        case .cellular: return "paused on cellular"
        case .playback: return "paused while streaming"
        case .listening: return "paused while playing"
        case .rateLimited: return "paused by SoundCloud"
        }
    }
}

struct HeavyWorkConditions: Equatable, Sendable {
    var isLowPowerMode = false
    var isThermallyLimited = false
    var isOnBattery = false
    var isOnCellular = false
    var playbackNeedsNetwork = false

    func pause(for policy: HeavyWorkPolicy) -> HeavyWorkPause? {
        if isLowPowerMode { return .lowPower }
        if isThermallyLimited { return .thermal }
        if policy.needsNetwork, isOnCellular { return .cellular }
        if policy.needsNetwork, playbackNeedsNetwork { return .playback }
        if policy.pausesOnBattery, isOnBattery { return .battery }
        return nil
    }
}

struct HeavyWorkPolicy: Equatable, Sendable {
    var stagger: TimeInterval
    var jitter: TimeInterval
    var backoffBase: TimeInterval
    var backoffCap: TimeInterval
    var needsNetwork: Bool
    var pausesOnBattery: Bool

    static let downloads = HeavyWorkPolicy(
        stagger: 4, jitter: 3, backoffBase: 120, backoffCap: 3600, needsNetwork: true, pausesOnBattery: false
    )

    static let analysis = HeavyWorkPolicy(
        stagger: 3, jitter: 3, backoffBase: 60, backoffCap: 3600, needsNetwork: false, pausesOnBattery: false
    )

    static let immediate = HeavyWorkPolicy(
        stagger: 0, jitter: 0, backoffBase: 1, backoffCap: 1, needsNetwork: false, pausesOnBattery: false
    )

    func gap(random unit: Double) -> TimeInterval {
        stagger + jitter * Self.clamp(unit)
    }

    func backoff(strikes: Int, random unit: Double) -> TimeInterval {
        let exponent = Double(max(0, strikes - 1))
        let base = min(backoffCap, backoffBase * pow(2, min(exponent, 20)))
        return base * (0.9 + 0.2 * Self.clamp(unit))
    }

    static func clamp(_ unit: Double) -> Double { min(max(unit, 0), 1) }
}

enum HeavyWorkGate: Equatable, Sendable {
    case go
    case wait(until: Date)
    case paused(HeavyWorkPause, until: Date?)
}

struct HeavyWorkPacer: Codable, Equatable, Sendable {
    private(set) var nextStartAt: Date?
    private(set) var backoffUntil: Date?
    private(set) var strikes = 0

    init() {}

    func gate(
        _ urgency: HeavyWorkUrgency,
        now: Date,
        conditions: HeavyWorkConditions,
        policy: HeavyWorkPolicy
    ) -> HeavyWorkGate {
        if let backoffUntil, backoffUntil > now {
            return .paused(.rateLimited, until: backoffUntil)
        }
        guard urgency == .background else { return .go }
        if let pause = conditions.pause(for: policy) {
            return .paused(pause, until: nil)
        }
        if let nextStartAt, nextStartAt > now {
            return .wait(until: nextStartAt)
        }
        return .go
    }

    mutating func finished(now: Date, policy: HeavyWorkPolicy, random: Double) {
        strikes = 0
        if let backoffUntil, backoffUntil <= now { self.backoffUntil = nil }
        nextStartAt = now.addingTimeInterval(policy.gap(random: random))
    }

    mutating func rateLimited(now: Date, retryAfter: TimeInterval?, policy: HeavyWorkPolicy, random: Double) {
        strikes += 1
        let wait: TimeInterval
        if let retryAfter, retryAfter > 0 {
            wait = retryAfter + policy.jitter * HeavyWorkPolicy.clamp(random)
        } else {
            wait = policy.backoff(strikes: strikes, random: random)
        }
        let until = now.addingTimeInterval(wait)
        backoffUntil = max(backoffUntil ?? until, until)
        nextStartAt = backoffUntil
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data?) -> HeavyWorkPacer? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(HeavyWorkPacer.self, from: data)
    }
}

enum HeavyWorkOrder {
    static func next<Key>(_ keys: [Key], urgency: (Key) -> HeavyWorkUrgency) -> Key? {
        var best: Key?
        var bestUrgency = HeavyWorkUrgency.background
        for key in keys {
            let value = urgency(key)
            if best == nil || value > bestUrgency {
                best = key
                bestUrgency = value
            }
        }
        return best
    }
}

struct HeavyWorkProgress: Equatable, Sendable {
    var done = 0
    var total = 0
    var isRunning = false
    var pause: HeavyWorkPause?

    var isActive: Bool { total > 0 && done < total }

    var position: Int { min(total, done + (isRunning ? 1 : 0)) }

    func label(verb: String) -> String? {
        guard isActive else { return nil }
        let base = "\(verb) \(max(1, position).formatted()) of \(total.formatted())"
        guard let pause else { return base }
        return "\(base) · \(pause.label)"
    }
}
