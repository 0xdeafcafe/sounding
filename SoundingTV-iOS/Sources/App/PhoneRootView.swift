import SwiftUI

struct PhoneRootView: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @ObservedObject private var subscription = SubscriptionService.shared
    @ObservedObject private var companionRegistry = CompanionRegistry.shared
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var linkOfferBrowser = LinkOfferBrowser()
    @StateObject private var cloudOffers = CloudPairingOfferMonitor()

    @State private var selection: PhoneTab = .library
    @State private var nearbyHandshake: LinkConfirmationHandshake?
    @State private var nearbyPairing: LinkRequest?
    @State private var nearbyPairingPeerName: String?
    @State private var nearbyPairingPeerClass: DeviceClass = .tv
    @State private var lastPromptedOfferPrefix: String?
    @State private var isNowPlayingExpanded = false
    @Namespace private var nowPlayingNamespace

    private let nowPlayingHeroID = "sc.transportHero"

    enum PhoneTab: Hashable {
        case home
        case library
        case appleTV
        case settings
        case search
    }

    private static let cachingImageSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
        return URLSession(configuration: configuration)
    }()

    init() {
        if let forced = Self.debugInitialTab {
            _selection = State(initialValue: forced)
        }
    }

    var body: some View {
        ZStack {
            content
                .allowsHitTesting(!isNowPlayingExpanded)
                .accessibilityHidden(isNowPlayingExpanded)

            if isNowPlayingExpanded {
                NowPlayingSheet(
                    isPresented: $isNowPlayingExpanded,
                    heroID: nowPlayingHeroID,
                    namespace: nowPlayingNamespace
                )
                .zIndex(10)
                .transition(.opacity)
            }
        }
            .applyAsyncImageSessionIfAvailable(Self.cachingImageSession)
            .environmentObject(linkOfferBrowser)
            .environmentObject(cloudOffers)
            .task { refreshState() }
            .task {
                while !Task.isCancelled {
                    cloudOffers.refresh()
                    try? await Task.sleep(for: .seconds(cloudOffers.nextRefreshDelay))
                }
            }
            .onChange(of: credentials.isSignedOut) { _, _ in refreshState() }
            .onChange(of: subscription.authenticatedAccountID) { _, accountID in
                if accountID == nil {
                    isNowPlayingExpanded = false
                    Self.cachingImageSession.configuration.urlCache?.removeAllCachedResponses()
                    ArtworkColors.shared.lockAccount()
                    NowPlayingPalette.shared.lockAccount()
                }
            }
            .onChange(of: client.isLinked) { _, isLinked in
                refreshState()
                cloudOffers.refresh()
                if isLinked {
                    nearbyHandshake?.stop()
                    nearbyHandshake = nil
                }
            }
            .onChange(of: selection) { _, _ in cloudOffers.refresh() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                refreshState()
                cloudOffers.refresh()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    linkOfferBrowser.start()
                    presentNearbyOfferIfNeeded(linkOfferBrowser.offer)
                default:
                    linkOfferBrowser.stop()
                }
            }
            .onChange(of: linkOfferBrowser.offer, initial: true) { _, offer in
                presentNearbyOfferIfNeeded(offer)
            }
            .sheet(isPresented: Binding(
                get: { nearbyHandshake != nil },
                set: { presented in
                    if !presented {
                        nearbyHandshake?.stop()
                        nearbyHandshake = nil
                    }
                }
            )) {
                if let nearbyHandshake {
                    NumericComparisonSheet(handshake: nearbyHandshake) { sessionId, secret in
                        nearbyPairingPeerName = nearbyHandshake.claimedName
                        nearbyPairingPeerClass = nearbyHandshake.kind
                        self.nearbyHandshake = nil
                        DispatchQueue.main.async {
                            nearbyPairing = LinkRequest(sessionId: sessionId, secret: secret)
                        }
                    }
                }
            }
            .fullScreenCover(item: $nearbyPairing) { request in
                NavigationStack {
                    SoundCloudLoginView(
                        sessionId: request.sessionId,
                        sessionSecret: request.secret,
                        peerName: nearbyPairingPeerName,
                        peerClass: nearbyPairingPeerClass,
                        onComplete: {
                            nearbyPairing = nil
                            refreshState()
                        }
                    )
                }
            }
    }

    private var content: some View {
        tabs
            .safeAreaInset(edge: .top, spacing: 0) {
                if credentials.isReadOnlySession {
                    Button {
                        selection = .settings
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                            Text("SoundCloud sign-in expired")
                            Spacer()
                            Text("Fix")
                                .fontWeight(.semibold)
                        }
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.regularMaterial)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens account settings to reauthenticate")
                }
            }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: PhoneTab.home) {
                NavigationStack { PhoneHomeHub() }
            }

            // Companion replaces the old Stream tab. Following activity is a
            // Home surface now, while the room controller stays one tap away.
            Tab(value: PhoneTab.appleTV) {
                NavigationStack { CompanionRootView(showsSignIn: true) }
            } label: {
                Label {
                    Text("Companion")
                } icon: {
                    Image(systemName: "iphone.and.arrow.forward")
                        .opacity(client.isReachable ? 1.0 : 0.55)
                }
            }
            .badge(hasPairingOffer ? 1 : 0)

            Tab("Library", systemImage: "music.note.list", value: PhoneTab.library) {
                NavigationStack { LibraryBrowserView() }
            }

            Tab("Settings", systemImage: "gearshape", value: PhoneTab.settings) {
                NavigationStack { PhoneSettingsView() }
            }
            .badge(credentials.isSessionRejected ? 1 : 0)

            Tab(value: PhoneTab.search, role: .search) {
                NavigationStack { GlobalSearchView() }
            }
        }
        .modifier(BottomAccessoryModifier(
            hasNowPlaying: coordinator.nowPlaying != nil,
            isExpanded: $isNowPlayingExpanded,
            heroID: nowPlayingHeroID,
            namespace: nowPlayingNamespace
        ))
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    private var hasPairingOffer: Bool {
        !client.isLinked && (linkOfferBrowser.offer != nil || cloudOffers.hasOffer)
    }

    private func presentNearbyOfferIfNeeded(_ offer: LinkOfferBrowser.Offer?) {
        guard scenePhase == .active,
              nearbyHandshake == nil,
              nearbyPairing == nil,
              LinkedCompanionStore.load() == nil,
              let offer,
              offer.sessionIdPrefix != lastPromptedOfferPrefix else { return }
        lastPromptedOfferPrefix = offer.sessionIdPrefix
        nearbyHandshake = LinkConfirmationHandshake(offer: offer)
    }

    private func refreshState() {
        credentials.refreshFromStore()
    }

    private static var debugInitialTab: PhoneTab? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_TAB"] {
        case "home":     return .home
        case "feed":     return .home
        case "library":  return .library
        case "search":   return .search
        case "appleTV":  return .appleTV
        case "settings": return .settings
        default:         return nil
        }
        #else
        return nil
        #endif
    }
}

