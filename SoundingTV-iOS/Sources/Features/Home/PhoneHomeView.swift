import SwiftUI

struct PhoneHomeView: View {
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject var source: DiscoveryHomeSource
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Namespace private var heroNamespace

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject private var continueFrom = ContinueFrom.shared

    @State private var isSigningIn = false
    @State private var shelfWidth: CGFloat = 0
    @State private var heroHeight: CGFloat = 0
    @State private var isHeroUnderBar = true
    @State private var scrollPosition = ScrollPosition(edge: .top)

    private static let heroFade: CGFloat = 104

    var body: some View {
        scroller
            .sheet(isPresented: $isSigningIn) {
                NavigationStack {
                    SoundCloudLoginView.standalone {
                        isSigningIn = false
                    }
                }
            }
            .task {
                await credentials.prepareStoreAtLaunch()
                await source.refreshIfStale(seed: seed)
            }
            .onChange(of: credentials.accountStatus) { _, _ in
                Task { await source.refreshIfStale(seed: seed) }
            }
    }

    private var isGuest: Bool {
        credentials.accountStatus == .signedOut && !usesVisualFixtures
    }

    private var needsReconnect: Bool {
        credentials.accountStatus == .needsReconnect
    }

    private var reconnectPrompt: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.snug))
            : AnyLayout(HStackLayout(spacing: Space.snug))
        return layout {
            Label("Sign in again to refresh your picks.", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reconnect") { isSigningIn = true }
                .buttonStyle(.glass)
                .accessibilityHint("Signs in to SoundCloud again")
        }
        .padding(.horizontal, Space.roomy)
    }

    private var usesVisualFixtures: Bool {
        #if DEBUG
        VisualFixtures.isEnabled
        #else
        false
        #endif
    }

    private var seed: DiscoveryHomeSource.Seed {
        guard let snapshot = coordinator.nowPlaying else { return .init() }
        return .init(trackID: snapshot.trackId, trackTitle: snapshot.title)
    }

    private enum PageState {
        case shelves
        case loading
        case guest
        case reconnect
        case failed
        case empty
    }

    private var pageState: PageState {
        if isGuest {
            if source.shelves.isEmpty && source.isLoading { return .loading }
            return source.shelves.isEmpty ? .guest : .shelves
        }
        if source.shelves.isEmpty, needsReconnect { return .reconnect }
        if source.didFailCompletely { return .failed }
        if source.shelves.isEmpty && source.isLoading { return .loading }
        return source.shelves.isEmpty ? .empty : .shelves
    }

    private var signedOutBanner: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Browsing as a Guest")
                    .font(.headline)
                Text("Sign in for picks made for you, your likes and what you were listening to.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Sign In") { isSigningIn = true }
                .buttonStyle(.glass)
                .accessibilityHint("Signs in to SoundCloud on this \(DeviceClass.current.displayName)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.roomy)
    }

    @ViewBuilder
    private var stateView: some View {
        switch pageState {
        case .shelves:
            EmptyView()
        case .loading:
            ProgressView()
                .accessibilityLabel("Loading")
        case .guest:
            SCEmptyState(
                icon: "person.crop.circle.badge.exclamationmark",
                title: "Explore as a Guest",
                message: "Sign in for picks made for you, your likes and what you were listening to.",
                actionTitle: "Sign In",
                action: { isSigningIn = true },
                style: .phone
            )
        case .reconnect:
            SCEmptyState(
                kind: .error,
                title: "Reconnect SoundCloud",
                message: "Sign in again to see picks made for you.",
                actionTitle: "Reconnect",
                action: { isSigningIn = true },
                style: .phone
            )
        case .failed:
            let failure = homeFailure
            SCEmptyState(
                kind: .error,
                title: failure?.title ?? "Couldn't Load Home",
                message: failure?.message(subject: "Home") ?? "Couldn't reach SoundCloud. Check your connection and try again.",
                actionTitle: "Try Again",
                action: { Task { await source.load(seed: seed) } },
                style: .phone
            )
        case .empty:
            SCEmptyState(
                icon: "sparkles",
                title: "Nothing Here Yet",
                message: "Play and like a few tracks and Home fills up with picks made for you.",
                style: .phone
            )
        }
    }

    private var homeFailure: LoadFailure? {
        guard case .waiting(_, let until) = SoundCloudAPI.shared.trafficSafetyState() else { return nil }
        return .rateLimited(until: until)
    }

    private var tileSize: CGFloat {
        if PadLayout.isPad, shelfWidth >= Self.padGridThreshold {
            return padTileSize
        }
        let margins = PhoneLayout.margin * 2 + PhoneLayout.tileGap * 1.5
        let available = max(0, shelfWidth - margins)
        let columns: CGFloat = dynamicTypeSize.isAccessibilitySize ? 1.5 : 2.5
        return available > 0 ? (available / columns).rounded(.down) : 157
    }

    private static let padGridThreshold: CGFloat = 600
    private static let padTileTarget: CGFloat = 170

    private var padTileSize: CGFloat {
        let available = shelfWidth - PhoneLayout.margin * 2
        let target = dynamicTypeSize.isAccessibilitySize ? Self.padTileTarget * 1.6 : Self.padTileTarget
        let columns = max(2, ((available + PhoneLayout.tileGap) / (target + PhoneLayout.tileGap)).rounded(.down))
        return ((available - PhoneLayout.tileGap * (columns - 1)) / columns).rounded(.down)
    }

    private var continueMetrics: CollectionHeroMetrics {
        if PadLayout.isPad, shelfWidth >= Self.padGridThreshold {
            var metrics = CollectionHeroMetrics.padLeading
            metrics.artworkSide = 200
            metrics.backdropFade = Self.heroFade
            return metrics
        }
        var metrics = CollectionHeroMetrics.phoneStacked
        metrics.artworkSide = 200
        metrics.backdropFade = Self.heroFade
        return metrics
    }

    private var usesCompactHero: Bool {
        !(PadLayout.isPad && shelfWidth >= Self.padGridThreshold) && shelfWidth > 0
    }

    private var heroShelfID: String? {
        guard usesCompactHero else { return nil }
        return source.shelves.first { shelf in
            if case .users = shelf.content { return false }
            return shelf.kind != .recent && shelf.count >= 2
        }?.id
    }

    private var heroWidth: CGFloat {
        max(220, shelfWidth - PhoneLayout.margin - PhoneLayout.tileGap - PhoneLayout.heroPeek)
    }

    private var showsContinueHero: Bool {
        !isGuest && continueFrom.offer != nil
    }

    private var isBarOverHero: Bool {
        showsContinueHero && isHeroUnderBar
    }

    private var scroller: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: PhoneLayout.shelfGap) {
                if !isGuest {
                    ContinueFromHero(metrics: continueMetrics, horizontalPadding: PhoneLayout.margin)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heroHeight = $0 }
                        .padding(.bottom, showsContinueHero ? -PhoneLayout.shelfGap : 0)
                }
                TVSignInPrompt()
                if pageState == .shelves {
                    if isGuest {
                        signedOutBanner
                    } else if needsReconnect {
                        reconnectPrompt
                    }
                    ForEach(source.shelves) { shelf in
                        HomeShelfView(
                            shelf: shelf,
                            heroNamespace: heroNamespace,
                            tileSize: tileSize,
                            layout: shelf.id == heroShelfID ? .hero(width: heroWidth) : .row
                        )
                    }
                } else {
                    stateView
                        .frame(maxWidth: .infinity)
                        .containerRelativeFrame(.vertical, alignment: .center) { length, _ in
                            showsContinueHero ? max(0, length - heroHeight) * 0.8 : length * 0.8
                        }
                }
            }
            .padding(.top, showsContinueHero ? 0 : Space.tight)
            .padding(.bottom, Space.base)
            .animation(reduceMotion ? nil : .smooth, value: source.shelves.map(\.id))
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.45), value: continueFrom.offer?.id)
        }
        .scrollPosition($scrollPosition)
        .collectionScrollBackdrop(
            url: continueFrom.offer?.session.artworkURL,
            identity: continueFrom.offer?.session.trackID,
            fade: Self.heroFade,
            isPresent: showsContinueHero
        )
        .onScrollGeometryChange(for: Bool.self) { [heroHeight] geometry in
            geometry.contentOffset.y + geometry.contentInsets.top < heroHeight - Self.heroFade
        } action: { _, underBar in
            isHeroUnderBar = underBar
        }
        .onChange(of: continueFrom.offer?.id) { _, _ in
            guard isHeroUnderBar else { return }
            withAnimation(reduceMotion ? nil : .smooth) { scrollPosition.scrollTo(edge: .top) }
        }
        .scrollEdgeEffectHidden(isBarOverHero, for: .top)
        .toolbarColorScheme(isBarOverHero ? .dark : nil, for: .navigationBar)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shelfWidth = $0 }
        .refreshable { await source.load(seed: seed) }
    }
}

