import AVFoundation
import CryptoKit
import Foundation

@MainActor
final class PlayedAudioCache {
    static let shared = PlayedAudioCache()

    private struct PendingFill: Sendable {
        let track: Track
        let streamURL: URL
        let transcoding: Transcoding
    }

    private static let ledgerPurpose = "played-audio-ledger"
    private static let networkFeature: NetworkFeature = "play-cache"
    private static let maximumPendingFills = 3

    private let limits: PlayedAudioCacheLedger.Limits
    private var ledger = PlayedAudioCacheLedger()
    private var loadedAccountID: String?
    private var activeFill: (trackID: String, task: Task<Void, Never>)?
    private var pendingFills: [PendingFill] = []
    private var scheduledFills: [String: Task<Void, Never>] = [:]
    private var pausedUntil: Date?
    private var persistTask: Task<Void, Never>?
    private var forgetObserver: NSObjectProtocol?
    private let observer = NetworkActivityTaskObserver(feature: PlayedAudioCache.networkFeature)
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
    }()

    init(limits: PlayedAudioCacheLedger.Limits = .standard) {
        self.limits = limits
        forgetObserver = NotificationCenter.default.addObserver(
            forName: AccountDataVault.didForgetAccountData,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in PlayedAudioCache.shared.removeAll() }
        }
    }

    static var rootDirectory: URL {
        AppDataDirectory.caches.appendingPathComponent("PlayedAudio", isDirectory: true)
    }

    // MARK: - Reading

    func contains(_ track: Track) -> Bool {
        guard !track.isLocal, let accountID = activeAccountID() else { return false }
        loadLedgerIfNeeded(accountID: accountID)
        guard let entry = ledger.entry(for: track.id, now: Date(), limits: limits) else { return false }
        return FileManager.default.fileExists(atPath: fileURL(entry.fileName, accountID: accountID).path)
    }

    func playbackAsset(for track: Track) async -> AVURLAsset? {
        guard !track.isLocal, let accountID = activeAccountID() else { return nil }
        loadLedgerIfNeeded(accountID: accountID)
        let now = Date()
        guard let entry = ledger.entry(for: track.id, now: now, limits: limits) else { return nil }
        let url = fileURL(entry.fileName, accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path),
              let key = DownloadVault.key(for: accountID, createIfMissing: false) else {
            ledger.remove(track.id)
            schedulePersist()
            return nil
        }
        let reader = await Task.detached(priority: .userInitiated) {
            try? EncryptedAudioReader(fileURL: url, key: key)
        }.value
        guard let reader, loadedAccountID == accountID else { return nil }
        ledger.touch(track.id, now: now)
        schedulePersist()
        Log.player.notice("[PlayCache] hit \(track.id, privacy: .public)")
        return VaultPlaybackAsset.make(reader: reader, trackID: track.id, fileExtension: entry.fileExtension)
    }

    // MARK: - Filling

    func noteAudibleStart(of track: Track, streamURL: URL, transcoding: Transcoding?) {
        guard let transcoding, shouldCache(track, transcoding: transcoding) else { return }
        scheduledFills[track.id]?.cancel()
        scheduledFills[track.id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: InstantPlayTuning.fillDelayAfterAudibleStart) } catch { return }
            guard let self else { return }
            self.scheduledFills[track.id] = nil
            guard PlayerService.shared.currentTrack?.id == track.id,
                  self.shouldCache(track, transcoding: transcoding) else { return }
            self.enqueue(PendingFill(track: track, streamURL: streamURL, transcoding: transcoding))
        }
    }

    private func shouldCache(_ track: Track, transcoding: Transcoding) -> Bool {
        guard !track.isLocal,
              transcoding.codec != .opus,
              !transcoding.isSnippet,
              let accountID = activeAccountID(),
              SubscriptionService.shared.playbackGrant(for: track) == .full,
              !DownloadManager.shared.isLocallyAvailable(track),
              !DownloadManager.shared.isOnCellular,
              activeFill?.trackID != track.id,
              !pendingFills.contains(where: { $0.track.id == track.id }) else { return false }
        if let pausedUntil, pausedUntil > Date() { return false }
        loadLedgerIfNeeded(accountID: accountID)
        if ledger.entry(for: track.id, now: Date(), limits: limits) != nil {
            ledger.touch(track.id, now: Date())
            schedulePersist()
            return false
        }
        let estimate = Int64(max(0, track.duration) * Double(max(transcoding.bitrate, 64)) * 1_000 / 8)
        return estimate == 0 || ledger.accepts(bytes: estimate, limits: limits)
    }

    private func enqueue(_ fill: PendingFill) {
        pendingFills.removeAll { $0.track.id == fill.track.id }
        pendingFills.append(fill)
        if pendingFills.count > Self.maximumPendingFills {
            pendingFills.removeFirst(pendingFills.count - Self.maximumPendingFills)
        }
        startNextFill()
    }

    private func startNextFill() {
        guard activeFill == nil, !pendingFills.isEmpty else { return }
        let fill = pendingFills.removeLast()
        guard let accountID = activeAccountID(),
              let key = DownloadVault.key(for: accountID, createIfMissing: true) else {
            pendingFills.removeAll()
            return
        }
        let directory = accountDirectory(accountID)
        let staging = directory.appendingPathComponent("Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let session = session
        let maximumBytes = limits.maximumItemBytes
        let task = Task { @MainActor [weak self] in
            let outcome = await Self.fetch(
                fill: fill,
                staging: staging,
                directory: directory,
                key: key,
                session: session,
                maximumBytes: maximumBytes
            )
            guard let self else { return }
            self.activeFill = nil
            switch outcome {
            case .stored(let fileName, let fileExtension, let bytes):
                if self.activeAccountID() == accountID {
                    self.loadLedgerIfNeeded(accountID: accountID)
                    let now = Date()
                    let evicted = self.ledger.insert(
                        .init(
                            trackID: fill.track.id,
                            fileName: fileName,
                            fileExtension: fileExtension,
                            bytes: bytes,
                            cachedAt: now,
                            lastPlayedAt: now
                        ),
                        now: now,
                        limits: self.limits
                    )
                    self.deleteFiles(evicted, accountID: accountID)
                    self.schedulePersist()
                    Log.player.notice("[PlayCache] stored \(fill.track.id, privacy: .public) \(bytes, privacy: .public) bytes")
                } else {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
                }
            case .rateLimited:
                self.pausedUntil = Date().addingTimeInterval(InstantPlayTuning.fillBackoffAfterRateLimit)
                self.pendingFills.removeAll()
            case .skipped:
                break
            }
            self.startNextFill()
        }
        activeFill = (fill.track.id, task)
    }

    private enum FillOutcome: Sendable {
        case stored(fileName: String, fileExtension: String, bytes: Int64)
        case rateLimited
        case skipped
    }

    private nonisolated static func fetch(
        fill: PendingFill,
        staging: URL,
        directory: URL,
        key: SymmetricKey,
        session: URLSession,
        maximumBytes: Int64
    ) async -> FillOutcome {
        let trackID = fill.track.id
        let plain: URL
        do {
            if fill.transcoding.isProgressive {
                var request = URLRequest(url: fill.streamURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (downloaded, response) = try await session.download(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 429 {
                    try? FileManager.default.removeItem(at: downloaded)
                    return .rateLimited
                }
                guard (200..<300).contains(status) else {
                    try? FileManager.default.removeItem(at: downloaded)
                    return .skipped
                }
                let ext = DownloadSourceSelection.fileExtension(for: fill.transcoding)
                plain = staging.appendingPathComponent("\(trackID)-partial-\(UUID().uuidString).\(ext)")
                try FileManager.default.moveItem(at: downloaded, to: plain)
            } else {
                plain = try await DownloadHLSAssembler.assemble(
                    playlistURL: fill.streamURL,
                    scratchDirectory: staging,
                    trackId: trackID
                ) { _ in }
            }
        } catch {
            if let gateway = error as? SoundCloudGatewayError {
                switch gateway {
                case .endpointCoolingDown, .backgroundPaused, .autonomousWorkSuspended: return .rateLimited
                case .untrustedDestination, .invalidResponse: return .skipped
                }
            }
            if case DownloadError.trafficStopped = error { return .rateLimited }
            return .skipped
        }
        defer { try? FileManager.default.removeItem(at: plain) }
        let bytes = (try? plain.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        guard bytes > 0, bytes <= maximumBytes else { return .skipped }
        let fileExtension = plain.pathExtension.isEmpty ? "audio" : plain.pathExtension
        let fileName = "\(trackID).\(UUID().uuidString.prefix(8)).sctv"
        let destination = directory.appendingPathComponent(fileName)
        let encrypted = await Task.detached(priority: .utility) { () -> Bool in
            do {
                try DownloadVault.encryptFile(at: plain, to: destination, using: key)
                return true
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return false
            }
        }.value
        guard encrypted else { return .skipped }
        return .stored(fileName: fileName, fileExtension: fileExtension, bytes: bytes)
    }

    // MARK: - Removal

    func remove(trackID: String) {
        guard let accountID = activeAccountID() else { return }
        loadLedgerIfNeeded(accountID: accountID)
        if let entry = ledger.remove(trackID) {
            deleteFiles([entry], accountID: accountID)
            schedulePersist()
        }
    }

    func removeAll() {
        for task in scheduledFills.values { task.cancel() }
        scheduledFills.removeAll()
        activeFill?.task.cancel()
        activeFill = nil
        pendingFills.removeAll()
        persistTask?.cancel()
        persistTask = nil
        ledger = PlayedAudioCacheLedger()
        loadedAccountID = nil
        let root = Self.rootDirectory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Storage

    private func activeAccountID() -> String? {
        let subscription = SubscriptionService.shared
        guard subscription.hasAuthenticatedSession, let accountID = subscription.authenticatedAccountID else { return nil }
        return accountID
    }

    private func accountDirectory(_ accountID: String) -> URL {
        Self.rootDirectory.appendingPathComponent(AccountDataVault.storageSuffix(for: accountID), isDirectory: true)
    }

    private func fileURL(_ fileName: String, accountID: String) -> URL {
        accountDirectory(accountID).appendingPathComponent(fileName)
    }

    private func ledgerURL(_ accountID: String) -> URL {
        accountDirectory(accountID).appendingPathComponent("ledger.vault")
    }

    private func loadLedgerIfNeeded(accountID: String) {
        guard loadedAccountID != accountID else { return }
        if let previous = loadedAccountID, previous != accountID {
            activeFill?.task.cancel()
            activeFill = nil
            pendingFills.removeAll()
        }
        loadedAccountID = accountID
        ledger = PlayedAudioCacheLedger()
        guard let sealed = try? Data(contentsOf: ledgerURL(accountID)),
              let key = DownloadVault.key(for: accountID, createIfMissing: false),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key, authenticating: Data(Self.ledgerPurpose.utf8)),
              let decoded = try? JSONDecoder().decode(PlayedAudioCacheLedger.self, from: data) else { return }
        ledger = decoded
        let evicted = ledger.evict(now: Date(), limits: limits)
        if !evicted.isEmpty {
            deleteFiles(evicted, accountID: accountID)
            schedulePersist()
        }
    }

    private func schedulePersist() {
        guard let accountID = loadedAccountID else { return }
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.loadedAccountID == accountID,
                  let key = DownloadVault.key(for: accountID, createIfMissing: true),
                  let data = try? JSONEncoder().encode(self.ledger),
                  let sealed = try? AES.GCM.seal(data, using: key, authenticating: Data(Self.ledgerPurpose.utf8)).combined else { return }
            let url = self.ledgerURL(accountID)
            let directory = self.accountDirectory(accountID)
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? sealed.write(to: url, options: .atomic)
            }.value
        }
    }

    private func deleteFiles(_ entries: [PlayedAudioCacheLedger.Entry], accountID: String) {
        let urls = entries.map { fileURL($0.fileName, accountID: accountID) }
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }
}
