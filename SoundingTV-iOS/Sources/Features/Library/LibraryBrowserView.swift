import SwiftUI
import os

extension String {
    func scLocallyContains(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .contains(needle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))
    }
}

struct LibraryBrowserView: View {
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @StateObject private var viewModel = LibraryBrowserViewModel()
    @StateObject private var confirmation = QueueConfirmationController()
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingSignIn = false
    @Namespace private var libraryNamespace
    @StateObject private var analysisStore = TrackAnalysisStore()

    var body: some View {
        Group {
            if !credentials.isSignedOut {
                libraryIndex
            } else {
                signInPrompt
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.scBgBase.ignoresSafeArea())
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { indexToolbar }
        .task {
            credentials.refreshFromStore()
            await viewModel.loadContent(for: .playlists)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            credentials.refreshFromStore()
        }
        .onChange(of: credentials.isSignedOut) { wasSignedOut, isSignedOut in
            guard isSignedOut, !wasSignedOut else { return }
            Task { await viewModel.handleSignOut() }
        }
        .sheet(isPresented: $isShowingSignIn) { signInSheet }
    }

    @ToolbarContentBuilder
    private var indexToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            AccountAvatarButton()
        }
    }

    private var libraryIndex: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                VStack(spacing: 0) {
                    indexRow(.likes, icon: "heart.fill", tint: .pink)
                    ScRowDivider(leading: indexSeparatorInset)
                    indexRow(.sets, icon: "clock.arrow.2.circlepath", tint: .scAccent)
                    ScRowDivider(leading: indexSeparatorInset)
                    indexRow(.playlists, icon: "music.note.list", tint: .scAccent)
                    ScRowDivider(leading: indexSeparatorInset)
                    indexRow(.following, icon: "person.2.fill", tint: .purple)
                }
                .padding(.horizontal, Space.page)

                recentlyAddedSection
            }
            .padding(.top, Space.tight)
            .padding(.bottom, Space.section)
        }
        .refreshable { await viewModel.loadContent(for: .playlists, forceRefresh: true) }
    }

    @ViewBuilder
    private var recentlyAddedSection: some View {
        switch viewModel.state(for: .playlists) {
        case .failed(let failure):
            SCEmptyState(
                kind: failure.isFault ? .error : .empty,
                icon: failure.icon,
                title: failure.title,
                message: failure.message(subject: "your library"),
                actionTitle: failure.actionTitle,
                action: {
                    switch failure.recovery {
                    case .signIn: isShowingSignIn = true
                    case .retry:  Task { await viewModel.loadContent(for: .playlists, forceRefresh: true) }
                    }
                },
                style: .phone
            )

        case .loading, .loaded, .empty:
            if !viewModel.playlists.isEmpty {
                VStack(alignment: .leading, spacing: Space.snug) {
                    SCSectionHeader(title: "Recently Added", style: .phoneSectionHeader)
                        .padding(.horizontal, Space.page)
                    recentlyAddedGrid
                }
            }
        }
    }

    private var indexSeparatorInset: CGFloat { 34 + Space.snug }

    private func indexRow(_ section: LibraryBrowserViewModel.Section, icon: String, tint: Color) -> some View {
        NavigationLink {
            LibrarySectionDetailView(
                section: section, viewModel: viewModel, analysisStore: analysisStore, confirmation: confirmation
            )
        } label: {
            HStack(spacing: Space.snug) {
                RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                Text(section.indexLabel)
                    .font(.scBody)
                    .foregroundStyle(Color.scTextPrimary)
                Spacer(minLength: Space.tight)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.scTextTertiary)
            }
            .padding(.vertical, Space.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recentlyAddedGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: Space.snug)],
            alignment: .leading,
            spacing: Space.snug
        ) {
            ForEach(viewModel.playlists.prefix(6)) { playlist in
                NavigationLink {
                    PlaylistDetailView(playlist: playlist, heroNamespace: libraryNamespace)
                } label: {
                    RecentlyAddedTile(playlist: playlist)
                }
                .matchedTransitionSource(id: playlist.id, in: libraryNamespace)
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 1040, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.page)
        .prefetchArtwork(viewModel.playlists.prefix(6).compactMap(\.artworkURL))
    }

    private var signInPrompt: some View {
        let failure = LoadFailure.credentialFailure()
        return SCEmptyState(
            kind: .empty,
            icon: failure.icon,
            title: failure.title,
            message: failure.message(subject: "your likes, playlists and following"),
            actionTitle: failure.actionTitle,
            action: { isShowingSignIn = true },
            style: .phone
        )
    }
}

