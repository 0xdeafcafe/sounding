#if DEBUG
import Foundation
import AVFoundation
import XCTest
@testable import SoundingTV

final class AutoMixMovesTests: XCTestCase {

    @MainActor
    func testMoveHarness() async throws {
        let harness = AutoMixMoveHarness()
        let report = try await harness.run()
        let failures = AutoMixMoveGates.evaluate(report)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    @MainActor
    func testRealMusicPack() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["AUTOMIX_REAL_SRC"], let output = env["AUTOMIX_REAL_OUT"] else {
            throw XCTSkip("set AUTOMIX_REAL_SRC and AUTOMIX_REAL_OUT")
        }
        let lines = try await AutoMixRealPack(source: URL(fileURLWithPath: source), output: URL(fileURLWithPath: output)).run()
        print(lines.joined(separator: "\n"))
    }

    func testRealMusicLoopMixPack() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["AUTOMIX_REAL_SRC"], let output = env["AUTOMIX_REAL_OUT"] else {
            throw XCTSkip("set AUTOMIX_REAL_SRC and AUTOMIX_REAL_OUT")
        }
        let lines = try await AutoMixRealPack(source: URL(fileURLWithPath: source), output: URL(fileURLWithPath: output)).runLoopMix()
        print(lines.joined(separator: "\n"))
    }

    func testPersonalityMoveDistribution() throws {
        let tracks = AutoMixMovePlaylist.tracks()
        var lines: [String] = []
        var failures: [String] = []
        var junkieLoops = 0
        var junkieKinds = Set<String>()
        for profile in DJProfile.all {
            var history = SetHistory()
            var used: [String] = []
            var loops = 0
            for index in 0..<(tracks.count - 1) {
                let plan = DJSessionDirector.decidePlan(
                    outgoing: tracks[index],
                    candidates: [tracks[index + 1]],
                    profile: profile,
                    history: history,
                    userTransitionSeconds: nil
                )
                let kind = plan.map(AutoMixMovePlaylist.label) ?? "none"
                used.append(kind)
                if ProcessInfo.processInfo.environment["AUTOMIX_DEBUG"] != nil || profile.id == .automatic {
                    let ranked = PhantomDJEngine.rank(PhantomDJEngine.PlanningInputs(outgoing: tracks[index], candidates: [tracks[index + 1]], profile: profile, history: history, seedComponents: ["debug"]))
                    var seen = Set<TransitionTemplateID>()
                    let top = ranked.ranked.filter { seen.insert($0.plan.templateId).inserted }.prefix(8)
                    lines.append("  \(profile.displayName) \(tracks[index].trackId)→\(tracks[index + 1].trackId): " + top.map { "\($0.plan.templateId.rawValue)=\(String(format: "%.2f", $0.score))" }.joined(separator: " "))
                    if let low = top.first(where: { $0.plan.templateId == DJMoveIDs.dropOnTheOne }) {
                        lines.append("    why: " + low.rationale.concerns.map { "\($0.termId.rawValue):\(String(format: "%.2f", $0.weightedCost)) \($0.explanation)" }.joined(separator: " | ") + " exit=\(low.plan.exit.seconds) entry=\(low.plan.entry.seconds) kinds=\(low.plan.exit.kind)→\(low.plan.entry.kind)")
                    }
                }
                if plan?.move?.kind == .loopRoll { loops += 1 }
                history = SetHistory(
                    recentTemplates: ([plan?.templateId].compactMap { $0 } + history.recentTemplates).prefix(8).map { $0 },
                    recentMoves: ([plan?.move?.kind].compactMap { $0 } + history.recentMoves).prefix(8).map { $0 },
                    loopsThisHour: loops
                )
            }
            lines.append("\(profile.displayName): \(used.joined(separator: ", "))")
            let allowed = AutoMixMovePlaylist.allowed[profile.id] ?? []
            for kind in used where !allowed.contains(kind) {
                failures.append("\(profile.displayName) used \(kind)")
            }
            if profile.id == .junkie {
                junkieLoops = loops
                junkieKinds = Set(used)
            }
        }
        if junkieLoops > DJProfile.junkie.loopsPerHour { failures.append("Junkie looped \(junkieLoops) times in an hour") }
        if junkieKinds.count < 3 { failures.append("Junkie only used \(junkieKinds.sorted())") }

        let set = AutoMixMovePlaylist.features(AutoMixMoveFixtures.setJ, labels: AutoMixMovePlaylist.setLabels, boundaries: AutoMixMovePlaylist.setBoundaryBars)
        let jump = DJJumpPlanner.propose(track: set, from: 120, profile: .junkie)
        if let jump {
            lines.append("Junkie jump: \(jump.plan.exit.seconds) → \(jump.plan.entry.seconds), \(jump.plan.move?.jumpBars ?? 0) bars, \(jump.reason)")
            if (jump.plan.move?.jumpBars ?? 0) < DJMoveSupport.minimumJumpBars { failures.append("jump shorter than 32 bars") }
            for bar in AutoMixMovePlaylist.setBoundaryBars {
                let boundary = AutoMixMoveFixtures.setJTruth.downbeats[bar]
                let clearance = 16 * 4 * 60 / 124.0
                if abs(jump.plan.entry.seconds - boundary) < clearance || abs(jump.plan.exit.seconds - boundary) < clearance {
                    failures.append("jump lands inside the set's own transition at bar \(bar)")
                }
            }
        } else {
            failures.append("Junkie found no jump in the set")
        }
        if DJJumpPlanner.propose(track: set, from: 120, profile: .automaticDJ) != nil { failures.append("Auto Mix jumped") }
        if DJJumpPlanner.propose(track: set, from: 120, profile: .weddingDJ) != nil { failures.append("Wedding DJ jumped") }

        print(lines.joined(separator: "\n"))
        XCTAssertTrue(failures.isEmpty, (failures + lines).joined(separator: "\n"))
    }

    @MainActor
    func testSafetyRails() throws {
        let a = AutoMixMovePlaylist.features(AutoMixFixtures.houseA, labels: AutoMixMovePlaylist.houseALabels)
        let f = AutoMixMovePlaylist.features(AutoMixMoveFixtures.clashF, labels: [])
        let plans = PhantomDJEngine.rank(PhantomDJEngine.PlanningInputs(
            outgoing: a, candidates: [f], profile: AutoMixMoveHarness.profile, seedComponents: ["rails"]
        ))
        let bar = a.beatGrid?.barDuration ?? 2
        for scored in plans.ranked where scored.score > 0 {
            let window = DJMoveSupport.overlapWindow(scored.plan, outgoing: a)
            XCTAssertLessThanOrEqual(window.length / bar, 4.05, "\(scored.plan.templateId) blends \(window.length / bar) bars across a key clash")
        }
        XCTAssertTrue(plans.ranked.contains { $0.score > 0 && ($0.plan.move?.kind == .echoOut || $0.plan.move?.kind == .cut || $0.plan.templateId == DJTemplates.cutOnTheOne) })

        let dry = AutoMixMovePlaylist.features(AutoMixFixtures.houseA, labels: AutoMixMovePlaylist.houseALabels)
        let drop = AutoMixMovePlaylist.features(AutoMixMoveFixtures.dropH, labels: AutoMixMovePlaylist.dropLabels)
        let spent = PhantomDJEngine.rank(PhantomDJEngine.PlanningInputs(
            outgoing: dry, candidates: [drop], profile: AutoMixMoveHarness.profile,
            history: SetHistory(loopsThisHour: 2), seedComponents: ["loops"]
        ))
        XCTAssertFalse(spent.ranked.contains { $0.score > 0 && $0.plan.move?.kind == .loopRoll }, "loops beyond the hourly budget")

        for scored in spent.ranked where scored.plan.move?.kind == .loopRoll {
            XCTAssertLessThanOrEqual(scored.plan.move?.repeatedBars ?? 0, 16)
        }

        let bpmOnly = TrackFeatures(trackId: "x", duration: 240, beatGrid: BeatGrid.tempoOnly(124), provenance: [.measuredTempo])
        let bpmOnlyIn = TrackFeatures(trackId: "y", duration: 240, beatGrid: BeatGrid.tempoOnly(124), provenance: [.measuredTempo])
        let unmeasured = PhantomDJEngine.rank(PhantomDJEngine.PlanningInputs(
            outgoing: bpmOnly, candidates: [bpmOnlyIn], profile: AutoMixMoveHarness.profile, seedComponents: ["grid"]
        ))
        XCTAssertFalse(unmeasured.ranked.contains { $0.plan.move != nil && $0.score > 0 }, "a move without measured downbeats")
    }
}

enum AutoMixMoveFixtures {
    static let dropH = MixFixtureSpec(
        id: "drop-h", duration: 230, bpmStart: 124, bpmEnd: 124, firstDownbeat: 0.05, pickupBeats: 0,
        keyPitchClass: 4, isMinor: true, introBars: 16, outroBars: 16,
        vocalBars: [56...71], breakdownBars: [32...39, 80...87]
    )
    static let halfL = MixFixtureSpec(
        id: "half-l", duration: 240, bpmStart: 87, bpmEnd: 87, firstDownbeat: 0.1, pickupBeats: 0,
        keyPitchClass: 9, isMinor: true, introBars: 8, outroBars: 8,
        vocalBars: [], breakdownBars: [40...43]
    )
    static let dnbK = MixFixtureSpec(
        id: "dnb-k", duration: 200, bpmStart: 174, bpmEnd: 174, firstDownbeat: 0.07, pickupBeats: 0,
        keyPitchClass: 9, isMinor: true, introBars: 16, outroBars: 16,
        vocalBars: [], breakdownBars: [64...71]
    )
    static let setJ = MixFixtureSpec(
        id: "set-j", duration: 1200, bpmStart: 122, bpmEnd: 126, firstDownbeat: 0.12, pickupBeats: 0,
        keyPitchClass: 9, isMinor: true, introBars: 16, outroBars: 16,
        vocalBars: [40...71, 200...231, 380...411], breakdownBars: [148...155, 296...303, 452...459]
    )
    static let clashF = MixFixtureSpec(
        id: "clash-f", duration: 230, bpmStart: 124, bpmEnd: 124, firstDownbeat: 0.05, pickupBeats: 0,
        keyPitchClass: 6, isMinor: false, introBars: 16, outroBars: 16,
        vocalBars: [], breakdownBars: [64...71]
    )

    static let setJTruth = MixFixtureTruth.make(setJ)
}

