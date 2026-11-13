import Foundation
import CryptoKit

struct InsightInput: Equatable, Sendable {
    var trackId: String
    var title: String
    var artist: String
    var description: String?
    var genre: String?
    var soundCloudTags: [String]
    var comments: [String]
    var tracklist: [String]
    var bpm: Double?
    var key: String?
    var energy: Double?
    var duration: TimeInterval

    init(
        trackId: String,
        title: String,
        artist: String = "",
        description: String? = nil,
        genre: String? = nil,
        soundCloudTags: [String] = [],
        comments: [String] = [],
        tracklist: [String] = [],
        bpm: Double? = nil,
        key: String? = nil,
        energy: Double? = nil,
        duration: TimeInterval = 0
    ) {
        self.trackId = trackId
        self.title = title
        self.artist = artist
        self.description = description
        self.genre = genre
        self.soundCloudTags = soundCloudTags
        self.comments = comments
        self.tracklist = tracklist
        self.bpm = bpm
        self.key = key
        self.energy = energy
        self.duration = duration
    }

    init(track: Track, comments: [Comment] = [], tracklist: [String] = [], bpm: Double? = nil, key: String? = nil, energy: Double? = nil) {
        self.init(
            trackId: track.id,
            title: track.title,
            artist: track.user.displayName,
            description: track.description,
            genre: track.genre,
            soundCloudTags: track.tags,
            comments: comments.map(\.body),
            tracklist: tracklist,
            bpm: bpm,
            key: key,
            energy: energy,
            duration: track.duration
        )
    }

    var isLongSet: Bool { duration >= InsightPrompts.longSetSeconds }

    var usableComments: [String] {
        InsightPrompts.usableComments(comments)
    }

    var wantsSetSummary: Bool {
        guard isLongSet else { return false }
        let text = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.count >= 120 || tracklist.count >= 3
    }

    var wantsCommentSummary: Bool {
        usableComments.count >= InsightPrompts.minimumCommentsForSummary
    }

    var textDigest: String {
        let parts = [title, description ?? "", genre ?? "", soundCloudTags.joined(separator: ","), key ?? "", bpm.map { String(Int($0.rounded())) } ?? ""]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

struct GeneratedInsights: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var trackId: String
    var tags: [String]
    var setSummary: String?
    var commentSummary: String?
    var textDigest: String
    var commentCount: Int
    var tracklistCount: Int
    var generatedAt: Date
    var version: Int

    init(
        trackId: String,
        tags: [String],
        setSummary: String? = nil,
        commentSummary: String? = nil,
        textDigest: String,
        commentCount: Int = 0,
        tracklistCount: Int = 0,
        generatedAt: Date = Date(),
        version: Int = GeneratedInsights.currentVersion
    ) {
        self.trackId = trackId
        self.tags = tags
        self.setSummary = setSummary
        self.commentSummary = commentSummary
        self.textDigest = textDigest
        self.commentCount = commentCount
        self.tracklistCount = tracklistCount
        self.generatedAt = generatedAt
        self.version = version
    }

    func needsRefresh(for input: InsightInput) -> Bool {
        if version != Self.currentVersion { return true }
        if textDigest != input.textDigest { return true }
        let comments = input.usableComments.count
        if input.wantsCommentSummary, commentSummary == nil || comments >= max(commentCount * 2, commentCount + 20) { return true }
        if input.wantsSetSummary, setSummary == nil || input.tracklist.count > tracklistCount { return true }
        return false
    }
}

enum InsightPrompts {
    static let longSetSeconds: TimeInterval = 20 * 60
    static let minimumCommentsForSummary = 8
    static let maximumTags = 6
    static let minimumTags = 3
    static let descriptionBudget = 1_200
    static let commentBudget = 2_400
    static let tracklistBudget = 40
    static let summaryCharacterLimit = 320

    static let tagVocabulary: [String] = [
        "late night", "afterhours", "peak time", "warm-up", "sunrise", "sunset", "driving", "workout",
        "focus", "chill", "mellow", "dreamy", "warm", "deep", "dark", "moody", "hypnotic", "groovy",
        "funky", "soulful", "bouncy", "energetic", "euphoric", "uplifting", "emotional", "melancholic",
        "nostalgic", "atmospheric", "cinematic", "spacey", "minimal", "raw", "heavy", "acid", "tribal",
        "percussive", "vocal", "instrumental", "summer", "beach", "rainy day", "party", "romantic",
        "playful", "rolling", "lush"
    ]

