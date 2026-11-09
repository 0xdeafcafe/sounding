import Foundation

enum PhantomDJEngine {

    enum OutroShape: Equatable {
        case breakdown
        case fadeToSilence
        case hardStop
        case unknown
    }

    typealias Accent = TransitionAccent

    struct Plan: Equatable {
        let mixPointSeconds: TimeInterval
        let transitionSeconds: TimeInterval
        let outroShape: OutroShape
        let accent: Accent?
        let reasoning: String

        let entrySeconds: TimeInterval
        let bassSwapAtSeconds: TimeInterval
        let bassSwapSeconds: TimeInterval
        let incomingRateRatio: Double
        let incomingTrackId: String?
        let profileId: DJProfileID?
        let templateId: TransitionTemplateID?
        let rationale: PlanRationale?
        let stages: [TransitionStage]
        let outgoingBeatGrid: BeatGrid?
        let incomingBeatGrid: BeatGrid?
        let move: MixMove?
        let incomingTitle: String?
        var incomingMidCutDecibels: Double = 0
        var selection: DJFlowChoice?
        var feedback: AutoMixTransitionFeatures?
        var outgoingFeatures: TrackFeatures?
        var entryNote: String?

        func carryingExtras(from other: Plan) -> Plan {
            var copy = self
            copy.incomingMidCutDecibels = other.incomingMidCutDecibels
            copy.selection = other.selection
            copy.feedback = other.feedback
            copy.outgoingFeatures = other.outgoingFeatures
            copy.entryNote = other.entryNote
            return copy
        }

        init(
            mixPointSeconds: TimeInterval,
            transitionSeconds: TimeInterval,
            outroShape: OutroShape,
            accent: Accent?,
            reasoning: String,
            entrySeconds: TimeInterval = 0,
            bassSwapAtSeconds: TimeInterval? = nil,
            bassSwapSeconds: TimeInterval? = nil,
            incomingRateRatio: Double = 1,
            incomingTrackId: String? = nil,
            profileId: DJProfileID? = nil,
            templateId: TransitionTemplateID? = nil,
            rationale: PlanRationale? = nil,
            stages: [TransitionStage] = [],
            outgoingBeatGrid: BeatGrid? = nil,
            incomingBeatGrid: BeatGrid? = nil,
            move: MixMove? = nil,
            incomingTitle: String? = nil
        ) {
            self.mixPointSeconds = mixPointSeconds
            self.transitionSeconds = transitionSeconds
            self.outroShape = outroShape
            self.accent = accent
            self.reasoning = reasoning
            self.entrySeconds = entrySeconds
            self.bassSwapAtSeconds = bassSwapAtSeconds ?? (transitionSeconds * 0.55)
            self.bassSwapSeconds = bassSwapSeconds ?? min(0.5, transitionSeconds * 0.2)
            self.incomingRateRatio = incomingRateRatio
            self.incomingTrackId = incomingTrackId
            self.profileId = profileId
            self.templateId = templateId
            self.rationale = rationale
            self.stages = stages
            self.outgoingBeatGrid = outgoingBeatGrid
            self.incomingBeatGrid = incomingBeatGrid
            self.move = move
            self.incomingTitle = incomingTitle
        }

        var moveHeadline: String? {
            guard let move else { return nil }
            let title = incomingTitle ?? "the next track"
            let jump = move.kind == .jump ? max(0, entrySeconds - mixPointSeconds) : nil
            return move.headline(into: title, durationSeconds: jump)
        }

        var mixEndSeconds: TimeInterval { mixPointSeconds + transitionSeconds }