enum AutoMixMovePlaylist {
    static let houseALabels: [(Int, SectionKind)] = [(0, .intro), (16, .bridge), (32, .drop), (64, .breakdown), (72, .drop), (108, .outro)]
    static let houseBLabels: [(Int, SectionKind)] = [(0, .intro), (16, .bridge), (24, .drop), (56, .breakdown), (64, .drop), (103, .outro)]
    static let dropLabels: [(Int, SectionKind)] = [(0, .intro), (16, .bridge), (32, .buildup), (40, .drop), (72, .bridge), (80, .breakdown), (88, .drop), (102, .outro)]
    static let setLabels: [(Int, SectionKind)] = [(0, .intro), (16, .drop), (100, .bridge), (140, .breakdown), (160, .drop), (240, .bridge), (290, .breakdown), (312, .drop), (400, .bridge), (444, .breakdown), (464, .drop), (600, .outro)]
    static let setBoundaryBars = [148, 296, 452]

    static let allowed: [DJProfileID: Set<String>] = [
        .wedding: ["blend", "cut", "echoOut"],
        .automatic: ["blend", "cut", "echoOut", "breakdownExit", "dropIn", "dropOnTheOne", "fxBuild.filterSweep", "fxBuild.echo"],
        .junkie: Set(["blend", "cut", "echoOut", "breakdownExit", "dropIn", "dropOnTheOne", "loopRoll", "fxBuild.filterSweep", "fxBuild.echo", "fxBuild.reverbWash", "tempoRamp", "bridge"])
    ]

    static func label(_ plan: PhantomDJEngine.Plan) -> String {
        if let move = plan.move {
            return move.kind == .fxBuild ? "fxBuild.\(move.effect.rawValue)" : move.kind.rawValue
        }
        switch plan.templateId {
        case DJTemplates.cutOnTheOne: return "cut"
        case DJTemplates.echoOut: return "echoOut"
        case DJTemplates.loopRollDown: return "loopRoll"
        case DJTemplates.tempoRampBlend: return "tempoRamp"
        case DJTemplates.halfTimeBlend: return "bridge"
        case DJTemplates.doubleDrop: return "dropIn"
        default: return "blend"
        }
    }

    static func tracks() -> [TrackFeatures] {
        [
            features(AutoMixFixtures.houseA, labels: houseALabels),
            features(AutoMixMoveFixtures.dropH, labels: dropLabels),
            features(AutoMixFixtures.houseB, labels: houseBLabels),
            features(AutoMixFixtures.houseG, labels: houseALabels),
            features(AutoMixMoveFixtures.clashF, labels: houseALabels),
            features(AutoMixFixtures.pickupC, labels: houseBLabels),
            features(AutoMixMoveFixtures.dropH, labels: dropLabels, id: "drop-h-2", dropCue: true),
            features(AutoMixFixtures.houseA, labels: houseALabels, id: "house-a-2"),
            features(AutoMixFixtures.houseG, labels: houseALabels, id: "house-g-2"),
            features(AutoMixMoveFixtures.dropH, labels: dropLabels, id: "drop-h-3"),
            features(AutoMixFixtures.houseB, labels: houseBLabels, id: "house-b-2")
        ]
    }

    static func features(
        _ spec: MixFixtureSpec,
        labels: [(Int, SectionKind)],
        id: String? = nil,
        boundaries: [Int] = [],
        dropCue: Bool = false
    ) -> TrackFeatures {
        let truth = MixFixtureTruth.make(spec)
        let bucketCount = max(8, Int(spec.duration.rounded()))
        var envelope = [Float](repeating: 0.85, count: bucketCount)
        for bars in spec.breakdownBars {
            let lower = bars.lowerBound < truth.downbeats.count ? truth.downbeats[bars.lowerBound] : spec.duration
            let upper = bars.upperBound + 1 < truth.downbeats.count ? truth.downbeats[bars.upperBound + 1] : spec.duration
            for i in 0..<bucketCount where Double(i) >= lower && Double(i) < upper { envelope[i] = 0.35 }
        }
        let sections: [TrackSection] = labels.enumerated().compactMap { index, label in
            guard label.0 < truth.downbeats.count else { return nil }
            let start = truth.downbeats[label.0]
            let end = index + 1 < labels.count && labels[index + 1].0 < truth.downbeats.count ? truth.downbeats[labels[index + 1].0] : spec.duration
            return TrackSection(kind: label.1, start: start, end: end)
        }
        var phrases: [TimeInterval] = []
        var index = 0
        while index < truth.downbeats.count { phrases.append(truth.downbeats[index]); index += 8 }
        var provenance: FeatureProvenance = [.measuredTempo, .measuredBeatGrid, .measuredDownbeats, .measuredKey, .measuredVocals, .measuredBass, .envelopeOnly]
        if !sections.isEmpty { provenance.insert(.measuredStructure) }
        return TrackFeatures(
            trackId: id ?? spec.id,
            title: id ?? spec.id,
            artist: "fixture",
            duration: spec.duration,
            beatGrid: BeatGrid.fromMeasuredBars(bpm: spec.meanBPM, beats: truth.beats, bars: truth.downbeats, confidence: 0.85),
            keyRegions: [KeyRegion(key: spec.camelot, start: 0, end: spec.duration)],
            sections: sections,
            phraseBoundaries: phrases,
            energyLevel: 7,
            envelope: envelope,
            vocalRanges: truth.vocalRanges,
            bassRanges: truth.bassRanges,
            provenance: provenance,
            cueHints: dropCue ? sections.filter { $0.kind == .drop }.prefix(1).map { CueHint(seconds: $0.start, role: .entry, confidence: 0.9, label: "Drop") } : [],
            boundaries: boundaries.compactMap { $0 < truth.downbeats.count ? truth.downbeats[$0] : nil }
        )
    }

    @MainActor
    static func prep(_ fixture: MixFixture, _ labels: [(Int, SectionKind)]) -> TrackPrep {
        var prep = TrackPrep(trackId: MixRenderer.track(for: fixture).id)
        let phrases = labels.compactMap { bar, kind -> PrepPhrase? in
            guard bar < fixture.truth.downbeats.count else { return nil }
            return PrepPhrase(startMillis: Int64((fixture.truth.downbeats[bar] * 1000).rounded()), kind: kind, mood: nil)
        }
        prep.phrases = PrepField(phrases, source: .user)
        return prep
    }
}

@MainActor
final class AutoMixMoveHarness {
    let outputDirectory: URL
    let label: String

    static let profile: DJProfile = {
        let j = DJProfile.junkie
        return DJProfile(
            id: j.id, displayName: "Harness", blurb: j.blurb,
            exitRegionFloor: j.exitRegionFloor, allowMidTrackExit: j.allowMidTrackExit,
            entryRegionCeiling: j.entryRegionCeiling, minimumPlayFraction: j.minimumPlayFraction,
            admissibleTemplates: j.admissibleTemplates.union(DJMoveIDs.all),
            repeatTemplateCooldown: j.repeatTemplateCooldown,
            maxAbsRatePercent: j.maxAbsRatePercent, allowVarispeed: j.allowVarispeed,
            requireMeasuredBPMForRate: j.requireMeasuredBPMForRate, maxDriftMs: j.maxDriftMs,
            minGridConfidence: j.minGridConfidence, maxCamelotSteps: j.maxCamelotSteps,
            allowEnergyBoost: j.allowEnergyBoost, genreCeiling: j.genreCeiling,
            mayReorderQueue: false, lookaheadCandidates: 1,
            analysisBudgetPerTrack: j.analysisBudgetPerTrack, maxLoopBars: j.maxLoopBars,
            maxLoopHalvings: j.maxLoopHalvings, weights: j.weights,
            minimumScoreToFire: j.minimumScoreToFire, transitionBarsRange: j.transitionBarsRange,
            energyStepLimit: j.energyStepLimit, timbreTargetDistance: j.timbreTargetDistance,
            honoursUserTransitionLength: false
        )
    }()

