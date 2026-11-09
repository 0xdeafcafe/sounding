import Foundation

enum DJTerms {
    static var v1Registry: ScoringRegistry {
        ScoringRegistry([
            TempoTerm(), PhraseTerm(), StructureTerm(), HarmonicTerm(),
            EnergyTerm(), GenreTerm(), SpectralClashTerm(), GrooveTerm(),
            NoveltyTerm(), FeasibilityTerm()
        ])
    }
}

struct TempoTerm: ScoringTerm {
    let id = ScoringTermID.tempo

    func evaluate(_ ctx: ScoringContext) -> TermResult {
        guard let a = ctx.outgoing.beatGrid, let b = ctx.incoming.beatGrid,
              let relation = DJTempo.local(
                ctx.outgoing, exit: ctx.plan.exit.seconds, overlap: ctx.plan.overlapSeconds,
                ctx.incoming, entry: ctx.plan.entry.seconds
              ) ?? DJTempo.best(outgoing: a, incoming: b) else {
            return .unmeasured("no measured tempo on one side — only a conservative transition is allowed")
        }

        let profile = ctx.profile
        let kappa = min(a.confidence, b.confidence)

        let applied = ctx.plan.incomingRateRatio
        let leftover = DJTempo.leftover(relation, appliedRate: applied)
        let driftMs = DJTempo.driftMs(leftover: leftover, overlapSeconds: ctx.plan.overlapSeconds)
            + DJTempo.curvatureDriftMs(a, from: ctx.plan.exit.seconds, seconds: ctx.plan.overlapSeconds)
            + DJTempo.curvatureDriftMs(b, from: ctx.plan.entry.seconds, seconds: ctx.plan.overlapSeconds * applied)
        let correction = abs(applied - 1)

        let fromBPM = DJFormat.bpm((a.bpm * 10).rounded() / 10)
        let toBPM = DJFormat.bpm((b.bpm * 10).rounded() / 10)

        if driftMs > profile.maxDriftMs {
            let required = DJFormat.signedPercent((relation.requiredRate - 1) * 100)
            let allowed = DJFormat.percent(profile.maxAbsRatePercent, decimals: 1)
            return TermResult(
                cost: 1, confidence: kappa, veto: false,
                explanation: "\(fromBPM) → \(toBPM) BPM needs \(required) and \(profile.displayName) "
                    + "allows ±\(allowed), which would drift \(Int(driftMs.rounded())) ms over the blend"
            )
        }

        let stretchCost = pow(correction / 0.10, 1.8)
        let driftCost = profile.maxDriftMs > 0 ? driftMs / profile.maxDriftMs * 0.25 : 0
        let cost = min(1, relation.baseCost + stretchCost + driftCost)

        let move = correction < 0.0005
            ? "no pitch move"
            : "\(DJFormat.signedPercent((applied - 1) * 100)), key-locked"
        let foldNote: String
        switch relation.factor {
        case 2.0:  foldNote = " at double time — the grids coincide exactly"
        case 0.5:  foldNote = " at half time — the grids coincide exactly"
        case 1.0:  foldNote = ""
        default:   foldNote = " on a \(relation.label) relation"
        }
        return TermResult(
            cost: cost, confidence: kappa, veto: false,
            explanation: "\(fromBPM) → \(toBPM) BPM (\(move))\(foldNote)"
        )
    }
}

struct PhraseTerm: ScoringTerm {
    let id = ScoringTermID.phrase

