import Foundation
import SQLite3

enum PrepRecordKind: String, Codable, Sendable {
    case prep
    case link
    case tally
}

struct PrepSyncRecord: Codable, Sendable, Equatable {
    let recordName: String
    let kind: PrepRecordKind
    let trackId: String
    let payload: Data
    let updatedAtMillis: Int64
    let writerId: String

    static func prep(_ prep: TrackPrep) -> PrepSyncRecord? {
        guard let payload = try? PrepCoding.encoder.encode(prep) else { return nil }
        return PrepSyncRecord(
            recordName: "prep:\(prep.trackId)", kind: .prep, trackId: prep.trackId,
            payload: payload, updatedAtMillis: prep.updatedAtMillis, writerId: prep.latestWriterId
        )
    }

    static func link(_ link: TrackLink) -> PrepSyncRecord? {
        guard let payload = try? PrepCoding.encoder.encode(link) else { return nil }
        return PrepSyncRecord(
            recordName: "link:\(link.trackId)", kind: .link, trackId: link.trackId,
            payload: payload, updatedAtMillis: link.updatedAtMillis, writerId: link.writerId
        )
    }

    static func tally(_ tally: ListeningTally) -> PrepSyncRecord? {
        guard let payload = try? PrepCoding.encoder.encode(tally) else { return nil }
        return PrepSyncRecord(
            recordName: tally.recordName, kind: .tally, trackId: tally.trackId,
            payload: payload, updatedAtMillis: tally.updatedAtMillis, writerId: tally.deviceId
        )
    }
}

enum PrepCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    static let decoder = JSONDecoder()
}

struct RekordboxPlaylistRecord: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let path: [String]
    let trackIds: [String]
}

extension CueStore {

    static func createPrepSchema(_ db: OpaquePointer?) {
        guard let db else { return }
        for ddl in [
            "CREATE TABLE IF NOT EXISTS track_prep (track_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at_millis INTEGER NOT NULL);",
            "CREATE TABLE IF NOT EXISTS track_link (track_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at_millis INTEGER NOT NULL);",
            "CREATE TABLE IF NOT EXISTS track_link_file (track_id TEXT PRIMARY KEY NOT NULL, bookmark BLOB NOT NULL, path TEXT NOT NULL);",
            "CREATE TABLE IF NOT EXISTS listening_tally (record_name TEXT PRIMARY KEY NOT NULL, track_id TEXT NOT NULL, payload BLOB NOT NULL, updated_at_millis INTEGER NOT NULL);",
            "CREATE INDEX IF NOT EXISTS listening_tally_track_idx ON listening_tally(track_id);",
            "CREATE TABLE IF NOT EXISTS prep_sync_log (record_name TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, track_id TEXT NOT NULL, changed_at_millis INTEGER NOT NULL);",
            "CREATE INDEX IF NOT EXISTS prep_sync_log_time_idx ON prep_sync_log(changed_at_millis);",
            "CREATE TABLE IF NOT EXISTS rekordbox_playlist (playlist_id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL);",
        ] {
            sqlite3_exec(db, ddl, nil, nil, nil)
        }
    }


    func prep(forTrack trackId: String) -> TrackPrep? {
        blob(sql: "SELECT payload FROM track_prep WHERE track_id = ?;", key: trackId)
            .flatMap { try? PrepCoding.decoder.decode(TrackPrep.self, from: $0) }
    }

    func preps(forTracks trackIds: [String]) -> [String: TrackPrep] {
        var out: [String: TrackPrep] = [:]
        for id in trackIds { if let prep = prep(forTrack: id) { out[id] = prep } }
        return out
    }

    func savePrep(_ prep: TrackPrep) {
        guard let payload = try? PrepCoding.encoder.encode(prep) else { return }
        execute(
            "INSERT INTO track_prep (track_id, payload, updated_at_millis) VALUES (?, ?, ?) "
                + "ON CONFLICT(track_id) DO UPDATE SET payload = excluded.payload, updated_at_millis = excluded.updated_at_millis;",
            [.text(prep.trackId), .blob(payload), .int(prep.updatedAtMillis)]
        )
        logChange(recordName: "prep:\(prep.trackId)", kind: .prep, trackId: prep.trackId)
        noteChange(trackId: prep.trackId)
        notifyLocalChange()
    }

    @discardableResult
    func setUserGrid(trackId: String, _ grid: PrepGrid?, now: Int64 = CueTime.nowMillis()) -> TrackPrep {
        var prep = self.prep(forTrack: trackId) ?? TrackPrep(trackId: trackId)
        prep.grid = grid.map { PrepField($0, source: .user, updatedAtMillis: now, writerId: writerId) }
        savePrep(prep)
        return prep
    }

