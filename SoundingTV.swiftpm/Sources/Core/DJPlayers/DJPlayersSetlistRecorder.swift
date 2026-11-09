#if os(macOS) || DEBUG
import Foundation

struct DJPlayersRecordedPlay: Equatable, Sendable {
    var playerNumber: Int
    var playerName: String
    var track: DJPlayerTrackKey
    var startedAt: Date
}

struct DJPlayersSetlistRecorder: Sendable {
    private struct Progress: Sendable {
        var track: DJPlayerTrackKey
        var beats: Double = 0
        var startedAt: Date?
        var recorded = false
    }

    var minimumBars: Int
    private var progress: [Int: Progress] = [:]
    private var lastObservation: TimeInterval?

    init(minimumBars: Int = 16) {
        self.minimumBars = max(1, minimumBars)
    }

    mutating func reset() {
        progress.removeAll()
        lastObservation = nil
    }

    mutating func observe(_ players: [DJPlayer], now: TimeInterval, date: Date) -> [DJPlayersRecordedPlay] {
        let elapsed = lastObservation.map { min(1, max(0, now - $0)) } ?? 0
        lastObservation = now
        let requiresOnAir = players.contains { $0.isMixer }
        var recorded: [DJPlayersRecordedPlay] = []
        var seen: Set<Int> = []

        for player in players where player.isPlayer {
            seen.insert(player.number)
            guard let status = player.status, let track = status.track else {
                progress[player.number] = nil
                continue
            }
            var entry = progress[player.number] ?? Progress(track: track)
            if entry.track != track { entry = Progress(track: track) }

            let audible = status.activity.isAudible && (!requiresOnAir || status.isOnAir)
            if audible {
                if entry.startedAt == nil { entry.startedAt = date }
                if let bpm = status.effectiveBPM, bpm > 0 {
                    entry.beats += elapsed * bpm / 60
                } else {
                    entry.beats += elapsed * 2
                }
            }

            if !entry.recorded, entry.beats >= Double(minimumBars * 4), let startedAt = entry.startedAt {
                entry.recorded = true
                recorded.append(DJPlayersRecordedPlay(
                    playerNumber: player.number,
                    playerName: player.name,
                    track: track,
                    startedAt: startedAt
                ))
            }
            progress[player.number] = entry
        }

        for number in progress.keys where !seen.contains(number) {
            progress[number] = nil
        }
        return recorded.sorted { $0.startedAt < $1.startedAt }
    }
}

struct DJPlayersSetlistBuilder: Sendable {
    static let trackIdPrefix = "djplayers."

    private(set) var setlist: GeneratedSetlist
    let startedAt: Date
    private var untitled: [String: DJPlayerTrackKey] = [:]

    init(startedAt: Date) {
        self.startedAt = startedAt
        let stamp = Int(startedAt.timeIntervalSince1970)
        setlist = GeneratedSetlist(
            trackId: "\(Self.trackIdPrefix)\(stamp)",
            trackTitle: Self.title(for: startedAt),
            duration: 0,
            segments: [],
            isSaved: true,
            updatedAt: startedAt,
            probes: [],
            savedUpdatedAt: startedAt
        )
    }

    static func title(for date: Date) -> String {
        "Recorded at \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    static func placeholderTitle(for play: DJPlayersRecordedPlay) -> String {
        "Unknown Track"
    }

    mutating func append(_ play: DJPlayersRecordedPlay, info: DJPlayersTrackInfo?, now: Date) -> GeneratedSetlist {
        let offset = max(0, play.startedAt.timeIntervalSince(startedAt))
        let segment = SetlistSegment(
            id: "\(setlist.trackId).\(setlist.segments.count + 1)",
            startSeconds: offset,
            observedAtSeconds: offset,
            artist: info?.artist,
            title: info?.title ?? Self.placeholderTitle(for: play),
            version: nil,
            source: .user,
            confidence: info == nil ? 0.5 : 1,
            evidence: "Player \(play.playerNumber) · \(play.track.slot.displayName) · ID \(play.track.rekordboxId)",
            shazamId: nil,
            soundCloudTrackId: info?.soundCloudTrackId,
            isUserEdited: false,
            updatedAt: now
        )
        setlist.segments.append(segment)
        if info == nil { untitled[segment.id] = play.track }
        setlist.duration = max(setlist.duration, now.timeIntervalSince(startedAt))
        setlist.updatedAt = now
        return setlist
    }

    mutating func fillTitles(from infos: [DJPlayerTrackKey: DJPlayersTrackInfo], now: Date) -> GeneratedSetlist? {
        var changed = false
        for (segmentId, key) in untitled {
            guard let info = infos[key], let index = setlist.segments.firstIndex(where: { $0.id == segmentId }) else { continue }
            setlist.segments[index].title = info.title
            setlist.segments[index].artist = info.artist
            setlist.segments[index].soundCloudTrackId = info.soundCloudTrackId
            setlist.segments[index].confidence = 1
            setlist.segments[index].updatedAt = now
            untitled[segmentId] = nil
            changed = true
        }
        guard changed else { return nil }
        setlist.updatedAt = now
        return setlist
    }

    mutating func extend(to now: Date) -> GeneratedSetlist {
        setlist.duration = max(setlist.duration, now.timeIntervalSince(startedAt))
        return setlist
    }
}
#endif
