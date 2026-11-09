import Foundation

var failures = 0

func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL")  \(label)")
    if !condition { failures += 1 }
}

func execution(for plan: MixPlanRecord) -> MixExecutionRecord {
    MixExecutionRecord(
        startSourceSeconds: plan.mixPointSeconds,
        windowSeconds: plan.transitionSeconds,
        entrySeconds: plan.entrySeconds,
        outgoingRate: 1,
        incomingRate: plan.incomingRateRatio,
        startedAtPlannedBoundary: true,
        riserLevel: 0,
        sampleRate: 48_000
    )
}

func rampOffsets(_ plan: MixPlanRecord, _ parameter: MixParameter, to value: Double? = nil) -> [Int64] {
    let timeline = MixTimeline.transition(MixReplayPlanner.timelineInput(plan: plan, execution: execution(for: plan), outgoing: 0, incoming: 1))
    return timeline.events.compactMap { event in
        guard case .ramp(let p, let target, _, _) = event.action, p == parameter else { return nil }
        if let value, abs(target - value) > 1e-6 { return nil }
        return event.offset
    }
}

func frames(bars: Double, _ plan: MixPlanRecord) -> Int64 {
    Int64((bars * plan.barSeconds * 48_000).rounded())
}

func near(_ a: Int64?, _ b: Int64, tolerance: Int64 = 2) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

// MARK: - Edited plan produces the expected timeline

let auto = DJPlanFixture.autoTimeline
let edited = DJPlanFixture.editedTimeline
check(auto.bar(.bassSwap) == 13, "auto swap sits at bar 13")
check(auto.forcedPlan == auto.auto, "an unedited transition forces nothing")
check(edited.edit.count == 2, "two edits recorded")
check(edited.bar(.bassSwap) == 17 && edited.point(.bassSwap)?.isUser == true, "user swap at bar 17, flagged as yours")
check(edited.point(.bassSwap)?.autoBar == 13, "auto swap kept as the ghost value")

let forced = edited.forcedPlan
check(forced.move?.shape?.bassSwapBar == 16, "forced plan carries the swap 16 bars after the start")
check(forced.move?.totalBars == 24, "forced plan keeps the 24-bar length")
check(forced.mixPointSeconds == auto.auto.mixPointSeconds && forced.entrySeconds == auto.auto.entrySeconds, "forced plan keeps the exit and entry")
let autoSwap = rampOffsets(auto.auto, .eqLow(0), to: -60).first
let editedSwap = rampOffsets(forced, .eqLow(0), to: -60).first
check(near(autoSwap, frames(bars: 8, auto.auto)), "auto timeline swaps at the release, bar 9 (no shape)")
check(near(editedSwap, frames(bars: 16, forced)), "edited timeline kills the outgoing bass at bar 17")
check(near(rampOffsets(forced, .eqLow(1), to: 0).first, frames(bars: 16, forced)), "edited timeline restores the incoming bass at bar 17")
let crossfades = rampOffsets(forced, .crossfade)
check(crossfades.contains { near($0, frames(bars: 16, forced)) }, "edited timeline starts the fade-out at bar 17")
check(crossfades.contains { near($0, 0) }, "edited timeline still fades in from bar 1")
let shapeData = try! JSONEncoder().encode(forced)
check((try? JSONDecoder().decode(MixPlanRecord.self, from: shapeData)) == forced, "forced plan survives a Codable round trip")
var legacyMove = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(MixMove.cut)) as! [String: Any]
legacyMove["shape"] = nil
check((try? JSONDecoder().decode(MixMove.self, from: JSONSerialization.data(withJSONObject: legacyMove))) == MixMove.cut, "old moves without a shape still decode")

// MARK: - Grid snapping

check(auto.propose(.bassSwap, to: 16.9) == .accepted(bar: 17, note: nil), "drag to 16.9 snaps to the beat at 17")
check(auto.propose(.bassSwap, to: 16.6) == .accepted(bar: 16.5, note: nil), "drag to 16.6 snaps to beat 16.5")
check(auto.propose(.bassSwap, to: 16.9, free: true) == .accepted(bar: 16.9, note: nil), "⌥ drag keeps 16.9")
check(auto.propose(.loopRelease, to: 14) == .accepted(bar: 13, note: nil), "loop release snaps to a whole loop")

