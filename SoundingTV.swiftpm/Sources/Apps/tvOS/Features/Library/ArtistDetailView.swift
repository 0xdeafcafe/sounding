import SwiftUI
import Combine

struct ArtistDetailView: View {
    let user: User
    private let isOwnProfile: Bool

    @EnvironmentObject private var playerService: PlayerService
    @EnvironmentObject private var authService: AuthenticationService
    @StateObject private var viewModel: ArtistDetailViewModel
    @StateObject private var followingModel: TVArtistConnectionsModel
    @StateObject private var followersModel: TVArtistConnectionsModel
    @StateObject private var similar: TVSimilarArtistsModel
    @State private var profile: User?
    @State private var bannerURL: URL?
    @State private var avatarURL: URL?
    @State private var isFollowing: Bool?
    @State private var isUpdatingFollow = false
    @State private var confirmsUnfollow = false
    @State private var confirmsSignOut = false
    @State private var isShowingBio = false
    @State private var requestedSections: Set<ArtistDetailSection> = []
    @State private var destination: PersonDestination?
    @State private var openedPlaylist: Playlist?
    @FocusState private var heroFocus: HeroFocus?

    private enum HeroFocus: Hashable {
        case play
        case shuffle
    }

    private static let inset: CGFloat = 80
    private static let songRowWidth: CGFloat = 600
    private static let songRowHeight: CGFloat = 88
    private static let songRows = 4
    private static let releaseArtwork: CGFloat = 300

    init(user: User, isOwnProfile: Bool = false) {
        self.user = user
        self.isOwnProfile = isOwnProfile
        _bannerURL = State(initialValue: user.profileCoverURL)
        _avatarURL = State(initialValue: user.largeAvatarURL ?? user.avatarURL)
        _viewModel = StateObject(wrappedValue: ArtistDetailViewModel(user: user))
        _followingModel = StateObject(wrappedValue: TVArtistConnectionsModel(userID: user.id, kind: .following))
        _followersModel = StateObject(wrappedValue: TVArtistConnectionsModel(userID: user.id, kind: .followers))
        _similar = StateObject(wrappedValue: TVSimilarArtistsModel(userID: user.id))
    }

