import Foundation

struct PlaybackQueueSource: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case likes
        case playlist
        case album
        case station
        case artist
        case other
    }

    var id: String?
    var kind: Kind
    var title: String

    static let likes = PlaybackQueueSource(id: CollectionPolicyID.likedTracks, kind: .likes, title: "Likes")

    init(id: String?, kind: Kind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }

    init(playlist: Playlist) {
        self.init(id: playlist.id, kind: playlist.isAlbum ? .album : .playlist, title: playlist.title)
    }

    init(station: SystemPlaylist) {
        self.init(id: station.id, kind: .station, title: station.shortTitle.flatMap { $0.isEmpty ? nil : $0 } ?? station.title)
    }

    init(artist: User) {
        self.init(id: "user:\(artist.id)", kind: .artist, title: artist.displayName)
    }
}

@MainActor
enum PlaybackQueueSourceDirectory {
    private static var known: [String: PlaybackQueueSource] = [:]
    private static var albums: [String: Playlist] = [:]
    private static var albumOfTrack: [String: String] = [:]
    private static let limit = 200
    private static let trackLimit = 5000

    static func note(_ source: PlaybackQueueSource) {
        guard let id = source.id, !source.title.isEmpty else { return }
        if known[id] == nil, known.count >= limit { known.removeAll(keepingCapacity: true) }
        known[id] = source
    }

    static func note(_ playlist: Playlist) {
        note(PlaybackQueueSource(playlist: playlist))
        guard playlist.isAlbum else { return }
        if albums[playlist.id] == nil, albums.count >= limit {
            albums.removeAll(keepingCapacity: true)
            albumOfTrack.removeAll(keepingCapacity: true)
        }
        albums[playlist.id] = playlist
        let ids = playlist.trackIDs ?? []
        if albumOfTrack.count + ids.count > trackLimit { albumOfTrack.removeAll(keepingCapacity: true) }
        for id in ids { albumOfTrack[id] = playlist.id }
    }

    static func album(for track: Track, playingFrom source: PlaybackQueueSource? = nil) -> Playlist? {
        guard !track.isLocal else { return nil }
        if let source, source.kind == .album, let id = source.id, let album = albums[id],
           album.trackIDs?.contains(track.id) ?? (album.title == track.albumName) {
            return album
        }
        return albumOfTrack[track.id].flatMap { albums[$0] }
    }

    static func note(_ station: SystemPlaylist) { note(PlaybackQueueSource(station: station)) }

    static func source(for collectionId: String?) -> PlaybackQueueSource? {
        guard let collectionId else { return nil }
        if collectionId == CollectionPolicyID.likedTracks { return .likes }
        return known[collectionId]
    }

    static func reset() {
        known.removeAll()
        albums.removeAll()
        albumOfTrack.removeAll()
    }
}

extension Track {
    @MainActor
    var knownAlbum: Playlist? {
        PlaybackQueueSourceDirectory.album(for: self, playingFrom: PlayerService.shared.queueSource)
    }

    @MainActor
    var albumDisplayName: String? {
        albumName ?? knownAlbum?.title
    }

    @MainActor
    func artistLine(omittingAlbum shown: String? = nil) -> String {
        guard let album = albumDisplayName,
              album.caseInsensitiveCompare(shown ?? "") != .orderedSame else { return user.displayName }
        return "\(user.displayName) \u{2014} \(album)"
    }
}
