import Foundation
import Combine
import Synchronization

struct LibrarySources: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let files = LibrarySources(rawValue: 1 << 0)
    static let soundCloud = LibrarySources(rawValue: 1 << 1)

    var symbols: [String] {
        var out: [String] = []
        if contains(.files) { out.append("folder") }
        if contains(.soundCloud) { out.append("cloud") }
        return out
    }

    var label: String {
        switch (contains(.files), contains(.soundCloud)) {
        case (true, true): "Your Files and SoundCloud"
        case (true, false): "Your Files"
        case (false, true): "SoundCloud"
        default: ""
        }
    }
}

struct LibraryArtist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let local: LocalCollection?
    let user: User?
    let linkOrigin: LibraryIdentityLink.Origin?

    var sources: LibrarySources {
        var sources: LibrarySources = []
        if local != nil { sources.insert(.files) }
        if user != nil { sources.insert(.soundCloud) }
        return sources
    }

    var localKey: String? { local?.id }
    var isLinked: Bool { local != nil && user != nil }
    var canLink: Bool { local != nil }

    var artworkURL: URL? {
        User.customAvatar(user?.largeAvatarURL) ?? local?.artworkURL
    }

    var thumbnailURL: URL? {
        User.customAvatar(user?.avatarURL) ?? local?.artworkURL
    }

    var localTracks: [Track] { local?.tracks ?? [] }

    var lastAddedAt: Date { local?.lastAddedAt ?? .distantPast }

    static func == (lhs: LibraryArtist, rhs: LibraryArtist) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.local == rhs.local && lhs.user?.id == rhs.user?.id && lhs.linkOrigin == rhs.linkOrigin
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(user?.id)
        hasher.combine(local?.tracks.count)
    }
}

struct LibraryArtistReleases {
    var albums: [LibraryGridItem] = []
    var tracks: [Track] = []
    var sets: [Track] = []
    var appearsOn: [LibraryGridItem] = []

    var playable: [Track] { tracks.isEmpty ? sets : tracks }
    var isEmpty: Bool { albums.isEmpty && tracks.isEmpty && sets.isEmpty && appearsOn.isEmpty }
}

struct LibraryIdentitySearchResults {
    var artists: [LibraryArtist] = []
    var albums: [LibraryGridItem] = []
    var tracks: [Track] = []
}

struct LibraryIdentityIndex: Sendable {
    var generation = 0
    var artists: [LibraryArtist] = []
    var localAlbums: [LocalCollection] = []
    var soundCloudAlbums: [Playlist] = []
    var linkCandidates: [User] = []
    var artistIDByLocalKey: [String: String] = [:]
    var artistIDByUserID: [String: String] = [:]
    var playlistsByUserID: [String: [Playlist]] = [:]
    var likedTracksByUserID: [String: [Track]] = [:]
    var soundCloudAlbumByLocalAlbumID: [String: Playlist] = [:]
    var localAlbumByPlaylistID: [String: LocalCollection] = [:]
    var localTrackBySoundCloudID: [String: Track] = [:]
    var soundCloudTrackByLocalID: [String: Track] = [:]
    var appearsOnLocalByArtistKey: [String: [String]] = [:]
    var appearsOnPlaylistsByUserID: [String: [Playlist]] = [:]
    var albumOriginByLocalID: [String: LibraryIdentityLink.Origin] = [:]
    var trackOriginByLocalID: [String: LibraryIdentityLink.Origin] = [:]
    var hasLocalFiles = false

    static let empty = LibraryIdentityIndex()

    func artist(id: String) -> LibraryArtist? {
        artists.first { $0.id == id }
    }

    func artist(forLocalKey key: String) -> LibraryArtist? {
        artistIDByLocalKey[key].flatMap(artist(id:))
    }

    func artist(forUserID id: String) -> LibraryArtist? {
        artistIDByUserID[id].flatMap(artist(id:))
    }

    func artist(named name: String) -> LibraryArtist? {
        artist(forLocalKey: LibraryNames.artistKey(name))
    }

    func soundCloudAlbum(forLocalAlbumID id: String) -> Playlist? {
        soundCloudAlbumByLocalAlbumID[id]
    }

    func localAlbum(forPlaylistID id: String) -> LocalCollection? {
        localAlbumByPlaylistID[id]
    }