        /// Executor-faithful stages for consoles and companions. The older
        /// blend templates are implemented by `beginDefaultTransition`
        /// rather than explicit `TransitionStage` values; project those same
        /// crossfader, bass-swap and filter operations here so a Junkie mix
        /// never appears idle while the engine is actively performing it.
        var presentationStages: [TransitionStage] {
            guard stages.isEmpty else {
                return stages.sorted { $0.atSeconds < $1.atSeconds }
            }

            let window = max(0, transitionSeconds)

            if templateId == DJTemplates.cutOnTheOne {
                return [
                    TransitionStage(at: 0, on: .outgoing, .hardCut(fadeSeconds: window), snap: .free),
                    TransitionStage(at: 0, on: .incoming, .crossfadeTo(position: 1, over: window), snap: .free)
                ]
            }

            let swapAt = min(max(0, bassSwapAtSeconds), window)
            let swapDuration = min(max(0, bassSwapSeconds), max(0, window - swapAt))
            var projected: [TransitionStage] = []

            if abs(incomingRateRatio - 1) > 0.0005 {
                projected.append(TransitionStage(
                    at: 0,
                    on: .incoming,
                    .rateRatio(incomingRateRatio, over: 0),
                    snap: .free
                ))
            }

            projected.append(TransitionStage(
                at: 0,
                on: .incoming,
                .crossfadeTo(position: 1, over: window),
                snap: .free
            ))
            if templateId == DJTemplates.highPassThinOut {
                projected.append(TransitionStage(
                    at: 0,
                    on: .outgoing,
                    .highPassTo(hertz: HighPassThinOutTemplate.targetHertz, over: window),
                    snap: .free
                ))
            } else {
                projected.append(TransitionStage(
                    at: swapAt,
                    on: .outgoing,
                    .eqLow(decibels: MixEngine.eqGainRange.lowerBound, over: swapDuration),
                    snap: .bar
                ))
            }
            projected.append(TransitionStage(
                at: swapAt,
                on: .incoming,
                .eqLow(decibels: 0, over: swapDuration),
                snap: .bar
            ))

            switch accent {
            case .outgoingFilterClose:
                projected.append(TransitionStage(
                    at: 0,
                    on: .outgoing,
                    .lowPassTo(hertz: DJEngineConstants.accentClosedFilterHz, over: window),
                    snap: .free
                ))
            case .incomingFilterOpen:
                projected.append(TransitionStage(
                    at: 0,
                    on: .incoming,
                    .lowPassTo(hertz: MixEngine.filterCutoffRange.upperBound, over: window),
                    snap: .free
                ))
            case nil:
                break
            }

            return projected.sorted { lhs, rhs in
                if lhs.atSeconds == rhs.atSeconds {
                    return lhs.action.summary < rhs.action.summary
                }
                return lhs.atSeconds < rhs.atSeconds
            }
        }

        init(_ scored: ScoredPlan, outroShape: OutroShape) {
            self.init(
                mixPointSeconds: scored.plan.exit.seconds,
                transitionSeconds: scored.plan.overlapSeconds,
                outroShape: outroShape,
                accent: scored.plan.accent,
                reasoning: scored.rationale.reasoning,
                entrySeconds: scored.plan.entry.seconds,
                bassSwapAtSeconds: scored.plan.bassSwapAtSeconds,
                bassSwapSeconds: scored.plan.bassSwapSeconds,
                incomingRateRatio: scored.plan.incomingRateRatio,
                incomingTrackId: scored.plan.incomingTrackId,
                profileId: scored.plan.profileId,
                templateId: scored.plan.templateId,
                rationale: scored.rationale,
                stages: scored.plan.stages,
                move: scored.plan.move
            )
        }

        func withBeatGrids(outgoing: BeatGrid?, incoming: BeatGrid?) -> Plan {
            Plan(
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
                outgoingBeatGrid: outgoing,
                incomingBeatGrid: incoming,
                move: move,
                incomingTitle: incomingTitle
            ).carryingExtras(from: self)
        }

        func titled(_ title: String?) -> Plan {
            Plan(
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
                incomingTitle: title
            ).carryingExtras(from: self)
        }

        func selected(_ choice: DJFlowChoice?) -> Plan {
            var copy = self
            copy.selection = choice
            return copy
        }
    }


