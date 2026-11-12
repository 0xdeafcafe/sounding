import SwiftUI
import Combine
import os

extension Int {
    var trackCountLabel: String { self == 1 ? "1 track" : "\(self) tracks" }
}

@MainActor
final class ArtistRouter: ObservableObject {
    @Published var path = NavigationPath() {
        didSet { if path.isEmpty { rootArtist = nil } }
    }
    @Published private(set) var rootArtist: User?
    var redirect: @MainActor (User) -> Bool = { _ in false }

    var redirectPlaylist: @MainActor (Playlist) -> Bool = { _ in false }

    func open(_ user: User) {
        if redirect(user) { return }
        if path.isEmpty { rootArtist = user }
        path.append(user)
    }

    func open(album: Playlist) {
        if redirectPlaylist(album) { return }
        path.append(LibraryCollectionRoute.playlist(album))
    }

    func open(social section: SocialSection) {
        path.append(section)
    }
}

@MainActor
@Observable
final class SidebarNavigator {
    private(set) var available: Set<PhoneRootView.PhoneTab> = []
    var pendingPlaylist: Playlist?
    @ObservationIgnored var playlistIDs: Set<String> = []
    @ObservationIgnored var sidebarPlaylistIDs: Set<String> = []
    @ObservationIgnored var select: (PhoneRootView.PhoneTab) -> Void = { _ in }
    @ObservationIgnored var insert: (Playlist) -> Void = { _ in }

    func update(available next: Set<PhoneRootView.PhoneTab>) {
        if next != available { available = next }
    }

    func opens(_ tab: PhoneRootView.PhoneTab) -> Bool {
        if case .playlist(let id) = tab {
            return available.contains(.playlists) && (playlistIDs.contains(id) || sidebarPlaylistIDs.contains(id))
        }
        return available.contains(tab)
    }

    func hasOwnItem(_ playlist: Playlist) -> Bool {
        sidebarPlaylistIDs.contains(playlist.id)
    }

    func redirects(_ playlist: Playlist, from hostTab: PhoneRootView.PhoneTab?) -> Bool {
        if case .playlist(let id) = hostTab, id == playlist.id { return false }
        guard opens(.playlist(playlist.id)) else { return false }
        return hostTab != .playlists || hasOwnItem(playlist)
    }

    func open(_ tab: PhoneRootView.PhoneTab) { select(tab) }

    func open(_ playlist: Playlist) {
        if hasOwnItem(playlist) {
            select(.playlist(playlist.id))
            return
        }
        pendingPlaylist = playlist
        select(.playlists)
    }
}

struct SidebarPendingPlaylistDestination: ViewModifier {
    @Environment(\.sidebarNavigator) private var navigator
    @Environment(\.artistRouter) private var router

    func body(content: Content) -> some View {
        content
            .onAppear(perform: openPending)
            .onChange(of: navigator?.pendingPlaylist?.id) { _, _ in openPending() }
    }

    private func openPending() {
        guard let navigator, let router, let playlist = navigator.pendingPlaylist else { return }
        navigator.pendingPlaylist = nil
        var path = NavigationPath()
        path.append(LibraryCollectionRoute.playlist(playlist))
        router.path = path
    }
}

struct SidebarLink<Destination: View, Label: View>: View {
    let tab: PhoneRootView.PhoneTab
    let isListRow: Bool
    let onOpen: (() -> Void)?
    let destination: () -> Destination
    let label: () -> Label

    @Environment(\.sidebarNavigator) private var navigator

    init(
        tab: PhoneRootView.PhoneTab,
        isListRow: Bool = false,
        onOpen: (() -> Void)? = nil,
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.tab = tab
        self.isListRow = isListRow
        self.onOpen = onOpen
        self.destination = destination
        self.label = label
    }

    var body: some View {
        if let navigator, navigator.opens(tab) {
            SidebarLinkButton(isListRow: isListRow, action: {
                onOpen?()
                navigator.open(tab)
            }, label: label)
        } else {
            NavigationLink {
                destination().onAppear { onOpen?() }
            } label: {
                label()
            }
        }
    }
}

struct SidebarLinkButton<Label: View>: View {
    let isListRow: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        if isListRow {
            Button(action: action) {
                HStack(spacing: Space.tight) {
                    label()
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Button(action: action, label: label)
        }
    }
}

struct PlaylistPageRoute: Hashable {
    let playlist: Playlist
    let zoom: Namespace.ID
}

struct PlaylistLink<Label: View>: View {
    let playlist: Playlist
    let heroNamespace: Namespace.ID
    let isListRow: Bool
    let onOpen: (() -> Void)?
    let label: () -> Label

    @Environment(\.sidebarNavigator) private var navigator

    init(
        _ playlist: Playlist,
        heroNamespace: Namespace.ID,
        isListRow: Bool = false,
        onOpen: (() -> Void)? = nil,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.playlist = playlist
        self.heroNamespace = heroNamespace
        self.isListRow = isListRow
        self.onOpen = onOpen
        self.label = label
    }

    @Environment(\.sidebarHostTab) private var hostTab

    var body: some View {
        if let navigator, navigator.redirects(playlist, from: hostTab) {
            SidebarLinkButton(isListRow: isListRow, action: {
                onOpen?()
                navigator.open(playlist)
            }, label: label)
        } else {
            NavigationLink(value: PlaylistPageRoute(playlist: playlist, zoom: heroNamespace)) {
                label()
            }
            .simultaneousGesture(TapGesture().onEnded { onOpen?() }, including: onOpen == nil ? .subviews : .all)
        }
    }
}

private struct ArtistRouterKey: EnvironmentKey {
    static let defaultValue: ArtistRouter? = nil
}

private struct PresentArtistKey: EnvironmentKey {
    static let defaultValue: @MainActor (User) -> Void = { _ in }
}

extension EnvironmentValues {
    var artistRouter: ArtistRouter? {
        get { self[ArtistRouterKey.self] }
        set { self[ArtistRouterKey.self] = newValue }
    }

    var presentArtist: @MainActor (User) -> Void {
        get { self[PresentArtistKey.self] }
        set { self[PresentArtistKey.self] = newValue }
    }

    @Entry var sidebarNavigator: SidebarNavigator?
    @Entry var sidebarHostTab: PhoneRootView.PhoneTab?
}

enum SceneRestoration {
    static func encode<Route: Encodable>(_ route: Route?) -> Data? {
        route.flatMap { try? JSONEncoder().encode($0) }
    }

    static func decode<Route: Decodable>(_ data: Data?, as type: Route.Type) -> Route? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

struct ArtistRoutingStack<Root: View>: View {
    @StateObject private var router = ArtistRouter()
    @SceneStorage private var storedArtist: Data?
    @Environment(\.sidebarNavigator) private var navigator
    @Environment(\.sidebarHostTab) private var hostTab
    @ViewBuilder let root: () -> Root
    private let opensPageLinks: Bool

    init(restorationKey: String, @ViewBuilder root: @escaping () -> Root) {
        _storedArtist = SceneStorage("red.forbes.sounding.scene.path.\(restorationKey)")
        opensPageLinks = restorationKey == "home"
        self.root = root
    }

    private func openPageLink(_ request: SoundingPageLinkRouter.Request) {
        guard opensPageLinks else { return }
        switch request.page {
        case .track:
            return
        case .artist, .playlist:
            break
        }
        switch SoundingPageLinkRouter.shared.take(request) {
        case .artist(let user):
            router.open(user)
        case .playlist(let playlist):
            router.open(album: playlist)
        case .track, nil:
            break
        }
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            root()
                .navigationDestination(for: SocialSection.self) { SocialSectionView(section: $0) }
                .appNavigationDestinations()
        }
        .environment(\.artistRouter, router)
        .onAppear {
            router.redirect = { [navigator] user in
                guard let navigator, navigator.opens(.profile),
                      user.id == SoundCloudCredentialSource.shared.currentUser?.id else { return false }
                navigator.open(.profile)
                return true
            }
            router.redirectPlaylist = { [navigator, hostTab] playlist in
                guard let navigator, navigator.redirects(playlist, from: hostTab) else { return false }
                navigator.open(playlist)
                return true
            }
            guard router.path.isEmpty,
                  let restored = SceneRestoration.decode(storedArtist, as: User.self) else { return }
            router.open(restored)
        }
        .onChange(of: router.rootArtist) { _, artist in
            storedArtist = SceneRestoration.encode(artist)
        }
        .onReceive(SoundingPageLinkRouter.shared.$pending.compactMap { $0 }) { request in
            openPageLink(request)
        }
        #if DEBUG
        .task {
            guard VisualFixtures.isEnabled, router.path.isEmpty,
                  ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_ARTIST"] == "1" else { return }
            router.open(VisualFixtures.artists[0])
        }
        #endif
    }
}

extension User {
    var followersLabel: String { followersCount == 1 ? "1 follower" : "\(formattedFollowers) followers" }
}

extension String {
    func scLocallyContains(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .contains(needle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))
    }
}

struct LibraryIndexLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Space.snug) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: PhoneLayout.listIconWidth)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.vertical, Space.hair)
        .alignmentGuide(.listRowSeparatorLeading) { _ in PhoneLayout.listIconWidth + Space.snug }
    }
}

