import Foundation
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

        let fixture = track(id: "913")
        let foreign = AnalyzedAudioFingerprint(durationMillis: 200_000, preset: "opus_64k", bitrate: 64, codec: "opus")
        await seed(cache, track: fixture, generation: MusicUnderstandingProducer().generation,
                   features: AnalysisFeatures(bpm: 120), fingerprintOverride: foreign)

        let summary = await AnalysisLookup.summaries(for: [fixture], cache: cache)[fixture.id]
        if summary == nil {
            report.lines.append("analysis measured from a different transcoding reads as unknown, never as borrowed data")
        } else {
            report.failures.append("foreign fingerprint borrowed: \(String(describing: summary))")
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
#endif
