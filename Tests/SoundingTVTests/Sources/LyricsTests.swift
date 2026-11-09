import Foundation
import XCTest
@testable import SoundingTV

final class LyricsParsingTests: XCTestCase {
    func testLRCMultipleTimestampsSortAndShareText() {
        let lines = LRCParser.parse("""
        [00:30.00][01:10.50]Chorus
        [00:05.25]Verse one
        """)
        XCTAssertEqual(lines.map(\.text), ["Verse one", "Chorus", "Chorus"])
        XCTAssertEqual(lines.map(\.start), [5.25, 30, 70.5])
        XCTAssertEqual(lines.map(\.id), [0, 1, 2])
    }

    func testLRCOffsetShiftsEarlierAndClampsAtZero() {
        let lines = LRCParser.parse("""
        [offset:+500]
        [00:00.20]Early
        [00:10.00]Later
        """)
        XCTAssertEqual(lines.map(\.start), [0, 9.5])
        let negative = LRCParser.parse("[offset:-250]\n[00:01.00]Line")
        XCTAssertEqual(negative.first?.start, 1.25)
    }

    func testLRCSkipsMalformedAndMetadataLines() {
        let lines = LRCParser.parse("""
        [ar:Artist]
        [ti:Title]
        [length: 03:20]
        plain text with no tag
        [aa:bb]Bad stamp
        [00:61.00]Seconds out of range
        [00:12]No fraction
        [00:13.5]One digit
        [00:14:20]Colon fraction
        [00:15.123]Milliseconds
        [00:16.00
        """)
        XCTAssertEqual(lines.map(\.text), ["No fraction", "One digit", "Colon fraction", "Milliseconds"])
        XCTAssertEqual(lines.map(\.start), [12, 13.5, 14.2, 15.123])
    }

    func testEnhancedLRCWordTiming() {
        let lines = LRCParser.parse("[00:20.00]<00:20.00>Hello <00:20.80>world<00:21.50>")
        XCTAssertEqual(lines.first?.text, "Hello world")
        XCTAssertEqual(lines.first?.words.map(\.text), ["Hello ", "world"])
        XCTAssertEqual(lines.first?.words.map(\.start), [20, 20.8])
        XCTAssertEqual(lines.first?.words.last?.end, 21.5)
    }

    func testLyricsfileWordSync() throws {
        let yaml = """
        version: '1.0'
        metadata:
          title: 'It''s a Song'
          artist: "The \\"Band\\""
          duration_ms: 245000
        lines:
          - text: 'Hello world'
            start_ms: 1200
            end_ms: 2800
            words:
              - text: 'Hello '
                start_ms: 1200
                end_ms: 1900
              - {text: 'world', start_ms: 1900, end_ms: 2800}
          - text: Second line # trailing comment
            start_ms: 5000
          - text: 'Broken'
            start_ms: -10
        plain: |
          Hello world

          Second line
        """
        let document = try XCTUnwrap(LyricsfileParser.parse(yaml))
        XCTAssertEqual(document.lines.map(\.text), ["Hello world", "Second line"])
        XCTAssertEqual(document.lines[0].start, 1.2)
        XCTAssertEqual(document.lines[0].end, 2.8)
        XCTAssertEqual(document.lines[0].words.map(\.text), ["Hello ", "world"])
        XCTAssertEqual(document.lines[0].words.map(\.start), [1.2, 1.9])
        XCTAssertTrue(document.lines[1].words.isEmpty)
        XCTAssertEqual(document.plain, "Hello world\n\nSecond line")
        XCTAssertFalse(document.instrumental)
        let root = try XCTUnwrap(MiniYAMLParser.parse(yaml))
        XCTAssertEqual(root["metadata"]?["title"]?.string, "It's a Song")
        XCTAssertEqual(root["metadata"]?["artist"]?.string, "The \"Band\"")
    }

    func testLyricsfileRejectsUnknownVersionAndReadsInstrumental() {
        XCTAssertNil(LyricsfileParser.parse("version: '2.0'\nmetadata:\n  title: A\n  artist: B\n"))
        let document = LyricsfileParser.parse("version: '1.0'\nmetadata:\n  title: A\n  artist: B\n  instrumental: true\n")
        XCTAssertEqual(document?.instrumental, true)
        XCTAssertEqual(document?.lines, [])
    }

