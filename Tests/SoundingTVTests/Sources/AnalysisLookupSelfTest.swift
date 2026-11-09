import Foundation
import XCTest
@testable import SoundingTV

#if DEBUG

enum AnalysisLookupSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []
    }

    static func run(into report: inout Report) async {
        await testEveryLiveGenerationIsReadable(&report)
        await testGenreAndTempoMergeAcrossDifferentEngines(&report)
        await testPayloadShapeIsIrrelevant(&report)
        await testASchemaBumpDoesNotBlankExistingValues(&report)
        await testASupersededEngineVersionIsNotRead(&report)
        await testForeignFingerprintIsNotBorrowed(&report)
        await testMeasuredTempoBeatsATaggedOne(&report)
    }

    private static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    private static func track(id: String, title: String = "Fixture", durationSeconds: Double = 200) -> Track {
        let json = """
        {
            "id": \(id), "title": "\(title)", "description": null,
            "artwork_url": null, "waveform_url": null,
            "permalink_url": "https://soundcloud.com/example/\(id)",
            "playback_count": 0, "likes_count": 0, "reposts_count": 0,
            "created_at": "2024-09-01T12:00:00Z",
            "user": { "id": 1, "username": "example", "permalink": "example",
                      "permalink_url": "https://soundcloud.com/example" },
            "media": { "transcodings": [ {
                "url": "https://api-v2.soundcloud.com/media/example/\(id)/stream",
                "duration": \(Int(durationSeconds * 1000)), "quality": "hq",
                "format": { "protocol": "progressive", "mime_type": "audio/mp4" },
                "preset": "aac_256k"
            } ] }
        }
        """
        return try! decoder.decode(Track.self, from: Data(json.utf8))
    }

    private static func scratchCache() -> (AnalysisCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisLookupSelfTest-\(UUID().uuidString)", isDirectory: true)
        return (AnalysisCache(directory: dir), dir)
    }

    private static func seed(
        _ cache: AnalysisCache, track: Track, generation: AnalysisGeneration,
        features: AnalysisFeatures, fingerprintOverride: AnalyzedAudioFingerprint? = nil,
        payload: Data = Data(#"{"deliberately":"not a SessionResult"}"#.utf8)
    ) async {
        let fingerprint = fingerprintOverride
            ?? AnalyzedAudioFingerprint(duration: track.duration, transcoding: track.transcodings.first)!
        let key = AnalysisCacheKey(trackId: track.id, generation: generation, fingerprint: fingerprint)
        let (bytes, encoding) = AnalysisPayloadCodec.encode(payload)
        let record = AnalysisSyncRecord(
            cacheKey: key.stableKey, trackId: track.id,
            engineName: generation.engine.name, engineVersion: generation.engine.version,
            schemaVersion: generation.schemaVersion,
            durationMillis: fingerprint.durationMillis, preset: fingerprint.preset,
            bitrate: fingerprint.bitrate, codec: fingerprint.codec,
            payload: bytes, payloadEncoding: encoding,
            uncompressedByteSize: payload.count,
            payloadDigest: AnalysisPayloadCodec.digest(ofUncompressed: payload),
            bpm: features.bpm,
            keyWheelPosition: features.key?.wheelPosition,
            keyMode: features.key?.mode.rawValue,
            genre: features.genre,
            producedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            producerId: "selftest"
        )
        _ = await cache.adopt([record])
    }

    private static func testEveryLiveGenerationIsReadable(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let generations = await MainActor.run { AnalysisLookup.liveGenerations }
        var missed: [String] = []
        for (index, entry) in generations.enumerated() {
            let fixture = track(id: "90\(index)")
            await seed(cache, track: fixture, generation: entry.generation,
                       features: AnalysisFeatures(bpm: Double(100 + index)))
            let found = await AnalysisLookup.summaries(for: [fixture], cache: cache)
            if found[fixture.id]?.bpm != Double(100 + index) {
                missed.append("\(entry.producerId) (\(entry.generation.engine.name) v\(entry.generation.engine.version) schema \(entry.generation.schemaVersion))")
            }
        }

        if missed.isEmpty, !generations.isEmpty {
            report.lines.append("every one of the \(generations.count) live producer generations is readable by AnalysisLookup — no reader/producer schema drift")
        } else {
            report.failures.append("AnalysisLookup cannot read \(missed.count)/\(generations.count) live generation(s): \(missed.joined(separator: ", "))")
        }
    }

    private static func testGenreAndTempoMergeAcrossDifferentEngines(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = track(id: "910")
        await seed(cache, track: fixture, generation: MusicUnderstandingProducer().generation,
                   features: AnalysisFeatures(bpm: 128, key: CamelotKey(wheelPosition: 8, mode: .minor)))
        await seed(cache, track: fixture, generation: GenreTaxonomyProducer().generation,
                   features: AnalysisFeatures(genre: "techHouse"))

        let summary = await AnalysisLookup.summaries(for: [fixture], cache: cache)[fixture.id]
        if summary?.bpm == 128, summary?.key?.label == "8A", summary?.genre == "techHouse" {
            report.lines.append("bpm/key from musicUnderstanding merge with genre from genreTaxonomy into one summary")
        } else {
            report.failures.append("cross-engine merge: \(String(describing: summary))")
        }

        if summary?.bpmProvenance == .measured, summary?.keyProvenance == .measured,
           summary?.genreProvenance == .inferred {
            report.lines.append("provenance: audio-tier bpm/key read .measured, metadata-tier genre reads .inferred")
        } else {
            report.failures.append("provenance mis-stated: bpm=\(String(describing: summary?.bpmProvenance)) key=\(String(describing: summary?.keyProvenance)) genre=\(String(describing: summary?.genreProvenance))")
        }
    }

    private static func testPayloadShapeIsIrrelevant(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = track(id: "911")
        await seed(cache, track: fixture, generation: MusicUnderstandingProducer().generation,
                   features: AnalysisFeatures(bpm: 174, key: CamelotKey(wheelPosition: 3, mode: .major)),
                   payload: Data(#"{"rhythm":"a string, not an object","key":42}"#.utf8))

        let summary = await AnalysisLookup.summaries(for: [fixture], cache: cache)[fixture.id]
        if summary?.bpm == 174, summary?.key?.label == "3B" {
            report.lines.append("a row whose payload is not the producer's type still yields bpm/key — the recall columns are what is read")
        } else {
            report.failures.append("payload-shape independence: \(String(describing: summary))")
        }
    }

    private static func testASchemaBumpDoesNotBlankExistingValues(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let live = MusicUnderstandingProducer().generation
        let previous = AnalysisGeneration(engine: live.engine, schemaVersion: live.schemaVersion - 1)

        let onlyOld = track(id: "912")
        await seed(cache, track: onlyOld, generation: previous, features: AnalysisFeatures(bpm: 122))

        let both = track(id: "916")
        await seed(cache, track: both, generation: previous, features: AnalysisFeatures(bpm: 122))
        await seed(cache, track: both, generation: live, features: AnalysisFeatures(bpm: 123))

        let found = await AnalysisLookup.summaries(for: [onlyOld, both], cache: cache)
        if found[onlyOld.id]?.bpm == 122, found[both.id]?.bpm == 123 {
            report.lines.append("a pre-bump row still reads (a schema bump changes the payload, not the measurement), and a post-bump row for the same track wins")
        } else {
            report.failures.append("schema-bump survival: onlyOld=\(String(describing: found[onlyOld.id])), both=\(String(describing: found[both.id]))")
        }
    }

    private static func testASupersededEngineVersionIsNotRead(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let live = MusicUnderstandingProducer().generation
        let oldEngine = AnalysisGeneration(
            engine: AnalysisEngineIdentity(name: live.engine.name, version: live.engine.version + 1),
            schemaVersion: live.schemaVersion
        )
        let fixture = track(id: "917")
        await seed(cache, track: fixture, generation: oldEngine, features: AnalysisFeatures(bpm: 999))

        let summary = await AnalysisLookup.summaries(for: [fixture], cache: cache)[fixture.id]
        if summary == nil {
            report.lines.append("a value measured by an engine version no producer runs reads as unknown, never as a current measurement")
        } else {
            report.failures.append("foreign engine version leaked through: \(String(describing: summary))")
        }
    }

    private static func testForeignFingerprintIsNotBorrowed(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sameAudio = track(id: "913")
        let otherEncoding = AnalyzedAudioFingerprint(durationMillis: 200_000, preset: "mp3_1_0", bitrate: 128, codec: "mp3")
        await seed(cache, track: sameAudio, generation: MusicUnderstandingProducer().generation,
                   features: AnalysisFeatures(bpm: 120), fingerprintOverride: otherEncoding)

        let reupload = track(id: "918")
        let otherCut = AnalyzedAudioFingerprint(durationMillis: 260_000, preset: "aac_256k", bitrate: 256, codec: "aac")
        await seed(cache, track: reupload, generation: MusicUnderstandingProducer().generation,
                   features: AnalysisFeatures(bpm: 120), fingerprintOverride: otherCut)

        let found = await AnalysisLookup.summaries(for: [sameAudio, reupload], cache: cache)
        if found[sameAudio.id]?.bpm == 120, found[reupload.id] == nil {
            report.lines.append("a measurement from another encoding of the same audio is used, one from a different cut is not")
        } else {
            report.failures.append("fingerprint matching: sameAudio=\(String(describing: found[sameAudio.id])), reupload=\(String(describing: found[reupload.id]))")
        }
    }

    private static func testMeasuredTempoBeatsATaggedOne(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let both = track(id: "914")
        await seed(cache, track: both, generation: GenreTaxonomyProducer().generation,
                   features: AnalysisFeatures(bpm: 128, genre: "house"))
        await seed(cache, track: both, generation: MusicUnderstandingProducer().generation,
                   features: AnalysisFeatures(bpm: 127.5))

        let tagOnly = track(id: "915")
        await seed(cache, track: tagOnly, generation: GenreTaxonomyProducer().generation,
                   features: AnalysisFeatures(bpm: 140, genre: "dnb"))

        let merged = await AnalysisLookup.summaries(for: [both, tagOnly], cache: cache)
        if merged[both.id]?.bpm == 127.5, merged[tagOnly.id]?.bpm == 140 {
            report.lines.append("a measured tempo outranks a tag-derived one, and a tag-derived one still shows when nothing measured it")
        } else {
            report.failures.append("tempo authority: both=\(String(describing: merged[both.id])), tagOnly=\(String(describing: merged[tagOnly.id]))")
        }

        if merged[both.id]?.bpmProvenance == .measured, merged[tagOnly.id]?.bpmProvenance == .inferred {
            report.lines.append("provenance follows the supplying row: measured tempo reads .measured, tag-derived reads .inferred")
        } else {
            report.failures.append("tempo provenance: both=\(String(describing: merged[both.id]?.bpmProvenance)), tagOnly=\(String(describing: merged[tagOnly.id]?.bpmProvenance))")
        }
    }
}

final class AnalysisSummaryTests: XCTestCase {
    private let fingerprint = AnalyzedAudioFingerprint(durationMillis: 200_000, preset: "aac_256k", bitrate: 256, codec: "aac")

    private func row(
        _ engine: AnalysisEngineIdentity,
        schema: Int = 1,
        fingerprint: AnalyzedAudioFingerprint? = nil,
        bpm: Double? = nil,
        key: CamelotKey? = nil,
        genre: String? = nil,
        producedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> AnalysisRecallRow {
        let print = fingerprint ?? self.fingerprint
        return AnalysisRecallRow(
            cacheKey: "\(engine.name)#\(schema)#\(print.preset)#\(producedAt.timeIntervalSince1970)",
            trackId: "t",
            generation: AnalysisGeneration(engine: engine, schemaVersion: schema),
            fingerprint: print,
            bpm: bpm, key: key, genre: genre,
            byteSize: 10,
            producedAt: producedAt,
            lastAccessedAt: producedAt,
            producerId: nil
        )
    }

    func testSelfTestBattery() async {
        var report = AnalysisLookupSelfTest.Report()
        await AnalysisLookupSelfTest.run(into: &report)
        XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: "\n"))
    }

    func testCorrectedBeatsMeasuredBeatsEstimated() {
        let measured = MusicUnderstandingProducer().generation
        let estimated = GenreTaxonomyProducer().generation
        let rows = [
            row(estimated.engine, schema: estimated.schemaVersion, bpm: 140, genre: "techno"),
            row(measured.engine, schema: measured.schemaVersion, bpm: 128, key: CamelotKey(wheelPosition: 8, mode: .minor)),
            row(.userCorrection(), bpm: 126),
        ]
        let summary = AnalysisSummaryStore.summarise(rows, expectedDurationMillis: 200_000, preferred: fingerprint)
        XCTAssertEqual(summary?.bpm, 126)
        XCTAssertEqual(summary?.bpmAuthority, .corrected)
        XCTAssertEqual(summary?.key?.label, "8A")
        XCTAssertEqual(summary?.keyAuthority, .measured)
        XCTAssertEqual(summary?.genre, "techno")
        XCTAssertEqual(summary?.genreAuthority, .estimated)
        XCTAssertEqual(summary?.bpmIsMeasured, true)
        XCTAssertEqual(summary?.genreIsMeasured, false)
    }

    func testCorrectionOutranksANewerMeasurement() {
        let measured = MusicUnderstandingProducer().generation
        let rows = [
            row(.userCorrection(), bpm: 87, producedAt: Date(timeIntervalSince1970: 10)),
            row(measured.engine, schema: measured.schemaVersion, bpm: 174, producedAt: Date(timeIntervalSince1970: 99_999)),
        ]
        XCTAssertEqual(AnalysisSummaryStore.summarise(rows, expectedDurationMillis: nil)?.bpm, 87)
    }

    func testRetiredAndUnknownEnginesAreIgnored() {
        let rows = [
            row(AnalysisEngineIdentity(name: "sounding.fftAudioAnalyzer", version: 1), bpm: 120),
            row(AnalysisEngineIdentity(name: "someone.else", version: 1), bpm: 121),
        ]
        XCTAssertNil(AnalysisSummaryStore.summarise(rows, expectedDurationMillis: nil))
        XCTAssertNil(AnalysisSummaryStore.authority(of: AnalysisEngineIdentity(name: "sounding.fftAudioAnalyzer", version: 1)))
        XCTAssertFalse(AnalysisSyncEngineScope.default.allows(engineName: "sounding.fftAudioAnalyzer"))
    }

    func testPreferredEncodingWinsAndOtherCutsAreRejected() {
        let measured = MusicUnderstandingProducer().generation
        let otherEncoding = AnalyzedAudioFingerprint(durationMillis: 200_400, preset: "mp3_1_0", bitrate: 128, codec: "mp3")
        let otherCut = AnalyzedAudioFingerprint(durationMillis: 230_000, preset: "aac_256k", bitrate: 256, codec: "aac")
        let rows = [
            row(measured.engine, schema: measured.schemaVersion, fingerprint: otherEncoding, bpm: 125, producedAt: Date(timeIntervalSince1970: 5_000)),
            row(measured.engine, schema: measured.schemaVersion, bpm: 124),
            row(measured.engine, schema: measured.schemaVersion, fingerprint: otherCut, bpm: 99, key: CamelotKey(wheelPosition: 1, mode: .major)),
        ]
        let summary = AnalysisSummaryStore.summarise(rows, expectedDurationMillis: 200_000, preferred: fingerprint)
        XCTAssertEqual(summary?.bpm, 124)
        XCTAssertNil(summary?.key)

        let onlyOtherEncoding = AnalysisSummaryStore.summarise(Array(rows.prefix(1)), expectedDurationMillis: 200_000, preferred: fingerprint)
        XCTAssertEqual(onlyOtherEncoding?.bpm, 125)
    }

    func testNewerSchemaWinsWithinTheSameAuthority() {
        let live = MusicUnderstandingProducer().generation
        let rows = [
            row(live.engine, schema: live.schemaVersion - 1, bpm: 122, producedAt: Date(timeIntervalSince1970: 9_000)),
            row(live.engine, schema: live.schemaVersion, bpm: 123),
        ]
        XCTAssertEqual(AnalysisSummaryStore.summarise(rows, expectedDurationMillis: 200_000)?.bpm, 123)
    }

    func testProvenanceMapping() {
        XCTAssertEqual(TrackAnalysisSummary.provenance(.corrected), .stated)
        XCTAssertEqual(TrackAnalysisSummary.provenance(.measured), .measured)
        XCTAssertEqual(TrackAnalysisSummary.provenance(.estimated), .inferred)
    }
}
#endif
