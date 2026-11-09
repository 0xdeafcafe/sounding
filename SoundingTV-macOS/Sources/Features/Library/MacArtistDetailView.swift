import SwiftUI
import AppKit
import Combine

enum ArtistDetailPane: String, CaseIterable {
    case overview  = "Overview"
    case activity  = "Activity"
    case tracks    = "Tracks"
    case playlists = "Playlists"
    case reposts   = "Reposts"
    case likes     = "Likes"
    case following = "Following"
    case followers = "Followers"

    var detailSection: ArtistDetailSection? {
        switch self {
        case .tracks:    return .tracks
        case .playlists: return .playlists
        case .reposts:   return .reposts
        case .likes:     return .likes
        case .overview, .activity, .following, .followers: return nil
        }
    }
}

struct MacArtistDetailView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    let user: User
    var showsToolbarSearch = true

    @StateObject private var viewModel: ArtistDetailViewModel
    @StateObject private var similar: ArtistSimilarModel
    @State private var followingModel: ArtistConnectionsModel
    @State private var followersModel: ArtistConnectionsModel
    @ObservedObject private var localActivity = MacLocalProfileActivity.shared
    @State private var pane: ArtistDetailPane = .overview
    @State private var searchText = ""
    @State private var updatingPlaylistIDs = Set<String>()
    @State private var isFollowing: Bool?
    @State private var isUpdatingFollow = false
    @State private var isConfirmingUnfollow = false
    @State private var isActivitySummaryExpanded = false
    @State private var profileCoverURL: URL?
    @State private var avatarURL: URL?
    @State private var heroGone = false
    @State private var heroArtGone = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    init(
        user: User,
        initialPane: ArtistDetailPane = .overview,
        showsToolbarSearch: Bool = true
    ) {
        self.user = user
        self.showsToolbarSearch = showsToolbarSearch
        #if DEBUG
        let debugPane = ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_ARTIST_PANE"].flatMap { ArtistDetailPane(rawValue: $0.capitalized) }
        _pane = State(initialValue: debugPane ?? initialPane)
        #else
        _pane = State(initialValue: initialPane)
        #endif
        _viewModel = StateObject(wrappedValue: ArtistDetailViewModel(user: user))
        _similar = StateObject(wrappedValue: ArtistSimilarModel(user: user))
        _followingModel = State(initialValue: ArtistConnectionsModel(userID: user.id, kind: .following))
        _followersModel = State(initialValue: ArtistConnectionsModel(userID: user.id, kind: .followers))
        _profileCoverURL = State(initialValue: user.profileCoverURL)
        _avatarURL = State(initialValue: user.largeAvatarURL ?? user.avatarURL)
    }

    var body: some View {
        content
            .navigationTitle(user.displayName)
            .toolbar(removing: .title)
            .toolbar {
                if heroGone {
                    MacScrolledPageTitle(title: user.displayName)
                }
            }
            .onChange(of: heroGone) { _, gone in MacPageTitleVisibility.shared.isShowingPushedTitle = gone }
            .onDisappear { MacPageTitleVisibility.shared.isShowingPushedTitle = false }
            .task { await viewModel.loadOverviewIfNeeded() }
            .task(id: user.id) { await loadProfileCover() }
            .task(id: credentials.currentUser?.id) { await loadFollowState() }
            .onChange(of: pane) { _, newPane in
                searchText = ""
                if let mapped = newPane.detailSection {
                    viewModel.selectedSection = mapped
                }
                Task { await load() }
            }
            .confirmationDialog(
                "Unfollow @\(user.username)?",
                isPresented: $isConfirmingUnfollow,
                titleVisibility: .visible
            ) {
                Button("Unfollow", role: .destructive) { setFollowState(false) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Their public music will remain available, but they will be removed from your followed artists.")
            }
    }

    @ViewBuilder
    private var content: some View {
        let detail = MacViewportScrollView(extendsUnderToolbar: true, hidesContentUnderToolbar: heroArtGone) {
            VStack(alignment: .leading, spacing: 0) {
                hero
                    .onGeometryChange(for: Bool.self) { proxy in
                        let frame = proxy.frame(in: .global)
                        return frame.height > 0 && frame.maxY <= 0
                    } action: { heroArtGone = $0 }

                headerDetails
                    .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                    .padding(.top, SCContentStyle.mac.spaceBase)
                    .padding(.bottom, SCContentStyle.mac.spaceRoomy)

                sectionPicker
                    .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                    .padding(.bottom, SCContentStyle.mac.spaceBase)
                    .macFadesUnderToolbar()

                sectionContent
                    .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                    .padding(.bottom, 32)
            }
            .collectionPageScheme()
        }
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollEdgeEffectHidden(!heroArtGone, for: .top)
        .collectionPersonBackdrop(heroContent, blursBanner: false)
        .background(Color.primary.opacity(0.001))
        .collectionPersonPage(heroContent)
        .collectionAccent(from: heroContent.accentURL)
        if showsToolbarSearch {
            detail.searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: "Search \(pane.rawValue.lowercased())"
            )
        } else {
            detail
        }
    }

    private func load() async {
        if pane == .overview {
            await viewModel.loadOverviewIfNeeded()
        } else if pane == .activity {
            await viewModel.loadActivityIfNeeded()
        } else if pane == .following {
            await followingModel.loadIfNeeded()
        } else if pane == .followers {
            await followersModel.loadIfNeeded()
        } else {
            await viewModel.loadIfNeeded()
        }
    }

    private var heroHeight: CGFloat { user.trackCount > 0 ? 330 : 270 }

    private var heroContent: PersonHeroContent {
        PersonHeroContent(
            user: user,
            bannerURL: profileCoverURL,
            avatarURL: avatarURL,
            badge: "\(user.formattedFollowers) \(user.followersCount == 1 ? "Follower" : "Followers")"
        )
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear

            HStack(alignment: .bottom, spacing: PersonHeroMetrics.mac.spacing) {
                PersonHeroTitle(content: heroContent, metrics: .mac)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .macFadesUnderToolbar()
                    .macReportsScrolledAway($heroGone)

                if user.trackCount > 0 || !viewModel.tracks.isEmpty {
                    PersonHeroPlayButton(name: user.displayName, diameter: 44, isEnabled: !playableTracks.isEmpty, action: playArtist)
                        .macFadesUnderToolbar()
                }
            }
            .padding(.horizontal, SCContentStyle.mac.spaceGutter + 8)
            .padding(.bottom, SCContentStyle.mac.spaceRoomy)
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .collectionScrollBackdropHero()
        .accessibilityElement(children: .contain)
    }

    private var headerDetails: some View {
        VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSnug) {
            Text("@\(user.username)")
                .font(.subheadline)
                .foregroundStyle(MacSecondaryStyle())
                .lineLimit(1)
                .macFadesUnderToolbar()

            artistActions
                .padding(.top, 2)
                .macFadesUnderToolbar()
        }
    }

    private func loadProfileCover() async {
        if user.profileCoverURL != nil, avatarURL != nil { return }
        guard let refreshed = try? await SoundCloudAPI.shared.getUser(id: user.id),
              !Task.isCancelled else { return }
        profileCoverURL = refreshed.profileCoverURL ?? profileCoverURL
        avatarURL = refreshed.largeAvatarURL ?? refreshed.avatarURL ?? avatarURL
    }

    private var artistActions: some View {
        HStack(spacing: SCContentStyle.mac.spaceSnug) {
            if user.trackCount > 0 || !viewModel.tracks.isEmpty {
                Button(action: shuffleArtist) {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(minWidth: 72)
                }
                .buttonStyle(.bordered)
                .disabled(playableTracks.isEmpty)
                .help("Shuffle \(user.displayName)")
                .accessibilityLabel("Shuffle \(user.displayName)")
            }

            if credentials.currentUser?.id != user.id,
               !credentials.isSignedOut {
                Button {
                    if isFollowing == true {
                        isConfirmingUnfollow = true
                    } else {
                        setFollowState(true)
                    }
                } label: {
                    Label(
                        isFollowing == true ? "Following" : "Follow",
                        systemImage: isFollowing == true ? "checkmark" : "plus"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isFollowing == nil || isUpdatingFollow)
                .accessibilityLabel(isFollowing == true ? "Unfollow \(user.displayName)" : "Follow \(user.displayName)")
                .accessibilityValue(isFollowing == true ? "Following" : "Not following")

                ScoutToggleButton(user: user, isFollowed: isFollowing)
                    .buttonStyle(.bordered)
            }

            Menu {
                StartStationMenuButton(artist: user)

                Divider()

                Button {
                    NSWorkspace.shared.open(user.permalinkURL)
                } label: {
                    Label("Open on SoundCloud", systemImage: "safari")
                }

                Button {
                    MacMessageComposer.shared.present(user: user)
                } label: {
                    Label("Message", systemImage: "envelope")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(user.permalinkURL.absoluteString, forType: .string)
                } label: {
                    Label("Copy SoundCloud Link", systemImage: "link")
                }

                ShareLink(item: user.permalinkURL, subject: Text(user.displayName), preview: SharePreview(user.displayName)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .help("More")
            .accessibilityLabel("More actions for \(user.displayName)")
        }
        .controlSize(.large)
    }

    private var playableTracks: [Track] {
        viewModel.tracks.filter { $0.streamURL != nil }
    }

    private func playArtist() {
        guard let first = playableTracks.first else { return }
        Task { await MacPlayback.play(first, in: viewModel.tracks, source: PlaybackQueueSource(artist: user)) }
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
                localActivity.record(user: user, followed: following)
            } catch {
                isFollowing = previous
            }
        }
    }

    private func shuffleArtist() {
        guard !playableTracks.isEmpty else { return }
        Task { await MacPlayback.shuffle(viewModel.tracks, source: PlaybackQueueSource(artist: user)) }
    }

    private var sectionPicker: some View {
        ViewThatFits(in: .horizontal) {
            sectionTabs(visible: ArtistDetailPane.allCases.count)
            sectionTabs(visible: 5)
            sectionTabs(visible: 3)
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionTabs(visible count: Int) -> some View {
        let overflow = Array(ArtistDetailPane.allCases.dropFirst(count))
        return GlassEffectContainer(spacing: SCContentStyle.mac.spaceTight) {
            HStack(spacing: SCContentStyle.mac.spaceTight) {
                ForEach(Array(ArtistDetailPane.allCases.prefix(count)), id: \.self) { candidate in
                    sectionTab(candidate)
                }
                if !overflow.isEmpty {
                    sectionOverflowMenu(overflow)
                }
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    @ViewBuilder
    private func sectionTab(_ candidate: ArtistDetailPane) -> some View {
        let button = Button(candidate.rawValue) {
            withAnimation(.snappy) { pane = candidate }
        }
        .accessibilityAddTraits(pane == candidate ? .isSelected : [])
        if pane == candidate {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    @ViewBuilder
    private func sectionOverflowMenu(_ overflow: [ArtistDetailPane]) -> some View {
        let menu = Menu {
            Picker("Section", selection: $pane) {
                ForEach(overflow, id: \.self) { candidate in
                    Text(candidate.rawValue).tag(candidate)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(overflow.contains(pane) ? pane.rawValue : "More")
        }
        .menuStyle(.button)
        .accessibilityLabel("More Sections")
        if overflow.contains(pane) {
            menu.buttonStyle(.glassProminent)
        } else {
            menu.buttonStyle(.glass)
        }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch pane {
        case .overview:
            overviewBody
        case .activity:
            activityBody
        case .tracks:
            sectionBody(isEmpty: viewModel.tracks.isEmpty, icon: "music.note", message: "\(user.displayName) hasn\u{2019}t uploaded any tracks.") {
                VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                    trackTable(filteredTracks)
                    pagedFooter(viewModel.tracksPager)

                    if !filteredAlbums.isEmpty {
                        collectionSection(title: "Albums", subtitle: nil) {
                            playlistGrid(filteredAlbums, onNearEnd: viewModel.playlistsPager.requestMore)
                            pagedFooter(viewModel.playlistsPager)
                        }
                    }
                    if !filteredSingles.isEmpty {
                        collectionSection(title: "Singles & EPs", subtitle: nil) {
                            playlistGrid(filteredSingles, onNearEnd: viewModel.playlistsPager.requestMore)
                        }
                    }
                }
            }
        case .playlists:
            sectionBody(isEmpty: viewModel.playlists.isEmpty, icon: "music.note.list", message: "\(user.displayName) hasn\u{2019}t published any playlists.") {
                VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                    if !publicPlaylists.isEmpty {
                        collectionSection(title: "Public", subtitle: "Visible to everyone") {
                            playlistGrid(publicPlaylists, onNearEnd: viewModel.playlistsPager.requestMore)
                        }
                    }
                    if !privatePlaylists.isEmpty {
                        collectionSection(title: "Private", subtitle: "Visible only to the owner and people with access") {
                            playlistGrid(privatePlaylists, onNearEnd: viewModel.playlistsPager.requestMore)
                        }
                    }
                    pagedFooter(viewModel.playlistsPager)
                }
            }
        case .reposts:
            sectionBody(
                isEmpty: viewModel.repostedTracks.isEmpty && viewModel.repostedPlaylists.isEmpty,
                icon: "arrow.2.squarepath",
                message: "\(user.displayName) hasn\u{2019}t reposted anything."
            ) {
                VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceRoomy) {
                    if !filteredRepostedPlaylists.isEmpty {
                        collectionSection(title: "Reposted Playlists", subtitle: nil) {
                            playlistGrid(filteredRepostedPlaylists, onNearEnd: viewModel.repostsPager.requestMore)
                        }
                    }
                    if !filteredRepostedTracks.isEmpty {
                        collectionSection(title: "Reposted Tracks", subtitle: nil) {
                            trackTable(filteredRepostedTracks)
                        }
                    }
                    pagedFooter(viewModel.repostsPager)
                }
            }
        case .likes:
            sectionBody(isEmpty: viewModel.likedTracks.isEmpty, icon: "heart", message: "\(user.displayName) hasn\u{2019}t liked any tracks publicly.") {
                VStack(spacing: 0) {
                    trackTable(filteredLikedTracks)
                    pagedFooter(viewModel.likesPager)
                }
            }
        case .following:
            followingBody
        case .followers:
            followersBody
        }
    }

    @ViewBuilder
    private func pagedFooter<Item: Identifiable>(_ pager: Paginator<Item>) -> some View {
        if trimmedSearch.isEmpty {
            MacPagedFooter(pager: pager)
        }
    }

    private func requestMoreActivity() {
        viewModel.tracksPager.requestMore()
        viewModel.repostsPager.requestMore()
        viewModel.likesPager.requestMore()
    }

    private var activityFooter: some View {
        let isLoading = viewModel.tracksPager.isLoadingMore || viewModel.repostsPager.isLoadingMore || viewModel.likesPager.isLoadingMore
        let failed = viewModel.tracksPager.didFailLoadingMore || viewModel.repostsPager.didFailLoadingMore || viewModel.likesPager.didFailLoadingMore
        let paused = viewModel.tracksPager.isPaused || viewModel.repostsPager.isPaused || viewModel.likesPager.isPaused
        return LazyVStack(spacing: 0) {
            PagedFooter(
                isLoading: isLoading,
                failed: failed,
                isPaused: paused,
                retry: {
                    Task {
                        async let tracks: Void = viewModel.tracksPager.retry()
                        async let reposts: Void = viewModel.repostsPager.retry()
                        async let likes: Void = viewModel.likesPager.retry()
                        _ = await (tracks, reposts, likes)
                    }
                },
                reachedEnd: requestMoreActivity
            )
        }
    }

    private enum LatestRelease {
        case collection(Playlist)
        case single(Track)

        var date: Date {
            switch self {
            case .collection(let playlist): return playlist.createdAt
            case .single(let track): return track.createdAt
            }
        }
    }

    private var latestRelease: LatestRelease? {
        if let album = (filteredAlbums + filteredSingles).max(by: { $0.createdAt < $1.createdAt }) { return .collection(album) }
        if let track = filteredTracks.max(by: { $0.createdAt < $1.createdAt }) { return .single(track) }
        return nil
    }

    private var topTracks: [Track] { filterTracks(viewModel.topTracks) }

    @ViewBuilder
    private var overviewBody: some View {
        if viewModel.isLoading(.tracks), viewModel.tracks.isEmpty, viewModel.playlists.isEmpty {
            LoadingPlaceholder(.trackList(.mac), count: 6, insets: false)
        } else if let error = viewModel.errorMessage(.tracks), viewModel.tracks.isEmpty, viewModel.playlists.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await viewModel.reload(section: .tracks) } }
            }
            .macFillsPane()
        } else if viewModel.tracks.isEmpty && viewModel.playlists.isEmpty {
            ContentUnavailableView(
                "No Music Yet",
                systemImage: "music.note",
                description: Text("\(user.displayName) hasn’t shared any public music.")
            )
            .macFillsPane()
        } else {
            VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: SCContentStyle.mac.spaceRoomy) {
                        if let latestRelease {
                            latestReleaseSection(latestRelease).frame(width: 220, alignment: .leading)
                        }
                        topTracksSection.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                        if let latestRelease {
                            latestReleaseSection(latestRelease)
                        }
                        topTracksSection
                    }
                }

                playlistShelf("Albums", playlists: filteredAlbums)
                playlistShelf("Singles & EPs", playlists: filteredSingles)
                playlistShelf("Playlists", playlists: filteredSets)

                DisclosureGroup("Activity Summary", isExpanded: $isActivitySummaryExpanded) {
                    HStack(spacing: 16) {
                        activityMetric(viewModel.tracksPager.countText(singular: "upload", plural: "uploads"), icon: "arrow.up.circle")
                        activityMetric(viewModel.repostsPager.countText(singular: "repost", plural: "reposts"), icon: "arrow.2.squarepath")
                        activityMetric(viewModel.likesPager.countText(singular: "like", plural: "likes"), icon: "heart")
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
                .foregroundStyle(MacSecondaryStyle())
                .onChange(of: isActivitySummaryExpanded) { _, expanded in
                    guard expanded else { return }
                    Task { await viewModel.loadActivityIfNeeded() }
                }

                PersonAboutSection(user: user, style: .mac, inset: SCContentStyle.mac.spaceGutter) { kind in
                    pane = kind == .following ? .following : .followers
                }
                .padding(.horizontal, -SCContentStyle.mac.spaceGutter)
                .onAppear { Task { await similar.loadIfNeeded() } }

                similarShelf
            }
        }
    }

    @ViewBuilder
    private var similarShelf: some View {
        if !similar.artists.isEmpty {
            CollectionShelf(
                title: "Similar Artists",
                items: similar.artists,
                style: .mac,
                tileWidth: 140,
                spacing: SCContentStyle.mac.spaceBase,
                inset: SCContentStyle.mac.spaceGutter
            ) { artist in
                NavigationLink(value: artist) {
                    PersonShelfTile(user: artist, diameter: 140, style: .mac)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(artist.displayName), artist")
            }
            .padding(.horizontal, -SCContentStyle.mac.spaceGutter)
            .macFadesUnderToolbar()
        }
    }

    private func playlistShelf(_ title: String, playlists: [Playlist]) -> some View {
        CollectionShelf(
            title: title,
            items: playlists,
            style: .mac,
            tileWidth: 168,
            spacing: SCContentStyle.mac.spaceBase,
            inset: SCContentStyle.mac.spaceGutter,
            headerAction: { pane = .playlists }
        ) { playlist in
            NavigationLink(value: playlist) {
                ArtworkShelfCard(playlist: playlist, style: .mac)
            }
            .buttonStyle(.plain)
            .macCardHover(artworkURL: playlist.displayArtworkURL, prewarm: { CollectionPlayback.prewarm(playlist: playlist) }, play: { Task { await MacPlayback.play(playlist: playlist) } }) {
                MacPlaylistContextMenu(
                    playlist: playlist,
                    canChangePrivacy: credentials.currentUser?.id == playlist.user.id,
                    isUpdatingPrivacy: updatingPlaylistIDs.contains(playlist.id),
                    onTogglePrivacy: { togglePlaylistPrivacy(playlist) }
                )
            }
            .accessibilityLabel("\(playlist.title), \(playlist.isAlbum ? "album" : "playlist")")
        }
        .padding(.horizontal, -SCContentStyle.mac.spaceGutter)
        .macFadesUnderToolbar()
    }

    private func latestReleaseSection(_ release: LatestRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SCSectionHeader(title: "Latest Release", style: .mac).macFadesUnderToolbar()

            switch release {
            case .collection(let playlist):
                NavigationLink(value: playlist) {
                    releaseCard(
                        url: playlist.largeDisplayArtworkURL,
                        identity: playlist.id,
                        date: release.date,
                        title: playlist.title,
                        detail: "\(playlist.totalTrackCount) \(playlist.totalTrackCount == 1 ? "track" : "tracks")",
                        crownUser: playlist.user
                    )
                }
                .buttonStyle(.plain)
                .contextMenu { MacPlaylistContextMenu(playlist: playlist) }
                .accessibilityLabel("Latest release, \(playlist.title)")
            case .single(let track):
                Button {
                    Task { await MacPlayback.play(track, in: viewModel.tracks, source: PlaybackQueueSource(artist: user)) }
                } label: {
                    releaseCard(
                        url: track.largeArtworkURL ?? track.artworkURL,
                        identity: track.id,
                        date: release.date,
                        title: track.title,
                        detail: singleDetail(track),
                        crownUser: track.user,
                        showsPlay: true
                    )
                }
                .buttonStyle(.plain)
                .macTrackAccessibility(track: track, context: viewModel.tracks)
                .accessibilityHint("Latest release")
                .macTrackContextMenu(track: track)
            }
        }
    }

    private func singleDetail(_ track: Track) -> String {
        guard let genre = track.genre, !genre.isEmpty else { return "Single" }
        return "Single · \(genre)"
    }

    private func releaseCard(
        url: URL?,
        identity: String,
        date: Date,
        title: String,
        detail: String,
        crownUser: User?,
        showsPlay: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkThumbnail(
                url: url,
                identity: identity,
                size: 220,
                cornerRadius: 14,
                crownUser: crownUser,
                crownContext: title
            )
            .overlay(alignment: .bottomTrailing) {
                if showsPlay {
                    Image(systemName: "play.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .macAdaptiveGlass(in: Circle())
                        .padding(10)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(date.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.caption)
                    .foregroundStyle(MacSecondaryStyle())
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(MacSecondaryStyle())
                    .lineLimit(1)
            }
            .macFadesUnderToolbar()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var topTracksSection: some View {
        if !topTracks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SCSectionHeader(title: "Top Tracks", showChevron: true, action: { pane = .tracks }, style: .mac)
                    .help("See All Tracks")
                    .accessibilityHint("Shows every track, with sorting")
                    .macFadesUnderToolbar()
                MacTrackRows(
                    tracks: Array(topTracks.prefix(6)),
                    onPlay: { track in
                        Task { await MacPlayback.play(track, in: topTracks, source: PlaybackQueueSource(artist: user)) }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var activityBody: some View {
        if viewModel.isLoading(.tracks) || viewModel.isLoading(.reposts) || viewModel.isLoading(.likes), activityItems.isEmpty {
            LoadingPlaceholder(.trackList(.mac), count: 8, insets: false)
        } else if activityItems.isEmpty {
            ContentUnavailableView(
                "No Activity Yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Uploads, reposts and likes from \(user.displayName) will appear here.")
            )
            .macFillsPane()
        } else {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    activityMetric(viewModel.tracksPager.countText(singular: "upload", plural: "uploads"), icon: "arrow.up.circle")
                    activityMetric(viewModel.repostsPager.countText(singular: "repost", plural: "reposts"), icon: "arrow.2.squarepath")
                    activityMetric(viewModel.likesPager.countText(singular: "like", plural: "likes"), icon: "heart")
                    Spacer(minLength: 0)
                }

                ForEach(activityGroups) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(group.title)
                            .font(.headline)
                        LazyVStack(spacing: 0) {
                            ForEach(group.items) { item in
                                profileActivityRow(item)
                                    .onAppear {
                                        guard activityItems.isNearEnd(item, lead: 10) else { return }
                                        requestMoreActivity()
                                    }
                            }
                        }
                    }
                }

                activityFooter
            }
        }
    }

    private func activityMetric(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(MacSecondaryStyle())
    }

    private var activityGroups: [ActivityDateGroup] {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let grouped = Dictionary(grouping: activityItems) { item -> String in
            if calendar.isDateInToday(item.date) { return "Today" }
            if calendar.isDateInYesterday(item.date) { return "Yesterday" }
            if let week = calendar.date(byAdding: .day, value: -7, to: now), item.date >= week {
                return "This Week"
            }
            return "Earlier"
        }
        let order = ["Today", "Yesterday", "This Week", "Earlier"]
        return order.compactMap { title in
            guard let items = grouped[title], !items.isEmpty else { return nil }
            return ActivityDateGroup(title: title, items: items)
        }
    }

    @ViewBuilder
    private func profileActivityRow(_ item: ProfileActivityItem) -> some View {
        let row = HStack(spacing: 12) {
            ArtworkThumbnail(
                url: item.artworkURL,
                identity: item.title,
                size: 40,
                cornerRadius: item.person != nil ? 20 : 5
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.action)
                    .font(.subheadline)
                    .foregroundStyle(MacSecondaryStyle())
            }
            Spacer(minLength: 8)
            Text(item.date, style: .relative)
                .font(.subheadline)
                .foregroundStyle(MacSecondaryStyle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .macHoverRowHighlight()
        .overlay(alignment: .bottom) { Divider().padding(.leading, 62) }

        if let track = item.track {
            Button {
                Task { await MacPlayback.play(track, in: activityItems.compactMap(\.track)) }
            } label: { row }
            .buttonStyle(.plain)
            .macTrackAccessibility(track: track, context: activityItems.compactMap(\.track))
            .accessibilityHint("\(item.action), \(item.date.formatted(.relative(presentation: .named)))")
            .macTrackContextMenu(track: track)
        } else if let playlist = item.playlist {
            NavigationLink(value: playlist) { row }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title), \(item.action), \(item.date.formatted(.relative(presentation: .named)))")
        } else if let person = item.person {
            NavigationLink(value: person) { row }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title), \(item.action), \(item.date.formatted(.relative(presentation: .named)))")
                .contextMenu { MacArtistContextMenu(artist: person) }
        }
    }

    private func collectionSection<Content: View>(
        title: String,
        subtitle: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSnug) {
            HStack(alignment: .firstTextBaseline) {
                SCSectionHeader(title: title, style: .mac).macFadesUnderToolbar()
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(MacSecondaryStyle())
                }
                Spacer(minLength: 0)
            }
            content()
        }
    }

    @ViewBuilder
    private var followingBody: some View {
        if followingModel.isLoading, followingModel.users.isEmpty {
            LoadingPlaceholder(.grid(minimumTile: 140, circular: true), insets: false)
        } else if let error = followingModel.errorMessage, followingModel.users.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await followingModel.loadIfNeeded(force: true) } }
            }
            .macFillsPane()
        } else if followingModel.users.isEmpty {
            ContentUnavailableView(
                "Not Following Anyone",
                systemImage: "person.2",
                description: Text("\(user.displayName) isn’t following anyone yet.")
            )
            .macFillsPane()
        } else {
            MacPeopleGrid(people: filteredFollowing, pager: followingModel.pager, pagesOnScroll: trimmedSearch.isEmpty)
        }
    }

    @ViewBuilder
    private var followersBody: some View {
        if followersModel.isLoading, followersModel.users.isEmpty {
            LoadingPlaceholder(.grid(minimumTile: 140, circular: true), insets: false)
        } else if let error = followersModel.errorMessage, followersModel.users.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await followersModel.loadIfNeeded(force: true) } }
            }
            .macFillsPane()
        } else if followersModel.users.isEmpty {
            ContentUnavailableView(
                "No Followers",
                systemImage: "person.2",
                description: Text("Nobody follows \(user.displayName) yet.")
            )
            .macFillsPane()
        } else {
            MacPeopleGrid(people: filteredFollowers, pager: followersModel.pager, pagesOnScroll: trimmedSearch.isEmpty)
        }
    }

    @ViewBuilder
    private func sectionBody<Content: View>(
        isEmpty: Bool,
        icon: String,
        message: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if viewModel.isLoading(viewModel.selectedSection), isEmpty {
            LoadingPlaceholder(viewModel.selectedSection == .playlists ? .grid(minimumTile: 150) : .trackList(.mac), insets: false)
        } else if let error = viewModel.errorMessage(viewModel.selectedSection), isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await viewModel.reload(section: viewModel.selectedSection) } }
            }
            .macFillsPane()
        } else if isEmpty {
            ContentUnavailableView(
                "No \(viewModel.selectedSection.rawValue)",
                systemImage: icon,
                description: Text(message)
            )
            .macFillsPane()
        } else {
            content()
        }
    }

    private func trackTable(_ tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MacCollectionTrackTable(
                tracks: tracks,
                onPlay: { track in Task { await MacPlayback.play(track, in: tracks) } }
            )
        }
    }

    private func playlistGrid(_ playlists: [Playlist], onNearEnd: (() -> Void)? = nil) -> some View {
        let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: SCContentStyle.mac.spaceRoomy)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(playlists) { playlist in
                NavigationLink {
                    if playlist.isAlbum {
                        MacAlbumDetailView(album: playlist)
                    } else {
                        MacPlaylistDetailView(playlist: playlist)
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        MacPlaylistCard(playlist: playlist)
                        playlistPrivacyBadge(playlist)
                            .padding(7)
                    }
                }
                .buttonStyle(.plain)
                .macCardHover(artworkURL: playlist.displayArtworkURL, prewarm: { CollectionPlayback.prewarm(playlist: playlist) }, play: { Task { await MacPlayback.play(playlist: playlist) } }) {
                    MacPlaylistContextMenu(
                        playlist: playlist,
                        canChangePrivacy: credentials.currentUser?.id == playlist.user.id,
                        isUpdatingPrivacy: updatingPlaylistIDs.contains(playlist.id),
                        onTogglePrivacy: { togglePlaylistPrivacy(playlist) }
                    )
                }
                .accessibilityLabel("\(playlist.title), \(playlist.isAlbum ? "album" : "playlist")\(playlist.sharing == "private" ? ", private" : "")")
                .onAppear {
                    guard let onNearEnd, trimmedSearch.isEmpty, playlists.isNearEnd(playlist, lead: 12) else { return }
                    onNearEnd()
                }
            }
        }
    }

    @ViewBuilder
    private func playlistPrivacyBadge(_ playlist: Playlist) -> some View {
        if playlist.sharing == "private" {
            Label("Private", systemImage: "lock.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .macAdaptiveGlass(in: Capsule(style: .continuous), tint: Color.black.opacity(0.34))
        }
    }

    private func togglePlaylistPrivacy(_ playlist: Playlist) {
        guard credentials.currentUser?.id == playlist.user.id else { return }
        updatingPlaylistIDs.insert(playlist.id)
        Task {
            defer { updatingPlaylistIDs.remove(playlist.id) }
            try? await viewModel.setPlaylistSharing(
                playlist,
                to: playlist.sharing == "private" ? "public" : "private"
            )
        }
    }

    private var filteredTracks: [Track] { filterTracks(viewModel.tracks) }
    private var filteredLikedTracks: [Track] { filterTracks(viewModel.likedTracks) }
    private var filteredRepostedTracks: [Track] { filterTracks(viewModel.repostedTracks) }
    private var filteredPlaylists: [Playlist] { filterPlaylists(viewModel.playlists) }
    private var publicPlaylists: [Playlist] { filteredPlaylists.filter { $0.sharing != "private" } }
    private var privatePlaylists: [Playlist] { filteredPlaylists.filter { $0.sharing == "private" } }
    private var filteredAlbums: [Playlist] { filteredPlaylists.filter { $0.isAlbum && !ArtistReleaseKind.isSingleOrEP($0) } }
    private var filteredSingles: [Playlist] { filteredPlaylists.filter(ArtistReleaseKind.isSingleOrEP) }
    private var filteredSets: [Playlist] { filteredPlaylists.filter { !$0.isAlbum && !ArtistReleaseKind.isSingleOrEP($0) } }
    private var filteredRepostedPlaylists: [Playlist] { filterPlaylists(viewModel.repostedPlaylists) }

    private var filteredFollowing: [User] { followingModel.filtered(trimmedSearch) }

    private var filteredFollowers: [User] { followersModel.filtered(trimmedSearch) }

    private func filterTracks(_ tracks: [Track]) -> [Track] {
        guard !trimmedSearch.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedSearch) || $0.user.displayName.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    private func filterPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        guard !trimmedSearch.isEmpty else { return playlists }
        return playlists.filter { $0.title.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    private var activityItems: [ProfileActivityItem] {
        let uploads = viewModel.tracks.map { ProfileActivityItem.upload($0) }
        let reposts = viewModel.repostItems.compactMap(ProfileActivityItem.repost)
        let likes = viewModel.likeItems.map(ProfileActivityItem.like)
        let local = credentials.currentUser?.id == user.id
            ? localActivity.events.map(ProfileActivityItem.local)
            : []
        let items = (uploads + reposts + likes + local).sorted { $0.date > $1.date }
        guard !trimmedSearch.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(trimmedSearch) }
    }
}

