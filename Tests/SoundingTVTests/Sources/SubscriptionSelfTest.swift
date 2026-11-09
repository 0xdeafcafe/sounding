import Foundation
import XCTest
@testable import SoundingTV

#if DEBUG

enum SubscriptionSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[SubscriptionTest] \(status)"] + lines.map { "[SubscriptionTest]   \($0)" }
                + failures.map { "[SubscriptionTest]   ✗ \($0)" }).joined(separator: "\n")
        }
    }

    static func run() -> Report {
        var report = Report()
        resolveTierCases(&report)
        resolveShapeCases(&report)
        creatorPlanCases(&report)
        unknownReasonCases(&report)
        rawDescriptionCases(&report)
        classifyCases(&report)
        return report
    }

    private static func sub(_ productId: String?) -> ConsumerSubscription {
        ConsumerSubscription(product: productId.map(SubscriptionProductRef.init(id:)))
    }

    private static func expectTier(
        _ report: inout Report,
        _ name: String,
        consumerRows: [ConsumerSubscription]? = nil,
        consumerSingle: ConsumerSubscription? = nil,
        creatorRows: [CreatorSubscription]? = nil,
        creatorSingle: CreatorSubscription? = nil,
        resolves tier: SubscriptionService.Tier
    ) {
        let got = SubscriptionService.resolve(
            consumerRows: consumerRows,
            consumerSingle: consumerSingle,
            creatorRows: creatorRows,
            creatorSingle: creatorSingle
        ).tier
        if got == tier {
            report.lines.append("resolve: \(name) → \(tier)")
        } else {
            report.failures.append("resolve: \(name): expected \(tier), got \(got)")
        }
    }

    private static func resolveTierCases(_ report: inout Report) {
        func expect(_ name: String, _ subscriptions: [ConsumerSubscription]?, resolves tier: SubscriptionService.Tier) {
            let got = SubscriptionService.resolveTier(from: subscriptions)
            if got == tier {
                report.lines.append("resolveTier: \(name) → \(tier)")
            } else {
                report.failures.append("resolveTier: \(name): expected \(tier), got \(got)")
            }
        }

        expect("missing key", nil, resolves: .unknown)
        expect("empty array", [], resolves: .free)
        expect("Go+", [sub("consumer-high-tier")], resolves: .goPlus)
        expect("Go", [sub("consumer-mid-tier")], resolves: .go)
        expect("Creator Pro filed under the consumer key", [sub("creator-pro")], resolves: .creatorPro)
        expect("explicit free product id", [sub("free")], resolves: .free)
        expect("unrecognised product id", [sub("consumer-ultra-mega-tier")], resolves: .unknown)
        expect("null product", [sub(nil)], resolves: .unknown)
        expect("Go+ wins over Go", [sub("consumer-mid-tier"), sub("consumer-high-tier")], resolves: .goPlus)
    }

    private static func resolveShapeCases(_ report: inout Report) {
        expectTier(
            &report, "singular key only (the captured Go+ shape)",
            consumerRows: nil, consumerSingle: sub("consumer-high-tier"),
            resolves: .goPlus
        )
        expectTier(
            &report, "singular Go only",
            consumerRows: nil, consumerSingle: sub("consumer-mid-tier"),
            resolves: .go
        )
        expectTier(
            &report, "plural null + singular free",
            consumerRows: nil, consumerSingle: sub("free"),
            resolves: .free
        )
        expectTier(
            &report, "plural empty but singular populated — singular still counts",
            consumerRows: [], consumerSingle: sub("consumer-high-tier"),
            resolves: .goPlus
        )
        expectTier(
            &report, "both spellings agree",
            consumerRows: [sub("consumer-high-tier")], consumerSingle: sub("consumer-high-tier"),
            resolves: .goPlus
        )
        expectTier(
            &report, "spellings disagree — higher privilege wins",
            consumerRows: [sub("free")], consumerSingle: sub("consumer-high-tier"),
            resolves: .goPlus
        )
        expectTier(
            &report, "truly empty consumer array stays authoritative free",
            consumerRows: [], consumerSingle: nil,
            resolves: .free
        )
    }

    private static func creatorPlanCases(_ report: inout Report) {
        expectTier(
            &report, "creator-pro-unlimited (Next Pro) via plural",
            creatorRows: [sub("creator-pro-unlimited")],
            resolves: .creatorPro
        )
        expectTier(
            &report, "creator-pro-unlimited via singular",
            creatorSingle: sub("creator-pro-unlimited"),
            resolves: .creatorPro
        )
        expectTier(
            &report, "creator-mid-tier (legacy Pro)",
            creatorRows: [sub("creator-mid-tier")],
            resolves: .creatorPro
        )
        expectTier(
            &report, "creator-creator-mid-tier (observed quirk)",
            creatorRows: [sub("creator-creator-mid-tier")],
            resolves: .creatorPro
        )
        expectTier(
            &report, "legacy creator-pro still recognised",
            creatorRows: [sub("creator-pro")],
            resolves: .creatorPro
        )
        expectTier(
            &report, "unseen future creator id caught by prefix (e.g. Artist Pro)",
            creatorRows: [sub("creator-artist-pro-2027")],
            resolves: .creatorPro
        )
        expectTier(
            &report, "free consumer + Next Pro creator → creatorPro, not goPlus",
            consumerRows: [sub("free")], creatorRows: [sub("creator-pro-unlimited")],
            resolves: .creatorPro
        )
        expectTier(
            &report, "Go+ consumer + creator plan → goPlus",
            consumerRows: [sub("consumer-high-tier")], creatorRows: [sub("creator-pro-unlimited")],
            resolves: .goPlus
        )
        expectTier(
            &report, "consumer- prefix must NOT promote to Go+",
            consumerRows: [sub("consumer-high-tier-expired")],
            resolves: .unknown
        )
        expectTier(
            &report, "creator- prefix must NOT promote to Go+",
            creatorRows: [sub("creator-high-tier")],
            resolves: .creatorPro
        )
    }

    private static func unknownReasonCases(_ report: inout Report) {
        func expect(
            _ name: String,
            consumerRows: [ConsumerSubscription]? = nil,
            consumerSingle: ConsumerSubscription? = nil,
            creatorRows: [CreatorSubscription]? = nil,
            reason: SubscriptionService.UnknownReason?
        ) {
            let got = SubscriptionService.resolve(
                consumerRows: consumerRows,
                consumerSingle: consumerSingle,
                creatorRows: creatorRows
            ).unknownReason
            if got == reason {
                report.lines.append("reason: \(name) → \(String(describing: got))")
            } else {
                report.failures.append(
                    "reason: \(name): expected \(String(describing: reason)), got \(String(describing: got))"
                )
            }
        }

        expect("all keys absent", reason: .payloadUnreadable)
        expect("row with null product", consumerRows: [sub(nil)], reason: .payloadUnreadable)
        expect(
            "unrecognised consumer id carries the id",
            consumerRows: [sub("consumer-ultra-mega-tier")],
            reason: .unrecognisedProductIDs(["consumer-ultra-mega-tier"])
        )
        expect(
            "unrecognised ids are sorted and de-duplicated",
            consumerRows: [sub("zeta-plan"), sub("alpha-plan"), sub("zeta-plan")],
            reason: .unrecognisedProductIDs(["alpha-plan", "zeta-plan"])
        )
        expect("recognised Go+ has no reason", consumerRows: [sub("consumer-high-tier")], reason: nil)
        expect("authoritative free has no reason", consumerRows: [], reason: nil)
    }

    private static func rawDescriptionCases(_ report: inout Report) {
        func expect(_ name: String, _ value: JSONValue, renders expected: String) {
            let got = value.diagnosticDescription
            if got == expected {
                report.lines.append("raw: \(name) → \(got)")
            } else {
                report.failures.append("raw: \(name): expected \(expected), got \(got)")
            }
        }

        expect("null", .null, renders: "null")
        expect("integer renders without decimal point", .number(3), renders: "3")
        expect(
            "the captured Go+ shape",
            .object(["product": .object(["id": .string("consumer-high-tier")])]),
            renders: "{product: {id: \"consumer-high-tier\"}}"
        )
        expect(
            "keys are sorted for stable comparison",
            .object(["z": .bool(true), "a": .bool(false)]),
            renders: "{a: false, z: true}"
        )
        expect(
            "an unmodelled sibling field survives into the diagnostic",
            .object([
                "product": .object(["id": .string("creator-pro-unlimited")]),
                "recurring": .bool(true),
            ]),
            renders: "{product: {id: \"creator-pro-unlimited\"}, recurring: true}"
        )
        expect(
            "credential-shaped keys are redacted",
            .object([
                "product": .object(["id": .string("free")]),
                "access_token": .string("would-be-a-leak"),
                "oauth_token": .string("would-be-a-leak"),
            ]),
            renders: "{access_token: <redacted>, oauth_token: <redacted>, product: {id: \"free\"}}"
        )
    }

    private static func classifyCases(_ report: inout Report) {
        let now = Date()
        let grace: TimeInterval = 10 * 24 * 3600

        func expect(
            _ name: String,
            lastTier: SubscriptionService.Tier?,
            lastVerifiedAt: Date?,
            latestAttempt: SubscriptionService.AttemptOutcome,
            expectTier: SubscriptionService.Tier,
            expectVerification: SubscriptionService.VerificationStatus
        ) {
            let (tier, verification) = SubscriptionService.classify(
                lastTier: lastTier,
                lastVerifiedAt: lastVerifiedAt,
                latestAttempt: latestAttempt,
                now: now,
                gracePeriod: grace
            )
            if tier == expectTier, verification == expectVerification {
                report.lines.append("classify: \(name) → \(tier)/\(verification)")
            } else {
                report.failures.append(
                    "classify: \(name): expected \(expectTier)/\(expectVerification), got \(tier)/\(verification)"
                )
            }
        }

        expect(
            "fresh Go+ read", lastTier: nil, lastVerifiedAt: nil,
            latestAttempt: .succeeded(.goPlus),
            expectTier: .goPlus, expectVerification: .verified
        )
        expect(
            "fresh free read", lastTier: nil, lastVerifiedAt: nil,
            latestAttempt: .succeeded(.free),
            expectTier: .free, expectVerification: .verifiedNotSubscribed
        )
        expect(
            "never attempted, nothing persisted", lastTier: nil, lastVerifiedAt: nil,
            latestAttempt: .notYetAttempted,
            expectTier: .unknown, expectVerification: .unverifiable(withinGrace: false)
        )
        expect(
            "failed attempt, recent Go+ on file → within grace", lastTier: .goPlus,
            lastVerifiedAt: now.addingTimeInterval(-3 * 24 * 3600),
            latestAttempt: .failed,
            expectTier: .goPlus, expectVerification: .unverifiable(withinGrace: true)
        )
        expect(
            "failed attempt, Go+ on file just past the grace boundary", lastTier: .goPlus,
            lastVerifiedAt: now.addingTimeInterval(-(grace + 1)),
            latestAttempt: .failed,
            expectTier: .goPlus, expectVerification: .unverifiable(withinGrace: false)
        )
        expect(
            "failed attempt, Go+ on file exactly at the grace boundary", lastTier: .goPlus,
            lastVerifiedAt: now.addingTimeInterval(-grace),
            latestAttempt: .failed,
            expectTier: .goPlus, expectVerification: .unverifiable(withinGrace: true)
        )
        expect(
            "failed attempt, free confirmed long ago stays confirmed", lastTier: .free,
            lastVerifiedAt: now.addingTimeInterval(-90 * 24 * 3600),
            latestAttempt: .failed,
            expectTier: .free, expectVerification: .verifiedNotSubscribed
        )
        expect(
            "ambiguous unknown-shape read doesn't overturn a recent Go+ read", lastTier: .goPlus,
            lastVerifiedAt: now.addingTimeInterval(-3600),
            latestAttempt: .succeeded(.unknown),
            expectTier: .goPlus, expectVerification: .unverifiable(withinGrace: true)
        )
    }
}

