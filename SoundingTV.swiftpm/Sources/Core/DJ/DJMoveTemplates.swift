import Foundation

enum DJMoveIDs {
    static let blend: TransitionTemplateID = "move.blend"
    static let cut: TransitionTemplateID = "move.cut"
    static let echoOut: TransitionTemplateID = "move.echoOut"
    static let breakdownExit: TransitionTemplateID = "move.breakdownExit"
    static let dropIn: TransitionTemplateID = "move.dropIn"
    static let dropOnTheOne: TransitionTemplateID = "move.dropOnTheOne"
    static let loopRoll: TransitionTemplateID = "move.loopRoll"
    static let filterBuild: TransitionTemplateID = "move.filterBuild"
    static let echoBuild: TransitionTemplateID = "move.echoBuild"
    static let reverbWash: TransitionTemplateID = "move.reverbWash"
    static let tempoRamp: TransitionTemplateID = "move.tempoRamp"
    static let bridge: TransitionTemplateID = "move.bridge"
    static let jump: TransitionTemplateID = "move.jump"
    static let loopMix: TransitionTemplateID = "move.loopMix"

    static let all: [TransitionTemplateID] = [
        blend, cut, echoOut, breakdownExit, dropIn, dropOnTheOne, loopRoll,
        filterBuild, echoBuild, reverbWash, tempoRamp, bridge, loopMix
    ]

    static var templates: [any TransitionTemplate] {
        [
            MoveBlendTemplate(), MoveCutTemplate(), MoveEchoOutTemplate(), BreakdownExitTemplate(),
            DropInTemplate(), DropOnTheOneTemplate(), LoopRollBuildTemplate(),
            FXBuildTemplate(id: filterBuild, effect: .filterSweep, displayName: "Filter build"),
            FXBuildTemplate(id: echoBuild, effect: .echo, displayName: "Echo build"),
            FXBuildTemplate(id: reverbWash, effect: .reverbWash, displayName: "Reverb wash"),
            TempoRampMoveTemplate(), BridgeMoveTemplate(), LoopMixTemplate()
        ]
    }
}

enum DJMoveSupport {
    static let maximumRampPercentPerBar = 0.5
    static let maximumLoopRepeatBars = DJMixRules.maximumLoopRepeatBars
    static let minimumJumpBars = 32
    static let boundaryClearanceBars = 16

    static func measured(_ track: TrackFeatures, _ profile: DJProfile) -> Bool {
        guard let grid = track.beatGrid, track.provenance.contains(.measuredBeatGrid) else { return false }
        if track.isBeatOnly { return grid.confidence >= min(profile.minGridConfidence, DJBeatOnly.minimumGridConfidence) }
        guard grid.isPhaseVerified else { return false }
        return grid.confidence >= profile.minGridConfidence
    }

    static func downbeats(_ track: TrackFeatures) -> [TimeInterval] {
        (track.beatGrid?.downbeats ?? []).sorted()
    }

    static func downbeatIndex(_ track: TrackFeatures, near seconds: TimeInterval, tolerance: TimeInterval = 0.05) -> Int? {
        let bars = downbeats(track)
        guard !bars.isEmpty else { return nil }
        var lo = 0
        var hi = bars.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if bars[mid] < seconds { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [lo - 1, lo].filter { $0 >= 0 && $0 < bars.count }
        guard let best = candidates.min(by: { abs(bars[$0] - seconds) < abs(bars[$1] - seconds) }),
              abs(bars[best] - seconds) <= tolerance else { return nil }
        return best
    }

    static func downbeat(_ track: TrackFeatures, from seconds: TimeInterval, bars: Int) -> TimeInterval? {
        guard let index = downbeatIndex(track, near: seconds) else { return nil }
        let list = downbeats(track)
        let target = index + bars
        guard target >= 0, target < list.count else { return nil }
        return list[target]
    }

    static func barsBetween(_ track: TrackFeatures, _ a: TimeInterval, _ b: TimeInterval) -> Int? {
        guard let i = downbeatIndex(track, near: a), let j = downbeatIndex(track, near: b) else { return nil }
        return j - i
    }

    static func snapToDownbeat(_ track: TrackFeatures, _ seconds: TimeInterval) -> TimeInterval? {
        guard let index = downbeatIndex(track, near: seconds, tolerance: (track.beatGrid?.barDuration ?? 2) / 2) else { return nil }
        return downbeats(track)[index]
    }

    static func isPhraseLine(_ track: TrackFeatures, _ seconds: TimeInterval) -> Bool {
        guard let grid = track.beatGrid, grid.beatPeriod > 0 else { return false }
        return abs(track.beatsFromPhraseBoundary(at: seconds)) < 0.25
    }

    static func drops(_ track: TrackFeatures) -> [TimeInterval] {
        var out = track.sections.filter { $0.kind == .drop }.map(\.start)
        out += track.cueHints.filter { $0.role == .entry && $0.label.lowercased().contains("drop") }.map(\.seconds)
        let snapped = out.compactMap { snapToDownbeat(track, $0) }
        var seen = Set<Int>()
        return snapped.sorted().filter { seen.insert(Int(($0 * 10).rounded())).inserted }
    }

    static func breakdowns(_ track: TrackFeatures) -> [TrackSection] {
        var out = track.sections.filter { $0.kind == .breakdown || $0.kind == .cooldown }
        for hint in track.cueHints where hint.role == .entry && hint.label.lowercased().contains("break") {
            let end = track.sections.first { $0.start > hint.seconds + 1 }?.start ?? min(track.duration, hint.seconds + 16 * (track.beatGrid?.barDuration ?? 2))
            out.append(TrackSection(kind: .breakdown, start: hint.seconds, end: end))
        }
        return out.sorted { $0.start < $1.start }
    }

    static let unmeasuredVocalMidCutDecibels: Double = -9

    static func vocalsMeasured(_ a: TrackFeatures, _ b: TrackFeatures) -> Bool {
        a.provenance.contains(.measuredVocals) && b.provenance.contains(.measuredVocals)
    }

    static func vocalSeconds(_ track: TrackFeatures, _ range: ClosedRange<TimeInterval>) -> TimeInterval {
        track.vocalRanges.reduce(0) { $0 + max(0, min($1.upperBound, range.upperBound) - max($1.lowerBound, range.lowerBound)) }
    }

    static func keySteps(_ outgoing: TrackFeatures, at exit: TimeInterval, _ incoming: TrackFeatures, at entry: TimeInterval) -> Int? {
        guard outgoing.provenance.contains(.measuredKey), incoming.provenance.contains(.measuredKey),
              let a = outgoing.key(at: exit), let b = incoming.key(at: entry) else { return nil }
        return DJMixRules.keySteps(a, b)
    }

    static func keysClash(_ outgoing: TrackFeatures, at exit: TimeInterval, _ incoming: TrackFeatures, at entry: TimeInterval, profile: DJProfile) -> Bool {
        guard let steps = keySteps(outgoing, at: exit, incoming, at: entry) else { return false }
        return steps > profile.maxCamelotSteps
    }

    static func wallSeconds(_ move: MixMove, outgoing: TrackFeatures, exit: TimeInterval, incomingRate: Double, bars: Int? = nil) -> TimeInterval {
        let input = MixTransitionTimelineInput(
            outgoing: 0, incoming: 1, sampleRate: DJEngineConstants.canonicalSampleRate,
            anchorSourceSeconds: exit, window: 0, entrySeconds: 0,
            outgoingRate: 1, incomingRate: incomingRate,
            outgoingGrid: outgoing.beatGrid, incomingGrid: nil, stages: [],
            bassSwapAtSeconds: nil, bassSwapSeconds: nil, filterAccent: nil,
            defersIncomingStart: false, phaseLock: false, move: move
        )
        return MixMoveBuilder(move: move, input: input).wall(bars ?? move.totalBars)
    }

    static func overlapWindow(_ plan: DJTransitionPlan, outgoing: TrackFeatures) -> (start: TimeInterval, length: TimeInterval) {
        guard let move = plan.move else { return (0, plan.overlapSeconds) }
        guard move.hasOverlap else { return (0, 0) }
        let start = wallSeconds(move, outgoing: outgoing, exit: plan.exit.seconds, incomingRate: plan.incomingRateRatio, bars: move.landingBar - move.incomingLeadBars)
        let end = wallSeconds(move, outgoing: outgoing, exit: plan.exit.seconds, incomingRate: plan.incomingRateRatio, bars: move.phraseBars)
        return (start, max(0, end - start))
    }

    static func exitPoint(_ track: TrackFeatures, _ seconds: TimeInterval, confidence: Double) -> ExitPoint {
        ExitPoint(
            seconds: seconds,
            kind: track.section(at: seconds),
            barsRemaining: track.beatGrid.map { max(0, Int((track.duration - seconds) / max(0.1, $0.barDuration))) },
            onPhraseBoundary: isPhraseLine(track, seconds),
            confidence: confidence
        )
    }

    static func entryPoint(_ track: TrackFeatures, _ seconds: TimeInterval, kind: SectionKind? = nil, confidence: Double) -> EntryPoint {
        let next = track.sections.first { $0.start > seconds + 0.5 }
        return EntryPoint(
            seconds: seconds,
            kind: kind ?? track.section(at: seconds),
            barsUntilNextSection: next.flatMap { section in track.beatGrid.map { Int((section.start - seconds) / max(0.1, $0.barDuration)) } },
            onPhraseBoundary: isPhraseLine(track, seconds),
            hasBassFromHere: true,
            confidence: confidence
        )
    }

    static func plan(
        _ id: TransitionTemplateID,
        _ move: MixMove,
        profile: DJProfile,
        outgoing: TrackFeatures,
        incoming: TrackFeatures,
        exit: ExitPoint,
        entry: EntryPoint,
        relation: DJTempo.Relation?,
        ratePercent: Double? = nil
    ) -> DJTransitionPlan {
        let limit = (ratePercent ?? profile.maxAbsRatePercent) / 100
        let rate = relation.map { min(1 + limit, max(1 - limit, $0.requiredRate)) } ?? 1
        let overlap = wallSeconds(move, outgoing: outgoing, exit: exit.seconds, incomingRate: rate)
        let swapBar = move.landingBar + (move.bassSwapBar ?? 0)
        let swap = wallSeconds(move, outgoing: outgoing, exit: exit.seconds, incomingRate: rate, bars: swapBar)
        return DJTransitionPlan(
            templateId: id,
            profileId: profile.id,
            outgoingTrackId: outgoing.trackId,
            incomingTrackId: incoming.trackId,
            exit: exit,
            entry: entry,
            overlapSeconds: max(CutOnTheOneTemplate.fadeSeconds, overlap),
            bassSwapAtSeconds: min(swap, overlap),
            bassSwapSeconds: outgoing.beatGrid?.beatPeriod ?? 0.5,
            incomingRateRatio: rate,
            tempoFactor: relation?.factor ?? 1,
            tempoLabel: relation?.label ?? "tempo unknown",
            accent: nil,
            profileMinimumScore: profile.minimumScoreToFire,
            move: move
        )
    }

    static func landingEntries(_ incoming: TrackFeatures, entries: [EntryPoint]) -> [EntryPoint] {
        var out: [EntryPoint] = drops(incoming).map { entryPoint(incoming, $0, kind: .drop, confidence: 0.85) }
        out += entries.filter { $0.hasBassFromHere }
        var seen = Set<Int>()
        return out.filter { seen.insert(Int(($0.seconds * 2).rounded())).inserted }
    }

    static func landingExits(_ outgoing: TrackFeatures, exits: [ExitPoint], profile: DJProfile, leadBars: Int) -> [(exit: ExitPoint, landing: TimeInterval)] {
        let floor = outgoing.duration * profile.moveExitFloor
        var out: [(ExitPoint, TimeInterval)] = []
        for point in exits {
            guard let landing = snapToDownbeat(outgoing, point.seconds),
                  let start = downbeat(outgoing, from: landing, bars: -leadBars),
                  start >= floor else { continue }
            out.append((ExitPoint(
                seconds: start,
                kind: outgoing.section(at: start),
                barsRemaining: point.barsRemaining,
                onPhraseBoundary: isPhraseLine(outgoing, start),
                confidence: point.confidence >= 1 ? 1 : point.confidence * 0.95
            ), landing))
        }
        return out
    }

    static func loopRegionIsClean(_ track: TrackFeatures, start: TimeInterval, bars: Int) -> Bool {
        guard let end = downbeat(track, from: start, bars: bars) else { return false }
        if track.provenance.contains(.measuredVocals) {
            guard vocalSeconds(track, start...end) < 0.05 else { return false }
        } else {
            return false
        }
        guard !track.envelope.isEmpty, track.duration > 0 else { return true }
        let lo = max(0, Int(start / track.duration * Double(track.envelope.count)))
        let hi = min(track.envelope.count, max(lo + 1, Int(end / track.duration * Double(track.envelope.count))))
        let slice = track.envelope[lo..<hi].map(Double.init)
        guard let low = slice.min(), let high = slice.max(), high > 0 else { return false }
        return low / high >= 0.45
    }
}

struct MoveBlendTemplate: TransitionTemplate {
    let id = DJMoveIDs.blend
    let displayName = "Blend"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .threeBandEQ, .timeStretch, .entryCue, .sampleAccurateCue, .mixTimeline]

