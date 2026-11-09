import ActivityKit
import Foundation

struct NowPlayingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var trackID: String
        var title: String
        var artist: String
        var artworkFile: String?
        var tint: [Double]?
        var isPlaying: Bool
        var position: TimeInterval
        var positionDate: Date
        var duration: TimeInterval
        var outputName: String?
        var nextTitle: String?
        var mixDate: Date?
        var moveLine: String?
        var inMixTitle: String?
        var inMixArtist: String?
        var inMixPosition: String?
        var pausedAt: Date?
        var sleepEndsAt: Date?

        enum Focus {
            case autoMix
            case inMix
            case sleep
        }

        var focus: Focus? {
            if nextTitle != nil { return .autoMix }
            if inMixTitle != nil { return .inMix }
            if sleepEndsAt != nil { return .sleep }
            return nil
        }

        var startDate: Date { positionDate.addingTimeInterval(-position) }

        var timerRange: ClosedRange<Date>? {
            guard duration > 0 else { return nil }
            return startDate...startDate.addingTimeInterval(duration)
        }

        var pausedProgress: Double {
            guard duration > 0 else { return 0 }
            return min(max(position / duration, 0), 1)
        }
    }

    var sessionID: String
}

enum LiveActivityArtworkStore {
    static let directoryName = "LiveActivity"
    static let pixelSize = 144

    static var directory: URL? {
        SoundingAppGroup.writableURL?.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func url(for file: String) -> URL? {
        directory?.appendingPathComponent(file)
    }

    @discardableResult
    static func write(_ data: Data, named file: String) -> Bool {
        guard let directory else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try data.write(to: directory.appendingPathComponent(file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    static func prune(keeping names: Set<String>) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}
