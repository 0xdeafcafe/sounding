import Foundation
import Combine

struct RecentlyAddedEntry<Value: Sendable>: Sendable {
    let value: Value
    let date: Date
}

struct RecentlyAddedSources: Sendable {
    var likes: [RecentlyAddedEntry<Track>] = []
    var likedPlaylists: [RecentlyAddedEntry<Playlist>] = []
    var ownPlaylists: [RecentlyAddedEntry<Playlist>] = []
    var followings: [RecentlyAddedEntry<User>] = []
    var localTracks: [Track] = []
}

struct RecentlyAddedItem: Identifiable, Sendable, Equatable {
    enum Content: Sendable {
        case likedTrack(Track)
        case likedTracks([Track])
        case playlist(Playlist)
        case person(User)
        case collection(LocalCollection)
        case localTrack(Track)
    }

    let id: String
    let addedAt: Date
    let content: Content
    private let size: Int

    init(id: String, addedAt: Date, content: Content) {
        self.id = id
        self.addedAt = addedAt
        self.content = content
        switch content {
        case .likedTracks(let tracks): size = tracks.count
        case .collection(let collection): size = collection.tracks.count
        default: size = 1
        }
    }

    static func == (lhs: RecentlyAddedItem, rhs: RecentlyAddedItem) -> Bool {
        lhs.id == rhs.id && lhs.addedAt == rhs.addedAt && lhs.size == rhs.size
    }

    var title: String {
        switch content {
        case .likedTrack(let track), .localTrack(let track): return track.title
        case .likedTracks(let tracks): return "\(tracks.count) Liked Tracks"
        case .playlist(let playlist): return playlist.title
        case .person(let user): return user.displayName
        case .collection(let collection): return collection.title
        }
    }

    var subtitle: String {
        switch content {
        case .likedTrack(let track): return "Liked Track · \(track.user.displayName)"
        case .likedTracks: return "Liked · \(Self.dayLabel(addedAt))"
        case .playlist(let playlist): return "\(playlist.isAlbum ? "Album" : "Playlist") · \(playlist.user.displayName)"
        case .person: return "Following"
        case .collection(let collection):
            let detail = collection.id.hasPrefix(RecentlyAddedFeed.looseGroupPrefix) ? collection.trackCountText : collection.subtitle
            return "Your Music · \(detail)"
        case .localTrack(let track): return "Your Music · \(track.user.displayName)"
        }
    }

    var kindLabel: String {
        switch content {
        case .likedTrack: return "Liked Track"
        case .likedTracks: return "Liked Tracks"
        case .playlist(let playlist): return playlist.isAlbum ? "Album" : "Playlist"
        case .person: return "Following"
        case .collection, .localTrack: return "Your Music"
        }
    }

    var isCircular: Bool {
        if case .person = content { return true }
        return false
    }

    var placeholderSymbol: String {
        switch content {
        case .likedTrack, .likedTracks: return "heart.fill"
        case .playlist: return "music.note.list"
        case .person: return "person.fill"
        case .collection: return "square.stack"
        case .localTrack: return "music.note"
        }
    }

    var artworkURLs: [URL] {
        switch content {
        case .likedTrack(let track), .localTrack(let track):
            return track.artworkURL.map { [$0] } ?? []
        case .likedTracks(let tracks):
            var seen = Set<URL>()
            let distinct = tracks.compactMap(\.artworkURL).filter { seen.insert($0).inserted }
            return distinct.count >= 4 ? Array(distinct.prefix(4)) : Array(distinct.prefix(1))
        case .playlist(let playlist):
            return playlist.displayArtworkURL.map { [$0] } ?? []
        case .person(let user):
            return user.avatarURL.map { [$0] } ?? []
        case .collection(let collection):
            return collection.artworkURL.map { [$0] } ?? []
        }
    }

    var tracks: [Track] {
        switch content {
        case .likedTrack(let track), .localTrack(let track): return [track]
        case .likedTracks(let tracks): return tracks
        case .collection(let collection): return collection.tracks
        case .playlist(let playlist): return playlist.tracks ?? []
        case .person: return []
        }
    }

