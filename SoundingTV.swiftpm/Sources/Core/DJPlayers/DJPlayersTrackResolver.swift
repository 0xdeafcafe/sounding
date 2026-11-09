#if os(macOS) || DEBUG
import Foundation

struct DJPlayersStickCandidate: Equatable, Sendable {
    var volume: String
    var title: String
    var artist: String?
    var durationSeconds: Int
    var bpm: Double?
    var isrc: String?
}

protocol DJPlayersStickCatalog: Sendable {
    func generation() async -> Int
    func candidates(rekordboxId: UInt32) async -> [DJPlayersStickCandidate]
}

protocol DJPlayersCollectionCatalog: Sendable {
    func generation() async -> Int
    func track(rekordboxId: String) async -> DJPlayersTrackInfo?
}

struct DJPlayersNoSticks: DJPlayersStickCatalog {
    func generation() async -> Int { 0 }
    func candidates(rekordboxId: UInt32) async -> [DJPlayersStickCandidate] { [] }
}

struct DJPlayersNoCollection: DJPlayersCollectionCatalog {
    func generation() async -> Int { 0 }
    func track(rekordboxId: String) async -> DJPlayersTrackInfo? { nil }
}

actor DJPlayersTrackLinkCollection: DJPlayersCollectionCatalog {
    static let refreshInterval: TimeInterval = 5

    private let store: CueStore
    private let now: @Sendable () -> Date
    private var byRekordboxId: [String: TrackLink] = [:]
    private var loadedAt: Date?
    private var signature = 0
    private var revision = 0

    init(store: CueStore = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    func generation() async -> Int {
        await refreshIfNeeded()
        return revision
    }

    func track(rekordboxId: String) async -> DJPlayersTrackInfo? {
        await refreshIfNeeded()
        guard let link = byRekordboxId[rekordboxId], !link.title.isEmpty else { return nil }
        return DJPlayersTrackInfo(
            title: link.title,
            artist: link.artist.isEmpty ? nil : link.artist,
            soundCloudTrackId: link.trackId
        )
    }

    private func refreshIfNeeded() async {
        if let loadedAt, now().timeIntervalSince(loadedAt) < Self.refreshInterval { return }
        let links = await store.allLinks()
        loadedAt = now()
        let next = links.count &* 31 &+ Int(truncatingIfNeeded: links.map(\.updatedAtMillis).max() ?? 0)
        guard next != signature || byRekordboxId.isEmpty && !links.isEmpty else { return }
        signature = next
        revision += 1
        var map: [String: TrackLink] = [:]
        for link in links {
            guard let id = link.rekordboxTrackId, !id.isEmpty else { continue }
            if let existing = map[id], existing.updatedAtMillis >= link.updatedAtMillis { continue }
            map[id] = link
        }
        byRekordboxId = map
    }
}

actor DJPlayersTrackResolver: DJPlayersTrackLookup {
    static let matcherLifetime: TimeInterval = 120
    static let lengthToleranceSeconds = 2
    static let tempoTolerance = 1.0

    private let sticks: any DJPlayersStickCatalog
    private let collection: any DJPlayersCollectionCatalog
    private let library: @Sendable () async -> [MatchCandidate]
    private let now: @Sendable () -> Date
    private var resolved: [DJPlayerTrackKey: DJPlayersTrackInfo] = [:]
    private var unresolved: [DJPlayerTrackKey: Int] = [:]
    private var matcher: (index: TrackMatcher.Index, builtAt: Date)?

    init(
        sticks: any DJPlayersStickCatalog = DJPlayersNoSticks(),
        collection: any DJPlayersCollectionCatalog = DJPlayersNoCollection(),
        library: @escaping @Sendable () async -> [MatchCandidate] = { [] },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sticks = sticks
        self.collection = collection
        self.library = library
        self.now = now
    }

    func track(for key: DJPlayerTrackKey, hint: DJPlayerTrackHint?) async -> DJPlayersTrackInfo? {
        guard key.isRekordboxTrack else { return nil }
        if let hit = resolved[key] { return hit }
        let generation: Int
        switch key.slot {
        case .usb, .sd:
            generation = await sticks.generation()
        case .collection:
            generation = await collection.generation()
        default:
            return nil
        }
        if unresolved[key] == generation { return nil }

        let info: DJPlayersTrackInfo?
        if key.slot == .collection {
            info = await collection.track(rekordboxId: String(key.rekordboxId))
        } else {
            info = await stickInfo(for: key, hint: hint)
        }
        if let info {
            resolved[key] = info
            unresolved[key] = nil
        } else {
            unresolved[key] = generation
        }
        return info
    }

    func forgetUnresolved() {
        unresolved.removeAll()
    }

    private func stickInfo(for key: DJPlayerTrackKey, hint: DJPlayerTrackHint?) async -> DJPlayersTrackInfo? {
        var candidates = await sticks.candidates(rekordboxId: key.rekordboxId).filter { !$0.title.isEmpty }
        if let length = hint?.lengthSeconds, length > 0 {
            candidates = candidates.filter { abs($0.durationSeconds - length) <= Self.lengthToleranceSeconds }
        }
        if candidates.count > 1, let bpm = hint?.bpm, bpm > 0 {
            let close = candidates.filter { $0.bpm.map { abs($0 - bpm) <= Self.tempoTolerance } ?? false }
            if !close.isEmpty { candidates = close }
        }
        guard let first = candidates.first else { return nil }
        let distinct = Set(candidates.map { "\($0.title)\u{1F}\($0.artist ?? "")\u{1F}\($0.durationSeconds)" })
        guard distinct.count == 1 else { return nil }
        return DJPlayersTrackInfo(
            title: first.title,
            artist: first.artist.flatMap { $0.isEmpty ? nil : $0 },
            soundCloudTrackId: await soundCloudId(for: first)
        )
    }

    private func soundCloudId(for candidate: DJPlayersStickCandidate) async -> String? {
        let index = await matchIndex()
        let query = MatchQuery(
            title: candidate.title,
            artist: candidate.artist ?? "",
            durationSeconds: TimeInterval(candidate.durationSeconds),
            isrc: candidate.isrc
        )
        return TrackMatcher.match(query, in: index).matchedTrackId
    }

    private func matchIndex() async -> TrackMatcher.Index {
        if let matcher, now().timeIntervalSince(matcher.builtAt) < Self.matcherLifetime { return matcher.index }
        let index = TrackMatcher.Index(await library())
        matcher = (index, now())
        return index
    }
}
#endif