@MainActor
final class SoundCloudTierTests: XCTestCase {
    private typealias Tier = SubscriptionService.Tier

    private struct FixtureAccount {
        let signedIn: Bool
        let tier: Tier
        let verification: SubscriptionService.VerificationStatus
    }

    private let signedOut = FixtureAccount(signedIn: false, tier: .unknown, verification: .unverifiable(withinGrace: false))
    private let free = FixtureAccount(signedIn: true, tier: .free, verification: .verifiedNotSubscribed)
    private let artist = FixtureAccount(signedIn: true, tier: .creatorPro, verification: .verifiedNotSubscribed)
    private let go = FixtureAccount(signedIn: true, tier: .go, verification: .verified)
    private let goPlus = FixtureAccount(signedIn: true, tier: .goPlus, verification: .verified)
    private let dj = FixtureAccount(signedIn: true, tier: .dj, verification: .verified)
    private let unconfirmedWithinGrace = FixtureAccount(signedIn: true, tier: .goPlus, verification: .unverifiable(withinGrace: true))
    private let unconfirmedPastGrace = FixtureAccount(signedIn: true, tier: .goPlus, verification: .unverifiable(withinGrace: false))
    private let unknown = FixtureAccount(signedIn: true, tier: .unknown, verification: .unverifiable(withinGrace: false))

