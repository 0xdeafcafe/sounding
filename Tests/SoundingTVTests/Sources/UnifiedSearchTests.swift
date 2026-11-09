import Foundation
import XCTest
@testable import SoundingTV

enum SearchFixtures {
    static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    static func user(_ id: String, _ name: String, followers: Int = 0) -> User {
        let json = """
        {"id": \(id), "username": "\(name)", "permalink": "u\(id)", "permalink_url": "https://soundcloud.com/u\(id)", "followers_count": \(followers)}
        """
        return try! decoder.decode(User.self, from: Data(json.utf8))
    }

    static func track(_ id: String, _ title: String, by artist: User = user("1", "Maren"), minutes: Int = 4, plays: Int = 0) -> Track {
        let json = """
        {
            "id": \(id),
            "title": "\(title)",
            "duration": \(minutes * 60_000),
            "playback_count": \(plays),
            "permalink_url": "https://soundcloud.com/x/\(id)",
            "created_at": "2025-09-01T12:00:00Z",
            "user": {"id": \(artist.id), "username": "\(artist.username)", "permalink": "\(artist.permalink)", "permalink_url": "\(artist.permalinkURL.absoluteString)"},
            "media": {"transcodings": [{"url": "https://api-v2.soundcloud.com/media/\(id)/stream", "duration": \(minutes * 60_000), "quality": "hq", "format": {"protocol": "progressive", "mime_type": "audio/mp4"}, "preset": "aac_256k"}]}
        }
        """
        return try! decoder.decode(Track.self, from: Data(json.utf8))
    }

    static func playlist(_ id: String, _ title: String, by artist: User = user("5", "me")) -> Playlist {
        let json = """
        {
            "id": \(id),
            "title": "\(title)",
            "permalink_url": "https://soundcloud.com/me/sets/\(id)",
            "created_at": "2025-09-01T12:00:00Z",
            "track_count": 3,
            "user": {"id": \(artist.id), "username": "\(artist.username)", "permalink": "\(artist.permalink)", "permalink_url": "\(artist.permalinkURL.absoluteString)"}
        }
        """
        return try! decoder.decode(Playlist.self, from: Data(json.utf8))
    }
}

final class SearchRankingTests: XCTestCase {
    private typealias F = SearchFixtures
    private let setMinimum: TimeInterval = 30 * 60

