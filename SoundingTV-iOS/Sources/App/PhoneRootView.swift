import SwiftUI
import Combine
import UIKit

struct PhoneRootView: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @EnvironmentObject private var pairing: DevicePairingFlow
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @ObservedObject private var continueFrom = ContinueFrom.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @SceneStorage("red.forbes.sounding.scene.tab") private var selection: PhoneTab = .home
    @State private var isExpandPending = false
    @State private var isNowPlayingExpanded = false
    @State private var presentedArtist: User?
    @State private var isShowingSharePlaySignIn = false
    @AppStorage("red.forbes.sounding.phone.didLeaveWelcome") private var didLeaveWelcome = false
    @AppStorage(MusicStep.answeredKey) private var didAnswerMusicStep = false
    @AppStorage(MusicStep.pendingKey) private var isMusicStepPending = false
    @State private var forcesMusicStep = MusicStep.isForced
    @Namespace private var nowPlayingNamespace
    @State private var nowPlayingZoomSourceID: String?

    private let nowPlayingHeroID = "sc.transportHero"

    @StateObject private var library = LibraryModels()
    @ObservedObject private var settingsPresenter = SettingsPresenter.shared

    enum PhoneTab: Hashable, RawRepresentable {
        case home
        case library
        case social
        case search
        case decks
        case recentlyAdded
        case songs
        case albums
        case artists
        case sets
        case setlists
        case mixes
        case playlists
        case downloads
        case following
        case followers
        case profile
        case activity
        case likes
        case history
        case stations
        case playlist(String)
        case playlistFolder(String)
        case pinnedFolder(String)
        case newPlaylist

        private static let named: [PhoneTab] = [
            .home, .library, .social, .search, .decks, .recentlyAdded, .songs, .albums, .artists, .sets,
            .setlists, .mixes, .playlists, .downloads, .following, .followers, .profile, .activity, .likes, .history, .stations,
        ]

        private static let playlistPrefix = "playlist."
        private static let folderPrefix = "playlistFolder."
        private static let pinnedFolderPrefix = "pinnedFolder."

        init?(rawValue: String) {
            if rawValue.hasPrefix(Self.pinnedFolderPrefix) {
                let id = String(rawValue.dropFirst(Self.pinnedFolderPrefix.count))
                guard !id.isEmpty else { return nil }
                self = .pinnedFolder(id)
                return
            }
            if rawValue.hasPrefix(Self.folderPrefix) {
                let id = String(rawValue.dropFirst(Self.folderPrefix.count))
                guard !id.isEmpty else { return nil }
                self = .playlistFolder(id)
                return
            }
            if rawValue.hasPrefix(Self.playlistPrefix) {
                let id = String(rawValue.dropFirst(Self.playlistPrefix.count))
                guard !id.isEmpty else { return nil }
                self = .playlist(id)
                return
            }
            guard let match = Self.named.first(where: { $0.rawValue == rawValue }) else { return nil }
            self = match
        }

        var rawValue: String {
            switch self {
            case .home: "home"
            case .library: "library"
            case .social: "social"
            case .search: "search"
            case .decks: "decks"
            case .recentlyAdded: "recentlyAdded"
            case .songs: "songs"
            case .albums: "albums"
            case .artists: "artists"
            case .sets: "sets"
            case .setlists: "setlists"
            case .mixes: "mixes"
            case .playlists: "playlists"
            case .downloads: "downloads"
            case .following: "following"
            case .followers: "followers"
            case .profile: "profile"
            case .activity: "activity"
            case .likes: "likes"
            case .history: "history"
            case .stations: "stations"
            case .playlist(let id): Self.playlistPrefix + id
            case .playlistFolder(let id): Self.folderPrefix + id
            case .pinnedFolder(let id): Self.pinnedFolderPrefix + id
            case .newPlaylist: "newPlaylist"
            }
        }

        static let librarySections: Set<PhoneTab> = [
            .recentlyAdded, .songs, .albums, .artists, .sets, .setlists, .downloads, .mixes, .history,
        ]

        static let playlistSections: Set<PhoneTab> = [.playlists, .likes, .newPlaylist]

        static let socialSections: Set<PhoneTab> = [.following, .followers, .profile, .activity]

        var padSidebarTab: PhoneTab {
            switch self {
            case .playlist, .newPlaylist: return .playlists
            case .setlists: return .sets
            case .social, .following, .followers, .profile, .activity: return .home
            default: return self
            }
        }

        var compactTab: PhoneTab {
            if case .playlist = self { return .playlists }
            if case .playlistFolder = self { return .playlists }
            if case .pinnedFolder = self { return .playlists }
            if Self.playlistSections.contains(self) { return .playlists }
            if Self.librarySections.contains(self) || self == .decks || self == .stations { return .library }
            if Self.socialSections.contains(self) || self == .social { return .home }
            return self
        }
    }

    var body: some View {
        content
            .task {
                if let forced = Self.debugInitialTab { selection = forced }
                if Self.debugOpensLikes { LibraryLikesRouting.shared.opensLikes = true }
                if Self.debugOpensSettings { settingsPresenter.isPresented = true }
            }
            .sheet(isPresented: $settingsPresenter.isPresented) {
                SettingsSheetView()
            }
            .debugOpensWindow()
            .animation(.smooth, value: onboardingStep)
            .onChange(of: showsWelcome) { wasShowing, isShowing in
                if wasShowing, !isShowing, !didAnswerMusicStep { isMusicStepPending = true }
            }
            .padDebugGeometry()
            .downloadRequestPrompts()
            .soundCloudEntitlementAlert()
            .listenTogether { isShowingSharePlaySignIn = true }
            .sheet(isPresented: $isShowingSharePlaySignIn) {
                NavigationStack {
                    SoundCloudLoginView.standalone {
                        isShowingSharePlaySignIn = false
                        credentials.refreshFromStore()
                    }
                }
            }
            .artworkImageCaching()
            .task { await credentials.prepareStoreAtLaunch() }
            .onChange(of: credentials.isSignedOut) { _, isSignedOut in
                refreshState()
                if !isSignedOut { didLeaveWelcome = false }
                if isSignedOut {
                    isNowPlayingExpanded = false
                    ArtworkImageSession.clear()
                    ArtworkColors.shared.lockAccount()
                    NowPlayingPalette.shared.lockAccount()
                }
            }
            .onChange(of: client.links.map(\.sessionId)) { previous, current in
                refreshState()
                if current.contains(where: { !previous.contains($0) }) { pairing.dismiss() }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                refreshState()
            }
            .onChange(of: pairing.request == nil) { _, _ in
                refreshState()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let onboardingStep {
            PhoneWelcomeView(
                step: onboardingStep,
                onUseWithoutSoundCloud: { didLeaveWelcome = true },
                onMusicAnswered: answerMusicStep
            )
            .transition(.opacity)
        } else {
            tabs
        }
    }

    private var onboardingStep: PhoneWelcomeView.Step? {
        if showsWelcome { return .welcome }
        if showsMusicStep { return .music }
        return nil
    }

    private var showsMusicStep: Bool {
        if forcesMusicStep { return true }
        return isMusicStepPending && !didAnswerMusicStep && !MusicStep.isSuppressed
    }

    private func answerMusicStep(addedFolder: Bool) {
        didAnswerMusicStep = true
        isMusicStepPending = false
        forcesMusicStep = false
        if addedFolder || credentials.isSignedOut {
            selection = PadLayout.isPad ? .songs : .library
        }
    }

    private var showsWelcome: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_WELCOME"] == "1" { return !didLeaveWelcome }
        if VisualFixtures.isEnabled
            || Self.debugInitialTab != nil
            || ProcessInfo.processInfo.environment["SOUNDING_TV_DISMISS_WELCOME"] == "1" {
            return false
        }
        #endif
        return credentials.isSignedOut && !didLeaveWelcome
    }

    @ViewBuilder
    private var tabs: some View {
        if PadLayout.isPad {
            playerChrome(
                PadRootTabs(selection: $selection, library: library),
                showsAccessory: !(selection == .decks && horizontalSizeClass != .compact)
            )
            .focusedSceneValue(\.rootTabSelection, $selection)
        } else {
            playerChrome(phoneTabs)
        }
    }

    private var phoneSelection: Binding<PhoneTab> {
        Binding(
            get: {
                let tab = selection.compactTab
                return Self.phoneTabValues.contains(tab) ? tab : .home
            },
            set: { selection = $0 }
        )
    }

    private static let phoneTabValues: Set<PhoneTab> = [.home, .library, .playlists, .search]

    private var phoneTabs: some View {
        TabView(selection: phoneSelection) {
            Tab("Home", systemImage: "house", value: PhoneTab.home) {
                ArtistRoutingStack(restorationKey: "home") { PhoneHomeHub() }
            }

            Tab("Library", systemImage: "music.note.list", value: PhoneTab.library) {
                ArtistRoutingStack(restorationKey: "library") { LibraryBrowserView(models: library) }
            }

            Tab("Playlists", systemImage: "music.note.square.stack", value: PhoneTab.playlists) {
                ArtistRoutingStack(restorationKey: "playlists") {
                    LibrarySectionRoot(section: .playlists, models: library, showsAccount: true)
                }
            }

            Tab(value: PhoneTab.search, role: .search) {
                ArtistRoutingStack(restorationKey: "search") { GlobalSearchView() }
            }
        }
        .tint(PadChrome.pageTint)
    }

    private func expandIfPending() {
        guard isExpandPending, coordinator.nowPlaying != nil else { return }
        isExpandPending = false
        withAnimation(.scMotion(SCContentMotion.settle, reduceMotion: reduceMotion)) { isNowPlayingExpanded = true }
    }

    private func playerChrome<Content: View>(_ content: Content, showsAccessory: Bool = true) -> some View {
        content
            .modifier(BottomAccessoryModifier(
                hasNowPlaying: (coordinator.nowPlaying != nil || PadLayout.isPad || coordinator.continueOffer(from: continueFrom) != nil) && showsAccessory,
                isExpanded: $isNowPlayingExpanded,
                heroID: nowPlayingHeroID,
                namespace: nowPlayingNamespace
            ))
            .tabBarMinimizeBehavior(.onScrollDown)
            .environment(\.nowPlayingZoomNamespace, nowPlayingNamespace)
            .onChange(of: continueFrom.expandRequest) { _, _ in
                isExpandPending = true
                expandIfPending()
            }
            .onReceive(NowPlayingReveal.shared.$request.dropFirst()) { _ in
                guard !isNowPlayingExpanded, let source = NowPlayingReveal.shared.consumeSource() else { return }
                nowPlayingZoomSourceID = source
                isExpandPending = true
                expandIfPending()
                guard isExpandPending else { return }
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    if isExpandPending, coordinator.nowPlaying == nil {
                        isExpandPending = false
                        nowPlayingZoomSourceID = nil
                    }
                }
            }
            .onChange(of: coordinator.nowPlaying != nil) { _, _ in
                expandIfPending()
            }
            .onChange(of: isNowPlayingExpanded) { _, isExpanded in
                guard !isExpanded else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    WindowAppearance.releaseOverride()
                    if !isNowPlayingExpanded { nowPlayingZoomSourceID = nil }
                }
            }
            .trafficNotice()
            .likeFailureAlert()
            .fullScreenCover(isPresented: $isNowPlayingExpanded) {
                NowPlayingSheet(isPresented: $isNowPlayingExpanded)
                    .likeFailureAlert()
                    .navigationTransition(.zoom(sourceID: nowPlayingZoomSourceID ?? nowPlayingHeroID, in: nowPlayingNamespace))
                    .addToPlaylistHost()
            }
            .environment(\.presentArtist) { presentedArtist = $0 }
            .sheet(item: $presentedArtist) { artist in
                NavigationStack {
                    ArtistDetailView(user: artist)
                        .appNavigationDestinations()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", role: .close) { presentedArtist = nil }
                            }
                        }
                }
                .addToPlaylistHost()
            }
            .behindTheTrackHost { BehindTheTrackSheet(track: $0) }
            .phoneIdentifySongHost(isNowPlayingExpanded: $isNowPlayingExpanded)
            .onReceive(SearchRequestRouter.shared.$pendingQuery.compactMap { $0 }) { _ in
                isNowPlayingExpanded = false
                presentedArtist = nil
                selection = .search
            }
            .onReceive(SoundingPageLinkRouter.shared.$pending.compactMap { $0 }) { request in
                isNowPlayingExpanded = false
                presentedArtist = nil
                if case .track = request.page {
                    if case .track(let track) = SoundingPageLinkRouter.shared.take(request) {
                        BehindTheTrackPresenter.shared.present(track)
                    }
                } else {
                    selection = .home
                }
            }
            .addToPlaylistHost()
    }

    private func refreshState() {
        credentials.refreshFromStore()
    }

    private static var debugInitialTab: PhoneTab? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_TAB"] {
        case "home":     return .home
        case "feed":     return .home
        case "library":  return PadLayout.isPad ? .recentlyAdded : .library
        case "likes":    return PadLayout.isPad ? .likes : .playlists
        case "albums":   return PadLayout.isPad ? .albums : .library
        case "artists":  return PadLayout.isPad ? .artists : .library
        case "sets":     return PadLayout.isPad ? .sets : .library
        case "setlists": return PadLayout.isPad ? .sets : .library
        case "mixes":    return PadLayout.isPad ? .mixes : .library
        case "playlists": return .playlists
        case "downloads": return PadLayout.isPad ? .downloads : .library
        case "history":  return PadLayout.isPad ? .history : .library
        case "decks":    return PadLayout.isPad ? .decks : .library
        case "stations": return PadLayout.isPad ? .stations : .library
        case "songs", "files": return PadLayout.isPad ? .songs : .library
        case "search":   return .search
        case "appleTV", "companion", "devices", "settings", "social", "following", "followers", "profile", "activity": return PadLayout.isPad ? .home : nil
        default:         return nil
        }
        #else
        return nil
        #endif
    }

    private static var debugOpensLikes: Bool {
        #if DEBUG
        !PadLayout.isPad && ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_TAB"] == "likes"
        #else
        false
        #endif
    }

    private static var debugOpensSettings: Bool {
        #if DEBUG
        ["appleTV", "companion", "devices", "settings"].contains(ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_TAB"] ?? "")
        #else
        false
        #endif
    }
}

