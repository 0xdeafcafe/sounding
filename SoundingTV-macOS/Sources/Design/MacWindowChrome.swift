import SwiftUI
import AppKit

struct MacWindowChrome: NSViewRepresentable {
    var configuresMainWindow = false

    init(configuresMainWindow: Bool = false) {
        self.configuresMainWindow = configuresMainWindow
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
        guard configuresMainWindow else { return }
        window.appearance = nil
        window.titlebarSeparatorStyle = .none
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
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

struct MacTrafficLightsKeeper: NSViewRepresentable {
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in apply(view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in apply(nsView?.window) }
    }

    private func apply(_ window: NSWindow?) {
        guard let window, let toolbar = window.toolbar else { return }
        if toolbar.isVisible == isActive { toolbar.isVisible = !isActive }
        window.titleVisibility = isActive ? .hidden : .visible
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = false
        }
    }
}