    func albumOrigin(forLocalAlbumID id: String) -> LibraryIdentityLink.Origin? {
        albumOriginByLocalID[id]
    }

    func trackOrigin(forLocalTrackID id: String) -> LibraryIdentityLink.Origin? {
        trackOriginByLocalID[id]
    }

    func localCopy(of track: Track) -> Track? {
        track.isLocal ? nil : localTrackBySoundCloudID[track.id]
    }

    func soundCloudCopy(of track: Track) -> Track? {
        track.isLocal ? soundCloudTrackByLocalID[track.id] : nil
    }

    func sources(of track: Track) -> LibrarySources {
        if track.isLocal {
            return soundCloudTrackByLocalID[track.id] == nil ? .files : [.files, .soundCloud]
        }
        return localTrackBySoundCloudID[track.id] == nil ? .soundCloud : [.files, .soundCloud]
    }

    func preferringLocalCopies(_ tracks: [Track]) -> [Track] {
        guard !localTrackBySoundCloudID.isEmpty else { return tracks }
        var seen = Set<String>()
        return tracks.compactMap { track in
            let chosen = localCopy(of: track) ?? track
            return seen.insert(chosen.id).inserted ? chosen : nil
        }
    }

    func withoutLinkedDuplicates(_ tracks: [Track]) -> [Track] {
        guard !localTrackBySoundCloudID.isEmpty else { return tracks }
        let present = Set(tracks.lazy.filter(\.isLocal).map(\.id))
        return tracks.filter { track in
            guard let copy = localCopy(of: track) else { return true }
            return !present.contains(copy.id)
        }
    }

    func releases(for artist: LibraryArtist, setMinimumDuration: TimeInterval) -> LibraryArtistReleases {
        var releases = LibraryArtistReleases()
        let localAlbums = LocalCollections.albums(from: artist.localTracks)
        var linked = Set<String>()
        for album in localAlbums {
            let remote = soundCloudAlbum(forLocalAlbumID: album.id)
            if let remote { linked.insert(remote.id) }
            releases.albums.append(LibraryGridItem(local: album, subtitle: Self.albumSubtitle(album), soundCloud: remote))
        }
        if let user = artist.user {
            for playlist in playlistsByUserID[user.id] ?? [] where playlist.isAlbum && !linked.contains(playlist.id) {
                releases.albums.append(LibraryGridItem(playlist: playlist, subtitle: Self.releaseSubtitle(playlist)))
            }
        }

        var tracks = artist.localTracks
        if let user = artist.user {
            let present = Set(tracks.map(\.id))
            for track in likedTracksByUserID[user.id] ?? [] {
                let chosen = localCopy(of: track) ?? track
                if !present.contains(chosen.id) { tracks.append(chosen) }
            }
        }
        var seen = Set<String>()
        tracks = tracks.filter { seen.insert($0.id).inserted }
        releases.sets = tracks.filter { $0.duration >= setMinimumDuration }
        releases.tracks = tracks.filter { $0.duration < setMinimumDuration }

        if let key = artist.localKey {
            let ids = Set(appearsOnLocalByArtistKey[key] ?? [])
            for album in self.localAlbums where ids.contains(album.id) {
                releases.appearsOn.append(LibraryGridItem(local: album, soundCloud: soundCloudAlbum(forLocalAlbumID: album.id)))
            }
        }
        if let user = artist.user {
            let shown = Set(releases.appearsOn.compactMap { $0.counterpart?.id })
            for playlist in appearsOnPlaylistsByUserID[user.id] ?? [] where !shown.contains(playlist.id) {
                releases.appearsOn.append(LibraryGridItem(playlist: playlist))
            }
        }
        return releases
    }