    func testScoreOrdersExactThenPrefixThenWordThenContains() {
        let exact = SearchRanking.score(query: "glass", primary: "Glass")
        let prefix = SearchRanking.score(query: "glass", primary: "Glass Horizon")
        let word = SearchRanking.score(query: "horizon", primary: "Glass Horizon")
        let contains = SearchRanking.score(query: "lass", primary: "Glass Horizon")
        let artist = SearchRanking.score(query: "maren", primary: "Wavelength", secondary: "Maren")
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, contains)
        XCTAssertGreaterThan(artist, word)
        XCTAssertEqual(SearchRanking.score(query: "zzz", primary: "Glass Horizon"), 0)
    }

    func testScoreIgnoresCaseDiacriticsAndExtraSpaces() {
        XCTAssertEqual(SearchRanking.score(query: "  rÓisín   murphy ", primary: "Roisin Murphy"), 1000)
    }

    func testMultiWordQueriesMatchAcrossTitleAndArtist() {
        XCTAssertGreaterThan(SearchRanking.score(query: "maren wavelength", primary: "Wavelength", secondary: "Maren"), 0)
        XCTAssertEqual(SearchRanking.score(query: "maren nothing", primary: "Wavelength", secondary: "Maren"), 0)
    }

    func testLibraryHitsCarryTheirReasonAndRankByMatch() {
        let maren = F.user("1", "Maren")
        let snapshot = SearchLibrarySnapshot(
            likes: [F.track("10", "Late Night Drive"), F.track("11", "Maren Forever", by: F.user("2", "Okari"))],
            downloads: [F.track("10", "Late Night Drive"), F.track("12", "Maren Dub")],
            playlists: [F.playlist("20", "Maren on Repeat")],
            followings: [maren]
        )
        let hits = SearchRanking.libraryHits(query: "maren", in: snapshot)
        XCTAssertEqual(hits.first?.hit, .artist(maren))
        XCTAssertEqual(hits.first?.reason, .followed)
        XCTAssertEqual(Set(hits.map(\.reason)), [.followed, .liked, .playlist, .downloaded])
        XCTAssertEqual(hits.filter { $0.id == "track:10" }.count, 1, "a track liked and downloaded appears once")
        XCTAssertEqual(hits.first(where: { $0.id == "track:10" })?.reason, .liked)
    }

    func testMergeBuildsEverySectionAndSplitsSetsByLength() {
        let okari = F.user("3", "Okari", followers: 50_000)
        let results = SearchRanking.merge(
            query: "okari",
            scope: .all,
            library: [SearchLibraryHit(hit: .track(F.track("10", "Okari Dub", by: okari)), reason: .liked)],
            remote: SearchRemoteResults(
                tracks: [F.track("10", "Okari Dub", by: okari), F.track("11", "Okari Live", by: okari), F.track("12", "Okari at Fabric", by: okari, minutes: 120)],
                artists: [okari, F.user("4", "Okari Tribute")],
                playlists: [F.playlist("20", "Best of Okari")]
            ),
            setMinimumDuration: setMinimum
        )
        XCTAssertEqual(results.topResult, .artist(okari), "an exact artist name is the top result")
        XCTAssertEqual(results.library.map(\.id), ["track:10"])
        XCTAssertEqual(results.tracks.map(\.id), ["11"], "library hits and the top result aren't repeated")
        XCTAssertEqual(results.sets.map(\.id), ["12"])
        XCTAssertEqual(results.artists.map(\.id), ["4"])
        XCTAssertEqual(results.playlists.map(\.id), ["20"])
    }

    func testLibraryWinsTheTopResultOverAnEqualRemoteMatch() {
        let liked = F.track("10", "Wavelength")
        let results = SearchRanking.merge(
            query: "wavelength",
            scope: .all,
            library: [SearchLibraryHit(hit: .track(liked), reason: .liked)],
            remote: SearchRemoteResults(tracks: [F.track("99", "Wavelength", plays: 2_000_000)], artists: [], playlists: []),
            setMinimumDuration: setMinimum
        )
        XCTAssertEqual(results.topResult, .track(liked))
        XCTAssertEqual(results.topReason, .liked)
        XCTAssertTrue(results.library.isEmpty)
        XCTAssertEqual(results.tracks.map(\.id), ["99"])
    }

    func testWeakMatchesNeverBecomeTheTopResult() {
        let results = SearchRanking.merge(
            query: "ave",
            scope: .all,
            library: [],
            remote: SearchRemoteResults(tracks: [F.track("1", "Wavelength")], artists: [], playlists: []),
            setMinimumDuration: setMinimum
        )
        XCTAssertNil(results.topResult)
        XCTAssertEqual(results.tracks.map(\.id), ["1"])
    }

    func testRemoteNonMatchesAreDroppedAndServerOrderBreaksTies() {
        let results = SearchRanking.merge(
            query: "drive",
            scope: .soundCloud,
            library: [],
            remote: SearchRemoteResults(
                tracks: [F.track("1", "Late Night Drive"), F.track("2", "Unrelated"), F.track("3", "Night Drive"), F.track("4", "Drive")],
                artists: nil,
                playlists: nil
            ),
            setMinimumDuration: setMinimum
        )
        XCTAssertEqual(results.topResult, .track(F.track("4", "Drive")))
        XCTAssertEqual(results.tracks.map(\.id), ["1", "3"])
    }

    func testScopesFilterSections() {
        let library = [SearchLibraryHit(hit: .track(F.track("10", "Okari Dub")), reason: .liked)]
        let remote = SearchRemoteResults(tracks: [F.track("11", "Okari Live")], artists: [F.user("3", "Okari")], playlists: [])
        let libraryOnly = SearchRanking.merge(query: "okari", scope: .library, library: library, remote: remote, setMinimumDuration: setMinimum)
        XCTAssertTrue(libraryOnly.tracks.isEmpty && libraryOnly.artists.isEmpty)
        XCTAssertEqual(libraryOnly.topResult?.id, "track:10")
        let soundCloudOnly = SearchRanking.merge(query: "okari", scope: .soundCloud, library: library, remote: remote, setMinimumDuration: setMinimum)
        XCTAssertTrue(soundCloudOnly.library.isEmpty)
        XCTAssertEqual(soundCloudOnly.topResult?.id, "artist:3")
    }

    func testTopResultsInterleaveKindsAfterTheTopResult() {
        let okari = F.user("3", "Okari", followers: 50_000)
        let results = SearchRanking.merge(
            query: "okari",
            scope: .soundCloud,
            library: [],
            remote: SearchRemoteResults(
                tracks: [F.track("11", "Okari Live", by: okari), F.track("12", "Okari Dub", by: okari), F.track("13", "Okari Remix", by: okari)],
                artists: [okari, F.user("4", "Okari Tribute")],
                playlists: [F.playlist("20", "Okari Essentials")]
            ),
            setMinimumDuration: setMinimum
        )
        let top = SearchRanking.topResults(results, query: "okari", setMinimumDuration: setMinimum)
        XCTAssertEqual(top.first?.id, "artist:3")
        XCTAssertEqual(Set(top.map(\.id)).count, top.count)
        let leading = top.prefix(4).map { SearchResultFilter.of($0.hit, setMinimumDuration: setMinimum) }
        XCTAssertGreaterThan(Set(leading).count, 2, "different kinds mix near the top")
    }

    func testFiltersSplitResultsByKind() {
        let results = SearchRanking.merge(
            query: "okari",
            scope: .soundCloud,
            library: [],
            remote: SearchRemoteResults(
                tracks: [F.track("11", "Okari Live"), F.track("12", "Okari at Fabric", minutes: 120)],
                artists: [],
                playlists: [F.playlist("20", "Okari Essentials")]
            ),
            setMinimumDuration: setMinimum
        )
        XCTAssertEqual(SearchRanking.items(results, filter: .tracks, query: "okari", setMinimumDuration: setMinimum).map(\.id), ["track:11"])
        XCTAssertEqual(SearchRanking.items(results, filter: .sets, query: "okari", setMinimumDuration: setMinimum).map(\.id), ["track:12"])
        XCTAssertEqual(SearchRanking.items(results, filter: .playlists, query: "okari", setMinimumDuration: setMinimum).map(\.id), ["playlist:20"])
        XCTAssertTrue(SearchRanking.items(results, filter: .albums, query: "okari", setMinimumDuration: setMinimum).isEmpty)
    }

    @MainActor
    func testRecentEntryKeepsTheTappedResult() {
        let playlist = F.playlist("20", "Okari Essentials")
        let entry = RecentSearchEntry(hit: .playlist(playlist))
        XCTAssertEqual(entry.id, "playlist:20")
        XCTAssertEqual(entry.query, "Okari Essentials")
        XCTAssertEqual(entry.hit, .playlist(playlist))
        let artist = RecentSearchEntry(hit: .artist(F.user("3", "Okari")))
        XCTAssertTrue(artist.isCircle)
        XCTAssertEqual(artist.hit?.id, "artist:3")
    }

    func testSuggestionsPreferRecentsAndPrefixesAndSkipTheQuery() {
        let snapshot = SearchLibrarySnapshot(playlists: [F.playlist("1", "Deep Focus")], followings: [F.user("2", "Deep Dish"), F.user("3", "Deep")])
        let suggestions = SearchRanking.suggestions(query: "deep", recents: ["deep house", "techno"], library: snapshot, results: .empty)
        XCTAssertEqual(suggestions, ["deep house", "Deep Dish", "Deep Focus"])
        XCTAssertTrue(SearchRanking.suggestions(query: " ", recents: ["deep"], library: snapshot, results: .empty).isEmpty)
    }
}

