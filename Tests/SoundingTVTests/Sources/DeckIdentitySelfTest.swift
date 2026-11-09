import Foundation
import XCTest
@testable import SoundingTV

#if DEBUG
enum DeckIdentitySelfTest {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func comment(
        id: Int,
        body: String,
        timestamp: Int,
        createdAt: String,
        userID: Int,
        user: String
    ) -> Comment {
        let json = """
        {
          "id": \(id),
          "body": "\(body)",
          "timestamp": \(timestamp),
          "created_at": "\(createdAt)",
          "user": {
            "id": \(userID),
            "username": "\(user)",
            "permalink": "\(user)",
            "permalink_url": "https://soundcloud.com/\(user)"
          }
        }
        """
        // Test fixtures are static and intentionally fail loudly if their
        // shape stops matching the SoundCloud model.
        return try! decoder.decode(Comment.self, from: Data(json.utf8))
    }

    static func run() -> ModelDecodeSelfTestReport {
        var report = ModelDecodeSelfTestReport()
        func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                report.lines.append("On Deck: \(name) → ok")
            } else {
                report.failures.append("On Deck: \(name)")
            }
        }

        let request = comment(
            id: 1, body: "track id?", timestamp: 64_000,
            createdAt: "2026-08-04T10:00:00Z", userID: 10, user: "alice"
        )
        let answer = comment(
            id: 2, body: "@alice Underworld — Rez", timestamp: 66_000,
            createdAt: "2026-08-04T10:02:00Z", userID: 20, user: "bob"
        )
        let valid = DeckIdentityResolver.commentIdentities(comments: [answer, request])
        expect("request followed by tagged ID is accepted",
               valid.count == 1 && valid.first?.label == "Underworld — Rez"
                   && valid.first?.commentID == "2")

        let nearbyID = comment(
            id: 3, body: "Underworld — Rez", timestamp: 65_000,
            createdAt: "2026-08-04T10:01:00Z", userID: 30, user: "carol"
        )
        let standalone = DeckIdentityResolver.commentIdentities(comments: [nearbyID])
        expect("standalone Artist–Title comment is accepted",
               standalone.count == 1 && standalone.first?.label == "Underworld — Rez")

        let unrelated = comment(
            id: 4, body: "what a drop", timestamp: 65_000,
            createdAt: "2026-08-04T10:01:00Z", userID: 10, user: "alice"
        )
        expect("later chatter does not hide the earlier request",
               DeckIdentityResolver.commentIdentities(comments: [request, unrelated, answer]).count == 1)

        let sameAuthorAnswer = comment(
            id: 5, body: "@alice Underworld — Rez", timestamp: 66_000,
            createdAt: "2026-08-04T10:02:00Z", userID: 10, user: "alice"
        )
        expect("self-answer is rejected",
               DeckIdentityResolver.commentIdentities(comments: [request, sameAuthorAnswer]).isEmpty)

        let farAnswer = comment(
            id: 6, body: "@alice Underworld — Rez", timestamp: 100_000,
            createdAt: "2026-08-04T10:02:00Z", userID: 20, user: "bob"
        )
        expect("answer outside the track-time window is rejected",
               DeckIdentityResolver.commentIdentities(comments: [request, farAnswer]).isEmpty)

        let wrongTag = comment(
            id: 7, body: "@carol Underworld — Rez", timestamp: 66_000,
            createdAt: "2026-08-04T10:02:00Z", userID: 20, user: "bob"
        )
        expect("answer must tag the requester",
               DeckIdentityResolver.commentIdentities(comments: [request, wrongTag]).isEmpty)

        // Anonymized regression sweep from the persisted Essy – Wildeburg and
        // Jamback @ BRET set lists. These were previously promoted solely
        // because they had timestamps.
        let cachedFalsePositives = [
            "Mega set 🔥",
            "hahaha",
            "Silat Beksi on that thaangg, lekker lekker JANBECK from chatgpt",
            "Jesus Christ",
            "That track is tough… 💪",
            "Some refreshing drum patterns",
            "this is my vibe 🫶",
            "Nice number thisss",
            "Filthy",
            "lovely",
            "heel vet! welke track is dit??",
            "Tf ! 🔥🔥",
            "Lekker maat!",
            "ID ??😮‍💨😮‍💨😮‍💨😮‍💨😮‍💨",
            "Crazy",
            "id? 🫨",
            "shize",
            "Wtf 😳 lo que toca este brother! 🔥🔥",
            "id heree",
            "ohh shitt",
            "Fookin hell mate",
            "Best set I’ve listened to in a while 🫡",
            "Counting seconds to breath🤯💣",
            ":) :) :)",
            "yooooooooooooo",
            "ID on that 💣",
            "A Sided 😀",
            "iddd??",
            "pokoeemannnn",
            "Stepperz",
            "holllly what is this",
            "nyc subway sound is peak",
            "this is the track right hereeeee",
            "Aw mate what’s this one again",
            "Whatttt 😛",
            "amazing set!!! 🥶🥶🥶🥶🥶🥶",
            "HOLY SMOKES",
            "Favo Wildeburg set 👏🏼",
            "transition tho",
            "on repeat🔥",
            "unreleased one by @di_after",
            "Id? 👽",
            "This moment 🫶🏻🥹",
            "And this id? 😯😯",
            "love it❤️‍🔥",
            "Wat een set 😮‍💨🚀",
            "Uitgespeeld🤝🏼"
        ]
        expect("cached reactions and ID requests are rejected",
               cachedFalsePositives.allSatisfy {
                   !DeckIdentityResolver.looksLikeIdentificationAnswer($0)
               })

        let cachedUsefulIDs = [
            "pumped up — danny bond",
            "Danny Bond — Pumped Up (Extended Mix)",
            "Rez by Underworld"
        ]
        expect("cached usable track IDs survive strict validation",
               cachedUsefulIDs.allSatisfy(DeckIdentityResolver.looksLikeIdentificationAnswer))

        let randomTimedComments = cachedFalsePositives.enumerated().map { offset, body in
            comment(
                id: 100 + offset,
                body: body,
                timestamp: 200_000 + offset * 1_000,
                createdAt: "2026-08-04T11:00:00Z",
                userID: 100 + offset,
                user: "listener\(offset)"
            )
        }
        expect("timestamps alone never create set-list entries",
               DeckIdentityResolver.commentIdentities(comments: randomTimedComments).isEmpty)

        let first = SetlistSegment(
            id: "first", startSeconds: 60, observedAtSeconds: 60,
            artist: "Artist A", title: "Track A", version: nil,
            source: .user, confidence: 1, evidence: nil,
            shazamId: nil, soundCloudTrackId: nil, isUserEdited: true
        )
        let second = SetlistSegment(
            id: "second", startSeconds: 180, observedAtSeconds: 180,
            artist: "Artist B", title: "Track B", version: nil,
            source: .shazam, confidence: 0.9, evidence: nil,
            shazamId: "shazam-b", soundCloudTrackId: nil, isUserEdited: false
        )
        let bounded = GeneratedSetlist(
            trackId: "set", trackTitle: "A set", duration: 600,
            segments: [second, first], isSaved: false, updatedAt: Date()
        )
        expect("each entry ends at the next detected boundary",
               bounded.endSeconds(for: first) == 180)
        expect("the final entry ends with the containing set",
               bounded.endSeconds(for: second) == 600)
        expect("boundary lookup selects the new entry",
               bounded.segment(at: 180)?.id == second.id)
        expect("boundary lookup does not switch early",
               bounded.segment(at: 179.9)?.id == first.id)

        let escapedWhitespace = SetlistSegment(
            id: "escaped", startSeconds: 200, observedAtSeconds: 200,
            artist: #"\t  Artist"#, title: "\tTrack\n  Name", version: "  Live\tMix  ",
            source: .uploaderTracklist, confidence: 0.9, evidence: nil,
            shazamId: nil, soundCloudTrackId: nil, isUserEdited: false
        )
        expect("escaped and real whitespace is normalized for display",
               escapedWhitespace.displayLabel == "Artist – Track Name (Live Mix)")

        return report
    }
}

