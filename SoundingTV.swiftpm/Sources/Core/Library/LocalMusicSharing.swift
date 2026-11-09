import Foundation
import Combine
import CloudKit
import CryptoKit
import Network

struct LocalMusicGrant: Codable, Equatable, Sendable {
    static let lifetime: TimeInterval = 30 * 60

    let id: String
    let key: Data
    let expiresAt: Date

    static func issue(now: Date = Date(), lifetime: TimeInterval = LocalMusicGrant.lifetime) -> LocalMusicGrant {
        LocalMusicGrant(
            id: UUID().uuidString,
            key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
            expiresAt: now.addingTimeInterval(lifetime)
        )
    }

    func isValid(at now: Date = Date()) -> Bool { now < expiresAt }

    var credential: PeerContentAccountCredential? { .grant(id: id, key: key) }
}

struct LocalMusicOffer: Codable, Equatable, Sendable {
    let contentDeviceId: String
    let name: String
    let deviceClass: DeviceClass
    let grant: LocalMusicGrant
    let catalogRevision: String
    let trackCount: Int
    let servesInBackground: Bool

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> LocalMusicOffer? { try? JSONDecoder().decode(LocalMusicOffer.self, from: data) }
}

enum LocalMusicResource: Equatable, Sendable {
    case catalog
    case audio(String)
    case artwork(String)
    case analysis(String)

    var path: String {
        switch self {
        case .catalog: return "local/catalog"
        case .audio(let id): return "local/audio/\(id)"
        case .artwork(let id): return "local/artwork/\(id)"
        case .analysis(let id): return "local/analysis/\(id)"
        }
    }

    init?(path: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "local" else { return nil }
        switch (parts.count, parts.count > 1 ? parts[1] : "") {
        case (2, "catalog"): self = .catalog
        case (3, "audio") where !parts[2].isEmpty: self = .audio(parts[2])
        case (3, "artwork") where !parts[2].isEmpty: self = .artwork(parts[2])
        case (3, "analysis") where !parts[2].isEmpty: self = .analysis(parts[2])
        default: return nil
        }
    }
}

struct LocalMusicCatalogTrack: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let genre: String?
    let duration: Double
    let modifiedAt: Date
    let fileExtension: String
    let fileSize: Int64
    let hasArtwork: Bool
    var bpm: Double?
    var keyWheelPosition: Int?
    var keyMode: Int?
}

struct LocalMusicCatalog: Codable, Equatable, Sendable {
    let revision: String
    let tracks: [LocalMusicCatalogTrack]

    static func revision(of tracks: [LocalMusicCatalogTrack]) -> String {
        var hasher = SHA256()
        for track in tracks {
            hasher.update(data: Data("\(track.id)|\(track.title)|\(track.modifiedAt.timeIntervalSince1970)|\(track.fileSize)\n".utf8))
        }
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

final class LocalMusicDataSource: PeerContentByteSource, @unchecked Sendable {
    private let data: Data

    init(_ data: Data) { self.data = data }

    var length: Int64 { Int64(data.count) }

    func read(offset: Int64, length: Int) throws -> Data {
        let start = Int(max(0, min(offset, self.length)))
        let end = min(data.count, start + max(0, length))
        return data.subdata(in: start..<end)
    }
}

final class LocalMusicFileSource: PeerContentByteSource, @unchecked Sendable {
    let url: URL
    let length: Int64

    init?(url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return nil }
        self.url = url
        self.length = size.int64Value
    }

    func read(offset: Int64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        return try handle.read(upToCount: max(0, length)) ?? Data()
    }
}

enum LocalMusicTransfer {
    static let chunkBytes: Int64 = 2 << 20
    static let parallelRequests = 4
    static let requestTimeout: TimeInterval = 20