private struct ActivityDateGroup: Identifiable {
    let title: String
    let items: [ProfileActivityItem]
    var id: String { title }
}

private struct ProfileActivityItem: Identifiable, Equatable {
    let id: String
    let date: Date
    let action: String
    let track: Track?
    let playlist: Playlist?
    let person: User?

    var title: String { track?.title ?? playlist?.title ?? person?.displayName ?? "Untitled" }
    var artworkURL: URL? { track?.artworkURL ?? playlist?.artworkURL ?? person?.avatarURL }
    var isPlaylist: Bool { playlist != nil }

    static func upload(_ track: Track) -> Self {
        Self(id: "upload-track-\(track.id)", date: track.createdAt, action: "Uploaded a track", track: track, playlist: nil, person: nil)
    }

    static func repost(_ item: StreamItem) -> Self? {
        if let track = item.track {
            return Self(id: "repost-track-\(track.id)-\(item.createdAt.timeIntervalSince1970)", date: item.createdAt, action: "Reposted a track", track: track, playlist: nil, person: nil)
        }
        if let playlist = item.playlist {
            return Self(id: "repost-playlist-\(playlist.id)-\(item.createdAt.timeIntervalSince1970)", date: item.createdAt, action: "Reposted a playlist", track: nil, playlist: playlist, person: nil)
        }
        return nil
    }

