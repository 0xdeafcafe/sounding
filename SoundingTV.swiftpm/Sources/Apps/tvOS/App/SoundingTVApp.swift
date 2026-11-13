import SwiftUI
import UIKit

@main
struct SoundingTVApp: App {
    @UIApplicationDelegateAdaptor(SoundingTVAppDelegate.self) private var appDelegate
    @StateObject private var runtime: AppRuntime
    @StateObject private var authService = AuthenticationService.shared
    @StateObject private var playerService = PlayerService.shared
    @StateObject private var navigationState = NavigationState()
    @State private var pendingTopShelfRoute: TopShelfStore.Route?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        MemoryRelief.install()
        SignInRequestPublisher.sweepLeftovers()
        NearbyLinkRequestPublisher.sweepLeftovers()
        AccountSignInAnnouncer.shared.install()
        SoundingTips.configure()
        #if DEBUG
        if VisualFixtures.isEnabled {
            SoundCloudCredentialSource.visualFixtureUser = VisualFixtures.currentUser
            Task { await SoundCloudCredentialSource.shared.prepareStoreAtLaunch() }
        }
        #endif
        let account = AccountSystem(
            credentials: AuthenticationService.shared,
            sessionSource: AuthenticationService.shared
        )
        let runtime = AppRuntime(platform: RuntimePlatformServices(
            deviceLabel: "Apple TV",
            account: account,
            lifecycleObserver: PlayerLifecycleObserver.shared,
            nowPlaying: MediaSessionNowPlayingBridge(),
            peerContentSource: CompanionServer.shared,
            prepare: {
                await SoundCloudCredentialSource.shared.establishSessionAtLaunch()
                await SoundCloudCredentialSource.shared.purgeExpiredLockedDataIfNeeded()
            },
            integrations: [
                RuntimeIntegrationAdapter(id: "companion", start: {
                    CompanionServer.shared.startIfPaired()
                }, setActive: { active in
                    CompanionServer.shared.setActive(active)
                }),
                RuntimeIntegrationAdapter(id: "homeLighting", start: {
                    HomeLightingDirector.shared.start()
                }),
            ]
        ))
        _runtime = StateObject(wrappedValue: runtime)