    private func denial(_ feature: SoundCloudFeature, _ account: FixtureAccount, gated: Bool = true) -> SoundCloudEntitlementError? {
        SoundCloudEntitlements.evaluate(feature, signedIn: account.signedIn, tier: account.tier, verification: account.verification, requiresSignIn: gated)
    }

    func testPlaybackGateNeedsSignInOnly() {
        XCTAssertTrue(SoundCloudEntitlements.requiresSignInForPlayback)
        XCTAssertNil(SoundCloudEntitlements.evaluate(.playback, signedIn: true, tier: .free, verification: .verifiedNotSubscribed))
        XCTAssertEqual(SoundCloudEntitlements.evaluate(.playback, signedIn: false, tier: .unknown, verification: .unverifiable(withinGrace: false)), .signedOut(.playback))
    }

    func testMonetizedTracksFollowTheSwitch() {
        for gated in [true, false] {
            if SoundCloudEntitlements.monetizedTracksOpen {
                XCTAssertNil(denial(.monetizedTrack, free, gated: gated))
                XCTAssertNil(denial(.monetizedTrack, artist, gated: gated))
            } else {
                XCTAssertEqual(denial(.monetizedTrack, free, gated: gated), .needsGo(.monetizedTrack))
            }
            XCTAssertEqual(denial(.monetizedTrack, signedOut, gated: gated), .signedOut(.monetizedTrack))
            XCTAssertNil(denial(.monetizedTrack, go, gated: gated))
            XCTAssertNil(denial(.monetizedTrack, goPlus, gated: gated))
        }
    }

