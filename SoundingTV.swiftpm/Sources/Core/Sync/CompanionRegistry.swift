import Foundation
import Combine

#if canImport(UIKit)
import UIKit
#endif

struct CompanionDeviceRecord: Sendable, Equatable, Codable {
    let deviceId: String
    let deviceClass: DeviceClass
    let displayName: String
    let accountId: String?
    let lastSeenAtMillis: Int64
    let conditions: DeviceConditions
    let appVersion: String
}

@MainActor
final class CompanionRegistry: ObservableObject {
    static let shared = CompanionRegistry()

    static let staleAfterMillis: Int64 = 14 * 24 * 60 * 60 * 1000

    private static let defaultsKey = "red.forbes.sounding.companionRegistry.v1"

    @Published private(set) var devices: [CompanionDeviceRecord] = [] {
        didSet { persist() }
    }

    private init() {
        devices = Self.filterStale(Self.loadPersisted())
    }

    var localDeviceId: String { DownloadManifestDeviceIdentity.deviceId() }

    var peers: [CompanionDeviceRecord] {
        devices
            .filter { $0.deviceId != localDeviceId }
            .sorted { $0.lastSeenAtMillis > $1.lastSeenAtMillis }
    }

    var peerClasses: [DeviceClass] {
        var seen = Set<DeviceClass>()
        var result: [DeviceClass] = []
        for peer in peers where !seen.contains(peer.deviceClass) {
            seen.insert(peer.deviceClass)
            result.append(peer.deviceClass)
        }
        return result
    }

    func adopt(_ records: [CompanionDeviceRecord]) {
        guard !DeviceSessionStore.hasLocalSignOut, !records.isEmpty else { return }
        var byId = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceId, $0) })
        for record in records {
            if let existing = byId[record.deviceId], existing.lastSeenAtMillis > record.lastSeenAtMillis {
                continue
            }
            byId[record.deviceId] = record
        }
        devices = Self.filterStale(Array(byId.values))
    }

    func forgetAll() {
        devices = []
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    @discardableResult
    func registerLocal() -> CompanionDeviceRecord {
        let record = localRecord()
        adopt([record])
        return record
    }

    func symbolName(fallback: DeviceClass) -> String {
        peerClasses.isEmpty ? fallback.symbolName : Self.symbolName(for: peerClasses)
    }

    static func symbolName(for classes: [DeviceClass]) -> String {
        let distinct = Set(classes)
        if distinct.count == 1, let only = distinct.first {
            return only.symbolName
        }
        return "point.3.filled.connected.trianglepath.dotted"
    }

    func localRecord() -> CompanionDeviceRecord {
        CompanionDeviceRecord(
            deviceId: DownloadManifestDeviceIdentity.deviceId(),
            deviceClass: DeviceClass.current,
            displayName: Self.localDisplayName(),
            accountId: SoundCloudCredentialSource.shared.currentUser?.id,
            lastSeenAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            conditions: Self.currentConditions(),
            appVersion: Self.currentAppVersion()
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func loadPersisted() -> [CompanionDeviceRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([CompanionDeviceRecord].self, from: data) else {
            return []
        }
        return records
    }

    private static func filterStale(_ records: [CompanionDeviceRecord]) -> [CompanionDeviceRecord] {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - staleAfterMillis
        return records
            .filter { $0.lastSeenAtMillis >= cutoff }
            .sorted { $0.lastSeenAtMillis > $1.lastSeenAtMillis }
    }

    private static func localDisplayName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(tvOS)
        return "Apple TV"
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif os(watchOS)
        return "Apple Watch"
        #else
        return DeviceClass.current.displayName
        #endif
    }

    private static func currentAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private static func currentConditions() -> DeviceConditions {
        let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        #if os(iOS) && canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryState = UIDevice.current.batteryState
        let level = UIDevice.current.batteryLevel
        let batteryFraction: Double? = level >= 0 ? Double(level) : nil
        let isPluggedIn = batteryState == .charging || batteryState == .full
        return DeviceConditions(
            isPluggedIn: isPluggedIn,
            batteryFraction: batteryFraction,
            isOnWiFi: true,
            isLowPowerMode: isLowPowerMode
        )
        #elseif os(tvOS)
        return DeviceConditions(
            isPluggedIn: true,
            batteryFraction: nil,
            isOnWiFi: true,
            isLowPowerMode: isLowPowerMode
        )
        #elseif os(macOS)
        let power = MacPowerSource.current()
        return DeviceConditions(
            isPluggedIn: power?.isPluggedIn ?? true,
            batteryFraction: power?.fraction,
            isOnWiFi: true,
            isLowPowerMode: isLowPowerMode
        )
        #else
        return DeviceConditions.unknown
        #endif
    }
}
