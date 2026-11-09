import SwiftUI
import AppKit

enum MacMaterialRole {
    case sidebar
    case underWindowBackground
    case contentBackground
    case hudWindow

    var material: NSVisualEffectView.Material {
        switch self {
        case .sidebar: return .sidebar
        case .underWindowBackground: return .underWindowBackground
        case .contentBackground: return .contentBackground
        case .hudWindow: return .hudWindow
        }
    }
}

struct MacVisualEffect<Content: View>: NSViewRepresentable {
    var role: MacMaterialRole
    var tracksKeyWindow: Bool = true
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var keyObserver: NSObjectProtocol?
        var resignObserver: NSObjectProtocol?

        deinit {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.material = role.material
        effectView.blendingMode = .withinWindow
        effectView.state = .active

        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effectView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        if tracksKeyWindow {
            DispatchQueue.main.async { [weak effectView] in
                Self.attachKeyObservers(to: effectView, coordinator: context.coordinator)
            }
        }

        return effectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = role.material
        if let hosting = nsView.subviews.first as? NSHostingView<Content> {
            hosting.rootView = content()
        }
        if tracksKeyWindow, let window = nsView.window {
            nsView.isEmphasized = window.isKeyWindow
        }
    }

    private static func attachKeyObservers(to effectView: NSVisualEffectView?, coordinator: Coordinator) {
        guard let effectView, let window = effectView.window else { return }
        effectView.isEmphasized = window.isKeyWindow
        coordinator.keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak effectView] _ in
            MainActor.assumeIsolated { effectView?.isEmphasized = true }
        }
        coordinator.resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak effectView] _ in
            MainActor.assumeIsolated { effectView?.isEmphasized = false }
        }
    }
}

struct MacVisualEffectBackground: NSViewRepresentable {
    var role: MacMaterialRole
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = role.material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = role.material
        nsView.blendingMode = blending
    }
}
