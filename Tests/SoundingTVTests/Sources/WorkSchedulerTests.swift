import XCTest
@testable import SoundingTV

@MainActor
final class WorkSchedulerTests: XCTestCase {
    func testLatestWorkUsesAResettableDebounce() async throws {
        let scheduler = WorkScheduler.shared
        let queue = WorkScheduler.QueueID(rawValue: "test.debounce.\(UUID().uuidString)")
        var delivered: [Int] = []

        scheduler.submit(
            queue: queue,
            key: "snapshot",
            delivery: .latest,
            delay: .milliseconds(30)
        ) {
            delivered.append(1)
        }
        try await Task.sleep(for: .milliseconds(15))
        scheduler.submit(
            queue: queue,
            key: "snapshot",
            delivery: .latest,
            delay: .milliseconds(30)
        ) {
            delivered.append(2)
        }

        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(delivered.isEmpty)
        await scheduler.flush(queue)
        XCTAssertEqual(delivered, [2])
    }

    func testPeriodicRegistrationWithSameIDCannotMultiply() async throws {
        let scheduler = WorkScheduler.shared
        let id = "test.periodic.\(UUID().uuidString)"
        var replacedRuns = 0
        var activeRuns = 0

        scheduler.registerPeriodic(
            id: id,
            scope: "test",
            initialDelay: .milliseconds(50),
            interval: .seconds(60)
        ) {
            replacedRuns += 1
        }
        scheduler.registerPeriodic(
            id: id,
            scope: "test",
            interval: .seconds(60)
        ) {
            activeRuns += 1
        }

        try await Task.sleep(for: .milliseconds(20))
        scheduler.cancelPeriodic(id: id)
        XCTAssertEqual(replacedRuns, 0)
        XCTAssertEqual(activeRuns, 1)
    }

    func testReadyBatchRunsHigherPriorityBeforeOlderBackgroundWork() async {
        let scheduler = WorkScheduler.shared
        let queue = WorkScheduler.QueueID(rawValue: "test.priority.\(UUID().uuidString)")
        var delivered: [String] = []

        scheduler.submit(
            queue: queue,
            key: "background",
            delivery: .fifo,
            delay: .milliseconds(20),
            priority: .background
        ) {
            delivered.append("background")
        }
        scheduler.submit(
            queue: queue,
            key: "interactive",
            delivery: .fifo,
            delay: .milliseconds(20),
            priority: .userInitiated
        ) {
            delivered.append("interactive")
        }

        await scheduler.flush(queue)
        XCTAssertEqual(delivered, ["interactive", "background"])
    }

    @MainActor
    func testDeliveredOperationRemainsOnMainActor() async {
        let scheduler = WorkScheduler.shared
        let queue = WorkScheduler.QueueID(rawValue: "tests.main-actor-delivery")
        var ranOnMainActor = false

        scheduler.submit(
            queue: queue,
            key: "background-ordered-ui-state",
            delivery: .fifo,
            priority: .background
        ) {
            MainActor.preconditionIsolated()
            ranOnMainActor = true
        }

        await scheduler.flush(queue)
        XCTAssertTrue(ranOnMainActor)
    }

    func testSnapshotExposesEnvironmentAndPeriodicDiagnostics() {
        let scheduler = WorkScheduler.shared
        let id = "test.diagnostics.\(UUID().uuidString)"
        let environment = WorkScheduler.Environment(
            isForeground: false,
            hasNetwork: false,
            isOnExternalPower: true
        )
        scheduler.updateEnvironment(environment)
        scheduler.registerPeriodic(
            id: id,
            scope: "test-diagnostics",
            initialDelay: .seconds(60),
            interval: .seconds(120),
            constraints: [.foreground, .network]
        ) {}
        defer {
            scheduler.cancelPeriodic(id: id)
            scheduler.updateEnvironment(.init())
        }

        let snapshot = scheduler.snapshot()
        XCTAssertEqual(snapshot.environment, environment)
        XCTAssertEqual(snapshot.periodic.first(where: { $0.id == id })?.scope, "test-diagnostics")
        XCTAssertEqual(
            snapshot.periodic.first(where: { $0.id == id })?.constraints,
            [.foreground, .network]
        )
    }