    static func fetch(
        _ path: String,
        using client: PeerContentClient,
        write: (Data) throws -> Void
    ) async throws -> Int64 {
        let first = try await client.fetchRange(trackId: path, offset: 0, length: chunkBytes, timeout: requestTimeout)
        try write(first.data)
        var offset = Int64(first.data.count)
        let total = first.totalLength
        while offset < total {
            let starts = Array(stride(from: offset, to: total, by: Int(chunkBytes)).prefix(parallelRequests))
            let chunks = try await withThrowingTaskGroup(of: (Int64, Data).self) { group in
                for start in starts {
                    group.addTask {
                        let range = try await client.fetchRange(
                            trackId: path, offset: start, length: min(chunkBytes, total - start), timeout: requestTimeout
                        )
                        return (start, range.data)
                    }
                }
                var out: [(Int64, Data)] = []
                for try await chunk in group { out.append(chunk) }
                return out.sorted { $0.0 < $1.0 }
            }
            for (start, data) in chunks {
                guard start == offset else { break }
                guard !data.isEmpty else { throw PeerContentError.malformedResponse }
                try write(data)
                offset += Int64(data.count)
            }
        }
        return total
    }

    static func fetchData(_ path: String, using client: PeerContentClient) async throws -> Data {
        var data = Data()
        _ = try await fetch(path, using: client) { data.append($0) }
        return data
    }

    static func fetchFile(_ path: String, using client: PeerContentClient, to destination: URL) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        try? fileManager.removeItem(at: partial)
        guard fileManager.createFile(atPath: partial.path, contents: nil) else { throw PeerContentError.ioError }
        let handle = try FileHandle(forWritingTo: partial)
        do {
            _ = try await fetch(path, using: client) { try handle.write(contentsOf: $0) }
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: partial)
            throw error
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: partial, to: destination)
    }
}

// MARK: - Serving

@MainActor
final class LocalMusicShareHost {
    static let shared = LocalMusicShareHost()
    static let maximumGrants = 4

    private let library: LocalMusicLibrary
    private var grants: [String: LocalMusicGrant] = [:]

    init(library: LocalMusicLibrary = .shared) {
        self.library = library
    }

    var hasMusic: Bool { !shareableEntries.isEmpty }