    private var person: User { profile ?? user }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                hero
                LazyVStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
                    sections
                }
                .padding(.top, Space.section)
                .padding(.bottom, Space.page)
            }
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: [.top, .horizontal])
        .foregroundStyle(Color.scTextPrimary)
        .collectionPageMesh(url: paletteSource.url, variant: paletteSource.variant)
        .collectionAccent(from: heroContent.accentURL)
        .defaultFocus($heroFocus, .play)
        .navigationDestination(item: $destination) { destination in
            destinationView(destination)
        }
        .navigationDestination(item: $openedPlaylist) { PlaylistDetailView(playlist: $0) }
        .sheet(isPresented: $isShowingBio) {
            TVPersonBioSheet(name: person.displayName, bio: bio ?? "")
        }
        .confirmationDialog("Unfollow \(user.displayName)?", isPresented: $confirmsUnfollow, titleVisibility: .visible) {
            Button("Unfollow", role: .destructive) { setFollowState(false) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Sign Out", isPresented: $confirmsSignOut) {
            Button("Sign Out", role: .destructive) {
                Task {
                    SessionSyncBookkeeping.recordLocalSignOut()
                    await authService.logout()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You\u{2019}ll need to pair with your iPhone again to sign back in.")
        }
        .task { await viewModel.loadOverviewIfNeeded() }
        .task(id: user.id) { await loadProfile() }
        .task(id: user.id) { await loadFollowState() }
    }

    // MARK: - Hero

    private var heroBadge: (text: String, symbol: String?)? {
        if person.verified == true { return ("Verified", "checkmark.seal.fill") }
        if isFollowing == true { return ("Following", "checkmark") }
        guard person.followersCount > 0 else { return nil }
        return ("\(person.formattedFollowers) \(person.followersCount == 1 ? "Follower" : "Followers")", nil)
    }

    private var paletteSource: (url: URL?, variant: ArtworkVariant) {
        if let bannerURL { return (bannerURL, .signed) }
        return (avatarURL, .thumbnail)
    }

    private var heroContent: PersonHeroContent {
        let badge = heroBadge
        return PersonHeroContent(user: user, bannerURL: bannerURL, avatarURL: avatarURL, badge: badge?.text, badgeSymbol: badge?.symbol)
    }

    private var hero: some View {
        let metrics = PersonHeroMetrics.tv
        let height = metrics.height(for: 1080)
        return ZStack(alignment: .bottomLeading) {
            ZStack {
                PersonHeroImage(
                    bannerURL: bannerURL,
                    avatarURL: avatarURL,
                    seed: user.artSeed,
                    avatarBlur: metrics.avatarBlur,
                    backdropIdentity: user.id
                )
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()

                PersonHeroScrim()
                    .frame(height: height)
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.62),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            HStack(alignment: .bottom, spacing: Space.section) {
                heroAvatar
                VStack(alignment: .leading, spacing: Space.base) {
                    PersonHeroTitle(content: heroContent, metrics: metrics)
                    heroButtons
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, metrics.horizontalInset)
            .padding(.bottom, metrics.bottomInset)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .environment(\.colorScheme, .dark)
    }

    private var heroAvatar: some View {
        SCArtworkResolver(url: avatarURL, variant: .hero) { image in
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                SoundingArtworkView(identity: user.id, subject: .person)
            }
        }
        .frame(width: 184, height: 184)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1) }
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .kyleCrowned(user: user, context: user.displayName)
        .accessibilityHidden(true)
    }

    private var heroButtons: some View {
        HStack(spacing: Space.snug) {
            Button {
                Task { await PlayActions.play(tracks: viewModel.tracks) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.tvHeadline)
            }
            .buttonStyle(TVGlassPillStyle(isProminent: true, diameter: 96))
            .focused($heroFocus, equals: .play)
            .accessibilityLabel("Play \(user.displayName)")
            .accessibilityIdentifier("artist.play")

            Button {
                Task { await PlayActions.shufflePlay(tracks: viewModel.tracks) }
            } label: {
                Image(systemName: "shuffle")
                    .font(.tvBodyEmph)
            }
            .buttonStyle(TVGlassPillStyle(diameter: 80))
            .focused($heroFocus, equals: .shuffle)
            .accessibilityLabel("Shuffle \(user.displayName)")
            .accessibilityIdentifier("artist.shuffle")

            if canFollow, let isFollowing {
                Button {
                    if isFollowing {
                        confirmsUnfollow = true
                    } else {
                        setFollowState(true)
                    }
                } label: {
                    TVGlassPillLabel(title: isFollowing ? "Following" : "Follow", systemImage: isFollowing ? "checkmark" : "plus")
                }
                .buttonStyle(TVGlassPillStyle())
                .accessibilityIdentifier("artist.follow")
            }

            if isOwnProfile {
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task {
                            await viewModel.reload(section: .tracks)
                            await viewModel.reload(section: .playlists)
                        }
                    }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmsSignOut = true
                    }
                    .accessibilityIdentifier("profile.signOut")
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.tvBodyEmph)
                }
                .buttonStyle(TVGlassPillStyle(diameter: 80))
                .accessibilityLabel("More")
                .accessibilityIdentifier("profile.more")
            }
        }
        .focusSection()
    }

    private var canFollow: Bool {
        !isOwnProfile && authService.isAuthenticated && authService.currentUser?.id != user.id
    }

    private func loadProfile() async {
        if bannerURL != nil, avatarURL != nil, user.verified != nil, user.description != nil { return }
        guard let refreshed = try? await SoundCloudAPI.shared.getUser(id: user.id), !Task.isCancelled else { return }
        profile = refreshed
        bannerURL = refreshed.profileCoverURL ?? bannerURL
        avatarURL = refreshed.largeAvatarURL ?? refreshed.avatarURL ?? avatarURL
    }

    private func loadFollowState() async {
        guard canFollow else { return }
        guard let following = try? await SoundCloudAPI.shared.isFollowing(userId: user.id), !Task.isCancelled else { return }
        isFollowing = following
    }

    private func setFollowState(_ following: Bool) {
        guard isFollowing != following, !isUpdatingFollow else { return }
        let previous = isFollowing
        isUpdatingFollow = true
        isFollowing = following
        Task {
            defer { isUpdatingFollow = false }
            do {
                try await SoundCloudAPI.shared.setFollowing(following, userId: user.id)
            } catch {
                isFollowing = previous
            }
        }
    }

    // MARK: - Sections

    private var albums: [Playlist] { viewModel.playlists.filter { $0.isAlbum && !$0.isSingleOrEP } }
    private var singles: [Playlist] { viewModel.playlists.filter(\.isSingleOrEP) }
    private var otherPlaylists: [Playlist] { viewModel.playlists.filter { !$0.isAlbum && !$0.isSingleOrEP } }
    private var sets: [Track] { viewModel.tracks.filter { CollectionKind.classify(trackDurationSeconds: $0.duration) == .set } }
    private var topTracks: [Track] { viewModel.topTracks }

    private var latestRelease: TVLatestRelease? {
        if let release = (albums + singles).max(by: { ($0.releaseDate ?? $0.createdAt) < ($1.releaseDate ?? $1.createdAt) }) {
            return .collection(release)
        }
        if let track = viewModel.tracks.max(by: { $0.createdAt < $1.createdAt }) {
            return .single(track)
        }
        return nil
    }

    private var repostTiles: [TVRepostTile] {
        var seen: Set<String> = []
        return viewModel.repostItems.compactMap { item -> TVRepostTile? in
            if let playlist = item.playlist { return .playlist(playlist) }
            if let track = item.track { return .track(track) }
            return nil
        }
        .filter { seen.insert($0.id).inserted }
    }

    @ViewBuilder
    private var sections: some View {
        if viewModel.isLoading(.tracks), viewModel.tracks.isEmpty, viewModel.playlists.isEmpty {
            LoadingPlaceholder(.shelf(tile: SCBrowseMetrics.tileEdge), count: 6, insets: false)
                .frame(height: SCBrowseMetrics.tileEdge + 96, alignment: .top)
                .padding(.horizontal, Self.inset)
        } else if let error = viewModel.errorMessage(.tracks), viewModel.tracks.isEmpty, viewModel.playlists.isEmpty {
            StatusPanel(
                kind: .error,
                title: "Couldn\u{2019}t Load \(user.displayName)",
                message: error,
                actionTitle: "Try Again",
                action: {
                    Task {
                        await viewModel.reload(section: .tracks)
                        await viewModel.reload(section: .playlists)
                    }
                },
                minHeight: 320
            )
            about
        } else if viewModel.tracks.isEmpty, viewModel.playlists.isEmpty {
            StatusPanel(
                kind: .empty,
                icon: "music.note",
                title: "No Tracks",
                message: isOwnProfile ? "You haven\u{2019}t uploaded any tracks." : "\(user.displayName) hasn\u{2019}t uploaded any tracks.",
                minHeight: 320
            )
            if isOwnProfile { likesShelf }
            about
        } else {
            releaseAndTopSongs
            playlistShelf("Albums", playlists: albums, destination: .albums)
            playlistShelf("Singles & EPs", playlists: singles, destination: .singles)
            setsShelf
            playlistShelf("Playlists", playlists: otherPlaylists, destination: .playlists)
            repostsShelf
            if isOwnProfile { likesShelf }
            about
            similarShelf
        }
    }

    @ViewBuilder
    private var releaseAndTopSongs: some View {
        HStack(alignment: .top, spacing: SCBrowseMetrics.gutter) {
            if let latestRelease {
                latestReleaseView(latestRelease)
                    .focusSection()
            }
            if !topTracks.isEmpty {
                topSongs
            }
        }
        .padding(.leading, Self.inset)
    }

    private func latestReleaseView(_ release: TVLatestRelease) -> some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            SCSectionHeader(title: "Latest Release", style: SCBrowseMetrics.header)
            switch release {
            case .collection(let playlist):
                Button {
                    openedPlaylist = playlist
                } label: {
                    releaseLabel(
                        url: playlist.largeDisplayArtworkURL,
                        identity: playlist.id,
                        date: release.date,
                        title: playlist.title,
                        detail: "\(CollectionPageKind(playlist: playlist).label) \u{00B7} \(playlist.totalTrackCount) \(playlist.totalTrackCount == 1 ? "track" : "tracks")"
                    )
                }
            case .single(let track):
                Button {
                    play(track, in: [track])
                } label: {
                    releaseLabel(
                        url: track.largeArtworkURL ?? track.artworkURL,
                        identity: track.id,
                        date: release.date,
                        title: track.title,
                        detail: "Single"
                    )
                }
            }
        }
        .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .card))
        .focusEffectDisabled()
    }

    private func releaseLabel(url: URL?, identity: String, date: Date, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: Space.base) {
            SCArtworkResolver(url: url) { image in
                if let image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    SoundingArtworkView(identity: identity, subject: .collection)
                }
            }
            .frame(width: Self.releaseArtwork, height: Self.releaseArtwork)
            .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))

            VStack(alignment: .leading, spacing: Space.hair) {
                Text(date.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextSecondary)
                Text(title)
                    .font(.tvBodyEmph)
                    .foregroundStyle(Color.scTextPrimary)
                    .lineLimit(3)
                Text(detail)
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(1)
            }
            .frame(width: SCBrowseMetrics.wideCardWidth - Self.releaseArtwork - Space.base, alignment: .leading)
        }
        .frame(width: SCBrowseMetrics.wideCardWidth, alignment: .leading)
    }

    private var topSongs: some View {
        let songs = Array(topTracks.prefix(Self.songRows * 5))
        return VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            Button {
                destination = .tracks
            } label: {
                TVShelfHeaderLabel(title: "Top Songs")
            }
            .buttonStyle(TVCollectionLinkStyle())

            ScrollView(.horizontal) {
                LazyHGrid(
                    rows: Array(repeating: GridItem(.fixed(Self.songRowHeight), spacing: Space.hair), count: Self.songRows),
                    alignment: .top,
                    spacing: SCBrowseMetrics.gutter
                ) {
                    ForEach(songs) { track in
                        songRow(track, context: songs)
                    }
                }
                .padding(.trailing, Self.inset)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func songRow(_ track: Track, context: [Track]) -> some View {
        var item = SCTrackListItem(track: track, showsArtist: false)
        item.artist = songSubtitle(track)
        item.analysis = nil
        return Button {
            play(track, in: context)
        } label: {
            SCTrackListRow(item: item, leading: .artwork, activity: activity(for: track), metrics: .tv, crownUser: track.user)
                .frame(width: Self.songRowWidth, height: Self.songRowHeight)
        }
        .buttonStyle(TVCollectionRowStyle())
        .contextMenu { TVTrackMenuItems(track: track) }
        .accessibilityLabel(item.accessibilityLabel)
        .prewarmPlaybackOnFocus(track.streamURL != nil ? track : nil)
    }

    private func songSubtitle(_ track: Track) -> String {
        var parts = [String(Calendar.current.component(.year, from: track.createdAt))]
        if let plays = track.playbackCount, plays > 0 {
            parts.append("\(plays.formatted(.number.notation(.compactName))) plays")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private func playlistShelf(_ title: String, playlists: [Playlist], destination target: PersonDestination) -> some View {
        if !playlists.isEmpty {
            CollectionShelf(
                title: title,
                items: playlists,
                style: SCBrowseMetrics.header,
                tileWidth: SCBrowseMetrics.tileEdge,
                spacing: SCBrowseMetrics.gutter,
                inset: Self.inset,
                headerAction: { destination = target }
            ) { playlist in
                Button {
                    openedPlaylist = playlist
                } label: {
                    ArtworkShelfCard(playlist: playlist, style: SCBrowseMetrics.tile)
                }
                .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
                .focusEffectDisabled()
            }
            .prefetchArtwork(playlists.compactMap(\.largeDisplayArtworkURL))
        }
    }

    @ViewBuilder
    private var setsShelf: some View {
        let sets = self.sets
        if !sets.isEmpty {
            CollectionShelf(
                title: "Sets",
                items: sets,
                style: SCBrowseMetrics.header,
                tileWidth: SCBrowseMetrics.tileEdge,
                spacing: SCBrowseMetrics.gutter,
                inset: Self.inset
            ) { track in
                trackTile(track, context: sets, subtitle: "\(Calendar.current.component(.year, from: track.createdAt)) \u{00B7} \(track.formattedDuration)")
            }
        }
    }

    @ViewBuilder
    private var repostsShelf: some View {
        let tiles = repostTiles
        if !tiles.isEmpty {
            let tracks = tiles.compactMap(\.track)
            CollectionShelf(
                title: "Reposts",
                items: tiles,
                style: SCBrowseMetrics.header,
                tileWidth: SCBrowseMetrics.tileEdge,
                spacing: SCBrowseMetrics.gutter,
                inset: Self.inset,
                headerAction: { destination = .reposts }
            ) { tile in
                switch tile {
                case .playlist(let playlist):
                    Button {
                        openedPlaylist = playlist
                    } label: {
                        ArtworkShelfCard(
                            title: playlist.title,
                            subtitle: playlist.user.displayName,
                            artworkURL: playlist.largeDisplayArtworkURL,
                            identity: playlist.id,
                            subject: .collection,
                            crownUser: playlist.user,
                            style: SCBrowseMetrics.tile
                        )
                    }
                    .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
                    .focusEffectDisabled()
                case .track(let track):
                    trackTile(track, context: tracks, subtitle: track.user.displayName)
                }
            }
        } else if !requestedSections.contains(.reposts) {
            CollectionRelatedTrigger { load(.reposts) }
        }
    }

    @ViewBuilder
    private var likesShelf: some View {
        let liked = viewModel.likedTracks
        if !liked.isEmpty {
            CollectionShelf(
                title: "Likes",
                items: Array(liked.prefix(24)),
                style: SCBrowseMetrics.header,
                tileWidth: SCBrowseMetrics.tileEdge,
                spacing: SCBrowseMetrics.gutter,
                inset: Self.inset,
                headerAction: { destination = .likes }
            ) { track in
                trackTile(track, context: liked, subtitle: track.user.displayName)
            }
        } else if !requestedSections.contains(.likes) {
            CollectionRelatedTrigger { load(.likes) }
        }
    }

    private func trackTile(_ track: Track, context: [Track], subtitle: String) -> some View {
        Button {
            play(track, in: context)
        } label: {
            ArtworkShelfCard(
                title: track.title,
                subtitle: subtitle,
                artworkURL: track.largeArtworkURL ?? track.artworkURL,
                identity: track.id,
                subject: .track,
                isAvailable: track.streamURL != nil,
                crownUser: track.user,
                style: SCBrowseMetrics.tile
            )
        }
        .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
        .focusEffectDisabled()
        .prewarmPlaybackOnFocus(track.streamURL != nil ? track : nil)
    }

    // MARK: - About

    private var bio: String? {
        guard let text = person.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            SCSectionHeader(title: "About", style: SCBrowseMetrics.header)

            HStack(alignment: .top, spacing: Space.page) {
                if let bio {
                    Button {
                        isShowingBio = true
                    } label: {
                        Text(bio)
                            .font(.tvCallout)
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: 900, alignment: .leading)
                    }
                    .buttonStyle(TVCollectionLinkStyle(cornerRadius: Corner.control, horizontalPadding: Space.base, verticalPadding: Space.snug))
                    .accessibilityLabel("About \(person.displayName)")
                    .accessibilityHint("Shows the full biography")
                }

                VStack(alignment: .leading, spacing: Space.roomy) {
                    HStack(spacing: Space.section) {
                        statLink(person.followersCount, label: person.followersCount == 1 ? "Follower" : "Followers", destination: .followers)
                        statLink(person.followingsCount, label: "Following", destination: .following)
                        if person.isArtist {
                            statLink(person.trackCount, label: person.trackCount == 1 ? "Track" : "Tracks", destination: .tracks)
                        }
                    }

                    VStack(alignment: .leading, spacing: Space.tight) {
                        SoundCloudProfileFacts(user: person, font: .tvCallout)
                        Label("soundcloud.com/\(person.permalink)", systemImage: "music.note")
                    }
                    .font(.tvCallout)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(1)
                }
            }
            .focusSection()
        }
        .padding(.horizontal, Self.inset)
    }

    private func statLink(_ count: Int, label: String, destination target: PersonDestination) -> some View {
        Button {
            destination = target
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(count.formatted(.number.notation(.compactName)))
                    .font(.tvHeadline)
                    .monospacedDigit()
                Text(label)
                    .font(.tvCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(TVCollectionLinkStyle(cornerRadius: Corner.control, horizontalPadding: Space.snug, verticalPadding: Space.tight))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(label)")
    }

    @ViewBuilder
    private var similarShelf: some View {
        if !similar.artists.isEmpty {
            CollectionShelf(
                title: "Similar Artists",
                items: similar.artists,
                style: SCBrowseMetrics.header,
                tileWidth: SCBrowseMetrics.tileEdge,
                spacing: SCBrowseMetrics.gutter,
                inset: Self.inset
            ) { artist in
                TVUserLink(user: artist) {
                    SCArtworkResolver(url: artist.largeAvatarURL ?? artist.avatarURL) { image in
                        SCArtistCard(
                            name: artist.displayName,
                            subtitle: artist.followersCount > 0 ? "\(artist.formattedFollowers) followers" : nil,
                            avatarImage: image,
                            identity: artist.id,
                            diameter: SCBrowseMetrics.tileEdge,
                            crownUser: artist,
                            crownContext: artist.displayName,
                            style: SCBrowseMetrics.tile
                        )
                    }
                }
                .buttonStyle(SCArtistCardButtonStyle())
                .focusEffectDisabled()
            }
            .prefetchArtwork(similar.artists.compactMap { $0.largeAvatarURL ?? $0.avatarURL })
        } else if !similar.hasFinished {
            CollectionRelatedTrigger {
                let seed = topTracks.first { !$0.isLocal }
                Task { await similar.load(seed: seed) }
            }
        }
    }

    // MARK: - Actions

    private func load(_ section: ArtistDetailSection) {
        guard requestedSections.insert(section).inserted else { return }
        Task {
            viewModel.selectedSection = section
            await viewModel.loadIfNeeded()
        }
    }

    private func activity(for track: Track) -> SCTrackActivity {
        guard playerService.currentTrack?.id == track.id else { return .none }
        return playerService.isPlaying ? .playing : .paused
    }

    private func play(_ track: Track, in context: [Track]) {
        guard track.streamURL != nil else { return }
        let playable = context.filter { $0.streamURL != nil }
        Task { await playerService.play(track, in: playable) }
    }

    // MARK: - Pages

    @ViewBuilder
    private func destinationView(_ destination: PersonDestination) -> some View {
        switch destination {
        case .tracks:
            TVPersonListPage(title: "Tracks", subtitle: user.displayName) {
                TVPersonTracksPage(viewModel: viewModel, section: .tracks)
            }
        case .albums:
            TVPersonListPage(title: "Albums", subtitle: user.displayName) {
                TVPersonCollectionsPage(viewModel: viewModel, filter: { $0.isAlbum && !$0.isSingleOrEP })
            }
        case .singles:
            TVPersonListPage(title: "Singles & EPs", subtitle: user.displayName) {
                TVPersonCollectionsPage(viewModel: viewModel, filter: \.isSingleOrEP)
            }
        case .playlists:
            TVPersonListPage(title: "Playlists", subtitle: user.displayName) {
                TVPersonCollectionsPage(viewModel: viewModel, filter: { !$0.isAlbum && !$0.isSingleOrEP })
            }
        case .reposts:
            TVPersonListPage(title: "Reposts", subtitle: user.displayName) {
                TVPersonRepostsPage(viewModel: viewModel)
            }
        case .likes:
            TVPersonListPage(title: "Likes", subtitle: user.displayName) {
                TVPersonTracksPage(viewModel: viewModel, section: .likes)
            }
        case .followers:
            TVPersonListPage(title: "Followers", subtitle: user.displayName) {
                TVPersonConnectionsPage(model: followersModel, name: user.displayName)
            }
        case .following:
            TVPersonListPage(title: "Following", subtitle: user.displayName) {
                TVPersonConnectionsPage(model: followingModel, name: user.displayName)
            }
        }
    }
}

private enum PersonDestination: Hashable {
    case tracks
    case albums
    case singles
    case playlists
    case reposts
    case likes
    case followers
    case following
}

private enum TVLatestRelease {
    case collection(Playlist)
    case single(Track)

    var date: Date {
        switch self {
        case .collection(let playlist): return playlist.releaseDate ?? playlist.createdAt
        case .single(let track): return track.createdAt
        }
    }
}

private enum TVRepostTile: Identifiable {
    case track(Track)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .track(let track): return "track-\(track.id)"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        }
    }

    var track: Track? {
        if case .track(let track) = self { return track }
        return nil
    }
}

private extension Playlist {
    var isSingleOrEP: Bool {
        switch setType?.lowercased() {
        case "ep", "single": return true
        default: return false
        }
    }
}

extension PersonHeroMetrics {
    static let tv = PersonHeroMetrics(
        heightFraction: 0.52,
        minHeight: 520,
        maxHeight: 620,
        nameSize: 96,
        nameLines: 1,
        badgeFont: .tvCalloutEmph,
        horizontalInset: 80,
        bottomInset: 48,
        spacing: Space.base,
        avatarBlur: 80
    )
}

// MARK: - Full pages

private struct TVPersonListPage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.section) {
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(title)
                        .font(.tvTitle)
                        .foregroundStyle(Color.scTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.tvCallout)
                            .foregroundStyle(Color.scTextSecondary)
                    }
                }
                content()
            }
            .padding(.bottom, Space.section)
        }
        .scrollClipDisabled()
        .background { BrowseBackdrop().ignoresSafeArea() }
    }
}

