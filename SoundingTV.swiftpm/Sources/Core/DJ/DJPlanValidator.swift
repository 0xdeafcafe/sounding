import Foundation

struct DJPlanShape: Equatable, Sendable {
    var templateId: TransitionTemplateID?
    var exit: TimeInterval
    var entry: TimeInterval
    var overlap: TimeInterval
    var rate: Double
    var move: MixMove?
    var bassSwapAt: TimeInterval
    var bassSwapSeconds: TimeInterval

    init(templateId: TransitionTemplateID?, exit: TimeInterval, entry: TimeInterval, overlap: TimeInterval, rate: Double, move: MixMove?, bassSwapAt: TimeInterval, bassSwapSeconds: TimeInterval) {
        self.templateId = templateId
        self.exit = exit
        self.entry = entry
        self.overlap = overlap
        self.rate = rate
        self.move = move
        self.bassSwapAt = bassSwapAt
        self.bassSwapSeconds = bassSwapSeconds
    }

    init(_ plan: DJTransitionPlan) {
        self.init(templateId: plan.templateId, exit: plan.exit.seconds, entry: plan.entry.seconds, overlap: plan.overlapSeconds,
                  rate: plan.incomingRateRatio, move: plan.move, bassSwapAt: plan.bassSwapAtSeconds, bassSwapSeconds: plan.bassSwapSeconds)
    }

    init(_ plan: PhantomDJEngine.Plan) {
        self.init(templateId: plan.templateId, exit: plan.mixPointSeconds, entry: plan.entrySeconds, overlap: plan.transitionSeconds,
                  rate: plan.incomingRateRatio, move: plan.move, bassSwapAt: plan.bassSwapAtSeconds, bassSwapSeconds: plan.bassSwapSeconds)
    }

    var isCut: Bool {
        guard move == nil || move?.kind == .cut else { return false }
        return templateId == DJTemplates.cutOnTheOne || overlap <= CutOnTheOneTemplate.fadeSeconds + 0.05
    }
    var isLoopMix: Bool { move?.kind == .loopMix }
}

struct DJSourceMap: Sendable {
    struct Piece: Sendable {
        let wallStart: TimeInterval
        let wallEnd: TimeInterval
        let source: TimeInterval
        let rate: Double

        func source(at t: TimeInterval) -> TimeInterval { source + (t - wallStart) * rate }
        var sourceRange: ClosedRange<TimeInterval> { source...(source + max(0, wallEnd - wallStart) * rate) }
    }

    let outgoing: [Piece]
    let incoming: [Piece]
    let overlapStart: TimeInterval
    let overlapEnd: TimeInterval
    let outgoingLoopSeconds: TimeInterval?
    let incomingLoopSeconds: TimeInterval?
    let releaseWall: TimeInterval?

    var overlapSeconds: TimeInterval { max(0, overlapEnd - overlapStart) }