    func testRecordPrefersWordSyncThenSyncedThenPlain() {
        let lyricsfile = "version: '1.0'\nmetadata:\n  title: A\n  artist: B\nlines:\n  - text: 'Hi there'\n    start_ms: 1000\n    words:\n      - text: 'Hi '\n        start_ms: 1000\n      - text: 'there'\n        start_ms: 1500\n"
        let wordSynced = LRCLIBRecord(id: 1, hasWordSync: true, plainLyrics: "Hi there", syncedLyrics: "[00:01.00]Hi there", lyricsfile: lyricsfile)
        XCTAssertEqual(wordSynced.lyrics?.isWordSynced, true)
        let synced = LRCLIBRecord(id: 2, hasWordSync: false, plainLyrics: "Hi", syncedLyrics: "[00:01.00]Hi", lyricsfile: nil)
        guard case .synced(let lines)? = synced.lyrics?.body else { return XCTFail("expected synced") }
        XCTAssertEqual(lines.map(\.text), ["Hi"])
        let plain = LRCLIBRecord(id: 3, plainLyrics: "\nOne\n\nTwo\n", syncedLyrics: nil)
        XCTAssertEqual(plain.lyrics?.body, .plain(["One", "", "Two"]))
        let instrumental = LRCLIBRecord(id: 4, instrumental: true)
        XCTAssertEqual(instrumental.lyrics?.body, .instrumental)
        XCTAssertNil(LRCLIBRecord(id: 5).lyrics)
    }

    func testDisplayLinesInsertInterludesForLongGaps() {
        let lines = LRCParser.parse("""
        [00:12.00]First
        [00:14.00]Second
        [00:18.00]
        [00:40.00]Third
        """)
        let display = LyricsTimeline.displayLines(lines)
        XCTAssertEqual(display.count, 5)
        guard case .interlude(_, let introStart, let introEnd) = display[0],
              case .interlude(_, let gapStart, let gapEnd) = display[3] else { return XCTFail("expected interludes") }
        XCTAssertEqual(introStart, 0)
        XCTAssertEqual(introEnd, 12)
        XCTAssertEqual(gapStart, 18)
        XCTAssertEqual(gapEnd, 40)
        XCTAssertEqual(LyricsTimeline.activeIndex(in: display, at: 13), 1)
        XCTAssertEqual(LyricsTimeline.activeIndex(in: display, at: 20), 3)
        XCTAssertEqual(LyricsTimeline.activeIndex(in: display, at: 1), 0)
    }
}

final class LyricsSignatureTests: XCTestCase {
    private func first(_ info: LyricsTrackInfo) -> LyricsSignature? {
        LyricsSignatureDeriver.candidates(for: info).first
    }

    func testArtistDashTitleWithFreeDownloadTag() {
        let info = LyricsTrackInfo(title: "Fred again.. - Delilah (pull me out of this) [FREE DL]", uploader: "Some Label", duration: 248.4)
        let candidate = first(info)
        XCTAssertEqual(candidate?.artist, "Fred again..")
        XCTAssertEqual(candidate?.track, "Delilah (pull me out of this)")
        XCTAssertEqual(candidate?.duration, 248)
    }

    func testPublisherMetadataWinsOverUploader() {
        let info = LyricsTrackInfo(
            title: "Oog om Oog (feat. Spinvis) (Elias Mazian Remix)", uploader: "jungle by night",
            publisherArtist: "Jungle By Night", publisherTitle: "Oog om Oog (feat. Spinvis) (Elias Mazian Remix)", duration: 244.5
        )
        let candidates = LyricsSignatureDeriver.candidates(for: info)
        XCTAssertEqual(candidates.first?.artist, "Jungle By Night")
        XCTAssertEqual(candidates.first?.track, "Oog om Oog (feat. Spinvis) (Elias Mazian Remix)")
        XCTAssertTrue(candidates.contains { $0.track == "Oog om Oog (Elias Mazian Remix)" })
        XCTAssertLessThanOrEqual(candidates.count, LyricsSignatureDeriver.maximumCandidates)
    }

    func testStripsOfficialVideoAndProducerCredits() {
        let info = LyricsTrackInfo(title: "Write Your Name (Prod. by Snapback) (Official Audio)", uploader: "G Herbo", duration: 199)
        XCTAssertEqual(first(info)?.track, "Write Your Name")
        XCTAssertEqual(first(info)?.artist, "G Herbo")
    }