    static let holdBars = [2, 4]

    static func heldOverDip(_ option: DJHandover.Option, move: MixMove, outgoing: TrackFeatures, incoming: TrackFeatures) -> MixMove? {
        guard option.bars >= 16, let bar = incoming.beatGrid?.barDuration, bar > 0,
              let arrival = DJMoveSupport.downbeat(incoming, from: option.arrival, bars: option.bars - option.swapBars),
              DJContentBounds.dips(incoming, from: arrival - bar, to: arrival + DJContentBounds.handoverCheckBars * bar) else { return nil }
        for hold in holdBars {
            guard let end = DJMoveSupport.downbeat(outgoing, from: option.exit.seconds, bars: option.bars + hold), end < outgoing.duration - 1,
                  let later = DJMoveSupport.downbeat(incoming, from: arrival, bars: hold) else { return nil }
            if DJContentBounds.dips(incoming, from: later - bar, to: later + DJContentBounds.handoverCheckBars * bar) { continue }
            var held = MixMove.blend(bars: option.bars + hold, swapAt: option.swapBars)
            held.shape = move.shape
            return held
        }
        return nil
    }

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard DJMoveSupport.measured(outgoing, profile), DJMoveSupport.measured(incoming, profile) else {
            return .rejected(reason: "\(displayName): blending needs measured downbeats on both tracks")
        }
        return .admitted
    }

    func propose(outgoing: TrackFeatures, incoming: TrackFeatures, exits: [ExitPoint], entries: [EntryPoint], profile: DJProfile, rng: inout SeededGenerator) -> [DJTransitionPlan] {
        var plans: [DJTransitionPlan] = []
        let landing = DJMoveSupport.landingExits(outgoing, exits: exits, profile: profile, leadBars: 0).map(\.exit)
        let lengths = DJHandover.lengths.filter { profile.transitionBarsRange.contains($0) }
        let handovers = DJHandover.options(outgoing: outgoing, incoming: incoming, exits: landing, entries: entries, profile: profile, lengths: lengths)
        if !handovers.isEmpty {
            for option in handovers {
                let relation = DJTempo.local(outgoing, exit: option.exit.seconds, overlap: option.window, incoming, entry: option.entry.seconds)
                var move = MixMove.blend(bars: option.bars, swapAt: option.swapBars)
                if DJMixRules.incomingIsBusy(incoming, from: option.entry.seconds, to: option.arrival) {
                    move.shape = MixMoveShape(incomingHighPassHertz: DJMixRules.busyHighPassHertz)
                }
                let short = option.bars <= DJMixRules.shortBlendBars
                plans.append(DJMoveSupport.plan(id, move, profile: profile, outgoing: outgoing, incoming: incoming, exit: option.exit, entry: option.entry, relation: relation, ratePercent: short ? max(profile.maxAbsRatePercent, DJMixRules.shortBlendRatePercent) : nil))
                if let held = Self.heldOverDip(option, move: move, outgoing: outgoing, incoming: incoming) {
                    plans.append(DJMoveSupport.plan(id, held, profile: profile, outgoing: outgoing, incoming: incoming, exit: option.exit, entry: option.entry, relation: relation, ratePercent: short ? max(profile.maxAbsRatePercent, DJMixRules.shortBlendRatePercent) : nil))
                }
            }
            return plans
        }
        for exit in landing.prefix(DJHandover.maximumExits) {
            for bars in lengths {
                guard let end = DJMoveSupport.downbeat(outgoing, from: exit.seconds, bars: bars), end < outgoing.duration - 1 else { continue }
                for entry in entries.filter(\.hasBassFromHere).prefix(DJHandover.maximumFallbackEntries) {
                    let relation = DJTempo.local(outgoing, exit: exit.seconds, overlap: end - exit.seconds, incoming, entry: entry.seconds)
                    plans.append(DJMoveSupport.plan(id, .blend(bars: bars, swapAt: bars >= 16 ? bars / 2 : nil), profile: profile, outgoing: outgoing, incoming: incoming, exit: exit, entry: entry, relation: relation))
                }
            }
        }
        return plans
    }
}

struct MoveCutTemplate: TransitionTemplate {
    let id = DJMoveIDs.cut
    let displayName = "Cut"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .entryCue, .sampleAccurateCue, .mixTimeline]

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard DJMoveSupport.measured(outgoing, profile), DJMoveSupport.measured(incoming, profile) else {
            return .rejected(reason: "\(displayName): a cut on the one needs measured downbeats")
        }
        return .admitted
    }

    func propose(outgoing: TrackFeatures, incoming: TrackFeatures, exits: [ExitPoint], entries: [EntryPoint], profile: DJProfile, rng: inout SeededGenerator) -> [DJTransitionPlan] {
        DJMoveSupport.landingExits(outgoing, exits: exits, profile: profile, leadBars: 0).prefix(3).flatMap { exit, _ in
            DJMoveSupport.landingEntries(incoming, entries: entries).prefix(2).map { entry in
                DJMoveSupport.plan(id, .cut, profile: profile, outgoing: outgoing, incoming: incoming, exit: exit, entry: entry, relation: DJTempo.grid(outgoing, incoming))
            }
        }
    }
}

struct MoveEchoOutTemplate: TransitionTemplate {
    let id = DJMoveIDs.echoOut
    let displayName = "Echo out"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .delayPerDeck, .entryCue, .sampleAccurateCue, .mixTimeline]

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard DJMoveSupport.measured(outgoing, profile), DJMoveSupport.measured(incoming, profile) else {
            return .rejected(reason: "\(displayName): the throw is beat-synced and needs measured downbeats")
        }
        return .admitted
    }

    func propose(outgoing: TrackFeatures, incoming: TrackFeatures, exits: [ExitPoint], entries: [EntryPoint], profile: DJProfile, rng: inout SeededGenerator) -> [DJTransitionPlan] {
        DJMoveSupport.landingExits(outgoing, exits: exits, profile: profile, leadBars: 1).prefix(3).flatMap { exit, _ in
            DJMoveSupport.landingEntries(incoming, entries: entries).prefix(2).map { entry in
                DJMoveSupport.plan(id, .echoOut, profile: profile, outgoing: outgoing, incoming: incoming, exit: exit, entry: entry, relation: DJTempo.grid(outgoing, incoming))
            }
        }
    }
}

struct BreakdownExitTemplate: TransitionTemplate {
    let id = DJMoveIDs.breakdownExit
    let displayName = "Breakdown exit"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .threeBandEQ, .lowPassFilter, .timeStretch, .entryCue, .sampleAccurateCue, .mixTimeline]

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard DJMoveSupport.measured(outgoing, profile), DJMoveSupport.measured(incoming, profile) else {
            return .rejected(reason: "\(displayName): needs measured downbeats on both tracks")
        }
        let floor = outgoing.duration * profile.moveExitFloor
        guard DJMoveSupport.breakdowns(outgoing).contains(where: { $0.start >= floor }) else {
            return .rejected(reason: "\(displayName): no breakdown left in \(outgoing.displayName)")
        }
        return .admitted
    }

    func propose(outgoing: TrackFeatures, incoming: TrackFeatures, exits: [ExitPoint], entries: [EntryPoint], profile: DJProfile, rng: inout SeededGenerator) -> [DJTransitionPlan] {
        let floor = outgoing.duration * profile.moveExitFloor
        let intros = entries.filter { $0.kind == .intro || $0.kind == .ambientIntro || $0.kind == .buildup || $0.kind == .build || $0.seconds < 1 }
        var plans: [DJTransitionPlan] = []
        for section in DJMoveSupport.breakdowns(outgoing).filter({ $0.start >= floor }).prefix(2) {
            guard let start = DJMoveSupport.snapToDownbeat(outgoing, section.start),
                  let length = DJMoveSupport.barsBetween(outgoing, start, section.end), length >= 4 else { continue }
            let bars = length >= 16 ? 16 : 8
            guard bars <= max(8, length), DJMoveSupport.downbeat(outgoing, from: start, bars: bars) != nil else { continue }
            let exit = ExitPoint(seconds: start, kind: .breakdown, barsRemaining: nil, onPhraseBoundary: DJMoveSupport.isPhraseLine(outgoing, start), confidence: 0.85)
            for entry in (intros.isEmpty ? Array(entries.prefix(1)) : Array(intros.prefix(2))) {
                let relation = DJTempo.local(outgoing, exit: start, overlap: Double(bars) * (outgoing.beatGrid?.barDuration ?? 2), incoming, entry: entry.seconds)
                plans.append(DJMoveSupport.plan(id, .breakdownExit(bars: bars), profile: profile, outgoing: outgoing, incoming: incoming, exit: exit, entry: entry, relation: relation))
            }
        }
        return plans
    }
}

struct DropInTemplate: TransitionTemplate {
    let id = DJMoveIDs.dropIn
    let displayName = "Drop-in"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .threeBandEQ, .highPassFilter, .timeStretch, .entryCue, .sampleAccurateCue, .mixTimeline]

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard DJMoveSupport.measured(outgoing, profile), DJMoveSupport.measured(incoming, profile) else {
            return .rejected(reason: "\(displayName): lining up a drop needs measured downbeats on both tracks")
        }
        guard !DJMoveSupport.drops(incoming).isEmpty else {
            return .rejected(reason: "\(displayName): \(incoming.displayName) has no labelled drop")
        }
        return .admitted
    }

    func propose(outgoing: TrackFeatures, incoming: TrackFeatures, exits: [ExitPoint], entries: [EntryPoint], profile: DJProfile, rng: inout SeededGenerator) -> [DJTransitionPlan] {
        var plans: [DJTransitionPlan] = []
        let outBars = profile.allowMidTrackExit ? 1 : 2
        for drop in DJMoveSupport.drops(incoming).prefix(2) {
            for build in [8, 4] {
                guard let start = DJMoveSupport.downbeat(incoming, from: drop, bars: -build), start >= 0 else { continue }
                let entry = DJMoveSupport.entryPoint(incoming, start, kind: .buildup, confidence: 0.85)
                for (exit, _) in DJMoveSupport.landingExits(outgoing, exits: exits, profile: profile, leadBars: build).prefix(3) {
                    let relation = DJTempo.local(outgoing, exit: exit.seconds, overlap: Double(build) * (outgoing.beatGrid?.barDuration ?? 2), incoming, entry: start)
                    plans.append(DJMoveSupport.plan(id, .dropIn(buildBars: build, outBars: outBars), profile: profile, outgoing: outgoing, incoming: incoming, exit: exit, entry: entry, relation: relation))
                }
            }
        }
        return plans
    }
}

struct DropOnTheOneTemplate: TransitionTemplate {
    let id = DJMoveIDs.dropOnTheOne
    let displayName = "Cut on the drop"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .delayPerDeck, .entryCue, .sampleAccurateCue, .mixTimeline]

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard DJMoveSupport.measured(outgoing, profile), DJMoveSupport.measured(incoming, profile) else {
            return .rejected(reason: "\(displayName): needs measured downbeats on both tracks")
        }
        guard !DJMoveSupport.drops(incoming).isEmpty else {
            return .rejected(reason: "\(displayName): \(incoming.displayName) has no labelled drop")
        }
        return .admitted
    }

    func propose(outgoing: TrackFeatures, incoming: TrackFeatures, exits: [ExitPoint], entries: [EntryPoint], profile: DJProfile, rng: inout SeededGenerator) -> [DJTransitionPlan] {
        let move = MixMove.dropOnTheOne(echo: true)
        return DJMoveSupport.drops(incoming).prefix(2).flatMap { drop in
            DJMoveSupport.landingExits(outgoing, exits: exits, profile: profile, leadBars: move.landingBar).prefix(3).map { exit, _ in
                DJMoveSupport.plan(id, move, profile: profile, outgoing: outgoing, incoming: incoming, exit: exit, entry: DJMoveSupport.entryPoint(incoming, drop, kind: .drop, confidence: 0.85), relation: DJTempo.grid(outgoing, incoming))
            }
        }
    }
}

