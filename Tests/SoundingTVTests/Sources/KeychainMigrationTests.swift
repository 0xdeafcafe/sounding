import Security
import Synchronization
import XCTest
@testable import SoundingTV

private final class FakeKeychain: KeychainBackend {
    private struct State {
        var items: [KeychainItemKey: Data] = [:]
        var readFailure: OSStatus?
        var writeFailure: OSStatus?
        var reads = 0
        var deletes = 0
    }

    private let state = Mutex(State())

    var reads: Int { state.withLock { $0.reads } }
    var deletes: Int { state.withLock { $0.deletes } }

    func value(_ key: KeychainItemKey) -> Data? { state.withLock { $0.items[key] } }
    func seed(_ data: Data, _ key: KeychainItemKey) { state.withLock { $0.items[key] = data } }
    func failReads(_ status: OSStatus?) { state.withLock { $0.readFailure = status } }
    func failWrites(_ status: OSStatus?) { state.withLock { $0.writeFailure = status } }

    func copyData(_ query: [String: Any]) -> KeychainLookup {
        state.withLock { state in
            state.reads += 1
            if let failure = state.readFailure { return .failed(failure) }
            guard let key = KeychainItemKey(query), let data = state.items[key] else { return .absent }
            return .present(data)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        state.withLock { state in
            if let failure = state.writeFailure { return failure }
            guard let key = KeychainItemKey(attributes), let data = attributes[kSecValueData as String] as? Data else {
                return errSecParam
            }
            if state.items[key] != nil { return errSecDuplicateItem }
            state.items[key] = data
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        state.withLock { state in
            if let failure = state.writeFailure { return failure }
            guard let key = KeychainItemKey(query), state.items[key] != nil else { return errSecItemNotFound }
            state.items[key] = changes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        state.withLock { state in
            state.deletes += 1
            guard let key = KeychainItemKey(query), state.items.removeValue(forKey: key) != nil else {
                return errSecItemNotFound
            }
            return errSecSuccess
        }
    }
}

private final class MemoryLedger: KeychainMigrationLedger {
    private let state = Mutex<(settled: Set<KeychainItemKey>, pending: Set<KeychainItemKey>)>(([], []))

    func isSettled(_ key: KeychainItemKey) -> Bool { state.withLock { $0.settled.contains(key) } }
    func settle(_ key: KeychainItemKey) {
        state.withLock {
            $0.settled.insert(key)
            $0.pending.remove(key)
        }
    }
    func markPending(_ key: KeychainItemKey) { state.withLock { _ = $0.pending.insert(key) } }
    func isPending(_ key: KeychainItemKey) -> Bool { state.withLock { $0.pending.contains(key) } }
}

final class KeychainMigrationTests: XCTestCase {
    private let key = KeychainItemKey(service: "red.forbes.sounding.account-data-vault", account: "111")
    private let secret = Data(repeating: 7, count: 32)
    private let denied = OSStatus(errSecAuthFailed)

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    // MARK: - Plan

    func testModernPresentWinsWithoutLegacy() {
        XCTAssertFalse(KeychainMigrationPlan.shouldConsultLegacy(modern: .present(secret), settled: false, deniedThisLaunch: false))
        XCTAssertEqual(KeychainMigrationPlan.step(modern: .present(secret), legacy: nil), .useModern(secret))
        XCTAssertEqual(KeychainMigrationPlan.step(modern: .present(secret), legacy: .present(Data([1]))), .useModern(secret))
    }

    func testModernAbsentLegacyPresentCopies() {
        XCTAssertTrue(KeychainMigrationPlan.shouldConsultLegacy(modern: .absent, settled: false, deniedThisLaunch: false))
        XCTAssertEqual(KeychainMigrationPlan.step(modern: .absent, legacy: .present(secret)), .copyLegacy(secret))
    }

    func testBothAbsentSettlesAsMissing() {
        XCTAssertEqual(KeychainMigrationPlan.step(modern: .absent, legacy: .absent), .settleMissing)
    }

    func testSettledKeyNeverConsultsLegacy() {
        XCTAssertFalse(KeychainMigrationPlan.shouldConsultLegacy(modern: .absent, settled: true, deniedThisLaunch: false))
        XCTAssertEqual(KeychainMigrationPlan.step(modern: .absent, legacy: nil), .missing)
    }

    func testDeniedLegacyRetriesLaterInsteadOfMissing() {
        XCTAssertEqual(KeychainMigrationPlan.step(modern: .absent, legacy: .failed(denied)), .retryLater(denied))
        XCTAssertFalse(KeychainMigrationPlan.shouldConsultLegacy(modern: .absent, settled: false, deniedThisLaunch: true))
    }

    func testModernFailureIsReportedNotMigrated() {
        XCTAssertFalse(KeychainMigrationPlan.shouldConsultLegacy(modern: .failed(errSecInteractionNotAllowed), settled: false, deniedThisLaunch: false))
        XCTAssertEqual(KeychainMigrationPlan.step(modern: .failed(errSecInteractionNotAllowed), legacy: nil), .report(errSecInteractionNotAllowed))
    }

    func testCopyOutcomeNeedsWriteAndMatchingReadBack() {
        XCTAssertEqual(KeychainMigrationPlan.outcome(writeStatus: errSecSuccess, readBack: .present(secret), expected: secret), .verified)
        XCTAssertEqual(KeychainMigrationPlan.outcome(writeStatus: errSecSuccess, readBack: .absent, expected: secret), .unverified)
        XCTAssertEqual(KeychainMigrationPlan.outcome(writeStatus: errSecSuccess, readBack: .present(Data([1])), expected: secret), .unverified)
        XCTAssertEqual(KeychainMigrationPlan.outcome(writeStatus: errSecMissingEntitlement, readBack: .absent, expected: secret), .unverified)
    }

    // MARK: - Backend

    func testLegacyItemMovesAndIsDeletedOnlyAfterVerification() {
        let modern = FakeKeychain()
        let legacy = FakeKeychain()
        let ledger = MemoryLedger()
        legacy.seed(secret, key)
        let keychain = MigratingKeychainBackend(modern: modern, legacy: legacy, ledger: ledger)

        XCTAssertEqual(keychain.copyData(query), .present(secret))
        XCTAssertEqual(modern.value(key), secret)
        XCTAssertNil(legacy.value(key))
        XCTAssertTrue(ledger.isSettled(key))

        let legacyReads = legacy.reads
        XCTAssertEqual(keychain.copyData(query), .present(secret))
        XCTAssertEqual(legacy.reads, legacyReads)
    }

    func testFailedCopyKeepsLegacyAndServesItThisLaunch() {
        let modern = FakeKeychain()
        let legacy = FakeKeychain()
        let ledger = MemoryLedger()
        legacy.seed(secret, key)
        modern.failWrites(errSecMissingEntitlement)
        let keychain = MigratingKeychainBackend(modern: modern, legacy: legacy, ledger: ledger)

        XCTAssertEqual(keychain.copyData(query), .present(secret))
        XCTAssertEqual(legacy.value(key), secret)
        XCTAssertFalse(ledger.isSettled(key))
        XCTAssertTrue(ledger.isPending(key))

        let legacyReads = legacy.reads
        XCTAssertEqual(keychain.copyData(query), .present(secret))
        XCTAssertEqual(legacy.reads, legacyReads)
    }

    func testDeniedLegacyReadFailsWithoutMintingAndAsksOncePerLaunch() {
        let modern = FakeKeychain()
        let legacy = FakeKeychain()
        let ledger = MemoryLedger()
        legacy.seed(secret, key)
        legacy.failReads(denied)
        let keychain = MigratingKeychainBackend(modern: modern, legacy: legacy, ledger: ledger)

        XCTAssertEqual(keychain.copyData(query), .failed(denied))
        XCTAssertEqual(keychain.copyData(query), .failed(denied))
        XCTAssertEqual(legacy.reads, 1)
        XCTAssertNil(modern.value(key))
        XCTAssertEqual(legacy.value(key), secret)
        XCTAssertTrue(ledger.isPending(key))
        XCTAssertFalse(ledger.isSettled(key))

        legacy.failReads(nil)
        let nextLaunch = MigratingKeychainBackend(modern: modern, legacy: legacy, ledger: ledger)
        XCTAssertEqual(nextLaunch.copyData(query), .present(secret))
        XCTAssertEqual(modern.value(key), secret)
        XCTAssertFalse(ledger.isPending(key))
    }

    func testNothingAnywhereSettlesAndStopsAskingLegacy() {
        let modern = FakeKeychain()
        let legacy = FakeKeychain()
        let ledger = MemoryLedger()
        let keychain = MigratingKeychainBackend(modern: modern, legacy: legacy, ledger: ledger)

        XCTAssertEqual(keychain.copyData(query), .absent)
        XCTAssertTrue(ledger.isSettled(key))
        XCTAssertEqual(keychain.copyData(query), .absent)
        XCTAssertEqual(legacy.reads, 1)
    }

    func testDeleteRemovesLegacySoItCannotComeBack() {
        let modern = FakeKeychain()
        let legacy = FakeKeychain()
        let ledger = MemoryLedger()
        legacy.seed(secret, key)
        let keychain = MigratingKeychainBackend(modern: modern, legacy: legacy, ledger: ledger)

        XCTAssertEqual(keychain.delete(query), errSecSuccess)
        XCTAssertNil(legacy.value(key))
        XCTAssertTrue(ledger.isSettled(key))
        XCTAssertEqual(keychain.copyData(query), .absent)
    }

    func testMemoryOverlayNeverWritesThrough() {
        let underlying = FakeKeychain()
        underlying.seed(secret, key)
        let overlay = MemoryKeychainBackend(underlying: underlying)

        XCTAssertEqual(overlay.copyData(query), .present(secret))
        XCTAssertEqual(overlay.delete(query), errSecSuccess)
        XCTAssertEqual(overlay.copyData(query), .absent)
        XCTAssertEqual(underlying.value(key), secret)
        XCTAssertEqual(underlying.deletes, 0)

        var attributes = query
        attributes.removeValue(forKey: kSecReturnData as String)
        attributes.removeValue(forKey: kSecMatchLimit as String)
        attributes[kSecValueData as String] = Data([9])
        XCTAssertEqual(overlay.add(attributes), errSecSuccess)
        XCTAssertEqual(overlay.copyData(query), .present(Data([9])))
        XCTAssertEqual(underlying.value(key), secret)
    }

    func testHarnessAndTestHostDetection() {
        XCTAssertTrue(KeychainEnvironment.isSnapshotHarness(["SOUNDING_TV_MAC_ROOT_SNAPSHOT": "-"]))
        XCTAssertTrue(KeychainEnvironment.isSnapshotHarness(["SOUNDING_TV_MAC_ROOT_SNAPSHOT_SHEET": "queue-panel"]))
        XCTAssertTrue(KeychainEnvironment.isSnapshotHarness(["SOUNDING_TV_MAC_DJ_SHEET": "mixer"]))
        XCTAssertFalse(KeychainEnvironment.isSnapshotHarness(["SOUNDING_TV_MAC_TAB": "home"]))
        XCTAssertTrue(KeychainEnvironment.isTestHost([:]))
    }
}
