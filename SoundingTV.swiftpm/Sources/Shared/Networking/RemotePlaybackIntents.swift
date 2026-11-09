import Foundation

struct RemotePlaybackIntents: Equatable, Sendable {
    static let grace: TimeInterval = 1
    static let deadline: TimeInterval = 3
    static let seekTolerance: TimeInterval = 2
    static let restartThreshold: TimeInterval = 3

    struct Transport: Equatable, Sendable {
        let isPlaying: Bool
        let issuedAt: Date
        let baselineRevision: Int
    }

    struct Skip: Equatable, Sendable {
        let fromTrackId: String?
        let target: QueueTrack?
        let issuedAt: Date
        let baselineRevision: Int
    }

    struct Seek: Equatable, Sendable {
        let target: TimeInterval
        let issuedAt: Date
        let baselineRevision: Int
    }

    struct Anchor: Equatable, Sendable {
        let position: TimeInterval
        let date: Date
    }

    struct Presentation: Equatable {
        let playback: PlaybackStatePayload
        let anchorDate: Date
    }

    private(set) var transport: Transport?
    private(set) var skip: Skip?
    private(set) var seek: Seek?
    private(set) var anchor: Anchor?

    var isEmpty: Bool { transport == nil && skip == nil && seek == nil }

    var nextDeadline: Date? {
        [transport?.issuedAt, skip?.issuedAt, seek?.issuedAt]
            .compactMap { $0 }
            .map { $0.addingTimeInterval(Self.deadline) }
            .min()
    }

    mutating func clear() {
        transport = nil
        skip = nil
        seek = nil
        anchor = nil
    }

    // MARK: - Intents

    mutating func notePlaying(_ isPlaying: Bool, observed: PlaybackStatePayload?, observedAt: Date, at now: Date) {
        guard let observed else { return }
        anchor = Anchor(position: presentedPosition(observed, observedAt: observedAt, at: now), date: now)
        transport = Transport(isPlaying: isPlaying, issuedAt: now, baselineRevision: observed.revision)
    }

    mutating func noteSeek(to position: TimeInterval, observed: PlaybackStatePayload?, observedAt: Date, at now: Date) {
        guard let observed else { return }
        let duration = presentedDuration(observed)
        let bounded = duration > 0 ? min(duration, max(0, position)) : max(0, position)
        anchor = Anchor(position: bounded, date: now)
        seek = Seek(target: bounded, issuedAt: now, baselineRevision: observed.revision)
    }

    mutating func noteSkip(to target: QueueTrack?, observed: PlaybackStatePayload?, observedAt: Date, at now: Date) {
        guard let observed else { return }
        let fromTrackId = present(observed, observedAt: observedAt, at: now).playback.trackId
        anchor = Anchor(position: 0, date: now)
        seek = nil
        skip = Skip(fromTrackId: fromTrackId, target: target, issuedAt: now, baselineRevision: observed.revision)
    }

    // MARK: - Reconciliation

    mutating func settle(observed: PlaybackStatePayload?, observedAt: Date, isLive: Bool, at now: Date) {
        guard let observed, isLive else {
            clear()
            return
        }
        let observedPosition = observed.estimatedPosition(elapsed: now.timeIntervalSince(observedAt))
        let isNewer: (Int) -> Bool = { observed.revision > $0 }

        if let transport {
            let elapsed = now.timeIntervalSince(transport.issuedAt)
            if elapsed >= Self.deadline
                || (isNewer(transport.baselineRevision) && (observed.isPlaying == transport.isPlaying || elapsed >= Self.grace)) {
                self.transport = nil
            }
        }

        if let skip {
            let elapsed = now.timeIntervalSince(skip.issuedAt)
            let moved = observed.trackId != skip.fromTrackId
            let restarted = skip.target == nil && observedPosition <= elapsed + Self.seekTolerance
            if elapsed >= Self.deadline
                || (isNewer(skip.baselineRevision) && (moved || restarted || elapsed >= Self.grace)) {
                self.skip = nil
            }
        }

        if let seek {
            let elapsed = now.timeIntervalSince(seek.issuedAt)
            let rate = observed.isPlaying ? observed.effectiveRate : 0
            let expected = seek.target + rate * elapsed
            if elapsed >= Self.deadline
                || (isNewer(seek.baselineRevision) && (abs(observedPosition - expected) <= Self.seekTolerance || elapsed >= Self.grace)) {
                self.seek = nil
            }
        }

        if isEmpty { anchor = nil }
    }

