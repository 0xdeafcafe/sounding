import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
import IOKit.ps
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
}

// MARK: - Mac power

struct MacPowerSource: Equatable, Sendable {
    let fraction: Double?
    let isPluggedIn: Bool

    static func current() -> MacPowerSource? {
        #if os(macOS)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let capacity = description[kIOPSCurrentCapacityKey] as? Int
            let maximum = description[kIOPSMaxCapacityKey] as? Int
            let fraction = capacity.flatMap { current in maximum.flatMap { $0 > 0 ? Double(current) / Double($0) : nil } }
            let state = description[kIOPSPowerSourceStateKey] as? String
            return MacPowerSource(fraction: fraction, isPluggedIn: state == kIOPSACPowerValue)
        }
        return nil
        #else
        return nil
        #endif
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
}
