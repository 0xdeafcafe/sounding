import Foundation
import Combine
import AppKit

@MainActor
final class MacSyncCoordinator: ObservableObject {
    static let shared = MacSyncCoordinator()

    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var lastSuccessfulRunAt: Date?
    @Published private(set) var failureMessage: String?

    private var periodicTask: Task<Void, Never>?
    private var foregroundToken: NSObjectProtocol?

    private init() {}

    static func install() {
        // Authentication is intentionally not imported through CloudKit on
        // macOS. A Mac signs in for itself and may hand auth to another device,
        // but it never adopts another device's credentials.
        SessionSyncTarget.source = nil
    }

    func start() {
        CloudSyncCoordinator.shared.start()
        installForegroundNudge()
    }

    private func installForegroundNudge() {
        guard foregroundToken == nil else { return }
        foregroundToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                CloudSyncCoordinator.shared.requestCueSync()
            }
        }
    }

    func runOnce() async {
        lastAttemptAt = Date()
        let controller = CloudSyncEngineController.shared
        switch await controller.availability() {
        case .available:
            break
        case .unavailable(let message):
            failureMessage = Self.userFacingFailure(message)
            return
        }

        await CloudSyncCoordinator.shared.runOnce(
            analysisStore: AnalysisCache.shared,
            downloadManifestExportSource: LocalDownloadManifestSource(
                deviceId: DownloadManifestDeviceIdentity.deviceId(),
                deviceLabel: "Mac"
            )
        )

        switch await controller.availability() {
        case .available:
            lastSuccessfulRunAt = Date()
            failureMessage = nil
        case .unavailable(let message):
            failureMessage = Self.userFacingFailure(message)
        }
    }

    /// CloudKit can include entitlement, container, and provisioning details in
    /// its errors. Those are useful in logs, but not actionable in Settings.
    private static func userFacingFailure(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("entitlement") || normalized.contains("provision") || normalized.contains("container") {
            return "iCloud sync is unavailable in this build. You can keep using SoundingCloud on this Mac and try again after updating the app."
        }
        if normalized.contains("cloudkit could not") {
            return "iCloud sync could not be reached. Check your network connection and try again."
        }
        return message
    }

    func startPeriodicSync(interval: TimeInterval = 300) {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPeriodicSync() {
        periodicTask?.cancel()
        periodicTask = nil
    }
}
