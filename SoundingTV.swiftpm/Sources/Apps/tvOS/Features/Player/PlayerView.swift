import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject var playerService: PlayerService
    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var navigationState: NavigationState
    @ObservedObject private var artworkColors = ArtworkColors.shared
    @ObservedObject private var waveforms = WaveformService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var panel: NPPanelKind?
    @State private var isVisible = false
    @State private var lastMainFocus: NPFocus = .play
    @State private var collectionTitle: String?
    @State private var showingDJ = false
    @State private var showingDJStartConfiguration = false
    @State private var showingComments = false
    @State private var showingDetails = false
    @State private var showingTrackMap = false
    @State private var showingSetlist = false
    @State private var showingLyrics = false
    @State private var setlistLocalFileURL: URL?
    @State private var safeTop: CGFloat = 0
    @State private var pinnedTop: CGFloat = 0
    @State private var mainDisabled = false
    @FocusState private var focus: NPFocus?
    @StateObject private var commentsStore = TrackCommentsStore()
    @StateObject private var engagement = TrackEngagementStore()
    @StateObject private var trackMap = TrackMapModel()
    @StateObject private var idle = NPIdleMonitor()
    @ObservedObject private var setlists = SetlistIntelligenceStore.shared

    static let tabBarFloor: CGFloat = 112

    private var contentTop: CGFloat {
        max(pinnedTop, Self.tabBarFloor) - safeTop + SCBrowseMetrics.contentTopInset
    }

    var body: some View {
        withCovers(withLifecycle(rootStack))
            .task(id: playerService.currentTrack?.id) {
                commentsStore.ensureLoaded(for: playerService.currentTrack)
            }
            .onChange(of: playerService.currentTrack?.supportsSoundCloudActions) { _, supports in
                if supports == false, panel == .comments { panel = .upNext }
            }
            .task(id: NPCollectionTitle.Key(source: playerService.queueSource, collectionId: playerService.activeCollectionId)) {
                collectionTitle = await NPCollectionTitle.resolve(playerService.queueSource, collectionId: playerService.activeCollectionId)
            }
            .task(id: showingSetlist ? playerService.currentTrack?.id : nil) {
                guard showingSetlist, let track = playerService.currentTrack else {
                    setlistLocalFileURL = nil
                    return
                }
                setlistLocalFileURL = await playerService.preparedLocalAudioURL(for: track)
            }
            .task(id: "\(playerService.currentTrack?.id ?? "none")#\(commentsStore.comments.count)") {
                guard let track = playerService.currentTrack else { return }
                SetlistIntelligenceStore.shared.seed(track: track, comments: commentsStore.comments)
            }
            .task(id: CueFeedKey(
                trackId: playerService.currentTrack?.id,
                sampleCount: currentWaveform?.samples.count ?? 0,
                duration: Int(playerService.currentTrack?.duration ?? 0)
            )) {
                let player = playerService
                trackMap.livePosition = { player.currentTime }
                trackMap.onSeek = { player.seek(to: $0, expectedTrackID: player.currentTrack?.id) }
                trackMap.load(
                    trackId: playerService.currentTrack?.id,
                    title: playerService.currentTrack?.title ?? "",
                    duration: playerService.currentTrack?.duration ?? 0,
                    envelope: currentWaveform?.samples ?? []
                )
            }
            #if DEBUG
            .task { await debugOpenHooks() }
            #endif
    }

    private var rootStack: some View {
        ZStack {
            if showingLyrics {
                NPLyricsScreen(
                    track: playerService.currentTrack,
                    nextTrack: playerService.upcomingTrack,
                    clock: playerService.clock,
                    isPlaying: playerService.isPlaying,
                    accent: artistTint,
                    topInset: contentTop,
                    onSeek: { [trackID = playerService.currentTrack?.id] time in
                        playerService.seek(to: time, expectedTrackID: trackID)
                    }
                )
                .transition(.opacity)
            } else {
                mainContent
                    .disabled(panel != nil || mainDisabled)
                    .transition(.opacity)
            }
            if idle.isIdle, let track = playerService.currentTrack {
                ambientOverlay(track)
            }
            if panel != nil {
                panelScrim
                    .transition(.opacity)
            }
            if let panel {
                panelView(panel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, Space.page)
                    .padding(.top, contentTop)
                    .padding(.bottom, Space.section)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: [.horizontal, .bottom])
        .background { backdrop.ignoresSafeArea() }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { top in
            safeTop = top
            if top > pinnedTop { pinnedTop = top }
        }
        .toolbarVisibility(idle.isIdle ? .hidden : .visible, for: .tabBar)
        .environment(\.colorScheme, .dark)
    }

    private var panelScrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0.25),
                .init(color: .black.opacity(0.5), location: 0.55),
                .init(color: .black.opacity(0.62), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func withLifecycle<V: View>(_ view: V) -> some View {
        view
        .animation(reduceMotion ? nil : Motion.settle, value: panel == nil)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: showingLyrics)
        .onExitCommand(perform: exitAction)
        .defaultFocus($focus, .play)
        .onAppear {
            isVisible = true
            route(.nowPlayingAppeared)
            applyDebugLaunchState()
        }
        .onDisappear {
            isVisible = false
            NowPlayingIdleHold.isActive = false
        }
        .onChange(of: isVisible && scenePhase == .active && !isCoverPresented, initial: true) { _, owns in
            NowPlayingIdleHold.isActive = owns
        }
        .onChange(of: idleEligible, initial: true) { _, eligible in
            idle.setEligible(eligible)
        }
        .onChange(of: idle.isIdle) { _, isIdle in
            idleDidChange(isIdle)
        }
    }

    private var exitAction: (() -> Void)? {
        if showingLyrics {
            return {
                showingLyrics = false
                DispatchQueue.main.async { focus = .lyrics }
            }
        }
        if panel != nil { return { exitPanel() } }
        if navigationState.tabBeforeNowPlaying != nil { return { navigationState.leaveNowPlaying() } }
        return nil
    }

    private func idleDidChange(_ isIdle: Bool) {
        if isIdle {
            if let current = focus { lastMainFocus = current }
            focus = NPFocus.idle
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if idle.isIdle { mainDisabled = true }
            }
        } else {
            mainDisabled = false
            focus = lastMainFocus
        }
    }

    private func withCovers<V: View>(_ view: V) -> some View {
        view
        .fullScreenCover(isPresented: $showingDJ) {
            DJModeView()
        }
        .sheet(isPresented: $showingDJStartConfiguration) {
            AutoDJStartConfigurationView { configuration in
                playerService.startDJSession(configuration: configuration)
                showingDJ = true
            }
        }
        .fullScreenCover(isPresented: $showingComments) {
            CommentsListView(
                track: playerService.currentTrack,
                store: commentsStore,
                palette: artworkColors.current,
                onSeek: { time in
                    playerService.seek(to: time)
                    showingComments = false
                }
            )
        }
        .fullScreenCover(isPresented: $showingDetails) {
            if let track = playerService.currentTrack {
                BehindTheTrackView(track: track, palette: artworkColors.current) {
                    showingDetails = false
                    open(.tracklist, from: .details)
                }
                .tvTrackActionsHost()
            }
        }
        .fullScreenCover(isPresented: $showingTrackMap) {
            TrackMapView(model: trackMap, palette: artworkColors.current)
        }
        .fullScreenCover(isPresented: $showingSetlist) {
            if let track = playerService.currentTrack {
                SetlistEditorView(
                    track: track,
                    currentPosition: playerService.currentTime,
                    comments: commentsStore.comments,
                    localFileURL: setlistLocalFileURL,
                    onSeek: { time in playerService.seek(to: time) },
                    onDownload: { DownloadManager.shared.download(track: track, confirmed: true) },
                    onPlaySearchResult: { result in
                        Task { await playerService.play(result, in: [result]) }
                    }
                )
            }
        }
        .onChange(of: authService.sessionHealth) { _, health in
            if health.needsSignIn { showingDJ = false }
        }
    }

    private struct CueFeedKey: Equatable {
        let trackId: String?
        let sampleCount: Int
        let duration: Int
    }

    private var currentWaveform: Waveform? {
        guard let track = playerService.currentTrack else { return nil }
        return waveforms.state(for: track.id).waveform
    }

    private var isCoverPresented: Bool {
        showingDJ || showingDJStartConfiguration || showingComments || showingDetails || showingTrackMap || showingSetlist
    }

    private var motionActive: Bool {
        isVisible && scenePhase == .active && !reduceMotion && !isCoverPresented
    }

    private var idleEligible: Bool {
        isVisible && scenePhase == .active && playerService.isPlaying && panel == nil && !showingLyrics && !isCoverPresented && focus != nil
    }


    private var backdrop: some View {
        let palette = artworkColors.current
        return ZStack {
            NPBackdrop(artworkURL: playerService.currentTrack?.artworkURL, palette: palette, isAnimating: motionActive)
            if let track = playerService.currentTrack, track.artworkURL == nil {
                SoundingLineArt(seed: GeneratedArtworkIdentity.seed(track.id), style: .ambient, loop: .once, isActive: isVisible && scenePhase == .active)
                    .environment(\.colorScheme, .dark)
                    .id(track.id)
            }
            NPLegibilityScrim(palette: palette)
            NPLineArtLayer(
                clock: playerService.clock,
                track: playerService.currentTrack,
                isPlaying: playerService.isPlaying,
                samples: currentWaveform?.samples ?? [],
                tint: palette.accent,
                isActive: isVisible && scenePhase == .active && !isCoverPresented
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var artistTint: Color {
        artworkColors.current.accent.mix(with: .white, by: 0.55)
    }

    private var mainContent: some View {
        let isDimmed = panel != nil
        let isAmbient = idle.isIdle
        return ZStack {
            artwork
                .scaleEffect(isAmbient && !reduceMotion ? 1.06 : 0.96)
                .opacity(isAmbient ? 1 : 0)
                .animation(reduceMotion ? .easeInOut(duration: 0.6) : .timingCurve(0.3, 0.7, 0.2, 1, duration: 1.4), value: isAmbient)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, contentTop + Self.ambientArtworkGrowth)
            deck
                .opacity(isAmbient ? 0 : 1)
                .animation(.easeInOut(duration: reduceMotion ? 0.6 : 1), value: isAmbient)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(x: isDimmed ? -80 : 0)
        .scaleEffect(isDimmed ? 0.97 : 1)
        .opacity(isDimmed ? 0.32 : 1)
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : Motion.settle, value: isDimmed)
    }

    static let ambientArtworkSide: CGFloat = 600
    static let ambientArtworkGrowth: CGFloat = ambientArtworkSide * 0.03

    private var artwork: some View {
        ZStack {
            ArtworkImage(url: playerService.currentTrack?.largeArtworkURL ?? playerService.currentTrack?.artworkURL, variant: .hero, identity: playerService.currentTrack?.id)
                .aspectRatio(1, contentMode: .fill)
                .id(playerService.currentTrack?.id)
                .transition(.opacity)
        }
        .frame(width: Self.ambientArtworkSide, height: Self.ambientArtworkSide)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 30)
        .scaleEffect(playerService.isPlaying ? 1 : 0.88)
        .animation(reduceMotion ? nil : Motion.settle, value: playerService.isPlaying)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: playerService.currentTrack?.id)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var deck: some View {
        let upNext = upNextEntries
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 90) {
                header
                    .frame(maxWidth: 1000, alignment: .topLeading)
                if !upNext.isEmpty {
                    upNextColumn(upNext)
                        .frame(width: 560, alignment: .topLeading)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 24)
            tape
        }
        .padding(.horizontal, Space.page)
        .padding(.top, contentTop)
        .padding(.bottom, Space.section)
    }

    private var tape: some View {
        VStack(spacing: 30) {
            NPProgressArea(
                isIdle: idle.isIdle,
                accent: artworkColors.current.accent,
                focus: $focus,
                incoming: incomingTrack(for:),
                onMixNow: { playerService.startMix() },
                onExtend: { playerService.extendMix() }
            ) {
                NPWaveform(
                    track: playerService.currentTrack,
                    clock: playerService.clock,
                    comments: commentsStore,
                    isPlaying: playerService.isPlaying,
                    isActive: !idle.isIdle,
                    accent: artworkColors.current.accent,
                    entries: setlists.tracklist(for: playerService.currentTrack?.id)?.entries ?? [],
                    showsBubble: panel == nil,
                    reduceMotion: reduceMotion,
                    focus: $focus,
                    onTogglePlayPause: { playerService.togglePlayPause() },
                    onSeek: { [trackID = playerService.currentTrack?.id] time in
                        playerService.seek(to: time, expectedTrackID: trackID)
                    }
                )
            }
            transport
        }
        .frame(maxWidth: .infinity)
        .focusSection()
    }

    private func incomingTrack(for state: AutoMixLiveState) -> Track? {
        let upcoming = playerService.upcomingTrack
        guard let id = state.incomingTrackId else { return upcoming }
        if upcoming?.id == id { return upcoming }
        return playerService.queue.first { $0.id == id }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let caption = StationLibrary.shared.caption(for: playerService.queueSource) ?? collectionTitle.map({ "From \($0)" }) {
                Text(caption)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(1)
                    .padding(.bottom, Spacing.sm)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(playerService.currentTrack?.title ?? "Not Playing")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                    .accessibilityAddTraits(.isHeader)
                Text(playerService.currentTrack?.artistLine(omittingAlbum: collectionTitle) ?? "")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(artistTint)
                    .lineLimit(1)
            }
            metadataActions
                .padding(.top, 28)
                .padding(.bottom, 38)
            VStack(alignment: .leading, spacing: 10) {
                if let track = playerService.currentTrack, !idle.isIdle {
                    NPEntryLine(track: track, clock: playerService.clock)
                }
                SoundCloudPreviewNowPlayingLine()
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.66))
                NPSleepTimerLine()
                NPListenTogetherLine()
                if let message = playerService.playbackErrorMessage, !playerService.isPlaying {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .accessibilityIdentifier("nowplaying.playbackError")
                }
            }
        }
    }

    private var metadataActions: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 18) {
                if let track = playerService.currentTrack, track.supportsSoundCloudActions {
                    NPLikeButton(track: track, engagement: engagement, focus: $focus)
                }
                secondaryButtons
                NPIconButton(
                    symbol: "ellipsis", label: "More", id: .more, focus: $focus,
                    iconSize: 30, isOn: panel == .more || panel == .cues || panel == .sleepTimer,
                    identifier: "nowplaying.action.more"
                ) { open(.more, from: .more) }
            }
        }
        .focusSection()
    }

    private var transport: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 18) {
                NPIconButton(
                    symbol: "backward.fill", label: "Previous", id: .prev, focus: $focus,
                    iconSize: 30, accessibilityTitle: "Previous track"
                ) { Task { await playerService.playPrevious() } }
                NPIconButton(
                    symbol: playerService.isPlaying ? "pause.fill" : "play.fill",
                    label: playerService.isPlaying ? "Pause" : "Play", id: .play, focus: $focus,
                    diameter: 100, iconSize: 44, swapsSymbol: true
                ) { playerService.togglePlayPause() }
                NPIconButton(
                    symbol: "forward.fill", label: "Next", id: .next, focus: $focus,
                    iconSize: 30, accessibilityTitle: "Next track"
                ) { Task { await playerService.playNext() } }
            }
        }
        .frame(height: 112, alignment: .center)
        .focusSection()
    }

    @ViewBuilder
    private var secondaryButtons: some View {
        let track = playerService.currentTrack
        if !(track.map { setlists.isMix($0) } ?? false) {
            NPIconButton(
                symbol: "quote.bubble", label: "Lyrics", id: .lyrics, focus: $focus,
                iconSize: 30, isOn: showingLyrics, identifier: "nowplaying.action.lyrics"
            ) {
                lastMainFocus = .lyrics
                showingLyrics = true
            }
        }
        if track != nil {
            NPIconButton(
                symbol: "info.circle", label: "Behind the Track", id: .details, focus: $focus,
                iconSize: 30, isOn: showingDetails, identifier: "nowplaying.action.behindTheTrack"
            ) {
                lastMainFocus = .details
                present { showingDetails = true }
            }
        }
        if NPButtonSlots.showsTracklist(for: track, store: setlists) {
            NPIconButton(
                symbol: "music.note.list", label: "Tracklist", id: .tracklist, focus: $focus,
                iconSize: 30, isOn: panel == .tracklist, identifier: "nowplaying.action.tracklist"
            ) { open(.tracklist, from: .tracklist) }
        } else if track?.supportsSoundCloudActions == true {
            NPCommentsButton(store: commentsStore, isOn: panel == .comments, focus: $focus) { open(.comments, from: .comments) }
        }
        NPIconButton(
            symbol: "airplayaudio", label: "Output", id: .output, focus: $focus,
            iconSize: 30, isOn: panel == .output, identifier: "nowplaying.action.output"
        ) { open(.output, from: .output) }
        NPIconButton(
            symbol: "list.bullet", label: "Up Next", id: .upNext, focus: $focus,
            iconSize: 30, isOn: panel == .upNext, identifier: "nowplaying.action.upNext"
        ) { open(.upNext, from: .upNext) }
    }

    private var upNextEntries: [NPUpNextEntry] {
        let start = playerService.currentIndex + 1
        guard start < playerService.queue.count else { return [] }
        return playerService.queue[start...].prefix(2).enumerated().map {
            NPUpNextEntry(index: start + $0.offset, track: $0.element)
        }
    }

    private func upNextColumn(_ entries: [NPUpNextEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up Next")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.66))
                .padding(.leading, 18)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(entries) { entry in
                NPUpNextColumnRow(track: entry.track, rowID: "next\(entry.index)", focus: $focus) {
                    Task { await playerService.playTrackAt(index: entry.index) }
                }
            }
        }
        .focusSection()
    }

    private func ambientOverlay(_ track: Track) -> some View {
        NPAmbientOverlay(
            title: track.title,
            artist: track.user.displayName,
            artistTint: artistTint,
            artworkTop: contentTop + Self.ambientArtworkGrowth,
            titleTop: contentTop + Self.ambientArtworkGrowth * 2 + Self.ambientArtworkSide + Space.section
        )
            .contentShape(Rectangle())
            .focusable()
            .focused($focus, equals: .idle)
            .focusEffectDisabled()
            .onTapGesture { idle.wake() }
            .onMoveCommand { _ in idle.wake() }
            .onExitCommand { idle.wake() }
            .onPlayPauseCommand { playerService.togglePlayPause() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Now Playing, \(track.title) by \(track.user.displayName)")
            .accessibilityHint("Press any button to return")
            .accessibilityIdentifier("nowplaying.ambient")
            .transition(.opacity)
    }

    private func panelView(_ kind: NPPanelKind) -> some View {
        NPPanel(
            kind: kind,
            accent: artworkColors.current.accent,
            collectionTitle: collectionTitle,
            comments: commentsStore,
            trackMap: trackMap,
            focus: $focus,
            actions: panelActions
        )
    }

    private var panelActions: NPPanelActions {
        NPPanelActions(
            select: { panel = $0 },
            close: closePanel,
            seek: { time in
                playerService.seek(to: time, expectedTrackID: playerService.currentTrack?.id)
            },
            openAllComments: { present { showingComments = true } },
            openSetlistEditor: { present { showingSetlist = true } },
            openTrackMap: { present { showingTrackMap = true } },
            openDecks: { present { route(.choseDecks) } },
            openDetails: { present { showingDetails = true } }
        )
    }

    private func open(_ kind: NPPanelKind, from origin: NPFocus) {
        if panel == nil { lastMainFocus = origin }
        panel = kind
    }

    private func closePanel() {
        panel = nil
        let restore = lastMainFocus
        DispatchQueue.main.async { focus = restore }
    }

    private func exitPanel() {
        if panel == .cues || panel == .sleepTimer {
            panel = .more
        } else {
            closePanel()
        }
    }

    private func present(_ action: () -> Void) {
        closePanel()
        action()
    }

    private func route(_ event: TVDecksEntry.Event) {
        let entry = TVDecksEntry.entry(
            for: event,
            sessionIsActive: playerService.isDJSessionEnabled,
            hasStartOptions: SettingsStore.shared.hasStoredValue(SettingKeys.DJStartOptions.self)
        )
        switch entry {
        case .stayOnNowPlaying:
            break
        case .openDecks:
            playerService.startDJSession(configuration: SettingsStore.shared.djStartConfiguration)
            showingDJ = true
        case .configureFirst:
            showingDJStartConfiguration = true
        }
    }


    private func applyDebugLaunchState() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let raw = env["SOUNDING_TV_NP_FOCUS"] {
            let map: [String: NPFocus] = [
                "prev": .prev, "play": .play, "next": .next, "like": .like, "comments": .comments,
                "upnext": .upNext, "details": .details, "tracklist": .tracklist, "output": .output, "more": .more, "wave": .wave,
            ]
            if let target = map[raw.lowercased()] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { focus = target }
            }
        }
        if env["SOUNDING_TV_NP_LYRICS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showingLyrics = true }
        }
        if let raw = env["SOUNDING_TV_NP_PANEL"], let kind = NPPanelKind(rawValue: raw) {
            let delay = env["SOUNDING_TV_NP_PANEL_DELAY"].flatMap(Double.init) ?? 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { open(kind, from: .more) }
        }
        #endif
    }

    #if DEBUG
    private func debugOpenHooks() async {
        let env = ProcessInfo.processInfo.environment
        if env["SOUNDING_TV_DJ_OPEN"] == "1" {
            try? await Task.sleep(for: .seconds(2))
            showingDJ = true
        }
        if env["SOUNDING_TV_CUES_OPEN"] == "1" {
            try? await Task.sleep(for: .seconds(2))
            showingTrackMap = true
        }
        if env["SOUNDING_TV_COMMENTS_OPEN"] == "1" {
            try? await Task.sleep(for: .seconds(2))
            showingComments = true
        }
        if let raw = env["SOUNDING_TV_NP_SEEK"], let seconds = Double(raw) {
            for _ in 0..<40 where !playerService.isPlaying { try? await Task.sleep(for: .milliseconds(500)) }
            try? await Task.sleep(for: .seconds(1))
            playerService.seek(to: seconds)
        }
        if env["SOUNDING_TV_NP_NEXT"] == "1" {
            for _ in 0..<40 where !playerService.isPlaying { try? await Task.sleep(for: .milliseconds(500)) }
            try? await Task.sleep(for: .seconds(1))
            await playerService.playNext()
        }
        if env["SOUNDING_TV_NP_PAUSE"] == "1" {
            for _ in 0..<40 where !playerService.isPlaying { try? await Task.sleep(for: .milliseconds(500)) }
            try? await Task.sleep(for: .seconds(1))
            playerService.togglePlayPause()
        }
        if env["SOUNDING_TV_PLAY"] == "1" {
            try? await Task.sleep(for: .seconds(3))
            guard !playerService.isPlaying else { return }
            playerService.togglePlayPause()
        }
    }
    #endif
}