    func evaluate(_ ctx: ScoringContext) -> TermResult {
        guard let a = ctx.outgoing.beatGrid, let b = ctx.incoming.beatGrid else {
            return .unmeasured("no beat grid — phrase alignment not checked")
        }

        let downbeatsKnown = ctx.outgoing.provenance.contains(.measuredDownbeats)
            && ctx.incoming.provenance.contains(.measuredDownbeats)

        let offsets = DJMixRules.phraseOffsets(
            exitBeats: ctx.outgoing.beatsFromPhraseBoundary(at: ctx.plan.exit.seconds),
            entryBeats: ctx.incoming.beatsFromPhraseBoundary(at: ctx.plan.entry.seconds)
        )
        let mod4 = offsets.bar
        let mod32 = offsets.phrase

        let mod4Cost = min(1, mod4 / 2.0)
        let mod32Cost = min(1, mod32 / 16.0)
        let cost = min(1, (3 * mod4Cost + mod32Cost) / 4)

        let kappa = downbeatsKnown ? min(a.confidence, b.confidence) * 0.9 : 0.3

        let explanation: String
        if mod4 < DJMixRules.phraseBeatTolerance && mod32 < DJMixRules.phraseBarTolerance {
            explanation = "both sides on phrase boundaries"
        } else if mod4 >= 0.5 {
            explanation = String(format: "%.1f beats off the bar — the backbeat would invert", mod4)
        } else {
            explanation = String(format: "%.0f bars off the phrase", mod32 / 4)
        }
        return TermResult(cost: cost, confidence: kappa, veto: false, explanation: explanation)
    }
}

struct StructureTerm: ScoringTerm {
    let id = ScoringTermID.structure

    static func cost(exit: SectionKind, entry: SectionKind, templateId: TransitionTemplateID) -> Double {
        switch (exit, entry) {
        case (.outro, .intro), (.ambientOutro, .intro), (.outro, .ambientIntro):
            return 0.0
        case (.breakdown, .intro), (.cooldown, .intro), (.breakdown, .buildup):
            return 0.10
        case (.outro, .buildup), (.ambientOutro, .ambientIntro):
            return 0.12
        case (.breakdown, .drop), (.buildup, .drop):
            return 0.20
        case (.drop, .drop):
            return templateId == "doubleDrop" ? 0.0 : 0.90
        case (.drop, .ambientIntro), (.drop, .intro):
            return 0.80
        case (.unknown, _), (_, .unknown):
            return 0.35
        default:
            return 0.35
        }
    }

    static func moveCost(_ move: MixMove, exit: SectionKind, entry: SectionKind, base: Double) -> Double {
        let lifts = entry == .drop
        switch move.kind {
        case .dropOnTheOne, .loopRoll, .fxBuild:
            if lifts { return exit == .ambientOutro || exit == .ambientIntro ? 0.25 : 0.05 }
            return entry == .intro || entry == .buildup || entry == .build ? 0.2 : max(0.3, base)
        case .dropIn:
            return entry == .buildup || entry == .build ? 0.05 : max(0.3, base)
        case .breakdownExit:
            return exit == .breakdown || exit == .cooldown ? (lifts ? 0.15 : 0.05) : max(0.3, base)
        case .echoOut, .cut:
            return min(base, 0.3)
        case .jump:
            return 0.1
        case .blend, .tempoRamp, .bridge, .loopMix:
            return base
        }
    }

    static func blendExit(_ ctx: ScoringContext) -> SectionKind {
        let exit = ctx.plan.exit.kind
        let kind = ctx.plan.move?.kind
        guard kind == nil || kind == .blend || kind == .loopMix, ctx.plan.overlapSeconds > 0,
              exit != .outro, exit != .ambientOutro, exit != .drop, exit != .buildup, exit != .build else { return exit }
        let start = ctx.plan.exit.seconds
        let end = start + ctx.plan.overlapSeconds
        return ctx.outgoing.sections.first { ($0.kind == .outro || $0.kind == .ambientOutro) && $0.start > start && $0.start < end }?.kind ?? exit
    }

