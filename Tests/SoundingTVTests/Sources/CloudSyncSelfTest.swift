import Foundation
import CloudKit
@testable import SoundingTV

#if DEBUG

enum CloudSyncSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[CloudSyncTest] \(status)"] + lines.map { "[CloudSyncTest]   \($0)" }
                + failures.map { "[CloudSyncTest]   ✗ \($0)" }).joined(separator: "\n")
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

    static func run() -> Report {
        var report = Report()
        testZonesAreAllPrivate(&report)
        testCueRoundTrip(&report)
        testDismissalRoundTrip(&report)
        testAnalysisRowRoundTrip(&report)
        testDownloadManifestRoundTrip(&report)
        testSessionFieldsAreEncryptedNotPlain(&report)
        testSessionRoundTrip(&report)
        testSessionUpdateReusesFetchedRecord(&report)
        testAnalysisRecordHasNoUnexpectedFields(&report)
        testMissingEntitlementDegradesToSkipNotCrash(&report)
        return report
    }

    private static func testZonesAreAllPrivate(_ report: inout Report) {
        report.expect(
            "every zone is scoped to the current user (private database), none shared or public",
            CloudSyncZone.all.allSatisfy { $0.ownerName == CKCurrentUserDefaultName }
        )
        report.expect(
            "the zones are all distinct — no domain's records can collide with another's",
            Set(CloudSyncZone.all).count == CloudSyncZone.all.count
        )
    }

    private static func testCueRoundTrip(_ report: inout Report) {
        let cue = CuePoint(
            id: "t#hot#0", trackId: "t", kind: .hotCue, positionMillis: 12_345, hotCueIndex: 2,
            label: "Drop", createdAtMillis: 100, updatedAtMillis: 200, isDeleted: false,
            promotedFrom: CueSuggesterIdentity(name: "sounding.envelope", version: 3), writerId: "device-a"
        )
        let original = CueSyncRecord(cue)
        let record = CloudSyncMapping.record(for: original)
        report.expect("a cue record lands in the Cues zone under its own id", record.recordID.recordName == original.cueId && record.recordID.zoneID == CloudSyncZone.cues)
        let decoded = CloudSyncMapping.cue(from: record)
        report.expect("a cue round-trips through CKRecord unchanged", decoded == original, String(describing: decoded))
    }

    private static func testDismissalRoundTrip(_ report: inout Report) {
        let suggestion = CueSuggestion(
            trackId: "t", kind: .memory, positionMillis: 90_000, endMillis: nil,
            suggester: CueSuggesterIdentity(name: "sounding.envelope", version: 1),
            confidence: 0.5, reasoning: "synthetic", snappedToGrid: false, label: "", color: .memory
        )
        let original = CueDismissal(suggestion: suggestion, writerId: "device-a", now: 500)
        let record = CloudSyncMapping.record(for: original)
        let decoded = CloudSyncMapping.dismissal(from: record)
        report.expect("a dismissal round-trips through CKRecord unchanged", decoded == original, String(describing: decoded))
    }

    private static func testAnalysisRowRoundTrip(_ report: inout Report) {
        let plain = Data(#"{"bpm":174.03,"beats":[0,0.345,0.69]}"#.utf8)
        let (bytes, encoding) = AnalysisPayloadCodec.encode(plain)
        let original = AnalysisSyncRecord(
            cacheKey: "t1#sounding.fftAudioAnalyzer#1#1#180000#aac_256k#256#aac",
            trackId: "t1", engineName: "sounding.fftAudioAnalyzer", engineVersion: 1, schemaVersion: 1,
            durationMillis: 180_000, preset: "aac_256k", bitrate: 256, codec: "aac",
            payload: bytes, payloadEncoding: encoding, uncompressedByteSize: plain.count,
            payloadDigest: AnalysisPayloadCodec.digest(ofUncompressed: plain),
            bpm: 174.03, keyWheelPosition: 8, keyMode: 1, genre: "house",
            producedAtMillis: 42, producerId: "device-a"
        )
        let record = CloudSyncMapping.record(for: original)
        report.expect("an analysis row lands in the Analysis zone under its cacheKey", record.recordID.recordName == original.cacheKey && record.recordID.zoneID == CloudSyncZone.analysis)
        let decoded = CloudSyncMapping.analysisRecord(from: record)
        report.expect(
            "an analysis row round-trips through CKRecord unchanged, including the byte-exact payload",
            decoded == original, String(describing: decoded)
        )
        report.expect(
            "the round-tripped record still validates under AnalysisSyncPolicy",
            decoded.map { AnalysisSyncPolicy.validate($0) == nil } ?? false
        )
    }

    private static func testDownloadManifestRoundTrip(_ report: inout Report) {
        let original = DownloadManifestSyncRecord(
            trackId: "t1", deviceId: "device-a", deviceLabel: "Alex's Apple TV",
            isPinned: true, addedAtMillis: 1_000, updatedAtMillis: 1_000, isDeleted: false
        )
        let record = CloudSyncMapping.record(for: original)
        report.expect("a download-manifest record lands in the DownloadManifests zone under deviceId#trackId", record.recordID.recordName == "device-a#t1" && record.recordID.zoneID == CloudSyncZone.downloadManifests)
        let decoded = CloudSyncMapping.downloadManifestRecord(from: record)
        report.expect("a download-manifest row round-trips through CKRecord unchanged", decoded == original, String(describing: decoded))
    }

    private static func testSessionFieldsAreEncryptedNotPlain(_ report: inout Report) {
        let session = SyncedSoundCloudSession(
            oauthToken: "secret-access-token", refreshToken: "secret-refresh-token",
            clientId: "client-id", expiresAtMillis: 9_999_999_999, updatedAtMillis: 500, writerId: "device-a"
        )
        let record = CloudSyncMapping.record(for: session)

        report.expect(
            "the encrypted store holds exactly the three secret fields, nothing else",
            Set(record.encryptedValues.allKeys()) == ["oauthToken", "refreshToken", "clientId"],
            "encrypted keys = \(record.encryptedValues.allKeys().sorted())"
        )
        let plainValuedKeys = Set(record.allKeys().filter { record[$0] != nil })
        report.expect(
            "the keys with a plain-storage value are exactly the non-secret provenance columns",
            plainValuedKeys == ["expiresAtMillis", "updatedAtMillis", "writerId"],
            "plain-valued keys = \(plainValuedKeys.sorted())"
        )
        report.expect(
            "the secret fields are readable back only through encryptedValues",
            record.encryptedValues["oauthToken"] as? String == session.oauthToken
                && record.encryptedValues["refreshToken"] as? String == session.refreshToken
                && record.encryptedValues["clientId"] as? String == session.clientId
        )
        report.expect("the plain subscript does not expose the encrypted field either", record["oauthToken"] == nil)
    }

    private static func testSessionRoundTrip(_ report: inout Report) {
        let original = SyncedSoundCloudSession(
            oauthToken: "tok", refreshToken: "refresh", clientId: "client",
            expiresAtMillis: 123_456, updatedAtMillis: 789, writerId: "device-a"
        )
        let record = CloudSyncMapping.record(for: original)
        report.expect("the session record always uses the same fixed record name/zone", record.recordID == CloudSyncMapping.sessionRecordID)
        let decoded = CloudSyncMapping.session(from: record)
        report.expect("a session round-trips through CKRecord unchanged", decoded == original, String(describing: decoded))

        let noRefresh = SyncedSoundCloudSession(
            oauthToken: "tok2", refreshToken: nil, clientId: nil,
            expiresAtMillis: nil, updatedAtMillis: 1, writerId: "device-a"
        )
        let decodedNoRefresh = CloudSyncMapping.session(from: CloudSyncMapping.record(for: noRefresh))
        report.expect("a session with no refresh material round-trips too", decodedNoRefresh == noRefresh)
    }

    private static func testSessionUpdateReusesFetchedRecord(_ report: inout Report) {
        let fetched = CKRecord(
            recordType: CloudSyncRecordType.session,
            recordID: CloudSyncMapping.sessionRecordID
        )
        let replacement = SyncedSoundCloudSession(
            oauthToken: "rotated", refreshToken: "refresh", clientId: "client",
            expiresAtMillis: 999, updatedAtMillis: 500, writerId: "device-b"
        )
        let updated = CloudSyncMapping.record(for: replacement, updating: fetched)
        report.expect(
            "updating a cloud session mutates the fetched CKRecord so its server metadata survives",
            updated === fetched && CloudSyncMapping.session(from: updated) == replacement
        )
    }

    private static func testAnalysisRecordHasNoUnexpectedFields(_ report: inout Report) {
        let original = AnalysisSyncRecord(
            cacheKey: "k", trackId: "t", engineName: "e", engineVersion: 1, schemaVersion: 1,
            durationMillis: 1, preset: "p", bitrate: 1, codec: "c",
            payload: Data("{}".utf8), payloadEncoding: .raw, uncompressedByteSize: 2,
            payloadDigest: "d", bpm: nil, keyWheelPosition: nil, keyMode: nil, genre: nil,
            producedAtMillis: 1, producerId: "p"
        )
        let expected: Set<String> = [
            "trackId", "engineName", "engineVersion", "schemaVersion", "durationMillis", "preset",
            "bitrate", "codec", "payload", "payloadEncoding", "uncompressedByteSize", "payloadDigest",
            "producedAtMillis", "producerId",
        ]
        let record = CloudSyncMapping.record(for: original)
        let keys = Set(record.allKeys())
        report.expect(
            "an analysis record with no recall features set carries exactly the expected fields, no more",
            keys == expected, "keys = \(keys.sorted())"
        )
    }

    private static func testMissingEntitlementDegradesToSkipNotCrash(_ report: inout Report) {
        let bogusIdentifier = "iCloud.red.forbes.sounding.selftest.\(UUID().uuidString)"
        report.expect(
            "a made-up container identifier is (as expected) absent from this process's entitlements",
            !CloudSyncEngineController.containerIdentifierIsEntitled(bogusIdentifier)
        )

        let controller = CloudSyncEngineController(containerIdentifier: bogusIdentifier)
        controller.start()
        report.expect(
            "start() against an unentitled identifier returns instead of trapping in CKContainer(identifier:)",
            true
        )
    }
}
#endif
