import CloudKit
import Combine
import CryptoKit
import Foundation
import os

#if canImport(UIKit)
import UIKit
#endif

struct AccountSignIn: Codable, Equatable, Hashable, Sendable {
    static let recordType = "AccountSignIn"
    static let subscriptionID = "account-signins-v2"
    static let subscriptionIDs: Set<String> = [subscriptionID, "account-signins-v1"]
    static let category = "ACCOUNT_SIGN_IN"
    static let titleKey = "ACCOUNT_SIGN_IN_TITLE"
    static let bodyKey = "ACCOUNT_SIGN_IN_BODY"
    static let maximumNameLength = 64
    static let freshness: TimeInterval = 24 * 60 * 60

    enum Field {
        static let subject = "subject"
        static let announcer = "announcer"
        static let accountTag = "accountTag"
        static let deviceName = "deviceName"
        static let deviceKind = "deviceKind"
        static let collapse = "collapse"
        static let createdAt = "createdAt"
        static let all = [subject, announcer, accountTag, deviceName, deviceKind, collapse, createdAt]
    }

    enum Verdict: Equatable, Sendable {
        case show
        case own
        case otherAccount
        case stale
    }

    let subject: String
    let announcer: String
    let accountTag: String
    let deviceName: String
    let deviceKind: DeviceClass
    let createdAt: Date

    init?(subject: String, announcer: String, accountTag: String, deviceName: String, deviceKind: DeviceClass, createdAt: Date) {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !subject.isEmpty, !announcer.isEmpty, !accountTag.isEmpty, !name.isEmpty else { return nil }
        self.subject = subject
        self.announcer = announcer
        self.accountTag = accountTag
        self.deviceName = String(name.prefix(Self.maximumNameLength))
        self.deviceKind = deviceKind
        self.createdAt = createdAt
    }

    var recordName: String { "account-signin-\(accountTag)-\(subject)" }
    var ledgerKey: String { "\(accountTag)|\(subject)" }

    var collapseKey: String {
        Self.digest("Sounding-AccountSignIn-Collapse-v1", accountTag, deviceKind.rawValue, deviceName.lowercased(), length: 32)
    }

    static func accountTag(userId: String) -> String {
        digest("Sounding-AccountSignIn-Account-v1", userId, length: 16)
    }

    static func subject(deviceId: String) -> String {
        "d" + digest("Sounding-AccountSignIn-Device-v1", deviceId, length: 24)
    }

    static func subject(linkSessionId: String) -> String {
        "l" + digest("Sounding-AccountSignIn-Link-v1", linkSessionId, length: 24)
    }

    private static func digest(_ parts: String..., length: Int) -> String {
        let hash = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(length))
    }

    func verdict(localDeviceId: String, currentUserId: String?, isSignedOut: Bool, now: Date = .now) -> Verdict {
        let local = Self.subject(deviceId: localDeviceId)
        if announcer == local || subject == local { return .own }
        if isSignedOut { return .otherAccount }
        if let currentUserId, Self.accountTag(userId: currentUserId) != accountTag { return .otherAccount }
        if now.timeIntervalSince(createdAt) > Self.freshness { return .stale }
        return .show
    }

    init?(fields: [String: Any]) {
        guard let subject = fields[Field.subject] as? String,
              let announcer = fields[Field.announcer] as? String,
              let tag = fields[Field.accountTag] as? String,
              let name = fields[Field.deviceName] as? String else { return nil }
        let kind = (fields[Field.deviceKind] as? String).flatMap(DeviceClass.init(rawValue:)) ?? .tv
        self.init(
            subject: subject,
            announcer: announcer,
            accountTag: tag,
            deviceName: name,
            deviceKind: kind,
            createdAt: Self.date(fields[Field.createdAt]) ?? .now
        )
    }

    init?(record: CKRecord) {
        guard record.recordType == Self.recordType else { return nil }
        var fields: [String: Any] = [:]
        for key in Field.all { fields[key] = record[key] }
        self.init(fields: fields)
    }

    init?(remoteNotification userInfo: [AnyHashable: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let subscriptionID = notification.subscriptionID,
              Self.subscriptionIDs.contains(subscriptionID),
              let fields = notification.recordFields else { return nil }
        self.init(fields: fields)
    }

    func record(zone: CKRecordZone.ID = .default) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: recordName, zoneID: zone))
        record[Field.subject] = subject as CKRecordValue
        record[Field.announcer] = announcer as CKRecordValue
        record[Field.accountTag] = accountTag as CKRecordValue
        record[Field.deviceName] = deviceName as CKRecordValue
        record[Field.deviceKind] = deviceKind.rawValue as CKRecordValue
        record[Field.collapse] = collapseKey as CKRecordValue
        record[Field.createdAt] = createdAt as CKRecordValue
        return record
    }

    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
    }
}

@MainActor
final class AccountSignInAnnouncer {
    static let shared = AccountSignInAnnouncer()

    private static let announcedKey = "accountSignIn.announced.v1"
    private static let pendingKey = "accountSignIn.pending.v1"
    private static let installedKey = "accountSignIn.installed.v1"
    private static let capacity = 64

