import Foundation
import NaturalLanguage

struct LyricsTranslation: Hashable, Sendable {
    var target: String
    var byText: [String: String]

    init(target: String, byText: [String: String] = [:]) {
        self.target = target
        self.byText = byText
    }

    init(target: String, pairs: [(source: String, translated: String)]) {
        var byText: [String: String] = [:]
        for pair in pairs {
            let key = Self.key(pair.source)
            let translated = pair.translated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !translated.isEmpty, !Self.isSame(key, translated) else { continue }
            byText[key] = translated
        }
        self.init(target: target, byText: byText)
    }

    var isEmpty: Bool { byText.isEmpty }

    func text(for line: String) -> String? {
        byText[Self.key(line)]
    }

    func annotate(_ lines: [LyricLine]) -> [LyricsTranslatedLine] {
        lines.map { LyricsTranslatedLine(line: $0, translation: $0.isBlank ? nil : text(for: $0.text)) }
    }

    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }

    static func sourceTexts(_ body: LyricsBody) -> [String] {
        let texts: [String]
        switch body {
        case .synced(let lines): texts = lines.map(\.text)
        case .plain(let lines): texts = lines
        case .instrumental: texts = []
        }
        var seen: Set<String> = []
        var result: [String] = []
        for text in texts {
            let key = key(text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result
    }

    static func detectLanguage(_ texts: [String]) -> String? {
        let sample = texts.prefix(80).joined(separator: "\n")
        guard sample.count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        return confidence >= 0.5 ? language.rawValue : nil
    }

    static func needsTranslation(source: String, target: String) -> Bool {
        let sourceCode = Locale.Language(identifier: source).languageCode
        let targetCode = Locale.Language(identifier: target).languageCode
        guard let sourceCode, let targetCode else { return false }
        return sourceCode != targetCode
    }

    static var preferredTarget: String {
        Locale.preferredLanguages.first ?? Locale.current.language.minimalIdentifier
    }
}

struct LyricsTranslatedLine: Hashable, Sendable {
    var line: LyricLine
    var translation: String?
}
