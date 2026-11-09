import Foundation
import XCTest
@testable import SoundingTV

@MainActor
final class TrackGateTests: XCTestCase {
    private typealias Tier = SubscriptionService.Tier

    private struct Account {
        let signedIn: Bool
        let tier: Tier
        let verification: SubscriptionService.VerificationStatus
    }

    private let signedOut = Account(signedIn: false, tier: .unknown, verification: .unverifiable(withinGrace: false))
    private let free = Account(signedIn: true, tier: .free, verification: .verifiedNotSubscribed)
    private let artist = Account(signedIn: true, tier: .creatorPro, verification: .verifiedNotSubscribed)
    private let go = Account(signedIn: true, tier: .go, verification: .verified)
    private let goPlus = Account(signedIn: true, tier: .goPlus, verification: .verified)
    private let dj = Account(signedIn: true, tier: .dj, verification: .verified)

    private static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    private func track(policy: String, monetization: String, snipped: Bool = false, quality: String = "sq") throws -> Track {
        let json = """
        {
            "id": 77, "title": "Fixture", "permalink_url": "https://soundcloud.com/example/77",
            "created_at": "2026-11-09T12:00:00Z", "monetization_model": "\(monetization)", "policy": "\(policy)",
            "user": { "id": 1, "username": "example", "permalink": "example", "permalink_url": "https://soundcloud.com/example" },
            "media": { "transcodings": [{
                "url": "https://api-v2.soundcloud.com/media/soundcloud:tracks:77/stream/hls",
                "preset": "aac_160k", "duration": \(snipped ? 30000 : 240000), "quality": "\(quality)", "snipped": \(snipped),
                "format": { "protocol": "hls", "mime_type": "audio/mp4; codecs=\\"mp4a.40.2\\"" }
            }] }
        }
        """
        return try Self.decoder.decode(Track.self, from: Data(json.utf8))
    }

    private func grant(_ track: Track, _ account: Account) -> SoundCloudPlaybackGrant {
        SoundCloudEntitlements.playbackGrant(for: track, signedIn: account.signedIn, tier: account.tier, verification: account.verification)
    }

    private func downloadDenial(_ track: Track, _ account: Account) -> SoundCloudEntitlementError? {
        SoundCloudEntitlements.trackDenial(for: track, feature: .downloads, signedIn: account.signedIn, tier: account.tier, verification: account.verification)
    }

    private func canDownload(_ track: Track, _ account: Account) -> Bool {
        SoundCloudEntitlements.canDownload(track, signedIn: account.signedIn, tier: account.tier, verification: account.verification)
    }

    func testFreeAccountStreamsAndDownloadsAllowTracks() throws {
        let allow = try track(policy: "ALLOW", monetization: "NOT_APPLICABLE")
        XCTAssertFalse(SoundCloudEntitlements.isGoRestricted(allow))
        for account in [free, artist] {
            XCTAssertEqual(grant(allow, account), .full)
            XCTAssertNil(downloadDenial(allow, account))
            XCTAssertTrue(canDownload(allow, account))
        }
    }

    func testFreeAccountMonetizedTracksFollowTheSwitch() throws {
        let monetized = try track(policy: "MONETIZE", monetization: "AD_SUPPORTED")
        if SoundCloudEntitlements.monetizedTracksOpen {
            XCTAssertFalse(SoundCloudEntitlements.isGoRestricted(monetized))
            XCTAssertEqual(grant(monetized, free), .full)
            XCTAssertTrue(canDownload(monetized, free))
        } else {
            XCTAssertTrue(SoundCloudEntitlements.isGoRestricted(monetized))
            XCTAssertEqual(grant(monetized, free), .denied(.needsGo(.monetizedTrack)))
            XCTAssertFalse(canDownload(monetized, free))
        }
        XCTAssertEqual(grant(monetized, go), .full)
        XCTAssertTrue(canDownload(monetized, go))
    }