    init(_ shape: DJPlanShape, outgoing: TrackFeatures, incoming: TrackFeatures?) {
        let bar = outgoing.beatGrid?.barDuration ?? 2
        func outBars(_ k: Int) -> TimeInterval {
            (DJMoveSupport.downbeat(outgoing, from: shape.exit, bars: k) ?? (shape.exit + Double(k) * bar)) - shape.exit
        }
        let end = max(0, shape.overlap)
        let rate = shape.rate > 0 ? shape.rate : 1
        var out: [Piece] = []
        var inc: [Piece] = []
        var start: TimeInterval = 0
        var overlapEnd = end
        var outLoop: TimeInterval?
        var inLoop: TimeInterval?
        var release: TimeInterval?
        if let move = shape.move, move.kind == .loopMix, move.outLoopBars > 0 {
            let length = max(0.1, outBars(move.outLoopBars))
            outLoop = length
            var t: TimeInterval = 0
            while t < end - 1e-6 {
                out.append(Piece(wallStart: t, wallEnd: min(end, t + length), source: shape.exit, rate: 1))
                t += length
            }
            let releaseAt = min(end, DJMoveSupport.wallSeconds(move, outgoing: outgoing, exit: shape.exit, incomingRate: rate, bars: move.leadBars))
            release = releaseAt
            var w: TimeInterval = 0
            if move.inLoopBars > 0 {
                let seconds = incoming.flatMap { DJMoveSupport.downbeat($0, from: shape.entry, bars: move.inLoopBars).map { $0 - shape.entry } }
                    ?? Double(move.inLoopBars) * bar * rate
                inLoop = seconds
                let pass = max(0.1, seconds / rate)
                while w + pass <= releaseAt + 1e-3 {
                    inc.append(Piece(wallStart: w, wallEnd: w + pass, source: shape.entry, rate: rate))
                    w += pass
                }
                if w < releaseAt - 1e-3 {
                    inc.append(Piece(wallStart: w, wallEnd: releaseAt, source: shape.entry, rate: rate))
                    w = releaseAt
                }
                inc.append(Piece(wallStart: w, wallEnd: max(w, end), source: shape.entry + seconds, rate: rate))
            } else {
                inc.append(Piece(wallStart: 0, wallEnd: end, source: shape.entry, rate: rate))
            }
        } else if let move = shape.move {
            if !move.ladder.isEmpty {
                var t: TimeInterval = 0
                var last: TimeInterval = 0
                for rung in move.ladder {
                    let span = max(0.05, outBars(rung.bars))
                    for _ in 0..<max(1, rung.passes) where t < end {
                        out.append(Piece(wallStart: t, wallEnd: min(end, t + span), source: shape.exit, rate: 1))
                        t += span
                    }
                    last = span
                }
                if t < end { out.append(Piece(wallStart: t, wallEnd: end, source: shape.exit + last, rate: 1)) }
            } else {
                out.append(Piece(wallStart: 0, wallEnd: end, source: shape.exit, rate: 1))
            }
            if move.hasOverlap {
                start = DJMoveSupport.wallSeconds(move, outgoing: outgoing, exit: shape.exit, incomingRate: rate, bars: move.landingBar - move.incomingLeadBars)
                overlapEnd = min(end, DJMoveSupport.wallSeconds(move, outgoing: outgoing, exit: shape.exit, incomingRate: rate, bars: move.phraseBars))
            } else {
                start = min(end, DJMoveSupport.wallSeconds(move, outgoing: outgoing, exit: shape.exit, incomingRate: rate, bars: move.landingBar))
                overlapEnd = start
            }
            inc.append(Piece(wallStart: start, wallEnd: max(start, end), source: shape.entry, rate: rate))
        } else {
            out.append(Piece(wallStart: 0, wallEnd: end, source: shape.exit, rate: 1))
            inc.append(Piece(wallStart: 0, wallEnd: end, source: shape.entry, rate: rate))
        }
        self.outgoing = out
        self.incoming = inc
        self.overlapStart = min(start, overlapEnd)
        self.overlapEnd = overlapEnd
        self.outgoingLoopSeconds = outLoop
        self.incomingLoopSeconds = inLoop
        self.releaseWall = release
    }

    static func source(_ pieces: [Piece], at t: TimeInterval) -> TimeInterval? {
        guard let piece = pieces.last(where: { $0.wallStart <= t + 1e-9 }), t <= piece.wallEnd + 1e-6 else { return nil }
        return piece.source(at: min(t, piece.wallEnd))
    }

    func outgoingSource(at t: TimeInterval) -> TimeInterval? { Self.source(outgoing, at: t) }
    func incomingSource(at t: TimeInterval) -> TimeInterval? { Self.source(incoming, at: t) }

    static func ranges(_ pieces: [Piece], from a: TimeInterval, to b: TimeInterval) -> [ClosedRange<TimeInterval>] {
        pieces.compactMap { piece in
            let lo = max(a, piece.wallStart), hi = min(b, piece.wallEnd)
            guard hi > lo else { return nil }
            return piece.source(at: lo)...piece.source(at: hi)
        }
    }

    var outgoingOverlapRanges: [ClosedRange<TimeInterval>] { Self.ranges(outgoing, from: overlapStart, to: overlapEnd) }
    var incomingOverlapRanges: [ClosedRange<TimeInterval>] { Self.ranges(incoming, from: overlapStart, to: overlapEnd) }

    var outgoingSourceExtent: ClosedRange<TimeInterval>? {
        guard let lo = outgoing.map(\.sourceRange.lowerBound).min(), let hi = outgoing.map(\.sourceRange.upperBound).max() else { return nil }
        return lo...hi
    }

