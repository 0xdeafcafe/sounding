import Foundation

struct DownloadEntry: Codable, @unchecked Sendable {
    var track: Track
    var isExplicit: Bool
    var collectionIDs: Set<String>
    var addedAt: Date
    var lastPlayedAt: Date
    var fileName: String?
    var fileSize: Int64
    var encryptionAccountID: String?
    var originalFileExtension: String?
    var sourceFingerprint: String?

    init(
        track: Track,
        isExplicit: Bool,
        collectionIDs: Set<String>,
        addedAt: Date = Date(),
        lastPlayedAt: Date = Date(),
        fileName: String? = nil,
        fileSize: Int64 = 0,
        encryptionAccountID: String? = nil,
        originalFileExtension: String? = nil,
        sourceFingerprint: String? = nil
    ) {
        self.track = track
        self.isExplicit = isExplicit
        self.collectionIDs = collectionIDs
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.fileName = fileName
        self.fileSize = fileSize
        self.encryptionAccountID = encryptionAccountID
        self.originalFileExtension = originalFileExtension
        self.sourceFingerprint = sourceFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case track
        case isExplicit = "isPinned"
        case collectionIDs = "pinningCollectionIds"
        case addedAt, lastPlayedAt, fileName, fileSize
        case encryptionAccountID, originalFileExtension, sourceFingerprint
    }

    var isRetained: Bool { isExplicit || !collectionIDs.isEmpty }
    var isDownloaded: Bool { fileName != nil }
}

enum DownloadTarget: Hashable, Sendable {
    case track(String)
    case collection(String)
}

struct DownloadCollectionDescriptor: Equatable, Sendable {
    let id: String
    let kind: DownloadCollectionKind
    let title: String
    let artworkURL: URL?
    let playlist: Playlist?

    static let likes = DownloadCollectionDescriptor(
        id: CollectionPolicyID.likedTracks,
        kind: .likes,
        title: "Likes",
        artworkURL: nil,
        playlist: nil
    )

    init(playlist: Playlist) {
        id = playlist.id
        kind = .playlist
        title = playlist.title
        artworkURL = playlist.displayArtworkURL
        self.playlist = playlist
    }

    init(id: String, kind: DownloadCollectionKind, title: String, artworkURL: URL?, playlist: Playlist?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.artworkURL = artworkURL
        self.playlist = playlist
    }

    static func forCollectionID(_ id: String, title: String, playlist: Playlist? = nil) -> DownloadCollectionDescriptor {
        if id == CollectionPolicyID.likedTracks { return .likes }
        if let playlist { return DownloadCollectionDescriptor(playlist: playlist) }
        return DownloadCollectionDescriptor(id: id, kind: .playlist, title: title, artworkURL: nil, playlist: nil)
    }
}

struct DownloadSizeEstimate: Equatable, Sendable {
    enum ConfirmationReason: Equatable, Sendable {
        case large
        case cellular
    }

    static let confirmationThresholdBytes: Int64 = 1_000_000_000

    let bytes: Int64
    let trackCount: Int
    let isOnCellular: Bool

    var confirmationReason: ConfirmationReason? {
        if bytes > Self.confirmationThresholdBytes { return .large }
        if isOnCellular, trackCount > 0 { return .cellular }
        return nil
    }

    var requiresConfirmation: Bool { confirmationReason != nil }

    static func estimate(tracks: [Track], ceiling: QualityCeiling, isOnCellular: Bool) -> DownloadSizeEstimate {
        let bytes = tracks.reduce(Int64(0)) {
            $0 + QualitySizeEstimator.estimatedBytes(durationSeconds: $1.duration, ceiling: ceiling)
        }
        return DownloadSizeEstimate(bytes: bytes, trackCount: tracks.count, isOnCellular: isOnCellular)
    }
}

enum DownloadRequestResult: Equatable, Sendable {
    case queued(DownloadSizeEstimate)
    case needsConfirmation(DownloadSizeEstimate)
    case refused(DownloadError)
}

enum DownloadItemState: Equatable, Sendable {
    case downloaded
    case downloading(completed: Int, total: Int)
    case waiting(completed: Int, total: Int)
    case failed(completed: Int, total: Int)
}

