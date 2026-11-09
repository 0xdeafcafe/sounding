#if DEBUG
import Foundation
import XCTest
@testable import SoundingTV

final class SoundingDataReconcileTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SoundingDataReconcileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Own writes

    func testOwnWritesAndRemovesAreRecognised() throws {
        let url = directory.appendingPathComponent("Zone/ab/own.snda")
        try SoundingDataFiles.write(Data("one".utf8), to: url, presenter: nil)
        XCTAssertTrue(SoundingDataSelfWrites.shared.isOwnChange(url))
        XCTAssertTrue(SoundingDataSelfWrites.shared.isOwnChange(url.deletingLastPathComponent()))

        try Data("someone else wrote this".utf8).write(to: url)
        XCTAssertFalse(SoundingDataSelfWrites.shared.isOwnChange(url))

        SoundingDataFiles.remove(url, presenter: nil)
        XCTAssertTrue(SoundingDataSelfWrites.shared.isOwnChange(url))

        let foreign = directory.appendingPathComponent("Zone/ab/foreign.snda")
        try Data("remote".utf8).write(to: foreign)
        XCTAssertFalse(SoundingDataSelfWrites.shared.isOwnChange(foreign))
    }

    func testOwnWriteRecordsExpire() throws {
        let writes = SoundingDataSelfWrites(lifetime: 10)
        let url = directory.appendingPathComponent("file.snda")
        try Data("x".utf8).write(to: url)
        let start = Date()
        writes.note(url, now: start)
        let generation = writes.generation
        XCTAssertTrue(writes.isOwnChange(url, now: start.addingTimeInterval(5)))
        XCTAssertFalse(writes.isOwnChange(url, now: start.addingTimeInterval(20)))
        writes.note(url, now: start)
        XCTAssertEqual(writes.generation, generation + 1)
    }

    func testPresenterIgnoresOwnWritesButPostsForeignChanges() throws {
        let presenter = SoundingDataPresenter(root: directory)
        let own = directory.appendingPathComponent("Zone/cd/own.snda")
        let foreign = directory.appendingPathComponent("Zone/cd/foreign.snda")
        try SoundingDataFiles.write(Data("mine".utf8), to: own, presenter: nil)
        try Data("theirs".utf8).write(to: foreign)

        let posted = ReconcileCounter()
        let observer = NotificationCenter.default.addObserver(forName: .soundingDataDidChangeOnDisk, object: nil, queue: nil) { note in
            guard note.userInfo?[SoundingDataLocation.areaKey] as? String == "Zone" else { return }
            posted.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        presenter.presentedSubitemDidChange(at: own)
        presenter.presentedSubitemDidAppear(at: own.deletingLastPathComponent())
        XCTAssertEqual(posted.value, 0)

        presenter.presentedSubitemDidChange(at: foreign)
        XCTAssertEqual(posted.value, 1)
    }

    // MARK: Throttle

    func testThrottleCoalescesAndHoldsTheMinimumInterval() {
        var policy = SoundingDataThrottlePolicy(delay: 3, minimumInterval: 30)
        let start = Date(timeIntervalSince1970: 1_000)

        guard let first = policy.request(now: start) else { return XCTFail("first request should schedule") }
        XCTAssertEqual(first.at, start.addingTimeInterval(3))
        XCTAssertNil(policy.request(now: start.addingTimeInterval(1)))
        XCTAssertNil(policy.request(now: start.addingTimeInterval(2)))

        XCTAssertTrue(policy.shouldRun(token: first.token, now: first.at))
        XCTAssertFalse(policy.shouldRun(token: first.token, now: first.at))

        guard let second = policy.request(now: start.addingTimeInterval(4)) else { return XCTFail("second request should schedule") }
        XCTAssertEqual(second.at, first.at.addingTimeInterval(30))
        XCTAssertNil(policy.request(now: start.addingTimeInterval(10)))

        guard let sooner = policy.request(now: start.addingTimeInterval(10), after: 5) else { return XCTFail("explicit request should move earlier") }
        XCTAssertEqual(sooner.at, start.addingTimeInterval(15))
        XCTAssertFalse(policy.shouldRun(token: second.token, now: second.at))
        XCTAssertTrue(policy.shouldRun(token: sooner.token, now: sooner.at))
    }

    func testThrottleRunsOnceForABurstOfChanges() {
        let runs = ReconcileCounter()
        let throttle = SoundingDataThrottle(delay: 0.05, minimumInterval: 60) { runs.increment() }
        for _ in 0..<20 { throttle.trigger() }
        let settle = expectation(description: "settle")
        settle.isInverted = true
        wait(for: [settle], timeout: 0.5)
        XCTAssertEqual(runs.value, 1)

        for _ in 0..<5 { throttle.trigger() }
        let settleAgain = expectation(description: "settle again")
        settleAgain.isInverted = true
        wait(for: [settleAgain], timeout: 0.5)
        XCTAssertEqual(runs.value, 1)
    }

    // MARK: Conflict names

    func testRealConflictCopiesAreRecognised() {
        let folder = directory.appendingPathComponent("Analysis/ab/abcd", isDirectory: true)
        let base = folder.appendingPathComponent("sounding.dsp-0123456789abcdef.snda")
        let stem = "sounding.dsp-0123456789abcdef"
        let copies = [
            "\(stem) 2.snda",
            "\(stem) 17.snda",
            "\(stem) (1).snda",
            "\(stem) (conflicted copy).snda",
            "\(stem) (Alex's conflicted copy 2026-11-09).snda",
            "\(stem) (Moved).snda",
            "\(stem) (Moved 3).snda",
            "\(stem).sync-conflict-20261109-101500-ABCDEF7.snda",
        ]
        for name in copies {
            XCTAssertEqual(SoundingDataFiles.conflictBase(of: folder.appendingPathComponent(name))?.path, base.path, name)
        }
    }

    func testOwnShardNamesAreNeverConflicts() {
        let root = directory.appendingPathComponent("Analysis", isDirectory: true)
        let analysis = AnalysisDataFiles.url(cacheKey: "k", trackId: "soundcloud:tracks:123", engineName: "Sounding DSP 2", in: root)
        let correction = AnalysisDataFiles.url(cacheKey: "k", trackId: "t", engineName: AnalysisEngineIdentity.userCorrection().name, in: root)
        let engineWithConflictInName = root.appendingPathComponent("ab/abcd/no_conflict_engine-0123456789abcdef.snda")
        let journal = root.appendingPathComponent("device/1731000000000-000012-AB12.sndj")
        let setlist = root.appendingPathComponent("ab/soundcloud%3Atracks%3A123.snds")
        let notICloud = root.appendingPathComponent("ab/track 1.snda")
        let zero = root.appendingPathComponent("ab/track 0.snda")
        for url in [analysis, correction, engineWithConflictInName, journal, setlist, notICloud, zero] {
            XCTAssertNil(SoundingDataFiles.conflictBase(of: url), url.lastPathComponent)
        }
    }
}

private final class ReconcileCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
#endif