struct LibraryBrowserView: View {
    @ObservedObject private var viewModel: LibraryBrowserViewModel
    @ObservedObject private var confirmation: QueueConfirmationController
    @ObservedObject private var analysisStore: TrackAnalysisStore
    @ObservedObject private var recentlyAdded: RecentlyAddedModel
    private let models: LibraryModels
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsMixes = ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_TAB"] == "mixes"
    @State private var showsDecks = false
    @State private var showsSongs = false
    @State private var pushedSection: LibraryBrowserViewModel.Section?
    @State private var isEditingRows = false
    @AppStorage(LibraryRowChoices.storageKey) private var libraryRowsRaw = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(models: LibraryModels) {
        self.models = models
        _viewModel = ObservedObject(wrappedValue: models.viewModel)
        _confirmation = ObservedObject(wrappedValue: models.confirmation)
        _analysisStore = ObservedObject(wrappedValue: models.analysisStore)
        _recentlyAdded = ObservedObject(wrappedValue: models.recentlyAdded)
    }

    var body: some View {
        libraryIndex
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { indexToolbar }
        .task { await recentlyAdded.load() }
        .task(id: hasSoundCloud) {
            await credentials.prepareStoreAtLaunch()
            guard hasSoundCloud else { return }
            await viewModel.loadContent(for: .playlists)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            credentials.refreshFromStore()
        }
        .onChange(of: credentials.sessionHealth) { oldHealth, newHealth in
            guard newHealth.needsSignIn, !oldHealth.needsSignIn else { return }
            Task { await viewModel.handleSignOut() }
        }
        .sheet(isPresented: $isEditingRows) { LibraryRowsEditor() }
        .navigationDestination(isPresented: $showsMixes) { MixHistoryView() }
        .navigationDestination(isPresented: $showsSongs) {
            LibrarySongsView(viewModel: viewModel, analysisStore: analysisStore, confirmation: confirmation)
        }
        .navigationDestination(item: $pushedSection) { section in
            SoundCloudSectionGate(section: section) {
                LibrarySectionDetailView(
                    section: section, viewModel: viewModel, analysisStore: analysisStore, confirmation: confirmation
                )
            }
        }
        #if DEBUG
        .task {
            guard !PadLayout.isPad, let tab = ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_TAB"] else { return }
            try? await Task.sleep(for: .milliseconds(700))
            if tab == "songs" { showsSongs = true }
            if tab == LibraryBrowserViewModel.Section.sets.rawValue { pushedSection = .sets }
        }
        #endif
    }

    private var hasSoundCloud: Bool { credentials.showsSoundCloudLibrary }

    @ToolbarContentBuilder
    private var indexToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Edit") { isEditingRows = true }
        }
        AccountToolbarItem()
    }

    private var libraryIndex: some View {
        List {
            Section {
                ForEach(LibraryRowChoices(raw: libraryRowsRaw).visible(on: .phoneList)) { row in
                    libraryRow(row)
                }
            }
            .listSectionSeparator(.hidden, edges: .top)

            recentlyAddedSection
        }
        .listStyle(.plain)
        .refreshable {
            guard hasSoundCloud else { return }
            await viewModel.loadContent(for: .playlists, forceRefresh: true)
        }
    }

    @ViewBuilder
    private var recentlyAddedSection: some View {
        if !recentlyAdded.items.isEmpty {
            Section {
                RecentlyAddedFeedGrid(
                    items: Array(recentlyAdded.items.prefix(6)),
                    allItems: recentlyAdded.items,
                    models: models,
                    minimumTile: dynamicTypeSize.isAccessibilitySize ? 280 : 160
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: Space.tight, leading: PhoneLayout.margin, bottom: Space.section, trailing: PhoneLayout.margin))
            } header: {
                NavigationLink {
                    LibraryRecentlyAddedView(models: models)
                } label: {
                    HStack(spacing: Space.hair) {
                        PhoneSectionTitle(title: "Recently Added")
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .headerProminence(.increased)
        }
    }

    @ViewBuilder
    private func libraryRow(_ row: LibraryPageRow) -> some View {
        switch row {
        case .tracks: songsRow
        case .albums: collectionsRow(models.albums)
        case .artists: collectionsRow(models.artists)
        case .sets: indexRow(.sets, icon: LibraryPageRow.sets.symbol)
        case .downloads: downloadsRow
        case .mixes: mixesRow
        case .decks: decksRow
        case .stations:
            NavigationLink {
                StationsView()
            } label: {
                LibraryIndexLabel(title: LibraryPageRow.stations.title, systemImage: LibraryPageRow.stations.symbol)
            }
        case .history:
            NavigationLink {
                ListeningHistoryView()
            } label: {
                LibraryIndexLabel(title: LibraryPageRow.history.title, systemImage: LibraryPageRow.history.symbol)
            }
        case .recentlyAdded:
            EmptyView()
        }
    }

    private func indexRow(_ section: LibraryBrowserViewModel.Section, icon: String) -> some View {
        NavigationLink {
            SoundCloudSectionGate(section: section) {
                LibrarySectionDetailView(
                    section: section, viewModel: viewModel, analysisStore: analysisStore, confirmation: confirmation
                )
            }
        } label: {
            LibraryIndexLabel(title: section.indexLabel, systemImage: icon)
        }
    }

    private var songsRow: some View {
        NavigationLink {
            LibrarySongsView(viewModel: viewModel, analysisStore: analysisStore, confirmation: confirmation)
        } label: {
            LibraryIndexLabel(title: LibraryPageRow.tracks.title, systemImage: LibraryPageRow.tracks.symbol)
        }
    }

    private func collectionsRow(_ model: LibraryCollectionsModel) -> some View {
        NavigationLink {
            PhoneLibraryCollectionsView(model: model)
        } label: {
            LibraryIndexLabel(title: model.kind.title, systemImage: model.kind.symbol)
        }
    }

    private var downloadsRow: some View {
        NavigationLink {
            DownloadedMusicView()
        } label: {
            LibraryIndexLabel(title: LibraryPageRow.downloads.title, systemImage: LibraryPageRow.downloads.symbol)
        }
    }

    private var decksRow: some View {
        Button {
            showsDecks = true
        } label: {
            HStack {
                LibraryIndexLabel(title: LibraryPageRow.decks.title, systemImage: LibraryPageRow.decks.symbol)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .fullScreenCover(isPresented: $showsDecks) {
            PhoneDecksView { showsDecks = false }
                .preferredColorScheme(.dark)
        }
    }

    private var mixesRow: some View {
        NavigationLink {
            MixHistoryView()
        } label: {
            LibraryIndexLabel(title: LibraryPageRow.mixes.title, systemImage: LibraryPageRow.mixes.symbol)
        }
    }
}

// MARK: - iPad library

@MainActor
final class LibraryLikesRouting: ObservableObject {
    static let shared = LibraryLikesRouting()

    @Published var opensLikes = false

    private init() {}
}

struct LikesPlaylistTile: View {
    @ObservedObject private var count = LikesPlaylistCount.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            LikesPlaylistArtwork(cornerRadius: SCContentStyle.phone.cornerCard)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: SCContentStyle.phone.cornerCard, style: .continuous))
                .hoverEffect(.lift)
            Text(LikesPlaylist.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Text(count.subtitle ?? " ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        }
        .accessibilityElement(children: .combine)
        .task { await count.refresh() }
    }
}

struct LikesPlaylistRow: View {
    @ObservedObject private var count = LikesPlaylistCount.shared

    var body: some View {
        HStack(spacing: Spacing.md) {
            LikesPlaylistArtwork(cornerRadius: SCContentStyle.phone.cornerCard)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(LikesPlaylist.title)
                    .font(.scBody)
                    .scAdaptiveLineLimit()
                if let subtitle = count.subtitle {
                    Text(subtitle)
                        .font(.scSubhead)
                        .foregroundStyle(.secondary)
                        .scAdaptiveLineLimit()
                }
            }

            Spacer(minLength: Spacing.sm)
        }
        .padding(.vertical, Spacing.xs)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 56 + Spacing.md }
        .accessibilityElement(children: .combine)
        .task { await count.refresh() }
    }
}

@MainActor
final class LibraryModels: ObservableObject {
    let viewModel = LibraryBrowserViewModel()
    let analysisStore = TrackAnalysisStore()
    let confirmation = QueueConfirmationController()
    let albums = LibraryCollectionsModel(kind: .albums)
    let artists = LibraryCollectionsModel(kind: .artists)
    let recentlyAdded = RecentlyAddedModel()
}

struct LibrarySectionRoot: View {
    let section: LibraryBrowserViewModel.Section
    @ObservedObject var models: LibraryModels
    var showsAccount = false

    var body: some View {
        SoundCloudSectionGate(section: section) {
            LibrarySectionDetailView(
                section: section,
                viewModel: models.viewModel,
                analysisStore: models.analysisStore,
                confirmation: models.confirmation,
                showsAccount: showsAccount
            )
        }
    }
}

struct LibraryRecentlyAddedView: View {
    let models: LibraryModels
    @ObservedObject private var recentlyAdded: RecentlyAddedModel
    @ObservedObject private var confirmation: QueueConfirmationController
    @ScaledMetric(relativeTo: .body) private var tileMinimum: CGFloat = 170

    init(models: LibraryModels) {
        self.models = models
        _recentlyAdded = ObservedObject(wrappedValue: models.recentlyAdded)
        _confirmation = ObservedObject(wrappedValue: models.confirmation)
    }

    var body: some View {
        RecentlyAddedStates(model: recentlyAdded, minimumTile: tileMinimum) {
            ScrollView {
                RecentlyAddedFeedGrid(
                    items: recentlyAdded.items,
                    allItems: recentlyAdded.items,
                    models: models,
                    minimumTile: tileMinimum
                )
                .padding(.horizontal, Space.roomy)
                .padding(.vertical, Space.tight)
            }
            .prefetchArtwork(recentlyAdded.items.prefix(24).flatMap(\.artworkURLs))
        }
        .navigationTitle("Recently Added")
        .libraryPageTitleDisplayMode()
        .toolbar {
            AccountToolbarItem()
        }
        .task { await recentlyAdded.load() }
        .queueConfirmationOverlay(confirmation)
    }
}

