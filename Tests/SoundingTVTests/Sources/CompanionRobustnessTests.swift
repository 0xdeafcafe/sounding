import XCTest
@testable import SoundingTV

@MainActor
final class PlaybackConfirmationTrackerTests: XCTestCase {
    @MainActor
    private final class FakeChannel {
        var sent: [String] = []
        var isConnected = true

        func send(_ trackId: String) -> Bool {
            guard isConnected else { return false }
            sent.append(trackId)
            return true
        }
    }

    func testConfirmsOnceTheRemoteReportsTheLoadedTrack() async {
        let tracker = PlaybackConfirmationTracker()
        let channel = FakeChannel()
        let outcome = Task { @MainActor in
            await tracker.confirm(trackId: "b", timeout: .seconds(5)) { channel.send("b") }
        }
        await waitUntil { tracker.pendingCount == 1 }
        XCTAssertEqual(channel.sent, ["b"])
        tracker.observePlayback(trackId: "a")
        tracker.observePlayback(trackId: nil)
        XCTAssertEqual(tracker.pendingCount, 1)
        tracker.observePlayback(trackId: "b")
        let result = await outcome.value
        XCTAssertEqual(result, .confirmed)
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testTimesOutWhenTheRemoteNeverConfirms() async {
        let tracker = PlaybackConfirmationTracker()
        let channel = FakeChannel()
        let started = ContinuousClock.now
        let outcome = await tracker.confirm(trackId: "b", timeout: .milliseconds(150)) { channel.send("b") }
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(150))
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testRejectionEndsTheWaitWithTheReason() async {
        let tracker = PlaybackConfirmationTracker()
        let channel = FakeChannel()
        let outcome = Task { @MainActor in
            await tracker.confirm(trackId: "b", timeout: .seconds(5)) { channel.send("b") }
        }
        await waitUntil { tracker.pendingCount == 1 }
        tracker.observeRejection("Could not load the queue")
        let result = await outcome.value
        XCTAssertEqual(result, .rejected("Could not load the queue"))
    }

    func testUnsentCommandReportsDisconnectedImmediately() async {
        let tracker = PlaybackConfirmationTracker()
        let channel = FakeChannel()
        channel.isConnected = false
        let outcome = await tracker.confirm(trackId: "b", timeout: .seconds(5)) { channel.send("b") }
        XCTAssertEqual(outcome, .disconnected)
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testDroppedConnectionEndsTheWait() async {
        let tracker = PlaybackConfirmationTracker()
        let channel = FakeChannel()
        let outcome = Task { @MainActor in
            await tracker.confirm(trackId: "b", timeout: .seconds(5)) { channel.send("b") }
        }
        await waitUntil { tracker.pendingCount == 1 }
        tracker.observeDisconnect()
        let result = await outcome.value
        XCTAssertEqual(result, .disconnected)
    }

    func testLateConfirmationAfterTimeoutIsIgnored() async {
        let tracker = PlaybackConfirmationTracker()
        let channel = FakeChannel()
        let outcome = await tracker.confirm(trackId: "b", timeout: .milliseconds(50)) { channel.send("b") }
        XCTAssertEqual(outcome, .timedOut)
        tracker.observePlayback(trackId: "b")
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testCancellingTheWaitDoesNotHang() async {
        let tracker = PlaybackConfirmationTracker()
        let channel = FakeChannel()
        let task = Task { @MainActor in
            await tracker.confirm(trackId: "b", timeout: .seconds(30)) { channel.send("b") }
        }
        await waitUntil { tracker.pendingCount == 1 }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .timedOut)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        var attempts = 0
        while !condition(), attempts < 400 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }
}

final class PendingRemoteSeekTests: XCTestCase {
    private let issued = Date(timeIntervalSinceReferenceDate: 1_000)

    private func seek(rate: Double = 1) -> PendingRemoteSeek {
        PendingRemoteSeek(target: 120, rate: rate, issuedAt: issued, baselineRevision: 7)
    }

    func testHoldsTheOptimisticPositionUntilANewerStateArrives() {
        let pending = seek()
        XCTAssertEqual(pending.resolution(revision: 7, position: 30, at: issued.addingTimeInterval(0.5)), .hold)
        XCTAssertEqual(pending.resolution(revision: nil, position: nil, at: issued.addingTimeInterval(2)), .hold)
    }

    func testSettlesWhenTheRemoteHonoursTheSeek() {
        let pending = seek()
        XCTAssertEqual(pending.resolution(revision: 8, position: 120.4, at: issued.addingTimeInterval(0.3)), .settle)
    }

    func testIgnoresAStaleInFlightStateRightAfterTheSeek() {
        let pending = seek()
        XCTAssertEqual(pending.resolution(revision: 8, position: 31, at: issued.addingTimeInterval(0.2)), .hold)
    }

    func testReanchorsToTheNextStateWhenTheRemoteIgnoredTheSeek() {
        let pending = seek()
        XCTAssertEqual(pending.resolution(revision: 9, position: 32, at: issued.addingTimeInterval(1.2)), .settle)
    }

    func testReanchorsAfterTheDeadlineEvenWithoutANewState() {
        let pending = seek()
        XCTAssertEqual(pending.resolution(revision: 7, position: 33, at: issued.addingTimeInterval(PendingRemoteSeek.deadline)), .settle)
        XCTAssertEqual(pending.resolution(revision: nil, position: nil, at: issued.addingTimeInterval(PendingRemoteSeek.deadline + 1)), .settle)
    }

    func testPausedSeekExpectsTheTargetToStayPut() {
        let pending = seek(rate: 0)
        XCTAssertEqual(pending.resolution(revision: 8, position: 120, at: issued.addingTimeInterval(0.9)), .settle)
        XCTAssertEqual(pending.resolution(revision: 8, position: 123, at: issued.addingTimeInterval(0.9)), .hold)
    }
}

@MainActor
final class CompanionServerSchedulingTests: XCTestCase {
    func testEvictionPrefersDeadClientsThenTheLeastRecentlyActive() {
        let now = ContinuousClock.now
        let quiet = CompanionClientEviction.Candidate(id: 5, isDead: false, lastActivityAt: now - .seconds(60))
        let busy = CompanionClientEviction.Candidate(id: 1, isDead: false, lastActivityAt: now)
        let dead = CompanionClientEviction.Candidate(id: 9, isDead: true, lastActivityAt: now)

        XCTAssertEqual(CompanionClientEviction.victim(among: [busy, quiet]), 5)
        XCTAssertEqual(CompanionClientEviction.victim(among: [busy, quiet, dead]), 9)
        XCTAssertNil(CompanionClientEviction.victim(among: []))

        let tie = CompanionClientEviction.Candidate(id: 3, isDead: false, lastActivityAt: now)
        XCTAssertEqual(CompanionClientEviction.victim(among: [busy, tie].reversed()), 1)
    }

    func testFailedAndCancelledConnectionsCountAsDead() {
        XCTAssertTrue(CompanionClientEviction.isDead(.cancelled))
        XCTAssertTrue(CompanionClientEviction.isDead(.failed(.posix(.ECONNRESET))))
        XCTAssertFalse(CompanionClientEviction.isDead(.ready))
        XCTAssertFalse(CompanionClientEviction.isDead(.preparing))
    }

    func testSlowPreparationDoesNotBlockAnotherClient() async {
        let pipeline = CompanionCommandPipeline()
        let applied = Recorder()
        let gate = Gate()

        pipeline.prepare(lane: 1) {
            await gate.wait()
            return { applied.append("slow") }
        }
        pipeline.submit(lane: 2) { applied.append("fast") }

        await waitUntil { applied.items == ["fast"] }
        gate.open()
        await waitUntil { applied.items == ["fast", "slow"] }
    }

    func testCommandsFromOneClientKeepTheirOrder() async {
        let pipeline = CompanionCommandPipeline()
        let applied = Recorder()
        let gate = Gate()

        pipeline.prepare(lane: 1) {
            await gate.wait()
            return { applied.append("load") }
        }
        pipeline.submit(lane: 1) { applied.append("pause") }

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(applied.items, [])
        gate.open()
        await waitUntil { applied.items == ["load", "pause"] }
    }

    func testAppliedOperationsNeverInterleave() async {
        let pipeline = CompanionCommandPipeline()
        let log = Recorder()

        pipeline.submit(lane: 1) {
            log.append("a-start")
            try? await Task.sleep(for: .milliseconds(40))
            log.append("a-end")
        }
        pipeline.submit(lane: 2) {
            log.append("b-start")
            log.append("b-end")
        }

        await waitUntil { log.items.count == 4 }
        let items = log.items
        XCTAssertTrue(
            items == ["a-start", "a-end", "b-start", "b-end"] || items == ["b-start", "b-end", "a-start", "a-end"],
            "\(items)"
        )
    }

    func testFailedPreparationSkipsOnlyThatCommand() async {
        let pipeline = CompanionCommandPipeline()
        let applied = Recorder()

        pipeline.prepare(lane: 1) { nil }
        pipeline.submit(lane: 1) { applied.append("next") }

        await waitUntil { applied.items == ["next"] }
    }

    func testCancelAllDropsQueuedWork() async {
        let pipeline = CompanionCommandPipeline()
        let applied = Recorder()
        let gate = Gate()

        pipeline.prepare(lane: 1) {
            await gate.wait()
            return { applied.append("late") }
        }
        pipeline.cancelAll()
        gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(applied.items, [])
        XCTAssertEqual(pipeline.laneCount, 0)
    }

    @MainActor
    private final class Recorder {
        private(set) var items: [String] = []
        func append(_ item: String) { items.append(item) }
    }

    @MainActor
    private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        var attempts = 0
        while !condition(), attempts < 400 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }
}

final class DeviceStatusPayloadTests: XCTestCase {
    private let sessionId = "device-status-session"
    private let secret = Data(repeating: 7, count: 32)

