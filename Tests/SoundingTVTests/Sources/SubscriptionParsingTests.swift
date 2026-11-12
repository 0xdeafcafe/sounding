import Foundation
import XCTest
@testable import SoundingTV

final class SubscriptionParsingTests: XCTestCase {
    private typealias Resolution = SubscriptionService.Resolution

    private func me(_ extra: String = "") throws -> SoundCloudCurrentUserResponse {
        let body = """
        {"id": 42, "username": "owner", "permalink": "owner", "permalink_url": "https://soundcloud.com/owner",
         "avatar_url": null, "followers_count": 3\(extra.isEmpty ? "" : ", " + extra)}
        """
        return try JSONDecoder().decode(SoundCloudCurrentUserResponse.self, from: Data(body.utf8))
    }

    private func capture(_ json: String) throws -> SoundCloudSubscriptionCapture {
        try JSONDecoder().decode(SoundCloudSubscriptionCapture.self, from: Data(json.utf8))
    }

    private func resolve(_ json: String) throws -> Resolution {
        SubscriptionService.resolve(SubscriptionService.signals(fromPayload: try capture(json).payload))
    }

    func testMeWithoutSubscriptionKeysStaysUnknownAndNamesItsKeys() throws {
        let response = try me()
        XCTAssertTrue(response.subscription.payload.isEmpty)
        XCTAssertEqual(SubscriptionService.resolve(from: response), Resolution(.unknown, .payloadUnreadable))
        let description = SubscriptionService.rawSubscriptionDescription(for: response.subscription, source: "api-v2 /me")
        XCTAssertTrue(description.hasPrefix("no subscription keys present on api-v2 /me"))
        XCTAssertTrue(description.contains("followers_count"))
        XCTAssertTrue(description.contains("username"))
    }

