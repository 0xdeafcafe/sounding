#if DEBUG
import Foundation
import XCTest
@testable import SoundingTV

final class SoundingDataTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SoundingDataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Format

    func testContainerRoundTripsAndRejectsForeignData() throws {
        let body = Data(String(repeating: "sounding ", count: 200).utf8)
        let wrapped = SoundingDataFormat.wrap(body, kind: .journalSegment)
        XCTAssertLessThan(wrapped.count, body.count)
        XCTAssertEqual(SoundingDataFormat.kind(of: wrapped), .journalSegment)
        XCTAssertEqual(try SoundingDataFormat.unwrap(wrapped, expecting: .journalSegment), body)
        XCTAssertThrowsError(try SoundingDataFormat.unwrap(wrapped, expecting: .analysisRecord))
        XCTAssertThrowsError(try SoundingDataFormat.unwrap(Data("{\"a\":1}".utf8), expecting: .journalSegment))
        var future = wrapped
        future[future.startIndex + 4] = 0xFF
        XCTAssertThrowsError(try SoundingDataFormat.unwrap(future, expecting: .journalSegment))
        let tiny = SoundingDataFormat.wrap(Data("x".utf8), kind: .manifest)
        XCTAssertEqual(try SoundingDataFormat.unwrap(tiny, expecting: .manifest), Data("x".utf8))
    }

    func testPackedJSONRoundTripKeepsScalarsExactAndPacksArrays() throws {
        let samples = (0..<1_800).map { Float(sin(Double($0) / 37) * 0.5 + 0.5) }
        let beats = (0..<700).map { 0.231 + Double($0) * 0.46875 }
        let object: [String: Any] = [
            "name": "Track ünïcode",
            "flag": true,
            "off": false,
            "nothing": NSNull(),
            "count": 42,
            "negative": -7,
            "bpm": 127.98765432,
            "date": 784_111_111.123456,
            "samples": samples,
            "beats": beats,
            "bytes": (0..<32).map { $0 * 8 },
            "ids": [9_007_199_254_740_000, -3, 12, 4, 5, 6, 7, 8],
            "short": [0.123456789, 1.5],
            "nested": [["a": 1], ["b": [1, 2, 3]]],
        ]
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let packed = try PackedJSON.pack(json)
        let back = try XCTUnwrap(try JSONSerialization.jsonObject(with: try PackedJSON.unpack(packed)) as? [String: Any])

        XCTAssertEqual(back["name"] as? String, "Track ünïcode")
        XCTAssertEqual(back["flag"] as? Bool, true)
        XCTAssertEqual(back["off"] as? Bool, false)
        XCTAssertTrue(back["nothing"] is NSNull)
        XCTAssertEqual(back["count"] as? Int, 42)
        XCTAssertEqual(back["negative"] as? Int, -7)
        XCTAssertEqual(back["bpm"] as? Double, 127.98765432)
        XCTAssertEqual(back["date"] as? Double, 784_111_111.123456)
        XCTAssertEqual(back["bytes"] as? [Int], (0..<32).map { $0 * 8 })
        XCTAssertEqual(back["ids"] as? [Int], [9_007_199_254_740_000, -3, 12, 4, 5, 6, 7, 8])
        XCTAssertEqual(back["short"] as? [Double], [0.123456789, 1.5])

        let backSamples = try XCTUnwrap(back["samples"] as? [Double])
        XCTAssertEqual(backSamples.count, samples.count)
        for (original, decoded) in zip(samples, backSamples) {
            XCTAssertEqual(Double(original), decoded, accuracy: 5e-4)
        }
        let backBeats = try XCTUnwrap(back["beats"] as? [Double])
        for (original, decoded) in zip(beats, backBeats) {
            XCTAssertEqual(original, decoded, accuracy: 1e-4)
        }
        XCTAssertLessThan(packed.count, json.count / 3)

        let canonical = try XCTUnwrap(PackedJSON.canonical(json))
        XCTAssertEqual(PackedJSON.canonical(canonical), canonical)
    }

    func testPrecisionRules() {
        XCTAssertEqual(PackedJSON.precision(for: Array(repeating: 0.5, count: 64)), .half)
        XCTAssertEqual(PackedJSON.precision(for: Array(repeating: 0.5, count: 63)), .single)
        XCTAssertEqual(PackedJSON.precision(for: Array(repeating: 2.5, count: 64)), .single)
        XCTAssertEqual(PackedJSON.precision(for: [784_111_111.5] + Array(repeating: 0.5, count: 9)), .double)
        XCTAssertEqual(PackedJSON.precision(for: [.nan] + Array(repeating: 0.5, count: 9)), .double)
    }

    func testHalfFloatConversion() {
        for value: Float in [0, 1, -1, 0.5, 2, 65504, 0.000061035156, 0.33325195] {
            XCTAssertEqual(HalfFloat.float(HalfFloat.bits(value)), value, accuracy: abs(value) * 1e-3 + 1e-7)
        }
        XCTAssertEqual(HalfFloat.bits(1), 0x3C00)
        XCTAssertEqual(HalfFloat.bits(-2), 0xC000)
        XCTAssertTrue(HalfFloat.float(HalfFloat.bits(.infinity)).isInfinite)
        XCTAssertTrue(HalfFloat.float(HalfFloat.bits(.nan)).isNaN)
        XCTAssertEqual(HalfFloat.float(HalfFloat.bits(1e-6)), 1e-6, accuracy: 1e-7)
    }

    // MARK: Analysis records

    private func record(trackId: String = "123", producedAt: Int64 = 1_000, producer: String = "A", samples: [Float] = [0.1, 0.2]) throws -> AnalysisDataRecord {
        let fingerprint = AnalyzedAudioFingerprint(durationMillis: 200_000, preset: "aac_160k", bitrate: 160, codec: "aac")
        let key = AnalysisCacheKey(trackId: trackId, engine: .soundCloudWaveform(), schemaVersion: 1, fingerprint: fingerprint)
        return AnalysisDataRecord(
            cacheKey: key.stableKey, trackId: trackId, engineName: key.engine.name, engineVersion: key.engine.version,
            schemaVersion: 1, durationMillis: 200_000, preset: "aac_160k", bitrate: 160, codec: "aac",
            payload: try JSONEncoder().encode(WaveformAnalysisPayload(samples: samples)),
            bpm: 124, keyWheelPosition: 8, keyMode: 0, genre: "house",
            producedAtMillis: producedAt, producerId: producer
        )
    }

    func testAnalysisRecordRoundTrip() throws {
        let samples = (0..<1_800).map { Float($0 % 97) / 97 }
        let original = try record(samples: samples)
        let decoded = try AnalysisDataFiles.decode(try AnalysisDataFiles.encode(original))
        XCTAssertEqual(decoded.cacheKey, original.cacheKey)
        XCTAssertEqual(decoded.key, original.key)
        XCTAssertEqual(decoded.bpm, 124)
        XCTAssertEqual(decoded.features.key, CamelotKey(wheelPosition: 8, mode: .minor))
        XCTAssertEqual(decoded.genre, "house")
        XCTAssertEqual(decoded.producedAtMillis, 1_000)
        let payload = try JSONDecoder().decode(WaveformAnalysisPayload.self, from: decoded.payload)
        XCTAssertEqual(payload.samples.count, samples.count)
        for (a, b) in zip(samples, payload.samples) { XCTAssertEqual(a, b, accuracy: 5e-4) }
        let again = try AnalysisDataFiles.decode(try AnalysisDataFiles.encode(decoded))
        XCTAssertEqual(again.payload, decoded.payload)
    }

    func testReportsSizePerAnalysedTrack() throws {
        let waveform = WaveformAnalysisPayload(samples: (0..<1_800).map { Float(abs(sin(Double($0) / 11))) * 0.9 })
        let waveformJSON = try JSONEncoder().encode(waveform)
        struct Beats: Codable { let beats: [Double]; let downbeats: [Double]; let bpm: Double; let confidence: Double }
        let beats = Beats(
            beats: (0..<720).map { 0.0421 + Double($0) * 60 / 124.03 },
            downbeats: (0..<180).map { 0.0421 + Double($0) * 240 / 124.03 },
            bpm: 124.03, confidence: 0.91
        )
        let beatsJSON = try JSONEncoder().encode(beats)
        struct Embedding: Codable { let vector: [Float] }
        let embedding = Embedding(vector: (0..<128).map { Float(cos(Double($0))) * 0.3 })
        let embeddingJSON = try JSONEncoder().encode(embedding)

        var before = 0
        var after = 0
        for (index, json) in [waveformJSON, beatsJSON, embeddingJSON].enumerated() {
            let item = AnalysisDataRecord(
                cacheKey: "k\(index)", trackId: "t", engineName: "e\(index)", engineVersion: 1, schemaVersion: 1,
                durationMillis: 360_000, preset: "aac_160k", bitrate: 160, codec: "aac", payload: json,
                bpm: nil, keyWheelPosition: nil, keyMode: nil, genre: nil, producedAtMillis: 1, producerId: "A"
            )
            before += json.count
            after += try AnalysisDataFiles.encode(item).count
        }
        print("Sounding Data size per analysed track: \(before) bytes as JSON rows, \(after) bytes packed")
        XCTAssertLessThan(after, before / 3)
    }

    func testConflictCopiesMergeToTheNewestRecord() throws {
        let root = directory.appendingPathComponent("Analysis", isDirectory: true)
        let older = try record(producedAt: 1_000, producer: "A")
        let newer = try record(producedAt: 2_000, producer: "B")
        let base = AnalysisDataFiles.url(for: older, in: root)
        try SoundingDataFiles.write(try AnalysisDataFiles.encode(older), to: base, presenter: nil)
        let stem = base.deletingPathExtension().lastPathComponent
        let iCloudCopy = base.deletingLastPathComponent().appendingPathComponent("\(stem) 2").appendingPathExtension("snda")
        let dropboxCopy = base.deletingLastPathComponent().appendingPathComponent("\(stem) (Alex's conflicted copy 2026-11-09)").appendingPathExtension("snda")
        try AnalysisDataFiles.encode(newer).write(to: iCloudCopy)
        try AnalysisDataFiles.encode(older).write(to: dropboxCopy)

        XCTAssertEqual(SoundingDataFiles.conflictBase(of: iCloudCopy)?.path, base.path)
        XCTAssertEqual(SoundingDataFiles.conflictBase(of: dropboxCopy)?.path, base.path)
        XCTAssertNil(SoundingDataFiles.conflictBase(of: base))

        let entries = SoundingDataFiles.resolveConflicts(
            in: SoundingDataFiles.files(in: root, extension: AnalysisDataFiles.fileExtension),
            merge: { AnalysisDataFiles.merge(current: $0, other: $1) }
        )
        XCTAssertEqual(entries.map(\.url.standardizedFileURL.path), [base.standardizedFileURL.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: iCloudCopy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropboxCopy.path))
        let winner = try AnalysisDataFiles.decode(Data(contentsOf: base))
        XCTAssertEqual(winner.producedAtMillis, 2_000)
        XCTAssertEqual(winner.producerId, "B")
    }

    // MARK: Journals

    private typealias Op = SoundingDataJournalOp<String>

    func testJournalMergeIsLastWriterWinsWithTombstonesAndClears() {
        let ops: [Op] = [
            Op(id: "a", at: 10, device: "mac", seq: 1, value: "a1"),
            Op(id: "a", at: 20, device: "ipad", seq: 1, value: "a2"),
            Op(id: "b", at: 10, device: "mac", seq: 2, value: "b1"),
            Op(id: "b", at: 15, device: "ipad", seq: 2, value: nil),
            Op(id: "c", at: 30, device: "mac", seq: 3, value: "c-mac"),
            Op(id: "c", at: 30, device: "ipad", seq: 9, value: "c-ipad"),
            Op(id: "a", at: 20, device: "ipad", seq: 1, value: "a2"),
        ]
        XCTAssertEqual(SoundingDataJournalMerge.merge(ops), ["a": "a2", "c": "c-mac"])
        XCTAssertEqual(SoundingDataJournalMerge.merge(ops.reversed()), ["a": "a2", "c": "c-mac"])

        let cleared = ops + [Op(id: "", at: 25, device: "ipad", seq: 3, value: nil, clear: true), Op(id: "d", at: 26, device: "mac", seq: 4, value: "d")]
        XCTAssertEqual(SoundingDataJournalMerge.merge(cleared), ["c": "c-mac", "d": "d"])

        let compacted = SoundingDataJournalMerge.compacted(cleared, now: 40)
        XCTAssertEqual(SoundingDataJournalMerge.merge(compacted), SoundingDataJournalMerge.merge(cleared))
        XCTAssertLessThan(compacted.count, cleared.count)
    }

    func testJournalsFromTwoDevicesMergeAndCompact() throws {
        let shared = directory.appendingPathComponent("Mix History", isDirectory: true)
        let mac = SoundingDataJournal<String>(directory: shared, device: "mac", compactAfter: 3)
        let iPad = SoundingDataJournal<String>(directory: shared, device: "ipad", compactAfter: 3)

        mac.put("one", "mac one")
        iPad.put("two", "ipad two")
        mac.put("three", "mac three")
        iPad.remove("one")
        mac.put("four", "mac four")
        mac.put("five", "mac five")
        mac.flush()
        iPad.flush()

        let expected = ["two": "ipad two", "three": "mac three", "four": "mac four", "five": "mac five"]
        XCTAssertEqual(mac.load(), expected)
        XCTAssertEqual(iPad.load(), expected)

        let macFiles = SoundingDataFiles.files(in: shared.appendingPathComponent("mac"), extension: "sndj")
        XCTAssertLessThanOrEqual(macFiles.count, 3)
        let iPadFiles = SoundingDataFiles.files(in: shared.appendingPathComponent("ipad"), extension: "sndj")
        XCTAssertEqual(iPadFiles.count, 2)

        let conflictCopy = iPadFiles[0].url.deletingLastPathComponent()
            .appendingPathComponent(iPadFiles[0].url.deletingPathExtension().lastPathComponent + " 2")
            .appendingPathExtension("sndj")
        try FileManager.default.copyItem(at: iPadFiles[0].url, to: conflictCopy)
        XCTAssertEqual(mac.load(), expected)

        iPad.clearAll()
        mac.put("six", "mac six")
        XCTAssertEqual(iPad.load(), ["six": "mac six"])
    }

    // MARK: Migration

    @MainActor
    func testMixHistoryMigratesFromTheOldFile() throws {
        let fileURL = directory.appendingPathComponent("mix-history.json")
        let fixture = MixHistoryStore.fixtureEntries()
        try JSONEncoder().encode(fixture).write(to: fileURL)

        let store = MixHistoryStore(fileURL: fileURL, library: SavedMixLibrary(), persistLibrary: { _ in })
        XCTAssertEqual(store.entries.map(\.id), fixture.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }.map(\.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("migrated").path))

        store.rateLatest(liked: true)
        let reopened = MixHistoryStore(fileURL: fileURL, library: SavedMixLibrary(), persistLibrary: { _ in })
        XCTAssertEqual(reopened.entries.map(\.id), store.entries.map(\.id))
        XCTAssertEqual(reopened.latest?.liked, true)

        reopened.clearHistory()
        XCTAssertTrue(MixHistoryStore(fileURL: fileURL, library: SavedMixLibrary(), persistLibrary: { _ in }).entries.isEmpty)
    }

    func testAnalysisCacheExportsOldRowsAndAnotherDeviceImportsThem() async throws {
        let firstIndex = directory.appendingPathComponent("IndexA", isDirectory: true)
        let secondIndex = directory.appendingPathComponent("IndexB", isDirectory: true)
        let dataRoot = directory.appendingPathComponent("Sounding Data/Analysis", isDirectory: true)
        let fingerprint = AnalyzedAudioFingerprint(durationMillis: 200_000, preset: "aac_160k", bitrate: 160, codec: "aac")
        let key = AnalysisCacheKey(trackId: "777", engine: .soundCloudWaveform(), schemaVersion: 1, fingerprint: fingerprint)
        let samples = (0..<400).map { Float($0) / 400 }

        let legacy = AnalysisCache(directory: firstIndex)
        _ = try await legacy.value(for: key, as: WaveformAnalysisPayload.self, compute: { WaveformAnalysisPayload(samples: samples) }) { _ in
            AnalysisFeatures(bpm: 126)
        }

        let mirror = AnalysisDataMirror(root: { dataRoot }, debounce: 0)
        let upgraded = AnalysisCache(directory: firstIndex, mirror: mirror)
        await upgraded.reconcileDataFolder()
        let files = SoundingDataFiles.files(in: dataRoot, extension: AnalysisDataFiles.fileExtension)
        XCTAssertEqual(files.count, 1)
        let exported = try AnalysisDataFiles.decode(Data(contentsOf: files[0].url))
        XCTAssertEqual(exported.cacheKey, key.stableKey)
        XCTAssertEqual(exported.bpm, 126)

        let otherDevice = AnalysisCache(directory: secondIndex, mirror: AnalysisDataMirror(root: { dataRoot }, debounce: 0))
        await otherDevice.reconcileDataFolder()
        let rows = await otherDevice.recallRows(forTrackIds: ["777"])
        XCTAssertEqual(rows["777"]?.first?.bpm, 126)
        let peeked = await otherDevice.peek(WaveformAnalysisPayload.self, for: key)
        let payload = try XCTUnwrap(peeked)
        XCTAssertEqual(payload.samples.count, samples.count)
        for (a, b) in zip(samples, payload.samples) { XCTAssertEqual(a, b, accuracy: 5e-4) }
    }
}
#endif
