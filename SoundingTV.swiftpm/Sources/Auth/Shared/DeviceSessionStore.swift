import Foundation
import Security
import Synchronization

struct StoredSession: Codable, Equatable, Sendable {
    var oauthToken: String
    var refreshToken: String?
    var clientId: String?
    var expiresAt: Date?
    var issuedAt: Date? = nil
    var generation: Int? = nil

    static let expirySkewMargin: TimeInterval = 300

    var lineage: String? { SessionSyncBookkeeping.lineageDigest(refreshToken: refreshToken) }

    func isNewer(than other: StoredSession) -> Bool {
        SessionIssuance.isNewer(
            issuedAtMillis: issuedAt.map(SessionIssuance.millis(_:)), generation: generation.map(Int64.init),
            than: other.issuedAt.map(SessionIssuance.millis(_:)), generation: other.generation.map(Int64.init)
        )
    }

    var isUsable: Bool {
        guard !oauthToken.isEmpty else { return false }
        // A session that can refresh itself is always usable. A session without
        // refresh material is usable while its access token is still valid.
        // Legacy/cookie-captured sessions have no declared expiry; keep those as
        // credential candidates and let the canonical /me request validate them.
        if canSelfRefresh { return true }
        guard let expiresAt else { return true }
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
            expiresAt: credentials.expiresAt,
            issuedAt: credentials.issuedAt ?? Date(),
            generation: credentials.generation ?? (generation ?? 0) + 1
        )
    }

    var asCredentials: SoundCloudTokenRefresh.Credentials {
        SoundCloudTokenRefresh.Credentials(
            accessToken: oauthToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            issuedAt: issuedAt,
            generation: generation
        )
    }
}

enum SessionIssuance {
    static func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    static func isNewer(issuedAtMillis: Int64?, generation: Int64?, than otherIssuedAtMillis: Int64?, generation otherGeneration: Int64?) -> Bool {
        if let issuedAtMillis, let otherIssuedAtMillis, issuedAtMillis != otherIssuedAtMillis {
            return issuedAtMillis > otherIssuedAtMillis
        }
        if issuedAtMillis != nil, otherIssuedAtMillis == nil { return true }
        if issuedAtMillis == nil, otherIssuedAtMillis != nil { return false }
        return (generation ?? 0) > (otherGeneration ?? 0)
    }
}

struct RejectedLineageLedger: Sendable {
    var contains: @Sendable (String) -> Bool
    var insert: @Sendable (String) -> Void

    func rejects(_ session: StoredSession) -> Bool {
        guard let lineage = session.lineage else { return false }
        return contains(lineage)
    }

    private static let defaultsKey = "red.forbes.sounding.auth.rejectedLineages"
    private static let capacity = 32

    static let defaults = RejectedLineageLedger(
        contains: { (UserDefaults.sounding.stringArray(forKey: defaultsKey) ?? []).contains($0) },
        insert: { lineage in
            var stored = UserDefaults.sounding.stringArray(forKey: defaultsKey) ?? []
            guard !stored.contains(lineage) else { return }
            stored.append(lineage)
            UserDefaults.sounding.set(Array(stored.suffix(capacity)), forKey: defaultsKey)
        }
    )

    static func memory() -> RejectedLineageLedger {
        final class Box: Sendable {
            let lineages = Mutex<Set<String>>([])
        }
        let box = Box()
        return RejectedLineageLedger(
            contains: { lineage in box.lineages.withLock { $0.contains(lineage) } },
            insert: { lineage in _ = box.lineages.withLock { $0.insert(lineage) } }
        )
    }
}

enum DeviceSessionStore {
    private static let service = "red.forbes.sounding.phone"
    private static let account = "soundcloud_session"

    private static let sessionSyncLocalSignOutKey = "red.forbes.sounding.sessionsync.localSignOutMillis"

    private enum CachedSession: Sendable {
        case notLoaded
        case loaded(StoredSession?)
    }

    /// Keychain is durable storage, not a view-state database. This cache keeps
    /// repeated screen appearances from performing synchronous Security IPC on
    /// the main actor. Every mutation below updates it atomically.
    private static let cachedSession = Mutex<CachedSession>(.notLoaded)

    private enum StoreError: Error {
        case encodeFailed(Error)
        case decodeFailed(Error)
        case keychainReadFailed(OSStatus)
        case keychainWriteFailed(OSStatus)
        case keychainDeleteFailed(OSStatus)
    }

    /// Must match the shared group in each target's signed entitlements.
    private static let sharedAccessGroup: String? = "6Z49PF6642.red.forbes.sounding.shared"

    #if DEBUG
    private static let mockSession: StoredSession? = ProcessInfo.processInfo.environment["SOUNDING_TV_SC_MOCK"] == "1"
        ? StoredSession(oauthToken: "mock-access", refreshToken: nil, clientId: nil, expiresAt: nil)
        : nil
    #endif

