import SwiftUI

struct NowPlayingScrubberStyle: Equatable {
    var waveHeight: CGFloat = 36
    var pitch: CGFloat = 3.6
    var barWidth: CGFloat = 2.2
    var timesGap: CGFloat = 9
    var timeFont: Font = .caption.weight(.medium)

    static let phone = NowPlayingScrubberStyle()
    static let pad = NowPlayingScrubberStyle(waveHeight: 40, pitch: 4, barWidth: 2.4, timesGap: 10, timeFont: .footnote.weight(.medium))
}

enum NowPlayingWaveformMarks: Equatable {
    case none
    case segments
    case comments
}

struct NowPlayingScrubber: View {
    let timeline: NowPlayingTimeline
    let trackId: String?
    let tint: Color
    let onSeek: (TimeInterval) -> Void
    @ObservedObject var store: PhoneWaveformStore
    var style: NowPlayingScrubberStyle = .phone
    var marks: NowPlayingWaveformMarks = .none
    var showsBubble = true
    var showsCurrentEntry = false
    var onPinchIn: (() -> Void)?

    @ObservedObject private var setlists = SetlistIntelligenceStore.shared
    @ObservedObject private var trims = TrackTrimStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .caption) private var timeRowHeight: CGFloat = 16

    @State private var width: CGFloat = 0
    @State private var bars = WaveformBars.empty
    @State private var scrub: TimeInterval?
    @State private var scrubFeedback = 0

    private var duration: TimeInterval { max(timeline.anchor.duration, 1) }
    private var trim: TrackTrimTimeline {
        TrackTrimTimeline(range: trims.effectiveRange(for: trackId ?? "", duration: duration), duration: duration)
    }
    private var tracklist: Tracklist? { setlists.tracklist(for: trackId) }
    private var isScrubbing: Bool { scrub != nil }
    private var isLive: Bool { timeline.anchor.isAdvancing && scenePhase == .active }
    private var scrubScale: CGFloat { isScrubbing && !reduceMotion ? 1.32 : 1 }
    private var scrubGrowth: CGFloat { style.waveHeight * (scrubScale - 1) / 2 }

    private var progressInterval: TimeInterval {
        let pixels = max(1, Double(width * displayScale))
        let perPixel = duration / pixels
        return min(1, max(1.0 / 30, reduceMotion ? max(perPixel, 1) : perPixel))
    }

    var body: some View {
        VStack(spacing: 0) {
            waveform
            timeRow
                .padding(.top, style.timesGap)
        }
        .overlay { scrubberAccessibilityElement }
        .overlay(alignment: .topLeading) {
            if showsBubble, width > 0 {
                NowPlayingCommentBubble(
                    timeline: timeline,
                    store: store,
                    trackId: trackId,
                    width: width,
                    tint: tint,
                    isEnabled: isLive && !isScrubbing
                )
                .offset(y: style.waveHeight + 2)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: WaveformBars.Key(waveform: store.waveform, count: barCount)) {
            await rebuildBars()
        }
        .sensoryFeedback(.selection, trigger: scrubFeedback)
        .onChange(of: scrub) { _, value in
            if timeline.scrubPreview != value { timeline.scrubPreview = value }
        }
        .onDisappear {
            if timeline.scrubPreview != nil { timeline.scrubPreview = nil }
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["SOUNDING_TV_NP_SHOT"] == "scrub" else { return }
            try? await Task.sleep(for: .seconds(1.5))
            scrub = duration * 0.38
        }
        #endif
    }

    private var barCount: Int { max(20, Int(width / style.pitch)) }

    // MARK: - Waveform

    private var waveform: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                WaveformBarsLayer(bars: bars, style: style, color: .white.opacity(isScrubbing ? 0.32 : 0.26))
                WaveformBarsLayer(bars: bars, style: style, color: .white.opacity(0.95))
                    .mask(alignment: .leading) {
                        PlayedMask(
                            timeline: timeline,
                            width: width,
                            duration: duration,
                            scrub: scrub,
                            isLive: isLive,
                            interval: progressInterval
                        )
                    }
                WaveformMarksLayer(
                    marks: marks,
                    segments: tracklist?.entries.dropFirst().map(\.startSeconds) ?? [],
                    comments: marks == .comments ? store.comments.compactMap(\.timeInTrack) : [],
                    duration: duration,
                    height: style.waveHeight
                )
                .opacity(marks == .none ? 0 : 1)
                .animation(.easeInOut(duration: 0.5), value: marks)
            }
            .mask(alignment: .leading) { trimMask }
            .scaleEffect(x: 1, y: scrubScale, anchor: .center)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : NPMotion.spring, value: isScrubbing)

            if let scrub {
                Capsule()
                    .fill(.white)
                    .frame(width: 2, height: style.waveHeight + scrubGrowth * 2)
                    .offset(x: CGFloat(scrub / duration) * width - 1, y: -scrubGrowth)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if case .unavailable(let reason) = store.waveform, !reason.isEmpty {
                HStack(spacing: 10) {
                    Text("Couldn't Load Waveform")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(NPInk.secondary)
                    Button("Retry") { store.retry(trackId: trackId) }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.mini)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: style.waveHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            if let scrub {
                scrubBadge(scrub)
            }
        }
        .padding(.top, 14).padding(.bottom, 4)
        .contentShape(Rectangle())
        .padding(.top, -14).padding(.bottom, -4)
        .gesture(scrubGesture)
        .simultaneousGesture(
            MagnifyGesture().onEnded { value in
                if value.magnification > 1.15 { onPinchIn?() }
            }
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trimMask: some View {
        let trim = trim
        if trim.isTrimmed {
            HStack(spacing: 0) {
                Color.white.opacity(0.3)
                    .frame(width: width * CGFloat(trim.range.lowerBound / duration))
                Color.white
                Color.white.opacity(0.3)
                    .frame(width: width * CGFloat(max(0, duration - trim.range.upperBound) / duration))
            }
        } else {
            Color.white
        }
    }

    private func scrubBadge(_ position: TimeInterval) -> some View {
        let x = min(max(CGFloat(position / duration) * width, 26), max(26, width - 26))
        return Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: .bottom) {
                Text(scFormatTime(trim.elapsed(at: position)))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white, in: Capsule())
                    .fixedSize()
            }
            .offset(x: x, y: -16)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            .allowsHitTesting(false)
    }

    private var scrubberAccessibilityElement: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !isLive)) { context in
            let position = scrub ?? timeline.anchor.position(at: context.date)
            Color.clear
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(scFormatTime(trim.elapsed(at: position))) of \(scFormatTime(trim.length))")
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityAdjustableAction { direction in
                    let delta: TimeInterval = direction == .increment ? 10 : -10
                    onSeek(trim.clamped(timeline.anchor.position(at: .now) + delta))
                }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Time row

    private var timeRow: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !isLive || isScrubbing)) { context in
            let position = scrub ?? timeline.anchor.position(at: context.date)
            HStack(spacing: 12) {
                Text(scFormatTime(trim.elapsed(at: position)))
                    .frame(minWidth: 44, alignment: .leading)
                Text(midLabel(at: position))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .opacity(showsCurrentEntry ? 1 : 0)
                    .accessibilityHidden(!showsCurrentEntry)
                    .animation(.easeInOut(duration: 0.3), value: showsCurrentEntry)
                Text("−" + scFormatTime(trim.remaining(at: position)))
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .font(style.timeFont.monospacedDigit())
            .foregroundStyle(isScrubbing ? NPInk.primary : NPInk.secondary)
            .animation(.easeInOut(duration: 0.2), value: isScrubbing)
        }
        .frame(minHeight: timeRowHeight)
        .offset(y: scrubGrowth)
        .animation(NPMotion.spring, value: isScrubbing)
        .accessibilityHidden(true)
    }

    private func midLabel(at position: TimeInterval) -> String {
        guard showsCurrentEntry, let entry = tracklist?.currentEntry(at: position) else { return "" }
        return NowPlayingSegmentText.line(entry.segment)
    }

    // MARK: - Gestures

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                if scrub == nil { scrubFeedback += 1 }
                scrub = trim.clamped(Self.clamp(Double(value.location.x / width) * duration, to: duration))
            }
            .onEnded { value in
                guard width > 0 else {
                    scrub = nil
                    return
                }
                let target = trim.clamped(Self.clamp(Double(value.location.x / width) * duration, to: duration))
                onSeek(target)
                scrub = nil
            }
    }

    private static func clamp(_ value: TimeInterval, to duration: TimeInterval) -> TimeInterval {
        min(duration, max(0, value))
    }

    // MARK: - Precompute

    private func rebuildBars() async {
        let count = barCount
        guard let samples = store.waveform.samples, !samples.isEmpty, width > 0 else {
            bars = width > 0 ? .flat(count: count) : .empty
            return
        }
        let built = await Task.detached(priority: .userInitiated) {
            WaveformBars.build(samples: samples, count: count)
        }.value
        guard !Task.isCancelled else { return }
        bars = built
    }
}