    func evaluate(_ ctx: ScoringContext) -> TermResult {
        let exit = Self.blendExit(ctx)
        let entry = ctx.plan.entry.kind
        let measured = ctx.outgoing.provenance.contains(.measuredStructure)
            && ctx.incoming.provenance.contains(.measuredStructure)

        let base = Self.cost(exit: exit, entry: entry, templateId: ctx.plan.templateId)
        let cost = ctx.plan.move.map { Self.moveCost($0, exit: exit, entry: entry, base: base) } ?? base
        let kappa = measured ? 0.9 : (exit == .unknown && entry == .unknown ? 0 : 0.45)

        return TermResult(
            cost: cost, confidence: kappa, veto: false,
            explanation: "\(exit.displayName) into \(entry.displayName)"
        )
    }
}

struct HarmonicTerm: ScoringTerm {
    let id = ScoringTermID.harmonic

    static let evidenceDiscount = 0.45

    func evaluate(_ ctx: ScoringContext) -> TermResult {
        guard let from = ctx.outgoing.key(at: ctx.plan.exit.seconds),
              let to = ctx.incoming.key(at: ctx.plan.entry.seconds) else {
            return .unmeasured("no key on one side — harmonic compatibility is unknown")
        }

        let steps = from.wheelSteps(to: to)
        let sameMode = from.mode == to.mode
        let profile = ctx.profile
        if steps > 0 || !sameMode {
            let map = DJSourceMap(DJPlanShape(ctx.plan), outgoing: ctx.outgoing, incoming: ctx.incoming)
            if DJMixRules.percussiveOnly(ctx.outgoing, sourceRanges: map.outgoingOverlapRanges) == true
                || DJMixRules.percussiveOnly(ctx.incoming, sourceRanges: map.incomingOverlapRanges) == true {
                return TermResult(cost: 0, confidence: Self.evidenceDiscount, veto: false,
                                  explanation: "\(from.label) → \(to.label), one side is only drums in the overlap")
            }
        }

        let cost: Double
        let note: String
        switch (steps, sameMode) {
        case (0, true):
            cost = 0.00; note = "same key"
        case (0, false):
            cost = 0.15; note = "relative \(to.isMinor ? "minor" : "major")"
        case (1, true):
            cost = 0.12; note = "one step round the wheel"
        case (2, true) where profile.allowEnergyBoost:
            cost = 0.25; note = "a two-step energy boost"
        case (2, true):
            cost = 0.85; note = "two steps round the wheel, past \(profile.displayName)'s limit"
        default:
            cost = 0.85
            note = "\(steps) steps round the wheel\(sameMode ? "" : " with a mode change")"
        }

        let overLimit = steps > profile.maxCamelotSteps
        let finalCost = overLimit ? max(cost, 0.85) : cost

        return TermResult(
            cost: finalCost,
            confidence: Self.evidenceDiscount,
            veto: false,
            explanation: "\(from.label) → \(to.label), \(note)"
        )
    }
}

struct EnergyTerm: ScoringTerm {
    let id = ScoringTermID.energy

    static func level(from features: TrackFeatures) -> (level: Int, measured: Bool)? {
        if let level = features.energyLevel { return (level, true) }
        guard !features.envelope.isEmpty else { return nil }
        let sorted = features.envelope.sorted()
        let p95 = Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
        return (min(10, max(1, Int((p95 * 11).rounded()))), false)
    }

    func evaluate(_ ctx: ScoringContext) -> TermResult {
        guard let a = Self.level(from: ctx.outgoing), let b = Self.level(from: ctx.incoming) else {
            return .unmeasured("no energy reading on one side")
        }
        let step = b.level - a.level
        let magnitude = abs(step)
        let limit = ctx.profile.energyStepLimit

        let cost: Double
        if magnitude <= limit {
            cost = 0.0
        } else if magnitude == limit + 1 {
            cost = 0.45
        } else {
            cost = 0.9
        }

        let kappa = (a.measured ? 1.0 : 0.45) * (b.measured ? 1.0 : 0.45)

        let direction = step == 0 ? "holds" : (step > 0 ? "lifts" : "drops")
        return TermResult(
            cost: cost, confidence: kappa, veto: false,
            explanation: magnitude == 0
                ? "energy \(a.level) → \(b.level), \(direction) the room"
                : "energy \(a.level) → \(b.level), \(direction) \(magnitude) step\(magnitude == 1 ? "" : "s")"
        )
    }
}

