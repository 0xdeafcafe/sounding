import XCTest
@testable import SoundingTV

final class PeerAccountWireTests: XCTestCase {
    private let secret = Data(repeating: 7, count: 32)
    private let sessionId = "session-1"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sam = PeerAccount(userId: "2002", name: "Sam", username: "sam", avatarURL: "https://i1.sndcdn.com/avatars-sam-large.jpg")

    func testTagMatchesAccountSignIn() {
        XCTAssertEqual(PeerAccount.tag(userId: "2002"), AccountSignIn.accountTag(userId: "2002"))
        XCTAssertEqual(sam.tag, AccountSignIn.accountTag(userId: "2002"))
        XCTAssertFalse(sam.tag.contains("2002"))
    }

    func testRoundTrip() throws {
        let data = try XCTUnwrap(sam.encoded())
        XCTAssertLessThanOrEqual(data.count, PeerAccount.maximumEncodedBytes)
        XCTAssertEqual(PeerAccount.decode(data), sam)
    }

    func testSizeCapDropsTheAvatarFirst() throws {
        let huge = PeerAccount(userId: "1", name: "Sam", username: "sam", avatarURL: "https://example.com/" + String(repeating: "a", count: 600))
        let data = try XCTUnwrap(huge.encoded())
        XCTAssertLessThanOrEqual(data.count, PeerAccount.maximumEncodedBytes)
        XCTAssertNil(PeerAccount.decode(data)?.avatarURL)
        XCTAssertNil(PeerAccount.decode(Data(repeating: 0x20, count: PeerAccount.maximumEncodedBytes + 1)))
        XCTAssertNil(PeerAccount.decode(Data("{\"tag\":\"\",\"name\":\"x\",\"username\":\"x\"}".utf8)))
        XCTAssertNil(PeerAccount.decode(nil))
    }

    func testAccountStatusSignsEveryField() throws {
        let status = AccountStatusPayload.create(state: .signedIn, account: sam.encoded(), last: nil, sessionId: sessionId, secret: secret, now: now)
        XCTAssertTrue(status.verify(sessionId: sessionId, secret: secret))
        XCTAssertTrue(status.isFresh(now: now + 60))
        XCTAssertFalse(status.isFresh(now: now + 121))
        XCTAssertTrue(status.supports(CompanionCapability.accountSwitch))
        XCTAssertFalse(status.verify(sessionId: "other", secret: secret))
        XCTAssertFalse(status.verify(sessionId: sessionId, secret: Data(repeating: 8, count: 32)))

        let alex = PeerAccount(userId: "1001", name: "Alex", username: "alex")
        let tamperedAccount = AccountStatusPayload(state: status.state, account: alex.encoded(), last: status.last, capabilities: status.capabilities, issuedAtMillis: status.issuedAtMillis, signature: status.signature)
        XCTAssertFalse(tamperedAccount.verify(sessionId: sessionId, secret: secret))
        let tamperedState = AccountStatusPayload(state: .needsSignIn, account: status.account, last: status.last, capabilities: status.capabilities, issuedAtMillis: status.issuedAtMillis, signature: status.signature)
        XCTAssertFalse(tamperedState.verify(sessionId: sessionId, secret: secret))
        let tamperedLast = AccountStatusPayload(state: status.state, account: status.account, last: alex.encoded(), capabilities: status.capabilities, issuedAtMillis: status.issuedAtMillis, signature: status.signature)
        XCTAssertFalse(tamperedLast.verify(sessionId: sessionId, secret: secret))
        let tamperedCapabilities = AccountStatusPayload(state: status.state, account: status.account, last: status.last, capabilities: [], issuedAtMillis: status.issuedAtMillis, signature: status.signature)
        XCTAssertFalse(tamperedCapabilities.verify(sessionId: sessionId, secret: secret))
        let tamperedTime = AccountStatusPayload(state: status.state, account: status.account, last: status.last, capabilities: status.capabilities, issuedAtMillis: status.issuedAtMillis + 1, signature: status.signature)
        XCTAssertFalse(tamperedTime.verify(sessionId: sessionId, secret: secret))
    }

    func testAccountStatusMessageRoundTrip() throws {
        let status = AccountStatusPayload.create(state: .signedIn, account: sam.encoded(), last: nil, sessionId: sessionId, secret: secret)
        let message = TokenTransferMessage.accountStatus(sessionId: sessionId, status: status)
        let decoded = try JSONDecoder().decode(TokenTransferMessage.self, from: JSONEncoder().encode(message))
        let verified = try XCTUnwrap(decoded.verifiedAccountStatus(sessionId: sessionId, secret: secret))
        XCTAssertEqual(PeerAccount.decode(verified.account), sam)
        XCTAssertNil(decoded.verifiedAccountStatus(sessionId: "other", secret: secret))
        let stale = AccountStatusPayload.create(state: .signedIn, account: sam.encoded(), last: nil, sessionId: sessionId, secret: secret, now: Date().addingTimeInterval(-600))
        XCTAssertNil(TokenTransferMessage.accountStatus(sessionId: sessionId, status: stale).verifiedAccountStatus(sessionId: sessionId, secret: secret))
    }

