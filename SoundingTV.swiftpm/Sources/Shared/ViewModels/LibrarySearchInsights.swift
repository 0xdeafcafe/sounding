import Foundation
import Combine
#if canImport(FoundationModels) && canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
import CoreSpotlight
import FoundationModels
#endif

enum LibraryQuestionState: Equatable {
    case idle
    case asking
    case answered(String, [Track])
    case noAnswer
}

@MainActor
final class LibrarySearchInsights: ObservableObject {
    @Published private(set) var vibeTracks: [Track] = []
    @Published private(set) var question: LibraryQuestionState = .idle

    private let insights: GeneratedInsightsService
    private let catalog = DeviceLocalCatalog()
    private var vibeTask: Task<Void, Never>?
    private var questionTask: Task<Void, Never>?
    private var lastQuery = ""

    init(insights: GeneratedInsightsService = .shared) {
        self.insights = insights
    }

    static var canAskLibrary: Bool {
        #if canImport(FoundationModels) && canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
        if #available(iOS 27.0, macOS 27.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastQuery else { return }
        lastQuery = trimmed
        vibeTask?.cancel()
        questionTask?.cancel()
        question = .idle
        guard trimmed.count >= 3, insights.isEnabled else {
            vibeTracks = []
            return
        }
        vibeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await self.insights.loadCache()
            let ids = self.insights.vibeMatches(for: trimmed)
            let tracks = await self.catalog.likedTracks(ids: ids)
            let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            guard !Task.isCancelled else { return }
            self.vibeTracks = tracks.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        }
    }

    func ask(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Self.canAskLibrary else { return }
        questionTask?.cancel()
        question = .asking
        questionTask = Task { [weak self] in
            let result = await Self.answer(trimmed)
            guard let self, !Task.isCancelled else { return }
            guard let result else {
                self.question = .noAnswer
                return
            }
            let tracks = await self.catalog.likedTracks(ids: result.trackIDs)
            let order = Dictionary(result.trackIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let sorted = tracks.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
            guard !Task.isCancelled else { return }
            self.question = result.text.isEmpty && sorted.isEmpty ? .noAnswer : .answered(result.text, sorted)
        }
    }

    private struct Answer: Sendable {
        let text: String
        let trackIDs: [String]
    }

    private nonisolated static func answer(_ question: String) async -> Answer? {
        #if canImport(FoundationModels) && canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
        if #available(iOS 27.0, macOS 27.0, *) {
            return await spotlightAnswer(question)
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels) && canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
    private actor IdentifierCollector {
        private(set) var ids: [String] = []
        func add(_ values: [String]) {
            for value in values where !ids.contains(value) { ids.append(value) }
        }
    }

    @available(iOS 27.0, macOS 27.0, *)
    private nonisolated static func spotlightAnswer(_ question: String) async -> Answer? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let tool = SpotlightSearchTool(configuration: .init(sources: [.coreSpotlight], guide: .focused(.audio)))
        let session = LanguageModelSession(
            model: .default,
            tools: [tool],
            instructions: """
            You help someone find music in their own Sounding library: their likes, playlists and saved setlists, indexed in Spotlight. Always search before answering. Answer in one short sentence that names how many matches you found. Never invent tracks.
            """
        )
        let collector = IdentifierCollector()
        let listener = Task {
            for await reply in tool.searchResults {
                let ids: [String]
                switch reply.content {
                case .items(let items):
                    ids = items.compactMap { LibraryQuestionHeuristics.trackID(fromSpotlightIdentifier: $0.item.uniqueIdentifier) }
                case .scoredItems(let scored):
                    ids = scored.sorted { $0.score > $1.score }
                        .compactMap { LibraryQuestionHeuristics.trackID(fromSpotlightIdentifier: $0.item.item.uniqueIdentifier) }
                case .groupedItems(let groups):
                    ids = groups.values.flatMap { $0 }
                        .compactMap { LibraryQuestionHeuristics.trackID(fromSpotlightIdentifier: $0.item.uniqueIdentifier) }
                default:
                    ids = []
                }
                await collector.add(ids)
            }
        }
        defer { listener.cancel() }
        guard let response = try? await session.respond(to: question) else { return nil }
        try? await Task.sleep(for: .milliseconds(100))
        let ids = await collector.ids
        return Answer(text: InsightPrompts.cleanSummary(response.content) ?? "", trackIDs: Array(ids.prefix(25)))
        #endif
    }
    #endif
}
