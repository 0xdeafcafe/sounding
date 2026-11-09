#if DEBUG
import Foundation
import XCTest
@testable import SoundingTV

struct StubAutoMixLanguageModel: AutoMixLanguageModel {
    var isAvailable = true
    var draft: SetIntentDraft?
    var why: GeneratedLine?
    var summary: GeneratedLine?

    func intentDraft(for request: String, now: Date) async throws -> SetIntentDraft? { draft }
    func whyLine(facts: [String]) async throws -> GeneratedLine? { why }
    func flairSummary(facts: [String]) async throws -> GeneratedLine? { summary }
}

enum AutoMixAIPickingFixtures {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    static var tenPM: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 22, minute: 0))!
    }

    static func embedding(_ seed: [Float], noise: Float = 0) -> TimbreEmbedding {
        let frames = (0..<20).map { i in seed.enumerated().map { $0.element + noise * Float(($0.offset * 7 + i * 3) % 5 - 2) } }
        return TimbreEmbedding(frames: frames)!
    }

    static func track(_ id: String, bpm: Double = 124, key: String = "8A", energy: Int = 5, vocals: Bool = false, timbre: TimbreEmbedding? = nil) -> TrackFeatures {
        var features = TrackFeatures(
            trackId: id, title: id, artist: "artist-\(id)", duration: 300,
            beatGrid: BeatGrid.tempoOnly(bpm),
            keyRegions: CamelotKey.parse(key).map { [KeyRegion(key: $0, start: 0, end: 300)] } ?? [],
            energyLevel: energy,
            vocalRanges: vocals ? [60...120] : []
        )
        features.timbre = timbre
        return features
    }
}

final class AutoMixAIPickingTests: XCTestCase {
    typealias F = AutoMixAIPickingFixtures

    // MARK: - Embeddings

    func testEmbeddingSimilaritySanity() {
        let house = F.embedding([1, 0.8, 0.1, 0, 0.3, 0.2])
        let houseAgain = F.embedding([1, 0.8, 0.1, 0, 0.3, 0.2], noise: 0.05)
        let ambient = F.embedding([0, 0.1, 1, 0.9, 0, 0])
        XCTAssertEqual(house.similarity(to: house) ?? 0, 1, accuracy: 0.001)
        XCTAssertGreaterThan(house.similarity(to: houseAgain) ?? 0, 0.97)
        XCTAssertLessThan(house.similarity(to: ambient) ?? 1, 0.5)
        XCTAssertEqual(house.similarity(to: ambient), ambient.similarity(to: house))
        XCTAssertNil(TimbreEmbedding.cosine([Int8](), [Int8]()))
        XCTAssertNil(TimbreEmbedding(frames: []))
    }

    func testEmbeddingQuantisesToUnitLength() {
        let embedding = F.embedding([3, 4, 0])
        XCTAssertEqual(embedding.whole, [76, 102, 0])
        XCTAssertEqual(embedding.frames, 20)
    }

    func testSoundCostOrdersBySimilarity() {
        let a = F.embedding([1, 0.8, 0.1, 0, 0.3])
        let near = F.embedding([1, 0.8, 0.1, 0, 0.3], noise: 0.02)
        let far = F.embedding([0, 0.1, 1, 0.9, 0])
        XCTAssertLessThan(TimbreScoring.cost(from: a, to: near), TimbreScoring.cost(from: a, to: far))
        XCTAssertEqual(TimbreScoring.cost(from: nil, to: far), TimbreScoring.unknownCost)
    }

    func testPickerPrefersTheTrackThatSoundsAlike() {
        let seedSound = F.embedding([1, 0.8, 0.1, 0, 0.3])
        let outgoing = F.track("seed", timbre: seedSound)
        let alike = F.track("alike", timbre: F.embedding([1, 0.8, 0.1, 0, 0.3], noise: 0.02))
        let other = F.track("other", timbre: F.embedding([0, 0.1, 1, 0.9, 0]))
        let choice = DJFlowSelector.choose(outgoing: outgoing, candidates: [other, alike], history: .empty, profile: .automaticDJ, keepQueueOrder: false)
        XCTAssertEqual(choice?.trackId, "alike")
        XCTAssertTrue(choice?.why.contains("sounds alike") ?? false)
        let blind = DJFlowSelector.choose(
            outgoing: F.track("seed"), candidates: [F.track("other"), F.track("alike")],
            history: .empty, profile: .automaticDJ, keepQueueOrder: false
        )
        XCTAssertEqual(blind?.trackId, "other")
    }