    func testPlaybackWouldBeOpenWithTheSwitchOff() {
        for account in [signedOut, free, artist, unknown, unconfirmedPastGrace, go, goPlus, dj] {
            XCTAssertNil(denial(.playback, account, gated: false))
        }
        XCTAssertEqual(denial(.goPlusTrack, go, gated: false), .needsGoPlus(.goPlusTrack))
        XCTAssertEqual(denial(.goPlusTrack, free, gated: false), .needsGoPlus(.goPlusTrack))
        XCTAssertNil(denial(.goPlusTrack, signedOut, gated: false))
        XCTAssertNil(denial(.goPlusTrack, unknown, gated: false))
        XCTAssertNil(denial(.downloads, free, gated: false))
        XCTAssertEqual(denial(.downloads, signedOut, gated: false), .signedOut(.downloads))
        XCTAssertNil(denial(.downloads, go, gated: false))
    }

    func testSelfTestSuitePasses() {
        let report = SubscriptionSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }

    func testPlaybackNeedsASignedInAccount() {
        XCTAssertEqual(denial(.playback, signedOut), .signedOut(.playback))
        for account in [free, artist, unknown, go, goPlus, dj] {
            XCTAssertNil(denial(.playback, account))
        }
    }

    func testDownloadsNeedASignedInAccount() {
        XCTAssertEqual(denial(.downloads, signedOut), .signedOut(.downloads))
        for account in [free, artist, unknown, go, goPlus, dj] {
            XCTAssertNil(denial(.downloads, account))
        }
        XCTAssertEqual(SoundCloudEntitlementError.signedOut(.downloads).errorDescription, "Sign in to SoundCloud to download.")
    }

    func testGoPlusCatalogueNeedsGoPlus() {
        XCTAssertEqual(denial(.goPlusTrack, go), .needsGoPlus(.goPlusTrack))
        XCTAssertEqual(denial(.goPlusTrack, free), .needsGoPlus(.goPlusTrack))
        XCTAssertNil(denial(.goPlusTrack, goPlus))
        XCTAssertNil(denial(.goPlusTrack, dj))
    }

