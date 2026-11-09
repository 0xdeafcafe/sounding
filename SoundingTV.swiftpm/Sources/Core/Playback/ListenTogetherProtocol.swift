import Foundation

struct ListenTogetherStamp: Codable, Hashable, Comparable, Sendable {
    var counter: UInt64
    var origin: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.origin < rhs.origin : lhs.counter < rhs.counter
    }
}

struct ListenTogetherNowPlaying: Codable, Equatable, Sendable {
    var stamp: ListenTogetherStamp
    var tracks: [Track]
    var currentIndex: Int
    var position: TimeInterval
    var isPlaying: Bool
    var sentAt: Date
    var sourceTitle: String?

    var track: Track? { tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil }
    var trackID: String? { track?.id }
}

struct ListenTogetherTransport: Codable, Equatable, Sendable {
    var stamp: ListenTogetherStamp
    var trackID: String
    var position: TimeInterval
    var isPlaying: Bool
    var sentAt: Date
}

enum ListenTogetherMessage: Codable, Equatable, Sendable {
    case hello(origin: String)
    case nowPlaying(ListenTogetherNowPlaying)
    case transport(ListenTogetherTransport)

    var stamp: ListenTogetherStamp? {
        switch self {
        case .hello: return nil
        case .nowPlaying(let value): return value.stamp
        case .transport(let value): return value.stamp
        }
    }
}

enum ListenTogetherCodec {
    static let version = 1
    static let maxBytes = 48_000
    static let maxUpcoming = 20

    enum Failure: Error, Equatable {
        case tooLarge
        case unsupportedVersion(Int)
    }

    private struct Envelope: Codable {
        var v: Int
        var m: ListenTogetherMessage?
    }

