import SwiftUI
import AppKit
import Combine
import os

struct MacRootView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @EnvironmentObject private var midi: DJControllerHub
    private let player = PlayerService.shared
    @ObservedObject private var nowPlayingPresentation = MacNowPlayingPresentation.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection: Section? = Section.debugInitial()
    #if DEBUG
    @State private var debugStateGallery: String?
    #endif

    @State private var sidebarPlayerPane: MacNowPlayingPane?
    @AppStorage("red.forbes.sounding.mac.didLeaveWelcome") private var didLeaveWelcome = false
    @AppStorage(MusicStep.answeredKey) private var didAnswerMusicStep = false
    @AppStorage(MusicStep.pendingKey) private var isMusicStepPending = false
    @State private var forcesMusicStep = MusicStep.isForced

    @State private var isShowingNowPlaying = false
    @State private var isNowPlayingClosing = false
    @State private var isWindowActive = true
    @State private var isShowingSharePlaySignIn = false
    @State private var isShowingActivityInbox = false
    @State private var soundCloudTrafficState: SoundCloudTrafficSafetyState = .ready

    @Environment(\.openSettings) private var openSettings

    @StateObject private var sidebarPlaylists = SidebarPlaylistsModel()
    @ObservedObject private var tvLinking = MacTVLinking.shared

    @StateObject private var searchModel = MacSearchModel()
    @StateObject private var likesModel = MacLibraryModel(mode: .liked)
    @StateObject private var privateSharesModel = MacLibraryModel(mode: .friends)
    @StateObject private var artistsModel = MacArtistsPaneModel()
    @StateObject private var albumsCollection = LibraryCollectionsModel(kind: .albums)
    @StateObject private var artistsCollection = LibraryCollectionsModel(kind: .artists)
    @StateObject private var playlistsModel = MacPlaylistsModel()

    @ObservedObject private var rootSelection = MacRootSelection.shared

    @State private var detailPath = NavigationPath()
    @State private var sectionPaths: [Section: NavigationPath] = [:]
    @State private var forwardPaths: [NavigationPath] = []
    @State private var pathChangeComesFromHistory = false
    @State private var previousPathCount = 0
    @State private var preservesDetailPathForNextSelection = false
    @State private var sectionBackStack: [MacSectionHistoryEntry] = []
    @State private var sectionForwardStack: [MacSectionHistoryEntry] = []
    @State private var windowWidth: CGFloat = 1360
    @State private var sidebarWidth: CGFloat = 220
    @State private var inspectorWidth: CGFloat = 360
    @State private var columnVisibility = MacRootView.initialColumnVisibility
    @State private var columnVisibilityOutsideDecks: NavigationSplitViewVisibility?
    @State private var decksMode: MacDJMode = .perform

    enum Section: Hashable, Identifiable {
        case search
        case home
        case console
        case stations
        case recentlyAdded
        case library
        case likes
        case friendsWithADJ
        case albums
        case artists
        case sets
        case setlists
        case downloads
        case history
        case mixes
        case playlists
        case myPlaylists
        case likedPlaylists
        case playlist(id: String)
        case pinnedFolder(id: String)
        case hardware
        case profile
        case messages
        case followers
        case following
        case activity
        case myTracks
        case account

        var id: Self { self }

        var title: String {
            switch self {
            case .search: return "Search"
            case .home: return "Home"
            case .console: return "Decks"
            case .stations: return "Stations"
            case .recentlyAdded: return "Recently Added"
            case .library: return "Tracks"
            case .likes: return "Likes"
            case .friendsWithADJ: return "Private Shares"
            case .albums: return "Albums"
            case .artists: return "Artists"
            case .sets: return "Sets"
            case .setlists: return "Setlists"
            case .downloads: return "Downloads"
            case .history: return "History"
            case .mixes: return "Mixes"
            case .playlists: return "All Playlists"
            case .myPlaylists: return "My Playlists"
            case .likedPlaylists: return "Liked Playlists"
            case .playlist: return "Playlist"
            case .pinnedFolder: return "Folder"
            case .hardware: return "Hardware"
            case .profile: return "Profile"
            case .messages: return "Messages"
            case .followers: return "Followers"
            case .following: return "Following"
            case .activity: return "Activity"
            case .myTracks: return "Your Tracks"
            case .account: return "Account"
            }
        }

        var symbol: String {
            switch self {
            case .search: return SidebarSymbol.search
            case .home: return SidebarSymbol.home
            case .console: return SidebarSymbol.decks
            case .stations: return SidebarSymbol.stations
            case .recentlyAdded: return SidebarSymbol.recentlyAdded
            case .library: return SidebarSymbol.tracks
            case .likes: return SidebarSymbol.likes
            case .friendsWithADJ: return SidebarSymbol.privateShares
            case .albums: return SidebarSymbol.albums
            case .artists: return SidebarSymbol.artists
            case .sets: return SidebarSymbol.sets
            case .setlists: return SidebarSymbol.setlists
            case .downloads: return SidebarSymbol.downloads
            case .history: return SidebarSymbol.history
            case .mixes: return SidebarSymbol.mixes
            case .playlists: return SidebarSymbol.allPlaylists
            case .myPlaylists: return SidebarSymbol.folder
            case .likedPlaylists: return "heart.text.square"
            case .playlist: return SidebarSymbol.pinnedPlaylist
            case .pinnedFolder: return SidebarSymbol.folder
            case .hardware: return SidebarSymbol.hardware
            case .profile: return "person.crop.circle"
            case .messages: return "bubble.left.and.bubble.right"
            case .followers: return "person.2"
            case .following: return "person.crop.circle.badge.checkmark"
            case .activity: return "bell"
            case .myTracks: return "waveform"
            case .account: return "gearshape"
            }
        }

        var worksSignedOut: Bool {
            switch self {
            case .search, .home, .console, .hardware, .library, .albums, .artists, .setlists, .downloads, .history, .mixes, .account: return true
            default: return false
            }
        }

        #if DEBUG
        static func debugInitial() -> Section {
            debugSection(named: ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_TAB"])
        }

        static func debugSection(named name: String?) -> Section {
            switch name?.lowercased() {
            case "console", "dj", "djconsole": return .console
            case "status", "diagnostics": return .account
            case "hardware": return .hardware
            case "stations": return .stations
            case "search": return .search
            case "home": return .home
            case "stream", "feed": return .home
            case "shares", "privateshares": return .friendsWithADJ
            case "artists": return .artists
            case "albums": return .albums
            case "sets": return .sets
            case "setlists": return .setlists
            case "downloads": return .downloads
            case "history": return .history
            case "recentlyadded", "recent": return .recentlyAdded
            case "activity": return .activity
            case "mixes": return .mixes
            case "folders", "localmusic", "onthismac", "songs": return .library
            case "playlists": return .playlists
            case "profile": return .profile
            case "messages": return .messages
            case "followers": return .followers
            case "following": return .following
            case "tracks": return .myTracks
            case "account": return .account
            case "library": return .library
            case "likes", "liked": return .likes
            default: return .library
            }
        }
        #else
        static func debugInitial() -> Section { .library }
        #endif
    }

    var body: some View {
        ZStack {
            splitView
                .allowsHitTesting(!isShowingNowPlaying)
                .environment(\.macPlaybackAnimationsActive, isWindowActive && !isShowingNowPlaying)

            if isShowingNowPlaying {
                nowPlayingTakeover
                    .environment(\.macPlaybackAnimationsActive, isWindowActive)
            }
        }
            .background(MacWindowActivityReader(isActive: $isWindowActive).frame(width: 0, height: 0))
            .background(MacTrafficLightsKeeper(isActive: hidesWindowChrome).frame(width: 0, height: 0))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: isShowingNowPlaying)
            .downloadRequestPrompts()
            .soundCloudEntitlementAlert()
            .macTrackTrimSheet()
            .trackTempoKeySheet()
            .behindTheTrackHost { MacBehindTheTrackSheet(track: $0) }
            .libraryLinkHost()
            .macIdentifySongHost()
            .sheet(item: tvLinking.confirmationBinding(for: .window)) { confirmation in
                MacSameAccountLinkSheet(confirmation: confirmation, linking: tvLinking, linker: tvLinking.linker)
            }
            .nearbyDeviceCardSheet(tvLinking.card, isEnabled: tvLinking.confirmation == nil)
            .listenTogether { isShowingSharePlaySignIn = true }
            .sheet(isPresented: $isShowingSharePlaySignIn) {
                MacSoundCloudSignInView(peerName: nil, forHandoff: false) {
                    isShowingSharePlaySignIn = false
                }
            }
            .sheet(isPresented: $nowPlayingPresentation.showsAutoMixSetup) {
                AutoDJStartConfigurationView { configuration in
                    player.startDJSession(configuration: configuration, reconfigure: true)
                }
                .frame(minWidth: 560, idealWidth: 580, minHeight: 620, idealHeight: 660)
            }
            .sheet(item: Binding(
                get: { rootSelection.pendingNewPlaylist },
                set: { rootSelection.pendingNewPlaylist = $0 }
            )) { request in
                NewPlaylistSheet(trackIDs: request.trackIDs) { playlist in
                    Task { await sidebarPlaylists.loadIfNeeded(credentials: credentials, forceReload: true) }
                    if request.trackIDs.isEmpty {
                        rootSelection.request(playlist: playlist)
                    }
                }
            }
            .sheet(item: Binding(
                get: { rootSelection.pendingAddToPlaylist },
                set: { rootSelection.pendingAddToPlaylist = $0 }
            )) { track in
                MacAddToPlaylistSheet(track: track) {
                    Task { await sidebarPlaylists.loadIfNeeded(credentials: credentials, forceReload: true) }
                }
            }
            .playlistEditingHost()
            .sheet(item: Binding(
                get: { rootSelection.pendingUSBExport },
                set: { rootSelection.pendingUSBExport = $0 }
            )) { source in
                MacUSBExportSheet(model: MacUSBExportModel(sources: [source])) { rootSelection.pendingUSBExport = nil }
            }
            .sheet(item: Binding(
                get: { rootSelection.pendingSetlist },
                set: { rootSelection.pendingSetlist = $0 }
            )) { track in
                SetlistEditorView(
                    track: track,
                    currentPosition: MacNowPlayingModel.shared.track?.id == track.id ? MacPlaybackTimeline.shared.position() : 0,
                    comments: [],
                    localFileURL: player.localAudioURL(for: track),
                    onSeek: { position in
                        Task {
                            if MacNowPlayingModel.shared.track?.id != track.id {
                                await MacPlayback.play(track, in: [track])
                            }
                            MacPlaybackTimeline.shared.seek(to: position)
                        }
                    },
                    onDownload: { DownloadManager.shared.download(track: track, confirmed: true) },
                    onPlaySearchResult: { result in
                        Task { await MacPlayback.play(result, in: [result]) }
                    }
                )
                .frame(minWidth: 720, minHeight: 680)
            }
            .likeFailureAlert()
            .onReceive(SoundCloudGateway.shared.$trafficSafety.removeDuplicates()) { state in
                soundCloudTrafficState = state
            }
            .task {
                soundCloudTrafficState = SoundCloudGateway.shared.trafficSafety
            }
            .task(id: trafficWaitDeadline) {
                guard let until = trafficWaitDeadline else { return }
                let remaining = until.timeIntervalSinceNow
                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                }
                guard !Task.isCancelled else { return }
                try? SoundCloudAPI.shared.enforceTrafficSafety()
                _ = await credentials.revalidate()
                soundCloudTrafficState = SoundCloudAPI.shared.trafficSafetyState()
            }
    }

    private var hidesWindowChrome: Bool {
        isShowingNowPlaying && !isNowPlayingClosing
    }

    private var trafficWaitDeadline: Date? {
        guard case .waiting(_, let until) = soundCloudTrafficState else { return nil }
        return until
    }

    #if DEBUG
    private func runDebugTour(_ spec: String) async {
        let env = ProcessInfo.processInfo.environment
        let interval = env["SOUNDING_TV_MAC_TOUR_INTERVAL"].flatMap(Double.init) ?? 7
        func emit(_ line: String) {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
        emit("[TOUR] start")
        try? await Task.sleep(for: .seconds(interval))
        let activates = env["SOUNDING_TV_MAC_NO_ACTIVATE"] != "1"
        if activates { NSApp.activate(ignoringOtherApps: true) }
        for rawStep in spec.split(separator: ",") {
            emit("[TOUR] step \(rawStep)")
            let step = rawStep.trimmingCharacters(in: .whitespaces)
            let parts = step.split(separator: "@", maxSplits: 1)
            let name = parts[0].lowercased()
            if parts.count > 1 {
                NSApp.appearance = NSAppearance(named: parts[1] == "dark" ? .darkAqua : .aqua)
            }
            await applyDebugTourStep(name)
            try? await Task.sleep(for: .seconds(interval))
            if activates { NSApp.activate(ignoringOtherApps: true) }
            try? await Task.sleep(for: .seconds(0.5))
            let window = (name.hasPrefix("settings:") ? Self.debugSettingsWindow : nil)
                ?? Self.debugCaptureWindow(for: name)
                ?? NSApp.windows.first { $0.isVisible && Self.isDebugMainWindow($0) }
                ?? NSApp.keyWindow
            emit("[TOUR] ready \(step) window=\(window?.windowNumber ?? 0)")
            try? await Task.sleep(for: .seconds(2))
        }
        emit("[TOUR] done")
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }

    private func installDebugNowPlayingFixture() {
        guard player.currentTrack == nil else { return }
        let env = ProcessInfo.processInfo.environment
        let fixture = env["SOUNDING_TV_MAC_FIXTURE_TRACK"] == "short" ? VisualFixtures.tracks[1] : VisualFixtures.nowPlayingMix
        player.installVisualFixture(
            track: fixture,
            queue: [fixture] + Array(VisualFixtures.tracks.prefix(8)),
            position: 64,
            playingNextCount: env["SOUNDING_TV_FIXTURE_PLAYING_NEXT"].flatMap(Int.init) ?? 0
        )
        player.setQueueSource(PlaybackQueueSource(playlist: VisualFixtures.playlists[0]))
        let position = env["SOUNDING_TV_MAC_FIXTURE_POSITION"].flatMap(Double.init) ?? min(1100, fixture.duration * 0.4)
        MacPlaybackTimeline.shared.adoptFixture(position: position, duration: fixture.duration, isPlaying: true)
    }

    private static func debugPane(_ name: String) -> MacNowPlayingPane? {
        if name.hasSuffix("comments") { return .comments }
        if name.hasSuffix("about") { return .about }
        if name.hasSuffix("queue") { return .queue }
        if name.hasSuffix("tracklist") { return .tracklist }
        if name.hasSuffix("lyrics") { return .lyrics }
        return nil
    }

    private static func isDebugMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    private static var debugHostWindow: NSWindow?

    private static func showDebugHost<V: View>(_ view: V) {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled]
        window.title = ""
        window.setContentSize(host.view.fittingSize)
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.orderFrontRegardless()
        debugHostWindow = window
    }

    private static func showDebugSheet<V: View>(_ view: V, size: NSSize) {
        let host = NSHostingController(rootView: view)
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_APPEARANCE"]?.lowercased() {
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.orderFrontRegardless()
        debugHostWindow = window
    }

    private static func debugCaptureWindow(for step: String) -> NSWindow? {
        switch step {
        case "menubar", "inbox", "signin", "loadbrowser", "rekordbox", "rekordbox-choose":
            return debugHostWindow
        case "activity":
            return NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        default:
            return nil
        }
    }

    private static var debugSettingsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && !isDebugMainWindow($0) && $0.level == .normal }
    }

    private func applyDebugTourStep(_ name: String) async {
        switch name {
        case let value where value.hasPrefix("gallery-"):
            isShowingNowPlaying = false
            detailPath = NavigationPath()
            debugStateGallery = String(value.dropFirst("gallery-".count))
        case "artist", "artist-fixture":
            if name == "artist" { await artistsModel.load(credentials: credentials) }
            let artist = name == "artist" ? artistsModel.artists.first(where: { $0.trackCount > 0 }) : nil
            selection = .playlists
            detailPath = NavigationPath()
            detailPath.append(artist ?? VisualFixtures.artists[0])
        case "playlist", "playlist-fixture":
            selection = .playlists
            detailPath = NavigationPath()
            let first = name == "playlist" ? (sidebarPlaylists.yourItems.first ?? sidebarPlaylists.likedItems.first)?.playlist : nil
            detailPath.append(first ?? VisualFixtures.playlists[0])
        case "album-fixture":
            selection = .playlists
            detailPath = NavigationPath()
            detailPath.append(VisualFixtures.albums[0])
        case "bar", "window", "nowplaying", "nowplaying-queue", "nowplaying-comments", "nowplaying-tracklist", "nowplaying-about", "nowplaying-lyrics":
            installDebugNowPlayingFixture()
            if name == "bar" || name == "window" {
                isShowingNowPlaying = false
            } else if isShowingNowPlaying {
                MacNowPlayingPresentation.shared.pane = Self.debugPane(name) ?? .tracklist
            } else {
                MacNowPlayingPresentation.shared.present(Self.debugPane(name))
            }
        case "queue", "inspector-queue", "inspector-comments", "inspector-tracklist", "inspector-about", "inspector-lyrics":
            installDebugNowPlayingFixture()
            isShowingNowPlaying = false
            sidebarPlayerPane = Self.debugPane(name) ?? .queue
        case "nowplaying-close":
            MacNowPlayingPresentation.shared.requestClose()
        case "hide":
            NSApp.hide(nil)
        case "queue-off", "inspector-off":
            sidebarPlayerPane = nil
        case "play":
            installDebugNowPlayingFixture()
            if !MacPlaybackTimeline.shared.isPlaying { MacPlaybackTimeline.shared.togglePlayPause() }
        case "pause":
            if MacPlaybackTimeline.shared.isPlaying { MacPlaybackTimeline.shared.togglePlayPause() }
        case let value where value.hasPrefix("size:"):
            let parts = value.dropFirst("size:".count).split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && Self.isDebugMainWindow($0) }) {
                var frame = window.frame
                let top = frame.maxY
                frame.size = CGSize(width: parts[0], height: parts[1])
                frame.origin.y = top - parts[1]
                window.setFrame(frame, display: true, animate: false)
            }
        case let value where value.hasPrefix("scroll:"):
            let offset = Double(value.dropFirst("scroll:".count)) ?? 400
            if let window = NSApp.windows.first(where: { $0.isVisible && Self.isDebugMainWindow($0) }) {
                var best: NSScrollView?
                var stack: [NSView] = [window.contentView].compactMap { $0 }
                while let view = stack.popLast() {
                    stack.append(contentsOf: view.subviews)
                    if let scroll = view as? NSScrollView, scroll.frame.width * scroll.frame.height > (best.map { $0.frame.width * $0.frame.height } ?? 0), scroll.frame.width > 500 {
                        best = scroll
                    }
                }
                if let best {
                    best.contentView.scroll(to: NSPoint(x: 0, y: offset))
                    best.reflectScrolledClipView(best.contentView)
                }
            }
        case "menubar":
            Self.showDebugHost(MacMenuBarPlayerView())
        case "inbox":
            Self.showDebugHost(MacActivityInboxPopover())
        case "signin":
            Self.showDebugSheet(
                MacSoundCloudSignInView(peerName: nil, forHandoff: false, onComplete: {}).environmentObject(CompanionClient()),
                size: NSSize(width: 520, height: 640)
            )
        case "loadbrowser":
            Self.showDebugSheet(
                MacLibraryBrowserView(onLoad: { _, _ in }).environmentObject(SoundCloudCredentialSource.shared),
                size: NSSize(width: 760, height: 540)
            )
        case "rekordbox", "rekordbox-choose":
            let store = MacPrepFixtures.makeStore()
            await MacPrepFixtures.seed(store)
            let library = MacPrepFixtures.library(store: store)
            await library.preview(MacPrepFixtures.rekordboxLibrary())
            if name == "rekordbox-choose" { library.bucket = .choose }
            Self.showDebugSheet(
                MacRekordboxImportSheet(library: library, onClose: {}, startsImmediately: false),
                size: NSSize(width: 720, height: 520)
            )
        case "menubar-off", "inbox-off", "signin-off", "loadbrowser-off", "rekordbox-off":
            Self.debugHostWindow?.close()
            Self.debugHostWindow = nil
        case "activity":
            isShowingActivityInbox = true
        case "activity-off":
            isShowingActivityInbox = false
        case let value where value.hasPrefix("settings:"):
            let requested = String(value.dropFirst("settings:".count)).replacingOccurrences(of: " ", with: "")
            let wanted = requested == "diagnostics" ? "advanced" : requested
            if let pane = MacSettingsPane.allCases.first(where: { $0.rawValue.replacingOccurrences(of: " ", with: "").lowercased() == wanted }) {
                MacSettingsNavigation.shared.selection = pane
            }
            openSettings()
        case "settings-off":
            Self.debugSettingsWindow?.close()
        case "loadsheet":
            selection = .console
            try? await Task.sleep(for: .seconds(1))
            MacConsoleController.shared.loadTarget = .a
        case "loadsheet-off":
            MacConsoleController.shared.loadTarget = nil
        default:
            debugStateGallery = nil
            let section = Section.debugSection(named: name)
            isShowingNowPlaying = false
            detailPath = NavigationPath()
            selection = section
        }
    }
    #endif

    private static var initialColumnVisibility: NavigationSplitViewVisibility {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_SIDEBAR"] != nil { return .all }
        #endif
        return .automatic
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebar(selection: $selection, onOpenFolder: openFolder, onOpenPlaylist: openSidebarPlaylist)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebarWidth = $0 }
        } detail: {
            navigationDetail
                .inspector(isPresented: Binding(
                    get: { sidebarPlayerPane != nil },
                    set: { if !$0 { sidebarPlayerPane = nil } }
                )) {
                    MacNowPlayingInspector(pane: Binding(
                        get: { sidebarPlayerPane ?? .queue },
                        set: { sidebarPlayerPane = $0 }
                    ))
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { inspectorWidth = $0 }
                }
            .animation(reduceMotion ? nil : SCContentMotion.settle, value: sidebarPlayerPane)
            .environment(\.macMainSidebarVisible, columnVisibility != .detailOnly)
            .environment(\.macMainInspectorVisible, sidebarPlayerPane != nil)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .onChange(of: selection, initial: true) { _, section in
            if section == .console {
                if sidebarPlayerPane != nil { MacDJPerformModel.shared.isPanelOpen = false }
                #if DEBUG
                if ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_SIDEBAR"] == "all" { return }
                #endif
                guard columnVisibilityOutsideDecks == nil else { return }
                columnVisibilityOutsideDecks = columnVisibility
                withAnimation(reduceMotion ? nil : SCContentMotion.settle) { columnVisibility = .detailOnly }
            } else if let saved = columnVisibilityOutsideDecks {
                columnVisibilityOutsideDecks = nil
                withAnimation(reduceMotion ? nil : SCContentMotion.settle) { columnVisibility = saved }
            }
        }
        .onReceive(MacDJPerformModel.shared.$mode.removeDuplicates()) { decksMode = $0 }
        .onReceive(MacDJPerformModel.shared.$isPanelOpen.removeDuplicates()) { isOpen in
            if isOpen, selection == .console, decksMode == .perform, sidebarPlayerPane != nil { sidebarPlayerPane = nil }
        }
        .onChange(of: sidebarPlayerPane) { _, pane in
            guard pane != nil, selection == .console else { return }
            if decksMode == .perform { MacDJPerformModel.shared.isPanelOpen = false }
        }
        .navigationTitle("Sounding")
        .task {
            if nowPlayingPresentation.presentationRequest > 0 {
                isShowingNowPlaying = true
                nowPlayingPresentation.consumePresentationRequest()
            }
            await sidebarPlaylists.loadIfNeeded(credentials: credentials)
            MacConsoleController.shared.isConsoleActive = (selection == .console)
            #if DEBUG
            switch ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_OPEN"] {
            case "playlist":
                if let first = sidebarPlaylists.yourItems.first {
                    detailPath.append(first.playlist)
                } else if VisualFixtures.isEnabled {
                    detailPath.append(VisualFixtures.playlists[0])
                }
            case "artist":
                if VisualFixtures.isEnabled {
                    detailPath.append(VisualFixtures.artists[0])
                } else if let user = await credentials.waitForCurrentUser() {
                    detailPath.append(user)
                }
            case "settings":
                openSettings()
            default: break
            }
            if ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_SIDEBAR"] == "hidden" {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { columnVisibility = .detailOnly }
                try? await Task.sleep(for: .seconds(1))
                if let spec = ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_WINDOW_SIZE"],
                   let width = spec.lowercased().split(separator: "x").first.flatMap({ Double($0) }),
                   let window = NSApp.windows.first(where: { $0.isVisible && Self.isDebugMainWindow($0) }) {
                    var frame = window.frame
                    frame.size.width = width
                    window.setFrame(frame, display: true)
                }
            }
            if ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_QUEUE"] == "1" {
                sidebarPlayerPane = .queue
            }
            if ["1", "bar"].contains(ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_NOW_PLAYING"]),
               ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_ROOT_SNAPSHOT"] == nil {
                installDebugNowPlayingFixture()
                isShowingNowPlaying = ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_NOW_PLAYING"] == "1"
            }
            #endif
        }
        .task {
            #if DEBUG
            if let tour = ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_TOUR"] {
                await runDebugTour(tour)
            }
            #endif
        }
        .onChange(of: credentials.isSignedOut) { _, isSignedOut in
            if isSignedOut { return }
            didLeaveWelcome = false
            Task { await sidebarPlaylists.loadIfNeeded(credentials: credentials, forceReload: true) }
        }
        .onChange(of: showsWelcome) { wasShowing, isShowing in
            if wasShowing, !isShowing, !didAnswerMusicStep { isMusicStepPending = true }
        }
        .sheet(isPresented: Binding(get: { onboardingStep != nil }, set: { _ in })) {
            MacOnboardingView(
                step: onboardingStep ?? .music,
                onUseWithoutSoundCloud: { didLeaveWelcome = true },
                onMusicAnswered: answerMusicStep
            )
            .interactiveDismissDisabled()
        }
        .onChange(of: selection) { oldSelection, newSelection in
            MacConsoleController.shared.isConsoleActive = (newSelection == .console)
            if preservesDetailPathForNextSelection {
                preservesDetailPathForNextSelection = false
            } else {
                isShowingNowPlaying = false
                if let oldSelection { sectionPaths[oldSelection] = detailPath }
                let restored = newSelection.flatMap { sectionPaths[$0] } ?? NavigationPath()
                if restored != detailPath { detailPath = restored }
                forwardPaths.removeAll()
                sectionBackStack.removeAll()
                sectionForwardStack.removeAll()
            }
        }
        .onReceive(rootSelection.$pendingRedirect.compactMap { $0 }) { section in
            rootSelection.pendingRedirect = nil
            isShowingNowPlaying = false
            if !detailPath.isEmpty { detailPath.removeLast() }
            openSection(section)
        }
        .onReceive(rootSelection.$pending.compactMap { $0 }) { requested in
            rootSelection.pending = nil
            isShowingNowPlaying = false
            if requested == .account {
                MacSettingsNavigation.shared.selection = .account
                openSettings()
                return
            }
            openSection(requested)
        }
        .onReceive(SearchRequestRouter.shared.$pendingQuery.compactMap { $0 }) { query in
            searchModel.search(query)
            SearchRequestRouter.shared.handled(query)
            rootSelection.request(.search)
        }
        .onReceive(MacHistoryRoute.shared.$requests.dropFirst()) { _ in
            MacRootSelection.shared.request(.history)
        }
        .onReceive(rootSelection.$queueToggleRequest.dropFirst()) { _ in
            guard !isShowingNowPlaying else { return }
            sidebarPlayerPane = sidebarPlayerPane == .queue ? nil : .queue
        }
        .onReceive(rootSelection.$pendingArtist.compactMap { $0 }) { user in
            rootSelection.pendingArtist = nil
            if user.id == credentials.currentUser?.id {
                openSection(.profile)
                return
            }
            if Self.isOutsideBrowsing(selection) {
                openSection(.home)
            }
            forwardPaths.removeAll()
            detailPath.append(user)
        }
        .onReceive(rootSelection.$pendingPlaylist.compactMap { $0 }) { playlist in
            rootSelection.pendingPlaylist = nil
            if !playlist.isAlbum, SidebarPins.shared.sidebarPlaylistIDs(in: PlaylistFolderStore.shared).contains(playlist.id) {
                isShowingNowPlaying = false
                openSection(.playlist(id: playlist.id))
                return
            }
            openSection(playlist.isAlbum ? .albums : .playlists)
            forwardPaths.removeAll()
            detailPath.append(playlist)
        }
        .onChange(of: nowPlayingPresentation.presentationRequest) { _, _ in
            guard nowPlayingPresentation.presentationRequest > 0 else { return }
            isShowingNowPlaying = true
            nowPlayingPresentation.consumePresentationRequest()
        }
        .onReceive(NowPlayingReveal.shared.$request.dropFirst()) { _ in
            guard isWindowActive, !isShowingNowPlaying, NowPlayingReveal.shared.consumeSource() != nil else { return }
            nowPlayingPresentation.presentFromCover()
        }
    }

    private func openSidebarPlaylist(_ playlist: Playlist) {
        if sidebarPlaylists.items.contains(where: { $0.id == playlist.id }) || PlaylistFolderStore.shared.playlist(playlist.id) != nil {
            openSection(.playlist(id: playlist.id))
        } else {
            rootSelection.request(playlist: playlist)
        }
    }

    private func openFolder(_ folder: PlaylistFolder) {
        if SidebarPins.shared.pinnedFolderIDs.contains(folder.id) {
            openSection(.pinnedFolder(id: folder.id))
            return
        }
        openSection(.playlists)
        detailPath.append(PlaylistFolderRoute(folderID: folder.id))
    }

    private func openSection(_ section: Section) {
        if section != selection {
            sectionBackStack.append(MacSectionHistoryEntry(section: selection, path: detailPath))
            sectionForwardStack.removeAll()
            if let selection { sectionPaths[selection] = detailPath }
            preservesDetailPathForNextSelection = true
            selection = section
        }
        sectionPaths[section] = nil
        if !detailPath.isEmpty { detailPath = NavigationPath() }
        forwardPaths.removeAll()
    }

    private func restoreSection(_ entry: MacSectionHistoryEntry) {
        if let selection { sectionPaths[selection] = detailPath }
        if entry.section != selection { preservesDetailPathForNextSelection = true }
        if entry.path.count != detailPath.count { pathChangeComesFromHistory = true }
        isShowingNowPlaying = false
        selection = entry.section
        detailPath = entry.path
        forwardPaths.removeAll()
    }

    private static func isOutsideBrowsing(_ section: Section?) -> Bool {
        switch section {
        case .console, .hardware, .account, nil: return true
        default: return false
        }
    }

    private var navigationDetail: some View {
        NavigationStack(path: $detailPath) {
            detailChrome { detailContent }
                .opacity(detailPath.isEmpty ? 1 : 0)
                .allowsHitTesting(detailPath.isEmpty)
                .accessibilityHidden(!detailPath.isEmpty)
                .navigationDestination(for: User.self) { user in
                    if user.id == credentials.currentUser?.id {
                        detailChrome { MacSidebarRedirect(section: .profile) }
                    } else {
                        detailChrome {
                            MacArtistDetailView(user: user)
                                .navigationBarBackButtonHidden(true)
                        }
                    }
                }
                .navigationDestination(for: Playlist.self) { playlist in
                    detailChrome {
                        if playlist.isAlbum {
                            MacAlbumDetailView(album: playlist)
                                .navigationBarBackButtonHidden(true)
                        } else {
                            MacPlaylistDetailView(playlist: playlist)
                                .navigationBarBackButtonHidden(true)
                        }
                    }
                }
                .navigationDestination(for: PlaylistFolderRoute.self) { route in
                    detailChrome {
                        MacPlaylistFolderView(folderID: route.folderID)
                            .navigationBarBackButtonHidden(true)
                    }
                }
                .navigationDestination(for: LikesPlaylistRoute.self) { _ in
                    detailChrome { MacSidebarRedirect(section: .likes) }
                }
                .navigationDestination(for: LibraryCollectionRoute.self) { route in
                    switch route {
                    case .playlist(let playlist):
                        detailChrome {
                            MacCollectionDetailView(playlist: playlist, kind: playlist.isAlbum ? .album : .playlist)
                                .navigationBarBackButtonHidden(true)
                        }
                    case .local(let collection):
                        detailChrome {
                            MacLocalCollectionView(collection: collection)
                                .navigationBarBackButtonHidden(true)
                        }
                    }
                }
        }
        .onChange(of: detailPath.count) { _, count in
            if count > previousPathCount, !pathChangeComesFromHistory {
                forwardPaths.removeAll()
            }
            previousPathCount = count
            pathChangeComesFromHistory = false
        }
        .background(MacVisualEffectBackground(role: .contentBackground).ignoresSafeArea())
        .animation(reduceMotion ? nil : SCContentMotion.settle, value: player.currentTrack?.id)
    }

    private var capsuleWidth: CGFloat {
        let sidebar = columnVisibility == .detailOnly ? 0 : sidebarWidth + MacToolbarMetrics.edge
        let inspector = sidebarPlayerPane == nil ? 0 : inspectorWidth
        let detail = windowWidth - sidebar - inspector
        let windowControls = columnVisibility == .detailOnly ? MacToolbarMetrics.windowControls : 0
        let showsTitle = detailPath.isEmpty
            ? selection != .home && selection != .console
            : MacPageTitleVisibility.shared.isShowingPushedTitle
        let leading = windowControls + MacToolbarMetrics.edge
            + MacToolbarMetrics.button * (hasHistory ? 5 : 3) + MacToolbarMetrics.groupPadding
            + (showsTitle ? MacToolbarMetrics.title + MacToolbarMetrics.gap : 0)
        let trailing = MacToolbarMetrics.edge
            + MacToolbarMetrics.button * CGFloat(3 + pageToolbarItems) + MacToolbarMetrics.groupPadding
            + MacToolbarMetrics.gap + MacToolbarMetrics.button
        let centred = detail - (max(leading, trailing) + MacToolbarMetrics.clearance) * 2
        let offCentre = detail - leading - trailing - MacToolbarMetrics.clearance * 2
        let width = max(centred, min(offCentre, MacToolbarMetrics.capsuleComfortable))
        let floor = min(MacToolbarMetrics.capsuleMin, max(MacToolbarMetrics.capsuleFloor, offCentre))
        return min(MacToolbarMetrics.capsuleMax, max(floor, width))
    }

    private var hasHistory: Bool {
        !detailPath.isEmpty || !forwardPaths.isEmpty || !sectionBackStack.isEmpty || !sectionForwardStack.isEmpty
    }

    private var pageToolbarItems: Int {
        guard detailPath.isEmpty else { return 0 }
        switch selection {
        case .likes: return 3
        case .console: return decksMode == .perform ? 4 : decksMode == .prep ? 3 : 2
        case .library, .friendsWithADJ, .account, nil: return 2
        case .search: return 4
        case .playlists, .myPlaylists, .likedPlaylists: return 2
        case .albums, .followers, .following, .activity: return 1
        default: return 0
        }
    }

    private func detailChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .toolbar {
                if hasHistory {
                    ToolbarItemGroup(placement: .navigation) {
                        Button(action: navigateBack) {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .disabled(detailPath.isEmpty && sectionBackStack.isEmpty)
                        .help("Back")
                        .accessibilityLabel("Back")

                        Button(action: navigateForward) {
                            Label("Forward", systemImage: "chevron.right")
                        }
                        .disabled(forwardPaths.isEmpty && sectionForwardStack.isEmpty)
                        .help("Forward")
                        .accessibilityLabel("Forward")
                    }
                }

                MacPlaybackToolbar(capsuleWidth: capsuleWidth)

                ToolbarItemGroup(placement: .primaryAction) {
                    MacToolbarPlayOn()
                    MacUpNextToggle(selection: $sidebarPlayerPane)

                    MacAccountToolbarMenu(
                        open: { openSection($0) },
                        showActivity: { isShowingActivityInbox = true },
                        openAccountSettings: {
                            MacSettingsNavigation.shared.selection = .account
                            openSettings()
                        }
                    )
                    .popover(isPresented: $isShowingActivityInbox, arrowEdge: .bottom) {
                        MacActivityInboxPopover()
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                trafficStatusBanner
            }
    }

    @ViewBuilder
    private var trafficStatusBanner: some View {
        if case .waiting(_, let until) = soundCloudTrafficState {
            MacTrafficPauseBanner(until: until)
        }
    }

    private func navigateBack() {
        guard !detailPath.isEmpty else {
            guard let entry = sectionBackStack.popLast() else { return }
            sectionForwardStack.append(MacSectionHistoryEntry(section: selection, path: detailPath))
            restoreSection(entry)
            return
        }
        forwardPaths.removeAll { $0.count == detailPath.count }
        forwardPaths.append(detailPath)
        pathChangeComesFromHistory = true
        detailPath.removeLast()
    }

    private func navigateForward() {
        if forwardPaths.isEmpty, let entry = sectionForwardStack.popLast() {
            sectionBackStack.append(MacSectionHistoryEntry(section: selection, path: detailPath))
            restoreSection(entry)
            return
        }
        let nextCount = detailPath.count + 1
        guard let index = forwardPaths.lastIndex(where: { $0.count == nextCount }) else {
            forwardPaths.removeAll { $0.count <= detailPath.count }
            return
        }
        let path = forwardPaths.remove(at: index)
        pathChangeComesFromHistory = true
        detailPath = path
    }

    private var nowPlayingTakeover: some View {
        MacNowPlayingView(
            onClose: {
                isShowingNowPlaying = false
                isNowPlayingClosing = false
            },
            onWillClose: { isNowPlayingClosing = true }
        )
            .ignoresSafeArea()
            .transition(.asymmetric(insertion: .identity, removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(3)
    }

    @ViewBuilder
    private var detailContent: some View {
        #if DEBUG
        if let kind = debugStateGallery {
            MacDebugStateGallery(kind: kind)
        } else {
            detailSwitch
        }
        #else
        detailSwitch
        #endif
    }

    private var onboardingStep: MacOnboardingView.Step? {
        if showsWelcome { return .welcome }
        if forcesMusicStep { return .music }
        if isMusicStepPending, !didAnswerMusicStep, !MusicStep.isSuppressed { return .music }
        return nil
    }

    private var showsWelcome: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["SOUNDING_TV_MAC_ROOT_SNAPSHOT"] != nil { return false }
        if environment["SOUNDING_TV_WELCOME"] == "1" { return !didLeaveWelcome }
        if VisualFixtures.isEnabled || environment["SOUNDING_TV_DISMISS_WELCOME"] == "1" { return false }
        #endif
        return credentials.isSignedOut && !credentials.isEstablishingSessionAtLaunch && !didLeaveWelcome
    }

    private func answerMusicStep(addedFolder: Bool) {
        didAnswerMusicStep = true
        isMusicStepPending = false
        forcesMusicStep = false
        if addedFolder || credentials.isSignedOut { selection = .library }
    }

    @ViewBuilder
    private var detailSwitch: some View {
        if credentials.isSignedOut, let selection, !selection.worksSignedOut {
            SoundCloudSectionGate(selection.signInTopic, isSignedIn: false, symbol: selection.symbol) { EmptyView() }
        } else {
            sectionContent
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case .search: MacSearchView(model: searchModel)
        case .home: MacHomeView(source: HomeStore.shared.forYou, feedModel: HomeStore.shared.following)
        case .console: MacDJWindow()
        case .stations: MacStationsView()
        case .recentlyAdded: MacRecentlyAddedView()
        case .library, .account, nil: MacSongsView(likesModel: likesModel)
        case .likes: MacLibraryPaneView(model: likesModel, pinnedMode: .liked)
        case .friendsWithADJ: MacLibraryPaneView(model: privateSharesModel, pinnedMode: .friends)
        case .albums: MacLibraryCollectionsPane(model: albumsCollection)
        case .artists: MacLibraryCollectionsPane(model: artistsCollection)
        case .sets: MacSetsPane(model: likesModel)
        case .setlists: MacSetsPane(model: likesModel)
        case .downloads: DownloadedMusicView().scrollContentBackground(.hidden)
        case .history: MacHistoryView()
        case .mixes: MixHistoryView()
        case .playlists: MacPlaylistsView(model: playlistsModel)
        case .myPlaylists: MacPlaylistsView(model: playlistsModel, scope: .mine)
        case .likedPlaylists: MacPlaylistsView(model: playlistsModel, scope: .liked)
        case .playlist(let id):
            if let entry = sidebarPlaylists.items.first(where: { $0.id == id }) {
                MacCollectionDetailView(
                    playlist: entry.playlist,
                    kind: entry.playlist.isAlbum ? .album : .playlist
                )
                .id(id)
            } else if let playlist = PlaylistFolderStore.shared.playlist(id) {
                MacCollectionDetailView(playlist: playlist, kind: playlist.isAlbum ? .album : .playlist)
                    .id(id)
            } else {
                MacPlaylistsView(model: playlistsModel)
            }
        case .pinnedFolder(let id):
            MacPlaylistFolderView(folderID: id)
                .id(id)
        case .hardware: HardwarePane()
        case .profile: MacProfileView()
        case .messages: MacMessagesView()
        case .followers: MacConnectionsPage(kind: .followers)
        case .following: MacConnectionsPage(kind: .following)
        case .activity: MacActivityPage()
        case .myTracks: MacOwnProfilePaneView(pane: .tracks)
        }
    }
}

private struct MacSectionHistoryEntry {
    let section: MacRootView.Section?
    let path: NavigationPath
}

private struct MacSidebarRedirect: View {
    let section: MacRootView.Section

    var body: some View {
        Color.clear
            .task { MacRootSelection.shared.redirect(to: section) }
    }
}

private struct MacTrafficPauseBanner: View {
    let until: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(MacSecondaryStyle())
            VStack(alignment: .leading, spacing: 1) {
                Text("SoundCloud is temporarily limiting requests")
                    .font(.subheadline.weight(.semibold))
                Text("Your sign-in is saved. Everything resumes automatically at \(until.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption)
                    .foregroundStyle(MacSecondaryStyle())
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

private struct MacOwnProfilePaneView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    let pane: ArtistDetailPane
    @State private var loadFailed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if credentials.isSessionRejected {
                MacAccountRecoveryEmptyState(sectionName: paneTitle)
            } else if credentials.isSignedOut {
                MacSignedOutEmptyState(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "\(paneTitle) Needs an Account",
                    message: "Sign in on this Mac to see \(paneTitle.lowercased()). Home and Search work without an account.",
                    browsableRoute: .home
                )
            } else if credentials.hasConfirmedAccount, let user = credentials.currentUser {
                MacArtistDetailView(user: user, initialPane: pane)
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Couldn’t Load Your Profile", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check the connection and try again.")
                } actions: {
                    Button("Try Again") { attempt &+= 1 }
                }
            } else {
                MacLoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(paneTitle)
        .background(MacVisualEffectBackground(role: .contentBackground).ignoresSafeArea())
        .task(id: attempt) {
            loadFailed = false
            guard !credentials.isSignedOut,
                  !credentials.isSessionRejected,
                  credentials.currentUser == nil else { return }
            loadFailed = await credentials.waitForCurrentUser() == nil
        }
    }

    private var paneTitle: String {
        switch pane {
        case .followers: return "Followers"
        case .following: return "Following"
        case .tracks: return "Your Tracks"
        default: return "Account"
        }
    }
}

private struct MacAccountToolbarMenu: View {
    let open: (MacRootView.Section) -> Void
    let showActivity: () -> Void
    let openAccountSettings: () -> Void

    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var poller = SoundCloudActivityPoller.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            if let user = credentials.accountUser {
                Section(user.displayName) {
                    Button("Profile", systemImage: MacRootView.Section.profile.symbol) { open(.profile) }
                    Button(activityTitle, systemImage: poller.unreadCount > 0 ? "bell.badge" : "bell") { showActivity() }
                    Button(messagesTitle, systemImage: MacRootView.Section.messages.symbol) { open(.messages) }
                }
                Section {
                    Button(MacRootView.Section.following.title, systemImage: MacRootView.Section.following.symbol) { open(.following) }
                    Button(followersTitle, systemImage: MacRootView.Section.followers.symbol) { open(.followers) }
                    Button(MacRootView.Section.myTracks.title, systemImage: MacRootView.Section.myTracks.symbol) { open(.myTracks) }
                }
                Divider()
                Button("Settings…", systemImage: "gearshape") { openSettings() }
            } else {
                Button("Sign In…", systemImage: "person.crop.circle") { openAccountSettings() }
                Button("Settings…", systemImage: "gearshape") { openSettings() }
            }
        } label: {
            avatar
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Account")
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var avatar: some View {
        Group {
            if let url = credentials.accountUser?.avatarURL {
                ArtworkThumbnail(url: url, identity: credentials.accountUser?.id ?? "", size: 22, cornerRadius: 11)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                    .foregroundStyle(MacSecondaryStyle())
                    .frame(width: 22, height: 22)
            }
        }
        .overlay(alignment: .topTrailing) {
            if poller.unreadCount > 0 {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .offset(x: 2, y: -2)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private var activityTitle: String {
        poller.unreadCount > 0 ? "Activity (\(poller.unreadCount))" : "Activity"
    }

    private var messagesTitle: String {
        let count = poller.unreadCount(kind: .message)
        return count > 0 ? "Messages (\(count))" : "Messages"
    }

    private var followersTitle: String {
        let count = poller.unreadCount(kind: .follower)
        return count > 0 ? "Followers (\(count))" : "Followers"
    }

    private var accessibilityLabel: String {
        guard let user = credentials.accountUser else { return "Account, signed out" }
        return poller.unreadCount > 0 ? "Account, \(user.displayName), \(poller.unreadCount) unread" : "Account, \(user.displayName)"
    }
}

private struct MacActivityInboxPopover: View {
    @ObservedObject private var poller = SoundCloudActivityPoller.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if poller.inbox.isEmpty {
                ContentUnavailableView(
                    "No New Activity",
                    systemImage: "bell",
                    description: Text("New followers, messages and stream activity will appear here.")
                )
            } else {
                MacActivityInboxList(onNavigate: { dismiss() })
            }
        }
        .frame(width: 380, height: 360)
    }
}

@MainActor
final class MacRootSelection: ObservableObject {
    static let shared = MacRootSelection()

    @Published var pending: MacRootView.Section?

    @Published var pendingRedirect: MacRootView.Section?

    @Published var pendingArtist: User?

    @Published var pendingPlaylist: Playlist?

    @Published var pendingSetlist: Track?

    @Published var pendingUSBExport: MacUSBExportSource?

    @Published var pendingNewPlaylist: NewPlaylistRequest?

    @Published var pendingAddToPlaylist: PlaylistTrackRef?

    @Published private(set) var queueToggleRequest = 0

    private init() {}

    func request(_ section: MacRootView.Section) { pending = section }

    func redirect(to section: MacRootView.Section) { pendingRedirect = section }

    func request(artist: User) {
        if artist.id == SoundCloudCredentialSource.shared.currentUser?.id {
            pending = .profile
        } else {
            pendingArtist = artist
        }
    }

    func request(playlist: Playlist) { pendingPlaylist = playlist }

    func request(setlist track: Track) { pendingSetlist = track }

    func request(usbExport source: MacUSBExportSource) { pendingUSBExport = source }

    func requestNewPlaylist(trackIDs: [String] = []) {
        pendingNewPlaylist = NewPlaylistRequest(trackIDs: trackIDs)
    }

    func requestAddToPlaylist(_ track: PlaylistTrackRef) {
        pendingAddToPlaylist = track
    }

    func toggleQueue() { queueToggleRequest &+= 1 }
}

struct LikesPlaylistRoute: Hashable {}

struct NewPlaylistRequest: Identifiable {
    let id = UUID()
    let trackIDs: [String]
}

@MainActor
final class SidebarPlaylistsModel: ObservableObject {
    enum Source: Hashable {
        case yours
        case liked
    }

    struct Entry: Identifiable, Hashable {
        let id: String
        let title: String
        let playlist: Playlist
        let source: Source
    }

    @Published private(set) var items: [Entry] = []
    var yourItems: [Entry] { items.filter { $0.source == .yours } }
    var likedItems: [Entry] { items.filter { $0.source == .liked } }

    let yourPager: Paginator<Playlist>
    let likedPager: Paginator<Playlist>

    private var hasLoaded = false
    private var userID: String?
    private var observations: [AnyCancellable] = []

    init() {
        yourPager = Paginator(source: LibraryDB.playlistSource(.ownPlaylists, pageSize: 200), maxUnattendedPages: 1_000)
        likedPager = Paginator(source: LibraryDB.playlistSource(.likedPlaylists, pageSize: 200), maxUnattendedPages: 1_000)
        observations = [
            yourPager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            likedPager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            yourPager.$items.combineLatest(likedPager.$items).sink { [weak self] yours, liked in
                self?.rebuild(yours: yours, liked: liked)
            },
            LibrarySyncEngine.shared.$revision.dropFirst().sink { [weak self] _ in
                let changed = LibrarySyncEngine.shared.lastChanged
                guard changed.contains(.likedPlaylists) || changed.contains(.ownPlaylists) else { return }
                Task { await self?.reloadAll() }
            }
        ]
    }

    private func reloadAll() async {
        async let yours: Void = yourPager.reload()
        async let liked: Void = likedPager.reload()
        _ = await (yours, liked)
        await TrackCollectionLoader.loadAll(yourPager)
        await TrackCollectionLoader.loadAll(likedPager)
    }

    private func rebuild(yours: [Playlist], liked: [Playlist]) {
        let yourIDs = Set(yours.map(\.id))
        items = yours.map {
            Entry(id: $0.id, title: $0.title, playlist: $0, source: .yours)
        } + liked.filter { !yourIDs.contains($0.id) }.map {
            Entry(id: $0.id, title: $0.title, playlist: $0, source: .liked)
        }
    }

    func countText(_ source: Source) -> String {
        let pager = source == .yours ? yourPager : likedPager
        let count = source == .yours ? yourItems.count : likedItems.count
        return pager.hasMore ? "\(count)+" : "\(count)"
    }

    func loadIfNeeded(credentials: SoundCloudCredentialSource, forceReload: Bool = false) async {
        if hasLoaded, !forceReload { return }
        guard !credentials.isSignedOut, let user = await credentials.waitForCurrentUser() else {
            yourPager.reset()
            likedPager.reset()
            return
        }
        userID = user.id
        await reloadAll()
        if yourPager.firstError == nil, likedPager.firstError == nil, !yourPager.isPaused, !likedPager.isPaused {
            hasLoaded = true
        }
    }
}

private struct MacSidebar: View {
    @Binding var selection: MacRootView.Section?
    var onOpenFolder: (PlaylistFolder) -> Void = { _ in }
    var onOpenPlaylist: (Playlist) -> Void = { MacRootSelection.shared.request(playlist: $0) }

    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var activityPoller = SoundCloudActivityPoller.shared
    @ObservedObject private var pins = SidebarPins.shared
    @ObservedObject private var folderStore = PlaylistFolderStore.shared

    private let primary: [MacRootView.Section] = [
        .search, .home, .console, .stations, .hardware,
    ]

    @State private var isShowingAuthentication = false
    @State private var isReauthentication = false
    @AppStorage("mac.sidebar.section.library") private var isLibraryExpanded = true
    @AppStorage("mac.sidebar.section.playlists") private var arePlaylistsExpanded = true
    @AppStorage("mac.sidebar.section.pinned") private var arePinsExpanded = true
    @AppStorage("mac.sidebar.library.recentlyAdded") private var showsRecentlyAdded = true
    @AppStorage("mac.sidebar.library.albums") private var showsAlbums = true
    @AppStorage("mac.sidebar.library.artists") private var showsArtists = true
    @AppStorage("mac.sidebar.library.sets") private var showsSets = true
    @AppStorage("mac.sidebar.library.downloads") private var showsDownloads = true
    @AppStorage("mac.sidebar.library.history") private var showsHistory = true
    @AppStorage("mac.sidebar.library.privateShares") private var showsPrivateShares = true

    var body: some View {
        sourceList
            .safeAreaInset(edge: .bottom, spacing: 0) { accountFooter }
            .onChange(of: selection) { _, section in
                if section == .messages { activityPoller.markAllRead(kind: .message) }
                if section == .followers { activityPoller.markAllRead(kind: .follower) }
            }
            .sheet(isPresented: $isShowingAuthentication) {
                MacSoundCloudSignInView(
                    peerName: nil,
                    forHandoff: false,
                    isReauthentication: isReauthentication
                ) {
                    isShowingAuthentication = false
                    isReauthentication = false
                }
            }
    }

    private var sourceList: some View {
        List {
            Section {
                ForEach(primary) { navigationRow(for: $0) }
            }

            if !pinnedItems.isEmpty {
                pinnedSection
            }

            Section(isExpanded: $isLibraryExpanded) {
                ForEach(libraryItems) { navigationRow(for: $0) }
            } header: {
                Text("Library")
                    .contextMenu { libraryVisibilityToggles }
                    .accessibilityActions { libraryVisibilityActions }
            }

            playlistsSection
        }
        .listStyle(.sidebar)
        .tint(Color.scAccent)
        .macListKeyboardSelection(ids: selectableSections, selection: $selection)
        .dropDestination(for: PlaylistReference.self) { items, _ in
            withAnimation(.snappy) { pins.acceptDragOut(items.map(\.child)) }
        }
    }

    private var pinnedItems: [SidebarPinItem] {
        pins.items(in: folderStore)
    }

    private var pinnedSection: some View {
        Section(isExpanded: $arePinsExpanded) {
            ForEach(pinnedItems) { item in
                pinnedRow(item)
                    .draggable(pins.dragPayload(item.target))
                    .dropDestination(for: PlaylistReference.self) { items, _ in
                        withAnimation(.snappy) { pins.acceptDrop(items.map(\.child), before: item.target) }
                    }
            }
        } header: {
            Text("Pinned")
                .dropDestination(for: PlaylistReference.self) { items, _ in
                    withAnimation(.snappy) { pins.acceptDrop(items.map(\.child), before: pins.pins.first) }
                }
        }
    }

    @ViewBuilder
    private func pinnedRow(_ item: SidebarPinItem) -> some View {
        switch item {
        case .playlist(let playlist):
            playlistRow(playlist, systemImage: SidebarSymbol.pinnedPlaylist)
        case .folder(let folder):
            MacPinnedFolderRow(folder: folder, selection: $selection) { playlist in
                playlistRow(playlist, systemImage: SidebarSymbol.pinnedPlaylist)
            }
        }
    }

    private func playlistRow(_ playlist: Playlist, systemImage: String) -> some View {
        MacSidebarLabel(playlist.title, systemImage: systemImage)
            .macSelectableRow(MacRootView.Section.playlist(id: playlist.id), selection: Binding(
                get: { selection },
                set: { _ in onOpenPlaylist(playlist) }
            ))
            .contextMenu { MacPlaylistContextMenu(playlist: playlist) }
    }

    private var libraryItems: [MacRootView.Section] {
        var items: [MacRootView.Section] = []
        if showsRecentlyAdded { items.append(.recentlyAdded) }
        items.append(.library)
        if showsAlbums { items.append(.albums) }
        if showsArtists { items.append(.artists) }
        if showsSets { items.append(.sets) }
        if showsDownloads { items.append(.downloads) }
        if showsHistory { items.append(.history) }
        if showsPrivateShares { items.append(.friendsWithADJ) }
        return items
    }

    @ViewBuilder
    private var libraryVisibilityToggles: some View {
        Toggle("Recently Added", isOn: $showsRecentlyAdded)
        Toggle("Albums", isOn: $showsAlbums)
        Toggle("Artists", isOn: $showsArtists)
        Toggle("Sets", isOn: $showsSets)
        Toggle("Downloads", isOn: $showsDownloads)
        Toggle("History", isOn: $showsHistory)
        Toggle("Private Shares", isOn: $showsPrivateShares)
    }

    @ViewBuilder
    private var libraryVisibilityActions: some View {
        visibilityAction("Recently Added", $showsRecentlyAdded)
        visibilityAction("Albums", $showsAlbums)
        visibilityAction("Artists", $showsArtists)
        visibilityAction("Sets", $showsSets)
        visibilityAction("Downloads", $showsDownloads)
        visibilityAction("History", $showsHistory)
        visibilityAction("Private Shares", $showsPrivateShares)
    }

    private func visibilityAction(_ title: String, _ isShown: Binding<Bool>) -> some View {
        Button(isShown.wrappedValue ? "Hide \(title)" : "Show \(title)") { isShown.wrappedValue.toggle() }
    }

    private var selectableSections: [MacRootView.Section] {
        var sections = primary
        if arePinsExpanded {
            for item in pinnedItems {
                switch item {
                case .playlist(let playlist): sections.append(.playlist(id: playlist.id))
                case .folder(let folder): sections.append(.pinnedFolder(id: folder.id))
                }
            }
        }
        if isLibraryExpanded { sections += libraryItems }
        if arePlaylistsExpanded {
            sections += [.playlists, .likes, .mixes]
        }
        return sections
    }

    private var playlistsSection: some View {
        Section(isExpanded: $arePlaylistsExpanded) {
            navigationRow(for: .playlists)
            navigationRow(for: .likes)
            navigationRow(for: .mixes)
            PlaylistFolderSidebarItems(onOpenFolder: onOpenFolder) { playlist in
                playlistRow(playlist, systemImage: playlist.isAlbum ? SidebarSymbol.albums : SidebarSymbol.pinnedPlaylist)
            }
        } header: {
            Text("Playlists")
        }
    }

    private func navigationRow(for section: MacRootView.Section) -> some View {
        MacSidebarLabel(section.title, systemImage: section.symbol)
            .macSelectableRow(section, selection: $selection)
    }

    @ViewBuilder
    private var accountFooter: some View {
        Button {
            if !credentials.hasConfirmedAccount {
                guard credentials.isSignedOut || credentials.isSessionRejected else { return }
                isReauthentication = credentials.isSessionRejected
                isShowingAuthentication = true
            } else {
                openSettings()
            }
        } label: {
            HStack(spacing: 8) {
                accountAvatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(accountTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let accountStatus {
                        Text(accountStatus)
                            .font(.caption)
                            .foregroundStyle(MacSecondaryStyle())
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .macHoverRowHighlight()
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(MacVisualEffectBackground(role: .sidebar))
        .overlay(alignment: .top) { Divider() }
        .accessibilityLabel(accountStatus.map { "\(accountTitle), \($0)" } ?? accountTitle)
        .accessibilityHint(credentials.hasConfirmedAccount ? "Opens Settings" : "Signs in to SoundCloud")
    }

    private var isAwaitingVerification: Bool {
        !credentials.isSignedOut
            && !credentials.hasConfirmedAccount
            && !credentials.isSessionRejected
    }

    private var accountTitle: String {
        if credentials.hasConfirmedAccount {
            return credentials.accountUser?.displayName ?? "SoundCloud"
        }
        if credentials.isReadOnlySession {
            return credentials.canRetrySession ? "SoundCloud Unreachable" : "Reconnect SoundCloud"
        }
        if isAwaitingVerification {
            return credentials.accountUser?.displayName ?? "Finishing Sign-In"
        }
        return "Sign In"
    }

    private var accountStatus: String? {
        if isAwaitingVerification { return "Verification paused" }
        if credentials.isReadOnlySession {
            return credentials.canRetrySession ? "Renewal paused" : "Reconnect to continue"
        }
        if credentials.isSignedOut { return "Browsing as a guest" }
        return nil
    }

    @ViewBuilder
    private var accountAvatar: some View {
        if let url = credentials.accountUser?.avatarURL {
            ArtworkThumbnail(url: url, identity: credentials.accountUser?.id ?? "", size: 28, cornerRadius: 14)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(MacSecondaryStyle())
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }
}

private struct MacPinnedFolderRow<PlaylistRow: View>: View {
    let folder: PlaylistFolder
    @Binding var selection: MacRootView.Section?
    let playlistRow: (Playlist) -> PlaylistRow

    @ObservedObject private var store = PlaylistFolderStore.shared
    @AppStorage private var isExpanded: Bool

    init(folder: PlaylistFolder, selection: Binding<MacRootView.Section?>, @ViewBuilder playlistRow: @escaping (Playlist) -> PlaylistRow) {
        self.folder = folder
        self._selection = selection
        self.playlistRow = playlistRow
        _isExpanded = AppStorage(wrappedValue: true, "mac.sidebar.pinnedFolder.\(folder.id).expanded")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded.animation(.snappy)) {
            ForEach(store.entries(in: folder.id)) { entry in
                if case .playlist(let playlist) = entry {
                    playlistRow(playlist)
                }
            }
        } label: {
            MacSidebarLabel(folder.name, systemImage: SidebarSymbol.folder)
                .macSelectableRow(MacRootView.Section.pinnedFolder(id: folder.id), selection: $selection)
                .contextMenu { PlaylistFolderMenuActions(folder: folder) }
                .playlistFolderDropTarget(folder.id, highlightCorner: 6)
        }
    }
}

private struct HardwarePane: View {
    @EnvironmentObject private var midi: DJControllerHub
    @ObservedObject private var players = DJPlayersController.shared
    @Environment(\.openSettings) private var openSettings

    @State private var lastRaw: ControllerMIDIMessage?
    @State private var rawCount = 0

    var body: some View {
        Form {
            SwiftUI.Section {
                if let error = midi.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if midi.controllers.isEmpty {
                    Text("No controllers connected")
                        .foregroundStyle(MacSecondaryStyle())
                } else {
                    ForEach(midi.controllers) { controller in
                        LabeledContent(controller.name) {
                            Text(controller.profileName ?? "Not Supported")
                                .foregroundStyle(MacSecondaryStyle())
                        }
                    }
                }
            } header: {
                Text("Controllers")
            } footer: {
                Text("Supported controllers work in Decks as soon as you plug them in.")
            }

            SwiftUI.Section {
                LabeledContent("Status", value: playersStatus)
                if players.state == .connected {
                    ForEach(players.visiblePlayers) { player in
                        DJPlayerRow(player: player, compact: true)
                    }
                    Button("Disconnect") { players.disconnect() }
                } else if players.state == .disconnected {
                    Button("Connect") { players.connect() }
                } else if players.state == .priming {
                    Button("Continue") { players.continueAfterPriming() }
                    Button("Not Now") { players.cancelPriming() }
                }
                Button("DJ Players Settings…") {
                    MacSettingsNavigation.shared.selection = .djPlayers
                    openSettings()
                }
            } header: {
                Text("DJ Players")
            } footer: {
                Text("CDJs and XDJs on the same network, over Pro DJ Link.")
            }

            SwiftUI.Section {
                if let lastRaw {
                    LabeledContent("Last Message", value: Self.describe(lastRaw))
                    LabeledContent("Messages", value: "\(rawCount)")
                } else {
                    Text("Move a control on a connected controller")
                        .foregroundStyle(MacSecondaryStyle())
                }
            } header: {
                Text("Monitor")
            }
        }
        .defaultScrollAnchor(.top, for: .alignment)
        .formStyle(.grouped)
        .navigationTitle("Hardware")
        .onReceive(midi.rawMessages) { message in
            lastRaw = message
            rawCount += 1
        }
    }

    private var playersStatus: String {
        switch players.state {
        case .connected:
            let count = players.visiblePlayers.filter(\.isPlayer).count
            return count == 1 ? "1 player" : "\(count) players"
        case .disconnected: return "Not Connected"
        case .priming: return "Needs Local Network Access"
        case .looking: return "Looking for Players"
        case .noPlayers: return "No Players Found"
        case .notAllowed: return "Local Network Is Off"
        case .rekordboxRunning: return "rekordbox Is Open"
        case .portsInUse: return "Another App Is Connected"
        case .noNetwork: return "No Network"
        case .numberTaken(let number): return "Player \(number) Is Taken"
        }
    }

    private static func describe(_ message: ControllerMIDIMessage) -> String {
        let kind: String
        switch message.kind {
        case .noteOn: kind = "Note On"
        case .noteOff: kind = "Note Off"
        case .controlChange: kind = "CC"
        case .pitchBend: kind = "Pitch Bend"
        }
        return String(format: "%@ ch%d #%d = %d", kind, Int(message.channel), Int(message.number), Int(message.value))
    }
}

enum MacSettingsPane: String, CaseIterable, Identifiable {
    case account = "Account"
    case playback = "Playback"
    case autoMix = "Auto Mix"
    case downloads = "Downloads"
    case scout = "Scout"
    case library = "Library"
    case analysis = "Music Analysis"
    case devices = "Devices"
    case djPlayers = "DJ Players"
    case advanced = "Advanced"

    var id: Self { self }

    var icon: SettingsIcon {
        switch self {
        case .account: return .account
        case .scout: return .scout
        case .playback: return .playback
        case .autoMix: return .autoMix
        case .analysis: return .analysis
        case .devices: return .devices
        case .djPlayers: return .djPlayers
        case .library: return .library
        case .downloads: return .downloads
        case .advanced: return .about
        }
    }

    static let sidebarGroups: [[MacSettingsPane]] = [
        [.account, .scout],
        [.playback, .autoMix, .analysis],
        [.devices, .djPlayers],
        [.library, .downloads, .advanced]
    ]
}

@MainActor
final class MacSettingsNavigation: ObservableObject {
    static let shared = MacSettingsNavigation()
    @Published var selection: MacSettingsPane = .account
    private init() {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_SETTINGS_PANE"],
           let pane = MacSettingsPane(rawValue: raw) {
            selection = pane
        }
        #endif
    }
}

struct MacSettingsView: View {
    @ObservedObject private var navigation = MacSettingsNavigation.shared

    private var selection: Binding<MacSettingsPane?> {
        Binding(
            get: { navigation.selection },
            set: { if let pane = $0 { navigation.selection = pane } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(Array(MacSettingsPane.sidebarGroups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { pane in
                            SettingsIconLabel(pane.rawValue, icon: pane.icon)
                                .macSelectableRow(pane, selection: selection)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .macListKeyboardSelection(ids: MacSettingsPane.sidebarGroups.flatMap { $0 }, selection: selection)
            .navigationSplitViewColumnWidth(min: 224, ideal: 232, max: 264)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(for: navigation.selection)
                .id(navigation.selection)
                .navigationTitle(navigation.selection.rawValue)
        }
        .tint(Color.scAccent)
        .background(MacWindowChrome().frame(width: 0, height: 0))
        .frame(width: 880, height: 600)
    }

    @ViewBuilder
    private func detail(for pane: MacSettingsPane) -> some View {
        switch pane {
        case .account: MacSettingsAccountTab()
        case .playback: MacSettingsAudioTab()
        case .autoMix: AutoMixMovesView()
        case .downloads: MacSettingsDownloadsTab()
        case .scout: ScoutSettingsView()
        case .library: MacLibrarySettingsTab()
        case .devices: MacDevicesSettingsTab()
        case .analysis: MacSettingsAnalysisTab()
        case .djPlayers: DJPlayersSettingsTab()
        case .advanced: MacSettingsAdvancedTab()
        }
    }
}

#if DEBUG
extension MacRootView {
    @MainActor
    fileprivate static func snapshotRoot(to path: String) async {
        let env = ProcessInfo.processInfo.environment
        let width = env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_WIDTH"].flatMap(Double.init) ?? 1040
        let height = env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_HEIGHT"].flatMap(Double.init) ?? 692
        let capturesNowPlaying = env["SOUNDING_TV_MAC_NOW_PLAYING"] == "1"
        if VisualFixtures.isEnabled {
            SoundCloudCredentialSource.visualFixtureUser = VisualFixtures.currentUser
            await SoundCloudCredentialSource.shared.prepareStoreAtLaunch()
        }

        if capturesNowPlaying || env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "queue-panel" {
            let fixture = VisualFixtures.tracks[0]
            PlayerService.shared.installVisualFixture(
                track: fixture,
                queue: [fixture] + Array(VisualFixtures.tracks.prefix(8)),
                position: 64,
                playingNextCount: env["SOUNDING_TV_FIXTURE_PLAYING_NEXT"].flatMap(Int.init) ?? 0
            )
            PlayerService.shared.setQueueSource(PlaybackQueueSource(playlist: VisualFixtures.playlists[0]))
        }

        if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "now-playing-full" {
            let fixture = env["SOUNDING_TV_MAC_FIXTURE_TRACK"] == "short" ? VisualFixtures.tracks[0] : VisualFixtures.nowPlayingMix
            PlayerService.shared.installVisualFixture(
                track: fixture,
                queue: [fixture] + Array(VisualFixtures.tracks.prefix(8)),
                position: 64,
                playingNextCount: 0
            )
            let position = env["SOUNDING_TV_MAC_FIXTURE_POSITION"].flatMap(Double.init) ?? fixture.duration * 0.4
            MacPlaybackTimeline.shared.adoptFixture(position: position, duration: fixture.duration, isPlaying: true)
        }

        let section = Section.debugInitial()
        let harness = Group {
            if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "queue-panel" {
                HStack(spacing: 0) {
                    Spacer()
                    MacNowPlayingPanes(pane: .constant(.queue), surface: .inspector).frame(width: 360)
                }
                .frame(maxHeight: .infinity)
                .environment(\.outputRouter, MacPlaybackTarget.router ?? OutputRouter(client: CompanionClient()))
                .environment(\.colorScheme, env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            } else if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "now-playing-full" {
                MacNowPlayingView(onClose: {}).background(Color.black)
                    .environment(\.outputRouter, MacPlaybackTarget.router ?? OutputRouter(client: CompanionClient()))
            } else if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "dj-mixer" {
                DJMixerHarness.view(state: env["SOUNDING_TV_DJ_MIXER_STATE"])
            } else if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "connect" {
                MacConnectView(router: MacPlaybackTarget.router ?? OutputRouter(client: CompanionClient()), onDone: {})
                    .environment(\.colorScheme, env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            } else if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "network-activity" {
                let _ = NetworkActivityFixture.isRequested ? NetworkActivityFixture.seed() : ()
                MacNetworkActivitySheet()
                    .environment(\.colorScheme, env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            } else if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "track-trim" {
                let track = TrackTrimFixture.prepare()
                TrackTrimEditor(track: track, initial: TrackTrimFixture.draft(for: track))
                    .frame(width: 520, height: 560)
                    .environment(\.colorScheme, env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            } else if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "autodj-start" {
                AutoDJStartConfigurationView(onStart: { _ in }, onCancel: {})
                    .frame(width: 700, height: 760)
                    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            } else if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "sidebar" {
                HStack(spacing: 0) {
                    MacSidebar(selection: .constant(section))
                        .frame(width: 240)
                    Divider()
                    Spacer()
                }
                .environmentObject(SoundCloudCredentialSource.shared)
                .environment(\.colorScheme, env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light)
            } else if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "welcome" || env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "music-step" {
                MacOnboardingView(
                    step: env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "welcome" ? .welcome : .music,
                    onUseWithoutSoundCloud: {},
                    onMusicAnswered: { _ in }
                )
                .environment(\.colorScheme, env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            } else if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "signin-prompt" {
                SoundCloudSectionGate(section.signInTopic, isSignedIn: false, symbol: section.symbol) { EmptyView() }
                    .frame(width: 760, height: 520)
                    .environmentObject(SoundCloudCredentialSource.shared)
                    .environment(\.colorScheme, env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            } else if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET"] == "welcome-hero" {
                MacWelcomeHero {}
                    .padding(20)
                    .environment(\.colorScheme, env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light)
                    .background(env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"] == "dark" ? Color.black : Color.white)
            } else if capturesNowPlaying {
                MacNowPlayingView(onClose: {})
                    .environment(\.outputRouter, MacPlaybackTarget.router)
            } else {
                switch section {
                case .search: MacSearchView(model: MacSearchModel()).environmentObject(SoundCloudCredentialSource.shared)
                case .friendsWithADJ: MacLibraryPaneView(model: MacLibraryModel(mode: .friends), pinnedMode: .friends).environmentObject(SoundCloudCredentialSource.shared)
                case .albums: MacLibraryCollectionsPane(model: LibraryCollectionsModel(kind: .albums))
                case .artists: MacLibraryCollectionsPane(model: LibraryCollectionsModel(kind: .artists))
                case .sets: MacSetsPane(model: MacLibraryModel(mode: .liked)).environmentObject(SoundCloudCredentialSource.shared)
                case .mixes: MixHistoryHarness.staticView(route: env["SOUNDING_TV_MIXES_ROUTE"], width: width)
                        .environment(\.colorScheme, env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light)
                case .myPlaylists: MacPlaylistsView(model: MacPlaylistsModel(), scope: .mine).environmentObject(SoundCloudCredentialSource.shared)
                case .likedPlaylists: MacPlaylistsView(model: MacPlaylistsModel(), scope: .liked).environmentObject(SoundCloudCredentialSource.shared)
                case .hardware: HardwarePane().environmentObject(DJControllerHub.shared)
                case .profile: MacProfileView().environmentObject(SoundCloudCredentialSource.shared)
                case .messages: MacMessagesView().environmentObject(SoundCloudCredentialSource.shared)
                case .followers: MacConnectionsPage(kind: .followers).environmentObject(SoundCloudCredentialSource.shared)
                case .following: MacConnectionsPage(kind: .following).environmentObject(SoundCloudCredentialSource.shared)
                case .activity: MacActivityPage().environmentObject(SoundCloudCredentialSource.shared)
                case .setlists: SavedSetlistsLibraryView()
                case .downloads: DownloadedMusicView()
                case .myTracks: MacOwnProfilePaneView(pane: .tracks).environmentObject(SoundCloudCredentialSource.shared)
                case .console: MacDJWindow().environmentObject(SoundCloudCredentialSource.shared)
                case .library: MacSongsView(likesModel: MacLibraryModel(mode: .liked)).environmentObject(SoundCloudCredentialSource.shared)
                case .likes: MacLibraryPaneView(model: MacLibraryModel(mode: .liked), pinnedMode: .liked).environmentObject(SoundCloudCredentialSource.shared)
                case .home: MacHomeView(source: HomeStore.shared.forYou, feedModel: HomeStore.shared.following).environmentObject(SoundCloudCredentialSource.shared)
                case .playlists: MacPlaylistsView(model: MacPlaylistsModel()).environmentObject(SoundCloudCredentialSource.shared)
                case .account where env["SOUNDING_TV_MAC_SETTINGS_PANE"] == MacSettingsPane.autoMix.rawValue:
                    AutoMixMovesView()
                        .environment(\.colorScheme, env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light)
                case .account where env["SOUNDING_TV_MAC_SETTINGS_PANE"] == MacSettingsPane.devices.rawValue:
                    MacDevicesSettingsTab()
                        .environmentObject(SoundCloudCredentialSource.shared)
                        .environmentObject(CompanionClient())
                case .account:
                    MacSettingsView()
                        .environment(\.colorScheme, env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light)
                        .environmentObject(SoundCloudCredentialSource.shared)
                        .environmentObject(CompanionClient())
                default: MacDJWindow().environmentObject(SoundCloudCredentialSource.shared)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())

        let djSheet = env["SOUNDING_TV_MAC_DJ_SHEET"]?.lowercased()
        let capturesFullWindow = env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_FULL"] == "1"
        let isDecks = section == .console || djSheet != nil || env["SOUNDING_TV_MAC_DJ_PAGE"] != nil
        let scheme = env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SCHEME"]?.lowercased() ?? (isDecks ? "dark" : "light")
        let appearance: NSAppearance.Name = scheme == "dark" ? .darkAqua : .aqua

        let content: AnyView
        var size = NSSize(width: width, height: height)
        if let djSheet {
            let sheet = await Self.debugDJSheet(djSheet)
            content = AnyView(
                sheet.view
                    .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
            if env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_WIDTH"] == nil, env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_HEIGHT"] == nil {
                size = sheet.size
            }
        } else if capturesFullWindow {
            content = AnyView(
                MacRootView()
                    .environmentObject(SoundCloudCredentialSource.shared)
                    .environmentObject(DJControllerHub.shared)
                    .environmentObject(CompanionClient())
                    .environment(\.outputRouter, MacPlaybackTarget.router)
            )
        } else {
            content = AnyView(harness)
        }

        guard let png = await Self.hostedSnapshot(
            content,
            size: size,
            titled: capturesFullWindow && djSheet == nil,
            appearance: appearance,
            delay: env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5
        ) else {
            Log.ui.error("ROOT_SNAPSHOT FAIL: could not rasterise view")
            exit(1)
        }

        if path == "-" {
            print("[ROOT_SNAPSHOT_B64]\(png.base64EncodedString())")
            fflush(stdout)
            Log.ui.info("ROOT_SNAPSHOT emitted \(png.count, privacy: .public) bytes at \(Int(width), privacy: .public)x\(Int(height), privacy: .public)")
            exit(0)
        }

        do {
            try png.write(to: URL(fileURLWithPath: path))
            Log.ui.info("ROOT_SNAPSHOT wrote \(path, privacy: .public) at \(Int(width), privacy: .public)x\(Int(height), privacy: .public)")
        } catch {
            Log.ui.error("ROOT_SNAPSHOT FAIL writing file: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
        exit(0)
    }

    @MainActor
    fileprivate static func hostedSnapshot(
        _ view: AnyView,
        size: NSSize,
        titled: Bool,
        appearance: NSAppearance.Name,
        delay: Double
    ) async -> Data? {
        let controller = NSHostingController(rootView: AnyView(
            view
                .frame(width: size.width, height: size.height)
                .environment(\.controlActiveState, .key)
        ))
        controller.sizingOptions = []
        if titled { controller.sceneBridgingOptions = [.toolbars, .title] }
        let style: NSWindow.StyleMask = titled
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.borderless]
        let window = MacSnapshotWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        if titled { window.toolbarStyle = .unified }
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()

        let target: NSView = titled ? (window.contentView?.superview ?? controller.view) : controller.view
        for _ in 0..<4 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(60))
            target.layoutSubtreeIfNeeded()
        }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        target.layoutSubtreeIfNeeded()
        target.displayIfNeeded()

        let bounds = target.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = target.bitmapImageRepForCachingDisplay(in: bounds) else {
            window.close()
            return nil
        }
        target.cacheDisplay(in: bounds, to: rep)
        window.close()
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor
    fileprivate static func debugDJSheet(_ name: String) async -> (view: AnyView, size: NSSize) {
        let library = MacRekordboxLibrary.shared
        switch name {
        case "export":
            let draft = await library.prepareExport()
            return (AnyView(MacRekordboxExportSheet(library: library, draft: draft, onClose: {})), NSSize(width: 460, height: 440))
        case "analysis", "share":
            return (AnyView(MacRekordboxShareSheet(model: MacRekordboxShareImport(library: library), onClose: {})), NSSize(width: 520, height: 560))
        case "usb":
            return (AnyView(MacUSBExportSheet(model: MacUSBExportModel(store: library.store)) {}), NSSize(width: 520, height: 720))
        case "players":
            return (AnyView(DJPlayersDecksPanel(openSettings: {})), NSSize(width: 420, height: 460))
        case "players-settings":
            return (AnyView(DJPlayersSettingsTab().frame(width: 680, height: 560)), NSSize(width: 680, height: 560))
        case "decks-view":
            return (AnyView(MacDJDecksViewPopover(model: .shared, console: .shared)), NSSize(width: 340, height: 560))
        case "load":
            return (
                AnyView(MacLibraryBrowserView(targetDeck: .a) { _, _ in }.environmentObject(SoundCloudCredentialSource.shared)),
                NSSize(width: 760, height: 540)
            )
        case "folder":
            let model = MacRekordboxFolderImport(url: URL(fileURLWithPath: NSTemporaryDirectory()), library: library)
            model.phase = .needsExport
            return (AnyView(MacRekordboxFolderSheet(model: model) {}), NSSize(width: MacRekordboxFolderSheet.width, height: MacRekordboxFolderSheet.height))
        case "library-settings":
            return (AnyView(MacLibrarySettingsTab().frame(width: 680, height: 600)), NSSize(width: 680, height: 600))
        default:
            return (AnyView(MacRekordboxImportSheet(library: library, onClose: {})), NSSize(width: 720, height: 520))
        }
    }
}

private final class MacSnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@_cdecl("soundingtv_mac_tour_bootstrap")
private func soundingtv_mac_tour_bootstrap() {
    guard ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_TOUR"] != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        let hasMainWindow = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
        guard !hasMainWindow else { return }
        FileHandle.standardOutput.write(Data("[TOUR] reopening main window\n".utf8))
        _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
    }
}

@section("__DATA,__mod_init_func")
@used
private let soundingtv_mac_tour_bootstrap_ptr: @convention(c) () -> Void = soundingtv_mac_tour_bootstrap

@_cdecl("soundingtv_mac_root_snapshot_bootstrap")
private func soundingtv_mac_root_snapshot_bootstrap() {
    guard let path = ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_ROOT_SNAPSHOT"] else { return }
    DispatchQueue.main.async {
        Task { @MainActor in
            await MacRootView.snapshotRoot(to: path)
        }
    }
}

@section("__DATA,__mod_init_func")
@used
private let soundingtv_mac_root_snapshot_bootstrap_ptr: @convention(c) () -> Void = soundingtv_mac_root_snapshot_bootstrap

#if DEBUG
@MainActor
private func soundingtv_mac_splitview_probe(to path: String) {
    var lines: [String] = []
    for window in NSApp.windows {
        guard window.isVisible else { continue }
        lines.append("window '\(window.title)' frame=\(window.frame)")
        func walk(_ view: NSView, depth: Int) {
            if let split = view as? NSSplitView {
                lines.append("\(String(repeating: "  ", count: depth))NSSplitView frame=\(split.frame) vertical=\(split.isVertical)")
                for (i, arranged) in split.arrangedSubviews.enumerated() {
                    lines.append("\(String(repeating: "  ", count: depth + 1))pane[\(i)] frame=\(arranged.frame)")
                }
            }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        if let contentView = window.contentView { walk(contentView, depth: 0) }
    }
    let text = lines.isEmpty ? "no visible windows / no NSSplitView found" : lines.joined(separator: "\n")
    if path == "-" {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    } else {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

@_cdecl("soundingtv_mac_splitview_probe_bootstrap")
private func soundingtv_mac_splitview_probe_bootstrap() {
    guard let path = ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_SPLITVIEW_PROBE"] else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        soundingtv_mac_splitview_probe(to: path)
    }
}

@section("__DATA,__mod_init_func")
@used
private let soundingtv_mac_splitview_probe_bootstrap_ptr: @convention(c) () -> Void = soundingtv_mac_splitview_probe_bootstrap
#endif
#endif

#if DEBUG
private struct MacDebugStateGallery: View {
    let kind: String

    var body: some View {
        switch kind {
        case "loading":
            MacViewportScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    title
                    MacLoadingView()
                }
            }
            .navigationTitle("Home")
        case "empty":
            MacViewportScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    title
                    ContentUnavailableView(
                        "No Tracks",
                        systemImage: "music.note.list",
                        description: Text("Tracks you add will appear here.")
                    )
                    .macFillsPane()
                }
            }
            .navigationTitle("Playlist")
        case "empty-root":
            ContentUnavailableView(
                "No Liked Tracks",
                systemImage: "music.note.list",
                description: Text("Tracks you like on SoundCloud show up here.")
            )
            .macFillsPane()
        default:
            MacLoadingView("Searching SoundCloud…")
        }
    }

    private var title: some View {
        Text("Home")
            .font(.largeTitle.weight(.bold))
            .padding(.horizontal, 20)
            .padding(.top, 22)
    }
}
#endif
