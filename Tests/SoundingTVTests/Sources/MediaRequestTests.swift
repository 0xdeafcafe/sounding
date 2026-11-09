import Intents
import XCTest
@testable import SoundingTV

private struct OfflineError: Error {}

private actor CallLog {
    private(set) var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
}

private struct StubRemote: SoundingRemoteCatalog {
    var trackResults: [TrackEntity] = []
    var artistResults: [ArtistEntity] = []
    var playlistResults: [PlaylistEntity] = []
    var offline = false
    let log = CallLog()

    func tracks(ids: [String]) async throws -> [TrackEntity] {
        await log.record("tracks")
        if offline { throw OfflineError() }
        return trackResults.filter { ids.contains($0.id) }
    }

    func searchTracks(_ query: String, limit: Int) async throws -> [TrackEntity] {
        await log.record("searchTracks:\(query)")
        if offline { throw OfflineError() }
        return trackResults
    }

    func artists(ids: [String]) async throws -> [ArtistEntity] {
        await log.record("artists")
        return []
    }

    func searchArtists(_ query: String, limit: Int) async throws -> [ArtistEntity] {
        await log.record("searchArtists:\(query)")
        if offline { throw OfflineError() }
        return artistResults
    }

    func playlists(ids: [String]) async throws -> [PlaylistEntity] {
        await log.record("playlists")
        if offline { throw OfflineError() }
        return playlistResults.filter { ids.contains($0.id) }
    }

    func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistEntity] {
        await log.record("searchPlaylists:\(query)")
        if offline { throw OfflineError() }
        return playlistResults
    }

    func myPlaylists(limit: Int) async throws -> [PlaylistEntity] {
        await log.record("myPlaylists")
        return []
    }
}

private struct StubLocal: SoundingLocalCatalog {
    var stored: SoundingSnapshot?
    var likes: [Track] = []
    var setlists: [GeneratedSetlist] = []
    var playlists: [Playlist] = []
    var following: [User] = []

    func snapshot() async -> SoundingSnapshot? { stored }

    func likedTracks(ids: [String]) async -> [Track] {
        likes.filter { ids.contains($0.id) }
    }

    func searchLikedTracks(_ query: String, limit: Int) async -> [Track] {
        let terms = MediaText.normalized(query).split(separator: " ")
        return Array(likes.filter { track in
            let haystack = MediaText.normalized("\(track.title) \(track.user.displayName)")
            return terms.allSatisfy { haystack.contains($0) }
        }.prefix(limit))
    }

    func recentLikedTracks(limit: Int) async -> [Track] { Array(likes.prefix(limit)) }
    func savedSetlists() async -> [GeneratedSetlist] { setlists }
    func likesCount() async -> Int { likes.count }
    func cachedPlaylists() async -> [Playlist] { playlists }
    func followedArtists() async -> [User] { following }
}

@MainActor
private final class RecordingSink: IntentPlaybackSink {
    enum Call: Equatable {
        case play(trackID: String, context: [String], collection: String?)
        case shuffled(context: [String], collection: String?)
    }

    var calls: [Call] = []
    var refusal: String?

    func play(_ track: Track, in context: [Track], collectionId: String?) async -> String? {
        calls.append(.play(trackID: track.id, context: context.map(\.id), collection: collectionId))
        return refusal
    }

    func play(shuffled tracks: [Track], collectionId: String?) async -> String? {
        calls.append(.shuffled(context: tracks.map(\.id), collection: collectionId))
        return refusal
    }
}

@MainActor
private final class StubPlaybackSource: IntentPlaybackSource {
    var isSignedIn = true
    var likes: [Track] = []
    var tracksByID: [String: Track] = [:]
    var playlistTracks: [String: [Track]] = [:]
    var artistTracks: [String: [Track]] = [:]
    var related: [String: [Track]] = [:]
    var unplayable: Set<String> = []

    func likedTracks(limit: Int) async -> [Track] { Array(likes.prefix(limit)) }

    func track(id: String) async throws -> Track {
        guard let track = tracksByID[id] else { throw OfflineError() }
        return track
    }

    func playlistTracks(id: String) async throws -> [Track] {
        guard let tracks = playlistTracks[id] else { throw OfflineError() }
        return tracks
    }