private struct RecentlyAddedTile: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            PlaylistArtworkView(
                identity: playlist.title,
                artworkURL: thumbnailURL,
                trackArtworkURLs: (playlist.tracks ?? []).compactMap(\.artworkURL),
                style: .phone
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .kyleCrowned(user: playlist.user, context: playlist.title)

            Text(playlist.title)
                .font(.scSubhead)
                .fontWeight(.semibold)
                .foregroundStyle(Color.scTextPrimary)
                .lineLimit(1)
            Text(playlist.user.displayName)
                .font(.scCaption)
                .foregroundStyle(Color.scTextTertiary)
                .lineLimit(1)
        }
    }

    private var thumbnailURL: URL? {
        guard let url = playlist.artworkURL else { return nil }
        return URL(string: url.absoluteString.replacingOccurrences(of: "-large", with: "-t300x300")) ?? url
    }
}

private extension LibraryBrowserView {
    var signInSheet: some View {
        NavigationStack {
            SoundCloudLoginView.standalone {
                isShowingSignIn = false
                credentials.refreshFromStore()
            }
        }
    }
}

private struct LibrarySectionDetailView: View {
    let section: LibraryBrowserViewModel.Section
    @ObservedObject var viewModel: LibraryBrowserViewModel
    @ObservedObject var analysisStore: TrackAnalysisStore
    @ObservedObject var confirmation: QueueConfirmationController

    @State private var searchText = ""
    @State private var sortKey: TrackSortKey = .dateAdded
    @State private var ascending = false
    @Namespace private var playlistNamespace
    @State private var isShowingSignIn = false
    @State private var isShowingCollectionPolicy = false
    @ObservedObject private var settings = SettingsStore.shared

