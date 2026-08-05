import SwiftUI
import WidgetKit
import ActivityKit
import UIKit

/// SoundingCloud Now Playing Live Activity.
///
/// Designed against Apple's Live Activity Human Interface Guidelines and the
/// WWDC23 "Design dynamic Live Activities" guidance:
///   - Lock Screen / StandBy: 14 pt margins, content-driven background, bold accent
///   - Dynamic Island compact: snug, no wasted space, recognisable at a glance
///   - Dynamic Island expanded: hugs the sensor, rounded thick shapes, bright tints
///   - All surfaces use `ContainerRelativeShape` so nested rounded rects stay
///     concentric with the system container.
struct NowPlayingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(context.state.cardTint)
                .activitySystemActionForegroundColor(context.state.systemActionColor)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailing(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.center) {
                    ExpandedCenter(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                CompactLeading(state: context.state)
            } compactTrailing: {
                CompactTrailing(state: context.state, isStale: context.isStale)
            } minimal: {
                MinimalGlyph(state: context.state)
            }
            .keylineTint(context.state.accent)
        }
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Color & State styling

private extension Color {
    static let djLive = Color(red: 1.0, green: 0.42, blue: 0.2)
    static let soundingCloud = Color(red: 1.0, green: 0.35, blue: 0.18)
}

private extension NowPlayingActivityAttributes.ContentState {
    var accent: Color {
        if let components = accentComponents {
            return Color(red: components.red, green: components.green, blue: components.blue)
        }
        return isDJModeLive ? .djLive : .soundingCloud
    }

    /// Lock Screen / StandBy background. Uses a heavily muted version of the
    /// accent so foreground text stays legible and the system dismiss button
    /// picks up a matching tone.
    var cardTint: Color {
        guard let components = accentComponents else {
            return Color.black.opacity(0.78)
        }
        return Color(
            red: components.red * 0.18,
            green: components.green * 0.18,
            blue: components.blue * 0.18
        )
    }

    var systemActionColor: Color {
        guard accentComponents != nil else { return .white }
        return .white
    }

    var artworkImage: UIImage? {
        guard let url = artworkFileURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    var sourceIconName: String {
        playbackSource.iconName
    }
}

// MARK: - Artwork

/// Album artwork with a deterministic gradient fallback. The clip shape uses
/// `ContainerRelativeShape` so the artwork corners stay concentric with any
/// outer rounded container.
private struct ArtworkView: View {
    let state: NowPlayingActivityAttributes.ContentState
    var size: CGFloat = 58
    var cornerRadius: CGFloat? = nil
    var glows = true

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        ZStack {
            if let image = state.artworkImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                GeneratedLiveArtwork(state: state)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.18, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
        .background {
            if glows && !isLuminanceReduced {
                RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.18, style: .continuous)
                    .fill(state.accent)
                    .blur(radius: size * 0.16)
                    .opacity(0.5)
                    .offset(y: size * 0.08)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct GeneratedLiveArtwork: View {
    let state: NowPlayingActivityAttributes.ContentState

    private var seed: UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(state.trackTitle)|\(state.artistName)".lowercased().utf8 {
            value ^= UInt64(byte)
            value = value &* 0x1000_0000_01b3
        }
        return value
    }

    private var baseHue: Double { Double(seed % 10_000) / 10_000 }

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(hue: baseHue, saturation: 0.82, brightness: 0.48),
                        Color(hue: wrappedHue(baseHue + 0.09), saturation: 0.72, brightness: 0.26),
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )

            for index in 0..<5 {
                let shifted = seed &>> UInt64(index * 7)
                let x = CGFloat(shifted & 0xff) / 255 * size.width
                let y = CGFloat((shifted &>> 8) & 0xff) / 255 * size.height
                let edge = min(size.width, size.height) * CGFloat(0.45 + Double(index) * 0.09)
                let rect = CGRect(x: x - edge / 2, y: y - edge / 2, width: edge, height: edge)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(Color(
                        hue: wrappedHue(baseHue + Double(index) * 0.035),
                        saturation: 0.74,
                        brightness: 0.72
                    ).opacity(0.24))
                )
            }
        }
        .overlay {
            Image(systemName: state.isDJModeLive ? "waveform" : "music.note")
                .font(.system(size: sizeForArtwork, weight: .thin))
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    private var sizeForArtwork: CGFloat {
        // Approximate based on common uses; exact value isn't critical for the
        // fallback glyph because Canvas fills its container.
        22
    }

    private func wrappedHue(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
}

// MARK: - Equaliser

private struct EqualiserBars: View {
    let state: NowPlayingActivityAttributes.ContentState
    var barCount = 4
    var height: CGFloat = 16
    var barWidth: CGFloat = 2.5

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        if state.isPlaying && !isLuminanceReduced {
            TimelineView(.periodic(from: .now, by: 0.28)) { context in
                bars(tick: Int(context.date.timeIntervalSinceReferenceDate / 0.28))
            }
        } else {
            bars(tick: 0)
        }
    }

    private func bars(tick: Int) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(state.accent)
                    .frame(width: barWidth, height: barHeight(index: index, tick: tick))
            }
        }
        .frame(height: height, alignment: .bottom)
        .animation(.easeInOut(duration: 0.26), value: tick)
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int, tick: Int) -> CGFloat {
        guard state.isPlaying else { return height * 0.28 }
        let mixed: Int = (tick &* 73) &+ (index &* 9973)
        var seed = UInt64(bitPattern: Int64(mixed))
        seed = seed &* 6364136223846793005
        seed ^= seed >> 33
        let unit = Double(seed % 1000) / 1000.0
        return height * CGFloat(0.3 + unit * 0.7)
    }
}

// MARK: - Badges

private struct DJBadge: View {
    var compact = false

    var body: some View {
        Label("DJ", systemImage: "waveform")
            .labelStyle(.iconOnly)
            .font(.system(size: compact ? 10 : 12, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 2 : 3)
            .background(Color.djLive, in: Capsule())
            .accessibilityLabel("Auto DJ is live")
    }
}

private struct SourceBadge: View {
    let state: NowPlayingActivityAttributes.ContentState
    var compact = false

    var body: some View {
        Label(state.resolvedOutputName, systemImage: state.sourceIconName)
            .font(.system(size: compact ? 10 : 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.72))
            .lineLimit(1)
            .accessibilityLabel("Playing on \(state.resolvedOutputName)")
    }
}

// MARK: - Waveform / progress

private struct WaveformTrack: View {
    let state: NowPlayingActivityAttributes.ContentState
    var height: CGFloat = 22

    var body: some View {
        if state.isPlaying, state.timerRange != nil {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        let levels = state.waveformLevels
        let played = state.fraction
        let mix = state.mixPointFraction

        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                        let position = (Double(index) + 0.5) / Double(levels.count)
                        Capsule()
                            .fill(position <= played ? state.accent : Color.white.opacity(0.22))
                            .frame(height: max(2, height * CGFloat(0.22 + level * 0.78)))
                    }
                }
                .frame(height: height)

                if let mix {
                    Rectangle()
                        .fill(Color.djLive)
                        .frame(width: 1.5, height: height + 3)
                        .offset(x: proxy.size.width * mix)
                }
            }
            .frame(height: height, alignment: .center)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waveform, \(Int(played * 100)) percent played")
    }
}

private struct MixCountdown: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        if let range = state.mixCountdownRange {
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .bold))
                Text("Mix in")
                Text(timerInterval: range, countsDown: true)
                    .frame(width: 30, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.djLive)
            .contentTransition(.numericText())
        }
    }
}

private struct LiveProgressBar: View {
    let state: NowPlayingActivityAttributes.ContentState
    var showsTimes = true