    static let tagInstructions = """
    You tag music for a listener's own library. Choose 3 to 6 mood or vibe tags that describe how the track or DJ set feels and when someone would play it. Use only tags from the allowed list. Base them on the details given; never guess an artist's intent.
    """

    static let setSummaryInstructions = """
    You describe a DJ set or long mix in one or two short sentences for someone deciding whether to listen. Mention the style and how it moves. Use only the details given. Never invent track names, artists, venues or dates. No hype, no emoji, British English.
    """

    static let commentSummaryInstructions = """
    You summarise what listeners say in the comments on a track or DJ set, in one or two short sentences. Say what people love and what they keep asking about. Never quote usernames, never invent track names, and leave out anything rude. No emoji, British English.
    """

    static func tagPrompt(_ input: InsightInput) -> String {
        var lines: [String] = []
        lines.append("Title: \(clean(input.title, limit: 200))")
        if !input.artist.isEmpty { lines.append("Artist: \(clean(input.artist, limit: 120))") }
        if let genre = input.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
            lines.append("Genre: \(clean(genre, limit: 60))")
        }
        let tags = input.soundCloudTags.map { clean($0, limit: 40) }.filter { !$0.isEmpty }.prefix(15)
        if !tags.isEmpty { lines.append("Uploader tags: \(tags.joined(separator: ", "))") }
        lines.append(contentsOf: analysisLines(input))
        if input.isLongSet { lines.append("Length: \(Int(input.duration / 60)) minutes (a DJ set or mix)") }
        if let description = input.description, !description.isEmpty {
            lines.append("Description: \(clean(description, limit: descriptionBudget / 2))")
        }
        let comments = budgeted(input.usableComments, limit: commentBudget / 3)
        if !comments.isEmpty { lines.append("Listener comments: \(comments.joined(separator: " | "))") }
        lines.append("Allowed tags: \(tagVocabulary.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    static func setSummaryPrompt(_ input: InsightInput) -> String? {
        guard input.wantsSetSummary else { return nil }
        var lines: [String] = ["Title: \(clean(input.title, limit: 200))"]
        if !input.artist.isEmpty { lines.append("Artist: \(clean(input.artist, limit: 120))") }
        if let genre = input.genre, !genre.isEmpty { lines.append("Genre: \(clean(genre, limit: 60))") }
        lines.append("Length: \(Int(input.duration / 60)) minutes")
        lines.append(contentsOf: analysisLines(input))
        if let description = input.description, !description.isEmpty {
            lines.append("Description: \(clean(description, limit: descriptionBudget))")
        }
        let entries = input.tracklist.map { clean($0, limit: 100) }.filter { !$0.isEmpty }.prefix(tracklistBudget)
        if !entries.isEmpty { lines.append("Tracklist: \(entries.joined(separator: "; "))") }
        return lines.joined(separator: "\n")
    }

    static func commentSummaryPrompt(_ input: InsightInput) -> String? {
        guard input.wantsCommentSummary else { return nil }
        let comments = budgeted(input.usableComments, limit: commentBudget)
        return "Title: \(clean(input.title, limit: 200))\nComments:\n" + comments.map { "- \($0)" }.joined(separator: "\n")
    }

    static func usableComments(_ comments: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in comments {
            let text = clean(raw, limit: 280)
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard letters >= 3 else { continue }
            let key = text.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(text)
        }
        return result
    }

    static func normalizeTags(_ raw: [String]) -> [String] {
        let allowed = Dictionary(uniqueKeysWithValues: tagVocabulary.map { (canonical($0), $0) })
        var result: [String] = []
        for tag in raw {
            guard let match = allowed[canonical(tag)], !result.contains(match) else { continue }
            result.append(match)
            if result.count == maximumTags { break }
        }
        return result
    }

