import Foundation
import XCTest
@testable import SoundingTV

final class FairPlayTranscodingTests: XCTestCase {
    private static func entry(_ preset: String, _ proto: String, _ mime: String, quality: String = "sq") -> String {
        """
        {
            "url": "https://api-v2.soundcloud.com/media/soundcloud:tracks:7/\(preset)/\(proto)",
            "preset": "\(preset)",
            "duration": 240000,
            "quality": "\(quality)",
            "snipped": false,
            "format": { "protocol": "\(proto)", "mime_type": "\(mime)" }
        }
        """
    }

    private static func track(_ transcodings: [String]) throws -> Track {
        let json = """
        {
            "id": 7,
            "title": "Icebox",
            "permalink_url": "https://soundcloud.com/maren/icebox",
            "created_at": 1756728000000,
            "monetization_model": "SUB_HIGH_TIER",
            "user": { "id": 1, "username": "maren", "permalink": "maren", "permalink_url": "https://soundcloud.com/maren" },
            "media": { "transcodings": [\(transcodings.joined(separator: ","))] }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Track.self, from: Data(json.utf8))
    }

    private static let aac = "audio/mp4; codecs=\\\"mp4a.40.2\\\""

    private static let goPlusLadder: [String] = [
        entry("aac_256k", "cbc-encrypted-hls", aac, quality: "hq"),
        entry("aac_256k", "ctr-encrypted-hls", aac, quality: "hq"),
        entry("aac_160k", "cbc-encrypted-hls", aac),
        entry("aac_160k", "ctr-encrypted-hls", aac),
        entry("aac_96k", "cbc-encrypted-hls", aac),
        entry("aac_96k", "ctr-encrypted-hls", aac),
        entry("abr_hq", "cbc-encrypted-hls", "audio/mpegurl", quality: "hq"),
        entry("abr_hq", "ctr-encrypted-hls", "audio/mpegurl", quality: "hq"),
        entry("abr_sq", "cbc-encrypted-hls", "audio/mpegurl"),
        entry("abr_sq", "ctr-encrypted-hls", "audio/mpegurl"),
    ]

    func testEncryptedOnlyLadderPicksFairPlayAndDropsWidevine() throws {
        let track = try Self.track(Self.goPlusLadder)
        XCTAssertEqual(track.transcodings.count, 5)
        XCTAssertFalse(track.transcodings.contains { $0.isWidevine })
        XCTAssertTrue(track.transcodings.allSatisfy(\.isFairPlay))
        XCTAssertTrue(track.needsFairPlay)
        XCTAssertTrue(track.hasFullAudio)
        XCTAssertNil(track.mixSource)
        XCTAssertNil(track.bestDecodableTranscoding)
        let best = try XCTUnwrap(track.transcodings.max { $0.playbackRank < $1.playbackRank })
        XCTAssertEqual(best.preset, "aac_256k")
        XCTAssertEqual(best.format.protocol, "cbc-encrypted-hls")
        XCTAssertEqual(track.streamURL, best.url)
        XCTAssertNil(DownloadSourceSelection.choose(from: track.transcodings))
    }

    func testUnencryptedBeatsHigherBitrateEncrypted() throws {
        let track = try Self.track(Self.goPlusLadder + [
            Self.entry("mp3_1_0", "hls", "audio/mpeg"),
            Self.entry("mp3_1_0", "progressive", "audio/mpeg"),
        ])
        XCTAssertFalse(track.needsFairPlay)
        let best = try XCTUnwrap(track.transcodings.max { $0.playbackRank < $1.playbackRank })
        XCTAssertEqual(best.preset, "mp3_1_0")
        XCTAssertEqual(best.format.protocol, "progressive")
        XCTAssertEqual(track.streamURL, best.url)
        XCTAssertEqual(track.mixSource?.format.protocol, "progressive")
        XCTAssertEqual(track.decodableTranscodings.count, 2)
        XCTAssertEqual(QualityCeiling.maximum.bestTranscoding(among: track.transcodings)?.isEncrypted, false)
        XCTAssertEqual(DownloadSourceSelection.choose(from: track.transcodings)?.transcoding.preset, "mp3_1_0")
    }

    func testPlainHLSBeatsEncryptedHLSOfTheSameCodec() throws {
        let track = try Self.track([
            Self.entry("aac_256k", "cbc-encrypted-hls", Self.aac, quality: "hq"),
            Self.entry("aac_160k", "hls", Self.aac),
        ])
        let best = try XCTUnwrap(track.transcodings.max { $0.playbackRank < $1.playbackRank })
        XCTAssertEqual(best.preset, "aac_160k")
        XCTAssertFalse(best.isEncrypted)
    }

    func testWidevineOnlyTrackHasNoPlayableAudio() throws {
        let track = try Self.track([Self.entry("aac_160k", "ctr-encrypted-hls", Self.aac)])
        XCTAssertTrue(track.transcodings.isEmpty)
        XCTAssertNil(track.streamURL)
        XCTAssertFalse(track.needsFairPlay)
    }

    func testRoundTripKeepsFairPlayAndDropsWidevine() throws {
        let track = try Self.track(Self.goPlusLadder)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let restored = try decoder.decode(Track.self, from: encoder.encode(track))
        XCTAssertEqual(restored.transcodings.count, 5)
        XCTAssertTrue(restored.needsFairPlay)
    }

    func testKeyIdentifierAndLicenceEncoding() {
        XCTAssertEqual(FairPlayKeyDelivery.assetID(fromKeyIdentifier: "skd://abc-123"), "abc-123")
        XCTAssertNil(FairPlayKeyDelivery.assetID(fromKeyIdentifier: "skd://"))
        XCTAssertNil(FairPlayKeyDelivery.assetID(fromKeyIdentifier: nil))
    }

    @MainActor
    func testLicenceServerEncodingHelpers() {
        XCTAssertEqual(FairPlayLicenceServer.formEncoded("a+b/c=d.e-f_g"), "a%2Bb%2Fc%3Dd.e-f_g")
        let ckc = Data([0x01, 0x02, 0x03, 0xFF])
        XCTAssertEqual(FairPlayLicenceServer.decodeLicence(Data((ckc.base64EncodedString() + "\n").utf8)), ckc)
        XCTAssertNil(FairPlayLicenceServer.decodeLicence(Data("not base64!".utf8)))
        let der = Data([0x30, 0x82, 0x01, 0x00])
        XCTAssertEqual(FairPlayLicenceServer.decodeCertificate(der), der)
        XCTAssertEqual(FairPlayLicenceServer.decodeCertificate(Data(der.base64EncodedString().utf8)), der)
    }

    func testLicenceRefusalMapsToGoPlusEntitlement() {
        XCTAssertEqual(FairPlayLicenceError.licenceRefused(status: 403).entitlementError, .needsGoPlus(.goPlusTrack))
        XCTAssertEqual(FairPlayLicenceError.licenceRefused(status: 401).entitlementError, .needsGoPlus(.goPlusTrack))
        XCTAssertNil(FairPlayLicenceError.licenceRefused(status: 500).entitlementError)
        XCTAssertNil(FairPlayLicenceError.rateLimited.entitlementError)
    }
}