    static func plan(outgoingDuration: TimeInterval, envelope: [Float]) -> Plan? {
        guard outgoingDuration.isFinite, outgoingDuration >= DJEngineConstants.minimumPlannableDuration else { return nil }
        guard envelope.count >= 8 else { return nil }

        let bucketSeconds = outgoingDuration / Double(envelope.count)
        guard bucketSeconds > 0 else { return nil }

        let sorted = envelope.sorted()
        let median = Double(sorted[sorted.count / 2])
        let quietThreshold = max(0.05, median * 0.55)

        let floorSeconds = max(outgoingDuration * 0.55, outgoingDuration - 90)
        let floorBucket = min(envelope.count - 1, max(0, Int(floorSeconds / bucketSeconds)))
        let tailSkipBuckets = Int(2 / bucketSeconds)
        let ceilBucket = max(floorBucket, envelope.count - 1 - tailSkipBuckets)
        guard floorBucket < ceilBucket else { return nil }

        var calmStart = ceilBucket
        var i = ceilBucket
        while i >= floorBucket, Double(envelope[i]) <= quietThreshold {
            calmStart = i
            i -= 1
        }
        let calmBucketLength = ceilBucket - calmStart
        let hasCalmRegion = calmBucketLength >= 4

        let mixPointBucket: Int
        let transitionSeconds: TimeInterval
        let outroShape: OutroShape

        if hasCalmRegion {
            mixPointBucket = calmStart
            let calmLength = Double(calmBucketLength) * bucketSeconds
            transitionSeconds = min(DJEngineConstants.maximumTransitionSeconds, max(6, calmLength * 0.9))
            let floorAmplitude = envelope[calmStart...ceilBucket].map(Double.init).min() ?? quietThreshold
            outroShape = floorAmplitude <= quietThreshold * 0.4 ? .fadeToSilence : .breakdown
        } else {
            let hardStopLookback = Int(4 / bucketSeconds)
            mixPointBucket = max(floorBucket, envelope.count - 1 - hardStopLookback)
            transitionSeconds = DJEngineConstants.minimumTransitionSeconds
            outroShape = .hardStop
        }

        let mixPointSeconds = min(outgoingDuration - 1, Double(mixPointBucket) * bucketSeconds)
        let clampedTransition = min(
            transitionSeconds,
            max(DJEngineConstants.minimumTransitionSeconds, outgoingDuration - mixPointSeconds)
        )

        let accent: Accent?
        switch outroShape {
        case .breakdown where clampedTransition >= 10: accent = .outgoingFilterClose
        case .fadeToSilence where clampedTransition >= 8: accent = .incomingFilterOpen
        default: accent = nil
        }

        return Plan(
            mixPointSeconds: mixPointSeconds,
            transitionSeconds: clampedTransition,
            outroShape: outroShape,
            accent: accent,
            reasoning: describe(
                outroShape: outroShape,
                mixPointSeconds: mixPointSeconds,
                transitionSeconds: clampedTransition,
                accent: accent
            )
        )
    }

    static func fallbackPlan(outgoingDuration: TimeInterval) -> Plan? {
        guard outgoingDuration.isFinite, outgoingDuration >= DJEngineConstants.minimumPlannableDuration else { return nil }
        let transitionSeconds = min(16, max(DJEngineConstants.minimumTransitionSeconds, outgoingDuration * 0.12))
        let mixPointSeconds = max(0, outgoingDuration - transitionSeconds)
        return Plan(
            mixPointSeconds: mixPointSeconds,
            transitionSeconds: transitionSeconds,
            outroShape: .unknown,
            accent: nil,
            reasoning: "No waveform for this track — using a flat \(Int(transitionSeconds.rounded()))s "
                + "lookahead instead of a found breakdown."
        )
    }

