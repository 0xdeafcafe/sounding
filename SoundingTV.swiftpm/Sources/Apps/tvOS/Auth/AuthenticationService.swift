import Foundation
import Combine
import os

/// tvOS-facing wrapper around the shared SoundCloud credential source.
///
/// This type keeps tvOS-specific behavior (clearing the player/queue on sign-out,
/// presentation delays during QR login) while delegating all credential management
/// to `SoundCloudCredentialSource`.
@MainActor
final class AuthenticationService: ObservableObject {
    static let shared = AuthenticationService()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: User?
    @Published private(set) var sessionHealth: SoundCloudSessionHealth = .signedOut

    /// An unverified credential is still a usable credential candidate. Keep
    /// the app shell visible while its first request validates it; only a real
    /// sign-out or unrecoverable rejection should replace the app with login.
    var needsSignIn: Bool { sessionHealth.needsSignIn }

    private let source = SoundCloudCredentialSource.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        source.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
            .store(in: &cancellables)
        sync()

        source.sideEffects.requestSessionSync = { [weak self] in
            guard self != nil else { return }
            CloudSyncCoordinator.shared.requestSessionSync()
        }
        source.sideEffects.wipeLocalIndexes = { [weak self] accountID in
            guard self != nil else { return }
            LikesSyncEngine.shared.handleSignOut()
            await LibraryCache.shared.clearAll()
            if let accountID { AccountDataVault.forget(accountID: accountID) }
        }
    }

    private func sync() {
        isAuthenticated = source.isAuthenticated
        currentUser = source.currentUser
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

        // Wait out the presentation delay so the sign-in UI doesn't flash.
        if clock.now < earliestCompletion {
            try? await Task.sleep(for: clock.now.duration(to: earliestCompletion))
        }
        sync()
    }

    func logout() async {
        // Authentication is a hard privacy boundary on a shared television.
        // Never leave audio playing, media controls active, or track metadata
        // visible behind the sign-in screen.
        PlayerService.shared.clearQueue()
        CompanionServer.shared.unpair()
        TopShelfPublisher.clear()

        await source.signOut()
        sync()
    }

    func waitForCurrentUser() async -> User? {
        await source.waitForCurrentUser()
    }

    func handleUnauthorized() async {
        await source.handleUnauthorized()
        sync()

        guard source.isSignedOut else { return }
        PlayerService.shared.clearQueue()
        CompanionServer.shared.unpair()
        TopShelfPublisher.clear()
    }

    #if DEBUG
    func _installDemoUser(_ user: User) {
        isAuthenticated = true
        currentUser = user
    }
    #endif
}

extension AuthenticationService: SoundCloudCredentialSourcing {
    var accessToken: String? { source.accessToken }

    func refreshAccessToken() async -> Bool {
        if await source.refreshAccessToken() {
            sync()
            return true
        }

        // Local refresh failed (expired/rotated refresh token). Ask the paired
        // companion to broker a brand-new device-specific session over the
        // existing remote-control link. The companion signs in again and hands us
        // a fresh token pair that belongs to this device, not to the companion.
        if let offer = await CompanionServer.shared.requestAuthHandoffSession() {
            let provisional = StoredSession(
                oauthToken: offer.oauthToken,
                refreshToken: offer.refreshToken,
                clientId: offer.clientId,
                expiresAt: offer.expiresAtMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            )
            guard provisional.canSelfRefresh else {
                Log.auth.error("[AuthenticationService] companion offer missing refresh material")
                sync()
                return false
            }
            let refreshed = await DeviceSessionRefresher.shared.refresh(provisional)
            let session = refreshed ?? provisional
            DeviceSessionStore.save(session)
            SessionSyncBookkeeping.clearLocalSignOut()
            source.didCompleteSignIn()
            sync()
            return true
        }

        sync()
        return false
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
