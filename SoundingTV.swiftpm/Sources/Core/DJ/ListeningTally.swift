import Foundation

struct ListeningBucket: Codable, Hashable, Sendable {
    var positionMillis: Int64
    var hits: Int
    var sessions: Int
    var sessionIds: [String]
}

struct ListeningTally: Codable, Hashable, Sendable {
    let trackId: String
    let deviceId: String
    var buckets: [ListeningBucket]
    var updatedAtMillis: Int64

    static let maximumBuckets = 64
    static let rememberedSessions = 8
    static let unsnappedBucketMillis: Int64 = 500

    var recordName: String { Self.recordName(trackId: trackId, deviceId: deviceId) }

    static func recordName(trackId: String, deviceId: String) -> String {
        "tally:\(trackId):\(deviceId)"
    }

    init(trackId: String, deviceId: String, buckets: [ListeningBucket] = [], updatedAtMillis: Int64 = 0) {
        self.trackId = trackId
        self.deviceId = deviceId
        self.buckets = buckets
        self.updatedAtMillis = updatedAtMillis
    }

    static func snappedMillis(_ seconds: TimeInterval, grid: BeatGrid?, duration: TimeInterval) -> Int64 {
        let snap = CueSuggester.snapped(seconds, grid: grid, duration: duration)
        if snap.didSnap { return CueTime.millis(fromSeconds: snap.seconds) }
        let millis = CueTime.millis(fromSeconds: max(0, seconds))
        return (millis + unsnappedBucketMillis / 2) / unsnappedBucketMillis * unsnappedBucketMillis
    }

    mutating func record(positionMillis: Int64, sessionId: String, now: Int64 = CueTime.nowMillis()) {
        if let index = buckets.firstIndex(where: { $0.positionMillis == positionMillis }) {
            buckets[index].hits += 1
            if !buckets[index].sessionIds.contains(sessionId) {
                buckets[index].sessions += 1
                buckets[index].sessionIds = Array((buckets[index].sessionIds + [sessionId]).suffix(Self.rememberedSessions))
            }
        } else {
            buckets.append(ListeningBucket(positionMillis: positionMillis, hits: 1, sessions: 1, sessionIds: [sessionId]))
            if buckets.count > Self.maximumBuckets {
                buckets.sort { $0.hits > $1.hits }
                buckets = Array(buckets.prefix(Self.maximumBuckets))
            }
        }
        buckets.sort { $0.positionMillis < $1.positionMillis }
        updatedAtMillis = now
    }
}

enum ListeningSuggester {

    static let identity = CueSuggesterIdentity(name: "sounding.listening", version: 1)
    static let minimumHits = 3
    static let minimumSessions = 2
    static let fallbackBarMillis: Int64 = 2_000

    static func barMillis(grid: BeatGrid?) -> Int64 {
        guard let grid, grid.barDuration > 0 else { return fallbackBarMillis }
        return max(250, CueTime.millis(fromSeconds: grid.barDuration))
    }

    struct Cluster: Equatable, Sendable {
        let positionMillis: Int64
        let hits: Int
        let sessions: Int
    }

    static func clusters(_ tallies: [ListeningTally], barMillis: Int64) -> [Cluster] {
        let buckets = tallies.flatMap { tally in tally.buckets.map { (tally.deviceId, $0) } }
        guard !buckets.isEmpty else { return [] }

        var candidates: [Cluster] = []
        for (_, center) in buckets {
            let members = buckets.filter { abs($0.1.positionMillis - center.positionMillis) <= barMillis }
            let hits = members.reduce(0) { $0 + $1.1.hits }
            var sessionKeys = Set<String>()
            var largest = 0
            for (device, bucket) in members {
                for id in bucket.sessionIds { sessionKeys.insert("\(device)#\(id)") }
                largest = max(largest, bucket.sessions)
            }
            let weighted = members.reduce(0.0) { $0 + Double($1.1.positionMillis) * Double($1.1.hits) }
            let position = hits > 0 ? Int64((weighted / Double(hits)).rounded()) : center.positionMillis
            candidates.append(Cluster(positionMillis: position, hits: hits, sessions: max(sessionKeys.count, largest)))
        }

        var accepted: [Cluster] = []
        for candidate in candidates.sorted(by: { lhs, rhs in
            if lhs.hits != rhs.hits { return lhs.hits > rhs.hits }
            if lhs.sessions != rhs.sessions { return lhs.sessions > rhs.sessions }
            return lhs.positionMillis < rhs.positionMillis
        }) {
            guard candidate.hits >= minimumHits, candidate.sessions >= minimumSessions else { continue }
            if accepted.contains(where: { abs($0.positionMillis - candidate.positionMillis) <= barMillis * 2 }) { continue }
            accepted.append(candidate)
        }
        return accepted.sorted { $0.positionMillis < $1.positionMillis }
    }

