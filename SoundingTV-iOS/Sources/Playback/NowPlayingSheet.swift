import SwiftUI
import TipKit
import UIKit

// MARK: - Screen state

@MainActor
@Observable
final class NowPlayingRouter {
    var isList = false
    var pane: NowPlayingPane = .upNext
    var showingOutput = false
    var showingCues = false
    var showingSetlist = false
    var showingAutoMixStart = false
    var showingDecks = false
    var showingAutoMixPlan = false
    var tapeZoomTrackId: String?
    var alert: (title: String, message: String)?
    let identifier = NowPlayingIdentifier()

    func open(_ pane: NowPlayingPane) {
        self.pane = pane
        isList = true
    }

    func toggle(_ pane: NowPlayingPane) {
        if isList, self.pane == pane {
            isList = false
        } else {
            open(pane)
        }
    }
}

@MainActor
enum NowPlayingLaunch {
    static var pane: NowPlayingPane?
}

struct NowPlayingContext {
    let waveformStore: PhoneWaveformStore
    let cueBoard: CueBoard
    let router: NowPlayingRouter
    let likes: NowPlayingLikeModel
    let artwork: NowPlayingArtworkLoader
    let onClose: () -> Void
}

// MARK: - Sheet

struct NowPlayingSheet: View {
    @Binding private var isPresented: Bool

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var waveformStore = PhoneWaveformStore()
    @State private var cueBoard = CueBoard()
    @State private var artwork = NowPlayingArtworkLoader()
    @State private var router = NowPlayingRouter()
    private let likes = NowPlayingLikeModel.shared
    @State private var keyboardHeight: CGFloat = 0

    init(isPresented: Binding<Bool>) {
        _isPresented = isPresented
        let router = NowPlayingRouter()
        if let pane = NowPlayingLaunch.pane { router.open(pane) }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let pane: NowPlayingPane? = switch environment["SOUNDING_TV_NOW_PLAYING_REVIEW"] {
        case "upNext": .upNext
        case "comments": .comments
        case "tracklist": .tracklist
        case "about": .about
        case "lyrics": .lyrics
        default: nil
        }
        if let pane { router.open(pane) }
        if environment["SOUNDING_TV_NP_SHOT"]?.hasPrefix("identify") == true { router.open(.tracklist) }
        #endif
        _router = State(initialValue: router)
    }