    init() {
        let env = ProcessInfo.processInfo.environment
        let base = env["AUTOMIX_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("automix-c", isDirectory: true)
        outputDirectory = base
        label = env["AUTOMIX_LABEL"] ?? "moves"
    }

    static let deadlineBarsLeft = 6

    func run() async throws -> AutoMixReport {
        let fixtureDirectory = outputDirectory.appendingPathComponent("fixtures", isDirectory: true)
        let runDirectory = outputDirectory.appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        let specs = [AutoMixFixtures.houseA, AutoMixFixtures.houseB, AutoMixFixtures.houseG, AutoMixFixtures.liveSetD,
                     AutoMixMoveFixtures.dropH, AutoMixMoveFixtures.halfL, AutoMixMoveFixtures.dnbK, AutoMixMoveFixtures.setJ]
        var fixtures: [String: MixFixture] = [:]
        for spec in specs {
            fixtures[spec.id] = try MixFixtureFactory.fixture(spec, in: fixtureDirectory)
        }
        let a = fixtures[AutoMixFixtures.houseA.id]!
        let b = fixtures[AutoMixFixtures.houseB.id]!
        let g = fixtures[AutoMixFixtures.houseG.id]!
        let d = fixtures[AutoMixFixtures.liveSetD.id]!
        let h = fixtures[AutoMixMoveFixtures.dropH.id]!
        let l = fixtures[AutoMixMoveFixtures.halfL.id]!
        let k = fixtures[AutoMixMoveFixtures.dnbK.id]!
        let j = fixtures[AutoMixMoveFixtures.setJ.id]!

        let aPrep = AutoMixMovePlaylist.prep(a, AutoMixMovePlaylist.houseALabels)
        let bPrep = AutoMixMovePlaylist.prep(b, AutoMixMovePlaylist.houseBLabels)
        let hPrep = AutoMixMovePlaylist.prep(h, AutoMixMovePlaylist.dropLabels)
        let jPrep = AutoMixMovePlaylist.prep(j, AutoMixMovePlaylist.setLabels)
        let profile = Self.profile

        func scenario(_ name: String, _ out: MixFixture, _ inc: MixFixture, _ template: TransitionTemplateID, outPrep: TrackPrep? = nil, inPrep: TrackPrep? = nil) -> MixRenderer.Scenario {
            var s = MixRenderer.Scenario(name: name, outgoing: out, incoming: inc, profile: profile, template: template)
            s.outgoingPrep = outPrep ?? (out.spec.id == a.spec.id ? aPrep : nil)
            s.incomingPrep = inPrep ?? (inc.spec.id == h.spec.id ? hPrep : (inc.spec.id == b.spec.id ? bPrep : nil))
            s.userTransitionSeconds = nil
            s.preRoll = 32
            return s
        }

        var dryLoop = scenario("loop-roll-dry", a, h, DJMoveIDs.loopRoll)
        dryLoop.customPlan = { outgoing, incoming in
            guard let plan = MixRenderer.plan(scenario: scenario("loop-roll", a, h, DJMoveIDs.loopRoll), outgoing: outgoing, incoming: incoming) else { return nil }
            return plan.replacingMove(.loopRoll(MixMove.standardLadder, effect: .none))
        }

        var jumpSet = MixRenderer.Scenario(name: "jump-set", outgoing: j, incoming: j, profile: profile)
        jumpSet.outgoingPrep = jPrep
        jumpSet.incomingPrep = jPrep
        jumpSet.outgoingBoundaries = AutoMixMovePlaylist.setBoundaryBars.map { j.truth.downbeats[$0] }
        jumpSet.userTransitionSeconds = nil
        jumpSet.customPlan = { outgoing, _ in
            DJJumpPlanner.propose(track: outgoing, from: 120, profile: profile).map { $0.executablePlan(outgoing) }
        }

        var jumpTrack = MixRenderer.Scenario(name: "jump-track", outgoing: d, incoming: d, profile: profile)
        jumpTrack.userTransitionSeconds = nil
        jumpTrack.customPlan = { outgoing, _ in
            DJJumpPlanner.propose(track: outgoing, from: 30, profile: profile).map { $0.executablePlan(outgoing) }
        }

        var riserLoop = scenario("riser-loop-roll", a, h, DJMoveIDs.loopRoll)
        riserLoop.riserLevel = 1
        var riserFilter = scenario("riser-filter-build", a, h, DJMoveIDs.filterBuild)
        riserFilter.riserLevel = SettingKeys.DJRiserLevel.defaultValue
        var riserDrop = scenario("riser-drop-in", a, h, DJMoveIDs.dropIn)
        riserDrop.riserLevel = SettingKeys.DJRiserLevel.defaultValue

        func deadline(_ name: String, loops: Bool) -> MixRenderer.Scenario {
            var s = scenario(name, a, b, DJMoveIDs.blend)
            s.loopsOnDeadline = loops
            let downbeats = a.truth.downbeats
            s.customPlan = { outgoing, incoming in
                guard downbeats.count > 12,
                      let plan = MixRenderer.plan(scenario: scenario("bass-swap", a, b, DJMoveIDs.blend), outgoing: outgoing, incoming: incoming) else { return nil }
                return plan.shifted(mixPoint: downbeats[downbeats.count - Self.deadlineBarsLeft - 1]).replacingMove(.blend(bars: 16))
            }
            return s
        }

        var lateLoad = deadline("deadline-late", loops: true)
        let lateDownbeats = a.truth.downbeats
        let lateStartIndex = max(0, lateDownbeats.count - 9)
        if lateDownbeats.count > 12 {
            let start = lateDownbeats[lateStartIndex]
            let length = lateDownbeats[lateStartIndex + 8] - start
            lateLoad.preLoop = (start, length, start + 0.1)
            lateLoad.beginAfterSeconds = 12
            lateLoad.customPlan = { outgoing, incoming in
                MixRenderer.plan(scenario: scenario("bass-swap", a, b, DJMoveIDs.blend), outgoing: outgoing, incoming: incoming)?
                    .shifted(mixPoint: start).replacingMove(.blend(bars: 16))
            }
        }

        let scenarios: [MixRenderer.Scenario] = [
            scenario("bass-swap", a, b, DJMoveIDs.blend),
            scenario("cut", a, b, DJMoveIDs.cut),
            scenario("echo-out", a, b, DJMoveIDs.echoOut),
            scenario("breakdown-exit", a, b, DJMoveIDs.breakdownExit),
            scenario("drop-in", a, h, DJMoveIDs.dropIn),
            scenario("drop-on-the-one", a, h, DJMoveIDs.dropOnTheOne),
            scenario("loop-roll", a, h, DJMoveIDs.loopRoll),
            dryLoop,
            scenario("filter-build", a, h, DJMoveIDs.filterBuild),
            scenario("echo-build", a, h, DJMoveIDs.echoBuild),
            scenario("reverb-wash", a, h, DJMoveIDs.reverbWash),
            scenario("tempo-ramp", a, g, DJMoveIDs.tempoRamp),
            scenario("bridge", l, k, DJMoveIDs.bridge),
            jumpSet,
            jumpTrack,
            riserLoop,
            riserFilter,
            riserDrop,
            deadline("deadline-loop", loops: true),
            lateLoad,
            deadline("deadline-control", loops: false)
        ]

        var report = AutoMixReport(label: label)
        let renderer = MixRenderer()
        let only = ProcessInfo.processInfo.environment["AUTOMIX_ONLY"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map(String.init)) }
        for scenario in scenarios where only?.contains(scenario.name) ?? true {
            do {
                let result = try renderer.render(scenario)
                var (metrics, notes) = AutoMixAnalysis.metrics(for: result)
                let (moveMetrics, moveNotes) = AutoMixMoveAnalysis.metrics(for: result)
                metrics.merge(moveMetrics) { _, new in new }
                notes.merge(moveNotes) { _, new in new }
                report.scenarios[scenario.name] = metrics
                report.notes[scenario.name] = notes
                try AutoMixAnalysis.writeWav(result, to: runDirectory.appendingPathComponent("\(scenario.name).wav"))
            } catch {
                report.notes[scenario.name] = ["error": String(describing: error)]
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sanitized = AutoMixReport(
            label: report.label,
            scenarios: report.scenarios.mapValues { $0.mapValues { $0.isFinite ? $0 : -999 } },
            notes: report.notes,
            analyzer: [:]
        )
        try encoder.encode(sanitized).write(to: runDirectory.appendingPathComponent("report.json"))
        let markdown = AutoMixAnalysis.markdown(report)
        try markdown.write(to: runDirectory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        print("AUTOMIX_REPORT_DIR=\(runDirectory.path)")
        print(markdown)
        return report
    }
}

struct AutoMixRealPack {
    let source: URL
    let output: URL

    enum Deadline {
        case none
        case shortOutro
        case lateLoad
    }

    struct Case {
        let name: String
        let out: String
        let inc: String
        let move: MixMove?
        let template: TransitionTemplateID
        let riser: Double
        var deadline: Deadline = .none
        let note: String
    }

    static let cases: [Case] = [
        Case(name: "1-blend", out: "jungle", inc: "voodoo", move: .blend(bars: 16), template: DJMoveIDs.blend, riser: 0, note: "16-bar blend with bass swap, no riser"),
        Case(name: "2-riser-drop-in", out: "pretend", inc: "marionette", move: .dropIn(buildBars: 8), template: DJMoveIDs.dropIn, riser: 0.5, note: "drop-in, 8-bar riser at the default level"),
        Case(name: "3-riser-loop-build", out: "arise", inc: "darkknight", move: .loopRoll(MixMove.standardLadder), template: DJMoveIDs.loopRoll, riser: 0.5, note: "loop build 8-4-2-1-1 with filter sweep, riser over the last 8 bars"),
        Case(name: "4-riser-filter-build", out: "finally", inc: "domino", move: .fxBuild(.filterSweep, bars: 8), template: DJMoveIDs.filterBuild, riser: 0.5, note: "8-bar filter build into a cut, riser at the default level"),
        Case(name: "5-riser-loud-echo-build", out: "darkknight", inc: "mercura", move: .fxBuild(.echo, bars: 8), template: DJMoveIDs.echoBuild, riser: 1, note: "8-bar echo build, riser at the loudest setting"),
        Case(name: "6-deadline-short-outro", out: "voodoo", inc: "pretend", move: .blend(bars: 16), template: DJMoveIDs.blend, riser: 0, deadline: .shortOutro, note: "16-bar blend starting 6 bars before the end; the last clean phrase loops so the outgoing never runs out"),
        Case(name: "7-deadline-late-load", out: "marionette", inc: "arise", move: .blend(bars: 16), template: DJMoveIDs.blend, riser: 0, deadline: .lateLoad, note: "next track was late: the last 8 bars were already looping; the blend starts on the next pass of the loop")
    ]

    @MainActor
    func run() async throws -> [String] {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var fixtures: [String: MixFixture] = [:]
        var trackedResults: [String: BeatTrackerResult] = [:]
        var lines: [String] = []
        let only = ProcessInfo.processInfo.environment["AUTOMIX_REAL_ONLY"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map(String.init)) }
        let selected = Self.cases.filter { only?.contains($0.name) ?? true }
        let ids = Set(selected.flatMap { [$0.out, $0.inc] })
        for id in ids.sorted() {
            let url = source.appendingPathComponent("\(id).wav")
            let fixture = try await Self.fixture(id: id, url: url)
            fixtures[id] = fixture
            let tracked = try await Self.analyze(url)
            trackedResults[id] = tracked
            lines.append("TRACK|\(id)|\(String(format: "%.1f", fixture.spec.meanBPM))|\(fixture.truth.downbeats.count)|\(Int(fixture.spec.duration))")
            let ranges = (tracked.vocalSeconds ?? []).map { String(format: "%.1f-%.1f", $0.lowerBound, $0.upperBound) }
            lines.append("VOCALS|\(id)|\(tracked.vocalRanges == nil ? "unmeasured" : ranges.joined(separator: " "))")
        }
        let renderer = MixRenderer()
        for item in selected {
            guard let a = fixtures[item.out], let b = fixtures[item.inc] else { continue }
            var scenario = MixRenderer.Scenario(name: item.name, outgoing: a, incoming: b, profile: .junkie, template: item.template)
            if let tracked = trackedResults[item.out] { scenario.outgoingAnalysis = .tracked(tracked, legacy: nil) }
            if let tracked = trackedResults[item.inc] { scenario.incomingAnalysis = .tracked(tracked, legacy: nil) }
            scenario.userTransitionSeconds = nil
            scenario.preRoll = 32
            scenario.riserLevel = item.riser
            scenario.rendersStems = false
            let downbeats = a.truth.downbeats
            let outgoingAnalysis = scenario.outgoingAnalysis
            let incomingAnalysis = scenario.incomingAnalysis
            let template = item.template
            let move = item.move
            let name = item.name
            let base: @MainActor (TrackFeatures, TrackFeatures) -> PhantomDJEngine.Plan? = { outgoing, incoming in
                var probe = MixRenderer.Scenario(name: name, outgoing: a, incoming: b, profile: .junkie, template: template)
                probe.outgoingAnalysis = outgoingAnalysis
                probe.incomingAnalysis = incomingAnalysis
                probe.userTransitionSeconds = nil
                let planned = MixRenderer.plan(scenario: probe, outgoing: outgoing, incoming: incoming)
                    ?? DJSessionDirector.decidePlan(outgoing: outgoing, candidates: [incoming], profile: .junkie, history: .empty, userTransitionSeconds: nil)
                guard let planned else { return nil }
                return move.map { planned.replacingMove($0) } ?? planned
            }
            switch item.deadline {
            case .none:
                if let move, move.kind == .blend {
                    let bars = move.phraseBars
                    scenario.customPlan = { outgoing, incoming in
                        guard let plan = base(outgoing, incoming) else { return nil }
                        let clean = Self.vocalClean(plan, outgoing: outgoing, incoming: incoming, bars: bars)
                        Self.notes.append("MIXPOINT|\(name)|exit \(String(format: "%.2f", clean.mixPointSeconds)) entry \(String(format: "%.2f", clean.entrySeconds)) (planner \(String(format: "%.2f", plan.mixPointSeconds)) / \(String(format: "%.2f", plan.entrySeconds)))")
                        Self.notes.append("VOCALWIN|\(name)|outgoing vocal s in window \(String(format: "%.2f", DJMoveSupport.vocalSeconds(outgoing, clean.mixPointSeconds...(clean.mixPointSeconds + Double(bars) * (outgoing.beatGrid?.barDuration ?? 2))))) incoming \(String(format: "%.2f", DJMoveSupport.vocalSeconds(incoming, clean.entrySeconds...(clean.entrySeconds + Double(bars) * (incoming.beatGrid?.barDuration ?? 2))))) ")
                        return clean
                    }
                } else {
                    scenario.customPlan = base
                }
            case .shortOutro:
                guard downbeats.count > 16 else { continue }
                let point = downbeats[downbeats.count - AutoMixMoveHarness.deadlineBarsLeft - 1]
                scenario.customPlan = { base($0, $1)?.shifted(mixPoint: point) }
            case .lateLoad:
                guard downbeats.count > 16,
                      let loop = MixDeadlineLoop.lastCleanPhrase(downbeats: downbeats, duration: a.spec.duration, playhead: 0) else { continue }
                let index = downbeats.firstIndex { abs($0 - loop.startSeconds) < 0.002 } ?? 0
                scenario.preLoop = (loop.startSeconds, loop.lengthSeconds, downbeats[min(downbeats.count - 1, index)] + 0.1)
                scenario.beginAfterSeconds = 10
                scenario.customPlan = { base($0, $1)?.shifted(mixPoint: loop.startSeconds) }
            }
            do {
                let result = try renderer.render(scenario)
                let url = output.appendingPathComponent("\(item.name).wav")
                try AutoMixAnalysis.writeWav(result, to: url)
                let begin = result.mix.beginTime ?? 0
                let clipStart = max(0, begin - 10)
                var start = begin + result.mix.leadSeconds
                var landing = start
                if let move = result.plan.move, let builder = AutoMixMoveAnalysis.builder(result, rateA: 1) {
                    landing = start + builder.wall(move.landingBar) - builder.offset0
                }
                if item.deadline == .lateLoad, let loopStart = result.mix.deadlineLoopStart, let length = result.mix.deadlineLoopLength {
                    start = loopStart + length - result.mix.startSourceA
                    landing = start
                }
                let finish = result.mix.finishTime ?? landing
                func stamp(_ t: TimeInterval) -> String {
                    let x = max(0, t - clipStart)
                    return String(format: "%d:%04.1f", Int(x) / 60, x.truncatingRemainder(dividingBy: 60))
                }
                var extra = ""
                if let length = result.mix.deadlineLoopLength, let loopStart = result.mix.deadlineLoopStart {
                    let bar = 4 * a.truth.localBeatPeriod(at: loopStart)
                    extra = "; loops the \(Int((length / bar).rounded()))-bar phrase at \(String(format: "%.1f", loopStart)) s of the outgoing"
                }
                lines.append("PACK|\(item.name)|\(item.out)|\(item.inc)|\(result.plan.move?.displayName ?? "plan")|\(stamp(start))|\(stamp(landing))|\(stamp(finish))|\(item.note)\(extra)|\(url.path)")
            } catch {
                lines.append("PACK-ERROR|\(item.name)|\(error)")
            }
        }
        lines.append(contentsOf: Self.notes)
        Self.notes = []
        return lines
    }

    @MainActor static var notes: [String] = []

    static func vocalClean(_ plan: PhantomDJEngine.Plan, outgoing: TrackFeatures, incoming: TrackFeatures, bars: Int) -> PhantomDJEngine.Plan {
        guard DJMoveSupport.vocalsMeasured(outgoing, incoming),
              let outGrid = outgoing.beatGrid, let inGrid = incoming.beatGrid else { return plan }
        let outBars = outGrid.downbeats ?? []
        let inBars = inGrid.downbeats ?? []
        guard outBars.count > bars + 2, inBars.count > bars + 2 else { return plan }
        let outLength = Double(bars) * outGrid.barDuration
        let inLength = Double(bars) * inGrid.barDuration
        let margin = 0.25
        func outClean(_ exit: TimeInterval) -> Bool {
            exit + outLength <= outgoing.duration - 2 * outGrid.barDuration
                && DJMoveSupport.vocalSeconds(outgoing, exit...(exit + outLength)) < margin
        }
        func inClean(_ entry: TimeInterval) -> Bool {
            DJMoveSupport.vocalSeconds(incoming, entry...(entry + inLength)) < margin
        }
        let exits = stride(from: 0, to: outBars.count, by: 8).map { outBars[$0] }.filter { $0 > outgoing.duration * 0.5 }
        let entries = stride(from: 0, to: inBars.count, by: 8).map { inBars[$0] }.filter { $0 < incoming.duration * 0.5 }
        guard let entry = entries.first(where: inClean) ?? entries.first,
              let exit = exits.last(where: outClean) else { return plan }
        return PhantomDJEngine.Plan(
            mixPointSeconds: exit,
            transitionSeconds: plan.transitionSeconds,
            outroShape: plan.outroShape,
            accent: plan.accent,
            reasoning: plan.reasoning,
            entrySeconds: entry,
            bassSwapAtSeconds: plan.bassSwapAtSeconds,
            bassSwapSeconds: plan.bassSwapSeconds,
            incomingRateRatio: plan.incomingRateRatio,
            incomingTrackId: plan.incomingTrackId,
            profileId: plan.profileId,
            templateId: plan.templateId,
            rationale: plan.rationale,
            stages: plan.stages,
            outgoingBeatGrid: plan.outgoingBeatGrid,
            incomingBeatGrid: plan.incomingBeatGrid,
            move: plan.move,
            incomingTitle: plan.incomingTitle
        )
    }

    static func analyze(_ url: URL) async throws -> BeatTrackerResult {
        guard let out = ProcessInfo.processInfo.environment["AUTOMIX_REAL_OUT"], !out.isEmpty else { return try await BeatTracker.analyze(fileURL: url) }
        let dir = URL(fileURLWithPath: out).appendingPathComponent("analysis-cache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-v\(BeatTracker.version)p.json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(BeatTrackerResult.self, from: data) { return cached }
        let result = try await BeatTracker.analyze(fileURL: url)
        try? JSONEncoder().encode(result).write(to: file)
        return result
    }

    static func fixture(id: String, url: URL) async throws -> MixFixture {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw MixEngineError.deckEmpty }
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        if let data = buffer.floatChannelData {
            for i in 0..<count {
                left[i] = data[0][i]
                right[i] = data[min(1, channels - 1)][i]
            }
        }
        let sampleRate = file.processingFormat.sampleRate
        let duration = Double(count) / sampleRate
        let tracked = try await Self.analyze(url)
        let bpm = tracked.bpm ?? 124
        let spec = MixFixtureSpec(
            id: id, duration: duration, bpmStart: bpm, bpmEnd: bpm, firstDownbeat: tracked.downbeats.first ?? 0, pickupBeats: 0,
            keyPitchClass: 9, isMinor: true, introBars: 16, outroBars: 16, vocalBars: [], breakdownBars: []
        )
        let truth = MixFixtureTruth(
            spec: spec, beats: tracked.beats, downbeats: tracked.downbeats, barStarts: tracked.downbeats,
            vocalRanges: [], bassRanges: [], kickRanges: []
        )
        var waveform = [Float](repeating: 0, count: 1800)
        for i in 0..<waveform.count {
            let lo = i * count / waveform.count
            let hi = max(lo + 1, min(count, (i + 1) * count / waveform.count))
            var peak: Float = 0
            var j = lo
            while j < hi {
                peak = max(peak, abs(left[j]), abs(right[j]))
                j += 7
            }
            waveform[i] = peak
        }
        let lufs = MixMetrics.integratedLoudness(left: left, right: right, sampleRate: sampleRate)
        return MixFixture(spec: spec, truth: truth, url: url, waveform: waveform, integratedLUFS: lufs)
    }
}

extension AutoMixRealPack {
    static let loopPairs: [(String, String, String)] = [
        ("1-loopmix", "jungle", "voodoo"),
        ("2-loopmix", "pretend", "marionette"),
        ("6-loopmix", "voodoo", "pretend"),
        ("8-loopmix", "arise", "darkknight"),
        ("9-loopmix", "finally", "domino")
    ]

    @MainActor
    func runLoopMix() async throws -> [String] {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var lines: [String] = []
        var fixtures: [String: MixFixture] = [:]
        var tracked: [String: BeatTrackerResult] = [:]
        let only = ProcessInfo.processInfo.environment["AUTOMIX_REAL_ONLY"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map(String.init)) }
        let pairs = Self.loopPairs.filter { only?.contains($0.0) ?? true }
        for id in Set(pairs.flatMap { [$0.1, $0.2] }).sorted() {
            let url = source.appendingPathComponent("\(id).wav")
            if let t = try? await Self.analyze(url) {
                lines.append(String(format: "CONF|\(id)|bpm %.2f conf %.3f beat %.3f downbeat %.3f clarity %.3f parity %.3f reliable \(t.isPhaseReliable) parity \(t.isParityReliable) evidence drum s/a, change s/a, halfbar s/a \(t.parityEvidence ?? [])", t.bpm ?? 0, t.confidence, t.beatConfidence, t.downbeatConfidence, t.tempoClarity, t.parityConfidence ?? -1))
            }
            fixtures[id] = try await Self.fixture(id: id, url: url)
            let result = try await Self.analyze(url)
            tracked[id] = result
            let ranges = (result.vocalSeconds ?? []).map { String(format: "%.1f-%.1f", $0.lowerBound, $0.upperBound) }
            lines.append("VOCALS|\(id)|\(result.vocalCurve == nil ? "unmeasured" : ranges.joined(separator: " "))")
            if let bars = result.bars {
                lines.append("DENSITY|\(id)|" + bars.density.map { String(Int(($0 * 9).rounded())) }.joined())
                lines.append("LOOP8|\(id)|" + bars.loop8.map { String(Int((max(0, $0) * 9).rounded())) }.joined())
            }
        }
        let renderer = MixRenderer()
        for (name, outId, inId) in pairs {
            guard let a = fixtures[outId], let b = fixtures[inId] else { continue }
            var scenario = MixRenderer.Scenario(name: name, outgoing: a, incoming: b, profile: .automaticDJ, template: DJMoveIDs.loopMix)
            if let t = tracked[outId] { scenario.outgoingAnalysis = .tracked(t, legacy: nil) }
            if let t = tracked[inId] { scenario.incomingAnalysis = .tracked(t, legacy: nil) }
            scenario.userTransitionSeconds = nil
            scenario.preRoll = 32
            scenario.riserLevel = 0
            scenario.rendersStems = true
            var chosen: LoopMixPlanner.Choice?
            var features: (TrackFeatures, TrackFeatures)?
            scenario.customPlan = { outgoing, incoming in
                features = (outgoing, incoming)
                chosen = LoopMixPlanner.choose(outgoing: outgoing, incoming: incoming)
                return DJSessionDirector.decidePlan(outgoing: outgoing, candidates: [incoming], profile: .automaticDJ, history: .empty, userTransitionSeconds: nil)
            }
            do {
                let result = try renderer.render(scenario)
                guard result.plan.move?.kind == .loopMix, let choice = chosen, let (fo, fi) = features else {
                    if let (fo, fi) = features {
                        var counts: [String: Int] = [:]
                        let loose = LoopMixPlanner.choose(outgoing: fo, incoming: fi, requireDownbeats: false) { counts[$0, default: 0] += 1 }
                        lines.append("LOOPMIX-LOOSE|\(name)|rejected \(counts)|without downbeats: \(loose.map { "out bar \($0.outgoing.bar)x\($0.outgoing.bars) in bar \($0.incoming.bar)x\($0.incoming.bars) step \($0.levelStep)" } ?? "none")|windows \(LoopMixPlanner.outgoingWindows(fo).count)/\(LoopMixPlanner.incomingWindows(fi, releaseBars: LoopMixPlanner.fadeOutBars).count)")
                    }
                    lines.append("LOOPMIX-NONE|\(name)|\(outId)→\(inId)|\(features.map { LoopMixPlanner.diagnose(outgoing: $0.0, incoming: $0.1) } ?? "no features")|planner chose \(result.plan.move?.displayName ?? result.plan.templateId?.rawValue ?? "none"): \(result.plan.reasoning)")
                    continue
                }
                let url = output.appendingPathComponent("\(name).wav")
                let measure = try Self.writeLoopPack(result, url: url)
                lines.append(contentsOf: Self.loopGates(name: name, result: result, choice: choice, outgoing: fo, incoming: fi, url: url, measure: measure))
            } catch {
                lines.append("PACK-ERROR|\(name)|\(error)")
            }
        }
        return lines
    }

    static func writeStems(_ result: MixRenderer.Result, base: URL) throws {
        let sr = result.sampleRate
        let begin = result.mix.beginTime ?? 0
        let finish = result.mix.finishTime ?? begin
        let from = max(0, Int((begin - 10) * sr))
        for (suffix, stem) in [("-out", result.stemA), ("-in", result.stemB)] {
            let to = min(stem.count, Int((finish + 15) * sr))
            guard to > from else { continue }
            let url = URL(fileURLWithPath: base.path + suffix + ".wav")
            try? FileManager.default.removeItem(at: url)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(to - from)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            for i in 0..<(to - from) { channel[i] = stem[from + i] }
            buffer.frameLength = AVAudioFrameCount(to - from)
            try file.write(from: buffer)
        }
    }

    struct LoopPackMeasure {
        let clip: TimeInterval
        let input: LoopMixMeasure.Input
        let result: LoopMixMeasure.Result
    }

    static func monoSource(_ url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return [] }
        let channels = Int(buffer.format.channelCount)
        let count = Int(buffer.frameLength)
        var out = [Float](repeating: 0, count: count)
        for c in 0..<channels {
            for i in 0..<count { out[i] += data[c][i] / Float(channels) }
        }
        return out
    }

