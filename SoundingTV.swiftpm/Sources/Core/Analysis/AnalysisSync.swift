import Foundation
import CryptoKit

enum AnalysisPayloadEncoding: String, Codable, Sendable {
    case raw
    case zlib
}

enum AnalysisPayloadCodec {
    static func digest(ofUncompressed data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    static func encode(_ data: Data) -> (bytes: Data, encoding: AnalysisPayloadEncoding) {
        guard !data.isEmpty else { return (data, .raw) }
        guard let compressed = try? (data as NSData).compressed(using: .zlib) as Data else {
            return (data, .raw)
        }
        return compressed.count < data.count ? (compressed, .zlib) : (data, .raw)
    }

    static func decode(_ data: Data, encoding: AnalysisPayloadEncoding) -> Data? {
        switch encoding {
        case .raw:
            return data
        case .zlib:
            return try? (data as NSData).decompressed(using: .zlib) as Data
        }
    }
}

struct AnalysisSyncRecord: Codable, Sendable, Equatable {
    let cacheKey: String
    let trackId: String
    let engineName: String
    let engineVersion: Int
    let schemaVersion: Int
    let durationMillis: Int
    let preset: String
    let bitrate: Int
    let codec: String

    let payload: Data
    let payloadEncoding: AnalysisPayloadEncoding
    let uncompressedByteSize: Int
    let payloadDigest: String

    let bpm: Double?
    let keyWheelPosition: Int?
    let keyMode: Int?
    let genre: String?

    let producedAtMillis: Int64
    let producerId: String

    var derivedCacheKey: String {
        "\(trackId)#\(engineName)#\(engineVersion)#\(schemaVersion)#"
            + "\(durationMillis)#\(preset)#\(bitrate)#\(codec)"
    }

    var identityMatchesCacheKey: Bool { derivedCacheKey == cacheKey }

    var featureCoverage: Int {
        [bpm != nil, keyWheelPosition != nil, keyMode != nil, genre != nil]
            .reduce(0) { $0 + ($1 ? 1 : 0) }
    }
}

struct AnalysisSyncLocalSummary: Sendable, Equatable {
    let cacheKey: String
    let payloadDigest: String
    let byteSize: Int
    let producedAtMillis: Int64
    let producerId: String
}

struct AnalysisSyncExportCandidate: Sendable, Equatable {
    let record: AnalysisSyncRecord
    let lastAccessedAtMillis: Int64
}

enum AnalysisSyncIdentity {
    static let defaultsKey = "red.forbes.sounding.analysissync.producerId"

    static func producerId(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: defaultsKey)
        return generated
    }
}

enum AnalysisSyncPolicy {

    static let maxRecordPayloadBytes = 256 * 1024

    static let defaultRemoteBudgetBytes: Int64 = 50_000_000

    static let importBatchFreeSpaceFraction = 0.5

    enum Rejection: String, Sendable, Equatable {
        case oversizePayload
        case emptyPayload
        case identityMismatch
        case malformedIdentity
        case undecodablePayload
        case digestMismatch
        case payloadCarriesLocator
    }

    private static let locatorMarkers = ["http://", "https://", "://", "soundcloud.com", "sndcdn.com"]

    static func validate(_ record: AnalysisSyncRecord) -> Rejection? {
        guard !record.trackId.isEmpty,
              !record.engineName.isEmpty,
              !record.cacheKey.isEmpty,
              record.engineVersion >= 0,
              record.schemaVersion >= 0,
              record.durationMillis > 0,
              record.bitrate >= 0 else {
            return .malformedIdentity
        }
        guard record.identityMatchesCacheKey else { return .identityMismatch }
        guard record.uncompressedByteSize > 0, !record.payload.isEmpty else { return .emptyPayload }
        guard record.uncompressedByteSize <= maxRecordPayloadBytes else { return .oversizePayload }

        guard let plain = AnalysisPayloadCodec.decode(record.payload, encoding: record.payloadEncoding) else {
            return .undecodablePayload
        }
        guard plain.count == record.uncompressedByteSize else { return .digestMismatch }
        guard AnalysisPayloadCodec.digest(ofUncompressed: plain) == record.payloadDigest else {
            return .digestMismatch
        }
        guard !carriesLocator(plain) else { return .payloadCarriesLocator }
        return nil
    }