    func testSignedStatusVerifiesForItsSession() {
        let status = DeviceStatusPayload.create(needsSignIn: true, sessionId: sessionId, secret: secret)
        XCTAssertTrue(status.needsSignIn)
        XCTAssertTrue(status.verify(sessionId: sessionId, secret: secret))
        XCTAssertTrue(status.isFresh())
    }

    func testWrongSecretOrSessionIsRejected() {
        let status = DeviceStatusPayload.create(needsSignIn: true, sessionId: sessionId, secret: secret)
        XCTAssertFalse(status.verify(sessionId: sessionId, secret: Data(repeating: 8, count: 32)))
        XCTAssertFalse(status.verify(sessionId: "another-session", secret: secret))
    }

    func testTamperedFieldsAreRejected() {
        let status = DeviceStatusPayload.create(needsSignIn: true, sessionId: sessionId, secret: secret)
        let flipped = DeviceStatusPayload(needsSignIn: false, issuedAtMillis: status.issuedAtMillis, signature: status.signature)
        let redated = DeviceStatusPayload(needsSignIn: true, issuedAtMillis: status.issuedAtMillis + 1, signature: status.signature)
        XCTAssertFalse(flipped.verify(sessionId: sessionId, secret: secret))
        XCTAssertFalse(redated.verify(sessionId: sessionId, secret: secret))
    }

