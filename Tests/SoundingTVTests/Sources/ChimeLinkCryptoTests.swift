import XCTest
import CryptoKit
@testable import SoundingTV

final class ChimeLinkCryptoTests: XCTestCase {
    private func code(_ seed: UInt8) -> ChimeCode {
        ChimeCode(bytes: (0..<ChimeCode.byteCount).map { UInt8(truncatingIfNeeded: Int($0) * 31 + Int(seed)) })!
    }

    private func transcript(
        version: Int = ChimeLinkCrypto.protocolVersion,
        sessionId: String = "6F1E2D3C-0000-4000-8000-00000000A1B2",
        tvDeviceId: String = "TV-DEVICE-1",
        tvName: String = "Living Room",
        tvKind: String = DeviceClass.tv.rawValue,
        phoneNonce: Data = Data(repeating: 0x11, count: 32),
        tvNonce: Data = Data(repeating: 0x22, count: 32)
    ) -> ChimeLinkCrypto.Transcript {
        ChimeLinkCrypto.Transcript(
            version: version,
            sessionId: sessionId,
            tvDeviceId: tvDeviceId,
            tvName: tvName,
            tvKind: tvKind,
            phoneNonce: phoneNonce,
            tvNonce: tvNonce
        )
    }

    // MARK: - Derivation and confirmation

    func testBothSidesConfirmOnlyWithTheSameSecret() throws {
        let tv = try XCTUnwrap(ChimeLinkCrypto.session(code: code(1), transcript: transcript()))
        let phone = try XCTUnwrap(ChimeLinkCrypto.session(code: code(1), transcript: transcript()))
        XCTAssertTrue(ChimeLinkCrypto.verifyConfirmation(ChimeLinkCrypto.confirmation(tv, role: .tv), session: phone, role: .tv))
        XCTAssertTrue(ChimeLinkCrypto.verifyConfirmation(ChimeLinkCrypto.confirmation(phone, role: .phone), session: tv, role: .phone))
        XCTAssertFalse(ChimeLinkCrypto.verifyConfirmation(ChimeLinkCrypto.confirmation(tv, role: .tv), session: phone, role: .phone))
        XCTAssertFalse(ChimeLinkCrypto.verifyConfirmation(ChimeLinkCrypto.confirmation(phone, role: .phone), session: tv, role: .tv))
        XCTAssertNotEqual(ChimeLinkCrypto.confirmation(tv, role: .tv), ChimeLinkCrypto.confirmation(tv, role: .phone))

        for bit in [0, 7, 64, 127] {
            var bytes = code(1).bytes
            bytes[bit / 8] ^= 1 << UInt8(bit % 8)
            let guess = try XCTUnwrap(ChimeLinkCrypto.session(code: XCTUnwrap(ChimeCode(bytes: bytes)), transcript: transcript()))
            XCTAssertFalse(ChimeLinkCrypto.verifyConfirmation(ChimeLinkCrypto.confirmation(tv, role: .tv), session: guess, role: .tv))
            XCTAssertFalse(ChimeLinkCrypto.verifyConfirmation(ChimeLinkCrypto.confirmation(guess, role: .phone), session: tv, role: .phone))
        }
    }

    func testConfirmationRejectsTruncatedAndEmptyTags() throws {
        let session = try XCTUnwrap(ChimeLinkCrypto.session(code: code(2), transcript: transcript()))
        let tag = ChimeLinkCrypto.confirmation(session, role: .tv)
        XCTAssertEqual(tag.count, 32)
        XCTAssertFalse(ChimeLinkCrypto.verifyConfirmation(tag.prefix(16), session: session, role: .tv))
        XCTAssertFalse(ChimeLinkCrypto.verifyConfirmation(Data(), session: session, role: .tv))
        XCTAssertFalse(ChimeLinkCrypto.verifyConfirmation(Data(repeating: 0, count: 32), session: session, role: .tv))
    }

    func testTVIdentityRolesVersionAndSessionAreBound() throws {
        let tv = try XCTUnwrap(ChimeLinkCrypto.session(code: code(3), transcript: transcript()))
        let tvTag = ChimeLinkCrypto.confirmation(tv, role: .tv)
        let tampered: [ChimeLinkCrypto.Transcript] = [
            transcript(tvName: "Bedroom"),
            transcript(tvDeviceId: "TV-DEVICE-2"),
            transcript(tvKind: DeviceClass.mac.rawValue),
            transcript(sessionId: "6F1E2D3C-0000-4000-8000-00000000A1B3"),
            transcript(phoneNonce: Data(repeating: 0x33, count: 32)),
            transcript(tvNonce: Data(repeating: 0x44, count: 32)),
        ]
        for other in tampered {
            let phone = try XCTUnwrap(ChimeLinkCrypto.session(code: code(3), transcript: other))
            XCTAssertFalse(ChimeLinkCrypto.verifyConfirmation(tvTag, session: phone, role: .tv), "\(other)")
        }
    }

