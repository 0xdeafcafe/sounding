import AVFoundation
import MediaPlayer
import SwiftUI
import TipKit
import UIKit

// MARK: - Shared controls

struct SquishButtonStyle: ButtonStyle {
    var reduceMotion: Bool
    var scale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1.0)
            .animation(
                .scMotion(SCContentMotion.press, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

struct PlayPauseGlyph: View {
    let isPlaying: Bool
    var font: Font = .title3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let image = Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(font.weight(.bold))
            .foregroundStyle(.primary)
        if reduceMotion {
            image
        } else {
            image
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isPlaying)
        }
    }
}

struct NowPlayingGlassCircle: ViewModifier {
    let diameter: CGFloat
    let tint: Color?

    static func symbolSize(_ diameter: CGFloat) -> CGFloat { diameter * 0.43 }
    static func hitPadding(_ diameter: CGFloat) -> CGFloat { max(0, (44 - diameter) / 2) }

    func body(content: Content) -> some View {
        content
            .font(.system(size: Self.symbolSize(diameter), weight: .semibold))
            .imageScale(.medium)
            .foregroundStyle(NPInk.primary)
            .frame(width: diameter, height: diameter)
            .glassEffect(glass, in: .circle)
            .padding(Self.hitPadding(diameter))
            .contentShape(Rectangle())
    }

    private var glass: Glass {
        if let tint { return .regular.tint(tint).interactive() }
        return .regular.interactive()
    }
}

extension View {
    func nowPlayingGlassCircle(diameter: CGFloat, tint: Color?) -> some View {
        modifier(NowPlayingGlassCircle(diameter: diameter, tint: tint))
    }
}

struct GlassCircleButton<Label: View>: View {
    let diameter: CGFloat
    var tint: Color?
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .nowPlayingGlassCircle(diameter: diameter, tint: tint)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

enum NowPlayingTint {
    static func artist(_ accent: Color) -> Color {
        let rgb = SCAmbient.components(accent)
        let mixed = SCAmbient.composite(SCAmbient.RGB(r: 1, g: 1, b: 1), alpha: 0.45, over: rgb)
        return Color(rgb: mixed)
    }

    static func glass(_ accent: Color) -> Color {
        accent.opacity(0.16)
    }
}

// MARK: - Transport

private struct NowPlayingTransportButtonStyle: ButtonStyle {
    let diameter: CGFloat
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.86 : 1)
            .frame(width: diameter, height: diameter)
            .background {
                Circle()
                    .fill(NPInk.fillStrong)
                    .scaleEffect(configuration.isPressed || reduceMotion ? 1 : 0.6)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .contentShape(Circle())
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : NPMotion.spring, value: configuration.isPressed)
    }
}

struct NowPlayingTransport: View {
    let snapshot: NowPlayingSnapshot
    var playSize: CGFloat = 34
    var skipSize: CGFloat = 26

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var skipFeedback = 0

    var body: some View {
        HStack(spacing: 0) {
            Button {
                skipFeedback += 1
                coordinator.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: skipSize, weight: .regular))
            }
            .buttonStyle(NowPlayingTransportButtonStyle(diameter: skipSize + 30, reduceMotion: reduceMotion))
            .accessibilityLabel("Previous Track")

            Spacer(minLength: 0)

            Button {
                coordinator.togglePlayPause()
            } label: {
                PlayPauseGlyph(isPlaying: snapshot.showsPauseGlyph, font: .system(size: playSize))
            }
            .buttonStyle(NowPlayingTransportButtonStyle(diameter: playSize + 32, reduceMotion: reduceMotion))
            .accessibilityLabel(snapshot.isLoading ? "Loading" : (snapshot.isPlaying ? "Pause" : "Play"))

            Spacer(minLength: 0)

            Button {
                skipFeedback += 1
                coordinator.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: skipSize, weight: .regular))
            }
            .buttonStyle(NowPlayingTransportButtonStyle(diameter: skipSize + 30, reduceMotion: reduceMotion))
            .accessibilityLabel("Next Track")
        }
        .foregroundStyle(NPInk.primary)
        .sensoryFeedback(.impact(weight: .medium), trigger: snapshot.isPlaying)
        .sensoryFeedback(.impact(weight: .light), trigger: skipFeedback)
    }
}

// MARK: - Volume

@MainActor
@Observable
final class NowPlayingVolume {
    static let shared = NowPlayingVolume()

    private(set) var level: Float
    @ObservationIgnored private var hosts: [WeakVolumeView] = []
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var isAdjusting = false