    private var context: NowPlayingContext {
        NowPlayingContext(
            waveformStore: waveformStore,
            cueBoard: cueBoard,
            router: router,
            likes: likes,
            artwork: artwork,
            onClose: closePlayer
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let safe = proxy.safeAreaInsets
            let size = CGSize(width: proxy.size.width, height: proxy.size.height + safe.top + safe.bottom)
            if usesColumns(size) {
                NowPlayingPadLayout(context: context, size: size, safe: safe, keyboard: keyboardHeight)
            } else {
                NowPlayingPhoneLayout(context: context, size: size, safe: safe, keyboard: keyboardHeight)
            }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear { NowPlayingLaunch.pane = nil }
        .background {
            ZStack {
                NowPlayingBackdropView(loader: artwork, identity: backdropIdentity, hasArtwork: coordinator.nowPlaying?.artworkURL != nil)
                NowPlayingLineArtLayer(
                    timeline: coordinator.timeline,
                    store: waveformStore,
                    loader: artwork,
                    trackId: coordinator.nowPlaying?.trackId,
                    hasArtwork: coordinator.nowPlaying?.artworkURL != nil,
                    usesColumns: usesColumnsHint
                )
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .behindTheTrackHost { BehindTheTrackSheet(track: $0) }
        .accessibilityAction(.escape) {
            if router.isList, !usesColumnsHint {
                router.isList = false
            } else {
                closePlayer()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = frame.height }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = 0 }
        }
        .modifier(NowPlayingLifecycle(
            artwork: artwork,
            waveformStore: waveformStore,
            likes: likes,
            router: router,
            onEmpty: closePlayer
        ))
        .background {
            NowPlayingFeeds(
                store: waveformStore,
                cueBoard: cueBoard,
                trackId: coordinator.nowPlaying?.trackId,
                duration: coordinator.nowPlaying?.duration ?? 0
            )
        }
        .modifier(NowPlayingSheets(router: router, waveformStore: waveformStore, cueBoard: cueBoard))
        .overlay {
            if coordinator.isRemoteUnreachable {
                NowPlayingRemoteUnavailable(
                    name: coordinator.currentOutput.name,
                    onRetry: coordinator.retryRemote,
                    onPlayHere: { Task { await coordinator.move(to: .thisDevice) } },
                    onClose: closePlayer
                )
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: coordinator.isRemoteUnreachable)
        #if DEBUG
        .overlay(alignment: .topLeading) { NowPlayingSeekProbeLabel() }
        #endif
    }

    private var usesColumnsHint: Bool {
        PadLayout.isPad && horizontalSizeClass == .regular
    }

    private var backdropIdentity: String {
        coordinator.nowPlaying?.trackId ?? coordinator.nowPlaying?.displayTitle ?? "Now Playing"
    }

    private func usesColumns(_ size: CGSize) -> Bool {
        PadLayout.isPad && horizontalSizeClass == .regular && size.width >= 760
    }

    private func closePlayer() {
        isPresented = false
    }
}

private struct NowPlayingRemoteUnavailable: View {
    let name: String
    let onRetry: () -> Void
    let onPlayHere: () -> Void
    let onClose: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("\(name) Isn’t Reachable", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Make sure it’s awake and on the same Wi‑Fi network.")
        } actions: {
            Button("Try Again", action: onRetry)
                .buttonStyle(.bordered)
            Button("Play on This \(DeviceClass.current.displayName)", action: onPlayHere)
            Button("Close", action: onClose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.96).ignoresSafeArea())
    }
}

private struct NowPlayingLifecycle: ViewModifier {
    let artwork: NowPlayingArtworkLoader
    let waveformStore: PhoneWaveformStore
    let likes: NowPlayingLikeModel
    let router: NowPlayingRouter
    let onEmpty: () -> Void

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared

    private var trackId: String? { coordinator.nowPlaying?.trackId }

    func body(content: Content) -> some View {
        content
            .onChange(of: coordinator.nowPlaying?.artworkURL, initial: true) { _, url in
                artwork.load(url)
            }
            .onChange(of: coordinator.nowPlaying == nil) { _, isEmpty in
                if isEmpty { onEmpty() }
            }
            .onChange(of: trackId, initial: true) { _, trackId in
                waveformStore.ensureLoaded(trackId: trackId)
                likes.refresh(trackId: trackId, resolved: waveformStore.resolvedTrack)
                router.identifier.reset(for: trackId)
            }
            .onReceive(LikesSyncEngine.shared.$revision.dropFirst()) { _ in
                likes.refresh(trackId: trackId, resolved: waveformStore.resolvedTrack)
            }
            .onChange(of: credentials.sessionHealth.canMakeAuthenticatedRequests) { _, canLoad in
                guard canLoad else { return }
                waveformStore.ensureLoaded(trackId: trackId)
            }
    }
}

private struct NowPlayingFeeds: View {
    @ObservedObject var store: PhoneWaveformStore
    let cueBoard: CueBoard
    let trackId: String?
    let duration: TimeInterval

    private var feedKey: String {
        "\(trackId ?? "-")#\(store.waveform.samples?.count ?? 0)#\(Int(duration))"
    }

    private var seedKey: String {
        "\(store.resolvedTrack?.id ?? "-")#\(store.comments.count)"
    }

    var body: some View {
        Color.clear
            .onChange(of: feedKey, initial: true) { _, _ in
                MusicPulse.shared.ingest(
                    trackId: trackId,
                    samples: store.waveform.samples ?? [],
                    duration: duration
                )
                cueBoard.ensureLoaded(
                    trackId: trackId,
                    duration: duration,
                    waveform: store.waveform.samples.map { Waveform(samples: $0) }
                )
            }
            .onChange(of: seedKey, initial: true) { _, _ in
                guard let track = store.resolvedTrack else { return }
                SetlistIntelligenceStore.shared.seed(track: track, comments: store.comments)
                GeneratedInsightsService.shared.request(
                    GeneratedInsightInputs.input(for: track, comments: store.comments, waveform: store.waveform.samples)
                )
            }
    }
}

private struct NowPlayingSheets: ViewModifier {
    @Bindable var router: NowPlayingRouter
    @ObservedObject var waveformStore: PhoneWaveformStore
    let cueBoard: CueBoard

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.downloadPrompter) private var prompter
    @ObservedObject private var palette = NowPlayingPalette.shared
    @State private var setlistLocalFileURL: URL?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $router.showingCues) {
                if let snapshot = coordinator.nowPlaying, let trackId = snapshot.trackId {
                    TrackMapSheet(
                        trackTitle: snapshot.displayTitle,
                        trackId: trackId,
                        fallbackPosition: coordinator.timeline.anchor.position(at: .now),
                        playbackClock: PlayerService.shared.clock,
                        usesLiveClock: snapshot.source.isLocal,
                        isPlaying: snapshot.isPlaying,
                        duration: snapshot.duration,
                        envelope: waveformStore.waveform.samples ?? [],
                        board: cueBoard,
                        accent: palette.current.accent,
                        onSeek: { coordinator.seek(to: $0) }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
            .sheet(isPresented: $router.showingSetlist) {
                if let track = waveformStore.resolvedTrack {
                    SetlistEditorView(
                        track: track,
                        currentPosition: coordinator.timeline.anchor.position(at: .now),
                        comments: waveformStore.comments,
                        localFileURL: setlistLocalFileURL,
                        onSeek: { coordinator.seek(to: $0) },
                        onDownload: {
                            prompter.request { confirmed in
                                DownloadManager.shared.download(track: track, confirmed: confirmed)
                            }
                        },
                        onPlaySearchResult: { result in
                            Task { await coordinator.play(result, in: [result]) }
                        }
                    )
                }
            }
            .task(id: router.showingSetlist ? waveformStore.resolvedTrack?.id : nil) {
                guard router.showingSetlist, let track = waveformStore.resolvedTrack else {
                    setlistLocalFileURL = nil
                    return
                }
                setlistLocalFileURL = await PlayerService.shared.preparedLocalAudioURL(for: track)
            }
            .sheet(isPresented: $router.showingAutoMixStart) {
                AutoDJStartConfigurationView { configuration in
                    coordinator.startDJSession(configuration: configuration)
                }
            }
            .sheet(isPresented: $router.showingAutoMixPlan) {
                NowPlayingAutoMixPlanSheet(isPresented: $router.showingAutoMixPlan)
                    .environmentObject(coordinator)
            }
            .fullScreenCover(isPresented: $router.showingDecks) {
                PhoneDecksView { router.showingDecks = false }
                    .preferredColorScheme(.dark)
                    .environmentObject(coordinator)
            }
            .alert(
                router.alert?.title ?? "",
                isPresented: Binding(
                    get: { router.alert != nil },
                    set: { if !$0 { router.alert = nil } }
                ),
                presenting: router.alert
            ) { _ in
                Button("OK", role: .cancel) { router.alert = nil }
            } message: { alert in
                Text(alert.message)
            }
            #if DEBUG
            .task {
                let environment = ProcessInfo.processInfo.environment
                if environment["SOUNDING_TV_PHONE_CUES"] == "1" {
                    try? await Task.sleep(for: .seconds(2))
                    router.showingCues = true
                }
                if environment["SOUNDING_TV_NOW_PLAYING_REVIEW"]?.hasPrefix("setlist") == true {
                    try? await Task.sleep(for: .seconds(2))
                    router.showingSetlist = true
                }
                switch environment["SOUNDING_TV_NP_SHOT"] {
                case "automixPlan":
                    try? await Task.sleep(for: .seconds(1.5))
                    router.showingAutoMixPlan = true
                case "output":
                    try? await Task.sleep(for: .seconds(1.5))
                    router.showingOutput = true
                case "identify":
                    try? await Task.sleep(for: .seconds(1.2))
                    router.identifier.identify(
                        track: waveformStore.resolvedTrack,
                        trackId: coordinator.nowPlaying?.trackId,
                        at: coordinator.timeline.anchor.position(at: .now)
                    )
                case "identifyFound":
                    try? await Task.sleep(for: .seconds(1.2))
                    let segment = SetlistSegment(
                        id: "debug.found", startSeconds: 1_090, observedAtSeconds: 1_100,
                        artist: "Juno Vale", title: "Breakwater", version: nil, source: .shazam,
                        confidence: 0.9, evidence: nil, shazamId: nil, soundCloudTrackId: nil, isUserEdited: false
                    )
                    router.identifier.state = .found(segment, coordinator.timeline.anchor.position(at: .now))
                default:
                    break
                }
            }
            #endif
    }
}

// MARK: - Shared pieces

extension NowPlayingContext {
    @MainActor
    func moreActions(coordinator: PhonePlaybackCoordinator, showsComments: Bool, showsLyrics: Bool = true, isPad: Bool) -> NowPlayingMoreActions {
        let router = self.router
        return NowPlayingMoreActions(
            showsComments: showsComments,
            showsLyrics: showsLyrics,
            onTracklist: { isPad ? (router.pane = .tracklist) : router.open(.tracklist) },
            onComments: { isPad ? (router.pane = .comments) : router.open(.comments) },
            onLyrics: { isPad ? (router.pane = .lyrics) : router.open(.lyrics) },
            onAbout: { isPad ? (router.pane = .about) : router.open(.about) },
            onCues: { router.showingCues = true },
            onAutoMix: { isOn in
                AutoMixTip().invalidate(reason: .actionPerformed)
                if isOn {
                    if coordinator.djSnapshot.isEngineLive {
                        coordinator.setAutoMixEnabled(true)
                    } else {
                        router.showingAutoMixStart = true
                    }
                } else {
                    coordinator.setDJEnabled(false)
                    coordinator.setAutoMixEnabled(false)
                }
            },
            onDecks: { router.showingDecks = true },
            nextMove: coordinator.nextMoveLine,
            canMixNow: coordinator.canMixNow,
            canExtend: coordinator.canExtendMix,
            onMixNow: { coordinator.mixNow() },
            onExtend: { coordinator.extendMix() },
            sleepTimer: coordinator.sleepTimer,
            offersEndOfMix: coordinator.offersEndOfMix,
            onSleepTimer: {
                SleepTimerTip().invalidate(reason: .actionPerformed)
                coordinator.setSleepTimer($0)
            }
        )
    }
}

struct NowPlayingHeroArt: View {
    let context: NowPlayingContext
    let snapshot: NowPlayingSnapshot
    let side: CGFloat
    var gap: CGFloat = 44
    var cornerRadius: CGFloat = 14
    var isEnabled = true
    var showsRouteBadge = true

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentPreview: PhonePlaybackCoordinator.SkipPreview {
        PhonePlaybackCoordinator.SkipPreview(
            title: snapshot.displayTitle,
            artist: snapshot.displayArtist,
            artworkURL: snapshot.artworkURL,
            trackID: snapshot.trackId
        )
    }

    var body: some View {
        SkipCarousel(
            current: currentPreview,
            currentID: snapshot.trackId ?? "\(snapshot.displayTitle)#\(snapshot.displayArtist)",
            previous: coordinator.previousSkipPreview,
            next: coordinator.nextSkipPreview,
            commitThreshold: 0.28,
            isEnabled: isEnabled,
            gap: gap,
            clips: false,
            onCommit: { edge in
                if edge == .trailing { coordinator.next() } else { coordinator.previous() }
            }
        ) { preview, isCurrent in
            NowPlayingArtworkTile(
                urlString: preview.artworkURL,
                identity: preview.trackID ?? preview.title,
                size: side,
                isCurrent: isCurrent,
                cornerRadius: cornerRadius,
                isRaised: snapshot.isPlaying
            )
            .kyleCrowned(user: nil, context: preview.artist)
            .overlay(alignment: .bottomLeading) {
                if isCurrent, showsRouteBadge, !snapshot.source.isLocal {
                    NowPlayingRouteBadge(device: snapshot.source, isConnecting: !snapshot.isAvailable)
                        .padding(14)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomLeading)))
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : NPMotion.bouncy, value: snapshot.source)
        }
        .frame(width: side, height: side)
        .nowPlayingDragSource(coordinator.currentTrack)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing, \(snapshot.displayTitle) by \(snapshot.displayArtist)")
        .popoverTip(isEnabled && coordinator.nextSkipPreview != nil ? NowPlayingSwipeTip() : nil, arrowEdge: .bottom)
        .onAppear { SoundingTips.noteNowPlayingOpened() }
        .onChange(of: neighbourArtworkURLs, initial: true) { _, urls in
            ArtworkCache.shared.prefetch(urls, variant: .standard)
        }
    }

