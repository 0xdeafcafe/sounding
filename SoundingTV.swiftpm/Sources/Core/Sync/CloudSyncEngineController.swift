import Foundation
import CloudKit
import Combine

final class CloudSyncEngineController: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    static let shared = CloudSyncEngineController(containerIdentifier: CloudSyncContainer.identifier)

    let cueInbox = CloudSyncInbox<CueSyncRecord>()
    let cueDismissalInbox = CloudSyncInbox<CueDismissal>()
    let analysisInbox = CloudSyncInbox<AnalysisSyncRecord>()
    let sessionInbox = CloudSyncInbox<SyncedSoundCloudSession>()
    let downloadManifestInbox = CloudSyncInbox<DownloadManifestSyncRecord>()
    let setlistInbox = CloudSyncInbox<SetlistSyncRecord>()
    let companionDeviceInbox = CloudSyncInbox<CompanionDeviceRecord>()
    let settingsInbox = CloudSyncInbox<SettingsSyncRecord>()
    let prepInbox = CloudSyncInbox<PrepSyncRecord>()
    let libraryInbox = CloudSyncInbox<LibraryChunk>()

    private let containerIdentifier: String
    private let stateDefaultsKey = "red.forbes.sounding.cloudsync.stateSerialization"

    private let lock = NSLock()
    private var container: CKContainer?
    private var containerEntitlementAbsent = false
    private var engine: CKSyncEngine?
    private var pendingRecordsByID: [CKRecord.ID: CKRecord] = [:]
    private var zonesEnsured = false

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        super.init()
    }

    func start() {
        lock.lock()
        let alreadyStarted = engine != nil
        lock.unlock()
        guard !alreadyStarted else { return }

        guard let container = resolvedContainer() else { return }

        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: Self.loadStateSerialization(defaultsKey: stateDefaultsKey),
            delegate: self
        )
        let newEngine = CKSyncEngine(configuration)

        lock.lock()
        engine = newEngine
        let needsZones = !zonesEnsured
        zonesEnsured = true
        lock.unlock()

        if needsZones {
            newEngine.state.add(pendingDatabaseChanges: CloudSyncZone.all.map { .saveZone(CKRecordZone(zoneID: $0)) })
        }
    }

    func isReadyToSync() async -> Bool {
        await availability() == .available
    }

    func availability() async -> CloudSyncAvailability {
        let hasEngine = lock.withLock { engine != nil }
        guard hasEngine else {
            if resolvedContainer() == nil {
                return .unavailable("This build cannot access the Sounding iCloud container. Check its iCloud entitlement and provisioning profile.")
            }
            return .unavailable("Cloud sync has not started. Quit and reopen Sounding, then try again.")
        }
        guard let container = resolvedContainer() else {
            return .unavailable("This build cannot access the Sounding iCloud container. Check its iCloud entitlement and provisioning profile.")
        }

        do {
            switch try await container.accountStatus() {
            case .available:
                _ = try await container.privateCloudDatabase.allRecordZones()
                return .available
            case .noAccount:
                return .unavailable("No iCloud account is available on this Mac. Sign in to iCloud in System Settings, using the same account as your iPhone.")
            case .restricted:
                return .unavailable("iCloud access is restricted on this Mac. Check Screen Time or device-management restrictions.")
            case .couldNotDetermine:
                return .unavailable("The Mac could not determine its iCloud status. Check the network and iCloud settings, then try again.")
            case .temporarilyUnavailable:
                return .unavailable("iCloud is temporarily unavailable. Check the network and try again in a moment.")
            @unknown default:
                return .unavailable("This version of macOS reported an unknown iCloud account state.")
            }
        } catch {
            return .unavailable("CloudKit could not be reached: \(error.localizedDescription)")
        }
    }

    private func resolvedContainer() -> CKContainer? {
        lock.lock()
        if let container {
            lock.unlock()
            return container
        }
        if containerEntitlementAbsent {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard Self.containerIdentifierIsEntitled(containerIdentifier) else {
            lock.lock()
            containerEntitlementAbsent = true
            lock.unlock()
            Log.sync.info("iCloud container entitlement absent; cloud sync disabled for this build")
            return nil
        }

        let newContainer = CKContainer(identifier: containerIdentifier)
        lock.lock()
        container = newContainer
        lock.unlock()
        return newContainer
    }

    static func containerIdentifierIsEntitled(_ identifier: String) -> Bool {
        guard let identifiers = SecTaskEntitlementBridge.stringArrayValue(
            forEntitlement: "com.apple.developer.icloud-container-identifiers"
        ) else { return false }
        return identifiers.contains(identifier)
    }

    func enqueue(_ records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }
        let currentEngine = lock.withLock { engine }
        guard let currentEngine else { return }
        let preparedRecords = try await prepareRecordsForSave(records)
        guard !preparedRecords.isEmpty else { return }
        lock.withLock {
            for record in preparedRecords { pendingRecordsByID[record.recordID] = record }
        }
        currentEngine.state.add(pendingRecordZoneChanges: preparedRecords.map { .saveRecord($0.recordID) })
        do {
            try await Self.sendChangesOutsideDelegateContext(currentEngine)
        } catch {
            let resolution = await resolveServerConflicts(in: error as NSError, localRecords: preparedRecords)
            guard !resolution.recordIDs.isEmpty else { throw error }
            currentEngine.state.add(
                pendingRecordZoneChanges: resolution.recordIDs.map { .saveRecord($0) }
            )
            Log.sync.info("Retrying \(resolution.recordIDs.count, privacy: .public) CloudKit conflicts immediately with server change tags")
            try await Self.sendChangesOutsideDelegateContext(currentEngine)
            if !resolution.allFailuresWereConflicts { throw error }
        }
    }

    private static func sendChangesOutsideDelegateContext(_ engine: CKSyncEngine) async throws {
        let send = Task.detached { try await engine.sendChanges() }
        try await withTaskCancellationHandler {
            try await send.value
        } onCancel: {
            send.cancel()
        }
    }

    private func prepareRecordsForSave(_ localRecords: [CKRecord]) async throws -> [CKRecord] {
        guard let container = resolvedContainer() else { return [] }
        var prepared: [CKRecord] = []

        for start in stride(from: 0, to: localRecords.count, by: 200) {
            let end = min(start + 200, localRecords.count)
            let batch = Array(localRecords[start..<end])
            let fetched: [CKRecord.ID: Result<CKRecord, any Error>]
            do {
                fetched = try await container.privateCloudDatabase.records(for: batch.map(\.recordID))
            } catch let error as CKError where error.code == .zoneNotFound {
                prepared.append(contentsOf: batch)
                continue
            }

            for localRecord in batch {
                guard let result = fetched[localRecord.recordID] else {
                    prepared.append(localRecord)
                    continue
                }
                switch result {
                case .success(let serverRecord):
                    guard !Self.hasEqualFields(localRecord, serverRecord) else { continue }
                    for key in localRecord.allKeys() { serverRecord[key] = localRecord[key] }
                    prepared.append(serverRecord)
                case .failure(let error as CKError) where error.code == .unknownItem || error.code == .zoneNotFound:
                    prepared.append(localRecord)
                case .failure(let error):
                    throw error
                }
            }
        }

        Log.sync.info(
            "CloudKit prepared \(prepared.count, privacy: .public) changed records from \(localRecords.count, privacy: .public) candidates"
        )
        return prepared
    }

    private static func hasEqualFields(_ lhs: CKRecord, _ rhs: CKRecord) -> Bool {
        let leftKeys = Set(lhs.allKeys())
        guard leftKeys == Set(rhs.allKeys()) else { return false }
        for key in leftKeys {
            switch (lhs[key], rhs[key]) {
            case (nil, nil):
                continue
            case let (left as NSObject, right as NSObject) where left.isEqual(right):
                continue
            default:
                return false
            }
        }
        return true
    }

    private func resolveServerConflicts(
        in error: NSError,
        localRecords: [CKRecord]
    ) async -> (recordIDs: [CKRecord.ID], allFailuresWereConflicts: Bool) {
        let partial = partialErrors(in: error)
        var conflictIDs: [CKRecord.ID] = []
        var serverRecords: [CKRecord.ID: CKRecord] = [:]
        var allConflicts = true

        for (itemID, conflict) in partial {
            guard let recordID = itemID as? CKRecord.ID,
                  conflict.domain == CKErrorDomain,
                  conflict.code == CKError.Code.serverRecordChanged.rawValue else {
                allConflicts = false
                continue
            }
            conflictIDs.append(recordID)
            if let serverRecord = conflict.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                serverRecords[recordID] = serverRecord
            }
        }
        if conflictIDs.isEmpty {
            conflictIDs = localRecords.map(\.recordID)
            allConflicts = false
        }
        Log.sync.info(
            "CloudKit partial failure: \(partial.count, privacy: .public) items, \(conflictIDs.count, privacy: .public) server conflicts, \(serverRecords.count, privacy: .public) embedded server records"
        )

        let missing = conflictIDs.filter { serverRecords[$0] == nil }
        if !missing.isEmpty, let container = resolvedContainer() {
            for start in stride(from: 0, to: missing.count, by: 200) {
                let end = min(start + 200, missing.count)
                if let fetched = try? await container.privateCloudDatabase.records(
                    for: Array(missing[start..<end])
                ) {
                    for (id, result) in fetched {
                        if case .success(let record) = result { serverRecords[id] = record }
                    }
                }
            }
        }

        let localByID = Dictionary(uniqueKeysWithValues: localRecords.map { ($0.recordID, $0) })
        var resolvedIDs: [CKRecord.ID] = []
        lock.withLock {
            for id in conflictIDs {
                guard let serverRecord = serverRecords[id], let localRecord = localByID[id] else { continue }
                for key in localRecord.allKeys() { serverRecord[key] = localRecord[key] }
                pendingRecordsByID[id] = serverRecord
                resolvedIDs.append(id)
            }
        }
        Log.sync.info(
            "CloudKit conflict resolution prepared \(resolvedIDs.count, privacy: .public) of \(conflictIDs.count, privacy: .public) retries"
        )
        let fullyResolved = resolvedIDs.count == conflictIDs.count
        return (resolvedIDs, fullyResolved && (partial.isEmpty || allConflicts))
    }

    private func partialErrors(in rootError: NSError) -> [(Any, NSError)] {
        var results: [(Any, NSError)] = []
        var visited = Set<ObjectIdentifier>()

        func collect(_ error: NSError) {
            let identity = ObjectIdentifier(error)
            guard visited.insert(identity).inserted else { return }

            let candidates = [
                error.userInfo[CKPartialErrorsByItemIDKey],
                error.userInfo["CKPartialErrors"]
            ]
            for candidate in candidates {
                guard let dictionary = candidate as? NSDictionary else { continue }
                for (key, value) in dictionary {
                    if let nested = value as? NSError {
                        results.append((key, nested))
                    }
                }
                if !results.isEmpty { break }
            }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                collect(underlying)
            }
        }

        collect(rootError)
        return results
    }

    func enqueueSession(_ session: SyncedSoundCloudSession) async throws {
        guard let container = resolvedContainer() else { return }
        let database = container.privateCloudDatabase

        do {
            _ = try await database.deleteRecord(withID: CloudSyncMapping.sessionRecordID)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
        }

        let record = CloudSyncMapping.record(for: session)
        _ = try await database.save(record)
    }

    func deleteSession() async throws {
        guard let container = resolvedContainer() else { return }
        do {
            _ = try await container.privateCloudDatabase.deleteRecord(withID: CloudSyncMapping.sessionRecordID)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
        }
    }

    func fetchCurrentSession() async throws -> SyncedSoundCloudSession? {
        guard let container = resolvedContainer() else { return nil }
        do {
            let record = try await container.privateCloudDatabase.record(
                for: CloudSyncMapping.sessionRecordID
            )
            return CloudSyncMapping.session(from: record)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    func fetchSettingsRecords(named names: [String]) async throws -> [SettingsSyncRecord] {
        guard let container = resolvedContainer(), !names.isEmpty else { return [] }
        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: CloudSyncZone.companion) }
        var records: [SettingsSyncRecord] = []
        for start in stride(from: 0, to: ids.count, by: 200) {
            let batch = Array(ids[start..<min(start + 200, ids.count)])
            let fetched: [CKRecord.ID: Result<CKRecord, any Error>]
            do {
                fetched = try await container.privateCloudDatabase.records(for: batch)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                continue
            }
            for result in fetched.values {
                if case .success(let record) = result, let settings = CloudSyncMapping.settingsRecord(from: record) {
                    records.append(settings)
                }
            }
        }
        return records
    }

    func swapLibraryLease(_ proposal: LibraryChunk, now: Date = Date()) async throws -> (saved: Bool, current: LibraryChunk?) {
        guard let container = resolvedContainer(),
              let lease = proposal.lease,
              let local = CloudSyncMapping.record(for: proposal) else { return (false, nil) }
        let database = container.privateCloudDatabase
        let server: CKRecord?
        do {
            server = try await database.record(for: local.recordID)
        } catch let error as CKError where error.code == .unknownItem {
            server = nil
        }
        let current = server.flatMap(CloudSyncMapping.libraryChunk(from:))
        guard LibraryBackfillElection.mayReplace(current?.lease, with: lease, now: now) else { return (false, current) }
        let record = server ?? local
        if let server {
            for key in local.allKeys() { server[key] = local[key] }
        }
        do {
            let results = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            if case .failure(let error)? = results.saveResults[record.recordID] { throw error }
            return (true, proposal)
        } catch let error as CKError where error.code == .serverRecordChanged {
            return (false, error.serverRecord.flatMap(CloudSyncMapping.libraryChunk(from:)))
        }
    }

    private var fetchInFlight: Task<Void, Error>?

    func fetchLatestChanges() async throws {
        let task: Task<Void, Error>? = lock.withLock {
            if let fetchInFlight { return fetchInFlight }
            guard let engine else { return nil }
            let started = Task.detached { try await engine.fetchChanges() }
            fetchInFlight = started
            return started
        }
        guard let task else { return }
        defer { lock.withLock { if fetchInFlight == task { fetchInFlight = nil } } }
        try await task.value
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            Self.saveStateSerialization(update.stateSerialization, defaultsKey: stateDefaultsKey)

        case .fetchedRecordZoneChanges(let changes):
            await route(modifications: changes.modifications.map(\.record))

        case .sentRecordZoneChanges(let sent):
            let libraryRejected = sent.failedRecordSaves.filter {
                $0.record.recordType == CloudSyncRecordType.libraryChunk && LibraryCloudAvailability.isSchemaRejection($0.error)
            }
            if !libraryRejected.isEmpty {
                LibraryCloudAvailability.noteRejected()
                let chunks = libraryRejected.compactMap { CloudSyncMapping.libraryChunk(from: $0.record) }
                await LibrarySyncEngine.shared.markCloudPending(chunks)
                Log.sync.info("iCloud library sync isn't available yet; keeping the library on this device")
            } else if sent.savedRecords.contains(where: { $0.recordType == CloudSyncRecordType.libraryChunk }) {
                LibraryCloudAvailability.noteAccepted()
            }
            var conflictsToRetry: [CKRecord.ID] = []
            lock.withLock {
                for saved in sent.savedRecords { pendingRecordsByID[saved.recordID] = nil }
                for failed in sent.failedRecordSaves {
                    let id = failed.record.recordID
                    if failed.error.code == .serverRecordChanged,
                       let serverRecord = failed.error.serverRecord {
                        for key in failed.record.allKeys() {
                            serverRecord[key] = failed.record[key]
                        }
                        pendingRecordsByID[id] = serverRecord
                        conflictsToRetry.append(id)
                    } else {
                        pendingRecordsByID[id] = nil
                    }
                }
            }
            if !conflictsToRetry.isEmpty {
                syncEngine.state.add(
                    pendingRecordZoneChanges: conflictsToRetry.map { .saveRecord($0) }
                )
                Log.sync.info("Retrying \(conflictsToRetry.count, privacy: .public) CloudKit conflicts with server change tags")
            }
            if !sent.failedRecordSaves.isEmpty {
                for failure in sent.failedRecordSaves {
                    guard failure.error.code != .serverRecordChanged else { continue }
                    if failure.record.recordType == CloudSyncRecordType.libraryChunk,
                       LibraryCloudAvailability.isSchemaRejection(failure.error) { continue }
                    Log.sync.error(
                        "record save failed for \(failure.record.recordID.recordName, privacy: .public): \(String(describing: failure.error), privacy: .public)"
                    )
                }
            }

        case .accountChange:
            Log.sync.info("iCloud account changed")

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }

        let snapshot = lock.withLock { pendingRecordsByID }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            snapshot[recordID]
        }
    }

    private func route(modifications: [CKRecord]) async {
        var cues: [CueSyncRecord] = []
        var dismissals: [CueDismissal] = []
        var analysisRows: [AnalysisSyncRecord] = []
        var sessions: [SyncedSoundCloudSession] = []
        var manifests: [DownloadManifestSyncRecord] = []
        var setlists: [SetlistSyncRecord] = []
        var companionDevices: [CompanionDeviceRecord] = []
        var settingsEntries: [SettingsSyncRecord] = []
        var prepRecords: [PrepSyncRecord] = []
        var libraryChunks: [LibraryChunk] = []

        for record in modifications {
            switch record.recordType {
            case CloudSyncRecordType.cue:
                if let cue = CloudSyncMapping.cue(from: record) { cues.append(cue) }
            case CloudSyncRecordType.cueDismissal:
                if let dismissal = CloudSyncMapping.dismissal(from: record) { dismissals.append(dismissal) }
            case CloudSyncRecordType.analysisRow:
                if let row = CloudSyncMapping.analysisRecord(from: record) { analysisRows.append(row) }
            case CloudSyncRecordType.session:
                if let session = CloudSyncMapping.session(from: record) { sessions.append(session) }
            case CloudSyncRecordType.downloadManifestEntry:
                if let entry = CloudSyncMapping.downloadManifestRecord(from: record) { manifests.append(entry) }
            case CloudSyncRecordType.setlistSnapshot:
                if let setlist = CloudSyncMapping.setlistRecord(from: record) { setlists.append(setlist) }
            case CloudSyncRecordType.companionDevice:
                if let device = CloudSyncMapping.companionDeviceRecord(from: record) { companionDevices.append(device) }
            case CloudSyncRecordType.settingsEntry:
                if let entry = CloudSyncMapping.settingsRecord(from: record) { settingsEntries.append(entry) }
            case CloudSyncRecordType.prepRecord:
                if let prep = CloudSyncMapping.prepRecord(from: record) { prepRecords.append(prep) }
            case CloudSyncRecordType.libraryChunk:
                if let chunk = CloudSyncMapping.libraryChunk(from: record) { libraryChunks.append(chunk) }
            default:
                break
            }
        }

        if !cues.isEmpty { await cueInbox.append(cues) }
        if !prepRecords.isEmpty { await prepInbox.append(prepRecords) }
        if !dismissals.isEmpty { await cueDismissalInbox.append(dismissals) }
        if !analysisRows.isEmpty { await analysisInbox.append(analysisRows) }
        if !sessions.isEmpty {
            await sessionInbox.append(sessions)
            await MainActor.run {
                SynchronizationCoordinator.shared.requestSessionSync()
            }
        }
        if !manifests.isEmpty { await downloadManifestInbox.append(manifests) }
        if !setlists.isEmpty { await setlistInbox.append(setlists) }
        if !companionDevices.isEmpty {
            await companionDeviceInbox.append(companionDevices)
            await MainActor.run {
                CompanionRegistry.shared.adopt(companionDevices)
            }
        }
        if !settingsEntries.isEmpty { await settingsInbox.append(settingsEntries) }
        if !libraryChunks.isEmpty { await libraryInbox.append(libraryChunks) }
    }

    private static func loadStateSerialization(defaultsKey: String) -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private static func saveStateSerialization(_ serialization: CKSyncEngine.State.Serialization, defaultsKey: String) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