    func testSurvivesTheWireIntact() throws {
        let status = DeviceStatusPayload.create(needsSignIn: false, sessionId: sessionId, secret: secret)
        let message = TokenTransferMessage.deviceStatus(sessionId: sessionId, status: status)
        let decoded = try JSONDecoder().decode(TokenTransferMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.type, .deviceStatus)
        XCTAssertEqual(decoded.deviceStatus, status)
        XCTAssertEqual(decoded.deviceStatus?.verify(sessionId: sessionId, secret: secret), true)
    }

    func testStaleOrFutureStatusIsNotFresh() {
        let status = DeviceStatusPayload.create(needsSignIn: true, sessionId: sessionId, secret: secret)
        let window = BonjourConstants.commandFreshnessWindow
        XCTAssertTrue(status.isFresh(now: Date().addingTimeInterval(window - 5)))
        XCTAssertFalse(status.isFresh(now: Date().addingTimeInterval(window + 5)))
        XCTAssertFalse(status.isFresh(now: Date().addingTimeInterval(-window - 5)))
    }
}

final class PendingLocalSeekTests: XCTestCase {
    private let issued = Date(timeIntervalSinceReferenceDate: 1_000)
    private var seek: PendingLocalSeek { PendingLocalSeek(target: 120, issuedAt: issued, trackID: "a") }

