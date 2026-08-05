import SwiftUI
import AppKit
import AVKit

struct MacTransportBar: View {
    var activeSidebarPane: MacNowPlayingPane? = nil
    var onExpand: (MacNowPlayingPane) -> Void = { _ in }

    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var waveforms = WaveformService.shared

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var palette: ArtworkPalette = .fallback
    @State private var isHoveringArtwork = false
    @State private var isHoveringWaveform = false
    @State private var waveformGracePeriodEnded = false
    @State private var dragFraction: Double?
    @State private var cuePoints: [CuePoint] = []

    private var track: Track? { player.currentTrack }

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: 820)
            .background(
                Color.black.opacity(track == nil ? 0.14 : 0.24),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .glassEffect(
                .regular.tint(palette.accent.opacity(track == nil ? 0.025 : 0.075)),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.22), radius: 16, y: 7)
            .frame(maxWidth: .infinity)
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 28, style: .continuous))
            .simultaneousGesture(TapGesture().onEnded {})
            .frame(height: 74)
            .task(id: track?.artworkURL) {
                guard let url = track?.artworkURL else {
                    palette = .fallback
                    return
                }
                palette = await ArtworkCache.shared.palette(for: url)
            }
            .task(id: track?.id) {
                waveformGracePeriodEnded = false
                cuePoints = []
                guard let track else { return }
                cuePoints = await CueStore.shared.cues(forTrack: track.id)
                waveforms.load(track)
                try? await Task.sleep(for: .seconds(1.4))
                if !Task.isCancelled { waveformGracePeriodEnded = true }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let track {
            ViewThatFits(in: .horizontal) {
                playingRow(track)
                compactPlayingRow(track)
            }
        } else {
            idleRow
        }
    }

    private func playingRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            transportControls(enabled: true)
                .frame(minWidth: 102, idealWidth: leadingClusterWidth, maxWidth: leadingClusterWidth, alignment: .leading)

            playbackLane(track)
                .layoutPriority(2)

            secondaryActions()
                .frame(minWidth: 136, idealWidth: trailingClusterWidth, maxWidth: trailingClusterWidth, alignment: .trailing)
        }
    }

    /// Artist split views can leave less horizontal room than the full
    /// transport requires. Keep the essential controls and identity visible
    /// instead of allowing the full row's minimum widths to escape the pane.
    private func compactPlayingRow(_ track: Track) -> some View {
        HStack(spacing: 8) {
            transportControls(enabled: true)
                .frame(width: 102, alignment: .leading)

            Button {
                MacNowPlayingPresentation.shared.present()
            } label: {
                HStack(spacing: 7) {
                    identityArtwork(track.artworkURL)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(track.user.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                queueButton
                trackMenu(track)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minWidth: 330, maxWidth: .infinity)
    }

    private var leadingClusterWidth: CGFloat { 154 }
    private var trailingClusterWidth: CGFloat { 156 }

    /// The identity and the seek surface share one lane. At rest the chart is
    /// deliberately quiet; hovering it turns the lane into the full scrubber.
    private func playbackLane(_ track: Track) -> some View {
        ZStack {
            if isHoveringWaveform {
                expandedWaveformLane
                    .transition(.opacity)
            } else {
                compactIdentityLane(track)
                    .transition(.opacity)
            }
        }
        .animation(SCContentMotion.focus, value: isHoveringWaveform)
        .help(track.user.displayName)
        .frame(
            minWidth: 260,
            maxWidth: .infinity,
            minHeight: 50,
            maxHeight: 50
        )
        // A 13-point strip is too exacting a hover target. Treat the entire
        // identity/seek lane as the waveform affordance.
        .onHover(perform: updateWaveformHover)
    }

    private func compactIdentityLane(_ track: Track) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 8) {
                Button {
                    MacNowPlayingPresentation.shared.present()
                } label: {
                    identityArtwork(track.artworkURL)
                        .overlay {
                            if isHoveringArtwork {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.black.opacity(0.42))
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                .transition(.opacity)
                            }
                        }
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(SCContentMotion.focus) {
                        isHoveringArtwork = hovering
                    }
                }

                HStack(spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("—")
                        .foregroundStyle(.tertiary)
                    Text(track.user.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

                Spacer(minLength: 8)
            }

            progressLine(height: 12)
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var expandedWaveformLane: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text(macFormatTime(displayedTime))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(macFormatRemaining(current: displayedTime, duration: player.duration))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .padding(.horizontal, 4)
            .frame(height: 13)

            progressLine(height: 37)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateWaveformHover(_ hovering: Bool) {
        withAnimation(SCContentMotion.focus) {
            isHoveringWaveform = hovering
        }
    }

    private func trackMenu(_ track: Track) -> some View {
        Menu {
            Button(MacTrackEngagement.shared.isLiked(track) ? "Unlike" : "Like") {
                Task { await MacTrackEngagement.shared.toggleLike(track) }
            }
            Divider()
            Button("Show Up Next") { onExpand(.queue) }
            Button("Show Timed Comments") { onExpand(.comments) }
            if player.queue.count > player.currentIndex + 1 {
                Button("Clear Up Next", role: .destructive) { player.clearQueue() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func secondaryActions() -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                if let track { trackMenu(track) }
                commentsButton
                queueButton
                miniPlayerButton
                routeButton
            }
            HStack(spacing: 0) {
                if let track { trackMenu(track) }
                commentsButton
                queueButton
                routeButton
            }
        }
        .frame(minWidth: 110, alignment: .trailing)
    }

    private var commentsButton: some View {
        iconButton(
            "bubble.left.and.bubble.right",
            help: "Timed Comments",
            active: activeSidebarPane == .comments
        ) { onExpand(.comments) }
    }

    private var queueButton: some View {
        iconButton(
            "list.bullet",
            help: "Up Next",
            active: activeSidebarPane == .queue
        ) { onExpand(.queue) }
    }

    private var miniPlayerButton: some View {
        iconButton("rectangle.inset.filled.on.rectangle", help: "Mini Player") {
            MacMusicWindowCoordinator.shared.request(.miniPlayer)
            openWindow(id: "mini-player")
            dismissWindow(id: "main")
        }
    }

    @ViewBuilder
    private var routeButton: some View {
        MacRoutePickerView()
            .frame(width: 20, height: 20)
            .padding(7)
            .contentShape(Rectangle())
    }

    private func progressLine(height: CGFloat) -> some View {
        GeometryReader { geometry in
            SCWaveformRenderer(
                envelope: transportWaveformEnvelope,
                duration: max(player.duration, 0.001),
                progress: dragFraction ?? (player.duration > 0 ? player.currentTime / player.duration : 0),
                cueMarkers: transportCueMarkers,
                placeholder: transportWaveformPlaceholder,
                identity: track?.id,
                motionSuppressed: waveformGracePeriodEnded,
                style: transportWaveformStyle
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = scrubFraction(at: value.location.x, width: geometry.size.width)
                    }
                    .onEnded { value in
                        let fraction = scrubFraction(at: value.location.x, width: geometry.size.width)
                        player.seek(to: fraction * player.duration)
                        dragFraction = nil
                    }
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .help("Drag to seek")
        .accessibilityHidden(true)
    }

    private var displayedTime: TimeInterval {
        dragFraction.map { $0 * player.duration } ?? player.currentTime
    }

    private func scrubFraction(at x: CGFloat, width: CGFloat) -> Double {
        Double(max(0, min(1, x / max(1, width))))
    }

    private var transportWaveformEnvelope: [Float] {
        guard let track, case .ready(let waveform) = waveforms.state(for: track.id) else { return [] }
        return SCWaveformSampler.visuallyNormalized(waveform.samples, floor: 0.06)
    }

    private var transportWaveformPlaceholder: SCWaveformPlaceholder {
        guard let track else { return .unavailable }
        switch waveforms.state(for: track.id) {
        case .pending, .loading: return waveformGracePeriodEnded ? .unavailable : .loading
        case .ready(let waveform): return waveform.isEmpty ? .unavailable : .loading
        case .failed: return .unavailable
        }
    }

    private var transportCueMarkers: [SCWaveformMarker] {
        guard player.duration > 0 else { return [] }
        return cuePoints.compactMap { cue in
            let fraction = cue.positionSeconds / player.duration
            guard fraction >= 0, fraction <= 1 else { return nil }
            return SCWaveformMarker(id: cue.id, position: fraction, color: macCueColor(cue))
        }
    }

    private var transportWaveformStyle: SCWaveformStyle {
        var content = SCContentStyle.mac
        content.accent = palette.accent
        var style = SCWaveformStyle.derived(from: content, dense: true)
        style.barPitch = 2
        style.barGap = 1
        style.barCornerRadius = 1
        // The resting strip still carries the track's silhouette; on hover
        // it opens into the full, high-contrast scrubbing waveform.
        // restFraction is the usable amplitude, not the empty margin. The
        // former 0.12 hover value forced almost every sample down to the
        // minimum bar height, producing a flat picket fence.
        style.restFraction = isHoveringWaveform ? 0.92 : 0.34
        style.minBarHalfHeight = isHoveringWaveform ? 1.5 : 1.7
        style.verticalInset = 1
        style.playedGlow = false
        style.glowBlurRadius = 0
        style.playheadColor = .primary
        return style
    }

    private var idleRow: some View {
        HStack(spacing: 12) {
            transportControls(enabled: false)
                .frame(width: leadingClusterWidth, alignment: .leading)

            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.24), radius: 5, y: 2)
                Text("SoundingCloud")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }

            HStack(spacing: 14) {
                iconButton("bubble.left.and.bubble.right", help: "Timed Comments", enabled: false) {}
                iconButton(
                    "list.bullet",
                    help: "Up Next",
                    active: activeSidebarPane == .queue
                ) { onExpand(.queue) }
            }
            .frame(width: trailingClusterWidth, alignment: .trailing)
        }
    }

    private func transportControls(enabled: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                shuffleButton(enabled: enabled)
                previousButton(enabled: enabled)
                playPauseButton(enabled: enabled)
                nextButton(enabled: enabled)
                repeatButton(enabled: enabled)
            }
            HStack(spacing: 0) {
                previousButton(enabled: enabled)
                playPauseButton(enabled: enabled)
                nextButton(enabled: enabled)
            }
        }
    }

    private func shuffleButton(enabled: Bool) -> some View {
        iconButton("shuffle", help: "Shuffle", active: player.isShuffleEnabled, enabled: enabled) {
            player.toggleShuffle()
        }
    }

    private func previousButton(enabled: Bool) -> some View {
        iconButton("backward.fill", help: "Previous", enabled: enabled) {
            Task { await InstantReplay.previous(player) }
        }
    }

    private func playPauseButton(enabled: Bool) -> some View {
        iconButton(
            player.isPlaying ? "pause.fill" : "play.fill",
            size: 17, help: player.isPlaying ? "Pause" : "Play", enabled: enabled
        ) {
            player.togglePlayPause()
        }
        .background(Color.primary.opacity(enabled ? 0.08 : 0.03), in: Circle())
    }

    private func nextButton(enabled: Bool) -> some View {
        iconButton("forward.fill", help: "Next", enabled: enabled) {
            Task { await player.playNext() }
        }
    }

    private func repeatButton(enabled: Bool) -> some View {
        iconButton(repeatSymbol, help: "Repeat", active: player.repeatMode.isActive, enabled: enabled) {
            player.repeatMode = nextRepeatMode
        }
    }

    private var repeatSymbol: String { player.repeatMode.icon }

    private var nextRepeatMode: RepeatMode {
        switch player.repeatMode {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    private func identityArtwork(_ url: URL?) -> some View {
        ArtworkThumbnail(
            url: url,
            identity: player.currentTrack?.title ?? "",
            size: 34,
            cornerRadius: 7,
            crownUser: player.currentTrack?.user,
            crownContext: player.currentTrack?.title
        )
    }

    private func iconButton(
        _ systemImage: String?,
        size: CGFloat = 13,
        help: String,
        active: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Color.clear
                }
            }
            .font(.system(size: size, weight: .semibold))
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(MacTransportButtonStyle(isActive: active, isEnabled: enabled))
        .foregroundStyle(active ? Color.accentColor : (enabled ? Color.primary : Color.primary.opacity(0.3)))
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct MacTransportButtonStyle: ButtonStyle {
    let isActive: Bool
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle().fill(
                    isActive
                        ? Color.accentColor.opacity(0.14)
                        : Color.primary.opacity(configuration.isPressed && isEnabled ? 0.10 : 0)
                )
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.94 : 1)
            .animation(SCContentMotion.focus, value: configuration.isPressed)
    }
}

