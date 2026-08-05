import Foundation
@testable import SoundingTV

#if DEBUG
enum FeedActivityDecodeSelfTest {

    private static func userJSON(id: Int, username: String) -> String {
        """
        { "id": \(id), "username": "\(username)", "permalink": "\(username)",
          "permalink_url": "https://soundcloud.com/\(username)" }
        """
    }

    private static func trackJSON(id: Int, title: String, ownerID: Int, ownerName: String, snippetOnly: Bool = false) -> String {
        let transcoding = snippetOnly
            ? """
              { "url": "https://api-v2.soundcloud.com/media/soundcloud:tracks:\(id)/stream/progressive",
                "preset": "mp3_1_0", "duration": 30000, "quality": "sq", "snipped": true,
                "format": { "protocol": "progressive", "mime_type": "audio/mpeg" } }
              """
            : """
              { "url": "https://api-v2.soundcloud.com/media/soundcloud:tracks:\(id)/stream/progressive",
                "preset": "mp3_1_0", "duration": 180000, "quality": "sq", "snipped": false,
                "format": { "protocol": "progressive", "mime_type": "audio/mpeg" } }
              """
        return """
        {
            "id": \(id), "title": "\(title)", "description": null, "artwork_url": null, "waveform_url": null,
            "permalink_url": "https://soundcloud.com/\(ownerName)/\(id)",
            "playback_count": 0, "likes_count": 0, "reposts_count": 0,
            "created_at": "2024-09-01T12:00:00Z",
            "user": \(userJSON(id: ownerID, username: ownerName)),
            "media": { "transcodings": [\(transcoding)] }
        }
        """
    }

    private static func playlistJSON(id: Int, title: String, ownerID: Int, ownerName: String) -> String {
        """
        {
            "id": \(id), "title": "\(title)", "description": null, "artwork_url": null,
            "permalink_url": "https://soundcloud.com/\(ownerName)/sets/\(id)",
            "duration": 0, "track_count": 0, "likes_count": 0, "reposts_count": 0,
            "created_at": "2024-09-01T12:00:00Z", "is_album": false,
            "user": \(userJSON(id: ownerID, username: ownerName))
        }
        """
    }

    private static func activityJSON(type: String, actorID: Int, actorName: String, uuid: String, body: String) -> String {
        """
        { "type": "\(type)", "created_at": "2024-09-02T08:00:00Z", "uuid": "\(uuid)",
          "user": \(userJSON(id: actorID, username: actorName)), \(body) }
        """
    }

    private static func page(_ elements: [String]) -> String {
        #"{"collection": [\#(elements.joined(separator: ","))], "next_href": null}"#
    }

