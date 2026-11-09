import Foundation

struct GenreCost: Equatable, Sendable {
    let cost: Double
    let reason: String

    static let zero = GenreCost(cost: 0, reason: "same genre")
}

struct TempoRelation: Equatable, Sendable {
    enum Fold: String, Sendable {
        case direct
        case doubleTime
        case halfTime
    }

    let fold: Fold
    let foldedBPM: Double
    let effectivePercent: Double
    let rawPercent: Double
    let cost: Double
    let reason: String
}

enum SetArc: String, Sendable, CaseIterable {
    case rising
    case holding
    case cooling
}

enum GenreDistanceModel {

    static let weightFourFour = 0.22
    static let weightEnergy = 0.16
    static let weightSwing = 0.14
    static let weightBrightness = 0.12
    static let weightMelodic = 0.10
    static let weightHalfTime = 0.10
    static let weightPercussive = 0.09
    static let weightVocal = 0.07

    static let genreForgiveness = 0.65
    static let maximumGenreAllowancePercent = 12.0
    static let maximumForgivenPercent = 6.0

    struct Pair: Hashable, Sendable {
        let low: String
        let high: String
        init(_ a: MusicGenre, _ b: MusicGenre) {
            if a.rawValue <= b.rawValue { low = a.rawValue; high = b.rawValue }
            else { low = b.rawValue; high = a.rawValue }
        }
    }

    struct Override: Sendable {
        let cost: Double
        let note: String
    }

    static let overrides: [Pair: Override] = {
        let raw: [(MusicGenre, MusicGenre, Double, String)] = [
            (.melodicTechno, .progressiveHouse, 0.14,
             "shared long-breakdown structure and overlapping tempo"),
            (.minimalTechno, .techHouse, 0.16,
             "the standard connective pairing"),
            (.techno, .techHouse, 0.20,
             "tech house is the bridge genre into techno"),
            (.disco, .nuDisco, 0.08, "same material, different decade"),
            (.deepHouse, .classicHouse, 0.12, "same lineage"),
            (.eurodance, .euroHouse, 0.10, "contested labels for the same wave"),
            (.eurodance, .italoDance, 0.12, "Italo dance grew out of eurodance"),
            (.handsUp, .hardstyle, 0.20, "shared reverse-bass and kick-distortion DNA"),
            (.ukGarage, .dubstep, 0.28, "dubstep grew out of garage"),
            (.ukGarage, .twoStep, 0.10, "2-step is a UKG variant"),
            (.ukGarage, .speedGarage, 0.14, "sibling garage styles"),
            (.drumAndBass, .jungle, 0.14, "jungle is DnB's direct precursor"),
            (.drumAndBass, .liquidDnB, 0.12, "liquid is a DnB subgenre"),
            (.drumAndBass, .neurofunk, 0.14, "neurofunk is a DnB subgenre"),
            (.dubstep, .grime, 0.22, "siblings at 140"),
            (.hardGroove, .techHouse, 0.18,
             "shared swing and groove focus, adjacent tempo"),

            (.hardTechno, .melodicTechno, 0.72, "industrial density buries the melody"),
            (.hardTechno, .techHouse, 0.75, "tempo gap too wide to bridge"),
            (.hardTechno, .progressiveHouse, 0.78, "no common ground"),
            (.schranz, .melodicTechno, 0.80, "opposite ends of techno"),
            (.schranz, .deepHouse, 0.92, "nothing in common"),
            (.hardGroove, .melodicTechno, 0.55, "dense percussion against patient pads"),
            (.hardGroove, .hardTechno, 0.42,
             "same word, different school — funk-rooted groove against industrial distortion"),
            (.progressiveHouse, .bigRoom, 0.55,
             "same tempo, opposite intent — patient build against instant drop"),
            (.nuDisco, .drumAndBass, 0.92, "no usable tempo relationship"),
            (.disco, .hardTechno, 0.95, "no usable tempo relationship"),
            (.disco, .schranz, 0.97, "no usable tempo relationship")
        ]
        var out: [Pair: Override] = [:]
        for (a, b, c, n) in raw { out[Pair(a, b)] = Override(cost: c, note: n) }
        return out
    }()

