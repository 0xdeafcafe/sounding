import Network
import XCTest
@testable import SoundingTV

final class SameAccountLinkTests: XCTestCase {
    private let salt = Data(repeating: 0x5A, count: LinkAccountHint.saltLength)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func advert(account: String = "12345", linked: [String] = [], salt: Data? = nil) -> LinkAccountHint.Advert {
        LinkAccountHint.advert(accountId: account, linkedDeviceIds: linked, salt: salt ?? self.salt)!
    }

    private func offer(_ prefix: String = "abcd1234", name: String = "Living Room", kind: DeviceClass = .tv, hint: LinkAccountHint.Advert?) -> SameAccountLinkOffer.Advertised {
        SameAccountLinkOffer.Advertised(sessionIdPrefix: prefix, name: name, kind: kind, accountHint: hint)
    }

    // MARK: - Account hash

    func testSameAccountMatches() {
        XCTAssertTrue(advert().matches(accountId: "12345"))
    }

    func testDifferentAccountDoesNotMatch() {
        XCTAssertFalse(advert().matches(accountId: "12346"))
        XCTAssertFalse(advert().matches(accountId: ""))
    }

    func testDigestNeverContainsTheRawAccountId() {
        let entries = advert(account: "user-98765").entries
        XCTAssertFalse(entries.values.contains { $0.contains("98765") })
        XCTAssertEqual(Data(base64Encoded: entries[LinkAccountHint.accountKey]!)!.count, LinkAccountHint.accountDigestLength)
    }

    func testSaltChangesTheDigest() {
        let other = advert(salt: Data(repeating: 0x11, count: LinkAccountHint.saltLength))
        XCTAssertNotEqual(advert().accountDigest, other.accountDigest)
        XCTAssertTrue(other.matches(accountId: "12345"))
    }

