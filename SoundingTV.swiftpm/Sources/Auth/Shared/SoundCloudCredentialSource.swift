import Foundation
import Combine
import os

@MainActor
final class SoundCloudCredentialSource: ObservableObject {
    static let shared = SoundCloudCredentialSource()

    struct SideEffects {
        var requestSessionSync: (() -> Void)?
        var wipeLocalIndexes: ((String?) async -> Void)?
        var clearWebSession: (() async -> Void)?
        var propagateRotation: ((_ previous: StoredSession, _ renewed: StoredSession) -> Void)?
    }

    var sideEffects = SideEffects()

    var recoverySources: [SoundCloudSessionRenewal.Source] = []

    struct PublishedAuthState: Equatable {
        var currentUser: User?
        var isSignedOut: Bool
        var isAuthenticated: Bool
        var lastSignOutReason: SignOutReason?
        var sessionHealth: SessionHealth
        var signInGeneration: UInt64 = 0
        var lastKnownUser: User? = nil
    }

    typealias AccountStatus = SoundCloudAccountStatus

    enum SignOutReason: Equatable {
        case accountRejected
        case noRefreshCapability
    }

    typealias RejectionKind = SoundCloudSessionRejection
    typealias SessionHealth = SoundCloudSessionHealth

    @Published private(set) var state = PublishedAuthState(
        currentUser: nil,
        isSignedOut: false,
        isAuthenticated: false,
        lastSignOutReason: nil,
        sessionHealth: .unverified
    )

    @Published private(set) var isEstablishingSessionAtLaunch = true

    @Published private(set) var isRecoveringSession = false
    @Published private(set) var isRenewingAtLaunch = false

    var isConnecting: Bool { !isSignedOut && (isRecoveringSession || isRenewingAtLaunch) }
    static let connectingTitle = "Connecting to SoundCloud…"

    var currentUser: User? { state.currentUser }
    var accountUser: User? { isSignedOut ? nil : (state.currentUser ?? state.lastKnownUser) }
    var isSignedOut: Bool { state.isSignedOut }
    var isAuthenticated: Bool { state.isAuthenticated }
    var lastSignOutReason: SignOutReason? { state.lastSignOutReason }
    var sessionHealth: SessionHealth { state.sessionHealth }

    var accountStatus: AccountStatus {
        SoundCloudAccountStatus.resolve(
            isEstablishingSessionAtLaunch: holdsAccountPresentation,
            isSignedOut: isSignedOut,
            health: sessionHealth
        )
    }

    private var holdsAccountPresentation: Bool { isEstablishingSessionAtLaunch || isRecoveringSession }

    var hasAccount: Bool { accountStatus != .signedOut }

    var isSessionRejected: Bool { accountStatus == .needsReconnect }

    var needsSignIn: Bool {
        SoundCloudCredentialSourcePolicy.needsSignIn(
            isEstablishingSessionAtLaunch: holdsAccountPresentation,
            isSignedOut: isSignedOut,
            healthNeedsSignIn: sessionHealth.needsSignIn,
            hasExplicitLocalSignOut: DeviceSessionStore.hasLocalSignOut
        )
    }

    var canRetrySession: Bool { sessionHealth.canRetry }
    var canPerformAccountMutations: Bool { isAuthenticated && sessionHealth == .healthy }
    var hasConfirmedAccount: Bool {
        isAuthenticated && sessionHealth == .healthy && currentUser != nil
    }

    var isReadOnlySession: Bool {
        !holdsAccountPresentation && sessionHealth.isRejected && !isSignedOut
    }

    var sessionRecoveryTitle: String? {
        guard isReadOnlySession else { return nil }
        return canRetrySession ? "Couldn't Renew SoundCloud Sign-In" : "Reconnect SoundCloud"
    }

    var sessionRecoveryActionTitle: String? {
        guard isReadOnlySession else { return nil }
        return canRetrySession ? "Try Again" : "Reconnect"
    }

    var sessionRecoveryMessage: String? {
        guard isReadOnlySession else { return nil }
        if canRetrySession {
            return "SoundCloud couldn't renew this sign-in right now. Your session and cached data are still here, and the app will try again later."
        }
        #if os(tvOS) || os(watchOS)
        return "Open Sounding on your iPhone to reconnect."
        #else
        return "Sounding couldn't renew this SoundCloud sign-in. Your cached data is still here; reconnect to restore account content, playback, and changes."
        #endif
    }

    private var lastRejection: RejectionKind?

    private var rejectedSessionDigest: String?

    private var hasSucceededSinceStoreChange = false

    private var sessionGeneration: UInt64 = 0

    private var currentUserTask: Task<User?, Never>?

    private var storePreparationTask: Task<StoredSession?, Never>?
    private var didPrepareStoreAtLaunch = false
    private var launchSessionTask: Task<Void, Never>?
    private var didEstablishSessionAtLaunch = false

