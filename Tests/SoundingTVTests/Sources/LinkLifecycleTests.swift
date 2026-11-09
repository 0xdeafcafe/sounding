import XCTest
import Network
@testable import SoundingTV

private final class MemoryLinkKeychain: LinkKeychain {
    var items: [String: Data] = [:]
    var failsWrites = false

    func read(account: String) -> Data? { items[account] }

    func write(_ data: Data, account: String) -> Bool {
        guard !failsWrites else { return false }
        items[account] = data
        return true
    }

    func delete(account: String) { items[account] = nil }
}

private final class MemoryDeviceKeychain: LinkedDeviceKeychain {
    var values: [String: String] = [:]

    func get(forKey key: String) -> String? { values[key] }
    func save(_ value: String, forKey key: String) throws { values[key] = value }
    func delete(forKey key: String) throws { values[key] = nil }
}

final class LinkedCompanionLedgerTests: XCTestCase {
    private let shared = MemoryLinkKeychain()
    private let legacyGroup = MemoryLinkKeychain()
    private lazy var ledger = LinkedCompanionLedger(keychain: shared, legacyKeychains: [legacyGroup])

    private func record(_ name: String, usedAt: Date) -> LinkedCompanionStore.LinkRecord {
        LinkedCompanionStore.LinkRecord(
            sessionId: UUID().uuidString,
            secretBase64: Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString(),
            pairedAt: usedAt,
            deviceClass: .tv,
            displayName: name,
            lastUsedAt: usedAt
        )
    }

    private func legacyData(_ record: LinkedCompanionStore.LinkRecord) throws -> Data {
        var legacy = record
        legacy.lastUsedAt = nil
        return try JSONEncoder().encode(legacy)
    }

    func testEmptyLedgerHasNoLinks() {
        XCTAssertEqual(ledger.loadAll(), [])
        XCTAssertNil(ledger.preferred())
    }

    func testLinkingASecondTVKeepsTheFirst() {
        let livingRoom = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        let bedroom = record("Bedroom", usedAt: Date(timeIntervalSince1970: 200))

        ledger.save(livingRoom)
        ledger.save(bedroom)

        XCTAssertEqual(ledger.loadAll().map(\.peerName), ["Bedroom", "Living Room"])
        XCTAssertEqual(ledger.preferred()?.sessionId, bedroom.sessionId)
    }

    func testMarkUsedMakesALinkPreferred() {
        let livingRoom = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        let bedroom = record("Bedroom", usedAt: Date(timeIntervalSince1970: 200))
        ledger.save(livingRoom)
        ledger.save(bedroom)

        ledger.markUsed(sessionId: livingRoom.sessionId, at: Date(timeIntervalSince1970: 300))

        XCTAssertEqual(ledger.preferred()?.sessionId, livingRoom.sessionId)
        XCTAssertEqual(ledger.loadAll().count, 2)
    }

    func testRelinkingTheSameSessionReplacesIt() {
        var livingRoom = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        ledger.save(livingRoom)
        livingRoom.displayName = "Lounge"
        ledger.save(livingRoom)

        XCTAssertEqual(ledger.loadAll().map(\.peerName), ["Lounge"])
    }

    func testRemoveForgetsOnlyThatTV() {
        let livingRoom = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        let bedroom = record("Bedroom", usedAt: Date(timeIntervalSince1970: 200))
        ledger.save(livingRoom)
        ledger.save(bedroom)

        XCTAssertEqual(ledger.remove(sessionId: bedroom.sessionId)?.sessionId, bedroom.sessionId)
        XCTAssertNil(ledger.remove(sessionId: bedroom.sessionId))
        XCTAssertEqual(ledger.loadAll().map(\.sessionId), [livingRoom.sessionId])
    }

    func testCapacityDropsTheLeastRecentlyUsed() {
        let oldest = record("Oldest", usedAt: Date(timeIntervalSince1970: 1))
        ledger.save(oldest)
        for index in 0..<LinkedCompanionLedger.capacity {
            ledger.save(record("TV \(index)", usedAt: Date(timeIntervalSince1970: Double(10 + index))))
        }

        let links = ledger.loadAll()
        XCTAssertEqual(links.count, LinkedCompanionLedger.capacity)
        XCTAssertFalse(links.contains { $0.sessionId == oldest.sessionId })
    }

