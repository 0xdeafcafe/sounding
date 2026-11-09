import Combine
import Foundation
import WatchConnectivity
import os

struct WatchSendSelection: Codable, Hashable, Sendable, Identifiable {
    static let localAlbumPrefix = "local.album."

    var id: String
    var kind: WatchOfflineCollectionKind
    var title: String
    var subtitle: String?
    var artworkURL: URL?

    static let likes = WatchSendSelection(id: CollectionPolicyID.likedTracks, kind: .likes, title: "Likes")

    init(id: String, kind: WatchOfflineCollectionKind, title: String, subtitle: String? = nil, artworkURL: URL? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
    }

    init(playlist: Playlist) {
        self.init(
            id: playlist.id,
            kind: playlist.isAlbum ? .album : .playlist,
            title: playlist.title,
            subtitle: playlist.user.displayName,
            artworkURL: playlist.displayArtworkURL
        )
    }

    init(local: LocalCollection) {
        self.init(id: Self.localAlbumPrefix + local.id, kind: .files, title: local.title, subtitle: local.subtitle)
    }

    var localAlbumID: String? {
        guard id.hasPrefix(Self.localAlbumPrefix) else { return nil }
        return String(id.dropFirst(Self.localAlbumPrefix.count))
    }
}

@MainActor
final class PhoneWatchOfflineSync: ObservableObject {
    static let shared = PhoneWatchOfflineSync()

    @Published private(set) var selections: [WatchSendSelection]
    @Published private(set) var budget: WatchStorageBudget
    @Published private(set) var excludedTrackIDs: Set<String>
    @Published private(set) var manifest: WatchOfflineManifest = .empty
    @Published private(set) var inventory: WatchOfflineInventory = .empty
    @Published private(set) var sendingCount = 0

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var rebuildTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var preparing: Set<String> = []
    private var retryAfter: [String: Date] = [:]
    private var isStarted = false
    private var didSweepStaging = false

    private static let selectionsKey = "red.forbes.sounding.watchOffline.selections"
    private static let budgetKey = "red.forbes.sounding.watchOffline.budget"
    private static let excludedKey = "red.forbes.sounding.watchOffline.excluded"
    private static let retryDelay: TimeInterval = 10 * 60