let reanalysed = DJPlanTimeline(outgoing: DJPlanFixture.lowSun, incoming: DJPlanFixture.reanalysedSoftStatic, auto: DJPlanFixture.record(
    move: DJPlanFixture.loopMix, from: DJPlanFixture.lowSun, to: DJPlanFixture.reanalysedSoftStatic,
    mixPoint: DJPlanFixture.mixPoint, entry: DJPlanFixture.entry
))
let reconciled = reanalysed.reconciling(edited.edit)
check(reconciled.notes.count == 1, "re-analysis touches only the incoming point")
check(reconciled.notes.first?.text == "Soft Static’s grid was re-analysed. Your swap snapped from 16.9 to bar 17.", "re-analysis note: \(reconciled.notes.first?.text ?? "none")")
check(reconciled.edit.bar(.bassSwap) == 17 && reconciled.edit.bar(.fadeOutStart) == 17, "edits survive re-analysis on the new grid")
check(reanalysed.reconciling(reconciled.edit).notes.isEmpty, "a reconciled edit is stable")

// MARK: - Reorder replanning

var crate = DJPlanFixture.crate
let velvet = crate.tracks.firstIndex { $0.title == "Velvet Hour" }!
var library = DJPlanEditLibrary()
let editedKey = DJPlanTransitionKey(outgoingId: DJPlanFixture.lowSun.id, incomingId: DJPlanFixture.softStatic.id)
library[editedKey].apply(edited.edit)
var planned: Set<DJPlanTransitionKey> = Set(crate.joins)
let moved = crate.move(from: velvet, to: 4)
let replans = (try? moved.get()) ?? []
check(crate.tracks.map(\.title) == ["Night Tapes", "Glass District", "Low Sun", "Soft Static", "Velvet Hour", "Copper Line", "Tidal Rooms", "Halflight"], "Velvet Hour lands after Soft Static")
check(replans == [
    DJPlanTransitionKey(outgoingId: "fixture-soft-static", incomingId: "fixture-velvet-hour"),
    DJPlanTransitionKey(outgoingId: "fixture-velvet-hour", incomingId: "fixture-copper-line")
], "only the two joins it touches replan")
for key in crate.joins where !planned.contains(key) && library[key].edit.isEmpty { planned.insert(key) }
check(crate.joins.allSatisfy { planned.contains($0) }, "every join has a plan after the reorder")
check(library[editedKey].edit == edited.edit, "the edited join keeps its edits")
check(crate.joins.contains(editedKey), "the edited join is still in the crate")
var middle = DJPlanFixture.crate
let copper = middle.tracks.firstIndex { $0.title == "Copper Line" }!
check(((try? middle.move(from: copper, to: middle.tracks.count).get()) ?? []).count == 2, "moving to the end makes the closed gap and the new tail joins")
var locked = DJPlanFixture.crate
check(locked.move(from: 1, to: 6) == .failure(.playing), "the on-air track can't move")
check(locked.move(from: 5, to: 1) == .failure(.beforeLive), "nothing moves before the live mix")

// MARK: - Hard rules

