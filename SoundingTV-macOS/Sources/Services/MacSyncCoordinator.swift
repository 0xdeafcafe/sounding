import Foundation
import Combine

@MainActor
final class MacSyncCoordinator: ObservableObject {
    static let shared = MacSyncCoordinator()

    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var lastSuccessfulRunAt: Date?
    @Published private(set) var failureMessage: String?

    private init() {}

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

        await SynchronizationCoordinator.shared.runOnce(
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
            return "iCloud sync is unavailable in this build. You can keep using Sounding on this Mac and try again after updating the app."
        }
        if normalized.contains("cloudkit could not") {
            return "iCloud sync could not be reached. Check your network connection and try again."
        }
        return message
    }

}