    func artistTracks(id: String, limit: Int) async throws -> [Track] {
        guard let tracks = artistTracks[id] else { throw OfflineError() }
        return tracks
    }

    func relatedTracks(seedTrackID: String, limit: Int) async throws -> [Track] {
        guard let tracks = related[seedTrackID] else { throw OfflineError() }
        return tracks
    }

    func isPlayable(_ track: Track) -> Bool { !unplayable.contains(track.id) }
}

final class MediaRequestTests: XCTestCase {
    private static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    private static func user(_ id: String, username: String) -> User {
        let json = """
        {"id": \(id), "username": "\(username)", "permalink": "\(username)", "permalink_url": "https://soundcloud.com/\(username)"}
        """
        return try! decoder.decode(User.self, from: Data(json.utf8))
    }

    private static func track(_ id: String, title: String, minutes: Int = 4, userID: String = "1", username: String = "maren") -> Track {
        let json = """
        {
            "id": \(id),
            "title": "\(title)",
            "duration": \(minutes * 60_000),
            "permalink_url": "https://soundcloud.com/\(username)/\(id)",
            "created_at": "2025-09-01T12:00:00Z",
            "user": {
                "id": \(userID),
                "username": "\(username)",
                "permalink": "\(username)",
                "permalink_url": "https://soundcloud.com/\(username)"
            },
            "media": {
                "transcodings": [
                    {
                        "url": "https://api-v2.soundcloud.com/media/\(id)/stream",
                        "duration": \(minutes * 60_000),
                        "quality": "hq",
                        "format": { "protocol": "progressive", "mime_type": "audio/mp4" },
                        "preset": "aac_256k"
                    }
                ]
            }
        }
        """
        return try! decoder.decode(Track.self, from: Data(json.utf8))
    }

    private static func playlist(_ id: String, title: String) -> Playlist {
        let json = """
        {
            "id": \(id),
            "title": "\(title)",
            "permalink_url": "https://soundcloud.com/me/sets/\(id)",
            "created_at": "2025-09-01T12:00:00Z",
            "track_count": 3,
            "user": {"id": 5, "username": "me", "permalink": "me", "permalink_url": "https://soundcloud.com/me"}
        }
        """
        return try! decoder.decode(Playlist.self, from: Data(json.utf8))
    }

    private static func setlist(_ id: String, title: String) -> GeneratedSetlist {
        GeneratedSetlist(trackId: id, trackTitle: title, duration: 3_600, segments: [], isSaved: true, updatedAt: Date())
    }

    private static func snapshot(nowPlaying: SoundingSnapshot.Item? = nil, recents: [SoundingSnapshot.Item] = []) -> SoundingSnapshot {
        SoundingSnapshot(
            generatedAt: Date(),
            nowPlaying: nowPlaying.map {
                SoundingSnapshot.NowPlaying(item: $0, anchor: .init(position: 0, anchoredAt: Date(), rate: 1), isPlaying: true)
            },
            recents: recents
        )
    }

    private func resolver(local: StubLocal, remote: StubRemote = StubRemote(), budget: Int = 1, allowed: Bool = true) -> MediaRequestResolver {
        MediaRequestResolver(local: local, remote: remote, remoteBudget: budget, remoteAllowed: { allowed })
    }

    // MARK: Parsing

    func testParsesLikesPhrasesAndShuffle() {
        for phrase in ["my likes", "Play my likes", "my liked tracks", "liked songs", "music I like", "my favourites", "My Library"] {
            let request = MediaRequest.parse(phrase)
            XCTAssertEqual(request.kind, .likes, phrase)
            XCTAssertFalse(request.shuffle, phrase)
        }
        let shuffled = MediaRequest.parse("Shuffle my likes")
        XCTAssertEqual(shuffled.kind, .likes)
        XCTAssertTrue(shuffled.shuffle)
        XCTAssertTrue(MediaRequest.parse("play my likes on shuffle").shuffle)
        XCTAssertEqual(MediaRequest.parse("play my likes on Sounding").kind, .likes)
    }

