import Foundation

enum DJPlanner {

    static let minimumEntryRunwaySeconds: TimeInterval = 30

    static func rank(
        outgoing: TrackFeatures,
        candidates: [TrackFeatures],
        profile: DJProfile,
        templates: TransitionRegistry,
        scoring: ScoringRegistry,
        capabilities: ExecutorCapabilities,
        history: SetHistory,
        rng: inout SeededGenerator,
        userTransitionSeconds: Double? = nil
    ) -> [ScoredPlan] {
        plan(
            outgoing: outgoing, candidates: candidates, profile: profile,
            templates: templates, scoring: scoring, capabilities: capabilities,
            history: history, rng: &rng, userTransitionSeconds: userTransitionSeconds
        ).ranked
    }

    static func plan(
        outgoing: TrackFeatures,
        candidates: [TrackFeatures],
        profile: DJProfile,
        templates: TransitionRegistry,
        scoring: ScoringRegistry,
        capabilities: ExecutorCapabilities,
        history: SetHistory,
        rng: inout SeededGenerator,
        userTransitionSeconds: Double? = nil
    ) -> PlanningResult {
        var ranked: [ScoredPlan] = []
        var rejections: [PlanRejection] = []

        let admissible = templates.admissible(for: profile, capabilities: capabilities)
        if admissible.isEmpty {
            return PlanningResult(
                ranked: [],
                rejections: [PlanRejection(
                    incomingTrackId: "",
                    templateId: nil,
                    reason: "no transition template is both allowed by \(profile.displayName) and executable by this build"
                )]
            )
        }

        let exits = DJPointFinder.exitCandidates(in: outgoing, profile: profile)
        if exits.isEmpty {
            return PlanningResult(
                ranked: [],
                rejections: [PlanRejection(
                    incomingTrackId: "",
                    templateId: nil,
                    reason: "no usable exit point in \(outgoing.displayName) — nothing past \(percent(profile.exitRegionFloor)) of the track to mix out of"
                )]
            )
        }

        let terms = scoring.ordered
        let effectiveUserTransitionSeconds = profile.honoursUserTransitionLength ? userTransitionSeconds : nil
        let transitionCap = effectiveUserTransitionSeconds.map { max($0 * 1.5, $0 + 4) }

        for candidate in candidates.prefix(max(1, profile.lookaheadCandidates)) {
            guard candidate.trackId != outgoing.trackId else {
                rejections.append(PlanRejection(
                    incomingTrackId: candidate.trackId, templateId: nil,
                    reason: "a track cannot mix into itself"
                ))
                continue
            }

            let entries = DJPointFinder.entryCandidates(in: candidate, profile: profile)
            guard !entries.isEmpty else {
                rejections.append(PlanRejection(
                    incomingTrackId: candidate.trackId, templateId: nil,
                    reason: "no usable entry point in \(candidate.displayName)"
                ))
                continue
            }

            for template in admissible {
                if profile.requireMeasuredBPMForRate,
                   template.requiredCapabilities.contains(.timeStretch),
                   (!outgoing.provenance.contains(.measuredTempo)
                    || !candidate.provenance.contains(.measuredTempo)) {
                    rejections.append(PlanRejection(
                        incomingTrackId: candidate.trackId, templateId: template.id,
                        reason: "\(template.displayName) needs measured tempo on both tracks for \(profile.displayName)"
                    ))
                    continue
                }
                switch template.admits(outgoing: outgoing, incoming: candidate, profile: profile) {
                case .rejected(let reason):
                    rejections.append(PlanRejection(
                        incomingTrackId: candidate.trackId, templateId: template.id, reason: reason
                    ))
                    continue
                case .admitted:
                    break
                }

                let proposals = template.propose(
                    outgoing: outgoing, incoming: candidate,
                    exits: exits, entries: entries, profile: profile, rng: &rng
                )
                if proposals.isEmpty {
                    rejections.append(PlanRejection(
                        incomingTrackId: candidate.trackId, templateId: template.id,
                        reason: "\(template.displayName) found no workable exit/entry pair"
                    ))
                }
                for rawProposal in proposals {
                    let proposal = transitionCap.map(rawProposal.clampingOverlap(toAtMost:)) ?? rawProposal
                    let needed = proposal.stageCapabilities
                    guard capabilities.isSuperset(of: needed) else {
                        rejections.append(PlanRejection(
                            incomingTrackId: candidate.trackId, templateId: template.id,
                            reason: "\(template.displayName) needs DSP this build does not have"
                        ))
                        continue
                    }
                    let entryRunway = candidate.duration - proposal.entry.seconds
                    let neededRunway = proposal.overlapSeconds + Self.minimumEntryRunwaySeconds
                    guard entryRunway >= neededRunway else {
                        rejections.append(PlanRejection(
                            incomingTrackId: candidate.trackId, templateId: template.id,
                            reason: "\(template.displayName): entering \(candidate.displayName) at \(Int(proposal.entry.seconds))s leaves only \(Int(entryRunway))s, needs \(Int(neededRunway))s of runway"
                        ))
                        continue
                    }
                    var scored = score(
                        plan: proposal, outgoing: outgoing, incoming: candidate,
                        profile: profile, terms: terms, history: history,
                        templateName: template.displayName
                    )
                    if let reason = DJMoveRails.veto(proposal, outgoing: outgoing, incoming: candidate, profile: profile, history: history)
                        ?? DJPlanValidator.reason(DJPlanShape(proposal), outgoing: outgoing, incoming: candidate, profile: profile) {
                        scored = vetoed(scored, reason: reason, profile: profile)
                    } else if scored.score > 0 {
                        let adjustment = DJMoveRails.adjustment(proposal, outgoing: outgoing, incoming: candidate, profile: profile, history: history)
                        let learned = history.learned.adjustment(for: proposal, barSeconds: outgoing.beatGrid?.barDuration)
                        let style = history.style.adjustment(
                            move: AutoMixMove.of(templateId: proposal.templateId, move: proposal.move),
                            blendBars: AutoMixTransitionFeatures.blendBucket(proposal.overlapSeconds / max(0.1, outgoing.beatGrid?.barDuration ?? 2)),
                            keySteps: DJMoveSupport.keySteps(outgoing, at: proposal.exit.seconds, candidate, at: proposal.entry.seconds)
                        )
                        let personal = AutoMixStyle.personalAdjustment(learned: learned, style: style)
                        let energy = DJIntro.energyAdjustment(outgoing: outgoing, exit: proposal.exit.seconds, incoming: candidate, entry: proposal.entry.seconds)
                        let net = history.transitionNet?.adjustment(for: proposal, outgoing: outgoing, incoming: candidate) ?? 0
                        let sets = history.setPriors?.adjustment(for: proposal, barSeconds: outgoing.beatGrid?.barDuration) ?? 0
                        let length = lengthAdjustment(proposal, outgoing: outgoing, incoming: candidate, profile: profile)
                        let lookAhead = DJLookAhead.penalty(proposal, outgoing: outgoing, incoming: candidate)
                        let delta = adjustment.delta + personal + energy + net + sets + length - lookAhead
                        if delta != 0 {
                            scored = ScoredPlan(plan: scored.plan, score: min(1, max(0, scored.score + delta)), rationale: scored.rationale)
                        }
                    }
                    if let effectiveUserTransitionSeconds, scored.score > 0 {
                        let distance = abs(proposal.overlapSeconds - effectiveUserTransitionSeconds)
                            / max(4, effectiveUserTransitionSeconds)
                        let bias = min(0.06, distance * 0.03)
                        if bias > 0 {
                            scored = ScoredPlan(plan: scored.plan, score: max(0, scored.score - bias), rationale: scored.rationale)
                        }
                    }
                    ranked.append(scored)
                }
            }
        }

        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.plan.templateId.rawValue != $1.plan.templateId.rawValue {
                return $0.plan.templateId.rawValue < $1.plan.templateId.rawValue
            }
            return $0.plan.entry.seconds < $1.plan.entry.seconds
        }
        return PlanningResult(ranked: ranked, rejections: rejections)
    }

    static let lengthWeight = 0.03

    static func lengthAdjustment(_ plan: DJTransitionPlan, outgoing: TrackFeatures, incoming: TrackFeatures?, profile: DJProfile) -> Double {
        guard let bar = outgoing.beatGrid?.barDuration, bar > 0, plan.templateId != DJTemplates.cutOnTheOne,
              plan.move.map({ $0.hasOverlap }) ?? true else { return 0 }
        let bars = plan.overlapSeconds / bar
        guard bars >= 2 else { return 0 }
        let distance = abs(log2(bars / Double(max(1, profile.referenceBars(outgoing: outgoing, incoming: incoming)))))
        return lengthWeight * max(0, 1 - distance)
    }

    static func score(
        plan: DJTransitionPlan,
        outgoing: TrackFeatures,
        incoming: TrackFeatures,
        profile: DJProfile,
        terms: [any ScoringTerm],
        history: SetHistory,
        templateName: String
    ) -> ScoredPlan {
        let ctx = ScoringContext(
            outgoing: outgoing, incoming: incoming, plan: plan,
            profile: profile, history: history
        )

        var numerator = 0.0
        var denominator = 0.0
        var measuredWeight = 0.0
        var vetoed: String?
        var all: [PlanRationale.Contribution] = []
        var worstConcern = 0.0
        let maxWeight = max(0.0001, profile.weights.values.max() ?? 1)

        for term in terms {
            let weight = profile.weights[term.id] ?? 0
            guard weight > 0 else { continue }
            let result = term.evaluate(ctx)
            if result.veto, vetoed == nil {
                vetoed = result.explanation ?? "\(term.id.rawValue) refused this plan"
            }
            let effectiveWeight = weight * result.confidence
            // Unknown evidence is uncertainty, not a free pass. It carries a
            // conservative neutral cost and also lowers the evidence ceiling.
            let unknownCost = 0.45
            numerator += weight * (
                result.confidence * result.cost
                    + (1 - result.confidence) * unknownCost
            )
            denominator += weight
            measuredWeight += effectiveWeight
            worstConcern = max(worstConcern, result.cost * result.confidence * weight / maxWeight)
            if let explanation = result.explanation {
                all.append(PlanRationale.Contribution(
                    termId: term.id,
                    explanation: explanation,
                    weightedCost: effectiveWeight * result.cost
                ))
            }
        }

        let coverage = denominator > 0 ? measuredWeight / denominator : 0
        let mean = denominator > 0 ? 1 - numerator / denominator : 0
        let evidenceCeiling = 0.35 + 0.65 * coverage
        let capped = min(mean, 1 - worstConcern, evidenceCeiling)
        let score = vetoed != nil ? 0 : min(1, max(0, capped))

        let concerns = all.filter { $0.weightedCost > 0.02 }.sorted { $0.weightedCost > $1.weightedCost }
        let contributions = all.filter { $0.weightedCost <= 0.02 }.sorted { $0.weightedCost < $1.weightedCost }

        var caveats = Set(outgoing.provenance.caveats).union(incoming.provenance.caveats)
        if let vetoed { caveats.insert(vetoed) }

        let headline: String
        if let vetoed {
            headline = "No mix — \(vetoed)"
        } else {
            let where_ = "\(templateName) into \(incoming.displayName) at \(DJFormat.time(plan.exit.seconds))"
            if let move = plan.move {
                headline = move.headline(into: incoming.displayName, durationSeconds: move.kind == .jump ? plan.entry.seconds - plan.exit.seconds : nil)
                    + " at \(DJFormat.time(plan.exit.seconds))"
            } else if let staged = plan.stageSummary {
                headline = "\(where_) — \(staged)"
            } else if plan.overlapSeconds < 1 {
                headline = where_
            } else {
                headline = where_ + ", " + String(format: "%.0f", plan.overlapSeconds) + "s"
            }
        }

        let rationale = PlanRationale(
            templateName: templateName,
            headline: headline,
            contributions: contributions,
            concerns: concerns,
            provenanceCaveats: caveats.sorted(),
            score: score,
            evidenceCoverage: coverage,
            fires: score >= profile.minimumScoreToFire
        )
        return ScoredPlan(plan: plan, score: score, rationale: rationale)
    }

    static func vetoed(_ scored: ScoredPlan, reason: String, profile: DJProfile) -> ScoredPlan {
        let r = scored.rationale
        let rationale = PlanRationale(
            templateName: r.templateName,
            headline: "No mix — \(reason)",
            contributions: r.contributions,
            concerns: r.concerns,
            provenanceCaveats: r.provenanceCaveats + [reason],
            score: 0,
            evidenceCoverage: r.evidenceCoverage,
            fires: false
        )
        return ScoredPlan(plan: scored.plan, score: 0, rationale: rationale)
    }

    private static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}
