import Foundation
import AppKit
import Combine

@MainActor
final class PlayerLifecycleObserver: PlatformLifecycleObserver {
    static let shared = PlayerLifecycleObserver()

    private init() {}

    func observeWillResignActive(handler: @escaping @MainActor () -> Void) -> AnyCancellable {
        NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
            .sink { _ in handler() }
    }
}
