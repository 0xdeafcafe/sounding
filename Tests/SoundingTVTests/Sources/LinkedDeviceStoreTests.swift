import XCTest
@testable import SoundingTV

private final class MemoryKeychain: LinkedDeviceKeychain {
    var values: [String: String] = [:]
    var failsSaves = false

    func get(forKey key: String) -> String? { values[key] }

    func save(_ value: String, forKey key: String) throws {
        if failsSaves { throw KeychainError.saveFailed(-1) }
        values[key] = value
    }

    func delete(forKey key: String) throws { values[key] = nil }
}

@MainActor
final class LinkedDeviceStoreTests: XCTestCase {
    private let keychain = MemoryKeychain()
    private lazy var store = LinkedDeviceStore(keychain: keychain)

    private func credentials() -> SessionCredentials {
        SessionCredentials.generate()!
    }

    private func device(
        _ credentials: SessionCredentials,
        name: String = "",
        deviceId: String? = nil,
        pairedAt: Date = Date()
    ) -> LinkedDevice {
        LinkedDevice(
            sessionId: credentials.sessionId,
            secret: credentials.secret,
            name: name,
            deviceClass: .phone,
            deviceId: deviceId,
            pairedAt: pairedAt
        )
    }

    func testEmptyStoreLoadsNothing() {
        XCTAssertEqual(store.load(), [])
    }

