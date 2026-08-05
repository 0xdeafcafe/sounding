#if DEBUG
import Foundation
@testable import SoundingTV

enum DJEngineSelfTest {

    static func near(_ a: Double, _ b: Double, _ tol: Double = 0.005) -> Bool { abs(a - b) <= tol }

    static func run() -> MixImportSelfTest.Report {
        var report = MixImportSelfTest.Report()

        func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() { report.lines.append("\(name) → ok") }
            else { report.failures.append(name) }
        }
        func note(_ line: String) { report.lines.append(line) }

        testTempoRelations(expect: expect, note: note)
        testTerms(expect: expect, note: note)
        testConfidenceAttenuation(expect: expect, note: note)
        testTemplatePreconditions(expect: expect, note: note)
        testRegistryCapabilities(expect: expect, note: note)
        testBassSwapDecoupling(expect: expect, note: note)
        testProfileDifferentiation(expect: expect, note: note)
        testAutomaticMidTrackWindow(expect: expect, note: note)
        testAutomaticFallback(expect: expect, note: note)
        testDeterminism(expect: expect, note: note)
        testCamelot(expect: expect, note: note)
        testStagedSchedule(expect: expect, note: note)
        testRealAnalysedTracks(expect: expect, note: note)

        return report
    }

    static func envelope(seconds: Int, calmFrom: Int, loud: Float = 0.8, calm: Float = 0.3) -> [Float] {
        (0..<seconds).map { $0 < calmFrom ? loud : calm }
    }

    static func features(
        id: String,
        title: String,
        artist: String = "",
        duration: TimeInterval,
        bpm: Double?,
        gridConfidence: Double = 0.85,
        downbeatsKnown: Bool = false,
        anchor: TimeInterval = 0,
        key: String? = nil,
        energy: Int? = nil,
        sections: [TrackSection] = [],
        genre: MusicGenre? = nil,
        genreConfidence: Double = 0.7,
        envelope: [Float] = [],
        vocals: [ClosedRange<TimeInterval>]? = nil,
        bass: [ClosedRange<TimeInterval>]? = nil,
        swing: Double? = nil,
        extraProvenance: FeatureProvenance = []
    ) -> TrackFeatures {
        var provenance: FeatureProvenance = extraProvenance
        var grid: BeatGrid?
        if let bpm {
            grid = BeatGrid.fromDisplayBPM(bpm, anchor: anchor, confidence: gridConfidence)
            provenance.insert([.measuredTempo, .measuredBeatGrid])
            if downbeatsKnown { provenance.insert(.measuredDownbeats) }
        }
        var keyRegions: [KeyRegion] = []
        if let key, let camelot = CamelotKey.parse(key) {
            keyRegions = [KeyRegion(key: camelot, start: 0, end: duration)]
            provenance.insert(.measuredKey)
        }
        if !sections.isEmpty { provenance.insert(.measuredStructure) }
        if energy != nil { provenance.insert(.measuredLoudness) }
        if vocals != nil { provenance.insert(.measuredVocals) }
        if bass != nil { provenance.insert(.measuredBass) }
        if !envelope.isEmpty { provenance.insert(.envelopeOnly) }

        let resolution: GenreResolution? = genre.map {
            GenreResolution(
                genre: $0, family: GenreProfile.of($0).family,
                confidenceValue: genreConfidence, source: .genreField,
                evidence: ["self-test fixture"], alternatives: [], bpmHint: nil
            )
        }

        return TrackFeatures(
            trackId: id, title: title, artist: artist, duration: duration,
            beatGrid: grid, swingRatio: swing, keyRegions: keyRegions,
            sections: sections, phraseBoundaries: [], energyLevel: energy,
            envelope: envelope, genre: resolution, vocalRanges: vocals ?? [],
            bassRanges: bass ?? [],
            provenance: provenance
        )
    }

    static func plan(
        outgoing: TrackFeatures, incoming: TrackFeatures,
        exitAt: TimeInterval, entryAt: TimeInterval = 0,
        overlap: TimeInterval = 30,
        exitKind: SectionKind = .breakdown, entryKind: SectionKind = .intro,
        rate: Double = 1, factor: Double = 1,
        template: TransitionTemplateID = DJTemplates.bassSwapBlend,
        profile: DJProfile
    ) -> DJTransitionPlan {
        DJTransitionPlan(
            templateId: template, profileId: profile.id,
            outgoingTrackId: outgoing.trackId, incomingTrackId: incoming.trackId,
            exit: ExitPoint(seconds: exitAt, kind: exitKind, barsRemaining: nil,
                            onPhraseBoundary: true, confidence: 0.8),
            entry: EntryPoint(seconds: entryAt, kind: entryKind, barsUntilNextSection: nil,
                              onPhraseBoundary: true, hasBassFromHere: true, confidence: 0.8),
            overlapSeconds: overlap,
            bassSwapAtSeconds: overlap * 0.55, bassSwapSeconds: 0.94,
            incomingRateRatio: rate, tempoFactor: factor, tempoLabel: "same tempo",
            accent: nil, profileMinimumScore: profile.minimumScoreToFire
        )
    }

    static func context(
        _ outgoing: TrackFeatures, _ incoming: TrackFeatures,
        _ plan: DJTransitionPlan, _ profile: DJProfile,
        history: SetHistory = .empty
    ) -> ScoringContext {
        ScoringContext(outgoing: outgoing, incoming: incoming, plan: plan,
                       profile: profile, history: history)
    }

    private static func testTempoRelations(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── tempo relations ──")

        func relation(_ a: Double, _ b: Double) -> DJTempo.Relation? {
            guard let ga = BeatGrid.fromDisplayBPM(a, confidence: 1),
                  let gb = BeatGrid.fromDisplayBPM(b, confidence: 1) else { return nil }
            return DJTempo.best(outgoing: ga, incoming: gb)
        }

        if let r = relation(174, 87) {
            expect("174 → 87 folds to double time", r.factor == 2.0)
            expect("174 → 87 residual is exactly zero", near(r.residual, 0, 1e-12))
            expect("174 → 87 needs no rate change", near(r.requiredRate, 1, 1e-12))
            note("  174 vs 87 → factor \(r.factor), residual \(String(format: "%.2e", r.residual)), rate \(String(format: "%.6f", r.requiredRate))")
        } else { expect("174 → 87 resolves", false) }

        if let r = relation(87, 174) {
            expect("87 → 174 folds to half time", r.factor == 0.5)
            expect("87 → 174 residual is exactly zero", near(r.residual, 0, 1e-12))
        } else { expect("87 → 174 resolves", false) }

        if let r = relation(128, 140) {
            expect("128 → 140 stays 1:1", r.factor == 1.0)
            note("  128 vs 140 → factor \(r.factor), residual \(String(format: "%.4f", r.residual)), rate \(String(format: "%.4f", r.requiredRate))")
        } else { expect("128 → 140 resolves", false) }

        if let r = relation(130, 97.5) {
            expect("130 → 97.5 resolves to the 4:3 relation", near(r.factor, 4.0 / 3.0, 1e-9))
            expect("130 → 97.5 has no leftover residual", near(r.residual, 0, 1e-9))
            note("  130 vs 97.5 → factor \(String(format: "%.4f", r.factor)) (\(r.label)), residual \(String(format: "%.2e", r.residual))")
        } else { expect("130 → 97.5 resolves", false) }

        if let r = relation(128.0, 128.1) {
            let drift = DJTempo.driftMs(leftover: DJTempo.leftover(r, appliedRate: 1), overlapSeconds: 60)
            expect("0.1 BPM at 128 drifts ~46.8 ms over 32 bars", near(drift, 46.8, 0.2))
            note("  128.0 vs 128.1 uncorrected over 60 s → \(String(format: "%.1f", drift)) ms of drift")
        } else { expect("128.0 → 128.1 resolves", false) }

        if let slow = relation(90.0, 90.1), let fast = relation(174.0, 174.1) {
            let slowDrift = DJTempo.driftMs(leftover: DJTempo.leftover(slow, appliedRate: 1), overlapSeconds: 85.33)
            let fastDrift = DJTempo.driftMs(leftover: DJTempo.leftover(fast, appliedRate: 1), overlapSeconds: 44.14)
            expect("0.1 BPM drifts further at 90 than at 174", slowDrift > fastDrift * 3)
            note("  0.1 BPM over 32 bars → \(String(format: "%.1f", slowDrift)) ms at 90, \(String(format: "%.1f", fastDrift)) ms at 174")
        }
    }

    private static func testTerms(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── scoring terms in isolation ──")
        let wedding = DJProfile.weddingDJ
        let junkie = DJProfile.junkie

        let a128 = features(id: "a", title: "A", duration: 360, bpm: 128)
        let b128 = features(id: "b", title: "B", duration: 360, bpm: 128)
        let tempo = TempoTerm()
        do {
            let r = tempo.evaluate(context(a128, b128, plan(outgoing: a128, incoming: b128, exitAt: 300, profile: wedding), wedding))
            expect("tempo: identical BPM costs nothing", near(r.cost, 0, 1e-9))
            expect("tempo: identical BPM is confident", r.confidence > 0.8)
        }
        do {
            let a174 = features(id: "a", title: "DnB", duration: 360, bpm: 174)
            let b87 = features(id: "b", title: "Hip hop", duration: 360, bpm: 87)
            let p = plan(outgoing: a174, incoming: b87, exitAt: 300, rate: 1, factor: 2, profile: wedding)
            let r = tempo.evaluate(context(a174, b87, p, wedding))
            expect("tempo: 174/87 fold costs only the fold surcharge", near(r.cost, 0.06, 1e-6))
            note("  tempo 174→87: cost \(String(format: "%.3f", r.cost)) — \"\(r.explanation ?? "")\"")
        }
        do {
            let a126 = features(id: "a", title: "Amphetamine", duration: 390, bpm: 126)
            let b132 = features(id: "b", title: "BANGING NOISE", duration: 380, bpm: 132.4)
            guard let rel = DJTempo.grid(a126, b132) else { return }
            let applied = DJTempo.applicableRate(rel, profile: wedding)
            let p = plan(outgoing: a126, incoming: b132, exitAt: 302, overlap: 30.476, rate: applied, profile: wedding)
            let r = tempo.evaluate(context(a126, b132, p, wedding))
            expect("tempo: an uncorrectable 5% gap costs the maximum", near(r.cost, 1.0, 1e-9))
            expect("tempo: the explanation names the drift", r.explanation?.contains("drift") == true)
            note("  tempo 126→132.4 under Wedding: \"\(r.explanation ?? "")\"")

            let appliedJ = DJTempo.applicableRate(rel, profile: junkie)
            let pj = plan(outgoing: a126, incoming: b132, exitAt: 302, overlap: 30.476, rate: appliedJ, profile: junkie)
            let rj = tempo.evaluate(context(a126, b132, pj, junkie))
            expect("tempo: Junkie can close the same gap", rj.cost < 0.35)
            note("  tempo 126→132.4 under Junkie:  cost \(String(format: "%.3f", rj.cost)) — \"\(rj.explanation ?? "")\"")
        }
        do {
            let noGrid = features(id: "n", title: "Unknown", duration: 300, bpm: nil)
            let r = tempo.evaluate(context(noGrid, b128, plan(outgoing: noGrid, incoming: b128, exitAt: 250, profile: wedding), wedding))
            expect("tempo: an unmeasured tempo contributes nothing", r.confidence == 0)
        }

        do {
            let term = PhraseTerm()
            let grid = BeatGrid.fromDisplayBPM(128, confidence: 0.9)!
            let onPhrase = plan(outgoing: a128, incoming: b128, exitAt: grid.phraseDuration * 4, profile: wedding)
            let clean = term.evaluate(context(a128, b128, onPhrase, wedding))
            expect("phrase: both on boundaries costs nothing", near(clean.cost, 0, 1e-9))

            let oneBeatOff = plan(outgoing: a128, incoming: b128,
                                  exitAt: grid.phraseDuration * 4 + grid.beatPeriod, profile: wedding)
            let off = term.evaluate(context(a128, b128, oneBeatOff, wedding))
            expect("phrase: one beat off is penalised", off.cost > clean.cost)
            note("  phrase: on-boundary \(String(format: "%.3f", clean.cost)) vs one beat off \(String(format: "%.3f", off.cost)) — \"\(off.explanation ?? "")\"")

            let oneBarOff = plan(outgoing: a128, incoming: b128,
                                 exitAt: grid.phraseDuration * 4 + grid.barDuration, profile: wedding)
            let bar = term.evaluate(context(a128, b128, oneBarOff, wedding))
            expect("phrase: a beat error costs more than a bar error", off.cost > bar.cost)
            note("  phrase: one bar off \(String(format: "%.3f", bar.cost)) — \"\(bar.explanation ?? "")\"")

            expect("phrase: without measured downbeats (the real-world case), confidence is the flat 0.3 floor",
                   near(clean.confidence, 0.3, 1e-9))
            let withDownbeats = features(id: "ad", title: "A", duration: 360, bpm: 128, downbeatsKnown: true)
            let withDownbeats2 = features(id: "bd", title: "B", duration: 360, bpm: 128, downbeatsKnown: true)
            let onPhraseKnown = plan(outgoing: withDownbeats, incoming: withDownbeats2,
                                     exitAt: grid.phraseDuration * 4, profile: wedding)
            let cleanKnown = term.evaluate(context(withDownbeats, withDownbeats2, onPhraseKnown, wedding))
            expect("phrase: measured downbeats unlock the full ×0.9-of-grid-confidence path",
                   near(cleanKnown.confidence, 0.85 * 0.9, 1e-9))
        }

        do {
            let term = StructureTerm()
            let withSections = features(id: "s", title: "S", duration: 360, bpm: 128,
                                        sections: [TrackSection(kind: .outro, start: 300, end: 360)])
            let target = features(id: "t", title: "T", duration: 360, bpm: 128,
                                  sections: [TrackSection(kind: .intro, start: 0, end: 30)])
            let good = term.evaluate(context(withSections, target,
                plan(outgoing: withSections, incoming: target, exitAt: 300, exitKind: .outro, entryKind: .intro, profile: wedding), wedding))
            expect("structure: outro → intro is free", near(good.cost, 0, 1e-9))

            let bad = term.evaluate(context(withSections, target,
                plan(outgoing: withSections, incoming: target, exitAt: 300, exitKind: .drop, entryKind: .ambientIntro, profile: wedding), wedding))
            expect("structure: drop → ambient intro dumps the energy", bad.cost >= 0.8)
            note("  structure: outro→intro \(String(format: "%.2f", good.cost)), drop→ambient intro \(String(format: "%.2f", bad.cost))")
        }

        do {
            let term = HarmonicTerm()
            func cost(_ from: String, _ to: String, _ profile: DJProfile) -> TermResult {
                let x = features(id: "x", title: "X", duration: 360, bpm: 128, key: from)
                let y = features(id: "y", title: "Y", duration: 360, bpm: 128, key: to)
                return term.evaluate(context(x, y, plan(outgoing: x, incoming: y, exitAt: 300, profile: profile), profile))
            }
            expect("harmonic: same key is free", near(cost("Am", "Am", wedding).cost, 0, 1e-9))
            expect("harmonic: one step round the wheel is cheap", near(cost("Am", "Em", wedding).cost, 0.12, 1e-9))
            expect("harmonic: the relative major is cheap", near(cost("Am", "C", wedding).cost, 0.15, 1e-9))
            let boostW = cost("Am", "Bm", wedding)
            let boostJ = cost("Am", "Bm", junkie)
            expect("harmonic: Wedding refuses the two-step energy boost", boostW.cost >= 0.85)
            expect("harmonic: Junkie allows it", near(boostJ.cost, 0.25, 1e-9))
            expect("harmonic: is discounted to 0.45 confidence", near(boostJ.confidence, 0.45, 1e-9))
            note("  harmonic 8A→10A: Wedding \(String(format: "%.2f", boostW.cost)) \"\(boostW.explanation ?? "")\", Junkie \(String(format: "%.2f", boostJ.cost)) \"\(boostJ.explanation ?? "")\"")

            let unmeasured = term.evaluate(context(a128, b128, plan(outgoing: a128, incoming: b128, exitAt: 300, profile: wedding), wedding))
            expect("harmonic: no key means no contribution", unmeasured.confidence == 0)
        }

        do {
            let term = EnergyTerm()
            func cost(_ from: Int, _ to: Int, _ profile: DJProfile) -> TermResult {
                let x = features(id: "x", title: "X", duration: 360, bpm: 128, energy: from)
                let y = features(id: "y", title: "Y", duration: 360, bpm: 128, energy: to)
                return term.evaluate(context(x, y, plan(outgoing: x, incoming: y, exitAt: 300, profile: profile), profile))
            }
            expect("energy: one step is free under Wedding", near(cost(6, 7, wedding).cost, 0, 1e-9))
            expect("energy: two steps costs Wedding", near(cost(6, 8, wedding).cost, 0.45, 1e-9))
            expect("energy: two steps is free for Junkie", near(cost(6, 8, junkie).cost, 0, 1e-9))
            expect("energy: three steps costs both", cost(5, 8, junkie).cost >= 0.45)
            note("  energy 6→8: Wedding \(String(format: "%.2f", cost(6, 8, wedding).cost)), Junkie \(String(format: "%.2f", cost(6, 8, junkie).cost))")

            let proxyA = features(id: "pa", title: "PA", duration: 100, bpm: 128, envelope: envelope(seconds: 100, calmFrom: 80))
            let proxyB = features(id: "pb", title: "PB", duration: 100, bpm: 128, envelope: envelope(seconds: 100, calmFrom: 80))
            let proxy = term.evaluate(context(proxyA, proxyB, plan(outgoing: proxyA, incoming: proxyB, exitAt: 80, profile: wedding), wedding))
            expect("energy: an envelope proxy is worth much less than a measurement",
                   proxy.confidence > 0 && proxy.confidence < 0.25)
        }

        do {
            let term = GenreTerm()
            let th = features(id: "th", title: "Tech house", duration: 360, bpm: 126, genre: .techHouse, genreConfidence: 0.7)
            let hg = features(id: "hg", title: "Hard groove", duration: 360, bpm: 132, genre: .hardGroove, genreConfidence: 0.6)
            let r = term.evaluate(context(th, hg, plan(outgoing: th, incoming: hg, exitAt: 300, profile: wedding), wedding))
            expect("genre: joint confidence is the product of both sides", near(r.confidence, 0.42, 1e-9))
            expect("genre: never vetoes", !r.veto)
            note("  genre techHouse→hardGroove: cost \(String(format: "%.2f", r.cost)), κ \(String(format: "%.2f", r.confidence))")
            note("    \"\(r.explanation ?? "")\"")

            let none = term.evaluate(context(a128, b128, plan(outgoing: a128, incoming: b128, exitAt: 300, profile: wedding), wedding))
            expect("genre: an unlabelled pair contributes nothing", none.confidence == 0)
        }

        do {
            let term = SpectralClashTerm()
            let unmeasured = term.evaluate(context(a128, b128, plan(outgoing: a128, incoming: b128, exitAt: 300, profile: wedding), wedding))
            expect("spectralClash: unmeasured vocals contribute nothing", unmeasured.confidence == 0)

            let outV = features(id: "ov", title: "OV", duration: 360, bpm: 128, vocals: [300...340])
            let inV = features(id: "iv", title: "IV", duration: 360, bpm: 128, vocals: [0...40])
            let clash = term.evaluate(context(outV, inV, plan(outgoing: outV, incoming: inV, exitAt: 300, overlap: 30, profile: wedding), wedding))
            expect("spectralClash: two overlapping vocals cost 0.9", near(clash.cost, 0.9, 1e-9))
            note("  spectralClash: \"\(clash.explanation ?? "")\"")

            let outQuiet = features(id: "oq", title: "OQ", duration: 360, bpm: 128, vocals: [10...40])
            let clean = term.evaluate(context(outQuiet, inV, plan(outgoing: outQuiet, incoming: inV, exitAt: 300, overlap: 30, profile: wedding), wedding))
            expect("spectralClash: no overlap costs nothing", near(clean.cost, 0, 1e-9))
        }

        do {
            let outgoing = features(id: "bs-out", title: "Outgoing", duration: 300, bpm: 128)
            let incoming = features(id: "bs-in", title: "Incoming", duration: 300, bpm: 128)
            let exits = [ExitPoint(seconds: 240, kind: .outro, barsRemaining: nil,
                                    onPhraseBoundary: true, confidence: 0.8)]
            let noBass = EntryPoint(seconds: 0, kind: .intro, barsUntilNextSection: nil,
                                     onPhraseBoundary: true, hasBassFromHere: false, confidence: 0.9)
            let withBass = EntryPoint(seconds: 8, kind: .intro, barsUntilNextSection: nil,
                                       onPhraseBoundary: true, hasBassFromHere: true, confidence: 0.6)
            var rng = SeededGenerator(seed: 1)

            let mixed = BassSwapBlendTemplate().propose(
                outgoing: outgoing, incoming: incoming, exits: exits, entries: [noBass, withBass],
                profile: DJProfile.weddingDJ, rng: &rng
            )
            expect("bass swap: proposes at least one plan when a bass-carrying entry exists", !mixed.isEmpty)
            expect("bass swap: never proposes into a bass-less entry",
                   mixed.allSatisfy { $0.entry.hasBassFromHere })
            note("  bass swap: \(mixed.count) plan(s), all entering at \(mixed.map { String(format: "%.0fs", $0.entry.seconds) }.joined(separator: ", "))")

            let bassless = BassSwapBlendTemplate().propose(
                outgoing: outgoing, incoming: incoming, exits: exits, entries: [noBass],
                profile: DJProfile.weddingDJ, rng: &rng
            )
            expect("bass swap: proposes nothing when every entry is bass-less", bassless.isEmpty)

            let bassFrom60 = features(id: "b60", title: "B60", duration: 300, bpm: 128, bass: [60...300])
            let candidates = DJPointFinder.entryCandidates(in: bassFrom60, profile: DJProfile.weddingDJ)
            expect("entryCandidates: measured bass starting at 60s marks that phrase boundary bass-capable",
                   candidates.contains { near($0.seconds, 60, 0.01) && $0.hasBassFromHere })
            expect("entryCandidates: measured bass absent before 60s marks an earlier boundary bass-less",
                   candidates.contains { near($0.seconds, 15, 0.01) && !$0.hasBassFromHere })
        }

        do {
            let term = GrooveTerm()
            let straight = features(id: "st", title: "Straight", duration: 360, bpm: 128, swing: 0.50)
            let shuffled = features(id: "sh", title: "Shuffled", duration: 360, bpm: 128, swing: 0.58)
            let r = term.evaluate(context(straight, shuffled, plan(outgoing: straight, incoming: shuffled, exitAt: 300, profile: wedding), wedding))
            expect("groove: 58% against straight at 128 lands near 18.7 ms",
                   r.explanation?.contains("18.7") == true)
            expect("groove: 18.7 ms is well past the 10 ms budget", near(r.cost, 1.0, 1e-9))
            note("  groove: \"\(r.explanation ?? "")\"")

            let unmeasured = term.evaluate(context(a128, b128, plan(outgoing: a128, incoming: b128, exitAt: 300, profile: wedding), wedding))
            expect("groove: ships unmeasured, so contributes nothing", unmeasured.confidence == 0)
        }

        do {
            let term = NoveltyTerm()
            let byArtist = features(id: "z", title: "Z", artist: "Pegassi", duration: 360, bpm: 128)
            let fresh = term.evaluate(context(a128, byArtist, plan(outgoing: a128, incoming: byArtist, exitAt: 300, profile: wedding), wedding))
            expect("novelty: a fresh move costs nothing", near(fresh.cost, 0, 1e-9))
            expect("novelty: is bookkeeping, so always fully confident", fresh.confidence == 1)

            let repeated = term.evaluate(context(a128, byArtist,
                plan(outgoing: a128, incoming: byArtist, exitAt: 300, profile: junkie),
                junkie,
                history: SetHistory(recentTemplates: [DJTemplates.bassSwapBlend], recentArtists: ["Pegassi"])))
            expect("novelty: repeating the move and the artist costs", repeated.cost > 0.5)
            note("  novelty: \"\(repeated.explanation ?? "")\"")
        }

        do {
            let term = FeasibilityTerm()
            let short = features(id: "sh", title: "Short", duration: 100, bpm: 128)
            let other = features(id: "ot", title: "Other", duration: 300, bpm: 128)
            let overrun = term.evaluate(context(short, other,
                plan(outgoing: short, incoming: other, exitAt: 90, overlap: 30, profile: junkie), junkie))
            expect("feasibility: a blend past the end of the track vetoes", overrun.veto)
            note("  feasibility: \"\(overrun.explanation ?? "")\"")

            let tooEarly = term.evaluate(context(other, short,
                plan(outgoing: other, incoming: short, exitAt: 60, overlap: 30, profile: wedding), wedding))
            expect("feasibility: leaving a track too early vetoes under Wedding", tooEarly.veto)
            note("  feasibility: \"\(tooEarly.explanation ?? "")\"")

            let ok = term.evaluate(context(other, short,
                plan(outgoing: other, incoming: short, exitAt: 260, overlap: 30, profile: wedding), wedding))
            expect("feasibility: a well-sited blend does not veto", !ok.veto)
        }
    }

    private static func testConfidenceAttenuation(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── confidence attenuation ──")
        let profile = DJProfile.junkie

        struct FixedTerm: ScoringTerm {
            let id: ScoringTermID
            let result: TermResult
            func evaluate(_ ctx: ScoringContext) -> TermResult { result }
        }

        let a = features(id: "a", title: "A", duration: 360, bpm: 128)
        let b = features(id: "b", title: "B", duration: 360, bpm: 128)
        let p = plan(outgoing: a, incoming: b, exitAt: 300, profile: profile)

        let base: [any ScoringTerm] = [
            FixedTerm(id: .structure, result: TermResult(cost: 0.2, confidence: 1, explanation: "structure")),
            FixedTerm(id: .tempo, result: TermResult(cost: 0.1, confidence: 1, explanation: "tempo"))
        ]
        let withZero = base + [
            FixedTerm(id: .harmonic, result: TermResult(cost: 1.0, confidence: 0, explanation: "key unknown"))
        ]

        let s1 = DJPlanner.score(plan: p, outgoing: a, incoming: b, profile: profile,
                                 terms: base, history: .empty, templateName: "T")
        let s2 = DJPlanner.score(plan: p, outgoing: a, incoming: b, profile: profile,
                                 terms: withZero, history: .empty, templateName: "T")
        expect(
            "a κ = 0 term lowers the evidence ceiling without pretending there is a clash",
            s2.score < s1.score && s2.score > s1.score - 0.1
        )
        note("  without the unmeasured term \(String(format: "%.4f", s1.score)), with it \(String(format: "%.4f", s2.score))")

        let withFull = base + [
            FixedTerm(id: .harmonic, result: TermResult(cost: 1.0, confidence: 1, explanation: "key clash"))
        ]
        let s3 = DJPlanner.score(plan: p, outgoing: a, incoming: b, profile: profile,
                                 terms: withFull, history: .empty, templateName: "T")
        expect("the same term at κ = 1 moves the score", s3.score < s1.score - 0.2)
        expect("unknown evidence is penalised less than a measured clash", s2.score > s3.score)
        note("  the same term at κ = 1 → \(String(format: "%.4f", s3.score))")
    }

    private static func testTemplatePreconditions(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── template preconditions ──")
        let wedding = DJProfile.weddingDJ

        let tiny = features(id: "tiny", title: "Interlude", duration: 30, bpm: 128)
        let normal = features(id: "n", title: "Normal", duration: 360, bpm: 128)

        let t1 = BassSwapBlendTemplate()
        let rejected = t1.admits(outgoing: tiny, incoming: normal, profile: wedding)
        expect("T1 rejects a track too short to blend out of", !rejected.isAdmitted)
        expect("T1's rejection carries a reason", rejected.reason?.isEmpty == false)
        note("  \(rejected.reason ?? "no reason")")

        expect("T1 admits a normal pair", t1.admits(outgoing: normal, incoming: normal, profile: wedding).isAdmitted)

        let t10 = HalfTimeBlendTemplate()
        let dnb = features(id: "dnb", title: "Rollers", duration: 360, bpm: 174)
        let hiphop = features(id: "hh", title: "Boom bap", duration: 240, bpm: 87)
        let house = features(id: "ho", title: "Roller", duration: 360, bpm: 128)
        expect("T10 admits 174 against 87", t10.admits(outgoing: dnb, incoming: hiphop, profile: wedding).isAdmitted)
        let notAFold = t10.admits(outgoing: dnb, incoming: house, profile: wedding)
        expect("T10 rejects 174 against 128", !notAFold.isAdmitted)
        note("  \(notAFold.reason ?? "no reason")")

        let noGrid = features(id: "ng", title: "No grid", duration: 360, bpm: nil)
        let ungridded = t10.admits(outgoing: noGrid, incoming: hiphop, profile: wedding)
        expect("T10 rejects an unmeasured grid", !ungridded.isAdmitted)
        note("  \(ungridded.reason ?? "no reason")")

        let almost = features(id: "al", title: "Almost", duration: 240, bpm: 86.0)
        let nearFold = t10.admits(outgoing: dnb, incoming: almost, profile: wedding)
        expect("T10 rejects a 2:1 relation that is really a stretch", !nearFold.isAdmitted)
        note("  \(nearFold.reason ?? "no reason")")

        expect("T8 always admits", CutOnTheOneTemplate().admits(outgoing: tiny, incoming: normal, profile: wedding).isAdmitted)
    }

    private static func testRegistryCapabilities(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── registry ──")
        let registry = DJTemplates.v1Registry
        let junkie = DJProfile.junkie

        let full = registry.admissible(for: junkie, capabilities: .v1MixEngine)
        expect("all five v1 templates are admissible with the v1 engine", full.count == 5)
        note("  admissible: \(full.map(\.id.rawValue).joined(separator: ", "))")

        var reduced = ExecutorCapabilities.v1MixEngine
        reduced.remove(.snappedBassSwap)
        let without = registry.admissible(for: junkie, capabilities: reduced)
        expect("removing snappedBassSwap removes exactly the templates that need it", without.count == 3)
        expect("bassSwapBlend disappears without its capability",
               !without.contains { $0.id == DJTemplates.bassSwapBlend })
        expect("cutOnTheOne survives — it only needs a crossfader",
               without.contains { $0.id == DJTemplates.cutOnTheOne })
        note("  without snappedBassSwap: \(without.map(\.id.rawValue).joined(separator: ", "))")

        let weddingSet = registry.admissible(for: .weddingDJ, capabilities: .v1MixEngine)
        expect("Wedding's admissible set is its own list", Set(weddingSet.map(\.id)) == DJProfile.weddingDJ.admissibleTemplates)
    }

    private static func testBassSwapDecoupling(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── bass swap timing ──")
        let grid = BeatGrid.fromDisplayBPM(128, confidence: 0.9)!
        let window = grid.barDuration * 16          // 30 s, the house default

        let wedding = DJBlendMath.bassSwap(window: window, grid: grid, profile: .weddingDJ)
        let junkie = DJBlendMath.bassSwap(window: window, grid: grid, profile: .junkie)

        expect("the swap is not the fade window", wedding.duration < window / 10)
        expect("Wedding swaps in two beats", near(wedding.duration, grid.beatPeriod * 2, 1e-9))
        expect("Junkie swaps in one", near(junkie.duration, grid.beatPeriod, 1e-9))
        expect("the swap lands on a phrase boundary inside the fade",
               near(wedding.at.truncatingRemainder(dividingBy: grid.phraseDuration), 0, 1e-9))
        expect("the swap finishes before the fader does", wedding.at + wedding.duration <= window)
        note("  30.0 s fade at 128 BPM → swap at \(String(format: "%.3f", wedding.at))s over \(String(format: "%.3f", wedding.duration))s (Wedding), \(String(format: "%.3f", junkie.duration))s (Junkie)")
        note("  before this change the same transition ramped the low band over all \(String(format: "%.1f", window))s")

        let ungridded = DJBlendMath.bassSwap(window: window, grid: nil, profile: .weddingDJ)
        expect("without a grid the swap is still half a second, not the window", ungridded.duration <= 0.5)
        note("  no grid → swap at \(String(format: "%.2f", ungridded.at))s over \(String(format: "%.2f", ungridded.duration))s")
    }

    private static func testProfileDifferentiation(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── profile differentiation: one pair, two DJs ──")

        let outgoing = features(
            id: "amphetamine", title: "Amphetamine", artist: "A", duration: 390, bpm: 126,
            key: "Am", energy: 6,
            sections: [TrackSection(kind: .intro, start: 0, end: 32),
                       TrackSection(kind: .drop, start: 32, end: 302),
                       TrackSection(kind: .breakdown, start: 302, end: 390)],
            genre: .techHouse, genreConfidence: 0.7,
            envelope: envelope(seconds: 390, calmFrom: 302),
            vocals: []
        )
        let incoming = features(
            id: "banging", title: "BANGING NOISE", artist: "B", duration: 380, bpm: 132.4,
            key: "Bm", energy: 8,
            sections: [TrackSection(kind: .intro, start: 0, end: 29),
                       TrackSection(kind: .drop, start: 29, end: 380)],
            genre: .hardGroove, genreConfidence: 0.6,
            envelope: envelope(seconds: 380, calmFrom: 350),
            vocals: []
        )

        func rank(_ profile: DJProfile) -> PlanningResult {
            var rng = SeededGenerator(["selftest", outgoing.trackId, "0"])
            return DJPlanner.plan(
                outgoing: outgoing, candidates: [incoming], profile: profile,
                templates: DJTemplates.v1Registry, scoring: DJTerms.v1Registry,
                capabilities: .v1MixEngine, history: .empty, rng: &rng
            )
        }

        let w = rank(.weddingDJ)
        let j = rank(.junkie)

        guard let wBest = w.ranked.first, let jBest = j.ranked.first else {
            expect("both profiles produce a ranking", false)
            return
        }

        note("  Wedding best: \(wBest.plan.templateId.rawValue) @ \(DJFormat.time(wBest.plan.exit.seconds)) score \(String(format: "%.3f", wBest.score)) (threshold \(String(format: "%.2f", DJProfile.weddingDJ.minimumScoreToFire)))")
        note("    \(wBest.rationale.reasoning)")
        note("  Junkie best:  \(jBest.plan.templateId.rawValue) @ \(DJFormat.time(jBest.plan.exit.seconds)) score \(String(format: "%.3f", jBest.score)) (threshold \(String(format: "%.2f", DJProfile.junkie.minimumScoreToFire)))")
        note("    \(jBest.rationale.reasoning)")

        expect("the two profiles reach different scores", !near(wBest.score, jBest.score, 0.02))

        let wBlend = w.ranked.first { $0.plan.templateId == DJTemplates.bassSwapBlend }
        let jBlend = j.ranked.first { $0.plan.templateId == DJTemplates.bassSwapBlend }
        guard let wBlend, let jBlend else {
            expect("both profiles considered a bass-swap blend", false)
            return
        }
        note("  bass-swap blend: Wedding \(String(format: "%.3f", wBlend.score)), Junkie \(String(format: "%.3f", jBlend.score))")
        expect("Wedding's blend of this pair does not reach its threshold", !wBlend.fires)
        expect("Junkie's blend of the same pair does", jBlend.fires)
        expect("Junkie scores the blend far higher", jBlend.score > wBlend.score + 0.4)

        expect("Wedding falls back to the clean cut", wBest.plan.templateId == DJTemplates.cutOnTheOne)
        expect("Junkie takes the blend", jBest.plan.templateId == DJTemplates.bassSwapBlend)

        expect("Wedding's blend scores 0.235 ± 0.02", near(wBlend.score, 0.235, 0.02))
        expect("Junkie's blend scores 0.839 ± 0.02", near(jBlend.score, 0.839, 0.02))

        let wExits = DJPointFinder.exitCandidates(in: outgoing, profile: .weddingDJ)
        let jExits = DJPointFinder.exitCandidates(in: outgoing, profile: .junkie)
        expect("Junkie finds more exits than Wedding", jExits.count > wExits.count)
        expect("Junkie will leave earlier than Wedding",
               (jExits.map(\.seconds).min() ?? 0) < (wExits.map(\.seconds).min() ?? 0))
        note("  exits: Wedding \(wExits.count) (earliest \(DJFormat.time(wExits.map(\.seconds).min() ?? 0))), Junkie \(jExits.count) (earliest \(DJFormat.time(jExits.map(\.seconds).min() ?? 0)))")

        let refusal = PhantomDJEngine.refusalReasoning(
            PlanningResult(ranked: [wBlend], rejections: []), profile: .weddingDJ
        )
        expect("the refusal names the threshold it missed", refusal.contains("threshold"))
        note("  refusal: \(refusal)")
    }

    private static func testDeterminism(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── determinism ──")
        let a = features(id: "a", title: "A", duration: 360, bpm: 128, key: "Am", energy: 6,
                         genre: .techHouse, envelope: envelope(seconds: 360, calmFrom: 300))
        let b = features(id: "b", title: "B", duration: 360, bpm: 128, key: "Em", energy: 6,
                         genre: .techHouse, envelope: envelope(seconds: 360, calmFrom: 330))

        func once() -> PlanningResult {
            var rng = SeededGenerator(["session-1", a.trackId, "3"])
            return DJPlanner.plan(outgoing: a, candidates: [b], profile: .junkie,
                                  templates: DJTemplates.v1Registry, scoring: DJTerms.v1Registry,
                                  capabilities: .v1MixEngine, history: .empty, rng: &rng)
        }
        let first = once()
        let second = once()
        expect("the same inputs and seed produce an identical ranking", first == second)
        expect("the ranking is not empty", !first.ranked.isEmpty)
        note("  \(first.ranked.count) plans ranked, best \(first.ranked.first.map { String(format: "%.4f", $0.score) } ?? "—"), reproduced byte-identically")

        var otherRNG = SeededGenerator(["session-2", a.trackId, "3"])
        let third = DJPlanner.plan(outgoing: a, candidates: [b], profile: .junkie,
                                   templates: DJTemplates.v1Registry, scoring: DJTerms.v1Registry,
                                   capabilities: .v1MixEngine, history: .empty, rng: &otherRNG)
        expect("a different seed still reaches the same winner",
               third.ranked.first?.plan.templateId == first.ranked.first?.plan.templateId)
    }

    private static func testAutomaticFallback(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── automatic fallback ──")
        let outgoing = features(
            id: "fallback-out", title: "Outgoing", duration: 240, bpm: 128,
            sections: [TrackSection(kind: .outro, start: 205, end: 240)]
        )
        let incoming = features(
            id: "fallback-in", title: "Incoming", duration: 220, bpm: 128,
            sections: [TrackSection(kind: .intro, start: 0, end: 24)]
        )
        var rng = SeededGenerator(["automatic-fallback"])
        let ranked = DJPlanner.plan(
            outgoing: outgoing, candidates: [incoming], profile: .weddingDJ,
            templates: DJTemplates.v1Registry, scoring: DJTerms.v1Registry,
            capabilities: .v1MixEngine, history: .empty, rng: &rng
        )
        let deliberatelyBelowThreshold = PlanningResult(
            ranked: ranked.ranked.map {
                ScoredPlan(plan: $0.plan, score: 0, rationale: $0.rationale)
            },
            rejections: ranked.rejections
        )
        let selected = PhantomDJEngine.selectPlan(
            from: deliberatelyBelowThreshold,
            profile: .weddingDJ
        )

        expect("below-threshold automation still selects a plan", selected != nil)
        expect("below-threshold automation selects the clean cut",
               selected?.templateId == DJTemplates.cutOnTheOne)
        expect("the fallback keeps the chosen incoming track",
               selected?.incomingTrackId == incoming.trackId)
        expect("the fallback explains that confidence missed the threshold",
               selected?.reasoning.contains("threshold") == true)
    }

    private static func testAutomaticMidTrackWindow(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── automatic mid-track window ──")
        let outgoing = features(
            id: "auto-mid-out", title: "Outgoing", duration: 300, bpm: 120,
            downbeatsKnown: true, key: "Am", energy: 6,
            sections: [
                TrackSection(kind: .breakdown, start: 168, end: 192),
                TrackSection(kind: .outro, start: 270, end: 300),
            ],
            genre: .techHouse,
            envelope: envelope(seconds: 300, calmFrom: 168),
            vocals: [], bass: [0...165, 192...300]
        )
        let incoming = features(
            id: "auto-mid-in", title: "Incoming", duration: 260, bpm: 120,
            downbeatsKnown: true, key: "Em", energy: 6,
            sections: [TrackSection(kind: .intro, start: 0, end: 32)],
            genre: .techHouse,
            envelope: envelope(seconds: 260, calmFrom: 230),
            vocals: [], bass: [16...260]
        )

        let automaticExits = DJPointFinder.exitCandidates(in: outgoing, profile: .automaticDJ)
        let weddingExits = DJPointFinder.exitCandidates(in: outgoing, profile: .weddingDJ)
        let automaticEarliest = automaticExits.map(\.seconds).min() ?? outgoing.duration
        let weddingEarliest = weddingExits.map(\.seconds).min() ?? outgoing.duration

        expect("Auto DJ considers a transition before the final quarter", automaticEarliest < outgoing.duration * 0.75)
        expect("Auto DJ considers an earlier exit than Wedding DJ", automaticEarliest < weddingEarliest)

        let selected = PhantomDJEngine.plan(.init(
            outgoing: outgoing,
            candidates: [incoming],
            profile: .automaticDJ,
            seedComponents: ["automatic-mid-track"]
        )).plan
        expect("Auto DJ produces a usable plan for a strong mid-track breakdown", selected != nil)
        expect("Auto DJ chooses the strong breakdown instead of waiting for the ending",
               (selected?.mixPointSeconds ?? outgoing.duration) < outgoing.duration * 0.75)
    }

    private static func testCamelot(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── camelot ──")
        expect("8A is A minor", CamelotKey.parse("Am")?.label == "8A")
        expect("8B is C major", CamelotKey.parse("C")?.label == "8B")
        expect("9A is E minor", CamelotKey.parse("Em")?.label == "9A")
        expect("5A is C minor", CamelotKey.parse("Cm")?.label == "5A")
        expect("a bare Camelot code round-trips", CamelotKey.parse("11B")?.label == "11B")
        expect("F# minor is 11A", CamelotKey.parse("F#m")?.label == "11A")

        let a = CamelotKey.parse("Am")!
        expect("8A → 9A is one step", a.wheelSteps(to: CamelotKey.parse("Em")!) == 1)
        expect("8A → 10A is two steps", a.wheelSteps(to: CamelotKey.parse("Bm")!) == 2)
        expect("8A → 8B is zero wheel steps with a mode change",
               a.wheelSteps(to: CamelotKey.parse("C")!) == 0 && a.mode != CamelotKey.parse("C")!.mode)

        let compatible = CamelotKey(wheelPosition: 8, mode: .major).harmonicallyCompatible.map(\.label)
        expect("8B's compatible set is 8B, 7B, 9B, 8A",
               Set(compatible) == Set(["8B", "7B", "9B", "8A"]))
        expect("1B is not compatible with 8B", !compatible.contains("1B"))
        note("  8B → \(compatible.joined(separator: ", "))")
    }

    private static func testStagedSchedule(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── staged schedules (loop roll-down) ──")

        let hot = features(
            id: "hot", title: "No Outro", duration: 300, bpm: 128, key: "Am", energy: 7,
            genre: .hardGroove, envelope: [Float](repeating: 0.85, count: 300)
        )
        let next = features(
            id: "next", title: "Follow Up", duration: 300, bpm: 128, key: "Em", energy: 7,
            genre: .hardGroove, envelope: [Float](repeating: 0.8, count: 300)
        )

        let t6 = LoopRollDownTemplate()
        let weddingSays = t6.admits(outgoing: hot, incoming: next, profile: .weddingDJ)
        expect("Wedding refuses the loop roll-down outright", !weddingSays.isAdmitted)
        note("  \(weddingSays.reason ?? "no reason")")
        expect("Junkie admits it", t6.admits(outgoing: hot, incoming: next, profile: .junkie).isAdmitted)

        let registry = DJTemplates.v1Registry
        expect("the loop roll-down is registered",
               registry.templates[DJTemplates.loopRollDown] != nil)
        expect("Junkie names it",
               DJProfile.junkie.admissibleTemplates.contains(DJTemplates.loopRollDown))
        expect("Wedding does not name it",
               !DJProfile.weddingDJ.admissibleTemplates.contains(DJTemplates.loopRollDown))
        expect("v1 capabilities filter it out",
               !registry.admissible(for: .junkie, capabilities: .v1MixEngine)
                   .contains { $0.id == DJTemplates.loopRollDown })

        var withResize = ExecutorCapabilities.v1MixEngine
        withResize.insert(.loopResize)
        expect("adding loopResize is all it takes to admit it",
               registry.admissible(for: .junkie, capabilities: withResize)
                   .contains { $0.id == DJTemplates.loopRollDown })

        var rng = SeededGenerator(["stage-test"])
        let exits = DJPointFinder.exitCandidates(in: hot, profile: .junkie)
        let entries = DJPointFinder.entryCandidates(in: next, profile: .junkie)
        let owners = LoopRollDownTemplate(ladder: LoopRollDownTemplate.ownersLadder)
        let plans = owners.propose(outgoing: hot, incoming: next, exits: exits,
                                   entries: entries, profile: .junkie, rng: &rng)
        guard let plan = plans.first else {
            expect("the loop roll-down proposes a plan", false)
            return
        }

        let loops = plan.stages.compactMap { stage -> Double? in
            if case .loop(let bars) = stage.action { return bars }
            return nil
        }
        expect("the ladder is carried as data, in order", loops == [8, 6, 4, 2, 1])
        expect("every loop stage snaps to a bar",
               plan.stages.allSatisfy { if case .loop = $0.action { return $0.snap == .bar }; return true })

        let hasSweep = plan.stages.contains { if case .lowPassTo = $0.action { return true }; return false }
        expect("a filter sweep runs in parallel across the ladder", hasSweep)
        let sweepSpansLadder = plan.stages.contains { stage in
            if case .lowPassTo(_, let over) = stage.action {
                return stage.atSeconds == 0 && near(over, 21 * 1.875, 0.01)
            }
            return false
        }
        expect("the sweep spans the whole ladder, not one rung", sweepSpansLadder)

        let cut = plan.stages.first { if case .hardCut = $0.action { return true }; return false }
        expect("the move terminates in a hard cut, not a fade", cut != nil)
        expect("the cut lands on a downbeat", cut?.snap == .bar)
        expect("the cut is the last thing that happens",
               (cut?.atSeconds ?? 0) >= (loops.reduce(0, +) * 1.875) - 0.01)

        expect("the plan declares the DSP its stages need",
               plan.stageCapabilities.contains(.loopResize)
                   && plan.stageCapabilities.contains(.sampleAccurateCue))
        expect("it does not claim a high-pass or a delay this engine lacks",
               !plan.stageCapabilities.contains(.highPassFilter)
                   && !plan.stageCapabilities.contains(.delayPerDeck))

        note("  schedule: \(plan.stageSummary ?? "—")")
        note("  stages: " + plan.stages.sorted { $0.atSeconds < $1.atSeconds }
            .map { String(format: "%.2fs %@ %@", $0.atSeconds, $0.deck.rawValue, $0.action.summary) }
            .joined(separator: " | "))

        var rng2 = SeededGenerator(["stage-test-2"])
        let halving = LoopRollDownTemplate().propose(
            outgoing: hot, incoming: next, exits: exits, entries: entries,
            profile: .junkie, rng: &rng2
        ).first
        let halvingLoops = halving?.stages.compactMap { stage -> Double? in
            if case .loop(let bars) = stage.action { return bars }
            return nil
        }
        expect("the halving ladder is the same code with different data", halvingLoops == [8, 4, 2, 1])
        note("  halving: \(halving?.stageSummary ?? "—")")
    }

    private static func testRealAnalysedTracks(
        expect: (String, @autoclosure () -> Bool) -> Void,
        note: (String) -> Void
    ) {
        note("── real analysed tracks (task #68 verification set) ──")

        let trackA = features(
            id: "real-a", title: "Real track A", duration: 340,
            bpm: 129.69, key: "7A", genre: .techHouse, genreConfidence: 0.06
        )
        let trackB = features(
            id: "real-b", title: "Real track B", duration: 305,
            bpm: 152.47, key: "2A", genre: .hardTechno, genreConfidence: 0.04
        )
        let trackC = features(
            id: "real-c", title: "Real track C", duration: 298,
            bpm: 147, key: nil
        )

        for (name, grid) in [("A", trackA.beatGrid), ("B", trackB.beatGrid), ("C", trackC.beatGrid)] {
            expect("real track \(name) has a beat grid at the real 0.85 cached-tier confidence",
                   grid.map { near($0.confidence, 0.85, 1e-9) } ?? false)
        }
        expect("real track C has no key (the 8/10 coverage gap)", trackC.keyRegions.isEmpty)
        expect("real track A/B carry a key (the other 8/10)",
               !trackA.keyRegions.isEmpty && !trackB.keyRegions.isEmpty)

        let tempo = TempoTerm()
        let abPlan = plan(outgoing: trackA, incoming: trackB, exitAt: 280, rate: 1, profile: .weddingDJ)
        let abResult = tempo.evaluate(context(trackA, trackB, abPlan, .weddingDJ))
        expect("129.69 → 152.47 finds no cheap fold and costs accordingly", abResult.cost > 0.9)
        expect("129.69 → 152.47 confidence is the real 0.85 ceiling, not a fixture round number",
               near(abResult.confidence, 0.85, 1e-9))
        note("  real tempo 129.69→152.47: cost \(String(format: "%.3f", abResult.cost)), κ \(String(format: "%.3f", abResult.confidence)) — \"\(abResult.explanation ?? "")\"")

        let bcPlanWedding = plan(outgoing: trackB, incoming: trackC, exitAt: 270, rate: 1, profile: .weddingDJ)
        let bcWedding = tempo.evaluate(context(trackB, trackC, bcPlanWedding, .weddingDJ))
        guard let relationBC = DJTempo.grid(trackB, trackC) else {
            expect("152.47 vs 147 resolves a tempo relation", false)
            return
        }
        let appliedJ = DJTempo.applicableRate(relationBC, profile: .junkie)
        let bcPlanJunkie = plan(outgoing: trackB, incoming: trackC, exitAt: 270, rate: appliedJ, profile: .junkie)
        let bcJunkie = tempo.evaluate(context(trackB, trackC, bcPlanJunkie, .junkie))
        expect("152.47 → 147 is out of Wedding's 2% budget", bcWedding.cost > 0.5)
        expect("152.47 → 147 is inside Junkie's 6% budget", bcJunkie.cost < 0.35)
        note("  real tempo 152.47→147: Wedding cost \(String(format: "%.3f", bcWedding.cost)), Junkie cost \(String(format: "%.3f", bcJunkie.cost))")

        let harmonic = HarmonicTerm()
        let abHarmonic = harmonic.evaluate(context(trackA, trackB, abPlan, .weddingDJ))
        let baPlan = plan(outgoing: trackB, incoming: trackA, exitAt: 260, profile: .weddingDJ)
        let baHarmonic = harmonic.evaluate(context(trackB, trackA, baPlan, .weddingDJ))
        expect("7A → 2A is a real key clash", abHarmonic.cost >= 0.85)
        expect("the harmonic cost is direction-independent", near(abHarmonic.cost, baHarmonic.cost, 1e-9))

        let genre = GenreTerm()
        let genreResult = genre.evaluate(context(trackA, trackB, abPlan, .weddingDJ))
        expect("genre at real-world title-only confidence barely moves the score",
               genreResult.confidence < 0.01)
        note("  real genre A→B: cost \(String(format: "%.2f", genreResult.cost)), κ \(String(format: "%.4f", genreResult.confidence)) — negligible by design")

        func rankOnce() -> PlanningResult {
            var rng = SeededGenerator(["real-analysed-verification", trackC.trackId, "0"])
            return DJPlanner.plan(
                outgoing: trackC, candidates: [trackA, trackB], profile: .junkie,
                templates: DJTemplates.v1Registry, scoring: DJTerms.v1Registry,
                capabilities: .v1MixEngine, history: .empty, rng: &rng
            )
        }
        let first = rankOnce()
        let second = rankOnce()
        expect("real-track planning is deterministic", first == second)
        expect("real-track planning finds at least one candidate plan", !first.ranked.isEmpty)
        if let best = first.ranked.first {
            expect("every real-data score stays finite and in 0...1",
                   best.score.isFinite && best.score >= 0 && best.score <= 1)
            note("  real-track Junkie best: \(best.plan.templateId.rawValue) into \(best.plan.incomingTrackId), score \(String(format: "%.3f", best.score))")
            note("    \(best.rationale.reasoning)")
        }
    }
}
#endif