    private init() {
        level = AVAudioSession.sharedInstance().outputVolume
        observation = Self.observeOutputVolume { value in
            NowPlayingVolume.shared.receive(value)
        }
    }

    nonisolated private static func observeOutputVolume(_ handler: @escaping @MainActor @Sendable (Float) -> Void) -> NSKeyValueObservation {
        AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in handler(value) }
        }
    }

    private func receive(_ value: Float) {
        guard !isAdjusting else { return }
        level = value
    }

    private struct WeakVolumeView {
        weak var view: MPVolumeView?
    }

    func register(_ view: MPVolumeView) {
        hosts.removeAll { $0.view == nil || $0.view === view }
        hosts.append(WeakVolumeView(view: view))
    }

    private var slider: UISlider? {
        hosts.removeAll { $0.view == nil }
        for host in hosts.reversed() {
            if let slider = host.view?.subviews.compactMap({ $0 as? UISlider }).first { return slider }
        }
        return nil
    }

    var isAvailable: Bool { slider != nil }

    func begin() { isAdjusting = true }

    func end() { isAdjusting = false }

    func set(_ value: Float) {
        let clamped = min(1, max(0, value))
        level = clamped
        slider?.value = clamped
        slider?.sendActions(for: .valueChanged)
    }
}

struct SystemVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        view.alpha = 0.001
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        NowPlayingVolume.shared.register(view)
    }
}

struct NowPlayingVolumeSlider: View {
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    var body: some View {
        if coordinator.volumeRoute.isRemote {
            NowPlayingRemoteVolumeSlider()
        } else {
            NowPlayingLocalVolumeSlider()
        }
    }
}

private struct NowPlayingLocalVolumeSlider: View {
    private var volume: NowPlayingVolume { .shared }

    var body: some View {
        NowPlayingVolumeTrack(
            level: Double(volume.level),
            label: "Volume",
            onBegin: { volume.begin() },
            onChange: { volume.set(Float($0)) },
            onEnd: { volume.end() }
        )
        .background { SystemVolumeHost().frame(width: 4, height: 4).accessibilityHidden(true) }
    }
}

private struct NowPlayingRemoteVolumeSlider: View {
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @State private var dragLevel: Double?

    var body: some View {
        if let reported = coordinator.remoteVolume {
            NowPlayingVolumeTrack(
                level: dragLevel ?? reported,
                label: "\(coordinator.remoteVolumeName) Volume",
                onBegin: { coordinator.beginRemoteVolumeChange() },
                onChange: { value in
                    dragLevel = value
                    coordinator.setRemoteVolume(value)
                },
                onEnd: {
                    coordinator.endRemoteVolumeChange()
                    dragLevel = nil
                }
            )
        } else {
            Color.clear
                .frame(height: 44)
                .accessibilityHidden(true)
        }
    }
}

private struct NowPlayingVolumeTrack: View {
    let level: Double
    let label: String
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isActive = false
    @State private var width: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? NPInk.secondary : NPInk.tertiary)
                .offset(x: isActive && !reduceMotion ? -3 : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(NPInk.faint)
                Capsule()
                    .fill(isActive ? NPInk.primary : NPInk.secondary)
                    .frame(width: max(0, width * CGFloat(min(1, max(0, level)))))
            }
            .frame(height: 6)
            .clipShape(Capsule())
            .scaleEffect(x: 1, y: isActive && !reduceMotion ? 1.9 : 1)
            .frame(height: 44)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isActive {
                            isActive = true
                            onBegin()
                        }
                        onChange(min(1, max(0, Double(value.location.x / max(width, 1)))))
                    }
                    .onEnded { _ in
                        isActive = false
                        onEnd()
                    }
            )
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? NPInk.secondary : NPInk.tertiary)
                .offset(x: isActive && !reduceMotion ? 3 : 0)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : NPMotion.spring, value: isActive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            onChange(min(1, max(0, level + (direction == .increment ? 0.0625 : -0.0625))))
        }
    }
}

// MARK: - Title

struct NowPlayingTitleBlock: View {
    let title: String
    let artist: String
    let tint: Color
    var font: Font = .title2
    var trackId: String? = nil

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    private var subtitle: String {
        guard let trackId, let track = coordinator.currentTrack, track.id == trackId,
              let album = track.albumDisplayName else { return artist }
        return "\(artist) \u{2014} \(album)"
    }