    /// The deadline-safe move when analysis has not produced an admissible
    /// plan. This is intentionally a real catalog transition, not a generic
    /// blend masquerading as a decision.
    static func cleanCutFallbackPlan(
        outgoingDuration: TimeInterval,
        incomingTrackId: String?,
        profile: DJProfile?,
        envelope: [Float] = [],
        reasoning: String? = nil
    ) -> Plan? {
        guard outgoingDuration.isFinite, outgoingDuration > CutOnTheOneTemplate.fadeSeconds else { return nil }
        let baseReasoning = reasoning ?? "Analysis is still arriving — playing this track out, then making a clean cut."

        guard let profile, profile.allowMidTrackExit else {
            let cutAt = max(0, outgoingDuration - CutOnTheOneTemplate.fadeSeconds - 0.5)
            return Plan(
                mixPointSeconds: cutAt,
                transitionSeconds: CutOnTheOneTemplate.fadeSeconds,
                outroShape: .hardStop,
                accent: nil,
                reasoning: baseReasoning,
                entrySeconds: 0,
                bassSwapAtSeconds: 0,
                bassSwapSeconds: CutOnTheOneTemplate.fadeSeconds,
                incomingRateRatio: 1,
                incomingTrackId: incomingTrackId,
                profileId: profile?.id,
                templateId: DJTemplates.cutOnTheOne
            )
        }

        let latest = outgoingDuration - CutOnTheOneTemplate.fadeSeconds - 0.5
        let earliest = profile.minimumPlayFraction * outgoingDuration
        let finalReasoning: String
        var cutAt: TimeInterval

        if let valley = DJPointFinder.bestValleyStart(envelope: envelope, duration: outgoingDuration, after: earliest),
           valley < latest {
            cutAt = valley
            finalReasoning = "\(baseReasoning) No analysis yet — cutting at an energy dip found in the waveform, not the end of the track."
        } else {
            cutAt = max(earliest, outgoingDuration * 0.6)
            finalReasoning = "\(baseReasoning) No analysis yet — cutting past \(Int((profile.minimumPlayFraction * 100).rounded()))% of the track rather than waiting for the end."
        }
        cutAt = max(0, min(cutAt, latest))

        return Plan(
            mixPointSeconds: cutAt,
            transitionSeconds: CutOnTheOneTemplate.fadeSeconds,
            outroShape: .hardStop,
            accent: nil,
            reasoning: finalReasoning,
            entrySeconds: 0,
            bassSwapAtSeconds: 0,
            bassSwapSeconds: CutOnTheOneTemplate.fadeSeconds,
            incomingRateRatio: 1,
            incomingTrackId: incomingTrackId,
            profileId: profile.id,
            templateId: DJTemplates.cutOnTheOne
        )
    }

    struct PlanningInputs {
        let outgoing: TrackFeatures
        let candidates: [TrackFeatures]
        let profile: DJProfile
        let history: SetHistory
        let capabilities: ExecutorCapabilities
        let seedComponents: [String]
        let userTransitionSeconds: Double?

        init(
            outgoing: TrackFeatures,
            candidates: [TrackFeatures],
            profile: DJProfile,
            history: SetHistory = .empty,
            capabilities: ExecutorCapabilities = .fullMixEngine,
            seedComponents: [String],
            userTransitionSeconds: Double? = nil
        ) {
            self.outgoing = outgoing
            self.candidates = candidates
            self.profile = profile
            self.history = history
            self.capabilities = capabilities
            self.seedComponents = seedComponents
            self.userTransitionSeconds = userTransitionSeconds
        }
    }

    static func rank(_ inputs: PlanningInputs) -> PlanningResult {
        var rng = SeededGenerator(inputs.seedComponents)
        return DJPlanner.plan(
            outgoing: inputs.outgoing,
            candidates: inputs.candidates,
            profile: inputs.profile,
            templates: DJTemplates.v1Registry,
            scoring: DJTerms.v1Registry,
            capabilities: inputs.capabilities,
            history: inputs.history,
            rng: &rng,
            userTransitionSeconds: inputs.userTransitionSeconds
        )
    }

    static func plan(_ inputs: PlanningInputs) -> (plan: Plan?, result: PlanningResult) {
        let result = rank(inputs)
        return (select(result, inputs: inputs), result)
    }

    static func select(_ result: PlanningResult, inputs: PlanningInputs) -> Plan? {
        let minimumBlend = inputs.outgoing.beatGrid.map {
            $0.barDuration * Double(inputs.profile.transitionBarsRange.lowerBound) - 0.05
        }
        let selected = selectPlan(
            from: result, profile: inputs.profile, minimumBlendSeconds: minimumBlend,
            outgoingBarSeconds: inputs.outgoing.beatGrid?.barDuration,
            runwaysFavourBlend: { plan in
                inputs.candidates.first { $0.trackId == plan.incomingTrackId }.map {
                    runwaysFavourBlend(outgoing: inputs.outgoing, incoming: $0)
                } ?? false
            },
            referenceSeconds: { plan in
                inputs.outgoing.beatGrid.map {
                    $0.barDuration * Double(inputs.profile.referenceBars(
                        outgoing: inputs.outgoing,
                        incoming: inputs.candidates.first { $0.trackId == plan.incomingTrackId }
                    ))
                }
            }
        )
        let incomingGrid = selected?.incomingTrackId.flatMap { id in
            inputs.candidates.first(where: { $0.trackId == id })?.beatGrid
        }
        return selected?.withBeatGrids(outgoing: inputs.outgoing.beatGrid, incoming: incomingGrid)
    }

