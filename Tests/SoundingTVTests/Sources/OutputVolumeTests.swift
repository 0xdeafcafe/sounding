import XCTest
@testable import SoundingTV

final class OutputVolumeTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    // MARK: - Route

    func testRouteFollowsSonosThenRemoteOutput() {
        XCTAssertEqual(OutputVolumeRoute.resolve(sonosActive: false, remoteOutput: false), .system)
        XCTAssertEqual(OutputVolumeRoute.resolve(sonosActive: false, remoteOutput: true), .linked)
        XCTAssertEqual(OutputVolumeRoute.resolve(sonosActive: true, remoteOutput: false), .sonos)
        XCTAssertFalse(OutputVolumeRoute.system.isRemote)
        XCTAssertTrue(OutputVolumeRoute.linked.isRemote)
        XCTAssertTrue(OutputVolumeRoute.sonos.isRemote)
    }

    // MARK: - Reconciliation

    func testEchoIsShownWhenNothingLocalHappened() {
        let reconciler = VolumeReconciler()
        XCTAssertEqual(reconciler.displayed(echo: 0.4, at: at(0)), 0.4)
        XCTAssertNil(reconciler.displayed(echo: nil, at: at(0)))
    }

    func testEchoesDuringADragAreIgnored() {
        var reconciler = VolumeReconciler()
        reconciler.begin(at: at(0))
        reconciler.set(0.7, at: at(0.1))
        XCTAssertEqual(reconciler.displayed(echo: 0.3, at: at(5)), 0.7)
        reconciler.set(0.75, at: at(6))
        XCTAssertEqual(reconciler.displayed(echo: 0.3, at: at(6.1)), 0.75)
    }

    func testEchoesJustAfterADragAreIgnoredThenAdopted() {
        var reconciler = VolumeReconciler()
        reconciler.begin(at: at(0))
        reconciler.set(0.6, at: at(0.2))
        reconciler.end(at: at(0.5))
        XCTAssertEqual(reconciler.displayed(echo: 0.2, at: at(1.0)), 0.6)
        XCTAssertEqual(reconciler.displayed(echo: 0.6, at: at(1.9)), 0.6)
        XCTAssertEqual(reconciler.displayed(echo: 0.65, at: at(2.1)), 0.65)
    }

    func testReleaseDelayCountsDownFromTheLastLocalChange() {
        var reconciler = VolumeReconciler()
        XCTAssertNil(reconciler.releaseDelay(at: at(0)))
        reconciler.set(0.5, at: at(0))
        XCTAssertEqual(try XCTUnwrap(reconciler.releaseDelay(at: at(0.5))), VolumeReconciler.defaultHold - 0.5, accuracy: 0.0001)
        XCTAssertNil(reconciler.releaseDelay(at: at(VolumeReconciler.defaultHold + 0.1)))
        reconciler.begin(at: at(3))
        XCTAssertNil(reconciler.releaseDelay(at: at(3.1)))
    }

    func testLocalValuesAreClamped() {
        var reconciler = VolumeReconciler()
        XCTAssertEqual(reconciler.set(1.4, at: at(0)), 1)
        XCTAssertEqual(reconciler.set(-0.2, at: at(0)), 0)
        XCTAssertEqual(reconciler.set(.nan, at: at(0)), 0)
        XCTAssertEqual(VolumeReconciler().displayed(echo: 3, at: at(0)), 1)
    }

    func testResetDropsTheOptimisticValue() {
        var reconciler = VolumeReconciler()
        reconciler.set(0.9, at: at(0))
        reconciler.reset()
        XCTAssertEqual(reconciler.displayed(echo: 0.1, at: at(0.1)), 0.1)
    }

    // MARK: - Throttle

    func testFirstValueSendsAtOnce() {
        var throttle = VolumeSendThrottle(interval: 0.1)
        XCTAssertEqual(throttle.submit(0.5, at: at(0)), .send(0.5))
    }

    func testValuesInsideTheIntervalWaitAndOnlyTheLatestIsSent() {
        var throttle = VolumeSendThrottle(interval: 0.1)
        XCTAssertEqual(throttle.submit(0.5, at: at(0)), .send(0.5))
        guard case .wait(let delay) = throttle.submit(0.55, at: at(0.03)) else {
            return XCTFail("expected wait")
        }
        XCTAssertEqual(delay, 0.07, accuracy: 0.0001)
        XCTAssertEqual(throttle.submit(0.6, at: at(0.05)), .skip)
        XCTAssertEqual(throttle.submit(0.62, at: at(0.08)), .skip)
        XCTAssertEqual(throttle.flush(at: at(0.1)), 0.62)
        XCTAssertNil(throttle.flush(at: at(0.11)))
    }

    func testValuesAfterTheIntervalSendAtOnce() {
        var throttle = VolumeSendThrottle(interval: 0.1)
        _ = throttle.submit(0.5, at: at(0))
        XCTAssertEqual(throttle.submit(0.4, at: at(0.25)), .send(0.4))
    }

    func testRepeatingTheSentValueIsSkipped() {
        var throttle = VolumeSendThrottle(interval: 0.1)
        _ = throttle.submit(0.5, at: at(0))
        XCTAssertEqual(throttle.submit(0.5, at: at(1)), .skip)
    }

    func testFlushSkipsAPendingValueEqualToTheLastSent() {
        var throttle = VolumeSendThrottle(interval: 0.1)
        _ = throttle.submit(0.5, at: at(0))
        _ = throttle.submit(0.6, at: at(0.02))
        _ = throttle.submit(0.5, at: at(0.04))
        XCTAssertNil(throttle.flush(at: at(0.1)))
    }

    func testAContinuousDragSendsAboutOncePerInterval() {
        var throttle = VolumeSendThrottle(interval: 0.1)
        var sends = 0
        var time: TimeInterval = 0
        var waitingUntil: TimeInterval?
        for index in 0..<100 {
            time = Double(index) * 0.01
            if let due = waitingUntil, time >= due {
                if throttle.flush(at: at(time)) != nil { sends += 1 }
                waitingUntil = nil
            }
            switch throttle.submit(Double(index) / 100, at: at(time)) {
            case .send: sends += 1
            case .wait(let delay): waitingUntil = time + delay
            case .skip: break
            }
        }
        XCTAssertGreaterThanOrEqual(sends, 9)
        XCTAssertLessThanOrEqual(sends, 11)
    }

    // MARK: - Hardware buttons

    func testOnePressIsOneStepEitherWay() {
        let step = HardwareVolumeStep.system
        XCTAssertEqual(HardwareVolumeStep.steps(from: 0.5, to: 0.5 + step), 1)
        XCTAssertEqual(HardwareVolumeStep.steps(from: 0.5, to: 0.5 - step), -1)
        XCTAssertEqual(HardwareVolumeStep.steps(from: 0.5, to: 0.5 + 2 * step), 2)
        XCTAssertEqual(HardwareVolumeStep.steps(from: 0.5, to: 0.5), 0)
        XCTAssertEqual(HardwareVolumeStep.steps(from: 0.5, to: 0.52), 1)
        XCTAssertEqual(HardwareVolumeStep.steps(from: 0.5, to: 0.48), -1)
    }

    func testAnchorKeepsRoomForBothButtons() {
        let step = HardwareVolumeStep.system
        XCTAssertEqual(HardwareVolumeStep.anchor(for: 0), step)
        XCTAssertEqual(HardwareVolumeStep.anchor(for: 1), 1 - step)
        XCTAssertEqual(HardwareVolumeStep.anchor(for: 0.5), 0.5)
    }

    func testStepsMoveTheRemoteLevelAndClamp() {
        XCTAssertEqual(HardwareVolumeStep.applying(1, to: 0.5), 0.5625, accuracy: 0.0001)
        XCTAssertEqual(HardwareVolumeStep.applying(-2, to: 0.5), 0.375, accuracy: 0.0001)
        XCTAssertEqual(HardwareVolumeStep.applying(3, to: 0.95), 1)
        XCTAssertEqual(HardwareVolumeStep.applying(-3, to: 0.05), 0)
    }

    func testTrackerStepsThenIgnoresItsOwnReset() {
        var tracker = HardwareVolumeTracker(original: 0.5)
        XCTAssertFalse(tracker.needsInitialReset)
        XCTAssertNil(tracker.restoreOnFinish)

        let up = tracker.observe(0.5625)
        XCTAssertEqual(up.steps, 1)
        XCTAssertEqual(up.resetTo, 0.5)

        let reset = tracker.observe(0.5)
        XCTAssertEqual(reset.steps, 0)
        XCTAssertNil(reset.resetTo)

        let down = tracker.observe(0.4375)
        XCTAssertEqual(down.steps, -1)
        XCTAssertEqual(down.resetTo, 0.5)
    }

    func testTrackerAtTheTopMovesOffTheLimitAndRestoresLater() {
        var tracker = HardwareVolumeTracker(original: 1)
        XCTAssertTrue(tracker.needsInitialReset)
        XCTAssertEqual(tracker.anchor, 1 - HardwareVolumeStep.system)
        XCTAssertEqual(tracker.restoreOnFinish, 1)

        let settle = tracker.observe(tracker.anchor)
        XCTAssertEqual(settle.steps, 0)
        XCTAssertNil(settle.resetTo)

        let up = tracker.observe(1)
        XCTAssertEqual(up.steps, 1)
        XCTAssertEqual(up.resetTo, tracker.anchor)
    }

    func testTrackerAtSilenceStillHearsVolumeDown() {
        var tracker = HardwareVolumeTracker(original: 0)
        _ = tracker.observe(tracker.anchor)
        let down = tracker.observe(0)
        XCTAssertEqual(down.steps, -1)
        XCTAssertEqual(down.resetTo, HardwareVolumeStep.system)
        XCTAssertEqual(tracker.restoreOnFinish, 0)
    }

    func testRapidPressesBeforeTheResetLandStillCount() {
        var tracker = HardwareVolumeTracker(original: 0.5)
        XCTAssertEqual(tracker.observe(0.5625).steps, 1)
        XCTAssertEqual(tracker.observe(0.625).steps, 1)
        XCTAssertEqual(tracker.observe(0.5).steps, 0)
    }
}
