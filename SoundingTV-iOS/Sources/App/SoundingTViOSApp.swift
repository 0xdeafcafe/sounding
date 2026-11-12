import Intents
import os
import SwiftUI
import UIKit

@MainActor
private final class AppObjectGraph {
    let queueClient: CompanionClient
    let coordinator: PhonePlaybackCoordinator

    init(queueClient: CompanionClient, coordinator: PhonePlaybackCoordinator) {
        self.queueClient = queueClient
        self.coordinator = coordinator
    }
}

@main
struct SoundingTViOSApp: App {
    @UIApplicationDelegateAdaptor(SoundingTViOSAppDelegate.self) private var appDelegate
    @StateObject private var runtime: AppRuntime
    @StateObject private var pairing = DevicePairingFlow()
    @ObservedObject private var signInNotifications = TVSignInNotifications.shared
    @ObservedObject private var outsideAlerts = OutsideAlertRoutes.shared
    @State private var authHandoffRequest: AuthHandoffRequest?
    @State private var authErrorMessage: String?

    @State private var graph: AppObjectGraph

    private let playerService: PlayerService
    private let downloadManager: DownloadManager

    private var queueClient: CompanionClient { graph.queueClient }
    private var coordinator: PhonePlaybackCoordinator { graph.coordinator }

    @Environment(\.scenePhase) private var scenePhase

    init() {
        MemoryRelief.install()
        PadSidebarCustomization.dropRetiredItems()
        SoundingTips.configure()
        #if DEBUG
        FrameProbe.startIfRequested()
        if VisualFixtures.isEnabled {
            SoundCloudCredentialSource.visualFixtureUser = VisualFixtures.currentUser
            _ = (VisualFixtures.tracks, VisualFixtures.playlists, VisualFixtures.albums)
            PlaylistWriter.fixtureSeed = VisualFixtures.playlists.map {
                (id: Int($0.id) ?? 0, title: $0.title, count: $0.tracks?.count ?? 0)
            }
        }
        #endif
        SoundCloudCredentialSource.install()
        AccountSignInAnnouncer.shared.install()
        let playback = PlaybackSystem()
        let synchronization = SynchronizationSystem()
        let downloads = DownloadSystem()
        let catalog = CatalogSystem()
        let nowPlaying = MediaPlayerNowPlayingBridge()
        nowPlaying.artworkProvider = NowPlayingArtworkProviderImpl.shared
        CompanionAppBootstrap.configureSoundCloudSession(
            synchronization: synchronization,
            downloads: downloads,
            catalog: catalog,
            clearSurfaces: { SoundingSnapshotPublisher.shared.clear() },
            clearWebSession: { await AuthWebSession.clear() },
            webStore: { .default() }
        )
        let client = CompanionAppBootstrap.companionClient(synchronization: synchronization, downloads: downloads, catalog: catalog)
        let playbackCoordinator = PhonePlaybackCoordinator(client: client)
        TVSignInInbox.shared.signedInTVNames = { [weak client] in
            guard let client, case .connected = client.state, !client.peerNeedsSignIn else { return [] }
            return [client.linkedName]
        }
        IntentPlayback.sink = playbackCoordinator
        PartyScenes.outputRouter = playbackCoordinator.output
        SoundingFocus.restore()
        let runtime = AppRuntime(platform: RuntimePlatformServices(
            deviceLabel: "iPhone",
            account: CompanionAppBootstrap.account,
            lifecycleObserver: PlayerLifecycleObserver.shared,
            nowPlaying: nowPlaying,
            peerContentSource: client,
            prepare: { await CompanionAppBootstrap.prepareSession() },
            integrations: [
                RuntimeIntegrationAdapter(id: "watch", start: {
                    let watchLink = PhoneWatchLinkServer.shared
                    watchLink.attach(coordinator: playbackCoordinator)
                    watchLink.activate()
                    watchLink.publish()
                }),
                RuntimeIntegrationAdapter(id: "spotlight", start: {
                    SpotlightIndexingService.shared.start(player: playback.player)
                }),
                RuntimeIntegrationAdapter(id: "surfaces", start: {
                    SoundingSnapshotPublisher.shared.start(player: playback.player)
                }),
                RuntimeIntegrationAdapter(id: "liveActivity", start: {
                    NowPlayingLiveActivityController.shared.start(coordinator: playbackCoordinator)
                }),
                RuntimeIntegrationAdapter(id: "companion", setActive: { active in
                    client.setActive(active)
                }),
                RuntimeIntegrationAdapter(id: "volumeButtons", start: {
                    PhoneVolumeButtons.shared.attach(playbackCoordinator)
                }, setActive: { active in
                    PhoneVolumeButtons.shared.setForeground(active)
                }),
                RuntimeIntegrationAdapter(id: "homeLighting", start: {
                    let output = playbackCoordinator.output
                    HomeLightingDirector.shared.start {
                        output.isRemote ? .elsewhere(output.current.name) : .thisDevice
                    }
                }),
            ]
        ), playback: playback, synchronization: synchronization, downloads: downloads, catalog: catalog)
        CarPlayAppContext.coordinator = playbackCoordinator
        CarPlayAppContext.startRuntime = { [weak runtime] in await runtime?.start() }
        _runtime = StateObject(wrappedValue: runtime)
        _graph = State(initialValue: AppObjectGraph(queueClient: client, coordinator: playbackCoordinator))
        playerService = playback.player
        downloadManager = downloads.manager
    }

