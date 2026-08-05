import Foundation

enum DJTempo {

    static let relations: [(factor: Double, baseCost: Double, label: String)] = [
        (1.0,       0.00, "same tempo"),
        (2.0,       0.06, "double time"),
        (0.5,       0.06, "half time"),
        (1.5,       0.30, "3:2"),
        (2.0 / 3.0, 0.30, "2:3"),
        (4.0 / 3.0, 0.42, "4:3"),
        (0.75,      0.42, "3:4")
    ]

    struct Relation: Equatable, Sendable {
        let factor: Double
        let baseCost: Double
        let label: String
        let residual: Double
        let requiredRate: Double

        var selectionCost: Double { pow(residual / 0.10, 1.8) + baseCost }
    }

    static func best(outgoing: BeatGrid, incoming: BeatGrid) -> Relation? {
        guard outgoing.beatPeriod > 0, incoming.beatPeriod > 0 else { return nil }
        var best: Relation?
        for r in relations {
            let residual = abs(1 - r.factor * outgoing.beatPeriod / incoming.beatPeriod)
            let required = incoming.beatPeriod / (outgoing.beatPeriod * r.factor)
            let candidate = Relation(
                factor: r.factor, baseCost: r.baseCost, label: r.label,
                residual: residual, requiredRate: required
            )
            if best == nil || candidate.selectionCost < best!.selectionCost {
                best = candidate
            }
        }
        return best
    }

    static func applicableRate(_ relation: Relation, profile: DJProfile) -> Double {
        let m = profile.maxAbsRatePercent / 100
        return min(1 + m, max(1 - m, relation.requiredRate))
    }

    static func leftover(_ relation: Relation, appliedRate: Double) -> Double {
        guard relation.requiredRate > 0 else { return 0 }
        return abs(1 - appliedRate / relation.requiredRate)
    }

    static func driftMs(leftover: Double, overlapSeconds: TimeInterval) -> Double {
        leftover * 1000 * overlapSeconds
    }
}

enum DJPointFinder {

    static let maxExits = 8
    static let maxEntries = 6

    static func exitCandidates(in track: TrackFeatures, profile: DJProfile) -> [ExitPoint] {
        guard track.duration.isFinite, track.duration >= DJEngineConstants.minimumPlannableDuration else {
            return []
        }

        let floor = track.duration * profile.exitRegionFloor
        let ceiling = max(floor, track.duration - 2)
        guard floor < ceiling else { return [] }

        var out: [ExitPoint] = []

        if let preferred = track.preferredExitSeconds,
           preferred >= floor, preferred <= ceiling {
            out.append(ExitPoint(
                seconds: preferred,
                kind: track.section(at: preferred),
                barsRemaining: bars(from: preferred, to: track.duration, grid: track.beatGrid),
                onPhraseBoundary: isOnPhrase(preferred, track),
                confidence: 1
            ))
        }

        if track.provenance.contains(.measuredStructure) {
            for section in track.sections where section.start >= floor && section.start <= ceiling {
                out.append(ExitPoint(
                    seconds: section.start,
                    kind: section.kind,
                    barsRemaining: bars(from: section.start, to: track.duration, grid: track.beatGrid),
                    onPhraseBoundary: isOnPhrase(section.start, track),
                    confidence: 0.85
                ))
            }
        }

        for point in envelopeExits(in: track, floor: floor, ceiling: ceiling) {
            out.append(point)
        }

        if profile.allowMidTrackExit, let grid = track.beatGrid,
           track.provenance.contains(.measuredBeatGrid), grid.phraseDuration > 1 {
            var t = grid.anchor
            if t < floor {
                let phrases = ((floor - t) / grid.phraseDuration).rounded(.up)
                t += phrases * grid.phraseDuration
            }
            while t <= ceiling && out.count < maxExits * 3 {
                out.append(ExitPoint(
                    seconds: t,
                    kind: track.section(at: t),
                    barsRemaining: bars(from: t, to: track.duration, grid: grid),
                    onPhraseBoundary: true,
                    confidence: 0.55 * grid.confidence
                ))
                t += grid.phraseDuration
            }
        }

        if out.isEmpty {
            let point = max(floor, track.duration - 4)
            out.append(ExitPoint(
                seconds: point,
                kind: .outro,
                barsRemaining: bars(from: point, to: track.duration, grid: track.beatGrid),
                onPhraseBoundary: isOnPhrase(point, track),
                confidence: 0.25
            ))
        }

        let snapped = out.map { snap($0, track: track, profile: profile) }
        var seen = Set<Int>()
        var unique: [ExitPoint] = []
        for point in snapped.sorted(by: { $0.confidence > $1.confidence }) {
            let bucket = Int((point.seconds / 0.5).rounded())
            if seen.insert(bucket).inserted { unique.append(point) }
        }
        return Array(unique.prefix(maxExits))
    }

