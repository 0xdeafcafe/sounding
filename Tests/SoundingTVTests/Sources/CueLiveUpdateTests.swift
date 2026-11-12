import Combine
import XCTest
@testable import SoundingTV

@MainActor
final class CueLiveUpdateTests: XCTestCase {
    private let trackId = "live-track"

    private func makeStore(writer: String = "this-mac") -> CueStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CueLiveUpdateTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CueStore(directory: directory, writerId: writer)
    }

    private func waitUntil(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func openBoard(_ store: CueStore, debounce: Duration = .milliseconds(20)) async -> CueBoard {
        let board = CueBoard(store: store, debounce: debounce)
        board.ensureLoaded(trackId: trackId, duration: 240, waveform: nil)
        _ = await waitUntil { board.sheet.trackId == trackId }
        return board
    }

    private func openModel(_ store: CueStore, debounce: Duration = .milliseconds(20)) async -> TrackMapModel {
        let model = TrackMapModel(board: CueBoard(store: store, debounce: debounce))
        model.load(trackId: trackId, title: "Live", duration: 240, envelope: [])
        _ = await waitUntil { model.board.sheet.trackId == trackId }
        return model
    }

    // MARK: Store change reloads an open board

    func testStoreWriteReloadsAnOpenBoard() async {
        let store = makeStore()
        let board = await openBoard(store)

        await store.addMemoryCue(trackId: trackId, positionMillis: 30_000, label: "Written elsewhere")

        let arrived = await waitUntil { board.sheet.userCues.contains { $0.label == "Written elsewhere" } }
        XCTAssertTrue(arrived, "a write straight to the store reaches an open board without ensureLoaded")
        XCTAssertGreaterThanOrEqual(board.storeReloadCount, 1)
    }

    func testDeleteAndMixPointWritesReachAnOpenBoard() async {
        let store = makeStore()
        let board = await openBoard(store)
        let cue = await store.setHotCue(trackId: trackId, index: 3, positionMillis: 60_000, label: "Drop")
        _ = await waitUntil { board.sheet.hotCue(at: 3) != nil }

        await store.setMixOut(trackId: trackId, positionMillis: 200_000)
        await store.delete(cueId: cue.id)

        let settled = await waitUntil { board.sheet.hotCue(at: 3) == nil && board.sheet.mixOut?.userCue != nil }
        XCTAssertTrue(settled, "a delete and an Auto Mix mix point written to the store both show on the open board")
    }

    func testWritesToAnotherTrackLeaveTheBoardAlone() async {
        let store = makeStore()
        let board = await openBoard(store)

        await store.addMemoryCue(trackId: "some-other-track", positionMillis: 10_000)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(board.storeReloadCount, 0)
        XCTAssertTrue(board.sheet.userCues.isEmpty)
    }

    func testTwoBoardsOnOneStoreMirrorEachOther() async {
        let store = makeStore()
        let prep = await openBoard(store)
        let nowPlaying = await openBoard(store)

        let placed = await prep.setHotCue(trackId: trackId, index: 0, positionMillis: 45_000, label: "From Prep")
        let mirrored = await waitUntil { nowPlaying.sheet.userCues.contains { $0.id == placed.id } }
        XCTAssertTrue(mirrored, "a cue saved in Prep shows in Now Playing")

        await nowPlaying.delete(placed)
        let removed = await waitUntil { prep.sheet.userCues.isEmpty }
        XCTAssertTrue(removed, "a delete in Now Playing shows in Prep")
    }

    func testDismissalAndUndismissReachAnOpenBoard() async throws {
        let store = makeStore()
        let first = await openBoard(store)
        let second = await openBoard(store)
        let envelope = (0..<600).map { Float(abs(sin(Double($0) / 40))) }
        first.ensureLoaded(trackId: trackId, duration: 240, waveform: Waveform(samples: envelope))
        second.ensureLoaded(trackId: trackId, duration: 240, waveform: Waveform(samples: envelope))
        _ = await waitUntil { !first.sheet.suggestions.isEmpty && first.sheet.suggestions == second.sheet.suggestions }
        guard let suggestion = first.sheet.suggestions.first else {
            throw XCTSkip("this envelope gave no suggestions to dismiss")
        }

        await first.dismiss(suggestion)
        let hidden = await waitUntil { !second.sheet.suggestions.contains { $0.id == suggestion.id } }
        XCTAssertTrue(hidden, "a dismissal on one screen hides the suggestion on the other")

        await store.undismiss(suggestionId: suggestion.id)
        let back = await waitUntil { second.sheet.suggestions.contains { $0.id == suggestion.id } }
        XCTAssertTrue(back, "undoing a dismissal brings the suggestion back on the other screen")
    }

    // MARK: Sync-applied changes

    func testSyncAppliedCueReachesAnOpenBoard() async throws {
        let store = makeStore(writer: "this-mac")
        let board = await openBoard(store)
        let remote = CuePoint(
            trackId: trackId,
            kind: .hotCue,
            positionMillis: 12_000,
            hotCueIndex: 2,
            label: "From iPad",
            createdAtMillis: 1,
            updatedAtMillis: CueTime.nowMillis() + 1_000,
            writerId: "the-ipad"
        )
        let relay = CueSyncRelay(store: store, transport: StubCueTransport(cues: [CueSyncRecord(remote)], dismissals: []))

        let result = try await relay.runOnce(since: nil)
        XCTAssertEqual(result.adoptedCues, 1)

        let arrived = await waitUntil { board.sheet.userCues.contains { $0.label == "From iPad" && $0.hotCueIndex == 2 } }
        XCTAssertTrue(arrived, "a cue adopted from iCloud shows on the open board")
    }

    func testSyncAppliedRemoteDeleteReachesAnOpenBoard() async {
        let store = makeStore(writer: "this-mac")
        let board = await openBoard(store)
        let local = await store.addMemoryCue(trackId: trackId, positionMillis: 20_000, label: "Soon gone")
        _ = await waitUntil { board.sheet.userCues.count == 1 }

        var tombstone = local
        tombstone.isDeleted = true
        tombstone.updatedAtMillis = local.updatedAtMillis + 1_000
        tombstone.writerId = "the-iphone"
        await store.adopt([CueSyncRecord(tombstone)])

        let removed = await waitUntil { board.sheet.userCues.isEmpty }
        XCTAssertTrue(removed, "a delete adopted from iCloud clears the cue on the open board")
    }

    func testSyncAppliedPrepReachesAnOpenTrackMap() async {
        let store = makeStore(writer: "this-mac")
        let model = await openModel(store)
        let stored = Counter()
        model.onStoreChange = { stored.value += 1 }

        var incoming = TrackPrep(trackId: trackId)
        incoming.comment = PrepField("Checked on the iPad", source: .user, updatedAtMillis: CueTime.nowMillis(), writerId: "the-ipad")
        guard let record = PrepSyncRecord.prep(incoming) else { return XCTFail("prep record") }
        await store.adoptPrep([record])

        let arrived = await waitUntil { model.prep?.comment?.value == "Checked on the iPad" }
        XCTAssertTrue(arrived, "prep adopted from iCloud reaches the open track map")
        XCTAssertGreaterThanOrEqual(stored.value, 1)
    }

    func testBulkAdoptAnnouncesOnce() async {
        let store = makeStore(writer: "this-mac")
        let changes = store.changes.subscribe()
        let now = CueTime.nowMillis() + 1_000
        let records = (0..<50).map { index in
            CueSyncRecord(CuePoint(trackId: index.isMultiple(of: 2) ? trackId : "other", kind: .memory, positionMillis: Int64(index) * 1_000, createdAtMillis: 1, updatedAtMillis: now, writerId: "the-ipad"))
        }

        await store.adopt(records)

        var iterator = changes.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, Set([trackId, "other"]), "a sync batch is announced as one change naming every track it touched")
    }

    // MARK: Own writes don't loop

    func testOwnWritesDoNotLoop() async {
        let store = makeStore()
        let board = await openBoard(store, debounce: .milliseconds(30))
        var publishes = 0
        let watcher = board.$sheet.dropFirst().sink { _ in publishes += 1 }
        defer { watcher.cancel() }

        await board.addMemoryCue(trackId: trackId, positionMillis: 15_000, label: "Mine")
        try? await Task.sleep(for: .milliseconds(300))
        let settledPublishes = publishes
        let settledReloads = board.storeReloadCount

        XCTAssertEqual(settledPublishes, 1, "the board publishes its own write once; the store's echo finds nothing new")
        XCTAssertLessThanOrEqual(settledReloads, 1, "one write is one echo at most")

        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(publishes, settledPublishes, "nothing keeps reloading after the write settles")
        XCTAssertEqual(board.storeReloadCount, settledReloads)
    }

    func testTrackMapOwnEditDoesNotReportAStoreChange() async {
        let store = makeStore()
        let model = await openModel(store, debounce: .milliseconds(100))
        let edits = Counter()
        let external = Counter()
        model.onEdit = { edits.value += 1 }
        model.onStoreChange = { external.value += 1 }
        model.livePosition = { 30 }

        model.saveCue()
        _ = await waitUntil { edits.value == 1 }
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(edits.value, 1)
        XCTAssertEqual(external.value, 0, "the store's echo of this model's own write changes nothing, so Prep isn't refreshed twice")
        XCTAssertEqual(model.userCues.count, 1)
    }

    // MARK: Two track maps on one track

    func testTrackMapsMirrorEditsAndKeepSelection() async {
        let store = makeStore()
        let prep = await openModel(store)
        let nowPlaying = await openModel(store)
        prep.livePosition = { 60 }

        prep.setHotCue(slot: 1)
        let mirrored = await waitUntil { nowPlaying.userCues.count == 1 }
        XCTAssertTrue(mirrored)
        guard let cue = nowPlaying.userCues.first else { return }
        nowPlaying.selectedCueId = cue.id

        prep.recolour(cue, to: CueColor.hotCuePalette[4])
        prep.rename(cue, to: "Build")
        let updated = await waitUntil { nowPlaying.cue(cue.id)?.label == "Build" && nowPlaying.cue(cue.id)?.color == CueColor.hotCuePalette[4] }
        XCTAssertTrue(updated, "rename and colour in Prep show in Now Playing")
        XCTAssertEqual(nowPlaying.selectedCueId, cue.id, "a live reload keeps the other screen's selection")
    }

    func testEditorClosesWhenItsCueIsDeletedElsewhere() async {
        let store = makeStore()
        let prep = await openModel(store)
        let nowPlaying = await openModel(store)
        prep.livePosition = { 90 }

        prep.saveCue()
        _ = await waitUntil { nowPlaying.userCues.count == 1 }
        guard let cue = nowPlaying.userCues.first else { return XCTFail("cue") }
        nowPlaying.editingCueId = cue.id

        prep.delete(cue)
        let closed = await waitUntil { nowPlaying.editingCueId == nil }
        XCTAssertTrue(closed, "an editor for a cue deleted on another screen closes instead of showing nothing")
    }

    func testUndoWorksWithoutAWindowUndoManager() async {
        let store = makeStore()
        let model = await openModel(store)
        model.livePosition = { 120 }

        model.saveCue()
        _ = await waitUntil { model.userCues.count == 1 && model.canUndo }
        XCTAssertTrue(model.canUndo, "Apple TV has no window undo manager, so the model keeps its own")

        model.undoLast()
        let undone = await waitUntil { model.userCues.isEmpty }
        XCTAssertTrue(undone)
    }

    func testReleasedBoardStopsListening() async {
        let store = makeStore()
        var board: CueBoard? = await openBoard(store)
        XCTAssertEqual(store.changes.subscriberCount, 1)
        XCTAssertNotNil(board)

        board = nil
        let released = await waitUntil { store.changes.subscriberCount == 0 }
        XCTAssertTrue(released, "a closed screen drops its subscription")
    }
}

@MainActor
private final class Counter {
    var value = 0
}

private struct StubCueTransport: CueSyncTransport {
    let cues: [CueSyncRecord]
    let dismissals: [CueDismissal]

    var transportId: String { "stub" }

    func isReady() async -> Bool { true }

    func offer(cues: [CueSyncRecord], dismissals: [CueDismissal]) async throws {}

    func fetch(since cursor: CueSyncCursor?) async throws -> (cues: [CueSyncRecord], dismissals: [CueDismissal], cursor: CueSyncCursor?) {
        (cues, dismissals, nil)
    }
}