    private var backingSection: LibraryBrowserViewModel.Section {
        section == .sets ? .likes : section
    }

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.scBgBase.ignoresSafeArea())
            .navigationTitle(section.indexLabel)
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: searchPrompt)
            .toolbar {
                if trimmedSearch.isEmpty, section == .likes {
                    ToolbarItem(placement: .topBarTrailing) {
                        TrackSortMenu(sortKey: $sortKey, ascending: $ascending)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        CollectionDownloadButton(collectionId: "likes", tracks: { viewModel.likedTracks })
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Liked Tracks Settings", systemImage: "slider.horizontal.3") {
                            isShowingCollectionPolicy = true
                        }
                    }
                }
            }
            .task { await viewModel.loadContent(for: backingSection) }
            .task(id: viewModel.likedTracks.map(\.id)) {
                guard section == .likes || section == .sets else { return }
                await analysisStore.load(for: viewModel.likedTracks)
                if section == .likes {
                    DownloadManager.shared.applyCollectionPolicy(
                        tracks: viewModel.likedTracks,
                        collectionId: CollectionPolicyID.likedTracks
                    )
                }
            }
            .task(id: searchText) {
                guard !trimmedSearch.isEmpty else { return }
                await loadRemainingForSearch()
            }
            .queueConfirmationOverlay(confirmation)
            .sheet(isPresented: $isShowingSignIn) {
                NavigationStack {
                    SoundCloudLoginView.standalone {
                        isShowingSignIn = false
                        SoundCloudCredentialSource.shared.refreshFromStore()
                        Task { await viewModel.loadContent(for: backingSection, forceRefresh: true) }
                    }
                }
            }
            .sheet(isPresented: $isShowingCollectionPolicy) {
                CollectionPolicyEditor(
                    collectionId: CollectionPolicyID.likedTracks,
                    collectionName: "Liked Tracks",
                    collectionKind: .playlist,
                    tracks: viewModel.likedTracks,
                    applier: DownloadManager.shared
                )
            }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchPrompt: String {
        switch section {
        case .likes:     return "Search Liked"
        case .sets:      return "Search Sets"
        case .playlists: return "Search Playlists"
        case .following: return "Search Following"
        }
    }

    private func loadRemainingForSearch() async {
        var stall = 0
        while !Task.isCancelled {
            let before = viewModel.count(for: backingSection)
            await viewModel.loadMore(section: backingSection)
            if viewModel.count(for: backingSection) == before {
                stall += 1
                if stall >= 2 { return }
            } else {
                stall = 0
            }
        }
    }

    private var searchYieldedNothing: Bool {
        guard !trimmedSearch.isEmpty else { return false }
        switch section {
        case .likes:     return filteredLikedTracks.isEmpty
        case .sets:      return filteredSetTracks.isEmpty
        case .playlists: return filteredPlaylists.isEmpty
        case .following: return filteredFollowing.isEmpty
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state(for: backingSection) {
        case .loading:
            LoadingState(message: "Loading your \(section.title.lowercased())…")

        case .failed(let failure):
            SCEmptyState(
                kind: failure.isFault ? .error : .empty,
                icon: failure.icon,
                title: failure.title,
                message: failure.message(subject: "your \(section.title.lowercased())"),
                actionTitle: failure.actionTitle,
                action: {
                    switch failure.recovery {
                    case .signIn:
                        isShowingSignIn = true
                    case .retry:
                        Task { await viewModel.loadContent(for: backingSection, forceRefresh: true) }
                    }
                },
                style: .phone
            )

        case .empty:
            StateMessage(
                icon: section.emptyIcon,
                title: section.title,
                message: section.emptyMessage
            ) {
                Button("Refresh") {
                    Task { await viewModel.loadContent(for: backingSection, forceRefresh: true) }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.scAccent)
            }

        case .loaded where searchYieldedNothing:
            StateMessage(
                icon: "magnifyingglass",
                title: "No Results",
                message: "Nothing matched \u{201C}\(searchText)\u{201D}."
            )

        case .loaded where section == .sets && filteredSetTracks.isEmpty:
            StateMessage(
                icon: section.emptyIcon,
                title: "No Sets Yet",
                message: "Sets are liked tracks lasting \(GeneratedLibraryCollections.durationLabel(settings.setMinimumDurationSeconds)) or more."
            )

        case .loaded:
            List {
                switch section {
                case .likes:     likesRows
                case .sets:      setRows
                case .playlists: playlistsRows
                case .following: followingRows
                }

                if viewModel.loadingMore.contains(backingSection) {
                    LoadingMoreRow()
                }
            }
            .listStyle(.plain)
            .refreshable { await viewModel.loadContent(for: section, forceRefresh: true) }
        }
    }

    private var sortedLikedTracks: [Track] {
        TrackSort.sorted(
            viewModel.likedTracks,
            by: sortKey,
            ascending: ascending,
            analysis: analysisStore.summaries,
            dateAdded: { viewModel.likedAtByTrackID[$0.id] ?? $0.createdAt }
        )
    }

    private var filteredLikedTracks: [Track] {
        guard !trimmedSearch.isEmpty else { return sortedLikedTracks }
        return sortedLikedTracks.filter {
            $0.title.scLocallyContains(trimmedSearch) || $0.user.displayName.scLocallyContains(trimmedSearch)
        }
    }

    private var filteredSetTracks: [Track] {
        let sets = GeneratedLibraryCollections.sets(
            from: viewModel.likedTracks,
            minimumDuration: settings.setMinimumDurationSeconds
        )
        guard !trimmedSearch.isEmpty else { return sets }
        return sets.filter {
            $0.title.scLocallyContains(trimmedSearch) || $0.user.displayName.scLocallyContains(trimmedSearch)
        }
    }

    private var filteredPlaylists: [Playlist] {
        guard !trimmedSearch.isEmpty else { return viewModel.playlists }
        return viewModel.playlists.filter { $0.title.scLocallyContains(trimmedSearch) }
    }

    private var filteredFollowing: [User] {
        guard !trimmedSearch.isEmpty else { return viewModel.following }
        return viewModel.following.filter { $0.displayName.scLocallyContains(trimmedSearch) }
    }

    private var likesRows: some View {
        ForEach(Array(filteredLikedTracks.enumerated()), id: \.element.id) { index, track in
            TrackListRow(
                track: track,
                analysis: analysisStore.summaries[track.id],
                context: { filteredLikedTracks },
                collectionId: CollectionPolicyID.likedTracks,
                confirmation: confirmation
            )
            .onAppear {
                guard trimmedSearch.isEmpty, sortedLikedTracks.isNearEnd(track, lead: 10) else { return }
                Task { await viewModel.loadMore(section: .likes) }
            }
            .onAppear {
                let tracks = filteredLikedTracks
                let lookahead = tracks[index..<min(index + Self.artworkLookahead, tracks.count)]
                ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL))
            }
        }
    }

    private var setRows: some View {
        ForEach(Array(filteredSetTracks.enumerated()), id: \.element.id) { index, track in
            TrackListRow(
                track: track,
                analysis: analysisStore.summaries[track.id],
                context: { filteredSetTracks },
                collectionId: nil,
                confirmation: confirmation
            )
            .onAppear {
                guard trimmedSearch.isEmpty, filteredSetTracks.isNearEnd(track, lead: 10) else { return }
                Task { await viewModel.loadMore(section: .likes) }
            }
            .onAppear {
                let tracks = filteredSetTracks
                let lookahead = tracks[index..<min(index + Self.artworkLookahead, tracks.count)]
                ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL))
            }
        }
    }

    private var playlistsRows: some View {
        ForEach(Array(filteredPlaylists.enumerated()), id: \.element.id) { index, playlist in
            NavigationLink {
                PlaylistDetailView(playlist: playlist, heroNamespace: playlistNamespace)
            } label: {
                PlaylistRow(playlist: playlist)
            }
            .matchedTransitionSource(id: playlist.id, in: playlistNamespace)
            .onAppear {
                guard trimmedSearch.isEmpty, viewModel.playlists.isNearEnd(playlist, lead: 10) else { return }
                Task { await viewModel.loadMore(section: .playlists) }
            }
            .onAppear {
                let playlists = filteredPlaylists
                let lookahead = playlists[index..<min(index + Self.artworkLookahead, playlists.count)]
                ArtworkCache.shared.prefetch(lookahead.compactMap(\.artworkURL))
            }
        }
    }

    private var followingRows: some View {
        ForEach(Array(filteredFollowing.enumerated()), id: \.element.id) { index, user in
            NavigationLink {
                ArtistDetailView(user: user)
            } label: {
                UserRow(user: user)
            }
            .onAppear {
                guard trimmedSearch.isEmpty, viewModel.following.isNearEnd(user, lead: 10) else { return }
                Task { await viewModel.loadMore(section: .following) }
            }
            .onAppear {
                let following = filteredFollowing
                let lookahead = following[index..<min(index + Self.artworkLookahead, following.count)]
                ArtworkCache.shared.prefetch(lookahead.compactMap { $0.largeAvatarURL ?? $0.avatarURL })
            }
        }
    }

    private static let artworkLookahead = 10
}

