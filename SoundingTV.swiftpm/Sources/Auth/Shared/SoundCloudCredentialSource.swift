import Foundation
import Combine
import os

@MainActor
final class SoundCloudCredentialSource: ObservableObject {
    static let shared = SoundCloudCredentialSource()

    struct SideEffects {
        var requestSessionSync: (() -> Void)?
        var wipeLocalIndexes: (() async -> Void)?
        var clearWebSession: (() async -> Void)?
    }

    var sideEffects = SideEffects()

    @Published private(set) var currentUser: User?

    @Published private(set) var isSignedOut = false

    @Published private(set) var isAuthenticated = false

    enum SignOutReason: Equatable {
        case accountRejected
        case noRefreshCapability
    }

    @Published private(set) var lastSignOutReason: SignOutReason?

    typealias RejectionKind = SoundCloudSessionRejection
    typealias SessionHealth = SoundCloudSessionHealth

    @Published private(set) var sessionHealth: SessionHealth = .signedOut

    var isSessionRejected: Bool { sessionHealth.isRejected }

    var needsSignIn: Bool { sessionHealth.needsSignIn }

    var canRetrySession: Bool { sessionHealth.canRetry }
    var canBrowsePublicContent: Bool { true }
    var canPerformAccountMutations: Bool { isAuthenticated && sessionHealth == .healthy }
    var canReadCachedAccountData: Bool { !isSignedOut || lockedDataDeletionDate != nil }

    var isReadOnlySession: Bool { isSessionRejected && !isSignedOut }

    var sessionRecoveryMessage: String? {
        guard isReadOnlySession else { return nil }
        return "Your saved data is still available, but SoundCloud needs you to reauthenticate before live updates, playback, or changes can continue."
    }

    private var lastRejection: RejectionKind?

    private var rejectedSessionDigest: String?

    private var hasSucceededSinceStoreChange = false

    private var sessionGeneration: UInt64 = 0

    private var currentUserTask: Task<User?, Never>?

    private static let lockedCacheAccountIDKey = "red.forbes.sounding.lockedCacheAccountID"
    private static let lockedDataPurgedForSignOutKey = "red.forbes.sounding.lockedDataPurgedForSignOut"
    static let lockedDataGracePeriod: TimeInterval = 7 * 24 * 60 * 60

