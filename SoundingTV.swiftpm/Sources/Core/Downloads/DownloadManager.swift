import AVFoundation
import Combine
import CryptoKit
import Foundation
import ObjectiveC
import Security
import SwiftUI

private final class BackgroundSessionCompletion: @unchecked Sendable {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }
}

enum DownloadStoragePolicy {
    static let accountsDirectoryName = "Accounts"
    static let transferStagingDirectoryName = "TransferStaging"
    static let accountIndexFileName = "index.vault"
    static let legacyIndexFileName = "index.json"
    static let legacyPlaintextCacheDirectoryName = "SoundingTV-DecryptedDownloads"
    static let temporaryPlaintextDirectoryName = "SoundingPlaintext"
    static let orphanGracePeriod: TimeInterval = 15 * 60

    static func accountDirectory(root: URL, accountID: String) -> URL {
        root
            .appendingPathComponent(accountsDirectoryName, isDirectory: true)
            .appendingPathComponent(AccountDataVault.storageSuffix(for: accountID), isDirectory: true)
    }

    static func accountStagingDirectory(root: URL, accountID: String) -> URL {
        accountDirectory(root: root, accountID: accountID)
            .appendingPathComponent("Staging", isDirectory: true)
    }

    static func decryptedAccountDirectory(root: URL, accountID: String) -> URL {
        root.appendingPathComponent(AccountDataVault.storageSuffix(for: accountID), isDirectory: true)
    }

    static func legacyEncryptedIndexFileName(accountID: String) -> String {
        "index.\(AccountDataVault.storageSuffix(for: accountID)).vault"
    }

    static func legacyPlaintextCacheRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent(legacyPlaintextCacheDirectoryName, isDirectory: true)
    }

    static func temporaryPlaintextRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(temporaryPlaintextDirectoryName, isDirectory: true)
    }

    static func migrateLegacyStorage(
        root: URL,
        accountID: String,
        fileManager: FileManager = .default
    ) {
        let destinationDirectory = accountDirectory(root: root, accountID: accountID)
        try? fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let legacyIndexName = legacyEncryptedIndexFileName(accountID: accountID)
        for source in contents {
            if source.lastPathComponent == accountsDirectoryName
                || source.lastPathComponent == transferStagingDirectoryName {
                continue
            }
            if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                continue
            }

            let destinationName = source.lastPathComponent == legacyIndexName
                ? accountIndexFileName
                : source.lastPathComponent
            let destination = destinationDirectory.appendingPathComponent(destinationName)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.moveItem(at: source, to: destination)
        }
    }

    static func temporaryArtifactTrackID(fileName: String) -> String? {
        if let range = fileName.range(of: "-assembled-") {
            return String(fileName[..<range.lowerBound])
        }
        if let range = fileName.range(of: ".replacement.") {
            return String(fileName[..<range.lowerBound])
        }
        if let range = fileName.range(of: "-partial-") {
            return String(fileName[..<range.lowerBound])
        }
        if fileName.hasSuffix(".partial") {
            return String(fileName.dropLast(".partial".count))
        }
        if fileName.hasSuffix(".encrypting") {
            return String(fileName.dropLast(".encrypting".count).split(separator: ".").first ?? "")
        }
        return nil
    }

    static func isTemporaryArtifact(fileName: String) -> Bool {
        fileName.contains("-assembled-")
            || fileName.contains(".replacement.")
            || fileName.contains("-partial-")
            || fileName.hasSuffix(".partial")
            || fileName.hasSuffix(".encrypting")
            || fileName.hasSuffix(".decrypting")
    }

    static func purgeAccountStorage(
        downloadsRoot: URL,
        decryptedRoot: URL,
        accountID: String,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: accountDirectory(root: downloadsRoot, accountID: accountID))
        try? fileManager.removeItem(at: decryptedAccountDirectory(root: decryptedRoot, accountID: accountID))
    }

    static func purgePlaintext(legacyRoot: URL, temporaryRoot: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: legacyRoot)
        try? fileManager.removeItem(at: temporaryRoot)
        try? fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        TemporaryPlaintextLeases.shared.forgetAll()
    }

    static func onDiskBytes(in directories: [URL], fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        var total: Int64 = 0
        var seen = Set<String>()
        for directory in directories {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: []
            ) else { continue }
            for case let file as URL in enumerator {
                guard seen.insert(file.standardizedFileURL.path).inserted,
                      let values = try? file.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }

    @discardableResult
    static func sweepTemporaryArtifacts(
        in directories: [URL],
        activeTrackIDs: Set<String>,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> (files: Int, bytes: Int64) {
        let cutoff = now.addingTimeInterval(-orphanGracePeriod)
        var removedFiles = 0
        var removedBytes: Int64 = 0

        for directory in directories {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in contents where isTemporaryArtifact(fileName: file.lastPathComponent) {
                let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
                ])
                guard values?.isRegularFile == true,
                      let modified = values?.contentModificationDate,
                      modified <= cutoff else { continue }
                if let trackID = temporaryArtifactTrackID(fileName: file.lastPathComponent),
                   activeTrackIDs.contains(trackID) {
                    continue
                }
                do {
                    try fileManager.removeItem(at: file)
                    removedFiles += 1
                    removedBytes += Int64(values?.fileSize ?? 0)
                } catch {
                    continue
                }
            }
        }
        return (removedFiles, removedBytes)
    }
}

private final class DownloadIndexWriter: @unchecked Sendable {
    private struct Payload: @unchecked Sendable {
        let entries: [String: DownloadEntry]
        let accountID: String
        let destination: URL
        let revision: UInt64
    }

    private let queue = DispatchQueue(label: "red.forbes.sounding.download-index", qos: .utility)
    private let lock = NSLock()
    private var latestRevision: UInt64 = 0

    func persist(entries: [String: DownloadEntry], accountID: String, destination: URL) {
        lock.lock()
        latestRevision &+= 1
        let revision = latestRevision
        lock.unlock()

        let payload = Payload(
            entries: entries,
            accountID: accountID,
            destination: destination,
            revision: revision
        )
        queue.async { [self] in
            guard isLatest(payload.revision),
                  let data = try? JSONEncoder().encode(payload.entries),
                  let sealed = AccountDataVault.seal(
                    data, accountID: payload.accountID, purpose: "download-index-v1"
                  ),
                  isLatest(payload.revision) else { return }
            try? sealed.write(to: payload.destination, options: .atomic)
        }
    }

    func invalidate() {
        lock.lock()
        latestRevision &+= 1
        lock.unlock()
    }

    private func isLatest(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestRevision == revision
    }
}

@MainActor
final class DownloadProgress: ObservableObject {
    @Published fileprivate(set) var fraction: Double = 0
}

struct DownloadFractionReader<Content: View>: View {
    @ObservedObject private var progress: DownloadProgress
    private let content: (Double) -> Content

    init(trackId: String, @ViewBuilder content: @escaping (Double) -> Content) {
        _progress = ObservedObject(wrappedValue: DownloadManager.shared.progress(for: trackId))
        self.content = content
    }

    var body: some View { content(progress.fraction) }
}

enum DownloadState: Equatable {
    case notDownloaded
    case queued
    case downloading(progress: Double)
    case paused(progress: Double)
    case downloaded
    case failed(reason: String)
}

@MainActor
struct LocalDownloadManifestSource: DownloadManifestExportSource {
    let deviceId: String
    let deviceLabel: String
    var manager: DownloadManager = .shared

    func currentManifest(limit: Int) async -> [DownloadManifestSyncRecord] {
        let sorted = manager.entries.values.filter(\.isDownloaded).sorted { $0.addedAt > $1.addedAt }
        return sorted.prefix(max(0, limit)).map { entry in
            let addedAtMillis = Int64(entry.addedAt.timeIntervalSince1970 * 1_000)
            return DownloadManifestSyncRecord(
                trackId: entry.track.id,
                deviceId: deviceId,
                deviceLabel: deviceLabel,
                isPinned: true,
                addedAtMillis: addedAtMillis,
                updatedAtMillis: addedAtMillis,
                isDeleted: false
            )
        }
    }
}

typealias LocalAudioProvider = @Sendable () async -> TemporaryPlaintextFile?

struct TemporaryPlaintextFile: Sendable, Hashable {
    let url: URL

    @discardableResult
    func retain() -> Bool {
        TemporaryPlaintextLeases.shared.retain(url)
    }

    func release() {
        TemporaryPlaintextLeases.shared.release(url)
    }
}

final class TemporaryPlaintextLeases: @unchecked Sendable {
    static let shared = TemporaryPlaintextLeases()

    private struct Lease {
        let fileURL: URL
        let key: String?
        var holders: Int
    }

    private let lock = NSLock()
    private var leases: [String: Lease] = [:]
    private var containersByKey: [String: String] = [:]

    static func container(of url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let container = url.deletingLastPathComponent()
        guard container.deletingLastPathComponent().lastPathComponent
                == DownloadStoragePolicy.temporaryPlaintextDirectoryName else { return nil }
        return container.standardizedFileURL
    }

    func register(_ url: URL, key: String? = nil) {
        guard let container = Self.container(of: url) else { return }
        lock.withLock {
            leases[container.path] = Lease(fileURL: url, key: key, holders: 1)
            if let key { containersByKey[key] = container.path }
        }
    }

    func retainExisting(key: String) -> URL? {
        lock.withLock {
            guard let path = containersByKey[key], var lease = leases[path] else { return nil }
            guard FileManager.default.fileExists(atPath: lease.fileURL.path) else {
                leases[path] = nil
                containersByKey[key] = nil
                return nil
            }
            lease.holders += 1
            leases[path] = lease
            return lease.fileURL
        }
    }

    @discardableResult
    func retain(_ url: URL) -> Bool {
        guard let container = Self.container(of: url) else { return false }
        return lock.withLock {
            guard var lease = leases[container.path] else { return false }
            lease.holders += 1
            leases[container.path] = lease
            return true
        }
    }

    func release(_ url: URL) {
        guard let container = Self.container(of: url) else { return }
        let shouldDelete = lock.withLock { () -> Bool in
            guard var lease = leases[container.path] else { return true }
            lease.holders -= 1
            guard lease.holders <= 0 else {
                leases[container.path] = lease
                return false
            }
            leases[container.path] = nil
            if let key = lease.key, containersByKey[key] == container.path { containersByKey[key] = nil }
            return true
        }
        if shouldDelete { try? FileManager.default.removeItem(at: container) }
    }

    func holderCount(_ url: URL) -> Int {
        guard let container = Self.container(of: url) else { return 0 }
        return lock.withLock { leases[container.path]?.holders ?? 0 }
    }

    func hasLiveCopy(key: String) -> Bool {
        lock.withLock {
            guard let path = containersByKey[key], let lease = leases[path] else { return false }
            return FileManager.default.fileExists(atPath: lease.fileURL.path)
        }
    }