@MainActor
final class LibraryBrowserViewModel: ObservableObject {
    enum Section: String, CaseIterable, Hashable {
        case likes, sets, playlists, following

        var title: String {
            switch self {
            case .likes:     return "Likes"
            case .sets:      return "Sets"
            case .playlists: return "Playlists"
            case .following: return "Following"
            }
        }

        var indexLabel: String {
            title
        }

        var emptyIcon: String {
            switch self {
            case .likes:     return "heart"
            case .sets:      return "clock.arrow.2.circlepath"
            case .playlists: return "music.note.list"
            case .following: return "person.2"
            }
        }

        var emptyMessage: String {
            switch self {
            case .likes:     return "Tracks you like show up here."
            case .sets:      return "Long-form liked tracks show up here."
            case .playlists: return "Your playlists show up here."
            case .following: return "Artists you follow show up here."
            }
        }
    }

    enum SectionState: Equatable {
        case loading
        case loaded
        case empty
        case failed(LoadFailure)
    }

    @Published var selectedSection: Section = .likes
    @Published private(set) var likedTracks: [Track] = []
    @Published private(set) var likedAtByTrackID: [String: Date] = [:]
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var following: [User] = []
    @Published private(set) var sectionState: [Section: SectionState] = [:]

    @Published private(set) var loadingMore: Set<Section> = []

