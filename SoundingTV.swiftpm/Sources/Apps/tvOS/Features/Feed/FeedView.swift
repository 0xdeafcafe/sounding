import SwiftUI

struct FeedView: View {
    @ObservedObject private var viewModel = HomeStore.shared.following
    @EnvironmentObject var playerService: PlayerService
    @EnvironmentObject var authService: AuthenticationService
    @FocusState private var focus: BrowseFocus?
    @FocusState private var statusFocused: Bool

    private static let heroCount = 6

    private let embedsNavigationStack: Bool

    init(embedsNavigationStack: Bool = true) {
        self.embedsNavigationStack = embedsNavigationStack
    }

    var body: some View {
        container
        .defaultFocus($focus, .firstCard)
        .onAppear { DispatchQueue.main.async { focus = .firstCard } }
        .task { await loadFeedIfNeeded() }
        .onChange(of: authService.isAuthenticated) { _, isAuthed in
            if isAuthed {
                Task { await loadFeedIfNeeded() }
            } else if SoundCloudCredentialSource.shared.isSignedOut {
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
    private var container: some View {
        if embedsNavigationStack {
            NavigationStack { scroller }
        } else {
            scroller
        }
    }

    private var scroller: some View {
        ScrollView(.vertical) {
            content
                .padding(.top, SCBrowseMetrics.contentTopInset)
                .padding(.bottom, SCBrowseMetrics.shelfGap)
        }
        .background { BrowseBackdrop() }
        .scrollClipDisabled()
        .frame(maxHeight: .infinity, alignment: .top)
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
                minHeight: 700,
                actionFocus: $statusFocused
            )
            .onAppear { DispatchQueue.main.async { statusFocused = true } }
        } else if !authService.isAuthenticated {
            StatusPanel(
                kind: .empty,
                icon: "qrcode",
                title: "Sign in to see your stream",
                message: "Scan the code with your iPhone to sign in to SoundCloud.",
                actionTitle: "Sign In",
                action: { Task { await authService.logout() } },
                minHeight: 700,
                actionFocus: $statusFocused
            )
            .onAppear { DispatchQueue.main.async { statusFocused = true } }
        } else if viewModel.items.isEmpty {
            StatusPanel(
                kind: .empty,
                icon: "dot.radiowaves.up.forward",
                title: "Nothing in your stream yet",
                message: "Follow some artists on SoundCloud and their uploads, playlists and reposts will show up here.",
                actionTitle: "Refresh",
                action: { Task { await loadFeed() } },
                minHeight: 700,
                actionFocus: $statusFocused
            )
            .onAppear { DispatchQueue.main.async { statusFocused = true } }
        } else {
            let paging = TVPaging(viewModel.pager)
            let heroes = Array(viewModel.items.prefix(Self.heroCount))
            let rest = Array(viewModel.items.dropFirst(heroes.count))
            let tracks = rest.filter { $0.track != nil }
            let collections = rest.filter { $0.playlist != nil }

            VStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
                heroShelf(heroes)
                    .focusSection()

                if !tracks.isEmpty {
                    FeedTrackShelf(activities: tracks, loadMore: loadMoreIfNeeded, paging: paging)
                }

                if !collections.isEmpty {
                    FeedCollectionShelf(activities: collections, loadMore: loadMoreIfNeeded, paging: paging)
                }

                if tracks.isEmpty, collections.isEmpty, let paging {
                    TVPagedFooter(paging: paging)
                }
            }
        }
    }

    private func heroShelf(_ activities: [FeedActivity]) -> some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            SCSectionHeader(title: "Latest", style: SCBrowseMetrics.header)

