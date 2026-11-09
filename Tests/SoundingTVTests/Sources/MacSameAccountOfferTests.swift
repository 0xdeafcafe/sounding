import XCTest
@testable import SoundingTV

final class MacSameAccountOfferTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let livingRoom = SameAccountLinkOffer.Candidate(sessionIdPrefix: "abcd1234", name: "Living Room", kind: .tv)
    private let bedroom = SameAccountLinkOffer.Candidate(sessionIdPrefix: "ef015678", name: "Bedroom", kind: .tv)

    private func suggested(_ candidates: [SameAccountLinkOffer.Candidate]? = nil) -> SameAccountLinkOffer {
        var offer = SameAccountLinkOffer()
        offer.observe(candidates ?? [livingRoom], now: start)
        return offer
    }

    private func prompt(_ offer: SameAccountLinkOffer) -> SameAccountLinkPrompt? {
        SameAccountLinkPrompt(offer.phase)
    }

    private func endHandshake(_ offer: inout SameAccountLinkOffer) {
        if case .linking = offer.phase { offer.finish(succeeded: false) }
        offer.retry()
    }

    // MARK: - Prompt mapping

    func testHiddenAndLinkingShowNothing() {
        XCTAssertNil(SameAccountLinkPrompt(.hidden))
        XCTAssertNil(SameAccountLinkPrompt(.linking(livingRoom, since: start)))
    }

    func testSuggestionCopy() {
        let prompt = SameAccountLinkPrompt(.suggested(livingRoom))
        XCTAssertEqual(prompt, .suggestion(name: "Living Room"))
        XCTAssertEqual(prompt?.title, "Living Room is signed in to your account. Link it?")
        XCTAssertEqual(prompt?.primaryAction, "Link")
        XCTAssertNil(prompt?.message)
        XCTAssertEqual(prompt?.name, "Living Room")
    }

    func testFailureCopy() {
        let prompt = SameAccountLinkPrompt(.failed(livingRoom, message: "The connection dropped."))
        XCTAssertEqual(prompt?.title, "Couldn't Link Living Room")
        XCTAssertEqual(prompt?.message, "The connection dropped.")
        XCTAssertEqual(prompt?.primaryAction, "Try Again")
    }

    // MARK: - Flows

    func testLinkHidesPromptWhileLinking() {
        var offer = suggested()
        XCTAssertEqual(prompt(offer), .suggestion(name: "Living Room"))
        XCTAssertEqual(offer.accept(now: start), livingRoom)
        XCTAssertNil(prompt(offer))
        offer.observe([livingRoom], now: start.addingTimeInterval(10))
        XCTAssertNil(prompt(offer))
    }

    func testSuccessKeepsThatTVQuiet() {
        var offer = suggested()
        _ = offer.accept(now: start)
        offer.finish(succeeded: true)
        XCTAssertNil(prompt(offer))
        offer.observe([livingRoom], now: start.addingTimeInterval(30))
        XCTAssertNil(prompt(offer))
    }

    func testTransferFailureShowsMessageThenTryAgainReturnsToSuggestion() {
        var offer = suggested()
        _ = offer.accept(now: start)
        offer.finish(succeeded: false, message: "Could not find Living Room.")
        XCTAssertEqual(prompt(offer), .failed(name: "Living Room", message: "Could not find Living Room."))
        offer.observe([], now: start.addingTimeInterval(5))
        XCTAssertEqual(prompt(offer)?.message, "Could not find Living Room.")
        offer.retry()
        XCTAssertEqual(prompt(offer), .suggestion(name: "Living Room"))
    }

    func testCancellingTheCodeReturnsToSuggestion() {
        var offer = suggested()
        _ = offer.accept(now: start)
        endHandshake(&offer)
        XCTAssertEqual(prompt(offer), .suggestion(name: "Living Room"))
    }

    func testNotNowIsQuietForTheSession() {
        var offer = suggested()
        offer.dismiss()
        XCTAssertNil(prompt(offer))
        offer.observe([livingRoom], now: start.addingTimeInterval(60))
        XCTAssertNil(prompt(offer))
    }

    func testNotNowOnFailureIsQuietToo() {
        var offer = suggested()
        _ = offer.accept(now: start)
        offer.finish(succeeded: false)
        offer.dismiss()
        XCTAssertNil(prompt(offer))
        offer.observe([livingRoom], now: start.addingTimeInterval(60))
        XCTAssertNil(prompt(offer))
    }

    func testNotNowMovesOnToAnotherTV() {
        var offer = suggested([livingRoom, bedroom])
        offer.dismiss()
        offer.observe([livingRoom, bedroom], now: start.addingTimeInterval(1))
        XCTAssertEqual(prompt(offer), .suggestion(name: "Bedroom"))
    }

    func testLinkingTimesOutIntoFailure() {
        var offer = suggested()
        _ = offer.accept(now: start)
        offer.observe([livingRoom], now: start.addingTimeInterval(SameAccountLinkOffer.linkingTimeout + 1))
        XCTAssertEqual(prompt(offer)?.primaryAction, "Try Again")
    }

    func testSecondLinkWhileLinkingIsIgnored() {
        var offer = suggested()
        _ = offer.accept(now: start)
        XCTAssertNil(offer.accept(now: start))
    }
}