    static func selectPlan(
        from result: PlanningResult,
        profile: DJProfile,
        minimumBlendSeconds: TimeInterval? = nil,
        outgoingBarSeconds: TimeInterval? = nil,
        runwaysFavourBlend: (DJTransitionPlan) -> Bool = { _ in false },
        referenceSeconds: (DJTransitionPlan) -> TimeInterval? = { _ in nil }
    ) -> Plan? {
        if let winner = firingWinner(
            from: result, profile: profile, minimumBlendSeconds: minimumBlendSeconds, outgoingBarSeconds: outgoingBarSeconds, runwaysFavourBlend: runwaysFavourBlend, referenceSeconds: referenceSeconds
        ) {
            let cuts = winner.plan.templateId == DJTemplates.cutOnTheOne || winner.plan.move?.kind == .cut
            if cuts, winner.plan.exit.confidence < 1, let softer = stepDown(from: result, outgoingBarSeconds: outgoingBarSeconds) {
                return Plan(softer, outroShape: outroShape(for: softer.plan.exit.kind))
            }
            return Plan(winner, outroShape: outroShape(for: winner.plan.exit.kind))
        }

        if !result.ranked.contains(where: { $0.plan.exit.confidence >= 1 }),
           let soft = stepDown(from: result, outgoingBarSeconds: outgoingBarSeconds) {
            let plan = Plan(soft, outroShape: outroShape(for: soft.plan.exit.kind))
            return Plan(
                mixPointSeconds: plan.mixPointSeconds,
                transitionSeconds: plan.transitionSeconds,
                outroShape: plan.outroShape,
                accent: plan.accent,
                reasoning: refusalReasoning(result, profile: profile, fallback: soft.rationale.headline),
                entrySeconds: plan.entrySeconds,
                bassSwapAtSeconds: plan.bassSwapAtSeconds,
                bassSwapSeconds: plan.bassSwapSeconds,
                incomingRateRatio: plan.incomingRateRatio,
                incomingTrackId: plan.incomingTrackId,
                profileId: plan.profileId,
                templateId: plan.templateId,
                rationale: plan.rationale,
                stages: plan.stages,
                move: plan.move
            )
        }

        // A blend that misses the profile's confidence floor must not sneak
        // through as a generic crossfade. The catalog's clean cut is the
        // deliberate, executable fallback: keep its chosen entry/downbeat,
        // but explain why the more ambitious plans were declined.
        guard let cleanCut = result.ranked.first(where: {
            $0.plan.templateId == DJTemplates.cutOnTheOne
        }) else {
            return nil
        }
        let cut = Plan(cleanCut, outroShape: .hardStop)
        return Plan(
            mixPointSeconds: cut.mixPointSeconds,
            transitionSeconds: cut.transitionSeconds,
            outroShape: cut.outroShape,
            accent: nil,
            reasoning: refusalReasoning(result, profile: profile),
            entrySeconds: cut.entrySeconds,
            bassSwapAtSeconds: cut.bassSwapAtSeconds,
            bassSwapSeconds: cut.bassSwapSeconds,
            incomingRateRatio: 1,
            incomingTrackId: cut.incomingTrackId,
            profileId: cut.profileId,
            templateId: cut.templateId,
            rationale: cut.rationale,
            stages: cut.stages
        )
    }

