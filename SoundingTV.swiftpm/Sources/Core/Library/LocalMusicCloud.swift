import Foundation
import CloudKit
import Combine
import Network

enum LocalMusicCloudSchema {
    static let zoneName = "LocalMusic"
    static let recordType = "LocalTrackAsset"

    enum Field {
        static let trackId = "trackId"
        static let title = "title"
        static let artist = "artist"
        static let album = "album"
        static let genre = "genre"
        static let duration = "duration"
        static let fileExtension = "fileExtension"
        static let fileSize = "fileSize"
        static let modifiedAt = "modifiedAt"
        static let bpm = "bpm"
        static let keyWheelPosition = "keyWheelPosition"
        static let keyMode = "keyMode"
        static let sourceDeviceId = "sourceDeviceId"
        static let sourceDeviceName = "sourceDeviceName"
        static let audio = "audio"
        static let artwork = "artwork"
    }

    static let metadataKeys: [CKRecord.FieldKey] = [
        Field.trackId, Field.title, Field.artist, Field.album, Field.genre, Field.duration,
        Field.fileExtension, Field.fileSize, Field.modifiedAt, Field.bpm, Field.keyWheelPosition,
        Field.keyMode, Field.sourceDeviceId, Field.sourceDeviceName,
    ]

    static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName) }

    static func recordID(trackId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "track\(trackId)", zoneID: zoneID)
    }

    static func record(
        for track: LocalMusicCatalogTrack,
        audio: URL,
        artwork: URL?,
        deviceId: String,
        deviceName: String
    ) -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(trackId: track.id))
        record[Field.trackId] = track.id
        record[Field.title] = track.title
        record[Field.artist] = track.artist
        record[Field.album] = track.album
        record[Field.genre] = track.genre
        record[Field.duration] = track.duration
        record[Field.fileExtension] = track.fileExtension
        record[Field.fileSize] = track.fileSize
        record[Field.modifiedAt] = track.modifiedAt
        record[Field.bpm] = track.bpm
        record[Field.keyWheelPosition] = track.keyWheelPosition
        record[Field.keyMode] = track.keyMode
        record[Field.sourceDeviceId] = deviceId
        record[Field.sourceDeviceName] = deviceName
        record[Field.audio] = CKAsset(fileURL: audio)
        if let artwork { record[Field.artwork] = CKAsset(fileURL: artwork) }
        return record
    }

    static func catalogTrack(from record: CKRecord) -> LocalMusicCatalogTrack? {
        guard record.recordType == recordType,
              let id = record[Field.trackId] as? String,
              let title = record[Field.title] as? String else { return nil }
        return LocalMusicCatalogTrack(
            id: id,
            title: title,
            artist: record[Field.artist] as? String,
            album: record[Field.album] as? String,
            genre: record[Field.genre] as? String,
            duration: record[Field.duration] as? Double ?? 0,
            modifiedAt: record[Field.modifiedAt] as? Date ?? record.creationDate ?? Date(timeIntervalSince1970: 0),
            fileExtension: record[Field.fileExtension] as? String ?? "",
            fileSize: record[Field.fileSize] as? Int64 ?? 0,
            hasArtwork: record[Field.artwork] != nil,
            bpm: record[Field.bpm] as? Double,
            keyWheelPosition: record[Field.keyWheelPosition] as? Int,
            keyMode: record[Field.keyMode] as? Int
        )
    }
}

enum LocalMusicCloudStore {
    static func database() -> CKDatabase? {
        guard CloudSyncEngineController.containerIdentifierIsEntitled(CloudSyncContainer.identifier) else { return nil }
        return CKContainer(identifier: CloudSyncContainer.identifier).privateCloudDatabase
    }

    static func isAccountAvailable() async -> Bool {
        guard CloudSyncEngineController.containerIdentifierIsEntitled(CloudSyncContainer.identifier) else { return false }
        return (try? await CKContainer(identifier: CloudSyncContainer.identifier).accountStatus()) == .available
    }