@MainActor
final class SettingsPresenter: ObservableObject {
    static let shared = SettingsPresenter()

    @Published var isPresented = false

    private init() {}
}

enum PadSidebarCustomization {
    static let storageKey = "red.forbes.sounding.pad.sidebarCustomization"
    static let retiredIDs = ["pad.library.likes", "pad.settings", "pad.library.playlists", "pad.library.setlists", "pad.library.mixes", "pad.playlists.new", "pad.social"]

    static let librarySectionID = "pad.library.section"
    static let pinsSectionID = "pad.pins.section"
    static let libraryPrefix = "pad.library."
    static let pinPrefix = "pad.pin."

    static func dropRetiredItems(_ defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: storageKey)
            ?? defaults.data(forKey: storageKey).flatMap { String(data: $0, encoding: .utf8) }
        guard let stored, retiredIDs.contains(where: { stored.contains($0) }) else { return }
        defaults.removeObject(forKey: storageKey)
    }

    static func id(for row: LibraryPageRow) -> String {
        libraryPrefix + row.rawValue
    }

    static func row(for id: String) -> LibraryPageRow? {
        guard id.hasPrefix(libraryPrefix) else { return nil }
        return LibraryPageRow(rawValue: String(id.dropFirst(libraryPrefix.count)))
    }

    static func id(for pin: PlaylistFolderChild) -> String {
        pinPrefix + pin.key
    }

    static func pin(for id: String) -> PlaylistFolderChild? {
        guard id.hasPrefix(pinPrefix) else { return nil }
        return PlaylistFolderChild(key: String(id.dropFirst(pinPrefix.count)))
    }

    static func load(_ defaults: UserDefaults = .standard) -> TabViewCustomization? {
        let data = defaults.data(forKey: storageKey) ?? defaults.string(forKey: storageKey).map { Data($0.utf8) }
        guard let data else { return nil }
        return try? JSONDecoder().decode(TabViewCustomization.self, from: data)
    }

    static func save(_ value: TabViewCustomization, _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

@MainActor
final class PadSidebarCustomizationStore {
    private(set) var value: TabViewCustomization

    init() {
        value = PadSidebarCustomization.load() ?? TabViewCustomization()
    }

    func value(applying choices: LibraryRowChoices) -> TabViewCustomization {
        var next = value
        for row in LibraryRowChoices.Surface.padSidebar.rows where choices.isExplicit(row) {
            next[tab: PadSidebarCustomization.id(for: row)].sidebarVisibility = choices.isShown(row, on: .padSidebar) ? .visible : .hidden
        }
        return next
    }

    func update(_ next: TabViewCustomization) {
        guard next != value else { return }
        value = next
        PadSidebarCustomization.save(next)
    }
}

private struct PhoneHomeHub: View {
    private var store: HomeStore { HomeStore.shared }

    private enum Surface: String, CaseIterable, Identifiable {
        case forYou = "For You"
        case following = "Following"
        var id: Self { self }
    }

    @SceneStorage("home.surface") private var surface: Surface = Self.initialSurface

    private static var initialSurface: Surface {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_FEED_STATE"] != nil { return .following }
        #endif
        return .forYou
    }

    var body: some View {
        Group {
            switch surface {
            case .forYou: PhoneHomeView(source: store.forYou)
            case .following: FeedView(viewModel: store.following)
            }
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.large)
        .toolbarTitleMenu { surfacePicker }
        .toolbar {
            ToolbarItem(placement: PadLayout.isPad ? .topBarTrailing : .topBarLeading) {
                Menu {
                    surfacePicker
                } label: {
                    Label(surface.rawValue, systemImage: surface == .forYou ? "sparkles" : "person.2.fill")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Home: \(surface.rawValue)")
            }
            AccountToolbarItem()
        }
        .sensoryFeedback(.selection, trigger: surface)
    }

    private var surfacePicker: some View {
        Picker("Home", selection: $surface) {
            Label("For You", systemImage: "sparkles").tag(Surface.forYou)
            Label("Following", systemImage: "person.2.fill").tag(Surface.following)
        }
    }
}

@MainActor
enum WindowAppearance {
    static func releaseOverride() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where window.overrideUserInterfaceStyle != .unspecified {
                window.overrideUserInterfaceStyle = .unspecified
            }
        }
    }
}