private struct TVPersonTracksPage: View {
    @ObservedObject var viewModel: ArtistDetailViewModel
    let section: ArtistDetailSection

    private var tracks: [Track] { section == .likes ? viewModel.likedTracks : viewModel.tracks }

    private var paging: TVPaging? {
        section == .likes ? TVPaging(viewModel.likesPager) : TVPaging(viewModel.tracksPager)
    }

    var body: some View {
        if viewModel.isLoading(section), tracks.isEmpty {
            LoadingPlaceholder(.trackList(.tv), count: 8, insets: false)
                .frame(minHeight: 600, alignment: .top)
        } else if let error = viewModel.errorMessage(section), tracks.isEmpty {
            StatusPanel(
                kind: .error,
                title: "Couldn\u{2019}t Load \(section.rawValue)",
                message: error,
                actionTitle: "Try Again",
                action: { Task { await viewModel.reload(section: section) } },
                minHeight: 600
            )
        } else if tracks.isEmpty {
            StatusPanel(kind: .empty, icon: section == .likes ? "heart" : "music.note", title: "No \(section.rawValue)", minHeight: 600)
        } else {
            TVDetailTrackList(tracks: tracks, showArtist: section == .likes, paging: paging)
        }
    }
}

private struct TVPersonCollectionsPage: View {
    @ObservedObject var viewModel: ArtistDetailViewModel
    let filter: (Playlist) -> Bool