struct LoopRollBuildTemplate: TransitionTemplate {
    let id = DJMoveIDs.loopRoll
    let displayName = "Loop build"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .highPassFilter, .loopBuffer, .loopResize, .sampleAccurateCue, .entryCue, .delayPerDeck, .mixTimeline]

    static func ladder(for profile: DJProfile) -> [MixMove.Rung]? {
        let full = MixMove.standardLadder
        let gentle = MixMove.gentleLadder
        for ladder in [full, gentle] {
            let rungs = Set(ladder.map(\.bars)).count
            let repeated = MixMove.loopRoll(ladder).repeatedBars
            if (ladder.map(\.bars).max() ?? 0) <= profile.maxLoopBars,
               rungs - 1 <= profile.maxLoopHalvings,
               repeated <= DJMoveSupport.maximumLoopRepeatBars {
                return ladder
            }
        }
        return nil
    }

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard profile.loopsPerHour > 0, Self.ladder(for: profile) != nil else {
            return .rejected(reason: "\(displayName): \(profile.displayName) doesn't loop")
        }
        guard DJMoveSupport.measured(outgoing, profile), DJMoveSupport.measured(incoming, profile) else {
            return .rejected(reason: "\(displayName): loop points need measured downbeats")
        }
        guard outgoing.provenance.contains(.measuredVocals) else {
            return .rejected(reason: "\(displayName): can't check the loop for vocals")
        }
        return .admitted
    }

    func propose(outgoing: TrackFeatures, incoming: TrackFeatures, exits: [ExitPoint], entries: [EntryPoint], profile: DJProfile, rng: inout SeededGenerator) -> [DJTransitionPlan] {
        guard let ladder = Self.ladder(for: profile) else { return [] }
        let move = MixMove.loopRoll(ladder)
        let span = ladder.map(\.bars).max() ?? 8
        var plans: [DJTransitionPlan] = []
        let starts = DJMoveSupport.landingExits(outgoing, exits: exits, profile: profile, leadBars: 0)
        for (exit, _) in starts where exit.onPhraseBoundary && !DJMoveRails.inDropOpening(outgoing, at: exit.seconds) && DJMoveSupport.loopRegionIsClean(outgoing, start: exit.seconds, bars: span) {
            for entry in DJMoveSupport.landingEntries(incoming, entries: entries).prefix(2) {
                plans.append(DJMoveSupport.plan(id, move, profile: profile, outgoing: outgoing, incoming: incoming, exit: exit, entry: entry, relation: DJTempo.grid(outgoing, incoming)))
            }
            if plans.count >= 4 { break }
        }
        return plans
    }
}

struct FXBuildTemplate: TransitionTemplate {
    let id: TransitionTemplateID
    let effect: MixMove.Effect
    let displayName: String
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .highPassFilter, .delayPerDeck, .entryCue, .sampleAccurateCue, .mixTimeline]

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard DJMoveSupport.measured(outgoing, profile), DJMoveSupport.measured(incoming, profile) else {
            return .rejected(reason: "\(displayName): needs measured downbeats on both tracks")
        }
        return .admitted
    }

    func propose(outgoing: TrackFeatures, incoming: TrackFeatures, exits: [ExitPoint], entries: [EntryPoint], profile: DJProfile, rng: inout SeededGenerator) -> [DJTransitionPlan] {
        var plans: [DJTransitionPlan] = []
        for bars in [8, 4] {
            let move = MixMove.fxBuild(effect, bars: bars)
            for (exit, _) in DJMoveSupport.landingExits(outgoing, exits: exits, profile: profile, leadBars: bars).filter({ !DJMoveRails.inDropOpening(outgoing, at: $0.exit.seconds) }).prefix(2) {
                for entry in DJMoveSupport.landingEntries(incoming, entries: entries).prefix(2) {
                    plans.append(DJMoveSupport.plan(id, move, profile: profile, outgoing: outgoing, incoming: incoming, exit: exit, entry: entry, relation: DJTempo.grid(outgoing, incoming)))
                }
            }
        }
        return plans
    }
}

struct TempoRampMoveTemplate: TransitionTemplate {
    let id = DJMoveIDs.tempoRamp
    let displayName = "Tempo ramp"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .threeBandEQ, .timeStretch, .entryCue, .sampleAccurateCue, .mixTimeline]

    static let minimumChange = 0.003

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard profile.allowsTempoRamps else {
            return .rejected(reason: "\(displayName): \(profile.displayName) holds the tempo")
        }
        guard DJMoveSupport.measured(outgoing, profile), DJMoveSupport.measured(incoming, profile),
              let relation = DJTempo.grid(outgoing, incoming), relation.factor == 1 else {
            return .rejected(reason: "\(displayName): needs measured grids at the same tempo family")
        }
        let target = 1 / relation.requiredRate
        guard abs(target - 1) >= Self.minimumChange, abs(target - 1) * 100 <= profile.maxAbsRatePercent else {
            return .rejected(reason: "\(displayName): no tempo to steer between these tracks")
        }
        return .admitted
    }

    func propose(outgoing: TrackFeatures, incoming: TrackFeatures, exits: [ExitPoint], entries: [EntryPoint], profile: DJProfile, rng: inout SeededGenerator) -> [DJTransitionPlan] {
        guard let relation = DJTempo.grid(outgoing, incoming) else { return [] }
        let target = 1 / relation.requiredRate
        let needed = Int((abs(target - 1) * 100 / DJMoveSupport.maximumRampPercentPerBar).rounded(.up))
        let rampBars = [4, 8, 16].first { $0 >= needed } ?? 16
        var plans: [DJTransitionPlan] = []
        for blend in [16, 8] where profile.transitionBarsRange.contains(blend) {
            let move = MixMove.tempoRamp(rampBars: rampBars, to: target, blendBars: blend)
            for (exit, _) in DJMoveSupport.landingExits(outgoing, exits: exits, profile: profile, leadBars: rampBars).prefix(2) {
                guard DJMoveSupport.downbeat(outgoing, from: exit.seconds, bars: rampBars + blend) != nil else { continue }
                for entry in entries.filter(\.hasBassFromHere).prefix(2) {
                    var plan = DJMoveSupport.plan(id, move, profile: profile, outgoing: outgoing, incoming: incoming, exit: exit, entry: entry, relation: relation)
                    plan = DJTransitionPlan(
                        templateId: plan.templateId, profileId: plan.profileId,
                        outgoingTrackId: plan.outgoingTrackId, incomingTrackId: plan.incomingTrackId,
                        exit: plan.exit, entry: plan.entry, overlapSeconds: plan.overlapSeconds,
                        bassSwapAtSeconds: plan.bassSwapAtSeconds, bassSwapSeconds: plan.bassSwapSeconds,
                        incomingRateRatio: relation.requiredRate, tempoFactor: relation.factor,
                        tempoLabel: "ramp to \(DJFormat.signedPercent((target - 1) * 100))",
                        accent: nil, profileMinimumScore: plan.profileMinimumScore, move: move
                    )
                    plans.append(plan)
                }
            }
        }
        return plans
    }
}

struct BridgeMoveTemplate: TransitionTemplate {
    let id = DJMoveIDs.bridge
    let displayName = "Double-time blend"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .threeBandEQ, .timeStretch, .entryCue, .sampleAccurateCue, .mixTimeline]

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard DJMoveSupport.measured(outgoing, profile), DJMoveSupport.measured(incoming, profile),
              let relation = DJTempo.grid(outgoing, incoming) else {
            return .rejected(reason: "\(displayName): needs measured grids on both tracks")
        }
        guard relation.factor == 2 || relation.factor == 0.5 else {
            return .rejected(reason: "\(displayName): not a 2:1 tempo relation")
        }
        guard relation.residual <= HalfTimeBlendTemplate.maxResidual else {
            return .rejected(reason: "\(displayName): the 2:1 fold leaves too much to stretch")
        }
        return .admitted
    }

    func propose(outgoing: TrackFeatures, incoming: TrackFeatures, exits: [ExitPoint], entries: [EntryPoint], profile: DJProfile, rng: inout SeededGenerator) -> [DJTransitionPlan] {
        guard let relation = DJTempo.grid(outgoing, incoming) else { return [] }
        var plans: [DJTransitionPlan] = []
        for bars in [16, 8] where profile.transitionBarsRange.contains(bars) {
            for (exit, _) in DJMoveSupport.landingExits(outgoing, exits: exits, profile: profile, leadBars: 0).prefix(2) {
                guard DJMoveSupport.downbeat(outgoing, from: exit.seconds, bars: bars) != nil else { continue }
                for entry in entries.filter(\.hasBassFromHere).prefix(2) {
                    plans.append(DJMoveSupport.plan(id, .bridge(bars: bars), profile: profile, outgoing: outgoing, incoming: incoming, exit: exit, entry: entry, relation: relation))
                }
            }
        }
        return plans
    }
}

enum DJJumpPlanner {
    static let minimumTrackSeconds: TimeInterval = 6 * 60

    struct Candidate: Equatable, Sendable {
        let plan: DJTransitionPlan
        let score: Double
        let reason: String
    }

    static func propose(track: TrackFeatures, from position: TimeInterval, profile: DJProfile, history: SetHistory = .empty) -> Candidate? {
        guard profile.allowsJumps, track.duration >= minimumTrackSeconds,
              DJMoveSupport.measured(track, profile), let grid = track.beatGrid, grid.phraseDuration > 0 else { return nil }
        let bars = DJMoveSupport.downbeats(track)
        guard bars.count > 96 else { return nil }
        let earliest = position + 2 * grid.phraseDuration
        let latest = track.duration - 64 * grid.barDuration
        guard latest > earliest else { return nil }
        let phrases = grid.phraseStarts(from: earliest, through: latest)
        let blendBars = profile.transitionBarsRange.contains(16) ? 16 : 8
        var best: Candidate?
        for exit in phrases.prefix(24) {
            guard !nearBoundary(track, exit, grid: grid), let exitIndex = DJMoveSupport.downbeatIndex(track, near: exit) else { continue }
            let dull = dullness(track, from: exit, bars: 32)
            for target in grid.phraseStarts(from: exit + Double(DJMoveSupport.minimumJumpBars) * grid.barDuration, through: min(latest, exit + 12 * 60)).prefix(96) {
                guard let targetIndex = DJMoveSupport.downbeatIndex(track, near: target), targetIndex - exitIndex >= DJMoveSupport.minimumJumpBars,
                      targetIndex + blendBars + 8 < bars.count, exitIndex + blendBars < bars.count,
                      !nearBoundary(track, target, grid: grid) else { continue }
                let exitPeriod = grid.localBeatPeriod(at: exit)
                let targetPeriod = grid.localBeatPeriod(at: target)
                let rate = exitPeriod > 0 ? targetPeriod / exitPeriod : 1
                guard abs(rate - 1) * 100 <= profile.maxAbsRatePercent else { continue }
                let vocalsOut = DJMoveSupport.vocalSeconds(track, exit...bars[exitIndex + blendBars])
                let vocalsIn = DJMoveSupport.vocalSeconds(track, target...bars[targetIndex + blendBars])
                if track.provenance.contains(.measuredVocals), vocalsOut > 0.1, vocalsIn > 0.1 { continue }
                let skipped = dullness(track, from: exit, bars: targetIndex - exitIndex)
                let landsOnSection = track.sections.contains { abs($0.start - target) < grid.beatPeriod && ($0.kind == .drop || $0.kind == .buildup || $0.kind == .build) }
                let heat = track.heat.contains { abs($0 - target) < grid.barDuration * 2 } ? 0.15 : 0
                let skipsHeat = track.heat.contains { $0 > exit + grid.barDuration && $0 < target - grid.barDuration } ? 0.2 : 0
                let distance = Double(targetIndex - exitIndex)
                let wait = min(0.15, max(0, exit - position) / 1_200)
                let score = 0.45 + 0.3 * dull + 0.2 * skipped + (landsOnSection ? 0.15 : 0) + heat - skipsHeat - min(0.1, distance / 4_000) - wait
                guard score > (best?.score ?? 0) else { continue }
                let move = MixMove.jump(bars: targetIndex - exitIndex, blendBars: blendBars)
                let exitPoint = ExitPoint(seconds: exit, kind: track.section(at: exit), barsRemaining: bars.count - exitIndex, onPhraseBoundary: true, confidence: 0.8)
                let entry = DJMoveSupport.entryPoint(track, target, confidence: 0.8)
                let overlap = DJMoveSupport.wallSeconds(move, outgoing: track, exit: exit, incomingRate: rate)
                let plan = DJTransitionPlan(
                    templateId: DJMoveIDs.jump, profileId: profile.id,
                    outgoingTrackId: track.trackId, incomingTrackId: track.trackId,
                    exit: exitPoint, entry: entry, overlapSeconds: overlap,
                    bassSwapAtSeconds: DJMoveSupport.wallSeconds(move, outgoing: track, exit: exit, incomingRate: rate, bars: move.bassSwapBar ?? blendBars / 2),
                    bassSwapSeconds: grid.beatPeriod,
                    incomingRateRatio: rate, tempoFactor: 1,
                    tempoLabel: "same track, \(Int(distance)) bars on",
                    accent: nil, profileMinimumScore: profile.minimumScoreToFire, move: move
                )
                let reason = dull > 0.5 ? "skips a flat stretch" : (landsOnSection ? "lands on a build" : "moves the set on")
                best = Candidate(plan: plan, score: score, reason: reason)
            }
        }
        guard let best, best.score >= profile.minimumScoreToFire else { return nil }
        return best
    }

