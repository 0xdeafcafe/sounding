import XCTest
@testable import SoundingTV

final class OutputPresenceTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let livingRoom = OutputDevice.linked(sessionId: "living", name: "Living Room", deviceClass: .tv)
    private let bedroom = OutputDevice.linked(sessionId: "bedroom", name: "Bedroom", deviceClass: .tv)
    private let kitchen = OutputDevice.linked(sessionId: "kitchen", name: "kitchen", deviceClass: .tv)
    private let local = OutputDevice(id: OutputDevice.localID, name: "This iPhone", deviceClass: .phone)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    // MARK: - Hysteresis

    func testUnseenDeviceIsNotListed() {
        let presence = OutputPresence()
        XCTAssertNil(presence.availability(of: livingRoom.id, at: start))
    }

    func testBriefDropStaysAvailable() {
        var presence = OutputPresence(settle: 10, grace: 45)
        presence.observe(live: [livingRoom.id], at: at(0))
        presence.observe(live: [], at: at(1))
        XCTAssertEqual(presence.availability(of: livingRoom.id, at: at(1)), .available)
        XCTAssertEqual(presence.availability(of: livingRoom.id, at: at(10.9)), .available)
        presence.observe(live: [livingRoom.id], at: at(5))
        XCTAssertEqual(presence.availability(of: livingRoom.id, at: at(30)), .available)
    }

    func testLongerDropDimsThenRemoves() {
        var presence = OutputPresence(settle: 10, grace: 45)
        presence.observe(live: [livingRoom.id], at: at(0))
        presence.observe(live: [], at: at(2))
        XCTAssertEqual(presence.availability(of: livingRoom.id, at: at(12)), .notResponding)
        XCTAssertEqual(presence.availability(of: livingRoom.id, at: at(46)), .notResponding)
        XCTAssertNil(presence.availability(of: livingRoom.id, at: at(47)))
    }

    func testRepeatedMissingObservationsKeepTheFirstDropTime() {
        var presence = OutputPresence(settle: 10, grace: 45)
        presence.observe(live: [livingRoom.id], at: at(0))
        presence.observe(live: [], at: at(1))
        presence.observe(live: [], at: at(20))
        presence.observe(live: [], at: at(40))
        XCTAssertNil(presence.availability(of: livingRoom.id, at: at(46)))
    }

    func testFlappingNeverRemovesTheDevice() {
        var presence = OutputPresence(settle: 10, grace: 45)
        var seen: [OutputAvailability?] = []
        for second in stride(from: 0.0, to: 120, by: 3) {
            let isLive = Int(second / 3) % 2 == 0
            presence.observe(live: isLive ? [livingRoom.id] : [], at: at(second))
            seen.append(presence.availability(of: livingRoom.id, at: at(second + 1)))
        }
        XCTAssertTrue(seen.allSatisfy { $0 == .available })
    }

    func testNextChangeReportsSettleThenGrace() {
        var presence = OutputPresence(settle: 10, grace: 45)
        presence.observe(live: [livingRoom.id], at: at(0))
        presence.observe(live: [], at: at(5))
        XCTAssertEqual(presence.nextChange(after: at(5)), at(15))
        XCTAssertEqual(presence.nextChange(after: at(15)), at(50))
        XCTAssertNil(presence.nextChange(after: at(50)))
    }

    func testForgottenLinksAreDropped() {
        var presence = OutputPresence()
        presence.observe(live: [livingRoom.id, bedroom.id], at: at(0))
        presence.retain(only: [bedroom.id])
        XCTAssertNil(presence.availability(of: livingRoom.id, at: at(0)))
        XCTAssertEqual(presence.availability(of: bedroom.id, at: at(0)), .available)
    }

    // MARK: - Merge and order

    func testCurrentFirstThenThisDeviceThenByName() {
        var presence = OutputPresence()
        presence.observe(live: [livingRoom.id, bedroom.id, kitchen.id], at: at(0))
        let entries = OutputList.entries(
            local: local,
            linked: [livingRoom, kitchen, bedroom],
            current: livingRoom,
            presence: presence,
            at: at(0)
        )
        XCTAssertEqual(entries.map(\.id), [livingRoom.id, local.id, bedroom.id, kitchen.id])
    }

    func testOrderIsStableAcrossRefreshes() {
        var presence = OutputPresence()
        presence.observe(live: [livingRoom.id, bedroom.id], at: at(0))
        let first = OutputList.entries(local: local, linked: [livingRoom, bedroom], current: local, presence: presence, at: at(0))
        presence.observe(live: [bedroom.id, livingRoom.id], at: at(1))
        let second = OutputList.entries(local: local, linked: [bedroom, livingRoom], current: local, presence: presence, at: at(1))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.id), [local.id, bedroom.id, livingRoom.id])
    }

    func testCurrentOutputNeverVanishes() {
        var presence = OutputPresence(settle: 10, grace: 45)
        presence.observe(live: [livingRoom.id], at: at(0))
        presence.observe(live: [], at: at(1))
        let entries = OutputList.entries(local: local, linked: [livingRoom], current: livingRoom, presence: presence, at: at(600))
        XCTAssertEqual(entries.first?.id, livingRoom.id)
        XCTAssertEqual(entries.first?.availability, .notResponding)
    }

    func testRestoringCurrentShowsConnecting() {
        let entries = OutputList.entries(local: local, linked: [livingRoom], current: livingRoom, presence: OutputPresence(), at: at(0))
        XCTAssertEqual(entries.map(\.id), [livingRoom.id, local.id])
        XCTAssertEqual(entries.first?.availability, .connecting)
    }

    func testExpiredNonCurrentDeviceIsRemoved() {
        var presence = OutputPresence(settle: 10, grace: 45)
        presence.observe(live: [livingRoom.id], at: at(0))
        presence.observe(live: [], at: at(1))
        let dimmed = OutputList.entries(local: local, linked: [livingRoom], current: local, presence: presence, at: at(20))
        XCTAssertEqual(dimmed.map(\.availability), [.available, .notResponding])
        let gone = OutputList.entries(local: local, linked: [livingRoom], current: local, presence: presence, at: at(60))
        XCTAssertEqual(gone.map(\.id), [local.id])
    }

    func testSameTVUnderTwoLinksIsListedOnce() {
        let stale = OutputDevice.linked(sessionId: "living-old", name: "Living Room", deviceClass: .tv)
        var presence = OutputPresence(settle: 10, grace: 45)
        presence.observe(live: [livingRoom.id, stale.id], at: at(0))
        presence.observe(live: [livingRoom.id], at: at(1))
        for second in [15.0, 30] {
            let entries = OutputList.entries(local: local, linked: [stale, livingRoom], current: local, presence: presence, at: at(second))
            XCTAssertEqual(entries.map(\.id), [local.id, livingRoom.id])
        }
    }

    func testTwoLiveDevicesWithOneNameStayDistinct() {
        let other = OutputDevice.linked(sessionId: "living-2", name: "Living Room", deviceClass: .tv)
        var presence = OutputPresence()
        presence.observe(live: [livingRoom.id, other.id], at: at(0))
        let entries = OutputList.entries(local: local, linked: [other, livingRoom], current: local, presence: presence, at: at(0))
        XCTAssertEqual(entries.map(\.id), [local.id, livingRoom.id, other.id])
    }

    func testDuplicateNamePrefersTheActiveLink() {
        let other = OutputDevice.linked(sessionId: "living-2", name: "Living Room", deviceClass: .tv)
        var presence = OutputPresence(settle: 10, grace: 45)
        presence.observe(live: [livingRoom.id, other.id], at: at(0))
        presence.observe(live: [], at: at(1))
        let entries = OutputList.entries(local: local, linked: [livingRoom, other], current: local, preferredID: other.id, presence: presence, at: at(20))
        XCTAssertEqual(entries.map(\.id), [local.id, other.id])
    }

    func testDuplicateLinkIdsMerge() {
        var presence = OutputPresence()
        presence.observe(live: [livingRoom.id], at: at(0))
        let entries = OutputList.entries(local: local, linked: [livingRoom, livingRoom], current: local, presence: presence, at: at(0))
        XCTAssertEqual(entries.map(\.id), [local.id, livingRoom.id])
    }

    func testSelectableOnlyWhenAvailable() {
        XCTAssertTrue(OutputAvailability.available.isSelectable)
        XCTAssertFalse(OutputAvailability.connecting.isSelectable)
        XCTAssertFalse(OutputAvailability.notResponding.isSelectable)
        XCTAssertNil(OutputAvailability.available.label)
        XCTAssertEqual(OutputAvailability.notResponding.label, "Not Responding")
    }

    // MARK: - Restore

    func testRestoreWaitsThenRestoresWhenTheDeviceAppears() {
        let restore = OutputRestore(savedID: livingRoom.id, startedAt: at(0), window: 25)
        XCTAssertEqual(restore.decide(linkedIDs: [livingRoom.id], liveIDs: [], at: at(3)), .wait)
        XCTAssertEqual(restore.decide(linkedIDs: [livingRoom.id], liveIDs: [livingRoom.id], at: at(12)), .restored)
    }

    func testRestoreFallsBackAfterTheWindow() {
        let restore = OutputRestore(savedID: livingRoom.id, startedAt: at(0), window: 25)
        XCTAssertEqual(restore.decide(linkedIDs: [livingRoom.id], liveIDs: [], at: at(24.9)), .wait)
        XCTAssertEqual(restore.decide(linkedIDs: [livingRoom.id], liveIDs: [], at: at(25)), .fallBack)
        XCTAssertEqual(restore.deadline, at(25))
    }

    func testRestoreFallsBackWhenTheLinkIsGone() {
        let restore = OutputRestore(savedID: livingRoom.id, startedAt: at(0))
        XCTAssertEqual(restore.decide(linkedIDs: [bedroom.id], liveIDs: [bedroom.id], at: at(0)), .fallBack)
    }

    func testRestoringThisDeviceIsImmediate() {
        let restore = OutputRestore(savedID: OutputDevice.localID, startedAt: at(0))
        XCTAssertEqual(restore.decide(linkedIDs: [], liveIDs: [], at: at(0)), .restored)
    }

    func testPreferenceRemembersThisDeviceExplicitly() throws {
        let suite = "OutputPresenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = OutputPreference(defaults: defaults)
        XCTAssertNil(preference.savedID)
        preference.remember(livingRoom)
        XCTAssertEqual(preference.savedID, livingRoom.id)
        preference.remember(local)
        XCTAssertEqual(preference.savedID, OutputDevice.localID)
        XCTAssertEqual(OutputPreference.key, "red.forbes.sounding.output.v1")
    }
}