    func testEntriesRoundTrip() {
        let original = advert(linked: ["PHONE-A", "phone-b"])
        let decoded = LinkAccountHint.decode(original.entries)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded!.isLinked(toDeviceId: "phone-a"))
        XCTAssertTrue(decoded!.isLinked(toDeviceId: "PHONE-B"))
        XCTAssertFalse(decoded!.isLinked(toDeviceId: "phone-c"))
    }

    func testTXTRecordRoundTrip() {
        let original = advert(linked: ["phone-a"])
        let record = NWTXTRecord(LinkOfferTXT.dictionary(name: "Living Room", kind: .tv, commitment: Data(repeating: 1, count: 32), accountHint: original))
        XCTAssertEqual(LinkAccountHint.decode(record), original)
        XCTAssertEqual(LinkOfferTXT.decode(record)?.name, "Living Room")
    }

    func testMalformedEntriesAreIgnored() {
        XCTAssertNil(LinkAccountHint.decode([:]))
        XCTAssertNil(LinkAccountHint.decode([LinkAccountHint.saltKey: "AAAA", LinkAccountHint.accountKey: "AAAA"]))
        var entries = advert().entries
        entries[LinkAccountHint.linkedKey] = Data(repeating: 1, count: 3).base64EncodedString()
        XCTAssertEqual(LinkAccountHint.decode(entries)?.linkedDigests, [])
    }

    func testLinkedListIsCapped() {
        let many = (0..<20).map { "phone-\($0)" }
        XCTAssertEqual(advert(linked: many).linkedDigests.count, LinkAccountHint.maximumLinked)
    }

    func testCandidatesNeedTheSameAccountAndNoExistingLink() {
        let offers = [
            offer("aaaa1111", name: "Living Room", hint: advert()),
            offer("bbbb2222", name: "Bedroom", hint: advert(account: "other")),
            offer("cccc3333", name: "Kitchen", hint: nil),
            offer("dddd4444", name: "Office", hint: advert(linked: ["me"])),
            offer("eeee5555", name: "Mac", kind: .mac, hint: advert()),
        ]
        let candidates = SameAccountLinkOffer.candidates(from: offers, accountId: "12345", deviceId: "me")
        XCTAssertEqual(candidates.map(\.name), ["Living Room"])
        XCTAssertEqual(SameAccountLinkOffer.candidates(from: offers, accountId: nil, deviceId: "me"), [])
    }

    // MARK: - Offer state machine

    private func candidate(_ name: String = "Living Room") -> SameAccountLinkOffer.Candidate {
        SameAccountLinkOffer.Candidate(sessionIdPrefix: "abcd1234", name: name, kind: .tv)
    }

    func testSuggestsTheFirstCandidateAndHidesWhenItLeaves() {
        var machine = SameAccountLinkOffer()
        machine.observe([candidate()], now: start)
        XCTAssertEqual(machine.suggestion, candidate())
        machine.observe([], now: start)
        XCTAssertEqual(machine.phase, .hidden)
    }

    func testDismissKeepsThatTVQuiet() {
        var machine = SameAccountLinkOffer()
        machine.observe([candidate()], now: start)
        machine.dismiss()
        machine.observe([candidate()], now: start)
        XCTAssertNil(machine.suggestion)
        machine.observe([candidate("living room"), candidate("Bedroom")], now: start)
        XCTAssertEqual(machine.suggestion?.name, "Bedroom")
    }

    func testAcceptThenSuccessHidesForGood() {
        var machine = SameAccountLinkOffer()
        machine.observe([candidate()], now: start)
        XCTAssertEqual(machine.accept(now: start), candidate())
        XCTAssertEqual(machine.phase, .linking(candidate(), since: start))
        machine.observe([candidate()], now: start.addingTimeInterval(5))
        XCTAssertEqual(machine.phase, .linking(candidate(), since: start))
        machine.finish(succeeded: true)
        machine.observe([candidate()], now: start.addingTimeInterval(6))
        XCTAssertEqual(machine.phase, .hidden)
    }

    func testAcceptWithoutSuggestionDoesNothing() {
        var machine = SameAccountLinkOffer()
        XCTAssertNil(machine.accept(now: start))
        XCTAssertEqual(machine.phase, .hidden)
    }

    func testFailureShowsAPlainMessageAndRetryOffersAgain() {
        var machine = SameAccountLinkOffer()
        machine.observe([candidate()], now: start)
        _ = machine.accept(now: start)
        machine.finish(succeeded: false, message: "Your Apple TV didn't answer. Keep it on and try again.")
        XCTAssertEqual(machine.phase, .failed(candidate(), message: "Your Apple TV didn't answer. Keep it on and try again."))
        machine.observe([], now: start)
        XCTAssertEqual(machine.phase, .failed(candidate(), message: "Your Apple TV didn't answer. Keep it on and try again."))
        machine.retry()
        XCTAssertEqual(machine.suggestion, candidate())
    }

    func testFinishIsIgnoredUnlessLinking() {
        var machine = SameAccountLinkOffer()
        machine.observe([candidate()], now: start)
        machine.finish(succeeded: true)
        XCTAssertEqual(machine.suggestion, candidate())
    }

    // MARK: - Timeouts and retries

    func testLinkingTimesOut() {
        var machine = SameAccountLinkOffer()
        machine.observe([candidate()], now: start)
        _ = machine.accept(now: start)
        machine.observe([candidate()], now: start.addingTimeInterval(SameAccountLinkOffer.linkingTimeout - 1))
        if case .failed = machine.phase { XCTFail("timed out early") }
        machine.observe([candidate()], now: start.addingTimeInterval(SameAccountLinkOffer.linkingTimeout + 1))
        guard case .failed(_, let message) = machine.phase else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("Try again"))
    }

    func testRetryPolicyBacksOffThenStops() {
        var policy = LinkRetryPolicy()
        XCTAssertEqual(policy.nextDelay(), 1)
        XCTAssertEqual(policy.nextDelay(), 2)
        XCTAssertNil(policy.nextDelay())
        XCTAssertEqual(policy.attempts, LinkRetryPolicy.maximumAttempts - 1)
    }

    func testEveryStepHasATimeoutAndANextStep() {
        for step in LinkStep.allCases {
            XCTAssertGreaterThan(step.timeout, 0)
            let message = step.timedOutMessage(peer: "Apple TV")
            XCTAssertTrue(message.contains("Apple TV"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("error"))
            XCTAssertTrue(message.hasSuffix("."))
        }
        XCTAssertEqual(LinkStep.comparingCode.timeout, BonjourConstants.linkApprovalTimeout)
    }

    func testServiceNamesDoNotCollide() {
        let link = BonjourConstants.linkServiceName(sessionId: "abcd1234ffff")
        let offer = BonjourConstants.linkOfferServiceName(sessionId: "abcd1234ffff")
        XCTAssertEqual(link, "SoundingTV-Link-abcd1234")
        XCTAssertNotEqual(link, offer)
        XCTAssertTrue(offer.hasPrefix(BonjourConstants.serviceName))
    }

    // MARK: - Already linked

    func testLinkedTVIsNotSuggested() {
        let linked: Set<String> = [SameAccountLinkOffer.identity(name: "Living Room", kind: .tv)]
        let candidates = SameAccountLinkOffer.candidates(
            from: [offer(hint: advert()), offer("ffff0000", name: "Bedroom", hint: advert())],
            accountId: "12345",
            deviceId: "phone",
            linked: linked
        )
        XCTAssertEqual(candidates.map(\.name), ["Bedroom"])
    }

    // MARK: - Same-owner proof

    private func ownerKey(_ byte: UInt8 = 7, at date: Date? = nil) -> LinkOwnerKey {
        LinkOwnerKey(material: Data(repeating: byte, count: LinkOwnerKey.length), createdAt: date ?? start)
    }

    private func transcript(account: String = "12345", responderKey: String = "tv-key") -> LinkOwnerProof.Transcript {
        LinkOwnerProof.Transcript(
            sessionId: "abcd1234",
            initiatorKey: "phone-key",
            responderKey: responderKey,
            commitNonce: "nonce",
            initiatorName: "iPhone",
            initiatorClass: DeviceClass.phone.rawValue,
            accountId: account
        )
    }

    func testOwnerProofVerifiesForTheSameKeyRoleAndAccount() {
        let key = ownerKey().material
        let proof = LinkOwnerProof.sign(.initiator, key: key, transcript: transcript())
        XCTAssertTrue(LinkOwnerProof.verify(proof, role: .initiator, key: key, transcript: transcript()))
    }

    func testOwnerProofFailsAcrossRolesAccountsKeysAndSessions() {
        let key = ownerKey().material
        let proof = LinkOwnerProof.sign(.initiator, key: key, transcript: transcript())
        XCTAssertFalse(LinkOwnerProof.verify(proof, role: .responder, key: key, transcript: transcript()))
        XCTAssertFalse(LinkOwnerProof.verify(proof, role: .initiator, key: key, transcript: transcript(account: "99999")))
        XCTAssertFalse(LinkOwnerProof.verify(proof, role: .initiator, key: ownerKey(8).material, transcript: transcript()))
        XCTAssertFalse(LinkOwnerProof.verify(proof, role: .initiator, key: key, transcript: transcript(responderKey: "other")))
        XCTAssertFalse(LinkOwnerProof.verify(nil, role: .initiator, key: key, transcript: transcript()))
    }

    func testOwnerProofNeedsAnAccount() {
        XCTAssertNil(LinkOwnerProof.sign(.initiator, key: ownerKey().material, transcript: transcript(account: "")))
    }

    func testKeyRingMatchesOfferedTags() {
        let ring = LinkOwnerKeyRing(current: ownerKey())
        let tags = LinkOwnerProof.tags(for: ring.usableKeys(at: start), sessionId: "abcd1234", initiatorKey: "phone-key")
        let match = ring.key(matching: Array(tags.keys), sessionId: "abcd1234", initiatorKey: "phone-key", at: start)
        XCTAssertEqual(match?.key, ownerKey())
        XCTAssertNil(ring.key(matching: Array(tags.keys), sessionId: "ffff0000", initiatorKey: "phone-key", at: start))
        XCTAssertNil(LinkOwnerKeyRing(current: ownerKey(8)).key(matching: Array(tags.keys), sessionId: "abcd1234", initiatorKey: "phone-key", at: start))
    }

    func testKeyRingRotatesAndRetiresTheOldKey() {
        let ring = LinkOwnerKeyRing(current: ownerKey())
        XCTAssertNil(ring.rotated(at: start.addingTimeInterval(86_400)))
        let later = start.addingTimeInterval(LinkOwnerKeyRing.rotationAge)
        let rotated = ring.rotated(at: later)!
        XCTAssertEqual(rotated.previous?.material, ownerKey().material)
        XCTAssertNotEqual(rotated.current?.material, ownerKey().material)
        XCTAssertEqual(rotated.usableKeys(at: later).count, 2)
        XCTAssertEqual(rotated.usableKeys(at: later.addingTimeInterval(LinkOwnerKeyRing.overlap + 1)).count, 1)
    }

    func testExpiredKeysAreNotUsed() {
        let ring = LinkOwnerKeyRing(current: ownerKey())
        XCTAssertTrue(ring.usableKeys(at: start.addingTimeInterval(LinkOwnerKeyRing.maximumAge)).isEmpty)
    }

    // MARK: - TV matches the phone's nearby advert

    private func phone(_ suffix: String = "a1b2c3d4", account: String = "12345", deviceId: String = "phone-1", name: String? = "Alex's iPhone") -> SameAccountPhoneBrowser.Advertised {
        var entries = advert(account: account, linked: [deviceId]).entries
        if let name { entries[LinkAccountHint.nameKey] = name }
        return SameAccountPhoneBrowser.Advertised(serviceName: "\(BonjourConstants.nearbyServiceName)-\(suffix)", entries: entries)
    }

    @MainActor
    func testTVMatchesASameAccountPhone() {
        XCTAssertEqual(SameAccountPhoneBrowser.nearbyName(in: [phone()], accountId: "12345", linkedDeviceIds: []), "Alex's iPhone")
    }

    @MainActor
    func testTVIgnoresAnotherAccount() {
        XCTAssertNil(SameAccountPhoneBrowser.nearbyName(in: [phone(account: "999")], accountId: "12345", linkedDeviceIds: []))
        XCTAssertNil(SameAccountPhoneBrowser.nearbyName(in: [phone()], accountId: nil, linkedDeviceIds: []))
        XCTAssertNil(SameAccountPhoneBrowser.nearbyName(in: [phone()], accountId: "", linkedDeviceIds: []))
    }

    @MainActor
    func testTVIgnoresAPhoneItIsAlreadyLinkedTo() {
        XCTAssertNil(SameAccountPhoneBrowser.nearbyName(in: [phone()], accountId: "12345", linkedDeviceIds: ["tv-remote", "phone-1"]))
        XCTAssertEqual(SameAccountPhoneBrowser.nearbyName(in: [phone()], accountId: "12345", linkedDeviceIds: ["phone-2"]), "Alex's iPhone")
    }

    @MainActor
    func testTVIgnoresOtherServicesAndMissingTXT() {
        let offer = SameAccountPhoneBrowser.Advertised(serviceName: "SoundingTV-LinkOffer-abcd1234", entries: phone().entries)
        let bare = SameAccountPhoneBrowser.Advertised(serviceName: "\(BonjourConstants.nearbyServiceName)-ffff0000", entries: nil)
        XCTAssertNil(SameAccountPhoneBrowser.nearbyName(in: [offer, bare], accountId: "12345", linkedDeviceIds: []))
    }

    @MainActor
    func testTVFallsBackToAGenericNameAndPicksTheFirstMatch() {
        XCTAssertEqual(SameAccountPhoneBrowser.nearbyName(in: [phone(name: nil)], accountId: "12345", linkedDeviceIds: []), "A device")
        XCTAssertEqual(SameAccountPhoneBrowser.nearbyName(in: [phone(name: "   ")], accountId: "12345", linkedDeviceIds: []), "A device")
        let adverts = [phone("bbbb0000", name: "iPad"), phone("aaaa0000", account: "999", name: "Other"), phone("cccc0000", name: "iPhone")]
        XCTAssertEqual(SameAccountPhoneBrowser.nearbyName(in: adverts, accountId: "12345", linkedDeviceIds: []), "iPad")
    }
}
