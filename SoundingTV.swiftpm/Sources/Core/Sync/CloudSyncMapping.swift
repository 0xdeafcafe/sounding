import Foundation
import CloudKit

enum CloudSyncMapping {
    private static let encryptedOAuthTokenKey = "oauthTokenEncrypted"
    private static let encryptedRefreshTokenKey = "refreshTokenEncrypted"
    private static let encryptedClientIdKey = "clientIdEncrypted"

    static func record(for cue: CueSyncRecord) -> CKRecord {
        let record = CKRecord(recordType: CloudSyncRecordType.cue, recordID: CKRecord.ID(recordName: cue.cueId, zoneID: CloudSyncZone.cues))
        record["trackId"] = cue.trackId as CKRecordValue
        record["kind"] = cue.kind.rawValue as CKRecordValue
        record["positionMillis"] = cue.positionMillis as CKRecordValue
        record["endMillis"] = cue.endMillis as CKRecordValue?
        record["hotCueIndex"] = cue.hotCueIndex.map { Int64($0) } as CKRecordValue?
        record["label"] = cue.label as CKRecordValue
        record["colorRGB"] = Int64(cue.colorRGB) as CKRecordValue
        record["isDeleted"] = (cue.isDeleted ? 1 : 0) as CKRecordValue
        record["promotedFromName"] = cue.promotedFromName as CKRecordValue?
        record["promotedFromVersion"] = cue.promotedFromVersion.map { Int64($0) } as CKRecordValue?
        record["origin"] = cue.origin?.rawValue as CKRecordValue?
        record["createdAtMillis"] = cue.createdAtMillis as CKRecordValue
        record["updatedAtMillis"] = cue.updatedAtMillis as CKRecordValue
        record["writerId"] = cue.writerId as CKRecordValue
        return record
    }

    static func cue(from record: CKRecord) -> CueSyncRecord? {
        guard record.recordType == CloudSyncRecordType.cue,
              let trackId = record["trackId"] as? String,
              let kindRaw = record["kind"] as? String,
              let kind = CueKind(rawValue: kindRaw),
              let positionMillis = record["positionMillis"] as? Int64,
              let label = record["label"] as? String,
              let colorRGB = record["colorRGB"] as? Int64,
              let isDeletedRaw = record["isDeleted"] as? Int64,
              let createdAtMillis = record["createdAtMillis"] as? Int64,
              let updatedAtMillis = record["updatedAtMillis"] as? Int64,
              let writerId = record["writerId"] as? String
        else { return nil }

        let promotedFrom: CueSuggesterIdentity? = (record["promotedFromName"] as? String).flatMap { name in
            (record["promotedFromVersion"] as? Int64).map { CueSuggesterIdentity(name: name, version: Int($0)) }
        }
        let cuePoint = CuePoint(
            id: record.recordID.recordName,
            trackId: trackId,
            kind: kind,
            positionMillis: positionMillis,
            endMillis: record["endMillis"] as? Int64,
            hotCueIndex: (record["hotCueIndex"] as? Int64).map(Int.init),
            label: label,
            color: CueColor(rgb: UInt32(truncatingIfNeeded: colorRGB)),
            createdAtMillis: createdAtMillis,
            updatedAtMillis: updatedAtMillis,
            isDeleted: isDeletedRaw != 0,
            promotedFrom: promotedFrom,
            writerId: writerId,
            origin: (record["origin"] as? String).flatMap(CueOrigin.init(rawValue:)) ?? .user
        )
        return CueSyncRecord(cuePoint)
    }

    static func record(for dismissal: CueDismissal) -> CKRecord {
        let record = CKRecord(recordType: CloudSyncRecordType.cueDismissal, recordID: CKRecord.ID(recordName: dismissal.id, zoneID: CloudSyncZone.cues))
        record["trackId"] = dismissal.trackId as CKRecordValue
        record["suggesterName"] = dismissal.suggesterName as CKRecordValue
        record["suggesterVersion"] = Int64(dismissal.suggesterVersion) as CKRecordValue
        record["kind"] = dismissal.kind.rawValue as CKRecordValue
        record["positionMillis"] = dismissal.positionMillis as CKRecordValue
        record["dismissedAtMillis"] = dismissal.dismissedAtMillis as CKRecordValue
        record["writerId"] = dismissal.writerId as CKRecordValue
        return record
    }

