import Foundation

struct PlaybackAnchor: Equatable, Sendable {
    var position: TimeInterval
    var date: Date
    var rate: Double
    var duration: TimeInterval

    static let idle = PlaybackAnchor(position: 0, date: .distantPast, rate: 0, duration: 0)

    var isAdvancing: Bool { rate > 0 }

    func position(at date: Date) -> TimeInterval {
        let raw = position + rate * max(0, date.timeIntervalSince(self.date))
        let clamped = max(0, raw)
        return duration > 0 ? min(duration, clamped) : clamped
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position(at: date) / duration))
    }

    func nextWholeSecond(after date: Date) -> Date {
        guard rate > 0 else { return date }
        let now = position(at: date)
        return date.addingTimeInterval((floor(now) + 1 - now) / rate)
    }

    func seeking(to position: TimeInterval, at date: Date) -> PlaybackAnchor {
        let bounded = duration > 0 ? min(duration, max(0, position)) : max(0, position)
        return PlaybackAnchor(position: bounded, date: date, rate: rate, duration: duration)
    }

    func reconciled(position: TimeInterval, observedAt: Date, rate: Double, duration: TimeInterval, now: Date = Date()) -> PlaybackAnchor? {
        let rateChanged = rate != self.rate
        let durationChanged = abs(duration - self.duration) > 0.01
        let drift = abs(position - self.position(at: observedAt))
        let tolerance: TimeInterval = isAdvancing ? 0.75 : 0.05
        guard self == .idle || rateChanged || durationChanged || drift > tolerance else { return nil }
        let fresh = now.timeIntervalSince(observedAt) < 0.6
        let date = rateChanged && !fresh ? now : min(observedAt, now)
        return PlaybackAnchor(position: max(0, position), date: date, rate: rate, duration: max(0, duration))
    }
}
