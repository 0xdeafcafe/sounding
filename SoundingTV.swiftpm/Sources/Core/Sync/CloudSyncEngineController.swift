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
    let workshopClaimInbox = CloudSyncInbox<WorkshopClaim>()

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
                return .unavailable("This build cannot access the SoundingCloud iCloud container. Check its iCloud entitlement and provisioning profile.")
            }
            return .unavailable("Cloud sync has not started. Quit and reopen SoundingCloud, then try again.")
        }
        guard let container = resolvedContainer() else {
            return .unavailable("This build cannot access the SoundingCloud iCloud container. Check its iCloud entitlement and provisioning profile.")
        }

        do {
            switch try await container.accountStatus() {
            case .available:
                // Account status can look healthy while the private database
                // is inaccessible. A lightweight read makes the status UI
                // report a real CloudKit round trip instead of a timer tick.
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
            try await currentEngine.sendChanges()
        } catch {
            let resolution = await resolveServerConflicts(in: error as NSError, localRecords: preparedRecords)
            guard !resolution.recordIDs.isEmpty else { throw error }
            currentEngine.state.add(
                pendingRecordZoneChanges: resolution.recordIDs.map { .saveRecord($0) }
            )
            Log.sync.info("Retrying \(resolution.recordIDs.count, privacy: .public) CloudKit conflicts immediately with server change tags")
            try await currentEngine.sendChanges()
            if !resolution.allFailuresWereConflicts { throw error }
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
                // The first send also creates SoundingCloud's custom zones.
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
        // Some CKSyncEngine builds surface only a textual CKPartialErrors
        // description across the async bridge. In that case, recover the
        // current system fields directly instead of abandoning the round.
        if conflictIDs.isEmpty {
            conflictIDs = localRecords.map(\.recordID)
            allConflicts = false
        }
        Log.sync.info(
            "CloudKit partial failure: \(partial.count, privacy: .public) items, \(conflictIDs.count, privacy: .public) server conflicts, \(serverRecords.count, privacy: .public) embedded server records"
        )

        let missing = conflictIDs.filter { serverRecords[$0] == nil }
        if !missing.isEmpty, let container = resolvedContainer() {
            // CKSyncEngine's partial error sometimes carries only a server
            // etag, not the full serverRecord. Fetch in bounded batches so we
            // can still rebuild updates with valid system fields.
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

        // Some legacy session records contain `oauthToken` as both a plain
        // and encrypted field. Merely fetching one of those records raises an
        // Objective-C CKException that Swift cannot catch. Delete the fixed-ID
        // legacy record without decoding it, then write the encrypted-only
        // replacement.
        do {
            _ = try await database.deleteRecord(withID: CloudSyncMapping.sessionRecordID)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            // Nothing to migrate.
        }

        let record = CloudSyncMapping.record(for: session)
        _ = try await database.save(record)
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

    func fetchLatestChanges() async throws {
        let currentEngine = lock.withLock { engine }
        guard let currentEngine else { return }
        try await currentEngine.fetchChanges()
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            Self.saveStateSerialization(update.stateSerialization, defaultsKey: stateDefaultsKey)

        case .fetchedRecordZoneChanges(let changes):
            await route(modifications: changes.modifications.map(\.record))

        case .sentRecordZoneChanges(let sent):
            var conflictsToRetry: [CKRecord.ID] = []
            lock.withLock {
                for saved in sent.savedRecords { pendingRecordsByID[saved.recordID] = nil }
                for failed in sent.failedRecordSaves {
                    let id = failed.record.recordID
                    if failed.error.code == .serverRecordChanged,
                       let serverRecord = failed.error.serverRecord {
                        // Reapply the local fields to the server instance so
                        // the retry carries CloudKit's current change tag.
                        // Reconstructing a fixed-ID CKRecord makes every
                        // existing row look like a conflicting insert.
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
        var workshopClaims: [WorkshopClaim] = []

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
            case CloudSyncRecordType.workshopClaim:
                if let claim = CloudSyncMapping.workshopClaimRecord(from: record) { workshopClaims.append(claim) }
            default:
                break
            }
        }

        if !cues.isEmpty { await cueInbox.append(cues) }
        if !dismissals.isEmpty { await cueDismissalInbox.append(dismissals) }
        if !analysisRows.isEmpty { await analysisInbox.append(analysisRows) }
        if !sessions.isEmpty {
            await sessionInbox.append(sessions)
            await MainActor.run {
                CloudSyncCoordinator.shared.requestSessionSync()
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
        if !workshopClaims.isEmpty {
            await workshopClaimInbox.append(workshopClaims)
            await MainActor.run {
                WorkshopPool.shared.adopt(workshopClaims)
            }
        }
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

struct CloudKitWorkshopSyncTransport: Sendable {
    let controller: CloudSyncEngineController

    func isReady() async -> Bool { await controller.isReadyToSync() }

    func offer(_ claims: [WorkshopClaim]) async throws {
        guard !claims.isEmpty else { return }
        try await controller.enqueue(claims.map(CloudSyncMapping.record(for:)))
    }

    func fetch() async throws -> [WorkshopClaim] {
        try await controller.fetchLatestChanges()
        return await controller.workshopClaimInbox.drain()
    }
}

@MainActor
final class CloudSyncCoordinator {
    static let shared = CloudSyncCoordinator()

    private let controller = CloudSyncEngineController.shared
    private var isRunning = false
    private var sessionRelayTask: Task<Void, Never>?
    private var sessionRelayNeedsAnotherPass = false
    private var periodicSessionTask: Task<Void, Never>?
    private var setlistRelayTask: Task<Void, Never>?
    private var setlistRelayNeedsAnotherPass = false
    private var settingsRelayTask: Task<Void, Never>?
    private var settingsRelayNeedsAnotherPass = false
    private var cueRelayTask: Task<Void, Never>?
    private var cueRelayNeedsAnotherPass = false

    private enum DefaultsKey {
        static let cueCursor = "red.forbes.sounding.cloudsync.cueCursor"
        static let analysisCursor = "red.forbes.sounding.cloudsync.analysisCursor"
        static let downloadManifestCursor = "red.forbes.sounding.cloudsync.downloadManifestCursor"
        static let setlistLastPush = "red.forbes.sounding.cloudsync.setlistLastPush"
        static let settingsLastPush = "red.forbes.sounding.cloudsync.settingsLastPush"
    }

    private init() {}

    func start() {
        controller.start()
        SetlistSyncTarget.requestSync = { CloudSyncCoordinator.shared.requestSetlistSync() }
        CueSyncTarget.requestCloudSync = { CloudSyncCoordinator.shared.requestCueSync() }
        SettingsSyncTarget.requestSync = { CloudSyncCoordinator.shared.requestSettingsSync() }
        requestSessionSync()
        requestSetlistSync()
        requestSettingsSync()
        requestCueSync()
        pushCompanionDevice()
        guard periodicSessionTask == nil else { return }
        periodicSessionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard let self else { return }
                self.requestSessionSync()
                self.requestSetlistSync()
                self.requestSettingsSync()
                self.requestCueSync()
                self.pushCompanionDevice()
            }
        }
    }

    private func pushCompanionDevice() {
        let transport = CloudKitCompanionSyncTransport(controller: controller)
        Task.detached {
            guard await transport.isReady() else { return }
            let record = await CompanionRegistry.shared.registerLocal()
            try? await transport.offer([record])
        }
    }

    /// Debounces the per-probe persistence of a long set into small CloudKit
    /// batches. Pull happens before push so Mac/TV can skip work another device
    /// has already completed.
    func requestSetlistSync() {
        setlistRelayNeedsAnotherPass = true
        guard setlistRelayTask == nil else { return }
        // Intentionally detached: replacing this with an actor-inheriting Task
        // reintroduces the concurrency runtime panic this relay avoids.
        setlistRelayTask = Task.detached {
            await CloudSyncCoordinator.runSetlistRelay()
        }
    }

    func requestSettingsSync() {
        settingsRelayNeedsAnotherPass = true
        guard settingsRelayTask == nil else { return }
        settingsRelayTask = Task.detached {
            await CloudSyncCoordinator.runSettingsRelay()
        }
    }

    func requestCueSync() {
        cueRelayNeedsAnotherPass = true
        guard cueRelayTask == nil else { return }
        cueRelayTask = Task.detached {
            await CloudSyncCoordinator.runCueRelay()
        }
    }

    /// Coalesces CloudKit pushes, app lifecycle nudges, and local credential
    /// changes into a single serial relay. This is intentionally public to the
    /// app targets: signing in, refreshing, or signing out should not wait for
    /// another launch before the other open devices notice.
    func requestSessionSync() {
        sessionRelayNeedsAnotherPass = true
        guard sessionRelayTask == nil else { return }
        sessionRelayTask = Task.detached {
            await CloudSyncCoordinator.runSessionRelay()
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
        await cueRelayTask?.value
        await runAnalysisRelay(store: analysisStore)
        requestSessionSync()
        await sessionRelayTask?.value
        requestSetlistSync()
        await setlistRelayTask?.value
        requestSettingsSync()
        await settingsRelayTask?.value
        pushCompanionDevice()
        if let downloadManifestExportSource {
            await runDownloadManifestRelay(exportSource: downloadManifestExportSource)
        }
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
    }

    private func performSessionRelay() async {
        guard let source = SessionSyncTarget.source else { return }
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
        do {
            let incoming = try await transport.fetch()
            let deviceId = DownloadManifestDeviceIdentity.deviceId()
            for record in incoming where record.deviceId != deviceId {
                SettingsStore.shared.merge(record.payload)
            }

            let lastPushMillis = UserDefaults.standard.object(forKey: DefaultsKey.settingsLastPush) as? Int64 ?? 0
            guard let payload = SettingsStore.shared.exportSyncPayload() else { return }
            guard let decodedPayload = try? JSONDecoder().decode(SettingsSyncPayload.self, from: payload) else { return }
            let newestUpdateMillis = decodedPayload.entries.map(\.updatedAtMillis).max() ?? 0
            guard newestUpdateMillis > lastPushMillis else { return }

            let record = SettingsSyncRecord(
                deviceId: deviceId,
                payload: payload,
                writerId: SettingsStore.shared.writerIdForSync,
                updatedAtMillis: newestUpdateMillis
            )
            try await transport.offer([record])
            UserDefaults.standard.set(newestUpdateMillis, forKey: DefaultsKey.settingsLastPush)
        } catch {
            Log.sync.error("settings relay round failed: \(String(describing: error), privacy: .public)")
        }
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

    private static func runSessionRelay() async {
        let coordinator = CloudSyncCoordinator.shared
        await Task.yield()
        while coordinator.sessionRelayNeedsAnotherPass, !Task.isCancelled {
            coordinator.sessionRelayNeedsAnotherPass = false
            await coordinator.performSessionRelay()
        }
        coordinator.sessionRelayTask = nil
    }

    private static func runSetlistRelay() async {
        let coordinator = CloudSyncCoordinator.shared
        try? await Task.sleep(for: .seconds(2))
        while coordinator.setlistRelayNeedsAnotherPass, !Task.isCancelled {
            coordinator.setlistRelayNeedsAnotherPass = false
            await coordinator.performSetlistRelay()
        }
        coordinator.setlistRelayTask = nil
    }

    private static func runSettingsRelay() async {
        let coordinator = CloudSyncCoordinator.shared
        try? await Task.sleep(for: .seconds(2))
        while coordinator.settingsRelayNeedsAnotherPass, !Task.isCancelled {
            coordinator.settingsRelayNeedsAnotherPass = false
            await coordinator.performSettingsRelay()
        }
        coordinator.settingsRelayTask = nil
    }

    private static func runCueRelay() async {
        let coordinator = CloudSyncCoordinator.shared
        try? await Task.sleep(for: .seconds(2))
        while coordinator.cueRelayNeedsAnotherPass, !Task.isCancelled {
            coordinator.cueRelayNeedsAnotherPass = false
            await coordinator.performCueRelay(store: CueStore.shared)
        }
        coordinator.cueRelayTask = nil
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