    private var startsInDJ: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SOUNDING_TV_DJ"] == "1"
        #else
        return false
        #endif
    }

    private var startsInCues: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SOUNDING_TV_CUES"] == "1"
        #else
        return false
        #endif
    }

    private var startsInSignIn: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SOUNDING_TV_SIGNIN"] == "1"
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var cueDemo: some View {
        #if DEBUG
        TrackMapSheetDemoView()
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder
    private var launchContent: some View {
        #if DEBUG
        if let destination = VisualFixtures.destination {
            PhoneVisualFixtureDestinationView(destination: destination)
        } else {
            standardLaunchContent
        }
        #else
        standardLaunchContent
        #endif
    }

    @ViewBuilder
    private var standardLaunchContent: some View {
        if startsInDJ {
            PhoneDecksView()
        } else if startsInCues {
            cueDemo
        } else if startsInSignIn {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
                .sheet(isPresented: .constant(true)) {
                    NavigationStack {
                        SoundCloudLoginView.standalone { }
                    }
                }
        } else {
            PhoneRootView()
                .libraryLinkHost()
        }
    }

    private func sharedEnvironment<Content: View>(_ content: Content) -> some View {
        content
            .environmentObject(runtime)
            .environmentObject(queueClient)
            .environmentObject(playerService)
            .environmentObject(coordinator)
            .environmentObject(pairing)
            .environmentObject(pairing.nearby)
            .environmentObject(pairing.sameAccount)
            .tint(Color.scAccent)
    }

    private var primaryScene: some View {
        PrimarySceneReader { isPrimary in
        sharedEnvironment(Group { launchContent })
        .devicePairing(pairing, enabled: isPrimary)
        .playlistFolderPrompts(isEnabled: isPrimary)
        .nearbyDeviceCard(pairing.card, isEnabled: isPrimary && pairing.showsNearbyCard)
        .reconnectCard(yieldingTo: pairing.card, isEnabled: isPrimary && pairing.showsNearbyCard) { done in
            NavigationStack {
                SoundCloudLoginView.standalone(onComplete: done)
            }
        }
        .tvAccountPrompts(router: coordinator.output, isEnabled: isPrimary)
        .linkedCapsule(pairing.card.autoLinker)
        .sheet(isPresented: isPrimary ? $signInNotifications.isPriming : .constant(false)) {
            SignInRequestsPrimingView(notifications: signInNotifications)
        }
        .sheet(isPresented: isPrimary ? $outsideAlerts.showsDevices : .constant(false)) {
            sharedEnvironment(AccountSignInDevicesSheet())
        }
        .onReceive(TVSignInInbox.shared.$invitation.compactMap { $0 }) { invitation in
            guard isPrimary else { return }
            TVSignInInbox.shared.invitation = nil
            pairing.accept(invitation)
        }
        .onReceive(NearbyLinkInbox.shared.$pending.compactMap { $0 }) { request in
            guard isPrimary else { return }
            NearbyLinkInbox.shared.pending = nil
            pairing.link(request)
        }
        #if DEBUG
        .modifier(TrackTrimFixtureSheet())
        .task {
            guard isPrimary else { return }
            if let invitation = TVSignInInbox.fixtureInvitation { pairing.accept(invitation) }
            if let phase = ProcessInfo.processInfo.environment["SOUNDING_TV_TV_SIGNIN_ACTIVITY"] {
                await TVSignInLiveActivityController.shared.runFixture(phase)
            }
        }
        #endif
        .task {
            #if DEBUG
            guard !VisualFixtures.isEnabled else { return }
            #endif
            await runtime.start()
        }
        .onReceive(queueClient.$authHandoffRequest.compactMap { $0 }) { request in
            Task {
                if let session = await SilentWebReauthorizer.authorize(using: .default()) {
                    queueClient.sendAuthHandoffSession(session)
                } else {
                    authHandoffRequest = request
                }
            }
        }
        .onReceive(SoundCloudCredentialSource.shared.$state.map(\.sessionHealth).removeDuplicates()) { _ in
            // Only an explicit sign-out is a playback/privacy boundary on
            // a personal device. A rejected or refreshing credential keeps
            // the restored queue and Now Playing UI available for recovery.
            guard SoundCloudCredentialSource.shared.isSignedOut else { return }
            playerService.clearQueue(forgetSavedSession: false)
            downloadManager.lockAccountVault()
        }
        .onReceive(SubscriptionService.shared.$authenticatedAccountID.removeDuplicates()) { accountID in
            if let accountID {
                SettingsStore.shared.unlockAccount(accountID)
            } else {
                SettingsStore.shared.lockAccount()
                URLCache.shared.removeAllCachedResponses()
                Task { await SCArtworkStore.shared.removeAll() }
            }
        }
        .scoutPriming(isActive: isPrimary)
        .sheet(item: Binding(
            get: { isPrimary ? authHandoffRequest : nil },
            set: { if isPrimary { authHandoffRequest = $0 } }
        )) { request in
            NavigationStack {
                SoundCloudLoginView.authHandoff(
                    sessionId: request.sessionId,
                    sessionSecret: request.secret,
                    peerName: request.peerName,
                    peerClass: request.peerClass,
                    client: queueClient,
                    onComplete: { authHandoffRequest = nil }
                )
            }
        }
        .alert(
            "Unable to Sign In",
            isPresented: Binding(
                get: { isPrimary && authErrorMessage != nil },
                set: { if !$0 { authErrorMessage = nil } }
            ),
            presenting: authErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { authErrorMessage = nil }
        } message: { message in
            Text(message)
        }
        .onOpenURL { url in
            guard !WidgetLinkRouter.handle(url) else { return }
            handleAuthURL(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                guard !WidgetLinkRouter.handle(url) else { return }
                handleAuthURL(url)
            }
        }
        .onContinueUserActivity(HandoffActivityType.link) { activity in
            guard let raw = activity.userInfo?["pairingURL"] as? String,
                  let url = URL(string: raw) else { return }
            handleAuthURL(url)
        }
        .modifier(ContinueFromHandoff())
        #if DEBUG
        .task {
            guard pairing.request == nil,
                  let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_PAIRING_URL"],
                  let url = URL(string: raw) else { return }
            handleAuthURL(url)
        }
        #endif
        }
        .tint(Color.scAccent)
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let probe = SidebarProbe.kind {
                SidebarProbeView(kind: probe)
            } else {
                primaryScene
            }
            #else
            primaryScene
            #endif
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            runtime.setActive(phase == .active)
            pairing.sameAccount.setForeground(phase == .active)
            pairing.card.setForeground(phase == .active)
            switch phase {
            case .active:
                pairing.nearby.start()
                if LinkedCompanionStore.load() != nil { pairing.nearby.startIfNeeded() }
                Task { await TVSignInNotifications.shared.refresh() }
                Task { await ScoutMonitor.shared.check() }
                if SoundCloudCredentialSource.shared.canRetrySession {
                    Task { await SoundCloudCredentialSource.shared.revalidate() }
                }
            case .background:
                pairing.nearby.suspend()
                pairing.nearby.stop()
                ScoutBackgroundRefresh.schedule()
            case .inactive:
                pairing.nearby.stop()
            @unknown default: break
            }
        }
        .backgroundTask(.appRefresh(ScoutBackgroundRefresh.identifier)) {
            await ScoutBackgroundRefresh.run()
        }
        .commands {
            PlaybackCommands(coordinator: coordinator)
        }

        WindowGroup("Sounding", id: WindowRoute.sceneID, for: WindowRoute.self) { $route in
            if let route {
                sharedEnvironment(DetailWindowRoot(route: route))
                    .navigationTitle(route.title)
            } else {
                primaryScene
            }
        }
    }

    private func handleAuthURL(_ url: URL) {
        authErrorMessage = pairing.link(url: url)
    }
}

