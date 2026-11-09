import Foundation

enum LibraryEntityKind: String, Codable, Sendable, CaseIterable {
    case track
    case playlist
    case user
}

enum LibraryCollection: Hashable, Sendable, Codable, CustomStringConvertible {
    case likes
    case likedPlaylists
    case ownPlaylists
    case followings
    case followers
    case reposts
    case ownTracks
    case playlist(String)

    static let backfillOrder: [LibraryCollection] = [
        .likes, .ownPlaylists, .likedPlaylists, .followings, .ownTracks, .reposts, .followers
    ]

    static let headPatched: [LibraryCollection] = [.likes, .followings, .ownTracks, .reposts, .followers]

    static let playlistLists: [LibraryCollection] = [.ownPlaylists, .likedPlaylists]

    static let playlistPrefix = "playlist."

    var key: String {
        switch self {
        case .likes: return "likes"
        case .likedPlaylists: return "likedPlaylists"
        case .ownPlaylists: return "ownPlaylists"
        case .followings: return "followings"
        case .followers: return "followers"
        case .reposts: return "reposts"
        case .ownTracks: return "ownTracks"
        case .playlist(let id): return Self.playlistPrefix + id
        }
    }

    var description: String { key }

    init?(key: String) {
        switch key {
        case "likes": self = .likes
        case "likedPlaylists": self = .likedPlaylists
        case "ownPlaylists": self = .ownPlaylists
        case "followings": self = .followings
        case "followers": self = .followers
        case "reposts": self = .reposts
        case "ownTracks": self = .ownTracks
        default:
            guard key.hasPrefix(Self.playlistPrefix) else { return nil }
            let id = String(key.dropFirst(Self.playlistPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .playlist(id)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = LibraryCollection(key: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown collection \(raw)")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }

    var playlistID: String? {
        if case .playlist(let id) = self { return id }
        return nil
    }

    var isLikeList: Bool { self == .likes || self == .likedPlaylists }

    var pageCap: Int? { self == .followers ? 10 : nil }

    var isPositional: Bool { self != .likes }
}

struct LibraryRecord: Codable, Sendable, Equatable {
    var kind: LibraryEntityKind
    var id: String
    var payload: Data
    var title: String
    var artist: String
    var timestampMillis: Int64?
    var changeKey: String?

    var key: String { Self.key(kind, id) }

    static func key(_ kind: LibraryEntityKind, _ id: String) -> String { "\(kind.rawValue):\(id)" }

    static func parse(key: String) -> (kind: LibraryEntityKind, id: String)? {
        guard let colon = key.firstIndex(of: ":"),
              let kind = LibraryEntityKind(rawValue: String(key[..<colon])) else { return nil }
        let id = String(key[key.index(after: colon)...])
        return id.isEmpty ? nil : (kind, id)
    }

    enum CodingKeys: String, CodingKey {
        case kind = "k", id = "i", payload = "p", title = "t", artist = "a", timestampMillis = "m", changeKey = "c"
    }
}

struct LibraryRow: Codable, Sendable, Equatable {
    var record: LibraryRecord
    var sortKey: Int64

    enum CodingKeys: String, CodingKey {
        case record = "r", sortKey = "s"
    }
}

struct LibraryCursor: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        case idle
        case walking
        case complete
    }

    var phase: Phase = .idle
    var nextHref: URL?
    var generation: Int64 = 0
    var fetched: Int = 0
    var expectedTotal: Int?
    var completedAt: Date?
    var patchedAt: Date?
    var verifyRequested = false
    var mismatchWalkAt: Date?
    var sawDrops = false
    var syncedChangeKey: String?
    var bucketCount = 1
    var walkBase: Int64?

    var hasCompletedOnce: Bool { completedAt != nil }
    var isBackfilling: Bool { completedAt == nil }
}

struct LibraryManifestEntry: Codable, Sendable, Equatable {
    var completedAtMillis: Int64?
    var count: Int
    var syncedChangeKey: String?
    var bucketCount: Int
    var patchedAtMillis: Int64? = nil
}

struct LibraryChunk: Codable, Sendable, Equatable {
    static let manifestCollection = "manifest"

    var account: String
    var collection: String
    var bucket: Int
    var bucketCount: Int
    var updatedAtMillis: Int64
    var writerId: String
    var rows: [LibraryRow]
    var manifest: [String: LibraryManifestEntry]?
    var lease: LibraryBackfillLease? = nil

    var recordName: String { "\(account).\(collection).\(bucket)" }

    var isManifest: Bool { collection == Self.manifestCollection }

    func encoded() -> Data? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        return try? (json as NSData).compressed(using: .lzfse) as Data
    }

    static func decode(_ data: Data) -> LibraryChunk? {
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(LibraryChunk.self, from: json)
    }
}

struct LibraryPeerBody: Codable, Sendable, Equatable {
    static let currentFormat = "library.1"
    static let maximumBytes = 600_000

    var format = LibraryPeerBody.currentFormat
    var accountId: String
    var chunks: [Data]
    var isComplete: Bool

    init(accountId: String, chunks: [Data], isComplete: Bool) {
        self.accountId = accountId
        self.chunks = chunks
        self.isComplete = isComplete
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> LibraryPeerBody? {
        guard let body = try? JSONDecoder().decode(LibraryPeerBody.self, from: data),
              body.format == currentFormat else { return nil }
        return body
    }

    func decodedChunks() -> [LibraryChunk] {
        chunks.compactMap(LibraryChunk.decode).filter { $0.account == accountId }
    }

    static func batches(_ chunks: [LibraryChunk], maximumBytes: Int = maximumBytes) -> [[Data]] {
        var batches: [[Data]] = []
        var current: [Data] = []
        var size = 0
        for data in chunks.compactMap({ $0.encoded() }) where data.count <= maximumBytes {
            if size + data.count > maximumBytes, !current.isEmpty {
                batches.append(current)
                current = []
                size = 0
            }
            current.append(data)
            size += data.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}

enum LibraryBuckets {
    static let rowsPerBucket = 100
    static let maximumBuckets = 256

    static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    static func bucket(for key: String, count: Int) -> Int {
        Int(fnv1a(key) % UInt32(max(1, count)))
    }

    static func count(forRows rows: Int) -> Int {
        var count = 1
        while count < maximumBuckets, rows > count * rowsPerBucket * 3 / 2 {
            count *= 2
        }
        return count
    }
}

struct LibraryPage: Sendable {
    var records: [LibraryRecord]
    var next: URL?
    var droppedCount = 0
}

struct LibraryPlaylistManifest: Sendable {
    var trackIDs: [String]
    var hydrated: [LibraryRecord]
    var changeKey: String?
}

enum LibraryRemoteError: Error, Equatable, Sendable {
    case stop(until: Date?)
    case gone
    case transient
}

protocol LibraryRemote: Sendable {
    func page(_ collection: LibraryCollection, from url: URL?) async throws -> LibraryPage
    func playlistManifest(id: String) async throws -> LibraryPlaylistManifest
    func tracks(ids: [String]) async throws -> [LibraryRecord]
    func expectedCounts() async -> [LibraryCollection: Int]
}

protocol LibraryPacer: Sendable {
    func admit(_ collection: LibraryCollection) async -> Bool
    func admit(_ collection: LibraryCollection, urgent: Bool) async -> Bool
    func retryDelay(attempt: Int) async
}

extension LibraryPacer {
    func admit(_ collection: LibraryCollection, urgent: Bool) async -> Bool {
        await admit(collection)
    }
}

protocol LibraryStore: Sendable {
    func boundAccount() async -> String?
    func bind(account: String) async -> Bool
    func wipe() async

    func cursor(_ collection: LibraryCollection) async -> LibraryCursor
    func setCursor(_ cursor: LibraryCursor, for collection: LibraryCollection) async
    func knownCollections() async -> [LibraryCollection]

    func count(_ collection: LibraryCollection) async -> Int
    func keys(_ collection: LibraryCollection, limit: Int?) async -> [String]
    func keysAbove(_ collection: LibraryCollection, key: String) async -> [String]
    func contains(_ collection: LibraryCollection, keys: [String]) async -> Set<String>
    func row(_ collection: LibraryCollection, key: String) async -> LibraryRow?
    func records(_ collection: LibraryCollection) async -> [LibraryRecord]

    func append(_ collection: LibraryCollection, records: [LibraryRecord], generation: Int64) async
    func setHead(_ collection: LibraryCollection, records: [LibraryRecord], generation: Int64) async
    func insert(_ collection: LibraryCollection, rows: [LibraryRow], generation: Int64) async
    func replace(_ collection: LibraryCollection, records: [LibraryRecord], generation: Int64) async
    func remove(_ collection: LibraryCollection, keys: [String]) async
    func prune(_ collection: LibraryCollection, olderThan generation: Int64) async -> Int
    func maxGeneration(_ collection: LibraryCollection) async -> Int64
    func drop(_ collection: LibraryCollection) async

    func cachedTracks(ids: [String]) async -> [String: LibraryRecord]
    func upsertEntities(_ records: [LibraryRecord]) async

    func meta(_ key: String) async -> String?
    func setMeta(_ value: String?, forKey key: String) async

    func dirtyBuckets(cloud: Bool, since millis: Int64) async -> [(collection: LibraryCollection, bucket: Int, updatedAtMillis: Int64)]
    func exportRows(_ collection: LibraryCollection, bucket: Int, bucketCount: Int) async -> [LibraryRow]
    func bucketUpdatedAt(_ collection: LibraryCollection, bucket: Int) async -> Int64?
    func applyBucket(_ collection: LibraryCollection, bucket: Int, bucketCount: Int, rows: [LibraryRow], updatedAtMillis: Int64, generation: Int64) async
    func markCloudExported(_ collection: LibraryCollection, bucket: Int, through millis: Int64) async
}

struct LibraryProgress: Equatable, Sendable {
    var isBackfilling = false
    var collection: LibraryCollection?
    var fetched = 0
    var expected: Int?
    var likesCount = 0
    var isComplete = false

    static let idle = LibraryProgress()
}

enum LibraryLocalAction: Sendable, Equatable {
    case like(LibraryRecord)
    case unlike(trackID: String)
    case follow(LibraryRecord)
    case unfollow(userID: String)
    case likePlaylist(LibraryRecord)
    case unlikePlaylist(playlistID: String)
    case repost(LibraryRecord)
    case unrepost(kind: LibraryEntityKind, id: String)
    case addOwnPlaylist(LibraryRecord)
    case updateOwnPlaylist(LibraryRecord, trackOrder: [String]?)
    case removeOwnPlaylist(playlistID: String)

    var collection: LibraryCollection {
        switch self {
        case .addOwnPlaylist, .updateOwnPlaylist, .removeOwnPlaylist: return .ownPlaylists
        case .like, .unlike: return .likes
        case .follow, .unfollow: return .followings
        case .likePlaylist, .unlikePlaylist: return .likedPlaylists
        case .repost, .unrepost: return .reposts
        }
    }
}

struct LibraryActionUndo: Sendable {
    let collection: LibraryCollection
    let removedKey: String?
    let restoredRow: LibraryRow?
    var restoredRecords: [LibraryRecord]? = nil
    var related: [LibraryActionUndo] = []
    var mutation: LibraryPendingMutation? = nil
}

// MARK: - Pending mutations

struct LibraryPendingMutation: Sendable, Equatable, Hashable {
    let id: UUID
    let collection: LibraryCollection
    let key: String
    let present: Bool
}

struct LibraryMutationOverlay: Sendable {
    struct Entry: Sendable, Equatable {
        let id: UUID
        let present: Bool
        let record: LibraryRecord?
        let startedAt: Date
        var settledAt: Date?
    }

    static let standardGrace: TimeInterval = 120
    static let standardRetention: TimeInterval = 900

    var grace: TimeInterval = LibraryMutationOverlay.standardGrace
    var retention: TimeInterval = LibraryMutationOverlay.standardRetention
    private(set) var entries: [LibraryCollection: [String: Entry]] = [:]

    var isEmpty: Bool { entries.values.allSatisfy(\.isEmpty) }

    mutating func begin(_ mutation: LibraryPendingMutation, record: LibraryRecord?, at date: Date) {
        entries[mutation.collection, default: [:]][mutation.key] = Entry(
            id: mutation.id,
            present: mutation.present,
            record: mutation.present ? record : nil,
            startedAt: date,
            settledAt: nil
        )
    }

    mutating func settle(_ mutation: LibraryPendingMutation, succeeded: Bool, at date: Date) {
        guard var entry = entries[mutation.collection]?[mutation.key], entry.id == mutation.id else { return }
        if succeeded {
            entry.settledAt = date
            entries[mutation.collection]?[mutation.key] = entry
        } else {
            entries[mutation.collection]?[mutation.key] = nil
        }
    }

    mutating func expire(now: Date) {
        for (collection, byKey) in entries {
            let kept = byKey.filter { _, entry in
                guard let settled = entry.settledAt else { return true }
                return now.timeIntervalSince(settled) < retention
            }
            entries[collection] = kept.isEmpty ? nil : kept
        }
    }

    func wanted(_ collection: LibraryCollection, key: String, fetchedFrom start: Date, now: Date) -> Bool? {
        guard let entry = entries[collection]?[key] else { return nil }
        guard let settled = entry.settledAt else { return entry.present }
        if entry.startedAt >= start { return entry.present }
        if now.timeIntervalSince(settled) < grace { return entry.present }
        return nil
    }

    func held(_ collection: LibraryCollection, fetchedFrom start: Date, now: Date) -> [(key: String, present: Bool, record: LibraryRecord?)] {
        guard let byKey = entries[collection] else { return [] }
        return byKey.keys.sorted().compactMap { key in
            guard let present = wanted(collection, key: key, fetchedFrom: start, now: now) else { return nil }
            return (key: key, present: present, record: byKey[key]?.record)
        }
    }

    func admitting(_ collection: LibraryCollection, _ records: [LibraryRecord], fetchedFrom start: Date, now: Date) -> [LibraryRecord] {
        guard entries[collection] != nil else { return records }
        return records.filter { wanted(collection, key: $0.key, fetchedFrom: start, now: now) != false }
    }

    func removable(_ collection: LibraryCollection, _ keys: [String], fetchedFrom start: Date, now: Date) -> [String] {
        guard entries[collection] != nil else { return keys }
        return keys.filter { wanted(collection, key: $0, fetchedFrom: start, now: now) != true }
    }
}

enum LibrarySyncMode: Equatable, Sendable {
    case backfill
    case follow
}

enum LibraryRunOutcome: Equatable, Sendable {
    case finished
    case parked(until: Date?)
    case outOfBudget
    case accountMismatch
}

struct LibrarySyncPolicy: Sendable {
    var knownRunToStop = 20
    var headPageCap = 10
    var patchInterval: TimeInterval = 15 * 60
    var playlistPatchInterval: TimeInterval = 60 * 60
    var verifyInterval: TimeInterval = 7 * 24 * 60 * 60
    var mismatchWalkInterval: TimeInterval = 7 * 24 * 60 * 60
    var adoptFreshness: TimeInterval = 7 * 24 * 60 * 60
    var adoptCoverage = 0.9
    var tracksBatchSize = 50
    var maximumRetries = 2
    var exportLimit = 40
    var followerHeadPageCap = 1
    var followerPatched: [LibraryCollection] = [.likes]
    var playlistConcurrency = 2

    static let standard = LibrarySyncPolicy()
}

private struct LibraryBudgetExhausted: Error {}

// MARK: - Core

actor LibrarySyncCore {
    private let store: any LibraryStore
    private let remote: any LibraryRemote
    private let pacer: any LibraryPacer
    private let policy: LibrarySyncPolicy
    private let now: @Sendable () -> Date
    private var forcedPatches: Set<LibraryCollection> = []
    private var urgent: Set<LibraryCollection> = []
    private var activeWalks: Set<LibraryCollection> = []
    private var changed: Set<LibraryCollection> = []
    private var overlay = LibraryMutationOverlay()
    private var progressValue = LibraryProgress.idle
    private var onProgress: (@Sendable (LibraryProgress) -> Void)?
    private var onChange: (@Sendable (Set<LibraryCollection>) -> Void)?

    init(
        store: any LibraryStore,
        remote: any LibraryRemote,
        pacer: any LibraryPacer,
        policy: LibrarySyncPolicy = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.remote = remote
        self.pacer = pacer
        self.policy = policy
        self.now = now
    }

    func setObservers(
        progress: (@Sendable (LibraryProgress) -> Void)?,
        change: (@Sendable (Set<LibraryCollection>) -> Void)?
    ) {
        onProgress = progress
        onChange = change
    }

    func requestPatch(_ collection: LibraryCollection) {
        forcedPatches.insert(collection)
    }

    func progress() -> LibraryProgress { progressValue }

    func run(account: String, mode: LibrarySyncMode = .backfill) async -> LibraryRunOutcome {
        guard !account.isEmpty else { return .accountMismatch }
        if await store.bind(account: account) {
            changed.formUnion(LibraryCollection.backfillOrder)
        }
        defer { flushChanges() }
        do {
            if mode == .follow {
                try await patchAsFollower()
                await publishProgress(collection: nil)
                return .finished
            }
            for collection in LibraryCollection.backfillOrder {
                let cursor = await store.cursor(collection)
                if cursor.isBackfilling || cursor.phase == .walking {
                    try await walk(collection)
                }
            }
            try await syncPlaylistTracks()
            try await patchDue()
            await publishProgress(collection: nil)
            return .finished
        } catch let error as LibraryRemoteError {
            await publishProgress(collection: nil)
            if case .stop(let until) = error { return .parked(until: until) }
            return .parked(until: nil)
        } catch {
            await publishProgress(collection: nil)
            return .outOfBudget
        }
    }

    func fill(_ collection: LibraryCollection, account: String) async -> LibraryRunOutcome {
        guard !account.isEmpty else { return .accountMismatch }
        guard collection.playlistID == nil else { return .finished }
        if await store.bind(account: account) {
            changed.formUnion(LibraryCollection.backfillOrder)
        }
        urgent.insert(collection)
        defer {
            urgent.remove(collection)
            flushChanges()
        }
        do {
            guard await store.cursor(collection).isBackfilling else { return .finished }
            try await walk(collection)
            await publishProgress(collection: nil)
            return .finished
        } catch let error as LibraryRemoteError {
            await publishProgress(collection: nil)
            if case .stop(let until) = error { return .parked(until: until) }
            return .parked(until: nil)
        } catch {
            await publishProgress(collection: nil)
            return .outOfBudget
        }
    }

    func isFilled(_ collection: LibraryCollection) async -> Bool {
        await store.cursor(collection).hasCompletedOnce
    }

    private func patchAsFollower() async throws {
        let date = now()
        for collection in LibraryCollection.headPatched {
            let cursor = await store.cursor(collection)
            guard cursor.hasCompletedOnce else { continue }
            let forced = forcedPatches.contains(collection)
            let routine = policy.followerPatched.contains(collection)
                && (cursor.patchedAt.map { date.timeIntervalSince($0) >= policy.patchInterval } ?? true)
            guard forced || routine else { continue }
            forcedPatches.remove(collection)
            try await patchHead(collection, pageCap: policy.followerHeadPageCap)
        }
    }

    private func patchDue() async throws {
        let date = now()
        let expected = await remote.expectedCounts()
        for collection in LibraryCollection.headPatched {
            var cursor = await store.cursor(collection)
            guard cursor.hasCompletedOnce else { continue }
            if let completedAt = cursor.completedAt, date.timeIntervalSince(completedAt) >= policy.verifyInterval {
                cursor.verifyRequested = true
                await store.setCursor(cursor, for: collection)
            }
            if cursor.verifyRequested || cursor.phase == .walking {
                try await startWalk(collection)
                try await walk(collection)
                continue
            }
            let due = forcedPatches.contains(collection)
                || cursor.patchedAt.map { date.timeIntervalSince($0) >= policy.patchInterval } ?? true
            guard due else { continue }
            forcedPatches.remove(collection)
            try await patchHead(collection)
            try await checkCount(collection, expected: expected[collection])
        }

        var playlistsPatched = false
        for collection in LibraryCollection.playlistLists {
            let cursor = await store.cursor(collection)
            guard cursor.hasCompletedOnce else { continue }
            let due = forcedPatches.contains(collection)
                || cursor.verifyRequested
                || cursor.patchedAt.map { date.timeIntervalSince($0) >= policy.playlistPatchInterval } ?? true
            guard due else { continue }
            forcedPatches.remove(collection)
            try await startWalk(collection)
            try await walk(collection)
            var done = await store.cursor(collection)
            done.patchedAt = now()
            await store.setCursor(done, for: collection)
            playlistsPatched = true
        }
        if playlistsPatched { try await syncPlaylistTracks() }
    }

    func startWalk(_ collection: LibraryCollection) async throws {
        var cursor = await store.cursor(collection)
        cursor.phase = .walking
        cursor.generation = max(cursor.generation, await store.maxGeneration(collection)) + 1
        cursor.nextHref = nil
        cursor.fetched = 0
        cursor.sawDrops = false
        cursor.verifyRequested = false
        if collection != .likes, cursor.hasCompletedOnce, cursor.walkBase == nil {
            var top: Int64 = 0
            if let key = await store.keys(collection, limit: 1).first, let row = await store.row(collection, key: key) {
                top = row.sortKey
            }
            cursor.walkBase = top + 1_000_000_000
        }
        await store.setCursor(cursor, for: collection)
    }

    func walk(_ collection: LibraryCollection) async throws {
        guard activeWalks.insert(collection).inserted else { return }
        defer { activeWalks.remove(collection) }
        let walkStarted = now()
        var cursor = await store.cursor(collection)
        if cursor.phase != .walking {
            try await startWalk(collection)
            cursor = await store.cursor(collection)
        }
        if cursor.expectedTotal == nil {
            cursor.expectedTotal = await remote.expectedCounts()[collection]
            await store.setCursor(cursor, for: collection)
        }
        var pages = cursor.fetched == 0 ? 0 : 1
        while true {
            let fetchStarted = now()
            let page = try await fetch(collection, from: cursor.nextHref)
            pages += 1
            let admitted = overlay.admitting(collection, page.records, fetchedFrom: fetchStarted, now: now())
            if collection != .likes, cursor.hasCompletedOnce, let base = cursor.walkBase {
                let start = Int64(cursor.fetched)
                let admittedKeys = Set(admitted.map(\.key))
                let rows = page.records.enumerated()
                    .filter { admittedKeys.contains($0.element.key) }
                    .map { LibraryRow(record: $0.element, sortKey: base - start - Int64($0.offset)) }
                await store.insert(collection, rows: rows, generation: cursor.generation)
            } else {
                await store.append(collection, records: admitted, generation: cursor.generation)
            }
            if !page.records.isEmpty { changed.insert(collection) }
            cursor.fetched += page.records.count
            cursor.sawDrops = cursor.sawDrops || page.droppedCount > 0
            let capped = collection.pageCap.map { pages >= $0 } ?? false
            if let next = page.next, !capped {
                cursor.nextHref = next
                await store.setCursor(cursor, for: collection)
                await publishProgress(collection: collection, cursor: cursor)
                if !cursor.hasCompletedOnce || urgent.contains(collection) { flushChanges() }
                continue
            }
            await reassert(collection, generation: cursor.generation, fetchedFrom: walkStarted)
            if !cursor.sawDrops && !capped {
                let pruned = await store.prune(collection, olderThan: cursor.generation)
                if pruned > 0 { changed.insert(collection) }
            }
            cursor.phase = .complete
            cursor.nextHref = nil
            cursor.completedAt = now()
            cursor.patchedAt = now()
            cursor.bucketCount = await resizedBucketCount(collection, current: cursor.bucketCount)
            await store.setCursor(cursor, for: collection)
            await publishProgress(collection: collection, cursor: cursor)
            flushChanges()
            return
        }
    }

    func patchHead(_ collection: LibraryCollection, pageCap: Int? = nil) async throws {
        let cap = max(1, pageCap ?? policy.headPageCap)
        let fetchStarted = now()
        var window: [LibraryRecord] = []
        var seen = Set<String>()
        var next: URL?
        var pages = 0
        var streak = 0
        var reachedEnd = false
        var anchored = false
        var dropped = 0
        repeat {
            let page = try await fetch(collection, from: next)
            pages += 1
            dropped += page.droppedCount
            let known = await store.contains(collection, keys: page.records.map(\.key))
            for record in page.records where seen.insert(record.key).inserted {
                var stamped = record
                if collection == .followings || collection == .followers, stamped.timestampMillis == nil, !known.contains(record.key) {
                    stamped.timestampMillis = Int64(now().timeIntervalSince1970 * 1000)
                }
                window.append(stamped)
                streak = known.contains(record.key) ? streak + 1 : 0
            }
            next = page.next
            if next == nil { reachedEnd = true; break }
            if streak >= policy.knownRunToStop { anchored = true; break }
        } while pages < cap

        window = overlay.admitting(collection, window, fetchedFrom: fetchStarted, now: now())
        var cursor = await store.cursor(collection)
        let windowKeys = window.map(\.key)
        let windowSet = Set(windowKeys)
        let known = await store.contains(collection, keys: windowKeys)

        if reachedEnd {
            let localCount = await store.count(collection)
            let suspicious = window.isEmpty && localCount > 0
            if dropped == 0 && !suspicious {
                let all = await store.keys(collection, limit: nil)
                let gone = overlay.removable(collection, all.filter { !windowSet.contains($0) }, fetchedFrom: fetchStarted, now: now())
                if !gone.isEmpty {
                    await store.remove(collection, keys: gone)
                    changed.insert(collection)
                }
            } else {
                cursor.verifyRequested = true
            }
            await place(collection, window: window, known: known, generation: cursor.generation)
        } else if anchored, let last = window.last {
            if dropped == 0 {
                let above = await store.keysAbove(collection, key: last.key)
                let gone = overlay.removable(collection, above.filter { !windowSet.contains($0) }, fetchedFrom: fetchStarted, now: now())
                if !gone.isEmpty {
                    await store.remove(collection, keys: gone)
                    changed.insert(collection)
                }
            }
            await place(collection, window: window, known: known, generation: cursor.generation)
        } else {
            let fresh = window.filter { !known.contains($0.key) }
            if !fresh.isEmpty {
                await store.setHead(collection, records: fresh, generation: cursor.generation)
                changed.insert(collection)
            }
            cursor.verifyRequested = true
        }
        await reassert(collection, generation: cursor.generation, fetchedFrom: fetchStarted)
        cursor.patchedAt = now()
        cursor.bucketCount = await resizedBucketCount(collection, current: cursor.bucketCount)
        await store.setCursor(cursor, for: collection)
        flushChanges()
    }

    private func place(_ collection: LibraryCollection, window: [LibraryRecord], known: Set<String>, generation: Int64) async {
        guard !window.isEmpty else { return }
        if collection == .likes {
            await store.setHead(collection, records: window, generation: generation)
            if window.contains(where: { !known.contains($0.key) }) { changed.insert(collection) }
            return
        }
        let windowKeys = window.map(\.key)
        let top = await store.keys(collection, limit: window.count)
        if top == windowKeys { return }
        let freshCount = window.prefix(while: { !known.contains($0.key) }).count
        let rest = Array(windowKeys.dropFirst(freshCount))
        let allFreshAtHead = window.dropFirst(freshCount).allSatisfy { known.contains($0.key) }
        if allFreshAtHead, Array(top.prefix(rest.count)) == rest {
            await store.setHead(collection, records: Array(window.prefix(freshCount)), generation: generation)
        } else {
            await store.setHead(collection, records: window, generation: generation)
        }
        changed.insert(collection)
    }

    private func checkCount(_ collection: LibraryCollection, expected: Int?) async throws {
        guard let expected else { return }
        if collection == .followers, expected > 2_000 { return }
        let local = await store.count(collection)
        guard local != expected else { return }
        var cursor = await store.cursor(collection)
        if let last = cursor.mismatchWalkAt, now().timeIntervalSince(last) < policy.mismatchWalkInterval { return }
        cursor.mismatchWalkAt = now()
        cursor.verifyRequested = true
        cursor.expectedTotal = expected
        await store.setCursor(cursor, for: collection)
    }

    func syncPlaylistTracks() async throws {
        var wanted: [String: String] = [:]
        for list in LibraryCollection.playlistLists {
            guard await store.cursor(list).hasCompletedOnce else { return }
            for record in await store.records(list) where record.kind == .playlist {
                wanted[record.id] = record.changeKey ?? ""
            }
        }
        for collection in await store.knownCollections() {
            guard let id = collection.playlistID, wanted[id] == nil else { continue }
            await store.drop(collection)
            changed.insert(collection)
        }
        var pending: [String] = []
        for id in wanted.keys.sorted() {
            let cursor = await store.cursor(LibraryCollection.playlist(id))
            if cursor.hasCompletedOnce, cursor.syncedChangeKey == (wanted[id] ?? "") { continue }
            pending.append(id)
        }
        let keys = wanted
        let width = max(1, policy.playlistConcurrency)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var queue = pending.makeIterator()
            for _ in 0..<min(width, pending.count) {
                guard let id = queue.next() else { break }
                group.addTask { try await self.syncPlaylist(id: id, changeKey: keys[id] ?? "") }
            }
            while try await group.next() != nil {
                if let id = queue.next() {
                    group.addTask { try await self.syncPlaylist(id: id, changeKey: keys[id] ?? "") }
                }
            }
        }
        flushChanges()
    }

    func syncPlaylist(id: String, changeKey: String) async throws {
        let collection = LibraryCollection.playlist(id)
        let manifest: LibraryPlaylistManifest
        do {
            manifest = try await withRetries(collection) { try await self.remote.playlistManifest(id: id) }
        } catch LibraryRemoteError.gone {
            await store.drop(collection)
            var cursor = LibraryCursor()
            cursor.phase = .complete
            cursor.completedAt = now()
            cursor.syncedChangeKey = changeKey
            await store.setCursor(cursor, for: collection)
            changed.insert(collection)
            return
        }
        var have = await store.cachedTracks(ids: manifest.trackIDs)
        for record in manifest.hydrated { have[record.id] = record }
        if !manifest.hydrated.isEmpty { await store.upsertEntities(manifest.hydrated) }
        let missing = manifest.trackIDs.filter { have[$0] == nil }
        var unique: [String] = []
        var seenIDs = Set<String>()
        for id in missing where seenIDs.insert(id).inserted { unique.append(id) }
        for start in stride(from: 0, to: unique.count, by: policy.tracksBatchSize) {
            let batch = Array(unique[start..<min(start + policy.tracksBatchSize, unique.count)])
            let fetched = try await withRetries(collection) { try await self.remote.tracks(ids: batch) }
            await store.upsertEntities(fetched)
            for record in fetched { have[record.id] = record }
        }
        var ordered: [LibraryRecord] = []
        var placed = Set<String>()
        for trackID in manifest.trackIDs where placed.insert(trackID).inserted {
            if let record = have[trackID] { ordered.append(record) }
        }
        var cursor = await store.cursor(collection)
        cursor.generation += 1
        await store.replace(collection, records: ordered, generation: cursor.generation)
        cursor.phase = .complete
        cursor.completedAt = now()
        cursor.patchedAt = now()
        cursor.fetched = ordered.count
        cursor.expectedTotal = manifest.trackIDs.count
        cursor.syncedChangeKey = manifest.changeKey ?? changeKey
        cursor.bucketCount = LibraryBuckets.count(forRows: ordered.count)
        await store.setCursor(cursor, for: collection)
        changed.insert(collection)
    }

    private func fetch(_ collection: LibraryCollection, from url: URL?) async throws -> LibraryPage {
        try await withRetries(collection) { try await self.remote.page(collection, from: url) }
    }

    private func withRetries<T: Sendable>(
        _ collection: LibraryCollection,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            guard await pacer.admit(collection, urgent: urgent.contains(collection)) else { throw LibraryBudgetExhausted() }
            do {
                return try await operation()
            } catch let error as LibraryRemoteError {
                switch error {
                case .stop, .gone: throw error
                case .transient:
                    guard attempt < policy.maximumRetries else { throw error }
                    await pacer.retryDelay(attempt: attempt)
                    attempt += 1
                }
            }
        }
    }

    func apply(_ action: LibraryLocalAction) async -> LibraryActionUndo {
        let collection = action.collection
        let generation = await store.cursor(collection).generation
        var undo = LibraryActionUndo(collection: collection, removedKey: nil, restoredRow: nil)
        var mutation: (key: String, present: Bool, record: LibraryRecord?)?
        switch action {
        case .like(let record), .follow(let record), .likePlaylist(let record), .repost(let record), .addOwnPlaylist(let record):
            var stamped = record
            if stamped.timestampMillis == nil { stamped.timestampMillis = Int64(now().timeIntervalSince1970 * 1000) }
            let existed = await store.row(collection, key: stamped.key)
            await store.setHead(collection, records: [stamped], generation: generation)
            undo = LibraryActionUndo(collection: collection, removedKey: existed == nil ? stamped.key : nil, restoredRow: existed)
            mutation = (key: stamped.key, present: true, record: Optional(stamped))
        case .unlike(let id):
            undo = await removeOptimistically(collection, key: LibraryRecord.key(.track, id))
            mutation = (key: LibraryRecord.key(.track, id), present: false, record: nil)
        case .unfollow(let id):
            undo = await removeOptimistically(collection, key: LibraryRecord.key(.user, id))
            mutation = (key: LibraryRecord.key(.user, id), present: false, record: nil)
        case .unlikePlaylist(let id):
            undo = await removeOptimistically(collection, key: LibraryRecord.key(.playlist, id))
            mutation = (key: LibraryRecord.key(.playlist, id), present: false, record: nil)
        case .unrepost(let kind, let id):
            undo = await removeOptimistically(collection, key: LibraryRecord.key(kind, id))
            mutation = (key: LibraryRecord.key(kind, id), present: false, record: nil)
        case .updateOwnPlaylist(let record, let trackOrder):
            undo = await updateOwnPlaylist(record, trackOrder: trackOrder)
        case .removeOwnPlaylist(let id):
            undo = await removeOptimistically(collection, key: LibraryRecord.key(.playlist, id))
            mutation = (key: LibraryRecord.key(.playlist, id), present: false, record: nil)
            let liked = await removeOptimistically(.likedPlaylists, key: LibraryRecord.key(.playlist, id))
            if liked.restoredRow != nil {
                undo.related.append(liked)
                changed.insert(.likedPlaylists)
            }
        }
        if let mutation {
            let pending = LibraryPendingMutation(id: UUID(), collection: collection, key: mutation.key, present: mutation.present)
            overlay.begin(pending, record: mutation.record, at: now())
            undo.mutation = pending
        }
        forcedPatches.insert(collection)
        changed.insert(collection)
        flushChanges()
        return undo
    }

    private func updateOwnPlaylist(_ record: LibraryRecord, trackOrder: [String]?) async -> LibraryActionUndo {
        let collection = LibraryCollection.ownPlaylists
        let generation = await store.cursor(collection).generation
        let existing = await store.row(collection, key: record.key)
        var undo = LibraryActionUndo(collection: collection, removedKey: nil, restoredRow: existing)
        if let existing {
            var updated = record
            updated.timestampMillis = existing.record.timestampMillis
            await store.insert(collection, rows: [LibraryRow(record: updated, sortKey: existing.sortKey)], generation: generation)
        }
        guard let trackOrder else { return undo }
        let tracks = LibraryCollection.playlist(record.id)
        let previous = await store.records(tracks)
        guard !previous.isEmpty else { return undo }
        let byID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = trackOrder.compactMap { byID[$0] }
        await store.replace(tracks, records: reordered, generation: await store.cursor(tracks).generation)
        undo.related.append(LibraryActionUndo(collection: tracks, removedKey: nil, restoredRow: nil, restoredRecords: previous))
        changed.insert(tracks)
        return undo
    }

    private func removeOptimistically(_ collection: LibraryCollection, key: String) async -> LibraryActionUndo {
        let existing = await store.row(collection, key: key)
        await store.remove(collection, keys: [key])
        return LibraryActionUndo(collection: collection, removedKey: nil, restoredRow: existing)
    }

    func settle(_ undo: LibraryActionUndo, succeeded: Bool) {
        guard let mutation = undo.mutation else { return }
        overlay.settle(mutation, succeeded: succeeded, at: now())
    }

    func pendingMutations(_ collection: LibraryCollection) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for item in overlay.held(collection, fetchedFrom: now(), now: now()) { result[item.key] = item.present }
        return result
    }

    func reassertPending(_ collection: LibraryCollection) async {
        let generation = await store.cursor(collection).generation
        await reassert(collection, generation: generation, fetchedFrom: now())
        flushChanges()
    }

    private func reassert(_ collection: LibraryCollection, generation: Int64, fetchedFrom start: Date) async {
        overlay.expire(now: now())
        let held = overlay.held(collection, fetchedFrom: start, now: now())
        guard !held.isEmpty else { return }
        var touched = false
        for item in held {
            let existing = await store.row(collection, key: item.key)
            if item.present {
                if let existing {
                    await store.insert(collection, rows: [existing], generation: generation)
                } else if let record = item.record {
                    await store.setHead(collection, records: [record], generation: generation)
                    touched = true
                }
            } else if existing != nil {
                await store.remove(collection, keys: [item.key])
                touched = true
            }
        }
        if touched { changed.insert(collection) }
    }

    func revert(_ undo: LibraryActionUndo) async {
        let generation = await store.cursor(undo.collection).generation
        if let key = undo.removedKey {
            await store.remove(undo.collection, keys: [key])
        }
        if let row = undo.restoredRow {
            await store.insert(undo.collection, rows: [row], generation: generation)
        }
        if let records = undo.restoredRecords {
            await store.replace(undo.collection, records: records, generation: generation)
        }
        changed.insert(undo.collection)
        for related in undo.related { await revert(related) }
        flushChanges()
    }

    func manifestChunk(account: String, writerId: String) async -> LibraryChunk {
        var entries: [String: LibraryManifestEntry] = [:]
        for collection in await store.knownCollections() {
            let cursor = await store.cursor(collection)
            guard cursor.phase == .complete || cursor.hasCompletedOnce else { continue }
            entries[collection.key] = LibraryManifestEntry(
                completedAtMillis: cursor.completedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
                count: await store.count(collection),
                syncedChangeKey: cursor.syncedChangeKey,
                bucketCount: cursor.bucketCount,
                patchedAtMillis: cursor.patchedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
            )
        }
        return LibraryChunk(
            account: account,
            collection: LibraryChunk.manifestCollection,
            bucket: 0,
            bucketCount: 1,
            updatedAtMillis: Int64(now().timeIntervalSince1970 * 1000),
            writerId: writerId,
            rows: [],
            manifest: entries
        )
    }

    func chunks(account: String, writerId: String, cloud: Bool, since millis: Int64, limit: Int?) async -> [LibraryChunk] {
        guard await store.boundAccount() == account else { return [] }
        var dirty = await store.dirtyBuckets(cloud: cloud, since: millis)
        dirty.sort { $0.updatedAtMillis < $1.updatedAtMillis }
        if let limit { dirty = Array(dirty.prefix(limit)) }
        var result: [LibraryChunk] = []
        for item in dirty {
            let cursor = await store.cursor(item.collection)
            let rows = await store.exportRows(item.collection, bucket: item.bucket, bucketCount: cursor.bucketCount)
            result.append(LibraryChunk(
                account: account,
                collection: item.collection.key,
                bucket: item.bucket,
                bucketCount: cursor.bucketCount,
                updatedAtMillis: item.updatedAtMillis,
                writerId: writerId,
                rows: rows,
                manifest: nil
            ))
        }
        return result
    }

    func allChunks(account: String, writerId: String) async -> [LibraryChunk] {
        guard await store.boundAccount() == account else { return [] }
        var result: [LibraryChunk] = []
        for collection in await store.knownCollections() {
            let cursor = await store.cursor(collection)
            for bucket in 0..<max(1, cursor.bucketCount) {
                let rows = await store.exportRows(collection, bucket: bucket, bucketCount: cursor.bucketCount)
                let updated = await store.bucketUpdatedAt(collection, bucket: bucket) ?? 0
                guard !rows.isEmpty || updated > 0 else { continue }
                result.append(LibraryChunk(
                    account: account,
                    collection: collection.key,
                    bucket: bucket,
                    bucketCount: cursor.bucketCount,
                    updatedAtMillis: updated,
                    writerId: writerId,
                    rows: rows,
                    manifest: nil
                ))
            }
        }
        return result
    }

    func markCloudExported(_ chunks: [LibraryChunk]) async {
        for chunk in chunks where !chunk.isManifest {
            guard let collection = LibraryCollection(key: chunk.collection) else { continue }
            await store.markCloudExported(collection, bucket: chunk.bucket, through: chunk.updatedAtMillis)
        }
    }

    @discardableResult
    func adopt(_ chunks: [LibraryChunk], expectedAccount: String) async -> Int {
        guard !expectedAccount.isEmpty, await store.boundAccount() == expectedAccount else { return 0 }
        var applied = 0
        for chunk in chunks where chunk.account == expectedAccount {
            if chunk.isManifest {
                if let manifest = chunk.manifest, let data = try? JSONEncoder().encode(manifest) {
                    await store.setMeta(String(decoding: data, as: UTF8.self), forKey: "manifest.pending")
                }
                continue
            }
            guard let collection = LibraryCollection(key: chunk.collection),
                  chunk.bucketCount >= 1,
                  chunk.bucketCount <= LibraryBuckets.maximumBuckets,
                  chunk.bucket >= 0, chunk.bucket < chunk.bucketCount else { continue }
            let local = await store.bucketUpdatedAt(collection, bucket: chunk.bucket) ?? 0
            guard chunk.updatedAtMillis > local else { continue }
            var cursor = await store.cursor(collection)
            if cursor.bucketCount != chunk.bucketCount {
                cursor.bucketCount = chunk.bucketCount
                await store.setCursor(cursor, for: collection)
            }
            let rows = chunk.rows.filter { LibraryBuckets.bucket(for: $0.record.key, count: chunk.bucketCount) == chunk.bucket }
            await store.applyBucket(
                collection,
                bucket: chunk.bucket,
                bucketCount: chunk.bucketCount,
                rows: rows,
                updatedAtMillis: chunk.updatedAtMillis,
                generation: cursor.generation
            )
            await reassert(collection, generation: cursor.generation, fetchedFrom: now())
            changed.insert(collection)
            applied += 1
        }
        await adoptPendingManifest()
        flushChanges()
        return applied
    }

    func adoptPendingManifest() async {
        guard let text = await store.meta("manifest.pending"),
              let manifest = try? JSONDecoder().decode([String: LibraryManifestEntry].self, from: Data(text.utf8)) else { return }
        var remaining = manifest
        let date = now()
        for (key, entry) in manifest {
            guard let collection = LibraryCollection(key: key) else {
                remaining[key] = nil
                continue
            }
            var cursor = await store.cursor(collection)
            guard let millis = entry.completedAtMillis else {
                remaining[key] = nil
                continue
            }
            let completedAt = Date(timeIntervalSince1970: Double(millis) / 1000)
            let vouchedAt = Date(timeIntervalSince1970: Double(max(millis, entry.patchedAtMillis ?? millis)) / 1000)
            guard date.timeIntervalSince(vouchedAt) <= policy.adoptFreshness else {
                remaining[key] = nil
                continue
            }
            if cursor.hasCompletedOnce, let mine = cursor.completedAt, mine >= completedAt, collection.playlistID == nil {
                remaining[key] = nil
                continue
            }
            let local = await store.count(collection)
            guard Double(local) >= Double(entry.count) * policy.adoptCoverage else { continue }
            cursor.phase = .complete
            cursor.nextHref = nil
            cursor.completedAt = max(cursor.completedAt ?? completedAt, completedAt)
            cursor.patchedAt = cursor.patchedAt ?? completedAt
            cursor.syncedChangeKey = entry.syncedChangeKey ?? cursor.syncedChangeKey
            cursor.bucketCount = entry.bucketCount
            cursor.fetched = local
            await store.setCursor(cursor, for: collection)
            remaining[key] = nil
        }
        if remaining.isEmpty {
            await store.setMeta(nil, forKey: "manifest.pending")
        } else if let data = try? JSONEncoder().encode(remaining) {
            await store.setMeta(String(decoding: data, as: UTF8.self), forKey: "manifest.pending")
        }
    }

    private func resizedBucketCount(_ collection: LibraryCollection, current: Int) async -> Int {
        let wanted = LibraryBuckets.count(forRows: await store.count(collection))
        return max(current, wanted)
    }

    private func publishProgress(collection: LibraryCollection?, cursor: LibraryCursor? = nil) async {
        var value = LibraryProgress()
        value.likesCount = await store.count(.likes)
        var backfilling: LibraryCollection?
        for candidate in LibraryCollection.backfillOrder {
            if await store.cursor(candidate).isBackfilling {
                backfilling = candidate
                break
            }
        }
        if let collection, let cursor, cursor.isBackfilling {
            value.isBackfilling = true
            value.collection = collection
            value.fetched = await store.count(collection)
            value.expected = cursor.expectedTotal
        } else if let backfilling {
            let state = await store.cursor(backfilling)
            value.isBackfilling = state.phase == .walking
            value.collection = backfilling
            value.fetched = await store.count(backfilling)
            value.expected = state.expectedTotal
        } else {
            value.isComplete = true
        }
        guard value != progressValue else { return }
        progressValue = value
        onProgress?(value)
    }

    private func flushChanges() {
        guard !changed.isEmpty else { return }
        let snapshot = changed
        changed = []
        onChange?(snapshot)
    }
}