    func testLinkEstablishRoundTrip() throws {
        let payload = LinkEstablishPayload.create(account: sam.encoded(), sessionId: sessionId, secret: secret)
        let peer = LinkPeerIdentity.create(name: "Alex's iPhone", deviceClass: .phone, deviceId: "device-1", sessionId: sessionId, secret: secret)
        let message = TokenTransferMessage.linkEstablish(sessionId: sessionId, payload: payload, peer: peer)
        let decoded = try JSONDecoder().decode(TokenTransferMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.type, .linkEstablish)
        XCTAssertEqual(decoded.peer, peer)
        let established = try XCTUnwrap(decoded.linkEstablish)
        XCTAssertTrue(established.verify(sessionId: sessionId, secret: secret))
        XCTAssertTrue(established.isFresh())
        let tampered = LinkEstablishPayload(account: nil, issuedAtMillis: established.issuedAtMillis, signature: established.signature)
        XCTAssertFalse(tampered.verify(sessionId: sessionId, secret: secret))
    }

    func testAccountSwitchRoundTripAndBinding() throws {
        let alex = PeerAccount(userId: "1001", name: "Alex", username: "alex")
        let request = AccountSwitchPayload.request(account: try XCTUnwrap(alex.encoded()), nonce: "n1", sessionId: sessionId, secret: secret)
        let message = TokenTransferMessage.accountSwitch(.accountSwitchRequest, sessionId: sessionId, payload: request)
        let decoded = try JSONDecoder().decode(TokenTransferMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.verifiedAccountSwitch(sessionId: sessionId, secret: secret), request)

        let relabelled = TokenTransferMessage.accountSwitch(.accountSwitchAnswer, sessionId: sessionId, payload: request)
        XCTAssertNil(relabelled.verifiedAccountSwitch(sessionId: sessionId, secret: secret))

        let answer = AccountSwitchPayload.answer(.accepted, nonce: "n1", sessionId: sessionId, secret: secret)
        XCTAssertTrue(answer.verify(.accountSwitchAnswer, sessionId: sessionId, secret: secret))
        let flipped = AccountSwitchPayload(nonce: "n1", account: nil, answer: .declined, credentials: nil, issuedAtMillis: answer.issuedAtMillis, signature: answer.signature)
        XCTAssertFalse(flipped.verify(.accountSwitchAnswer, sessionId: sessionId, secret: secret))

        let token = TokenPayload.create(token: "t", refreshToken: "r", clientId: "c", expiresAt: nil, sessionId: sessionId, secret: secret)
        let credentials = AccountSwitchPayload.credentials(token, nonce: "n1", sessionId: sessionId, secret: secret)
        XCTAssertTrue(credentials.verify(.accountSwitchCredentials, sessionId: sessionId, secret: secret))
        let otherToken = TokenPayload.create(token: "u", refreshToken: "r", clientId: "c", expiresAt: nil, sessionId: sessionId, secret: secret)
        let swapped = AccountSwitchPayload(nonce: "n1", account: nil, answer: nil, credentials: otherToken, issuedAtMillis: credentials.issuedAtMillis, signature: credentials.signature)
        XCTAssertFalse(swapped.verify(.accountSwitchCredentials, sessionId: sessionId, secret: secret))
        let empty = AccountSwitchPayload.answer(.accepted, nonce: "", sessionId: sessionId, secret: secret)
        XCTAssertFalse(empty.verify(.accountSwitchAnswer, sessionId: sessionId, secret: secret))
    }

    func testErrorCodeRoundTrip() throws {
        let message = TokenTransferMessage.error(sessionId: sessionId, message: "No", code: CompanionErrorCode.trackUnavailable, trackId: "123")
        let decoded = try JSONDecoder().decode(TokenTransferMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.errorCode, CompanionErrorCode.trackUnavailable)
        XCTAssertEqual(decoded.errorTrackId, "123")
        XCTAssertEqual(decoded.error, "No")
    }

    func testOlderPayloadsStillDecodeAndVerify() throws {
        let old = Data("{\"type\":\"error\",\"sessionId\":\"s\",\"error\":\"Library sync rejected\"}".utf8)
        let decoded = try JSONDecoder().decode(TokenTransferMessage.self, from: old)
        XCTAssertNil(decoded.errorCode)
        XCTAssertNil(decoded.accountStatus)

        let revoke = TokenTransferMessage.linkRevoke(sessionId: sessionId, secret: secret)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(revoke)) as? [String: Any])
        XCTAssertNil((json["revoke"] as? [String: Any])?["reason"])
        let withReason = TokenTransferMessage.linkRevoke(sessionId: sessionId, secret: secret, reason: .signedOut)
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(withReason)) as? [String: Any])
        XCTAssertEqual((json["revoke"] as? [String: Any])?["reason"] as? String, "signedOut")
        let decodedRevoke = try JSONDecoder().decode(TokenTransferMessage.self, from: JSONEncoder().encode(withReason))
        XCTAssertEqual(decodedRevoke.revoke?.reason, .signedOut)
        XCTAssertFalse(try XCTUnwrap(decodedRevoke.revoke).isExplicitUnlink)
        XCTAssertTrue(try XCTUnwrap(revoke.revoke).isExplicitUnlink)
        XCTAssertTrue(try XCTUnwrap(TokenTransferMessage.linkRevoke(sessionId: sessionId, secret: secret, reason: .forgotten).revoke).isExplicitUnlink)

        let hello = LinkConfirmationHelloPayload(ephemeralPublicKeyBase64: "k")
        let helloData = try JSONEncoder().encode(hello)
        XCTAssertFalse(String(decoding: helloData, as: UTF8.self).contains("accountDigest"))
        XCTAssertNil(try JSONDecoder().decode(LinkConfirmationHelloPayload.self, from: helloData).accountDigest)
    }
}
