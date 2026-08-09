import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var navigationState: NavigationState
    @FocusState private var railFocus: LibraryFilter?
    @State private var isShowingLikesPolicy = false
    @State private var selectedGenre: String?
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Group {
            if authService.isAuthenticated {
                authenticatedView
            } else {
                signInPrompt
            }
        }
        .onChange(of: authService.isAuthenticated) { wasAuthenticated, isAuthenticated in
            if wasAuthenticated, !isAuthenticated {
                Task { await viewModel.handleSignOut() }
            }
        }
        .sheet(isPresented: $isShowingLikesPolicy) {
            CollectionPolicyEditor(
                collectionId: CollectionPolicyID.likedTracks,
                collectionName: "Liked Tracks",
                collectionKind: .playlist,
                tracks: viewModel.likedTracks,
                applier: DownloadManager.shared
            )
        }
    }

    private var authenticatedView: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: Space.roomy) {
                rail
                content
            }
            .padding(.trailing, Space.gutter)
            .padding(.top, SCBrowseMetrics.contentTopInset)
            .defaultFocus($railFocus, viewModel.selectedFilter)
            .onAppear {
                DispatchQueue.main.async { railFocus = viewModel.selectedFilter }
            }
            .onChange(of: viewModel.selectedFilter) { _, _ in
                Task { await viewModel.loadSelectedFilter() }
            }
            .task { await viewModel.loadSelectedFilter() }
            .onChange(of: navigationState.selectedTab) { _, tab in
                if tab == .library {
                    Task { await viewModel.refreshSelectedFilterIfStale() }
                }
            }
        }
        .background { BrowseBackdrop() }
    }

    private var rail: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.hair) {
                ForEach(LibraryFilter.railGroups) { group in
                    if let title = group.title {
                        Rectangle()
                            .fill(Color.scSeparator)
                            .frame(height: 1)
                            .padding(.top, Space.snug)
                            .padding(.bottom, Space.tight)

                        Text(title.uppercased())
                            .font(.system(size: 20, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(Color.scTextTertiary)
                            .padding(.leading, LibraryFilter.railLabelInset)
                            .padding(.trailing, Space.base)
                            .padding(.bottom, Space.tight)
                    }

                    ForEach(group.filters) { filter in
                        LibraryRailRow(
                            filter: filter,
                            isSelected: selectedGenre == nil && viewModel.selectedFilter == filter,
                            isFocused: railFocus == filter
                        ) {
                            selectedGenre = nil
                            viewModel.selectedFilter = filter
                        }
                        .focused($railFocus, equals: filter)
                    }
                }

                if !libraryGenres.isEmpty {
                    Rectangle()
                        .fill(Color.scSeparator)
                        .frame(height: 1)
                        .padding(.top, Space.snug)
                        .padding(.bottom, Space.tight)

                    Text("Genres")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.scTextTertiary)
                        .padding(.leading, Space.base)
                        .padding(.bottom, Space.hair)

                    ForEach(libraryGenres, id: \.self) { genre in
                        LibraryGenreRailRow(
                            genre: genre,
                            isSelected: selectedGenre == genre
                        ) {
                            selectedGenre = genre
                            viewModel.selectedFilter = .songs
                            railFocus = nil
                        }
                    }
                }
            }
            .padding(.vertical, Space.hair)
        }
        .scrollClipDisabled()
        .frame(width: LibraryFilter.railWidth)
        .offset(x: -30)
        .focusSection()
    }

    private var content: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
                paneHeader
                contentBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Space.section)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    @ViewBuilder
    private var paneHeader: some View {
        HStack(alignment: .bottom, spacing: Space.roomy) {
            VStack(alignment: .leading, spacing: Space.hair) {
                SCSectionHeader(title: selectedGenre ?? viewModel.selectedFilter.label, style: SCBrowseMetrics.header)
                if let count = paneCount {
                    Text(count)
                        .font(.tvCaption)
                        .foregroundStyle(Color.scTextSecondary)
                }
            }

            Spacer(minLength: 0)

            if viewModel.selectedFilter != .songs,
               viewModel.selectedFilter != .likes,
               !panePlayableTracks.isEmpty {
                HStack(spacing: Space.snug) {
                    Button {
                        Task { await PlayActions.play(tracks: panePlayableTracks, collectionId: paneCollectionId) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }

                    Button {
                        Task { await PlayActions.shufflePlay(tracks: panePlayableTracks, collectionId: paneCollectionId) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .tint(.white)
                .focusSection()
            }
        }
    }

    private var panePlayableTracks: [Track] {
        switch viewModel.selectedFilter {
        case .recentlyAdded:
            return viewModel.recentlyAdded.compactMap(\.track).filter { $0.streamURL != nil }
        case .songs:
            return displayedSongTracks.filter { $0.streamURL != nil }
        case .likes:
            return viewModel.likedTracks.filter { $0.streamURL != nil }
        case .sets:
            return displayedSets.filter { $0.streamURL != nil }
        case .artists, .playlists, .following:
            return []
        }
    }

    private var paneCollectionId: String? {
        switch viewModel.selectedFilter {
        case .likes: return CollectionPolicyID.likedTracks
        default: return nil
        }
    }

    private var paneCount: String? {
        func label(_ count: Int, _ noun: String) -> String {
            "\(count) \(count == 1 ? noun : noun + "s")"
        }
        switch viewModel.selectedFilter {
        case .recentlyAdded:
            if viewModel.recentlyAddedLoading, viewModel.recentlyAdded.isEmpty { return nil }
            return label(viewModel.recentlyAdded.count, "item")
        case .artists:
            if isLoadingFirstPage(.likes), viewModel.libraryArtists.isEmpty { return nil }
            return label(viewModel.libraryArtists.count, "artist")
        case .sets:
            if isLoadingFirstPage(.likes), displayedSets.isEmpty { return nil }
            return label(displayedSets.count, "set")
        case .songs:
            if isLoadingFirstPage(.likes), viewModel.likedTracks.isEmpty { return nil }
            return label(displayedSongTracks.count, "song")
        case .likes:
            if isLoadingFirstPage(.likes), viewModel.likedTracks.isEmpty { return nil }
            return label(viewModel.likedTracks.count, "track")
        case .playlists:
            if isLoadingFirstPage(.playlists), viewModel.libraryPlaylists.isEmpty { return nil }
            return label(viewModel.libraryPlaylists.count, "playlist")
        case .following:
            if isLoadingFirstPage(.following), viewModel.following.isEmpty { return nil }
            return label(viewModel.following.count, "artist")
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_LIBRARY_SKELETON"] == "1" {
            loadingSkeleton(for: viewModel.selectedFilter)
        } else {
            contentSwitch
        }
        #else
        contentSwitch
        #endif
    }

    @ViewBuilder
    private func loadingSkeleton(for filter: LibraryFilter) -> some View {
        switch filter {
        case .recentlyAdded:
            ContentSkeleton(
                lockup: .grid(columns: LibraryFilter.gridColumns),
                title: "Loading recently added…"
            )
        case .artists:
            ContentSkeleton(
                lockup: .grid(columns: LibraryFilter.gridColumns, circular: true),
                title: "Loading artists…"
            )
        case .songs, .likes, .sets:
            ContentSkeleton(lockup: .list(), title: "Loading songs…")
        case .playlists:
            ContentSkeleton(
                lockup: .grid(columns: LibraryFilter.gridColumns),
                title: "Loading your playlists…"
            )
        case .following:
            ContentSkeleton(
                lockup: .grid(columns: LibraryFilter.gridColumns, circular: true),
                title: "Loading who you follow…"
            )
        }
    }

    @ViewBuilder
    private var contentSwitch: some View {
        switch viewModel.selectedFilter {
        case .recentlyAdded:
            if viewModel.recentlyAddedLoading || !viewModel.recentlyAddedAttempted,
               viewModel.recentlyAdded.isEmpty {
                loadingSkeleton(for: .recentlyAdded)
            } else if let error = viewModel.recentlyAddedError, viewModel.recentlyAdded.isEmpty {
                retryPanel(title: "Couldn't load recently added", error: error) {
                    Task { await viewModel.loadRecentlyAdded() }
                }
            } else {
                RecentlyAddedGridView(
                    items: viewModel.recentlyAdded,
                    columns: LibraryFilter.gridColumns,
                    onNearEnd: { Task { await viewModel.loadMoreRecentlyAdded() } },
                    isLoadingMore: viewModel.recentlyAddedLoadingMore
                )
            }

        case .songs:
            if isLoadingFirstPage(.likes), viewModel.likedTracks.isEmpty {
                loadingSkeleton(for: .songs)
            } else if let error = viewModel.errorMessage, viewModel.likedTracks.isEmpty {
                retryPanel(title: "Couldn't load your songs", error: error) {
                    Task { await viewModel.loadContent() }
                }
            } else {
                TrackListView(
                    tracks: displayedSongTracks,
                    collectionId: nil,
                    dateAdded: { viewModel.likedAtByTrackID[$0.id] ?? $0.createdAt },
                    emptyIcon: LibraryFilter.songs.icon,
                    emptyTitle: selectedGenre.map { "No \($0) songs yet" } ?? LibraryFilter.songs.emptyMessage,
                    onNearEnd: { Task { await viewModel.loadMore(section: .likes) } },
                    isLoadingMore: viewModel.loadingMore.contains(.likes),
                    toolbarActions: AnyView(trackToolbarActions(
                        tracks: panePlayableTracks,
                        collectionId: nil,
                        showsManagement: false
                    )),
                    toolbarHeaderOverlap: 104
                )
            }

        case .likes:
            if isLoadingFirstPage(.likes), viewModel.likedTracks.isEmpty {
                loadingSkeleton(for: .likes)
            } else if let error = viewModel.errorMessage, viewModel.likedTracks.isEmpty {
                retryPanel(title: "Couldn't load your likes", error: error) {
                    Task { await viewModel.loadContent() }
                }
            } else {
                TrackListView(
                    tracks: viewModel.likedTracks,
                    collectionId: CollectionPolicyID.likedTracks,
                    dateAdded: { viewModel.likedAtByTrackID[$0.id] ?? $0.createdAt },
                    emptyIcon: LibraryFilter.likes.icon,
                    emptyTitle: LibraryFilter.likes.emptyMessage,
                    onNearEnd: { Task { await viewModel.loadMore(section: .likes) } },
                    isLoadingMore: viewModel.loadingMore.contains(.likes),
                    toolbarActions: AnyView(trackToolbarActions(
                        tracks: panePlayableTracks,
                        collectionId: CollectionPolicyID.likedTracks,
                        showsManagement: true
                    )),
                    toolbarHeaderOverlap: 104
                )
            }

        case .sets:
            if isLoadingFirstPage(.likes), displayedSets.isEmpty {
                loadingSkeleton(for: .sets)
            } else if let error = viewModel.errorMessage, displayedSets.isEmpty {
                retryPanel(title: "Couldn't load sets", error: error) {
                    Task { await viewModel.loadSelectedFilter() }
                }
            } else {
                TrackListView(
                    tracks: displayedSets,
                    collectionId: nil,
                    dateAdded: { viewModel.likedAtByTrackID[$0.id] ?? $0.createdAt },
                    emptyIcon: LibraryFilter.sets.icon,
                    emptyTitle: "No Sets Yet",
                    onNearEnd: { Task { await viewModel.loadMore(section: .likes) } },
                    isLoadingMore: viewModel.loadingMore.contains(.likes),
                    toolbarActions: AnyView(trackToolbarActions(
                        tracks: panePlayableTracks,
                        collectionId: nil,
                        showsManagement: false
                    )),
                    toolbarHeaderOverlap: 104
                )
            }

        case .artists:
            if isLoadingFirstPage(.likes), viewModel.libraryArtists.isEmpty {
                loadingSkeleton(for: .artists)
            } else if let error = viewModel.errorMessage, viewModel.libraryArtists.isEmpty {
                retryPanel(title: "Couldn't load your artists", error: error) {
                    Task { await viewModel.loadSelectedFilter() }
                }
            } else {
                UserGridView(
                    users: viewModel.libraryArtists,
                    columns: LibraryFilter.gridColumns,
                    onNearEnd: { Task { await viewModel.loadMoreArtists() } },
                    isLoadingMore: viewModel.loadingMore.contains(.likes)
                        || viewModel.loadingMore.contains(.following),
                    emptyIcon: LibraryFilter.artists.icon,
                    emptyTitle: LibraryFilter.artists.emptyMessage
                )
            }

        case .playlists:
            if isLoadingFirstPage(.playlists), viewModel.libraryPlaylists.isEmpty {
                loadingSkeleton(for: .playlists)
            } else if let error = viewModel.errorMessage, viewModel.libraryPlaylists.isEmpty {
                retryPanel(title: "Couldn't load your playlists", error: error) {
                    Task { await viewModel.loadContent() }
                }
            } else {
                PlaylistGridView(
                    playlists: viewModel.libraryPlaylists,
                    columns: LibraryFilter.gridColumns,
                    onNearEnd: { Task { await viewModel.loadMoreCollections() } },
                    isLoadingMore: viewModel.loadingMore.contains(.playlists)
                        || viewModel.likedPlaylistsLoadingMore,
                    emptyIcon: LibraryFilter.playlists.icon,
                    emptyTitle: LibraryFilter.playlists.emptyMessage
                )
            }

        case .following:
            if isLoadingFirstPage(.following), viewModel.following.isEmpty {
                loadingSkeleton(for: .following)
            } else if let error = viewModel.errorMessage, viewModel.following.isEmpty {
                retryPanel(title: "Couldn't load who you follow", error: error) {
                    Task { await viewModel.loadContent() }
                }
            } else {
                UserGridView(
                    users: viewModel.following,
                    columns: LibraryFilter.gridColumns,
                    onNearEnd: { Task { await viewModel.loadMore(section: .following) } },
                    isLoadingMore: viewModel.loadingMore.contains(.following),
                    emptyIcon: LibraryFilter.following.icon,
                    emptyTitle: LibraryFilter.following.emptyMessage
                )
            }
        }
    }

    private func trackToolbarActions(
        tracks: [Track],
        collectionId: String?,
        showsManagement: Bool
    ) -> some View {
        HStack(spacing: Space.snug) {
            Button {
                Task {
                    await PlayActions.play(
                        tracks: tracks,
                        collectionId: collectionId
                    )
                }
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Button {
                Task {
                    await PlayActions.shufflePlay(
                        tracks: tracks,
                        collectionId: collectionId
                    )
                }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }

            if showsManagement {
                Button {
                    isShowingLikesPolicy = true
                } label: {
                    Label("Manage Likes", systemImage: "arrow.down.circle")
                }
                .accessibilityLabel("Manage liked-track downloads")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(.white)
        .focusSection()
    }

    private var displayedSongTracks: [Track] {
        guard let selectedGenre else { return viewModel.librarySongTracks }
        return viewModel.librarySongTracks.filter {
            $0.genre?.localizedCaseInsensitiveCompare(selectedGenre) == .orderedSame
        }
    }

    private var displayedSets: [Track] {
        GeneratedLibraryCollections.sets(
            from: viewModel.likedTracks,
            minimumDuration: settings.setMinimumDurationSeconds
        )
    }

    private var libraryGenres: [String] {
        var counts: [String: Int] = [:]
        for track in viewModel.librarySongTracks {
            guard let raw = track.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            counts[raw, default: 0] += 1
        }
        return counts.keys.sorted {
            let lhsCount = counts[$0, default: 0]
            let rhsCount = counts[$1, default: 0]
            return lhsCount == rhsCount
                ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                : lhsCount > rhsCount
        }
        .prefix(8)
        .map { $0 }
    }

    private func isLoadingFirstPage(_ section: LibrarySection) -> Bool {
        viewModel.isLoading || !viewModel.attempted.contains(section)
    }

    private func retryPanel(title: String, error: String, retry: @escaping () -> Void) -> some View {
        StatusPanel(
            kind: .error,
            title: title,
            message: error,
            actionTitle: "Try Again",
            action: retry,
            minHeight: 400
        )
    }

    private var signInPrompt: some View {
        VStack(spacing: Space.roomy) {
            Spacer()

            Image(systemName: "music.note.list")
                .font(.system(size: 96, weight: .heavy))
                .foregroundStyle(Color.scTextTertiary)

            VStack(spacing: Spacing.sm) {
                Text("Your Library")
                    .font(.tvTitle)
                    .foregroundStyle(.white)
                Text("Sign in to see your liked tracks, playlists, and artists.")
                    .font(.tvBody)
                    .foregroundStyle(Color.scTextSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                NotificationCenter.default.post(name: .sessionExpired, object: nil)
            } label: {
                Label("Sign In", systemImage: "qrcode")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.white)
            .foregroundStyle(.black)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RecentlyAddedGridView: View {
    let items: [LibraryItem]
    let columns: Int
    var onNearEnd: (() -> Void)?
    var isLoadingMore = false

    @EnvironmentObject private var playerService: PlayerService

    private var grid: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Space.gutter), count: max(1, columns))
    }

    private var playableTracks: [Track] {
        items.compactMap(\.track).filter { $0.streamURL != nil }
    }

    var body: some View {
        if items.isEmpty {
            StatusPanel(
                kind: .empty,
                icon: LibraryFilter.recentlyAdded.icon,
                title: LibraryFilter.recentlyAdded.emptyMessage,
                minHeight: 320
            )
        } else {
            VStack(spacing: Space.base) {
                LazyVGrid(columns: grid, spacing: Space.gutter) {
                    ForEach(Array(items.enumerated()), id: \.element.libraryID) { index, item in
                        destination(for: item)
                            .onAppear {
                                guard index >= max(0, items.count - 12) else { return }
                                onNearEnd?()
                            }
                    }
                }
                .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
                .focusEffectDisabled()
                .prefetchArtwork(items.compactMap(\.artworkURL))

                if isLoadingMore {
                    LoadingMoreRow()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for item: LibraryItem) -> some View {
        if let playlist = item.playlist {
            NavigationLink {
                PlaylistDetailView(playlist: playlist)
            } label: {
                card(for: item)
            }
        } else if let track = item.track {
            Button {
                Task { await playerService.play(track, in: playableTracks) }
            } label: {
                card(for: item)
            }
            .disabled(track.streamURL == nil)
        } else if let station = item.systemPlaylist {
            Button {
                Task {
                    guard let tracks = try? await SoundCloudAPI.shared.getSystemPlaylistTracks(station),
                          let first = tracks.first else { return }
                    await playerService.play(first, in: tracks)
                }
            } label: {
                card(for: item)
            }
        }
    }

    private func card(for item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            ArtworkImage(url: item.artworkURL, icon: item.icon)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                .kyleCrowned(user: item.crownUser, context: item.displayTitle)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.displayTitle)
                    .font(.tvBodyEmph)
                    .foregroundStyle(Color.scTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.displaySubtitle)
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(item.isAvailable ? 1 : 0.5)
        .accessibilityElement(children: .combine)
    }
}

private extension LibraryItem {
    var libraryID: String {
        if let track { return "track:\(track.id)" }
        if let playlist { return "playlist:\(playlist.id)" }
        if let systemPlaylist { return "system:\(systemPlaylist.id)" }
        return "unknown:\(createdAt.timeIntervalSince1970)"
    }

    var artworkURL: URL? {
        track?.artworkURL ?? playlist?.displayArtworkURL ?? systemPlaylist?.artworkURL
    }

    var displayTitle: String {
        track?.title ?? playlist?.title ?? systemPlaylist?.title ?? "Unknown"
    }

    var displaySubtitle: String {
        if let track { return track.user.displayName }
        if let playlist { return playlist.isAlbum ? playlist.user.displayName : "Playlist" }
        if let systemPlaylist { return systemPlaylist.user?.displayName ?? "Station" }
        return ""
    }

    var crownUser: User? {
        track?.user ?? playlist?.user
    }

    var icon: String {
        if track != nil { return "music.note" }
        if playlist?.isAlbum == true { return "square.stack" }
        if playlist != nil { return "music.note.list" }
        return "dot.radiowaves.left.and.right"
    }

    var isAvailable: Bool {
        track?.streamURL != nil || playlist != nil || systemPlaylist != nil
    }
}

private struct LibraryRailRow: View {
    let filter: LibraryFilter
    let isSelected: Bool
    let isFocused: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: Capsule { Capsule(style: .continuous) }
    private var hasLightChrome: Bool { isFocused || isSelected }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.snug) {
                Image(systemName: filter.icon)
                    .font(.system(size: 25, weight: .medium))
                    .frame(width: LibraryFilter.railIconColumn, alignment: .center)
                    .foregroundStyle(hasLightChrome ? Color.scChromeFocusOn : Color.scTextSecondary)

                Text(filter.label)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(hasLightChrome ? Color.scChromeFocusOn : Color.scTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { shape.fill(hasLightChrome ? Color.scChromeFocus : .clear) }
            .contentShape(shape)
        }
        .buttonStyle(SCPlainButtonStyle())
        .focusEffectDisabled()
        .scMotion(Motion.focus, reduceMotion: reduceMotion, value: isFocused)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("libraryRail.\(filter.rawValue)")
    }
}

private struct LibraryGenreRailRow: View {
    let genre: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isHighlighted = isSelected || isFocused
        Button(action: action) {
            Text(GenrePresentation.displayName(for: genre))
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isHighlighted ? Color.scChromeFocusOn : Color.scTextSecondary)
                .lineLimit(1)
                .padding(.horizontal, Space.base)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isHighlighted ? Color.scChromeFocus : .clear,
                    in: Capsule(style: .continuous)
                )
        }
        .buttonStyle(SCPlainButtonStyle())
        .focusEffectDisabled()
        .focused($isFocused)
        .scMotion(Motion.focus, reduceMotion: reduceMotion, value: isFocused)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable, Hashable {
    case recentlyAdded
    case artists
    case sets
    case songs
    case playlists
    case likes
    case following

    var id: String { rawValue }

    struct RailGroup: Identifiable {
        let id: String
        var title: String?
        var filters: [LibraryFilter]
    }

    static let railGroups: [RailGroup] = [
        RailGroup(
            id: "library",
            title: nil,
            filters: [.recentlyAdded, .artists, .sets, .songs, .playlists, .likes, .following]
        ),
    ]

    static let railWidth: CGFloat = 300
    static let railIconColumn: CGFloat = 32

    static let railLabelInset: CGFloat = Space.base + railIconColumn + Space.snug

    static let gridColumns = 5

    var label: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .artists:       return "Artists"
        case .sets:          return "Sets"
        case .songs:         return "Songs"
        case .playlists:     return "Playlists"
        case .likes:         return "Likes"
        case .following:     return "Following"
        }
    }

    var icon: String {
        switch self {
        case .recentlyAdded: return "clock"
        case .artists:       return "music.mic"
        case .sets:          return "clock.arrow.2.circlepath"
        case .songs:         return "music.note"
        case .playlists:     return "music.note.list"
        case .likes:         return "heart.fill"
        case .following:     return "person.2"
        }
    }

    var emptyMessage: String {
        switch self {
        case .recentlyAdded: return "Music you add will appear here"
        case .artists:       return "Artists you save will appear here"
        case .sets:          return "Long-form liked tracks appear here"
        case .songs:         return "Songs you save will appear here"
        case .playlists:     return "Your saved playlists will appear here"
        case .likes:         return "Tracks you like will appear here"
        case .following:     return "Artists you follow will appear here"
        }
    }

    var dataSection: LibrarySection {
        switch self {
        case .recentlyAdded:       return .recentlyAdded
        case .artists, .sets, .songs, .likes: return .likes
        case .playlists:          return .playlists
        case .following:           return .following
        }
    }
}

enum LibrarySection: String, CaseIterable {
    case recentlyAdded = "RecentlyAdded"
    case likes     = "Liked"
    case playlists = "Playlists"
    case following = "Following"
}

@MainActor
class LibraryViewModel: ObservableObject {
    @Published var selectedFilter: LibraryFilter = LibraryViewModel.initialFilter()
    @Published var recentlyAdded: [LibraryItem] = []
    @Published private(set) var recentlyAddedAttempted = false
    @Published var recentlyAddedLoading = false
    @Published var recentlyAddedLoadingMore = false
    @Published var recentlyAddedError: String?
    @Published var likedTracks: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var following: [User] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var selectedSection: LibrarySection { selectedFilter.dataSection }

    @Published var likedAtByTrackID: [String: Date] = [:]

    @Published private(set) var loadingMore: Set<LibrarySection> = []

    @Published private(set) var attempted: Set<LibrarySection> = []

    @Published var likedPlaylists: [Playlist] = []
    @Published var likedPlaylistsLoadingMore = false
    private var likedPlaylistsCursor = PageCursor<Playlist>()
    private var didLoadLikedPlaylists = false

    private let api = SoundCloudAPI.shared
    private var lastLoaded: [LibrarySection: Date] = [:]

    private let libraryCache = LibraryCache.shared
    private static let cacheDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    private static let cacheEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(cacheDateFormatter)
        return encoder
    }()
    private static let cacheDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(cacheDateFormatter)
        return decoder
    }()

    private static let likedPlaylistsCacheKey = "LikedPlaylists"

    private var recentlyAddedCursor = PageCursor<LibraryItem>()
    private var likesCursor     = PageCursor<Like<Track>>()
    private var playlistsCursor = PageCursor<Playlist>()
    private var followingCursor = PageCursor<User>()

    private let staleAfter: TimeInterval = 5 * 60

    private var likesServedFromIndex = false
    private var likesIndexComplete = false
    private nonisolated(unsafe) var indexObserver: NSObjectProtocol?
    private let createdAtReference = Date()

    init() {
        indexObserver = NotificationCenter.default.addObserver(
            forName: .likesIndexDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.rehydrateLikesFromIndex() }
        }
    }

    deinit {
        if let indexObserver {
            NotificationCenter.default.removeObserver(indexObserver)
        }
    }

    static func initialFilter() -> LibraryFilter {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "SOUNDING_TV_LIBRARY_SECTION")
            ?? ProcessInfo.processInfo.environment["SOUNDING_TV_LIBRARY_SECTION"] {
            if let filter = LibraryFilter(rawValue: raw) { return filter }
            switch raw {
            case "Liked":     return .likes
            case "Playlists": return .playlists
            case "Following": return .following
            default:          break
            }
        }
        #endif
        return .recentlyAdded
    }

    var libraryArtists: [User] {
        var seen = Set<String>()
        var result: [User] = []
        for user in following where seen.insert(user.id).inserted {
            result.append(user)
        }
        for track in likedTracks where seen.insert(track.user.id).inserted {
            result.append(track.user)
        }
        return result
    }

    var librarySongTracks: [Track] {
        var seen = Set<String>()
        let recentlySaved = recentlyAdded.compactMap(\.track)
        return (recentlySaved + likedTracks).filter { seen.insert($0.id).inserted }
    }

    var libraryPlaylists: [Playlist] {
        mergedCollections.filter { !$0.isAlbum }
    }

    private var mergedCollections: [Playlist] {
        var seen = Set<String>()
        return (likedPlaylists + playlists).filter { seen.insert($0.id).inserted }
    }

    func loadSelectedFilter() async {
        #if DEBUG
        if VisualFixtures.isEnabled {
            installVisualFixtures()
            return
        }
        #endif

        switch selectedFilter {
        case .recentlyAdded:
            await loadRecentlyAddedIfNeeded()
        case .artists:
            await loadSectionIfNeeded(.likes)
            await loadSectionIfNeeded(.following)
        case .playlists:
            await loadSectionIfNeeded(.playlists)
            await loadLikedPlaylistsIfNeeded()
        case .likes, .sets, .following:
            await loadContent()
        case .songs:
            await loadSectionIfNeeded(.likes)
            await loadRecentlyAddedIfNeeded()
        }
    }

    #if DEBUG
    private func installVisualFixtures() {
        recentlyAdded = VisualFixtures.libraryItems
        recentlyAddedAttempted = true
        likedTracks = VisualFixtures.tracks
        following = VisualFixtures.artists
        playlists = VisualFixtures.playlists
        attempted = Set(LibrarySection.allCases)
        errorMessage = nil
        recentlyAddedError = nil
        for section in LibrarySection.allCases { lastLoaded[section] = Date() }
    }
    #endif

    func refreshSelectedFilterIfStale() async {
        switch selectedFilter {
        case .recentlyAdded:
            await refreshRecentlyAddedIfStale()
        case .artists:
            await refreshSectionIfStale(.likes)
            await refreshSectionIfStale(.following)
        case .playlists:
            await refreshSectionIfStale(.playlists)
            await loadLikedPlaylistsIfNeeded()
        case .likes, .sets, .following:
            await refreshIfStale()
        case .songs:
            await refreshSectionIfStale(.likes)
            await refreshRecentlyAddedIfStale()
        }
    }

    private func loadSectionIfNeeded(_ section: LibrarySection) async {
        guard lastLoaded[section] == nil else { return }
        await load(section: section)
    }

    private func refreshSectionIfStale(_ section: LibrarySection) async {
        guard let loaded = lastLoaded[section], Date().timeIntervalSince(loaded) <= staleAfter else {
            await load(section: section)
            return
        }
    }

    func refreshIfStale() async {
        guard let loaded = lastLoaded[selectedSection] else {
            await loadContent()
            return
        }
        if Date().timeIntervalSince(loaded) > staleAfter {
            await loadContent()
        }
    }

    func loadContent() async {
        if selectedSection == .recentlyAdded {
            await loadRecentlyAdded()
            return
        }
        await load(section: selectedSection)
    }

    private func load(section: LibrarySection) async {
        guard AuthenticationService.shared.isAuthenticated else { return }

        attempted.insert(section)

        LikesSyncEngine.shared.activate()

        if lastLoaded[section] == nil {
            await hydrateFromCache(section)
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            switch section {
            case .recentlyAdded:
                return
            case .likes:
                let result = try await api.getLikedTracks(limit: 100)
                for like in result.collection { likedAtByTrackID[like.item.id] = like.createdAt }
                await LikesSyncEngine.shared.integrate(firstPage: result.collection)
                if likesServedFromIndex {
                    await rehydrateLikesFromIndex()
                } else {
                    likedTracks = result.collection.map { $0.item }
                    likesCursor.advance(to: result)
                    await persistLikesCache(result.collection)
                }

            case .playlists:
                guard let user = await AuthenticationService.shared.waitForCurrentUser() else {
                    if playlists.isEmpty { errorMessage = "Couldn't load your account details." }
                    return
                }
                let result = try await api.getUserPlaylists(userId: user.id, limit: 50)
                playlists = result.collection
                playlistsCursor.advance(to: result)
                await persistCache(LibrarySection.playlists.rawValue, items: result.collection, id: \.id)

            case .following:
                guard let user = await AuthenticationService.shared.waitForCurrentUser() else {
                    if following.isEmpty { errorMessage = "Couldn't load your account details." }
                    return
                }
                let result = try await api.getUserFollowings(userId: user.id, limit: 100)
                following = result.collection
                followingCursor.advance(to: result)
                await persistCache(LibrarySection.following.rawValue, items: result.collection, id: \.id)
            }

            lastLoaded[section] = Date()
        } catch {
            print("Library load error: \(error)")
            if !hasContent(section) {
                errorMessage = "Couldn't reach SoundCloud. Check this Apple TV's network connection."
            }
        }
    }

    private func hasContent(_ section: LibrarySection) -> Bool {
        switch section {
        case .recentlyAdded: return !recentlyAdded.isEmpty
        case .likes:     return !likedTracks.isEmpty
        case .playlists: return !playlists.isEmpty
        case .following: return !following.isEmpty
        }
    }

    private func hydrateFromCache(_ section: LibrarySection) async {
        if section == .likes, await rehydrateLikesFromIndex() {
            return
        }

        let rows = await libraryCache.loadSection(section.rawValue)
        guard !rows.isEmpty else { return }

        switch section {
        case .recentlyAdded:
            let decoded = rows.compactMap { try? Self.cacheDecoder.decode(LibraryItem.self, from: $0.payload) }
            guard !decoded.isEmpty else { return }
            recentlyAdded = decoded

        case .likes:
            var tracks: [Track] = []
            var likedAt: [String: Date] = [:]
            for row in rows {
                guard let track = try? Self.cacheDecoder.decode(Track.self, from: row.payload) else { continue }
                tracks.append(track)
                if let millis = row.likedAtMillis {
                    likedAt[track.id] = Date(timeIntervalSince1970: Double(millis) / 1000)
                }
            }
            guard !tracks.isEmpty else { return }
            likedTracks = tracks
            likedAtByTrackID = likedAt
            logLikesContent(count: tracks.count, source: "section cache")

        case .playlists:
            let decoded = rows.compactMap { try? Self.cacheDecoder.decode(Playlist.self, from: $0.payload) }
            guard !decoded.isEmpty else { return }
            playlists = decoded

        case .following:
            let decoded = rows.compactMap { try? Self.cacheDecoder.decode(User.self, from: $0.payload) }
            guard !decoded.isEmpty else { return }
            following = decoded
        }
    }

    @discardableResult
    private func rehydrateLikesFromIndex() async -> Bool {
        guard AuthenticationService.shared.isAuthenticated else { return false }

        let engine = LikesSyncEngine.shared
        let complete = await engine.indexCompletedAt() != nil

        if likedTracks.isEmpty {
            let head = await engine.indexedLikes(limit: 100)
            guard !head.tracks.isEmpty else { return false }
            likedTracks = head.tracks
            likedAtByTrackID = head.likedAt
            likesServedFromIndex = true
            likesIndexComplete = complete
            logLikesContent(count: head.tracks.count, source: "index head")
        }

        let indexed = await engine.indexedLikes()
        guard !indexed.tracks.isEmpty else { return likesServedFromIndex }
        guard complete || indexed.tracks.count >= likedTracks.count else { return likesServedFromIndex }

        likedTracks = indexed.tracks
        likedAtByTrackID = indexed.likedAt
        likesServedFromIndex = true
        likesIndexComplete = complete
        logLikesContent(count: indexed.tracks.count, source: complete ? "index (complete)" : "index (partial)")
        return true
    }

    private func logLikesContent(count: Int, source: String) {
        #if DEBUG
        let elapsed = Date().timeIntervalSince(createdAtReference) * 1000
        print(String(format: "[Perf] likes content: %d track(s) from %@ at +%.0fms after VM init", count, source, elapsed))
        #endif
    }

    private func persistLikesCache(_ likes: [Like<Track>]) async {
        let rows: [LibraryCache.WriteRow] = likes.compactMap { like in
            guard let payload = try? Self.cacheEncoder.encode(like.item) else { return nil }
            return LibraryCache.WriteRow(
                id: like.item.id,
                payload: payload,
                likedAtMillis: Int64((like.createdAt.timeIntervalSince1970 * 1000).rounded())
            )
        }
        await libraryCache.replaceSection(LibrarySection.likes.rawValue, rows: rows)
    }

    private func persistCache<T: Encodable>(_ cacheKey: String, items: [T], id: (T) -> String) async {
        let rows: [LibraryCache.WriteRow] = items.compactMap { item in
            guard let payload = try? Self.cacheEncoder.encode(item) else { return nil }
            return LibraryCache.WriteRow(id: id(item), payload: payload)
        }
        await libraryCache.replaceSection(cacheKey, rows: rows)
    }

    func handleSignOut() async {
        LikesSyncEngine.shared.handleSignOut()
        await libraryCache.clearAll()
        attempted.removeAll()
        lastLoaded.removeAll()
        recentlyAdded = []
        recentlyAddedAttempted = false
        recentlyAddedCursor.reset()
        likedTracks = []
        likedAtByTrackID = [:]
        playlists = []
        following = []
        likesCursor.reset()
        playlistsCursor.reset()
        followingCursor.reset()
        likedPlaylists = []
        likedPlaylistsCursor.reset()
        didLoadLikedPlaylists = false
        likesServedFromIndex = false
        likesIndexComplete = false
    }

    func loadMore(section: LibrarySection) async {
        guard AuthenticationService.shared.isAuthenticated else { return }

        guard !isLoading, !loadingMore.contains(section), canLoadMore(section) else { return }

        loadingMore.insert(section)
        defer { loadingMore.remove(section) }

        do {
            switch section {
            case .recentlyAdded:
                return
            case .likes:
                guard let page = likesCursor.lastPage else { return }
                let next = try await api.getNextPage(page)
                likesCursor.advance(to: next)
                for like in next.collection { likedAtByTrackID[like.item.id] = like.createdAt }
                likedTracks.appendUnique(contentsOf: next.collection.map { $0.item })

            case .playlists:
                guard let page = playlistsCursor.lastPage else { return }
                let next = try await api.getNextPage(page)
                playlistsCursor.advance(to: next)
                playlists.appendUnique(contentsOf: next.collection)

            case .following:
                guard let page = followingCursor.lastPage else { return }
                let next = try await api.getNextPage(page)
                followingCursor.advance(to: next)
                following.appendUnique(contentsOf: next.collection)
            }
        } catch {
            print("Library load-more error (\(section.rawValue)): \(error)")
        }
    }

    private func canLoadMore(_ section: LibrarySection) -> Bool {
        switch section {
        case .recentlyAdded: return recentlyAddedCursor.canLoadMore
        case .likes:     return !likesIndexComplete && likesCursor.canLoadMore
        case .playlists: return playlistsCursor.canLoadMore
        case .following: return followingCursor.canLoadMore
        }
    }

    func loadLikedPlaylistsIfNeeded() async {
        guard !didLoadLikedPlaylists else { return }
        await loadLikedPlaylists()
    }

    func loadLikedPlaylists() async {
        guard AuthenticationService.shared.isAuthenticated else { return }

        if likedPlaylists.isEmpty {
            await hydrateLikedPlaylistsFromCache()
        }

        didLoadLikedPlaylists = true

        do {
            let page = try await api.getLikedPlaylists(limit: 50)
            likedPlaylists = page.collection
            likedPlaylistsCursor.advance(to: page)
            await persistCache(Self.likedPlaylistsCacheKey, items: page.collection, id: \.id)
        } catch {
            print("Liked playlists load error: \(error)")
        }
    }

    private func hydrateLikedPlaylistsFromCache() async {
        let rows = await libraryCache.loadSection(Self.likedPlaylistsCacheKey)
        let decoded = rows.compactMap { try? Self.cacheDecoder.decode(Playlist.self, from: $0.payload) }
        guard !decoded.isEmpty else { return }
        likedPlaylists = decoded
    }

    func loadRecentlyAddedIfNeeded() async {
        guard !recentlyAddedAttempted else { return }
        await loadRecentlyAdded()
    }

    func refreshRecentlyAddedIfStale() async {
        guard let loaded = lastLoaded[.recentlyAdded],
              Date().timeIntervalSince(loaded) <= staleAfter else {
            await loadRecentlyAdded()
            return
        }
    }

    func loadRecentlyAdded() async {
        guard AuthenticationService.shared.isAuthenticated else { return }

        recentlyAddedAttempted = true
        if recentlyAdded.isEmpty {
            await hydrateFromCache(.recentlyAdded)
        }

        recentlyAddedLoading = true
        recentlyAddedError = nil
        defer { recentlyAddedLoading = false }

        do {
            let page = try await api.getLibrary(limit: 50)
            let visible = page.collection.filter { $0.track != nil || $0.playlist != nil || $0.systemPlaylist != nil }
            recentlyAdded = visible
            recentlyAddedCursor.advance(to: page)
            await persistCache(
                LibrarySection.recentlyAdded.rawValue,
                items: visible,
                id: { $0.libraryID }
            )
            lastLoaded[.recentlyAdded] = Date()
        } catch {
            if recentlyAdded.isEmpty {
                recentlyAddedError = "Couldn't reach SoundCloud. Check this Apple TV's network connection."
            }
        }
    }

    func loadMoreRecentlyAdded() async {
        guard !recentlyAddedLoadingMore, recentlyAddedCursor.canLoadMore else { return }
        recentlyAddedLoadingMore = true
        defer { recentlyAddedLoadingMore = false }

        do {
            guard let page = recentlyAddedCursor.lastPage else { return }
            let next = try await api.getNextPage(page)
            recentlyAddedCursor.advance(to: next)
            let visible = next.collection.filter { $0.track != nil || $0.playlist != nil || $0.systemPlaylist != nil }
            var seen = Set(recentlyAdded.map(\.libraryID))
            recentlyAdded.append(contentsOf: visible.filter { seen.insert($0.libraryID).inserted })
        } catch {
            print("Recently added load-more error: \(error)")
        }
    }

    func loadMoreLikedPlaylists() async {
        guard !likedPlaylistsLoadingMore, likedPlaylistsCursor.canLoadMore else { return }
        likedPlaylistsLoadingMore = true
        defer { likedPlaylistsLoadingMore = false }

        do {
            guard let page = likedPlaylistsCursor.lastPage else { return }
            let next = try await api.getNextPage(page)
            likedPlaylistsCursor.advance(to: next)
            likedPlaylists.appendUnique(contentsOf: next.collection)
        } catch {
            print("Liked playlists load-more error: \(error)")
        }
    }

    func loadMoreCollections() async {
        await loadMore(section: .playlists)
        await loadMoreLikedPlaylists()
    }

    func loadMoreArtists() async {
        await loadMore(section: .likes)
        await loadMore(section: .following)
    }
}
