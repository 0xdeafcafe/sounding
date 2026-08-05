import Foundation
@testable import SoundingTV

#if DEBUG

enum CueSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[CueTest] \(status)"] + lines.map { "[CueTest]   \($0)" }
                + failures.map { "[CueTest]   ✗ \($0)" }).joined(separator: "\n")
        }

        mutating func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() { lines.append("\(name) → ok") } else { failures.append(name) }
        }
    }

    static func run() async -> Report {
        var report = Report()
        testPositionRoundTrip(&report)
        await testStorageRoundTrip(&report)
        await testSlotIdentityConverges(&report)
        await testTombstoneSurvivesSync(&report)
        testSuggestionVsUserSetDistinction(&report)
        await testPromotionAndDismissal(&report)
        testSuggesterNeverClaimsHotCueSlot(&report)
        testSuggesterReusesPhantomsMixPoint(&report)
        testSuggesterFindsIntroDropAndBreakdown(&report)
        testOrdering(&report)
        testEnginePrecedence(&report)
        testClampingAgainstAShorterTrack(&report)
        return report
    }

    private static func scratchStore(writerId: String = "writer-A") -> (CueStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CueStoreSelfTest-\(UUID().uuidString)", isDirectory: true)
        return (CueStore(directory: dir, writerId: writerId), dir)
    }

    private static func testPositionRoundTrip(_ report: inout Report) {
        let cases: [(seconds: TimeInterval, millis: Int64)] = [
            (0, 0),
            (0.001, 1),
            (1.0 / 3.0, 333),
            (191.2, 191_200),
            (191.2005, 191_201),   // rounds to nearest, not toward zero
            (3_599.999, 3_599_999),
        ]
        var ok = true
        for c in cases where CueTime.millis(fromSeconds: c.seconds) != c.millis { ok = false }
        report.expect("seconds → millis rounds to nearest", ok)

        var stable = true
        for c in cases {
            let millis = CueTime.millis(fromSeconds: c.seconds)
            if CueTime.millis(fromSeconds: CueTime.seconds(fromMillis: millis)) != millis { stable = false }
        }
        report.expect("millis → seconds → millis is a fixed point", stable)

        report.expect(
            "non-finite input is refused outright rather than trapping",
            CueTime.millis(fromSeconds: .nan) == 0
                && CueTime.millis(fromSeconds: .infinity) == 0
                && CueTime.millis(fromSeconds: -.infinity) == 0
        )
        report.expect(
            "a finite but out-of-range input saturates rather than trapping",
            CueTime.millis(fromSeconds: 1e300) == Int64.max
                && CueTime.millis(fromSeconds: -1e300) == Int64.min
        )
        report.expect(
            "a negative position normalises to the start of the track",
            CuePoint(trackId: "t", kind: .memory, positionMillis: -500).positionMillis == 0
        )
        report.expect(
            "a loop end at or before its start is normalised, not stored inverted",
            CuePoint(trackId: "t", kind: .loop, positionMillis: 1_000, endMillis: 500).endMillis == 1_001
        )
        report.expect(
            "a hot-cue index outside 0...7 is clamped into the slot range",
            CuePoint(trackId: "t", kind: .hotCue, positionMillis: 0, hotCueIndex: 99).hotCueIndex == 7
                && CuePoint(trackId: "t", kind: .hotCue, positionMillis: 0, hotCueIndex: -3).hotCueIndex == 0
        )
        report.expect(
            "only a loop carries an end and only a hot cue carries a slot",
            CuePoint(trackId: "t", kind: .memory, positionMillis: 0, endMillis: 5_000, hotCueIndex: 2).endMillis == nil
                && CuePoint(trackId: "t", kind: .memory, positionMillis: 0, hotCueIndex: 2).hotCueIndex == nil
        )

        let cue = CuePoint(trackId: "t", kind: .mixIn, positionMillis: CueTime.millis(fromSeconds: 191.2))
        report.expect("seconds accessor recovers the input to within the quantum", abs(cue.positionSeconds - 191.2) <= 0.0005)
    }

    private static func testStorageRoundTrip(_ report: inout Report) async {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let saved = await store.setHotCue(trackId: "t1", index: 2, positionMillis: 191_234, label: "The bit")
        _ = await store.addLoop(trackId: "t1", startMillis: 60_000, endMillis: 63_750, label: "8 bars")
        _ = await store.setMixIn(trackId: "t1", positionMillis: 12_500)

        let reopened = CueStore(directory: dir)
        let cues = await reopened.cues(forTrack: "t1")

        report.expect("three cues persist across a fresh store instance", cues.count == 3)
        report.expect(
            "every field survives the round trip",
            cues.first { $0.kind == .hotCue }.map {
                $0.positionMillis == 191_234 && $0.hotCueIndex == 2 && $0.label == "The bit"
                    && $0.color == CueColor.hotCuePalette[2] && $0.id == saved.id
            } ?? false
        )
        report.expect(
            "a loop keeps its end and a non-loop does not acquire one",
            cues.first { $0.kind == .loop }?.endMillis == 63_750
                && cues.first { $0.kind == .mixIn }?.endMillis == nil
        )

        await store.delete(cueId: saved.id)
        let afterDelete = await store.cues(forTrack: "t1")
        report.expect("a deleted cue leaves the live set", !afterDelete.contains { $0.id == saved.id })
        let records = await store.syncRecords(changedSince: 0)
        report.expect(
            "…but survives as a tombstone for sync",
            records.contains { $0.cueId == saved.id && $0.isDeleted }
        )
        let durable = await store.isDurable
        report.expect("a scratch store on a real directory reports itself durable", durable)
    }

    private static func testSlotIdentityConverges(_ report: inout Report) async {
        let (a, dirA) = scratchStore(writerId: "A")
        let (b, dirB) = scratchStore(writerId: "B")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let onA = await a.setHotCue(trackId: "t", index: 2, positionMillis: 1_000, now: 100)
        let onB = await b.setHotCue(trackId: "t", index: 2, positionMillis: 2_000, now: 200)
        report.expect("the same hot-cue slot on two devices is one id", onA.id == onB.id)

        let fromB = await b.syncRecords()
        let adopted = await a.adopt(fromB)
        let merged = await a.cues(forTrack: "t")
        report.expect(
            "last-writer-wins converges on the newer edit, with no duplicate row",
            adopted == 1 && merged.count == 1 && merged.first?.positionMillis == 2_000
        )
        let replay = await a.adopt(fromB)
        report.expect("adopting the same batch twice writes nothing", replay == 0)

        let memA = await a.addMemoryCue(trackId: "t2", positionMillis: 5_000)
        let memB = await b.addMemoryCue(trackId: "t2", positionMillis: 9_000)
        report.expect("two unslotted cues get distinct ids", memA.id != memB.id)
    }

    private static func testTombstoneSurvivesSync(_ report: inout Report) async {
        let (a, dirA) = scratchStore(writerId: "A")
        let (b, dirB) = scratchStore(writerId: "B")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let cue = await a.setMixOut(trackId: "t", positionMillis: 300_000, now: 100)
        var fromA = await a.syncRecords()
        _ = await b.adopt(fromA)
        let onB = await b.cues(forTrack: "t")
        report.expect("B receives the cue", onB.count == 1)

        await a.delete(cueId: cue.id, now: 200)
        fromA = await a.syncRecords()
        _ = await b.adopt(fromA)
        let afterDelete = await b.cues(forTrack: "t")
        report.expect("B honours the delete", afterDelete.isEmpty)

        let fromB = await b.syncRecords()
        _ = await a.adopt(fromB)
        let afterRoundTrip = await a.cues(forTrack: "t")
        report.expect("the delete is not resurrected on the round trip", afterRoundTrip.isEmpty)

        let prunedEarly = await a.pruneTombstones(olderThan: 150)
        let prunedLate = await a.pruneTombstones(olderThan: 250)
        report.expect("tombstones are pruned only once past retention", prunedEarly == 0 && prunedLate == 1)
    }

    private static func testSuggestionVsUserSetDistinction(_ report: inout Report) {
        let userMixIn = CuePoint(trackId: "t", kind: .mixIn, positionMillis: 30_000, label: "mine")
        let suggestedMixIn = suggestion(kind: .mixIn, millis: 12_000)
        let suggestedFar = suggestion(kind: .memory, millis: 90_000)
        let suggestedNear = suggestion(kind: .memory, millis: 60_500)
        let userMemory = CuePoint(trackId: "t", kind: .memory, positionMillis: 60_000)

        let sheet = CueResolution.resolve(
            trackId: "t",
            userCues: [userMixIn, userMemory],
            suggestions: [suggestedMixIn, suggestedNear, suggestedFar],
            dismissedIds: []
        )

        report.expect(
            "a user mix-in suppresses the suggested one outright",
            sheet.mixIn?.origin == .user && sheet.entriesMatching(.mixIn, .suggested).isEmpty
        )
        report.expect(
            "a suggestion within a bar of a user cue of the same kind is suppressed",
            !sheet.entries.contains { $0.id == suggestedNear.id }
        )
        report.expect(
            "a suggestion further away survives",
            sheet.entries.contains { $0.id == suggestedFar.id }
        )
        report.expect(
            "the user's cues are all still there, unmodified",
            sheet.userCues.count == 2
                && sheet.userCues.contains { $0.positionMillis == 30_000 && $0.label == "mine" }
                && sheet.userCues.contains { $0.positionMillis == 60_000 }
        )
        report.expect(
            "origin, confidence and reasoning distinguish the two structurally",
            sheet.entries.allSatisfy { entry in
                switch entry.origin {
                case .user:      return entry.confidence == nil
                case .suggested: return entry.confidence != nil && !entry.reasoning.isEmpty
                }
            }
        )
        report.expect(
            "a deleted user cue stops suppressing",
            CueResolution.resolve(
                trackId: "t",
                userCues: [CuePoint(trackId: "t", kind: .mixIn, positionMillis: 30_000, isDeleted: true)],
                suggestions: [suggestedMixIn],
                dismissedIds: []
            ).mixIn?.origin == .suggested
        )
        report.expect(
            "a dismissed suggestion does not come back",
            CueResolution.resolve(
                trackId: "t",
                userCues: [],
                suggestions: [suggestedFar],
                dismissedIds: [suggestedFar.id]
            ).entries.isEmpty
        )
        report.expect(
            "a dismissal is scoped to the suggester version",
            !CueResolution.resolve(
                trackId: "t",
                userCues: [],
                suggestions: [suggestion(kind: .memory, millis: 90_000, version: 2)],
                dismissedIds: [suggestedFar.id]
            ).entries.isEmpty
        )
    }

    private static func testPromotionAndDismissal(_ report: inout Report) async {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let candidate = suggestion(kind: .memory, millis: 120_000)
        let kept = await store.promote(candidate, asKind: .hotCue, hotCueIndex: 3, label: "Drop")

        report.expect(
            "a promoted suggestion becomes a user cue that records where it came from",
            kept.origin == .user
                && kept.kind == .hotCue
                && kept.hotCueIndex == 3
                && kept.positionMillis == candidate.positionMillis
                && kept.promotedFrom == candidate.suggester
        )
        let stored = await store.cues(forTrack: "t")
        report.expect("…and it persists", stored.contains { $0.id == kept.id })

        let other = suggestion(kind: .memory, millis: 200_000)
        await store.dismiss(other)
        let dismissed = await store.dismissedSuggestionIds(forTrack: "t")
        report.expect("a dismissal persists", dismissed.contains(other.id))
        await store.undismiss(suggestionId: other.id)
        let afterUndismiss = await store.dismissedSuggestionIds(forTrack: "t")
        report.expect("…and can be undone", afterUndismiss.isEmpty)

        let sheet = await store.sheet(for: CueSuggester.Input(trackId: "t", duration: 300, envelope: []))
        report.expect(
            "a kept suggestion shows on the sheet as a user cue",
            sheet.entries.count == 1 && sheet.entries.first?.origin == .user
        )
    }

    private static func testSuggesterNeverClaimsHotCueSlot(_ report: inout Report) {
        let inputs = [
            CueSuggester.Input(trackId: "a", duration: 300, envelope: syntheticClubTrack(buckets: 300)),
            CueSuggester.Input(trackId: "b", duration: 240, envelope: syntheticFadeOut(buckets: 240)),
            CueSuggester.Input(trackId: "c", duration: 200, envelope: syntheticHardStop(buckets: 200)),
        ]
        let all = inputs.flatMap(CueSuggester.suggest)
        report.expect("no suggestion is ever a hot cue", !all.contains { $0.kind == .hotCue })
        report.expect("no suggestion carries a hot-cue slot", all.allSatisfy { ResolvedCue.suggested($0).hotCueIndex == nil })
        report.expect("every suggestion names its suggester", all.allSatisfy { $0.suggester == CueSuggester.identity })
        report.expect("every suggestion explains itself", all.allSatisfy { !$0.reasoning.isEmpty })
    }

    private static func testSuggesterReusesPhantomsMixPoint(_ report: inout Report) {
        var agreed = true
        var checked = 0
        let cases: [(String, TimeInterval, [Float])] = [
            ("club", 300, syntheticClubTrack(buckets: 300)),
            ("fade", 240, syntheticFadeOut(buckets: 240)),
            ("hard", 200, syntheticHardStop(buckets: 200)),
        ]
        for (name, duration, envelope) in cases {
            let plan = PhantomDJEngine.plan(outgoingDuration: duration, envelope: envelope)
            let suggested = CueSuggester.suggest(CueSuggester.Input(trackId: name, duration: duration, envelope: envelope))
                .first { $0.kind == .mixOut }
            guard let plan else {
                if suggested != nil { agreed = false }
                continue
            }
            checked += 1
            if suggested?.positionMillis != CueTime.millis(fromSeconds: plan.mixPointSeconds) { agreed = false }
            if suggested?.reasoning.hasPrefix(plan.reasoning) != true { agreed = false }
        }
        report.expect("the mix-out suggestion is Phantom's own mix point, verbatim", agreed && checked == 3)

        report.expect(
            "no mix-out suggestion when Phantom will not plan",
            !CueSuggester.suggest(CueSuggester.Input(trackId: "short", duration: 10, envelope: syntheticClubTrack(buckets: 10)))
                .contains { $0.kind == .mixOut }
        )
    }

    private static func testSuggesterFindsIntroDropAndBreakdown(_ report: inout Report) {
        let envelope = syntheticClubTrack(buckets: 300)
        let plain = CueSuggester.suggest(CueSuggester.Input(trackId: "t", duration: 300, envelope: envelope))

        let mixIn = plain.first { $0.kind == .mixIn }
        report.expect(
            "finds the ambient opening and starts the deck after it",
            mixIn.map { $0.positionSeconds >= 18 && $0.positionSeconds <= 65 } ?? false
        )
        report.expect(
            "finds at least one drop and one breakdown, both as memory cues",
            plain.filter { $0.kind == .memory }.count >= 2
        )
        report.expect("respects the suggestion cap", plain.count <= CueSuggester.maximumSuggestions)
        report.expect(
            "no two memory suggestions land inside the spacing window",
            {
                let memory = plain.filter { $0.kind == .memory }.map(\.positionMillis).sorted()
                let spacing = CueTime.millis(fromSeconds: CueSuggester.minimumSpacingSeconds)
                return zip(memory, memory.dropFirst()).allSatisfy { $1 - $0 >= spacing }
            }()
        )
        report.expect(
            "the cap never costs a structural suggestion",
            {
                let crowded = (0..<20).map { i in
                    suggestion(kind: .memory, millis: Int64(30_000 + i * 21_000))
                } + [suggestion(kind: .mixIn, millis: 8_000), suggestion(kind: .mixOut, millis: 900_000)]
                let pruned = CueSuggester.prune(crowded)
                return pruned.count == CueSuggester.maximumSuggestions
                    && pruned.contains { $0.kind == .mixIn }
                    && pruned.contains { $0.kind == .mixOut }
            }()
        )
        report.expect(
            "suggestions come back ordered by position",
            zip(plain, plain.dropFirst()).allSatisfy { $0.positionMillis <= $1.positionMillis }
        )
        report.expect(
            "a track with no envelope produces nothing rather than a guess",
            CueSuggester.suggest(CueSuggester.Input(trackId: "t", duration: 300, envelope: [])).isEmpty
        )
        report.expect(
            "a track that opens on the one gets no mix-in suggestion",
            !CueSuggester.suggest(CueSuggester.Input(trackId: "t", duration: 200, envelope: syntheticHardStop(buckets: 200)))
                .contains { $0.kind == .mixIn }
        )

        let grid = BeatGrid(anchor: 0, beatPeriod: 0.5, downbeatOffset: 0, barsPerPhrase: 8, confidence: 0.9)
        let snapped = CueSuggester.suggest(
            CueSuggester.Input(trackId: "t", duration: 300, envelope: envelope, beatGrid: grid)
        )
        report.expect(
            "a confident grid snaps every position onto a bar line and says so",
            !snapped.isEmpty && snapped.allSatisfy { $0.positionMillis % 2_000 == 0 && $0.snappedToGrid }
        )
        report.expect(
            "an unconfident grid does not snap",
            CueSuggester.suggest(CueSuggester.Input(
                trackId: "t", duration: 300, envelope: envelope,
                beatGrid: BeatGrid(anchor: 0, beatPeriod: 0.5, confidence: 0.2)
            )).allSatisfy { !$0.snappedToGrid }
        )

        let withStructure = CueSuggester.suggest(CueSuggester.Input(
            trackId: "t", duration: 300, envelope: envelope,
            sections: [TrackSection(kind: .ambientIntro, start: 0, end: 44)]
        ))
        report.expect(
            "a measured ambient intro wins over the envelope guess, with higher confidence",
            withStructure.first { $0.kind == .mixIn }.map {
                abs($0.positionSeconds - 44) < 0.5 && $0.confidence > (mixIn?.confidence ?? 1)
            } ?? false
        )
    }

    private static func testOrdering(_ report: inout Report) {
        let cues = [
            CuePoint(trackId: "t", kind: .memory, positionMillis: 90_000),
            CuePoint(trackId: "t", kind: .hotCue, positionMillis: 10_000, hotCueIndex: 5),
            CuePoint(trackId: "t", kind: .hotCue, positionMillis: 10_000, hotCueIndex: 1),
            CuePoint(trackId: "t", kind: .mixIn, positionMillis: 10_000),
            CuePoint(trackId: "t", kind: .mixOut, positionMillis: 250_000),
        ]
        let sheet = CueResolution.resolve(
            trackId: "t",
            userCues: cues,
            suggestions: [suggestion(kind: .memory, millis: 10_000)],
            dismissedIds: []
        )

        report.expect(
            "ordered by position",
            zip(sheet.entries, sheet.entries.dropFirst()).allSatisfy { $0.positionMillis <= $1.positionMillis }
        )
        let tied = sheet.entries.filter { $0.positionMillis == 10_000 }
        report.expect(
            "ties break user-first, then by kind, then by hot-cue index",
            tied.count == 4
                && tied[0].kind == .mixIn
                && tied[1].hotCueIndex == 1
                && tied[2].hotCueIndex == 5
                && tied[3].origin == .suggested
        )

        var stable = true
        for _ in 0..<12 {
            let shuffled = CueResolution.resolve(
                trackId: "t",
                userCues: cues.shuffled(),
                suggestions: [suggestion(kind: .memory, millis: 10_000)],
                dismissedIds: []
            )
            if shuffled.entries.map(\.id) != sheet.entries.map(\.id) { stable = false }
        }
        report.expect("the order does not depend on input order", stable)

        report.expect(
            "the accessors find the right entries",
            sheet.mixIn?.kind == .mixIn
                && sheet.mixOut?.positionMillis == 250_000
                && sheet.hotCue(at: 5)?.positionMillis == 10_000
                && sheet.hotCue(at: 7) == nil
        )
    }

    private static func testEnginePrecedence(_ report: inout Report) {
        let userSheet = CueResolution.resolve(
            trackId: "t",
            userCues: [CuePoint(trackId: "t", kind: .mixIn, positionMillis: 32_000),
                       CuePoint(trackId: "t", kind: .mixOut, positionMillis: 280_000)],
            suggestions: [suggestion(kind: .mixIn, millis: 8_000)],
            dismissedIds: []
        )
        let entry = CuePolicy.entry(sheet: userSheet, plannedEntrySeconds: 0, duration: 300)
        report.expect("a user mix-in beats the hard-coded zero", entry.seconds == 32 && entry.source == .userCue)

        let exit = CuePolicy.exit(sheet: userSheet, plannedExitSeconds: 250, duration: 300)
        report.expect("a user mix-out beats the planner", exit.seconds == 280 && exit.source == .userCue)

        let suggestedOnly = CueResolution.resolve(
            trackId: "t", userCues: [], suggestions: [suggestion(kind: .mixIn, millis: 8_000)], dismissedIds: []
        )
        report.expect(
            "a suggestion is ignored by default",
            CuePolicy.entry(sheet: suggestedOnly, plannedEntrySeconds: 0, duration: 300).seconds == 0
        )
        report.expect(
            "…and used only on an explicit opt-in, which is reported as such",
            CuePolicy.entry(sheet: suggestedOnly, plannedEntrySeconds: 0, duration: 300, allowSuggestions: true)
                == CuePolicy.Resolution(seconds: 8, source: .suggestion)
        )
        report.expect(
            "the planner's own entry point outranks a suggestion",
            CuePolicy.entry(sheet: suggestedOnly, plannedEntrySeconds: 16, duration: 300, allowSuggestions: true)
                == CuePolicy.Resolution(seconds: 16, source: .planner)
        )
        report.expect(
            "a suggested mix-out never overrules the planner it came from",
            CuePolicy.exit(
                sheet: CueResolution.resolve(trackId: "t", userCues: [], suggestions: [suggestion(kind: .mixOut, millis: 200_000)], dismissedIds: []),
                plannedExitSeconds: 250,
                duration: 300
            ) == CuePolicy.Resolution(seconds: 250, source: .planner)
        )
    }

    private static func testClampingAgainstAShorterTrack(_ report: inout Report) {
        let sheet = CueResolution.resolve(
            trackId: "t",
            userCues: [CuePoint(trackId: "t", kind: .mixIn, positionMillis: 400_000)],
            suggestions: [],
            dismissedIds: []
        )
        let entry = CuePolicy.entry(sheet: sheet, plannedEntrySeconds: 0, duration: 120)
        report.expect(
            "a cue past the end of a now-shorter track clamps inside it",
            entry.seconds == 120 - CuePolicy.minimumTailSeconds && entry.source == .userCue
        )
        report.expect(
            "a nonsense duration does not produce a nonsense seek",
            CuePolicy.clamp(50, duration: .nan) >= 0 && CuePolicy.clamp(.nan, duration: 300) == 0
        )
    }

    private static func suggestion(kind: CueKind, millis: Int64, version: Int = 1) -> CueSuggestion {
        CueSuggestion(
            trackId: "t",
            kind: kind,
            positionMillis: millis,
            endMillis: nil,
            suggester: CueSuggesterIdentity(name: "sounding.envelope", version: version),
            confidence: 0.5,
            reasoning: "synthetic",
            snappedToGrid: false,
            label: kind.displayName,
            color: .default(for: kind)
        )
    }

    private static func syntheticClubTrack(buckets: Int) -> [Float] {
        (0..<buckets).map { i in
            let t = Double(i) * 300 / Double(max(1, buckets))
            switch t {
            case ..<20:    return 0.01
            case ..<40:    return 0.22
            case ..<60:    return 0.55
            case ..<150:   return 0.9
            case ..<180:   return 0.2
            case ..<270:   return 0.92
            default:       return 0.16
            }
        }
    }

    private static func syntheticFadeOut(buckets: Int) -> [Float] {
        (0..<buckets).map { i in
            let fraction = Double(i) / Double(max(1, buckets - 1))
            return fraction < 0.7 ? 0.9 : Float(0.9 * (1 - (fraction - 0.7) / 0.3))
        }
    }

    private static func syntheticHardStop(buckets: Int) -> [Float] {
        (0..<buckets).map { i in i >= buckets - 1 ? 0.85 : 0.9 }
    }
}

private extension CueSheet {
    func entriesMatching(_ kind: CueKind, _ origin: CueOrigin) -> [ResolvedCue] {
        entries.filter { $0.kind == kind && $0.origin == origin }
    }
}
#endif
