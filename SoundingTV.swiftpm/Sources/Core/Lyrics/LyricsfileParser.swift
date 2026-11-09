import Foundation

indirect enum MiniYAML: Equatable, Sendable {
    case scalar(String)
    case quoted(String)
    case sequence([MiniYAML])
    case mapping([(String, MiniYAML)])
    case null

    static func == (lhs: MiniYAML, rhs: MiniYAML) -> Bool {
        switch (lhs, rhs) {
        case (.scalar(let a), .scalar(let b)), (.quoted(let a), .quoted(let b)): a == b
        case (.sequence(let a), .sequence(let b)): a == b
        case (.mapping(let a), .mapping(let b)): a.map(\.0) == b.map(\.0) && a.map(\.1) == b.map(\.1)
        case (.null, .null): true
        default: false
        }
    }

    subscript(key: String) -> MiniYAML? {
        guard case .mapping(let pairs) = self else { return nil }
        return pairs.first(where: { $0.0 == key })?.1
    }

    var string: String? {
        switch self {
        case .scalar(let value), .quoted(let value): value
        default: nil
        }
    }

    var int: Int? {
        guard let text = string?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let value = Int(text) { return value }
        if let value = Double(text), value.isFinite { return Int(value.rounded()) }
        return nil
    }

    var bool: Bool? {
        guard case .scalar(let value) = self else { return nil }
        switch value.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: return nil
        }
    }

    var items: [MiniYAML] {
        guard case .sequence(let values) = self else { return [] }
        return values
    }
}

enum MiniYAMLParser {
    private struct Line {
        var indent: Int
        var text: String
    }

    static let maximumDepth = 16

