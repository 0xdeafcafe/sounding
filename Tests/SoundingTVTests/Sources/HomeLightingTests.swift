import Foundation
import XCTest
@testable import SoundingTV

@MainActor
private final class ManualClock {
    var now: TimeInterval = 100
}

@MainActor
private final class RecordingLights: LightWriting {
    struct Write: Equatable {
        let lightID: String
        let changes: LightWriteChanges
        let at: TimeInterval
    }

    let clock: ManualClock
    var writes: [Write] = []
    var latency: TimeInterval = 0
    var failNext = false
    var hold: CheckedContinuation<Void, Never>?
    var holdsWrites = false

    init(clock: ManualClock) {
        self.clock = clock
    }

    func write(_ changes: LightWriteChanges, to lightID: String) async throws {
        writes.append(Write(lightID: lightID, changes: changes, at: clock.now))
        if holdsWrites {
            await withCheckedContinuation { hold = $0 }
        }
        clock.now += latency
        if failNext {
            failNext = false
            throw HomeLightingWriteError.unknownLight
        }
    }

    func release() {
        hold?.resume()
        hold = nil
    }
}

private func state(_ hue: Double, _ brightness: Double, saturation: Double = 0.8) -> LightState {
    LightState(color: LightColor(hue: hue, saturation: saturation), brightness: brightness)
}

@MainActor
final class LightWriteSchedulerTests: XCTestCase {
    private func makeScheduler(
        policy: LightWritePolicy = .standard
    ) -> (LightWriteScheduler, RecordingLights, ManualClock) {
        let clock = ManualClock()
        let lights = RecordingLights(clock: clock)
        let scheduler = LightWriteScheduler(backend: lights, policy: policy, now: { clock.now }, wakesItself: false)
        return (scheduler, lights, clock)
    }

