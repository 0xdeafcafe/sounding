#if DEBUG
import Combine
import Foundation
import XCTest
@testable import SoundingTV

@MainActor
final class MixHistoryTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MixHistoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(library: SavedMixLibrary = SavedMixLibrary(), persisted: ((SavedMixLibrary) -> Void)? = nil) -> MixHistoryStore {
        MixHistoryStore(
            fileURL: directory.appendingPathComponent("history.json"),
            library: library,
            persistLibrary: persisted ?? { _ in }
        )
    }

    private var fixture: [MixHistoryEntry] { MixHistoryStore.fixtureEntries() }

    private func record(_ entry: MixHistoryEntry, into store: MixHistoryStore, at date: Date) -> MixHistoryEntry {
        store.record(outgoing: entry.outgoing, incoming: entry.incoming, plan: entry.plan, execution: entry.execution, performance: entry.performance, date: date)
    }

    func testRecordingChainsTransitionsIntoOneSession() {
        let store = makeStore()
        var date = Date()
        for entry in fixture {
            _ = record(entry, into: store, at: date)
            date = date.addingTimeInterval(240)
        }
        XCTAssertEqual(store.entries.count, 5)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].tracks.map(\.id), [fixture[0].outgoing.id] + fixture.map(\.incoming.id))
    }

    func testBrokenChainStartsANewSession() {
        let store = makeStore()
        let entries = fixture
        _ = record(entries[0], into: store, at: Date())
        _ = record(entries[2], into: store, at: Date().addingTimeInterval(60))
        XCTAssertEqual(store.sessions.count, 2)
    }

    func testLongGapStartsANewSession() {
        let store = makeStore()
        let entries = fixture
        let first = record(entries[0], into: store, at: Date())
        let second = record(entries[1], into: store, at: Date().addingTimeInterval(MixHistoryStore.sessionGap + entries[1].outgoing.track.duration + 60))
        XCTAssertNotEqual(first.sessionID, second.sessionID)
    }

    func testHistoryIsCapped() {
        let store = makeStore()
        let entry = fixture[0]
        for i in 0..<(MixHistoryStore.storedLimit + 20) {
            _ = record(entry, into: store, at: Date().addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(store.entries.count, MixHistoryStore.storedLimit)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries.count, MixHistoryStore.storedLimit)
        XCTAssertEqual(reloaded.entries.last, store.entries.last)
    }

    func testRatingAttachesToTheLatestTransition() {
        let store = makeStore()
        _ = record(fixture[0], into: store, at: Date())
        _ = record(fixture[1], into: store, at: Date().addingTimeInterval(200))
        store.rateLatest(liked: false)
        XCTAssertNil(store.entries[0].liked)
        XCTAssertEqual(store.entries[1].liked, false)
    }

    func testEntryAndLibraryRoundTripThroughCodable() throws {
        let entry = fixture[2]
        let decoded = try JSONDecoder().decode(MixHistoryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
        let library = SavedMixLibrary(
            mixes: [SavedMix(id: UUID(), name: entry.title, savedAt: Date(timeIntervalSince1970: 1), entry: entry)],
            sets: [SavedSet(id: entry.sessionID, name: "Set", savedAt: Date(timeIntervalSince1970: 2), entries: fixture)]
        )
        XCTAssertEqual(SavedMixLibrary(data: library.encoded), library)
        XCTAssertEqual(SavedMixLibrary(data: Data()), SavedMixLibrary())
    }

    func testPhantomPlanSurvivesTheRecord() {
        let entry = fixture[0]
        let plan = entry.plan.phantomPlan
        XCTAssertEqual(MixPlanRecord(plan), entry.plan)
        XCTAssertEqual(plan.move, entry.plan.move)
        XCTAssertEqual(plan.stages, entry.plan.stages)
        XCTAssertEqual(plan.outgoingBeatGrid, entry.plan.outgoingBeatGrid)
    }

    func testReplayedPlanProducesTheRecordedTimeline() {
        for entry in fixture {
            let plan = entry.plan.phantomPlan
            let request = MixTransitionPerformer.Request(
                outgoing: .a, incoming: .b, window: plan.transitionSeconds, entrySeconds: entry.execution.entrySeconds,
                plan: plan, filterAccent: plan.accent, announceAsMix: true, startAtPlannedBoundary: true,
                outgoingGridFallback: nil, rateBudgetPercent: 8, legacyTempoMatch: nil, resetsIncoming: true, startsPaused: false
            )
            let live = MixTransitionPerformer.timelineInput(
                for: request, anchorSourceSeconds: entry.execution.startSourceSeconds,
                outgoingRate: entry.execution.outgoingRate, incomingRate: entry.execution.incomingRate, sampleRate: entry.execution.sampleRate
            )
            let replay = MixReplayPlanner.reconcile(entry.plan, currentOutgoingGrid: entry.plan.outgoingBeatGrid, currentIncomingGrid: entry.plan.incomingBeatGrid)
            let stored = MixReplayPlanner.timelineInput(plan: replay.plan, execution: entry.execution, outgoing: 0, incoming: 1)
            XCTAssertEqual(MixTimeline.transition(stored), MixTimeline.transition(live), entry.moveName)
        }
    }

    func testMovedGridIsResnappedAndExplained() throws {
        let entry = fixture[1]
        let recorded = try XCTUnwrap(entry.plan.outgoingBeatGrid)
        let moved = BeatGrid(anchor: recorded.anchor + 0.12, beatPeriod: recorded.beatPeriod, confidence: 0.9)
        let result = MixReplayPlanner.reconcile(entry.plan, currentOutgoingGrid: moved, currentIncomingGrid: entry.plan.incomingBeatGrid)
        XCTAssertTrue(result.resnapped)
        XCTAssertNotNil(result.notice)
        XCTAssertEqual(result.plan.mixPointSeconds, moved.nearestDownbeat(to: entry.plan.mixPointSeconds), accuracy: 1e-9)
        XCTAssertEqual(result.plan.outgoingBeatGrid, moved)
        XCTAssertEqual(result.plan.stages, entry.plan.stages)
        XCTAssertEqual(result.plan.move, entry.plan.move)
    }

    func testUnchangedGridKeepsTheExactPlan() {
        let entry = fixture[3]
        let result = MixReplayPlanner.reconcile(entry.plan, currentOutgoingGrid: entry.plan.outgoingBeatGrid, currentIncomingGrid: entry.plan.incomingBeatGrid)
        XCTAssertFalse(result.resnapped)
        XCTAssertNil(result.notice)
        XCTAssertEqual(result.plan, entry.plan)
        XCTAssertEqual(result.startSeconds, entry.plan.mixPointSeconds - 8 * entry.plan.barSeconds, accuracy: 1e-9)
    }

    func testSavingNamesAndSyncsTheLibrary() {
        var persisted: [SavedMixLibrary] = []
        let store = makeStore(persisted: { persisted.append($0) })
        let entry = record(fixture[0], into: store, at: Date())
        let mix = store.save(entry)
        XCTAssertEqual(mix.name, "\(entry.outgoing.title) → \(entry.incoming.title)")
        store.rename(mix: mix.id, to: "  Opener  ")
        XCTAssertEqual(store.library.mixes.first?.name, "Opener")
        store.save(session: store.sessions[0], name: "")
        XCTAssertEqual(store.library.sets.first?.name, store.sessions[0].defaultName)
        XCTAssertEqual(persisted.last, store.library)
        XCTAssertTrue(store.isSaved(entry))
    }

    func testSetLayoutPlacesBlendsAsOverlaps() {
        let session = MixHistorySession(id: UUID(), entries: fixture)
        let layout = MixSetLayout(session: session)
        XCTAssertEqual(layout.segments.count, 6)
        XCTAssertEqual(layout.blends.count, 5)
        XCTAssertEqual(layout.segments[0].setStart, 0)
        for blend in layout.blends {
            let outgoing = layout.segments[blend.index]
            let incoming = layout.segments[blend.index + 1]
            XCTAssertEqual(incoming.setStart, blend.setStart, accuracy: 1e-9)
            XCTAssertEqual(outgoing.setEnd, blend.setEnd, accuracy: 1e-6)
        }
        XCTAssertEqual(layout.markers.count, 2)
        XCTAssertEqual(MixSetLayout.timestamp(342), "5:42")
        XCTAssertEqual(MixSetLayout.timestamp(3_725), "1:02:05")
    }
}
#endif