private struct RecentlyAddedFeedGrid: View {
    let items: [RecentlyAddedItem]
    let allItems: [RecentlyAddedItem]
    let models: LibraryModels
    let minimumTile: CGFloat

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.artistRouter) private var artistRouter
    @Namespace private var namespace

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimumTile, maximum: max(240, minimumTile * 1.4)), spacing: Space.base, alignment: .top)],
            alignment: .leading,
            spacing: Space.section
        ) {
            ForEach(items) { item in
                link(item)
            }
        }
    }

    @ViewBuilder
    private func link(_ item: RecentlyAddedItem) -> some View {
        switch item.content {
        case .playlist(let playlist):
            PlaylistLink(playlist, heroNamespace: namespace) {
                RecentlyAddedFeedTile(item: item)
                    .matchedTransitionSource(id: playlist.id, in: namespace)
            }
            .buttonStyle(.plain)
            .libraryTilePreviewShape()
            .contextMenu { PlaylistContextMenu(playlist: playlist) }

        case .likedTracks(let tracks):
            NavigationLink {
                SoundCloudSectionGate(section: .likes) {
                    LibrarySectionDetailView(
                        section: .likes,
                        viewModel: models.viewModel,
                        analysisStore: models.analysisStore,
                        confirmation: models.confirmation
                    )
                }
            } label: {
                RecentlyAddedFeedTile(item: item)
            }
            .buttonStyle(.plain)
            .libraryTilePreviewShape()
            .contextMenu { playMenu(tracks) }

        case .collection(let collection):
            NavigationLink {
                LocalCollectionDetailView(collection: collection)
            } label: {
                RecentlyAddedFeedTile(item: item)
            }
            .buttonStyle(.plain)
            .libraryTilePreviewShape()
            .contextMenu { playMenu(collection.tracks) }

        case .person(let user):
            Button {
                artistRouter?.open(user)
            } label: {
                RecentlyAddedFeedTile(item: item)
            }
            .buttonStyle(.plain)
            .libraryTilePreviewShape()
            .contextMenu { UserContextMenu(user: user) }

        case .likedTrack(let track), .localTrack(let track):
            Button {
                Task {
                    let context = RecentlyAddedFeed.playbackContext(for: item, in: allItems)
                    if let message = await coordinator.play(track, in: context) {
                        models.confirmation.show(message, icon: "exclamationmark.triangle.fill")
                    }
                }
            } label: {
                RecentlyAddedFeedTile(item: item)
            }
            .buttonStyle(.plain)
            .libraryTilePreviewShape()
            .contextMenu { playMenu([track]) }
        }
    }

    @ViewBuilder
    private func playMenu(_ tracks: [Track]) -> some View {
        Button {
            guard let first = tracks.first else { return }
            Task { _ = await coordinator.play(first, in: tracks) }
        } label: {
            Label("Play", systemImage: "play")
        }
        .disabled(tracks.isEmpty)
        Button {
            Task { _ = await coordinator.play(shuffled: tracks) }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }
        .disabled(tracks.count < 2)
    }
}

