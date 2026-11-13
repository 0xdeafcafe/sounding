import Foundation
import Security
import Synchronization

enum KeychainLookup: Equatable, Sendable {
    case present(Data)
    case absent
    case failed(OSStatus)

    init(status: OSStatus, item: CFTypeRef?) {
        switch status {
        case errSecSuccess:
            if let data = item as? Data {
                self = .present(data)
            } else {
                self = .failed(errSecDecode)
            }
        case errSecItemNotFound:
            self = .absent
        default:
            self = .failed(status)
        }
    }
}

protocol KeychainBackend: Sendable {
    func copyData(_ query: [String: Any]) -> KeychainLookup
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

enum SoundingKeychain {
    static let backend: any KeychainBackend = KeychainEnvironment.makeBackend()

    static var isDurable: Bool { !(backend is MemoryKeychainBackend) }

    static func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus {
        switch backend.copyData(BuildFlavor.current.keychainQuery(query)) {
        case .present(let data):
            result = data as CFData
            return errSecSuccess
        case .absent:
            result = nil
            return errSecItemNotFound
        case .failed(let status):
            result = nil
            return status
        }
    }

    static func copyData(_ query: [String: Any]) -> KeychainLookup {
        backend.copyData(BuildFlavor.current.keychainQuery(query))
    }

    static func add(_ attributes: [String: Any]) -> OSStatus {
        backend.add(BuildFlavor.current.keychainQuery(attributes))
    }

    static func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        backend.update(BuildFlavor.current.keychainQuery(query), BuildFlavor.current.keychainQuery(changes))
    }

    @discardableResult
    static func delete(_ query: [String: Any]) -> OSStatus {
        backend.delete(BuildFlavor.current.keychainQuery(query))
    }
}

// MARK: - Environment

enum KeychainEnvironment {
    static let harnessVariables: Set<String> = [
        "SOUNDING_TV_MAC_DJ_SHEET",
        "SOUNDING_TV_MAC_DJ_PAGE",
        "SOUNDING_TV_MAC_DJ_PLAYERS_SNAPSHOT",
    ]

    static func isSnapshotHarness(_ environment: [String: String]) -> Bool {
        environment.keys.contains { $0.hasPrefix("SOUNDING_TV_MAC_ROOT_SNAPSHOT") || harnessVariables.contains($0) }
    }

    static func isTestHost(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static func makeBackend() -> any KeychainBackend {
        #if os(macOS)
        let environment = ProcessInfo.processInfo.environment
        if isTestHost(environment) || !isTeamSigned() {
            return MemoryKeychainBackend(underlying: nil)
        }
        let modern = SystemKeychainBackend(dataProtection: true)
        if isSnapshotHarness(environment) {
            return MemoryKeychainBackend(underlying: modern)
        }
        return MigratingKeychainBackend(
            modern: modern,
            legacy: SystemKeychainBackend(dataProtection: false),
            ledger: DefaultsKeychainMigrationLedger()
        )
        #else
        return SystemKeychainBackend(dataProtection: true)
        #endif
    }

    #if os(macOS)
    static func isTeamSigned() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess,
            let info = information as? [String: Any] else { return false }
        let adhocFlag: UInt32 = 0x0002
        if let flags = info[kSecCodeInfoFlags as String] as? NSNumber, flags.uint32Value & adhocFlag != 0 {
            return false
        }
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        return !team.isEmpty
    }
    #endif
}

// MARK: - System

struct SystemKeychainBackend: KeychainBackend {
    let dataProtection: Bool

    func prepared(_ query: [String: Any]) -> [String: Any] {
        var query = query
        #if os(macOS)
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        } else {
            query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            query.removeValue(forKey: kSecAttrAccessGroup as String)
        }
        #endif
        return query
    }

    func copyData(_ query: [String: Any]) -> KeychainLookup {
        var query = prepared(query)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return KeychainLookup(status: status, item: item)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(prepared(attributes) as CFDictionary, nil)
    }

    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        SecItemUpdate(prepared(query) as CFDictionary, changes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(prepared(query) as CFDictionary)
    }
}

// MARK: - Memory

struct KeychainItemKey: Hashable, Sendable {
    let service: String
    let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    init?(_ query: [String: Any]) {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else { return nil }
        self.init(service: service, account: account)
    }

    var ledgerKey: String { "\(service)|\(account)" }
}

final class MemoryKeychainBackend: KeychainBackend {
    private struct Entry: Sendable {
        let service: String
        let account: String
        let group: String?
        var data: Data
    }

    private struct State: Sendable {
        var entries: [Entry] = []
        var hiddenItems: Set<KeychainItemKey> = []
        var hiddenServices: Set<String> = []
    }