    static func nearBoundary(_ track: TrackFeatures, _ seconds: TimeInterval, grid: BeatGrid) -> Bool {
        let clearance = Double(DJMoveSupport.boundaryClearanceBars) * grid.barDuration
        return track.boundaries.contains { abs($0 - seconds) < clearance }
    }

    static func dullness(_ track: TrackFeatures, from start: TimeInterval, bars: Int) -> Double {
        guard bars > 0, !track.envelope.isEmpty, track.duration > 0, let grid = track.beatGrid else { return 0 }
        let end = min(track.duration, start + Double(bars) * grid.barDuration)
        let lo = max(0, Int(start / track.duration * Double(track.envelope.count)))
        let hi = min(track.envelope.count, max(lo + 2, Int(end / track.duration * Double(track.envelope.count))))
        guard hi > lo + 1 else { return 0 }
        let slice = track.envelope[lo..<hi].map(Double.init)
        let mean = slice.reduce(0, +) / Double(slice.count)
        let variance = slice.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(slice.count)
        let flatness = 1 - min(1, variance.squareRoot() / max(0.05, mean) * 4)
        let overall = DJPointFinder.envelopeMedian(track.envelope)
        let lowness = overall > 0 ? max(0, min(1, 1.2 - mean / overall)) : 0
        return max(0, min(1, 0.6 * flatness + 0.4 * lowness))
    }
}

enum DJMoveRails {
    static let vocalMaskBars = 4.0

    static func vocalPhraseVeto(_ plan: DJTransitionPlan, window: (start: TimeInterval, length: TimeInterval), outgoing: TrackFeatures, incoming: TrackFeatures, beat: TimeInterval, bar: TimeInterval) -> String? {
        guard plan.move?.kind != .loopMix else { return nil }
        let outStart = plan.exit.seconds + window.start
        let eqBlend = plan.move?.kind == .blend && plan.move?.filter == nil
        let swap = plan.exit.seconds + plan.bassSwapAtSeconds
        if outgoing.provenance.contains(.measuredVocals),
           outgoing.vocalRanges.contains(where: { $0.lowerBound < outStart - beat && $0.upperBound > outStart + beat && !(eqBlend && $0.upperBound <= swap) }) {
            return "the outgoing vocal phrase hasn't finished"
        }
        guard incoming.provenance.contains(.measuredVocals) else { return nil }
        let entry = plan.entry.seconds
        let masked = eqBlend ? entry + min(plan.bassSwapAtSeconds, vocalMaskBars * bar) * plan.incomingRateRatio : entry
        if incoming.vocalRanges.contains(where: { $0.lowerBound < entry - beat && $0.upperBound > entry + beat && !(eqBlend && $0.upperBound <= masked) }) {
            return "the incoming would land inside a vocal phrase"
        }
        guard outgoing.provenance.contains(.measuredVocals), window.length > beat,
              let first = incoming.vocalRanges.map(\.lowerBound).filter({ $0 >= entry - beat && $0 < entry + window.length }).min() else { return nil }
        let onset = outStart + (first - entry)
        let lastOut = outgoing.vocalRanges.filter { $0.lowerBound < onset && $0.upperBound > outStart }.map(\.upperBound).max()
        if let lastOut, onset - lastOut < bar {
            return "the incoming vocal would start less than a bar after the outgoing vocal"
        }
        return nil
    }

    static func payoffEnd(_ track: TrackFeatures) -> TimeInterval? {
        var ends: [TimeInterval] = []
        if meatyBars(track) != nil {
            if let peak = energyPayoffEnd(track) { ends.append(peak) }
        } else if track.provenance.contains(.measuredStructure),
           let drop = track.sections.filter({ $0.kind == .drop }).map(\.end).max() {
            ends.append(drop)
        }
        if track.provenance.contains(.measuredVocals),
           let vocal = track.vocalRanges.map(\.upperBound).filter({ $0 < track.duration - 1 }).max() {
            ends.append(vocal)
        }
        return ends.max()
    }

    static func exitPlacementVeto(_ plan: DJTransitionPlan, window: (start: TimeInterval, length: TimeInterval), outgoing: TrackFeatures, profile: DJProfile, beat: TimeInterval) -> String? {
        guard plan.move == nil || plan.move?.kind == .blend else { return nil }
        if let preferred = outgoing.preferredExitSeconds, abs(preferred - plan.exit.seconds) < beat { return nil }
        let outStart = plan.exit.seconds + window.start
        let returning = DJMoveSupport.breakdowns(outgoing).filter { $0.end < outgoing.duration - outroBars * 4 * beat }
        if returning.contains(where: { $0.start - beat <= outStart && outStart < $0.end - beat }) {
            return "the exit would land in a breakdown"
        }
        return nil
    }

    static let outroBars = 8.0
    static let meatyRunBars = 4
    static let dropLookaheadBars = 8.0
    static let meatyBarsAllowed = 1

    static let dipDecibels: Float = 6
    static let breakdownBars = 4
    static let dropBars = 16
    static let bandDecibelsPerUnit: Float = 4.343