    static func dismissal(from record: CKRecord) -> CueDismissal? {
        guard record.recordType == CloudSyncRecordType.cueDismissal,
              let trackId = record["trackId"] as? String,
              let suggesterName = record["suggesterName"] as? String,
              let suggesterVersion = record["suggesterVersion"] as? Int64,
              let kindRaw = record["kind"] as? String,
              let kind = CueKind(rawValue: kindRaw),
              let positionMillis = record["positionMillis"] as? Int64,
              let dismissedAtMillis = record["dismissedAtMillis"] as? Int64,
              let writerId = record["writerId"] as? String
        else { return nil }
        return CueDismissal(
            id: record.recordID.recordName, trackId: trackId, suggesterName: suggesterName,
            suggesterVersion: Int(suggesterVersion), kind: kind, positionMillis: positionMillis,
            dismissedAtMillis: dismissedAtMillis, writerId: writerId
        )
    }

    static func record(for row: AnalysisSyncRecord) -> CKRecord {
        let record = CKRecord(recordType: CloudSyncRecordType.analysisRow, recordID: CKRecord.ID(recordName: row.cacheKey, zoneID: CloudSyncZone.analysis))
        record["trackId"] = row.trackId as CKRecordValue
        record["engineName"] = row.engineName as CKRecordValue
        record["engineVersion"] = Int64(row.engineVersion) as CKRecordValue
        record["schemaVersion"] = Int64(row.schemaVersion) as CKRecordValue
        record["durationMillis"] = Int64(row.durationMillis) as CKRecordValue
        record["preset"] = row.preset as CKRecordValue
        record["bitrate"] = Int64(row.bitrate) as CKRecordValue
        record["codec"] = row.codec as CKRecordValue
        record["payload"] = row.payload as CKRecordValue
        record["payloadEncoding"] = row.payloadEncoding.rawValue as CKRecordValue
        record["uncompressedByteSize"] = Int64(row.uncompressedByteSize) as CKRecordValue
        record["payloadDigest"] = row.payloadDigest as CKRecordValue
        record["bpm"] = row.bpm as CKRecordValue?
        record["keyWheelPosition"] = row.keyWheelPosition.map { Int64($0) } as CKRecordValue?
        record["keyMode"] = row.keyMode.map { Int64($0) } as CKRecordValue?
        record["genre"] = row.genre as CKRecordValue?
        record["producedAtMillis"] = row.producedAtMillis as CKRecordValue
        record["producerId"] = row.producerId as CKRecordValue
        return record
    }

    static func analysisRecord(from record: CKRecord) -> AnalysisSyncRecord? {
        guard record.recordType == CloudSyncRecordType.analysisRow,
              let trackId = record["trackId"] as? String,
              let engineName = record["engineName"] as? String,
              let engineVersion = record["engineVersion"] as? Int64,
              let schemaVersion = record["schemaVersion"] as? Int64,
              let durationMillis = record["durationMillis"] as? Int64,
              let preset = record["preset"] as? String,
              let bitrate = record["bitrate"] as? Int64,
              let codec = record["codec"] as? String,
              let payload = record["payload"] as? Data,
              let payloadEncodingRaw = record["payloadEncoding"] as? String,
              let payloadEncoding = AnalysisPayloadEncoding(rawValue: payloadEncodingRaw),
              let uncompressedByteSize = record["uncompressedByteSize"] as? Int64,
              let payloadDigest = record["payloadDigest"] as? String,
              let producedAtMillis = record["producedAtMillis"] as? Int64,
              let producerId = record["producerId"] as? String
        else { return nil }

        return AnalysisSyncRecord(
            cacheKey: record.recordID.recordName,
            trackId: trackId, engineName: engineName, engineVersion: Int(engineVersion),
            schemaVersion: Int(schemaVersion), durationMillis: Int(durationMillis), preset: preset,
            bitrate: Int(bitrate), codec: codec, payload: payload, payloadEncoding: payloadEncoding,
            uncompressedByteSize: Int(uncompressedByteSize), payloadDigest: payloadDigest,
            bpm: record["bpm"] as? Double,
            keyWheelPosition: (record["keyWheelPosition"] as? Int64).map(Int.init),
            keyMode: (record["keyMode"] as? Int64).map(Int.init),
            genre: record["genre"] as? String,
            producedAtMillis: producedAtMillis, producerId: producerId
        )
    }

    static func record(for entry: DownloadManifestSyncRecord) -> CKRecord {
        let record = CKRecord(recordType: CloudSyncRecordType.downloadManifestEntry, recordID: CKRecord.ID(recordName: entry.recordKey, zoneID: CloudSyncZone.downloadManifests))
        record["trackId"] = entry.trackId as CKRecordValue
        record["deviceId"] = entry.deviceId as CKRecordValue
        record["deviceLabel"] = entry.deviceLabel as CKRecordValue
        record["isPinned"] = (entry.isPinned ? 1 : 0) as CKRecordValue
        record["addedAtMillis"] = entry.addedAtMillis as CKRecordValue
        record["updatedAtMillis"] = entry.updatedAtMillis as CKRecordValue
        record["isDeleted"] = (entry.isDeleted ? 1 : 0) as CKRecordValue
        return record
    }

