import CloudKit
import Combine
import Foundation
import UserNotifications
import os

@MainActor
final class OutsideAlertRoutes: ObservableObject {
    static let shared = OutsideAlertRoutes()

    @Published var showsDevices = false
}

enum OutsideAlerts {
    static let signInRequestCategory = OutsideAlertSubscription.signInRequestCategory
    static let linkAction = "SIGN_IN_REQUEST_LINK"
    static let notNowAction = "SIGN_IN_REQUEST_NOT_NOW"
    static let nearbyLinkAction = "LINK_REQUEST_LINK"
    static let nearbyNotNowAction = "LINK_REQUEST_NOT_NOW"
    static let showDevicesAction = "ACCOUNT_SIGN_IN_SHOW_DEVICES"
    static let withdrawalSubscriptionID = OutsideAlertSubscription.signInWithdrawalID
    static let withdrawalSubscriptionIDs: Set<String> = [
        withdrawalSubscriptionID,
        "signin-requests-gone-v1",
        NearbyLinkRequest.withdrawalSubscriptionID,
    ]
    static let legacySubscriptionIDs = OutsideAlertSubscription.retiredIDs

    private static let subscriptionCheckKey = "outsideAlertSubscriptions.v2"
    private static let subscriptionCheckSpacing: TimeInterval = 24 * 3_600
    private static let signInRecordPrefix = SignInRequest.recordPrefix

    enum Lookup<Value: Sendable>: Sendable {
        case found(Value)
        case gone
        case unavailable
    }

    enum Response: Equatable, Sendable {
        case open
        case notNow
        case dismissed
    }

    static func response(for actionIdentifier: String) -> Response {
        switch actionIdentifier {
        case UNNotificationDismissActionIdentifier: return .dismissed
        case notNowAction, nearbyNotNowAction: return .notNow
        default: return .open
        }
    }

    // MARK: - Categories

    static func registerCategories() async {
        let center = UNUserNotificationCenter.current()
        let ours: Set<UNNotificationCategory> = [
            UNNotificationCategory(
                identifier: signInRequestCategory,
                actions: [
                    UNNotificationAction(identifier: linkAction, title: String(localized: "Link"), options: [.foreground]),
                    UNNotificationAction(identifier: notNowAction, title: String(localized: "Not Now"), options: []),
                ],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: NearbyLinkRequest.category,
                actions: [
                    UNNotificationAction(identifier: nearbyLinkAction, title: String(localized: "Link"), options: [.foreground]),
                    UNNotificationAction(identifier: nearbyNotNowAction, title: String(localized: "Not Now"), options: []),
                ],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: AccountSignIn.category,
                actions: [
                    UNNotificationAction(identifier: showDevicesAction, title: String(localized: "Show Devices"), options: [.foreground]),
                ],
                intentIdentifiers: [],
                options: []
            ),
        ]
        let ids = Set(ours.map(\.identifier))
        let existing = await center.notificationCategories()
        center.setNotificationCategories(existing.filter { !ids.contains($0.identifier) }.union(ours))
    }

    // MARK: - Subscriptions

