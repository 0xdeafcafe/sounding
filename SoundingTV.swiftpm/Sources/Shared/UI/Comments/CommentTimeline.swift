import Foundation

enum CommentTimeline {
    struct Split: Equatable {
        let reachedCount: Int
        let currentIndex: Int?
    }

    static let defaultTolerance: TimeInterval = 0.5
    static let currentWindow: TimeInterval = 25
    static let laterTitle = "Later in This Track"
    static let laterSymbol = "forward"

    static func ordered(_ comments: [Comment]) -> [Comment] {
        comments
            .enumerated()
            .compactMap { offset, comment in comment.timeInTrack.map { (comment, $0, offset) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.id != rhs.0.id { return idPrecedes(lhs.0.id, rhs.0.id) }
                return lhs.2 < rhs.2
            }
            .map { $0.0 }
    }

    static func split(
        _ ordered: [Comment],
        at position: TimeInterval,
        tolerance: TimeInterval = defaultTolerance
    ) -> Split {
        split(ordered, at: position, tolerance: tolerance) { $0.timeInTrack ?? 0 }
    }

    static func split<Element>(
        _ ordered: [Element],
        at position: TimeInterval,
        tolerance: TimeInterval = defaultTolerance,
        time: (Element) -> TimeInterval
    ) -> Split {
        var low = 0
        var high = ordered.count
        while low < high {
            let mid = (low + high) / 2
            if time(ordered[mid]) <= position + tolerance { low = mid + 1 } else { high = mid }
        }
        guard low > 0, position - time(ordered[low - 1]) < currentWindow else {
            return Split(reachedCount: low, currentIndex: nil)
        }
        return Split(reachedCount: low, currentIndex: low - 1)
    }

    static func laterAccessibilityLabel(name: String, clock: String, body: String) -> String {
        "\(name), later in the track, at \(clock), \(body)"
    }

    private static func idPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        if let a = Int(lhs), let b = Int(rhs) { return a < b }
        return lhs < rhs
    }
}