    func search(_ query: String, limit: Int = 25) -> LibraryIdentitySearchResults {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return LibraryIdentitySearchResults() }
        var results = LibraryIdentitySearchResults()
        results.artists = Array(artists.filter { artist in
            LibraryNames.matches(artist.name, query: needle)
                || artist.user.map { LibraryNames.matches($0.username, query: needle) || LibraryNames.matches($0.displayName, query: needle) } == true
        }.prefix(limit))
        var albums: [LibraryGridItem] = []
        var linked = Set<String>()
        for album in localAlbums where LibraryNames.matches(album.title, query: needle) || LibraryNames.matches(album.subtitle, query: needle) {
            let remote = soundCloudAlbum(forLocalAlbumID: album.id)
            if let remote { linked.insert(remote.id) }
            albums.append(LibraryGridItem(local: album, soundCloud: remote))
        }
        for playlist in soundCloudAlbums where !linked.contains(playlist.id)
            && (LibraryNames.matches(playlist.title, query: needle) || LibraryNames.matches(playlist.user.displayName, query: needle)) {
            if let local = localAlbum(forPlaylistID: playlist.id) {
                albums.append(LibraryGridItem(local: local, soundCloud: playlist))
            } else {
                albums.append(LibraryGridItem(playlist: playlist))
            }
        }
        results.albums = Array(albums.prefix(limit))
        var tracks: [Track] = []
        var seen = Set<String>()
        let pools = localAlbums.flatMap(\.tracks) + artists.compactMap(\.local).flatMap(\.tracks) + likedTracksByUserID.values.flatMap { $0 }
        for track in pools where LibraryNames.matches(track.title, query: needle) || LibraryNames.matches(track.user.displayName, query: needle) {
            let chosen = localCopy(of: track) ?? track
            if seen.insert(chosen.id).inserted { tracks.append(chosen) }
            if tracks.count >= limit { break }
        }
        results.tracks = tracks
        return results
    }

    static func albumSubtitle(_ album: LocalCollection) -> String {
        album.trackCountText
    }

    static func releaseSubtitle(_ playlist: Playlist) -> String {
        let date = playlist.releaseDate ?? playlist.createdAt
        let kind: String
        switch playlist.setType?.lowercased() {
        case "ep": kind = "EP"
        case "single": kind = "Single"
        case "compilation": kind = "Compilation"
        default: kind = "Album"
        }
        return "\(kind) · \(Calendar.current.component(.year, from: date))"
    }
}

@MainActor
final class LibraryIdentity: ObservableObject {
    static let shared = LibraryIdentity()

    @Published private(set) var index = LibraryIdentityIndex.empty
    @Published private(set) var isReady = false

    nonisolated static var current: LibraryIdentityIndex { storage.withLock { $0 } }
    private nonisolated static let storage = Mutex(LibraryIdentityIndex.empty)

    private var localTracks: [Track] = []
    private var cancellables: Set<AnyCancellable> = []
    private var rebuildTask: Task<Void, Never>?
    private var generation = 0
    private var activeRebuilds = 0

    private static let watched: Set<LibraryCollection> = [.likes, .followings, .likedPlaylists, .ownPlaylists]

    private init() {
        observe()
    }

    func refresh() {
        scheduleRebuild(after: .zero)
    }

    func linkCandidates(for artist: LibraryArtist) -> [User] {
        LibraryIdentityMatcher.rankedCandidates(for: artist.name, among: index.linkCandidates)
    }

    func link(_ artist: LibraryArtist, to user: User) {
        guard let key = artist.localKey else { return }
        let payload = try? LikesSyncEngine.makeEncoder().encode(user)
        let link = LibraryIdentityLink(kind: .artist, localKey: key, soundCloudID: user.id, origin: .manual, confidence: 1, payload: payload)
        Task {
            await LibraryDB.saveIdentityLinks([link])
            scheduleRebuild(after: .zero)
        }
    }

    func unlink(_ artist: LibraryArtist) {
        guard let key = artist.localKey else { return }
        let link = LibraryIdentityLink(kind: .artist, localKey: key, soundCloudID: artist.user?.id ?? "", origin: .unlinked, confidence: 1)
        Task {
            await LibraryDB.saveIdentityLinks([link])
            scheduleRebuild(after: .zero)
        }
    }

    func link(album local: LocalCollection, to playlist: Playlist) {
        let payload = try? LikesSyncEngine.makeEncoder().encode(playlist)
        var saves = [LibraryIdentityLink(kind: .album, localKey: local.id, soundCloudID: playlist.id, origin: .manual, confidence: 1, payload: payload)]
        if let prior = index.localAlbum(forPlaylistID: playlist.id), prior.id != local.id {
            saves.append(LibraryIdentityLink(kind: .album, localKey: prior.id, soundCloudID: playlist.id, origin: .unlinked, confidence: 1))
        }
        commit(saves: saves) { next in
            Self.detachAlbum(local.id, in: &next)
            if let prior = next.localAlbumByPlaylistID[playlist.id] {
                next.soundCloudAlbumByLocalAlbumID[prior.id] = nil
                next.albumOriginByLocalID[prior.id] = .unlinked
            }
            next.soundCloudAlbumByLocalAlbumID[local.id] = playlist
            next.localAlbumByPlaylistID[playlist.id] = local
            next.albumOriginByLocalID[local.id] = .manual
        }
    }