private struct MacRoutePickerView: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

struct MacMiniPlayerView: View {
    @ObservedObject private var player = PlayerService.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var palette: ArtworkPalette = .fallback

    private var track: Track? { player.currentTrack }

    var body: some View {
        VStack(spacing: 10) {
            if let track {
                header(track)
                scrubber
            } else {
                Text("Nothing Playing")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            transportRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MacVisualEffectBackground(role: .hudWindow).ignoresSafeArea())
        .task(id: track?.artworkURL) {
            guard let url = track?.artworkURL else {
                palette = .fallback
                return
            }
            palette = await ArtworkCache.shared.palette(for: url)
        }
    }

    private func header(_ track: Track) -> some View {
        HStack(spacing: 10) {
            ArtworkThumbnail(url: track.artworkURL, identity: track.title, size: 44, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(track.user.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                MacMusicWindowCoordinator.shared.request(.main)
                openWindow(id: "main")
                dismissWindow(id: "mini-player")
                MacNowPlayingPresentation.shared.present()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open Now Playing")
        }
    }

    private var scrubber: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let fraction = player.duration > 0 ? player.currentTime / player.duration : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15)).frame(height: 3)
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: geo.size.width * max(0, min(1, fraction)), height: 3)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { value in
                        guard player.duration > 0, geo.size.width > 0 else { return }
                        let target = max(0, min(1, value.location.x / geo.size.width))
                        player.seek(to: target * player.duration)
                    }
                )
            }
            .frame(height: 3)

            HStack {
                Text(macFormatTime(player.currentTime))
                Spacer()
                Text(macFormatRemaining(current: player.currentTime, duration: player.duration))
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 18) {
            Spacer(minLength: 0)
            miniButton("shuffle", active: player.isShuffleEnabled) { player.toggleShuffle() }
            miniButton("backward.fill") { Task { await InstantReplay.previous(player) } }
            miniButton(player.isPlaying ? "pause.fill" : "play.fill", size: 16) { player.togglePlayPause() }
            miniButton("forward.fill") { Task { await player.playNext() } }
            miniButton(player.repeatMode.icon, active: player.repeatMode.isActive) {
                player.repeatMode = player.repeatMode.miniNext
            }
            Spacer(minLength: 0)
        }
    }

    private func miniButton(
        _ systemImage: String,
        size: CGFloat = 13,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.accentColor : Color.primary)
        .disabled(player.currentTrack == nil)
    }
}