enum PadChrome {
    static let sidebarTint = Color.scAccent
    static let pageTint = Color.scAccent
}

struct PadNowPlaying {
    let isExpanded: Binding<Bool>
    let heroID: String
    let namespace: Namespace.ID
    let isVisible: Bool
}

private struct PadRootTabs: View {
    @Binding var selection: PhoneRootView.PhoneTab
    let library: LibraryModels

    @State private var customization = PadSidebarCustomizationStore()
    @AppStorage(LibraryRowChoices.storageKey) private var libraryRowsRaw = ""
    @State private var libraryPlaylists: PadSidebarPlaylists?
    @State private var navigator = SidebarNavigator()
    @State private var folders: [PadSidebarFolder] = []
    @State private var pinned = PadPinnedState()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var hidesSections: Bool { horizontalSizeClass == .compact }

    private var libraryChoices: LibraryRowChoices { LibraryRowChoices(raw: libraryRowsRaw) }

    private var visibleSelection: Binding<PhoneRootView.PhoneTab> {
        Binding(
            get: { hidesSections ? selection.compactTab : selection },
            set: { tab in
                if tab != selection { selection = tab }
            }
        )
    }

    private var customizationBinding: Binding<TabViewCustomization> {
        let store = customization
        let choices = libraryChoices
        return Binding(
            get: { store.value(applying: choices) },
            set: { next in adoptSystemEdits(next) }
        )
    }