    func unlink(album local: LocalCollection) {
        let current = index.soundCloudAlbum(forLocalAlbumID: local.id)
        let link = LibraryIdentityLink(kind: .album, localKey: local.id, soundCloudID: current?.id ?? "", origin: .unlinked, confidence: 1)
        commit(saves: [link]) { next in
            Self.detachAlbum(local.id, in: &next)
            next.albumOriginByLocalID[local.id] = .unlinked
        }
    }

    func allowAutomaticLinking(album local: LocalCollection) {
        commit(removals: [(kind: .album, localKey: local.id)], rebuild: true) { next in
            next.albumOriginByLocalID[local.id] = nil
        }
    }

    func link(track local: Track, to remote: Track) {
        let payload = try? LikesSyncEngine.makeEncoder().encode(remote)
        var saves = [LibraryIdentityLink(kind: .track, localKey: local.id, soundCloudID: remote.id, origin: .manual, confidence: 1, payload: payload)]
        if let prior = index.localTrackBySoundCloudID[remote.id], prior.id != local.id {
            saves.append(LibraryIdentityLink(kind: .track, localKey: prior.id, soundCloudID: remote.id, origin: .unlinked, confidence: 1))
        }
        commit(saves: saves) { next in
            Self.detachTrack(local.id, in: &next)
            if let prior = next.localTrackBySoundCloudID[remote.id] {
                next.soundCloudTrackByLocalID[prior.id] = nil
                next.trackOriginByLocalID[prior.id] = .unlinked
            }
            next.soundCloudTrackByLocalID[local.id] = remote
            next.localTrackBySoundCloudID[remote.id] = local
            next.trackOriginByLocalID[local.id] = .manual
        }
    }

    func unlink(track local: Track) {
        let current = index.soundCloudTrackByLocalID[local.id]
        let link = LibraryIdentityLink(kind: .track, localKey: local.id, soundCloudID: current?.id ?? "", origin: .unlinked, confidence: 1)
        commit(saves: [link]) { next in
            Self.detachTrack(local.id, in: &next)
            next.trackOriginByLocalID[local.id] = .unlinked
        }
    }

    func allowAutomaticLinking(track local: Track) {
        commit(removals: [(kind: .track, localKey: local.id)], rebuild: true) { next in
            next.trackOriginByLocalID[local.id] = nil
        }
    }

    private static func detachAlbum(_ id: String, in index: inout LibraryIdentityIndex) {
        if let old = index.soundCloudAlbumByLocalAlbumID[id] { index.localAlbumByPlaylistID[old.id] = nil }
        index.soundCloudAlbumByLocalAlbumID[id] = nil
    }

    private static func detachTrack(_ id: String, in index: inout LibraryIdentityIndex) {
        if let old = index.soundCloudTrackByLocalID[id] { index.localTrackBySoundCloudID[old.id] = nil }
        index.soundCloudTrackByLocalID[id] = nil
    }

    private func commit(
        saves: [LibraryIdentityLink] = [],
        removals: [(kind: LibraryIdentityLink.Kind, localKey: String)] = [],
        rebuild: Bool = false,
        patch: (inout LibraryIdentityIndex) -> Void
    ) {
        var next = index
        patch(&next)
        generation += 1
        next.generation = generation
        Self.storage.withLock { $0 = next }
        index = next
        let interrupted = activeRebuilds > 0
        if interrupted { rebuildTask?.cancel() }
        Task {
            await LibraryDB.saveIdentityLinks(saves, removing: removals)
            if rebuild || interrupted { scheduleRebuild(after: .milliseconds(300)) }
        }
    }

    private func observe() {
        #if os(tvOS)
        let local = RemoteLocalMusic.shared.$tracksByDevice.map { $0.values.flatMap { $0 } }.eraseToAnyPublisher()
        #else
        let local = LocalMusicLibrary.shared.$tracksByFolder.map { $0.values.flatMap { $0 } }.eraseToAnyPublisher()
        #endif
        local
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                guard let self else { return }
                self.localTracks = tracks
                self.scheduleRebuild(after: self.isReady ? .seconds(1) : .milliseconds(200))
            }
            .store(in: &cancellables)