    static func like(_ item: Like<Track>) -> Self {
        Self(
            id: "like-track-\(item.item.id)-\(item.createdAt.timeIntervalSince1970)",
            date: item.createdAt,
            action: "Liked a track",
            track: item.item,
            playlist: nil,
            person: nil
        )
    }

    static func local(_ event: MacLocalProfileActivity.Event) -> Self {
        Self(
            id: event.id,
            date: event.date,
            action: event.followed ? "Followed a profile" : "Unfollowed a profile",
            track: nil,
            playlist: nil,
            person: event.user
        )
    }
}

@MainActor
private final class MacLocalProfileActivity: ObservableObject {
    static let shared = MacLocalProfileActivity()

    struct Event: Identifiable, Codable {
        let id: String
        let date: Date
        let user: User
        let followed: Bool
    }

    @Published private(set) var events: [Event]
    private static let defaultsKey = "red.forbes.sounding.mac.profileActivity"

    private var forgetObserver: NSObjectProtocol?

    private init() {
        events = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []
        forgetObserver = NotificationCenter.default.addObserver(
            forName: AccountDataVault.didForgetAccountData,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.events = []
                UserDefaults.standard.removeObject(forKey: MacLocalProfileActivity.defaultsKey)
            }
        }
    }

    func record(user: User, followed: Bool) {
        events.insert(Event(id: UUID().uuidString, date: Date(), user: user, followed: followed), at: 0)
        events = Array(events.prefix(200))
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

struct MacArtistsPane: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var model: MacArtistsPaneModel
    @ObservedObject private var findFocus = MacFindFocus.shared
    @State private var searchText = ""
    @State private var selectedArtistID: String? = Self.allArtistsID
    @State private var isSearchPresented = false

    private static let allArtistsID = "__all_artists__"

    init(model: MacArtistsPaneModel) {
        self.model = model
    }

    var body: some View {
        Group {
            if credentials.isSessionRejected {
                MacAccountRecoveryEmptyState(sectionName: "Artists")
            } else if credentials.isSignedOut {
                MacSignedOutEmptyState(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "Artists Need an Account",
                    message: "Sign in to see the artists you follow. Home and Search work without an account.",
                    browsableRoute: .home
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isLoading && model.artists.isEmpty {
                MacLoadingView()
            } else if let error = model.errorMessage, model.artists.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Load Artists", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        let credentials = credentials
                        Task { await model.load(credentials: credentials, force: true) }
                    }
                }
                .macFillsPane()
            } else if artistAccounts.isEmpty, !model.isLoading {
                ContentUnavailableView {
                    Label("No Artists Yet", systemImage: "music.microphone")
                } description: {
                    Text("Follow artists on SoundCloud and they’ll appear here.")
                } actions: {
                    Button("Find Artists") { MacRootSelection.shared.request(.search) }
                }
                .macFillsPane()
            } else {
                artistSplitView
            }
        }
        .navigationTitle("Artists")
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: "Filter Artists"
        )
        .navigationSubtitle(
            selectedArtistID == Self.allArtistsID && !artistAccounts.isEmpty
                ? "\(artistAccounts.count) artist\(artistAccounts.count == 1 ? "" : "s")"
                : ""
        )
        .onReceive(findFocus.$request.dropFirst()) { _ in isSearchPresented = true }
        .task {
            await model.load(credentials: credentials)
            selectFirstArtistIfNeeded()
        }
        .onChange(of: artistAccounts.map(\.id)) { _, _ in selectFirstArtistIfNeeded() }
        .onChange(of: credentials.isSignedOut) { _, isSignedOut in
            guard !isSignedOut else { return }
            let credentials = credentials
            Task {
                await model.load(credentials: credentials, force: true)
            }
        }
        .onChange(of: credentials.isAuthenticated) { _, isAuthenticated in
            guard isAuthenticated else { return }
            let credentials = credentials
            Task { await model.load(credentials: credentials, force: true) }
        }
    }

    private var artistSplitView: some View {
        HStack(spacing: 0) {
            artistSourceList
                .frame(width: 280)

            Divider()

            Group {
                if selectedArtistID == Self.allArtistsID {
                    allArtistsGrid
                } else if let selectedArtist {
                    MacArtistDetailView(
                        user: selectedArtist,
                        showsToolbarSearch: false
                    )
                    .id(selectedArtist.id)
                } else {
                    ContentUnavailableView(
                        "Choose an Artist",
                        systemImage: "music.microphone",
                        description: Text("Select an artist to see their music and activity.")
                    )
                    .macFillsPane()
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.001))
        }
    }

    private var artistSourceList: some View {
        MacVisualEffect(role: .sidebar) {
            artistSourceListContent
        }
    }

    private var artistSourceListContent: some View {
        List {
            MacSidebarLabel("All Artists", systemImage: "music.microphone")
                .macSelectableRow(Self.allArtistsID, selection: $selectedArtistID)

            if filteredArtists.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .macFillsPane()
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredArtists) { artist in
                    ArtistSourceRow(artist: artist)
                        .macSelectableRow(artist.id, selection: $selectedArtistID)
                        .contextMenu { MacArtistContextMenu(artist: artist) }
                        .onAppear {
                            guard searchText.isEmpty else { return }
                            model.pager.loadMoreIfNeeded(after: artist, lead: 14)
                        }
                }
            }

            if searchText.isEmpty {
                MacPagedFooter(pager: model.pager, isInLazyContainer: true)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .macListKeyboardSelection(
            ids: [Self.allArtistsID] + filteredArtists.map(\.id),
            selection: $selectedArtistID
        )
    }

    private var allArtistsGrid: some View {
        MacViewportScrollView {
            if filteredArtists.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .macFillsPane()
            } else {
                MacPeopleGrid(people: filteredArtists, pager: model.pager, pagesOnScroll: searchText.isEmpty)
                    .padding(SCContentStyle.mac.spaceGutter)
            }
        }
        .defaultScrollAnchor(.top, for: .alignment)
    }

    private var filteredArtists: [User] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sortedArtists }
        return sortedArtists.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle)
                || $0.username.localizedCaseInsensitiveContains(needle)
        }
    }

    private var sortedArtists: [User] {
        artistAccounts.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private var artistAccounts: [User] {
        model.artists.filter(\.isArtist)
    }

    private var selectedArtist: User? {
        guard let selectedArtistID else { return nil }
        return artistAccounts.first { $0.id == selectedArtistID }
    }

    private func selectFirstArtistIfNeeded() {
        if let selectedArtistID {
            if selectedArtistID == Self.allArtistsID {
                return
            }
            if artistAccounts.contains(where: { $0.id == selectedArtistID }) {
                return
            }
        }
        selectedArtistID = Self.allArtistsID
    }

}