struct CloudKitCueSyncTransport: CueSyncTransport {
    let transportId = "cloudkit"
    let controller: CloudSyncEngineController

    func isReady() async -> Bool { await controller.isReadyToSync() }

    func offer(cues: [CueSyncRecord], dismissals: [CueDismissal]) async throws {
        let records = cues.map(CloudSyncMapping.record(for:)) + dismissals.map(CloudSyncMapping.record(for:))
        guard !records.isEmpty else { return }
        try await controller.enqueue(records)
    }

    func fetch(since cursor: CueSyncCursor?) async throws -> (cues: [CueSyncRecord], dismissals: [CueDismissal], cursor: CueSyncCursor?) {
        try await controller.fetchLatestChanges()
        let cues = await controller.cueInbox.drain()
        let dismissals = await controller.cueDismissalInbox.drain()
        return (cues, dismissals, cursor)
    }
}

struct CloudKitAnalysisSyncTransport: AnalysisSyncTransport {
    let transportId = "cloudkit"
    let controller: CloudSyncEngineController

    func isReady() async -> Bool { await controller.isReadyToSync() }

    func offer(_ records: [AnalysisSyncRecord]) async throws {
        guard !records.isEmpty else { return }
        try await controller.enqueue(records.map(CloudSyncMapping.record(for:)))
    }