    static func carriesLocator(_ payload: Data) -> Bool {
        guard let text = String(data: payload, encoding: .utf8) else { return true }
        let lowered = text.lowercased()
        return locatorMarkers.contains { lowered.contains($0) }
    }

    static func remoteWins(local: AnalysisSyncLocalSummary?, remote: AnalysisSyncRecord) -> Bool {
        guard let local else { return true }
        if local.payloadDigest == remote.payloadDigest { return false }
        if remote.producedAtMillis != local.producedAtMillis {
            return remote.producedAtMillis > local.producedAtMillis
        }
        return remote.producerId > local.producerId
    }

    static func remoteDeletions(forLocalEviction cacheKeys: [String]) -> [String] { [] }

    static func selectForExport(
        candidates: [AnalysisSyncExportCandidate],
        budgetBytes: Int64 = defaultRemoteBudgetBytes,
        scope: AnalysisSyncEngineScope = .default
    ) -> (offer: [AnalysisSyncRecord], rejected: [(cacheKey: String, reason: Rejection)], skippedForBudget: [String]) {
        var offer: [AnalysisSyncRecord] = []
        var rejected: [(cacheKey: String, reason: Rejection)] = []
        var skippedForBudget: [String] = []
        var spent: Int64 = 0

        for candidate in candidates.sorted(by: { $0.lastAccessedAtMillis > $1.lastAccessedAtMillis }) {
            let record = candidate.record
            guard scope.allows(engineName: record.engineName) else {
                skippedForBudget.append(record.cacheKey)
                continue
            }
            if let reason = validate(record) {
                rejected.append((record.cacheKey, reason))
                continue
            }
            let size = Int64(record.uncompressedByteSize)
            guard spent + size <= budgetBytes else {
                skippedForBudget.append(record.cacheKey)
                continue
            }
            spent += size
            offer.append(record)
        }
        return (offer, rejected, skippedForBudget)
    }

    struct ImportPlan: Sendable, Equatable {
        var adopt: [AnalysisSyncRecord] = []
        var converged: [String] = []
        var keptLocal: [String] = []
        var rejected: [String: Rejection] = [:]
        var deferredForBudget: [String] = []
        var coverageRegressions: [String] = []

        var adoptedByteSize: Int {
            adopt.reduce(0) { $0 + $1.uncompressedByteSize }
        }
    }

    static func planImport(
        incoming: [AnalysisSyncRecord],
        freeBytes: Int64,
        localSummary: (String) -> AnalysisSyncLocalSummary?,
        localCoverage: (String) -> Int = { _ in 0 },
        scope: AnalysisSyncEngineScope = .default
    ) -> ImportPlan {
        var plan = ImportPlan()
        let allowance = Int64(Double(max(0, freeBytes)) * importBatchFreeSpaceFraction)
        var spent: Int64 = 0

        for record in incoming {
            guard scope.allows(engineName: record.engineName) else {
                plan.keptLocal.append(record.cacheKey)
                continue
            }
            if let reason = validate(record) {
                plan.rejected[record.cacheKey] = reason
                continue
            }

            let local = localSummary(record.cacheKey)
            if let local, local.payloadDigest == record.payloadDigest {
                plan.converged.append(record.cacheKey)
                continue
            }
            guard remoteWins(local: local, remote: record) else {
                plan.keptLocal.append(record.cacheKey)
                continue
            }

            let delta = Int64(record.uncompressedByteSize - (local?.byteSize ?? 0))
            if delta > 0, spent + delta > allowance {
                plan.deferredForBudget.append(record.cacheKey)
                continue
            }
            spent += max(0, delta)

            if local != nil, record.featureCoverage < localCoverage(record.cacheKey) {
                plan.coverageRegressions.append(record.cacheKey)
            }
            plan.adopt.append(record)
        }
        return plan
    }
}

