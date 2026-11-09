import CloudKit
import Foundation
import Security

struct SignInRequest: Equatable, Hashable, Sendable, Identifiable {
    static let recordType = "SignInRequest"
    static let lifetime: TimeInterval = 600
    static let rendezvousLength = 32
    static let maximumNameLength = 64

    enum Field {
        static let tvName = "tvName"
        static let tvKind = "tvKind"
        static let rendezvous = "rendezvous"
        static let createdAt = "createdAt"
        static let expiresAt = "expiresAt"
        static let all = [tvName, tvKind, rendezvous, createdAt, expiresAt]
    }

    let rendezvous: String
    let tvName: String
    let tvKind: DeviceClass
    let createdAt: Date
    let expiresAt: Date

    var id: String { rendezvous }
    var recordName: String { "signin-\(rendezvous)" }

    init?(rendezvous: String, tvName: String, tvKind: DeviceClass = .tv, createdAt: Date, expiresAt: Date? = nil) {
        let name = tvName.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard Self.isValidRendezvous(rendezvous), !name.isEmpty else { return nil }
        let latest = createdAt.addingTimeInterval(Self.lifetime)
        let expiry = min(expiresAt ?? latest, latest)
        guard expiry > createdAt else { return nil }
        self.rendezvous = rendezvous
        self.tvName = String(name.prefix(Self.maximumNameLength))
        self.tvKind = tvKind
        self.createdAt = createdAt
        self.expiresAt = expiry
    }

    static func make(tvName: String, tvKind: DeviceClass = .current, now: Date = .now) -> SignInRequest? {
        guard let rendezvous = makeRendezvous() else { return nil }
        return SignInRequest(rendezvous: rendezvous, tvName: tvName, tvKind: tvKind, createdAt: now)
    }

    static func makeRendezvous() -> String? {
        var bytes = [UInt8](repeating: 0, count: rendezvousLength / 2)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isValidRendezvous(_ value: String) -> Bool {
        value.count == rendezvousLength && value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    func isExpired(at now: Date = .now) -> Bool {
        now >= expiresAt || now < createdAt.addingTimeInterval(-120)
    }

    init?(fields: [String: Any]) {
        guard let rendezvous = fields[Field.rendezvous] as? String,
              let name = fields[Field.tvName] as? String,
              let created = fields[Field.createdAt] as? Date else { return nil }
        let kind = (fields[Field.tvKind] as? String).flatMap(DeviceClass.init(rawValue:)) ?? .tv
        self.init(
            rendezvous: rendezvous,
            tvName: name,
            tvKind: kind,
            createdAt: created,
            expiresAt: fields[Field.expiresAt] as? Date
        )
    }

    init?(record: CKRecord) {
        guard record.recordType == Self.recordType else { return nil }
        var fields: [String: Any] = [:]
        for key in Field.all { fields[key] = record[key] }
        self.init(fields: fields)
    }

    init?(remoteNotification userInfo: [AnyHashable: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let subscriptionID = notification.subscriptionID,
              Self.subscriptionIDs.contains(subscriptionID),
              let fields = notification.recordFields else { return nil }
        self.init(fields: fields)
    }

    func record(zone: CKRecordZone.ID = .default) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: recordName, zoneID: zone))
        record[Field.rendezvous] = rendezvous as CKRecordValue
        record[Field.tvName] = tvName as CKRecordValue
        record[Field.tvKind] = tvKind.rawValue as CKRecordValue
        record[Field.createdAt] = createdAt as CKRecordValue
        record[Field.expiresAt] = expiresAt as CKRecordValue
        return record
    }

    static let subscriptionID = "signin-requests-v2"
    static let subscriptionIDs: Set<String> = [subscriptionID, "signin-requests-v1"]
    static let titleKey = "SIGN_IN_REQUEST_TITLE"
    static let bodyKey = "SIGN_IN_REQUEST_BODY"

    static func matchingOffer<Offer>(_ rendezvous: String, in offers: [Offer], key: (Offer) -> String?) -> Offer? {
        guard isValidRendezvous(rendezvous) else { return nil }
        return offers.first { key($0) == rendezvous }
    }
}

struct SignInRequestLedger: @unchecked Sendable {
    static let key = "signInRequest.outstanding.v1"
    static let capacity = 20

    let defaults: UserDefaults
    let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = SignInRequestLedger.key) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    var recordNames: [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    func add(_ recordName: String) {
        var names = recordNames.filter { $0 != recordName }
        names.append(recordName)
        defaults.set(Array(names.suffix(Self.capacity)), forKey: storageKey)
    }

    func remove(_ removed: some Sequence<String>) {
        let removed = Set(removed)
        let names = recordNames.filter { !removed.contains($0) }
        if names.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(names, forKey: storageKey)
        }
    }

    static func settled(_ results: [String: Error?]) -> [String] {
        results.compactMap { name, error in
            guard let error else { return name }
            return (error as? CKError)?.code == .unknownItem ? name : nil
        }
    }
}

struct SignInRequestFilter: Sendable {
    enum Verdict: Equatable, Sendable {
        case show
        case expired
        case duplicate
        case alreadySignedIn
    }

    private(set) var seen: [String: Date] = [:]

    mutating func admit(
        _ request: SignInRequest,
        now: Date = .now,
        signedInTVNames: Set<String> = []
    ) -> Verdict {
        seen = seen.filter { $0.value > now }
        guard !request.isExpired(at: now) else { return .expired }
        if signedInTVNames.contains(where: { $0.localizedCaseInsensitiveCompare(request.tvName) == .orderedSame }) {
            return .alreadySignedIn
        }
        guard seen[request.rendezvous] == nil else { return .duplicate }
        seen[request.rendezvous] = request.expiresAt
        return .show
    }

    mutating func forget(_ rendezvous: String) {
        seen[rendezvous] = nil
    }
}

enum DevicePickerSignIn {
    static let serviceName = "SoundingSignIn"
    static let wireVersion = 1
    static let maximumMessageLength = 4096

    struct Invitation: Codable, Equatable, Sendable {
        var version: Int
        var sessionId: String
        var secretBase64: String
        var createdAt: Date
        var tvName: String
        var tvKind: String

        var secret: Data? { Data(base64Encoded: secretBase64) }
        var kind: DeviceClass { DeviceClass(rawValue: tvKind) ?? .tv }
    }

    static func encode(_ invitation: Invitation) throws -> Data {
        let body = try JSONEncoder().encode(invitation)
        guard body.count <= maximumMessageLength else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "too long")) }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    static func decode(_ data: Data, now: Date = .now) -> Invitation? {
        guard data.count > 4 else { return nil }
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= maximumMessageLength, data.count >= 4 + length else { return nil }
        guard let invitation = try? JSONDecoder().decode(Invitation.self, from: data.dropFirst(4).prefix(length)),
              invitation.version == wireVersion,
              !invitation.sessionId.isEmpty,
              invitation.secret?.count == 32,
              !invitation.tvName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              invitation.tvName.count <= SignInRequest.maximumNameLength,
              now.timeIntervalSince(invitation.createdAt) < BonjourConstants.sessionTimeout,
              invitation.createdAt.timeIntervalSince(now) < 120 else { return nil }
        return invitation
    }

    static func isComplete(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        return length > maximumMessageLength || data.count >= 4 + length
    }
}