    func testCapturedGoPlusShapeStillResolves() throws {
        let response = try me(#""consumer_subscription": {"product": {"id": "consumer-high-tier"}}"#)
        XCTAssertEqual(SubscriptionService.resolve(from: response), Resolution(.goPlus))
    }

    func testEmptyConsumerListIsAuthoritativeFree() throws {
        XCTAssertEqual(SubscriptionService.resolve(from: try me(#""consumer_subscriptions": []"#)), Resolution(.free))
        XCTAssertEqual(try resolve(#"{"consumer_subscriptions": {"collection": []}}"#), Resolution(.free))
    }

    func testAlternativeConsumerShapes() throws {
        XCTAssertEqual(try resolve(#"{"consumer_subscription": "consumer-high-tier"}"#), Resolution(.goPlus))
        XCTAssertEqual(try resolve(#"{"consumer_subscription": {"product_id": "consumer-mid-tier"}}"#), Resolution(.go))
        XCTAssertEqual(try resolve(#"{"consumer_subscription": {"product": "consumer-dj"}}"#), Resolution(.dj))
        XCTAssertEqual(
            try resolve(#"{"consumer_subscriptions": {"collection": [{"product": {"id": "consumer-high-tier"}}]}}"#),
            Resolution(.goPlus)
        )
        XCTAssertEqual(
            try resolve(#"{"active_consumer_subscription": {"product": {"id": "consumer-mid-tier"}}}"#),
            Resolution(.go)
        )
    }

    func testAnUnexpectedTypedShapeNoLongerBreaksTheMeDecode() throws {
        let response = try me(#""consumer_subscriptions": [{"product": "consumer-high-tier"}]"#)
        XCTAssertNil(response.user.consumerSubscriptions)
        XCTAssertEqual(SubscriptionService.resolve(from: response), Resolution(.goPlus))
    }

    func testOfficialMeSubscriptionsListReadsPaidPlans() throws {
        let official = #"""
        {"id": 42, "plan": "Free", "subscriptions": [{"product": {"id": "consumer-high-tier", "name": "SoundCloud Go+"}, "recurring": true}]}
        """#
        XCTAssertEqual(try resolve(official), Resolution(.goPlus))
    }

    func testOfficialMeNeverInfersAnUnpaidPlan() throws {
        XCTAssertEqual(try resolve(#"{"plan": "Free", "subscriptions": []}"#), Resolution(.unknown, .payloadUnreadable))
        XCTAssertEqual(
            try resolve(#"{"plan": "Free", "subscriptions": [{"product": {"id": "free"}}]}"#),
            Resolution(.unknown, .payloadUnreadable)
        )
        XCTAssertEqual(
            try resolve(#"{"plan": "Pro Unlimited", "subscriptions": [{"product": {"id": "creator-pro-unlimited"}}]}"#),
            Resolution(.unknown, .payloadUnreadable)
        )
    }

    func testPlanNamesNeverDecideTheTier() throws {
        XCTAssertEqual(try resolve(#"{"plan": "consumer-high-tier"}"#), Resolution(.unknown, .payloadUnreadable))
        XCTAssertEqual(try resolve(#"{"subscription_plan": "Go+"}"#), Resolution(.unknown, .payloadUnreadable))
    }

    func testUnknownIDsNeverGuessUpward() throws {
        XCTAssertEqual(
            try resolve(#"{"consumer_subscription": {"product": {"id": "consumer-high-tier-expired"}}}"#),
            Resolution(.unknown, .unrecognisedProductIDs(["consumer-high-tier-expired"]))
        )
        XCTAssertEqual(
            try resolve(#"{"subscriptions": [{"product": {"id": "consumer-ultra"}}]}"#),
            Resolution(.unknown, .unrecognisedProductIDs(["consumer-ultra"]))
        )
        XCTAssertEqual(
            try resolve(#"{"consumer_subscription": {"product": {"id": " "}}}"#),
            Resolution(.unknown, .payloadUnreadable)
        )
    }

    func testOfficialPlanFillsInWhenTheV2BodyHasNone() throws {
        var signals = SubscriptionService.signals(from: try me())
        XCTAssertEqual(SubscriptionService.resolve(signals), Resolution(.unknown, .payloadUnreadable))
        signals.merge(SubscriptionService.signals(fromPayload: try capture(
            #"{"subscriptions": [{"product": {"id": "consumer-mid-tier"}}]}"#
        ).payload))
        XCTAssertEqual(SubscriptionService.resolve(signals), Resolution(.go))
    }

    func testCreatorPlansStillResolveFromTheirOwnKeys() throws {
        XCTAssertEqual(
            try resolve(#"{"creator_subscriptions": [{"product": {"id": "creator-pro-unlimited"}}]}"#),
            Resolution(.creatorPro)
        )
        XCTAssertEqual(
            try resolve(#"{"consumer_subscriptions": [], "creator_subscription": {"product": {"id": "creator-pro-unlimited"}}}"#),
            Resolution(.creatorPro)
        )
    }

    func testSubscriptionKeyMatching() {
        XCTAssertTrue(SoundCloudSubscriptionCapture.isSubscriptionKey("consumer_subscriptions"))
        XCTAssertTrue(SoundCloudSubscriptionCapture.isSubscriptionKey("subscriptions"))
        XCTAssertTrue(SoundCloudSubscriptionCapture.isSubscriptionKey("plan"))
        XCTAssertTrue(SoundCloudSubscriptionCapture.isSubscriptionKey("subscription_plan"))
        XCTAssertFalse(SoundCloudSubscriptionCapture.isSubscriptionKey("username"))
        XCTAssertFalse(SoundCloudSubscriptionCapture.isSubscriptionKey("playlist_count"))
    }

    func testCredentialShapedValuesStayRedactedInTheDiagnostic() throws {
        let description = SubscriptionService.rawSubscriptionDescription(
            for: try capture(#"{"consumer_subscription": {"product": {"id": "free"}, "token": "secret-value"}}"#),
            source: "api-v2 /me"
        )
        XCTAssertFalse(description.contains("secret-value"))
        XCTAssertTrue(description.contains("<redacted>"))
    }
}
