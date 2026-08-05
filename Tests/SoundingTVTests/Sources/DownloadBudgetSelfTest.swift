import Foundation
@testable import SoundingTV

#if DEBUG
enum DownloadBudgetSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[DownloadBudgetTest] \(status)"] + lines.map { "[DownloadBudgetTest]   \($0)" }
                + failures.map { "[DownloadBudgetTest]   ✗ \($0)" }).joined(separator: "\n")
        }
    }

    static func run() -> Report {
        var report = Report()
        let now = Date()

        func expect(_ name: String, _ entries: [DownloadBudgetPolicy.Entry], maxBytes: Int64, evicts expected: [String]) {
            let got = DownloadBudgetPolicy.victims(entries: entries, maxBytes: maxBytes)
            if got == expected {
                report.lines.append("\(name) → evicts \(expected)")
            } else {
                report.failures.append("\(name): expected \(expected), got \(got)")
            }
        }

        expect("under budget, nothing evicted", [
            .init(id: "a", bytes: 100, lastPlayedAt: now, isPinned: false)
        ], maxBytes: 1_000, evicts: [])

        expect("over budget, least-recently-played goes first", [
            .init(id: "old", bytes: 400, lastPlayedAt: now.addingTimeInterval(-3600), isPinned: false),
            .init(id: "new", bytes: 400, lastPlayedAt: now, isPinned: false)
        ], maxBytes: 500, evicts: ["old"])

        expect("pinned survives even when oldest", [
            .init(id: "pinned-old", bytes: 400, lastPlayedAt: now.addingTimeInterval(-7200), isPinned: true),
            .init(id: "predictive-new", bytes: 400, lastPlayedAt: now, isPinned: false)
        ], maxBytes: 500, evicts: ["predictive-new"])

        expect("all pinned and over budget: nothing evictable, budget stays exceeded", [
            .init(id: "a", bytes: 400, lastPlayedAt: now.addingTimeInterval(-7200), isPinned: true),
            .init(id: "b", bytes: 400, lastPlayedAt: now, isPinned: true)
        ], maxBytes: 100, evicts: [])

        expect("evicts multiple, stops as soon as it's under budget", [
            .init(id: "a", bytes: 300, lastPlayedAt: now.addingTimeInterval(-300), isPinned: false),
            .init(id: "b", bytes: 300, lastPlayedAt: now.addingTimeInterval(-200), isPinned: false),
            .init(id: "c", bytes: 300, lastPlayedAt: now.addingTimeInterval(-100), isPinned: false)
        ], maxBytes: 500, evicts: ["a", "b"])

        return report
    }
}
#endif