    var body: some View {
        tabs
            .environment(\.sidebarNavigator, navigator)
            .onChange(of: hidesSections, initial: true) { _, hides in
                navigator.update(available: hides ? [] : [.playlists, .likes, .history])
            }
            .task {
                let binding = $selection
                navigator.select = { tab in
                    let target = PadSidebarTarget.resolve(tab)
                    if binding.wrappedValue != target { binding.wrappedValue = target }
                }
                if libraryPlaylists == nil {
                    let navigator = navigator
                    let playlists = PadSidebarPlaylists { ids in navigator.playlistIDs = ids }
                    navigator.insert = { playlists.insert($0) }
                    libraryPlaylists = playlists
                }
                adoptSystemEdits(customization.value, initial: true)
            }
            .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
                let target = sizeClass == .compact ? selection.compactTab : PadSidebarTarget.resolve(selection)
                if target != selection { selection = target }
            }
            .padDebugSelection($selection)
            .onReceive(PlaylistFolderStore.shared.$tree.map(PadSidebarFolder.roots).removeDuplicates()) { next in
                if next != folders { folders = next }
                if case .playlistFolder(let id) = selection, !next.contains(where: { $0.id == id }) {
                    selection = .playlists
                }
            }
            .onReceive(PadPinnedState.publisher) { next in
                if next != pinned { pinned = next }
                navigator.sidebarPlaylistIDs = next.playlistIDs
                if case .pinnedFolder(let id) = selection, !next.folderIDs.contains(id) {
                    selection = .playlists
                }
                if case .playlist(let id) = selection, !next.playlistIDs.contains(id), PlaylistFolderStore.shared.hasLoadedPlaylists {
                    selection = .playlists
                }
            }
            .onReceive(PlaylistEditCenter.shared.$deletedIDs) { deleted in
                if case .playlist(let id) = selection, deleted.contains(id) {
                    selection = .playlists
                }
            }
    }

    private func sidebarLabel(_ title: String, _ symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            hidesSections ? Image(systemName: symbol) : SidebarTabIcon.image(symbol)
        }
    }

    private func adoptSystemEdits(_ next: TabViewCustomization, initial: Bool = false) {
        let surface = LibraryRowChoices.Surface.padSidebar
        var choices = libraryChoices
        let previous = customization.value(applying: choices)
        var stored = next
        var choicesChanged = false
        for row in surface.rows {
            let id = PadSidebarCustomization.id(for: row)
            let visibility = next[tab: id].sidebarVisibility
            guard visibility != .automatic else { continue }
            let adopts = initial ? !choices.isExplicit(row) : visibility != previous[tab: id].sidebarVisibility
            guard adopts else { continue }
            choices.setShown(visibility == .visible, for: row, on: surface)
            choicesChanged = true
        }
        if let order = next[section: PadSidebarCustomization.librarySectionID].tabOrder {
            let rows = order.compactMap(PadSidebarCustomization.row(for:))
            if !rows.isEmpty, rows != choices.ordered(for: surface) {
                choices.setOrder(rows, on: surface)
                choicesChanged = true
            }
            stored[section: PadSidebarCustomization.librarySectionID].resetTabOrder()
        }
        let pinTabOrder = next[section: PadSidebarCustomization.pinsSectionID].tabOrder
        let pinOrder = pinTabOrder?.compactMap(PadSidebarCustomization.pin(for:)) ?? []
        if pinTabOrder != nil {
            stored[section: PadSidebarCustomization.pinsSectionID].resetTabOrder()
        }
        customization.update(stored)
        let raw = choicesChanged ? choices.raw : nil
        guard raw != nil || !pinOrder.isEmpty else { return }
        Task { @MainActor in
            if !pinOrder.isEmpty { SidebarPins.shared.setOrder(pinOrder) }
            if let raw, raw != libraryRowsRaw { libraryRowsRaw = raw }
        }
    }

    private var tabs: some View {
        TabView(selection: visibleSelection) {
            Tab(value: PhoneRootView.PhoneTab.search, role: .search) {
                ArtistRoutingStack(restorationKey: "search") { GlobalSearchView() }
                .tint(PadChrome.pageTint)
            } label: {
                sidebarLabel("Search", SidebarSymbol.search)
            }
            .customizationID("pad.search")
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)

            Tab(value: PhoneRootView.PhoneTab.home) {
                ArtistRoutingStack(restorationKey: "home") { PhoneHomeHub() }
                .tint(PadChrome.pageTint)
            } label: {
                sidebarLabel("Home", SidebarSymbol.home)
            }
            .customizationID("pad.home")
            .customizationBehavior(.reorderable, for: .sidebar, .tabBar)

            Tab(value: PhoneRootView.PhoneTab.decks) {
                PhoneDecksView { selection = .home }
                .tint(PadChrome.pageTint)
            } label: {
                sidebarLabel("Decks", SidebarSymbol.decks)
            }
            .customizationID("pad.decks")
            .defaultVisibility(.hidden, for: .tabBar)
            .hidden(hidesSections)

            Tab(value: PhoneRootView.PhoneTab.stations) {
                ArtistRoutingStack(restorationKey: "stations") { StationsView() }
                .tint(PadChrome.pageTint)
            } label: {
                sidebarLabel("Stations", SidebarSymbol.stations)
            }
            .customizationID("pad.stations")
            .defaultVisibility(.hidden, for: .tabBar)
            .hidden(hidesSections)

            Tab("Library", systemImage: SidebarSymbol.allPlaylists, value: PhoneRootView.PhoneTab.library) {
                ArtistRoutingStack(restorationKey: "library") { LibraryBrowserView(models: library) }
                .tint(PadChrome.pageTint)
            }
            .customizationID("pad.library")
            .customizationBehavior(.disabled, for: .sidebar)
            .customizationBehavior(.reorderable, for: .tabBar)
            .defaultVisibility(.hidden, for: .sidebar)

            if !pinned.items.isEmpty {
                pinnedSection
            }
            librarySection
            playlistsSection
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(PadChrome.sidebarTint)
        .tabViewCustomization(customizationBinding)
        .tabViewSidebarFooter {
            PadSidebarAccount()
                .containerRelativeFrame(.horizontal, alignment: .leading)
        }
    }

    private var pinnedSection: some TabContent<PhoneRootView.PhoneTab> {
        TabSection("Pinned") {
            ForEach(pinned.items) { item in
                switch item.target {
                case .playlist(let id):
                    pinnedPlaylistTab(id: id, title: item.title, customizationID: PadSidebarCustomization.id(for: item.target), pin: item.target)
                case .folder(let id):
                    pinnedFolderSection(item, folderID: id)
                }
            }
        }
        .customizationID(PadSidebarCustomization.pinsSectionID)
    }

    private func pinnedFolderSection(_ item: PadPinnedState.Item, folderID id: String) -> some TabContent<PhoneRootView.PhoneTab> {
        TabSection(item.title) {
            Tab(value: PhoneRootView.PhoneTab.pinnedFolder(id)) {
                NavigationStack {
                    PlaylistFolderDetailView(folderID: id)
                        .appNavigationDestinations()
                }
                .environment(\.sidebarHostTab, .playlists)
                .tint(PadChrome.pageTint)
            } label: {
                sidebarLabel("All Playlists", SidebarSymbol.folder)
            }
            .customizationID(PadSidebarCustomization.pinPrefix + "page." + id)
            .defaultVisibility(.hidden, for: .tabBar)
            .hidden(hidesSections)
            .contextMenu { unpinButton(item.target) }
            .dropDestination(for: PlaylistReference.self) { items in
                _ = PlaylistFolderDrop.accept(items.map(\.child), into: id)
            }

            ForEach(item.children) { child in
                pinnedPlaylistTab(id: child.id, title: child.title, customizationID: PadSidebarCustomization.pinPrefix + "child." + child.id, pin: item.target)
            }
        }
        .customizationID(PadSidebarCustomization.id(for: item.target))
    }

    private func pinnedPlaylistTab(id: String, title: String, customizationID: String, pin: PlaylistFolderChild) -> some TabContent<PhoneRootView.PhoneTab> {
        Tab(value: PhoneRootView.PhoneTab.playlist(id)) {
            ArtistRoutingStack(restorationKey: "pin.\(id)") { PadPinnedPlaylistPage(playlistID: id) }
            .environment(\.sidebarHostTab, .playlist(id))
            .tint(PadChrome.pageTint)
        } label: {
            sidebarLabel(title, SidebarSymbol.pinnedPlaylist)
        }
        .customizationID(customizationID)
        .defaultVisibility(.hidden, for: .tabBar)
        .hidden(hidesSections)
        .contextMenu { unpinButton(pin) }
    }

    private func unpinButton(_ target: PlaylistFolderChild) -> some View {
        Button {
            withAnimation(.snappy) { SidebarPins.shared.unpin(target) }
        } label: {
            Label("Unpin from Sidebar", systemImage: "pin.slash")
        }
    }

    private var librarySection: some TabContent<PhoneRootView.PhoneTab> {
        TabSection("Library") {
            ForEach(libraryChoices.ordered(for: .padSidebar)) { row in
                Tab(value: row.padTab) {
                    PadLibraryPage(row: row, library: library)
                        .tint(PadChrome.pageTint)
                } label: {
                    sidebarLabel(row.title, row.symbol)
                }
                .customizationID(PadSidebarCustomization.id(for: row))
                .defaultVisibility(.hidden, for: .tabBar)
                .defaultVisibility(LibraryRowChoices.Surface.padSidebar.hiddenByDefault.contains(row) ? .hidden : .automatic, for: .sidebar)
                .hidden(hidesSections)
            }
        }
        .customizationID(PadSidebarCustomization.librarySectionID)
    }

    private var playlistsSection: some TabContent<PhoneRootView.PhoneTab> {
        TabSection("Playlists") {
            Tab(value: PhoneRootView.PhoneTab.playlists) {
                ArtistRoutingStack(restorationKey: "playlists") {
                    LibrarySectionRoot(section: .playlists, models: library, showsAccount: true)
                        .modifier(SidebarPendingPlaylistDestination())
                }
                .environment(\.sidebarHostTab, .playlists)
                .tint(PadChrome.pageTint)
            } label: {
                sidebarLabel(hidesSections ? "Playlists" : "All Playlists", hidesSections ? "music.note.square.stack" : SidebarSymbol.allPlaylists)
            }
            .customizationID("pad.playlists.all")
            .defaultVisibility(hidesSections ? .visible : .hidden, for: .tabBar)

            Tab(value: PhoneRootView.PhoneTab.likes) {
                ArtistRoutingStack(restorationKey: "likes") { LibrarySectionRoot(section: .likes, models: library, showsAccount: true) }
                .tint(PadChrome.pageTint)
            } label: {
                sidebarLabel(LikesPlaylist.title, SidebarSymbol.likes)
            }
            .customizationID("pad.playlists.likes")
            .defaultVisibility(.hidden, for: .tabBar)
            .hidden(hidesSections)

            ForEach(folders) { folder in
                Tab(value: PhoneRootView.PhoneTab.playlistFolder(folder.id)) {
                    NavigationStack {
                        PlaylistFolderDetailView(folderID: folder.id)
                            .appNavigationDestinations()
                    }
                    .environment(\.sidebarHostTab, .playlists)
                    .tint(PadChrome.pageTint)
                } label: {
                    sidebarLabel(folder.name, SidebarSymbol.folder)
                }
                .customizationID(PadSidebarFolder.customizationPrefix + folder.id)
                .defaultVisibility(.hidden, for: .tabBar)
                .hidden(hidesSections)
                .contextMenu {
                    if let stored = PlaylistFolderStore.shared.folder(folder.id) {
                        PlaylistFolderMenuActions(folder: stored)
                    }
                }
                .dropDestination(for: PlaylistReference.self) { items in
                    _ = PlaylistFolderDrop.accept(items.map(\.child), into: folder.id)
                }
            }

            Tab(value: PhoneRootView.PhoneTab.mixes) {
                NavigationStack { MixHistoryView().appNavigationDestinations() }
                .tint(PadChrome.pageTint)
            } label: {
                sidebarLabel("Mixes", SidebarSymbol.mixes)
            }
            .customizationID("pad.playlists.mixes")
            .defaultVisibility(.hidden, for: .tabBar)
            .hidden(hidesSections)
        }
        .customizationID("pad.playlists.section")
    }
}

