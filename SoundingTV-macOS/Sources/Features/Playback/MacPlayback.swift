import SwiftUI
import AppKit

@MainActor
enum MacPlaybackTarget {
    static weak var router: OutputRouter?

    static var output: CompanionClient? {
        guard let router, router.isRemote else { return nil }
        return router.client
    }
}

@MainActor
enum MacPlayback {
    private static var remote: OutputRouter? {
        guard MacPlaybackTarget.output != nil else { return nil }
        return MacPlaybackTarget.router
    }

    static func play(_ track: Track, in context: [Track], collectionId: String? = nil, source: PlaybackQueueSource? = nil) async {
        if let router = remote {
            _ = await router.play(track, in: context, collectionId: collectionId, source: source)
        } else {
            await PlayerService.shared.play(track, in: context, collectionId: collectionId, source: source)
        }
    }

    static func shuffle(_ tracks: [Track], collectionId: String? = nil, source: PlaybackQueueSource? = nil) async {
        let playable = tracks.filter { $0.streamURL != nil }
        if let router = remote {
            _ = await router.play(shuffled: playable, collectionId: collectionId, source: source)
            return
        }
        guard let start = playable.randomElement() else { return }
        PlayerService.shared.isShuffleEnabled = true
        await PlayerService.shared.play(start, in: tracks, collectionId: collectionId, source: source)
    }

    static func play(playlist: Playlist) async {
        await CollectionPlayback.start(playlist: playlist) { first, queue in
            await MacPlayback.play(first, in: queue, collectionId: playlist.id, source: PlaybackQueueSource(playlist: playlist))
        }
    }

    static func play(user: User) async {
        guard let page = try? await SoundCloudAPI.shared.getUserTracks(userId: user.id),
              let first = page.collection.first else { return }
        await play(first, in: page.collection, source: PlaybackQueueSource(artist: user))
    }

    static func playNext(_ tracks: [Track]) {
        if let router = remote {
            for track in tracks.reversed() { router.playNext(track) }
            return
        }
        let player = PlayerService.shared
        let insertion = player.currentIndex + 1
        for track in tracks.reversed() { player.insertIntoQueue(track, at: insertion) }
    }

    static func playLast(_ tracks: [Track]) {
        if let router = remote {
            for track in tracks { router.addToQueue(track) }
            return
        }
        for track in tracks { PlayerService.shared.addToQueue(track) }
    }

    static func insert(_ tracks: [Track], at index: Int? = nil) {
        let player = PlayerService.shared
        guard let router = MacPlaybackTarget.router else {
            var position = index ?? player.queue.count
            for track in tracks {
                player.insertIntoQueue(track, at: position)
                position += 1
            }
            return
        }
        let end = router.isRemote ? router.client.tracks.count : player.queue.count
        router.insertIntoQueue(tracks, at: index ?? end)
    }

    static func next() {
        if let client = MacPlaybackTarget.output {
            client.next()
        } else {
            Task { await PlayerService.shared.playNext() }
        }
    }

    static func previous() {
        if let client = MacPlaybackTarget.output {
            client.previous()
        } else {
            Task { await InstantReplay.previous(PlayerService.shared) }
        }
    }

    static var isShuffleEnabled: Bool {
        if let client = MacPlaybackTarget.output {
            return client.telemetry.playbackModes?.isShuffleEnabled == true
        }
        return PlayerService.shared.isShuffleEnabled
    }

    static func toggleShuffle() {
        guard let client = MacPlaybackTarget.output else {
            PlayerService.shared.toggleShuffle()
            return
        }
        guard client.canChangePlaybackModes else { return }
        client.setShuffle(!isShuffleEnabled)
    }

    static func cycleRepeatMode() {
        guard let client = MacPlaybackTarget.output else {
            PlayerService.shared.cycleRepeatMode()
            return
        }
        guard client.canChangePlaybackModes else { return }
        switch client.telemetry.playbackModes?.remoteRepeatMode ?? .off {
        case .off: client.setRepeat(.all)
        case .all: client.setRepeat(.one)
        case .one: client.setRepeat(.off)
        }
    }
}