    static func distance(_ a: MusicGenre, _ b: MusicGenre) -> GenreCost {
        if a == b {
            return GenreCost(cost: 0, reason: "same genre (\(GenreProfile.of(a).displayName))")
        }

        let pa = GenreProfile.of(a)
        let pb = GenreProfile.of(b)
        let nameA = pa.displayName
        let nameB = pb.displayName

        if a == .unknown || b == .unknown {
            return GenreCost(
                cost: 0.30,
                reason: "genre unknown for one side — treated as neutral, not as a mismatch"
            )
        }

        if let override = overrides[Pair(a, b)] {
            return GenreCost(
                cost: override.cost,
                reason: "\(nameA) → \(nameB): \(override.note) (\(fmt(override.cost)))"
            )
        }

        let axis = axisDistance(pa, pb)
        let family = GenreFamilyGraph.distance(pa.family, pb.family)
        let total = min(1.0, axis + family)

        return GenreCost(cost: total, reason: describe(pa, pb, axis: axis, family: family, total: total))
    }

    static func axisDistance(_ pa: GenreProfile, _ pb: GenreProfile) -> Double {
        func sq(_ x: Double) -> Double { x * x }
        let total =
            weightFourFour * sq(pa.fourFourness - pb.fourFourness)
            + weightEnergy * sq(pa.energy - pb.energy)
            + weightSwing * sq(pa.swing - pb.swing)
            + weightBrightness * sq(pa.brightness - pb.brightness)
            + weightMelodic * sq(pa.melodicContent - pb.melodicContent)
            + weightHalfTime * sq(pa.halfTimeFeel - pb.halfTimeFeel)
            + weightPercussive * sq(pa.percussiveDensity - pb.percussiveDensity)
            + weightVocal * sq(pa.vocalPresence - pb.vocalPresence)
        return total.squareRoot()
    }

    static func mixCost(from a: MusicGenre, to b: MusicGenre, arc: SetArc = .rising) -> GenreCost {
        let base = distance(a, b)
        guard a != .unknown, b != .unknown, a != b else { return base }

        let energyDelta = GenreProfile.of(b).energy - GenreProfile.of(a).energy
        guard abs(energyDelta) > 0.001 else { return base }

        let adjustment: Double
        let note: String
        switch arc {
        case .rising:
            if energyDelta >= 0 {
                adjustment = -0.10 * energyDelta
                note = "lifts the room"
            } else {
                adjustment = 0.25 * -energyDelta
                note = "drops energy while the set is still building"
            }
        case .holding:
            adjustment = 0.06 * abs(energyDelta)
            note = energyDelta > 0 ? "pushes past the plateau" : "dips below the plateau"
        case .cooling:
            if energyDelta <= 0 {
                adjustment = -0.10 * -energyDelta
                note = "eases down, with the arc"
            } else {
                adjustment = 0.25 * energyDelta
                note = "pushes energy up during the come-down"
            }
        }

        let cost = clamp01(base.cost + adjustment)
        return GenreCost(cost: cost, reason: "\(base.reason); \(note) (\(fmt(cost)))")
    }

    static func tempoRelation(
        fromBPM: Double,
        toBPM: Double,
        from a: MusicGenre = .unknown,
        to b: MusicGenre = .unknown
    ) -> TempoRelation {
        guard fromBPM.isFinite, toBPM.isFinite, fromBPM > 20, toBPM > 20 else {
            return TempoRelation(
                fold: .direct, foldedBPM: toBPM, effectivePercent: 0, rawPercent: 0,
                cost: 0.30,
                reason: "no usable tempo for one side — tempo term neutral"
            )
        }

        let pa = GenreProfile.of(a)
        let pb = GenreProfile.of(b)
        let affinity = min(pa.halfTimeAffinity, pb.halfTimeAffinity)
        let foldSurcharge = 0.10 + 0.35 * (1 - affinity)

        struct Candidate { let fold: TempoRelation.Fold; let bpm: Double; let centre: Double; let surcharge: Double }
        let candidates: [Candidate] = [
            Candidate(fold: .direct, bpm: toBPM, centre: pb.bpmCenter, surcharge: 0),
            Candidate(fold: .doubleTime, bpm: toBPM * 2, centre: pb.bpmCenter * 2, surcharge: foldSurcharge),
            Candidate(fold: .halfTime, bpm: toBPM / 2, centre: pb.bpmCenter / 2, surcharge: foldSurcharge)
        ]

        var best: TempoRelation?
        for candidate in candidates {
            let rawPercent = abs(candidate.bpm - fromBPM) / fromBPM * 100

            let allowance = min(maximumGenreAllowancePercent,
                                abs(candidate.centre - pa.bpmCenter) / fromBPM * 100)
            let forgiven = min(rawPercent, min(genreForgiveness * allowance, maximumForgivenPercent))
            let effective = max(0, rawPercent - forgiven)

            let cost = clamp01(stretchCost(effective) + candidate.surcharge)
            if best == nil || cost < best?.cost ?? .infinity {
                best = TempoRelation(
                    fold: candidate.fold,
                    foldedBPM: candidate.bpm,
                    effectivePercent: effective,
                    rawPercent: rawPercent,
                    cost: cost,
                    reason: tempoReason(
                        fold: candidate.fold, fromBPM: fromBPM, toBPM: toBPM,
                        folded: candidate.bpm, effective: effective,
                        affinity: affinity, cost: cost, a: pa, b: pb
                    )
                )
            }
        }
        return best ?? TempoRelation(
            fold: .direct, foldedBPM: toBPM, effectivePercent: 0, rawPercent: 0,
            cost: 0.3, reason: "tempo term neutral"
        )
    }

