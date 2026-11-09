import XCTest
@testable import SoundingTV

final class TopShelfTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let placeholder: (URL?, URL?) = (URL(fileURLWithPath: "/tmp/p.png"), URL(fileURLWithPath: "/tmp/p@2x.png"))
    private let locale = Locale(identifier: "en_GB")

    private func track(
        _ id: String,
        shelf: String = TopShelfStore.recentsKind,
        duration: TimeInterval = 240,
        progress: Double = 0,
        playedAt: Date? = nil,
        artwork: URL? = nil
    ) -> TopShelfEntry {
        TopShelfEntry(
            id: shelf == TopShelfStore.recentsKind ? id : "\(shelf):\(id)",
            title: "Track \(id)",
            subtitle: "Artist \(id)",
            artworkURL: artwork,
            artworkURL2x: artwork,
            progress: progress,
            actionURL: TopShelfStore.trackURL(trackId: id),
            playActionURL: TopShelfStore.playURL(trackId: id, shelf: shelf),
            kind: .track,
            duration: duration,
            playedAt: playedAt
        )
    }

    private func snapshot(_ sections: [TopShelfSection], signedIn: Bool = true) -> TopShelfSnapshot {
        TopShelfSnapshot(sections: sections, generatedAt: now, isSignedIn: signedIn)
    }

    private func rows(_ plan: TopShelfContentPlan) -> [TopShelfRow] {
        guard case .rows(let rows) = plan else {
            XCTFail("Expected rows, got \(plan)")
            return []
        }
        return rows
    }

    // MARK: - Fallbacks

    func testFallbacks() {
        XCTAssertEqual(TopShelfLayout.plan(for: nil, now: now), .fallback(.noSnapshot))
        XCTAssertEqual(TopShelfLayout.plan(for: snapshot([], signedIn: false), now: now), .fallback(.signedOut))
        XCTAssertEqual(TopShelfLayout.plan(for: snapshot([]), now: now), .fallback(.emptyLibrary))
        let empty = TopShelfSection(kind: TopShelfStore.likesKind, title: "Your Likes", entries: [])
        XCTAssertEqual(TopShelfLayout.plan(for: snapshot([empty]), now: now), .fallback(.emptyLibrary))
    }

    func testSignedOutWinsOverStaleEntries() {
        let recents = TopShelfSection(kind: TopShelfStore.recentsKind, title: "Recently Played", entries: [track("1")])
        XCTAssertEqual(TopShelfLayout.plan(for: snapshot([recents], signedIn: false), now: now), .fallback(.signedOut))
    }

    // MARK: - Shelf assembly

    func testRowsFollowFixedOrderWhateverTheSnapshotOrder() {
        let mixes = TopShelfSection(kind: TopShelfStore.mixesKind, title: "Mixes For You", entries: [
            TopShelfEntry(
                id: "mixes:p1",
                title: "Mix",
                subtitle: "",
                artworkURL: nil,
                actionURL: TopShelfStore.playlistURL(id: "p1"),
                playActionURL: TopShelfStore.playlistURL(id: "p1", play: true),
                kind: .playlist
            ),
        ])
        let likes = TopShelfSection(kind: TopShelfStore.likesKind, title: "Your Likes", entries: [track("2", shelf: TopShelfStore.likesKind)])
        let recents = TopShelfSection(kind: TopShelfStore.recentsKind, title: "Recently Played", entries: [track("1")])

        let result = rows(TopShelfLayout.plan(for: snapshot([mixes, likes, recents]), now: now, placeholder: placeholder, locale: locale))
        XCTAssertEqual(result.map(\.kind), [TopShelfStore.recentsKind, TopShelfStore.likesKind, TopShelfStore.mixesKind])
    }

    func testInProgressSetMovesToContinueListening() {
        let set = track("9", duration: 3_600, progress: 0.5, playedAt: now.addingTimeInterval(-3_600))
        let song = track("1", duration: 200, progress: 0.5)
        let recents = TopShelfSection(kind: TopShelfStore.recentsKind, title: "Recently Played", entries: [set, song])

        let result = rows(TopShelfLayout.plan(for: snapshot([recents]), now: now, placeholder: placeholder, locale: locale))
        XCTAssertEqual(result.map(\.kind), [TopShelfStore.continueKind, TopShelfStore.recentsKind])

        let resume = result[0].tiles[0]
        XCTAssertEqual(resume.id, "continue:9")
        XCTAssertEqual(resume.progress, 0.5)
        XCTAssertEqual(resume.playURL, resume.displayURL)
        XCTAssertEqual(TopShelfStore.route(from: resume.playURL), .track(id: "9", shelf: TopShelfStore.recentsKind, position: 1_800))
        XCTAssertTrue(resume.title.hasPrefix("Track 9 · "))

        XCTAssertEqual(result[1].tiles.map(\.id), ["1"])
    }

    func testContinueListeningSkipsFinishedUnstartedAndStaleSets() {
        let finished = track("a", duration: 3_600, progress: 0.97)
        let unstarted = track("b", duration: 3_600, progress: 0.01)
        let stale = track("c", duration: 3_600, progress: 0.4, playedAt: now.addingTimeInterval(-30 * 24 * 3_600))
        let recents = TopShelfSection(kind: TopShelfStore.recentsKind, title: "Recently Played", entries: [finished, unstarted, stale])

        let result = rows(TopShelfLayout.plan(for: snapshot([recents]), now: now, placeholder: placeholder, locale: locale))
        XCTAssertEqual(result.map(\.kind), [TopShelfStore.recentsKind])
        XCTAssertEqual(result[0].tiles.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(result[0].tiles[0].progress, 0)
        XCTAssertEqual(result[0].tiles[2].progress, 0.4)
    }

    func testDuplicateIdentifiersAreDroppedAndRowsCapped() {
        let entries = (0..<30).map { track("\($0)") } + [track("0")]
        let recents = TopShelfSection(kind: TopShelfStore.recentsKind, title: "Recently Played", entries: entries)

        let result = rows(TopShelfLayout.plan(for: snapshot([recents]), now: now, placeholder: placeholder, locale: locale))
        XCTAssertEqual(result[0].tiles.count, TopShelfStore.maxEntriesPerSection)
        XCTAssertEqual(Set(result[0].tiles.map(\.id)).count, result[0].tiles.count)
    }

    func testTrackTilesPlayFromTheirShelfOnSelectAndPlay() {
        let likes = TopShelfSection(kind: TopShelfStore.likesKind, title: "Your Likes", entries: [track("7", shelf: TopShelfStore.likesKind)])
        let tile = rows(TopShelfLayout.plan(for: snapshot([likes]), now: now, placeholder: placeholder, locale: locale))[0].tiles[0]

        XCTAssertEqual(tile.displayURL, tile.playURL)
        XCTAssertEqual(TopShelfStore.route(from: tile.playURL), .track(id: "7", shelf: TopShelfStore.likesKind, position: nil))
        XCTAssertEqual(tile.progress, 0)
    }

    func testMissingArtworkFallsBackToPlaceholder() {
        let remote = URL(string: "https://i1.sndcdn.com/artworks-abc-t500x500.jpg")
        let recents = TopShelfSection(kind: TopShelfStore.recentsKind, title: "Recently Played", entries: [
            track("1", artwork: remote),
            track("2"),
        ])
        let tiles = rows(TopShelfLayout.plan(for: snapshot([recents]), now: now, placeholder: placeholder, locale: locale))[0].tiles
        XCTAssertEqual(tiles[0].imageURL, remote)
        XCTAssertEqual(tiles[0].imageURL2x, remote)
        XCTAssertEqual(tiles[1].imageURL, placeholder.0)
        XCTAssertEqual(tiles[1].imageURL2x, placeholder.1)
    }

    func testUnknownShelvesKeepTheirStoredTitleAfterKnownOnes() {
        let other = TopShelfSection(kind: "other", title: "Other", entries: [track("x", shelf: "other")])
        let recents = TopShelfSection(kind: TopShelfStore.recentsKind, title: "Stale Title", entries: [track("1")])
        let result = rows(TopShelfLayout.plan(for: snapshot([other, recents]), now: now, placeholder: placeholder, locale: locale))
        XCTAssertEqual(result.map(\.kind), [TopShelfStore.recentsKind, "other"])
        XCTAssertEqual(result[0].title, "Recently Played")
        XCTAssertEqual(result[1].title, "Other")
    }

    // MARK: - Titles

    func testTitles() {
        XCTAssertEqual(TopShelfLayout.title(for: track("1"), locale: locale), "Track 1 · Artist 1")

        let set = track("2", duration: 2 * 3_600 + 5 * 60)
        let setTitle = TopShelfLayout.title(for: set, locale: locale)
        XCTAssertTrue(setTitle.hasPrefix("Track 2 · Artist 2 · "))
        XCTAssertTrue(setTitle.contains("2"))

        let blank = TopShelfEntry(id: "3", title: "  ", subtitle: "", artworkURL: nil)
        XCTAssertFalse(TopShelfLayout.title(for: blank, locale: locale).trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func testDurationText() {
        XCTAssertNil(TopShelfLayout.durationText(0, locale: locale))
        XCTAssertNil(TopShelfLayout.durationText(.nan, locale: locale))
        XCTAssertNotNil(TopShelfLayout.durationText(20, locale: locale))
        XCTAssertNotEqual(TopShelfLayout.durationText(3_600, locale: locale), TopShelfLayout.durationText(60, locale: locale))
    }

    // MARK: - URLs

    func testURLRoundTrip() {
        XCTAssertEqual(TopShelfStore.route(from: TopShelfStore.playURL(trackId: "42")), .track(id: "42", shelf: nil, position: nil))
        XCTAssertEqual(
            TopShelfStore.route(from: TopShelfStore.playURL(trackId: "42", shelf: "likes", at: 95.7)),
            .track(id: "42", shelf: "likes", position: 95)
        )
        XCTAssertEqual(TopShelfStore.route(from: TopShelfStore.playURL(trackId: "42", at: 0.4)), .track(id: "42", shelf: nil, position: nil))
        XCTAssertEqual(TopShelfStore.route(from: TopShelfStore.trackURL(trackId: "42")), .trackDetails(id: "42"))
        XCTAssertEqual(TopShelfStore.route(from: TopShelfStore.playlistURL(id: "p")), .playlist(id: "p", play: false))
        XCTAssertEqual(TopShelfStore.route(from: TopShelfStore.playlistURL(id: "p", play: true)), .playlist(id: "p", play: true))
        let urn = "soundcloud:system-playlists:artist-stations:123"
        XCTAssertEqual(TopShelfStore.route(from: TopShelfStore.mixURL(urn: urn)), .mix(urn: urn))
        XCTAssertEqual(TopShelfStore.route(from: TopShelfStore.homeURL()), .home)
        XCTAssertEqual(TopShelfStore.route(from: TopShelfStore.signInURL()), .signIn)
    }

    func testRejectsForeignAndIncompleteURLs() {
        XCTAssertNil(TopShelfStore.route(from: URL(string: "https://sounding.forbes.red/play?track=1")!))
        XCTAssertNil(TopShelfStore.route(from: URL(string: "soundingtv://play")!))
        XCTAssertNil(TopShelfStore.route(from: URL(string: "soundingtv://play?track=")!))
        XCTAssertNil(TopShelfStore.route(from: URL(string: "soundingtv://unknown?id=1")!))
        XCTAssertEqual(TopShelfStore.route(from: URL(string: "SoundingTV://Play?track=5")!), .track(id: "5", shelf: nil, position: nil))
    }

    func testOnlyAccountRoutesWaitForSignIn() {
        XCTAssertFalse(TopShelfStore.Route.home.needsAccount)
        XCTAssertFalse(TopShelfStore.Route.signIn.needsAccount)
        XCTAssertTrue(TopShelfStore.Route.trackDetails(id: "1").needsAccount)
        XCTAssertTrue(TopShelfStore.Route.mix(urn: "u").needsAccount)
    }

    // MARK: - Artwork

    func testArtworkAsksForTheLargestReliableVariant() {
        let large = URL(string: "https://i1.sndcdn.com/artworks-abc-large.jpg")
        XCTAssertEqual(TopShelfStore.artwork(large)?.absoluteString, "https://i1.sndcdn.com/artworks-abc-t500x500.jpg")
        let other = URL(string: "https://example.com/a-large.jpg")
        XCTAssertEqual(TopShelfStore.artwork(other), other)
        XCTAssertNil(TopShelfStore.artwork(nil))
    }

    func testArtworkFileNamesAreStableAcrossSizeVariants() {
        let small = URL(string: "https://i1.sndcdn.com/artworks-abc-large.jpg")!
        let big = URL(string: "https://i1.sndcdn.com/artworks-abc-t500x500.jpg")!
        let other = URL(string: "https://i1.sndcdn.com/artworks-xyz-t500x500.jpg")!
        XCTAssertEqual(TopShelfArtwork.fileName(for: small), TopShelfArtwork.fileName(for: big))
        XCTAssertNotEqual(TopShelfArtwork.fileName(for: big), TopShelfArtwork.fileName(for: other))
        XCTAssertTrue(TopShelfArtwork.fileName(for: big).hasSuffix(".jpg"))
    }

    // MARK: - Snapshot

    func testDecodesVersionTwoSnapshots() throws {
        let json = """
        {"version":2,"isSignedIn":true,"generatedAt":0,"sections":[{"kind":"recents","title":"Recently Played","entries":[
          {"id":"1","title":"T","subtitle":"A","progress":1.7,"shape":"square","playActionURL":"soundingtv://play?track=1"}
        ]}]}
        """
        let snapshot = try XCTUnwrap(TopShelfStore.decode(Data(json.utf8)))
        let entry = try XCTUnwrap(snapshot.section(kind: TopShelfStore.recentsKind)?.entries.first)
        XCTAssertEqual(entry.kind, .track)
        XCTAssertNil(entry.duration)
        XCTAssertNil(entry.playedAt)
        XCTAssertEqual(entry.progress, 1)
    }

    func testSnapshotRoundTripsAndComparesContentOnly() throws {
        let recents = TopShelfSection(kind: TopShelfStore.recentsKind, title: "Recently Played", entries: [
            track("1", duration: 3_600, progress: 0.3, playedAt: now),
        ])
        let original = snapshot([recents])
        let data = try XCTUnwrap(TopShelfStore.encode(original))
        let decoded = try XCTUnwrap(TopShelfStore.decode(data))
        XCTAssertEqual(decoded, original)

        var later = original
        later.generatedAt = now.addingTimeInterval(60)
        XCTAssertTrue(later.hasSameContent(as: original))
        later.isSignedIn = false
        XCTAssertFalse(later.hasSameContent(as: original))
    }
}
