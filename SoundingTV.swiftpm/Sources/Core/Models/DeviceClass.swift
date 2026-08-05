import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum DeviceClass: String, Codable, Sendable, Hashable, CaseIterable {
    case tv
    case phone
    case pad
    case mac
    case watch

    var displayName: String {
        switch self {
        case .tv: return "Apple TV"
        case .phone: return "iPhone"
        case .pad: return "iPad"
        case .mac: return "Mac"
        case .watch: return "Apple Watch"
        }
    }

    var symbolName: String {
        switch self {
        case .tv: return "appletv.fill"
        case .phone: return "iphone"
        case .pad: return "ipad"
        case .mac: return "desktopcomputer"
        case .watch: return "applewatch"
        }
    }

    var canPresentSignIn: Bool {
        switch self {
        case .phone, .pad: return true
        case .tv, .mac, .watch: return false
        }
    }

    var hasBattery: Bool {
        switch self {
        case .phone, .pad, .watch: return true
        case .tv: return false
        case .mac: return true
        }
    }
}

// MARK: - Resolution

extension DeviceClass {
    static let current: DeviceClass = resolveCurrent()

    private static func resolveCurrent() -> DeviceClass {
        #if os(tvOS)
        return .tv
        #elseif os(watchOS)
        return .watch
        #elseif os(macOS)
        return .mac
        #elseif os(iOS)
        return hardwareModelIdentifier().hasPrefix("iPad") ? .pad : .phone
        #else
        return .phone
        #endif
    }

    private static func hardwareModelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return "" }
        if let terminator = buffer.firstIndex(of: 0) {
            buffer.removeSubrange(terminator...)
        }
        return String(decoding: buffer, as: UTF8.self)
    }
}

// MARK: - Conditions

struct DeviceConditions: Codable, Sendable, Equatable {
    var isPluggedIn: Bool
    var batteryFraction: Double?
    var isOnWiFi: Bool
    var isLowPowerMode: Bool

    static let unknown = DeviceConditions(
        isPluggedIn: false,
        batteryFraction: nil,
        isOnWiFi: true,
        isLowPowerMode: false
    )

    var isBatteryConstrained: Bool {
        guard !isPluggedIn else { return false }
        guard let batteryFraction else { return false }
        return batteryFraction < 0.3
    }
}

// MARK: - Workshop capability

enum WorkshopJob: String, Codable, Sendable, CaseIterable {
    case download
    case metadataAnalysis
    case deepAnalysis
    case artworkPrewarm
}

extension DeviceClass {
    func supports(_ job: WorkshopJob) -> Bool {
        switch (self, job) {
        case (.watch, _):
            return false
        case (.tv, .deepAnalysis):
            return false
        case (.pad, .deepAnalysis), (.phone, .deepAnalysis), (.mac, .deepAnalysis):
            return true
        default:
            return true
        }
    }

    fileprivate var baseAffinity: Int {
        switch self {
        case .tv: return 120
        case .mac: return 70
        case .pad: return 50
        case .phone: return 40
        case .watch: return 0
        }
    }
}

enum WorkshopCapability {
    static func score(
        deviceClass: DeviceClass,
        conditions: DeviceConditions,
        job: WorkshopJob
    ) -> Int? {
        guard deviceClass.supports(job) else { return nil }

        var score = deviceClass.baseAffinity

        if job == .deepAnalysis, deviceClass == .mac {
            score += 40
        }

        if conditions.isPluggedIn, deviceClass.hasBattery {
            score += 40
        }
        if conditions.isBatteryConstrained {
            score -= 60
        }
        if conditions.isLowPowerMode {
            score -= 25
        }
        if !conditions.isOnWiFi, job == .download || job == .artworkPrewarm {
            score -= 50
        }

        return max(score, 0)
    }
}