        LibrarySyncEngine.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let changed = LibrarySyncEngine.shared.lastChanged
                let relevant = !changed.isDisjoint(with: Self.watched) || changed.contains { $0.key.hasPrefix(LibraryCollection.playlistPrefix) }
                guard relevant else { return }
                self?.scheduleRebuild(after: .seconds(2))
            }
            .store(in: &cancellables)
    }

    private func scheduleRebuild(after delay: Duration) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.rebuild()
        }
    }

    private func rebuild() async {
        activeRebuilds += 1
        defer { activeRebuilds -= 1 }
        let local = localTracks
        let inputs = await LibraryIdentityInputs.load()
        let stored = await LibraryDB.identityLinks()
        guard !Task.isCancelled else { return }
        generation += 1
        let stamp = generation
        let result = await Task.detached(priority: .utility) {
            LibraryIdentityBuilder.build(local: local, inputs: inputs, stored: stored, generation: stamp)
        }.value
        guard !Task.isCancelled else { return }
        Self.storage.withLock { $0 = result.index }
        index = result.index
        isReady = true
        if !result.saves.isEmpty || !result.removals.isEmpty {
            await LibraryDB.saveIdentityLinks(result.saves, removing: result.removals)
        }
    }
}

struct LibraryIdentityInputs: Sendable {
    var followings: [User] = []
    var likes: [Track] = []
    var playlists: [Playlist] = []
    var albumTracks: [String: [Track]] = [:]

    private static let likesCeiling = 25_000
    private static let albumCeiling = 400

    static func load() async -> LibraryIdentityInputs {
        var inputs = LibraryIdentityInputs()
        let followCount = await LibraryDB.count(.followings)
        if followCount > 0 {
            inputs.followings = await LibraryDB.users(.followings, offset: 0, limit: followCount).users
        }
        let likeCount = await LibraryDB.count(.likes)
        if likeCount > 0 {
            inputs.likes = await LibraryDB.tracks(.likes, offset: 0, limit: min(likeCount, likesCeiling)).tracks
        }
        let playlistCount = await LibraryDB.playlistCount()
        if playlistCount > 0 {
            inputs.playlists = await LibraryDB.allPlaylists(offset: 0, limit: playlistCount).playlists.deduplicatedByID()
        }
        for album in inputs.playlists.filter(\.isAlbum).prefix(albumCeiling) {
            if let tracks = await LibraryDB.playlistTracks(id: album.id), !tracks.isEmpty {
                inputs.albumTracks[album.id] = tracks
            }
        }
        return inputs
    }
}

enum LibraryIdentityBuilder {
    struct Result: Sendable {
        let index: LibraryIdentityIndex
        let saves: [LibraryIdentityLink]
        let removals: [(kind: LibraryIdentityLink.Kind, localKey: String)]
    }

    private struct LinkKey: Hashable {
        let kind: LibraryIdentityLink.Kind
        let localKey: String
    }