struct PlaylistContextMenu: View {
    let playlist: Playlist
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    var body: some View {
        if let tracks = playlist.tracks, let first = tracks.first(where: { $0.streamURL != nil }) {
            Button {
                Task { await coordinator.play(first, in: tracks, collectionId: playlist.id) }
            } label: {
                Label("Play", systemImage: "play")
            }
            Button {
                Task { await coordinator.play(shuffled: tracks, collectionId: playlist.id) }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
        }
        PlaylistFolderMenuItems(playlist: playlist)
        SidebarPinButton(playlist: playlist)
        OpenInNewWindowButton(route: .playlist(playlist))
        WakeToThisMenuButton(playlist: playlist)
        ShareLink(item: playlist.permalinkURL, preview: SharePreview(playlist.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        PlaylistManagementMenuItems(playlist: playlist)
        AnalyseMissingMenuItems(tracks: playlist.tracks ?? [])
    }
}

struct UserContextMenu: View {
    let user: User
    var isFollowed: Bool?

    var body: some View {
        StartStationMenuButton(artist: user)
        ScoutToggleButton(user: user, isFollowed: isFollowed)
        OpenInNewWindowButton(route: .artist(user))
        ShareLink(item: user.permalinkURL, preview: SharePreview(user.displayName)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

struct LoadFailureView: View {
    let failure: LoadFailure
    let subject: String
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: failure.icon)
        } description: {
            Text(failure.message(subject: subject))
        } actions: {
            Button(failure.actionTitle, action: action)
                .buttonStyle(.bordered)
        }
    }
}

struct RecentlyAddedTile: View {
    let playlist: Playlist
    let heroNamespace: Namespace.ID

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            PlaylistArtworkView(
                identity: playlist.id,
                artworkURL: thumbnailURL,
                trackArtworkURLs: (playlist.tracks ?? []).compactMap(\.artworkURL),
                style: .phone
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .kyleCrowned(user: playlist.user, context: playlist.title)
            .matchedTransitionSource(id: playlist.id, in: heroNamespace)

            Text(playlist.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Text(privateMarked: playlist.user.displayName, isPrivate: playlist.isPrivate)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        }
    }

    private var thumbnailURL: URL? {
        guard let url = playlist.displayArtworkURL else { return nil }
        return URL(string: url.absoluteString.replacingOccurrences(of: "-large", with: "-t300x300")) ?? url
    }
}

private struct LibrarySectionDetailView: View {
    let section: LibraryBrowserViewModel.Section
    @ObservedObject var viewModel: LibraryBrowserViewModel
    @ObservedObject var analysisStore: TrackAnalysisStore
    @ObservedObject var confirmation: QueueConfirmationController
    var showsAccount = false

    @State private var searchText = ""
    @AppStorage("library.likes.query") private var likesQuery = TrackCollectionQuery.newestFirst
    @AppStorage("library.sets.query") private var setsQuery = TrackCollectionQuery.newestFirst
    @AppStorage(trackListColumns: "likes") private var likesColumns: Bool
    @AppStorage(trackListColumns: "sets") private var setsColumns: Bool
    @State private var loadAllTask: Task<Void, Never>?
    @State private var isLoadingAll = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var columnsDynamicTypeSize
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject private var downloads = DownloadManager.shared
    @Namespace private var playlistNamespace
    @State private var isShowingSignIn = false
    @State private var isShowingCollectionPolicy = false
    @State private var rowsMemo = DerivedRowsMemo()
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var likesRouting = LibraryLikesRouting.shared
    @ObservedObject private var folders = PlaylistFolderStore.shared
    @State private var isCreatingPlaylist = false
    @State private var createdPlaylist: Playlist?
    @Environment(\.sidebarNavigator) private var navigator
    @Environment(\.downloadPrompter) private var prompter
    @ScaledMetric(relativeTo: .body) private var playlistTileMinimum: CGFloat = 170

    private static let playlistsPage = "library.playlists"

    private func downloadLikesForWatch() {
        guard !DownloadManager.shared.isCollectionDownloaded(CollectionPolicyID.likedTracks) else { return }
        let tracks = viewModel.likedTracks
        prompter.request { confirmed in
            await DownloadManager.shared.download(collection: .likes, tracks: tracks, confirmed: confirmed)
        }
    }

    private var playlistViewMode: Binding<CollectionViewMode> {
        Binding(
            get: { settings.collectionViewMode(for: Self.playlistsPage, default: .list) },
            set: { settings.setCollectionViewMode($0, for: Self.playlistsPage) }
        )
    }

    private var showsPlaylistGrid: Bool {
        section == .playlists && playlistViewMode.wrappedValue == .grid
    }

    private var likesPlaylistTileLink: some View {
        SidebarLink(tab: .likes) {
            likesPage
        } label: {
            LikesPlaylistTile()
        }
        .buttonStyle(.plain)
    }

    private func playlistsGrid(_ playlists: [Playlist]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: playlistTileMinimum, maximum: max(240, playlistTileMinimum * 1.4)), spacing: Space.base, alignment: .top)],
                    alignment: .leading,
                    spacing: Space.section
                ) {
                    if showsLikesPlaylist {
                        likesPlaylistTileLink
                    }
                    ForEach(visibleFolders) { folder in
                        PlaylistFolderLink(folder: folder, isTile: true)
                    }
                    ForEach(playlists) { playlist in
                        PlaylistLink(playlist, heroNamespace: playlistNamespace) {
                            RecentlyAddedTile(playlist: playlist, heroNamespace: playlistNamespace)
                                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: SCContentStyle.phone.artworkCorner, style: .continuous))
                                .hoverEffect(.lift)
                        }
                        .buttonStyle(.plain)
                        .libraryTilePreviewShape()
                        .contextMenu { PlaylistContextMenu(playlist: playlist) }
                        .collectionDragSource(playlist)
                        .playlistTrackDropTarget(playlist, cornerRadius: SCContentStyle.phone.artworkCorner)
                        .onAppear {
                            guard trimmedSearch.isEmpty, viewModel.playlists.isNearEnd(playlist, lead: 12) else { return }
                            viewModel.requestMore(section: .playlists)
                        }
                    }
                }
                .padding(.horizontal, Space.roomy)
                .padding(.vertical, Space.tight)
                .animation(.snappy, value: visibleFolders.map(\.id) + playlists.map(\.id))
                if trimmedSearch.isEmpty {
                    PagedFooter(pager: viewModel.playlistsPager)
                }
            }
        }
        .refreshable { await viewModel.loadContent(for: .playlists, forceRefresh: true) }
    }

    private var opensLikes: Binding<Bool> {
        Binding(
            get: { section == .playlists && likesRouting.opensLikes },
            set: { if section == .playlists { likesRouting.opensLikes = $0 } }
        )
    }

    private var showsLikesPlaylist: Bool {
        section == .playlists && LikesPlaylist.matches(search: trimmedSearch)
    }

    private var visibleFolders: [PlaylistFolder] {
        guard section == .playlists else { return [] }
        return folders.matchingFolders(trimmedSearch)
    }

    private var likesPage: some View {
        SoundCloudSectionGate(section: .likes) {
            LibrarySectionDetailView(
                section: .likes, viewModel: viewModel, analysisStore: analysisStore, confirmation: confirmation
            )
        }
    }

    private var likesPlaylistLink: some View {
        SidebarLink(tab: .likes, isListRow: true) {
            likesPage
        } label: {
            LikesPlaylistRow()
        }
    }

    private var isTrackSection: Bool { section == .likes || section == .sets }

    private var query: Binding<TrackCollectionQuery> {
        section == .sets ? $setsQuery : $likesQuery
    }

    private var showsColumns: Binding<Bool> {
        section == .sets ? $setsColumns : $likesColumns
    }

    private var sortKey: TrackSortKey? { isTrackSection ? query.wrappedValue.sortKey : nil }

    private var showsColumnHeader: Bool {
        isTrackSection && showsColumns.wrappedValue && horizontalSizeClass == .regular && !columnsDynamicTypeSize.isAccessibilitySize
    }

    private func likedDate(_ track: Track) -> Date {
        viewModel.likedAtByTrackID[track.id] ?? track.createdAt
    }

    private func startLoadingAll() {
        loadAllTask?.cancel()
        let pager = viewModel.likesPager
        guard pager.hasMore else { return }
        isLoadingAll = true
        loadAllTask = Task {
            await TrackCollectionLoader.loadAll(pager)
            isLoadingAll = false
        }
    }

    private func stopLoadingAll() {
        loadAllTask?.cancel()
        loadAllTask = nil
        isLoadingAll = false
    }

    private func sortChanged() {
        guard isTrackSection,
              TrackCollection.needsFullCollection(query.wrappedValue, naturalOrder: .newestFirst) else { return }
        startLoadingAll()
    }

    private var backingSection: LibraryBrowserViewModel.Section {
        switch section {
        case .sets: return .likes
        default: return section
        }
    }

    var body: some View {
        content
            .navigationTitle(section.indexLabel)
            .navigationSubtitle(viewModel.countText(for: section) ?? "")
            .libraryPageTitleDisplayMode()
            .libraryPageSearchable(text: $searchText, prompt: searchPrompt)
            .task(id: trimmedSearch) { await loadMoreWhileSearchIsEmpty() }
            .toolbar {
                if isTrackSection {
                    ToolbarItem(placement: .topBarTrailing) {
                        TrackCollectionMenu(
                            query: query,
                            showsColumns: showsColumns,
                            sortKeys: TrackCollection.availableSortKeys(for: viewModel.likedTracks, analysis: analysisStore.summaries),
                            dateLabel: "Date Liked",
                            filters: section == .sets ? TrackFilter.allCases.filter { $0 != .sets } : TrackFilter.allCases,
                            analyseTracks: section == .sets ? derivedRows().sets : derivedRows().liked
                        )
                    }
                }
                if section == .playlists {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                isCreatingPlaylist = true
                            } label: {
                                Label("New Playlist", systemImage: "music.note.list")
                            }
                            Button {
                                PlaylistFolderPrompter.shared.newFolder()
                            } label: {
                                Label("New Playlist Folder", systemImage: "folder.badge.plus")
                            }
                            .disabled(!folders.canEdit)
                        } label: {
                            Label("New", systemImage: "plus")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        CollectionViewModeToggle(mode: playlistViewMode)
                    }
                }
                if showsAccount {
                    AccountToolbarItem()
                }
                if trimmedSearch.isEmpty, section == .likes {
                    ToolbarItem(placement: .topBarTrailing) {
                        CollectionDownloadButton(collectionId: "likes", tracks: { viewModel.likedTracks })
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            SendToWatchMenuToggle(selection: .likes) {
                                downloadLikesForWatch()
                            }
                            Button("Collection Settings", systemImage: "slider.horizontal.3") {
                                isShowingCollectionPolicy = true
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                }
            }
            .task {
                await viewModel.loadContent(for: backingSection)
                if section == .sets { startLoadingAll() }
            }
            .onChange(of: query.wrappedValue.sortKey) { _, _ in sortChanged() }
            .onChange(of: query.wrappedValue.ascending) { _, _ in sortChanged() }
            .onDisappear { stopLoadingAll() }
            .task(id: likedFingerprint) {
                guard section == .likes || section == .sets else { return }
                await analysisStore.load(for: viewModel.likedTracks)
                if section == .likes {
                    DownloadManager.shared.applyCollectionPolicy(
                        tracks: viewModel.likedTracks,
                        collectionId: CollectionPolicyID.likedTracks
                    )
                }
            }
            .queueConfirmationOverlay(confirmation)
            .navigationDestination(isPresented: opensLikes) { likesPage }
            .navigationDestination(item: $createdPlaylist) { playlist in
                PlaylistDetailView(playlist: playlist, heroNamespace: playlistNamespace)
            }
            .sheet(isPresented: $isCreatingPlaylist) {
                NewPlaylistSheet { playlist in
                    navigator?.insert(playlist)
                    createdPlaylist = playlist
                }
            }
            .sheet(isPresented: $isShowingSignIn) {
                NavigationStack {
                    SoundCloudLoginView.standalone {
                        isShowingSignIn = false
                        SoundCloudCredentialSource.shared.refreshFromStore()
                        Task { await viewModel.loadContent(for: backingSection, forceRefresh: true) }
                    }
                }
            }
            .sheet(isPresented: $isShowingCollectionPolicy) {
                CollectionPolicyEditor(
                    collectionId: CollectionPolicyID.likedTracks,
                    collectionName: "Liked Tracks",
                    collectionKind: .playlist,
                    tracks: viewModel.likedTracks,
                    applier: DownloadManager.shared
                )
            }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchPrompt: String {
        switch section {
        case .likes:     return "Search Liked"
        case .sets:      return "Search Sets"
        case .playlists: return "Search Playlists"
        case .following: return "Search Following"
        }
    }

    private struct DerivedRows {
        var sortedLiked: [Track] = []
        var liked: [Track] = []
        var sets: [Track] = []
        var playlists: [Playlist] = []
        var following: [User] = []
    }

    private struct ListFingerprint: Equatable {
        let count: Int
        let firstID: String?
        let lastID: String?

        init<Item: Identifiable>(_ items: [Item]) where Item.ID == String {
            count = items.count
            firstID = items.first?.id
            lastID = items.last?.id
        }
    }

    private struct DerivedRowsKey: Equatable {
        let section: LibraryBrowserViewModel.Section
        let itemsRevision: Int
        let needle: String
        let query: TrackCollectionQuery
        let downloadsCount: Int
        let analysisRevision: Int
        let likedAtCount: Int
        let setMinimumDuration: Double
    }

    private final class DerivedRowsMemo {
        var key: DerivedRowsKey?
        var rows = DerivedRows()
    }

    private var likedFingerprint: ListFingerprint {
        ListFingerprint(viewModel.likedTracks)
    }

    private var derivedRowsKey: DerivedRowsKey {
        DerivedRowsKey(
            section: section,
            itemsRevision: viewModel.likesPager.revision,
            needle: trimmedSearch,
            query: isTrackSection ? query.wrappedValue : .collectionOrder,
            downloadsCount: isTrackSection && query.wrappedValue.isFiltering ? downloads.states.count : 0,
            analysisRevision: isTrackSection ? analysisStore.revision : 0,
            likedAtCount: section == .likes ? viewModel.likedAtByTrackID.count : 0,
            setMinimumDuration: section == .sets ? Double(settings.setMinimumDurationSeconds) : 0
        )
    }

    private func derivedRows() -> DerivedRows {
        guard section == .likes || section == .sets else { return computeDerivedRows() }
        let key = derivedRowsKey
        if rowsMemo.key == key { return rowsMemo.rows }
        let rows = computeDerivedRows()
        rowsMemo.key = key
        rowsMemo.rows = rows
        return rows
    }

    private func computeDerivedRows() -> DerivedRows {
        var rows = DerivedRows()
        let needle = trimmedSearch
        switch section {
        case .likes:
            rows.sortedLiked = TrackCollection.apply(
                viewModel.likedTracks,
                query: likesQuery,
                search: needle,
                analysis: analysisStore.summaries,
                context: TrackCollectionLoader.context(),
                dateAdded: likedDate
            )
            rows.liked = rows.sortedLiked
        case .sets:
            let sets = GeneratedLibraryCollections.sets(
                from: viewModel.likedTracks,
                minimumDuration: settings.setMinimumDurationSeconds
            )
            rows.sets = TrackCollection.apply(
                sets,
                query: setsQuery,
                search: needle,
                analysis: analysisStore.summaries,
                context: TrackCollectionLoader.context(),
                dateAdded: likedDate
            )
        case .playlists:
            let kindFiltered = viewModel.playlists.filter { !$0.isAlbum }
            rows.playlists = needle.isEmpty
                ? kindFiltered.filter { !folders.isFoldered($0.id) }
                : kindFiltered.filter { $0.title.scLocallyContains(needle) }
        case .following:
            rows.following = needle.isEmpty
                ? viewModel.following
                : viewModel.following.filter { $0.displayName.scLocallyContains(needle) }
        }
        return rows
    }

    private func searchYieldedNothing(_ rows: DerivedRows) -> Bool {
        guard !trimmedSearch.isEmpty || (isTrackSection && query.wrappedValue.isFiltering) else { return false }
        switch section {
        case .likes:     return rows.liked.isEmpty
        case .sets:      return rows.sets.isEmpty
        case .playlists: return rows.playlists.isEmpty && !showsLikesPlaylist && visibleFolders.isEmpty
        case .following: return rows.following.isEmpty
        }
    }

    private func loadMoreWhileSearchIsEmpty() async {
        guard !trimmedSearch.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(500))
        var pages = 0
        while !Task.isCancelled, pages < 10,
              viewModel.state(for: backingSection) == .loaded,
              searchYieldedNothing(derivedRows()),
              viewModel.canAutoLoadMore(section: backingSection) {
            if viewModel.isLoadingMore(backingSection) {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            pages += 1
            await viewModel.loadMore(section: backingSection)
        }
    }

    @ViewBuilder
    private var content: some View {
        let sectionState = viewModel.state(for: backingSection)
        let rows = sectionState == .loaded ? derivedRows() : DerivedRows()
        switch sectionState {
        case .loading:
            LibraryLoadingState()

        case .failed(let failure):
            LoadFailureView(failure: failure, subject: "your \(section.title.lowercased())") {
                switch failure.recovery {
                case .signIn:
                    isShowingSignIn = true
                case .retry:
                    Task { await viewModel.loadContent(for: backingSection, forceRefresh: true) }
                }
            }

        case .empty where showsPlaylistGrid:
            playlistsGrid([])

        case .empty where section == .playlists:
            List {
                likesPlaylistLink
                ForEach(visibleFolders) { folder in
                    PlaylistFolderLink(folder: folder)
                }
            }
            .listStyle(.plain)
            .refreshable { await viewModel.loadContent(for: .playlists, forceRefresh: true) }

        case .empty:
            ContentUnavailableView {
                SoundingArtEmptyLabel(title: section.title, identity: "empty.library.\(section.title)", motif: .vinyl)
            } description: {
                Text(section.emptyMessage)
            } actions: {
                Button("Refresh") {
                    Task { await viewModel.loadContent(for: backingSection, forceRefresh: true) }
                }
                .buttonStyle(.bordered)
            }

        case .loaded where searchYieldedNothing(rows):
            if viewModel.isLoadingMore(backingSection) {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if trimmedSearch.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Tracks", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No loaded tracks match these filters.")
                } actions: {
                    Button("Clear Filters") { query.wrappedValue.clearFilters() }
                        .buttonStyle(.bordered)
                }
            } else {
                ContentUnavailableView.search(text: trimmedSearch)
            }

        case .loaded where section == .sets && rows.sets.isEmpty:
            ContentUnavailableView(
                "No Sets Yet",
                systemImage: section.emptyIcon,
                description: Text("Liked tracks \(GeneratedLibraryCollections.durationLabel(settings.setMinimumDurationSeconds)) or longer appear here.")
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                SavedSetlistsCount { count in
                    if count > 0 { setlistsHeaderLink(count: count) }
                }
            }

        case .loaded where showsPlaylistGrid && !searchYieldedNothing(rows):
            playlistsGrid(rows.playlists)

        case .loaded:
            List {
                if isTrackSection {
                    TrackCollectionLoadAllRow(
                        pager: viewModel.likesPager,
                        noun: "likes",
                        isLoadingAll: isLoadingAll,
                        isFiltering: query.wrappedValue.isFiltering || !trimmedSearch.isEmpty,
                        loadAll: startLoadingAll,
                        stop: stopLoadingAll
                    )
                    MissingAnalysisProgressLine()
                        .listRowSeparator(.hidden)
                }
                if showsColumnHeader {
                    TrackColumnsHeader(
                        query: query,
                        sortKeys: TrackCollection.availableSortKeys(for: viewModel.likedTracks, analysis: analysisStore.summaries)
                    )
                }
                switch section {
                case .likes:     likesRows(rows)
                case .sets:
                    if trimmedSearch.isEmpty {
                        SavedSetlistsCount { count in
                            if count > 0 { setlistsLink(count: count) }
                        }
                    }
                    setRows(rows)
                case .playlists:
                    if showsLikesPlaylist { likesPlaylistLink }
                    ForEach(visibleFolders) { folder in
                        PlaylistFolderLink(folder: folder)
                    }
                    playlistsRows(rows)
                case .following: followingRows(rows)
                }

                if isTrackSection {
                    UnanalysedTracksFooter(tracks: section == .sets ? rows.sets : rows.liked, sortKey: sortKey, summaries: analysisStore.summaries)
                }

                if trimmedSearch.isEmpty {
                    pagedFooter
                }
                if isTrackSection {
                    LibrarySyncStatusLine().listRowSeparator(.hidden)
                }
            }
            .environment(\.trackSortKey, sortKey)
            .trackListColumns(isTrackSection && showsColumns.wrappedValue)
            .animation(.smooth, value: showsColumns.wrappedValue)
            .listStyle(.plain)
            .animation(.snappy, value: visibleFolders.map(\.id))
            .refreshable { await viewModel.loadContent(for: section, forceRefresh: true) }
        }
    }

    @ViewBuilder
    private var pagedFooter: some View {
        switch backingSection {
        case .likes, .sets: PagedFooter(pager: viewModel.likesPager).listRowSeparator(.hidden)
        case .playlists:    PagedFooter(pager: viewModel.playlistsPager).listRowSeparator(.hidden)
        case .following:    PagedFooter(pager: viewModel.followingPager).listRowSeparator(.hidden)
        }
    }

    private func likesRows(_ rows: DerivedRows) -> some View {
        let tracks = rows.liked
        let sorted = rows.sortedLiked
        return ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            TrackListRow(
                track: track,
                analysis: analysisStore.summaries[track.id],
                context: { tracks },
                collectionId: CollectionPolicyID.likedTracks,
                confirmation: confirmation
            )
            .onAppear {
                if trimmedSearch.isEmpty, sorted.isNearEnd(track, lead: 10) {
                    viewModel.requestMore(section: .likes)
                }
                let lookahead = tracks[index..<min(index + Self.artworkLookahead, tracks.count)]
                ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL), variant: .thumbnail)
                AnalysisSummaries.shared.request(lookahead)
            }
        }
    }

    private func setlistsLink(count: Int) -> some View {
        NavigationLink(value: LibraryPageRoute.setlists) {
            SavedSetlistsLabel(count: count)
        }
    }

    private func setlistsHeaderLink(count: Int) -> some View {
        NavigationLink(value: LibraryPageRoute.setlists) {
            HStack(spacing: Space.tight) {
                SavedSetlistsLabel(count: count)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private func setRows(_ rows: DerivedRows) -> some View {
        let tracks = rows.sets
        return ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            TrackListRow(
                track: track,
                analysis: analysisStore.summaries[track.id],
                context: { tracks },
                collectionId: nil,
                confirmation: confirmation,
                showsSetlistAction: true
            )
            .onAppear {
                if trimmedSearch.isEmpty, tracks.isNearEnd(track, lead: 10) {
                    viewModel.requestMore(section: .likes)
                }
                let lookahead = tracks[index..<min(index + Self.artworkLookahead, tracks.count)]
                ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL), variant: .thumbnail)
                AnalysisSummaries.shared.request(lookahead)
            }
        }
    }

    private func playlistsRows(_ rows: DerivedRows) -> some View {
        let playlists = rows.playlists
        return ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
            PlaylistLink(playlist, heroNamespace: playlistNamespace, isListRow: true) {
                PlaylistRow(playlist: playlist)
            }
            .matchedTransitionSource(id: playlist.id, in: playlistNamespace)
            .libraryRowPreviewShape()
            .contextMenu { PlaylistContextMenu(playlist: playlist) }
            .collectionDragSource(playlist)
            .onAppear {
                if trimmedSearch.isEmpty, viewModel.playlists.isNearEnd(playlist, lead: 10) {
                    viewModel.requestMore(section: .playlists)
                }
                let lookahead = playlists[index..<min(index + Self.artworkLookahead, playlists.count)]
                ArtworkCache.shared.prefetch(lookahead.compactMap(\.displayArtworkURL))
            }
        }
    }

    private func followingRows(_ rows: DerivedRows) -> some View {
        let following = rows.following
        return ForEach(Array(following.enumerated()), id: \.element.id) { index, user in
            NavigationLink {
                ArtistDetailView(user: user)
            } label: {
                UserRow(user: user)
            }
            .libraryRowPreviewShape()
            .contextMenu { UserContextMenu(user: user, isFollowed: true) }
            .onAppear {
                if trimmedSearch.isEmpty, viewModel.following.isNearEnd(user, lead: 10) {
                    viewModel.requestMore(section: .following)
                }
                let lookahead = following[index..<min(index + Self.artworkLookahead, following.count)]
                ArtworkCache.shared.prefetch(lookahead.compactMap(\.avatarURL), variant: .thumbnail)
            }
        }
    }

    private static let artworkLookahead = 10
}

