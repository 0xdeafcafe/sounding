import Foundation

var failures = 0

func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL")  \(label)")
    if !condition { failures += 1 }
}

func grid(bpm: Double, anchor: Double, duration: Double, phased: Bool) -> BeatGrid {
    let beat = 60 / bpm
    let beats = phased ? stride(from: anchor, to: duration, by: beat).map { $0 } : nil
    let downbeats = beats.map { all in stride(from: 0, to: all.count, by: 4).map { all[$0] } }
    return BeatGrid(anchor: anchor, beatPeriod: beat, confidence: 0.9, beats: beats, downbeats: downbeats, phraseOffsetBars: 0)
}

struct Case {
    var name: String
    var plan: MixPlanRecord
    var execution: MixExecutionRecord
}

func makeCase(_ name: String, move: MixMove?, stages: [TransitionStage], phased: Bool, accent: TransitionAccent? = nil) -> Case {
    let outGrid = grid(bpm: 124, anchor: 0.21, duration: 360, phased: phased)
    let inGrid = grid(bpm: 126, anchor: 0.08, duration: 330, phased: phased)
    let mixPoint = outGrid.nearestDownbeat(to: 300)
    let entry = inGrid.nearestDownbeat(to: 16)
    let bars = Double(move?.totalBars ?? 16)
    let window = bars * outGrid.barDuration
    let plan = MixPlanRecord(
        mixPointSeconds: mixPoint,
        transitionSeconds: window,
        outroShape: "breakdown",
        accent: accent,
        reasoning: name,
        entrySeconds: entry,
        bassSwapAtSeconds: window * 0.55,
        bassSwapSeconds: 0.4,
        incomingRateRatio: 124.0 / 126.0,
        incomingTrackId: "b",
        profileId: "automaticDJ",
        templateId: move == nil ? "longBlend" : nil,
        stages: stages,
        outgoingBeatGrid: outGrid,
        incomingBeatGrid: inGrid,
        move: move,
        incomingTitle: "B",
        incomingMidCutDecibels: -3
    )
    let execution = MixExecutionRecord(
        startSourceSeconds: mixPoint,
        windowSeconds: window,
        entrySeconds: entry,
        outgoingRate: 1,
        incomingRate: 124.0 / 126.0,
        startedAtPlannedBoundary: true,
        riserLevel: 0.5,
        sampleRate: 48_000
    )
    return Case(name: name, plan: plan, execution: execution)
}

func referenceInput(_ c: Case) -> MixTransitionTimelineInput {
    let plan = c.plan
    return MixTransitionTimelineInput(
        outgoing: 0,
        incoming: 1,
        sampleRate: c.execution.sampleRate,
        anchorSourceSeconds: c.execution.startSourceSeconds,
        window: max(0.15, c.execution.windowSeconds),
        entrySeconds: c.execution.entrySeconds,
        outgoingRate: c.execution.outgoingRate,
        incomingRate: c.execution.incomingRate,
        outgoingGrid: plan.outgoingBeatGrid,
        incomingGrid: plan.incomingBeatGrid,
        stages: plan.stages,
        bassSwapAtSeconds: plan.bassSwapAtSeconds,
        bassSwapSeconds: plan.bassSwapSeconds,
        filterAccent: plan.accent,
        defersIncomingStart: false,
        phaseLock: (plan.outgoingBeatGrid?.isPhaseVerified ?? false) && (plan.incomingBeatGrid?.isPhaseVerified ?? false),
        move: plan.move,
        riserGain: 0.5,
        incomingMidCutDecibels: plan.incomingMidCutDecibels
    )
}

