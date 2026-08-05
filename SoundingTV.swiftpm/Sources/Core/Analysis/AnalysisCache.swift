import Foundation
import SQLite3

struct AnalysisEngineIdentity: Codable, Hashable, Sendable {
    let name: String
    let version: Int

    static func fftAudioAnalyzer(version: Int = 1) -> AnalysisEngineIdentity {
        .init(name: "sounding.fftAudioAnalyzer", version: version)
    }

    static func musicUnderstanding(version: Int = 1) -> AnalysisEngineIdentity {
        .init(name: "apple.musicUnderstanding", version: version)
    }

    static func soundCloudWaveform(version: Int = 1) -> AnalysisEngineIdentity {
        .init(name: "soundcloud.waveform", version: version)
    }

    static func genreTaxonomy(version: Int = 1) -> AnalysisEngineIdentity {
        .init(name: "sounding.genreTaxonomy", version: version)
    }

    static func userCorrection(version: Int = 1) -> AnalysisEngineIdentity {
        .init(name: "sounding.userCorrection", version: version)
    }
}

struct UserAnalysisCorrectionPayload: Codable, Sendable {
    let bpm: Double?
    let keyLabel: String?
    let genre: String?
    let updatedAt: Date
}

struct AnalyzedAudioFingerprint: Codable, Hashable, Sendable {
    let durationMillis: Int
    let preset: String
    let bitrate: Int
    let codec: String

    init?(duration: TimeInterval, transcoding: Transcoding?) {
        guard let transcoding else { return nil }
        durationMillis = Int((duration * 1000).rounded())
        preset = transcoding.preset ?? "unknown"
        bitrate = transcoding.bitrate
        codec = String(describing: transcoding.codec)
    }

    init(durationMillis: Int, preset: String, bitrate: Int, codec: String) {
        self.durationMillis = durationMillis
        self.preset = preset
        self.bitrate = bitrate
        self.codec = codec
    }
}

struct AnalysisCacheKey: Hashable, Sendable {
    let trackId: String
    let engine: AnalysisEngineIdentity
    let schemaVersion: Int
    let fingerprint: AnalyzedAudioFingerprint

    init(trackId: String, engine: AnalysisEngineIdentity, schemaVersion: Int, fingerprint: AnalyzedAudioFingerprint) {
        self.trackId = trackId
        self.engine = engine
        self.schemaVersion = schemaVersion
        self.fingerprint = fingerprint
    }

    init?(track: Track, transcoding: Transcoding?, engine: AnalysisEngineIdentity, schemaVersion: Int) {
        guard let fingerprint = AnalyzedAudioFingerprint(duration: track.duration, transcoding: transcoding) else { return nil }
        self.init(trackId: track.id, engine: engine, schemaVersion: schemaVersion, fingerprint: fingerprint)
    }

    var stableKey: String {
        "\(trackId)#\(engine.name)#\(engine.version)#\(schemaVersion)#"
            + "\(fingerprint.durationMillis)#\(fingerprint.preset)#\(fingerprint.bitrate)#\(fingerprint.codec)"
    }

    var generation: AnalysisGeneration {
        AnalysisGeneration(engine: engine, schemaVersion: schemaVersion)
    }

    init(trackId: String, generation: AnalysisGeneration, fingerprint: AnalyzedAudioFingerprint) {
        self.init(
            trackId: trackId, engine: generation.engine,
            schemaVersion: generation.schemaVersion, fingerprint: fingerprint
        )
    }

    init?(track: Track, transcoding: Transcoding?, generation: AnalysisGeneration) {
        guard let fingerprint = AnalyzedAudioFingerprint(duration: track.duration, transcoding: transcoding) else { return nil }
        self.init(trackId: track.id, generation: generation, fingerprint: fingerprint)
    }
}

struct AnalysisGeneration: Hashable, Sendable {
    let engine: AnalysisEngineIdentity
    let schemaVersion: Int

    init(engine: AnalysisEngineIdentity, schemaVersion: Int) {
        self.engine = engine
        self.schemaVersion = schemaVersion
    }
}

struct AnalysisRecallRow: Sendable, Equatable {
    let cacheKey: String
    let trackId: String
    let generation: AnalysisGeneration
    let fingerprint: AnalyzedAudioFingerprint
    let bpm: Double?
    let key: CamelotKey?
    let genre: String?
    let byteSize: Int
    let producedAt: Date
    let lastAccessedAt: Date
    let producerId: String?

    var features: AnalysisFeatures { AnalysisFeatures(bpm: bpm, key: key, genre: genre) }

    var hasIndexedValue: Bool { bpm != nil || key != nil || genre != nil }
}