    static func entryCandidates(in track: TrackFeatures, profile: DJProfile) -> [EntryPoint] {
        guard track.duration.isFinite, track.duration > 10 else { return [] }
        let ceiling = max(4, track.duration * 0.20)

        var out: [EntryPoint] = []
        let median = envelopeMedian(track.envelope)

        if let preferred = track.preferredEntrySeconds,
           preferred >= 0, preferred < track.duration {
            out.append(EntryPoint(
                seconds: preferred,
                kind: track.section(at: preferred),
                barsUntilNextSection: barsUntilNext(after: preferred, in: track),
                onPhraseBoundary: isOnPhrase(preferred, track),
                hasBassFromHere: hasBody(track, at: preferred, median: median),
                confidence: 1
            ))
        }

        if track.provenance.contains(.measuredStructure) {
            for section in track.sections where section.start <= ceiling {
                out.append(EntryPoint(
                    seconds: section.start,
                    kind: section.kind,
                    barsUntilNextSection: barsUntilNext(after: section.start, in: track),
                    onPhraseBoundary: isOnPhrase(section.start, track),
                    hasBassFromHere: hasBody(track, at: section.start, median: median),
                    confidence: 0.85
                ))
            }
        }

        out.append(EntryPoint(
            seconds: 0,
            kind: track.provenance.contains(.measuredStructure) ? track.section(at: 0) : .intro,
            barsUntilNextSection: barsUntilNext(after: 0, in: track),
            onPhraseBoundary: true,
            hasBassFromHere: hasBody(track, at: 0, median: median),
            confidence: 0.6
        ))

        if let grid = track.beatGrid, track.provenance.contains(.measuredBeatGrid),
           grid.phraseDuration > 1 {
            var t = grid.anchor
            while t <= ceiling && out.count < maxEntries * 3 {
                if t > 0.5 {
                    out.append(EntryPoint(
                        seconds: t,
                        kind: track.section(at: t),
                        barsUntilNextSection: barsUntilNext(after: t, in: track),
                        onPhraseBoundary: true,
                        hasBassFromHere: hasBody(track, at: t, median: median),
                        confidence: 0.65 * grid.confidence
                    ))
                }
                t += grid.phraseDuration
            }
        }

        var seen = Set<Int>()
        var unique: [EntryPoint] = []
        for point in out.sorted(by: { $0.confidence > $1.confidence }) {
            let bucket = Int((point.seconds / 0.5).rounded())
            if seen.insert(bucket).inserted { unique.append(point) }
        }
        return Array(unique.prefix(maxEntries))
    }

    private static func envelopeExits(
        in track: TrackFeatures, floor: TimeInterval, ceiling: TimeInterval
    ) -> [ExitPoint] {
        let envelope = track.envelope
        guard envelope.count >= 8 else { return [] }
        let bucketSeconds = track.duration / Double(envelope.count)
        guard bucketSeconds > 0 else { return [] }

        let quietThreshold = max(0.05, envelopeMedian(envelope) * 0.55)

        let floorBucket = min(envelope.count - 1, max(0, Int(floor / bucketSeconds)))
        let ceilBucket = min(envelope.count - 1, max(floorBucket, Int(ceiling / bucketSeconds)))
        guard floorBucket < ceilBucket else { return [] }

        var out: [ExitPoint] = []
        var i = floorBucket
        while i <= ceilBucket {
            guard Double(envelope[i]) <= quietThreshold else { i += 1; continue }
            let start = i
            while i <= ceilBucket, Double(envelope[i]) <= quietThreshold { i += 1 }
            let length = i - start
            guard length >= 4 else { continue }
            let floorAmplitude = envelope[start..<i].map(Double.init).min() ?? quietThreshold
            let kind: SectionKind = floorAmplitude <= quietThreshold * 0.4 ? .ambientOutro : .breakdown
            let seconds = Double(start) * bucketSeconds
            out.append(ExitPoint(
                seconds: seconds,
                kind: kind,
                barsRemaining: bars(from: seconds, to: track.duration, grid: track.beatGrid),
                onPhraseBoundary: isOnPhrase(seconds, track),
                confidence: min(0.7, 0.35 + Double(length) * 0.02)
            ))
        }
        return out
    }