    private var neighbourArtworkURLs: [URL] {
        [coordinator.previousSkipPreview?.artworkURL, coordinator.nextSkipPreview?.artworkURL]
            .compactMap { $0.flatMap(URL.init) }
    }
}

struct NowPlayingActions: View {
    let context: NowPlayingContext
    let snapshot: NowPlayingSnapshot
    let diameter: CGFloat
    var isPad = false

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject var store: PhoneWaveformStore
    @ObservedObject var cueBoard: CueBoard
    @ObservedObject private var setlists = SetlistIntelligenceStore.shared

    private var resolved: Track? {
        store.resolvedTrack?.id == snapshot.trackId ? store.resolvedTrack : nil
    }

    private var isMix: Bool {
        !(setlists.tracklist(for: snapshot.trackId)?.isEmpty ?? true)
    }

    var body: some View {
        let glass = NowPlayingTint.glass(context.artwork.tint)
        HStack(spacing: 2) {
            if let sleep = coordinator.sleepTimer {
                SleepTimerIndicator(status: sleep)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(NPInk.secondary)
                    .padding(.trailing, 6)
            }
            if !snapshot.isDeviceTrack {
                NowPlayingLikeButton(
                    trackId: snapshot.trackId,
                    resolved: resolved,
                    likes: context.likes,
                    diameter: diameter,
                    glassTint: glass
                )
            }
            NowPlayingMoreMenu(
                track: resolved,
                trackId: snapshot.trackId,
                isDeviceTrack: snapshot.isDeviceTrack,
                diameter: diameter,
                glassTint: glass,
                cueCount: cueBoard.sheet.userCues.count,
                isAutoMixOn: coordinator.djSnapshot.isEngineLive || coordinator.nextMoveLine != nil,
                actions: context.moreActions(coordinator: coordinator, showsComments: isMix && !isPad && !snapshot.isDeviceTrack, showsLyrics: !setlists.isMix(trackID: snapshot.trackId, title: snapshot.title, duration: snapshot.duration), isPad: isPad)
            )
        }
    }
}