@MainActor
enum PadSidebarTarget {
    static func resolve(_ tab: PhoneRootView.PhoneTab) -> PhoneRootView.PhoneTab {
        let pins = SidebarPins.shared
        switch tab {
        case .playlist(let id):
            return pins.sidebarPlaylistIDs(in: PlaylistFolderStore.shared).contains(id) ? tab : .playlists
        case .pinnedFolder(let id):
            return pins.pinnedFolderIDs.contains(id) ? tab : .playlists
        default:
            return tab.padSidebarTab
        }
    }
}

private struct PadPinnedState: Equatable {
    struct Child: Identifiable, Equatable {
        let id: String
        let title: String
    }

    struct Item: Identifiable, Equatable {
        let target: PlaylistFolderChild
        let title: String
        let children: [Child]

        var id: String { target.key }
    }

    var items: [Item] = []
    var playlistIDs: Set<String> = []
    var folderIDs: Set<String> = []

    @MainActor
    static let publisher: AnyPublisher<PadPinnedState, Never> = {
        let store = PlaylistFolderStore.shared
        return SidebarPins.shared.$pins
            .combineLatest(store.$tree, store.$playlists, PlaylistEditCenter.shared.$deletedIDs)
            .map { pins, tree, playlists, deleted in
                PadPinnedState.build(pins: pins, tree: tree, playlists: playlists, deleted: deleted)
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }()

    static func build(pins: [PlaylistFolderChild], tree: PlaylistFolderTree, playlists: [String: Playlist], deleted: Set<String>) -> PadPinnedState {
        var state = PadPinnedState()
        let direct = Set(pins.compactMap { target -> String? in
            if case .playlist(let id) = target { return id }
            return nil
        })
        state.playlistIDs = direct
        for target in pins {
            switch target {
            case .playlist(let id):
                guard !deleted.contains(id), let playlist = playlists[id] else { continue }
                state.items.append(Item(target: target, title: playlist.title, children: []))
            case .folder(let id):
                guard let folder = tree.folders[id] else { continue }
                state.folderIDs.insert(id)
                var children: [Child] = []
                for case .playlist(let childID) in tree.children[id] ?? [] where !direct.contains(childID) && !deleted.contains(childID) {
                    state.playlistIDs.insert(childID)
                    guard let playlist = playlists[childID] else { continue }
                    children.append(Child(id: childID, title: playlist.title))
                }
                state.items.append(Item(target: target, title: folder.name, children: children))
            }
        }
        return state
    }
}

private struct PadPinnedPlaylistPage: View {
    let playlistID: String