    private let api = SoundCloudAPI.shared

    private let cache = LibraryCache.shared
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(dateFormatter)
        return encoder
    }()
    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(dateFormatter)
        return decoder
    }()

    private var likesCursor     = PageCursor<Like<Track>>()
    private var playlistsCursor = PageCursor<Playlist>()
    private var followingCursor = PageCursor<User>()

    private var loadedSections: Set<Section> = []

    private var loadInFlight: Set<Section> = []

    func loadContentIfNeeded() async {
        guard !loadedSections.contains(selectedSection) else { return }
        await loadContent(for: selectedSection)
    }

    private static let cacheTTL: TimeInterval = 5 * 60

    func loadContent(for section: Section, forceRefresh: Bool = false) async {
        if section == .sets {
            await loadContent(for: .likes, forceRefresh: forceRefresh)
            return
        }
        guard SoundCloudCredentialSource.shared.accessToken != nil else {
            if sectionState[section] != .loaded {
                sectionState[section] = .failed(LoadFailure.credentialFailure())
            }
            return
        }
        guard sectionState[section] != .loading, !loadInFlight.contains(section) else { return }
        loadInFlight.insert(section)
        defer { loadInFlight.remove(section) }

        if sectionState[section] == nil {
            await hydrateFromCache(section)
        }

        if !forceRefresh, sectionState[section] == .loaded,
           let cachedAt = await cache.sectionCachedAt(section.rawValue),
           Date().timeIntervalSince(cachedAt) < Self.cacheTTL {
            loadedSections.insert(section)
            return
        }

        if sectionState[section] != .loaded {
            sectionState[section] = .loading
        }

        do {
            switch section {
            case .likes, .sets:
                let page = try await api.getLikedTracks(limit: 50)
                likedTracks = page.collection.map(\.item)
                for like in page.collection { likedAtByTrackID[like.item.id] = like.createdAt }
                likesCursor.advance(to: page)
                sectionState[.likes] = likedTracks.isEmpty ? .empty : .loaded
                await persistLikesCache(page.collection)

            case .playlists:
                guard let user = await SoundCloudCredentialSource.shared.waitForCurrentUser() else {
                    if sectionState[.playlists] != .loaded {
                        sectionState[.playlists] = .failed(LoadFailure.credentialFailure())
                    }
                    return
                }
                let page = try await api.getUserPlaylists(userId: user.id, limit: 50)
                playlists = page.collection
                playlistsCursor.advance(to: page)
                sectionState[.playlists] = playlists.isEmpty ? .empty : .loaded
                await persistCache(.playlists, items: page.collection, id: \.id)

            case .following:
                guard let user = await SoundCloudCredentialSource.shared.waitForCurrentUser() else {
                    if sectionState[.following] != .loaded {
                        sectionState[.following] = .failed(LoadFailure.credentialFailure())
                    }
                    return
                }
                let page = try await api.getUserFollowings(userId: user.id, limit: 50)
                following = page.collection
                followingCursor.advance(to: page)
                sectionState[.following] = following.isEmpty ? .empty : .loaded
                await persistCache(.following, items: page.collection, id: \.id)
            }
            loadedSections.insert(section)
        } catch {
            if error.isTaskCancellation {
                if sectionState[section] != .loaded { sectionState[section] = nil }
                return
            }
            if sectionState[section] != .loaded {
                sectionState[section] = .failed(LoadFailure.classify(error))
            }
        }
    }

    private func hydrateFromCache(_ section: Section) async {
        let rows = await cache.loadSection(section.rawValue)
        guard !rows.isEmpty else { return }

        switch section {
        case .likes, .sets:
            var tracks: [Track] = []
            var likedAt: [String: Date] = [:]
            for row in rows {
                guard let track = try? Self.jsonDecoder.decode(Track.self, from: row.payload) else { continue }
                tracks.append(track)
                if let millis = row.likedAtMillis {
                    likedAt[track.id] = Date(timeIntervalSince1970: Double(millis) / 1000)
                }
            }
            guard !tracks.isEmpty else { return }
            likedTracks = tracks
            likedAtByTrackID = likedAt

        case .playlists:
            let decoded = rows.compactMap { try? Self.jsonDecoder.decode(Playlist.self, from: $0.payload) }
            guard !decoded.isEmpty else { return }
            playlists = decoded

        case .following:
            let decoded = rows.compactMap { try? Self.jsonDecoder.decode(User.self, from: $0.payload) }
            guard !decoded.isEmpty else { return }
            following = decoded
        }
        sectionState[section] = .loaded
    }

    private func persistLikesCache(_ likes: [Like<Track>]) async {
        let rows: [LibraryCache.WriteRow] = likes.compactMap { like in
            guard let payload = try? Self.jsonEncoder.encode(like.item) else { return nil }
            return LibraryCache.WriteRow(
                id: like.item.id,
                payload: payload,
                likedAtMillis: Int64((like.createdAt.timeIntervalSince1970 * 1000).rounded())
            )
        }
        await cache.replaceSection(Section.likes.rawValue, rows: rows)
    }

    private func persistCache<T: Encodable>(_ section: Section, items: [T], id: (T) -> String) async {
        let rows: [LibraryCache.WriteRow] = items.compactMap { item in
            guard let payload = try? Self.jsonEncoder.encode(item) else { return nil }
            return LibraryCache.WriteRow(id: id(item), payload: payload)
        }
        await cache.replaceSection(section.rawValue, rows: rows)
    }

    func handleSignOut() async {
        await cache.clearAll()
    }

    func state(for section: Section) -> SectionState {
        if section == .sets { return state(for: .likes) }
        return sectionState[section] ?? .loading
    }

    func loadMore(section: Section) async {
        if section == .sets {
            await loadMore(section: .likes)
            return
        }
        guard !loadingMore.contains(section), canLoadMore(section) else { return }

        loadingMore.insert(section)
        defer { loadingMore.remove(section) }

        do {
            switch section {
            case .likes, .sets:
                guard let page = likesCursor.lastPage else { return }
                let next = try await api.getNextPage(page)
                likesCursor.advance(to: next)
                for like in next.collection { likedAtByTrackID[like.item.id] = like.createdAt }
                likedTracks.appendUnique(contentsOf: next.collection.map(\.item))

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
            Log.api.error("Library load-more error (\(section.rawValue, privacy: .public)): \(error, privacy: .public)")
        }
    }

    private func canLoadMore(_ section: Section) -> Bool {
        switch section {
        case .likes, .sets: return likesCursor.canLoadMore
        case .playlists: return playlistsCursor.canLoadMore
        case .following: return followingCursor.canLoadMore
        }
    }

    func count(for section: Section) -> Int {
        switch section {
        case .likes, .sets: return likedTracks.count
        case .playlists: return playlists.count
        case .following: return following.count
        }
    }

}