    static func stretchCost(_ percent: Double) -> Double {
        let p = abs(percent)
        switch p {
        case ..<3:  return p / 3 * 0.05
        case ..<6:  return 0.05 + (p - 3) / 3 * 0.10
        case ..<10: return 0.15 + (p - 6) / 4 * 0.25
        default:    return min(1.0, 0.40 + (p - 10) / 10 * 0.60)
            }
    }

    private static func describe(
        _ pa: GenreProfile, _ pb: GenreProfile,
        axis: Double, family: Double, total: Double
    ) -> String {
        let a = pa.displayName
        let b = pb.displayName
        let contributions: [(String, Double)] = [
            ("rhythmic base", weightFourFour * pow(pa.fourFourness - pb.fourFourness, 2)),
            ("energy", weightEnergy * pow(pa.energy - pb.energy, 2)),
            ("swing", weightSwing * pow(pa.swing - pb.swing, 2)),
            ("mood", weightBrightness * pow(pa.brightness - pb.brightness, 2)),
            ("melodic content", weightMelodic * pow(pa.melodicContent - pb.melodicContent, 2)),
            ("half-time feel", weightHalfTime * pow(pa.halfTimeFeel - pb.halfTimeFeel, 2)),
            ("percussion density", weightPercussive * pow(pa.percussiveDensity - pb.percussiveDensity, 2)),
            ("vocals", weightVocal * pow(pa.vocalPresence - pb.vocalPresence, 2))
        ]
        let driver = contributions.max(by: { $0.1 < $1.1 })?.0 ?? "character"

        if total <= 0.20 {
            return "\(a) → \(b): close neighbours (\(fmt(total)))"
        }
        if pa.family == pb.family {
            return "\(a) → \(b): same scene, differs most in \(driver) (\(fmt(total)))"
        }
        if family >= 0.12 {
            return "\(a) → \(b): different scenes, differs most in \(driver) (\(fmt(total)))"
        }
        return "\(a) → \(b): adjacent scenes, differs most in \(driver) (\(fmt(total)))"
    }

    private static func tempoReason(
        fold: TempoRelation.Fold, fromBPM: Double, toBPM: Double, folded: Double,
        effective: Double, affinity: Double, cost: Double,
        a: GenreProfile, b: GenreProfile
    ) -> String {
        let from = bpmText(fromBPM)
        let to = bpmText(toBPM)
        switch fold {
        case .direct:
            if effective < 2 {
                return "\(from) → \(to) BPM: moves with the grain of \(a.displayName) → \(b.displayName) (\(fmt(cost)))"
            }
            return "\(from) → \(to) BPM: \(String(format: "%.1f", effective))% effective pitch move (\(fmt(cost)))"
        case .doubleTime, .halfTime:
            let quality = affinity >= 0.7 ? "both sides take the fold well"
                : affinity >= 0.4 ? "the fold is workable but not free"
                : "the groove does not survive folding cleanly"
            return "\(from) → \(to) BPM at half/double time (counts as \(bpmText(folded))): "
                + "\(quality) (\(fmt(cost)))"
        }
    }

