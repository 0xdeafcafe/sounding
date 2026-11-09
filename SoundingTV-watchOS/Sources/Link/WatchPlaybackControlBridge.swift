import Foundation

enum PlaybackControlBridge {
    @MainActor
    static func setPlaying(_ playing: Bool) async throws {
        if WatchPlayback.shared.isLocal {
            WatchPlayback.shared.transport(playing ? .play : .pause)
            return
        }
        WatchSnapshotWriter.shared.assume(isPlaying: playing)
        await WatchLinkClient.shared.sendAwaitingPhone(
            WatchCommand(kind: .transport, transport: playing ? .play : .pause)
        )
    }

    @MainActor
    static func skipToNext() async throws {
        if WatchPlayback.shared.isLocal {
            WatchPlayback.shared.transport(.next)
            return
        }
        await WatchLinkClient.shared.sendAwaitingPhone(
            WatchCommand(kind: .transport, transport: .next)
        )
    }

    @MainActor
    static func mixNow() async throws {
        await WatchLinkClient.shared.sendAwaitingPhone(
            WatchCommand(kind: .dj, dj: .mixNow)
        )
    }
}