@MainActor
final class QueueConfirmationController: ObservableObject {
    struct Confirmation: Equatable {
        let message: String
        let icon: String
    }

    @Published private(set) var current: Confirmation?
    private var token = 0

    func show(_ message: String, icon: String = "checkmark.circle.fill") {
        token &+= 1
        let issued = token
        current = Confirmation(message: message, icon: icon)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.token == issued else { return }
            self.current = nil
        }
    }
}

extension View {
    func queueConfirmationOverlay(_ controller: QueueConfirmationController) -> some View {
        overlay(alignment: .bottom) {
            if let confirmation = controller.current {
                Label(confirmation.message, systemImage: confirmation.icon)
                    .font(.scSubhead)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.bottom, Spacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(SCContentMotion.gentle, value: controller.current)
    }
}

enum TrackRowActivity: Equatable {
    case none
    case loading
    case playing
    case paused
}

struct TrackListRow: View {
    let track: Track
    var analysis: TrackAnalysisSummary?
    let context: () -> [Track]
    var collectionId: String? = nil
    @ObservedObject var confirmation: QueueConfirmationController

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    var body: some View {
        TrackRow(
            track: track,
            analysis: analysis,
            activity: activity,
            play: { Task { await coordinator.playHere(track, in: context(), collectionId: collectionId) } },
            canPlayOnAppleTV: coordinator.isAppleTVAvailable,
            playOnAppleTV: sendToAppleTV,
            addToQueue: queue
        )
    }

    private var activity: TrackRowActivity {
        guard let snapshot = coordinator.nowPlaying, snapshot.trackId == track.id else { return .none }
        if snapshot.isLoading { return .loading }
        return snapshot.isPlaying ? .playing : .paused
    }

    private func sendToAppleTV() {
        coordinator.playOnAppleTV(track)
        confirmation.show("Playing \u{201C}\(track.title)\u{201D} on Apple TV", icon: "appletv.fill")
    }

    private func queue() {
        coordinator.addToQueue(track)
        confirmation.show("Added \u{201C}\(track.title)\u{201D} to queue")
    }
}

struct TrackRow: View {
    let track: Track
    var analysis: TrackAnalysisSummary?
    let activity: TrackRowActivity
    let play: () -> Void
    let canPlayOnAppleTV: Bool
    let playOnAppleTV: () -> Void
    let addToQueue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject private var downloadManager = DownloadManager.shared

    private var isPlayable: Bool { track.streamURL != nil }

    private var downloadState: DownloadState { downloadManager.state(for: track.id) }

    private var canDownload: Bool { isPlayable && downloadManager.downloadRefusalReason(for: track) == nil }

    var body: some View {
        Button(action: play) {
            HStack(spacing: Spacing.md) {
                ArtworkThumbnail(
                    url: track.artworkURL,
                    systemImage: "music.note",
                    identity: track.title,
                    crownUser: track.user,
                    crownContext: track.title
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.scBody)
                        .fontWeight(.semibold)
                        .foregroundStyle(activity == .none ? Color.primary : Color.scAccent)
                        .lineLimit(1)
                    Text(track.user.displayName)
                        .font(.scSubhead)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let analysis, !analysis.isEmpty {
                        analysis.badgeRow(style: .phone)
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: Spacing.sm)

                if isPlayable {
                    downloadStatusGlyph
                    activityGlyph

                    Text(track.formattedDuration)
                        .font(.scNumeric.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else {
                    Label("Unavailable", systemImage: "lock.fill")
                        .font(.scSubhead)
                        .foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
            .opacity(isPlayable ? 1 : 0.5)
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 52 + Spacing.md }
        .disabled(!isPlayable)
        .buttonStyle(.plain)
        .contextMenu { secondaryActions }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isPlayable {
                Button { addToQueue() } label: {
                    Label("Queue", systemImage: "text.append")
                }
                .tint(.scAccent)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if canDownload {
                downloadSwipeAction
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title) by \(track.user.displayName)\(isPlayable ? "" : ", unavailable")")
        .accessibilityHint(isPlayable ? "Plays on this device" : "This track isn't available to play")
        .accessibilityActions { secondaryActions }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if isPlayable {
            if canPlayOnAppleTV {
                Button { playOnAppleTV() } label: {
                    Label("Play on Apple TV", systemImage: "appletv")
                }
            }
            Button { addToQueue() } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            if canDownload {
                downloadMenuItems
            }
        }
    }

    @ViewBuilder
    private var downloadMenuItems: some View {
        switch downloadState {
        case .notDownloaded:
            Button { downloadManager.download(track) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        case .queued, .downloading:
            Button(role: .destructive) { downloadManager.cancel(trackId: track.id) } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        case .paused:
            Button { downloadManager.resume(trackId: track.id) } label: {
                Label("Resume Download", systemImage: "arrow.down.circle")
            }
            Button(role: .destructive) { downloadManager.cancel(trackId: track.id) } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        case .downloaded:
            Button(role: .destructive) { downloadManager.cancel(trackId: track.id) } label: {
                Label("Remove Download", systemImage: "trash")
            }
        case .failed:
            Button { downloadManager.download(track) } label: {
                Label("Retry Download", systemImage: "arrow.clockwise")
            }
        }
    }

    @ViewBuilder
    private var downloadSwipeAction: some View {
        switch downloadState {
        case .notDownloaded, .failed:
            Button { downloadManager.download(track) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .tint(.scAccent)
        case .queued, .downloading, .paused:
            Button { downloadManager.cancel(trackId: track.id) } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .tint(.scDestructive)
        case .downloaded:
            Button(role: .destructive) { downloadManager.cancel(trackId: track.id) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var downloadStatusGlyph: some View {
        switch downloadState {
        case .notDownloaded:
            EmptyView()
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        case .downloading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .tint(.scAccent)
        case .paused:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.scAccent)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.scDestructive)
        }
    }

    @ViewBuilder
    private var activityGlyph: some View {
        switch activity {
        case .none:
            EmptyView()
        case .loading:
            ProgressView()
                .controlSize(.small)
                .tint(.scAccent)
        case .playing:
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.scAccent)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.scAccent.opacity(0.7))
        }
    }

}

struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: Spacing.md) {
            PlaylistArtworkView(
                identity: playlist.title,
                artworkURL: playlist.artworkURL,
                trackArtworkURLs: (playlist.tracks ?? []).compactMap(\.artworkURL),
                style: .phone
            )
            .frame(width: 52, height: 52)
            .kyleCrowned(user: playlist.user, context: playlist.title)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title)
                    .font(.scBody)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("\(playlist.trackCount) tracks \u{00B7} \(playlist.user.displayName)")
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.sm)
        }
        .padding(.vertical, Spacing.xs)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 52 + Spacing.md }
    }
}

struct UserRow: View {
    let user: User

    var body: some View {
        HStack(spacing: Spacing.md) {
            ArtworkThumbnail(
                url: user.avatarURL,
                systemImage: "person.fill",
                isCircle: true,
                crownUser: user,
                crownContext: user.displayName
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(user.displayName)
                    .font(.scBody)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("\(user.formattedFollowers) followers")
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.sm)
        }
        .padding(.vertical, Spacing.xs)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 52 + Spacing.md }
    }
}

struct LoadingMoreRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView().tint(.scAccent)
            Spacer()
        }
        .padding(.vertical, Spacing.sm)
        .listRowSeparator(.hidden)
    }
}

