import AppIntents
import Foundation

private let controlTimeout: Duration = .seconds(5)

@MainActor
private func runControl(
    _ type: MessageType,
    optimistic: (NowPlayingActivityAttributes.ContentState) -> NowPlayingActivityAttributes.ContentState = { $0 }
) async throws {
    let previous = NowPlayingLiveActivity.currentContentState
    if let previous {
        await NowPlayingLiveActivity.update(optimistic(previous))
    }

    do {
        let playback = try await WidgetControlSender().send(type, timeout: controlTimeout)
        await NowPlayingLiveActivity.update(.init(playback: playback))
    } catch {
        if let previous {
            await NowPlayingLiveActivity.update(previous)
        }
        throw error
    }
}

struct PlayTransportIntent: AppIntent {
    static let title: LocalizedStringResource = "Play"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await runControl(.transportPlay) { state in
            state.settingPlayback(true)
        }
        return .result()
    }
}

struct PauseTransportIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await runControl(.transportPause) { state in
            state.settingPlayback(false)
        }
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await runControl(.transportNext)
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await runControl(.transportPrevious)
        return .result()
    }
}

struct MixNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Mix Now"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await runControl(.djMixNow) { state in
            var next = state
            next.isDJModeLive = true
            return next
        }
        return .result()
    }
}
