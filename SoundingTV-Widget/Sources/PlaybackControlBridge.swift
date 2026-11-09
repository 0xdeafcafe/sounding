import Foundation

enum PlaybackControlBridge {
    static func setPlaying(_ playing: Bool) async throws {}
    static func skipToNext() async throws {}
    static func mixNow() async throws {}
}
