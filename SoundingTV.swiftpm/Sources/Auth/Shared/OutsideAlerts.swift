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
    static let signInRequestCategory = "SIGN_IN_REQUEST"
    static let linkAction = "SIGN_IN_REQUEST_LINK"
    static let notNowAction = "SIGN_IN_REQUEST_NOT_NOW"
    static let nearbyLinkAction = "LINK_REQUEST_LINK"
    static let nearbyNotNowAction = "LINK_REQUEST_NOT_NOW"
    static let showDevicesAction = "ACCOUNT_SIGN_IN_SHOW_DEVICES"
    static let withdrawalSubscriptionID = "signin-requests-gone-v2"
    static let withdrawalSubscriptionIDs: Set<String> = [
        withdrawalSubscriptionID,
        "signin-requests-gone-v1",
        NearbyLinkRequest.withdrawalSubscriptionID,
    ]
    static let legacySubscriptionIDs: Set<String> = [
        "signin-requests-v1",
        "signin-requests-gone-v1",
        "account-signins-v1",
    ]

    private static let subscriptionCheckKey = "outsideAlertSubscriptions.v2"
    private static let subscriptionCheckSpacing: TimeInterval = 24 * 3_600
    private static let signInRecordPrefix = "signin-"

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
        let check = UserDefaults.standard.dictionary(forKey: subscriptionCheckKey) ?? [:]
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
            if !missing.isEmpty || !obsolete.isEmpty {
                let results = try await database.modifySubscriptions(saving: missing, deleting: obsolete)
                for (id, result) in results.saveResults {
                    guard case .failure(let error) = result else { continue }
                    complete = false
                    Log.link.info("[OutsideAlerts] \(id, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
                }
                Log.link.info("[OutsideAlerts] saved \(missing.count, privacy: .public) subscriptions, removed \(obsolete.count, privacy: .public) old ones")
            }
            guard complete else { return }
            UserDefaults.standard.set(["build": build, "checkedAt": now.timeIntervalSince1970], forKey: subscriptionCheckKey)
        } catch {
            Log.link.info("[OutsideAlerts] subscriptions not checked: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func subscriptions() -> [CKQuerySubscription] {
        let requests = CKQuerySubscription(
            recordType: SignInRequest.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: SignInRequest.subscriptionID,
            options: [.firesOnRecordCreation]
        )
        let requestInfo = CKSubscription.NotificationInfo()
        requestInfo.titleLocalizationKey = SignInRequest.titleKey
        requestInfo.titleLocalizationArgs = [SignInRequest.Field.tvName]
        requestInfo.alertLocalizationKey = SignInRequest.bodyKey
        requestInfo.soundName = "default"
        requestInfo.desiredKeys = SignInRequest.Field.all
        requestInfo.collapseIDKey = SignInRequest.Field.rendezvous
        requestInfo.category = signInRequestCategory
        requestInfo.shouldSendMutableContent = true
        requests.notificationInfo = requestInfo

        let withdrawals = CKQuerySubscription(
            recordType: SignInRequest.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: withdrawalSubscriptionID,
            options: [.firesOnRecordDeletion]
        )
        let withdrawalInfo = CKSubscription.NotificationInfo()
        withdrawalInfo.shouldSendContentAvailable = true
        withdrawals.notificationInfo = withdrawalInfo

        let signIns = CKQuerySubscription(
            recordType: AccountSignIn.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: AccountSignIn.subscriptionID,
            options: [.firesOnRecordCreation]
        )
        let signInInfo = CKSubscription.NotificationInfo()
        signInInfo.titleLocalizationKey = AccountSignIn.titleKey
        signInInfo.alertLocalizationKey = AccountSignIn.bodyKey
        signInInfo.alertLocalizationArgs = [AccountSignIn.Field.deviceName]
        signInInfo.soundName = "default"
        signInInfo.desiredKeys = AccountSignIn.Field.all
        signInInfo.collapseIDKey = AccountSignIn.Field.collapse
        signInInfo.category = AccountSignIn.category
        signInInfo.shouldSendMutableContent = true
        signIns.notificationInfo = signInInfo

        let links = CKQuerySubscription(
            recordType: NearbyLinkRequest.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: NearbyLinkRequest.subscriptionID,
            options: [.firesOnRecordCreation]
        )
        let linkInfo = CKSubscription.NotificationInfo()
        linkInfo.titleLocalizationKey = NearbyLinkRequest.titleKey
        linkInfo.titleLocalizationArgs = [NearbyLinkRequest.Field.tvName]
        linkInfo.alertLocalizationKey = NearbyLinkRequest.bodyKey
        linkInfo.soundName = "default"
        linkInfo.desiredKeys = NearbyLinkRequest.Field.all
        linkInfo.collapseIDKey = NearbyLinkRequest.Field.tvTag
        linkInfo.category = NearbyLinkRequest.category
        linkInfo.shouldSendMutableContent = true
        links.notificationInfo = linkInfo

        let linkWithdrawals = CKQuerySubscription(
            recordType: NearbyLinkRequest.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: NearbyLinkRequest.withdrawalSubscriptionID,
            options: [.firesOnRecordDeletion]
        )
        let linkWithdrawalInfo = CKSubscription.NotificationInfo()
        linkWithdrawalInfo.shouldSendContentAvailable = true
        linkWithdrawals.notificationInfo = linkWithdrawalInfo

        return [requests, withdrawals, signIns, links, linkWithdrawals]
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
            if let link = NearbyLinkRequest(remoteNotification: userInfo) { return link.recordName == recordName }
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
        let matching = delivered.filter { NearbyLinkRequest(remoteNotification: $0.request.content.userInfo)?.tvTag == tvTag }
        guard !matching.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: matching.map(\.request.identifier))
    }

    static func snooze(_ request: NearbyLinkRequest, now: Date = .now) async {
        await removeDeliveredLinkRequests(tvTag: request.tvTag)
        guard CloudSyncEngineController.containerIdentifierIsEntitled(CloudSyncContainer.identifier) else { return }
        let container = CKContainer(identifier: CloudSyncContainer.identifier)
        guard (try? await container.accountStatus()) == .available else { return }
        let snooze = NearbyLinkSnooze(tvTag: request.tvTag, snoozedAt: now)
        do {
            _ = try await container.privateCloudDatabase.modifyRecords(
                saving: [snooze.record()],
                deleting: [CKRecord.ID(recordName: request.recordName)],
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
            localDeviceId: LinkPeerIdentity.localDeviceId(),
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
    static func tidyDelivered() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let stale = delivered.filter { notification in
            let userInfo = notification.request.content.userInfo
            if let request = SignInRequest(remoteNotification: userInfo) { return request.isExpired() }
            if let link = NearbyLinkRequest(remoteNotification: userInfo) { return verdict(for: link) != .show }
            if let signIn = AccountSignIn(remoteNotification: userInfo) { return verdict(for: signIn) != .show }
            return false
        }
        guard !stale.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: stale.map(\.request.identifier))
    }
}