    func forgetAll() {
        lock.withLock {
            leases.removeAll()
            containersByKey.removeAll()
        }
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    nonisolated static let backgroundSessionIdentifier = "red.forbes.sounding.downloads"

    @Published private(set) var states: [String: DownloadState] = [:]
    private var progressObjects: [String: DownloadProgress] = [:]

    @Published private(set) var entries: [String: DownloadEntry] = [:]
    @Published private(set) var collections: [String: DownloadedCollectionRecord] = [:]
    @Published private(set) var syncingCollectionIDs: Set<String> = []

    @Published private(set) var usedBytes: Int64 = 0
    @Published private(set) var waitingReason: String?
    @Published private(set) var isOnUnmeteredNetwork = true
    @Published private(set) var hasConnectivity = true

    @Published private(set) var allowsCellularDownloads: Bool {
        didSet {
            guard allowsCellularDownloads != oldValue else { return }
            handlePolicyChange()
        }
    }

    @Published private(set) var optimiseStorage: Bool {
        didSet {
            guard optimiseStorage != oldValue, optimiseStorage else { return }
            Task { [weak self] in await self?.runMaintenance() }
        }
    }

    @Published private(set) var optimiseStorageMinimumBytes: Int64
    @Published private(set) var quality: QualityCeiling

    var storageUsed: Int64 { usedBytes }
    var downloadOverCellular: Bool { allowsCellularDownloads }
    var isOnCellular: Bool { hasConnectivity && !isOnUnmeteredNetwork }
    var isIndexLoaded: Bool { isIndexReady }

    func setDownloadOverCellular(_ value: Bool) {
        SettingsStore.shared.setCellularDownloadsAllowed(value)
    }

    func setOptimiseStorage(_ value: Bool) {
        SettingsStore.shared.setOptimiseStorage(value)
    }

    func setOptimiseStorageMinimumBytes(_ value: Int64) {
        SettingsStore.shared.setOptimiseStorageMinimumBytes(value)
    }

    func setQuality(_ value: QualityCeiling) {
        SettingsStore.shared.setDownloadQualityCeiling(value)
    }

    var scheduledDeletionDate: Date? {
        guard case .verifiedNotSubscribed = SubscriptionService.shared.verification,
              let since = SubscriptionService.shared.notSubscribedSince else { return nil }
        let date = since.addingTimeInterval(SubscriptionService.deletionDelay)
        guard date > Date(), entries.values.contains(where: { entitlementDenial(for: $0.track) != nil }) else { return nil }
        return date
    }

    private static let maxConcurrentTransfers = 3
    private static let maintenanceInterval: TimeInterval = 3600
    private static let pacingDefaultsKey = "red.forbes.sounding.downloads.pacing"
    private static let pausedRecheck: TimeInterval = 30

    private nonisolated let downloadsRootDirectory: URL
    private nonisolated let transferStagingDirectory: URL
    private nonisolated let legacyPlaintextDirectory: URL
    private nonisolated let temporaryPlaintextDirectory: URL
    private var activeAccountID: String?
    private var isIndexReady = false

    private var session: URLSession!
    private var activeResolutionTasks: [String: Task<Void, Never>] = [:]
    private var activeDownloadTasks: [String: URLSessionDownloadTask] = [:]
    private var activeAssemblyTasks: [String: Task<Void, Never>] = [:]
    private var collectionSyncTasks: [String: Task<Void, Never>] = [:]
    private var vaultUnlockTask: Task<Void, Never>?
    private var usedBytesTask: Task<Void, Never>?
    private let scheduler = WorkScheduler.shared
    private static let schedulerQueue = WorkScheduler.QueueID(rawValue: "downloads.policy")
    private var resumeDataStore: [String: Data] = [:]
    private var pendingFileExtensions: [String: String] = [:]
    private var pendingSourceFingerprints: [String: String] = [:]
    private var pendingQueue: [String] = []
    private var pausedByPolicy: Set<String> = []
    private var qualityMigrationQueue: [String] = []
    private var qualityMigrationTrackID: String?
    private var heavyPacer = HeavyWorkPacer.decode(UserDefaults.standard.data(forKey: DownloadManager.pacingDefaultsKey)) ?? HeavyWorkPacer()
    private var backgroundInFlight: Set<String> = []

    private var systemCompletion: BackgroundSessionCompletion?
    private let indexWriter = DownloadIndexWriter()
    private var settingsCancellables = Set<AnyCancellable>()
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        let directory = AppDataDirectory.folder("Downloads")
        downloadsRootDirectory = directory
        transferStagingDirectory = directory.appendingPathComponent(
            DownloadStoragePolicy.transferStagingDirectoryName,
            isDirectory: true
        )
        legacyPlaintextDirectory = DownloadStoragePolicy.legacyPlaintextCacheRoot()
        temporaryPlaintextDirectory = DownloadStoragePolicy.temporaryPlaintextRoot()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: directory.appendingPathComponent(DownloadStoragePolicy.accountsDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(at: transferStagingDirectory, withIntermediateDirectories: true)

        let settings = SettingsStore.shared
        allowsCellularDownloads = settings.cellularDownloadsAllowed
        optimiseStorage = settings.optimiseStorage
        optimiseStorageMinimumBytes = settings.optimiseStorageMinimumBytes
        quality = settings.downloadQualityCeiling

        super.init()

        try? FileManager.default.removeItem(at: temporaryPlaintextDirectory)
        try? FileManager.default.createDirectory(at: temporaryPlaintextDirectory, withIntermediateDirectories: true)
        let legacyPlaintext = legacyPlaintextDirectory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: legacyPlaintext)
        }
        observeSettings(settings)
        observeLibrary()

        SoundCloudCredentialSource.shared.$state
            .map(\.isSignedOut)
            .removeDuplicates()
            .sink { [weak self] isSignedOut in
                guard isSignedOut else { return }
                self?.lockAccountVault()
            }
            .store(in: &cancellables)

        scheduler.$environment
            .removeDuplicates()
            .sink { [weak self] environment in
                guard let self else { return }
                self.hasConnectivity = environment.hasNetwork
                self.isOnUnmeteredNetwork = environment.hasUnmeteredNetwork
                self.handlePolicyChange()
            }
            .store(in: &cancellables)

        var excludedDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedDirectory.setResourceValues(resourceValues)

        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        observeSubscriptionState()
        startMaintenanceLoop()

