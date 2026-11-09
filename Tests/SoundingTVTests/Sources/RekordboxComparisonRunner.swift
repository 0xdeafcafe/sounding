import Foundation
#if os(macOS)
@testable import SoundingTV_macOS
#else
@testable import SoundingTV
#endif

enum SoundingComparisonRunner {
    static let folderID = "rekordbox-compare"
    static let primaryEngine = "Sounding"
    static let beatTrackerEngine = "BeatTracker only"

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func makeTrack(url: URL, metadata: LocalMusicMetadata) async -> Track? {
        let id = LocalMusicScanner.trackID(folderID: folderID, relativePath: url.path)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return await MainActor.run {
            LocalMusicLibrary.makeTrack(
                id: id,
                title: metadata.title,
                artist: metadata.artist ?? "Unknown",
                album: metadata.album,
                genre: metadata.genre,
                duration: metadata.duration,
                modifiedAt: modified,
                fileURL: url,
                ownerURL: url.deletingLastPathComponent(),
                artworkURL: nil,
                localFile: LocalTrackFile(folderID: folderID, relativePath: url.path)
            )
        }
    }

    static func run(_ producer: any AnalysisProducer, track: Track, url: URL, cache: AnalysisCache) async -> (outcome: AnalysisProducerOutcome?, seconds: Double) {
        let clock = ContinuousClock()
        var outcome: AnalysisProducerOutcome?
        var elapsed = 0.0
        for attempt in 0 ..< 4 {
            let start = clock.now
            let result = await AnalysisCoordinator.analyze(
                track: track,
                localFileURL: url,
                refresh: true,
                registry: AnalysisProducerRegistry([producer]),
                cache: cache
            )
            elapsed = seconds(start.duration(to: clock.now))
            outcome = result.outcomes[producer.id]
            if case .failed(let message) = outcome, message.contains("sessionInProgress"), attempt < 3 {
                try? await Task.sleep(for: .seconds(Double(attempt + 1)))
                continue
            }
            break
        }
        return (outcome, elapsed)
    }

    static func note(_ id: String, _ outcome: AnalysisProducerOutcome?) -> String? {
        switch outcome {
        case .failed(let message): return "\(id) failed: \(message)"
        case .skipped(let message): return "\(id) skipped: \(message)"
        case nil: return "\(id) did not run"
        case .stored: return nil
        }
    }

    static func peekBeatTracker(track: Track, cache: AnalysisCache) async -> BeatTrackerResult? {
        guard let key = AnalysisCacheKey(track: track, transcoding: track.transcodings.first, generation: BeatTrackerProducer().generation) else { return nil }
        return await cache.peek(BeatTrackerResult.self, for: key)
    }

    static func peekAI(track: Track, cache: AnalysisCache) async -> AIAudioAnalysisResult? {
        let generation = AnalysisGeneration(engine: .aiAudio(), schemaVersion: 1)
        guard let key = AnalysisCacheKey(track: track, transcoding: track.transcodings.first, generation: generation) else { return nil }
        return await cache.peek(AIAudioAnalysisResult.self, for: key)
    }

    static func peekMusicUnderstanding(track: Track, cache: AnalysisCache) async -> DJSessionDirector.CachedMusicUnderstanding? {
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) else { return nil }
        guard let key = AnalysisCacheKey(track: track, transcoding: track.transcodings.first, generation: MusicUnderstandingProducer().generation),
              let result = await cache.peek(MusicUnderstandingDistilledResult.self, for: key) else { return nil }
        return DJSessionDirector.cachedMusicUnderstanding(result)
    }

    static func analyse(reference: RekordboxReferenceTrack, cache: AnalysisCache, includeBeatTracker: Bool) async -> TrackComparison {
        let url = URL(fileURLWithPath: reference.audioPath ?? reference.devicePath)
        let metadata = await LocalMusicScanner.metadata(for: url)
        let xmlGenre = reference.xml?.attributes["Genre"]?.trimmingCharacters(in: .whitespaces)
        let tagGenre = metadata.genre?.trimmingCharacters(in: .whitespaces)
        let genre = [tagGenre, xmlGenre].compactMap { $0 }.first { !$0.isEmpty } ?? "Untagged"
        let referenceKey = (reference.xml?.tonality).flatMap(CamelotKey.parse)
        let duration = metadata.duration > 0 ? metadata.duration : (reference.beatTimes.last ?? 0)
        var comparison = TrackComparison(
            reference: reference,
            title: metadata.title,
            artist: metadata.artist ?? "",
            genre: genre,
            duration: duration,
            referenceKey: referenceKey,
            engines: []
        )
        guard metadata.duration > 0, let track = await makeTrack(url: url, metadata: metadata) else {
            comparison.failure = "unreadable audio"
            comparison.engines = [EngineComparison(reference: reference, observation: EngineObservation(name: primaryEngine, failure: "unreadable audio"), referenceKey: referenceKey)]
            return comparison
        }

        let registry = AnalysisProducerRegistry.audioTier
        let ids = Set(registry.producers.map { $0.id })
        var producerSeconds: [String: Double] = [:]
        var notes: [String] = []
        for producer in registry.producers {
            let ran = await run(producer, track: track, url: url, cache: cache)
            producerSeconds[producer.id] = ran.seconds
            if let note = note(producer.id, ran.outcome) { notes.append(note) }
        }
        let cachedMU = await peekMusicUnderstanding(track: track, cache: cache)
        var ai: AIAudioAnalysisResult?
        if ids.contains("aiAudio") { ai = await peekAI(track: track, cache: cache) }
        var productionBeats: BeatTrackerResult?
        if ids.contains("beatTracker") { productionBeats = await peekBeatTracker(track: track, cache: cache) }
        let trackedBeats = (cachedMU?.barSeconds.count ?? 0) < 2 ? productionBeats : nil
        let features = DJSessionDirector.assembleFeatures(
            for: track,
            envelope: [],
            cachedAnalysis: cachedMU,
            legacyAnalysis: nil,
            userCues: [],
            trackedBeats: trackedBeats,
            aiAudio: ai
        )
        let primary = EngineObservation(
            name: primaryEngine,
            features: features,
            duration: duration,
            seconds: producerSeconds.values.reduce(0, +),
            producerSeconds: producerSeconds,
            failure: notes.isEmpty ? nil : notes.joined(separator: "; ")
        )
        comparison.engines.append(EngineComparison(reference: reference, observation: primary, referenceKey: referenceKey))

        if includeBeatTracker, !ids.contains("beatTracker") {
            let ran = await run(BeatTrackerProducer(), track: track, url: url, cache: cache)
            let tracked = await peekBeatTracker(track: track, cache: cache)
            let fallback = DJSessionDirector.assembleFeatures(
                for: track,
                envelope: [],
                cachedAnalysis: nil,
                legacyAnalysis: nil,
                userCues: [],
                trackedBeats: tracked,
                aiAudio: ai
            )
            let observation = EngineObservation(
                name: beatTrackerEngine,
                features: fallback,
                duration: duration,
                seconds: ran.seconds,
                producerSeconds: ["beatTracker": ran.seconds],
                failure: note("beatTracker", ran.outcome)
            )
            comparison.engines.append(EngineComparison(reference: reference, observation: observation, referenceKey: referenceKey))
        }
        return comparison
    }
}