    private static func bpmText(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}

enum GenreTransitionShape: String, Sendable, CaseIterable {
    case longBlend, bassSwap, filterRoll, breakdownDrop, echoOut, loopOut, quickCut, doubleDrop
}

enum PhraseDiscipline: String, Sendable {
    case strict32
    case strict16
    case loose
    case free
}

struct GenreTransitionHint: Sendable, Equatable {
    let phrasing: PhraseDiscipline
    let blendBars: ClosedRange<Int>
    let preferred: [GenreTransitionShape]
    let avoid: [GenreTransitionShape]
    let reason: String
}

extension GenreDistanceModel {

    static func transitionHint(from a: MusicGenre, to b: MusicGenre) -> GenreTransitionHint {
        let pa = GenreProfile.of(a)
        let pb = GenreProfile.of(b)

        let discipline = min(pa.phraseStrictness, pb.phraseStrictness)
        let phrasing: PhraseDiscipline
        switch discipline {
        case 0.85...: phrasing = .strict32
        case 0.60..<0.85: phrasing = .strict16
        case 0.35..<0.60: phrasing = .loose
        default: phrasing = .free
        }

        let breakdown = min(pa.breakdownLength, pb.breakdownLength)
        let energy = max(pa.energy, pb.energy)
        let blendBars: ClosedRange<Int>
        if energy >= 0.88 && breakdown <= 0.15 {
            blendBars = 8...16
        } else if breakdown >= 0.55 {
            blendBars = 32...64
        } else if breakdown >= 0.25 {
            blendBars = 16...32
        } else {
            blendBars = 16...32
        }

        var preferred: [GenreTransitionShape] = []
        var avoid: [GenreTransitionShape] = []
        var notes: [String] = []

        if pb.breakdownLength >= 0.55 {
            preferred.append(.breakdownDrop)
            notes.append("\(pb.displayName)'s long breakdown is the natural landing point")
        }

        if breakdown <= 0.25 && pa.fourFourness > 0.7 && pb.fourFourness > 0.7 {
            preferred.append(contentsOf: [.longBlend, .bassSwap])
            notes.append("rolling arrangements with little breakdown — blend through the groove")
        } else if pa.fourFourness > 0.7 && pb.fourFourness > 0.7 {
            preferred.append(.bassSwap)
        }

        if energy >= 0.88 && max(pa.percussiveDensity, pb.percussiveDensity) >= 0.5
            && max(pa.melodicContent, pb.melodicContent) <= 0.35 {
            preferred.append(.quickCut)
            avoid.append(.longBlend)
            notes.append("two dense, hot records — a long blend turns to mud")
        }

        if max(pa.percussiveDensity, pb.percussiveDensity) >= 0.85 && pa.fourFourness > 0.7 {
            preferred.append(.loopOut)
            notes.append("dense percussion rewards loop layering")
        }

        if discipline < 0.55 {
            preferred.append(contentsOf: [.echoOut, .quickCut])
            avoid.append(.longBlend)
            notes.append("song-structured arrangement — no long beatless outro to blend through")
        }

        if abs(pa.fourFourness - pb.fourFourness) >= 0.45 {
            preferred.append(contentsOf: [.filterRoll, .doubleDrop])
            avoid.append(.longBlend)
            notes.append("crossing between 4/4 and breakbeat — make it a moment, not a fade")
        }

        if min(pa.melodicContent, pb.melodicContent) >= 0.65 {
            preferred.append(.longBlend)
            notes.append("melodic on both sides — key match matters more than usual")
        }

        if preferred.isEmpty { preferred = [.longBlend, .bassSwap] }

        var seen = Set<String>()
        let dedupedAvoid = avoid.filter { seen.insert($0.rawValue).inserted }
        seen.removeAll()
        let dedupedPreferred = preferred
            .filter { seen.insert($0.rawValue).inserted }
            .filter { !dedupedAvoid.contains($0) }

        let reason = notes.isEmpty
            ? "\(phrasing.rawValue) phrasing, \(blendBars.lowerBound)–\(blendBars.upperBound) bar blend"
            : notes.joined(separator: "; ")

        return GenreTransitionHint(
            phrasing: phrasing,
            blendBars: blendBars,
            preferred: dedupedPreferred.isEmpty ? [.bassSwap] : dedupedPreferred,
            avoid: dedupedAvoid,
            reason: reason
        )
    }
}
