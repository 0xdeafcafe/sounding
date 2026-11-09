import CloudKit
import Foundation
import os

@MainActor
final class LinkOwnerKeyCloud {
    static let shared = LinkOwnerKeyCloud()

    private static let refreshInterval: TimeInterval = 6 * 3_600
    private static let emptyRetryInterval: TimeInterval = 300

    private var task: Task<Void, Never>?
    private var lastAttempt: Date?
    private var accountObserver: NSObjectProtocol?

    static var isEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_UI_FIXTURE"] == "1" { return false }
        #endif
        return CloudSyncEngineController.containerIdentifierIsEntitled(CloudSyncContainer.identifier)
    }

    func refreshIfNeeded(now: Date = Date()) {
        guard Self.isEnabled, task == nil else { return }
        observeAccountChanges()
        let interval = LinkOwnerKeyStore.usableKeys(at: now).isEmpty ? Self.emptyRetryInterval : Self.refreshInterval
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < interval { return }
        lastAttempt = now
        task = Task { [weak self] in
            await LinkOwnerKeyRecord.sync()
            self?.task = nil
        }
    }

    private func accountChanged() {
        LinkOwnerKeyStore.clear()
        lastAttempt = nil
        refreshIfNeeded()
    }

    private func observeAccountChanges() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in LinkOwnerKeyCloud.shared.accountChanged() }
        }
    }
}

enum LinkOwnerKeyRecord {
    static let recordType = "LinkOwnerKey"
    static let recordName = "linkOwnerKey"

    enum Field {
        static let currentKey = "currentKey"
        static let currentCreatedAtMillis = "currentCreatedAtMillis"
        static let previousKey = "previousKey"
        static let previousRetiresAtMillis = "previousRetiresAtMillis"
    }

    static func sync() async {
        let container = CKContainer(identifier: CloudSyncContainer.identifier)
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                if status == .noAccount || status == .restricted { LinkOwnerKeyStore.clear() }
                return
            }
        } catch {
            return
        }
        let database = container.privateCloudDatabase
        let recordID = CKRecord.ID(recordName: recordName)
        for _ in 0 ..< 3 {
            do {
                let existing: CKRecord?
                do {
                    existing = try await database.record(for: recordID)
                } catch let error as CKError where error.code == .unknownItem {
                    existing = nil
                }
                if let existing {
                    guard let ring = ring(from: existing) else {
                        Log.link.error("[LinkOwnerKey] the iCloud record couldn't be read; keeping the local copy")
                        return
                    }
                    guard let next = ring.rotated(at: Date()) else {
                        LinkOwnerKeyStore.save(ring)
                        return
                    }
                    try await save(next, into: existing, database: database)
                    LinkOwnerKeyStore.save(next)
                    Log.link.info("[LinkOwnerKey] rotated")
                } else {
                    guard let created = LinkOwnerKeyRing().rotated(at: Date()) else { return }
                    let record = CKRecord(recordType: recordType, recordID: recordID)
                    try await save(created, into: record, database: database)
                    LinkOwnerKeyStore.save(created)
                    Log.link.info("[LinkOwnerKey] created")
                }
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            } catch {
                Log.link.info("[LinkOwnerKey] not synced: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    private static func save(_ ring: LinkOwnerKeyRing, into record: CKRecord, database: CKDatabase) async throws {
        write(ring, into: record)
        let results = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        if case .failure(let error)? = results.saveResults[record.recordID] { throw error }
    }

    static func write(_ ring: LinkOwnerKeyRing, into record: CKRecord) {
        record.encryptedValues[Field.currentKey] = ring.current.map { $0.material as NSData }
        record[Field.currentCreatedAtMillis] = ring.current.map { NSNumber(value: millis($0.createdAt)) }
        record.encryptedValues[Field.previousKey] = ring.previous.map { $0.material as NSData }
        let retires: NSNumber? = ring.previous?.retiresAt.map { NSNumber(value: millis($0)) }
        record[Field.previousRetiresAtMillis] = retires
    }

    static func ring(from record: CKRecord) -> LinkOwnerKeyRing? {
        guard record.recordType == recordType,
              let material = record.encryptedValues[Field.currentKey] as? Data,
              material.count == LinkOwnerKey.length,
              let created = (record[Field.currentCreatedAtMillis] as? NSNumber)?.int64Value else { return nil }
        var ring = LinkOwnerKeyRing(current: LinkOwnerKey(material: material, createdAt: date(created)))
        if let previous = record.encryptedValues[Field.previousKey] as? Data,
           previous.count == LinkOwnerKey.length,
           let retires = (record[Field.previousRetiresAtMillis] as? NSNumber)?.int64Value {
            ring.previous = LinkOwnerKey(
                material: previous,
                createdAt: date(created).addingTimeInterval(-LinkOwnerKeyRing.rotationAge),
                retiresAt: date(retires)
            )
        }
        return ring
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }
}