let shortFade = edited.applying(.fadeOutEnd, bar: 21)
check(shortFade.propose(.bassSwap, to: 23) == .refused("Bass swaps while both decks play"), "swap after the outgoing has gone is refused")
check(edited.propose(.fadeOutEnd, to: 15) == .accepted(bar: 17, note: "Can’t pass the other end"), "fade-out end is held at its start")
check(edited.applying(.fadeOutStart, bar: 12).propose(.fadeOutEnd, to: 15) == .refused("Bass swaps while both decks play"), "a fade that would leave the swap stranded is refused")
check(auto.propose(.fadeOutEnd, to: 27) == .refused("Low Sun ends at bar 25"), "fade can't run past the end of the track")
check(auto.propose(.loopRelease, to: 25) == .refused("Loops are capped at 16 bars"), "six passes of a 4-bar loop are refused")
check(auto.propose(.loopRelease, to: 21) == .accepted(bar: 21, note: nil), "five passes are allowed")
var vocal = DJPlanFixture.softStatic
vocal.vocalRanges = [(DJPlanFixture.entry + 4.1 * DJPlanFixture.incomingGrid.barDuration)...(DJPlanFixture.entry + 30 * DJPlanFixture.incomingGrid.barDuration)]
var vocalOut = DJPlanFixture.lowSun
vocalOut.vocalRanges = [(DJPlanFixture.mixPoint + 18 * DJPlanFixture.outgoingGrid.barDuration)...(DJPlanFixture.mixPoint + 23 * DJPlanFixture.outgoingGrid.barDuration)]
let vocalTimeline = DJPlanTimeline(outgoing: vocalOut, incoming: vocal, auto: DJPlanFixture.autoPlan).applying(.fadeOutEnd, bar: 18)
check(!vocalTimeline.vocalsClash, "a short fade keeps the vocals apart")
check(vocalTimeline.propose(.fadeOutEnd, to: 24) == .refused("Vocals would overlap"), "a longer fade into the vocal is refused")
var clash = DJPlanFixture.softStatic
clash.key = CamelotKey(wheelPosition: 12, mode: .minor)
let blendPlan = DJPlanFixture.record(move: .blend(bars: 4, swapAt: 2), from: DJPlanFixture.lowSun, to: clash, mixPoint: DJPlanFixture.mixPoint, entry: DJPlanFixture.entry)
let blend = DJPlanTimeline(outgoing: DJPlanFixture.lowSun, incoming: clash, auto: blendPlan)
check(!blend.keysClash, "a 4-bar blend tolerates keys 3 apart")
check(blend.propose(.fadeOutEnd, to: 9) == .refused("Keys clash past 4 bars"), "stretching it to 8 bars is refused")
check(blend.propose(.fadeOutEnd, to: 5) == .accepted(bar: 5, note: nil), "staying at 4 bars is fine")
check(auto.propose(.fadeInEnd, to: 30) == .refused("Low Sun ends at bar 25"), "nothing moves past the outgoing track's end")
check(auto.propose(.fadeInStart, to: 12) == .accepted(bar: 9, note: "Can’t pass the other end"), "fade-in start is held at its end")
check(auto.propose(.fadeOutStart, to: 30) == .refused("Low Sun ends at bar 25"), "fade-out start can't leave the track")
check(edited.propose(.fadeOutStart, to: 23) == .accepted(bar: 23, note: nil), "fade-out start moves freely within its pair")
check(edited.propose(.fadeOutStart, to: 24.75) == .accepted(bar: 24.75, note: nil), "fade-out start can sit right before its end")

// MARK: - Checks

let checks = edited.checks
check(checks.map(\.title) == ["Phrases line up", "No vocal overlap", "Level stays even", "Bass never doubles"], "edited plan checks: \(checks.map(\.title))")
check(checks.allSatisfy(\.passed), "all four checks pass on the edited plan")
check(edited.applying(.bassSwap, bar: 17.3).checks.first?.passed == false, "a free swap off the bar fails the phrase check")
check(edited.applying(.fadeInEnd, bar: 1).applying(.fadeInStart, bar: 1).applying(.fadeOutStart, bar: 1).applying(.fadeOutEnd, bar: 1.25).checks[2].passed, "an instant handover keeps the level")

// MARK: - Undo and redo

var record = DJPlanEditRecord()
let one = DJPlanFixture.autoTimeline.applying(.bassSwap, bar: 17).edit
let two = DJPlanFixture.editedTimeline.edit
record.apply(one)
record.apply(two)
check(record.edit == two && record.undo.count == 2, "two edits stack")
record.revert()
check(record.edit.isEmpty && record.canUndo, "revert to auto is undoable")
record.undoLast()
check(record.edit == two, "undo brings the edits back")
record.undoLast()
check(record.edit == one && record.redo.count == 2, "undo again steps back one edit")
record.redoLast()
check(record.edit == two, "redo reapplies")
record.apply(one)
check(!record.canRedo, "a new edit clears redo")
var persisted = DJPlanEditLibrary()
persisted[editedKey] = record
let restored = DJPlanEditLibrary(data: persisted.encoded)
check(restored == persisted, "edit history survives encoding")
check(DJPlanEditLibrary(data: Data()) == DJPlanEditLibrary(), "empty data is an empty library")
persisted[editedKey] = DJPlanEditRecord()
check(persisted.records.isEmpty, "an empty record is dropped")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