    var body: some View {
        VStack(spacing: 2) {
            bar
            if showsTimes, state.hasKnownDuration {
                HStack(spacing: 4) {
                    elapsedLabel
                    Spacer(minLength: 2)
                    Text(Self.clock(state.duration))
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var bar: some View {
        if let range = state.timerRange {
            ProgressView(timerInterval: range, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(state.accent)
            .frame(height: 3)
        } else {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(state.accent.opacity(state.isPlaying ? 1 : 0.6))
                        .frame(width: proxy.size.width * state.fraction)
                }
            }
            .frame(height: 3)
        }
    }

    @ViewBuilder
    private var elapsedLabel: some View {
        if let range = state.timerRange {
            Text(timerInterval: range, countsDown: false)
                .contentTransition(.numericText())
                .frame(width: 42, alignment: .leading)
        } else {
            Text(Self.clock(state.elapsed))
                .contentTransition(.numericText())
        }
    }

    private var accessibilityDescription: String {
        guard state.hasKnownDuration else { return "Playback progress" }
        return "\(Self.spoken(state.elapsed)) of \(Self.spoken(state.duration))"
    }

    private static func clock(_ value: TimeInterval) -> String {
        guard value.isFinite, value > 0 else { return "0:00" }
        let total = Int(value.rounded())
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func spoken(_ value: TimeInterval) -> String {
        guard value.isFinite, value > 0 else { return "zero seconds" }
        let total = Int(value.rounded())
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 && seconds > 0 { return "\(minutes) minutes \(seconds) seconds" }
        if minutes > 0 { return "\(minutes) minutes" }
        return "\(seconds) seconds"
    }
}

// MARK: - Controls

private struct ControlGlyph: View {
    let systemName: String
    var diameter: CGFloat = 30
    var pointSize: CGFloat = 14
    var tint: Color = .white
    var filled: Color? = nil

    var body: some View {
        glyph
            .padding(6)
            .contentShape(Circle())
    }

    private var glyph: some View {
        Image(systemName: systemName)
            .font(.system(size: pointSize, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: diameter, height: diameter)
            .background(filled ?? .white.opacity(0.14), in: Circle())
    }
}

private struct TransportControls: View {
    let state: NowPlayingActivityAttributes.ContentState
    var showsMixNow = false
    var compact = false
    var expanded = false

    private var side: CGFloat { compact ? 28 : (expanded ? 44 : 36) }
    private var centre: CGFloat { compact ? 34 : (expanded ? 54 : 42) }
    private var spacing: CGFloat { compact ? 12 : (expanded ? 24 : 14) }
    private var sidePointSize: CGFloat { compact ? 12 : (expanded ? 18 : 14) }
    private var centrePointSize: CGFloat { compact ? 14 : (expanded ? 21 : 16) }

    var body: some View {
        if state.canControlFromActivity {
            HStack(spacing: spacing) {
                Button(intent: PreviousTrackIntent()) {
                    ControlGlyph(systemName: "backward.fill", diameter: side, pointSize: sidePointSize)
                }
                .accessibilityLabel("Previous Track")

                if state.isPlaying {
                    Button(intent: PauseTransportIntent()) {
                        ControlGlyph(systemName: "pause.fill", diameter: centre, pointSize: centrePointSize)
                    }
                    .accessibilityLabel("Pause")
                } else {
                    Button(intent: PlayTransportIntent()) {
                        ControlGlyph(systemName: "play.fill", diameter: centre, pointSize: centrePointSize)
                    }
                    .accessibilityLabel("Play")
                }

                Button(intent: NextTrackIntent()) {
                    ControlGlyph(systemName: "forward.fill", diameter: side, pointSize: sidePointSize)
                }
                .accessibilityLabel("Next Track")

                if showsMixNow && !state.isDJModeLive {
                    Button(intent: MixNowIntent()) {
                        ControlGlyph(
                            systemName: "waveform",
                            diameter: side,
                            pointSize: sidePointSize,
                            tint: .white,
                            filled: Color.djLive
                        )
                    }
                    .accessibilityLabel("Mix Now")
                }
            }
            .buttonStyle(.plain)
        } else {
            SourceBadge(state: state)
        }
    }
}

// MARK: - Lock Screen / StandBy / Small

private struct LockScreenView: View {
    let state: NowPlayingActivityAttributes.ContentState
    let isStale: Bool

    @Environment(\.activityFamily) private var activityFamily
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        switch activityFamily {
        case .small:
            watchLayout
        default:
            phoneLayout
        }
    }

    /// The default Lock Screen presentation. Also scaled 2× by StandBy, so
    /// all assets and fonts must remain sharp at larger sizes.
    private var phoneLayout: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ArtworkView(state: state, size: 60)
                    .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.trackTitle)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .contentTransition(.opacity)

                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .contentTransition(.opacity)

                    MixCountdown(state: state)
                }

                Spacer(minLength: 4)

                statusIndicator
            }

            if !state.waveformLevels.isEmpty {
                WaveformTrack(state: state, height: 20)
            } else {
                LiveProgressBar(state: state)
            }

            HStack(spacing: 8) {
                SourceBadge(state: state, compact: true)

                Spacer(minLength: 8)

                TransportControls(state: state)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !isLuminanceReduced {
                Group {
                    if let image = state.artworkImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        GeneratedLiveArtwork(state: state)
                    }
                }
                .blur(radius: 48)
                .opacity(0.38)
                .overlay(state.cardTint.opacity(0.55))
                .clipShape(ContainerRelativeShape())
            }
        }
        .widgetURL(URL(string: "soundingtv://now-playing"))
        .opacity(isStale ? 0.55 : 1)
    }

    private var statusIndicator: some View {
        Group {
            if isStale {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityLabel("Not responding")
            } else if state.isDJModeLive {
                DJBadge()
            } else if state.isPlaying {
                EqualiserBars(state: state, height: 18)
                    .accessibilityLabel("Playing")
            } else {
                Image(systemName: "pause.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(state.accent)
                    .accessibilityLabel("Paused")
            }
        }
        .frame(width: 36, height: 36)
    }

    /// Smart Stack / Apple Watch small-family layout.
    private var watchLayout: some View {
        HStack(spacing: 8) {
            ArtworkView(state: state, size: 32, cornerRadius: 7, glows: false)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.trackTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(state.artistName)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            EqualiserBars(state: state, barCount: 3, height: 14)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        if isStale { return "\(state.artistName) · not responding" }
        return state.artistName
    }
}

// MARK: - Dynamic Island expanded

private struct ExpandedLeading: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        ArtworkView(state: state, size: 40)
            .frame(width: 40, height: 40)
            .padding(.leading, 2)
    }
}