    static func cleanSummary(_ raw: String) -> String? {
        var text = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        guard text.count >= 12 else { return nil }
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, stop in
            if let substring { sentences.append(substring.trimmingCharacters(in: .whitespaces)) }
            if sentences.count == 2 { stop = true }
        }
        var joined = sentences.isEmpty ? text : sentences.joined(separator: " ")
        if joined.count > summaryCharacterLimit {
            let cut = joined.prefix(summaryCharacterLimit)
            joined = (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? String(cut)) + "…"
        }
        return joined
    }

    static func vibeScore(tags: [String], query: String) -> Int {
        let needle = canonical(query)
        guard !needle.isEmpty else { return 0 }
        let words = Set(needle.split(separator: " ").map(String.init))
        var score = 0
        for tag in tags.map(canonical) {
            if needle == tag { score += 4 }
            else if needle.contains(tag) { score += 3 }
            else if tag.split(separator: " ").allSatisfy({ words.contains(String($0)) }) { score += 2 }
        }
        return score
    }

    private static func analysisLines(_ input: InsightInput) -> [String] {
        var lines: [String] = []
        if let bpm = input.bpm, bpm > 0 { lines.append("Tempo: \(Int(bpm.rounded())) BPM") }
        if let key = input.key, !key.isEmpty { lines.append("Key: \(key)") }
        if let energy = input.energy {
            let clamped = min(1, max(0, energy))
            let word = clamped < 0.33 ? "low" : clamped < 0.66 ? "medium" : "high"
            lines.append("Energy: \(word)")
        }
        return lines
    }

    private static func budgeted(_ values: [String], limit: Int) -> [String] {
        var used = 0
        var result: [String] = []
        for value in values {
            guard used + value.count <= limit else { break }
            used += value.count + 3
            result.append(value)
        }
        return result
    }

    static func clean(_ value: String, limit: Int) -> String {
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count > limit ? String(collapsed.prefix(limit)) : collapsed
    }