struct NowPlayingDock: View {
    let context: NowPlayingContext
    let snapshot: NowPlayingSnapshot
    var style: NowPlayingScrubberStyle = .phone
    var isPad = false
    var tapeStyle = NowPlayingTape.style(isPad: false, timesHeight: 16)
    var bleed = TapeBleed(leading: 24, trailing: 24)

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    private var router: NowPlayingRouter { context.router }

    private var marks: NowPlayingWaveformMarks {
        guard isPad || router.isList else { return .none }
        switch router.pane {
        case .tracklist: return .segments
        case .comments: return .comments
        default: return .none
        }
    }

    var body: some View {
        let duration = coordinator.timeline.anchor.duration
        if NowPlayingTape.isActive(router: router, trackId: snapshot.trackId, duration: duration) {
            NowPlayingTapeScrubber(
                timeline: coordinator.timeline,
                trackId: snapshot.trackId,
                tint: context.artwork.tint,
                onSeek: { coordinator.seek(to: $0) },
                store: context.waveformStore,
                style: tapeStyle,
                bleed: bleed,
                compact: !isPad && router.isList,
                initialSpan: duration >= NowPlayingTape.threshold ? 240 : max(30, duration / 3),
                onZoomOutToFit: duration >= NowPlayingTape.threshold ? nil : { router.tapeZoomTrackId = nil }
            )
            .transition(.opacity)
        } else {
            NowPlayingScrubber(
                timeline: coordinator.timeline,
                trackId: snapshot.trackId,
                tint: context.artwork.tint,
                onSeek: { coordinator.seek(to: $0) },
                store: context.waveformStore,
                style: style,
                marks: marks,
                showsBubble: isPad ? router.pane != .comments : !router.isList,
                showsCurrentEntry: !isPad && router.isList,
                onPinchIn: { router.tapeZoomTrackId = snapshot.trackId }
            )
            .transition(.opacity)
        }
    }
}

struct NowPlayingPaneContent: View {
    let context: NowPlayingContext
    let snapshot: NowPlayingSnapshot
    let pane: NowPlayingPane
    var style = NowPlayingPaneStyle()

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject var store: PhoneWaveformStore

    private var resolved: Track? {
        store.resolvedTrack?.id == snapshot.trackId ? store.resolvedTrack : nil
    }