    // MARK: - Set intent

    func testDeterministicParserReadsTheOwnersExample() {
        let intent = SetIntentParser.parse("warm-up set, building to peak by midnight, no vocals until 11", now: F.tenPM, calendar: F.calendar)
        XCTAssertEqual(intent?.startEnergy, 3)
        XCTAssertEqual(intent?.targetEnergy, 9)
        XCTAssertEqual(intent?.rampMinutes ?? 0, 120, accuracy: 0.5)
        XCTAssertEqual(intent?.vocalsAfterMinutes ?? 0, 60, accuracy: 0.5)
        XCTAssertEqual(intent?.targetEnergy(atMinute: 0), 3)
        XCTAssertEqual(intent?.targetEnergy(atMinute: 60), 6)
        XCTAssertEqual(intent?.targetEnergy(atMinute: 200), 9)
        XCTAssertEqual(intent?.allowsVocals(atMinute: 30), false)
        XCTAssertEqual(intent?.allowsVocals(atMinute: 61), true)
    }

    func testDeterministicParserTempoAndLength() {
        let intent = SetIntentParser.parse("2 hour set, 120-126 bpm, instrumental", now: F.tenPM, calendar: F.calendar)
        XCTAssertEqual(intent?.minBPM, 120)
        XCTAssertEqual(intent?.maxBPM, 126)
        XCTAssertEqual(intent?.durationMinutes, 120)
        XCTAssertEqual(intent?.vocalsAfterMinutes, SetIntent.noVocalsEver)
        XCTAssertEqual(intent?.bpmOutsideRange(124), 0)
        XCTAssertEqual(intent?.bpmOutsideRange(62), 0)
        XCTAssertEqual(intent?.bpmOutsideRange(130), 4)
        XCTAssertNil(SetIntentParser.parse("hello there", now: F.tenPM, calendar: F.calendar))
        XCTAssertEqual(SetIntentParser.parse("wind down", now: F.tenPM, calendar: F.calendar)?.targetEnergy, 3)
    }

    func testStubbedModelDraftBecomesIntent() async {
        let draft = SetIntentDraft(startEnergy: 2, targetEnergy: 10, reachTargetAt: "00:00", noVocalsUntil: "23:00", minBPM: 118, maxBPM: 128)
        let language = AutoMixLanguage(model: StubAutoMixLanguageModel(draft: draft))
        let intent = await language.intent(for: "slow start, peak at midnight", now: F.tenPM, calendar: F.calendar)
        XCTAssertEqual(intent?.startEnergy, 2)
        XCTAssertEqual(intent?.targetEnergy, 10)
        XCTAssertEqual(intent?.rampMinutes ?? 0, 120, accuracy: 0.5)
        XCTAssertEqual(intent?.vocalsAfterMinutes ?? 0, 60, accuracy: 0.5)
        XCTAssertEqual(intent?.minBPM, 118)
        XCTAssertEqual(intent?.text, "slow start, peak at midnight")
    }

    func testStubbedModelOutOfRangeValuesAreClamped() {
        let intent = SetIntentDraft(startEnergy: -4, targetEnergy: 40, minBPM: 20, maxBPM: 128).intent(text: "x", now: F.tenPM, calendar: F.calendar)
        XCTAssertEqual(intent.startEnergy, 1)
        XCTAssertEqual(intent.targetEnergy, 10)
        XCTAssertNil(intent.minBPM)
        XCTAssertEqual(intent.maxBPM, 128)
    }

    func testUnavailableModelFallsBackToParser() async {
        let language = AutoMixLanguage(model: UnavailableAutoMixLanguageModel())
        let intent = await language.intent(for: "warm-up, around 122 bpm", now: F.tenPM, calendar: F.calendar)
        XCTAssertEqual(intent?.startEnergy, 3)
        XCTAssertEqual(intent?.minBPM, 119)
        XCTAssertEqual(intent?.maxBPM, 125)
    }