    var incomingSourceEnd: TimeInterval? { incoming.last.map { $0.sourceRange.upperBound } }

    func simultaneousSeconds(step: TimeInterval, until limit: TimeInterval? = nil, _ both: (TimeInterval, TimeInterval) -> Bool) -> TimeInterval {
        let stop = min(overlapEnd, limit ?? overlapEnd)
        guard stop > overlapStart, step > 0 else { return 0 }
        var total = 0.0
        var t = overlapStart + step / 2
        while t < stop {
            if let o = outgoingSource(at: t), let i = incomingSource(at: t), both(o, i) { total += step }
            t += step
        }
        return total
    }
}

struct DJRangeIndex: Sendable {
    let ranges: [ClosedRange<TimeInterval>]
    private let reach: [TimeInterval]

    init(_ ranges: [ClosedRange<TimeInterval>]) {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        self.ranges = sorted
        var running = -TimeInterval.infinity
        self.reach = sorted.map { running = max(running, $0.upperBound); return running }
    }

    func contains(_ t: TimeInterval) -> Bool {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].lowerBound <= t { lo = mid + 1 } else { hi = mid }
        }
        var k = lo - 1
        while k >= 0, reach[k] >= t {
            if ranges[k].contains(t) { return true }
            k -= 1
        }
        return false
    }

    func seconds(in range: ClosedRange<TimeInterval>) -> TimeInterval {
        ranges.reduce(0) { $0 + max(0, min($1.upperBound, range.upperBound) - max($1.lowerBound, range.lowerBound)) }
    }

    func touches(_ t: TimeInterval, margin: TimeInterval) -> Bool {
        ranges.contains { $0.lowerBound < t + margin && $0.upperBound > t - margin }
    }
}

enum DJPlanValidator {
    static let maximumRepeatBars = DJMixRules.maximumLoopRepeatBars
    static let maximumLyricRepeatBars = 8
    static let swapBeatTolerance = 1.05
    static let swapTemplates: Set<TransitionTemplateID> = [DJTemplates.bassSwapBlend, DJTemplates.filterFadeOut, DJTemplates.filterBloomIn, DJTemplates.halfTimeBlend]

    static func vocalOverlapSeconds(_ map: DJSourceMap, outgoing: TrackFeatures, incoming: TrackFeatures, step: TimeInterval, shape: DJPlanShape? = nil) -> TimeInterval {
        let a = DJRangeIndex(outgoing.vocalRanges)
        let b = DJRangeIndex(incoming.vocalRanges)
        guard !a.ranges.isEmpty, !b.ranges.isEmpty else { return 0 }
        return map.simultaneousSeconds(step: step, until: shape.flatMap { carveWall($0, outgoing: outgoing) }) { a.contains($0) && b.contains($1) }
    }

    static let carveBars = 2.0

    static func carveWall(_ shape: DJPlanShape, outgoing: TrackFeatures) -> TimeInterval? {
        guard let move = shape.move, move.kind == .blend, move.filter == nil, let bar = outgoing.beatGrid?.barDuration else { return nil }
        return shape.bassSwapAt + carveBars * bar
    }

