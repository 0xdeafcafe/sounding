import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject var playerService: PlayerService
    @EnvironmentObject var navigationState: NavigationState
    @ObservedObject private var artworkColors = ArtworkColors.shared
    @ObservedObject private var dj = DJTransitionService.shared
    @ObservedObject private var waveforms = WaveformService.shared
    @ObservedObject private var setlistStore = SetlistIntelligenceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showingDJ = false
    @State private var showingDJStartConfiguration = false
    @State private var showingComments = false
    @State private var showingDetails = false
    @State private var showingTrackMap = false
    @State private var showingSetlist = false
    @FocusState private var primaryFocused: Bool
    @StateObject private var commentsStore = TrackCommentsStore()
    @StateObject private var engagement = TrackEngagementStore()
    @StateObject private var cueBoard = CueBoard()

    var body: some View {
        let _ = PlayerProbe.countBody("PlayerView")
        #if DEBUG
        let _ = PlayerProbe.isOff(PlayerProbe.Ablation.printChanges) ? Self._printChanges() : ()
        #endif
        if PlayerProbe.isOff(PlayerProbe.Ablation.screen) {
            probeBlankScreen
        } else {
            playerContent
        }
    }

    @ViewBuilder
    private var probeBlankScreen: some View {
        Color.black
            .ignoresSafeArea()
            #if DEBUG
            .onAppear { PlayerFrameMeter.shared.startIfNeeded() }
            #endif
    }

    private var playerContent: some View {
        GeometryReader { proxy in
            let layout = PlayerLayout(available: proxy.size)

            ZStack(alignment: .bottom) {
                heroRow(layout: layout)
                    .padding(.horizontal, Spacing.screen)
                    .padding(.top, SCBrowseMetrics.contentTopInset)
                    .padding(.bottom, Spacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                transportSection(layout: layout)
                    .frame(width: proxy.size.width)
                    .padding(.bottom, Spacing.xl)
                    .focusSection()
                    .ignoresSafeArea(.container, edges: .horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                CinematicBackground(
                    track: playerService.currentTrack,
                    palette: artworkColors.current
                )
            )
            #if DEBUG
            .task(id: debugArtworkOverrideURL) {
                if let debugArtworkOverrideURL {
                    ArtworkColors.shared.update(for: debugArtworkOverrideURL)
                }
            }
            #endif
        }
        .fullScreenCover(isPresented: $showingDJ) {
            DJModeView()
                #if DEBUG
                .onAppear { CrashRecorder.note("DJModeView appeared") }
                #endif
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
                BehindTheTrackView(track: track, palette: artworkColors.current)
            }
        }
        .fullScreenCover(isPresented: $showingTrackMap) {
            TrackMapView(
                track: playerService.currentTrack,
                board: cueBoard,
                currentTime: playerService.currentTime,
                duration: playerService.duration,
                envelope: currentWaveform?.samples ?? [],
                palette: artworkColors.current,
                onSeek: { time in playerService.seek(to: time) }
            )
        }
        .fullScreenCover(isPresented: $showingSetlist) {
            if let track = playerService.currentTrack {
                SetlistEditorView(
                    track: track,
                    currentPosition: playerService.currentTime,
                    comments: commentsStore.comments,
                    localFileURL: playerService.localAudioURL(for: track),
                    onSeek: { time in playerService.seek(to: time) },
                    onDownload: { _ = DownloadManager.shared.download(track) },
                    onPlaySearchResult: { result in
                        Task { await playerService.play(result, in: [result]) }
                    }
                )
            }
        }
        .task(id: playerService.currentTrack?.id) {
            commentsStore.ensureLoaded(for: playerService.currentTrack)
        }
        .task(id: "\(playerService.currentTrack?.id ?? "none")#\(commentsStore.comments.count)") {
            guard let track = playerService.currentTrack else { return }
            setlistStore.seed(track: track, comments: commentsStore.comments)
        }
        .task(id: PulseFeedKey(
            trackId: playerService.currentTrack?.id,
            sampleCount: currentWaveform?.samples.count ?? 0,
            duration: Int(playerService.duration)
        )) {
            cueBoard.ensureLoaded(
                trackId: playerService.currentTrack?.id,
                duration: playerService.duration,
                waveform: currentWaveform
            )
        }
        .task(id: PulseFeedKey(
            trackId: playerService.currentTrack?.id,
            sampleCount: currentWaveform?.samples.count ?? 0,
            duration: Int(playerService.duration)
        )) {
            MusicPulse.shared.ingest(
                trackId: playerService.currentTrack?.id,
                samples: currentWaveform?.samples ?? [],
                duration: playerService.duration
            )
        }
        .onChange(of: playerService.currentTime, initial: true) { _, time in
            MusicPulse.shared.anchor(position: time, isPlaying: playerService.isPlaying)
        }
        .onChange(of: playerService.isPlaying) { _, playing in
            MusicPulse.shared.anchor(position: playerService.currentTime, isPlaying: playing)
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["SOUNDING_TV_DJ_OPEN"] == "1" else { return }
            try? await Task.sleep(for: .seconds(2))
            showingDJ = true
        }
        .task {
            guard ProcessInfo.processInfo.environment["SOUNDING_TV_CUES_OPEN"] == "1" else { return }
            try? await Task.sleep(for: .seconds(2))
            showingTrackMap = true
        }
        .task {
            guard ProcessInfo.processInfo.environment["SOUNDING_TV_COMMENTS_OPEN"] == "1" else { return }
            try? await Task.sleep(for: .seconds(2))
            showingComments = true
        }
        .task {
            guard ProcessInfo.processInfo.environment["SOUNDING_TV_PLAY"] == "1" else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !playerService.isPlaying else { return }
            playerService.togglePlayPause()
        }
        #endif
        .defaultFocus($primaryFocused, true)
        #if DEBUG
        .onAppear { PlayerFrameMeter.shared.startIfNeeded() }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .sessionExpired)) { _ in
            showingDJ = false
        }
    }

    private var currentWaveform: Waveform? {
        guard let track = playerService.currentTrack else { return nil }
        return waveforms.state(for: track.id).waveform
    }

    private var debugArtworkOverrideURL: URL? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SOUNDING_TV_ARTWORK_URL"].flatMap(URL.init(string:))
        #else
        return nil
        #endif
    }

    private func heroRow(layout: PlayerLayout) -> some View {
        HStack(alignment: .top, spacing: Spacing.screen) {
            trackInfoColumn(layout: layout)
                .frame(maxWidth: 1120, maxHeight: layout.artworkSize, alignment: .topLeading)

            if layout.showsUpNext, !upcomingTracks.isEmpty {
                upNextSection
                    .frame(maxWidth: 560, alignment: .topLeading)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: layout.artworkSize, alignment: .topLeading)
    }

    private func trackInfoColumn(layout: PlayerLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(playerService.currentTrack?.title ?? "Not Playing")
                .font(.tvLargeTitle)
                .foregroundStyle(.white)
                .kerning(-1.4)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: 920, alignment: .leading)
                .shadow(color: .black.opacity(0.45), radius: 22, y: 6)

            Text(playerService.currentTrack?.user.displayName ?? "")
                .font(.tvHeadline)
                .foregroundStyle(Color.scTextSecondary)
                .lineLimit(1)
                .padding(.top, Spacing.xs)
                .shadow(color: .black.opacity(0.30), radius: 10, y: 3)

            if let track = playerService.currentTrack {
                secondaryActionsRow(for: track)
                    .padding(.top, Spacing.lg)
                    .focusSection()

                if DeckIdentityResolver.isLikelyMix(track) {
                    OnDecksIndicator(
                        identity: setlistStore.setlist(for: track.id)?.segment(at: playerService.currentTime),
                        isScanning: setlistStore.scanningTrackIds.contains(track.id),
                        action: { showingSetlist = true }
                    )
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .frame(maxWidth: 920, alignment: .leading)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .padding(.top, Spacing.md)
                    .focusSection()
                }
            }

            Spacer(minLength: Spacing.lg)
        }
        .frame(height: layout.artworkSize, alignment: .topLeading)
    }

    @ViewBuilder
    private var upNextSection: some View {
        let upcoming = upcomingTracks
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Eyebrow(text: "Up Next")

            VStack(spacing: Spacing.xs) {
                ForEach(upcoming) { entry in
                    UpNextRow(track: entry.track) {
                        Task { await playerService.playTrackAt(index: entry.id) }
                    }
                }
            }
        }
        .focusSection(when: !upcoming.isEmpty)
    }

    private func secondaryActionsRow(for track: Track) -> some View {
        HStack(spacing: Spacing.sm) {
            LikeActionButton(track: track, engagement: engagement)
            TrackMapButton(board: cueBoard) { showingTrackMap = true }
            DJModeButton(isOn: dj.isEnabled) {
                if dj.isEnabled || SettingsStore.shared.hasStoredValue(SettingKeys.DJStartOptions.self) {
                    playerService.startDJSession(configuration: SettingsStore.shared.djStartConfiguration)
                    showingDJ = true
                } else {
                    showingDJStartConfiguration = true
                }
            }
            CommentsEntryButton(store: commentsStore) { showingComments = true }
            if DeckIdentityResolver.isLikelyMix(track) {
                UtilityActionButton(icon: "list.number", accessibilityLabel: "Detected Set List") {
                    showingSetlist = true
                }
            }
            UtilityActionButton(icon: "info.circle", accessibilityLabel: "Behind This Track") {
                showingDetails = true
            }
        }
    }

    private var upcomingTracks: [QueueEntry] {
        let start = playerService.currentIndex + 1
        guard start < playerService.queue.count else { return [] }
        return playerService.queue[start...].prefix(2).enumerated().map {
            QueueEntry(id: start + $0.offset, track: $0.element)
        }
    }

    private func transportSection(layout: PlayerLayout) -> some View {
        VStack(spacing: Spacing.md) {
            VStack(spacing: Spacing.sm) {
                WaveformScrubber(
                    track: playerService.currentTrack,
                    currentTime: playerService.currentTime,
                    duration: playerService.duration,
                    isPlaying: playerService.isPlaying,
                    laneHeight: layout.waveformHeight,
                    palette: artworkColors.current,
                    comments: commentsStore,
                    cues: cueBoard,
                    setlistSegments: currentSetlistSegments,
                    reduceMotion: reduceMotion,
                    onTogglePlayPause: { playerService.togglePlayPause() },
                    onSeek: { time in playerService.seek(to: time) }
                )

                HStack {
                    Text(formatTime(playerService.currentTime))
                    Spacer()
                    Text("\u{2212}\(formatTime(max(0, playerService.duration - playerService.currentTime)))")
                }
                .font(.tvCalloutEmph)
                .foregroundStyle(Color.scTextSecondary)
                .monospacedDigit()
                .padding(.horizontal, Spacing.screen)
            }

            transportCluster
                .padding(.top, Spacing.xs)
        }
    }

    @ViewBuilder
    private var transportCluster: some View {
        transportControls
        .scMotion(.glassMorph, reduceMotion: reduceMotion, value: dj.isEnabled)
    }

    @ViewBuilder
    private var transportControls: some View {
        transportButtons
    }

    private var transportButtons: some View {
        // Apple Music's transport hierarchy is deliberately asymmetric:
        // shuffle/repeat are quiet edge controls, skip is secondary, and play
        // owns the visual centre. Equal circular buttons make every action
        // compete with Play.
        HStack(spacing: Spacing.md) {
            if dj.isEnabled {
                Label("Live Mix", systemImage: "waveform.badge.magnifyingglass")
                    .font(.tvCaptionEmph)
                    .foregroundStyle(artworkColors.current.accent)
                    .lineLimit(1)

                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 1, height: 48)
            }

            ControlButton(icon: "shuffle", isActive: playerService.isShuffleEnabled) {
                playerService.toggleShuffle()
            }
            ControlButton(icon: "backward.fill", size: .medium) {
                Task { await playerService.playPrevious() }
            }
            ControlButton(
                icon: playerService.isPlaying ? "pause.fill" : "play.fill",
                size: .large,
                isPrimary: true
            ) { playerService.togglePlayPause() }
            .focused($primaryFocused)
            ControlButton(icon: "forward.fill", size: .medium) {
                Task { await playerService.playNext() }
            }
            ControlButton(icon: playerService.repeatMode.icon, isActive: playerService.repeatMode.isActive) {
                playerService.cycleRepeatMode()
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    private var currentSetlistSegments: [SetlistSegment] {
        setlistStore.setlist(for: playerService.currentTrack?.id)?.segments
            .filter { !$0.isDeleted }
            .sorted { $0.startSeconds < $1.startSeconds } ?? []
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, !time.isNaN else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct PlayerLayout {
    let artworkSize: CGFloat
    let waveformHeight: CGFloat
    let showsUpNext: Bool

    init(available: CGSize) {
        waveformHeight = min(max(available.height * 0.09, 88), 112)
        let verticalInset = SCBrowseMetrics.contentTopInset + Spacing.xl
        artworkSize = min(max(460, available.height - verticalInset * 1.5), available.width * 0.36, 640)
        showsUpNext = artworkSize >= 540

        #if DEBUG
        if PlayerProbe.isMetering, !Self.didLogGeometry {
            Self.didLogGeometry = true
            NSLog(
                "[fpsprobe] layout available=%.0fx%.0f inset=%.0f lane=%.0f artwork=%.0f upNext=%@",
                available.width, available.height, verticalInset,
                waveformHeight, artworkSize, showsUpNext ? "yes" : "no"
            )
        }
        #endif
    }

    #if DEBUG
    nonisolated(unsafe) private static var didLogGeometry = false
    #endif
}

private struct PulseFeedKey: Equatable {
    let trackId: String?
    let sampleCount: Int
    let duration: Int
}

private struct QueueEntry: Identifiable {
    let id: Int
    let track: Track
}

private struct CinematicBackground: View {
    let track: Track?
    let palette: ArtworkColors.Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var luminanceFactor: Double {
        min(1, max(0, SCAmbient.relativeLuminance(palette.rawMean) / 0.45))
    }

    private var baseLevel: Double { 0.055 - 0.026 * luminanceFactor }
    private var paletteStrength: Double { 0.68 - 0.22 * luminanceFactor }
    private var adaptiveScrim: Double { 0.05 + 0.24 * luminanceFactor }

    var body: some View {
        ZStack {
            Color(red: baseLevel * 0.92, green: baseLevel, blue: baseLevel * 1.08)

            ArtworkImage(url: track?.artworkURL, variant: .hero) {
                LinearGradient(
                    colors: [
                        palette.primary.opacity(paletteStrength),
                        palette.average.opacity(paletteStrength * 0.52),
                        palette.secondary.opacity(paletteStrength * 0.78)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            RadialGradient(
                colors: [palette.accent.opacity(paletteStrength * 0.44), .clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 1150
            )

            RadialGradient(
                colors: [palette.secondary.opacity(paletteStrength * 0.32), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 1250
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.56 + adaptiveScrim),
                    Color.black.opacity(0.18 + adaptiveScrim * 0.4),
                    Color.black.opacity(0.10)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.24),
                    Color.black.opacity(0.02),
                    Color.black.opacity(0.68)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .scMotion(.easeInOut(duration: 1.2), reduceMotion: reduceMotion, value: palette.primary)
        .scMotion(.easeInOut(duration: 1.2), reduceMotion: reduceMotion, value: palette.secondary)
    }
}

private struct HeroArtwork: View {
    let track: Track?
    let isPlaying: Bool
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        artworkWithShadow
            .scaleEffect(isPlaying ? 1.0 : 0.96)
            .scMotion(.spring(response: 0.6, dampingFraction: 0.78), reduceMotion: reduceMotion, value: isPlaying)
            .phaseAnimator([false, true], trigger: track?.id) { content, hasSettled in
                content
                    .scaleEffect(hasSettled || reduceMotion ? 1.0 : 0.90)
                    .opacity(hasSettled || reduceMotion ? 1.0 : 0.35)
            } animation: { hasSettled in
                guard !reduceMotion else { return nil }
                return hasSettled ? .spring(response: 0.55, dampingFraction: 0.70) : .easeOut(duration: 0.01)
            }
    }

    private static let artworkCorner: CGFloat = Corner.card

    private var artworkBase: some View {
        ArtworkImage(url: track?.artworkURL, variant: .hero) {
            GeneratedArtworkCard(
                identity: track.map { "\($0.title)#\($0.user.username)" } ?? "sounding.tv/no-track",
                mode: .blob,
                style: .tv
            )
        }
        .kyleCrowned(user: track?.user, context: track?.title)
        .clipShape(RoundedRectangle(cornerRadius: Self.artworkCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.artworkCorner, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        )
        .backgroundExtensionEffect()
    }

    @ViewBuilder
    private var artworkWithShadow: some View {
        if PlayerProbe.isOff(PlayerProbe.Ablation.heroShadow) {
            artworkBase
        } else {
            artworkBase
                .shadow(color: .black.opacity(0.55), radius: 60, y: 36)
        }
    }
}

private struct UpNextRow: View {
    let track: Track
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var artworkColors = ArtworkColors.shared

    var body: some View {
        HStack(spacing: Spacing.md) {
            ArtworkImage(url: track.artworkURL)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                .kyleCrowned(user: track.user, context: track.title)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.tvBodyEmph)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.user.displayName)
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                .fill(Color.white.opacity(focused ? 0.14 : 0))
        )
        .scFocus(focused, cornerRadius: Corner.card, reduceMotion: reduceMotion)
        .contentShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
    }
}

private struct DJModeButton: View {
    let isOn: Bool
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var artworkColors = ArtworkColors.shared

    @ViewBuilder
    private var icon: some View {
        Group {
            if isOn && !reduceMotion {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .symbolEffect(.variableColor.iterative)
            } else {
                Image(systemName: "waveform.badge.magnifyingglass")
            }
        }
        .font(.system(size: 28, weight: .heavy))
        .symbolEffect(.bounce, value: reduceMotion ? false : isOn)
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            icon
            Text("Decks")
                .font(.tvBodyEmph)
            if isOn {
                Circle()
                    .fill(Color.scAccent)
                    .frame(width: 10, height: 10)
                    .padding(.leading, 2)
            }
        }
        .foregroundStyle(isOn || focused ? .white : .white.opacity(0.85))
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .liquidGlass(in: Capsule(), tint: isOn ? artworkColors.current.accent.opacity(0.32) : nil)
        .shadow(color: isOn ? artworkColors.current.accent.opacity(0.45) : .clear, radius: isOn ? 18 : 0)
        .scFocus(focused, in: Capsule(), reduceMotion: reduceMotion)
        .contentShape(Capsule())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
    }
}

struct WaveformScrubber: View {
    let track: Track?
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let laneHeight: CGFloat
    let palette: ArtworkColors.Palette
    @ObservedObject var comments: TrackCommentsStore
    @ObservedObject var cues: CueBoard
    let setlistSegments: [SetlistSegment]
    let reduceMotion: Bool
    let onTogglePlayPause: () -> Void
    let onSeek: (TimeInterval) -> Void

    @ObservedObject private var waveforms = WaveformService.shared
    @FocusState private var isFocused: Bool

    @State private var bars: [Float] = []
    @State private var clusters: [CommentCluster] = []
    @State private var scrubPreview: TimeInterval?
    @State private var scrubClearTask: Task<Void, Never>?
    @State private var panAnchor: TimeInterval?
    @State private var isPanning = false
    @State private var suppressMoves = false
    @State private var moveCooldownTask: Task<Void, Never>?

    private let scrubStep: TimeInterval = 10
    private static let barPitch: CGFloat = 5
    private static let barGap: CGFloat = 2

    private var displayedTime: TimeInterval { scrubPreview ?? currentTime }
    private var displayedProgress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displayedTime / duration))
    }

    private var waveformState: WaveformState {
        guard let track else { return .pending }
        return waveforms.state(for: track.id)
    }

    private struct BarsKey: Equatable {
        let trackId: String?
        let widthBucket: Int
        let sampleCount: Int
    }

    private struct ClustersKey: Equatable {
        let trackId: String?
        let widthBucket: Int
        let commentCount: Int
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .topLeading) {
                let laneBars = PlayerProbe.isOff(PlayerProbe.Ablation.waveformLoading) ? [] : bars
                PulseTimeline(
                    isActive: PlayerProbe.reactive(isPlaying, PlayerProbe.Ablation.waveformPulse) && !laneBars.isEmpty,
                    reduceMotion: reduceMotion
                ) { rawPulse in
                    let pulse = PlayerProbe.pulse(rawPulse)
                    let _ = PlayerProbe.countBody("Waveform")
                    SCWaveformRenderer(
                        envelope: laneBars,
                        duration: duration,
                        progress: displayedProgress,
                        mode: .centered(windowSeconds: visibleWindowSeconds),
                        playheadEmphasis: Double(pulse.impact),
                        pulseEnergy: Double(pulse.energy),
                        placeholder: placeholderKind,
                        identity: track?.id,
                        style: paletteLaneStyle
                    )
                    .frame(width: width, height: laneHeight)
                }

                if bars.isEmpty {
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 3, height: laneHeight - 6)
                        .offset(x: width / 2 - 1.5, y: 3)
                        .allowsHitTesting(false)
                }

                cueMarkers(width: width)
                setlistMarkers(width: width)
                markers(width: width)
                bubble(width: width)
                readout(width: width)
            }
            .frame(width: width, height: laneHeight, alignment: .center)
            .clipped()
            .task(id: BarsKey(
                trackId: track?.id,
                widthBucket: Int(width / 4),
                sampleCount: waveformState.waveform?.samples.count ?? 0
            )) {
                recomputeBars(width: width)
            }
            .task(id: ClustersKey(
                trackId: track?.id,
                widthBucket: Int(width / 4),
                commentCount: comments.timedComments.count
            )) {
                recomputeClusters(width: width)
            }
        }
        .frame(height: laneHeight)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .scaleEffect(y: isFocused ? Focus.scale : 1.0, anchor: .center)
        .shadow(
            color: isFocused ? .scFocusShadow : .clear,
            radius: isFocused ? Focus.shadowRadius : 0,
            y: isFocused ? Focus.shadowY : 0
        )
        .overlay(
            RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        )
        .scMotion(Motion.focus, reduceMotion: reduceMotion, value: isFocused)
        .task(id: track?.id) {
            guard let track else { return }
            waveforms.load(track)
        }
        .background(
            RemoteScrubSurface(
                isActive: isFocused && duration > 0,
                onBegan: beginPan,
                onChanged: { scrubPreview = panTime(for: $0) },
                onEnded: endPan,
                onCancelled: cancelPan
            )
            .allowsHitTesting(false)
        )
        .onTapGesture(perform: commitSeek)
        .onMoveCommand { direction in
            guard !suppressMoves else { return }
            switch direction {
            case .left:  scrub(by: -scrubStep)
            case .right: scrub(by: scrubStep)
            case .up:    jumpToCue(forward: true)
            case .down:  jumpToCue(forward: false)
            default: break
            }
        }
        .onPlayPauseCommand(perform: onTogglePlayPause)
        .accessibilityHint("Slide to scrub, lift to seek. Press up or down to jump between marked moments.")
        .onChange(of: track?.id) { _, _ in
            scrubPreview = nil
            scrubClearTask?.cancel()
            panAnchor = nil
            isPanning = false
            bars = []
            clusters = []
        }
    }

    private func panTime(for translation: CGFloat) -> TimeInterval {
        RemoteScrub.time(from: panAnchor ?? currentTime, translation: translation, duration: duration)
    }

    private func beginPan() {
        scrubClearTask?.cancel()
        moveCooldownTask?.cancel()
        panAnchor = scrubPreview ?? currentTime
        isPanning = true
        suppressMoves = true
    }

    private func endPan(_ translation: CGFloat) {
        let target = panTime(for: translation)
        panAnchor = nil
        isPanning = false
        scrubPreview = target
        onSeek(target)

        scrubClearTask?.cancel()
        scrubClearTask = Task {
            try? await Task.sleep(for: RemoteScrub.settleDelay)
            guard !Task.isCancelled else { return }
            scrubPreview = nil
        }
        releaseMoveSuppression()
    }

    private func cancelPan() {
        panAnchor = nil
        isPanning = false
        scrubClearTask?.cancel()
        scrubClearTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            scrubPreview = nil
        }
        releaseMoveSuppression()
    }

    private func releaseMoveSuppression() {
        moveCooldownTask?.cancel()
        moveCooldownTask = Task {
            try? await Task.sleep(for: RemoteScrub.moveCooldown)
            guard !Task.isCancelled else { return }
            suppressMoves = false
        }
    }

    private func commitSeek() {
        guard let target = scrubPreview else { return }
        onSeek(target)
        scrubPreview = nil
        scrubClearTask?.cancel()
    }

    private func jumpToCue(forward: Bool) {
        let positions = cues.sheet.userCues.map(\.positionSeconds)
        let target = forward
            ? CueNavigation.next(after: displayedTime, positions: positions)
            : CueNavigation.previous(before: displayedTime, positions: positions)
        guard let target else { return }

        scrubPreview = target
        scrubClearTask?.cancel()
        scrubClearTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            scrubPreview = nil
        }
    }

    private func scrub(by delta: TimeInterval) {
        let base = scrubPreview ?? currentTime
        scrubPreview = min(max(0, base + delta), max(duration, 0))

        scrubClearTask?.cancel()
        scrubClearTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            scrubPreview = nil
        }
    }

    private func recomputeBars(width: CGFloat) {
        guard let waveform = waveformState.waveform, !waveform.isEmpty, width > 0 else {
            bars = []
            return
        }
        let totalPitch = Self.barPitch + Self.barGap
        let barCount = max(1, Int(width / totalPitch))
        bars = waveform.displayBars(count: barCount)
    }

    private func recomputeClusters(width: CGFloat) {
        clusters = clusterTimedComments(comments.timedComments, duration: duration, width: width)
    }

    private var paletteLaneStyle: SCWaveformStyle {
        var style = Self.laneStyle
        style.playheadHaloColor = palette.accent
        return style
    }

    fileprivate static let laneStyle: SCWaveformStyle = {
        var style = SCWaveformStyle.tv
        style.barPitch = barPitch
        style.barGap = barGap
        style.barCornerRadius = barPitch / 2
        return style
    }()

    private var placeholderKind: SCWaveformPlaceholder {
        if PlayerProbe.isOff(PlayerProbe.Ablation.waveformLoading) { return .loading }
        switch waveformState {
        case .pending, .loading:      return .loading
        case .ready(let waveform):    return waveform.isEmpty ? .unavailable : .loading
        case .failed:                 return .unavailable
        }
    }

    @ViewBuilder
    private func cueMarkers(width: CGFloat) -> some View {
        ForEach(cues.sheet.entries) { entry in
            let x = xPosition(for: entry.positionSeconds, width: width)
            Capsule()
                .fill(entry.color.color.opacity(entry.isSuggestion ? 0.4 : 0.95))
                .frame(width: 3, height: bars.isEmpty ? 28 : 12)
                .offset(
                    x: x - 1.5,
                    y: bars.isEmpty ? laneHeight / 2 - 14 : 3
                )
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func markers(width: CGFloat) -> some View {
        ForEach(clusters) { cluster in
            let x = xPosition(for: cluster.time, width: width)
            Circle()
                .fill(cluster.comments.count > 1 ? palette.accent : Color.white.opacity(0.6))
                .frame(width: bars.isEmpty ? 11 : 8, height: bars.isEmpty ? 11 : 8)
                .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 0.5))
                .offset(
                    x: x - (bars.isEmpty ? 5.5 : 4),
                    y: bars.isEmpty ? laneHeight / 2 + 14 : laneHeight - 9
                )
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func setlistMarkers(width: CGFloat) -> some View {
        ForEach(setlistSegments) { segment in
            let x = xPosition(for: segment.startSeconds, width: width)
            if x >= -12, x <= width + 12 {
                let isCurrent = activeSetlistSegment?.id == segment.id
                ZStack {
                    Capsule()
                        .fill(palette.accent.opacity(isCurrent ? 0.72 : 0.30))
                        .frame(width: 2, height: isCurrent ? 24 : 16)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(isCurrent ? palette.accent : Color.white.opacity(0.55))
                        .frame(width: isCurrent ? 9 : 7, height: isCurrent ? 9 : 7)
                        .rotationEffect(.degrees(45))
                }
                .frame(width: 12, height: 28)
                .offset(x: x - 6, y: laneHeight / 2 - 14)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func readout(width: CGFloat) -> some View {
        if isPanning, let preview = scrubPreview {
            let x = xPosition(for: preview, width: width)
            ScrubReadout(time: preview, delta: preview - currentTime, accent: palette.accent)
                .offset(x: min(max(x - 85, 0), max(0, width - 170)), y: -46)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func bubble(width: CGFloat) -> some View {
        if !isPanning, let active = activeCluster {
            let x = xPosition(for: active.time, width: width)
            let clampedX = min(max(x, 200), max(200, width - 200))

            CommentBubble(cluster: active, palette: palette)
                .offset(x: clampedX - 200, y: -(CommentBubble.height + 8))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                .scMotion(.glassMorph, reduceMotion: reduceMotion, value: active.id)
                .allowsHitTesting(false)
        }
    }

    private var activeCluster: CommentCluster? {
        guard !clusters.isEmpty else { return nil }
        let window: TimeInterval = 2.5
        guard let nearest = clusters.min(by: { abs($0.time - displayedTime) < abs($1.time - displayedTime) }) else {
            return nil
        }
        return abs(nearest.time - displayedTime) <= window ? nearest : nil
    }

    private var activeSetlistSegment: SetlistSegment? {
        setlistSegments.last { $0.startSeconds <= displayedTime + 2 }
    }

    private func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0, width > 0 else { return width / 2 }
        let secondsPerPoint = visibleWindowSeconds / Double(width)
        return width / 2 + CGFloat((time - displayedTime) / secondsPerPoint)
    }

    private var visibleWindowSeconds: TimeInterval {
        guard duration > 0 else { return 60 }
        return min(max(duration * 0.18, 45), 180)
    }
}

// MARK: - Remote touch scrubbing

enum RemoteScrub {
    static let swipeSpan: CGFloat = 900
    static let engageThreshold: CGFloat = 14
    static let shortestSpan: TimeInterval = 45
    static let longestSpan: TimeInterval = 600
    static let moveCooldown: Duration = .milliseconds(450)
    static let settleDelay: Duration = .milliseconds(700)

    static func span(for duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 0 }
        return min(max(duration, shortestSpan), longestSpan)
    }

    static func time(from anchor: TimeInterval, translation: CGFloat, duration: TimeInterval) -> TimeInterval {
        let delta = TimeInterval(translation / swipeSpan) * span(for: duration)
        return min(max(0, anchor + delta), max(duration, 0))
    }

    static func delta(_ seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded())
        guard rounded != 0 else { return "0:00" }
        let sign = rounded < 0 ? "\u{2212}" : "+"
        return sign + DJFormat.time(TimeInterval(abs(rounded)))
    }
}

struct RemoteScrubSurface: UIViewRepresentable {
    var isActive: Bool
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void
    var onCancelled: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onWindowChange = { [coordinator = context.coordinator] window in
            coordinator.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(surface: self)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(surface: self) }

    private final class HostView: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var surface: RemoteScrubSurface
        private weak var attachedWindow: UIWindow?
        private var engaged = false

        private lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        init(surface: RemoteScrubSurface) {
            self.surface = surface
        }

        func update(surface: RemoteScrubSurface) {
            self.surface = surface
            pan.isEnabled = surface.isActive
            if !surface.isActive, engaged {
                engaged = false
                surface.onCancelled()
            }
        }

        func attach(to window: UIWindow?) {
            guard attachedWindow !== window else { return }
            attachedWindow?.removeGestureRecognizer(pan)
            attachedWindow = window
            window?.addGestureRecognizer(pan)
            pan.isEnabled = surface.isActive
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view).x

            switch recognizer.state {
            case .began:
                engaged = false
            case .changed:
                if !engaged {
                    guard abs(translation) >= RemoteScrub.engageThreshold else { return }
                    engaged = true
                    surface.onBegan()
                }
                surface.onChanged(translation)
            case .ended:
                guard engaged else { return }
                engaged = false
                surface.onEnded(translation)
            case .cancelled, .failed:
                guard engaged else { return }
                engaged = false
                surface.onCancelled()
            default:
                break
            }
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

struct ScrubReadout: View {
    let time: TimeInterval
    let delta: TimeInterval
    let accent: Color

    var body: some View {
        HStack(spacing: Space.tight) {
            Text(DJFormat.time(time))
                .foregroundStyle(.white)
            Text(RemoteScrub.delta(delta))
                .foregroundStyle(accent)
        }
        .font(.tvCalloutEmph)
        .monospacedDigit()
        .padding(.horizontal, Space.snug)
        .padding(.vertical, Space.hair)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        .fixedSize()
    }
}

/// A truthful fallback for tracks that do not expose waveform data. It keeps
/// the same seek semantics without inventing an audio envelope.
private struct ClassicProgressScrubber: View {
    let progress: Double
    let accent: Color
    let isFocused: Bool

    private var clampedProgress: CGFloat {
        CGFloat(min(1, max(0, progress)))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let thumb: CGFloat = isFocused ? 30 : 24
            let trackHeight: CGFloat = isFocused ? 12 : 9
            let thumbX = min(max(0, width * clampedProgress - thumb / 2), max(0, width - thumb))

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.16))
                    .frame(height: trackHeight)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.82), Color.white.opacity(0.94)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * clampedProgress, height: trackHeight)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: accent.opacity(isFocused ? 0.42 : 0.20), radius: isFocused ? 14 : 7)
                    .offset(x: thumbX)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .allowsHitTesting(false)
    }
}