    static func downloadManifestRecord(from record: CKRecord) -> DownloadManifestSyncRecord? {
        guard record.recordType == CloudSyncRecordType.downloadManifestEntry,
              let trackId = record["trackId"] as? String,
              let deviceId = record["deviceId"] as? String,
              let deviceLabel = record["deviceLabel"] as? String,
              let isPinnedRaw = record["isPinned"] as? Int64,
              let addedAtMillis = record["addedAtMillis"] as? Int64,
              let updatedAtMillis = record["updatedAtMillis"] as? Int64,
              let isDeletedRaw = record["isDeleted"] as? Int64
        else { return nil }
        return DownloadManifestSyncRecord(
            trackId: trackId, deviceId: deviceId, deviceLabel: deviceLabel,
            isPinned: isPinnedRaw != 0, addedAtMillis: addedAtMillis, updatedAtMillis: updatedAtMillis,
            isDeleted: isDeletedRaw != 0
        )
    }

    static func record(for setlist: SetlistSyncRecord) -> CKRecord {
        let record = CKRecord(
            recordType: CloudSyncRecordType.setlistSnapshot,
            recordID: CKRecord.ID(recordName: setlist.recordKey, zoneID: CloudSyncZone.setlists)
        )
        record["trackId"] = setlist.trackId as CKRecordValue
        record["deviceId"] = setlist.deviceId as CKRecordValue
        record["payload"] = setlist.payload as CKRecordValue
        record["updatedAtMillis"] = setlist.updatedAtMillis as CKRecordValue
        return record
    }

    static func setlistRecord(from record: CKRecord) -> SetlistSyncRecord? {
        guard record.recordType == CloudSyncRecordType.setlistSnapshot,
              let trackId = record["trackId"] as? String,
              let deviceId = record["deviceId"] as? String,
              let payload = record["payload"] as? Data,
              let updatedAtMillis = record["updatedAtMillis"] as? Int64 else { return nil }
        return SetlistSyncRecord(
            trackId: trackId,
            deviceId: deviceId,
            payload: payload,
            updatedAtMillis: updatedAtMillis
        )
    }

    static func record(for settings: SettingsSyncRecord) -> CKRecord {
        let record = CKRecord(
            recordType: CloudSyncRecordType.settingsEntry,
            recordID: CKRecord.ID(recordName: settings.recordName, zoneID: CloudSyncZone.companion)
        )
        record["payload"] = settings.payload as CKRecordValue
        record["writerId"] = settings.writerId as CKRecordValue
        record["updatedAtMillis"] = settings.updatedAtMillis as CKRecordValue
        return record
    }

    static func settingsRecord(from record: CKRecord) -> SettingsSyncRecord? {
        guard record.recordType == CloudSyncRecordType.settingsEntry,
              let payload = record["payload"] as? Data,
              let writerId = record["writerId"] as? String,
              let updatedAtMillis = record["updatedAtMillis"] as? Int64 else { return nil }
        let name = SettingsSyncRecord.parse(recordName: record.recordID.recordName)
        return SettingsSyncRecord(
            deviceId: name.deviceId,
            payload: payload,
            writerId: writerId,
            updatedAtMillis: updatedAtMillis,
            accountTag: name.accountTag
        )
    }

    static func record(for device: CompanionDeviceRecord) -> CKRecord {
        let record = CKRecord(
            recordType: CloudSyncRecordType.companionDevice,
            recordID: CKRecord.ID(recordName: device.deviceId, zoneID: CloudSyncZone.companion)
        )
        record["deviceClass"] = device.deviceClass.rawValue as CKRecordValue
        record["displayName"] = device.displayName as CKRecordValue
        record["accountId"] = device.accountId as CKRecordValue?
        record["lastSeenAtMillis"] = device.lastSeenAtMillis as CKRecordValue
        record["conditionsJSON"] = (try? JSONEncoder().encode(device.conditions)) as CKRecordValue?
        record["appVersion"] = device.appVersion as CKRecordValue
        return record
    }

