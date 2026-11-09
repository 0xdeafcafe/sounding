import SwiftUI
import Foundation
import UIKit

struct RootView: View {
    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var playerService: PlayerService
    @EnvironmentObject var navigationState: NavigationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("red.forbes.sounding.didSeeTVWelcome") private var didSeeWelcome = false
    @AppStorage("red.forbes.sounding.tv.usesDeviceMusic") private var usesDeviceMusic = false
    @ObservedObject private var remoteMusic = RemoteLocalMusic.shared
    @AppStorage("red.forbes.sounding.tv.didAnswerMusicStep") private var didAnswerMusicStep = false
    @State private var forcesStartScreen = RootView.debugForcesStartScreen
    @State private var showsMusicStep = RootView.debugForcesMusicStep

    var body: some View {
        content
            .tvTrackActionsHost()
            .downloadRequestPrompts()
            .soundCloudEntitlementAlert()
            .listenTogether()
            .onChange(of: playerService.currentTrack?.largeArtworkURL) { _, url in
                ArtworkColors.shared.update(for: url)
            }
            .onChange(of: playerService.explicitPlayRequest) { _, _ in
                guard authService.isAuthenticated || usesDeviceMusic else { return }
                navigationState.showNowPlaying()
            }
            .onChange(of: authService.needsSignIn, initial: true) { _, needsSignIn in
                guard needsSignIn else { return }
                playerService.clearQueue(forgetSavedSession: false)
            }
            .onAppear { TopShelfPublisher.start() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                TopShelfPublisher.flush()
            }
            .ambientScreen(isEnabled: authService.isAuthenticated)
            .modifier(SameAccountLinking())
            .userActivity(
                HandoffActivityType.nowPlaying,
                isActive: authService.isAuthenticated && playerService.currentTrack != nil
            ) { activity in
                configureNowPlayingActivity(activity)
            }
    }

    private static var debugForcesStartScreen: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_START_SCREEN"] == "1"
        #else
        false
        #endif
    }

    private static var debugForcesMusicStep: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_MUSIC_STEP"] == "1"
        #else
        false
        #endif
    }

    private static var debugSkipsMusicStep: Bool {
        #if DEBUG
        VisualFixtures.isEnabled || ProcessInfo.processInfo.environment["SOUNDING_TV_DISMISS_WELCOME"] == "1"
        #else
        false
        #endif
    }

    private func configureNowPlayingActivity(_ activity: NSUserActivity) {
        guard let track = playerService.currentTrack else { return }
        activity.title = "Now Playing: \(track.title)"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.userInfo = [
            "trackId": track.id,
            "trackTitle": track.title,
            "artist": track.user.displayName,
            "position": playerService.currentTime,
        ]
        activity.requiredUserInfoKeys = ["trackId"]
    }

    private var showsTabs: Bool { !authService.needsSignIn || usesDeviceMusic }

    private var landsInDeviceMusic: Bool {
        remoteMusic.hasMusic && authService.needsSignIn && !usesDeviceMusic
    }

    private func startWithDeviceMusic() {
        usesDeviceMusic = true
        didSeeWelcome = true
        navigationState.selectedTab = .library
    }

    private func useWithoutSoundCloud() {
        forcesStartScreen = false
        if didAnswerMusicStep {
            startWithDeviceMusic()
        } else {
            showsMusicStep = true
        }
    }

    private func answerMusicStep() {
        didAnswerMusicStep = true
        didSeeWelcome = true
        showsMusicStep = false
        if authService.needsSignIn { startWithDeviceMusic() }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if showsMusicStep {
                TVMusicStepView(onContinue: answerMusicStep)
                    .transition(.push(from: .trailing))
            } else if showsTabs, !forcesStartScreen {
                signedInContent
            } else {
                QRCodeLoginView(useWithoutSoundCloud: useWithoutSoundCloud)
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: showsMusicStep)
        .fullScreenCover(isPresented: $navigationState.isSigningIn) {
            QRCodeLoginView(onClose: { navigationState.isSigningIn = false })
        }
        .onChange(of: authService.needsSignIn) { _, needsSignIn in
            if !needsSignIn { navigationState.isSigningIn = false }
        }
        .onChange(of: authService.needsSignIn, initial: true) { _, needsSignIn in
            let deviceTabs: [NavigationState.Tab] = [.library, .nowPlaying, .settings]
            if needsSignIn, !deviceTabs.contains(navigationState.selectedTab) {
                navigationState.selectedTab = .library
            }
        }
        .onChange(of: landsInDeviceMusic, initial: true) { _, lands in
            if lands, !forcesStartScreen { startWithDeviceMusic() }
        }
    }

    @ViewBuilder
    private var signedInContent: some View {
        if didSeeWelcome || usesDeviceMusic || didAnswerMusicStep || Self.debugSkipsMusicStep {
            tabs
                .tabViewStyle(.tabBarOnly)
                .background(BrowseBackdrop())
                .animation(reduceMotion ? nil : Motion.settle, value: navigationState.selectedTab)
        } else {
            TVMusicStepView(onContinue: answerMusicStep)
                .transition(.push(from: .trailing))
        }
    }

    @ViewBuilder
    private var tabs: some View {
        if !authService.needsSignIn {
            TabView(selection: $navigationState.selectedTab) {
                Tab("Home", systemImage: NavigationState.Tab.home.icon, value: .home) {
                    HomeView()
                }
                .accessibilityIdentifier("sidebar.tab.home")
                Tab(value: NavigationState.Tab.search, role: .search) {
                    SearchView()
                }
                .accessibilityIdentifier("sidebar.tab.search")
                libraryTab
                Tab("Decks", systemImage: NavigationState.Tab.decks.icon, value: .decks) {
                    DJModeView { navigationState.selectedTab = .home }
                }
                .accessibilityIdentifier("sidebar.tab.decks")
                Tab("Stations", systemImage: NavigationState.Tab.stations.icon, value: .stations) {
                    TVStationsView()
                }
                .accessibilityIdentifier("sidebar.tab.stations")
                nowPlayingTab
                settingsTab
            }
            .toolbarVisibility(.visible, for: .tabBar)
        } else {
            TabView(selection: $navigationState.selectedTab) {
                libraryTab
                nowPlayingTab
                settingsTab
            }
            .toolbarVisibility(.visible, for: .tabBar)
        }
    }

    private var libraryTab: some TabContent<NavigationState.Tab> {
        Tab("Library", systemImage: NavigationState.Tab.library.icon, value: .library) {
            LibraryView()
        }
        .accessibilityIdentifier("sidebar.tab.library")
    }

    private var nowPlayingTab: some TabContent<NavigationState.Tab> {
        Tab("Now Playing", systemImage: NavigationState.Tab.nowPlaying.icon, value: .nowPlaying) {
            NowPlayingView()
        }
        .accessibilityIdentifier("sidebar.tab.nowPlaying")
    }

    private var settingsTab: some TabContent<NavigationState.Tab> {
        Tab("Settings", systemImage: NavigationState.Tab.settings.icon, value: .settings) {
            SettingsView()
        }
        .accessibilityIdentifier("sidebar.tab.settings")
    }
}