    func testMalformedTranscriptsAreRefused() {
        let malformed: [ChimeLinkCrypto.Transcript] = [
            transcript(version: 1),
            transcript(sessionId: "6F1E2D3C"),
            transcript(tvDeviceId: ""),
            transcript(tvName: ""),
            transcript(tvName: String(repeating: "x", count: ChimeLinkCrypto.maximumNameLength + 1)),
            transcript(phoneNonce: Data(repeating: 0x11, count: 16)),
            transcript(tvNonce: Data(repeating: 0x11, count: 32)),
        ]
        for transcript in malformed {
            XCTAssertNil(ChimeLinkCrypto.session(code: code(4), transcript: transcript), "\(transcript)")
        }
    }

    func testSealedOfferOpensOnlyUnderTheSameTranscript() throws {
        let tv = try XCTUnwrap(ChimeLinkCrypto.session(code: code(5), transcript: transcript()))
        let phone = try XCTUnwrap(ChimeLinkCrypto.session(code: code(5), transcript: transcript()))
        let relayed = try XCTUnwrap(ChimeLinkCrypto.session(code: code(5), transcript: transcript(tvNonce: Data(repeating: 0x55, count: 32))))
        let sealed = try ChimeLinkCrypto.seal(Data("offer".utf8), session: tv)
        XCTAssertEqual(try ChimeLinkCrypto.open(sealed, session: phone), Data("offer".utf8))
        XCTAssertThrowsError(try ChimeLinkCrypto.open(sealed, session: relayed))
        var flipped = sealed
        flipped[flipped.count - 1] ^= 1
        XCTAssertThrowsError(try ChimeLinkCrypto.open(flipped, session: phone))
    }

    @MainActor
    func testPhoneReadsOnlyAuthenticatableIdentity() throws {
        let nonce = Data(repeating: 0x11, count: 32)
        var payload = ChimeLinkPayload(
            version: ChimeLinkCrypto.protocolVersion,
            nonceBase64: Data(repeating: 0x22, count: 32).base64EncodedString(),
            sessionId: "6F1E2D3C-0000-4000-8000-00000000A1B2",
            tvName: "Living Room",
            tvKind: DeviceClass.tv.rawValue,
            tvDeviceId: "TV-DEVICE-1"
        )
        XCTAssertEqual(ChimeLinkCrypto.transcript(from: payload, phoneNonce: nonce, sessionIdPrefix: "6F1E2D3C"), transcript())
        XCTAssertNil(ChimeLinkCrypto.transcript(from: payload, phoneNonce: nonce, sessionIdPrefix: "6F1E2D3D"))
        payload.tvKind = "toaster"
        XCTAssertNil(ChimeLinkCrypto.transcript(from: payload, phoneNonce: nonce, sessionIdPrefix: "6F1E2D3C"))
        payload.tvKind = DeviceClass.tv.rawValue
        payload.version = 1
        XCTAssertNil(ChimeLinkCrypto.transcript(from: payload, phoneNonce: nonce, sessionIdPrefix: "6F1E2D3C"))
    }

    func testFreshCodesAre128BitsAndNeverPrinted() throws {
        let first = try XCTUnwrap(ChimeCode.random())
        let second = try XCTUnwrap(ChimeCode.random())
        XCTAssertEqual(first.bytes.count, 16)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse("\(first)".contains(first.bytes.map { String(format: "%02x", $0) }.joined()))
        XCTAssertEqual(String(describing: first), "ChimeCode(redacted)")
        XCTAssertNil(ChimeCode(bytes: Array(repeating: 0, count: 15)))
    }

    func testNumericCodeBindsThePeerName() {
        let tv = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let shared = try! tv.sharedSecretFromKeyAgreement(with: phone.publicKey)
        let names = ["Alex's iPhone", "Alex’s iPhone", "Kitchen iPad", ""]
        let codes = names.map {
            LinkConfirmationCrypto.code(
                sharedSecret: shared,
                publicKeyA: tv.publicKey.rawRepresentation,
                publicKeyB: phone.publicKey.rawRepresentation,
                sessionId: "6F1E2D3C",
                peerName: $0
            )
        }
        XCTAssertEqual(Set(codes).count, names.count)
    }

    // MARK: - Code life

