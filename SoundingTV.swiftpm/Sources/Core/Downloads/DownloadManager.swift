import Foundation
import Network
import Combine
import CryptoKit
import Security

private final class BackgroundSessionCompletion: @unchecked Sendable {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }
}

/// Serialises encrypted index writes away from the main actor and coalesces
/// stale snapshots. A large Likes collection must never make SwiftUI wait for
/// JSON encoding, encryption, or an atomic filesystem write.
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

    private func isLatest(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestRevision == revision
    }
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
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    nonisolated static let backgroundSessionIdentifier = "red.forbes.sounding.downloads"

    @Published private(set) var states: [String: DownloadState] = [:]

    @Published private(set) var entries: [String: DownloadEntry] = [:]

    private var settingsCancellables = Set<AnyCancellable>()
    private let indexWriter = DownloadIndexWriter()

    @Published private(set) var usedBytes: Int64 = 0

    @Published private(set) var maxBytes: Int64 {
        didSet {
            guard maxBytes != oldValue else { return }
            Task { [weak self] in await self?.runMaintenance() }
        }
    }

    func setMaxBytes(_ value: Int64) {
        SettingsStore.shared.setDownloadStorageCapBytes(value)
    }

    @Published private(set) var isOnUnmeteredNetwork = true
    @Published private(set) var hasConnectivity = true

    @Published private(set) var allowsCellularDownloads: Bool {
        didSet {
            guard allowsCellularDownloads != oldValue else { return }
            handlePolicyChange()
        }
    }

    func setAllowsCellularDownloads(_ value: Bool) {
        SettingsStore.shared.setCellularDownloadsAllowed(value)
    }

    var scheduledDeletionDate: Date? {
        guard case .verifiedNotSubscribed = SubscriptionService.shared.verification,
              let since = SubscriptionService.shared.notSubscribedSince else { return nil }
        return since.addingTimeInterval(SubscriptionService.deletionDelay)
    }

    private static let maxConcurrentTransfers = 3
    private static let predictiveLookahead = 3
    private static let recommendedLikedLimit = 15
    private static let recommendedRecentLimit = 10
    private static let predictiveTTL: TimeInterval = 30 * 24 * 3600
    private static let reservedFreeSpaceBytes: Int64 = 1_000_000_000
    private static let maxBytesDefaultsKey = "red.forbes.sounding.downloads.maxBytes"
    private static let allowsCellularDefaultsKey = "red.forbes.sounding.downloads.allowsCellular"
    private static let maintenanceInterval: TimeInterval = 3600

    nonisolated let downloadsDirectory: URL
    private nonisolated let indexFileURL: URL
    private nonisolated let decryptedDirectory: URL

    private var session: URLSession!
    private var activeResolutionTasks: [String: Task<Void, Never>] = [:]
    private var activeDownloadTasks: [String: URLSessionDownloadTask] = [:]
    private var activeAssemblyTasks: [String: Task<Void, Never>] = [:]
    private var vaultUnlockTask: Task<Void, Never>?
    private var trafficSafetyResumeTask: Task<Void, Never>?
    private var intelligenceResumeTask: Task<Void, Never>?
    private var intelligenceResumeRevision: UInt64 = 0
    private var resumeDataStore: [String: Data] = [:]
    private var pendingFileExtensions: [String: String] = [:]
    private var pendingSourceFingerprints: [String: String] = [:]
    private var pendingQueue: [String] = []
    private var pausedByPolicy: Set<String> = []
    private var qualityMigrationQueue: [String] = []
    private var qualityMigrationTrackID: String?

    private nonisolated(unsafe) var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "red.forbes.sounding.downloadmanager.path")
    private nonisolated(unsafe) var maintenanceTask: Task<Void, Never>?
    private var systemCompletion: BackgroundSessionCompletion?

    private var cancellables = Set<AnyCancellable>()

    private override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Downloads", isDirectory: true)
        downloadsDirectory = directory
        indexFileURL = directory.appendingPathComponent("index.json")
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        decryptedDirectory = caches.appendingPathComponent("SoundingTV-DecryptedDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: decryptedDirectory)
        try? FileManager.default.createDirectory(at: decryptedDirectory, withIntermediateDirectories: true)

        let settings = SettingsStore.shared
        maxBytes = settings.downloadStorageCapBytes
        allowsCellularDownloads = settings.cellularDownloadsAllowed

        super.init()

        settings.$downloadStorageCapBytes
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor in self?.maxBytes = value }
            }
            .store(in: &settingsCancellables)

        settings.$cellularDownloadsAllowed
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor in self?.allowsCellularDownloads = value }
            }
            .store(in: &settingsCancellables)

        settings.$automaticAnalysisPolicy
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.resumeDownloadedIntelligenceWork()
            }
            .store(in: &settingsCancellables)

        settings.$downloadQualityCeiling
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleRollingQualityMigration()
            }
            .store(in: &settingsCancellables)

        SoundCloudCredentialSource.shared.$isSignedOut
            .removeDuplicates()
            .sink { [weak self] isSignedOut in
                guard isSignedOut else { return }
                self?.lockAccountVault()
            }
            .store(in: &cancellables)

        var excludedDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedDirectory.setResourceValues(resourceValues)

        entries = [:]
        usedBytes = 0

        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 5 * 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        startPathMonitor()
        observeSubscriptionState()
        startMaintenanceLoop()

        Task { [weak self] in
            await self?.loadPersistedResumeData()
            await self?.reconcileExistingTasks()
            #if os(macOS) || os(tvOS)
            self?.resumeDownloadedIntelligenceWork()
            #endif
        }
    }

    deinit {
        cancelBackgroundResources()
    }

    private nonisolated func cancelBackgroundResources() {
        pathMonitor?.cancel()
        maintenanceTask?.cancel()
    }

    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        intelligenceResumeTask?.cancel()
        intelligenceResumeTask = nil
        vaultUnlockTask?.cancel()
        vaultUnlockTask = nil
        trafficSafetyResumeTask?.cancel()
        trafficSafetyResumeTask = nil
        for task in activeResolutionTasks.values { task.cancel() }
        for task in activeDownloadTasks.values { task.cancel() }
        for task in activeAssemblyTasks.values { task.cancel() }
        activeResolutionTasks.removeAll()
        activeDownloadTasks.removeAll()
        activeAssemblyTasks.removeAll()
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

    func state(for trackId: String) -> DownloadState {
        states[trackId] ?? .notDownloaded
    }

    func isPinned(trackId: String) -> Bool {
        entries[trackId]?.isEffectivelyPinned ?? false
    }

    func downloadRefusalReason(for track: Track) -> DownloadError? {
        guard isFullyEntitled(track) else { return .previewOnly }
        return nil
    }

    func localFileURL(for track: Track) -> URL? {
        guard let accountID = SubscriptionService.shared.authenticatedAccountID,
              SubscriptionService.shared.hasAuthenticatedSession,
              var entry = entries[track.id],
              let fileName = entry.fileName else { return nil }
        let url = downloadsDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard hasConnectivity || entries[track.id]?.encryptionAccountID != nil else { return nil }

        if let owner = entry.encryptionAccountID {
            guard owner == accountID else { return nil }
            return materialize(entry: entry, encryptedURL: url, accountID: accountID)
        }

        return migrateLegacyDownload(entry: &entry, plaintextURL: url, accountID: accountID)
    }

    func lockAccountVault() {
        vaultUnlockTask?.cancel()
        vaultUnlockTask = nil
        intelligenceResumeTask?.cancel()
        intelligenceResumeTask = nil
        try? FileManager.default.removeItem(at: decryptedDirectory)
        try? FileManager.default.createDirectory(at: decryptedDirectory, withIntermediateDirectories: true)
        entries = [:]
        states = [:]
        usedBytes = 0
        handlePolicyChange()
    }

    func localFileURL(forTrackId trackId: String) -> URL? {
        guard let track = entries[trackId]?.track else { return nil }
        return localFileURL(for: track)
    }

    /// A listener can always prioritise an already-downloaded track. This is
    /// intentionally separate from the global policy and never starts a
    /// download or fetches stream bytes.
    func forceAnalyseNow(trackId: String) {
        guard let entry = entries[trackId], let localFileURL = localFileURL(for: entry.track) else {
            AutomaticAnalysisStatus.shared.set(.notEligible("Download this track first"), for: trackId)
            return
        }
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            AnalysisOpportunity.schedule(
                track: entry.track,
                transcoding: chooseSource(for: entry.track)?.transcoding,
                localFileURL: localFileURL,
                registry: AnalysisProducerRegistry([MusicUnderstandingProducer()]),
                priority: .interactive,
                enforceDeviceEligibility: false
            )
        }
    }

    /// Metadata in the durable download index is sufficient to restore Now
    /// Playing while offline; playback can resolve the local file separately.
    func cachedTrack(forTrackId trackId: String) -> Track? {
        entries[trackId]?.track
    }

    func cachedTracks(forCollectionId collectionId: String) -> [Track] {
        entries.values
            .filter { $0.pinningCollectionIds.contains(collectionId) }
            .sorted { $0.addedAt < $1.addedAt }
            .map(\.track)
    }

    func markPlayed(trackId: String) {
        guard var entry = entries[trackId] else { return }
        entry.lastPlayedAt = Date()
        entries[trackId] = entry
        persistIndex()
    }

    @discardableResult
    func download(_ track: Track, pinned: Bool = true) -> Bool {
        guard isFullyEntitled(track) else { return false }
        upsertEntry(for: track, pinned: pinned, collectionId: nil)
        return true
    }

    func predictivelyDownload(_ track: Track) {
        guard isFullyEntitled(track) else { return }
        guard entries[track.id] == nil else { return }
        upsertEntry(for: track, pinned: false, collectionId: nil)
    }

    /// Copies an already-downloaded file from a specifically identified paired
    /// device. The local peer credential authenticates the transport; the
    /// received plaintext is staged temporarily and immediately re-encrypted
    /// with this device's account vault key by `adoptPeerDelivered`.
    @discardableResult
    func downloadFromPeer(
        trackId: String,
        sourceDeviceId: String,
        provider: any PeerContentSessionProvider,
        pinned: Bool = true
    ) async -> Bool {
        if entries[trackId]?.isDownloaded == true { return true }
        guard let endpoint = provider.peerContentEndpoint(forDeviceId: sourceDeviceId) else {
            setState(.failed(reason: "That device is not currently reachable."), for: trackId)
            return false
        }

        let track: Track
        do {
            track = try await SoundCloudAPI.shared.getTrack(id: trackId)
        } catch {
            setState(.failed(reason: "Could not load the track details."), for: trackId)
            return false
        }
        guard isFullyEntitled(track) else {
            setState(.failed(reason: DownloadError.previewOnly.errorDescription ?? "This track cannot be downloaded."), for: trackId)
            return false
        }

        if entries[trackId] == nil {
            entries[trackId] = DownloadEntry(
                track: track, isPinned: pinned, pinningCollectionIds: [],
                addedAt: Date(), lastPlayedAt: Date(), fileName: nil, fileSize: 0
            )
        }
        setState(.downloading(progress: 0), for: trackId)
        persistIndex()

        do {
            let staged = try await PeerContentTransfer.stage(
                trackId: trackId,
                endpoint: endpoint.endpoint,
                sessionId: endpoint.sessionId,
                secret: endpoint.secret
            ) { [weak self] fraction in
                await MainActor.run { self?.updateProgress(trackId: trackId, fraction: fraction) }
            }
            guard adoptPeerDelivered(track: track, sourceFileURL: staged, pinned: pinned) else {
                try? FileManager.default.removeItem(at: staged)
                fail(trackId: trackId, reason: "Could not secure the transferred download.")
                return false
            }
            return true
        } catch is CancellationError {
            setState(.paused(progress: lastKnownProgress(trackId)), for: trackId)
            return false
        } catch {
            fail(trackId: trackId, reason: "Could not copy from that device: \(error.localizedDescription)")
            return false
        }
    }

    func queueDidChange(upcoming: [Track], isLocalPlaybackTarget: Bool = true) {
        guard isLocalPlaybackTarget else { return }
        for track in upcoming.prefix(Self.predictiveLookahead) {
            predictivelyDownload(track)
        }
    }

    func considerRecommended(liked: [Track], recentlyPlayed: [Track]) {
        let likesPolicy = CollectionQualityOverrideStore.shared.policy(for: CollectionPolicyID.likedTracks)
        if likesPolicy.automaticDownloads {
            for track in liked.prefix(Self.recommendedLikedLimit) {
                upsertEntry(for: track, pinned: false, collectionId: CollectionPolicyID.likedTracks)
            }
        }
        for track in recentlyPlayed.prefix(Self.recommendedRecentLimit) { predictivelyDownload(track) }
    }

    /// Applies the whole collection policy to the tracks currently known to the caller.
    /// This is intentionally idempotent, so paged playlist and Likes views can call it
    /// after every page without producing duplicate work.
    func applyCollectionPolicy(tracks: [Track], collectionId: String) {
        let policy = CollectionQualityOverrideStore.shared.policy(for: collectionId)

        if policy.automaticDownloads {
            _ = pinForOffline(tracks: tracks, collectionId: collectionId)
        } else {
            unpinCollection(collectionId)
        }

        // Collection policies control downloads. The choice of which saved
        // collections merit automatic analysis is one shared global rule.
        resumeDownloadedIntelligenceWork()
    }

    @discardableResult
    func pinForOffline(tracks: [Track], collectionId: String) -> Int {
        var accepted = 0
        for track in tracks where isFullyEntitled(track) {
            upsertEntry(
                for: track,
                pinned: false,
                collectionId: collectionId,
                persistImmediately: false,
                admitImmediately: false
            )
            accepted += 1
        }
        if accepted > 0 {
            persistIndex()
            admitFromQueueIfPossible()
        }
        return accepted
    }

    @discardableResult
    func pinForOffline(_ playlist: Playlist) -> Int {
        pinForOffline(tracks: playlist.loadedTracks, collectionId: playlist.id)
    }

    @discardableResult
    func pinForOfflineHydrating(_ playlist: Playlist) async throws -> Int {
        guard playlist.hasUnloadedTracks else {
            return pinForOffline(tracks: playlist.loadedTracks, collectionId: playlist.id)
        }
        let manifest = playlist.trackIDs ?? playlist.loadedTracks.map(\.id)
        let hydrated = try await SoundCloudAPI.shared.getPlaylistTracks(playlist, ids: manifest)
        return pinForOffline(tracks: hydrated, collectionId: playlist.id)
    }

    @discardableResult
    func adoptPeerDelivered(track: Track, sourceFileURL: URL, pinned: Bool) -> Bool {
        guard isFullyEntitled(track) else { return false }
        guard let source = chooseSource(for: track) else { return false }

        guard let accountID = SubscriptionService.shared.authenticatedAccountID,
              let key = DownloadVault.key(for: accountID) else { return false }
        let originalExtension = DownloadSourceSelection.fileExtension(for: source.transcoding)
        let finalName = "\(track.id).sctv"
        let finalURL = downloadsDirectory.appendingPathComponent(finalName)
        try? FileManager.default.removeItem(at: finalURL)
        do {
            try DownloadVault.encryptFile(at: sourceFileURL, to: finalURL, using: key)
            try? FileManager.default.removeItem(at: sourceFileURL)
        } catch {
            return false
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        var entry = entries[track.id] ?? DownloadEntry(
            track: track, isPinned: pinned, pinningCollectionIds: [],
            addedAt: Date(), lastPlayedAt: Date(), fileName: nil, fileSize: 0
        )
        entry.track = track
        if pinned { entry.isPinned = true }
        entry.fileName = finalName
        entry.fileSize = size
        entry.encryptionAccountID = accountID
        entry.originalFileExtension = originalExtension
        entry.lastPlayedAt = Date()
        entries[track.id] = entry

        setState(.downloaded, for: track.id)
        usedBytes += size
        persistIndex()
        if let localURL = materialize(entry: entry, encryptedURL: finalURL, accountID: accountID) {
            scheduleIntelligenceForDownloadedEntry(entry, localFileURL: localURL)
        }
        Task { [weak self] in await self?.runMaintenance() }
        return true
    }

    func unpinCollection(_ collectionId: String) {
        for (trackId, var entry) in entries where entry.pinningCollectionIds.contains(collectionId) {
            entry.pinningCollectionIds.remove(collectionId)
            entries[trackId] = entry
        }
        persistIndex()
        Task { [weak self] in await self?.runMaintenance() }
    }

    func pin(trackId: String) {
        guard var entry = entries[trackId] else { return }
        entry.isPinned = true
        entries[trackId] = entry
        persistIndex()
    }

    func unpin(trackId: String) {
        guard var entry = entries[trackId] else { return }
        entry.isPinned = false
        entries[trackId] = entry
        persistIndex()
        Task { [weak self] in await self?.runMaintenance() }
    }

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
        _ = entry
        guard !pendingQueue.contains(trackId),
              activeResolutionTasks[trackId] == nil,
              activeDownloadTasks[trackId] == nil,
              activeAssemblyTasks[trackId] == nil else { return }
        setState(.queued, for: trackId)
        pendingQueue.append(trackId)
        admitFromQueueIfPossible()
    }

    func cancel(trackId: String) {
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
        resumeDataStore[trackId] = nil
        clearResumeDataFile(for: trackId)
        removeMaterializedFile(trackID: trackId)

        if qualityMigrationTrackID == trackId {
            pendingFileExtensions[trackId] = nil
            pendingSourceFingerprints[trackId] = nil
            qualityMigrationTrackID = nil
            setState(.downloaded, for: trackId)
            startNextQualityMigrationIfPossible()
            admitFromQueueIfPossible()
            return
        }

        if let entry = entries[trackId] {
            if let fileName = entry.fileName {
                try? FileManager.default.removeItem(at: downloadsDirectory.appendingPathComponent(fileName))
                usedBytes = max(0, usedBytes - entry.fileSize)
            }
            entries[trackId] = nil
        }
        states[trackId] = .notDownloaded
        persistIndex()
        admitFromQueueIfPossible()
    }

    private func upsertEntry(
        for track: Track,
        pinned: Bool,
        collectionId: String?,
        persistImmediately: Bool = true,
        admitImmediately: Bool = true
    ) {
        if var existing = entries[track.id] {
            existing.track = track
            if pinned { existing.isPinned = true }
            if let collectionId { existing.pinningCollectionIds.insert(collectionId) }
            entries[track.id] = existing
            if persistImmediately { persistIndex() }
            switch states[track.id] {
            case .downloaded, .queued, .downloading, .paused:
                return
            default:
                break
            }
        } else {
            entries[track.id] = DownloadEntry(
                track: track,
                isPinned: pinned,
                pinningCollectionIds: collectionId.map { [$0] } ?? [],
                addedAt: Date(),
                lastPlayedAt: Date(),
                fileName: nil,
                fileSize: 0
            )
        }
        setState(.queued, for: track.id)
        pendingQueue.append(track.id)
        if persistImmediately { persistIndex() }
        if admitImmediately { admitFromQueueIfPossible() }
    }

    private func isFullyEntitled(_ track: Track) -> Bool {
        !track.transcodings.isEmpty
    }

    private func chooseSource(for track: Track) -> DownloadSourceSelection.Source? {
        DownloadSourceSelection.choose(
            from: track.transcodings,
            ceiling: effectiveDownloadCeiling(for: track)
        )
    }

    func effectiveDownloadCeiling(for track: Track) -> QualityCeiling {
        let store = CollectionQualityOverrideStore.shared
        let global = SettingsStore.shared.downloadQualityCeiling
        let ids = [track.id] + Array(entries[track.id]?.pinningCollectionIds ?? [])
        let ceilings = ids.compactMap { store.override(for: $0) }
        // A file can be shared by several pinned collections. Honour the strictest
        // ceiling so one collection cannot silently consume more storage than asked.
        return ceilings.min() ?? global
    }

    private func resolveStreamURL(for transcodingURL: URL, allowRefresh: Bool = true) async throws -> URL {
        try SoundCloudAPI.shared.enforceTrafficSafety()
        let url = SoundCloudAPI.strippingCredentials(from: transcodingURL)

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let token = SoundCloudAPI.credentials?.accessToken {
            request.addValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.streamResolutionFailed }

        if http.statusCode == 401, allowRefresh, await SoundCloudAPI.credentials?.refreshAccessToken() == true {
            return try await resolveStreamURL(for: transcodingURL, allowRefresh: false)
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            let until = SoundCloudAPI.shared.recordTrafficBlock(statusCode: http.statusCode, response: http)
            scheduleTrafficSafetyResume(at: until)
            throw DownloadError.trafficStopped(statusCode: http.statusCode, until: until)
        }
        guard (200..<300).contains(http.statusCode) else { throw DownloadError.streamResolutionFailed }

        struct StreamResponse: Decodable { let url: String }
        guard let decoded = try? JSONDecoder().decode(StreamResponse.self, from: data),
              let finalURL = URL(string: decoded.url) else {
            throw DownloadError.streamResolutionFailed
        }
        return finalURL
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
            } catch is CancellationError {
                self.activeResolutionTasks[track.id] = nil
            } catch {
                self.activeResolutionTasks[track.id] = nil
                self.fail(trackId: track.id, reason: error.localizedDescription)
            }
        }
        activeResolutionTasks[track.id] = task
    }

    private func beginProgressiveDownload(trackId: String, url: URL, transcoding: Transcoding) {
        guard entries[trackId] != nil else { return }
        pendingFileExtensions[trackId] = DownloadSourceSelection.fileExtension(for: transcoding)
        let task = session.downloadTask(with: url)
        task.taskDescription = trackId
        activeDownloadTasks[trackId] = task
        setState(.downloading(progress: 0), for: trackId)
        task.resume()
    }

    private func beginAssembly(trackId: String, playlistURL: URL) {
        let directory = downloadsDirectory
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
            } catch {
                await MainActor.run {
                    self?.fail(trackId: trackId, reason: error.localizedDescription)
                }
            }
        }
        activeAssemblyTasks[trackId] = task
    }

    private func finishTransfer(trackId: String, stagedFile: URL) {
        guard var entry = entries[trackId] else {
            try? FileManager.default.removeItem(at: stagedFile)
            return
        }
        let ext = pendingFileExtensions.removeValue(forKey: trackId) ?? stagedFile.pathExtension
        guard let accountID = SubscriptionService.shared.authenticatedAccountID,
              let key = DownloadVault.key(for: accountID) else {
            fail(trackId: trackId, reason: "Sign in again to finish this download.")
            return
        }
        let finalName = "\(trackId).sctv"
        let finalURL = downloadsDirectory.appendingPathComponent(finalName)
        let replacementURL = downloadsDirectory.appendingPathComponent("\(trackId).replacement.\(UUID().uuidString).sctv")
        do {
            try DownloadVault.encryptFile(at: stagedFile, to: replacementURL, using: key)
            try? FileManager.default.removeItem(at: stagedFile)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: replacementURL)
            } else {
                try FileManager.default.moveItem(at: replacementURL, to: finalURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: replacementURL)
            fail(trackId: trackId, reason: "Could not finalize the download.")
            return
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        let previousSize = entry.fileSize
        entry.fileName = finalName
        entry.fileSize = size
        entry.encryptionAccountID = accountID
        entry.originalFileExtension = ext
        entry.sourceFingerprint = pendingSourceFingerprints.removeValue(forKey: trackId)
        entry.lastPlayedAt = Date()
        entries[trackId] = entry

        activeDownloadTasks[trackId] = nil
        activeAssemblyTasks[trackId] = nil
        resumeDataStore[trackId] = nil
        clearResumeDataFile(for: trackId)

        setState(.downloaded, for: trackId)
        usedBytes = max(0, usedBytes - previousSize) + size
        persistIndex()
        completeQualityMigrationIfNeeded(trackId: trackId)
        admitFromQueueIfPossible()
        Task { [weak self] in await self?.runMaintenance() }

        if let localURL = materialize(entry: entry, encryptedURL: finalURL, accountID: accountID) {
            scheduleIntelligenceForDownloadedEntry(entry, localFileURL: localURL)
        }
    }

    private func scheduleIntelligenceForDownloadedEntry(_ entry: DownloadEntry, localFileURL: URL) {
        let rules = SettingsStore.shared.automaticAnalysisPolicy
        let isLiked = entry.pinningCollectionIds.contains(CollectionPolicyID.likedTracks)
        let isPlaylistTrack = entry.pinningCollectionIds.contains { $0 != CollectionPolicyID.likedTracks }
        guard (rules.likedTracks && isLiked) || (rules.yourPlaylists && isPlaylistTrack) else { return }
        scheduleIntelligence(for: entry.track, level: .full, localFileURL: localFileURL)
    }

    /// Rehydrates intelligence work after launch without ever decrypting audio
    /// on the main actor. Probe ledgers make completed work inexpensive, while
    /// the serial utility task keeps launch and scrolling responsive.
    private func resumeDownloadedIntelligenceWork() {
        let rules = SettingsStore.shared.automaticAnalysisPolicy
        let downloaded = entries.values
            .filter(\.isDownloaded)
            .filter { entry in
                let isLiked = entry.pinningCollectionIds.contains(CollectionPolicyID.likedTracks)
                let isPlaylistTrack = entry.pinningCollectionIds.contains {
                    $0 != CollectionPolicyID.likedTracks
                }
                return (rules.likedTracks && isLiked) || (rules.yourPlaylists && isPlaylistTrack)
            }
            .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
        guard !downloaded.isEmpty,
              let accountID = SubscriptionService.shared.authenticatedAccountID,
              SubscriptionService.shared.hasAuthenticatedSession else { return }

        intelligenceResumeTask?.cancel()
        intelligenceResumeRevision &+= 1
        let revision = intelligenceResumeRevision
        let encryptedDirectory = downloadsDirectory
        let materializedDirectory = decryptedDirectory

        intelligenceResumeTask = Task.detached(priority: .utility) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard self?.intelligenceResumeRevision == revision else { return }
                    self?.intelligenceResumeTask = nil
                }
            }
            guard let key = DownloadVault.key(for: accountID, createIfMissing: false) else { return }

            for entry in downloaded {
                guard !Task.isCancelled else { return }
                guard entry.encryptionAccountID == accountID,
                      let fileName = entry.fileName else { continue }
                let encryptedURL = encryptedDirectory.appendingPathComponent(fileName)
                guard FileManager.default.fileExists(atPath: encryptedURL.path) else { continue }
                let destination = materializedDirectory
                    .appendingPathComponent(entry.track.id)
                    .appendingPathExtension(entry.originalFileExtension ?? "audio")
                if !FileManager.default.fileExists(atPath: destination.path) {
                    do {
                        try DownloadVault.decryptFile(at: encryptedURL, to: destination, using: key)
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        continue
                    }
                }
                guard !Task.isCancelled else { return }
                await self?.scheduleIntelligenceForDownloadedEntry(entry, localFileURL: destination)
                await Task.yield()
            }
        }
    }

    private func scheduleIntelligence(
        for track: Track,
        level: CollectionIntelligenceLevel,
        localFileURL: URL? = nil
    ) {
        guard level != .off else { return }
        AnalysisOpportunity.schedule(
            track: track,
            genreField: track.genre,
            tags: track.tags + [track.title],
            registry: .metadataOnly
        )
        guard level == .full,
              let localFileURL = localFileURL ?? self.localFileURL(for: track) else { return }
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            AnalysisOpportunity.schedule(
                track: track,
                transcoding: chooseSource(for: track)?.transcoding,
                localFileURL: localFileURL,
                registry: AnalysisProducerRegistry([MusicUnderstandingProducer()])
            )
        }
        if DeckIdentityResolver.isLikelyMix(track) {
            SetlistBackgroundWorkCoordinator.shared.enqueue(
                track: track,
                localFileURL: localFileURL
            )
        }
    }

    private func lastKnownProgress(_ trackId: String) -> Double {
        switch states[trackId] {
        case .downloading(let progress), .paused(let progress): return progress
        default: return 0
        }
    }

    private func setState(_ state: DownloadState, for trackId: String) {
        states[trackId] = state
    }

    private func updateProgress(trackId: String, fraction: Double) {
        guard states[trackId] != .downloaded else { return }
        states[trackId] = .downloading(progress: min(1, max(0, fraction)))
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

    /// Replaces downloaded audio serially. The old encrypted file remains the
    /// active copy until the newly selected source is fully downloaded and
    /// encrypted, then FileManager performs one atomic replacement.
    private func scheduleRollingQualityMigration() {
        let candidates = entries.values
            .filter(\.isDownloaded)
            .filter { entry in
                guard let selected = chooseSource(for: entry.track) else { return false }
                return entry.sourceFingerprint != Self.sourceFingerprint(selected.transcoding)
            }
            .map { $0.track.id }
        qualityMigrationQueue = candidates.filter { $0 != qualityMigrationTrackID }
        startNextQualityMigrationIfPossible()
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
        scheduleRollingQualityMigration()
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

    private func admitFromQueueIfPossible() {
        while (activeResolutionTasks.count + activeDownloadTasks.count + activeAssemblyTasks.count) < Self.maxConcurrentTransfers,
              !pendingQueue.isEmpty {
            guard canTransferNow() else { return }
            let trackId = pendingQueue.removeFirst()
            guard let entry = entries[trackId], states[trackId] == .queued else { continue }
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

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let unmetered = connected && !path.isExpensive && !path.isConstrained
            Task { @MainActor in
                self?.hasConnectivity = connected
                self?.isOnUnmeteredNetwork = unmetered
                self?.handlePolicyChange()
            }
        }
        pathMonitor = monitor
        monitor.start(queue: pathMonitorQueue)
    }

    private func canTransferNow() -> Bool {
        guard hasConnectivity else { return false }
        guard (try? SoundCloudAPI.shared.enforceTrafficSafety()) != nil else { return false }
        return isOnUnmeteredNetwork || allowsCellularDownloads
    }

    private func scheduleTrafficSafetyResume(at date: Date) {
        trafficSafetyResumeTask?.cancel()
        trafficSafetyResumeTask = Task { @MainActor [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            self.trafficSafetyResumeTask = nil
            self.handlePolicyChange()
        }
    }

    private func handlePolicyChange() {
        if canTransferNow() {
            let resumable = pausedByPolicy
            pausedByPolicy.removeAll()
            for trackId in resumable { resume(trackId: trackId) }
            admitFromQueueIfPossible()
        } else {
            pauseAllActiveTransfers(dueToPolicy: true)
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
            .sink { [weak self] _, verification in
                guard let self else { return }
                self.handlePolicyChange()
                if case .verifiedNotSubscribed = verification {
                    self.pauseAllActiveTransfers(dueToPolicy: true)
                }
                self.evaluateEntitlementDeletionSweep()
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
        guard case .verifiedNotSubscribed = SubscriptionService.shared.verification,
              let since = SubscriptionService.shared.notSubscribedSince else { return }
        guard Date().timeIntervalSince(since) >= SubscriptionService.deletionDelay else { return }
        guard !entries.isEmpty else { return }
        for trackId in Array(entries.keys) {
            cancel(trackId: trackId)
        }
    }

    private func startMaintenanceLoop() {
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runMaintenance()
                try? await Task.sleep(for: .seconds(Self.maintenanceInterval))
            }
        }
    }

    private func runMaintenance() async {
        evaluateEntitlementDeletionSweep()
        sweepStaleContent()
        enforceDiskHeadroom()
        enforceBudget()
    }

    private func sweepStaleContent() {
        let cutoff = Date().addingTimeInterval(-Self.predictiveTTL)
        for (trackId, entry) in entries where entry.isDownloaded && !entry.isEffectivelyPinned && entry.lastPlayedAt < cutoff {
            cancel(trackId: trackId)
        }
    }

    private func enforceDiskHeadroom() {
        guard let available = Self.availableDiskSpace(near: downloadsDirectory) else { return }
        guard available < Self.reservedFreeSpaceBytes else { return }

        var deficit = Self.reservedFreeSpaceBytes - available
        let candidates = entries.values
            .filter { $0.isDownloaded && !$0.isEffectivelyPinned }
            .sorted { $0.lastPlayedAt < $1.lastPlayedAt }
        for entry in candidates {
            guard deficit > 0 else { break }
            deficit -= entry.fileSize
            cancel(trackId: entry.track.id)
        }
    }

    private func enforceBudget() {
        let budgetEntries = entries.values
            .filter { $0.isDownloaded }
            .map { DownloadBudgetPolicy.Entry(id: $0.track.id, bytes: $0.fileSize, lastPlayedAt: $0.lastPlayedAt, isPinned: $0.isEffectivelyPinned) }
        let victims = DownloadBudgetPolicy.victims(entries: Array(budgetEntries), maxBytes: maxBytes)
        for trackId in victims {
            cancel(trackId: trackId)
        }
    }

    private static func availableDiskSpace(near directory: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path) else {
            return nil
        }
        return attributes[.systemFreeSize] as? Int64
    }

    private nonisolated static func loadIndex(from url: URL) -> [String: DownloadEntry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: DownloadEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persistIndex() {
        guard let accountID = SubscriptionService.shared.authenticatedAccountID else { return }
        indexWriter.persist(
            entries: entries,
            accountID: accountID,
            destination: encryptedIndexURL(accountID: accountID)
        )
    }

    private func unlockAccountVault(_ accountID: String) {
        let encryptedURL = encryptedIndexURL(accountID: accountID)
        let legacyURL = indexFileURL
        vaultUnlockTask?.cancel()
        vaultUnlockTask = Task.detached(priority: .utility) { [weak self] in
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
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self,
                      SubscriptionService.shared.authenticatedAccountID == accountID else { return }
                self.entries = decoded
                self.states = decoded.mapValues { $0.isDownloaded ? .downloaded : .queued }
                self.usedBytes = decoded.values.reduce(Int64(0)) { $0 + $1.fileSize }
                if migratedLegacy, !decoded.isEmpty {
                    self.persistIndex()
                    try? FileManager.default.removeItem(at: legacyURL)
                }
            }
        }
    }

    private func encryptedIndexURL(accountID: String) -> URL {
        downloadsDirectory.appendingPathComponent(
            "index.\(AccountDataVault.storageSuffix(for: accountID)).vault"
        )
    }

    // LEGACY MIGRATION: remove after the account-vault rollout window.
    private func migrateLegacyIndex(accountID: String) -> [String: DownloadEntry] {
        let decoded = Self.loadIndex(from: indexFileURL)
        guard !decoded.isEmpty else { return [:] }
        entries = decoded
        persistIndex()
        try? FileManager.default.removeItem(at: indexFileURL)
        return decoded
    }

    private func materialize(entry: DownloadEntry, encryptedURL: URL, accountID: String) -> URL? {
        guard entry.encryptionAccountID == accountID,
              let key = DownloadVault.key(for: accountID, createIfMissing: false) else { return nil }
        let destination = decryptedURL(
            trackID: entry.track.id,
            fileExtension: entry.originalFileExtension ?? "audio"
        )
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        do {
            try DownloadVault.decryptFile(at: encryptedURL, to: destination, using: key)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    // LEGACY MIGRATION: remove after the encrypted-download rollout window.
    // New downloads never enter this path.
    private func migrateLegacyDownload(
        entry: inout DownloadEntry,
        plaintextURL: URL,
        accountID: String
    ) -> URL? {
        let ext = plaintextURL.pathExtension
        let encryptedURL = downloadsDirectory.appendingPathComponent("\(entry.track.id).sctv")
        guard let key = DownloadVault.key(for: accountID),
              (try? DownloadVault.encryptFile(at: plaintextURL, to: encryptedURL, using: key)) != nil else {
            return nil
        }
        let materialized = decryptedURL(trackID: entry.track.id, fileExtension: ext)
        try? FileManager.default.removeItem(at: materialized)
        do {
            try FileManager.default.moveItem(at: plaintextURL, to: materialized)
        } catch {
            try? FileManager.default.removeItem(at: encryptedURL)
            return nil
        }
        entry.fileName = encryptedURL.lastPathComponent
        entry.fileSize = fileSize(at: encryptedURL)
        entry.encryptionAccountID = accountID
        entry.originalFileExtension = ext
        entries[entry.track.id] = entry
        usedBytes = entries.values.reduce(Int64(0)) { $0 + $1.fileSize }
        persistIndex()
        return materialized
    }

    private func decryptedURL(trackID: String, fileExtension: String) -> URL {
        decryptedDirectory.appendingPathComponent("\(trackID).\(fileExtension)")
    }

    private func removeMaterializedFile(trackID: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: decryptedDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.deletingPathExtension().lastPathComponent == trackID {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func resumeDataFileURL(for trackId: String) -> URL {
        downloadsDirectory.appendingPathComponent("\(trackId).resumedata")
    }

    private func persistResumeData(_ data: Data, for trackId: String) {
        resumeDataStore[trackId] = data
        try? data.write(to: resumeDataFileURL(for: trackId), options: .atomic)
    }

    private func clearResumeDataFile(for trackId: String) {
        try? FileManager.default.removeItem(at: resumeDataFileURL(for: trackId))
    }

    private func loadPersistedResumeData() async {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.pathExtension == "resumedata" {
            let trackId = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url) else { continue }
            resumeDataStore[trackId] = data
            if entries[trackId] != nil, states[trackId] != .downloaded {
                setState(.paused(progress: 0), for: trackId)
            }
        }
    }

    private func reconcileExistingTasks() async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let trackId = task.taskDescription,
                  let downloadTask = task as? URLSessionDownloadTask,
                  entries[trackId] != nil else { continue }
            activeDownloadTasks[trackId] = downloadTask
            let expected = downloadTask.countOfBytesExpectedToReceive
            let received = downloadTask.countOfBytesReceived
            let fraction = expected > 0 ? Double(received) / Double(expected) : 0
            setState(.downloading(progress: fraction), for: trackId)
        }

        for (trackId, entry) in entries where !entry.isDownloaded && activeDownloadTasks[trackId] == nil {
            setState(.paused(progress: 0), for: trackId)
        }
        admitFromQueueIfPossible()
    }
}

private enum DownloadVault {
    private static let service = "red.forbes.sounding.download-vault"
    private static let magic = Data("SCTVENC1".utf8)
    private static let chunkSize = 1_048_576

    enum VaultError: Error {
        case keyUnavailable
        case malformedFile
        case writeFailed
    }

    static func key(for accountID: String, createIfMissing: Bool = true) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard createIfMissing else { return nil }

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
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            return key(for: accountID, createIfMissing: false)
        }
        return SymmetricKey(data: bytes)
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
            while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                let sealed = try AES.GCM.seal(chunk, using: key)
                guard let combined = sealed.combined else { throw VaultError.writeFailed }
                try output.write(contentsOf: encodedLength(combined.count))
                try output.write(contentsOf: combined)
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
        let temporary = destination.appendingPathExtension("decrypting")
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
            guard try readExactly(magic.count, from: input) == magic else {
                throw VaultError.malformedFile
            }
            while true {
                let lengthData = try input.read(upToCount: 4) ?? Data()
                if lengthData.isEmpty { break }
                guard lengthData.count == 4 else { throw VaultError.malformedFile }
                let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= UInt32(chunkSize + 64) else {
                    throw VaultError.malformedFile
                }
                let combined = try readExactly(Int(length), from: input)
                let box = try AES.GCM.SealedBox(combined: combined)
                try output.write(contentsOf: AES.GCM.open(box, using: key))
            }
            try output.synchronize()
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func encodedLength(_ count: Int) -> Data {
        let value = UInt32(count)
        return Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else {
                throw VaultError.malformedFile
            }
            result.append(part)
        }
        return result
    }
}

extension DownloadManager: CollectionPolicyApplier {}

extension DownloadManager: URLSessionDownloadDelegate {
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
        let staged = downloadsDirectory.appendingPathComponent("\(trackId).partial")
        try? FileManager.default.removeItem(at: staged)
        let moved = (try? FileManager.default.moveItem(at: location, to: staged)) != nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            if moved {
                self.finishTransfer(trackId: trackId, stagedFile: staged)
            } else {
                self.fail(trackId: trackId, reason: "Could not save the downloaded file.")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
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

enum DownloadSourceSelection {
    struct Source: Equatable {
        let transcoding: Transcoding
        let isHLS: Bool
    }

    static func choose(from transcodings: [Transcoding], ceiling: QualityCeiling = .maximum) -> Source? {
        let pool = ceiling.capping(transcodings)
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
        case .opus: return "opus" // excluded by `choose`; kept exhaustive
        case .unknown: return "audio"
        }
    }
}
