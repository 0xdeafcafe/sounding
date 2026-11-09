import Foundation
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class PlayerLifecycleObserver: PlatformLifecycleObserver {
    static let shared = PlayerLifecycleObserver()

    private init() {}

    func observeSessionCheckpoints(handler: @escaping @MainActor () -> Void) -> AnyCancellable {
        let center = NotificationCenter.default
        #if os(macOS)
        let checkpoints = [
            NSApplication.willResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.willTerminateNotification
        ]
        #else
        let checkpoints = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification
        ]
        #endif
        return Publishers.MergeMany(checkpoints.map { center.publisher(for: $0) })
            .sink { _ in handler() }
    }
}
