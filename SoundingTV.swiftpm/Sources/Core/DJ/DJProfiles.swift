import Foundation
import SwiftUI

struct DJModeGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    guideSection(
                        "Run modes",
                        icon: "switch.2",
                        rows: [
                            ("Auto Mix", "Keeps the next deck loaded, scores track, entry, exit and technique together, then plays the safest plan at the phrase it picked. Mix Now runs the current plan straight away."),
                            ("Manual Decks", "Stops the automatic moves and leaves the mixer up. Play, fader, EQ, filter, tempo, Sync, loops and cue pads are all yours."),
                            ("Decks Off", "Back to ordinary one-track playback. Use it when you don't need a second deck warmed up or any DJ processing.")
                        ]
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Auto Mix personalities", systemImage: "wand.and.stars")
                            .font(.headline)
                        ForEach(DJProfile.all) { profile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.displayName).font(.subheadline.weight(.bold))
                                Text(profile.blurb).foregroundStyle(.secondary)
                                Text(profileFacts(profile))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    guideSection(
                        "What each control does",
                        icon: "slider.horizontal.3",
                        rows: [
                            ("Waveform / track bar", "Tap or drag to move playback. It never creates or replaces a cue point."),
                            ("Cue pads", "Tap an occupied pad to jump. Hold an empty pad to save the current moment. Saving a cue is always deliberate."),
                            ("Sync", "Matches tempo and phase when the measured beat grids are trustworthy. Unknown stays unknown. It won't invent a BPM."),
                            ("Jog / platter", "Nudges the timing for a moment. It's for fixing phase, not for setting a permanent cue."),
                            ("Loop", "Loops on the render thread, quantised to the beat grid when there is one."),
                            ("Mix Now", "Runs the prepared plan where it can. If the next deck can't be made ready, it tells you and makes a short clean cut.")
                        ]
                    )

                    guideSection(
                        "Safety nets and background work",
                        icon: "checkmark.shield",
                        rows: [
                            ("Honest fallback", "No measured grid means no claimed beat-match. Vocals, genre, headroom or a half-prepared deck can each veto a blend and take the clean cut instead."),
                            ("Mac first", "The Mac does the heavy analysis pass. Apple TV does a smaller one while it's plugged in. Probe history and results sync, so devices carry on rather than redo the work."),
                            ("Collection rules", "Likes and playlists can override personality, queue order, set handling, vocal overlap, transition length, downloads and analysis policy.")
                        ]
                    )
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("How Decks Works")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func guideSection(
        _ title: String,
        icon: String,
        rows: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.0).font(.subheadline.weight(.semibold))
                    Text(row.1).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func profileFacts(_ profile: DJProfile) -> String {
        let order = profile.mayReorderQueue ? "may reorder" : "keeps order"
        let exit = Int((profile.minimumPlayFraction * 100).rounded())
        return "\(order) · plays at least \(exit)% · tempo ±\(profile.maxAbsRatePercent.formatted())%"
    }
}

extension DJProfile {

