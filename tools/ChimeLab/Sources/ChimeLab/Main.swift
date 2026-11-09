import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--report") {
            let trials = arguments.count > index + 1 ? Int(arguments[index + 1]) ?? 16 : 16
            Report.run(trials: trials)
            return
        }
        if let index = arguments.firstIndex(of: "--pulse-only"), arguments.count > index + 1 {
            let trials = arguments.count > index + 2 ? Int(arguments[index + 2]) ?? 16 : 16
            PulseOnly.run(directory: arguments[index + 1], trials: trials, quick: arguments.contains("--quick"))
            return
        }
        if let index = arguments.firstIndex(where: { $0 == "--pulse" || $0 == "--pulse-quick" }), arguments.count > index + 1 {
            let trials = arguments.count > index + 2 ? Int(arguments[index + 2]) ?? 16 : 16
            PulsePack.run(directory: arguments[index + 1], trials: trials, quick: arguments[index] == "--pulse-quick")
            return
        }
        ChimeLabApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        switch ProcessInfo.processInfo.environment["CHIMELAB_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        NSApp.activate(ignoringOtherApps: true)
        if let path = ProcessInfo.processInfo.environment["CHIMELAB_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Self.snapshot(to: URL(fileURLWithPath: path)) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView?.superview else { return }
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: url)
        print("window \(window.windowNumber) snapshot \(url.path)")
    }
}

struct ChimeLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = LabModel()

    var body: some Scene {
        Window("Chime Lab", id: "lab") {
            ContentView(model: model)
        }
        .defaultSize(width: 1_180, height: 860)
    }
}