private actor FakeSearchRemote: SearchRemoteSource {
    private(set) var queries: [String] = []
    private var artistGate: CheckedContinuation<Void, Never>?
    private var holdsArtists: Bool
    private var fails: Bool
    let corpus: SearchRemoteResults

    init(corpus: SearchRemoteResults, holdsArtists: Bool = false, fails: Bool = false) {
        self.corpus = corpus
        self.holdsArtists = holdsArtists
        self.fails = fails
    }

    func releaseArtists() {
        holdsArtists = false
        artistGate?.resume()
        artistGate = nil
    }

    func tracks(_ query: String) async throws -> [Track] {
        queries.append(query)
        if fails { throw URLError(.notConnectedToInternet) }
        return corpus.tracks ?? []
    }

    func artists(_ query: String) async throws -> [User] {
        if holdsArtists { await withCheckedContinuation { artistGate = $0 } }
        if fails { throw URLError(.notConnectedToInternet) }
        return corpus.artists ?? []
    }

    func playlists(_ query: String) async throws -> [Playlist] {
        if fails { throw URLError(.notConnectedToInternet) }
        return corpus.playlists ?? []
    }
}

private struct FakeSearchLibrary: SearchLibrarySource {
    let snapshot: SearchLibrarySnapshot
    func snapshot(matching query: String) async -> SearchLibrarySnapshot { snapshot }
}