    func testConstrainedRetryableWorkResumesWhenEnvironmentAllowsIt() async {
        let scheduler = WorkScheduler.shared
        let queue = WorkScheduler.QueueID(rawValue: "test.constraints.\(UUID().uuidString)")
        scheduler.updateEnvironment(.init(isForeground: true, hasNetwork: false, isOnExternalPower: true))
        defer { scheduler.updateEnvironment(.init()) }
        var runs = 0

        scheduler.submitRetrying(queue: queue, key: "network", constraints: [.network]) {
            runs += 1
        }
        await scheduler.flush(queue)
        XCTAssertEqual(runs, 0)

        scheduler.updateEnvironment(.init())
        await scheduler.flush(queue)
        XCTAssertEqual(runs, 1)
    }
}

final class DJTransitionPlanningPolicyTests: XCTestCase {
    func testPlanningRunsWhenBothSidesExist() {
        XCTAssertTrue(DJTransitionPlanningPolicy.shouldPlan(
            isEnabled: true,
            sessionIsEnabled: true,
            hasCurrentTrack: true,
            hasUpcomingTrack: true
        ))
    }

    func testAutoMixStartsTracksInTheMixEngine() {
        func starts(
            enabled: Bool = true,
            elsewhere: Bool = false,
            duration: TimeInterval = 240,
            loaded: Bool = false,
            fellBack: Bool = false
        ) -> Bool {
            DJTransitionPlanningPolicy.startsInMixEngine(
                sessionIsEnabled: enabled,
                exclusiveElsewhere: elsewhere,
                trackDuration: duration,
                isLoadedOnDeck: loaded,
                fellBackToAVPlayer: fellBack
            )
        }
        XCTAssertTrue(starts())
        XCTAssertFalse(starts(enabled: false))
        XCTAssertFalse(starts(elsewhere: true))
        XCTAssertFalse(starts(fellBack: true))
        XCTAssertFalse(starts(duration: 7_200))
        XCTAssertTrue(starts(duration: 7_200, loaded: true))
        XCTAssertFalse(starts(loaded: true, fellBack: true))
    }

    func testPlanningRequiresBothSidesOfTheTransition() {
        XCTAssertFalse(DJTransitionPlanningPolicy.shouldPlan(
            isEnabled: true,
            sessionIsEnabled: true,
            hasCurrentTrack: true,
            hasUpcomingTrack: false
        ))
    }
}

final class PlaybackTimelinePolicyTests: XCTestCase {
    func testPositionIsBoundedByTheActiveTrack() {
        XCTAssertEqual(PlaybackTimelinePolicy.clampedPosition(10_800, duration: 3_600), 3_600)
        XCTAssertEqual(PlaybackTimelinePolicy.clampedPosition(-20, duration: 3_600), 0)
        XCTAssertEqual(PlaybackTimelinePolicy.clampedPosition(.nan, duration: 3_600), 0)
    }

    func testDelayedControlFromPreviousTrackIsRejected() {
        XCTAssertFalse(PlaybackTimelinePolicy.accepts(expectedTrackID: "old-set", activeTrackID: "new-set"))
        XCTAssertTrue(PlaybackTimelinePolicy.accepts(expectedTrackID: "new-set", activeTrackID: "new-set"))
        XCTAssertTrue(PlaybackTimelinePolicy.accepts(expectedTrackID: nil, activeTrackID: "new-set"))
    }

    func testTransitionCueBeyondIncomingTrackStartsAtZero() {
        XCTAssertEqual(PlaybackTimelinePolicy.transitionStartPosition(10_800, duration: 3_600), 0)
        XCTAssertEqual(PlaybackTimelinePolicy.transitionStartPosition(32, duration: 3_600), 32)
    }
}