    @discardableResult
    func setUserComment(trackId: String, _ comment: String, now: Int64 = CueTime.nowMillis()) -> TrackPrep {
        var prep = self.prep(forTrack: trackId) ?? TrackPrep(trackId: trackId)
        prep.comment = PrepField(comment, source: .user, updatedAtMillis: now, writerId: writerId)
        savePrep(prep)
        return prep
    }

    @discardableResult
    func setUserKey(trackId: String, _ key: PrepKey?, now: Int64 = CueTime.nowMillis()) -> TrackPrep {
        var prep = self.prep(forTrack: trackId) ?? TrackPrep(trackId: trackId)
        prep.key = key.map { PrepField($0, source: .user, updatedAtMillis: now, writerId: writerId) }
        savePrep(prep)
        return prep
    }

    func restorePrep(_ prep: TrackPrep) {
        savePrep(prep)
    }

    @discardableResult
    func applyCandidatePrep(_ candidate: TrackPrep) -> (prep: TrackPrep, blocked: [PrepItem]) {
        let local = prep(forTrack: candidate.trackId)
        let blocked = TrackPrepPolicy.blockedItems(local: local, incoming: candidate)
        let merged = TrackPrepPolicy.merge(local: local, incoming: candidate)
        if merged != local { savePrep(merged) }
        return (merged, blocked)
    }


    func link(forTrack trackId: String) -> TrackLink? {
        blob(sql: "SELECT payload FROM track_link WHERE track_id = ?;", key: trackId)
            .flatMap { try? PrepCoding.decoder.decode(TrackLink.self, from: $0) }
    }

    func allLinks() -> [TrackLink] {
        blobs(sql: "SELECT payload FROM track_link ORDER BY updated_at_millis DESC;", bindings: [])
            .compactMap { try? PrepCoding.decoder.decode(TrackLink.self, from: $0) }
    }

    @discardableResult
    func saveLink(_ link: TrackLink, now: Int64 = CueTime.nowMillis()) -> TrackLink {
        var stamped = link
        stamped.updatedAtMillis = now
        stamped.writerId = writerId
        writeLink(stamped)
        notifyLocalChange()
        return stamped
    }

    private func writeLink(_ link: TrackLink) {
        guard let payload = try? PrepCoding.encoder.encode(link) else { return }
        execute(
            "INSERT INTO track_link (track_id, payload, updated_at_millis) VALUES (?, ?, ?) "
                + "ON CONFLICT(track_id) DO UPDATE SET payload = excluded.payload, updated_at_millis = excluded.updated_at_millis;",
            [.text(link.trackId), .blob(payload), .int(link.updatedAtMillis)]
        )
        logChange(recordName: "link:\(link.trackId)", kind: .link, trackId: link.trackId)
    }