    static let automaticDJ = DJProfile(
        id: .automatic,
        displayName: "Auto Mix",
        blurb: "Plays the queue in order and mixes each track out of its outro with a long, phrase-aligned blend.",

        exitRegionFloor: 0.45,
        allowMidTrackExit: false,
        entryRegionCeiling: 0.35,
        minimumPlayFraction: 0.55,

        admissibleTemplates: [
            DJMoveIDs.blend, DJTemplates.filterFadeOut,
            DJTemplates.filterBloomIn, DJTemplates.highPassThinOut,
            DJTemplates.cutOnTheOne,
            DJTemplates.halfTimeBlend,
            DJMoveIDs.echoOut, DJMoveIDs.breakdownExit, DJMoveIDs.dropIn,
            DJMoveIDs.dropOnTheOne, DJMoveIDs.filterBuild, DJMoveIDs.echoBuild,
            DJMoveIDs.loopMix
        ],
        repeatTemplateCooldown: 2,

        maxAbsRatePercent: 3.0,
        allowVarispeed: false,
        requireMeasuredBPMForRate: true,
        maxDriftMs: 15,
        minGridConfidence: 0.65,

        maxCamelotSteps: 1,
        allowEnergyBoost: true,
        genreCeiling: 0.65,

        mayReorderQueue: false,
        lookaheadCandidates: 1,
        analysisBudgetPerTrack: 2,

        maxLoopBars: 8,
        maxLoopHalvings: 1,

        weights: [
            .feasibility: 1.00,
            .phrase: 0.95,
            .structure: 0.90,
            .tempo: 0.85,
            .spectralClash: 0.85,
            .energy: 0.65,
            .genre: 0.55,
            .harmonic: 0.40,
            .groove: 0.30,
            .novelty: 0.25
        ],
        minimumScoreToFire: 0.55,
        transitionBarsRange: 8...32,
        energyStepLimit: 2,
        timbreTargetDistance: 0.24,
        honoursUserTransitionLength: false
    )

    static let weddingDJ = DJProfile(
        id: .wedding,
        displayName: "Wedding DJ",
        blurb: "Plays the queue in order and mixes out of the outro. Cuts cleanly rather than chancing it.",

        exitRegionFloor: 0.72,
        allowMidTrackExit: false,
        entryRegionCeiling: 0.20,
        minimumPlayFraction: 0.85,

        admissibleTemplates: [
            DJMoveIDs.blend, DJTemplates.filterFadeOut,
            DJTemplates.filterBloomIn, DJTemplates.highPassThinOut,
            DJTemplates.cutOnTheOne,
            DJTemplates.halfTimeBlend,
            DJMoveIDs.echoOut, DJMoveIDs.loopMix
        ],
        repeatTemplateCooldown: 2,

        maxAbsRatePercent: 2.0,
        allowVarispeed: false,
        requireMeasuredBPMForRate: true,
        maxDriftMs: 10,
        minGridConfidence: 0.75,

        maxCamelotSteps: 1,
        allowEnergyBoost: false,
        genreCeiling: 0.55,

        mayReorderQueue: false,
        lookaheadCandidates: 1,
        analysisBudgetPerTrack: 1,

        maxLoopBars: 8,
        maxLoopHalvings: 1,

        weights: [
            .feasibility: 1.00,
            .phrase: 0.95,
            .tempo: 0.90,
            .spectralClash: 0.85,
            .structure: 0.70,
            .genre: 0.65,
            .energy: 0.55,
            .harmonic: 0.35,
            .groove: 0.30,
            .novelty: 0.20
        ],
        minimumScoreToFire: 0.62,
        transitionBarsRange: 8...32,
        energyStepLimit: 1,
        timbreTargetDistance: 0.18,
        honoursUserTransitionLength: true
    )