    private func djDenial(_ feature: DJGearFeature, _ account: FixtureAccount, soundCloud: Bool = true, unlocked: Bool = false) -> SoundCloudEntitlementError? {
        SoundCloudEntitlements.djGearDenial(
            feature, isSoundCloudTrack: soundCloud, signedIn: account.signedIn,
            tier: account.tier, verification: account.verification, personalUnlocked: unlocked
        )
    }

    func testDJGearAcrossEveryTierAndFeature() {
        let streamingFeatures: [DJGearFeature] = [.decks, .controllers, .prep]
        for feature in DJGearFeature.allCases {
            for account in [signedOut, free, artist, unknown, go, goPlus, dj, unconfirmedWithinGrace, unconfirmedPastGrace] {
                XCTAssertNil(djDenial(feature, account, soundCloud: false), "own music always allowed")
                XCTAssertNil(djDenial(feature, account, unlocked: true), "personal unlock allows everything")
            }
        }
        for feature in streamingFeatures {
            XCTAssertNil(djDenial(feature, goPlus))
            XCTAssertNil(djDenial(feature, dj))
            XCTAssertNil(djDenial(feature, unconfirmedWithinGrace))
            XCTAssertEqual(djDenial(feature, go), .needsGoPlus(.djGear))
            XCTAssertEqual(djDenial(feature, free), .needsGoPlus(.djGear))
            XCTAssertEqual(djDenial(feature, artist), .needsGoPlus(.djGear))
            XCTAssertEqual(djDenial(feature, signedOut), .signedOut(.djGear))
            XCTAssertEqual(djDenial(feature, unknown), .planUnconfirmed)
            XCTAssertEqual(djDenial(feature, unconfirmedPastGrace), .planUnconfirmed)
        }
        for account in [signedOut, free, artist, go, goPlus, dj] {
            XCTAssertEqual(djDenial(.usbExport, account), .ownMusicOnly)
        }
        XCTAssertEqual(SoundCloudEntitlementError.needsGoPlus(.djGear).errorDescription, "DJ decks need SoundCloud Go+ for SoundCloud tracks.")
        XCTAssertTrue(SoundCloudEntitlementError.needsGoPlus(.djGear).offersSubscription)
        XCTAssertFalse(SoundCloudEntitlementError.ownMusicOnly.offersSubscription)
    }

    func testUnconfirmedPlanFallsBackToFreeAfterGrace() {
        XCTAssertNil(denial(.goPlusTrack, unconfirmedWithinGrace))
        XCTAssertEqual(denial(.goPlusTrack, unconfirmedPastGrace), .planUnconfirmed)
        XCTAssertNil(denial(.playback, unconfirmedPastGrace))
        XCTAssertNil(denial(.downloads, unconfirmedPastGrace))
    }

    func testGoIsAPaidPlanForClassification() {
        let now = Date()
        let grace = SubscriptionService.gracePeriod
        let fresh = SubscriptionService.classify(lastTier: nil, lastVerifiedAt: nil, latestAttempt: .succeeded(.go), now: now, gracePeriod: grace)
        XCTAssertEqual(fresh.tier, .go)
        XCTAssertEqual(fresh.verification, .verified)
        let offline = SubscriptionService.classify(lastTier: .go, lastVerifiedAt: now.addingTimeInterval(-3600), latestAttempt: .failed, now: now, gracePeriod: grace)
        XCTAssertEqual(offline.tier, .go)
        XCTAssertEqual(offline.verification, .unverifiable(withinGrace: true))
        let lapsed = SubscriptionService.classify(lastTier: .goPlus, lastVerifiedAt: now, latestAttempt: .succeeded(.free), now: now, gracePeriod: grace)
        XCTAssertEqual(lapsed.verification, .verifiedNotSubscribed)
        XCTAssertNil(SoundCloudEntitlements.evaluate(.downloads, signedIn: true, tier: lapsed.tier, verification: lapsed.verification))
        XCTAssertEqual(SoundCloudEntitlements.evaluate(.goPlusTrack, signedIn: true, tier: lapsed.tier, verification: lapsed.verification), .needsGoPlus(.goPlusTrack))
    }

    func testDJProductResolves() {
        let plan = ConsumerSubscription(product: SubscriptionProductRef(id: "consumer-dj"))
        XCTAssertEqual(SubscriptionService.resolve(consumerRows: [plan]).tier, .dj)
    }

