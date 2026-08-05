import SwiftUI
import os

private enum HomeLog {
    static let logger = Logger(subsystem: "red.forbes.sounding", category: "home")
}

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject var playerService: PlayerService
    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var navigationState: NavigationState
    @FocusState private var focus: BrowseFocus?

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                if viewModel.shelves.isEmpty {
                    homeStatus
                        .padding(.horizontal, SCBrowseMetrics.pageInset)
                } else {
                    LazyVStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
                        ForEach(Array(viewModel.shelves.enumerated()), id: \.element.id) { index, shelf in
                            shelfView(shelf, isFirst: index == 0)
                                .focusSection()
                        }
                    }
                    .padding(.top, SCBrowseMetrics.contentTopInset)
                    .padding(.bottom, SCBrowseMetrics.shelfGap)
                }
            }
            .background { BrowseBackdrop() }
            .scrollClipDisabled()
            .frame(maxHeight: .infinity, alignment: .top)
        }
        // Keep the system title area transparent so Home shares the same
        // backdrop as the rest of the TV shell instead of introducing a
        // mismatched navigation-bar color above the content.
        .toolbarBackground(.hidden, for: .navigationBar)
        .defaultFocus($focus, .firstCard)
        .onAppear { DispatchQueue.main.async { focus = .firstCard } }
        .task { await viewModel.loadContent() }
        .onChange(of: authService.isAuthenticated) { _, isAuthed in
            if isAuthed {
                Task { await viewModel.loadContent() }
            } else {
                viewModel.reset()
            }
        }
        .onChange(of: navigationState.selectedTab) { _, tab in
            if tab == .home {
                Task { await viewModel.refreshIfStale() }
            }
        }
        .onChange(of: viewModel.shelves.first?.id) { _, newID in
            if newID != nil, focus == nil {
                focus = .firstCard
            }
        }
    }

    @ViewBuilder
    private func shelfView(_ shelf: HomeShelf, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            SCSectionHeader(title: shelf.title, style: SCBrowseMetrics.header)
                .padding(.horizontal, SCBrowseMetrics.pageInset)

            switch shelf.items {
            case .tracks(let tracks):
                TrackShelf(
                    tracks: tracks,
                    focusFirst: isFirst ? $focus : nil,
                    identifierPrefix: shelf.id,
                    progressByTrackID: shelf.progressByTrackID
                )
            case .collections(let collections, let module):
                CollectionShelf(
                    collections: collections,
                    module: module,
                    focusFirst: isFirst ? $focus : nil,
                    identifierPrefix: shelf.id
                )
            case .entries(let entries):
                EntryShelf(
                    entries: entries,
                    focusFirst: isFirst ? $focus : nil,
                    identifierPrefix: shelf.id
                )
            case .artists(let users):
                ArtistShelf(
                    users: users,
                    focusFirst: isFirst ? $focus : nil,
                    identifierPrefix: shelf.id
                )
            }
        }
    }

    @ViewBuilder
    private var homeStatus: some View {
        if viewModel.isLoading {
            StatusPanel(kind: .loading, title: "Loading your music…", minHeight: 700)
        } else if let error = viewModel.errorMessage {
            StatusPanel(
                kind: .error,
                title: "Couldn't load your music",
                message: error,
                actionTitle: "Try Again",
                action: { Task { await viewModel.loadContent() } },
                minHeight: 700
            )
        } else if !authService.isAuthenticated {
            StatusPanel(
                kind: .empty,
                icon: "qrcode",
                title: "Sign in to get started",
                message: "Scan the code with your iPhone to sign in to SoundCloud.",
                actionTitle: "Sign In",
                action: { NotificationCenter.default.post(name: .sessionExpired, object: nil) },
                minHeight: 700
            )
        } else {
            StatusPanel(
                kind: .empty,
                icon: "music.note",
                title: "Nothing to discover yet",
                message: "SoundCloud had no suggestions this time. Play a few tracks and Home will build itself around what you listen to.",
                actionTitle: "Refresh",
                action: { Task { await viewModel.loadContent() } },
                minHeight: 700
            )
        }
    }
}