    static let junkie = DJProfile(
        id: .junkie,
        displayName: "Junkie",
        blurb: "Cuts tracks short and goes wherever the phrase boundaries let it.",

        exitRegionFloor: 0.25,
        allowMidTrackExit: true,
        entryRegionCeiling: 0.55,
        minimumPlayFraction: 0.35,

        admissibleTemplates: [
            DJMoveIDs.blend, DJTemplates.filterFadeOut,
            DJTemplates.filterBloomIn, DJTemplates.highPassThinOut,
            DJTemplates.cutOnTheOne,
            DJTemplates.halfTimeBlend,
            DJTemplates.echoOut,
            DJTemplates.doubleDrop,
            DJMoveIDs.echoOut, DJMoveIDs.breakdownExit, DJMoveIDs.dropIn,
            DJMoveIDs.dropOnTheOne, DJMoveIDs.filterBuild, DJMoveIDs.echoBuild,
            DJMoveIDs.reverbWash, DJMoveIDs.loopRoll, DJMoveIDs.tempoRamp, DJMoveIDs.bridge,
            DJMoveIDs.loopMix
        ],
        repeatTemplateCooldown: 3,

        maxAbsRatePercent: 6.0,
        allowVarispeed: true,
        requireMeasuredBPMForRate: true,
        maxDriftMs: 25,
        minGridConfidence: 0.55,

        maxCamelotSteps: 2,
        allowEnergyBoost: true,
        genreCeiling: 0.85,

        mayReorderQueue: true,
        lookaheadCandidates: 12,
        analysisBudgetPerTrack: 3,

        maxLoopBars: 32,
        maxLoopHalvings: 4,

        weights: [
            .feasibility: 1.00,
            .phrase: 0.85,
            .structure: 0.90,
            .energy: 0.75,
            .tempo: 0.70,
            .spectralClash: 0.60,
            .novelty: 0.55,
            .harmonic: 0.50,
            .groove: 0.45,
            .genre: 0.40
        ],
        minimumScoreToFire: 0.45,
        transitionBarsRange: 4...64,
        energyStepLimit: 2,
        timbreTargetDistance: 0.32,
        honoursUserTransitionLength: false
    )

    static let all: [DJProfile] = [.automaticDJ, .weddingDJ, .junkie]

    static func profile(id: DJProfileID) -> DJProfile? { all.first { $0.id == id } }

    func applying(queueOrder order: DJQueueOrderPolicy) -> DJProfile {
        let mayReorder: Bool
        switch order {
        case .profileDefault: mayReorder = mayReorderQueue
        case .preserve, .random: mayReorder = false
        case .mayReorder: mayReorder = true
        }

        return DJProfile(
            id: id, displayName: displayName, blurb: blurb,
            exitRegionFloor: exitRegionFloor, allowMidTrackExit: allowMidTrackExit,
            entryRegionCeiling: entryRegionCeiling,
            minimumPlayFraction: minimumPlayFraction,
            admissibleTemplates: admissibleTemplates, repeatTemplateCooldown: repeatTemplateCooldown,
            maxAbsRatePercent: maxAbsRatePercent, allowVarispeed: allowVarispeed,
            requireMeasuredBPMForRate: requireMeasuredBPMForRate, maxDriftMs: maxDriftMs,
            minGridConfidence: minGridConfidence, maxCamelotSteps: maxCamelotSteps,
            allowEnergyBoost: allowEnergyBoost, genreCeiling: genreCeiling,
            mayReorderQueue: mayReorder,
            lookaheadCandidates: mayReorder ? max(lookaheadCandidates, 12) : 1,
            analysisBudgetPerTrack: analysisBudgetPerTrack, maxLoopBars: maxLoopBars,
            maxLoopHalvings: maxLoopHalvings, weights: weights,
            minimumScoreToFire: minimumScoreToFire, transitionBarsRange: transitionBarsRange,
            energyStepLimit: energyStepLimit, timbreTargetDistance: timbreTargetDistance,
            honoursUserTransitionLength: honoursUserTransitionLength,
            blendTargetBars: blendTargetBars
        )
    }

    var styleName: String {
        switch id {
        case .wedding: return "Smooth"
        case .automatic: return "Club"
        case .junkie: return "Adventurous"
        default: return displayName
        }
    }

    func referenceBars(outgoing: TrackFeatures?, incoming: TrackFeatures?) -> Int {
        let target = blendTargetBars ?? DJBlendTarget.bars(outgoing: outgoing, incoming: incoming)
        return max(transitionBarsRange.lowerBound, min(transitionBarsRange.upperBound, target))
    }

