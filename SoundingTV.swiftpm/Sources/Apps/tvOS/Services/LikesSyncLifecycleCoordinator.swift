import Foundation
import UIKit

@MainActor
final class LikesSyncLifecycleCoordinator {
    static let shared = LikesSyncLifecycleCoordinator()

    private var token: NSObjectProtocol?

    private init() {}

    func install() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                LikesSyncEngine.shared.handleDidBecomeActive()
            }
        }
    }
}
