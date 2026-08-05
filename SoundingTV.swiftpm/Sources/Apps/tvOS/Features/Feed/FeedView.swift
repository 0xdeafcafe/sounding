import SwiftUI

struct FeedView: View {
    @StateObject private var viewModel = FeedViewModel()
    @EnvironmentObject var playerService: PlayerService
    @EnvironmentObject var authService: AuthenticationService
    @FocusState private var focus: BrowseFocus?

    private static let heroCount = 2

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                content
                    .padding(.top, SCBrowseMetrics.contentTopInset)
                    .padding(.bottom, SCBrowseMetrics.shelfGap)
            }
            .background { BrowseBackdrop() }
            .scrollClipDisabled()
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .defaultFocus($focus, .firstCard)
        .onAppear { DispatchQueue.main.async { focus = .firstCard } }
        .task { await loadFeedIfNeeded() }
        .onChange(of: authService.isAuthenticated) { _, isAuthed in
            if isAuthed {
                Task { await loadFeed() }
            } else {
                viewModel.reset()
            }
        }
        .onChange(of: viewModel.items.first?.id) { _, newID in
            if newID != nil, focus == nil {
                focus = .firstCard
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let forced = Self.debugForcedState {
            switch forced {
            case .loading:
                StatusPanel(kind: .loading, title: "Loading your stream…", minHeight: 700)
            case .error:
                StatusPanel(
                    kind: .error, title: "Couldn't load your stream",
                    message: "Couldn't reach SoundCloud. Check this Apple TV's network connection.",
                    actionTitle: "Try Again", action: {}, minHeight: 700
                )
            case .empty:
                StatusPanel(
                    kind: .empty, icon: "dot.radiowaves.up.forward", title: "Nothing in your stream yet",
                    message: "Follow some artists on SoundCloud and their uploads, playlists and reposts will show up here.",
                    actionTitle: "Refresh", action: {}, minHeight: 700
                )
            }
        } else if viewModel.isLoading, viewModel.items.isEmpty {
            StatusPanel(kind: .loading, title: "Loading your stream…", minHeight: 700)
        } else if viewModel.error != nil, viewModel.items.isEmpty {
            StatusPanel(
                kind: .error,
                title: "Couldn't load your stream",
                message: "Couldn't reach SoundCloud. Check this Apple TV's network connection.",
                actionTitle: "Try Again",
                action: { Task { await loadFeed() } },
                minHeight: 700
            )
        } else if !authService.isAuthenticated {
            StatusPanel(
                kind: .empty,
                icon: "qrcode",
                title: "Sign in to see your stream",
                message: "Scan the code with your iPhone to sign in to SoundCloud.",
                actionTitle: "Sign In",
                action: { NotificationCenter.default.post(name: .sessionExpired, object: nil) },
                minHeight: 700
            )
        } else if viewModel.items.isEmpty {
            StatusPanel(
                kind: .empty,
                icon: "dot.radiowaves.up.forward",
                title: "Nothing in your stream yet",
                message: "Follow some artists on SoundCloud and their uploads, playlists and reposts will show up here.",
                actionTitle: "Refresh",
                action: { Task { await loadFeed() } },
                minHeight: 700
            )
        } else {
            let heroes = Array(viewModel.items.prefix(Self.heroCount))
            let rest = Array(viewModel.items.dropFirst(heroes.count))
            let tracks = rest.filter { $0.track != nil }
            let collections = rest.filter { $0.playlist != nil }

            VStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
                heroShelf(heroes)
                    .focusSection()

                if !tracks.isEmpty {
                    FeedTrackShelf(activities: tracks, loadMore: loadMoreIfNeeded)
                }

                if !collections.isEmpty {
                    FeedCollectionShelf(activities: collections, loadMore: loadMoreIfNeeded)
                }

                if viewModel.isLoadingMore {
                    LoadingMoreRow()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func heroShelf(_ activities: [FeedActivity]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: SCBrowseMetrics.gutter) {
                ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                    heroCard(activity, index: index)
                }
            }
        }
        .scrollClipDisabled()
        .safeAreaPadding(.horizontal, SCBrowseMetrics.pageInset)
        .buttonStyle(SCCardButtonStyle(cornerRadius: SCBrowseMetrics.heroCorner))
        .focusEffectDisabled()
        .prefetchArtwork(activities.compactMap { $0.artwork.url }, variant: .hero)
    }

    @ViewBuilder
    private func heroCard(_ activity: FeedActivity, index: Int) -> some View {
        let card = FeedActivityCard(activity: activity, play: { play(activity) })
            .accessibilityIdentifier(index == 0 ? "feed.hero" : "feed.hero.\(index)")
            .onAppear {
                guard viewModel.items.isNearEnd(activity, lead: 6) else { return }
                Task { await viewModel.loadMore() }
            }

        if index == 0 {
            card.focused($focus, equals: .firstCard)
        } else {
            card
        }
    }

    private func loadMoreIfNeeded(_ activity: FeedActivity) {
        guard viewModel.items.isNearEnd(activity, lead: 6) else { return }
        Task { await viewModel.loadMore() }
    }

    private func play(_ activity: FeedActivity) {
        guard let track = activity.track, track.streamURL != nil else { return }
        let context = viewModel.items.compactMap(\.track).filter { $0.streamURL != nil }
        Task { await playerService.play(track, in: context) }
    }

    private func loadFeedIfNeeded() async {
        guard authService.isAuthenticated else { return }
        await viewModel.loadContentIfNeeded()
    }

    private func loadFeed() async {
        guard authService.isAuthenticated else { return }
        await viewModel.loadContent()
    }

    private func refreshFeedIfStale() async {
        guard authService.isAuthenticated else { return }
        await viewModel.refreshIfStale()
    }

    private enum DebugForcedFeedState { case loading, error, empty }

    private static var debugForcedState: DebugForcedFeedState? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_FEED_STATE"] {
        case "loading": return .loading
        case "error":   return .error
        case "empty":   return .empty
        default:        return nil
        }
        #else
        return nil
        #endif
    }
}