enum NPCollectionTitle {
    @MainActor private static var cache: [String: String] = [:]

    struct Key: Equatable {
        let source: PlaybackQueueSource?
        let collectionId: String?
    }

    @MainActor
    static func resolve(_ source: PlaybackQueueSource?, collectionId id: String?) async -> String? {
        #if DEBUG
        if let title = ProcessInfo.processInfo.environment["SOUNDING_TV_NP_COLLECTION"] { return title }
        #endif
        if let source { return source.title }
        guard let id else { return nil }
        if id == CollectionPolicyID.likedTracks { return PlaybackQueueSource.likes.title }
        if let cached = cache[id] { return cached }
        guard let playlist = try? await SoundCloudAPI.shared.getPlaylist(id: id) else { return nil }
        cache[id] = playlist.title
        PlaybackQueueSourceDirectory.note(playlist)
        return playlist.title
    }
}

private struct NPEntryLine: View {
    let track: Track
    let clock: PlaybackClock
    @ObservedObject private var store = SetlistIntelligenceStore.shared

    var body: some View {
        if let list = store.tracklist(for: track.id), !list.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let entry = list.currentEntry(at: clock.currentTime) {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.callout.weight(.medium))
                        Text(entry.segment.displayLabel)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.white.opacity(0.66))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("On now, \(entry.segment.displayLabel)")
                }
            }
        }
    }
}

