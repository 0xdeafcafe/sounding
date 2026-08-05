import Foundation
import ActivityKit
import os

private struct LiveActivityHandle: @unchecked Sendable {
    let activity: Activity<NowPlayingActivityAttributes>

    var contentState: NowPlayingActivityAttributes.ContentState {
        activity.content.state
    }

    func update(_ state: NowPlayingActivityAttributes.ContentState) async {
        await activity.update(ActivityContent(state: state, staleDate: state.staleDate))
    }

    func end(finalState: NowPlayingActivityAttributes.ContentState?) async {
        let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
        await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(5)))
    }
}

@MainActor
enum NowPlayingLiveActivity {

    private static var current: LiveActivityHandle?

    private static func runningActivity() -> LiveActivityHandle? {
        current ?? Activity<NowPlayingActivityAttributes>.activities.last.map(LiveActivityHandle.init)
    }

    static func start(sessionId: String, state: NowPlayingActivityAttributes.ContentState) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let existing = runningActivity() {
            current = existing
            await existing.update(state)
            return
        }

        do {
            let activity = try Activity.request(
                attributes: NowPlayingActivityAttributes(sessionId: sessionId),
                content: ActivityContent(state: state, staleDate: state.staleDate),
                pushType: nil
            )
            current = LiveActivityHandle(activity: activity)
        } catch {
            Log.player.error("[NowPlayingLiveActivity] Failed to start: \(error, privacy: .public)")
        }
    }

    static var currentContentState: NowPlayingActivityAttributes.ContentState? {
        runningActivity()?.contentState
    }

    static func update(_ state: NowPlayingActivityAttributes.ContentState) async {
        guard let activity = runningActivity() else { return }
        current = activity
        await activity.update(state)
    }

    static func end(finalState: NowPlayingActivityAttributes.ContentState? = nil) async {
        for activity in Activity<NowPlayingActivityAttributes>.activities {
            await LiveActivityHandle(activity: activity).end(finalState: finalState)
        }
        current = nil
    }
}
