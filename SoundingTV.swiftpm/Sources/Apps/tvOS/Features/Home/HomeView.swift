import SwiftUI
import Combine
import os

private enum HomeLog {
    static let logger = Logger(subsystem: "red.forbes.sounding", category: "home")
}

struct HomeView: View {
    @ObservedObject private var viewModel = HomeViewModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var playerService: PlayerService
    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var navigationState: NavigationState
    @ObservedObject private var continueFrom = ContinueFrom.shared
    @ObservedObject private var presence = DevicePresenceModel.shared
    @FocusState private var focus: BrowseFocus?
    @State private var showsInitialLoadingIndicator = false
    @State private var showingDJStartConfiguration = false
    @State private var heroArtworkURL: URL?

    private var layout: HomeLayout {
        HomeLayout(
            shelves: viewModel.shelves,
            offer: continueFrom.offer,
            nowPlaying: playerService.currentTrack,
            isPlaying: playerService.isPlaying,
            otherDevice: presence.primary
        )
    }

    var body: some View {
        let layout = self.layout
        NavigationStack {
            GeometryReader { proxy in
                let inset = max(proxy.safeAreaInsets.leading, SCBrowseMetrics.sideMargin)
                ScrollView(.vertical) {
                    if layout.isEmpty {
                        homeStatus
                            .padding(.horizontal, inset)
                            .padding(.top, proxy.safeAreaInsets.top)
                    } else {
                        LazyVStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
                            if !layout.hero.isEmpty {
                                HomeHeroCarousel(
                                    items: layout.hero,
                                    inset: inset,
                                    isAutoMixOn: playerService.isAutoMixEnabled,
                                    focus: $focus,
                                    action: perform,
                                    currentArtwork: $heroArtworkURL
                                )
                                .focusSection()
                            }

                            ForEach(Array(layout.shelves.enumerated()), id: \.element.id) { index, shelf in
                                shelfView(shelf, isFirst: index == 0 && layout.hero.isEmpty)
                                    .safeAreaPadding(.horizontal, inset)
                                    .focusSection()
                            }

                            if layout.shelves.isEmpty {
                                homeStatus
                                    .padding(.horizontal, inset)
                            }
                        }
                        .animation(reduceMotion ? nil : .smooth, value: layout.shelves.map(\.id))
                        .padding(.top, layout.hero.isEmpty ? proxy.safeAreaInsets.top + SCBrowseMetrics.contentTopInset : 0)
                        .padding(.bottom, SCBrowseMetrics.shelfGap)
                    }
                }
                .scrollClipDisabled()
                .ignoresSafeArea(edges: [.top, .horizontal])
            }
            .background {
                ZStack {
                    BrowseBackdrop()
                    CollectionPageMesh(url: layout.hero.isEmpty ? nil : heroArtworkURL)
                }
                .ignoresSafeArea()
            }
            .navigationDestination(item: $navigationState.homeDestination) { destination in
                switch destination {
                case .track(let track):
                    BehindTheTrackView(track: track, palette: ArtworkColors.shared.current)
                case .playlist(let playlist):
                    PlaylistDetailView(playlist: playlist)
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .defaultFocus($focus, .firstCard)
        .onAppear { DispatchQueue.main.async { focus = .firstCard } }
        .sheet(isPresented: $showingDJStartConfiguration) {
            AutoDJStartConfigurationView { configuration in
                playerService.startDJSession(configuration: configuration)
                navigationState.showNowPlaying()
            }
        }
        .task { await viewModel.refreshIfStale() }
        .task(id: viewModel.isLoading && viewModel.shelves.isEmpty) {
            showsInitialLoadingIndicator = false
            guard viewModel.isLoading, viewModel.shelves.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, viewModel.isLoading, viewModel.shelves.isEmpty else { return }
            showsInitialLoadingIndicator = true
        }
        .onChange(of: authService.isAuthenticated) { _, isAuthed in
            if isAuthed {
                Task { await viewModel.refreshIfStale() }
            } else if SoundCloudCredentialSource.shared.isSignedOut {
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

    private func perform(_ item: HomeHeroItem, _ role: HomeHeroItem.Role) {
        switch (item.kind, role) {
        case (.continueFrom(let offer), .primary):
            continueFrom.accept(offer, play: true)
        case (.continueFrom(let offer), .secondary):
            withAnimation { continueFrom.dismiss(offer) }
        case (.otherDevice(let entry), _):
            presence.perform(.playHere, on: entry)
        case (.nowPlaying, .primary):
            if !playerService.playbackRequested, !playerService.isPlaying {
                playerService.play()
            }
            navigationState.showNowPlaying()
        case (.nowPlaying, .secondary):
            startOrOpenAutoMix()
        case (.track(let track, let queue), .primary):
            Task { await playerService.play(track, in: queue) }
        case (.track(let track, _), .secondary):
            navigationState.homeDestination = .track(track)
        case (.playlist(let playlist), .primary):
            Task { await PlayActions.play(playlist: playlist) }
        case (.playlist(let playlist), .secondary):
            navigationState.homeDestination = .playlist(playlist)
        case (.station(let station), _):
            Task { await HomeStations.play(station) }
        }
    }

    private func startOrOpenAutoMix() {
        if playerService.isAutoMixEnabled {
            navigationState.showNowPlaying()
        } else if playerService.isDJSessionEnabled {
            playerService.setAutomaticMixEnabled(true)
            navigationState.showNowPlaying()
        } else if SettingsStore.shared.hasStoredValue(SettingKeys.DJStartOptions.self) {
            playerService.startDJSession(configuration: SettingsStore.shared.djStartConfiguration)
            navigationState.showNowPlaying()
        } else {
            showingDJStartConfiguration = true
        }
    }

    @ViewBuilder
    private func shelfView(_ shelf: HomeShelf, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            SCSectionHeader(title: shelf.title, style: SCBrowseMetrics.header)
                .padding(.horizontal, SCBrowseMetrics.pageInset)
                .accessibilityAddTraits(.isHeader)

            switch shelf.items {
            case .tracks(let tracks):
                TrackShelf(
                    tracks: tracks,
                    focusFirst: isFirst ? $focus : nil,
                    identifierPrefix: shelf.id,
                    progressByTrackID: shelf.progressByTrackID
                )
            case .collections(let collections, let module):
                TVCollectionShelf(
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
            Group {
                if showsInitialLoadingIndicator {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .accessibilityLabel("Loading Home")
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
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
                message: "Scan the code with your phone's camera to sign in to SoundCloud.",
                actionTitle: "Sign In",
                action: { Task { await authService.logout() } },
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

    static let tileEdge: CGFloat = 300
    static let gutter: CGFloat = Space.gutter

    static let wideCardWidth: CGFloat = 560
    static let wideCardHeight: CGFloat = 315

    static let cardWidth: CGFloat = 410
    static let cardHeight: CGFloat = 550

    static let heroWidth: CGFloat = 860
    static let heroHeight: CGFloat = 650

    static let pageInset: CGFloat = 0
    static let sideMargin: CGFloat = Space.page
    static let contentTopInset: CGFloat = Space.base

    static let headerGap: CGFloat = Space.base
    static let shelfGap: CGFloat = 72
    static let rowSpacing: CGFloat = 14

    static let editorialCorner: CGFloat = Corner.card
    static let heroCorner: CGFloat = Corner.panel

    static let header: SCContentStyle = {
        var style = SCContentStyle.tv
        style.fontTitle = .tvHeadline
        style.textPrimary = .white
        style.textSecondary = .white.opacity(0.6)
        return style
    }()

    static let tile: SCContentStyle = {
        var style = SCContentStyle.tv
        style.textSecondary = SCContentStyle.tv.textTertiary
        return style
    }()

    static let row: SCContentStyle = {
        var style = SCContentStyle.tv
        style.cornerControl = Corner.thumb
        return style
    }()
}

struct BrowseBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color(white: 0.11), Color(white: 0.05)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
                    artIdentity: track.id,
                    isAvailable: track.streamURL != nil,
                    style: SCBrowseMetrics.tile,
                    progress: progressByTrackID[track.id]
                )
                .kyleCrowned(user: track.user, context: track.title)
            }
            .frame(width: SCBrowseMetrics.tileEdge)
        }
        .contextMenu { TVTrackMenuItems(track: track) }
        .accessibilityIdentifier("\(identifierPrefix).card.\(index)")
        .accessibilityLabel(trackCardLabel(track))
        .prewarmPlaybackOnFocus(track)
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

    private func trackCardLabel(_ track: Track) -> String {
        var label = TrackAccessibility.label(
            title: track.title,
            artist: track.user.displayName,
            duration: track.formattedDuration,
            isUnavailable: track.streamURL == nil
        )
        if let progress = SCMediaCard.resolvedProgress(progressByTrackID[track.id]) {
            label += ", \(Int((progress * 100).rounded())) percent played"
        }
        return label
    }
}

enum CollectionModule: Equatable {
    case cards
    case tiles
}

struct TVCollectionShelf: View {
    let collections: [HomeCollection]
    var module: CollectionModule = .cards
    var focusFirst: FocusState<BrowseFocus?>.Binding?
    var identifierPrefix: String = "shelf"
    var pinsLikes = false

    private var cornerRadius: CGFloat {
        switch module {
        case .cards: return SCBrowseMetrics.editorialCorner
        case .tiles: return Corner.control
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: SCBrowseMetrics.gutter) {
                if pinsLikes {
                    TVLikesPlaylistTile(identifier: "\(identifierPrefix).likes")
                }
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
        .accessibilityLabel([collection.kicker, collection.title, collection.subtitle].compactMap { $0 }.joined(separator: ", "))

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
            HomeWideCard(
                eyebrow: collection.kicker,
                title: collection.title,
                subtitle: collection.subtitle,
                image: image,
                identity: collection.playlist.id
            )
            .kyleCrowned(user: collection.playlist.user, context: collection.title)
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
                artIdentity: collection.playlist.id,
                artSubject: .collection,
                style: SCBrowseMetrics.tile,
                isPrivate: collection.playlist.isPrivate
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
                TVUserLink(user: user) {
                    SCArtworkResolver(url: entry.artworkURL) { image in
                        SCArtistCard(
                            name: entry.cardTitle,
                            subtitle: entry.cardSubtitle,
                            avatarImage: image,
                            identity: entry.artIdentity,
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
        .accessibilityLabel([entry.cardTitle, entry.cardSubtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(hydratingID == entry.id ? "Loading" : "")

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
                artIdentity: entry.artIdentity,
                artSubject: .station,
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
        await HomeStations.play(station)
    }
}

@MainActor
enum HomeStations {
    static func play(_ station: SystemPlaylist) async {
        guard let tracks = try? await SoundCloudAPI.shared.getSystemPlaylistTracks(station) else {
            HomeLog.logger.error("station \(station.id, privacy: .public) failed to hydrate")
            return
        }
        guard let first = tracks.first(where: { $0.streamURL != nil }) else {
            HomeLog.logger.info("station \(station.id, privacy: .public) hydrated to nothing playable")
            return
        }
        PlaybackQueueSourceDirectory.note(station)
        StationLibrary.shared.record(station)
        await PlayerService.shared.play(first, in: tracks, collectionId: station.id)
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
                    identity: user.id,
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

struct SCArtistCardButtonStyle: ButtonStyle {
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
    case hero(String)
    case heroAlt(String)
}

// MARK: - Hero

struct HomeHeroAction {
    let title: String
    var symbol: String?
    var identifier: String
}

struct HomeHeroItem: Identifiable {
    enum Kind {
        case continueFrom(ContinueFrom.Offer)
        case otherDevice(DevicePresenceEntry)
        case nowPlaying(Track, isPlaying: Bool)
        case track(Track, queue: [Track])
        case playlist(Playlist)
        case station(SystemPlaylist)
    }

    enum Role {
        case primary
        case secondary
    }

    let id: String
    var sourceID: String?
    let kind: Kind
    let eyebrow: String
    var eyebrowSymbol: String?
    let title: String
    var subtitle: String?
    let artworkURL: URL?
    let identity: String
    var artSubject: SoundingArtSubject = .track
    var progress: Double?
    var elapsed: String?
    var total: String?

    var primaryAction: HomeHeroAction {
        switch kind {
        case .continueFrom:
            return HomeHeroAction(title: "Play", symbol: "play.fill", identifier: "home.continueFrom.play")
        case .otherDevice:
            return HomeHeroAction(title: "Play Here", symbol: "play.fill", identifier: "home.otherDevice.playHere")
        case .nowPlaying(_, let isPlaying):
            return isPlaying
                ? HomeHeroAction(title: "Now Playing", symbol: "waveform", identifier: "home.hero.nowPlaying")
                : HomeHeroAction(title: "Play", symbol: "play.fill", identifier: "home.hero.nowPlaying")
        case .track, .playlist, .station:
            return HomeHeroAction(title: "Play", symbol: "play.fill", identifier: "home.hero.\(id).play")
        }
    }

    func secondaryAction(isAutoMixOn: Bool) -> HomeHeroAction? {
        switch kind {
        case .continueFrom:
            return HomeHeroAction(title: "Not Now", identifier: "home.continueFrom.dismiss")
        case .otherDevice:
            return nil
        case .nowPlaying:
            return HomeHeroAction(
                title: isAutoMixOn ? "Auto Mix On" : "Start Auto Mix",
                symbol: "wand.and.stars",
                identifier: "home.hero.autoMix"
            )
        case .track:
            return HomeHeroAction(title: "Behind the Track", symbol: "info.circle", identifier: "home.hero.\(id).about")
        case .playlist(let playlist):
            return HomeHeroAction(title: playlist.isAlbum ? "Go to Album" : "Go to Playlist", identifier: "home.hero.\(id).open")
        case .station:
            return nil
        }
    }

    static func continueFrom(_ offer: ContinueFrom.Offer) -> HomeHeroItem {
        let artist = offer.session.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return HomeHeroItem(
            id: "continue.\(offer.id)",
            kind: .continueFrom(offer),
            eyebrow: offer.heroCaption(),
            eyebrowSymbol: offer.session.deviceClass.symbolName,
            title: offer.session.title.isEmpty ? offer.deviceName : offer.session.title,
            subtitle: artist.isEmpty ? nil : artist,
            artworkURL: offer.session.artworkURL,
            identity: offer.session.trackID,
            progress: offer.progress,
            elapsed: ContinueSessions.clock(offer.position),
            total: offer.session.duration > 0 ? ContinueSessions.clock(offer.session.duration) : nil
        )
    }

    static func otherDevice(_ entry: DevicePresenceEntry, now: Date = Date()) -> HomeHeroItem {
        let artist = entry.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return HomeHeroItem(
            id: "presence.\(entry.id)",
            kind: .otherDevice(entry),
            eyebrow: entry.caption(at: now),
            eyebrowSymbol: entry.deviceClass.symbolName,
            title: entry.displayTitle,
            subtitle: artist.isEmpty ? nil : artist,
            artworkURL: entry.artworkURL,
            identity: entry.trackID
        )
    }

    static func nowPlaying(_ track: Track, isPlaying: Bool) -> HomeHeroItem {
        HomeHeroItem(
            id: "nowPlaying",
            kind: .nowPlaying(track, isPlaying: isPlaying),
            eyebrow: isPlaying ? "Playing" : "Paused",
            eyebrowSymbol: isPlaying ? "waveform" : "pause.fill",
            title: track.title,
            subtitle: track.user.displayName,
            artworkURL: track.largeArtworkURL ?? track.artworkURL,
            identity: track.id
        )
    }

    static func featured(from shelf: HomeShelf, limit: Int) -> [HomeHeroItem] {
        switch shelf.items {
        case .tracks(let tracks):
            let playable = tracks.filter { $0.streamURL != nil }
            return Array(playable.prefix(limit)).map { track in
                HomeHeroItem(
                    id: "featured.\(track.id)",
                    sourceID: track.id,
                    kind: .track(track, queue: tracks),
                    eyebrow: shelf.title,
                    title: track.title,
                    subtitle: track.user.displayName,
                    artworkURL: track.largeArtworkURL ?? track.artworkURL,
                    identity: track.id
                )
            }
        case .collections(let collections, _):
            return Array(collections.prefix(limit)).map { collection in
                HomeHeroItem(
                    id: "featured.\(collection.id)",
                    sourceID: collection.id,
                    kind: .playlist(collection.playlist),
                    eyebrow: collection.kicker,
                    title: collection.title,
                    subtitle: collection.subtitle,
                    artworkURL: collection.artworkURL,
                    identity: collection.playlist.id,
                    artSubject: .collection
                )
            }
        case .entries(let entries):
            let items: [HomeHeroItem] = entries.compactMap { entry in
                switch entry {
                case .playlist(let playlist):
                    return HomeHeroItem(
                        id: "featured.\(entry.id)",
                        sourceID: entry.id,
                        kind: .playlist(playlist),
                        eyebrow: shelf.title,
                        title: entry.cardTitle,
                        subtitle: entry.cardSubtitle,
                        artworkURL: entry.artworkURL,
                        identity: entry.artIdentity,
                        artSubject: .collection
                    )
                case .station(let station):
                    return HomeHeroItem(
                        id: "featured.\(entry.id)",
                        sourceID: entry.id,
                        kind: .station(station),
                        eyebrow: shelf.title,
                        title: entry.cardTitle,
                        subtitle: entry.cardSubtitle,
                        artworkURL: entry.artworkURL,
                        identity: entry.artIdentity,
                        artSubject: .station
                    )
                case .user:
                    return nil
                }
            }
            return Array(items.prefix(limit))
        case .artists:
            return []
        }
    }
}

struct HomeLayout {
    static let featuredLimit = 5
    static let minimumShelfCount = 4

    let hero: [HomeHeroItem]
    let shelves: [HomeShelf]

    var isEmpty: Bool { hero.isEmpty && shelves.isEmpty }

    init(shelves: [HomeShelf], offer: ContinueFrom.Offer?, nowPlaying: Track?, isPlaying: Bool, otherDevice: DevicePresenceEntry? = nil) {
        var hero: [HomeHeroItem] = []
        if let offer { hero.append(.continueFrom(offer)) }
        if let nowPlaying { hero.append(.nowPlaying(nowPlaying, isPlaying: isPlaying)) }
        if let otherDevice, otherDevice.id != offer.map({ "device:\($0.session.deviceID)" }) {
            hero.append(.otherDevice(otherDevice))
        }

        var remaining = shelves
        let source = remaining.firstIndex { shelf in
            shelf.id != HomeShelf.continueID && !HomeHeroItem.featured(from: shelf, limit: 1).isEmpty
        }
        if let source {
            let featured = HomeHeroItem.featured(from: remaining[source], limit: Self.featuredLimit)
            hero += featured
            let taken = Set(featured.compactMap(\.sourceID))
            if let rest = remaining[source].removing(taken, keepingAtLeast: Self.minimumShelfCount) {
                remaining[source] = rest
            } else {
                remaining.remove(at: source)
            }
        }
        self.hero = hero
        self.shelves = remaining
    }
}

private struct HomeHeroCarousel: View {
    let items: [HomeHeroItem]
    let inset: CGFloat
    let isAutoMixOn: Bool
    var focus: FocusState<BrowseFocus?>.Binding
    let action: (HomeHeroItem, HomeHeroItem.Role) -> Void
    @Binding var currentArtwork: URL?

    @State private var position: String?
    @State private var isOnScreen = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 780

    private var current: HomeHeroItem? {
        items.first { $0.id == position } ?? items.first
    }

    private var currentIndex: Int {
        guard let current else { return 0 }
        return items.firstIndex { $0.id == current.id } ?? 0
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CollectionArtworkBackdrop(
                url: current?.artworkURL,
                identity: current?.identity,
                isActive: isOnScreen,
                fade: 300
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HomeHeroPage(
                            item: item,
                            isFirst: index == 0,
                            inset: inset,
                            isAutoMixOn: isAutoMixOn,
                            focus: focus,
                            action: action
                        )
                        .containerRelativeFrame(.horizontal)
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()

            if items.count > 1 {
                HomeHeroDots(count: items.count, selected: currentIndex)
                    .padding(.bottom, Space.base)
            }
        }
        .frame(height: Self.height)
        .collectionAccent(from: current?.artworkURL)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .global).maxY > 0
        } action: { isOnScreen = $0 }
        .onChange(of: focus.wrappedValue) { _, value in follow(value) }
        .onChange(of: current?.artworkURL, initial: true) { _, url in currentArtwork = url }
        .task(id: items.map(\.id)) { await prefetch() }
    }

    private func follow(_ value: BrowseFocus?) {
        let target: String?
        switch value {
        case .some(.firstCard): target = items.first?.id
        case .some(.hero(let id)), .some(.heroAlt(let id)): target = id
        default: target = nil
        }
        guard let target, target != position else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) { position = target }
    }

    private func prefetch() async {
        for url in items.compactMap(\.artworkURL) {
            guard !Task.isCancelled else { return }
            _ = await CollectionBackdropStore.shared.art(for: url)
        }
    }
}

private struct HomeHeroPage: View {
    let item: HomeHeroItem
    let isFirst: Bool
    let inset: CGFloat
    let isAutoMixOn: Bool
    var focus: FocusState<BrowseFocus?>.Binding
    let action: (HomeHeroItem, HomeHeroItem.Role) -> Void

    static let artworkSide: CGFloat = 500

    var body: some View {
        HStack(alignment: .bottom, spacing: 64) {
            VStack(alignment: .leading, spacing: Space.tight) {
                eyebrow
                Text(item.title)
                    .font(.tvDisplay)
                    .foregroundStyle(Color.scTextPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.tvHeadline)
                        .foregroundStyle(Color.scTextSecondary)
                        .lineLimit(1)
                }
                if let progress = item.progress {
                    progressRow(progress)
                        .padding(.top, Space.tight)
                }
                buttons
                    .padding(.top, Space.roomy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            artwork
        }
        .padding(.horizontal, inset)
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var eyebrow: some View {
        Group {
            if let symbol = item.eyebrowSymbol {
                Label(item.eyebrow, systemImage: symbol)
            } else {
                Text(item.eyebrow)
            }
        }
        .font(.tvCaptionEmph)
        .foregroundStyle(Color.scTextSecondary)
        .lineLimit(1)
    }

    private func progressRow(_ progress: Double) -> some View {
        HStack(spacing: Space.snug) {
            if let elapsed = item.elapsed { Text(elapsed) }
            SCProgressBar(progress: progress, style: .tv)
                .frame(width: 360)
            if let total = item.total { Text(total) }
        }
        .font(.tvCaption.monospacedDigit())
        .foregroundStyle(Color.scTextSecondary)
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
        HStack(spacing: Space.base) {
            let primary = item.primaryAction
            Button { action(item, .primary) } label: {
                TVGlassPillLabel(title: primary.title, systemImage: primary.symbol)
            }
            .buttonStyle(TVGlassPillStyle(isProminent: true))
            .focused(focus, equals: isFirst ? .firstCard : .hero(item.id))
            .accessibilityIdentifier(primary.identifier)
            .accessibilityHint(Text(item.title))

            if let secondary = item.secondaryAction(isAutoMixOn: isAutoMixOn) {
                Button { action(item, .secondary) } label: {
                    TVGlassPillLabel(title: secondary.title, systemImage: secondary.symbol)
                }
                .buttonStyle(TVGlassPillStyle())
                .focused(focus, equals: .heroAlt(item.id))
                .accessibilityIdentifier(secondary.identifier)
            }
        }
        .focusSection()
    }

    private var artwork: some View {
        SCArtworkResolver(url: item.artworkURL, variant: .hero) { image in
            SCArtwork(image: image, identity: item.identity, style: .tv, cornerRadius: Corner.card, subject: item.artSubject)
        }
        .frame(width: Self.artworkSide, height: Self.artworkSide)
        .shadow(color: .black.opacity(0.45), radius: 40, y: 20)
        .accessibilityHidden(true)
    }
}

private struct HomeHeroDots: View {
    let count: Int
    let selected: Int

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index == selected ? 0.95 : 0.3))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct HomeWideCard: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?
    let image: Image?
    let identity: String

    private var side: CGFloat { SCBrowseMetrics.wideCardHeight - 64 }

    var body: some View {
        ZStack(alignment: .leading) {
            Group {
                if let image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(1.4)
                        .blur(radius: 40)
                } else {
                    SoundingArtworkView(identity: identity, subject: .collection)
                }
            }
            .frame(width: SCBrowseMetrics.wideCardWidth, height: SCBrowseMetrics.wideCardHeight)
            .clipped()

            Color.black.opacity(0.34)

            HStack(spacing: Space.base) {
                SCArtwork(image: image, identity: identity, style: .tv, cornerRadius: Corner.control, subject: .collection)
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)

                VStack(alignment: .leading, spacing: Space.hair) {
                    if let eyebrow {
                        Text(eyebrow)
                            .font(.tvCaptionEmph)
                            .foregroundStyle(Color.whiteInk(0.75))
                            .lineLimit(1)
                    }
                    Text(title)
                        .font(.tvSubheadline)
                        .foregroundStyle(Color.white)
                        .lineLimit(3)
                    if let subtitle {
                        Text(subtitle)
                            .font(.tvCaption)
                            .foregroundStyle(Color.whiteInk(0.75))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Space.roomy)
        }
        .frame(width: SCBrowseMetrics.wideCardWidth, height: SCBrowseMetrics.wideCardHeight)
        .clipShape(RoundedRectangle(cornerRadius: SCBrowseMetrics.editorialCorner, style: .continuous))
    }
}

struct HomeShelf: Identifiable {
    enum Items {
        case tracks([Track])
        case collections([HomeCollection], CollectionModule)
        case entries([DiscoveryEntry])
        case artists([User])
    }

    static let continueID = "home.continue"

    let id: String
    let title: String
    var items: Items
    var progressByTrackID: [String: Double] = [:]

    func removing(_ ids: Set<String>, keepingAtLeast minimum: Int) -> HomeShelf? {
        guard !ids.isEmpty else { return self }
        var copy = self
        let remaining: Int
        switch items {
        case .tracks(let tracks):
            let rest = tracks.filter { !ids.contains($0.id) }
            copy.items = .tracks(rest)
            remaining = rest.count
        case .collections(let collections, let module):
            let rest = collections.filter { !ids.contains($0.id) }
            copy.items = .collections(rest, module)
            remaining = rest.count
        case .entries(let entries):
            let rest = entries.filter { !ids.contains($0.id) }
            copy.items = .entries(rest)
            remaining = rest.count
        case .artists:
            return self
        }
        return remaining >= minimum ? copy : nil
    }
}

struct HomeCollection: Identifiable {
    let id: String
    let title: String
    let kicker: String
    let subtitle: String?
    let playlist: Playlist

    let mosaicURLs: [URL]

    var artworkURL: URL? {
        playlist.largeDisplayArtworkURL
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
    static let shared = HomeViewModel()

    @Published private(set) var shelves: [HomeShelf] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    @Published private var continueListening: [Track] = []
    @Published private var continueProgress: [String: Double] = [:]

    @Published private var discoveryShelves: [DiscoveryShelf] = []
    private let discovery = HomeStore.shared.forYou

    #if DEBUG
    #endif

    @Published var likedTracks: [Track] = []

    private let api = SoundCloudAPI.shared
    private var lastLoaded: Date?
    private let recentlyPlayed = RecentlyPlayed.shared
    private var cancellables = Set<AnyCancellable>()

    private let staleAfter: TimeInterval = 5 * 60

    init() {
        discoveryShelves = discovery.shelves
        hydrateContinueListeningFromCache()
        if !discoveryShelves.isEmpty || !continueListening.isEmpty {
            isLoading = false
            rebuildShelves()
        }

        NotificationCenter.default.publisher(for: TopShelfStore.snapshotDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hydrateContinueListeningFromCache()
                }
            }
            .store(in: &cancellables)

        discovery.$shelves
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] shelves in
                Task { @MainActor [weak self] in
                    guard let self, self.discoveryShelves != shelves else { return }
                    self.discoveryShelves = shelves
                    self.rebuildShelves()
                }
            }
            .store(in: &cancellables)

        recentlyPlayed.$items
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hydrateContinueListeningFromCache()
                }
            }
            .store(in: &cancellables)
    }

    private func rebuildShelves() {
        #if DEBUG
        if VisualFixtures.isEnabled {
            shelves = VisualFixtures.homeShelves
            return
        }
        #endif
        var built: [HomeShelf] = []

        var previousWasCards = false
        var remaining = discoveryShelves.filter { !$0.isEmpty && $0.kind != .recent }

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
                id: HomeShelf.continueID,
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
        likedTracks = []
        errorMessage = nil
        isLoading = false
        lastLoaded = nil
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
            TopShelfPublisher.publishFixtures()
            shelves = VisualFixtures.homeShelves
            errorMessage = nil
            isLoading = false
            lastLoaded = Date()
            return
        }
        #endif

        guard AuthenticationService.shared.isAuthenticated else {
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        await discovery.hydrateCachedContent()
        discoveryShelves = discovery.shelves
        rebuildShelves()

        hydrateContinueListeningFromCache()
        async let recents: Void = refreshContinueListening()
        async let topShelf: Void = refreshTopShelf()
        await discovery.load(seed: seed(), quietly: !shelves.isEmpty)
        _ = await (topShelf, recents)

        discoveryShelves = discovery.shelves
        rebuildShelves()
        TopShelfPublisher.publish(mixes: discoveryShelves)

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
        if let latest = continueListening.first(where: { !$0.isLocal }) {
            return .init(track: latest)
        }
        return .init()
    }

    private func hydrateContinueListeningFromCache() {
        let entries = TopShelfStore.load()?.section(kind: TopShelfStore.recentsKind)?.entries ?? []
        continueListening = recentlyPlayed.tracks
        continueProgress = Dictionary(
            entries.map { ($0.id, $0.progress) },
            uniquingKeysWith: { first, _ in first }
        )
        rebuildShelves()
    }

    private func refreshContinueListening() async {
        await recentlyPlayed.refreshFromSoundCloud()
        hydrateContinueListeningFromCache()
    }

    private func refreshTopShelf() async {
        guard await AuthenticationService.shared.waitForCurrentUser() != nil else { return }
        guard !(await TopShelfPublisher.refreshLikes()) else { return }
        do {
            let page = try await api.getLikedTracks(limit: TopShelfStore.maxEntriesPerSection)
            likedTracks = page.collection.map { $0.item }
        } catch {
            HomeLog.logger.error("Top Shelf likes load failed: \(String(describing: error), privacy: .public)")
        }
        TopShelfPublisher.publish(liked: likedTracks)
    }

}