enum SCBrowseMetrics {

    static let tileEdge: CGFloat = 260
    static let gutter: CGFloat = Space.gutter          // 40

    static let cardWidth: CGFloat = 410
    static let cardHeight: CGFloat = 550
    static var cardPitch: CGFloat { cardWidth + gutter }

    static let heroWidth: CGFloat = 860
    static let heroHeight: CGFloat = 650

    static let pageInset: CGFloat = 0
    /// Clears the floating sidebar-adaptable tab capsule, which extends below
    /// the system-reported safe area when expanded.
    static let contentTopInset: CGFloat = 12

    static let headerGap: CGFloat = Space.base         // 24
    static let shelfGap: CGFloat = Spacing.xxxl        // 64
    static let rowSpacing: CGFloat = 14

    static let editorialCorner: CGFloat = Corner.card    // 18
    static let heroCorner: CGFloat = Corner.panel        // 32
    static let rowCardCorner: CGFloat = Corner.panel     // 32

    static let header: SCContentStyle = {
        var style = SCContentStyle.tv
        style.fontTitle = .tvSection                   // 32pt heavy
        style.textPrimary = .white.opacity(0.76)
        return style
    }()

    static let tile: SCContentStyle = {
        var style = SCContentStyle.tv
        style.textSecondary = SCContentStyle.tv.textTertiary
        return style
    }()

    static let row: SCContentStyle = {
        var style = SCContentStyle.tv
        style.cornerControl = Corner.thumb               // 9
        return style
    }()
}

struct BrowseBackdrop: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 48 / 255, green: 59 / 255, blue: 63 / 255), location: 0.0),
                .init(color: Color(red: 38 / 255, green: 43 / 255, blue: 44 / 255), location: 0.45),
                .init(color: Color(red: 29 / 255, green: 31 / 255, blue: 30 / 255), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct TrackShelf: View {
    let tracks: [Track]
    var isLoadingMore = false
    var onNearEnd: (() async -> Void)?
    var focusFirst: FocusState<BrowseFocus?>.Binding?
    var identifierPrefix: String = "shelf"
    var progressByTrackID: [String: Double] = [:]

    @EnvironmentObject var playerService: PlayerService

    private var pageLead: Int { 8 }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: SCBrowseMetrics.gutter) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    card(track, index: index)
                }

                if isLoadingMore {
                    LoadingMoreRow()
                }
            }
        }
        .scrollClipDisabled()
        .safeAreaPadding(.horizontal, SCBrowseMetrics.pageInset)
        .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control))
        .focusEffectDisabled()
        .prefetchArtwork(tracks.compactMap(\.artworkURL))
    }

    @ViewBuilder
    private func card(_ track: Track, index: Int) -> some View {
        let button = Button {
            Task { await playerService.play(track, in: tracks) }
        } label: {
            SCArtworkResolver(url: track.artworkURL) { image in
                SCMediaCard(
                    title: track.title,
                    subtitle: track.user.displayName,
                    artworkImage: image,
                    isAvailable: track.streamURL != nil,
                    style: SCBrowseMetrics.tile,
                    progress: progressByTrackID[track.id]
                )
                .kyleCrowned(user: track.user, context: track.title)
            }
            .frame(width: SCBrowseMetrics.tileEdge)
        }
        .accessibilityIdentifier("\(identifierPrefix).card.\(index)")
        .onAppear {
            guard let onNearEnd, tracks.isNearEnd(track, lead: pageLead) else { return }
            Task { await onNearEnd() }
        }

        if index == 0, let focusFirst {
            button.focused(focusFirst, equals: .firstCard)
        } else {
            button
        }
    }
}

enum CollectionModule: Equatable {
    case cards
    case tiles
}

