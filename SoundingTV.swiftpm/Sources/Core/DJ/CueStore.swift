import Foundation
import SQLite3

enum CueWriterIdentity {
    static let defaultsKey = "red.forbes.sounding.cues.writerId"

    static func writerId(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: defaultsKey)
        return generated
    }
}

actor CueStore {

    static let shared = CueStore(directory: CueStore.defaultDirectory())

    private(set) var isDurable: Bool

    private nonisolated(unsafe) let db: OpaquePointer?
    private let writerId: String

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("CuePoints", isDirectory: true)
    }

    init(directory: URL, writerId: String? = nil) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("cues.sqlite3")
        if let handle = Self.openDatabase(path: fileURL.path) {
            db = handle
            isDurable = true
        } else {
            Log.cues.error("Could not open the cue database — running in memory; cues written this session will not survive relaunch")
            db = Self.openDatabase(path: ":memory:")
            isDurable = false
        }

        self.writerId = writerId ?? CueWriterIdentity.writerId(defaults: .standard)

        Self.createSchema(db)
        Self.migrateSchemaIfNeeded(db)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    var localWriterId: String { writerId }

    func cues(forTrack trackId: String) -> [CuePoint] {
        rows(sql: "SELECT * FROM cue WHERE track_id = ? AND is_deleted = 0;", bindings: [.text(trackId)])
            .sorted(by: Self.cueOrder)
    }

    func cues(forTracks trackIds: [String]) -> [String: [CuePoint]] {
        guard !trackIds.isEmpty else { return [:] }
        let placeholders = trackIds.map { _ in "?" }.joined(separator: ",")
        let found = rows(
            sql: "SELECT * FROM cue WHERE is_deleted = 0 AND track_id IN (\(placeholders));",
            bindings: trackIds.map { .text($0) }
        )
        return Dictionary(grouping: found, by: \.trackId).mapValues { $0.sorted(by: Self.cueOrder) }
    }

    func dismissedSuggestionIds(forTrack trackId: String) -> Set<String> {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT dismissal_id FROM cue_dismissal WHERE track_id = ?;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        _ = trackId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
        var out: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) { out.insert(String(cString: ptr)) }
        }
        return out
    }

    func sheet(for input: CueSuggester.Input) -> CueSheet {
        CueResolution.resolve(
            trackId: input.trackId,
            userCues: cues(forTrack: input.trackId),
            suggestions: CueSuggester.suggest(input),
            dismissedIds: dismissedSuggestionIds(forTrack: input.trackId)
        )
    }

    @discardableResult
    func upsert(_ cue: CuePoint, now: Int64 = CueTime.nowMillis()) -> CuePoint {
        var stamped = cue
        stamped.updatedAtMillis = now
        stamped.writerId = writerId
        write(stamped)
        notifyLocalChange()
        return stamped
    }

    private nonisolated func notifyLocalChange() {
        Task { @MainActor in CueSyncTarget.localChangeCommitted() }
    }

    @discardableResult
    func setHotCue(
        trackId: String,
        index: Int,
        positionMillis: Int64,
        label: String = "",
        color: CueColor? = nil,
        now: Int64 = CueTime.nowMillis()
    ) -> CuePoint {
        upsert(
            CuePoint(
                trackId: trackId,
                kind: .hotCue,
                positionMillis: positionMillis,
                hotCueIndex: index,
                label: label,
                color: color,
                createdAtMillis: existing(id: CuePoint.slotId(trackId: trackId, kind: .hotCue, hotCueIndex: index))?.createdAtMillis ?? now
            ),
            now: now
        )
    }

    @discardableResult
    func setMixIn(trackId: String, positionMillis: Int64, label: String = "Mix in", now: Int64 = CueTime.nowMillis()) -> CuePoint {
        upsert(singleton(trackId: trackId, kind: .mixIn, positionMillis: positionMillis, label: label, now: now), now: now)
    }

    @discardableResult
    func setMixOut(trackId: String, positionMillis: Int64, label: String = "Mix out", now: Int64 = CueTime.nowMillis()) -> CuePoint {
        upsert(singleton(trackId: trackId, kind: .mixOut, positionMillis: positionMillis, label: label, now: now), now: now)
    }

    @discardableResult
    func addMemoryCue(trackId: String, positionMillis: Int64, label: String = "", now: Int64 = CueTime.nowMillis()) -> CuePoint {
        upsert(CuePoint(trackId: trackId, kind: .memory, positionMillis: positionMillis, label: label, createdAtMillis: now), now: now)
    }

    @discardableResult
    func addLoop(trackId: String, startMillis: Int64, endMillis: Int64, label: String = "", now: Int64 = CueTime.nowMillis()) -> CuePoint {
        upsert(
            CuePoint(trackId: trackId, kind: .loop, positionMillis: startMillis, endMillis: endMillis, label: label, createdAtMillis: now),
            now: now
        )
    }

    @discardableResult
    func promote(
        _ suggestion: CueSuggestion,
        asKind: CueKind? = nil,
        hotCueIndex: Int? = nil,
        label: String? = nil,
        now: Int64 = CueTime.nowMillis()
    ) -> CuePoint {
        let cue = suggestion.promoted(
            asKind: asKind,
            hotCueIndex: hotCueIndex,
            label: label,
            writerId: writerId,
            now: now
        )
        return upsert(cue, now: now)
    }

    func dismiss(_ suggestion: CueSuggestion, now: Int64 = CueTime.nowMillis()) {
        let dismissal = CueDismissal(suggestion: suggestion, writerId: writerId, now: now)
        guard let db else { return }
        let sql = """
        INSERT INTO cue_dismissal (
            dismissal_id, track_id, suggester_name, suggester_version, kind,
            position_millis, dismissed_at_millis, writer_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(dismissal_id) DO NOTHING;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, [
            .text(dismissal.id), .text(dismissal.trackId), .text(dismissal.suggesterName),
            .int(Int64(dismissal.suggesterVersion)), .text(dismissal.kind.rawValue),
            .int(dismissal.positionMillis), .int(dismissal.dismissedAtMillis), .text(dismissal.writerId),
        ])
        sqlite3_step(stmt)
        notifyLocalChange()
    }

    func undismiss(suggestionId: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM cue_dismissal WHERE dismissal_id = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        _ = suggestionId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
        sqlite3_step(stmt)
        notifyLocalChange()
    }

    func delete(cueId: String, now: Int64 = CueTime.nowMillis()) {
        guard var cue = existing(id: cueId) else { return }
        cue.isDeleted = true
        cue.updatedAtMillis = now
        cue.writerId = writerId
        write(cue)
        notifyLocalChange()
    }

    func deleteAll(forTrack trackId: String, now: Int64 = CueTime.nowMillis()) {
        for cue in cues(forTrack: trackId) { delete(cueId: cue.id, now: now) }
    }

    @discardableResult
    func pruneTombstones(olderThan cutoffMillis: Int64) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM cue WHERE is_deleted = 1 AND updated_at_millis < ?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffMillis)
        sqlite3_step(stmt)
        return Int(sqlite3_changes(db))
    }

    func syncRecords(changedSince cursorMillis: Int64 = 0, limit: Int = 5_000) -> [CueSyncRecord] {
        rows(
            sql: "SELECT * FROM cue WHERE updated_at_millis > ? ORDER BY updated_at_millis ASC LIMIT ?;",
            bindings: [.int(cursorMillis), .int(Int64(limit))]
        ).map(CueSyncRecord.init)
    }

    func dismissalRecords(changedSince cursorMillis: Int64 = 0, limit: Int = 5_000) -> [CueDismissal] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT dismissal_id, track_id, suggester_name, suggester_version, kind, position_millis, dismissed_at_millis, writer_id "
            + "FROM cue_dismissal WHERE dismissed_at_millis > ? ORDER BY dismissed_at_millis ASC LIMIT ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cursorMillis)
        sqlite3_bind_int64(stmt, 2, Int64(limit))

        var out: [CueDismissal] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0),
                  let trackPtr = sqlite3_column_text(stmt, 1),
                  let namePtr = sqlite3_column_text(stmt, 2),
                  let kindPtr = sqlite3_column_text(stmt, 4),
                  let writerPtr = sqlite3_column_text(stmt, 7),
                  let kind = CueKind(rawValue: String(cString: kindPtr))
            else { continue }
            out.append(CueDismissal(
                id: String(cString: idPtr),
                trackId: String(cString: trackPtr),
                suggesterName: String(cString: namePtr),
                suggesterVersion: Int(sqlite3_column_int64(stmt, 3)),
                kind: kind,
                positionMillis: sqlite3_column_int64(stmt, 5),
                dismissedAtMillis: sqlite3_column_int64(stmt, 6),
                writerId: String(cString: writerPtr)
            ))
        }
        return out
    }

    @discardableResult
    func adopt(_ records: [CueSyncRecord]) -> Int {
        var adopted = 0
        for record in records {
            let local = existing(id: record.cueId)
            guard CueSyncPolicy.remoteWins(local: local, remote: record) else { continue }
            write(record.cuePoint)
            adopted += 1
        }
        return adopted
    }

    @discardableResult
    func adoptDismissals(_ dismissals: [CueDismissal]) -> Int {
        guard let db else { return 0 }
        var adopted = 0
        let sql = """
        INSERT INTO cue_dismissal (
            dismissal_id, track_id, suggester_name, suggester_version, kind,
            position_millis, dismissed_at_millis, writer_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(dismissal_id) DO NOTHING;
        """
        for dismissal in dismissals {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            bind(stmt, [
                .text(dismissal.id), .text(dismissal.trackId), .text(dismissal.suggesterName),
                .int(Int64(dismissal.suggesterVersion)), .text(dismissal.kind.rawValue),
                .int(dismissal.positionMillis), .int(dismissal.dismissedAtMillis), .text(dismissal.writerId),
            ])
            if sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 { adopted += 1 }
            sqlite3_finalize(stmt)
        }
        return adopted
    }

    private func singleton(trackId: String, kind: CueKind, positionMillis: Int64, label: String, now: Int64) -> CuePoint {
        let id = CuePoint.slotId(trackId: trackId, kind: kind, hotCueIndex: nil)
        return CuePoint(
            trackId: trackId,
            kind: kind,
            positionMillis: positionMillis,
            label: label,
            createdAtMillis: existing(id: id)?.createdAtMillis ?? now
        )
    }

    private func existing(id: String?) -> CuePoint? {
        guard let id else { return nil }
        return rows(sql: "SELECT * FROM cue WHERE cue_id = ?;", bindings: [.text(id)]).first
    }

    private static func cueOrder(_ lhs: CuePoint, _ rhs: CuePoint) -> Bool {
        if lhs.positionMillis != rhs.positionMillis { return lhs.positionMillis < rhs.positionMillis }
        if lhs.kind != rhs.kind { return lhs.kind.sortRank < rhs.kind.sortRank }
        if let l = lhs.hotCueIndex, let r = rhs.hotCueIndex, l != r { return l < r }
        return lhs.id < rhs.id
    }

    private enum Binding {
        case text(String)
        case int(Int64)
        case nullInt(Int64?)
    }

    private func bind(_ stmt: OpaquePointer?, _ bindings: [Binding]) {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value):
                _ = value.withCString { sqlite3_bind_text(stmt, index, $0, -1, Self.sqliteTransient) }
            case .int(let value):
                sqlite3_bind_int64(stmt, index, value)
            case .nullInt(let value):
                if let value { sqlite3_bind_int64(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
            }
        }
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func openDatabase(path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 2_000)
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=FULL;", nil, nil, nil)
        return handle
    }

    private static func createSchema(_ db: OpaquePointer?) {
        guard let db else { return }
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS cue (
            cue_id                TEXT PRIMARY KEY NOT NULL,
            track_id              TEXT NOT NULL,
            kind                  TEXT NOT NULL,
            position_millis       INTEGER NOT NULL,
            end_millis            INTEGER,
            hot_cue_index         INTEGER,
            label                 TEXT NOT NULL,
            color_rgb             INTEGER NOT NULL,
            created_at_millis     INTEGER NOT NULL,
            updated_at_millis     INTEGER NOT NULL,
            is_deleted            INTEGER NOT NULL DEFAULT 0,
            promoted_from_name    TEXT,
            promoted_from_version INTEGER,
            writer_id             TEXT NOT NULL
        );
        """, nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS cue_track_idx ON cue(track_id, is_deleted);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS cue_updated_idx ON cue(updated_at_millis);", nil, nil, nil)

        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS cue_dismissal (
            dismissal_id        TEXT PRIMARY KEY NOT NULL,
            track_id            TEXT NOT NULL,
            suggester_name      TEXT NOT NULL,
            suggester_version   INTEGER NOT NULL,
            kind                TEXT NOT NULL,
            position_millis     INTEGER NOT NULL,
            dismissed_at_millis INTEGER NOT NULL,
            writer_id           TEXT NOT NULL
        );
        """, nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS cue_dismissal_track_idx ON cue_dismissal(track_id);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS cue_dismissal_time_idx ON cue_dismissal(dismissed_at_millis);", nil, nil, nil)
    }

    private static func migrateSchemaIfNeeded(_ db: OpaquePointer?) {
        guard let db else { return }
        let existing = Set(tableInfoColumnNames(db, table: "cue"))
        let additions: [(name: String, ddl: String)] = []
        for column in additions where !existing.contains(column.name) {
            sqlite3_exec(db, "ALTER TABLE cue ADD COLUMN \(column.name) \(column.ddl);", nil, nil, nil)
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

    private func rows(sql: String, bindings: [Binding]) -> [CuePoint] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, bindings)

        var out: [CuePoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cue = Self.decodeRow(stmt) { out.append(cue) }
        }
        return out
    }

    private static func decodeRow(_ stmt: OpaquePointer?) -> CuePoint? {
        guard let idPtr = sqlite3_column_text(stmt, 0),
              let trackPtr = sqlite3_column_text(stmt, 1),
              let kindPtr = sqlite3_column_text(stmt, 2),
              let kind = CueKind(rawValue: String(cString: kindPtr)),
              let labelPtr = sqlite3_column_text(stmt, 6),
              let writerPtr = sqlite3_column_text(stmt, 13)
        else { return nil }

        let endMillis: Int64? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4)
        let hotCueIndex: Int? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 5))
        let promotedName: String? = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
        let promotedVersion: Int? = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 12))

        return CuePoint(
            id: String(cString: idPtr),
            trackId: String(cString: trackPtr),
            kind: kind,
            positionMillis: sqlite3_column_int64(stmt, 3),
            endMillis: endMillis,
            hotCueIndex: hotCueIndex,
            label: String(cString: labelPtr),
            color: CueColor(rgb: UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, 7))),
            createdAtMillis: sqlite3_column_int64(stmt, 8),
            updatedAtMillis: sqlite3_column_int64(stmt, 9),
            isDeleted: sqlite3_column_int64(stmt, 10) != 0,
            promotedFrom: promotedName.flatMap { name in promotedVersion.map { CueSuggesterIdentity(name: name, version: $0) } },
            writerId: String(cString: writerPtr)
        )
    }

    private func write(_ cue: CuePoint) {
        guard let db else { return }
        let sql = """
        INSERT INTO cue (
            cue_id, track_id, kind, position_millis, end_millis, hot_cue_index,
            label, color_rgb, created_at_millis, updated_at_millis, is_deleted,
            promoted_from_name, promoted_from_version, writer_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(cue_id) DO UPDATE SET
            position_millis = excluded.position_millis,
            end_millis = excluded.end_millis,
            hot_cue_index = excluded.hot_cue_index,
            label = excluded.label,
            color_rgb = excluded.color_rgb,
            updated_at_millis = excluded.updated_at_millis,
            is_deleted = excluded.is_deleted,
            promoted_from_name = excluded.promoted_from_name,
            promoted_from_version = excluded.promoted_from_version,
            writer_id = excluded.writer_id;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, [
            .text(cue.id), .text(cue.trackId), .text(cue.kind.rawValue),
            .int(cue.positionMillis), .nullInt(cue.endMillis),
            .nullInt(cue.hotCueIndex.map(Int64.init)),
            .text(cue.label), .int(Int64(cue.color.rgb)),
            .int(cue.createdAtMillis), .int(cue.updatedAtMillis),
            .int(cue.isDeleted ? 1 : 0),
        ])
        if let promoted = cue.promotedFrom {
            _ = promoted.name.withCString { sqlite3_bind_text(stmt, 12, $0, -1, Self.sqliteTransient) }
            sqlite3_bind_int64(stmt, 13, Int64(promoted.version))
        } else {
            sqlite3_bind_null(stmt, 12)
            sqlite3_bind_null(stmt, 13)
        }
        _ = cue.writerId.withCString { sqlite3_bind_text(stmt, 14, $0, -1, Self.sqliteTransient) }

        sqlite3_step(stmt)
    }
}

extension CueStore: CueSyncStore {
    func pendingChanges(since cursorMillis: Int64, limit: Int) async -> (cues: [CueSyncRecord], dismissals: [CueDismissal]) {
        (syncRecords(changedSince: cursorMillis, limit: limit), dismissalRecords(changedSince: cursorMillis, limit: limit))
    }
}
