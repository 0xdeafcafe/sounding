import SwiftUI
import WidgetKit

enum WatchUIPreview {
    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-SoundingWatchUIPreview")
        #else
        false
        #endif
    }

    static var destination: String? {
        value(for: "-SoundingWatchUIDestination")
    }

    static func value(for argument: String) -> String? {
        #if DEBUG
        guard isEnabled else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
        #else
        nil
        #endif
    }

    static func hasFlag(_ argument: String) -> Bool {
        #if DEBUG
        isEnabled && ProcessInfo.processInfo.arguments.contains(argument)
        #else
        false
        #endif
    }
}

@main
struct SoundingTVWatchApp: App {
    @StateObject private var link = WatchLinkClient.shared
    @StateObject private var credentials = WatchCredentialSource.shared

    init() {
        SoundCloudGateway.installAsTokenRefreshTransport()
        WatchCredentialSource.install()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(link)
                .environmentObject(credentials)
                .tint(Color.scAccent)
                .task {
                    link.activate()
                    await credentials.adoptFromPhoneIfNeeded()
                }
        }
    }
}

enum WatchRootRoute: Hashable {
    case onThisWatch
    case identify
}

struct WatchRootView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @EnvironmentObject private var credentials: WatchCredentialSource
    @ObservedObject private var identifiedHistory = IdentifiedSongHistory.shared
    @ObservedObject private var store = WatchOfflineStore.shared
    @ObservedObject private var playback = WatchPlayback.shared
    @ObservedObject private var identifyRequests = IdentifySongRequests.shared

    @State private var path: [WatchRootRoute] = []
    @State private var didOfferOffline = false

    #if DEBUG
    @State private var previewPath: [String] = WatchUIPreview.destination.map { [$0] } ?? []
    #endif

    var body: some View {
        ZStack {
            stack
                #if DEBUG
                .transformEnvironment(\.dynamicTypeSize) { size in
                    if WatchUIPreview.hasFlag("-SoundingWatchUIXL") { size = .accessibility3 }
                }
                #endif

            if !credentials.isSignedIn, store.isEmpty, !WatchUIPreview.isEnabled {
                Color.black.ignoresSafeArea()
                WatchSignInGate()
            }
        }
    }

    @ViewBuilder
    private var stack: some View {
        #if DEBUG
        if WatchUIPreview.hasFlag("-SoundingWatchUIPushed") {
            NavigationStack(path: $previewPath) {
                rootList.navigationDestination(for: String.self) { previewDestination($0) }
            }
        } else if let destination = WatchUIPreview.destination {
            NavigationStack { previewDestination(destination) }
        } else {
            rootStack
        }
        #else
        rootStack
        #endif
    }

    private var rootStack: some View {
        NavigationStack(path: $path) {
            rootList
                .navigationDestination(for: WatchRootRoute.self) { route in
                    switch route {
                    case .onThisWatch: WatchOnThisWatchView()
                    case .identify: WatchIdentifyView()
                    }
                }
        }
        .task { await openOnThisWatchIfOffline() }
        .onReceive(identifyRequests.$pendingListen) { pending in
            guard pending, identifyRequests.consume() else { return }
            if path.last != .identify { path.append(.identify) }
        }
    }

    private func openOnThisWatchIfOffline() async {
        guard !didOfferOffline else { return }
        didOfferOffline = true
        try? await Task.sleep(for: .seconds(2))
        guard path.isEmpty, !link.isReachable, !store.isEmpty,
              !link.nowPlaying.isPlaying || playback.isLocal else { return }
        path.append(.onThisWatch)
    }

    #if DEBUG
    @ViewBuilder
    private func previewDestination(_ destination: String) -> some View {
        switch destination {
        case "now-playing": WatchNowPlayingView()
        case "up-next": WatchUpNextView()
        case "tracklist": WatchTracklistView()
        case "more": WatchNowPlayingMoreView()
        case "about": WatchTrackInfoView()
        case "output": WatchOutputPickerView()
        case "listen-now": WatchHomeView()
        case "library": WatchLibraryView()
        case "library-playlists": WatchLibraryPlaylistsView()
        case "library-artists": WatchLibraryArtistsView()
        case "library-songs": WatchLibrarySongsView()
        case "playlist": WatchPlaylistDetailView(playlist: VisualFixtures.playlists[0])
        case "artist": WatchArtistDetailView(user: VisualFixtures.artists[0])
        case "search": WatchSearchView()
        case "downloads": WatchDownloadsView()
        case "on-this-watch": WatchOnThisWatchView()
        case "dj": WatchDJView()
        case "widgets": WatchWidgetFamiliesPreview()
        case "settings": WatchSettingsView()
        case "identify": WatchIdentifyView()
        case "identified": WatchIdentifiedHistoryView()
        case "sign-in": WatchSignInGate()
        default: rootList
        }
    }
    #endif

    private var rootList: some View {
        List {
            WatchContinueFromSection()

            if playback.nowPlaying.hasTrack {
                Section {
                    NavigationLink { WatchNowPlayingView() } label: {
                        WatchNowPlayingChip(nowPlaying: playback.nowPlaying)
                    }
                }
            }

            if !store.isEmpty {
                Section {
                    NavigationLink(value: WatchRootRoute.onThisWatch) {
                        Label("On This Watch", systemImage: "applewatch")
                    }
                }
            }

            Section {
                NavigationLink { WatchIdentifyView() } label: {
                    Label("Identify Song", systemImage: "shazam.logo.fill")
                        .font(.headline)
                }
                .listItemTint(Color.accentColor)
                if !identifiedHistory.songs.isEmpty {
                    NavigationLink { WatchIdentifiedHistoryView() } label: {
                        Label("Recently Identified", systemImage: "clock")
                    }
                }
            }

            Section {
                NavigationLink { WatchHomeView() } label: {
                    Label("Listen Now", systemImage: "play.circle.fill")
                }
                NavigationLink { WatchLibraryView() } label: {
                    Label("Library", systemImage: "music.note.list")
                }
                NavigationLink { WatchSearchView() } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                NavigationLink { WatchDownloadsView() } label: {
                    Label("Downloads", systemImage: "arrow.down.circle.fill")
                }
            }

            Section {
                NavigationLink { WatchDJView() } label: {
                    LabeledContent {
                        if link.djState.isEngineLive {
                            Text("On")
                        }
                    } label: {
                        Label("Auto Mix", systemImage: "wand.and.stars")
                    }
                }
                NavigationLink { WatchSettingsView() } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }
            }
        }
        .navigationTitle("Sounding")
        .watchNavigationTint()
    }
}