struct AnalysisSyncEngineScope: Sendable, Equatable {
    let allowedEngineNames: Set<String>

    func allows(engineName: String) -> Bool { allowedEngineNames.contains(engineName) }

    static let `default` = AnalysisSyncEngineScope(allowedEngineNames: [
        "apple.musicUnderstanding",
        "sounding.beatTracker",
        "sounding.genreTaxonomy",
        "sounding.userCorrection",
        "soundcloud.waveform",
    ])

    static let none = AnalysisSyncEngineScope(allowedEngineNames: [])
}

struct AnalysisSyncCursor: Codable, Sendable, Equatable {
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
}

protocol AnalysisSyncTransport: Sendable {
    var transportId: String { get }
    func isReady() async -> Bool
    func offer(_ records: [AnalysisSyncRecord]) async throws
    func fetch(since cursor: AnalysisSyncCursor?) async throws -> (records: [AnalysisSyncRecord], cursor: AnalysisSyncCursor?)
}

protocol AnalysisSyncStore: Sendable {
    func exportCandidates(limit: Int) async -> [AnalysisSyncExportCandidate]
    func localSummaries(for cacheKeys: [String]) async -> [String: AnalysisSyncLocalSummary]
    func localFeatureCoverage(for cacheKeys: [String]) async -> [String: Int]
    func adopt(_ records: [AnalysisSyncRecord]) async -> Int
    func freeBytes() async -> Int64
}

struct AnalysisSyncRelay: Sendable {
    let store: any AnalysisSyncStore
    let transport: any AnalysisSyncTransport
    let scope: AnalysisSyncEngineScope
    let exportBudgetBytes: Int64
    let exportCandidateLimit: Int

    init(
        store: any AnalysisSyncStore,
        transport: any AnalysisSyncTransport,
        scope: AnalysisSyncEngineScope = .default,
        exportBudgetBytes: Int64 = AnalysisSyncPolicy.defaultRemoteBudgetBytes,
        exportCandidateLimit: Int = 2_000
    ) {
        self.store = store
        self.transport = transport
        self.scope = scope
        self.exportBudgetBytes = exportBudgetBytes
        self.exportCandidateLimit = exportCandidateLimit
    }

    struct RoundResult: Sendable, Equatable {
        var offered = 0
        var offerRejected = 0
        var offerSkippedForBudget = 0
        var fetched = 0
        var adopted = 0
        var converged = 0
        var keptLocal = 0
        var importRejected = 0
        var deferredForBudget = 0
        var coverageRegressions = 0
        var cursor: AnalysisSyncCursor?
        var skippedNotReady = false
    }

    func runOnce(since cursor: AnalysisSyncCursor?) async throws -> RoundResult {
        var result = RoundResult()
        guard await transport.isReady() else {
            result.skippedNotReady = true
            return result
        }

        let (incoming, nextCursor) = try await transport.fetch(since: cursor)
        result.fetched = incoming.count
        result.cursor = nextCursor

        if !incoming.isEmpty {
            let keys = incoming.map(\.cacheKey)
            let summaries = await store.localSummaries(for: keys)
            let coverage = await store.localFeatureCoverage(for: keys)
            let free = await store.freeBytes()

            let plan = AnalysisSyncPolicy.planImport(
                incoming: incoming,
                freeBytes: free,
                localSummary: { summaries[$0] },
                localCoverage: { coverage[$0] ?? 0 },
                scope: scope
            )
            result.adopted = plan.adopt.isEmpty ? 0 : await store.adopt(plan.adopt)
            result.converged = plan.converged.count
            result.keptLocal = plan.keptLocal.count
            result.importRejected = plan.rejected.count
            result.deferredForBudget = plan.deferredForBudget.count
            result.coverageRegressions = plan.coverageRegressions.count
        }

        let candidates = await store.exportCandidates(limit: exportCandidateLimit)
        let selection = AnalysisSyncPolicy.selectForExport(
            candidates: candidates,
            budgetBytes: exportBudgetBytes,
            scope: scope
        )
        if !selection.offer.isEmpty {
            try await transport.offer(selection.offer)
        }
        result.offered = selection.offer.count
        result.offerRejected = selection.rejected.count
        result.offerSkippedForBudget = selection.skippedForBudget.count

        Log.sync.info(
            "\(transport.transportId, privacy: .public): fetched \(result.fetched, privacy: .public), adopted \(result.adopted, privacy: .public), converged \(result.converged, privacy: .public), offered \(result.offered, privacy: .public)"
        )
        return result
    }
}