enum CommentsLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

@MainActor
final class TrackCommentsStore: ObservableObject {
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var state: CommentsLoadState = .idle

    private var loadedTrackId: String?
    private var task: Task<Void, Never>?

    func ensureLoaded(for track: Track?) {
        guard let track else {
            reset()
            return
        }
        guard track.id != loadedTrackId else { return }
        loadedTrackId = track.id
        #if DEBUG
        if CommentDemo.isEnabled {
            comments = CommentDemo.comments()
            state = .loaded
            return
        }
        #endif
        comments = []
        state = .loading
        task?.cancel()
        task = Task { [weak self] in
            do {
                let page = try await SoundCloudAPI.shared.getComments(trackId: track.id)
                guard !Task.isCancelled, self?.loadedTrackId == track.id else { return }
                self?.comments = page.collection
                self?.state = .loaded
            } catch {
                guard !Task.isCancelled, self?.loadedTrackId == track.id else { return }
                self?.state = .failed
            }
        }
    }

    func retry(for track: Track?) {
        loadedTrackId = nil
        ensureLoaded(for: track)
    }

    private func reset() {
        task?.cancel()
        task = nil
        loadedTrackId = nil
        comments = []
        state = .idle
    }

    var timedComments: [Comment] {
        comments
            .filter { $0.timeInTrack != nil }
            .sorted { ($0.timeInTrack ?? 0) < ($1.timeInTrack ?? 0) }
    }
}

