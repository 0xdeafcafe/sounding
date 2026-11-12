import AppKit

extension NSApplication {
    @objc var soundingPlayerState: NSNumber {
        let code: FourCharCode
        switch MacTransport.state {
        case .stopped: code = MacScripting.stopped
        case .playing: code = MacScripting.playing
        case .paused: code = MacScripting.paused
        }
        return NSNumber(value: code)
    }

    @objc var soundingCurrentTrackName: String {
        MacTransport.track?.title ?? ""
    }

    @objc var soundingCurrentTrackArtist: String {
        MacTransport.track?.user.displayName ?? ""
    }

    @objc var soundingCurrentTrackURL: String {
        guard let track = MacTransport.track, track.supportsSoundCloudActions else { return "" }
        return track.permalinkURL.absoluteString
    }
}

enum MacScripting {
    static let stopped = fourCharCode("kPSS")
    static let playing = fourCharCode("kPSP")
    static let paused = fourCharCode("kPSp")

    private static func fourCharCode(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    static func perform(_ action: @MainActor () -> Void) -> Any? {
        MainActor.assumeIsolated { action() }
        return nil
    }
}

@objc(SoundingPlayCommand)
final class SoundingPlayCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MacScripting.perform { MacTransport.play() }
    }
}

@objc(SoundingPauseCommand)
final class SoundingPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MacScripting.perform { MacTransport.pause() }
    }
}

@objc(SoundingPlayPauseCommand)
final class SoundingPlayPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MacScripting.perform { MacTransport.playPause() }
    }
}

@objc(SoundingNextTrackCommand)
final class SoundingNextTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MacScripting.perform { MacTransport.next() }
    }
}

@objc(SoundingPreviousTrackCommand)
final class SoundingPreviousTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MacScripting.perform { MacTransport.previous() }
    }
}