    static func parse(_ source: String) -> MiniYAML? {
        var lines: [Line] = []
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let indent = raw.prefix(while: { $0 == " " }).count
            let text = String(raw.dropFirst(indent))
            lines.append(Line(indent: indent, text: text))
        }
        var cursor = 0
        skipBlank(lines, &cursor)
        guard cursor < lines.count else { return nil }
        if lines[cursor].text.hasPrefix("---") { cursor += 1 }
        skipBlank(lines, &cursor)
        guard cursor < lines.count else { return nil }
        return block(&lines, &cursor, indent: lines[cursor].indent, depth: 0)
    }

    private static func isBlank(_ line: Line) -> Bool {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    private static func skipBlank(_ lines: [Line], _ cursor: inout Int) {
        while cursor < lines.count, isBlank(lines[cursor]) { cursor += 1 }
    }

    private static func block(_ lines: inout [Line], _ cursor: inout Int, indent: Int, depth: Int) -> MiniYAML {
        guard depth < maximumDepth else { return .null }
        skipBlank(lines, &cursor)
        guard cursor < lines.count else { return .null }
        if lines[cursor].text.hasPrefix("- ") || lines[cursor].text == "-" {
            return sequence(&lines, &cursor, indent: indent, depth: depth)
        }
        return mapping(&lines, &cursor, indent: indent, depth: depth)
    }

    private static func sequence(_ lines: inout [Line], _ cursor: inout Int, indent: Int, depth: Int) -> MiniYAML {
        var items: [MiniYAML] = []
        while true {
            skipBlank(lines, &cursor)
            guard cursor < lines.count, lines[cursor].indent == indent,
                  lines[cursor].text.hasPrefix("- ") || lines[cursor].text == "-" else { break }
            let rest = String(lines[cursor].text.dropFirst(2))
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                cursor += 1
                skipBlank(lines, &cursor)
                if cursor < lines.count, lines[cursor].indent > indent {
                    items.append(block(&lines, &cursor, indent: lines[cursor].indent, depth: depth + 1))
                } else {
                    items.append(.null)
                }
            } else if splitKey(trimmed) != nil {
                let itemIndent = indent + 2 + (rest.count - rest.drop(while: { $0 == " " }).count)
                lines[cursor] = Line(indent: itemIndent, text: trimmed)
                items.append(mapping(&lines, &cursor, indent: itemIndent, depth: depth + 1))
            } else {
                cursor += 1
                items.append(scalar(trimmed))
            }
        }
        return .sequence(items)
    }

    private static func mapping(_ lines: inout [Line], _ cursor: inout Int, indent: Int, depth: Int) -> MiniYAML {
        var pairs: [(String, MiniYAML)] = []
        while true {
            skipBlank(lines, &cursor)
            guard cursor < lines.count, lines[cursor].indent == indent,
                  !lines[cursor].text.hasPrefix("- "),
                  let (key, value) = splitKey(lines[cursor].text) else { break }
            guard !pairs.contains(where: { $0.0 == key }) else { return .mapping(pairs) }
            cursor += 1
            if value.isEmpty {
                skipBlank(lines, &cursor)
                if cursor < lines.count,
                   lines[cursor].indent > indent || (lines[cursor].indent == indent && lines[cursor].text.hasPrefix("- ")) {
                    pairs.append((key, block(&lines, &cursor, indent: lines[cursor].indent, depth: depth + 1)))
                } else {
                    pairs.append((key, .null))
                }
            } else if value == "|" || value == "|-" || value == "|+" || value == ">" || value == ">-" {
                var collected: [String] = []
                var blockIndent: Int?
                while cursor < lines.count {
                    let line = lines[cursor]
                    if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                        collected.append("")
                        cursor += 1
                        continue
                    }
                    guard line.indent > indent else { break }
                    let base = blockIndent ?? line.indent
                    blockIndent = base
                    collected.append(String(repeating: " ", count: max(0, line.indent - base)) + line.text)
                    cursor += 1
                }
                while collected.last == "" { collected.removeLast() }
                let joiner = value.hasPrefix(">") ? " " : "\n"
                pairs.append((key, .quoted(collected.joined(separator: joiner))))
            } else {
                pairs.append((key, scalar(value)))
            }
        }
        return .mapping(pairs)
    }

    private static func splitKey(_ text: String) -> (String, String)? {
        var inSingle = false
        var inDouble = false
        var index = text.startIndex
        if text.first == "'" || text.first == "\"" || text.first == "{" || text.first == "[" { return quotedKey(text) }
        while index < text.endIndex {
            let character = text[index]
            if character == "'" && !inDouble { inSingle.toggle() }
            if character == "\"" && !inSingle { inDouble.toggle() }
            if character == ":", !inSingle, !inDouble {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " {
                    let key = text[..<index].trimmingCharacters(in: .whitespaces)
                    let value = next == text.endIndex ? "" : text[next...].trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return nil }
                    return (key, stripComment(value))
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func quotedKey(_ text: String) -> (String, String)? {
        guard let quote = text.first, quote == "'" || quote == "\"" else { return nil }
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            if text[index] == quote {
                let next = text.index(after: index)
                if quote == "'", next < text.endIndex, text[next] == "'" {
                    index = text.index(after: next)
                    continue
                }
                let key = unquote(String(text[...index]))
                let remainder = text[next...].trimmingCharacters(in: .whitespaces)
                guard remainder.hasPrefix(":") else { return nil }
                return (key, stripComment(remainder.dropFirst().trimmingCharacters(in: .whitespaces)))
            }
            if quote == "\"", text[index] == "\\" { index = text.index(after: index) }
            if index < text.endIndex { index = text.index(after: index) }
        }
        return nil
    }

    private static func stripComment(_ value: String) -> String {
        guard let first = value.first, first != "'", first != "\"" else { return value }
        if let range = value.range(of: " #") {
            return value[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    static func scalar(_ text: String) -> MiniYAML {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "~" || trimmed == "null" { return .null }
        if trimmed.first == "'" || trimmed.first == "\"" { return .quoted(unquote(trimmed)) }
        if trimmed.first == "{" { return flowMapping(trimmed) }
        if trimmed.first == "[" { return flowSequence(trimmed) }
        return .scalar(trimmed)
    }

    static func unquote(_ text: String) -> String {
        guard let quote = text.first, text.count >= 2, text.last == quote else { return text }
        let inner = String(text.dropFirst().dropLast())
        if quote == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var result = ""
        var iterator = inner.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch iterator.next() {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "/": result.append("/")
            case "u":
                var hex = ""
                for _ in 0..<4 { if let next = iterator.next() { hex.append(next) } }
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { result.append(Character(scalar)) }
            case let other?: result.append(other)
            case nil: break
            }
        }
        return result
    }

    private static func flowItems(_ text: String) -> [String] {
        let inner = text.dropFirst().dropLast()
        var items: [String] = []
        var lines = ""
        var depth = 0
        var quote: Character?
        var previous: Character?
        for character in inner {
            if let open = quote {
                lines.append(character)
                if character == open && !(open == "\"" && previous == "\\") { quote = nil }
                previous = character
                continue
            }
            switch character {
            case "'", "\"": quote = character; lines.append(character)
            case "{", "[": depth += 1; lines.append(character)
            case "}", "]": depth -= 1; lines.append(character)
            case "," where depth == 0:
                items.append(lines.trimmingCharacters(in: .whitespaces))
                lines = ""
            default: lines.append(character)
            }
            previous = character
        }
        let tail = lines.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { items.append(tail) }
        return items
    }

    private static func flowMapping(_ text: String) -> MiniYAML {
        guard text.hasSuffix("}") else { return .scalar(text) }
        var pairs: [(String, MiniYAML)] = []
        for item in flowItems(text) {
            guard let (key, value) = splitKey(item) ?? splitFlowKey(item) else { continue }
            pairs.append((key, scalar(value)))
        }
        return .mapping(pairs)
    }

    private static func splitFlowKey(_ item: String) -> (String, String)? {
        guard let colon = item.firstIndex(of: ":") else { return nil }
        return (item[..<colon].trimmingCharacters(in: .whitespaces), item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    private static func flowSequence(_ text: String) -> MiniYAML {
        guard text.hasSuffix("]") else { return .scalar(text) }
        return .sequence(flowItems(text).map(scalar))
    }
}

enum LyricsfileParser {
    struct Document: Equatable, Sendable {
        var lines: [LyricLine]
        var plain: String?
        var instrumental: Bool
    }

    static func parse(_ source: String) -> Document? {
        guard source.utf8.count <= 2_000_000, let root = MiniYAMLParser.parse(source), case .mapping = root else { return nil }
        if let version = root["version"]?.string, !version.hasPrefix("1") { return nil }
        let metadata = root["metadata"]
        let instrumental = metadata?["instrumental"]?.bool ?? false
        var lines: [LyricLine] = []
        for item in root["lines"]?.items ?? [] {
            guard let text = item["text"]?.string, let start = item["start_ms"]?.int, start >= 0 else { continue }
            let end = item["end_ms"]?.int.flatMap { $0 >= start ? $0 : nil }
            var words: [LyricWord] = []
            for word in item["words"]?.items ?? [] {
                guard let wordText = word["text"]?.string, let wordStart = word["start_ms"]?.int, wordStart >= 0 else { continue }
                let wordEnd = word["end_ms"]?.int.flatMap { $0 >= wordStart ? $0 : nil }
                words.append(LyricWord(text: wordText, start: Double(wordStart) / 1000, end: wordEnd.map { Double($0) / 1000 }))
            }
            words.sort { $0.start < $1.start }
            lines.append(LyricLine(text: text, start: Double(start) / 1000, end: end.map { Double($0) / 1000 }, words: words))
        }
        lines.sort { $0.start < $1.start }
        for index in lines.indices { lines[index].id = index }
        return Document(lines: lines, plain: root["plain"]?.string, instrumental: instrumental)
    }
}
