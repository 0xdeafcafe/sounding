import Foundation
import Combine

struct LocalCollection: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case album
        case artist
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let tracks: [Track]

    static func == (lhs: LocalCollection, rhs: LocalCollection) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.tracks.map(\.id) == rhs.tracks.map(\.id)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(kind)
        hasher.combine(tracks.count)
    }

    var trackCountText: String { tracks.count == 1 ? "1 track" : "\(tracks.count) tracks" }

    var metadataLine: String {
        let minutes = Int(tracks.reduce(0) { $0 + $1.duration }) / 60
        var parts = [kind == .album ? "Album" : "Artist", trackCountText]
        if minutes >= 60 {
            parts.append("\(minutes / 60) hr \(minutes % 60) min")
        } else if minutes > 0 {
            parts.append("\(minutes) min")
        }
        return parts.joined(separator: " · ")
    }
}

enum LibraryCollectionRoute: Hashable {
    case playlist(Playlist)
    case local(LocalCollection)
}

struct LibraryGridItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let isCircular: Bool
    let isLocal: Bool
    let route: LibraryCollectionRoute
    var sources: LibrarySources
    var counterpart: Playlist?

    init(playlist: Playlist, subtitle: String? = nil) {
        id = "sc.\(playlist.id)"
        title = playlist.title
        self.subtitle = subtitle ?? playlist.user.displayName
        artworkURL = playlist.displayArtworkURL
        isCircular = false
        isLocal = false
        route = .playlist(playlist)
        sources = .soundCloud
    }

    init(local: LocalCollection, subtitle: String? = nil, soundCloud: Playlist? = nil) {
        id = "local.\(local.kind.rawValue).\(local.id)"
        title = local.title
        self.subtitle = subtitle ?? local.subtitle
        artworkURL = local.artworkURL ?? soundCloud?.displayArtworkURL
        isCircular = local.kind == .artist
        isLocal = true
        route = .local(local)
        sources = soundCloud == nil ? .files : [.files, .soundCloud]
        counterpart = soundCloud
    }
}

enum LibraryArtistSort: String, CaseIterable, Identifiable {
    case name
    case recentlyAdded

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .recentlyAdded: "Recently Added"
        }
    }
}

