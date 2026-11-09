import Foundation

struct PickReason: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case key
        case tempo
        case energy
        case sound
        case journey
        case vocals
        case queue
    }

    let kind: Kind
    let text: String

    static func deterministicLine(_ reasons: [PickReason]) -> String {
        guard !reasons.isEmpty else { return "Next in the queue" }
        var parts = reasons.map(\.text)
        if let first = parts.first, first.first?.isLowercase == true {
            parts[0] = first.prefix(1).uppercased() + first.dropFirst()
        }
        return parts.joined(separator: " · ")
    }

    static func split(_ line: String) -> [PickReason] {
        line.components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { PickReason(kind: kind(of: $0), text: $0) }
    }

    static func kind(of text: String) -> Kind {
        let lower = text.lowercased()
        if lower.contains("bpm") { return .tempo }
        if lower.contains("key") || lower.contains("→") { return .key }
        if lower.contains("energy") { return .energy }
        if lower.contains("sound") { return .sound }
        if lower.contains("vocal") { return .vocals }
        return .queue
    }
}

struct GeneratedLine: Sendable, Equatable {
    var line: String
    var usedFacts: [Int]
}

protocol AutoMixLanguageModel: Sendable {
    var isAvailable: Bool { get }
    func intentDraft(for request: String, now: Date) async throws -> SetIntentDraft?
    func whyLine(facts: [String]) async throws -> GeneratedLine?
    func flairSummary(facts: [String]) async throws -> GeneratedLine?
}

struct UnavailableAutoMixLanguageModel: AutoMixLanguageModel {
    var isAvailable: Bool { false }
    func intentDraft(for request: String, now: Date) async throws -> SetIntentDraft? { nil }
    func whyLine(facts: [String]) async throws -> GeneratedLine? { nil }
    func flairSummary(facts: [String]) async throws -> GeneratedLine? { nil }
}

enum GroundedLineGuard {
    static let maxWhyCharacters = 90
    static let maxSummaryCharacters = 160

    static func accepts(_ generated: GeneratedLine, facts: [String], maxCharacters: Int) -> Bool {
        let line = generated.line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.count <= maxCharacters else { return false }
        guard !generated.usedFacts.isEmpty, generated.usedFacts.allSatisfy(facts.indices.contains) else { return false }
        let used = generated.usedFacts.map { facts[$0] }.joined(separator: " ")
        let allowed = Set(tokens(used))
        let claimed = tokens(line).filter { $0.contains(where: \.isNumber) }
        guard claimed.allSatisfy(allowed.contains) else { return false }
        let keyLabels = tokens(line).filter(isKeyLabel)
        guard keyLabels.allSatisfy(allowed.contains) else { return false }
        return true
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func isKeyLabel(_ token: String) -> Bool {
        guard let last = token.last, last == "a" || last == "b", token.count <= 3 else { return false }
        return Int(token.dropLast()).map { (1...12).contains($0) } ?? false
    }
}

struct AutoMixLanguage: Sendable {
    let model: any AutoMixLanguageModel

    init(model: any AutoMixLanguageModel = AutoMixLanguageModelFactory.make()) {
        self.model = model
    }

    func intent(for request: String, now: Date = Date(), calendar: Calendar = .current) async -> SetIntent? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if model.isAvailable, let draft = try? await model.intentDraft(for: trimmed, now: now) {
            return draft.intent(text: trimmed, now: now, calendar: calendar)
        }
        return SetIntentParser.parse(trimmed, now: now, calendar: calendar)
    }

    func whyLine(_ reasons: [PickReason]) async -> String {
        let fallback = PickReason.deterministicLine(reasons)
        let facts = reasons.map(\.text)
        guard model.isAvailable, facts.count >= 2,
              let generated = try? await model.whyLine(facts: facts),
              GroundedLineGuard.accepts(generated, facts: facts, maxCharacters: GroundedLineGuard.maxWhyCharacters)
        else { return fallback }
        return generated.line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func flairSummary(_ lines: [String]) async -> String? {
        guard let fallback = Self.deterministicFlairSummary(lines) else { return nil }
        guard model.isAvailable, lines.count >= 2,
              let generated = try? await model.flairSummary(facts: lines),
              GroundedLineGuard.accepts(generated, facts: lines, maxCharacters: GroundedLineGuard.maxSummaryCharacters)
        else { return fallback }
        return generated.line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deterministicFlairSummary(_ lines: [String]) -> String? {
        let picked = Array(lines.prefix(3))
        guard let first = picked.first else { return nil }
        guard picked.count > 1 else { return first + "." }
        let rest = picked.dropFirst().map { line -> String in
            guard let initial = line.first, !line.hasPrefix("I ") else { return line }
            return initial.lowercased() + line.dropFirst()
        }
        if rest.count == 1 { return "\(first), and \(rest[0])." }
        return "\(first), \(rest[0]), and \(rest[1])."
    }
}