    static func dryStem(_ result: MixRenderer.Result, deckA: Bool) -> [Float] {
        let source = monoSource(deckA ? result.scenario.outgoing.url : result.scenario.incoming.url)
        let sr = result.sampleRate
        let chunk = 512
        let gain = Float(deckA ? result.mix.gainA : result.mix.gainB)
        var out = [Float](repeating: 0, count: result.mix.left.count)
        guard !source.isEmpty else { return out }
        var previous: (TimeInterval, Bool)?
        for (index, entry) in result.mix.log.enumerated() {
            let playing = AutoMixMoveAnalysis.playing(entry, deckA: deckA)
            let end = AutoMixMoveAnalysis.position(entry, deckA: deckA)
            defer { previous = (end, playing) }
            guard playing else { continue }
            let span = Double(chunk) / sr * AutoMixMoveAnalysis.rate(entry, deckA: deckA)
            var begin = end - span
            if let (p, wasPlaying) = previous, wasPlaying, end > p, end - p < 0.1 { begin = p }
            let base = index * chunk
            for j in 0..<chunk where base + j < out.count {
                let position = (begin + (end - begin) * Double(j) / Double(chunk)) * sr
                let i = Int(position)
                guard i >= 0, i + 1 < source.count else { continue }
                let f = Float(position - Double(i))
                out[base + j] = (source[i] * (1 - f) + source[i + 1] * f) * gain
            }
        }
        return out
    }