enum LibraryArtists {
    static func list(_ artists: [LocalCollection], search: String, sort: LibraryArtistSort) -> [LocalCollection] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? artists : artists.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        switch sort {
        case .name:
            return matching.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recentlyAdded:
            return matching.sorted { lhs, rhs in
                let left = lhs.lastAddedAt, right = rhs.lastAddedAt
                if left != right { return left > right }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    static func list(_ artists: [LibraryArtist], search: String, sort: LibraryArtistSort) -> [LibraryArtist] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? artists : artists.filter { artist in
            LibraryNames.matches(artist.name, query: needle)
                || artist.user.map { LibraryNames.matches($0.displayName, query: needle) || LibraryNames.matches($0.username, query: needle) } == true
        }
        switch sort {
        case .name:
            return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .recentlyAdded:
            return matching.sorted { lhs, rhs in
                let left = lhs.lastAddedAt, right = rhs.lastAddedAt
                if left != right { return left > right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    static func albumItems(of artist: LocalCollection) -> [LibraryGridItem] {
        let identity = LibraryIdentity.current
        return LocalCollections.albums(from: artist.tracks).map {
            LibraryGridItem(local: $0, subtitle: $0.trackCountText, soundCloud: identity.soundCloudAlbum(forLocalAlbumID: $0.id))
        }
    }
}

extension LocalCollection {
    var lastAddedAt: Date { tracks.map(\.createdAt).max() ?? .distantPast }
}

struct LocalCollectionRelated: Equatable {
    var artist: LocalCollection?
    var albums: [LocalCollection] = []

    init() {}

    init(collection: LocalCollection, libraryTracks: [Track]) {
        switch collection.kind {
        case .album:
            let name = collection.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, collection.subtitle != LocalCollections.variousArtists else { return }
            let theirs = libraryTracks.filter {
                $0.user.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name
            }
            artist = LocalCollections.artists(from: theirs).first
            albums = LocalCollections.albums(from: theirs).filter { $0.id != collection.id }
        case .artist:
            albums = LocalCollections.albums(from: collection.tracks)
        }
    }
}

enum LocalCollections {
    static let variousArtists = "Various Artists"

    static func albums(from tracks: [Track]) -> [LocalCollection] {
        var groups: [String: [Track]] = [:]
        var titles: [String: String] = [:]
        for track in tracks {
            guard let album = albumTitle(of: track), let key = albumID(of: track) else { continue }
            groups[key, default: []].append(track)
            if titles[key] == nil { titles[key] = album }
        }
        return groups.compactMap { key, members in
            guard let title = titles[key] else { return nil }
            let ordered = members.sorted { order($0) < order($1) }
            let artists = Set(ordered.map { $0.user.displayName.lowercased() })
            let subtitle = artists.count == 1 ? (ordered.first?.user.displayName ?? "") : variousArtists
            return LocalCollection(
                id: key,
                kind: .album,
                title: title,
                subtitle: subtitle,
                artworkURL: ordered.first { $0.artworkURL != nil }?.artworkURL,
                tracks: ordered
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func artistKey(of track: Track) -> String? {
        let name = track.user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let key = LibraryNames.artistKey(name)
        return key.isEmpty ? nil : key
    }

    static func artists(from tracks: [Track]) -> [LocalCollection] {
        var groups: [String: [Track]] = [:]
        var spellings: [String: [String: Int]] = [:]
        for track in tracks where track.isLocal {
            guard let key = artistKey(of: track) else { continue }
            groups[key, default: []].append(track)
            let primary = LibraryNames.primaryArtist(track.user.displayName)
            spellings[key, default: [:]][primary, default: 0] += 1
        }
        return groups.compactMap { key, members in
            guard let name = spellings[key]?.max(by: { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            })?.key else { return nil }
            let ordered = members.sorted { order($0) < order($1) }
            let albumCount = Set(ordered.compactMap { albumTitle(of: $0)?.lowercased() }).count
            let subtitle: String
            switch albumCount {
            case 0: subtitle = ordered.count == 1 ? "1 track" : "\(ordered.count) tracks"
            case 1: subtitle = "1 album"
            default: subtitle = "\(albumCount) albums"
            }
            return LocalCollection(
                id: key,
                kind: .artist,
                title: name,
                subtitle: subtitle,
                artworkURL: ordered.first { $0.artworkURL != nil }?.artworkURL,
                tracks: ordered
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func albumTitle(of track: Track) -> String? {
        guard track.isLocal, let title = track.publisher?.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    static func albumID(of track: Track) -> String? {
        guard let album = albumTitle(of: track) else { return nil }
        return album.lowercased() + "|" + directory(of: track)
    }

    private static func directory(of track: Track) -> String {
        guard let file = track.localFile else { return "" }
        let parent = (file.relativePath as NSString).deletingLastPathComponent
        return file.folderID + "/" + parent
    }

    private static func order(_ track: Track) -> String {
        track.localFile?.relativePath ?? track.title
    }
}

@MainActor
final class LibraryCollectionsModel: ObservableObject {
    enum Kind: String, Hashable {
        case albums
        case artists

        var title: String {
            switch self {
            case .albums: "Albums"
            case .artists: "Artists"
            }
        }

        var symbol: String {
            switch self {
            case .albums: SidebarSymbol.albums
            case .artists: SidebarSymbol.artists
            }
        }

        var emptyTitle: String {
            switch self {
            case .albums: "No Albums Yet"
            case .artists: "No Artists Yet"
            }
        }

        var emptyMessage: String {
            switch self {
            case .albums: "Albums you like on SoundCloud and albums in your music folders appear here."
            case .artists: "Artists from your music folders and albums you like on SoundCloud appear here."
            }
        }
    }

    let kind: Kind

    @Published private(set) var items: [LibraryGridItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?

    private var soundCloudAlbums: [Playlist] = []
    private var localTracks: [Track] = []
    private var managesSoundCloud = true
    private var didLoadSoundCloud = false
    private var localObservation: AnyCancellable?
    private var libraryObservation: AnyCancellable?

    private static let playlistCollections: Set<LibraryCollection> = [.likedPlaylists, .ownPlaylists]
    private static let networkPageLimit = 40

    private var identityObservation: AnyCancellable?

    init(kind: Kind) {
        self.kind = kind
        observeLocalMusic()
        observeLibrary()
        if kind == .albums {
            identityObservation = LibraryIdentity.shared.$index
                .map(\.generation)
                .removeDuplicates()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.rebuild() }
        }
    }

    var isEmpty: Bool { items.isEmpty && !isLoading && failure == nil }

    var localCollections: [LocalCollection] {
        items.compactMap { item in
            if case .local(let collection) = item.route { return collection }
            return nil
        }
    }

    var subtitle: String? {
        guard !items.isEmpty else { return nil }
        let noun = kind == .albums ? (items.count == 1 ? "album" : "albums") : (items.count == 1 ? "artist" : "artists")
        return "\(items.count.formatted(.number)) \(noun)"
    }

    func useSoundCloudAlbums(_ playlists: [Playlist]) {
        managesSoundCloud = false
        let albums = playlists.filter(\.isAlbum).deduplicatedByID()
        guard albums.map(\.id) != soundCloudAlbums.map(\.id) else { return }
        soundCloudAlbums = albums
        rebuild()
    }

    func load(force: Bool = false) async {
        guard kind == .albums, managesSoundCloud else { return }
        guard SoundCloudAPI.shared.hasCredentials else {
            soundCloudAlbums = []
            didLoadSoundCloud = false
            failure = nil
            rebuild()
            return
        }
        if didLoadSoundCloud, !force { return }
        if soundCloudAlbums.isEmpty {
            let cached = await Self.cachedAlbums()
            if !cached.isEmpty {
                soundCloudAlbums = cached
                rebuild()
            }
        }
        isLoading = items.isEmpty
        failure = nil
        defer { isLoading = false }
        LibrarySyncEngine.shared.prioritise(Array(Self.playlistCollections))
        if await loadFromLibrary() { return }
        do {
            var page = try await SoundCloudAPI.shared.getLikedPlaylists(limit: 100)
            var fetched = page.collection
            var pages = 1
            while page.nextHref != nil, pages < Self.networkPageLimit, !Task.isCancelled {
                page = try await SoundCloudAPI.shared.getNextPage(page)
                fetched += page.collection
                pages += 1
            }
            let fresh = fetched.filter(\.isAlbum)
            let freshIDs = Set(fresh.map(\.id))
            soundCloudAlbums = fresh + soundCloudAlbums.filter { !freshIDs.contains($0.id) }
            didLoadSoundCloud = true
            rebuild()
        } catch {
            guard !error.isCancellation else { return }
            if items.isEmpty {
                failure = "Couldn't reach SoundCloud. Check your connection and try again."
            }
        }
    }

    private func loadFromLibrary() async -> Bool {
        var ready = true
        for collection in Self.playlistCollections {
            let isReady = await LibraryDB.isCollectionReady(collection)
            if !isReady { ready = false }
        }
        let total = await LibraryDB.playlistCount()
        guard ready || total > 0 else { return false }
        let stored = await LibraryDB.allPlaylists(offset: 0, limit: max(total, 1)).playlists
            .filter(\.isAlbum)
            .deduplicatedByID()
        guard ready || !stored.isEmpty else { return false }
        soundCloudAlbums = stored
        didLoadSoundCloud = ready
        rebuild()
        return ready
    }

    private func observeLibrary() {
        guard kind == .albums else { return }
        libraryObservation = LibrarySyncEngine.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.managesSoundCloud,
                      !LibrarySyncEngine.shared.lastChanged.isDisjoint(with: Self.playlistCollections) else { return }
                Task { _ = await self.loadFromLibrary() }
            }
    }

    private static func cachedAlbums() async -> [Playlist] {
        await Task.detached(priority: .userInitiated) {
            let decoder = LikesSyncEngine.makeDecoder()
            let rows = LibraryCache.shared.loadSection("LikedAlbums") + LibraryCache.shared.loadSection("LibraryAlbums")
            return rows
                .compactMap { try? decoder.decode(Playlist.self, from: $0.payload) }
                .filter(\.isAlbum)
                .deduplicatedByID()
        }.value
    }

    private func observeLocalMusic() {
        #if os(tvOS)
        localObservation = RemoteLocalMusic.shared.$tracksByDevice
            .map { $0.values.flatMap { $0 } }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.localTracks = tracks
                self?.rebuild()
            }
        #else
        localObservation = LocalMusicLibrary.shared.$tracksByFolder
            .map { $0.values.flatMap { $0 } }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.localTracks = tracks
                self?.rebuild()
            }
        #endif
    }

    private func rebuild() {
        switch kind {
        case .albums: items = Self.albumItems(soundCloud: soundCloudAlbums, localTracks: localTracks)
        case .artists: items = Self.artistItems(localTracks: localTracks)
        }
    }

    static func albumItems(soundCloud: [Playlist], localTracks: [Track], identity: LibraryIdentityIndex = LibraryIdentity.current) -> [LibraryGridItem] {
        let local = LocalCollections.albums(from: localTracks).map {
            LibraryGridItem(local: $0, soundCloud: identity.soundCloudAlbum(forLocalAlbumID: $0.id))
        }
        let linked = Set(local.compactMap { $0.counterpart?.id })
        let remote = soundCloud.filter(\.isAlbum).deduplicatedByID()
            .filter { !linked.contains($0.id) }
            .map { LibraryGridItem(playlist: $0) }
        return (remote + local).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func artistItems(localTracks: [Track]) -> [LibraryGridItem] {
        LocalCollections.artists(from: localTracks).map { LibraryGridItem(local: $0) }
    }

    func tracks(of items: [LibraryGridItem]) async -> [Track] {
        var seen = Set<String>()
        var tracks: [Track] = []
        for item in items {
            let itemTracks: [Track]
            switch item.route {
            case .local(let collection):
                itemTracks = collection.tracks
            case .playlist(let playlist):
                if let stored = playlist.tracks, !stored.isEmpty {
                    itemTracks = stored
                } else {
                    itemTracks = await LibraryDB.playlistTracks(id: playlist.id) ?? []
                }
            }
            for track in itemTracks where seen.insert(track.id).inserted {
                tracks.append(track)
            }
        }
        return tracks
    }

    static func matching(_ items: [LibraryGridItem], search: String) -> [LibraryGridItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.localizedStandardContains(query) || $0.subtitle.localizedStandardContains(query)
        }
    }
}

enum SocialSection: String, CaseIterable, Identifiable, Hashable {
    case following
    case followers
    case profile
    case activity

    var id: Self { self }

    var title: String {
        switch self {
        case .following: "Following"
        case .followers: "Followers"
        case .profile: "Profile"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .following: "person.crop.circle.badge.checkmark"
        case .followers: "person.2"
        case .profile: "person.crop.circle"
        case .activity: "bell"
        }
    }
}

private extension Error {
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
