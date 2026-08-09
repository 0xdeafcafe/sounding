import SwiftUI
import UIKit

@main
struct SoundingTVApp: App {
    @UIApplicationDelegateAdaptor(SoundingTVAppDelegate.self) private var appDelegate
    @StateObject private var authService = AuthenticationService.shared
    @StateObject private var playerService = PlayerService.shared
    @StateObject private var polyphony = PolyphonyController.shared
    @StateObject private var navigationState = NavigationState()

    init() {
        #if DEBUG
        SoundCloudCredentialSource.shared.seedDevCredentialIfAvailable()
        #endif
        SoundCloudCredentialSource.shared.refreshFromStore()
        SoundCloudAPI.credentials = AuthenticationService.shared
        SessionSyncTarget.source = AuthenticationService.shared
        PlayerService.installNowPlaying(MediaSessionNowPlayingBridge())
        PlayerService.lifecycleObserver = PlayerLifecycleObserver.shared
        #if DEBUG
        if !VisualFixtures.isEnabled {
            LikesSyncEngine.shared.activate()
        }
        #else
        LikesSyncEngine.shared.activate()
        #endif
        LikesSyncLifecycleCoordinator.shared.install()
        CueSyncForegroundNudge.install()

        #if DEBUG
        CrashRecorder.install()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let destination = VisualFixtures.destination {
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
                .environmentObject(playerService)
                .environmentObject(polyphony)
                .environmentObject(navigationState)
                .tint(.scAccent)
                // tvOS artwork, focus treatments, and playback chrome are designed
                // as one dark, cinema-style surface. Letting the system flip only
                // some controls to light appearance produces illegible mixed states.
                .preferredColorScheme(.dark)
                .task {
                    #if DEBUG
                    guard !VisualFixtures.isEnabled else { return }
                    #endif
                    PlayerService.peerContentSource = CompanionServer.shared
                    await SoundCloudCredentialSource.shared.purgeExpiredLockedDataIfNeeded()
                    CompanionServer.shared.startIfPaired()
                }
                .task {
                    #if DEBUG
                    guard !VisualFixtures.isEnabled else { return }
                    #endif
                    CloudSyncCoordinator.shared.start()
                    await CloudSyncCoordinator.shared.runOnce(
                        analysisStore: AnalysisCache.shared,
                        downloadManifestExportSource: LocalDownloadManifestSource(
                            deviceId: DownloadManifestDeviceIdentity.deviceId(),
                            deviceLabel: "Apple TV"
                        )
                    )
                }
                .onOpenURL { url in
                    switch TopShelfStore.route(from: url) {
                    case .track(let id):
                        Task { await openTrack(id: id) }
                    case .playlist(_, let firstTrackId):
                        if let firstTrackId {
                            Task { await openTrack(id: firstTrackId) }
                        } else {
                            navigationState.selectedTab = .home
                        }
                    case .home, .signIn:
                        navigationState.selectedTab = .home
                    case nil:
                        break
                    }
                }
        }
    }

    @MainActor
    private func openTrack(id: String) async {
        guard authService.isAuthenticated else { return }
        guard let track = try? await SoundCloudAPI.shared.getTrack(id: id) else { return }

        let recents = TopShelfStore.load()?
            .section(titled: TopShelfStore.recentsTitle)?
            .entries ?? []
        let context = (try? await SoundCloudAPI.shared.getTracks(
            ids: recents.map(\.id)
        )) ?? []

        await playerService.play(track, in: context.isEmpty ? [track] : context)
        navigationState.selectedTab = .nowPlaying
    }
}

@MainActor
enum CueSyncForegroundNudge {
    private static var token: NSObjectProtocol?

    static func install() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                CloudSyncCoordinator.shared.requestCueSync()
            }
        }
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
    @Published var selectedTab: Tab

    init() {
        #if DEBUG
        let argumentTab = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--tab=") }?
            .replacingOccurrences(of: "--tab=", with: "")
        let raw = argumentTab
            ?? UserDefaults.standard.string(forKey: "SOUNDING_TV_TAB")
            ?? ProcessInfo.processInfo.environment["SOUNDING_TV_TAB"]
        if let raw, let tab = Tab.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }) {
            self.selectedTab = tab
            return
        }
        #endif
        self.selectedTab = .home
    }

    enum Tab: String, CaseIterable {
        case home       = "Home"
        case following  = "Following"
        case search     = "Search"
        case library    = "Library"
        case nowPlaying = "Now Playing"
        case polyphony  = "Polyphony"
        case companion  = "Companion"
        case profile    = "Profile"
        case settings   = "Settings"

        var icon: String {
            switch self {
            case .home:       return "house.fill"
            case .following:  return "person.2.fill"
            case .search:     return "magnifyingglass"
            case .library:    return "music.note.list"
            case .nowPlaying: return "waveform"
            case .polyphony:  return "point.3.connected.trianglepath.dotted"
            case .companion:  return "iphone.and.arrow.forward"
            case .profile:    return "person.crop.circle.fill"
            case .settings:   return "gearshape.fill"
            }
        }
    }
}

#if DEBUG
enum CrashRecorder {
    private static let fileName = "last-crash.txt"

    static var fileURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
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