    static func writeMono(_ samples: ArraySlice<Float>, to url: URL, sampleRate: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        for (k, v) in samples.enumerated() { channel[k] = v }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    static func writeStereo(_ left: ArraySlice<Float>, _ right: ArraySlice<Float>, to url: URL, sampleRate: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(left.count)),
              let data = buffer.floatChannelData else { return }
        for (k, v) in left.enumerated() { data[0][k] = v }
        for (k, v) in right.enumerated() { data[1][k] = v }
        buffer.frameLength = AVAudioFrameCount(left.count)
        try file.write(from: buffer)
    }

    static func loopTimes(_ result: MixRenderer.Result, fadeInBars: Int, fadeOutBars: Int, outgoingBar: TimeInterval) -> (start: TimeInterval, landing: TimeInterval, finish: TimeInterval, bar: TimeInterval) {
        let begin = result.mix.beginTime ?? 0
        let start = begin + result.mix.leadSeconds
        let bar = outgoingBar / max(0.01, result.mix.log.last(where: { $0.time <= begin })?.rateA ?? 1)
        let landing = start + Double(fadeInBars) * bar
        let finish = result.mix.finishTime ?? (landing + Double(fadeOutBars) * bar)
        return (start, landing, finish, bar)
    }

    static func writeLoopPack(_ result: MixRenderer.Result, url: URL) throws -> LoopPackMeasure? {
        guard let move = result.plan.move, move.kind == .loopMix, let grid = result.outgoingFeatures.beatGrid else { return nil }
        let sr = result.sampleRate
        let times = loopTimes(result, fadeInBars: move.leadBars, fadeOutBars: move.blendBars, outgoingBar: grid.barDuration)
        let clip = max(0, times.start - 20 * times.bar)
        let from = Int(clip * sr)
        let to = min(result.mix.left.count, Int((times.finish + 12 * times.bar) * sr))
        guard to > from else { return nil }
        let dryOut = dryStem(result, deckA: true)
        let dryIn = dryStem(result, deckA: false)
        let base = url.deletingPathExtension().path
        try writeStereo(result.mix.left[from..<to], result.mix.right[from..<to], to: url, sampleRate: sr)
        try writeMono(result.stemA[from..<min(to, result.stemA.count)], to: URL(fileURLWithPath: base + "-out.wav"), sampleRate: sr)
        try writeMono(result.stemB[from..<min(to, result.stemB.count)], to: URL(fileURLWithPath: base + "-in.wav"), sampleRate: sr)
        try writeMono(dryOut[from..<to], to: URL(fileURLWithPath: base + "-out-dry.wav"), sampleRate: sr)
        try writeMono(dryIn[from..<to], to: URL(fileURLWithPath: base + "-in-dry.wav"), sampleRate: sr)
        let input = LoopMixMeasure.Input(
            left: Array(result.mix.left[from..<to]), right: Array(result.mix.right[from..<to]),
            stemOut: Array(result.stemA[from..<min(to, result.stemA.count)]), stemIn: Array(result.stemB[from..<min(to, result.stemB.count)]),
            dryOut: Array(dryOut[from..<to]), dryIn: Array(dryIn[from..<to]),
            sampleRate: sr, start: times.start - clip, landing: times.landing - clip, finish: times.finish - clip, bar: times.bar
        )
        return LoopPackMeasure(clip: clip, input: input, result: LoopMixMeasure.measure(input))
    }

