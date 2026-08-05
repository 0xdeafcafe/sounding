import Foundation
@testable import SoundingTV

#if DEBUG

enum DownloadManifestSyncSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[DownloadManifestSyncTest] \(status)"] + lines.map { "[DownloadManifestSyncTest]   \($0)" }
                + failures.map { "[DownloadManifestSyncTest]   ✗ \($0)" }).joined(separator: "\n")
        }

        mutating func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                lines.append(name)
            } else {
                let suffix = detail()
                failures.append(suffix.isEmpty ? name : "\(name): \(suffix)")
            }
        }
    }

    private static func record(
        trackId: String, deviceId: String = "device-a", deviceLabel: String = "Apple TV",
        isPinned: Bool = false, addedAtMillis: Int64 = 1_000, isDeleted: Bool = false
    ) -> DownloadManifestSyncRecord {
        DownloadManifestSyncRecord(
            trackId: trackId, deviceId: deviceId, deviceLabel: deviceLabel, isPinned: isPinned,
            addedAtMillis: addedAtMillis, updatedAtMillis: addedAtMillis, isDeleted: isDeleted
        )
    }

    struct MemoryExportSource: DownloadManifestExportSource {
        let manifest: [DownloadManifestSyncRecord]
        func currentManifest(limit: Int) async -> [DownloadManifestSyncRecord] { Array(manifest.prefix(limit)) }
    }

    struct MemoryTransport: DownloadManifestSyncTransport {
        let transportId = "memory"
        let ready: Bool
        let inbound: [DownloadManifestSyncRecord]
        let offered: OfferSink

        actor OfferSink {
            private(set) var records: [DownloadManifestSyncRecord] = []
            func record(_ new: [DownloadManifestSyncRecord]) { records.append(contentsOf: new) }
        }

        init(ready: Bool = true, inbound: [DownloadManifestSyncRecord] = [], offered: OfferSink = OfferSink()) {
            self.ready = ready
            self.inbound = inbound
            self.offered = offered
        }

        func isReady() async -> Bool { ready }
        func offer(_ records: [DownloadManifestSyncRecord]) async throws { await offered.record(records) }
        func fetch(since cursor: DownloadManifestSyncCursor?) async throws -> (records: [DownloadManifestSyncRecord], cursor: DownloadManifestSyncCursor?) {
            (inbound, DownloadManifestSyncCursor(bytes: Data("1".utf8)))
        }
    }

    static func run() async -> Report {
        var report = Report()
        testValidation(&report)
        testRemoteWins(&report)
        await testStorePersistsAcrossInstances(&report)
        await testStoreExcludesOwnDeviceAndTombstones(&report)
        await testRelayRoundTrip(&report)
        return report
    }

    private static func testValidation(_ report: inout Report) {
        report.expect("a well-formed record validates", DownloadManifestSyncPolicy.validate(record(trackId: "1")) == nil)
        report.expect(
            "a blank device id is refused",
            DownloadManifestSyncPolicy.validate(record(trackId: "1", deviceId: "")) == .malformedIdentity
        )
        report.expect(
            "a device label carrying a stream host is refused",
            DownloadManifestSyncPolicy.validate(record(trackId: "1", deviceLabel: "https://sndcdn.com/x")) == .labelCarriesLocator
        )
    }

    private static func testRemoteWins(_ report: inout Report) {
        report.expect("no local copy → adopt", DownloadManifestSyncPolicy.remoteWins(local: nil, remote: record(trackId: "1")))
        let same = record(trackId: "1")
        report.expect("identical content is a no-op", !DownloadManifestSyncPolicy.remoteWins(local: same, remote: same))
        let older = record(trackId: "1", isPinned: false, addedAtMillis: 100)
        let newer = record(trackId: "1", isPinned: true, addedAtMillis: 200)
        report.expect("a genuinely newer row wins", DownloadManifestSyncPolicy.remoteWins(local: older, remote: newer))
        report.expect("a stale row does not win", !DownloadManifestSyncPolicy.remoteWins(local: newer, remote: older))
    }

    private static func testStorePersistsAcrossInstances(_ report: inout Report) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadManifestSelfTest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RemoteDownloadManifestStore(fileURL: dir)
        let adopted = await store.adopt([record(trackId: "1"), record(trackId: "2", isPinned: true)])
        let reopened = RemoteDownloadManifestStore(fileURL: dir)
        let manifests = await reopened.manifestsByDevice(excluding: "nobody")
        report.expect(
            "adopted rows persist across a fresh store instance on the same file",
            adopted == 2 && manifests["device-a"]?.count == 2,
            "adopted=\(adopted), rows=\(manifests["device-a"]?.count ?? -1)"
        )
    }

    private static func testStoreExcludesOwnDeviceAndTombstones(_ report: inout Report) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadManifestSelfTest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RemoteDownloadManifestStore(fileURL: dir)
        _ = await store.adopt([
            record(trackId: "1", deviceId: "device-a"),
            record(trackId: "2", deviceId: "device-b"),
            record(trackId: "3", deviceId: "device-b", isDeleted: true),
        ])
        let manifests = await store.manifestsByDevice(excluding: "device-a")
        report.expect(
            "the local device's own rows are excluded and a tombstone doesn't show as downloaded",
            manifests["device-a"] == nil && manifests["device-b"]?.count == 1,
            "keys=\(manifests.keys.sorted())"
        )
    }

    private static func testRelayRoundTrip(_ report: inout Report) async {
        let exportSource = MemoryExportSource(manifest: [record(trackId: "mine", deviceId: "device-a")])
        let importStore = RemoteDownloadManifestStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("DownloadManifestSelfTest-\(UUID().uuidString).json"))
        let sink = MemoryTransport.OfferSink()
        let transport = MemoryTransport(inbound: [record(trackId: "theirs", deviceId: "device-b")], offered: sink)
        let relay = DownloadManifestSyncRelay(exportSource: exportSource, importStore: importStore, transport: transport)

        do {
            let result = try await relay.runOnce(since: nil)
            let adoptedTheirs = await importStore.manifestsByDevice(excluding: "device-a")["device-b"]?.count == 1
            let offeredIds = await sink.records.map(\.trackId)
            report.expect(
                "relay adopts a peer's manifest row and offers this device's own",
                result.adopted == 1 && adoptedTheirs && offeredIds == ["mine"],
                "adopted=\(result.adopted), hasTheirs=\(adoptedTheirs), offered=\(offeredIds)"
            )
        } catch {
            report.failures.append("relay round trip threw: \(error)")
        }
    }

}
#endif