struct CollectionShelf: View {
    let collections: [HomeCollection]
    var module: CollectionModule = .cards
    var focusFirst: FocusState<BrowseFocus?>.Binding?
    var identifierPrefix: String = "shelf"

    private var cornerRadius: CGFloat {
        switch module {
        case .cards: return SCBrowseMetrics.editorialCorner   // 18, measured 17–19
        case .tiles: return Corner.control                    // 14, measured 12–16
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: SCBrowseMetrics.gutter) {
                ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
                    card(collection, index: index)
                }
            }
        }
        .scrollClipDisabled()
        .safeAreaPadding(.horizontal, SCBrowseMetrics.pageInset)
        .buttonStyle(SCCardButtonStyle(cornerRadius: cornerRadius))
        .focusEffectDisabled()
        .prefetchArtwork(
            collections.compactMap(\.artworkURL),
            variant: module == .cards ? .hero : .standard
        )
    }

    @ViewBuilder
    private func card(_ collection: HomeCollection, index: Int) -> some View {
        let link = NavigationLink {
            PlaylistDetailView(playlist: collection.playlist)
        } label: {
            switch module {
            case .cards: editorialCard(collection)
            case .tiles: tile(collection)
            }
        }
        .accessibilityIdentifier("\(identifierPrefix).card.\(index)")

        if index == 0, let focusFirst {
            link.focused(focusFirst, equals: .firstCard)
        } else {
            link
        }
    }

    @ViewBuilder
    private func editorialCard(_ collection: HomeCollection) -> some View {
        SCCollectionArtworkResolver(
            artworkURL: collection.artworkURL,
            trackArtworkURLs: collection.mosaicURLs,
            variant: .hero
        ) { image in
            SCHeroCard(
                eyebrow: collection.kicker,
                title: collection.title,
                description: collection.subtitle,
                backgroundImage: image,
                style: SCContentStyle.tv,
                cornerRadius: SCBrowseMetrics.editorialCorner
            )
            .kyleCrowned(user: collection.playlist.user, context: collection.title)
            .frame(width: SCBrowseMetrics.cardWidth, height: SCBrowseMetrics.cardHeight)
        }
    }

    @ViewBuilder
    private func tile(_ collection: HomeCollection) -> some View {
        SCCollectionArtworkResolver(
            artworkURL: collection.artworkURL,
            trackArtworkURLs: collection.mosaicURLs
        ) { image in
            SCMediaCard(
                title: collection.title,
                subtitle: collection.subtitle,
                artworkImage: image,
                style: SCBrowseMetrics.tile
            )
            .kyleCrowned(user: collection.playlist.user, context: collection.title)
        }
        .frame(width: SCBrowseMetrics.tileEdge)
    }
}

struct EntryShelf: View {
    let entries: [DiscoveryEntry]
    var focusFirst: FocusState<BrowseFocus?>.Binding?
    var identifierPrefix: String = "shelf"

