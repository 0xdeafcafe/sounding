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