    func applying(blend: DJBlendLength) -> DJProfile {
        let upper: Int
        var target: Int?
        switch blend {
        case .short:
            upper = max(transitionBarsRange.lowerBound, min(transitionBarsRange.upperBound, DJBlendTarget.shortBars))
            target = DJBlendTarget.shortBars
        case .normal:
            upper = max(transitionBarsRange.upperBound, DJBlendTarget.autoMaximumBars)
        case .long:
            upper = max(transitionBarsRange.upperBound, DJBlendTarget.longBars)
            target = DJBlendTarget.longBars
        }
        var profile = DJProfile(
            id: id, displayName: displayName, blurb: blurb,
            exitRegionFloor: exitRegionFloor, allowMidTrackExit: allowMidTrackExit,
            entryRegionCeiling: entryRegionCeiling,
            minimumPlayFraction: minimumPlayFraction,
            admissibleTemplates: admissibleTemplates, repeatTemplateCooldown: repeatTemplateCooldown,
            maxAbsRatePercent: maxAbsRatePercent, allowVarispeed: allowVarispeed,
            requireMeasuredBPMForRate: requireMeasuredBPMForRate, maxDriftMs: maxDriftMs,
            minGridConfidence: minGridConfidence, maxCamelotSteps: maxCamelotSteps,
            allowEnergyBoost: allowEnergyBoost, genreCeiling: genreCeiling,
            mayReorderQueue: mayReorderQueue,
            lookaheadCandidates: lookaheadCandidates,
            analysisBudgetPerTrack: analysisBudgetPerTrack, maxLoopBars: maxLoopBars,
            maxLoopHalvings: maxLoopHalvings, weights: weights,
            minimumScoreToFire: minimumScoreToFire,
            transitionBarsRange: transitionBarsRange.lowerBound...upper,
            energyStepLimit: energyStepLimit, timbreTargetDistance: timbreTargetDistance,
            honoursUserTransitionLength: honoursUserTransitionLength
        )
        profile.blendTargetBars = target
        return profile
    }

    func applying(collectionPolicy policy: CollectionPolicy) -> DJProfile {
        var adjustedWeights = weights
        if policy.avoidVocalOverlap {
            adjustedWeights[.spectralClash] = max(1.25, adjustedWeights[.spectralClash] ?? 0)
        }

        let mayReorder: Bool
        switch policy.queueOrder {
        case .profileDefault: mayReorder = mayReorderQueue
        case .preserve:       mayReorder = false
        case .mayReorder:     mayReorder = true
        case .random:         mayReorder = false
        }

        let maximumBars = min(transitionBarsRange.upperBound, policy.maximumTransitionBars)
        let minimumBars = min(transitionBarsRange.lowerBound, maximumBars)
        return DJProfile(
            id: id,
            displayName: displayName,
            blurb: blurb,
            exitRegionFloor: exitRegionFloor,
            allowMidTrackExit: allowMidTrackExit,
            entryRegionCeiling: entryRegionCeiling,
            minimumPlayFraction: minimumPlayFraction,
            admissibleTemplates: admissibleTemplates,
            repeatTemplateCooldown: repeatTemplateCooldown,
            maxAbsRatePercent: maxAbsRatePercent,
            allowVarispeed: allowVarispeed,
            requireMeasuredBPMForRate: requireMeasuredBPMForRate,
            maxDriftMs: maxDriftMs,
            minGridConfidence: minGridConfidence,
            maxCamelotSteps: maxCamelotSteps,
            allowEnergyBoost: allowEnergyBoost,
            genreCeiling: genreCeiling,
            mayReorderQueue: mayReorder,
            lookaheadCandidates: mayReorder ? max(lookaheadCandidates, 12) : 1,
            analysisBudgetPerTrack: analysisBudgetPerTrack,
            maxLoopBars: min(maxLoopBars, maximumBars),
            maxLoopHalvings: maxLoopHalvings,
            weights: adjustedWeights,
            minimumScoreToFire: minimumScoreToFire,
            transitionBarsRange: minimumBars...maximumBars,
            energyStepLimit: energyStepLimit,
            timbreTargetDistance: timbreTargetDistance,
            honoursUserTransitionLength: honoursUserTransitionLength,
            blendTargetBars: blendTargetBars
        )
    }
}