    @ObservedObject private var store = PlaylistFolderStore.shared
    @Namespace private var namespace

    var body: some View {
        if let playlist = store.playlist(playlistID) {
            PlaylistDetailView(playlist: playlist, heroNamespace: namespace)
        } else if store.hasLoadedPlaylists {
            ContentUnavailableView("Playlist Unavailable", systemImage: SidebarSymbol.allPlaylists)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PadLibraryPage: View {
    let row: LibraryPageRow
    let library: LibraryModels

    var body: some View {
        switch row {
        case .recentlyAdded:
            ArtistRoutingStack(restorationKey: "recentlyAdded") { LibraryRecentlyAddedView(models: library) }
        case .tracks:
            ArtistRoutingStack(restorationKey: "songs") {
                LibrarySongsView(viewModel: library.viewModel, analysisStore: library.analysisStore, confirmation: library.confirmation)
            }
        case .albums:
            ArtistRoutingStack(restorationKey: "albums") { PhoneLibraryCollectionsView(model: library.albums, showsAccount: true) }
        case .artists:
            ArtistRoutingStack(restorationKey: "artists") { PhoneLibraryCollectionsView(model: library.artists, showsAccount: true) }
        case .sets:
            ArtistRoutingStack(restorationKey: "sets") { LibrarySectionRoot(section: .sets, models: library, showsAccount: true) }
        case .downloads:
            NavigationStack { DownloadedMusicView().appNavigationDestinations() }
        case .history:
            NavigationStack { ListeningHistoryView().appNavigationDestinations() }
        case .stations, .decks, .mixes:
            EmptyView()
        }
    }
}

private extension LibraryPageRow {
    var padTab: PhoneRootView.PhoneTab {
        switch self {
        case .recentlyAdded: .recentlyAdded
        case .tracks: .songs
        case .albums: .albums
        case .artists: .artists
        case .stations: .stations
        case .decks: .decks
        case .sets: .sets
        case .downloads: .downloads
        case .mixes: .mixes
        case .history: .history
        }
    }
}

private struct PadSidebarFolder: Identifiable, Equatable {
    static let customizationPrefix = "pad.folder."

    let id: String
    let name: String

    static func roots(_ tree: PlaylistFolderTree) -> [PadSidebarFolder] {
        tree.roots.compactMap { tree.folders[$0] }.map { PadSidebarFolder(id: $0.id, name: $0.name) }
    }
}

@MainActor
private final class PadSidebarPlaylists {
    private var items: [Playlist] = []
    private var observation: AnyCancellable?
    private var deletions: AnyCancellable?
    private var reloadTask: Task<Void, Never>?
    private var inserted: [Playlist] = []
    private let onChange: (Set<String>) -> Void

    init(onChange: @escaping (Set<String>) -> Void) {
        self.onChange = onChange
        observation = LibrarySyncEngine.shared.$revision
            .removeDuplicates()
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
        deletions = PlaylistEditCenter.shared.$deletedIDs
            .removeDuplicates()
            .sink { [weak self] ids in self?.drop(ids) }
        reload()
    }

    func insert(_ playlist: Playlist) {
        guard !items.contains(where: { $0.id == playlist.id }),
              !PlaylistEditCenter.shared.deletedIDs.contains(playlist.id) else { return }
        inserted.append(playlist)
        items.insert(playlist, at: 0)
        onChange(Set(items.map(\.id)))
    }

    private func drop(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        inserted.removeAll { ids.contains($0.id) }
        let next = items.filter { !ids.contains($0.id) }
        guard next.count != items.count else { return }
        items = next
        onChange(Set(next.map(\.id)))
    }

    private func reload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let total = await LibraryDB.playlistCount()
            let page = await LibraryDB.allPlaylists(offset: 0, limit: max(total, 1))
            guard !Task.isCancelled, let self else { return }
            let deleted = PlaylistEditCenter.shared.deletedIDs
            var seen = Set<String>()
            let stored = page.playlists.filter { !$0.isAlbum && !deleted.contains($0.id) && seen.insert($0.id).inserted }
            inserted.removeAll { seen.contains($0.id) || deleted.contains($0.id) }
            let next = inserted + stored
            guard next.map(\.id) != items.map(\.id) else { return }
            items = next
            onChange(Set(next.map(\.id)))
        }
    }
}

private struct PadSidebarAccount: View {
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @State private var isSigningIn = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if isSignedOutRow {
                    isSigningIn = true
                } else {
                    SettingsPresenter.shared.isPresented = true
                }
            } label: {
                HStack(spacing: 12) {
                    avatar
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if credentials.isSessionRejected {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Needs sign-in")
                    } else if !isSignedOutRow {
                        Image(systemName: "gearshape")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, isSignedOutRow ? 4 : 16)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityHint(isSignedOutRow ? "Signs in to SoundCloud" : "Opens Settings")

            if isSignedOutRow {
                Button {
                    SettingsPresenter.shared.isPresented = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .padding(.trailing, 8)
                .accessibilityLabel("Settings")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .soundCloudSignIn(isPresented: $isSigningIn)
    }

    private var isSignedOutRow: Bool {
        user == nil && credentials.isSignedOut
    }

    private var user: User? {
        #if DEBUG
        if VisualFixtures.isEnabled { return VisualFixtures.currentUser }
        #endif
        return credentials.accountUser
    }

    private var title: String {
        if let user { return user.displayName }
        return credentials.isSignedOut ? "Sign In" : "SoundCloud"
    }

    @ViewBuilder
    private var avatar: some View {
        if user == nil, credentials.isSignedOut {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        } else {
            ArtworkThumbnail(
                url: user?.avatarURL,
                systemImage: "person.fill",
                isCircle: true,
                size: 32,
                identity: user?.id ?? "SoundCloud account"
            )
            .accessibilityHidden(true)
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
            .upNextTrackDropTarget()
        }
    }
}

private struct TrafficNoticeModifier: ViewModifier {
    @ObservedObject private var gateway = SoundCloudGateway.shared
    @State private var dismissedUntil: Date?
    @State private var clock = Date.now

    private var resumeDate: Date? {
        guard case .waiting(_, let until) = gateway.trafficSafety, until > clock else { return nil }
        return until
    }

    @ViewBuilder
    private var notice: some View {
        if let until = resumeDate, until != dismissedUntil {
            TrafficNotice(until: until) {
                withAnimation(.smooth) { dismissedUntil = until }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    func body(content: Content) -> some View {
        Group {
            if PadLayout.isPad {
                content.safeAreaInset(edge: .top, spacing: 0) { notice }
            } else {
                VStack(spacing: 0) {
                    notice
                    content
                }
            }
        }
        .animation(.smooth, value: resumeDate)
        .task(id: resumeDate) {
            guard let until = resumeDate else { return }
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow) + 0.5))
            guard !Task.isCancelled else { return }
            clock = .now
        }
    }
}

private struct TrafficNotice: View {
    let until: Date
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("SoundCloud is limiting requests")
                    .font(.footnote.weight(.semibold))
                Text("Your sign-in is saved. Resumes at \(until.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar, ignoresSafeAreaEdges: .top)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

private extension View {
    func trafficNotice() -> some View { modifier(TrafficNoticeModifier()) }
}