    private static func canonical(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

enum LibraryQuestionHeuristics {
    static let leadWords: Set<String> = ["the", "that", "what", "which", "something", "anything", "my", "those", "songs", "tracks", "sets", "music", "show", "find", "play"]
    static let timeWords: Set<String> = ["liked", "saved", "last", "year", "month", "week", "yesterday", "ago", "played", "from", "when", "since"]

    static func looksLikeQuestion(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard words.count >= 3 else { return false }
        if query.hasSuffix("?") { return true }
        return words.contains(where: timeWords.contains) && words.contains(where: leadWords.contains)
    }

    static func trackID(fromSpotlightIdentifier identifier: String) -> String? {
        let digits = identifier.reversed().prefix { $0.isNumber }
        guard digits.count >= 3 else { return nil }
        return String(digits.reversed())
    }
}

protocol InsightLanguageModel: Sendable {
    var isAvailable: Bool { get }
    func tags(instructions: String, prompt: String) async throws -> [String]
    func summary(instructions: String, prompt: String) async throws -> String
}

struct UnavailableInsightModel: InsightLanguageModel {
    var isAvailable: Bool { false }
    func tags(instructions: String, prompt: String) async throws -> [String] { [] }
    func summary(instructions: String, prompt: String) async throws -> String { "" }
}

enum InsightGenerator {
    static func generate(_ input: InsightInput, model: any InsightLanguageModel, previous: GeneratedInsights? = nil) async -> GeneratedInsights? {
        guard model.isAvailable else { return nil }
        let rawTags = (try? await model.tags(instructions: InsightPrompts.tagInstructions, prompt: InsightPrompts.tagPrompt(input))) ?? []
        let tags = InsightPrompts.normalizeTags(rawTags)
        guard !Task.isCancelled else { return nil }

        var setSummary = previous?.setSummary
        if let prompt = InsightPrompts.setSummaryPrompt(input),
           previous?.setSummary == nil || input.tracklist.count > (previous?.tracklistCount ?? 0) || previous?.textDigest != input.textDigest,
           let raw = try? await model.summary(instructions: InsightPrompts.setSummaryInstructions, prompt: prompt) {
            setSummary = InsightPrompts.cleanSummary(raw) ?? setSummary
        }
        guard !Task.isCancelled else { return nil }

        var commentSummary = previous?.commentSummary
        if let prompt = InsightPrompts.commentSummaryPrompt(input),
           let raw = try? await model.summary(instructions: InsightPrompts.commentSummaryInstructions, prompt: prompt) {
            commentSummary = InsightPrompts.cleanSummary(raw) ?? commentSummary
        }

        let resolvedTags = tags.isEmpty ? (previous?.tags ?? []) : tags
        guard !resolvedTags.isEmpty || setSummary != nil || commentSummary != nil else { return nil }
        return GeneratedInsights(
            trackId: input.trackId,
            tags: resolvedTags,
            setSummary: input.isLongSet ? setSummary : nil,
            commentSummary: commentSummary,
            textDigest: input.textDigest,
            commentCount: input.usableComments.count,
            tracklistCount: input.tracklist.count
        )
    }
}

actor GeneratedInsightsCache {
    private let fileURL: URL?
    private let capacity: Int
    private let journal: SoundingDataJournal<GeneratedInsights>?
    private var entries: [String: GeneratedInsights] = [:]
    private var loaded = false

    init(fileURL: URL?, capacity: Int = 4_000) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        if let fileURL, fileURL == Self.defaultFileURL() {
            journal = SoundingDataJournal(area: .insights)
        } else {
            journal = fileURL.map { SoundingDataJournal(directory: $0.deletingPathExtension().appendingPathExtension("journal")) }
        }
    }

    static func defaultFileURL() -> URL {
        AppDataDirectory.folder("GeneratedInsights").appendingPathComponent("insights.json")
    }

    func all() -> [String: GeneratedInsights] {
        loadIfNeeded()
        return entries
    }

    func insights(for trackId: String) -> GeneratedInsights? {
        loadIfNeeded()
        return entries[trackId]
    }

    func store(_ insights: GeneratedInsights) {
        loadIfNeeded()
        guard entries[insights.trackId] != insights else { return }
        entries[insights.trackId] = insights
        journal?.put(insights.trackId, insights)
        if entries.count > capacity {
            let overflow = entries.values.sorted { $0.generatedAt < $1.generatedAt }.prefix(entries.count - capacity)
            for stale in overflow {
                entries[stale.trackId] = nil
                journal?.remove(stale.trackId)
            }
        }
    }

    func removeAll() {
        entries = [:]
        loaded = true
        journal?.clearAll()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    func reload() {
        loaded = false
        loadIfNeeded()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let journal else { return }
        if let fileURL {
            journal.migrateLegacy(file: fileURL) { data in
                ((try? JSONDecoder().decode([GeneratedInsights].self, from: data)) ?? []).map { ($0.trackId, $0) }
            }
        }
        entries = journal.load()
    }
}

struct InsightThrottle: Sendable {
    var foregroundInterval: TimeInterval = 2
    var backgroundInterval: TimeInterval = 30
    var hourlyLimit: Int = 40

    func delay(isBackground: Bool, history: [Date], now: Date) -> TimeInterval {
        let recent = history.filter { now.timeIntervalSince($0) < 3_600 }.sorted()
        var wait: TimeInterval = 0
        if let last = recent.last {
            wait = max(wait, (isBackground ? backgroundInterval : foregroundInterval) - now.timeIntervalSince(last))
        }
        if recent.count >= hourlyLimit, let oldest = recent.first {
            wait = max(wait, 3_600 - now.timeIntervalSince(oldest))
        }
        return max(0, wait)
    }
}

enum InsightPause: Equatable, Sendable {
    case none
    case device
    case playback
}

@MainActor
final class GeneratedInsightsService: ObservableObject {
    static let visibilityKey = "red.forbes.sounding.generatedInsights.visible"

    static let shared = GeneratedInsightsService(
        model: InsightModelFactory.make(),
        cache: GeneratedInsightsCache(fileURL: GeneratedInsightsCache.defaultFileURL()),
        pause: { isBackground in
            if AutomaticAnalysisEligibility.systemPauseReason() != nil { return .device }
            if isBackground, AutomaticAnalysisEligibility.isPlaybackActive { return .playback }
            return .none
        }
    )

    @Published private(set) var insights: [String: GeneratedInsights] = [:]
    @Published private(set) var generatingTrackIds: Set<String> = []

    let model: any InsightLanguageModel
    private let cache: GeneratedInsightsCache
    private let pause: @MainActor (Bool) -> InsightPause
    private let throttle: InsightThrottle
    private let pauseRetry: Duration
    private let workPriority: TaskPriority
    private var foreground: [InsightInput] = []
    private var background: [InsightInput] = []
    private var history: [Date] = []
    private var worker: Task<Void, Never>?
    private var didLoad = false
    private var lastVisible = true
    private var visibilityObserver: NSObjectProtocol?

    init(
        model: any InsightLanguageModel,
        cache: GeneratedInsightsCache,
        throttle: InsightThrottle = InsightThrottle(),
        pauseRetry: Duration = .seconds(60),
        workPriority: TaskPriority = .background,
        pause: @escaping @MainActor (Bool) -> InsightPause = { _ in .none }
    ) {
        self.model = model
        self.cache = cache
        self.throttle = throttle
        self.pauseRetry = pauseRetry
        self.workPriority = workPriority
        self.pause = pause
        lastVisible = isVisible
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteVisibilityChange() }
        }
    }