    func testSingleSharedLinkMigratesToTheList() throws {
        let legacy = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        shared.items[LinkedCompanionLedger.Accounts.legacyLink] = try legacyData(legacy)

        let links = ledger.loadAll()

        XCTAssertEqual(links.map(\.sessionId), [legacy.sessionId])
        XCTAssertEqual(links.first?.secret, legacy.secret)
        XCTAssertNil(shared.items[LinkedCompanionLedger.Accounts.legacyLink])
        XCTAssertNotNil(shared.items[LinkedCompanionLedger.Accounts.links])
        XCTAssertEqual(ledger.loadAll(), links)
    }

    func testLegacyAccessGroupLinkMigratesAndIsDeleted() throws {
        let legacy = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        legacyGroup.items[LinkedCompanionLedger.Accounts.legacyLink] = try legacyData(legacy)

        XCTAssertEqual(ledger.loadAll().map(\.sessionId), [legacy.sessionId])
        XCTAssertNil(legacyGroup.items[LinkedCompanionLedger.Accounts.legacyLink])
    }

    func testMigrationKeepsTheLegacyItemWhenTheListCannotBeSaved() throws {
        let legacy = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        shared.items[LinkedCompanionLedger.Accounts.legacyLink] = try legacyData(legacy)
        shared.failsWrites = true

        XCTAssertEqual(ledger.loadAll().map(\.sessionId), [legacy.sessionId])
        XCTAssertNotNil(shared.items[LinkedCompanionLedger.Accounts.legacyLink])
    }

    func testMigratedLinkSurvivesLinkingASecondTV() throws {
        let legacy = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        shared.items[LinkedCompanionLedger.Accounts.legacyLink] = try legacyData(legacy)
        let bedroom = record("Bedroom", usedAt: Date(timeIntervalSince1970: 200))

        ledger.save(bedroom)

        XCTAssertEqual(Set(ledger.loadAll().map(\.sessionId)), [legacy.sessionId, bedroom.sessionId])
    }

    func testForgetQueuesASignedRevokeThatOutlivesTheLink() throws {
        let livingRoom = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        ledger.save(livingRoom)

        ledger.enqueue(PendingLinkMessage(kind: .linkRevoke, link: livingRoom))
        ledger.remove(sessionId: livingRoom.sessionId)

        let pending = ledger.pendingMessages()
        XCTAssertEqual(pending.count, 1)
        let message = try XCTUnwrap(pending.first?.message())
        XCTAssertEqual(message.type, .linkRevoke)
        XCTAssertNotNil(message.verifiedRevoke(sessionId: livingRoom.sessionId, secret: try XCTUnwrap(livingRoom.secret)))
    }

    func testRevokeSupersedesAQueuedSignOutForTheSameTV() {
        let livingRoom = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        ledger.enqueue(PendingLinkMessage(kind: .sessionRevoke, link: livingRoom, accountId: "1"))
        ledger.enqueue(PendingLinkMessage(kind: .sessionRevoke, link: livingRoom, accountId: "1"))
        XCTAssertEqual(ledger.pendingMessages().count, 1)

        ledger.enqueue(PendingLinkMessage(kind: .linkRevoke, link: livingRoom))

        XCTAssertEqual(ledger.pendingMessages().map(\.kind), [.linkRevoke])
    }

    func testDeliveredMessagesAreSettled() throws {
        let livingRoom = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        let bedroom = record("Bedroom", usedAt: Date(timeIntervalSince1970: 200))
        ledger.enqueue(PendingLinkMessage(kind: .linkRevoke, link: livingRoom))
        ledger.enqueue(PendingLinkMessage(kind: .linkRevoke, link: bedroom))
        let first = try XCTUnwrap(ledger.pendingMessages().first)

        ledger.settle(messageId: first.id)

        XCTAssertEqual(ledger.pendingMessages().map(\.sessionId), [bedroom.sessionId])
        ledger.settle(messageId: ledger.pendingMessages()[0].id)
        XCTAssertNil(shared.items[LinkedCompanionLedger.Accounts.outbox])
    }