final class DeckIdentityTests: XCTestCase {
    func testStrictCommentSweepAndBoundaries() {
        let report = DeckIdentitySelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }

    private func segment(_ id: String, at start: TimeInterval, deleted: Bool = false) -> SetlistSegment {
        SetlistSegment(
            id: id, startSeconds: start, observedAtSeconds: start,
            artist: "Artist \(id)", title: "Track \(id)", version: nil,
            source: .shazam, confidence: 0.9, evidence: nil,
            shazamId: "shazam-\(id)", soundCloudTrackId: nil, isUserEdited: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            deletedAt: deleted ? Date(timeIntervalSince1970: 200) : nil
        )
    }

    private func setlist(_ segments: [SetlistSegment], duration: TimeInterval = 600) -> GeneratedSetlist {
        GeneratedSetlist(
            trackId: "mix", trackTitle: "Mix", duration: duration,
            segments: segments, isSaved: false, updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    func testTracklistEntriesCarryTimeRanges() {
        let tracklist = setlist([segment("c", at: 400), segment("a", at: 0), segment("b", at: 150)]).tracklist
        XCTAssertEqual(tracklist.entries.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(tracklist.entries.map(\.startSeconds), [0, 150, 400])
        XCTAssertEqual(tracklist.entries.map(\.endSeconds), [150, 400, 600])
        XCTAssertEqual(tracklist.entries.map(\.index), [0, 1, 2])
        XCTAssertEqual(tracklist.entries[1].durationSeconds, 250)
    }

    func testTracklistCurrentEntry() {
        let tracklist = setlist([segment("a", at: 30), segment("b", at: 150), segment("c", at: 400)]).tracklist
        XCTAssertNil(tracklist.currentIndex(at: 10))
        XCTAssertEqual(tracklist.currentIndex(at: 30), 0)
        XCTAssertEqual(tracklist.currentIndex(at: 149.9), 0)
        XCTAssertEqual(tracklist.currentIndex(at: 150), 1)
        XCTAssertEqual(tracklist.currentEntry(at: 399)?.id, "b")
        XCTAssertEqual(tracklist.currentEntry(at: 600)?.id, "c")
        XCTAssertNil(tracklist.currentIndex(at: 600.5))
        XCTAssertNil(tracklist.currentIndex(at: -1))
        XCTAssertTrue(tracklist.entries[1].contains(200))
        XCTAssertFalse(tracklist.entries[1].contains(400))
    }

    func testTracklistSkipsDeletedEntriesAndAgreesWithSegmentLookup() {
        let source = setlist([segment("a", at: 0), segment("gone", at: 100, deleted: true), segment("b", at: 300)])
        let tracklist = source.tracklist
        XCTAssertEqual(tracklist.entries.map(\.id), ["a", "b"])
        XCTAssertEqual(tracklist.entries.first?.endSeconds, 300)
        for position in stride(from: 0.0, through: 600.0, by: 7.5) {
            XCTAssertEqual(tracklist.currentEntry(at: position)?.id, source.segment(at: position)?.id, "at \(position)")
        }
    }

    func testEmptyTracklistHasNoCurrentEntry() {
        let tracklist = setlist([]).tracklist
        XCTAssertTrue(tracklist.isEmpty)
        XCTAssertNil(tracklist.currentEntry(at: 0))
    }

    func testSyncAdoptionKeepsUnchangedSetlistsOut() {
        let local = setlist([segment("a", at: 0)])
        XCTAssertTrue(SetlistMerging.adopt([local], into: ["mix": local]).isEmpty)

        var remote = setlist([segment("a", at: 0), segment("b", at: 200)])
        remote.updatedAt = Date(timeIntervalSince1970: 300)
        let merged = SetlistMerging.adopt([remote], into: ["mix": local])
        XCTAssertEqual(merged["mix"]?.activeSegments.map(\.id), ["a", "b"])
    }
}
#endif