    var body: some View {
        let subtitle = subtitle
        VStack(alignment: .leading, spacing: 0) {
            NowPlayingFadingLine(text: title, font: font.weight(.semibold), color: NPInk.primary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            NowPlayingFadingLine(text: subtitle, font: font, color: tint)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(subtitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NowPlayingFadingLine: View {
    let text: String
    let font: Font
    let color: Color

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0

    private var overflows: Bool { textWidth > boxWidth + 1 }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            label
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            label
                .lineLimit(1)
                .hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
                .overlay(alignment: .leading) {
                    label
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                }
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: overflows ? 0.82 : 1),
                            .init(color: overflows ? .clear : .black, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
        }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .tracking(-0.35)
            .foregroundStyle(color)
    }
}

// MARK: - Mix line

struct NowPlayingMixLine: View {
    let trackId: String?
    let timeline: NowPlayingTimeline
    var font: Font = .subheadline
    let action: () -> Void

    @ObservedObject private var setlists = SetlistIntelligenceStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var entry: TracklistEntry?

    private var tracklist: Tracklist? {
        guard let list = setlists.tracklist(for: trackId), !list.isEmpty else { return nil }
        return list
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .font(font.weight(.medium))
                Text(entry.map { NowPlayingSegmentText.line($0.segment) } ?? " ")
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 1)
                    .multilineTextAlignment(.leading)
                    .contentTransition(.opacity)
            }
            .font(font)
            .foregroundStyle(NPInk.primary.opacity(0.86))
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(entry == nil ? 0 : 1)
        .allowsHitTesting(entry != nil)
        .accessibilityHidden(entry == nil)
        .accessibilityLabel(entry.map { "Now in this mix, \(NowPlayingSegmentText.line($0.segment))" } ?? "")
        .accessibilityHint("Opens the tracklist")
        .animation(.easeInOut(duration: 0.3), value: entry?.id)
        .task(id: Key(trackId: trackId, anchor: timeline.anchor, count: tracklist?.entries.count ?? 0)) {
            await follow()
        }
    }

    private struct Key: Equatable {
        let trackId: String?
        let anchor: PlaybackAnchor
        let count: Int
    }

    private func follow() async {
        while !Task.isCancelled {
            guard let list = tracklist else {
                entry = nil
                return
            }
            let anchor = timeline.anchor
            let position = anchor.position(at: .now)
            let current = list.currentEntry(at: position) ?? list.entries.first
            if current != entry { entry = current }
            guard anchor.isAdvancing, let current else { return }
            let wait = min(30, max(0.25, current.endSeconds - position + 0.05))
            try? await Task.sleep(for: .seconds(wait / max(anchor.rate, 0.01)))
        }
    }
}

// MARK: - Actions

struct NowPlayingLikeButton: View {
    let trackId: String?
    let resolved: Track?
    let likes: NowPlayingLikeModel
    let diameter: CGFloat
    let glassTint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isLiked = trackId.map { likes.isLiked($0, resolved: resolved) } ?? false
        GlassCircleButton(diameter: diameter, tint: glassTint) {
            guard let trackId else { return }
            likes.toggle(trackId: trackId, resolved: resolved)
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .speed(1.4), value: reduceMotion ? false : isLiked)
        }
        .disabled(trackId == nil)
        .accessibilityLabel(isLiked ? "Remove from Likes" : "Add to Likes")
        .sensoryFeedback(.impact(weight: .light), trigger: isLiked)
    }
}

struct NowPlayingMoreActions {
    var showsComments = false
    var showsLyrics = true
    let onTracklist: () -> Void
    let onComments: () -> Void
    var onLyrics: () -> Void = {}
    var onAbout: () -> Void = {}
    let onCues: () -> Void
    let onAutoMix: (Bool) -> Void
    let onDecks: () -> Void
    var nextMove: String?
    var canMixNow = false
    var canExtend = false
    var onMixNow: () -> Void = {}
    var onExtend: () -> Void = {}
    var sleepTimer: SleepTimerStatus?
    var offersEndOfMix = false
    var onSleepTimer: (SleepTimerMode?) -> Void = { _ in }
}

struct NowPlayingMoreMenu: View {
    let track: Track?
    let trackId: String?
    var isDeviceTrack = false
    let diameter: CGFloat
    let glassTint: Color
    let cueCount: Int
    let isAutoMixOn: Bool
    let actions: NowPlayingMoreActions

    @ObservedObject private var listenTogether = ListenTogether.shared