private struct ArtistSourceRow: View {
    let artist: User

    var body: some View {
        HStack(spacing: SCContentStyle.mac.spaceSnug) {
            ArtworkThumbnail(
                url: artist.avatarURL,
                identity: artist.id,
                size: 32,
                cornerRadius: 16,
                crownUser: artist,
                crownContext: artist.displayName
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(artist.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(artist.formattedFollowers) followers")
                    .font(.caption)
                    .foregroundStyle(MacSecondaryStyle())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
final class MacArtistsPaneModel: ObservableObject {
    @Published private(set) var isHydrating = false
    @Published private(set) var errorMessage: String?

    let pager: Paginator<User>

    private var hasLoaded = false
    private var observations = Set<AnyCancellable>()

    init() {
        pager = Paginator(source: LibraryDB.userSource(.followings), maxUnattendedPages: 1_000)
        pager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        LibrarySyncEngine.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        LibrarySyncEngine.shared.$revision
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.hasLoaded else { return }
                Task { await self.pager.reload() }
            }
            .store(in: &observations)
    }

    var artists: [User] { pager.items }

    var isLoading: Bool {
        if isHydrating || pager.isLoadingFirst { return true }
        return pager.items.isEmpty && LibrarySyncEngine.shared.isAwaitingFirstSync(.followings)
    }

    func load(credentials: SoundCloudCredentialSource, force: Bool = false) async {
        if hasLoaded, !force { return }
        guard !credentials.isSignedOut else { return }
        isHydrating = true
        errorMessage = nil
        defer { isHydrating = false }
        if force {
            LibrarySyncEngine.shared.requestRefresh([.followings])
        } else {
            LibrarySyncEngine.shared.kick()
        }
        await pager.reload()
        hasLoaded = true
    }
}