private struct CommentsEntryButton: View {
    @ObservedObject var store: TrackCommentsStore
    let action: () -> Void

    var body: some View {
        UtilityActionButton(
            icon: isFailed ? "exclamationmark.bubble.fill" : "bubble.left.and.bubble.right.fill",
            label: countLabel,
            accessibilityLabel: accessibilityLabel
        ) {
            action()
        }
    }

    private var isFailed: Bool { store.state == .failed }

    private var countLabel: String? {
        guard !isFailed, store.state == .loaded, !store.comments.isEmpty else { return nil }
        return "\(store.comments.count)"
    }

    private var accessibilityLabel: String {
        if isFailed { return "Comments, couldn't load" }
        guard store.state == .loaded else { return "Comments" }
        if store.comments.isEmpty { return "Comments, none yet" }
        return store.comments.count == 1 ? "Comments, 1" : "Comments, \(store.comments.count)"
    }
}

private struct CommentCluster: Identifiable, Equatable {
    let time: TimeInterval
    let comments: [Comment]
    var id: String { "\(Int(time * 10))#\(comments.count)#\(comments.first?.id ?? "")" }
    var representative: Comment? { comments.first }
}

private func clusterTimedComments(
    _ sortedByTime: [Comment], duration: TimeInterval, width: CGFloat, minSpacing: CGFloat = 26
) -> [CommentCluster] {
    guard duration > 0, width > 0, !sortedByTime.isEmpty else { return [] }
    let minSpacingSeconds = TimeInterval(minSpacing / width) * duration

    var clusters: [CommentCluster] = []
    for comment in sortedByTime {
        guard let time = comment.timeInTrack else { continue }
        if let last = clusters.last, time - last.time <= minSpacingSeconds {
            clusters[clusters.count - 1] = CommentCluster(time: last.time, comments: last.comments + [comment])
        } else {
            clusters.append(CommentCluster(time: time, comments: [comment]))
        }
    }
    return clusters
}

