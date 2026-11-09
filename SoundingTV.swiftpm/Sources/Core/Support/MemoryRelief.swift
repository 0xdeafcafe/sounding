import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
enum MemoryRelief {
    enum Reason: Sendable {
        case background
        case warning
        case critical
    }

    private static var handlers: [@MainActor (Reason) -> Void] = []
    private static var observers: [NSObjectProtocol] = []
    private static var pressureSource: DispatchSourceMemoryPressure?

    static func install() {
        guard pressureSource == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            let critical = source.data.contains(.critical)
            MainActor.assumeIsolated { purge(critical ? .critical : .warning) }
        }
        source.resume()
        pressureSource = source

        let center = NotificationCenter.default
        #if os(iOS) || os(tvOS)
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { purge(.critical) }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { purge(.background) }
        })
        #elseif os(macOS)
        observers.append(center.addObserver(
            forName: NSApplication.didHideNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { purge(.background) }
        })
        #endif
    }

    static func addHandler(_ handler: @escaping @MainActor (Reason) -> Void) {
        handlers.append(handler)
    }

    static func purge(_ reason: Reason) {
        if reason != .warning {
            ArtworkCache.shared.purgeMemory()
        }
        SoundingArtCache.shared.purgeMemory()
        Task.detached(priority: .utility) { await PlaylistMosaicComposer.shared.purge() }

        let shared = URLCache.shared
        let capacity = shared.memoryCapacity
        shared.memoryCapacity = 0
        shared.memoryCapacity = capacity

        for handler in handlers { handler(reason) }
    }
}