struct AnalysisPeerBody: Codable, Sendable, Equatable {
    let records: [AnalysisSyncRecord]

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> AnalysisPeerBody? {
        try? JSONDecoder().decode(AnalysisPeerBody.self, from: data)
    }
}

enum AnalysisPeerPush {
    static let lookahead = 5

    static let scope = AnalysisSyncEngineScope(allowedEngineNames: [
        "apple.musicUnderstanding",
        "sounding.beatTracker",
        "sounding.genreTaxonomy",
        "sounding.userCorrection",
    ])

    static let measuredEngineNames: Set<String> = ["apple.musicUnderstanding", "sounding.beatTracker"]

    static func upcomingTrackIds(queue: [String], currentIndex: Int, limit: Int = lookahead) -> [String] {
        guard limit > 0, currentIndex + 1 < queue.count else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for id in queue[(max(0, currentIndex) + 1)...] where !id.isEmpty && seen.insert(id).inserted {
            out.append(id)
            if out.count == limit { break }
        }
        return out
    }

    static func needsMeasuredAnalysis(_ trackId: String, records: [AnalysisSyncRecord]) -> Bool {
        !records.contains { $0.trackId == trackId && measuredEngineNames.contains($0.engineName) }
    }

    static func batches(
        _ records: [AnalysisSyncRecord],
        alreadySent: Set<String>,
        maxRecords: Int = AnalysisPeerChunking.maxRecordsPerMessage,
        maxBytes: Int = AnalysisPeerChunking.maxBodyBytes
    ) -> [[AnalysisSyncRecord]] {
        var out: [[AnalysisSyncRecord]] = []
        var current: [AnalysisSyncRecord] = []
        var bytes = 0
        var seen = alreadySent
        for record in records {
            guard scope.allows(engineName: record.engineName),
                  AnalysisSyncPolicy.validate(record) == nil,
                  record.payload.count <= maxBytes,
                  seen.insert(sentKey(record)).inserted else { continue }
            if !current.isEmpty, current.count >= maxRecords || bytes + record.payload.count > maxBytes {
                out.append(current)
                current = []
                bytes = 0
            }
            current.append(record)
            bytes += record.payload.count
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    @discardableResult
    static func adopt(_ body: AnalysisPeerBody, into store: any AnalysisSyncStore) async -> Int {
        let records = Array(body.records.prefix(AnalysisPeerChunking.maxRecordsPerMessage))
        guard !records.isEmpty else { return 0 }
        let keys = records.map(\.cacheKey)
        let summaries = await store.localSummaries(for: keys)
        let coverage = await store.localFeatureCoverage(for: keys)
        let plan = AnalysisSyncPolicy.planImport(
            incoming: records,
            freeBytes: await store.freeBytes(),
            localSummary: { summaries[$0] },
            localCoverage: { coverage[$0] ?? 0 },
            scope: scope
        )
        guard !plan.adopt.isEmpty else { return 0 }
        return await store.adopt(plan.adopt)
    }

    static func sentKey(_ record: AnalysisSyncRecord) -> String {
        "\(record.cacheKey)|\(record.payloadDigest)"
    }
}
