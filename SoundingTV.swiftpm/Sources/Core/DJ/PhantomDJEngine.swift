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
            incomingBeatGrid: BeatGrid? = nil
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
        }

        var mixEndSeconds: TimeInterval { mixPointSeconds + transitionSeconds }

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
                stages: scored.plan.stages
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
                incomingBeatGrid: incoming
            )
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
        profileId: DJProfileID?,
        reasoning: String = "Analysis is still arriving — playing this track out, then making a clean cut."
    ) -> Plan? {
        guard outgoingDuration.isFinite, outgoingDuration > CutOnTheOneTemplate.fadeSeconds else { return nil }
        let cutAt = max(0, outgoingDuration - CutOnTheOneTemplate.fadeSeconds - 0.5)
        return Plan(
            mixPointSeconds: cutAt,
            transitionSeconds: CutOnTheOneTemplate.fadeSeconds,
            outroShape: .hardStop,
            accent: nil,
            reasoning: reasoning,
            entrySeconds: 0,
            bassSwapAtSeconds: 0,
            bassSwapSeconds: CutOnTheOneTemplate.fadeSeconds,
            incomingRateRatio: 1,
            incomingTrackId: incomingTrackId,
            profileId: profileId,
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

        init(
            outgoing: TrackFeatures,
            candidates: [TrackFeatures],
            profile: DJProfile,
            history: SetHistory = .empty,
            capabilities: ExecutorCapabilities = .v1MixEngine,
            seedComponents: [String]
        ) {
            self.outgoing = outgoing
            self.candidates = candidates
            self.profile = profile
            self.history = history
            self.capabilities = capabilities
            self.seedComponents = seedComponents
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
            rng: &rng
        )
    }

    static func plan(_ inputs: PlanningInputs) -> (plan: Plan?, result: PlanningResult) {
        let result = rank(inputs)
        let selected = selectPlan(from: result, profile: inputs.profile)
        let incomingGrid = selected?.incomingTrackId.flatMap { id in
            inputs.candidates.first(where: { $0.trackId == id })?.beatGrid
        }
        return (
            selected?.withBeatGrids(outgoing: inputs.outgoing.beatGrid, incoming: incomingGrid),
            result
        )
    }

    static func selectPlan(from result: PlanningResult, profile: DJProfile) -> Plan? {
        if let winner = firingWinner(from: result, profile: profile) {
            return Plan(winner, outroShape: outroShape(for: winner.plan.exit.kind))
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

    /// Ranking still establishes quality. For the everyday automatic profile,
    /// an earlier phrase is more useful than an outro when it is within a small
    /// quality margin of the top result. This keeps the director lively without
    /// accepting a weak transition merely because it occurs sooner.
    private static func firingWinner(from result: PlanningResult, profile: DJProfile) -> ScoredPlan? {
        guard let best = result.firing else { return nil }
        guard profile.id == .automatic else { return best }

        let nearBestFloor = max(profile.minimumScoreToFire, best.score - 0.08)
        return result.ranked
            .filter {
                $0.fires
                    && $0.score >= nearBestFloor
                    && $0.plan.templateId != DJTemplates.cutOnTheOne
            }
            .min {
                if abs($0.plan.exit.seconds - $1.plan.exit.seconds) > 0.5 {
                    return $0.plan.exit.seconds < $1.plan.exit.seconds
                }
                return $0.score > $1.score
            }
            ?? best
    }

    static func outroShape(for kind: SectionKind) -> OutroShape {
        switch kind {
        case .ambientOutro:                    return .fadeToSilence
        case .breakdown, .cooldown, .bridge:   return .breakdown
        case .outro, .intro, .buildup, .drop, .ambientIntro: return .hardStop
        case .unknown:                         return .unknown
        }
    }

    static func refusalReasoning(_ result: PlanningResult, profile: DJProfile) -> String {
        if let best = result.ranked.first {
            return best.rationale.reasoning
                + " Scored \(String(format: "%.2f", best.score)) against "
                + "\(profile.displayName)'s \(String(format: "%.2f", profile.minimumScoreToFire)) threshold — playing out to a clean cut."
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
