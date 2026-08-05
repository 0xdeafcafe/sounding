import SwiftUI
import UIKit

@main
struct SoundingTViOSApp: App {
    @UIApplicationDelegateAdaptor(SoundingTViOSAppDelegate.self) private var appDelegate
    @State private var link: LinkRequest?
    @State private var authHandoffRequest: AuthHandoffRequest?
    @State private var authErrorMessage: String?

    @StateObject private var queueClient: CompanionClient

    @StateObject private var playerService = PlayerService.shared

    @StateObject private var downloadManager = DownloadManager.shared

    @StateObject private var coordinator: PhonePlaybackCoordinator

    @StateObject private var polyphony = PolyphonyController.shared

    @Environment(\.scenePhase) private var scenePhase

    init() {
        SoundCloudCredentialSource.install()
        SoundCloudCredentialSource.shared.sideEffects = .init(
            requestSessionSync: { CloudSyncCoordinator.shared.requestSessionSync() },
            wipeLocalIndexes: {
                LikesSyncEngine.shared.handleSignOut()
                await LibraryCache.shared.clearAll()
            },
            clearWebSession: { await AuthWebSession.clear() }
        )
        SessionSyncTarget.source = SoundCloudCredentialSource.shared
        PlayerService.lifecycleObserver = PlayerLifecycleObserver.shared
        LikesSyncEngine.shared.activate()
        LikesSyncLifecycleCoordinator.shared.install()
        Task { await SoundCloudCredentialSource.shared.purgeExpiredLockedDataIfNeeded() }

        let client = CompanionClient()
        _queueClient = StateObject(wrappedValue: client)
        _coordinator = StateObject(wrappedValue: PhonePlaybackCoordinator(client: client))
    }

    private var startsInQueue: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SOUNDING_TV_QUEUE"] == "1"
        #else
        return false
        #endif
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

    private var startsInListeningRoom: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SOUNDING_TV_POLYPHONY"] != nil
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

    var body: some Scene {
        WindowGroup {
            Group {
                if startsInQueue {
                    NavigationStack { QueueManagerView() }
                } else if startsInDJ {
                    NavigationStack { DJControlView(client: queueClient) }
                } else if startsInCues {
                    cueDemo
                } else if startsInSignIn {
                    NavigationStack {
                        SoundCloudLoginView.standalone { }
                    }
                } else if startsInListeningRoom {
                    NavigationStack { PolyphonyView() }
                } else {
                    PhoneRootView()
                }
            }
            .tint(.scAccent)
            .environmentObject(queueClient)
            .environmentObject(playerService)
            .environmentObject(coordinator)
            .environmentObject(polyphony)
            .task {
                await SoundCloudCredentialSource.shared.refreshIfNeededAtLaunch()
            }
            .task {
                for await notification in NotificationCenter.default.notifications(named: .companionClientAuthHandoffRequest, object: queueClient) {
                    guard let userInfo = notification.userInfo,
                          let sessionId = userInfo[CompanionClientAuthHandoffRequestSessionIdKey] as? String,
                          let secretBase64 = userInfo[CompanionClientAuthHandoffRequestSecretKey] as? String,
                          let secret = Data(base64Encoded: secretBase64) else { continue }
                    let peerClass = userInfo["peerClass"] as? DeviceClass ?? .tv
                    let peerName = userInfo["peerName"] as? String
                    authHandoffRequest = AuthHandoffRequest(
                        sessionId: sessionId,
                        secret: secret,
                        peerName: peerName,
                        peerClass: peerClass
                    )
                }
            }
            .task { PlayerService.remoteOutput = queueClient }
            .task { PlayerService.peerContentSource = queueClient }
            .onReceive(NotificationCenter.default.publisher(for: .soundCloudAuthenticationChanged)) { _ in
                guard SoundCloudCredentialSource.shared.accessToken == nil else { return }
                playerService.clearQueue()
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
            .task {
                let watchLink = PhoneWatchLinkServer.shared
                watchLink.attach(coordinator: coordinator)
                watchLink.activate()
                watchLink.publish()
            }
            .task { SpotlightIndexingService.shared.start(player: playerService) }
            .task {
                CloudSyncCoordinator.shared.start()
                await CloudSyncCoordinator.shared.runOnce(
                    analysisStore: AnalysisCache.shared,
                    downloadManifestExportSource: LocalDownloadManifestSource(
                        deviceId: DownloadManifestDeviceIdentity.deviceId(),
                        deviceLabel: "iPhone"
                    )
                )
            }
            .fullScreenCover(item: $link) { request in
                NavigationStack {
                    SoundCloudLoginView(
                        sessionId: request.sessionId,
                        sessionSecret: request.secret,
                        onComplete: { link = nil }
                    )
                }
            }
            .fullScreenCover(item: $authHandoffRequest) { request in
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
                    get: { authErrorMessage != nil },
                    set: { if !$0 { authErrorMessage = nil } }
                ),
                presenting: authErrorMessage
            ) { _ in
                Button("OK", role: .cancel) { authErrorMessage = nil }
            } message: { message in
                Text(message)
            }
            .onOpenURL { url in
                handleAuthURL(url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL {
                    handleAuthURL(url)
                }
            }
            .onContinueUserActivity(HandoffActivityType.link) { activity in
                guard let raw = activity.userInfo?["pairingURL"] as? String,
                      let url = URL(string: raw) else { return }
                handleAuthURL(url)
            }
            .onContinueUserActivity(HandoffActivityType.nowPlaying) { _ in }
            #if DEBUG
            .task {
                guard link == nil,
                      let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_PAIRING_URL"],
                      let url = URL(string: raw) else { return }
                handleAuthURL(url)
            }
            #endif
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    queueClient.connect()
                    CloudSyncCoordinator.shared.requestCueSync()
                case .background: queueClient.disconnect()
                default:          break
                }
            }
        }
    }

    private func handleAuthURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            authErrorMessage = "That sign-in link isn't valid. Scan the QR code on your Apple TV again."
            return
        }

        guard let session = queryItems.first(where: { $0.name == "session" })?.value,
              let secretBase64 = queryItems.first(where: { $0.name == "secret" })?.value,
              let secret = SessionCredentials.decodeSecret(secretBase64) else {
            authErrorMessage = "That sign-in link is missing its session details. Scan the QR code on your Apple TV again."
            return
        }

        authErrorMessage = nil
        link = LinkRequest(sessionId: session, secret: secret)
    }
}

final class SoundingTViOSAppDelegate: NSObject, UIApplicationDelegate {
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
