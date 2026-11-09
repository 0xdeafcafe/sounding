import Foundation
import CloudKit

protocol PrepSyncStore: Sendable {
    func pendingPrepChanges(since cursorMillis: Int64, limit: Int) async -> [PrepSyncRecord]
    @discardableResult
    func adoptPrep(_ records: [PrepSyncRecord]) async -> Int
}

protocol PrepSyncTransport: Sendable {
    func isReady() async -> Bool
    func offer(_ records: [PrepSyncRecord]) async throws
    func fetch() async throws -> [PrepSyncRecord]
}

extension CueStore: PrepSyncStore {
    func pendingPrepChanges(since cursorMillis: Int64, limit: Int) async -> [PrepSyncRecord] {
        prepSyncRecords(changedSince: cursorMillis, limit: limit)
    }

    @discardableResult
    func adoptPrep(_ records: [PrepSyncRecord]) async -> Int {
        adoptPrepRecords(records)
    }
}

struct PrepSyncRelay: Sendable {
    let store: any PrepSyncStore
    let transport: any PrepSyncTransport
    let exportLimit: Int

    init(store: any PrepSyncStore, transport: any PrepSyncTransport, exportLimit: Int = 2_000) {
        self.store = store
        self.transport = transport
        self.exportLimit = exportLimit
    }

    struct RoundResult: Sendable, Equatable {
        var fetched = 0
        var adopted = 0
        var offered = 0
        var pushedThroughMillis: Int64 = 0
        var skippedNotReady = false
    }

    func runOnce(pushedThroughMillis: Int64) async throws -> RoundResult {
        var result = RoundResult(pushedThroughMillis: pushedThroughMillis)
        guard await transport.isReady() else {
            result.skippedNotReady = true
            return result
        }
        let incoming = try await transport.fetch()
        result.fetched = incoming.count
        result.adopted = incoming.isEmpty ? 0 : await store.adoptPrep(incoming)

        let pending = await store.pendingPrepChanges(since: pushedThroughMillis, limit: exportLimit)
        if !pending.isEmpty { try await transport.offer(pending) }
        result.offered = pending.count
        result.pushedThroughMillis = max(pushedThroughMillis, pending.map(\.updatedAtMillis).max() ?? 0)
        return result
    }
}

extension CloudSyncRecordType {
    static let prepRecord = "PrepRecord"
}

extension CloudSyncMapping {
    static func record(for prep: PrepSyncRecord) -> CKRecord {
        let record = CKRecord(recordType: CloudSyncRecordType.prepRecord, recordID: CKRecord.ID(recordName: prep.recordName, zoneID: CloudSyncZone.cues))
        record["kind"] = prep.kind.rawValue as CKRecordValue
        record["trackId"] = prep.trackId as CKRecordValue
        record["payload"] = prep.payload as CKRecordValue
        record["updatedAtMillis"] = prep.updatedAtMillis as CKRecordValue
        record["writerId"] = prep.writerId as CKRecordValue
        return record
    }

    static func prepRecord(from record: CKRecord) -> PrepSyncRecord? {
        guard record.recordType == CloudSyncRecordType.prepRecord,
              let kindRaw = record["kind"] as? String,
              let kind = PrepRecordKind(rawValue: kindRaw),
              let trackId = record["trackId"] as? String,
              let payload = record["payload"] as? Data,
              let updatedAtMillis = record["updatedAtMillis"] as? Int64,
              let writerId = record["writerId"] as? String
        else { return nil }
        return PrepSyncRecord(
            recordName: record.recordID.recordName, kind: kind, trackId: trackId,
            payload: payload, updatedAtMillis: updatedAtMillis, writerId: writerId
        )
    }
}

struct CloudKitPrepSyncTransport: PrepSyncTransport {
    let controller: CloudSyncEngineController

    func isReady() async -> Bool { await controller.isReadyToSync() }

    func offer(_ records: [PrepSyncRecord]) async throws {
        guard !records.isEmpty else { return }
        try await controller.enqueue(records.map(CloudSyncMapping.record(for:)))
    }

    func fetch() async throws -> [PrepSyncRecord] {
        try await controller.fetchLatestChanges()
        return await controller.prepInbox.drain()
    }
}
