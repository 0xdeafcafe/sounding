import SwiftUI
import AppKit

enum MacMusicWindowKind: String {
    case main
    case miniPlayer

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("SoundingCloud.music.\(rawValue)")
    }
}

@MainActor
final class MacMusicWindowCoordinator {
    static let shared = MacMusicWindowCoordinator()

    private(set) var requested: MacMusicWindowKind = .main

    private init() {}

    func request(_ kind: MacMusicWindowKind) {
        requested = kind
        closeMusicWindows(except: kind)
    }

    func register(_ window: NSWindow, as kind: MacMusicWindowKind) {
        window.identifier = kind.identifier
        guard requested == kind else {
            window.close()
            return
        }
        closeMusicWindows(except: kind, preserving: window)
    }

    private func closeMusicWindows(except kind: MacMusicWindowKind, preserving preserved: NSWindow? = nil) {
        let musicIdentifiers = Set([MacMusicWindowKind.main.identifier, MacMusicWindowKind.miniPlayer.identifier])
        for window in NSApp.windows where window !== preserved {
            guard let identifier = window.identifier, musicIdentifiers.contains(identifier) else { continue }
            if identifier != kind.identifier {
                // Order the old music window out before SwiftUI instantiates
                // the requested one. Closing alone is deferred by AppKit and
                // briefly left both the main player and mini player visible.
                window.orderOut(nil)
                window.close()
            }
        }
    }
}

struct MacWindowChrome: NSViewRepresentable {
    var musicWindow: MacMusicWindowKind?

    init(musicWindow: MacMusicWindowKind? = nil) {
        self.musicWindow = musicWindow
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        DispatchQueue.main.async { [weak view] in
            configure(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            configure(nsView?.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        if let musicWindow {
            MacMusicWindowCoordinator.shared.register(window, as: musicWindow)
        }
        #if DEBUG
        applyDebugWindowSizeOverride(window)
        #endif
    }

    #if DEBUG
    private func applyDebugWindowSizeOverride(_ window: NSWindow) {
        guard let spec = ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_WINDOW_SIZE"] else { return }
        let parts = spec.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return }
        var frame = window.frame
        let topLeft = CGPoint(x: frame.minX, y: frame.maxY)
        frame.size = CGSize(width: width, height: height)
        frame.origin = CGPoint(x: topLeft.x, y: topLeft.y - frame.height)
        window.setFrame(frame, display: true)
    }
    #endif
}
