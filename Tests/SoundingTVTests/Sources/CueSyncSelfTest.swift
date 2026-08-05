import Foundation
@testable import SoundingTV

#if DEBUG

enum CueSyncSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[CueSyncTest] \(status)"] + lines.map { "[CueSyncTest]   \($0)" }
                + failures.map { "[CueSyncTest]   ✗ \($0)" }).joined(separator: "\n")
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

    actor MemoryStore: CueSyncStore {
        private var cues: [String: CueSyncRecord] = [:]
        private var dismissals: [String: CueDismissal] = [:]

        init(cues seedCues: [CueSyncRecord] = [], dismissals seedDismissals: [CueDismissal] = []) {
            for cue in seedCues { cues[cue.cueId] = cue }
            for dismissal in seedDismissals { dismissals[dismissal.id] = dismissal }
        }

        func pendingChanges(since cursorMillis: Int64, limit: Int) async -> (cues: [CueSyncRecord], dismissals: [CueDismissal]) {
            let dueCues = cues.values.filter { $0.updatedAtMillis > cursorMillis }.sorted { $0.updatedAtMillis < $1.updatedAtMillis }
            let dueDismissals = dismissals.values.filter { $0.dismissedAtMillis > cursorMillis }.sorted { $0.dismissedAtMillis < $1.dismissedAtMillis }
            return (Array(dueCues.prefix(limit)), Array(dueDismissals.prefix(limit)))
        }

        @discardableResult
        func adopt(_ records: [CueSyncRecord]) async -> Int {
            var adopted = 0
            for record in records {
                guard CueSyncPolicy.remoteWins(local: cues[record.cueId]?.cuePoint, remote: record) else { continue }
                cues[record.cueId] = record
                adopted += 1
            }
            return adopted
        }

        @discardableResult
        func adoptDismissals(_ records: [CueDismissal]) async -> Int {
            var adopted = 0
            for record in records where dismissals[record.id] == nil {
                dismissals[record.id] = record
                adopted += 1
            }
            return adopted
        }

        var cueCount: Int { cues.count }
        var dismissalCount: Int { dismissals.count }
        func contains(_ cueId: String) -> Bool { cues[cueId] != nil }
    }

    struct MemoryTransport: CueSyncTransport {
        let transportId = "memory"
        let ready: Bool
        let inboundCues: [CueSyncRecord]
        let inboundDismissals: [CueDismissal]
        let offered: OfferSink

        actor OfferSink {
            private(set) var cues: [CueSyncRecord] = []
            private(set) var dismissals: [CueDismissal] = []
            func record(cues newCues: [CueSyncRecord], dismissals newDismissals: [CueDismissal]) {
                cues.append(contentsOf: newCues)
                dismissals.append(contentsOf: newDismissals)
            }
        }

        init(
            ready: Bool = true,
            inboundCues: [CueSyncRecord] = [],
            inboundDismissals: [CueDismissal] = [],
            offered: OfferSink = OfferSink()
        ) {
            self.ready = ready
            self.inboundCues = inboundCues
            self.inboundDismissals = inboundDismissals
            self.offered = offered
        }

        func isReady() async -> Bool { ready }

        func offer(cues: [CueSyncRecord], dismissals: [CueDismissal]) async throws {
            await offered.record(cues: cues, dismissals: dismissals)
        }

        func fetch(since cursor: CueSyncCursor?) async throws -> (cues: [CueSyncRecord], dismissals: [CueDismissal], cursor: CueSyncCursor?) {
            (inboundCues, inboundDismissals, CueSyncCursor(bytes: Data("1".utf8)))
        }
    }

    private static func record(
        cueId: String,
        trackId: String = "t",
        kind: CueKind = .memory,
        positionMillis: Int64 = 1_000,
        updatedAtMillis: Int64 = 100,
        writerId: String = "device-a",
        isDeleted: Bool = false
    ) -> CueSyncRecord {
        CueSyncRecord(CuePoint(
            id: cueId,
            trackId: trackId,
            kind: kind,
            positionMillis: positionMillis,
            createdAtMillis: updatedAtMillis,
            updatedAtMillis: updatedAtMillis,
            isDeleted: isDeleted,
            writerId: writerId
        ))
    }

    private static func dismissal(
        id: String,
        writerId: String = "device-a",
        dismissedAtMillis: Int64 = 500
    ) -> CueDismissal {
        CueDismissal(
            id: id, trackId: "t", suggesterName: "sounding.envelope", suggesterVersion: 1,
            kind: .memory, positionMillis: 90_000, dismissedAtMillis: dismissedAtMillis, writerId: writerId
        )
    }

    static func run() async -> Report {
        var report = Report()
        await testRelayRoundTrip(&report)
        await testRelayIsIdempotent(&report)
        await testPushCursorStopsResendingSettledRows(&report)
        await testDismissalsRideTheSameRound(&report)
        await testNotReadyTransportIsAnInertSkip(&report)
        testCueSyncPayloadRoundTrip(&report)
        testCueSyncPayloadRejectsWrongSecret(&report)
        testCueSyncPayloadRejectsWrongSessionId(&report)
        testCueSyncPayloadRejectsTamperedBody(&report)
        testCueSyncPayloadRejectsTamperedCounts(&report)
        testCueSyncPayloadFreshnessWindow(&report)
        testCueSyncPayloadEmptyBodyRoundTrips(&report)
        return report
    }

    private static func testCueSyncPayloadRoundTrip(_ report: inout Report) {
        let cues = [record(cueId: "a"), record(cueId: "b", updatedAtMillis: 200)]
        let dismissals = [dismissal(id: "d1")]
        let body = CueSyncBody(cues: cues, dismissals: dismissals)
        guard let encoded = body.encoded() else {
            report.failures.append("cue sync payload round trip: body failed to encode")
            return
        }
        let secret = Data("shared-secret".utf8)
        let payload = CueSyncPayload.create(
            body: encoded, cueCount: cues.count, dismissalCount: dismissals.count,
            sessionId: "session-1", secret: secret
        )
        report.expect(
            "a signed cue sync payload verifies under the session id and secret it was created with",
            payload.verify(sessionId: "session-1", secret: secret)
        )
        report.expect(
            "a verified cue sync payload's body decodes back to the original cue sync body",
            CueSyncBody.decode(payload.body) == body
        )
    }

    private static func testCueSyncPayloadRejectsWrongSecret(_ report: inout Report) {
        let body = CueSyncBody(cues: [record(cueId: "a")], dismissals: [])
        guard let encoded = body.encoded() else {
            report.failures.append("cue sync payload wrong-secret test: body failed to encode")
            return
        }
        let payload = CueSyncPayload.create(
            body: encoded, cueCount: 1, dismissalCount: 0,
            sessionId: "session-1", secret: Data("secret-a".utf8)
        )
        report.expect(
            "a cue sync payload created with one secret fails verification under a different secret",
            !payload.verify(sessionId: "session-1", secret: Data("secret-b".utf8))
        )
    }

    private static func testCueSyncPayloadRejectsWrongSessionId(_ report: inout Report) {
        let body = CueSyncBody(cues: [record(cueId: "a")], dismissals: [])
        guard let encoded = body.encoded() else {
            report.failures.append("cue sync payload wrong-session test: body failed to encode")
            return
        }
        let secret = Data("shared-secret".utf8)
        let payload = CueSyncPayload.create(
            body: encoded, cueCount: 1, dismissalCount: 0,
            sessionId: "session-1", secret: secret
        )
        report.expect(
            "a cue sync payload created for one session id fails verification under a different session id",
            !payload.verify(sessionId: "session-2", secret: secret)
        )
    }

    private static func testCueSyncPayloadRejectsTamperedBody(_ report: inout Report) {
        let originalBody = CueSyncBody(cues: [record(cueId: "a")], dismissals: [])
        let swappedBody = CueSyncBody(cues: [record(cueId: "b")], dismissals: [])
        guard let encodedOriginal = originalBody.encoded(), let encodedSwapped = swappedBody.encoded() else {
            report.failures.append("cue sync payload tampered-body test: body failed to encode")
            return
        }
        let secret = Data("shared-secret".utf8)
        let payload = CueSyncPayload.create(
            body: encodedOriginal, cueCount: 1, dismissalCount: 0,
            sessionId: "session-1", secret: secret
        )
        let tampered = CueSyncPayload(
            body: encodedSwapped, cueCount: payload.cueCount, dismissalCount: payload.dismissalCount,
            issuedAtMillis: payload.issuedAtMillis, nonce: payload.nonce, signature: payload.signature
        )
        report.expect(
            "a cue sync payload whose body is swapped after signing fails verification",
            !tampered.verify(sessionId: "session-1", secret: secret)
        )
    }

    private static func testCueSyncPayloadRejectsTamperedCounts(_ report: inout Report) {
        let body = CueSyncBody(cues: [record(cueId: "a")], dismissals: [])
        guard let encoded = body.encoded() else {
            report.failures.append("cue sync payload tampered-counts test: body failed to encode")
            return
        }
        let secret = Data("shared-secret".utf8)
        let payload = CueSyncPayload.create(
            body: encoded, cueCount: 1, dismissalCount: 0,
            sessionId: "session-1", secret: secret
        )
        let tamperedCueCount = CueSyncPayload(
            body: payload.body, cueCount: payload.cueCount + 1, dismissalCount: payload.dismissalCount,
            issuedAtMillis: payload.issuedAtMillis, nonce: payload.nonce, signature: payload.signature
        )
        report.expect(
            "a cue sync payload whose cue count is altered after signing fails verification",
            !tamperedCueCount.verify(sessionId: "session-1", secret: secret)
        )
        let tamperedDismissalCount = CueSyncPayload(
            body: payload.body, cueCount: payload.cueCount, dismissalCount: payload.dismissalCount + 1,
            issuedAtMillis: payload.issuedAtMillis, nonce: payload.nonce, signature: payload.signature
        )
        report.expect(
            "a cue sync payload whose dismissal count is altered after signing fails verification",
            !tamperedDismissalCount.verify(sessionId: "session-1", secret: secret)
        )
    }

    private static func testCueSyncPayloadFreshnessWindow(_ report: inout Report) {
        let body = CueSyncBody(cues: [], dismissals: [])
        guard let encoded = body.encoded() else {
            report.failures.append("cue sync payload freshness test: body failed to encode")
            return
        }
        let secret = Data("shared-secret".utf8)
        let now = Date()
        let payload = CueSyncPayload.create(
            body: encoded, cueCount: 0, dismissalCount: 0,
            sessionId: "session-1", secret: secret
        )
        report.expect(
            "a cue sync payload issued just now is fresh",
            payload.isFresh(now: now)
        )
        let stale = CueSyncPayload(
            body: payload.body, cueCount: payload.cueCount, dismissalCount: payload.dismissalCount,
            issuedAtMillis: payload.issuedAtMillis - 10 * 60 * 1000, nonce: payload.nonce, signature: payload.signature
        )
        report.expect(
            "a cue sync payload issued well outside the freshness window in the past is not fresh",
            !stale.isFresh(now: now)
        )
        let fromTheFuture = CueSyncPayload(
            body: payload.body, cueCount: payload.cueCount, dismissalCount: payload.dismissalCount,
            issuedAtMillis: payload.issuedAtMillis + 10 * 60 * 1000, nonce: payload.nonce, signature: payload.signature
        )
        report.expect(
            "a cue sync payload issued well outside the freshness window in the future is not fresh",
            !fromTheFuture.isFresh(now: now)
        )
    }

    private static func testCueSyncPayloadEmptyBodyRoundTrips(_ report: inout Report) {
        let body = CueSyncBody(cues: [], dismissals: [])
        guard let encoded = body.encoded() else {
            report.failures.append("cue sync payload empty-body test: body failed to encode")
            return
        }
        let secret = Data("shared-secret".utf8)
        let payload = CueSyncPayload.create(
            body: encoded, cueCount: 0, dismissalCount: 0,
            sessionId: "session-1", secret: secret
        )
        report.expect(
            "an empty cue sync body (no cues, no dismissals) still produces a payload that verifies",
            payload.verify(sessionId: "session-1", secret: secret)
        )
        report.expect(
            "an empty cue sync body decodes back to an empty cue sync body",
            CueSyncBody.decode(payload.body) == body
        )
    }

    private static func testRelayRoundTrip(_ report: inout Report) async {
        let mine = record(cueId: "mine", updatedAtMillis: 50)
        let theirs = record(cueId: "theirs", updatedAtMillis: 60, writerId: "device-b")
        let store = MemoryStore(cues: [mine])
        let sink = MemoryTransport.OfferSink()
        let transport = MemoryTransport(inboundCues: [theirs], offered: sink)
        let relay = CueSyncRelay(store: store, transport: transport)

        do {
            let result = try await relay.runOnce(since: nil)
            let hasTheirs = await store.contains("theirs")
            let offeredIds = await sink.cues.map(\.cueId).sorted()
            report.expect(
                "relay adopts a peer's cue and offers its own back (fetched \(result.fetchedCues), adopted \(result.adoptedCues), offered \(result.offeredCues))",
                result.adoptedCues == 1 && hasTheirs && offeredIds == ["mine"],
                "adopted=\(result.adoptedCues), hasTheirs=\(hasTheirs), offered=\(offeredIds)"
            )
            report.expect("relay returns a cursor for the next round", result.cursor != nil)
        } catch {
            report.failures.append("relay round trip threw: \(error)")
        }
    }

    private static func testRelayIsIdempotent(_ report: inout Report) async {
        let theirs = record(cueId: "shared", writerId: "device-b")
        let store = MemoryStore()
        let transport = MemoryTransport(inboundCues: [theirs])
        let relay = CueSyncRelay(store: store, transport: transport)

        do {
            let first = try await relay.runOnce(since: nil)
            let second = try await relay.runOnce(since: first.cursor)
            let count = await store.cueCount
            report.expect(
                "replaying the same inbound batch adopts once then stops adopting",
                first.adoptedCues == 1 && second.adoptedCues == 0 && count == 1,
                "first=\(first.adoptedCues), second=\(second.adoptedCues), rows=\(count)"
            )
        } catch {
            report.failures.append("idempotency test threw: \(error)")
        }
    }

    private static func testPushCursorStopsResendingSettledRows(_ report: inout Report) async {
        let mine = record(cueId: "mine", updatedAtMillis: 50)
        let store = MemoryStore(cues: [mine])
        let sink = MemoryTransport.OfferSink()
        let transport = MemoryTransport(offered: sink)
        let relay = CueSyncRelay(store: store, transport: transport)

        do {
            let first = try await relay.runOnce(since: nil)
            _ = try await relay.runOnce(since: first.cursor)
            let offeredTwice = await sink.cues.filter { $0.cueId == "mine" }.count
            report.expect(
                "a row already pushed through is not re-offered on the next settled round",
                offeredTwice == 1,
                "offered \(offeredTwice) time(s), expected 1"
            )
        } catch {
            report.failures.append("push-cursor test threw: \(error)")
        }
    }

    private static func testDismissalsRideTheSameRound(_ report: inout Report) async {
        let suggestion = CueSuggestion(
            trackId: "t", kind: .memory, positionMillis: 90_000, endMillis: nil,
            suggester: CueSuggesterIdentity(name: "sounding.envelope", version: 1),
            confidence: 0.5, reasoning: "synthetic", snappedToGrid: false, label: "", color: .memory
        )
        let dismissal = CueDismissal(suggestion: suggestion, writerId: "device-b", now: 500)
        let store = MemoryStore()
        let transport = MemoryTransport(inboundDismissals: [dismissal])
        let relay = CueSyncRelay(store: store, transport: transport)

        do {
            let result = try await relay.runOnce(since: nil)
            let count = await store.dismissalCount
            report.expect(
                "a dismissal fetched from a peer is adopted alongside cues",
                result.adoptedDismissals == 1 && count == 1
            )
        } catch {
            report.failures.append("dismissal relay test threw: \(error)")
        }
    }

    private static func testNotReadyTransportIsAnInertSkip(_ report: inout Report) async {
        let relay = CueSyncRelay(store: MemoryStore(), transport: MemoryTransport(ready: false))
        do {
            let result = try await relay.runOnce(since: nil)
            report.expect(
                "a transport with no peer/account is an inert skip, not an error",
                result.skippedNotReady && result.fetchedCues == 0 && result.offeredCues == 0
            )
        } catch {
            report.failures.append("not-ready relay threw: \(error)")
        }
    }
}
#endif
