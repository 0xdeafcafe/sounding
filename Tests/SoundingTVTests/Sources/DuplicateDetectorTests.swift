import Foundation
import XCTest
@testable import SoundingTV

final class DuplicateDetectorTests: XCTestCase {
    private func candidate(
        _ id: String,
        _ title: String,
        by artist: String,
        uploader: String? = nil,
        seconds: TimeInterval,
        source: DuplicateCandidate.Source = .stream,
        bitrate: Int = 128,
        bpm: Double? = nil,
        key: CamelotKey? = nil,
        hasCues: Bool = false,
        filePath: String? = nil,
        contentHash: String? = nil
    ) -> DuplicateCandidate {
        DuplicateCandidate(
            id: id,
            title: title,
            artist: artist,
            alternateArtists: uploader.map { [$0] } ?? [],
            duration: seconds,
            source: source,
            bitrate: bitrate,
            bpm: bpm,
            key: key,
            hasCues: hasCues,
            filePath: filePath,
            contentHash: contentHash
        )
    }

    func testParseStripsPremiereOriginalMixAndFreeDownload() {
        let parsed = DuplicateDetector.parse(title: "PREMIERE: Bicep - Glue (Original Mix) [Free DL]", artist: "Mixmag")
        XCTAssertEqual(parsed.artist, "bicep")
        XCTAssertEqual(parsed.title, "glue")
        XCTAssertEqual(parsed.version, "")
    }

    func testParseNormalisesMixNames() {
        XCTAssertEqual(DuplicateDetector.parse(title: "Glue - Extended Mix", artist: "Bicep").version, "extended")
        XCTAssertEqual(DuplicateDetector.parse(title: "Glue (Extended Version)", artist: "Bicep").version, "extended")
        XCTAssertEqual(DuplicateDetector.parse(title: "Glue (Radio Edit)", artist: "Bicep").version, "radio edit")
        XCTAssertEqual(DuplicateDetector.parse(title: "Opus (Four Tet Remix)", artist: "Eric Prydz").version, "four tet remix")
        XCTAssertNil(DuplicateDetector.parse(title: "Glue - Extended Mix", artist: "Bicep").artist)
    }

