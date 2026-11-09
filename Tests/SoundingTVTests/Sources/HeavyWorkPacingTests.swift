import XCTest
@testable import SoundingTV

private struct FakeClock {
    var now: Date

    mutating func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

private final class FakeNetwork {
    enum Response: Equatable {
        case ok
        case rateLimited(retryAfter: TimeInterval?)
    }

    private var scripted: [String: [Response]]
    private(set) var requests: [String] = []

    init(_ scripted: [String: [Response]] = [:]) {
        self.scripted = scripted
    }

    func respond(_ key: String) -> Response {
        requests.append(key)
        guard var queue = scripted[key], !queue.isEmpty else { return .ok }
        let next = queue.removeFirst()
        scripted[key] = queue
        return next
    }
}

private struct PacedDriver {
    struct Item: Codable, Equatable {
        var key: String
        var urgency: HeavyWorkUrgency
    }

    struct Snapshot: Codable, Equatable {
        var pacer: HeavyWorkPacer
        var queue: [Item]
    }

    var pacer = HeavyWorkPacer()
    var queue: [Item]
    var policy: HeavyWorkPolicy
    var jitter: Double = 0.5
    var workDuration: TimeInterval = 5
    var starts: [(key: String, at: Date)] = []
    var stoppedByRateLimit = false

    init(queue: [Item], policy: HeavyWorkPolicy) {
        self.queue = queue
        self.policy = policy
    }

    init(snapshot: Snapshot, policy: HeavyWorkPolicy) {
        self.pacer = snapshot.pacer
        self.queue = snapshot.queue
        self.policy = policy
    }

    var snapshot: Snapshot { Snapshot(pacer: pacer, queue: queue) }

    mutating func run(
        clock: inout FakeClock,
        network: FakeNetwork,
        conditions: (Date) -> HeavyWorkConditions = { _ in HeavyWorkConditions() },
        limit: TimeInterval = 24 * 60 * 60
    ) {
        let deadline = clock.now.addingTimeInterval(limit)
        while !queue.isEmpty, clock.now < deadline {
            let urgencies = Dictionary(queue.map { ($0.key, $0.urgency) }, uniquingKeysWith: { first, _ in first })
            guard let key = HeavyWorkOrder.next(queue.map(\.key), urgency: { urgencies[$0] ?? .background }) else { return }
            let urgency = urgencies[key] ?? .background
            switch pacer.gate(urgency, now: clock.now, conditions: conditions(clock.now), policy: policy) {
            case .go:
                break
            case .wait(let until):
                clock.now = until
                continue
            case .paused(_, let until):
                clock.now = until ?? clock.now.addingTimeInterval(30)
                continue
            }
            starts.append((key, clock.now))
            clock.advance(workDuration)
            switch network.respond(key) {
            case .ok:
                queue.removeAll { $0.key == key }
                pacer.finished(now: clock.now, policy: policy, random: jitter)
            case .rateLimited(let retryAfter):
                pacer.rateLimited(now: clock.now, retryAfter: retryAfter, policy: policy, random: jitter)
                stoppedByRateLimit = true
                return
            }
        }
    }
}

final class HeavyWorkPacingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func background(_ keys: String...) -> [PacedDriver.Item] {
        keys.map { PacedDriver.Item(key: $0, urgency: .background) }
    }

    func testUserWorkJumpsTheQueueAndBackgroundStaysInOrder() {
        var clock = FakeClock(now: start)
        var driver = PacedDriver(
            queue: background("b1", "b2") + [.init(key: "u1", urgency: .user)] + background("b3"),
            policy: .downloads
        )
        driver.run(clock: &clock, network: FakeNetwork())
        XCTAssertEqual(driver.starts.map(\.key), ["u1", "b1", "b2", "b3"])
    }

    func testOrderPicksTheFirstOfTheMostUrgent() {
        let urgency: [String: HeavyWorkUrgency] = ["a": .background, "b": .user, "c": .user]
        XCTAssertEqual(HeavyWorkOrder.next(["a", "b", "c"], urgency: { urgency[$0]! }), "b")
        XCTAssertEqual(HeavyWorkOrder.next(["a"], urgency: { urgency[$0]! }), "a")
        XCTAssertNil(HeavyWorkOrder.next([String](), urgency: { _ in .user }))
    }

    func testBackgroundItemsRunOneAtATimeWithAStaggeredGap() {
        var clock = FakeClock(now: start)
        var driver = PacedDriver(queue: background("a", "b", "c", "d"), policy: .downloads)
        driver.jitter = 0.5
        driver.run(clock: &clock, network: FakeNetwork())

        XCTAssertEqual(driver.starts.count, 4)
        let expectedGap = driver.workDuration + HeavyWorkPolicy.downloads.gap(random: 0.5)
        for (previous, next) in zip(driver.starts, driver.starts.dropFirst()) {
            XCTAssertEqual(next.at.timeIntervalSince(previous.at), expectedGap, accuracy: 0.001)
        }
    }