    var lockedDataDeletionDate: Date? {
        guard isSignedOut,
              let millis = SessionSyncBookkeeping.localSignOutMillis() else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1_000)
            .addingTimeInterval(Self.lockedDataGracePeriod)
    }

    func purgeExpiredLockedDataIfNeeded(now: Date = Date()) async {
        guard let deletionDate = lockedDataDeletionDate, now >= deletionDate,
              let signOutMillis = SessionSyncBookkeeping.localSignOutMillis() else { return }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.lockedDataPurgedForSignOutKey) as? Int64 != signOutMillis else { return }
        await wipeLocalIndexes()
        defaults.set(signOutMillis, forKey: Self.lockedDataPurgedForSignOutKey)
        defaults.removeObject(forKey: Self.lockedCacheAccountIDKey)
    }

    private init() {}

    #if DEBUG
    private static let forcedHealth: SessionHealth? = {
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_FORCE_SESSION_HEALTH"] {
        case "signedOut":           return .signedOut
        case "unverified":          return .unverified
        case "healthy":             return .healthy
        case "rejectedAccount":     return .rejected(.accountRejected)
        case "rejectedNoRefresh":   return .rejected(.noRefreshCapability)
        case "rejectedUnreachable": return .rejected(.refreshUnreachable)
        default:                    return nil
        }
    }()
    #endif

    private func wipeLocalIndexes() async {
        await sideEffects.wipeLocalIndexes?()
    }

    private func requestSessionSync() {
        sideEffects.requestSessionSync?()
    }

    private func publishHealth(_ health: SessionHealth) {
        #if DEBUG
        if let forced = Self.forcedHealth {
            sessionHealth = forced
            return
        }
        #endif
        sessionHealth = health
    }

    private static func digest(of session: StoredSession) -> String {
        SessionSyncBookkeeping.digest(
            oauthToken: session.oauthToken,
            refreshToken: session.refreshToken,
            clientId: session.clientId,
            expiresAtMillis: session.expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        )
    }

    private func recomputeHealth() {
        let session = DeviceSessionStore.load()

        if let session, let digest = rejectedSessionDigest, Self.digest(of: session) != digest {
            lastRejection = nil
            rejectedSessionDigest = nil
            hasSucceededSinceStoreChange = false
        }

        publishHealth(SoundCloudCredentialSourcePolicy.health(
            hasUsableSession: session?.isUsable == true,
            rejection: lastRejection,
            hasSucceeded: hasSucceededSinceStoreChange
        ))
    }

    private func markRejected(_ kind: RejectionKind) {
        lastRejection = kind
        rejectedSessionDigest = DeviceSessionStore.load().map(Self.digest(of:))
        hasSucceededSinceStoreChange = false
        isAuthenticated = false
        switch kind {
        case .accountRejected:     lastSignOutReason = .accountRejected
        case .noRefreshCapability: lastSignOutReason = .noRefreshCapability
        case .refreshUnreachable:  break // not a sign-out; the session is kept
        }
        recomputeHealth()
    }

    static func install() {
        SoundCloudAPI.credentials = shared
        #if DEBUG
        shared.seedDevCredentialIfAvailable()
        #endif
        shared.refreshFromStore()
    }

    #if DEBUG
    func seedDevCredentialIfAvailable() {
        Self.seedFromDevCredentialAtLaunch()
    }

    private static func seedFromDevCredentialAtLaunch() {
        if let supplied = DevCredentialStore.loadFromEnvironment() {
            guard DeviceSessionStore.load() != supplied else { return }
            if DeviceSessionStore.hasLocalSignOut {
                Log.link.debug("[SoundCloudCredentialSource] SOUNDING_TV_DEV_TOKEN supplied — lifting the recorded local sign-out for this launch")
                DeviceSessionStore.clearLocalSignOut()
            }
            DeviceSessionStore.save(supplied)
            if ProcessInfo.processInfo.environment["SOUNDING_TV_PERSIST_DEV_CREDENTIAL"] == "1" {
                _ = DevCredentialStore.save(supplied)
            }
            return
        }

        guard DeviceSessionStore.load() == nil else { return }
        guard !DeviceSessionStore.hasLocalSignOut else {
            Log.link.debug("[SoundCloudCredentialSource] dev credential cache suppressed — this device has a recorded sign-out")
            return
        }
        guard let cached = DevCredentialStore.load() else { return }
        DeviceSessionStore.save(cached)
    }
    #endif

    func refreshIfNeededAtLaunch() async {
        guard let session = DeviceSessionStore.load(), session.shouldRefreshBeforeHandoff else { return }

        _ = await DeviceSessionRefresher.shared.refreshIfNeeded(session)

        if DeviceSessionRefresher.shared.recentOutcome == .unrecoverable {
            DeviceSessionRefresher.shared.reset()
            sessionGeneration &+= 1
            lastSignOutReason = .accountRejected
            isSignedOut = false
            isAuthenticated = false
            markRejected(.accountRejected)
            notifyAuthenticationChanged()
        } else {
            refreshFromStore()
            _ = currentSessionForSync()
            requestSessionSync()
        }
    }

    func refreshFromStore() {
        isSignedOut = DeviceSessionStore.load()?.isUsable != true
        if isSignedOut {
            currentUser = nil
            lastRejection = nil
            rejectedSessionDigest = nil
            hasSucceededSinceStoreChange = false
        } else {
            lastSignOutReason = nil
        }
        recomputeHealth()
        isAuthenticated = !isSignedOut && !isSessionRejected
    }

    func signOut() async {
        if let accountID = currentUser?.id ?? SubscriptionService.shared.authenticatedAccountID {
            UserDefaults.standard.set(accountID, forKey: Self.lockedCacheAccountIDKey)
        }
        DeviceSessionStore.forget()
        DeviceSessionRefresher.shared.reset()
        sessionGeneration &+= 1
        currentUserTask = nil
        currentUser = nil

        await sideEffects.clearWebSession?()

        lastSignOutReason = nil
        lastRejection = nil
        rejectedSessionDigest = nil
        hasSucceededSinceStoreChange = false
        isSignedOut = true
        isAuthenticated = false
        publishHealth(.signedOut)
        notifyAuthenticationChanged()

        requestSessionSync()
    }

    func didCompleteSignIn() {
        DeviceSessionRefresher.shared.reset()
        sessionGeneration &+= 1
        currentUserTask = nil
        currentUser = nil
        lastSignOutReason = nil
        lastRejection = nil
        rejectedSessionDigest = nil
        hasSucceededSinceStoreChange = false
        UserDefaults.standard.removeObject(forKey: Self.lockedDataPurgedForSignOutKey)
        refreshFromStore()
        _ = currentSessionForSync()
        requestSessionSync()
        Task {
            let user = await waitForCurrentUser()
            if let lockedAccountID = UserDefaults.standard.string(forKey: Self.lockedCacheAccountIDKey) {
                if let user, user.id != lockedAccountID { await wipeLocalIndexes() }
                UserDefaults.standard.removeObject(forKey: Self.lockedCacheAccountIDKey)
            }
        }
        notifyAuthenticationChanged()
    }

    @discardableResult
    func revalidate() async -> SessionHealth {
        guard DeviceSessionStore.load()?.isUsable == true else {
            refreshFromStore()
            return sessionHealth
        }
        currentUserTask = nil
        let generation = sessionGeneration
        let user = try? await SoundCloudAPI.shared.getCurrentUser()
        guard generation == sessionGeneration else { return sessionHealth }
        if let user {
            currentUser = user
            noteAuthenticatedRequestSucceeded()
        }
        return sessionHealth
    }
}

