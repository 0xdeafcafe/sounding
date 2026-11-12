import XCTest
@testable import SoundingTV

final class SessionSyncAccountTests: XCTestCase {
    private let alexTag = PeerAccount.tag(userId: "1001")
    private let samTag = PeerAccount.tag(userId: "2002")

    private func session(_ token: String, issued: Int64, tag: String?, name: String? = nil, writer: String = "w1") -> SyncedSoundCloudSession {
        SyncedSoundCloudSession(
            oauthToken: token,
            refreshToken: "r-\(token)",
            clientId: "c",
            expiresAtMillis: nil,
            updatedAtMillis: issued,
            writerId: writer,
            issuedAtMillis: issued,
            generation: 0
        ).describingAccount(tag: tag, name: name, writerName: "Living Room", writerKind: "tv")
    }

    private let noLineages = RejectedLineageLedger.memory()

    func testNewerSessionOnTheSameAccountWins() {
        let local = session("a", issued: 100, tag: alexTag)
        let remote = session("b", issued: 200, tag: alexTag, writer: "w2")
        XCTAssertTrue(SessionSyncPolicy.remoteWins(local: local, remote: remote, rejectedLineages: noLineages))
    }

    func testAnotherAccountNeverWinsForASignedInDevice() {
        let local = session("a", issued: 100, tag: alexTag)
        let remote = session("b", issued: 900, tag: samTag, writer: "w2")
        XCTAssertFalse(SessionSyncPolicy.remoteWins(local: local, remote: remote, rejectedLineages: noLineages))
    }

    func testUntaggedRecordsKeepTheOldOrdering() {
        let local = session("a", issued: 100, tag: nil)
        let remote = session("b", issued: 200, tag: samTag, writer: "w2")
        XCTAssertTrue(SessionSyncPolicy.remoteWins(local: local, remote: remote, rejectedLineages: noLineages))
    }

    func testAnEmptyDeviceAdoptsTheNewestUnlessItSignedOut() {
        let remote = session("b", issued: 200, tag: samTag)
        XCTAssertTrue(SessionSyncPolicy.remoteWins(local: nil, remote: remote, rejectedLineages: noLineages))
        XCTAssertFalse(SessionSyncPolicy.remoteWins(local: nil, remote: remote, localSignOutMillis: 150, rejectedLineages: noLineages))
    }

    func testEqualityIgnoresAccountDescription() {
        let plain = session("a", issued: 100, tag: nil)
        let described = session("a", issued: 100, tag: alexTag, name: "Alex")
        XCTAssertEqual(plain, described)
    }

    func testContinueOfferNeedsATag() {
        XCTAssertNil(SessionContinueOffer(session("a", issued: 1, tag: nil)))
        let offer = SessionContinueOffer(session("a", issued: 1, tag: samTag, name: "Sam"))
        XCTAssertEqual(offer?.account.displayName, "Sam")
        XCTAssertEqual(offer?.writerName, "Living Room")
    }

    func testGuestSignInsStayOffICloudOnTheTV() {
        let local = session("a", issued: 100, tag: samTag)
        XCTAssertFalse(SessionProvenance.mayPush(.guest, isTV: true, local: local, remote: nil))
        XCTAssertFalse(SessionProvenance.mayPush(.guest, isTV: true, local: local, remote: session("b", issued: 50, tag: alexTag)))
        XCTAssertTrue(SessionProvenance.mayPush(.guest, isTV: true, local: local, remote: session("b", issued: 50, tag: samTag)))
        XCTAssertTrue(SessionProvenance.mayPush(.iCloud, isTV: true, local: local, remote: nil))
        XCTAssertTrue(SessionProvenance.mayPush(.linkedPeer, isTV: true, local: local, remote: nil))
        XCTAssertTrue(SessionProvenance.mayPush(.guest, isTV: false, local: local, remote: nil))
    }

    func testProvenancePersists() {
        let defaults = UserDefaults(suiteName: "SessionSyncAccountTests")!
        defaults.removePersistentDomain(forName: "SessionSyncAccountTests")
        XCTAssertEqual(SessionProvenance.current(defaults: defaults), .local)
        SessionProvenance.record(.guest, defaults: defaults)
        XCTAssertEqual(SessionProvenance.current(defaults: defaults), .guest)
        defaults.removePersistentDomain(forName: "SessionSyncAccountTests")
    }

    func testRecordMappingCarriesTheAccountTagInTheWriterField() {
        let marked = CloudSyncMapping.splitAccountMarker("writer#acct.\(alexTag)")
        XCTAssertEqual(marked.writerId, "writer")
        XCTAssertEqual(marked.accountTag, alexTag)
        XCTAssertNil(CloudSyncMapping.splitAccountMarker("writer").accountTag)
        let record = CloudSyncMapping.record(for: session("a", issued: 100, tag: alexTag, name: "Alex"))
        let parsed = CloudSyncMapping.session(from: record)
        XCTAssertEqual(parsed?.writerId, "w1")
        XCTAssertEqual(parsed?.accountTag, alexTag)
        XCTAssertNil(parsed?.accountName)
        let perAccount = CloudSyncMapping.record(for: session("a", issued: 100, tag: alexTag, name: "Alex"), perAccount: true)
        XCTAssertEqual(perAccount.recordID.recordName, "session-\(alexTag)")
        XCTAssertEqual(CloudSyncMapping.session(from: perAccount)?.accountName, "Alex")
    }
}