    private enum Outcome: Sendable {
        case saved
        case existed
        case unavailable
        case failed
    }

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private var baselinesFirstUser = false
    private var inFlight: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static var isEnabled: Bool {
        #if DEBUG
        if VisualFixtures.isEnabled { return false }
        if ProcessInfo.processInfo.environment["SOUNDING_TV_SIGNIN_STORY"] != nil { return false }
        #endif
        return CloudSyncEngineController.containerIdentifierIsEntitled(CloudSyncContainer.identifier)
    }

    func install() {
        guard cancellables.isEmpty, Self.isEnabled else { return }
        let isFirstRun = !defaults.bool(forKey: Self.installedKey)
        baselinesFirstUser = isFirstRun && defaults.string(forKey: DownloadManifestDeviceIdentity.defaultsKey) != nil
        defaults.set(true, forKey: Self.installedKey)
        SoundCloudCredentialSource.shared.$state
            .map { $0.currentUser?.id }
            .removeDuplicates()
            .sink { [weak self] userId in
                guard let userId else { return }
                self?.signedIn(userId: userId)
            }
            .store(in: &cancellables)
        #if !os(tvOS)
        LinkClient.transfers
            .filter { $0.state == .completed }
            .sink { [weak self] transfer in self?.linked(sessionId: transfer.sessionId) }
            .store(in: &cancellables)
        #endif
        for signIn in pending where Date.now.timeIntervalSince(signIn.createdAt) < AccountSignIn.freshness {
            announce(signIn)
        }
    }

    static var localName: String {
        #if os(macOS)
        return Host.current().localizedName ?? DeviceClass.current.displayName
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #else
        return DeviceClass.current.displayName
        #endif
    }

    private var localSubject: String {
        AccountSignIn.subject(deviceId: DownloadManifestDeviceIdentity.deviceId(defaults: defaults))
    }

    private func signedIn(userId: String) {
        let own = localSubject
        guard let signIn = AccountSignIn(
            subject: own,
            announcer: own,
            accountTag: AccountSignIn.accountTag(userId: userId),
            deviceName: Self.localName,
            deviceKind: .current,
            createdAt: .now
        ) else { return }
        if baselinesFirstUser {
            baselinesFirstUser = false
            remember(signIn.ledgerKey)
            return
        }
        announce(signIn)
    }

    #if !os(tvOS)
    private func linked(sessionId: String) {
        guard let userId = SoundCloudCredentialSource.shared.currentUser?.id else { return }
        let link = LinkedCompanionStore.loadAll().first { $0.sessionId == sessionId }
        guard let signIn = AccountSignIn(
            subject: AccountSignIn.subject(linkSessionId: sessionId),
            announcer: localSubject,
            accountTag: AccountSignIn.accountTag(userId: userId),
            deviceName: link?.peerName ?? DeviceClass.tv.displayName,
            deviceKind: link?.peerClass ?? .tv,
            createdAt: .now
        ) else { return }
        announce(signIn)
    }
    #endif

    private func announce(_ signIn: AccountSignIn) {
        let key = signIn.ledgerKey
        guard !announced.contains(key), !inFlight.contains(key) else { return }
        inFlight.insert(key)
        enqueue(signIn)
        Task { [weak self] in
            let outcome = await Self.save(signIn)
            self?.finish(signIn, outcome: outcome)
        }
    }

    private func finish(_ signIn: AccountSignIn, outcome: Outcome) {
        inFlight.remove(signIn.ledgerKey)
        switch outcome {
        case .saved, .existed:
            remember(signIn.ledgerKey)
            dequeue(signIn)
            if outcome == .saved {
                Log.link.info("[AccountSignIn] told this account's other devices about a new sign-in")
            }
        case .unavailable:
            dequeue(signIn)
        case .failed:
            break
        }
    }

    private nonisolated static func save(_ signIn: AccountSignIn) async -> Outcome {
        let container = CKContainer(identifier: CloudSyncContainer.identifier)
        let record = signIn.record()
        do {
            guard try await container.accountStatus() == .available else { return .unavailable }
            let results = try await container.privateCloudDatabase.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            ).saveResults
            if case .failure(let error) = results[record.recordID] { throw error }
            return .saved
        } catch let error as CKError where error.code == .serverRecordChanged {
            return .existed
        } catch {
            Log.link.info("[AccountSignIn] not sent: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    private var announced: [String] {
        defaults.stringArray(forKey: Self.announcedKey) ?? []
    }

    private func remember(_ key: String) {
        var keys = announced.filter { $0 != key }
        keys.append(key)
        defaults.set(Array(keys.suffix(Self.capacity)), forKey: Self.announcedKey)
    }

    private var pending: [AccountSignIn] {
        guard let data = defaults.data(forKey: Self.pendingKey),
              let list = try? JSONDecoder().decode([AccountSignIn].self, from: data) else { return [] }
        return list
    }

    private func setPending(_ list: [AccountSignIn]) {
        let fresh = list.filter { Date.now.timeIntervalSince($0.createdAt) < AccountSignIn.freshness }
        if fresh.isEmpty {
            defaults.removeObject(forKey: Self.pendingKey)
        } else if let data = try? JSONEncoder().encode(Array(fresh.suffix(Self.capacity))) {
            defaults.set(data, forKey: Self.pendingKey)
        }
    }

    private func enqueue(_ signIn: AccountSignIn) {
        setPending(pending.filter { $0.ledgerKey != signIn.ledgerKey } + [signIn])
    }

    private func dequeue(_ signIn: AccountSignIn) {
        setPending(pending.filter { $0.ledgerKey != signIn.ledgerKey })
    }
}