    static func envelopeMedian(_ envelope: [Float]) -> Double {
        guard !envelope.isEmpty else { return 0 }
        let sorted = envelope.sorted()
        return Double(sorted[sorted.count / 2])
    }

    private static func hasBody(_ track: TrackFeatures, at seconds: TimeInterval, median: Double) -> Bool {
        if track.provenance.contains(.measuredBass) {
            let lookahead = 8.0
            let window = seconds...(seconds + lookahead)
            return track.bassRanges.contains { $0.overlaps(window) }
        }
        guard !track.envelope.isEmpty, track.duration > 0 else { return true }
        let idx = min(track.envelope.count - 1,
                      max(0, Int(seconds / track.duration * Double(track.envelope.count))))
        return Double(track.envelope[idx]) >= median * 0.5
    }

    private static func bars(from: TimeInterval, to: TimeInterval, grid: BeatGrid?) -> Int? {
        guard let grid, grid.barDuration > 0 else { return nil }
        return max(0, Int((to - from) / grid.barDuration))
    }

    private static func barsUntilNext(after seconds: TimeInterval, in track: TrackFeatures) -> Int? {
        guard let grid = track.beatGrid, grid.barDuration > 0 else { return nil }
        guard let next = track.sections.first(where: { $0.start > seconds + 0.5 }) else { return nil }
        return max(0, Int((next.start - seconds) / grid.barDuration))
    }

    private static func isOnPhrase(_ seconds: TimeInterval, _ track: TrackFeatures) -> Bool {
        guard track.beatGrid?.beatPeriod ?? 0 > 0 else { return false }
        return abs(track.beatsFromPhraseBoundary(at: seconds)) < 0.25
    }

    private static func snap(_ point: ExitPoint, track: TrackFeatures, profile: DJProfile) -> ExitPoint {
        // A user's explicit mix-out is an instruction, not a suggestion.
        if let preferred = track.preferredExitSeconds,
           abs(preferred - point.seconds) < 0.001 { return point }
        guard let grid = track.beatGrid else { return point }
        guard grid.confidence >= profile.minGridConfidence, grid.phraseDuration > 1 else {
            return point
        }
        let offsetBeats = track.beatsFromPhraseBoundary(at: point.seconds)
        let snapped = point.seconds - offsetBeats * grid.beatPeriod
        guard snapped > 0 else { return point }
        return ExitPoint(
            seconds: snapped,
            kind: point.kind,
            barsRemaining: point.barsRemaining,
            onPhraseBoundary: true,
            confidence: point.confidence
        )
    }
}

enum DJTemplates {

    static let bassSwapBlend: TransitionTemplateID = "bassSwapBlend"
    static let filterFadeOut: TransitionTemplateID = "filterFadeOut"
    static let filterBloomIn: TransitionTemplateID = "filterBloomIn"
    static let cutOnTheOne: TransitionTemplateID = "cutOnTheOne"
    static let halfTimeBlend: TransitionTemplateID = "halfTimeBlend"
    static let loopRollDown: TransitionTemplateID = "loopRollDown"

    static var v1Registry: TransitionRegistry {
        TransitionRegistry([
            BassSwapBlendTemplate(),
            FilterFadeOutTemplate(),
            FilterBloomInTemplate(),
            HalfTimeBlendTemplate(),
            CutOnTheOneTemplate(),
            LoopRollDownTemplate()
        ])
    }