@MainActor
fileprivate protocol SectionPaging: AnyObject {
    var isLoadingFirst: Bool { get }
    var isLoadingMore: Bool { get }
    var hasLoadedFirst: Bool { get }
    var hasMore: Bool { get }
    var firstError: Error? { get }
    var didFailLoadingMore: Bool { get }
    var isPaused: Bool { get }
    var itemCount: Int { get }
    func reload() async
    func loadMore() async
    func requestMore()
}

extension Paginator: SectionPaging {
    fileprivate var itemCount: Int { items.count }
}

@MainActor
final class LibraryBrowserViewModel: ObservableObject {
    enum Section: String, CaseIterable, Hashable {
        case likes, sets, playlists, following

        var title: String {
            switch self {
            case .likes:     return "Likes"
            case .sets:      return "Sets"
            case .playlists: return "Playlists"
            case .following: return "Following"
            }
        }

        var indexLabel: String {
            title
        }

        var emptyIcon: String {
            switch self {
            case .likes:     return "heart"
            case .sets:      return SidebarSymbol.sets
            case .playlists: return "music.note.list"
            case .following: return "person.2"
            }
        }

        var emptyMessage: String {
            switch self {
            case .likes:     return "Tracks you like show up here."
            case .sets:      return "Long-form liked tracks show up here."
            case .playlists: return "Your playlists show up here."
            case .following: return "Artists you follow show up here."
            }
        }
    }

