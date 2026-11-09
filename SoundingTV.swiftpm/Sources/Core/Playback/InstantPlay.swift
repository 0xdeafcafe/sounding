import Foundation

// MARK: - Start order

struct CollectionStartPlan: Equatable, Sendable {
    enum Start: Equatable, Sendable {
        case now(trackID: String)
        case afterFirstPage(ids: [String])
        case afterCollectionLookup
        case nothing
    }

    let start: Start
    let initialQueueIDs: [String]
    let hydrateAfterStartIDs: [String]

    var waitsOnNetwork: Bool {
        switch start {
        case .now, .nothing: return false
        case .afterFirstPage, .afterCollectionLookup: return true
        }
    }
}

enum CollectionStartPlanner {
    static let firstPageSize = 10
    static let hydrationBatchSize = 50

    static func plan(
        orderedIDs: [String],
        loadedIDs: [String],
        playableIDs: Set<String>,
        preferredStartID: String? = nil,
        firstPageSize: Int = CollectionStartPlanner.firstPageSize
    ) -> CollectionStartPlan {
        let loadedPlayable = unique(loadedIDs).filter { playableIDs.contains($0) }
        let loadedSet = Set(loadedIDs)
        let remaining = unique(orderedIDs).filter { !loadedSet.contains($0) }

        if !loadedPlayable.isEmpty {
            let start = preferredStartID.flatMap { loadedPlayable.contains($0) ? $0 : nil } ?? loadedPlayable[0]
            return CollectionStartPlan(
                start: .now(trackID: start),
                initialQueueIDs: loadedPlayable,
                hydrateAfterStartIDs: remaining
            )
        }
        if !remaining.isEmpty {
            let page = Array(remaining.prefix(max(1, firstPageSize)))
            return CollectionStartPlan(
                start: .afterFirstPage(ids: page),
                initialQueueIDs: [],
                hydrateAfterStartIDs: Array(remaining.dropFirst(page.count))
            )
        }
        if orderedIDs.isEmpty, loadedIDs.isEmpty {
            return CollectionStartPlan(start: .afterCollectionLookup, initialQueueIDs: [], hydrateAfterStartIDs: [])
        }
        return CollectionStartPlan(start: .nothing, initialQueueIDs: [], hydrateAfterStartIDs: [])
    }