        Task { [weak self] in self?.sweepOrphanedTransferArtifacts() }
    }

    private func observeSettings(_ settings: SettingsStore) {
        settings.$cellularDownloadsAllowed
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor in self?.allowsCellularDownloads = value }
            }
            .store(in: &settingsCancellables)

        settings.$optimiseStorage
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor in self?.optimiseStorage = value }
            }
            .store(in: &settingsCancellables)

        settings.$optimiseStorageMinimumBytes
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor in self?.optimiseStorageMinimumBytes = value }
            }
            .store(in: &settingsCancellables)

        settings.$downloadQualityCeiling
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor in self?.quality = value }
            }
            .store(in: &settingsCancellables)

        settings.$analyseMusicOnDevice
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.resumeDownloadedIntelligenceWork()
            }
            .store(in: &settingsCancellables)
    }

    private func observeLibrary() {
        LikesSyncEngine.shared.$revision
            .removeDuplicates()
            .debounce(for: .seconds(5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleCollectionSync(CollectionPolicyID.likedTracks)
            }
            .store(in: &cancellables)

        SoundCloudAPI.shared.$latestLikeChange
            .compactMap { $0 }
            .sink { [weak self] change in
                self?.handleLikeChange(change)
            }
            .store(in: &cancellables)
    }

    func stop() {
        scheduler.cancelPeriodic(id: "downloads.maintenance")
        scheduler.cancelPending(keyPrefix: "downloads.", in: [Self.schedulerQueue])
        vaultUnlockTask?.cancel()
        vaultUnlockTask = nil
        for task in activeResolutionTasks.values { task.cancel() }
        for task in activeDownloadTasks.values { task.cancel() }
        for task in activeAssemblyTasks.values { task.cancel() }
        for task in collectionSyncTasks.values { task.cancel() }
        activeResolutionTasks.removeAll()
        activeDownloadTasks.removeAll()
        activeAssemblyTasks.removeAll()
        collectionSyncTasks.removeAll()
        cancellables.removeAll()
    }

    @discardableResult
    nonisolated func handleBackgroundURLSessionEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == Self.backgroundSessionIdentifier else { return false }
        let completion = BackgroundSessionCompletion(completionHandler)
        Task { @MainActor [self, completion] in
            systemCompletion = completion
        }
        return true
    }

    // MARK: - Observable state

    func state(for trackId: String) -> DownloadState {
        switch states[trackId] {
        case .downloading: return .downloading(progress: progressObjects[trackId]?.fraction ?? 0)
        case let state?: return state
        case nil: return .notDownloaded
        }
    }

    func progress(for trackId: String) -> DownloadProgress {
        if let existing = progressObjects[trackId] { return existing }
        let created = DownloadProgress()
        progressObjects[trackId] = created
        return created
    }

    private func storeFraction(_ fraction: Double, for trackId: String) {
        if let existing = progressObjects[trackId] {
            if existing.fraction != fraction { existing.fraction = fraction }
        } else if fraction != 0 {
            progress(for: trackId).fraction = fraction
        }
    }

    func downloadRefusalReason(for track: Track) -> DownloadError? {
        guard isFullyEntitled(track) else { return .previewOnly }
        return nil
    }

    func entitlementDenial(for track: Track) -> SoundCloudEntitlementError? {
        SubscriptionService.shared.denial(for: track, feature: .downloads)
    }

    func isCollectionDownloaded(_ collectionID: String) -> Bool {
        collections[collectionID] != nil
    }

    var library: DownloadLibrarySnapshot {
        var snapshot = DownloadLibrarySnapshot(storageUsed: usedBytes)
        var members: [String: [DownloadEntry]] = [:]
        for entry in entries.values {
            for collectionID in entry.collectionIDs {
                members[collectionID, default: []].append(entry)
            }
        }
        var playlists: [DownloadedCollectionItem] = []
        for record in collections.values {
            let item = collectionItem(for: record, members: members[record.id] ?? [])
            if record.kind == .likes {
                snapshot.likes = item
            } else {
                playlists.append(item)
            }
        }
        snapshot.playlists = playlists.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        snapshot.songs = entries.values
            .filter(\.isExplicit)
            .sorted { $0.addedAt > $1.addedAt }
            .map(trackItem(for:))
        return snapshot
    }

    func tracks(inDownloadedCollection collectionID: String) -> [DownloadedTrackItem] {
        entries.values
            .filter { $0.collectionIDs.contains(collectionID) }
            .sorted { $0.addedAt < $1.addedAt }
            .map(trackItem(for:))
    }

    private func trackItem(for entry: DownloadEntry) -> DownloadedTrackItem {
        DownloadedTrackItem(
            id: entry.track.id,
            track: entry.track,
            bytes: entry.isDownloaded ? entry.fileSize : 0,
            state: state(for: entry.track.id),
            lastPlayedAt: entry.lastPlayedAt
        )
    }

    private func collectionItem(for record: DownloadedCollectionRecord, members: [DownloadEntry]) -> DownloadedCollectionItem {
        let downloaded = members.filter(\.isDownloaded)
        var failed = false
        var active = false
        for entry in members where !entry.isDownloaded {
            switch state(for: entry.track.id) {
            case .failed: failed = true
            case .downloading: active = true
            default: break
            }
        }
        let total = members.count
        let completed = downloaded.count
        let itemState: DownloadItemState
        if completed == total {
            itemState = .downloaded
        } else if active {
            itemState = .downloading(completed: completed, total: total)
        } else if failed {
            itemState = .failed(completed: completed, total: total)
        } else {
            itemState = .waiting(completed: completed, total: total)
        }
        return DownloadedCollectionItem(
            id: record.id,
            kind: record.kind,
            title: record.title,
            artworkURL: record.artworkURL,
            trackCount: total,
            downloadedCount: completed,
            bytes: downloaded.reduce(Int64(0)) { $0 + $1.fileSize },
            excludedCount: record.excludedTrackIDs.count,
            state: itemState
        )
    }

    // MARK: - Local playback and analysis

    func isLocallyAvailable(_ track: Track) -> Bool {
        isLocallyAvailable(trackId: track.id)
    }

    func isLocallyAvailable(trackId: String) -> Bool {
        guard let accountID = SubscriptionService.shared.authenticatedAccountID,
              SubscriptionService.shared.hasAuthenticatedSession,
              let entry = entries[trackId],
              entry.fileName != nil else { return false }
        return entry.encryptionAccountID == accountID
    }

    private func vaultFile(for trackID: String) -> (url: URL, key: SymmetricKey, fileExtension: String)? {
        guard let accountID = SubscriptionService.shared.authenticatedAccountID,
              SubscriptionService.shared.hasAuthenticatedSession,
              accountID == activeAccountID,
              let entry = entries[trackID],
              SubscriptionService.shared.denial(for: entry.track, feature: .downloads) == nil,
              let fileName = entry.fileName,
              entry.encryptionAccountID == accountID else { return nil }
        let url = accountDirectory(for: accountID).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let key = DownloadVault.key(for: accountID, createIfMissing: false) else { return nil }
        return (url, key, entry.originalFileExtension ?? "audio")
    }

    func playbackAsset(for track: Track) async -> AVURLAsset? {
        guard let file = vaultFile(for: track.id) else { return nil }
        let reader = await Task.detached(priority: .userInitiated) {
            try? EncryptedAudioReader(fileURL: file.url, key: file.key)
        }.value
        guard let reader else { return nil }
        return VaultPlaybackAsset.make(reader: reader, trackID: track.id, fileExtension: file.fileExtension)
    }

    func peerContentSource(forTrackId trackID: String) async -> (any PeerContentByteSource)? {
        guard let file = vaultFile(for: trackID) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? EncryptedAudioReader(fileURL: file.url, key: file.key)
        }.value
    }

    func temporaryPlaintextFile(trackID: String) async -> TemporaryPlaintextFile? {
        guard let file = vaultFile(for: trackID) else { return nil }
        if let shared = TemporaryPlaintextLeases.shared.retainExisting(key: trackID) {
            return TemporaryPlaintextFile(url: shared)
        }
        let container = temporaryPlaintextDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = container.appendingPathComponent("\(trackID).\(file.fileExtension)")
        let succeeded = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
                try DownloadVault.decryptFile(at: file.url, to: destination, using: file.key)
                return true
            } catch {
                try? FileManager.default.removeItem(at: container)
                return false
            }
        }.value
        guard succeeded else { return nil }
        TemporaryPlaintextLeases.shared.register(destination, key: trackID)
        return TemporaryPlaintextFile(url: destination)
    }

    func temporaryPlaintextCopyBytes(trackID: String) -> Int64 {
        guard !TemporaryPlaintextLeases.shared.hasLiveCopy(key: trackID),
              let file = vaultFile(for: trackID) else { return 0 }
        let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        return size ?? entries[trackID]?.fileSize ?? 0
    }

    func temporaryPlaintextFile(for track: Track) async -> TemporaryPlaintextFile? {
        await temporaryPlaintextFile(trackID: track.id)
    }

    nonisolated static func localAudioProvider(for trackID: String) -> LocalAudioProvider {
        { @Sendable in await DownloadManager.shared.temporaryPlaintextFile(trackID: trackID) }
    }

    func cachedTrack(forTrackId trackId: String) -> Track? {
        entries[trackId]?.track
    }

    func cachedTracks(forCollectionId collectionId: String) -> [Track] {
        entries.values
            .filter { $0.collectionIDs.contains(collectionId) }
            .sorted { $0.addedAt < $1.addedAt }
            .map(\.track)
    }

    func markPlayed(trackId: String) {
        guard var entry = entries[trackId] else { return }
        entry.lastPlayedAt = Date()
        entries[trackId] = entry
        persistIndex()
    }

    // MARK: - Requests

    func estimate(track: Track) -> DownloadSizeEstimate {
        let pending = entries[track.id]?.isDownloaded == true ? [] : [track]
        return DownloadSizeEstimate.estimate(tracks: pending, ceiling: quality, isOnCellular: isOnCellular)
    }

    @discardableResult
    func download(track: Track, confirmed: Bool = false) -> DownloadRequestResult {
        if let denial = entitlementDenial(for: track) { return .refused(.entitlement(denial)) }
        guard isFullyEntitled(track) else { return .refused(.previewOnly) }
        let sizeEstimate = estimate(track: track)
        if !confirmed, sizeEstimate.requiresConfirmation { return .needsConfirmation(sizeEstimate) }
        var updated = collections
        var changed = false
        for (id, record) in collections where record.excludedTrackIDs.contains(track.id) {
            updated[id]?.excludedTrackIDs.remove(track.id)
            changed = true
        }
        if changed { storeCollections(updated) }
        upsertEntry(for: track, explicit: true, collectionId: nil)
        return .queued(sizeEstimate)
    }

    func estimate(collection descriptor: DownloadCollectionDescriptor, tracks supplied: [Track]? = nil) async -> DownloadSizeEstimate {
        let members = await resolveMembers(for: descriptor, supplied: supplied)
        let pending = (members?.ordered ?? supplied ?? [])
            .filter { isFullyEntitled($0) && entries[$0.id]?.isDownloaded != true }
        return DownloadSizeEstimate.estimate(tracks: pending, ceiling: quality, isOnCellular: isOnCellular)
    }

    @discardableResult
    func download(
        collection descriptor: DownloadCollectionDescriptor,
        tracks supplied: [Track]? = nil,
        confirmed: Bool = false
    ) async -> DownloadRequestResult {
        if let denial = SubscriptionService.shared.denial(for: .downloads) {
            return .refused(.entitlement(denial))
        }
        guard let members = await resolveMembers(for: descriptor, supplied: supplied) else {
            return .refused(.streamResolutionFailed)
        }
        let entitled = members.ordered.filter { isFullyEntitled($0) && entitlementDenial(for: $0) == nil }
        if !members.ordered.isEmpty, entitled.isEmpty { return .refused(.previewOnly) }
        let pending = entitled.filter { entries[$0.id]?.isDownloaded != true }
        let estimate = DownloadSizeEstimate.estimate(tracks: pending, ceiling: quality, isOnCellular: isOnCellular)
        if !confirmed, estimate.requiresConfirmation { return .needsConfirmation(estimate) }

        var record = collections[descriptor.id] ?? DownloadedCollectionRecord(
            id: descriptor.id,
            kind: descriptor.kind,
            title: descriptor.title,
            artworkURL: descriptor.artworkURL
        )
        record.title = members.playlist?.title ?? descriptor.title
        record.artworkURL = members.playlist?.displayArtworkURL ?? descriptor.artworkURL ?? record.artworkURL
        record.excludedTrackIDs = []
        var updated = collections
        updated[descriptor.id] = record
        storeCollections(updated)

        applySync(
            collectionID: descriptor.id,
            memberIDs: members.ordered.map(\.id),
            tracksByID: Dictionary(members.ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            authoritative: members.isAuthoritative
        )
        return .queued(estimate)
    }

    func removeDownload(_ target: DownloadTarget) {
        switch target {
        case .track(let trackID):
            guard let entry = entries[trackID] else {
                deleteEntry(trackID)
                return
            }
            if !entry.collectionIDs.isEmpty {
                storeCollections(DownloadCollectionSync.exclusionsAfterRemoving(
                    trackID: trackID,
                    from: collections,
                    memberOf: entry.collectionIDs
                ))
            }
            deleteEntry(trackID)
        case .collection(let collectionID):
            collectionSyncTasks.removeValue(forKey: collectionID)?.cancel()
            var updated = collections
            updated[collectionID] = nil
            storeCollections(updated)
            detach(trackIDs: entries.filter { $0.value.collectionIDs.contains(collectionID) }.map(\.key), from: collectionID)
        }
    }

    func removeAll() {
        for task in collectionSyncTasks.values { task.cancel() }
        collectionSyncTasks.removeAll()
        storeCollections([:])
        qualityMigrationQueue.removeAll()
        for trackID in Array(entries.keys) {
            deleteEntry(trackID, persist: false)
        }
        for task in activeDownloadTasks.values { task.cancel() }
        persistIndex()
        refreshUsedBytes()
    }

    func applyCollectionPolicy(tracks: [Track], collectionId: String) {
        noteCollectionMembers(tracks, collectionID: collectionId)
    }

    func noteCollectionMembers(_ tracks: [Track], collectionID: String) {
        guard isIndexReady, collections[collectionID] != nil, !tracks.isEmpty else { return }
        applySync(
            collectionID: collectionID,
            memberIDs: tracks.map(\.id),
            tracksByID: Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            authoritative: false
        )
    }

    // MARK: - Quality

    func redownloadEstimate() -> DownloadSizeEstimate {
        DownloadSizeEstimate.estimate(
            tracks: qualityMigrationCandidates().compactMap { entries[$0]?.track },
            ceiling: quality,
            isOnCellular: isOnCellular
        )
    }

    @discardableResult
    func redownloadAtCurrentQuality(confirmed: Bool = false) -> DownloadRequestResult {
        let estimate = redownloadEstimate()
        if !confirmed, estimate.requiresConfirmation { return .needsConfirmation(estimate) }
        qualityMigrationQueue = qualityMigrationCandidates().filter { $0 != qualityMigrationTrackID }
        startNextQualityMigrationIfPossible()
        return .queued(estimate)
    }

    private func qualityMigrationCandidates() -> [String] {
        entries.values
            .filter(\.isDownloaded)
            .filter { entry in
                guard let selected = chooseSource(for: entry.track) else { return false }
                return entry.sourceFingerprint != Self.sourceFingerprint(selected.transcoding)
            }
            .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
            .map { $0.track.id }
    }

    // MARK: - Transfer control

    func pause(trackId: String) {
        if let resolution = activeResolutionTasks.removeValue(forKey: trackId) {
            resolution.cancel()
            setState(.paused(progress: 0), for: trackId)
            admitFromQueueIfPossible()
            return
        }
        if let task = activeDownloadTasks[trackId] {
            task.cancel(byProducingResumeData: { [weak self] data in
                Task { @MainActor in
                    guard let self else { return }
                    self.activeDownloadTasks[trackId] = nil
                    if let data { self.persistResumeData(data, for: trackId) }
                    self.setState(.paused(progress: self.lastKnownProgress(trackId)), for: trackId)
                    self.admitFromQueueIfPossible()
                }
            })
            return
        }
        if let assembly = activeAssemblyTasks[trackId] {
            assembly.cancel()
            activeAssemblyTasks[trackId] = nil
            setState(.paused(progress: lastKnownProgress(trackId)), for: trackId)
            admitFromQueueIfPossible()
            return
        }
        if pendingQueue.contains(trackId) {
            pendingQueue.removeAll { $0 == trackId }
            setState(.paused(progress: 0), for: trackId)
        }
    }

    func resume(trackId: String) {
        pausedByPolicy.remove(trackId)
        guard let entry = entries[trackId], !entry.isDownloaded else { return }
        guard canTransferNow() else {
            pausedByPolicy.insert(trackId)
            return
        }
        guard !pendingQueue.contains(trackId),
              activeResolutionTasks[trackId] == nil,
              activeDownloadTasks[trackId] == nil,
              activeAssemblyTasks[trackId] == nil else { return }
        setState(.queued, for: trackId)
        pendingQueue.append(trackId)
        admitFromQueueIfPossible()
    }

    private func deleteEntry(_ trackId: String, persist: Bool = true) {
        if let resolution = activeResolutionTasks.removeValue(forKey: trackId) {
            resolution.cancel()
        }
        if let task = activeDownloadTasks.removeValue(forKey: trackId) {
            task.cancel()
        }
        if let assembly = activeAssemblyTasks.removeValue(forKey: trackId) {
            assembly.cancel()
        }
        pendingQueue.removeAll { $0 == trackId }
        pausedByPolicy.remove(trackId)
        qualityMigrationQueue.removeAll { $0 == trackId }
        resumeDataStore[trackId] = nil
        clearResumeDataFile(for: trackId)
        pendingFileExtensions[trackId] = nil
        pendingSourceFingerprints[trackId] = nil

        if let entry = entries[trackId] {
            if let fileName = entry.fileName, let activeAccountID {
                try? FileManager.default.removeItem(
                    at: accountDirectory(for: activeAccountID).appendingPathComponent(fileName)
                )
            }
            entries[trackId] = nil
        }
        states[trackId] = .notDownloaded
        storeFraction(0, for: trackId)

        if qualityMigrationTrackID == trackId {
            qualityMigrationTrackID = nil
            startNextQualityMigrationIfPossible()
        }
        if persist {
            persistIndex()
            refreshUsedBytes()
        }
        admitFromQueueIfPossible()
    }

    private func upsertEntry(
        for track: Track,
        explicit: Bool,
        collectionId: String?,
        persistImmediately: Bool = true,
        admitImmediately: Bool = true
    ) {
        if var existing = entries[track.id] {
            existing.track = track
            if explicit { existing.isExplicit = true }
            if let collectionId { existing.collectionIDs.insert(collectionId) }
            entries[track.id] = existing
            if persistImmediately { persistIndex() }
            switch states[track.id] {
            case .downloaded, .downloading:
                return
            case .queued where pendingQueue.contains(track.id) || hasActiveWork(track.id):
                return
            case .paused:
                if admitImmediately { resume(trackId: track.id) }
                return
            default:
                if existing.isDownloaded || hasActiveWork(track.id) { return }
            }
        } else {
            entries[track.id] = DownloadEntry(
                track: track,
                isExplicit: explicit,
                collectionIDs: collectionId.map { [$0] } ?? []
            )
        }
        setState(.queued, for: track.id)
        if !pendingQueue.contains(track.id) { pendingQueue.append(track.id) }
        if persistImmediately { persistIndex() }
        if admitImmediately { admitFromQueueIfPossible() }
    }

    private func hasActiveWork(_ trackId: String) -> Bool {
        activeResolutionTasks[trackId] != nil
            || activeDownloadTasks[trackId] != nil
            || activeAssemblyTasks[trackId] != nil
    }

    private func isFullyEntitled(_ track: Track) -> Bool {
        !track.transcodings.isEmpty
    }

    private func chooseSource(for track: Track) -> DownloadSourceSelection.Source? {
        DownloadSourceSelection.choose(
            from: track.transcodings,
            ceiling: quality,
            allowsHighQuality: DownloadSourceSelection.allowsHighQuality(for: SubscriptionService.shared.tier)
        )
    }

    // MARK: - Collections

    private struct ResolvedMembers {
        let ordered: [Track]
        let isAuthoritative: Bool
        var playlist: Playlist? = nil
    }

    private func resolveMembers(
        for descriptor: DownloadCollectionDescriptor,
        supplied: [Track]?
    ) async -> ResolvedMembers? {
        switch descriptor.kind {
        case .likes:
            let engine = LikesSyncEngine.shared
            let indexed = await engine.indexedLikes().tracks
            let isComplete = await engine.indexCompletedAt() != nil && !engine.isSyncing
            let merged = Self.merge(indexed, supplied ?? [])
            guard !merged.isEmpty || isComplete else { return supplied.map { ResolvedMembers(ordered: $0, isAuthoritative: false) } }
            return ResolvedMembers(ordered: merged, isAuthoritative: isComplete && merged.count == indexed.count)
        case .playlist:
            var playlist = descriptor.playlist
            if playlist?.trackIDs == nil {
                playlist = try? await SoundCloudAPI.shared.getPlaylist(id: descriptor.id)
            }
            guard let playlist, let ids = playlist.trackIDs else {
                guard let supplied, !supplied.isEmpty else { return nil }
                return ResolvedMembers(ordered: supplied, isAuthoritative: false)
            }
            var known = Dictionary(
                (playlist.loadedTracks + (supplied ?? [])).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for (id, entry) in entries where known[id] == nil { known[id] = entry.track }
            let missing = ids.filter { known[$0] == nil }
            if !missing.isEmpty,
               let hydrated = try? await SoundCloudAPI.shared.getPlaylistTracks(playlist, ids: missing) {
                for track in hydrated { known[track.id] = track }
            }
            return ResolvedMembers(
                ordered: ids.compactMap { known[$0] },
                isAuthoritative: missing.allSatisfy { known[$0] != nil },
                playlist: playlist
            )
        }
    }

    private static func merge(_ primary: [Track], _ secondary: [Track]) -> [Track] {
        var seen = Set<String>()
        return (primary + secondary).filter { seen.insert($0.id).inserted }
    }

    private func applySync(
        collectionID: String,
        memberIDs: [String],
        tracksByID: [String: Track],
        authoritative: Bool
    ) {
        guard var record = collections[collectionID] else { return }
        let plan = DownloadCollectionSync.plan(
            collectionID: collectionID,
            memberIDs: memberIDs,
            excluded: record.excludedTrackIDs,
            entries: entries,
            authoritative: authoritative
        )
        attach(tracks: plan.attach.compactMap { tracksByID[$0] ?? entries[$0]?.track }, to: collectionID)
        guard authoritative else { return }
        detach(trackIDs: plan.detach, from: collectionID)
        if record.excludedTrackIDs != plan.prunedExclusions {
            record.excludedTrackIDs = plan.prunedExclusions
            var updated = collections
            updated[collectionID] = record
            storeCollections(updated)
        }
    }

    private func attach(tracks: [Track], to collectionID: String) {
        var accepted = 0
        for track in tracks where isFullyEntitled(track) && entitlementDenial(for: track) == nil {
            upsertEntry(
                for: track,
                explicit: false,
                collectionId: collectionID,
                persistImmediately: false,
                admitImmediately: false
            )
            accepted += 1
        }
        guard accepted > 0 else { return }
        persistIndex()
        admitFromQueueIfPossible()
    }

    private func detach(trackIDs: [String], from collectionID: String) {
        guard !trackIDs.isEmpty else { return }
        for trackID in trackIDs {
            guard var entry = entries[trackID] else { continue }
            entry.collectionIDs.remove(collectionID)
            if entry.isRetained {
                entries[trackID] = entry
            } else {
                deleteEntry(trackID, persist: false)
            }
        }
        persistIndex()
        refreshUsedBytes()
    }

    private func storeCollections(_ value: [String: DownloadedCollectionRecord]) {
        collections = value
        SettingsStore.shared.setDownloadedCollections(value)
    }

    private func handleLikeChange(_ change: SoundCloudLikeChange) {
        let likesID = CollectionPolicyID.likedTracks
        guard isIndexReady, var record = collections[likesID] else { return }
        if change.isLiked {
            guard !record.excludedTrackIDs.contains(change.track.id) else { return }
            attach(tracks: [change.track], to: likesID)
        } else {
            if record.excludedTrackIDs.remove(change.track.id) != nil {
                var updated = collections
                updated[likesID] = record
                storeCollections(updated)
            }
            detach(trackIDs: [change.track.id], from: likesID)
        }
    }

    func scheduleCollectionSync(_ collectionID: String? = nil) {
        guard isIndexReady, !AutomaticAnalysisEligibility.isSuppressedForFixtures else { return }
        let ids = collectionID.map { [$0] } ?? Array(collections.keys)
        for id in ids where collections[id] != nil && collectionSyncTasks[id] == nil {
            collectionSyncTasks[id] = Task { [weak self] in
                await self?.syncCollection(id)
                self?.collectionSyncTasks[id] = nil
            }
        }
    }

    func syncCollection(_ collectionID: String) async {
        guard isIndexReady, let record = collections[collectionID] else { return }
        syncingCollectionIDs.insert(collectionID)
        defer { syncingCollectionIDs.remove(collectionID) }
        switch record.kind {
        case .likes:
            let engine = LikesSyncEngine.shared
            guard !engine.isSyncing, await engine.indexCompletedAt() != nil else { return }
            let tracks = await engine.indexedLikes().tracks
            guard !Task.isCancelled, collections[collectionID] != nil else { return }
            applySync(
                collectionID: collectionID,
                memberIDs: tracks.map(\.id),
                tracksByID: Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                authoritative: true
            )
        case .playlist:
            guard hasConnectivity, (try? SoundCloudAPI.shared.enforceTrafficSafety()) != nil else { return }
            guard let playlist = try? await SoundCloudAPI.shared.getPlaylist(id: collectionID),
                  let ids = playlist.trackIDs,
                  !Task.isCancelled,
                  var current = collections[collectionID] else { return }
            let known = Set(entries.keys)
            let missing = ids.filter { !known.contains($0) && !current.excludedTrackIDs.contains($0) }
            var tracksByID = Dictionary(playlist.loadedTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let unresolved = missing.filter { tracksByID[$0] == nil }
            if !unresolved.isEmpty,
               let hydrated = try? await SoundCloudAPI.shared.getPlaylistTracks(playlist, ids: unresolved) {
                for track in hydrated { tracksByID[track.id] = track }
            }
            guard !Task.isCancelled, collections[collectionID] != nil else { return }
            if current.title != playlist.title || current.artworkURL != playlist.displayArtworkURL {
                current.title = playlist.title
                current.artworkURL = playlist.displayArtworkURL ?? current.artworkURL
                var updated = collections
                updated[collectionID] = current
                storeCollections(updated)
            }
            applySync(collectionID: collectionID, memberIDs: ids, tracksByID: tracksByID, authoritative: true)
        }
    }

    // MARK: - Transfers

    private func resolveStreamURL(for transcodingURL: URL) async throws -> URL {
        do {
            return try await SoundCloudRequestEnvironment.systemInitiated {
                try await SoundCloudAPI.shared.getStreamURL(forTranscodingURL: transcodingURL)
            }
        } catch SoundCloudGatewayError.backgroundPaused(let until) {
            scheduleTrafficSafetyResume(at: until)
            throw DownloadError.trafficStopped(statusCode: 429, until: until)
        } catch SoundCloudGatewayError.endpointCoolingDown(_, let until) {
            scheduleTrafficSafetyResume(at: until)
            throw DownloadError.trafficStopped(statusCode: 429, until: until)
        } catch APIError.rateLimited(let resetAt) {
            let until = resetAt ?? Date(timeIntervalSinceNow: 60 * 60)
            scheduleTrafficSafetyResume(at: until)
            throw DownloadError.trafficStopped(statusCode: 429, until: until)
        } catch APIError.temporarilyBlocked(let until, let statusCode) {
            scheduleTrafficSafetyResume(at: until)
            throw DownloadError.trafficStopped(statusCode: statusCode, until: until)
        } catch APIError.forbidden {
            throw DownloadError.previewOnly
        }
    }

    private func beginTransfer(entry: DownloadEntry) {
        let track = entry.track
        guard activeResolutionTasks[track.id] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            guard let source = self.chooseSource(for: track) else {
                self.activeResolutionTasks[track.id] = nil
                self.fail(trackId: track.id, reason: DownloadError.unsupportedContainer.errorDescription!)
                return
            }
            do {
                self.pendingSourceFingerprints[track.id] = Self.sourceFingerprint(source.transcoding)
                let resolvedURL = try await self.resolveStreamURL(for: source.transcoding.url)
                try Task.checkCancellation()
                self.activeResolutionTasks[track.id] = nil
                if source.isHLS {
                    self.beginAssembly(trackId: track.id, playlistURL: resolvedURL)
                } else {
                    self.beginProgressiveDownload(trackId: track.id, url: resolvedURL, transcoding: source.transcoding)
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.activeResolutionTasks[track.id] = nil
                if case DownloadError.trafficStopped(_, let until) = error {
                    self.requeueAfterRateLimit(track.id, until: until)
                    return
                }
                self.fail(trackId: track.id, reason: error.localizedDescription)
            }
        }
        activeResolutionTasks[track.id] = task
    }

    private func beginProgressiveDownload(trackId: String, url: URL, transcoding: Transcoding) {
        guard entries[trackId] != nil else { return }
        guard (try? SoundCloudGateway.shared.admitMediaURL(url)) != nil else {
            fail(trackId: trackId, reason: SoundCloudGatewayError.untrustedDestination(url.host ?? "(missing)").localizedDescription)
            return
        }
        pendingFileExtensions[trackId] = DownloadSourceSelection.fileExtension(for: transcoding)
        let task = session.downloadTask(with: url)
        task.taskDescription = trackId
        task.priority = entries[trackId]?.isExplicit == true
            ? URLSessionTask.defaultPriority
            : URLSessionTask.lowPriority
        activeDownloadTasks[trackId] = task
        setState(.downloading(progress: 0), for: trackId)
        task.resume()
    }

    private func beginAssembly(trackId: String, playlistURL: URL) {
        guard activeAssemblyTasks[trackId] == nil,
              let accountID = activeAccountID,
              SubscriptionService.shared.authenticatedAccountID == accountID else { return }
        let directory = DownloadStoragePolicy.accountStagingDirectory(
            root: downloadsRootDirectory,
            accountID: accountID
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setState(.downloading(progress: 0), for: trackId)
        let task = Task { [weak self] in
            do {
                let assembled = try await DownloadHLSAssembler.assemble(
                    playlistURL: playlistURL,
                    scratchDirectory: directory,
                    trackId: trackId
                ) { fraction in
                    Task { @MainActor in
                        self?.updateProgress(trackId: trackId, fraction: fraction)
                    }
                }
                await MainActor.run {
                    self?.finishTransfer(trackId: trackId, stagedFile: assembled)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.activeAssemblyTasks[trackId] = nil
                    self?.admitFromQueueIfPossible()
                }
            } catch {
                await MainActor.run {
                    self?.fail(trackId: trackId, reason: error.localizedDescription)
                }
            }
        }
        activeAssemblyTasks[trackId] = task
    }

    private func finishTransfer(trackId: String, stagedFile: URL, verifiedAccount: Bool = false) {
        guard entries[trackId] != nil else {
            try? FileManager.default.removeItem(at: stagedFile)
            return
        }
        guard let accountID = SubscriptionService.shared.authenticatedAccountID else {
            guard !verifiedAccount else {
                try? FileManager.default.removeItem(at: stagedFile)
                fail(trackId: trackId, reason: "Couldn't confirm your SoundCloud account. Sign in again to finish this download.")
                return
            }
            Task { [weak self] in
                await SubscriptionService.shared.verifyNow()
                self?.finishTransfer(trackId: trackId, stagedFile: stagedFile, verifiedAccount: true)
            }
            return
        }
        guard activeAccountID == accountID else {
            try? FileManager.default.removeItem(at: stagedFile)
            fail(trackId: trackId, reason: "Sign in again to finish this download.")
            return
        }
        let stagedExtension = stagedFile.pathExtension
        let ext = pendingFileExtensions.removeValue(forKey: trackId)
            ?? (stagedExtension.isEmpty ? nil : stagedExtension)
            ?? entries[trackId].flatMap { chooseSource(for: $0.track) }.map { DownloadSourceSelection.fileExtension(for: $0.transcoding) }
            ?? "audio"
        let key: SymmetricKey
        switch DownloadVault.keyResult(for: accountID) {
        case .success(let found):
            key = found
        case .failure(let status):
            try? FileManager.default.removeItem(at: stagedFile)
            fail(trackId: trackId, reason: "Couldn't create the download key in the keychain (\(status)).")
            return
        }
        let directory = accountDirectory(for: accountID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let finalName = "\(trackId).sctv"
        let finalURL = directory.appendingPathComponent(finalName)
        let replacementURL = directory.appendingPathComponent("\(trackId).replacement.\(UUID().uuidString).sctv")
        activeDownloadTasks[trackId] = nil
        activeAssemblyTasks[trackId] = nil

        Task { [weak self] in
            let succeeded = await Task.detached(priority: .utility) { () -> Bool in
                defer { try? FileManager.default.removeItem(at: stagedFile) }
                do {
                    try DownloadVault.encryptFile(at: stagedFile, to: replacementURL, using: key)
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: replacementURL)
                    } else {
                        try FileManager.default.moveItem(at: replacementURL, to: finalURL)
                    }
                    return true
                } catch {
                    try? FileManager.default.removeItem(at: replacementURL)
                    return false
                }
            }.value
            guard let self else { return }
            if succeeded {
                self.completeFinishedTransfer(
                    trackId: trackId,
                    finalName: finalName,
                    finalURL: finalURL,
                    accountID: accountID,
                    fileExtension: ext
                )
            } else {
                self.fail(trackId: trackId, reason: "Could not finalize the download.")
            }
        }
    }

    private func completeFinishedTransfer(
        trackId: String,
        finalName: String,
        finalURL: URL,
        accountID: String,
        fileExtension ext: String
    ) {
        guard var entry = entries[trackId], SubscriptionService.shared.authenticatedAccountID == accountID else {
            if entries[trackId] == nil { try? FileManager.default.removeItem(at: finalURL) }
            return
        }
        entry.fileName = finalName
        entry.fileSize = fileSize(at: finalURL)
        entry.encryptionAccountID = accountID
        entry.originalFileExtension = ext
        entry.sourceFingerprint = pendingSourceFingerprints.removeValue(forKey: trackId)
        entry.lastPlayedAt = Date()
        entries[trackId] = entry

        resumeDataStore[trackId] = nil
        clearResumeDataFile(for: trackId)

        setState(.downloaded, for: trackId)
        persistIndex()
        refreshUsedBytes()
        completeQualityMigrationIfNeeded(trackId: trackId)
        admitFromQueueIfPossible()
        optimiseStorageIfNeeded()
        scheduleIntelligenceForDownloadedEntry(entry)
    }

    // MARK: - Intelligence

    private func scheduleIntelligenceForDownloadedEntry(_ entry: DownloadEntry) {
        scheduleIntelligence(for: entry.track)
    }

    private func resumeDownloadedIntelligenceWork() {
        guard !AutomaticAnalysisEligibility.isSuppressedForFixtures,
              SettingsStore.shared.analyseMusicOnDevice else { return }
        let trackIds = entries.values
            .filter(\.isDownloaded)
            .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
            .map(\.track.id)
        let localTracks = Dictionary(
            LocalMusicLibrary.shared.allTracks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let localIds = localTracks.keys.filter { entries[$0] == nil }.sorted()
        AutomaticAnalysisScheduler.shared.resumeBacklog(trackIds: trackIds + localIds) { trackId in
            if let candidate = await DownloadManager.shared.backlogCandidate(trackId: trackId) { return candidate }
            guard let track = localTracks[trackId],
                  let url = LocalMusicLibrary.readyFileURL(for: track) else { return nil }
            return AnalysisBacklogCandidate(track: track, transcoding: track.mixSource, localFileURL: url)
        }
    }

    func backlogCandidate(trackId: String) -> AnalysisBacklogCandidate? {
        guard let entry = entries[trackId], entry.isDownloaded, isLocallyAvailable(trackId: trackId) else { return nil }
        return AnalysisBacklogCandidate(track: entry.track, transcoding: chooseSource(for: entry.track)?.transcoding)
    }

    private func scheduleIntelligence(for track: Track) {
        AutomaticAnalysisScheduler.shared.schedule(
            track,
            trigger: .downloaded,
            localAudio: Self.localAudioProvider(for: track.id),
            transcoding: chooseSource(for: track)?.transcoding
        )
    }

    func scheduleSetlistScan(for track: Track, whilePlaying: Bool) {
        guard DeckIdentityResolver.isLikelyMix(track) else { return }
        AutomaticAnalysisScheduler.shared.enqueueBackground(
            key: "setlist.\(track.id)",
            pausesDuringPlayback: !whilePlaying,
            operation: Self.setlistScanOperation(for: track)
        )
    }

    nonisolated static func setlistScanOperation(for track: Track) -> @Sendable () async -> Void {
        let provider = localAudioProvider(for: track.id)
        return {
            guard await SetlistIntelligenceStore.shared.hasPendingBackgroundScan(for: track) else { return }
            #if os(macOS) || os(tvOS)
            guard let lease = await provider() else { return }
            await SetlistIntelligenceStore.shared.analyze(track: track, localFileURL: lease.url)
            lease.release()
            #else
            _ = provider
            await SetlistIntelligenceStore.shared.analyze(track: track, localFileURL: nil)
            #endif
        }
    }

    // MARK: - State bookkeeping

    private func lastKnownProgress(_ trackId: String) -> Double {
        switch states[trackId] {
        case .downloading, .paused: return progressObjects[trackId]?.fraction ?? 0
        default: return 0
        }
    }

    private func setState(_ state: DownloadState, for trackId: String) {
        switch state {
        case .downloading(let fraction):
            storeFraction(fraction, for: trackId)
            if case .downloading = states[trackId] { return }
            states[trackId] = .downloading(progress: 0)
        case .paused(let fraction):
            storeFraction(fraction, for: trackId)
            states[trackId] = state
        default:
            storeFraction(0, for: trackId)
            states[trackId] = state
        }
    }

    private func updateProgress(trackId: String, fraction: Double) {
        let clamped = min(1, max(0, fraction))
        switch states[trackId] {
        case .downloaded:
            return
        case .downloading:
            let current = progressObjects[trackId]?.fraction ?? 0
            if abs(clamped - current) < 0.01 && clamped < 1 { return }
            storeFraction(clamped, for: trackId)
        default:
            setState(.downloading(progress: clamped), for: trackId)
        }
    }

    private func fail(trackId: String, reason: String) {
        activeResolutionTasks[trackId] = nil
        activeDownloadTasks[trackId] = nil
        activeAssemblyTasks[trackId] = nil
        pendingSourceFingerprints[trackId] = nil
        if qualityMigrationTrackID == trackId, entries[trackId]?.isDownloaded == true {
            qualityMigrationTrackID = nil
            setState(.downloaded, for: trackId)
            startNextQualityMigrationIfPossible()
        } else {
            setState(.failed(reason: reason), for: trackId)
        }
        admitFromQueueIfPossible()
    }

    private func startNextQualityMigrationIfPossible() {
        guard qualityMigrationTrackID == nil else { return }
        while !qualityMigrationQueue.isEmpty {
            let trackID = qualityMigrationQueue.removeFirst()
            guard entries[trackID]?.isDownloaded == true else { continue }
            qualityMigrationTrackID = trackID
            setState(.queued, for: trackID)
            if !pendingQueue.contains(trackID) { pendingQueue.append(trackID) }
            admitFromQueueIfPossible()
            return
        }
    }

    private func completeQualityMigrationIfNeeded(trackId: String) {
        guard qualityMigrationTrackID == trackId else { return }
        qualityMigrationTrackID = nil
        startNextQualityMigrationIfPossible()
    }

    private static func sourceFingerprint(_ transcoding: Transcoding) -> String {
        [
            transcoding.preset ?? "",
            transcoding.quality ?? "",
            transcoding.format.protocol ?? "",
            transcoding.format.mimeType ?? "",
            String(transcoding.bitrate),
        ].joined(separator: "|")
    }

    private func urgency(of trackId: String) -> HeavyWorkUrgency {
        entries[trackId]?.isExplicit == true && qualityMigrationTrackID != trackId ? .user : .background
    }

    private func settleBackgroundSlot(now: Date) -> Bool {
        let active = Set(activeResolutionTasks.keys)
            .union(activeDownloadTasks.keys)
            .union(activeAssemblyTasks.keys)
            .filter { urgency(of: $0) == .background }
        if !backgroundInFlight.subtracting(active).isEmpty {
            heavyPacer.finished(now: now, policy: .downloads, random: Double.random(in: 0...1))
        }
        backgroundInFlight = active
        return !active.isEmpty
    }

    private func scheduleHeavyWake(at date: Date) {
        let delay = max(0.5, date.timeIntervalSinceNow)
        scheduler.submit(
            queue: Self.schedulerQueue,
            key: "downloads.pacing",
            delivery: .latest,
            delay: .seconds(delay)
        ) { [weak self] in
            self?.admitFromQueueIfPossible()
        }
    }

    private func requeueAfterRateLimit(_ trackId: String, until: Date) {
        heavyPacer.rateLimited(
            now: Date(),
            retryAfter: until.timeIntervalSinceNow,
            policy: .downloads,
            random: Double.random(in: 0...1)
        )
        UserDefaults.standard.set(heavyPacer.encoded(), forKey: Self.pacingDefaultsKey)
        pendingSourceFingerprints[trackId] = nil
        guard entries[trackId] != nil else { return }
        setState(.queued, for: trackId)
        pendingQueue.removeAll { $0 == trackId }
        pendingQueue.insert(trackId, at: 0)
        admitFromQueueIfPossible()
    }

    private func admitFromQueueIfPossible() {
        let now = Date()
        var backgroundBusy = settleBackgroundSlot(now: now)
        while (activeResolutionTasks.count + activeDownloadTasks.count + activeAssemblyTasks.count) < Self.maxConcurrentTransfers,
              !pendingQueue.isEmpty {
            guard canTransferNow() else {
                refreshWaitingReason()
                return
            }
            pendingQueue.removeAll { entries[$0] == nil || states[$0] != .queued }
            let candidates = backgroundBusy ? pendingQueue.filter { urgency(of: $0) == .user } : pendingQueue
            guard let trackId = HeavyWorkOrder.next(candidates, urgency: { self.urgency(of: $0) }) else { return }
            let urgencyValue = urgency(of: trackId)
            let conditions = AutomaticAnalysisEligibility.heavyWorkConditions(isOnCellular: isOnCellular)
            switch heavyPacer.gate(urgencyValue, now: now, conditions: conditions, policy: .downloads) {
            case .go:
                break
            case .wait(let until):
                scheduleHeavyWake(at: until)
                return
            case .paused(_, let until):
                scheduleHeavyWake(at: until ?? now.addingTimeInterval(Self.pausedRecheck))
                return
            }
            pendingQueue.removeAll { $0 == trackId }
            guard let entry = entries[trackId], entitlementDenial(for: entry.track) == nil else { continue }
            if urgencyValue == .background {
                backgroundInFlight.insert(trackId)
                backgroundBusy = true
            }
            if let resumeData = resumeDataStore[trackId] {
                let task = session.downloadTask(withResumeData: resumeData)
                task.taskDescription = trackId
                activeDownloadTasks[trackId] = task
                setState(.downloading(progress: lastKnownProgress(trackId)), for: trackId)
                task.resume()
            } else {
                beginTransfer(entry: entry)
            }
        }
    }

    private func canTransferNow() -> Bool {
        guard !AutomaticAnalysisEligibility.isSuppressedForFixtures else { return false }
        guard SubscriptionService.shared.denial(for: .downloads) == nil else { return false }
        guard hasConnectivity else { return false }
        guard (try? SoundCloudAPI.shared.enforceTrafficSafety()) != nil else { return false }
        guard hasStorageHeadroom() else { return false }
        return isOnUnmeteredNetwork || allowsCellularDownloads
    }

    private func hasStorageHeadroom() -> Bool {
        OptimiseStoragePolicy.admitsNewTransfers(availableBytes: Self.availableDiskSpace(near: downloadsRootDirectory))
    }

    private func scheduleTrafficSafetyResume(at date: Date) {
        let delay = max(0, date.timeIntervalSinceNow)
        scheduler.submit(
            queue: Self.schedulerQueue,
            key: "downloads.traffic-safety",
            delivery: .latest,
            delay: .seconds(delay)
        ) { [weak self] in
            guard let self else { return }
            self.handlePolicyChange()
        }
    }

    private func refreshWaitingReason() {
        let reason: String?
        if let denial = SubscriptionService.shared.denial(for: .downloads) {
            reason = denial.errorDescription
        } else if !hasConnectivity {
            reason = "Waiting for a connection"
        } else if (try? SoundCloudAPI.shared.enforceTrafficSafety()) == nil {
            reason = "Paused by SoundCloud rate limiting"
        } else if !isOnUnmeteredNetwork && !allowsCellularDownloads {
            reason = "Waiting for Wi-Fi"
        } else if !hasStorageHeadroom() {
            reason = "Waiting for free storage"
        } else {
            reason = nil
        }
        if waitingReason != reason { waitingReason = reason }
    }

    private func handlePolicyChange() {
        refreshWaitingReason()
        if canTransferNow() {
            let resumable = pausedByPolicy
            pausedByPolicy.removeAll()
            for trackId in resumable { resume(trackId: trackId) }
            admitFromQueueIfPossible()
        } else {
            pauseAllActiveTransfers(dueToPolicy: true)
        }
    }

    private func pauseDeniedTransfers(tier: SubscriptionService.Tier, verification: SubscriptionService.VerificationStatus) {
        let subscription = SubscriptionService.shared
        let signedIn = subscription.isSignedInForEntitlements || subscription.hasAuthenticatedSession
        let active = Set(Array(activeResolutionTasks.keys) + Array(activeDownloadTasks.keys) + Array(activeAssemblyTasks.keys))
        for trackId in active {
            guard let entry = entries[trackId],
                  SoundCloudEntitlements.trackDenial(
                    for: entry.track, feature: .downloads, signedIn: signedIn,
                    tier: tier, verification: verification
                  ) != nil else { continue }
            pause(trackId: trackId)
        }
    }

    private func pauseAllActiveTransfers(dueToPolicy: Bool) {
        for trackId in Array(activeResolutionTasks.keys) + Array(activeDownloadTasks.keys) + Array(activeAssemblyTasks.keys) {
            if dueToPolicy { pausedByPolicy.insert(trackId) }
            pause(trackId: trackId)
        }
    }

    private func observeSubscriptionState() {
        Publishers.CombineLatest(SubscriptionService.shared.$tier, SubscriptionService.shared.$verification)
            .sink { [weak self] tier, verification in
                guard let self else { return }
                self.handlePolicyChange()
                self.pauseDeniedTransfers(tier: tier, verification: verification)
                Task { @MainActor [weak self] in self?.evaluateEntitlementDeletionSweep() }
            }
            .store(in: &cancellables)

        SubscriptionService.shared.$authenticatedAccountID
            .removeDuplicates()
            .sink { [weak self] accountID in
                guard let self else { return }
                if let accountID {
                    self.unlockAccountVault(accountID)
                } else {
                    self.lockAccountVault()
                }
            }
            .store(in: &cancellables)
    }

    private func evaluateEntitlementDeletionSweep() {
        guard !entries.isEmpty || !collections.isEmpty else { return }
        let subscription = SubscriptionService.shared
        switch Self.entitlementSweep(
            verification: subscription.verification,
            notSubscribedSince: subscription.notSubscribedSince,
            lastConfirmedAt: subscription.lastConfirmedAt,
            now: Date()
        ) {
        case .removeAll:
            removeAll()
        case .removeRestricted:
            let denied = entries.values.filter { entitlementDenial(for: $0.track) != nil }.map(\.track.id)
            for trackID in denied { removeDownload(.track(trackID)) }
        case .keep:
            break
        }
    }

    nonisolated static func entitlementSweep(
        verification: SubscriptionService.VerificationStatus,
        notSubscribedSince: Date?,
        lastConfirmedAt: Date?,
        now: Date
    ) -> DownloadEntitlementSweep {
        switch verification {
        case .verifiedNotSubscribed:
            if let lastConfirmedAt, now.timeIntervalSince(lastConfirmedAt) >= SubscriptionService.offlineReconfirmLimit {
                return .removeAll
            }
            guard let notSubscribedSince,
                  now.timeIntervalSince(notSubscribedSince) >= SubscriptionService.deletionDelay else { return .keep }
            return .removeRestricted
        case .unverifiable:
            guard let lastConfirmedAt,
                  now.timeIntervalSince(lastConfirmedAt) >= SubscriptionService.offlineReconfirmLimit else { return .keep }
            return .removeAll
        case .verified:
            return .removeRestricted
        }
    }

    // MARK: - Maintenance and storage

    private func startMaintenanceLoop() {
        scheduler.registerPeriodic(
            id: "downloads.maintenance",
            scope: "downloads",
            interval: .seconds(Self.maintenanceInterval)
        ) { [weak self] in
            await self?.runMaintenance()
        }
    }

    private func runMaintenance() async {
        sweepOrphanedTransferArtifacts()
        evaluateEntitlementDeletionSweep()
        optimiseStorageIfNeeded()
        refreshUsedBytes()
        let now = Date()
        guard SoundCloudGateway.shared.isApplicationForeground,
              now.timeIntervalSince(lastMaintenanceCollectionSync ?? .distantPast) >= Self.maintenanceCollectionSyncInterval else { return }
        lastMaintenanceCollectionSync = now
        SoundCloudRequestEnvironment.$intent.withValue(.autonomous) {
            scheduleCollectionSync()
        }
    }

    private var lastMaintenanceCollectionSync: Date?
    private static let maintenanceCollectionSyncInterval: TimeInterval = 6 * 60 * 60

    private func optimiseStorageIfNeeded() {
        guard optimiseStorage, isIndexReady,
              let available = Self.availableDiskSpace(near: downloadsRootDirectory) else { return }
        let candidates = entries.values
            .filter(\.isDownloaded)
            .map { OptimiseStoragePolicy.Candidate(id: $0.track.id, bytes: $0.fileSize, lastPlayedAt: $0.lastPlayedAt) }
        let victims = OptimiseStoragePolicy.victims(
            candidates: candidates,
            availableBytes: available,
            minimumKeptBytes: optimiseStorageMinimumBytes
        )
        guard !victims.isEmpty else { return }
        var updated = collections
        for trackID in victims {
            guard let entry = entries[trackID] else { continue }
            updated = DownloadCollectionSync.exclusionsAfterRemoving(
                trackID: trackID,
                from: updated,
                memberOf: entry.collectionIDs
            )
            deleteEntry(trackID, persist: false)
        }
        storeCollections(updated)
        persistIndex()
        refreshUsedBytes()
        Log.download.info("Optimise Storage removed \(victims.count, privacy: .public) downloads")
    }

    private func refreshUsedBytes() {
        guard let accountID = activeAccountID else {
            if usedBytes != 0 { usedBytes = 0 }
            return
        }
        let directories = [accountDirectory(for: accountID), transferStagingDirectory]
        usedBytesTask?.cancel()
        usedBytesTask = Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) {
                DownloadStoragePolicy.onDiskBytes(in: directories)
            }.value
            guard !Task.isCancelled, let self, self.activeAccountID == accountID else { return }
            if self.usedBytes != bytes { self.usedBytes = bytes }
        }
    }

    private func sweepOrphanedTransferArtifacts() {
        let activeTrackIDs = Set(activeAssemblyTasks.keys)
            .union(activeDownloadTasks.keys)
            .union(activeResolutionTasks.keys)
        var directories = [downloadsRootDirectory, transferStagingDirectory]
        if let activeAccountID {
            directories.append(accountDirectory(for: activeAccountID))
            directories.append(DownloadStoragePolicy.accountStagingDirectory(
                root: downloadsRootDirectory,
                accountID: activeAccountID
            ))
        }
        DownloadStoragePolicy.sweepTemporaryArtifacts(
            in: directories,
            activeTrackIDs: activeTrackIDs
        )
    }

    private static func availableDiskSpace(near directory: URL) -> Int64? {
        #if !os(tvOS)
        if let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        #endif
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path) else {
            return nil
        }
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value
    }

    // MARK: - Account vault

    func lockAccountVault() {
        vaultUnlockTask?.cancel()
        vaultUnlockTask = nil
        for task in collectionSyncTasks.values { task.cancel() }
        collectionSyncTasks.removeAll()
        pauseAllActiveTransfers(dueToPolicy: true)
        DownloadStoragePolicy.purgePlaintext(
            legacyRoot: legacyPlaintextDirectory,
            temporaryRoot: temporaryPlaintextDirectory
        )
        isIndexReady = false
        entries = [:]
        collections = [:]
        states = [:]
        for object in progressObjects.values { object.fraction = 0 }
        usedBytes = 0
        SettingsStore.shared.lockAccount()
    }

    func purgeCachedDownloads(accountID requestedAccountID: String?) async {
        let accountID = requestedAccountID ?? activeAccountID
        let ownsActiveRuntime = accountID == nil || activeAccountID == accountID

        if ownsActiveRuntime {
            vaultUnlockTask?.cancel()
            vaultUnlockTask = nil
            scheduler.cancelPending(keyPrefix: "downloads.traffic-safety", in: [Self.schedulerQueue])
            for task in activeResolutionTasks.values { task.cancel() }
            for task in activeDownloadTasks.values { task.cancel() }
            for task in activeAssemblyTasks.values { task.cancel() }
            for task in collectionSyncTasks.values { task.cancel() }
            for task in await session.allTasks { task.cancel() }
            activeResolutionTasks.removeAll()
            activeDownloadTasks.removeAll()
            activeAssemblyTasks.removeAll()
            collectionSyncTasks.removeAll()
            resumeDataStore.removeAll()
            pendingFileExtensions.removeAll()
            pendingSourceFingerprints.removeAll()
            pendingQueue.removeAll()
            pausedByPolicy.removeAll()
            qualityMigrationQueue.removeAll()
            qualityMigrationTrackID = nil
            indexWriter.invalidate()
            isIndexReady = false
            entries = [:]
            collections = [:]
            states = [:]
            usedBytes = 0
        }

        if let accountID {
            DownloadStoragePolicy.migrateLegacyStorage(
                root: downloadsRootDirectory,
                accountID: accountID
            )
            DownloadStoragePolicy.purgeAccountStorage(
                downloadsRoot: downloadsRootDirectory,
                decryptedRoot: legacyPlaintextDirectory,
                accountID: accountID
            )
            DownloadVault.forget(accountID: accountID)
            if activeAccountID == accountID { activeAccountID = nil }
        } else {
            try? FileManager.default.removeItem(at: downloadsRootDirectory)
            activeAccountID = nil
        }
        DownloadStoragePolicy.purgePlaintext(
            legacyRoot: legacyPlaintextDirectory,
            temporaryRoot: temporaryPlaintextDirectory
        )

        if ownsActiveRuntime {
            try? FileManager.default.removeItem(at: transferStagingDirectory)
        }
        try? FileManager.default.createDirectory(
            at: downloadsRootDirectory.appendingPathComponent(
                DownloadStoragePolicy.accountsDirectoryName,
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(at: transferStagingDirectory, withIntermediateDirectories: true)
    }

    private nonisolated static func loadIndex(from url: URL) -> [String: DownloadEntry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: DownloadEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persistIndex() {
        guard let accountID = SubscriptionService.shared.authenticatedAccountID,
              activeAccountID == accountID else { return }
        try? FileManager.default.createDirectory(
            at: accountDirectory(for: accountID),
            withIntermediateDirectories: true
        )
        indexWriter.persist(
            entries: entries,
            accountID: accountID,
            destination: encryptedIndexURL(accountID: accountID)
        )
    }

    private func unlockAccountVault(_ accountID: String) {
        if activeAccountID != accountID {
            pauseAllActiveTransfers(dueToPolicy: false)
            indexWriter.invalidate()
            isIndexReady = false
            entries = [:]
            states = [:]
            usedBytes = 0
        }
        activeAccountID = accountID
        let settings = SettingsStore.shared
        settings.unlockAccount(accountID)
        collections = settings.downloadedCollections
        DownloadStoragePolicy.migrateLegacyStorage(
            root: downloadsRootDirectory,
            accountID: accountID
        )
        let accountDirectory = accountDirectory(for: accountID)
        let accountStagingDirectory = DownloadStoragePolicy.accountStagingDirectory(
            root: downloadsRootDirectory,
            accountID: accountID
        )
        try? FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: accountStagingDirectory, withIntermediateDirectories: true)
        sweepOrphanedTransferArtifacts()

        let encryptedURL = encryptedIndexURL(accountID: accountID)
        let legacyURL = accountDirectory.appendingPathComponent(DownloadStoragePolicy.legacyIndexFileName)
        vaultUnlockTask?.cancel()
        vaultUnlockTask = Task.detached(priority: .utility) { [weak self] in
            let hasEncryptedIndex = FileManager.default.fileExists(atPath: encryptedURL.path)
            let encryptedEntries: [String: DownloadEntry]? = {
                guard let sealed = try? Data(contentsOf: encryptedURL),
                      let data = AccountDataVault.open(
                        sealed, accountID: accountID, purpose: "download-index-v1"
                      ) else { return nil }
                return try? JSONDecoder().decode([String: DownloadEntry].self, from: data)
            }()
            guard !Task.isCancelled else { return }

            let migratedLegacy = encryptedEntries == nil
            let decoded = encryptedEntries ?? Self.loadIndex(from: legacyURL)
            let loadedCleanly = encryptedEntries != nil || !hasEncryptedIndex
            guard !Task.isCancelled else { return }

            await self?.adoptLoadedIndex(
                decoded,
                accountID: accountID,
                migratedLegacy: migratedLegacy,
                loadedCleanly: loadedCleanly,
                legacyURL: legacyURL
            )
            guard !Task.isCancelled else { return }
            await self?.encryptLegacyPlaintextDownloads(accountID: accountID)
            await self?.loadPersistedResumeData(accountID: accountID)
            await self?.reconcileExistingTasks()
            #if !os(watchOS)
            await self?.resumeDownloadedIntelligenceWork()
            #endif
            await self?.runMaintenance()
        }
    }

    private func adoptLoadedIndex(
        _ decoded: [String: DownloadEntry],
        accountID: String,
        migratedLegacy: Bool,
        loadedCleanly: Bool,
        legacyURL: URL
    ) {
        guard SubscriptionService.shared.authenticatedAccountID == accountID,
              activeAccountID == accountID else { return }
        var merged = decoded
        for (trackId, entry) in entries where merged[trackId] == nil {
            merged[trackId] = entry
        }

        let settings = SettingsStore.shared
        var changed = merged.count != decoded.count || migratedLegacy
        if loadedCleanly, settings.downloadModelVersion < SettingKeys.DownloadModelVersion.current {
            var migratedCollections = settings.downloadedCollections
            let outcome = DownloadModelMigration.migrate(
                entries: &merged,
                collections: &migratedCollections,
                legacyCollectionIDs: settings.legacyDownloadCollectionIDs
            )
            for trackID in outcome.removedTrackIDs {
                resumeDataStore[trackID] = nil
                clearResumeDataFile(for: trackID)
            }
            storeCollections(migratedCollections)
            settings.completeDownloadModelMigration()
            changed = true
            Log.download.notice(
                "Download model migration kept \(outcome.keptCollectionIDs.count, privacy: .public) collections, dropped \(outcome.droppedCollectionIDs.count, privacy: .public), removed \(outcome.removedTrackIDs.count, privacy: .public) queued tracks"
            )
        }

        entries = merged
        for (trackId, entry) in merged where entry.isDownloaded {
            setState(.downloaded, for: trackId)
        }
        isIndexReady = true
        if migratedLegacy, !decoded.isEmpty {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        if changed { persistIndex() }
        refreshUsedBytes()
    }

    private func encryptLegacyPlaintextDownloads(accountID: String) async {
        guard activeAccountID == accountID else { return }
        let directory = accountDirectory(for: accountID)
        let legacy = entries.values.filter { $0.isDownloaded && $0.encryptionAccountID == nil }
        guard !legacy.isEmpty, let key = DownloadVault.key(for: accountID) else { return }
        for entry in legacy {
            guard let fileName = entry.fileName else { continue }
            let trackID = entry.track.id
            let plaintextURL = directory.appendingPathComponent(fileName)
            let encryptedURL = directory.appendingPathComponent("\(trackID).sctv")
            let fileExtension = plaintextURL.pathExtension
            let succeeded = await Task.detached(priority: .utility) { () -> Bool in
                guard FileManager.default.fileExists(atPath: plaintextURL.path) else { return false }
                do {
                    try DownloadVault.encryptFile(at: plaintextURL, to: encryptedURL, using: key)
                    try? FileManager.default.removeItem(at: plaintextURL)
                    return true
                } catch {
                    return false
                }
            }.value
            guard activeAccountID == accountID, var current = entries[trackID] else { continue }
            if succeeded {
                current.fileName = encryptedURL.lastPathComponent
                current.fileSize = fileSize(at: encryptedURL)
                current.encryptionAccountID = accountID
                current.originalFileExtension = fileExtension.isEmpty ? "audio" : fileExtension
                entries[trackID] = current
            } else {
                deleteEntry(trackID, persist: false)
            }
        }
        persistIndex()
        refreshUsedBytes()
    }

    private func accountDirectory(for accountID: String) -> URL {
        DownloadStoragePolicy.accountDirectory(root: downloadsRootDirectory, accountID: accountID)
    }

    private func encryptedIndexURL(accountID: String) -> URL {
        accountDirectory(for: accountID)
            .appendingPathComponent(DownloadStoragePolicy.accountIndexFileName)
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func resumeDataFileURL(for trackId: String) -> URL? {
        guard let activeAccountID else { return nil }
        return accountDirectory(for: activeAccountID).appendingPathComponent("\(trackId).resumedata")
    }

    private func persistResumeData(_ data: Data, for trackId: String) {
        resumeDataStore[trackId] = data
        guard let url = resumeDataFileURL(for: trackId) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func clearResumeDataFile(for trackId: String) {
        guard let url = resumeDataFileURL(for: trackId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func loadPersistedResumeData(accountID: String) async {
        guard activeAccountID == accountID,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: accountDirectory(for: accountID),
                includingPropertiesForKeys: nil
              ) else { return }
        for url in contents where url.pathExtension == "resumedata" {
            let trackId = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url) else { continue }
            if entries[trackId] == nil || entries[trackId]?.isDownloaded == true {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            resumeDataStore[trackId] = data
        }
    }

    private func reconcileExistingTasks() async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let trackId = task.taskDescription,
                  let downloadTask = task as? URLSessionDownloadTask,
                  downloadTask.state == .running || downloadTask.state == .suspended,
                  activeDownloadTasks[trackId] == nil else { continue }
            guard let entry = entries[trackId], !entry.isDownloaded || qualityMigrationTrackID == trackId else {
                downloadTask.cancel()
                continue
            }
            activeDownloadTasks[trackId] = downloadTask
            pendingQueue.removeAll { $0 == trackId }
            if downloadTask.state == .suspended { downloadTask.resume() }
            let expected = downloadTask.countOfBytesExpectedToReceive
            let received = downloadTask.countOfBytesReceived
            let fraction = expected > 0 ? Double(received) / Double(expected) : 0
            setState(.downloading(progress: fraction), for: trackId)
        }

        for (trackId, entry) in entries where !entry.isDownloaded && !hasActiveWork(trackId) {
            switch states[trackId] {
            case .downloading, .paused:
                continue
            default:
                setState(.queued, for: trackId)
                if !pendingQueue.contains(trackId) { pendingQueue.append(trackId) }
            }
        }
        admitFromQueueIfPossible()
    }
}

extension DownloadManager: CollectionPolicyApplier {}

// MARK: - Vault

enum DownloadVault {
    private static let service = "red.forbes.sounding.download-vault"
    static let magic = Data("SCTVENC1".utf8)
    static let chunkSize = 1_048_576

    enum VaultError: Error {
        case keyUnavailable
        case malformedFile
        case writeFailed
    }

    struct KeychainStatus: Error, CustomStringConvertible {
        let code: OSStatus
        var description: String {
            let message = SecCopyErrorMessageString(code, nil) as String? ?? "unknown"
            return "\(code): \(message)"
        }
    }

    static func keyResult(for accountID: String) -> Result<SymmetricKey, KeychainStatus> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        switch SoundingKeychain.copyData(query) {
        case .present(let data):
            guard data.count == 32 else { return .failure(KeychainStatus(code: errSecDecode)) }
            return .success(SymmetricKey(data: data))
        case .failed(let status):
            return .failure(KeychainStatus(code: status))
        case .absent:
            break
        }
        if let key = key(for: accountID, createIfMissing: true) { return .success(key) }
        var probe: CFTypeRef?
        return .failure(KeychainStatus(code: SoundingKeychain.copyMatching(query, &probe)))
    }

    static func key(for accountID: String, createIfMissing: Bool = true) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        switch SoundingKeychain.copyData(query) {
        case .present(let data):
            guard data.count == 32 else { return nil }
            return SymmetricKey(data: data)
        case .failed:
            return nil
        case .absent:
            break
        }
        guard createIfMissing, SoundingKeychain.isDurable else { return nil }

        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard SoundingKeychain.add(add) == errSecSuccess else {
            return key(for: accountID, createIfMissing: false)
        }
        return SymmetricKey(data: bytes)
    }

    static func forget(accountID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
        SoundingKeychain.delete(query)
    }

    static func encryptFile(at source: URL, to destination: URL, using key: SymmetricKey) throws {
        let temporary = destination.appendingPathExtension("encrypting")
        try? FileManager.default.removeItem(at: temporary)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw VaultError.writeFailed
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: temporary)
        defer {
            try? input.close()
            try? output.close()
        }
        do {
            try output.write(contentsOf: magic)
            while true {
                let chunk = try readUpTo(chunkSize, from: input)
                if chunk.isEmpty { break }
                let sealed = try AES.GCM.seal(chunk, using: key)
                guard let combined = sealed.combined else { throw VaultError.writeFailed }
                try output.write(contentsOf: encodedLength(combined.count))
                try output.write(contentsOf: combined)
                if chunk.count < chunkSize { break }
            }
            try output.synchronize()
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            #if os(iOS) || os(tvOS) || os(watchOS)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            #endif
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func decryptFile(at source: URL, to destination: URL, using key: SymmetricKey) throws {
        let reader = try EncryptedAudioReader(fileURL: source, key: key)
        let temporary = destination.appendingPathExtension("decrypting")
        try? FileManager.default.removeItem(at: temporary)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw VaultError.writeFailed
        }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        do {
            var offset: Int64 = 0
            while offset < reader.length {
                let data = try reader.read(offset: offset, length: chunkSize)
                guard !data.isEmpty else { throw VaultError.malformedFile }
                try output.write(contentsOf: data)
                offset += Int64(data.count)
            }
            try output.synchronize()
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func encodedLength(_ count: Int) -> Data {
        let value = UInt32(count)
        return Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    static func decodedLength(_ data: Data) -> Int? {
        guard data.count == 4 else { return nil }
        return Int(data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }

    static func readUpTo(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else { break }
            result.append(part)
        }
        return result
    }

    static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        let data = try readUpTo(count, from: handle)
        guard data.count == count else { throw VaultError.malformedFile }
        return data
    }
}

struct VaultChunkLayout: Equatable, Sendable {
    struct Chunk: Equatable, Sendable {
        let fileOffset: Int64
        let sealedLength: Int
        let plaintextOffset: Int64

        var plaintextLength: Int { sealedLength - VaultChunkLayout.sealOverhead }
    }

    static let headerLength = Int64(DownloadVault.magic.count)
    static let lengthPrefix = 4
    static let sealOverhead = 12 + 16
    static let plaintextChunkLength = DownloadVault.chunkSize
    static let fullSealedLength = plaintextChunkLength + sealOverhead
    static let fullRecordLength = Int64(lengthPrefix + fullSealedLength)

    let plaintextLength: Int64
    let chunkCount: Int
    let isFixed: Bool
    private let lastSealedLength: Int
    private let index: [Chunk]

    static func fixed(encryptedLength: Int64) -> VaultChunkLayout? {
        let body = encryptedLength - headerLength
        guard body >= 0 else { return nil }
        let fullRecords = body / fullRecordLength
        let remainder = body % fullRecordLength
        let count: Int
        let lastSealed: Int
        if remainder == 0 {
            count = Int(fullRecords)
            lastSealed = fullSealedLength
        } else {
            guard remainder > Int64(lengthPrefix + sealOverhead) else { return nil }
            count = Int(fullRecords) + 1
            lastSealed = Int(remainder) - lengthPrefix
        }
        let plaintext = count == 0
            ? 0
            : Int64(count - 1) * Int64(plaintextChunkLength) + Int64(lastSealed - sealOverhead)
        return VaultChunkLayout(
            plaintextLength: plaintext,
            chunkCount: count,
            isFixed: true,
            lastSealedLength: lastSealed,
            index: []
        )
    }

    static func indexed(_ chunks: [Chunk]) -> VaultChunkLayout? {
        var expectedPlaintext: Int64 = 0
        for chunk in chunks {
            guard chunk.plaintextOffset == expectedPlaintext, chunk.plaintextLength > 0 else { return nil }
            expectedPlaintext += Int64(chunk.plaintextLength)
        }
        return VaultChunkLayout(
            plaintextLength: expectedPlaintext,
            chunkCount: chunks.count,
            isFixed: false,
            lastSealedLength: chunks.last?.sealedLength ?? 0,
            index: chunks
        )
    }

    func chunk(at position: Int) -> Chunk {
        guard isFixed else { return index[position] }
        let sealed = position == chunkCount - 1 ? lastSealedLength : Self.fullSealedLength
        return Chunk(
            fileOffset: Self.headerLength + Int64(position) * Self.fullRecordLength,
            sealedLength: sealed,
            plaintextOffset: Int64(position) * Int64(Self.plaintextChunkLength)
        )
    }

    func chunkIndex(containing plaintextOffset: Int64) -> Int? {
        guard plaintextOffset >= 0, plaintextOffset < plaintextLength else { return nil }
        if isFixed { return Int(plaintextOffset / Int64(Self.plaintextChunkLength)) }
        var low = 0
        var high = index.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = index[middle]
            if plaintextOffset < candidate.plaintextOffset {
                high = middle - 1
            } else if plaintextOffset >= candidate.plaintextOffset + Int64(candidate.plaintextLength) {
                low = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }

    func chunkIndices(coveringOffset offset: Int64, length: Int) -> ClosedRange<Int>? {
        guard length > 0, let first = chunkIndex(containing: offset) else { return nil }
        let last = chunkIndex(containing: min(plaintextLength, offset + Int64(length)) - 1) ?? first
        return first...last
    }

    static func load(from handle: FileHandle, encryptedLength: Int64) throws -> VaultChunkLayout {
        try handle.seek(toOffset: 0)
        guard try DownloadVault.readUpTo(DownloadVault.magic.count, from: handle) == DownloadVault.magic else {
            throw DownloadVault.VaultError.malformedFile
        }
        if let fixed = fixed(encryptedLength: encryptedLength), try fixed.validates(against: handle) {
            return fixed
        }
        return try scan(handle, encryptedLength: encryptedLength)
    }

    private func validates(against handle: FileHandle) throws -> Bool {
        guard chunkCount > 0 else { return true }
        for position in Set([0, chunkCount / 2, chunkCount - 1]) {
            let expected = chunk(at: position)
            try handle.seek(toOffset: UInt64(expected.fileOffset))
            let prefix = try DownloadVault.readUpTo(Self.lengthPrefix, from: handle)
            guard DownloadVault.decodedLength(prefix) == expected.sealedLength else { return false }
        }
        return true
    }

    static func scan(_ handle: FileHandle, encryptedLength: Int64) throws -> VaultChunkLayout {
        var chunks: [Chunk] = []
        var fileOffset = headerLength
        var plaintextOffset: Int64 = 0
        while fileOffset < encryptedLength {
            try handle.seek(toOffset: UInt64(fileOffset))
            let prefix = try DownloadVault.readUpTo(lengthPrefix, from: handle)
            guard let sealed = DownloadVault.decodedLength(prefix),
                  sealed > sealOverhead,
                  sealed <= plaintextChunkLength + 64 else {
                throw DownloadVault.VaultError.malformedFile
            }
            let chunk = Chunk(fileOffset: fileOffset, sealedLength: sealed, plaintextOffset: plaintextOffset)
            chunks.append(chunk)
            plaintextOffset += Int64(chunk.plaintextLength)
            fileOffset += Int64(lengthPrefix + sealed)
        }
        guard fileOffset == encryptedLength, let layout = indexed(chunks) else {
            throw DownloadVault.VaultError.malformedFile
        }
        return layout
    }
}

enum VaultLayoutCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var layouts: [String: VaultChunkLayout] = [:]
    private static let capacity = 256

    static func layout(
        for url: URL,
        encryptedLength: Int64,
        modified: Date?,
        build: () throws -> VaultChunkLayout
    ) throws -> VaultChunkLayout {
        let key = "\(url.standardizedFileURL.path)|\(encryptedLength)|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
        lock.lock()
        let cached = layouts[key]
        lock.unlock()
        if let cached { return cached }
        let built = try build()
        lock.lock()
        if layouts.count >= capacity { layouts.removeAll(keepingCapacity: true) }
        layouts[key] = built
        lock.unlock()
        return built
    }

    static func removeAll() {
        lock.lock()
        layouts.removeAll()
        lock.unlock()
    }
}

final class EncryptedAudioReader: PeerContentByteSource, @unchecked Sendable {
    let layout: VaultChunkLayout
    private let handle: FileHandle
    private let key: SymmetricKey
    private let lock = NSLock()
    private var recentChunks: [(position: Int, plaintext: Data)] = []
    private static let recentChunkLimit = 2

    var length: Int64 { layout.plaintextLength }

    init(fileURL: URL, key: SymmetricKey) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let encryptedLength = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes[.modificationDate] as? Date
        let handle = try FileHandle(forReadingFrom: fileURL)
        do {
            layout = try VaultLayoutCache.layout(for: fileURL, encryptedLength: encryptedLength, modified: modified) {
                try VaultChunkLayout.load(from: handle, encryptedLength: encryptedLength)
            }
        } catch {
            try? handle.close()
            throw error
        }
        self.handle = handle
        self.key = key
    }

    deinit {
        try? handle.close()
    }

    func read(offset: Int64, length requested: Int) throws -> Data {
        guard requested > 0, offset >= 0, offset < length else { return Data() }
        let end = min(length, offset + Int64(requested))
        lock.lock()
        defer { lock.unlock() }
        var result = Data()
        result.reserveCapacity(Int(end - offset))
        var cursor = offset
        while cursor < end {
            guard let position = layout.chunkIndex(containing: cursor) else {
                throw DownloadVault.VaultError.malformedFile
            }
            let chunk = layout.chunk(at: position)
            let plaintext = try decryptedChunk(at: position, chunk: chunk)
            let lower = Int(cursor - chunk.plaintextOffset)
            let upper = Int(min(end, chunk.plaintextOffset + Int64(plaintext.count)) - chunk.plaintextOffset)
            guard lower < upper else { throw DownloadVault.VaultError.malformedFile }
            result.append(plaintext.subdata(in: (plaintext.startIndex + lower)..<(plaintext.startIndex + upper)))
            cursor = chunk.plaintextOffset + Int64(upper)
        }
        return result
    }

    private func decryptedChunk(at position: Int, chunk: VaultChunkLayout.Chunk) throws -> Data {
        if let cached = recentChunks.first(where: { $0.position == position }) { return cached.plaintext }
        try handle.seek(toOffset: UInt64(chunk.fileOffset))
        let record = try DownloadVault.readExactly(VaultChunkLayout.lengthPrefix + chunk.sealedLength, from: handle)
        guard DownloadVault.decodedLength(record.prefix(VaultChunkLayout.lengthPrefix)) == chunk.sealedLength else {
            throw DownloadVault.VaultError.malformedFile
        }
        let box = try AES.GCM.SealedBox(combined: record.dropFirst(VaultChunkLayout.lengthPrefix))
        let plaintext = try AES.GCM.open(box, using: key)
        guard plaintext.count == chunk.plaintextLength else { throw DownloadVault.VaultError.malformedFile }
        recentChunks.append((position, plaintext))
        if recentChunks.count > Self.recentChunkLimit { recentChunks.removeFirst() }
        return plaintext
    }
}

final class VaultResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "sounding-vault"
    static let responseSliceLength = 512 * 1024

    let queue = DispatchQueue(label: "red.forbes.sounding.vault.loader")
    private let workQueue = DispatchQueue(
        label: "red.forbes.sounding.vault.loader.work",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let reader: EncryptedAudioReader
    private let contentType: String
    private let trackID: String

    init(reader: EncryptedAudioReader, contentType: String, trackID: String) {
        self.reader = reader
        self.contentType = contentType
        self.trackID = trackID
    }

    static func assetURL(trackID: String, fileExtension: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "track"
        components.path = "/\(trackID).\(fileExtension)"
        return components.url ?? URL(string: "\(scheme)://track/download")!
    }

    static func contentType(forFileExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "public.mp3"
        case "m4a", "mp4": return "public.mpeg-4-audio"
        case "aac": return "public.aac-audio"
        case "flac": return "org.xiph.flac"
        case "ts": return "public.mpeg-2-transport-stream"
        case "wav": return "com.microsoft.waveform-audio"
        default: return "public.audio"
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        workQueue.async { [self] in
            fulfill(loadingRequest)
        }
        return true
    }

    private func isCancelled(_ request: AVAssetResourceLoadingRequest) -> Bool {
        request.isCancelled
    }

    private func fulfill(_ request: AVAssetResourceLoadingRequest) {
        if let information = request.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = reader.length
            information.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }
        let total = reader.length
        let end = dataRequest.requestsAllDataToEndOfResource
            ? total
            : min(total, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
        var cursor = dataRequest.currentOffset
        Log.download.info(
            "vault read \(self.trackID, privacy: .public) offset=\(cursor, privacy: .public) end=\(end, privacy: .public) of \(total, privacy: .public)"
        )
        do {
            while cursor < end {
                if isCancelled(request) { return }
                let slice = Int(min(Int64(Self.responseSliceLength), end - cursor))
                let data = try reader.read(offset: cursor, length: slice)
                guard !data.isEmpty else { break }
                dataRequest.respond(with: data)
                cursor += Int64(data.count)
            }
            if !isCancelled(request) { request.finishLoading() }
        } catch {
            if !isCancelled(request) { request.finishLoading(with: error) }
        }
    }
}

enum VaultPlaybackAsset {
    nonisolated(unsafe) private static var delegateAssociationKey: UInt8 = 0

    static func make(reader: EncryptedAudioReader, trackID: String, fileExtension: String) -> AVURLAsset {
        let delegate = VaultResourceLoaderDelegate(
            reader: reader,
            contentType: VaultResourceLoaderDelegate.contentType(forFileExtension: fileExtension),
            trackID: trackID
        )
        let asset = AVURLAsset(url: VaultResourceLoaderDelegate.assetURL(trackID: trackID, fileExtension: fileExtension))
        asset.resourceLoader.setDelegate(delegate, queue: delegate.queue)
        objc_setAssociatedObject(asset, &delegateAssociationKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated static let networkObserver = NetworkActivityTaskObserver(feature: .download)

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let trackId = downloadTask.taskDescription else { return }
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { @MainActor [weak self] in
            self?.updateProgress(trackId: trackId, fraction: fraction)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let trackId = downloadTask.taskDescription else { return }
        let staged = transferStagingDirectory.appendingPathComponent(
            "\(trackId)-partial-\(UUID().uuidString)"
        )
        try? FileManager.default.createDirectory(
            at: transferStagingDirectory,
            withIntermediateDirectories: true
        )
        let moved = (try? FileManager.default.moveItem(at: location, to: staged)) != nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.vaultUnlockTask?.value
            if moved {
                self.finishTransfer(trackId: trackId, stagedFile: staged)
            } else {
                self.fail(trackId: trackId, reason: "Could not save the downloaded file.")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        Self.networkObserver.urlSession(session, task: task, didFinishCollecting: metrics)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Self.networkObserver.observeCompletion(task: task, error: error)
        guard let trackId = task.taskDescription, let error else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor [weak self] in
            self?.handleTransferFailure(trackId: trackId, error: error, resumeData: resumeData)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            let completion = self?.systemCompletion
            self?.systemCompletion = nil
            completion?.handler()
        }
    }
}

extension DownloadManager {
    fileprivate func handleTransferFailure(trackId: String, error: Error, resumeData: Data?) {
        activeDownloadTasks[trackId] = nil
        if let resumeData {
            persistResumeData(resumeData, for: trackId)
            setState(.paused(progress: lastKnownProgress(trackId)), for: trackId)
        } else if (error as? URLError)?.code == .cancelled {
        } else {
            fail(trackId: trackId, reason: error.localizedDescription)
        }
        admitFromQueueIfPossible()
    }
}

enum DownloadEntitlementSweep: Equatable, Sendable {
    case keep
    case removeRestricted
    case removeAll
}

enum DownloadSourceSelection {
    struct Source: Equatable {
        let transcoding: Transcoding
        let isHLS: Bool
    }

    static func allowsHighQuality(for tier: SubscriptionService.Tier) -> Bool {
        tier == .goPlus || tier == .dj || tier == .unknown
    }

    static func choose(from transcodings: [Transcoding], ceiling: QualityCeiling = .maximum, allowsHighQuality: Bool = true) -> Source? {
        let standard = transcodings.filter { !$0.isHQ }
        let entitled = allowsHighQuality || standard.isEmpty ? transcodings : standard
        let pool = ceiling.capping(entitled)
        let progressive = pool
            .filter { $0.isProgressive && $0.codec != .opus }
            .max { $0.playbackRank < $1.playbackRank }
        if let progressive {
            return Source(transcoding: progressive, isHLS: false)
        }
        let hls = pool
            .filter { $0.codec != .opus }
            .max { $0.playbackRank < $1.playbackRank }
        return hls.map { Source(transcoding: $0, isHLS: true) }
    }

    static func fileExtension(for transcoding: Transcoding) -> String {
        switch transcoding.codec {
        case .lossless: return "flac"
        case .aac: return "m4a"
        case .mp3: return "mp3"
        case .opus: return "opus"
        case .unknown: return "audio"
        }
    }
}