    func testParsesTheSetILikedLast() {
        for phrase in ["the set I liked last", "my last liked set", "the last set I liked", "latest liked mix", "the mix I just liked"] {
            let request = MediaRequest.parse(phrase)
            XCTAssertEqual(request.kind, .set, phrase)
            XCTAssertEqual(request.order, .newest, phrase)
            XCTAssertTrue(request.mine, phrase)
            XCTAssertNil(request.query, phrase)
        }
    }

    func testParsesSomethingLikeThis() {
        for phrase in ["something like this", "Play more like this", "something similar"] {
            let request = MediaRequest.parse(phrase)
            XCTAssertEqual(request.kind, .station, phrase)
            XCTAssertNil(request.query, phrase)
        }
        let seeded = MediaRequest.parse("something like Glue")
        XCTAssertEqual(seeded.kind, .station)
        XCTAssertEqual(seeded.query, "glue")
    }

    func testParsesKindsAndArtists() {
        let byArtist = MediaRequest.parse("Glue by Bicep")
        XCTAssertEqual(byArtist.kind, .any)
        XCTAssertEqual(byArtist.query, "glue")
        XCTAssertEqual(byArtist.artist, "bicep")

        let playlist = MediaRequest.parse("my Sunday Morning playlist")
        XCTAssertEqual(playlist.kind, .playlist)
        XCTAssertEqual(playlist.query, "sunday morning")
        XCTAssertTrue(playlist.mine)

        let set = MediaRequest.parse("the Boiler Room DJ set")
        XCTAssertEqual(set.kind, .set)
        XCTAssertEqual(set.query, "boiler room")

        let plain = MediaRequest.parse("Low Tide 041")
        XCTAssertEqual(plain.kind, .any)
        XCTAssertEqual(plain.query, "low tide 041")
        XCTAssertNil(plain.artist)

        XCTAssertEqual(MediaRequest.parse("Up All Night").query, "up all night")
        XCTAssertEqual(MediaRequest.parse("Set It Off").kind, .any)
        XCTAssertEqual(MediaRequest.parse("Set It Off").query, "set it off")
        XCTAssertEqual(MediaRequest.parse("Glue (Original Mix)").query, "glue original mix")
        XCTAssertEqual(MediaRequest.parse("play me some techno").query, "techno")
        XCTAssertEqual(MediaRequest.parse("put on the playlist Sunday").kind, .playlist)
    }

    func testScoresExactAboveContainsAboveTokens() {
        XCTAssertEqual(MediaText.score("Low Tide 041", query: "low tide 041"), 100)
        XCTAssertGreaterThan(MediaText.score("Low Tide 041", query: "low tide"), MediaText.score("Ebb and Low Tide", query: "low tide"))
        XCTAssertGreaterThan(MediaText.score("Ebb and Low Tide", query: "low tide"), MediaText.score("Tide Low", query: "low tide"))
        XCTAssertEqual(MediaText.score("Harbour Lights", query: "low tide"), 0)
        XCTAssertEqual(MediaText.normalized("Fred again.. — Boiler Room: London"), "fred again boiler room london")
        XCTAssertEqual(MediaText.score("Señor Coconut", query: "senor coconut"), 100)
    }

    func testTargetIdentifiersRoundTrip() {
        let targets: [MediaTarget] = [.likes, .track("1"), .playlist("2"), .artist("3"), .station(seedTrackID: "4")]
        for target in targets {
            XCTAssertEqual(MediaTarget(identifier: target.identifier), target)
        }
        XCTAssertEqual(MediaTarget.playlist(MediaTarget.likesID).identifier, "likes")
        XCTAssertNil(MediaTarget(identifier: "track:"))
        XCTAssertNil(MediaTarget(identifier: "album:9"))
    }

    // MARK: Resolution