    private var renewalTask: Task<SoundCloudSessionRenewal.Outcome, Never>?
    private var sessionRecoveryTask: Task<SoundCloudSessionRecovery.Result, Never>?
    private var sessionRecoveryGeneration: UInt64 = 0
    private var lastUnresolvedRecovery: (digest: String, at: Date)?
    static let recoveryCooldown: TimeInterval = 60
    private var renewalRetryTask: Task<Void, Never>?
    private var renewalRetryAttempt = 0
    private var lastRenewalVerdict: (digest: String?, outcome: SoundCloudSessionRenewal.Outcome, at: Date)?
    static let renewalVerdictLifetime: TimeInterval = 30

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
        await prepareStoreAtLaunch()
        guard let deletionDate = lockedDataDeletionDate, now >= deletionDate,
              let signOutMillis = SessionSyncBookkeeping.localSignOutMillis() else { return }
        let defaults = UserDefaults.sounding
        guard defaults.object(forKey: Self.lockedDataPurgedForSignOutKey) as? Int64 != signOutMillis else { return }
        let accountID = defaults.string(forKey: Self.lockedCacheAccountIDKey)
        await wipeLocalIndexes(accountID: accountID)
        defaults.set(signOutMillis, forKey: Self.lockedDataPurgedForSignOutKey)
        defaults.removeObject(forKey: Self.lockedCacheAccountIDKey)
    }

    private init() {
        DeviceSessionRefresher.shared.onRotation = { [weak self] previous, renewed in
            self?.sessionDidRotate(from: previous, to: renewed)
        }
    }

    private func sessionDidRotate(from previous: StoredSession, to renewed: StoredSession) {
        _ = currentSessionForSync()
        requestSessionSync()
        sideEffects.propagateRotation?(previous, renewed)
    }

    private var renewalEnvironment: SoundCloudSessionRenewal.Environment {
        SoundCloudSessionRenewal.Environment(
            load: { DeviceSessionStore.load() },
            save: { DeviceSessionStore.save($0) },
            refresh: { await DeviceSessionRefresher.shared.renew($0) },
            validate: { await SoundCloudAPI.shared.validateToken($0) },
            isTrafficStopped: {
                if case .waiting = SoundCloudAPI.shared.trafficSafetyState() { return true }
                return false
            },
            isRejectedLineage: { RejectedLineageLedger.defaults.rejects($0) }
        )
    }

    static let recentSuccessWindow: TimeInterval = 10
    private var lastAuthenticatedSuccess: (digest: String, at: Date)?

    var isRenewing: Bool { renewalTask != nil }

    func waitForRenewal() async {
        if let renewalTask { _ = await renewalTask.value }
        if let sessionRecoveryTask { _ = await sessionRecoveryTask.value }
    }

    var holdsAuthenticatedRequests: Bool {
        SoundCloudCredentialSourcePolicy.holdsAuthenticatedRequests(
            isSignedOut: isSignedOut,
            hasStoredSession: DeviceSessionStore.load() != nil,
            health: sessionHealth
        )
    }

    private func wasRecentlyAccepted(_ session: StoredSession, now: Date = Date()) -> Bool {
        guard let lastAuthenticatedSuccess else { return false }
        return lastAuthenticatedSuccess.digest == Self.digest(of: session)
            && now.timeIntervalSince(lastAuthenticatedSuccess.at) < Self.recentSuccessWindow
    }

    private func runRenewal(
        trigger: String,
        _ operation: @escaping @MainActor (SoundCloudSessionRenewal) async -> SoundCloudSessionRenewal.Outcome
    ) async -> SoundCloudSessionRenewal.Outcome {
        if let renewalTask { return await renewalTask.value }

        let digestBefore = DeviceSessionStore.load().map(Self.digest(of:))
        if let verdict = lastRenewalVerdict,
           verdict.digest == digestBefore,
           Date().timeIntervalSince(verdict.at) < Self.renewalVerdictLifetime {
            return verdict.outcome
        }

        let renewal = SoundCloudSessionRenewal(environment: renewalEnvironment, sources: recoverySources)
        let task = Task { @MainActor in
            await DeviceSessionRefresher.Trigger.$current.withValue(trigger) { await operation(renewal) }
        }
        renewalTask = task
        let outcome = await task.value
        renewalTask = nil
        Log.link.info("[SoundCloudCredentialSource] session renewal finished: \(String(describing: outcome), privacy: .public)")

        switch outcome {
        case .refreshed:
            lastRenewalVerdict = nil
            lastRejection = nil
            rejectedSessionDigest = nil
            hasSucceededSinceStoreChange = true
            refreshFromStore()
            _ = currentSessionForSync()
            requestSessionSync()
        case .adopted:
            lastRenewalVerdict = nil
            DeviceSessionRefresher.shared.reset()
            currentUserTask = nil
            _ = currentSessionForSync()
            requestSessionSync()
            noteAuthenticatedRequestSucceeded()
        case .temporarilyUnavailable, .exhausted:
            lastRenewalVerdict = (DeviceSessionStore.load().map(Self.digest(of:)), outcome, Date())
        }
        if outcome.renewed { resetRenewalRetry() }
        if outcome == .temporarilyUnavailable { scheduleRenewalRetry(because: "renewal could not finish") }
        return outcome
    }

    func adoptRotatedSession(_ session: StoredSession, replacingLineage lineage: String) -> Bool {
        guard let local = DeviceSessionStore.load(),
              SessionSyncBookkeeping.lineageDigest(refreshToken: local.refreshToken) == lineage,
              session.canSelfRefresh,
              Self.digest(of: session) != Self.digest(of: local) else { return false }
        DeviceSessionStore.save(session)
        DeviceSessionRefresher.shared.reset()
        lastRenewalVerdict = nil
        lastRejection = nil
        rejectedSessionDigest = nil
        hasSucceededSinceStoreChange = true
        mutateState(because: "adopted a rotated session") { $0.lastSignOutReason = nil }
        refreshFromStore()
        _ = currentSessionForSync()
        requestSessionSync()
        return true
    }

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

    private func wipeLocalIndexes(accountID: String? = nil) async {
        await sideEffects.wipeLocalIndexes?(accountID)
    }

    private func requestSessionSync() {
        sideEffects.requestSessionSync?()
    }

    private func mutateState(because reason: String, _ mutation: (inout PublishedAuthState) -> Void) {
        let previousStatus = accountStatus
        var next = state
        mutation(&next)
        if next.isSignedOut {
            next.lastKnownUser = nil
        } else if let user = next.currentUser {
            next.lastKnownUser = user
        }
        if let confirmedID = next.currentUser?.id, confirmedID != state.currentUser?.id {
            UserDefaults.sounding.set(confirmedID, forKey: Self.lockedCacheAccountIDKey)
        }
        let previousHealth = state.sessionHealth
        state = next
        if previousHealth != next.sessionHealth || previousStatus != accountStatus {
            Log.auth.notice("health \(String(describing: previousHealth), privacy: .public) -> \(String(describing: next.sessionHealth), privacy: .public), account \(String(describing: previousStatus), privacy: .public) -> \(String(describing: self.accountStatus), privacy: .public): \(reason, privacy: .public)")
        }
    }

    private func publishHealth(_ health: SessionHealth, because reason: String) {
        #if DEBUG
        if let forced = Self.forcedHealth {
            mutateState(because: "forced by SOUNDING_TV_FORCE_SESSION_HEALTH") { $0.sessionHealth = forced }
            return
        }
        #endif
        mutateState(because: reason) { $0.sessionHealth = health }
    }

    private static func digest(of session: StoredSession) -> String {
        SessionSyncBookkeeping.digest(
            oauthToken: session.oauthToken,
            refreshToken: session.refreshToken,
            clientId: session.clientId,
            expiresAtMillis: session.expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        )
    }

    private func computeHealth(using session: StoredSession?) -> SessionHealth {
        if let session, let digest = rejectedSessionDigest, Self.digest(of: session) != digest {
            lastRejection = nil
            rejectedSessionDigest = nil
            hasSucceededSinceStoreChange = false
        }

        return SoundCloudCredentialSourcePolicy.health(
            hasUsableSession: session?.isUsable == true,
            rejection: lastRejection,
            hasSucceeded: hasSucceededSinceStoreChange
        )
    }

    private func computeHealth() -> SessionHealth {
        computeHealth(using: DeviceSessionStore.load())
    }

    private func recomputeHealth(using session: StoredSession?) {
        publishHealth(computeHealth(using: session), because: "recomputed from the stored session")
    }

    private func recomputeHealth() {
        recomputeHealth(using: DeviceSessionStore.load())
    }

    private func markRejected(_ kind: RejectionKind, because reason: String) {
        resetRenewalRetry()
        if let accountID = currentUser?.id {
            UserDefaults.sounding.set(accountID, forKey: Self.lockedCacheAccountIDKey)
        }
        lastRejection = kind
        rejectedSessionDigest = DeviceSessionStore.load().map(Self.digest(of:))
        hasSucceededSinceStoreChange = false
        let signOutReason: SignOutReason? = switch kind {
        case .accountRejected:     .accountRejected
        case .noRefreshCapability: .noRefreshCapability
        case .refreshUnreachable:  nil
        }
        let health = computeHealth()
        mutateState(because: reason) {
            $0.isAuthenticated = false
            $0.lastSignOutReason = signOutReason
            $0.sessionHealth = health
        }
    }

    static func install() {
        SoundCloudAPI.credentials = shared
        #if DEBUG
        let fixtureValue = ProcessInfo.processInfo.environment["SOUNDING_TV_UI_FIXTURE"]?.lowercased()
        let usesVisualFixtures = fixtureValue == "1" || fixtureValue == "loaded" || fixtureValue == "true"
            || ProcessInfo.processInfo.arguments.contains("--ui-fixture")
            || UserDefaults.sounding.bool(forKey: "SOUNDING_TV_UI_FIXTURE")
        if usesVisualFixtures { return }
        #endif
        Task { await shared.prepareStoreAtLaunch() }
    }

    func resolveLaunchStateFromLocalStore() {
        guard !didPrepareStoreAtLaunch else { return }
        #if DEBUG
        Self.seedFromDevCredentialAtLaunch()
        #endif
        let session = DeviceSessionStore.load()
        if session?.isUsable != true, !DeviceSessionStore.hasLocalSignOut {
            isEstablishingSessionAtLaunch = false
        }
        applyStoredSession(session)
        didPrepareStoreAtLaunch = true
    }

    func prepareStoreAtLaunch() async {
        guard !didPrepareStoreAtLaunch else { return }
        #if DEBUG
        if let user = Self.visualFixtureUser {
            applyVisualFixtureSession(user)
            return
        }
        #endif

        let task: Task<StoredSession?, Never>
        if let existing = storePreparationTask {
            task = existing
        } else {
            task = Task.detached(priority: .userInitiated) {
                #if DEBUG
                Self.seedFromDevCredentialAtLaunch()
                #endif
                return DeviceSessionStore.load()
            }
            storePreparationTask = task
        }

        let session = await task.value
        guard !didPrepareStoreAtLaunch else { return }
        applyStoredSession(session)
        didPrepareStoreAtLaunch = true
        storePreparationTask = nil
    }

    #if DEBUG
    static var visualFixtureUser: User?

    private func applyVisualFixtureSession(_ user: User) {
        didPrepareStoreAtLaunch = true
        isEstablishingSessionAtLaunch = false
        let forced = Self.forcedHealth
        let signedIn = forced != .signedOut
        mutateState(because: "visual fixture session") {
            $0.currentUser = signedIn ? user : nil
            $0.isSignedOut = forced == .signedOut
            $0.isAuthenticated = forced == nil || forced == .healthy
            $0.lastSignOutReason = forced?.needsSignIn == true && forced != .signedOut ? .accountRejected : nil
            $0.sessionHealth = forced ?? .healthy
        }
    }

    nonisolated func seedDevCredentialIfAvailable() {
        Self.seedFromDevCredentialAtLaunch()
    }

    nonisolated private static func seedFromDevCredentialAtLaunch() {
        if ProcessInfo.processInfo.environment["SOUNDING_TV_PRINT_DEV_SESSION"] == "1" {
            let payload = DeviceSessionStore.load().flatMap { try? JSONEncoder().encode($0) }
            print("[DEV_SESSION_B64]" + (payload?.base64EncodedString() ?? "none"))
            fflush(stdout)
            exit(0)
        }
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
        await prepareStoreAtLaunch()
        guard let session = DeviceSessionStore.load(), session.isExpired else { return }

        isRenewingAtLaunch = true
        let outcome = await runRenewal(trigger: "launch, token expired") { await $0.renew() }
        if outcome == .exhausted {
            _ = beginSessionRecovery(validateFirst: true, because: "launch renewal found no usable session")
        }
        isRenewingAtLaunch = false
    }

    private static func rejectionKind(for session: StoredSession?, refreshWasLocalGuard: Bool) -> RejectionKind {
        if refreshWasLocalGuard || session?.canSelfRefresh == false { return .noRefreshCapability }
        return .accountRejected
    }

    func establishSessionAtLaunch() async {
        guard !didEstablishSessionAtLaunch else { return }

        let task: Task<Void, Never>
        if let existing = launchSessionTask {
            task = existing
        } else {
            task = Task { @MainActor in
                await self.refreshIfNeededAtLaunch()
                if !self.isSignedOut, self.sessionRecoveryTask == nil {
                    _ = await self.revalidate()
                }
            }
            launchSessionTask = task
        }

        await task.value
        guard !didEstablishSessionAtLaunch else { return }
        didEstablishSessionAtLaunch = true
        launchSessionTask = nil
        isEstablishingSessionAtLaunch = false
        refreshFromStore()
    }

    func refreshFromStore() {
        #if DEBUG
        if Self.visualFixtureUser != nil { return }
        #endif
        guard didPrepareStoreAtLaunch else {
            Task { await prepareStoreAtLaunch() }
            return
        }
        applyStoredSession(DeviceSessionStore.load())
    }

    private func applyStoredSession(_ session: StoredSession?) {
        let isSignedOut = session?.isUsable != true
        if isSignedOut, isEstablishingSessionAtLaunch, !DeviceSessionStore.hasLocalSignOut {
            return
        }
        if isSignedOut {
            lastRejection = nil
            rejectedSessionDigest = nil
            hasSucceededSinceStoreChange = false
        }
        let health = computeHealth(using: session)
        mutateState(because: isSignedOut ? "no usable stored session" : "applied the stored session") {
            $0.isSignedOut = isSignedOut
            if isSignedOut { $0.currentUser = nil }
            $0.lastSignOutReason = isSignedOut ? nil : $0.lastSignOutReason
            $0.sessionHealth = health
            $0.isAuthenticated = health == .healthy
        }
    }

    func signOutThisDevice(tokenIsShared: Bool) async {
        await signOut(revoking: SessionRevocation.decide(scope: .thisDevice, tokenIsShared: tokenIsShared))
    }

    func signOutEverywhere() async {
        await signOut(revoking: SessionRevocation.decide(scope: .everywhere, tokenIsShared: true))
    }

    func signOut(revoking revocation: SessionRevocation = .none) async {
        cancelSessionRecovery()
        let defaults = UserDefaults.sounding
        if revocation != .none, let token = DeviceSessionStore.load()?.oauthToken, !token.isEmpty {
            await SoundCloudSessionRevoker.revoke(revocation, token: token)
        }
        let accountID = currentUser?.id
            ?? defaults.string(forKey: Self.lockedCacheAccountIDKey)
        DeviceSessionStore.forget()
        DeviceSessionRefresher.shared.reset()
        sessionGeneration &+= 1
        currentUserTask = nil

        await wipeLocalIndexes(accountID: accountID)
        defaults.removeObject(forKey: Self.lockedCacheAccountIDKey)
        defaults.removeObject(forKey: Self.lockedDataPurgedForSignOutKey)

        await sideEffects.clearWebSession?()

        resetRenewalRetry()
        lastRenewalVerdict = nil
        lastRejection = nil
        rejectedSessionDigest = nil
        hasSucceededSinceStoreChange = false
        didEstablishSessionAtLaunch = true
        launchSessionTask?.cancel()
        launchSessionTask = nil
        isEstablishingSessionAtLaunch = false
        mutateState(because: "signed out") {
            $0.currentUser = nil
            $0.lastSignOutReason = nil
            $0.isSignedOut = true
            $0.isAuthenticated = false
            $0.sessionHealth = .signedOut
        }

        requestSessionSync()
    }

    func didCompleteSignIn() {
        DeviceSessionRefresher.shared.reset()
        sessionGeneration &+= 1
        currentUserTask = nil
        cancelSessionRecovery()
        resetRenewalRetry()
        lastRenewalVerdict = nil
        lastRejection = nil
        rejectedSessionDigest = nil
        hasSucceededSinceStoreChange = false
        didEstablishSessionAtLaunch = true
        launchSessionTask?.cancel()
        launchSessionTask = nil
        isEstablishingSessionAtLaunch = false
        UserDefaults.sounding.removeObject(forKey: Self.lockedDataPurgedForSignOutKey)
        mutateState(because: "sign-in completed") {
            $0.currentUser = nil
            $0.lastKnownUser = nil
            $0.lastSignOutReason = nil
            $0.signInGeneration &+= 1
        }
        refreshFromStore()
        _ = currentSessionForSync()
        requestSessionSync()
        Task {
            let user = await waitForCurrentUser()
            if let lockedAccountID = UserDefaults.sounding.string(forKey: Self.lockedCacheAccountIDKey) {
                if let user, user.id != lockedAccountID {
                    await wipeLocalIndexes(accountID: lockedAccountID)
                }
                UserDefaults.sounding.removeObject(forKey: Self.lockedCacheAccountIDKey)
            }
        }
    }

    @discardableResult
    func revalidate() async -> SessionHealth {
        await prepareStoreAtLaunch()
        #if DEBUG
        if Self.visualFixtureUser != nil { return sessionHealth }
        #endif
        if let stored = DeviceSessionStore.load(), !stored.isUsable, !stored.oauthToken.isEmpty {
            _ = await runRenewal(trigger: "revalidate, stored session unusable") { await $0.recover() }
        }
        guard DeviceSessionStore.load()?.isUsable == true else {
            refreshFromStore()
            return sessionHealth
        }
        guard accessToken != nil else { return sessionHealth }
        currentUserTask = nil
        let generation = sessionGeneration
        let user = try? await SoundCloudAPI.shared.getCurrentUser()
        guard generation == sessionGeneration else { return sessionHealth }
        if let user {
            mutateState(because: "loaded the current user") { $0.currentUser = user }
            noteAuthenticatedRequestSucceeded()
        }
        return sessionHealth
    }
}