    private let underlying: (any KeychainBackend)?
    private let state = Mutex(State())

    init(underlying: (any KeychainBackend)?) {
        self.underlying = underlying
    }

    private static func matches(_ entry: Entry, _ query: [String: Any]) -> Bool {
        if let service = query[kSecAttrService as String] as? String, service != entry.service { return false }
        if let account = query[kSecAttrAccount as String] as? String, account != entry.account { return false }
        if let group = query[kSecAttrAccessGroup as String] as? String, let entryGroup = entry.group, group != entryGroup {
            return false
        }
        return true
    }

    private static func isHidden(_ query: [String: Any], in state: State) -> Bool {
        if let service = query[kSecAttrService as String] as? String, state.hiddenServices.contains(service) { return true }
        if let key = KeychainItemKey(query), state.hiddenItems.contains(key) { return true }
        return false
    }

    func copyData(_ query: [String: Any]) -> KeychainLookup {
        let local: KeychainLookup? = state.withLock { state in
            if let entry = state.entries.first(where: { Self.matches($0, query) }) {
                return .present(entry.data)
            }
            if underlying == nil || Self.isHidden(query, in: state) { return .absent }
            return nil
        }
        if let local { return local }
        return underlying?.copyData(query) ?? .absent
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        guard let key = KeychainItemKey(attributes),
              let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        let group = attributes[kSecAttrAccessGroup as String] as? String
        return state.withLock { state in
            if state.entries.contains(where: { $0.service == key.service && $0.account == key.account && $0.group == group }) {
                return errSecDuplicateItem
            }
            state.entries.append(Entry(service: key.service, account: key.account, group: group, data: data))
            state.hiddenItems.insert(key)
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        state.withLock { state in
            var found = false
            for index in state.entries.indices where Self.matches(state.entries[index], query) {
                found = true
                if let data = changes[kSecValueData as String] as? Data {
                    state.entries[index].data = data
                }
            }
            return found ? errSecSuccess : errSecItemNotFound
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        state.withLock { state in
            let before = state.entries.count
            state.entries.removeAll { Self.matches($0, query) }
            if let key = KeychainItemKey(query) {
                state.hiddenItems.insert(key)
            } else if let service = query[kSecAttrService as String] as? String {
                state.hiddenServices.insert(service)
            }
            if underlying != nil { return errSecSuccess }
            return state.entries.count == before ? errSecItemNotFound : errSecSuccess
        }
    }
}

// MARK: - Migration

protocol KeychainMigrationLedger: Sendable {
    func isSettled(_ key: KeychainItemKey) -> Bool
    func settle(_ key: KeychainItemKey)
    func markPending(_ key: KeychainItemKey)
    func isPending(_ key: KeychainItemKey) -> Bool
}

struct DefaultsKeychainMigrationLedger: KeychainMigrationLedger {
    private static let settledKey = "red.forbes.sounding.keychain.legacySettled"
    private static let pendingKey = "red.forbes.sounding.keychain.legacyPending"

    private func list(_ name: String) -> [String] {
        UserDefaults.sounding.stringArray(forKey: name) ?? []
    }

    func isSettled(_ key: KeychainItemKey) -> Bool {
        list(Self.settledKey).contains(key.ledgerKey)
    }

    func settle(_ key: KeychainItemKey) {
        var settled = list(Self.settledKey)
        if !settled.contains(key.ledgerKey) {
            settled.append(key.ledgerKey)
            UserDefaults.sounding.set(settled, forKey: Self.settledKey)
        }
        let pending = list(Self.pendingKey).filter { $0 != key.ledgerKey }
        UserDefaults.sounding.set(pending, forKey: Self.pendingKey)
    }

    func markPending(_ key: KeychainItemKey) {
        var pending = list(Self.pendingKey)
        guard !pending.contains(key.ledgerKey) else { return }
        pending.append(key.ledgerKey)
        UserDefaults.sounding.set(pending, forKey: Self.pendingKey)
    }

    func isPending(_ key: KeychainItemKey) -> Bool {
        list(Self.pendingKey).contains(key.ledgerKey)
    }
}

enum KeychainMigrationPlan {
    enum Step: Equatable, Sendable {
        case useModern(Data)
        case report(OSStatus)
        case missing
        case settleMissing
        case copyLegacy(Data)
        case retryLater(OSStatus)
    }

    enum CopyOutcome: Equatable, Sendable {
        case verified
        case unverified
    }

    static func shouldConsultLegacy(modern: KeychainLookup, settled: Bool, deniedThisLaunch: Bool) -> Bool {
        guard case .absent = modern else { return false }
        return !settled && !deniedThisLaunch
    }

    static func step(modern: KeychainLookup, legacy: KeychainLookup?) -> Step {
        switch modern {
        case .present(let data):
            return .useModern(data)
        case .failed(let status):
            return .report(status)
        case .absent:
            switch legacy {
            case nil:
                return .missing
            case .absent?:
                return .settleMissing
            case .present(let data)?:
                return .copyLegacy(data)
            case .failed(let status)?:
                return .retryLater(status)
            }
        }
    }

    static func outcome(writeStatus: OSStatus, readBack: KeychainLookup, expected: Data) -> CopyOutcome {
        guard writeStatus == errSecSuccess, readBack == .present(expected) else { return .unverified }
        return .verified
    }
}

final class MigratingKeychainBackend: KeychainBackend {
    private struct State: Sendable {
        var denied: [KeychainItemKey: OSStatus] = [:]
        var unverified: [KeychainItemKey: Data] = [:]
        var legacyOnly = false
    }

    private let modern: any KeychainBackend
    private let legacy: any KeychainBackend
    private let ledger: any KeychainMigrationLedger
    private let state = Mutex(State())

    init(modern: any KeychainBackend, legacy: any KeychainBackend, ledger: any KeychainMigrationLedger) {
        self.modern = modern
        self.legacy = legacy
        self.ledger = ledger
    }

    private static func identity(_ key: KeychainItemKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
        ]
    }

    func copyData(_ query: [String: Any]) -> KeychainLookup {
        state.withLock { state in
            if state.legacyOnly { return legacy.copyData(query) }
            let current = modern.copyData(query)
            if case .failed(errSecMissingEntitlement) = current {
                state.legacyOnly = true
                return legacy.copyData(query)
            }
            guard let key = KeychainItemKey(query) else { return current }
            if case .absent = current, let cached = state.unverified[key] {
                return .present(cached)
            }
            let denied = state.denied[key]
            var legacyLookup: KeychainLookup?
            if KeychainMigrationPlan.shouldConsultLegacy(
                modern: current, settled: ledger.isSettled(key), deniedThisLaunch: denied != nil
            ) {
                legacyLookup = legacy.copyData(Self.identity(key))
            } else if case .absent = current, let denied, !ledger.isSettled(key) {
                legacyLookup = .failed(denied)
            }
            switch KeychainMigrationPlan.step(modern: current, legacy: legacyLookup) {
            case .useModern(let data):
                return .present(data)
            case .report(let status):
                return .failed(status)
            case .missing:
                return .absent
            case .settleMissing:
                ledger.settle(key)
                return .absent
            case .retryLater(let status):
                state.denied[key] = status
                ledger.markPending(key)
                return .failed(status)
            case .copyLegacy(let data):
                var target = Self.identity(key)
                if let group = query[kSecAttrAccessGroup as String] {
                    target[kSecAttrAccessGroup as String] = group
                }
                var attributes = target
                attributes[kSecValueData as String] = data
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                var writeStatus = modern.add(attributes)
                if writeStatus == errSecDuplicateItem {
                    writeStatus = modern.update(target, [kSecValueData as String: data])
                }
                let readBack = modern.copyData(target)
                switch KeychainMigrationPlan.outcome(writeStatus: writeStatus, readBack: readBack, expected: data) {
                case .verified:
                    _ = legacy.delete(Self.identity(key))
                    ledger.settle(key)
                    state.unverified[key] = nil
                case .unverified:
                    state.unverified[key] = data
                    ledger.markPending(key)
                }
                return .present(data)
            }
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        state.withLock { state in
            if state.legacyOnly { return legacy.add(attributes) }
            let status = modern.add(attributes)
            if status == errSecSuccess, let key = KeychainItemKey(attributes) {
                state.unverified[key] = nil
            }
            return status
        }
    }

    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        state.withLock { state in
            if state.legacyOnly { return legacy.update(query, changes) }
            let status = modern.update(query, changes)
            if status == errSecSuccess, let key = KeychainItemKey(query) {
                state.unverified[key] = nil
            }
            return status
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        state.withLock { state in
            if state.legacyOnly { return legacy.delete(query) }
            let status = modern.delete(query)
            guard let key = KeychainItemKey(query) else { return status }
            state.unverified[key] = nil
            state.denied[key] = nil
            if !ledger.isSettled(key) {
                let legacyStatus = legacy.delete(Self.identity(key))
                ledger.settle(key)
                if status == errSecItemNotFound && legacyStatus == errSecSuccess { return errSecSuccess }
            }
            return status
        }
    }
}