    @EnvironmentObject var playerService: PlayerService
    @State private var hydratingID: String?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: SCBrowseMetrics.gutter) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    card(entry, index: index)
                }
            }
        }
        .scrollClipDisabled()
        .safeAreaPadding(.horizontal, SCBrowseMetrics.pageInset)
        .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control))
        .focusEffectDisabled()
        .prefetchArtwork(entries.compactMap(\.artworkURL))
    }

    @ViewBuilder
    private func card(_ entry: DiscoveryEntry, index: Int) -> some View {
        let content = Group {
            switch entry {
            case .station(let station):
                Button { Task { await play(station) } } label: { tile(entry) }
            case .playlist(let playlist):
                NavigationLink { PlaylistDetailView(playlist: playlist) } label: { tile(entry) }
            case .user(let user):
                NavigationLink { ArtistDetailView(user: user) } label: {
                    SCArtworkResolver(url: entry.artworkURL) { image in
                        SCArtistCard(
                            name: entry.cardTitle,
                            subtitle: entry.cardSubtitle,
                            avatarImage: image,
                            diameter: SCBrowseMetrics.tileEdge,
                            style: SCBrowseMetrics.tile
                        )
                        .kyleCrowned(user: user, context: entry.cardTitle)
                    }
                }
                .buttonStyle(SCArtistCardButtonStyle())
            }
        }
        .accessibilityIdentifier("\(identifierPrefix).card.\(index)")

        if index == 0, let focusFirst {
            content.focused(focusFirst, equals: .firstCard)
        } else {
            content
        }
    }

    @ViewBuilder
    private func tile(_ entry: DiscoveryEntry) -> some View {
        SCArtworkResolver(url: entry.artworkURL) { image in
            SCMediaCard(
                title: entry.cardTitle,
                subtitle: entry.cardSubtitle,
                artworkImage: image,
                style: SCBrowseMetrics.tile
            )
            .kyleCrowned(user: entry.crownUser, context: entry.cardTitle)
            .overlay(alignment: .top) {
                if hydratingID == entry.id {
                    Color.black.opacity(0.45)
                        .overlay { ProgressView().controlSize(.large) }
                        .frame(height: SCBrowseMetrics.tileEdge)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                }
            }
        }
        .frame(width: SCBrowseMetrics.tileEdge)
    }

    private func play(_ station: SystemPlaylist) async {
        hydratingID = station.id
        defer { hydratingID = nil }
        guard let tracks = try? await SoundCloudAPI.shared.getSystemPlaylistTracks(station) else {
            HomeLog.logger.error("station \(station.id, privacy: .public) failed to hydrate")
            return
        }
        guard let first = tracks.first(where: { $0.streamURL != nil }) else {
            HomeLog.logger.info("station \(station.id, privacy: .public) hydrated to nothing playable")
            return
        }
        await playerService.play(first, in: tracks)
    }
}

struct ArtistShelf: View {
    let users: [User]
    var focusFirst: FocusState<BrowseFocus?>.Binding?
    var identifierPrefix: String = "shelf"
    var unreadUserIDs: Set<String> = []

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: SCBrowseMetrics.gutter) {
                ForEach(Array(users.enumerated()), id: \.element.id) { index, user in
                    card(user, index: index)
                }
            }
        }
        .scrollClipDisabled()
        .safeAreaPadding(.horizontal, SCBrowseMetrics.pageInset)
        .buttonStyle(SCArtistCardButtonStyle())
        .focusEffectDisabled()
        .prefetchArtwork(users.compactMap { $0.largeAvatarURL ?? $0.avatarURL })
    }

    @ViewBuilder
    private func card(_ user: User, index: Int) -> some View {
        let link = NavigationLink {
            ArtistDetailView(user: user)
        } label: {
            SCArtworkResolver(url: user.largeAvatarURL ?? user.avatarURL) { image in
                SCArtistCard(
                    name: user.displayName,
                    subtitle: "\(user.formattedFollowers) followers",
                    avatarImage: image,
                    hasUnread: unreadUserIDs.contains(user.id),
                    diameter: SCBrowseMetrics.tileEdge,
                    style: SCBrowseMetrics.tile
                )
                .kyleCrowned(user: user, context: user.displayName)
            }
        }
        .accessibilityIdentifier("\(identifierPrefix).card.\(index)")

        if index == 0, let focusFirst {
            link.focused(focusFirst, equals: .firstCard)
        } else {
            link
        }
    }
}

private struct SCArtistCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusedLabel(configuration: configuration)
    }

    private struct FocusedLabel: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scFocus(isFocused, in: SCArtistCardFocusShape(), reduceMotion: reduceMotion)
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

enum BrowseFocus: Hashable {
    case firstCard
}

struct HomeShelf: Identifiable {
    enum Items {
        case tracks([Track])
        case collections([HomeCollection], CollectionModule)
        case entries([DiscoveryEntry])
        case artists([User])
    }

    let id: String
    let title: String
    var items: Items
    var progressByTrackID: [String: Double] = [:]
}