@MainActor
final class UnifiedSearchModelTests: XCTestCase {
    private typealias F = SearchFixtures
    private let okari = SearchFixtures.user("3", "Okari", followers: 50_000)

    private func makeModel(remote: FakeSearchRemote, debounce: Duration = .milliseconds(1)) -> UnifiedSearchModel {
        UnifiedSearchModel(
            library: FakeSearchLibrary(snapshot: SearchLibrarySnapshot(likes: [F.track("10", "Okari Dub", by: okari)])),
            remote: remote,
            debounce: debounce,
            recents: [],
            setMinimumDuration: { 30 * 60 }
        )
    }

    private func corpus() -> SearchRemoteResults {
        SearchRemoteResults(tracks: [F.track("11", "Okari Live", by: okari)], artists: [okari], playlists: [F.playlist("20", "Best of Okari")])
    }

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testLibraryResultsShowBeforeSoundCloudAnswers() async {
        let remote = FakeSearchRemote(corpus: corpus(), holdsArtists: true)
        let model = makeModel(remote: remote)
        model.query = "okari"
        await eventually { !model.results.library.isEmpty || model.results.topResult != nil }
        await eventually { !model.results.tracks.isEmpty }
        XCTAssertTrue(model.isRemoteLoading)
        XCTAssertTrue(model.results.artists.isEmpty && model.results.topResult != .artist(okari), "artists haven't arrived yet")
        await remote.releaseArtists()
        await model.waitForIdle()
        XCTAssertEqual(model.results.topResult, .artist(okari))
        XCTAssertFalse(model.isRemoteLoading)
        XCTAssertEqual(model.phase, .loaded)
    }

    func testTypingQuicklySendsOneSearch() async {
        let remote = FakeSearchRemote(corpus: corpus())
        let model = makeModel(remote: remote, debounce: .milliseconds(80))
        for prefix in ["o", "ok", "oka", "okar", "okari"] {
            model.query = prefix
            try? await Task.sleep(for: .milliseconds(5))
        }
        await model.waitForIdle()
        let queries = await remote.queries
        XCTAssertEqual(queries, ["okari"])
    }

    func testRepeatingAQueryUsesTheResultsAlreadyFetched() async {
        let remote = FakeSearchRemote(corpus: corpus())
        let model = makeModel(remote: remote)
        model.query = "okari"
        await model.waitForIdle()
        model.query = "okar"
        await model.waitForIdle()
        model.query = "okari"
        await model.waitForIdle()
        XCTAssertFalse(model.isRemoteLoading)
        XCTAssertEqual(model.results.topResult, .artist(okari))
        let queries = await remote.queries
        XCTAssertEqual(queries, ["okari", "okar"])
    }

    func testOneLetterSearchesStayLocal() async {
        let remote = FakeSearchRemote(corpus: corpus())
        let model = makeModel(remote: remote)
        model.query = "o"
        await model.waitForIdle()
        let queries = await remote.queries
        XCTAssertTrue(queries.isEmpty)
        XCTAssertEqual(model.phase, .loaded)
    }

    func testFailureWithLibraryResultsStillShowsThem() async {
        let model = makeModel(remote: FakeSearchRemote(corpus: corpus(), fails: true))
        model.query = "okari"
        await model.waitForIdle()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.results.topResult?.id, "track:10")
        model.query = "nothing here"
        await model.waitForIdle()
        XCTAssertEqual(model.phase, .failed)
    }

    func testScopeChangesRemergeWithoutRefetching() async {
        let remote = FakeSearchRemote(corpus: corpus())
        let model = makeModel(remote: remote)
        model.query = "okari"
        await model.waitForIdle()
        model.scope = .library
        XCTAssertTrue(model.results.artists.isEmpty && model.results.tracks.isEmpty)
        XCTAssertEqual(model.results.topResult?.id, "track:10")
        model.scope = .soundCloud
        XCTAssertEqual(model.results.topResult, .artist(okari))
        let queries = await remote.queries
        XCTAssertEqual(queries.count, 1)
    }

    func testRecentsAreDedupedNewestFirst() async {
        let model = makeModel(remote: FakeSearchRemote(corpus: corpus()))
        model.query = "okari"
        await model.waitForIdle()
        model.rememberCurrentQuery()
        model.query = "techno"
        model.rememberCurrentQuery()
        model.query = "OKARI"
        model.rememberCurrentQuery()
        XCTAssertEqual(model.recents.map(\.query), ["OKARI", "techno"])
        model.clearRecents()
        XCTAssertTrue(model.recents.isEmpty)
    }
}