    struct BarCharacter: Equatable, Sendable {
        let dip: Bool
        let drop: Bool
        let vocal: Bool
        var peak: Bool { drop }
        var beatLed: Bool { !peak && !vocal }
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count) * p)))]
    }

    static func barCharacters(_ track: TrackFeatures) -> [BarCharacter]? {
        guard let profile = track.barProfile, track.barStarts.count == profile.level.count, profile.level.count >= 16 else { return nil }
        let count = profile.level.count
        let measured = profile.level.filter { $0 > -89 }
        guard measured.count >= 8 else { return nil }
        let body = percentile(measured, 0.75)
        let starts = track.barStarts
        let bar = count > 1 ? (starts[count - 1] - starts[0]) / Double(count - 1) : 2
        var lows: [Float]?
        var lowTypical: Float = 0
        if let bands = profile.bands, bands.count == count * 4 {
            let values = (0..<count).map { bands[$0 * 4] * bandDecibelsPerUnit }
            let loud = (0..<count).filter { profile.level[$0] >= body - 3 }.map { values[$0] }
            lowTypical = percentile(loud.isEmpty ? values : loud, 0.5)
            lows = values
        }
        let dips = (0..<count).map { b in
            profile.level[b] <= body - dipDecibels || (lows.map { $0[b] <= lowTypical - dipDecibels } ?? false)
        }
        var drop = [Bool](repeating: false, count: count)
        var run = 0
        var b = 0
        while b < count {
            if dips[b] {
                run += 1
                b += 1
                continue
            }
            if run >= breakdownBars {
                var loudRun = 0
                while b + loudRun < count, !dips[b + loudRun] { loudRun += 1 }
                if loudRun >= breakdownBars {
                    for k in b..<min(count, b + dropBars, b + loudRun) { drop[k] = true }
                }
            }
            run = 0
            b += 1
        }
        let vocalsKnown = track.provenance.contains(.measuredVocals)
        return (0..<count).map { b in
            let lo = starts[b], hi = b + 1 < count ? starts[b + 1] : starts[b] + bar
            let vocal = vocalsKnown && DJMoveSupport.vocalSeconds(track, lo...hi) >= (hi - lo) * 0.25
            return BarCharacter(dip: dips[b], drop: drop[b], vocal: vocal)
        }
    }

    static func meatyBars(_ track: TrackFeatures) -> [Bool]? {
        let legacy = barCharacters(track)?.map(\.peak)
        guard let arrangement = track.arrangement, !track.barStarts.isEmpty else { return legacy }
        return track.barStarts.enumerated().map { index, start in
            guard let bar = arrangement.bar(at: start) else { return legacy?[index] ?? true }
            return arrangement.isPeak(bars: bar..<(bar + 1)) ?? legacy?[index] ?? true
        }
    }

    static func beatLedBars(_ track: TrackFeatures) -> [Bool]? {
        guard let peaks = meatyBars(track), let characters = barCharacters(track) else { return barCharacters(track)?.map(\.beatLed) }
        return zip(peaks, characters).map { !$0 && !$1.vocal }
    }

    static func dropOpening(_ track: TrackFeatures, bar index: Int) -> Bool {
        if let arrangement = track.arrangement, track.barStarts.indices.contains(index), let role = arrangement.role(at: track.barStarts[index]) {
            return role == .dropOpening
        }
        guard let characters = barCharacters(track), characters.indices.contains(index) else { return false }
        return characters[index].drop
    }

    static let dropOpeningBars = 8
    static let envelopeDipRatio: Float = 0.6

    static func dropOnsets(_ track: TrackFeatures) -> [TimeInterval] {
        var out: [TimeInterval] = []
        let sections = track.sections.sorted { $0.start < $1.start }
        for (index, section) in sections.enumerated() where section.kind == .drop && index > 0 {
            let previous = sections[index - 1].kind
            if previous == .breakdown || previous == .buildup || previous == .build || previous == .cooldown { out.append(section.start) }
        }
        for breakdown in DJMoveSupport.breakdowns(track) where breakdown.end < track.duration - 1 {
            out.append(breakdown.end)
        }
        let starts = track.barStarts
        if let arrangement = track.arrangement {
            for index in starts.indices where arrangement.role(at: starts[index]) == .dropOpening
                && (index == 0 || arrangement.role(at: starts[index - 1]) != .dropOpening) {
                out.append(starts[index])
            }
        }
        if let characters = barCharacters(track) {
            for index in characters.indices where characters[index].drop && (index == 0 || !characters[index - 1].drop) {
                out.append(starts[index])
            }
        }
        out += envelopeDropOnsets(track)
        return out.sorted()
    }

    static func envelopeDropOnsets(_ track: TrackFeatures) -> [TimeInterval] {
        let starts = track.barStarts
        let values = track.envelope
        guard starts.count >= 16, values.count >= 16, track.duration > 0 else { return [] }
        let bucket = track.duration / Double(values.count)
        let levels: [Float] = starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : min(track.duration, starts[index] + (starts[index] - starts[max(0, index - 1)]))
            let lo = max(0, min(values.count - 1, Int(starts[index] / bucket)))
            let hi = min(values.count, max(lo + 1, Int(end / bucket)))
            let slice = values[lo..<hi]
            return slice.reduce(0, +) / Float(slice.count)
        }
        let body = percentile(levels, 0.75)
        guard body > 0 else { return [] }
        let dips = levels.map { $0 < body * envelopeDipRatio }
        var out: [TimeInterval] = []
        var run = 0
        for index in dips.indices {
            if dips[index] {
                run += 1
                continue
            }
            if run >= breakdownBars, index + breakdownBars <= dips.count, !dips[index..<(index + breakdownBars)].contains(true) {
                out.append(starts[index])
            }
            run = 0
        }
        return out
    }

    static func inDropOpening(_ track: TrackFeatures, at seconds: TimeInterval) -> Bool {
        guard let grid = track.beatGrid, grid.barDuration > 0 else { return false }
        let beat = grid.beatPeriod
        let span = Double(dropOpeningBars) * grid.barDuration
        return dropOnsets(track).contains { seconds >= $0 - beat && seconds < $0 + span - beat }
    }

    static func loopsOrBuilds(_ plan: DJTransitionPlan) -> Bool {
        if plan.templateId == DJTemplates.loopRollDown { return true }
        guard let move = plan.move else { return false }
        return move.kind == .loopRoll || move.kind == .fxBuild || move.kind == .loopMix || !move.ladder.isEmpty
    }

    static func dropOpeningVeto(_ plan: DJTransitionPlan, outgoing: TrackFeatures) -> String? {
        guard loopsOrBuilds(plan), inDropOpening(outgoing, at: plan.exit.seconds) else { return nil }
        return "the loop would start on the outgoing's drop"
    }

    static func payoffRuns(_ track: TrackFeatures) -> [Range<Int>] {
        guard let meaty = meatyBars(track) else { return [] }
        var runs: [Range<Int>] = []
        var start: Int?
        var gap = 0
        for index in meaty.indices {
            if meaty[index] {
                if start == nil { start = index }
                gap = 0
            } else if let s = start {
                gap += 1
                if gap > 1 {
                    let end = index - gap + 1
                    if end - s >= meatyRunBars { runs.append(s..<end) }
                    start = nil
                    gap = 0
                }
            }
        }
        if let s = start {
            let end = meaty.count - gap
            if end - s >= meatyRunBars { runs.append(s..<end) }
        }
        return runs
    }

    static func energyPayoffEnd(_ track: TrackFeatures) -> TimeInterval? {
        guard let last = payoffRuns(track).last else { return nil }
        return last.upperBound < track.barStarts.count ? track.barStarts[last.upperBound] : track.duration
    }

    static func payoffVeto(_ plan: DJTransitionPlan, window: (start: TimeInterval, length: TimeInterval), outgoing: TrackFeatures, profile: DJProfile, beat: TimeInterval) -> String? {
        guard plan.move?.kind != .loopMix, let meaty = meatyBars(outgoing), let bar = outgoing.beatGrid?.barDuration, bar > 0 else { return nil }
        if let preferred = outgoing.preferredExitSeconds, abs(preferred - plan.exit.seconds) < beat { return nil }
        let exit = plan.exit.seconds
        let end = exit + window.start + window.length
        let horizon = max(end, exit + dropLookaheadBars * bar)
        let starts = outgoing.barStarts
        let runs = payoffRuns(outgoing)
        for run in runs where starts[run.lowerBound] > exit + beat && starts[run.lowerBound] < horizon {
            return "the outgoing's drop is coming up"
        }
        let covered = starts.indices.filter { starts[$0] >= exit - beat && starts[$0] < end - beat && meaty[$0] }.count
        if covered > meatyBarsAllowed {
            return "the mix would run over the outgoing's peak"
        }
        return nil
    }

    static func contentVeto(_ plan: DJTransitionPlan, outgoing: TrackFeatures, incoming: TrackFeatures, beat: TimeInterval) -> String? {
        if let preferred = outgoing.preferredExitSeconds, abs(preferred - plan.exit.seconds) < beat { return nil }
        let start = plan.exit.seconds
        if !DJContentBounds.hasEnergy(outgoing, at: start) {
            return "the outgoing has gone quiet there"
        }
        if plan.templateId != DJTemplates.cutOnTheOne, let bar = outgoing.beatGrid?.barDuration,
           DJContentBounds.dropsOut(outgoing, from: start, to: start + DJContentBounds.gapCheckBars * bar) {
            return "the outgoing drops out just after the mix would start"
        }
        if plan.move == nil || plan.move?.kind == .blend, plan.templateId != DJTemplates.cutOnTheOne, let bar = incoming.beatGrid?.barDuration, bar > 0,
           plan.overlapSeconds >= DJContentBounds.handoverCheckMinimumBars * bar {
            let arrival = plan.entry.seconds + plan.overlapSeconds * plan.incomingRateRatio
            if DJContentBounds.dips(incoming, from: arrival - bar, to: arrival + DJContentBounds.handoverCheckBars * bar) {
                return "the incoming drops out as the outgoing leaves"
            }
        }
        if let move = plan.move, move.kind == .loopMix, move.inLoopBars > 0, let bar = incoming.beatGrid?.barDuration, bar > 0,
           let release = DJMoveSupport.downbeat(incoming, from: plan.entry.seconds, bars: move.inLoopBars) {
            let gone = DJMoveSupport.downbeat(incoming, from: release, bars: move.blendBars) ?? release + Double(move.blendBars) * bar
            if DJContentBounds.dips(incoming, from: release - bar, to: gone + DJContentBounds.handoverCheckBars * bar) {
                return "the incoming drops out as the loop releases"
            }
        }
        if let latest = outgoing.latestMixStart, start > latest + beat,
           (payoffEnd(outgoing) ?? 0) <= latest {
            return "the outro is long, so the mix starts while it still has a beat"
        }
        if plan.entry.seconds < incoming.contentStart - beat, incoming.preferredEntrySeconds.map({ abs($0 - plan.entry.seconds) >= beat }) ?? true {
            return "the incoming would start in silence"
        }
        return nil
    }

    static let vetoFallDecibels: Float = 6.5
    static let vetoJumpDecibels: Float = 10

    static func lookAheadVeto(_ plan: DJTransitionPlan, outgoing: TrackFeatures, incoming: TrackFeatures) -> String? {
        guard plan.templateId != DJTemplates.cutOnTheOne, plan.move?.kind != .echoOut,
              let reading = DJLookAhead.read(plan, outgoing: outgoing, incoming: incoming) else { return nil }
        if reading.fall > vetoFallDecibels { return "the room would drop \(Int(reading.fall.rounded())) dB as the decks change over" }
        if reading.jump > vetoJumpDecibels { return "the incoming would jump \(Int(reading.jump.rounded())) dB during the handover" }
        return nil
    }

    static func veto(_ plan: DJTransitionPlan, outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile, history: SetHistory) -> String? {
        let window = DJMoveSupport.overlapWindow(plan, outgoing: outgoing)
        let bar = outgoing.beatGrid?.barDuration ?? 2
        let beat = outgoing.beatGrid?.beatPeriod ?? 0.5
        if let reason = contentVeto(plan, outgoing: outgoing, incoming: incoming, beat: beat) {
            return reason
        }
        if let reason = payoffVeto(plan, window: window, outgoing: outgoing, profile: profile, beat: beat) {
            return reason
        }
        if let reason = dropOpeningVeto(plan, outgoing: outgoing) {
            return reason
        }
        if let reason = lookAheadVeto(plan, outgoing: outgoing, incoming: incoming) {
            return reason
        }
        let overlapBars = window.length / max(0.1, bar)
        let shape = DJPlanShape(plan)
        if let reason = DJPlanValidator.keyReason(DJSourceMap(shape, outgoing: outgoing, incoming: incoming), shape: shape, outgoing: outgoing, incoming: incoming, profile: profile) {
            return reason
        }
        if let reason = vocalPhraseVeto(plan, window: window, outgoing: outgoing, incoming: incoming, beat: beat, bar: bar) {
            return reason
        }
        if let reason = exitPlacementVeto(plan, window: window, outgoing: outgoing, profile: profile, beat: beat) {
            return reason
        }
        if window.length > beat, !shape.isLoopMix, shape.move?.kind != .blend {
            let outStart = plan.exit.seconds + window.start
            let bothMeasured = DJMoveSupport.vocalsMeasured(outgoing, incoming)
            if !bothMeasured, outgoing.provenance.contains(.measuredVocals),
               DJMoveSupport.vocalSeconds(outgoing, outStart...(outStart + window.length)) > beat {
                return "the outgoing vocal hasn't ended"
            }
            if !bothMeasured, incoming.provenance.contains(.measuredVocals),
               DJMoveSupport.vocalSeconds(incoming, plan.entry.seconds...(plan.entry.seconds + window.length)) > beat {
                return "the incoming track has vocals in the blend"
            }
            if bothMeasured {
                let overlap = DJMixRules.vocalOverlapSeconds(
                    outgoing: outgoing.vocalRanges, from: outStart, length: window.length,
                    incoming: incoming.vocalRanges, entry: plan.entry.seconds
                )
                if overlap > beat { return "the vocals would overlap" }
            } else if overlapBars > DJMixRules.unmeasuredVocalOverlapBars {
                return "vocals aren't measured, so the overlap is capped at 8 bars"
            }
        }
        if let move = plan.move, !move.ladder.isEmpty {
            if move.repeatedBars > DJMoveSupport.maximumLoopRepeatBars { return "loops are capped at 16 bars" }
            if history.loopsThisHour >= profile.loopsPerHour { return "\(profile.displayName) has used its loops for this hour" }
        }
        if let move = plan.move, move.outgoingRateTarget != nil, move.landingBar > 0 {
            let change = abs((move.outgoingRateTarget ?? 1) - 1) * 100
            if change / Double(move.landingBar) > DJMoveSupport.maximumRampPercentPerBar + 1e-6 { return "the tempo would move faster than 0.5% a bar" }
            if change > profile.maxAbsRatePercent { return "the tempo would leave \(profile.displayName)'s range" }
        }
        return nil
    }

    static func adjustment(_ plan: DJTransitionPlan, outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile, history: SetHistory) -> (delta: Double, notes: [String]) {
        var delta = 0.0
        var notes: [String] = []
        if let move = plan.move {
            delta -= move.baseRisk * (1 - profile.adventure) * 0.35
            if move.kind != .blend { delta += 0.05 * profile.adventure }
            if move.kind != .blend, let index = history.recentTemplates.prefix(3).firstIndex(of: plan.templateId) {
                delta -= 0.12 * Double(3 - index) / 3
                notes.append("used this move recently")
            } else if history.recentMoves.prefix(2).contains(move.kind), move.kind != .blend {
                delta -= 0.05
            }
            let landing = move.incomingLeadBars > 0
                ? DJMoveSupport.downbeat(incoming, from: plan.entry.seconds, bars: move.incomingLeadBars) ?? plan.entry.seconds
                : plan.entry.seconds
            if let grid = incoming.beatGrid,
               incoming.cueHints.contains(where: { $0.role == .entry && $0.confidence >= 0.85 && abs($0.seconds - landing) < grid.beatPeriod }) {
                delta += 0.1
                notes.append("lands on your cue")
            }
            if plan.exit.confidence >= 0.9 {
                delta += 0.04
            }
        }
        if let grid = incoming.beatGrid, incoming.heat.contains(where: { abs($0 - plan.entry.seconds) < grid.barDuration * 2 }) {
            delta += 0.04
            notes.append("enters on a part people replay")
        }
        if let grid = outgoing.beatGrid {
            let end = plan.exit.seconds + plan.overlapSeconds
            if outgoing.heat.contains(where: { $0 > end + grid.barDuration }) {
                delta -= 0.04
                notes.append("leaves before a part people replay")
            }
        }
        if let target = history.energyTarget {
            let current = EnergyTerm.level(from: outgoing)?.level ?? target
            if let next = EnergyTerm.level(from: incoming)?.level {
                delta -= min(0.12, Double(abs(next - target)) * 0.02)
            }
            let want = target - current
            if let move = plan.move, move.energyDirection != 0, want != 0 {
                delta += (move.energyDirection > 0) == (want > 0) ? 0.04 : -0.04
            }
        }
        return (delta, notes)
    }
}

extension DJProfile {
    var adventure: Double {
        switch id {
        case .wedding: return 0
        case .junkie: return 1
        default: return 0.5
        }
    }

    var loopsPerHour: Int {
        switch id {
        case .wedding: return 0
        case .junkie: return 2
        default: return 1
        }
    }

    var moveMargin: Double {
        switch id {
        case .wedding: return 0.08
        case .junkie: return 0
        default: return 0.05
        }
    }

    var moveExitFloor: Double { allowMidTrackExit ? exitRegionFloor : max(exitRegionFloor, 0.7) }

    var adventureSummary: String {
        switch id {
        case .wedding: return "Smooth plays it safe: long blends, echo outs and clean cuts."
        case .junkie: return "Adventurous goes wild: loop builds, jumps through sets, tempo ramps and cuts on the drop."
        default: return "Club blends out of the outro, with the odd drop-in or breakdown exit."
        }
    }

    var allowsTempoRamps: Bool { id == .junkie }
    var allowsJumps: Bool { id == .junkie }
}

extension DJJumpPlanner.Candidate {
    func executablePlan(_ track: TrackFeatures) -> PhantomDJEngine.Plan {
        let distance = plan.entry.seconds - plan.exit.seconds
        let headline = (plan.move?.headline(into: track.displayName, durationSeconds: distance) ?? "Jump")
            + " at \(DJFormat.time(plan.exit.seconds))"
        let rationale = PlanRationale(
            templateName: "Jump",
            headline: headline,
            contributions: [PlanRationale.Contribution(termId: .structure, explanation: reason, weightedCost: 0)],
            concerns: [],
            provenanceCaveats: [],
            score: score,
            evidenceCoverage: 1,
            fires: true
        )
        return PhantomDJEngine.Plan(
            mixPointSeconds: plan.exit.seconds,
            transitionSeconds: plan.overlapSeconds,
            outroShape: .unknown,
            accent: nil,
            reasoning: "\(headline): \(reason).",
            entrySeconds: plan.entry.seconds,
            bassSwapAtSeconds: plan.bassSwapAtSeconds,
            bassSwapSeconds: plan.bassSwapSeconds,
            incomingRateRatio: plan.incomingRateRatio,
            incomingTrackId: track.trackId,
            profileId: plan.profileId,
            templateId: DJMoveIDs.jump,
            rationale: rationale,
            outgoingBeatGrid: track.beatGrid,
            incomingBeatGrid: track.beatGrid,
            move: plan.move,
            incomingTitle: track.displayName
        )
    }
}