final class OutputHandoverTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testPlayingHereMovesThisDevicesQueue() {
        XCTAssertEqual(OutputHandover.plan(localIsPlaying: true, localHasTrack: true, remoteIsPlaying: true, remoteHasTrack: true), .sendThisDevice)
        XCTAssertEqual(OutputHandover.plan(localIsPlaying: true, localHasTrack: true, remoteIsPlaying: false, remoteHasTrack: false), .sendThisDevice)
    }

    func testAPlayingRemoteIsControlledNotReplacedByAPausedQueue() {
        XCTAssertEqual(OutputHandover.plan(localIsPlaying: false, localHasTrack: true, remoteIsPlaying: true, remoteHasTrack: true), .controlRemote)
        XCTAssertEqual(OutputHandover.plan(localIsPlaying: false, localHasTrack: false, remoteIsPlaying: true, remoteHasTrack: true), .controlRemote)
    }

    func testAPausedQueueStillMovesToAnIdleRemote() {
        XCTAssertEqual(OutputHandover.plan(localIsPlaying: false, localHasTrack: true, remoteIsPlaying: false, remoteHasTrack: true), .sendThisDevice)
        XCTAssertEqual(OutputHandover.plan(localIsPlaying: false, localHasTrack: true, remoteIsPlaying: false, remoteHasTrack: false), .sendThisDevice)
    }

    func testNothingAnywhereJustSelectsTheRemote() {
        XCTAssertEqual(OutputHandover.plan(localIsPlaying: false, localHasTrack: false, remoteIsPlaying: false, remoteHasTrack: false), .controlRemote)
    }

    private func follows(
        currentIsLocal: Bool = true,
        isMoving: Bool = false,
        localIsPlaying: Bool = false,
        localLastPlayedAt: Date? = nil,
        audible: Bool = true,
        wasAudible: Bool = false
    ) -> Bool {
        OutputFollow.shouldFollow(
            currentIsLocal: currentIsLocal,
            isMoving: isMoving,
            localIsPlaying: localIsPlaying,
            localLastPlayedAt: localLastPlayedAt,
            remoteIsAudible: audible,
            remoteWasAudible: wasAudible,
            now: start
        )
    }

    func testFollowsARemoteThatStartsPlayingWhileThisDeviceIsIdle() {
        XCTAssertTrue(follows())
    }

    func testFollowsOnlyOnTheRisingEdge() {
        XCTAssertFalse(follows(wasAudible: true))
        XCTAssertFalse(follows(audible: false))
    }

    func testNeverFollowsWhileThisDevicePlaysOrIsMoving() {
        XCTAssertFalse(follows(localIsPlaying: true))
        XCTAssertFalse(follows(isMoving: true))
        XCTAssertFalse(follows(currentIsLocal: false))
    }

    func testRecentLocalListeningOrChoiceHoldsTheOutput() {
        XCTAssertFalse(follows(localLastPlayedAt: start.addingTimeInterval(-60)))
        XCTAssertFalse(follows(localLastPlayedAt: start.addingTimeInterval(-(OutputFollow.localQuietPeriod - 1))))
        XCTAssertTrue(follows(localLastPlayedAt: start.addingTimeInterval(-OutputFollow.localQuietPeriod)))
    }
}