    var changes: AnyPublisher<Void, Never> {
        library.$tracksByFolder
            .dropFirst()
            .map { _ in () }
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    func offer(now: Date = Date()) -> LocalMusicOffer {
        grants = grants.filter { $0.value.isValid(at: now) }
        let grant = LocalMusicGrant.issue(now: now)
        grants[grant.id] = grant
        while grants.count > Self.maximumGrants,
              let oldest = grants.values.min(by: { $0.expiresAt < $1.expiresAt }) {
            grants[oldest.id] = nil
        }
        let tracks = catalogTracks()
        return LocalMusicOffer(
            contentDeviceId: DownloadManifestDeviceIdentity.deviceId(),
            name: LinkPeerIdentity.localName,
            deviceClass: .current,
            grant: grant,
            catalogRevision: LocalMusicCatalog.revision(of: tracks),
            trackCount: tracks.count,
            servesInBackground: DeviceClass.current == .mac
        )
    }

    func credential(forGrantId id: String, now: Date = Date()) -> PeerContentAccountCredential? {
        guard let grant = grants[id], grant.isValid(at: now) else { return nil }
        return grant.credential
    }

    func revokeAll() {
        grants.removeAll()
    }

    func source(for path: String) async -> (any PeerContentByteSource)? {
        switch LocalMusicResource(path: path) {
        case .catalog:
            guard let data = await catalogData() else { return nil }
            return LocalMusicDataSource(data)
        case .audio(let id):
            guard let url = fileURL(forTrackId: id) else { return nil }
            return await Task.detached(priority: .userInitiated) { LocalMusicFileSource(url: url) }.value
        case .artwork(let id):
            return LocalMusicFileSource(url: library.artworkDirectory.appendingPathComponent("\(id).jpg"))
        case .analysis(let id):
            let records = await AnalysisCache.shared.syncRecords(forTrackIds: [id])
            guard let data = try? JSONEncoder().encode(records) else { return nil }
            return LocalMusicDataSource(data)
        case nil:
            return nil
        }
    }

    private var shareableEntries: [(folder: MusicFolder, entry: LocalMusicFileEntry)] {
        library.folders.flatMap { folder in
            folder.files.filter(\.isDownloaded).map { (folder, $0) }
        }
    }

    func catalogTracks() -> [LocalMusicCatalogTrack] {
        shareableEntries.map { folder, entry in
            LocalMusicCatalogTrack(
                id: LocalMusicScanner.trackID(folderID: folder.id, relativePath: entry.relativePath),
                title: entry.title,
                artist: entry.artist ?? folder.name,
                album: entry.album,
                genre: entry.genre,
                duration: entry.duration,
                modifiedAt: entry.addedAt ?? entry.modifiedAt,
                fileExtension: (entry.relativePath as NSString).pathExtension.lowercased(),
                fileSize: entry.fileSize,
                hasArtwork: entry.hasArtwork
            )
        }
    }

    private func catalogData() async -> Data? {
        var tracks = catalogTracks()
        let summaries = await AnalysisSummaryStore.summaries(forTrackIds: tracks.map(\.id))
        for index in tracks.indices {
            guard let summary = summaries[tracks[index].id] else { continue }
            tracks[index].bpm = summary.bpm
            tracks[index].keyWheelPosition = summary.key?.wheelPosition
            tracks[index].keyMode = summary.key?.mode.rawValue
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try? encoder.encode(LocalMusicCatalog(revision: LocalMusicCatalog.revision(of: tracks), tracks: tracks))
    }

    func artworkURL(forTrackId id: String) -> URL? {
        let url = library.artworkDirectory.appendingPathComponent("\(id).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func fileURL(forTrackId id: String) -> URL? {
        guard let match = shareableEntries.first(where: {
            LocalMusicScanner.trackID(folderID: $0.folder.id, relativePath: $0.entry.relativePath) == id
        }) else { return nil }
        guard let url = LocalMusicAccess.shared.fileURL(
            for: LocalTrackFile(folderID: match.folder.id, relativePath: match.entry.relativePath)
        ), FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }
}

// MARK: - Receiving

enum RemoteLocalMusicError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case unknownDevice

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .unknownDevice: return "This track's device is no longer linked."
        }
    }
}

@MainActor
final class RemoteLocalMusic: ObservableObject {
    static let shared = RemoteLocalMusic()
    nonisolated static let folderPrefix = "remote:"
    static let refreshLead: TimeInterval = 5 * 60
    static let cacheBudgetBytes: Int64 = 3 << 30

    struct Device: Identifiable, Equatable, Codable, Sendable {
        let id: String
        var sessionId: String
        var name: String
        var deviceClass: DeviceClass?
        var servesInBackground: Bool
        var catalog: LocalMusicCatalog?

        var isCloud: Bool { id == RemoteLocalMusic.cloudDeviceId }

        var sourceLabel: String { isCloud ? "In iCloud" : "On \(name)" }

        var symbolName: String { isCloud ? "icloud" : deviceClass?.symbolName ?? "music.note.house" }

        private var needsAppOpen: Bool {
            !servesInBackground && (deviceClass == .phone || deviceClass == .pad)
        }

        var unavailableTitle: String {
            if isCloud { return "iCloud Isn't Available" }
            return needsAppOpen ? "Open Sounding on \(name)" : "\(name) Isn't Available"
        }

        var unavailableMessage: String {
            if isCloud { return "Sign in to iCloud on this Apple TV to play music you uploaded." }
            return needsAppOpen
                ? "\(name) shares its music while Sounding is open."
                : "Make sure \(name) is awake, nearby and running Sounding."
        }
    }

    nonisolated static let cloudDeviceId = "icloud"
    static let cloudRefreshInterval: TimeInterval = 10 * 60