extension PhantomDJEngine.Plan {
    func entering(at entry: TimeInterval) -> PhantomDJEngine.Plan {
        PhantomDJEngine.Plan(
            mixPointSeconds: mixPointSeconds,
            transitionSeconds: transitionSeconds,
            outroShape: outroShape,
            accent: accent,
            reasoning: reasoning,
            entrySeconds: entry,
            bassSwapAtSeconds: bassSwapAtSeconds,
            bassSwapSeconds: bassSwapSeconds,
            incomingRateRatio: incomingRateRatio,
            incomingTrackId: incomingTrackId,
            profileId: profileId,
            templateId: templateId,
            rationale: rationale,
            stages: stages,
            outgoingBeatGrid: outgoingBeatGrid,
            incomingBeatGrid: incomingBeatGrid,
            move: move,
            incomingTitle: incomingTitle
        ).carryingExtras(from: self)
    }

    func shifted(mixPoint: TimeInterval) -> PhantomDJEngine.Plan {
        PhantomDJEngine.Plan(
            mixPointSeconds: mixPoint,
            transitionSeconds: transitionSeconds,
            outroShape: outroShape,
            accent: accent,
            reasoning: reasoning,
            entrySeconds: entrySeconds,
            bassSwapAtSeconds: bassSwapAtSeconds,
            bassSwapSeconds: bassSwapSeconds,
            incomingRateRatio: incomingRateRatio,
            incomingTrackId: incomingTrackId,
            profileId: profileId,
            templateId: templateId,
            rationale: rationale,
            stages: stages,
            outgoingBeatGrid: outgoingBeatGrid,
            incomingBeatGrid: incomingBeatGrid,
            move: move,
            incomingTitle: incomingTitle
        ).carryingExtras(from: self)
    }

    func cleanCut(at mixPoint: TimeInterval, reason: String) -> PhantomDJEngine.Plan {
        var cut = PhantomDJEngine.Plan(
            mixPointSeconds: mixPoint,
            transitionSeconds: CutOnTheOneTemplate.fadeSeconds,
            outroShape: .hardStop,
            accent: nil,
            reasoning: reason,
            entrySeconds: entrySeconds,
            bassSwapAtSeconds: 0,
            bassSwapSeconds: CutOnTheOneTemplate.fadeSeconds,
            incomingRateRatio: 1,
            incomingTrackId: incomingTrackId,
            profileId: profileId,
            templateId: DJTemplates.cutOnTheOne,
            outgoingBeatGrid: outgoingBeatGrid,
            incomingBeatGrid: incomingBeatGrid,
            incomingTitle: incomingTitle
        ).carryingExtras(from: self)
        cut.incomingMidCutDecibels = 0
        return cut
    }

    func validated(outgoing: TrackFeatures?, profile: DJProfile?) -> PhantomDJEngine.Plan {
        guard move?.kind != .jump, let outgoing = outgoing ?? outgoingFeatures,
              let reason = DJPlanValidator.reason(self, outgoing: outgoing, incoming: DJPlanFeatureCache.shared.features(for: incomingTrackId), profile: profile) else { return self }
        return cleanCut(at: mixPointSeconds, reason: "No mix — \(reason). Cutting on the bar.")
    }

    func replacingMove(_ move: MixMove) -> PhantomDJEngine.Plan {
        PhantomDJEngine.Plan(
            mixPointSeconds: mixPointSeconds,
            transitionSeconds: transitionSeconds,
            outroShape: outroShape,
            accent: accent,
            reasoning: reasoning,
            entrySeconds: entrySeconds,
            bassSwapAtSeconds: bassSwapAtSeconds,
            bassSwapSeconds: bassSwapSeconds,
            incomingRateRatio: incomingRateRatio,
            incomingTrackId: incomingTrackId,
            profileId: profileId,
            templateId: templateId,
            rationale: rationale,
            stages: stages,
            outgoingBeatGrid: outgoingBeatGrid,
            incomingBeatGrid: incomingBeatGrid,
            move: move,
            incomingTitle: incomingTitle
        ).carryingExtras(from: self)
    }
}

struct LoopMixTemplate: TransitionTemplate {
    let id = DJMoveIDs.loopMix
    let displayName = "Loop mix"
    let requiredCapabilities: ExecutorCapabilities = [.crossfade, .threeBandEQ, .timeStretch, .entryCue, .sampleAccurateCue, .mixTimeline]

    func admits(outgoing: TrackFeatures, incoming: TrackFeatures, profile: DJProfile) -> TemplateAdmission {
        guard DJMoveSupport.measured(outgoing, profile), DJMoveSupport.measured(incoming, profile) else {
            return .rejected(reason: "\(displayName): looping needs measured downbeats on both tracks")
        }
        guard LoopMixPlanner.usable(outgoing), LoopMixPlanner.usable(incoming) else {
            return .rejected(reason: "\(displayName): needs measured bars and vocals on both tracks")
        }
        return .admitted
    }

    func propose(outgoing: TrackFeatures, incoming: TrackFeatures, exits: [ExitPoint], entries: [EntryPoint], profile: DJProfile, rng: inout SeededGenerator) -> [DJTransitionPlan] {
        LoopMixPlanner.choices(outgoing: outgoing, incoming: incoming).map { choice in
            let move = MixMove.loopMix(outLoop: choice.outgoing.bars, inLoop: choice.incoming.bars, fadeIn: choice.fadeInBars, fadeOut: choice.fadeOutBars)
            let relation = DJTempo.local(outgoing, exit: choice.outgoing.seconds, overlap: choice.outgoing.endSeconds - choice.outgoing.seconds, incoming, entry: choice.incoming.seconds)
                ?? DJTempo.grid(outgoing, incoming)
            return DJMoveSupport.plan(
                id, move, profile: profile, outgoing: outgoing, incoming: incoming,
                exit: DJMoveSupport.exitPoint(outgoing, choice.outgoing.seconds, confidence: 0.8),
                entry: DJMoveSupport.entryPoint(incoming, choice.incoming.seconds, confidence: 0.8),
                relation: relation
            )
        }
    }
}

enum LoopMixPlanner {
    static let fadeInBars = 16
    static let fadeOutBars = 4
    static let holdBars = [16, 8]
    static let maxLevelStepDecibels = Float(DJMixRules.maxLevelStepDecibels)
    static let vocalMarginSeconds = 0.25
    static let payoffDensity: Float = 0.8
    static let maximumChoices = 4

    struct Window: Equatable, Sendable {
        let bar: Int
        let bars: Int
        let seconds: TimeInterval
        let endSeconds: TimeInterval
        let density: Float
        let level: Float
        let loopability: Float
        var hasVocal: Bool = false
    }

    struct Choice: Equatable, Sendable {
        let outgoing: Window
        let incoming: Window
        let fadeInBars: Int
        let fadeOutBars: Int
        let levelStep: Float
    }

    static func usable(_ track: TrackFeatures, requireDownbeats: Bool = true) -> Bool {
        guard let profile = track.barProfile, track.barStarts.count == profile.density.count,
              track.provenance.contains(.measuredVocals), !requireDownbeats || !track.provenance.isDisjoint(with: [.measuredDownbeats, .measuredBeatParity]) else { return false }
        return profile.density.count >= 16
    }

    static func vocalFree(_ track: TrackFeatures, _ from: TimeInterval, _ to: TimeInterval) -> Bool {
        DJMoveSupport.vocalSeconds(track, (from - vocalMarginSeconds)...(to + vocalMarginSeconds)) < 0.01
    }

    static func lyricIntact(_ track: TrackFeatures, _ from: TimeInterval, _ to: TimeInterval) -> Bool {
        let vocals = DJRangeIndex(track.vocalRanges)
        return !vocals.touches(from, margin: vocalMarginSeconds) && !vocals.touches(to, margin: vocalMarginSeconds)
    }

    static let loopableRank: Float = 0.25
    static let loopableFloor: Float = 0.75
    static let maxLoopLevelSpreadDecibels: Float = 3
    static let maxSeamLevelDecibels: Float = 1.5

    static func loopRanks(_ values: [Float], density: [Float]? = nil) -> [Float] {
        let valid = values.indices
            .filter { index in values[index] > 0 && (density.map { index < $0.count && $0[index] <= BarProfile.sparseDensity } ?? true) }
            .map { values[$0] }.sorted()
        guard valid.count > 1 else { return values.map { $0 > 0 ? 1 : 0 } }
        return values.map { value in
            guard value > 0 else { return 0 }
            let below = valid.firstIndex { $0 >= value } ?? valid.count
            let atOrBelow = valid.lastIndex { $0 <= value }.map { $0 + 1 } ?? 0
            return Float(below + atOrBelow) / Float(2 * valid.count)
        }
    }

    static func window(_ track: TrackFeatures, bar: Int, bars: Int, ranks: [Float]? = nil) -> Window? {
        guard let profile = track.barProfile else { return nil }
        let starts = track.barStarts
        guard bar >= 0, bar + bars < starts.count else { return nil }
        let slice = bar..<(bar + bars)
        let density = slice.map { profile.density[$0] }
        let mean = density.reduce(0, +) / Float(bars)
        let start = starts[bar]
        let end = starts[bar + bars]
        let vocal = DJMoveSupport.vocalSeconds(track, start...end) > 0.01
        if track.provenance.contains(.measuredStems), !track.loopRanges.isEmpty {
            guard track.loopRanges.contains(where: { $0.lowerBound <= start + 0.05 && $0.upperBound >= end - 0.05 }) else { return nil }
        } else if let peaks = DJMoveRails.meatyBars(track), peaks.count == starts.count {
            guard slice.allSatisfy({ !peaks[$0] }) else { return nil }
        } else {
            guard mean <= BarProfile.sparseDensity, (density.max() ?? 1) <= BarProfile.sparseDensity + 0.15 else { return nil }
        }
        let raw = bars == 8 ? profile.loop8 : profile.loop4
        let loop = raw[bar]
        let rank = (ranks ?? loopRanks(raw, density: nil))[bar]
        guard loop >= loopableFloor, rank >= loopableRank else { return nil }
        guard start >= track.contentStart - 0.01, end <= track.duration + 0.01,
              DJContentBounds.hasEnergy(track, at: start), DJContentBounds.hasEnergy(track, at: max(start, end - 1)) else { return nil }
        guard lyricIntact(track, start, end) else { return nil }
        let levels = slice.map { profile.level[$0] }
        guard (levels.max() ?? 0) - (levels.min() ?? 0) <= maxLoopLevelSpreadDecibels else { return nil }
        if vocal, abs(levels[0] - levels[levels.count - 1]) > maxSeamLevelDecibels { return nil }
        return Window(bar: bar, bars: bars, seconds: start, endSeconds: end, density: mean, level: levels.reduce(0, +) / Float(bars), loopability: rank, hasVocal: vocal)
    }

    static func bodyStep(_ outgoing: TrackFeatures, before bar: Int, _ incoming: TrackFeatures, after inBar: Int) -> Float? {
        guard let o = outgoing.barProfile, let i = incoming.barProfile, bar >= 8, inBar + 8 <= i.level.count else { return nil }
        func power(_ levels: ArraySlice<Float>) -> Float { 10 * log10(max(1e-10, levels.map { pow(10, $0 / 10) }.reduce(0, +) / Float(levels.count))) }
        return DJMixRules.residualLevelStep(outgoing: outgoing, outgoingLevel: power(o.level[(bar - 8)..<bar]), incoming: incoming, incomingLevel: power(i.level[inBar..<(inBar + 8)]))
    }