let cases = [
    makeCase("blend 16, tempo grid", move: nil, stages: [
        TransitionStage(at: 0, on: .incoming, .crossfadeTo(position: 1, over: 30)),
        TransitionStage(at: 8, on: .outgoing, .highPassTo(hertz: 400, over: 12))
    ], phased: false, accent: .outgoingFilterClose),
    makeCase("loop mix, phased grid", move: .loopMix(outLoop: 4, inLoop: 4, fadeIn: 8, fadeOut: 4), stages: [], phased: true),
    makeCase("loop roll ladder", move: .loopRoll(MixMove.standardLadder), stages: [
        TransitionStage(at: 0, on: .outgoing, .loop(bars: 8)),
        TransitionStage(at: 16, on: .outgoing, .loop(bars: 4)),
        TransitionStage(at: 24, on: .outgoing, .clearLoop),
        TransitionStage(at: 2, on: .outgoing, .eqLow(decibels: -60, over: 4), snap: .beat)
    ], phased: true),
    makeCase("drop-in", move: .dropIn(buildBars: 8, outBars: 2), stages: [], phased: true),
    makeCase("echo out", move: .echoOut, stages: [TransitionStage(at: 0, on: .outgoing, .echoCut(feedback: 0.5, release: 3))], phased: true),
    makeCase("tempo ramp", move: .tempoRamp(rampBars: 8, to: 1.016, blendBars: 16), stages: [], phased: true)
]

for c in cases {
    let original = MixTimeline.transition(referenceInput(c))
    let data = try! JSONEncoder().encode(c.plan)
    let decoded = try! JSONDecoder().decode(MixPlanRecord.self, from: data)
    let executionData = try! JSONEncoder().encode(c.execution)
    let execution = try! JSONDecoder().decode(MixExecutionRecord.self, from: executionData)
    check(decoded == c.plan, "\(c.name): plan survives a Codable round trip")
    let result = MixReplayPlanner.reconcile(decoded, currentOutgoingGrid: c.plan.outgoingBeatGrid, currentIncomingGrid: c.plan.incomingBeatGrid)
    check(!result.resnapped && result.notice == nil, "\(c.name): unchanged grid replays without re-snapping")
    let replayed = MixTimeline.transition(MixReplayPlanner.timelineInput(plan: result.plan, execution: execution, outgoing: 0, incoming: 1, riserGain: 0.5))
    check(!original.events.isEmpty, "\(c.name): original timeline has \(original.events.count) events, \(original.lengthFrames) frames")
    check(replayed == original, "\(c.name): replayed timeline matches the original event for event")
    let bar = c.plan.barSeconds
    check(abs(result.startSeconds - (c.plan.mixPointSeconds - 8 * bar)) < 1e-9, "\(c.name): replay starts 8 bars before the exit")
}

let base = cases[1]
var moved = base.plan.outgoingBeatGrid!
moved = grid(bpm: 124, anchor: 0.21 + 0.11, duration: 360, phased: true)
let resnap = MixReplayPlanner.reconcile(base.plan, currentOutgoingGrid: moved, currentIncomingGrid: base.plan.incomingBeatGrid)
check(resnap.resnapped, "grid moved by 110 ms: plan is re-snapped")
check(resnap.notice?.contains("nearest bar") == true, "grid moved: the user is told")
check(moved.downbeats!.contains { abs($0 - resnap.plan.mixPointSeconds) < 1e-9 }, "grid moved: exit lands on a downbeat of the new grid")
check(abs(resnap.plan.mixPointSeconds - base.plan.mixPointSeconds) < moved.barDuration / 2, "grid moved: exit stays within half a bar of the recorded point")
check(resnap.plan.entrySeconds == base.plan.entrySeconds, "grid moved on A only: B entry is untouched")

let retempo = grid(bpm: 125.5, anchor: 0.08, duration: 330, phased: true)
let tempoResnap = MixReplayPlanner.reconcile(base.plan, currentOutgoingGrid: base.plan.outgoingBeatGrid, currentIncomingGrid: retempo)
check(tempoResnap.resnapped && tempoResnap.plan.incomingBeatGrid == retempo, "B tempo re-measured: entry re-snapped to the new grid")

let tiny = grid(bpm: 124, anchor: 0.215, duration: 360, phased: true)
let jitter = MixReplayPlanner.reconcile(base.plan, currentOutgoingGrid: tiny, currentIncomingGrid: base.plan.incomingBeatGrid)
check(!jitter.resnapped, "5 ms jitter is within tolerance and keeps the stored plan")

let missing = MixReplayPlanner.reconcile(base.plan, currentOutgoingGrid: nil, currentIncomingGrid: nil)
check(!missing.resnapped && missing.usedRecordedGrid && missing.plan == base.plan, "no current analysis: stored plan and grid are used as recorded")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