@MainActor
enum SoundCloudCredentialSourcePolicy {

    static func health(
        hasUsableSession: Bool,
        rejection: SoundCloudCredentialSource.RejectionKind?,
        hasSucceeded: Bool
    ) -> SoundCloudCredentialSource.SessionHealth {
        guard hasUsableSession else { return .signedOut }
        if let rejection { return .rejected(rejection) }
        return hasSucceeded ? .healthy : .unverified
    }

    enum DevSeedAction: Equatable {
        case skipStoreOccupied
        case skipSuppressedBySignOut
        case skipNoCredential
        case seedFromEnvironment(liftsSignOut: Bool)
        case seedFromCache
    }

    static func devSeedAction(
        storeIsEmpty: Bool,
        hasLocalSignOut: Bool,
        hasEnvironmentToken: Bool,
        hasCachedCredential: Bool
    ) -> DevSeedAction {
        guard storeIsEmpty else { return .skipStoreOccupied }
        if hasEnvironmentToken { return .seedFromEnvironment(liftsSignOut: hasLocalSignOut) }
        if hasLocalSignOut { return .skipSuppressedBySignOut }
        return hasCachedCredential ? .seedFromCache : .skipNoCredential
    }
}


extension SoundCloudCredentialSource: SoundCloudCredentialSourcing {
    var accessToken: String? {
        guard !isSessionRejected else { return nil }
        guard let session = DeviceSessionStore.load(), session.isUsable else { return nil }
        return session.oauthToken
    }

    func waitForCurrentUser() async -> User? {
        if let currentUser { return currentUser }
        if let currentUserTask { return await currentUserTask.value }
        guard accessToken != nil else { return nil }

        let generation = sessionGeneration
        let task = Task<User?, Never> {
            try? await SoundCloudAPI.shared.getCurrentUser()
        }
        currentUserTask = task
        let user = await task.value
        guard generation == sessionGeneration else { return nil }
        currentUserTask = nil
        if let user { currentUser = user }
        return user
    }

