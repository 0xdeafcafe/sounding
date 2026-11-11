import Foundation
import Network

enum CompanionFailure: Equatable, Sendable {
    case notFound
    case localNetworkDenied
    case networkUnavailable
    case connectionLost
    case closed
    case notRecognised

    private static let policyDenied: Int32 = -65570

    static func classify(_ error: NWError?, fallback: CompanionFailure = .connectionLost) -> CompanionFailure {
        guard let error else { return fallback }
        switch error {
        case .dns(let code):
            if code == Self.policyDenied { return .localNetworkDenied }
            return .notFound
        case .tls:
            return .notRecognised
        case .posix(let code):
            switch code {
            case .ENETDOWN, .ENETUNREACH, .ENOTCONN:
                return .networkUnavailable
            case .EHOSTUNREACH, .EHOSTDOWN, .ETIMEDOUT, .ECONNREFUSED:
                return .notFound
            case .ECONNRESET, .ECONNABORTED, .EPIPE:
                return .connectionLost
            default:
                return fallback
            }
        default:
            return fallback
        }
    }

    func message(here: DeviceClass = .current) -> String {
        switch self {
        case .notFound:
            return "Make sure it’s awake and on the same Wi‑Fi network."
        case .localNetworkDenied:
            return "Turn on Local Network for Sounding in Settings."
        case .networkUnavailable:
            return "Connect this \(here.displayName) to Wi‑Fi."
        case .connectionLost, .closed:
            return "The connection dropped. Sounding keeps trying."
        case .notRecognised:
            return "It no longer recognises this \(here.displayName). Forget it here, then link it again."
        }
    }
}

enum LinkStatus: Equatable, Sendable {
    case connected
    case connecting
    case needsSignIn
    case available
    case unreachable(CompanionFailure)

    var title: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .needsSignIn: return "Needs Sign-In"
        case .available: return "Available"
        case .unreachable: return "Not Reachable"
        }
    }

    var isHealthy: Bool { self == .connected }
}

// MARK: - Liveness

enum CompanionHeartbeat {
    static let interval: TimeInterval = 5
    static let controllerStaleAfter: TimeInterval = 15
    static let peerStaleAfter: TimeInterval = 30
    static let handshakeTimeout: TimeInterval = 20

    static func isDue(lastSentAt: Date?, now: Date) -> Bool {
        guard let lastSentAt else { return true }
        return now.timeIntervalSince(lastSentAt) >= interval
    }

    static func controllerIsStale(lastFrameAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastFrameAt) > controllerStaleAfter
    }

    static func peerIsUnresponsive(isReady: Bool, sendsHeartbeats: Bool, connectedFor: TimeInterval, silentFor: TimeInterval) -> Bool {
        guard isReady else { return connectedFor > handshakeTimeout }
        return sendsHeartbeats && silentFor > peerStaleAfter
    }
}

// MARK: - Pending commands

struct CompanionCommandOutbox<Command> {
    static var lifetime: TimeInterval { 10 }
    static var capacity: Int { 32 }

    private struct Entry {
        let key: String?
        let enqueuedAt: Date
        let command: Command
    }

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    var nextExpiry: Date? {
        entries.map { $0.enqueuedAt.addingTimeInterval(Self.lifetime) }.min()
    }

    mutating func enqueue(_ command: Command, key: String? = nil, at now: Date) {
        expire(at: now)
        if let key { entries.removeAll { $0.key == key } }
        entries.append(Entry(key: key, enqueuedAt: now, command: command))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    @discardableResult
    mutating func expire(at now: Date) -> Int {
        let before = entries.count
        entries.removeAll { now.timeIntervalSince($0.enqueuedAt) > Self.lifetime }
        return before - entries.count
    }

    mutating func drain(at now: Date) -> [Command] {
        expire(at: now)
        defer { entries.removeAll() }
        return entries.map(\.command)
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

// MARK: - Connection phase

enum CompanionConnectionPhase: Equatable, Sendable {
    case live
    case connecting
    case unreachable

    static func resolve(isReachable: Bool, isLive: Bool, hasFailed: Bool) -> CompanionConnectionPhase {
        if isReachable, isLive { return .live }
        if hasFailed { return .unreachable }
        return .connecting
    }
}