private struct TVSignInPrompt: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var pairing: DevicePairingFlow
    @EnvironmentObject private var nearby: LinkOfferBrowser
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let prompt = PeerSignInPrompt.resolve(client: client, offers: nearby.offers) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.snug))
                : AnyLayout(HStackLayout(spacing: Space.snug))
            layout {
                Label("\(prompt.name) is waiting to sign in", systemImage: DeviceClass.tv.symbolName)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Sign In") { prompt.start(client: client, pairing: pairing) }
                    .buttonStyle(.glass)
                    .disabled(client.isRequestingPeerSignIn)
                    .accessibilityHint("Signs in \(prompt.name) with your SoundCloud account")
            }
            .padding(.horizontal, Space.roomy)
            .transition(.opacity)
        }
    }
}

struct HomeShelfView: View {
    enum Layout {
        case row
        case hero(width: CGFloat)
        case grid(columns: Int)
    }

    let shelf: DiscoveryShelf
    let heroNamespace: Namespace.ID
    let tileSize: CGFloat
    var layout: Layout = .row

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.artistRouter) private var artistRouter

    private enum Item: Identifiable {
        case track(Track)
        case playlist(Playlist)
        case station(SystemPlaylist)
        case user(User)

        var id: String {
            switch self {
            case .track(let track): return "track:\(track.id)"
            case .playlist(let playlist): return playlist.id
            case .station(let station): return station.id
            case .user(let user): return "user:\(user.id)"
            }
        }
    }

    private var items: [Item] {
        switch shelf.content {
        case .tracks(let tracks): return tracks.map(Item.track)
        case .playlists(let playlists): return playlists.map(Item.playlist)
        case .stations(let stations): return stations.map(Item.station)
        case .users(let users): return users.map(Item.user)
        case .mixed(let entries):
            return entries.map { entry in
                switch entry {
                case .playlist(let playlist): return .playlist(playlist)
                case .station(let station): return .station(station)
                case .user(let user): return .user(user)
                }
            }
        }
    }

    private var trackContext: [Track] {
        if case .tracks(let tracks) = shelf.content { return tracks }
        return []
    }

    var body: some View {
        switch layout {
        case .grid(let columns):
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(tileSize), spacing: PhoneLayout.tileGap, alignment: .top), count: max(1, columns)),
                alignment: .leading,
                spacing: Space.roomy
            ) {
                ForEach(items) { tile($0) }
            }
            .padding(.horizontal, PhoneLayout.margin)
            .prefetchArtwork(artworkURLs)
        case .row, .hero:
            VStack(alignment: .leading, spacing: PhoneLayout.headerGap) {
                header
                    .padding(.horizontal, PhoneLayout.margin)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: PhoneLayout.tileGap) {
                        ForEach(items) { item in
                            if case .hero(let width) = layout {
                                heroCard(item, width: width)
                            } else {
                                tile(item)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, PhoneLayout.margin, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
                .prefetchArtwork(artworkURLs)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if shelf.kind == .recent {
                SidebarLink(tab: .history) {
                    ListeningHistoryView()
                } label: {
                    SCSectionHeader(title: shelf.title, showChevron: true, titleLineLimit: nil, style: .phoneSectionHeader)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows your listening history")
            } else if shelf.count > 2 {
                NavigationLink {
                    HomeShelfDetailView(shelf: shelf)
                } label: {
                    SCSectionHeader(title: shelf.title, showChevron: true, titleLineLimit: nil, style: .phoneSectionHeader)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows all")
            } else {
                SCSectionHeader(title: shelf.title, titleLineLimit: nil, style: .phoneSectionHeader)
            }
            if let subtitle = shelf.subtitle {
                Text(subtitle)
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
        }
    }

    @ViewBuilder
    private func tile(_ item: Item) -> some View {
        switch item {
        case .track(let track): trackTile(track, context: trackContext)
        case .playlist(let playlist): playlistTile(playlist)
        case .station(let station): StationTile(station: station, tileSize: tileSize)
        case .user(let user): artistTile(user)
        }
    }

    @ViewBuilder
    private func heroCard(_ item: Item, width: CGFloat) -> some View {
        switch item {
        case .track(let track):
            Button {
                Task { await coordinator.play(track, in: trackContext) }
            } label: {
                HomeHeroCardLabel(
                    eyebrow: "Track",
                    title: track.title,
                    subtitle: track.user.displayName,
                    artworkURL: track.artworkURL,
                    identity: track.id,
                    isAvailable: track.streamURL != nil,
                    width: width
                )
            }
            .buttonStyle(TilePressStyle())
            .libraryCardPreviewShape()
            .contextMenu { trackMenu(track, context: trackContext) }
            .disabled(track.streamURL == nil)
            .accessibilityLabel("\(track.title) by \(track.user.displayName)\(track.streamURL == nil ? ", unavailable" : "")")
            .accessibilityHint(track.streamURL == nil ? "This track isn't available to play" : "Plays on this device")
        case .playlist(let playlist):
            PlaylistLink(playlist, heroNamespace: heroNamespace) {
                HomeHeroCardLabel(
                    eyebrow: "Playlist",
                    title: playlist.title,
                    subtitle: playlist.user.displayName,
                    artworkURL: playlist.largeDisplayArtworkURL ?? playlist.displayArtworkURL,
                    identity: playlist.id,
                    subject: .collection,
                    width: width
                )
                .matchedTransitionSource(id: playlist.id, in: heroNamespace)
            }
            .buttonStyle(TilePressStyle())
            .libraryCardPreviewShape()
            .contextMenu { PlaylistContextMenu(playlist: playlist) }
            .accessibilityLabel("\(playlist.title), playlist by \(playlist.user.displayName)")
        case .station(let station):
            StationTile(station: station, tileSize: width, hero: true)
        case .user(let user):
            NavigationLink {
                ArtistDetailView(user: user)
            } label: {
                HomeHeroCardLabel(
                    eyebrow: user.kindLabel,
                    title: user.displayName,
                    subtitle: user.followersLabel,
                    artworkURL: user.largeAvatarURL ?? user.avatarURL,
                    identity: user.id,
                    width: width
                )
            }
            .buttonStyle(TilePressStyle())
            .libraryCardPreviewShape()
            .contextMenu { UserContextMenu(user: user) }
            .accessibilityLabel("\(user.displayName), artist")
        }
    }

    private var artworkURLs: [URL] {
        switch shelf.content {
        case .tracks(let tracks):
            return tracks.compactMap(\.artworkURL)
        case .playlists(let playlists):
            return playlists.compactMap(\.displayArtworkURL)
        case .stations(let stations):
            return stations.compactMap { DiscoveryEntry.station($0).artworkURL }
        case .users(let users):
            return users.compactMap { $0.largeAvatarURL ?? $0.avatarURL }
        case .mixed(let entries):
            return entries.compactMap(\.artworkURL)
        }
    }

    private func trackTile(_ track: Track, context: [Track]) -> some View {
        Button {
            Task { await coordinator.play(track, in: context) }
        } label: {
            SCArtworkResolver(url: track.artworkURL) { image in
                SCMediaCard(
                    title: track.title,
                    subtitle: track.user.displayName,
                    artworkImage: image,
                    artIdentity: track.id,
                    isAvailable: track.streamURL != nil,
                    style: .phone
                )
            }
            .kyleCrowned(user: track.user, context: track.title)
            .frame(width: tileSize)
            .tileHoverEffect()
        }
        .buttonStyle(TilePressStyle())
        .libraryTilePreviewShape()
        .contextMenu { trackMenu(track, context: context) }
        .disabled(track.streamURL == nil)
        .accessibilityLabel("\(track.title) by \(track.user.displayName)\(track.streamURL == nil ? ", unavailable" : "")")
        .accessibilityHint(track.streamURL == nil ? "This track isn't available to play" : "Plays on this device")
    }

    @ViewBuilder
    private func trackMenu(_ track: Track, context: [Track]) -> some View {
        BehindTheTrackMenuButton(track: track)
        Button {
            Task { await coordinator.play(track, in: context) }
        } label: {
            Label("Play", systemImage: "play")
        }
        Button {
            coordinator.addToQueue(track)
        } label: {
            Label("Add to Up Next", systemImage: "text.append")
        }
        AddToPlaylistMenuButton(track: track)
        WakeToThisMenuButton(track: track)
        if let artistRouter {
            Button {
                artistRouter.open(track.user)
            } label: {
                Label("Go to Artist", systemImage: "person.crop.circle")
            }
        }
        ShareLink(item: track.permalinkURL, preview: SharePreview(track.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private func playlistTile(_ playlist: Playlist) -> some View {
        PlaylistLink(playlist, heroNamespace: heroNamespace) {
            SCArtworkResolver(url: playlist.displayArtworkURL) { image in
                VStack(alignment: .leading, spacing: SCContentStyle.phone.spaceTight) {
                    SCArtwork(image: image, identity: playlist.id, style: .phone, subject: .collection)
                        .aspectRatio(1, contentMode: .fit)
                        .kyleCrowned(user: playlist.user, context: playlist.title)
                        .matchedTransitionSource(id: playlist.id, in: heroNamespace)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.title)
                            .font(SCContentStyle.phone.fontBodyEmphasis)
                            .foregroundStyle(SCContentStyle.phone.textPrimary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        Text(playlist.user.displayName)
                            .font(SCContentStyle.phone.fontCaption)
                            .foregroundStyle(SCContentStyle.phone.textSecondary)
                            .scAdaptiveLineLimit(1, accessibility: 2)
                    }
                }
            }
            .frame(width: tileSize)
            .tileHoverEffect()
        }
        .buttonStyle(TilePressStyle())
        .libraryTilePreviewShape()
        .contextMenu { PlaylistContextMenu(playlist: playlist) }
        .accessibilityLabel("\(playlist.title), playlist by \(playlist.user.displayName)")
    }

    private func artistTile(_ user: User) -> some View {
        NavigationLink {
            ArtistDetailView(user: user)
        } label: {
            SCArtworkResolver(url: user.largeAvatarURL ?? user.avatarURL) { image in
                SCArtistCard(
                    name: user.displayName,
                    subtitle: user.followersLabel,
                    avatarImage: image,
                    identity: user.id,
                    diameter: tileSize,
                    style: .phone
                )
            }
            .kyleCrowned(user: user, context: user.displayName)
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.lift)
        }
        .buttonStyle(TilePressStyle())
        .libraryTilePreviewShape()
        .contextMenu { UserContextMenu(user: user) }
        .accessibilityLabel("\(user.displayName), artist")
    }
}

private struct StationTile: View {
    let station: SystemPlaylist
    let tileSize: CGFloat
    var hero = false

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @State private var isHydrating = false

    private var entry: DiscoveryEntry { .station(station) }
    private var opensList: Bool { station.stationKind == .other }

    var body: some View {
        Group {
            if opensList {
                NavigationLink {
                    StationDetailView(station: station)
                } label: {
                    card
                }
                .accessibilityLabel("\(entry.cardTitle), playlist")
                .accessibilityHint("Shows the tracks")
            } else {
                Button(action: play) { card }
                    .disabled(isHydrating)
                    .accessibilityLabel("\(entry.cardTitle), station")
                    .accessibilityValue(isHydrating ? "Loading" : "")
                    .accessibilityHint("Plays the station")
            }
        }
        .buttonStyle(TilePressStyle())
        .libraryTilePreviewShape()
        .contextMenu {
            Button(action: play) {
                Label("Play", systemImage: "play")
            }
            if !opensList {
                NavigationLink {
                    StationDetailView(station: station)
                } label: {
                    Label("Show Tracks", systemImage: "music.note.list")
                }
            }
            if let url = station.permalinkURL {
                ShareLink(item: url, preview: SharePreview(entry.cardTitle)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    @ViewBuilder
    private var cardLabel: some View {
        if hero {
            HomeHeroCardLabel(
                eyebrow: opensList ? "Playlist" : "Station",
                title: entry.cardTitle,
                subtitle: entry.cardSubtitle,
                artworkURL: entry.artworkURL,
                identity: entry.artIdentity,
                subject: .station,
                width: tileSize
            )
        } else {
            SCArtworkResolver(url: entry.artworkURL) { image in
                SCMediaCard(
                    title: entry.cardTitle,
                    subtitle: entry.cardSubtitle,
                    artworkImage: image,
                    artIdentity: entry.artIdentity,
                    artSubject: .station,
                    style: .phone
                )
            }
            .frame(width: tileSize)
            .tileHoverEffect()
        }
    }

    private var card: some View {
        cardLabel
            .overlay(alignment: .center) {
                if isHydrating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading")
                }
            }
            .contentShape(Rectangle())
    }

    private func play() {
        guard !isHydrating else { return }
        isHydrating = true
        Task {
            defer { isHydrating = false }
            guard let tracks = try? await StationQueue.load(station),
                  let first = tracks.first(where: { $0.streamURL != nil }) else { return }
            StationLibrary.shared.record(station)
            await coordinator.play(first, in: tracks, collectionId: station.id)
        }
    }
}

private struct StationDetailView: View {
    let station: SystemPlaylist

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @StateObject private var confirmation = QueueConfirmationController()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var failed = false
    @State private var isHeroScrolledAway = false

    private var entry: DiscoveryEntry { .station(station) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(isHeroScrolledAway ? entry.cardTitle : "")
            .navigationBarTitleDisplayMode(.inline)
            .queueConfirmationOverlay(confirmation)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, tracks.isEmpty {
            VStack(spacing: 0) {
                hero
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if failed, tracks.isEmpty {
            VStack(spacing: 0) {
                hero
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "wifi.slash")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxHeight: .infinity)
            }
        } else if tracks.isEmpty {
            VStack(spacing: 0) {
                hero
                ContentUnavailableView(
                    "No Tracks",
                    systemImage: "music.note.list",
                    description: Text("There's nothing in here right now.")
                )
                .frame(maxHeight: .infinity)
            }
        } else {
            List {
                hero
                    .onGeometryChange(for: Bool.self) { proxy in
                        proxy.frame(in: .scrollView).maxY < 0
                    } action: { isHeroScrolledAway = $0 }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                ForEach(tracks) { track in
                    TrackListRow(
                        track: track,
                        context: { tracks },
                        collectionId: station.id,
                        confirmation: confirmation
                    )
                }
            }
            .listStyle(.plain)
            .refreshable { await load() }
        }
    }

    private var hero: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let rowLayout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
            : AnyLayout(HStackLayout(spacing: Spacing.md))
        return VStack(alignment: .leading, spacing: Spacing.md) {
            rowLayout {
                ArtworkThumbnail(
                    url: entry.artworkURL,
                    systemImage: "music.note.list",
                    size: 84,
                    cornerRadius: Corner.thumb,
                    identity: entry.artIdentity
                )
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.cardTitle)
                        .font(.scTitle)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle = entry.cardSubtitle {
                        Text(subtitle)
                            .font(.scSubhead)
                            .foregroundStyle(.secondary)
                            .lineLimit(stacked ? nil : 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            rowLayout {
                Button(action: play) {
                    Label("Play", systemImage: "play.fill")
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                Button(action: shuffle) {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .disabled(tracks.isEmpty)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.md)
    }

    private func load() async {
        isLoading = true
        failed = false
        defer { isLoading = false }
        do {
            tracks = try await StationQueue.load(station)
        } catch {
            failed = true
        }
    }

    private func play() {
        guard let first = tracks.first(where: { $0.streamURL != nil }) else { return }
        StationLibrary.shared.record(station)
        Task { await coordinator.play(first, in: tracks, collectionId: station.id) }
    }

    private func shuffle() {
        guard !tracks.isEmpty else { return }
        StationLibrary.shared.record(station)
        Task { await coordinator.play(shuffled: tracks, collectionId: station.id) }
    }
}

private extension View {
    func tileHoverEffect() -> some View {
        contentShape(.hoverEffect, RoundedRectangle(cornerRadius: SCContentStyle.phone.artworkCorner, style: .continuous))
            .hoverEffect(.lift)
    }
}

private struct TilePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}