    private static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    static func run() -> ModelDecodeSelfTestReport {
        var report = ModelDecodeSelfTestReport()

        func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                report.lines.append("\(name) → ok")
            } else {
                report.failures.append(name)
            }
        }

        do {
            let json = activityJSON(
                type: "track", actorID: 100, actorName: "artist-a", uuid: "uuid-1",
                body: "\"track\": \(trackJSON(id: 1, title: "Own Upload", ownerID: 100, ownerName: "artist-a"))"
            )
            do {
                let decoded = try decoder.decode(FeedActivity.self, from: Data(json.utf8))
                expect("upload: kind is .track", decoded.kind == .track)
                expect("upload: not a repost", !decoded.isRepost)
                expect("upload: actor is the owner", decoded.actor.id == decoded.track?.user.id)
                expect("upload: track present", decoded.track?.id == "1")
                expect("upload: playlist absent", decoded.playlist == nil)
            } catch {
                report.failures.append("plain upload threw: \(error)")
            }
        }

        do {
            let json = activityJSON(
                type: "track-repost", actorID: 200, actorName: "reposter", uuid: "uuid-2",
                body: "\"track\": \(trackJSON(id: 2, title: "Reposted Track", ownerID: 101, ownerName: "artist-b"))"
            )
            do {
                let decoded = try decoder.decode(FeedActivity.self, from: Data(json.utf8))
                expect("repost: kind is .trackRepost", decoded.kind == .trackRepost)
                expect("repost: is a repost", decoded.isRepost)
                expect("repost: actor is the reposter", decoded.actor.id == "200")
                expect("repost: not the track's owner", decoded.actor.id != decoded.track?.user.id)
                expect("repost: original owner preserved", decoded.track?.user.id == "101")
            } catch {
                report.failures.append("track repost threw: \(error)")
            }
        }

        do {
            let json = activityJSON(
                type: "playlist", actorID: 100, actorName: "artist-a", uuid: "uuid-3",
                body: "\"playlist\": \(playlistJSON(id: 10, title: "A Playlist", ownerID: 100, ownerName: "artist-a"))"
            )
            do {
                let decoded = try decoder.decode(FeedActivity.self, from: Data(json.utf8))
                expect("playlist: kind is .playlist", decoded.kind == .playlist)
                expect("playlist: not a repost", !decoded.isRepost)
                expect("playlist: playlist present", decoded.playlist?.id == "10")
                expect("playlist: track absent", decoded.track == nil)
            } catch {
                report.failures.append("playlist post threw: \(error)")
            }
        }

        do {
            let json = activityJSON(
                type: "playlist-repost", actorID: 300, actorName: "curator", uuid: "uuid-4",
                body: "\"playlist\": \(playlistJSON(id: 11, title: "Another Playlist", ownerID: 102, ownerName: "artist-c"))"
            )
            do {
                let decoded = try decoder.decode(FeedActivity.self, from: Data(json.utf8))
                expect("playlist repost: kind is .playlistRepost", decoded.kind == .playlistRepost)
                expect("playlist repost: is a repost", decoded.isRepost)
                expect("playlist repost: actor is the reposter", decoded.actor.id == "300")
                expect("playlist repost: original owner preserved", decoded.playlist?.user.id == "102")
            } catch {
                report.failures.append("playlist repost threw: \(error)")
            }
        }

        do {
            let unknown = activityJSON(
                type: "comment", actorID: 400, actorName: "commenter", uuid: "uuid-5",
                body: "\"comment\": {\"body\": \"nice track\"}"
            )
            let first = activityJSON(
                type: "track", actorID: 100, actorName: "artist-a", uuid: "uuid-6",
                body: "\"track\": \(trackJSON(id: 3, title: "First", ownerID: 100, ownerName: "artist-a"))"
            )
            let third = activityJSON(
                type: "track", actorID: 100, actorName: "artist-a", uuid: "uuid-7",
                body: "\"track\": \(trackJSON(id: 4, title: "Third", ownerID: 100, ownerName: "artist-a"))"
            )
            let json = page([first, unknown, third])
            do {
                let decoded = try decoder.decode(Page<FeedActivity>.self, from: Data(json.utf8))
                expect("unknown type: survivors kept", decoded.collection.count == 2)
                expect("unknown type: order preserved", decoded.collection.map(\.id) == ["uuid-6", "uuid-7"])
                expect("unknown type: exactly one dropped", decoded.droppedCount == 1)
            } catch {
                report.failures.append("page with unknown type threw unexpectedly: \(error)")
            }
        }

        do {
            let json = activityJSON(
                type: "track", actorID: 100, actorName: "artist-a", uuid: "uuid-8",
                body: "\"caption\": null"
            )
            do {
                _ = try decoder.decode(FeedActivity.self, from: Data(json.utf8))
                report.failures.append("track-typed entry with no track payload should have thrown")
            } catch {
                report.lines.append("malformed track entry: threw as expected → ok")
            }
        }

        do {
            let json = activityJSON(
                type: "track-repost", actorID: 200, actorName: "reposter", uuid: "uuid-9",
                body: "\"track\": \(trackJSON(id: 5, title: "Snippet Only", ownerID: 101, ownerName: "artist-b", snippetOnly: true))"
            )
            do {
                let decoded = try decoder.decode(FeedActivity.self, from: Data(json.utf8))
                expect("entitlement: track still decodes", decoded.track != nil)
                expect("entitlement: snippet transcodings filtered", decoded.track?.transcodings.isEmpty == true)
                expect("entitlement: no stream URL", decoded.track?.streamURL == nil)
            } catch {
                report.failures.append("entitlement fixture threw: \(error)")
            }
        }

        do {
            let entries = [
                activityJSON(type: "track", actorID: 100, actorName: "artist-a", uuid: "m-1",
                             body: "\"track\": \(trackJSON(id: 6, title: "A", ownerID: 100, ownerName: "artist-a"))"),
                activityJSON(type: "track-repost", actorID: 200, actorName: "reposter", uuid: "m-2",
                             body: "\"track\": \(trackJSON(id: 7, title: "B", ownerID: 101, ownerName: "artist-b"))"),
                activityJSON(type: "playlist", actorID: 102, actorName: "artist-c", uuid: "m-3",
                             body: "\"playlist\": \(playlistJSON(id: 12, title: "C", ownerID: 102, ownerName: "artist-c"))"),
                activityJSON(type: "playlist-repost", actorID: 300, actorName: "curator", uuid: "m-4",
                             body: "\"playlist\": \(playlistJSON(id: 13, title: "D", ownerID: 103, ownerName: "artist-d"))"),
            ]
            let json = page(entries)
            do {
                let decoded = try decoder.decode(Page<FeedActivity>.self, from: Data(json.utf8))
                expect("mixed page: all four survive", decoded.collection.count == 4)
                expect("mixed page: nothing dropped", decoded.droppedCount == 0)
                expect(
                    "mixed page: order preserved",
                    decoded.collection.map(\.id) == ["m-1", "m-2", "m-3", "m-4"]
                )
                expect(
                    "mixed page: kinds preserved in order",
                    decoded.collection.map(\.kind) == [.track, .trackRepost, .playlist, .playlistRepost]
                )
            } catch {
                report.failures.append("mixed page threw: \(error)")
            }
        }

        return report
    }
}
#endif
