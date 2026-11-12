import SwiftUI
import AppKit

@MainActor
final class MacPrepRoute: ObservableObject {
    static let shared = MacPrepRoute()

    @Published var pendingTrackId: String?
    @Published var inspectedTrack: Track?

    private init() {}

    func inspect(_ track: Track) {
        MacPrepLibraryIndex.shared.install([track])
        inspectedTrack = track
    }

    func openPage(trackId: String? = nil) {
        pendingTrackId = trackId
        MacRootSelection.shared.request(.prep)
    }

    func consumePendingTrack() -> String? {
        defer { pendingTrackId = nil }
        return pendingTrackId
    }
}

@MainActor
enum MacMainWindow {
    static var current: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
            ?? NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }
}