    static func ensureSubscriptions(now: Date = .now) async {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let check = UserDefaults.sounding.dictionary(forKey: subscriptionCheckKey) ?? [:]
        if check["build"] as? String == build,
           let checkedAt = check["checkedAt"] as? Double,
           now.timeIntervalSince1970 >= checkedAt,
           now.timeIntervalSince1970 - checkedAt < subscriptionCheckSpacing { return }
        guard CloudSyncEngineController.containerIdentifierIsEntitled(CloudSyncContainer.identifier) else { return }
        let container = CKContainer(identifier: CloudSyncContainer.identifier)
        guard (try? await container.accountStatus()) == .available else { return }
        let database = container.privateCloudDatabase
        let wanted = subscriptions()
        do {
            let existing = Set(try await database.allSubscriptions().map(\.subscriptionID))
            let missing = wanted.filter { !existing.contains($0.subscriptionID) }
            let obsolete = existing.intersection(legacySubscriptionIDs).sorted()
            var complete = true
            if !missing.isEmpty {
                let results = try await database.modifySubscriptions(saving: missing, deleting: [])
                for (id, result) in results.saveResults {
                    guard case .failure(let error) = result else { continue }
                    complete = false
                    Log.link.info("[OutsideAlerts] \(id, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
                }
                Log.link.info("[OutsideAlerts] saved \(missing.count, privacy: .public) subscriptions")
            }
            guard complete else { return }
            if !obsolete.isEmpty {
                _ = try await database.modifySubscriptions(saving: [], deleting: obsolete)
                Log.link.info("[OutsideAlerts] removed \(obsolete.count, privacy: .public) old subscriptions")
            }
            UserDefaults.sounding.set(["build": build, "checkedAt": now.timeIntervalSince1970], forKey: subscriptionCheckKey)
        } catch {
            Log.link.info("[OutsideAlerts] subscriptions not checked: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func subscriptions() -> [CKQuerySubscription] {
        OutsideAlertSubscription.all.map(\.querySubscription)
    }

    // MARK: - Records behind a notification

    static func linkRequest(for notice: NearbyLinkRequest.Notice) async -> Lookup<NearbyLinkRequest> {
        await linkRequests(for: [notice])[notice.recordName] ?? .unavailable
    }

    static func signIn(for notice: AccountSignIn.Notice) async -> Lookup<AccountSignIn> {
        await signIns(for: [notice])[notice.recordName] ?? .unavailable
    }

    static func linkRequests(for notices: [NearbyLinkRequest.Notice]) async -> [String: Lookup<NearbyLinkRequest>] {
        await fetch(notices.map { RecordReference(recordName: $0.recordName, zoneName: $0.zoneName, ownerName: $0.ownerName) }) {
            NearbyLinkRequest(record: $0)
        }
    }

    static func signIns(for notices: [AccountSignIn.Notice]) async -> [String: Lookup<AccountSignIn>] {
        await fetch(notices.map { RecordReference(recordName: $0.recordName, zoneName: $0.zoneName, ownerName: $0.ownerName) }) {
            AccountSignIn(record: $0)
        }
    }

    private struct RecordReference: Hashable, Sendable {
        let recordName: String
        let zoneName: String
        let ownerName: String

        init(recordName: String, zoneName: String, ownerName: String) {
            self.recordName = recordName
            self.zoneName = zoneName
            self.ownerName = ownerName
        }

        init(_ recordID: CKRecord.ID) {
            self.init(recordName: recordID.recordName, zoneName: recordID.zoneID.zoneName, ownerName: recordID.zoneID.ownerName)
        }

        var recordID: CKRecord.ID {
            CKRecord.ID(recordName: recordName, zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName))
        }
    }

    private enum AlertRecord: Sendable {
        case signInRequest(SignInRequest)
        case nearbyLink(NearbyLinkRequest)
        case accountSignIn(AccountSignIn)

        init?(_ record: CKRecord) {
            switch record.recordType {
            case SignInRequest.recordType:
                guard let request = SignInRequest(record: record) else { return nil }
                self = .signInRequest(request)
            case NearbyLinkRequest.recordType:
                guard let request = NearbyLinkRequest(record: record) else { return nil }
                self = .nearbyLink(request)
            case AccountSignIn.recordType:
                guard let signIn = AccountSignIn(record: record) else { return nil }
                self = .accountSignIn(signIn)
            default:
                return nil
            }
        }
    }

    @concurrent
    private static func fetch<Value: Sendable>(
        _ references: [RecordReference],
        decode: @Sendable (CKRecord) -> Value?
    ) async -> [String: Lookup<Value>] {
        let references = Array(Set(references))
        guard !references.isEmpty,
              CloudSyncEngineController.containerIdentifierIsEntitled(CloudSyncContainer.identifier) else { return [:] }
        let container = CKContainer(identifier: CloudSyncContainer.identifier)
        guard (try? await container.accountStatus()) == .available else { return [:] }
        do {
            let results = try await container.privateCloudDatabase.records(for: references.map(\.recordID))
            var lookups: [String: Lookup<Value>] = [:]
            for (id, result) in results {
                switch result {
                case .success(let record):
                    lookups[id.recordName] = decode(record).map { Lookup<Value>.found($0) } ?? .gone
                case .failure(let error as CKError) where error.code == .unknownItem:
                    lookups[id.recordName] = .gone
                case .failure(let error):
                    lookups[id.recordName] = .unavailable
                    Log.link.info("[OutsideAlerts] record not read: \(error.localizedDescription, privacy: .public)")
                }
            }
            return lookups
        } catch {
            Log.link.info("[OutsideAlerts] records not read: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    // MARK: - Delivered notifications

    static func withdrawnRecordName(from userInfo: [AnyHashable: Any]) -> String? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let subscriptionID = notification.subscriptionID,
              withdrawalSubscriptionIDs.contains(subscriptionID),
              notification.queryNotificationReason == .recordDeleted,
              let name = notification.recordID?.recordName,
              name.hasPrefix(signInRecordPrefix) || name.hasPrefix(NearbyLinkRequest.recordPrefix) else { return nil }
        return name
    }

    static func withdrawRequest(recordName: String) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let matching = delivered.filter { notification in
            let userInfo = notification.request.content.userInfo
            if let link = NearbyLinkRequest.Notice(remoteNotification: userInfo) { return link.recordName == recordName }
            guard let query = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
                  let subscriptionID = query.subscriptionID,
                  SignInRequest.subscriptionIDs.contains(subscriptionID) else { return false }
            if query.recordID?.recordName == recordName { return true }
            return SignInRequest(remoteNotification: userInfo).map { $0.recordName == recordName } ?? false
        }
        guard !matching.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: matching.map(\.request.identifier))
    }

    static func removeDeliveredLinkRequests(tvTag: String) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let matching = delivered.filter { NearbyLinkRequest.Notice(remoteNotification: $0.request.content.userInfo)?.tvTag == tvTag }
        guard !matching.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: matching.map(\.request.identifier))
    }