private struct CommentBubble: View {
    let cluster: CommentCluster
    let palette: ArtworkColors.Palette

    static let height: CGFloat = 78

    var body: some View {
        if let comment = cluster.representative {
            GlassEffectContainer(spacing: 6) {
                VStack(spacing: 6) {
                    bubbleContent(comment)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xs)
                        .frame(width: 400, height: 56, alignment: .leading)
                        .liquidGlass(
                            in: RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous),
                            tint: palette.accent.opacity(0.18)
                        )

                    Rectangle()
                        .fill(.white.opacity(0.4))
                        .frame(width: 2, height: 16)
                        .liquidGlass(in: Rectangle())
                }
            }
        }
    }

    private func bubbleContent(_ comment: Comment) -> some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            ArtworkImage(url: comment.user.avatarURL, icon: "person.fill")
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .kyleCrowned(user: comment.user, context: comment.user.displayName)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(comment.user.displayName)
                        .font(.tvCaptionEmph)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if cluster.comments.count > 1 {
                        Text("+\(cluster.comments.count - 1) more")
                            .font(.tvCaptionEmph)
                            .foregroundStyle(palette.accent)
                    }
                }
                Text(comment.body)
                    .font(.tvCallout)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(1)
            }
        }
    }
}

struct ControlButton: View {
    let icon: String
    var size: ButtonSize = .small
    var isActive: Bool = false
    var isPrimary: Bool = false
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var artworkColors = ArtworkColors.shared
    @State private var didActivate = false