    static func payoffEnd(_ track: TrackFeatures) -> TimeInterval {
        guard let profile = track.barProfile else { return 0 }
        if DJMoveRails.meatyBars(track) != nil {
            let lastVocal = track.vocalRanges.map(\.upperBound).filter { $0 < track.duration - 1 }.max() ?? 0
            return max(DJMoveRails.energyPayoffEnd(track) ?? 0, lastVocal)
        }
        let starts = track.barStarts
        var end = 0.0
        var run = 0
        for (index, value) in profile.density.enumerated() {
            run = value >= payoffDensity ? run + 1 : 0
            if run >= 4, index + 1 < starts.count { end = starts[index + 1] }
        }
        let lastVocal = track.vocalRanges.map(\.upperBound).filter { $0 < track.duration - 1 }.max() ?? 0
        return max(end, lastVocal)
    }

    static func outgoingWindows(_ track: TrackFeatures) -> [Window] {
        let count = track.barStarts.count
        let floor = track.duration * 0.5
        let peak = DJMoveRails.energyPayoffEnd(track) ?? 0
        var out: [Window] = []
        guard let profile = track.barProfile else { return [] }
        for bars in [8, 4] {
            let ranks = loopRanks(bars == 8 ? profile.loop8 : profile.loop4, density: nil)
            for bar in stride(from: 0, to: count - bars, by: 4) where track.barStarts[bar] >= floor && track.barStarts[bar] >= peak - 0.01 && track.barStarts[bar] >= track.earliestExitSeconds - 0.01 {
                guard let w = window(track, bar: bar, bars: bars, ranks: ranks) else { continue }
                if DJMoveRails.inDropOpening(track, at: w.seconds) { continue }
                if !w.hasVocal, w.seconds < payoffEnd(track) - 0.01 { continue }
                out.append(w)
            }
        }
        return out
    }

    static func incomingWindows(_ track: TrackFeatures, releaseBars: Int) -> [Window] {
        guard let profile = track.barProfile else { return [] }
        let count = track.barStarts.count
        let firstDense = DJMoveRails.payoffRuns(track).first?.lowerBound ?? count
        let ceiling = min(count, max(8, min(firstDense, 64)))
        var out: [Window] = []
        for bars in [8, 4] {
            let ranks = loopRanks(bars == 8 ? profile.loop8 : profile.loop4, density: nil)
            for bar in stride(from: 0, to: ceiling, by: 4) {
                guard let w = window(track, bar: bar, bars: bars, ranks: ranks), bar + bars + releaseBars < count else { continue }
                out.append(w)
            }
        }
        return out
    }

    static func releaseDips(_ incoming: TrackFeatures, _ i: Window) -> Bool {
        guard let bar = incoming.beatGrid?.barDuration, bar > 0 else { return false }
        let gone = DJMoveSupport.downbeat(incoming, from: i.endSeconds, bars: fadeOutBars) ?? i.endSeconds + Double(fadeOutBars) * bar
        return DJContentBounds.dips(incoming, from: i.endSeconds - bar, to: gone + DJContentBounds.handoverCheckBars * bar)
    }

    static func diagnose(outgoing: TrackFeatures, incoming: TrackFeatures) -> String {
        "usable \(usable(outgoing))/\(usable(incoming)) vocals \(outgoing.provenance.contains(.measuredVocals))/\(incoming.provenance.contains(.measuredVocals)) downbeats \(outgoing.provenance.contains(.measuredDownbeats))/\(incoming.provenance.contains(.measuredDownbeats)) bars \(outgoing.barStarts.count)/\(incoming.barStarts.count) payoff \(Int(payoffEnd(outgoing))) s of \(Int(outgoing.duration)) windows \(outgoingWindows(outgoing).count)/\(incomingWindows(incoming, releaseBars: fadeOutBars).count)"
    }

    static func holds(_ o: Window, _ i: Window) -> [Int] {
        holdBars.filter { hold in
            guard hold % o.bars == 0, hold % i.bars == 0 else { return false }
            let outRepeats = hold + fadeOutBars - o.bars
            let inRepeats = hold - i.bars
            guard outRepeats <= DJMixRules.maximumLoopRepeatBars, inRepeats <= DJMixRules.maximumLoopRepeatBars else { return false }
            if o.hasVocal, outRepeats > DJPlanValidator.maximumLyricRepeatBars { return false }
            if i.hasVocal, inRepeats > DJPlanValidator.maximumLyricRepeatBars { return false }
            return true
        }
    }

    static func oneVocalOwner(_ outgoing: TrackFeatures, _ o: Window, _ incoming: TrackFeatures, _ i: Window, hold: Int) -> Bool {
        guard o.hasVocal || i.hasVocal else { return true }
        if o.hasVocal, i.hasVocal { return false }
        if o.hasVocal {
            guard hold + fadeOutBars <= incoming.barStarts.count - i.bar else { return false }
            let releaseEnd = DJMoveSupport.downbeat(incoming, from: i.endSeconds, bars: fadeOutBars) ?? i.endSeconds
            return vocalFree(incoming, i.seconds, releaseEnd)
        }
        return true
    }

    static func choices(outgoing: TrackFeatures, incoming: TrackFeatures, requireDownbeats: Bool = true, rejections: ((String) -> Void)? = nil) -> [Choice] {
        guard usable(outgoing, requireDownbeats: requireDownbeats), usable(incoming, requireDownbeats: requireDownbeats) else { return [] }
        let outs = outgoingWindows(outgoing)
        let ins = incomingWindows(incoming, releaseBars: fadeOutBars)
        var ranked: [(Double, Choice)] = []
        for o in outs {
            for i in ins {
                let step = DJMixRules.residualLevelStep(outgoing: outgoing, outgoingLevel: o.level, incoming: incoming, incomingLevel: i.level)
                guard step <= maxLevelStepDecibels else { rejections?("step"); continue }
                if DJMoveSupport.keySteps(outgoing, at: o.seconds, incoming, at: i.seconds).map({ $0 > 1 }) == true,
                   DJMixRules.percussiveOnly(outgoing, sourceRanges: [o.seconds...o.endSeconds]) != true,
                   DJMixRules.percussiveOnly(incoming, sourceRanges: [i.seconds...i.endSeconds]) != true {
                    rejections?("key")
                    continue
                }
                for hold in holds(o, i) {
                    guard oneVocalOwner(outgoing, o, incoming, i, hold: hold) else { rejections?("vocal"); continue }
                    guard !releaseDips(incoming, i) else { rejections?("release"); continue }
                    guard let body = bodyStep(outgoing, before: o.bar, incoming, after: i.bar + i.bars + fadeOutBars), body <= maxLevelStepDecibels else { rejections?("body"); continue }
                    let lateness = (o.seconds - outgoing.duration * 0.5) / max(1, outgoing.duration)
                    let skip = Double(i.bar) / 32
                    let cost = Double(step) / 6 + Double(o.density + i.density) + Double(2 - o.loopability - i.loopability) * 2
                        + (o.bars == 8 ? 0 : 0.3) + (i.bars == 8 ? 0 : 0.3) + skip - lateness * 0.5
                        + (o.hasVocal || i.hasVocal ? 0.2 : 0) + (hold == fadeInBars ? 0 : 0.15)
                    ranked.append((cost, Choice(outgoing: o, incoming: i, fadeInBars: hold, fadeOutBars: fadeOutBars, levelStep: step)))
                }
            }
        }
        ranked.sort { $0.0 < $1.0 }
        var out: [Choice] = []
        for (_, choice) in ranked where out.count < maximumChoices {
            if out.contains(where: { $0.outgoing.bar == choice.outgoing.bar && $0.incoming.bar == choice.incoming.bar && $0.fadeInBars == choice.fadeInBars }) { continue }
            out.append(choice)
        }
        return out
    }

    static func choose(outgoing: TrackFeatures, incoming: TrackFeatures, requireDownbeats: Bool = true, rejections: ((String) -> Void)? = nil) -> Choice? {
        choices(outgoing: outgoing, incoming: incoming, requireDownbeats: requireDownbeats, rejections: rejections).first
    }
}

enum DJPhraseCut {
    static let tailBars = 16.0
    static let endMarginBars = 2.0

    static func exit(_ outgoing: TrackFeatures, near: TimeInterval? = nil) -> TimeInterval? {
        exits(outgoing, near: near).first
    }

    static func exits(_ outgoing: TrackFeatures, near: TimeInterval? = nil) -> [TimeInterval] {
        guard let grid = outgoing.beatGrid, grid.barDuration > 0 else { return [] }
        let bar = grid.barDuration
        let latest = outgoing.duration - endMarginBars * bar
        if let cue = outgoing.preferredExitSeconds, cue >= max(1, outgoing.earliestExitSeconds - 0.05), cue <= latest {
            return [DJMoveSupport.downbeat(outgoing, from: cue, bars: 0) ?? cue]
        }
        let settled = max(outgoing.earliestExitSeconds, outgoing.duration * 0.45)
        let payoff = max(settled, DJMoveRails.energyPayoffEnd(outgoing) ?? 0)
        let floor = latest - Double(MixMove.echoOut.leadBars + MixMove.echoOut.tailBars) * bar > payoff ? payoff : settled
        guard latest > floor else { return [] }
        var phrases = outgoing.phraseBoundaries.filter { $0 >= floor - 0.05 && $0 <= latest }
        if phrases.isEmpty { phrases = grid.phraseStarts(from: floor, through: latest) }
        let audible = phrases.filter { DJContentBounds.hasEnergy(outgoing, at: $0) }
        let target = near ?? min(latest, outgoing.latestMixStart ?? (outgoing.duration - tailBars * bar))
        return (audible.isEmpty ? phrases : audible).sorted { abs($0 - target) < abs($1 - target) }
    }

    static let searchExits = 3
    static let searchEntries = 3
    static let searchRankCost: Float = 0.75
    static let quietThrowDecibels: Float = 6
    static let quietThrowCost: Float = 3

    static func quietThrow(_ outgoing: TrackFeatures, line: TimeInterval) -> Bool {
        guard let levels = DJLookAhead.Levels(outgoing), let bar = outgoing.beatGrid?.barDuration, bar > 0 else { return false }
        let steps = Int((bar / DJLookAhead.step).rounded())
        var total: Float = 0
        for k in 0..<steps { total += DJLookAhead.power(levels.relative(line - bar + Double(k) * DJLookAhead.step)) }
        return DJLookAhead.decibels(total / Float(max(1, steps))) < -quietThrowDecibels
    }

    static func plan(outgoing: TrackFeatures, incoming: TrackFeatures?, incomingTrackId: String?, profile: DJProfile, reason: String, near: TimeInterval? = nil) -> PhantomDJEngine.Plan? {
        let lines = exits(outgoing, near: near)
        guard let first = lines.first else { return nil }
        var best: (plan: PhantomDJEngine.Plan, cost: Float)?
        for (exitRank, line) in lines.prefix(searchExits).enumerated() {
            let sung = outgoing.beatGrid.map { DJMoveSupport.vocalSeconds(outgoing, line...(line + MixMoveBuilder.echoOutCrossfadeBars * $0.barDuration)) > 0.5 } ?? false
            let entries = incoming.map { onTheOneLines($0, from: DJIntro.cutEntry($0, from: $0.contentStart), clearOfVocalsForBars: sung ? Double(MixMove.echoOut.tailBars) : 0) } ?? [0]
            for (entryRank, entry) in entries.prefix(searchEntries).enumerated() {
                let plan = single(outgoing: outgoing, incoming: incoming, incomingTrackId: incomingTrackId, profile: profile, reason: reason, line: line, entry: entry)
                guard let incoming else { return plan }
                if line != first, plan.templateId != DJMoveIDs.echoOut { continue }
                let excess = DJLookAhead.read(DJPlanShape(plan), outgoing: outgoing, incoming: incoming)?.risk ?? 0
                let quiet = quietThrow(outgoing, line: line) ? quietThrowCost : 0
                let cost = excess + quiet + Float(exitRank + entryRank) * searchRankCost
                if best.map({ cost < $0.cost }) ?? true { best = (plan, cost) }
            }
        }
        return best?.plan
    }