    static func load() -> StoredSession? {
        #if DEBUG
        if let mockSession { return mockSession }
        #endif
        if case .loaded(let session) = cachedSession.withLock({ $0 }) {
            return session
        }
        do {
            let session = try loadSession()
            cachedSession.withLock { $0 = .loaded(session) }
            return session
        } catch {
            // Only an explicit errSecItemNotFound (returned as nil above) may
            // be cached. A transient keychain or decode failure must not
            // become a sticky signed-out state — leave the cache untouched so
            // a later load() retries the read.
            Log.auth.error("[DeviceSessionStore] load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func reload() -> StoredSession? {
        #if DEBUG
        if let mockSession { return mockSession }
        #endif
        do {
            let session = try loadSession()
            cachedSession.withLock { $0 = .loaded(session) }
            return session
        } catch {
            Log.auth.error("[DeviceSessionStore] reload failed: \(error.localizedDescription, privacy: .public)")
            return load()
        }
    }

    static func save(_ session: StoredSession) {
        #if DEBUG
        if mockSession != nil { return }
        #endif
        var session = session
        if session.issuedAt == nil { session.issuedAt = Date() }
        do {
            try saveSession(session)
            cachedSession.withLock { $0 = .loaded(session) }
            UserDefaults.sounding.removeObject(forKey: sessionSyncLocalSignOutKey)
        } catch {
            Log.auth.error("[DeviceSessionStore] save failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func clear() {
        #if DEBUG
        if mockSession != nil { return }
        #endif
        do {
            try deleteSessionItem()
            cachedSession.withLock { $0 = .loaded(nil) }
        } catch {
            Log.auth.error("[DeviceSessionStore] clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func forget(now: Date = Date()) {
        #if DEBUG
        if mockSession != nil { return }
        #endif
        do {
            try deleteSessionItem()
            cachedSession.withLock { $0 = .loaded(nil) }
        } catch {
            Log.auth.error("[DeviceSessionStore] forget failed: \(error.localizedDescription, privacy: .public)")
        }
        UserDefaults.sounding.set(
            NSNumber(value: Int64(now.timeIntervalSince1970 * 1000)),
            forKey: sessionSyncLocalSignOutKey
        )
    }

    static var hasLocalSignOut: Bool {
        UserDefaults.sounding.object(forKey: sessionSyncLocalSignOutKey) != nil
    }

    static func clearLocalSignOut() {
        UserDefaults.sounding.removeObject(forKey: sessionSyncLocalSignOutKey)
    }

    private static func loadSession() throws -> StoredSession? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_UI_FIXTURE"] == "1" { return nil }
        #endif
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
        let status = SoundingKeychain.copyMatching(query, &item)
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

        bestEffortDeleteSessionItems()

        var match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = sharedAccessGroup {
            match[kSecAttrAccessGroup as String] = group
        }
        var attributes = match
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SoundingKeychain.add(attributes)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            status = SoundingKeychain.update(match, update)
        }
        guard status == errSecSuccess else {
            throw StoreError.keychainWriteFailed(status)
        }
    }

    private static func bestEffortDeleteSessionItems() {
        if let group = sharedAccessGroup {
            do { try deleteSessionItem(accessGroup: group) } catch {
                Log.auth.error("[DeviceSessionStore] shared delete before save failed: \(String(describing: error), privacy: .public)")
            }
        }
        do { try deleteSessionItem(accessGroup: nil) } catch {
            Log.auth.error("[DeviceSessionStore] legacy delete before save failed: \(String(describing: error), privacy: .public)")
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
        let status = SoundingKeychain.delete(query)
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
        guard SoundingKeychain.copyMatching(query, &item) == errSecSuccess,
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
        let status = SoundingKeychain.add(attributes)
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
        let status = SoundingKeychain.delete(query)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.auth.error("[DevCredentialStore] clear failed: \(status, privacy: .public)")
        }
    }
}
#endif

@MainActor
final class DeviceSessionRefresher {
    static let shared = DeviceSessionRefresher(environment: .live)

    struct Environment {
        var perform: @MainActor (_ refreshToken: String?, _ clientId: String?) async -> SoundCloudTokenRefresh.Outcome
        var reloadStored: @MainActor () -> StoredSession?
        var save: @MainActor (StoredSession) -> Void
        var ledger: RejectedLineageLedger
        var ownsRefresh: Bool
        var record: @MainActor (_ trigger: String, _ outcome: String) -> Void = { _, _ in }

        static var live: Environment {
            let coordinator = TokenRefreshCoordinator()
            return Environment(
                perform: { await coordinator.refresh(refreshToken: $0, clientId: $1) },
                reloadStored: { DeviceSessionStore.reload() },
                save: { DeviceSessionStore.save($0) },
                ledger: .defaults,
                ownsRefresh: Bundle.main.bundleURL.pathExtension != "appex",
                record: { trigger, outcome in
                    Log.auth.notice("refresh \(outcome, privacy: .public) (trigger \(trigger, privacy: .public), device \(DeviceClass.current.rawValue, privacy: .public))")
                }
            )
        }
    }

    enum Trigger {
        @TaskLocal static var current = "unspecified"
    }

    private let environment: Environment
    private var tail: Task<Void, Never>?
    private var lastVerdict: (lineage: String?, outcome: SoundCloudTokenRefresh.Outcome, wasLocalGuard: Bool, at: Date)?
    private(set) var networkRefreshes = 0

    init(environment: Environment) {
        self.environment = environment
    }

    var recentOutcome: SoundCloudTokenRefresh.Outcome? {
        guard let verdict = currentVerdict() else { return nil }
        return verdict.outcome
    }

    var recentOutcomeWasLocalGuard: Bool { currentVerdict()?.wasLocalGuard ?? false }

    private func currentVerdict() -> (lineage: String?, outcome: SoundCloudTokenRefresh.Outcome, wasLocalGuard: Bool, at: Date)? {
        guard let lastVerdict, lastVerdict.lineage == DeviceSessionStore.load()?.lineage else { return nil }
        let lifetime = lastVerdict.outcome == .transient
            ? TokenRefreshCoordinator.transientVerdictLifetime
            : TokenRefreshCoordinator.verdictLifetime
        guard Date().timeIntervalSince(lastVerdict.at) < lifetime else { return nil }
        return lastVerdict
    }

    var onRotation: (@MainActor (_ previous: StoredSession, _ renewed: StoredSession) -> Void)?

    func renew(_ session: StoredSession, trigger: String? = nil, adoptsNewerStored: Bool = true) async -> SoundCloudTokenRefresh.Outcome {
        let trigger = trigger ?? Trigger.current
        let previous = tail
        let work = Task { @MainActor [self] in
            await previous?.value
            return await self.renewSerially(session, trigger: trigger, adoptsNewerStored: adoptsNewerStored)
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    private func renewSerially(_ session: StoredSession, trigger: String, adoptsNewerStored: Bool) async -> SoundCloudTokenRefresh.Outcome {
        guard session.canSelfRefresh else {
            lastVerdict = (session.lineage, .unrecoverable, true, Date())
            environment.record(trigger, "skipped, no refresh material")
            return .unrecoverable
        }

        if adoptsNewerStored, let stored = environment.reloadStored(),
           stored.lineage != session.lineage,
           stored.canSelfRefresh,
           !environment.ledger.rejects(stored),
           stored.isNewer(than: session) || environment.ledger.rejects(session) {
            environment.record(trigger, "adopted the newer stored pair, no request")
            return .succeeded(stored.asCredentials)
        }

        if environment.ledger.rejects(session) {
            lastVerdict = (session.lineage, .unrecoverable, false, Date())
            environment.record(trigger, "skipped, SoundCloud already refused this refresh token")
            return .unrecoverable
        }

        guard environment.ownsRefresh else {
            environment.record(trigger, "deferred to the app")
            return .transient
        }

        networkRefreshes += 1
        let outcome = await NetworkActivityLog.$detail.withValue("refresh on \(DeviceClass.current.rawValue), \(trigger)") {
            await environment.perform(session.refreshToken, session.clientId)
        }
        lastVerdict = (session.lineage, outcome, false, Date())

        switch outcome {
        case .succeeded(let credentials):
            let renewed = session.applying(credentials)
            environment.save(renewed)
            environment.record(trigger, "succeeded, generation \(renewed.generation ?? 0)")
            onRotation?(session, renewed)
            return .succeeded(renewed.asCredentials)
        case .unrecoverable:
            if let lineage = session.lineage { environment.ledger.insert(lineage) }
            environment.record(trigger, "refused")
            return outcome
        case .transient:
            environment.record(trigger, "inconclusive")
            return outcome
        }
    }

    @discardableResult
    func refresh(_ session: StoredSession, trigger: String? = nil, adoptsNewerStored: Bool = true) async -> StoredSession? {
        guard case .succeeded(let credentials) = await renew(session, trigger: trigger, adoptsNewerStored: adoptsNewerStored) else { return nil }
        return session.applying(credentials)
    }

    func refreshIfNeeded(_ session: StoredSession, trigger: String? = nil) async -> StoredSession {
        guard session.shouldRefreshBeforeHandoff else { return session }
        return await refresh(session, trigger: trigger) ?? session
    }

    func reset() {
        lastVerdict = nil
    }
}