    static func displayName(for id: TransitionTemplateID) -> String {
        v1Registry.templates[id]?.displayName ?? id.rawValue
    }
}

enum DJBlendMath {

    static func window(bars: Int, grid: BeatGrid?, fallback: TimeInterval) -> TimeInterval {
        let seconds: TimeInterval
        if let grid, grid.barDuration > 0 {
            seconds = grid.barDuration * Double(bars)
        } else {
            seconds = fallback
        }
        return min(DJEngineConstants.maximumTransitionSeconds, seconds)
    }

    static func bassSwap(
        window: TimeInterval,
        grid: BeatGrid?,
        profile: DJProfile
    ) -> (at: TimeInterval, duration: TimeInterval) {
        let beats = profile.allowMidTrackExit ? 1.0 : 2.0

        guard let grid, grid.beatPeriod > 0, grid.phraseDuration > 0 else {
            return (at: window * 0.55, duration: min(0.5, window * 0.2))
        }

        let duration = min(grid.beatPeriod * beats, window * 0.25)
        let target = window * 0.55
        let phrases = (target / grid.phraseDuration).rounded(.down)
        var at = phrases * grid.phraseDuration
        if at < grid.phraseDuration * 0.5 || at + duration > window {
            let bars = (target / grid.barDuration).rounded(.down)
            at = bars * grid.barDuration
        }
        at = min(max(0, at), max(0, window - duration))
        return (at: at, duration: duration)
    }

}

struct BassSwapBlendTemplate: TransitionTemplate {
    let id = DJTemplates.bassSwapBlend
    let displayName = "Bass swap"
    let requiredCapabilities: ExecutorCapabilities = [
        .crossfade, .threeBandEQ, .timeStretch, .entryCue, .snappedBassSwap
    ]

    static let minRunwayBars = 8
    static let minRunwaySeconds: TimeInterval = 12

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard outgoing.duration >= 45 else {
            return .rejected(reason: "\(displayName): \(outgoing.displayName) is only \(Int(outgoing.duration))s, too short to blend out of")
        }
        guard incoming.duration >= 45 else {
            return .rejected(reason: "\(displayName): \(incoming.displayName) is only \(Int(incoming.duration))s, too short to blend into")
        }
        let earliest = outgoing.duration * profile.exitRegionFloor
        guard outgoing.duration - earliest >= Self.minRunwaySeconds else {
            return .rejected(reason: "\(displayName): only \(Int(outgoing.duration - earliest))s of runway past \(Int(profile.exitRegionFloor * 100))% of \(outgoing.displayName), needs \(Int(Self.minRunwaySeconds))s")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        var plans: [DJTransitionPlan] = []
        let relation = DJTempo.grid(outgoing, incoming)

        let bassCapableEntries = entries.filter(\.hasBassFromHere)

        for exit in exits.prefix(3) {
            let available = outgoing.duration - exit.seconds
            guard available >= 4 else { continue }

            for bars in barChoices(profile: profile) {
                var window = DJBlendMath.window(
                    bars: bars, grid: outgoing.beatGrid, fallback: Double(bars) * 1.875
                )
                window = min(window, available - 0.5)
                guard window >= 4 else { continue }

                for entry in bassCapableEntries.prefix(2) {
                    if let untilNext = entry.barsUntilNextSection, untilNext < 4 { continue }

                    let swap = DJBlendMath.bassSwap(
                        window: window, grid: outgoing.beatGrid, profile: profile
                    )
                    plans.append(DJTransitionPlan(
                        templateId: id, profileId: profile.id,
                        outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                        exit: exit, entry: entry,
                        overlapSeconds: window,
                        bassSwapAtSeconds: swap.at, bassSwapSeconds: swap.duration,
                        incomingRateRatio: relation.map { DJTempo.applicableRate($0, profile: profile) } ?? 1,
                        tempoFactor: relation?.factor ?? 1,
                        tempoLabel: relation?.label ?? "tempo unknown",
                        accent: nil,
                        profileMinimumScore: profile.minimumScoreToFire
                    ))
                }
            }
        }
        return plans
    }