private struct PlayedMask: View {
    let timeline: NowPlayingTimeline
    let width: CGFloat
    let duration: TimeInterval
    let scrub: TimeInterval?
    let isLive: Bool
    let interval: TimeInterval

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: !isLive || scrub != nil)) { context in
            let position = scrub ?? timeline.anchor.position(at: context.date)
            Rectangle()
                .frame(width: max(0, width * CGFloat(min(1, max(0, position / duration)))))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Bars

struct WaveformBars: Equatable, Sendable {
    let id: UUID
    let values: [Float]

    static let empty = WaveformBars(id: UUID(), values: [])
    static let barsPerTile = 64

    struct Key: Equatable {
        let waveform: PhoneWaveformState
        let count: Int
    }

    static func == (lhs: WaveformBars, rhs: WaveformBars) -> Bool { lhs.id == rhs.id }

    static func build(samples: [Float], count: Int) -> WaveformBars {
        guard count > 0, !samples.isEmpty else { return .empty }
        let shaped = SCWaveformSampler.visuallyNormalized(samples, floor: 0.10)
        return WaveformBars(id: UUID(), values: Waveform(samples: shaped).displayBars(count: count, contrast: 0.45))
    }

    static func flat(count: Int) -> WaveformBars {
        WaveformBars(id: UUID(), values: Array(repeating: 0, count: count))
    }

    var tileCount: Int { (values.count + Self.barsPerTile - 1) / Self.barsPerTile }
}

private struct WaveformBarsLayer: View {
    let bars: WaveformBars
    let style: NowPlayingScrubberStyle
    let color: Color

    var body: some View {
        let tileWidth = CGFloat(WaveformBars.barsPerTile) * style.pitch
        ZStack(alignment: .topLeading) {
            ForEach(0..<bars.tileCount, id: \.self) { index in
                WaveformTile(bars: bars, index: index, style: style, color: color)
                    .equatable()
                    .offset(x: CGFloat(index) * tileWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: style.waveHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct WaveformTile: View, Equatable {
    let bars: WaveformBars
    let index: Int
    let style: NowPlayingScrubberStyle
    let color: Color

    var body: some View {
        Canvas(rendersAsynchronously: false) { graphics, _ in
            let first = index * WaveformBars.barsPerTile
            let last = min(bars.values.count, first + WaveformBars.barsPerTile)
            guard first < last else { return }
            let height = style.waveHeight
            let radius = style.barWidth / 2
            var path = Path()
            for barIndex in first..<last {
                let value = CGFloat(max(0.1, bars.values[barIndex]))
                let barHeight = max(style.barWidth, value * height)
                let x = CGFloat(barIndex - first) * style.pitch + (style.pitch - style.barWidth) / 2
                path.addRoundedRect(
                    in: CGRect(x: x, y: (height - barHeight) / 2, width: style.barWidth, height: barHeight),
                    cornerSize: CGSize(width: radius, height: radius)
                )
            }
            graphics.fill(path, with: .color(color))
        }
        .frame(width: CGFloat(WaveformBars.barsPerTile) * style.pitch, height: style.waveHeight)
    }
}

private struct WaveformMarksLayer: View, Equatable {
    let marks: NowPlayingWaveformMarks
    let segments: [TimeInterval]
    let comments: [TimeInterval]
    let duration: TimeInterval
    let height: CGFloat

    var body: some View {
        Canvas { graphics, size in
            switch marks {
            case .none:
                break
            case .segments:
                for start in segments {
                    let x = CGFloat(start / duration) * size.width
                    graphics.fill(
                        Path(CGRect(x: x - 0.5, y: -5, width: 1, height: height + 10)),
                        with: .color(.white.opacity(0.38))
                    )
                }
            case .comments:
                for time in comments {
                    let x = CGFloat(time / duration) * size.width
                    graphics.fill(
                        Path(roundedRect: CGRect(x: x - 1, y: height + 6, width: 2, height: 2), cornerRadius: 1),
                        with: .color(.white.opacity(0.42))
                    )
                }
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

// MARK: - Comment bubble

private struct NowPlayingCommentBubble: View {
    let timeline: NowPlayingTimeline
    @ObservedObject var store: PhoneWaveformStore
    let trackId: String?
    let width: CGFloat
    let tint: Color
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var timed = TimedComments.empty
    @State private var shown: TimedComments.Item?
    @State private var lastShownAt = Date.distantPast
    @State private var bubbleWidth: CGFloat = 0

    private static let minimumGap: TimeInterval = 7
    private static let visibleFor: TimeInterval = 3.6

    private var inset: CGFloat { (width * 0.12).rounded() }
    private var maxBubbleWidth: CGFloat { max(80, min(width - inset * 2, 300)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let shown {
                bubble(shown)
                    .id(shown.id)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.94)))
            }
        }
        .frame(width: width, alignment: .topLeading)
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : NPMotion.spring, value: shown?.id)
        .allowsHitTesting(false)
        .task(id: TimedComments.Key(store.comments)) {
            timed = TimedComments(store.comments)
        }
        .task(id: Key(trackId: trackId, enabled: isEnabled, count: timed.items.count, anchor: timeline.anchor)) {
            await watch()
        }
        .onChange(of: trackId) { _, _ in shown = nil }
    }

    private struct Key: Equatable {
        let trackId: String?
        let enabled: Bool
        let count: Int
        let anchor: PlaybackAnchor
    }

    private func bubble(_ item: TimedComments.Item) -> some View {
        let x = CGFloat(item.time / max(timeline.anchor.duration, 1)) * width
        let half = bubbleWidth / 2
        let center = min(max(x, inset + half), max(inset + half, width - inset - half))
        return HStack(spacing: 7) {
            NowPlayingAvatar(url: item.comment.user.avatarURL, name: item.comment.user.displayName, size: 20)
            Text(item.comment.body)
                .font(.footnote)
                .foregroundStyle(NPInk.primary)
                .lineLimit(1)
        }
        .padding(.leading, 5)
        .padding(.trailing, 11)
        .padding(.vertical, 5)
        .background(.black.opacity(contrast == .increased ? 0.7 : 0.38), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(contrast == .increased ? 0.4 : 0.14), lineWidth: 1))
        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { bubbleWidth = $0 }
        .offset(x: center - half)
        .opacity(bubbleWidth > 0 ? 1 : 0)
        .accessibilityElement(children: .combine)
    }

    private func watch() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_NP_SHOT"] == "bubble", shown == nil {
            let position = timeline.anchor.position(at: .now)
            if let item = timed.items.min(by: { abs($0.time - position) < abs($1.time - position) }) {
                shown = item
                lastShownAt = .distantFuture
                return
            }
        }
        #endif
        guard isEnabled, !timed.items.isEmpty else {
            if !isEnabled { shown = nil }
            return
        }
        var previous = timeline.anchor.position(at: .now)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let now = Date.now
            let position = timeline.anchor.position(at: now)
            if let shown, now.timeIntervalSince(lastShownAt) >= Self.visibleFor {
                if self.shown?.id == shown.id { self.shown = nil }
            }
            if position - previous < 2,
               now.timeIntervalSince(lastShownAt) >= Self.minimumGap,
               let item = timed.latest(after: previous, through: position + 0.5) {
                bubbleWidth = 0
                shown = item
                lastShownAt = now
            }
            previous = position
        }
    }
}