    var body: some View {
        PlaylistGridView(
            playlists: viewModel.playlists.filter(filter),
            paging: TVPaging(viewModel.playlistsPager),
            emptyTitle: "Nothing Here Yet"
        )
    }
}

private struct TVPersonRepostsPage: View {
    @ObservedObject var viewModel: ArtistDetailViewModel

    var body: some View {
        let playlists = viewModel.repostedPlaylists
        let tracks = viewModel.repostedTracks
        if viewModel.isLoading(.reposts), playlists.isEmpty, tracks.isEmpty {
            LoadingPlaceholder(.trackList(.tv), count: 8, insets: false)
                .frame(minHeight: 600, alignment: .top)
        } else if playlists.isEmpty, tracks.isEmpty {
            StatusPanel(kind: .empty, icon: "arrow.2.squarepath", title: "No Reposts", minHeight: 600)
        } else {
            VStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
                if !playlists.isEmpty {
                    PlaylistGridView(
                        playlists: playlists,
                        paging: tracks.isEmpty ? TVPaging(viewModel.repostsPager) : nil,
                        emptyTitle: ""
                    )
                }
                if !tracks.isEmpty {
                    TVDetailTrackList(tracks: tracks, paging: TVPaging(viewModel.repostsPager))
                }
            }
        }
    }
}

