import SwiftUI
import UIKit

@MainActor
enum PadLayout {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
}

extension View {
    func padDebugGeometry() -> some View {
        #if DEBUG
        modifier(PadDebugGeometry())
        #else
        self
        #endif
    }

    func padDebugSelection(_ selection: Binding<PhoneRootView.PhoneTab>) -> some View {
        #if DEBUG
        onReceive(NotificationCenter.default.publisher(for: .padDebugSelectLikes)) { _ in
            selection.wrappedValue = .likes
        }
        #else
        self
        #endif
    }
}

extension FocusedValues {
    @Entry var rootTabSelection: Binding<PhoneRootView.PhoneTab>?
}

struct PlaybackCommands: Commands {
    @ObservedObject var coordinator: PhonePlaybackCoordinator

    @FocusedBinding(\.rootTabSelection) private var tab
    @ObservedObject private var textEditing = TextEditingObserver.shared
    private let likes = NowPlayingLikeModel.shared

    private var likeTrack: Track? {
        guard let track = coordinator.currentTrack, track.supportsSoundCloudActions else { return nil }
        return track
    }

    private var likeTitle: String {
        guard let track = likeTrack else { return "Like" }
        return likes.isLiked(track.id, resolved: track) ? "Unlike" : "Like"
    }

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play/Pause") { coordinator.togglePlayPause() }
                .keyboardShortcut(textEditing.isEditing ? nil : KeyboardShortcut(.space, modifiers: []))
            Button("Next Track") { coordinator.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Track") { coordinator.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Volume Up") { adjustVolume(by: 1) }
                .keyboardShortcut(textEditing.isEditing ? nil : KeyboardShortcut(.upArrow, modifiers: .command))
                .disabled(coordinator.volume == nil)
            Button("Volume Down") { adjustVolume(by: -1) }
                .keyboardShortcut(textEditing.isEditing ? nil : KeyboardShortcut(.downArrow, modifiers: .command))
                .disabled(coordinator.volume == nil)
            Divider()
            Button(likeTitle) {
                guard let track = likeTrack else { return }
                likes.toggle(trackId: track.id, resolved: track)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(likeTrack == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsPresenter.shared.isPresented = true }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("Search") { tab = .search }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(tab == nil)
        }
        CommandGroup(after: .sidebar) {
            destination("Home", .home, shortcut: "1")
            destination("Search", .search, shortcut: "2")
            destination("Recently Added", .recentlyAdded, shortcut: "3")
            destination("Tracks", .songs, shortcut: "4")
            destination("Albums", .albums, shortcut: "5")
            destination("Artists", .artists, shortcut: "6")
            destination("Sets", .sets, shortcut: "7")
            destination("All Playlists", .playlists, shortcut: "8")
            destination("Likes", .likes, shortcut: "9")
            Divider()
            destination("Decks", .decks, shortcut: "d", modifiers: [.command, .shift])
            destination("Downloads", .downloads)
            destination("Mixes", .mixes)
        }
        CommandMenu("Library") {
            destination("Likes", .likes, shortcut: "1", modifiers: [.command, .option])
            destination("Artists", .artists, shortcut: "2", modifiers: [.command, .option])
            destination("All Playlists", .playlists, shortcut: "3", modifiers: [.command, .option])
        }
    }

    @ViewBuilder
    private func destination(
        _ title: String,
        _ target: PhoneRootView.PhoneTab,
        shortcut: KeyEquivalent? = nil,
        modifiers: EventModifiers = .command
    ) -> some View {
        if let shortcut {
            Button(title) { tab = target }
                .keyboardShortcut(shortcut, modifiers: modifiers)
                .disabled(tab == nil)
        } else {
            Button(title) { tab = target }
                .disabled(tab == nil)
        }
    }

    private func adjustVolume(by steps: Int) {
        if coordinator.volumeRoute.isRemote {
            coordinator.stepRemoteVolume(steps)
            return
        }
        let system = NowPlayingVolume.shared
        if system.isAvailable {
            system.set(system.level + Float(steps) * HardwareVolumeStep.system)
        } else if let current = coordinator.volume {
            coordinator.setVolume(HardwareVolumeStep.applying(steps, to: current))
        }
    }
}

@MainActor
final class TextEditingObserver: ObservableObject {
    static let shared = TextEditingObserver()

    @Published private(set) var isEditing = false

    private init() {
        let center = NotificationCenter.default
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TextEditingObserver.shared.isEditing = true }
            }
        }
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TextEditingObserver.shared.isEditing = false }
            }
        }
    }
}