    func testLikesResolveWithoutTheNetwork() async throws {
        let remote = StubRemote()
        let resolution = try await resolver(local: StubLocal(), remote: remote).resolve(MediaRequest.parse("shuffle my likes"))
        XCTAssertEqual(resolution.target, .likes)
        XCTAssertTrue(resolution.shuffle)
        let calls = await remote.log.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testTheSetILikedLastIsTheNewestLongLike() async throws {
        let local = StubLocal(likes: [
            Self.track("1", title: "Short One"),
            Self.track("2", title: "Sunrise Set", minutes: 95),
            Self.track("3", title: "Older Set", minutes: 120),
        ])
        let resolution = try await resolver(local: local).resolve(MediaRequest.parse("the set I liked last"))
        XCTAssertEqual(resolution.target, .track("2"))
        XCTAssertEqual(resolution.title, "Sunrise Set")
        XCTAssertEqual(resolution.source, .likes)

        do {
            _ = try await resolver(local: StubLocal(likes: [Self.track("1", title: "Short")])).resolve(MediaRequest(kind: .set, mine: true, order: .newest))
            XCTFail("Expected noLikedSets")
        } catch let error as MediaRequestError {
            XCTAssertEqual(error, .noLikedSets)
        }
    }

    func testSomethingLikeThisSeedsFromNowPlaying() async throws {
        let local = StubLocal(stored: Self.snapshot(nowPlaying: .init(kind: .track, id: "42", title: "Undertow", subtitle: "Koji")))
        let resolution = try await resolver(local: local).resolve(MediaRequest.parse("something like this"))
        XCTAssertEqual(resolution.target, .station(seedTrackID: "42"))
        XCTAssertEqual(resolution.source, .nowPlaying)

        do {
            _ = try await resolver(local: StubLocal()).resolve(MediaRequest(kind: .station))
            XCTFail("Expected nothingPlaying")
        } catch let error as MediaRequestError {
            XCTAssertEqual(error, .nothingPlaying)
        }
    }

    func testSomethingLikeANamedTrackSeedsFromThatTrack() async throws {
        let local = StubLocal(likes: [Self.track("7", title: "Glue", userID: "9", username: "bicep")])
        let resolution = try await resolver(local: local).resolve(MediaRequest.parse("something like Glue"))
        XCTAssertEqual(resolution.target, .station(seedTrackID: "7"))
    }

    func testStrongLocalMatchSkipsSearch() async throws {
        let remote = StubRemote(trackResults: [TrackEntity(id: "99", title: "Low Tide 041 (Remix)", artistName: "Someone")])
        let local = StubLocal(likes: [Self.track("1", title: "Low Tide 041"), Self.track("2", title: "Harbour Lights")])
        let resolution = try await resolver(local: local, remote: remote).resolve(MediaRequest.parse("play Low Tide 041"))
        XCTAssertEqual(resolution.target, .track("1"))
        XCTAssertEqual(resolution.source, .likes)
        let calls = await remote.log.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSearchIsTheFallbackAndSpendsOneRequest() async throws {
        let remote = StubRemote(trackResults: [
            TrackEntity(id: "50", title: "Glasshouse Session 7", artistName: "Teodora"),
            TrackEntity(id: "51", title: "Glasshouse Session 8", artistName: "Teodora"),
        ])
        let local = StubLocal(likes: [Self.track("1", title: "Harbour Lights")])
        let resolution = try await resolver(local: local, remote: remote).resolve(MediaRequest.parse("glasshouse session 7"))
        XCTAssertEqual(resolution.target, .track("50"))
        XCTAssertEqual(resolution.source, .search)
        let calls = await remote.log.calls
        XCTAssertEqual(calls, ["searchTracks:glasshouse session 7"])
    }

    func testNoBudgetOrTrafficStopMeansNoSearch() async throws {
        let remote = StubRemote(trackResults: [TrackEntity(id: "50", title: "Glasshouse", artistName: "Teodora")])
        for (budget, allowed) in [(0, true), (1, false)] {
            do {
                _ = try await resolver(local: StubLocal(), remote: remote, budget: budget, allowed: allowed).resolve(MediaRequest.parse("glasshouse"))
                XCTFail("Expected notFound")
            } catch let error as MediaRequestError {
                XCTAssertEqual(error, .notFound)
            }
        }
        let calls = await remote.log.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testMyRequestsNeverSearchSoundCloud() async throws {
        let remote = StubRemote(playlistResults: [PlaylistEntity(id: "p9", title: "Sunday Morning", ownerName: "Someone")])
        do {
            _ = try await resolver(local: StubLocal(), remote: remote).resolve(MediaRequest.parse("my Sunday Morning playlist"))
            XCTFail("Expected notFound")
        } catch {}
        let calls = await remote.log.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testArtistsResolveFromLikesAndFollowingBeforeSearch() async throws {
        let remote = StubRemote(artistResults: [ArtistEntity(id: "77", name: "Okari", username: "okari")])
        let local = StubLocal(
            likes: [Self.track("1", title: "Glue", userID: "11", username: "Bicep")],
            following: [Self.user("12", username: "Teodora")]
        )

        let liked = try await resolver(local: local, remote: remote).resolve(MediaRequest(kind: .artist, query: "bicep"))
        XCTAssertEqual(liked.target, .artist("11"))
        let followed = try await resolver(local: local, remote: remote).resolve(MediaRequest.parse("Teodora"))
        XCTAssertEqual(followed.target, .artist("12"))
        XCTAssertEqual(followed.source, .following)
        var calls = await remote.log.calls
        XCTAssertTrue(calls.isEmpty)

        let searched = try await resolver(local: local, remote: remote).resolve(MediaRequest(kind: .artist, query: "okari"))
        XCTAssertEqual(searched.target, .artist("77"))
        calls = await remote.log.calls
        XCTAssertEqual(calls, ["searchArtists:okari"])
    }

    func testTitleByArtistPicksTheRightUploader() async throws {
        let local = StubLocal(likes: [
            Self.track("1", title: "Glue", userID: "11", username: "Someone Else"),
            Self.track("2", title: "Glue", userID: "12", username: "Bicep"),
        ])
        let resolution = try await resolver(local: local).resolve(MediaRequest.parse("Glue by Bicep"))
        XCTAssertEqual(resolution.target, .track("2"))
    }

    func testPlaylistsHistoryAndSetlistsResolveLocally() async throws {
        let remote = StubRemote()
        let local = StubLocal(
            stored: Self.snapshot(recents: [.init(kind: .track, id: "300", title: "Harbour Lights", subtitle: "Maren")]),
            setlists: [Self.setlist("400", title: "Glasshouse Session 7")],
            playlists: [Self.playlist("200", title: "Sunday Morning")]
        )
        let playlist = try await resolver(local: local, remote: remote).resolve(MediaRequest.parse("Sunday Morning playlist"))
        XCTAssertEqual(playlist.target, .playlist("200"))
        XCTAssertEqual(playlist.source, .playlists)

        let history = try await resolver(local: local, remote: remote).resolve(MediaRequest.parse("Harbour Lights"))
        XCTAssertEqual(history.target, .track("300"))
        XCTAssertEqual(history.source, .history)

        let setlist = try await resolver(local: local, remote: remote).resolve(MediaRequest.parse("Glasshouse Session 7"))
        XCTAssertEqual(setlist.target, .track("400"))
        XCTAssertEqual(setlist.source, .setlists)

        let calls = await remote.log.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: SiriKit mapping

    func testPlayMediaSearchMapping() {
        XCTAssertNil(MediaRequest(search: nil, shuffle: false))

        let song = MediaRequest(search: INMediaSearch(mediaType: .song, sortOrder: .unknown, mediaName: "Glue", artistName: "Bicep", albumName: nil, genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil), shuffle: false)
        XCTAssertEqual(song?.kind, .track)
        XCTAssertEqual(song?.query, "glue")
        XCTAssertEqual(song?.artist, "Bicep")

        let artist = MediaRequest(search: INMediaSearch(mediaType: .artist, sortOrder: .unknown, mediaName: nil, artistName: "Bicep", albumName: nil, genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil), shuffle: false)
        XCTAssertEqual(artist?.kind, .artist)
        XCTAssertEqual(artist?.query, "Bicep")

        let mine = MediaRequest(search: INMediaSearch(mediaType: .music, sortOrder: .unknown, mediaName: nil, artistName: nil, albumName: nil, genreNames: nil, moodNames: nil, releaseDate: nil, reference: .my, mediaIdentifier: nil), shuffle: true)
        XCTAssertEqual(mine?.kind, .likes)
        XCTAssertEqual(mine?.shuffle, true)

        let likesByName = MediaRequest(search: INMediaSearch(mediaType: .playlist, sortOrder: .unknown, mediaName: "my likes", artistName: nil, albumName: nil, genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil), shuffle: false)
        XCTAssertEqual(likesByName?.kind, .likes)

        let similar = MediaRequest(search: INMediaSearch(mediaType: .station, sortOrder: .unknown, mediaName: nil, artistName: nil, albumName: nil, genreNames: nil, moodNames: nil, releaseDate: nil, reference: .currentlyPlaying, mediaIdentifier: nil), shuffle: false)
        XCTAssertEqual(similar?.kind, .station)
        XCTAssertNil(similar?.query)

        let lastSet = MediaRequest(search: INMediaSearch(mediaType: .unknown, sortOrder: .unknown, mediaName: "the set I liked last", artistName: nil, albumName: nil, genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil), shuffle: false)
        XCTAssertEqual(lastSet?.kind, .set)
        XCTAssertEqual(lastSet?.order, .newest)

        let resume = MediaRequest(search: INMediaSearch(mediaType: .unknown, sortOrder: .unknown, mediaName: nil, artistName: nil, albumName: nil, genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil), shuffle: false)
        XCTAssertNil(resume)
    }

    // MARK: Playback mapping

    @MainActor
    private func withPlayback(_ source: StubPlaybackSource, _ body: (RecordingSink) async throws -> Void) async rethrows {
        let previousSink = IntentPlayback.sink
        let previousSource = IntentPlayback.source
        let sink = RecordingSink()
        IntentPlayback.sink = sink
        IntentPlayback.source = source
        defer {
            IntentPlayback.sink = previousSink
            IntentPlayback.source = previousSource
        }
        try await body(sink)
    }

    @MainActor
    func testLikesPlayInOrderOrShuffledAsTheLikesCollection() async throws {
        let source = StubPlaybackSource()
        source.likes = [Self.track("1", title: "A"), Self.track("2", title: "B"), Self.track("3", title: "C")]
        source.unplayable = ["2"]
        try await withPlayback(source) { sink in
            try await IntentPlayback.play(MediaResolution(target: .likes, title: "Likes", source: .likes))
            try await IntentPlayback.play(MediaResolution(target: .likes, title: "Likes", source: .likes, shuffle: true))
            try await IntentPlayback.playPlaylist(id: MediaTarget.likesID)
            XCTAssertEqual(sink.calls, [
                .play(trackID: "1", context: ["1", "3"], collection: "likes"),
                .shuffled(context: ["1", "3"], collection: "likes"),
                .play(trackID: "1", context: ["1", "3"], collection: "likes"),
            ])
        }
    }

    @MainActor
    func testTracksPlaylistsArtistsAndStationsReachTheSink() async throws {
        let source = StubPlaybackSource()
        source.tracksByID = ["5": Self.track("5", title: "Set", minutes: 90)]
        source.playlistTracks = ["p1": [Self.track("10", title: "X"), Self.track("11", title: "Y")]]
        source.artistTracks = ["a1": [Self.track("20", title: "Z")]]
        source.related = ["5": [Self.track("5", title: "Seed"), Self.track("30", title: "Near"), Self.track("31", title: "Nearer")]]
        try await withPlayback(source) { sink in
            try await IntentPlayback.play(MediaResolution(target: .track("5"), title: "", source: .likes))
            try await IntentPlayback.play(MediaResolution(target: .playlist("p1"), title: "", source: .playlists, shuffle: true))
            try await IntentPlayback.play(MediaResolution(target: .artist("a1"), title: "", source: .following))
            try await IntentPlayback.play(MediaResolution(target: .station(seedTrackID: "5"), title: "", source: .nowPlaying))
            XCTAssertEqual(sink.calls, [
                .play(trackID: "5", context: ["5"], collection: nil),
                .shuffled(context: ["10", "11"], collection: "p1"),
                .play(trackID: "20", context: ["20"], collection: nil),
                .play(trackID: "30", context: ["30", "31"], collection: nil),
            ])
        }
    }

    @MainActor
    func testPlaybackFailuresAreSpokenErrors() async throws {
        let source = StubPlaybackSource()
        source.isSignedIn = false
        try await withPlayback(source) { sink in
            do {
                try await IntentPlayback.playLikes(shuffle: false)
                XCTFail("Expected signedOut")
            } catch PlaybackIntentError.signedOut {}

            source.isSignedIn = true
            do {
                try await IntentPlayback.playLikes(shuffle: false)
                XCTFail("Expected noLikes")
            } catch let error as MediaRequestError {
                XCTAssertEqual(error, .noLikes)
            }

            source.tracksByID = ["9": Self.track("9", title: "Preview Only")]
            source.unplayable = ["9"]
            do {
                try await IntentPlayback.playTrack(id: "9")
                XCTFail("Expected notEntitled")
            } catch PlaybackIntentError.notEntitled {}

            source.unplayable = []
            sink.refusal = "Playback is controlled by the lead device."
            do {
                try await IntentPlayback.playTrack(id: "9")
                XCTFail("Expected refusal")
            } catch PlaybackIntentError.refused(let message) {
                XCTAssertEqual(message, "Playback is controlled by the lead device.")
            }
            XCTAssertEqual(sink.calls.count, 1)
        }
    }

    // MARK: Entity queries

    func testEntityQueriesUnderstandLikesAndTheLastLikedSet() async throws {
        let remote = StubRemote(offline: true)
        let local = StubLocal(likes: [Self.track("1", title: "Short"), Self.track("2", title: "Sunrise Set", minutes: 95)])
        let catalog = LiveSoundingEntityCatalog(remote: remote, local: local)

        let likes = try await PlaylistEntityQuery(catalog: catalog).entities(matching: "my likes")
        XCTAssertEqual(likes.map(\.id), ["likes"])
        XCTAssertEqual(likes.first?.trackCount, 2)

        let byID = try await PlaylistEntityQuery(catalog: catalog).entities(for: ["likes"])
        XCTAssertEqual(byID.map(\.title), ["Likes"])

        let suggested = try await PlaylistEntityQuery(catalog: catalog).suggestedEntities()
        XCTAssertEqual(suggested.first?.id, "likes")

        let lastSet = try await TrackEntityQuery(catalog: catalog).entities(matching: "the set I liked last")
        XCTAssertEqual(lastSet.map(\.id), ["2"])

        let calls = await remote.log.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("search") })
    }

    func testExactLocalTitleSkipsRemoteSearchInEntityQueries() async throws {
        let remote = StubRemote(trackResults: [TrackEntity(id: "99", title: "Other", artistName: "X")])
        let local = StubLocal(likes: [Self.track("1", title: "Harbour Lights")])
        let result = try await TrackEntityQuery(catalog: LiveSoundingEntityCatalog(remote: remote, local: local)).entities(matching: "harbour lights")
        XCTAssertEqual(result.map(\.id), ["1"])
        let calls = await remote.log.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: Spotlight ledger

    func testSpotlightLedgerIndexesOnlyWhatChanged() {
        var ledger = SpotlightLibraryLedger()
        let likes = PlaylistEntity.likes(trackCount: 2)
        let sunday = PlaylistEntity(id: "p1", title: "Sunday", ownerName: "Me", trackCount: 3)

        let first = ledger.plan(likeIDs: ["1", "2"], playlists: [likes, sunday])
        XCTAssertEqual(first.likesToIndex, ["1", "2"])
        XCTAssertEqual(first.playlistsToIndex, ["likes", "p1"])

        ledger.likeIDs = ["1", "2"]
        ledger.playlistDigests = [
            "likes": SpotlightLibraryLedger.playlistDigest(likes),
            "p1": SpotlightLibraryLedger.playlistDigest(sunday),
        ]
        let renamed = PlaylistEntity(id: "p1", title: "Sunday Best", ownerName: "Me", trackCount: 3)
        let second = ledger.plan(likeIDs: ["2", "3"], playlists: [likes, renamed])
        XCTAssertEqual(second.likesToIndex, ["3"])
        XCTAssertEqual(second.likesToRemove, ["1"])
        XCTAssertEqual(second.playlistsToIndex, ["p1"])
        XCTAssertEqual(second.playlistsToRemove, [])

        let third = ledger.plan(likeIDs: [], playlists: [])
        XCTAssertEqual(third.likesToRemove, ["1", "2"])
        XCTAssertEqual(third.playlistsToRemove, ["likes", "p1"])
    }
}