    func testRejectsThePreSeekPlayheadWhileTheSeekIsInFlight() {
        XCTAssertFalse(seek.accepts(31, at: issued.addingTimeInterval(0.2)))
        XCTAssertFalse(seek.accepts(300, at: issued.addingTimeInterval(0.2)))
    }

    func testAcceptsAToleranceLandingAndPlaybackFromTheTarget() {
        XCTAssertTrue(seek.accepts(119.3, at: issued.addingTimeInterval(0.1)))
        XCTAssertTrue(seek.accepts(121.2, at: issued.addingTimeInterval(1)))
    }

    func testExpiresAtTheDeadlineOrOnATrackChange() {
        XCTAssertFalse(seek.isExpired(at: issued.addingTimeInterval(1), trackID: "a"))
        XCTAssertTrue(seek.isExpired(at: issued.addingTimeInterval(PendingLocalSeek.deadline), trackID: "a"))
        XCTAssertTrue(seek.isExpired(at: issued.addingTimeInterval(0.5), trackID: "b"))
    }
}

final class CompanionHeartbeatTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testHeartbeatIsDueFirstThenEveryInterval() {
        XCTAssertTrue(CompanionHeartbeat.isDue(lastSentAt: nil, now: start))
        XCTAssertFalse(CompanionHeartbeat.isDue(lastSentAt: start, now: start.addingTimeInterval(CompanionHeartbeat.interval - 0.1)))
        XCTAssertTrue(CompanionHeartbeat.isDue(lastSentAt: start, now: start.addingTimeInterval(CompanionHeartbeat.interval)))
    }

    func testControllerGoesStaleAfterThreeMissedPings() {
        XCTAssertFalse(CompanionHeartbeat.controllerIsStale(lastFrameAt: start, now: start.addingTimeInterval(CompanionHeartbeat.controllerStaleAfter)))
        XCTAssertTrue(CompanionHeartbeat.controllerIsStale(lastFrameAt: start, now: start.addingTimeInterval(CompanionHeartbeat.controllerStaleAfter + 0.1)))
        XCTAssertGreaterThanOrEqual(CompanionHeartbeat.controllerStaleAfter, CompanionHeartbeat.interval * 3)
    }

    func testSilentHeartbeatingPeerIsDropped() {
        let late = CompanionHeartbeat.peerStaleAfter + 1
        XCTAssertTrue(CompanionHeartbeat.peerIsUnresponsive(isReady: true, sendsHeartbeats: true, connectedFor: 600, silentFor: late))
        XCTAssertFalse(CompanionHeartbeat.peerIsUnresponsive(isReady: true, sendsHeartbeats: true, connectedFor: 600, silentFor: CompanionHeartbeat.interval))
    }

    func testOlderControllersWithoutHeartbeatsAreNeverDroppedForSilence() {
        XCTAssertFalse(CompanionHeartbeat.peerIsUnresponsive(isReady: true, sendsHeartbeats: false, connectedFor: 3600, silentFor: 3600))
    }

