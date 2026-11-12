import SwiftUI
import AppKit

@MainActor
final class MacPrepRoute: ObservableObject {
    static let shared = MacPrepRoute()

    @Published var inspectedTrack: Track?
    @Published var selectedTrack: Track?

    private init() {}

    func inspect(_ track: Track) {
        MacPrepLibraryIndex.shared.install([track])
        inspectedTrack = track
    }

    func inspectCurrent() {
        if let track = selectedTrack ?? MacNowPlayingModel.shared.track { inspect(track) }
    }

    func inspectNowPlaying() {
        if let track = MacNowPlayingModel.shared.track ?? selectedTrack { inspect(track) }
    }}

@MainActor
enum MacMainWindow {
    static var current: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
            ?? NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }
}