    var body: some View {
        NowPlayingMoreMenuBody(
            inputs: NowPlayingMoreMenuInputs(
                trackId: trackId,
                hasTrack: track != nil,
                permalink: isDeviceTrack ? nil : track?.permalinkURL,
                isDeviceTrack: isDeviceTrack,
                diameter: diameter,
                glassTint: glassTint,
                isAutoMixOn: isAutoMixOn,
                isListenTogetherActive: listenTogether.isActive,
                showsComments: actions.showsComments,
                showsLyrics: actions.showsLyrics,
                canMixNow: actions.canMixNow,
                canExtend: actions.canExtend,
                sleepTimer: actions.sleepTimer,
                offersEndOfMix: actions.offersEndOfMix
            ),
            track: track,
            actions: actions
        )
        .equatable()
    }
}

struct NowPlayingMoreMenuInputs: Equatable {
    var trackId: String?
    var hasTrack: Bool
    var permalink: URL?
    var isDeviceTrack: Bool
    var diameter: CGFloat
    var glassTint: Color
    var isAutoMixOn: Bool
    var isListenTogetherActive: Bool
    var showsComments: Bool
    var showsLyrics: Bool
    var canMixNow: Bool
    var canExtend: Bool
    var sleepTimer: SleepTimerStatus?
    var offersEndOfMix: Bool
}

private struct NowPlayingMoreMenuBody: View, @MainActor Equatable {
    let inputs: NowPlayingMoreMenuInputs
    let track: Track?
    let actions: NowPlayingMoreActions

    @State private var tips = TipGroup(.ordered) {
        AddToPlaylistTip()
        AutoMixTip()
        SleepTimerTip()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.inputs == rhs.inputs
    }

    var body: some View {
        Menu {
            Section {
                if let url = inputs.permalink {
                    Menu {
                        ListenTogetherShareLink(url: url, trackID: inputs.trackId, title: track?.title ?? "Sounding") {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        ListenTogetherMenuItems()
                        Button {
                            UIPasteboard.general.url = url
                        } label: {
                            Label("Copy Link", systemImage: "link")
                        }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                if let track {
                    AddToPlaylistMenuButton(track: track)
                    TrackDownloadMenuItems(track: track)
                    WakeToThisMenuButton(track: track)
                }
            }
            Section {
                Toggle(isOn: Binding(get: { inputs.isAutoMixOn && !inputs.isListenTogetherActive }, set: { actions.onAutoMix($0) })) {
                    Label("Auto Mix", systemImage: "infinity")
                    if inputs.isListenTogetherActive {
                        Text("Off during SharePlay")
                    }
                }
                .disabled(inputs.isListenTogetherActive)
                if inputs.isAutoMixOn {
                    Menu {
                        Button(action: actions.onMixNow) {
                            Label("Mix Now", systemImage: "arrow.triangle.merge")
                        }
                        .disabled(!inputs.canMixNow)
                        Button(action: actions.onExtend) {
                            Label("Extend This", systemImage: "arrow.right.to.line")
                        }
                        .disabled(!inputs.canExtend)
                        MixSaveLatestButton(title: "Save Last Mix", iconOnly: false)
                    } label: {
                        Label("Mix", systemImage: "arrow.triangle.merge")
                    }
                }
                Button(action: actions.onDecks) {
                    Label("Decks", systemImage: "opticaldisc")
                }
            }
            Section {
                Button(action: actions.onAbout) {
                    Label("Behind the Track", systemImage: "info.circle")
                }
                ControlGroup {
                    Button(action: actions.onTracklist) {
                        Label("Tracklist", systemImage: "music.note.list")
                    }
                    if inputs.showsLyrics {
                        Button(action: actions.onLyrics) {
                            Label("Lyrics", systemImage: "quote.bubble")
                        }
                    }
                    if inputs.showsComments {
                        Button(action: actions.onComments) {
                            Label("Comments", systemImage: "bubble.left")
                        }
                    }
                    Button(action: actions.onCues) {
                        Label("Cue Points", systemImage: "flag")
                    }
                }
                SleepTimerPicker(
                    status: inputs.sleepTimer,
                    offersEndOfMix: inputs.offersEndOfMix,
                    onSelect: actions.onSleepTimer
                )
            }
        } label: {
            Image(systemName: "ellipsis")
                .nowPlayingGlassCircle(diameter: inputs.diameter, tint: inputs.glassTint)
        }
        .menuStyle(.button)
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("More")
        .fixedSize()
        .popoverTip(tips.currentTip, arrowEdge: .top)
    }
}

// MARK: - Output

struct NowPlayingRouteBadge: View {
    let device: OutputDevice

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: device.symbolName)
                .font(.system(size: 13, weight: .semibold))
            Text(device.name)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.leading, 9)
        .padding(.trailing, 12)
        .frame(minHeight: 30)
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playing on \(device.name)")
    }
}
