import Foundation

struct DeliveredOutsideAlert: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case signInRequest
        case nearbyLink
        case accountSignIn
    }

    let id: String
    let kind: Kind
    let recordName: String
    var device: String? = nil
    var createdAt: Date? = nil
    var expiresAt: Date? = nil
    let deliveredAt: Date
}

enum OutsideAlertSweep {
    enum RecordState: Equatable, Sendable {
        case live
        case resolved
        case gone
    }

    static func device(name: String?, kind: DeviceClass) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return SameAccountLinkOffer.identity(name: name, kind: kind)
    }

    static func isExpired(_ alert: DeliveredOutsideAlert, now: Date) -> Bool {
        switch alert.kind {
        case .signInRequest, .nearbyLink:
            guard let expiresAt = alert.expiresAt else { return false }
            return now >= expiresAt
        case .accountSignIn:
            guard let createdAt = alert.createdAt else { return false }
            return now.timeIntervalSince(createdAt) > AccountSignIn.freshness
        }
    }

    static func needsRecord(_ alert: DeliveredOutsideAlert, now: Date, resolvedDevices: Set<String>) -> Bool {
        !isExpired(alert, now: now) && !isResolved(alert, resolvedDevices: resolvedDevices)
    }

    static func stale(
        _ alerts: [DeliveredOutsideAlert],
        now: Date,
        records: [String: RecordState] = [:],
        resolvedDevices: Set<String> = []
    ) -> Set<String> {
        var stale = Set<String>()
        for alert in alerts {
            if isExpired(alert, now: now) || isResolved(alert, resolvedDevices: resolvedDevices) {
                stale.insert(alert.id)
                continue
            }
            switch records[alert.recordName] {
            case .resolved, .gone: stale.insert(alert.id)
            case .live, nil: break
            }
        }
        let current = alerts.filter { !stale.contains($0.id) && $0.kind != .accountSignIn }
        let perDevice = Dictionary(grouping: current.compactMap { alert in alert.device.map { ("\(alert.kind.rawValue)|\($0)", alert) } }, by: \.0)
        for group in perDevice.values.map({ $0.map(\.1) }) where group.count > 1 {
            guard let newest = group.max(by: { order($0) < order($1) }) else { continue }
            for alert in group where alert.id != newest.id { stale.insert(alert.id) }
        }
        return stale
    }

    private static func isResolved(_ alert: DeliveredOutsideAlert, resolvedDevices: Set<String>) -> Bool {
        guard alert.kind != .accountSignIn, let device = alert.device else { return false }
        return resolvedDevices.contains(device)
    }

    private static func order(_ alert: DeliveredOutsideAlert) -> (Date, Date, String) {
        (alert.createdAt ?? alert.deliveredAt, alert.deliveredAt, alert.id)
    }
}
