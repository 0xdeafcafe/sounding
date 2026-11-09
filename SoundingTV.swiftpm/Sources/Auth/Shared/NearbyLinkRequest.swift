import CloudKit
import CryptoKit
import Foundation
import Security

struct NearbyLinkRequest: Equatable, Hashable, Sendable, Identifiable {
    static let recordType = "NearbyLinkRequest"
    static let recordPrefix = "nearbylink-"
    static let subscriptionID = "nearby-link-requests-v1"
    static let withdrawalSubscriptionID = "nearby-link-requests-gone-v1"
    static let category = "LINK_REQUEST"
    static let titleKey = "LINK_REQUEST_TITLE"
    static let bodyKey = "LINK_REQUEST_BODY"
    static let lifetime: TimeInterval = 600
    static let maximumNameLength = 64
    static let maximumLinked = 16

    enum Field {
        static let tvName = "tvName"
        static let tvKind = "tvKind"
        static let tvTag = "tvTag"
        static let accountTag = "accountTag"
        static let linkedDevices = "linkedDevices"
        static let createdAt = "createdAt"
        static let expiresAt = "expiresAt"
        static let all = [tvName, tvKind, tvTag, accountTag, linkedDevices, createdAt, expiresAt]
    }

    enum Verdict: Equatable, Sendable {
        case show
        case expired
        case otherAccount
        case linked

        var allowsLinking: Bool { self == .show || self == .expired }
    }

    let nonce: String
    let tvName: String
    let tvKind: DeviceClass
    let tvTag: String
    let accountTag: String
    let linkedDevices: [String]
    let createdAt: Date
    let expiresAt: Date

    var id: String { nonce }
    var recordName: String { Self.recordPrefix + nonce }

    init?(
        nonce: String,
        tvName: String,
        tvKind: DeviceClass = .tv,
        tvTag: String,
        accountTag: String,
        linkedDevices: [String] = [],
        createdAt: Date,
        expiresAt: Date? = nil
    ) {
        let name = tvName.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard SignInRequest.isValidRendezvous(nonce), !name.isEmpty, !tvTag.isEmpty, !accountTag.isEmpty else { return nil }
        let latest = createdAt.addingTimeInterval(Self.lifetime)
        let expiry = min(expiresAt ?? latest, latest)
        guard expiry > createdAt else { return nil }
        self.nonce = nonce
        self.tvName = String(name.prefix(Self.maximumNameLength))
        self.tvKind = tvKind
        self.tvTag = tvTag
        self.accountTag = accountTag
        self.linkedDevices = Array(linkedDevices.filter { !$0.isEmpty }.prefix(Self.maximumLinked))
        self.createdAt = createdAt
        self.expiresAt = expiry
    }

    static func make(
        tvName: String,
        tvDeviceId: String,
        accountId: String,
        linkedDeviceIds: [String],
        tvKind: DeviceClass = .current,
        now: Date = .now
    ) -> NearbyLinkRequest? {
        guard let nonce = SignInRequest.makeRendezvous(), !accountId.isEmpty else { return nil }
        return NearbyLinkRequest(
            nonce: nonce,
            tvName: tvName,
            tvKind: tvKind,
            tvTag: tvTag(deviceId: tvDeviceId),
            accountTag: AccountSignIn.accountTag(userId: accountId),
            linkedDevices: linkedDeviceIds.map { deviceTag(deviceId: $0) },
            createdAt: now
        )
    }

    static func tvTag(deviceId: String) -> String {
        digest("Sounding-NearbyLink-TV-v1", deviceId.lowercased(), length: 24)
    }

    static func deviceTag(deviceId: String) -> String {
        digest("Sounding-NearbyLink-Device-v1", deviceId.lowercased(), length: 16)
    }

