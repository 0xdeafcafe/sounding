import Foundation
import WebKit

@MainActor
enum CompanionAppBootstrap {
    static func configureSoundCloudSession(
        synchronization: SynchronizationSystem,
        downloads: DownloadSystem,
        catalog: CatalogSystem,
        clearSurfaces: @escaping @MainActor () -> Void = {},
        clearWebSession: @escaping () async -> Void,
        webStore: @escaping @MainActor () -> WKWebsiteDataStore
    ) {
        let credentials = SoundCloudCredentialSource.shared
        credentials.sideEffects = .init(
            requestSessionSync: { synchronization.send(.session) },
            wipeLocalIndexes: { accountID in
                clearSurfaces()
                catalog.likes.handleSignOut()
                await catalog.library.clearAll()
                await downloads.manager.purgeCachedDownloads(accountID: accountID)
                if let accountID { AccountDataVault.forget(accountID: accountID) }
            },
            clearWebSession: clearWebSession
        )
        credentials.recoverySources = [
            .synced(
                coordinator: synchronization.coordinator,
                localSession: { SoundCloudCredentialSource.shared.currentSessionForSync() }
            ),
            .silentWeb(store: webStore),
        ]
    }

    static func companionClient(synchronization: SynchronizationSystem, downloads: DownloadSystem, catalog: CatalogSystem) -> CompanionClient {
        CompanionClient(
            synchronization: synchronization.coordinator,
            gateway: synchronization.gateway,
            likes: catalog.likes,
            library: catalog.library,
            downloads: downloads.manager
        )
    }

    static var account: AccountSystem {
        AccountSystem(
            credentials: SoundCloudCredentialSource.shared,
            sessionSource: SoundCloudCredentialSource.shared
        )
    }

    static func prepareSession() async {
        await SoundCloudCredentialSource.shared.establishSessionAtLaunch()
        await SoundCloudCredentialSource.shared.purgeExpiredLockedDataIfNeeded()
    }
}