    func testAtMostNWritesPerSecondPerLight() async {
        let (scheduler, lights, clock) = makeScheduler(policy: LightWritePolicy(writesPerSecondPerLight: 2, writesPerSecondTotal: 100))
        for step in 0..<20 {
            scheduler.submit(state(Double(step * 10), 0.5), to: ["lamp"])
            await scheduler.settle()
            clock.now += 0.1
        }
        await scheduler.settle()
        XCTAssertEqual(lights.writes.count, 4)
        let times = lights.writes.map(\.at)
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 0.5 - 0.0001)
        }
    }

    func testBurstCoalescesToTheLatestState() async {
        let (scheduler, lights, clock) = makeScheduler()
        scheduler.submit(state(0, 0.5), to: ["lamp"])
        await scheduler.settle()
        for hue in stride(from: 10.0, through: 90.0, by: 10) {
            scheduler.submit(state(hue, 0.5), to: ["lamp"])
        }
        XCTAssertEqual(scheduler.pendingCount, 1)
        clock.now += 1
        scheduler.pump()
        await scheduler.settle()
        XCTAssertEqual(lights.writes.count, 2)
        XCTAssertEqual(lights.writes.last?.changes.hue ?? -1, 90, accuracy: 0.001)
        XCTAssertNil(lights.writes.last?.changes.brightness)
    }

    func testUnchangedStateIsNotWrittenAgain() async {
        let (scheduler, lights, clock) = makeScheduler()
        scheduler.submit(state(200, 0.7), to: ["lamp"])
        await scheduler.settle()
        clock.now += 2
        scheduler.submit(state(200.5, 0.704), to: ["lamp"])
        await scheduler.settle()
        XCTAssertEqual(lights.writes.count, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testOnlyChangedCharacteristicsAreWritten() async {
        let (scheduler, lights, clock) = makeScheduler()
        scheduler.submit(state(120, 0.4), to: ["lamp"])
        await scheduler.settle()
        XCTAssertEqual(lights.writes.first?.changes.characteristicCount, 4)
        clock.now += 1
        scheduler.submit(state(120, 0.9), to: ["lamp"])
        await scheduler.settle()
        XCTAssertEqual(lights.writes.last?.changes, LightWriteChanges(brightness: 0.9))
    }

    func testBrightnessOnlyLightsNeverReceiveColour() async {
        let (scheduler, lights, _) = makeScheduler()
        scheduler.setCapabilities(["shelf": [.power, .brightness]])
        scheduler.submit(state(300, 0.6), to: ["shelf"])
        await scheduler.settle()
        XCTAssertEqual(lights.writes.first?.changes, LightWriteChanges(isOn: true, brightness: 0.6))
    }

    func testTotalCapSpreadsALargeRoomOverSeconds() async {
        let (scheduler, lights, clock) = makeScheduler(policy: LightWritePolicy(writesPerSecondPerLight: 1, writesPerSecondTotal: 8))
        let ids = (0..<12).map { "light\($0)" }
        scheduler.submit(state(10, 0.5), to: ids)
        await scheduler.settle()
        XCTAssertEqual(lights.writes.count, 8)
        clock.now += 0.5
        scheduler.pump()
        await scheduler.settle()
        XCTAssertEqual(lights.writes.count, 8)
        clock.now += 0.5
        scheduler.pump()
        await scheduler.settle()
        XCTAssertEqual(lights.writes.count, 12)
        XCTAssertEqual(Set(lights.writes.map(\.lightID)).count, 12)
    }

    func testNoSecondWriteWhileOneIsInFlight() async {
        let (scheduler, lights, clock) = makeScheduler()
        lights.holdsWrites = true
        scheduler.submit(state(10, 0.5), to: ["lamp"])
        while lights.hold == nil { await Task.yield() }
        clock.now += 3
        scheduler.submit(state(50, 0.5), to: ["lamp"])
        XCTAssertEqual(lights.writes.count, 1)
        lights.holdsWrites = false
        lights.release()
        await scheduler.settle()
        scheduler.pump()
        await scheduler.settle()
        XCTAssertEqual(lights.writes.count, 2)
        XCTAssertEqual(lights.writes.last?.changes.hue ?? -1, 50, accuracy: 0.001)
    }

    func testFailedWriteResendsTheWholeStateNextTime() async {
        let (scheduler, lights, clock) = makeScheduler()
        lights.failNext = true
        scheduler.submit(state(10, 0.5), to: ["lamp"])
        await scheduler.settle()
        XCTAssertEqual(scheduler.failures, 1)
        clock.now += 1
        scheduler.submit(state(10, 0.6), to: ["lamp"])
        await scheduler.settle()
        XCTAssertEqual(lights.writes.last?.changes.characteristicCount, 4)
    }

    func testLatencyIsMeasuredFromTheBackend() async {
        let (scheduler, lights, clock) = makeScheduler()
        lights.latency = 0.8
        for index in 0..<10 {
            scheduler.submit(state(Double(index * 30), 0.5), to: ["lamp"])
            await scheduler.settle()
            clock.now += 1
        }
        XCTAssertEqual(scheduler.latency, 0.8, accuracy: 0.05)
    }
}

final class LightingLookaheadTests: XCTestCase {
    private func plan() -> LightingPlan {
        let cues = [0.0, 16, 32, 48].map { LightCue(time: $0, state: state($0, 0.5), kind: .phrase) }
        let phrases = [0.0, 16, 32, 48].map {
            LightingPhrase(start: $0, end: $0 + 16, energy: 0.5, relative: 1, kind: .steady)
        }
        return LightingPlan(trackID: "t", phrases: phrases, cues: cues)
    }

    func testCueFiresEarlyByTheMeasuredLead() {
        var cursor = LightingCueCursor(plan: plan(), lead: 0.4)
        XCTAssertEqual(cursor.advance(to: 0)?.time, 0)
        for position in stride(from: 0.25, through: 15.5, by: 0.25) {
            XCTAssertNil(cursor.advance(to: position))
        }
        XCTAssertEqual(cursor.advance(to: 15.65)?.time, 16)
        XCTAssertNil(cursor.advance(to: 16.2))
    }

    func testEachCueFiresOnce() {
        var cursor = LightingCueCursor(plan: plan(), lead: 0.3)
        var fired: [TimeInterval] = []
        var position = 0.0
        while position < 60 {
            if let cue = cursor.advance(to: position) { fired.append(cue.time) }
            position += 0.5
        }
        XCTAssertEqual(fired, [0, 16, 32, 48])
    }

    func testSeekResyncsToTheCurrentPhrase() {
        var cursor = LightingCueCursor(plan: plan(), lead: 0.3)
        _ = cursor.advance(to: 1)
        XCTAssertEqual(cursor.advance(to: 40)?.time, 32)
        XCTAssertEqual(cursor.advance(to: 20)?.time, 16)
        XCTAssertNil(cursor.advance(to: 20.5))
    }

    func testShortStallStillFiresTheMissedCue() {
        var cursor = LightingCueCursor(plan: plan(), lead: 0)
        _ = cursor.advance(to: 14)
        XCTAssertEqual(cursor.advance(to: 16.5)?.time, 16)
    }

    func testLookaheadCoversTheNextPhraseOnly() {
        let cursor = LightingCueCursor(plan: plan(), lead: 0.5)
        let window = cursor.lookaheadWindow(at: 10)
        XCTAssertEqual(window, 16)
        XCTAssertEqual(cursor.upcoming(after: 10, within: window).map(\.time), [16])
    }
}

final class LightingPlannerTests: XCTestCase {
    private func envelope(_ segments: [(seconds: Int, level: Float)]) -> [Float] {
        segments.flatMap { Array(repeating: $0.level, count: $0.seconds) }
    }

    private let palette = [
        LightColor(hue: 210, saturation: 0.7),
        LightColor(hue: 330, saturation: 0.95),
        LightColor(hue: 40, saturation: 0.6),
    ]

    func testMeasuredPhrasesAreUsed() {
        let analysis = LightingAnalysis(
            trackID: "a", duration: 120, envelope: envelope([(120, 0.5)]),
            phraseStarts: [15, 30, 45, 60, 75, 90, 105], bpm: 128, palette: palette
        )
        XCTAssertEqual(LightingPlanner.phraseStarts(for: analysis), [0, 15, 30, 45, 60, 75, 90, 105])
    }

    func testTempoFallbackMakesEightBarPhrases() {
        let analysis = LightingAnalysis(
            trackID: "a", duration: 120, envelope: envelope([(120, 0.5)]),
            phraseStarts: [], bpm: 128, palette: palette
        )
        let starts = LightingPlanner.phraseStarts(for: analysis)
        XCTAssertEqual(starts.first, 0)
        XCTAssertEqual(starts[1], 15, accuracy: 0.01)
        XCTAssertEqual(starts.count, 8)
    }

    func testDropAndBreakdownAreFound() {
        let analysis = LightingAnalysis(
            trackID: "a", duration: 96, envelope: envelope([(32, 0.5), (16, 0.15), (16, 0.95), (32, 0.5)]),
            phraseStarts: [16, 32, 48, 64, 80], bpm: nil, palette: palette
        )
        let kinds = LightingPlanner.phrases(for: analysis).map(\.kind)
        XCTAssertEqual(kinds, [.steady, .steady, .breakdown, .drop, .steady, .steady])
    }

    func testPartyPulsesOnTheDropThenReleases() {
        let analysis = LightingAnalysis(
            trackID: "a", duration: 96, envelope: envelope([(32, 0.5), (16, 0.15), (16, 0.95), (32, 0.5)]),
            phraseStarts: [16, 32, 48, 64, 80], bpm: nil, palette: palette
        )
        let plan = LightingPlanner.plan(analysis, intensity: .party)
        let drop = plan.cues.first { $0.kind == .drop }
        let release = plan.cues.first { $0.kind == .dropRelease }
        XCTAssertEqual(drop?.time, 48)
        XCTAssertEqual(drop?.state.brightness, 1)
        XCTAssertEqual(drop?.state.color.hue ?? -1, 330, accuracy: 0.01)
        XCTAssertEqual(release?.time ?? 0, 49.5, accuracy: 0.01)
        XCTAssertLessThan(release?.state.brightness ?? 1, 1.0001)

        let subtle = LightingPlanner.plan(analysis, intensity: .subtle)
        XCTAssertFalse(subtle.cues.contains { $0.kind == .drop })
        XCTAssertLessThanOrEqual(subtle.cues.map(\.state.brightness).max() ?? 1, 0.6 + 0.0001)
    }

    func testDropPulsesAreRateLimited() {
        let analysis = LightingAnalysis(
            trackID: "a", duration: 64,
            envelope: envelope([(8, 0.15), (8, 0.95), (8, 0.15), (8, 0.95), (32, 0.5)]),
            phraseStarts: [8, 16, 24, 32], bpm: nil, palette: palette
        )
        let plan = LightingPlanner.plan(analysis, intensity: .party)
        XCTAssertEqual(plan.cues.filter { $0.kind == .drop }.count, 1)
    }

    func testBreakdownFadesSlowlyDownwards() {
        let analysis = LightingAnalysis(
            trackID: "a", duration: 96, envelope: envelope([(32, 0.8), (32, 0.1), (32, 0.8)]),
            phraseStarts: [32, 64], bpm: nil, palette: palette
        )
        let plan = LightingPlanner.plan(analysis, intensity: .party)
        let fade = plan.cues.filter { $0.kind == .breakdown }
        XCTAssertGreaterThanOrEqual(fade.count, 4)
        let levels = fade.map(\.state.brightness)
        XCTAssertEqual(levels, levels.sorted(by: >))
        XCTAssertGreaterThanOrEqual((fade.last?.time ?? 0) - (fade.first?.time ?? 0), 6)
    }

    func testCuesRespectTheWriteInterval() {
        let analysis = LightingAnalysis(
            trackID: "a", duration: 300,
            envelope: (0..<300).map { Float(0.2 + 0.7 * abs(sin(Double($0) / 9))) },
            phraseStarts: stride(from: 7.0, to: 300, by: 7).map { $0 }, bpm: nil, palette: palette
        )
        for spacing in [1.0, 2.0] {
            let cues = LightingPlanner.plan(analysis, intensity: .party, minimumCueSpacing: spacing).cues
            for (a, b) in zip(cues, cues.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.time - a.time, spacing - 0.0001)
            }
        }
    }

    func testOffPlansNothing() {
        let analysis = LightingAnalysis(
            trackID: "a", duration: 60, envelope: envelope([(60, 0.5)]),
            phraseStarts: [], bpm: nil, palette: palette
        )
        XCTAssertTrue(LightingPlanner.plan(analysis, intensity: .off).cues.isEmpty)
    }

    func testSteadyPhrasesCycleThroughThePalette() {
        let analysis = LightingAnalysis(
            trackID: "a", duration: 64, envelope: envelope([(64, 0.5)]),
            phraseStarts: [16, 32, 48], bpm: nil, palette: palette
        )
        let hues = LightingPlanner.plan(analysis, intensity: .subtle).cues.map(\.state.color.hue)
        XCTAssertEqual(hues, [210, 330, 40, 210])
    }

    func testEmptyPaletteFallsBackToAWarmGlow() {
        let analysis = LightingAnalysis(
            trackID: "a", duration: 32, envelope: envelope([(32, 0.5)]),
            phraseStarts: [], bpm: nil, palette: []
        )
        XCTAssertEqual(LightingPlanner.plan(analysis, intensity: .subtle).cues.first?.state.color, .warmGlow)
    }
}