    @Published private(set) var devices: [Device] = []
    @Published private(set) var availableDeviceIds: Set<String> = []
    @Published private(set) var tracksByDevice: [String: [Track]] = [:]
    @Published private(set) var loadingDeviceIds: Set<String> = []
    @Published private(set) var cloudTrackIds: Set<String> = []

    private var cloudAvailable = false
    private var cloudRefreshedAt: Date?
    private var cloudTask: Task<Void, Never>?

    weak var endpoints: (any PeerContentSessionProvider)?
    var requestOffers: () -> Void = {}

    private var offers: [String: LocalMusicOffer] = [:]
    private var clients: [String: (grantId: String, client: PeerContentClient)] = [:]
    private var catalogTasks: [String: Task<Void, Never>] = [:]
    private var transfers: [String: Task<URL, Error>] = [:]
    private var isFixture = false

    init() {
        #if DEBUG
        if let fixture = Self.fixture() {
            isFixture = true
            devices = fixture.devices
            availableDeviceIds = fixture.available
            rebuildTracks()
            return
        }
        #endif
        devices = Self.loadDevices()
        rebuildTracks()
    }

    nonisolated static func isRemote(_ file: LocalTrackFile) -> Bool {
        file.folderID.hasPrefix(folderPrefix)
    }

    nonisolated static func deviceId(of file: LocalTrackFile) -> String? {
        guard isRemote(file) else { return nil }
        let id = String(file.folderID.dropFirst(folderPrefix.count))
        return id.isEmpty ? nil : id
    }

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("RemoteMusic", isDirectory: true)
    }

    nonisolated static func deviceDirectory(_ deviceId: String) -> URL {
        directory.appendingPathComponent(PeerContentServer.serviceToken(for: deviceId), isDirectory: true)
    }

    nonisolated static func audioURL(for file: LocalTrackFile) -> URL? {
        guard let deviceId = deviceId(of: file) else { return nil }
        return deviceDirectory(deviceId).appendingPathComponent(file.relativePath)
    }

    nonisolated static func cachedFileURL(for file: LocalTrackFile) -> URL? {
        guard let url = audioURL(for: file), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var allTracks: [Track] {
        orderedDevices.flatMap { tracksByDevice[$0.id] ?? [] }
    }

    var availableTracks: [Track] {
        orderedDevices.filter { isAvailable($0) }.flatMap { tracksByDevice[$0.id] ?? [] }
    }

    var orderedDevices: [Device] {
        devices.sorted { lhs, rhs in
            let left = isAvailable(lhs), right = isAvailable(rhs)
            if left != right { return left }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var hasMusic: Bool { devices.contains { !($0.catalog?.tracks.isEmpty ?? true) } }

    func isAvailable(_ device: Device) -> Bool { availableDeviceIds.contains(device.id) }

    func device(for track: Track) -> Device? {
        guard let file = track.localFile, let id = Self.deviceId(of: file) else { return nil }
        return devices.first { $0.id == id }
    }

    func isAvailable(_ track: Track) -> Bool {
        guard let device = device(for: track) else { return false }
        return isAvailable(device)
            || track.localFile.flatMap(Self.cachedFileURL(for:)) != nil
            || (cloudAvailable && cloudTrackIds.contains(track.id))
    }

    func sourceLabel(for track: Track) -> String? { device(for: track)?.sourceLabel }

    // MARK: - Offers

    func adopt(_ offer: LocalMusicOffer, sessionId: String) {
        guard !isFixture else { return }
        offers[offer.contentDeviceId] = offer
        if let index = devices.firstIndex(where: { $0.id == offer.contentDeviceId }) {
            devices[index].sessionId = sessionId
            devices[index].name = offer.name
            devices[index].deviceClass = offer.deviceClass
            devices[index].servesInBackground = offer.servesInBackground
        } else {
            devices.append(Device(
                id: offer.contentDeviceId, sessionId: sessionId, name: offer.name,
                deviceClass: offer.deviceClass, servesInBackground: offer.servesInBackground, catalog: nil
            ))
        }
        if let existing = clients[offer.contentDeviceId], existing.grantId != offer.grant.id {
            existing.client.disconnect()
            clients[offer.contentDeviceId] = nil
        }
        recomputeAvailability()
        saveDevices()
        let current = devices.first { $0.id == offer.contentDeviceId }?.catalog?.revision
        if offer.trackCount == 0 {
            setCatalog(LocalMusicCatalog(revision: offer.catalogRevision, tracks: []), for: offer.contentDeviceId)
        } else if current != offer.catalogRevision {
            loadCatalog(deviceId: offer.contentDeviceId)
        }
    }

    func forget(sessionId: String) {
        let removed = devices.filter { $0.sessionId == sessionId }
        guard !removed.isEmpty else { return }
        for device in removed {
            offers[device.id] = nil
            clients.removeValue(forKey: device.id)?.client.disconnect()
            catalogTasks.removeValue(forKey: device.id)?.cancel()
            tracksByDevice[device.id] = nil
            try? FileManager.default.removeItem(at: Self.deviceDirectory(device.id))
        }
        devices.removeAll { $0.sessionId == sessionId }
        recomputeAvailability()
        saveDevices()
    }

    func endpointsChanged() {
        guard !isFixture else { return }
        recomputeAvailability()
    }

    func refreshIfNeeded(now: Date = Date()) {
        guard !isFixture else { return }
        let stale = devices.contains { device in
            guard let offer = offers[device.id] else { return true }
            return offer.grant.expiresAt.timeIntervalSince(now) < Self.refreshLead
        }
        if stale || devices.isEmpty { requestOffers() }
        refreshCloud()
    }

    private func recomputeAvailability(now: Date = Date()) {
        let available = Set(devices.compactMap { device -> String? in
            guard let offer = offers[device.id], offer.grant.isValid(at: now),
                  endpoints?.peerContentEndpoint(forDeviceId: device.id) != nil else { return nil }
            return device.id
        }).union(cloudAvailable ? [Self.cloudDeviceId] : [])
        if available != availableDeviceIds { availableDeviceIds = available }
    }

    // MARK: - Catalog

    private func loadCatalog(deviceId: String) {
        guard catalogTasks[deviceId] == nil else { return }
        loadingDeviceIds.insert(deviceId)
        catalogTasks[deviceId] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.catalogTasks[deviceId] = nil
                self.loadingDeviceIds.remove(deviceId)
            }
            do {
                let client = try await self.client(for: deviceId)
                let data = try await LocalMusicTransfer.fetchData(LocalMusicResource.catalog.path, using: client)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                let catalog = try decoder.decode(LocalMusicCatalog.self, from: data)
                self.setCatalog(catalog, for: deviceId)
                await self.loadArtwork(deviceId: deviceId, catalog: catalog, client: client)
            } catch {
                Log.link.info("[RemoteLocalMusic] catalog unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func setCatalog(_ catalog: LocalMusicCatalog, for deviceId: String) {
        guard let index = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[index].catalog = catalog
        saveDevices()
        rebuildTracks()
    }

    private func loadArtwork(deviceId: String, catalog: LocalMusicCatalog, client: PeerContentClient) async {
        let folder = Self.deviceDirectory(deviceId)
        var fetched = 0
        for track in catalog.tracks where track.hasArtwork {
            guard !Task.isCancelled else { return }
            let destination = folder.appendingPathComponent("\(track.id).jpg")
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            guard (try? await LocalMusicTransfer.fetchFile(
                LocalMusicResource.artwork(track.id).path, using: client, to: destination
            )) != nil else { continue }
            fetched += 1
            if fetched % 24 == 0 { rebuildTracks(deviceId: deviceId) }
        }
        if fetched > 0 { rebuildTracks(deviceId: deviceId) }
    }

    private func rebuildTracks(deviceId: String? = nil) {
        for device in devices where deviceId == nil || device.id == deviceId {
            var entries = device.catalog?.tracks ?? []
            if device.isCloud {
                let elsewhere = Set(devices.filter { !$0.isCloud }.flatMap { $0.catalog?.tracks.map(\.id) ?? [] })
                entries.removeAll { elsewhere.contains($0.id) }
            }
            tracksByDevice[device.id] = entries.compactMap { Self.makeTrack($0, device: device) }
        }
    }

    static func makeTrack(_ entry: LocalMusicCatalogTrack, device: Device) -> Track? {
        let folder = deviceDirectory(device.id)
        let name = entry.fileExtension.isEmpty ? entry.id : "\(entry.id).\(entry.fileExtension)"
        let artwork = folder.appendingPathComponent("\(entry.id).jpg")
        let token = PeerContentServer.serviceToken(for: device.id)
        return LocalMusicLibrary.makeTrack(
            id: entry.id,
            title: entry.title,
            artist: entry.artist ?? device.name,
            album: entry.album,
            genre: entry.genre,
            duration: entry.duration,
            modifiedAt: entry.modifiedAt,
            fileURL: URL(string: "sounding-remote://\(token)/\(name)") ?? folder.appendingPathComponent(name),
            ownerURL: URL(string: "sounding-remote://\(token)") ?? folder,
            artworkURL: entry.hasArtwork && FileManager.default.fileExists(atPath: artwork.path) ? artwork : nil,
            localFile: LocalTrackFile(folderID: folderPrefix + device.id, relativePath: name)
        )
    }

    // MARK: - Playback

    func playableURL(for track: Track) async throws -> URL {
        guard let file = track.localFile, let deviceId = Self.deviceId(of: file),
              let device = devices.first(where: { $0.id == deviceId }) else { throw RemoteLocalMusicError.unknownDevice }
        if let cached = Self.cachedFileURL(for: file) {
            touch(cached)
            return cached
        }
        #if DEBUG
        if isFixture {
            guard isAvailable(device) else { throw RemoteLocalMusicError.unavailable(device.unavailableMessage) }
            if let url = await FixtureAudio.url() { return url }
        }
        #endif
        refreshIfNeeded()
        guard let destination = Self.audioURL(for: file) else { throw RemoteLocalMusicError.unknownDevice }
        if let running = transfers[track.id] { return try await running.value }
        let trackId = track.id
        let lanDeviceId = lanSource(forTrackId: trackId, preferring: device)
        let cloudHasIt = cloudAvailable && cloudTrackIds.contains(trackId)
        guard lanDeviceId != nil || cloudHasIt else {
            throw RemoteLocalMusicError.unavailable(device.unavailableMessage)
        }
        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            if let lanDeviceId {
                do {
                    try await self.fetchOverNetwork(trackId: trackId, from: lanDeviceId, to: destination)
                    return destination
                } catch {
                    self.clients.removeValue(forKey: lanDeviceId)?.client.disconnect()
                    self.recomputeAvailability()
                    guard cloudHasIt else { throw error }
                }
            }
            try await Self.fetchFromCloud(trackId: trackId, to: destination)
            return destination
        }
        transfers[trackId] = task
        defer { transfers[trackId] = nil }
        do {
            let url = try await task.value
            pruneCache(keeping: url)
            return url
        } catch {
            throw isAvailable(track) ? error : RemoteLocalMusicError.unavailable(device.unavailableMessage)
        }
    }

    private func lanSource(forTrackId trackId: String, preferring device: Device) -> String? {
        if !device.isCloud, isAvailable(device) { return device.id }
        return devices.first { candidate in
            !candidate.isCloud && isAvailable(candidate)
                && (candidate.catalog?.tracks.contains { $0.id == trackId } ?? false)
        }?.id
    }

    private func fetchOverNetwork(trackId: String, from deviceId: String, to destination: URL) async throws {
        let client = try await client(for: deviceId)
        try await LocalMusicTransfer.fetchFile(LocalMusicResource.audio(trackId).path, using: client, to: destination)
        if let data = try? await LocalMusicTransfer.fetchData(LocalMusicResource.analysis(trackId).path, using: client),
           let records = try? JSONDecoder().decode([AnalysisSyncRecord].self, from: data), !records.isEmpty {
            await AnalysisCache.shared.adopt(records)
        }
    }

    private nonisolated static func fetchFromCloud(trackId: String, to destination: URL) async throws {
        guard let database = LocalMusicCloudStore.database(),
              let asset = try await LocalMusicCloudStore.audioFile(trackId: trackId, in: database) else {
            throw RemoteLocalMusicError.unavailable("This track isn't in iCloud any more.")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: asset, to: destination)
    }

    // MARK: - iCloud

    func refreshCloud(force: Bool = false, now: Date = Date()) {
        guard !isFixture, cloudTask == nil else { return }
        if !force, let refreshed = cloudRefreshedAt, now.timeIntervalSince(refreshed) < Self.cloudRefreshInterval { return }
        cloudTask = Task { [weak self] in
            defer { self?.cloudTask = nil }
            guard let database = LocalMusicCloudStore.database(), await LocalMusicCloudStore.isAccountAvailable() else {
                self?.applyCloud(nil)
                return
            }
            let records = try? await LocalMusicCloudStore.fetchAll(
                in: database,
                desiredKeys: LocalMusicCloudSchema.metadataKeys + [LocalMusicCloudSchema.Field.artwork]
            )
            guard let records else { return }
            let folder = Self.deviceDirectory(Self.cloudDeviceId)
            let tracks = await Task.detached(priority: .utility) { () -> [LocalMusicCatalogTrack] in
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return records.compactMap { record -> LocalMusicCatalogTrack? in
                    guard let track = LocalMusicCloudSchema.catalogTrack(from: record) else { return nil }
                    if let artwork = (record[LocalMusicCloudSchema.Field.artwork] as? CKAsset)?.fileURL {
                        let destination = folder.appendingPathComponent("\(track.id).jpg")
                        if !FileManager.default.fileExists(atPath: destination.path) {
                            try? FileManager.default.copyItem(at: artwork, to: destination)
                        }
                    }
                    return track
                }
            }.value
            self?.applyCloud(tracks.sorted { $0.modifiedAt > $1.modifiedAt })
        }
    }

    private func applyCloud(_ tracks: [LocalMusicCatalogTrack]?) {
        cloudAvailable = tracks != nil
        cloudRefreshedAt = tracks == nil ? nil : Date()
        cloudTrackIds = Set(tracks?.map(\.id) ?? [])
        devices.removeAll { $0.isCloud }
        tracksByDevice[Self.cloudDeviceId] = nil
        if let tracks, !tracks.isEmpty {
            devices.append(Device(
                id: Self.cloudDeviceId, sessionId: "", name: "iCloud", deviceClass: nil, servesInBackground: true,
                catalog: LocalMusicCatalog(revision: LocalMusicCatalog.revision(of: tracks), tracks: tracks)
            ))
        }
        recomputeAvailability()
        saveDevices()
        rebuildTracks()
    }

    private func client(for deviceId: String) async throws -> PeerContentClient {
        guard let offer = offers[deviceId], offer.grant.isValid(),
              let credential = offer.grant.credential else {
            throw RemoteLocalMusicError.unavailable(devices.first { $0.id == deviceId }?.unavailableMessage ?? "")
        }
        if let existing = clients[deviceId], existing.grantId == offer.grant.id { return existing.client }
        guard let endpoint = endpoints?.peerContentEndpoint(forDeviceId: deviceId) else {
            throw RemoteLocalMusicError.unavailable(devices.first { $0.id == deviceId }?.unavailableMessage ?? "")
        }
        let client = PeerContentClient(accountCredential: credential)
        try await client.connect(to: endpoint.endpoint, sessionId: endpoint.sessionId, secret: endpoint.secret, timeout: 6)
        clients[deviceId] = (offer.grant.id, client)
        return client
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func pruneCache(keeping kept: URL) {
        let budget = Self.cacheBudgetBytes
        Task.detached(priority: .utility) {
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            let urls = FileManager.default.enumerator(at: Self.directory, includingPropertiesForKeys: keys)?.allObjects as? [URL] ?? []
            var files: [(url: URL, size: Int64, date: Date)] = []
            for url in urls where url.pathExtension != "jpg" && url.pathExtension != "json" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), let size = values.fileSize else { continue }
                files.append((url, Int64(size), values.contentModificationDate ?? .distantPast))
            }
            var total = files.reduce(Int64(0)) { $0 + $1.size }
            for file in files.sorted(by: { $0.date < $1.date }) where total > budget && file.url != kept {
                try? FileManager.default.removeItem(at: file.url)
                total -= file.size
            }
        }
    }

    // MARK: - Persistence

    private static var devicesURL: URL { directory.appendingPathComponent("devices.json") }

    private static func loadDevices() -> [Device] {
        guard let data = try? Data(contentsOf: devicesURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode([Device].self, from: data)) ?? []
    }

    private func saveDevices() {
        guard !isFixture else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(devices) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.devicesURL, options: .atomic)
    }
}

