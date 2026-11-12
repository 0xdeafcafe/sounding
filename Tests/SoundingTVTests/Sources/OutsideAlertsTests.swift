import CloudKit
import XCTest
@testable import SoundingTV

final class OutsideAlertsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Subscriptions

    func testEveryAlertAsksForFiveFieldsAtMost() {
        let visible = OutsideAlertSubscription.all.filter(\.isVisible)
        XCTAssertEqual(visible.count, 3)
        XCTAssertLessThanOrEqual(OutsideAlertSubscription.maximumDesiredKeys, 5)
        for subscription in visible {
            XCTAssertFalse(subscription.desiredKeys.isEmpty, subscription.id)
            XCTAssertLessThanOrEqual(subscription.desiredKeys.count, OutsideAlertSubscription.maximumDesiredKeys, subscription.id)
            XCTAssertEqual(Set(subscription.desiredKeys).count, subscription.desiredKeys.count, subscription.id)
        }
    }

    func testAlertsCarryTheirLocalizationArgsAndCollapseKey() {
        for subscription in OutsideAlertSubscription.all where subscription.isVisible {
            let keys = Set(subscription.desiredKeys)
            for argument in subscription.titleArgs + subscription.alertArgs {
                XCTAssertTrue(keys.contains(argument), "\(subscription.id) is missing \(argument)")
            }
            guard let collapse = subscription.collapseIDKey else {
                XCTFail("\(subscription.id) has no collapse key")
                continue
            }
            XCTAssertTrue(keys.contains(collapse), "\(subscription.id) is missing \(collapse)")
            XCTAssertNotNil(subscription.category, subscription.id)
        }
    }

    func testAlertsAskOnlyForTheirRecordsFields() {
        let fields: [String: [String]] = [
            SignInRequest.recordType: SignInRequest.Field.all,
            NearbyLinkRequest.recordType: NearbyLinkRequest.Field.all,
            AccountSignIn.recordType: AccountSignIn.Field.all,
        ]
        for subscription in OutsideAlertSubscription.all {
            let known = Set(fields[subscription.recordType] ?? [])
            XCTAssertTrue(Set(subscription.desiredKeys).isSubset(of: known), subscription.id)
        }
    }

    func testNotificationServiceGetsWhatItRenders() {
        XCTAssertTrue(Set(SignInRequest.Field.notified).isSuperset(of: ["tvName", "tvKind", "tvTag", "createdAt"]))
        XCTAssertTrue(Set(NearbyLinkRequest.Field.notified).isSuperset(of: ["tvName", "tvKind", "tvTag", "expiresAt"]))
        XCTAssertTrue(Set(AccountSignIn.Field.notified).isSuperset(of: ["deviceName", "collapse"]))
    }

    func testSignInRequestsCollapsePerTV() {
        let subscription = OutsideAlertSubscription.all.first { $0.id == SignInRequest.subscriptionID }
        XCTAssertEqual(subscription?.collapseIDKey, SignInRequest.Field.tvTag)
        XCTAssertEqual(SignInRequest.tvTag(deviceId: "TV-1"), SignInRequest.tvTag(deviceId: "tv-1"))
        XCTAssertNotEqual(SignInRequest.tvTag(deviceId: "TV-1"), SignInRequest.tvTag(deviceId: "TV-2"))
        XCTAssertNotEqual(SignInRequest.tvTag(deviceId: "TV-1"), NearbyLinkRequest.tvTag(deviceId: "TV-1"))
    }

    func testSilentSubscriptionsAskForNothing() {
        let silent = OutsideAlertSubscription.all.filter { !$0.isVisible }
        XCTAssertEqual(silent.count, 2)
        for subscription in silent {
            XCTAssertEqual(subscription.trigger, .deletion)
            XCTAssertTrue(subscription.desiredKeys.isEmpty)
            XCTAssertNil(subscription.collapseIDKey)
        }
    }

    func testRefusedSubscriptionsAreRetiredAndReplaced() {
        let ids = OutsideAlertSubscription.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(Set(ids).isDisjoint(with: OutsideAlertSubscription.retiredIDs))
        XCTAssertTrue(OutsideAlertSubscription.retiredIDs.isSuperset(of: ["nearby-link-requests-v1", "account-signins-v2", "signin-requests-v2"]))
        XCTAssertTrue(NearbyLinkRequest.subscriptionIDs.contains(NearbyLinkRequest.subscriptionID))
        XCTAssertTrue(AccountSignIn.subscriptionIDs.contains(AccountSignIn.subscriptionID))
        XCTAssertTrue(SignInRequest.subscriptionIDs.contains(SignInRequest.subscriptionID))
    }

    func testSignInRequestKeepsItsTVTag() {
        let request = SignInRequest(rendezvous: String(repeating: "a1", count: 16), tvName: "Living Room", tvTag: "abc", createdAt: start)
        XCTAssertEqual(request.flatMap { SignInRequest(record: $0.record()) }, request)
        XCTAssertEqual(SignInRequest(fields: ["rendezvous": String(repeating: "a1", count: 16), "tvName": "Living Room", "createdAt": start])?.expiresAt, start.addingTimeInterval(SignInRequest.lifetime))
    }

    // MARK: - Sweep

    private func alert(
        _ id: String,
        kind: DeliveredOutsideAlert.Kind = .signInRequest,
        device: String? = "tv|living room",
        createdAt: Date? = nil,
        expiresAt: Date? = nil,
        deliveredAt: Date? = nil
    ) -> DeliveredOutsideAlert {
        DeliveredOutsideAlert(
            id: id,
            kind: kind,
            recordName: "record-\(id)",
            device: device,
            createdAt: createdAt ?? start,
            expiresAt: expiresAt ?? start.addingTimeInterval(600),
            deliveredAt: deliveredAt ?? createdAt ?? start
        )
    }

    func testExpiredAlertsAreStale() {
        let alerts = [alert("a"), alert("b", kind: .nearbyLink, device: "tv|den")]
        XCTAssertTrue(OutsideAlertSweep.stale(alerts, now: start.addingTimeInterval(60)).isEmpty)
        XCTAssertEqual(OutsideAlertSweep.stale(alerts, now: start.addingTimeInterval(600)), ["a", "b"])
        XCTAssertFalse(OutsideAlertSweep.needsRecord(alerts[0], now: start.addingTimeInterval(600), resolvedDevices: []))
    }

    func testNewSignInsGoStaleAfterADay() {
        let signIn = alert("a", kind: .accountSignIn, device: nil, expiresAt: .distantFuture)
        XCTAssertTrue(OutsideAlertSweep.stale([signIn], now: start.addingTimeInterval(3_600)).isEmpty)
        XCTAssertEqual(OutsideAlertSweep.stale([signIn], now: start.addingTimeInterval(AccountSignIn.freshness + 1)), ["a"])
    }

    func testSignedInOrLinkedTVsClearTheirAlerts() {
        let alerts = [alert("a"), alert("b", kind: .nearbyLink), alert("c", device: "tv|den")]
        let stale = OutsideAlertSweep.stale(alerts, now: start, resolvedDevices: ["tv|living room"])
        XCTAssertEqual(stale, ["a", "b"])
        XCTAssertFalse(OutsideAlertSweep.needsRecord(alerts[0], now: start, resolvedDevices: ["tv|living room"]))
        XCTAssertTrue(OutsideAlertSweep.needsRecord(alerts[2], now: start, resolvedDevices: ["tv|living room"]))
    }

    func testWithdrawnOrResolvedRecordsClearTheirAlerts() {
        let alerts = [alert("a", device: "tv|a"), alert("b", device: "tv|b"), alert("c", device: "tv|c"), alert("d", device: "tv|d")]
        let records: [String: OutsideAlertSweep.RecordState] = ["record-a": .gone, "record-b": .resolved, "record-c": .live]
        XCTAssertEqual(OutsideAlertSweep.stale(alerts, now: start, records: records), ["a", "b"])
    }

    func testOneAlertPerTV() {
        let alerts = [
            alert("old", createdAt: start),
            alert("new", createdAt: start.addingTimeInterval(120)),
            alert("middle", createdAt: start.addingTimeInterval(60)),
            alert("other", device: "tv|den"),
            alert("link", kind: .nearbyLink),
        ]
        XCTAssertEqual(OutsideAlertSweep.stale(alerts, now: start.addingTimeInterval(130)), ["old", "middle"])
    }

    func testTheNewestLiveAlertSurvivesWhenTheNewestIsGone() {
        let alerts = [alert("old", createdAt: start), alert("new", createdAt: start.addingTimeInterval(120))]
        let stale = OutsideAlertSweep.stale(alerts, now: start.addingTimeInterval(130), records: ["record-new": .gone])
        XCTAssertEqual(stale, ["new"])
    }

    func testNewSignInsAreNeverMergedPerDevice() {
        let alerts = [
            alert("a", kind: .accountSignIn, device: "tv|living room", expiresAt: .distantFuture),
            alert("b", kind: .accountSignIn, device: "tv|living room", createdAt: start.addingTimeInterval(60), expiresAt: .distantFuture),
        ]
        XCTAssertTrue(OutsideAlertSweep.stale(alerts, now: start.addingTimeInterval(120), resolvedDevices: ["tv|living room"]).isEmpty)
    }

    func testDeviceIdentityMatchesLinkedIdentity() {
        XCTAssertEqual(OutsideAlertSweep.device(name: " Living Room ", kind: .tv), SameAccountLinkOffer.identity(name: "living room", kind: .tv))
        XCTAssertNil(OutsideAlertSweep.device(name: nil, kind: .tv))
        XCTAssertNil(OutsideAlertSweep.device(name: "", kind: .tv))
    }

    // MARK: - TV publishing

    func testTVAsksAtMostOncePerTenMinutesUnlessTheUserStartsIt() {
        XCTAssertTrue(SignInRequestPublisher.mayPublish(now: start, lastPublishedAt: nil, userStarted: false))
        XCTAssertFalse(SignInRequestPublisher.mayPublish(now: start.addingTimeInterval(60), lastPublishedAt: start, userStarted: false))
        XCTAssertTrue(SignInRequestPublisher.mayPublish(now: start.addingTimeInterval(60), lastPublishedAt: start, userStarted: true))
        XCTAssertTrue(SignInRequestPublisher.mayPublish(now: start.addingTimeInterval(600), lastPublishedAt: start, userStarted: false))
        XCTAssertTrue(SignInRequestPublisher.mayPublish(now: start.addingTimeInterval(-60), lastPublishedAt: start, userStarted: false))
    }
}