@MainActor
private final class SessionRecoveryProgress {
    var tried = Set<String>()
}

@MainActor
enum SoundCloudCredentialSourcePolicy {

    static func needsSignIn(
        isEstablishingSessionAtLaunch: Bool,
        isSignedOut: Bool,
        healthNeedsSignIn: Bool,
        hasExplicitLocalSignOut: Bool
    ) -> Bool {
        if isEstablishingSessionAtLaunch {
            return isSignedOut && hasExplicitLocalSignOut
        }
        if isSignedOut { return true }
        return healthNeedsSignIn
    }

    static func holdsAuthenticatedRequests(
        isSignedOut: Bool,
        hasStoredSession: Bool,
        health: SoundCloudCredentialSource.SessionHealth
    ) -> Bool {
        guard !isSignedOut, hasStoredSession else { return false }
        return health.isRejected && !health.canMakeAuthenticatedRequests
    }

    static func launchRefreshRequiresReconnect(
        refreshOutcome: SoundCloudTokenRefresh.Outcome,
        tokenValidation: SoundCloudTokenValidation
    ) -> Bool {
        guard refreshOutcome == .unrecoverable else { return false }
        if case .rejected = tokenValidation { return true }
        return false
    }

    static func adoptionKeepsHealth(current: SoundCloudCredentialSource.SessionHealth, adoptedIsExpired: Bool) -> Bool {
        current == .healthy && !adoptedIsExpired
    }

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
        guard sessionHealth.canMakeAuthenticatedRequests else { return nil }
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
        currentUserTask = nil
        guard generation == sessionGeneration else { return nil }
        if let user { mutateState(because: "loaded the current user") { $0.currentUser = user } }
        return user
    }

    func noteAuthenticatedRequestSucceeded() {
        if let stored = DeviceSessionStore.load() {
            lastAuthenticatedSuccess = (Self.digest(of: stored), Date())
        }
        lastRejection = nil
        rejectedSessionDigest = nil
        hasSucceededSinceStoreChange = true
        resetRenewalRetry()
        mutateState(because: "an authenticated request succeeded") {
            $0.lastSignOutReason = nil
            $0.isSignedOut = false
            $0.isAuthenticated = true
            $0.sessionHealth = .healthy
        }
    }

    func refreshAccessToken() async -> Bool {
        if let sessionRecoveryTask { return await sessionRecoveryTask.value == .recovered }
        guard let stored = DeviceSessionStore.load() else { return false }
        if wasRecentlyAccepted(stored) {
            return await runRenewal(trigger: "401 right after a 200, adopting only") { await $0.adoptNewer() }.renewed
        }
        let outcome = await runRenewal(trigger: "401 on a request") { await $0.renew() }
        if outcome.renewed { return true }
        guard outcome == .exhausted else { return false }
        return await recoverSession(validateFirst: true, because: "401 and renewal found no usable session") == .recovered
    }

    func handleUnauthorized() async -> SoundCloudUnauthorizedDisposition {
        #if DEBUG
        if Self.visualFixtureUser != nil { return .endpointRejected }
        #endif
        guard let stored = DeviceSessionStore.load() else {
            mutateState(because: "401 with no stored session") {
                $0.currentUser = nil
                $0.isSignedOut = true
                $0.isAuthenticated = false
                $0.sessionHealth = computeHealth()
            }
            return .credentialRejected
        }

        if case .waiting = SoundCloudAPI.shared.trafficSafetyState() {
            Log.auth.notice("401 during a SoundCloud traffic stop, waiting")
            scheduleRenewalRetry(because: "401 during a traffic stop")
            return .temporarilyUnavailable
        }

        if DeviceSessionRefresher.shared.recentOutcome == nil, stored.canSelfRefresh {
            let outcome = wasRecentlyAccepted(stored)
                ? await runRenewal(trigger: "401 handler right after a 200, adopting only") { await $0.adoptNewer() }
                : await runRenewal(trigger: "401 handler") { await $0.renew() }
            if outcome.renewed {
                Log.auth.notice("401 recovered by renewing the session")
                return .temporarilyUnavailable
            }
        }

        let refresh = DeviceSessionRefresher.shared.recentOutcome
        let current = DeviceSessionStore.load() ?? stored
        var validation: SoundCloudTokenValidation?
        if SoundCloudUnauthorizedPolicy.needsValidation(refresh: refresh, canSelfRefresh: current.canSelfRefresh) {
            validation = await SoundCloudAPI.shared.validateToken(current.oauthToken)
        }

        let verdict = SoundCloudUnauthorizedPolicy.verdict(
            trafficStopped: false,
            refresh: refresh,
            canSelfRefresh: current.canSelfRefresh,
            validation: validation
        )
        Log.auth.notice("401 verdict \(String(describing: verdict), privacy: .public) (refresh \(String(describing: refresh), privacy: .public), /me \(String(describing: validation), privacy: .public))")

        switch verdict {
        case .keep:
            noteAuthenticatedRequestSucceeded()
            return .endpointRejected
        case .wait:
            scheduleRenewalRetry(because: "401 without a definitive answer")
            return .temporarilyUnavailable
        case .reconnect(let kind):
            let because = Self.definitiveReason(refresh: refresh, kind: kind)
            switch await recoverSession(validateFirst: false, because: because, rejecting: kind) {
            case .recovered, .unresolved:
                return .temporarilyUnavailable
            case .failed:
                return .credentialRejected
            }
        }
    }

    private static func definitiveReason(refresh: SoundCloudTokenRefresh.Outcome?, kind: RejectionKind) -> String {
        switch refresh {
        case .succeeded?: return "401 again after a successful refresh"
        case .unrecoverable?: return kind == .noRefreshCapability ? "no refresh material" : "SoundCloud refused the refresh token"
        case .transient?, nil: return "no refresh material and /me rejected the token"
        }
    }

    static let renewalRetryDelays: [Duration] = [.seconds(15), .seconds(60), .seconds(300), .seconds(900)]

    // MARK: Session recovery

    func recoverSession(
        validateFirst: Bool,
        because reason: String,
        rejecting kind: RejectionKind? = nil
    ) async -> SoundCloudSessionRecovery.Result {
        guard let task = beginSessionRecovery(validateFirst: validateFirst, because: reason, rejecting: kind) else {
            if let kind, !sessionHealth.isRejected, !isSignedOut, DeviceSessionStore.load()?.isUsable == false {
                rejectSession(kind, because: reason)
            }
            return sessionHealth.isRejected ? .failed : .unresolved
        }
        return await task.value
    }

    private func beginSessionRecovery(
        validateFirst: Bool,
        because reason: String,
        rejecting kind: RejectionKind? = nil
    ) -> Task<SoundCloudSessionRecovery.Result, Never>? {
        if let sessionRecoveryTask { return sessionRecoveryTask }
        guard !isSignedOut, let stored = DeviceSessionStore.load(), stored.isUsable else { return nil }
        let digest = Self.digest(of: stored)
        if sessionHealth.isRejected, rejectedSessionDigest == digest { return nil }
        if let last = lastUnresolvedRecovery, last.digest == digest,
           Date().timeIntervalSince(last.at) < Self.recoveryCooldown { return nil }

        sessionRecoveryGeneration &+= 1
        let generation = sessionRecoveryGeneration
        let task = Task { @MainActor [weak self] () -> SoundCloudSessionRecovery.Result in
            guard let self else { return .unresolved }
            return await self.performSessionRecovery(
                from: digest, generation: generation, validateFirst: validateFirst, because: reason, rejecting: kind
            )
        }
        sessionRecoveryTask = task
        isRecoveringSession = true
        Log.auth.notice("session recovery started: \(reason, privacy: .public)")
        return task
    }

    private func performSessionRecovery(
        from digest: String,
        generation: UInt64,
        validateFirst: Bool,
        because reason: String,
        rejecting kind: RejectionKind?
    ) async -> SoundCloudSessionRecovery.Result {
        let sources = recoverySources
        let progress = SessionRecoveryProgress()
        let result = await SoundCloudSessionRecovery.run(
            validateFirst: validateFirst,
            polls: sources.contains { $0.kind != .silentWeb },
            environment: SoundCloudSessionRecovery.Environment(
                validateCurrent: { [weak self] in
                    guard let token = DeviceSessionStore.load()?.oauthToken else { return nil }
                    let validation = await SoundCloudAPI.shared.validateToken(token)
                    if validation == .valid { self?.noteAuthenticatedRequestSucceeded() }
                    return validation
                },
                isResolved: { [weak self] in self?.sessionWasReplaced(since: digest) ?? true },
                attempt: { [weak self] _ in
                    guard let self, !Task.isCancelled else { return .temporarilyUnavailable }
                    let renewal = SoundCloudSessionRenewal(environment: self.renewalEnvironment, sources: sources)
                    let round = await renewal.recover(kinds: [.synced, .linkedPeer], skipping: progress.tried)
                    progress.tried = round.tried
                    if round.outcome.renewed { self.didAdoptRecoveredSession() }
                    return round.outcome
                },
                sleep: { duration in try? await Task.sleep(for: duration) },
                now: { ContinuousClock.now }
            )
        )

        guard generation == sessionRecoveryGeneration else { return result }
        Log.auth.notice("session recovery finished: \(String(describing: result), privacy: .public)")
        switch result {
        case .recovered:
            lastUnresolvedRecovery = nil
        case .unresolved:
            lastUnresolvedRecovery = (digest, Date())
        case .failed:
            lastUnresolvedRecovery = (digest, Date())
            let rejection = kind ?? Self.rejectionKind(for: DeviceSessionStore.load(), refreshWasLocalGuard: false)
            rejectSession(rejection, because: "no device or sync store had a usable session: \(reason)")
        }
        sessionRecoveryTask = nil
        isRecoveringSession = false
        if result == .unresolved { scheduleRenewalRetry(because: "session recovery could not finish") }
        if result == .recovered, currentUser == nil { Task { _ = await self.waitForCurrentUser() } }
        return result
    }

    private func sessionWasReplaced(since digest: String) -> Bool {
        guard let stored = DeviceSessionStore.load(), stored.isUsable else { return false }
        return Self.digest(of: stored) != digest && !RejectedLineageLedger.defaults.rejects(stored)
    }

    private func didAdoptRecoveredSession() {
        lastRenewalVerdict = nil
        DeviceSessionRefresher.shared.reset()
        currentUserTask = nil
        _ = currentSessionForSync()
        requestSessionSync()
        noteAuthenticatedRequestSucceeded()
    }

    private func rejectSession(_ kind: RejectionKind, because reason: String) {
        sessionGeneration &+= 1
        currentUserTask = nil
        mutateState(because: reason) {
            $0.lastSignOutReason = kind == .noRefreshCapability ? .noRefreshCapability : .accountRejected
            $0.isSignedOut = false
            $0.isAuthenticated = false
        }
        markRejected(kind, because: reason)
    }

    private func cancelSessionRecovery() {
        sessionRecoveryGeneration &+= 1
        sessionRecoveryTask?.cancel()
        sessionRecoveryTask = nil
        lastUnresolvedRecovery = nil
        isRecoveringSession = false
        isRenewingAtLaunch = false
    }

    private func resetRenewalRetry() {
        renewalRetryTask?.cancel()
        renewalRetryTask = nil
        renewalRetryAttempt = 0
    }

    private func scheduleRenewalRetry(because reason: String) {
        #if DEBUG
        if Self.visualFixtureUser != nil { return }
        #endif
        guard renewalRetryTask == nil,
              let delay = SoundCloudUnauthorizedPolicy.retryDelay(attempt: renewalRetryAttempt, delays: Self.renewalRetryDelays),
              DeviceSessionStore.load() != nil else { return }
        renewalRetryAttempt += 1
        let attempt = renewalRetryAttempt
        Log.auth.notice("renewal retry \(attempt, privacy: .public) in \(String(describing: delay), privacy: .public): \(reason, privacy: .public)")
        renewalRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.renewalRetryTask = nil
            self.lastRenewalVerdict = nil
            let outcome = await self.runRenewal(trigger: "scheduled retry \(attempt)") { await $0.renew() }
            Log.auth.notice("renewal retry \(attempt, privacy: .public) finished: \(String(describing: outcome), privacy: .public)")
            guard outcome.renewed else { return }
            _ = await self.revalidate()
        }
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
        let observedAtMillis = SessionSyncBookkeeping.recordIfChanged(digest: digest)
        let issuedAtMillis = session.issuedAt.map(SessionIssuance.millis(_:))
        return SyncedSoundCloudSession(
            oauthToken: session.oauthToken,
            refreshToken: session.refreshToken,
            clientId: session.clientId,
            expiresAtMillis: expiresAtMillis,
            updatedAtMillis: issuedAtMillis ?? observedAtMillis,
            writerId: SessionSyncBookkeeping.writerId(),
            issuedAtMillis: issuedAtMillis,
            generation: session.generation.map(Int64.init)
        ).describingAccount(
            tag: accountUser.map { PeerAccount.tag(userId: $0.id) },
            name: accountUser?.displayName,
            writerName: LinkPeerIdentity.localName,
            writerKind: DeviceClass.current.rawValue
        )
    }

    func adoptSyncedSession(_ session: SyncedSoundCloudSession) async {
        if let lineage = session.lineage, RejectedLineageLedger.defaults.contains(lineage) {
            Log.auth.notice("ignored a synced session whose refresh token SoundCloud already refused")
            return
        }
        let local = DeviceSessionStore.load()
        if let local, local.oauthToken == session.oauthToken,
           local.refreshToken == session.refreshToken, local.clientId == session.clientId {
            Log.auth.debug("a synced session matched the one on this device, nothing to adopt")
            return
        }
        if let local, local.canSelfRefresh,
           !RejectedLineageLedger.defaults.rejects(local),
           local.isNewer(than: session.storedSession) {
            Log.auth.notice("ignored a synced session older than the one on this device")
            return
        }
        SessionProvenance.record(.iCloud)
        SessionContinueOffer.save(nil)
        DeviceSessionStore.save(session.storedSession)
        let digest = SessionSyncBookkeeping.digest(
            oauthToken: session.oauthToken, refreshToken: session.refreshToken,
            clientId: session.clientId, expiresAtMillis: session.expiresAtMillis
        )
        SessionSyncBookkeeping.adoptForeignProvenance(updatedAtMillis: session.updatedAtMillis, digest: digest)

        let keepsHealth = SoundCloudCredentialSourcePolicy.adoptionKeepsHealth(
            current: sessionHealth,
            adoptedIsExpired: session.storedSession.isExpired
        )
        DeviceSessionRefresher.shared.reset()
        sessionGeneration &+= 1
        currentUserTask = nil
        lastRenewalVerdict = nil
        lastRejection = nil
        rejectedSessionDigest = nil
        hasSucceededSinceStoreChange = keepsHealth

        let health = computeHealth()
        mutateState(because: "adopted a synced session") {
            $0.isSignedOut = false
            $0.isAuthenticated = keepsHealth
            $0.lastSignOutReason = nil
            $0.sessionHealth = health
        }

        let generation = sessionGeneration
        guard let user = try? await SoundCloudAPI.shared.getCurrentUser(), generation == sessionGeneration else { return }
        mutateState(because: "loaded the current user") { $0.currentUser = user }
        noteAuthenticatedRequestSucceeded()
    }
}

