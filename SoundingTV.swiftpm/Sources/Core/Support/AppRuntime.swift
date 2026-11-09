import Foundation
import Combine
import Network

enum PlaybackCommand {
    case play(track: Track, context: [Track], collectionID: String?)
    case resume
    case pause
    case toggle
    case next
    case previous
    case seek(TimeInterval)
}

@MainActor
final class PlaybackSystem {
    let player: PlayerService
    let indicator: PlaybackIndicatorStore
    let queue: PlaybackQueueStore
    let sources: PlaybackSourceResolver

    init(
        player: PlayerService = .shared,
        indicator: PlaybackIndicatorStore = .shared,
        queue: PlaybackQueueStore = .shared,
        sources: PlaybackSourceResolver? = nil
    ) {
        self.player = player
        self.indicator = indicator
        self.queue = queue
        self.sources = sources ?? player.sourceResolver
    }

    func send(_ command: PlaybackCommand) async {
        switch command {
        case .play(let track, let context, let collectionID):
            await player.play(track, in: context, collectionId: collectionID)
        case .resume: player.play()
        case .pause: player.pause()
        case .toggle: player.togglePlayPause()
        case .next: await player.playNext()
        case .previous: await player.playPrevious()
        case .seek(let time): player.seek(to: time)
        }
    }
}

enum SynchronizationCommand {
    case refresh
    case mutation(SynchronizationDomain)
    case session
}

@MainActor
final class SynchronizationSystem {
    let coordinator: SynchronizationCoordinator
    let gateway: SynchronizationGateway

    init(
        coordinator: SynchronizationCoordinator = .shared,
        gateway: SynchronizationGateway = .shared
    ) {
        self.coordinator = coordinator
        self.gateway = gateway
    }

    var metrics: SynchronizationGateway.Metrics { gateway.metrics }

    func send(_ command: SynchronizationCommand) {
        switch command {
        case .refresh: coordinator.requestRefresh()
        case .mutation(let domain): coordinator.noteLocalChange(domain)
        case .session: coordinator.requestSessionSync()
        }
    }
}

@MainActor
final class DownloadSystem {
    let manager: DownloadManager
    let remoteManifest: RemoteDownloadManifestStore

    init(
        manager: DownloadManager = .shared,
        remoteManifest: RemoteDownloadManifestStore = .shared
    ) {
        self.manager = manager
        self.remoteManifest = remoteManifest
    }
}

@MainActor
final class CatalogSystem {
    let api: SoundCloudAPI
    let gateway: SoundCloudGateway
    let library: LibraryCache
    let likes: LikesSyncEngine
    let artwork: SCArtworkStore

    init(
        api: SoundCloudAPI = .shared,
        gateway: SoundCloudGateway = .shared,
        library: LibraryCache = .shared,
        likes: LikesSyncEngine = .shared,
        artwork: SCArtworkStore = .shared
    ) {
        self.api = api
        self.gateway = gateway
        self.library = library
        self.likes = likes
        self.artwork = artwork
    }
}

@MainActor
final class AnalysisSystem {
    let cache: AnalysisCache
    let status: AutomaticAnalysisStatus

    init(cache: AnalysisCache = .shared, status: AutomaticAnalysisStatus = .shared) {
        self.cache = cache
        self.status = status
    }
}

@MainActor
final class AccountSystem {
    let credentials: any SoundCloudCredentialSourcing
    let sessionSource: (any SoundCloudSessionSyncSource)?

    init(
        credentials: any SoundCloudCredentialSourcing,
        sessionSource: (any SoundCloudSessionSyncSource)?
    ) {
        self.credentials = credentials
        self.sessionSource = sessionSource
    }
}

@MainActor
protocol RuntimeIntegration: AnyObject {
    var id: String { get }
    func start() async
    func setActive(_ active: Bool)
}

@MainActor
final class RuntimeIntegrationAdapter: RuntimeIntegration {
    let id: String
    private let startAction: @MainActor () async -> Void
    private let activityAction: @MainActor (Bool) -> Void
    private var started = false

    init(
        id: String,
        start: @escaping @MainActor () async -> Void = {},
        setActive: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.id = id
        startAction = start
        activityAction = setActive
    }

    func start() async {
        guard !started else { return }
        started = true
        await startAction()
    }

    func setActive(_ active: Bool) {
        activityAction(active)
    }
}

@MainActor
final class IntegrationSystem {
    private let integrations: [any RuntimeIntegration]

    init(_ integrations: [any RuntimeIntegration]) {
        var seen = Set<String>()
        self.integrations = integrations.filter { seen.insert($0.id).inserted }
    }