    var body: some View {
        let tint = context.artwork.tint
        let router = context.router
        switch pane {
        case .upNext:
            NowPlayingUpNextPane(style: style)
        case .comments where !snapshot.isDeviceTrack:
            NowPlayingCommentsPane(
                trackId: snapshot.trackId,
                tint: tint,
                store: store,
                timeline: coordinator.timeline,
                onSeek: { time in
                    coordinator.seek(to: time)
                    if !snapshot.isPlaying { coordinator.play() }
                },
                style: style,
                onError: { router.alert = ("Couldn't Post Comment", $0) }
            )
        case .tracklist, .comments:
            NowPlayingTracklistPane(
                trackId: snapshot.trackId,
                resolvedTrack: resolved,
                tint: tint,
                timeline: coordinator.timeline,
                identifier: router.identifier,
                onSeek: { coordinator.seek(to: $0) },
                onEdit: { router.showingSetlist = true },
                style: style
            )
        case .about:
            NowPlayingAboutPane(
                track: resolved,
                commentCount: store.comments.count,
                style: style,
                onSeek: { time in
                    coordinator.seek(to: time)
                    if !snapshot.isPlaying { coordinator.play() }
                },
                onTracklist: { router.pane = .tracklist }
            )
        case .lyrics:
            let anchor = coordinator.timeline.anchor
            NowPlayingLyrics(
                track: resolved,
                nextTrack: coordinator.upcomingTrack,
                playhead: LyricsPlayhead(position: anchor.position, date: anchor.date, rate: anchor.rate),
                style: style.inset > 24 ? .pad : .phone,
                onSeek: { time in
                    coordinator.seek(to: time)
                    if !snapshot.isPlaying { coordinator.play() }
                }
            )
        }
    }
}

struct NowPlayingOutputButton<Label: View>: View {
    let context: NowPlayingContext
    var showsClose = true
    @ViewBuilder let label: () -> Label

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    var body: some View {
        @Bindable var router = context.router
        Button {
            router.showingOutput = true
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SonosOutputController.shared.activeGroup.map { "Output, \($0.displayName)" } ?? (coordinator.isRemoteOutput ? "Output, \(coordinator.currentOutput.name)" : "Output"))
        .accessibilityHint("Chooses where music plays")
        .popover(isPresented: $router.showingOutput) {
            ConnectSheet(onDone: { router.showingOutput = false })
                .environmentObject(coordinator)
                .frame(idealWidth: 420, idealHeight: 620)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCompactAdaptation(.sheet)
        }
    }
}

// MARK: - Phone

private struct NowPlayingPhoneMetrics {
    let width: CGFloat
    let height: CGFloat
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let titleHeight: CGFloat
    let segHeight: CGFloat
    let tabsHeight: CGFloat
    let timesHeight: CGFloat
    let keyboard: CGFloat
    var waveHeight: CGFloat = 36
    var mixLine: CGFloat = 0
    var tapeHeight: CGFloat = 0

    var inset: CGFloat { 24 }
    var content: CGFloat { width - inset * 2 }
    var bottomRowTop: CGFloat { height - max(safeBottom, 12) - 14 - 48 }
    var volumeTop: CGFloat { bottomRowTop - 32 - 28 }
    var transportTop: CGFloat { volumeTop - 30 - 70 - mixLine }
    var mixLineTop: CGFloat { transportTop + 70 + 4 }
    var dockHeight: CGFloat { waveHeight + 9 + timesHeight }
    var dockTop: CGFloat { transportTop - 27 - timesHeight - 9 - waveHeight }
    var segTop: CGFloat { dockTop - 14 - (tapeHeight > 0 ? max(segHeight, tapeHeight - dockHeight - 14 + 6) : segHeight) }
    var tapeTop: CGFloat { dockTop + dockHeight - tapeHeight }
    var titleTop: CGFloat { segTop - 8 - titleHeight }
    var artTop: CGFloat { safeTop + 30 }
    var art: CGFloat { max(0, min(content, titleTop - 26 - artTop)) }
    var artX: CGFloat { (width - art) / 2 }
    var grabCenter: CGFloat { safeTop + 5 }
    var titleWidth: CGFloat { content - 100 }
    var actionsX: CGFloat { width - inset - 82 }

    var headTop: CGFloat { safeTop + 8 }
    var headArt: CGFloat { 64 }
    var titleScale: CGFloat { 17.0 / 22.0 }
    var titleListX: CGFloat { inset + headArt + 14 }
    var modebarTop: CGFloat { headTop + max(headArt, titleHeight * titleScale + 6) + 14 }
    var panesTop: CGFloat { modebarTop + tabsHeight + 16 }
    var transportListCenter: CGFloat { bottomRowTop - 38 }
    var dockListTop: CGFloat { transportListCenter - 28 - 7 - timesHeight - 9 - waveHeight }
    var panesBottom: CGFloat { keyboard > 0 ? height - keyboard - 10 : dockListTop - 12 }
}

struct NowPlayingPhoneLayout: View {
    let context: NowPlayingContext
    let size: CGSize
    let safe: EdgeInsets
    let keyboard: CGFloat

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var titleLine: CGFloat = 27
    @ScaledMetric(relativeTo: .subheadline) private var segLine: CGFloat = 26
    @ScaledMetric(relativeTo: .caption) private var timesLine: CGFloat = 16
    @State private var isMoving = false
    @State private var tabsHeight: CGFloat = 36

    private var router: NowPlayingRouter { context.router }

    private var autoMix: AutoMixLiveState? { coordinator.autoMixLive }

    private var showsAutoMixDecks: Bool { autoMix?.stage == .mixing && autoMix?.outgoing != nil }