    func testJitterStaysWithinTheStaggerWindow() {
        let policy = HeavyWorkPolicy.downloads
        XCTAssertEqual(policy.gap(random: 0), policy.stagger)
        XCTAssertEqual(policy.gap(random: 1), policy.stagger + policy.jitter)
        XCTAssertEqual(policy.gap(random: 7), policy.stagger + policy.jitter)
        XCTAssertGreaterThanOrEqual(policy.stagger, 3)
    }

    func testUserWorkSkipsTheStagger() {
        var pacer = HeavyWorkPacer()
        pacer.finished(now: start, policy: .downloads, random: 1)
        XCTAssertEqual(pacer.gate(.user, now: start, conditions: HeavyWorkConditions(), policy: .downloads), .go)
        guard case .wait(let until) = pacer.gate(.background, now: start, conditions: HeavyWorkConditions(), policy: .downloads) else {
            return XCTFail("background work should wait for the stagger")
        }
        XCTAssertEqual(until.timeIntervalSince(start), HeavyWorkPolicy.downloads.gap(random: 1), accuracy: 0.001)
    }

    func testPausesForLowPowerHeatCellularAndStreaming() {
        let pacer = HeavyWorkPacer()
        func gate(_ conditions: HeavyWorkConditions, _ urgency: HeavyWorkUrgency = .background) -> HeavyWorkGate {
            pacer.gate(urgency, now: start, conditions: conditions, policy: .downloads)
        }
        XCTAssertEqual(gate(HeavyWorkConditions(isLowPowerMode: true)), .paused(.lowPower, until: nil))
        XCTAssertEqual(gate(HeavyWorkConditions(isThermallyLimited: true)), .paused(.thermal, until: nil))
        XCTAssertEqual(gate(HeavyWorkConditions(isOnCellular: true)), .paused(.cellular, until: nil))
        XCTAssertEqual(gate(HeavyWorkConditions(playbackNeedsNetwork: true)), .paused(.playback, until: nil))
        XCTAssertEqual(gate(HeavyWorkConditions(isOnBattery: true)), .go)
        XCTAssertEqual(gate(HeavyWorkConditions(isLowPowerMode: true, isOnCellular: true), .user), .go)
    }

    func testLocalWorkIgnoresTheNetworkButCanWaitForPower() {
        var policy = HeavyWorkPolicy.analysis
        let streaming = HeavyWorkConditions(isOnBattery: true, isOnCellular: true, playbackNeedsNetwork: true)
        XCTAssertNil(streaming.pause(for: policy))
        policy.pausesOnBattery = true
        XCTAssertEqual(streaming.pause(for: policy), .battery)
    }

    func testPausedWorkResumesWhenConditionsClear() {
        var clock = FakeClock(now: start)
        var driver = PacedDriver(queue: background("a", "b"), policy: .downloads)
        let clearsAt = start.addingTimeInterval(95)
        driver.run(clock: &clock, network: FakeNetwork()) { now in
            HeavyWorkConditions(playbackNeedsNetwork: now < clearsAt)
        }
        XCTAssertEqual(driver.starts.map(\.key), ["a", "b"])
        XCTAssertGreaterThanOrEqual(driver.starts[0].at, clearsAt)
    }

    func testFirstRateLimitStopsAndHonoursRetryAfter() {
        var clock = FakeClock(now: start)
        let network = FakeNetwork(["b": [.rateLimited(retryAfter: 90)]])
        var driver = PacedDriver(queue: background("a", "b", "c"), policy: .downloads)
        driver.run(clock: &clock, network: network)

        XCTAssertTrue(driver.stoppedByRateLimit)
        XCTAssertEqual(network.requests, ["a", "b"])
        guard case .paused(.rateLimited, let until?) = driver.pacer.gate(.user, now: clock.now, conditions: HeavyWorkConditions(), policy: .downloads) else {
            return XCTFail("a 429 should stop user work too")
        }
        XCTAssertGreaterThanOrEqual(until.timeIntervalSince(clock.now), 90)
        XCTAssertLessThanOrEqual(until.timeIntervalSince(clock.now), 90 + HeavyWorkPolicy.downloads.jitter)
    }

    func testRateLimitWithoutRetryAfterBacksOffExponentiallyAndCaps() {
        let policy = HeavyWorkPolicy.downloads
        var pacer = HeavyWorkPacer()
        var waits: [TimeInterval] = []
        var now = start
        for _ in 0..<8 {
            pacer.rateLimited(now: now, retryAfter: nil, policy: policy, random: 0.5)
            let until = pacer.backoffUntil ?? now
            waits.append(until.timeIntervalSince(now))
            now = until
        }
        XCTAssertEqual(waits[0], policy.backoffBase, accuracy: 0.001)
        XCTAssertEqual(waits[1], policy.backoffBase * 2, accuracy: 0.001)
        XCTAssertEqual(waits[2], policy.backoffBase * 4, accuracy: 0.001)
        XCTAssertEqual(waits.last ?? 0, policy.backoffCap, accuracy: 0.001)
        XCTAssertEqual(pacer.strikes, 8)
    }