struct ArtworkThumbnail: View {
    let url: URL?
    var systemImage: String = "music.note"
    var isCircle: Bool = false
    var size: CGFloat = 52
    var cornerRadius: CGFloat = Radius.sm
    var identity: String?
    var crownUser: User?
    var crownContext: String?

    var body: some View {
        AsyncImage(url: Self.thumbnailURL(url)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                if let identity, !identity.isEmpty {
                    GeneratedArtworkCard(
                        identity: identity,
                        mode: .blob,
                        style: .phone,
                        isAnimated: size >= 44
                    )
                } else {
                    ZStack {
                        Color.primary.opacity(0.08)
                        Image(systemName: systemImage)
                            .font(.system(size: size * 0.34))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(isCircle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        .kyleCrowned(user: crownUser, context: crownContext)
    }

    private static func thumbnailURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        return URL(string: url.absoluteString.replacingOccurrences(of: "-large", with: "-t200x200")) ?? url
    }
}

struct LoadingState: View {
    let message: String

    var body: some View {
        VStack(spacing: Spacing.md) {
            Spacer(minLength: 60)
            ProgressView()
                .controlSize(.large)
                .tint(.scAccent)
            Text(message)
                .font(.scSubhead)
                .foregroundStyle(.secondary)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
    }
}

struct StateMessage<Action: View>: View {
    let icon: String
    let title: String
    let message: String?
    let action: () -> Action

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounced = false

    init(
        icon: String,
        title: String,
        message: String? = nil,
        @ViewBuilder action: @escaping () -> Action
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            Spacer(minLength: 40)

            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.scAccent.gradient)
                .symbolEffect(.bounce, value: bounced)

            Text(title)
                .font(.scTitle)

            if let message {
                Text(message)
                    .font(.scBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            action()

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
        .task {
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(200))
            bounced = true
        }
    }
}

extension StateMessage where Action == EmptyView {
    init(icon: String, title: String, message: String? = nil) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}

#Preview {
    NavigationStack {
        LibraryBrowserView()
    }
    .environmentObject(PhonePlaybackCoordinator(client: CompanionClient()))
    .preferredColorScheme(.dark)
}
