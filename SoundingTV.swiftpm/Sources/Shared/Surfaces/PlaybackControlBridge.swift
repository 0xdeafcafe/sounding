import Foundation

enum PlaybackControlBridge {
    struct OutputOverride {
        var isActive: @MainActor () -> Bool
        var setPlaying: @MainActor (Bool) -> Void
        var next: @MainActor () -> Void
        var mixNow: @MainActor () -> Void
    }

    private static let restoreWait: Duration = .seconds(2)

    @MainActor static var outputOverride: OutputOverride?

    @MainActor
    static func setPlaying(_ playing: Bool) async throws {
        if let override = outputOverride, override.isActive() {
            override.setPlaying(playing)
            return
        }

        let player = PlayerService.shared
        guard playing else {
            player.pause()
            SoundingSnapshotPublisher.shared.flush()
            return
        }

        if player.currentTrack == nil {
            let deadline = ContinuousClock.now.advanced(by: restoreWait)
            while player.currentTrack == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        if player.currentTrack != nil {
            player.play()
        } else if let resume = SoundingSnapshotPublisher.shared.current.resumeTarget {
            try await IntentPlayback.playTrack(id: resume.item.id, startingAt: resume.position)
        } else {
            throw PlaybackIntentError.notFound
        }
        SoundingSnapshotPublisher.shared.flush()
    }

    @MainActor
    static func skipToNext() async throws {
        if let override = outputOverride, override.isActive() {
            override.next()
            return
        }
        guard PlayerService.shared.currentTrack != nil else { throw PlaybackIntentError.notFound }
        await PlayerService.shared.playNext()
        SoundingSnapshotPublisher.shared.flush()
    }

    @MainActor
    static func mixNow() async throws {
        if let override = outputOverride, override.isActive() {
            override.mixNow()
            return
        }
        guard PlayerService.shared.canStartMix else { throw PlaybackIntentError.notFound }
        PlayerService.shared.startMix()
        SoundingSnapshotPublisher.shared.flush()
    }
}
