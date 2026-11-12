import SwiftUI

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

    func openWindow(trackId: String?, open: OpenWindowAction) {
        pendingTrackId = trackId
        open(id: MacPrepCommands.windowID)
    }

    func consumePendingTrack() -> String? {
        defer { pendingTrackId = nil }
        return pendingTrackId
    }
}
