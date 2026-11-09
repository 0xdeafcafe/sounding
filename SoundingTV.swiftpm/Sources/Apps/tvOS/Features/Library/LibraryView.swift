import SwiftUI
import Combine

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var navigationState: NavigationState
    @ObservedObject private var router = LibraryRouter.shared
    @AppStorage("library.tv.page") private var page: LibraryFilter = .recentlyAdded
    @State private var path: [LibraryFilter] = []
    @State private var socialPage: SocialSection?
    @State private var appliedLaunchRoute = false

    var body: some View {
        Group {
            if authService.isAuthenticated {
                authenticatedView
            } else {
                NavigationStack { SignedOutLibraryView() }
                    .background { BrowseBackdrop() }
            }
        }
        .onChange(of: authService.isAuthenticated) { wasAuthenticated, isAuthenticated in
            if wasAuthenticated, !isAuthenticated {
                path = []
                Task { await viewModel.handleSignOut() }
            }
        }
    }

    private var authenticatedView: some View {
        NavigationStack(path: $path) {
            LibrarySplitView(viewModel: viewModel, page: $page) { socialPage = $0 }
                .navigationDestination(for: LibraryFilter.self) { filter in
                    LibraryDetailView(filter: filter, viewModel: viewModel)
                }
                .navigationDestination(item: $socialPage) { section in
                    TVSocialPage(section: section)
                }
        }
        .onChange(of: navigationState.socialRequest, initial: true) { _, request in
            guard let request else { return }
            path = []
            socialPage = request
            navigationState.socialRequest = nil
        }
        .onChange(of: navigationState.selectedTab) { _, tab in
            if tab == .library {
                Task { await viewModel.refreshShelvesIfStale() }
            }
        }
        .onChange(of: router.request, initial: true) { _, request in
            guard let request else { return }
            open(request)
            router.request = nil
        }
        .onAppear(perform: applyLaunchRoute)
        .background { BrowseBackdrop() }
    }

    private func open(_ filter: LibraryFilter) {
        if LibraryFilter.sidebarOrder.contains(filter) {
            page = filter
            path = []
        } else if filter == .likes {
            page = .playlists
            path = [.likes]
        } else {
            path = [filter]
        }
    }

    private func applyLaunchRoute() {
        guard !appliedLaunchRoute else { return }
        appliedLaunchRoute = true
        if let filter = LibraryViewModel.launchRoute() { open(filter) }
    }
}

@MainActor
final class LibraryRouter: ObservableObject {
    static let shared = LibraryRouter()

    @Published var request: LibraryFilter?

    func open(_ filter: LibraryFilter, navigationState: NavigationState) {
        request = filter
        navigationState.selectedTab = .library
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable, Hashable {
    case recentlyAdded
    case likes
    case sets
    case playlists
    case albums
    case following
    case setlists
    case downloads
    case songs
    case artists
    case yourMusic
    case mixes
    case history

    var id: String { rawValue }

    static let sidebarOrder: [LibraryFilter] = [
        .recentlyAdded, .history, .songs, .albums, .artists, .playlists, .sets, .setlists, .downloads, .mixes, .yourMusic,
    ]

    var label: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .likes:         return "Likes"
        case .sets:          return "Sets"
        case .playlists:     return "Playlists"
        case .albums:        return "Albums"
        case .following:     return "Following"
        case .setlists:      return "Setlists"
        case .downloads:     return "Downloads"
        case .songs:         return "Tracks"
        case .artists:       return "Artists"
        case .yourMusic:     return "Your Music"
        case .mixes:         return "Mixes"
        case .history:       return "History"
        }
    }

    var icon: String {
        switch self {
        case .recentlyAdded: return SidebarSymbol.recentlyAdded
        case .likes:         return SidebarSymbol.likes
        case .sets:          return SidebarSymbol.sets
        case .playlists:     return SidebarSymbol.allPlaylists
        case .albums:        return SidebarSymbol.albums
        case .following:     return SidebarSymbol.following
        case .artists:       return SidebarSymbol.artists
        case .setlists:      return SidebarSymbol.setlists
        case .downloads:     return SidebarSymbol.downloads
        case .songs:         return SidebarSymbol.tracks
        case .yourMusic:     return SidebarSymbol.yourMusic
        case .mixes:         return SidebarSymbol.mixes
        case .history:       return SidebarSymbol.history
        }
    }

    var isPeople: Bool { self == .following }

    var emptyTitle: String {
        switch self {
        case .recentlyAdded: return "Nothing Added Yet"
        case .likes:         return "No Likes Yet"
        case .sets:          return "No Sets Yet"
        case .playlists:     return "No Playlists Yet"
        case .albums:        return "No Albums Yet"
        case .following:     return "Not Following Anyone"
        case .artists:       return "No Artists Yet"
        case .setlists:      return "No Setlists Yet"
        case .downloads:     return "No Downloads"
        case .songs:         return "No Tracks Yet"
        case .yourMusic:     return "No Music on Your Devices"
        case .mixes:         return "No Mixes Yet"
        case .history:       return "No Listening History"
        }
    }

