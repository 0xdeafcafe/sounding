import Foundation
import CryptoKit
import Security
import os

struct LinkOwnerKey: Codable, Equatable, Sendable {
    static let length = 32

    let material: Data
    let createdAt: Date
    var retiresAt: Date?

    static func generate(at now: Date) -> LinkOwnerKey? {
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return LinkOwnerKey(material: Data(bytes), createdAt: now)
    }
}

struct LinkOwnerKeyRing: Codable, Equatable, Sendable {
    static let rotationAge: TimeInterval = 30 * 86_400
    static let maximumAge: TimeInterval = 45 * 86_400
    static let overlap: TimeInterval = 7 * 86_400
    private static let clockSkew: TimeInterval = 86_400

    var current: LinkOwnerKey?
    var previous: LinkOwnerKey?

    var isEmpty: Bool { current == nil && previous == nil }

    func usableKeys(at now: Date) -> [LinkOwnerKey] {
        var keys: [LinkOwnerKey] = []
        if let current, Self.isValid(current),
           current.createdAt.timeIntervalSince(now) < Self.clockSkew,
           now.timeIntervalSince(current.createdAt) < Self.maximumAge {
            keys.append(current)
        }
        if let previous, Self.isValid(previous),
           let retiresAt = previous.retiresAt, retiresAt > now,
           now.timeIntervalSince(previous.createdAt) < Self.maximumAge + Self.overlap {
            keys.append(previous)
        }
        return keys
    }

    func needsRotation(at now: Date) -> Bool {
        guard let current, Self.isValid(current) else { return true }
        return now.timeIntervalSince(current.createdAt) >= Self.rotationAge
    }

    func rotated(at now: Date) -> LinkOwnerKeyRing? {
        guard needsRotation(at: now), let fresh = LinkOwnerKey.generate(at: now) else { return nil }
        var retired = current.flatMap { Self.isValid($0) ? $0 : nil }
        retired?.retiresAt = now.addingTimeInterval(Self.overlap)
        return LinkOwnerKeyRing(current: fresh, previous: retired)
    }

    func key(matching tags: [String], sessionId: String, initiatorKey: String, at now: Date) -> (key: LinkOwnerKey, tag: String)? {
        let offered = tags.prefix(LinkOwnerProof.maximumTags).compactMap { Data(base64Encoded: $0) }
        guard !offered.isEmpty else { return nil }
        for key in usableKeys(at: now) {
            let tag = LinkOwnerProof.tag(key: key.material, sessionId: sessionId, initiatorKey: initiatorKey)
            guard let mine = Data(base64Encoded: tag) else { continue }
            if offered.contains(where: { LinkAccountHint.constantTimeEqual($0, mine) }) {
                return (key, tag)
            }
        }
        return nil
    }

    private static func isValid(_ key: LinkOwnerKey) -> Bool {
        key.material.count == LinkOwnerKey.length
    }
}

enum LinkOwnerProof {
    static let maximumTags = 2
    static let tagLength = 8

    enum Role: String {
        case initiator
        case responder
    }

    struct Transcript: Equatable {
        let sessionId: String
        let initiatorKey: String
        let responderKey: String
        let commitNonce: String
        let initiatorName: String
        let initiatorClass: String
        let accountId: String

        fileprivate var fields: [String] {
            [sessionId, initiatorKey, responderKey, commitNonce, initiatorName, initiatorClass, accountId]
        }
    }

    static func tag(key: Data, sessionId: String, initiatorKey: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: CanonicalForm.bytes(["Sounding-LinkOwnerTag-v1", sessionId, initiatorKey]),
            using: SymmetricKey(data: key)
        )
        return Data(code).prefix(tagLength).base64EncodedString()
    }

    static func tags(for keys: [LinkOwnerKey], sessionId: String, initiatorKey: String) -> [String: LinkOwnerKey] {
        var tags: [String: LinkOwnerKey] = [:]
        for key in keys.prefix(maximumTags) {
            tags[tag(key: key.material, sessionId: sessionId, initiatorKey: initiatorKey)] = key
        }
        return tags
    }

    static func sign(_ role: Role, key: Data, transcript: Transcript) -> String? {
        guard !transcript.accountId.isEmpty, key.count == LinkOwnerKey.length else { return nil }
        return CanonicalForm.sign(fields(role, transcript), secret: key)
    }

    static func verify(_ proof: String?, role: Role, key: Data, transcript: Transcript) -> Bool {
        guard let proof, !transcript.accountId.isEmpty, key.count == LinkOwnerKey.length else { return false }
        return CanonicalForm.verify(proof, fields: fields(role, transcript), secret: key)
    }

    private static func fields(_ role: Role, _ transcript: Transcript) -> [String] {
        ["Sounding-LinkOwnerProof-v1", role.rawValue] + transcript.fields
    }
}

enum LinkOwnerKeyStore {
    private static let account = "owner_key_ring"

    private static var keychain: SecLinkKeychain {
        SecLinkKeychain(service: "red.forbes.sounding.linkOwnerKey", accessGroup: "6Z49PF6642.red.forbes.sounding.shared")
    }

    static func load() -> LinkOwnerKeyRing {
        guard let data = keychain.read(account: account),
              let ring = try? JSONDecoder().decode(LinkOwnerKeyRing.self, from: data) else { return LinkOwnerKeyRing() }
        return ring
    }

    static func save(_ ring: LinkOwnerKeyRing) {
        guard ring != load() else { return }
        guard !ring.isEmpty, let data = try? JSONEncoder().encode(ring) else {
            clear()
            return
        }
        keychain.write(data, account: account)
    }

    static func clear() {
        keychain.delete(account: account)
    }

    static func usableKeys(at now: Date = Date()) -> [LinkOwnerKey] {
        load().usableKeys(at: now)
    }
}