    func fetch(since cursor: AnalysisSyncCursor?) async throws -> (records: [AnalysisSyncRecord], cursor: AnalysisSyncCursor?) {
        try await controller.fetchLatestChanges()
        return (await controller.analysisInbox.drain(), cursor)
    }
}

struct CloudKitSessionSyncTransport: SessionSyncTransport {
    let transportId = "cloudkit"
    let controller: CloudSyncEngineController

    func isReady() async -> Bool { await controller.isReadyToSync() }

    func push(_ session: SyncedSoundCloudSession) async throws {
        try await controller.enqueueSession(session)
    }

    func pull() async throws -> SyncedSoundCloudSession? {
        try await controller.fetchLatestChanges()
        _ = await controller.sessionInbox.drain()
        return try await controller.fetchCurrentSession()
    }
}

struct CloudKitDownloadManifestSyncTransport: DownloadManifestSyncTransport {
    let transportId = "cloudkit"
    let controller: CloudSyncEngineController

    func isReady() async -> Bool { await controller.isReadyToSync() }

    func offer(_ records: [DownloadManifestSyncRecord]) async throws {
        guard !records.isEmpty else { return }
        try await controller.enqueue(records.map(CloudSyncMapping.record(for:)))
    }

    func fetch(since cursor: DownloadManifestSyncCursor?) async throws -> (records: [DownloadManifestSyncRecord], cursor: DownloadManifestSyncCursor?) {
        try await controller.fetchLatestChanges()
        return (await controller.downloadManifestInbox.drain(), cursor)
    }
}