struct GenreTerm: ScoringTerm {
    let id = ScoringTermID.genre

    func evaluate(_ ctx: ScoringContext) -> TermResult {
        guard let a = ctx.outgoing.genre, let b = ctx.incoming.genre else {
            return .unmeasured("no genre on one side — stylistic distance is unknown")
        }
        let result = GenreScoringTerm.evaluate(from: a, to: b, arc: ctx.history.arc)
        let overCeiling = result.cost > ctx.profile.genreCeiling
        return TermResult(
            cost: overCeiling ? 1 : result.cost,
            confidence: result.confidence,
            veto: false,
            explanation: overCeiling
                ? "\(result.reason); beyond \(ctx.profile.displayName)'s genre limit"
                : result.reason
        )
    }
}

struct SpectralClashTerm: ScoringTerm {
    let id = ScoringTermID.spectralClash

    func evaluate(_ ctx: ScoringContext) -> TermResult {
        let vocals = vocalClash(ctx)
        let bass = bassClash(ctx)
        guard vocals != nil || bass != nil else { return .unmeasured(nil) }
        let parts = [vocals, bass].compactMap { $0 }
        return TermResult(
            cost: parts.map(\.cost).max() ?? 0,
            confidence: 0.85,
            veto: false,
            explanation: parts.map(\.note).joined(separator: "; ")
        )
    }

    private func vocalClash(_ ctx: ScoringContext) -> (cost: Double, note: String)? {
        guard ctx.outgoing.provenance.contains(.measuredVocals),
              ctx.incoming.provenance.contains(.measuredVocals) else {
            return nil
        }

        let map = DJSourceMap(DJPlanShape(ctx.plan), outgoing: ctx.outgoing, incoming: ctx.incoming)
        let beat = ctx.outgoing.beatGrid?.beatPeriod ?? 0.5
        let overlapping = DJPlanValidator.vocalOverlapSeconds(map, outgoing: ctx.outgoing, incoming: ctx.incoming, step: beat / 2, shape: DJPlanShape(ctx.plan))

        let barSeconds = ctx.outgoing.beatGrid?.barDuration ?? 2.0
        let bars = overlapping / max(0.1, barSeconds)

        if bars < 0.25 { return (0.0, "no vocal overlap") }
        if bars <= 1.0 { return (0.2, "about a bar of vocal overlap") }
        return (0.9, String(format: "%.0f bars of vocal overlap", bars))
    }

    private func bassClash(_ ctx: ScoringContext) -> (cost: Double, note: String)? {
        guard ctx.outgoing.provenance.contains(.measuredStems),
              ctx.incoming.provenance.contains(.measuredStems) else {
            return nil
        }
        let barSeconds = max(0.1, ctx.outgoing.beatGrid?.barDuration ?? 2.0)
        let swapOut = ctx.plan.exit.seconds + ctx.plan.bassSwapAtSeconds
        let swapIn = ctx.plan.entry.seconds + ctx.plan.bassSwapAtSeconds * ctx.plan.incomingRateRatio
        let doubled = DJMixRules.vocalOverlapSeconds(
            outgoing: ctx.outgoing.bassRanges, from: swapOut, length: max(ctx.plan.bassSwapSeconds, 0),
            incoming: ctx.incoming.bassRanges, entry: swapIn
        ) / barSeconds
        if doubled > 1 {
            return (0.6, String(format: "%.0f bars of double bass at the swap", doubled))
        }
        let outgoingHadBass = ctx.outgoing.bassRanges.contains { $0.overlaps((swapOut - barSeconds)...swapOut) }
        let incomingHasBass = ctx.incoming.bassRanges.contains { $0.overlaps(swapIn...(swapIn + barSeconds)) }
        if outgoingHadBass, !incomingHasBass {
            return (0.3, "the bass drops out at the swap")
        }
        return (0.0, "bass swap lands on the incoming bass")
    }
}

