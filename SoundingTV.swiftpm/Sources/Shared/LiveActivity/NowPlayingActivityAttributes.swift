import Foundation
import ActivityKit

/// ActivityKit data model for the SoundingCloud Now Playing Live Activity.
///
/// The static `sessionId` identifies a single continuous playback session. All
/// state that can change while the session is alive lives in `ContentState`.
struct NowPlayingActivityAttributes: ActivityAttributes, Sendable {

    struct ContentState: Codable, Hashable, Sendable {
        var trackTitle: String
        var artistName: String
        var artworkURLString: String?
        var isPlaying: Bool
        var position: TimeInterval
        var duration: TimeInterval
        var isDJModeLive: Bool
        var playbackSource: PlaybackSource = .local
        var outputName: String? = nil
        var controlsPairedDevice: Bool? = nil
        var startedAt: Date? = nil
        var artworkFileName: String? = nil
        var accentHex: String? = nil
        /// One hex digit per bar, 0-15. Compact enough to stay far inside the
        /// 4KB content-state budget.
        var waveformBars: String? = nil
        var mixPointSeconds: TimeInterval? = nil
    }

    enum PlaybackSource: String, Codable, Sendable, CaseIterable {
        case local
        case appleTV
        case mac
        case unknown
    }

    var sessionId: String
}

extension NowPlayingActivityAttributes.ContentState {
    init(playback: PlaybackStatePayload) {
        self.init(
            trackTitle: playback.title ?? "Unknown",
            artistName: playback.artist ?? "",
            artworkURLString: playback.artworkURL,
            isPlaying: playback.isPlaying,
            position: playback.positionSeconds,
            duration: playback.durationSeconds,
            isDJModeLive: playback.isDJEngineLive,
            artworkFileName: SharedArtworkStore.fileName(for: playback.artworkURL)
        )
    }

    var resolvedOutputName: String {
        outputName ?? playbackSource.displayName
    }

    var canControlFromActivity: Bool {
        controlsPairedDevice ?? true
    }

    var hasKnownDuration: Bool { duration > 0 && duration.isFinite }

    var elapsed: TimeInterval {
        guard let startedAt, isPlaying else { return position }
        let ticked = Date().timeIntervalSince(startedAt)
        guard hasKnownDuration else { return max(0, ticked) }
        return min(duration, max(0, ticked))
    }