    func testOwnFileMatchesLabelUploadThatNamesTheArtist() {
        let local = candidate("-101", "Glue (Original Mix)", by: "Bicep", seconds: 269, source: .localLossless, bitrate: 900)
        let label = candidate("2001", "Bicep - Glue [Free Download]", by: "Ninja Tune", uploader: "ninja-tune", seconds: 270)
        let groups = DuplicateDetector.groups(in: [local, label])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.keeperID, "-101")
        XCTAssertEqual(groups.first?.confidence, .likely)
    }

    func testExtendedRadioEditAndOriginalStayDistinct() {
        let groups = DuplicateDetector.groups(in: [
            candidate("1", "Glue (Extended Mix)", by: "Bicep", seconds: 300),
            candidate("2", "Glue (Radio Edit)", by: "Bicep", seconds: 300),
            candidate("3", "Glue", by: "Bicep", seconds: 300),
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    func testRemixesVipsAndLiveVersionsStayDistinct() {
        let groups = DuplicateDetector.groups(in: [
            candidate("1", "Opus (Four Tet Remix)", by: "Eric Prydz", seconds: 540),
            candidate("2", "Opus (Eric Prydz VIP)", by: "Eric Prydz", seconds: 540),
            candidate("3", "Opus - Live at Printworks", by: "Eric Prydz", seconds: 540),
            candidate("4", "Opus", by: "Eric Prydz", seconds: 540),
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    func testFeaturedCreditsCaseAndDiacriticsAreIgnored() {
        let rumble = DuplicateDetector.groups(in: [
            candidate("1", "Rumble (feat. Flowdan)", by: "Skrillex & Fred again..", seconds: 225),
            candidate("2", "RUMBLE ft. Flowdan", by: "Fred again..", seconds: 226),
        ])
        XCTAssertEqual(rumble.count, 1)

        let cafe = DuplicateDetector.groups(in: [
            candidate("3", "Café Del Mar", by: "Energy 52", seconds: 446),
            candidate("4", "Cafe del Mar (Original Mix)", by: "Energy 52", seconds: 445),
        ])
        XCTAssertEqual(cafe.count, 1)
    }

    func testDifferentArtistsOnOneLabelStayDistinct() {
        let groups = DuplicateDetector.groups(in: [
            candidate("1", "Four Tet - Baby", by: "Text Records", uploader: "textrecords", seconds: 301),
            candidate("2", "Caribou - Baby", by: "Text Records", uploader: "textrecords", seconds: 301),
            candidate("-3", "Baby", by: "Four Tet", seconds: 300, source: .localFile),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.memberIDs, ["1", "-3"])
    }

    func testDurationsMoreThanTwoSecondsApartAreNotDuplicates() {
        let groups = DuplicateDetector.groups(in: [
            candidate("1", "Strings of Life", by: "Rhythim Is Rhythim", seconds: 300),
            candidate("2", "Strings of Life", by: "Rhythim Is Rhythim", seconds: 303),
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    func testTempoMustAgreeWhenBothAreAnalysed() {
        let clash = DuplicateDetector.groups(in: [
            candidate("1", "Innerbloom", by: "RÜFÜS DU SOL", seconds: 578, bpm: 124),
            candidate("2", "Innerbloom", by: "RUFUS DU SOL", seconds: 578, bpm: 128),
        ])
        XCTAssertTrue(clash.isEmpty)

        let halfTime = DuplicateDetector.groups(in: [
            candidate("3", "Innerbloom", by: "RÜFÜS DU SOL", seconds: 578, bpm: 61),
            candidate("4", "Innerbloom", by: "RUFUS DU SOL", seconds: 578, bpm: 122),
        ])
        XCTAssertEqual(halfTime.count, 1)
    }

    func testDifferentKeysLowerConfidence() {
        let groups = DuplicateDetector.groups(in: [
            candidate("1", "Xtal", by: "Aphex Twin", seconds: 293, bpm: 118, key: CamelotKey(wheelPosition: 8, mode: .minor)),
            candidate("2", "Xtal", by: "Aphex Twin", seconds: 293, bpm: 118, key: CamelotKey(wheelPosition: 3, mode: .major)),
        ])
        XCTAssertEqual(groups.first?.confidence, .possible)
    }

    func testSameFileInTwoFoldersIsCertain() {
        let byPath = DuplicateDetector.groups(in: [
            candidate("-1", "Glue", by: "Bicep", seconds: 269, source: .localLossless, filePath: "/Users/alex/Music/DJ/Bicep - Glue.flac"),
            candidate("-2", "Glue", by: "Bicep", seconds: 269, source: .localLossless, filePath: "/Users/alex/Music/DJ/Bicep - Glue.flac"),
        ])
        XCTAssertEqual(byPath.first?.confidence, .sameFile)

        let byHash = DuplicateDetector.groups(in: [
            candidate("-3", "01 Glue", by: "Unknown Artist", seconds: 269, source: .localFile, filePath: "/Volumes/USB/Glue.mp3", contentHash: "ab12"),
            candidate("-4", "Glue", by: "Bicep", seconds: 269, source: .localFile, filePath: "/Users/alex/Music/Glue.mp3", contentHash: "ab12"),
        ])
        XCTAssertEqual(byHash.count, 1)
        XCTAssertEqual(byHash.first?.confidence, .sameFile)
    }

    func testKeeperPrefersLosslessThenDownloadedThenBitrateThenCues() {
        let lossless = candidate("-1", "Glue", by: "Bicep", seconds: 269, source: .localLossless, bitrate: 900)
        let downloaded = candidate("2", "Glue", by: "Bicep", seconds: 269, source: .downloaded, bitrate: 256)
        let stream = candidate("3", "Glue", by: "Bicep", seconds: 269, source: .stream, bitrate: 160)
        XCTAssertEqual(DuplicateDetector.ranked([stream, downloaded, lossless]).map(\.id), ["-1", "2", "3"])

        let low = candidate("4", "Glue", by: "Bicep", seconds: 269, bitrate: 64)
        let high = candidate("5", "Glue", by: "Bicep", seconds: 269, bitrate: 256)
        XCTAssertEqual(DuplicateDetector.ranked([low, high]).first?.id, "5")

        let plain = candidate("6", "Glue", by: "Bicep", seconds: 269)
        let cued = candidate("7", "Glue", by: "Bicep", seconds: 269, hasCues: true)
        XCTAssertEqual(DuplicateDetector.ranked([plain, cued]).first?.id, "7")
    }

    func testDecisionsAndRestriction() {
        let group = DuplicateGroup(
            members: [
                candidate("1", "Glue", by: "Bicep", seconds: 269),
                candidate("2", "Glue", by: "Bicep", seconds: 269),
                candidate("3", "Glue", by: "Bicep", seconds: 269),
            ],
            confidence: .likely,
            score: 0.85
        )
        XCTAssertEqual(group.restricted(to: ["1", "2"])?.memberIDs, ["1", "2"])
        XCTAssertNil(group.restricted(to: ["1"]))

        let decisions = DuplicateDecisions(hidden: [], dismissed: [["1", "2"]])
        XCTAssertTrue(decisions.isDismissed(["1", "2"]))
        XCTAssertFalse(decisions.isDismissed(["1", "2", "3"]))
    }

    func testThousandsOfTracksGroupOnlyTheDuplicates() {
        var input: [DuplicateCandidate] = []
        for index in 0..<4_000 {
            input.append(candidate("t\(index)", "Track \(index)", by: "Artist \(index % 300)", seconds: 200 + Double(index % 100)))
        }
        for index in stride(from: 0, to: 500, by: 10) {
            input.append(candidate("d\(index)", "Track \(index) (Original Mix)", by: "Artist \(index % 300)", seconds: 201 + Double(index % 100)))
        }
        let groups = DuplicateDetector.groups(in: input)
        XCTAssertEqual(groups.count, 50)
        XCTAssertTrue(groups.allSatisfy { $0.members.count == 2 })
    }
}
