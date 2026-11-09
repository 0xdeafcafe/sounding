import Foundation
import SQLite3

actor LibrarySQLiteStore: LibraryStore {
    static let shared = LibrarySQLiteStore(directory: LibraryCache.defaultDirectory())

    private nonisolated(unsafe) let db: OpaquePointer?
    private var bucketCounts: [String: Int] = [:]
    private let clock: @Sendable () -> Date

    init(directory: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("library.sqlite3").path
        var handle: OpaquePointer?
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            if let handle { sqlite3_close(handle) }
            handle = nil
            sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        }
        db = handle
        if let handle {
            sqlite3_busy_timeout(handle, 2_000)
            sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
            Self.createSchema(handle)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private static func createSchema(_ db: OpaquePointer) {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS likes_index (
                item_id TEXT PRIMARY KEY, payload BLOB NOT NULL, liked_at_millis INTEGER NOT NULL,
                title_fold TEXT NOT NULL, artist_fold TEXT NOT NULL, generation INTEGER NOT NULL, cached_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS likes_index_liked_at_idx ON likes_index(liked_at_millis DESC);",
            """
            CREATE TABLE IF NOT EXISTS ldb_member (
                collection TEXT NOT NULL, item_key TEXT NOT NULL, kind TEXT NOT NULL, item_id TEXT NOT NULL, sort_key INTEGER NOT NULL,
                generation INTEGER NOT NULL, timestamp_millis INTEGER, PRIMARY KEY (collection, item_key)
            );
            """,
            "CREATE INDEX IF NOT EXISTS ldb_member_order ON ldb_member(collection, sort_key DESC);",
            """
            CREATE TABLE IF NOT EXISTS ldb_entity (
                kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, title TEXT NOT NULL, artist TEXT NOT NULL,
                title_fold TEXT NOT NULL, artist_fold TEXT NOT NULL, change_key TEXT, PRIMARY KEY (kind, id)
            );
            """,
            "CREATE TABLE IF NOT EXISTS ldb_cursor (collection TEXT PRIMARY KEY, json TEXT NOT NULL);",
            """
            CREATE TABLE IF NOT EXISTS ldb_bucket (
                collection TEXT NOT NULL, bucket INTEGER NOT NULL, updated_millis INTEGER NOT NULL,
                cloud_millis INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (collection, bucket)
            );
            """,
            "CREATE TABLE IF NOT EXISTS ldb_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
            """
            CREATE TABLE IF NOT EXISTS ldb_identity_link (
                kind TEXT NOT NULL, local_key TEXT NOT NULL, soundcloud_id TEXT NOT NULL, origin TEXT NOT NULL,
                confidence REAL NOT NULL, payload BLOB, updated_millis INTEGER NOT NULL, PRIMARY KEY (kind, local_key)
            );
            """,
        ]
        for sql in statements { sqlite3_exec(db, sql, nil, nil, nil) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private final class Statement {
        let handle: OpaquePointer?
        init(_ db: OpaquePointer?, _ sql: String) {
            var stmt: OpaquePointer?
            if let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                handle = stmt
            } else {
                handle = nil
            }
        }
        deinit { sqlite3_finalize(handle) }

        var isValid: Bool { handle != nil }

        @discardableResult
        func bind(_ index: Int32, _ value: String?) -> Statement {
            if let value {
                _ = value.withCString { sqlite3_bind_text(handle, index, $0, -1, LibrarySQLiteStore.transient) }
            } else {
                sqlite3_bind_null(handle, index)
            }
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: Int64?) -> Statement {
            if let value { sqlite3_bind_int64(handle, index, value) } else { sqlite3_bind_null(handle, index) }
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: Data) -> Statement {
            value.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(handle, index, raw.baseAddress, Int32(raw.count), LibrarySQLiteStore.transient)
            }
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: Double) -> Statement {
            sqlite3_bind_double(handle, index, value)
            return self
        }

        func step() -> Bool { sqlite3_step(handle) == SQLITE_ROW }

        func run() { _ = sqlite3_step(handle) }

        func reset() {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }

        func text(_ column: Int32) -> String? {
            guard let raw = sqlite3_column_text(handle, column) else { return nil }
            return String(cString: raw)
        }

        func int(_ column: Int32) -> Int64? {
            sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : sqlite3_column_int64(handle, column)
        }

        func double(_ column: Int32) -> Double {
            sqlite3_column_double(handle, column)
        }

        func blob(_ column: Int32) -> Data {
            guard let raw = sqlite3_column_blob(handle, column) else { return Data() }
            return Data(bytes: raw, count: Int(sqlite3_column_bytes(handle, column)))
        }
    }

    private func statement(_ sql: String) -> Statement { Statement(db, sql) }

    private func transaction(_ body: () -> Void) {
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        body()
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    private var nowMillis: Int64 { Int64(clock().timeIntervalSince1970 * 1000) }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trackID(fromKey key: String) -> String? {
        guard let parsed = LibraryRecord.parse(key: key), parsed.kind == .track else { return nil }
        return parsed.id
    }

    // MARK: - Account

    func boundAccount() -> String? { meta("account") }

    func bind(account: String) -> Bool {
        let current = meta("account")
        if current == account { return false }
        if current != nil { wipe() }
        setMeta(account, forKey: "account")
        return current != nil
    }

    func wipe() {
        transaction {
            for table in ["likes_index", "ldb_member", "ldb_entity", "ldb_cursor", "ldb_bucket", "ldb_meta"] {
                sqlite3_exec(db, "DELETE FROM \(table);", nil, nil, nil)
            }
        }
        bucketCounts = [:]
    }

    func cursor(_ collection: LibraryCollection) -> LibraryCursor {
        let stmt = statement("SELECT json FROM ldb_cursor WHERE collection = ?;").bind(1, collection.key)
        guard stmt.step(), let json = stmt.text(0),
              let cursor = try? JSONDecoder().decode(LibraryCursor.self, from: Data(json.utf8)) else {
            return LibraryCursor()
        }
        return cursor
    }

    func setCursor(_ cursor: LibraryCursor, for collection: LibraryCollection) {
        let previous = bucketCount(collection)
        guard let data = try? JSONEncoder().encode(cursor) else { return }
        statement("INSERT OR REPLACE INTO ldb_cursor (collection, json) VALUES (?, ?);")
            .bind(1, collection.key)
            .bind(2, String(decoding: data, as: UTF8.self))
            .run()
        bucketCounts[collection.key] = max(1, cursor.bucketCount)
        if cursor.bucketCount != previous {
            let millis = nowMillis
            for bucket in 0..<max(1, cursor.bucketCount) { touch(collection, bucket: bucket, millis: millis) }
        }
    }

    private func bucketCount(_ collection: LibraryCollection) -> Int {
        if let cached = bucketCounts[collection.key] { return cached }
        let value = max(1, cursor(collection).bucketCount)
        bucketCounts[collection.key] = value
        return value
    }

    func knownCollections() -> [LibraryCollection] {
        var keys = Set<String>()
        let cursors = statement("SELECT collection FROM ldb_cursor;")
        while cursors.step() { if let key = cursors.text(0) { keys.insert(key) } }
        let members = statement("SELECT DISTINCT collection FROM ldb_member;")
        while members.step() { if let key = members.text(0) { keys.insert(key) } }
        if count(.likes) > 0 { keys.insert(LibraryCollection.likes.key) }
        return keys.sorted().compactMap(LibraryCollection.init(key:))
    }

    func count(_ collection: LibraryCollection) -> Int {
        let stmt = collection == .likes
            ? statement("SELECT COUNT(*) FROM likes_index;")
            : statement("SELECT COUNT(*) FROM ldb_member WHERE collection = ?;").bind(1, collection.key)
        return stmt.step() ? Int(stmt.int(0) ?? 0) : 0
    }

    func keys(_ collection: LibraryCollection, limit: Int?) -> [String] {
        let bound = Int64(limit ?? -1)
        var result: [String] = []
        if collection == .likes {
            let stmt = statement("SELECT item_id FROM likes_index ORDER BY liked_at_millis DESC, item_id ASC LIMIT ?;").bind(1, bound)
            while stmt.step() { if let id = stmt.text(0) { result.append(LibraryRecord.key(.track, id)) } }
        } else {
            let stmt = statement("SELECT item_key FROM ldb_member WHERE collection = ? ORDER BY sort_key DESC, item_key ASC LIMIT ?;")
                .bind(1, collection.key).bind(2, bound)
            while stmt.step() { if let key = stmt.text(0) { result.append(key) } }
        }
        return result
    }

    func keysAbove(_ collection: LibraryCollection, key: String) -> [String] {
        var result: [String] = []
        if collection == .likes {
            guard let id = Self.trackID(fromKey: key) else { return [] }
            let stmt = statement("""
            SELECT l.item_id FROM likes_index l, likes_index a WHERE a.item_id = ?
            AND (l.liked_at_millis > a.liked_at_millis OR (l.liked_at_millis = a.liked_at_millis AND l.item_id < a.item_id));
            """).bind(1, id)
            while stmt.step() { if let found = stmt.text(0) { result.append(LibraryRecord.key(.track, found)) } }
        } else {
            let stmt = statement("""
            SELECT m.item_key FROM ldb_member m, ldb_member a WHERE a.collection = ? AND a.item_key = ? AND m.collection = a.collection
            AND (m.sort_key > a.sort_key OR (m.sort_key = a.sort_key AND m.item_key < a.item_key));
            """).bind(1, collection.key).bind(2, key)
            while stmt.step() { if let found = stmt.text(0) { result.append(found) } }
        }
        return result
    }

    func contains(_ collection: LibraryCollection, keys: [String]) -> Set<String> {
        var found = Set<String>()
        for start in stride(from: 0, to: keys.count, by: 200) {
            let slice = Array(keys[start..<min(start + 200, keys.count)])
            let marks = Array(repeating: "?", count: slice.count).joined(separator: ",")
            if collection == .likes {
                let ids = slice.compactMap(Self.trackID(fromKey:))
                guard !ids.isEmpty else { continue }
                let stmt = statement("SELECT item_id FROM likes_index WHERE item_id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")));")
                for (index, id) in ids.enumerated() { stmt.bind(Int32(index + 1), id) }
                while stmt.step() { if let id = stmt.text(0) { found.insert(LibraryRecord.key(.track, id)) } }
            } else {
                let stmt = statement("SELECT item_key FROM ldb_member WHERE collection = ? AND item_key IN (\(marks));")
                stmt.bind(1, collection.key)
                for (index, key) in slice.enumerated() { stmt.bind(Int32(index + 2), key) }
                while stmt.step() { if let key = stmt.text(0) { found.insert(key) } }
            }
        }
        return found
    }

    func row(_ collection: LibraryCollection, key: String) -> LibraryRow? {
        rows(collection, keys: [key]).first
    }

    func records(_ collection: LibraryCollection) -> [LibraryRecord] {
        page(collection, offset: 0, limit: nil).map(\.record)
    }

    func page(_ collection: LibraryCollection, offset: Int, limit: Int?) -> [LibraryRow] {
        var result: [LibraryRow] = []
        if collection == .likes {
            let stmt = statement("""
            SELECT item_id, payload, liked_at_millis, title_fold, artist_fold FROM likes_index
            ORDER BY liked_at_millis DESC, item_id ASC LIMIT ? OFFSET ?;
            """).bind(1, Int64(limit ?? -1)).bind(2, Int64(max(0, offset)))
            while stmt.step() {
                guard let id = stmt.text(0) else { continue }
                let liked = stmt.int(2) ?? 0
                let record = LibraryRecord(kind: .track, id: id, payload: stmt.blob(1), title: stmt.text(3) ?? "", artist: stmt.text(4) ?? "", timestampMillis: liked, changeKey: nil)
                result.append(LibraryRow(record: record, sortKey: liked))
            }
        } else {
            let stmt = statement("""
            SELECT m.item_key, m.sort_key, m.timestamp_millis, e.kind, e.id, e.payload, e.title, e.artist, e.change_key
            FROM ldb_member m JOIN ldb_entity e ON e.kind = m.kind AND e.id = m.item_id
            WHERE m.collection = ? ORDER BY m.sort_key DESC, m.item_key ASC LIMIT ? OFFSET ?;
            """).bind(1, collection.key).bind(2, Int64(limit ?? -1)).bind(3, Int64(max(0, offset)))
            while stmt.step() {
                guard let kindRaw = stmt.text(3), let kind = LibraryEntityKind(rawValue: kindRaw), let id = stmt.text(4) else { continue }
                let record = LibraryRecord(kind: kind, id: id, payload: stmt.blob(5), title: stmt.text(6) ?? "", artist: stmt.text(7) ?? "", timestampMillis: stmt.int(2), changeKey: stmt.text(8))
                result.append(LibraryRow(record: record, sortKey: stmt.int(1) ?? 0))
            }
        }
        return result
    }

    private func rows(_ collection: LibraryCollection, keys: [String]) -> [LibraryRow] {
        var result: [LibraryRow] = []
        for start in stride(from: 0, to: keys.count, by: 200) {
            let slice = Array(keys[start..<min(start + 200, keys.count)])
            if collection == .likes {
                let ids = slice.compactMap(Self.trackID(fromKey:))
                guard !ids.isEmpty else { continue }
                let stmt = statement("SELECT item_id, payload, liked_at_millis, title_fold, artist_fold FROM likes_index WHERE item_id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")));")
                for (index, id) in ids.enumerated() { stmt.bind(Int32(index + 1), id) }
                while stmt.step() {
                    guard let id = stmt.text(0) else { continue }
                    let liked = stmt.int(2) ?? 0
                    result.append(LibraryRow(record: LibraryRecord(kind: .track, id: id, payload: stmt.blob(1), title: stmt.text(3) ?? "", artist: stmt.text(4) ?? "", timestampMillis: liked, changeKey: nil), sortKey: liked))
                }
            } else {
                let marks = Array(repeating: "?", count: slice.count).joined(separator: ",")
                let stmt = statement("""
                SELECT m.item_key, m.sort_key, m.timestamp_millis, e.kind, e.id, e.payload, e.title, e.artist, e.change_key
                FROM ldb_member m JOIN ldb_entity e ON e.kind = m.kind AND e.id = m.item_id
                WHERE m.collection = ? AND m.item_key IN (\(marks));
                """)
                stmt.bind(1, collection.key)
                for (index, key) in slice.enumerated() { stmt.bind(Int32(index + 2), key) }
                while stmt.step() {
                    guard let kindRaw = stmt.text(3), let kind = LibraryEntityKind(rawValue: kindRaw), let id = stmt.text(4) else { continue }
                    result.append(LibraryRow(record: LibraryRecord(kind: kind, id: id, payload: stmt.blob(5), title: stmt.text(6) ?? "", artist: stmt.text(7) ?? "", timestampMillis: stmt.int(2), changeKey: stmt.text(8)), sortKey: stmt.int(1) ?? 0))
                }
            }
        }
        return result
    }

    func cachedTracks(ids: [String]) -> [String: LibraryRecord] {
        var result: [String: LibraryRecord] = [:]
        let unique = Array(Set(ids))
        for start in stride(from: 0, to: unique.count, by: 200) {
            let slice = Array(unique[start..<min(start + 200, unique.count)])
            let marks = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let entities = statement("SELECT id, payload, title, artist, change_key FROM ldb_entity WHERE kind = 'track' AND id IN (\(marks));")
            for (index, id) in slice.enumerated() { entities.bind(Int32(index + 1), id) }
            while entities.step() {
                guard let id = entities.text(0) else { continue }
                result[id] = LibraryRecord(kind: .track, id: id, payload: entities.blob(1), title: entities.text(2) ?? "", artist: entities.text(3) ?? "", timestampMillis: nil, changeKey: entities.text(4))
            }
            let likes = statement("SELECT item_id, payload, title_fold, artist_fold FROM likes_index WHERE item_id IN (\(marks));")
            for (index, id) in slice.enumerated() { likes.bind(Int32(index + 1), id) }
            while likes.step() {
                guard let id = likes.text(0), result[id] == nil else { continue }
                result[id] = LibraryRecord(kind: .track, id: id, payload: likes.blob(1), title: likes.text(2) ?? "", artist: likes.text(3) ?? "", timestampMillis: nil, changeKey: nil)
            }
        }
        return result
    }

    func upsertEntities(_ records: [LibraryRecord]) {
        guard !records.isEmpty else { return }
        transaction { for record in records { writeEntity(record) } }
    }

    private func writeEntity(_ record: LibraryRecord) {
        statement("""
        INSERT INTO ldb_entity (kind, id, payload, title, artist, title_fold, artist_fold, change_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(kind, id) DO UPDATE SET payload = excluded.payload, title = excluded.title, artist = excluded.artist,
            title_fold = excluded.title_fold, artist_fold = excluded.artist_fold, change_key = excluded.change_key;
        """)
            .bind(1, record.kind.rawValue).bind(2, record.id).bind(3, record.payload)
            .bind(4, record.title).bind(5, record.artist)
            .bind(6, Self.fold(record.title)).bind(7, Self.fold(record.artist))
            .bind(8, record.changeKey)
            .run()
    }

    private func entityChangeKey(_ record: LibraryRecord) -> String?? {
        let stmt = statement("SELECT change_key FROM ldb_entity WHERE kind = ? AND id = ?;").bind(1, record.kind.rawValue).bind(2, record.id)
        guard stmt.step() else { return nil }
        return .some(stmt.text(0))
    }

    private func writeLike(_ record: LibraryRecord, generation: Int64) -> Bool {
        let liked = record.timestampMillis ?? nowMillis
        let existing = statement("SELECT liked_at_millis FROM likes_index WHERE item_id = ?;").bind(1, record.id)
        let previous: Int64? = existing.step() ? existing.int(0) : nil
        statement("""
        INSERT INTO likes_index (item_id, payload, liked_at_millis, title_fold, artist_fold, generation, cached_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(item_id) DO UPDATE SET payload = excluded.payload, liked_at_millis = excluded.liked_at_millis,
            title_fold = excluded.title_fold, artist_fold = excluded.artist_fold, generation = excluded.generation, cached_at = excluded.cached_at;
        """)
            .bind(1, record.id).bind(2, record.payload).bind(3, liked)
            .bind(4, Self.fold(record.title)).bind(5, Self.fold(record.artist))
            .bind(6, generation).bind(7, clock().timeIntervalSince1970)
            .run()
        return previous != liked
    }

    private func writeMember(_ collection: LibraryCollection, record: LibraryRecord, sortKey: Int64, generation: Int64) {
        statement("""
        INSERT INTO ldb_member (collection, item_key, kind, item_id, sort_key, generation, timestamp_millis) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(collection, item_key) DO UPDATE SET sort_key = excluded.sort_key, generation = excluded.generation,
            timestamp_millis = COALESCE(excluded.timestamp_millis, ldb_member.timestamp_millis);
        """)
            .bind(1, collection.key).bind(2, record.key).bind(3, record.kind.rawValue).bind(4, record.id)
            .bind(5, sortKey).bind(6, generation).bind(7, record.timestampMillis)
            .run()
    }

    private func extremeSortKey(_ collection: LibraryCollection, maximum: Bool) -> Int64? {
        let stmt = statement("SELECT \(maximum ? "MAX" : "MIN")(sort_key) FROM ldb_member WHERE collection = ?;").bind(1, collection.key)
        return stmt.step() ? stmt.int(0) : nil
    }

    private func memberSortKey(_ collection: LibraryCollection, key: String) -> Int64? {
        let stmt = statement("SELECT sort_key FROM ldb_member WHERE collection = ? AND item_key = ?;").bind(1, collection.key).bind(2, key)
        return stmt.step() ? stmt.int(0) : nil
    }

    func append(_ collection: LibraryCollection, records: [LibraryRecord], generation: Int64) {
        guard !records.isEmpty else { return }
        transaction {
            if collection == .likes {
                for record in records where writeLike(record, generation: generation) { markDirty(collection, key: record.key) }
                return
            }
            var low = extremeSortKey(collection, maximum: false).map { $0 - 1 } ?? 0
            var previous: Int64?
            for record in records {
                let oldChange = entityChangeKey(record)
                writeEntity(record)
                if let existing = memberSortKey(collection, key: record.key) {
                    statement("UPDATE ldb_member SET generation = ?, timestamp_millis = COALESCE(?, timestamp_millis) WHERE collection = ? AND item_key = ?;")
                        .bind(1, generation).bind(2, record.timestampMillis).bind(3, collection.key).bind(4, record.key).run()
                    previous = existing
                    if let oldChange, oldChange != record.changeKey { markDirty(collection, key: record.key) }
                } else {
                    let placed: Int64
                    if let previous, previous > low + 1 {
                        placed = previous
                    } else {
                        placed = low
                        low -= 1
                    }
                    writeMember(collection, record: record, sortKey: placed, generation: generation)
                    previous = placed
                    markDirty(collection, key: record.key)
                }
            }
        }
    }

    func setHead(_ collection: LibraryCollection, records: [LibraryRecord], generation: Int64) {
        guard !records.isEmpty else { return }
        transaction {
            if collection == .likes {
                for record in records where writeLike(record, generation: generation) { markDirty(collection, key: record.key) }
                return
            }
            let high = extremeSortKey(collection, maximum: true) ?? 0
            for (index, record) in records.enumerated() {
                writeEntity(record)
                writeMember(collection, record: record, sortKey: high + Int64(records.count - index), generation: generation)
                markDirty(collection, key: record.key)
            }
        }
    }

    func insert(_ collection: LibraryCollection, rows: [LibraryRow], generation: Int64) {
        guard !rows.isEmpty else { return }
        transaction {
            for row in rows {
                let changed: Bool
                if collection == .likes {
                    var record = row.record
                    record.timestampMillis = row.sortKey
                    changed = writeLike(record, generation: generation)
                } else {
                    let previous = memberSortKey(collection, key: row.record.key)
                    let oldChange = entityChangeKey(row.record)
                    writeEntity(row.record)
                    writeMember(collection, record: row.record, sortKey: row.sortKey, generation: generation)
                    changed = previous != row.sortKey || (oldChange != nil && oldChange! != row.record.changeKey)
                }
                if changed { markDirty(collection, key: row.record.key) }
            }
        }
    }

    func replace(_ collection: LibraryCollection, records: [LibraryRecord], generation: Int64) {
        let old = keys(collection, limit: nil)
        transaction {
            if collection == .likes {
                sqlite3_exec(db, "DELETE FROM likes_index;", nil, nil, nil)
                for record in records { _ = writeLike(record, generation: generation) }
            } else {
                statement("DELETE FROM ldb_member WHERE collection = ?;").bind(1, collection.key).run()
                for (index, record) in records.enumerated() {
                    writeEntity(record)
                    writeMember(collection, record: record, sortKey: Int64(records.count - index), generation: generation)
                }
            }
            for key in Set(old + records.map(\.key)) { markDirty(collection, key: key) }
        }
    }

    func remove(_ collection: LibraryCollection, keys: [String]) {
        guard !keys.isEmpty else { return }
        transaction {
            for key in keys {
                if collection == .likes {
                    guard let id = Self.trackID(fromKey: key) else { continue }
                    statement("DELETE FROM likes_index WHERE item_id = ?;").bind(1, id).run()
                } else {
                    statement("DELETE FROM ldb_member WHERE collection = ? AND item_key = ?;").bind(1, collection.key).bind(2, key).run()
                }
                markDirty(collection, key: key)
            }
        }
    }

    func prune(_ collection: LibraryCollection, olderThan generation: Int64) -> Int {
        var stale: [String] = []
        if collection == .likes {
            let stmt = statement("SELECT item_id FROM likes_index WHERE generation < ?;").bind(1, generation)
            while stmt.step() { if let id = stmt.text(0) { stale.append(LibraryRecord.key(.track, id)) } }
        } else {
            let stmt = statement("SELECT item_key FROM ldb_member WHERE collection = ? AND generation < ?;").bind(1, collection.key).bind(2, generation)
            while stmt.step() { if let key = stmt.text(0) { stale.append(key) } }
        }
        remove(collection, keys: stale)
        return stale.count
    }

    func maxGeneration(_ collection: LibraryCollection) -> Int64 {
        let stmt = collection == .likes
            ? statement("SELECT MAX(generation) FROM likes_index;")
            : statement("SELECT MAX(generation) FROM ldb_member WHERE collection = ?;").bind(1, collection.key)
        return stmt.step() ? (stmt.int(0) ?? 0) : 0
    }

    func drop(_ collection: LibraryCollection) {
        transaction {
            if collection == .likes {
                sqlite3_exec(db, "DELETE FROM likes_index;", nil, nil, nil)
            } else {
                statement("DELETE FROM ldb_member WHERE collection = ?;").bind(1, collection.key).run()
            }
            statement("DELETE FROM ldb_cursor WHERE collection = ?;").bind(1, collection.key).run()
            statement("DELETE FROM ldb_bucket WHERE collection = ?;").bind(1, collection.key).run()
            bucketCounts[collection.key] = 1
            touch(collection, bucket: 0, millis: nowMillis)
        }
    }

    func meta(_ key: String) -> String? {
        let stmt = statement("SELECT value FROM ldb_meta WHERE key = ?;").bind(1, key)
        return stmt.step() ? stmt.text(0) : nil
    }

    func setMeta(_ value: String?, forKey key: String) {
        if let value {
            statement("INSERT OR REPLACE INTO ldb_meta (key, value) VALUES (?, ?);").bind(1, key).bind(2, value).run()
        } else {
            statement("DELETE FROM ldb_meta WHERE key = ?;").bind(1, key).run()
        }
    }

    // MARK: - Identity links

    func identityLinks() -> [LibraryIdentityLink] {
        let stmt = statement("SELECT kind, local_key, soundcloud_id, origin, confidence, payload, updated_millis FROM ldb_identity_link;")
        var links: [LibraryIdentityLink] = []
        while stmt.step() {
            guard let kind = stmt.text(0).flatMap(LibraryIdentityLink.Kind.init(rawValue:)),
                  let localKey = stmt.text(1),
                  let origin = stmt.text(3).flatMap(LibraryIdentityLink.Origin.init(rawValue:)) else { continue }
            let payload = stmt.blob(5)
            links.append(LibraryIdentityLink(
                kind: kind,
                localKey: localKey,
                soundCloudID: stmt.text(2) ?? "",
                origin: origin,
                confidence: stmt.double(4),
                payload: payload.isEmpty ? nil : payload,
                updatedAtMillis: stmt.int(6) ?? 0
            ))
        }
        return links
    }

    func saveIdentityLinks(_ links: [LibraryIdentityLink], removing removed: [(kind: LibraryIdentityLink.Kind, localKey: String)]) {
        guard !links.isEmpty || !removed.isEmpty else { return }
        transaction {
            let upsert = statement("""
                INSERT OR REPLACE INTO ldb_identity_link (kind, local_key, soundcloud_id, origin, confidence, payload, updated_millis)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """)
            for link in links {
                upsert.bind(1, link.kind.rawValue).bind(2, link.localKey).bind(3, link.soundCloudID).bind(4, link.origin.rawValue)
                    .bind(5, link.confidence)
                if let payload = link.payload { upsert.bind(6, payload) } else { upsert.bind(6, nil as String?) }
                upsert.bind(7, link.updatedAtMillis == 0 ? nowMillis : link.updatedAtMillis)
                upsert.run()
                upsert.reset()
            }
            let delete = statement("DELETE FROM ldb_identity_link WHERE kind = ? AND local_key = ?;")
            for entry in removed {
                delete.bind(1, entry.kind.rawValue).bind(2, entry.localKey)
                delete.run()
                delete.reset()
            }
        }
    }

    private func markDirty(_ collection: LibraryCollection, key: String) {
        touch(collection, bucket: LibraryBuckets.bucket(for: key, count: bucketCount(collection)), millis: nowMillis)
    }

    private func touch(_ collection: LibraryCollection, bucket: Int, millis: Int64) {
        statement("""
        INSERT INTO ldb_bucket (collection, bucket, updated_millis, cloud_millis) VALUES (?, ?, ?, 0)
        ON CONFLICT(collection, bucket) DO UPDATE SET updated_millis = MAX(excluded.updated_millis, ldb_bucket.updated_millis + 1);
        """).bind(1, collection.key).bind(2, Int64(bucket)).bind(3, millis).run()
    }

    func dirtyBuckets(cloud: Bool, since millis: Int64) -> [(collection: LibraryCollection, bucket: Int, updatedAtMillis: Int64)] {
        let stmt = cloud
            ? statement("SELECT collection, bucket, updated_millis FROM ldb_bucket WHERE updated_millis > cloud_millis;")
            : statement("SELECT collection, bucket, updated_millis FROM ldb_bucket WHERE updated_millis > ?;").bind(1, millis)
        var result: [(collection: LibraryCollection, bucket: Int, updatedAtMillis: Int64)] = []
        while stmt.step() {
            guard let key = stmt.text(0), let collection = LibraryCollection(key: key) else { continue }
            let bucket = Int(stmt.int(1) ?? 0)
            guard bucket < bucketCount(collection) else { continue }
            result.append((collection, bucket, stmt.int(2) ?? 0))
        }
        return result
    }

    private func bucketKeys(_ collection: LibraryCollection, bucket: Int, bucketCount: Int) -> [String] {
        keys(collection, limit: nil).filter { LibraryBuckets.bucket(for: $0, count: bucketCount) == bucket }
    }

    func exportRows(_ collection: LibraryCollection, bucket: Int, bucketCount: Int) -> [LibraryRow] {
        rows(collection, keys: bucketKeys(collection, bucket: bucket, bucketCount: bucketCount))
            .sorted { $0.sortKey == $1.sortKey ? $0.record.key < $1.record.key : $0.sortKey > $1.sortKey }
    }

    func bucketUpdatedAt(_ collection: LibraryCollection, bucket: Int) -> Int64? {
        let stmt = statement("SELECT updated_millis FROM ldb_bucket WHERE collection = ? AND bucket = ?;").bind(1, collection.key).bind(2, Int64(bucket))
        return stmt.step() ? stmt.int(0) : nil
    }

    func applyBucket(_ collection: LibraryCollection, bucket: Int, bucketCount: Int, rows: [LibraryRow], updatedAtMillis: Int64, generation: Int64) {
        let existing = bucketKeys(collection, bucket: bucket, bucketCount: bucketCount)
        transaction {
            for key in existing {
                if collection == .likes {
                    if let id = Self.trackID(fromKey: key) { statement("DELETE FROM likes_index WHERE item_id = ?;").bind(1, id).run() }
                } else {
                    statement("DELETE FROM ldb_member WHERE collection = ? AND item_key = ?;").bind(1, collection.key).bind(2, key).run()
                }
            }
            for row in rows {
                if collection == .likes {
                    var record = row.record
                    record.timestampMillis = row.sortKey
                    _ = writeLike(record, generation: generation)
                } else {
                    writeEntity(row.record)
                    writeMember(collection, record: row.record, sortKey: row.sortKey, generation: generation)
                }
            }
            statement("""
            INSERT INTO ldb_bucket (collection, bucket, updated_millis, cloud_millis) VALUES (?, ?, ?, ?)
            ON CONFLICT(collection, bucket) DO UPDATE SET updated_millis = excluded.updated_millis, cloud_millis = excluded.cloud_millis;
            """).bind(1, collection.key).bind(2, Int64(bucket)).bind(3, updatedAtMillis).bind(4, updatedAtMillis).run()
        }
    }

    func markCloudPending(_ collection: LibraryCollection, bucket: Int) {
        statement("UPDATE ldb_bucket SET cloud_millis = 0 WHERE collection = ? AND bucket = ?;")
            .bind(1, collection.key).bind(2, Int64(bucket)).run()
    }

    func markCloudExported(_ collection: LibraryCollection, bucket: Int, through millis: Int64) {
        statement("UPDATE ldb_bucket SET cloud_millis = MAX(cloud_millis, ?) WHERE collection = ? AND bucket = ?;")
            .bind(1, millis).bind(2, collection.key).bind(3, Int64(bucket)).run()
    }
}

struct LibraryIdentityLink: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case artist
        case album
        case track
    }

    enum Origin: String, Hashable, Sendable {
        case automatic
        case manual
        case unlinked
    }

    let kind: Kind
    let localKey: String
    let soundCloudID: String
    let origin: Origin
    let confidence: Double
    var payload: Data?
    var updatedAtMillis: Int64 = 0
}
