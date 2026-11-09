import XCTest
@testable import SoundingTV

final class SoundingSnapshotTests: XCTestCase {
    private let anchorDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, duration: TimeInterval? = 240, isMix: Bool = false) -> SoundingSnapshot.Item {
        SoundingSnapshot.Item(
            kind: .track,
            id: id,
            title: "Track \(id)",
            subtitle: "Artist \(id)",
            artworkURL: URL(string: "https://i1.sndcdn.com/artworks-\(id)-t500x500.jpg"),
            duration: duration,
            isMix: isMix
        )
    }

    private func populated() -> SoundingSnapshot {
        SoundingSnapshot(
            generatedAt: anchorDate,
            nowPlaying: SoundingSnapshot.NowPlaying(
                item: item("1", duration: 3_600, isMix: true),
                anchor: SoundingSnapshot.PositionAnchor(position: 120, anchoredAt: anchorDate, rate: 1),
                isPlaying: true,
                collectionID: "playlist-9",
                queueIndex: 2,
                queueCount: 10
            ),
            lastMix: SoundingSnapshot.Resume(
                item: item("1", duration: 3_600, isMix: true),
                position: 120,
                collectionID: "playlist-9",
                savedAt: anchorDate
            ),
            recents: [item("1", duration: 3_600, isMix: true), item("2"), item("3")]
        )
    }

    func testRoundTripPreservesEverything() throws {
        let snapshot = populated()
        let data = try SoundingSnapshotStore.encode(snapshot)
        let decoded = try SoundingSnapshotStore.decode(data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.version, SoundingSnapshot.currentVersion)
    }

    func testFileRoundTripAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(SoundingSnapshotStore.fileName)

        XCTAssertNil(SoundingSnapshotStore.load(from: fileURL))
        XCTAssertTrue(SoundingSnapshotStore.save(populated(), to: fileURL))
        XCTAssertEqual(SoundingSnapshotStore.load(from: fileURL), populated())

        SoundingSnapshotStore.remove(at: fileURL)
        XCTAssertNil(SoundingSnapshotStore.load(from: fileURL))
    }

    func testDecodingToleratesNewerAndPartialPayloads() throws {
        let json = """
        {
          "version": 7,
          "generatedAt": 1800000000000,
          "futureField": {"anything": true},
          "nowPlaying": {"item": {"id": "x"}, "broken": true},
          "recents": [
            {"kind": "track", "id": "a", "title": "A"},
            {"kind": "podcast", "id": "b", "title": "B"},
            {"title": "missing id"}
          ]
        }
        """
        let decoded = try SoundingSnapshotStore.decode(Data(json.utf8))
        XCTAssertEqual(decoded.version, 7)
        XCTAssertNil(decoded.nowPlaying)
        XCTAssertNil(decoded.lastMix)
        XCTAssertEqual(decoded.recents.map(\.id), ["a", "b"])
        XCTAssertEqual(decoded.recents.last?.kind, .track)
        XCTAssertEqual(decoded.recents.first?.subtitle, "")
        XCTAssertFalse(decoded.recents[0].isMix)
    }

    func testEmptyObjectDecodesToEmptySnapshot() throws {
        let decoded = try SoundingSnapshotStore.decode(Data("{}".utf8))
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.generatedAt, .distantPast)
    }

    func testPositionAnchorAdvancesOnlyWhilePlayingAndClamps() {
        let playing = SoundingSnapshot.PositionAnchor(position: 100, anchoredAt: anchorDate, rate: 1)
        XCTAssertEqual(playing.position(at: anchorDate.addingTimeInterval(30), duration: 3_600), 130, accuracy: 0.001)
        XCTAssertEqual(playing.position(at: anchorDate.addingTimeInterval(10_000), duration: 3_600), 3_600, accuracy: 0.001)
        XCTAssertEqual(playing.position(at: anchorDate.addingTimeInterval(-50), duration: 3_600), 100, accuracy: 0.001)
        XCTAssertEqual(playing.startDate, anchorDate.addingTimeInterval(-100))

        let paused = SoundingSnapshot.PositionAnchor(position: 100, anchoredAt: anchorDate, rate: 0)
        XCTAssertEqual(paused.position(at: anchorDate.addingTimeInterval(600), duration: 3_600), 100, accuracy: 0.001)

        let invalid = SoundingSnapshot.PositionAnchor(position: .nan, anchoredAt: anchorDate, rate: -2)
        XCTAssertEqual(invalid.position, 0)
        XCTAssertEqual(invalid.rate, 0)
    }

    func testRecordingDedupesAndCaps() {
        var snapshot = SoundingSnapshot()
        for index in 0..<(SoundingSnapshot.recentsLimit + 5) {
            snapshot = snapshot.recording(item("\(index)"))
        }
        snapshot = snapshot.recording(item("10"))
        XCTAssertEqual(snapshot.recents.count, SoundingSnapshot.recentsLimit)
        XCTAssertEqual(snapshot.recents.first?.id, "10")
        XCTAssertEqual(snapshot.recents.filter { $0.id == "10" }.count, 1)
    }

    func testResumeTargetPrefersNowPlayingThenLastMix() {
        var snapshot = populated()
        snapshot.lastMix?.item = item("mix", duration: 4_000, isMix: true)
        XCTAssertEqual(snapshot.resumeTarget?.item.id, "1")
        XCTAssertEqual(snapshot.resumeTarget?.position ?? 0, 120, accuracy: 0.001)

        snapshot.nowPlaying = nil
        XCTAssertEqual(snapshot.resumeTarget?.item.id, "mix")
    }

    @MainActor
    func testPublisherTransitionsRecordRecentsAndLastMix() {
        let start = SoundingSnapshot()
        let paused = SoundingSnapshotPublisher.next(
            after: start,
            track: item("a"),
            position: 10,
            isPlaying: false,
            collectionID: nil,
            queueIndex: 0,
            queueCount: 1,
            at: anchorDate
        )
        XCTAssertEqual(paused.nowPlaying?.item.id, "a")
        XCTAssertEqual(paused.nowPlaying?.anchor.rate, 0)
        XCTAssertTrue(paused.recents.isEmpty)
        XCTAssertNil(paused.lastMix)

        let mix = item("m", duration: 5_400, isMix: true)
        let playing = SoundingSnapshotPublisher.next(
            after: paused,
            track: mix,
            position: 600,
            isPlaying: true,
            collectionID: "c",
            queueIndex: 1,
            queueCount: 4,
            at: anchorDate
        )
        XCTAssertEqual(playing.recents.map(\.id), ["m"])
        XCTAssertEqual(playing.lastMix?.item.id, "m")
        XCTAssertEqual(playing.lastMix?.position ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(playing.nowPlaying?.anchor.rate, 1)

        let stopped = SoundingSnapshotPublisher.next(
            after: playing,
            track: nil,
            position: 0,
            isPlaying: false,
            collectionID: nil,
            queueIndex: nil,
            queueCount: nil,
            at: anchorDate.addingTimeInterval(5)
        )
        XCTAssertNil(stopped.nowPlaying)
        XCTAssertEqual(stopped.lastMix?.item.id, "m")
        XCTAssertEqual(stopped.recents.map(\.id), ["m"])
        XCTAssertEqual(stopped.resumeTarget?.item.id, "m")
    }

    @MainActor
    func testPublisherClearRemovesTheSharedFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("publisher-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(SoundingSnapshotStore.fileName)
        SoundingSnapshotStore.save(populated(), to: fileURL)

        let publisher = SoundingSnapshotPublisher(fileURL: fileURL)
        XCTAssertEqual(publisher.current, populated())
        publisher.clear()
        XCTAssertTrue(publisher.current.isEmpty)
        XCTAssertNil(SoundingSnapshotStore.load(from: fileURL))
    }
}
