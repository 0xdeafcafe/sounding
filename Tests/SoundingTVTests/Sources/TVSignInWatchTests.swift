import XCTest
@testable import SoundingTV

final class TVSignInWatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    func testTVNeedingSignInIsSeen() {
        var sightings = TVSignInSightings()
        sightings.observe(name: "Living Room", kind: .tv, signedIn: false, at: at(0))
        XCTAssertTrue(sightings.needsSignIn(name: "Living Room", kind: .tv))
        XCTAssertFalse(sightings.signedIn(name: "Living Room", kind: .tv, since: start))
    }

    func testSignInAfterNeedingItIsSuccess() {
        var sightings = TVSignInSightings()
        sightings.observe(name: "Living Room", kind: .tv, signedIn: false, at: at(0))
        XCTAssertTrue(sightings.observe(name: "Living Room", kind: .tv, signedIn: true, at: at(20)))
        XCTAssertFalse(sightings.needsSignIn(name: "Living Room", kind: .tv))
        XCTAssertTrue(sightings.signedIn(name: "living room ", kind: .tv, since: at(5)))
        XCTAssertFalse(sightings.signedIn(name: "Living Room", kind: .tv, since: at(30)))
    }

    func testTVThatWasAlwaysSignedInIsNotEvidence() {
        var sightings = TVSignInSightings()
        XCTAssertFalse(sightings.observe(name: "Living Room", kind: .tv, signedIn: true, at: at(0)))
        XCTAssertFalse(sightings.needsSignIn(name: "Living Room", kind: .tv))
        XCTAssertFalse(sightings.signedIn(name: "Living Room", kind: .tv, since: start))
    }

    func testRepeatedSignedInSightingsKeepTheFirstTime() {
        var sightings = TVSignInSightings()
        sightings.observe(name: "Living Room", kind: .tv, signedIn: false, at: at(0))
        sightings.observe(name: "Living Room", kind: .tv, signedIn: true, at: at(10))
        XCTAssertFalse(sightings.observe(name: "Living Room", kind: .tv, signedIn: true, at: at(40)))
        XCTAssertTrue(sightings.signedIn(name: "Living Room", kind: .tv, since: at(10)))
    }

    func testNeedingSignInAgainCancelsEvidence() {
        var sightings = TVSignInSightings()
        sightings.observe(name: "Living Room", kind: .tv, signedIn: false, at: at(0))
        sightings.observe(name: "Living Room", kind: .tv, signedIn: true, at: at(10))
        sightings.observe(name: "Living Room", kind: .tv, signedIn: false, at: at(20))
        XCTAssertTrue(sightings.needsSignIn(name: "Living Room", kind: .tv))
        XCTAssertFalse(sightings.signedIn(name: "Living Room", kind: .tv, since: start))
    }

    func testOtherTVsAreSeparate() {
        var sightings = TVSignInSightings()
        sightings.observe(name: "Living Room", kind: .tv, signedIn: false, at: at(0))
        sightings.observe(name: "Bedroom", kind: .tv, signedIn: false, at: at(0))
        sightings.observe(name: "Bedroom", kind: .tv, signedIn: true, at: at(10))
        XCTAssertFalse(sightings.signedIn(name: "Living Room", kind: .tv, since: start))
        XCTAssertTrue(sightings.signedIn(name: "Bedroom", kind: .tv, since: start))
    }

    func testTVSuccessCompletesTheSheet() {
        var watch = TVSignInWatch(since: start)
        watch.tvSignedIn()
        XCTAssertEqual(watch.verdict, .succeeded)
    }

    func testLostAnswerWaitsForTheTVInsteadOfFailing() {
        var watch = TVSignInWatch(since: start)
        watch.transferFailed("Your Apple TV didn't answer.", at: at(10), awaitingTV: true)
        XCTAssertEqual(watch.verdict, .waiting)
        watch.tick(at: at(10 + TVSignInWatch.grace - 1))
        XCTAssertEqual(watch.verdict, .waiting)
        watch.tvSignedIn()
        watch.tick(at: at(60))
        XCTAssertEqual(watch.verdict, .succeeded)
    }

    func testTimesOutOnlyWithoutSuccess() {
        var watch = TVSignInWatch(since: start)
        watch.transferFailed("Your Apple TV didn't answer.", at: at(10), awaitingTV: true)
        watch.tick(at: at(10 + TVSignInWatch.grace))
        XCTAssertEqual(watch.verdict, .failed("Your Apple TV didn't answer."))
    }

    func testFailureBeforeSendingIsImmediate() {
        var watch = TVSignInWatch(since: start)
        watch.transferFailed("Couldn't find your Apple TV.", at: at(10), awaitingTV: false)
        XCTAssertEqual(watch.verdict, .failed("Couldn't find your Apple TV."))
        XCTAssertNil(watch.pending)
    }

    func testTVSuccessOverridesAShownFailure() {
        var watch = TVSignInWatch(since: start)
        watch.transferFailed("The connection dropped.", at: at(10), awaitingTV: false)
        watch.tvSignedIn()
        XCTAssertEqual(watch.verdict, .succeeded)
    }

    func testAckCompletesAndLaterFailuresAreIgnored() {
        var watch = TVSignInWatch(since: start)
        watch.transferCompleted()
        watch.transferFailed("The connection dropped.", at: at(10), awaitingTV: true)
        watch.tick(at: at(60))
        XCTAssertEqual(watch.verdict, .succeeded)
    }

    func testSecondFailureKeepsTheFirstDeadline() {
        var watch = TVSignInWatch(since: start)
        watch.transferFailed("Your Apple TV didn't answer.", at: at(10), awaitingTV: true)
        watch.transferFailed("The connection dropped.", at: at(11), awaitingTV: true)
        XCTAssertEqual(watch.pending?.message, "Your Apple TV didn't answer.")
        XCTAssertEqual(watch.pending?.deadline, at(10 + TVSignInWatch.grace))
    }
}