@MainActor
final class LocalMusicSearchTests: XCTestCase {
    private typealias F = SearchFixtures

    private func localTrack(_ path: String, title: String, artist: String) -> Track {
        let folder = MusicFolder(
            id: "folder-1", name: "DJ Folder", bookmark: Data(), addedAt: Date(timeIntervalSince1970: 0),
            lastScannedAt: nil, files: []
        )
        let entry = LocalMusicFileEntry(
            relativePath: path, fileSize: 1_024, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: title, artist: artist, album: nil, genre: "House",
            duration: 245, hasArtwork: false, isDownloaded: true
        )
        return LocalMusicLibrary.makeTrack(
            entry: entry, folder: folder, root: URL(fileURLWithPath: "/Music/DJ Folder"),
            artworkDirectory: URL(fileURLWithPath: "/tmp")
        )!
    }

    func testLocalTracksAreFilteredToTheQuery() {
        let neon = localTrack("Neon Weather.flac", title: "Neon Weather", artist: "Maya Sol")
        let water = localTrack("Open Water.mp3", title: "Open Water", artist: "Low Sun")

        XCTAssertEqual(SearchRanking.localTracks([water, neon], matching: "neon").map(\.id), [neon.id])
        XCTAssertEqual(SearchRanking.localTracks([water, neon], matching: "maya").map(\.id), [neon.id])
        XCTAssertTrue(SearchRanking.localTracks([water, neon], matching: "garage").isEmpty)
    }

    func testLocalTracksAppearInLibraryHitsWithTheirOwnReason() {
        let neon = localTrack("Neon Weather.flac", title: "Neon Weather", artist: "Maya Sol")
        let liked = F.track("10", "Neon Lights")
        let snapshot = SearchLibrarySnapshot(likes: [liked], local: [neon])

        let hits = SearchRanking.libraryHits(query: "neon", in: snapshot)

        XCTAssertEqual(hits.first { $0.hit.track?.id == neon.id }?.reason, .local)
        XCTAssertEqual(hits.first { $0.hit.track?.id == liked.id }?.reason, .liked)
        XCTAssertEqual(SearchLibraryReason.local.title, LocalMusicLibrary.displayName)
        XCTAssertTrue(["Files", "On This Mac"].contains(SearchLibraryReason.local.title))
    }

    func testLocalOnlyMatchBecomesTheTopResult() {
        let neon = localTrack("Neon Weather.flac", title: "Neon Weather", artist: "Maya Sol")
        let library = SearchRanking.libraryHits(query: "Neon Weather", in: SearchLibrarySnapshot(local: [neon]))

        let results = SearchRanking.merge(
            query: "Neon Weather", scope: .all, library: library,
            remote: SearchRemoteResults(tracks: [], artists: [], playlists: []), setMinimumDuration: 1800
        )

        XCTAssertEqual(results.topResult?.track?.id, neon.id)
        XCTAssertEqual(results.topReason, .local)
    }

    func testUndownloadedLocalTrackHasNoDuration() {
        let folder = MusicFolder(
            id: "folder-1", name: "DJ Folder", bookmark: Data(), addedAt: Date(timeIntervalSince1970: 0),
            lastScannedAt: nil, files: []
        )
        let entry = LocalMusicFileEntry(
            relativePath: "Copper Wire.mp3", fileSize: 1_024, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Copper Wire", artist: "Maya Sol", album: nil, genre: nil,
            duration: 0, hasArtwork: false, isDownloaded: false
        )
        let pending = LocalMusicLibrary.makeTrack(entry: entry, folder: folder, root: nil, artworkDirectory: URL(fileURLWithPath: "/tmp"))!
        let ready = localTrack("Neon Weather.flac", title: "Neon Weather", artist: "Maya Sol")

        XCTAssertTrue(pending.isAwaitingLocalMetadata)
        XCTAssertEqual(pending.formattedDuration, "—")
        XCTAssertFalse(ready.isAwaitingLocalMetadata)
        XCTAssertEqual(ready.formattedDuration, "4:05")
    }
}