    private func barChoices(profile: DJProfile) -> [Int] {
        [4, 8, 16].filter { profile.transitionBarsRange.contains($0) }
    }
}

struct FilterFadeOutTemplate: TransitionTemplate {
    let id = DJTemplates.filterFadeOut
    let displayName = "Filter fade"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .lowPassFilter, .entryCue]

    static let minimumSeconds: TimeInterval = 10

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard outgoing.duration >= DJEngineConstants.minimumPlannableDuration else {
            return .rejected(reason: "\(displayName): \(outgoing.displayName) is too short to sweep out of")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        let usable = exits.filter { $0.kind == .breakdown || $0.kind == .cooldown || $0.kind == .outro }
        guard let entry = entries.first else { return [] }

        var plans: [DJTransitionPlan] = []
        for exit in usable.prefix(3) {
            let available = outgoing.duration - exit.seconds
            let window = min(max(Self.minimumSeconds, available * 0.9),
                             DJEngineConstants.maximumTransitionSeconds)
            guard window >= Self.minimumSeconds, window <= available else { continue }

            let swap = DJBlendMath.bassSwap(window: window, grid: outgoing.beatGrid, profile: profile)
            let relation = DJTempo.grid(outgoing, incoming)
            plans.append(DJTransitionPlan(
                templateId: id, profileId: profile.id,
                outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                exit: exit, entry: entry,
                overlapSeconds: window,
                bassSwapAtSeconds: swap.at, bassSwapSeconds: swap.duration,
                incomingRateRatio: relation.map { DJTempo.applicableRate($0, profile: profile) } ?? 1,
                tempoFactor: relation?.factor ?? 1,
                tempoLabel: relation?.label ?? "tempo unknown",
                accent: .outgoingFilterClose,
                profileMinimumScore: profile.minimumScoreToFire
            ))
        }
        return plans
    }
}

struct FilterBloomInTemplate: TransitionTemplate {
    let id = DJTemplates.filterBloomIn
    let displayName = "Filter bloom"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .lowPassFilter, .entryCue]

    static let minimumSeconds: TimeInterval = 8

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard outgoing.duration >= DJEngineConstants.minimumPlannableDuration else {
            return .rejected(reason: "\(displayName): \(outgoing.displayName) is too short to sweep out of")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        let usable = exits.filter { $0.kind == .ambientOutro || $0.kind == .cooldown }
        guard let entry = entries.first else { return [] }

        var plans: [DJTransitionPlan] = []
        for exit in usable.prefix(3) {
            let available = outgoing.duration - exit.seconds
            let window = min(max(Self.minimumSeconds, available * 0.9),
                             DJEngineConstants.maximumTransitionSeconds)
            guard window >= Self.minimumSeconds, window <= available else { continue }

            let swap = DJBlendMath.bassSwap(window: window, grid: outgoing.beatGrid, profile: profile)
            let relation = DJTempo.grid(outgoing, incoming)
            plans.append(DJTransitionPlan(
                templateId: id, profileId: profile.id,
                outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                exit: exit, entry: entry,
                overlapSeconds: window,
                bassSwapAtSeconds: swap.at, bassSwapSeconds: swap.duration,
                incomingRateRatio: relation.map { DJTempo.applicableRate($0, profile: profile) } ?? 1,
                tempoFactor: relation?.factor ?? 1,
                tempoLabel: relation?.label ?? "tempo unknown",
                accent: .incomingFilterOpen,
                profileMinimumScore: profile.minimumScoreToFire
            ))
        }
        return plans
    }
}

struct HalfTimeBlendTemplate: TransitionTemplate {
    let id = DJTemplates.halfTimeBlend
    let displayName = "Half-time blend"
    let requiredCapabilities: ExecutorCapabilities = [
        .crossfade, .threeBandEQ, .timeStretch, .entryCue, .snappedBassSwap
    ]