extension RepeatMode {
    var miniNext: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

enum InstantReplay {
    static let threshold: TimeInterval = 3

    @MainActor
    static func previous(_ player: PlayerService) async {
        if player.currentTime > threshold {
            player.seek(to: 0)
        } else {
            await player.playPrevious()
        }
    }
}

struct ArtworkThumbnail: View {
    var candidates: [URL]
    var identity: String = ""
    var size: CGFloat = 40
    var cornerRadius: CGFloat = 5
    var isAvailable: Bool = true
    var crownUser: User?
    var crownContext: String?

    @State private var image: NSImage?

    init(
        url: URL?, identity: String = "", size: CGFloat = 40,
        cornerRadius: CGFloat = 5, isAvailable: Bool = true,
        crownUser: User? = nil, crownContext: String? = nil
    ) {
        self.candidates = url.map { [$0] } ?? []
        self.identity = identity
        self.size = size
        self.cornerRadius = cornerRadius
        self.isAvailable = isAvailable
        self.crownUser = crownUser
        self.crownContext = crownContext
    }

    init(
        candidates: [URL], identity: String = "", size: CGFloat = 40,
        cornerRadius: CGFloat = 5, isAvailable: Bool = true,
        crownUser: User? = nil, crownContext: String? = nil
    ) {
        self.candidates = candidates
        self.identity = identity
        self.size = size
        self.cornerRadius = cornerRadius
        self.isAvailable = isAvailable
        self.crownUser = crownUser
        self.crownContext = crownContext
    }

    var body: some View {
        SCArtwork(
            image: image.map { Image(nsImage: $0) },
            identity: identity,
            isAvailable: isAvailable,
            style: .mac,
            cornerRadius: cornerRadius,
            usesGeneratedFallback: size > 64
        )
        .frame(width: size, height: size)
        .kyleCrowned(user: crownUser, context: crownContext)
        .task(id: candidates) {
            image = nil
            image = await MacCoverArt.load(candidates)
        }
    }
}
