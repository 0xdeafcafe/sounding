import XCTest
@testable import SoundingTV

private struct OfflineError: Error {}

private actor CallLog {
    private(set) var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
}

private struct FakeRemote: SoundingRemoteCatalog {
    var tracksByID: [String: TrackEntity] = [:]
    var searchResults: [TrackEntity] = []
    var artistsByID: [String: ArtistEntity] = [:]
    var artistResults: [ArtistEntity] = []
    var playlistsByID: [String: PlaylistEntity] = [:]
    var playlistResults: [PlaylistEntity] = []
    var mine: [PlaylistEntity] = []
    var offline = false
    let log = CallLog()

    func tracks(ids: [String]) async throws -> [TrackEntity] {
        await log.record("tracks:\(ids.joined(separator: ","))")
        if offline { throw OfflineError() }
        return ids.compactMap { tracksByID[$0] }
    }

    func searchTracks(_ query: String, limit: Int) async throws -> [TrackEntity] {
        await log.record("searchTracks:\(query)")
        if offline { throw OfflineError() }
        return searchResults
    }

    func artists(ids: [String]) async throws -> [ArtistEntity] {
        await log.record("artists:\(ids.joined(separator: ","))")
        if offline { throw OfflineError() }
        return ids.compactMap { artistsByID[$0] }
    }

    func searchArtists(_ query: String, limit: Int) async throws -> [ArtistEntity] {
        if offline { throw OfflineError() }
        return artistResults
    }

    func playlists(ids: [String]) async throws -> [PlaylistEntity] {
        if offline { throw OfflineError() }
        return ids.compactMap { playlistsByID[$0] }
    }

    func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistEntity] {
        if offline { throw OfflineError() }
        return playlistResults
    }

    func myPlaylists(limit: Int) async throws -> [PlaylistEntity] {
        if offline { throw OfflineError() }
        return mine
    }
}

private struct FakeLocal: SoundingLocalCatalog {
    var stored: SoundingSnapshot?
    var likes: [Track] = []
    var setlists: [GeneratedSetlist] = []

    func snapshot() async -> SoundingSnapshot? { stored }

    func likedTracks(ids: [String]) async -> [Track] {
        likes.filter { ids.contains($0.id) }
    }

    func searchLikedTracks(_ query: String, limit: Int) async -> [Track] {
        Array(likes.filter { $0.title.localizedCaseInsensitiveContains(query) }.prefix(limit))
    }

    func recentLikedTracks(limit: Int) async -> [Track] {
        Array(likes.prefix(limit))
    }

    func savedSetlists() async -> [GeneratedSetlist] { setlists }
}

final class SoundingEntityQueryTests: XCTestCase {
    private static let fixtureDecoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    private static func track(_ id: String, title: String, userID: String = "1", username: String = "maren") -> Track {
        let json = """
        {
            "id": \(id),
            "title": "\(title)",
            "permalink_url": "https://soundcloud.com/\(username)/\(id)",
            "created_at": "2025-09-01T12:00:00Z",
            "artwork_url": "https://i1.sndcdn.com/artworks-\(id)-large.jpg",
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
                        "duration": 3600000,
                        "quality": "hq",
                        "format": { "protocol": "progressive", "mime_type": "audio/mp4" },
                        "preset": "aac_256k"
                    }
                ]
            }
        }
        """
        return try! fixtureDecoder.decode(Track.self, from: Data(json.utf8))
    }

    private static func remoteTrack(_ id: String) -> TrackEntity {
        TrackEntity(id: id, title: "Remote \(id)", artistName: "Remote Artist")
    }