enum SoundCloudAccountStatus: Equatable, Sendable {
    case signedOut
    case signedIn
    case needsReconnect

    static func resolve(
        isEstablishingSessionAtLaunch: Bool,
        isSignedOut: Bool,
        health: SoundCloudSessionHealth
    ) -> SoundCloudAccountStatus {
        if isSignedOut || health == .signedOut { return .signedOut }
        if !isEstablishingSessionAtLaunch, health.needsSignIn { return .needsReconnect }
        return .signedIn
    }
}

enum SoundCloudUnauthorizedPolicy {
    enum Verdict: Equatable, Sendable {
        case keep
        case wait
        case reconnect(SoundCloudSessionRejection)
    }

    static func needsValidation(refresh: SoundCloudTokenRefresh.Outcome?, canSelfRefresh: Bool) -> Bool {
        switch refresh {
        case .transient?: return false
        case .succeeded?, .unrecoverable?: return true
        case nil: return !canSelfRefresh
        }
    }

    static func verdict(
        trafficStopped: Bool,
        refresh: SoundCloudTokenRefresh.Outcome?,
        canSelfRefresh: Bool,
        validation: SoundCloudTokenValidation?
    ) -> Verdict {
        if trafficStopped { return .wait }
        switch refresh {
        case .transient?:
            return .wait
        case nil where canSelfRefresh:
            return .wait
        case nil, .succeeded?, .unrecoverable?:
            switch validation {
            case .valid?: return .keep
            case .unavailable?, nil: return .wait
            case .rejected?: return .reconnect(canSelfRefresh ? .accountRejected : .noRefreshCapability)
            }
        }
    }