final class PlaybackBufferingPolicyTests: XCTestCase {
    func testHalfSecondOfClockProgressPreventsRecovery() {
        XCTAssertTrue(PlaybackBufferingPolicy.hasNotAdvanced(currentTime: 1_200.49, from: 1_200))
        XCTAssertFalse(PlaybackBufferingPolicy.hasNotAdvanced(currentTime: 1_200.5, from: 1_200))
    }

    func testInvalidClockIsTreatedAsUnresponsive() {
        XCTAssertTrue(PlaybackBufferingPolicy.hasNotAdvanced(currentTime: .nan, from: 0))
        XCTAssertTrue(PlaybackBufferingPolicy.hasNotAdvanced(currentTime: 0, from: .infinity))
    }
}

final class LibraryCachePaginationTests: XCTestCase {
    func testSectionWindowsStayBoundedAndStable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LibraryCache(directory: directory)
        let rows = (0..<250).map { index in
            LibraryCache.WriteRow(
                id: "track-\(index)",
                payload: Data("payload-\(index)".utf8)
            )
        }
        await cache.replaceSection("test", rows: rows)

        let first = cache.loadSection("test", offset: 0, limit: 100)
        let second = cache.loadSection("test", offset: 100, limit: 100)
        let tail = cache.loadSection("test", offset: 200, limit: 100)

        XCTAssertEqual(first.count, 100)
        XCTAssertEqual(second.count, 100)
        XCTAssertEqual(tail.count, 50)
        XCTAssertEqual(String(decoding: first[0].payload, as: UTF8.self), "payload-0")
        XCTAssertEqual(String(decoding: second[0].payload, as: UTF8.self), "payload-100")
        XCTAssertEqual(String(decoding: tail[0].payload, as: UTF8.self), "payload-200")
    }
}

final class LibraryCacheConcurrencyTests: XCTestCase {
    func testSynchronousReadsDuringWritesStayConsistent() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-cache-concurrency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LibraryCache(directory: directory)
        let rows = (0..<400).map { index in
            LibraryCache.WriteRow(id: "track-\(index)", payload: Data(repeating: UInt8(index % 251), count: 512))
        }
        await cache.replaceSection("test", rows: rows)

        let pageCounts = await withTaskGroup(of: [Int].self) { group in
            for _ in 0..<6 {
                group.addTask {
                    (0..<40).map { _ in cache.loadSection("test", limit: 100).count }
                }
            }
            group.addTask {
                for _ in 0..<20 {
                    await cache.replaceSection("test", rows: rows)
                    await cache.mergeSection("test", rows: Array(rows.prefix(50)))
                }
                return []
            }
            var counts: [Int] = []
            for await batch in group { counts.append(contentsOf: batch) }
            return counts
        }

        XCTAssertEqual(pageCounts.count, 240)
        XCTAssertTrue(pageCounts.allSatisfy { $0 == 100 }, "a reader observed a half-written section")
        XCTAssertEqual(cache.loadSection("test").count, 400)
    }
}

private actor AnalysisLaneProbe {
    private(set) var running = 0
    private(set) var maxRunning = 0
    private(set) var finished = 0

    func begin() {
        running += 1
        maxRunning = max(maxRunning, running)
    }

    func end() {
        running -= 1
        finished += 1
    }
}

