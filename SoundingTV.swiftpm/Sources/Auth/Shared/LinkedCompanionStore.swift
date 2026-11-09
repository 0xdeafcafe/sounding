import Foundation
import Combine
import Security
import os

protocol LinkKeychain {
    func read(account: String) -> Data?
    @discardableResult func write(_ data: Data, account: String) -> Bool
    func delete(account: String)
}

struct SecLinkKeychain: LinkKeychain {
    let service: String
    let accessGroup: String

    func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SoundingKeychain.copyMatching(query, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    func write(_ data: Data, account: String) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SoundingKeychain.update(match, update)
        if status == errSecItemNotFound {
            var attributes = match
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SoundingKeychain.add(attributes)
        }
        if status != errSecSuccess {
            Log.link.error("[LinkedCompanionStore] keychain write failed: \(status, privacy: .public)")
        }
        return status == errSecSuccess
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SoundingKeychain.delete(query)
    }
}

extension LinkedCompanionStore {
    struct LinkRecord: Codable, Equatable, Identifiable, Sendable {
        var sessionId: String
        var secretBase64: String
        var pairedAt: Date
        var deviceClass: DeviceClass?
        var displayName: String?
        var lastUsedAt: Date?

        var id: String { sessionId }
        var secret: Data? { Data(base64Encoded: secretBase64) }
        var peerClass: DeviceClass { deviceClass ?? .tv }
        var peerName: String { displayName ?? peerClass.displayName }
        var servicePrefix: String { String(sessionId.prefix(8)) }
        var recency: Date { lastUsedAt ?? pairedAt }
    }
}

struct PendingLinkMessage: Codable, Equatable, Identifiable, Sendable {
    typealias LinkRecord = LinkedCompanionStore.LinkRecord

    enum Kind: String, Codable, Sendable {
        case linkRevoke
        case sessionRevoke
    }

    let id: String
    let kind: Kind
    let sessionId: String
    let secretBase64: String
    let peerName: String
    let accountId: String?
    let lineageDigest: String?
    let createdAt: Date

    init(
        kind: Kind,
        link: LinkRecord,
        accountId: String? = nil,
        lineageDigest: String? = nil,
        createdAt: Date = Date()
    ) {
        id = UUID().uuidString
        self.kind = kind
        sessionId = link.sessionId
        secretBase64 = link.secretBase64
        peerName = link.peerName
        self.accountId = accountId
        self.lineageDigest = lineageDigest
        self.createdAt = createdAt
    }

    var secret: Data? { Data(base64Encoded: secretBase64) }
    var servicePrefix: String { String(sessionId.prefix(8)) }

    func message() -> TokenTransferMessage? {
        guard let secret else { return nil }
        switch kind {
        case .linkRevoke:
            return .linkRevoke(sessionId: sessionId, secret: secret)
        case .sessionRevoke:
            return .sessionRevoke(sessionId: sessionId, secret: secret, accountId: accountId, lineageDigest: lineageDigest)
        }
    }
}

struct LinkedCompanionLedger {
    typealias LinkRecord = LinkedCompanionStore.LinkRecord

    static let capacity = 8
    static let outboxCapacity = 32
    static let outboxLifetime: TimeInterval = 14 * 24 * 60 * 60

    enum Accounts {
        static let links = "linked_tvs"
        static let legacyLink = "paired_tv"
        static let outbox = "pending_link_messages"
    }

    let keychain: any LinkKeychain
    let legacyKeychains: [any LinkKeychain]

    func loadAll() -> [LinkRecord] {
        if let data = keychain.read(account: Accounts.links),
           let records = try? JSONDecoder().decode([LinkRecord].self, from: data) {
            return Self.sorted(records.filter { $0.secret?.isEmpty == false })
        }
        return migrateLegacy()
    }

    func preferred() -> LinkRecord? {
        loadAll().first
    }

    @discardableResult
    func save(_ record: LinkRecord) -> [LinkRecord] {
        var records = loadAll().filter { $0.sessionId != record.sessionId }
        var added = record
        if added.lastUsedAt == nil { added.lastUsedAt = added.pairedAt }
        records.insert(added, at: 0)
        records = Self.sorted(records)
        if records.count > Self.capacity { records = Array(records.prefix(Self.capacity)) }
        persist(records)
        return records
    }

    @discardableResult
    func markUsed(sessionId: String, at date: Date = Date()) -> [LinkRecord] {
        var records = loadAll()
        guard let index = records.firstIndex(where: { $0.sessionId == sessionId }) else { return records }
        records[index].lastUsedAt = date
        records = Self.sorted(records)
        persist(records)
        return records
    }

    @discardableResult
    func remove(sessionId: String) -> LinkRecord? {
        var records = loadAll()
        guard let index = records.firstIndex(where: { $0.sessionId == sessionId }) else { return nil }
        let removed = records.remove(at: index)
        persist(records)
        return removed
    }