#Preview {
    RootView()
        .environmentObject(AuthenticationService.shared)
        .environmentObject(PlayerService.shared)
        .environmentObject(NavigationState())
}

private struct SameAccountLinking: ViewModifier {
    @EnvironmentObject var authService: AuthenticationService
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var advertiser = SameAccountLinkAdvertiser.shared
    @ObservedObject private var server = SameAccountLinkAdvertiser.shared.server
    @ObservedObject private var nearby = SameAccountPhoneBrowser.shared
    @State private var linkedBanner: String?
    @State private var dismissedNearbyName: String?

    private var accountKey: String {
        "\(!authService.needsSignIn)-\(authService.currentUser?.id ?? "")-\(scenePhase != .background)"
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let banner = linkedBanner ?? nearbyHint {
                    Label(banner, systemImage: DeviceClass.phone.symbolName)
                        .font(.tvCaption)
                        .foregroundStyle(Color.scTextPrimary)
                        .padding(.horizontal, Space.base)
                        .padding(.vertical, Space.snug)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.bottom, Space.base)
                        .allowsHitTesting(false)
                        .focusable(false)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .animation(.smooth, value: linkedBanner ?? nearbyHint)
            .alert(
                "Allow “\(server.linkApproval?.deviceName ?? "A nearby device")” to link to this Apple TV?",
                isPresented: Binding(get: { server.linkApproval != nil }, set: { _ in }),
                presenting: server.linkApproval
            ) { _ in
                Button("Allow") { server.approveLink() }
                Button("Don't Allow", role: .cancel) { server.declineLink() }
            } message: { approval in
                Text("It's signed in to your SoundCloud account. Only allow it if it shows this code.\n\n\(Self.grouped(approval.code))")
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
            .onChange(of: accountKey, initial: true) { _, _ in update() }
            .onChange(of: advertiser.isAdvertising) { _, _ in askPhonesToLink() }
            .onChange(of: server.linkApproval != nil) { _, _ in askPhonesToLink() }
            .onReceive(CompanionServer.shared.$devices) { devices in askPhonesToLink(devices) }
            .onChange(of: nearby.nearbyName, initial: true) { _, name in
                askPhonesToLink()
                guard let name else {
                    dismissedNearbyName = nil
                    return
                }
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    if nearby.nearbyName == name { dismissedNearbyName = name }
                }
            }
            .onChange(of: advertiser.linkedName) { _, name in
                guard let name else { return }
                linkedBanner = "\(name) is linked"
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    linkedBanner = nil
                }
            }
    }

    private var nearbyHint: String? {
        guard !authService.needsSignIn, server.linkApproval == nil, let name = nearby.nearbyName, name != dismissedNearbyName else { return nil }
        return "\(name) is nearby. To link it, open Sounding › Devices on it."
    }

    private func update() {
        let accountId = authService.needsSignIn ? nil : SameAccountLinkAdvertiser.currentAccountId
        let active = scenePhase != .background
        advertiser.update(accountId: accountId, isActive: active)
        nearby.update(accountId: active ? accountId : nil, linkedDeviceIds: CompanionServer.shared.devices.compactMap(\.deviceId))
        askPhonesToLink()
    }

    private func askPhonesToLink(_ devices: [LinkedDevice]? = nil) {
        let companions = (devices ?? CompanionServer.shared.devices).filter { $0.deviceClass != .watch && $0.deviceClass != .tv }
        NearbyLinkRequestPublisher.shared.update(NearbyLinkRequestPublisher.Context(
            accountId: authService.needsSignIn ? nil : SameAccountLinkAdvertiser.currentAccountId,
            isActive: scenePhase != .background,
            isPairing: server.linkApproval != nil || !advertiser.isAdvertising,
            seesUnlinkedPhone: nearby.nearbyName != nil,
            linkedDeviceIds: companions.compactMap(\.deviceId),
            linkedDeviceCount: companions.count
        ))
    }

    private static func grouped(_ code: String) -> String {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return code }
        let split = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[..<split]) - \(digits[split...])"
    }
}
