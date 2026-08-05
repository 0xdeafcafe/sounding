import Foundation
@testable import SoundingTV

#if DEBUG

enum SettingsSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[SettingsTest] \(status)"] + lines.map { "[SettingsTest]   \($0)" }
                + failures.map { "[SettingsTest]   ✗ \($0)" }).joined(separator: "\n")
        }
    }

    static func run() -> Report {
        var report = Report()
        remoteWinsCases(&report)
        reconcileCases(&report)
        scenarioCases(&report)
        return report
    }

    private static func rev(_ revision: UInt64, _ millis: Int64, _ writer: String) -> SettingRevision {
        SettingRevision(revision: revision, updatedAtMillis: millis, writerId: writer)
    }

    private static func remoteWinsCases(_ report: inout Report) {
        func expect(_ name: String, local: SettingRevision?, remote: SettingRevision, wins expected: Bool) {
            let got = SettingsMerge.remoteWins(local: local, remote: remote)
            if got == expected {
                report.lines.append("remoteWins: \(name) → \(got)")
            } else {
                report.failures.append("remoteWins: \(name): expected \(expected), got \(got)")
            }
        }

        expect("never synced locally", local: nil, remote: rev(0, 1000, "peer"), wins: true)

        expect("higher revision wins", local: rev(1, 5000, "me"), remote: rev(2, 1000, "peer"), wins: true)
        expect("lower revision loses", local: rev(3, 1000, "me"), remote: rev(2, 9000, "peer"), wins: false)

        expect("equal revision, later timestamp wins", local: rev(1, 1000, "me"), remote: rev(1, 2000, "peer"), wins: true)
        expect("equal revision, earlier timestamp loses", local: rev(1, 5000, "me"), remote: rev(1, 2000, "peer"), wins: false)

        expect("exact tie, higher writerId wins", local: rev(1, 1000, "aaa"), remote: rev(1, 1000, "bbb"), wins: true)
        expect("exact tie, lower writerId loses", local: rev(1, 1000, "bbb"), remote: rev(1, 1000, "aaa"), wins: false)

        expect("identical record is a no-op", local: rev(2, 1000, "me"), remote: rev(2, 1000, "me"), wins: false)
    }

    private static func reconcileCases(_ report: inout Report) {
        let knownIds: Set<String> = ["a", "b"]

        let payload = SettingsSyncPayload(entries: [
            .init(id: "a", valueJSON: Data("1".utf8), revision: 1, updatedAtMillis: 1000, writerId: "peer"),
            .init(id: "zzz-future-setting", valueJSON: Data("1".utf8), revision: 1, updatedAtMillis: 1000, writerId: "peer"),
        ])
        let (winners, outcome) = SettingsMerge.reconcile(
            payload: payload, knownIds: knownIds, deviceLocalIds: [],
            localRevisions: { _ in nil }
        )
        check("unknown id doesn't block a known one", winners.map(\.id) == ["a"] && outcome.unknownIds == ["zzz-future-setting"], &report)

        let (winners2, outcome2) = SettingsMerge.reconcile(
            payload: payload, knownIds: knownIds, deviceLocalIds: ["a"],
            localRevisions: { _ in nil }
        )
        check("device-local override suppresses an otherwise-winning entry", winners2.isEmpty && outcome2.skippedDeviceLocalIds == ["a"], &report)

        let (winners3, outcome3) = SettingsMerge.reconcile(
            payload: payload, knownIds: knownIds, deviceLocalIds: [],
            localRevisions: { id in id == "a" ? rev(5, 9999, "me") : nil }
        )
        check("a losing entry is reported kept, not applied", winners3.map(\.id) == [] && outcome3.keptIds == ["a"], &report)
    }

    private static func scenarioCases(_ report: inout Report) {
        let tvRevisions: [String: SettingRevision] = [
            "djAutoMixEnabled": rev(1, 5000, "tv"),
        ]
        let phonePayload = SettingsSyncPayload(entries: [
            .init(id: "djAutoMixEnabled", valueJSON: encodedBool(true), revision: 1, updatedAtMillis: 1000, writerId: "phone"),
            .init(id: "streamingQualityCeiling", valueJSON: encodedString("efficient"), revision: 1, updatedAtMillis: 3000, writerId: "phone"),
        ])
        let (winners, _) = SettingsMerge.reconcile(
            payload: phonePayload,
            knownIds: ["djAutoMixEnabled", "streamingQualityCeiling"],
            deviceLocalIds: [],
            localRevisions: { tvRevisions[$0] }
        )
        let wonIds = Set(winners.map(\.id))
        check(
            "TV keeps its own newer djAutoMixEnabled edit",
            !wonIds.contains("djAutoMixEnabled"),
            &report
        )
        check(
            "TV still adopts the phone's streamingQualityCeiling edit",
            wonIds.contains("streamingQualityCeiling"),
            &report
        )

        let freshDevicePayload = SettingsSyncPayload(entries: [
            .init(id: "djAutoMixEnabled", valueJSON: encodedBool(false), revision: 4, updatedAtMillis: 8000, writerId: "peer"),
            .init(id: "streamingQualityCeiling", valueJSON: encodedString("maximum"), revision: 2, updatedAtMillis: 8000, writerId: "peer"),
        ])
        let (freshWinners, _) = SettingsMerge.reconcile(
            payload: freshDevicePayload,
            knownIds: ["djAutoMixEnabled", "streamingQualityCeiling"],
            deviceLocalIds: [],
            localRevisions: { _ in nil }
        )
        check(
            "a never-synced device adopts everything offered",
            Set(freshWinners.map(\.id)) == ["djAutoMixEnabled", "streamingQualityCeiling"],
            &report
        )

        let manyEditsLater = rev(3, 50_000, "away")
        check(
            "three edits while offline still beat one stale local edit",
            SettingsMerge.remoteWins(local: rev(1, 10_000, "here"), remote: manyEditsLater),
            &report
        )

        let localAfterFirstMerge: [String: SettingRevision] = [
            "djAutoMixEnabled": rev(1, 1000, "phone"),
            "streamingQualityCeiling": rev(1, 3000, "phone"),
        ]
        let (replayWinners, _) = SettingsMerge.reconcile(
            payload: phonePayload,
            knownIds: ["djAutoMixEnabled", "streamingQualityCeiling"],
            deviceLocalIds: [],
            localRevisions: { localAfterFirstMerge[$0] }
        )
        check("replaying an already-applied payload is a no-op", replayWinners.isEmpty, &report)
    }

    private static func encodedBool(_ value: Bool) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
    private static func encodedString(_ value: String) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }

    private static func check(_ name: String, _ condition: Bool, _ report: inout Report) {
        if condition {
            report.lines.append(name)
        } else {
            report.failures.append(name)
        }
    }
}
#endif