    static func loopGates(name: String, result: MixRenderer.Result, choice: LoopMixPlanner.Choice, outgoing: TrackFeatures, incoming: TrackFeatures, url: URL, measure: LoopPackMeasure?) -> [String] {
        let times = loopTimes(result, fadeInBars: choice.fadeInBars, fadeOutBars: choice.fadeOutBars, outgoingBar: (choice.outgoing.endSeconds - choice.outgoing.seconds) / Double(choice.outgoing.bars))
        let clip = measure?.clip ?? 0
        let start = measure.map { $0.input.start + clip } ?? times.start
        let bar = measure?.input.bar ?? times.bar
        let landing = measure.map { $0.input.landing + clip } ?? times.landing
        let finish = measure.map { $0.input.finish + clip } ?? times.finish
        let inBar = (choice.incoming.endSeconds - choice.incoming.seconds) / Double(choice.incoming.bars)
        let vOutLoop = DJMoveSupport.vocalSeconds(outgoing, choice.outgoing.seconds...choice.outgoing.endSeconds)
        let vInLoop = DJMoveSupport.vocalSeconds(incoming, choice.incoming.seconds...choice.incoming.endSeconds)
        let releaseEnd = choice.incoming.endSeconds + Double(choice.fadeOutBars) * inBar
        let vInRelease = DJMoveSupport.vocalSeconds(incoming, choice.incoming.endSeconds...releaseEnd)
        func densities(_ track: TrackFeatures, _ bar: Int) -> String {
            guard let p = track.barProfile else { return "-" }
            return (max(0, bar - 8)..<min(p.density.count, bar + 8)).map { String(format: "%.2f", p.density[$0]) }.joined(separator: ",")
        }
        func stamp(_ t: TimeInterval) -> String {
            let x = max(0, t - clip)
            return String(format: "%d:%04.1f", Int(x) / 60, x.truncatingRemainder(dividingBy: 60))
        }
        let dense = choice.outgoing.density <= BarProfile.sparseDensity && choice.incoming.density <= BarProfile.sparseDensity
        let measured = measure.map { LoopMixMeasure.passes($0.result) && LoopMixMeasure.levelContinuity($0.result) } ?? false
        let pass = vOutLoop < 0.01 && vInLoop < 0.01 && vInRelease < 0.01 && dense && measured
        return (measure.map { LoopMixMeasure.lines(name, $0.result) } ?? ["MEASURE|\(name)|unmeasured"]) + [
            "LOOPMIX-VERDICT|\(name)|vocal s: out loop \(String(format: "%.2f", vOutLoop)), in loop \(String(format: "%.2f", vInLoop)), in after release \(String(format: "%.2f", vInRelease))|density out \(String(format: "%.2f", choice.outgoing.density)) in \(String(format: "%.2f", choice.incoming.density)) (≤ \(BarProfile.sparseDensity))|\(pass ? "PASS" : "FAIL")|rule 21 (dip ≤ 1.5 LU, swell ≤ 3 LU) \(measure.map { LoopMixMeasure.levelContinuity($0.result) ? "PASS" : "FAIL" } ?? "unmeasured")",
            "LOOPMIX|\(name)|\(outgoing.trackId)→\(incoming.trackId)|out loop \(choice.outgoing.bars) bars at \(String(format: "%.2f", choice.outgoing.seconds)) s (bar \(choice.outgoing.bar), density \(String(format: "%.2f", choice.outgoing.density)), loop \(String(format: "%.2f", choice.outgoing.loopability)), level \(String(format: "%.1f", choice.outgoing.level)) dB)|in loop \(choice.incoming.bars) bars at \(String(format: "%.2f", choice.incoming.seconds)) s (bar \(choice.incoming.bar), density \(String(format: "%.2f", choice.incoming.density)), loop \(String(format: "%.2f", choice.incoming.loopability)), level \(String(format: "%.1f", choice.incoming.level)) dB)",
            "LOOPMIX-TIME|\(name)|loops from \(stamp(start)), release \(stamp(landing)), outgoing gone \(stamp(finish))",
            "LOOPMIX-DENSITY|\(name)|out bars \(max(0, choice.outgoing.bar - 8))…: \(densities(outgoing, choice.outgoing.bar))|in bars \(max(0, choice.incoming.bar - 8))…: \(densities(incoming, choice.incoming.bar))",
            "SPEC|\(name)|{\"stemOut\":\"\(url.deletingPathExtension().path)-out.wav\",\"stemIn\":\"\(url.deletingPathExtension().path)-in.wav\",\"dryOut\":\"\(url.deletingPathExtension().path)-out-dry.wav\",\"dryIn\":\"\(url.deletingPathExtension().path)-in-dry.wav\",\"start\":\(String(format: "%.4f", start - clip)),\"bar\":\(String(format: "%.6f", bar)),\"landingExact\":\(String(format: "%.4f", landing - clip)),\"finishExact\":\(String(format: "%.4f", finish - clip)),\"landing\":\(String(format: "%.2f", landing - clip)),\"finish\":\(String(format: "%.2f", finish - clip)),\"windows\":{\"outLoop\":[\(String(format: "%.2f", start - clip)),\(String(format: "%.2f", finish - clip))],\"inLoop\":[\(String(format: "%.2f", start - clip)),\(String(format: "%.2f", landing - clip))],\"blend\":[\(String(format: "%.2f", start - clip)),\(String(format: "%.2f", finish - clip))]}}",
            "PACK|\(name)|\(url.path)"
        ]
    }
}

enum AutoMixMoveAnalysis {

    static func position(_ entry: MixRenderer.LogEntry, deckA: Bool) -> TimeInterval { deckA ? entry.positionA : entry.positionB }
    static func rate(_ entry: MixRenderer.LogEntry, deckA: Bool) -> Double { max(0.01, deckA ? entry.rateA : entry.rateB) }
    static func playing(_ entry: MixRenderer.LogEntry, deckA: Bool) -> Bool { deckA ? entry.playingA : entry.playingB }

    static func crossing(of source: TimeInterval, deckA: Bool, log: [MixRenderer.LogEntry], after: TimeInterval) -> TimeInterval? {
        guard log.count > 1 else { return nil }
        for i in 1..<log.count where log[i].time >= after {
            let p = log[i - 1]
            let q = log[i]
            let p0 = position(p, deckA: deckA)
            let p1 = position(q, deckA: deckA)
            let tolerance = 2 / DJEngineConstants.canonicalSampleRate
            guard playing(q, deckA: deckA), p1 > p0, p1 - p0 < 0.5, p0 <= source + tolerance, p1 > source else { continue }
            return q.time - (p1 - source) / rate(q, deckA: deckA)
        }
        return nil
    }

    static func truthGrid(_ truth: MixFixtureTruth) -> BeatGrid? {
        BeatGrid.fromMeasuredBars(bpm: truth.spec.meanBPM, beats: truth.beats, bars: truth.downbeats, confidence: 1)
    }

    static func builder(_ result: MixRenderer.Result, rateA: Double) -> MixMoveBuilder? {
        guard let move = result.plan.move else { return nil }
        let input = MixTransitionTimelineInput(
            outgoing: 0, incoming: 1, sampleRate: result.sampleRate,
            anchorSourceSeconds: result.plan.mixPointSeconds, window: 0, entrySeconds: result.entrySeconds,
            outgoingRate: rateA, incomingRate: result.mix.incomingRate,
            outgoingGrid: truthGrid(result.scenario.outgoing.truth), incomingGrid: nil, stages: [],
            bassSwapAtSeconds: nil, bassSwapSeconds: nil, filterAccent: nil,
            defersIncomingStart: false, phaseLock: false, move: move
        )
        return MixMoveBuilder(move: move, input: input)
    }