private struct PhoneHomeHub: View {
    @EnvironmentObject private var polyphony: PolyphonyController

    private enum Surface: String, CaseIterable, Identifiable {
        case forYou = "For You"
        case following = "Following"
        var id: Self { self }
    }

    @State private var surface: Surface = .forYou

    var body: some View {
        Group {
            switch surface {
            case .forYou: PhoneHomeView()
            case .following: FeedView()
            }
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    Picker("Home", selection: $surface) {
                        Label("For You", systemImage: "sparkles").tag(Surface.forYou)
                        Label("Following", systemImage: "person.2.fill").tag(Surface.following)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(surface.rawValue)
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityLabel("Home section, \(surface.rawValue)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    PolyphonyView()
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .accessibilityLabel("Polyphony")
            }
            ToolbarItem(placement: .topBarTrailing) {
                AccountAvatarButton()
            }
        }
    }
}

@MainActor
final class CloudPairingOfferMonitor: ObservableObject {
    @Published private(set) var hasOffer = false

    private var expiresAt: Date?

    func refresh() {
        guard LinkedCompanionStore.load() == nil else {
            set(hasOffer: false, expiresAt: nil)
            return
        }
        if Self.debugOfferSeeded {
            set(hasOffer: true, expiresAt: Date().addingTimeInterval(BonjourConstants.sessionTimeout))
            return
        }
        guard let offer = LinkOfferStore.fetchLatest(), offer.secret != nil else {
            set(hasOffer: false, expiresAt: nil)
            return
        }
        set(hasOffer: true, expiresAt: offer.createdAt.addingTimeInterval(BonjourConstants.sessionTimeout))
    }

    var nextRefreshDelay: TimeInterval {
        guard let expiresAt else { return 30 }
        return max(1, min(30, expiresAt.timeIntervalSinceNow + 0.5))
    }

    private func set(hasOffer newValue: Bool, expiresAt newExpiry: Date?) {
        expiresAt = newExpiry
        if hasOffer != newValue {
            hasOffer = newValue
        }
    }

    private static var debugOfferSeeded: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SOUNDING_TV_CLOUD_OFFER"] == "1"
        #else
        return false
        #endif
    }
}

private extension View {
    @ViewBuilder
    func applyAsyncImageSessionIfAvailable(_ session: URLSession) -> some View {
        if #available(iOS 27.0, *) {
            self.asyncImageURLSession(session)
        } else {
            self
        }
    }
}

private struct BottomAccessoryModifier: ViewModifier {
    let hasNowPlaying: Bool
    @Binding var isExpanded: Bool
    let heroID: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        content.tabViewBottomAccessory(isEnabled: hasNowPlaying) {
            TransportBarView(
                isExpanded: $isExpanded,
                heroID: heroID,
                heroNamespace: namespace
            )
        }
    }
}
