import Foundation
import Combine
import os

/// watchOS credential-source wrapper.
///
/// Delegates token management to the shared `SoundCloudCredentialSource` and adds
/// watch-specific behavior: authorizing a paired Apple TV and falling back to
/// adopting a session from the paired iPhone when the local session cannot refresh.
@MainActor
final class WatchCredentialSource: ObservableObject {
    static let shared = WatchCredentialSource()

    @Published private(set) var currentUser: User?
    @Published private(set) var isSignedIn = false
    @Published private(set) var isAdopting = false
    @Published private(set) var pendingTVOffer: LinkOffer?
    @Published private(set) var tvAuthorizationResult: String?

    private var didLoadUser = false
    private let source = SoundCloudCredentialSource.shared
    private let tvAuthorizer = CompanionLinker()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        source.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
            .store(in: &cancellables)

        tvAuthorizer.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
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
        refreshTVAuthorizationOffer()
        sync()
    }

    var isAuthorizingTV: Bool { tvAuthorizer.state.isWorking }

    func refreshTVAuthorizationOffer() {
        guard DeviceSessionStore.load()?.isUsable == true else {
            pendingTVOffer = nil
            return
        }
        pendingTVOffer = LinkOfferStore.fetchLatest()
    }

    @discardableResult
    func authorizeWaitingTV() async -> Bool {
        guard !isAuthorizingTV,
              let offer = pendingTVOffer,
              var session = DeviceSessionStore.load(),
              session.isUsable else { return false }

        if session.shouldRefreshBeforeHandoff,
           let refreshed = await DeviceSessionRefresher.shared.refresh(session) {
            session = refreshed
        }

        await tvAuthorizer.authorize(offer: offer, session: session)
        switch tvAuthorizer.state {
        case .completed(let name):
            pendingTVOffer = nil
            tvAuthorizationResult = "\(name) is signed in and ready."
            return true
        case .failed(let message):
            tvAuthorizationResult = message
            refreshTVAuthorizationOffer()
            return false
        default:
            return false
        }
    }

    func dismissTVAuthorizationResult() {
        tvAuthorizationResult = nil
        tvAuthorizer.reset()
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
            await source.signOut()
            didLoadUser = false
            pendingTVOffer = nil
            tvAuthorizationResult = nil
            tvAuthorizer.reset()
            sync()
        }
    }
}

extension WatchCredentialSource: SoundCloudCredentialSourcing {
    var accessToken: String? {
        source.accessToken
    }

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
        if await source.refreshAccessToken() {
            refreshFromStore()
            return true
        }
        return await adoptFromPhone()
    }

    func handleUnauthorized() async {
        if await refreshAccessToken() { return }
        await source.signOut()
        didLoadUser = false
        pendingTVOffer = nil
        tvAuthorizationResult = nil
        tvAuthorizer.reset()
        sync()
    }

    func noteAuthenticatedRequestSucceeded() {
        source.noteAuthenticatedRequestSucceeded()
        sync()
    }
}
