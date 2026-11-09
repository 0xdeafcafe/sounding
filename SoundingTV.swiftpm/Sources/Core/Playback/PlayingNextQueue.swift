import Foundation

struct PlayingNextQueue: Equatable, Sendable {
    private(set) var trackIds: [String] = []

    init() {}

    init(leading count: Int, in queue: [String], currentIndex: Int) {
        let start = min(queue.count, currentIndex + 1)
        trackIds = Array(queue[start..<min(queue.count, start + max(0, count))])
    }

    var isEmpty: Bool { trackIds.isEmpty }

    func count(in queue: [String], currentIndex: Int) -> Int {
        Self.leadingRun(of: trackIds, in: queue, from: currentIndex + 1, skipping: nil)
    }

    func playNextIndex(currentIndex: Int) -> Int {
        currentIndex + 1
    }

    func addToQueueIndex(in queue: [String], currentIndex: Int) -> Int {
        min(queue.count, currentIndex + 1 + count(in: queue, currentIndex: currentIndex))
    }

    func contains(offset: Int, in queue: [String], currentIndex: Int) -> Bool {
        offset > currentIndex && offset <= currentIndex + count(in: queue, currentIndex: currentIndex)
    }

    func autoMixCandidates(in queue: [String], currentIndex: Int) -> [String] {
        let start = currentIndex + 1
        guard start < queue.count else { return [] }
        let run = count(in: queue, currentIndex: currentIndex)
        if run > 0 { return [queue[start]] }
        return Array(queue[start...])
    }

    mutating func noteInserted(_ id: String, at index: Int, before queue: [String], currentIndex: Int) {
        let start = currentIndex + 1
        let end = start + count(in: queue, currentIndex: currentIndex)
        guard index >= start, index <= end else { return }
        trackIds.append(id)
    }

    mutating func noteJoined(_ id: String) {
        trackIds.append(id)
    }

    mutating func noteRemoved(_ id: String, wasQueued: Bool) {
        guard wasQueued, let index = trackIds.firstIndex(of: id) else { return }
        trackIds.remove(at: index)
    }

    mutating func noteMoved(_ id: String, wasQueued: Bool, to index: Int, after queue: [String], currentIndex: Int) {
        noteRemoved(id, wasQueued: wasQueued)
        let start = currentIndex + 1
        guard index >= start else { return }
        let run = Self.leadingRun(of: trackIds, in: queue, from: start, skipping: index)
        if index < start + run || (index == start + run && wasQueued) { trackIds.append(id) }
    }

    mutating func prune(queue: [String], currentIndex: Int) {
        var upcoming = Array(queue.dropFirst(currentIndex + 1))
        trackIds = trackIds.filter { id in
            guard let match = upcoming.firstIndex(of: id) else { return false }
            upcoming.remove(at: match)
            return true
        }
    }

    mutating func removeAll() {
        trackIds.removeAll()
    }

    private static func leadingRun(of ids: [String], in queue: [String], from start: Int, skipping skipped: Int?) -> Int {
        guard !ids.isEmpty, start < queue.count else { return 0 }
        var remaining = ids
        var run = 0
        for offset in start..<queue.count {
            if offset == skipped { continue }
            guard let match = remaining.firstIndex(of: queue[offset]) else { break }
            remaining.remove(at: match)
            run += 1
        }
        return run
    }
}

enum UpNextSection: String, Equatable, Sendable {
    case playingNext
    case autoMix
    case continuePlaying
}

struct UpNextLayout: Equatable, Sendable {
    var playingNext: Range<Int>
    var autoMixPick: Int?
    var continuePlaying: Range<Int>

    static let empty = UpNextLayout(playingNext: 0..<0, autoMixPick: nil, continuePlaying: 0..<0)

    static func make(upcomingCount: Int, playingNextCount: Int, autoMixOn: Bool) -> UpNextLayout {
        let queued = max(0, min(playingNextCount, upcomingCount))
        let pick = autoMixOn && queued == 0 && upcomingCount > 0 ? 0 : nil
        let restStart = queued + (pick == nil ? 0 : 1)
        return UpNextLayout(
            playingNext: 0..<queued,
            autoMixPick: pick,
            continuePlaying: min(restStart, upcomingCount)..<upcomingCount
        )
    }

    func section(at offset: Int) -> UpNextSection {
        if playingNext.contains(offset) { return .playingNext }
        if offset == autoMixPick { return .autoMix }
        return .continuePlaying
    }
}