final class LightingMappingTests: XCTestCase {
    func testBrightnessFollowsEnergyWithinEachIntensity() {
        for intensity in [LightingIntensity.subtle, .party] {
            let levels = stride(from: 0.0, through: 1.0, by: 0.1).map {
                LightingPlanner.brightness(forEnergy: $0, intensity: intensity)
            }
            XCTAssertEqual(levels, levels.sorted())
            XCTAssertEqual(levels.first ?? -1, intensity.brightnessRange.lowerBound, accuracy: 0.0001)
            XCTAssertEqual(levels.last ?? -1, intensity.brightnessRange.upperBound, accuracy: 0.0001)
        }
        XCTAssertGreaterThan(
            LightingPlanner.brightness(forEnergy: 0.7, intensity: .party),
            LightingPlanner.brightness(forEnergy: 0.7, intensity: .subtle)
        )
        XCTAssertEqual(LightingPlanner.brightness(forEnergy: .nan, intensity: .party), 0.25, accuracy: 0.0001)
        XCTAssertEqual(LightingPlanner.brightness(forEnergy: 4, intensity: .party), 1, accuracy: 0.0001)
    }

    func testRestingAndWindDownDim() {
        let playing = state(200, 0.8)
        XCTAssertLessThan(LightingPlanner.resting(from: playing, intensity: .party).brightness, 0.8)
        let start = LightingPlanner.windDown(from: playing, progress: 0)
        let end = LightingPlanner.windDown(from: playing, progress: 1)
        XCTAssertEqual(start.brightness, 0.8, accuracy: 0.0001)
        XCTAssertEqual(end.brightness, 0.03, accuracy: 0.0001)
        XCTAssertEqual(end.color.hue, LightColor.warmGlow.hue, accuracy: 0.01)
        XCTAssertEqual(WindDownController.gain(at: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(WindDownController.gain(at: 1), 0, accuracy: 0.0001)
        let gains = stride(from: 0.0, through: 1.0, by: 0.05).map(WindDownController.gain(at:))
        XCTAssertEqual(gains, gains.sorted(by: >))
    }

    private func image(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                out += [r, g, b, 255]
            }
        }
        return out
    }