    func testStaleQueuedMessagesExpire() {
        let livingRoom = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        ledger.enqueue(PendingLinkMessage(kind: .linkRevoke, link: livingRoom, createdAt: Date(timeIntervalSinceNow: -LinkedCompanionLedger.outboxLifetime - 60)))

        XCTAssertEqual(ledger.pendingMessages(), [])
    }

    func testSignOutEverywhereQueuesOneMessagePerLinkedTV() throws {
        let livingRoom = record("Living Room", usedAt: Date(timeIntervalSince1970: 100))
        let bedroom = record("Bedroom", usedAt: Date(timeIntervalSince1970: 200))
        for link in [livingRoom, bedroom] {
            ledger.save(link)
            ledger.enqueue(PendingLinkMessage(kind: .sessionRevoke, link: link, accountId: "42", lineageDigest: "lineage"))
        }

        let pending = ledger.pendingMessages()
        XCTAssertEqual(Set(pending.map(\.sessionId)), [livingRoom.sessionId, bedroom.sessionId])
        XCTAssertEqual(ledger.loadAll().count, 2)
        for item in pending {
            let message = try XCTUnwrap(item.message())
            let link = try XCTUnwrap([livingRoom, bedroom].first { $0.sessionId == item.sessionId })
            let revoke = try XCTUnwrap(message.verifiedRevoke(sessionId: link.sessionId, secret: try XCTUnwrap(link.secret)))
            XCTAssertEqual(message.type, .sessionRevoke)
            XCTAssertEqual(revoke.accountId, "42")
            XCTAssertTrue(revoke.matchesAccount(accountId: "42", lineageDigest: nil))
        }
    }
}

final class LinkRevokePayloadTests: XCTestCase {
    private let sessionId = UUID().uuidString
    private let secret = Data(repeating: 3, count: 32)

    func testRevokeVerifiesWithTheLinkSecret() {
        let message = TokenTransferMessage.linkRevoke(sessionId: sessionId, secret: secret)
        XCTAssertNotNil(message.verifiedRevoke(sessionId: sessionId, secret: secret))
    }

    func testRevokeFailsWithAnotherSecretOrSession() {
        let message = TokenTransferMessage.linkRevoke(sessionId: sessionId, secret: secret)
        XCTAssertNil(message.verifiedRevoke(sessionId: sessionId, secret: Data(repeating: 4, count: 32)))
        XCTAssertNil(message.verifiedRevoke(sessionId: UUID().uuidString, secret: secret))
    }

    func testARevokeCannotBeReplayedAsASignOut() throws {
        let revoke = try XCTUnwrap(TokenTransferMessage.linkRevoke(sessionId: sessionId, secret: secret).revoke)
        let forged = TokenTransferMessage(type: .sessionRevoke, sessionId: sessionId, revoke: revoke)
        XCTAssertNil(forged.verifiedRevoke(sessionId: sessionId, secret: secret))
    }

    func testTamperedAccountFailsVerification() throws {
        let original = try XCTUnwrap(TokenTransferMessage.sessionRevoke(sessionId: sessionId, secret: secret, accountId: "1", lineageDigest: nil).revoke)
        let tampered = LinkRevokePayload(
            accountId: "2",
            lineageDigest: original.lineageDigest,
            issuedAtMillis: original.issuedAtMillis,
            nonce: original.nonce,
            signature: original.signature
        )
        XCTAssertFalse(tampered.verify(.sessionRevoke, sessionId: sessionId, secret: secret))
    }

    func testStaleRevokeIsRejected() {
        let payload = LinkRevokePayload.create(.linkRevoke, sessionId: sessionId, secret: secret, now: Date(timeIntervalSinceNow: -600))
        let message = TokenTransferMessage(type: .linkRevoke, sessionId: sessionId, revoke: payload)
        XCTAssertNil(message.verifiedRevoke(sessionId: sessionId, secret: secret))
    }

    func testRevokeSurvivesTheWire() throws {
        let message = TokenTransferMessage.sessionRevoke(sessionId: sessionId, secret: secret, accountId: "7", lineageDigest: "abc")
        var framer = MessageFramer()
        framer.append(try message.framed())
        let decoded = try XCTUnwrap(try framer.next())
        XCTAssertEqual(decoded.type, .sessionRevoke)
        XCTAssertEqual(decoded.verifiedRevoke(sessionId: sessionId, secret: secret)?.lineageDigest, "abc")
    }