private extension FeedActivity {
    var kicker: String {
        switch kind {
        case .track:    return "New upload"
        case .playlist: return "New playlist"
        case .trackRepost, .playlistRepost:
            return "Reposted by \(actor.displayName)"
        }
    }

    var displayTitle: String { track?.title ?? playlist?.title ?? "" }

    var displaySubtitle: String {
        if let playlist {
            let count = playlist.totalTrackCount
            return "\(count == 1 ? "1 track" : "\(count) tracks") \u{00B7} \(playlist.user.displayName)"
        }
        if let track {
            return "\(track.user.displayName) \u{00B7} \(track.formattedDuration)"
        }
        return ""
    }

    var rowSubtitle: String {
        let who = playlist.map { "\($0.totalTrackCount == 1 ? "1 track" : "\($0.totalTrackCount) tracks") \u{00B7} \($0.user.displayName)" }
            ?? (track?.user.displayName ?? "")
        return isRepost ? "\(who) \u{00B7} via \(actor.displayName)" : who
    }

    var isPlayable: Bool { track?.streamURL != nil }

    var isActionable: Bool { isPlayable || playlist != nil }

    var artwork: (url: URL?, mosaic: [URL]) {
        if let track { return (track.artworkURL, []) }
        if let playlist {
            let collection = HomeCollection(playlist: playlist, kicker: "")
            return (collection.artworkURL, collection.mosaicURLs)
        }
        return (nil, [])
    }
}

private struct FeedActivityCard: View {
    let activity: FeedActivity
    let play: () -> Void

    var body: some View {
        Group {
            if let playlist = activity.playlist {
                NavigationLink {
                    PlaylistDetailView(playlist: playlist)
                } label: {
                    label
                }
            } else {
                Button(action: play) { label }
            }
        }
    }

