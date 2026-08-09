import SwiftUI
import AppKit
import AVKit

enum MacNowPlayingPane: String, CaseIterable, Identifiable {
    case queue
    case comments
    case tracklist
    case about
    var id: String { rawValue }
}

enum MacCommentsLoadState: Equatable {
    case loading
    case loaded([Comment])
    case failed
}

@MainActor
final class MacNowPlayingPresentation: ObservableObject {
    static let shared = MacNowPlayingPresentation()
    @Published var pane: MacNowPlayingPane = .queue
    @Published private(set) var presentationRequest = 0
    private init() {}

    func present(_ pane: MacNowPlayingPane = .queue) {
        self.pane = pane
        presentationRequest &+= 1
    }

    func consumePresentationRequest() {
        presentationRequest = 0
    }
}

/// The lightweight comments companion shown beside library content. Transport
/// actions use this instead of replacing the current page with the full player.
struct MacTimedCommentsSidebar: View {
    @ObservedObject private var player = PlayerService.shared

    @State private var load: MacCommentsLoadState = .loading
    @State private var palette: ArtworkPalette = .fallback
    @State private var ambientArtwork: Image?

    var body: some View {
        ZStack {
            AmbientArtworkBackdrop(seed: ambientArtworkSeed, intensity: 0.55)
                .overlay(Color.black.opacity(0.24))
                .ignoresSafeArea()

            TimedCommentsPane(
                load: load,
                currentTime: player.currentTime,
                focusedCommentID: nil,
                accent: palette.accent,
                onSeek: player.seek
            )
            .padding(18)
        }
        .task(id: player.currentTrack?.artworkURL) {
            guard let url = player.currentTrack?.artworkURL else {
                palette = .fallback
                ambientArtwork = nil
                return
            }
            async let paletteResult = ArtworkCache.shared.palette(for: url)
            async let artworkResult = ArtworkCache.shared.heroImage(for: url)
            palette = await paletteResult
            ambientArtwork = await artworkResult
        }
        .task(id: player.currentTrack?.id) {
            load = .loading
            guard let track = player.currentTrack else {
                load = .loaded([])
                return
            }
            do {
                let page = try await SoundCloudAPI.shared.getComments(trackId: track.id)
                if !Task.isCancelled { load = .loaded(page.collection) }
            } catch {
                if !Task.isCancelled { load = .failed }
            }
        }
    }

    private var ambientArtworkSeed: AmbientArtworkSeed {
        AmbientArtworkSeed(
            artwork: ambientArtwork,
            colors: palette.gradientStops,
            accent: palette.accent,
            scrim: max(0.48, palette.localScrimOpacity)
        )
    }
}

struct MacNowPlayingView: View {
    var initialPane: MacNowPlayingPane = .queue
    var isEmbedded: Bool = false
    var onClose: (() -> Void)?
    var onDetach: () -> Void = {}

    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var engagement = MacTrackEngagement.shared
    @ObservedObject private var waveforms = WaveformService.shared
    @ObservedObject private var setlistStore = SetlistIntelligenceStore.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pane: MacNowPlayingPane
    @State private var palette: ArtworkPalette = .fallback
    @State private var ambientArtwork: Image?
    @State private var isDragging = false
    @State private var dragFraction: Double?
    @State private var dragStartFraction: Double?
    @State private var commentsLoad: MacCommentsLoadState = .loading
    @State private var commentThreads: [CommentThread] = []
    @State private var commentClusters: [SCCommentCluster] = []
    @State private var hoveredCluster: SCCommentCluster?
    @State private var focusedCommentID: String?
    @State private var waveformGracePeriodEnded = false
    @State private var showingSetlist = false
    @AppStorage("mac.nowPlaying.largeArtwork") private var isLargeArtwork = false

    private static let narrowWidthThreshold: CGFloat = 900

    private static let railMetrics: SCCommentRailMetrics = {
        var style = SCContentStyle.mac
        style.rowArtworkSize = 48
        return SCCommentRailMetrics.derived(from: style)
    }()

    init(
        initialPane: MacNowPlayingPane = .queue,
        isEmbedded: Bool = false,
        onClose: (() -> Void)? = nil,
        onDetach: @escaping () -> Void = {}
    ) {
        self.initialPane = initialPane
        self.isEmbedded = isEmbedded
        self.onClose = onClose
        self.onDetach = onDetach
        _pane = State(initialValue: initialPane)
    }

    private var track: Track? { player.currentTrack }