    private static func digest(_ parts: String..., length: Int) -> String {
        let hash = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(length))
    }

    func isExpired(at now: Date = .now) -> Bool {
        now >= expiresAt || now < createdAt.addingTimeInterval(-120)
    }

    func verdict(
        localDeviceId: String,
        currentUserId: String?,
        isSignedOut: Bool,
        linkedIdentities: Set<String> = [],
        now: Date = .now
    ) -> Verdict {
        if isExpired(at: now) { return .expired }
        if isSignedOut { return .otherAccount }
        if let currentUserId, AccountSignIn.accountTag(userId: currentUserId) != accountTag { return .otherAccount }
        if !localDeviceId.isEmpty, linkedDevices.contains(Self.deviceTag(deviceId: localDeviceId)) { return .linked }
        if linkedIdentities.contains(SameAccountLinkOffer.identity(name: tvName, kind: tvKind)) { return .linked }
        return .show
    }

    init?(fields: [String: Any]) {
        guard let name = fields[Field.tvName] as? String,
              let tvTag = fields[Field.tvTag] as? String,
              let accountTag = fields[Field.accountTag] as? String,
              let created = Self.date(fields[Field.createdAt]) else { return nil }
        let nonce = (fields["nonce"] as? String) ?? String(repeating: "0", count: SignInRequest.rendezvousLength)
        let kind = (fields[Field.tvKind] as? String).flatMap(DeviceClass.init(rawValue:)) ?? .tv
        let linked = (fields[Field.linkedDevices] as? String).map { $0.split(separator: ",").map(String.init) } ?? []
        self.init(
            nonce: nonce,
            tvName: name,
            tvKind: kind,
            tvTag: tvTag,
            accountTag: accountTag,
            linkedDevices: linked,
            createdAt: created,
            expiresAt: Self.date(fields[Field.expiresAt])
        )
    }

    init?(record: CKRecord) {
        guard record.recordType == Self.recordType else { return nil }
        var fields: [String: Any] = [:]
        for key in Field.all { fields[key] = record[key] }
        if let nonce = Self.nonce(fromRecordName: record.recordID.recordName) { fields["nonce"] = nonce }
        self.init(fields: fields)
    }

    init?(remoteNotification userInfo: [AnyHashable: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              notification.subscriptionID == Self.subscriptionID,
              var fields = notification.recordFields else { return nil }
        if let name = notification.recordID?.recordName, let nonce = Self.nonce(fromRecordName: name) { fields["nonce"] = nonce }
        self.init(fields: fields)
    }

    static func nonce(fromRecordName name: String) -> String? {
        guard name.hasPrefix(recordPrefix) else { return nil }
        let nonce = String(name.dropFirst(recordPrefix.count))
        return SignInRequest.isValidRendezvous(nonce) ? nonce : nil
    }

    func record(zone: CKRecordZone.ID = .default) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: recordName, zoneID: zone))
        record[Field.tvName] = tvName as CKRecordValue
        record[Field.tvKind] = tvKind.rawValue as CKRecordValue
        record[Field.tvTag] = tvTag as CKRecordValue
        record[Field.accountTag] = accountTag as CKRecordValue
        record[Field.linkedDevices] = linkedDevices.joined(separator: ",") as CKRecordValue
        record[Field.createdAt] = createdAt as CKRecordValue
        record[Field.expiresAt] = expiresAt as CKRecordValue
        return record
    }

    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
    }
}

struct NearbyLinkSnooze: Equatable, Sendable {
    static let recordType = "NearbyLinkSnooze"

    enum Field {
        static let tvTag = "tvTag"
        static let snoozedAt = "snoozedAt"
    }

    let tvTag: String
    let snoozedAt: Date

    static func recordName(tvTag: String) -> String { "nearbylink-snooze-\(tvTag)" }

    static func recordID(tvTag: String, zone: CKRecordZone.ID = .default) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(tvTag: tvTag), zoneID: zone)
    }

    init(tvTag: String, snoozedAt: Date) {
        self.tvTag = tvTag
        self.snoozedAt = snoozedAt
    }

    init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
              let tag = record[Field.tvTag] as? String,
              let date = record[Field.snoozedAt] as? Date else { return nil }
        self.init(tvTag: tag, snoozedAt: date)
    }

    func record(zone: CKRecordZone.ID = .default) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: Self.recordID(tvTag: tvTag, zone: zone))
        record[Field.tvTag] = tvTag as CKRecordValue
        record[Field.snoozedAt] = snoozedAt as CKRecordValue
        return record
    }
}

enum NearbyLinkRequestPolicy {
    static let throttle: TimeInterval = 12 * 3_600
    static let snoozeCooldown: TimeInterval = 12 * 3_600
    static let awayGap: TimeInterval = 30 * 60

    enum Decision: Equatable, Sendable {
        case post
        case notNeeded
        case throttled
        case snoozed
    }

    enum Withdrawal: Equatable, Sendable {
        case keep
        case linked
        case away
        case expired
    }

    static func hasReason(
        isSignedIn: Bool,
        isActive: Bool,
        isPairing: Bool,
        seesUnlinkedPhone: Bool,
        linkedDeviceCount: Int
    ) -> Bool {
        isSignedIn && isActive && !isPairing && (seesUnlinkedPhone || linkedDeviceCount == 0)
    }

    static func decide(
        now: Date,
        hasReason: Bool,
        lastPostedAt: Date?,
        snoozedAt: Date?,
        lastAbsence: DateInterval?
    ) -> Decision {
        guard hasReason else { return .notNeeded }
        if let lastPostedAt, now >= lastPostedAt, now.timeIntervalSince(lastPostedAt) < throttle { return .throttled }
        if let snoozedAt {
            if now.timeIntervalSince(snoozedAt) < snoozeCooldown { return .snoozed }
            guard let lastAbsence, lastAbsence.start >= snoozedAt, lastAbsence.duration >= awayGap else { return .snoozed }
        }
        return .post
    }

    static func withdrawal(
        expiresAt: Date,
        now: Date,
        isActive: Bool,
        isSignedIn: Bool,
        linkedSincePosting: Bool
    ) -> Withdrawal {
        if linkedSincePosting { return .linked }
        if !isActive || !isSignedIn { return .away }
        if now >= expiresAt { return .expired }
        return .keep
    }
}

struct NearbyLinkAbsence: Codable, Equatable, Sendable {
    var awaySince: Date?
    var lastAbsence: DateInterval?

    mutating func wentAway(at now: Date) {
        if awaySince == nil { awaySince = now }
    }

    mutating func cameBack(at now: Date) {
        guard let since = awaySince else { return }
        awaySince = nil
        guard now > since, now.timeIntervalSince(since) >= NearbyLinkRequestPolicy.awayGap else { return }
        lastAbsence = DateInterval(start: since, end: now)
    }
}