    func testPaletteFindsTheArtworkHues() {
        let pixels = image(width: 24, height: 24) { x, _ in x < 12 ? (220, 30, 40) : (30, 60, 210) }
        let colors = LightPalette.colors(rgba: pixels, width: 24, height: 24)
        XCTAssertEqual(colors.count, 2)
        XCTAssertTrue(colors.contains { LightState.hueDistance($0.hue, 357) < 10 })
        XCTAssertTrue(colors.contains { LightState.hueDistance($0.hue, 228) < 10 })
        XCTAssertTrue(colors.allSatisfy { $0.saturation >= 0.6 })
    }

    func testDominantColourComesFirstAndSmallSpecksAreIgnored() {
        let pixels = image(width: 24, height: 24) { x, y in
            if x == 0, y == 0 { return (20, 200, 40) }
            return x < 18 ? (240, 120, 20) : (120, 40, 200)
        }
        let colors = LightPalette.colors(rgba: pixels, width: 24, height: 24)
        XCTAssertEqual(colors.first.map { LightState.hueDistance($0.hue, 30) < 10 }, true)
        XCTAssertFalse(colors.contains { LightState.hueDistance($0.hue, 128) < 20 })
    }

    func testGreyArtworkHasNoPalette() {
        let pixels = image(width: 24, height: 24) { x, _ in
            let v = UInt8(40 + x * 8)
            return (v, v, v)
        }
        XCTAssertTrue(LightPalette.colors(rgba: pixels, width: 24, height: 24).isEmpty)
    }

