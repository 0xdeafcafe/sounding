import Foundation
#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
import FoundationModels
#endif

enum InsightModelFactory {
    static func make() -> any InsightLanguageModel {
        #if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return UnavailableInsightModel() }
        if #available(iOS 26, macOS 26, *) {
            return SystemInsightModel()
        }
        #endif
        return UnavailableInsightModel()
    }
}

#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
@available(iOS 26, macOS 26, *)
@Generable
struct GeneratedTagChoice {
    @Guide(description: "Three to six mood or vibe tags from the allowed list", .count(3...6))
    var tags: [String]
}

@available(iOS 26, macOS 26, *)
struct SystemInsightModel: InsightLanguageModel {
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func tags(instructions: String, prompt: String) async throws -> [String] {
        let model = SystemLanguageModel(useCase: .contentTagging)
        guard case .available = model.availability else { return [] }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(to: prompt, generating: GeneratedTagChoice.self)
        return response.content.tags
    }

    func summary(instructions: String, prompt: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return "" }
        let session = LanguageModelSession(model: model, instructions: instructions)
        return try await session.respond(to: prompt).content
    }
}
#endif