#if DEBUG
extension Notification.Name {
    static let padDebugSelectLikes = Notification.Name("red.forbes.sounding.debug.padSelectLikes")
}

struct PlaylistFixtureView: View {
    let playlist: Playlist
    @Namespace private var namespace

    var body: some View {
        PlaylistDetailView(playlist: playlist, heroNamespace: namespace)
    }
}

private struct PadDebugGeometry: ViewModifier {
    func body(content: Content) -> some View {
        content.task {
            if ProcessInfo.processInfo.environment["SOUNDING_TV_PAD_LANDSCAPE"] == "1" {
                for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { print("PAD_LANDSCAPE error \($0)") }
                }
            }
            let environment = ProcessInfo.processInfo.environment
            if let toggles = environment["SOUNDING_TV_PAD_WIDTH_TOGGLES"].flatMap(Int.init) {
                await Self.toggleWidths(toggles)
                return
            }
            let width = environment["SOUNDING_TV_PAD_WINDOW_WIDTH"].flatMap(Double.init)
            let height = environment["SOUNDING_TV_PAD_WINDOW_HEIGHT"].flatMap(Double.init)
            guard width != nil || height != nil else { return }
            try? await Task.sleep(for: .milliseconds(200))
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows {
                    if let width, width < 600 {
                        window.traitOverrides.horizontalSizeClass = .compact
                    }
                    var frame = window.frame
                    if let width { frame.size.width = width }
                    if let height { frame.size.height = height }
                    window.frame = frame
                }
            }
        }
    }

    private static func toggleWidths(_ count: Int) async {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let fullFrames = windows.map(\.frame)
        try? await Task.sleep(for: .milliseconds(800))
        for index in 0..<(count * 2) {
            let compact = index.isMultiple(of: 2)
            for (window, full) in zip(windows, fullFrames) {
                window.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
                var frame = full
                if compact { frame.size.width = 375 }
                window.frame = frame
            }
            print("PAD_WIDTH_TOGGLE \(index + 1) \(compact ? "compact" : "regular")")
            try? await Task.sleep(for: .milliseconds(compact ? 450 : 350))
            if !compact {
                NotificationCenter.default.post(name: .padDebugSelectLikes, object: nil)
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
        print("PAD_WIDTH_TOGGLE done")
    }
}
#endif

enum SidebarProbe {
    static var kind: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_SIDEBAR_PROBE"]
        #else
        nil
        #endif
    }
}

#if DEBUG
struct SidebarProbeView: View {
    let kind: String
    @State private var selection = 0
    @State private var split: Int? = 0

    var body: some View {
        probe.padDebugGeometry()
    }

    @ViewBuilder
    private var probe: some View {
        switch kind {
        case "split":
            NavigationSplitView {
                List(0..<8, id: \.self, selection: $split) { Text("Item \($0)") }
                    .navigationTitle("Probe")
            } detail: {
                probeDetail
            }
        case let value where value.hasPrefix("tabsplit"):
            TabView(selection: $selection) {
                Tab("Home", systemImage: "house", value: 0) { NavigationStack { probeDetail } }
                Tab("Settings", systemImage: "gearshape", value: 1) {
                    nestedSplit(value)
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .onAppear { if value.hasSuffix("-settings") || value.contains("-") { selection = 1 } }
        default:
            TabView(selection: $selection) {
                Tab("Home", systemImage: "house", value: 0) { NavigationStack { probeDetail } }
                TabSection("Library") {
                    Tab("Likes", systemImage: "heart", value: 1) { NavigationStack { probeDetail } }
                    Tab("Sets", systemImage: "clock", value: 2) { NavigationStack { probeDetail } }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        }
    }

    var probeDetail: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))]) {
                ForEach(0..<40, id: \.self) { index in
                    Color(hue: Double(index) / 40, saturation: 0.7, brightness: 0.9)
                        .frame(height: 160)
                }
            }
        }
        .navigationTitle("Detail")
    }
}
#endif

#if DEBUG
extension SidebarProbeView {
    @ViewBuilder
    func nestedSplit(_ value: String) -> some View {
        let nested = NavigationSplitView {
            List(0..<8, id: \.self) { Text("Item \($0)") }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
        } detail: {
            probeDetail
        }
        switch value {
        case "tabsplit-ignore": nested.ignoresSafeArea(.container, edges: .top)
        case "tabsplit-prominent": nested.navigationSplitViewStyle(.prominentDetail)
        case "tabsplit-balanced": nested.navigationSplitViewStyle(.balanced)
        case "tabsplit-hidebar": nested.toolbar(.hidden, for: .tabBar)
        default: nested
        }
    }
}
#endif