    static func batches(_ ids: [String], size: Int = CollectionStartPlanner.hydrationBatchSize) -> [[String]] {
        guard size > 0, !ids.isEmpty else { return [] }
        return stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    static func appended(_ queueIDs: [String], with incomingIDs: [String]) -> [String] {
        var seen = Set(queueIDs)
        return queueIDs + incomingIDs.filter { seen.insert($0).inserted }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - Resolved stream URLs

struct ResolvedStreamURLCache: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let url: URL
        let fetchedAt: Date
        var expiresAt: Date?
        var lastUsedAt: Date?

        func isFresh(at now: Date) -> Bool {
            now < (expiresAt ?? fetchedAt.addingTimeInterval(ResolvedStreamURLCache.unsignedLifetime))
        }

        var recency: Date { lastUsedAt ?? fetchedAt }
    }

    static let defaultCapacity = 48
    static let unsignedLifetime: TimeInterval = 30
    static let signedExpiryMargin: TimeInterval = 90
    static let maximumSignedLifetime: TimeInterval = 20 * 60

    private(set) var entries: [String: Entry] = [:]
    var capacity: Int = ResolvedStreamURLCache.defaultCapacity

    init(entries: [String: Entry] = [:], capacity: Int = ResolvedStreamURLCache.defaultCapacity) {
        self.entries = entries
        self.capacity = capacity
    }

    static func usableExpiry(signedExpiry: Date?, fetchedAt: Date) -> Date? {
        guard let signedExpiry else { return nil }
        let usable = min(
            signedExpiry.addingTimeInterval(-signedExpiryMargin),
            fetchedAt.addingTimeInterval(maximumSignedLifetime)
        )
        return usable > fetchedAt.addingTimeInterval(unsignedLifetime) ? usable : nil
    }

    func peek(_ key: String, now: Date) -> URL? {
        guard let entry = entries[key], entry.isFresh(at: now) else { return nil }
        return entry.url
    }

    mutating func url(for key: String, now: Date) -> URL? {
        guard var entry = entries[key] else { return nil }
        guard entry.isFresh(at: now) else {
            entries[key] = nil
            return nil
        }
        entry.lastUsedAt = now
        entries[key] = entry
        return entry.url
    }

    mutating func store(_ url: URL, signedExpiry: Date?, for key: String, now: Date) {
        entries = entries.filter { $0.value.isFresh(at: now) }
        entries[key] = Entry(
            url: url,
            fetchedAt: now,
            expiresAt: Self.usableExpiry(signedExpiry: signedExpiry, fetchedAt: now),
            lastUsedAt: now
        )
        let limit = max(1, capacity)
        if entries.count > limit {
            let victims = entries
                .sorted { $0.value.recency < $1.value.recency }
                .prefix(entries.count - limit)
                .map(\.key)
            for victim in victims { entries[victim] = nil }
        }
    }

    mutating func remove(_ key: String) {
        entries[key] = nil
    }

    mutating func removeAll() {
        entries = [:]
    }
}

// MARK: - Played audio cache ledger

struct PlayedAudioCacheLedger: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let trackID: String
        let fileName: String
        let fileExtension: String
        let bytes: Int64
        let cachedAt: Date
        var lastPlayedAt: Date
    }

    struct Limits: Equatable, Sendable {
        var minimumRetention: TimeInterval
        var maximumAge: TimeInterval
        var softCapBytes: Int64
        var hardCapBytes: Int64
        var maximumItemBytes: Int64

        static let standard = Limits(
            minimumRetention: 3 * 60 * 60,
            maximumAge: 72 * 60 * 60,
            softCapBytes: 1_500_000_000,
            hardCapBytes: 2_000_000_000,
            maximumItemBytes: 400_000_000
        )
    }

    private(set) var entries: [String: Entry] = [:]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.bytes } }

    func entry(for trackID: String, now: Date, limits: Limits = .standard) -> Entry? {
        guard let entry = entries[trackID], now.timeIntervalSince(entry.lastPlayedAt) < limits.maximumAge else { return nil }
        return entry
    }

    func accepts(bytes: Int64, limits: Limits = .standard) -> Bool {
        bytes > 0 && bytes <= limits.maximumItemBytes
    }

    mutating func touch(_ trackID: String, now: Date) {
        guard var entry = entries[trackID] else { return }
        entry.lastPlayedAt = max(entry.lastPlayedAt, now)
        entries[trackID] = entry
    }

    @discardableResult
    mutating func insert(_ entry: Entry, now: Date, limits: Limits = .standard) -> [Entry] {
        var evicted: [Entry] = []
        if let previous = entries[entry.trackID], previous.fileName != entry.fileName {
            evicted.append(previous)
        }
        entries[entry.trackID] = entry
        evicted += evict(now: now, limits: limits, protecting: entry.trackID)
        return evicted
    }

    @discardableResult
    mutating func remove(_ trackID: String) -> Entry? {
        entries.removeValue(forKey: trackID)
    }

    @discardableResult
    mutating func removeAll() -> [Entry] {
        let all = Array(entries.values)
        entries = [:]
        return all
    }

    @discardableResult
    mutating func evict(now: Date, limits: Limits = .standard, protecting protected: String? = nil) -> [Entry] {
        var evicted: [Entry] = []
        for entry in entries.values where now.timeIntervalSince(entry.lastPlayedAt) >= limits.maximumAge && entry.trackID != protected {
            entries[entry.trackID] = nil
            evicted.append(entry)
        }
        let byAge = entries.values
            .filter { $0.trackID != protected }
            .sorted { $0.lastPlayedAt < $1.lastPlayedAt }
        var total = totalBytes
        for entry in byAge where total > limits.softCapBytes {
            guard now.timeIntervalSince(entry.lastPlayedAt) >= limits.minimumRetention else { continue }
            entries[entry.trackID] = nil
            evicted.append(entry)
            total -= entry.bytes
        }
        for entry in byAge where total > limits.hardCapBytes && entries[entry.trackID] != nil {
            entries[entry.trackID] = nil
            evicted.append(entry)
            total -= entry.bytes
        }
        return evicted
    }
}

// MARK: - Startup tuning

enum InstantPlayTuning {
    static let networkStartupForwardBuffer: TimeInterval = 2
    static let fillDelayAfterAudibleStart: Duration = .seconds(8)
    static let fillBackoffAfterRateLimit: TimeInterval = 10 * 60

    static func startsImmediately(origin: PlaybackMediaOrigin, itemIsPrepared: Bool) -> Bool {
        switch origin {
        case .localCache: return true
        case .networkStream: return itemIsPrepared
        case .peerStream: return false
        }
    }

    static func waitsToMinimizeStalling(origin: PlaybackMediaOrigin) -> Bool {
        origin != .localCache
    }
}
