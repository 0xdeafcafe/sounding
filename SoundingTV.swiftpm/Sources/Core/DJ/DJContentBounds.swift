import Foundation

struct DJContentBounds: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let duration: TimeInterval
    let body: Double
    let floor: Double

    static let envelopeFloorRatio = 0.25
    static let barFloorDecibels: Float = 18
    static let smoothingRadiusSeconds: TimeInterval = 2
    static let brokenSilenceSeconds: TimeInterval = 20
    static let brokenFragmentSeconds: TimeInterval = 60
    static let brokenFragmentFraction = 0.2
    static let minimumTrimSeconds: TimeInterval = 1
    static let longOutroBars = 16.0
    static let outroLeadBars = 8.0
    static let bodyRatio = 0.6

    var trimmedTail: TimeInterval { max(0, duration - end) }
    var trimmedHead: TimeInterval { max(0, start) }

    static func measure(_ track: TrackFeatures) -> DJContentBounds {
        let duration = track.duration
        let envelope = envelopeBounds(track.envelope, duration: duration)
        let bars = barBounds(track)
        var start = max(envelope?.start ?? 0, bars?.coversStart == true ? bars?.start ?? 0 : 0)
        var end = min(envelope?.end ?? duration, bars?.coversEnd == true ? bars?.end ?? duration : duration)
        if end - start < min(30, duration * 0.5) {
            start = envelope?.start ?? 0
            end = envelope?.end ?? duration
        }
        if end - start < min(30, duration * 0.5) {
            start = 0
            end = duration
        }
        if end > duration - minimumTrimSeconds { end = duration }
        if start < minimumTrimSeconds { start = 0 }
        return DJContentBounds(
            start: start,
            end: end,
            duration: duration,
            body: envelope?.body ?? 0,
            floor: envelope?.floor ?? 0
        )
    }

    static func level(_ track: TrackFeatures, at seconds: TimeInterval) -> Double? {
        let values = track.envelope
        guard values.count >= 8, track.duration > 0 else { return nil }
        let bucket = track.duration / Double(values.count)
        let radius = max(0, Int((Self.smoothingRadiusSeconds / bucket).rounded()))
        let index = min(values.count - 1, max(0, Int(seconds / bucket)))
        let lo = max(0, index - radius)
        let hi = min(values.count - 1, index + radius)
        let slice = values[lo...hi]
        return Double(slice.reduce(0, +)) / Double(slice.count)
    }

    func isAboveFloor(_ track: TrackFeatures, at seconds: TimeInterval) -> Bool {
        guard seconds >= start - 0.01, seconds < end else { return false }
        guard floor > 0, let level = Self.level(track, at: seconds) else { return true }
        return level >= floor
    }

    static let gapBuckets = 2
    static let gapCheckBars = 8.0

    static let dropOutDecibels: Float = 15
    static let handoverDipDecibels: Float = 4
    static let handoverCheckBars = 2.0
    static let handoverCheckMinimumBars = 8.0

    static func dips(_ track: TrackFeatures, from: TimeInterval, to: TimeInterval) -> Bool {
        guard let profile = track.barProfile, track.barStarts.count == profile.level.count, profile.level.count >= 8 else { return false }
        let sorted = profile.level.filter { $0 > -89 }.sorted()
        guard sorted.count >= 8 else { return false }
        let body = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.75))]
        return track.barStarts.enumerated().contains { index, start in
            start >= from - 0.05 && start < to && profile.level[index] < body - handoverDipDecibels
        }
    }

    static func dropsOut(_ track: TrackFeatures, from: TimeInterval, to: TimeInterval) -> Bool {
        if let profile = track.barProfile, track.barStarts.count == profile.level.count, profile.level.count >= 8 {
            let sorted = profile.level.filter { $0 > -89 }.sorted()
            if sorted.count >= 8 {
                let body = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.75))]
                for (index, start) in track.barStarts.enumerated() where start >= from - 0.05 && start < to {
                    if profile.level[index] < body - dropOutDecibels { return true }
                }
            }
        }
        let values = track.envelope
        guard track.contentFloor > 0, values.count >= 8, track.duration > 0, to > from else { return false }
        let bucket = track.duration / Double(values.count)
        let lo = max(0, Int(from / bucket))
        let hi = min(values.count, Int((to / bucket).rounded(.up)))
        var run = 0
        for i in lo..<max(lo, hi) {
            run = Double(values[i]) < track.contentFloor ? run + 1 : 0
            if run >= gapBuckets { return true }
        }
        return false
    }

    static func hasEnergy(_ track: TrackFeatures, at seconds: TimeInterval) -> Bool {
        guard seconds < track.duration - 0.5 else { return false }
        guard track.contentFloor > 0, let level = level(track, at: seconds) else { return true }
        return level >= track.contentFloor
    }

    func lastBodySeconds(_ track: TrackFeatures) -> TimeInterval? {
        let values = track.envelope
        guard values.count >= 8, track.duration > 0, body > 0 else { return nil }
        let bucket = track.duration / Double(values.count)
        let smoothed = Self.smooth(values, radius: max(1, Int((Self.smoothingRadiusSeconds / bucket).rounded())))
        let limit = min(values.count, Int(end / bucket))
        guard let last = (0..<limit).last(where: { smoothed[$0] >= body * Self.bodyRatio }) else { return nil }
        return Double(last + 1) * bucket
    }

    func outroSeconds(_ track: TrackFeatures) -> TimeInterval {
        guard let lastBody = lastBodySeconds(track) else { return 0 }
        return max(0, end - lastBody)
    }

    func latestMixStart(_ track: TrackFeatures) -> TimeInterval? {
        guard let bar = track.beatGrid?.barDuration, bar > 0 else { return nil }
        guard outroSeconds(track) >= Self.longOutroBars * bar else { return nil }
        return end - Self.outroLeadBars * bar
    }

    static func smooth(_ values: [Float], radius: Int) -> [Double] {
        guard radius > 0, !values.isEmpty else { return values.map(Double.init) }
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for (i, v) in values.enumerated() { prefix[i + 1] = prefix[i] + Double(v) }
        return values.indices.map { i in
            let lo = max(0, i - radius)
            let hi = min(values.count - 1, i + radius)
            return (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
    }

    private static func envelopeBounds(_ values: [Float], duration: TimeInterval) -> (start: TimeInterval, end: TimeInterval, body: Double, floor: Double)? {
        guard values.count >= 8, duration > 0 else { return nil }
        let bucket = duration / Double(values.count)
        let smoothed = smooth(values, radius: max(1, Int((smoothingRadiusSeconds / bucket).rounded())))
        let audible = smoothed.filter { $0 > 0.02 }.sorted()
        guard audible.count >= 8 else { return nil }
        let body = audible[min(audible.count - 1, Int(Double(audible.count) * 0.75))]
        let floor = body * envelopeFloorRatio
        let above = smoothed.map { $0 >= floor }
        guard var first = above.firstIndex(of: true), var last = above.lastIndex(of: true) else { return nil }
        let gap = max(1, Int((brokenSilenceSeconds / bucket).rounded()))
        let fragment = min(brokenFragmentSeconds, duration * brokenFragmentFraction)
        var runs: [Range<Int>] = []
        var runStart: Int?
        for i in first...last {
            if above[i] {
                if let s = runStart, i - s >= gap { runs.append(s..<i) }
                runStart = nil
            } else if runStart == nil {
                runStart = i
            }
        }
        for run in runs.reversed() where Double(last + 1 - run.upperBound) * bucket <= fragment {
            last = run.lowerBound - 1
        }
        for run in runs where run.upperBound <= last && Double(run.lowerBound - first) * bucket <= fragment {
            first = run.upperBound
        }
        return (Double(first) * bucket, Double(last + 1) * bucket, body, floor)
    }

    static let barCoverageBars = 8.0

    private static func barBounds(_ track: TrackFeatures) -> (start: TimeInterval, end: TimeInterval, coversStart: Bool, coversEnd: Bool)? {
        guard let profile = track.barProfile, track.barStarts.count == profile.level.count, profile.level.count >= 8 else { return nil }
        let measured = profile.level.filter { $0 > -89 }.sorted()
        guard measured.count >= 8 else { return nil }
        let body = measured[min(measured.count - 1, Int(Double(measured.count) * 0.75))]
        let floor = body - barFloorDecibels
        guard let first = profile.level.firstIndex(where: { $0 >= floor }),
              let last = profile.level.lastIndex(where: { $0 >= floor }) else { return nil }
        let starts = track.barStarts
        let bar = starts.count > 1 ? (starts[starts.count - 1] - starts[0]) / Double(starts.count - 1) : 2
        let end = last + 1 < starts.count ? starts[last + 1] : starts[last] + bar
        let coverage = barCoverageBars * bar
        return (
            starts[first],
            min(track.duration, end),
            starts[0] <= coverage,
            (starts.last ?? 0) + bar >= track.duration - coverage
        )
    }
}

extension TrackFeatures {
    var contentBounds: DJContentBounds { DJContentBounds.measure(self) }

    func planningView(earliestExit: TimeInterval = 0, playable: ClosedRange<TimeInterval>? = nil) -> TrackFeatures {
        let bounds = contentBounds
        let end = min(bounds.end, playable?.upperBound ?? duration)
        var view = end < duration - 0.5 ? trimmed(to: end) : self
        view.contentStart = max(bounds.start, playable?.lowerBound ?? 0)
        view.earliestExitSeconds = max(view.earliestExitSeconds, earliestExit)
        view.contentFloor = bounds.floor
        view.latestMixStart = view.contentBounds.latestMixStart(view)
        return view
    }

    func entryView(playable: ClosedRange<TimeInterval>? = nil) -> TrackFeatures {
        var view = self
        let bounds = contentBounds
        let intro = DJIntro.analyse(self, contentStart: max(bounds.start, playable?.lowerBound ?? 0))
        view.contentStart = intro.earliestEntry
        view.contentFloor = bounds.floor
        view.intro = intro
        return view
    }

    func trimmed(to end: TimeInterval) -> TrackFeatures {
        guard end > 0, end < duration else { return self }
        let bucket = envelope.isEmpty ? 0 : duration / Double(envelope.count)
        let keptBuckets = bucket > 0 ? max(8, min(envelope.count, Int(end / bucket))) : 0
        let newEnd = bucket > 0 ? Double(keptBuckets) * bucket : end
        let barCount = barStarts.firstIndex { $0 >= newEnd - 0.01 } ?? barStarts.count
        let profile = barProfile.flatMap { p -> BarProfile? in
            guard p.level.count == barStarts.count else { return p }
            let n = min(barCount, p.level.count)
            return BarProfile(
                level: Array(p.level.prefix(n)), density: Array(p.density.prefix(n)),
                loop4: Array(p.loop4.prefix(n)), loop8: Array(p.loop8.prefix(n)),
                bands: p.bands.map { Array($0.prefix(n * 4)) }, tonality: p.tonality.map { Array($0.prefix(n)) }
            )
        }
        var copy = TrackFeatures(
            trackId: trackId,
            title: title,
            artist: artist,
            duration: newEnd,
            beatGrid: beatGrid,
            swingRatio: swingRatio,
            keyRegions: keyRegions,
            sections: sections.compactMap { $0.start < newEnd ? TrackSection(kind: $0.kind, start: $0.start, end: min($0.end, newEnd)) : nil },
            phraseBoundaries: phraseBoundaries.filter { $0 < newEnd },
            energyLevel: energyLevel,
            envelope: bucket > 0 ? Array(envelope.prefix(keptBuckets)) : envelope,
            genre: genre,
            vocalRanges: vocalRanges.compactMap { $0.lowerBound < newEnd ? $0.lowerBound...min($0.upperBound, newEnd) : nil },
            bassRanges: bassRanges.compactMap { $0.lowerBound < newEnd ? $0.lowerBound...min($0.upperBound, newEnd) : nil },
            preferredEntrySeconds: preferredEntrySeconds,
            preferredExitSeconds: preferredExitSeconds,
            provenance: provenance,
            cueHints: cueHints,
            extensionLoop: extensionLoop,
            heat: heat,
            boundaries: boundaries.filter { $0 < newEnd },
            barProfile: profile,
            barStarts: profile == nil ? barStarts : Array(barStarts.prefix(min(barCount, barStarts.count)))
        )
        copy.contentStart = contentStart
        copy.earliestExitSeconds = earliestExitSeconds
        copy.contentFloor = contentFloor
        copy.latestMixStart = latestMixStart
        copy.fileDuration = fileDuration ?? duration
        copy.loopRanges = loopRanges.filter { $0.upperBound <= newEnd + 0.01 }
        return copy
    }
}