struct DownloadedTrackItem: Identifiable, Equatable, Sendable {
    let id: String
    let track: Track
    let bytes: Int64
    let state: DownloadState
    let lastPlayedAt: Date

    static func == (lhs: DownloadedTrackItem, rhs: DownloadedTrackItem) -> Bool {
        lhs.id == rhs.id && lhs.bytes == rhs.bytes && lhs.state == rhs.state && lhs.lastPlayedAt == rhs.lastPlayedAt
    }
}

struct DownloadedCollectionItem: Identifiable, Equatable, Sendable {
    let id: String
    let kind: DownloadCollectionKind
    let title: String
    let artworkURL: URL?
    let trackCount: Int
    let downloadedCount: Int
    let bytes: Int64
    let excludedCount: Int
    let state: DownloadItemState
}

struct DownloadLibrarySnapshot: Equatable, Sendable {
    var playlists: [DownloadedCollectionItem] = []
    var likes: DownloadedCollectionItem?
    var songs: [DownloadedTrackItem] = []
    var storageUsed: Int64 = 0

    var isEmpty: Bool { playlists.isEmpty && likes == nil && songs.isEmpty }
}

enum DownloadCollectionSync {
    struct Plan: Equatable {
        var attach: [String] = []
        var detach: [String] = []
        var prunedExclusions: Set<String> = []
    }

    static func plan(
        collectionID: String,
        memberIDs: [String],
        excluded: Set<String>,
        entries: [String: DownloadEntry],
        authoritative: Bool
    ) -> Plan {
        var plan = Plan()
        var seen = Set<String>()
        for id in memberIDs where seen.insert(id).inserted {
            guard !excluded.contains(id) else { continue }
            if entries[id]?.collectionIDs.contains(collectionID) == true { continue }
            plan.attach.append(id)
        }
        guard authoritative else { return plan }
        plan.detach = entries
            .filter { $0.value.collectionIDs.contains(collectionID) && !seen.contains($0.key) }
            .map(\.key)
            .sorted()
        plan.prunedExclusions = excluded.intersection(seen)
        return plan
    }

    static func exclusionsAfterRemoving(
        trackID: String,
        from collections: [String: DownloadedCollectionRecord],
        memberOf collectionIDs: Set<String>
    ) -> [String: DownloadedCollectionRecord] {
        var updated = collections
        for id in collectionIDs where updated[id] != nil {
            updated[id]?.excludedTrackIDs.insert(trackID)
        }
        return updated
    }
}

enum DownloadModelMigration {
    struct Outcome: Equatable {
        var keptCollectionIDs: Set<String> = []
        var droppedCollectionIDs: Set<String> = []
        var removedTrackIDs: Set<String> = []
        var promotedToExplicit: Set<String> = []
    }

    static func migrate(
        entries: inout [String: DownloadEntry],
        collections: inout [String: DownloadedCollectionRecord],
        legacyCollectionIDs: Set<String>,
        now: Date = Date()
    ) -> Outcome {
        var outcome = Outcome()
        let collectionsWithFiles = Set(entries.values.filter(\.isDownloaded).flatMap(\.collectionIDs))

        for id in legacyCollectionIDs.sorted() {
            if collectionsWithFiles.contains(id) {
                outcome.keptCollectionIDs.insert(id)
                if collections[id] == nil {
                    let kind: DownloadCollectionKind = id == CollectionPolicyID.likedTracks ? .likes : .playlist
                    collections[id] = DownloadedCollectionRecord(
                        id: id,
                        kind: kind,
                        title: kind == .likes ? "Likes" : "Playlist",
                        addedAt: now
                    )
                }
            } else {
                outcome.droppedCollectionIDs.insert(id)
            }
        }

        let liveCollections = Set(collections.keys)
        for (id, var entry) in entries {
            let stale = entry.collectionIDs.subtracting(liveCollections)
            if !stale.isEmpty { entry.collectionIDs.subtract(stale) }
            if entry.isRetained {
                entries[id] = entry
            } else if entry.isDownloaded {
                entry.isExplicit = true
                entries[id] = entry
                outcome.promotedToExplicit.insert(id)
            } else {
                entries[id] = nil
                outcome.removedTrackIDs.insert(id)
            }
        }
        return outcome
    }
}