    var fraction: Double {
        guard hasKnownDuration else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    /// Rebase the extrapolated clock before changing transport state. This is
    /// used by Live Activity intents so an optimistic pause never jumps back
    /// to the position from the activity's last server update.
    func settingPlayback(_ playing: Bool, at date: Date = Date()) -> Self {
        var copy = self
        let currentElapsed: TimeInterval
        if let startedAt, isPlaying {
            let ticked = date.timeIntervalSince(startedAt)
            currentElapsed = hasKnownDuration
                ? min(duration, max(0, ticked))
                : max(0, ticked)
        } else {
            currentElapsed = position
        }
        copy.position = currentElapsed
        copy.isPlaying = playing
        copy.startedAt = playing ? date.addingTimeInterval(-currentElapsed) : nil
        return copy
    }

    /// The window `ProgressView`/`Text` animate across without further pushes.
    var timerRange: ClosedRange<Date>? {
        guard isPlaying, hasKnownDuration, let startedAt else { return nil }
        return startedAt...startedAt.addingTimeInterval(duration)
    }

    var artworkFileURL: URL? {
        artworkFileName.flatMap(SharedArtworkStore.url(forFileName:))
    }

    var waveformLevels: [Double] {
        guard let waveformBars, !waveformBars.isEmpty else { return [] }
        return waveformBars.compactMap { character in
            guard let value = character.hexDigitValue else { return nil }
            return Double(value) / 15.0
        }
    }

    /// Where the DJ engine plans to start the next transition, as a fraction of
    /// the track. Nil when there is no plan or the point has already passed.
    var mixPointFraction: Double? {
        guard hasKnownDuration, let mixPointSeconds, mixPointSeconds > 0 else { return nil }
        let fraction = mixPointSeconds / duration
        guard fraction > 0.02, fraction < 0.995 else { return nil }
        return fraction
    }

    /// Lets the countdown tick on device instead of being pushed each second.
    var mixCountdownRange: ClosedRange<Date>? {
        guard isPlaying, let startedAt, let mixPointSeconds else { return nil }
        let fires = startedAt.addingTimeInterval(mixPointSeconds)
        let remaining = fires.timeIntervalSinceNow
        guard remaining > 0, remaining < 90 else { return nil }
        return Date()...fires
    }

    var secondsUntilMixPoint: TimeInterval? {
        guard let mixPointSeconds, isPlaying else { return nil }
        let remaining = mixPointSeconds - elapsed
        guard remaining > 0, remaining < 90 else { return nil }
        return remaining
    }

    var accentComponents: (red: Double, green: Double, blue: Double)? {
        guard let accentHex, accentHex.count == 6,
              let value = UInt32(accentHex, radix: 16)
        else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    /// When the system should stop presenting this as live. A playing track
    /// goes stale shortly after it would have finished; a paused one holds for
    /// a while, since nothing is expected to change.
    var staleDate: Date? {
        guard isPlaying else { return Date().addingTimeInterval(60 * 60) }
        guard hasKnownDuration, let startedAt else {
            return Date().addingTimeInterval(15 * 60)
        }
        return startedAt.addingTimeInterval(duration + 30)
    }

    /// Treated as materially different only when something a viewer would
    /// notice changed. Position alone must never trigger a push: ActivityKit
    /// budget-limits updates and the timer animates on device.
    func differsMeaningfully(from other: NowPlayingActivityAttributes.ContentState?) -> Bool {
        guard let other else { return true }
        if trackTitle != other.trackTitle { return true }
        if artistName != other.artistName { return true }
        if artworkFileName != other.artworkFileName { return true }
        if accentHex != other.accentHex { return true }
        if waveformBars != other.waveformBars { return true }
        if mixPointSeconds != other.mixPointSeconds { return true }
        if artworkURLString != other.artworkURLString { return true }
        if isPlaying != other.isPlaying { return true }
        if isDJModeLive != other.isDJModeLive { return true }
        if playbackSource != other.playbackSource { return true }
        if outputName != other.outputName { return true }
        if controlsPairedDevice != other.controlsPairedDevice { return true }
        if abs(duration - other.duration) > 1 { return true }
        return abs(elapsed - other.elapsed) > 3
    }
}

extension NowPlayingActivityAttributes.PlaybackSource {
    var displayName: String {
        switch self {
        case .local:  return "iPhone"
        case .appleTV: return "Apple TV"
        case .mac:    return "Mac"
        case .unknown: return "SoundingCloud"
        }
    }

    var iconName: String {
        switch self {
        case .local:  return "iphone"
        case .appleTV: return "appletv.fill"
        case .mac:    return "macwindow"
        case .unknown: return "waveform"
        }
    }
}

enum SharedArtworkStore {
    static let appGroup = "group.red.forbes.sounding"

    private static var directory: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return nil }
        let folder = container.appendingPathComponent("LiveActivityArtwork", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    static func fileName(for urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(urlString.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(hash, radix: 36) + ".img"
    }

    static func url(forFileName name: String) -> URL? {
        directory?.appendingPathComponent(name, isDirectory: false)
    }

    static func hasCachedArtwork(fileName: String?) -> Bool {
        guard let name = fileName, let url = url(forFileName: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @discardableResult
    static func store(_ data: Data, fileName: String) -> URL? {
        guard let url = url(forFileName: fileName) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func prune(keeping keep: Set<String>, limit: Int = 12) {
        guard let directory else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        guard contents.count > limit else { return }

        let sorted = contents.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }

        for url in sorted.dropFirst(limit) where !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
