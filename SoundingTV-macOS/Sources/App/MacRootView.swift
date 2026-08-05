import SwiftUI
import AppKit
import Combine
import os

struct MacRootView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @EnvironmentObject private var midi: MIDIControllerHub
    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var nowPlayingPresentation = MacNowPlayingPresentation.shared
    @ObservedObject private var activityPoller = SoundCloudActivityPoller.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection: Section? = Section.debugInitial()

    @State private var sidebarPlayerPane: MacNowPlayingPane?

    @State private var isShowingNowPlaying = false
    @State private var isShowingActivityInbox = false
    @State private var isShowingSessionRecovery = false
    @State private var soundCloudTrafficState: SoundCloudTrafficSafetyState = .ready

    @Environment(\.openWindow) private var openWindow

    @Environment(\.openSettings) private var openSettings

    @StateObject private var sidebarPlaylists = SidebarPlaylistsModel()

    @StateObject private var homeSource = DiscoveryHomeSource()
    @StateObject private var feedModel = FeedViewModel()
    @StateObject private var searchModel = MacSearchModel()
    @StateObject private var libraryModel = MacLibraryModel()
    @StateObject private var likesModel = MacLibraryModel(mode: .liked)
    @StateObject private var privateSharesModel = MacLibraryModel(mode: .friends)
    @StateObject private var artistsModel = MacArtistsPaneModel()
    @StateObject private var playlistsModel = MacPlaylistsModel()

    @ObservedObject private var rootSelection = MacRootSelection.shared

    @State private var detailPath = NavigationPath()
    @State private var forwardPaths: [NavigationPath] = []
    @State private var pathChangeComesFromHistory = false
    @State private var previousPathCount = 0

    enum Section: Hashable, Identifiable {
        case search
        case home
        case companion
        case polyphony
        case console
        case library
        case likes
        case friendsWithADJ
        case artists
        case sets
        case playlists
        case myPlaylists
        case likedPlaylists
        case playlist(id: String)
        case intelligence
        case status
        case hardware
        case profile
        case messages
        case followers
        case following
        case myTracks
        case account

        var id: Self { self }

        var title: String {
            switch self {
            case .search: return "Search"
            case .home: return "Home"
            case .companion: return "Companion"
            case .polyphony: return "Polyphony"
            case .console: return "Decks"
            case .library: return "Library"
            case .likes: return "Likes"
            case .friendsWithADJ: return "Private Shares"
            case .artists: return "Artists"
            case .sets: return "Sets"
            case .playlists: return "All Playlists"
            case .myPlaylists: return "My Playlists"
            case .likedPlaylists: return "Liked Playlists"
            case .playlist: return "Playlist"
            case .intelligence: return "Music Intelligence"
            case .status: return "Status"
            case .hardware: return "Hardware"
            case .profile: return "Profile"
            case .messages: return "Messages"
            case .followers: return "Followers"
            case .following: return "Following"
            case .myTracks: return "Tracks"
            case .account: return "Account"
            }
        }

        var symbol: String {
            switch self {
            case .search: return "magnifyingglass"
            case .home: return "house"
            case .companion: return "iphone.and.arrow.forward"
            case .polyphony: return "dot.radiowaves.left.and.right"
            case .console: return "slider.horizontal.3"
            case .library: return "music.note.list"
            case .likes: return "heart"
            case .friendsWithADJ: return "lock.fill"
            case .artists: return "person.2"
            case .sets: return "clock.arrow.2.circlepath"
            case .playlists: return "square.stack.3d.up"
            case .myPlaylists: return "folder"
            case .likedPlaylists: return "folder"
            case .playlist: return "music.note.list"
            case .intelligence: return "waveform"
            case .status: return "waveform"
            case .hardware: return "hifispeaker"
            case .profile: return "person.crop.circle"
            case .messages: return "bubble.left.and.bubble.right"
            case .followers: return "person.2"
            case .following: return "person.crop.circle.badge.checkmark"
            case .myTracks: return "music.note"
            case .account: return "gearshape"
            }
        }

        #if DEBUG
        static func debugInitial() -> Section {
            switch ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_TAB"]?.lowercased() {
            case "console", "dj", "djconsole": return .console
            case "status": return .status
            case "hardware": return .hardware
            case "search": return .search
            case "home": return .home
            // Stream is a Home surface now. Keep the old debug aliases useful
            // without keeping a second navigation destination alive.
            case "stream", "feed": return .home
            case "companion", "tv", "appletv": return .companion
            case "polyphony", "room": return .polyphony
            case "artists": return .artists
            case "sets": return .sets
            case "playlists": return .playlists
            case "intelligence", "analysis": return .intelligence
            case "profile": return .profile
            case "messages": return .messages
            case "followers": return .followers
            case "following": return .following
            case "tracks": return .myTracks
            case "account": return .account
            case "library": return .library
            case "likes", "liked": return .likes
            default: return .likes
            }
        }
        #else
        static func debugInitial() -> Section { .likes }
        #endif
    }

    private var sidebarSelection: Binding<Section?> {
        Binding(
            get: { selection },
            set: { newValue in
                if !detailPath.isEmpty { detailPath = NavigationPath() }
                forwardPaths.removeAll()
                selection = newValue
            }
        )
    }

    var body: some View {
        ZStack {
            splitView

            if isShowingNowPlaying {
                nowPlayingTakeover
            }
        }
        // Keep toolbar visibility out of SwiftUI's toolbar-preference graph.
        // Toggling `.toolbar(.hidden)` while an NSHostingView is laying out
        // was the source of the AppKit update-constraints trap seen when the
        // player takeover opened.
        .background(MacWindowToolbarVisibility(isHidden: isShowingNowPlaying).frame(width: 0, height: 0))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: isShowingNowPlaying)
        .safeAreaInset(edge: .top, spacing: 0) {
            if credentials.isReadOnlySession {
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                    Text("Session expired. Saved data remains available read-only.")
                    Spacer()
                    Button("Reauthenticate") { isShowingSessionRecovery = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                .accessibilityElement(children: .combine)
            } else if case .waiting(_, let until) = soundCloudTrafficState {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("SoundCloud access is temporarily paused until (until.formatted(date: .abbreviated, time: .shortened)).")
                    Spacer()
                    Button("Open Account Settings") { openSettings() }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                .accessibilityElement(children: .combine)
            }
        }
        .sheet(isPresented: $isShowingSessionRecovery) {
            MacSoundCloudSignInView(peerName: nil, forHandoff: false, isReauthentication: true) {
                credentials.didCompleteSignIn()
                isShowingSessionRecovery = false
            }
            .frame(minWidth: 720, minHeight: 620)
        }
        .onReceive(NotificationCenter.default.publisher(for: .soundCloudTrafficSafetyChanged)) { _ in
            soundCloudTrafficState = SoundCloudAPI.shared.trafficSafetyState()
        }
        .task {
            soundCloudTrafficState = SoundCloudAPI.shared.trafficSafetyState()
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            MacSidebar(selection: sidebarSelection, playlists: sidebarPlaylists)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            ZStack(alignment: .trailing) {
                navigationDetail

                if sidebarPlayerPane != nil {
                    queuePanel
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .trailing).combined(with: .opacity)
                        )
                        .zIndex(2)
                }
            }
            // HSplitView and artwork-backed detail surfaces may otherwise
            // draw outside their assigned NavigationSplitView column while
            // the window is narrow.
            .clipped()
            .animation(reduceMotion ? nil : SCContentMotion.settle, value: sidebarPlayerPane)
        }
        .navigationTitle("SoundingCloud")
        .task {
            if nowPlayingPresentation.presentationRequest > 0 {
                isShowingNowPlaying = true
                nowPlayingPresentation.consumePresentationRequest()
            }
            await sidebarPlaylists.loadIfNeeded(credentials: credentials)
            MacConsoleController.shared.isConsoleActive = (selection == .console)
            #if DEBUG
            if ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_QUEUE"] == "1" {
                sidebarPlayerPane = .queue
            }
            #endif
        }
        .onChange(of: credentials.isSignedOut) { _, isSignedOut in
            guard !isSignedOut else { return }
            Task { await sidebarPlaylists.loadIfNeeded(credentials: credentials, forceReload: true) }
        }
        .onChange(of: selection) { _, newSelection in
            MacConsoleController.shared.isConsoleActive = (newSelection == .console)
        }
        .onReceive(rootSelection.$pending.compactMap { $0 }) { requested in
            rootSelection.pending = nil
            if requested == .account || requested == .intelligence {
                MacSettingsNavigation.shared.selection = requested == .intelligence ? .intelligence : .account
                openSettings()
                return
            }
            if !detailPath.isEmpty { detailPath = NavigationPath() }
            forwardPaths.removeAll()
            selection = requested
        }
        .onReceive(rootSelection.$queueToggleRequest.dropFirst()) { _ in
            guard !isShowingNowPlaying else { return }
            sidebarPlayerPane = sidebarPlayerPane == .queue ? nil : .queue
        }
        .onReceive(rootSelection.$pendingArtist.compactMap { $0 }) { user in
            rootSelection.pendingArtist = nil
            if user.id == credentials.currentUser?.id {
                detailPath = NavigationPath()
                forwardPaths.removeAll()
                selection = .profile
                return
            }
            // Only creator accounts belong to the Artists destination. A
            // listener profile opens in the caller's navigation context.
            if user.trackCount > 0, selection != .artists {
                detailPath = NavigationPath()
                selection = .artists
            }
            forwardPaths.removeAll()
            detailPath.append(user)
        }
        .onReceive(rootSelection.$pendingPlaylist.compactMap { $0 }) { playlist in
            rootSelection.pendingPlaylist = nil
            if selection == .console {
                selection = .library
                detailPath = NavigationPath()
            }
            forwardPaths.removeAll()
            detailPath.append(playlist)
        }
        .onChange(of: nowPlayingPresentation.presentationRequest) { _, _ in
            guard nowPlayingPresentation.presentationRequest > 0 else { return }
            isShowingNowPlaying = true
            nowPlayingPresentation.consumePresentationRequest()
        }
    }

    private var queuePanel: some View {
        Group {
            switch sidebarPlayerPane {
            case .comments:
                MacTimedCommentsSidebar()
            default:
                MacQueueSidebar(appearance: .rootArtwork)
            }
        }
            .frame(width: 390)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .leading) { Divider() }
            .shadow(color: .black.opacity(0.18), radius: 18, x: -6)
    }

    private var navigationDetail: some View {
        NavigationStack(path: $detailPath) {
            detailContent
                .navigationDestination(for: User.self) { user in
                    MacArtistDetailView(user: user)
                        .navigationBarBackButtonHidden(true)
                }
                .navigationDestination(for: Playlist.self) { playlist in
                    if playlist.isAlbum {
                        MacAlbumDetailView(album: playlist)
                            .navigationBarBackButtonHidden(true)
                    } else {
                        MacPlaylistDetailView(playlist: playlist)
                            .navigationBarBackButtonHidden(true)
                    }
                }
        }
        .toolbar {
            if detailPath.count > 0 || !forwardPaths.isEmpty {
                ToolbarItemGroup(placement: .navigation) {
                    Button(action: navigateBack) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(detailPath.isEmpty)
                    .help("Back")

                    Button(action: navigateForward) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(forwardPaths.isEmpty)
                    .help("Forward")
                }
            }

            ToolbarItem(id: "activity-inbox", placement: .primaryAction) {
                Button {
                    isShowingActivityInbox.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: activityPoller.unreadCount > 0 ? "bell.badge.fill" : "bell")
                        if activityPoller.unreadCount > 0 {
                            Text("\(min(activityPoller.unreadCount, 99))")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .frame(minWidth: 13, minHeight: 13)
                                .background(Color.orange, in: Capsule())
                                .offset(x: 8, y: -7)
                        }
                    }
                }
                .help("Activity")
                .accessibilityLabel(
                    activityPoller.unreadCount == 0
                        ? "Activity"
                        : "Activity, \(activityPoller.unreadCount) unread"
                )
                .popover(isPresented: $isShowingActivityInbox, arrowEdge: .bottom) {
                    MacActivityInboxPopover()
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
        .safeAreaInset(edge: .bottom) {
            if selection != .console && !isShowingNowPlaying {
                MacTransportBar(activeSidebarPane: sidebarPlayerPane) { pane in
                    sidebarPlayerPane = sidebarPlayerPane == pane ? nil : pane
                }
                .padding(.horizontal, 20)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
            }
        }
        .animation(reduceMotion ? nil : SCContentMotion.settle, value: player.currentTrack?.id)
    }

    private func navigateBack() {
        guard !detailPath.isEmpty else { return }
        forwardPaths.removeAll { $0.count == detailPath.count }
        forwardPaths.append(detailPath)
        pathChangeComesFromHistory = true
        detailPath.removeLast()
    }

    private func navigateForward() {
        let nextCount = detailPath.count + 1
        guard let index = forwardPaths.lastIndex(where: { $0.count == nextCount }) else {
            forwardPaths.removeAll { $0.count <= detailPath.count }
            return
        }
        let path = forwardPaths.remove(at: index)
        pathChangeComesFromHistory = true
        detailPath = path
    }

    private func preloadSidebarDestinations() async {
        let seed = player.currentTrack.map(DiscoveryHomeSource.Seed.init(track:)) ?? DiscoveryHomeSource.Seed()
        // Give the visible destination first use of the connection. The rest
        // can prewarm after Home has either refreshed or restored its cache.
        await homeSource.refreshIfStale(seed: seed)

        guard !credentials.isSignedOut else { return }

        async let feed: Void = feedModel.loadContentIfNeeded()
        async let artists: Void = artistsModel.load(credentials: credentials)
        let userID = await credentials.waitForCurrentUser()?.id
        libraryModel.load(currentUserId: userID, isSignedOut: false)
        likesModel.load(currentUserId: userID, isSignedOut: false)
        playlistsModel.load(currentUserId: userID, isSignedOut: false)
        _ = await (feed, artists)
    }

    private var nowPlayingTakeover: some View {
        MacNowPlayingView(
            isEmbedded: true,
            onClose: { isShowingNowPlaying = false },
            onDetach: {}
        )
        .transition(
            reduceMotion
                ? .opacity
                // Keep the takeover opaque while it rises.  Combining this
                // with opacity briefly exposed the artwork in the source row,
                // which looked as though the cover was flying into the player.
                : .move(edge: .bottom)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(1)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .search: MacSearchView(model: searchModel, libraryModel: libraryModel)
        case .home: MacHomeView(source: homeSource, feedModel: feedModel)
        case .companion: MacTVCompanionView()
        case .polyphony: MacPolyphonyView()
        case .console: MacConsoleView()
        case .library, .account, nil: MacLibraryPaneView(model: libraryModel)
        case .likes: MacLibraryPaneView(model: likesModel, pinnedMode: .liked)
        case .friendsWithADJ: MacLibraryPaneView(model: privateSharesModel, pinnedMode: .friends)
        case .artists: MacArtistsPane(model: artistsModel)
        case .sets: MacSetsPane(model: likesModel)
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
            } else {
                MacPlaylistsView(model: playlistsModel)
            }
        case .intelligence:
            MacLibraryPaneView(model: libraryModel)
        case .status: StatusPane()
        case .hardware: HardwarePane()
        case .profile: MacProfileView()
        case .messages: MacMessagesView()
        case .followers: MacOwnProfilePaneView(pane: .followers)
        case .following: MacOwnProfilePaneView(pane: .following)
        case .myTracks: MacOwnProfilePaneView(pane: .tracks)
        }
    }
}