    enum ButtonSize {
        case small, medium, large

        var iconSize: Font {
            switch self {
            case .small:  return .system(size: 24, weight: .semibold)
            case .medium: return .system(size: 30, weight: .bold)
            case .large:  return .system(size: 36, weight: .heavy)
            }
        }

        var frame: CGFloat {
            switch self {
            case .small:  return 52
            case .medium: return 64
            case .large:  return 76
            }
        }
    }

    var body: some View {
        Image(systemName: icon)
            .font(size.iconSize)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .symbolEffect(.bounce, value: reduceMotion ? false : didActivate)
            .foregroundStyle(foreground)
            .frame(width: size.frame, height: size.frame)
            .background(background)
            .scFocus(focused, in: Circle(), reduceMotion: reduceMotion)
            .contentShape(Circle())
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onTapGesture {
                didActivate.toggle()
                action()
            }
    }

    private var foreground: Color {
        if isPrimary { return .black }
        if isActive  { return Color.scAccent }
        return focused ? .white : .white.opacity(0.78)
    }

    @ViewBuilder
    private var background: some View {
        if isPrimary {
            Circle().fill(Color.white)
        } else if focused {
            Circle().fill(Color.white.opacity(0.18))
        } else {
            Color.clear
        }
    }

}

enum PlayerProbe {
    enum Ablation {
        static let heroShadow = "heroShadow"
        static let backdropArtwork = "bgArtwork"
        static let backdropMesh = "bgMesh"
        static let waveformPulse = "wavePulse"
        static let transportGlass = "glass"
        static let screen = "screen"
        static let printChanges = "changes"
        static let waveformLoading = "waveLoading"
    }

