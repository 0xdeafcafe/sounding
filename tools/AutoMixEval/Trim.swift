import Foundation

enum TrackTrimStore {
    nonisolated static func effectiveRange(for trackID: String, duration: TimeInterval) -> ClosedRange<TimeInterval> {
        0...duration
    }
}

extension TrackFeatures {
    func baselineView(earliestExit: TimeInterval = 0, playable: ClosedRange<TimeInterval>? = nil) -> TrackFeatures {
        var view = self
        view.earliestExitSeconds = earliestExit
        return view
    }
}