struct CloudKitSetlistSyncTransport: Sendable {
    let controller: CloudSyncEngineController

    func isReady() async -> Bool { await controller.isReadyToSync() }

    func offer(_ records: [SetlistSyncRecord]) async throws {
        guard !records.isEmpty else { return }
        try await controller.enqueue(records.map(CloudSyncMapping.record(for:)))
    }

    func fetch() async throws -> [SetlistSyncRecord] {
        try await controller.fetchLatestChanges()
        return await controller.setlistInbox.drain()
    }
}

struct CloudKitCompanionSyncTransport: Sendable {
    let controller: CloudSyncEngineController

    func isReady() async -> Bool { await controller.isReadyToSync() }

    func offer(_ devices: [CompanionDeviceRecord]) async throws {
        guard !devices.isEmpty else { return }
        try await controller.enqueue(devices.map(CloudSyncMapping.record(for:)))
    }

    func fetch() async throws -> [CompanionDeviceRecord] {
        try await controller.fetchLatestChanges()
        return await controller.companionDeviceInbox.drain()
    }
}

struct CloudKitSettingsSyncTransport: Sendable {
    let controller: CloudSyncEngineController

    func isReady() async -> Bool { await controller.isReadyToSync() }

    func offer(_ records: [SettingsSyncRecord]) async throws {
        guard !records.isEmpty else { return }
        try await controller.enqueue(records.map(CloudSyncMapping.record(for:)))
    }