#if DEBUG
@MainActor
private final class FrameProbe: NSObject {
    private static var shared: FrameProbe?
    private let label: String
    private let logger = Logger(subsystem: "red.forbes.sounding", category: "frameprobe")
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var hitchMs = 0.0
    private var worstMs = 0.0

    private init(label: String) {
        self.label = label
    }

    static func startIfRequested() {
        guard let label = ProcessInfo.processInfo.environment["SOUNDING_TV_FRAME_PROBE"], shared == nil else { return }
        let probe = FrameProbe(label: label)
        shared = probe
        let link = CADisplayLink(target: probe, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        probe.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard last > 0 else {
            windowStart = now
            driver = FrameProbeDriver(script: ProcessInfo.processInfo.environment["SOUNDING_TV_FRAME_PROBE_DRIVE"], start: now)
            return
        }
        let delta = now - last
        let expected = link.duration
        frames += 1
        var over = 0.0
        if delta > expected * 1.5 {
            over = (delta - expected) * 1000
            hitchMs += over
            worstMs = max(worstMs, over)
        }
        if let phase = driver?.advance(now: now, delta: delta, hitchMs: over) {
            logger.notice("probe \(self.label, privacy: .public) phase=\(phase.name, privacy: .public) seconds=\(phase.seconds, format: .fixed(precision: 2)) frames=\(phase.frames) hitchMsPerSec=\(phase.hitchMs / max(phase.seconds, 0.001), format: .fixed(precision: 2)) worstMs=\(phase.worstMs, format: .fixed(precision: 1))")
        }
        let elapsed = now - windowStart
        if elapsed >= 1 {
            logger.notice("probe \(self.label, privacy: .public) frames=\(self.frames) hitchMsPerSec=\(self.hitchMs / elapsed, format: .fixed(precision: 2)) worstMs=\(self.worstMs, format: .fixed(precision: 1))")
            windowStart = now
            frames = 0
            hitchMs = 0
            worstMs = 0
        }
    }

    private var driver: FrameProbeDriver?
}

@MainActor
private final class FrameProbeDriver {
    struct Phase {
        let name: String
        let seconds: Double
        let frames: Int
        let hitchMs: Double
        let worstMs: Double
    }