private struct TVPersonConnectionsPage: View {
    @ObservedObject var model: TVArtistConnectionsModel
    let name: String

    var body: some View {
        Group {
            if (model.isLoading || model.isWaitingOnTrafficStop), model.users.isEmpty {
                LoadingPlaceholder(.columns(5, spacing: SCBrowseMetrics.gutter, circular: true), insets: false)
                    .frame(minHeight: 600, alignment: .top)
            } else if let error = model.errorMessage, model.users.isEmpty {
                StatusPanel(
                    kind: .error,
                    title: "Couldn\u{2019}t Load \(model.kind.rawValue)",
                    message: error,
                    actionTitle: "Try Again",
                    action: { Task { await model.reload() } },
                    minHeight: 600
                )
            } else {
                UserGridView(
                    users: model.users,
                    columns: 5,
                    paging: model.paging,
                    emptyIcon: model.kind.systemImage,
                    emptyTitle: model.kind == .following ? "\(name) Isn\u{2019}t Following Anyone" : "No Followers Yet"
                )
            }
        }
        .task { await model.loadIfNeeded() }
    }
}

private struct TVPersonBioSheet: View {
    let name: String
    let bio: String

    private var paragraphs: [String] {
        bio.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.base) {
                Text(name)
                    .font(.tvTitle)
                    .foregroundStyle(Color.scTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.tvBody)
                        .foregroundStyle(Color.scTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusable()
                        .focusEffectDisabled()
                }
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(Space.page)
        }
        .scrollClipDisabled()
    }
}