    static func single(outgoing: TrackFeatures, incoming: TrackFeatures?, incomingTrackId: String?, profile: DJProfile, reason: String, line: TimeInterval, entry: TimeInterval) -> PhantomDJEngine.Plan {
        if let bar = outgoing.beatGrid?.barDuration, bar > 0 {
            let start = DJMoveSupport.downbeat(outgoing, from: line, bars: -1) ?? (line - bar)
            let move = MixMove.echoOut
            let wall = DJMoveSupport.wallSeconds(move, outgoing: outgoing, exit: start, incomingRate: 1)
            if start >= outgoing.earliestExitSeconds - 0.01, start + wall < outgoing.duration + 0.05 {
                return PhantomDJEngine.Plan(
                    mixPointSeconds: start,
                    transitionSeconds: wall,
                    outroShape: .hardStop,
                    accent: nil,
                    reasoning: reason,
                    entrySeconds: entry,
                    bassSwapAtSeconds: DJMoveSupport.wallSeconds(move, outgoing: outgoing, exit: start, incomingRate: 1, bars: move.landingBar),
                    bassSwapSeconds: outgoing.beatGrid?.beatPeriod ?? 0.5,
                    incomingRateRatio: 1,
                    incomingTrackId: incomingTrackId ?? incoming?.trackId,
                    profileId: profile.id,
                    templateId: DJMoveIDs.echoOut,
                    outgoingBeatGrid: outgoing.beatGrid,
                    incomingBeatGrid: incoming?.beatGrid,
                    move: move
                )
            }
        }
        return PhantomDJEngine.Plan(
            mixPointSeconds: line,
            transitionSeconds: CutOnTheOneTemplate.fadeSeconds,
            outroShape: .hardStop,
            accent: nil,
            reasoning: reason,
            entrySeconds: entry,
            bassSwapAtSeconds: 0,
            bassSwapSeconds: CutOnTheOneTemplate.fadeSeconds,
            incomingRateRatio: 1,
            incomingTrackId: incomingTrackId ?? incoming?.trackId,
            profileId: profile.id,
            templateId: DJTemplates.cutOnTheOne,
            outgoingBeatGrid: outgoing.beatGrid,
            incomingBeatGrid: incoming?.beatGrid
        )
    }

    static let entrySearchBars = 32.0

    static func onTheOne(_ incoming: TrackFeatures, from entry: TimeInterval, clearOfVocalsForBars clear: Double = 0) -> TimeInterval {
        onTheOneLines(incoming, from: entry, clearOfVocalsForBars: clear).first ?? entry
    }

    static func onTheOneLines(_ incoming: TrackFeatures, from entry: TimeInterval, clearOfVocalsForBars clear: Double = 0) -> [TimeInterval] {
        guard let grid = incoming.beatGrid, grid.barDuration > 0 else { return [entry] }
        let avoid = clear > 0 && incoming.provenance.contains(.measuredVocals)
        let horizon = avoid ? incoming.duration * 0.5 : min(incoming.duration * 0.5, entry + entrySearchBars * grid.barDuration)
        let phrases = grid.phraseStarts(from: entry - 0.05, through: max(entry, horizon))
        let quiet = avoid ? phrases.filter { DJMoveSupport.vocalSeconds(incoming, $0...($0 + clear * grid.barDuration)) < 0.05 } : phrases
        let lines = quiet.isEmpty ? phrases : quiet
        if let profile = incoming.barProfile, incoming.barStarts.count == profile.level.count, profile.level.count >= 8 {
            let levels = profile.level.filter { $0 > -89 }.sorted()
            let body = levels.isEmpty ? 0 : levels[min(levels.count - 1, Int(Double(levels.count) * 0.75))]
            let accepted: [TimeInterval] = lines.compactMap { line in
                guard let index = incoming.barStarts.firstIndex(where: { abs($0 - line) < grid.beatPeriod }),
                      profile.level[index] >= body - DJIntro.cutEntryWithinDecibels else { return nil }
                return incoming.barStarts[index]
            }
            if !accepted.isEmpty { return accepted }
        }
        let energetic = lines.filter { DJContentBounds.hasEnergy(incoming, at: $0) }
        if !energetic.isEmpty { return energetic }
        return [incoming.barStarts.first { $0 >= entry - 0.05 && $0 <= horizon } ?? entry]
    }

    static func isEndOfTrack(_ plan: PhantomDJEngine.Plan, outgoing: TrackFeatures) -> Bool {
        guard plan.templateId == DJTemplates.cutOnTheOne, let bar = outgoing.beatGrid?.barDuration, bar > 0 else { return false }
        return plan.mixPointSeconds > outgoing.duration - 4 * bar
    }
}

enum DJLookAhead {
    static let fallDecibels: Float = 6
    static let riskFallDecibels: Float = 6
    static let jumpDecibels: Float = 9
    static let step: TimeInterval = 0.25
    static let fallWindow: TimeInterval = 0.5
    static let floorDecibels: Float = 30
    static let postBars = 2.0
    static let lowKillDecibels: Float = -3
    static let blendHeldBackDecibels: Float = -7
    static let echoTailBars = 8.0
    static let laterBars = 8
    static let laterDipDecibels: Float = 6
    static let laterPenalty = 0.12
    static let laterRisk: Float = 2

    struct Reading: Equatable, Sendable {
        let fall: Float
        let jump: Float
        let at: TimeInterval
        var breaksSoon = false
        var passes: Bool { fall <= DJLookAhead.fallDecibels && jump <= DJLookAhead.jumpDecibels }
        var excess: Float { max(0, fall - DJLookAhead.fallDecibels) + max(0, jump - DJLookAhead.jumpDecibels) }
        var risk: Float { max(0, fall - DJLookAhead.riskFallDecibels) + max(0, jump - DJLookAhead.jumpDecibels) + (breaksSoon ? DJLookAhead.laterRisk : 0) }
    }

    struct Levels {
        let starts: [TimeInterval]
        let level: [Float]
        let body: Float

        init?(_ track: TrackFeatures) {
            guard let profile = track.barProfile, track.barStarts.count == profile.level.count, profile.level.count >= 8 else { return nil }
            let measured = profile.level.filter { $0 > -89 }
            guard measured.count >= 8 else { return nil }
            body = DJMoveRails.percentile(measured, 0.75)
            let per = BarProfile.beatsPerBar
            guard let beats = profile.beats, beats.count == profile.level.count * per else {
                starts = track.barStarts
                level = profile.level
                return
            }
            let bars = track.barStarts
            var s: [TimeInterval] = []
            s.reserveCapacity(beats.count)
            for index in bars.indices {
                let length = index + 1 < bars.count ? bars[index + 1] - bars[index] : bars[index] - bars[max(0, index - 1)]
                for k in 0..<per { s.append(bars[index] + length * Double(k) / Double(per)) }
            }
            starts = s
            level = beats
        }

        func relative(_ seconds: TimeInterval) -> Float {
            guard let first = starts.first, seconds >= first - 0.05 else { return -floorDecibels }
            var lo = 0, hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= seconds + 0.05 { lo = mid + 1 } else { hi = mid }
            }
            let index = lo - 1
            guard index >= 0, index < level.count else { return -floorDecibels }
            if index == level.count - 1, seconds > starts[index] + (starts[index] - starts[max(0, index - 1)]) { return -floorDecibels }
            return max(-floorDecibels, level[index] - body)
        }
    }

    static func power(_ decibels: Float) -> Float { pow(10, decibels / 10) }
    static func decibels(_ power: Float) -> Float { 10 * log10(max(1e-6, power)) }
    static func amplitudeDecibels(_ amplitude: Double) -> Float { Float(20 * log10(max(1e-4, amplitude))) }

    static func ramp(_ t: TimeInterval, from a: TimeInterval, to b: TimeInterval) -> Double {
        guard b > a else { return t >= b ? 1 : 0 }
        return min(1, max(0, (t - a) / (b - a)))
    }

    static func penalty(_ plan: DJTransitionPlan, outgoing: TrackFeatures, incoming: TrackFeatures) -> Double {
        guard let reading = read(plan, outgoing: outgoing, incoming: incoming), reading.risk > 0 else { return 0 }
        return (reading.breaksSoon ? laterPenalty : 0) + (reading.fall > riskFallDecibels || reading.jump > jumpDecibels ? min(0.4, 0.12 + 0.03 * Double(reading.risk)) : 0)
    }

    static func read(_ plan: DJTransitionPlan, outgoing: TrackFeatures, incoming: TrackFeatures) -> Reading? {
        read(DJPlanShape(plan), outgoing: outgoing, incoming: incoming)
    }

    static func read(_ shape: DJPlanShape, outgoing: TrackFeatures, incoming: TrackFeatures) -> Reading? {
        guard let o = Levels(outgoing), let i = Levels(incoming), let bar = outgoing.beatGrid?.barDuration, bar > 0 else { return nil }
        let map = DJSourceMap(shape, outgoing: outgoing, incoming: incoming)
        let end = max(0, shape.overlap)
        let rate = shape.rate > 0 ? shape.rate : 1
        let inStart = map.incoming.first?.wallStart ?? end
        let kind = shape.move?.kind
        let echo = kind == .echoOut || shape.templateId == DJTemplates.echoOut
        let cut = shape.isCut
        let overlapBars = (end - inStart) / bar
        let fadeIn = (overlapBars < 16 ? 2.0 : 4.0) * bar
        let outFadeStart: TimeInterval
        let outFadeEnd: TimeInterval
        let inFullAt: TimeInterval
        if cut {
            outFadeStart = end; outFadeEnd = end; inFullAt = end
        } else if kind == .loopMix {
            let release = map.releaseWall ?? end
            outFadeStart = release; outFadeEnd = end; inFullAt = release
        } else if echo {
            outFadeStart = inStart; outFadeEnd = inStart + 4 * bar; inFullAt = inStart
        } else {
            outFadeStart = max(inStart, end - 4 * bar); outFadeEnd = end; inFullAt = min(end, inStart + fadeIn)
        }
        let landsOnOne = cut || kind == .fxBuild || kind == .loopRoll || kind == .dropOnTheOne || kind == .cut
        let heldBack = !cut && !echo && !landsOnOne && (kind == .blend || kind == nil)
        let swapAt = shape.bassSwapAt > 0 ? shape.bassSwapAt : inFullAt
        let incomingEnd = map.incomingSourceEnd ?? shape.entry
        func outgoingSource(_ t: TimeInterval) -> TimeInterval? {
            if t < 0 { return shape.exit + t }
            return map.outgoingSource(at: t)
        }
        func incomingSource(_ t: TimeInterval) -> TimeInterval? {
            if t > end { return incomingEnd + (t - end) * rate }
            return t >= inStart ? map.incomingSource(at: t) : nil
        }
        var times: [TimeInterval] = []
        var sum: [Float] = []
        var inc: [Float] = []
        var settled: [Bool] = []
        var t = -fallWindow - step
        let stop = end + postBars * bar
        while t <= stop {
            var total: Float = 0
            if let s = outgoingSource(t) {
                let gain = 1 - ramp(t, from: outFadeStart, to: outFadeEnd)
                if gain > 0.001 { total += power(o.relative(s) + amplitudeDecibels(gain)) }
                if echo, t >= inStart {
                    let tail = 0.2 * (1 - ramp(t, from: inStart, to: inStart + echoTailBars * bar))
                    if tail > 0.001 { total += power(o.relative(s) + amplitudeDecibels(tail)) }
                }
            }
            var incoming = -floorDecibels
            if let s = incomingSource(t) {
                let gain = cut || echo || landsOnOne ? 1 : (kind == .loopMix ? 0.1 + 0.9 * ramp(t, from: inStart, to: inFullAt) : ramp(t, from: inStart, to: inFullAt))
                if gain > 0.001 {
                    incoming = max(-floorDecibels, i.relative(s) + amplitudeDecibels(gain) + (t < swapAt ? (heldBack ? blendHeldBackDecibels * Float(1 - ramp(t, from: inStart, to: swapAt)) + lowKillDecibels : lowKillDecibels) : 0))
                    total += power(incoming)
                }
            }
            times.append(t)
            sum.append(max(-floorDecibels, decibels(total)))
            inc.append(incoming)
            settled.append(landsOnOne || t >= max(inStart, inFullAt) + step)
            t += step
        }
        let span = Int((fallWindow / step).rounded())
        var fall: Float = 0
        var jump: Float = 0
        var at: TimeInterval = 0
        for k in sum.indices {
            let hi = min(sum.count, k + span + 1)
            if let low = sum[k..<hi].min(), sum[k] - low > fall {
                fall = sum[k] - low
                at = times[k]
            }
            if k + 1 < inc.count, settled[k] { jump = max(jump, inc[k + 1] - inc[k]) }
        }
        return Reading(fall: fall, jump: jump, at: at, breaksSoon: breaksSoon(i, from: incomingEnd + postBars * bar * rate, bar: bar * rate))
    }
}

extension DJLookAhead {
    static func breaksSoon(_ levels: Levels, from start: TimeInterval, bar: TimeInterval) -> Bool {
        guard bar > 0 else { return false }
        let steps = Int((bar / step).rounded())
        for index in 0..<(laterBars - Int(postBars)) {
            let from = start + Double(index) * bar
            var total: Float = 0
            for k in 0..<steps { total += power(levels.relative(from + Double(k) * step)) }
            if decibels(total / Float(max(1, steps))) < -laterDipDecibels { return true }
        }
        return false
    }
}
