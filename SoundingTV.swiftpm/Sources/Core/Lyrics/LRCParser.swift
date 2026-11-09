import Foundation

enum LRCParser {
    static func parse(_ source: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var stamped: [(order: Int, line: LyricLine)] = []
        var order = 0
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[") else { continue }
            if let value = metadataValue(line, key: "offset") {
                offset = (Double(value.replacingOccurrences(of: "+", with: "")) ?? 0) / 1000
                continue
            }
            let (times, rest) = leadingTimestamps(line)
            guard !times.isEmpty else { continue }
            let (text, words) = enhancedWords(rest)
            let anchor = times[0]
            for time in times {
                let shift = time - anchor
                let lineWords = words.map {
                    LyricWord(text: $0.text, start: $0.start + shift, end: $0.end.map { $0 + shift })
                }
                stamped.append((order, LyricLine(text: text, start: time, words: lineWords)))
                order += 1
            }
        }
        let sorted = stamped.sorted { lhs, rhs in
            lhs.line.start == rhs.line.start ? lhs.order < rhs.order : lhs.line.start < rhs.line.start
        }
        return sorted.enumerated().map { index, entry in
            var line = entry.line
            line.id = index
            line.start = max(0, line.start - offset)
            line.words = line.words.map { word in
                LyricWord(text: word.text, start: max(0, word.start - offset), end: word.end.map { max(0, $0 - offset) })
            }
            return line
        }
    }

    static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        let secondsText: Substring
        var fraction: Double = 0
        if parts.count == 3 {
            secondsText = parts[1]
            guard let hundredths = fractionValue(parts[2]) else { return nil }
            fraction = hundredths
        } else if let dot = parts[1].firstIndex(of: ".") {
            secondsText = parts[1][..<dot]
            guard let value = fractionValue(parts[1][parts[1].index(after: dot)...]) else { return nil }
            fraction = value
        } else {
            secondsText = parts[1]
        }
        guard secondsText.count <= 2, let seconds = Int(secondsText), seconds >= 0, seconds < 60 else { return nil }
        return TimeInterval(minutes * 60 + seconds) + fraction
    }

    private static func fractionValue(_ digits: Substring) -> Double? {
        guard !digits.isEmpty, digits.count <= 3, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let value = Double(digits) else { return nil }
        return value / pow(10, Double(digits.count))
    }

    private static func metadataValue(_ line: String, key: String) -> String? {
        guard line.hasSuffix("]") else { return nil }
        let inner = line.dropFirst().dropLast()
        guard let colon = inner.firstIndex(of: ":") else { return nil }
        guard inner[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == key else { return nil }
        return inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    private static func leadingTimestamps(_ line: String) -> ([TimeInterval], Substring) {
        var times: [TimeInterval] = []
        var rest = Substring(line)
        while rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { break }
            let tag = rest[rest.index(after: rest.startIndex)..<close]
            guard let time = timestamp(tag) else { break }
            times.append(time)
            rest = rest[rest.index(after: close)...]
            while rest.first == " " && rest.dropFirst().first == "[" { rest = rest.dropFirst() }
        }
        return (times, rest)
    }

    private static func enhancedWords(_ rest: Substring) -> (String, [LyricWord]) {
        guard rest.contains("<") else {
            return (rest.trimmingCharacters(in: .whitespaces), [])
        }
        var words: [LyricWord] = []
        var plain = ""
        var cursor = rest.startIndex
        var pendingStart: TimeInterval?
        var pendingText = ""
        func flush(endingAt end: TimeInterval?) {
            if let start = pendingStart, !pendingText.isEmpty {
                words.append(LyricWord(text: pendingText, start: start, end: end))
            }
            pendingText = ""
        }
        while cursor < rest.endIndex {
            if rest[cursor] == "<", let close = rest[cursor...].firstIndex(of: ">"),
               let time = timestamp(rest[rest.index(after: cursor)..<close]) {
                flush(endingAt: time)
                pendingStart = time
                cursor = rest.index(after: close)
                continue
            }
            pendingText.append(rest[cursor])
            plain.append(rest[cursor])
            cursor = rest.index(after: cursor)
        }
        flush(endingAt: nil)
        if let last = words.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty {
            words.removeLast()
        }
        return (plain.trimmingCharacters(in: .whitespaces), words)
    }
}
