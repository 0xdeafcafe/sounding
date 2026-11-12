import Foundation
import CryptoKit

struct PeerAccount: Codable, Equatable, Hashable, Sendable {
    static let maximumEncodedBytes = 512
    static let maximumNameLength = 64
    static let maximumTagLength = 64

    let tag: String
    let name: String
    let username: String
    var avatarURL: String?

    init(tag: String, name: String, username: String, avatarURL: String? = nil) {
        self.tag = tag
        self.name = String(Self.clean(name).prefix(Self.maximumNameLength))
        self.username = String(Self.clean(username).prefix(Self.maximumNameLength))
        self.avatarURL = avatarURL
    }

    init(userId: String, name: String, username: String, avatarURL: String? = nil) {
        self.init(tag: Self.tag(userId: userId), name: name, username: username, avatarURL: avatarURL)
    }

    var displayName: String {
        if !name.isEmpty { return name }
        if !username.isEmpty { return username }
        return "SoundCloud"
    }

    func isSameAccount(as other: PeerAccount?) -> Bool {
        guard let other, !tag.isEmpty else { return false }
        return other.tag == tag
    }

    static func tag(userId: String) -> String {
        let hash = SHA256.hash(data: Data("Sounding-AccountSignIn-Account-v1|\(userId)".utf8))
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(self), data.count <= Self.maximumEncodedBytes { return data }
        var trimmed = self
        trimmed.avatarURL = nil
        guard let data = try? encoder.encode(trimmed), data.count <= Self.maximumEncodedBytes else { return nil }
        return data
    }

    static func decode(_ data: Data?) -> PeerAccount? {
        guard let data, !data.isEmpty, data.count <= maximumEncodedBytes,
              let account = try? JSONDecoder().decode(PeerAccount.self, from: data),
              !account.tag.isEmpty, account.tag.count <= maximumTagLength else { return nil }
        return PeerAccount(tag: account.tag, name: account.name, username: account.username, avatarURL: account.avatarURL)
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }
}

struct KnownLinkLedger: Codable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case never
        case linked
        case unlinked
        case otherAccount
    }

    struct Entry: Codable, Equatable, Sendable {
        var accountTag: String
        var linkedAt: Date
        var unlinkedAt: Date?
    }

    static let defaultsKey = "red.forbes.sounding.knownLinks.v1"
    static let capacity = 32

    private(set) var entries: [String: Entry] = [:]

    static func identity(name: String, kind: DeviceClass) -> String {
        "\(kind.rawValue)|\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    func status(of identity: String, accountTag: String?) -> Status {
        guard let entry = entries[identity] else { return .never }
        if entry.unlinkedAt != nil { return .unlinked }
        guard let accountTag, !accountTag.isEmpty, entry.accountTag == accountTag else { return .otherAccount }
        return .linked
    }

    func allowsAutoLink(_ identity: String, accountTag: String?) -> Bool {
        status(of: identity, accountTag: accountTag) == .linked
    }

    mutating func recordLinked(_ identity: String, accountTag: String, at now: Date = Date()) {
        guard !accountTag.isEmpty else { return }
        entries[identity] = Entry(accountTag: accountTag, linkedAt: now, unlinkedAt: nil)
        trim()
    }

    mutating func recordUnlinked(_ identity: String, at now: Date = Date()) {
        guard var entry = entries[identity] else {
            entries[identity] = Entry(accountTag: "", linkedAt: now, unlinkedAt: now)
            trim()
            return
        }
        entry.unlinkedAt = now
        entries[identity] = entry
    }

    private mutating func trim() {
        guard entries.count > Self.capacity else { return }
        let keep = entries.sorted { ($0.value.unlinkedAt ?? $0.value.linkedAt) > ($1.value.unlinkedAt ?? $1.value.linkedAt) }
            .prefix(Self.capacity)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    static func load(defaults: UserDefaults = .standard) -> KnownLinkLedger {
        guard let data = defaults.data(forKey: defaultsKey),
              let ledger = try? JSONDecoder().decode(KnownLinkLedger.self, from: data) else { return KnownLinkLedger() }
        return ledger
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func update(defaults: UserDefaults = .standard, _ change: (inout KnownLinkLedger) -> Void) {
        var ledger = load(defaults: defaults)
        change(&ledger)
        ledger.save(defaults: defaults)
    }
}

extension PeerAccount {
    init(user: User) {
        self.init(userId: user.id, name: user.displayName, username: user.username, avatarURL: user.avatarURL?.absoluteString)
    }
}

enum LinkEstablishPolicy {
    enum OfferHint: Equatable, Sendable {
        case signedOut
        case sameAccount
        case otherAccount
        case notSeen
    }

    enum Opening: Equatable, Sendable {
        case tokenTransfer
        case linkEstablish
    }

    static func hint(for advert: LinkAccountHint.Advert?, offerSeen: Bool, accountId: String?) -> OfferHint {
        guard offerSeen else { return .notSeen }
        guard let advert else { return .signedOut }
        guard let accountId, advert.matches(accountId: accountId) else { return .otherAccount }
        return .sameAccount
    }

    static func opening(for hint: OfferHint) -> Opening {
        hint == .signedOut ? .tokenTransfer : .linkEstablish
    }

    static func sendsCredentials(_ established: LinkEstablishedPayload) -> Bool {
        established.needsCredentials
    }

    static func fallsBackToTokenTransfer(_ hint: OfferHint) -> Bool {
        switch hint {
        case .notSeen, .sameAccount, .signedOut: return true
        case .otherAccount: return false
        }
    }

    static func isSameAccountApproval(digest: String?, salt: Data?, accountId: String?) -> Bool {
        guard let digest, let mine = Data(base64Encoded: digest), let salt,
              let accountId, !accountId.isEmpty else { return false }
        return LinkAccountHint.constantTimeEqual(mine, LinkAccountHint.accountDigest(accountId: accountId, salt: salt))
    }

    static func helloDigest(accountId: String?, salt: Data?) -> String? {
        guard let accountId, !accountId.isEmpty, let salt, salt.count == LinkAccountHint.saltLength else { return nil }
        return LinkAccountHint.accountDigest(accountId: accountId, salt: salt).base64EncodedString()
    }
}
