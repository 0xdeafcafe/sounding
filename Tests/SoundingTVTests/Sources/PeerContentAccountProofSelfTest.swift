import Foundation
@testable import SoundingTV

enum PeerContentAccountProofSelfTest {
    struct Report {
        var failures = [String]()
        var summary: String {
            failures.isEmpty
                ? "[PeerContentAccountProofTest] PASS"
                : "[PeerContentAccountProofTest] FAIL: \(failures.joined(separator: "; "))"
        }

        mutating func expect(_ label: String, _ condition: Bool) {
            if !condition { failures.append(label) }
        }
    }

    static func run() -> Report {
        var report = Report()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        guard let phone = PeerContentAccountCredential.derive(accountId: "account-a", accessToken: "shared-token"),
              let mac = PeerContentAccountCredential.derive(accountId: "account-a", accessToken: "shared-token"),
              let otherAccount = PeerContentAccountCredential.derive(accountId: "account-b", accessToken: "other-token"),
              let otherSession = PeerContentAccountCredential.derive(accountId: "account-a", accessToken: "different-token") else {
            report.failures.append("credential derivation")
            return report
        }

        let proof = PeerContentAccountProof.make(
            requestId: "request-1", trackId: "track-1", offset: 32, length: 64,
            credential: phone, now: now
        )
        report.expect("same credential verifies", proof.isValid(
            requestId: "request-1", trackId: "track-1", offset: 32, length: 64,
            credential: mac, now: now
        ))
        report.expect("a different account cannot claim the request", !proof.isValid(
            requestId: "request-1", trackId: "track-1", offset: 32, length: 64,
            credential: otherAccount, now: now
        ))
        report.expect("a separately issued token fails closed", !proof.isValid(
            requestId: "request-1", trackId: "track-1", offset: 32, length: 64,
            credential: otherSession, now: now
        ))
        report.expect("range tampering is detected", !proof.isValid(
            requestId: "request-1", trackId: "track-1", offset: 33, length: 64,
            credential: mac, now: now
        ))
        report.expect("stale requests are refused", !proof.isValid(
            requestId: "request-1", trackId: "track-1", offset: 32, length: 64,
            credential: mac,
            now: now.addingTimeInterval(PeerContentAccountProof.maximumClockSkew + 1)
        ))

        let body = Data("audio bytes".utf8)
        let responseCode = PeerContentAccountProof.responseCode(
            requestId: "request-1", status: .ok, offset: 32,
            length: Int64(body.count), totalLength: 256, body: body,
            credential: mac
        )
        report.expect("the same account mutually proves the response", PeerContentAccountProof.verifyResponse(
            responseCode, requestId: "request-1", status: .ok, offset: 32,
            length: Int64(body.count), totalLength: 256, body: body,
            credential: phone
        ))
        report.expect("response body tampering is detected", !PeerContentAccountProof.verifyResponse(
            responseCode, requestId: "request-1", status: .ok, offset: 32,
            length: Int64(body.count), totalLength: 256, body: Data("changed".utf8),
            credential: phone
        ))
        report.expect("a different-account server cannot prove the response", !PeerContentAccountProof.verifyResponse(
            responseCode, requestId: "request-1", status: .ok, offset: 32,
            length: Int64(body.count), totalLength: 256, body: body,
            credential: otherAccount
        ))
        return report
    }
}