    static func metrics(for result: MixRenderer.Result) -> ([String: Double], [String: String]) {
        var m: [String: Double] = [:]
        var notes: [String: String] = [:]
        let plan = result.plan
        let log = result.mix.log
        let sr = result.sampleRate
        guard let move = plan.move, let begin = result.mix.beginTime else {
            notes["moveError"] = "no move"
            return (m, notes)
        }
        notes["move"] = move.kind.rawValue + (move.effect == .none ? "" : ".\(move.effect.rawValue)")
        notes["headline"] = plan.rationale?.headline ?? plan.reasoning
        m["plan.score"] = plan.rationale?.score ?? 0
        m["move.landingBar"] = Double(move.landingBar)
        m["move.phraseBars"] = Double(move.phraseBars)
        m["move.repeatedBars"] = Double(move.repeatedBars)
        if move.kind == .jump { m["jump.distanceBars"] = Double(move.jumpBars) }

        let outgoing = result.scenario.outgoing
        let incoming = result.scenario.incoming
        if [.loopRoll, .fxBuild, .loopMix].contains(move.kind) || !move.ladder.isEmpty {
            let downbeats = outgoing.truth.downbeats
            let startBar = downbeats.indices.min { abs(downbeats[$0] - plan.mixPointSeconds) < abs(downbeats[$1] - plan.mixPointSeconds) } ?? 0
            let onsets = outgoing.spec.breakdownBars.map { $0.upperBound + 1 }
            m["move.startBar"] = Double(startBar)
            m["move.startsInDropOpening"] = onsets.contains { startBar >= $0 && startBar < $0 + DJMoveRails.dropOpeningBars } ? 1 : 0
        }
        let rateA = log.last(where: { $0.time <= begin })?.rateA ?? 1
        var wrapAnchor: TimeInterval?
        if let start = result.mix.deadlineLoopStart, abs(start - plan.mixPointSeconds) < 0.005, log.count > 1 {
            for i in 1..<log.count where log[i].time >= begin {
                let p0 = log[i - 1].positionA
                let p1 = log[i].positionA
                if p1 < p0 - 1, p1 >= start - 0.002 {
                    wrapAnchor = log[i].time - (p1 - start) / rate(log[i], deckA: true)
                    break
                }
            }
        }
        let crossed = crossing(of: plan.mixPointSeconds, deckA: true, log: log, after: begin - 1)
        if wrapAnchor != nil { m["deadline.anchorOnNextPass"] = crossed == nil || (wrapAnchor ?? 0) < (crossed ?? 0) ? 1 : 0 }
        guard let anchorTime = wrapAnchor.map({ w in crossed.map { min($0, w) } ?? w }) ?? crossed,
              let builder = builder(result, rateA: rateA) else {
            notes["moveError"] = "anchor never crossed"
            return (m, notes)
        }
        let expected = anchorTime + builder.wall(move.landingBar)
        let incomingStartBars = move.incomingLeadBars
        let entryIndex = incoming.truth.downbeats.firstIndex { abs($0 - result.entrySeconds) < 0.01 }
        m["landing.entryOnDownbeat"] = entryIndex == nil ? 0 : 1
        if let entryIndex, entryIndex + incomingStartBars < incoming.truth.downbeats.count {
            let landingSource = incoming.truth.downbeats[entryIndex + incomingStartBars]
            if let actual = crossing(of: landingSource, deckA: false, log: log, after: anchorTime - 0.5) {
                m["landing.errorMs"] = (actual - expected) * 1000
                m["landing.absErrorMs"] = abs(actual - expected) * 1000
                if move.kind == .dropIn || move.kind == .dropOnTheOne || move.kind == .loopRoll || move.kind == .fxBuild || move.kind == .echoOut || move.kind == .cut {
                    let period = outgoing.truth.localBeatPeriod(at: plan.mixPointSeconds) / rateA
                    let lowsBack = move.kind == .echoOut ? (MixMoveBuilder.echoOutLowReturnBars + MixMoveBuilder.echoOutLowRampBars) * 4 * period : 0
                    let onsets = MixMetrics.kickOnsets(result.stemB, sampleRate: sr).filter { $0 >= actual + lowsBack - 0.05 && $0 <= actual + lowsBack + 0.3 }
                    let outOnsets = MixMetrics.kickOnsets(result.stemA, sampleRate: sr).filter { $0 >= begin - 30 && $0 < begin - 0.5 }
                    if let first = onsets.first, let origin = outOnsets.first, outOnsets.count >= 4, period > 0.1 {
                        let phases = outOnsets.map { onset -> Double in
                            var r = (onset - origin).truncatingRemainder(dividingBy: period)
                            if r > period / 2 { r -= period }
                            return r
                        }
                        let phase = MixMetrics.median(phases)
                        let n = ((first - origin - phase) / period).rounded()
                        m["landing.audioErrorMs"] = (first - (origin + phase + n * period)) * 1000
                    }
                }
                if move.kind == .dropIn || move.kind == .dropOnTheOne {
                    if let sourceA = AutoMixAnalysis.sourceTime(at: actual - 0.001, deckA: true, log: log),
                       let anchorIndex = outgoing.truth.downbeats.firstIndex(where: { $0 >= plan.mixPointSeconds - 0.002 }) {
                        let barIndex = outgoing.truth.downbeats.indices.min { abs(outgoing.truth.downbeats[$0] - sourceA) < abs(outgoing.truth.downbeats[$1] - sourceA) } ?? 0
                        m["dropIn.targetBarOffset"] = Double(barIndex - (anchorIndex + move.landingBar))
                        let dropIndex = incoming.truth.downbeats.firstIndex { abs($0 - landingSource) < 0.01 } ?? -1
                        notes["dropIn.landing"] = "incoming bar \(dropIndex) on outgoing bar \(barIndex)"
                    }
                }
            } else {
                notes["moveError"] = "the incoming landing bar never played"
            }
        }

        if !move.ladder.isEmpty {
            let base = Int((anchorTime * sr).rounded())
            var cursor = 0
            var seams: [Int] = []
            for (index, rung) in move.ladder.enumerated() {
                let length = Int(((builder.source(rung.bars) - builder.source(0)) * sr).rounded())
                for p in 0..<rung.passes {
                    if index > 0 || p > 0 { seams.append(base + cursor) }
                    cursor += length
                }
            }
            var worstLag = 0
            var worstCorrelation = 1.0
            var worstDiff: Float = 0
            let window = 4096
            let skip = Int(0.04 * sr)
            let reference = base + skip
            for seam in seams {
                let start = seam + skip
                guard reference + window < result.stemA.count, start + window + 64 < result.stemA.count, start > 64 else { continue }
                var bestLag = 0
                var best = -Double.infinity
                for lag in -64...64 {
                    var dot = 0.0
                    var ea = 0.0
                    var eb = 0.0
                    for n in 0..<window {
                        let x = Double(result.stemA[reference + n])
                        let y = Double(result.stemA[start + lag + n])
                        dot += x * y
                        ea += x * x
                        eb += y * y
                    }
                    let c = dot / max(1e-12, (ea * eb).squareRoot())
                    if c > best { best = c; bestLag = lag }
                }
                var diff: Float = 0
                for n in 0..<window { diff = max(diff, abs(result.stemA[reference + n] - result.stemA[start + n])) }
                if abs(bestLag) > abs(worstLag) { worstLag = bestLag }
                worstCorrelation = min(worstCorrelation, best)
                worstDiff = max(worstDiff, diff)
            }
            m["loop.seams"] = Double(seams.count)
            m["loop.seamLagSamples"] = Double(abs(worstLag))
            m["loop.seamCorrelation"] = worstCorrelation
            m["loop.seamMaxDiff"] = Double(worstDiff)
        }

        if !result.stemRiser.isEmpty {
            let stem = result.stemRiser
            let landingIndex = Int((expected * sr).rounded()) + MixLimiter.lookahead
            let peak = stem.reduce(Float(0)) { max($0, abs($1)) }
            m["riser.peakDBFS"] = MixMetrics.db(Double(peak))
            func rms(_ from: TimeInterval, _ to: TimeInterval) -> Double {
                let lo = max(0, Int(from * sr))
                let hi = min(stem.count, Int(to * sr))
                guard hi > lo else { return 0 }
                var sum = 0.0
                for n in lo..<hi { sum += Double(stem[n]) * Double(stem[n]) }
                return (sum / Double(hi - lo)).squareRoot()
            }
            m["riser.beforeLandingDBFS"] = MixMetrics.db(rms(expected - 0.3, expected - 0.01))
            let threshold = peak * 0.001
            if let last = stem.lastIndex(where: { abs($0) > threshold }) {
                m["riser.endErrorMs"] = Double(last - landingIndex) / sr * 1000
            }
            let after = stem[min(stem.count, landingIndex + 1)..<min(stem.count, landingIndex + Int(sr))].reduce(Float(0)) { max($0, abs($1)) }
            m["riser.afterLandingDBFS"] = MixMetrics.db(Double(after))
            let mono = zip(result.mix.left, result.mix.right).map { ($0 + $1) * 0.5 }
            let preMix: Double = {
                let lo = max(0, Int((begin - 10) * sr))
                let hi = max(lo, Int((begin - 1) * sr))
                guard hi > lo else { return 0 }
                var sum = 0.0
                for n in lo..<hi { sum += Double(mono[n]) * Double(mono[n]) }
                return (sum / Double(hi - lo)).squareRoot()
            }()
            m["riser.relativeToMixDB"] = MixMetrics.db(rms(expected - 1, expected - 0.01)) - MixMetrics.db(preMix)
            m["riser.preMixDBFS"] = MixMetrics.db(preMix)
        }

        if let length = result.mix.deadlineLoopLength, let start = result.mix.deadlineLoopStart {
            let bar = 4 * outgoing.truth.localBeatPeriod(at: start)
            m["deadline.loopBars"] = (length / bar).rounded()
            let nearest = outgoing.truth.downbeats.min { abs($0 - start) < abs($1 - start) } ?? start
            m["deadline.loopStartOffDownbeatMs"] = abs(nearest - start) * 1000
            let end = start + length
            let nearestEnd = outgoing.truth.downbeats.min { abs($0 - end) < abs($1 - end) } ?? end
            m["deadline.loopEndOffDownbeatMs"] = abs(nearestEnd - end) * 1000
        } else {
            m["deadline.loopBars"] = 0
        }
        if let finishTime = result.mix.finishTime {
            let stop = result.mix.stopTimeA ?? finishTime
            m["deadline.outgoingEarlyStopSeconds"] = max(0, finishTime - stop)
        }

        let finish = result.mix.finishTime ?? (log.last?.time ?? begin)
        var maxStep = 0.0
        var maxSlope = 0.0
        let barSeconds = 4 * outgoing.truth.localBeatPeriod(at: plan.mixPointSeconds)
        let span = log.filter { $0.time >= begin && $0.time <= finish }
        for i in 1..<max(1, span.count) {
            maxStep = max(maxStep, abs(span[i].rateA - span[i - 1].rateA) * 100)
        }
        var cursor = 0
        for i in 0..<span.count {
            while cursor < i, span[i].time - span[cursor].time > barSeconds { cursor += 1 }
            maxSlope = max(maxSlope, abs(span[i].rateA - span[cursor].rateA) * 100)
        }
        m["tempo.maxStepPercent"] = maxStep
        m["tempo.maxSlopePercentPerBar"] = maxSlope
        if let last = span.last { m["tempo.outgoingRateAtEnd"] = last.rateA }

        if move.hasOverlap {
            let errors = factorPhaseErrors(result: result, from: begin + result.mix.leadSeconds, to: finish)
            if !errors.isEmpty {
                m["phaseFold.medianAbsMs"] = MixMetrics.median(errors.map { abs($0) })
                m["phaseFold.p95AbsMs"] = MixMetrics.percentile(errors.map { abs($0) }, 0.95)
                m["phaseFold.pairs"] = Double(errors.count)
            }
        }

        if move.effect == .echo || move.effect == .reverbWash || move.kind == .loopRoll {
            let landing = expected
            let tail = MixMetrics.rmsSeries(result.stemA, sampleRate: sr, window: 0.1, hop: 0.05)
            let before = tail.enumerated().compactMap { i, v -> Double? in
                let t = Double(i) * 0.05 + 0.05
                return t > landing - 2 && t < landing - 0.1 ? MixMetrics.db(v) : nil
            }
            let floor = (before.max() ?? -20) - 40
            var last = landing
            for (i, v) in tail.enumerated() {
                let t = Double(i) * 0.05 + 0.05
                if t > landing, MixMetrics.db(v) > floor { last = t }
            }
            m["tail.secondsAfterLanding"] = last - landing
        }

        let hop = 0.1
        let momentary = MixMetrics.loudnessSeries(left: result.mix.left, right: result.mix.right, sampleRate: sr, window: 0.4, hop: hop)
        let pre = MixMetrics.median(momentary.enumerated().compactMap { i, v in
            let t = Double(i) * hop + 0.2
            return t >= begin - 10 && t <= begin - 1 ? v : nil
        })
        let during = momentary.enumerated().compactMap { i, v -> Double? in
            let t = Double(i) * hop + 0.2
            return t >= begin && t <= finish ? v : nil
        }
        let post = MixMetrics.median(momentary.enumerated().compactMap { i, v in
            let t = Double(i) * hop + 0.2
            return t >= finish + 3 && t <= finish + 13 ? v : nil
        })
        if pre.isFinite, post.isFinite {
            let floor = max(pre, post) - 24
            m["loudness.holeSeconds"] = Double(during.filter { $0 < floor }.count) * hop
            m["loudness.deepestBelowLouderLU"] = max(0, max(pre, post) - (during.min() ?? max(pre, post)))
        }
        return (m, notes)
    }

    static func factorPhaseErrors(result: MixRenderer.Result, from start: TimeInterval, to end: TimeInterval) -> [Double] {
        let log = result.mix.log
        let outPeriod = result.scenario.outgoing.truth.localBeatPeriod(at: result.plan.mixPointSeconds)
        let inPeriod = result.scenario.incoming.truth.localBeatPeriod(at: result.entrySeconds)
        let sparseIsA = outPeriod >= inPeriod
        let sparse = sparseIsA ? result.scenario.outgoing.truth : result.scenario.incoming.truth
        let dense = sparseIsA ? result.scenario.incoming.truth : result.scenario.outgoing.truth
        let rmsA = MixMetrics.rmsSeries(result.stemA, sampleRate: result.sampleRate, window: 0.1, hop: 0.01)
        let rmsB = MixMetrics.rmsSeries(result.stemB, sampleRate: result.sampleRate, window: 0.1, hop: 0.01)
        func audible(_ series: [Double], _ t: TimeInterval) -> Bool {
            guard !series.isEmpty else { return false }
            return MixMetrics.db(series[min(series.count - 1, max(0, Int(t / 0.01)))]) > -45
        }
        var out: [Double] = []
        var cursor = start
        for beat in sparse.beats {
            guard let t = AutoMixAnalysis.outputTime(ofSource: beat, deckA: sparseIsA, log: log, after: cursor) else { continue }
            if t > end { break }
            guard t >= start else { continue }
            cursor = max(start, t - 0.05)
            guard audible(rmsA, t), audible(rmsB, t),
                  let other = AutoMixAnalysis.sourceTime(at: t, deckA: !sparseIsA, log: log),
                  let nearest = dense.beats.min(by: { abs($0 - other) < abs($1 - other) }) else { continue }
            let rate = max(0.01, log.first(where: { $0.time >= t }).map { sparseIsA ? $0.rateB : $0.rateA } ?? 1)
            out.append((other - nearest) / rate * 1000)
        }
        return out
    }
}

