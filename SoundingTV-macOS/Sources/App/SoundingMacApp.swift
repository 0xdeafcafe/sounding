import SwiftUI
import AppKit
import Combine
import os
import UserNotifications

@MainActor
private final class MacActivityPollingCoordinator: ObservableObject {
    private let scheduler = WorkScheduler.shared
    private var accountID: String?

    func start(accountID: String) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        scheduler.registerPeriodic(
            id: "activity.notifications",
            scope: "activity",
            interval: .seconds(15 * 60)
        ) { [weak self] in
            guard let self, let accountID = self.accountID else { return }
            let events = await SoundCloudActivityPoller.shared.poll(accountID: accountID)
            await MacActivityNotificationDelivery.deliver(events)
        }
    }

    func stop() {
        accountID = nil
        scheduler.cancelPeriodic(id: "activity.notifications")
    }
}

@main
struct SoundingMacApp: App {
    @NSApplicationDelegateAdaptor(MacOutsideAlertsAppDelegate.self) private var outsideAlertsDelegate
    @StateObject private var runtime: AppRuntime
    @StateObject private var credentials = SoundCloudCredentialSource.shared
    @StateObject private var midi = DJControllerHub.shared
    @StateObject private var tvCompanion: CompanionClient
    @StateObject private var outputRouter: OutputRouter
    @StateObject private var activityPolling = MacActivityPollingCoordinator()
    @State private var authHandoffRequest: AuthHandoffRequest?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        if MacSetAnalysis.isRequested { MacSetAnalysis.runAndExit() }
        #endif
        MemoryRelief.install()
        SoundingTips.configure()
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_WINDOW_SIZE"] != nil {
            let defaults = UserDefaults.standard
            let staleKeys = defaults.dictionaryRepresentation().keys.filter {
                $0.hasPrefix("NSWindow Frame SwiftUI.WindowGroup")
                    || $0.hasPrefix("NSSplitView Subview Frames SwiftUI.WindowGroup")
            }
            for key in staleKeys { defaults.removeObject(forKey: key) }
        }
        #endif
        SoundCloudCredentialSource.install()
        AccountSignInAnnouncer.shared.install()
        UNUserNotificationCenter.current().delegate = MacActivityNotificationDelegate.shared
        MacOutsideAlerts.install()
        let playback = PlaybackSystem()
        let synchronization = SynchronizationSystem()
        let downloads = DownloadSystem()
        let catalog = CatalogSystem()
        CompanionAppBootstrap.configureSoundCloudSession(
            synchronization: synchronization,
            downloads: downloads,
            catalog: catalog,
            clearSurfaces: { SoundingSnapshotPublisher.shared.clear() },
            clearWebSession: { await MacSoundCloudWebsiteData.clear() },
            webStore: { MacSoundCloudWebsiteData.persistentStore }
        )
        MacAudioSessionCoordinator.install()
        let companion = CompanionAppBootstrap.companionClient(synchronization: synchronization, downloads: downloads, catalog: catalog)
        let runtime = AppRuntime(platform: RuntimePlatformServices(
            deviceLabel: "Mac",
            account: CompanionAppBootstrap.account,
            lifecycleObserver: PlayerLifecycleObserver.shared,
            nowPlaying: MediaSessionNowPlayingBridge(),
            peerContentSource: companion,
            prepare: { await CompanionAppBootstrap.prepareSession() },
            integrations: [
                RuntimeIntegrationAdapter(id: "spotlight", start: {
                    SpotlightIndexingService.shared.start(player: playback.player)
                }),
                RuntimeIntegrationAdapter(id: "surfaces", start: {
                    SoundingSnapshotPublisher.shared.start(player: playback.player)
                }),
                RuntimeIntegrationAdapter(id: "midi", start: {
                    MacDeckControlSurface.shared.start()
                }),
                RuntimeIntegrationAdapter(
                    id: "companion",
                    start: { companion.connect() },
                    setActive: { active in
                        companion.setActive(active)
                    }
                ),
            ]
        ), playback: playback, synchronization: synchronization, downloads: downloads, catalog: catalog)
        _runtime = StateObject(wrappedValue: runtime)
        _tvCompanion = StateObject(wrappedValue: companion)
        let outputRouter = OutputRouter(client: companion)
        _outputRouter = StateObject(wrappedValue: outputRouter)
        MacPlaybackTimeline.shared.attach(output: outputRouter)
        MacNowPlayingModel.shared.attach(output: outputRouter)
        MacPlaybackTarget.router = outputRouter
        IntentPlayback.sink = outputRouter
        PartyScenes.outputRouter = outputRouter
        SoundingFocus.restore()
        DevicePresenceModel.shared.attach(router: outputRouter)
    }

    #if DEBUG
    private struct MacDebugForceActive: ViewModifier {
        func body(content: Content) -> some View {
            if ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_FORCE_ACTIVE"] == "1" {
                content.environment(\.controlActiveState, .key)
            } else {
                content
            }
        }
    }

    private struct MacDebugColorScheme: ViewModifier {
        func body(content: Content) -> some View {
            if let scheme = SoundingMacApp.debugColorScheme {
                content.preferredColorScheme(scheme)
            } else {
                content
            }
        }
    }

    private static var debugColorScheme: ColorScheme? {
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_APPEARANCE"]?.lowercased() {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
    #endif

    var body: some Scene {
        Window("Sounding", id: "main") {
            MacRootView()
                .environmentObject(credentials)
                .environmentObject(runtime)
                .environmentObject(midi)
                .environmentObject(tvCompanion)
                .environmentObject(outputRouter)
                .environment(\.outputRouter, outputRouter)
                .tint(Color.scAccent)
                #if DEBUG
                .modifier(MacDebugColorScheme())
                .modifier(MacDebugForceActive())
                #endif
                .frame(minWidth: 1040, idealWidth: 1360, minHeight: 640, idealHeight: 820)
                .background(MacWindowChrome(configuresMainWindow: true).frame(width: 0, height: 0))
                .background(MacMessageWindowBridge())
                .modifier(MacOutsideAlertsOpener())
                .modifier(ContinueFromHandoff())
                .onOpenURL { url in
                    _ = WidgetLinkRouter.handle(url)
                }
                .onReceive(SoundingPageLinkRouter.shared.$pending.compactMap { $0 }) { request in
                    switch SoundingPageLinkRouter.shared.take(request) {
                    case .artist(let user): MacRootSelection.shared.request(artist: user)
                    case .playlist(let playlist): MacRootSelection.shared.request(playlist: playlist)
                    case .track(let track): BehindTheTrackPresenter.shared.present(track)
                    case nil: break
                    }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    _ = WidgetLinkRouter.handle(url)
                }
                .playlistFolderPrompts()
                .artworkImageCaching()
                .onChange(of: credentials.isSignedOut) { _, isSignedOut in
                    if isSignedOut { ArtworkImageSession.clear() }
                }
                .task {
                    #if DEBUG
                    if VisualFixtures.isEnabled { return }
                    #endif
                    await runtime.start()
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["SOUNDING_TV_MIXAUDIOTEST"] == "1" {
                        await MacMixAudioSelfTest.run()
                    }
                    #endif
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    runtime.setActive(phase == .active)
                    MacTVLinking.shared.setForeground(phase == .active)
                    if phase == .active, credentials.canRetrySession {
                        Task { await credentials.revalidate() }
                    }
                }
                .scoutPriming()
                .task(id: credentials.currentUser?.id ?? "signed-out") {
                    guard await credentials.waitForCurrentUser() != nil else {
                        ScoutMacSchedule.stop()
                        return
                    }
                    ScoutMacSchedule.start()
                }
                .task(id: "\(credentials.currentUser?.id ?? "signed-out")|\(scenePhase == .active)") {
                    guard scenePhase == .active else {
                        activityPolling.stop()
                        return
                    }
                    guard let user = await credentials.waitForCurrentUser() else {
                        activityPolling.stop()
                        return
                    }
                    await MacActivityNotificationDelivery.prepare()
                    activityPolling.start(accountID: user.id)
                }
                .onReceive(tvCompanion.$authHandoffRequest.compactMap { $0 }) { request in
                    Task {
                        if let session = await SilentWebReauthorizer.authorize(using: MacSoundCloudWebsiteData.persistentStore) {
                            tvCompanion.sendAuthHandoffSession(session)
                        } else {
                            authHandoffRequest = request
                        }
                    }
                }
                .sheet(item: $authHandoffRequest) { request in
                    MacSoundCloudSignInView(
                        peerName: request.peerName ?? request.peerClass.displayName,
                        forHandoff: true
                    ) {
                        authHandoffRequest = nil
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Playlist…") {
                    MacRootSelection.shared.requestNewPlaylist()
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("New Playlist Folder…") {
                    PlaylistFolderPrompter.shared.newFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
            }
            SidebarCommands()
            SoundingViewCommands()
            LibraryCommands()
            TransportCommands()
            DecksCommands()
            MessagingCommands()
            MacPrepCommands()
            MacRekordboxImportCommands()
        }


        Settings {
            MacSettingsView()
                .artworkImageCaching()
                .environmentObject(credentials)
                .environmentObject(runtime)
                .environmentObject(midi)
                .environmentObject(tvCompanion)
                .environmentObject(outputRouter)
                .tint(Color.scAccent)
                #if DEBUG
                .modifier(MacDebugColorScheme())
                #endif
        }
        .windowResizability(.contentSize)

        Window("Prep", id: MacPrepCommands.windowID) {
            MacPrepView()
                .tint(Color.scAccent)
                .artworkImageCaching()
                #if DEBUG
                .modifier(MacDebugColorScheme())
                #endif
        }
        .defaultSize(width: 1180, height: 760)

        MenuBarExtra("Sounding", systemImage: "waveform.circle.fill") {
            MacMenuBarPlayerView()
                .environmentObject(runtime)
                .tint(Color.scAccent)
                .artworkImageCaching()
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private enum MacActivityNotificationDelivery {
    private static let center = UNUserNotificationCenter.current()

    static func prepare() async {
        center.delegate = MacActivityNotificationDelegate.shared
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await MacOutsideAlerts.refresh()
    }

    static func deliver(_ events: [SoundCloudInboxEvent]) async {
        guard !events.isEmpty else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            content.userInfo = [
                "eventID": event.id,
                "destination": event.destination?.absoluteString ?? "",
            ]
            let request = UNNotificationRequest(
                identifier: "soundcloud.activity.\(event.id)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}

private final class MacActivityNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = MacActivityNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        if let signIn = AccountSignIn(remoteNotification: userInfo) {
            return await MacOutsideAlerts.presentation(for: signIn)
        }
        if let request = SignInRequest(remoteNotification: userInfo) {
            return request.isExpired() ? [] : [.banner, .list, .sound]
        }
        if let link = NearbyLinkRequest(remoteNotification: userInfo) {
            return await MacOutsideAlerts.presentation(for: link)
        }
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let action = OutsideAlerts.response(for: response.actionIdentifier)
        if let signIn = AccountSignIn(remoteNotification: userInfo) {
            await MacOutsideAlerts.open(signIn, action: action)
            return
        }
        if let request = SignInRequest(remoteNotification: userInfo) {
            await MacOutsideAlerts.open(request, action: action)
            return
        }
        if let link = NearbyLinkRequest(remoteNotification: userInfo) {
            await MacOutsideAlerts.open(link, action: action)
            return
        }
        if let target = ScoutNotifications.target(from: userInfo) {
            await ScoutNotifications.open(kind: target.kind, id: target.id)
            return
        }
        guard let raw = response.notification.request.content.userInfo["destination"] as? String,
              let url = URL(string: raw), !raw.isEmpty else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }
}

struct MacMenuBarPlayerView: View {
    @ObservedObject private var player = PlayerService.shared
    @Environment(\.openWindow) private var openWindow

    private var track: Track? { MacNowPlayingModel.shared.track }
    private var timeline: MacPlaybackTimeline { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let track {
                HStack(spacing: 10) {
                    ArtworkThumbnail(
                        url: track.artworkURL,
                        identity: track.id,
                        size: 44,
                        cornerRadius: 6,
                        isAvailable: track.streamURL != nil,
                        crownUser: track.user,
                        crownContext: track.title
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(track.user.displayName)
                            .font(.caption)
                            .foregroundStyle(MacSecondaryStyle())
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                MacLiveClock { position in
                    let duration = max(1, timeline.anchor.duration)
                    ProgressView(value: min(1, position / duration))
                        .tint(.primary)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(macFormatTime(position)) of \(macFormatTime(duration))")
                }

                HStack(spacing: 28) {
                    Spacer(minLength: 0)
                    Button {
                        if let remote = MacPlaybackTarget.output {
                            remote.previous()
                        } else {
                            Task { await InstantReplay.previous(player) }
                        }
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    .accessibilityLabel("Previous")
                    .help("Previous")
                    Button {
                        timeline.togglePlayPause()
                    } label: {
                        Image(systemName: timeline.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel(timeline.isPlaying ? "Pause" : "Play")
                    .help(timeline.isPlaying ? "Pause" : "Play")
                    Button {
                        if let remote = MacPlaybackTarget.output {
                            remote.next()
                        } else {
                            Task { await player.playNext() }
                        }
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    .accessibilityLabel("Next")
                    .help("Next")
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .padding(.vertical, 2)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "waveform.circle")
                    .frame(maxWidth: .infinity)
            }

            Divider()

            Button("Open Sounding") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            .buttonStyle(.plain)
            .font(.body)

            Button("Quit Sounding") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.body)
            .foregroundStyle(MacSecondaryStyle())
        }
        .padding(14)
        .frame(width: 260)
    }
}

struct TransportCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Playback") {
            Button {
                let controller = MacConsoleController.shared
                if controller.isConsoleActive {
                    controller.togglePlayPause(controller.focusedDeck)
                } else if let remote = MacPlaybackTarget.output {
                    remote.togglePlayPause()
                } else {
                    PlayerService.shared.togglePlayPause()
                }
            } label: {
                Label("Play/Pause", systemImage: "playpause")
            }
            .keyboardShortcut(.space, modifiers: [])
            Button {
                guard !MacConsoleController.shared.isConsoleActive else { return }
                if let remote = MacPlaybackTarget.output {
                    remote.next()
                } else {
                    Task { await PlayerService.shared.playNext() }
                }
            } label: {
                Label("Next Track", systemImage: "forward.fill")
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            Button {
                guard !MacConsoleController.shared.isConsoleActive else { return }
                if let remote = MacPlaybackTarget.output {
                    remote.previous()
                } else {
                    Task { await InstantReplay.previous(PlayerService.shared) }
                }
            } label: {
                Label("Previous Track", systemImage: "backward.fill")
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            Button {
                guard !MacConsoleController.shared.isConsoleActive else { return }
                if let remote = MacPlaybackTarget.output {
                    remote.seek(toSeconds: max(0, remote.telemetry.estimatedPosition() - 15))
                    return
                }
                let player = PlayerService.shared
                player.seek(to: max(0, player.currentTime - 15))
            } label: {
                Label("Skip Back 15 Seconds", systemImage: "gobackward.15")
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button {
                guard !MacConsoleController.shared.isConsoleActive else { return }
                if let remote = MacPlaybackTarget.output {
                    let duration = remote.telemetry.playback?.durationSeconds ?? 0
                    remote.seek(toSeconds: min(duration, remote.telemetry.estimatedPosition() + 15))
                    return
                }
                let player = PlayerService.shared
                player.seek(to: min(player.duration, player.currentTime + 15))
            } label: {
                Label("Skip Forward 15 Seconds", systemImage: "goforward.15")
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Divider()
            Button {
                MacPlayback.toggleShuffle()
            } label: {
                Label(MacPlayback.isShuffleEnabled ? "Shuffle Off" : "Shuffle On", systemImage: "shuffle")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            Button {
                MacPlayback.cycleRepeatMode()
            } label: {
                Label("Cycle Repeat", systemImage: "repeat")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button {
                guard let track = MacNowPlayingModel.shared.track else { return }
                Task { await MacTrackEngagement.shared.toggleLike(track) }
            } label: {
                Label(
                    MacNowPlayingModel.shared.track.map { MacTrackEngagement.shared.isLiked($0) } == true ? "Unlike" : "Like",
                    systemImage: "heart"
                )
            }
            .keyboardShortcut("l", modifiers: [.command])
            .disabled(MacNowPlayingModel.shared.track?.supportsSoundCloudActions != true)
            Divider()
            Button {
                openWindow(id: "main")
                MacNowPlayingPresentation.shared.toggle()
            } label: {
                Label("Now Playing", systemImage: "music.note.house")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button {
                openWindow(id: "main")
                MacNowPlayingPresentation.shared.present(.comments)
            } label: {
                Label("Timed Comments", systemImage: "quote.bubble")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(MacNowPlayingModel.shared.track?.supportsSoundCloudActions == false)
            Divider()
            Button {
                MacRootSelection.shared.request(.console)
            } label: {
                Label("Open Decks", systemImage: "slider.horizontal.3")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}

@MainActor
final class MacFindFocus: ObservableObject {
    static let shared = MacFindFocus()
    @Published private(set) var request = 0
    private init() {}
    func requestFocus() { request &+= 1 }
}

struct SoundingViewCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find") { MacFindFocus.shared.requestFocus() }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button {
                MacHistoryRoute.shared.open()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut("y", modifiers: .command)

            Button {
                MacRootSelection.shared.toggleQueue()
            } label: {
                Label("Show or Hide Queue", systemImage: "music.note.list")
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])

            Button {
                MacLibraryCommandPreferences.toggleArtwork()
            } label: {
                Label("Toggle Artwork in Track Lists", systemImage: "photo")
            }

            Button {
                MacLibraryCommandPreferences.toggleCompactRows()
            } label: {
                Label("Toggle Compact Track Rows", systemImage: "rectangle.compress.vertical")
            }
        }
    }
}

private enum MacLibraryCommandPreferences {
    private static let artworkKey = "mac.library.showsArtwork"
    private static let compactRowsKey = "mac.library.compactRows"

    static func toggleArtwork(defaults: UserDefaults = .standard) {
        defaults.set(!value(for: artworkKey, defaultValue: true, defaults: defaults), forKey: artworkKey)
    }

    static func toggleCompactRows(defaults: UserDefaults = .standard) {
        defaults.set(!value(for: compactRowsKey, defaultValue: true, defaults: defaults), forKey: compactRowsKey)
    }

    private static func value(
        for key: String,
        defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }
}

struct LibraryCommands: Commands {
    var body: some Commands {
        CommandMenu("Library") {
            destination("Likes", systemImage: "heart", section: .likes, shortcut: "1")
            destination("Artists", systemImage: "music.microphone", section: .artists, shortcut: "2")
            destination("All Playlists", systemImage: "square.stack.3d.up", section: .playlists, shortcut: "3")
            Divider()
            destination("Search SoundCloud", systemImage: "magnifyingglass", section: .search, shortcut: "f")
            Button {
                IdentifySongPresenter.shared.listen()
            } label: {
                Label("Identify Song", systemImage: "shazam.logo")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Button {
                IdentifySongPresenter.shared.showHistory()
            } label: {
                Label("Recently Identified", systemImage: "clock")
            }
        }
    }

    @ViewBuilder
    private func destination(
        _ title: String,
        systemImage: String,
        section: MacRootView.Section,
        shortcut: KeyEquivalent? = nil
    ) -> some View {
        if let shortcut {
            Button {
                MacRootSelection.shared.request(section)
            } label: {
                Label(title, systemImage: systemImage)
            }
            .keyboardShortcut(shortcut, modifiers: [.command, .option])
        } else {
            Button {
                MacRootSelection.shared.request(section)
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }
}

// MARK: - SoundCloud messages

@MainActor
final class MacMessageComposer: ObservableObject {
    static let shared = MacMessageComposer()

    @Published private(set) var revision = 0
    private(set) var sharedTrack: Track?
    private(set) var recipient: User?

    private init() {}

    func present(track: Track? = nil) {
        sharedTrack = track
        recipient = nil
        revision += 1
    }

    func present(user: User) {
        sharedTrack = nil
        recipient = user
        revision += 1
    }

    func consumeSharedTrack() -> Track? {
        defer { sharedTrack = nil }
        return sharedTrack
    }

    func consumeRecipient() -> User? {
        defer { recipient = nil }
        return recipient
    }
}

private struct MacMessageWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var composer = MacMessageComposer.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: composer.revision) { _, _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                MacRootSelection.shared.request(.messages)
            }
    }
}

struct MessagingCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Social") {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                MacRootSelection.shared.request(.messages)
            } label: {
                Label("Messages", systemImage: "bubble.left.and.bubble.right")
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }
}

@MainActor
private final class MacMessagesModel: ObservableObject {
    @Published private(set) var conversations: [SoundCloudConversation] = []
    @Published var selectedID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var requiresWebInbox = false
    @Published private(set) var userResults: [User] = []
    @Published private(set) var isSearchingUsers = false

    private static let loadFailureMessage = "Couldn’t reach SoundCloud. Check your connection and try again."

    private let api = SoundCloudAPI.shared
    private var searchTask: Task<Void, Never>?
    private var cacheAccountID: String?
    private var pagerObservation: AnyCancellable?

    let pager = Paginator<SoundCloudConversation>(soundCloudSource: PagedSource(
        first: { PagedChunk(items: []) },
        next: { cursor in
            guard case .url(let url) = cursor else { return PagedChunk(items: []) }
            let page = try await SoundCloudAPI.shared.getPage(SoundCloudConversation.self, from: url)
            return PagedChunk(items: page.collection, next: page.nextHref.map(PagedCursor.url))
        }
    ))

    init() {
        pager.onAppend = { [weak self] fresh in self?.absorbConversations(fresh) }
        pagerObservation = pager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func absorbConversations(_ fresh: [SoundCloudConversation]) {
        let known = Set(conversations.map(\.id))
        let additions = fresh.filter { !known.contains($0.id) }
        guard !additions.isEmpty else { return }
        conversations = (conversations + additions).sorted(by: Self.isNewer)
        Task { await persistCache() }
    }

    var selectedConversation: SoundCloudConversation? {
        conversations.first(where: { $0.id == selectedID })
    }

    func restoreCached(accountID: String) async {
        cacheAccountID = accountID
        guard conversations.isEmpty,
              let cached = await MacMessageCache.shared.load(accountID: accountID) else { return }
        conversations = cached.sorted(by: Self.isNewer)
        if selectedID == nil { selectedID = conversations.first?.id }
    }

    func load(accountID: String? = nil) async {
        guard !isLoading else { return }
        if let accountID { await restoreCached(accountID: accountID) }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await api.getConversations(limit: 50)
            conversations = page.collection.sorted(by: Self.isNewer)
            pager.prime(items: conversations, cursor: page.nextHref.map(PagedCursor.url))
            await persistCache()
            requiresWebInbox = false
            if selectedID == nil { selectedID = conversations.first?.id }
            if let selectedID { await loadConversation(selectedID) }
        } catch SoundCloudMessagingError.unavailable {
            requiresWebInbox = true
            errorMessage = SoundCloudMessagingError.unavailable.localizedDescription
        } catch {
            errorMessage = Self.loadFailureMessage
        }
    }

    func loadConversation(_ id: String) async {
        do {
            let loaded = try await api.getConversation(id: id)
            replace(loaded)
            await persistCache()
        } catch SoundCloudMessagingError.unavailable {
            requiresWebInbox = true
        } catch {
            if selectedConversation?.messages.isEmpty != false {
                errorMessage = Self.loadFailureMessage
            }
        }
    }

    func send(_ draft: String, to recipient: SoundCloudMessageParticipant) async -> Bool {
        await send(draft, recipientID: recipient.id, conversationID: selectedID)
    }

    func startConversation(_ draft: String, with user: User) async -> Bool {
        let sent = await send(draft, recipientID: user.id, conversationID: nil)
        if sent { await load() }
        return sent
    }

    private func send(_ draft: String, recipientID: String, conversationID: String?) async -> Bool {
        guard !isSending else { return false }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            if let updated = try await api.sendDirectMessage(
                draft,
                to: recipientID,
                conversationID: conversationID
            ) {
                replace(updated)
                selectedID = updated.id
                await persistCache()
            } else if let conversationID {
                await loadConversation(conversationID)
            }
            requiresWebInbox = false
            return true
        } catch SoundCloudMessagingError.unavailable {
            requiresWebInbox = true
            errorMessage = SoundCloudMessagingError.unavailable.localizedDescription
            return false
        } catch {
            errorMessage = "Your message wasn’t sent. Try again."
            return false
        }
    }

    func searchUsers(_ query: String) {
        searchTask?.cancel()
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else {
            userResults = []
            isSearchingUsers = false
            return
        }
        isSearchingUsers = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                userResults = try await api.searchUsers(query: clean, limit: 20).collection
            } catch {
                if !Task.isCancelled { userResults = [] }
            }
            isSearchingUsers = false
        }
    }

    private func replace(_ conversation: SoundCloudConversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        conversations.sort(by: Self.isNewer)
    }

    private func persistCache() async {
        guard let cacheAccountID else { return }
        await MacMessageCache.shared.save(conversations, accountID: cacheAccountID)
    }

    private static func isNewer(_ lhs: SoundCloudConversation, _ rhs: SoundCloudConversation) -> Bool {
        (lhs.latestMessage?.createdAt ?? lhs.lastUpdatedAt ?? .distantPast)
            > (rhs.latestMessage?.createdAt ?? rhs.lastUpdatedAt ?? .distantPast)
    }
}

private actor MacMessageCache {
    static let shared = MacMessageCache()
    private let ttl: TimeInterval = 24 * 60 * 60

    private struct Snapshot: Codable {
        let savedAt: Date
        let conversations: [SoundCloudConversation]
    }

    func load(accountID: String) -> [SoundCloudConversation]? {
        let key = storageKey(accountID)
        guard let sealed = UserDefaults.standard.data(forKey: key),
              let data = AccountDataVault.open(sealed, accountID: accountID, purpose: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              Date().timeIntervalSince(snapshot.savedAt) <= ttl else { return nil }
        return snapshot.conversations
    }

    func save(_ conversations: [SoundCloudConversation], accountID: String) {
        let key = storageKey(accountID)
        guard let data = try? JSONEncoder().encode(Snapshot(savedAt: Date(), conversations: conversations)),
              let sealed = AccountDataVault.seal(data, accountID: accountID, purpose: key) else { return }
        UserDefaults.standard.set(sealed, forKey: key)
    }

    private func storageKey(_ accountID: String) -> String {
        "red.forbes.sounding.messages.v1.\(AccountDataVault.storageSuffix(for: accountID))"
    }
}

struct MacMessagesView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @Environment(\.openSettings) private var openSettings
    @StateObject private var model = MacMessagesModel()
    @ObservedObject private var composer = MacMessageComposer.shared
    @State private var draft = ""
    @State private var showsNewMessage = false
    @State private var initialRecipient: User?

    var body: some View {
        Group {
            if !credentials.hasConfirmedAccount {
                messagesGate
            } else {
                HStack(spacing: 0) {
                    conversationList
                        .frame(width: 260)
                    Divider()
                    conversationDetail
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { showsNewMessage = true } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .help("New Message")
                        .accessibilityLabel("New Message")
                        .disabled(!credentials.canPerformAccountMutations)
                        Button { Task { await model.load() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh")
                        .accessibilityLabel("Refresh")
                    }
                }
            }
        }
        .navigationTitle("Messages")
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: credentials.accessToken) {
            let accountID = credentials.currentUser?.id ?? SubscriptionService.shared.authenticatedAccountID
            if let accountID { await model.restoreCached(accountID: accountID) }
            guard credentials.accessToken != nil else { return }
            await model.load(accountID: accountID)
            consumeSharedTrack()
        }
        .onChange(of: model.selectedID) { _, id in
            guard let id else { return }
            Task { await model.loadConversation(id) }
        }
        .onChange(of: composer.revision) { _, _ in consumeSharedTrack() }
        .sheet(isPresented: $showsNewMessage) {
            MacNewMessageSheet(
                model: model,
                initialDraft: draft,
                initialRecipient: initialRecipient
            ) {
                showsNewMessage = false
                draft = ""
                initialRecipient = nil
            }
        }
    }

    @ViewBuilder
    private var messagesGate: some View {
        if credentials.isSessionRejected {
            MacAccountRecoveryEmptyState(sectionName: "Messages")
        } else if credentials.isSignedOut {
            MacSignedOutEmptyState(
                icon: "bubble.left.and.bubble.right",
                title: "Messages Need an Account",
                message: "Sign in on this Mac to see your SoundCloud messages. Home and Search work without an account.",
                browsableRoute: .home
            )
        } else {
            MacLoadingView()
        }
    }

    @ViewBuilder
    private var conversationList: some View {
        if model.isLoading && model.conversations.isEmpty {
            MacLoadingView()
        } else if model.conversations.isEmpty {
            ContentUnavailableView {
                Label(
                    model.requiresWebInbox
                        ? "Continue on SoundCloud"
                        : (model.errorMessage == nil ? "No Messages" : "Messages Unavailable"),
                    systemImage: model.requiresWebInbox ? "safari" : "bubble.left"
                )
            } description: {
                Text(model.errorMessage ?? "Start a conversation with an artist or listener.")
            } actions: {
                if model.requiresWebInbox {
                    Button("Open Web Inbox") { openWebInbox() }
                        .buttonStyle(.borderedProminent)
                } else if model.errorMessage != nil {
                    Button("Try Again") { Task { await model.load() } }
                        .buttonStyle(.borderedProminent)
                    Button("Account Settings") { openSettings() }
                        .buttonStyle(.bordered)
                }
            }
            .macFillsPane()
        } else {
            List {
                ForEach(model.conversations) { conversation in
                    MacConversationRow(
                        conversation: conversation,
                        currentUserID: credentials.currentUser?.id
                    )
                    .macSelectableRow(conversation.id, selection: $model.selectedID)
                    .onAppear { model.pager.loadMoreIfNeeded(after: conversation, lead: 8) }
                }
                MacPagedFooter(pager: model.pager, isInLazyContainer: true)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .macListKeyboardSelection(ids: model.conversations.map(\.id), selection: $model.selectedID)
        }
    }

    @ViewBuilder
    private var conversationDetail: some View {
        if let conversation = model.selectedConversation {
            MacConversationDetail(
                conversation: conversation,
                currentUserID: credentials.currentUser?.id,
                draft: $draft,
                isSending: model.isSending,
                errorMessage: model.errorMessage,
                requiresWebInbox: model.requiresWebInbox,
                allowsSending: credentials.canPerformAccountMutations,
                onSend: { recipient in
                    let outgoing = draft
                    if await model.send(outgoing, to: recipient) { draft = "" }
                },
                onOpenWeb: openWebInbox
            )
        } else {
            ContentUnavailableView {
                Label("Choose a conversation", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Your recent SoundCloud conversations appear here.")
            } actions: {
                Button("New Message") { showsNewMessage = true }
                if model.requiresWebInbox { Button("Open Web Inbox") { openWebInbox() } }
            }
            .macFillsPane()
        }
    }

    private func consumeSharedTrack() {
        if let recipient = composer.consumeRecipient() {
            initialRecipient = recipient
            showsNewMessage = true
        }
        guard let track = composer.consumeSharedTrack() else { return }
        let link = track.permalinkURL.absoluteString
        if !draft.isEmpty, !draft.hasSuffix("\n") { draft += "\n" }
        draft += link
        if model.selectedConversation == nil { showsNewMessage = true }
    }

    private func openWebInbox() {
        NSWorkspace.shared.open(SoundCloudAPI.webInboxURL)
    }
}

private struct MacConversationRow: View {
    let conversation: SoundCloudConversation
    let currentUserID: String?

    private var counterpart: SoundCloudMessageParticipant? {
        conversation.participants.first(where: { $0.id != currentUserID })
            ?? conversation.participants.first
    }

    var body: some View {
        HStack(spacing: 10) {
            MacMessageAvatar(user: counterpart, size: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(counterpart?.username ?? "Conversation")
                    .font(.body)
                    .fontWeight(conversation.unreadCount > 0 ? .bold : .regular)
                    .lineLimit(1)
                Text(conversation.latestMessage?.body ?? "No preview")
                    .font(.subheadline)
                    .foregroundStyle(MacSecondaryStyle())
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if conversation.unreadCount > 0 {
                Text(conversation.unreadCount, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(MacSecondaryStyle())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(conversation.unreadCount > 0 ? "\(conversation.unreadCount) unread" : "")
    }
}

private struct MacConversationDetail: View {
    let conversation: SoundCloudConversation
    let currentUserID: String?
    @Binding var draft: String
    let isSending: Bool
    let errorMessage: String?
    let requiresWebInbox: Bool
    let allowsSending: Bool
    let onSend: (SoundCloudMessageParticipant) async -> Void
    let onOpenWeb: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var counterpart: SoundCloudMessageParticipant? {
        conversation.participants.first(where: { $0.id != currentUserID })
            ?? conversation.participants.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MacMessageAvatar(user: counterpart, size: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(counterpart?.username ?? "Conversation").font(.headline)
                    if let profileURL = counterpart?.profileURL {
                        Link("View profile on SoundCloud", destination: profileURL)
                            .font(.caption)
                            .foregroundStyle(MacSecondaryStyle())
                    }
                }
                Spacer()
                Button("Open Web Inbox", action: onOpenWeb)
                    .buttonStyle(.link)
            }
            .padding(14)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(conversation.messages) { message in
                            MacMessageBubble(
                                message: message,
                                isOutgoing: message.sender?.id == currentUserID
                            )
                            .id(message.id)
                        }
                    }
                    .padding(18)
                }
                .onAppear {
                    if let last = conversation.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: conversation.messages.count) { _, _ in
                    if let last = conversation.messages.last {
                        withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let errorMessage {
                HStack(spacing: 8) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if requiresWebInbox { Button("Continue on Web", action: onOpenWeb) }
                }
                .font(.callout)
                .foregroundStyle(MacSecondaryStyle())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .onSubmit { send() }
                    .disabled(!allowsSending)
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .foregroundStyle(Color.scAccent)
                    .accessibilityLabel("Send")
                    .disabled(!allowsSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || counterpart == nil)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }

    private func send() {
        guard let counterpart else { return }
        Task { await onSend(counterpart) }
    }
}

private struct MacMessageBubble: View {
    let message: SoundCloudDirectMessage
    let isOutgoing: Bool

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 24) }
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                Text(message.body)
                    .font(.body)
                    .accessibilityLabel("\(isOutgoing ? "You" : (message.sender?.username ?? "Them")): \(message.body)")
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .foregroundStyle(isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .background(
                        isOutgoing ? AnyShapeStyle(Color.scAccent) : AnyShapeStyle(.fill.tertiary),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                if message.createdAt != .distantPast {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if !isOutgoing { Spacer(minLength: 24) }
        }
    }
}

private struct MacMessageAvatar: View {
    let user: SoundCloudMessageParticipant?
    let size: CGFloat

    var body: some View {
        SCArtworkResolver(url: user?.avatarURL, variant: .thumbnail) { image in
            if let image {
                image.resizable().scaledToFill()
            } else {
                SoundingArtworkView(identity: user?.id ?? "SoundCloud", subject: .person)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct MacNewMessageSheet: View {
    @ObservedObject var model: MacMessagesModel
    let initialDraft: String
    let initialRecipient: User?
    let onDone: () -> Void

    @State private var query = ""
    @State private var recipient: User?
    @State private var draft = ""

    private var canSend: Bool {
        recipient != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isSending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("To") {
                    if let recipient {
                        HStack(spacing: 10) {
                            ArtworkThumbnail(
                                url: recipient.avatarURL,
                                identity: recipient.id,
                                size: 38,
                                cornerRadius: 19,
                                isAvailable: true,
                                crownUser: recipient,
                                crownContext: recipient.username
                            )
                            Text(recipient.username).font(.headline)
                            Spacer()
                            Button("Change") { self.recipient = nil }
                                .buttonStyle(.link)
                        }
                    } else {
                        TextField("Find an artist or listener", text: $query)
                            .labelsHidden()
                            .onChange(of: query) { _, value in model.searchUsers(value) }

                        if model.isSearchingUsers { ProgressView().controlSize(.small) }

                        ForEach(model.userResults.prefix(8)) { user in
                            Button {
                                recipient = user
                            } label: {
                                HStack(spacing: 10) {
                                    ArtworkThumbnail(
                                        url: user.avatarURL,
                                        identity: user.id,
                                        size: 34,
                                        cornerRadius: 17,
                                        isAvailable: true,
                                        crownUser: user,
                                        crownContext: user.username
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(user.username).foregroundStyle(.primary)
                                        Text("@\(user.permalink)")
                                            .font(.caption)
                                            .foregroundStyle(MacSecondaryStyle())
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Message") {
                    TextField("Message", text: $draft, axis: .vertical)
                        .labelsHidden()
                        .lineLimit(4...10)
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(MacSecondaryStyle())
                        if model.requiresWebInbox {
                            Button("Continue on SoundCloud") {
                                NSWorkspace.shared.open(SoundCloudAPI.webInboxURL)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        guard let recipient else { return }
                        Task {
                            if await model.startConversation(draft, with: recipient) { onDone() }
                        }
                    }
                    .disabled(!canSend)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            draft = initialDraft
            recipient = initialRecipient
        }
    }
}

extension OutputRouter: IntentPlaybackSink {}
