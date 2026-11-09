import Foundation

struct LinkedDevice: Codable, Equatable, Identifiable, Sendable {
    let sessionId: String
    let secretBase64: String
    var name: String
    var deviceClass: DeviceClass?
    var deviceId: String?
    let pairedAt: Date

    var id: String { sessionId }
    var secret: Data? { Data(base64Encoded: secretBase64) }

    var displayName: String {
        if !name.isEmpty { return name }
        return deviceClass?.displayName ?? "Linked Device"
    }

    init(
        sessionId: String,
        secret: Data,
        name: String = "",
        deviceClass: DeviceClass? = nil,
        deviceId: String? = nil,
        pairedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.secretBase64 = secret.base64EncodedString()
        self.name = name
        self.deviceClass = deviceClass
        self.deviceId = deviceId
        self.pairedAt = pairedAt
    }

    mutating func adopt(_ identity: LinkPeerIdentity) -> Bool {
        let before = self
        name = identity.name
        deviceClass = identity.peerClass ?? deviceClass
        deviceId = identity.deviceId
        return self != before
    }
}

protocol LinkedDeviceKeychain {
    func get(forKey key: String) -> String?
    func save(_ value: String, forKey key: String) throws
    func delete(forKey key: String) throws
}

extension KeychainService: LinkedDeviceKeychain {}

struct LinkedDeviceTrust {
    let devices: [LinkedDevice]

    func credentials(forSessionId sessionId: String) -> (sessionId: String, secret: Data)? {
        guard let device = devices.first(where: { $0.sessionId == sessionId }),
              let secret = device.secret, !secret.isEmpty else { return nil }
        return (device.sessionId, secret)
    }

    func admits(_ message: TokenTransferMessage, onSession sessionId: String) -> Bool {
        message.sessionId == sessionId && credentials(forSessionId: sessionId) != nil
    }
}

struct LinkedDeviceStore {
    static let capacity = 8

    enum Keys {
        static let devices = "remote_linked_devices_v1"
        static let legacySessionId = "remote_pair_session_id"
        static let legacySecret = "remote_pair_secret"
    }

    struct Change: Equatable {
        let devices: [LinkedDevice]
        let removed: [LinkedDevice]
    }

    let keychain: any LinkedDeviceKeychain

    init(keychain: any LinkedDeviceKeychain = KeychainService.shared) {
        self.keychain = keychain
    }

    func load() -> [LinkedDevice] {
        if let encoded = keychain.get(forKey: Keys.devices),
           let data = encoded.data(using: .utf8),
           let devices = try? JSONDecoder().decode([LinkedDevice].self, from: data) {
            return devices.filter { $0.secret?.isEmpty == false }
        }
        guard let sessionId = keychain.get(forKey: Keys.legacySessionId), !sessionId.isEmpty,
              let encodedSecret = keychain.get(forKey: Keys.legacySecret),
              let secret = Data(base64Encoded: encodedSecret), !secret.isEmpty else {
            return []
        }
        let migrated = [LinkedDevice(sessionId: sessionId, secret: secret, pairedAt: .distantPast)]
        guard persist(migrated) else { return migrated }
        deleteLegacy()
        Log.link.info("[LinkedDeviceStore] migrated the single linked device")
        return migrated
    }

    @discardableResult
    func add(_ device: LinkedDevice) -> Change {
        var devices = load()
        var removed = devices.filter { existing in
            existing.sessionId == device.sessionId
                || (device.deviceId != nil && existing.deviceId == device.deviceId)
        }
        devices.removeAll { candidate in removed.contains { $0.sessionId == candidate.sessionId } }
        devices.append(device)
        devices.sort { $0.pairedAt < $1.pairedAt }
        while devices.count > Self.capacity {
            removed.append(devices.removeFirst())
        }
        persist(devices)
        return Change(devices: devices, removed: removed.filter { $0.sessionId != device.sessionId })
    }

    @discardableResult
    func revoke(sessionId: String) -> Change {
        var devices = load()
        let removed = devices.filter { $0.sessionId == sessionId }
        guard !removed.isEmpty else { return Change(devices: devices, removed: []) }
        devices.removeAll { $0.sessionId == sessionId }
        persist(devices)
        return Change(devices: devices, removed: removed)
    }

    @discardableResult
    func update(sessionId: String, identity: LinkPeerIdentity) -> [LinkedDevice]? {
        var devices = load()
        guard let index = devices.firstIndex(where: { $0.sessionId == sessionId }),
              devices[index].adopt(identity) else { return nil }
        persist(devices)
        return devices
    }

    func removeAll() {
        for key in [Keys.devices, Keys.legacySessionId, Keys.legacySecret] {
            do {
                try keychain.delete(forKey: key)
            } catch {
                Log.auth.error("[LinkedDeviceStore] keychain delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @discardableResult
    private func persist(_ devices: [LinkedDevice]) -> Bool {
        do {
            let data = try JSONEncoder().encode(devices)
            try keychain.save(String(decoding: data, as: UTF8.self), forKey: Keys.devices)
            return true
        } catch {
            Log.auth.error("[LinkedDeviceStore] keychain save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func deleteLegacy() {
        try? keychain.delete(forKey: Keys.legacySessionId)
        try? keychain.delete(forKey: Keys.legacySecret)
    }
}

struct RevokedLink: Codable, Equatable, Identifiable, Sendable {
    let sessionId: String
    let secretBase64: String
    let name: String
    let revokedAt: Date

    var id: String { sessionId }
    var secret: Data? { Data(base64Encoded: secretBase64) }

    init(_ device: LinkedDevice, revokedAt: Date = Date()) {
        sessionId = device.sessionId
        secretBase64 = device.secretBase64
        name = device.displayName
        self.revokedAt = revokedAt
    }
}

struct RevokedLinkStore {
    static let capacity = 16
    static let lifetime: TimeInterval = 14 * 24 * 60 * 60
    static let key = "remote_revoked_links_v1"

    let keychain: any LinkedDeviceKeychain

    init(keychain: any LinkedDeviceKeychain = KeychainService.shared) {
        self.keychain = keychain
    }

    func load(now: Date = Date()) -> [RevokedLink] {
        guard let encoded = keychain.get(forKey: Self.key),
              let data = encoded.data(using: .utf8),
              let links = try? JSONDecoder().decode([RevokedLink].self, from: data) else { return [] }
        let live = links.filter { now.timeIntervalSince($0.revokedAt) < Self.lifetime && $0.secret?.isEmpty == false }
        if live.count != links.count { persist(live) }
        return live
    }

    @discardableResult
    func add(_ link: RevokedLink) -> [RevokedLink] {
        var links = load().filter { $0.sessionId != link.sessionId }
        links.append(link)
        if links.count > Self.capacity { links.removeFirst(links.count - Self.capacity) }
        persist(links)
        return links
    }

    @discardableResult
    func settle(sessionId: String) -> [RevokedLink] {
        let links = load().filter { $0.sessionId != sessionId }
        persist(links)
        return links
    }

    func removeAll() {
        try? keychain.delete(forKey: Self.key)
    }

    private func persist(_ links: [RevokedLink]) {
        guard !links.isEmpty else {
            try? keychain.delete(forKey: Self.key)
            return
        }
        guard let data = try? JSONEncoder().encode(links) else { return }
        try? keychain.save(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }
}
