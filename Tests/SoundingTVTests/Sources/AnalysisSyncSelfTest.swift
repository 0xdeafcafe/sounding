import Foundation
import CryptoKit
@testable import SoundingTV

#if DEBUG

enum AnalysisSyncSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[AnalysisSyncTest] \(status)"] + lines.map { "[AnalysisSyncTest]   \($0)" }
                + failures.map { "[AnalysisSyncTest]   ✗ \($0)" }).joined(separator: "\n")
        }

        mutating func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                lines.append(name)
            } else {
                let suffix = detail()
                failures.append(suffix.isEmpty ? name : "\(name): \(suffix)")
            }
        }
    }

    static func record(
        trackId: String,
        engineName: String = "sounding.fftAudioAnalyzer",
        engineVersion: Int = 1,
        schemaVersion: Int = 1,
        durationMillis: Int = 180_000,
        preset: String = "aac_256k",
        bitrate: Int = 256,
        codec: String = "aac",
        payloadJSON: String = #"{"bpm":128,"beats":[0,0.5,1]}"#,
        bpm: Double? = 128,
        keyWheelPosition: Int? = 8,
        keyMode: Int? = 1,
        genre: String? = nil,
        producedAtMillis: Int64 = 1_000,
        producerId: String = "device-a",
        overrideCacheKey: String? = nil,
        overrideDigest: String? = nil,
        overrideUncompressedSize: Int? = nil
    ) -> AnalysisSyncRecord {
        let plain = Data(payloadJSON.utf8)
        let (bytes, encoding) = AnalysisPayloadCodec.encode(plain)
        let derived = "\(trackId)#\(engineName)#\(engineVersion)#\(schemaVersion)#"
            + "\(durationMillis)#\(preset)#\(bitrate)#\(codec)"
        return AnalysisSyncRecord(
            cacheKey: overrideCacheKey ?? derived,
            trackId: trackId,
            engineName: engineName,
            engineVersion: engineVersion,
            schemaVersion: schemaVersion,
            durationMillis: durationMillis,
            preset: preset,
            bitrate: bitrate,
            codec: codec,
            payload: bytes,
            payloadEncoding: encoding,
            uncompressedByteSize: overrideUncompressedSize ?? plain.count,
            payloadDigest: overrideDigest ?? AnalysisPayloadCodec.digest(ofUncompressed: plain),
            bpm: bpm,
            keyWheelPosition: keyWheelPosition,
            keyMode: keyMode,
            genre: genre,
            producedAtMillis: producedAtMillis,
            producerId: producerId
        )
    }

    static func summary(of record: AnalysisSyncRecord) -> AnalysisSyncLocalSummary {
        AnalysisSyncLocalSummary(
            cacheKey: record.cacheKey,
            payloadDigest: record.payloadDigest,
            byteSize: record.uncompressedByteSize,
            producedAtMillis: record.producedAtMillis,
            producerId: record.producerId
        )
    }

    actor MemoryStore: AnalysisSyncStore {
        private var rows: [String: AnalysisSyncRecord] = [:]
        private var lastAccessed: [String: Int64] = [:]
        private var budget: Int64

        init(budget: Int64 = 10_000_000, seed: [AnalysisSyncRecord] = []) {
            self.budget = budget
            for (index, record) in seed.enumerated() {
                rows[record.cacheKey] = record
                lastAccessed[record.cacheKey] = Int64(index)
            }
        }

        func exportCandidates(limit: Int) async -> [AnalysisSyncExportCandidate] {
            rows.values
                .prefix(limit)
                .map { .init(record: $0, lastAccessedAtMillis: lastAccessed[$0.cacheKey] ?? 0) }
        }

        func localSummaries(for cacheKeys: [String]) async -> [String: AnalysisSyncLocalSummary] {
            var out: [String: AnalysisSyncLocalSummary] = [:]
            for key in cacheKeys {
                guard let row = rows[key] else { continue }
                out[key] = AnalysisSyncSelfTest.summary(of: row)
            }
            return out
        }

        func localFeatureCoverage(for cacheKeys: [String]) async -> [String: Int] {
            var out: [String: Int] = [:]
            for key in cacheKeys {
                guard let row = rows[key] else { continue }
                out[key] = row.featureCoverage
            }
            return out
        }

        func adopt(_ records: [AnalysisSyncRecord]) async -> Int {
            for record in records { rows[record.cacheKey] = record }
            return records.count
        }

        func freeBytes() async -> Int64 {
            let used = rows.values.reduce(Int64(0)) { $0 + Int64($1.uncompressedByteSize) }
            return max(0, budget - used)
        }

        func contains(_ cacheKey: String) -> Bool { rows[cacheKey] != nil }
        func digest(_ cacheKey: String) -> String? { rows[cacheKey]?.payloadDigest }
        var count: Int { rows.count }
    }

    struct MemoryTransport: AnalysisSyncTransport {
        let transportId = "memory"
        let ready: Bool
        let inbound: [AnalysisSyncRecord]
        let offered: OfferSink

        actor OfferSink {
            private(set) var records: [AnalysisSyncRecord] = []
            func record(_ new: [AnalysisSyncRecord]) { records.append(contentsOf: new) }
            var count: Int { records.count }
        }

        init(ready: Bool = true, inbound: [AnalysisSyncRecord] = [], offered: OfferSink = OfferSink()) {
            self.ready = ready
            self.inbound = inbound
            self.offered = offered
        }

        func isReady() async -> Bool { ready }
        func offer(_ records: [AnalysisSyncRecord]) async throws { await offered.record(records) }
        func fetch(since cursor: AnalysisSyncCursor?) async throws -> (records: [AnalysisSyncRecord], cursor: AnalysisSyncCursor?) {
            (inbound, AnalysisSyncCursor(bytes: Data("1".utf8)))
        }
    }

    static func run() async -> Report {
        var report = Report()
        testCodecRoundTrip(&report)
        testValidation(&report)
        testEntitlementLocatorGuard(&report)
        testIdempotencyShortCircuit(&report)
        testLastWriterWins(&report)
        testEvictionNeverDeletesRemotely(&report)
        testExportBudget(&report)
        testEngineScope(&report)
        testImportDefersRatherThanEvicting(&report)
        testCoverageRegressionIsReported(&report)
        await testRelayRoundTrip(&report)
        await testRelayIsIdempotent(&report)
        await testAnalysisCacheConformsToSyncStore(&report)
        return report
    }

    private static func testAnalysisCacheConformsToSyncStore(_ report: inout Report) async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisSyncSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = AnalysisCache(directory: dir)

        struct Fixture: Codable, Sendable, Equatable { let bpm: Double }
        let key = AnalysisCacheKey(
            trackId: "local-1", engine: .fftAudioAnalyzer(), schemaVersion: 1,
            fingerprint: AnalyzedAudioFingerprint(durationMillis: 180_000, preset: "aac_256k", bitrate: 256, codec: "aac")
        )
        do {
            _ = try await cache.value(for: key, as: Fixture.self, compute: { Fixture(bpm: 128) }) {
                AnalysisFeatures(bpm: $0.bpm, key: CamelotKey(wheelPosition: 8, mode: .major), genre: "house")
            }
        } catch {
            report.failures.append("seeding the scratch cache threw: \(error)")
            return
        }

        let candidates = await cache.exportCandidates(limit: 10)
        let localDeviceId = AnalysisSyncIdentity.producerId(defaults: .standard)
        report.expect(
            "a locally-computed row exports with this device as producer and a matching digest",
            candidates.count == 1
                && candidates[0].record.producerId == localDeviceId
                && candidates[0].record.payloadDigest == AnalysisPayloadCodec.digest(ofUncompressed: Data(#"{"bpm":128}"#.utf8))
                && AnalysisSyncPolicy.validate(candidates[0].record) == nil,
            "candidates=\(candidates.count), validate=\(candidates.first.map { String(describing: AnalysisSyncPolicy.validate($0.record)) } ?? "n/a")"
        )

        let summaries = await cache.localSummaries(for: [key.stableKey])
        report.expect(
            "localSummaries reports the same digest exportCandidates offered — the idempotency shortcut depends on this",
            summaries[key.stableKey]?.payloadDigest == candidates.first?.record.payloadDigest
        )

        let coverage = await cache.localFeatureCoverage(for: [key.stableKey])
        report.expect("feature coverage reflects bpm + key + genre all populated", coverage[key.stableKey] == 3)

        let foreign = record(trackId: "remote-1", producedAtMillis: 42, producerId: "device-far-away")
        let adoptedCount = await cache.adopt([foreign])
        let foreignSummary = await cache.localSummaries(for: [foreign.cacheKey])
        report.expect(
            "an adopted row keeps its original producer's provenance, not this device's",
            adoptedCount == 1
                && foreignSummary[foreign.cacheKey]?.producerId == "device-far-away"
                && foreignSummary[foreign.cacheKey]?.producedAtMillis == 42,
            "adopted=\(adoptedCount), summary=\(String(describing: foreignSummary[foreign.cacheKey]))"
        )

        let free = await cache.freeBytes()
        report.expect("freeBytes stays within the cache's own budget", free >= 0 && free <= AnalysisCache.defaultMaxBytes)
    }

    private static func testCodecRoundTrip(_ report: inout Report) {
        let beats = (0..<400).map { String(format: "%.3f", Double($0) * 0.46875) }.joined(separator: ",")
        let plain = Data(#"{"bpm":128,"beats":["#.utf8) + Data(beats.utf8) + Data("]}".utf8)
        let (bytes, encoding) = AnalysisPayloadCodec.encode(plain)
        let back = AnalysisPayloadCodec.decode(bytes, encoding: encoding)

        report.expect(
            "codec round-trips a realistic beat grid (\(plain.count)B → \(bytes.count)B, \(encoding.rawValue))",
            back == plain && encoding == .zlib && bytes.count < plain.count,
            "encoding=\(encoding.rawValue), in=\(plain.count), out=\(bytes.count), roundTrip=\(back == plain)"
        )

        let tiny = Data("{}".utf8)
        let (tinyBytes, tinyEncoding) = AnalysisPayloadCodec.encode(tiny)
        report.expect(
            "a payload that compresses larger is sent raw",
            tinyEncoding == .raw && tinyBytes == tiny,
            "encoding=\(tinyEncoding.rawValue), bytes=\(tinyBytes.count) vs \(tiny.count)"
        )

        report.expect(
            "digest is over uncompressed bytes, so encoding choice can't fake a conflict",
            AnalysisPayloadCodec.digest(ofUncompressed: plain)
                == AnalysisPayloadCodec.digest(ofUncompressed: back ?? Data())
        )
    }

    private static func testValidation(_ report: inout Report) {
        report.expect("a well-formed record validates", AnalysisSyncPolicy.validate(record(trackId: "1")) == nil,
                      String(describing: AnalysisSyncPolicy.validate(record(trackId: "1"))))

        let forged = record(trackId: "1", overrideCacheKey: "2#sounding.fftAudioAnalyzer#1#1#180000#aac_256k#256#aac")
        report.expect("a cacheKey that disagrees with its identity fields is refused",
                      AnalysisSyncPolicy.validate(forged) == .identityMismatch,
                      String(describing: AnalysisSyncPolicy.validate(forged)))

        let wrongDigest = record(trackId: "1", overrideDigest: "AAAA")
        report.expect("a record whose payload doesn't match its digest is refused",
                      AnalysisSyncPolicy.validate(wrongDigest) == .digestMismatch,
                      String(describing: AnalysisSyncPolicy.validate(wrongDigest)))

        let oversize = record(
            trackId: "1",
            payloadJSON: "{\"x\":\"" + String(repeating: "a", count: 8) + "\"}",
            overrideUncompressedSize: AnalysisSyncPolicy.maxRecordPayloadBytes + 1
        )
        report.expect("a payload past the per-record cap is refused",
                      AnalysisSyncPolicy.validate(oversize) == .oversizePayload,
                      String(describing: AnalysisSyncPolicy.validate(oversize)))

        let blankTrack = record(trackId: "")
        report.expect("a blank track id is refused",
                      AnalysisSyncPolicy.validate(blankTrack) == .malformedIdentity,
                      String(describing: AnalysisSyncPolicy.validate(blankTrack)))
    }

    private static func testEntitlementLocatorGuard(_ report: inout Report) {
        let cases: [(String, String)] = [
            ("an https stream URL", #"{"bpm":128,"src":"https://cf-hls-media.sndcdn.com/x.m3u8"}"#),
            ("a scheme-relative locator", #"{"bpm":128,"src":"//sndcdn.com/x"}"#),
            ("a bare SoundCloud host", #"{"bpm":128,"note":"from soundcloud.com"}"#),
        ]
        for (name, json) in cases {
            let smuggler = record(trackId: "1", payloadJSON: json)
            report.expect("payload containing \(name) is refused",
                          AnalysisSyncPolicy.validate(smuggler) == .payloadCarriesLocator,
                          String(describing: AnalysisSyncPolicy.validate(smuggler)))
        }

        report.expect("ordinary derived metadata is unaffected by the locator guard",
                      !AnalysisSyncPolicy.carriesLocator(Data(#"{"bpm":174.03,"key":"8B","bars":[0,1,2]}"#.utf8)))

        report.expect("a payload that isn't valid UTF-8 is treated as carrying a locator (refused)",
                      AnalysisSyncPolicy.carriesLocator(Data([0xFF, 0xFE, 0x00, 0x01])))
    }

    private static func testIdempotencyShortCircuit(_ report: inout Report) {
        let mine = record(trackId: "1", producedAtMillis: 100, producerId: "device-a")
        let theirs = record(trackId: "1", producedAtMillis: 999_999, producerId: "device-z")

        report.expect("identical payloads converge: the newer copy does not overwrite",
                      theirs.payloadDigest == mine.payloadDigest
                          && !AnalysisSyncPolicy.remoteWins(local: summary(of: mine), remote: theirs))

        let plan = AnalysisSyncPolicy.planImport(
            incoming: [theirs], freeBytes: 10_000_000, localSummary: { _ in summary(of: mine) }
        )
        report.expect("import plan reports it as converged, adopts nothing",
                      plan.adopt.isEmpty && plan.converged == [mine.cacheKey],
                      "adopt=\(plan.adopt.count), converged=\(plan.converged)")
    }

    private static func testLastWriterWins(_ report: inout Report) {
        let old = record(trackId: "1", payloadJSON: #"{"bpm":128}"#, producedAtMillis: 100, producerId: "device-a")
        let new = record(trackId: "1", payloadJSON: #"{"bpm":174}"#, producedAtMillis: 200, producerId: "device-b")

        report.expect("on a genuine mismatch the newer record wins",
                      AnalysisSyncPolicy.remoteWins(local: summary(of: old), remote: new))
        report.expect("and the older one does not",
                      !AnalysisSyncPolicy.remoteWins(local: summary(of: new), remote: old))

        let tieA = record(trackId: "1", payloadJSON: #"{"bpm":128}"#, producedAtMillis: 500, producerId: "aaa")
        let tieB = record(trackId: "1", payloadJSON: #"{"bpm":174}"#, producedAtMillis: 500, producerId: "zzz")
        let aSeesB = AnalysisSyncPolicy.remoteWins(local: summary(of: tieA), remote: tieB)
        let bSeesA = AnalysisSyncPolicy.remoteWins(local: summary(of: tieB), remote: tieA)
        report.expect("an exact timestamp tie is broken deterministically — both devices converge on the same winner",
                      aSeesB && !bSeesA, "aSeesB=\(aSeesB), bSeesA=\(bSeesA)")

        report.expect("a key this device has never seen is always adopted",
                      AnalysisSyncPolicy.remoteWins(local: nil, remote: old))
    }

    private static func testEvictionNeverDeletesRemotely(_ report: inout Report) {
        let evicted = ["a", "b", "c"]
        report.expect("local LRU eviction propagates no remote deletions (closes the evict↔re-upload loop)",
                      AnalysisSyncPolicy.remoteDeletions(forLocalEviction: evicted).isEmpty)
    }

    private static func testExportBudget(_ report: inout Report) {
        let a = record(trackId: "a", payloadJSON: #"{"bpm":100}"#)
        let b = record(trackId: "b", payloadJSON: #"{"bpm":110}"#)
        let c = record(trackId: "c", payloadJSON: #"{"bpm":120}"#)
        let size = Int64(a.uncompressedByteSize)

        let selection = AnalysisSyncPolicy.selectForExport(
            candidates: [
                .init(record: a, lastAccessedAtMillis: 1),
                .init(record: b, lastAccessedAtMillis: 3),
                .init(record: c, lastAccessedAtMillis: 2),
            ],
            budgetBytes: size * 2
        )
        report.expect("export offers most-recently-used first and stops at the remote budget",
                      selection.offer.map(\.trackId) == ["b", "c"] && selection.skippedForBudget.count == 1,
                      "offer=\(selection.offer.map(\.trackId)), skipped=\(selection.skippedForBudget.count)")

        let bad = record(trackId: "d", overrideDigest: "AAAA")
        let withBad = AnalysisSyncPolicy.selectForExport(
            candidates: [.init(record: bad, lastAccessedAtMillis: 9), .init(record: a, lastAccessedAtMillis: 1)],
            budgetBytes: 1_000_000
        )
        report.expect("an unsendable row is dropped from the offer without blocking the rest",
                      withBad.offer.map(\.trackId) == ["a"] && withBad.rejected.count == 1,
                      "offer=\(withBad.offer.map(\.trackId)), rejected=\(withBad.rejected.count)")
    }

    private static func testEngineScope(_ report: inout Report) {
        let unlisted = record(trackId: "1", engineName: "apple.musicUnderstanding")
        let selection = AnalysisSyncPolicy.selectForExport(
            candidates: [.init(record: unlisted, lastAccessedAtMillis: 1)], budgetBytes: 1_000_000
        )
        report.expect("an engine not on the allowlist is never offered",
                      selection.offer.isEmpty, "offer=\(selection.offer.count)")

        let plan = AnalysisSyncPolicy.planImport(
            incoming: [unlisted], freeBytes: 10_000_000, localSummary: { _ in nil }
        )
        report.expect("and is never adopted either — the allowlist is symmetric",
                      plan.adopt.isEmpty && plan.keptLocal == [unlisted.cacheKey],
                      "adopt=\(plan.adopt.count), keptLocal=\(plan.keptLocal.count)")

        report.expect("MusicUnderstanding is deliberately absent from the default scope until determinism is measured",
                      !AnalysisSyncEngineScope.default.allows(engineName: "apple.musicUnderstanding"))
    }

    private static func testImportDefersRatherThanEvicting(_ report: inout Report) {
        let incoming = (0..<10).map { record(trackId: "in-\($0)", payloadJSON: #"{"bpm":1\#($0)0}"#) }
        let each = Int64(incoming[0].uncompressedByteSize)

        let plan = AnalysisSyncPolicy.planImport(
            incoming: incoming, freeBytes: each * 4, localSummary: { _ in nil }
        )
        let adoptedBytes = Int64(plan.adoptedByteSize)
        report.expect("import adopts only what fits in half the free budget, defers the rest — never evicts to make room",
                      plan.adopt.count == 2 && plan.deferredForBudget.count == 8 && adoptedBytes <= each * 4,
                      "adopt=\(plan.adopt.count), deferred=\(plan.deferredForBudget.count), bytes=\(adoptedBytes)/\(each * 4)")

        let full = AnalysisSyncPolicy.planImport(incoming: incoming, freeBytes: 0, localSummary: { _ in nil })
        report.expect("a device already at its budget adopts nothing rather than evicting its own rows",
                      full.adopt.isEmpty && full.deferredForBudget.count == incoming.count)

        let existing = record(trackId: "x", payloadJSON: #"{"bpm":100}"#, producedAtMillis: 1)
        let correction = record(trackId: "x", payloadJSON: #"{"bpm":174}"#, producedAtMillis: 2)
        let replace = AnalysisSyncPolicy.planImport(
            incoming: [correction], freeBytes: 0, localSummary: { _ in summary(of: existing) }
        )
        report.expect("a same-size replacement is net-neutral and lands even on a full device",
                      replace.adopt.count == 1, "adopt=\(replace.adopt.count), deferred=\(replace.deferredForBudget)")
    }

    private static func testCoverageRegressionIsReported(_ report: inout Report) {
        let complete = record(trackId: "1", payloadJSON: #"{"bpm":128}"#,
                              bpm: 128, keyWheelPosition: 8, keyMode: 1, genre: "house",
                              producedAtMillis: 100)
        let thinnerButNewer = record(trackId: "1", payloadJSON: #"{"bpm":174}"#,
                                     bpm: 174, keyWheelPosition: nil, keyMode: nil, genre: nil,
                                     producedAtMillis: 200)
        let plan = AnalysisSyncPolicy.planImport(
            incoming: [thinnerButNewer],
            freeBytes: 10_000_000,
            localSummary: { _ in summary(of: complete) },
            localCoverage: { _ in complete.featureCoverage }
        )
        report.expect("a newer but thinner row still wins LWW, and the coverage regression is reported not hidden",
                      plan.adopt.count == 1 && plan.coverageRegressions == [complete.cacheKey],
                      "adopt=\(plan.adopt.count), regressions=\(plan.coverageRegressions)")
    }

    private static func testRelayRoundTrip(_ report: inout Report) async {
        let mine = record(trackId: "mine", producerId: "device-a")
        let theirs = record(trackId: "theirs", producerId: "device-b", overrideCacheKey: nil)
        let store = MemoryStore(seed: [mine])
        let sink = MemoryTransport.OfferSink()
        let transport = MemoryTransport(inbound: [theirs], offered: sink)
        let relay = AnalysisSyncRelay(store: store, transport: transport)

        do {
            let result = try await relay.runOnce(since: nil)
            let adoptedTheirs = await store.contains(theirs.cacheKey)
            let offeredIds = await sink.records.map(\.trackId).sorted()
            report.expect(
                "relay pulls a peer's row, adopts it, then offers both back (fetched \(result.fetched), adopted \(result.adopted), offered \(result.offered))",
                result.adopted == 1 && adoptedTheirs && offeredIds == ["mine", "theirs"],
                "adopted=\(result.adopted), hasTheirs=\(adoptedTheirs), offered=\(offeredIds)"
            )
            report.expect("relay returns the transport's cursor for the next round", result.cursor != nil)
        } catch {
            report.failures.append("relay round trip threw: \(error)")
        }

        let notReady = AnalysisSyncRelay(store: MemoryStore(), transport: MemoryTransport(ready: false))
        do {
            let skipped = try await notReady.runOnce(since: nil)
            report.expect("a transport that isn't ready is an inert skip, not an error",
                          skipped.skippedNotReady && skipped.fetched == 0 && skipped.offered == 0)
        } catch {
            report.failures.append("not-ready relay threw: \(error)")
        }
    }

    private static func testRelayIsIdempotent(_ report: inout Report) async {
        let theirs = record(trackId: "shared", producerId: "device-b")
        let store = MemoryStore()
        let transport = MemoryTransport(inbound: [theirs])
        let relay = AnalysisSyncRelay(store: store, transport: transport)

        do {
            let first = try await relay.runOnce(since: nil)
            let second = try await relay.runOnce(since: first.cursor)
            let rowCount = await store.count
            report.expect(
                "replaying the same batch adopts once then converges — a record arriving over both channels costs one digest compare",
                first.adopted == 1 && second.adopted == 0 && second.converged == 1 && rowCount == 1,
                "first=\(first.adopted), second adopted=\(second.adopted) converged=\(second.converged), rows=\(rowCount)"
            )
        } catch {
            report.failures.append("relay idempotency test threw: \(error)")
        }
    }
}
#endif