    func testPremierePrefixAndFeaturingArtist() {
        let info = LyricsTrackInfo(title: "PREMIERE: Bicep feat. Clara La San - Saku", uploader: "Mixmag", duration: 300)
        let candidates = LyricsSignatureDeriver.candidates(for: info)
        XCTAssertEqual(candidates.first?.artist, "Bicep feat. Clara La San")
        XCTAssertEqual(candidates.first?.track, "Saku")
        XCTAssertTrue(candidates.contains { $0.artist == "Bicep" && $0.track == "Saku" })
    }

    func testUploaderSuffixAndLocalFileTags() {
        let uploader = LyricsTrackInfo(title: "Midnight City", uploader: "M83 Official", duration: 243)
        XCTAssertEqual(first(uploader)?.artist, "M83")
        let local = LyricsTrackInfo(title: "Midnight City", uploader: "M83", album: "Hurry Up, We're Dreaming", duration: 243.9, isLocal: true)
        XCTAssertEqual(first(local)?.album, "Hurry Up, We're Dreaming")
        XCTAssertEqual(first(local)?.duration, 244)
    }

    func testMixesAreRecognised() {
        XCTAssertTrue(LyricsTrackInfo(title: "Essy - Wildeburg 2025", uploader: "Wildeburg", duration: 10_717).isMix)
        XCTAssertFalse(LyricsTrackInfo(title: "Song", uploader: "A", duration: 200).isMix)
    }
}

final class LyricsRankingTests: XCTestCase {
    private let signature = LyricsSignature(track: "Midnight City", artist: "M83", album: nil, duration: 243)

    func testRejectsDurationOutsideTwoSeconds() {
        let far = LRCLIBSummary(id: 1, trackName: "Midnight City", artistName: "M83", duration: 246)
        XCTAssertNil(LyricsCandidateRanker.score(far, for: signature))
        let near = LRCLIBSummary(id: 2, trackName: "Midnight City", artistName: "M83", duration: 241.5)
        XCTAssertNotNil(LyricsCandidateRanker.score(near, for: signature))
    }

    func testPrefersSyncedWordSyncAndCloserDuration() {
        let plain = LRCLIBSummary(id: 1, trackName: "Midnight City", artistName: "M83", duration: 243, hasWordSync: false, hasSyncedLyrics: false)
        let synced = LRCLIBSummary(id: 2, trackName: "Midnight City", artistName: "M83", duration: 244, hasWordSync: false, hasSyncedLyrics: true)
        let words = LRCLIBSummary(id: 3, trackName: "Midnight City", artistName: "M83", duration: 244, hasWordSync: true, hasSyncedLyrics: true)
        XCTAssertEqual(LyricsCandidateRanker.best([plain, synced], for: signature)?.id, 2)
        XCTAssertEqual(LyricsCandidateRanker.best([plain, synced, words], for: signature)?.id, 3)
    }

    func testRejectsWrongTitleOrArtist() {
        let wrongTitle = LRCLIBSummary(id: 1, trackName: "Outro", artistName: "M83", duration: 243)
        let wrongArtist = LRCLIBSummary(id: 2, trackName: "Midnight City", artistName: "Someone Covering", duration: 243)
        XCTAssertNil(LyricsCandidateRanker.best([wrongTitle, wrongArtist], for: signature))
        let featured = LRCLIBSummary(id: 3, trackName: "Midnight City (feat. Nobody)", artistName: "M83, Nobody", duration: 243)
        XCTAssertEqual(LyricsCandidateRanker.best([featured], for: signature)?.id, 3)
    }
}