    static func encode(_ message: ListenTogetherMessage) throws -> Data {
        let data = try encoder.encode(Envelope(v: version, m: message))
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> ListenTogetherMessage {
        let envelope = try JSONDecoder.listenTogether.decode(Envelope.self, from: data)
        guard envelope.v == version, let message = envelope.m else { throw Failure.unsupportedVersion(envelope.v) }
        return message
    }

    static func window(_ queue: [Track], currentIndex: Int, maxUpcoming: Int = maxUpcoming) -> (tracks: [Track], currentIndex: Int) {
        guard queue.indices.contains(currentIndex) else { return ([], 0) }
        let end = min(queue.count, currentIndex + 1 + max(0, maxUpcoming))
        return (Array(queue[currentIndex..<end]), 0)
    }

    static func fitting(_ nowPlaying: ListenTogetherNowPlaying) -> Data? {
        var candidate = nowPlaying
        while true {
            if let data = try? encode(.nowPlaying(candidate)) { return data }
            guard candidate.tracks.count > candidate.currentIndex + 1 else { return nil }
            candidate.tracks.removeLast()
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var listenTogether: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

struct ListenTogetherMachine: Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case waitingForSignIn
        case listening
    }

    enum Event: Sendable {
        case sessionArrived(signedIn: Bool)
        case signedIn
        case participantsChanged([String])
        case received(ListenTogetherMessage)
        case localTrackChanged(tracks: [Track], currentIndex: Int, position: TimeInterval, isPlaying: Bool, sourceTitle: String?)
        case localTransport(trackID: String, position: TimeInterval, isPlaying: Bool)
        case sessionEnded
    }

    enum Effect: Equatable, Sendable {
        case promptSignIn
        case join
        case suspendMixing
        case resumeMixing
        case send(ListenTogetherMessage, to: String?)
        case play(ListenTogetherNowPlaying, position: TimeInterval)
        case applyTransport(position: TimeInterval, isPlaying: Bool)
    }

    static let seekTolerance: TimeInterval = 2
    static let maxLatencyCompensation: TimeInterval = 5

    let origin: String
    private(set) var phase: Phase = .idle
    private(set) var participants: [String] = []
    private(set) var counter: UInt64 = 0
    private(set) var current: ListenTogetherNowPlaying?
    private(set) var lastTransport: ListenTogetherStamp?
    private(set) var expected: (trackID: String, position: TimeInterval, isPlaying: Bool, at: Date)?

    init(origin: String) {
        self.origin = origin
    }

    var participantCount: Int { phase == .listening ? max(participants.count, 1) : 0 }

    var answersHello: Bool {
        guard let current else { return false }
        let others = Set(participants)
        if current.stamp.origin == origin { return true }
        if others.contains(current.stamp.origin) { return false }
        return participants.filter { $0 != current.stamp.origin }.min().map { $0 == origin } ?? true
    }

    func expectedPosition(at now: Date) -> TimeInterval? {
        guard let expected else { return nil }
        return expected.isPlaying ? expected.position + max(0, now.timeIntervalSince(expected.at)) : expected.position
    }

    mutating func handle(_ event: Event, now: Date = Date()) -> [Effect] {
        switch event {
        case .sessionArrived(let signedIn):
            guard phase == .idle else { return [] }
            if signedIn { return begin() }
            phase = .waitingForSignIn
            return [.promptSignIn]

        case .signedIn:
            guard phase == .waitingForSignIn else { return [] }
            return begin()

        case .participantsChanged(let ids):
            participants = ids.sorted()
            return []

        case .received(let message):
            guard phase == .listening else { return [] }
            if let stamp = message.stamp { counter = max(counter, stamp.counter) }
            return receive(message, now: now)

        case .localTrackChanged(let tracks, let index, let position, let isPlaying, let sourceTitle):
            guard phase == .listening, tracks.indices.contains(index) else { return [] }
            if tracks[index].id == current?.trackID { return [] }
            let window = ListenTogetherCodec.window(tracks, currentIndex: index)
            let nowPlaying = ListenTogetherNowPlaying(
                stamp: nextStamp(),
                tracks: window.tracks,
                currentIndex: window.currentIndex,
                position: position,
                isPlaying: isPlaying,
                sentAt: now,
                sourceTitle: sourceTitle
            )
            current = nowPlaying
            lastTransport = nowPlaying.stamp
            expected = (tracks[index].id, position, isPlaying, now)
            return [.send(.nowPlaying(nowPlaying), to: nil)]

        case .localTransport(let trackID, let position, let isPlaying):
            guard phase == .listening, trackID == current?.trackID else { return [] }
            if let expected, expected.trackID == trackID, expected.isPlaying == isPlaying,
               let predicted = expectedPosition(at: now), abs(predicted - position) < Self.seekTolerance {
                return []
            }
            let transport = ListenTogetherTransport(
                stamp: nextStamp(), trackID: trackID, position: position, isPlaying: isPlaying, sentAt: now
            )
            lastTransport = transport.stamp
            expected = (trackID, position, isPlaying, now)
            return [.send(.transport(transport), to: nil)]

        case .sessionEnded:
            let wasActive = phase == .listening
            phase = .idle
            participants = []
            current = nil
            lastTransport = nil
            expected = nil
            return wasActive ? [.resumeMixing] : []
        }
    }

    private mutating func begin() -> [Effect] {
        phase = .listening
        return [.join, .suspendMixing, .send(.hello(origin: origin), to: nil)]
    }

    private mutating func nextStamp() -> ListenTogetherStamp {
        counter += 1
        return ListenTogetherStamp(counter: counter, origin: origin)
    }

    private mutating func receive(_ message: ListenTogetherMessage, now: Date) -> [Effect] {
        switch message {
        case .hello(let from):
            guard from != origin, answersHello, var snapshot = current else { return [] }
            if let predicted = expectedPosition(at: now) { snapshot.position = predicted }
            snapshot.isPlaying = expected?.isPlaying ?? snapshot.isPlaying
            snapshot.sentAt = now
            return [.send(.nowPlaying(snapshot), to: from)]

        case .nowPlaying(let incoming):
            guard incoming.stamp.origin != origin, incoming.track != nil else { return [] }
            if let current, incoming.stamp <= current.stamp { return [] }
            let position = compensated(incoming.position, isPlaying: incoming.isPlaying, sentAt: incoming.sentAt, now: now)
            current = incoming
            lastTransport = incoming.stamp
            expected = (incoming.trackID ?? "", position, incoming.isPlaying, now)
            return [.play(incoming, position: position)]

        case .transport(let incoming):
            guard incoming.stamp.origin != origin, incoming.trackID == current?.trackID else { return [] }
            if let lastTransport, incoming.stamp <= lastTransport { return [] }
            let position = compensated(incoming.position, isPlaying: incoming.isPlaying, sentAt: incoming.sentAt, now: now)
            lastTransport = incoming.stamp
            expected = (incoming.trackID, position, incoming.isPlaying, now)
            return [.applyTransport(position: position, isPlaying: incoming.isPlaying)]
        }
    }

    private func compensated(_ position: TimeInterval, isPlaying: Bool, sentAt: Date, now: Date) -> TimeInterval {
        guard isPlaying else { return position }
        let latency = min(Self.maxLatencyCompensation, max(0, now.timeIntervalSince(sentAt)))
        return position + latency
    }
}