    private enum Step {
        case wait(Double)
        case scroll(Int)
        case tap(String)
        case search(String)
        case back
    }

    private var steps: [Step]
    private var current: Step?
    private var phaseStart: CFTimeInterval
    private var frames = 0
    private var hitchMs = 0.0
    private var worstMs = 0.0
    private var flings: [CGFloat] = []
    private var velocity: CGFloat = 0
    private weak var scrollView: UIScrollView?

    init?(script: String?, start: CFTimeInterval) {
        guard let script, !script.isEmpty else { return nil }
        steps = script.split(separator: ",").compactMap { raw in
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "wait": return .wait(Double(argument) ?? 1)
            case "scroll": return .scroll(Int(argument) ?? 4)
            case "tap": return .tap(argument)
            case "search": return .search(argument)
            case "back": return .back
            default: return nil
            }
        }
        phaseStart = start
    }

    func advance(now: CFTimeInterval, delta: CFTimeInterval, hitchMs over: Double) -> Phase? {
        if current != nil {
            frames += 1
            hitchMs += over
            worstMs = max(worstMs, over)
        }
        let elapsed = now - phaseStart
        var finished: Phase?
        switch current {
        case .wait(let seconds)?:
            if elapsed >= seconds { finished = finish(now) }
        case .tap?, .search?, .back?:
            if elapsed >= 1.5 { finished = finish(now) }
        case .scroll?:
            if scrollView == nil, elapsed < 2 { scrollView = Self.mainScrollView() }
            if (scrollView != nil || elapsed >= 2), stepScroll(delta: delta) { finished = finish(now) }
        case nil:
            break
        }
        if current == nil, !steps.isEmpty {
            begin(steps.removeFirst(), now: now)
        }
        return finished
    }

    private func finish(_ now: CFTimeInterval) -> Phase {
        let phase = Phase(name: name(of: current), seconds: now - phaseStart, frames: frames, hitchMs: hitchMs, worstMs: worstMs)
        current = nil
        return phase
    }

    private func begin(_ step: Step, now: CFTimeInterval) {
        current = step
        phaseStart = now
        frames = 0
        hitchMs = 0
        worstMs = 0
        switch step {
        case .scroll(let cycles):
            scrollView = Self.mainScrollView()
            flings = Array(repeating: [4200, 4200, -4200, -4200] as [CGFloat], count: cycles).flatMap { $0 }
            velocity = 0
        case .tap(let label):
            Self.select(label)
        case .search(let query):
            Self.search(query)
        case .back:
            Self.navigationController()?.popViewController(animated: true)
        case .wait:
            break
        }
    }