#if DEBUG
extension RemoteLocalMusic {
    static func fixture() -> (devices: [Device], available: Set<String>)? {
        guard let mode = ProcessInfo.processInfo.environment["SOUNDING_TV_REMOTE_MUSIC_FIXTURE"]?.lowercased() else { return nil }
        if mode == "empty" { return ([], []) }
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        func track(_ id: Int, _ title: String, _ artist: String, _ genre: String, _ seconds: Double, bpm: Double?) -> LocalMusicCatalogTrack {
            LocalMusicCatalogTrack(
                id: String(-id), title: title, artist: artist, album: nil, genre: genre, duration: seconds,
                modifiedAt: base.addingTimeInterval(-Double(id)), fileExtension: "flac",
                fileSize: Int64(seconds * 90_000), hasArtwork: false, bpm: bpm
            )
        }
        let allMacTracks = [
            track(1001, "First Light", "Night Tapes", "Deep House", 372, bpm: 122),
            track(1002, "Neon Weather", "Maya Sol", "House", 401, bpm: 124),
            track(1003, "After Hours", "Glass District", "Tech House", 428, bpm: 126),
            track(1004, "Open Water", "Low Sun", "Melodic Techno", 455, bpm: 123),
            track(1005, "Parallel Lines", "Juno Vale", "Techno", 389, bpm: 130),
            track(1006, "Home Signal", "Soft Static", "Ambient", 512, bpm: nil),
            track(1007, "Glue (Club Edit)", "Night Tapes", "House", 318, bpm: 125),
        ]
        let macTracks = mode == "dimmed" ? Array(allMacTracks.prefix(4)) : allMacTracks
        let phoneTracks = [
            track(2001, "Copper Wire", "Maya Sol", "Garage", 284, bpm: 132),
            track(2002, "Slow Return", "Low Sun", "Downtempo", 341, bpm: 98),
            track(2003, "Late Bus", "Juno Vale", "Breaks", 297, bpm: 128),
        ]
        let mac = Device(
            id: "fixture-mac", sessionId: "fixture-mac", name: "Studio Mac", deviceClass: .mac,
            servesInBackground: true,
            catalog: LocalMusicCatalog(revision: LocalMusicCatalog.revision(of: macTracks), tracks: macTracks)
        )
        let phone = Device(
            id: "fixture-phone", sessionId: "fixture-phone", name: "iPhone", deviceClass: .phone,
            servesInBackground: false,
            catalog: LocalMusicCatalog(revision: LocalMusicCatalog.revision(of: phoneTracks), tracks: phoneTracks)
        )
        switch mode {
        case "offline": return ([mac, phone], [])
        default: return ([mac, phone], [mac.id])
        }
    }
}
#endif
