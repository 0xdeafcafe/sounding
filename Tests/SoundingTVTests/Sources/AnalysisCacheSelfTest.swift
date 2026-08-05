import Foundation
@testable import SoundingTV

#if DEBUG

enum AnalysisCacheSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[AnalysisCacheTest] \(status)"] + lines.map { "[AnalysisCacheTest]   \($0)" }
                + failures.map { "[AnalysisCacheTest]   ✗ \($0)" }).joined(separator: "\n")
        }
    }

    private struct SyntheticAnalysis: Codable, Sendable, Equatable {
        let bpm: Double
        let beats: [Double]
    }

    private static let noFeatures: @Sendable (SyntheticAnalysis) -> AnalysisFeatures = { _ in AnalysisFeatures() }

    private static func scratchCache(maxBytes: Int64 = AnalysisCache.defaultMaxBytes) -> (AnalysisCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisCacheSelfTest-\(UUID().uuidString)", isDirectory: true)
        return (AnalysisCache(directory: dir, maxBytes: maxBytes), dir)
    }

    private static func fingerprint(durationMillis: Int = 180_000, preset: String = "aac_256k", bitrate: Int = 256) -> AnalyzedAudioFingerprint {
        AnalyzedAudioFingerprint(durationMillis: durationMillis, preset: preset, bitrate: bitrate, codec: "aac")
    }

    static func run() async -> Report {
        var report = Report()
        await testPersistsAcrossInstances(&report)
        await testSchemaVersionInvalidates(&report)
        await testEngineVersionInvalidates(&report)
        await testFingerprintMismatchInvalidates(&report)
        await testLRUEvictionOrder(&report)
        await testTouchProtectsFromEviction(&report)
        await testConcurrentCallersCoalesce(&report)
        await testBPMHalfDoubleTimeRecall(&report)
        await testCamelotKeySetRecall(&report)
        await testRecallNullFeatureScopedToItsOwnFilter(&report)
        await testRecallQueryUsesIndex(&report)
        return report
    }

    private static func testPersistsAcrossInstances(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = AnalysisCacheKey(trackId: "1", engine: .fftAudioAnalyzer(), schemaVersion: 1, fingerprint: fingerprint())
        let computeCount = Counter()

        do {
            let first = try await cache.value(for: key, as: SyntheticAnalysis.self) {
                _ = await computeCount.increment()
                return SyntheticAnalysis(bpm: 128, beats: [0, 0.5, 1.0])
            } features: { _ in AnalysisFeatures() }

            let reopened = AnalysisCache(directory: dir)
            let second = try await reopened.value(for: key, as: SyntheticAnalysis.self) {
                _ = await computeCount.increment()
                return SyntheticAnalysis(bpm: 999, beats: [])
            } features: { _ in AnalysisFeatures() }

            let runs = await computeCount.count
            if first == second, runs == 1 {
                report.lines.append("persists across a fresh actor instance on the same directory without recomputing")
            } else {
                report.failures.append("persistence: computeCount=\(runs), first=\(first), second=\(second)")
            }
        } catch {
            report.failures.append("persistence threw: \(error)")
        }
    }

    private static func testSchemaVersionInvalidates(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let keyV1 = AnalysisCacheKey(trackId: "2", engine: .fftAudioAnalyzer(), schemaVersion: 1, fingerprint: fingerprint())
        let keyV2 = AnalysisCacheKey(trackId: "2", engine: .fftAudioAnalyzer(), schemaVersion: 2, fingerprint: fingerprint())

        do {
            _ = try await cache.value(for: keyV1, as: SyntheticAnalysis.self, compute: { SyntheticAnalysis(bpm: 100, beats: []) }, features: noFeatures)
            let recomputed = Counter()
            _ = try await cache.value(for: keyV2, as: SyntheticAnalysis.self) {
                _ = await recomputed.increment()
                return SyntheticAnalysis(bpm: 200, beats: [])
            } features: { _ in AnalysisFeatures() }
            if await recomputed.count > 0 {
                report.lines.append("schemaVersion bump is a cache miss, forces recompute")
            } else {
                report.failures.append("schemaVersion bump incorrectly reused the v1 row")
            }
        } catch {
            report.failures.append("schemaVersion invalidation threw: \(error)")
        }
    }

    private static func testEngineVersionInvalidates(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let keyV1 = AnalysisCacheKey(trackId: "3", engine: .fftAudioAnalyzer(version: 1), schemaVersion: 1, fingerprint: fingerprint())
        let keyV2 = AnalysisCacheKey(trackId: "3", engine: .fftAudioAnalyzer(version: 2), schemaVersion: 1, fingerprint: fingerprint())

        do {
            _ = try await cache.value(for: keyV1, as: SyntheticAnalysis.self, compute: { SyntheticAnalysis(bpm: 100, beats: []) }, features: noFeatures)
            let recomputed = Counter()
            _ = try await cache.value(for: keyV2, as: SyntheticAnalysis.self) {
                _ = await recomputed.increment()
                return SyntheticAnalysis(bpm: 200, beats: [])
            } features: { _ in AnalysisFeatures() }
            if await recomputed.count > 0 {
                report.lines.append("engine version bump is a cache miss, forces recompute")
            } else {
                report.failures.append("engine version bump incorrectly reused the old engine's row")
            }
        } catch {
            report.failures.append("engine version invalidation threw: \(error)")
        }
    }

    private static func testFingerprintMismatchInvalidates(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let hqKey = AnalysisCacheKey(trackId: "4", engine: .fftAudioAnalyzer(), schemaVersion: 1, fingerprint: fingerprint(preset: "aac_256k", bitrate: 256))
        let lowQualityKey = AnalysisCacheKey(trackId: "4", engine: .fftAudioAnalyzer(), schemaVersion: 1, fingerprint: fingerprint(preset: "opus_0_0", bitrate: 64))

        do {
            _ = try await cache.value(for: hqKey, as: SyntheticAnalysis.self, compute: { SyntheticAnalysis(bpm: 128, beats: []) }, features: noFeatures)
            let recomputed = Counter()
            _ = try await cache.value(for: lowQualityKey, as: SyntheticAnalysis.self) {
                _ = await recomputed.increment()
                return SyntheticAnalysis(bpm: 60, beats: [])
            } features: { _ in AnalysisFeatures() }
            if await recomputed.count > 0 {
                report.lines.append("a different transcoding (fingerprint) is a cache miss, does not reuse a mismatched analysis")
            } else {
                report.failures.append("a lower-quality stream incorrectly reused the high-quality stream's analysis")
            }
        } catch {
            report.failures.append("fingerprint mismatch test threw: \(error)")
        }
    }

    private static let syntheticPayloadSize: Int64 = {
        let data = (try? JSONEncoder().encode(SyntheticAnalysis(bpm: 100, beats: []))) ?? Data()
        return Int64(data.count)
    }()

    private static func testLRUEvictionOrder(_ report: inout Report) async {
        let maxBytes = syntheticPayloadSize * 2 + syntheticPayloadSize / 2
        let (cache, dir) = scratchCache(maxBytes: maxBytes)
        defer { try? FileManager.default.removeItem(at: dir) }

        func key(_ trackId: String) -> AnalysisCacheKey {
            AnalysisCacheKey(trackId: trackId, engine: .fftAudioAnalyzer(), schemaVersion: 1, fingerprint: fingerprint())
        }

        do {
            _ = try await cache.value(for: key("old"), as: SyntheticAnalysis.self, compute: { SyntheticAnalysis(bpm: 100, beats: []) }, features: noFeatures)
            _ = try await cache.value(for: key("mid"), as: SyntheticAnalysis.self, compute: { SyntheticAnalysis(bpm: 110, beats: []) }, features: noFeatures)
            _ = try await cache.value(for: key("new"), as: SyntheticAnalysis.self, compute: { SyntheticAnalysis(bpm: 120, beats: []) }, features: noFeatures)

            let oldStillCached = await cache.peek(SyntheticAnalysis.self, for: key("old")) != nil
            let newStillCached = await cache.peek(SyntheticAnalysis.self, for: key("new")) != nil
            let usedBytes = await cache.usedBytes
            let maxBytes = await cache.maxBytes

            if !oldStillCached, newStillCached, usedBytes <= maxBytes {
                report.lines.append("over budget: least-recently-inserted ('old') evicted first, most recent survives, usedBytes(\(usedBytes)) <= maxBytes(\(maxBytes))")
            } else {
                report.failures.append("LRU order: old cached=\(oldStillCached), new cached=\(newStillCached), usedBytes=\(usedBytes), maxBytes=\(maxBytes)")
            }
        } catch {
            report.failures.append("LRU eviction test threw: \(error)")
        }
    }

    private static func testTouchProtectsFromEviction(_ report: inout Report) async {
        let maxBytes = syntheticPayloadSize * 2 + syntheticPayloadSize / 2
        let (cache, dir) = scratchCache(maxBytes: maxBytes)
        defer { try? FileManager.default.removeItem(at: dir) }

        func key(_ trackId: String) -> AnalysisCacheKey {
            AnalysisCacheKey(trackId: trackId, engine: .fftAudioAnalyzer(), schemaVersion: 1, fingerprint: fingerprint())
        }

        do {
            _ = try await cache.value(for: key("a"), as: SyntheticAnalysis.self, compute: { SyntheticAnalysis(bpm: 100, beats: []) }, features: noFeatures)
            _ = try await cache.value(for: key("b"), as: SyntheticAnalysis.self, compute: { SyntheticAnalysis(bpm: 110, beats: []) }, features: noFeatures)
            _ = await cache.peek(SyntheticAnalysis.self, for: key("a"))
            _ = try await cache.value(for: key("c"), as: SyntheticAnalysis.self, compute: { SyntheticAnalysis(bpm: 120, beats: []) }, features: noFeatures)

            let aStillCached = await cache.peek(SyntheticAnalysis.self, for: key("a")) != nil
            let bStillCached = await cache.peek(SyntheticAnalysis.self, for: key("b")) != nil

            if aStillCached, !bStillCached {
                report.lines.append("a touched (re-read) row survives eviction over an idle row inserted more recently")
            } else {
                report.failures.append("touch-protects-from-eviction: a cached=\(aStillCached), b cached=\(bStillCached)")
            }
        } catch {
            report.failures.append("touch protection test threw: \(error)")
        }
    }

    private actor Counter {
        private(set) var count = 0
        func increment() -> Int {
            count += 1
            return count
        }
    }

    private static func testConcurrentCallersCoalesce(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = AnalysisCacheKey(trackId: "stampede", engine: .fftAudioAnalyzer(), schemaVersion: 1, fingerprint: fingerprint())
        let counter = Counter()
        let callerCount = 25

        do {
            let results = try await withThrowingTaskGroup(of: SyntheticAnalysis.self) { group in
                for _ in 0..<callerCount {
                    group.addTask {
                        try await cache.value(for: key, as: SyntheticAnalysis.self) {
                            let n = await counter.increment()
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            return SyntheticAnalysis(bpm: Double(100 + n), beats: [])
                        } features: { _ in AnalysisFeatures() }
                    }
                }
                var collected: [SyntheticAnalysis] = []
                for try await value in group { collected.append(value) }
                return collected
            }

            let computeRuns = await counter.count
            let distinctResults = Set(results.map { $0.bpm })

            if computeRuns == 1, distinctResults.count == 1, results.count == callerCount {
                report.lines.append("\(callerCount) concurrent callers for the same key coalesce into exactly 1 compute, all get the identical result")
            } else {
                report.failures.append("coalescing: computeRuns=\(computeRuns), distinctResults=\(distinctResults), resultCount=\(results.count)")
            }
        } catch {
            report.failures.append("coalescing test threw: \(error)")
        }
    }

    @discardableResult
    private static func seedRecallRow(
        _ cache: AnalysisCache,
        trackId: String,
        bpm: Double,
        key: CamelotKey? = nil,
        genre: String? = nil,
        engine: AnalysisEngineIdentity = .fftAudioAnalyzer(),
        schemaVersion: Int = 1
    ) async throws -> AnalysisCacheKey {
        let cacheKey = AnalysisCacheKey(trackId: trackId, engine: engine, schemaVersion: schemaVersion, fingerprint: fingerprint())
        _ = try await cache.value(for: cacheKey, as: SyntheticAnalysis.self) {
            SyntheticAnalysis(bpm: bpm, beats: [])
        } features: { payload in
            AnalysisFeatures(bpm: payload.bpm, key: key, genre: genre)
        }
        return cacheKey
    }

    private static func testBPMHalfDoubleTimeRecall(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            try await seedRecallRow(cache, trackId: "unity", bpm: 174)
            try await seedRecallRow(cache, trackId: "half", bpm: 87)
            try await seedRecallRow(cache, trackId: "double", bpm: 348)
            try await seedRecallRow(cache, trackId: "unrelated", bpm: 100)
            try await seedRecallRow(cache, trackId: "near-half-but-outside-tolerance", bpm: 87 * 1.10)

            let results = await cache.recallCandidates(
                CandidateRecallQuery(engine: .fftAudioAnalyzer(), schemaVersion: 1, bpm: BPMWindow(seedBPM: 174))
            )

            let expected: Set<String> = ["unity", "half", "double"]
            if Set(results) == expected {
                report.lines.append("BPM recall at 174 finds unity/half/double-time matches (\(results.sorted())), excludes unrelated tempo and near-miss")
            } else {
                report.failures.append("BPM half/double recall: expected \(expected), got \(Set(results))")
            }

            let unityOnly = await cache.recallCandidates(
                CandidateRecallQuery(engine: .fftAudioAnalyzer(), schemaVersion: 1, bpm: BPMWindow(seedBPM: 174, includeHalfDouble: false))
            )
            if unityOnly == ["unity"] {
                report.lines.append("includeHalfDouble: false narrows recall back to the unity tempo only")
            } else {
                report.failures.append("includeHalfDouble: false: expected [\"unity\"], got \(unityOnly)")
            }
        } catch {
            report.failures.append("BPM half/double recall test threw: \(error)")
        }
    }

    private static func testCamelotKeySetRecall(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let seedKey = CamelotKey(wheelPosition: 8, mode: .major) // 8B / C major
        do {
            try await seedRecallRow(cache, trackId: "same", bpm: 120, key: CamelotKey(wheelPosition: 8, mode: .major))
            try await seedRecallRow(cache, trackId: "next", bpm: 120, key: CamelotKey(wheelPosition: 9, mode: .major))
            try await seedRecallRow(cache, trackId: "prev", bpm: 120, key: CamelotKey(wheelPosition: 7, mode: .major))
            try await seedRecallRow(cache, trackId: "relative-minor", bpm: 120, key: CamelotKey(wheelPosition: 8, mode: .minor))
            try await seedRecallRow(cache, trackId: "incompatible", bpm: 120, key: CamelotKey(wheelPosition: 1, mode: .major))

            let results = await cache.recallCandidates(
                CandidateRecallQuery(engine: .fftAudioAnalyzer(), schemaVersion: 1, key: seedKey)
            )
            let expected: Set<String> = ["same", "next", "prev", "relative-minor"]
            if Set(results) == expected {
                report.lines.append("Camelot recall for 8B finds same/adjacent/relative-minor (\(results.sorted())), excludes the non-adjacent 1B")
            } else {
                report.failures.append("Camelot key recall: expected \(expected), got \(Set(results))")
            }
        } catch {
            report.failures.append("Camelot key recall test threw: \(error)")
        }
    }

    private static func testRecallNullFeatureScopedToItsOwnFilter(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            try await seedRecallRow(cache, trackId: "bpm-only", bpm: 120)

            let byBPM = await cache.recallCandidates(
                CandidateRecallQuery(engine: .fftAudioAnalyzer(), schemaVersion: 1, bpm: BPMWindow(seedBPM: 120))
            )
            if byBPM == ["bpm-only"] {
                report.lines.append("a row with no key/genre is still found by a BPM-only query — NULL key doesn't leak into an unrelated filter")
            } else {
                report.failures.append("NULL-scoping (BPM query): expected [\"bpm-only\"], got \(byBPM)")
            }

            let byKey = await cache.recallCandidates(
                CandidateRecallQuery(engine: .fftAudioAnalyzer(), schemaVersion: 1, key: CamelotKey(wheelPosition: 8, mode: .major))
            )
            if byKey.isEmpty {
                report.lines.append("the same row is correctly absent from a key-filtered query (its key is genuinely unknown)")
            } else {
                report.failures.append("NULL-scoping (key query): expected [], got \(byKey)")
            }

            let coverage = await cache.featureCoverage(engine: .fftAudioAnalyzer(), schemaVersion: 1)
            let byGenre = await cache.recallCandidates(
                CandidateRecallQuery(engine: .fftAudioAnalyzer(), schemaVersion: 1, genre: "house")
            )
            if coverage.withGenre == 0, byGenre.isEmpty {
                report.lines.append("genre filter with zero genre coverage (\(coverage)) returns an honest empty result, not a crash or false match")
            } else {
                report.failures.append("genre-with-no-data: coverage=\(coverage), byGenre=\(byGenre)")
            }
        } catch {
            report.failures.append("NULL-scoping test threw: \(error)")
        }
    }

    private static func testRecallQueryUsesIndex(_ report: inout Report) async {
        let (cache, dir) = scratchCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            for i in 0..<20 {
                try await seedRecallRow(cache, trackId: "t\(i)", bpm: Double(100 + i), key: CamelotKey(wheelPosition: (i % 12) + 1, mode: i % 2 == 0 ? .major : .minor), genre: i % 3 == 0 ? "house" : nil)
            }

            let query = CandidateRecallQuery(
                engine: .fftAudioAnalyzer(),
                schemaVersion: 1,
                excludingTrackId: "t0",
                bpm: BPMWindow(seedBPM: 120),
                key: CamelotKey(wheelPosition: 8, mode: .major),
                genre: "house"
            )
            let plan = await cache.explainRecallQueryPlan(query)
            let planText = plan.joined(separator: " | ")
            let scansWholeTable = plan.contains { $0.contains("SCAN analysis") || $0.contains("SCAN TABLE analysis") }

            if !plan.isEmpty, !scansWholeTable {
                report.lines.append("recall query plan uses an index, not a full table scan: \(planText)")
            } else {
                report.failures.append("recall query plan: expected an index SEARCH with no full SCAN, got: \(planText)")
            }
        } catch {
            report.failures.append("query plan test threw: \(error)")
        }
    }
}
#endif
