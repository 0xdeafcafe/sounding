import Foundation
import SQLite3

actor LibraryCache {
    static let shared = LibraryCache(directory: LibraryCache.defaultDirectory())

    struct Row: Sendable {
        let payload: Data
        let likedAtMillis: Int64?
    }

    struct WriteRow: Sendable {
        let id: String
        let payload: Data
        let likedAtMillis: Int64?

        init(id: String, payload: Data, likedAtMillis: Int64? = nil) {
            self.id = id
            self.payload = payload
            self.likedAtMillis = likedAtMillis
        }
    }

    struct LikeIndexRow: Sendable {
        let id: String
        let payload: Data
        let likedAtMillis: Int64
        let title: String
        let artist: String
    }

    struct SectionState: Sendable, Equatable {
        let updatedAt: Date?
        let completedAt: Date?
        let nextHref: URL?
        let itemCount: Int

        func isFresh(for ttl: TimeInterval, now: Date = Date()) -> Bool {
            guard let reference = completedAt ?? updatedAt else { return false }
            return now.timeIntervalSince(reference) <= ttl
        }
    }

    struct SectionSnapshot: Sendable {
        let rows: [Row]
        let state: SectionState
    }

    private nonisolated(unsafe) let db: OpaquePointer?

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("LibraryCache", isDirectory: true)
    }

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("library.sqlite3")
        if let handle = Self.openDatabase(path: fileURL.path) {
            db = handle
        } else {
            Log.library.error("Could not open \(fileURL.path, privacy: .public) — falling back to an in-memory library cache; nothing will persist across relaunch")
            db = Self.openDatabase(path: ":memory:")
        }

        var excludedDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedDirectory.setResourceValues(resourceValues)

        Self.createSchema(db)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func loadSection(_ section: String) -> [Row] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT payload, liked_at_millis FROM library_item WHERE section = ? ORDER BY position ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        _ = section.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 0))
            let payload = Data(bytes: blob, count: length)
            let likedAtMillis: Int64? = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 1)
            rows.append(Row(payload: payload, likedAtMillis: likedAtMillis))
        }
        return rows
    }

    /// Loads payload and freshness metadata in one actor turn so views can
    /// paint stale data immediately and decide whether to revalidate without
    /// maintaining a launch-only in-memory timestamp.
    func loadSectionSnapshot(_ section: String) -> SectionSnapshot {
        SectionSnapshot(rows: loadSection(section), state: sectionState(section))
    }

    func replaceSection(_ section: String, rows: [WriteRow]) {
        guard let db else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        var deleteStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM library_item WHERE section = ?;", -1, &deleteStmt, nil) == SQLITE_OK {
            _ = section.withCString { sqlite3_bind_text(deleteStmt, 1, $0, -1, Self.sqliteTransient) }
            sqlite3_step(deleteStmt)
        }
        sqlite3_finalize(deleteStmt)

        let insertSQL = """
        INSERT INTO library_item (section, item_id, position, payload, liked_at_millis, cached_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        for (index, row) in rows.enumerated() {
            var insertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else { continue }
            _ = section.withCString { sqlite3_bind_text(insertStmt, 1, $0, -1, Self.sqliteTransient) }
            _ = row.id.withCString { sqlite3_bind_text(insertStmt, 2, $0, -1, Self.sqliteTransient) }
            sqlite3_bind_int64(insertStmt, 3, Int64(index))
            row.payload.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(insertStmt, 4, raw.baseAddress, Int32(raw.count), Self.sqliteTransient)
            }
            if let likedAtMillis = row.likedAtMillis {
                sqlite3_bind_int64(insertStmt, 5, likedAtMillis)
            } else {
                sqlite3_bind_null(insertStmt, 5)
            }
            sqlite3_bind_double(insertStmt, 6, Date().timeIntervalSince1970)
            sqlite3_step(insertStmt)
            sqlite3_finalize(insertStmt)
        }

        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        setSectionState(section, completedAt: Date(), nextHref: nil, itemCount: rows.count)
        Log.library.info("Cached \(rows.count, privacy: .public) row(s) for section \(section, privacy: .public)")
    }

    /// Adds metadata discovered by a background walk without discarding the
    /// last complete snapshot. This is deliberately metadata-only: callers
    /// supply JSON payloads and this cache never resolves stream URLs.
    func mergeSection(_ section: String, rows: [WriteRow]) {
        guard let db, !rows.isEmpty else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT;", nil, nil, nil) }

        var position: Int64 = 0
        var positionStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(position) + 1, 0) FROM library_item WHERE section = ?;", -1, &positionStmt, nil) == SQLITE_OK {
            _ = section.withCString { sqlite3_bind_text(positionStmt, 1, $0, -1, Self.sqliteTransient) }
            if sqlite3_step(positionStmt) == SQLITE_ROW { position = sqlite3_column_int64(positionStmt, 0) }
        }
        sqlite3_finalize(positionStmt)

        let sql = """
        INSERT INTO library_item (section, item_id, position, payload, liked_at_millis, cached_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(section, item_id) DO UPDATE SET
            payload = excluded.payload,
            liked_at_millis = excluded.liked_at_millis,
            cached_at = excluded.cached_at;
        """
        for row in rows {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            _ = section.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
            _ = row.id.withCString { sqlite3_bind_text(stmt, 2, $0, -1, Self.sqliteTransient) }
            sqlite3_bind_int64(stmt, 3, position)
            row.payload.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, 4, raw.baseAddress, Int32(raw.count), Self.sqliteTransient)
            }
            if let likedAtMillis = row.likedAtMillis { sqlite3_bind_int64(stmt, 5, likedAtMillis) }
            else { sqlite3_bind_null(stmt, 5) }
            sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            position += 1
        }
        setSectionState(section, completedAt: nil, nextHref: nil, itemCount: sectionCount(section))
    }

    /// Records progressive-walk state independently of payload writes. A
    /// process can therefore resume at the server cursor after relaunch while
    /// readers continue using the last locally available rows.
    func markSectionProgress(
        _ section: String,
        nextHref: URL?,
        completed: Bool,
        now: Date = Date()
    ) {
        setSectionState(
            section,
            completedAt: completed ? now : nil,
            nextHref: nextHref,
            itemCount: sectionCount(section),
            now: now
        )
    }

    func sectionState(_ section: String) -> SectionState {
        guard let db else { return SectionState(updatedAt: nil, completedAt: nil, nextHref: nil, itemCount: 0) }
        var stmt: OpaquePointer?
        let sql = "SELECT updated_at, completed_at, next_href, item_count FROM library_section_state WHERE section = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return SectionState(updatedAt: nil, completedAt: nil, nextHref: nil, itemCount: 0)
        }
        defer { sqlite3_finalize(stmt) }
        _ = section.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return SectionState(updatedAt: sectionCachedAt(section), completedAt: nil, nextHref: nil, itemCount: sectionCount(section))
        }
        let updatedAt = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        let completedAt = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let nextHref = sqlite3_column_text(stmt, 2).flatMap { URL(string: String(cString: $0)) }
        return SectionState(updatedAt: updatedAt, completedAt: completedAt, nextHref: nextHref, itemCount: Int(sqlite3_column_int64(stmt, 3)))
    }

    func clearAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM library_item;", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM likes_index;", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM sync_state;", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM library_section_state;", nil, nil, nil)
    }

    func upsertLikes(_ rows: [LikeIndexRow], generation: Int64) {
        guard let db, !rows.isEmpty else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        let sql = """
        INSERT INTO likes_index (item_id, payload, liked_at_millis, title_fold, artist_fold, generation, cached_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(item_id) DO UPDATE SET
            payload = excluded.payload,
            liked_at_millis = excluded.liked_at_millis,
            title_fold = excluded.title_fold,
            artist_fold = excluded.artist_fold,
            generation = excluded.generation,
            cached_at = excluded.cached_at;
        """
        for row in rows {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            _ = row.id.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
            row.payload.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), Self.sqliteTransient)
            }
            sqlite3_bind_int64(stmt, 3, row.likedAtMillis)
            _ = Self.fold(row.title).withCString { sqlite3_bind_text(stmt, 4, $0, -1, Self.sqliteTransient) }
            _ = Self.fold(row.artist).withCString { sqlite3_bind_text(stmt, 5, $0, -1, Self.sqliteTransient) }
            sqlite3_bind_int64(stmt, 6, generation)
            sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    func removeLikes(ids: [String]) {
        guard let db, !ids.isEmpty else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        for id in ids {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM likes_index WHERE item_id = ?;", -1, &stmt, nil) == SQLITE_OK else { continue }
            _ = id.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    func pruneLikes(olderThanGeneration generation: Int64) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM likes_index WHERE generation < ?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_int64(stmt, 1, generation)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return Int(sqlite3_changes(db))
    }

    func likesCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM likes_index;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func loadAllLikes(limit: Int? = nil) -> [Row] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        var sql = "SELECT payload, liked_at_millis FROM likes_index ORDER BY liked_at_millis DESC, item_id ASC"
        if limit != nil { sql += " LIMIT ?" }
        sql += ";"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let limit { sqlite3_bind_int64(stmt, 1, Int64(limit)) }

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 0))
            rows.append(Row(payload: Data(bytes: blob, count: length), likedAtMillis: sqlite3_column_int64(stmt, 1)))
        }
        return rows
    }

    func loadLikesForPeer(offset: Int, limit: Int) -> [LikesPeerRecord] {
        guard let db, offset >= 0, limit > 0 else { return [] }
        var stmt: OpaquePointer?
        let sql = """
        SELECT item_id, payload, liked_at_millis, title_fold, artist_fold
        FROM likes_index
        ORDER BY liked_at_millis DESC, item_id ASC
        LIMIT ? OFFSET ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        sqlite3_bind_int64(stmt, 2, Int64(offset))

        var rows: [LikesPeerRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let blob = sqlite3_column_blob(stmt, 1) else { continue }
            let payload = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1)))
            rows.append(LikesPeerRecord(
                id: String(cString: idText),
                payload: payload,
                likedAtMillis: sqlite3_column_int64(stmt, 2),
                title: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                artist: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            ))
        }
        return rows
    }

    func likeIDs(newerThanMillis millis: Int64) -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT item_id FROM likes_index WHERE liked_at_millis > ?;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, millis)

        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                ids.append(String(cString: text))
            }
        }
        return ids
    }

    func searchLikes(query: String, limit: Int) -> [Row] {
        guard let db else { return [] }
        let folded = Self.fold(query)
        let terms = folded.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }

        let clause = terms
            .map { _ in "(title_fold LIKE ? ESCAPE '\\' OR artist_fold LIKE ? ESCAPE '\\')" }
            .joined(separator: " AND ")
        let sql = """
        SELECT payload, liked_at_millis FROM likes_index
        WHERE \(clause)
        ORDER BY
            CASE WHEN title_fold LIKE ? ESCAPE '\\' THEN 0
                 WHEN artist_fold LIKE ? ESCAPE '\\' THEN 1
                 ELSE 2 END,
            liked_at_millis DESC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        for term in terms {
            let pattern = "%\(Self.likePattern(term))%"
            for _ in 0..<2 {
                _ = pattern.withCString { sqlite3_bind_text(stmt, index, $0, -1, Self.sqliteTransient) }
                index += 1
            }
        }
        let prefix = "\(Self.likePattern(folded))%"
        for _ in 0..<2 {
            _ = prefix.withCString { sqlite3_bind_text(stmt, index, $0, -1, Self.sqliteTransient) }
            index += 1
        }
        sqlite3_bind_int64(stmt, index, Int64(limit))

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 0))
            rows.append(Row(payload: Data(bytes: blob, count: length), likedAtMillis: sqlite3_column_int64(stmt, 1)))
        }
        return rows
    }

    func syncValue(forKey key: String) -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM sync_state WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    func setSyncValue(_ value: String?, forKey key: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        if let value {
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK else { return }
            _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
            _ = value.withCString { sqlite3_bind_text(stmt, 2, $0, -1, Self.sqliteTransient) }
        } else {
            guard sqlite3_prepare_v2(db, "DELETE FROM sync_state WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
            _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    nonisolated static func fold(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func likePattern(_ term: String) -> String {
        var escaped = ""
        for character in term {
            if character == "%" || character == "_" || character == "\\" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    func sectionCachedAt(_ section: String) -> Date? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT MAX(cached_at) FROM library_item WHERE section = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        _ = section.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }

        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
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
        CREATE TABLE IF NOT EXISTS library_item (
            section          TEXT NOT NULL,
            item_id          TEXT NOT NULL,
            position         INTEGER NOT NULL,
            payload          BLOB NOT NULL,
            liked_at_millis  INTEGER,
            cached_at        REAL NOT NULL,
            PRIMARY KEY (section, item_id)
        );
        """, nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS library_item_section_idx ON library_item(section, position);", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS library_section_state (
            section       TEXT PRIMARY KEY,
            updated_at    REAL NOT NULL,
            completed_at  REAL,
            next_href     TEXT,
            item_count    INTEGER NOT NULL DEFAULT 0
        );
        """, nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS likes_index (
            item_id          TEXT PRIMARY KEY,
            payload          BLOB NOT NULL,
            liked_at_millis  INTEGER NOT NULL,
            title_fold       TEXT NOT NULL,
            artist_fold      TEXT NOT NULL,
            generation       INTEGER NOT NULL,
            cached_at        REAL NOT NULL
        );
        """, nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS likes_index_liked_at_idx ON likes_index(liked_at_millis DESC);", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS sync_state (
            key    TEXT PRIMARY KEY,
            value  TEXT NOT NULL
        );
        """, nil, nil, nil)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func sectionCount(_ section: String) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM library_item WHERE section = ?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        _ = section.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func setSectionState(
        _ section: String,
        completedAt: Date?,
        nextHref: URL?,
        itemCount: Int,
        now: Date = Date()
    ) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO library_section_state (section, updated_at, completed_at, next_href, item_count)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(section) DO UPDATE SET
            updated_at = excluded.updated_at,
            completed_at = COALESCE(excluded.completed_at, library_section_state.completed_at),
            next_href = excluded.next_href,
            item_count = excluded.item_count;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        _ = section.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.sqliteTransient) }
        sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
        if let completedAt { sqlite3_bind_double(stmt, 3, completedAt.timeIntervalSince1970) }
        else { sqlite3_bind_null(stmt, 3) }
        if let nextHref {
            _ = nextHref.absoluteString.withCString { sqlite3_bind_text(stmt, 4, $0, -1, Self.sqliteTransient) }
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_int64(stmt, 5, Int64(itemCount))
        sqlite3_step(stmt)
    }
}