private final class AnalysisLaneConditionsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AnalysisLaneConditions

    init(_ conditions: AnalysisLaneConditions) { current = conditions }

    var value: AnalysisLaneConditions {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

final class AnalysisLaneTests: XCTestCase {
    private func runJobs(
        _ count: Int,
        on scheduler: AutomaticAnalysisScheduler,
        probe: AnalysisLaneProbe,
        duration: Duration = .milliseconds(150)
    ) async throws {
        let before = await probe.finished
        for _ in 0..<count {
            scheduler.enqueueBackground(
                key: "lane-test-\(UUID().uuidString)",
                pausesDuringPlayback: false
            ) {
                await probe.begin()
                try? await Task.sleep(for: duration)
                await probe.end()
            }
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while await probe.finished < before + count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let finished = await probe.finished
        XCTAssertEqual(finished, before + count)
    }

    func testBackgroundWorkRunsOneJobAtATime() async throws {
        let probe = AnalysisLaneProbe()
        let phoneInUse = AnalysisLaneConditions(device: .phone, isOnPower: false, isPlaying: false)
        let scheduler = AutomaticAnalysisScheduler(backgroundPriority: .userInitiated, conditions: { phoneInUse })
        try await runJobs(3, on: scheduler, probe: probe)
        let maxRunning = await probe.maxRunning
        XCTAssertEqual(maxRunning, 1)
    }

    func testBackgroundRunsOneAtATimeOnPowerAndDuringPlayback() async throws {
        let box = AnalysisLaneConditionsBox(AnalysisLaneConditions(
            device: .mac, performanceCores: 6, isOnPower: true, isPlaying: false
        ))
        let scheduler = AutomaticAnalysisScheduler(backgroundPriority: .userInitiated, conditions: { box.value })

        let idle = AnalysisLaneProbe()
        try await runJobs(8, on: scheduler, probe: idle, duration: .milliseconds(400))
        let idleMax = await idle.maxRunning
        XCTAssertEqual(idleMax, 1)

        box.value.isPlaying = true
        let playing = AnalysisLaneProbe()
        try await runJobs(3, on: scheduler, probe: playing)
        let playingMax = await playing.maxRunning
        XCTAssertEqual(playingMax, 1)
    }

    func testSystemPauseHoldsBackgroundWorkButNotRequests() {
        let paused = AnalysisLaneConditions(device: .mac, performanceCores: 8, isOnPower: true, isPlaying: false, systemPause: "hot")
        XCTAssertEqual(AnalysisLanePolicy.backgroundLanes(paused), 0)
        XCTAssertEqual(AnalysisLanePolicy.capacity(paused), 1)
    }

    func testLaneCountFollowsDeviceAndPower() {
        func lanes(_ device: DeviceClass, power: Bool, playing: Bool = false, idle: Bool = false, cores: Int = 8) -> Int {
            AnalysisLanePolicy.backgroundLanes(AnalysisLaneConditions(
                device: device, performanceCores: cores, isOnPower: power, isPlaying: playing, isScreenIdle: idle
            ))
        }
        XCTAssertEqual(lanes(.mac, power: true), 1)
        XCTAssertEqual(lanes(.mac, power: true, cores: 4), 1)
        XCTAssertEqual(lanes(.mac, power: false), 1)
        XCTAssertEqual(lanes(.mac, power: true, playing: true), 1)
        XCTAssertEqual(lanes(.pad, power: true), 1)
        XCTAssertEqual(lanes(.phone, power: false), 1)
        XCTAssertEqual(lanes(.phone, power: false, idle: true), 1)
        XCTAssertEqual(lanes(.tv, power: true), 1)
        XCTAssertEqual(lanes(.watch, power: true), 0)
    }

    func testYieldOnlyWhenOnBatteryOrPlaying() {
        XCTAssertEqual(AnalysisLanePolicy.yield(.init(device: .mac, isOnPower: true, isPlaying: false)), .zero)
        XCTAssertEqual(AnalysisLanePolicy.yield(.init(device: .mac, isOnPower: false, isPlaying: false)), .seconds(2))
        XCTAssertEqual(AnalysisLanePolicy.yield(.init(device: .tv, isOnPower: true, isPlaying: true)), .seconds(2))
    }

    func testBackgroundWorkWaitsForInitialSync() async throws {
        let probe = AnalysisLaneProbe()
        let tv = AnalysisLaneConditions(device: .tv, isOnPower: true, isPlaying: false)
        let scheduler = AutomaticAnalysisScheduler(
            backgroundPriority: .userInitiated, waitsForInitialSync: true, conditions: { tv }
        )
        scheduler.enqueueBackground(key: "sync-gate-\(UUID().uuidString)", pausesDuringPlayback: false) {
            await probe.begin()
            await probe.end()
        }
        try await Task.sleep(for: .milliseconds(400))
        let early = await probe.finished
        XCTAssertEqual(early, 0)
        scheduler.noteAnalysisSyncSettled()
        let deadline = ContinuousClock.now + .seconds(10)
        while await probe.finished < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let finished = await probe.finished
        XCTAssertEqual(finished, 1)
    }
}

final class EngineHandoverPolicyTests: XCTestCase {
    func testStartRouteStreamsUnlessTheEngineCanStartAtOnce() {
        XCTAssertEqual(EngineHandoverPolicy.startRoute(isOnDeck: false, isCached: false, isAirPlay: false), .streamThenHandOver)
        XCTAssertEqual(EngineHandoverPolicy.startRoute(isOnDeck: true, isCached: false, isAirPlay: false), .engine)
        XCTAssertEqual(EngineHandoverPolicy.startRoute(isOnDeck: false, isCached: true, isAirPlay: false), .engine)
        XCTAssertEqual(EngineHandoverPolicy.startRoute(isOnDeck: false, isCached: false, isAirPlay: true), .engine)
    }

    func testHandsOverAsSoonAsReadyWithSixteenBarsToSpare() {
        let latest = EngineHandoverPolicy.latestTransition(duration: 240, barSeconds: 2)
        XCTAssertEqual(latest, 176, accuracy: 0.001)
        XCTAssertEqual(step(ready: true, position: 10, transitionAt: latest), .handOverNow)
        XCTAssertEqual(step(ready: true, position: latest - 32, transitionAt: latest), .handOverNow)
    }

    func testWaitsWhileTheEngineIsStillFetching() {
        XCTAssertEqual(step(ready: false, position: 10, transitionAt: 176), .wait)
    }

    func testWaitsWhileTheStreamIsBuffering() {
        XCTAssertEqual(
            EngineHandoverPolicy.step(
                engineReady: true, streamPlaying: false, streamPaused: false,
                position: 10, transitionAt: 176, barSeconds: 2
            ),
            .wait
        )
    }

    func testPausedStreamSwapsWithoutACrossfade() {
        XCTAssertEqual(
            EngineHandoverPolicy.step(
                engineReady: true, streamPlaying: false, streamPaused: true,
                position: 10, transitionAt: 176, barSeconds: 2
            ),
            .handOverNow
        )
    }

    func testStaysOnTheStreamWhenTheTransitionIsTooClose() {
        XCTAssertEqual(step(ready: true, position: 176 - 31.9, transitionAt: 176), .stayOnStream)
        XCTAssertEqual(step(ready: false, position: 176 - 31.9, transitionAt: 176), .stayOnStream)
    }

    func testShortTrackNeverHandsOver() {
        let latest = EngineHandoverPolicy.latestTransition(duration: 70, barSeconds: nil)
        XCTAssertEqual(step(ready: true, position: 0, transitionAt: latest), .stayOnStream)
    }

    func testUnknownTempoFallsBackToTwoSecondBars() {
        XCTAssertEqual(EngineHandoverPolicy.latestTransition(duration: 240, barSeconds: nil), 176, accuracy: 0.001)
        XCTAssertEqual(EngineHandoverPolicy.latestTransition(duration: 240, barSeconds: .nan), 176, accuracy: 0.001)
    }

    func testAlignmentCorrectsOnlyMeasurableOffsets() {
        XCTAssertNil(EngineHandoverPolicy.alignmentCorrection(offset: 0.0005))
        XCTAssertEqual(EngineHandoverPolicy.alignmentCorrection(offset: -0.012) ?? 0, -0.012, accuracy: 1e-9)
        XCTAssertNil(EngineHandoverPolicy.alignmentCorrection(offset: .nan))
        XCTAssertTrue(EngineHandoverPolicy.isAligned(offset: 0.003))
        XCTAssertFalse(EngineHandoverPolicy.isAligned(offset: 0.006))
    }

    func testAlignedCrossfadeHoldsLevelWithinHalfADecibel() {
        let rate = 48_000.0
        let fadeFrames = Int(EngineHandoverPolicy.crossfadeSeconds * rate)
        let signal: (Int) -> Double = { frame in
            let t = Double(frame) / rate
            return 0.5 * sin(2 * .pi * 110 * t) + 0.3 * sin(2 * .pi * 1_760 * t + 0.4)
        }
        var mixed: [Double] = []
        for frame in 0..<(fadeFrames * 3) {
            let progress = Double(frame - fadeFrames) / Double(fadeFrames)
            let gains = EngineHandoverPolicy.crossfadeGains(progress: progress)
            mixed.append(gains.stream * signal(frame) + gains.engine * signal(frame))
        }
        var largestJump = 0.0
        var largestDeviation = 0.0
        for frame in 0..<mixed.count {
            largestDeviation = max(largestDeviation, abs(mixed[frame] - signal(frame)))
            if frame > 0 {
                let expected = signal(frame) - signal(frame - 1)
                largestJump = max(largestJump, abs((mixed[frame] - mixed[frame - 1]) - expected))
            }
        }
        XCTAssertLessThan(largestJump, 1e-9)
        XCTAssertLessThan(largestDeviation, 1e-9)

        let window = fadeFrames / 3
        for start in stride(from: 0, to: mixed.count - window, by: window) {
            let reference = rms((start..<(start + window)).map(signal))
            let level = rms(Array(mixed[start..<(start + window)]))
            XCTAssertLessThan(abs(20 * log10(level / reference)), 0.5)
        }
    }

    func testEqualPowerWouldBumpTheLevelOnIdenticalAudio() {
        let middle = EngineHandoverPolicy.crossfadeGains(progress: 0.5)
        XCTAssertEqual(middle.stream + middle.engine, 1, accuracy: 1e-12)
        let equalPower = 2 * cos(Double.pi / 4)
        XCTAssertGreaterThan(20 * log10(equalPower), 2.9)
    }

    private func step(ready: Bool, position: TimeInterval, transitionAt: TimeInterval) -> EngineHandoverPolicy.Step {
        EngineHandoverPolicy.step(
            engineReady: ready, streamPlaying: true, streamPaused: false,
            position: position, transitionAt: transitionAt, barSeconds: 2
        )
    }

    private func rms(_ values: [Double]) -> Double {
        sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(max(1, values.count)))
    }
}

final class DeckAnalysisTests: XCTestCase {
    func testDeckLoadedAnalysesOnEveryDevice() {
        XCTAssertEqual(AnalysisTrigger.deckLoaded.priority, .interactive)
        XCTAssertFalse(AnalysisTrigger.deckLoaded.enforcesDeviceEligibility)
        XCTAssertTrue(AutomaticAnalysisScheduler.supportsAudioTier(for: .deckLoaded))
        XCTAssertTrue(AutomaticAnalysisScheduler.supportsAudioTier(for: .requested))
    }

    func testAppleTVRunsOneAnalysisAtATime() {
        let tv = AnalysisLaneConditions(device: .tv, isOnPower: true, isPlaying: true)
        XCTAssertTrue(AnalysisLanePolicy.mayStartInteractive(running: 0, interactiveRunning: false, tv))
        XCTAssertFalse(AnalysisLanePolicy.mayStartInteractive(running: 1, interactiveRunning: false, tv))
        XCTAssertFalse(AnalysisLanePolicy.mayStartInteractive(running: 1, interactiveRunning: true, tv))
        let mac = AnalysisLaneConditions(device: .mac, isOnPower: true, isPlaying: true)
        XCTAssertTrue(AnalysisLanePolicy.mayStartInteractive(running: 1, interactiveRunning: false, mac))
        XCTAssertFalse(AnalysisLanePolicy.mayStartInteractive(running: 1, interactiveRunning: true, mac))
    }

    func testEstimateNeverShowsEnergy() {
        let estimate = TrackAnalysis(trackId: "t", bpm: nil, key: nil, energy: 0.5, intro: 0, outro: 200, isEstimated: true)
        let readout = DeckReadout(.analyzed(estimate))
        XCTAssertNil(readout.energy)
        XCTAssertNil(readout.energyText)
        XCTAssertFalse(readout.hasAnalysis)
        XCTAssertFalse(readout.isEstimated)

        let tempoEstimate = TrackAnalysis(trackId: "t", bpm: 124, key: nil, energy: 0.5, intro: 0, outro: 200, isEstimated: true)
        let estimated = DeckReadout(.analyzed(tempoEstimate))
        XCTAssertEqual(estimated.bpm, 124)
        XCTAssertNil(estimated.energyText)
        XCTAssertTrue(estimated.isEstimated)
    }

    func testAnalysingReadoutSaysSo() {
        XCTAssertTrue(DeckReadout(.analyzing).isAnalyzing)
        XCTAssertTrue(DeckReadout(.pending).isAnalyzing)
        XCTAssertEqual(DeckReadout(.analyzing).spokenSummary, "analysing")
        XCTAssertFalse(DeckReadout(.failed).isAnalyzing)
    }

    func testMeasuredReadoutShowsEverything() {
        let measured = TrackAnalysis(trackId: "t", bpm: 126, key: "8A", energy: 0.72, intro: 16, outro: 300)
        let readout = DeckReadout(.analyzed(measured))
        XCTAssertEqual(readout.bpmText, "126")
        XCTAssertEqual(readout.key, "8A")
        XCTAssertEqual(readout.energyText, "72%")
        XCTAssertTrue(readout.hasAnalysis)
        XCTAssertFalse(readout.isEstimated)
    }

    func testSummaryValuesWinOnlyWhenMeasured() {
        let key = CamelotKey(wheelPosition: 8, mode: .minor)
        let measured = TrackAnalysis(trackId: "t", bpm: 125.6, key: "5A", energy: 0.6, intro: 8, outro: 280)
        let synced = AnalysisFeatureSummary(bpm: 126, key: key, bpmAuthority: .measured, keyAuthority: .measured)
        let merged = DJTransitionService.merge(trackId: "t", duration: 300, summary: synced, measured: measured)
        XCTAssertEqual(merged?.bpm, 126)
        XCTAssertEqual(merged?.key, key.label)
        XCTAssertEqual(merged?.energy, 0.6)
        XCTAssertEqual(merged?.isEstimated, false)

        let hinted = AnalysisFeatureSummary(bpm: 128, bpmAuthority: .estimated)
        XCTAssertEqual(DJTransitionService.merge(trackId: "t", duration: 300, summary: hinted, measured: measured)?.bpm, 125.6)
        XCTAssertNil(DJTransitionService.merge(trackId: "t", duration: 300, summary: hinted, measured: nil))
    }

    func testSyncedAnalysisNeedsNoAudio() {
        let synced = AnalysisFeatureSummary(bpm: 122, bpmAuthority: .corrected)
        let merged = DJTransitionService.merge(trackId: "t", duration: 300, summary: synced, measured: nil)
        XCTAssertEqual(merged?.bpm, 122)
        XCTAssertNil(merged?.energy)
        XCTAssertEqual(merged?.outro, 284)
    }
}
