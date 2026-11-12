import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
enum MacOutsideAlerts {
    private static var activation: AnyCancellable?

    static func install() {
        guard activation == nil else { return }
        OutsideAlertSweeper.shared.install()
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in Task { await refresh() } }
        Task {
            await OutsideAlerts.registerCategories()
            await refresh()
        }
    }

    static func refresh() async {
        NSApplication.shared.registerForRemoteNotifications()
        await OutsideAlerts.ensureSubscriptions()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        await OutsideAlerts.tidyDelivered()
    }

    static func presentation(for notice: AccountSignIn.Notice) async -> UNNotificationPresentationOptions {
        guard case .found(let signIn) = await OutsideAlerts.signIn(for: notice) else { return [] }
        return OutsideAlerts.verdict(for: signIn) == .show ? [.banner, .list, .sound] : []
    }

    static func open(_ notice: AccountSignIn.Notice, action: OutsideAlerts.Response) {
        guard action == .open else { return }
        MacSettingsNavigation.shared.selection = .devices
        OutsideAlertRoutes.shared.showsDevices = true
        bringForward()
    }

    static func open(_ request: SignInRequest, action: OutsideAlerts.Response) {
        guard action == .open, !request.isExpired() else { return }
        bringForward()
    }

    static func presentation(for notice: NearbyLinkRequest.Notice) async -> UNNotificationPresentationOptions {
        guard !NSApp.isActive,
              case .found(let request) = await OutsideAlerts.linkRequest(for: notice),
              OutsideAlerts.verdict(for: request) == .show else { return [] }
        return NSApp.isActive ? [] : [.banner, .list, .sound]
    }

    static func open(_ notice: NearbyLinkRequest.Notice, action: OutsideAlerts.Response) async {
        switch action {
        case .open:
            guard case .found(let request) = await OutsideAlerts.linkRequest(for: notice),
                  OutsideAlerts.verdict(for: request).allowsLinking else { return }
            bringForward()
            MacTVLinking.shared.card.linkWhenSeen(name: request.tvName, kind: request.tvKind, within: 15)
        case .notNow:
            NearbyLinkInbox.shared.notNow(notice)
            await OutsideAlerts.snooze(notice)
        case .dismissed:
            break
        }
    }

    private static func bringForward() {
        NSApp.activate()
        let hasMainWindow = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
        guard !hasMainWindow else { return }
        _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
    }
}

struct MacOutsideAlertsOpener: ViewModifier {
    @ObservedObject private var routes = OutsideAlertRoutes.shared
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onChange(of: routes.showsDevices, initial: true) { _, shows in
            guard shows else { return }
            routes.showsDevices = false
            MacSettingsNavigation.shared.selection = .devices
            openSettings()
        }
    }
}

final class MacOutsideAlertsAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let recordName = OutsideAlerts.withdrawnRecordName(from: userInfo) else { return }
        Task { await OutsideAlerts.withdrawRequest(recordName: recordName) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.link.info("[OutsideAlerts] push registration failed: \(error.localizedDescription, privacy: .public)")
    }
}
