import XCTest
@testable import SoundingTV

@MainActor
final class LocalMusicTrackTests: XCTestCase {
    private let folder = MusicFolder(
        id: "folder-1", name: "DJ Folder", bookmark: Data(), addedAt: Date(timeIntervalSince1970: 0),
        lastScannedAt: nil, files: []
    )

    private func entry(_ path: String, artist: String? = "Maya Sol", duration: TimeInterval = 245.5) -> LocalMusicFileEntry {
        LocalMusicFileEntry(
            relativePath: path, fileSize: 1_024, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Neon Weather", artist: artist, album: nil, genre: "House",
            duration: duration, hasArtwork: false, isDownloaded: true
        )
    }

    func testLocalTrackCarriesItsSourceAndPlaysFromTheFile() throws {
        let root = URL(fileURLWithPath: "/Music/DJ Folder", isDirectory: true)
        let track = try XCTUnwrap(LocalMusicLibrary.makeTrack(
            entry: entry("Crate/Neon Weather.flac"), folder: folder, root: root,
            artworkDirectory: URL(fileURLWithPath: "/tmp")
        ))

        XCTAssertTrue(track.isLocal)
        XCTAssertEqual(track.source, .local(LocalTrackFile(folderID: "folder-1", relativePath: "Crate/Neon Weather.flac")))
        XCTAssertEqual(track.title, "Neon Weather")
        XCTAssertEqual(track.user.displayName, "Maya Sol")
        XCTAssertEqual(track.genre, "House")
        XCTAssertEqual(track.duration, 245.5, accuracy: 0.01)
        XCTAssertEqual(track.streamURL?.path, "/Music/DJ Folder/Crate/Neon Weather.flac")
        XCTAssertEqual(track.mixSource?.codec, .lossless)
        XCTAssertTrue(LocalTrackFile.isLocalTrackID(track.id))
    }

    func testLocalTrackSurvivesTheQueuePersistenceRoundTrip() throws {
        let track = try XCTUnwrap(LocalMusicLibrary.makeTrack(
            entry: entry("One.mp3", artist: nil), folder: folder, root: nil,
            artworkDirectory: URL(fileURLWithPath: "/tmp")
        ))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(Track.self, from: encoder.encode(track))

        XCTAssertEqual(decoded.id, track.id)
        XCTAssertEqual(decoded.localFile, track.localFile)
        XCTAssertEqual(decoded.user.displayName, "DJ Folder")
    }

    func testSoundCloudTracksStaySoundCloud() {
        let track = VisualFixtures.tracks[0]
        XCTAssertEqual(track.source, .soundCloud)
        XCTAssertFalse(track.isLocal)
        XCTAssertFalse(LocalTrackFile.isLocalTrackID(track.id))
    }
}
