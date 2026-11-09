import Foundation
import XCTest
@testable import SoundingTV

#if DEBUG

final class LibraryCacheSelfTests: XCTestCase {
    func testLibraryCacheSelfTest() async {
        let report = await LibraryCacheSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }
}

enum LibraryCacheSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []
        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[LibraryCacheTest] \(status)"] + lines.map { "[LibraryCacheTest]   \($0)" }
                + failures.map { "[LibraryCacheTest]   ✗ \($0)" }).joined(separator: "\n")
        }
        mutating func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                lines.append(name)
            } else {
                let suffix = detail()
                failures.append(suffix.isEmpty ? name : "\(name): \(suffix)")
            }
        }
    }

    static func run() async -> Report {
        var report = Report()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryCacheSelfTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = LibraryCache(directory: dir)

        let empty = cache.loadSection("likes")
        report.expect("an uncached section reads empty, not an error", empty.isEmpty)

        let uncachedAt = await cache.sectionCachedAt("likes")
        report.expect("an uncached section has no cached-at timestamp", uncachedAt == nil)

        let rows: [LibraryCache.WriteRow] = [
            .init(id: "1", payload: Data("a".utf8), likedAtMillis: 100),
            .init(id: "2", payload: Data("b".utf8), likedAtMillis: 200),
            .init(id: "3", payload: Data("c".utf8), likedAtMillis: 300),
        ]
        await cache.replaceSection("likes", rows: rows)
        let loaded = cache.loadSection("likes")
        let freshSnapshot = await cache.loadSectionSnapshot("likes")

        let cachedAt = await cache.sectionCachedAt("likes")
        report.expect(
            "a just-written section has a cached-at timestamp within the last minute",
            cachedAt.map { abs($0.timeIntervalSinceNow) < 60 } ?? false,
            "cachedAt=\(cachedAt.map(String.init(describing:)) ?? "nil")"
        )
        report.expect(
            "rows round-trip in the order written",
            loaded.map(\.payload) == rows.map(\.payload),
            "loaded=\(loaded.map { String(data: $0.payload, encoding: .utf8) ?? "?" })"
        )
        report.expect(
            "likedAtMillis round-trips",
            loaded.map(\.likedAtMillis) == [100, 200, 300]
        )
        report.expect(
            "a replacement records a complete, fresh section snapshot",
            freshSnapshot.state.itemCount == 3
                && freshSnapshot.state.completedAt != nil
                && freshSnapshot.state.isFresh(for: 60)
        )

        let cursor = URL(string: "https://api-v2.soundcloud.com/me/library?cursor=next")!
        await cache.markSectionProgress("likes", nextHref: cursor, completed: false)
        let progressive = await cache.sectionState("likes")
        report.expect(
            "progressive section state retains its resume cursor without dropping rows",
            progressive.nextHref == cursor && progressive.itemCount == 3
        )

        let fewer: [LibraryCache.WriteRow] = [.init(id: "1", payload: Data("a".utf8), likedAtMillis: 100)]
        await cache.replaceSection("likes", rows: fewer)
        let afterRemoval = cache.loadSection("likes")
        report.expect(
            "a row absent from the next replaceSection is gone, not merged",
            afterRemoval.count == 1 && afterRemoval.first?.payload == Data("a".utf8),
            "afterRemoval=\(afterRemoval.count)"
        )

        await cache.replaceSection("playlists", rows: [.init(id: "p1", payload: Data("p".utf8))])
        let likesStillOne = cache.loadSection("likes")
        let playlistsOne = cache.loadSection("playlists")
        report.expect(
            "writing one section doesn't disturb another",
            likesStillOne.count == 1 && playlistsOne.count == 1
        )

        await cache.clearAll()
        let afterClear = cache.loadSection("likes")
        let playlistsAfterClear = cache.loadSection("playlists")
        report.expect(
            "clearAll empties every section",
            afterClear.isEmpty && playlistsAfterClear.isEmpty
        )

        let cache2 = LibraryCache(directory: dir)
        await cache2.replaceSection("following", rows: [.init(id: "u1", payload: Data("u".utf8))])
        let cache3 = LibraryCache(directory: dir)
        let reopened = cache3.loadSection("following")
        report.expect(
            "a written row persists across a fresh store instance on the same file",
            reopened.count == 1 && reopened.first?.payload == Data("u".utf8),
            "reopened=\(reopened.count)"
        )

        await likesIndexCases(cache, &report)
        await likesIndexPerf(cache, &report)

        let peerRecord = LikesPeerRecord(
            id: "peer-like", payload: Data("track".utf8), likedAtMillis: 42,
            title: "track", artist: "artist"
        )
        let peerBody = LikesPeerBody(
            accountId: "account-a", snapshotId: "snapshot-a",
            records: [peerRecord], isComplete: true
        )
        report.expect(
            "peer likes snapshot preserves account, completion, and records",
            peerBody.encoded().flatMap(LikesPeerBody.decode) == peerBody
        )

        return report
    }

    private static func likesIndexCases(_ cache: LibraryCache, _ report: inout Report) async {
        let seed: [LibraryCache.LikeIndexRow] = [
            .init(id: "t1", payload: Data("one".utf8), likedAtMillis: 3000,
                  title: "Déjà Vu (Extended Mix)", artist: "Fred again.."),
            .init(id: "t2", payload: Data("two".utf8), likedAtMillis: 2000,
                  title: "100% Pure Love", artist: "Crystal Waters"),
            .init(id: "t3", payload: Data("three".utf8), likedAtMillis: 1000,
                  title: "Vu Meter", artist: "Deja Boo"),
        ]
        await cache.upsertLikes(seed, generation: 1)

        let count = await cache.likesCount()
        report.expect("likes index: three upserts count three", count == 3, "count=\(count)")

        let containsKnownLike = await cache.containsLike(id: "t2")
        let containsMissingLike = await cache.containsLike(id: "missing")
        report.expect(
            "likes index: membership lookup distinguishes liked and unknown tracks",
            containsKnownLike && !containsMissingLike
        )

        let all = await cache.loadAllLikes()
        report.expect(
            "likes index: loadAllLikes orders newest-liked first",
            all.map(\.likedAtMillis) == [3000, 2000, 1000]
        )

        let head = await cache.loadAllLikes(limit: 2)
        report.expect(
            "likes index: a limited load returns the newest prefix in the same order",
            head.map(\.likedAtMillis) == [3000, 2000]
        )

        let folded = await cache.searchLikes(query: "deja", limit: 10)
        report.expect(
            "likes search: case- and diacritic-folded matching finds Déjà",
            folded.count == 2,
            "hits=\(folded.count)"
        )
        report.expect(
            "likes search: a title prefix hit ranks above an artist hit",
            folded.first?.payload == Data("one".utf8)
        )

        let wildcard = await cache.searchLikes(query: "100%", limit: 10)
        report.expect(
            "likes search: %/_ are literals, not wildcards",
            wildcard.count == 1 && wildcard.first?.payload == Data("two".utf8),
            "hits=\(wildcard.count)"
        )

        let multiTerm = await cache.searchLikes(query: "vu fred", limit: 10)
        report.expect(
            "likes search: terms AND together across title and artist",
            multiTerm.count == 1 && multiTerm.first?.payload == Data("one".utf8),
            "hits=\(multiTerm.count)"
        )

        let miss = await cache.searchLikes(query: "zzz", limit: 10)
        report.expect("likes search: a miss is empty, not an error", miss.isEmpty)

        await cache.upsertLikes([
            .init(id: "t1", payload: Data("one'".utf8), likedAtMillis: 4000,
                  title: "Déjà Vu (Extended Mix)", artist: "Fred again.."),
        ], generation: 2)
        let afterUpsert = await cache.likesCount()
        report.expect(
            "likes index: re-upserting an id updates in place, never duplicates",
            afterUpsert == 3,
            "count=\(afterUpsert)"
        )

        let pruned = await cache.pruneLikes(olderThanGeneration: 2)
        let survivors = await cache.likesCount()
        report.expect(
            "likes index: pruning an old generation removes exactly the unseen rows",
            pruned == 2 && survivors == 1,
            "pruned=\(pruned) survivors=\(survivors)"
        )

        await cache.upsertLikes([
            .init(id: "t4", payload: Data("four".utf8), likedAtMillis: 5000, title: "New", artist: "A"),
            .init(id: "t5", payload: Data("five".utf8), likedAtMillis: 6000, title: "Newer", artist: "B"),
        ], generation: 2)
        let newer = await cache.likeIDs(newerThanMillis: 4000)
        report.expect(
            "likes index: likeIDs(newerThanMillis:) is strict, keeping the boundary row",
            Set(newer) == Set(["t4", "t5"]),
            "newer=\(newer.sorted())"
        )

        await cache.removeLikes(ids: ["t4"])
        let afterRemove = await cache.likesCount()
        report.expect("likes index: removeLikes deletes by id", afterRemove == 2, "count=\(afterRemove)")

        await cache.setSyncValue("cursor-a", forKey: "likes.nextHref")
        let stored = await cache.syncValue(forKey: "likes.nextHref")
        report.expect("sync state: a value round-trips", stored == "cursor-a")

        await cache.setSyncValue(nil, forKey: "likes.nextHref")
        let removed = await cache.syncValue(forKey: "likes.nextHref")
        report.expect("sync state: nil deletes the key", removed == nil)

        await cache.setSyncValue("g", forKey: "likes.generation")
        await cache.clearAll()
        let likesAfterClear = await cache.likesCount()
        let stateAfterClear = await cache.syncValue(forKey: "likes.generation")
        report.expect(
            "clearAll wipes the likes index and sync state too",
            likesAfterClear == 0 && stateAfterClear == nil
        )
    }

    private static func trackPayload(id: Int, title: String, artist: String) -> Data {
        let json = """
        {
            "id": \(id),
            "title": "\(title)",
            "description": "Out now on all platforms. Thanks for all the support on this one — it means the world. Mixed and mastered at home over one long weekend.",
            "artwork_url": "https://i1.sndcdn.com/artworks-000\(id)-abcdef-large.jpg",
            "waveform_url": "https://wave.sndcdn.com/whqxbKr5Bxn2_m.json",
            "permalink_url": "https://soundcloud.com/artist\(id)/track\(id)",
            "playback_count": 412998,
            "likes_count": 18422,
            "reposts_count": 921,
            "created_at": "2025-11-02T18:22:04Z",
            "genre": "Deep House",
            "tag_list": "deep house summer \\"melodic techno\\" rooftop",
            "user": {
                "id": \(90_000 + id % 500),
                "username": "artist\(id % 500)",
                "permalink": "artist\(id % 500)",
                "permalink_url": "https://soundcloud.com/artist\(id % 500)",
                "avatar_url": "https://i1.sndcdn.com/avatars-000387272834-fkfd2d-large.jpg",
                "full_name": "\(artist)",
                "city": "London",
                "country": "United Kingdom",
                "track_count": 124,
                "followers_count": 4823
            },
            "media": {
                "transcodings": [
                    {
                        "url": "https://api-v2.soundcloud.com/media/soundcloud:tracks:\(id)/abc/stream/hls",
                        "duration": 251000,
                        "snipped": false,
                        "format": {"protocol": "hls", "mime_type": "audio/mpeg"},
                        "quality": "sq"
                    },
                    {
                        "url": "https://api-v2.soundcloud.com/media/soundcloud:tracks:\(id)/abc/stream/progressive",
                        "duration": 251000,
                        "snipped": false,
                        "format": {"protocol": "progressive", "mime_type": "audio/mpeg"},
                        "quality": "sq"
                    }
                ]
            }
        }
        """
        return Data(json.utf8)
    }

    private static func likesIndexPerf(_ cache: LibraryCache, _ report: inout Report) async {
        let titles = ["Midnight Run", "Coastline", "Déjà Vu", "Late Bloomer", "After Hours",
                      "Pink Pony Club", "Daylight", "Berlin Sunrise", "Warehouse Anthem", "Golden Hour"]
        let artists = ["Fred again..", "Metro Boomin", "Chappell Roan", "Phoebe Bridgers",
                       "The Weeknd", "Jack Harlow", "Overmono", "Bicep", "Jamie xx", "Peggy Gou"]
        let rows = (0..<5_000).map { i in
            LibraryCache.LikeIndexRow(
                id: "perf-\(i)",
                payload: trackPayload(id: i, title: "\(titles[i % titles.count]) #\(i)", artist: artists[i % artists.count]),
                likedAtMillis: Int64(i),
                title: "\(titles[i % titles.count]) #\(i)",
                artist: artists[i % artists.count]
            )
        }
        let payloadBytes = rows[0].payload.count

        var clock = Date()
        await cache.upsertLikes(rows, generation: 1)
        let upsertMs = Date().timeIntervalSince(clock) * 1000

        clock = Date()
        let loaded = await cache.loadAllLikes()
        let loadMs = Date().timeIntervalSince(clock) * 1000

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)

        clock = Date()
        var decoded: [Track] = []
        decoded.reserveCapacity(loaded.count)
        for row in loaded {
            guard let track = try? decoder.decode(Track.self, from: row.payload) else { continue }
            decoded.append(track)
        }
        let decodeMs = Date().timeIntervalSince(clock) * 1000

        clock = Date()
        let hits = await cache.searchLikes(query: "fred midnight", limit: 24)
        let searchMs = Date().timeIntervalSince(clock) * 1000

        report.expect(
            "perf: 5,000-row upsert stays under 5s",
            loaded.count == 5_000 && upsertMs < 5_000,
            String(format: "%.0fms", upsertMs)
        )
        report.expect(
            "perf: full 5,000-row hydrate stays under 1.5s",
            loadMs < 1_500,
            String(format: "%.0fms", loadMs)
        )
        report.expect(
            "perf: decoding all 5,000 track payloads stays under 3s",
            decoded.count == 5_000 && decodeMs < 3_000,
            String(format: "%.0fms decoded=%d", decodeMs, decoded.count)
        )
        report.expect(
            "perf: search over 5,000 rows stays under 250ms",
            !hits.isEmpty && searchMs < 250,
            String(format: "%.0fms hits=%d", searchMs, hits.count)
        )
        report.lines.append(String(
            format: "perf measured: payload=%dB upsert5k=%.0fms hydrate5k=%.0fms decode5k=%.0fms search5k=%.1fms",
            payloadBytes, upsertMs, loadMs, decodeMs, searchMs
        ))

        await cache.clearAll()
    }
}
#endif