    func testSignOutOnlyMatchesTheSameAccount() {
        let payload = LinkRevokePayload.create(.sessionRevoke, accountId: "1", lineageDigest: "L", sessionId: sessionId, secret: secret)
        XCTAssertTrue(payload.matchesAccount(accountId: "1", lineageDigest: nil))
        XCTAssertTrue(payload.matchesAccount(accountId: nil, lineageDigest: "L"))
        XCTAssertFalse(payload.matchesAccount(accountId: "2", lineageDigest: "M"))
        XCTAssertFalse(payload.matchesAccount(accountId: nil, lineageDigest: nil))

        let anonymous = LinkRevokePayload.create(.sessionRevoke, sessionId: sessionId, secret: secret)
        XCTAssertFalse(anonymous.matchesAccount(accountId: nil, lineageDigest: nil))
    }
}

@MainActor
final class RevokedLinkStoreTests: XCTestCase {
    private let keychain = MemoryDeviceKeychain()
    private lazy var store = RevokedLinkStore(keychain: keychain)
    private lazy var devices = LinkedDeviceStore(keychain: keychain)

    private func device(_ name: String) -> LinkedDevice {
        let credentials = SessionCredentials.generate()!
        return LinkedDevice(sessionId: credentials.sessionId, secret: credentials.secret, name: name, deviceClass: .phone)
    }

    func testForgottenDeviceIsRememberedUntilItAcknowledges() {
        let phone = device("Alex’s iPhone")
        devices.add(phone)

        let change = devices.revoke(sessionId: phone.sessionId)
        store.add(RevokedLink(phone))

        XCTAssertEqual(change.devices, [])
        XCTAssertEqual(store.load().map(\.sessionId), [phone.sessionId])
        XCTAssertEqual(store.load().first?.secret, phone.secret)

        store.settle(sessionId: phone.sessionId)
        XCTAssertEqual(store.load(), [])
        XCTAssertNil(keychain.values[RevokedLinkStore.key])
    }

    func testNoticesExpire() {
        store.add(RevokedLink(device("Old iPad"), revokedAt: Date(timeIntervalSinceNow: -RevokedLinkStore.lifetime - 60)))
        XCTAssertEqual(store.load(), [])
    }

    func testNoticesAreBounded() {
        for index in 0..<(RevokedLinkStore.capacity + 3) {
            store.add(RevokedLink(device("Phone \(index)")))
        }
        XCTAssertEqual(store.load().count, RevokedLinkStore.capacity)
    }
}

final class CompanionFailureTests: XCTestCase {
    func testErrorsMapToPlainCopy() {
        XCTAssertEqual(CompanionFailure.classify(.dns(-65570)), .localNetworkDenied)
        XCTAssertEqual(CompanionFailure.classify(.dns(-65554)), .notFound)
        XCTAssertEqual(CompanionFailure.classify(.posix(.ENETDOWN)), .networkUnavailable)
        XCTAssertEqual(CompanionFailure.classify(.posix(.ECONNREFUSED)), .notFound)
        XCTAssertEqual(CompanionFailure.classify(.posix(.ECONNRESET)), .connectionLost)
        XCTAssertEqual(CompanionFailure.classify(.tls(-9806)), .notRecognised)
        XCTAssertEqual(CompanionFailure.classify(nil), .connectionLost)
        XCTAssertEqual(CompanionFailure.classify(nil, fallback: .notFound), .notFound)
    }

    func testMessagesNeverLeakRawErrorText() {
        let failures: [CompanionFailure] = [.notFound, .localNetworkDenied, .networkUnavailable, .connectionLost, .closed, .notRecognised]
        for failure in failures {
            let message = failure.message(here: .phone)
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("NWError"))
            XCTAssertFalse(message.contains("POSIX"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("error"))
        }
        XCTAssertEqual(LinkStatus.unreachable(.notRecognised).title, "Not Reachable")
        XCTAssertEqual(LinkStatus.needsSignIn.title, "Needs Sign-In")
    }
}