    static func snooze(_ notice: NearbyLinkRequest.Notice, now: Date = .now) async {
        guard let tvTag = notice.tvTag else { return }
        await removeDeliveredLinkRequests(tvTag: tvTag)
        guard CloudSyncEngineController.containerIdentifierIsEntitled(CloudSyncContainer.identifier) else { return }
        let container = CKContainer(identifier: CloudSyncContainer.identifier)
        guard (try? await container.accountStatus()) == .available else { return }
        let snooze = NearbyLinkSnooze(tvTag: tvTag, snoozedAt: now)
        do {
            _ = try await container.privateCloudDatabase.modifyRecords(
                saving: [snooze.record()],
                deleting: [notice.recordID],
                savePolicy: .allKeys,
                atomically: false
            )
        } catch {
            Log.link.info("[OutsideAlerts] Not Now not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    static func verdict(for request: NearbyLinkRequest, now: Date = .now) -> NearbyLinkRequest.Verdict {
        let credentials = SoundCloudCredentialSource.shared
        let linked = SameAccountLinkModel.linkedIdentities()
        return request.verdict(
            localDeviceId: LinkPeerIdentity.localDeviceId(defaults: .sounding),
            currentUserId: credentials.currentUser?.id,
            isSignedOut: credentials.isSignedOut,
            linkedIdentities: linked,
            now: now
        )
    }

    @MainActor
    static func verdict(for signIn: AccountSignIn) -> AccountSignIn.Verdict {
        let credentials = SoundCloudCredentialSource.shared
        return signIn.verdict(
            localDeviceId: DownloadManifestDeviceIdentity.deviceId(),
            currentUserId: credentials.currentUser?.id,
            isSignedOut: credentials.isSignedOut
        )
    }

    @MainActor
    static func tidyDelivered(resolvedDevices: Set<String> = [], now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        var references: [String: RecordReference] = [:]
        var alerts: [DeliveredOutsideAlert] = []
        for notification in await center.deliveredNotifications() {
            guard let alert = deliveredAlert(notification, references: &references) else { continue }
            alerts.append(alert)
        }
        guard !alerts.isEmpty else { return }
        let lookups = alerts
            .filter { OutsideAlertSweep.needsRecord($0, now: now, resolvedDevices: resolvedDevices) }
            .compactMap { references[$0.recordName] }
        var records: [String: OutsideAlertSweep.RecordState] = [:]
        if !lookups.isEmpty {
            for (name, lookup) in await fetch(lookups, decode: { AlertRecord($0) }) {
                switch lookup {
                case .found(let record): records[name] = state(of: record, now: now)
                case .gone: records[name] = .gone
                case .unavailable: break
                }
            }
        }
        let stale = OutsideAlertSweep.stale(alerts, now: now, records: records, resolvedDevices: resolvedDevices)
        guard !stale.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: Array(stale))
        Log.link.info("[OutsideAlerts] cleared \(stale.count, privacy: .public) alerts that no longer apply")
    }

    @MainActor
    private static func state(of record: AlertRecord, now: Date) -> OutsideAlertSweep.RecordState {
        switch record {
        case .signInRequest(let request):
            return request.isExpired(at: now) ? .resolved : .live
        case .nearbyLink(let request):
            return verdict(for: request, now: now) == .show ? .live : .resolved
        case .accountSignIn(let signIn):
            return verdict(for: signIn) == .show ? .live : .resolved
        }
    }

    private static func deliveredAlert(_ notification: UNNotification, references: inout [String: RecordReference]) -> DeliveredOutsideAlert? {
        let id = notification.request.identifier
        let userInfo = notification.request.content.userInfo
        if let notice = NearbyLinkRequest.Notice(remoteNotification: userInfo) {
            references[notice.recordName] = RecordReference(notice.recordID)
            return DeliveredOutsideAlert(
                id: id,
                kind: .nearbyLink,
                recordName: notice.recordName,
                device: OutsideAlertSweep.device(name: notice.tvName, kind: notice.tvKind),
                expiresAt: notice.expiresAt,
                deliveredAt: notification.date
            )
        }
        if let notice = AccountSignIn.Notice(remoteNotification: userInfo) {
            references[notice.recordName] = RecordReference(notice.recordID)
            return DeliveredOutsideAlert(
                id: id,
                kind: .accountSignIn,
                recordName: notice.recordName,
                createdAt: notice.createdAt,
                deliveredAt: notification.date
            )
        }
        guard let query = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let subscriptionID = query.subscriptionID,
              SignInRequest.subscriptionIDs.contains(subscriptionID),
              let recordID = query.recordID,
              recordID.recordName.hasPrefix(SignInRequest.recordPrefix) else { return nil }
        references[recordID.recordName] = RecordReference(recordID)
        let request = SignInRequest(remoteNotification: userInfo)
        return DeliveredOutsideAlert(
            id: id,
            kind: .signInRequest,
            recordName: recordID.recordName,
            device: request.flatMap { OutsideAlertSweep.device(name: $0.tvName, kind: $0.tvKind) },
            createdAt: request?.createdAt,
            expiresAt: request?.expiresAt,
            deliveredAt: notification.date
        )
    }
}

@MainActor
final class OutsideAlertSweeper {
    static let shared = OutsideAlertSweeper()