    func testAHandshakeThatNeverFinishesIsDropped() {
        XCTAssertFalse(CompanionHeartbeat.peerIsUnresponsive(isReady: false, sendsHeartbeats: false, connectedFor: 5, silentFor: 5))
        XCTAssertTrue(CompanionHeartbeat.peerIsUnresponsive(isReady: false, sendsHeartbeats: false, connectedFor: CompanionHeartbeat.handshakeTimeout + 1, silentFor: 0))
    }

    func testPeerGraceOutlastsTheHeartbeatInterval() {
        XCTAssertGreaterThan(CompanionHeartbeat.peerStaleAfter, CompanionHeartbeat.interval * 4)
    }
}

final class CompanionCommandOutboxTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testDrainsInOrderAndEmpties() {
        var outbox = CompanionCommandOutbox<String>()
        outbox.enqueue("next", at: start)
        outbox.enqueue("previous", at: start.addingTimeInterval(1))
        XCTAssertEqual(outbox.drain(at: start.addingTimeInterval(2)), ["next", "previous"])
        XCTAssertTrue(outbox.isEmpty)
        XCTAssertEqual(outbox.drain(at: start.addingTimeInterval(3)), [])
    }

    func testKeyedCommandsKeepOnlyTheLatestIntent() {
        var outbox = CompanionCommandOutbox<String>()
        outbox.enqueue("play", key: "transport.playing", at: start)
        outbox.enqueue("next", at: start)
        outbox.enqueue("pause", key: "transport.playing", at: start.addingTimeInterval(0.5))
        XCTAssertEqual(outbox.drain(at: start.addingTimeInterval(1)), ["next", "pause"])
    }

    func testUnkeyedCommandsAreNotCoalesced() {
        var outbox = CompanionCommandOutbox<String>()
        outbox.enqueue("next", at: start)
        outbox.enqueue("next", at: start)
        XCTAssertEqual(outbox.count, 2)
    }

    func testCommandsExpireSoAStaleTapNeverFiresLater() {
        var outbox = CompanionCommandOutbox<String>()
        outbox.enqueue("pause", key: "transport.playing", at: start)
        outbox.enqueue("next", at: start.addingTimeInterval(8))
        XCTAssertEqual(outbox.nextExpiry, start.addingTimeInterval(CompanionCommandOutbox<String>.lifetime))
        let late = start.addingTimeInterval(CompanionCommandOutbox<String>.lifetime + 1)
        XCTAssertEqual(outbox.drain(at: late), ["next"])
    }

    func testExpireReportsHowManyWereDropped() {
        var outbox = CompanionCommandOutbox<String>()
        outbox.enqueue("a", at: start)
        outbox.enqueue("b", at: start)
        XCTAssertEqual(outbox.expire(at: start.addingTimeInterval(CompanionCommandOutbox<String>.lifetime + 0.1)), 2)
        XCTAssertNil(outbox.nextExpiry)
    }

    func testCapacityKeepsTheNewest() {
        var outbox = CompanionCommandOutbox<Int>()
        let total = CompanionCommandOutbox<Int>.capacity + 5
        for index in 0..<total { outbox.enqueue(index, at: start) }
        let drained = outbox.drain(at: start)
        XCTAssertEqual(drained.count, CompanionCommandOutbox<Int>.capacity)
        XCTAssertEqual(drained.first, 5)
        XCTAssertEqual(drained.last, total - 1)
    }
}

final class CompanionConnectionPhaseTests: XCTestCase {
    func testLiveOnlyOnceStateHasArrived() {
        XCTAssertEqual(CompanionConnectionPhase.resolve(isReachable: true, isLive: true, hasFailed: false), .live)
        XCTAssertEqual(CompanionConnectionPhase.resolve(isReachable: true, isLive: false, hasFailed: false), .connecting)
    }

    func testAStaleSnapshotIsNeverShownAsConnected() {
        XCTAssertEqual(CompanionConnectionPhase.resolve(isReachable: false, isLive: true, hasFailed: false), .connecting)
        XCTAssertEqual(CompanionConnectionPhase.resolve(isReachable: false, isLive: false, hasFailed: true), .unreachable)
    }
}