    func testLapsedDownloadsAreRemoved() {
        let now = Date()
        let day: TimeInterval = 24 * 3600
        func sweep(_ verification: SubscriptionService.VerificationStatus, since: TimeInterval?, confirmed: TimeInterval) -> DownloadEntitlementSweep {
            DownloadManager.entitlementSweep(
                verification: verification,
                notSubscribedSince: since.map { now.addingTimeInterval(-$0 * day) },
                lastConfirmedAt: now.addingTimeInterval(-confirmed * day),
                now: now
            )
        }
        XCTAssertEqual(sweep(.verified, since: nil, confirmed: 0), .removeRestricted)
        XCTAssertEqual(sweep(.verifiedNotSubscribed, since: 6, confirmed: 0), .keep)
        XCTAssertEqual(sweep(.verifiedNotSubscribed, since: 7, confirmed: 0), .removeRestricted)
        XCTAssertEqual(sweep(.verifiedNotSubscribed, since: 40, confirmed: 29), .removeRestricted)
        XCTAssertEqual(sweep(.verifiedNotSubscribed, since: 40, confirmed: 30), .removeAll)
        XCTAssertEqual(sweep(.unverifiable(withinGrace: false), since: nil, confirmed: 29), .keep)
        XCTAssertEqual(sweep(.unverifiable(withinGrace: false), since: nil, confirmed: 30), .removeAll)
    }

    private func decodeTrack(monetization: String, snippedOnly: Bool) throws -> Track {
        let json = """
        {
            "id": 42, "title": "Fixture", "permalink_url": "https://soundcloud.com/example/42",
            "created_at": "2024-09-01T12:00:00Z", "monetization_model": "\(monetization)",
            "user": { "id": 1, "username": "example", "permalink": "example", "permalink_url": "https://soundcloud.com/example" },
            "media": { "transcodings": [{
                "url": "https://api-v2.soundcloud.com/media/soundcloud:tracks:42/stream/progressive",
                "preset": "aac_160k", "duration": \(snippedOnly ? 30000 : 240000), "quality": "sq", "snipped": \(snippedOnly),
                "format": { "protocol": "progressive", "mime_type": "audio/mp4" }
            }] }
        }
        """
        return try Self.decoder.decode(Track.self, from: Data(json.utf8))
    }

