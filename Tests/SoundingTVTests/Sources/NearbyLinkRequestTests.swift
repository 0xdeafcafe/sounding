import CloudKit
import XCTest
@testable import SoundingTV

final class NearbyLinkRequestTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3_600

    private func request(accountId: String = "42", linked: [String] = [], at created: Date? = nil) -> NearbyLinkRequest {
        NearbyLinkRequest(
            nonce: String(repeating: "ab", count: 16),
            tvName: "Living Room",
            tvKind: .tv,
            tvTag: NearbyLinkRequest.tvTag(deviceId: "TV-1"),
            accountTag: AccountSignIn.accountTag(userId: accountId),
            linkedDevices: linked.map { NearbyLinkRequest.deviceTag(deviceId: $0) },
            createdAt: created ?? start
        )!
    }

    private func decide(
        at offset: TimeInterval,
        reason: Bool = true,
        lastPosted: TimeInterval? = nil,
        snoozed: TimeInterval? = nil,
        absence: DateInterval? = nil
    ) -> NearbyLinkRequestPolicy.Decision {
        NearbyLinkRequestPolicy.decide(
            now: start.addingTimeInterval(offset),
            hasReason: reason,
            lastPostedAt: lastPosted.map { start.addingTimeInterval($0) },
            snoozedAt: snoozed.map { start.addingTimeInterval($0) },
            lastAbsence: absence
        )
    }

    // MARK: - Reason

    func testAsksOnlyWhenSignedInActiveAndNotPairing() {
        XCTAssertTrue(NearbyLinkRequestPolicy.hasReason(isSignedIn: true, isActive: true, isPairing: false, seesUnlinkedPhone: false, linkedDeviceCount: 0))
        XCTAssertFalse(NearbyLinkRequestPolicy.hasReason(isSignedIn: false, isActive: true, isPairing: false, seesUnlinkedPhone: true, linkedDeviceCount: 0))
        XCTAssertFalse(NearbyLinkRequestPolicy.hasReason(isSignedIn: true, isActive: false, isPairing: false, seesUnlinkedPhone: true, linkedDeviceCount: 0))
        XCTAssertFalse(NearbyLinkRequestPolicy.hasReason(isSignedIn: true, isActive: true, isPairing: true, seesUnlinkedPhone: true, linkedDeviceCount: 0))
    }

    func testALinkedTVAsksOnlyWhenItSeesAnUnlinkedPhone() {
        XCTAssertFalse(NearbyLinkRequestPolicy.hasReason(isSignedIn: true, isActive: true, isPairing: false, seesUnlinkedPhone: false, linkedDeviceCount: 1))
        XCTAssertTrue(NearbyLinkRequestPolicy.hasReason(isSignedIn: true, isActive: true, isPairing: false, seesUnlinkedPhone: true, linkedDeviceCount: 1))
    }

    // MARK: - Throttle

    func testFirstRequestIsPosted() {
        XCTAssertEqual(decide(at: 0), .post)
    }

    func testNothingToAskIsNotPosted() {
        XCTAssertEqual(decide(at: 0, reason: false), .notNeeded)
    }

    func testOneRequestPerTwelveHours() {
        XCTAssertEqual(decide(at: 11 * hour, lastPosted: 0), .throttled)
        XCTAssertEqual(decide(at: 12 * hour, lastPosted: 0), .post)
    }

    func testAPostTimeInTheFutureDoesNotBlockForever() {
        XCTAssertEqual(decide(at: 0, lastPosted: 48 * hour), .post)
    }

    // MARK: - Not Now

    func testNotNowHoldsForTwelveHours() {
        let away = DateInterval(start: start.addingTimeInterval(hour), duration: 2 * hour)
        XCTAssertEqual(decide(at: 11 * hour, snoozed: 0, absence: away), .snoozed)
    }

    func testNotNowNeedsTheTVToHaveBeenAwayAfterwards() {
        XCTAssertEqual(decide(at: 13 * hour, snoozed: 0), .snoozed)
        let before = DateInterval(start: start.addingTimeInterval(-3 * hour), duration: 2 * hour)
        XCTAssertEqual(decide(at: 13 * hour, snoozed: 0, absence: before), .snoozed)
    }

    func testNotNowNeedsAnAbsenceOfThirtyMinutes() {
        let short = DateInterval(start: start.addingTimeInterval(hour), duration: 29 * 60)
        XCTAssertEqual(decide(at: 13 * hour, snoozed: 0, absence: short), .snoozed)
        let long = DateInterval(start: start.addingTimeInterval(hour), duration: 30 * 60)
        XCTAssertEqual(decide(at: 13 * hour, snoozed: 0, absence: long), .post)
    }

    func testThrottleStillAppliesAfterNotNowExpires() {
        let away = DateInterval(start: start.addingTimeInterval(hour), duration: 2 * hour)
        XCTAssertEqual(decide(at: 13 * hour, lastPosted: 6 * hour, snoozed: 0, absence: away), .throttled)
    }

    // MARK: - Absence

    func testAbsenceRecordsOnlyLongGaps() {
        var absence = NearbyLinkAbsence()
        absence.wentAway(at: start)
        absence.cameBack(at: start.addingTimeInterval(10 * 60))
        XCTAssertNil(absence.lastAbsence)
        absence.wentAway(at: start.addingTimeInterval(hour))
        absence.wentAway(at: start.addingTimeInterval(2 * hour))
        absence.cameBack(at: start.addingTimeInterval(3 * hour))
        XCTAssertEqual(absence.lastAbsence, DateInterval(start: start.addingTimeInterval(hour), end: start.addingTimeInterval(3 * hour)))
        XCTAssertNil(absence.awaySince)
    }

    func testComingBackWithoutLeavingChangesNothing() {
        var absence = NearbyLinkAbsence()
        absence.cameBack(at: start)
        XCTAssertEqual(absence, NearbyLinkAbsence())
    }

    // MARK: - Withdrawal

    func testWithdrawal() {
        let expires = start.addingTimeInterval(NearbyLinkRequest.lifetime)
        XCTAssertEqual(NearbyLinkRequestPolicy.withdrawal(expiresAt: expires, now: start, isActive: true, isSignedIn: true, linkedSincePosting: false), .keep)
        XCTAssertEqual(NearbyLinkRequestPolicy.withdrawal(expiresAt: expires, now: start, isActive: true, isSignedIn: true, linkedSincePosting: true), .linked)
        XCTAssertEqual(NearbyLinkRequestPolicy.withdrawal(expiresAt: expires, now: start, isActive: false, isSignedIn: true, linkedSincePosting: false), .away)
        XCTAssertEqual(NearbyLinkRequestPolicy.withdrawal(expiresAt: expires, now: start, isActive: true, isSignedIn: false, linkedSincePosting: false), .away)
        XCTAssertEqual(NearbyLinkRequestPolicy.withdrawal(expiresAt: expires, now: expires, isActive: true, isSignedIn: true, linkedSincePosting: false), .expired)
    }

    func testRequestLastsTenMinutes() {
        let request = request()
        XCTAssertEqual(request.expiresAt, start.addingTimeInterval(600))
        XCTAssertFalse(request.isExpired(at: start.addingTimeInterval(599)))
        XCTAssertTrue(request.isExpired(at: start.addingTimeInterval(600)))
    }

    // MARK: - Phone verdict

    func testVerdictOnTheSameAccount() {
        XCTAssertEqual(request().verdict(localDeviceId: "PHONE-1", currentUserId: "42", isSignedOut: false, now: start), .show)
    }

    func testVerdictOnAnotherAccountOrSignedOut() {
        XCTAssertEqual(request().verdict(localDeviceId: "PHONE-1", currentUserId: "7", isSignedOut: false, now: start), .otherAccount)
        XCTAssertEqual(request().verdict(localDeviceId: "PHONE-1", currentUserId: nil, isSignedOut: true, now: start), .otherAccount)
    }

    func testVerdictWhenThisPhoneIsAlreadyLinked() {
        let linked = request(linked: ["phone-1"])
        XCTAssertEqual(linked.verdict(localDeviceId: "PHONE-1", currentUserId: "42", isSignedOut: false, now: start), .linked)
        let byName = SameAccountLinkOffer.identity(name: "Living Room", kind: .tv)
        XCTAssertEqual(request().verdict(localDeviceId: "PHONE-1", currentUserId: "42", isSignedOut: false, linkedIdentities: [byName], now: start), .linked)
    }

    func testVerdictWhenExpired() {
        let verdict = request().verdict(localDeviceId: "PHONE-1", currentUserId: "42", isSignedOut: false, now: start.addingTimeInterval(601))
        XCTAssertEqual(verdict, .expired)
        XCTAssertTrue(verdict.allowsLinking)
    }

    // MARK: - Record

    func testRecordRoundTrip() {
        let original = request(linked: ["phone-2", "mac-1"])
        let decoded = NearbyLinkRequest(record: original.record())
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(original.recordName.hasPrefix(NearbyLinkRequest.recordPrefix))
    }

    func testTagsHideRawIds() {
        let tag = NearbyLinkRequest.tvTag(deviceId: "TV-1")
        XCTAssertFalse(tag.contains("TV-1"))
        XCTAssertEqual(tag, NearbyLinkRequest.tvTag(deviceId: "tv-1"))
        XCTAssertNotEqual(NearbyLinkRequest.deviceTag(deviceId: "TV-1"), String(tag.prefix(16)))
    }

    func testSnoozeRecordRoundTrip() {
        let snooze = NearbyLinkSnooze(tvTag: "abc", snoozedAt: start)
        XCTAssertEqual(NearbyLinkSnooze(record: snooze.record()), snooze)
    }
}
