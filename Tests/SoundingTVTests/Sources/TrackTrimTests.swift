import XCTest
import Combine
@testable import SoundingTV

@MainActor
final class TrackTrimTests: XCTestCase {
    func testUntrimmedRangeIsTheWholeTrack() {
        XCTAssertEqual(TrackTrimStore.range(nil, duration: 240), 0...240)
        XCTAssertEqual(TrackTrim().playableRange(duration: 240), 0...240)
    }

    func testRangeHonoursStartAndEnd() {
        XCTAssertEqual(TrackTrim(start: 30, end: 200).playableRange(duration: 240), 30...200)
        XCTAssertEqual(TrackTrim(start: 30).playableRange(duration: 240), 30...240)
        XCTAssertEqual(TrackTrim(end: 210).playableRange(duration: 240), 0...210)
    }

    func testRangeClampsToTheTrackAndKeepsASecond() {
        XCTAssertEqual(TrackTrim(start: -5, end: 900).playableRange(duration: 240), 0...240)
        XCTAssertEqual(TrackTrim(start: 300).playableRange(duration: 240), 239...240)
        XCTAssertEqual(TrackTrim(start: 100, end: 50).playableRange(duration: 240), 49...50)
        XCTAssertEqual(TrackTrim(start: .nan, end: .infinity).playableRange(duration: 240), 0...240)
    }

    func testUnknownDurationKeepsTheStart() {
        let range = TrackTrim(start: 12).playableRange(duration: 0)
        XCTAssertEqual(range.lowerBound, 12)
        XCTAssertGreaterThan(range.upperBound, 1_000_000)
    }

    func testNormalisingDropsNoOpTrims() {
        XCTAssertNil(TrackTrim(start: 0, end: 240).normalised(duration: 240))
        XCTAssertNil(TrackTrim(start: -1, end: 900).normalised(duration: 240))
        XCTAssertEqual(TrackTrim(start: 30, end: 240).normalised(duration: 240), TrackTrim(start: 30))
        XCTAssertEqual(TrackTrim(end: 200).normalised(duration: 240), TrackTrim(end: 200))
    }

    func testTimelineMapsRawPositionsToTheTrimmedLength() {
        let timeline = TrackTrimTimeline(range: 30...210, duration: 240)
        XCTAssertTrue(timeline.isTrimmed)
        XCTAssertEqual(timeline.length, 180)
        XCTAssertEqual(timeline.elapsed(at: 30), 0)
        XCTAssertEqual(timeline.elapsed(at: 10), 0)
        XCTAssertEqual(timeline.elapsed(at: 120), 90)
        XCTAssertEqual(timeline.remaining(at: 120), 90)
        XCTAssertEqual(timeline.remaining(at: 230), 0)
        XCTAssertEqual(timeline.fraction(at: 120), 0.5)
        XCTAssertEqual(timeline.position(atFraction: 0.5), 120)
        XCTAssertEqual(timeline.position(atFraction: 2), 210)
        XCTAssertEqual(timeline.position(atElapsed: 15), 45)
        XCTAssertEqual(timeline.clamped(5), 30)
        XCTAssertEqual(timeline.clamped(239), 210)
        XCTAssertEqual(timeline.clamped(.nan), 30)
    }

    func testUntrimmedTimelineIsIdentity() {
        let timeline = TrackTrimTimeline(range: 0...240, duration: 240)
        XCTAssertFalse(timeline.isTrimmed)
        XCTAssertEqual(timeline.elapsed(at: 61), 61)
        XCTAssertEqual(timeline.remaining(at: 61), 179)
    }

    func testStoreSetsNormalisesAndPersists() {
        var persisted: [[String: TrackTrim]] = []
        let snapshot = TrackTrimSnapshot()
        let store = TrackTrimStore(snapshot: snapshot, persist: { persisted.append($0) })

        store.setTrim(TrackTrim(start: 30, end: 240), for: "a", duration: 240)
        XCTAssertEqual(store.trim(for: "a"), TrackTrim(start: 30))
        XCTAssertEqual(snapshot.trim(for: "a"), TrackTrim(start: 30))
        XCTAssertEqual(store.effectiveRange(for: "a", duration: 240), 30...240)
        XCTAssertEqual(store.effectiveRange(for: "b", duration: 240), 0...240)
        XCTAssertEqual(persisted.last, ["a": TrackTrim(start: 30)])

        store.setTrim(TrackTrim(start: 30, end: 240), for: "a", duration: 240)
        XCTAssertEqual(persisted.count, 1)

        store.setTrim(TrackTrim(start: 0, end: 240), for: "a", duration: 240)
        XCTAssertNil(store.trim(for: "a"))
        XCTAssertNil(snapshot.trim(for: "a"))
        XCTAssertEqual(persisted.last, [:])
    }

    func testStoreResetRemovesTheTrim() {
        let store = TrackTrimStore(initial: ["a": TrackTrim(start: 5, end: 100)])
        XCTAssertEqual(store.effectiveRange(for: "a", duration: 240), 5...100)
        store.reset("a")
        XCTAssertNil(store.trim(for: "a"))
        XCTAssertEqual(store.effectiveRange(for: "a", duration: 240), 0...240)
    }

    func testStoreAdoptsSyncedUpdates() {
        let subject = PassthroughSubject<[String: TrackTrim], Never>()
        let snapshot = TrackTrimSnapshot()
        var persisted = 0
        let store = TrackTrimStore(
            snapshot: snapshot,
            persist: { _ in persisted += 1 },
            updates: subject.eraseToAnyPublisher()
        )
        subject.send(["remote": TrackTrim(end: 180)])
        XCTAssertEqual(store.trim(for: "remote"), TrackTrim(end: 180))
        XCTAssertEqual(snapshot.trim(for: "remote"), TrackTrim(end: 180))
        XCTAssertEqual(persisted, 0)
    }

    func testTrimsRoundTripThroughTheSettingsPayload() throws {
        let value = ["a": TrackTrim(start: 1.5, end: 99.25), "b": TrackTrim(start: 30)]
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode([String: TrackTrim].self, from: data), value)
        XCTAssertEqual(SettingKeys.TrackTrims.defaultScope, .account)
    }

    func testSuggestionFindsLeadingAndTrailingSilence() throws {
        var samples = [Float](repeating: 0.005, count: 100)
        for index in 10..<90 { samples[index] = 0.6 }
        let trim = try XCTUnwrap(TrackTrimSuggestion.silence(in: samples, duration: 100))
        XCTAssertEqual(trim.start, 9, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(trim.end), 91, accuracy: 0.001)
    }

    func testSuggestionIgnoresTracksWithoutSilence() {
        let samples = [Float](repeating: 0.5, count: 100)
        XCTAssertNil(TrackTrimSuggestion.silence(in: samples, duration: 100))
        XCTAssertNil(TrackTrimSuggestion.silence(in: [Float](repeating: 0, count: 100), duration: 100))
        XCTAssertNil(TrackTrimSuggestion.silence(in: [], duration: 100))
    }

    func testSuggestionKeepsOnlyTheTrailingSilence() throws {
        var samples = [Float](repeating: 0.5, count: 200)
        for index in 150..<200 { samples[index] = 0 }
        let trim = try XCTUnwrap(TrackTrimSuggestion.silence(in: samples, duration: 200))
        XCTAssertEqual(trim.start, 0)
        XCTAssertEqual(try XCTUnwrap(trim.end), 151, accuracy: 0.001)
    }
}