enum AnalysisRecallScope: Sendable {
    case everything
    case engines([AnalysisEngineIdentity])
    case generations([AnalysisGeneration])
}

struct AnalysisFeatures: Sendable {
    var bpm: Double?
    var key: CamelotKey?
    var genre: String?

    init(bpm: Double? = nil, key: CamelotKey? = nil, genre: String? = nil) {
        self.bpm = bpm
        self.key = key
        self.genre = genre
    }
}

struct BPMWindow: Sendable {
    let seedBPM: Double
    var tolerancePercent: Double = 0.04
    var includeHalfDouble: Bool = true

    init(seedBPM: Double, tolerancePercent: Double = 0.04, includeHalfDouble: Bool = true) {
        self.seedBPM = seedBPM
        self.tolerancePercent = tolerancePercent
        self.includeHalfDouble = includeHalfDouble
    }

    fileprivate var ranges: [(low: Double, high: Double)] {
        func range(_ center: Double) -> (low: Double, high: Double) {
            let delta = center * tolerancePercent
            return (center - delta, center + delta)
        }
        var result = [range(seedBPM)]
        if includeHalfDouble {
            result.append(range(seedBPM / 2))
            result.append(range(seedBPM * 2))
        }
        return result
    }
}

struct CandidateRecallQuery: Sendable {
    let engine: AnalysisEngineIdentity
    let schemaVersion: Int
    var excludingTrackId: String?
    var bpm: BPMWindow?
    var key: CamelotKey?
    var genre: String?
    var limit: Int

    init(
        engine: AnalysisEngineIdentity,
        schemaVersion: Int,
        excludingTrackId: String? = nil,
        bpm: BPMWindow? = nil,
        key: CamelotKey? = nil,
        genre: String? = nil,
        limit: Int = 50
    ) {
        self.engine = engine
        self.schemaVersion = schemaVersion
        self.excludingTrackId = excludingTrackId
        self.bpm = bpm
        self.key = key
        self.genre = genre
        self.limit = max(0, limit)
    }
}