// MARK: - Models

@MainActor
final class TVSimilarArtistsModel: ObservableObject {
    private static let lifetime: TimeInterval = 15 * 60
    private static var cache: [String: (savedAt: Date, users: [User])] = [:]
    private static var pausedUntil: Date?

    @Published private(set) var artists: [User] = []
    @Published private(set) var hasFinished = false

    let userID: String
    private var isLoading = false

    init(userID: String) {
        self.userID = userID
        if let cached = Self.cache[userID], Date().timeIntervalSince(cached.savedAt) < Self.lifetime {
            artists = cached.users
            hasFinished = true
        }
    }

    func load(seed: Track?) async {
        guard !hasFinished, !isLoading else { return }
        #if DEBUG
        if VisualFixtures.isEnabled {
            artists = VisualFixtures.artists.filter { $0.id != userID }
            hasFinished = true
            return
        }
        #endif
        if let pausedUntil = Self.pausedUntil, pausedUntil > Date() {
            hasFinished = true
            return
        }
        guard let seed, !seed.isLocal else {
            hasFinished = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await SoundCloudAPI.shared.getRelatedTracks(trackID: seed.id, limit: 30)
            var seen: Set<String> = [userID]
            let users = page.collection.map(\.user).filter { seen.insert($0.id).inserted }
            artists = Array(users.prefix(12))
            Self.cache[userID] = (Date(), artists)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if let apiError = error as? APIError, case .rateLimited(let resetAt) = apiError {
                Self.pausedUntil = resetAt ?? Date().addingTimeInterval(15 * 60)
            }
        }
        hasFinished = true
    }
}