    var emptyMessage: String {
        switch self {
        case .recentlyAdded: return "Tracks you like, playlists you make or like, people you follow and music you add appear here."
        case .likes:         return "Tracks you like will appear here."
        case .sets:          return "Long mixes you like will appear here."
        case .playlists:     return "Your playlists will appear here."
        case .albums:        return "Albums you like and albums on your devices will appear here."
        case .following:     return "Artists you follow will appear here."
        case .artists:       return "Artists from music on your devices will appear here."
        case .setlists:      return "Mixes with a saved tracklist will appear here."
        case .downloads:     return "Downloaded music plays without a connection."
        case .songs:         return "Tracks you save will appear here."
        case .yourMusic:     return "Music folders on your linked Mac, iPhone or iPad appear here."
        case .mixes:         return "Transitions Auto Mix plays show up here, so you can save the good ones."
        case .history:       return "Tracks you play appear here."
        }
    }

    var dataSection: LibrarySection? {
        switch self {
        case .recentlyAdded: return .recentlyAdded
        case .likes, .sets, .songs, .setlists: return .likes
        case .playlists, .albums: return .playlists
        case .following: return .following
        case .downloads, .yourMusic, .artists, .mixes, .history: return nil
        }
    }
}

enum LibrarySection: String, CaseIterable {
    case recentlyAdded = "RecentlyAdded"
    case likes     = "Liked"
    case playlists = "Playlists"
    case following = "Following"
}

private enum LibraryLoadError: Error {
    case accountUnavailable

    var message: String { "Couldn't load your account details." }
}

private enum LikesLocalSource {
    case none
    case index
    case cache
}

private extension PagedSource {
    static var placeholder: PagedSource {
        PagedSource(first: { PagedChunk(items: []) }, next: { _ in PagedChunk(items: []) })
    }
}

@MainActor
class LibraryViewModel: ObservableObject {
    @Published private(set) var recentlyAddedAttempted = false
    @Published var recentlyAddedLoading = false
    @Published var recentlyAddedError: String?
    @Published var isLoading = false
    @Published var errorMessage: String?


    @Published var likedAtByTrackID: [String: Date] = [:]

    @Published private(set) var attempted: Set<LibrarySection> = []
    @Published private(set) var firstSyncSettled = false

    let recentlyAddedPager = Paginator<LibraryItem>(soundCloudSource: .placeholder)
    let recentlyAddedFeed = RecentlyAddedModel()
    let likesPager = Paginator<Track>(source: .placeholder, maxUnattendedPages: 1_000)
    let playlistsPager = Paginator<Playlist>(source: .placeholder, maxUnattendedPages: 1_000)
    let followingPager = Paginator<User>(source: .placeholder, maxUnattendedPages: 1_000)
    let likedPlaylistsPager = Paginator<Playlist>(source: .placeholder, maxUnattendedPages: 1_000)

    var recentlyAdded: [LibraryItem] { recentlyAddedPager.items }
    var likedTracks: [Track] { likesPager.items }
    var playlists: [Playlist] { playlistsPager.items }
    var following: [User] { followingPager.items }
    var likedPlaylists: [Playlist] { likedPlaylistsPager.items }

    private let api = SoundCloudAPI.shared
    private var lastLoaded: [LibrarySection: Date] = [:]
    private var didLoadLikedPlaylists = false

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
    private static let cachePageSize = 100

    private let staleAfter: TimeInterval = 5 * 60

    private var likesLocalSource: LikesLocalSource = .none
    private var cancellables: [AnyCancellable] = []
    private let createdAtReference = Date()

