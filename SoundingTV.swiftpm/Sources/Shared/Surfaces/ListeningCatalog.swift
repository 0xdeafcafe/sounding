import Foundation

@MainActor
enum ListeningCatalog {
    static let likesContextLimit = IntentPlayback.likesQueueLimit

    static var isSignedIn: Bool { SoundCloudCredentialSource.shared.hasAccount }

    static func likes(offset: Int, limit: Int) async -> (tracks: [Track], rowCount: Int) {
        let page = await LibraryDB.tracks(.likes, offset: offset, limit: limit)
        return (page.tracks, page.rowCount)
    }

    static func likesContext() async -> [Track] {
        await likes(offset: 0, limit: likesContextLimit).tracks
    }

    static func playlists(offset: Int, limit: Int) async -> (playlists: [Playlist], rowCount: Int) {
        let page = await LibraryDB.allPlaylists(offset: offset, limit: limit)
        return (page.playlists.filter { !$0.isAlbum }, page.rowCount)
    }

    static func albums() async -> [LibraryGridItem] {
        let total = await LibraryDB.playlistCount()
        var stored: [Playlist] = []
        if total > 0 {
            stored = await LibraryDB.allPlaylists(offset: 0, limit: total).playlists
        }
        return LibraryCollectionsModel.albumItems(soundCloud: stored.filter(\.isAlbum), localTracks: yourMusic())
    }

    static func artists() -> [LibraryGridItem] {
        LibraryCollectionsModel.artistItems(localTracks: yourMusic())
    }

    static func downloads() -> [Track] {
        DownloadManager.shared.entries.values
            .filter(\.isDownloaded)
            .sorted { $0.addedAt > $1.addedAt }
            .map(\.track)
    }

    static func yourMusic() -> [Track] {
        LocalMusicLibrary.isSupported ? LocalMusicLibrary.shared.allTracks : []
    }

    static var hasYourMusic: Bool {
        LocalMusicLibrary.isSupported && LocalMusicLibrary.shared.tracksByFolder.values.contains { !$0.isEmpty }
    }

    static func playlistTracks(_ playlist: Playlist) async -> [Track] {
        if let stored = await LibraryDB.playlistTracks(id: playlist.id), !stored.isEmpty { return stored }
        let loaded = playlist.loadedTracks
        if !loaded.isEmpty, loaded.count >= playlist.trackCount { return loaded }
        guard isSignedIn, let fetched = try? await IntentPlayback.source.playlistTracks(id: playlist.id), !fetched.isEmpty else {
            return loaded.isEmpty ? DownloadManager.shared.cachedTracks(forCollectionId: playlist.id) : loaded
        }
        return fetched
    }

    static func stations(in shelves: [DiscoveryShelf]) -> [SystemPlaylist] {
        var seen = Set<String>()
        var stations: [SystemPlaylist] = []
        for shelf in shelves {
            switch shelf.content {
            case .stations(let list):
                stations += list
            case .mixed(let entries):
                stations += entries.compactMap { entry in
                    if case .station(let station) = entry { return station }
                    return nil
                }
            case .tracks, .playlists, .users:
                break
            }
        }
        return stations.filter { seen.insert($0.id).inserted }
    }

    static func stationShelves(in shelves: [DiscoveryShelf]) -> [DiscoveryShelf] {
        shelves.filter { shelf in
            guard shelf.kind == .station, case .tracks(let tracks) = shelf.content else { return false }
            return !tracks.isEmpty
        }
    }

    static func searchLibrary(_ query: String, limit: Int) async -> [SearchLibraryHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let snapshot = await LiveSearchLibrarySource().snapshot(matching: trimmed)
        return SearchRanking.libraryHits(query: trimmed, in: snapshot, limit: limit)
    }

    static func libraryTracks(byArtist name: String, userID: String?, limit: Int) async -> [Track] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let snapshot = await LiveSearchLibrarySource().snapshot(matching: trimmed)
        let needle = SearchRanking.normalized(trimmed)
        var seen = Set<String>()
        let pool = snapshot.likes + snapshot.reposts + snapshot.downloads + snapshot.local
        let matches = pool.filter { track in
            let byID = userID.map { track.user.id == $0 } ?? false
            let byName = SearchRanking.normalized(track.user.displayName) == needle
            return (byID || byName) && seen.insert(track.id).inserted
        }
        return Array(matches.prefix(limit))
    }
}
