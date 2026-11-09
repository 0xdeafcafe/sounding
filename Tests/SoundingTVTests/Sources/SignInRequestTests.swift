import CloudKit
import Network
import XCTest
@testable import SoundingTV

final class SignInRequestTests: XCTestCase {
    private let rendezvous = String(repeating: "0f", count: 16)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(_ rendezvous: String? = nil, name: String = "Living Room", at created: Date? = nil, expires: Date? = nil) -> SignInRequest {
        SignInRequest(rendezvous: rendezvous ?? self.rendezvous, tvName: name, createdAt: created ?? start, expiresAt: expires)!
    }

    // MARK: - Expiry

    func testExpiresAfterTenMinutes() {
        let request = request()
        XCTAssertEqual(request.expiresAt, start.addingTimeInterval(600))
        XCTAssertFalse(request.isExpired(at: start.addingTimeInterval(599)))
        XCTAssertTrue(request.isExpired(at: start.addingTimeInterval(600)))
    }

    func testExpiryIsClampedToTheLifetime() {
        let request = request(expires: start.addingTimeInterval(86_400))
        XCTAssertEqual(request.expiresAt, start.addingTimeInterval(SignInRequest.lifetime))
    }

    func testRequestFromTheFutureCountsAsExpired() {
        XCTAssertTrue(request(at: start.addingTimeInterval(3600)).isExpired(at: start))
    }

    func testRejectsMalformedFields() {
        XCTAssertNil(SignInRequest(rendezvous: "short", tvName: "TV", createdAt: start))
        XCTAssertNil(SignInRequest(rendezvous: String(repeating: "ZZ", count: 16), tvName: "TV", createdAt: start))
        XCTAssertNil(SignInRequest(rendezvous: rendezvous, tvName: "  \n", createdAt: start))
        XCTAssertNil(SignInRequest(rendezvous: rendezvous, tvName: "TV", createdAt: start, expiresAt: start.addingTimeInterval(-1)))
        XCTAssertEqual(SignInRequest(rendezvous: rendezvous, tvName: String(repeating: "x", count: 300), createdAt: start)?.tvName.count, SignInRequest.maximumNameLength)
    }