    func testCodesExpireOnAMonotonicDeadline() throws {
        var ledger = ChimeCodeLedger()
        let start = ContinuousClock.now
        ledger.rotate(to: code(6), at: start)
        XCTAssertEqual(ledger.live(at: start.advanced(by: .seconds(119)))?.code, code(6))
        XCTAssertNil(ledger.live(at: start.advanced(by: .seconds(120))))

        let session = try XCTUnwrap(ChimeLinkCrypto.session(code: code(6), transcript: transcript()))
        let pending = try XCTUnwrap(ledger.pending(session, at: start.advanced(by: .seconds(100))))
        XCTAssertEqual(pending.deadline, start.advanced(by: .seconds(120)))
        XCTAssertTrue(ledger.isRedeemable(pending, at: start.advanced(by: .seconds(110))))
        XCTAssertFalse(ledger.isRedeemable(pending, at: start.advanced(by: .seconds(121))))
        XCTAssertFalse(ledger.redeem(pending, at: start.advanced(by: .seconds(121))))

        let early = try XCTUnwrap(ledger.pending(session, at: start))
        XCTAssertEqual(early.deadline, start.advanced(by: ChimeCodeLedger.pendingLifetime))
        XCTAssertFalse(ledger.isRedeemable(early, at: start.advanced(by: .seconds(61))))
        XCTAssertNil(ledger.pending(session, at: start.advanced(by: .seconds(130))))
    }

    func testRotationInvalidatesPendingSessions() throws {
        var ledger = ChimeCodeLedger()
        let start = ContinuousClock.now
        ledger.rotate(to: code(7), at: start)
        let session = try XCTUnwrap(ChimeLinkCrypto.session(code: code(7), transcript: transcript()))
        let pending = try XCTUnwrap(ledger.pending(session, at: start))
        ledger.rotate(to: code(8), at: start.advanced(by: .seconds(1)))
        XCTAssertFalse(ledger.isRedeemable(pending, at: start.advanced(by: .seconds(2))))
        XCTAssertFalse(ledger.redeem(pending, at: start.advanced(by: .seconds(2))))

        ledger.rotate(to: code(7), at: start.advanced(by: .seconds(3)))
        XCTAssertFalse(ledger.isRedeemable(pending, at: start.advanced(by: .seconds(4))), "same secret, new generation")
    }

    func testCodesAreSingleUse() throws {
        var ledger = ChimeCodeLedger()
        let start = ContinuousClock.now
        ledger.rotate(to: code(9), at: start)
        let session = try XCTUnwrap(ChimeLinkCrypto.session(code: code(9), transcript: transcript()))
        let first = try XCTUnwrap(ledger.pending(session, at: start))
        let second = try XCTUnwrap(ledger.pending(session, at: start))
        XCTAssertTrue(ledger.redeem(first, at: start.advanced(by: .seconds(1))))
        XCTAssertFalse(ledger.redeem(second, at: start.advanced(by: .seconds(1))))
        XCTAssertNil(ledger.live(at: start.advanced(by: .seconds(1))))
        XCTAssertNil(ledger.pending(session, at: start.advanced(by: .seconds(1))))
    }

    func testFailedConfirmationsAndHellosAreBudgeted() {
        var ledger = ChimeCodeLedger()
        let start = ContinuousClock.now
        ledger.rotate(to: code(10), at: start)
        XCTAssertFalse(ledger.recordFailure())
        XCTAssertFalse(ledger.recordFailure())
        XCTAssertTrue(ledger.recordFailure())
        ledger.rotate(to: code(11), at: start)
        XCTAssertFalse(ledger.recordFailure())

        for i in 0..<ChimeCodeLedger.hellosPerMinute {
            XCTAssertTrue(ledger.admitHello(at: start.advanced(by: .milliseconds(i))))
        }
        XCTAssertFalse(ledger.admitHello(at: start.advanced(by: .seconds(30))))
        XCTAssertTrue(ledger.admitHello(at: start.advanced(by: .seconds(61))))
    }

    func testPhoneBudgetsAttemptsAgainstSpoofedOffers() {
        var budget = ChimeAttemptBudget()
        let start = ContinuousClock.now
        for _ in 0..<ChimeAttemptBudget.attemptsPerCode {
            XCTAssertTrue(budget.admit(code(12), active: 0, at: start))
        }
        XCTAssertFalse(budget.admit(code(12), active: 0, at: start), "per heard code")
        XCTAssertFalse(budget.admit(code(13), active: ChimeAttemptBudget.concurrentAttempts, at: start), "concurrent")

        var admitted = ChimeAttemptBudget.attemptsPerCode
        var seed: UInt8 = 14
        while budget.admit(code(seed), active: 0, at: start) {
            admitted += 1
            seed &+= 1
        }
        XCTAssertEqual(admitted, ChimeAttemptBudget.attemptsPerMinute, "per minute")
        XCTAssertTrue(budget.admit(code(seed), active: 0, at: start.advanced(by: .seconds(61))))
    }
}