    func start() async {
        for integration in integrations { await integration.start() }
    }

    func setActive(_ active: Bool) {
        for integration in integrations { integration.setActive(active) }
    }
}

@MainActor
final class RuntimeNetworkIntegration: RuntimeIntegration {
    let id = "runtime.network"
    private let scheduler: WorkScheduler
    private nonisolated(unsafe) var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "red.forbes.sounding.runtime.network")

    init(scheduler: WorkScheduler) {
        self.scheduler = scheduler
    }

    func start() async {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                var environment = self.scheduler.snapshot().environment
                environment.hasNetwork = path.status == .satisfied
                environment.isExpensiveNetwork = path.isExpensive
                environment.isConstrainedNetwork = path.isConstrained
                self.scheduler.updateEnvironment(environment)
            }
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    func setActive(_ active: Bool) {}

    deinit {
        monitor?.cancel()
    }
}

struct RuntimePlatformServices {
    let deviceLabel: String
    let account: AccountSystem
    let lifecycleObserver: (any PlatformLifecycleObserver)?
    let nowPlaying: (any SystemNowPlayingBridge)?
    let peerContentSource: (any PeerContentSessionProvider)?
    let prepare: @MainActor () async -> Void
    let integrations: [any RuntimeIntegration]

    init(
        deviceLabel: String,
        account: AccountSystem,
        lifecycleObserver: (any PlatformLifecycleObserver)? = nil,
        nowPlaying: (any SystemNowPlayingBridge)? = nil,
        peerContentSource: (any PeerContentSessionProvider)? = nil,
        prepare: @escaping @MainActor () async -> Void = {},
        integrations: [any RuntimeIntegration] = []
    ) {
        self.deviceLabel = deviceLabel
        self.account = account
        self.lifecycleObserver = lifecycleObserver
        self.nowPlaying = nowPlaying
        self.peerContentSource = peerContentSource
        self.prepare = prepare
        self.integrations = integrations
    }
}

@MainActor
final class AppRuntime: ObservableObject {
    let playback: PlaybackSystem
    let synchronization: SynchronizationSystem
    let downloads: DownloadSystem
    let catalog: CatalogSystem
    let analysis: AnalysisSystem
    let account: AccountSystem
    let integrations: IntegrationSystem
    let scheduler: WorkScheduler

    private let platform: RuntimePlatformServices
    private var started = false

    init(
        platform: RuntimePlatformServices,
        playback: PlaybackSystem = PlaybackSystem(),
        synchronization: SynchronizationSystem = SynchronizationSystem(),
        downloads: DownloadSystem = DownloadSystem(),
        catalog: CatalogSystem = CatalogSystem(),
        analysis: AnalysisSystem = AnalysisSystem(),
        scheduler: WorkScheduler = .shared
    ) {
        _ = CompanionRegistry.shared
        self.platform = platform
        self.playback = playback
        self.synchronization = synchronization
        self.downloads = downloads
        self.catalog = catalog
        self.analysis = analysis
        self.account = platform.account
        self.scheduler = scheduler
        integrations = IntegrationSystem(
            [RuntimeNetworkIntegration(scheduler: scheduler)] + platform.integrations
        )

        SoundCloudGateway.installAsTokenRefreshTransport()
        SoundCloudAPI.credentials = platform.account.credentials
        synchronization.coordinator.configureSessionSource(platform.account.sessionSource)
        playback.player.configurePlatform(
            nowPlaying: platform.nowPlaying,
            lifecycleObserver: platform.lifecycleObserver
        )
        playback.player.connectNearbyPlayback(peerContentSource: platform.peerContentSource)
    }

    func start() async {
        guard !started else { return }
        started = true
        await platform.prepare()
        catalog.likes.activate()
        synchronization.coordinator.start()
        await synchronization.coordinator.runOnce(
            analysisStore: analysis.cache,
            downloadManifestExportSource: LocalDownloadManifestSource(
                deviceId: DownloadManifestDeviceIdentity.deviceId(),
                deviceLabel: platform.deviceLabel,
                manager: downloads.manager
            )
        )
        await integrations.start()
    }

    func setActive(_ isActive: Bool) {
        var environment = scheduler.snapshot().environment
        environment.isForeground = isActive
        scheduler.updateEnvironment(environment)
        catalog.gateway.setApplicationActivity(isActive ? .foreground : .background)
        integrations.setActive(isActive)
        guard isActive else { return }
        catalog.likes.handleDidBecomeActive()
        synchronization.send(.refresh)
    }
}