    private var ratingPending: Bool { AutoMixFeedbackStore.shared.pending != nil }

    private var tapeStyle: TapeScrubberStyle { NowPlayingTape.style(isPad: false, timesHeight: timesLine) }

    private func isTape(_ snapshot: NowPlayingSnapshot) -> Bool {
        NowPlayingTape.isActive(router: router, trackId: snapshot.trackId, duration: coordinator.timeline.anchor.duration)
    }

    private var metrics: NowPlayingPhoneMetrics {
        var metrics = baseMetrics
        if let snapshot = coordinator.nowPlaying, isTape(snapshot), !showsAutoMixDecks {
            metrics.tapeHeight = tapeStyle.height
        }
        return metrics
    }

    private var baseMetrics: NowPlayingPhoneMetrics {
        NowPlayingPhoneMetrics(
            width: size.width,
            height: size.height,
            safeTop: safe.top,
            safeBottom: safe.bottom,
            titleHeight: titleLine * 2,
            segHeight: segLine,
            tabsHeight: tabsHeight,
            timesHeight: timesLine,
            keyboard: keyboard,
            waveHeight: showsAutoMixDecks ? NowPlayingAutoMixMetrics.decksHeight - 9 - timesLine : 36,
            mixLine: autoMix.map { NowPlayingAutoMixMetrics.lineHeight(for: $0) + 6 } ?? (ratingPending ? 78 + 6 : 0)
        )
    }