    private func stepScroll(delta: CFTimeInterval) -> Bool {
        guard let scrollView else { return true }
        if abs(velocity) < 300 {
            guard !flings.isEmpty else { return true }
            velocity = flings.removeFirst()
        }
        let dt = CGFloat(min(delta, 0.1))
        let inset = scrollView.adjustedContentInset
        let minimum = -inset.top
        let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        var y = scrollView.contentOffset.y + velocity * dt
        if y <= minimum || y >= maximum {
            y = min(max(y, minimum), maximum)
            velocity = 0
        } else {
            velocity *= pow(0.998, dt * 1000)
        }
        scrollView.contentOffset.y = y
        return false
    }

    private func name(of step: Step?) -> String {
        switch step {
        case .wait(let seconds)?: return "wait\(Int(seconds))"
        case .scroll?: return "scroll"
        case .tap(let label)?: return "push:\(label)"
        case .search?: return "search"
        case .back?: return "back"
        case nil: return "none"
        }
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private static func descendants<T: UIView>(of view: UIView, _ type: T.Type) -> [T] {
        view.subviews.flatMap { subview -> [T] in
            guard !subview.isHidden else { return [] }
            return (subview as? T).map { [$0] + descendants(of: subview, type) } ?? descendants(of: subview, type)
        }
    }

    private static func mainScrollView() -> UIScrollView? {
        guard let window = keyWindow else { return nil }
        return descendants(of: window, UIScrollView.self)
            .filter { $0.contentSize.height > $0.bounds.height + 20 && !($0 is UITextView) }
            .filter { $0.convert($0.bounds, to: window).intersects(window.bounds) }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    private static func navigationController() -> UINavigationController? {
        guard let window = keyWindow else { return nil }
        var controller = window.rootViewController
        var found: UINavigationController?
        while let next = controller {
            if let navigation = next as? UINavigationController { found = navigation }
            controller = next.presentedViewController
                ?? (next as? UINavigationController)?.topViewController
                ?? (next as? UITabBarController)?.selectedViewController
                ?? next.children.first { $0.viewIfLoaded?.window != nil }
            if controller === next { break }
        }
        return found
    }

    private static func select(_ row: String) {
        guard let window = keyWindow,
              let collection = descendants(of: window, UICollectionView.self)
                .max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else { return }
        let indexPath = IndexPath(item: Int(row) ?? 0, section: 0)
        guard collection.numberOfSections > 0, collection.numberOfItems(inSection: 0) > indexPath.item else { return }
        collection.selectItem(at: indexPath, animated: false, scrollPosition: [])
        collection.delegate?.collectionView?(collection, didSelectItemAt: indexPath)
    }

    private static func search(_ query: String) {
        guard let window = keyWindow, let bar = descendants(of: window, UISearchBar.self).first else { return }
        bar.text = query
        bar.delegate?.searchBar?(bar, textDidChange: query)
        bar.delegate?.searchBarSearchButtonClicked?(bar)
    }
}

private struct PhoneVisualFixtureDestinationView: View {
    let destination: String

    var body: some View {
        switch destination.lowercased() {
        case "artist":
            NavigationStack { ArtistDetailView(user: VisualFixtures.artists[0]).appNavigationDestinations() }
        case "playlist":
            if let playlist = VisualFixtures.playlists.first {
                NavigationStack { PlaylistFixtureView(playlist: playlist).appNavigationDestinations() }
            }
        default:
            PhoneRootView()
        }
    }
}
#endif

final class SoundingTViOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        TVSignInNotifications.shared.install()
        DevicePickerSignInListener.shared.start()
        return true
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.link.info("[SignInRequest] push registration failed: \(error.localizedDescription, privacy: .public)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let recordName = OutsideAlerts.withdrawnRecordName(from: userInfo) else {
            completionHandler(.noData)
            return
        }
        Task {
            await OutsideAlerts.withdrawRequest(recordName: recordName)
            completionHandler(.newData)
        }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        DecksOrientationLock.mask
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? PlayMediaIntentHandler() : nil
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            _ = DownloadManager.shared.handleBackgroundURLSessionEvents(
                identifier: identifier,
                completionHandler: completionHandler
            )
        }
    }
}