    func testFreeAccountGetsPreviewsOfGoPlusTracksAndCannotDownloadThem() throws {
        let snippet = try track(policy: "SNIP", monetization: "SUB_HIGH_TIER", snipped: true)
        XCTAssertTrue(SoundCloudEntitlements.isGoRestricted(snippet))
        XCTAssertEqual(grant(snippet, free), .preview)
        XCTAssertFalse(canDownload(snippet, free))
        XCTAssertEqual(downloadDenial(snippet, free), .needsGoPlus(.goPlusTrack))

        let cachedFull = try track(policy: "ALLOW", monetization: "SUB_HIGH_TIER")
        XCTAssertTrue(SoundCloudEntitlements.isGoRestricted(cachedFull))
        XCTAssertEqual(grant(cachedFull, free), .denied(.needsGoPlus(.goPlusTrack)))
        XCTAssertEqual(downloadDenial(cachedFull, free), .needsGoPlus(.goPlusTrack))
        XCTAssertFalse(canDownload(cachedFull, free))
        XCTAssertTrue(SoundCloudEntitlementError.needsGoPlus(.goPlusTrack).offersSubscription)
    }

    func testSnipPolicyAloneIsGoRestricted() throws {
        let snip = try track(policy: "SNIP", monetization: "AD_SUPPORTED")
        XCTAssertTrue(SoundCloudEntitlements.isGoRestricted(snip))
        XCTAssertEqual(downloadDenial(snip, free), .needsGoPlus(.goPlusTrack))
        XCTAssertNil(downloadDenial(snip, goPlus))
    }

    func testGoAccountsAreUnchanged() throws {
        let allow = try track(policy: "ALLOW", monetization: "NOT_APPLICABLE")
        let goPlusFull = try track(policy: "ALLOW", monetization: "SUB_HIGH_TIER")
        let goPlusSnippet = try track(policy: "SNIP", monetization: "SUB_HIGH_TIER", snipped: true)
        XCTAssertEqual(grant(allow, go), .full)
        XCTAssertTrue(canDownload(allow, go))
        XCTAssertEqual(grant(goPlusFull, go), .denied(.needsGoPlus(.goPlusTrack)))
        XCTAssertFalse(canDownload(goPlusFull, go))
        XCTAssertEqual(grant(goPlusSnippet, go), .preview)
        for account in [goPlus, dj] {
            XCTAssertEqual(grant(allow, account), .full)
            XCTAssertEqual(grant(goPlusFull, account), .full)
            XCTAssertTrue(canDownload(goPlusFull, account))
            XCTAssertFalse(canDownload(goPlusSnippet, account))
        }
    }

    func testSignedOutIsUnchanged() throws {
        let allow = try track(policy: "ALLOW", monetization: "NOT_APPLICABLE")
        let snippet = try track(policy: "SNIP", monetization: "SUB_HIGH_TIER", snipped: true)
        XCTAssertEqual(grant(allow, signedOut), .denied(.signedOut(.playback)))
        XCTAssertEqual(downloadDenial(allow, signedOut), .signedOut(.downloads))
        XCTAssertFalse(canDownload(allow, signedOut))
        XCTAssertEqual(grant(snippet, signedOut), .preview)
        XCTAssertFalse(SoundCloudEntitlementError.signedOut(.downloads).offersSubscription)
    }

    func testDJGearStillNeedsGoPlusOnFree() {
        for feature: DJGearFeature in [.decks, .controllers, .prep] {
            XCTAssertEqual(
                SoundCloudEntitlements.djGearDenial(feature, isSoundCloudTrack: true, signedIn: true, tier: .free, verification: .verifiedNotSubscribed, personalUnlocked: false),
                .needsGoPlus(.djGear)
            )
        }
    }

    func testDownloadSourceUsesTheQualityTheAccountIsEntitledTo() throws {
        let hq = try track(policy: "ALLOW", monetization: "NOT_APPLICABLE", quality: "hq").transcodings[0]
        let sq = try track(policy: "ALLOW", monetization: "NOT_APPLICABLE").transcodings[0]
        XCTAssertFalse(DownloadSourceSelection.allowsHighQuality(for: .free))
        XCTAssertFalse(DownloadSourceSelection.allowsHighQuality(for: .go))
        XCTAssertTrue(DownloadSourceSelection.allowsHighQuality(for: .goPlus))
        XCTAssertEqual(DownloadSourceSelection.choose(from: [hq, sq], allowsHighQuality: false)?.transcoding.quality, "sq")
        XCTAssertEqual(DownloadSourceSelection.choose(from: [hq], allowsHighQuality: false)?.transcoding.quality, "hq")
    }
}