    func present(_ observed: PlaybackStatePayload, observedAt: Date, at now: Date) -> Presentation {
        guard !isEmpty else { return Presentation(playback: observed, anchorDate: observedAt) }
        let isPlaying = transport?.isPlaying ?? observed.isPlaying
        let target = skip?.target
        let duration = presentedDuration(observed)
        let rate = isPlaying ? observed.effectiveRate : 0
        var position: TimeInterval
        if let anchor {
            position = anchor.position + rate * max(0, now.timeIntervalSince(anchor.date))
        } else {
            position = observed.estimatedPosition(elapsed: now.timeIntervalSince(observedAt))
        }
        position = duration > 0 ? min(duration, max(0, position)) : max(0, position)
        let playback = PlaybackStatePayload(
            isPlaying: isPlaying,
            positionSeconds: position,
            durationSeconds: duration,
            trackId: target?.id ?? observed.trackId,
            title: target?.title ?? observed.title,
            artist: target?.artist ?? observed.artist,
            artworkURL: target.map { $0.artworkURL?.absoluteString } ?? observed.artworkURL,
            isDJEngineLive: observed.isDJEngineLive,
            revision: observed.revision,
            issuedAtMillis: observed.issuedAtMillis,
            signature: observed.signature,
            rate: observed.rate,
            modes: observed.modes
        )
        return Presentation(playback: playback, anchorDate: now)
    }

    func presentedPosition(_ observed: PlaybackStatePayload, observedAt: Date, at now: Date) -> TimeInterval {
        let presentation = present(observed, observedAt: observedAt, at: now)
        return presentation.playback.estimatedPosition(elapsed: now.timeIntervalSince(presentation.anchorDate))
    }

    private func presentedDuration(_ observed: PlaybackStatePayload) -> TimeInterval {
        skip?.target?.duration ?? observed.durationSeconds
    }
}

enum RemoteSkipPlanner {
    static func nextTarget(tracks: [QueueTrack], currentIndex: Int, presentedTrackId: String?) -> QueueTrack? {
        let index = RemoteQueueProjection.playingIndex(tracks: tracks, currentIndex: currentIndex, presentedTrackId: presentedTrackId)
        guard let index, tracks.indices.contains(index + 1) else { return nil }
        return tracks[index + 1]
    }

    enum Previous: Equatable {
        case restart
        case track(QueueTrack)
        case unknown
    }

    static func previous(tracks: [QueueTrack], currentIndex: Int, presentedTrackId: String?, position: TimeInterval) -> Previous {
        if position > RemotePlaybackIntents.restartThreshold { return .restart }
        guard let index = RemoteQueueProjection.playingIndex(tracks: tracks, currentIndex: currentIndex, presentedTrackId: presentedTrackId) else {
            return .unknown
        }
        guard tracks.indices.contains(index - 1) else { return .restart }
        return .track(tracks[index - 1])
    }
}

enum RemoteQueueProjection {
    static func playingIndex(tracks: [QueueTrack], currentIndex: Int, presentedTrackId: String?) -> Int? {
        guard !tracks.isEmpty else { return nil }
        guard let presentedTrackId else {
            return tracks.indices.contains(currentIndex) ? currentIndex : nil
        }
        for candidate in [currentIndex, currentIndex + 1, currentIndex - 1] where tracks.indices.contains(candidate) {
            if tracks[candidate].id == presentedTrackId { return candidate }
        }
        return tracks.firstIndex { $0.id == presentedTrackId }
    }

    static func upNext(tracks: [QueueTrack], currentIndex: Int, presentedTrackId: String?) -> [(index: Int, track: QueueTrack)] {
        let playing = playingIndex(tracks: tracks, currentIndex: currentIndex, presentedTrackId: presentedTrackId) ?? currentIndex
        guard playing + 1 < tracks.count else { return [] }
        return (playing + 1..<tracks.count).map { ($0, tracks[$0]) }
    }

    static func playingNextCount(_ count: Int, tracks: [QueueTrack], currentIndex: Int, presentedTrackId: String?) -> Int {
        let playing = playingIndex(tracks: tracks, currentIndex: currentIndex, presentedTrackId: presentedTrackId) ?? currentIndex
        guard playing >= currentIndex else { return 0 }
        return max(0, count - (playing - currentIndex))
    }

    static func playNextDestination(for index: Int, tracks: [QueueTrack], currentIndex: Int, presentedTrackId: String?) -> Int? {
        let playing = playingIndex(tracks: tracks, currentIndex: currentIndex, presentedTrackId: presentedTrackId) ?? currentIndex
        let destination = index > playing ? playing + 1 : playing
        guard tracks.indices.contains(index), destination != index else { return nil }
        return destination
    }
}

enum RemoteLinkStatus: Equatable, Sendable {
    case unlinked
    case connecting
    case connected
    case unreachable
}

enum RemotePhase: Equatable, Sendable {
    case unlinked
    case connecting
    case unreachable
    case needsSignIn
    case nothingPlaying
    case playing(isLive: Bool)

    static func resolve(link: RemoteLinkStatus, peerNeedsSignIn: Bool, hasPlayback: Bool, isLive: Bool) -> RemotePhase {
        switch link {
        case .unlinked:
            return .unlinked
        case .unreachable:
            return .unreachable
        case .connecting:
            return hasPlayback ? .playing(isLive: false) : .connecting
        case .connected:
            if peerNeedsSignIn { return .needsSignIn }
            return hasPlayback ? .playing(isLive: isLive) : .nothingPlaying
        }
    }
}