    func testPaletteFromACGImage() throws {
        let side = 64
        var pixels = image(width: side, height: side) { _, y in y < side / 2 ? (250, 200, 30) : (20, 180, 170) }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes: &pixels, count: pixels.count) as CFData))
        let cg = try XCTUnwrap(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let colors = LightPalette.colors(from: cg)
        XCTAssertEqual(colors.count, 2)
    }

    func testIntensitySurvivesTheWire() {
        for intensity in LightingIntensity.allCases {
            XCTAssertEqual(LightingIntensity(wireValue: intensity.wireValue), intensity)
        }
        XCTAssertEqual(MessageType(rawValue: "scene_party"), .sceneParty)
        XCTAssertTrue(MessageType.sceneWindDown.isControlCommand)
        XCTAssertFalse(MessageType.sceneParty.isContinuousControl)
    }
}

@MainActor
final class HomeLightingSelectionTests: XCTestCase {
    func testRoomSelectionIncludesEveryLightAndPersists() throws {
        let suite = "HomeLightingSelectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let all: LightCapabilities = [.power, .brightness, .color]
        let living = HomeRoomInfo(id: "living", name: "Living Room", lights: [
            HomeLightInfo(id: "a", name: "A", roomID: "living", capabilities: all),
            HomeLightInfo(id: "b", name: "B", roomID: "living", capabilities: all),
        ])
        let kitchen = HomeRoomInfo(id: "kitchen", name: "Kitchen", lights: [
            HomeLightInfo(id: "c", name: "C", roomID: "kitchen", capabilities: all),
        ])
        let snapshot = HomeSnapshot(access: .ready, homes: [
            HomeInfo(id: "home", name: "Home", isPrimary: true, rooms: [living, kitchen]),
        ])

        let settings = HomeLightingSettings(defaults: defaults)
        settings.setRoom(living, selected: true)
        settings.setLight(kitchen.lights[0], selected: true)
        settings.intensity = .party
        XCTAssertEqual(settings.selectedLights(in: snapshot).map(\.id), ["a", "b", "c"])

        let reloaded = HomeLightingSettings(defaults: defaults)
        XCTAssertEqual(reloaded.intensity, .party)
        XCTAssertEqual(reloaded.selectedLights(in: snapshot).map(\.id), ["a", "b", "c"])
        reloaded.setRoom(living, selected: false)
        XCTAssertEqual(reloaded.selectedLights(in: snapshot).map(\.id), ["c"])
    }
}