extension DJProfile {
    enum CodingKeys: String, CodingKey {
        case id, displayName, blurb
        case exitRegionFloor, allowMidTrackExit, entryRegionCeiling, minimumPlayFraction
        case admissibleTemplates, repeatTemplateCooldown
        case maxAbsRatePercent, allowVarispeed, requireMeasuredBPMForRate, maxDriftMs, minGridConfidence
        case maxCamelotSteps, allowEnergyBoost, genreCeiling
        case mayReorderQueue, lookaheadCandidates, analysisBudgetPerTrack
        case maxLoopBars, maxLoopHalvings
        case weightPairs, minimumScoreToFire, transitionBarsLow, transitionBarsHigh
        case energyStepLimit, timbreTargetDistance
        case honoursUserTransitionLength
    }

    private struct WeightPair: Codable, Sendable {
        let term: String
        let weight: Double
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = DJProfileID(try c.decode(String.self, forKey: .id))
        displayName = try c.decode(String.self, forKey: .displayName)
        blurb = try c.decode(String.self, forKey: .blurb)
        exitRegionFloor = try c.decode(Double.self, forKey: .exitRegionFloor)
        allowMidTrackExit = try c.decode(Bool.self, forKey: .allowMidTrackExit)
        entryRegionCeiling = try c.decodeIfPresent(Double.self, forKey: .entryRegionCeiling) ?? 0.20
        minimumPlayFraction = try c.decode(Double.self, forKey: .minimumPlayFraction)
        admissibleTemplates = Set(try c.decode([String].self, forKey: .admissibleTemplates)
            .map { TransitionTemplateID($0) })
        repeatTemplateCooldown = try c.decode(Int.self, forKey: .repeatTemplateCooldown)
        maxAbsRatePercent = try c.decode(Double.self, forKey: .maxAbsRatePercent)
        allowVarispeed = try c.decode(Bool.self, forKey: .allowVarispeed)
        requireMeasuredBPMForRate = try c.decode(Bool.self, forKey: .requireMeasuredBPMForRate)
        maxDriftMs = try c.decode(Double.self, forKey: .maxDriftMs)
        minGridConfidence = try c.decode(Double.self, forKey: .minGridConfidence)
        maxCamelotSteps = try c.decode(Int.self, forKey: .maxCamelotSteps)
        allowEnergyBoost = try c.decode(Bool.self, forKey: .allowEnergyBoost)
        genreCeiling = try c.decode(Double.self, forKey: .genreCeiling)
        mayReorderQueue = try c.decode(Bool.self, forKey: .mayReorderQueue)
        lookaheadCandidates = try c.decode(Int.self, forKey: .lookaheadCandidates)
        analysisBudgetPerTrack = try c.decode(Int.self, forKey: .analysisBudgetPerTrack)
        maxLoopBars = try c.decode(Int.self, forKey: .maxLoopBars)
        maxLoopHalvings = try c.decode(Int.self, forKey: .maxLoopHalvings)
        weights = Dictionary(uniqueKeysWithValues: try c.decode([WeightPair].self, forKey: .weightPairs)
            .map { (ScoringTermID($0.term), $0.weight) })
        minimumScoreToFire = try c.decode(Double.self, forKey: .minimumScoreToFire)
        let low = try c.decode(Int.self, forKey: .transitionBarsLow)
        let high = try c.decode(Int.self, forKey: .transitionBarsHigh)
        transitionBarsRange = low...max(low, high)
        energyStepLimit = try c.decode(Int.self, forKey: .energyStepLimit)
        timbreTargetDistance = try c.decode(Double.self, forKey: .timbreTargetDistance)
        honoursUserTransitionLength = try c.decodeIfPresent(Bool.self, forKey: .honoursUserTransitionLength) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.rawValue, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(blurb, forKey: .blurb)
        try c.encode(exitRegionFloor, forKey: .exitRegionFloor)
        try c.encode(allowMidTrackExit, forKey: .allowMidTrackExit)
        try c.encode(entryRegionCeiling, forKey: .entryRegionCeiling)
        try c.encode(minimumPlayFraction, forKey: .minimumPlayFraction)
        try c.encode(admissibleTemplates.map(\.rawValue).sorted(), forKey: .admissibleTemplates)
        try c.encode(repeatTemplateCooldown, forKey: .repeatTemplateCooldown)
        try c.encode(maxAbsRatePercent, forKey: .maxAbsRatePercent)
        try c.encode(allowVarispeed, forKey: .allowVarispeed)
        try c.encode(requireMeasuredBPMForRate, forKey: .requireMeasuredBPMForRate)
        try c.encode(maxDriftMs, forKey: .maxDriftMs)
        try c.encode(minGridConfidence, forKey: .minGridConfidence)
        try c.encode(maxCamelotSteps, forKey: .maxCamelotSteps)
        try c.encode(allowEnergyBoost, forKey: .allowEnergyBoost)
        try c.encode(genreCeiling, forKey: .genreCeiling)
        try c.encode(mayReorderQueue, forKey: .mayReorderQueue)
        try c.encode(lookaheadCandidates, forKey: .lookaheadCandidates)
        try c.encode(analysisBudgetPerTrack, forKey: .analysisBudgetPerTrack)
        try c.encode(maxLoopBars, forKey: .maxLoopBars)
        try c.encode(maxLoopHalvings, forKey: .maxLoopHalvings)
        try c.encode(
            weights.map { WeightPair(term: $0.key.rawValue, weight: $0.value) }
                .sorted { $0.term < $1.term },
            forKey: .weightPairs
        )
        try c.encode(minimumScoreToFire, forKey: .minimumScoreToFire)
        try c.encode(transitionBarsRange.lowerBound, forKey: .transitionBarsLow)
        try c.encode(transitionBarsRange.upperBound, forKey: .transitionBarsHigh)
        try c.encode(energyStepLimit, forKey: .energyStepLimit)
        try c.encode(timbreTargetDistance, forKey: .timbreTargetDistance)
        try c.encode(honoursUserTransitionLength, forKey: .honoursUserTransitionLength)
    }
}

