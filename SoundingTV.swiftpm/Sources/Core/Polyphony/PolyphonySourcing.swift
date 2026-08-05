import Foundation

enum PolyphonySourcing: String, Codable, Sendable, CaseIterable {
    case ownAccount
    case leaderCredentials
    case leaderRelay

    var displayName: String {
        switch self {
        case .ownAccount: return "Own account"
        case .leaderCredentials: return "Leader's account"
        case .leaderRelay: return "Relayed from leader"
        }
    }

    var explanation: String {
        switch self {
        case .ownAccount:
            return "This device streams from SoundCloud using its own account and its own network connection."
        case .leaderCredentials:
            return "This device streams from SoundCloud using the leader's account, so it doesn't need its own sign-in."
        case .leaderRelay:
            return "The leader downloads the audio once and sends it to this device, so this device doesn't use its own network connection."
        }
    }
}

extension PolyphonySourcing {
    static func propose(
        conditions: DeviceConditions,
        deviceClass: DeviceClass,
        isSignedIn: Bool
    ) -> PolyphonySourcing {
        if !conditions.isOnWiFi {
            return .leaderRelay
        }
        let batteryConstrained = deviceClass.hasBattery && (conditions.isBatteryConstrained || conditions.isLowPowerMode)
        if batteryConstrained {
            return .leaderCredentials
        }
        if !isSignedIn {
            return .leaderCredentials
        }
        return .ownAccount
    }

    static func confirm(
        proposal: PolyphonySourcing,
        leaderCanRelay: Bool,
        leaderWillShareCredentials: Bool
    ) -> PolyphonySourcing {
        switch proposal {
        case .ownAccount:
            return .ownAccount
        case .leaderCredentials:
            if leaderWillShareCredentials { return .leaderCredentials }
            if leaderCanRelay { return .leaderRelay }
            return .ownAccount
        case .leaderRelay:
            if leaderCanRelay { return .leaderRelay }
            if leaderWillShareCredentials { return .leaderCredentials }
            return .ownAccount
        }
    }
}
