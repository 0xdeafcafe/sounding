import Foundation
import UIKit
import Combine

@MainActor
final class PlayerLifecycleObserver: PlatformLifecycleObserver {
    static let shared = PlayerLifecycleObserver()

    private init() {}

    func observeWillResignActive(handler: @escaping @MainActor () -> Void) -> AnyCancellable {
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { _ in handler() }
    }
}
