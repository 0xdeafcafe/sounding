import Foundation

struct OutsideAlertSubscription: Equatable, Sendable {
    enum Trigger: Equatable, Sendable {
        case creation
        case deletion
    }

    static let maximumDesiredKeys = 5
    static let signInRequestCategory = "SIGN_IN_REQUEST"
    static let signInWithdrawalID = "signin-requests-gone-v2"

    let id: String
    let recordType: String
    let trigger: Trigger
    var titleKey: String? = nil
    var titleArgs: [String] = []
    var alertKey: String? = nil
    var alertArgs: [String] = []
    var desiredKeys: [String] = []
    var collapseIDKey: String? = nil
    var category: String? = nil

    var isVisible: Bool { titleKey != nil || alertKey != nil }

    static let all: [OutsideAlertSubscription] = [
        OutsideAlertSubscription(
            id: SignInRequest.subscriptionID,
            recordType: SignInRequest.recordType,
            trigger: .creation,
            titleKey: SignInRequest.titleKey,
            titleArgs: [SignInRequest.Field.tvName],
            alertKey: SignInRequest.bodyKey,
            desiredKeys: SignInRequest.Field.notified,
            collapseIDKey: SignInRequest.Field.tvTag,
            category: signInRequestCategory
        ),
        OutsideAlertSubscription(
            id: signInWithdrawalID,
            recordType: SignInRequest.recordType,
            trigger: .deletion
        ),
        OutsideAlertSubscription(
            id: AccountSignIn.subscriptionID,
            recordType: AccountSignIn.recordType,
            trigger: .creation,
            titleKey: AccountSignIn.titleKey,
            alertKey: AccountSignIn.bodyKey,
            alertArgs: [AccountSignIn.Field.deviceName],
            desiredKeys: AccountSignIn.Field.notified,
            collapseIDKey: AccountSignIn.Field.collapse,
            category: AccountSignIn.category
        ),
        OutsideAlertSubscription(
            id: NearbyLinkRequest.subscriptionID,
            recordType: NearbyLinkRequest.recordType,
            trigger: .creation,
            titleKey: NearbyLinkRequest.titleKey,
            titleArgs: [NearbyLinkRequest.Field.tvName],
            alertKey: NearbyLinkRequest.bodyKey,
            desiredKeys: NearbyLinkRequest.Field.notified,
            collapseIDKey: NearbyLinkRequest.Field.tvTag,
            category: NearbyLinkRequest.category
        ),
        OutsideAlertSubscription(
            id: NearbyLinkRequest.withdrawalSubscriptionID,
            recordType: NearbyLinkRequest.recordType,
            trigger: .deletion
        ),
    ]

    static let retiredIDs: Set<String> = [
        "signin-requests-v1",
        "signin-requests-v2",
        "signin-requests-gone-v1",
        "account-signins-v1",
        "account-signins-v2",
        "nearby-link-requests-v1",
    ]
}
