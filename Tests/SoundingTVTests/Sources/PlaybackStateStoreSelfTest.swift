import Foundation
@testable import SoundingTV

#if DEBUG

enum PlaybackStateStoreSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            (lines + failures.map { "FAIL: \($0)" }).joined(separator: "\n")
        }
    }

    static func run() -> Report {
        var report = Report()

        let snapshot = PlaybackStateStore.Snapshot(
            trackIds: ["101", "202", "303"],
            currentIndex: 1,
            positionSeconds: 42.5,
            isShuffleEnabled: true,
            repeatMode: .all,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard let data = try? JSONEncoder().encode(snapshot) else {
            report.failures.append("snapshot failed to encode")
            return report
        }
        report.lines.append("encoded snapshot (\(data.count) bytes)")

        guard let decoded = try? JSONDecoder().decode(PlaybackStateStore.Snapshot.self, from: data) else {
            report.failures.append("snapshot failed to decode")
            return report
        }

        if decoded == snapshot {
            report.lines.append("round-trip preserved all fields")
        } else {
            report.failures.append("round-trip produced a different snapshot: \(decoded)")
        }

        return report
    }
}
#endif
