import Foundation
import XCTest
@testable import SoundingTV

final class LibraryIdentityTests: XCTestCase {
    private static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    private static func user(_ id: Int, username: String, fullName: String? = nil) -> User {
        let full = fullName.map { ", \"full_name\": \"\($0)\"" } ?? ""
        let json = """
        {"id": \(id), "username": "\(username)", "permalink": "\(username.lowercased().replacingOccurrences(of: " ", with: "-"))", "permalink_url": "https://soundcloud.com/x"\(full)}
        """
        return try! decoder.decode(User.self, from: Data(json.utf8))
    }

    private static func track(_ id: Int, title: String, seconds: Int, userID: Int, username: String) -> Track {
        let json = """
        {
            "id": \(id), "title": "\(title)", "duration": \(seconds * 1000),
            "permalink_url": "https://soundcloud.com/x/\(id)", "created_at": "2025-09-01T12:00:00Z",
            "user": {"id": \(userID), "username": "\(username)", "permalink": "x", "permalink_url": "https://soundcloud.com/x"}
        }
        """
        return try! decoder.decode(Track.self, from: Data(json.utf8))
    }

    private static func album(_ id: Int, title: String, count: Int, userID: Int, username: String) -> Playlist {
        let json = """
        {
            "id": \(id), "title": "\(title)", "permalink_url": "https://soundcloud.com/x/sets/\(id)",
            "created_at": "2025-09-01T12:00:00Z", "track_count": \(count), "is_album": true, "set_type": "album",
            "user": {"id": \(userID), "username": "\(username)", "permalink": "x", "permalink_url": "https://soundcloud.com/x"}
        }
        """
        return try! decoder.decode(Playlist.self, from: Data(json.utf8))
    }

    func testNamesFoldCaseDiacriticsQuotesAndAmpersands() {
        XCTAssertEqual(LibraryNames.key("Beyoncé"), LibraryNames.key("BEYONCE"))
        XCTAssertEqual(LibraryNames.key("\u{201C}We Are The Resistance\u{201D}"), "we are the resistance")
        XCTAssertEqual(LibraryNames.key("Simon & Garfunkel"), LibraryNames.key("simon and garfunkel"))
        XCTAssertEqual(LibraryNames.key("The Prodigy"), LibraryNames.key("Prodigy"))
    }

    func testPrimaryArtistAndCredits() {
        XCTAssertEqual(LibraryNames.primaryArtist("Bicep feat. Clara La San"), "Bicep")
        XCTAssertEqual(LibraryNames.primaryArtist("Fred again.. (feat. Romy)"), "Fred again..")
        XCTAssertEqual(LibraryNames.credits("Skrillex x Fred again.. & Four Tet"), ["skrillex", "fred again", "four tet"])
        XCTAssertEqual(LibraryNames.credits("Bicep ft. Clara La San"), ["bicep", "clara la san"])
    }

    func testAlbumSuffixesAreStripped() {
        XCTAssertEqual(LibraryNames.albumTitle("Isles (Deluxe Edition)"), "Isles")
        XCTAssertEqual(LibraryNames.albumTitle("Glue - Single"), "Glue")
        XCTAssertEqual(LibraryNames.albumTitle("Random Access Memories (10th Anniversary Edition)"), "Random Access Memories")
        XCTAssertEqual(LibraryNames.albumTitle("Live at Wembley (Live)"), "Live at Wembley (Live)")
        XCTAssertEqual(LibraryNames.albumKey("\"We Are The Resistance\" - EP"), LibraryNames.albumKey("We Are the Resistance"))
    }

    func testFollowedUserLinksButUnsupportedNameDoesNot() {
        let bicep = Self.user(1, username: "bicep", fullName: "BICEP")
        let impostor = Self.user(2, username: "bicep-fan-page")
        let index = LibraryIdentityMatcher.CandidateIndex([
            LibraryArtistCandidate(user: bicep, isFollowed: true),
            LibraryArtistCandidate(user: impostor),
        ])
        XCTAssertEqual(LibraryIdentityMatcher.bestArtist(local: "Bicep", in: index, sharedTracks: [:])?.user.id, "1")

        let lone = LibraryIdentityMatcher.CandidateIndex([LibraryArtistCandidate(user: bicep)])
        XCTAssertNil(LibraryIdentityMatcher.bestArtist(local: "Bicep", in: lone, sharedTracks: [:]))
        XCTAssertEqual(LibraryIdentityMatcher.bestArtist(local: "Bicep", in: lone, sharedTracks: ["1": 2])?.user.id, "1")
    }

    func testAmbiguousArtistsStayUnlinked() {
        let first = Self.user(1, username: "kettama")
        let second = Self.user(2, username: "KETTAMA")
        let index = LibraryIdentityMatcher.CandidateIndex([
            LibraryArtistCandidate(user: first, isFollowed: true),
            LibraryArtistCandidate(user: second, isFollowed: true),
        ])
        XCTAssertNil(LibraryIdentityMatcher.bestArtist(local: "Kettama", in: index, sharedTracks: [:]))
    }

    func testAlbumMatchesOnTitleArtistAndTrackCount() {
        let playlist = Self.album(10, title: "Isles", count: 10, userID: 1, username: "bicep")
        let local = LibraryLocalAlbumProfile(id: "isles", title: "Isles (Deluxe)", artistKeys: ["bicep"], trackCount: 10)
        XCTAssertEqual(LibraryIdentityMatcher.bestAlbum(local, among: [playlist], linkedUserIDs: [])?.playlist.id, "10")

        let other = LibraryLocalAlbumProfile(id: "isles", title: "Isles", artistKeys: ["someone else"], trackCount: 10)
        XCTAssertNil(LibraryIdentityMatcher.bestAlbum(other, among: [playlist], linkedUserIDs: []))
    }

    func testTrackMatchesWithinThreeSeconds() {
        let remote = Self.track(100, title: "Glue", seconds: 268, userID: 1, username: "bicep")
        let index = LibraryIdentityMatcher.TrackIndex([remote])
        let near = Self.track(-5, title: "Glue", seconds: 270, userID: 9, username: "Bicep")
        let far = Self.track(-6, title: "Glue", seconds: 280, userID: 9, username: "Bicep")
        XCTAssertEqual(LibraryIdentityMatcher.bestTrack(for: near, in: index, linkedUserIDs: [])?.id, "100")
        XCTAssertNil(LibraryIdentityMatcher.bestTrack(for: far, in: index, linkedUserIDs: []))
    }
}
