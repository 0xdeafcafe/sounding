import SwiftUI

enum ArtistPageShelf: String, Identifiable, Hashable {
    case tracks, albums, singles, playlists, reposts, likes, similar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tracks: "Tracks"
        case .albums: "Albums"
        case .singles: "Singles & EPs"
        case .playlists: "Playlists"
        case .reposts: "Reposts"
        case .likes: "Likes"
        case .similar: "Similar Artists"
        }
    }

    var section: ArtistDetailSection? {
        switch self {
        case .tracks: .tracks
        case .albums, .singles, .playlists: .playlists
        case .reposts: .reposts
        case .likes: .likes
        case .similar: nil
        }
    }
}

struct ArtistDetailView: View {
    let user: User
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var viewModel: ArtistDetailViewModel
    @StateObject private var similar: ArtistSimilarModel
    @StateObject private var confirmation = QueueConfirmationController()
    @StateObject private var analysisStore = TrackAnalysisStore()
    @State private var followingModel: ArtistConnectionsModel
    @State private var followersModel: ArtistConnectionsModel
    @Namespace private var heroNamespace

    @State private var openShelf: ArtistPageShelf?
    @State private var connectionSheet: ArtistConnectionKind?
    @State private var isFollowing: Bool?
    @State private var isUpdatingFollow = false
    @State private var isConfirmingUnfollow = false
    @State private var profile: User
    @State private var bannerURL: URL?
    @State private var avatarURL: URL?
    @State private var isVerified: Bool?
    @State private var isHeroScrolledAway = false
    @State private var pageHeight: CGFloat = 0
    @State private var didRequestLowerShelves = false
    @State private var setlistTrack: Track?
    @State private var trimTrack: Track?

    init(user: User) {
        self.user = user
        _profile = State(initialValue: user)
        _bannerURL = State(initialValue: user.profileCoverURL)
        _avatarURL = State(initialValue: user.largeAvatarURL ?? user.avatarURL)
        _isVerified = State(initialValue: user.verified)
        _viewModel = StateObject(wrappedValue: ArtistDetailViewModel(user: user))
        _similar = StateObject(wrappedValue: ArtistSimilarModel(user: user))
        _followingModel = State(initialValue: ArtistConnectionsModel(userID: user.id, kind: .following))
        _followersModel = State(initialValue: ArtistConnectionsModel(userID: user.id, kind: .followers))
    }