    private static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(formatter)
        return encoder
    }()

    private func grant(_ track: Track, _ account: FixtureAccount) -> SoundCloudPlaybackGrant {
        SoundCloudEntitlements.playbackGrant(for: track, signedIn: account.signedIn, tier: account.tier, verification: account.verification)
    }

    func testSnippedOnlyTrackDecodesAsAPreview() throws {
        let preview = try decodeTrack(monetization: "SUB_HIGH_TIER", snippedOnly: true)
        XCTAssertTrue(preview.transcodings.isEmpty)
        XCTAssertEqual(preview.previewTranscodings.count, 1)
        XCTAssertTrue(preview.isPreviewOnly)
        XCTAssertNotNil(preview.streamURL)
        XCTAssertEqual(preview.previewDuration, 30)
        XCTAssertEqual(preview.duration, 30)
        XCTAssertTrue(preview.requiresGoPlus)
        let cached = try Self.decoder.decode(Track.self, from: try Self.encoder.encode(preview))
        XCTAssertEqual(cached.previewTranscodings.count, 1)
        XCTAssertTrue(cached.transcodings.isEmpty)
    }

    func testFreeAccountsPlaySnippedOnlyTracksAsPreviews() throws {
        let preview = try decodeTrack(monetization: "SUB_HIGH_TIER", snippedOnly: true)
        XCTAssertEqual(grant(preview, free), .preview)
        XCTAssertEqual(grant(preview, artist), .preview)
        XCTAssertEqual(grant(preview, signedOut), .preview)
        let ordinaryPreview = try decodeTrack(monetization: "AD_SUPPORTED", snippedOnly: true)
        XCTAssertEqual(grant(ordinaryPreview, free), .preview)
    }

    func testFreeAccountsPlayFullTracksThatAreNotGoRestricted() throws {
        let full = try decodeTrack(monetization: "AD_SUPPORTED", snippedOnly: false)
        XCTAssertEqual(grant(full, free), .full)
        XCTAssertEqual(grant(full, artist), .full)
        XCTAssertEqual(grant(full, signedOut), .denied(.signedOut(.playback)))
    }

    func testGoAccountsHearPreviewsOfGoPlusTracks() throws {
        let preview = try decodeTrack(monetization: "SUB_HIGH_TIER", snippedOnly: true)
        XCTAssertEqual(grant(preview, go), .preview)
        let fullGoPlus = try decodeTrack(monetization: "SUB_HIGH_TIER", snippedOnly: false)
        XCTAssertEqual(grant(fullGoPlus, go), .denied(.needsGoPlus(.goPlusTrack)))
        XCTAssertEqual(SoundCloudEntitlements.previewDenial(for: preview, tier: .go), .previewOnly(needsGoPlus: true))
        XCTAssertEqual(SoundCloudEntitlementError.previewOnly(needsGoPlus: true).errorDescription, "Full track needs SoundCloud Go+.")
    }

    func testGoPlusPlaysTheFullTrack() throws {
        let full = try decodeTrack(monetization: "SUB_HIGH_TIER", snippedOnly: false)
        XCTAssertEqual(grant(full, goPlus), .full)
        XCTAssertEqual(grant(full, dj), .full)
        let ordinary = try decodeTrack(monetization: "AD_SUPPORTED", snippedOnly: false)
        XCTAssertEqual(grant(ordinary, go), .full)
    }

    func testPreviewEndedCopyFollowsTheTier() throws {
        let ordinaryPreview = try decodeTrack(monetization: "AD_SUPPORTED", snippedOnly: true)
        XCTAssertEqual(SoundCloudEntitlements.previewDenial(for: ordinaryPreview, tier: .free), .previewOnly(needsGoPlus: true))
        XCTAssertEqual(SoundCloudEntitlementError.previewOnly(needsGoPlus: false).errorDescription, "Full track needs SoundCloud Go or Go+.")
        XCTAssertTrue(SoundCloudEntitlementError.previewOnly(needsGoPlus: true).offersSubscription)
    }

    func testAutoMixNeverBlendsIntoOrOutOfAPreview() throws {
        let preview = try decodeTrack(monetization: "SUB_HIGH_TIER", snippedOnly: true)
        let full = try decodeTrack(monetization: "AD_SUPPORTED", snippedOnly: false)
        let freeGrant: (Track) -> SoundCloudPlaybackGrant = { self.grant($0, self.free) }
        let goGrant: (Track) -> SoundCloudPlaybackGrant = { self.grant($0, self.go) }
        XCTAssertNil(SoundCloudEntitlements.blendableNext(after: full, next: preview, grant: goGrant))
        XCTAssertNil(SoundCloudEntitlements.blendableNext(after: preview, next: full, grant: goGrant))
        XCTAssertNil(SoundCloudEntitlements.blendableNext(after: preview, next: preview, grant: freeGrant))
        XCTAssertEqual(SoundCloudEntitlements.blendableNext(after: full, next: full, grant: goGrant)?.id, full.id)
    }

    func testGoPlusTrackNeedsGoPlusEvenWhenCached() throws {
        let full = try decodeTrack(monetization: "SUB_HIGH_TIER", snippedOnly: false)
        XCTAssertFalse(full.transcodings.isEmpty)
        XCTAssertEqual(SoundCloudEntitlements.features(for: full, base: .playback), [.playback, .goPlusTrack])
        let cached = try Self.decoder.decode(Track.self, from: try Self.encoder.encode(full))
        XCTAssertTrue(cached.requiresGoPlus)
        let ordinary = try decodeTrack(monetization: "AD_SUPPORTED", snippedOnly: false)
        XCTAssertEqual(SoundCloudEntitlements.features(for: ordinary, base: .playback), [.playback])
    }
}

@MainActor
final class PromotedFeedTests: XCTestCase {
    private actor RecordingTransport: PromotedTrackingTransport {
        private(set) var sent: [URL] = []
        func send(_ url: URL, event: PromotedContent.Event) async { sent.append(url) }
    }

