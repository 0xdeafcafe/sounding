import AppIntents
import Foundation

private enum WatchIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingPlaying
    case signedOut
    case failed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingPlaying:
            return "Nothing is playing."
        case .signedOut:
            return "Open Sounding on your iPhone and sign in to SoundCloud first."
        case .failed:
            return "Couldn't do that right now."
        }
    }
}

private enum WatchLikesCollection {
    static let id = "likes"
}

struct PausePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause"
    static let description = IntentDescription("Pauses Sounding.")
    static let supportedModes: IntentModes = .background

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlaybackControlBridge.setPlaying(false)
        return .result()
    }
}

struct PlayLikesIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Likes"
    static let description = IntentDescription("Plays your SoundCloud Likes in Sounding.")
    static let supportedModes: IntentModes = .background

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard WatchCredentialSource.shared.isSignedIn else { throw WatchIntentError.signedOut }
        await WatchLinkClient.shared.sendAwaitingPhone(
            WatchCommand(kind: .play, collectionId: WatchLikesCollection.id, shuffled: false)
        )
        return .result()
    }
}

struct ShuffleLikesIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Likes"
    static let description = IntentDescription("Shuffles your SoundCloud Likes in Sounding.")
    static let supportedModes: IntentModes = .background

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard WatchCredentialSource.shared.isSignedIn else { throw WatchIntentError.signedOut }
        await WatchLinkClient.shared.sendAwaitingPhone(
            WatchCommand(kind: .play, collectionId: WatchLikesCollection.id, shuffled: true)
        )
        return .result()
    }
}

struct LikeCurrentTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Like Current Track"
    static let description = IntentDescription("Likes the track that's playing in Sounding.")
    static let supportedModes: IntentModes = .background

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard WatchCredentialSource.shared.isSignedIn else { throw WatchIntentError.signedOut }
        let link = WatchLinkClient.shared
        link.activate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while link.nowPlaying.trackId == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard let trackID = link.nowPlaying.trackId else { throw WatchIntentError.nothingPlaying }
        do {
            let track = try await SoundCloudAPI.shared.getTrack(id: trackID)
            try await SoundCloudAPI.shared.likeTrack(track)
            return .result(dialog: "Liked \(track.title).")
        } catch {
            throw WatchIntentError.failed
        }
    }
}

struct SoundingWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeLastSessionIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Play \(.applicationName)",
                "Resume playback in \(.applicationName)",
            ],
            shortTitle: "Play",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause playback in \(.applicationName)",
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: SkipTrackIntent(),
            phrases: [
                "Skip in \(.applicationName)",
                "Next track in \(.applicationName)",
                "Skip this track in \(.applicationName)",
            ],
            shortTitle: "Next Track",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PlayLikesIntent(),
            phrases: [
                "Play my likes in \(.applicationName)",
                "Play my likes on \(.applicationName)",
                "Play my \(.applicationName) likes",
            ],
            shortTitle: "Play Likes",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: ShuffleLikesIntent(),
            phrases: [
                "Shuffle my likes in \(.applicationName)",
                "Shuffle my likes on \(.applicationName)",
                "Shuffle my \(.applicationName) likes",
            ],
            shortTitle: "Shuffle Likes",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: LikeCurrentTrackIntent(),
            phrases: [
                "Like this track in \(.applicationName)",
                "Like this song in \(.applicationName)",
                "Like what's playing in \(.applicationName)",
            ],
            shortTitle: "Like Track",
            systemImageName: "heart"
        )
    }
}