struct WatchNowPlayingChip: View {
    let nowPlaying: WatchNowPlaying
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            WatchArtwork(url: nowPlaying.artworkURL, size: 28, corner: 6, identity: nowPlaying.trackId ?? nowPlaying.title)
            VStack(alignment: .leading, spacing: 0) {
                Text(nowPlaying.title)
                    .font(.body)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .contentTransition(reduceMotion ? .identity : .interpolate)
                Text(nowPlaying.displayOutputName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            Spacer(minLength: 0)
            Image(systemName: nowPlaying.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: nowPlaying.trackId)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: nowPlaying.isPlaying)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now Playing, \(nowPlaying.title), on \(nowPlaying.displayOutputName)")
        .accessibilityValue(nowPlaying.isPlaying ? "Playing" : "Paused")
    }
}

struct WatchSignInGate: View {
    @EnvironmentObject private var link: WatchLinkClient
    @EnvironmentObject private var credentials: WatchCredentialSource

    var body: some View {
        ContentUnavailableView {
            Label(
                link.isReachable ? "Sign In on iPhone" : "iPhone Not Reachable",
                systemImage: link.isReachable ? "iphone.and.arrow.forward" : "iphone.slash"
            )
        } description: {
            Text(link.isReachable
                 ? "Open Sounding on iPhone."
                 : "Bring your iPhone closer.")
        } actions: {
            if credentials.isAdopting {
                ProgressView()
                    .accessibilityLabel("Signing in")
            } else {
                Button("Try Again") {
                    Task { await credentials.adoptFromPhone() }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

#if DEBUG
struct WatchWidgetFamiliesPreview: View {
    private static func entry(playing: Bool?) -> WatchNowPlayingEntry {
        guard let playing else { return WatchNowPlayingEntry(date: .now, nowPlaying: nil, resume: nil) }
        let item = SoundingSnapshot.Item(
            kind: .track,
            id: "preview-1",
            title: "Midnight Transit",
            subtitle: "Glass District",
            duration: 312
        )
        return WatchNowPlayingEntry(
            date: .now,
            nowPlaying: SoundingSnapshot.NowPlaying(
                item: item,
                anchor: SoundingSnapshot.PositionAnchor(position: 94, anchoredAt: .now, rate: playing ? 1 : 0),
                isPlaying: playing,
                collectionID: nil,
                queueIndex: nil,
                queueCount: 7
            ),
            resume: nil
        )
    }

    private let samples: [(WidgetFamily, CGSize)] = [
        (.accessoryCircular, CGSize(width: 76, height: 76)),
        (.accessoryRectangular, CGSize(width: 148, height: 64)),
        (.accessoryCorner, CGSize(width: 76, height: 76)),
        (.accessoryInline, CGSize(width: 148, height: 24))
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                        cell(sample.0, size: sample.1, playing: true).id(index)
                    }
                    cell(.accessoryCircular, size: samples[0].1, playing: false).id(4)
                    cell(.accessoryRectangular, size: samples[1].1, playing: false).id(5)
                    cell(.accessoryCircular, size: samples[0].1, playing: nil).id(6)
                    cell(.accessoryRectangular, size: samples[1].1, playing: nil).id(7)
                }
            }
            .task { await proxy.scrollToPreviewTarget() }
        }
        .navigationTitle("Widgets")
    }

    private func cell(_ family: WidgetFamily, size: CGSize, playing: Bool?) -> some View {
        WatchNowPlayingWidgetView(entry: Self.entry(playing: playing), family: family)
            .frame(width: size.width, height: size.height)
            .background(.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
#endif