    var body: some View {
        ZStack {
            ambientBackground

            MacNowPlayingDismissMonitor(
                activeWidthFraction: isLargeArtwork ? 1 : 0.58,
                onDismiss: close
            )

            if let track {
                layout(track)
            } else {
                emptyState
            }

            // This remains above every pane, including the artwork-only mode.
            // A plainly visible target is much more reliable than asking people
            // to discover the tiny window chrome or a precise gesture.
            closeButton
        }
        // The presentation covers the complete detail surface.  Give the
        // otherwise-empty artwork/background area an explicit interaction
        // shape so it never leaks clicks through to a table below it.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { })
        // This is a takeover inside the existing main window, not a separate
        // compact player. Publishing a smaller ideal size here let AppKit
        // shrink the main window when Now Playing was presented.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 620)
        .onExitCommand(perform: close)
        .task(id: track?.id) {
            guard let track,
                  let url = track.artworkURL
                    ?? track.user.largeAvatarURL
                    ?? track.user.avatarURL else {
                palette = .fallback
                ambientArtwork = nil
                return
            }
            async let paletteResult = ArtworkCache.shared.palette(for: url)
            async let artworkResult = ArtworkCache.shared.heroImage(for: url)
            palette = await paletteResult
            ambientArtwork = await artworkResult
        }
        .task(id: track?.id) {
            engagement.refreshLikedStateIfStale()
            hoveredCluster = nil
            focusedCommentID = nil
            commentClusters = []
            commentThreads = []
            commentsLoad = .loading
            guard let track else { return }
            setlistStore.seed(track: track, comments: [])
            do {
                let page = try await SoundCloudAPI.shared.getComments(trackId: track.id)
                commentsLoad = .loaded(page.collection)
                commentThreads = CommentThreadBuilder.build(page.collection).timed
                setlistStore.seed(track: track, comments: page.collection)
            } catch {
                if !Task.isCancelled { commentsLoad = .failed }
            }
        }
        .task(id: track?.id) {
            waveformGracePeriodEnded = false
            guard let track else { return }
            waveforms.load(track)
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { waveformGracePeriodEnded = true }
        }
        .onReceive(MacNowPlayingPresentation.shared.$pane) { pane = $0 }
        .sheet(isPresented: $showingSetlist) {
            if let track {
                SetlistEditorView(
                    track: track,
                    currentPosition: player.currentTime,
                    comments: loadedComments,
                    localFileURL: player.localAudioURL(for: track),
                    onSeek: { player.seek(to: $0) },
                    onDownload: { _ = DownloadManager.shared.download(track) },
                    onPlaySearchResult: { result in
                        Task { await player.play(result, in: [result]) }
                    }
                )
                .frame(minWidth: 680, minHeight: 620)
            }
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismissWindow()
            dismiss()
        }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.92))
                .background(.black.opacity(0.30), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .help("Close Now Playing (Esc)")
                .accessibilityLabel("Close Now Playing")
            }
            Spacer()
        }
        .padding(18)
        .zIndex(10)
    }

    private var ambientBackground: some View {
        ZStack {
            Color.black

            if let ambientArtwork {
                ambientArtwork
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                AmbientArtworkBackdrop(seed: ambientArtworkSeed)
            }

            LinearGradient(
                colors: [.black.opacity(0.16), .black.opacity(0.22), .black.opacity(0.74)],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [.clear, .black.opacity(0.62)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
            .animation(SCContentMotion.ambient, value: palette)
            .ignoresSafeArea()
    }

    private var ambientArtworkSeed: AmbientArtworkSeed {
        AmbientArtworkSeed(
            artwork: ambientArtwork,
            colors: palette.gradientStops,
            accent: palette.accent,
            scrim: palette.localScrimOpacity
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("Nothing Playing")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func layout(_ track: Track) -> some View {
        GeometryReader { proxy in
            Group {
                if isLargeArtwork {
                    largeArtworkLayout(track, size: proxy.size)
                } else if proxy.size.width < Self.narrowWidthThreshold {
                    verticalLayout(track, size: proxy.size)
                } else {
                    twoColumnLayout(track, size: proxy.size)
                }
            }
            .animation(SCContentMotion.focus, value: isLargeArtwork)
        }
    }

    private func twoColumnLayout(_ track: Track, size: CGSize) -> some View {
        HStack(alignment: .top, spacing: 0) {
            leftColumn(track)
                .frame(width: size.width * 0.58, height: size.height)
            rightPanel(track)
                .frame(width: size.width * 0.42, height: size.height)
        }
    }

    private func verticalLayout(_ track: Track, size: CGSize) -> some View {
        return VStack(spacing: 0) {
            VStack(spacing: 16) {
                titleArtistRow(track)
                Spacer(minLength: 80)
                scrubber
                transportRow
                nextUpHint
            }
            .frame(width: min(size.width - 32, 520))
            .padding(.top, 24)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)

            rightPanel(track)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
    }

    private func largeArtworkLayout(_ track: Track, size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            ArtworkThumbnail(
                url: track.artworkURL,
                identity: track.title,
                size: max(size.width, size.height),
                cornerRadius: 0,
                crownUser: track.user,
                crownContext: track.title
            )
            .frame(width: size.width, height: size.height)
            .clipped()
            .backgroundExtensionEffect()

            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: size.height * 0.4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            VStack(spacing: 14) {
                titleArtistRow(track)
                scrubber
                transportRow
                nextUpHint
            }
            .frame(width: min(size.width * 0.62, 560))
            .padding(.bottom, 48)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func leftColumn(_ track: Track) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                titleArtistRow(track)

                if DeckIdentityResolver.isLikelyMix(track) {
                    OnDecksIndicator(
                        identity: setlistStore.setlist(for: track.id)?.segment(at: player.currentTime),
                        isScanning: setlistStore.scanningTrackIds.contains(track.id),
                        action: { pane = .tracklist }
                    )
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 9))
                    .padding(.top, 10)
                }

                Spacer(minLength: 80)

                VStack(spacing: 14) {
                    scrubber
                    transportRow
                    nextUpHint
                }
                .padding(18)
                .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func rightPanel(_ track: Track) -> some View {
        paneColumn(track)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerPanel, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerPanel, style: .continuous)
                            .fill(Color.black.opacity(0.38))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerPanel, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .padding(.top, 16)
            .padding(.trailing, 16)
            .padding(.bottom, 16)
    }

    private func artwork(_ track: Track, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerPanel, style: .continuous)
                .fill(Color.white.opacity(0.06))
            if let url = track.artworkURL {
                ArtworkThumbnail(
                    url: url,
                    identity: player.currentTrack?.title ?? "",
                    size: size,
                    cornerRadius: SCContentStyle.mac.cornerPanel,
                    crownUser: player.currentTrack?.user,
                    crownContext: player.currentTrack?.title
                )
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerPanel, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        .animation(SCContentMotion.settle, value: player.isPlaying)
    }

    private func titleArtistRow(_ track: Track) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(track.user.displayName)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                favoriteButton(track)
                Menu {
                    Button("Show Up Next") { pane = .queue }
                    Button("Show Timed Comments") { pane = .comments }
                    if DeckIdentityResolver.isLikelyMix(track) {
                        Button("Show Setlist") { pane = .tracklist }
                    }
                    Button("About This Track") { pane = .about }
                    if player.queue.count > player.currentIndex + 1 {
                        Button("Clear Up Next", role: .destructive) { player.clearQueue() }
                    }
                    Divider()
                    Button(isLargeArtwork ? "Hide Large Artwork" : "Show Large Artwork") {
                        isLargeArtwork.toggle()
                    }
                    .keyboardShortcut("a", modifiers: [.option, .command])
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerControl, style: .continuous)
                .fill(.black.opacity(0.42))
        )
    }

    private func favoriteButton(_ track: Track) -> some View {
        let liked = engagement.isLiked(track)
        return Button {
            Task { await engagement.toggleLike(track) }
        } label: {
            if engagement.isPending(track) {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 16))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(liked ? palette.accent : .white.opacity(0.8))
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .accessibilityLabel(liked ? "Unlike" : "Like")
    }

    private var loadedComments: [Comment] {
        guard case .loaded(let comments) = commentsLoad else { return [] }
        return comments
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let duration = max(player.duration, 0.001)
                let fraction = dragFraction ?? (player.currentTime / duration)
                let clamped = max(0, min(1, fraction))
                ZStack(alignment: .bottom) {
                    SCWaveformRenderer(
                        envelope: waveformEnvelope,
                        duration: duration,
                        progress: clamped,
                        mode: .centered(windowSeconds: macWaveformWindowSeconds),
                        placeholder: waveformPlaceholder,
                        identity: track?.id,
                        motionSuppressed: reduceMotion || waveformGracePeriodEnded,
                        style: waveformStyle
                    )

                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: geo.size.height / 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)

                    commentRail
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragStartFraction = clamped
                            }
                            let base = dragStartFraction ?? clamped
                            let delta = -Double(value.translation.width / max(1, geo.size.width))
                                * macWaveformWindowSeconds / duration
                            dragFraction = max(0, min(1, base + delta))
                        }
                        .onEnded { _ in
                            let f = dragFraction ?? clamped
                            player.seek(to: f * duration)
                            isDragging = false
                            dragFraction = nil
                            dragStartFraction = nil
                        }
                )
            }
            .frame(height: 72)

            HStack {
                Text(macFormatTime(displayedTime))
                Spacer()
                Text(macFormatRemaining(
                    current: displayedTime,
                    duration: player.duration
                ))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))

        }
    }

    private var displayedTime: TimeInterval {
        dragFraction.map { $0 * player.duration } ?? player.currentTime
    }

    private var macWaveformWindowSeconds: TimeInterval {
        let duration = max(player.duration, 0.001)
        return min(duration, max(120, duration * 0.20))
    }

    private var waveformState: WaveformState {
        guard let track else { return .pending }
        return waveforms.state(for: track.id)
    }

    private var waveformEnvelope: [Float] {
        guard case .ready(let waveform) = waveformState else { return [] }
        return SCWaveformSampler.visuallyNormalized(waveform.samples, floor: 0.12)
    }

    private var waveformPlaceholder: SCWaveformPlaceholder {
        switch waveformState {
        case .pending, .loading:   return waveformGracePeriodEnded ? .unavailable : .loading
        case .ready(let waveform): return waveform.isEmpty ? .unavailable : .loading
        case .failed:              return .unavailable
        }
    }

    private var waveformStyle: SCWaveformStyle {
        var style = SCWaveformStyle.derived(from: onArtworkStyle, dense: false)
        style.barPitch = 3.5
        style.barGap = 2
        style.barCornerRadius = 1.5
        style.restFraction = 0.96
        style.verticalInset = 2
        style.minBarHalfHeight = 2
        style.playheadWidth = 2
        style.glowBlurRadius = 10
        return style
    }

    private var onArtworkStyle: SCContentStyle {
        Self.onArtworkContentStyle(accent: palette.accent)
    }

    static func onArtworkContentStyle(accent: Color) -> SCContentStyle {
        var style = SCContentStyle.mac
        style.textPrimary = .white
        style.textSecondary = .white.opacity(0.66)
        style.textTertiary = .white.opacity(0.42)
        style.separator = .white.opacity(0.22)
        style.accent = accent
        return style
    }

    private var playbackCluster: SCCommentCluster? {
        SCCommentTimeline.active(in: commentClusters, at: displayedTime)
    }

    private struct RailKey: Equatable {
        let trackId: String?
        let threadCount: Int
        let durationBucket: Int
        let widthBucket: Int
    }

    @ViewBuilder
    private var commentRail: some View {
        if !commentThreads.isEmpty {
            GeometryReader { geo in
                Group {
                    if commentClusters.count <= Self.maximumVisibleCommentClusters {
                        SCCommentRail(
                            clusters: commentClusters,
                            duration: player.duration,
                            playhead: displayedTime,
                            activeClusterID: (hoveredCluster ?? playbackCluster)?.id,
                            style: onArtworkStyle,
                            reduceMotion: reduceMotion,
                            onSelect: { cluster in
                                player.seek(to: cluster.time)
                                focusedCommentID = cluster.id
                                pane = .comments
                            },
                            onHoverCluster: { hoveredCluster = $0 }
                        )
                    }
                }
                .task(id: RailKey(
                    trackId: track?.id,
                    threadCount: commentThreads.count,
                    durationBucket: Int(player.duration),
                    widthBucket: Int(geo.size.width / 4)
                )) {
                    hoveredCluster = nil
                    commentClusters = SCCommentTimeline.clusters(
                        from: commentThreads,
                        duration: player.duration,
                        width: geo.size.width,
                        metrics: Self.railMetrics
                    )
                }
            }
            .frame(height: Self.railMetrics.railHeight)
            .clipped()
        }
    }

    private static let maximumVisibleCommentClusters = 12

    private var transportRow: some View {
        HStack(spacing: 30) {
            transportIcon("shuffle", size: 18, backgroundOpacity: 0.10, active: player.isShuffleEnabled) {
                player.toggleShuffle()
            }
            transportIcon("backward.fill", size: 20, backgroundOpacity: 0.10) {
                Task { await player.playPrevious() }
            }
            transportIcon(player.isPlaying ? "pause.fill" : "play.fill", size: 30, backgroundOpacity: 0.14) {
                player.togglePlayPause()
            }
            transportIcon("forward.fill", size: 20, backgroundOpacity: 0.10) {
                Task { await player.playNext() }
            }
            transportIcon(player.repeatMode.icon, size: 18, backgroundOpacity: 0.10, active: player.repeatMode.isActive) {
                player.repeatMode = nextRepeatMode
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var nextUpHint: some View {
        if let nextTrack {
            Button { pane = .queue } label: {
                HStack(spacing: 6) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Next")
                        .fontWeight(.semibold)
                    Text(nextTrack.title)
                        .lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.48))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show Up Next")
        }
    }

    private var nextTrack: Track? {
        let index = player.currentIndex + 1
        guard player.queue.indices.contains(index) else { return nil }
        return player.queue[index]
    }

    private var nextRepeatMode: RepeatMode {
        switch player.repeatMode {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    private func transportIcon(_ systemImage: String, size: CGFloat, backgroundOpacity: CGFloat = 0.10, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? palette.accent : .white.opacity(0.9))
        .background(.white.opacity(backgroundOpacity), in: Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .contentShape(Circle())
    }

    private func paneColumn(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                paneToggle
                outputRoutePicker
            }
            .padding(.bottom, 16)

            Group {
                switch pane {
                case .queue:
                    MacQueueSidebar(appearance: .onArtwork(accent: palette.accent))
                case .comments:
                    TimedCommentsPane(
                        load: commentsLoad,
                        currentTime: player.currentTime,
                        focusedCommentID: focusedCommentID,
                        accent: palette.accent,
                        onSeek: { player.seek(to: $0) }
                    )
                case .tracklist:
                    MacTracklistPane(
                        isLikelyMix: DeckIdentityResolver.isLikelyMix(track),
                        setlist: setlistStore.setlist(for: track.id),
                        isScanning: setlistStore.scanningTrackIds.contains(track.id),
                        scanError: setlistStore.scanErrors[track.id],
                        currentTime: player.currentTime,
                        accent: palette.accent,
                        onSeek: { player.seek(to: $0) },
                        onEdit: { showingSetlist = true }
                    )
                case .about:
                    MacAboutTrackPane(track: track, accent: palette.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
    }

    private var outputRoutePicker: some View {
        MacNowPlayingRoutePickerView()
            .frame(width: 20, height: 20)
            .padding(8)
            .glassEffect(.regular, in: Circle())
            .help("Choose Audio Output")
    }

    private var paneToggle: some View {
        HStack(spacing: 3) {
            paneToggleButton(for: .queue)
            paneToggleButton(for: .comments)
            paneToggleButton(for: .tracklist)
            paneToggleButton(for: .about)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerPanel, style: .continuous)
                .fill(.white.opacity(0.07))
        )
    }

    private func paneToggleButton(for paneCase: MacNowPlayingPane) -> some View {
        let configuration: (title: String, systemImage: String) = {
            switch paneCase {
            case .queue: return ("Up Next", "list.bullet")
            case .comments: return ("Comments", "quote.bubble")
            case .tracklist: return ("Setlist", "list.number")
            case .about: return ("About", "info.circle")
            }
        }()
        return paneToggleButton(
            title: configuration.title,
            systemImage: configuration.systemImage,
            isActive: pane == paneCase,
            isEnabled: true
        ) {
            pane = paneCase
        }
        .frame(maxWidth: .infinity)
    }

    private func paneToggleButton(
        title: String,
        systemImage: String,
        isActive: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
                .background(Capsule().fill(isActive ? Color.white.opacity(0.15) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.white : .white.opacity(isEnabled ? 0.62 : 0.22))
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

private struct MacNowPlayingRoutePickerView: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

/// Watches precise trackpad scrolling without becoming a hit-test surface, so
/// Queue/Comments/Tracklist retain normal scrolling. A deliberate two-finger
/// pull down over the ambient/artwork side dismisses the takeover.
private struct MacNowPlayingDismissMonitor: NSViewRepresentable {
    let activeWidthFraction: CGFloat
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(activeWidthFraction: activeWidthFraction, onDismiss: onDismiss)
    }

    func makeNSView(context: Context) -> PassiveView {
        let view = PassiveView()
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ nsView: PassiveView, context: Context) {
        context.coordinator.activeWidthFraction = activeWidthFraction
        context.coordinator.onDismiss = onDismiss
    }

    static func dismantleNSView(_ nsView: PassiveView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class PassiveView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        var activeWidthFraction: CGFloat
        var onDismiss: () -> Void
        private weak var view: NSView?
        private var monitor: Any?
        private var downwardDistance: CGFloat = 0
        private var didDismiss = false

        init(activeWidthFraction: CGFloat, onDismiss: @escaping () -> Void) {
            self.activeWidthFraction = activeWidthFraction
            self.onDismiss = onDismiss
        }

        func install(for view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard event.hasPreciseScrollingDeltas,
                  let view,
                  event.window === view.window,
                  view.window?.isKeyWindow == true else { return }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point),
                  point.x <= view.bounds.width * activeWidthFraction else { return }

            if event.phase == .began || event.phase == .mayBegin {
                downwardDistance = 0
                didDismiss = false
            }

            let physicalDelta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
            if physicalDelta < 0 {
                downwardDistance += abs(physicalDelta)
            } else {
                downwardDistance = max(0, downwardDistance - abs(physicalDelta) * 1.5)
            }

            if downwardDistance >= 56, !didDismiss {
                didDismiss = true
                onDismiss()
            }

            if event.phase == .ended || event.phase == .cancelled {
                downwardDistance = 0
                didDismiss = false
            }
        }
    }
}

private struct MacAboutTrackPane: View {
    let track: Track
    let accent: Color

    @State private var descriptionExpanded = false

    private var model: SCBehindTrackModel { SCBehindTrackModel(track: track) }
    private var style: SCContentStyle { MacNowPlayingView.onArtworkContentStyle(accent: accent) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: style.spaceBase) {
                SCEyebrow("Behind This Track", style: style)

                header

                if let description = model.description, !description.isEmpty {
                    descriptionCard(description)
                }

                SCStatsStrip(model: model, style: style)

                SCChipRow(model: model, style: style)

                HStack(spacing: style.spaceTight) {
                    Image(systemName: "clock")
                        .font(style.fontCaption)
                    Text(model.relativeUploadDate)
                        .font(style.fontCaption)
                }
                .foregroundStyle(style.textTertiary)

                Link(destination: track.permalinkURL) {
                    HStack(spacing: style.spaceTight) {
                        Image(systemName: "safari")
                        Text("Open on SoundCloud")
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(style.fontCaptionEmphasis)
                    .foregroundStyle(style.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, style.spaceSnug)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: style.spaceSnug) {
            ArtworkThumbnail(
                url: track.artworkURL,
                identity: track.title,
                size: 72,
                cornerRadius: style.cornerControl,
                crownUser: track.user,
                crownContext: track.title
            )
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: style.spaceHair) {
                Link(destination: track.permalinkURL) {
                    Text(track.title)
                        .font(style.fontHeadline)
                        .foregroundStyle(style.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                Link(track.user.displayName, destination: track.user.permalinkURL)
                    .font(style.fontSubheadline)
                    .foregroundStyle(style.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func descriptionCard(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: style.spaceHair) {
            Text(description)
                .font(style.fontBody)
                .foregroundStyle(style.textSecondary)
                .lineLimit(descriptionExpanded ? nil : 4)
                .textSelection(.enabled)

            if !descriptionExpanded {
                Button("More") { descriptionExpanded = true }
                    .buttonStyle(.plain)
                    .font(style.fontCaptionEmphasis)
                    .foregroundStyle(style.textPrimary)
            }
        }
        .padding(style.spaceSnug)
        .background(
            style.bgRaised,
            in: RoundedRectangle(cornerRadius: style.cornerCard, style: .continuous)
        )
    }
}

private struct MacTracklistPane: View {
    let isLikelyMix: Bool
    let setlist: GeneratedSetlist?
    let isScanning: Bool
    let scanError: String?
    let currentTime: TimeInterval
    let accent: Color
    let onSeek: (TimeInterval) -> Void
    let onEdit: () -> Void

    private var style: SCContentStyle {
        MacNowPlayingView.onArtworkContentStyle(accent: accent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Setlist")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(style.textPrimary)
                Spacer()
                if isLikelyMix && !isScanning {
                    Button("Edit Setlist", action: onEdit)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }

            statusOrList
        }
    }

    private var activeSegments: [SetlistSegment] {
        (setlist?.segments ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.startSeconds < $1.startSeconds }
    }

    private var currentSegmentId: String? {
        setlist?.segment(at: currentTime)?.id
    }

    @ViewBuilder
    private var statusOrList: some View {
        if activeSegments.isEmpty {
            if !isLikelyMix {
                tracklistEmptyState(
                    icon: "music.note",
                    title: "This is a single track",
                    message: "Track detection only runs on DJ mixes and long-form sets."
                )
            } else if isScanning {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular).tint(.white)
                    Text("Listening for track changes…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(style.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let scanError {
                tracklistEmptyState(
                    icon: "waveform.badge.magnifyingglass",
                    title: "Track recognition paused",
                    message: friendlyScanError(scanError)
                )
            } else {
                tracklistEmptyState(
                    icon: "list.number",
                    title: "No tracks identified yet",
                    message: "Open the editor to add tracks or search for them yourself."
                )
            }
        } else {
            if isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Still scanning…")
                        .font(.system(size: 11))
                        .foregroundStyle(style.textTertiary)
                }
            }
            segmentList
        }
    }

    private func tracklistEmptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(style.textTertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style.textPrimary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(style.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            if isLikelyMix {
                Button("Open Setlist Editor", action: onEdit)
                    .buttonStyle(.bordered)
                    .tint(accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func friendlyScanError(_ error: String) -> String {
        let normalized = error.lowercased()
        if normalized.contains("shazamcore") || normalized.contains("error 102") {
            return "Shazam couldn't identify this mix. Retry from the editor, or add the tracks yourself."
        }
        return "Track recognition didn't finish. Retry from the editor, or add the tracks yourself."
    }

    private var segmentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(activeSegments) { segment in
                    segmentRow(segment)
                }
            }
            .padding(style.spaceHair)
        }
    }

    private func segmentRow(_ segment: SetlistSegment) -> some View {
        let isCurrent = segment.id == currentSegmentId
        return Button {
            onSeek(segment.startSeconds)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(macFormatTime(segment.startSeconds))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(style.textTertiary)
                    .frame(width: 46, alignment: .leading)
                Text(segment.displayLabel)
                    .font(.system(size: 12, weight: isCurrent ? .bold : .regular))
                    .foregroundStyle(isCurrent ? style.textPrimary : style.textSecondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? accent.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

func macFormatTime(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    guard hours > 0 else { return String(format: "%d:%02d", minutes, secs) }
    return String(format: "%d:%02d:%02d", hours, minutes, secs)
}

func macFormatRemaining(current: TimeInterval, duration: TimeInterval) -> String {
    "-" + macFormatTime(max(0, duration - current))
}

@MainActor
final class MacTrackEngagement: ObservableObject {
    static let shared = MacTrackEngagement()

    @Published private(set) var likedOverrides: [String: Bool] = [:]
    @Published private(set) var pendingTrackIds: Set<String> = []

    @Published private(set) var knownLikedIds: Set<String> = []

    private var likesFetchTask: Task<Void, Never>?
    private var lastLikesFetch: Date?
    private let likesRefreshInterval: TimeInterval = 5 * 60
    private let likesPageLimit = 200

    private init() {}

    func isLiked(_ track: Track) -> Bool {
        likedOverrides[track.id] ?? knownLikedIds.contains(track.id)
    }

    func isPending(_ track: Track) -> Bool {
        pendingTrackIds.contains(track.id)
    }

    func refreshLikedStateIfStale() {
        if let lastLikesFetch, Date().timeIntervalSince(lastLikesFetch) < likesRefreshInterval { return }
        guard likesFetchTask == nil else { return }
        likesFetchTask = Task { @MainActor [weak self] in
            defer { self?.likesFetchTask = nil }
            guard let page = try? await SoundCloudAPI.shared.getLikedTracks(limit: self?.likesPageLimit ?? 200) else { return }
            guard let self else { return }
            self.lastLikesFetch = Date()
            self.knownLikedIds.formUnion(page.collection.map(\.item.id))
        }
    }

    func toggleLike(_ track: Track) async {
        guard !pendingTrackIds.contains(track.id) else { return }
        let next = !isLiked(track)
        likedOverrides[track.id] = next
        pendingTrackIds.insert(track.id)
        defer { pendingTrackIds.remove(track.id) }

        do {
            if next {
                try await SoundCloudAPI.shared.likeTrack(track)
            } else {
                try await SoundCloudAPI.shared.unlikeTrack(track)
            }
            if next {
                knownLikedIds.insert(track.id)
            } else {
                knownLikedIds.remove(track.id)
            }
        } catch {
            likedOverrides[track.id] = !next
        }
    }
}

private struct TimedCommentsPane: View {
    let load: MacCommentsLoadState
    let currentTime: TimeInterval
    let focusedCommentID: String?
    let accent: Color
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Timed Comments")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)

            switch load {
            case .loading:
                ProgressView().controlSize(.small).tint(.white)
            case .failed:
                Text("Couldn't load comments.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            case .loaded(let comments):
                if comments.isEmpty {
                    Text("No comments yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    commentsList(comments)
                }
            }
        }
    }

    private var rowStyle: SCContentStyle {
        MacNowPlayingView.onArtworkContentStyle(accent: accent)
    }

    private func commentsList(_ comments: [Comment]) -> some View {
        let threadSet = CommentThreadBuilder.build(comments)
        let currentRootId = threadSet.timed.last { ($0.timeInTrack ?? 0) <= currentTime }?.id
        let highlightedID = focusedCommentID ?? currentRootId

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: rowStyle.spaceSnug) {
                    ForEach(threadSet.timed) { thread in
                        threadRows(thread, highlightedID: highlightedID)
                    }
                    if !threadSet.untimed.isEmpty {
                        Divider().overlay(Color.white.opacity(0.15)).padding(.vertical, SCContentStyle.mac.spaceHair)
                        Text("General")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                        ForEach(threadSet.untimed) { thread in
                            threadRows(thread, highlightedID: highlightedID)
                        }
                    }
                }
            }
            .onChange(of: currentRootId) { _, newValue in
                guard focusedCommentID == nil else { return }
                guard let newValue else { return }
                withAnimation(SCContentMotion.settle) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .task(id: focusedCommentID) {
                guard let focusedCommentID else { return }
                await Task.yield()
                withAnimation(SCContentMotion.settle) {
                    proxy.scrollTo(focusedCommentID, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func threadRows(_ thread: CommentThread, highlightedID: String?) -> some View {
        VStack(alignment: .leading, spacing: rowStyle.spaceHair) {
            commentRow(thread.root, isReply: false, isCurrent: thread.id == highlightedID)
            ForEach(thread.replies) { reply in
                commentRow(reply, isReply: true, isCurrent: reply.id == highlightedID)
                    .padding(.leading, rowStyle.spaceBase)
            }
        }
        .id(thread.id)
    }

    private func commentRow(_ comment: Comment, isReply: Bool, isCurrent: Bool) -> some View {
        MacCommentRow(
            comment: comment,
            isReply: isReply,
            isCurrent: isCurrent,
            style: rowStyle,
            onSeek: comment.timeInTrack.map { time in
                { onSeek(time) }
            },
            searchURL: Self.searchURL(for: comment)
        )
    }

    private static func searchURL(for comment: Comment) -> URL? {
        guard let query = comment.searchQuery else { return nil }
        var components = URLComponents(string: "https://soundcloud.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

private struct MacCommentRow: View {
    let comment: Comment
    let isReply: Bool
    let isCurrent: Bool
    let style: SCContentStyle
    let onSeek: (() -> Void)?
    let searchURL: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: style.spaceTight) {
            SCCommentRow(
                comment: comment,
                isReply: isReply,
                isHighlighted: isCurrent,
                bodyLineLimit: isCurrent ? 6 : 3,
                style: style
            )

            if let searchURL {
                Button {
                    openURL(searchURL)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(style.accent)
                .help("Search SoundCloud for \(comment.searchQuery ?? "this track")")
                .accessibilityLabel("Search SoundCloud for track mentioned in comment")
            }
        }
        .padding(style.spaceTight)
        .background(
            RoundedRectangle(cornerRadius: style.cornerControl, style: .continuous)
                .fill(isCurrent ? style.accent.opacity(0.12) : Color.clear)
        )
        .macHoverRowHighlight(cornerRadius: style.cornerControl)
        .contentShape(Rectangle())
        .onTapGesture { onSeek?() }
        .contextMenu {
            if let onSeek, let time = comment.timeInTrack {
                Button("Jump to \(CommentFormat.clock(time))") { onSeek() }
            }
            if let searchURL {
                Button("Search on SoundCloud") { openURL(searchURL) }
            }
            Button("View \(comment.user.displayName) on SoundCloud") {
                openURL(comment.user.permalinkURL)
            }
        }
    }
}