    static let maxResidual = 0.01

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard let a = outgoing.beatGrid, let b = incoming.beatGrid,
              outgoing.provenance.contains(.measuredBeatGrid),
              incoming.provenance.contains(.measuredBeatGrid) else {
            return .rejected(reason: "\(displayName): needs a measured beat grid on both tracks")
        }
        guard let relation = DJTempo.best(outgoing: a, incoming: b) else {
            return .rejected(reason: "\(displayName): no usable tempo on one side")
        }
        guard relation.factor == 2.0 || relation.factor == 0.5 else {
            return .rejected(reason: "\(displayName): \(DJFormat.bpm(a.bpm)) against \(DJFormat.bpm(b.bpm)) is not a 2:1 relation")
        }
        guard relation.residual <= Self.maxResidual else {
            return .rejected(reason: "\(displayName): the 2:1 fold still leaves \(DJFormat.percent(relation.residual * 100, decimals: 2)) out - that's a stretch, not a fold")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        guard let a = outgoing.beatGrid, let b = incoming.beatGrid,
              let relation = DJTempo.best(outgoing: a, incoming: b) else { return [] }

        var plans: [DJTransitionPlan] = []
        for exit in exits.prefix(2) {
            let available = outgoing.duration - exit.seconds
            for bars in [8, 16].filter({ profile.transitionBarsRange.contains($0) }) {
                var window = DJBlendMath.window(bars: bars, grid: a, fallback: Double(bars) * 1.875)
                window = min(window, available - 0.5)
                guard window >= 8 else { continue }
                for entry in entries.prefix(2) {
                    let swap = DJBlendMath.bassSwap(window: window, grid: a, profile: profile)
                    plans.append(DJTransitionPlan(
                        templateId: id, profileId: profile.id,
                        outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                        exit: exit, entry: entry,
                        overlapSeconds: window,
                        bassSwapAtSeconds: swap.at, bassSwapSeconds: swap.duration,
                        incomingRateRatio: DJTempo.applicableRate(relation, profile: profile),
                        tempoFactor: relation.factor,
                        tempoLabel: relation.label,
                        accent: nil,
                        profileMinimumScore: profile.minimumScoreToFire
                    ))
                }
            }
        }
        return plans
    }
}

struct CutOnTheOneTemplate: TransitionTemplate {
    let id = DJTemplates.cutOnTheOne
    let displayName = "Clean cut"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade]

    static let fadeSeconds: TimeInterval = 0.05

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        let point = exits.max(by: { $0.seconds < $1.seconds })
            ?? ExitPoint(seconds: max(0, outgoing.duration - 1), kind: .outro,
                         barsRemaining: 0, onPhraseBoundary: false, confidence: 0.2)

        var cutAt = max(point.seconds, outgoing.duration - Self.fadeSeconds - 0.5)
        var onBoundary = point.onPhraseBoundary
        if let grid = outgoing.beatGrid, grid.barDuration > 0.1 {
            let bars = ((cutAt - grid.anchor) / grid.barDuration).rounded(.down)
            let snapped = grid.anchor + bars * grid.barDuration
            if snapped > 0, snapped <= outgoing.duration - Self.fadeSeconds {
                cutAt = snapped
                onBoundary = true
            }
        }
        let latest = ExitPoint(
            seconds: cutAt, kind: point.kind, barsRemaining: point.barsRemaining,
            onPhraseBoundary: onBoundary, confidence: point.confidence
        )
        let entry = entries.first ?? EntryPoint(
            seconds: 0, kind: .intro, barsUntilNextSection: nil,
            onPhraseBoundary: true, hasBassFromHere: true, confidence: 0.5
        )
        return [DJTransitionPlan(
            templateId: id, profileId: profile.id,
            outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
            exit: latest, entry: entry,
            overlapSeconds: Self.fadeSeconds,
            bassSwapAtSeconds: 0, bassSwapSeconds: Self.fadeSeconds,
            incomingRateRatio: 1, tempoFactor: 1, tempoLabel: "no tempo match needed",
            accent: nil,
            profileMinimumScore: profile.minimumScoreToFire
        )]
    }
}

struct LoopRollDownTemplate: TransitionTemplate {
    let id = DJTemplates.loopRollDown
    let displayName = "Loop roll-down"

    let requiredCapabilities: ExecutorCapabilities = [
        .crossfade, .threeBandEQ, .lowPassFilter, .loopBuffer,
        .loopResize, .sampleAccurateCue, .entryCue
    ]