    static func ensureZone(in database: CKDatabase) async throws {
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: LocalMusicCloudSchema.zoneID)], deleting: [])
    }

    static func fetchAll(in database: CKDatabase, desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord] {
        var token: CKServerChangeToken?
        var records: [CKRecord.ID: CKRecord] = [:]
        while true {
            guard let changes = try await zoneChanges(in: database, since: token, desiredKeys: desiredKeys) else { return [] }
            for (id, result) in changes.modificationResultsByID {
                if case .success(let modification) = result { records[id] = modification.record }
            }
            for deletion in changes.deletions { records[deletion.recordID] = nil }
            token = changes.changeToken
            if !changes.moreComing { break }
        }
        return Array(records.values)
    }

    private static func zoneChanges(
        in database: CKDatabase,
        since token: CKServerChangeToken?,
        desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> (
        modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
        deletions: [CKDatabase.RecordZoneChange.Deletion],
        changeToken: CKServerChangeToken,
        moreComing: Bool
    )? {
        do {
            return try await database.recordZoneChanges(
                inZoneWith: LocalMusicCloudSchema.zoneID, since: token, desiredKeys: desiredKeys
            )
        } catch let error as CKError where error.code == .zoneNotFound {
            return nil
        }
    }

    static func audioFile(trackId: String, in database: CKDatabase) async throws -> URL? {
        let id = LocalMusicCloudSchema.recordID(trackId: trackId)
        let results = try await database.records(for: [id], desiredKeys: [LocalMusicCloudSchema.Field.audio])
        guard case .success(let record)? = results[id] else { return nil }
        return (record[LocalMusicCloudSchema.Field.audio] as? CKAsset)?.fileURL
    }

    static func deleteAll(in database: CKDatabase) async throws {
        do {
            _ = try await database.modifyRecordZones(saving: [], deleting: [LocalMusicCloudSchema.zoneID])
        } catch let error as CKError where error.code == .zoneNotFound {
            return
        }
    }
}

// MARK: - Upload

@MainActor
final class LocalMusicCloudUploader: ObservableObject {
    static let shared = LocalMusicCloudUploader()
    static let enabledKey = "red.forbes.sounding.localMusic.iCloudUpload"

    enum Phase: Equatable {
        case off
        case checking
        case waitingForWiFi
        case uploading
        case upToDate
        case removing
        case unavailable(String)
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var phase: Phase = .off
    @Published private(set) var uploadedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var bytesUsed: Int64 = 0

    private let host: LocalMusicShareHost
    private let defaults: UserDefaults
    private let monitor = NWPathMonitor()
    private var isOnWiFi = false
    private var syncTask: Task<Void, Never>?
    private var changeSubscription: AnyCancellable?

