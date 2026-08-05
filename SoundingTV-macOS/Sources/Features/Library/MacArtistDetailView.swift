import SwiftUI
import AppKit

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
    var onBack: (() -> Void)?

    @StateObject private var viewModel: ArtistDetailViewModel
    @StateObject private var followingModel: MacArtistFollowingModel
    @StateObject private var followersModel: MacArtistFollowersModel
    @ObservedObject private var localActivity = MacLocalProfileActivity.shared
    @State private var pane: ArtistDetailPane = .overview
    @State private var searchText = ""
    @State private var updatingPlaylistIDs = Set<String>()
    @State private var isFollowing: Bool?
    @State private var isUpdatingFollow = false
    @State private var isConfirmingUnfollow = false
    @State private var isActivitySummaryExpanded = false

    init(
        user: User,
        initialPane: ArtistDetailPane = .overview,
        showsToolbarSearch: Bool = true,
        onBack: (() -> Void)? = nil
    ) {
        self.user = user
        self.showsToolbarSearch = showsToolbarSearch
        self.onBack = onBack
        _pane = State(initialValue: initialPane)
        _viewModel = StateObject(wrappedValue: ArtistDetailViewModel(user: user))
        _followingModel = StateObject(wrappedValue: MacArtistFollowingModel(userId: user.id))
        _followersModel = StateObject(wrappedValue: MacArtistFollowersModel(userId: user.id))
    }

    var body: some View {
        content
            .navigationTitle("@\(user.username)")
            .toolbar {
                if let onBack {
                    ToolbarItem(id: "artist-inline-back", placement: .navigation) {
                        Button(action: onBack) { Image(systemName: "chevron.left") }
                            .help("Back to All Artists")
                            .accessibilityLabel("Back to All Artists")
                    }
                }
            }
            .task { await viewModel.loadOverviewIfNeeded() }
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
        let detail = ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                    .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                    .padding(.top, SCContentStyle.mac.spaceGutter)
                    .padding(.bottom, SCContentStyle.mac.spaceRoomy)

                sectionPicker
                    .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                    .padding(.bottom, SCContentStyle.mac.spaceBase)

                sectionContent
                    .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                    .padding(.bottom, 32)
            }
        }
        .background(Color.primary.opacity(0.001))
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

    private var headerSubtitle: String {
        "\(user.formattedFollowers) followers \u{00B7} \(trackCountText) tracks"
    }

    private var trackCountText: String {
        formatCount(max(user.trackCount, viewModel.tracks.count))
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
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

    private var hero: some View {
        ZStack(alignment: .bottom) {
            ArtistHeroArtwork(
                url: heroArtworkURL,
                fallbackURL: user.largeAvatarURL ?? user.avatarURL
            )
            .frame(height: user.trackCount > 0 ? 300 : 240)

            LinearGradient(
                colors: [.clear, .black.opacity(0.30), .black.opacity(0.94)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 7) {
                ArtworkThumbnail(
                    url: user.largeAvatarURL ?? user.avatarURL,
                    identity: user.displayName,
                    size: 82,
                    cornerRadius: 41,
                    crownUser: user,
                    crownContext: user.displayName
                )
                .overlay { Circle().strokeBorder(.white.opacity(0.30), lineWidth: 1) }
                .shadow(color: .black.opacity(0.48), radius: 14, y: 7)

                Text(user.displayName)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text("@\(user.username) · \(headerSubtitle)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)

                if let description = user.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }

                artistActions.padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 9)
    }

    private var heroArtworkURL: URL? {
        viewModel.tracks.first(where: { $0.artworkURL != nil })?.artworkURL
            ?? viewModel.playlists.first(where: { $0.artworkURL != nil })?.artworkURL
            ?? user.largeAvatarURL
            ?? user.avatarURL
    }

    private var artistLinks: [ArtistExternalLink] {
        var urls: [URL] = []
        if let website = user.website { urls.append(website) }

        if let description = user.description,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(description.startIndex..<description.endIndex, in: description)
            urls.append(contentsOf: detector.matches(in: description, range: range).compactMap(\.url))
        }

        var seen = Set<String>()
        return urls.compactMap { url in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            let key = url.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard url != user.permalinkURL, seen.insert(key).inserted else { return nil }
            return ArtistExternalLink(url: url, preferredTitle: url == user.website ? user.websiteTitle : nil)
        }
    }

    private var artistActions: some View {
        HStack(spacing: SCContentStyle.mac.spaceTight) {
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
                        isFollowing == true ? "Unfollow" : "Follow",
                        systemImage: isFollowing == true ? "person.badge.minus" : "plus"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular.tint(
                        isFollowing == true
                            ? Color.primary.opacity(0.045)
                            : SCContentStyle.mac.accent.opacity(0.22)
                    ),
                    in: Capsule(style: .continuous)
                )
                .disabled(isFollowing == nil || isUpdatingFollow)
            }

            if user.trackCount > 0 || !viewModel.tracks.isEmpty {
                Button(action: playArtist) {
                    Label("Play", systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular.tint(SCContentStyle.mac.accent.opacity(0.28)),
                    in: Capsule(style: .continuous)
                )
                .disabled(playableTracks.isEmpty)
                .accessibilityLabel("Play \(user.displayName)")

                Button(action: shuffleArtist) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())
                .disabled(playableTracks.isEmpty)
                .help("Shuffle \(user.displayName)")
                .accessibilityLabel("Shuffle \(user.displayName)")
            }

            Menu {
                if !artistLinks.isEmpty {
                    Menu("Artist Links", systemImage: "link") {
                        ForEach(artistLinks) { link in
                            Link(destination: link.url) {
                                Label(link.title, systemImage: link.symbol)
                            }
                        }
                    }
                    Divider()
                }

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

                ShareLink(item: user.permalinkURL, subject: Text(user.displayName)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Circle())
            .menuIndicator(.hidden)
            .help("More")
            .accessibilityLabel("More actions for \(user.displayName)")
        }
    }

    private var playableTracks: [Track] {
        viewModel.tracks.filter { $0.streamURL != nil }
    }

    private func playArtist() {
        guard let first = playableTracks.first else { return }
        Task { await PlayerService.shared.play(first, in: viewModel.tracks) }
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
        guard let first = playableTracks.randomElement() else { return }
        PlayerService.shared.isShuffleEnabled = true
        Task { await PlayerService.shared.play(first, in: viewModel.tracks) }
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(ArtistDetailPane.allCases, id: \.self) { candidate in
                Button {
                    pane = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 12, weight: pane == candidate ? .semibold : .medium))
                        .foregroundStyle(pane == candidate ? Color.scAccentOn : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            pane == candidate ? SCContentStyle.mac.accent.opacity(0.72) : .clear,
                            in: Capsule(style: .continuous)
                        )
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(maxWidth: 860)
        .glassEffect(.regular, in: Capsule(style: .continuous))
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
                    trackTable(filteredTracks, onNearEnd: { Task { await viewModel.loadMore(section: .tracks) } })

                    if !filteredAlbums.isEmpty {
                        collectionSection(title: "Albums", subtitle: nil) {
                            playlistGrid(
                                filteredAlbums,
                                onNearEnd: {
                                    guard filteredSets.isEmpty else { return }
                                    Task { await viewModel.loadMore(section: .playlists) }
                                }
                            )
                        }
                    }
                }
            }
        case .playlists:
            sectionBody(isEmpty: viewModel.playlists.isEmpty, icon: "music.note.list", message: "\(user.displayName) hasn\u{2019}t published any playlists.") {
                VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                    if !publicPlaylists.isEmpty {
                        collectionSection(title: "Public", subtitle: "Visible to everyone") {
                            playlistGrid(publicPlaylists, onNearEnd: loadMorePlaylists)
                        }
                    }
                    if !privatePlaylists.isEmpty {
                        collectionSection(title: "Private", subtitle: "Visible only to the owner and people with access") {
                            playlistGrid(privatePlaylists, onNearEnd: loadMorePlaylists)
                        }
                    }
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
                            playlistGrid(
                                filteredRepostedPlaylists,
                                onNearEnd: {
                                    guard filteredRepostedTracks.isEmpty else { return }
                                    Task { await viewModel.loadMore(section: .reposts) }
                                }
                            )
                        }
                    }
                    if !filteredRepostedTracks.isEmpty {
                        collectionSection(title: "Reposted Songs", subtitle: nil) {
                            trackTable(filteredRepostedTracks, onNearEnd: { Task { await viewModel.loadMore(section: .reposts) } })
                        }
                    }
                }
            }
        case .likes:
            sectionBody(isEmpty: viewModel.likedTracks.isEmpty, icon: "heart", message: "\(user.displayName) hasn\u{2019}t liked any tracks publicly.") {
                trackTable(filteredLikedTracks, onNearEnd: { Task { await viewModel.loadMore(section: .likes) } })
            }
        case .following:
            followingBody
        case .followers:
            followersBody
        }
    }

    private func loadMorePlaylists() {
        Task { await viewModel.loadMore(section: .playlists) }
    }

    @ViewBuilder
    private var overviewBody: some View {
        if viewModel.isLoading(.tracks), viewModel.tracks.isEmpty {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 50)
        } else if viewModel.tracks.isEmpty && viewModel.playlists.isEmpty {
            SCEmptyState(
                icon: "person.crop.circle",
                title: user.displayName,
                message: "This profile has no public music yet.",
                style: .mac
            )
            .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: SCContentStyle.mac.spaceRoomy) {
                        latestReleaseSection.frame(width: 260)
                        recentTracksSection.frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                        latestReleaseSection
                        recentTracksSection
                    }
                }

                if !filteredAlbums.isEmpty {
                    collectionSection(title: "Albums", subtitle: nil) {
                        playlistGrid(Array(filteredAlbums.prefix(8)))
                    }
                } else if !filteredSets.isEmpty {
                    collectionSection(title: "Featured sets", subtitle: nil) {
                        playlistGrid(Array(filteredSets.prefix(8)))
                    }
                }

                DisclosureGroup("Activity summary", isExpanded: $isActivitySummaryExpanded) {
                    HStack(spacing: 8) {
                        activityMetric("Uploads", count: viewModel.tracks.count, icon: "arrow.up.circle")
                        activityMetric("Reposts", count: viewModel.repostItems.count, icon: "arrow.2.squarepath")
                        activityMetric("Likes", count: viewModel.likeItems.count, icon: "heart")
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .onChange(of: isActivitySummaryExpanded) { _, expanded in
                    guard expanded else { return }
                    Task { await viewModel.loadActivityIfNeeded() }
                }
            }
        }
    }

    @ViewBuilder
    private var latestReleaseSection: some View {
        if let latest = filteredTracks.first {
            VStack(alignment: .leading, spacing: 10) {
                Text("Latest release")
                    .font(.system(size: 18, weight: .bold))

                Button {
                    Task { await PlayerService.shared.play(latest, in: viewModel.tracks) }
                } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        ArtworkThumbnail(
                            url: latest.artworkURL,
                            identity: latest.title,
                            size: 220,
                            cornerRadius: 14,
                            crownUser: latest.user,
                            crownContext: latest.title
                        )
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .glassEffect(.regular.tint(.orange.opacity(0.35)), in: Circle())
                                .padding(10)
                        }

                        Text(latest.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(latest.createdAt, style: .date)
                            if let genre = latest.genre, !genre.isEmpty {
                                Text("·")
                                Text(genre)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .macTrackContextMenu(track: latest)
            }
        }
    }

    private var recentTracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent tracks")
                .font(.system(size: 18, weight: .bold))
            MacCollectionTrackTable(
                tracks: Array(filteredTracks.prefix(6)),
                onPlay: { track in
                    Task { await PlayerService.shared.play(track, in: viewModel.tracks) }
                }
            )
            .frame(minHeight: CGFloat(min(filteredTracks.count, 6)) * 50 + 31)
        }
    }

    @ViewBuilder
    private var activityBody: some View {
        if viewModel.isLoading(.tracks) || viewModel.isLoading(.reposts) || viewModel.isLoading(.likes), activityItems.isEmpty {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 50)
        } else if activityItems.isEmpty {
            SCEmptyState(
                icon: "clock.arrow.circlepath",
                title: "No Activity Yet",
                message: "Uploads, reposts and likes from \(user.displayName) will appear here.",
                style: .mac
            )
            .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    activityMetric("Uploads", count: viewModel.tracks.count, icon: "arrow.up.circle")
                    activityMetric("Reposts", count: viewModel.repostItems.count, icon: "arrow.2.squarepath")
                    activityMetric("Likes", count: viewModel.likeItems.count, icon: "heart")
                    Spacer(minLength: 0)
                }

                ForEach(activityGroups) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        LazyVStack(spacing: 4) {
                            ForEach(group.items) { item in
                                profileActivityRow(item)
                                    .onAppear {
                                        guard activityItems.isNearEnd(item, lead: 10) else { return }
                                        Task {
                                            async let tracks: Void = viewModel.loadMore(section: .tracks)
                                            async let reposts: Void = viewModel.loadMore(section: .reposts)
                                            async let likes: Void = viewModel.loadMore(section: .likes)
                                            _ = await (tracks, reposts, likes)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }
    }

    private func activityMetric(_ title: String, count: Int, icon: String) -> some View {
        Label("\(count) \(title.lowercased())", systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .glassEffect(.regular.tint(.orange.opacity(0.035)), in: Capsule())
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
                size: 42,
                cornerRadius: item.isPlaylist ? 7 : 6
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.action)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(item.date, style: .relative)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        if let track = item.track {
            Button {
                Task { await PlayerService.shared.play(track, in: activityItems.compactMap(\.track)) }
            } label: { row }
            .buttonStyle(.plain)
            .macTrackContextMenu(track: track)
        } else if let playlist = item.playlist {
            NavigationLink(value: playlist) { row }
                .buttonStyle(.plain)
        } else if let person = item.person {
            NavigationLink(value: person) { row }
                .buttonStyle(.plain)
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
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            content()
        }
    }

    @ViewBuilder
    private var followingBody: some View {
        if followingModel.isLoading, followingModel.users.isEmpty {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 50)
        } else if let error = followingModel.errorMessage, followingModel.users.isEmpty {
            SCEmptyState(
                kind: .error,
                title: "Couldn\u{2019}t Load",
                message: error,
                actionTitle: "Try Again",
                action: { Task { await followingModel.loadIfNeeded(force: true) } },
                style: .mac
            )
            .padding(.vertical, 40)
        } else if followingModel.users.isEmpty {
            SCEmptyState(
                icon: "person.2",
                title: ArtistDetailPane.following.rawValue,
                message: "\(user.displayName) isn\u{2019}t following anyone.",
                style: .mac
            )
            .padding(.vertical, 40)
        } else {
            peopleGrid(filteredFollowing, onNearEnd: followingModel.loadMore)
        }
    }

    @ViewBuilder
    private var followersBody: some View {
        if followersModel.isLoading, followersModel.users.isEmpty {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 50)
        } else if let error = followersModel.errorMessage, followersModel.users.isEmpty {
            SCEmptyState(
                kind: .error,
                title: "Couldn\u{2019}t Load",
                message: error,
                actionTitle: "Try Again",
                action: { Task { await followersModel.loadIfNeeded(force: true) } },
                style: .mac
            )
            .padding(.vertical, 40)
        } else if followersModel.users.isEmpty {
            SCEmptyState(
                icon: "person.2",
                title: ArtistDetailPane.followers.rawValue,
                message: "Nobody follows \(user.displayName) yet.",
                style: .mac
            )
            .padding(.vertical, 40)
        } else {
            peopleGrid(filteredFollowers, onNearEnd: followersModel.loadMore)
        }
    }

    private func peopleGrid(_ people: [User], onNearEnd: @escaping () -> Void) -> some View {
        let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 20)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(people) { person in
                NavigationLink(value: person) {
                    SCArtworkResolver(url: person.largeAvatarURL ?? person.avatarURL) { image in
                        SCArtistCard(
                            name: person.displayName,
                            avatarImage: image,
                            identity: person.displayName,
                            crownUser: person,
                            crownContext: person.displayName,
                            style: .mac
                        )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .macHoverLift()
                .contextMenu { MacArtistContextMenu(artist: person) }
                .onAppear {
                    guard trimmedSearch.isEmpty, people.isNearEnd(person, lead: 10) else { return }
                    onNearEnd()
                }
            }
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
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 50)
        } else if let error = viewModel.errorMessage(viewModel.selectedSection), isEmpty {
            SCEmptyState(
                kind: .error,
                title: "Couldn\u{2019}t Load",
                message: error,
                actionTitle: "Try Again",
                action: { Task { await viewModel.reload(section: viewModel.selectedSection) } },
                style: .mac
            )
            .padding(.vertical, 40)
        } else if isEmpty {
            SCEmptyState(
                icon: icon,
                title: viewModel.selectedSection.rawValue,
                message: message,
                style: .mac
            )
            .padding(.vertical, 40)
        } else {
            content()
        }
    }

    private func trackTable(_ tracks: [Track], onNearEnd: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            MacCollectionTrackTable(
                tracks: tracks,
                onPlay: { track in Task { await PlayerService.shared.play(track, in: tracks) } }
            )
            .frame(minHeight: CGFloat(tracks.count) * 50 + 31)

            if trimmedSearch.isEmpty {
                Color.clear.frame(height: 1).onAppear(perform: onNearEnd)
            }
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
                .contextMenu {
                    MacPlaylistContextMenu(
                        playlist: playlist,
                        canChangePrivacy: credentials.currentUser?.id == playlist.user.id,
                        isUpdatingPrivacy: updatingPlaylistIDs.contains(playlist.id),
                        onTogglePrivacy: { togglePlaylistPrivacy(playlist) }
                    )
                }
                .onAppear {
                    guard let onNearEnd, trimmedSearch.isEmpty, playlists.isNearEnd(playlist, lead: 8) else { return }
                    onNearEnd()
                }
            }
        }
    }

    @ViewBuilder
    private func playlistPrivacyBadge(_ playlist: Playlist) -> some View {
        if playlist.sharing == "private" {
            Label("Private", systemImage: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .glassEffect(
                    .regular.tint(Color.black.opacity(0.34)),
                    in: Capsule(style: .continuous)
                )
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
    private var filteredAlbums: [Playlist] { filteredPlaylists.filter(\.isAlbum) }
    private var filteredSets: [Playlist] { filteredPlaylists.filter { !$0.isAlbum } }
    private var filteredRepostedPlaylists: [Playlist] { filterPlaylists(viewModel.repostedPlaylists) }

    private var filteredFollowing: [User] {
        guard !trimmedSearch.isEmpty else { return followingModel.users }
        return followingModel.users.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmedSearch) || $0.username.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    private var filteredFollowers: [User] {
        guard !trimmedSearch.isEmpty else { return followersModel.users }
        return followersModel.users.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmedSearch) || $0.username.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

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

private struct ArtistExternalLink: Identifiable {
    let url: URL
    let preferredTitle: String?

    var id: String { url.absoluteString }

    var title: String {
        if let preferredTitle, !preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preferredTitle
        }
        let host = url.host?.lowercased() ?? ""
        if host.contains("instagram.com") { return "Instagram" }
        if host.contains("twitter.com") || host == "x.com" || host.hasSuffix(".x.com") { return "X / Twitter" }
        if host.contains("facebook.com") { return "Facebook" }
        if host.contains("tiktok.com") { return "TikTok" }
        if host.contains("youtube.com") || host.contains("youtu.be") { return "YouTube" }
        if host.contains("bandcamp.com") { return "Bandcamp" }
        return url.host?.replacingOccurrences(of: "www.", with: "") ?? "Website"
    }

    var symbol: String {
        let host = url.host?.lowercased() ?? ""
        return host.contains("youtube") || host.contains("youtu.be") ? "play.rectangle" : "globe"
    }
}

private struct ArtistHeroArtwork: View {
    let url: URL?
    let fallbackURL: URL?
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color.orange.opacity(0.34), Color.black, Color(red: 0.10, green: 0.04, blue: 0.02)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay {
                            Color.orange.opacity(0.055).blendMode(.plusLighter)
                        }
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 100, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.10))
                }
            }
        }
        .task(id: url) {
            image = nil
            if let url, let resolved = await ArtworkCache.shared.image(for: url, variant: .standard) {
                image = resolved
            } else if let fallbackURL {
                image = await ArtworkCache.shared.image(for: fallbackURL, variant: .standard)
            }
        }
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

    private init() {
        events = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []
    }

    func record(user: User, followed: Bool) {
        events.insert(Event(id: UUID().uuidString, date: Date(), user: user, followed: followed), at: 0)
        events = Array(events.prefix(200))
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// The artist hero needs secondary transport actions to read as quiet tools,
/// not as competing rectangular calls-to-action.  This intentionally keeps a
/// full 28-point hit target while using the compact circular affordance that
/// macOS Music uses around its Play control.
private struct ArtistSecondaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(
                Circle()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.075))
            )
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct MacArtistsPane: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var model: MacArtistsPaneModel
    @State private var searchText = ""
    @State private var selectedArtistID: String? = Self.allArtistsID
    @FocusState private var filterFieldFocused: Bool

    private static let allArtistsID = "__all_artists__"

    init(model: MacArtistsPaneModel) {
        self.model = model
    }

    var body: some View {
        Group {
            if credentials.isSignedOut {
                MacSignedOutEmptyState(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "Artists Need an Account",
                    message: "Sign in to see the artists you follow. Home and Search work without an account.",
                    browsableRoute: .home
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isLoading && model.artists.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.artists.isEmpty {
                SCEmptyState(
                    kind: .error,
                    title: "Couldn\u{2019}t Load Artists",
                    message: error,
                    actionTitle: "Try Again",
                    action: {
                        let credentials = credentials
                        Task { await model.load(credentials: credentials, force: true) }
                    },
                    style: .mac
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if artistAccounts.isEmpty, !model.isLoading {
                SCEmptyState(
                    icon: "music.microphone",
                    title: "No Artists Yet",
                    message: "Follow artists on SoundCloud and they\u{2019}ll appear here.",
                    actionTitle: "Find Artists",
                    action: { MacRootSelection.shared.request(.search) },
                    style: .mac
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                artistSplitView
            }
        }
        .navigationTitle("Artists")
        .navigationSubtitle(
            selectedArtistID == Self.allArtistsID
                ? "You follow \(artistAccounts.count) artists"
                : ""
        )
        .background {
            Group {
                Button("") { filterFieldFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { filterFieldFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
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
    }

    private var artistSplitView: some View {
        HSplitView {
            artistSourceList
                .frame(width: 280)

            Group {
                if selectedArtistID == Self.allArtistsID {
                    allArtistsGrid
                } else if let selectedArtist {
                    MacArtistDetailView(
                        user: selectedArtist,
                        showsToolbarSearch: false,
                        onBack: { selectedArtistID = Self.allArtistsID }
                    )
                        .id(selectedArtist.id)
                } else {
                    ContentUnavailableView(
                        "Choose an Artist",
                        systemImage: "music.microphone",
                        description: Text("Select an artist to see their music and activity.")
                    )
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.001))
        }
    }

    private var artistSourceList: some View {
        MacVisualEffect(role: .sidebar) {
            artistSourceListContent
        }
    }

    private var artistSourceListContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter Artists", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($filterFieldFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .glassEffect(
                .regular.tint(.orange.opacity(filterFieldFocused ? 0.07 : 0.02)),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.orange.opacity(filterFieldFocused ? 0.45 : 0.08), lineWidth: 0.8)
            }
            .padding(.horizontal, SCContentStyle.mac.spaceBase)
            .padding(.top, SCContentStyle.mac.spaceBase)
            .padding(.bottom, SCContentStyle.mac.spaceTight)

            if filteredArtists.isEmpty {
                SCEmptyState(
                    icon: "magnifyingglass",
                    title: "No Matching Artists",
                    message: "Try a different name.",
                    style: .mac
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(SCContentStyle.mac.spaceBase)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        allArtistsRow

                        ForEach(filteredArtists) { artist in
                            Button {
                                selectedArtistID = artist.id
                            } label: {
                                ArtistSourceRow(
                                    artist: artist,
                                    isSelected: selectedArtistID == artist.id
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contextMenu { MacArtistContextMenu(artist: artist) }
                        .onAppear {
                            guard searchText.isEmpty, filteredArtists.isNearEnd(artist, lead: 12) else { return }
                            model.loadMore()
                        }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SCContentStyle.mac.spaceBase)
                    .padding(.vertical, SCContentStyle.mac.spaceTight)
                }
                .background(Color.clear)
            }

            if model.isLoading, !model.artists.isEmpty {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Loading more artists…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, SCContentStyle.mac.spaceBase)
                .padding(.vertical, SCContentStyle.mac.spaceTight)
            }
        }
    }

    private var allArtistsRow: some View {
        Button {
            selectedArtistID = Self.allArtistsID
        } label: {
            HStack(spacing: SCContentStyle.mac.spaceSnug) {
                Image(systemName: "music.microphone")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        SCContentStyle.mac.accent.opacity(0.18),
                        in: Circle()
                    )

                Text("All Artists")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, SCContentStyle.mac.spaceSnug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectedArtistID == Self.allArtistsID
                    ? SCContentStyle.mac.accent.opacity(0.24)
                    : Color.white.opacity(0),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var allArtistsGrid: some View {
        ScrollView {
            if filteredArtists.isEmpty {
                SCEmptyState(
                    icon: "person.2",
                    title: "No Artists",
                    message: "Follow artists on SoundCloud and they’ll appear here.",
                    style: .mac
                )
                .padding(.vertical, 40)
            } else {
                peopleGrid(filteredArtists, onNearEnd: model.loadMore)
                    .padding(SCContentStyle.mac.spaceGutter)
            }
        }
    }

    private func peopleGrid(_ people: [User], onNearEnd: @escaping () -> Void) -> some View {
        let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 20)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(people) { person in
                NavigationLink(value: person) {
                    SCArtworkResolver(url: person.largeAvatarURL ?? person.avatarURL) { image in
                        SCArtistCard(
                            name: person.displayName,
                            avatarImage: image,
                            identity: person.displayName,
                            crownUser: person,
                            crownContext: person.displayName,
                            style: .mac
                        )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .macHoverLift()
                .contextMenu { MacArtistContextMenu(artist: person) }
                .onAppear {
                    guard searchText.isEmpty, people.isNearEnd(person, lead: 10) else { return }
                    onNearEnd()
                }
            }
        }
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
        model.artists.filter { $0.trackCount > 0 }
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
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: SCContentStyle.mac.spaceSnug) {
            ArtworkThumbnail(
                url: artist.avatarURL,
                identity: artist.displayName,
                size: 36,
                cornerRadius: 18,
                crownUser: artist,
                crownContext: artist.displayName
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(artist.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(artist.formattedFollowers) followers")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, SCContentStyle.mac.spaceSnug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? SCContentStyle.mac.accent.opacity(0.24)
                : Color.white.opacity(isHovered ? 0.055 : 0),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

@MainActor
final class MacArtistsPaneModel: ObservableObject {
    @Published private(set) var artists: [User] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var page: Page<User>?
    private var hasLoaded = false
    private let cache = LibraryCache.shared

    func load(credentials: SoundCloudCredentialSource, force: Bool = false) async {
        if hasLoaded, !force { return }
        guard !credentials.isSignedOut else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let cachedRows = await cache.loadSection("Artists")
        let decoder = LikesSyncEngine.makeDecoder()
        let cached = cachedRows.compactMap { try? decoder.decode(User.self, from: $0.payload) }
        if !cached.isEmpty { artists = cached }
        guard let user = await credentials.waitForCurrentUser() else { return }
        do {
            let first = try await SoundCloudAPI.shared.getUserFollowings(userId: user.id, limit: 100)
            page = first
            // The server's first page is fresh, while the cache can contain
            // older pages discovered by the background metadata walk.
            artists = (first.collection + artists).deduplicatedByID()
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() {
        guard let page, page.nextHref != nil, !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            defer { isLoading = false }
            do {
                let next = try await SoundCloudAPI.shared.getNextPage(page)
                self.page = next
                let known = Set(artists.map(\.id))
                artists += next.collection.filter { !known.contains($0.id) }
            } catch {
            }
        }
    }
}

@MainActor
final class MacArtistFollowingModel: ObservableObject {
    private static let cacheLifetime: TimeInterval = 15 * 60
    private static var cache: [String: (savedAt: Date, users: [User])] = [:]
    @Published private(set) var users: [User] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let userId: String
    private var page: Page<User>?
    private var hasLoaded = false

    init(userId: String) {
        self.userId = userId
        if let cached = Self.cache[userId], Date().timeIntervalSince(cached.savedAt) < Self.cacheLifetime {
            users = cached.users
            hasLoaded = true
        }
    }

    func loadIfNeeded(force: Bool = false) async {
        if hasLoaded, !force { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let first = try await SoundCloudAPI.shared.getUserFollowings(userId: userId, limit: 100)
            page = first
            users = first.collection
            hasLoaded = true
            Self.cache[userId] = (Date(), users)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() {
        guard let page, page.nextHref != nil, !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            defer { isLoading = false }
            do {
                let next = try await SoundCloudAPI.shared.getNextPage(page)
                self.page = next
                users.appendUnique(contentsOf: next.collection)
                Self.cache[userId] = (Date(), users)
            } catch {
            }
        }
    }
}

@MainActor
final class MacArtistFollowersModel: ObservableObject {
    private static let cacheLifetime: TimeInterval = 15 * 60
    private static var cache: [String: (savedAt: Date, users: [User])] = [:]
    @Published private(set) var users: [User] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let userId: String
    private var page: Page<User>?
    private var hasLoaded = false

    init(userId: String) {
        self.userId = userId
        if let cached = Self.cache[userId], Date().timeIntervalSince(cached.savedAt) < Self.cacheLifetime {
            users = cached.users
            hasLoaded = true
        }
    }

    func loadIfNeeded(force: Bool = false) async {
        if hasLoaded, !force { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let first = try await SoundCloudAPI.shared.getUserFollowers(userId: userId, limit: 100)
            page = first
            users = first.collection
            hasLoaded = true
            Self.cache[userId] = (Date(), users)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() {
        guard let page, page.nextHref != nil, !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            defer { isLoading = false }
            do {
                let next = try await SoundCloudAPI.shared.getNextPage(page)
                self.page = next
                users.appendUnique(contentsOf: next.collection)
                Self.cache[userId] = (Date(), users)
            } catch {
            }
        }
    }
}