    private func noteVisibilityChange() {
        let visible = isVisible
        guard visible != lastVisible else { return }
        lastVisible = visible
        objectWillChange.send()
    }

    var isAvailable: Bool { model.isAvailable }

    var isVisible: Bool {
        UserDefaults.sounding.object(forKey: Self.visibilityKey) as? Bool ?? true
    }

    var isEnabled: Bool { isAvailable && isVisible }

    func insights(for trackId: String?) -> GeneratedInsights? {
        guard let trackId, isEnabled else { return nil }
        return insights[trackId]
    }

    func loadCache() async {
        guard !didLoad else { return }
        didLoad = true
        let stored = await cache.all()
        insights.merge(stored) { current, _ in current }
    }

    func request(_ input: InsightInput, isBackground: Bool = false) {
        guard isEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.loadCache()
            if let cached = self.insights[input.trackId], !cached.needsRefresh(for: input) { return }
            self.enqueue(input, isBackground: isBackground)
        }
    }

    func vibeMatches(for query: String, limit: Int = 12) -> [String] {
        guard isEnabled else { return [] }
        return insights.values
            .map { ($0, InsightPrompts.vibeScore(tags: $0.tags, query: query)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.generatedAt > $1.0.generatedAt }
            .prefix(limit)
            .map(\.0.trackId)
    }

    func clear() async {
        foreground = []
        background = []
        worker?.cancel()
        worker = nil
        insights = [:]
        await cache.removeAll()
    }

    func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    private func enqueue(_ input: InsightInput, isBackground: Bool) {
        foreground.removeAll { $0.trackId == input.trackId }
        if isBackground {
            guard !background.contains(where: { $0.trackId == input.trackId }) else { return }
            background.append(input)
            if background.count > 200 { background.removeFirst(background.count - 200) }
        } else {
            background.removeAll { $0.trackId == input.trackId }
            foreground.insert(input, at: 0)
            if foreground.count > 8 { foreground.removeLast(foreground.count - 8) }
        }
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task(priority: workPriority) { [weak self] in
            await self?.drain()
            self?.worker = nil
        }
    }

    private func drain() async {
        while !Task.isCancelled {
            let isBackground = foreground.isEmpty
            guard let next = isBackground ? background.first : foreground.first else { return }

            switch pause(isBackground) {
            case .none:
                break
            case .device, .playback:
                try? await Task.sleep(for: pauseRetry)
                continue
            }

            let wait = throttle.delay(isBackground: isBackground, history: history, now: Date())
            if wait > 0 {
                try? await Task.sleep(for: .milliseconds(Int(wait * 1_000)))
                continue
            }

            if isBackground { background.removeFirst() } else { foreground.removeFirst() }
            history.append(Date())
            history.removeAll { Date().timeIntervalSince($0) > 3_600 }

            generatingTrackIds.insert(next.trackId)
            let previous = insights[next.trackId]
            let model = self.model
            let result = await Task.detached(priority: workPriority) {
                await InsightGenerator.generate(next, model: model, previous: previous)
            }.value
            generatingTrackIds.remove(next.trackId)

            guard let result else { continue }
            await cache.store(result)
            insights[result.trackId] = result
        }
    }
}
