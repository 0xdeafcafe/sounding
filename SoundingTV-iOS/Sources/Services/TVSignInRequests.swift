import CloudKit
import Combine
import Foundation
import Network
import UIKit
import UserNotifications
import os

enum TVSignInInvitation: Identifiable, Equatable {
    case nearby(SignInRequest)
    case picked(DevicePickerSignIn.Invitation)

    var id: String {
        switch self {
        case .nearby(let request): return "nearby-\(request.rendezvous)"
        case .picked(let invitation): return "picked-\(invitation.sessionId)"
        }
    }

    var tvName: String {
        switch self {
        case .nearby(let request): return request.tvName
        case .picked(let invitation): return invitation.tvName
        }
    }

    var kind: DeviceClass {
        switch self {
        case .nearby(let request): return request.tvKind
        case .picked(let invitation): return invitation.kind
        }
    }
}

@MainActor
final class TVSignInInbox: ObservableObject {
    static let shared = TVSignInInbox()

    @Published var invitation: TVSignInInvitation?

    var signedInTVNames: () -> Set<String> = { [] }

    private var filter = SignInRequestFilter()

    func admit(_ request: SignInRequest) -> SignInRequestFilter.Verdict {
        filter.admit(request, signedInTVNames: signedInTVNames())
    }

    func open(_ request: SignInRequest) {
        guard !request.isExpired() else { return }
        if signedInTVNames().contains(where: { $0.localizedCaseInsensitiveCompare(request.tvName) == .orderedSame }) { return }
        invitation = .nearby(request)
    }

    func open(_ invitation: DevicePickerSignIn.Invitation) {
        self.invitation = .picked(invitation)
    }

    #if DEBUG
    static var fixtureInvitation: TVSignInInvitation? {
        let now = Date()
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_SIGNIN_INVITE"] {
        case "nearby":
            return SignInRequest(rendezvous: String(repeating: "a1", count: 16), tvName: "Living Room", createdAt: now).map { .nearby($0) }
        case "picked":
            return .picked(DevicePickerSignIn.Invitation(
                version: DevicePickerSignIn.wireVersion,
                sessionId: "fixture",
                secretBase64: Data(repeating: 7, count: 32).base64EncodedString(),
                createdAt: now,
                tvName: "Living Room",
                tvKind: DeviceClass.tv.rawValue
            ))
        default:
            return nil
        }
    }
    #endif
}

@MainActor
final class TVSignInNotifications: NSObject, ObservableObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = TVSignInNotifications()

    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    @Published var isPriming = false

    private static let primedAfterLinkKey = "outsideAlerts.primedAfterLink.v1"
    private let center = UNUserNotificationCenter.current()
    private var linkWatch: AnyCancellable?

    func install() {
        center.delegate = self
        linkWatch = LinkClient.transfers
            .filter { $0.state == .completed }
            .sink { [weak self] _ in self?.primeAfterLink() }
        OutsideAlertSweeper.shared.install()
        Task { await OutsideAlerts.registerCategories() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_SIGNIN_NOTIFY_STORY"] == "priming" {
            status = .notDetermined
            isPriming = true
            return
        }
        #endif
        Task { await refresh() }
    }

    func refresh() async {
        UIApplication.shared.registerForRemoteNotifications()
        let settings = await center.notificationSettings()
        status = settings.authorizationStatus
        await OutsideAlerts.ensureSubscriptions()
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        await OutsideAlerts.tidyDelivered()
    }

    func requestAuthorization() async {
        isPriming = false
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
    }

    var needsPriming: Bool { status == .notDetermined }

    private func primeAfterLink() {
        guard !UserDefaults.standard.bool(forKey: Self.primedAfterLinkKey) else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            let settings = await center.notificationSettings()
            status = settings.authorizationStatus
            guard status == .notDetermined, !isPriming else { return }
            UserDefaults.standard.set(true, forKey: Self.primedAfterLinkKey)
            isPriming = true
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        if let notice = AccountSignIn.Notice(remoteNotification: userInfo) {
            guard case .found(let signIn) = await OutsideAlerts.signIn(for: notice) else { return [] }
            return OutsideAlerts.verdict(for: signIn) == .show ? [.banner, .list, .sound] : []
        }
        if NearbyLinkRequest.Notice(remoteNotification: userInfo) != nil {
            return []
        }
        guard let request = SignInRequest(remoteNotification: userInfo) else {
            return [.banner, .list, .sound]
        }
        return TVSignInInbox.shared.admit(request) == .show ? [.banner, .list, .sound] : []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if ScoutNotifications.isScout(userInfo) {
            await ScoutNotifications.open(userInfo)
            return
        }
        let action = OutsideAlerts.response(for: response.actionIdentifier)
        if let notice = NearbyLinkRequest.Notice(remoteNotification: userInfo) {
            switch action {
            case .open:
                guard case .found(let link) = await OutsideAlerts.linkRequest(for: notice),
                      OutsideAlerts.verdict(for: link).allowsLinking else { return }
                NearbyLinkInbox.shared.link(link)
            case .notNow:
                NearbyLinkInbox.shared.notNow(notice)
                await OutsideAlerts.snooze(notice)
            case .dismissed:
                break
            }
            return
        }
        if AccountSignIn.Notice(remoteNotification: userInfo) != nil {
            guard action == .open else { return }
            OutsideAlertRoutes.shared.showsDevices = true
            return
        }
        guard let request = SignInRequest(remoteNotification: userInfo) else { return }
        switch action {
        case .open:
            TVSignInInbox.shared.open(request)
        case .notNow, .dismissed:
            _ = TVSignInInbox.shared.admit(request)
        }
    }
}

final class DevicePickerSignInListener: @unchecked Sendable {
    static let shared = DevicePickerSignInListener()

    private let queue = DispatchQueue(label: "red.forbes.sounding.devicepicker")
    private var listener: NWListener?
    private var connection: NWConnection?

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let listener = try NWListener(using: .applicationService)
                listener.service = NWListener.Service(applicationService: DevicePickerSignIn.serviceName)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed(let error):
                        Log.link.error("[DevicePicker] listener failed: \(error.localizedDescription, privacy: .public)")
                        self?.queue.async { self?.listener = nil }
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                Log.link.error("[DevicePicker] listener unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + 20) { [weak connection] in connection?.cancel() }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: DevicePickerSignIn.maximumMessageLength + 4) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if DevicePickerSignIn.isComplete(buffer) || isComplete || error != nil || buffer.count > DevicePickerSignIn.maximumMessageLength + 4 {
                connection.cancel()
                guard let invitation = DevicePickerSignIn.decode(buffer) else {
                    Log.link.error("[DevicePicker] ignored an invitation it couldn't read")
                    return
                }
                Task { @MainActor in TVSignInInbox.shared.open(invitation) }
                return
            }
            self?.receive(on: connection, buffer: buffer)
        }
    }
}
