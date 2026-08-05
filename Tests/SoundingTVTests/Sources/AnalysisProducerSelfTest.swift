import Foundation
import AVFoundation
@testable import SoundingTV

#if DEBUG

enum AnalysisProducerSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[AnalysisProducerTest] \(status)"] + lines.map { "[AnalysisProducerTest]   \($0)" }
                + failures.map { "[AnalysisProducerTest]   ✗ \($0)" }).joined(separator: "\n")
        }
    }

    private static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    private static func entitledTrack(id: String, title: String, durationSeconds: Double = 200) -> Track {
        let json = """
        {
            "id": \(id),
            "title": "\(title)",
            "description": null,
            "artwork_url": null,
            "waveform_url": null,
            "permalink_url": "https://soundcloud.com/example/\(id)",
            "playback_count": 0,
            "likes_count": 0,
            "reposts_count": 0,
            "created_at": "2024-09-01T12:00:00Z",
            "user": {
                "id": 1,
                "username": "example",
                "permalink": "example",
                "permalink_url": "https://soundcloud.com/example"
            },
            "media": {
                "transcodings": [
                    {
                        "url": "https://api-v2.soundcloud.com/media/example/\(id)/stream",
                        "duration": \(Int(durationSeconds * 1000)),
                        "quality": "hq",
                        "format": { "protocol": "progressive", "mime_type": "audio/mp4" },
                        "preset": "aac_256k"
                    }
                ]
            }
        }
        """
        let data = Data(json.utf8)
        return try! decoder.decode(Track.self, from: data)
    }

    private static func unentitledTrack(id: String, title: String) -> Track {
        let json = """
        {
            "id": \(id),
            "title": "\(title)",
            "description": null,
            "artwork_url": null,
            "waveform_url": null,
            "permalink_url": "https://soundcloud.com/example/\(id)",
            "playback_count": 0,
            "likes_count": 0,
            "reposts_count": 0,
            "created_at": "2024-09-01T12:00:00Z",
            "user": {
                "id": 1,
                "username": "example",
                "permalink": "example",
                "permalink_url": "https://soundcloud.com/example"
            },
            "media": {
                "transcodings": [
                    {
                        "url": "https://api-v2.soundcloud.com/media/example/\(id)/preview",
                        "duration": 30000,
                        "quality": "sq",
                        "snipped": true,
                        "format": { "protocol": "progressive", "mime_type": "audio/mp4" },
                        "preset": "aac_64k"
                    }
                ]
            }
        }
        """
        let data = Data(json.utf8)
        return try! decoder.decode(Track.self, from: data)
    }

    private static func scratchCache() -> (AnalysisCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisProducerSelfTest-\(UUID().uuidString)", isDirectory: true)
        return (AnalysisCache(directory: dir), dir)
    }

    static func run() async -> Report {
        var report = Report()
        await testGenreProducerStoresResolutionAndProjectsBPMAndGenre(&report)
        await testGenreProducerLowConfidenceOmitsGenreFromRecallButKeepsPayload(&report)
        await testWaveformProducerStoresEnvelopeWithNoRecallProjection(&report)
        await testWaveformProducerSkipsWithoutSamples(&report)
        await testCoordinatorRefusesUnentitledTrack(&report)
        await testCoordinatorIsIdempotentAndUpserts(&report)
        await testMusicUnderstandingSkipsWithoutLocalFile(&report)
        await testMusicUnderstandingIsUnreachableOnTVOS(&report)
        await testEveryProducerDeclaresADistinctGeneration(&report)
        if ProcessInfo.processInfo.environment["SOUNDING_TV_MIXTEST_ANALYSIS"] == "1" {
            await testMusicUnderstandingRunsAgainstARealLocalFile(&report)
        } else {
            report.lines.append("real-file MusicUnderstanding smoke test SKIPPED — opt in with SOUNDING_TV_MIXTEST_ANALYSIS=1 (can SIGABRT the whole process on some devices; see task #79)")
        }
        return report
    }

    private static func testGenreProducerStoresResolutionAndProjectsBPMAndGenre(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = entitledTrack(id: "1", title: "Some Track")
        let result = await AnalysisCoordinator.analyze(
            track: track,
            genreField: "Tech House",
            tags: ["128bpm", "peak time"],
            registry: AnalysisProducerRegistry([GenreTaxonomyProducer()]),
            cache: cache
        )

        let features = result.stored["genreTaxonomy"]
        let coverage = await cache.featureCoverage(
            engine: GenreTaxonomyProducer().engine, schemaVersion: GenreTaxonomyProducer().schemaVersion
        )

        if result.isEntitled, features?.genre == MusicGenre.techHouse.rawValue, features?.bpm == 128,
           coverage.total == 1, coverage.withGenre == 1, coverage.withBPM == 1 {
            report.lines.append("genre producer resolves 'Tech House' + a bpm tag and lands in featureCoverage (\(coverage))")
        } else {
            report.failures.append("genre producer: features=\(String(describing: features)), coverage=\(coverage)")
        }
    }

    private static func testGenreProducerLowConfidenceOmitsGenreFromRecallButKeepsPayload(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = entitledTrack(id: "2", title: "Untitled")
        let result = await AnalysisCoordinator.analyze(
            track: track,
            registry: AnalysisProducerRegistry([GenreTaxonomyProducer()]),
            cache: cache
        )

        let features = result.stored["genreTaxonomy"]
        let payload = await cache.peek(GenreAnalysisPayload.self, for: AnalysisCacheKey(
            track: track, transcoding: track.transcodings[0], generation: GenreTaxonomyProducer().generation
        )!)

        if features?.genre == nil, payload != nil {
            report.lines.append("an unresolved genre still writes a row (payload present) but leaves the recall column NULL")
        } else {
            report.failures.append("low-confidence genre: features=\(String(describing: features)), payload present=\(payload != nil)")
        }
    }

    private static func testWaveformProducerStoresEnvelopeWithNoRecallProjection(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = entitledTrack(id: "3", title: "Waveform Track")
        let samples: [Float] = (0..<200).map { Float($0) / 200 }
        let result = await AnalysisCoordinator.analyze(
            track: track,
            waveformSamples: samples,
            registry: AnalysisProducerRegistry([WaveformEnvelopeProducer()]),
            cache: cache
        )

        let key = AnalysisCacheKey(track: track, transcoding: track.transcodings[0], engine: .soundCloudWaveform(version: 1), schemaVersion: 1)!
        let payload = await cache.peek(WaveformAnalysisPayload.self, for: key)

        if result.stored["waveformEnvelope"] == AnalysisFeatures(), payload?.samples.count == 200 {
            report.lines.append("waveform producer persists all 200 envelope samples with an empty (correct) recall projection")
        } else {
            report.failures.append("waveform producer: stored=\(String(describing: result.stored["waveformEnvelope"])), sampleCount=\(payload?.samples.count ?? -1)")
        }
    }

    private static func testWaveformProducerSkipsWithoutSamples(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = entitledTrack(id: "4", title: "No Waveform")
        let result = await AnalysisCoordinator.analyze(
            track: track,
            registry: AnalysisProducerRegistry([WaveformEnvelopeProducer()]),
            cache: cache
        )

        if case .skipped = result.outcomes["waveformEnvelope"] {
            report.lines.append("waveform producer skips cleanly (not .failed) when no samples were supplied")
        } else {
            report.failures.append("waveform producer without samples: expected .skipped, got \(String(describing: result.outcomes["waveformEnvelope"]))")
        }
    }

    private static func testCoordinatorRefusesUnentitledTrack(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = unentitledTrack(id: "5", title: "Preview Only")
        let result = await AnalysisCoordinator.analyze(
            track: track,
            genreField: "Techno",
            waveformSamples: [0.1, 0.2, 0.3],
            registry: .v1,
            cache: cache
        )
        let coverage = await cache.featureCoverage(
            engine: GenreTaxonomyProducer().engine, schemaVersion: GenreTaxonomyProducer().schemaVersion
        )

        if !result.isEntitled, result.outcomes.isEmpty, track.transcodings.isEmpty, coverage.total == 0 {
            report.lines.append("an unentitled track (snippet-only transcodings) is refused before a single producer runs — no row lands anywhere")
        } else {
            report.failures.append("unentitled gate: isEntitled=\(result.isEntitled), outcomes=\(result.outcomes.count), coverage=\(coverage)")
        }
    }

    private static func testCoordinatorIsIdempotentAndUpserts(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = entitledTrack(id: "6", title: "Repeat Me")
        _ = await AnalysisCoordinator.analyze(
            track: track, genreField: "House", tags: ["deep house"],
            registry: AnalysisProducerRegistry([GenreTaxonomyProducer()]), cache: cache
        )
        _ = await AnalysisCoordinator.analyze(
            track: track, genreField: "House", tags: ["deep house"],
            registry: AnalysisProducerRegistry([GenreTaxonomyProducer()]), cache: cache
        )

        let coverage = await cache.featureCoverage(
            engine: GenreTaxonomyProducer().engine, schemaVersion: GenreTaxonomyProducer().schemaVersion
        )
        if coverage.total == 1 {
            report.lines.append("calling the coordinator twice for the same track upserts one row, never appends a second")
        } else {
            report.failures.append("idempotency: expected 1 row after two calls, coverage=\(coverage)")
        }
    }

    private static func testMusicUnderstandingSkipsWithoutLocalFile(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = entitledTrack(id: "7", title: "Streamed, Never Materialised")
        let result = await AnalysisCoordinator.analyze(
            track: track,
            registry: AnalysisProducerRegistry([MusicUnderstandingProducer()]),
            cache: cache
        )

        if case .skipped = result.outcomes["musicUnderstanding"] {
            report.lines.append("MusicUnderstanding never runs against a bare remote track — no local file, no attempt")
        } else {
            report.failures.append("MusicUnderstanding gate: expected .skipped, got \(String(describing: result.outcomes["musicUnderstanding"]))")
        }
    }

    private static func testMusicUnderstandingIsUnreachableOnTVOS(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("not-really-audio.m4a")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data([0, 1, 2, 3]))

        let track = entitledTrack(id: "168", title: "Platform Gate")
        guard let transcoding = track.transcodings.first else {
            report.failures.append("tvOS gate test: fixture track has no transcoding to analyse")
            return
        }
        let context = AnalysisProducerContext(
            track: track,
            transcoding: transcoding,
            localFileURL: fileURL
        )
        let producer = MusicUnderstandingProducer()

        #if os(tvOS)
        let refusedByApplicability = !producer.isApplicable(context)
        var refusedByRun = false
        if case .skipped = await producer.run(context, cache: cache) { refusedByRun = true }

        if refusedByApplicability, refusedByRun {
            report.lines.append("tvOS: MusicUnderstanding refuses a valid local-file context at both isApplicable and run — MusicUnderstandingSession(asset:) is unreachable (task #168)")
        } else {
            report.failures.append("tvOS gate breached: isApplicable refused=\(refusedByApplicability), run refused=\(refusedByRun) — MusicUnderstandingSession(asset:) aborts the process on this platform")
        }
        #else
        if producer.isApplicable(context) {
            report.lines.append("non-tvOS: MusicUnderstanding accepts a local-file context — the tvOS gate has not been over-applied")
        } else {
            report.failures.append("MusicUnderstanding refused a valid local-file context on a platform where it is supported — real analysis is disabled")
        }
        #endif
    }

    private static func testEveryProducerDeclaresADistinctGeneration(_ report: inout Report) async {
        let live = AnalysisProducerRegistry.v1.liveGenerations
        let distinct = Set(live.map(\.generation))
        let derivationHolds = AnalysisProducerRegistry.v1.producers.allSatisfy {
            $0.schemaVersion == $0.generation.schemaVersion && $0.engine == $0.generation.engine
        }

        if distinct.count == live.count, !live.isEmpty, derivationHolds {
            let described = live.map { "\($0.producerId)@\($0.generation.engine.name)v\($0.generation.engine.version)/s\($0.generation.schemaVersion)" }
            report.lines.append("all \(live.count) live producer generations are distinct and self-derived: \(described.joined(separator: ", "))")
        } else {
            report.failures.append("producer generations: \(live.count) producers, \(distinct.count) distinct, derivationHolds=\(derivationHolds)")
        }
    }

    private static func testMusicUnderstandingRunsAgainstARealLocalFile(_ report: inout Report) async {
        guard let toneURL = writeSyntheticTone() else {
            report.failures.append("could not synthesise a local test tone (AVAudioFile write failed)")
            return
        }
        defer { try? FileManager.default.removeItem(at: toneURL) }

        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = entitledTrack(id: "8", title: "Synthetic Tone")
        let result = await AnalysisCoordinator.analyze(
            track: track,
            localFileURL: toneURL,
            registry: AnalysisProducerRegistry([MusicUnderstandingProducer()]),
            cache: cache
        )

        switch result.outcomes["musicUnderstanding"] {
        case .stored(let features):
            report.lines.append("MusicUnderstanding analysed a real local file and stored a row (features: \(features))")
        case .skipped(let reason):
            report.lines.append("MusicUnderstanding ran against a real local file and reported no data (\(reason)) — acceptable for a plain tone, not a failure")
        case .failed(let reason):
            report.failures.append("MusicUnderstanding failed against a real local file: \(reason)")
        case nil:
            report.failures.append("MusicUnderstanding producer did not run at all")
        }
    }

    private static func writeSyntheticTone(seconds: Double = 2, frequency: Double = 220, sampleRate: Double = 44_100) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisProducerSelfTest-tone-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return nil }
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData else { return nil }
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            channelData[0][frame] = Float(sin(2 * Double.pi * frequency * t) * 0.4)
        }
        do {
            try file.write(from: buffer)
            return url
        } catch {
            return nil
        }
    }
}
#endif