enum AutoMixMoveGates {
    static let overlapMoves = ["bass-swap", "breakdown-exit", "drop-in", "tempo-ramp", "bridge", "jump-set", "jump-track", "riser-drop-in", "deadline-loop", "deadline-late"]
    static let cutMoves = ["cut", "echo-out", "drop-on-the-one", "loop-roll", "loop-roll-dry", "filter-build", "echo-build", "reverb-wash", "riser-loop-roll", "riser-filter-build"]
    static let riserMoves = ["riser-loop-roll", "riser-filter-build", "riser-drop-in"]

    static var gates: [AutoMixGates.Gate] {
        var out: [AutoMixGates.Gate] = []
        for name in overlapMoves + cutMoves {
            out += [
                .min(name, "plan.score", 0.01),
                .max(name, "landing.absErrorMs", 3),
                .min(name, "landing.entryOnDownbeat", 1),
                .max(name, "clicks.count", 0),
                .max(name, "clicks.stemCount", 0),
                .max(name, "truePeak.dBTP", -0.3),
                .max(name, "loudness.swellLU", 3),
                .max(name, "loudness.holeSeconds", 0.25),
                .max(name, "anchors.missed", 0)
            ]
        }
        for name in overlapMoves {
            out += [
                .max(name, "phaseFold.medianAbsMs", 3),
                .max(name, "phaseFold.p95AbsMs", 8),
                .min(name, "phaseFold.pairs", 4)
            ]
        }
        for name in ["bass-swap", "tempo-ramp", "jump-set", "jump-track"] {
            out.append(.max(name, "downbeat.medianOffsetBeats", 0))
        }
        for name in ["bass-swap", "bridge", "jump-set", "jump-track"] {
            out.append(.max(name, "loudness.dipLU", 1.5))
        }
        for name in ["cut", "echo-out", "drop-on-the-one", "drop-in", "breakdown-exit", "tempo-ramp", "loop-roll-dry"] {
            out.append(.max(name, "loudness.dipLU", 14))
        }
        for name in ["loop-roll", "filter-build", "echo-build", "reverb-wash", "riser-loop-roll", "riser-filter-build"] {
            out.append(.max(name, "loudness.dipLU", 20))
            out.append(.max(name, "move.startsInDropOpening", 0))
        }
        out += [.max("riser-drop-in", "loudness.dipLU", 14), .max("deadline-loop", "loudness.dipLU", 1.5), .max("deadline-late", "loudness.dipLU", 1.5)]
        for name in ["deadline-loop", "deadline-late"] {
            out += [.max(name, "truePeak.dBTP", -1), .max(name, "clicks.count", 0), .max(name, "clicks.stemCount", 0)]
        }
        for name in riserMoves {
            out += [
                .max(name, "riser.peakDBFS", -9),
                .max(name, "riser.relativeToMixDB", -3),
                .min(name, "riser.beforeLandingDBFS", -40),
                .max(name, "riser.endErrorMs", 0.1),
                .min(name, "riser.endErrorMs", -5),
                .max(name, "riser.afterLandingDBFS", -90)
            ]
        }
        out += [
            .min("deadline-loop", "deadline.loopBars", 4),
            .max("deadline-loop", "deadline.loopBars", 8),
            .max("deadline-loop", "deadline.loopStartOffDownbeatMs", 1),
            .max("deadline-loop", "deadline.loopEndOffDownbeatMs", 1),
            .max("deadline-loop", "deadline.outgoingEarlyStopSeconds", 0.05),
            .min("deadline-late", "deadline.loopBars", 8),
            .max("deadline-late", "deadline.loopBars", 8),
            .max("deadline-late", "deadline.outgoingEarlyStopSeconds", 0.05),
            .min("deadline-late", "deadline.anchorOnNextPass", 1),
            .max("deadline-control", "deadline.loopBars", 0),
            .min("deadline-control", "deadline.outgoingEarlyStopSeconds", 1)
        ]
        for name in ["loop-roll", "drop-on-the-one", "filter-build", "echo-build", "reverb-wash", "cut", "echo-out", "riser-loop-roll", "riser-filter-build"] {
            out.append(.max(name, "landing.audioErrorMs", 5))
            out.append(.min(name, "landing.audioErrorMs", -5))
        }
        out += [
            .max("loop-roll-dry", "loop.seamLagSamples", 0),
            .min("loop-roll-dry", "loop.seamCorrelation", 0.999),
            .min("loop-roll-dry", "loop.seams", 4),
            .max("loop-roll", "move.repeatedBars", 16),
            .max("drop-in", "dropIn.targetBarOffset", 0),
            .min("drop-in", "dropIn.targetBarOffset", 0),
            .max("riser-drop-in", "dropIn.targetBarOffset", 0),
            .min("riser-drop-in", "dropIn.targetBarOffset", 0),
            .max("drop-on-the-one", "dropIn.targetBarOffset", 0),
            .min("drop-on-the-one", "dropIn.targetBarOffset", 0),
            .min("jump-set", "jump.distanceBars", 32),
            .min("jump-track", "jump.distanceBars", 32),
            .max("tempo-ramp", "tempo.maxStepPercent", 0.05),
            .max("tempo-ramp", "tempo.maxSlopePercentPerBar", 0.5),
            .max("tempo-ramp", "tempo.postMixChangePercent", 0.05),
            .min("echo-out", "tail.secondsAfterLanding", 1),
            .min("reverb-wash", "tail.secondsAfterLanding", 1)
        ]
        return out
    }

    static func evaluate(_ report: AutoMixReport) -> [String] {
        var failures: [String] = []
        for (name, notes) in report.notes {
            if let error = notes["error"] { failures.append("\(name): \(error)") }
            if let error = notes["moveError"] { failures.append("\(name): \(error)") }
        }
        let partial = !(ProcessInfo.processInfo.environment["AUTOMIX_ONLY"] ?? "").isEmpty
        for gate in gates where !partial || report.scenarios[gate.scenario] != nil {
            guard let value = report.scenarios[gate.scenario]?[gate.metric] else {
                failures.append("\(gate.scenario).\(gate.metric) was not measured")
                continue
            }
            if let maximum = gate.maximum, !(value <= maximum) {
                failures.append("\(gate.scenario).\(gate.metric) = \(value), gate ≤ \(maximum)")
            }
            if let minimum = gate.minimum, !(value >= minimum) {
                failures.append("\(gate.scenario).\(gate.metric) = \(value), gate ≥ \(minimum)")
            }
        }
        return failures
    }
}

final class MixDeadlineLoopVocalTests: XCTestCase {
    private let downbeats = stride(from: 0.0, through: 200.0, by: 2.0).map { $0 }

    private func loop(_ vocals: [ClosedRange<TimeInterval>]?) -> MixDeadlineLoop? {
        MixDeadlineLoop.lastCleanPhrase(downbeats: downbeats, duration: 201, playhead: 150, vocals: vocals)
    }

    func testUnmeasuredVocalsKeepTheLastPhrase() {
        XCTAssertEqual(loop(nil), MixDeadlineLoop(startSeconds: 184, lengthSeconds: 16, bars: 8))
    }

    func testVocalPhraseIsSkippedForAnEarlierInstrumentalPhrase() {
        XCTAssertEqual(loop([180...200]), MixDeadlineLoop(startSeconds: 164, lengthSeconds: 16, bars: 8))
    }

    func testOnlyAShortGapFallsBackToAShortInstrumentalLoop() {
        let picked = loop([140...186, 190...200])
        XCTAssertEqual(picked, MixDeadlineLoop(startSeconds: 186, lengthSeconds: 4, bars: 2))
        if let picked {
            XCTAssertEqual(MixDeadlineLoop.vocalSeconds([140...186, 190...200], picked.startSeconds...picked.endSeconds), 0, accuracy: 1e-9)
        }
    }

    func testLoopAvoidsAFadingTailSeam() {
        var levels = [Float](repeating: 0.6, count: 201)
        for i in 190..<201 { levels[i] = 0.1 }
        let picked = MixDeadlineLoop.lastCleanPhrase(downbeats: downbeats, duration: 201, playhead: 150, levels: levels)
        XCTAssertEqual(picked, MixDeadlineLoop(startSeconds: 174, lengthSeconds: 16, bars: 8))
        if let picked { XCTAssertTrue(MixDeadlineLoop.seamLevelsMatch(picked, levels: levels, duration: 201)) }
    }

    func testVocalsEverywhereStillLoopsRatherThanRunningOut() {
        XCTAssertEqual(loop([0...201]), MixDeadlineLoop(startSeconds: 184, lengthSeconds: 16, bars: 8))
    }
}

final class VocalActivityTests: XCTestCase {
    func testDetectorFindsTheFixtureVocal() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("vocal-activity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try MixFixtureFactory.fixture(AutoMixFixtures.vocalOutroE, in: directory)
        let tracked = try await BeatTracker.analyze(fileURL: fixture.url)
        let detected = try XCTUnwrap(tracked.vocalSeconds)
        let truth = fixture.truth.vocalRanges
        func overlap(_ a: [ClosedRange<TimeInterval>], _ b: [ClosedRange<TimeInterval>]) -> TimeInterval {
            a.reduce(0) { sum, x in sum + b.reduce(0) { $0 + max(0, min(x.upperBound, $1.upperBound) - max(x.lowerBound, $1.lowerBound)) } }
        }
        let truthSeconds = truth.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        let detectedSeconds = detected.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        let hit = overlap(detected, truth)
        XCTAssertGreaterThanOrEqual(hit / max(1, truthSeconds), 0.7, "detected \(detected) vs truth \(truth)")
        XCTAssertGreaterThanOrEqual(hit / max(1, detectedSeconds), 0.7, "detected \(detected) vs truth \(truth)")
    }
}
#endif