    private static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    private static let promotedJSON = """
    {
        "type": "track-promoted", "created_at": "2026-11-08T12:00:00Z", "uuid": "promo-1",
        "promoter": { "id": 9, "username": "Label Records", "permalink": "label", "permalink_url": "https://soundcloud.com/label" },
        "promoted": {
            "ad_urn": "dfp:ads:123",
            "tracking": {
                "impression": ["https://promoted.example.com/imp?a=1", "http://insecure.example.com/imp"],
                "track_played": "https://promoted.example.com/play",
                "track_clicked": ["https://promoted.example.com/click"]
            }
        },
        "track": {
            "id": 42, "title": "Fixture", "permalink_url": "https://soundcloud.com/example/42",
            "created_at": "2024-09-01T12:00:00Z", "policy": "MONETIZE", "monetization_model": "AD_SUPPORTED",
            "user": { "id": 1, "username": "example", "permalink": "example", "permalink_url": "https://soundcloud.com/example" },
            "media": { "transcodings": [{
                "url": "https://api-v2.soundcloud.com/media/soundcloud:tracks:42/stream/progressive",
                "preset": "aac_160k", "duration": 240000, "quality": "sq", "snipped": false,
                "format": { "protocol": "progressive", "mime_type": "audio/mp4" }
            }] }
        }
    }
    """

    private func activity() throws -> FeedActivity {
        try Self.decoder.decode(FeedActivity.self, from: Data(Self.promotedJSON.utf8))
    }

    func testPromotedItemsDecodeWithLabelAndTracking() throws {
        let item = try activity()
        XCTAssertEqual(item.kind, .trackPromoted)
        XCTAssertTrue(item.isPromoted)
        XCTAssertEqual(item.promotedLabel, "Promoted by Label Records")
        XCTAssertEqual(item.promoted?.adURN, "dfp:ads:123")
        XCTAssertEqual(item.promoted?.urls(for: .impression), [URL(string: "https://promoted.example.com/imp?a=1")!])
        XCTAssertEqual(item.promoted?.urls(for: .play), [URL(string: "https://promoted.example.com/play")!])
        XCTAssertEqual(item.promoted?.urls(for: .click), [URL(string: "https://promoted.example.com/click")!])
        XCTAssertTrue(item.track?.isMonetized == true)
        XCTAssertEqual(SoundCloudEntitlements.features(for: item.track!, base: .playback), [.playback, .monetizedTrack])
    }

    func testPromotedItemsSurviveTheFeedCache() throws {
        let item = try activity()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(formatter)
        let cached = try Self.decoder.decode(FeedActivity.self, from: try encoder.encode(item))
        XCTAssertEqual(cached.promoted, item.promoted)
        XCTAssertEqual(cached.promotedLabel, item.promotedLabel)
    }

    func testEachEventFiresOncePerItem() async throws {
        let transport = RecordingTransport()
        let tracking = PromotedTracking(transport: transport, isSuppressed: { false }, trafficAllowed: { true })
        let item = try activity()
        XCTAssertEqual(tracking.record(.impression, for: item).count, 1)
        XCTAssertTrue(tracking.record(.impression, for: item).isEmpty)
        XCTAssertEqual(tracking.record(.play, for: item).count, 1)
        XCTAssertTrue(tracking.record(.play, for: item).isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        let sent = await transport.sent
        XCTAssertEqual(Set(sent), [URL(string: "https://promoted.example.com/imp?a=1")!, URL(string: "https://promoted.example.com/play")!])
        XCTAssertEqual(sent.count, 2)
    }

    func testNothingFiresWhenSuppressedOrRateLimited() async throws {
        let transport = RecordingTransport()
        let item = try activity()
        let suppressed = PromotedTracking(transport: transport, isSuppressed: { true }, trafficAllowed: { true })
        XCTAssertTrue(suppressed.record(.impression, for: item).isEmpty)
        let stopped = PromotedTracking(transport: transport, isSuppressed: { false }, trafficAllowed: { false })
        XCTAssertTrue(stopped.record(.play, for: item).isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        let sent = await transport.sent
        XCTAssertTrue(sent.isEmpty)
    }

    func testOrdinaryItemsNeverFire() async throws {
        let transport = RecordingTransport()
        let tracking = PromotedTracking(transport: transport, isSuppressed: { false }, trafficAllowed: { true })
        let plain = try Self.decoder.decode(
            FeedActivity.self,
            from: Data(Self.promotedJSON.replacingOccurrences(of: "track-promoted", with: "track").replacingOccurrences(of: "\"promoted\": {", with: "\"unused\": {").utf8)
        )
        XCTAssertFalse(plain.isPromoted)
        XCTAssertTrue(tracking.record(.impression, for: plain).isEmpty)
    }

    func testTestRunsAreSuppressedByDefault() {
        XCTAssertTrue(PromotedTracking.isSuppressedEnvironment)
    }
}
#endif