private struct NPUpNextEntry: Identifiable {
    let index: Int
    let track: Track
    var id: Int { index }
}

private struct NPUpNextColumnRow: View {
    let track: Track
    let rowID: String
    var focus: FocusState<NPFocus?>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                ArtworkImage(url: track.artworkURL, identity: track.id)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.thumb, style: .continuous))
                    .kyleCrowned(user: track.user, context: track.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.body.weight(.semibold))
                        .npInk(.primary)
                        .lineLimit(1)
                    Text(track.user.displayName)
                        .font(.caption)
                        .npInk(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 110)
        }
        .buttonStyle(NPRowStyle())
        .focused(focus, equals: .row(rowID))
        .accessibilityLabel("\(track.title), \(track.user.displayName)")
        .accessibilityHint("Plays this track now")
        .accessibilityIdentifier("nowplaying.upnext.column.\(track.id)")
    }
}

private struct NPLikeButton: View {
    let track: Track
    @ObservedObject var engagement: TrackEngagementStore
    var focus: FocusState<NPFocus?>.Binding

    var body: some View {
        let liked = engagement.isLiked(track)
        NPIconButton(
            symbol: liked ? "heart.fill" : "heart",
            label: liked ? "Liked" : "Like",
            id: .like, focus: focus, isOn: liked,
            accessibilityTitle: liked ? "Unlike" : "Like",
            identifier: "nowplaying.action.like"
        ) {
            Task { await engagement.toggleLike(track) }
        }
        .task(id: track.id) {
            await engagement.refreshLikeState(track)
        }
        .onReceive(LikesSyncEngine.shared.$revision.dropFirst()) { _ in
            Task { await engagement.refreshLikeState(track) }
        }
    }
}