    func fetch() async throws -> [SettingsSyncRecord] {
        try await controller.fetchLatestChanges()
        return await controller.settingsInbox.drain()
    }
}

@MainActor
final class SynchronizationCoordinator: SetlistSynchronizationReceiving, SettingsSynchronizationReceiving, CueSynchronizationReceiving {
    static let shared = SynchronizationCoordinator(
        controller: .shared,
        gateway: .shared,
        scheduler: .shared,
        cueStore: .shared,
        likesImporter: .shared,
        likes: .shared
    )

    private let controller: CloudSyncEngineController
    private let gateway: SynchronizationGateway
    private let scheduler: WorkScheduler
    private let cueStore: CueStore
    private let likesImporter: LikesPeerImportCoordinator
    private let likes: LikesSyncEngine
    private var isRunning = false
    private var settingsNeedFullFetch = true
    private var settingsRestoredAccountTags: Set<String> = []
    private var nearbySinks: [String: @MainActor (SynchronizationDomain) -> Void] = [:]
    private weak var sessionSource: (any SoundCloudSessionSyncSource)?

    private enum DefaultsKey {
        static let cueCursor = "red.forbes.sounding.cloudsync.cueCursor"
        static let prepPushedThrough = "red.forbes.sounding.cloudsync.prepPushedThrough"
        static let analysisCursor = "red.forbes.sounding.cloudsync.analysisCursor"
        static let downloadManifestCursor = "red.forbes.sounding.cloudsync.downloadManifestCursor"
        static let setlistLastPush = "red.forbes.sounding.cloudsync.setlistLastPush"
        static let settingsLastPush = "red.forbes.sounding.cloudsync.settingsLastPush"
    }

    init(
        controller: CloudSyncEngineController,
        gateway: SynchronizationGateway,
        scheduler: WorkScheduler,
        cueStore: CueStore,
        likesImporter: LikesPeerImportCoordinator,
        likes: LikesSyncEngine
    ) {
        self.controller = controller
        self.gateway = gateway
        self.scheduler = scheduler
        self.cueStore = cueStore
        self.likesImporter = likesImporter
        self.likes = likes
    }

    func start() {
        controller.start()
        SetlistIntelligenceStore.shared.connectSynchronization(to: self)
        SettingsStore.shared.connectSynchronization(to: self)
        Task { await cueStore.connectSynchronization(to: self) }
        requestRefresh()
        scheduler.registerPeriodic(
            id: "synchronization.refresh",
            scope: "synchronization",
            initialDelay: .seconds(30),
            interval: .seconds(30)
        ) { [weak self] in
            self?.requestRefresh()
        }
    }

    func configureSessionSource(_ source: (any SoundCloudSessionSyncSource)?) {
        sessionSource = source
    }

    func requestRefresh() {
        requestSessionSync()
        requestSetlistSync()
        requestSettingsSync()
        requestCueSync()
        requestLibrarySync()
        pushCompanionDevice()
    }

    func requestLibrarySync() {
        gateway.submit(lane: .cloud, key: "library") { [weak self] in
            await self?.performLibraryRelay()
        }
    }

