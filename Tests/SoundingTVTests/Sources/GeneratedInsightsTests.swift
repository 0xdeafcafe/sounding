import XCTest
@testable import SoundingTV

private final class StubInsightModel: InsightLanguageModel, @unchecked Sendable {
    var isAvailable: Bool
    var tagReply: [String]
    var summaryReply: String
    private let lock = NSLock()
    private var _prompts: [String] = []

    init(isAvailable: Bool = true, tags: [String] = ["Late Night", "driving", "made-up tag", "warm", "late night"], summary: String = "A warm, rolling deep house set that builds slowly. It peaks around the hour mark. Then it winds down.") {
        self.isAvailable = isAvailable
        self.tagReply = tags
        self.summaryReply = summary
    }

    var prompts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _prompts
    }

    private func record(_ prompt: String) {
        lock.lock(); _prompts.append(prompt); lock.unlock()
    }

    func tags(instructions: String, prompt: String) async throws -> [String] {
        record(prompt)
        return tagReply
    }

    func summary(instructions: String, prompt: String) async throws -> String {
        record(prompt)
        return summaryReply
    }
}

@MainActor
private final class PauseGate {
    var paused = true
}

final class GeneratedInsightsTests: XCTestCase {
    private func longSet(comments: Int = 12) -> InsightInput {
        InsightInput(
            trackId: "42",
            title: "Low Tide 041",
            artist: "Maren Holt",
            description: String(repeating: "Recorded live at the harbour, three hours of deep and dubby house. ", count: 4) + "https://example.com/tickets",
            genre: "Deep House",
            soundCloudTags: ["deep house", "live"],
            comments: (0..<comments).map { "Comment number \($0) loving this" } + ["🔥", "Comment number 1 loving this"],
            tracklist: ["Kōji Aren – Undertow", "Nilu & Brask – Glass Tide", "Pale Harbour – Lanterns"],
            bpm: 122.4,
            key: "8A",
            energy: 0.7,
            duration: 3 * 3600
        )
    }

    func testTagPromptCarriesEverySource() {
        let prompt = InsightPrompts.tagPrompt(longSet())
        XCTAssertTrue(prompt.contains("Title: Low Tide 041"))
        XCTAssertTrue(prompt.contains("Genre: Deep House"))
        XCTAssertTrue(prompt.contains("Uploader tags: deep house, live"))
        XCTAssertTrue(prompt.contains("Tempo: 122 BPM"))
        XCTAssertTrue(prompt.contains("Key: 8A"))
        XCTAssertTrue(prompt.contains("Energy: high"))
        XCTAssertTrue(prompt.contains("a DJ set or mix"))
        XCTAssertTrue(prompt.contains("Listener comments:"))
        XCTAssertTrue(prompt.contains("Allowed tags: late night"))
        XCTAssertFalse(prompt.contains("https://"))
    }

    func testPromptsStayInsideTheirBudgets() {
        var input = longSet(comments: 400)
        input.description = String(repeating: "x", count: 10_000)
        let tagPrompt = InsightPrompts.tagPrompt(input)
        let commentPrompt = InsightPrompts.commentSummaryPrompt(input) ?? ""
        let setPrompt = InsightPrompts.setSummaryPrompt(input) ?? ""
        XCTAssertLessThan(tagPrompt.count, 3_000)
        XCTAssertLessThan(commentPrompt.count, InsightPrompts.commentBudget + 400)
        XCTAssertLessThan(setPrompt.count, InsightPrompts.descriptionBudget + 2_000)
    }

    func testSummariesOnlyWhenThereIsSomethingToSummarise() {
        let short = InsightInput(trackId: "1", title: "Single", comments: ["nice", "great"], duration: 240)
        XCTAssertNil(InsightPrompts.setSummaryPrompt(short))
        XCTAssertNil(InsightPrompts.commentSummaryPrompt(short))
        XCTAssertNotNil(InsightPrompts.setSummaryPrompt(longSet()))
        XCTAssertNotNil(InsightPrompts.commentSummaryPrompt(longSet()))
    }

    func testCommentsAreDedupedAndEmojiOnlyDropped() {
        let usable = InsightPrompts.usableComments(["🔥🔥", "ID?", "Great set", "great set", "  Great   set "])
        XCTAssertEqual(usable, ["Great set"])
    }

    func testTagsAreLimitedToTheVocabulary() {
        let tags = InsightPrompts.normalizeTags(["Late Night", "#driving", "made up", "WARM", "late-night", "peak time", "sunrise", "deep", "dark", "acid"])
        XCTAssertEqual(tags, ["late night", "driving", "warm", "peak time", "sunrise", "deep"])
    }

    func testSummaryIsCappedToTwoSentences() {
        let cleaned = InsightPrompts.cleanSummary("\"One thing. Two things! Three things?\"")
        XCTAssertEqual(cleaned, "One thing. Two things!")
        XCTAssertNil(InsightPrompts.cleanSummary("ok"))
    }

    func testVibeScoreMatchesTagsInAQuery() {
        XCTAssertGreaterThan(InsightPrompts.vibeScore(tags: ["late night", "warm"], query: "something late night"), 0)
        XCTAssertGreaterThan(InsightPrompts.vibeScore(tags: ["driving"], query: "Driving"), InsightPrompts.vibeScore(tags: ["driving"], query: "driving music"))
        XCTAssertEqual(InsightPrompts.vibeScore(tags: ["dark"], query: "sunny"), 0)
    }