    private static func dayLabel(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

enum RecentlyAddedFeed {
    static let maximumItems = 200
    static let window: TimeInterval = 183 * 24 * 60 * 60
    static let minimumLikeGroup = 3
    static let minimumLooseGroup = 2
    static let storedLikeLimit = 400
    static let storedPlaylistLimit = 200
    static let storedFollowingLimit = 200
    static let looseGroupPrefix = "loose."

    static func build(_ sources: RecentlyAddedSources, now: Date = Date(), calendar: Calendar = .current) -> [RecentlyAddedItem] {
        let cutoff = now.addingTimeInterval(-window)
        func clamped(_ date: Date) -> Date { min(date, now) }

        var items: [RecentlyAddedItem] = []
        items += likeItems(sources.likes, cutoff: cutoff, now: now, calendar: calendar)
        items += playlistItems(sources, cutoff: cutoff, now: now)

        for entry in sources.followings {
            let date = clamped(entry.date)
            guard date >= cutoff else { continue }
            items.append(RecentlyAddedItem(id: "person.\(entry.value.id)", addedAt: date, content: .person(entry.value)))
        }

        items += localItems(sources.localTracks, cutoff: cutoff, now: now, calendar: calendar)

        items.sort { lhs, rhs in
            lhs.addedAt != rhs.addedAt ? lhs.addedAt > rhs.addedAt : lhs.id < rhs.id
        }
        return Array(items.prefix(maximumItems))
    }

    static func playbackContext(for item: RecentlyAddedItem, in items: [RecentlyAddedItem]) -> [Track] {
        guard case .likedTrack = item.content else { return item.tracks }
        var context: [Track] = []
        for candidate in items {
            switch candidate.content {
            case .likedTrack(let track): context.append(track)
            case .likedTracks(let tracks): context.append(contentsOf: tracks)
            default: break
            }
        }
        return context
    }

    private static func likeItems(
        _ likes: [RecentlyAddedEntry<Track>],
        cutoff: Date,
        now: Date,
        calendar: Calendar
    ) -> [RecentlyAddedItem] {
        let recent = likes
            .map { RecentlyAddedEntry(value: $0.value, date: min($0.date, now)) }
            .filter { $0.date >= cutoff }
            .sorted { $0.date > $1.date }
        var days: [Date] = []
        var byDay: [Date: [RecentlyAddedEntry<Track>]] = [:]
        for like in recent {
            let day = calendar.startOfDay(for: like.date)
            if byDay[day] == nil { days.append(day) }
            byDay[day, default: []].append(like)
        }
        var items: [RecentlyAddedItem] = []
        for day in days {
            guard let group = byDay[day], let newest = group.first else { continue }
            if group.count >= minimumLikeGroup {
                items.append(RecentlyAddedItem(
                    id: "likes.\(Int(day.timeIntervalSince1970))",
                    addedAt: newest.date,
                    content: .likedTracks(group.map(\.value))
                ))
            } else {
                for like in group {
                    items.append(RecentlyAddedItem(id: "like.\(like.value.id)", addedAt: like.date, content: .likedTrack(like.value)))
                }
            }
        }
        return items
    }

    private static func playlistItems(_ sources: RecentlyAddedSources, cutoff: Date, now: Date) -> [RecentlyAddedItem] {
        var newest: [String: RecentlyAddedEntry<Playlist>] = [:]
        for entry in sources.likedPlaylists + sources.ownPlaylists {
            let date = min(entry.date, now)
            guard date >= cutoff else { continue }
            if let existing = newest[entry.value.id], existing.date >= date { continue }
            newest[entry.value.id] = RecentlyAddedEntry(value: entry.value, date: date)
        }
        return newest.values.map {
            RecentlyAddedItem(id: "playlist.\($0.value.id)", addedAt: $0.date, content: .playlist($0.value))
        }
    }

    private static func localItems(_ tracks: [Track], cutoff: Date, now: Date, calendar: Calendar) -> [RecentlyAddedItem] {
        let local = tracks.filter(\.isLocal)
        var items: [RecentlyAddedItem] = []

        for album in LocalCollections.albums(from: local) {
            let date = min(album.lastAddedAt, now)
            guard date >= cutoff else { continue }
            items.append(RecentlyAddedItem(id: "album.\(album.id)", addedAt: date, content: .collection(album)))
        }

        var keys: [String] = []
        var groups: [String: [Track]] = [:]
        for track in local where LocalCollections.albumTitle(of: track) == nil {
            let date = min(track.createdAt, now)
            guard date >= cutoff else { continue }
            let day = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
            let key = "\(track.user.displayName.lowercased())|\(day)"
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(track)
        }
        for key in keys {
            guard let group = groups[key]?.sorted(by: { $0.createdAt > $1.createdAt }), let newest = group.first else { continue }
            let date = min(newest.createdAt, now)
            if group.count >= minimumLooseGroup {
                let collection = LocalCollection(
                    id: looseGroupPrefix + key,
                    kind: .album,
                    title: newest.user.displayName,
                    subtitle: newest.user.displayName,
                    artworkURL: group.first { $0.artworkURL != nil }?.artworkURL,
                    tracks: group
                )
                items.append(RecentlyAddedItem(id: "album.\(collection.id)", addedAt: date, content: .collection(collection)))
            } else {
                items.append(RecentlyAddedItem(id: "track.\(newest.id)", addedAt: date, content: .localTrack(newest)))
            }
        }
        return items
    }
}

extension LibraryDB {
    static func recentlyAddedSources(since cutoff: Date) async -> RecentlyAddedSources {
        let likeRows = await store.page(.likes, offset: 0, limit: RecentlyAddedFeed.storedLikeLimit)
        let likedPlaylistRows = await store.page(.likedPlaylists, offset: 0, limit: RecentlyAddedFeed.storedPlaylistLimit)
        let ownPlaylistRows = await store.page(.ownPlaylists, offset: 0, limit: RecentlyAddedFeed.storedPlaylistLimit)
        let followingRows = await store.page(.followings, offset: 0, limit: RecentlyAddedFeed.storedFollowingLimit)

        return await Task.detached(priority: .userInitiated) {
            let decoder = LikesSyncEngine.makeDecoder()
            var sources = RecentlyAddedSources()

            func stamp(_ row: LibraryRow) -> Date? {
                row.record.timestampMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            }

            for row in likeRows where row.record.kind == .track {
                guard let date = stamp(row), date >= cutoff,
                      let track = try? decoder.decode(Track.self, from: row.record.payload) else { continue }
                sources.likes.append(RecentlyAddedEntry(value: track, date: date))
            }
            for row in likedPlaylistRows where row.record.kind == .playlist {
                guard let date = stamp(row), date >= cutoff,
                      let playlist = try? decoder.decode(Playlist.self, from: row.record.payload) else { continue }
                sources.likedPlaylists.append(RecentlyAddedEntry(value: playlist, date: date))
            }
            for row in ownPlaylistRows where row.record.kind == .playlist {
                guard let playlist = try? decoder.decode(Playlist.self, from: row.record.payload),
                      playlist.createdAt >= cutoff else { continue }
                sources.ownPlaylists.append(RecentlyAddedEntry(value: playlist, date: playlist.createdAt))
            }
            for row in followingRows where row.record.kind == .user {
                guard let date = stamp(row), date >= cutoff,
                      let user = try? decoder.decode(User.self, from: row.record.payload) else { continue }
                sources.followings.append(RecentlyAddedEntry(value: user, date: date))
            }
            return sources
        }.value
    }
}

@MainActor
final class RecentlyAddedModel: ObservableObject {
    static let shared = RecentlyAddedModel()

    @Published private(set) var items: [RecentlyAddedItem] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isSyncing = false

    private var sources = RecentlyAddedSources()
    private var generation = 0
    private var observers: [AnyCancellable] = []

    private static let watched: Set<LibraryCollection> = [.likes, .likedPlaylists, .ownPlaylists, .followings]

    init() {
        observeLibrary()
        observeLocalMusic()
    }

    var showsLoading: Bool { items.isEmpty && (isLoading || isSyncing) }

    func load() async {
        await reloadStored()
        isLoading = false
    }

    private func reloadStored() async {
        let cutoff = Date().addingTimeInterval(-RecentlyAddedFeed.window)
        let stored = await LibraryDB.recentlyAddedSources(since: cutoff)
        sources.likes = stored.likes
        sources.likedPlaylists = stored.likedPlaylists
        sources.ownPlaylists = stored.ownPlaylists
        sources.followings = stored.followings
        await rebuild()
    }

    private func rebuild() async {
        generation += 1
        let token = generation
        let snapshot = sources
        let built = await Task.detached(priority: .userInitiated) {
            RecentlyAddedFeed.build(snapshot)
        }.value
        guard token == generation, built != items else { return }
        items = built
    }

    private func observeLibrary() {
        let engine = LibrarySyncEngine.shared
        observers.append(
            engine.$revision
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard !engine.lastChanged.isDisjoint(with: Self.watched) else { return }
                    Task { await self?.reloadStored() }
                }
        )
        observers.append(
            engine.$progress
                .map(\.isBackfilling)
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in self?.isSyncing = value }
        )
    }

    private func observeLocalMusic() {
        #if os(tvOS)
        let source = RemoteLocalMusic.shared.$tracksByDevice.map { $0.values.flatMap { $0 } }
        #else
        let source = LocalMusicLibrary.shared.$tracksByFolder.map { $0.values.flatMap { $0 } }
        #endif
        observers.append(
            source
                .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
                .sink { [weak self] local in
                    guard let self else { return }
                    self.sources.localTracks = local
                    guard !self.isLoading else { return }
                    Task { await self.rebuild() }
                }
        )
    }
}