private struct NPCommentsButton: View {
    @ObservedObject var store: TrackCommentsStore
    let isOn: Bool
    var focus: FocusState<NPFocus?>.Binding
    let action: () -> Void

    var body: some View {
        NPIconButton(
            symbol: store.state == .failed ? "exclamationmark.bubble" : "bubble.left",
            label: "Comments", id: .comments, focus: focus, isOn: isOn,
            accessibilityTitle: accessibilityTitle,
            identifier: "nowplaying.action.comments",
            action: action
        )
    }

    private var accessibilityTitle: String {
        if store.state == .failed { return "Comments, couldn't load" }
        guard store.state == .loaded else { return "Comments" }
        if store.comments.isEmpty { return "Comments, none yet" }
        return store.comments.count == 1 ? "Comments, 1" : "Comments, \(store.comments.count)"
    }
}

private struct NPLineArtLayer: View {
    @ObservedObject var clock: PlaybackClock
    let track: Track?
    let isPlaying: Bool
    let samples: [Float]
    let tint: Color
    let isActive: Bool

    var body: some View {
        let duration = clock.duration > 0 ? clock.duration : (track?.duration ?? 0)
        SoundingReactiveLineArt(
            trackID: track?.id,
            samples: samples,
            duration: duration,
            playhead: SoundingLineArtPlayhead(
                position: clock.currentTime,
                date: clock.updatedAt,
                rate: isPlaying ? 1 : 0,
                duration: duration
            ),
            scrub: nil,
            tint: tint,
            intensity: 0.26,
            bandPosition: 0.07,
            wideTipAnchor: UnitPoint(x: 0.42, y: 0.95),
            isActive: isActive
        )
    }
}