struct HomeCollection: Identifiable {
    let id: String
    let title: String
    let kicker: String
    let subtitle: String?
    let playlist: Playlist

    let mosaicURLs: [URL]

    var artworkURL: URL? {
        playlist.largeArtworkURL ?? playlist.artworkURL
    }

    init(playlist: Playlist, kicker: String) {
        self.id = "collection.\(playlist.id)"
        self.title = playlist.title
        self.kicker = kicker
        self.playlist = playlist

        let count = playlist.trackCount
        self.subtitle = count > 0
            ? "\(count == 1 ? "1 track" : "\(count) tracks") \u{00B7} \(playlist.user.displayName)"
            : playlist.user.displayName

        var seen = Set<String>()
        var urls: [URL] = []
        for track in playlist.tracks ?? [] {
            guard let url = track.artworkURL, seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
            if urls.count == 4 { break }
        }
        self.mosaicURLs = urls
    }
}

@MainActor
class HomeViewModel: ObservableObject {
    @Published private(set) var shelves: [HomeShelf] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published private var continueListening: [Track] = []
    @Published private var continueProgress: [String: Double] = [:]

    @Published private var discoveryShelves: [DiscoveryShelf] = []
    private let discovery = DiscoveryHomeSource()

    #if DEBUG
    #endif

    @Published var streamTracks: [Track] = []
    @Published var likedTracks: [Track] = []

    private let api = SoundCloudAPI.shared
    private var lastLoaded: Date?

    private let staleAfter: TimeInterval = 5 * 60

    private func rebuildShelves() {
        var built: [HomeShelf] = []

        var previousWasCards = false
        var remaining = discoveryShelves.filter { !$0.isEmpty }

        // Apple Music gives the first frame an editorial identity. Keep resume
        // nearby, but never let it replace the opening recommendation shelf.
        if let first = remaining.first {
            built.append(Self.homeShelf(
                from: first,
                previousWasCards: &previousWasCards,
                titleOverride: "Top Picks for You",
                kickerOverride: "Made for You"
            ))
            remaining.removeFirst()
        }

        if !continueListening.isEmpty {
            built.append(HomeShelf(
                id: "home.continue",
                title: TopShelfStore.recentsTitle,
                items: .tracks(continueListening),
                progressByTrackID: continueProgress
            ))
            previousWasCards = false
        }

        for shelf in remaining {
            built.append(Self.homeShelf(from: shelf, previousWasCards: &previousWasCards))
        }

        #if DEBUG
        #endif

        shelves = built

        #if DEBUG
        for (index, shelf) in built.enumerated() {
            let shape: String
            switch shelf.items {
            case .tracks(let tracks): shape = "tracks×\(tracks.count)"
            case .collections(let collections, let module):
                shape = "\(module == .cards ? "cards" : "tiles")×\(collections.count)"
            case .entries(let entries):
                let stations = entries.filter { if case .station = $0 { return true } else { return false } }.count
                let users = entries.filter { if case .user = $0 { return true } else { return false } }.count
                shape = "entries×\(entries.count) (stations×\(stations), users×\(users))"
            case .artists(let users): shape = "artists×\(users.count)"
            }
            HomeLog.logger.info("shelf[\(index, privacy: .public)] \(shape, privacy: .public) \(shelf.id, privacy: .public) \"\(shelf.title, privacy: .public)\"")
        }
        #endif
    }

