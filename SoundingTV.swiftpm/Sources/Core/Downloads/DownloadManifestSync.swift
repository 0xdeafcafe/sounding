import Foundation

enum DownloadManifestDeviceIdentity {
    static let defaultsKey = "red.forbes.sounding.downloadmanifestsync.deviceId"

    static func deviceId(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty { return existing }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: defaultsKey)
        return generated
    }
}

struct DownloadManifestSyncRecord: Codable, Sendable, Equatable {
    let trackId: String
    let deviceId: String
    let deviceLabel: String
    let isPinned: Bool
    let addedAtMillis: Int64
    let updatedAtMillis: Int64
    let isDeleted: Bool

    var recordKey: String { "\(deviceId)#\(trackId)" }
}

enum DownloadManifestSyncPolicy {
    enum Rejection: String, Sendable, Equatable {
        case malformedIdentity
        case labelCarriesLocator
    }

    private static let locatorMarkers = ["http://", "https://", "://", "soundcloud.com", "sndcdn.com"]

    static func validate(_ record: DownloadManifestSyncRecord) -> Rejection? {
        guard !record.trackId.isEmpty, !record.deviceId.isEmpty else { return .malformedIdentity }
        let lowered = record.deviceLabel.lowercased()
        guard !locatorMarkers.contains(where: lowered.contains) else { return .labelCarriesLocator }
        return nil
    }

    static func remoteWins(local: DownloadManifestSyncRecord?, remote: DownloadManifestSyncRecord) -> Bool {
        guard let local else { return true }
        if local == remote { return false }
        return remote.updatedAtMillis >= local.updatedAtMillis
    }
}

protocol DownloadManifestExportSource: Sendable {
    func currentManifest(limit: Int) async -> [DownloadManifestSyncRecord]
}

protocol DownloadManifestImportStore: Sendable {
    @discardableResult
    func adopt(_ records: [DownloadManifestSyncRecord]) async -> Int
}

actor RemoteDownloadManifestStore: DownloadManifestImportStore {
    static let shared = RemoteDownloadManifestStore(fileURL: RemoteDownloadManifestStore.defaultFileURL())

    private var rows: [String: DownloadManifestSyncRecord]
    private let fileURL: URL

    static func defaultFileURL() -> URL {
        AppDataDirectory.file("RemoteDownloadManifest.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: DownloadManifestSyncRecord].self, from: data) {
            rows = decoded
        } else {
            rows = [:]
        }
    }

    @discardableResult
    func adopt(_ records: [DownloadManifestSyncRecord]) async -> Int {
        var adopted = 0
        for record in records {
            guard DownloadManifestSyncPolicy.validate(record) == nil else { continue }
            guard DownloadManifestSyncPolicy.remoteWins(local: rows[record.recordKey], remote: record) else { continue }
            rows[record.recordKey] = record
            adopted += 1
        }
        if adopted > 0 { persist() }
        return adopted
    }

    func manifestsByDevice(excluding localDeviceId: String) -> [String: [DownloadManifestSyncRecord]] {
        Dictionary(grouping: rows.values.filter { !$0.isDeleted && $0.deviceId != localDeviceId }, by: \.deviceId)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct DownloadManifestSyncCursor: Codable, Sendable, Equatable {
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
}

protocol DownloadManifestSyncTransport: Sendable {
    var transportId: String { get }
    func isReady() async -> Bool
    func offer(_ records: [DownloadManifestSyncRecord]) async throws
    func fetch(since cursor: DownloadManifestSyncCursor?) async throws -> (records: [DownloadManifestSyncRecord], cursor: DownloadManifestSyncCursor?)
}

struct DownloadManifestSyncRelay: Sendable {
    let exportSource: any DownloadManifestExportSource
    let importStore: any DownloadManifestImportStore
    let transport: any DownloadManifestSyncTransport
    let exportLimit: Int

    init(
        exportSource: any DownloadManifestExportSource,
        importStore: any DownloadManifestImportStore,
        transport: any DownloadManifestSyncTransport,
        exportLimit: Int = 2_000
    ) {
        self.exportSource = exportSource
        self.importStore = importStore
        self.transport = transport
        self.exportLimit = exportLimit
    }

    struct RoundResult: Sendable, Equatable {
        var fetched = 0
        var adopted = 0
        var offered = 0
        var rejectedOnOffer = 0
        var cursor: DownloadManifestSyncCursor?
        var skippedNotReady = false
    }

    func runOnce(since cursor: DownloadManifestSyncCursor?) async throws -> RoundResult {
        var result = RoundResult()
        guard await transport.isReady() else {
            result.skippedNotReady = true
            return result
        }

        let (incoming, nextCursor) = try await transport.fetch(since: cursor)
        result.fetched = incoming.count
        result.cursor = nextCursor
        result.adopted = incoming.isEmpty ? 0 : await importStore.adopt(incoming)

        let outgoing = await exportSource.currentManifest(limit: exportLimit)
        let valid = outgoing.filter { DownloadManifestSyncPolicy.validate($0) == nil }
        result.rejectedOnOffer = outgoing.count - valid.count
        if !valid.isEmpty {
            try await transport.offer(valid)
        }
        result.offered = valid.count
        return result
    }
}