    static let halvingLadder: [Double] = [8, 4, 2, 1]
    static let ownersLadder: [Double] = [8, 6, 4, 2, 1]

    let ladder: [Double]

    init(ladder: [Double] = LoopRollDownTemplate.halvingLadder) {
        self.ladder = ladder
    }

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard profile.allowMidTrackExit else {
            return .rejected(reason: "\(displayName): \(profile.displayName) doesn't cut tracks short")
        }
        guard let grid = outgoing.beatGrid, outgoing.provenance.contains(.measuredBeatGrid),
              grid.confidence >= profile.minGridConfidence else {
            return .rejected(reason: "\(displayName): a loop needs an accurate bar grid and there isn't one")
        }
        let needed = ladder.reduce(0, +) * grid.barDuration
        guard outgoing.duration >= needed + 30 else {
            return .rejected(reason: "\(displayName): the ladder needs \(Int(needed))s and \(outgoing.displayName) is only \(Int(outgoing.duration))s")
        }
        guard ladder.allSatisfy({ $0 > 0 }) else {
            return .rejected(reason: "\(displayName): every rung of the loop ladder needs a positive length")
        }
        guard (ladder.max() ?? 0) <= Double(profile.maxLoopBars) else {
            return .rejected(reason: "\(displayName): \(profile.displayName) limits loops to \(profile.maxLoopBars) bars")
        }
        guard max(0, ladder.count - 1) <= profile.maxLoopHalvings else {
            return .rejected(reason: "\(displayName): \(profile.displayName) only allows \(profile.maxLoopHalvings) loop reductions")
        }
        return .admitted
    }

    func propose(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exits: [ExitPoint], entries: [EntryPoint],
        profile: DJProfile, rng: inout SeededGenerator
    ) -> [DJTransitionPlan] {
        guard let grid = outgoing.beatGrid, grid.barDuration > 0 else { return [] }
        guard let entry = entries.first else { return [] }

        let preferred = exits.filter { $0.kind == .drop || $0.kind == .outro || $0.kind == .unknown }
        let usable = preferred.isEmpty ? Array(exits.prefix(1)) : Array(preferred.prefix(2))
        guard !usable.isEmpty else { return [] }

        var plans: [DJTransitionPlan] = []
        for exit in usable {
            var stages: [TransitionStage] = []
            var t: TimeInterval = 0

            for bars in ladder {
                stages.append(TransitionStage(at: t, on: .outgoing, .loop(bars: bars), snap: .bar))
                t += bars * grid.barDuration
            }

            stages.append(TransitionStage(
                at: 0, on: .outgoing,
                .lowPassTo(hertz: DJEngineConstants.accentClosedFilterHz, over: t),
                snap: .free
            ))

            let fade = CutOnTheOneTemplate.fadeSeconds
            stages.append(TransitionStage(at: t, on: .outgoing, .clearLoop, snap: .bar))
            stages.append(TransitionStage(at: t, on: .outgoing, .hardCut(fadeSeconds: fade), snap: .bar))
            stages.append(TransitionStage(at: t, on: .incoming, .crossfadeTo(position: 1, over: fade), snap: .bar))

            let relation = DJTempo.grid(outgoing, incoming)
            plans.append(DJTransitionPlan(
                templateId: id, profileId: profile.id,
                outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
                exit: exit, entry: entry,
                overlapSeconds: t + fade,
                bassSwapAtSeconds: t, bassSwapSeconds: fade,
                incomingRateRatio: relation.map { DJTempo.applicableRate($0, profile: profile) } ?? 1,
                tempoFactor: relation?.factor ?? 1,
                tempoLabel: relation?.label ?? "tempo unknown",
                accent: .outgoingFilterClose,
                stages: stages,
                profileMinimumScore: profile.minimumScoreToFire
            ))
        }
        return plans
    }
}

extension DJTempo {
    static func grid(_ outgoing: TrackFeatures, _ incoming: TrackFeatures) -> Relation? {
        guard let a = outgoing.beatGrid, let b = incoming.beatGrid else { return nil }
        return best(outgoing: a, incoming: b)
    }
}
