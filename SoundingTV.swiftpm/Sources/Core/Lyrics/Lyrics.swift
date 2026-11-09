import Foundation

struct LyricWord: Codable, Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval?
}

struct LyricLine: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var text: String
    var start: TimeInterval
    var end: TimeInterval?
    var words: [LyricWord]

    init(id: Int = 0, text: String, start: TimeInterval, end: TimeInterval? = nil, words: [LyricWord] = []) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.words = words
    }

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasWordTiming: Bool { !words.isEmpty }
}

enum LyricsBody: Codable, Hashable, Sendable {
    case synced([LyricLine])
    case plain([String])
    case instrumental
}

struct Lyrics: Codable, Hashable, Sendable {
    var body: LyricsBody
    var recordID: Int?
    var trackName: String?
    var artistName: String?

    init(body: LyricsBody, recordID: Int? = nil, trackName: String? = nil, artistName: String? = nil) {
        self.body = body
        self.recordID = recordID
        self.trackName = trackName
        self.artistName = artistName
    }

    var isWordSynced: Bool {
        guard case .synced(let lines) = body else { return false }
        return lines.contains(where: \.hasWordTiming)
    }
}

enum LyricsDisplayLine: Hashable, Sendable, Identifiable {
    case line(LyricLine)
    case interlude(id: Int, start: TimeInterval, end: TimeInterval)

    var id: Int {
        switch self {
        case .line(let line): line.id
        case .interlude(let id, _, _): id
        }
    }

    var start: TimeInterval {
        switch self {
        case .line(let line): line.start
        case .interlude(_, let start, _): start
        }
    }
}

enum LyricsTimeline {
    static let interludeThreshold: TimeInterval = 8
    static let leadIn: TimeInterval = 0.15

    static func displayLines(_ lines: [LyricLine]) -> [LyricsDisplayLine] {
        var result: [LyricsDisplayLine] = []
        var nextID = 1_000_000
        if let first = lines.first(where: { !$0.isBlank }), first.start >= interludeThreshold {
            result.append(.interlude(id: nextID, start: 0, end: first.start))
            nextID += 1
        }
        for (index, line) in lines.enumerated() where !line.isBlank {
            result.append(.line(line))
            let rest = lines.dropFirst(index + 1)
            guard let following = rest.first(where: { !$0.isBlank }) else { continue }
            let gapStart: TimeInterval
            if let immediate = rest.first, immediate.isBlank {
                gapStart = immediate.start
            } else {
                let lineEnd = line.end ?? line.words.last?.end ?? line.start
                gapStart = max(lineEnd, line.start + 4)
            }
            if following.start - gapStart >= interludeThreshold {
                result.append(.interlude(id: nextID, start: gapStart, end: following.start))
                nextID += 1
            }
        }
        return result
    }

    static func activeIndex(in lines: [LyricsDisplayLine], at time: TimeInterval) -> Int? {
        let probe = time + leadIn
        var low = 0
        var high = lines.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= probe {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    static func wordProgress(_ word: LyricWord, next: TimeInterval?, at time: TimeInterval) -> Double {
        let end = word.end ?? next ?? (word.start + 0.4)
        guard end > word.start else { return time >= word.start ? 1 : 0 }
        return min(1, max(0, (time - word.start) / (end - word.start)))
    }
}