    func linkFile(forTrack trackId: String) -> TrackLinkFile? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT bookmark, path FROM track_link_file WHERE track_id = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, [.text(trackId)])
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let blob = sqlite3_column_blob(stmt, 0),
              let pathPtr = sqlite3_column_text(stmt, 1) else { return nil }
        let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
        return TrackLinkFile(trackId: trackId, bookmark: data, path: String(cString: pathPtr))
    }

    func saveLinkFile(_ file: TrackLinkFile) {
        execute(
            "INSERT INTO track_link_file (track_id, bookmark, path) VALUES (?, ?, ?) "
                + "ON CONFLICT(track_id) DO UPDATE SET bookmark = excluded.bookmark, path = excluded.path;",
            [.text(file.trackId), .blob(file.bookmark), .text(file.path)]
        )
    }

    func removeLinkFile(trackId: String) {
        execute("DELETE FROM track_link_file WHERE track_id = ?;", [.text(trackId)])
    }

    func linkedFileTrackIds() -> Set<String> {
        Set(strings(sql: "SELECT track_id FROM track_link_file;"))
    }

    func preparedTrackIds() -> [String] {
        let ids = strings(sql: "SELECT track_id FROM track_link UNION SELECT track_id FROM track_prep UNION SELECT DISTINCT track_id FROM cue WHERE is_deleted = 0;")
        return Array(Set(ids)).sorted()
    }


    func tallies(forTrack trackId: String) -> [ListeningTally] {
        blobs(sql: "SELECT payload FROM listening_tally WHERE track_id = ?;", bindings: [.text(trackId)])
            .compactMap { try? PrepCoding.decoder.decode(ListeningTally.self, from: $0) }
    }

    func recordListening(trackId: String, positionMillis: Int64, sessionId: String, deviceId: String? = nil, now: Int64 = CueTime.nowMillis()) {
        let device = deviceId ?? writerId
        var tally = tallies(forTrack: trackId).first { $0.deviceId == device }
            ?? ListeningTally(trackId: trackId, deviceId: device)
        tally.record(positionMillis: positionMillis, sessionId: sessionId, now: now)
        writeTally(tally)
        notifyLocalChange()
    }

    private func writeTally(_ tally: ListeningTally) {
        guard let payload = try? PrepCoding.encoder.encode(tally) else { return }
        execute(
            "INSERT INTO listening_tally (record_name, track_id, payload, updated_at_millis) VALUES (?, ?, ?, ?) "
                + "ON CONFLICT(record_name) DO UPDATE SET payload = excluded.payload, updated_at_millis = excluded.updated_at_millis;",
            [.text(tally.recordName), .text(tally.trackId), .blob(payload), .int(tally.updatedAtMillis)]
        )
        logChange(recordName: tally.recordName, kind: .tally, trackId: tally.trackId)
        noteChange(trackId: tally.trackId)
    }

    func dismissals(forTrack trackId: String) -> [CueDismissal] {
        dismissalRecords(changedSince: Int64.min, limit: 100_000).filter { $0.trackId == trackId }
    }

    func listeningSuggestions(forTrack trackId: String, grid: BeatGrid?, duration: TimeInterval) -> [CueSuggestion] {
        ListeningSuggester.suggest(
            trackId: trackId,
            tallies: tallies(forTrack: trackId),
            grid: grid,
            duration: duration,
            userCues: cues(forTrack: trackId),
            dismissals: dismissals(forTrack: trackId)
        )
    }


    func saveRekordboxPlaylists(_ playlists: [RekordboxPlaylistRecord]) {
        execute("DELETE FROM rekordbox_playlist;", [])
        for (index, playlist) in playlists.enumerated() {
            guard let payload = try? PrepCoding.encoder.encode(playlist) else { continue }
            execute(
                "INSERT OR REPLACE INTO rekordbox_playlist (playlist_id, position, payload) VALUES (?, ?, ?);",
                [.text(playlist.id), .int(Int64(index)), .blob(payload)]
            )
        }
    }

    func rekordboxPlaylists() -> [RekordboxPlaylistRecord] {
        blobs(sql: "SELECT payload FROM rekordbox_playlist ORDER BY position ASC;", bindings: [])
            .compactMap { try? PrepCoding.decoder.decode(RekordboxPlaylistRecord.self, from: $0) }
    }


    func prepSyncRecords(changedSince cursorMillis: Int64, limit: Int = 2_000) -> [PrepSyncRecord] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT record_name, kind, track_id, changed_at_millis FROM prep_sync_log WHERE changed_at_millis > ? ORDER BY changed_at_millis ASC LIMIT ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bind(stmt, [.int(cursorMillis), .int(Int64(limit))])
        var due: [(String, PrepRecordKind, String, Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let name = sqlite3_column_text(stmt, 0), let kind = sqlite3_column_text(stmt, 1),
                  let track = sqlite3_column_text(stmt, 2),
                  let parsed = PrepRecordKind(rawValue: String(cString: kind)) else { continue }
            due.append((String(cString: name), parsed, String(cString: track), sqlite3_column_int64(stmt, 3)))
        }
        sqlite3_finalize(stmt)

        return due.compactMap { name, kind, trackId, changedAt in
            let record: PrepSyncRecord?
            switch kind {
            case .prep: record = prep(forTrack: trackId).flatMap(PrepSyncRecord.prep)
            case .link: record = link(forTrack: trackId).flatMap(PrepSyncRecord.link)
            case .tally:
                record = blob(sql: "SELECT payload FROM listening_tally WHERE record_name = ?;", key: name)
                    .flatMap { try? PrepCoding.decoder.decode(ListeningTally.self, from: $0) }
                    .flatMap(PrepSyncRecord.tally)
            }
            guard let record else { return nil }
            return PrepSyncRecord(
                recordName: record.recordName, kind: record.kind, trackId: record.trackId,
                payload: record.payload, updatedAtMillis: changedAt, writerId: record.writerId
            )
        }
    }

    @discardableResult
    func adoptPrepRecords(_ records: [PrepSyncRecord]) -> Int {
        batchingChanges { adoptPrepRecordsNow(records) }
    }

    private func adoptPrepRecordsNow(_ records: [PrepSyncRecord]) -> Int {
        var adopted = 0
        for record in records {
            switch record.kind {
            case .prep:
                guard let incoming = try? PrepCoding.decoder.decode(TrackPrep.self, from: record.payload) else { continue }
                let local = prep(forTrack: incoming.trackId)
                let merged = TrackPrepPolicy.merge(local: local, incoming: incoming)
                guard merged != local else { continue }
                writePrepSilently(merged)
                adopted += 1
            case .link:
                guard let incoming = try? PrepCoding.decoder.decode(TrackLink.self, from: record.payload),
                      TrackLink.remoteWins(local: link(forTrack: incoming.trackId), remote: incoming) else { continue }
                guard let payload = try? PrepCoding.encoder.encode(incoming) else { continue }
                execute(
                    "INSERT INTO track_link (track_id, payload, updated_at_millis) VALUES (?, ?, ?) "
                        + "ON CONFLICT(track_id) DO UPDATE SET payload = excluded.payload, updated_at_millis = excluded.updated_at_millis;",
                    [.text(incoming.trackId), .blob(payload), .int(incoming.updatedAtMillis)]
                )
                adopted += 1
            case .tally:
                guard let incoming = try? PrepCoding.decoder.decode(ListeningTally.self, from: record.payload),
                      incoming.deviceId != writerId else { continue }
                let existing = tallies(forTrack: incoming.trackId).first { $0.deviceId == incoming.deviceId }
                guard existing.map({ $0.updatedAtMillis < incoming.updatedAtMillis }) ?? true else { continue }
                guard let payload = try? PrepCoding.encoder.encode(incoming) else { continue }
                execute(
                    "INSERT INTO listening_tally (record_name, track_id, payload, updated_at_millis) VALUES (?, ?, ?, ?) "
                        + "ON CONFLICT(record_name) DO UPDATE SET payload = excluded.payload, updated_at_millis = excluded.updated_at_millis;",
                    [.text(incoming.recordName), .text(incoming.trackId), .blob(payload), .int(incoming.updatedAtMillis)]
                )
                noteChange(trackId: incoming.trackId)
                adopted += 1
            }
        }
        return adopted
    }

    private func writePrepSilently(_ prep: TrackPrep) {
        guard let payload = try? PrepCoding.encoder.encode(prep) else { return }
        execute(
            "INSERT INTO track_prep (track_id, payload, updated_at_millis) VALUES (?, ?, ?) "
                + "ON CONFLICT(track_id) DO UPDATE SET payload = excluded.payload, updated_at_millis = excluded.updated_at_millis;",
            [.text(prep.trackId), .blob(payload), .int(prep.updatedAtMillis)]
        )
        noteChange(trackId: prep.trackId)
    }


    private func logChange(recordName: String, kind: PrepRecordKind, trackId: String) {
        let now = max(CueTime.nowMillis(), lastPrepChangeMillis() + 1)
        execute(
            "INSERT INTO prep_sync_log (record_name, kind, track_id, changed_at_millis) VALUES (?, ?, ?, ?) "
                + "ON CONFLICT(record_name) DO UPDATE SET changed_at_millis = excluded.changed_at_millis;",
            [.text(recordName), .text(kind.rawValue), .text(trackId), .int(now)]
        )
    }

    private func lastPrepChangeMillis() -> Int64 {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(changed_at_millis) FROM prep_sync_log;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    private func execute(_ sql: String, _ bindings: [PrepBinding]) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindPrep(stmt, bindings)
        sqlite3_step(stmt)
    }

    private func blob(sql: String, key: String) -> Data? {
        blobs(sql: sql, bindings: [.text(key)]).first
    }

    private func blobs(sql: String, bindings: [PrepBinding]) -> [Data] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindPrep(stmt, bindings)
        var out: [Data] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pointer = sqlite3_column_blob(stmt, 0) else { continue }
            out.append(Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, 0))))
        }
        return out
    }

    private func strings(sql: String) -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let pointer = sqlite3_column_text(stmt, 0) { out.append(String(cString: pointer)) }
        }
        return out
    }

    enum PrepBinding {
        case text(String)
        case int(Int64)
        case blob(Data)
    }

    private func bindPrep(_ stmt: OpaquePointer?, _ bindings: [PrepBinding]) {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value):
                _ = value.withCString { sqlite3_bind_text(stmt, index, $0, -1, Self.sqliteTransient) }
            case .int(let value):
                sqlite3_bind_int64(stmt, index, value)
            case .blob(let value):
                _ = value.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(value.count), Self.sqliteTransient) }
            }
        }
    }
}