    private var label: some View {
        SCCollectionArtworkResolver(
            artworkURL: activity.artwork.url,
            trackArtworkURLs: activity.artwork.mosaic,
            variant: .hero
        ) { image in
            SCHeroCard(
                eyebrow: activity.kicker,
                title: activity.displayTitle,
                description: activity.displaySubtitle,
                backgroundImage: image,
                style: SCContentStyle.tv,
                isAvailable: activity.isActionable,
                cornerRadius: SCBrowseMetrics.heroCorner,
                crownUser: activity.track?.user ?? activity.playlist?.user,
                crownContext: activity.displayTitle
            )
            .frame(
                width: SCBrowseMetrics.heroWidth,
                height: SCBrowseMetrics.heroHeight
            )
        }
    }
}

private struct FeedTrackShelf: View {
    let activities: [FeedActivity]
    let loadMore: (FeedActivity) -> Void

    @EnvironmentObject private var playerService: PlayerService

    var body: some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            SCSectionHeader(title: "Latest Tracks", style: SCBrowseMetrics.header)

            ScrollView(.horizontal) {
                LazyHStack(spacing: SCBrowseMetrics.gutter) {
                    ForEach(activities) { activity in
                        if let track = activity.track {
                            Button {
                                let queue = activities.compactMap(\.track).filter { $0.streamURL != nil }
                                Task { await playerService.play(track, in: queue) }
                            } label: {
                                FeedTrackLockup(activity: activity)
                            }
                            .disabled(track.streamURL == nil)
                            .onAppear { loadMore(activity) }
                        }
                    }
                }
            }
            .scrollClipDisabled()
            .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.card, sizeClass: .card))
            .focusEffectDisabled()
            .prefetchArtwork(activities.compactMap { $0.artwork.url })
        }
    }
}

private struct FeedTrackLockup: View {
    let activity: FeedActivity

    private var label: some View {
        SCCollectionArtworkResolver(
            artworkURL: activity.artwork.url,
            trackArtworkURLs: activity.artwork.mosaic
        ) { image in
            SCTrackRow(
                title: activity.displayTitle,
                subtitle: activity.rowSubtitle,
                eyebrow: activity.kicker,
                eyebrowIcon: activity.isRepost ? "arrow.2.squarepath" : nil,
                artworkImage: image,
                isAvailable: activity.isActionable,
                crownUser: activity.track?.user ?? activity.playlist?.user,
                crownContext: activity.displayTitle,
                style: SCBrowseMetrics.row
            ) {
                trailing
            }
        }
        .padding(.horizontal, Space.snug)
        .frame(width: 570, alignment: .leading)
        .background(
            Color.white.opacity(0.075),
            in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
        )
    }

    var body: some View { label }

    @ViewBuilder
    private var trailing: some View {
        if let track = activity.track {
            if track.streamURL != nil {
                Text(track.formattedDuration)
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextTertiary)
                    .monospacedDigit()
            } else {
                Text("Unavailable")
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextTertiary)
            }
        } else if activity.playlist != nil {
            Image(systemName: "chevron.right")
                .font(.tvCaption)
                .foregroundStyle(Color.scTextTertiary)
        }
    }
}

private struct FeedCollectionShelf: View {
    let activities: [FeedActivity]
    let loadMore: (FeedActivity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            SCSectionHeader(title: "Albums & Playlists", style: SCBrowseMetrics.header)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: SCBrowseMetrics.gutter) {
                    ForEach(activities) { activity in
                        if let playlist = activity.playlist {
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                SCCollectionArtworkResolver(
                                    artworkURL: activity.artwork.url,
                                    trackArtworkURLs: activity.artwork.mosaic
                                ) { image in
                                    SCMediaCard(
                                        title: activity.displayTitle,
                                        subtitle: activity.rowSubtitle,
                                        artworkImage: image,
                                        crownUser: playlist.user,
                                        crownContext: playlist.title,
                                        style: SCBrowseMetrics.tile
                                    )
                                }
                                .frame(width: SCBrowseMetrics.tileEdge)
                            }
                            .onAppear { loadMore(activity) }
                        }
                    }
                }
            }
            .scrollClipDisabled()
            .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
            .focusEffectDisabled()
            .prefetchArtwork(activities.compactMap { $0.artwork.url })
        }
    }
}