    private static func firingWinner(
        from result: PlanningResult,
        profile: DJProfile,
        minimumBlendSeconds: TimeInterval?,
        outgoingBarSeconds: TimeInterval?,
        runwaysFavourBlend: (DJTransitionPlan) -> Bool,
        referenceSeconds: (DJTransitionPlan) -> TimeInterval?
    ) -> ScoredPlan? {
        guard let best = result.firing else { return nil }
        let firing = result.ranked.filter { $0.fires && $0.plan.templateId != DJTemplates.cutOnTheOne }
        if let cued = firing.filter({ $0.plan.exit.confidence >= 1 }).max(by: { $0.score < $1.score }) {
            return cued
        }
        if result.ranked.contains(where: { $0.plan.exit.confidence >= 1 }) {
            return nil
        }
        guard !profile.allowMidTrackExit else { return best }

        let blends = firing.filter { $0.plan.move == nil || $0.plan.move?.kind == .loopMix || $0.plan.move?.kind == .blend }
        let bestMove = firing.filter { $0.plan.move != nil && $0.plan.move?.kind != .loopMix && $0.plan.move?.kind != .blend }.max(by: { $0.score < $1.score })
        let long = minimumBlendSeconds.map { minimum in blends.filter { $0.plan.overlapSeconds >= minimum } } ?? []
        let textbook = long.filter { scored in
            guard let bar = outgoingBarSeconds, bar > 0 else { return false }
            let reference = referenceSeconds(scored.plan) ?? Self.textbookBlendBars * bar
            return scored.plan.overlapSeconds >= min(Self.textbookBlendBars * bar, reference) - 0.05
        }
        let pool = !textbook.isEmpty ? textbook : long.isEmpty ? blends : long
        guard let poolBest = pool.max(by: { $0.score < $1.score }) else { return bestMove ?? best }
        let runwayBlend = !long.isEmpty && profile.adventure < 1 && runwaysFavourBlend(poolBest.plan)
        let landingMargin = bestMove.map { Self.landsHard($0.plan) && profile.adventure < 1 ? Self.hardLandingMargin : 0 } ?? 0
        if let bestMove, !runwayBlend, bestMove.score >= poolBest.score + profile.moveMargin + landingMargin { return bestMove }
        let nearBestFloor = max(profile.minimumScoreToFire, poolBest.score - 0.08)
        func lengthRank(_ scored: ScoredPlan) -> Double {
            guard let reference = referenceSeconds(scored.plan), reference > 0 else { return (scored.plan.overlapSeconds / 2).rounded() }
            return -abs(log2(max(0.5, scored.plan.overlapSeconds) / reference) * 4).rounded()
        }
        let loops = pool.filter { $0.plan.move?.kind == .loopMix }
        let plain = pool.filter { $0.plan.move?.kind != .loopMix }
        let blend = plain
            .filter { $0.score >= nearBestFloor }
            .max { lhs, rhs in
                let lhsLength = lengthRank(lhs)
                let rhsLength = lengthRank(rhs)
                if lhsLength != rhsLength { return lhsLength < rhsLength }
                if abs(lhs.plan.exit.seconds - rhs.plan.exit.seconds) > 0.5 {
                    return lhs.plan.exit.seconds < rhs.plan.exit.seconds
                }
                return lhs.score < rhs.score
            }
        let loop = loops.max { $0.score < $1.score }
        switch (blend, loop) {
        case let (blend?, loop?): return loop.score > (plain.map(\.score).max() ?? blend.score) ? loop : blend
        case let (blend?, nil): return blend
        case let (nil, loop?): return loop
        default: return best
        }
    }

    static func outroShape(for kind: SectionKind) -> OutroShape {
        switch kind {
        case .ambientOutro:                    return .fadeToSilence
        case .breakdown, .cooldown, .bridge:   return .breakdown
        case .outro, .intro, .buildup, .build, .drop, .ambientIntro: return .hardStop
        case .unknown:                         return .unknown
        }
    }

    static let stepDownBlendBars = 16.0
    static let textbookBlendBars = 16.0
    static let hardLandingMargin = 0.15

    static func landsHard(_ plan: DJTransitionPlan) -> Bool {
        guard let kind = plan.move?.kind else { return false }
        return [.cut, .dropOnTheOne, .fxBuild, .loopRoll].contains(kind)
    }
    static let blendRunwayBars = 16.0

