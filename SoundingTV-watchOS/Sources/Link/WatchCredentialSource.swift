import Foundation
import Combine
import os

@MainActor
final class WatchCredentialSource: ObservableObject {
    static let shared = WatchCredentialSource()

    @Published private(set) var currentUser: User?
    @Published private(set) var isSignedIn = false
    @Published private(set) var isAdopting = false

    private var didLoadUser = false
    private let source = SoundCloudCredentialSource.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        source.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
            .store(in: &cancellables)

        source.recoverySources = [Self.pairedPhoneSource]
        source.sideEffects.propagateRotation = { previous, renewed in
            WatchLinkClient.shared.pushRotatedSession(previous: previous, renewed: renewed)
        }
    }

    private static var pairedPhoneSource: SoundCloudSessionRenewal.Source {
        SoundCloudSessionRenewal.Source(kind: .linkedPeer) { phase in
            if phase == .beforeRefresh, !WatchLinkClient.shared.isReachable { return nil }
            guard let offer = await WatchLinkClient.shared.requestSession() else { return nil }
            return SoundCloudSessionRenewal.Candidate(session: StoredSession(
                oauthToken: offer.oauthToken,
                refreshToken: offer.refreshToken,
                clientId: offer.clientId,
                expiresAt: offer.expiresAt
            ))
        }
    }

    static func install() {
        SoundCloudAPI.credentials = shared
        #if DEBUG
        shared.source.seedDevCredentialIfAvailable()
        #endif
        shared.refreshFromStore()
    }

    private func sync() {
        currentUser = source.currentUser
        isSignedIn = source.accessToken != nil
    }

    func refreshFromStore() {
        isSignedIn = DeviceSessionStore.load()?.isUsable == true
        sync()
    }

    func adoptFromPhoneIfNeeded() async {
        guard DeviceSessionStore.load()?.isUsable != true else {
            refreshFromStore()
            return
        }
        await adoptFromPhone()
    }

    @discardableResult
    func adoptFromPhone() async -> Bool {
        guard !isAdopting else { return false }
        isAdopting = true
        defer { isAdopting = false }

        guard let offer = await WatchLinkClient.shared.requestSession() else { return false }
        DeviceSessionStore.save(StoredSession(
            oauthToken: offer.oauthToken,
            refreshToken: offer.refreshToken,
            clientId: offer.clientId,
            expiresAt: offer.expiresAt
        ))
        DeviceSessionRefresher.shared.reset()
        didLoadUser = false
        refreshFromStore()
        Log.link.info("[WatchLink] adopted the paired iPhone's SoundCloud session")
        return true
    }

    func signOut() {
        Task {
            await source.signOutThisDevice(tokenIsShared: true)
            didLoadUser = false
            sync()
        }
    }
}

extension WatchCredentialSource: SoundCloudCredentialSourcing {
    var accessToken: String? {
        source.accessToken
    }

    var holdsAuthenticatedRequests: Bool { source.holdsAuthenticatedRequests }

    func waitForRenewal() async { await source.waitForRenewal() }

    func waitForCurrentUser() async -> User? {
        if let currentUser { return currentUser }
        guard !didLoadUser, accessToken != nil else { return currentUser }
        didLoadUser = true
        do {
            let user = try await SoundCloudAPI.shared.getCurrentUser()
            currentUser = user
            return user
        } catch {
            didLoadUser = false
            return nil
        }
    }

    func refreshAccessToken() async -> Bool {
        guard DeviceSessionStore.load() != nil else { return await adoptFromPhone() }
        let renewed = await source.refreshAccessToken()
        refreshFromStore()
        return renewed
    }

    func handleUnauthorized() async -> SoundCloudUnauthorizedDisposition {
        let disposition = await source.handleUnauthorized()
        if disposition == .credentialRejected {
            didLoadUser = false
        }
        sync()
        return disposition
    }

    func noteAuthenticatedRequestSucceeded() {
        source.noteAuthenticatedRequestSucceeded()
        sync()
    }
}