private struct ExpandedTrailing: View {
    let state: NowPlayingActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        Group {
            if isStale {
                Image(systemName: "wifi.exclamationmark")
                    .accessibilityLabel("Not responding")
            } else if state.isDJModeLive {
                DJBadge(compact: true)
            } else if state.isPlaying {
                EqualiserBars(state: state, barCount: 3, height: 14)
                    .accessibilityLabel("Playing")
            } else {
                Image(systemName: "pause.fill")
                    .accessibilityLabel("Paused")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(isStale ? 0.4 : 0.9))
        .padding(.trailing, 2)
        .frame(height: 40)
    }
}

private struct ExpandedCenter: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.trackTitle)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .contentTransition(.opacity)

            Text(state.artistName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

private struct ExpandedBottom: View {
    let state: NowPlayingActivityAttributes.ContentState
    let isStale: Bool

    private var hasWaveform: Bool { !state.waveformLevels.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasWaveform {
                WaveformTrack(state: state, height: 22)
            } else {
                LiveProgressBar(state: state, showsTimes: false)
            }

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                TransportControls(state: state, expanded: true)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .opacity(isStale ? 0.78 : 1)
    }
}

// MARK: - Dynamic Island compact

private struct CompactLeading: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        if state.isPlaying, state.timerRange != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ring
            }
        } else {
            ring
        }
    }

    private var ring: some View {
        ArtworkView(state: state, size: 22, cornerRadius: 7, glows: false)
            .frame(width: 22, height: 22)
            .padding(2)
            .background(
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 2)
            )
            .overlay {
                Circle()
                    .trim(from: 0, to: max(0.02, state.fraction))
                    .stroke(state.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
    }
}

private struct CompactTrailing: View {
    let state: NowPlayingActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .accessibilityLabel("Not responding")
        } else if state.isPlaying {
            EqualiserBars(state: state, barCount: 3, height: 14)
                .accessibilityLabel("Playing")
        } else {
            Image(systemName: "pause.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(state.accent)
                .accessibilityLabel("Paused")
        }
    }
}

// MARK: - Dynamic Island minimal

private struct MinimalGlyph: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        if state.isPlaying {
            EqualiserBars(state: state, barCount: 3, height: 12, barWidth: 2)
                .accessibilityLabel(state.isDJModeLive ? "Auto DJ is live" : "Now playing")
        } else {
            Image(systemName: "pause.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(state.accent)
                .accessibilityLabel("Paused")
        }
    }
}