            ScrollView(.horizontal) {
                LazyHStack(spacing: SCBrowseMetrics.gutter) {
                    ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                        heroCard(activity, index: index)
                    }
                }
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
            .safeAreaPadding(.horizontal, SCBrowseMetrics.pageInset)
            .buttonStyle(SCCardButtonStyle(cornerRadius: SCBrowseMetrics.editorialCorner, sizeClass: .card))
            .focusEffectDisabled()
            .prefetchArtwork(activities.compactMap { $0.artwork.url }, variant: .hero)
        }
    }

    @ViewBuilder
    private func heroCard(_ activity: FeedActivity, index: Int) -> some View {
        let card = FeedActivityCard(activity: activity, play: { play(activity) })
            .accessibilityIdentifier(index == 0 ? "feed.hero" : "feed.hero.\(index)")
            .accessibilityLabel(activity.accessibilityLabel)
            .onAppear { loadMoreIfNeeded(activity) }
            .promotedImpression(activity)

        if index == 0 {
            card.focused($focus, equals: .firstCard)
        } else {
            card
        }
    }

    private func loadMoreIfNeeded(_ activity: FeedActivity) {
        viewModel.pager.loadMoreIfNeeded(after: activity, lead: 10)
    }

    private func play(_ activity: FeedActivity) {
        guard let track = activity.track, track.streamURL != nil else { return }
        PromotedTracking.shared.record(.play, for: activity)
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
        case .trackPromoted, .playlistPromoted:
            return promotedLabel ?? "Promoted"
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

    var accessibilityLabel: String {
        var parts = [kicker, displayTitle, rowSubtitle]
        if let track, track.streamURL != nil { parts.append(track.formattedDuration) }
        if !isActionable { parts.append("unavailable") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

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
        .prewarmPlaybackOnFocus(activity.track)
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
                identity: activity.track?.id ?? activity.playlist?.id,
                cornerRadius: SCBrowseMetrics.editorialCorner,
                crownUser: activity.track?.user ?? activity.playlist?.user,
                crownContext: activity.displayTitle
            )
            .frame(
                width: SCBrowseMetrics.wideCardWidth,
                height: SCBrowseMetrics.wideCardHeight
            )
        }
    }
}

private struct FeedTrackShelf: View {
    let activities: [FeedActivity]
    let loadMore: (FeedActivity) -> Void
    var paging: TVPaging?

    @EnvironmentObject private var playerService: PlayerService

    var body: some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            SCSectionHeader(title: "Tracks", style: SCBrowseMetrics.header)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: SCBrowseMetrics.gutter) {
                    ForEach(activities) { activity in
                        if let track = activity.track {
                            Button {
                                guard track.streamURL != nil else { return }
                                PromotedTracking.shared.record(.play, for: activity)
                                let queue = activities.compactMap(\.track).filter { $0.streamURL != nil }
                                Task { await playerService.play(track, in: queue) }
                            } label: {
                                FeedTrackTile(activity: activity)
                            }
                            .accessibilityLabel(activity.accessibilityLabel)
                            .prewarmPlaybackOnFocus(track.streamURL != nil ? track : nil)
                            .onAppear { loadMore(activity) }
                            .promotedImpression(activity)
                        }
                    }

                    if let paging {
                        TVShelfFooter(paging: paging, height: SCBrowseMetrics.tileEdge)
                    }
                }
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
            .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
            .focusEffectDisabled()
            .prefetchArtwork(activities.compactMap { $0.artwork.url })
        }
    }
}

private struct FeedTrackTile: View {
    let activity: FeedActivity

    var body: some View {
        SCCollectionArtworkResolver(
            artworkURL: activity.artwork.url,
            trackArtworkURLs: activity.artwork.mosaic
        ) { image in
            SCMediaCard(
                title: activity.displayTitle,
                subtitle: activity.promotedLabel ?? activity.rowSubtitle,
                artworkImage: image,
                artIdentity: activity.track?.id ?? activity.playlist?.id,
                artSubject: .track,
                isAvailable: activity.isActionable,
                crownUser: activity.track?.user ?? activity.playlist?.user,
                crownContext: activity.displayTitle,
                style: SCBrowseMetrics.tile
            )
        }
        .frame(width: SCBrowseMetrics.tileEdge)
    }
}

private struct FeedCollectionShelf: View {
    let activities: [FeedActivity]
    let loadMore: (FeedActivity) -> Void
    var paging: TVPaging?

    var body: some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            SCSectionHeader(title: "Albums & Playlists", style: SCBrowseMetrics.header)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: SCBrowseMetrics.gutter) {
                    ForEach(activities) { activity in
                        if let playlist = activity.playlist {
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                                    .onAppear { PromotedTracking.shared.record(.click, for: activity) }
                            } label: {
                                SCCollectionArtworkResolver(
                                    artworkURL: activity.artwork.url,
                                    trackArtworkURLs: activity.artwork.mosaic
                                ) { image in
                                    SCMediaCard(
                                        title: activity.displayTitle,
                                        subtitle: activity.promotedLabel ?? activity.rowSubtitle,
                                        artworkImage: image,
                                        artIdentity: playlist.id,
                                        artSubject: .collection,
                                        crownUser: playlist.user,
                                        crownContext: playlist.title,
                                        style: SCBrowseMetrics.tile
                                    )
                                }
                                .frame(width: SCBrowseMetrics.tileEdge)
                            }
                            .accessibilityLabel(activity.accessibilityLabel)
                            .onAppear { loadMore(activity) }
                            .promotedImpression(activity)
                        }
                    }

                    if let paging {
                        TVShelfFooter(paging: paging, height: SCBrowseMetrics.tileEdge)
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