    private func performLibraryRelay() async {
        let controller = controller
        let engine = LibrarySyncEngine.shared
        guard await controller.isReadyToSync() else {
            engine.noteLeaseChannelClosed()
            return
        }
        do {
            try await controller.fetchLatestChanges()
            let incoming = await controller.libraryInbox.drain()
            if !incoming.isEmpty, let account = SoundCloudCredentialSource.shared.currentUser?.id {
                await engine.adopt(incoming.filter { $0.account == account }, expectedAccount: account)
            }
            guard !LibraryCloudAvailability.isPaused() else {
                engine.noteLeaseChannelClosed()
                return
            }
            await runLibraryLeaseRound()
            let outgoing = await engine.cloudChunks(limit: 40)
            if !outgoing.isEmpty {
                try await controller.enqueue(outgoing.compactMap(CloudSyncMapping.record(for:)))
                await engine.markCloudExported(outgoing)
            }
            if let manifest = await engine.cloudManifestIfDue(), let record = CloudSyncMapping.record(for: manifest) {
                try await controller.enqueue([record])
                engine.noteManifestExported()
            }
        } catch {
            Log.sync.error("library relay round failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func runLibraryLeaseRound() async {
        let engine = LibrarySyncEngine.shared
        let registry = CompanionRegistry.shared
        let local = registry.localRecord()
        guard let account = local.accountId else { return }
        let me = LibraryBackfillCandidate(
            id: local.deviceId,
            deviceClass: local.deviceClass,
            isOnPower: local.conditions.isPluggedIn,
            lastSeen: Date()
        )
        let roster = registry.peers
            .filter { $0.accountId == account }
            .map { peer in
                LibraryBackfillCandidate(
                    id: peer.deviceId,
                    deviceClass: peer.deviceClass,
                    isOnPower: peer.conditions.isPluggedIn,
                    lastSeen: Date(timeIntervalSince1970: Double(peer.lastSeenAtMillis) / 1000)
                )
            }
        guard let proposal = engine.leaseRound(local: me, roster: roster) else { return }
        do {
            let result = try await controller.swapLibraryLease(proposal)
            engine.leaseResult(proposal: proposal, saved: result.saved, server: result.current)
        } catch let error as CKError where LibraryCloudAvailability.isSchemaRejection(error) {
            engine.leaseRoundFailed()
            LibraryCloudAvailability.noteRejected()
        } catch {
            engine.leaseRoundFailed()
            Log.sync.error("library lease round failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func pushCompanionDevice() {
        let transport = CloudKitCompanionSyncTransport(controller: controller)
        gateway.submit(lane: .cloud, key: SynchronizationDomain.companionRoster.rawValue) {
            guard await transport.isReady() else { return }
            let record = CompanionRegistry.shared.registerLocal()
            try? await transport.offer([record])
        }
    }

    func registerNearbySink(
        id: String,
        _ sink: @escaping @MainActor (SynchronizationDomain) -> Void
    ) {
        nearbySinks[id] = sink
    }

    func unregisterNearbySink(id: String) {
        nearbySinks[id] = nil
        gateway.cancel(keyPrefix: id)
    }

    func noteLocalChange(_ domain: SynchronizationDomain) {
        switch domain {
        case .session: requestSessionSync()
        case .cues: requestCueSync()
        case .setlists: requestSetlistSync()
        case .settings: requestSettingsSync()
        case .analysis, .downloadManifest, .companionRoster:
            break
        }
        for sink in nearbySinks.values { sink(domain) }
    }

    func noteSetlistMutation() { noteLocalChange(.setlists) }
    func noteSettingsMutation() { noteLocalChange(.settings) }

    func noteSettingsNeedFullFetch() {
        settingsNeedFullFetch = true
        settingsRestoredAccountTags = []
        requestSettingsSync()
    }
    func noteCueMutation() { noteLocalChange(.cues) }

    func adoptNearbyCueState(_ body: CueSyncBody) async {
        _ = await cueStore.adopt(body.cues)
        _ = await cueStore.adoptDismissals(body.dismissals)
    }

    func nearbyCueBatch(changedSince cursor: Int64, limit: Int) async -> (cues: [CueSyncRecord], dismissals: [CueDismissal]) {
        let cues = await cueStore.syncRecords(changedSince: cursor, limit: limit)
        let dismissals = await cueStore.dismissalRecords(changedSince: cursor, limit: limit)
        return (cues, dismissals)
    }

    func setNearbyHotCue(trackID: String, index: Int, positionMillis: Int64) async {
        await cueStore.setHotCue(trackId: trackID, index: index, positionMillis: positionMillis)
    }

    @discardableResult
    func adoptNearbyLikes(_ body: LikesPeerBody, expectedAccountID: String) async -> Int {
        let adopted = await likesImporter.adopt(body, expectedAccountId: expectedAccountID)
        await likes.didAdoptPeerLikes()
        return adopted
    }

    func requestSetlistSync() {
        gateway.submit(lane: .cloud, key: SynchronizationDomain.setlists.rawValue) { [weak self] in
            await self?.performSetlistRelay()
        }
    }

    func requestSettingsSync() {
        gateway.submit(lane: .cloud, key: SynchronizationDomain.settings.rawValue) { [weak self] in
            await self?.performSettingsRelay()
        }
    }

    func requestCueSync() {
        gateway.submit(lane: .cloud, key: SynchronizationDomain.cues.rawValue) { [weak self] in
            guard let self else { return }
            await self.performCueRelay(store: self.cueStore)
        }
    }

    func latestSyncedSession() async -> SyncedSoundCloudSession? {
        let transport = CloudKitSessionSyncTransport(controller: controller)
        guard await transport.isReady() else { return nil }
        do {
            return try await controller.fetchCurrentSession()
        } catch {
            Log.sync.error("latest synced session fetch failed: \(type(of: error), privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func clearSyncedSession() async -> Bool {
        do {
            try await controller.deleteSession()
            return true
        } catch {
            Log.sync.error("synced session delete failed: \(type(of: error), privacy: .public)")
            return false
        }
    }

    func requestSessionSync() {
        gateway.submit(
            lane: .cloud,
            key: SynchronizationDomain.session.rawValue,
            urgency: .immediate
        ) { [weak self] in
            await self?.performSessionRelay()
        }
    }

    func runOnce(
        analysisStore: any AnalysisSyncStore,
        downloadManifestExportSource: (any DownloadManifestExportSource)?
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        requestCueSync()
        gateway.submit(lane: .cloud, key: SynchronizationDomain.analysis.rawValue) { [weak self] in
            await self?.runAnalysisRelay(store: analysisStore)
        }
        requestSessionSync()
        requestSetlistSync()
        requestSettingsSync()
        pushCompanionDevice()
        if let downloadManifestExportSource {
            gateway.submit(lane: .cloud, key: SynchronizationDomain.downloadManifest.rawValue) { [weak self] in
                await self?.runDownloadManifestRelay(exportSource: downloadManifestExportSource)
            }
        }
        await gateway.flush(.cloud)
    }

    private func performCueRelay(store: any CueSyncStore) async {
        let cursor = Self.loadCursor(CueSyncCursor.self, key: DefaultsKey.cueCursor)
        let relay = CueSyncRelay(store: store, transport: CloudKitCueSyncTransport(controller: controller))
        do {
            let result = try await relay.runOnce(since: cursor)
            Self.saveCursor(result.cursor, key: DefaultsKey.cueCursor)
        } catch {
            Log.sync.error("cue relay round failed: \(String(describing: error), privacy: .public)")
        }
        await performPrepRelay()
    }

    private func performPrepRelay() async {
        let pushed = (UserDefaults.standard.object(forKey: DefaultsKey.prepPushedThrough) as? NSNumber)?.int64Value ?? 0
        let relay = PrepSyncRelay(store: cueStore, transport: CloudKitPrepSyncTransport(controller: controller))
        do {
            let result = try await relay.runOnce(pushedThroughMillis: pushed)
            UserDefaults.standard.set(NSNumber(value: result.pushedThroughMillis), forKey: DefaultsKey.prepPushedThrough)
        } catch {
            Log.sync.error("prep relay round failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func runAnalysisRelay(store: any AnalysisSyncStore) async {
        let cursor = Self.loadCursor(AnalysisSyncCursor.self, key: DefaultsKey.analysisCursor)
        let relay = AnalysisSyncRelay(store: store, transport: CloudKitAnalysisSyncTransport(controller: controller))
        do {
            let result = try await relay.runOnce(since: cursor)
            Self.saveCursor(result.cursor, key: DefaultsKey.analysisCursor)
        } catch {
            Log.sync.error("analysis relay round failed: \(String(describing: error), privacy: .public)")
        }
        AutomaticAnalysisScheduler.shared.noteAnalysisSyncSettled()
    }

    private func performSessionRelay() async {
        guard let source = sessionSource else { return }
        let relay = SessionSyncRelay(source: source, transport: CloudKitSessionSyncTransport(controller: controller))
        do {
            _ = try await relay.runOnce()
        } catch {
            Log.sync.error("session relay round failed: \(type(of: error), privacy: .public)")
        }
    }

    private func performSetlistRelay() async {
        let transport = CloudKitSetlistSyncTransport(controller: controller)
        guard await transport.isReady() else { return }
        do {
            let incoming = try await transport.fetch()
            let incomingSetlists = incoming.compactMap(\.setlist)
            if !incomingSetlists.isEmpty {
                SetlistIntelligenceStore.shared.adoptSynced(incomingSetlists)
            }

            let deviceId = DownloadManifestDeviceIdentity.deviceId()
            let lastPush = (UserDefaults.standard.dictionary(
                forKey: DefaultsKey.setlistLastPush
            ) as? [String: Double]) ?? [:]
            let snapshots = SetlistIntelligenceStore.shared.snapshotsForSync()
            let due = snapshots.filter { snapshot in
                snapshot.updatedAt.timeIntervalSince1970 > (lastPush[snapshot.trackId] ?? 0) + 0.001
            }
            let records = due.compactMap { SetlistSyncRecord(setlist: $0, deviceId: deviceId) }
            guard !records.isEmpty else { return }
            try await transport.offer(records)

            var updatedPush = lastPush
            for snapshot in due {
                updatedPush[snapshot.trackId] = snapshot.updatedAt.timeIntervalSince1970
            }
            UserDefaults.standard.set(updatedPush, forKey: DefaultsKey.setlistLastPush)
        } catch {
            Log.sync.error("setlist relay round failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func performSettingsRelay() async {
        let transport = CloudKitSettingsSyncTransport(controller: controller)
        guard await transport.isReady() else { return }
        let store = SettingsStore.shared
        do {
            var incoming = try await transport.fetch()
            guard store.syncSettingsWithICloud else { return }
            store.preferences.scan()
            let deviceId = DownloadManifestDeviceIdentity.deviceId()
            let accountTag = store.activeAccountTag
            let restoresAccount = accountTag.map { !settingsRestoredAccountTags.contains($0) } ?? false
            let fullFetch = settingsNeedFullFetch || restoresAccount
            if fullFetch {
                let deviceIds = Set([deviceId] + CompanionRegistry.shared.devices.map(\.deviceId))
                var names = deviceIds.map { SettingsSyncRecord.recordName(deviceId: $0, accountTag: nil) }
                if let accountTag {
                    names += deviceIds.map { SettingsSyncRecord.recordName(deviceId: $0, accountTag: accountTag) }
                }
                incoming += try await controller.fetchSettingsRecords(named: names.sorted())
            }
            for record in incoming {
                store.merge(record.payload)
            }
            if fullFetch {
                settingsNeedFullFetch = false
                UserDefaults.standard.removeObject(forKey: DefaultsKey.settingsLastPush)
                if let accountTag {
                    settingsRestoredAccountTags.insert(accountTag)
                    UserDefaults.standard.removeObject(forKey: Self.settingsLastPushKey(accountTag: accountTag))
                }
            }

            var outgoing: [(record: SettingsSyncRecord, lastPushKey: String)] = []
            if let snapshot = store.exportSyncSnapshot(scope: .appleID) {
                outgoing += Self.dueSettingsRecord(
                    snapshot, deviceId: deviceId, writerId: store.writerIdForSync,
                    lastPushKey: DefaultsKey.settingsLastPush
                )
            }
            if let snapshot = store.exportSyncSnapshot(scope: .account),
               let tag = snapshot.accountTag, settingsRestoredAccountTags.contains(tag) {
                outgoing += Self.dueSettingsRecord(
                    snapshot, deviceId: deviceId, writerId: store.writerIdForSync,
                    lastPushKey: Self.settingsLastPushKey(accountTag: tag)
                )
            }
            guard !outgoing.isEmpty else { return }
            try await transport.offer(outgoing.map { $0.record })
            for item in outgoing {
                UserDefaults.standard.set(item.record.updatedAtMillis, forKey: item.lastPushKey)
            }
        } catch {
            Log.sync.error("settings relay round failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func settingsLastPushKey(accountTag: String) -> String {
        "\(DefaultsKey.settingsLastPush).account.\(accountTag)"
    }

    private static func dueSettingsRecord(
        _ snapshot: SettingsSyncSnapshot,
        deviceId: String,
        writerId: String,
        lastPushKey: String
    ) -> [(record: SettingsSyncRecord, lastPushKey: String)] {
        let lastPushMillis = (UserDefaults.standard.object(forKey: lastPushKey) as? NSNumber)?.int64Value ?? 0
        guard snapshot.newestUpdateMillis > lastPushMillis else { return [] }
        let record = SettingsSyncRecord(
            deviceId: deviceId,
            payload: snapshot.payload,
            writerId: writerId,
            updatedAtMillis: snapshot.newestUpdateMillis,
            accountTag: snapshot.accountTag
        )
        return [(record, lastPushKey)]
    }

    private func runDownloadManifestRelay(exportSource: any DownloadManifestExportSource) async {
        let cursor = Self.loadCursor(DownloadManifestSyncCursor.self, key: DefaultsKey.downloadManifestCursor)
        let relay = DownloadManifestSyncRelay(
            exportSource: exportSource,
            importStore: RemoteDownloadManifestStore.shared,
            transport: CloudKitDownloadManifestSyncTransport(controller: controller)
        )
        do {
            let result = try await relay.runOnce(since: cursor)
            Self.saveCursor(result.cursor, key: DefaultsKey.downloadManifestCursor)
        } catch {
            Log.sync.error("download manifest relay round failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func loadCursor<C: Decodable>(_ type: C.Type, key: String) -> C? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(C.self, from: data)
    }

    private static func saveCursor<C: Encodable>(_ cursor: C?, key: String) {
        guard let cursor, let data = try? JSONEncoder().encode(cursor) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension SoundCloudSessionRenewal.Source {
    @MainActor static func synced(
        coordinator: SynchronizationCoordinator = .shared,
        localSession: @escaping @MainActor () -> SyncedSoundCloudSession?
    ) -> Self {
        Self(kind: .synced) { phase in
            let wait: Duration = phase == .beforeRefresh ? .seconds(4) : .seconds(8)
            guard let remote = await SoundCloudSessionRenewalTimeout.value(within: wait, {
                await coordinator.latestSyncedSession()
            }) else { return nil }
            if phase == .beforeRefresh,
               !SessionSyncPolicy.remoteWins(local: localSession(), remote: remote) {
                return nil
            }
            let session = StoredSession(
                oauthToken: remote.oauthToken,
                refreshToken: remote.refreshToken,
                clientId: remote.clientId,
                expiresAt: remote.expiresAtMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            )
            let digest = SessionSyncBookkeeping.digest(
                oauthToken: remote.oauthToken,
                refreshToken: remote.refreshToken,
                clientId: remote.clientId,
                expiresAtMillis: remote.expiresAtMillis
            )
            return SoundCloudSessionRenewal.Candidate(session: session) {
                SessionSyncBookkeeping.adoptForeignProvenance(updatedAtMillis: remote.updatedAtMillis, digest: digest)
            }
        }
    }
}

enum LibraryCloudAvailability {
    static let retryInterval: TimeInterval = 6 * 60 * 60
    private static let retryKey = "red.forbes.sounding.library.cloudRetryAt"

    static func isPaused(now: Date = Date()) -> Bool {
        let stored = UserDefaults.standard.double(forKey: retryKey)
        return stored > now.timeIntervalSince1970
    }

    static func noteRejected(now: Date = Date()) {
        UserDefaults.standard.set(now.addingTimeInterval(retryInterval).timeIntervalSince1970, forKey: retryKey)
    }

    static func noteAccepted() {
        UserDefaults.standard.removeObject(forKey: retryKey)
    }

    static func isSchemaRejection(_ error: CKError) -> Bool {
        switch error.code {
        case .invalidArguments, .serverRejectedRequest, .badContainer, .permissionFailure:
            return true
        default:
            return false
        }
    }
}