    func testLegacySingleSessionBecomesTheFirstEntry() {
        let legacy = credentials()
        keychain.values[LinkedDeviceStore.Keys.legacySessionId] = legacy.sessionId
        keychain.values[LinkedDeviceStore.Keys.legacySecret] = legacy.secret.base64EncodedString()

        let devices = store.load()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.sessionId, legacy.sessionId)
        XCTAssertEqual(devices.first?.secret, legacy.secret)
        XCTAssertNil(keychain.values[LinkedDeviceStore.Keys.legacySessionId])
        XCTAssertNil(keychain.values[LinkedDeviceStore.Keys.legacySecret])
        XCTAssertNotNil(keychain.values[LinkedDeviceStore.Keys.devices])
        XCTAssertEqual(store.load(), devices)
    }

    func testMigrationKeepsTheLegacyKeysWhenTheNewListCannotBeSaved() {
        let legacy = credentials()
        keychain.values[LinkedDeviceStore.Keys.legacySessionId] = legacy.sessionId
        keychain.values[LinkedDeviceStore.Keys.legacySecret] = legacy.secret.base64EncodedString()
        keychain.failsSaves = true

        XCTAssertEqual(store.load().first?.sessionId, legacy.sessionId)
        XCTAssertEqual(keychain.values[LinkedDeviceStore.Keys.legacySessionId], legacy.sessionId)
    }

    func testMigratedDeviceKeepsWorkingAlongsideANewlyPairedOne() {
        let legacy = credentials()
        keychain.values[LinkedDeviceStore.Keys.legacySessionId] = legacy.sessionId
        keychain.values[LinkedDeviceStore.Keys.legacySecret] = legacy.secret.base64EncodedString()
        let mac = credentials()

        let change = store.add(device(mac, name: "Studio Mac", deviceId: "mac"))

        XCTAssertEqual(change.devices.map(\.sessionId), [legacy.sessionId, mac.sessionId])
        XCTAssertEqual(change.removed, [])
        let trust = LinkedDeviceTrust(devices: store.load())
        XCTAssertEqual(trust.credentials(forSessionId: legacy.sessionId)?.secret, legacy.secret)
        XCTAssertEqual(trust.credentials(forSessionId: mac.sessionId)?.secret, mac.secret)
    }

    func testPairingASecondDeviceKeepsTheFirst() {
        let phone = credentials()
        let mac = credentials()
        let start = Date()

        store.add(device(phone, name: "iPhone", deviceId: "phone", pairedAt: start))
        let change = store.add(device(mac, name: "Mac", deviceId: "mac", pairedAt: start.addingTimeInterval(1)))

        XCTAssertEqual(change.devices.map(\.sessionId), [phone.sessionId, mac.sessionId])
        XCTAssertEqual(change.removed, [])
        XCTAssertNotEqual(change.devices[0].secret, change.devices[1].secret)
    }

    func testRepairingTheSameDeviceReplacesItsOldSession() {
        let first = credentials()
        let second = credentials()
        let other = credentials()
        store.add(device(first, deviceId: "phone"))
        store.add(device(other, deviceId: "mac"))

        let change = store.add(device(second, deviceId: "phone"))

        XCTAssertEqual(Set(change.devices.map(\.sessionId)), [other.sessionId, second.sessionId])
        XCTAssertEqual(change.removed.map(\.sessionId), [first.sessionId])
    }

    func testDevicesWithoutAnIdentityAreNeverMergedTogether() {
        store.add(device(credentials()))
        let change = store.add(device(credentials()))
        XCTAssertEqual(change.devices.count, 2)
        XCTAssertEqual(change.removed, [])
    }

    func testCapacityDropsTheLeastRecentlyPairedDevice() {
        let start = Date()
        var all: [SessionCredentials] = []
        for index in 0...LinkedDeviceStore.capacity {
            let next = credentials()
            all.append(next)
            store.add(device(next, deviceId: "device-\(index)", pairedAt: start.addingTimeInterval(Double(index))))
        }

        let devices = store.load()
        XCTAssertEqual(devices.count, LinkedDeviceStore.capacity)
        XCTAssertFalse(devices.contains { $0.sessionId == all[0].sessionId })
        XCTAssertTrue(devices.contains { $0.sessionId == all.last!.sessionId })
    }

    func testRevokeRemovesOnlyThatDevice() {
        let phone = credentials()
        let mac = credentials()
        store.add(device(phone, deviceId: "phone"))
        store.add(device(mac, deviceId: "mac"))

        let change = store.revoke(sessionId: phone.sessionId)

        XCTAssertEqual(change.removed.map(\.sessionId), [phone.sessionId])
        XCTAssertEqual(store.load().map(\.sessionId), [mac.sessionId])
        XCTAssertEqual(store.revoke(sessionId: phone.sessionId).removed, [])
    }

    func testRevokingTheMigratedDeviceDoesNotResurrectIt() {
        let legacy = credentials()
        keychain.values[LinkedDeviceStore.Keys.legacySessionId] = legacy.sessionId
        keychain.values[LinkedDeviceStore.Keys.legacySecret] = legacy.secret.base64EncodedString()
        _ = store.load()

        store.revoke(sessionId: legacy.sessionId)

        XCTAssertEqual(store.load(), [])
    }

    func testRemoveAllForgetsEveryDeviceAndTheLegacyPairing() {
        keychain.values[LinkedDeviceStore.Keys.legacySessionId] = "legacy"
        keychain.values[LinkedDeviceStore.Keys.legacySecret] = Data([1, 2, 3]).base64EncodedString()
        store.add(device(credentials(), deviceId: "phone"))

        store.removeAll()

        XCTAssertEqual(store.load(), [])
        XCTAssertTrue(keychain.values.isEmpty)
    }

    func testRevokedDeviceIsRefused() {
        let phone = credentials()
        let mac = credentials()
        store.add(device(phone, deviceId: "phone"))
        store.add(device(mac, deviceId: "mac"))
        let phoneCommand = CompanionCommandSigner(sessionId: phone.sessionId, secret: phone.secret)
            .control(.transportPause)
        let macCommand = CompanionCommandSigner(sessionId: mac.sessionId, secret: mac.secret)
            .control(.transportPause)

        XCTAssertTrue(LinkedDeviceTrust(devices: store.load()).admits(phoneCommand, onSession: phone.sessionId))

        store.revoke(sessionId: phone.sessionId)
        let trust = LinkedDeviceTrust(devices: store.load())

        XCTAssertFalse(trust.admits(phoneCommand, onSession: phone.sessionId))
        XCTAssertNil(trust.credentials(forSessionId: phone.sessionId))
        XCTAssertTrue(trust.admits(macCommand, onSession: mac.sessionId))
        XCTAssertFalse(trust.admits(phoneCommand, onSession: mac.sessionId))
        XCTAssertFalse(phoneCommand.control!.verify(type: .transportPause, sessionId: mac.sessionId, secret: mac.secret))
    }

    func testOneDeviceCannotSpeakOnAnotherDevicesSession() {
        let phone = credentials()
        let mac = credentials()
        store.add(device(phone, deviceId: "phone"))
        store.add(device(mac, deviceId: "mac"))
        let forged = CompanionCommandSigner(sessionId: mac.sessionId, secret: phone.secret).control(.transportPlay)

        let trust = LinkedDeviceTrust(devices: store.load())
        let credentials = trust.credentials(forSessionId: mac.sessionId)!

        XCTAssertTrue(trust.admits(forged, onSession: mac.sessionId))
        XCTAssertFalse(forged.control!.verify(type: .transportPlay, sessionId: credentials.sessionId, secret: credentials.secret))
    }

    func testSignedIdentityNamesTheDevice() {
        let phone = credentials()
        store.add(device(phone))
        let identity = LinkPeerIdentity.create(
            name: "Kitchen iPad",
            deviceClass: .pad,
            deviceId: "pad",
            sessionId: phone.sessionId,
            secret: phone.secret
        )

        XCTAssertTrue(identity.verify(sessionId: phone.sessionId, secret: phone.secret))
        let updated = store.update(sessionId: phone.sessionId, identity: identity)

        XCTAssertEqual(updated?.first?.displayName, "Kitchen iPad")
        XCTAssertEqual(updated?.first?.deviceClass, .pad)
        XCTAssertEqual(updated?.first?.deviceId, "pad")
        XCTAssertNil(store.update(sessionId: phone.sessionId, identity: identity))
    }

    func testIdentitySignedWithAnotherSecretIsRejected() {
        let phone = credentials()
        let other = credentials()
        let identity = LinkPeerIdentity.create(
            name: "Impostor",
            deviceClass: .phone,
            deviceId: "x",
            sessionId: phone.sessionId,
            secret: other.secret
        )
        XCTAssertFalse(identity.verify(sessionId: phone.sessionId, secret: phone.secret))
    }

    func testUnnamedDevicesFallBackToTheirClass() {
        let phone = credentials()
        XCTAssertEqual(LinkedDevice(sessionId: phone.sessionId, secret: phone.secret).displayName, "Linked Device")
        XCTAssertEqual(LinkedDevice(sessionId: phone.sessionId, secret: phone.secret, deviceClass: .mac).displayName, "Mac")
    }

    func testPeerIdentityTravelsInTheEnvelopeAndOlderMessagesStillDecode() throws {
        let phone = credentials()
        let signer = CompanionCommandSigner(sessionId: phone.sessionId, secret: phone.secret)
        var message = signer.queue(.queueRequest, revision: 0)
        message.peer = LinkPeerIdentity.create(
            name: "iPhone",
            deviceClass: .phone,
            deviceId: "phone",
            sessionId: phone.sessionId,
            secret: phone.secret
        )

        let decoded = try TokenTransferMessage.decode(from: message.encode())
        XCTAssertEqual(decoded.peer, message.peer)
        XCTAssertTrue(decoded.peer!.verify(sessionId: phone.sessionId, secret: phone.secret))

        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: message.encode()) as? [String: Any])
        legacyJSON["peer"] = nil
        let legacy = try TokenTransferMessage.decode(from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertNil(legacy.peer)
        XCTAssertTrue(legacy.command!.verify(type: .queueRequest, sessionId: phone.sessionId, secret: phone.secret))
    }
}