    private var subscriptions: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?

    func install() {
        guard subscriptions.isEmpty else { return }
        LinkClient.transfers
            .filter { $0.state == .completed }
            .sink { [weak self] transfer in self?.linked(sessionId: transfer.sessionId) }
            .store(in: &subscriptions)
        SoundCloudCredentialSource.shared.$state
            .map { $0.currentUser?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.sweep() }
            .store(in: &subscriptions)
    }

    func sweep(resolvedDevices: Set<String> = []) {
        let previous = pending
        pending = Task {
            await previous?.value
            await OutsideAlerts.tidyDelivered(resolvedDevices: resolvedDevices)
        }
    }

    private func linked(sessionId: String) {
        let identities = LinkedCompanionStore.loadAll()
            .filter { $0.sessionId == sessionId }
            .map { SameAccountLinkOffer.identity(name: $0.peerName, kind: $0.peerClass) }
        sweep(resolvedDevices: Set(identities))
    }
}

extension OutsideAlertSubscription {
    var querySubscription: CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: id,
            options: trigger == .creation ? [.firesOnRecordCreation] : [.firesOnRecordDeletion]
        )
        let info = CKSubscription.NotificationInfo()
        if isVisible {
            info.titleLocalizationKey = titleKey
            info.titleLocalizationArgs = titleArgs.isEmpty ? nil : titleArgs
            info.alertLocalizationKey = alertKey
            info.alertLocalizationArgs = alertArgs.isEmpty ? nil : alertArgs
            info.soundName = "default"
            info.desiredKeys = desiredKeys
            info.collapseIDKey = collapseIDKey
            info.category = category
            info.shouldSendMutableContent = true
        } else {
            info.shouldSendContentAvailable = true
        }
        subscription.notificationInfo = info
        return subscription
    }
}