    func testSuccessAfterBackOffClearsStrikes() {
        var pacer = HeavyWorkPacer()
        pacer.rateLimited(now: start, retryAfter: 60, policy: .downloads, random: 0)
        let later = start.addingTimeInterval(61)
        XCTAssertEqual(pacer.gate(.background, now: later, conditions: HeavyWorkConditions(), policy: .downloads), .go)
        pacer.finished(now: later, policy: .downloads, random: 0)
        XCTAssertEqual(pacer.strikes, 0)
        XCTAssertNil(pacer.backoffUntil)
    }

    func testResumesWhereItStoppedAfterARelaunch() throws {
        var clock = FakeClock(now: start)
        let network = FakeNetwork(["b": [.rateLimited(retryAfter: 120)]])
        var first = PacedDriver(queue: background("a", "b", "c", "d"), policy: .downloads)
        first.run(clock: &clock, network: network)
        XCTAssertTrue(first.stoppedByRateLimit)

        let saved = try JSONEncoder().encode(first.snapshot)
        let backoffUntil = try XCTUnwrap(first.pacer.backoffUntil)
        clock.advance(10)

        let restored = try JSONDecoder().decode(PacedDriver.Snapshot.self, from: saved)
        XCTAssertEqual(restored, first.snapshot)
        var second = PacedDriver(snapshot: restored, policy: .downloads)
        second.run(clock: &clock, network: network)

        XCTAssertEqual(second.starts.map(\.key), ["b", "c", "d"])
        XCTAssertGreaterThanOrEqual(second.starts[0].at, backoffUntil)
        XCTAssertEqual(network.requests, ["a", "b", "b", "c", "d"])
        XCTAssertTrue(second.queue.isEmpty)
    }

    func testPacerRoundTripsThroughStorage() {
        var pacer = HeavyWorkPacer()
        pacer.rateLimited(now: start, retryAfter: 30, policy: .downloads, random: 0.2)
        XCTAssertEqual(HeavyWorkPacer.decode(pacer.encoded()), pacer)
        XCTAssertNil(HeavyWorkPacer.decode(nil))
        XCTAssertNil(HeavyWorkPacer.decode(Data("nope".utf8)))
    }

    func testAnalysisStatusLine() {
        let paused = HeavyWorkProgress(done: 0, total: 820, isRunning: true, pause: .battery)
        XCTAssertEqual(paused.label(verb: "Analysing"), "Analysing 1 of \(820.formatted()) · paused on battery")
        let running = HeavyWorkProgress(done: 41, total: 820, isRunning: true, pause: nil)
        XCTAssertEqual(running.label(verb: "Analysing"), "Analysing 42 of \(820.formatted())")
        XCTAssertNil(HeavyWorkProgress(done: 820, total: 820).label(verb: "Analysing"))
        XCTAssertNil(HeavyWorkProgress().label(verb: "Analysing"))
    }

    func testAnalysisLanePauseReasons() {
        XCTAssertEqual(
            AnalysisLanePolicy.pause(AnalysisLaneConditions(device: .mac, isOnPower: true, isPlaying: false, systemPause: AnalysisLanePolicy.lowPowerReason)),
            .lowPower
        )
        XCTAssertEqual(
            AnalysisLanePolicy.pause(AnalysisLaneConditions(device: .mac, isOnPower: true, isPlaying: false, systemPause: AnalysisLanePolicy.thermalReason)),
            .thermal
        )
        XCTAssertEqual(AnalysisLanePolicy.pause(AnalysisLaneConditions(device: .phone, isOnPower: false, isPlaying: false)), .battery)
        XCTAssertEqual(AnalysisLanePolicy.pause(AnalysisLaneConditions(device: .mac, isOnPower: true, isPlaying: true)), .listening)
        XCTAssertNil(AnalysisLanePolicy.pause(AnalysisLaneConditions(device: .mac, isOnPower: false, isPlaying: false)))
    }

    func testLibraryStatusLine() {
        var counts = LibraryItemCounts()
        var walking = LibraryCursor()
        walking.phase = .walking
        walking.expectedTotal = 4_000
        counts.add(.likes, cursor: walking, count: 3_710)
        var done = LibraryCursor()
        done.phase = .complete
        done.completedAt = start
        counts.add(.ownPlaylists, cursor: done, count: 500)
        var followers = LibraryCursor()
        followers.expectedTotal = 90_000
        counts.add(.followers, cursor: followers, count: 0)
        XCTAssertEqual(counts.label, "Library: \(4_210.formatted()) of \(6_500.formatted()) items")

        counts.isComplete = true
        XCTAssertEqual(counts.label, "Library: \(4_210.formatted()) items")
        XCTAssertNil(LibraryItemCounts().label)
    }
}