enum DJBlendTarget {
    static let shortBars = 16
    static let longBars = 64
    static let autoMaximumBars = 48
    static let phraseLengths = [16, 24, 32, 40, 48]
    static let fallbackBars = 32
    static let spotCheckScale = 0.85

    static func medianBars(_ track: TrackFeatures) -> Double? {
        if let genre = track.genre, genre.family != .unknown {
            switch genre.genre {
            case .hardTechno, .schranz, .hardGroove, .hardstyle, .hardHouse, .hardDance, .hardTrance: return 39
            case .bigRoom, .futureHouse, .eurodance, .euroHouse, .italoDance, .handsUp, .donk: return 28
            default: break
            }
            switch genre.family {
            case .techno: return 38
            case .trance: return 40
            case .hardDance: return 39
            case .house: return 31
            case .disco: return 26
            default: break
            }
        }
        guard let bpm = track.beatGrid?.bpm ?? track.genre?.bpmHint, bpm > 0 else { return nil }
        var folded = bpm
        while folded < 90 { folded *= 2 }
        while folded >= 180 { folded /= 2 }
        if folded < 126 { return 31 }
        if folded < 150 { return 38 }
        return 39
    }

    static func bars(outgoing: TrackFeatures?, incoming: TrackFeatures?) -> Int {
        let medians = [outgoing, incoming].compactMap { $0.flatMap(medianBars) }
        guard !medians.isEmpty else { return fallbackBars }
        let target = medians.reduce(0, +) / Double(medians.count) * spotCheckScale
        return phraseLengths.min { lhs, rhs in
            let a = abs(Double(lhs) - target), b = abs(Double(rhs) - target)
            return a == b ? lhs > rhs : a < b
        } ?? fallbackBars
    }
}
