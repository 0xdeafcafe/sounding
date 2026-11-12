import AppKit

extension MacOutsideAlertsAppDelegate {
    @MainActor @objc
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        MacDockMenu.shared.makeMenu()
    }
}

@MainActor
final class MacDockMenu: NSObject {
    static let shared = MacDockMenu()

    private static let recentLimit = 5
    private var recents: [SoundingSnapshot.Item] = []

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let track = MacTransport.track

        if let track {
            menu.addItem(.sectionHeader(title: "Now Playing"))
            let current = item(track.title, action: #selector(showNowPlaying))
            current.subtitle = track.user.displayName
            menu.addItem(current)
            menu.addItem(.separator())
        }

        menu.addItem(item(MacTransport.isPlaying ? "Pause" : "Play", action: #selector(playPause)))
        let next = item("Next Track", action: #selector(nextTrack))
        next.isEnabled = track != nil
        menu.addItem(next)
        let previous = item("Previous Track", action: #selector(previousTrack))
        previous.isEnabled = track != nil
        menu.addItem(previous)
        if MacTransport.canLike {
            menu.addItem(item(MacTransport.isLiked ? "Unlike" : "Like", action: #selector(toggleLike)))
        }

        recents = MacTransport.recentTracks(limit: Self.recentLimit)
        if !recents.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recently Played"))
            for (index, recent) in recents.enumerated() {
                let entry = item(recent.title, action: #selector(playRecent(_:)))
                entry.subtitle = recent.subtitle.isEmpty ? nil : recent.subtitle
                entry.tag = index
                menu.addItem(entry)
            }
        }
        return menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showNowPlaying() {
        NSApp.activate()
        let hasMainWindow = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
        if !hasMainWindow {
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
        MacNowPlayingPresentation.shared.present()
    }

    @objc private func playPause() {
        MacTransport.playPause()
    }

    @objc private func nextTrack() {
        MacTransport.next()
    }

    @objc private func previousTrack() {
        MacTransport.previous()
    }

    @objc private func toggleLike() {
        MacTransport.toggleLike()
    }

    @objc private func playRecent(_ sender: NSMenuItem) {
        guard recents.indices.contains(sender.tag) else { return }
        MacTransport.play(recent: recents[sender.tag])
    }
}
