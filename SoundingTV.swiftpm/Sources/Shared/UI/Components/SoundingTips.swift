import Foundation
import SwiftUI
import TipKit

enum SoundingTips {
    static let nowPlayingOpened = Tips.Event(id: "nowPlayingOpened")
    static let trackStarted = Tips.Event(id: "trackStarted")

    static var isSuppressed: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["SOUNDING_TV_TIPS"] == "1" { return false }
        #if DEBUG
        if VisualFixtures.isEnabled { return true }
        #endif
        return environment.keys.contains { $0.hasPrefix("SOUNDING_TV_") || $0.hasPrefix("XCTest") }
    }

    @MainActor
    static func configure() {
        if ProcessInfo.processInfo.environment["SOUNDING_TV_TIPS"] == "1" {
            Tips.showAllTipsForTesting()
        } else if isSuppressed {
            Tips.hideAllTipsForTesting()
        }
        try? Tips.configure([.displayFrequency(.daily)])
    }

    static func noteNowPlayingOpened() {
        guard !isSuppressed else { return }
        Task { await nowPlayingOpened.donate() }
    }

    static func noteTrackStarted() {
        guard !isSuppressed else { return }
        Task { await trackStarted.donate() }
    }
}

struct NowPlayingSwipeTip: Tip {
    var title: Text { Text("Swipe to Skip") }
    var message: Text? { Text("Swipe the artwork left or right to change track.") }
    var image: Image? { Image(systemName: "hand.draw") }
    var rules: [Rule] {
        #Rule(SoundingTips.nowPlayingOpened) { $0.donations.count >= 2 }
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(1)] }
}

struct AutoMixTip: Tip {
    var title: Text { Text("Auto Mix") }
    var message: Text? { Text("Turn it on and the next track comes in on the beat.") }
    var image: Image? { Image(systemName: "infinity") }
    var rules: [Rule] {
        #Rule(SoundingTips.trackStarted) { $0.donations.count >= 5 }
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(1)] }
}

struct SleepTimerTip: Tip {
    var title: Text { Text("Sleep Timer") }
    var message: Text? { Text("Fade out and pause after a set time, or at the end of the track.") }
    var image: Image? { Image(systemName: "moon.zzz") }
    var rules: [Rule] {
        #Rule(SoundingTips.nowPlayingOpened) { $0.donations.count >= 6 }
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(1)] }
}

struct AddToPlaylistTip: Tip {
    var title: Text { Text("Add to Playlist") }
    var message: Text? { Text("Touch and hold any track to add it to one of your playlists.") }
    var image: Image? { Image(systemName: "text.badge.plus") }
    var rules: [Rule] {
        #Rule(SoundingTips.trackStarted) { $0.donations.count >= 3 }
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(1)] }
}

struct LinkAppleTVTip: Tip {
    var title: Text { Text("Play on Your Apple TV") }
    var message: Text? { Text("Link an Apple TV to send music to it and use this as the remote.") }
    var image: Image? { Image(systemName: "appletv") }
    var options: [any TipOption] { [Tips.MaxDisplayCount(1)] }
}