@MainActor
final class TVArtistConnectionsModel: ObservableObject {
    private struct CacheKey: Hashable {
        let userID: String
        let kind: ArtistConnectionKind
    }

    private static let cacheLifetime: TimeInterval = 15 * 60
    private static var cache: [CacheKey: (savedAt: Date, users: [User], cursor: PagedCursor?)] = [:]

    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let pager: Paginator<User>
    private let readsLibrary: Bool

    var users: [User] { pager.items }
    var paging: TVPaging? { TVPaging(pager) }
    var isWaitingOnTrafficStop: Bool { pager.isPaused && pager.items.isEmpty }

    let userID: String
    let kind: ArtistConnectionKind
    private var hasLoaded = false
    private var pagerObservation: AnyCancellable?

    init(userID: String, kind: ArtistConnectionKind) {
        self.userID = userID
        self.kind = kind
        readsLibrary = SoundCloudAPI.credentials?.currentUser?.id == userID
        if readsLibrary {
            pager = Paginator(source: LibraryDB.userSource(kind == .following ? .followings : .followers), maxUnattendedPages: 1_000)
        } else {
            pager = Paginator(soundCloudSource: PagedSource(first: { PagedChunk(items: []) }, next: { _ in PagedChunk(items: []) }))
        }
        pagerObservation = pager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        guard !readsLibrary else { return }
        pager.onAppend = { [weak self] _ in
            Task { @MainActor in self?.persist() }
        }
        pager.setSource(PagedSource(
            first: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.fetchFirstPage()
            },
            next: { [weak self] cursor in
                guard let self else { throw CancellationError() }
                guard case .url(let url) = cursor else { return PagedChunk(items: []) }
                let page = try await SoundCloudAPI.shared.getPage(User.self, from: url)
                return PagedChunk(items: page.collection, next: page.nextHref.map(PagedCursor.url))
            }
        ))
        let key = CacheKey(userID: userID, kind: kind)
        if let cached = Self.cache[key], Date().timeIntervalSince(cached.savedAt) < Self.cacheLifetime {
            pager.prime(items: cached.users, cursor: cached.cursor)
            hasLoaded = true
        }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        guard !pager.isLoadingFirst else { return }
        #if DEBUG
        if VisualFixtures.isEnabled {
            pager.prime(items: VisualFixtures.artists.filter { $0.id != userID }, cursor: nil)
            hasLoaded = true
            persist()
            return
        }
        #endif
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        await pager.reload()

        if pager.firstError != nil {
            errorMessage = "Couldn\u{2019}t reach SoundCloud. Check your connection and try again."
        } else if pager.hasLoadedFirst {
            hasLoaded = true
            persist()
        }
    }

    private func fetchFirstPage() async throws -> PagedChunk<User> {
        let first: Page<User>
        switch kind {
        case .following:
            first = try await SoundCloudAPI.shared.getUserFollowings(userId: userID, limit: 100)
        case .followers:
            first = try await SoundCloudAPI.shared.getUserFollowers(userId: userID, limit: 100)
        }
        return PagedChunk(items: first.collection, next: first.nextHref.map(PagedCursor.url))
    }

    private func persist() {
        Self.cache[CacheKey(userID: userID, kind: kind)] = (Date(), pager.items, pager.cursor)
    }
}