    var body: some View {
        List {
            hero
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            overview
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .collectionPageScheme()
        .collectionPersonBackdrop(heroContent, blursBanner: heroMetrics.blursBanner)
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { pageHeight = $0 }
        .collectionPersonPage(heroContent)
        .collectionAccent(from: heroContent.accentURL)
        .refreshable {
            await viewModel.reload(section: .tracks)
            await viewModel.reload(section: .playlists)
            await loadFollowState()
        }
        .navigationTitle(isHeroScrolledAway ? user.displayName : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(isHeroScrolledAway ? .automatic : .hidden, for: .navigationBar)
        .toolbar {
            if showsFollowButton {
                ToolbarItem(placement: .topBarTrailing) {
                    followButton
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                actionMenu
            }
        }
        .task {
            await viewModel.loadOverviewIfNeeded()
            await loadFollowState()
        }
        .task(id: user.id) { await loadProfile() }
        .task(id: overviewTrackIDs) {
            await analysisStore.load(for: overviewTracks)
        }
        .queueConfirmationOverlay(confirmation)
        .trackActionSheets(setlist: $setlistTrack, trim: $trimTrack)
        .navigationDestination(item: $connectionSheet) { kind in
            ArtistConnectionsView(
                artist: user,
                kind: kind,
                model: kind == .following ? followingModel : followersModel
            )
        }
        .navigationDestination(item: $openShelf) { shelf in
            ArtistShelfPage(
                user: user,
                shelf: shelf,
                viewModel: viewModel,
                similar: similar,
                analysisStore: analysisStore,
                confirmation: confirmation,
                heroNamespace: heroNamespace
            )
        }
        .confirmationDialog(
            "Unfollow @\(user.username)?",
            isPresented: $isConfirmingUnfollow,
            titleVisibility: .visible
        ) {
            Button("Unfollow", role: .destructive) { setFollowState(false) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var isWide: Bool {
        PadLayout.isPad && horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    private var heroMetrics: PersonHeroMetrics { isWide ? .pad : .phone }
    private var tileWidth: CGFloat { isWide ? 200 : 150 }
    private var personDiameter: CGFloat { isWide ? 150 : 120 }

    private var heroBadge: (text: String, symbol: String?) {
        if isVerified == true { return ("Verified", "checkmark.seal.fill") }
        if isFollowing == true { return ("Following", "checkmark") }
        return ("\(user.formattedFollowers) \(user.followersCount == 1 ? "Follower" : "Followers")", nil)
    }

    private var heroContent: PersonHeroContent {
        let badge = heroBadge
        return PersonHeroContent(user: user, bannerURL: bannerURL, avatarURL: avatarURL, badge: badge.text, badgeSymbol: badge.symbol)
    }

    private var hero: some View {
        PersonHero(content: heroContent, metrics: heroMetrics, height: heroMetrics.height(for: pageHeight)) {
            PersonHeroPlayButton(name: user.displayName, diameter: isWide ? 60 : 52, isEnabled: !viewModel.tracks.isEmpty) {
                Task { await PlayActions.play(tracks: viewModel.tracks) }
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .scrollView).maxY < 110
        } action: { isHeroScrolledAway = $0 }
    }

    private var showsFollowButton: Bool {
        credentials.currentUser?.id != user.id && !credentials.isSignedOut
    }

    private var followButton: some View {
        Button {
            if isFollowing == true {
                isConfirmingUnfollow = true
            } else {
                setFollowState(true)
            }
        } label: {
            Label(
                isFollowing == true ? "Following" : "Follow",
                systemImage: isFollowing == true ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus"
            )
        }
        .disabled(isUpdatingFollow)
        .accessibilityLabel(isFollowing == true ? "Following \(user.displayName)" : "Follow \(user.displayName)")
    }

    private var actionMenu: some View {
        Menu {
            Button {
                Task { await PlayActions.shufflePlay(tracks: viewModel.tracks) }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(viewModel.tracks.isEmpty)
            StartStationMenuButton(artist: user)
            Section {
                Button {
                    connectionSheet = .followers
                } label: {
                    Label("Followers", systemImage: ArtistConnectionKind.followers.systemImage)
                }
                Button {
                    connectionSheet = .following
                } label: {
                    Label("Following", systemImage: ArtistConnectionKind.following.systemImage)
                }
            }
            if showsFollowButton {
                ScoutToggleButton(user: user, isFollowed: isFollowing)
            }
            OpenInNewWindowButton(route: .artist(user))
            ShareLink(item: user.permalinkURL, subject: Text(user.displayName), preview: SharePreview(user.displayName)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityLabel("More for \(user.displayName)")
    }

    private func loadProfile() async {
        if user.profileCoverURL != nil, avatarURL != nil, isVerified != nil { return }
        guard let refreshed = try? await SoundCloudAPI.shared.getUser(id: user.id),
              !Task.isCancelled else { return }
        profile = refreshed
        bannerURL = refreshed.profileCoverURL ?? bannerURL
        avatarURL = refreshed.largeAvatarURL ?? refreshed.avatarURL ?? avatarURL
        isVerified = refreshed.verified ?? isVerified
    }

    // MARK: - Overview

    private var topTracks: [Track] { viewModel.topTracks }

    private var overviewTracks: [Track] { Array(topTracks.prefix(8)) }

    private var overviewTrackIDs: [String] { overviewTracks.map(\.id) }

    @ViewBuilder
    private var overview: some View {
        if viewModel.isLoading(.tracks), viewModel.tracks.isEmpty, viewModel.playlists.isEmpty {
            LoadingPlaceholder(.trackList(.phoneRoomy), count: 6, insets: false)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else if let error = viewModel.errorMessage(.tracks), viewModel.tracks.isEmpty, viewModel.playlists.isEmpty {
            ContentUnavailableView {
                Label("Couldn\u{2019}t Load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await viewModel.loadOverviewIfNeeded() } }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else {
            if viewModel.tracks.isEmpty, viewModel.playlists.isEmpty {
                ContentUnavailableView(
                    "No Tracks",
                    systemImage: "music.note",
                    description: Text("\(user.displayName) hasn\u{2019}t uploaded any tracks.")
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                topSection
                playlistShelf(.albums, playlists: viewModel.albums)
                playlistShelf(.singles, playlists: viewModel.singlesAndEPs)
                playlistShelf(.playlists, playlists: viewModel.otherPlaylists)
            }

            repostsShelf
            likesShelf

            PersonAboutSection(user: profile, style: .phone, inset: Spacing.lg) { connectionSheet = $0 }
                .onAppear { loadLowerShelves() }
                .padding(.top, Spacing.md)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            similarShelf
        }
    }

    private func loadLowerShelves() {
        guard !didRequestLowerShelves else { return }
        didRequestLowerShelves = true
        Task {
            await viewModel.loadSectionIfNeeded(.reposts)
            guard !viewModel.repostsPager.isPaused else { return }
            await viewModel.loadSectionIfNeeded(.likes)
            guard !viewModel.likesPager.isPaused else { return }
            await similar.loadIfNeeded()
        }
    }

    @ViewBuilder
    private var topSection: some View {
        if isWide {
            HStack(alignment: .top, spacing: Spacing.xl) {
                if let latest = viewModel.latestRelease {
                    latestReleaseView(latest, artworkSide: 220)
                        .frame(width: 220, alignment: .leading)
                }
                if !topTracks.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        topTracksHeader
                        compactTrackGrid(overviewTracks, columns: 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .listRowInsets(EdgeInsets(top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else {
            if let latest = viewModel.latestRelease {
                latestReleaseView(latest, artworkSide: 120)
                    .listRowInsets(EdgeInsets(top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if !topTracks.isEmpty {
                topTracksHeader
                    .listRowInsets(EdgeInsets(top: Spacing.md, leading: Spacing.lg, bottom: Spacing.xs, trailing: Spacing.lg))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                let top = Array(topTracks.prefix(5))
                ForEach(top) { track in
                    TrackListRow(
                        track: track,
                        analysis: analysisStore.summaries[track.id],
                        context: { top },
                        confirmation: confirmation
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    private var topTracksHeader: some View {
        SCSectionHeader(title: "Top Tracks", showChevron: true, action: { openShelf = .tracks }, style: .phoneSectionHeader)
    }

    @ViewBuilder
    private func latestReleaseView(_ release: ArtistLatestRelease, artworkSide: CGFloat) -> some View {
        let layout = isWide
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.md))
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SCSectionHeader(title: "Latest Release", style: .phoneSectionHeader)
            switch release {
            case .collection(let playlist):
                PlaylistLink(playlist, heroNamespace: heroNamespace) {
                    layout {
                        releaseArtwork(url: release.artworkURL, identity: release.id, side: artworkSide)
                        releaseText(release)
                    }
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: playlist.id, in: heroNamespace)
                .libraryTilePreviewShape()
                .contextMenu { PlaylistContextMenu(playlist: playlist) }
            case .single(let track):
                Button {
                    play(track, in: [track])
                } label: {
                    layout {
                        releaseArtwork(url: release.artworkURL, identity: release.id, side: artworkSide)
                        releaseText(release)
                    }
                }
                .buttonStyle(.plain)
                .libraryTilePreviewShape()
                .contextMenu { trackMenu(track, context: [track]) }
            }
        }
    }

    private func releaseArtwork(url: URL?, identity: String, side: CGFloat) -> some View {
        SCArtworkResolver(url: url) { image in
            if let image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                SoundingArtworkView(identity: identity, subject: .collection)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: SCContentStyle.phone.cornerCard, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
    }

    private func releaseText(_ release: ArtistLatestRelease) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(release.date.formatted(.dateTime.day().month(.abbreviated).year()))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(release.title)
                .font(.headline)
                .lineLimit(2)
            Text(release.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactTrackGrid(_ tracks: [Track], columns: Int) -> some View {
        let grid = Array(repeating: GridItem(.flexible(), spacing: Spacing.lg, alignment: .leading), count: columns)
        return LazyVGrid(columns: grid, alignment: .leading, spacing: 0) {
            ForEach(tracks) { track in
                compactTrackRow(track, context: tracks)
            }
        }
    }

    private func compactSubtitle(_ track: Track) -> String {
        var parts = [String(Calendar.current.component(.year, from: track.createdAt))]
        if let plays = track.playbackCount, plays > 0 {
            parts.append("\(plays.formatted(.number.notation(.compactName))) plays")
        }
        return parts.joined(separator: " · ")
    }

    private func activity(for track: Track) -> SCTrackActivity {
        guard let snapshot = coordinator.nowPlaying, snapshot.trackId == track.id else { return .none }
        if snapshot.isLoading { return .loading }
        return snapshot.isPlaying ? .playing : .paused
    }

    private func compactTrackRow(_ track: Track, context: [Track]) -> some View {
        var item = SCTrackListItem(track: track, analysis: analysisStore.summaries[track.id])
        item.artist = compactSubtitle(track)
        item.analysis = nil
        return HStack(spacing: Spacing.xs) {
            Button {
                play(track, in: context)
            } label: {
                SCTrackListRow(item: item, leading: .artwork, activity: activity(for: track), metrics: .phoneRoomy, crownUser: track.user)
            }
            .buttonStyle(.plain)
            .disabled(track.streamURL == nil)
            SCTrackListMoreMenu(title: track.title) {
                trackMenu(track, context: context)
            }
        }
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, SCTrackListMetrics.phoneRoomy.artworkSize + SCTrackListMetrics.phoneRoomy.spacing)
        }
        .trackDragSource(track)
        .libraryRowPreviewShape()
        .contextMenu { trackMenu(track, context: context) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilityLabel)
    }

    @ViewBuilder
    private func trackMenu(_ track: Track, context: [Track]) -> some View {
        TrackActionMenuItems(
            track: track,
            addToQueue: {
                coordinator.addToQueue(track)
                confirmation.show("Added \u{201C}\(track.title)\u{201D} to Up Next")
            },
            showSetlist: { setlistTrack = track },
            editTrim: { trimTrack = track }
        )
        ShareLink(item: track.permalinkURL, preview: SharePreview(track.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private func play(_ track: Track, in context: [Track]) {
        guard track.streamURL != nil else { return }
        Task {
            if let message = await coordinator.play(track, in: context.filter { $0.streamURL != nil }) {
                confirmation.show(message, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: - Shelves

    @ViewBuilder
    private func playlistShelf(_ shelf: ArtistPageShelf, playlists: [Playlist]) -> some View {
        if !playlists.isEmpty {
            CollectionShelf(
                title: shelf.title,
                items: playlists,
                style: .phoneSectionHeader,
                tileWidth: tileWidth,
                spacing: Spacing.md,
                inset: Spacing.lg,
                headerAction: { openShelf = shelf }
            ) { playlist in
                playlistTile(playlist)
            }
            .artistShelfRow()
        }
    }

    private func playlistTile(_ playlist: Playlist) -> some View {
        PlaylistLink(playlist, heroNamespace: heroNamespace) {
            ArtworkShelfCard(playlist: playlist, style: .phone)
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: playlist.id, in: heroNamespace)
        .libraryTilePreviewShape()
        .contextMenu { PlaylistContextMenu(playlist: playlist) }
    }

    private func trackTile(_ track: Track, context: [Track]) -> some View {
        Button {
            play(track, in: context)
        } label: {
            ArtworkShelfCard(track: track, style: .phone)
        }
        .buttonStyle(.plain)
        .disabled(track.streamURL == nil)
        .trackDragSource(track)
        .contextMenu { trackMenu(track, context: context) }
    }

    @ViewBuilder
    private var repostsShelf: some View {
        let entries = Array(viewModel.repostsPager.items.prefix(20))
        if !entries.isEmpty {
            let tracks = entries.compactMap(\.item.track)
            CollectionShelf(
                title: ArtistPageShelf.reposts.title,
                items: entries,
                style: .phoneSectionHeader,
                tileWidth: tileWidth,
                spacing: Spacing.md,
                inset: Spacing.lg,
                headerAction: { openShelf = .reposts }
            ) { entry in
                if let playlist = entry.item.playlist {
                    playlistTile(playlist)
                } else if let track = entry.item.track {
                    trackTile(track, context: tracks)
                }
            }
            .artistShelfRow()
        }
    }

    @ViewBuilder
    private var likesShelf: some View {
        let tracks = Array(viewModel.likedTracks.prefix(20))
        if !tracks.isEmpty {
            CollectionShelf(
                title: ArtistPageShelf.likes.title,
                items: tracks,
                style: .phoneSectionHeader,
                tileWidth: tileWidth,
                spacing: Spacing.md,
                inset: Spacing.lg,
                headerAction: { openShelf = .likes }
            ) { track in
                trackTile(track, context: tracks)
            }
            .artistShelfRow()
        }
    }

    @ViewBuilder
    private var similarShelf: some View {
        if !similar.artists.isEmpty {
            CollectionShelf(
                title: ArtistPageShelf.similar.title,
                items: similar.artists,
                style: .phoneSectionHeader,
                tileWidth: personDiameter,
                spacing: Spacing.md,
                inset: Spacing.lg,
                headerAction: { openShelf = .similar }
            ) { artist in
                NavigationLink(value: artist) {
                    PersonShelfTile(user: artist, diameter: personDiameter, style: .phone)
                }
                .buttonStyle(.plain)
                .contextMenu { UserContextMenu(user: artist) }
                .accessibilityLabel("\(artist.displayName), artist")
            }
            .artistShelfRow()
        }
    }

    private func loadFollowState() async {
        guard !credentials.isSignedOut, credentials.currentUser?.id != user.id else {
            isFollowing = nil
            return
        }
        isFollowing = try? await SoundCloudAPI.shared.isFollowing(userId: user.id)
    }

    private func setFollowState(_ following: Bool) {
        guard isFollowing != following, !isUpdatingFollow else { return }
        let previous = isFollowing
        isUpdatingFollow = true
        Task {
            defer { isUpdatingFollow = false }
            do {
                try await SoundCloudAPI.shared.setFollowing(following, userId: user.id)
                isFollowing = following
            } catch {
                isFollowing = previous
                confirmation.show(
                    following ? "Couldn\u{2019}t follow \(user.displayName)" : "Couldn\u{2019}t unfollow \(user.displayName)",
                    icon: "exclamationmark.triangle.fill"
                )
            }
        }
    }
}

private extension View {
    func artistShelfRow() -> some View {
        padding(.vertical, Spacing.md)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private struct ArtistShelfPage: View {
    let user: User
    let shelf: ArtistPageShelf
    @ObservedObject var viewModel: ArtistDetailViewModel
    @ObservedObject var similar: ArtistSimilarModel
    @ObservedObject var analysisStore: TrackAnalysisStore
    @ObservedObject var confirmation: QueueConfirmationController
    let heroNamespace: Namespace.ID

    @State private var sortKey: TrackSortKey = .dateAdded
    @State private var ascending = false
    @AppStorage(trackListColumns: "artist") private var showsColumns: Bool
    @State private var searchText = ""
    @State private var searchLoadedPages = 0

    var body: some View {
        List {
            content
        }
        .environment(\.trackSortKey, showsSortMenu ? sortKey : nil)
        .trackListColumns(showsSortMenu && showsColumns)
        .listStyle(.plain)
        .navigationTitle(shelf.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsSortMenu {
                ToolbarItem(placement: .topBarTrailing) {
                    TrackSortMenu(sortKey: $sortKey, ascending: $ascending, showsColumns: $showsColumns)
                }
            }
        }
        .libraryPageSearchable(text: $searchText, prompt: "Search \(shelf.title.lowercased())")
        .refreshable {
            if let section = shelf.section { await viewModel.reload(section: section) }
        }
        .task {
            if let section = shelf.section {
                await viewModel.loadSectionIfNeeded(section)
            } else {
                await similar.loadIfNeeded()
            }
        }
        .task(id: trimmedSearch) { await loadMoreWhileSearchIsEmpty() }
        .task(id: visibleTrackIDs) { await analysisStore.load(for: sourceTracks) }
        .queueConfirmationOverlay(confirmation)
    }

    @ViewBuilder
    private var content: some View {
        switch shelf {
        case .tracks, .likes:
            let source = sourceTracks
            let filtered = sorted(source).filter(matchesTrackSearch)
            sectionBody(isEmpty: source.isEmpty) {
                searchAware(filteredEmpty: filtered.isEmpty) {
                    trackRows(filtered, source: source)
                }
                sectionFooter
            }

        case .albums, .singles, .playlists:
            let source = shelfPlaylists
            let filtered = source.filter(matchesPlaylistSearch)
            sectionBody(isEmpty: source.isEmpty) {
                searchAware(filteredEmpty: filtered.isEmpty) {
                    playlistRows(filtered)
                }
                sectionFooter
            }

        case .reposts:
            let playlists = viewModel.repostedPlaylists.filter(matchesPlaylistSearch)
            let tracks = sorted(viewModel.repostedTracks).filter(matchesTrackSearch)
            sectionBody(isEmpty: viewModel.repostedTracks.isEmpty && viewModel.repostedPlaylists.isEmpty) {
                searchAware(filteredEmpty: playlists.isEmpty && tracks.isEmpty) {
                    if !playlists.isEmpty {
                        playlistRows(playlists)
                    }
                    if !tracks.isEmpty {
                        trackRows(tracks, source: viewModel.repostedTracks)
                    }
                }
                sectionFooter
            }

        case .similar:
            similarRows
        }
    }

    @ViewBuilder
    private var similarRows: some View {
        let people = similar.artists.filter { trimmedSearch.isEmpty || $0.displayName.scLocallyContains(trimmedSearch) || $0.username.scLocallyContains(trimmedSearch) }
        if !similar.hasFinished {
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        } else if similar.artists.isEmpty {
            ContentUnavailableView(
                "No Similar Artists",
                systemImage: "person.2",
                description: Text("SoundCloud has no similar artists for \(user.displayName) yet.")
            )
            .listRowSeparator(.hidden)
        } else if people.isEmpty {
            ContentUnavailableView.search(text: trimmedSearch)
                .listRowSeparator(.hidden)
        } else {
            ForEach(people) { person in
                NavigationLink(value: person) {
                    UserRow(user: person)
                }
                .libraryRowPreviewShape()
                .contextMenu { UserContextMenu(user: person) }
            }
        }
    }

    private var sourceTracks: [Track] {
        switch shelf {
        case .tracks: viewModel.tracks
        case .likes: viewModel.likedTracks
        case .reposts: viewModel.repostedTracks
        default: []
        }
    }

    private var visibleTrackIDs: [String] { sourceTracks.map(\.id) }

    private var shelfPlaylists: [Playlist] {
        switch shelf {
        case .albums: viewModel.albums
        case .singles: viewModel.singlesAndEPs
        case .playlists: viewModel.otherPlaylists
        default: []
        }
    }

    private var showsSortMenu: Bool {
        switch shelf {
        case .tracks: !viewModel.tracks.isEmpty
        case .likes: !viewModel.likedTracks.isEmpty
        case .reposts: !viewModel.repostedTracks.isEmpty
        default: false
        }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sorted(_ tracks: [Track]) -> [Track] {
        TrackSort.sorted(tracks, by: sortKey, ascending: ascending, analysis: analysisStore.summaries)
    }

    private func matchesTrackSearch(_ track: Track) -> Bool {
        guard !trimmedSearch.isEmpty else { return true }
        return track.title.scLocallyContains(trimmedSearch) || track.user.displayName.scLocallyContains(trimmedSearch)
    }

    private func matchesPlaylistSearch(_ playlist: Playlist) -> Bool {
        guard !trimmedSearch.isEmpty else { return true }
        return playlist.title.scLocallyContains(trimmedSearch)
    }

    private var visibleIsEmpty: Bool {
        switch shelf {
        case .tracks, .likes: sourceTracks.filter(matchesTrackSearch).isEmpty
        case .albums, .singles, .playlists: shelfPlaylists.filter(matchesPlaylistSearch).isEmpty
        case .reposts: viewModel.repostedTracks.filter(matchesTrackSearch).isEmpty && viewModel.repostedPlaylists.filter(matchesPlaylistSearch).isEmpty
        case .similar: false
        }
    }

    private static let searchPageLimit = 10

    private func loadMoreWhileSearchIsEmpty() async {
        guard !trimmedSearch.isEmpty, let section = shelf.section else { return }
        try? await Task.sleep(for: .milliseconds(500))
        while !Task.isCancelled, searchLoadedPages < Self.searchPageLimit, visibleIsEmpty, viewModel.canAutoLoadMore(section) {
            if viewModel.loadingMore.contains(section) {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            searchLoadedPages += 1
            let before = viewModel.tracks.count + viewModel.playlists.count + viewModel.repostsPager.items.count + viewModel.likedTracks.count
            await viewModel.loadMore(section: section)
            let after = viewModel.tracks.count + viewModel.playlists.count + viewModel.repostsPager.items.count + viewModel.likedTracks.count
            if after == before { return }
        }
    }

    @ViewBuilder
    private func searchAware<Content: View>(filteredEmpty: Bool, @ViewBuilder content: () -> Content) -> some View {
        if !trimmedSearch.isEmpty, filteredEmpty {
            if let section = shelf.section, viewModel.loadingMore.contains(section) {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            } else {
                ContentUnavailableView.search(text: trimmedSearch)
                    .listRowSeparator(.hidden)
            }
        } else {
            content()
        }
    }

    @ViewBuilder
    private var sectionFooter: some View {
        if trimmedSearch.isEmpty, let section = shelf.section {
            switch section {
            case .tracks:    PagedFooter(pager: viewModel.tracksPager).listRowSeparator(.hidden)
            case .playlists: PagedFooter(pager: viewModel.playlistsPager).listRowSeparator(.hidden)
            case .reposts:   PagedFooter(pager: viewModel.repostsPager).listRowSeparator(.hidden)
            case .likes:     PagedFooter(pager: viewModel.likesPager).listRowSeparator(.hidden)
            }
        }
    }

    @ViewBuilder
    private func sectionBody<Content: View>(isEmpty: Bool, @ViewBuilder content: () -> Content) -> some View {
        if let section = shelf.section, viewModel.isLoading(section), isEmpty {
            LoadingPlaceholder(.trackList(.phoneRoomy), count: 6, insets: false)
                .listRowSeparator(.hidden)
        } else if let section = shelf.section, let error = viewModel.errorMessage(section), isEmpty {
            ContentUnavailableView {
                Label("Couldn\u{2019}t Load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await viewModel.reload(section: section) } }
            }
            .listRowSeparator(.hidden)
        } else if isEmpty {
            ContentUnavailableView(shelf.title, systemImage: emptyIcon, description: Text(emptyMessage))
                .listRowSeparator(.hidden)
        } else {
            content()
        }
    }

    private var emptyIcon: String {
        switch shelf {
        case .tracks: "music.note"
        case .albums, .singles: "square.stack"
        case .playlists: "music.note.list"
        case .reposts: "arrow.2.squarepath"
        case .likes: "heart"
        case .similar: "person.2"
        }
    }

    private var emptyMessage: String {
        switch shelf {
        case .tracks: "\(user.displayName) hasn\u{2019}t uploaded any tracks."
        case .albums: "\(user.displayName) hasn\u{2019}t released any albums."
        case .singles: "\(user.displayName) hasn\u{2019}t released any singles or EPs."
        case .playlists: "\(user.displayName) hasn\u{2019}t published any playlists."
        case .reposts: "\(user.displayName) hasn\u{2019}t reposted anything."
        case .likes: "\(user.displayName) hasn\u{2019}t publicly liked any tracks."
        case .similar: ""
        }
    }

    @ViewBuilder
    private func trackRows(_ tracks: [Track], source: [Track]) -> some View {
        ForEach(tracks) { track in
            TrackListRow(
                track: track,
                analysis: analysisStore.summaries[track.id],
                context: { tracks },
                confirmation: confirmation
            )
            .onAppear {
                guard trimmedSearch.isEmpty, let section = shelf.section, source.isNearEnd(track, lead: 10) else { return }
                viewModel.requestMore(section: section)
            }
        }
        UnanalysedTracksFooter(tracks: tracks, sortKey: sortKey, summaries: analysisStore.summaries)
    }

    @ViewBuilder
    private func playlistRows(_ playlists: [Playlist]) -> some View {
        ForEach(playlists) { playlist in
            PlaylistLink(playlist, heroNamespace: heroNamespace, isListRow: true) {
                PlaylistRow(playlist: playlist)
            }
            .matchedTransitionSource(id: playlist.id, in: heroNamespace)
            .libraryRowPreviewShape()
            .contextMenu { PlaylistContextMenu(playlist: playlist) }
            .onAppear {
                guard trimmedSearch.isEmpty, let section = shelf.section, playlists.isNearEnd(playlist, lead: 10) else { return }
                viewModel.requestMore(section: section)
            }
        }
    }
}

struct ArtistConnectionsView: View {
    let artist: User
    let kind: ArtistConnectionKind
    let model: ArtistConnectionsModel
    @ObservedObject private var pager: Paginator<User>
    @State private var searchText = ""

    init(artist: User, kind: ArtistConnectionKind, model: ArtistConnectionsModel) {
        self.artist = artist
        self.kind = kind
        self.model = model
        _pager = ObservedObject(wrappedValue: model.pager)
    }

    var body: some View {
        Group {
            if (pager.isLoadingFirst || pager.isPaused) && pager.items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pager.firstError != nil, pager.items.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Load \(kind.rawValue)", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Couldn’t reach SoundCloud. Check your connection and try again.")
                } actions: {
                    Button("Try Again") { Task { await model.loadIfNeeded(force: true) } }
                }
            } else if pager.items.isEmpty, pager.hasLoadedFirst {
                ContentUnavailableView(
                    kind.rawValue,
                    systemImage: kind.systemImage,
                    description: Text(emptyMessage)
                )
            } else if pager.items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visiblePeople.isEmpty {
                if pager.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView.search(text: trimmedSearch)
                }
            } else {
                List {
                    ForEach(visiblePeople) { person in
                        NavigationLink {
                            ArtistDetailView(user: person)
                        } label: {
                            UserRow(user: person)
                        }
                        .libraryRowPreviewShape()
                        .contextMenu { UserContextMenu(user: person) }
                        .onAppear {
                            guard trimmedSearch.isEmpty else { return }
                            pager.loadMoreIfNeeded(after: person, lead: 12)
                        }
                    }

                    if trimmedSearch.isEmpty {
                        PagedFooter(pager: pager)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(kind.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .libraryPageSearchable(text: $searchText, prompt: "Search \(kind.rawValue.lowercased())")
        .task { await model.loadIfNeeded() }
        .task(id: trimmedSearch) { await model.loadMoreWhileSearching(trimmedSearch) }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visiblePeople: [User] {
        model.filtered(trimmedSearch)
    }

    private var emptyMessage: String {
        switch kind {
        case .following: "\(artist.displayName) isn’t following anyone."
        case .followers: "Nobody follows \(artist.displayName) yet."
        }
    }
}