final class StubLyricsTransport: LyricsTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    private let lock = NSLock()
    private var replies: [(String, Reply)]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [(String, Reply)]) {
        self.replies = replies
    }

    var paths: [String] {
        lock.withLock { requests.compactMap { $0.url?.path } }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = lock.withLock {
            requests.append(request)
            let path = request.url?.path ?? ""
            if let index = replies.firstIndex(where: { path == $0.0 }) {
                return replies.remove(at: index).1
            }
            return Reply(status: 404, body: #"{"statusCode":404,"name":"TrackNotFound"}"#)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}

final class LyricsClientTests: XCTestCase {
    private func gate() -> LyricsRequestGate {
        LyricsRequestGate(spacing: 0...0, jitter: { 0 }, sleeper: { _ in })
    }

    private let info = LyricsTrackInfo(title: "M83 - Midnight City", uploader: "Label", duration: 243)

    func testPrimaryLookupSendsSignatureAndUserAgent() async throws {
        let transport = StubLyricsTransport([
            ("/api/get", .init(status: 200, body: #"{"id":7,"trackName":"Midnight City","artistName":"M83","duration":243,"instrumental":false,"hasWordSync":false,"plainLyrics":"Waiting","syncedLyrics":"[00:10.00]Waiting","lyricsfile":"version: '1.0'"}"#)),
        ])
        let client = LRCLIBClient(transport: transport, gate: gate())
        let result = try await client.lookup(info)
        guard case .found(let lyrics) = result, case .synced(let lines) = lyrics.body else { return XCTFail("expected lyrics") }
        XCTAssertEqual(lines.map(\.text), ["Waiting"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Sounding/") == true)
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasSuffix("(https://sounding.forbes.red)") == true)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "track_name" })?.value, "Midnight City")
        XCTAssertEqual(query.first(where: { $0.name == "artist_name" })?.value, "M83")
        XCTAssertEqual(query.first(where: { $0.name == "duration" })?.value, "243")
        XCTAssertEqual(transport.paths, ["/api/get"])
    }

    func testFallsBackToV2SearchThenGetByID() async throws {
        let transport = StubLyricsTransport([
            ("/api/v2/search", .init(status: 200, body: #"[{"id":9,"trackName":"Midnight City","artistName":"M83","duration":244,"instrumental":false,"hasWordSync":false,"hasPlainLyrics":true,"hasSyncedLyrics":true,"hasLyricsfile":true},{"id":10,"trackName":"Midnight City","artistName":"M83","duration":300,"hasSyncedLyrics":true}]"#)),
            ("/api/get/9", .init(status: 200, body: #"{"id":9,"trackName":"Midnight City","artistName":"M83","duration":244,"plainLyrics":"Waiting in a car","syncedLyrics":null}"#)),
        ])
        let client = LRCLIBClient(transport: transport, gate: gate())
        let result = try await client.lookup(info)
        XCTAssertEqual(result, .found(Lyrics(body: .plain(["Waiting in a car"]), recordID: 9, trackName: "Midnight City", artistName: "M83")))
        XCTAssertEqual(transport.paths.last, "/api/get/9")
        XCTAssertTrue(transport.paths.contains("/api/v2/search"))
        XCTAssertFalse(transport.paths.contains("/api/search"))
    }

    func testV2FailureFallsBackToV1Search() async throws {
        let transport = StubLyricsTransport([
            ("/api/v2/search", .init(status: 400, body: "Failed to deserialize query string", headers: ["Content-Type": "text/plain"])),
            ("/api/search", .init(status: 200, body: #"[{"id":11,"trackName":"Midnight City","artistName":"M83","duration":243,"plainLyrics":"Waiting","syncedLyrics":"[00:01.00]Waiting"}]"#)),
        ])
        let client = LRCLIBClient(transport: transport, gate: gate())
        let result = try await client.lookup(info)
        guard case .found(let lyrics) = result else { return XCTFail("expected lyrics") }
        XCTAssertEqual(lyrics.recordID, 11)
        XCTAssertEqual(transport.paths.last, "/api/search")
    }

    func testNotFoundWhenNothingMatches() async throws {
        let transport = StubLyricsTransport([("/api/v2/search", .init(status: 200, body: "[]"))])
        let client = LRCLIBClient(transport: transport, gate: gate())
        let result = try await client.lookup(info)
        XCTAssertEqual(result, .notFound)
        XCTAssertFalse(transport.paths.contains("/api/search"))
    }

    func testRateLimitStopsFurtherRequests() async throws {
        let transport = StubLyricsTransport([
            ("/api/get", .init(status: 429, body: "{}", headers: ["Retry-After": "30"])),
        ])
        let client = LRCLIBClient(transport: transport, gate: gate())
        do {
            _ = try await client.lookup(info)
            XCTFail("expected rate limit")
        } catch LyricsError.rateLimited(let until) {
            XCTAssertGreaterThanOrEqual(until.timeIntervalSinceNow, 29)
            XCTAssertLessThanOrEqual(until.timeIntervalSinceNow, 40)
        }
        do {
            _ = try await client.lookup(info)
            XCTFail("expected rate limit")
        } catch LyricsError.rateLimited {}
        XCTAssertEqual(transport.paths.count, 1)
    }
}

final class LyricsRequestGateTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.withLock { values.append(value) } }
        var all: [String] { lock.withLock { values } }
    }

    func testRequestsRunSequentiallyWithSpacing() async throws {
        let recorder = Recorder()
        let gate = LyricsRequestGate(spacing: 0.2...0.5, jitter: { 0.5 }, sleeper: { seconds in
            recorder.add(String(format: "sleep %.2f", seconds))
        })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<3 {
                group.addTask {
                    try await gate.run {
                        recorder.add("start \(index)")
                        try await Task.sleep(nanoseconds: 5_000_000)
                        recorder.add("end")
                    }
                }
            }
            try await group.waitForAll()
        }
        let events = recorder.all
        XCTAssertEqual(events.filter { $0.hasPrefix("start") }.count, 3)
        for (index, event) in events.enumerated() where event.hasPrefix("start") && index > 0 {
            XCTAssertTrue(events[index - 1].hasPrefix("sleep"), "\(events)")
        }
        for (index, event) in events.enumerated() where event.hasPrefix("start") {
            XCTAssertEqual(events[index + 1], "end", "\(events)")
        }
        let sleeps = events.filter { $0.hasPrefix("sleep") }.compactMap { Double($0.dropFirst(6)) }
        XCTAssertEqual(sleeps.count, 2)
        XCTAssertTrue(sleeps.allSatisfy { $0 > 0.3 && $0 <= 0.35 }, "\(sleeps)")
    }

    func testRetryAfterAddsJitterAndBlocks() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let gate = LyricsRequestGate(spacing: 0...0, jitter: { 1 }, now: { start }, sleeper: { _ in })
        let until = await gate.noteRetryAfter(10)
        XCTAssertEqual(until.timeIntervalSince(start), 13, accuracy: 0.001)
        do {
            _ = try await gate.run { 1 }
            XCTFail("expected block")
        } catch LyricsError.rateLimited(let blocked) {
            XCTAssertEqual(blocked, until)
        }
    }
}

final class LyricsCacheTests: XCTestCase {
    func testNegativeResultsExpire() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let cache = LyricsCache(directory: directory, now: { clock.now })
        await cache.store(.notFound, for: "a")
        let lyrics = Lyrics(body: .plain(["x"]), recordID: 1, trackName: nil, artistName: nil)
        await cache.store(.found(lyrics), for: "b")
        let reloaded = LyricsCache(directory: directory, now: { clock.now })
        let miss = await reloaded.lookup(for: "a")
        XCTAssertEqual(miss, .notFound)
        clock.now = clock.now.addingTimeInterval(LyricsCache.missLifetime + 1)
        let expired = await reloaded.lookup(for: "a")
        let kept = await reloaded.lookup(for: "b")
        XCTAssertNil(expired)
        XCTAssertEqual(kept, .found(lyrics))
    }

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 0)
    }
}

@MainActor
final class LyricsConsentTests: XCTestCase {
    func testNoRequestsUntilConsentGiven() async throws {
        let transport = StubLyricsTransport([])
        let client = LRCLIBClient(transport: transport, gate: LyricsRequestGate(spacing: 0...0, jitter: { 0 }, sleeper: { _ in }))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-consent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var provider = LyricsProvider.unset
        let store = LyricsStore(client: client, cache: LyricsCache(directory: directory), provider: { provider })
        let track = try XCTUnwrap(Self.track(id: 101, title: "M83 - Midnight City"))
        let next = try XCTUnwrap(Self.track(id: 102, title: "M83 - Wait"))

        store.focus(current: track, next: next)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.state(for: track.id), .needsConsent)
        XCTAssertTrue(transport.requests.isEmpty)

        provider = .off
        store.focus(current: track, next: next)
        store.retry(track)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.state(for: track.id), .off)
        XCTAssertTrue(transport.requests.isEmpty)

        provider = .lrclib
        store.focus(current: track, next: next)
        for _ in 0..<100 where transport.requests.isEmpty || store.state(for: next.id) == .idle || store.state(for: next.id) == .loading {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(transport.requests.isEmpty)
        XCTAssertEqual(store.state(for: track.id), .notFound)
    }

    static func track(id: Int, title: String) -> Track? {
        let json: [String: Any] = [
            "id": id, "title": title, "permalink_url": "https://soundcloud.com/a/\(id)", "created_at": 0,
            "user": ["id": 1, "username": "Label", "permalink": "label", "permalink_url": "https://soundcloud.com/label"],
            "media": ["transcodings": [[
                "url": "https://example.com/\(id)", "preset": "mp3", "duration": 243_000, "quality": "sq", "snipped": false,
                "format": ["protocol": "progressive", "mime_type": "audio/mpeg"],
            ]]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Track.self, from: data)
    }
}