struct GrooveTerm: ScoringTerm {
    let id = ScoringTermID.groove

    func evaluate(_ ctx: ScoringContext) -> TermResult {
        guard let a = ctx.outgoing.swingRatio, let b = ctx.incoming.swingRatio,
              let grid = ctx.outgoing.beatGrid else {
            return .unmeasured(nil)
        }
        let eighthMs = grid.beatPeriod / 2 * 1000
        let displacement = abs(a - b) * eighthMs
        let cost = min(1, displacement / 10)
        return TermResult(
            cost: cost, confidence: 0.6, veto: false,
            explanation: String(format: "swing differs by %.1f ms on the offbeat", displacement)
        )
    }
}

struct NoveltyTerm: ScoringTerm {
    let id = ScoringTermID.novelty

    func evaluate(_ ctx: ScoringContext) -> TermResult {
        var cost = 0.0
        var notes: [String] = []

        let cooldown = max(0, ctx.profile.repeatTemplateCooldown)
        if let index = ctx.history.recentTemplates.firstIndex(of: ctx.plan.templateId),
           index < cooldown {
            cost += 0.6 * (1 - Double(index) / Double(max(1, cooldown)))
            notes.append("same move as \(index == 0 ? "the last transition" : "\(index + 1) transitions ago")")
        }

        let artist = ctx.incoming.artist
        if !artist.isEmpty, let index = ctx.history.recentArtists.firstIndex(of: artist), index < 3 {
            cost += 0.4
            notes.append("\(artist) played \(index + 1) track\(index == 0 ? "" : "s") ago")
        }

        return TermResult(
            cost: min(1, cost), confidence: 1.0, veto: false,
            explanation: notes.isEmpty ? "fresh move and fresh artist" : notes.joined(separator: ", ")
        )
    }
}

struct FeasibilityTerm: ScoringTerm {
    let id = ScoringTermID.feasibility

    func evaluate(_ ctx: ScoringContext) -> TermResult {
        let plan = ctx.plan
        let profile = ctx.profile
        let outgoing = ctx.outgoing

        let available = outgoing.duration - plan.exit.seconds
        if plan.overlapSeconds > available + 0.01 {
            return TermResult(
                cost: 1, confidence: 1, veto: true,
                explanation: "\(Int(plan.overlapSeconds))s blend needs \(Int(plan.overlapSeconds))s "
                    + "of runway and only \(max(0, Int(available)))s remain after \(DJFormat.time(plan.exit.seconds))"
            )
        }

        let playedFraction = outgoing.duration > 0 ? plan.mixEndSeconds / outgoing.duration : 0
        if playedFraction < profile.minimumPlayFraction - 0.001 {
            return TermResult(
                cost: 1, confidence: 1, veto: true,
                explanation: "\(profile.displayName) plays at least "
                    + "\(Int(profile.minimumPlayFraction * 100))% of a track and this would be done with it at "
                    + "\(Int(playedFraction * 100))%"
            )
        }

        if plan.outgoingTrackId == plan.incomingTrackId {
            return TermResult(
                cost: 1, confidence: 1, veto: true,
                explanation: "a track cannot mix into itself"
            )
        }

        if plan.entry.seconds >= ctx.incoming.duration {
            return TermResult(
                cost: 1, confidence: 1, veto: true,
                explanation: "entry point is past the end of \(ctx.incoming.displayName)"
            )
        }

        let margin = available - plan.overlapSeconds
        let cost = margin >= 4 ? 0 : min(0.5, (4 - margin) / 8)
        return TermResult(
            cost: cost, confidence: 1, veto: false,
            explanation: cost > 0
                ? String(format: "only %.1fs of slack after the blend", max(0, margin))
                : "fits with \(Int(margin))s to spare"
        )
    }
}
