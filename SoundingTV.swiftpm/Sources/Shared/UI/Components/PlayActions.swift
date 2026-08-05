import Foundation

@MainActor
enum PlayActions {
    static func play(playlist: Playlist) async {
        var tracks = playlist.tracks ?? []

        if tracks.isEmpty {
            guard let full = try? await SoundCloudAPI.shared.getPlaylist(id: playlist.id) else {
                return
            }
            tracks = full.tracks ?? []
        }

        guard let first = tracks.first else { return }
        await PlayerService.shared.play(first, in: tracks, collectionId: playlist.id)
    }

    static func play(user: User) async {
        guard let page = try? await SoundCloudAPI.shared.getUserTracks(userId: user.id) else {
            return
        }
        guard let first = page.collection.first else { return }
        await PlayerService.shared.play(first, in: page.collection)
    }
}

extension PlayActions {

    static func play(tracks: [Track], startingAt track: Track? = nil, collectionId: String? = nil) async {
        guard !tracks.isEmpty else { return }
        await PlayerService.shared.play(track ?? tracks[0], in: tracks, collectionId: collectionId)
    }

    static func shufflePlay(tracks: [Track], collectionId: String? = nil) async {
        guard let start = tracks.randomElement() else { return }
        PlayerService.shared.isShuffleEnabled = true
        await PlayerService.shared.play(start, in: tracks, collectionId: collectionId)
    }
}