    func testGeneratorUsesTheStubAndNormalises() async {
        let model = StubInsightModel()
        let result = await InsightGenerator.generate(longSet(), model: model)
        XCTAssertEqual(result?.tags, ["late night", "driving", "warm"])
        XCTAssertEqual(result?.setSummary, "A warm, rolling deep house set that builds slowly. It peaks around the hour mark.")
        XCTAssertNotNil(result?.commentSummary)
        XCTAssertEqual(model.prompts.count, 3)
    }

    func testUnavailableModelProducesNothing() async {
        let model = StubInsightModel(isAvailable: false)
        let result = await InsightGenerator.generate(longSet(), model: model)
        XCTAssertNil(result)
        XCTAssertTrue(model.prompts.isEmpty)
    }

    func testNeedsRefreshWhenCommentsArriveOrTextChanges() {
        let short = InsightInput(trackId: "1", title: "Single", duration: 240)
        let cached = GeneratedInsights(trackId: "1", tags: ["warm"], textDigest: short.textDigest)
        XCTAssertFalse(cached.needsRefresh(for: short))

        var withComments = short
        withComments.comments = (0..<10).map { "Lovely track number \($0)" }
        XCTAssertTrue(cached.needsRefresh(for: withComments))

        var retitled = short
        retitled.title = "Single (Edit)"
        XCTAssertTrue(cached.needsRefresh(for: retitled))
    }

    func testCachePersistsAcrossInstancesAndEvicts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("insights.json")

        let first = GeneratedInsightsCache(fileURL: url, capacity: 2)
        await first.store(GeneratedInsights(trackId: "a", tags: ["warm"], textDigest: "1", generatedAt: Date(timeIntervalSince1970: 1)))
        await first.store(GeneratedInsights(trackId: "b", tags: ["dark"], textDigest: "2", generatedAt: Date(timeIntervalSince1970: 2)))
        await first.store(GeneratedInsights(trackId: "c", tags: ["deep"], textDigest: "3", generatedAt: Date(timeIntervalSince1970: 3)))

        let second = GeneratedInsightsCache(fileURL: url, capacity: 2)
        let all = await second.all()
        XCTAssertEqual(Set(all.keys), ["b", "c"])
        XCTAssertEqual(all["c"]?.tags, ["deep"])

        await second.removeAll()
        let empty = await GeneratedInsightsCache(fileURL: url).all()
        XCTAssertTrue(empty.isEmpty)
    }

    func testThrottleSpacesBackgroundWorkAndCapsTheHour() {
        let throttle = InsightThrottle(foregroundInterval: 2, backgroundInterval: 30, hourlyLimit: 3)
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(throttle.delay(isBackground: true, history: [], now: now), 0)
        XCTAssertEqual(throttle.delay(isBackground: true, history: [now.addingTimeInterval(-10)], now: now), 20, accuracy: 0.001)
        XCTAssertEqual(throttle.delay(isBackground: false, history: [now.addingTimeInterval(-10)], now: now), 0)
        let full = [now.addingTimeInterval(-3_000), now.addingTimeInterval(-2_000), now.addingTimeInterval(-1_000)]
        XCTAssertEqual(throttle.delay(isBackground: false, history: full, now: now), 600, accuracy: 0.001)
    }

    @MainActor
    func testServiceGeneratesCachesAndMatchesVibes() async throws {
        let model = StubInsightModel()
        let cache = GeneratedInsightsCache(fileURL: nil)
        let service = GeneratedInsightsService(
            model: model,
            cache: cache,
            throttle: InsightThrottle(foregroundInterval: 0, backgroundInterval: 0, hourlyLimit: 100),
            pauseRetry: .milliseconds(10),
            workPriority: .userInitiated
        )
        service.request(longSet())
        try await waitFor { service.insights["42"] != nil }
        XCTAssertEqual(service.insights(for: "42")?.tags, ["late night", "driving", "warm"])
        XCTAssertEqual(service.vibeMatches(for: "late night drive"), ["42"])
        let stored = await cache.insights(for: "42")
        XCTAssertNotNil(stored)

        let before = model.prompts.count
        service.request(longSet())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.prompts.count, before)
    }

    @MainActor
    func testServicePausesBackgroundWorkDuringPlayback() async throws {
        let model = StubInsightModel()
        let gate = PauseGate()
        let service = GeneratedInsightsService(
            model: model,
            cache: GeneratedInsightsCache(fileURL: nil),
            throttle: InsightThrottle(foregroundInterval: 0, backgroundInterval: 0, hourlyLimit: 100),
            pauseRetry: .milliseconds(20),
            workPriority: .userInitiated,
            pause: { isBackground in isBackground && gate.paused ? .playback : .none }
        )
        service.request(InsightInput(trackId: "7", title: "Background", duration: 200), isBackground: true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.prompts.isEmpty)
        gate.paused = false
        try await waitFor { service.insights["7"] != nil }
    }

    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testQuestionHeuristicsAndSpotlightIdentifiers() {
        XCTAssertTrue(LibraryQuestionHeuristics.looksLikeQuestion("the deep house I liked last year"))
        XCTAssertTrue(LibraryQuestionHeuristics.looksLikeQuestion("anything warm for tonight?"))
        XCTAssertFalse(LibraryQuestionHeuristics.looksLikeQuestion("deep house"))
        XCTAssertEqual(LibraryQuestionHeuristics.trackID(fromSpotlightIdentifier: "TrackEntity/123456"), "123456")
        XCTAssertNil(LibraryQuestionHeuristics.trackID(fromSpotlightIdentifier: "likes"))
    }
}
