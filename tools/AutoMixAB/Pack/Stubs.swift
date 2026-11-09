import Foundation

struct ABSilentLanguageModel: AutoMixLanguageModel {
    var isAvailable: Bool { false }
    func intentDraft(for request: String, now: Date) async throws -> SetIntentDraft? { nil }
    func whyLine(facts: [String]) async throws -> GeneratedLine? { nil }
    func flairSummary(facts: [String]) async throws -> GeneratedLine? { nil }
}

enum AutoMixLanguageModelFactory {
    static func make() -> any AutoMixLanguageModel { ABSilentLanguageModel() }
}
