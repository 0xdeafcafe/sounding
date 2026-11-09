import Foundation

enum WatchOfflineSource: String, Codable, Sendable {
    case soundCloud
    case file
}

struct WatchOfflineTrack: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var artist: String
    var album: String?
    var artworkURL: URL?
    var durationSeconds: TimeInterval
    var fileExtension: String
    var bytes: Int64
    var source: WatchOfflineSource

    var fileName: String {
        let safe = String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" })
        return "t\(safe).\(fileExtension)"
    }
}

enum WatchOfflineCollectionKind: String, Codable, Sendable {
    case likes
    case playlist
    case album
    case files

    var symbolName: String {
        switch self {
        case .likes: return "heart.fill"
        case .playlist: return "music.note.list"
        case .album, .files: return "square.stack"
        }
    }
}

struct WatchOfflineCollection: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String
    var kind: WatchOfflineCollectionKind
    var title: String
    var subtitle: String?
    var artworkURL: URL?
    var trackIDs: [String]
}

struct WatchOfflineManifest: Codable, Equatable, Sendable {
    var collections: [WatchOfflineCollection]
    var tracks: [WatchOfflineTrack]
    var budgetBytes: Int64
    var isSoundCloudAuthoritative: Bool
    var skippedForBudget: Int

    static let empty = WatchOfflineManifest(
        collections: [],
        tracks: [],
        budgetBytes: WatchStorageBudget.standard.bytes,
        isSoundCloudAuthoritative: false,
        skippedForBudget: 0
    )

    var plannedIDs: Set<String> { Set(tracks.map(\.id)) }

    func keeps(_ track: WatchOfflineTrack, planned: Set<String>) -> Bool {
        if planned.contains(track.id) { return true }
        return track.source == .soundCloud && !isSoundCloudAuthoritative
    }
}

struct WatchOfflineInventory: Codable, Equatable, Sendable {
    var trackIDs: [String]
    var usedBytes: Int64
    var updatedAtMillis: Int64

    static let empty = WatchOfflineInventory(trackIDs: [], usedBytes: 0, updatedAtMillis: 0)
}

struct WatchPlayReport: Codable, Equatable, Sendable {
    var trackID: String
    var playedAtMillis: Int64
    var title: String
    var artist: String
    var durationSeconds: TimeInterval
    var isLocal: Bool

    var playedAt: Date { Date(timeIntervalSince1970: TimeInterval(playedAtMillis) / 1000) }
}

enum WatchStorageBudget: Int64, CaseIterable, Identifiable, Codable, Sendable {
    case two = 2
    case four = 4
    case eight = 8

    static let standard: WatchStorageBudget = .two

    var id: Int64 { rawValue }
    var bytes: Int64 { rawValue * 1_000_000_000 }
    var displayName: String { "\(rawValue) GB" }
}

enum WatchOfflinePolicy {
    static let playableExtensions: Set<String> = ["m4a", "mp3", "aac", "flac", "wav", "aif", "aiff", "caf", "alac", "mp4"]
    static let unconfirmedLifetime: TimeInterval = 30 * 24 * 3600
    static let maximumConcurrentTransfers = 2
    static let estimatedBytesPerSecond: Double = 32_000

    static func isPlayable(fileExtension: String) -> Bool {
        playableExtensions.contains(fileExtension.lowercased())
    }

    static func isExpired(confirmedAt: Date?, now: Date = Date()) -> Bool {
        guard let confirmedAt else { return true }
        return now.timeIntervalSince(confirmedAt) > unconfirmedLifetime
    }

    static func estimatedBytes(durationSeconds: TimeInterval) -> Int64 {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 8_000_000 }
        return Int64(durationSeconds * estimatedBytesPerSecond)
    }
}

enum WatchOfflinePlanner {
    struct Selection: Sendable {
        var collection: WatchOfflineCollection
        var tracks: [WatchOfflineTrack]
    }

    static func manifest(
        selections: [Selection],
        excluded: Set<String>,
        budgetBytes: Int64,
        isSoundCloudAuthoritative: Bool
    ) -> WatchOfflineManifest {
        var planned: [WatchOfflineTrack] = []
        var plannedIDs = Set<String>()
        var skipped = Set<String>()
        var used: Int64 = 0
        var collections: [WatchOfflineCollection] = []

        for selection in selections {
            var members: [String] = []
            for track in selection.tracks where !excluded.contains(track.id) {
                if plannedIDs.contains(track.id) {
                    members.append(track.id)
                    continue
                }
                guard !skipped.contains(track.id) else { continue }
                guard used + track.bytes <= budgetBytes else {
                    skipped.insert(track.id)
                    continue
                }
                used += track.bytes
                plannedIDs.insert(track.id)
                planned.append(track)
                members.append(track.id)
            }
            guard !members.isEmpty else { continue }
            var collection = selection.collection
            collection.trackIDs = members
            collections.append(collection)
        }

        return WatchOfflineManifest(
            collections: collections,
            tracks: planned,
            budgetBytes: budgetBytes,
            isSoundCloudAuthoritative: isSoundCloudAuthoritative,
            skippedForBudget: skipped.subtracting(plannedIDs).count
        )
    }

    static func pending(
        manifest: WatchOfflineManifest,
        onWatch: Set<String>,
        inFlight: Set<String>,
        limit: Int
    ) -> [WatchOfflineTrack] {
        let open = max(0, limit - inFlight.count)
        guard open > 0 else { return [] }
        return Array(
            manifest.tracks
                .filter { !onWatch.contains($0.id) && !inFlight.contains($0.id) }
                .prefix(open)
        )
    }
}