    static func companionDeviceRecord(from record: CKRecord) -> CompanionDeviceRecord? {
        guard record.recordType == CloudSyncRecordType.companionDevice,
              let deviceClassRaw = record["deviceClass"] as? String,
              let deviceClass = DeviceClass(rawValue: deviceClassRaw),
              let displayName = record["displayName"] as? String,
              let lastSeenAtMillis = record["lastSeenAtMillis"] as? Int64,
              let appVersion = record["appVersion"] as? String
        else { return nil }
        let conditions = (record["conditionsJSON"] as? Data).flatMap {
            try? JSONDecoder().decode(DeviceConditions.self, from: $0)
        } ?? .unknown
        return CompanionDeviceRecord(
            deviceId: record.recordID.recordName,
            deviceClass: deviceClass,
            displayName: displayName,
            accountId: record["accountId"] as? String,
            lastSeenAtMillis: lastSeenAtMillis,
            conditions: conditions,
            appVersion: appVersion
        )
    }

    static let sessionRecordID = CKRecord.ID(recordName: "session", zoneID: CloudSyncZone.session)

    static func record(
        for session: SyncedSoundCloudSession,
        updating existingRecord: CKRecord? = nil
    ) -> CKRecord {
        // Do not reuse an existing record: older records contain plaintext
        // fields with these names, which collide with encryptedValues.
        let record = CKRecord(
            recordType: CloudSyncRecordType.session,
            recordID: sessionRecordID
        )
        assert(record.recordID == sessionRecordID)
        assert(record.recordType == CloudSyncRecordType.session)
        record.encryptedValues[encryptedOAuthTokenKey] = session.oauthToken as CKRecordValue
        record.encryptedValues[encryptedRefreshTokenKey] = session.refreshToken as CKRecordValue?
        record.encryptedValues[encryptedClientIdKey] = session.clientId as CKRecordValue?
        record["expiresAtMillis"] = session.expiresAtMillis as CKRecordValue?
        record["updatedAtMillis"] = (session.issuedAtMillis ?? session.updatedAtMillis) as CKRecordValue
        record["writerId"] = sessionWriterField(writerId: session.writerId, issued: session.issuedAtMillis != nil, generation: session.generation) as CKRecordValue
        return record
    }

    private static let issuanceMarker = "#issued.g"

    static func sessionWriterField(writerId: String, issued: Bool, generation: Int64?) -> String {
        guard issued else { return writerId }
        return writerId + issuanceMarker + String(generation ?? 0)
    }

    static func parseSessionWriterField(_ field: String) -> (writerId: String, issued: Bool, generation: Int64?) {
        guard let range = field.range(of: issuanceMarker) else { return (field, false, nil) }
        return (String(field[..<range.lowerBound]), true, Int64(field[range.upperBound...]))
    }

    static func session(from record: CKRecord) -> SyncedSoundCloudSession? {
        guard record.recordType == CloudSyncRecordType.session,
              let oauthToken = record.encryptedValues[encryptedOAuthTokenKey] as? String,
              let updatedAtMillis = record["updatedAtMillis"] as? Int64,
              let writerField = record["writerId"] as? String
        else { return nil }
        let writer = parseSessionWriterField(writerField)
        let writerId = writer.writerId
        return SyncedSoundCloudSession(
            oauthToken: oauthToken,
            refreshToken: record.encryptedValues[encryptedRefreshTokenKey] as? String,
            clientId: record.encryptedValues[encryptedClientIdKey] as? String,
            expiresAtMillis: record["expiresAtMillis"] as? Int64,
            updatedAtMillis: updatedAtMillis,
            writerId: writerId,
            issuedAtMillis: writer.issued ? updatedAtMillis : nil,
            generation: writer.generation
        )
    }
}

extension CloudSyncMapping {
    static let libraryPayloadLimit = 600_000

    static func record(for chunk: LibraryChunk) -> CKRecord? {
        guard let payload = chunk.encoded(), payload.count <= libraryPayloadLimit else { return nil }
        let record = CKRecord(
            recordType: CloudSyncRecordType.libraryChunk,
            recordID: CKRecord.ID(recordName: chunk.recordName, zoneID: CloudSyncZone.library)
        )
        record["account"] = chunk.account as CKRecordValue
        record["collection"] = chunk.collection as CKRecordValue
        record["bucket"] = Int64(chunk.bucket) as CKRecordValue
        record["bucketCount"] = Int64(chunk.bucketCount) as CKRecordValue
        record["payload"] = payload as CKRecordValue
        record["updatedAtMillis"] = chunk.updatedAtMillis as CKRecordValue
        record["writerId"] = chunk.writerId as CKRecordValue
        return record
    }

    static func libraryChunk(from record: CKRecord) -> LibraryChunk? {
        guard record.recordType == CloudSyncRecordType.libraryChunk,
              let account = record["account"] as? String,
              let payload = record["payload"] as? Data,
              let chunk = LibraryChunk.decode(payload),
              chunk.account == account else { return nil }
        return chunk
    }
}