    func testFreshRendezvousIsValidAndUnique() throws {
        let a = try XCTUnwrap(SignInRequest.makeRendezvous())
        let b = try XCTUnwrap(SignInRequest.makeRendezvous())
        XCTAssertTrue(SignInRequest.isValidRendezvous(a))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Records

    func testRecordRoundTrip() throws {
        let original = request()
        let record = original.record()
        XCTAssertEqual(record.recordType, SignInRequest.recordType)
        XCTAssertEqual(record.recordID.recordName, "signin-\(rendezvous)")
        XCTAssertEqual(SignInRequest(record: record), original)
        XCTAssertNil(record.allKeys().first { !SignInRequest.Field.all.contains($0) })
    }

    func testNotificationFieldsDecode() {
        let fields: [String: Any] = [
            SignInRequest.Field.rendezvous: rendezvous,
            SignInRequest.Field.tvName: "Bedroom",
            SignInRequest.Field.tvKind: "tv",
            SignInRequest.Field.createdAt: start,
            SignInRequest.Field.expiresAt: start.addingTimeInterval(60),
        ]
        let decoded = SignInRequest(fields: fields)
        XCTAssertEqual(decoded?.tvName, "Bedroom")
        XCTAssertEqual(decoded?.expiresAt, start.addingTimeInterval(60))
        XCTAssertNil(SignInRequest(fields: [SignInRequest.Field.tvName: "Bedroom"]))
    }

    // MARK: - Leftover records

    private func ledger() -> SignInRequestLedger {
        let suite = "SignInRequestTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return SignInRequestLedger(defaults: defaults)
    }

    func testLedgerRemembersRecordsUntilTheyAreDeleted() {
        let ledger = ledger()
        ledger.add("signin-a")
        ledger.add("signin-b")
        ledger.add("signin-a")
        XCTAssertEqual(ledger.recordNames, ["signin-b", "signin-a"])
        ledger.remove(["signin-b"])
        XCTAssertEqual(ledger.recordNames, ["signin-a"])
        ledger.remove(["signin-a"])
        XCTAssertNil(ledger.defaults.object(forKey: SignInRequestLedger.key))
    }

    func testLedgerKeepsOnlyTheNewest() {
        let ledger = ledger()
        for index in 0..<(SignInRequestLedger.capacity + 5) { ledger.add("signin-\(index)") }
        XCTAssertEqual(ledger.recordNames.count, SignInRequestLedger.capacity)
        XCTAssertEqual(ledger.recordNames.last, "signin-\(SignInRequestLedger.capacity + 4)")
    }

    func testDeletedOrMissingRecordsAreSettledButFailuresAreRetried() {
        let settled = SignInRequestLedger.settled([
            "deleted": Optional<Error>.none,
            "missing": CKError(.unknownItem),
            "offline": CKError(.networkUnavailable),
        ])
        XCTAssertEqual(Set(settled), ["deleted", "missing"])
    }

    // MARK: - Filtering and de-duplication

    func testFilterShowsOnceThenDeduplicates() {
        var filter = SignInRequestFilter()
        XCTAssertEqual(filter.admit(request(), now: start), .show)
        XCTAssertEqual(filter.admit(request(), now: start.addingTimeInterval(5)), .duplicate)
        XCTAssertEqual(filter.admit(request(String(repeating: "ab", count: 16)), now: start.addingTimeInterval(5)), .show)
    }

    func testFilterIgnoresExpired() {
        var filter = SignInRequestFilter()
        XCTAssertEqual(filter.admit(request(), now: start.addingTimeInterval(601)), .expired)
        XCTAssertTrue(filter.seen.isEmpty)
    }

    func testFilterIgnoresATVThatIsAlreadySignedIn() {
        var filter = SignInRequestFilter()
        XCTAssertEqual(filter.admit(request(), now: start, signedInTVNames: ["living room"]), .alreadySignedIn)
        XCTAssertEqual(filter.admit(request(), now: start, signedInTVNames: ["Bedroom"]), .show)
    }

    func testFilterForgetsOnceTheRequestExpires() {
        var filter = SignInRequestFilter()
        XCTAssertEqual(filter.admit(request(), now: start), .show)
        let renewed = request(at: start.addingTimeInterval(700))
        XCTAssertEqual(filter.admit(renewed, now: start.addingTimeInterval(700)), .show)
    }

    // MARK: - Rendezvous mapping

    private struct FakeOffer: Equatable {
        let name: String
        let rendezvous: String?
    }

    func testRendezvousPicksTheMatchingOffer() {
        let offers = [
            FakeOffer(name: "Kitchen", rendezvous: nil),
            FakeOffer(name: "Bedroom", rendezvous: String(repeating: "12", count: 16)),
            FakeOffer(name: "Living Room", rendezvous: rendezvous),
        ]
        XCTAssertEqual(SignInRequest.matchingOffer(rendezvous, in: offers, key: \.rendezvous)?.name, "Living Room")
        XCTAssertNil(SignInRequest.matchingOffer(String(repeating: "99", count: 16), in: offers, key: \.rendezvous))
        XCTAssertNil(SignInRequest.matchingOffer("", in: [FakeOffer(name: "Empty", rendezvous: "")], key: \.rendezvous))
    }

    func testRendezvousTravelsInTheLinkOfferTXTRecord() {
        let entries = LinkOfferTXT.dictionary(name: "Living Room", kind: .tv, commitment: Data(repeating: 1, count: 32), rendezvous: rendezvous)
        let record = NWTXTRecord(entries)
        XCTAssertEqual(LinkOfferTXT.rendezvous(record), rendezvous)
        XCTAssertNotNil(LinkOfferTXT.decode(record))
        XCTAssertNil(LinkOfferTXT.rendezvous(NWTXTRecord(LinkOfferTXT.dictionary(name: "TV", kind: .tv, commitment: Data(repeating: 1, count: 32)))))
    }

    // MARK: - Device picker wire

    private func invitation(createdAt: Date = Date(), secret: Data = Data(repeating: 9, count: 32)) -> DevicePickerSignIn.Invitation {
        DevicePickerSignIn.Invitation(
            version: DevicePickerSignIn.wireVersion,
            sessionId: "6F1E2D3C-0000-4000-8000-00000000A1B2",
            secretBase64: secret.base64EncodedString(),
            createdAt: createdAt,
            tvName: "Living Room",
            tvKind: "tv"
        )
    }

    func testPickerInvitationRoundTrip() throws {
        let original = invitation()
        let data = try DevicePickerSignIn.encode(original)
        XCTAssertTrue(DevicePickerSignIn.isComplete(data))
        XCTAssertFalse(DevicePickerSignIn.isComplete(data.prefix(data.count - 1)))
        XCTAssertEqual(DevicePickerSignIn.decode(data), original)
    }

    func testPickerRejectsStaleShortOrOversized() throws {
        XCTAssertNil(DevicePickerSignIn.decode(try DevicePickerSignIn.encode(invitation(createdAt: Date().addingTimeInterval(-3600)))))
        XCTAssertNil(DevicePickerSignIn.decode(try DevicePickerSignIn.encode(invitation(secret: Data(repeating: 1, count: 8)))))
        var huge = UInt32(1_000_000).bigEndian
        XCTAssertNil(DevicePickerSignIn.decode(Data(bytes: &huge, count: 4) + Data(repeating: 0x20, count: 64)))
        XCTAssertNil(DevicePickerSignIn.decode(Data([0, 0])))
    }
}
