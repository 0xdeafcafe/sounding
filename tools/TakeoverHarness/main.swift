import AVFoundation
import Foundation

@MainActor
func runTakeover() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    let engine = MixEngine(offline: true)
    defer { engine.stop() }
    let rate = engine.sampleRate
    func render(_ seconds: Double) {
        try? engine.renderOffline(frames: AVAudioFrameCount(seconds * rate)) { _ in }
    }

    engine.takeOver(MixControl(.filter, deck: .b))
    check(engine.ownedControls == [MixControl(.filter, deck: .b)], "takeOver records the control")

    var timeline = MixTimeline(anchor: .now)
    timeline.add(0.01, .ramp(.lowPass(1), to: 2_000, frames: 0, curve: .linear), sampleRate: rate)
    timeline.add(0.01, .ramp(.eqLow(1), to: -26, frames: 0, curve: .linear), sampleRate: rate)
    engine.schedule(timeline, group: engine.makeGroup())
    render(0.1)
    check(engine[.b].filterCutoff > 15_000, "scheduled automation must not move an owned filter (got \(engine[.b].filterCutoff))")
    check(abs(engine[.b].low + 26) < 0.5, "scheduled automation still moves unowned controls (got \(engine[.b].low))")

    engine.setFilterCutoff(1_000, on: .b)
    render(0.05)
    check(engine[.b].filterCutoff > 15_000, "direct automation writes are blocked on an owned control")

    engine.asUser { engine.setFilterCutoff(2_100, on: .b) }
    render(0.05)
    check(abs(engine[.b].filterCutoff - 2_100) < 1, "user writes reach an owned control (got \(engine[.b].filterCutoff))")

    engine.setEQ(.mid, on: .a, toDecibels: -12)
    render(0.05)
    check(abs(engine[.a].mid + 12) < 0.5, "other controls stay automated")

    engine.handBack(MixControl(.filter, deck: .b))
    check(engine.ownedControls.isEmpty, "handBack releases the control")
    var after = MixTimeline(anchor: .now)
    after.add(0.01, .ramp(.lowPass(1), to: 500, frames: 0, curve: .linear), sampleRate: rate)
    engine.schedule(after, group: engine.makeGroup())
    render(0.1)
    check(abs(engine[.b].filterCutoff - 500) < 1, "automation resumes after hand back (got \(engine[.b].filterCutoff))")

    for control in MixControl.everything { engine.takeOver(control) }
    engine.crossfade(to: 1, over: 0)
    render(0.05)
    check(engine.crossfade < 0.01, "an owned crossfader ignores automation")
    engine.handBackAll()
    check(engine.ownedControls.isEmpty, "handBackAll clears everything")
    return failures
}

let failures = MainActor.assumeIsolated { runTakeover() }
if failures.isEmpty {
    print("PASS  takeover self-test (10 checks)")
    exit(0)
}
for failure in failures { print("FAIL  \(failure)") }
exit(1)