    init() {
        forward(recentlyAddedPager)
        forward(recentlyAddedFeed)
        forward(likesPager)
        forward(playlistsPager)
        forward(followingPager)
        forward(likedPlaylistsPager)
        configureSources()
        LibrarySyncEngine.shared.$revision
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refreshFromDatabase() }
            }
            .store(in: &cancellables)
        LibrarySyncEngine.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        LibrarySyncEngine.shared.$hasFinishedFirstRun
            .removeDuplicates()
            .sink { [weak self] finished in
                Task { @MainActor in await self?.syncRunDidChange(finished: finished) }
            }
            .store(in: &cancellables)
    }

    private func syncRunDidChange(finished: Bool) async {
        guard finished else {
            firstSyncSettled = false
            return
        }
        guard !firstSyncSettled else { return }
        if attempted.contains(.likes) { await likesPager.reload() }
        if attempted.contains(.playlists) {
            await playlistsPager.reload()
            if didLoadLikedPlaylists { await likedPlaylistsPager.reload() }
        }
        if attempted.contains(.following) { await followingPager.reload() }
        firstSyncSettled = true
    }

    private var firstSyncPending: Bool {
        AuthenticationService.shared.isAuthenticated && !firstSyncSettled
    }

    private func awaitingSync(_ collection: LibraryCollection) -> Bool {
        if firstSyncPending { return true }
        if LibrarySyncEngine.shared.lastRunFailed { return false }
        return LibrarySyncEngine.shared.isAwaitingFirstSync(collection)
    }

    var syncErrorMessage: String? {
        guard firstSyncSettled, LibrarySyncEngine.shared.lastRunFailed, libraryIsEmpty else { return nil }
        return "Couldn't reach SoundCloud. Check this Apple TV's network connection."
    }

    private func refreshFromDatabase() async {
        let changed = LibrarySyncEngine.shared.lastChanged
        if changed.contains(.likes), likesPager.hasLoadedFirst {
            let page = await LibraryDB.tracks(.likes, offset: 0, limit: max(Self.cachePageSize, likesPager.items.count))
            let total = await LibraryDB.count(.likes)
            likedAtByTrackID.merge(page.likedAt) { _, latest in latest }
            likesPager.prime(items: page.tracks, cursor: page.rowCount < total ? .offset(page.rowCount) : nil, total: total)
        }
        if changed.contains(.ownPlaylists), playlistsPager.hasLoadedFirst {
            let page = await LibraryDB.playlists(.ownPlaylists, offset: 0, limit: max(Self.cachePageSize, playlistsPager.items.count))
            let total = await LibraryDB.count(.ownPlaylists)
            playlistsPager.prime(items: page.playlists, cursor: page.rowCount < total ? .offset(page.rowCount) : nil, total: total)
        }
        if changed.contains(.likedPlaylists), likedPlaylistsPager.hasLoadedFirst {
            let page = await LibraryDB.playlists(.likedPlaylists, offset: 0, limit: max(Self.cachePageSize, likedPlaylistsPager.items.count))
            let total = await LibraryDB.count(.likedPlaylists)
            likedPlaylistsPager.prime(items: page.playlists, cursor: page.rowCount < total ? .offset(page.rowCount) : nil, total: total)
        }
        if changed.contains(.followings), followingPager.hasLoadedFirst {
            let page = await LibraryDB.users(.followings, offset: 0, limit: max(Self.cachePageSize, followingPager.items.count))
            let total = await LibraryDB.count(.followings)
            followingPager.prime(items: page.users, cursor: page.rowCount < total ? .offset(page.rowCount) : nil, total: total)
        }
    }

    private func forward<Object: ObservableObject>(_ object: Object) where Object.ObjectWillChangePublisher == ObservableObjectPublisher {
        object.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func configureSources() {
        recentlyAddedPager.setSource(PagedSource(
            first: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.fetchRecentlyAddedFirst()
            },
            next: { [weak self] cursor in
                guard let self else { throw CancellationError() }
                return try await self.fetchRecentlyAdded(after: cursor)
            }
        ))
        likesPager.setSource(LibraryDB.trackSource(.likes, onLikedAt: { [weak self] likedAt in
            self?.likedAtByTrackID.merge(likedAt) { _, latest in latest }
        }))
        playlistsPager.setSource(LibraryDB.playlistSource(.ownPlaylists))
        followingPager.setSource(LibraryDB.userSource(.followings))
        likedPlaylistsPager.setSource(LibraryDB.playlistSource(.likedPlaylists))
    }

    static func launchRoute() -> LibraryFilter? {
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
        return nil
    }

    var librarySongTracks: [Track] {
        var seen = Set<String>()
        let recentlySaved = recentlyAdded.compactMap(\.track)
        return (recentlySaved + likedTracks).filter { seen.insert($0.id).inserted }
    }

    var libraryPlaylists: [Playlist] {
        mergedCollections.filter { !$0.isAlbum }
    }

    var libraryAlbums: [Playlist] {
        mergedCollections.filter(\.isAlbum)
    }

    var albumItems: [LibraryGridItem] {
        LibraryCollectionsModel.albumItems(soundCloud: libraryAlbums, localTracks: RemoteLocalMusic.shared.allTracks)
    }

    var artistItems: [LibraryGridItem] {
        LibraryCollectionsModel.artistItems(localTracks: RemoteLocalMusic.shared.allTracks)
    }

    private var mergedCollections: [Playlist] {
        var seen = Set<String>()
        return (likedPlaylists + playlists).filter { seen.insert($0.id).inserted }
    }

    func sets(minimumDuration: Double) -> [Track] {
        GeneratedLibraryCollections.sets(from: likedTracks, minimumDuration: minimumDuration)
    }

    func loadAllLikes() async {
        await TrackCollectionLoader.loadAll(likesPager)
    }

    func loadAllCollections() async {
        await TrackCollectionLoader.loadAll(playlistsPager)
        await TrackCollectionLoader.loadAll(likedPlaylistsPager)
    }

    var likesPaging: TVPaging? { TVPaging(likesPager) }
    var followingPaging: TVPaging? { TVPaging(followingPager) }
    var collectionsPaging: TVPaging? { .combining([TVPaging(playlistsPager), TVPaging(likedPlaylistsPager)]) }

    func countText(_ count: Int, singular: String, plural: String, hasMore: Bool) -> String {
        let number = count.formatted(.number)
        return "\(number)\(hasMore ? "+" : "") \(count == 1 && !hasMore ? singular : plural)"
    }

    func totalText(_ filter: LibraryFilter, count: Int?) -> String? {
        switch filter {
        case .likes:
            guard !likedTracks.isEmpty || likesPager.hasLoadedFirst else { return nil }
            return likesPager.countText(singular: "track", plural: "tracks")
        case .recentlyAdded:
            let count = recentlyAddedFeed.items.count
            guard count > 0 else { return nil }
            return countText(count, singular: "item", plural: "items", hasMore: false)
        case .following:
            guard !following.isEmpty else { return nil }
            return followingPager.countText(singular: "artist", plural: "artists")
        case .artists:
            return countText(count ?? artistItems.count, singular: "artist", plural: "artists", hasMore: false)
        case .playlists:
            return countText(count ?? libraryPlaylists.count, singular: "playlist", plural: "playlists", hasMore: collectionsHaveMore)
        case .albums:
            return countText(count ?? albumItems.count, singular: "album", plural: "albums", hasMore: collectionsHaveMore)
        case .sets:
            return countText(count ?? sets(minimumDuration: SettingsStore.shared.setMinimumDurationSeconds).count, singular: "set", plural: "sets", hasMore: likesPager.hasMore)
        case .songs, .setlists, .downloads, .yourMusic:
            guard let count else { return nil }
            return countText(count, singular: "track", plural: "tracks", hasMore: false)
        case .mixes:
            return countText(count ?? MixHistoryStore.shared.collectedCount, singular: "mix", plural: "mixes", hasMore: false)
        case .history:
            return nil
        }
    }

    var collectionsHaveMore: Bool { playlistsPager.hasMore || likedPlaylistsPager.hasMore }

    func awaitingFirstPage(_ section: LibrarySection) -> Bool {
        switch section {
        case .recentlyAdded: return recentlyAddedPager.isPaused && !recentlyAddedPager.hasLoadedFirst
        case .likes:         return (likesPager.isPaused && !likesPager.hasLoadedFirst) || (likedTracks.isEmpty && awaitingSync(.likes))
        case .playlists:     return (playlistsPager.isPaused && !playlistsPager.hasLoadedFirst) || (mergedCollections.isEmpty && awaitingSync(.ownPlaylists))
        case .following:     return (followingPager.isPaused && !followingPager.hasLoadedFirst) || (following.isEmpty && awaitingSync(.followings))
        }
    }

    func isFirstPageLoading(_ filter: LibraryFilter) -> Bool {
        switch filter.dataSection {
        case .recentlyAdded?:
            return recentlyAddedFeed.showsLoading || (recentlyAddedFeed.items.isEmpty && firstSyncPending)
        case let section?:
            return (isLoading && !attempted.isEmpty) || !attempted.contains(section) || awaitingFirstPage(section)
        case nil:
            return false
        }
    }

    func pageError(_ filter: LibraryFilter) -> String? {
        switch filter.dataSection {
        case .recentlyAdded?: return recentlyAddedError ?? syncErrorMessage
        case .some: return errorMessage ?? syncErrorMessage
        case nil: return nil
        }
    }

    var libraryIsEmpty: Bool {
        recentlyAdded.isEmpty && recentlyAddedFeed.items.isEmpty && likedTracks.isEmpty && mergedCollections.isEmpty && following.isEmpty
    }

    func load(filter: LibraryFilter) async {
        #if DEBUG
        if VisualFixtures.isEnabled {
            installVisualFixtures()
            return
        }
        #endif

        switch filter {
        case .recentlyAdded:
            await recentlyAddedFeed.load()
        case .likes, .sets, .setlists:
            await loadSectionIfNeeded(.likes)
        case .songs:
            await loadSectionIfNeeded(.likes)
            await loadRecentlyAddedIfNeeded()
        case .playlists, .albums:
            await loadSectionIfNeeded(.playlists)
            await loadLikedPlaylistsIfNeeded()
        case .following:
            await loadSectionIfNeeded(.following)
        case .artists:
            RemoteLocalMusic.shared.refreshIfNeeded()
        case .downloads, .mixes:
            break
        case .history:
            await ListeningHistory.shared.load()
        case .yourMusic:
            RemoteLocalMusic.shared.refreshIfNeeded()
        }
    }

    func reloadAllShelves() async {
        attempted.removeAll()
        lastLoaded.removeAll()
        recentlyAddedAttempted = false
        didLoadLikedPlaylists = false
        errorMessage = nil
        recentlyAddedError = nil
        await load(filter: .recentlyAdded)
        await load(filter: .likes)
    }

    func refreshShelvesIfStale() async {
        #if DEBUG
        if VisualFixtures.isEnabled { return }
        #endif
        await refreshRecentlyAddedIfStale()
        for section in [LibrarySection.likes, .playlists, .following] where lastLoaded[section] != nil {
            await refreshSectionIfStale(section)
        }
    }

    #if DEBUG
    private func installVisualFixtures() {
        guard !fixturesInstalled else { return }
        fixturesInstalled = true
        let state = ProcessInfo.processInfo.environment["SOUNDING_TV_LIBRARY_STATE"]
        switch state {
        case "empty":
            for pager in [likesPager] { pager.prime(items: [], cursor: nil) }
        case "loading":
            return
        case "error":
            errorMessage = "Couldn't reach SoundCloud. Check this Apple TV's network connection."
        default:
            recentlyAddedPager.prime(items: VisualFixtures.libraryItems, cursor: nil)
            likesPager.prime(items: Self.fixtureLikes, cursor: nil, total: Self.fixtureLikes.count)
            followingPager.prime(items: VisualFixtures.artists, cursor: nil)
            playlistsPager.prime(items: VisualFixtures.playlists, cursor: nil)
            likedPlaylistsPager.prime(items: VisualFixtures.albums, cursor: nil)
        }
        recentlyAddedAttempted = true
        attempted = Set(LibrarySection.allCases)
        recentlyAddedError = nil
        for section in LibrarySection.allCases { lastLoaded[section] = Date() }
    }

    private var fixturesInstalled = false

    private static let fixtureLikes: [Track] = {
        guard let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_LIBRARY_LIKES"], let count = Int(raw) else {
            return VisualFixtures.tracks + [VisualFixtures.nowPlayingMix]
        }
        let base = VisualFixtures.tracks
        return (0..<count).compactMap { index in
            var track = base[index % base.count]
            guard let data = try? JSONEncoder().encode(track),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            json["id"] = 50_000 + index
            json["title"] = "\(track.title) \(index / base.count + 1)"
            guard let patched = try? JSONSerialization.data(withJSONObject: json),
                  let decoded = try? JSONDecoder().decode(Track.self, from: patched) else { return nil }
            track = decoded
            return track
        }
    }()
    #endif

    private func loadSectionIfNeeded(_ section: LibrarySection) async {
        guard lastLoaded[section] == nil, !attempted.contains(section) else { return }
        await load(section: section)
    }

    private func refreshSectionIfStale(_ section: LibrarySection) async {
        guard let loaded = lastLoaded[section], Date().timeIntervalSince(loaded) <= staleAfter else {
            await load(section: section)
            return
        }
    }

    private func load(section: LibrarySection) async {
        guard AuthenticationService.shared.isAuthenticated else { return }

        attempted.insert(section)

        LikesSyncEngine.shared.activate()
        switch section {
        case .likes: LibrarySyncEngine.shared.prioritise([.likes])
        case .playlists: LibrarySyncEngine.shared.prioritise([.ownPlaylists, .likedPlaylists])
        case .following: LibrarySyncEngine.shared.prioritise([.followings])
        case .recentlyAdded: LibrarySyncEngine.shared.kick()
        }

        if lastLoaded[section] == nil, section == .recentlyAdded {
            await hydrateFromCache(section)
        }

        switch section {
        case .recentlyAdded: return
        case .likes:         await reloadFirstPage(likesPager)
        case .playlists:     await reloadFirstPage(playlistsPager)
        case .following:     await reloadFirstPage(followingPager)
        }
    }

    private func reloadFirstPage<Item: Identifiable>(_ pager: Paginator<Item>) async {
        guard !pager.isLoadingFirst else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        await pager.reload()

        guard let error = pager.firstError, pager.items.isEmpty else { return }
        errorMessage = (error as? LibraryLoadError)?.message
            ?? "Couldn't reach SoundCloud. Check this Apple TV's network connection."
    }

    private var likesTotal: Int? {
        SoundCloudCredentialSource.shared.currentUser?.publicFavoritesCount.flatMap { $0 > 0 ? $0 : nil }
    }

    private var followingTotal: Int? {
        SoundCloudCredentialSource.shared.currentUser.flatMap { $0.followingsCount > 0 ? $0.followingsCount : nil }
    }

    private static func isVisible(_ item: LibraryItem) -> Bool {
        item.track != nil || item.playlist != nil || item.systemPlaylist != nil
    }

    private static func continuation(
        consumed: Int,
        pageFull: Bool,
        state: LibraryCache.SectionState
    ) -> PagedCursor? {
        if pageFull, state.itemCount > consumed { return .offset(consumed) }
        return state.nextHref.map(PagedCursor.url)
    }

    private func cachedPage<T: Decodable>(
        _ key: String,
        offset: Int,
        as type: T.Type
    ) async -> (items: [T], rows: [LibraryCache.Row], next: PagedCursor?) {
        let rows = libraryCache.loadSection(key, offset: offset, limit: Self.cachePageSize)
        let state = await libraryCache.sectionState(key)
        let items = rows.compactMap { try? Self.cacheDecoder.decode(T.self, from: $0.payload) }
        let next = Self.continuation(
            consumed: offset + rows.count,
            pageFull: rows.count == Self.cachePageSize,
            state: state
        )
        return (items, rows, next)
    }

    private func hydrateFromCache(_ section: LibrarySection) async {
        switch section {
        case .recentlyAdded:
            let head = await cachedPage(section.rawValue, offset: 0, as: LibraryItem.self)
            guard !head.items.isEmpty else { return }
            recentlyAddedPager.prime(items: head.items, cursor: head.next)

        case .likes:
            if await rehydrateLikesFromIndex() { return }
            let head = await cachedPage(section.rawValue, offset: 0, as: Track.self)
            let tracks = decodeLikes(head.rows)
            guard !tracks.isEmpty else { return }
            likesLocalSource = .cache
            likesPager.prime(items: tracks, cursor: head.next, total: likesTotal)
            logLikesContent(count: tracks.count, source: "section cache")

        case .playlists:
            let head = await cachedPage(section.rawValue, offset: 0, as: Playlist.self)
            guard !head.items.isEmpty else { return }
            playlistsPager.prime(items: head.items, cursor: head.next)

        case .following:
            let head = await cachedPage(section.rawValue, offset: 0, as: User.self)
            guard !head.items.isEmpty else { return }
            followingPager.prime(items: head.items, cursor: head.next, total: followingTotal)
        }
    }

    private func decodeLikes(_ rows: [LibraryCache.Row]) -> [Track] {
        var tracks: [Track] = []
        for row in rows {
            guard let track = try? Self.cacheDecoder.decode(Track.self, from: row.payload) else { continue }
            tracks.append(track)
            if let millis = row.likedAtMillis {
                likedAtByTrackID[track.id] = Date(timeIntervalSince1970: Double(millis) / 1000)
            }
        }
        return tracks
    }

    private func likesContinuation(base: Int = 0, count: Int, requested: Int, complete: Bool) async -> PagedCursor? {
        if count >= requested, count > 0 { return .offset(base + count) }
        if complete { return nil }
        return await libraryCache.sectionState(LibrarySection.likes.rawValue).nextHref.map(PagedCursor.url)
    }

    @discardableResult
    private func rehydrateLikesFromIndex() async -> Bool {
        guard AuthenticationService.shared.isAuthenticated else { return false }
        let wasIndex = likesLocalSource == .index
        guard !likesPager.isLoadingFirst, !likesPager.isLoadingMore else { return wasIndex }

        let engine = LikesSyncEngine.shared
        let complete = await engine.indexCompletedAt() != nil
        let requested = max(Self.cachePageSize, wasIndex ? min(likesPager.items.count, 2000) : 0)
        let indexed = await engine.indexedLikes(limit: requested)
        guard !indexed.tracks.isEmpty else { return wasIndex }
        let next = await likesContinuation(count: indexed.tracks.count, requested: requested, complete: complete)
        guard !likesPager.isLoadingFirst, !likesPager.isLoadingMore else { return wasIndex }

        likedAtByTrackID.merge(indexed.likedAt) { _, incoming in incoming }
        likesLocalSource = .index
        likesPager.prime(items: indexed.tracks, cursor: next, total: likesTotal)
        logLikesContent(count: indexed.tracks.count, source: complete ? "index head (complete)" : "index head (partial)")
        return true
    }

    private func logLikesContent(count: Int, source: String) {
        #if DEBUG
        let elapsed = Date().timeIntervalSince(createdAtReference) * 1000
        print(String(format: "[Perf] likes content: %d track(s) from %@ at +%.0fms after VM init", count, source, elapsed))
        #endif
    }

    private func fetchLikesFirst() async throws -> PagedChunk<Track> {
        let result = try await api.getLikedTracks(limit: Self.cachePageSize)
        for like in result.collection { likedAtByTrackID[like.item.id] = like.createdAt }
        await LikesSyncEngine.shared.integrate(firstPage: result.collection)
        await libraryCache.markSectionProgress(
            LibrarySection.likes.rawValue,
            nextHref: result.nextHref,
            completed: result.nextHref == nil
        )
        lastLoaded[.likes] = Date()

        let engine = LikesSyncEngine.shared
        let indexed = await engine.indexedLikes(limit: Self.cachePageSize)
        if !indexed.tracks.isEmpty {
            likedAtByTrackID.merge(indexed.likedAt) { _, incoming in incoming }
            likesLocalSource = .index
            let complete = await engine.indexCompletedAt() != nil
            let next = await likesContinuation(count: indexed.tracks.count, requested: Self.cachePageSize, complete: complete)
            return PagedChunk(items: indexed.tracks, next: next, total: likesTotal)
        }

        likesLocalSource = .none
        await mergeLikesCache(result.collection)
        return PagedChunk(
            items: result.collection.map(\.item),
            next: result.nextHref.map(PagedCursor.url),
            total: likesTotal
        )
    }

    private func fetchLikes(after cursor: PagedCursor) async throws -> PagedChunk<Track> {
        switch cursor {
        case .start:
            return try await fetchLikesFirst()
        case .offset(let offset):
            if likesLocalSource == .index {
                let engine = LikesSyncEngine.shared
                let indexed = await engine.indexedLikes(offset: offset, limit: Self.cachePageSize)
                likedAtByTrackID.merge(indexed.likedAt) { _, incoming in incoming }
                let complete = await engine.indexCompletedAt() != nil
                let next = await likesContinuation(
                    base: offset,
                    count: indexed.tracks.count,
                    requested: Self.cachePageSize,
                    complete: complete
                )
                return PagedChunk(items: indexed.tracks, next: next, total: likesTotal)
            }
            let page = await cachedPage(LibrarySection.likes.rawValue, offset: offset, as: Track.self)
            return PagedChunk(items: decodeLikes(page.rows), next: page.next, total: likesTotal)
        case .url(let url):
            let page = try await api.getPage(Like<Track>.self, from: url)
            for like in page.collection { likedAtByTrackID[like.item.id] = like.createdAt }
            await LikesSyncEngine.shared.integrate(laterPage: page.collection)
            await mergeLikesCache(page.collection)
            await libraryCache.markSectionProgress(
                LibrarySection.likes.rawValue,
                nextHref: page.nextHref,
                completed: page.nextHref == nil
            )
            return PagedChunk(
                items: page.collection.map(\.item),
                next: page.nextHref.map(PagedCursor.url),
                total: likesTotal
            )
        }
    }

    private func fetchPlaylistsFirst() async throws -> PagedChunk<Playlist> {
        guard let user = await AuthenticationService.shared.waitForCurrentUser() else {
            throw LibraryLoadError.accountUnavailable
        }
        let page = try await api.getUserPlaylists(userId: user.id, limit: 50)
        await persistCache(LibrarySection.playlists.rawValue, items: page.collection, id: \.id)
        await libraryCache.markSectionProgress(
            LibrarySection.playlists.rawValue,
            nextHref: page.nextHref,
            completed: page.nextHref == nil
        )
        lastLoaded[.playlists] = Date()
        return PagedChunk(items: page.collection, next: page.nextHref.map(PagedCursor.url))
    }

    private func fetchPlaylists(after cursor: PagedCursor) async throws -> PagedChunk<Playlist> {
        try await fetchSection(
            cursor,
            key: LibrarySection.playlists.rawValue,
            as: Playlist.self,
            first: fetchPlaylistsFirst
        )
    }

    private func fetchFollowingFirst() async throws -> PagedChunk<User> {
        guard let user = await AuthenticationService.shared.waitForCurrentUser() else {
            throw LibraryLoadError.accountUnavailable
        }
        let page = try await api.getUserFollowings(userId: user.id, limit: 100)
        await persistCache(LibrarySection.following.rawValue, items: page.collection, id: \.id)
        await libraryCache.markSectionProgress(
            LibrarySection.following.rawValue,
            nextHref: page.nextHref,
            completed: page.nextHref == nil
        )
        lastLoaded[.following] = Date()
        return PagedChunk(items: page.collection, next: page.nextHref.map(PagedCursor.url), total: followingTotal)
    }

    private func fetchFollowing(after cursor: PagedCursor) async throws -> PagedChunk<User> {
        try await fetchSection(
            cursor,
            key: LibrarySection.following.rawValue,
            as: User.self,
            total: followingTotal,
            first: fetchFollowingFirst
        )
    }

    private func fetchLikedPlaylistsFirst() async throws -> PagedChunk<Playlist> {
        let page = try await api.getLikedPlaylists(limit: 50)
        await persistCache(Self.likedPlaylistsCacheKey, items: page.collection, id: \.id)
        await libraryCache.markSectionProgress(
            Self.likedPlaylistsCacheKey,
            nextHref: page.nextHref,
            completed: page.nextHref == nil
        )
        return PagedChunk(items: page.collection, next: page.nextHref.map(PagedCursor.url))
    }

    private func fetchLikedPlaylists(after cursor: PagedCursor) async throws -> PagedChunk<Playlist> {
        try await fetchSection(
            cursor,
            key: Self.likedPlaylistsCacheKey,
            as: Playlist.self,
            first: fetchLikedPlaylistsFirst
        )
    }

    private func fetchSection<T: Codable & Identifiable>(
        _ cursor: PagedCursor,
        key: String,
        as type: T.Type,
        total: Int? = nil,
        first: () async throws -> PagedChunk<T>
    ) async throws -> PagedChunk<T> where T.ID == String {
        switch cursor {
        case .start:
            return try await first()
        case .offset(let offset):
            let page = await cachedPage(key, offset: offset, as: T.self)
            return PagedChunk(items: page.items, next: page.next, total: total)
        case .url(let url):
            let page = try await api.getPage(T.self, from: url)
            await persistCache(key, items: page.collection, id: \.id)
            await libraryCache.markSectionProgress(key, nextHref: page.nextHref, completed: page.nextHref == nil)
            return PagedChunk(items: page.collection, next: page.nextHref.map(PagedCursor.url), total: total)
        }
    }

    private func fetchRecentlyAddedFirst() async throws -> PagedChunk<LibraryItem> {
        let page = try await api.getLibrary(limit: 50)
        let visible = page.collection.filter(Self.isVisible)
        await persistCache(LibrarySection.recentlyAdded.rawValue, items: visible, id: { $0.libraryShelfID })
        await libraryCache.markSectionProgress(
            LibrarySection.recentlyAdded.rawValue,
            nextHref: page.nextHref,
            completed: page.nextHref == nil
        )
        lastLoaded[.recentlyAdded] = Date()
        return PagedChunk(items: visible, next: page.nextHref.map(PagedCursor.url))
    }

    private func fetchRecentlyAdded(after cursor: PagedCursor) async throws -> PagedChunk<LibraryItem> {
        let key = LibrarySection.recentlyAdded.rawValue
        switch cursor {
        case .start:
            return try await fetchRecentlyAddedFirst()
        case .offset(let offset):
            let page = await cachedPage(key, offset: offset, as: LibraryItem.self)
            return PagedChunk(items: page.items, next: page.next)
        case .url(let url):
            let page = try await api.getPage(LibraryItem.self, from: url)
            let visible = page.collection.filter(Self.isVisible)
            await persistCache(key, items: visible, id: { $0.libraryShelfID })
            await libraryCache.markSectionProgress(key, nextHref: page.nextHref, completed: page.nextHref == nil)
            return PagedChunk(items: visible, next: page.nextHref.map(PagedCursor.url))
        }
    }

    private func persistCache<T: Encodable>(_ cacheKey: String, items: [T], id: (T) -> String) async {
        let rows: [LibraryCache.WriteRow] = items.compactMap { item in
            guard let payload = try? Self.cacheEncoder.encode(item) else { return nil }
            return LibraryCache.WriteRow(id: id(item), payload: payload)
        }
        await libraryCache.mergeSection(cacheKey, rows: rows)
    }

    private func mergeLikesCache(_ likes: [Like<Track>]) async {
        let rows = likes.compactMap { like -> LibraryCache.WriteRow? in
            guard let payload = try? Self.cacheEncoder.encode(like.item) else { return nil }
            return LibraryCache.WriteRow(
                id: like.item.id,
                payload: payload,
                likedAtMillis: Int64((like.createdAt.timeIntervalSince1970 * 1000).rounded())
            )
        }
        await libraryCache.mergeSection(LibrarySection.likes.rawValue, rows: rows)
    }

    func handleSignOut() async {
        LikesSyncEngine.shared.handleSignOut()
        await libraryCache.clearAll()
        attempted.removeAll()
        lastLoaded.removeAll()
        recentlyAddedAttempted = false
        recentlyAddedPager.reset()
        likesPager.reset()
        playlistsPager.reset()
        followingPager.reset()
        likedPlaylistsPager.reset()
        likedAtByTrackID = [:]
        didLoadLikedPlaylists = false
        likesLocalSource = .none
    }

    func loadLikedPlaylistsIfNeeded() async {
        guard !didLoadLikedPlaylists else { return }
        await loadLikedPlaylists()
    }

    func loadLikedPlaylists() async {
        guard AuthenticationService.shared.isAuthenticated else { return }
        guard !likedPlaylistsPager.isLoadingFirst else { return }

        didLoadLikedPlaylists = true
        await likedPlaylistsPager.reload()
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

        guard !recentlyAddedPager.isLoadingFirst else { return }
        recentlyAddedLoading = true
        recentlyAddedError = nil
        defer { recentlyAddedLoading = false }

        await recentlyAddedPager.reload()

        if recentlyAddedPager.firstError != nil, recentlyAdded.isEmpty {
            recentlyAddedError = "Couldn't reach SoundCloud. Check this Apple TV's network connection."
        }
    }
}

extension LibraryItem: Identifiable {
    var id: String { libraryShelfID }
}
