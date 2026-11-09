import Foundation
import Combine

struct TrackTrim: Codable, Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval?

    static let minimumLength: TimeInterval = 1

    init(start: TimeInterval = 0, end: TimeInterval? = nil) {
        self.start = start
        self.end = end
    }

    var isEmpty: Bool { start <= 0 && end == nil }

    func playableRange(duration: TimeInterval) -> ClosedRange<TimeInterval> {
        let start = start.isFinite ? max(0, start) : 0
        let end = end.flatMap { $0.isFinite ? $0 : nil }
        guard duration.isFinite, duration > 0 else {
            return start...max(start, end ?? .greatestFiniteMagnitude)
        }
        let length = min(Self.minimumLength, duration)
        let upper = min(duration, max(end ?? duration, length))
        let lower = max(0, min(start, upper - length))
        return lower...upper
    }

    func normalised(duration: TimeInterval) -> TrackTrim? {
        guard duration.isFinite, duration > 0 else {
            let trim = TrackTrim(start: max(0, start), end: end)
            return trim.isEmpty ? nil : trim
        }
        let range = playableRange(duration: duration)
        let trim = TrackTrim(
            start: range.lowerBound,
            end: range.upperBound >= duration - 0.05 ? nil : range.upperBound
        )
        return trim.isEmpty ? nil : trim
    }
}

struct TrackTrimTimeline: Equatable, Sendable {
    let range: ClosedRange<TimeInterval>
    let duration: TimeInterval

    init(range: ClosedRange<TimeInterval>, duration: TimeInterval) {
        self.duration = duration
        self.range = range
    }

    init(trackID: String, duration: TimeInterval) {
        self.init(range: TrackTrimStore.effectiveRange(for: trackID, duration: duration), duration: duration)
    }

    var isTrimmed: Bool {
        guard duration > 0 else { return false }
        return range.lowerBound > 0 || range.upperBound < duration
    }

    var length: TimeInterval { max(0, min(range.upperBound, max(duration, range.lowerBound)) - range.lowerBound) }

    func elapsed(at position: TimeInterval) -> TimeInterval {
        min(length, max(0, position - range.lowerBound))
    }

    func remaining(at position: TimeInterval) -> TimeInterval {
        max(0, length - elapsed(at: position))
    }

    func fraction(at position: TimeInterval) -> Double {
        guard length > 0 else { return 0 }
        return elapsed(at: position) / length
    }

    func position(atFraction fraction: Double) -> TimeInterval {
        range.lowerBound + min(1, max(0, fraction)) * length
    }

    func position(atElapsed elapsed: TimeInterval) -> TimeInterval {
        range.lowerBound + min(length, max(0, elapsed))
    }

    func clamped(_ position: TimeInterval) -> TimeInterval {
        guard position.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, position))
    }
}

final class TrackTrimSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var trims: [String: TrackTrim] = [:]

    func replace(_ trims: [String: TrackTrim]) {
        lock.withLock { self.trims = trims }
    }

    func trim(for trackID: String) -> TrackTrim? {
        lock.withLock { trims[trackID] }
    }
}

enum TrackTrimSuggestion {
    static let silenceThreshold: Float = 0.04
    static let minimumSilence: TimeInterval = 0.75

    static func silence(in samples: [Float], duration: TimeInterval) -> TrackTrim? {
        guard samples.count > 1, duration.isFinite, duration > 0 else { return nil }
        let peak = samples.max() ?? 0
        guard peak > 0 else { return nil }
        let threshold = peak * silenceThreshold
        guard let first = samples.firstIndex(where: { $0 > threshold }),
              let last = samples.lastIndex(where: { $0 > threshold }) else { return nil }
        let step = duration / Double(samples.count)
        let start = Double(max(0, first - 1)) * step
        let end = Double(min(samples.count, last + 2)) * step
        let trim = TrackTrim(
            start: start >= minimumSilence ? start : 0,
            end: duration - end >= minimumSilence ? end : nil
        )
        return trim.normalised(duration: duration)
    }
}

@MainActor
final class TrackTrimStore: ObservableObject {
    static let shared = TrackTrimStore(
        initial: SettingsStore.shared.trackTrims,
        snapshot: live,
        persist: { SettingsStore.shared.setTrackTrims($0) },
        updates: SettingsStore.shared.$trackTrims.eraseToAnyPublisher()
    )

    nonisolated static let live = TrackTrimSnapshot()

    @Published private(set) var trims: [String: TrackTrim]

    private let snapshot: TrackTrimSnapshot
    private let persist: ([String: TrackTrim]) -> Void
    private var updates: AnyCancellable?

    init(
        initial: [String: TrackTrim] = [:],
        snapshot: TrackTrimSnapshot = TrackTrimSnapshot(),
        persist: @escaping ([String: TrackTrim]) -> Void = { _ in },
        updates: AnyPublisher<[String: TrackTrim], Never>? = nil
    ) {
        self.trims = initial
        self.snapshot = snapshot
        self.persist = persist
        snapshot.replace(initial)
        self.updates = updates?
            .removeDuplicates()
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.adopt(value) }
            }
    }

    func trim(for trackID: String) -> TrackTrim? {
        trims[trackID]
    }

    func setTrim(_ trim: TrackTrim?, for trackID: String, duration: TimeInterval) {
        guard !trackID.isEmpty else { return }
        var next = trims
        next[trackID] = trim?.normalised(duration: duration)
        guard next != trims else { return }
        adopt(next)
        persist(next)
    }

    func reset(_ trackID: String) {
        setTrim(nil, for: trackID, duration: 0)
    }

    func effectiveRange(for trackID: String, duration: TimeInterval) -> ClosedRange<TimeInterval> {
        Self.range(trims[trackID], duration: duration)
    }

    func effectiveRange(for track: Track) -> ClosedRange<TimeInterval> {
        effectiveRange(for: track.id, duration: track.duration)
    }

    nonisolated static func effectiveRange(for trackID: String, duration: TimeInterval) -> ClosedRange<TimeInterval> {
        range(live.trim(for: trackID), duration: duration)
    }

    nonisolated static func effectiveRange(for track: Track) -> ClosedRange<TimeInterval> {
        effectiveRange(for: track.id, duration: track.duration)
    }

    nonisolated static func range(_ trim: TrackTrim?, duration: TimeInterval) -> ClosedRange<TimeInterval> {
        if let trim { return trim.playableRange(duration: duration) }
        guard duration.isFinite, duration > 0 else { return 0...TimeInterval.greatestFiniteMagnitude }
        return 0...duration
    }

    private func adopt(_ value: [String: TrackTrim]) {
        guard value != trims else { return }
        trims = value
        snapshot.replace(value)
    }
}