        #if DEBUG
        CrashRecorder.install()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let destination = VisualFixtures.destination ?? TVMockDestination.current {
                    TVVisualFixtureDestinationView(destination: destination)
                } else if TrackMapDemo.isEnabled {
                    TrackMapDemoView()
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
                .environmentObject(authService)
                .environmentObject(runtime)
                .environmentObject(playerService)
                .environmentObject(navigationState)
                .preferredColorScheme(.dark)
                .tint(Color.scAccent)
                .likeFailureAlert()
                .task {
                    #if DEBUG
                    guard !VisualFixtures.isEnabled else { return }
                    #endif
                    await runtime.start()
                }
                #if DEBUG
                .task { await TVMockDestination.autoplayIfRequested() }
                #endif
                .onOpenURL { url in
                    guard let route = TopShelfStore.route(from: url) else { return }
                    openTopShelfRoute(route)
                }
                .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
                    guard isAuthenticated, let route = pendingTopShelfRoute else { return }
                    pendingTopShelfRoute = nil
                    openTopShelfRoute(route)
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    runtime.setActive(phase == .active)
                    if phase == .active, SoundCloudCredentialSource.shared.canRetrySession {
                        Task { await SoundCloudCredentialSource.shared.revalidate() }
                    }
                }
        }
    }

    // MARK: - Top Shelf

    @MainActor
    private func openTopShelfRoute(_ route: TopShelfStore.Route) {
        guard route.needsAccount else {
            pendingTopShelfRoute = nil
            navigationState.homeDestination = nil
            navigationState.selectedTab = .home
            return
        }
        guard authService.isAuthenticated else {
            pendingTopShelfRoute = route
            return
        }
        pendingTopShelfRoute = nil
        Task { await executeTopShelfRoute(route) }
    }

    @MainActor
    private func executeTopShelfRoute(_ route: TopShelfStore.Route) async {
        switch route {
        case .track(let id, let shelf, let position):
            await playTopShelfTrack(id: id, shelf: shelf, position: position)

        case .trackDetails(let id):
            var resolved = await TopShelfTrackResolver.track(id: id)
            if resolved == nil {
                resolved = await fetchOnce({ try await SoundCloudAPI.shared.getTrack(id: id) })
            }
            guard let track = resolved else { return }
            navigationState.selectedTab = .home
            navigationState.homeDestination = .track(track)

        case .playlist(let id, let play):
            guard let playlist = await fetchOnce({ try await SoundCloudAPI.shared.getPlaylist(id: id) }) else { return }
            if play {
                await playPlaylist(playlist)
            } else {
                navigationState.selectedTab = .home
                navigationState.homeDestination = .playlist(playlist)
            }

        case .mix(let urn):
            guard let mix = await fetchOnce({ try await SoundCloudAPI.shared.getSystemPlaylist(urn: urn) }) else { return }
            await waitForLaunchRestore()
            navigationState.selectedTab = .nowPlaying
            await HomeStations.play(mix)

        case .home, .signIn:
            navigationState.homeDestination = nil
            navigationState.selectedTab = .home
        }
    }

    @MainActor
    private func fetchOnce<T>(_ operation: () async throws -> T) async -> T? {
        if let value = try? await operation() { return value }
        try? await Task.sleep(for: .seconds(2))
        return try? await operation()
    }

    @MainActor
    private func waitForLaunchRestore() async {
        for _ in 0..<20 where !playerService.hasResolvedLaunchRestore {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    @MainActor
    private func playPlaylist(_ playlist: Playlist) async {
        let ids = playlist.trackIDs ?? playlist.loadedTracks.map(\.id)
        guard let tracks = await fetchOnce({ try await SoundCloudAPI.shared.getPlaylistTracks(playlist, ids: ids) }),
              let first = tracks.first(where: { $0.streamURL != nil }) else { return }
        await waitForLaunchRestore()
        navigationState.selectedTab = .nowPlaying
        await playerService.play(first, in: tracks)
    }

    @MainActor
    private func playTopShelfTrack(id: String, shelf: String?, position: TimeInterval?) async {
        guard authService.isAuthenticated else { return }
        let shelfIDs = TopShelfTrackResolver.shelfTrackIDs(containing: id, preferring: shelf)
        var context = await TopShelfTrackResolver.tracks(ids: shelfIDs)
        var resolved = context.first { $0.id == id }
        if resolved == nil {
            resolved = await fetchOnce({ try await SoundCloudAPI.shared.getTrack(id: id) })
        }
        guard let track = resolved else { return }

        let missing = shelfIDs.filter { wanted in !context.contains { $0.id == wanted } }
        if !missing.isEmpty, let fetched = try? await SoundCloudAPI.shared.getTracks(ids: missing) {
            let byID = Dictionary((context + fetched).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            context = shelfIDs.compactMap { byID[$0] }
        }
        if !context.contains(where: { $0.id == track.id }) { context = [track] }

        await waitForLaunchRestore()
        navigationState.selectedTab = .nowPlaying
        await playerService.play(track, in: context)
        if let position, position >= 5 {
            playerService.seek(to: position, expectedTrackID: track.id)
        }
    }
}

@MainActor
enum TopShelfTrackResolver {
    static func shelfTrackIDs(containing id: String, preferring kind: String?) -> [String] {
        let sections = TopShelfStore.load()?.sections ?? []
        let playable = sections.filter { $0.kind != TopShelfStore.mixesKind }
        let section = playable.first { $0.kind == kind && $0.entries.contains { $0.trackID == id } }
            ?? playable.first { $0.entries.contains { $0.trackID == id } }
        let ids = section?.entries.map(\.trackID) ?? []
        return ids.isEmpty ? [id] : ids
    }

    static func tracks(ids: [String]) async -> [Track] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        var byID: [String: Track] = [:]
        for track in RecentlyPlayed.shared.tracks where wanted.contains(track.id) {
            byID[track.id] = byID[track.id] ?? track
        }
        if byID.count < wanted.count {
            for track in TopShelfPublisher.cachedRecentTracks() where wanted.contains(track.id) {
                byID[track.id] = byID[track.id] ?? track
            }
        }
        if byID.count < wanted.count {
            let likes = await LikesSyncEngine.shared.indexedLikes(limit: TopShelfStore.maxEntriesPerSection).tracks
            for track in likes where wanted.contains(track.id) {
                byID[track.id] = byID[track.id] ?? track
            }
        }
        return ids.compactMap { byID[$0] }
    }

    static func track(id: String) async -> Track? {
        await tracks(ids: [id]).first
    }
}

final class SoundingTVAppDelegate: NSObject, UIApplicationDelegate {
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

@MainActor
class NavigationState: ObservableObject {
    @Published var selectedTab: Tab {
        didSet { if selectedTab != .nowPlaying { tabBeforeNowPlaying = nil } }
    }
    @Published var tabBeforeNowPlaying: Tab?
    @Published var homeDestination: HomeDestination? = nil
    @Published var pendingSearchQuery: String?
    @Published var isSigningIn = false
    @Published var socialRequest: SocialSection?

    func showProfile() {
        socialRequest = .profile
        selectedTab = .library
    }

    func showNowPlaying() {
        guard selectedTab != .nowPlaying else { return }
        let origin = selectedTab
        selectedTab = .nowPlaying
        tabBeforeNowPlaying = origin
    }

    func leaveNowPlaying() {
        guard selectedTab == .nowPlaying, let origin = tabBeforeNowPlaying else { return }
        selectedTab = origin
    }

    init() {
        #if DEBUG
        let argumentTab = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--tab=") }?
            .replacingOccurrences(of: "--tab=", with: "")
        let raw = argumentTab
            ?? UserDefaults.sounding.string(forKey: "SOUNDING_TV_TAB")
            ?? ProcessInfo.processInfo.environment["SOUNDING_TV_TAB"]
        if let raw, let tab = Tab.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }) {
            self.selectedTab = tab
            return
        }
        if let raw, let section = Self.debugSocialSection(raw) {
            self.selectedTab = .library
            self.socialRequest = section
            return
        }
        #endif
        self.selectedTab = .home
    }

    #if DEBUG
    private static func debugSocialSection(_ raw: String) -> SocialSection? {
        switch raw.lowercased() {
        case "social", "following": return .following
        case "followers": return .followers
        case "profile": return .profile
        case "feed", "activity": return .activity
        default: return nil
        }
    }
    #endif

    enum HomeDestination: Identifiable, Hashable {
        case track(Track)
        case playlist(Playlist)

        var id: String {
            switch self {
            case .track(let track):       return "track.\(track.id)"
            case .playlist(let playlist): return "playlist.\(playlist.id)"
            }
        }
    }

    enum Tab: String, CaseIterable {
        case home       = "Home"
        case search     = "Search"
        case library    = "Library"
        case decks      = "Decks"
        case stations   = "Stations"
        case nowPlaying = "Now Playing"
        case settings   = "Settings"

        var icon: String {
            switch self {
            case .home:       return "house.fill"
            case .search:     return "magnifyingglass"
            case .library:    return "music.note.list"
            case .decks:      return "opticaldisc"
            case .stations:   return "dot.radiowaves.left.and.right"
            case .nowPlaying: return "waveform"
            case .settings:   return "gearshape.fill"
            }
        }
    }
}

#if DEBUG
enum CrashRecorder {
    private static let fileName = "last-crash.txt"

    static var fileURL: URL {
        (FileManager.default
            .soundingDirectory(.documentDirectory) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent(fileName)
    }

    static func note(_ crumb: String) {
        let line = "[\(Date().timeIntervalSince1970)] \(crumb)\n"
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
    }

    static func install() {
        note("--- launch ---")

        NSSetUncaughtExceptionHandler { exception in
            let frames = exception.callStackSymbols.joined(separator: "\n")
            CrashRecorder.note("EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "")\n\(frames)")
        }

        for sig in [SIGILL, SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGFPE] {
            signal(sig) { received in
                let frames = Thread.callStackSymbols.joined(separator: "\n")
                CrashRecorder.note("SIGNAL \(received)\n\(frames)")
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }
}
#endif