    var body: some View {
        if let snapshot = coordinator.nowPlaying {
            if dynamicTypeSize.isAccessibilitySize || metrics.art < 150 {
                NowPlayingAccessibleLayout(context: context, snapshot: snapshot, size: size, safe: safe)
            } else if reduceMotion {
                ZStack {
                    morph(snapshot, isList: router.isList)
                        .id(router.isList)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.2), value: router.isList)
            } else {
                morph(snapshot, isList: router.isList)
                    .animation(NPMotion.spring, value: router.isList)
            }
        }
    }

    private func morph(_ snapshot: NowPlayingSnapshot, isList: Bool) -> some View {
        let m = metrics
        let tint = context.artwork.tint
        let pausedScale: CGFloat = (snapshot.isPlaying || isList || reduceMotion) ? 1 : 0.84
        let artScale = isList ? m.headArt / max(m.art, 1) : (isMoving ? 0.94 : pausedScale)
        let keyboardUp = keyboard > 0 && isList
        return ZStack(alignment: .topLeading) {
            grab
                .position(x: m.width / 2, y: m.grabCenter)

            ListenTogetherIndicator()
                .font(.caption.weight(.semibold))
                .foregroundStyle(NPInk.secondary)
                .fixedSize()
                .position(x: m.width / 2, y: m.grabCenter + 15)
                .opacity(isList ? 0 : 1)

            NowPlayingHeroArt(
                context: context,
                snapshot: snapshot,
                side: m.art,
                cornerRadius: isList ? 52 * m.art / 392 : 14,
                isEnabled: !isList,
                showsRouteBadge: !isList
            )
            .scaleEffect(artScale, anchor: .topLeading)
            .offset(
                x: isList ? m.inset : m.artX + m.art * (1 - artScale) / 2,
                y: isList ? m.headTop : m.artTop + m.art * (1 - artScale) / 2
            )
            .animation(reduceMotion ? nil : NPMotion.spring, value: pausedScale)
            .animation(reduceMotion ? nil : NPMotion.spring, value: isMoving)

            if isList {
                Button {
                    router.isList = false
                } label: {
                    Color.clear
                        .frame(width: m.titleListX + m.titleWidth * m.titleScale - m.inset, height: m.headArt)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: m.inset, y: m.headTop)
                .accessibilityLabel("Back to Now Playing")
            }

            Button { router.open(.about) } label: {
                titleBlock(snapshot, tint: tint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: m.titleWidth, alignment: .leading)
            .scaleEffect(isList ? m.titleScale : 1, anchor: .topLeading)
            .offset(
                x: isList ? m.titleListX : m.inset,
                y: isList ? m.headTop + 6 : m.titleTop
            )
            .allowsHitTesting(!isList)
            .accessibilityHint(isList ? "" : "Shows Behind the Track")

            NowPlayingMixLine(trackId: snapshot.trackId, timeline: coordinator.timeline) {
                router.open(.tracklist)
            }
            .frame(width: m.content, height: m.segHeight + 18, alignment: .leading)
            .scaleEffect(isList ? m.titleScale : 1, anchor: .topLeading)
            .offset(
                x: isList ? m.titleListX : m.inset,
                y: isList ? m.headTop + 11 : m.segTop - 9
            )
            .opacity(isList || m.tapeHeight > 0 ? 0 : 1)
            .allowsHitTesting(!isList && m.tapeHeight == 0)
            .accessibilityHidden(m.tapeHeight > 0)

            NowPlayingActions(
                context: context,
                snapshot: snapshot,
                diameter: 36,
                store: context.waveformStore,
                cueBoard: context.cueBoard
            )
            .offset(x: m.actionsX - 4, y: isList ? m.headTop + 10 : m.titleTop + 2)

            if isList {
                NowPlayingPhoneTabs(router: router, snapshot: snapshot)
                    .frame(width: m.content, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tabsHeight = $0 }
                    .offset(x: m.inset, y: m.modebarTop)
                    .transition(.opacity.combined(with: .offset(y: 24)))

                NowPlayingPhonePanes(context: context, snapshot: snapshot)
                    .frame(width: m.width, height: max(0, m.panesBottom - m.panesTop))
                    .offset(y: m.panesTop)
                    .transition(.opacity.combined(with: .offset(y: 40)))
            }

            NowPlayingDock(context: context, snapshot: snapshot, tapeStyle: tapeStyle, bleed: TapeBleed(leading: m.inset, trailing: m.inset))
                .frame(width: m.content)
                .offset(x: m.inset, y: isList ? m.dockListTop : (m.tapeHeight > 0 ? m.tapeTop : m.dockTop + (showsAutoMixDecks && !isList ? m.waveHeight - 36 : 0)))
                .opacity(keyboardUp || (showsAutoMixDecks && !isList) ? 0 : 1)
                .allowsHitTesting(!(showsAutoMixDecks && !isList))

            if let autoMix, showsAutoMixDecks, !isList {
                NowPlayingAutoMixDecks(state: autoMix, tint: tint)
                    .frame(width: m.content, height: m.dockHeight, alignment: .top)
                    .offset(x: m.inset, y: m.dockTop)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }

            NowPlayingTransport(snapshot: snapshot)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(width: m.width - 72, height: 70)
                .scaleEffect(isList ? 0.8 : 1)
                .offset(x: 36, y: isList ? m.transportListCenter - 35 : m.transportTop)
                .opacity(keyboardUp ? 0 : 1)

            if let autoMix, !isList {
                NowPlayingAutoMixLine(state: autoMix, tint: tint) { router.showingAutoMixPlan = true }
                    .frame(width: m.content, height: NowPlayingAutoMixMetrics.lineHeight(for: autoMix))
                    .offset(x: m.inset, y: m.mixLineTop)
                    .transition(.opacity)
            } else if ratingPending, !isList {
                AutoMixRatingView()
                    .foregroundStyle(NPInk.primary)
                    .frame(width: m.content, height: 78)
                    .offset(x: m.inset, y: m.mixLineTop)
                    .transition(.opacity)
            }

            NowPlayingVolumeSlider()
                .frame(width: m.content)
                .offset(x: m.inset, y: isList ? m.volumeTop + 32 : m.volumeTop - 8)
                .opacity(isList ? 0 : 1)
                .allowsHitTesting(!isList)
                .accessibilityHidden(isList)

            NowPlayingPhoneBottomBar(context: context, snapshot: snapshot)
                .frame(width: m.width - 100, height: 48)
                .offset(x: 50, y: m.bottomRowTop)
                .opacity(keyboardUp ? 0 : 1)
        }
        .frame(width: m.width, height: m.height, alignment: .topLeading)
        .ignoresSafeArea()
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : NPMotion.spring, value: showsAutoMixDecks)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : NPMotion.spring, value: autoMix == nil)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : NPMotion.spring, value: ratingPending)
        .onChange(of: coordinator.currentOutput.id) { _, _ in
            guard !reduceMotion else { return }
            isMoving = true
            Task {
                try? await Task.sleep(for: .milliseconds(420))
                isMoving = false
            }
        }
    }

    private func titleBlock(_ snapshot: NowPlayingSnapshot, tint: Color) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                NowPlayingTitleBlock(title: snapshot.displayTitle, artist: snapshot.displayArtist, tint: tint, trackId: snapshot.trackId)
                SoundCloudPreviewNowPlayingLine(trackID: snapshot.trackId)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(NPInk.secondary)
                StationNowPlayingLine(source: coordinator.queueSource)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(NPInk.secondary)
            }
                .id(snapshot.trackId ?? snapshot.displayTitle)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: -10)))
        }
        .animation(.easeOut(duration: 0.18), value: snapshot.trackId)
    }

    private var grab: some View {
        Button(action: context.onClose) {
            Capsule()
                .fill(NPInk.faint)
                .frame(width: 38, height: 5)
                .frame(width: 120, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close Now Playing")
    }
}

private struct NowPlayingPhoneTabs: View {
    let router: NowPlayingRouter
    let snapshot: NowPlayingSnapshot

    @ObservedObject private var setlists = SetlistIntelligenceStore.shared

    var body: some View {
        let isMix = !(setlists.tracklist(for: snapshot.trackId)?.isEmpty ?? true)
        let hidesLyrics = setlists.isMix(trackID: snapshot.trackId, title: snapshot.title, duration: snapshot.duration)
        NowPlayingPaneTabs(router: router, panes: NowPlayingPane.phoneTabs(isMix: isMix, isDeviceTrack: snapshot.isDeviceTrack, hidesLyrics: hidesLyrics, showing: router.pane))
    }
}

struct NowPlayingPaneTabs: View {
    let router: NowPlayingRouter
    let panes: [NowPlayingPane]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal) { row }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
        }
        .sensoryFeedback(.selection, trigger: router.pane)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing Details")
    }

    private var row: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(panes) { pane in
                    tab(pane)
                }
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .fixedSize()
    }

    @ViewBuilder
    private func tab(_ pane: NowPlayingPane) -> some View {
        let isSelected = router.pane == pane
        let button = Button {
            withAnimation(reduceMotion ? nil : .snappy) { router.pane = pane }
        } label: {
            Text(pane.rawValue)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.black : NPInk.primary)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        if isSelected {
            button
                .buttonStyle(.glassProminent)
                .tint(.white)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

private struct NowPlayingPhonePanes: View {
    let context: NowPlayingContext
    let snapshot: NowPlayingSnapshot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pane = context.router.pane
        ZStack {
            NowPlayingPaneContent(context: context, snapshot: snapshot, pane: pane, store: context.waveformStore)
                .id(pane)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.26), value: pane)
    }
}