    static func build(local: [Track], inputs: LibraryIdentityInputs, stored: [LibraryIdentityLink], generation: Int) -> Result {
        var index = LibraryIdentityIndex()
        index.generation = generation
        index.hasLocalFiles = local.contains(where: \.isLocal)

        let storedByKey = Dictionary(stored.map { (LinkKey(kind: $0.kind, localKey: $0.localKey), $0) }, uniquingKeysWith: { lhs, _ in lhs })
        var desired: [LinkKey: LibraryIdentityLink] = [:]

        let localArtists = LocalCollections.artists(from: local)
        let localAlbums = LocalCollections.albums(from: local)
        index.localAlbums = localAlbums

        let soundCloudAlbums = inputs.playlists.filter(\.isAlbum)
        index.soundCloudAlbums = soundCloudAlbums

        var users: [String: User] = [:]
        var candidates: [String: LibraryArtistCandidate] = [:]
        for user in inputs.followings {
            users[user.id] = user
            candidates[user.id, default: LibraryArtistCandidate(user: user)].isFollowed = true
        }
        for track in inputs.likes {
            let user = users[track.user.id] ?? track.user
            users[user.id] = user
            candidates[user.id, default: LibraryArtistCandidate(user: user)].likedTrackCount += 1
            index.likedTracksByUserID[user.id, default: []].append(track)
        }
        for playlist in inputs.playlists {
            let user = users[playlist.user.id] ?? playlist.user
            users[user.id] = user
            index.playlistsByUserID[user.id, default: []].append(playlist)
            if playlist.isAlbum {
                candidates[user.id, default: LibraryArtistCandidate(user: user)].likedAlbumCount += 1
            }
        }
        let candidateIndex = LibraryIdentityMatcher.CandidateIndex(Array(candidates.values))

        var likedOwnersByTitle: [String: [String]] = [:]
        for track in inputs.likes {
            likedOwnersByTitle[LibraryNames.trackKey(track.title), default: []].append(track.user.id)
        }

        var userByArtistKey: [String: User] = [:]
        var originByArtistKey: [String: LibraryIdentityLink.Origin] = [:]
        for artist in localArtists {
            let key = LinkKey(kind: .artist, localKey: artist.id)
            if let saved = storedByKey[key], saved.origin != .automatic {
                guard saved.origin == .manual else { continue }
                let user = users[saved.soundCloudID]
                    ?? saved.payload.flatMap { try? LikesSyncEngine.makeDecoder().decode(User.self, from: $0) }
                if let user {
                    userByArtistKey[artist.id] = user
                    originByArtistKey[artist.id] = .manual
                    users[user.id] = users[user.id] ?? user
                }
                continue
            }
            var shared: [String: Int] = [:]
            for track in artist.tracks {
                for owner in Set(likedOwnersByTitle[LibraryNames.trackKey(track.title)] ?? []) {
                    shared[owner, default: 0] += 1
                }
            }
            guard let best = LibraryIdentityMatcher.bestArtist(local: artist.title, in: candidateIndex, sharedTracks: shared) else { continue }
            userByArtistKey[artist.id] = best.user
            originByArtistKey[artist.id] = .automatic
            desired[key] = LibraryIdentityLink(kind: .artist, localKey: artist.id, soundCloudID: best.user.id, origin: .automatic, confidence: best.confidence)
        }

        var albumsByKey: [String: [Playlist]] = [:]
        for playlist in soundCloudAlbums {
            albumsByKey[LibraryNames.albumKey(playlist.title), default: []].append(playlist)
        }
        let playlistByID = Dictionary(inputs.playlists.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        for album in localAlbums {
            let key = LinkKey(kind: .album, localKey: album.id)
            if let saved = storedByKey[key], saved.origin != .automatic {
                index.albumOriginByLocalID[album.id] = saved.origin
                if saved.origin == .manual,
                   let playlist = playlistByID[saved.soundCloudID] ?? saved.payload.flatMap({ try? LikesSyncEngine.makeDecoder().decode(Playlist.self, from: $0) }) {
                    index.soundCloudAlbumByLocalAlbumID[album.id] = playlist
                    index.localAlbumByPlaylistID[playlist.id] = album
                }
                continue
            }
            let artistKeys = Set(album.tracks.flatMap { LibraryNames.creditKeys($0.user.displayName) })
            let linkedUsers = Set(album.tracks.compactMap { LocalCollections.artistKey(of: $0).flatMap { userByArtistKey[$0]?.id } })
            let profile = LibraryLocalAlbumProfile(id: album.id, title: album.title, artistKeys: artistKeys, trackCount: album.tracks.count)
            let pool = albumsByKey[LibraryNames.albumKey(album.title)] ?? []
            guard let best = LibraryIdentityMatcher.bestAlbum(profile, among: pool, linkedUserIDs: linkedUsers),
                  index.localAlbumByPlaylistID[best.playlist.id] == nil else { continue }
            index.soundCloudAlbumByLocalAlbumID[album.id] = best.playlist
            index.localAlbumByPlaylistID[best.playlist.id] = album
            index.albumOriginByLocalID[album.id] = .automatic
            desired[key] = LibraryIdentityLink(kind: .album, localKey: album.id, soundCloudID: best.playlist.id, origin: .automatic, confidence: best.confidence)
        }

        let remoteTracks = inputs.likes + inputs.albumTracks.values.flatMap { $0 }
        let remoteByID = Dictionary(remoteTracks.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        let trackIndex = LibraryIdentityMatcher.TrackIndex(remoteTracks)
        for track in local where track.isLocal {
            let key = LinkKey(kind: .track, localKey: track.id)
            if let saved = storedByKey[key], saved.origin != .automatic {
                index.trackOriginByLocalID[track.id] = saved.origin
                if saved.origin == .manual,
                   let remote = remoteByID[saved.soundCloudID] ?? saved.payload.flatMap({ try? LikesSyncEngine.makeDecoder().decode(Track.self, from: $0) }) {
                    index.soundCloudTrackByLocalID[track.id] = remote
                    index.localTrackBySoundCloudID[remote.id] = track
                }
                continue
            }
            var linkedUsers = Set<String>()
            if let artistKey = LocalCollections.artistKey(of: track), let user = userByArtistKey[artistKey] { linkedUsers.insert(user.id) }
            if let albumID = LocalCollections.albumID(of: track), let album = index.soundCloudAlbumByLocalAlbumID[albumID] { linkedUsers.insert(album.user.id) }
            guard let remote = LibraryIdentityMatcher.bestTrack(for: track, in: trackIndex, linkedUserIDs: linkedUsers),
                  index.localTrackBySoundCloudID[remote.id] == nil else { continue }
            index.soundCloudTrackByLocalID[track.id] = remote
            index.localTrackBySoundCloudID[remote.id] = track
            index.trackOriginByLocalID[track.id] = .automatic
            desired[key] = LibraryIdentityLink(kind: .track, localKey: track.id, soundCloudID: remote.id, origin: .automatic, confidence: 0.9)
        }

        var artists: [LibraryArtist] = []
        var claimedUsers = Set<String>()
        for artist in localArtists {
            let user = userByArtistKey[artist.id]
            if let user { claimedUsers.insert(user.id) }
            let entry = LibraryArtist(id: "artist.\(artist.id)", name: artist.title, local: artist, user: user, linkOrigin: originByArtistKey[artist.id])
            artists.append(entry)
            index.artistIDByLocalKey[artist.id] = entry.id
            if let user { index.artistIDByUserID[user.id] = entry.id }
        }
        for playlist in soundCloudAlbums {
            let user = users[playlist.user.id] ?? playlist.user
            guard !claimedUsers.contains(user.id) else { continue }
            claimedUsers.insert(user.id)
            let entry = LibraryArtist(id: "sc.\(user.id)", name: user.displayName, local: nil, user: user, linkOrigin: nil)
            artists.append(entry)
            index.artistIDByUserID[user.id] = entry.id
        }
        index.artists = artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for album in localAlbums {
            let albumArtist = LibraryNames.artistKey(album.subtitle)
            var credited = Set<String>()
            for track in album.tracks { credited.formUnion(LibraryNames.creditKeys(track.user.displayName)) }
            credited.remove(albumArtist)
            for key in credited where index.artistIDByLocalKey[key] != nil {
                let ownTracks = album.tracks.filter { LocalCollections.artistKey(of: $0) == key }
                if ownTracks.count == album.tracks.count { continue }
                index.appearsOnLocalByArtistKey[key, default: []].append(album.id)
            }
        }
        for (playlistID, tracks) in inputs.albumTracks {
            guard let playlist = playlistByID[playlistID] else { continue }
            for userID in Set(tracks.map(\.user.id)) where userID != playlist.user.id && index.artistIDByUserID[userID] != nil {
                index.appearsOnPlaylistsByUserID[userID, default: []].append(playlist)
            }
        }

        let followed = Set(inputs.followings.map(\.id))
        index.linkCandidates = users.values.sorted { lhs, rhs in
            let left = followed.contains(lhs.id), right = followed.contains(rhs.id)
            if left != right { return left }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        var saves: [LibraryIdentityLink] = []
        for (key, link) in desired {
            if let saved = storedByKey[key], saved.origin == .automatic, saved.soundCloudID == link.soundCloudID { continue }
            saves.append(link)
        }
        let removals: [(kind: LibraryIdentityLink.Kind, localKey: String)] = local.isEmpty ? [] : stored
            .filter { $0.origin == .automatic && desired[LinkKey(kind: $0.kind, localKey: $0.localKey)] == nil }
            .map { (kind: $0.kind, localKey: $0.localKey) }
        return Result(index: index, saves: saves, removals: removals)
    }
}