private struct MacOwnProfilePaneView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    let pane: ArtistDetailPane
    @State private var loadFailed = false
    @State private var attempt = 0
    @State private var isShowingReauthentication = false

    var body: some View {
        Group {
            if let user = credentials.currentUser {
                MacArtistDetailView(user: user, initialPane: pane)
            } else if credentials.isSessionRejected {
                ContentUnavailableView {
                    Label("Session Expired", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                } description: {
                    Text("Reauthenticate to load this account section. Your cached data is preserved.")
                } actions: {
                    Button("Reauthenticate") { isShowingReauthentication = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if credentials.isSignedOut {
                ContentUnavailableView {
                    Label("Please Sign In", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Home and Search remain available in guest mode. Please sign in to view account activity.")
                }
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Couldn’t Load Your Profile", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Your account section is unavailable. Check the connection and try again.")
                } actions: {
                    Button("Try Again") { attempt &+= 1 }
                }
            } else {
                ProgressView("Loading profile…")
            }
        }
        .task(id: attempt) {
            loadFailed = false
            guard !credentials.isSignedOut,
                  !credentials.isSessionRejected,
                  credentials.currentUser == nil else { return }
            loadFailed = await credentials.waitForCurrentUser() == nil
        }
        .sheet(isPresented: $isShowingReauthentication) {
            MacSoundCloudSignInView(peerName: nil, forHandoff: false, isReauthentication: true) {
                credentials.didCompleteSignIn()
                isShowingReauthentication = false
                attempt &+= 1
            }
            .frame(minWidth: 720, minHeight: 620)
        }
    }
}

private struct MacActivityInboxPopover: View {
    @ObservedObject private var poller = SoundCloudActivityPoller.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                if poller.unreadCount > 0 {
                    Button("Mark All Read") { poller.markAllRead() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)

            Divider()

            if poller.inbox.isEmpty {
                ContentUnavailableView(
                    "No New Activity",
                    systemImage: "bell",
                    description: Text("New followers, messages, and stream activity will appear here.")
                )
                .frame(width: 360, height: 230)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(poller.inbox) { event in
                            Button {
                                poller.markRead(id: event.id)
                                if let destination = event.destination {
                                    NSWorkspace.shared.open(destination)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: symbol(for: event.kind))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(event.readAt == nil ? Color.orange : Color.secondary)
                                        .frame(width: 26, height: 26)
                                        .background(Color.primary.opacity(0.055), in: Circle())

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.title)
                                            .font(.system(size: 12, weight: event.readAt == nil ? .bold : .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(event.body)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 4)
                                    Text(event.date, style: .relative)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .frame(width: 380, height: 360)
            }
        }
    }

    private func symbol(for kind: SoundCloudInboxEvent.Kind) -> String {
        switch kind {
        case .feed: return "waveform"
        case .follower: return "person.badge.plus"
        case .message: return "envelope"
        }
    }
}

/// An AppKit-level toolbar toggle keeps the transport takeover clear of
/// toolbar controls without mutating SwiftUI toolbar preferences mid-layout.
private struct MacWindowToolbarVisibility: NSViewRepresentable {
    let isHidden: Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let toolbar = nsView.window?.toolbar else { return }
            let shouldBeVisible = !isHidden
            guard toolbar.isVisible != shouldBeVisible else { return }
            toolbar.isVisible = shouldBeVisible
        }
    }
}

@MainActor
final class MacRootSelection: ObservableObject {
    static let shared = MacRootSelection()

    @Published var pending: MacRootView.Section?

    @Published var pendingArtist: User?

    @Published var pendingPlaylist: Playlist?

    @Published private(set) var queueToggleRequest = 0

    private init() {}

    func request(_ section: MacRootView.Section) { pending = section }

    func request(artist: User) {
        if artist.id == SoundCloudCredentialSource.shared.currentUser?.id {
            pending = .profile
        } else {
            pendingArtist = artist
        }
    }

    func request(playlist: Playlist) { pendingPlaylist = playlist }

    func toggleQueue() { queueToggleRequest &+= 1 }
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
    private var hasLoaded = false

    func loadIfNeeded(credentials: SoundCloudCredentialSource, forceReload: Bool = false) async {
        if hasLoaded, !forceReload { return }
        guard !credentials.isSignedOut, let user = await credentials.waitForCurrentUser() else {
            items = []
            return
        }
        do {
            async let yoursPage = SoundCloudAPI.shared.getUserPlaylists(userId: user.id, limit: 50)
            async let likedPage = SoundCloudAPI.shared.getLikedPlaylists(limit: 50)
            let (yours, liked) = try await (yoursPage, likedPage)
            var yourCollections = yours.collection
            var likedCollections = liked.collection

            func publish() {
                let yourIDs = Set(yourCollections.map(\.id))
                items = yourCollections.map {
                    Entry(id: $0.id, title: $0.title, playlist: $0, source: .yours)
                } + likedCollections.filter { !yourIDs.contains($0.id) }.map {
                    Entry(id: $0.id, title: $0.title, playlist: $0, source: .liked)
                }
            }
            publish()
            hasLoaded = true

            var yourCursor = yours
            var likedCursor = liked
            var pageCount = 1
            while (yourCursor.nextHref != nil || likedCursor.nextHref != nil),
                  !Task.isCancelled,
                  pageCount < 50 {
                try? await Task.sleep(for: .milliseconds(300))
                if yourCursor.nextHref != nil {
                    yourCursor = try await SoundCloudAPI.shared.getNextPage(yourCursor)
                    yourCollections.appendUnique(contentsOf: yourCursor.collection)
                }
                if likedCursor.nextHref != nil {
                    likedCursor = try await SoundCloudAPI.shared.getNextPage(likedCursor)
                    likedCollections.appendUnique(contentsOf: likedCursor.collection)
                }
                publish()
                pageCount += 1
            }
        } catch {
            items = []
        }
    }
}

private struct MacSidebar: View {
    @Binding var selection: MacRootView.Section?
    @ObservedObject var playlists: SidebarPlaylistsModel

    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var likesSync = LikesSyncEngine.shared
    @ObservedObject private var metadataSync = LibraryMetadataSyncEngine.shared
    @ObservedObject private var analysisWork = AutomaticAnalysisStatus.shared
    @ObservedObject private var analysisIndex = MacAnalysisIndex.shared
    @ObservedObject private var activityPoller = SoundCloudActivityPoller.shared

    private let primary: [MacRootView.Section] = [.home, .search, .companion, .polyphony, .console, .hardware]
    private let social: [MacRootView.Section] = [.profile, .messages, .followers, .following, .myTracks]

    @State private var isDiagnosticsExpanded = false
    @State private var isPlaylistsExpanded = true
    @State private var areYourPlaylistsExpanded = true
    @State private var areLikedPlaylistsExpanded = true
    @AppStorage("mac.sidebar.library.artists") private var showsArtists = true
    @AppStorage("mac.sidebar.library.sets") private var showsSets = true

    var body: some View {
        sourceList
            .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            if selection == .console {
                MacSidebarDeckDock()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            accountFooter
        }
        .animation(SCContentMotion.settle, value: selection == .console)
    }

    private var sourceList: some View {
        List(selection: $selection) {
            Section {
                ForEach(primary) { navigationRow(for: $0) }
            }

            Section("Social") {
                ForEach(social) { navigationRow(for: $0) }
            }

            Section {
                navigationRow(for: .likes)
                navigationRow(for: .friendsWithADJ)
                if showsArtists { navigationRow(for: .artists) }
                if showsSets { navigationRow(for: .sets) }
            } header: {
                Text("Library")
                    .contextMenu {
                        Toggle("Artists", isOn: $showsArtists)
                        Toggle("Sets", isOn: $showsSets)
                    }
            }

            Section {
                navigationRow(for: .playlists)

                if !playlists.yourItems.isEmpty {
                    playlistFolderRow(
                        title: "My Playlists",
                        count: playlists.yourItems.count,
                        section: .myPlaylists,
                        isExpanded: $areYourPlaylistsExpanded
                    )
                    if areYourPlaylistsExpanded {
                        ForEach(playlists.yourItems) { playlistRow($0) }
                    }
                }

                if !playlists.likedItems.isEmpty {
                    playlistFolderRow(
                        title: "Liked Playlists",
                        count: playlists.likedItems.count,
                        section: .likedPlaylists,
                        isExpanded: $areLikedPlaylistsExpanded
                    )
                    if areLikedPlaylistsExpanded {
                        ForEach(playlists.likedItems) { playlistRow($0) }
                    }
                }
            } header: {
                Text("Playlists")
            }

            Section(isExpanded: $isDiagnosticsExpanded) {
                navigationRow(for: .status)
            } header: {
                Text("Diagnostics")
            }
        }
        .listStyle(.sidebar)
        .tint(.scAccent)
    }

    private func navigationRow(for section: MacRootView.Section) -> some View {
        HStack(spacing: 7) {
            Image(systemName: section.symbol)
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.monochrome)
                .symbolVariant(selection == section ? .fill : .none)
                .foregroundStyle(Color.scAccent)
                .frame(width: 15, height: 15)
                .frame(width: 19, height: 20)

            Text(section.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
            let badge = badgeCount(for: section)
            if badge > 0 {
                Text("\(min(99, badge))")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.scAccent, in: Capsule())
                    .foregroundStyle(Color.white)
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .tag(section)
        .onTapGesture {
            selection = section
            if section == .messages { activityPoller.markAllRead(kind: .message) }
            if section == .followers { activityPoller.markAllRead(kind: .follower) }
        }
    }

    private func badgeCount(for section: MacRootView.Section) -> Int {
        switch section {
        case .messages: return activityPoller.unreadCount(kind: .message)
        case .followers: return activityPoller.unreadCount(kind: .follower)
        case .profile: return activityPoller.unreadCount
        default: return 0
        }
    }

    private func playlistFolderRow(
        title: String,
        count: Int,
        section: MacRootView.Section,
        isExpanded: Binding<Bool>
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: selection == section ? "folder.fill" : "folder")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.scAccent)
                .frame(width: 15, height: 15)
                .frame(width: 19, height: 20)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded.wrappedValue ? "Collapse \(title)" : "Expand \(title)")
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { selection = section }
        .tag(section)
    }

    @ViewBuilder
    private var accountFooter: some View {
        Button {
            if intelligenceStatus != nil {
                MacSettingsNavigation.shared.selection = .intelligence
            }
            openSettings()
        } label: {
            HStack(spacing: 8) {
                accountAvatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(credentials.currentUser?.displayName ?? "Please Sign In")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let status = intelligenceStatus ?? syncStatus {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text(status)
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    } else if credentials.isSignedOut {
                        Text("Guest mode")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if credentials.isReadOnlySession {
                        Text("Session expired · reauthenticate")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .macHoverRowHighlight()
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(MacVisualEffectBackground(role: .sidebar))
        .overlay(alignment: .top) { Divider() }
    }

    private var syncStatus: String? {
        if likesSync.isSyncing { return "Syncing \(likesSync.indexedCount) likes…" }
        if metadataSync.isSyncing { return metadataSync.statusText }
        return nil
    }

    private var intelligenceStatus: String? {
        if analysisIndex.isRefreshing { return "Indexing analysis…" }
        let states = analysisWork.states.values
        if states.contains(.analysing) { return "Analysing a track…" }
        let queued = states.reduce(0) { partial, state in
            if case .queued = state { return partial + 1 }
            return partial
        }
        if queued > 0 { return "\(queued) track\(queued == 1 ? "" : "s") queued for analysis" }
        return nil
    }

    @ViewBuilder
    private var accountAvatar: some View {
        if let url = credentials.currentUser?.avatarURL {
            ArtworkThumbnail(url: url, identity: credentials.currentUser?.displayName ?? "", size: 28, cornerRadius: 14)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 25))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }

    private func playlistRow(_ entry: SidebarPlaylistsModel.Entry) -> some View {
        HStack(spacing: 7) {
            Image(systemName: entry.playlist.isAlbum ? "square.stack" : "music.note.list")
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(selection == .playlist(id: entry.id) ? Color.white : Color.scAccent)
                .frame(width: 15, height: 15)
                .frame(width: 19, height: 20)
            Text(entry.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .tag(MacRootView.Section.playlist(id: entry.id))
    }
}

/// A glanceable mirror of the live manual decks. It only occupies sidebar
/// space while the Decks surface is open, then collapses back to the normal
/// account footer when the user leaves DJ mode.
private struct MacSidebarDeckDock: View {
    @ObservedObject private var controller = MacConsoleController.shared
    @ObservedObject private var registry = MacDeckTrackRegistry.shared
    @ObservedObject private var waveforms = WaveformService.shared
    @ObservedObject private var analysisWork = AutomaticAnalysisStatus.shared

    private let deckAColor = Color(red: 1.00, green: 0.478, blue: 0.157)
    private let deckBColor = Color(red: 0.486, green: 0.455, blue: 1.00)

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
                Text("DJ DECKS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                Spacer(minLength: 6)
                Text("LEFT  /  RIGHT")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            deckRow(.a, tint: deckAColor, side: "LEFT")
            deckRow(.b, tint: deckBColor, side: "RIGHT")

            MacEngineFader(
                value: { MixEngine.shared.crossfade },
                setValue: { MixEngine.shared.crossfade = $0 },
                publisher: MixEngine.shared.$crossfade.removeDuplicates().eraseToAnyPublisher(),
                tint: .white.opacity(0.8)
            )
            .frame(height: 12)
            .accessibilityLabel("Deck crossfader")
            .help("Crossfade between the left and right decks")
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(MacVisualEffectBackground(role: .sidebar))
        .overlay(alignment: .top) { Divider() }
    }

    private func deckRow(_ deck: MixEngine.Deck, tint: Color, side: String) -> some View {
        MacDeckSlice(deck: deck, read: SidebarDeckState.init) { state in
            let track = registry.track(for: deck)
            VStack(spacing: 5) {
                HStack(spacing: 7) {
                    Button {
                        controller.focusedDeck = deck
                        if track == nil { controller.loadTarget = deck }
                    } label: {
                        HStack(spacing: 7) {
                            deckBadge(deck, side: side, tint: tint)

                            ArtworkThumbnail(
                                url: track?.artworkURL,
                                identity: track?.title ?? "Deck \(deck.label)",
                                size: 32,
                                cornerRadius: 5,
                                isAvailable: track != nil
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track?.title ?? "Load a track")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(track == nil ? .secondary : .primary)
                                    .lineLimit(1)

                                deckStatus(deck, state: state, track: track, tint: tint)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(track == nil ? "Load the \(side.lowercased()) deck" : "Focus the \(side.lowercased()) deck")

                    if track != nil {
                        Button {
                            controller.togglePlayPause(deck)
                        } label: {
                            Image(systemName: controller.isPlayRequested(deck) ? "pause.fill" : "play.fill")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(tint.opacity(controller.isPlayRequested(deck) ? 0.22 : 0.10)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(controller.isPlayRequested(deck) ? tint : .secondary)
                        .help(
                            controller.isDeckReady(deck)
                                ? (controller.isPlayRequested(deck) ? "Pause Deck \(deck.label)" : "Play Deck \(deck.label)")
                                : (controller.isPlayRequested(deck) ? "Cancel queued playback" : "Play when loading finishes")
                        )
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .frame(width: 28, height: 28)
                    }
                }

                compactWaveform(deck, state: state, track: track, tint: tint)
                deckReadout(deck, state: state, track: track, tint: tint)
            }
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(controller.focusedDeck == deck ? 0.105 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(controller.focusedDeck == deck ? 0.42 : 0.12), lineWidth: 1)
            )
            .task(id: track?.id) {
                if let track { waveforms.load(track) }
            }
        }
    }

    private func compactWaveform(
        _ deck: MixEngine.Deck,
        state: SidebarDeckState,
        track: Track?,
        tint: Color
    ) -> some View {
        let waveformState = track.map { waveforms.state(for: $0.id) } ?? .pending
        let bpm = controller.analysisByDeck[deck.rawValue]?.bpm
        let cues = controller.hotCues[deck.rawValue] ?? []
        return SCWaveformRenderer(
            envelope: waveformEnvelope(waveformState),
            duration: state.duration,
            progress: state.progress,
            mode: .centered(windowSeconds: 14),
            beatGrid: bpm.flatMap { $0 > 20 ? SCBeatGrid(bpm: $0) : nil },
            cueMarkers: waveformMarkers(state: state, cues: cues),
            placeholder: waveformPlaceholder(waveformState),
            identity: track?.id,
            style: MacWaveformPalette.overview(for: deck)
        )
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.42)))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            Rectangle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        .help("Deck \(deck.label) waveform, beat grid, cues and loop points")
    }

    private func deckReadout(_ deck: MixEngine.Deck, state: SidebarDeckState, track: Track?, tint: Color) -> some View {
        let analysis = controller.analysisByDeck[deck.rawValue]
        let workState = track.flatMap { analysisWork.state(for: $0.id) }
        let pending = workState?.label ?? "---"
        return HStack(spacing: 6) {
            metric("BPM", analysis?.bpm.map { String(format: "%.1f", $0 * state.rate) } ?? pending, tint: tint)
            metric("KEY", analysis?.key?.label ?? (workState == nil ? "––" : pending), tint: tint)
            metric("TEMPO", String(format: "%+.1f%%", (state.rate - 1) * 100), tint: tint)
            if state.loopStartSeconds != nil {
                Text("LOOP")
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint))
            }
            Spacer(minLength: 2)
            Text("\(deckTime(state.position))  −\(deckTime(max(0, state.duration - state.position)))")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func metric(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(tint.opacity(0.9))
        }
        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
        .lineLimit(1)
    }

    private func waveformMarkers(state: SidebarDeckState, cues: [CuePoint]) -> [SCWaveformMarker] {
        guard state.duration > 0 else { return [] }
        var markers = cues.map { cue in
            SCWaveformMarker(
                id: cue.id,
                position: cue.positionSeconds / state.duration,
                color: macCueColor(cue),
                label: cue.hotCueIndex.map { String($0 + 1) }
            )
        }
        if let start = state.loopStartSeconds {
            markers.append(SCWaveformMarker(id: "sidebar-loop-in", position: start / state.duration, color: .white))
            if let length = state.loopLengthSeconds {
                markers.append(SCWaveformMarker(id: "sidebar-loop-out", position: (start + length) / state.duration, color: .white))
            }
        }
        return markers
    }

    private func waveformEnvelope(_ state: WaveformState) -> [Float] {
        guard case .ready(let waveform) = state else { return [] }
        return waveform.samples
    }

    private func waveformPlaceholder(_ state: WaveformState) -> SCWaveformPlaceholder {
        switch state {
        case .pending, .loading: return .loading
        case .ready(let waveform): return waveform.isEmpty ? .unavailable : .loading
        case .failed: return .unavailable
        }
    }

    private func deckTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func deckBadge(_ deck: MixEngine.Deck, side: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            Text(deck.label)
                .font(.system(size: 11, weight: .black, design: .monospaced))
            Text(side)
                .font(.system(size: 5.5, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(.black)
        .frame(width: 29, height: 29)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint))
    }

    @ViewBuilder
    private func deckStatus(
        _ deck: MixEngine.Deck,
        state: SidebarDeckState,
        track: Track?,
        tint: Color
    ) -> some View {
        if let error = registry.loadError(for: deck) {
            Text(error)
                .foregroundStyle(Color.red.opacity(0.85))
        } else if registry.isLoading(deck), state.trackID != track?.id {
            Text(controller.isPlayRequested(deck) ? "Play queued · Preparing…" : "Preparing track…")
                .foregroundStyle(tint.opacity(0.85))
        } else {
            switch state.status {
            case .loading(let fraction):
                HStack(spacing: 5) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .frame(maxWidth: 48)
                    Text("\(controller.isPlayRequested(deck) ? "Play queued · " : "")Loading \(Int((fraction * 100).rounded()))%")
                }
                .foregroundStyle(tint.opacity(0.85))
            case .ready:
                Text(state.isPlaying ? "Playing" : "Ready")
                    .foregroundStyle(state.isPlaying ? tint : .secondary)
            case .failed(let reason):
                Text(reason)
                    .foregroundStyle(Color.red.opacity(0.85))
            case .empty:
                Text(track == nil ? "Empty" : "Preparing track…")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private struct SidebarDeckState: Equatable {
        let status: MixEngine.LoadStatus
        let isPlaying: Bool
        let trackID: String?
        let position: TimeInterval
        let duration: TimeInterval
        let rate: Double
        let loopStartSeconds: Double?
        let loopLengthSeconds: Double?

        init(_ state: MixEngine.DeckState) {
            status = state.status
            isPlaying = state.isPlaying
            trackID = state.trackId
            position = state.position
            duration = state.duration
            rate = state.rate
            loopStartSeconds = state.loopStartSeconds
            loopLengthSeconds = state.loopLengthSeconds
        }

        var progress: Double {
            guard duration > 0 else { return 0 }
            return max(0, min(1, position / duration))
        }
    }
}

private struct MacTVCompanionView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @EnvironmentObject private var client: CompanionClient

    @StateObject private var offerBrowser = LinkOfferBrowser()
    @StateObject private var authorizer = CompanionLinker()
    @ObservedObject private var companionRegistry = CompanionRegistry.shared
    @State private var handshake: LinkConfirmationHandshake?
    @State private var cloudOffer: LinkOffer?
    @State private var errorMessage: String?
    @State private var showingForgetConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            MacPaneHeader(title: "Companion", subtitle: statusSubtitle) {
                if client.isLinked {
                    Button {
                        client.retry()
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !client.isLinked {
                        authorizationSection
                    } else {
                        devicesSection
                        connectionSection
                        nowPlayingSection
                        sharedDJSection
                        queueSection
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
        }
        .task {
            credentials.refreshFromStore()
            refreshCloudOffer()
            if client.isLinked { client.connect() } else { offerBrowser.start() }
        }
        .task {
            while !Task.isCancelled {
                refreshCloudOffer()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .onChange(of: client.isLinked) { _, isLinked in
            if isLinked {
                offerBrowser.stop()
                cloudOffer = nil
                client.connect()
            } else {
                offerBrowser.start()
            }
        }
        .onChange(of: authorizer.state) { _, state in
            if case .failed(let message) = state { errorMessage = message }
        }
        .sheet(isPresented: Binding(
            get: { handshake != nil },
            set: { shown in
                if !shown {
                    handshake?.stop()
                    handshake = nil
                }
            }
        )) {
            if let handshake {
                MacNumericComparisonView(handshake: handshake) { sessionId, secret, tvName in
                    self.handshake = nil
                    authorize(sessionId: sessionId, secret: secret, tvName: tvName)
                }
                .frame(width: 500, height: 430)
            }
        }
        .alert("Companion", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Forget this \(client.linkedClass.displayName)?", isPresented: $showingForgetConfirmation) {
            Button("Forget \(client.linkedClass.displayName)", role: .destructive) {
                client.disconnect()
                LinkedCompanionStore.clear()
                authorizer.reset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to authorise it again before this Mac can control it.")
        }
    }

    private var statusSubtitle: String {
        if authorizer.state.isWorking { return authorizerLabel }
        switch client.state {
        case .connected: return "Connected to your \(client.linkedClass.displayName)"
        case .searching: return "Looking on the local network…"
        case .connecting: return "Connecting securely…"
        case .failed(let message): return message
        case .idle: return client.isLinked ? "Ready to connect" : "Authorise and control another device"
        case .unlinked: return "Authorise and control another device"
        }
    }

    @ViewBuilder
    private var authorizationSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let phone = pairedPhone {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "iphone")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.scAccent)
                        .frame(width: 56, height: 56)
                        .background(Color.scAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Share with \(phone.displayName)")
                            .font(.title3.weight(.semibold))
                        Text("This iPhone is signed into the same SoundingCloud session. While the app is open, its playback, queue and DJ state can be controlled here.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("Connect") {
                        client.connectToSharedPhone(named: phone.displayName)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider()
            }

            HStack(alignment: .top, spacing: 16) {
                Image(systemName: offerBrowser.offer?.kind.symbolName ?? "macbook.and.appletv")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.scAccent)
                    .frame(width: 56, height: 56)
                    .background(Color.scAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Authorise an Apple TV")
                        .font(.title3.weight(.semibold))
                    Text("Open the SoundingCloud sign-in screen on Apple TV. This Mac approves it the same way iPhone does.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            if credentials.isSignedOut {
                Label("This Mac needs a synced SoundCloud account before it can authorise the TV.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
            } else if let nearby = offerBrowser.offer {
                Button {
                    handshake = LinkConfirmationHandshake(offer: nearby)
                } label: {
                    Label("Confirm \(nearby.displayIdentity)", systemImage: "number.square")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if let cloudOffer, cloudOffer.secret != nil {
                Button {
                    authorize(offer: cloudOffer)
                } label: {
                    Label("Authorise \(cloudOffer.tvName)", systemImage: "checkmark.shield.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting for an Apple TV")
                            .font(.headline)
                        Text("The approval request will appear here automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if authorizer.state.isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(authorizerLabel)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var pairedPhone: CompanionDeviceRecord? {
        companionRegistry.peers.first { $0.deviceClass == .phone || $0.deviceClass == .pad }
    }

    @ViewBuilder
    private var devicesSection: some View {
        if !companionRegistry.devices.isEmpty {
            GroupBox("Devices") {
                VStack(spacing: 0) {
                    ForEach(companionRegistry.devices, id: \.deviceId) { record in
                        deviceRow(record)
                        if record.deviceId != companionRegistry.devices.last?.deviceId { Divider() }
                    }
                }
            }
        }
    }

    private func deviceRow(_ record: CompanionDeviceRecord) -> some View {
        HStack(spacing: 14) {
            Image(systemName: record.deviceClass.symbolName)
                .font(.system(size: 20))
                .foregroundStyle(deviceStatusColor(for: record))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(.headline)
                Text(deviceStatusText(for: record))
                    .font(.caption)
                    .foregroundStyle(deviceStatusColor(for: record))
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
    }

    private func deviceStatusText(for record: CompanionDeviceRecord) -> String {
        var status: String
        if record.deviceClass == client.linkedClass && client.isReachable {
            status = "Connected"
        } else if record.deviceId == companionRegistry.localDeviceId {
            status = "This Mac"
        } else {
            status = "Last seen \(record.lastSeenAt.formatted(.relative(presentation: .named)))"
        }
        if record.deviceClass.hasBattery, let batteryFraction = record.conditions.batteryFraction {
            status += " · \(Int((batteryFraction * 100).rounded()))%"
        }
        return status
    }

    private func deviceStatusColor(for record: CompanionDeviceRecord) -> Color {
        (record.deviceClass == client.linkedClass && client.isReachable) ? Color.green : Color.secondary
    }

    private var connectionSection: some View {
        GroupBox("Connection") {
            HStack(spacing: 14) {
                Image(systemName: client.linkedClass.symbolName)
                    .font(.system(size: 32))
                    .foregroundStyle(client.isReachable ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(client.isReachable ? "\(client.linkedName) connected" : "\(client.linkedName) paired")
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if client.isSharingWithPhone {
                    Button("Disconnect") { client.stopSharingWithPhone() }
                } else {
                    Button("Forget…", role: .destructive) { showingForgetConfirmation = true }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var nowPlayingSection: some View {
        GroupBox("Now Playing on \(client.linkedClass.displayName)") {
            if let playback = client.playback, playback.trackId != nil {
                HStack(spacing: 16) {
                    ArtworkThumbnail(
                        url: playback.artworkURL.flatMap(URL.init(string:)),
                        identity: playback.title ?? "Now Playing",
                        size: 72,
                        cornerRadius: 10
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playback.title ?? "Unknown Track")
                            .font(.headline)
                            .lineLimit(1)
                        Text(playback.artist ?? "Unknown Artist")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { client.previous() } label: { Image(systemName: "backward.fill") }
                    Button { playback.isPlaying ? client.pause() : client.play() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { client.next() } label: { Image(systemName: "forward.fill") }
                }
                .controlSize(.large)
                .padding(8)
            } else {
                ContentUnavailableView(
                    "Nothing Playing",
                    systemImage: "music.note",
                    description: Text("Start something on the TV and its controls will appear here.")
                )
                .frame(minHeight: 150)
            }
        }
    }

    @ViewBuilder
    private var queueSection: some View {
        if !client.tracks.isEmpty {
            GroupBox("Up Next") {
                VStack(spacing: 0) {
                    ForEach(Array(client.tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            client.jump(to: index)
                        } label: {
                            HStack {
                                Image(systemName: index == client.currentIndex ? "speaker.wave.2.fill" : "music.note")
                                    .foregroundStyle(index == client.currentIndex ? Color.accentColor : Color.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title).lineLimit(1)
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(track.formattedDuration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < client.tracks.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sharedDJSection: some View {
        if let dj = client.djState {
            GroupBox("DJ on \(client.linkedName)") {
                HStack(spacing: 18) {
                    Label(dj.isEnabled ? "DJ on" : "DJ off", systemImage: "slider.horizontal.3")
                    Label(dj.isAutoMixEnabled ? "AutoMix on" : "AutoMix off", systemImage: "arrow.triangle.2.circlepath")
                    if dj.isEngineLive {
                        Label("Mixing live", systemImage: "waveform.path.ecg")
                    }
                    Spacer()
                    Toggle("DJ", isOn: Binding(
                        get: { dj.isEnabled },
                        set: { client.setDJEnabled($0) }
                    ))
                    .labelsHidden()
                    Toggle("AutoMix", isOn: Binding(
                        get: { dj.isAutoMixEnabled },
                        set: { client.setAutoMixEnabled($0) }
                    ))
                    .labelsHidden()
                }
                .padding(8)
            }
        }
    }

    private var authorizerLabel: String {
        switch authorizer.state {
        case .idle: return "Ready"
        case .findingTV: return "Finding Apple TV…"
        case .connecting: return "Connecting securely…"
        case .transferring: return "Authorising Apple TV…"
        case .completed(let name): return "\(name) authorised"
        case .failed(let message): return message
        }
    }

    private func refreshCloudOffer() {
        guard !client.isLinked else {
            cloudOffer = nil
            return
        }
        cloudOffer = LinkOfferStore.fetchLatest()
    }

    private func authorize(offer: LinkOffer) {
        guard let session = usableSession() else { return }
        Task { await authorizer.authorize(offer: offer, session: session) }
    }

    private func authorize(sessionId: String, secret: Data, tvName: String) {
        guard let session = usableSession() else { return }
        Task {
            await authorizer.authorize(
                sessionId: sessionId,
                secret: secret,
                tvName: tvName,
                session: session
            )
        }
    }

    private func usableSession() -> StoredSession? {
        guard let session = DeviceSessionStore.load(), session.isUsable else {
            errorMessage = "Sign in to SoundCloud on this Mac, or let iCloud sync a session from another device, then authorise the TV."
            return nil
        }
        return session
    }
}

private struct MacNumericComparisonView: View {
    @ObservedObject var handshake: LinkConfirmationHandshake
    let onPaired: (String, Data, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            Text("Confirm Apple TV")
                .font(.title2.weight(.bold))

            switch handshake.state {
            case .idle, .connecting:
                ProgressView("Connecting…")
            case .awaitingComparison(let code):
                Text("Does this match the code on \(handshake.claimedName)? If it doesn't, someone else on this network is asking, and you should decline.")
                    .multilineTextAlignment(.center)
                Text(grouped(code))
                    .font(.system(size: 42, weight: .bold, design: .rounded).monospacedDigit())
                    .tracking(5)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Button("It Doesn't Match", role: .destructive) {
                        handshake.decline()
                        dismiss()
                    }
                    Button("Yes, It Matches") { handshake.confirm() }
                        .buttonStyle(.borderedProminent)
                }
            case .confirming, .succeeded:
                ProgressView("Finishing secure link…")
            case .failed(let message):
                ContentUnavailableView("Could Not Pair", systemImage: "exclamationmark.triangle", description: Text(message))
                Button("Close") { dismiss() }
            case .declined:
                EmptyView()
            }
        }
        .padding(32)
        .onAppear { handshake.start() }
        .onChange(of: handshake.state) { _, state in
            if case .succeeded(let sessionId, let secret, let tvName) = state {
                onPaired(sessionId, secret, tvName)
            }
        }
    }

    private func grouped(_ code: String) -> String {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return code }
        let split = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[..<split])  \(digits[split...])"
    }
}

private struct StatusPane: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var sync = MacSyncCoordinator.shared
    @ObservedObject private var activityPoller = SoundCloudActivityPoller.shared

    var body: some View {
        Form {
            SwiftUI.Section("Account") {
                LabeledContent("SoundCloud") {
                    if credentials.isSessionRejected {
                        Text("Session expired — reauthentication required").foregroundStyle(.orange)
                    } else if credentials.isSignedOut {
                        Text("Please Sign In").foregroundStyle(.secondary)
                    } else if let user = credentials.currentUser {
                        Text(user.username)
                    } else {
                        Text("Loading profile…").foregroundStyle(.secondary)
                    }
                }
                Text(
                    """
                    The Mac shares the account rather than holding its own. \
                    Per-device OAuth needs a client_id with a custom-scheme \
                    redirect_uri this project doesn't have, so a second \
                    independently-refreshable token isn't possible. See \
                    Design/specs/macos-plan.md §4.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            SwiftUI.Section("Audio output") {
                LabeledContent("Device", value: PlatformAudioSession.outputName ?? "None")
                LabeledContent("Transport", value: PlatformAudioSession.outputKind.rawValue)
                LabeledContent("Output channels", value: "\(PlatformAudioSession.maximumOutputChannels)")
                LabeledContent("Separate cue bus") {
                    Text(PlatformAudioSession.supportsSeparateCueBus ? "Possible (4+ outputs)" : "Not possible (stereo only)")
                        .foregroundStyle(PlatformAudioSession.supportsSeparateCueBus ? .primary : .secondary)
                }
            }

            SwiftUI.Section("Cloud sync") {
                LabeledContent(
                    "Runtime entitlement",
                    value: CloudSyncEngineController.containerIdentifierIsEntitled(CloudSyncContainer.identifier)
                        ? "Available"
                        : "Missing from this build"
                )
                LabeledContent("Container", value: CloudSyncContainer.identifier)
                LabeledContent("Last attempt") {
                    if let date = sync.lastAttemptAt { Text(date, style: .relative) }
                    else { Text("Not yet").foregroundStyle(.secondary) }
                }
                LabeledContent("Last successful sync") {
                    if let date = sync.lastSuccessfulRunAt { Text(date, style: .relative) }
                    else { Text("Not yet").foregroundStyle(.secondary) }
                }
                if let failure = sync.failureMessage {
                    Text(failure).font(.footnote).foregroundStyle(.orange)
                }
                Button("Run Sync Diagnostics") { Task { await sync.runOnce() } }
            }

            SwiftUI.Section("SoundCloud activity") {
                LabeledContent("Unread inbox events", value: "\(activityPoller.unreadCount)")
                LabeledContent("Last successful poll") {
                    if let date = activityPoller.lastSuccessfulPoll { Text(date, style: .relative) }
                    else { Text("Not yet").foregroundStyle(.secondary) }
                }
                LabeledContent("Circuit breaker") {
                    if let date = activityPoller.circuitOpenUntil, date > Date() {
                        Text("Paused until \(date.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Closed")
                    }
                }
                Text("Feed, follower, and message cursors are encrypted per SoundCloud account. First polling establishes a baseline and emits no old notifications.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HardwarePane: View {
    @EnvironmentObject private var midi: MIDIControllerHub

    @State private var lastRaw: MIDIRawMessage?
    @State private var rawCount = 0

    var body: some View {
        Form {
            SwiftUI.Section("MIDI controllers") {
                if let error = midi.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if midi.controllers.isEmpty {
                    Text("No MIDI devices connected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(midi.controllers) { controller in
                        LabeledContent(controller.name) {
                            Text(controller.hasMapping ? "Mapped (DDJ-400)" : "Unmapped")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            SwiftUI.Section("Raw MIDI monitor") {
                Text(
                    """
                    Wiggle a control on the connected device. Every message \
                    CoreMIDI delivers shows here, mapped or not. This isn't \
                    the mapping editor Design/specs/macos-plan.md §3.4 \
                    describes (nothing here can be assigned to a control \
                    yet). It's the fastest way to confirm the hardware is \
                    seen at all, before wondering why a fader does nothing.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let lastRaw {
                    LabeledContent("Last message", value: Self.describe(lastRaw))
                    LabeledContent("Messages seen", value: "\(rawCount)")
                } else {
                    Text("No MIDI traffic yet.")
                        .foregroundStyle(.secondary)
                }
            }

            SwiftUI.Section("CDJs") {
                Text(
                    """
                    Pioneer/AlphaTheta CDJs aren't supported and can't be. \
                    They speak Pro DJ Link, a proprietary Ethernet protocol \
                    with no public SDK, and they play audio from their own \
                    media, so there's no way to hand one a SoundCloud \
                    stream. DDJ-class USB controllers work over MIDI, and \
                    they're what this app talks to.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Hardware")
        .onReceive(midi.rawMessages) { message in
            lastRaw = message
            rawCount += 1
        }
    }

    private static func describe(_ message: MIDIRawMessage) -> String {
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
    case downloads = "Downloads"
    case intelligence = "Intelligence"
    case diagnostics = "Diagnostics"
    case advanced = "Advanced"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .account: return "person.crop.circle"
        case .playback: return "play.circle"
        case .downloads: return "arrow.down.circle"
        case .intelligence: return "waveform.badge.magnifyingglass"
        case .diagnostics: return "stethoscope"
        case .advanced: return "gearshape.2"
        }
    }
}

@MainActor
final class MacSettingsNavigation: ObservableObject {
    static let shared = MacSettingsNavigation()
    @Published var selection: MacSettingsPane = .account
    private init() {}
}

struct MacSettingsView: View {
    @ObservedObject private var navigation = MacSettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.selection) {
            Tab("Account", systemImage: MacSettingsPane.account.symbol, value: MacSettingsPane.account) {
                MacSettingsAccountTab()
            }
            Tab("Playback", systemImage: MacSettingsPane.playback.symbol, value: MacSettingsPane.playback) {
                MacSettingsAudioTab()
            }
            Tab("Downloads", systemImage: MacSettingsPane.downloads.symbol, value: MacSettingsPane.downloads) {
                MacSettingsDownloadsTab()
            }
            Tab("Intelligence", systemImage: MacSettingsPane.intelligence.symbol, value: MacSettingsPane.intelligence) {
                MacIntelligenceView(model: MacIntelligenceModel())
            }
            Tab("Diagnostics", systemImage: MacSettingsPane.diagnostics.symbol, value: MacSettingsPane.diagnostics) {
                StatusPane()
            }
            Tab("Advanced", systemImage: MacSettingsPane.advanced.symbol, value: MacSettingsPane.advanced) {
                MacSettingsAdvancedTab()
            }
        }
        .tint(.scAccent)
        .background(MacWindowChrome().frame(width: 0, height: 0))
        .frame(width: 680, height: 560)
    }
}

#if DEBUG
extension MacRootView {
    @MainActor
    fileprivate static func snapshotRoot(to path: String) async {
        let env = ProcessInfo.processInfo.environment
        let width = env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_WIDTH"].flatMap(Double.init) ?? 1040
        let height = env["SOUNDING_TV_MAC_ROOT_SNAPSHOT_HEIGHT"].flatMap(Double.init) ?? 692

        let section = Section.debugInitial()
        let harness = Group {
            switch section {
            case .console: MacConsoleView()
            case .intelligence: MacIntelligenceView(model: MacIntelligenceModel()).environmentObject(SoundCloudCredentialSource.shared)
            case .library: MacLibraryPaneView(model: MacLibraryModel()).environmentObject(SoundCloudCredentialSource.shared)
            case .likes: MacLibraryPaneView(model: MacLibraryModel(mode: .liked), pinnedMode: .liked).environmentObject(SoundCloudCredentialSource.shared)
            case .home: MacHomeView(source: DiscoveryHomeSource(), feedModel: FeedViewModel()).environmentObject(SoundCloudCredentialSource.shared)
            case .playlists: MacPlaylistsView(model: MacPlaylistsModel()).environmentObject(SoundCloudCredentialSource.shared)
            case .account: MacSettingsView().environmentObject(SoundCloudCredentialSource.shared)
            default: MacConsoleView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())

        let renderer = ImageRenderer(
            content: harness
                .frame(width: width, height: height)
        )
        renderer.scale = 2
        for _ in 0..<6 {
            _ = renderer.nsImage
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            Log.ui.error("ROOT_SNAPSHOT FAIL: could not rasterise view")
            return
        }

        if path == "-" {
            print("[ROOT_SNAPSHOT_B64]\(png.base64EncodedString())")
            Log.ui.info("ROOT_SNAPSHOT emitted \(png.count, privacy: .public) bytes at \(Int(width), privacy: .public)x\(Int(height), privacy: .public)")
            return
        }

        do {
            try png.write(to: URL(fileURLWithPath: path))
            Log.ui.info("ROOT_SNAPSHOT wrote \(path, privacy: .public) at \(Int(width), privacy: .public)x\(Int(height), privacy: .public)")
        } catch {
            Log.ui.error("ROOT_SNAPSHOT FAIL writing file: \(error.localizedDescription, privacy: .public)")
        }
    }
}

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
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
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
