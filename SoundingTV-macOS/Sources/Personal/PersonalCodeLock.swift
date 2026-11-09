#if SOUNDING_PERSONAL
import CryptoKit
import Foundation

enum SoundingPersonalMarker {
    static let name = "SoundingPersonalMarker"
}

struct PersonalCodeDigest: Equatable, Sendable {
    let salt: Data
    let hash: Data

    init?(setting: String) {
        let parts = setting.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let salt = Data(hex: String(parts[0])), salt.count >= 8,
              let hash = Data(hex: String(parts[1])), hash.count == SHA256.byteCount else { return nil }
        self.salt = salt
        self.hash = hash
    }

    init(code: String, salt: Data) {
        self.salt = salt
        self.hash = Self.digest(code: code, salt: salt)
    }

    var setting: String { "\(salt.hexString):\(hash.hexString)" }

    static func normalise(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func digest(code: String, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(normalise(code).utf8))
        return Data(hasher.finalize())
    }

    func matches(_ code: String) -> Bool {
        let candidate = Self.digest(code: code, salt: salt)
        guard candidate.count == hash.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(candidate, hash) { difference |= a ^ b }
        return difference == 0
    }
}

struct PersonalCodeLock {
    static let infoPlistKey = "SoundingPersonalCodeHash"
    static let unlockedDefaultsKey = "\(SoundingPersonalMarker.name).audioExportUnlock"

    let digest: PersonalCodeDigest?
    private let defaults: UserDefaults

    init(digest: PersonalCodeDigest?, defaults: UserDefaults) {
        self.digest = digest
        self.defaults = defaults
    }

    static func live(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> PersonalCodeLock {
        let setting = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String
        return PersonalCodeLock(digest: setting.flatMap(PersonalCodeDigest.init(setting:)), defaults: defaults)
    }

    var isConfigured: Bool { digest != nil }

    var isUnlocked: Bool {
        guard let digest else { return false }
        return defaults.string(forKey: Self.unlockedDefaultsKey) == digest.setting
    }

    @discardableResult
    func unlock(with code: String) -> Bool {
        guard let digest, digest.matches(code) else { return false }
        defaults.set(digest.setting, forKey: Self.unlockedDefaultsKey)
        return true
    }

    func lock() {
        defaults.removeObject(forKey: Self.unlockedDefaultsKey)
    }
}

extension Data {
    fileprivate init?(hex: String) {
        let characters = Array(hex.utf8)
        guard characters.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = Self.nibble(characters[index]), let low = Self.nibble(characters[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
#endif
