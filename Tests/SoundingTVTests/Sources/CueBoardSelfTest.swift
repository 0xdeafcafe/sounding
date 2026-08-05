import Foundation
@testable import SoundingTV

#if DEBUG

@MainActor
enum CueBoardSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[CueBoardTest] \(status)"] + lines.map { "[CueBoardTest]   \($0)" }
                + failures.map { "[CueBoardTest]   ✗ \($0)" }).joined(separator: "\n")
        }

        mutating func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() { lines.append("\(name) → ok") } else { failures.append(name) }
        }
    }

    static func run() async -> Report {
        var report = Report()
        await testLoadReflectsWrites(&report)
        await testRedundantLoadIsANoOp(&report)
        await testReloadIsInertBeforeFirstLoad(&report)
        testNavigationWraps(&report)
        testNavigationHandlesEmptyAndSingleton(&report)
        return report
    }

    private static func scratchBoard() -> (CueBoard, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CueBoardSelfTest-\(UUID().uuidString)", isDirectory: true)
        return (CueBoard(store: CueStore(directory: dir)), dir)
    }

    private static func testLoadReflectsWrites(_ report: inout Report) async {
        let (board, dir) = scratchBoard()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trackId = "t"

        board.ensureLoaded(trackId: trackId, duration: 240, waveform: nil)
        try? await Task.sleep(for: .milliseconds(50))
        report.expect("a track with no cues loads to an empty sheet", board.sheet.userCues.isEmpty)

        let placed = await board.addMemoryCue(trackId: trackId, positionMillis: 45_000, label: "Test drop")
        report.expect(
            "adding a cue is reflected in `sheet` without a second `ensureLoaded` call",
            board.sheet.userCues.contains { $0.id == placed.id && $0.label == "Test drop" }
        )

        await board.rename(placed, to: "Renamed")
        report.expect(
            "a rename lands in `sheet` and does not create a second row",
            board.sheet.userCues.count == 1 && board.sheet.userCues.first?.label == "Renamed"
        )

        await board.reposition(placed, toMillis: 90_000)
        report.expect(
            "a reposition moves the same cue rather than duplicating it",
            board.sheet.userCues.count == 1 && board.sheet.userCues.first?.positionMillis == 90_000
        )

        await board.delete(placed)
        report.expect("a delete removes the cue from `sheet`", board.sheet.userCues.isEmpty)
    }

    private static func testRedundantLoadIsANoOp(_ report: inout Report) async {
        let (board, dir) = scratchBoard()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trackId = "t"

        board.ensureLoaded(trackId: trackId, duration: 200, waveform: nil)
        try? await Task.sleep(for: .milliseconds(50))

        _ = await board.addMemoryCue(trackId: trackId, positionMillis: 10_000)
        let sheetAfterWrite = board.sheet

        board.ensureLoaded(trackId: trackId, duration: 200, waveform: nil)
        report.expect(
            "an identical `ensureLoaded` call after a write does not clobber the freshly-reloaded sheet",
            board.sheet == sheetAfterWrite
        )
    }

    private static func testReloadIsInertBeforeFirstLoad(_ report: inout Report) async {
        let (board, dir) = scratchBoard()
        defer { try? FileManager.default.removeItem(at: dir) }

        let placed = await board.addMemoryCue(trackId: "t", positionMillis: 5_000)
        report.expect(
            "a write before any `ensureLoaded` call still succeeds against the store",
            placed.positionMillis == 5_000
        )
        report.expect("…but `sheet` stays the untouched empty baseline, since nothing was ever loaded", board.sheet.trackId.isEmpty)
    }

    private static func testNavigationWraps(_ report: inout Report) {
        let positions: [TimeInterval] = [10, 90, 45]
        report.expect("next finds the closest cue strictly ahead", CueNavigation.next(after: 10, positions: positions) == 45)
        report.expect("next wraps to the first cue once past the last", CueNavigation.next(after: 90, positions: positions) == 10)
        report.expect("previous finds the closest cue strictly behind", CueNavigation.previous(before: 90, positions: positions) == 45)
        report.expect("previous wraps to the last cue once before the first", CueNavigation.previous(before: 10, positions: positions) == 90)
        report.expect("next steps off the cue you're standing on rather than stalling", CueNavigation.next(after: 45, positions: positions) == 90)
        report.expect("previous steps off the cue you're standing on rather than stalling", CueNavigation.previous(before: 45, positions: positions) == 10)
    }

    private static func testNavigationHandlesEmptyAndSingleton(_ report: inout Report) {
        report.expect("next on an empty list is nil, not a crash", CueNavigation.next(after: 30, positions: []) == nil)
        report.expect("previous on an empty list is nil, not a crash", CueNavigation.previous(before: 30, positions: []) == nil)
        report.expect("next with one cue returns to that same cue", CueNavigation.next(after: 30, positions: [30]) == 30)
        report.expect("previous with one cue returns to that same cue", CueNavigation.previous(before: 30, positions: [30]) == 30)
    }
}
#endif