    func removeAll() {
        keychain.delete(account: Accounts.links)
        keychain.delete(account: Accounts.legacyLink)
    }

    func pendingMessages(now: Date = Date()) -> [PendingLinkMessage] {
        guard let data = keychain.read(account: Accounts.outbox),
              let messages = try? JSONDecoder().decode([PendingLinkMessage].self, from: data) else { return [] }
        let live = messages.filter { now.timeIntervalSince($0.createdAt) < Self.outboxLifetime && $0.secret != nil }
        if live.count != messages.count { persistOutbox(live) }
        return live
    }

    @discardableResult
    func enqueue(_ message: PendingLinkMessage) -> [PendingLinkMessage] {
        var messages = pendingMessages().filter { !($0.sessionId == message.sessionId && $0.kind == message.kind) }
        if message.kind == .linkRevoke {
            messages.removeAll { $0.sessionId == message.sessionId }
        }
        messages.append(message)
        if messages.count > Self.outboxCapacity { messages.removeFirst(messages.count - Self.outboxCapacity) }
        persistOutbox(messages)
        return messages
    }

    @discardableResult
    func settle(messageId: String) -> [PendingLinkMessage] {
        let messages = pendingMessages().filter { $0.id != messageId }
        persistOutbox(messages)
        return messages
    }

    private func migrateLegacy() -> [LinkRecord] {
        for source in [keychain] + legacyKeychains {
            guard let data = source.read(account: Accounts.legacyLink),
                  let legacy = try? JSONDecoder().decode(LinkRecord.self, from: data),
                  legacy.secret?.isEmpty == false else { continue }
            let migrated = [legacy]
            guard persist(migrated) else { return migrated }
            source.delete(account: Accounts.legacyLink)
            keychain.delete(account: Accounts.legacyLink)
            Log.link.info("[LinkedCompanionStore] migrated the single linked Apple TV")
            return migrated
        }
        return []
    }

    @discardableResult
    private func persist(_ records: [LinkRecord]) -> Bool {
        guard let data = try? JSONEncoder().encode(records) else { return false }
        return keychain.write(data, account: Accounts.links)
    }

    private func persistOutbox(_ messages: [PendingLinkMessage]) {
        guard !messages.isEmpty else {
            keychain.delete(account: Accounts.outbox)
            return
        }
        guard let data = try? JSONEncoder().encode(messages) else { return }
        keychain.write(data, account: Accounts.outbox)
    }

    private static func sorted(_ records: [LinkRecord]) -> [LinkRecord] {
        records.sorted { $0.recency > $1.recency }
    }
}

enum LinkedCompanionStore {
    private static let service = "red.forbes.sounding.phone"
    private static let sharedAccessGroup = "6Z49PF6642.red.forbes.sounding.shared"
    private static let legacyAccessGroup = "6Z49PF6642.red.forbes.sounding"
    private nonisolated(unsafe) static let changeSubject = PassthroughSubject<Void, Never>()

    nonisolated(unsafe) static var ledger = LinkedCompanionLedger(
        keychain: SecLinkKeychain(service: service, accessGroup: sharedAccessGroup),
        legacyKeychains: [SecLinkKeychain(service: service, accessGroup: legacyAccessGroup)]
    )

    static var changes: AnyPublisher<Void, Never> {
        changeSubject.eraseToAnyPublisher()
    }

    static func loadAll() -> [LinkRecord] { ledger.loadAll() }

    static func load() -> LinkRecord? { ledger.preferred() }

    static func save(sessionId: String, secret: Data, deviceClass: DeviceClass = .tv, displayName: String? = nil) {
        let now = Date()
        ledger.save(LinkRecord(
            sessionId: sessionId,
            secretBase64: secret.base64EncodedString(),
            pairedAt: now,
            deviceClass: deviceClass,
            displayName: displayName,
            lastUsedAt: now
        ))
        changeSubject.send(())
    }

    static func markUsed(sessionId: String) {
        guard ledger.preferred()?.sessionId != sessionId else { return }
        ledger.markUsed(sessionId: sessionId)
        changeSubject.send(())
    }

    @discardableResult
    static func remove(sessionId: String) -> LinkRecord? {
        let removed = ledger.remove(sessionId: sessionId)
        if removed != nil { changeSubject.send(()) }
        return removed
    }

    static func clear() {
        ledger.removeAll()
        changeSubject.send(())
    }

    static func pendingMessages() -> [PendingLinkMessage] { ledger.pendingMessages() }

    static func enqueue(_ message: PendingLinkMessage) { ledger.enqueue(message) }

    static func settle(messageId: String) { ledger.settle(messageId: messageId) }
}