    init(host: LocalMusicShareHost = .shared, defaults: UserDefaults = .standard) {
        self.host = host
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && !path.isExpensive && !path.isConstrained
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in self?.networkChanged(onWiFi: wifi) }
        }
        monitor.start(queue: DispatchQueue(label: "red.forbes.sounding.localmusic.cloud.path"))
        changeSubscription = host.changes.sink { [weak self] _ in
            Task { @MainActor in self?.scheduleSync() }
        }
        if isEnabled { phase = .checking }
    }

    var progress: Double? {
        guard phase == .uploading, totalCount > 0 else { return nil }
        return Double(uploadedCount) / Double(totalCount)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            scheduleSync()
        } else {
            syncTask?.cancel()
            syncTask = nil
            phase = .off
        }
    }

    func removeAll() {
        setEnabled(false)
        syncTask?.cancel()
        phase = .removing
        syncTask = Task { [weak self] in
            guard let self else { return }
            guard let database = LocalMusicCloudStore.database() else {
                self.phase = .unavailable("iCloud isn't available.")
                return
            }
            do {
                try await LocalMusicCloudStore.deleteAll(in: database)
                self.bytesUsed = 0
                self.uploadedCount = 0
                self.totalCount = 0
                self.phase = .off
            } catch {
                self.phase = .unavailable("Couldn't remove your music from iCloud.")
            }
        }
    }

    func refresh() {
        scheduleSync()
    }

    private func networkChanged(onWiFi: Bool) {
        let changed = onWiFi != isOnWiFi
        isOnWiFi = onWiFi
        if changed { scheduleSync() }
    }

    private func scheduleSync() {
        guard isEnabled else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func sync() async {
        guard isEnabled else { return }
        guard let database = LocalMusicCloudStore.database(), await LocalMusicCloudStore.isAccountAvailable() else {
            phase = .unavailable("Sign in to iCloud to upload your music.")
            return
        }
        phase = .checking
        let deviceId = DownloadManifestDeviceIdentity.deviceId()
        let existing: [CKRecord]
        do {
            try await LocalMusicCloudStore.ensureZone(in: database)
            existing = try await LocalMusicCloudStore.fetchAll(
                in: database,
                desiredKeys: [LocalMusicCloudSchema.Field.trackId, LocalMusicCloudSchema.Field.fileSize, LocalMusicCloudSchema.Field.sourceDeviceId]
            )
        } catch {
            phase = .unavailable("iCloud isn't responding. Sounding will try again.")
            return
        }
        let uploaded = Dictionary(
            existing.compactMap { record in (record[LocalMusicCloudSchema.Field.trackId] as? String).map { ($0, record) } },
            uniquingKeysWith: { first, _ in first }
        )
        bytesUsed = existing.reduce(Int64(0)) { $0 + (($1[LocalMusicCloudSchema.Field.fileSize] as? Int64) ?? 0) }
        let local = host.catalogTracks()
        let localIds = Set(local.map(\.id))
        let pending = local.filter { uploaded[$0.id] == nil }
        totalCount = local.count
        uploadedCount = local.count - pending.count

        let stale = existing.filter { record in
            guard record[LocalMusicCloudSchema.Field.sourceDeviceId] as? String == deviceId,
                  let id = record[LocalMusicCloudSchema.Field.trackId] as? String else { return false }
            return !localIds.contains(id)
        }
        if !stale.isEmpty, (try? await database.modifyRecords(saving: [], deleting: stale.map(\.recordID))) != nil {
            bytesUsed -= stale.reduce(Int64(0)) { $0 + (($1[LocalMusicCloudSchema.Field.fileSize] as? Int64) ?? 0) }
        }

        guard !pending.isEmpty else {
            phase = .upToDate
            return
        }
        guard isOnWiFi else {
            phase = .waitingForWiFi
            return
        }
        phase = .uploading
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("LocalMusicUpload", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for track in pending {
            guard !Task.isCancelled, isEnabled else { return }
            guard isOnWiFi else {
                phase = .waitingForWiFi
                return
            }
            guard let source = host.fileURL(forTrackId: track.id) else { continue }
            let copy = staging.appendingPathComponent("\(track.id).\(track.fileExtension.isEmpty ? "audio" : track.fileExtension)")
            let copied = await Task.detached(priority: .utility) { () -> Bool in
                try? FileManager.default.removeItem(at: copy)
                return (try? FileManager.default.copyItem(at: source, to: copy)) != nil
            }.value
            guard copied else { continue }
            defer { try? FileManager.default.removeItem(at: copy) }
            let record = LocalMusicCloudSchema.record(
                for: track, audio: copy, artwork: host.artworkURL(forTrackId: track.id),
                deviceId: deviceId, deviceName: LinkPeerIdentity.localName
            )
            do {
                _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
                uploadedCount += 1
                bytesUsed += track.fileSize
            } catch let error as CKError where error.code == .quotaExceeded {
                phase = .unavailable("Your iCloud storage is full.")
                return
            } catch {
                phase = .unavailable("iCloud isn't responding. Sounding will try again.")
                return
            }
        }
        phase = .upToDate
    }
}