    static func retryDelay(attempt: Int, delays: [Duration]) -> Duration? {
        guard attempt >= 0, attempt < delays.count else { return nil }
        return delays[attempt]
    }
}

enum SignOutScope: Equatable {
    case thisDevice
    case everywhere
}

enum SessionRevocation: Equatable {
    case none
    case signOut
    case signOutAndDisconnect

    static func decide(scope: SignOutScope, tokenIsShared: Bool) -> Self {
        switch scope {
        case .everywhere: return .signOutAndDisconnect
        case .thisDevice: return tokenIsShared ? .none : .signOut
        }
    }

    var paths: [String] {
        switch self {
        case .none: return []
        case .signOut: return ["sign-out"]
        case .signOutAndDisconnect: return ["sign-out"]
        }
    }
}

enum SoundCloudSessionRevoker {
    static let timeout: TimeInterval = 5

    static func request(path: String, token: String) -> URLRequest? {
        guard let url = URL(string: "https://api.soundcloud.com/\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        return request
    }

    static func revoke(_ revocation: SessionRevocation, token: String) async {
        for path in revocation.paths {
            guard let request = request(path: path, token: token) else { continue }
            await NetworkActivityLog.$feature.withValue(.signOut) {
                await NetworkActivityLog.$detail.withValue("Sign out") {
                    await send(request)
                }
            }
        }
    }

    private static func send(_ request: URLRequest) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                if let transport = SoundCloudTokenRefresh.requestTransport {
                    _ = try? await transport(request)
                } else {
                    _ = try? await URLSession.shared.data(for: request)
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
            await group.next()
            group.cancelAll()
        }
    }
}
