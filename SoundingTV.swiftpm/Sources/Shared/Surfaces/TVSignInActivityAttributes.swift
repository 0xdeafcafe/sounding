import ActivityKit
import Foundation

struct TVSignInActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case connecting
        case waitingForSoundCloud
        case done
        case failed

        var progress: Double {
            switch self {
            case .connecting: return 0.33
            case .waitingForSoundCloud: return 0.66
            case .done, .failed: return 1
            }
        }

        var line: String {
            switch self {
            case .connecting: return "Connecting…"
            case .waitingForSoundCloud: return "Waiting for SoundCloud…"
            case .done: return "Signed in"
            case .failed: return "Couldn’t sign in"
            }
        }

        var isFinished: Bool { self == .done || self == .failed }
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
    }

    var tvName: String
    var symbolName: String

    var title: String { "Signing in \(tvName)" }
}