    func testIntentSteersThePickerAwayFromVocals() {
        var history = SetHistory()
        history.intent = SetIntent(text: "x", startEnergy: 3, targetEnergy: 3, vocalsAfterMinutes: 30)
        let outgoing = F.track("seed", energy: 3)
        let vocal = F.track("vocal", energy: 3, vocals: true)
        let dub = F.track("dub", energy: 3)
        let choice = DJFlowSelector.choose(outgoing: outgoing, candidates: [vocal, dub], history: history, profile: .automaticDJ, keepQueueOrder: false)
        XCTAssertEqual(choice?.trackId, "dub")
        history.setMinute = 45
        let later = DJFlowSelector.choose(outgoing: outgoing, candidates: [vocal, dub], history: history, profile: .automaticDJ, keepQueueOrder: false)
        XCTAssertEqual(later?.trackId, "vocal")
    }

    func testJourneyFollowsTheArc() {
        var history = SetHistory()
        history.intent = SetIntent(text: "x", startEnergy: 3, targetEnergy: 9, rampMinutes: 15)
        let seed = F.track("seed", energy: 3)
        let pool = [9, 4, 7, 5, 8, 6].map { F.track("e\($0)", energy: $0) }
        let journey = SetJourney.plan(from: seed, pool: pool, history: history)
        let energies = journey?.steps.compactMap(\.energy) ?? []
        XCTAssertEqual(energies.count, 6)
        XCTAssertEqual(energies.first, 4)
        XCTAssertLessThan(energies.prefix(3).reduce(0, +), energies.suffix(3).reduce(0, +))
    }

    // MARK: - Grounded lines

    func testWhyLineFallsBackWithoutModel() async {
        let reasons = [PickReason(kind: .key, text: "Same key"), PickReason(kind: .tempo, text: "124 → 126 BPM")]
        let line = await AutoMixLanguage(model: UnavailableAutoMixLanguageModel()).whyLine(reasons)
        XCTAssertEqual(line, "Same key · 124 → 126 BPM")
    }

    func testWhyLineRejectsInventedFacts() async {
        let reasons = [PickReason(kind: .key, text: "Same key"), PickReason(kind: .tempo, text: "124 → 126 BPM")]
        let invented = StubAutoMixLanguageModel(why: GeneratedLine(line: "Same key at 128 BPM, a disco classic", usedFacts: [0, 1]))
        let rejected = await AutoMixLanguage(model: invented).whyLine(reasons)
        XCTAssertEqual(rejected, "Same key · 124 → 126 BPM")
        let wrongKey = StubAutoMixLanguageModel(why: GeneratedLine(line: "Stays in 8A, nudging from 124 to 126", usedFacts: [0, 1]))
        let rejectedKey = await AutoMixLanguage(model: wrongKey).whyLine(reasons)
        XCTAssertEqual(rejectedKey, "Same key · 124 → 126 BPM")
        let grounded = StubAutoMixLanguageModel(why: GeneratedLine(line: "Same key, nudging from 124 to 126", usedFacts: [0, 1]))
        let accepted = await AutoMixLanguage(model: grounded).whyLine(reasons)
        XCTAssertEqual(accepted, "Same key, nudging from 124 to 126")
        let badIndex = StubAutoMixLanguageModel(why: GeneratedLine(line: "Same key", usedFacts: [7]))
        let rejectedIndex = await AutoMixLanguage(model: badIndex).whyLine(reasons)
        XCTAssertEqual(rejectedIndex, "Same key · 124 → 126 BPM")
    }

    func testFlairSummaryFallback() async {
        let language = AutoMixLanguage(model: UnavailableAutoMixLanguageModel())
        let summary = await language.flairSummary(["You like long blends", "Echo outs aren’t for you", "You keep it in key"])
        XCTAssertEqual(summary, "You like long blends, echo outs aren’t for you, and you keep it in key.")
        let empty = await language.flairSummary([])
        XCTAssertNil(empty)
        let one = await language.flairSummary(["You like long mixes"])
        XCTAssertEqual(one, "You like long mixes.")
    }
}
#endif
