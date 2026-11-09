import Foundation
import XCTest
@testable import SoundingTV

@MainActor
final class BehindTheTrackTests: XCTestCase {
    func testTimestampsParseMinutesAndHours() {
        let text = "01. Juno Vale - Breakwater 0:00\n02. Maya Sol - Tides 4:35\n03. Night Tapes - Glass 1:02:07"
        let stamps = TrackDescriptionLinks.timestamps(in: text, duration: 7_200)
        XCTAssertEqual(stamps.map(\.seconds), [0, 275, 3_727])
    }

    func testTimestampsPastTheEndAreIgnored() {
        let stamps = TrackDescriptionLinks.timestamps(in: "Drop at 3:10 and outro at 9:59", duration: 300)
        XCTAssertEqual(stamps.map(\.seconds), [190])
    }

    func testTimestampsIgnoreDecimalsAndBadSeconds() {
        XCTAssertTrue(TrackDescriptionLinks.timestamps(in: "v1.2:30 and 4:75", duration: 600).isEmpty)
    }

    func testSeekURLRoundTrips() throws {
        let url = try XCTUnwrap(TrackDescriptionLinks.seekURL(275))
        XCTAssertEqual(TrackDescriptionLinks.seconds(from: url), 275)
        XCTAssertNil(TrackDescriptionLinks.seconds(from: URL(string: "https://soundcloud.com/x")!))
    }

    func testAttributedLinksURLsMentionsAndTimestamps() {
        let text = "Out now https://example.com/buy with @maya-sol, drop at 2:15"
        let attributed = TrackDescriptionLinks.attributed(text, duration: 400, linksTimestamps: true)
        let links = attributed.runs.compactMap { $0.link }
        XCTAssertEqual(links.map(\.absoluteString), [
            "https://example.com/buy",
            "https://soundcloud.com/maya-sol",
            "sounding-seek://135",
        ])
    }

    func testTimestampsStayPlainWithoutSeeking() {
        let attributed = TrackDescriptionLinks.attributed("drop at 2:15", duration: 400, linksTimestamps: false)
        XCTAssertTrue(attributed.runs.compactMap { $0.link }.isEmpty)
    }

    func testLicenceNames() {
        XCTAssertEqual(BehindTheTrackModel.licenceName("cc-by-nc"), "Creative Commons Attribution-NonCommercial")
        XCTAssertEqual(BehindTheTrackModel.licenceName("all-rights-reserved"), "All Rights Reserved")
        XCTAssertNil(BehindTheTrackModel.licenceName("unknown"))
    }

    func testTrackAboutDecodesStoreFields() throws {
        let json = """
        {"genre": "House", "tag_list": "deep \\"late night\\"", "label_name": "Rinse",
         "release_date": "2024-03-01T00:00:00Z", "license": "cc-by", "purchase_url": "https://example.com/buy",
         "purchase_title": "Free Download", "downloadable": true, "comment_count": 42,
         "publisher_metadata": {"isrc": "GBXXX2400001", "publisher": "Rinse Publishing", "release_title": "Tides EP"}}
        """
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        decoder.dateDecodingStrategy = .formatted(formatter)
        let about = try decoder.decode(TrackAbout.self, from: Data(json.utf8))
        XCTAssertEqual(about.tags, ["deep", "late night"])
        XCTAssertEqual(about.license, "cc-by")
        XCTAssertEqual(about.purchaseURL?.absoluteString, "https://example.com/buy")
        XCTAssertEqual(about.purchaseTitle, "Free Download")
        XCTAssertTrue(about.isDownloadable)
        XCTAssertEqual(about.commentCount, 42)
        XCTAssertEqual(about.isrc, "GBXXX2400001")
        XCTAssertEqual(about.releaseTitle, "Tides EP")
        XCTAssertNotNil(about.releaseDate)
    }

    func testPeopleSummary() throws {
        let users = try (1...4).map { try Self.user(id: $0) }
        XCTAssertEqual(BehindTheTrackModel.peopleSummary(Array(users.prefix(1))), "User 1")
        XCTAssertEqual(BehindTheTrackModel.peopleSummary(Array(users.prefix(2))), "User 1 and User 2")
        XCTAssertEqual(BehindTheTrackModel.peopleSummary(Array(users.prefix(3))), "User 1, User 2 and 1 other")
        XCTAssertEqual(BehindTheTrackModel.peopleSummary(users), "User 1, User 2 and 2 others")
    }

    func testEngagedUserDecodesPlainAndWrapped() throws {
        let plain = Self.userJSON(id: 7)
        let wrapped = "{\"user\": \(plain), \"created_at\": \"2024-01-01T00:00:00Z\"}"
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(TrackEngagedUser.self, from: Data(plain.utf8)).user.id, "7")
        XCTAssertEqual(try decoder.decode(TrackEngagedUser.self, from: Data(wrapped.utf8)).user.id, "7")
    }

    private static func userJSON(id: Int) -> String {
        """
        {"id": \(id), "username": "User \(id)", "permalink": "user-\(id)", "permalink_url": "https://soundcloud.com/user-\(id)",
         "avatar_url": null, "track_count": 0, "playlist_count": 0, "followers_count": 10, "followings_count": 1}
        """
    }

    private static func user(id: Int) throws -> User {
        try JSONDecoder().decode(User.self, from: Data(userJSON(id: id).utf8))
    }
}
