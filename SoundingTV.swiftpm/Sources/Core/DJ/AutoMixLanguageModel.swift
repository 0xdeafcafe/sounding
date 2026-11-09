import Foundation
#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
import FoundationModels
#endif

enum AutoMixLanguageModelFactory {
    static func make() -> any AutoMixLanguageModel {
        #if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return UnavailableAutoMixLanguageModel() }
        return SystemAutoMixLanguageModel()
        #else
        return UnavailableAutoMixLanguageModel()
        #endif
    }
}

#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
@Generable
struct GeneratedSetIntent {
    @Guide(description: "Energy at the start of the set, 1 is ambient, 5 is steady groove, 10 is peak time", .range(1...10))
    var startEnergy: Int
    @Guide(description: "Energy the set should reach, 1 to 10. Same as startEnergy if no change was asked for", .range(1...10))
    var targetEnergy: Int
    @Guide(description: "Clock time to reach the target energy, as 24-hour HH:mm. Midnight is 00:00. Leave empty unless a clock time was given")
    var reachTargetAt: String?
    @Guide(description: "Minutes from now to reach the target energy, only if a duration was given")
    var reachTargetInMinutes: Int?
    @Guide(description: "Clock time before which no vocals may play, as 24-hour HH:mm. Leave empty unless asked")
    var noVocalsUntil: String?
    @Guide(description: "Minutes from now during which no vocals may play, only if a duration was given")
    var noVocalsForMinutes: Int?
    @Guide(description: "True only if the listener asked for no vocals at all")
    var noVocalsAtAll: Bool
    @Guide(description: "Lowest tempo in BPM, only if a tempo was mentioned", .range(60...200))
    var minBPM: Int?
    @Guide(description: "Highest tempo in BPM, only if a tempo was mentioned", .range(60...200))
    var maxBPM: Int?
    @Guide(description: "Length of the whole set in minutes, only if given")
    var durationMinutes: Int?
}

@Generable
struct GeneratedGroundedLine {
    @Guide(description: "Numbers of the facts this line uses, from the numbered list", .count(1...4))
    var usedFacts: [Int]
    @Guide(description: "One short, warm, plain sentence that restates only the used facts. No new facts, numbers, keys, genres or artists")
    var line: String
}

struct SystemAutoMixLanguageModel: AutoMixLanguageModel {
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func intentDraft(for request: String, now: Date) async throws -> SetIntentDraft? {
        guard isAvailable else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let instructions = """
        You turn a listener's request for a DJ set into settings. Only fill a field when the request asks for it. \
        Warm-up means low energy. Peak means energy 9 or 10. Wind down means energy falling.
        """
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let prompt = "The time now is \(formatter.string(from: now)). Request: \(request)"
        let generated = try await session.respond(to: prompt, generating: GeneratedSetIntent.self).content
        return SetIntentDraft(
            startEnergy: generated.startEnergy,
            targetEnergy: generated.targetEnergy,
            reachTargetAt: generated.reachTargetAt?.nilIfBlank,
            reachTargetInMinutes: generated.reachTargetInMinutes,
            noVocalsUntil: generated.noVocalsUntil?.nilIfBlank,
            noVocalsForMinutes: generated.noVocalsForMinutes,
            noVocalsAtAll: generated.noVocalsAtAll,
            minBPM: generated.minBPM,
            maxBPM: generated.maxBPM,
            durationMinutes: generated.durationMinutes
        )
    }

    func whyLine(facts: [String]) async throws -> GeneratedLine? {
        try await grounded(
            instructions: "You explain why a DJ picked the next track, in one short line of at most twelve words. Use only the numbered facts.",
            facts: facts
        )
    }

    func flairSummary(facts: [String]) async throws -> GeneratedLine? {
        try await grounded(
            instructions: "You sum up a listener's mixing taste in one friendly sentence, speaking to them as you. Use only the numbered facts.",
            facts: facts
        )
    }

    private func grounded(instructions: String, facts: [String]) async throws -> GeneratedLine? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let numbered = facts.enumerated().map { "\($0.offset). \($0.element)" }.joined(separator: "\n")
        let generated = try await session.respond(to: "Facts:\n\(numbered)", generating: GeneratedGroundedLine.self).content
        return GeneratedLine(line: generated.line, usedFacts: generated.usedFacts)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