    private static func setlist(_ id: String, title: String, labels: [String], updatedAt: TimeInterval) -> GeneratedSetlist {
        GeneratedSetlist(
            trackId: id,
            trackTitle: title,
            duration: 3_600,
            segments: labels.enumerated().map { offset, label in
                SetlistSegment(
                    id: "\(id)-\(offset)",
                    startSeconds: TimeInterval(offset * 300),
                    observedAtSeconds: TimeInterval(offset * 300),
                    artist: nil,
                    title: label,
                    version: nil,
                    source: .uploaderTracklist,
                    confidence: 1,
                    evidence: nil,
                    shazamId: nil,
                    soundCloudTrackId: nil,
                    isUserEdited: false
                )
            },
            isSaved: true,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private func snapshot(recentIDs: [String]) -> SoundingSnapshot {
        SoundingSnapshot(
            generatedAt: Date(),
            recents: recentIDs.map {
                SoundingSnapshot.Item(kind: .track, id: $0, title: "Recent \($0)", subtitle: "Snapshot Artist")
            }
        )
    }

    // MARK: Tracks

    func testTrackLookupUsesSnapshotAndLikesBeforeTheAPIAndKeepsOrder() async throws {
        let remote = FakeRemote(tracksByID: ["30": Self.remoteTrack("30")])
        let local = FakeLocal(stored: snapshot(recentIDs: ["10"]), likes: [Self.track("20", title: "Liked Twenty")])
        let query = TrackEntityQuery(catalog: LiveSoundingEntityCatalog(remote: remote, local: local))

        let result = try await query.entities(for: ["30", "10", "20", "10"])

        XCTAssertEqual(result.map(\.id), ["30", "10", "20"])
        XCTAssertEqual(result.map(\.title), ["Remote 30", "Recent 10", "Liked Twenty"])
        let calls = await remote.log.calls
        XCTAssertEqual(calls, ["tracks:30"])
    }

    func testTrackLookupSkipsTheAPIWhenEverythingIsLocal() async throws {
        let remote = FakeRemote()
        let local = FakeLocal(stored: snapshot(recentIDs: ["10"]), likes: [Self.track("20", title: "Liked")])
        let query = TrackEntityQuery(catalog: LiveSoundingEntityCatalog(remote: remote, local: local))

        let result = try await query.entities(for: ["20", "10"])

        XCTAssertEqual(result.map(\.id), ["20", "10"])
        let calls = await remote.log.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testTrackLookupFallsBackToLocalHitsWhenOffline() async throws {
        let remote = FakeRemote(offline: true)
        let local = FakeLocal(likes: [Self.track("20", title: "Liked")])
        let query = TrackEntityQuery(catalog: LiveSoundingEntityCatalog(remote: remote, local: local))

        let partial = try await query.entities(for: ["20", "99"])
        XCTAssertEqual(partial.map(\.id), ["20"])

        do {
            _ = try await query.entities(for: ["99"])
            XCTFail("Expected the offline error when nothing resolves locally")
        } catch is OfflineError {
        }
    }

    func testTrackSearchPutsLikesFirstAndDedupes() async throws {
        let remote = FakeRemote(searchResults: [Self.remoteTrack("5"), Self.remoteTrack("1")])
        let local = FakeLocal(likes: [Self.track("1", title: "Low Tide 041"), Self.track("2", title: "Harbour Lights")])
        let query = TrackEntityQuery(catalog: LiveSoundingEntityCatalog(remote: remote, local: local))

        let result = try await query.entities(matching: "  low tide ")

        XCTAssertEqual(result.map(\.id), ["1", "5"])
        XCTAssertEqual(result.first?.title, "Low Tide 041")
        let calls = await remote.log.calls
        XCTAssertEqual(calls, ["searchTracks:low tide"])
    }

    func testTrackSearchIgnoresBlankQueriesAndSurvivesOffline() async throws {
        let remote = FakeRemote(offline: true)
        let local = FakeLocal(likes: [Self.track("1", title: "Low Tide 041")])
        let query = TrackEntityQuery(catalog: LiveSoundingEntityCatalog(remote: remote, local: local))

        let blank = try await query.entities(matching: "   ")
        XCTAssertTrue(blank.isEmpty)

        let offline = try await query.entities(matching: "tide")
        XCTAssertEqual(offline.map(\.id), ["1"])
    }

    func testTrackSuggestionsLeadWithRecentsThenLikes() async throws {
        let local = FakeLocal(
            stored: snapshot(recentIDs: ["3", "1"]),
            likes: [Self.track("1", title: "One"), Self.track("2", title: "Two")]
        )
        let query = TrackEntityQuery(catalog: LiveSoundingEntityCatalog(remote: FakeRemote(), local: local))

        let result = try await query.suggestedEntities()

        XCTAssertEqual(result.map(\.id), ["3", "1", "2"])
    }

    // MARK: Artists

    func testArtistsResolveFromLikedUploadersBeforeTheAPI() async throws {
        let remote = FakeRemote(artistsByID: ["77": ArtistEntity(id: "77", name: "Okari", username: "okari")])
        let local = FakeLocal(likes: [
            Self.track("1", title: "A", userID: "11", username: "maren"),
            Self.track("2", title: "B", userID: "11", username: "maren"),
            Self.track("3", title: "C", userID: "12", username: "teodora"),
        ])
        let catalog = LiveSoundingEntityCatalog(remote: remote, local: local)

        let resolved = try await ArtistEntityQuery(catalog: catalog).entities(for: ["12", "77", "11"])
        XCTAssertEqual(resolved.map(\.id), ["12", "77", "11"])
        let calls = await remote.log.calls
        XCTAssertEqual(calls, ["artists:77"])

        let suggested = try await ArtistEntityQuery(catalog: catalog).suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), ["11", "12"])

        let searched = try await ArtistEntityQuery(catalog: catalog).entities(matching: "TEO")
        XCTAssertEqual(searched.map(\.id), ["12"])
    }

    // MARK: Playlists

    func testPlaylistSearchPrefersMyOwnPlaylists() async throws {
        let mine = PlaylistEntity(id: "p1", title: "Sunday Set", ownerName: "Me", ownerID: "me", trackCount: 12)
        let other = PlaylistEntity(id: "p2", title: "Sunday Morning", ownerName: "Someone", trackCount: 3)
        let remote = FakeRemote(playlistResults: [other, mine], mine: [mine])
        let query = PlaylistEntityQuery(catalog: LiveSoundingEntityCatalog(remote: remote, local: FakeLocal()))

        let result = try await query.entities(matching: "sunday")
        XCTAssertEqual(result.map(\.id), ["p1", "p2"])

        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), ["likes", "p1"])
    }

    // MARK: Setlists

    func testSetlistsMatchByTitleOrTracklistEntry() async throws {
        let local = FakeLocal(setlists: [
            Self.setlist("100", title: "Low Tide 041", labels: ["Lanterns", "Undertow"], updatedAt: 2),
            Self.setlist("200", title: "Glasshouse Session 7", labels: ["Low Light"], updatedAt: 1),
        ])
        let query = SetlistEntityQuery(catalog: LiveSoundingEntityCatalog(remote: FakeRemote(offline: true), local: local))

        let byTitle = try await query.entities(matching: "glasshouse")
        XCTAssertEqual(byTitle.map(\.id), ["200"])

        let byEntry = try await query.entities(matching: "undertow")
        XCTAssertEqual(byEntry.map(\.id), ["100"])

        let both = try await query.entities(matching: "low")
        XCTAssertEqual(both.map(\.id), ["100", "200"])

        let byID = try await query.entities(for: ["200", "missing", "100"])
        XCTAssertEqual(byID.map(\.id), ["200", "100"])
        XCTAssertEqual(byID.last?.entryCount, 2)
    }

    // MARK: Library cache

    @MainActor
    func testDeviceLocalCatalogReadsLikesFromTheLibraryCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("entity-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LibraryCache(directory: directory)
        let encoder = LikesSyncEngine.makeEncoder()
        let tracks = [Self.track("1", title: "Low Tide 041"), Self.track("2", title: "Harbour Lights")]
        await cache.upsertLikes(tracks.enumerated().map { offset, track in
            LibraryCache.LikeIndexRow(
                id: track.id,
                payload: try! encoder.encode(track),
                likedAtMillis: Int64(1_000 - offset),
                title: track.title,
                artist: track.user.displayName
            )
        }, generation: 1)

        let local = DeviceLocalCatalog(library: cache)

        let byID = await local.likedTracks(ids: ["2", "404"])
        XCTAssertEqual(byID.map(\.id), ["2"])

        let searched = await local.searchLikedTracks("harbour", limit: 5)
        XCTAssertEqual(searched.map(\.title), ["Harbour Lights"])

        let recent = await local.recentLikedTracks(limit: 1)
        XCTAssertEqual(recent.map(\.id), ["1"])
    }

    func testEntityMappingFromModelsAndSnapshotItems() {
        let track = Self.track("42", title: "Undertow", userID: "9", username: "koji")
        let entity = TrackEntity(track)
        XCTAssertEqual(entity.id, "42")
        XCTAssertEqual(entity.title, "Undertow")
        XCTAssertEqual(entity.artistName, track.user.displayName)
        XCTAssertEqual(entity.artistID, "9")
        XCTAssertEqual(entity.durationSeconds ?? 0, 3_600, accuracy: 0.001)
        XCTAssertEqual(entity.artworkURL, track.largeArtworkURL)

        XCTAssertNil(TrackEntity(SoundingSnapshot.Item(kind: .playlist, id: "p", title: "P")))
        let fromItem = TrackEntity(SoundingSnapshot.Item(kind: .track, id: "7", title: "Seven", subtitle: "Artist", duration: 60))
        XCTAssertEqual(fromItem?.artistName, "Artist")
        XCTAssertEqual(fromItem?.durationSeconds, 60)

        let setlist = SetlistEntity(Self.setlist("5", title: "Low\\tTide", labels: ["A", "B", "C"], updatedAt: 0))
        XCTAssertEqual(setlist.title, "Low Tide")
        XCTAssertEqual(setlist.entryCount, 3)
    }
}