actor AnalysisCache {
    static let defaultMaxBytes: Int64 = 250_000_000

    static let shared = AnalysisCache(directory: AnalysisCache.defaultDirectory())

    private(set) var usedBytes: Int64 = 0
    private(set) var maxBytes: Int64

    private var inFlight: [String: Task<(Data, AnalysisFeatures), Error>] = [:]

    private nonisolated(unsafe) let db: OpaquePointer?

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        return encoder
    }()
    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        return decoder
    }()

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("AnalysisCache", isDirectory: true)
    }

    init(directory: URL, maxBytes: Int64 = AnalysisCache.defaultMaxBytes) {
        self.maxBytes = max(0, maxBytes)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("analysis.sqlite3")
        if let handle = Self.openDatabase(path: fileURL.path) {
            db = handle
        } else {
            Log.analysis.error("Could not open \(fileURL.path, privacy: .public) — falling back to an in-memory analysis cache; nothing will persist across relaunch")
            db = Self.openDatabase(path: ":memory:")
        }

        var excludedDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedDirectory.setResourceValues(resourceValues)

        Self.createSchema(db)
        Self.migrateSchemaIfNeeded(db)
        usedBytes = Self.queryUsedBytes(db)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func setMaxBytes(_ value: Int64) {
        maxBytes = max(0, value)
        runMaintenance()
    }

    func value<Payload: Codable & Sendable>(
        for key: AnalysisCacheKey,
        as type: Payload.Type,
        compute: @escaping @Sendable () async throws -> Payload,
        features: @escaping @Sendable (Payload) -> AnalysisFeatures
    ) async throws -> Payload {
        let cacheKey = key.stableKey

        if let data = readAndTouch(cacheKey) {
            if let decoded = try? Self.jsonDecoder.decode(Payload.self, from: data) {
                return decoded
            }
            Log.analysis.error("Row for \(key.trackId, privacy: .public)/\(key.engine.name, privacy: .public) failed to decode as the requested type — dropping and recomputing")
            deleteRows([cacheKey])
        }

        if let existing = inFlight[cacheKey] {
            let (data, _) = try await existing.value
            return try Self.jsonDecoder.decode(Payload.self, from: data)
        }

        let task = Task<(Data, AnalysisFeatures), Error> {
            let payload = try await compute()
            let data = try Self.jsonEncoder.encode(payload)
            return (data, features(payload))
        }
        inFlight[cacheKey] = task
        defer { inFlight[cacheKey] = nil }

        let (data, extractedFeatures) = try await task.value
        insertRow(
            key: key, cacheKey: cacheKey, data: data, features: extractedFeatures,
            producedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            producerId: AnalysisSyncIdentity.producerId(defaults: .standard)
        )
        runMaintenance()
        return try Self.jsonDecoder.decode(Payload.self, from: data)
    }

    func peek<Payload: Codable & Sendable>(_ type: Payload.Type, for key: AnalysisCacheKey) -> Payload? {
        guard let data = readAndTouch(key.stableKey) else { return nil }
        return try? Self.jsonDecoder.decode(Payload.self, from: data)
    }

    func invalidate(trackId: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM analysis WHERE track_id = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        _ = trackId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
        sqlite3_step(stmt)
        usedBytes = Self.queryUsedBytes(db)
    }

    func removeAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM analysis;", nil, nil, nil)
        usedBytes = 0
    }

    func storeUserCorrection(
        for track: Track,
        bpm: Double?,
        key: CamelotKey?,
        genre: String?,
        updatedAt: Date = Date()
    ) {
        let transcoding = track.transcodings.max { $0.playbackRank < $1.playbackRank }
        guard let keyIdentity = AnalysisCacheKey(
            track: track,
            transcoding: transcoding,
            engine: .userCorrection(),
            schemaVersion: 1
        ) else { return }

        let normalizedGenre = genre?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bpm != nil || key != nil || normalizedGenre?.isEmpty == false else {
            deleteRows([keyIdentity.stableKey])
            return
        }

        let payload = UserAnalysisCorrectionPayload(
            bpm: bpm,
            keyLabel: key?.label,
            genre: normalizedGenre,
            updatedAt: updatedAt
        )
        guard let data = try? Self.jsonEncoder.encode(payload) else { return }
        insertRow(
            key: keyIdentity,
            cacheKey: keyIdentity.stableKey,
            data: data,
            features: AnalysisFeatures(bpm: bpm, key: key, genre: normalizedGenre),
            producedAtMillis: Int64((updatedAt.timeIntervalSince1970 * 1000).rounded()),
            producerId: AnalysisSyncIdentity.producerId(defaults: .standard)
        )
        runMaintenance()
    }

    func runMaintenance() {
        guard usedBytes > maxBytes else { return }
        let candidates = queryEvictionCandidates()
        let victims = DownloadBudgetPolicy.victims(entries: candidates, maxBytes: maxBytes)
        guard !victims.isEmpty else { return }
        deleteRows(victims)
        Log.analysis.info("Evicted \(victims.count, privacy: .public) analysis row(s) to stay under the \(self.maxBytes, privacy: .public)-byte budget")
    }

    func recallCandidates(_ query: CandidateRecallQuery) -> [String] {
        guard let db else { return [] }
        let (sql, binds) = Self.buildRecallSQL(query, select: "SELECT DISTINCT track_id FROM analysis")

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.analysis.error("recallCandidates: failed to prepare query")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, binds)

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_text(stmt, 0) else { continue }
            results.append(String(cString: ptr))
        }
        return results
    }

    func explainRecallQueryPlan(_ query: CandidateRecallQuery) -> [String] {
        guard let db else { return [] }
        let (sql, binds) = Self.buildRecallSQL(query, select: "SELECT DISTINCT track_id FROM analysis")

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN \(sql)", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, binds)

        var lines: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let detailPtr = sqlite3_column_text(stmt, 3) {
                lines.append(String(cString: detailPtr))
            }
        }
        return lines
    }

    func featureCoverage(engine: AnalysisEngineIdentity, schemaVersion: Int) -> (total: Int, withBPM: Int, withKey: Int, withGenre: Int) {
        guard let db else { return (0, 0, 0, 0) }
        let sql = """
        SELECT COUNT(*), COUNT(bpm), COUNT(key_wheel_position), COUNT(genre)
        FROM analysis WHERE engine_name = ? AND engine_version = ? AND schema_version = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0, 0) }
        defer { sqlite3_finalize(stmt) }
        _ = engine.name.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
        sqlite3_bind_int64(stmt, 2, Int64(engine.version))
        sqlite3_bind_int64(stmt, 3, Int64(schemaVersion))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0, 0, 0) }
        return (
            Int(sqlite3_column_int64(stmt, 0)),
            Int(sqlite3_column_int64(stmt, 1)),
            Int(sqlite3_column_int64(stmt, 2)),
            Int(sqlite3_column_int64(stmt, 3))
        )
    }

    func recallRows(forTrackIds trackIds: [String], scope: AnalysisRecallScope = .everything) -> [String: [AnalysisRecallRow]] {
        guard db != nil, !trackIds.isEmpty else { return [:] }
        var out: [String: [AnalysisRecallRow]] = [:]
        for chunk in Self.chunk(Array(Set(trackIds)), size: 400) {
            for row in queryRecallRows(trackIds: chunk, scope: scope, limit: nil) {
                out[row.trackId, default: []].append(row)
            }
        }
        return out
    }

    func allRecallRows(limit: Int) -> [AnalysisRecallRow] {
        queryRecallRows(trackIds: [], scope: .everything, limit: max(0, limit))
    }

    private static func chunk(_ values: [String], size: Int) -> [[String]] {
        guard size > 0, values.count > size else { return values.isEmpty ? [] : [values] }
        return stride(from: 0, to: values.count, by: size).map {
            Array(values[$0..<min($0 + size, values.count)])
        }
    }

    private func queryRecallRows(trackIds: [String], scope: AnalysisRecallScope, limit: Int?) -> [AnalysisRecallRow] {
        guard let db else { return [] }

        var clauses: [String] = []
        var binds: [SQLBindValue] = []

        if !trackIds.isEmpty {
            clauses.append("track_id IN (\(trackIds.map { _ in "?" }.joined(separator: ",")))")
            binds.append(contentsOf: trackIds.map { SQLBindValue.text($0) })
        }

        switch scope {
        case .everything:
            break
        case .engines(let engines):
            guard !engines.isEmpty else { return [] }
            let parts = engines.map { _ in "(engine_name = ? AND engine_version = ?)" }
            clauses.append("(\(parts.joined(separator: " OR ")))")
            for engine in engines {
                binds.append(.text(engine.name))
                binds.append(.int(Int64(engine.version)))
            }
        case .generations(let generations):
            guard !generations.isEmpty else { return [] }
            let parts = generations.map { _ in "(engine_name = ? AND engine_version = ? AND schema_version = ?)" }
            clauses.append("(\(parts.joined(separator: " OR ")))")
            for generation in generations {
                binds.append(.text(generation.engine.name))
                binds.append(.int(Int64(generation.engine.version)))
                binds.append(.int(Int64(generation.schemaVersion)))
            }
        }

        var sql = """
        SELECT cache_key, track_id, engine_name, engine_version, schema_version,
               duration_millis, preset, bitrate, codec, byte_size,
               created_at, last_accessed_at, produced_at_millis, producer_id,
               bpm, key_wheel_position, key_mode, genre
        FROM analysis
        """
        if !clauses.isEmpty { sql += " WHERE \(clauses.joined(separator: " AND "))" }
        sql += " ORDER BY last_accessed_at DESC"
        if let limit {
            sql += " LIMIT ?"
            binds.append(.int(Int64(limit)))
        }
        sql += ";"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.analysis.error("recallRows: failed to prepare query")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, binds)

        var rows: [AnalysisRecallRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = Self.decodeRecallRow(stmt) { rows.append(row) }
        }
        return rows
    }

    private static func decodeRecallRow(_ stmt: OpaquePointer?) -> AnalysisRecallRow? {
        guard let cacheKeyPtr = sqlite3_column_text(stmt, 0),
              let trackIdPtr = sqlite3_column_text(stmt, 1),
              let engineNamePtr = sqlite3_column_text(stmt, 2),
              let presetPtr = sqlite3_column_text(stmt, 6),
              let codecPtr = sqlite3_column_text(stmt, 8)
        else { return nil }

        let createdAt = sqlite3_column_double(stmt, 10)
        let lastAccessedAt = sqlite3_column_double(stmt, 11)
        let producedAtMillis = sqlite3_column_type(stmt, 12) == SQLITE_NULL
            ? Int64(createdAt * 1000)
            : sqlite3_column_int64(stmt, 12)

        var key: CamelotKey?
        if sqlite3_column_type(stmt, 15) != SQLITE_NULL,
           sqlite3_column_type(stmt, 16) != SQLITE_NULL,
           let mode = CamelotKey.CamelotMode(rawValue: Int(sqlite3_column_int64(stmt, 16))) {
            key = CamelotKey(wheelPosition: Int(sqlite3_column_int64(stmt, 15)), mode: mode)
        }

        let genre = sqlite3_column_text(stmt, 17).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }

        return AnalysisRecallRow(
            cacheKey: String(cString: cacheKeyPtr),
            trackId: String(cString: trackIdPtr),
            generation: AnalysisGeneration(
                engine: AnalysisEngineIdentity(
                    name: String(cString: engineNamePtr),
                    version: Int(sqlite3_column_int64(stmt, 3))
                ),
                schemaVersion: Int(sqlite3_column_int64(stmt, 4))
            ),
            fingerprint: AnalyzedAudioFingerprint(
                durationMillis: Int(sqlite3_column_int64(stmt, 5)),
                preset: String(cString: presetPtr),
                bitrate: Int(sqlite3_column_int64(stmt, 7)),
                codec: String(cString: codecPtr)
            ),
            bpm: sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 14),
            key: key,
            genre: genre,
            byteSize: Int(sqlite3_column_int64(stmt, 9)),
            producedAt: Date(timeIntervalSince1970: Double(producedAtMillis) / 1000),
            lastAccessedAt: Date(timeIntervalSince1970: lastAccessedAt),
            producerId: sqlite3_column_text(stmt, 13).map { String(cString: $0) }
        )
    }

    private enum SQLBindValue {
        case text(String)
        case int(Int64)
        case double(Double)
    }

    private static func bind(_ stmt: OpaquePointer?, _ values: [SQLBindValue]) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let string):
                _ = string.withCString { sqlite3_bind_text(stmt, position, $0, -1, Self.sqliteTransient) }
            case .int(let intValue):
                sqlite3_bind_int64(stmt, position, intValue)
            case .double(let doubleValue):
                sqlite3_bind_double(stmt, position, doubleValue)
            }
        }
    }

    private static func buildRecallSQL(_ query: CandidateRecallQuery, select: String) -> (sql: String, binds: [SQLBindValue]) {
        var clauses = ["engine_name = ?", "engine_version = ?", "schema_version = ?"]
        var binds: [SQLBindValue] = [.text(query.engine.name), .int(Int64(query.engine.version)), .int(Int64(query.schemaVersion))]

        if let excludingTrackId = query.excludingTrackId {
            clauses.append("track_id != ?")
            binds.append(.text(excludingTrackId))
        }

        if let bpmWindow = query.bpm {
            let ranges = bpmWindow.ranges
            let rangeSQL = ranges.map { _ in "(bpm BETWEEN ? AND ?)" }.joined(separator: " OR ")
            clauses.append("(bpm IS NOT NULL AND (\(rangeSQL)))")
            for range in ranges {
                binds.append(.double(range.low))
                binds.append(.double(range.high))
            }
        }

        if let seedKey = query.key {
            let compatible = seedKey.harmonicallyCompatible
            let sameMode = compatible.filter { $0.mode == seedKey.mode }
            let otherMode = compatible.filter { $0.mode != seedKey.mode }

            var keyParts: [String] = []
            if !sameMode.isEmpty {
                let placeholders = sameMode.map { _ in "?" }.joined(separator: ",")
                keyParts.append("(key_mode = ? AND key_wheel_position IN (\(placeholders)))")
            }
            keyParts.append(contentsOf: Array(repeating: "(key_mode = ? AND key_wheel_position = ?)", count: otherMode.count))

            clauses.append("(key_wheel_position IS NOT NULL AND key_mode IS NOT NULL AND (\(keyParts.joined(separator: " OR "))))")
            if !sameMode.isEmpty {
                binds.append(.int(Int64(seedKey.mode.rawValue)))
                for candidate in sameMode { binds.append(.int(Int64(candidate.wheelPosition))) }
            }
            for candidate in otherMode {
                binds.append(.int(Int64(candidate.mode.rawValue)))
                binds.append(.int(Int64(candidate.wheelPosition)))
            }
        }

        if let genre = query.genre {
            clauses.append("(genre IS NOT NULL AND genre = ?)")
            binds.append(.text(genre))
        }

        let sql = "\(select) WHERE \(clauses.joined(separator: " AND ")) ORDER BY track_id ASC LIMIT ?;"
        binds.append(.int(Int64(query.limit)))
        return (sql, binds)
    }

    private static func openDatabase(path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 2_000)
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        return handle
    }

    private static func createSchema(_ db: OpaquePointer?) {
        guard let db else { return }
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS analysis (
            cache_key TEXT PRIMARY KEY NOT NULL,
            track_id TEXT NOT NULL,
            engine_name TEXT NOT NULL,
            engine_version INTEGER NOT NULL,
            schema_version INTEGER NOT NULL,
            duration_millis INTEGER NOT NULL,
            preset TEXT NOT NULL,
            bitrate INTEGER NOT NULL,
            codec TEXT NOT NULL,
            payload BLOB NOT NULL,
            byte_size INTEGER NOT NULL,
            created_at REAL NOT NULL,
            last_accessed_at REAL NOT NULL,
            bpm REAL,                    -- recall
            key_wheel_position INTEGER,  -- recall (Camelot 1...12)
            key_mode INTEGER,            -- recall (CamelotKey.CamelotMode)
            genre TEXT                   -- recall (taxonomy-owned, opaque here)
        );
        """, nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS analysis_track_id_idx ON analysis(track_id);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS analysis_last_accessed_idx ON analysis(last_accessed_at);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS analysis_bpm_idx ON analysis(engine_name, engine_version, schema_version, bpm);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS analysis_key_idx ON analysis(engine_name, engine_version, schema_version, key_mode, key_wheel_position);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS analysis_genre_idx ON analysis(engine_name, engine_version, schema_version, genre);", nil, nil, nil)
    }

    private static func migrateSchemaIfNeeded(_ db: OpaquePointer?) {
        guard let db else { return }
        let existing = Set(tableInfoColumnNames(db, table: "analysis"))
        let recallColumns: [(name: String, ddl: String)] = [
            ("bpm", "REAL"),
            ("key_wheel_position", "INTEGER"),
            ("key_mode", "INTEGER"),
            ("genre", "TEXT"),
            ("produced_at_millis", "INTEGER"),
            ("producer_id", "TEXT"),
        ]
        for column in recallColumns where !existing.contains(column.name) {
            sqlite3_exec(db, "ALTER TABLE analysis ADD COLUMN \(column.name) \(column.ddl);", nil, nil, nil)
        }
    }

    private static func tableInfoColumnNames(_ db: OpaquePointer?, table: String) -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(stmt, 1) { names.append(String(cString: namePtr)) }
        }
        return names
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func readAndTouch(_ cacheKey: String) -> Data? {
        guard let db else { return nil }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM analysis WHERE cache_key = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        _ = cacheKey.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            return nil
        }
        let length = Int(sqlite3_column_bytes(stmt, 0))
        let data: Data
        if let blob = sqlite3_column_blob(stmt, 0) {
            data = Data(bytes: blob, count: length)
        } else {
            data = Data()
        }
        sqlite3_finalize(stmt)

        var touchStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE analysis SET last_accessed_at = ? WHERE cache_key = ?;", -1, &touchStmt, nil) == SQLITE_OK {
            sqlite3_bind_double(touchStmt, 1, Date().timeIntervalSince1970)
            _ = cacheKey.withCString { sqlite3_bind_text(touchStmt, 2, $0, -1, Self.sqliteTransient) }
            sqlite3_step(touchStmt)
        }
        sqlite3_finalize(touchStmt)

        return data
    }

    private func queryEvictionCandidates() -> [DownloadBudgetPolicy.Entry] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT cache_key, byte_size, last_accessed_at FROM analysis;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var entries: [DownloadBudgetPolicy.Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: keyPtr)
            let bytes = sqlite3_column_int64(stmt, 1)
            let lastAccessed = sqlite3_column_double(stmt, 2)
            entries.append(.init(id: id, bytes: bytes, lastPlayedAt: Date(timeIntervalSince1970: lastAccessed), isPinned: false))
        }
        return entries
    }

    private static func queryUsedBytes(_ db: OpaquePointer?) -> Int64 {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(byte_size), 0) FROM analysis;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    private func insertRow(
        key: AnalysisCacheKey, cacheKey: String, data: Data, features: AnalysisFeatures,
        producedAtMillis: Int64, producerId: String
    ) {
        guard let db else { return }
        let sql = """
        INSERT INTO analysis (
            cache_key, track_id, engine_name, engine_version, schema_version,
            duration_millis, preset, bitrate, codec, payload, byte_size, created_at, last_accessed_at,
            bpm, key_wheel_position, key_mode, genre, produced_at_millis, producer_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(cache_key) DO UPDATE SET
            payload = excluded.payload,
            byte_size = excluded.byte_size,
            created_at = excluded.created_at,
            last_accessed_at = excluded.last_accessed_at,
            bpm = excluded.bpm,
            key_wheel_position = excluded.key_wheel_position,
            key_mode = excluded.key_mode,
            genre = excluded.genre,
            produced_at_millis = excluded.produced_at_millis,
            producer_id = excluded.producer_id;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let now = Date().timeIntervalSince1970
        _ = cacheKey.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
        _ = key.trackId.withCString { sqlite3_bind_text(stmt, 2, $0, -1, Self.sqliteTransient) }
        _ = key.engine.name.withCString { sqlite3_bind_text(stmt, 3, $0, -1, Self.sqliteTransient) }
        sqlite3_bind_int64(stmt, 4, Int64(key.engine.version))
        sqlite3_bind_int64(stmt, 5, Int64(key.schemaVersion))
        sqlite3_bind_int64(stmt, 6, Int64(key.fingerprint.durationMillis))
        _ = key.fingerprint.preset.withCString { sqlite3_bind_text(stmt, 7, $0, -1, Self.sqliteTransient) }
        sqlite3_bind_int64(stmt, 8, Int64(key.fingerprint.bitrate))
        _ = key.fingerprint.codec.withCString { sqlite3_bind_text(stmt, 9, $0, -1, Self.sqliteTransient) }
        data.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, 10, raw.baseAddress, Int32(raw.count), Self.sqliteTransient)
        }
        sqlite3_bind_int64(stmt, 11, Int64(data.count))
        sqlite3_bind_double(stmt, 12, now)
        sqlite3_bind_double(stmt, 13, now)

        if let bpm = features.bpm {
            sqlite3_bind_double(stmt, 14, bpm)
        } else {
            sqlite3_bind_null(stmt, 14)
        }
        if let camelotKey = features.key {
            sqlite3_bind_int64(stmt, 15, Int64(camelotKey.wheelPosition))
            sqlite3_bind_int64(stmt, 16, Int64(camelotKey.mode.rawValue))
        } else {
            sqlite3_bind_null(stmt, 15)
            sqlite3_bind_null(stmt, 16)
        }
        if let genre = features.genre {
            _ = genre.withCString { sqlite3_bind_text(stmt, 17, $0, -1, Self.sqliteTransient) }
        } else {
            sqlite3_bind_null(stmt, 17)
        }
        sqlite3_bind_int64(stmt, 18, producedAtMillis)
        _ = producerId.withCString { sqlite3_bind_text(stmt, 19, $0, -1, Self.sqliteTransient) }

        sqlite3_step(stmt)
        usedBytes = Self.queryUsedBytes(db)
    }

    private func deleteRows(_ cacheKeys: [String]) {
        guard let db, !cacheKeys.isEmpty else { return }
        let placeholders = cacheKeys.map { _ in "?" }.joined(separator: ",")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM analysis WHERE cache_key IN (\(placeholders));", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (index, cacheKey) in cacheKeys.enumerated() {
            _ = cacheKey.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, Self.sqliteTransient) }
        }
        sqlite3_step(stmt)
        usedBytes = Self.queryUsedBytes(db)
    }
}

extension AnalysisCache: AnalysisSyncStore {
    func exportCandidates(limit: Int) async -> [AnalysisSyncExportCandidate] {
        guard let db else { return [] }
        let sql = """
        SELECT cache_key, track_id, engine_name, engine_version, schema_version,
               duration_millis, preset, bitrate, codec, payload, byte_size,
               created_at, last_accessed_at, produced_at_millis, producer_id,
               bpm, key_wheel_position, key_mode, genre
        FROM analysis ORDER BY last_accessed_at DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(max(0, limit)))

        let localProducerId = AnalysisSyncIdentity.producerId(defaults: .standard)
        var out: [AnalysisSyncExportCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let record = Self.decodeSyncRow(stmt, fallbackProducerId: localProducerId) else { continue }
            let lastAccessed = Int64(sqlite3_column_double(stmt, 12) * 1000)
            out.append(AnalysisSyncExportCandidate(record: record, lastAccessedAtMillis: lastAccessed))
        }
        return out
    }

    func localSummaries(for cacheKeys: [String]) async -> [String: AnalysisSyncLocalSummary] {
        guard let db, !cacheKeys.isEmpty else { return [:] }
        let placeholders = cacheKeys.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT cache_key, payload, byte_size, created_at, produced_at_millis, producer_id FROM analysis WHERE cache_key IN (\(placeholders));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        for (index, key) in cacheKeys.enumerated() {
            _ = key.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, Self.sqliteTransient) }
        }

        let localProducerId = AnalysisSyncIdentity.producerId(defaults: .standard)
        var out: [String: AnalysisSyncLocalSummary] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(stmt, 0) else { continue }
            let cacheKey = String(cString: keyPtr)
            let payload = Self.blobData(stmt, column: 1)
            let byteSize = Int(sqlite3_column_int64(stmt, 2))
            let createdAt = sqlite3_column_double(stmt, 3)
            let producedAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? Int64(createdAt * 1000)
                : sqlite3_column_int64(stmt, 4)
            let producerId = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? localProducerId
            out[cacheKey] = AnalysisSyncLocalSummary(
                cacheKey: cacheKey,
                payloadDigest: AnalysisPayloadCodec.digest(ofUncompressed: payload),
                byteSize: byteSize,
                producedAtMillis: producedAt,
                producerId: producerId
            )
        }
        return out
    }

    func localFeatureCoverage(for cacheKeys: [String]) async -> [String: Int] {
        guard let db, !cacheKeys.isEmpty else { return [:] }
        let placeholders = cacheKeys.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT cache_key, bpm, key_wheel_position, key_mode, genre FROM analysis WHERE cache_key IN (\(placeholders));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        for (index, key) in cacheKeys.enumerated() {
            _ = key.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, Self.sqliteTransient) }
        }

        var out: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(stmt, 0) else { continue }
            let hasBPM = sqlite3_column_type(stmt, 1) != SQLITE_NULL
            let hasWheel = sqlite3_column_type(stmt, 2) != SQLITE_NULL
            let hasMode = sqlite3_column_type(stmt, 3) != SQLITE_NULL
            let hasGenre = sqlite3_column_type(stmt, 4) != SQLITE_NULL
            out[String(cString: keyPtr)] = [hasBPM, hasWheel && hasMode, hasGenre].reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        return out
    }

    @discardableResult
    func adopt(_ records: [AnalysisSyncRecord]) async -> Int {
        var adopted = 0
        for record in records {
            guard let raw = AnalysisPayloadCodec.decode(record.payload, encoding: record.payloadEncoding) else { continue }
            let fingerprint = AnalyzedAudioFingerprint(
                durationMillis: record.durationMillis, preset: record.preset,
                bitrate: record.bitrate, codec: record.codec
            )
            let key = AnalysisCacheKey(
                trackId: record.trackId,
                engine: AnalysisEngineIdentity(name: record.engineName, version: record.engineVersion),
                schemaVersion: record.schemaVersion,
                fingerprint: fingerprint
            )
            var features = AnalysisFeatures(bpm: record.bpm, genre: record.genre)
            if let wheel = record.keyWheelPosition, let modeRaw = record.keyMode, let mode = CamelotKey.CamelotMode(rawValue: modeRaw) {
                features.key = CamelotKey(wheelPosition: wheel, mode: mode)
            }
            insertRow(
                key: key, cacheKey: record.cacheKey, data: raw, features: features,
                producedAtMillis: record.producedAtMillis, producerId: record.producerId
            )
            adopted += 1
        }
        if adopted > 0 { runMaintenance() }
        return adopted
    }

    func freeBytes() async -> Int64 {
        max(0, maxBytes - usedBytes)
    }

    private static func blobData(_ stmt: OpaquePointer?, column: Int32) -> Data {
        guard let blob = sqlite3_column_blob(stmt, column) else { return Data() }
        let length = Int(sqlite3_column_bytes(stmt, column))
        return Data(bytes: blob, count: length)
    }

    private static func decodeSyncRow(_ stmt: OpaquePointer?, fallbackProducerId: String) -> AnalysisSyncRecord? {
        guard let cacheKeyPtr = sqlite3_column_text(stmt, 0),
              let trackIdPtr = sqlite3_column_text(stmt, 1),
              let engineNamePtr = sqlite3_column_text(stmt, 2),
              let presetPtr = sqlite3_column_text(stmt, 6),
              let codecPtr = sqlite3_column_text(stmt, 8)
        else { return nil }

        let raw = blobData(stmt, column: 9)
        guard !raw.isEmpty else { return nil }
        let (bytes, encoding) = AnalysisPayloadCodec.encode(raw)

        let createdAt = sqlite3_column_double(stmt, 11)
        let producedAt = sqlite3_column_type(stmt, 13) == SQLITE_NULL
            ? Int64(createdAt * 1000)
            : sqlite3_column_int64(stmt, 13)
        let producerId = sqlite3_column_text(stmt, 14).map { String(cString: $0) } ?? fallbackProducerId

        return AnalysisSyncRecord(
            cacheKey: String(cString: cacheKeyPtr),
            trackId: String(cString: trackIdPtr),
            engineName: String(cString: engineNamePtr),
            engineVersion: Int(sqlite3_column_int64(stmt, 3)),
            schemaVersion: Int(sqlite3_column_int64(stmt, 4)),
            durationMillis: Int(sqlite3_column_int64(stmt, 5)),
            preset: String(cString: presetPtr),
            bitrate: Int(sqlite3_column_int64(stmt, 7)),
            codec: String(cString: codecPtr),
            payload: bytes,
            payloadEncoding: encoding,
            uncompressedByteSize: raw.count,
            payloadDigest: AnalysisPayloadCodec.digest(ofUncompressed: raw),
            bpm: sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 15),
            keyWheelPosition: sqlite3_column_type(stmt, 16) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 16)),
            keyMode: sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 17)),
            genre: sqlite3_column_text(stmt, 18).map { String(cString: $0) },
            producedAtMillis: producedAt,
            producerId: producerId
        )
    }
}