    nonisolated static var stagingDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchTransfers", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selections = defaults.data(forKey: Self.selectionsKey)
            .flatMap { try? JSONDecoder().decode([WatchSendSelection].self, from: $0) } ?? []
        budget = WatchStorageBudget(rawValue: Int64(defaults.integer(forKey: Self.budgetKey))) ?? .standard
        excludedTrackIDs = Set(defaults.stringArray(forKey: Self.excludedKey) ?? [])
    }

    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    private var canTransfer: Bool {
        guard let session else { return false }
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    var onWatchCount: Int { inventory.trackIDs.count }

    func isSending(_ id: String) -> Bool {
        selections.contains { $0.id == id }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let downloads = DownloadManager.shared
        downloads.$entries.map { _ in () }
            .merge(with: downloads.$collections.map { _ in () })
            .merge(with: LocalMusicLibrary.shared.$tracksByFolder.map { _ in () })
            .merge(with: SubscriptionService.shared.$verification.map { _ in () })
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AccountDataVault.didForgetAccountData)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.forgetSoundCloudSelections() }
            .store(in: &cancellables)
        if let session, session.activationState == .activated,
           let data = session.receivedApplicationContext[WatchLinkKey.offlineInventory] as? Data,
           let value = WatchLinkCodec.decode(WatchOfflineInventory.self, from: data) {
            inventory = value
        }
        scheduleRebuild()
    }

    func sessionDidActivate() {
        guard let session else { return }
        if let data = session.receivedApplicationContext[WatchLinkKey.offlineInventory] as? Data,
           let value = WatchLinkCodec.decode(WatchOfflineInventory.self, from: data) {
            inventory = value
        }
        if !didSweepStaging, session.activationState == .activated, preparing.isEmpty {
            didSweepStaging = true
            let staged = Set(session.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
            Task.detached(priority: .utility) { Self.sweepStaging(keeping: staged) }
        }
        schedulePump()
    }

    func setSending(_ on: Bool, _ selection: WatchSendSelection) {
        var updated = selections.filter { $0.id != selection.id }
        if on {
            updated.append(selection)
            let members = Set(selectionTracks(selection).map(\.id))
            if !excludedTrackIDs.isDisjoint(with: members) {
                storeExcluded(excludedTrackIDs.subtracting(members))
            }
        }
        storeSelections(updated)
        scheduleRebuild()
    }

    func setBudget(_ value: WatchStorageBudget) {
        guard value != budget else { return }
        budget = value
        defaults.set(Int(value.rawValue), forKey: Self.budgetKey)
        scheduleRebuild()
    }

    func ingestInventory(_ value: WatchOfflineInventory) {
        guard value.updatedAtMillis >= inventory.updatedAtMillis else { return }
        inventory = value
        schedulePump()
    }

    func handleRemoval(collectionId: String?, trackId: String?) {
        if let collectionId {
            storeSelections(selections.filter { $0.id != collectionId })
        }
        if let trackId {
            storeExcluded(excludedTrackIDs.union([trackId]))
        }
        scheduleRebuild()
    }

    func record(_ report: WatchPlayReport) {
        let playedAt = report.playedAt
        let downloaded = DownloadManager.shared.cachedTrack(forTrackId: report.trackID)
        let local = report.isLocal ? LocalMusicLibrary.shared.allTracks.first { $0.id == report.trackID } : nil
        if let track = downloaded ?? local {
            RecentlyPlayed.shared.record(track, at: playedAt)
        }
        guard !report.isLocal, !LocalTrackFile.isLocalTrackID(report.trackID) else { return }
        PlayHistoryReporter.shared.enqueue(trackID: report.trackID, playedAt: playedAt)
    }

    func transferFinished(stagedURL: URL, trackID: String?, failure: String?) {
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: stagedURL) }
        if let trackID {
            preparing.remove(trackID)
            retryAfter[trackID] = Date().addingTimeInterval(Self.retryDelay)
            if let failure {
                Log.link.error("[WatchOffline] transfer failed: \(failure, privacy: .public)")
            }
        }
        refreshSendingCount()
        schedulePump()
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.rebuild()
        }
    }

    private func rebuild() {
        let downloads = DownloadManager.shared
        let authoritative = downloads.isIndexLoaded || !SubscriptionService.shared.hasAuthenticatedSession
        let plan = WatchOfflinePlanner.manifest(
            selections: selections.map { selection in
                WatchOfflinePlanner.Selection(
                    collection: WatchOfflineCollection(
                        id: selection.id,
                        kind: selection.kind,
                        title: selection.title,
                        subtitle: selection.subtitle,
                        artworkURL: selection.artworkURL,
                        trackIDs: []
                    ),
                    tracks: selectionTracks(selection)
                )
            },
            excluded: excludedTrackIDs,
            budgetBytes: budget.bytes,
            isSoundCloudAuthoritative: authoritative
        )
        if plan != manifest { manifest = plan }
        schedulePump()
    }

    private func selectionTracks(_ selection: WatchSendSelection) -> [WatchOfflineTrack] {
        if let albumID = selection.localAlbumID {
            let album = LocalCollections.albums(from: LocalMusicLibrary.shared.allTracks).first { $0.id == albumID }
            return album?.tracks.compactMap { Self.offlineTrack(local: $0) } ?? []
        }
        return DownloadManager.shared.entries.values
            .filter { $0.isDownloaded && $0.collectionIDs.contains(selection.id) }
            .sorted { $0.addedAt < $1.addedAt }
            .compactMap { self.offlineTrack(entry: $0) }
    }

    private func offlineTrack(entry: DownloadEntry) -> WatchOfflineTrack? {
        let track = entry.track
        let downloads = DownloadManager.shared
        guard !track.isLocal, !track.isPreviewOnly,
              downloads.isLocallyAvailable(trackId: track.id),
              downloads.entitlementDenial(for: track) == nil,
              downloads.downloadRefusalReason(for: track) == nil,
              let fileExtension = entry.originalFileExtension?.lowercased(),
              WatchOfflinePolicy.isPlayable(fileExtension: fileExtension) else { return nil }
        return WatchOfflineTrack(
            id: track.id,
            title: track.title,
            artist: track.publisher?.artist ?? track.user.displayName,
            album: track.albumName,
            artworkURL: track.artworkURL,
            durationSeconds: track.duration,
            fileExtension: fileExtension,
            bytes: entry.fileSize > 0 ? entry.fileSize : WatchOfflinePolicy.estimatedBytes(durationSeconds: track.duration),
            source: .soundCloud
        )
    }

    private static func offlineTrack(local track: Track) -> WatchOfflineTrack? {
        guard let file = track.localFile else { return nil }
        let fileExtension = (file.relativePath as NSString).pathExtension.lowercased()
        guard WatchOfflinePolicy.isPlayable(fileExtension: fileExtension) else { return nil }
        let size = LocalMusicLibrary.readyFileURL(for: track)
            .flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .map(Int64.init)
        return WatchOfflineTrack(
            id: track.id,
            title: track.title,
            artist: track.user.displayName,
            album: track.albumName,
            artworkURL: nil,
            durationSeconds: track.duration,
            fileExtension: fileExtension,
            bytes: size ?? WatchOfflinePolicy.estimatedBytes(durationSeconds: track.duration),
            source: .file
        )
    }

    private func schedulePump() {
        guard pumpTask == nil else { return }
        pumpTask = Task { @MainActor [weak self] in
            await Task.yield()
            await self?.pump()
            self?.pumpTask = nil
        }
    }

    private func pump() async {
        guard canTransfer, let session else { return }
        let now = Date()
        retryAfter = retryAfter.filter { $0.value > now }
        let inFlight = Set(session.outstandingFileTransfers.compactMap { Self.trackID(of: $0.file.metadata) })
            .union(preparing)
        let candidates = WatchOfflinePlanner.pending(
            manifest: manifest,
            onWatch: Set(inventory.trackIDs).union(retryAfter.keys),
            inFlight: inFlight,
            limit: WatchOfflinePolicy.maximumConcurrentTransfers
        )
        refreshSendingCount()
        for track in candidates {
            preparing.insert(track.id)
            guard let staged = await stage(track) else {
                preparing.remove(track.id)
                retryAfter[track.id] = Date().addingTimeInterval(Self.retryDelay)
                continue
            }
            guard canTransfer, manifest.plannedIDs.contains(track.id) else {
                preparing.remove(track.id)
                try? FileManager.default.removeItem(at: staged)
                continue
            }
            _ = session.transferFile(staged, metadata: WatchLinkCodec.message(.offlineFile, track))
            preparing.remove(track.id)
        }
        refreshSendingCount()
    }

    private func stage(_ track: WatchOfflineTrack) async -> URL? {
        let destination = Self.stagingDirectory.appendingPathComponent(track.fileName)
        switch track.source {
        case .soundCloud:
            guard let plaintext = await DownloadManager.shared.temporaryPlaintextFile(trackID: track.id) else { return nil }
            let copied = await Self.copy(plaintext.url, to: destination)
            plaintext.release()
            return copied
        case .file:
            guard let local = LocalMusicLibrary.shared.allTracks.first(where: { $0.id == track.id }),
                  let url = try? await LocalMusicLibrary.shared.playableURL(for: local) else { return nil }
            return await Self.copy(url, to: destination)
        }
    }

    private func refreshSendingCount() {
        let outstanding = session?.outstandingFileTransfers.count ?? 0
        let count = outstanding + preparing.count
        if count != sendingCount { sendingCount = count }
    }

    nonisolated static func trackID(of metadata: [String: Any]?) -> String? {
        guard let metadata, WatchLinkCodec.kind(of: metadata) == .offlineFile else { return nil }
        return WatchLinkCodec.payload(WatchOfflineTrack.self, from: metadata)?.id
    }

    private nonisolated static func copy(_ source: URL, to destination: URL) async -> URL? {
        await Task.detached(priority: .utility) { () -> URL? in
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                try manager.copyItem(at: source, to: destination)
                return destination
            } catch {
                return nil
            }
        }.value
    }

    private nonisolated static func sweepStaging(keeping names: Set<String>) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where !names.contains(file.lastPathComponent) {
            try? manager.removeItem(at: file)
        }
    }

    private func storeSelections(_ value: [WatchSendSelection]) {
        selections = value
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.selectionsKey)
        }
    }

    private func storeExcluded(_ value: Set<String>) {
        excludedTrackIDs = value
        defaults.set(Array(value).sorted(), forKey: Self.excludedKey)
    }

    private func forgetSoundCloudSelections() {
        storeSelections(selections.filter { $0.localAlbumID != nil })
        storeExcluded(excludedTrackIDs.filter(LocalTrackFile.isLocalTrackID))
        scheduleRebuild()
    }
}