    func noteAuthenticatedRequestSucceeded() {
        lastRejection = nil
        rejectedSessionDigest = nil
        hasSucceededSinceStoreChange = true
        guard sessionHealth != .healthy else { return }
        lastSignOutReason = nil
        isSignedOut = false
        isAuthenticated = true
        publishHealth(.healthy)
    }

    func refreshAccessToken() async -> Bool {
        guard let session = DeviceSessionStore.load() else { return false }
        guard await DeviceSessionRefresher.shared.refresh(session) != nil else { return false }
        lastRejection = nil
        rejectedSessionDigest = nil
        hasSucceededSinceStoreChange = false
        refreshFromStore()
        _ = currentSessionForSync()
        requestSessionSync()
        return true
    }

    func handleUnauthorized() async {
        guard DeviceSessionStore.load() != nil else {
            currentUser = nil
            isSignedOut = true
            isAuthenticated = false
            recomputeHealth()
            notifyAuthenticationChanged()
            return
        }

        if DeviceSessionRefresher.shared.recentOutcome == .transient {
            Log.link.error("[SoundCloudCredentialSource] 401 with an unreachable refresh endpoint — keeping the session, reporting it as not working")
            markRejected(.refreshUnreachable)
            return
        }

        let reason: SignOutReason = DeviceSessionRefresher.shared.recentOutcomeWasLocalGuard
            ? .noRefreshCapability
            : .accountRejected
        Log.link.error("[SoundCloudCredentialSource] 401, cannot recover locally (\(String(describing: reason), privacy: .public)) — preserving cached data in read-only mode")

        DeviceSessionRefresher.shared.reset()
        sessionGeneration &+= 1
        currentUserTask = nil
        lastSignOutReason = reason
        isSignedOut = false
        isAuthenticated = false
        markRejected(reason == .accountRejected ? .accountRejected : .noRefreshCapability)
        notifyAuthenticationChanged()
    }

    private func notifyAuthenticationChanged() {
        NotificationCenter.default.post(name: .soundCloudAuthenticationChanged, object: nil)
    }
}

extension SoundCloudCredentialSource: SoundCloudSessionSyncSource {
    func currentSessionForSync() -> SyncedSoundCloudSession? {
        guard let session = DeviceSessionStore.load(), session.isUsable else { return nil }
        let expiresAtMillis = session.expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        let digest = SessionSyncBookkeeping.digest(
            oauthToken: session.oauthToken, refreshToken: session.refreshToken,
            clientId: session.clientId, expiresAtMillis: expiresAtMillis
        )
        return SyncedSoundCloudSession(
            oauthToken: session.oauthToken,
            refreshToken: session.refreshToken,
            clientId: session.clientId,
            expiresAtMillis: expiresAtMillis,
            updatedAtMillis: SessionSyncBookkeeping.recordIfChanged(digest: digest),
            writerId: SessionSyncBookkeeping.writerId()
        )
    }

    func adoptSyncedSession(_ session: SyncedSoundCloudSession) async {
        DeviceSessionStore.save(StoredSession(
            oauthToken: session.oauthToken,
            refreshToken: session.refreshToken,
            clientId: session.clientId,
            expiresAt: session.expiresAtMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        ))
        let digest = SessionSyncBookkeeping.digest(
            oauthToken: session.oauthToken, refreshToken: session.refreshToken,
            clientId: session.clientId, expiresAtMillis: session.expiresAtMillis
        )
        SessionSyncBookkeeping.adoptForeignProvenance(updatedAtMillis: session.updatedAtMillis, digest: digest)

        DeviceSessionRefresher.shared.reset()
        sessionGeneration &+= 1
        currentUserTask = nil
        isSignedOut = false
        isAuthenticated = true
        lastSignOutReason = nil
        lastRejection = nil
        rejectedSessionDigest = nil
        hasSucceededSinceStoreChange = false
        currentUser = nil
        recomputeHealth()
        _ = await waitForCurrentUser()
        notifyAuthenticationChanged()
    }
}