    enum SectionState: Equatable {
        case loading
        case loaded
        case empty
        case failed(LoadFailure)
    }

    @Published var selectedSection: Section = .likes
    @Published private(set) var likedAtByTrackID: [String: Date] = [:]
    @Published private(set) var sectionState: [Section: SectionState] = [:]

    let likesPager: Paginator<Track>
    let playlistsPager: Paginator<Playlist>
    let followingPager: Paginator<User>

    var likedTracks: [Track] { likesPager.items }
    var playlists: [Playlist] { playlistsPager.items }
    var following: [User] { followingPager.items }

    private let api = SoundCloudAPI.shared

    private let cache = LibraryCache.shared

    private static let cachePageSize = 100
    private static let cacheTTL: TimeInterval = 5 * 60

    private var loadedSections: Set<Section> = []
    private var loadInFlight: Set<Section> = []
    private var cancellables: Set<AnyCancellable> = []

    private static func placeholderSource<Item>() -> PagedSource<Item> {
        PagedSource(first: { PagedChunk(items: []) }, next: { _ in PagedChunk(items: []) })
    }

    init() {
        likesPager = Paginator(source: Self.placeholderSource(), maxUnattendedPages: 1_000)
        playlistsPager = Paginator(source: Self.placeholderSource(), maxUnattendedPages: 1_000)
        followingPager = Paginator(source: Self.placeholderSource(), maxUnattendedPages: 1_000)

        likesPager.setSource(LibraryDB.trackSource(.likes, onLikedAt: { [weak self] likedAt in
            self?.likedAtByTrackID.merge(likedAt) { _, latest in latest }
        }))
        playlistsPager.setSource(LibraryDB.playlistSource())
        followingPager.setSource(LibraryDB.userSource(.followings))

        likesPager.objectWillChange
            .merge(with: playlistsPager.objectWillChange, followingPager.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        LibrarySyncEngine.shared.$revision
            .dropFirst()
            .sink { [weak self] _ in
                Task { await self?.refreshFromDatabase() }
            }
            .store(in: &cancellables)
        LibrarySyncEngine.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func pager(for section: Section) -> any SectionPaging {
        switch section {
        case .likes, .sets: return likesPager
        case .playlists:    return playlistsPager
        case .following:    return followingPager
        }
    }

    private static func collection(for section: Section) -> LibraryCollection {
        switch section {
        case .likes, .sets: return .likes
        case .playlists:    return .ownPlaylists
        case .following:    return .followings
        }
    }

    func loadContentIfNeeded() async {
        guard !loadedSections.contains(selectedSection) else { return }
        await loadContent(for: selectedSection)
    }

    func loadContent(for section: Section, forceRefresh: Bool = false) async {
        #if DEBUG
        if VisualFixtures.isEnabled {
            installVisualFixtures()
            return
        }
        #endif
        if section == .sets {
            await loadContent(for: .likes, forceRefresh: forceRefresh)
            return
        }
        let pager = pager(for: section)
        guard SoundCloudCredentialSource.shared.accessToken != nil else {
            if !pager.hasLoadedFirst {
                sectionState[section] = .failed(LoadFailure.credentialFailure())
            }
            return
        }
        let collections: [LibraryCollection] = section == .playlists
            ? [.ownPlaylists, .likedPlaylists]
            : [Self.collection(for: section)]
        if forceRefresh {
            LibrarySyncEngine.shared.requestRefresh(collections)
        } else {
            LibrarySyncEngine.shared.prioritise(collections)
        }
        guard !loadInFlight.contains(section), !pager.isLoadingFirst else { return }
        loadInFlight.insert(section)
        defer { loadInFlight.remove(section) }
        if !pager.hasLoadedFirst {
            await pager.reload()
        }
        if pager.hasLoadedFirst {
            loadedSections.insert(section)
            sectionState[section] = nil
        }
    }

    private func refreshFromDatabase() async {
        let changed = LibrarySyncEngine.shared.lastChanged
        if changed.contains(.likes), likesPager.hasLoadedFirst {
            let page = await LibraryDB.tracks(.likes, offset: 0, limit: max(Self.cachePageSize, likesPager.items.count))
            let total = await LibraryDB.count(.likes)
            likedAtByTrackID.merge(page.likedAt) { _, latest in latest }
            likesPager.prime(items: page.tracks, cursor: page.rowCount < total ? .offset(page.rowCount) : nil, total: total)
        }
        if (changed.contains(.ownPlaylists) || changed.contains(.likedPlaylists)), playlistsPager.hasLoadedFirst {
            let page = await LibraryDB.allPlaylists(offset: 0, limit: max(Self.cachePageSize, playlistsPager.items.count))
            let total = await LibraryDB.playlistCount()
            playlistsPager.prime(items: page.playlists, cursor: page.rowCount < total ? .offset(page.rowCount) : nil, total: total)
        }
        if changed.contains(.followings), followingPager.hasLoadedFirst {
            let page = await LibraryDB.users(.followings, offset: 0, limit: max(Self.cachePageSize, followingPager.items.count))
            let total = await LibraryDB.count(.followings)
            followingPager.prime(items: page.users, cursor: page.rowCount < total ? .offset(page.rowCount) : nil, total: total)
        }
        for section in [Section.likes, .playlists, .following] where !pager(for: section).hasLoadedFirst && loadedSections.contains(section) {
            await pager(for: section).reload()
        }
    }

    #if DEBUG
    private func installVisualFixtures() {
        likedAtByTrackID = Dictionary(uniqueKeysWithValues: VisualFixtures.tracks.enumerated().map {
            ($0.element.id, Date().addingTimeInterval(Double(-$0.offset * 900)))
        })
        likesPager.prime(items: VisualFixtures.tracks, cursor: nil)
        playlistsPager.prime(items: VisualFixtures.playlists + VisualFixtures.albums, cursor: nil)
        followingPager.prime(items: VisualFixtures.artists, cursor: nil)
        sectionState = [:]
        loadedSections = [.likes, .playlists, .following]
    }
    #endif

    func handleSignOut() async {
        await cache.clearAll()
        await LibrarySyncEngine.shared.handleSignOut()
        likesPager.reset()
        playlistsPager.reset()
        followingPager.reset()
        likedAtByTrackID = [:]
        sectionState = [:]
        loadedSections = []
    }

    func state(for section: Section) -> SectionState {
        if section == .sets { return state(for: .likes) }
        let pager = pager(for: section)
        if pager.hasLoadedFirst {
            guard pager.itemCount == 0 else { return .loaded }
            return LibrarySyncEngine.shared.isAwaitingFirstSync(Self.collection(for: section)) ? .loading : .empty
        }
        if let error = pager.firstError { return .failed(LoadFailure.classify(error)) }
        return sectionState[section] ?? .loading
    }

    func loadMore(section: Section) async {
        await pager(for: section).loadMore()
    }

    func requestMore(section: Section) {
        pager(for: section).requestMore()
    }

    func canLoadMore(section: Section) -> Bool {
        pager(for: section).hasMore
    }

    func isLoadingMore(_ section: Section) -> Bool {
        pager(for: section).isLoadingMore
    }

    func canAutoLoadMore(section: Section) -> Bool {
        let pager = pager(for: section)
        return pager.hasMore && !pager.didFailLoadingMore && !pager.isPaused
    }

    private func mergeLikesCache(_ likes: [Like<Track>]) async {
        let entries = likes.map { (track: $0.item, likedAtMillis: Int64(($0.createdAt.timeIntervalSince1970 * 1000).rounded())) }
        let rows = await Task.detached(priority: .utility) {
            let encoder = Self.makeCacheEncoder()
            return entries.compactMap { entry -> LibraryCache.WriteRow? in
                guard let payload = try? encoder.encode(entry.track) else { return nil }
                return LibraryCache.WriteRow(id: entry.track.id, payload: payload, likedAtMillis: entry.likedAtMillis)
            }
        }.value
        await cache.mergeSection(Section.likes.rawValue, rows: rows)
    }

    private func mergeCache<T: Encodable & Sendable>(_ section: Section, items: [T], id: @escaping @Sendable (T) -> String) async {
        let rows = await Task.detached(priority: .utility) {
            let encoder = Self.makeCacheEncoder()
            return items.compactMap { item -> LibraryCache.WriteRow? in
                guard let payload = try? encoder.encode(item) else { return nil }
                return LibraryCache.WriteRow(id: id(item), payload: payload)
            }
        }.value
        await cache.mergeSection(section.rawValue, rows: rows)
    }

    private nonisolated static func makeCacheEncoder() -> JSONEncoder {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(formatter)
        return encoder
    }

    func count(for section: Section) -> Int {
        switch section {
        case .likes, .sets: return likedTracks.count
        case .playlists: return playlists.count
        case .following: return following.count
        }
    }

    func countText(for section: Section) -> String? {
        switch section {
        case .likes:
            guard !likedTracks.isEmpty else { return nil }
            if !likesPager.hasMore { return Self.countLabel(likedTracks.count, "track", "tracks") }
            if let total = SoundCloudCredentialSource.shared.currentUser?.publicFavoritesCount, total >= likedTracks.count {
                return Self.countLabel(total, "track", "tracks")
            }
            return likesPager.countText(singular: "track", plural: "tracks")
        case .sets:
            return nil
        case .playlists:
            let count = playlists.filter { !$0.isAlbum }.count
            guard count > 0 else { return nil }
            return Self.countLabel(count, "playlist", "playlists", approximate: playlistsPager.hasMore)
        case .following:
            guard !following.isEmpty else { return nil }
            let total = SoundCloudCredentialSource.shared.currentUser?.followingsCount ?? 0
            if followingPager.hasMore, total >= following.count {
                return Self.countLabel(total, "artist", "artists")
            }
            return Self.countLabel(following.count, "artist", "artists", approximate: followingPager.hasMore)
        }
    }

    private static func countLabel(_ count: Int, _ singular: String, _ plural: String, approximate: Bool = false) -> String {
        let noun = count == 1 ? singular : plural
        return approximate ? "\(count)+ \(noun)" : "\(count) \(noun)"
    }

}

@MainActor
final class QueueConfirmationController: ObservableObject {
    struct Confirmation: Equatable {
        let message: String
        let icon: String
    }

    @Published private(set) var current: Confirmation?
    private var token = 0

    func show(_ message: String, icon: String = "checkmark.circle.fill") {
        token &+= 1
        let issued = token
        current = Confirmation(message: message, icon: icon)
        AccessibilityNotification.Announcement(message).post()

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.token == issued else { return }
            self.current = nil
        }
    }
}

extension View {
    func queueConfirmationOverlay(_ controller: QueueConfirmationController) -> some View {
        modifier(QueueConfirmationOverlayModifier(controller: controller))
    }
}

private struct QueueConfirmationOverlayModifier: ViewModifier {
    @ObservedObject var controller: QueueConfirmationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let confirmation = controller.current {
                    Label(confirmation.message, systemImage: confirmation.icon)
                        .scTransientBanner()
                        .padding(.bottom, Spacing.lg)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(reduceMotion ? nil : SCContentMotion.gentle, value: controller.current)
    }
}

typealias TrackRowActivity = SCTrackActivity

struct TrackListRow: View {
    let track: Track
    var analysis: TrackAnalysisSummary?
    let context: () -> [Track]
    var collectionId: String? = nil
    @ObservedObject var confirmation: QueueConfirmationController
    var showsSetlistAction = false
    var number: Int? = nil

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    var body: some View {
        TrackRow(
            track: track,
            analysis: analysis,
            activity: activity,
            number: number,
            play: {
                Task {
                    if let message = await coordinator.play(track, in: context(), collectionId: collectionId) {
                        confirmation.show(message, icon: "exclamationmark.triangle.fill")
                    }
                }
            },
            addToQueue: queue,
            showsSetlistAction: showsSetlistAction,
            playOn: { device in
                Task {
                    if let message = await coordinator.play(track, in: context(), on: device) {
                        confirmation.show(message, icon: "exclamationmark.triangle.fill")
                    }
                }
            }
        )
    }