    static func keyReason(_ map: DJSourceMap, shape: DJPlanShape, outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> String? {
        let bar = max(0.1, outgoing.beatGrid?.barDuration ?? 2)
        let overlapBars = map.overlapSeconds / bar
        guard overlapBars > DJMixRules.keyClashOverlapBars,
              DJMoveSupport.keysClash(outgoing, at: shape.exit, incoming, at: shape.entry, profile: profile) else { return nil }
        if DJMixRules.percussiveOnly(outgoing, sourceRanges: map.outgoingOverlapRanges) == true
            || DJMixRules.percussiveOnly(incoming, sourceRanges: map.incomingOverlapRanges) == true {
            return nil
        }
        return "the keys clash for a \(Int(overlapBars.rounded()))-bar blend"
    }

    static func barIndices(_ track: TrackFeatures, in ranges: [ClosedRange<TimeInterval>]) -> Set<Int> {
        let starts = track.barStarts
        var out = Set<Int>()
        for range in ranges {
            var k = barIndex(track, at: range.lowerBound) ?? 0
            if k < starts.count, starts[k] < range.lowerBound - 0.05 { k += 1 }
            while k < starts.count, starts[k] < range.upperBound - 0.05 {
                out.insert(k)
                k += 1
            }
        }
        return out
    }

    static func barIndex(_ track: TrackFeatures, at seconds: TimeInterval) -> Int? {
        let starts = track.barStarts
        guard let first = starts.first, seconds >= first - 0.05 else { return nil }
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= seconds + 0.05 { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    static func reason(_ plan: PhantomDJEngine.Plan, outgoing: TrackFeatures, incoming: TrackFeatures?, profile: DJProfile?) -> String? {
        reason(DJPlanShape(plan), outgoing: outgoing, incoming: incoming, profile: profile)
    }

    static func reason(_ shape: DJPlanShape, outgoing: TrackFeatures, incoming: TrackFeatures?, profile: DJProfile?) -> String? {
        let beat = outgoing.beatGrid?.beatPeriod ?? 0.5
        let bar = max(0.1, outgoing.beatGrid?.barDuration ?? 2)
        guard shape.exit.isFinite, shape.entry.isFinite, shape.overlap.isFinite, shape.rate.isFinite, shape.rate > 0 else {
            return "the plan has no finite timing"
        }
        guard shape.exit >= -0.01, shape.entry >= -0.01 else { return "the plan starts before a track does" }
        let fileEnd = max(outgoing.duration, outgoing.fileDuration ?? 0)
        if shape.exit > fileEnd { return "the mix would start after the outgoing has ended" }
        let shortBlend = shape.move?.kind == .blend && (shape.move?.blendBars ?? 99) <= DJMixRules.shortBlendBars
        let rateLimit = profile.map { shortBlend ? max($0.maxAbsRatePercent, DJMixRules.shortBlendRatePercent) : $0.maxAbsRatePercent }
        if let profile, let rateLimit, abs(shape.rate - 1) * 100 > rateLimit + 1e-6 {
            return "the tempo would leave \(profile.displayName)'s range"
        }
        if outgoing.isBeatOnly || incoming?.isBeatOnly == true, let reason = DJBeatOnly.reason(shape, bar: bar) { return reason }
        if shape.isCut {
            if let incoming, shape.entry >= incoming.duration - 1 { return "the incoming would start at its end" }
            return nil
        }
        let map = DJSourceMap(shape, outgoing: outgoing, incoming: incoming)
        if let extent = map.outgoingSourceExtent, extent.upperBound > fileEnd + 0.05 {
            return "the outgoing would run out before the mix ends"
        }
        if let move = shape.move {
            if move.kind == .loopMix {
                if move.totalBars - move.outLoopBars > maximumRepeatBars { return "the outgoing loop repeats for more than 16 bars" }
                if move.inLoopBars > 0, move.leadBars - move.inLoopBars > maximumRepeatBars { return "the incoming loop repeats for more than 16 bars" }
            } else if move.repeatedBars > maximumRepeatBars {
                return "loops are capped at 16 bars"
            }
        } else if let id = shape.templateId, swapTemplates.contains(id), map.overlapSeconds > bar {
            if shape.bassSwapAt < -0.01 || shape.bassSwapAt > shape.overlap + 0.01 { return "the bass swap falls outside the blend" }
            if let grid = outgoing.beatGrid, grid.beatPeriod > 0, shape.bassSwapSeconds > grid.beatPeriod * swapBeatTolerance + 0.01 {
                return "the bass swap takes longer than a beat"
            }
        }
        guard let incoming else { return nil }
        if shape.entry >= incoming.duration - 1 { return "the incoming would start at its end" }
        if shape.entry < incoming.contentStart - beat, incoming.preferredEntrySeconds.map({ abs($0 - shape.entry) >= beat }) ?? true {
            return "the incoming would start in silence"
        }
        if let end = map.incomingSourceEnd, incoming.duration - end < DJPlanner.minimumEntryRunwaySeconds - 0.5 {
            return "the incoming would run out too soon after the mix"
        }
        if let move = shape.move, move.kind == .loopMix {
            if let loop = map.outgoingLoopSeconds,
               let reason = loopReason(outgoing, start: shape.exit, seconds: loop, heldBars: move.totalBars, loopBars: move.outLoopBars, side: "outgoing") { return reason }
            if let loop = map.incomingLoopSeconds,
               let reason = loopReason(incoming, start: shape.entry, seconds: loop, heldBars: move.leadBars, loopBars: move.inLoopBars, side: "incoming") { return reason }
            if let reason = loopLevelReason(shape, map: map, outgoing: outgoing, incoming: incoming) { return reason }
        }
        let blendsIn = shape.move?.kind == .blend || (shape.move == nil && shape.templateId.map(swapTemplates.contains) == true)
        if blendsIn, shape.bassSwapAt > 4 * bar + 0.05,
           DJMixRules.incomingIsBusy(incoming, from: shape.entry, to: shape.entry + shape.bassSwapAt * shape.rate) {
            return "the incoming is busy from its first bar, so it cuts in on the 1"
        }
        let bothMeasured = DJMoveSupport.vocalsMeasured(outgoing, incoming)
        let overlapRanges = (out: map.outgoingOverlapRanges, inc: map.incomingOverlapRanges)
        if map.overlapSeconds > beat {
            if bothMeasured {
                if vocalOverlapSeconds(map, outgoing: outgoing, incoming: incoming, step: beat / 2, shape: shape) > beat { return "the vocals would overlap" }
            } else if map.overlapSeconds / bar > DJMixRules.unmeasuredVocalOverlapBars {
                return "vocals aren't measured, so the overlap is capped at 8 bars"
            } else if outgoing.provenance.contains(.measuredVocals),
                      overlapRanges.out.reduce(0, { $0 + DJMoveSupport.vocalSeconds(outgoing, $1) }) > beat {
                return "the outgoing vocal hasn't ended"
            } else if incoming.provenance.contains(.measuredVocals),
                      overlapRanges.inc.reduce(0, { $0 + DJMoveSupport.vocalSeconds(incoming, $1) }) > beat {
                return "the incoming track has vocals in the blend"
            }
        }
        let cue = outgoing.preferredExitSeconds.map { abs($0 - shape.exit) < beat } ?? false
        if !cue, map.overlapSeconds > beat, let meaty = DJMoveRails.meatyBars(outgoing) {
            let covered = barIndices(outgoing, in: overlapRanges.out).filter { $0 < meaty.count && meaty[$0] }.count
            if covered > DJMoveRails.meatyBarsAllowed { return "the mix would run over the outgoing's peak" }
            if let incomingMeaty = DJMoveRails.meatyBars(incoming) {
                let both = map.simultaneousSeconds(step: beat) { o, i in
                    guard let a = barIndex(outgoing, at: o), let b = barIndex(incoming, at: i), a < meaty.count, b < incomingMeaty.count else { return false }
                    return meaty[a] && incomingMeaty[b]
                }
                if both > bar + 0.01 { return "both tracks would be at their peak together" }
            }
        }
        if let profile, let reason = keyReason(map, shape: shape, outgoing: outgoing, incoming: incoming, profile: profile) { return reason }
        return nil
    }

    static func loopReason(_ track: TrackFeatures, start: TimeInterval, seconds: TimeInterval, heldBars: Int, loopBars: Int, side: String) -> String? {
        let end = start + seconds
        let beat = track.beatGrid?.beatPeriod ?? 0.5
        if end > track.duration + 0.05 { return "the \(side) loop runs past the end of the track" }
        guard track.provenance.contains(.measuredVocals) else { return "the \(side) loop's vocals aren't measured" }
        let vocals = DJRangeIndex(track.vocalRanges)
        let margin = LoopMixPlanner.vocalMarginSeconds
        if vocals.touches(start, margin: margin) || vocals.touches(end, margin: margin) {
            return "the \(side) loop would cut a vocal line at its seam"
        }
        guard vocals.seconds(in: start...end) > beat else { return nil }
        if heldBars - loopBars > maximumLyricRepeatBars { return "the \(side) loop would repeat a lyric too often" }
        if barIndices(track, in: [start...end]).contains(where: { DJMoveRails.dropOpening(track, bar: $0) }) {
            return "the \(side) loop would repeat a peak"
        }
        return nil
    }

    static func loopLevelReason(_ shape: DJPlanShape, map: DJSourceMap, outgoing: TrackFeatures, incoming: TrackFeatures) -> String? {
        guard let o = outgoing.barProfile, let i = incoming.barProfile, !o.level.isEmpty, !i.level.isEmpty else { return nil }
        func mean(_ track: TrackFeatures, _ levels: [Float], _ range: ClosedRange<TimeInterval>) -> Float? {
            let bars = barIndices(track, in: [range]).filter { $0 < levels.count }
            guard !bars.isEmpty else { return nil }
            return bars.map { levels[$0] }.reduce(0, +) / Float(bars.count)
        }
        guard let outLevel = mean(outgoing, o.level, shape.exit...(shape.exit + (map.outgoingLoopSeconds ?? 0))),
              let inLevel = mean(incoming, i.level, shape.entry...(shape.entry + max(map.incomingLoopSeconds ?? 0, 0.1))) else { return nil }
        let step = DJMixRules.residualLevelStep(outgoing: outgoing, outgoingLevel: outLevel, incoming: incoming, incomingLevel: inLevel)
        if step > LoopMixPlanner.maxLevelStepDecibels { return "the loops differ by \(Int(step.rounded())) dB after level matching" }
        return nil
    }
}

final class DJPlanFeatureCache: @unchecked Sendable {
    static let shared = DJPlanFeatureCache()
    private let lock = NSLock()
    private var features: [String: TrackFeatures] = [:]
    private var order: [String] = []

    func remember(_ track: TrackFeatures) {
        lock.lock()
        defer { lock.unlock() }
        if features[track.trackId] == nil { order.append(track.trackId) }
        features[track.trackId] = track
        while order.count > 24 { features[order.removeFirst()] = nil }
    }

    func features(for trackId: String?) -> TrackFeatures? {
        guard let trackId else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return features[trackId]
    }
}

extension PhantomDJEngine {
    static func validatedPlan(
        _ inputs: PlanningInputs,
        finish: (Plan) -> Plan,
        attempts: Int = 8
    ) -> (plan: Plan?, result: PlanningResult, rejected: [String]) {
        var (decided, result) = plan(inputs)
        let original = result
        var rejected: [String] = []
        for _ in 0..<attempts {
            guard let candidate = decided else { break }
            let finished = finish(candidate)
            let incoming = inputs.candidates.first { $0.trackId == finished.incomingTrackId }
            guard let reason = DJPlanValidator.reason(finished, outgoing: inputs.outgoing, incoming: incoming, profile: inputs.profile) else {
                return (finished, original, rejected)
            }
            rejected.append(reason)
            let shape = DJPlanShape(candidate)
            let remaining = result.ranked.filter { scored in
                let other = DJPlanShape(scored.plan)
                return !(scored.plan.incomingTrackId == candidate.incomingTrackId && other.templateId == shape.templateId
                         && abs(other.exit - shape.exit) < 0.05 && abs(other.entry - shape.entry) < 0.05)
            }
            guard remaining.count < result.ranked.count else { break }
            result = PlanningResult(ranked: remaining, rejections: result.rejections)
            decided = select(result, inputs: inputs)
        }
        return (nil, original, rejected)
    }
}

enum DJBeatOnly {
    static let minimumGridConfidence = 0.55
    static let minimumBlendBars = 16.0
    static let phraseLockDownbeatConfidence = 0.8

    static func grid(_ tracked: BeatTrackerResult, barsPerPhrase: Int = 8) -> BeatGrid? {
        guard !tracked.isPhaseReliable || tracked.downbeatConfidence < phraseLockDownbeatConfidence, tracked.downbeats.count >= 2 else { return nil }
        return tracked.beatOnlyGrid(barsPerPhrase: barsPerPhrase, anchoredOnStrongestSection: true)
    }

    static func reason(_ shape: DJPlanShape, bar: TimeInterval) -> String? {
        let blendLike = shape.move == nil || shape.move?.kind == .blend
        guard blendLike, !shape.isCut, shape.overlap >= (minimumBlendBars - 0.5) * bar else {
            return "the downbeats are a best guess, so only a blend of 16 bars or more hides a wrong bar"
        }
        return nil
    }
}

extension TrackFeatures {
    var isBeatOnly: Bool { provenance.contains(.guessedBarPhase) && !provenance.contains(.measuredDownbeats) }
}
