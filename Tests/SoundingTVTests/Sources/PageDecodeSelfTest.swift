import Foundation
@testable import SoundingTV

#if DEBUG
struct ModelDecodeSelfTestReport {
    var lines: [String] = []
    var failures: [String] = []

    var summary: String {
        let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
        return (["[MixTest] \(status)"] + lines.map { "[MixTest]   \($0)" }
            + failures.map { "[MixTest]   ✗ \($0)" }).joined(separator: "\n")
    }
}

enum PageDecodeSelfTest {
    private static func track(id: Int, title: String) -> String {
        """
        {
            "id": \(id),
            "title": "\(title)",
            "description": null,
            "artwork_url": null,
            "waveform_url": null,
            "permalink_url": "https://soundcloud.com/example/\(id)",
            "playback_count": 0,
            "likes_count": 0,
            "reposts_count": 0,
            "created_at": "2024-09-01T12:00:00Z",
            "user": {
                "id": 1,
                "username": "example",
                "permalink": "example",
                "permalink_url": "https://soundcloud.com/example"
            },
            "media": { "transcodings": [] }
        }
        """
    }

    private static func stub(id: Int) -> String {
        """
        {
            "id": \(id),
            "kind": "track",
            "monetization_model": "NOT_APPLICABLE",
            "policy": "ALLOW"
        }
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
            let json = page([track(id: 1, title: "A"), track(id: 2, title: "B"), track(id: 3, title: "C")])
            do {
                let decoded = try decoder.decode(Page<Track>.self, from: Data(json.utf8))
                expect("well-formed: all three survive", decoded.collection.count == 3)
                expect("well-formed: order preserved", decoded.collection.map(\.id) == ["1", "2", "3"])
                expect("well-formed: nothing dropped", decoded.droppedCount == 0)
            } catch {
                report.failures.append("well-formed page threw: \(error)")
            }
        }

        do {
            let json = page([track(id: 10, title: "First"), stub(id: 11), track(id: 12, title: "Third")])
            do {
                let decoded = try decoder.decode(Page<Track>.self, from: Data(json.utf8))
                expect("middle-fails: survivors kept", decoded.collection.count == 2)
                expect("middle-fails: order preserved", decoded.collection.map(\.id) == ["10", "12"])
                expect("middle-fails: drop counted", decoded.droppedCount == 1)
            } catch {
                report.failures.append("middle-fails page threw unexpectedly: \(error)")
            }
        }

        do {
            let json = page([stub(id: 20), stub(id: 21)])
            do {
                let decoded = try decoder.decode(Page<Track>.self, from: Data(json.utf8))
                report.failures.append(
                    "all-fail: expected a thrown error, got a page with \(decoded.collection.count) item(s)"
                )
            } catch {
                report.lines.append("all-fail: threw as expected → ok")
            }
        }

        do {
            let json = page([])
            do {
                let decoded = try decoder.decode(Page<Track>.self, from: Data(json.utf8))
                expect("empty: no items", decoded.collection.isEmpty)
                expect("empty: nothing dropped", decoded.droppedCount == 0)
            } catch {
                report.failures.append("empty page threw: \(error)")
            }
        }

        return report
    }
}

enum PlaylistDecodeSelfTest {

    private static func track(id: Int, title: String, snippetOnly: Bool = false) -> String {
        let transcodings = snippetOnly ? """
        {
            "url": "https://api-v2.soundcloud.com/media/soundcloud:tracks:\(id)/stream/progressive",
            "preset": "mp3_1_0",
            "duration": 30000,
            "quality": "sq",
            "snipped": true,
            "format": { "protocol": "progressive", "mime_type": "audio/mpeg" }
        }
        """ : ""
        return """
        {
            "id": \(id),
            "title": "\(title)",
            "description": null,
            "artwork_url": null,
            "waveform_url": null,
            "permalink_url": "https://soundcloud.com/example/\(id)",
            "playback_count": 0,
            "likes_count": 0,
            "reposts_count": 0,
            "created_at": "2024-09-01T12:00:00Z",
            "user": {
                "id": 1,
                "username": "example",
                "permalink": "example",
                "permalink_url": "https://soundcloud.com/example"
            },
            "media": { "transcodings": [\(transcodings)] }
        }
        """
    }

    private static func stub(id: Int) -> String {
        """
        {
            "id": \(id),
            "kind": "track",
            "monetization_model": "NOT_APPLICABLE",
            "policy": "ALLOW"
        }
        """
    }

    private static func playlist(id: Int, trackCount: Int, tracksJSON: [String]?) -> String {
        let tracksField = tracksJSON.map { ", \"tracks\": [\($0.joined(separator: ","))]" } ?? ""
        return """
        {
            "id": \(id),
            "title": "Fixture Playlist",
            "description": null,
            "artwork_url": null,
            "permalink_url": "https://soundcloud.com/example/sets/\(id)",
            "duration": 0,
            "track_count": \(trackCount),
            "likes_count": 0,
            "reposts_count": 0,
            "created_at": "2024-09-01T12:00:00Z",
            "is_album": false,
            "user": {
                "id": 1,
                "username": "example",
                "permalink": "example",
                "permalink_url": "https://soundcloud.com/example"
            }\(tracksField)
        }
        """
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(dateFormatter)
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(dateFormatter)
        return encoder
    }()

    private static func decodePlaylist(_ json: String) throws -> Playlist {
        try decoder.decode(Playlist.self, from: Data(json.utf8))
    }

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
            let hydrated = (1...5).map { track(id: $0, title: "Track \($0)") }
            let stubs = (6...161).map { stub(id: $0) }
            let json = playlist(id: 900, trackCount: 161, tracksJSON: hydrated + stubs)
            do {
                let decoded = try decodePlaylist(json)
                expect("5+156: playlist decodes at all", true)
                expect("5+156: 5 tracks hydrated", decoded.loadedTrackCount == 5)
                expect("5+156: true length preserved", decoded.totalTrackCount == 161)
                expect("5+156: manifest holds every id", decoded.trackIDs?.count == 161)
                expect(
                    "5+156: manifest order preserved",
                    decoded.trackIDs == (1...161).map(String.init)
                )
                expect(
                    "5+156: hydrated order preserved",
                    decoded.loadedTracks.map(\.id) == ["1", "2", "3", "4", "5"]
                )
                expect("5+156: knows it is incomplete", decoded.hasUnloadedTracks)
                expect("5+156: 156 ids left to fetch", decoded.unloadedTrackIDs.count == 156)
                expect(
                    "5+156: unloaded ids are the right ones",
                    decoded.unloadedTrackIDs.first == "6" && decoded.unloadedTrackIDs.last == "161"
                )
            } catch {
                report.failures.append("5+156 playlist threw: \(error)")
            }
        }

        do {
            let json = playlist(id: 901, trackCount: 40, tracksJSON: (1...40).map { stub(id: $0) })
            do {
                let decoded = try decodePlaylist(json)
                expect("zero-hydrated: does not throw", true)
                expect("zero-hydrated: no tracks loaded", decoded.loadedTrackCount == 0)
                expect("zero-hydrated: full length still known", decoded.totalTrackCount == 40)
                expect("zero-hydrated: all 40 fetchable", decoded.unloadedTrackIDs.count == 40)
            } catch {
                report.failures.append("zero-hydrated playlist threw: \(error)")
            }
        }

        do {
            let json = playlist(id: 902, trackCount: 0, tracksJSON: [])
            do {
                let decoded = try decodePlaylist(json)
                expect("empty: no tracks", decoded.loadedTracks.isEmpty)
                expect("empty: manifest present but empty", decoded.trackIDs?.isEmpty == true)
                expect("empty: total is zero", decoded.totalTrackCount == 0)
                expect("empty: nothing pending", !decoded.hasUnloadedTracks)
            } catch {
                report.failures.append("empty playlist threw: \(error)")
            }
        }

        do {
            let json = playlist(
                id: 903, trackCount: 3,
                tracksJSON: (1...3).map { track(id: $0, title: "Track \($0)") }
            )
            do {
                let decoded = try decodePlaylist(json)
                expect("short: all three hydrated", decoded.loadedTrackCount == 3)
                expect("short: total agrees", decoded.totalTrackCount == 3)
                expect("short: nothing pending", !decoded.hasUnloadedTracks)
                expect("short: order preserved", decoded.loadedTracks.map(\.id) == ["1", "2", "3"])
            } catch {
                report.failures.append("short playlist threw: \(error)")
            }
        }

        do {
            let json = playlist(id: 904, trackCount: 27, tracksJSON: nil)
            do {
                let decoded = try decodePlaylist(json)
                expect("no-tracks-key: tracks nil", decoded.tracks == nil)
                expect("no-tracks-key: manifest nil", decoded.trackIDs == nil)
                expect("no-tracks-key: falls back to track_count", decoded.totalTrackCount == 27)
                expect("no-tracks-key: nothing to fetch by id yet", decoded.unloadedTrackIDs.isEmpty)
            } catch {
                report.failures.append("no-tracks-key playlist threw: \(error)")
            }
        }

        do {
            let hydrated = (1...5).map { track(id: $0, title: "Track \($0)") }
            let stubs = (6...161).map { stub(id: $0) }
            let json = playlist(id: 905, trackCount: 161, tracksJSON: hydrated + stubs)
            do {
                let original = try decodePlaylist(json)
                let reencoded = try encoder.encode(original)
                let round = try decoder.decode(Playlist.self, from: reencoded)
                expect("round-trip: id survives", round.id == original.id)
                expect("round-trip: title survives", round.title == original.title)
                expect("round-trip: manifest length survives", round.totalTrackCount == 161)
                expect("round-trip: manifest order survives", round.trackIDs == original.trackIDs)
                expect(
                    "round-trip: hydrated tracks survive",
                    round.loadedTracks.map(\.id) == original.loadedTracks.map(\.id)
                )
                expect("round-trip: still knows it is incomplete", round.hasUnloadedTracks)
            } catch {
                report.failures.append("round-trip threw: \(error)")
            }
        }

        do {
            let json = playlist(id: 906, trackCount: 27, tracksJSON: nil)
            do {
                let original = try decodePlaylist(json)
                let round = try decoder.decode(Playlist.self, from: try encoder.encode(original))
                expect("round-trip (no key): manifest still nil", round.trackIDs == nil)
                expect("round-trip (no key): track_count still 27", round.totalTrackCount == 27)
            } catch {
                report.failures.append("round-trip (no tracks key) threw: \(error)")
            }
        }

        do {
            let entries = [
                track(id: 1, title: "Repeated"), stub(id: 2), track(id: 1, title: "Repeated")
            ]
            let json = playlist(id: 907, trackCount: 3, tracksJSON: entries)
            do {
                let decoded = try decodePlaylist(json)
                expect("duplicates: all three slots kept", decoded.trackIDs == ["1", "2", "1"])
                let round = try decoder.decode(Playlist.self, from: try encoder.encode(decoded))
                expect("duplicates: survive round-trip", round.trackIDs == ["1", "2", "1"])
            } catch {
                report.failures.append("duplicate-id playlist threw: \(error)")
            }
        }

        do {
            let json = playlist(
                id: 908, trackCount: 2,
                tracksJSON: [
                    track(id: 1, title: "Snippet Only", snippetOnly: true),
                    track(id: 2, title: "Normal")
                ]
            )
            do {
                let decoded = try decodePlaylist(json)
                let snippet = decoded.loadedTracks.first { $0.id == "1" }
                expect("entitlement: snippet track still decodes", snippet != nil)
                expect("entitlement: snippet transcodings filtered", snippet?.transcodings.isEmpty == true)
                expect("entitlement: no stream URL", snippet?.streamURL == nil)
            } catch {
                report.failures.append("entitlement playlist threw: \(error)")
            }
        }

        do {
            let entries = (1...5).map { track(id: $0, title: "Track \($0)") } + (6...30).map { stub(id: $0) }
            let json = playlist(id: 909, trackCount: 30, tracksJSON: entries)
            do {
                let ids = try decoder.decode(PlaylistTrackIDs.self, from: Data(json.utf8))
                expect("PlaylistTrackIDs: all 30 ids", ids.trackIDs.count == 30)
                expect("PlaylistTrackIDs: order preserved", ids.trackIDs == (1...30).map(String.init))
            } catch {
                report.failures.append("PlaylistTrackIDs threw: \(error)")
            }
        }

        do {
            let hydrated = (1...5).map { track(id: $0, title: "Track \($0)") }
            let stubs = (6...161).map { stub(id: $0) }
            let json = playlist(id: 910, trackCount: 161, tracksJSON: hydrated + stubs)
            do {
                let decoded = try decodePlaylist(json)
                var cursor = PlaylistTrackCursor(playlist: decoded)
                expect("cursor: knows the true total", cursor.totalCount == 161)
                expect("cursor: starts empty", cursor.loadedCount == 0)
                expect("cursor: has work to do", cursor.canLoadMore)

                let first = cursor.nextBatch()
                expect("cursor: first batch is 50 ids", first.count == 50)
                expect("cursor: first batch starts at the top", first.first == "1")
                expect("cursor: nextBatch does not advance", cursor.offset == 0)

                cursor.accept(decoded.loadedTracks, for: first)
                expect("cursor: advanced by ids requested", cursor.offset == 50)
                expect("cursor: counted the withheld ids", cursor.unavailableCount == 45)
                expect("cursor: kept what it got", cursor.loadedCount == 5)

                let second = cursor.nextBatch()
                expect("cursor: second batch moves on", second.first == "51")

                var guardCounter = 0
                while cursor.canLoadMore, guardCounter < 100 {
                    let batch = cursor.nextBatch()
                    cursor.accept([], for: batch)
                    guardCounter += 1
                }
                expect("cursor: terminates", !cursor.canLoadMore)
                expect("cursor: consumed exactly the manifest", cursor.offset == 161)
                expect("cursor: took 4 batches total", guardCounter == 3)

                cursor.reset()
                expect("cursor: reset rewinds", cursor.offset == 0 && cursor.loadedCount == 0)
            } catch {
                report.failures.append("cursor fixture threw: \(error)")
            }
        }

        do {
            let json = "[\(track(id: 1, title: "A")),\(stub(id: 2)),\(track(id: 3, title: "C"))]"
            do {
                let decoded = try decoder.decode(ResilientArray<Track>.self, from: Data(json.utf8))
                expect("ResilientArray: survivors kept", decoded.elements.map(\.id) == ["1", "3"])
                expect("ResilientArray: drop counted", decoded.droppedCount == 1)
            } catch {
                report.failures.append("ResilientArray threw: \(error)")
            }
        }

        return report
    }
}
#endif