private struct NowPlayingPhoneBottomBar: View {
    let context: NowPlayingContext
    let snapshot: NowPlayingSnapshot

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject private var setlists = SetlistIntelligenceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var routeBounce = 0

    private var router: NowPlayingRouter { context.router }

    private var showsCaptions: Bool { dynamicTypeSize.isAccessibilitySize }

    private var isMix: Bool {
        !(setlists.tracklist(for: snapshot.trackId)?.isEmpty ?? true)
    }

    var body: some View {
        HStack(spacing: 0) {
            if isMix || snapshot.isDeviceTrack {
                modeButton(.tracklist, systemImage: "music.note.list")
            } else {
                modeButton(.comments, systemImage: "bubble.left")
            }
            Spacer(minLength: 0)
            routeButton
            Spacer(minLength: 0)
            modeButton(.upNext, systemImage: "list.bullet")
        }
        .onChange(of: coordinator.currentOutput.id) { _, _ in routeBounce += 1 }
    }

    private func modeButton(_ pane: NowPlayingPane, systemImage: String) -> some View {
        let isOn = router.isList && router.pane == pane
        return Button {
            router.toggle(pane)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .medium))
                if showsCaptions {
                    Text(pane.rawValue)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(isOn ? NPInk.primary : NPInk.secondary)
            .frame(minWidth: 50, minHeight: 46)
            .padding(.horizontal, showsCaptions ? 6 : 0)
            .background(isOn ? NPInk.fillStrong : .clear, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion, scale: 0.9))
        .animation(.easeInOut(duration: 0.25), value: isOn)
        .accessibilityLabel(pane.rawValue)
        .accessibilityHint(isOn ? "Returns to Now Playing" : "Shows \(pane.rawValue.lowercased())")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var routeButton: some View {
        let remote = !coordinator.currentOutput.isLocal
        let tint = context.artwork.tint
        return NowPlayingOutputButton(context: context) {
            VStack(spacing: 2) {
                Image(systemName: remote ? coordinator.currentOutput.symbolName : "airplay.audio")
                    .font(.system(size: 19, weight: .medium))
                    .symbolEffect(.bounce, value: reduceMotion ? 0 : routeBounce)
                if showsCaptions {
                    Text(remote ? coordinator.currentOutput.name : "Output")
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(remote ? tint : NPInk.secondary)
            .frame(minWidth: 50, minHeight: 46)
            .padding(.horizontal, showsCaptions ? 6 : 0)
            .overlay(alignment: .bottom) {
                if remote && !showsCaptions {
                    Text(coordinator.currentOutput.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(y: 14)
                }
            }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Accessibility sizes

private struct NowPlayingAccessibleLayout: View {
    let context: NowPlayingContext
    let snapshot: NowPlayingSnapshot
    let size: CGSize
    let safe: EdgeInsets

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    private var router: NowPlayingRouter { context.router }

    var body: some View {
        let tint = context.artwork.tint
        let side = min(size.width - 48, 300)
        VStack(spacing: 0) {
            if router.isList {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        Button { router.isList = false } label: {
                            NowPlayingTitleBlock(title: snapshot.displayTitle, artist: snapshot.displayArtist, tint: tint, font: .headline, trackId: snapshot.trackId)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Returns to Now Playing")
                        NowPlayingActions(context: context, snapshot: snapshot, diameter: 44, store: context.waveformStore, cueBoard: context.cueBoard)
                    }
                    NowPlayingPhoneTabs(router: router, snapshot: snapshot)
                        .padding(.bottom, 4)
                }
                .padding(.horizontal, 24)
                .padding(.top, safe.top + 8)
                NowPlayingPhonePanes(context: context, snapshot: snapshot)
                    .frame(maxHeight: .infinity)
                NowPlayingPhoneBottomBar(context: context, snapshot: snapshot)
                    .padding(.horizontal, 50)
                    .padding(.bottom, max(safe.bottom, 12))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Button(action: context.onClose) {
                            Capsule().fill(NPInk.faint).frame(width: 38, height: 5)
                                .frame(maxWidth: .infinity, minHeight: 26)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close Now Playing")

                        NowPlayingHeroArt(context: context, snapshot: snapshot, side: side)
                            .frame(maxWidth: .infinity)

                        Button { router.open(.about) } label: {
                            NowPlayingTitleBlock(title: snapshot.displayTitle, artist: snapshot.displayArtist, tint: tint, trackId: snapshot.trackId)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows Behind the Track")
                        NowPlayingMixLine(trackId: snapshot.trackId, timeline: coordinator.timeline) {
                            router.open(.tracklist)
                        }
                        NowPlayingActions(context: context, snapshot: snapshot, diameter: 44, store: context.waveformStore, cueBoard: context.cueBoard)
                        NowPlayingDock(context: context, snapshot: snapshot)
                        NowPlayingTransport(snapshot: snapshot)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .frame(height: 70)
                        NowPlayingVolumeSlider()
                        NowPlayingPhoneBottomBar(context: context, snapshot: snapshot)
                            .padding(.horizontal, 26)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, safe.top)
                    .padding(.bottom, max(safe.bottom, 12) + 20)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()
    }
}
