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
              let relation = DJTempo.best(outgoing: a, incoming: b) else {
            return .unmeasured("no measured tempo on one side — only a conservative transition is allowed")
        }

        let profile = ctx.profile
        let kappa = min(a.confidence, b.confidence)

        let applied = ctx.plan.incomingRateRatio
        let leftover = DJTempo.leftover(relation, appliedRate: applied)
        let driftMs = DJTempo.driftMs(leftover: leftover, overlapSeconds: ctx.plan.overlapSeconds)
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

        let exitOffset = abs(ctx.outgoing.beatsFromPhraseBoundary(at: ctx.plan.exit.seconds))
        let entryOffset = abs(ctx.incoming.beatsFromPhraseBoundary(at: ctx.plan.entry.seconds))

        func fold(_ beats: Double, modulo m: Double) -> Double {
            let r = beats.truncatingRemainder(dividingBy: m)
            return min(abs(r), m - abs(r))
        }

        let mod4 = (fold(exitOffset, modulo: 4) + fold(entryOffset, modulo: 4)) / 2
        let mod32 = (fold(exitOffset, modulo: 32) + fold(entryOffset, modulo: 32)) / 2

        let mod4Cost = min(1, mod4 / 2.0)
        let mod32Cost = min(1, mod32 / 16.0)
        let cost = min(1, (3 * mod4Cost + mod32Cost) / 4)

        let kappa = downbeatsKnown ? min(a.confidence, b.confidence) * 0.9 : 0.3

        let explanation: String
        if mod4 < 0.15 && mod32 < 0.5 {
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

    func evaluate(_ ctx: ScoringContext) -> TermResult {
        let exit = ctx.plan.exit.kind
        let entry = ctx.plan.entry.kind
        let measured = ctx.outgoing.provenance.contains(.measuredStructure)
            && ctx.incoming.provenance.contains(.measuredStructure)

        let cost = Self.cost(exit: exit, entry: entry, templateId: ctx.plan.templateId)
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
        guard ctx.outgoing.provenance.contains(.measuredVocals),
              ctx.incoming.provenance.contains(.measuredVocals) else {
            return .unmeasured(nil)
        }

        let start = ctx.plan.exit.seconds
        let end = start + ctx.plan.overlapSeconds
        let entryStart = ctx.plan.entry.seconds

        var overlapping = 0.0
        for outRange in ctx.outgoing.vocalRanges {
            let oLo = max(outRange.lowerBound, start)
            let oHi = min(outRange.upperBound, end)
            guard oHi > oLo else { continue }
            for inRange in ctx.incoming.vocalRanges {
                let iLo = inRange.lowerBound - entryStart + start
                let iHi = inRange.upperBound - entryStart + start
                overlapping += max(0, min(oHi, iHi) - max(oLo, iLo))
            }
        }

        let barSeconds = ctx.outgoing.beatGrid?.barDuration ?? 2.0
        let bars = overlapping / max(0.1, barSeconds)

        let cost: Double
        let note: String
        if bars < 0.25 {
            cost = 0.0; note = "no vocal overlap"
        } else if bars <= 1.0 {
            cost = 0.2; note = "about a bar of vocal overlap"
        } else {
            cost = 0.9
            note = String(format: "%.0f bars of vocal overlap", bars)
        }
        return TermResult(cost: cost, confidence: 0.85, veto: false, explanation: note)
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