    private static func homeShelf(
        from shelf: DiscoveryShelf,
        previousWasCards: inout Bool,
        titleOverride: String? = nil,
        kickerOverride: String? = nil
    ) -> HomeShelf {
        let title = titleOverride ?? shelf.title
        switch shelf.content {
        case .tracks(let tracks):
            previousWasCards = false
            return HomeShelf(id: shelf.id, title: title, items: .tracks(tracks))
        case .playlists(let playlists):
            let collections = playlists.map {
                HomeCollection(
                    playlist: $0,
                    kicker: kickerOverride ?? ($0.isAlbum ? "Album" : "Playlist")
                )
            }
            let module: CollectionModule = previousWasCards ? .tiles : .cards
            previousWasCards = (module == .cards)
            return HomeShelf(
                id: shelf.id,
                title: title,
                items: .collections(collections, module)
            )
        case .stations(let stations):
            previousWasCards = false
            return HomeShelf(
                id: shelf.id,
                title: title,
                items: .entries(stations.map(DiscoveryEntry.station))
            )
        case .users(let users):
            previousWasCards = false
            return HomeShelf(id: shelf.id, title: title, items: .artists(users))
        case .mixed(let entries):
            previousWasCards = false
            return HomeShelf(id: shelf.id, title: title, items: .entries(entries))
        }
    }

    func reset() {
        continueListening = []
        continueProgress = [:]
        discoveryShelves = []
        #if DEBUG
        #endif
        streamTracks = []
        likedTracks = []
        errorMessage = nil
        lastLoaded = nil
        discovery.reset()
        rebuildShelves()
    }

    func refreshIfStale() async {
        guard let lastLoaded else {
            await loadContent()
            return
        }
        if Date().timeIntervalSince(lastLoaded) > staleAfter {
            await loadContent()
        }
    }

    func loadContent() async {
        #if DEBUG
        if VisualFixtures.isEnabled {
            shelves = VisualFixtures.homeShelves
            errorMessage = nil
            lastLoaded = Date()
            return
        }
        #endif

        guard AuthenticationService.shared.isAuthenticated else { return }

        isLoading = true
        defer { isLoading = false }

        if let recents = await fetchContinueListening() {
            continueListening = recents.tracks
            continueProgress = recents.progress
        }

        async let topShelf: Void = refreshTopShelf()
        await discovery.load(seed: seed())
        await topShelf

        discoveryShelves = discovery.shelves
        rebuildShelves()

        if shelves.isEmpty && discovery.didFailForCredentials {
            errorMessage = "SoundCloud rejected this Apple TV's sign-in, so nothing could load. If it keeps happening, sign in again from Settings."
        } else if shelves.isEmpty && discovery.didFailCompletely {
            errorMessage = "Couldn't reach SoundCloud. Check this Apple TV's network connection."
        } else {
            errorMessage = nil
            if !shelves.isEmpty { lastLoaded = Date() }
        }
    }

    private func seed() -> DiscoveryHomeSource.Seed {
        if let current = PlayerService.shared.currentTrack {
            return .init(track: current)
        }
        if let latest = continueListening.first {
            return .init(track: latest)
        }
        return .init()
    }

    private func fetchContinueListening() async -> (tracks: [Track], progress: [String: Double])? {
        guard let entries = TopShelfStore.load()?.section(kind: TopShelfStore.recentsKind)?.entries,
              !entries.isEmpty else { return ([], [:]) }

        let ids = entries.map(\.id)
        guard let tracks = try? await api.getTracks(ids: ids) else { return nil }

        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let progress = Dictionary(
            entries.map { ($0.id, $0.progress) },
            uniquingKeysWith: { first, _ in first }
        )
        return (ids.compactMap { byID[$0] }, progress)
    }

    private func refreshTopShelf() async {
        async let streamResult: Page<StreamItem>? = {
            do { return try await api.getStream(limit: 20) }
            catch { print("Top Shelf stream load error: \(error)"); return nil }
        }()
        async let likedResult: Page<Like<Track>>? = {
            guard await AuthenticationService.shared.waitForCurrentUser() != nil else { return nil }
            do { return try await api.getLikedTracks(limit: 20) }
            catch { print("Top Shelf likes load error: \(error)"); return nil }
        }()

        let (stream, liked) = await (streamResult, likedResult)
        if let stream { streamTracks = stream.collection.compactMap { $0.track } }
        if let liked { likedTracks = liked.collection.map { $0.item } }

        TopShelfPublisher.publish(stream: streamTracks, liked: likedTracks)
    }

}
