import SwiftUI

enum WindowRoute: Codable, Hashable {
    case artist(User)
    case playlist(Playlist)

    static let sceneID = "detail"

    var title: String {
        switch self {
        case .artist(let user): return user.displayName
        case .playlist(let playlist): return playlist.title
        }
    }
}

@MainActor
private final class SceneRegistry: ObservableObject {
    static let shared = SceneRegistry()
    @Published private(set) var ids: [UUID] = []

    func add(_ id: UUID) {
        guard !ids.contains(id) else { return }
        ids.append(id)
    }

    func remove(_ id: UUID) {
        ids.removeAll { $0 == id }
    }
}

struct PrimarySceneReader<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content

    @ObservedObject private var registry = SceneRegistry.shared
    @State private var id = UUID()

    var body: some View {
        content(registry.ids.first == id || !registry.ids.contains(id))
            .onAppear { registry.add(id) }
            .onDisappear { registry.remove(id) }
    }
}

struct OpenInNewWindowButton: View {
    let route: WindowRoute

    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if supportsMultipleWindows {
            Button {
                openWindow(id: WindowRoute.sceneID, value: route)
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
    }
}

extension View {
    func debugOpensWindow() -> some View {
        #if DEBUG
        modifier(DebugOpensWindow())
        #else
        self
        #endif
    }
}

#if DEBUG
private struct DebugOpensWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            guard VisualFixtures.isEnabled,
                  let kind = ProcessInfo.processInfo.environment["SOUNDING_TV_OPEN_WINDOW"] else { return }
            try? await Task.sleep(for: .seconds(1.5))
            switch kind {
            case "artist":
                openWindow(id: WindowRoute.sceneID, value: WindowRoute.artist(VisualFixtures.artists[0]))
            case "playlist":
                if let playlist = VisualFixtures.playlists.first {
                    openWindow(id: WindowRoute.sceneID, value: WindowRoute.playlist(playlist))
                }
            default:
                break
            }
        }
    }
}
#endif

struct DetailWindowRoot: View {
    let route: WindowRoute

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @State private var isNowPlayingExpanded = false
    @State private var nowPlayingZoomSourceID: String?
    @Namespace private var nowPlayingNamespace

    private let nowPlayingHeroID = "sc.transportHero"

    var body: some View {
        ArtistRoutingStack(restorationKey: "detail") {
            destination
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if coordinator.nowPlaying != nil {
                TransportBarView(
                    isExpanded: $isNowPlayingExpanded,
                    heroID: nowPlayingHeroID,
                    heroNamespace: nowPlayingNamespace
                )
                .glassEffect(.regular, in: .rect(cornerRadius: PhoneRadius.card, style: .continuous))
                .padding(.horizontal, Space.tight)
                .padding(.bottom, Space.tight)
            }
        }
        .environment(\.nowPlayingZoomNamespace, nowPlayingNamespace)
        .onReceive(NowPlayingReveal.shared.$request.dropFirst()) { _ in
            guard !isNowPlayingExpanded, coordinator.nowPlaying != nil,
                  let source = NowPlayingReveal.shared.consumeSource() else { return }
            nowPlayingZoomSourceID = source
            isNowPlayingExpanded = true
        }
        .onChange(of: isNowPlayingExpanded) { _, isExpanded in
            guard !isExpanded else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                if !isNowPlayingExpanded { nowPlayingZoomSourceID = nil }
            }
        }
        .fullScreenCover(isPresented: $isNowPlayingExpanded) {
            NowPlayingSheet(isPresented: $isNowPlayingExpanded)
                .navigationTransition(.zoom(sourceID: nowPlayingZoomSourceID ?? nowPlayingHeroID, in: nowPlayingNamespace))
                .addToPlaylistHost()
        }
        .addToPlaylistHost()
    }

    @ViewBuilder
    private var destination: some View {
        switch route {
        case .artist(let user):
            ArtistDetailView(user: user)
        case .playlist(let playlist):
            DetailPlaylistView(playlist: playlist)
        }
    }
}

private struct DetailPlaylistView: View {
    let playlist: Playlist
    @Namespace private var namespace

    var body: some View {
        PlaylistDetailView(playlist: playlist, heroNamespace: namespace)
    }
}