    static func suggest(
        trackId: String,
        tallies: [ListeningTally],
        grid: BeatGrid?,
        duration: TimeInterval,
        userCues: [CuePoint] = [],
        dismissals: [CueDismissal] = []
    ) -> [CueSuggestion] {
        let bar = barMillis(grid: grid)
        let live = userCues.filter { !$0.isDeleted && $0.trackId == trackId }
        let dismissed = dismissals.filter { $0.trackId == trackId && $0.suggesterName == identity.name }

        return clusters(tallies.filter { $0.trackId == trackId }, barMillis: bar).compactMap { cluster in
            let seconds = CueTime.seconds(fromMillis: cluster.positionMillis)
            let snap = duration > 0
                ? CueSuggester.snapped(seconds, grid: grid, duration: duration)
                : (seconds: seconds, didSnap: false)
            let millis = CueTime.millis(fromSeconds: snap.seconds)
            if live.contains(where: { abs($0.positionMillis - millis) <= bar }) { return nil }
            if dismissed.contains(where: { abs($0.positionMillis - millis) <= bar }) { return nil }
            return CueSuggestion(
                trackId: trackId,
                kind: .memory,
                positionMillis: millis,
                endMillis: nil,
                suggester: identity,
                confidence: min(0.95, 0.45 + 0.05 * Double(cluster.hits)),
                reasoning: "You often come back here.",
                snappedToGrid: snap.didSnap,
                label: "Often replayed",
                color: .memory
            )
        }
    }
}

enum SeekIntent: Sendable {
    case user
    case correction
}

@MainActor
final class ListeningRecorder {
    static let shared = ListeningRecorder(store: .shared)

    struct PlaybackProbe {
        let trackId: String?
        let positionSeconds: TimeInterval
        let isPlaying: Bool
    }

    static let confirmationDelay: Duration = .seconds(6)
    static let confirmationWindow: ClosedRange<TimeInterval> = 3...14

    private let store: CueStore
    private var generation = 0
    private var sessionTrackId: String?
    private var sessionId = ""

    init(store: CueStore) {
        self.store = store
    }

    func noteTrackStarted(_ trackId: String?) {
        guard trackId != sessionTrackId else { return }
        sessionTrackId = trackId
        sessionId = String(UUID().uuidString.prefix(8))
        generation += 1
    }

    func noteSeek(
        trackId: String?,
        toSeconds target: TimeInterval,
        duration: TimeInterval,
        intent: SeekIntent,
        decksLive: Bool,
        probe: @escaping @MainActor () -> PlaybackProbe
    ) {
        generation += 1
        guard intent == .user, !decksLive, let trackId, duration > 0, target.isFinite else { return }
        noteTrackStarted(trackId)
        let expected = generation
        let session = sessionId
        let store = store
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.confirmationDelay)
            guard let self, self.generation == expected else { return }
            let now = probe()
            guard now.trackId == trackId, now.isPlaying else { return }
            let advanced = now.positionSeconds - target
            guard Self.confirmationWindow.contains(advanced) else { return }
            let grid = await store.prep(forTrack: trackId)?.grid?.value.beatGrid(durationSeconds: duration, confidence: 0.9)
            let millis = ListeningTally.snappedMillis(target, grid: grid, duration: duration)
            await store.recordListening(trackId: trackId, positionMillis: millis, sessionId: session)
        }
    }
}