    #if DEBUG
    static let isMetering = ProcessInfo.processInfo.environment["SOUNDING_TV_FPSPROBE"] == "1"

    private static let ablated: Set<String> = Set(
        (ProcessInfo.processInfo.environment["SOUNDING_TV_ABLATE"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    )
    #else
    static let isMetering = false
    private static let ablated: Set<String> = []
    #endif

    static func isOff(_ key: String) -> Bool {
        !ablated.isEmpty && ablated.contains(key)
    }

    static func reactive(_ isPlaying: Bool, _ key: String) -> Bool {
        (isPlaying || isMetering) && !isOff(key)
    }

    static func pulse(_ pulse: Pulse) -> Pulse {
        guard isMetering else { return pulse }
        let t = CACurrentMediaTime()
        return Pulse(
            position: pulse.position,
            energy: Float(0.5 + 0.45 * sin(t * 0.8)),
            impact: Float(0.5 + 0.45 * sin(t * 3.1)),
            beatPhase: nil
        )
    }

    @MainActor
    static func countBody(_ name: String) {
        #if DEBUG
        guard isMetering else { return }
        PlayerFrameMeter.shared.note(name)
        #endif
    }
}

#if DEBUG
@MainActor
final class PlayerFrameMeter: NSObject {
    static let shared = PlayerFrameMeter()

    private var link: CADisplayLink?
    private var previousTimestamp: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var bodyCounts: [String: Int] = [:]
    private var windowStart: CFTimeInterval = 0
    private var nominal: Double = 1.0 / 60.0
    private var windowIndex = 0
    private let windowSeconds: Double = 5

    private var label: String {
        let ablate = ProcessInfo.processInfo.environment["SOUNDING_TV_ABLATE"] ?? "none"
        return ablate.isEmpty ? "none" : ablate
    }

    func startIfNeeded() {
        guard PlayerProbe.isMetering, link == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(step(_:)))
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
        previousTimestamp = 0
        windowStart = CACurrentMediaTime()
        NSLog("[fpsprobe] start ablate=%@", label)
    }

    func note(_ name: String) {
        bodyCounts[name, default: 0] += 1
    }

    @objc private func step(_ displayLink: CADisplayLink) {
        let now = displayLink.timestamp
        let period = displayLink.targetTimestamp - displayLink.timestamp
        if period > 0.002, period < 0.2 { nominal = period }
        defer { previousTimestamp = now }
        guard previousTimestamp > 0 else { return }
        intervals.append(now - previousTimestamp)
        if now - windowStart >= windowSeconds { flush(at: now) }
    }

    private func flush(at now: CFTimeInterval) {
        let elapsed = now - windowStart
        defer {
            intervals.removeAll(keepingCapacity: true)
            bodyCounts.removeAll(keepingCapacity: true)
            windowStart = now
            windowIndex += 1
        }
        guard intervals.count > 4 else { return }

        let sorted = intervals.sorted()
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        let worst = sorted[sorted.count - 1]
        let late = intervals.filter { $0 > nominal * 1.5 }.count
        let veryLate = intervals.filter { $0 > nominal * 2.5 }.count

        let bodies = bodyCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(format: "%.1f", Double($0.value) / elapsed))/s" }
            .joined(separator: " ")

        NSLog(
            "[fpsprobe] w%d ablate=%@ frames=%d fps=%.1f mean=%.1fms p50=%.1fms p95=%.1fms max=%.1fms late=%d(%.0f%%) verylate=%d nominal=%.1fms %@",
            windowIndex, label, intervals.count, Double(intervals.count) / elapsed,
            mean * 1000, p50 * 1000, p95 * 1000, worst * 1000,
            late, 100 * Double(late) / Double(intervals.count), veryLate,
            nominal * 1000, bodies
        )
    }
}
#endif
