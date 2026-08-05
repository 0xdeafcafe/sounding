import Foundation
import Security

struct StoredSession: Codable, Equatable {
    var oauthToken: String
    var refreshToken: String?
    var clientId: String?
    var expiresAt: Date?

    static let expirySkewMargin: TimeInterval = 300

    var isUsable: Bool {
        guard !oauthToken.isEmpty else { return false }
        // A session that can refresh itself is always usable. A session without
        // refresh material is only usable while its access token is still valid.
        if canSelfRefresh { return true }
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow > Self.expirySkewMargin
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow <= Self.expirySkewMargin
    }

    var canSelfRefresh: Bool {
        refreshToken?.isEmpty == false && clientId?.isEmpty == false
    }

    var shouldRefreshBeforeHandoff: Bool {
        isExpired && canSelfRefresh
    }

    func applying(_ credentials: SoundCloudTokenRefresh.Credentials) -> StoredSession {
        StoredSession(
            oauthToken: credentials.accessToken,
            refreshToken: credentials.refreshToken ?? refreshToken,
            clientId: clientId,
            expiresAt: credentials.expiresAt
        )
    }
}

enum DeviceSessionStore {
    private static let service = "red.forbes.sounding.phone"
    private static let account = "soundcloud_session"

    private static let sessionSyncLocalSignOutKey = "red.forbes.sounding.sessionsync.localSignOutMillis"

    private enum StoreError: Error {
        case encodeFailed(Error)
        case decodeFailed(Error)
        case keychainReadFailed(OSStatus)
        case keychainWriteFailed(OSStatus)
        case keychainDeleteFailed(OSStatus)
    }

    /// Must match the shared group in each target's signed entitlements.
    private static let sharedAccessGroup: String? = "6Z49PF6642.red.forbes.sounding.shared"

    static func load() -> StoredSession? {
        do {
            return try loadSession()
        } catch {
            Log.auth.error("[DeviceSessionStore] load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func save(_ session: StoredSession) {
        do {
            try saveSession(session)
            UserDefaults.standard.removeObject(forKey: sessionSyncLocalSignOutKey)
        } catch {
            Log.auth.error("[DeviceSessionStore] save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func clear() {
        do {
            try deleteSessionItem()
        } catch {
            Log.auth.error("[DeviceSessionStore] clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func forget(now: Date = Date()) {
        do {
            try deleteSessionItem()
        } catch {
            Log.auth.error("[DeviceSessionStore] forget failed: \(error.localizedDescription, privacy: .public)")
        }
        UserDefaults.standard.set(
            NSNumber(value: Int64(now.timeIntervalSince1970 * 1000)),
            forKey: sessionSyncLocalSignOutKey
        )
    }

    static var hasLocalSignOut: Bool {
        UserDefaults.standard.object(forKey: sessionSyncLocalSignOutKey) != nil
    }

    static func clearLocalSignOut() {
        UserDefaults.standard.removeObject(forKey: sessionSyncLocalSignOutKey)
    }

    private static func loadSession() throws -> StoredSession? {
        if let group = sharedAccessGroup,
           let session = try loadSession(accessGroup: group) {
            return session
        }
        return try loadSession(accessGroup: nil)
    }

    private static func loadSession(accessGroup: String?) throws -> StoredSession? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return nil }
            throw StoreError.keychainReadFailed(status)
        }
        guard let data = item as? Data else {
            throw StoreError.keychainReadFailed(errSecSuccess)
        }
        do {
            return try JSONDecoder().decode(StoredSession.self, from: data)
        } catch {
            throw StoreError.decodeFailed(error)
        }
    }

    private static func saveSession(_ session: StoredSession) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(session)
        } catch {
            throw StoreError.encodeFailed(error)
        }

        try deleteSessionItem()

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let group = sharedAccessGroup {
            attributes[kSecAttrAccessGroup as String] = group
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychainWriteFailed(status)
        }
    }

    private static func deleteSessionItem() throws {
        if let group = sharedAccessGroup {
            try deleteSessionItem(accessGroup: group)
        }
        try deleteSessionItem(accessGroup: nil)
    }

    private static func deleteSessionItem(accessGroup: String?) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychainDeleteFailed(status)
        }
    }
}

#if DEBUG
enum DevCredentialStore {
    private static let service = "red.forbes.sounding.devcredential"
    private static let account = "soundcloud_dev_session"

    private static let accessGroup: String? = "6Z49PF6642.red.forbes.sounding.shared"

    static func loadFromEnvironment() -> StoredSession? {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["SOUNDING_TV_DEV_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return StoredSession(
            oauthToken: token,
            refreshToken: env["SOUNDING_TV_DEV_REFRESH"].flatMap { $0.isEmpty ? nil : $0 },
            clientId: env["SOUNDING_TV_DEV_CLIENT_ID"].flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: nil
        )
    }

    static func load() -> StoredSession? {
        guard let accessGroup else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    @discardableResult
    static func save(_ session: StoredSession) -> OSStatus {
        guard let accessGroup else { return errSecMissingEntitlement }
        guard let data = try? JSONEncoder().encode(session) else { return errSecParam }
        clear()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            Log.auth.error("[DevCredentialStore] save failed: \(status, privacy: .public)")
        }
        return status
    }

    static func clear() {
        guard let accessGroup else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.auth.error("[DevCredentialStore] clear failed: \(status, privacy: .public)")
        }
    }
}
#endif

@MainActor
final class DeviceSessionRefresher {
    static let shared = DeviceSessionRefresher()

    private let coordinator = TokenRefreshCoordinator()

    private init() {}

    var recentOutcome: SoundCloudTokenRefresh.Outcome? { coordinator.recentOutcome }

    var recentOutcomeWasLocalGuard: Bool { coordinator.recentOutcomeWasLocalGuard }

    @discardableResult
    func refresh(_ session: StoredSession) async -> StoredSession? {
        let outcome = await coordinator.refresh(
            refreshToken: session.refreshToken,
            clientId: session.clientId
        )
        guard case .succeeded(let credentials) = outcome else { return nil }

        let renewed = session.applying(credentials)
        DeviceSessionStore.save(renewed)
        return renewed
    }

    func refreshIfNeeded(_ session: StoredSession) async -> StoredSession {
        guard session.shouldRefreshBeforeHandoff else { return session }
        return await refresh(session) ?? session
    }

    func reset() {
        coordinator.reset()
    }
}
