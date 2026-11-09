import Foundation
import Combine
import os

@MainActor
final class AuthenticationService: ObservableObject {
    static let shared = AuthenticationService()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: User?
    @Published private(set) var sessionHealth: SoundCloudSessionHealth = .signedOut

    var needsSignIn: Bool { source.needsSignIn }

    private let source = SoundCloudCredentialSource.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        #if DEBUG
        if !VisualFixtures.isEnabled { source.resolveLaunchStateFromLocalStore() }
        #else
        source.resolveLaunchStateFromLocalStore()
        #endif
        source.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
            .store(in: &cancellables)
        sync()

        source.sideEffects.requestSessionSync = { [weak self] in
            guard self != nil else { return }
            SynchronizationCoordinator.shared.requestSessionSync()
        }
        source.sideEffects.wipeLocalIndexes = { [weak self] accountID in
            guard self != nil else { return }
            LikesSyncEngine.shared.handleSignOut()
            await LibraryCache.shared.clearAll()
            await DownloadManager.shared.purgeCachedDownloads(accountID: accountID)
            if let accountID { AccountDataVault.forget(accountID: accountID) }
        }
        source.recoverySources = [
            .synced(localSession: { SoundCloudCredentialSource.shared.currentSessionForSync() }),
            Self.linkedCompanionSource,
        ]
    }

    private static var linkedCompanionSource: SoundCloudSessionRenewal.Source {
        SoundCloudSessionRenewal.Source(kind: .linkedPeer) { phase in
            guard phase == .afterFailure,
                  let offer = await CompanionServer.shared.requestAuthHandoffSession() else { return nil }
            let provisional = StoredSession(
                oauthToken: offer.oauthToken,
                refreshToken: offer.refreshToken,
                clientId: offer.clientId,
                expiresAt: offer.expiresAtMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            )
            guard provisional.canSelfRefresh else {
                Log.auth.error("[AuthenticationService] companion offer missing refresh material")
                return nil
            }
            return SoundCloudSessionRenewal.Candidate(session: provisional) {
                SessionSyncBookkeeping.clearLocalSignOut()
            }
        }
    }

    private func sync() {
        isAuthenticated = source.isAuthenticated
        currentUser = source.accountUser
        sessionHealth = source.sessionHealth
    }

    func authenticate(
        token: String,
        refreshToken: String?,
        clientId: String?,
        expiry: Date?,
        presentationDelay: Duration = .zero
    ) async {
        let clock = ContinuousClock()
        let earliestCompletion = clock.now.advanced(by: presentationDelay)

        DeviceSessionStore.save(StoredSession(
            oauthToken: token,
            refreshToken: refreshToken,
            clientId: clientId,
            expiresAt: expiry
        ))
        SessionSyncBookkeeping.clearLocalSignOut()

        source.didCompleteSignIn()
        _ = await source.waitForCurrentUser()

        if clock.now < earliestCompletion {
            try? await Task.sleep(for: clock.now.duration(to: earliestCompletion))
        }
        sync()
    }

    func logout() async {
        PlayerService.shared.clearQueue()
        CompanionServer.shared.unpair()
        TopShelfPublisher.clear()

        await source.signOutThisDevice(tokenIsShared: true)
        sync()
    }

    func signOutKeepingLinks() async {
        PlayerService.shared.clearQueue()
        TopShelfPublisher.clear()
        SessionSyncBookkeeping.recordLocalSignOut()
        await source.signOutThisDevice(tokenIsShared: true)
        sync()
    }

    func waitForCurrentUser() async -> User? {
        await source.waitForCurrentUser()
    }

    func handleUnauthorized() async -> SoundCloudUnauthorizedDisposition {
        let disposition = await source.handleUnauthorized()
        sync()

        if source.isSignedOut {
            PlayerService.shared.clearQueue(forgetSavedSession: false)
            TopShelfPublisher.clear()
        }
        return disposition
    }

}

extension AuthenticationService: SoundCloudCredentialSourcing {
    var accessToken: String? { source.accessToken }

    var holdsAuthenticatedRequests: Bool { source.holdsAuthenticatedRequests }

    func waitForRenewal() async { await source.waitForRenewal() }

    func refreshAccessToken() async -> Bool {
        let renewed = await source.refreshAccessToken()
        sync()
        return renewed
    }

    func noteAuthenticatedRequestSucceeded() {
        source.noteAuthenticatedRequestSucceeded()
        sync()
    }
}

extension AuthenticationService: SoundCloudSessionSyncSource {
    func currentSessionForSync() -> SyncedSoundCloudSession? {
        source.currentSessionForSync()
    }

    func adoptSyncedSession(_ session: SyncedSoundCloudSession) async {
        await source.adoptSyncedSession(session)
        sync()
    }
}