    static func runwaysFavourBlend(outgoing: TrackFeatures, incoming: TrackFeatures) -> Bool {
        guard outgoing.provenance.contains(.measuredVocals), incoming.provenance.contains(.measuredVocals),
              let outBar = outgoing.beatGrid?.barDuration, let inBar = incoming.beatGrid?.barDuration,
              outBar > 0, inBar > 0 else { return false }
        let outRunway = (outgoing.duration - (outgoing.vocalRanges.map(\.upperBound).max() ?? 0)) / outBar
        let inRunway = (incoming.vocalRanges.map(\.lowerBound).min() ?? incoming.duration) / inBar
        return outRunway >= blendRunwayBars && inRunway >= blendRunwayBars
    }

    static func stepDown(from result: PlanningResult, outgoingBarSeconds: TimeInterval?) -> ScoredPlan? {
        let usable = result.ranked.filter { $0.score > 0 }
        func latest(_ plans: [ScoredPlan]) -> ScoredPlan? {
            plans.max { lhs, rhs in
                if abs(lhs.plan.exit.seconds - rhs.plan.exit.seconds) > 0.5 { return lhs.plan.exit.seconds < rhs.plan.exit.seconds }
                return lhs.score < rhs.score
            }
        }
        let blends = usable.filter { scored in
            guard scored.plan.move == nil || scored.plan.move?.kind == .blend, scored.plan.templateId != DJTemplates.cutOnTheOne,
                  let bar = outgoingBarSeconds, bar > 0 else { return false }
            return scored.plan.overlapSeconds <= Self.stepDownBlendBars * bar + 0.05
        }
        if let blend = blends.max(by: { $0.score < $1.score }) { return blend }
        let filters = usable.filter { [DJTemplates.filterFadeOut, DJTemplates.filterBloomIn, DJTemplates.highPassThinOut].contains($0.plan.templateId) }
        if let filter = filters.max(by: { $0.score < $1.score }) { return filter }
        let echoes = usable.filter { $0.plan.templateId == DJTemplates.echoOut || $0.plan.templateId == DJMoveIDs.echoOut }
        return latest(echoes)
    }

    static func refusalReasoning(_ result: PlanningResult, profile: DJProfile, fallback: String? = nil) -> String {
        let ending = fallback.map { " — stepping down: \($0)." } ?? " — playing out to a clean cut."
        if let best = result.ranked.first {
            return best.rationale.reasoning
                + " Scored \(String(format: "%.2f", best.score)) against "
                + "\(profile.displayName)'s \(String(format: "%.2f", profile.minimumScoreToFire)) threshold" + ending
        }
        if let rejection = result.rejections.first {
            return "No mix — \(rejection.reason). Playing out to a clean cut."
        }
        return "No mix — nothing to mix into. Playing out to a clean cut."
    }

    private static func describe(
        outroShape: OutroShape,
        mixPointSeconds: TimeInterval,
        transitionSeconds: TimeInterval,
        accent: Accent?
    ) -> String {
        let point = formatTime(mixPointSeconds)
        let length = Int(transitionSeconds.rounded())
        switch outroShape {
        case .breakdown:
            let accentNote = accent == .outgoingFilterClose ? ", filtering the outgoing deck down" : ""
            return "Breakdown found at \(point) — \(length)s blend with a bass swap\(accentNote)."
        case .fadeToSilence:
            let accentNote = accent == .incomingFilterOpen ? ", rolling the incoming deck's filter open" : ""
            return "Fades to silence from \(point) — \(length)s blend with a bass swap\(accentNote)."
        case .hardStop:
            return "Runs hot to the end — short \(length)s blend at \(point), bass swap only, no accent."
        case .unknown:
            return "No waveform available — short \(length)s blend at \(point)."
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

enum PhantomActivity: Equatable {
    case idle
    case armed(PhantomDJEngine.Plan)
    case mixing(PhantomDJEngine.Plan)
    case cutting(reason: String)

    var statusText: String {
        switch self {
        case .idle: return ""
        case .armed(let plan): return plan.reasoning
        case .mixing(let plan): return "Mixing — \(plan.reasoning)"
        case .cutting(let reason): return reason
        }
    }
}