    private var activity: TrackRowActivity {
        guard let snapshot = coordinator.nowPlaying, snapshot.trackId == track.id else { return .none }
        if snapshot.isLoading { return .loading }
        return snapshot.isPlaying ? .playing : .paused
    }

    private func queue() {
        coordinator.addToQueue(track)
        confirmation.show("Added \u{201C}\(track.title)\u{201D} to Up Next")
    }
}

struct WarmStreamOnPressButtonStyle: ButtonStyle {
    let track: Track

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onChange(of: configuration.isPressed) { _, pressed in
                guard pressed, track.streamURL != nil else { return }
                PlayerService.shared.preparePlayback(for: track, immediate: true)
            }
    }
}

struct TrackRow: View {
    let track: Track
    var analysis: TrackAnalysisSummary?
    let activity: TrackRowActivity
    var number: Int? = nil
    let play: () -> Void
    let addToQueue: () -> Void
    var showsSetlistAction = false
    var playOn: ((OutputDevice) -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ObservedObject private var setlistStore = SetlistIntelligenceStore.shared
    @ObservedObject private var summaries = AnalysisSummaries.shared
    @State private var setlistTrack: Track?
    @State private var trimTrack: Track?

    @Environment(\.trackSortKey) private var sortKey
    @Environment(\.showsTrackSource) private var showsSource
    @Environment(\.trackListShowsColumns) private var showsColumns
    @Environment(\.trackRowShowsType) private var showsType

    private var isPlayable: Bool { track.streamURL != nil }
    private var usesColumns: Bool {
        showsColumns && !showsType && horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    private var resolvedAnalysis: TrackAnalysisSummary? {
        analysis ?? summaries.summary(for: track).map(TrackAnalysisSummary.init)
    }

    private var secondaryLine: String {
        if showsType { return SearchTypeLine.text(.track(track)) }
        switch sortKey {
        case .plays?, .energy?, .source?, .genre?:
            guard let value = TrackSort.sortValue(for: track, key: sortKey, analysis: resolvedAnalysis) else { break }
            return "\(track.user.displayName) · \(value)"
        default:
            break
        }
        if horizontalSizeClass == .regular, number == nil, let album = track.albumName {
            return "\(track.user.displayName) \u{00B7} \(album)"
        }
        return track.user.displayName
    }

    private var hasSetlistAction: Bool {
        DeckIdentityResolver.isLikelyMix(track) || setlistStore.setlist(for: track.id) != nil
    }

    private var metrics: SCTrackListMetrics { showsType ? .phoneSearch : .phone }

    private var leading: SCTrackListLeading { number == nil ? .artwork : .number }

    private var leadingWidth: CGFloat {
        leading == .number ? metrics.numberWidth : metrics.artworkSize
    }

    private var item: SCTrackListItem {
        var item = SCTrackListItem(
            track: track,
            number: number ?? 0,
            analysis: resolvedAnalysis
        )
        item.artist = secondaryLine
        if track.isAwaitingLocalMetadata { item.duration = "" }
        return item
    }

    var body: some View {
        HStack(spacing: Space.tight) {
            Button(action: play) {
                Group {
                    if usesColumns {
                        TrackColumnsRowLabel(track: track, analysis: resolvedAnalysis, number: number, activity: activity)
                    } else {
                        SCTrackListRow(item: item, leading: leading, activity: activity, metrics: metrics, crownUser: track.user) {
                            TrackPlayCountLabel(track: track, isEnabled: sortKey != .plays, font: metrics.detailFont)
                            if showsSource {
                                TrackSourceMark(track: track)
                            }
                            if showsType {
                                SoundCloudTrackBadge(track: track)
                            }
                            if isPlayable {
                                TrackDownloadStatusGlyph(trackId: track.id)
                            }
                        }
                    }
                }
                .contentShape(.hoverEffect, .rect(cornerRadius: Radius.sm))
                .hoverEffect(.highlight)
            }
            .disabled(!isPlayable)
            .buttonStyle(WarmStreamOnPressButtonStyle(track: track))

            if showsSetlistAction, hasSetlistAction {
                Button { setlistTrack = track } label: {
                    Image(systemName: "list.number")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("View setlist for \(track.title)")
            }

            SCTrackListMoreMenu(title: track.title, size: 44) {
                menuItems
                ShareLink(item: track.permalinkURL, preview: SharePreview(track.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in leadingWidth + metrics.spacing }
        .trackDragSource(track)
        .libraryRowPreviewShape()
        .contextMenu {
            menuItems
            ShareLink(item: track.permalinkURL, preview: SharePreview(track.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .trackActionSheets(setlist: $setlistTrack, trim: $trimTrack)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isPlayable {
                Button { addToQueue() } label: {
                    Label("Add to Up Next", systemImage: "text.append")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if isPlayable {
                TrackDownloadSwipeAction(track: track)
            }
        }
        .accessibilityElement(children: .combine)
        .modifier(TrackRowAccessibility(track: track, analysis: resolvedAnalysis, isPlayable: isPlayable, activity: activity))
        .accessibilityActions { menuItems }
    }

    private var menuItems: some View {
        TrackActionMenuItems(
            track: track,
            addToQueue: addToQueue,
            playOn: playOn,
            showSetlist: { setlistTrack = track },
            editTrim: { trimTrack = track }
        )
    }
}

struct TrackActionMenuItems: View {
    let track: Track
    let addToQueue: () -> Void
    var playOn: ((OutputDevice) -> Void)? = nil
    let showSetlist: () -> Void
    let editTrim: () -> Void

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.artistRouter) private var artistRouter

    private var isPlayable: Bool { track.streamURL != nil }

    var body: some View {
        BehindTheTrackMenuButton(track: track)
        LibraryTrackLinkMenuItems(track: track)
        if isPlayable {
            ForEach(coordinator.playOnDevices) { device in
                Button {
                    if let playOn {
                        playOn(device)
                    } else {
                        Task { await coordinator.play(track, in: [track], on: device) }
                    }
                } label: {
                    Label("Play on \(device.name)", systemImage: device.symbolName)
                }
            }
            Button { coordinator.playNext(track) } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            Button { addToQueue() } label: {
                Label("Add to Up Next", systemImage: "text.append")
            }
            TrackDownloadMenuItems(track: track)
        }
        AddToPlaylistMenuButton(track: track)
        RemoveFromPlaylistMenuItem(track: track)
        StartStationMenuButton(track: track)
        WakeToThisMenuButton(track: track)
        if let artistRouter {
            Button { artistRouter.open(track.user) } label: {
                Label("Go to Artist", systemImage: "person.crop.circle")
            }
        }
        TrackAlbumMenuItem(track: track)
        if DeckIdentityResolver.isLikelyMix(track) || SetlistIntelligenceStore.shared.setlist(for: track.id) != nil {
            Button(action: showSetlist) {
                Label("View Setlist", systemImage: "list.number")
            }
        }
        if isPlayable {
            Button(action: editTrim) {
                Label("Edit Start & End…", systemImage: "timeline.selection")
            }
        }
        TrackTempoKeyMenuItems(track: track)
        AnalyseMissingMenuItems(tracks: [track])
    }
}

struct TrackAlbumMenuItem: View {
    let track: Track

    @Environment(\.artistRouter) private var artistRouter

    var body: some View {
        if let artistRouter, let album = track.knownAlbum {
            Button { artistRouter.open(album: album) } label: {
                Label("Go to Album", systemImage: "square.stack")
                Text(album.title)
            }
        } else if let name = track.albumName {
            Button {} label: {
                Label(name, systemImage: "square.stack")
            }
            .disabled(true)
        }
    }
}

private struct TrackActionSheets: ViewModifier {
    @Binding var setlist: Track?
    @Binding var trim: Track?

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @State private var tempoKey: Track?

    func body(content: Content) -> some View {
        content
            .trackTempoKeySheet($tempoKey)
            .sheet(item: $trim) { track in
                TrackTrimEditor(track: track)
            }
            .sheet(item: $setlist) { track in
                SetlistEditorView(
                    track: track,
                    currentPosition: coordinator.nowPlaying?.trackId == track.id
                        ? coordinator.nowPlaying?.position ?? 0
                        : 0,
                    comments: [],
                    localFileURL: PlayerService.shared.localAudioURL(for: track),
                    onSeek: { position in preview(track, at: position) },
                    onDownload: { DownloadManager.shared.download(track: track, confirmed: true) },
                    onPlaySearchResult: { result in
                        Task { await coordinator.play(result, in: [result]) }
                    }
                )
            }
    }

    private func preview(_ track: Track, at position: TimeInterval) {
        if coordinator.nowPlaying?.trackId == track.id {
            coordinator.seek(to: position)
            return
        }
        Task {
            _ = await coordinator.play(track, in: [track])
            coordinator.seek(to: position)
        }
    }
}

extension View {
    func trackActionSheets(setlist: Binding<Track?>, trim: Binding<Track?>) -> some View {
        modifier(TrackActionSheets(setlist: setlist, trim: trim))
    }
}

private struct TrackRowAccessibility: ViewModifier {
    let track: Track
    let analysis: TrackAnalysisSummary?
    let isPlayable: Bool
    let activity: TrackRowActivity

    @ObservedObject private var downloadManager = DownloadManager.shared

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(TrackAccessibility.label(
                title: track.title,
                artist: track.user.displayName,
                duration: isPlayable && !track.isAwaitingLocalMetadata ? track.formattedDuration : nil,
                isDownloaded: downloadManager.state(for: track.id) == .downloaded,
                isUnavailable: !isPlayable,
                analysis: analysis
            ))
            .accessibilityValue(activityValue)
            .accessibilityHint(isPlayable ? "Plays on this device" : "This track isn't available to play")
    }

    private var activityValue: String {
        switch activity {
        case .none: return ""
        case .loading: return "Loading"
        case .playing: return "Now playing"
        case .paused: return "Paused"
        }
    }
}

struct TrackDownloadMenuItems: View {
    let track: Track
    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.downloadPrompter) private var prompter

    var body: some View {
        if downloadManager.downloadRefusalReason(for: track) == nil {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch downloadManager.state(for: track.id) {
        case .notDownloaded:
            Button { download() } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        case .queued, .downloading:
            if case .queued = downloadManager.state(for: track.id), let reason = downloadManager.waitingReason {
                Text(reason)
            }
            Button(role: .destructive) { downloadManager.removeDownload(.track(track.id)) } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        case .paused:
            Button { downloadManager.resume(trackId: track.id) } label: {
                Label("Resume Download", systemImage: "arrow.down.circle")
            }
            Button(role: .destructive) { downloadManager.removeDownload(.track(track.id)) } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        case .downloaded:
            Button(role: .destructive) { downloadManager.removeDownload(.track(track.id)) } label: {
                Label("Remove Download", systemImage: "trash")
            }
        case .failed(let reason):
            Text("Download failed: \(reason)")
            Button { download() } label: {
                Label("Retry Download", systemImage: "arrow.clockwise")
            }
        }
    }

    private func download() {
        prompter.request { confirmed in
            downloadManager.download(track: track, confirmed: confirmed)
        }
    }
}

struct TrackDownloadSwipeAction: View {
    let track: Track
    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.downloadPrompter) private var prompter

    var body: some View {
        if downloadManager.downloadRefusalReason(for: track) == nil {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch downloadManager.state(for: track.id) {
        case .notDownloaded, .failed:
            Button {
                prompter.request { confirmed in
                    downloadManager.download(track: track, confirmed: confirmed)
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        case .queued, .downloading, .paused:
            Button(role: .destructive) { downloadManager.removeDownload(.track(track.id)) } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
        case .downloaded:
            Button(role: .destructive) { downloadManager.removeDownload(.track(track.id)) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

struct TrackDownloadStatusGlyph: View {
    let trackId: String
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var failureReason: String?

    var body: some View {
        switch downloadManager.state(for: trackId) {
        case .notDownloaded:
            EmptyView()
        case .queued:
            Image(systemName: "clock")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(downloadManager.waitingReason ?? "Waiting to download")
        case .downloading:
            DownloadFractionReader(trackId: trackId) { fraction in
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .accessibilityLabel("Downloading")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            }
        case .paused:
            Image(systemName: "arrow.down.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Download paused")
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Downloaded")
        case .failed(let reason):
            Button {
                failureReason = reason
            } label: {
                Image(systemName: "exclamationmark.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download failed")
            .accessibilityHint("Shows why")
            .alert("Download Failed", isPresented: Binding(
                get: { failureReason != nil },
                set: { if !$0 { failureReason = nil } }
            ), presenting: failureReason) { _ in
                Button("OK", role: .cancel) { failureReason = nil }
            } message: { reason in
                Text(reason)
            }
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: Spacing.md) {
            PlaylistArtworkView(
                identity: playlist.id,
                artworkURL: playlist.displayArtworkURL,
                trackArtworkURLs: (playlist.tracks ?? []).compactMap(\.artworkURL),
                style: .phone
            )
            .frame(width: 56, height: 56)
            .kyleCrowned(user: playlist.user, context: playlist.title)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title)
                    .font(.scBody)
                    .scAdaptiveLineLimit()
                Text(privateMarked: "\(playlist.trackCount.trackCountLabel) \u{00B7} \(playlist.user.displayName)", isPrivate: playlist.isPrivate)
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .scAdaptiveLineLimit()
            }

            Spacer(minLength: Spacing.sm)
        }
        .padding(.vertical, Spacing.xs)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 56 + Spacing.md }
        .playlistTrackDropTarget(playlist)
    }
}

struct UserRow: View {
    let user: User

    var body: some View {
        HStack(spacing: Spacing.md) {
            ArtworkThumbnail(
                url: user.avatarURL,
                systemImage: "person.fill",
                isCircle: true,
                size: 48,
                identity: user.id,
                crownUser: user,
                crownContext: user.displayName
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(user.displayName)
                    .font(.scBody)
                    .scAdaptiveLineLimit()
                Text(user.followersLabel)
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .scAdaptiveLineLimit()
            }

            Spacer(minLength: Spacing.sm)
        }
        .padding(.vertical, Spacing.xs)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 48 + Spacing.md }
    }
}

struct LoadingMoreRow: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .listRowSeparator(.hidden)
    }
}

struct ArtworkThumbnail: View {
    let url: URL?
    var systemImage: String = "music.note"
    var isCircle: Bool = false
    var size: CGFloat = 52
    var cornerRadius: CGFloat = Radius.sm
    var identity: String?
    var crownUser: User?
    var crownContext: String?

    static func variant(forSize size: CGFloat) -> ArtworkVariant {
        size <= 64 ? .thumbnail : .standard
    }

    var body: some View {
        ArtworkImage(url: url, variant: Self.variant(forSize: size)) {
            placeholder
        }
        .frame(width: size, height: size)
        .clipShape(isCircle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        .kyleCrowned(user: crownUser, context: crownContext)
    }

    @ViewBuilder
    private var placeholder: some View {
        if let seed = identity.flatMap({ $0.isEmpty ? nil : $0 }) ?? url?.absoluteString {
            SoundingArtworkView(
                identity: seed,
                subject: isCircle || systemImage.hasPrefix("person") ? .person : ArtworkPlaceholder.subject(for: systemImage),
                displaySize: CGSize(width: size, height: size)
            )
        } else {
            ZStack {
                Color.primary.opacity(0.08)
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.34))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        LibraryBrowserView(models: LibraryModels())
    }
    .environmentObject(PhonePlaybackCoordinator(client: CompanionClient()))
    .preferredColorScheme(.dark)
}
