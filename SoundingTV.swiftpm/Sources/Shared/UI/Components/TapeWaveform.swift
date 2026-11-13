#if os(iOS) || os(macOS)
import SwiftUI
import QuartzCore

// MARK: - Peaks

final class TapeWaveformTile: @unchecked Sendable {
    let path: Path

    init(path: Path) { self.path = path }
}

struct TapeWaveformPeaks: Sendable {
    struct Level: Sendable {
        let binSeconds: Double
        let values: [Float]
        let tiles: [TapeWaveformTile]
    }

    let id: UUID
    let duration: TimeInterval
    let levels: [Level]

    static let barsPerTile = 128
    static let barFraction: CGFloat = 0.6
    static let finestBins = 16_384

    nonisolated static func build(samples: [Float], duration: TimeInterval) -> TapeWaveformPeaks? {
        guard duration > 0, samples.count > 1 else { return nil }
        let bin = max(0.25, duration / Double(finestBins))
        let count = max(1, Int((duration / bin).rounded(.up)))
        var base = [Float](repeating: 0, count: count)
        let perBin = Double(samples.count) / Double(count)
        if perBin >= 1 {
            for index in 0..<count {
                let lower = Int(Double(index) * perBin)
                let upper = min(samples.count, max(lower + 1, Int(Double(index + 1) * perBin)))
                var peak: Float = 0
                var sum: Float = 0
                for sample in samples[lower..<upper] {
                    peak = max(peak, sample)
                    sum += sample
                }
                base[index] = peak * 0.6 + sum / Float(upper - lower) * 0.4
            }
        } else {
            let last = samples.count - 1
            let scale = Double(last) / Double(max(1, count - 1))
            for index in 0..<count {
                let point = Double(index) * scale
                let lower = min(last, Int(point))
                let upper = min(last, lower + 1)
                let fraction = Float(point - Double(lower))
                base[index] = samples[lower] + (samples[upper] - samples[lower]) * fraction
            }
        }
        for index in base.indices { base[index] = min(1, max(0.06, base[index])) }

        var levels: [Level] = []
        var values = base
        var seconds = bin
        while true {
            levels.append(Level(binSeconds: seconds, values: values, tiles: tiles(for: values)))
            guard values.count > 48 else { break }
            var next = [Float](repeating: 0, count: (values.count + 1) / 2)
            for index in next.indices {
                let a = values[index * 2]
                let b = index * 2 + 1 < values.count ? values[index * 2 + 1] : a
                next[index] = max(a, b) * 0.6 + (a + b) * 0.2
            }
            values = next
            seconds *= 2
        }
        return TapeWaveformPeaks(id: UUID(), duration: duration, levels: levels)
    }

    nonisolated private static func tiles(for values: [Float]) -> [TapeWaveformTile] {
        let tileCount = (values.count + barsPerTile - 1) / barsPerTile
        let inset = (1 - barFraction) / 2
        return (0..<tileCount).map { tile in
            var path = Path()
            let first = tile * barsPerTile
            let last = min(values.count, first + barsPerTile)
            for index in first..<last {
                let height = CGFloat(values[index])
                path.addRect(CGRect(x: CGFloat(index - first) + inset, y: -height / 2, width: barFraction, height: height))
            }
            return TapeWaveformTile(path: path)
        }
    }

    func level(forBarSeconds seconds: Double) -> Level {
        guard let finest = levels.first?.binSeconds, seconds > finest else { return levels[0] }
        let index = Int((log2(seconds / finest)).rounded())
        return levels[min(levels.count - 1, max(0, index))]
    }

    func overview(count: Int) -> [Float] {
        guard count > 0, let level = levels.last(where: { $0.values.count >= count }) ?? levels.first else { return [] }
        let values = level.values
        let step = Double(values.count) / Double(count)
        return (0..<count).map { index in
            let lower = Int(Double(index) * step)
            let upper = min(values.count, max(lower + 1, Int(Double(index + 1) * step)))
            let slice = values[lower..<upper]
            let mean = slice.reduce(0, +) / Float(slice.count)
            return pow(mean, 1.6)
        }
    }
}

// MARK: - Rendering

struct TapeViewport: Equatable {
    var start: TimeInterval
    var pointsPerSecond: Double
    var played: TimeInterval
    var trim: ClosedRange<TimeInterval>

    func x(_ time: TimeInterval) -> CGFloat { CGFloat((time - start) * pointsPerSecond) }
}

struct TapeWaveformPalette: Equatable {
    var played: Color = .white.opacity(0.95)
    var unplayed: Color = .white.opacity(0.32)
    var trimmed: Color = .white.opacity(0.12)
    var targetPitch: CGFloat = 3.6
}

protocol TapeWaveformRendering: View {
    init(peaks: TapeWaveformPeaks?, viewport: TapeViewport, palette: TapeWaveformPalette)
}

typealias TapeWaveformRenderer = TapeCanvasWaveform

@MainActor
enum TapeRendering {
    static let prefersMetal: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_TAPE_METAL"] == "1" && MetalWaveformView.isSupported
        #else
        false
        #endif
    }()
}

struct TapeCanvasWaveform: TapeWaveformRendering {
    let peaks: TapeWaveformPeaks?
    let viewport: TapeViewport
    let palette: TapeWaveformPalette

    init(peaks: TapeWaveformPeaks?, viewport: TapeViewport, palette: TapeWaveformPalette) {
        self.peaks = peaks
        self.viewport = viewport
        self.palette = palette
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            #if DEBUG
            let began = TapeFrameProbe.isEnabled ? CACurrentMediaTime() : 0
            #endif
            Self.draw(peaks: peaks, viewport: viewport, palette: palette, in: &context, size: size)
            #if DEBUG
            if TapeFrameProbe.isEnabled { TapeFrameProbe.record(began: began) }
            #endif
        }
        .allowsHitTesting(false)
    }

    static func draw(peaks: TapeWaveformPeaks?, viewport: TapeViewport, palette: TapeWaveformPalette, in context: inout GraphicsContext, size: CGSize) {
        let pps = viewport.pointsPerSecond
        guard pps > 0, size.width > 0 else { return }
        guard let peaks, !peaks.levels.isEmpty else {
            context.fill(Path(CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)), with: .color(palette.unplayed))
            return
        }
        let level = peaks.level(forBarSeconds: Double(palette.targetPitch) / pps)
        let bin = level.binSeconds
        let pitch = CGFloat(bin * pps)
        let firstBar = max(0, Int((viewport.start / bin).rounded(.down)))
        let lastBar = min(level.values.count, Int(((viewport.start + Double(size.width) / pps) / bin).rounded(.up)) + 1)
        guard firstBar < lastBar else { return }
        let perTile = TapeWaveformPeaks.barsPerTile
        let firstTile = firstBar / perTile
        let lastTile = min(level.tiles.count - 1, (lastBar - 1) / perTile)
        guard firstTile <= lastTile else { return }

        let trimLow = viewport.x(viewport.trim.lowerBound)
        let trimHigh = viewport.x(viewport.trim.upperBound)
        let played = min(max(viewport.x(viewport.played), trimLow), trimHigh)
        let regions: [(CGFloat, CGFloat, Color)] = [
            (-.infinity, trimLow, palette.trimmed),
            (trimLow, played, palette.played),
            (played, trimHigh, palette.unplayed),
            (trimHigh, .infinity, palette.trimmed),
        ]
        let middle = size.height / 2
        for (low, high, color) in regions {
            let left = max(0, low)
            let right = min(size.width, high)
            guard right > left else { continue }
            var region = context
            region.clip(to: Path(CGRect(x: left, y: 0, width: right - left, height: size.height)))
            for tile in firstTile...lastTile {
                let tileStart = Double(tile * perTile) * bin
                var drawing = region
                drawing.translateBy(x: viewport.x(tileStart), y: middle)
                drawing.scaleBy(x: pitch, y: size.height)
                drawing.fill(level.tiles[tile].path, with: .color(color))
            }
        }
    }
}

struct TapeMetalWaveform: TapeWaveformRendering {
    let peaks: TapeWaveformPeaks?
    let viewport: TapeViewport
    let palette: TapeWaveformPalette

    init(peaks: TapeWaveformPeaks?, viewport: TapeViewport, palette: TapeWaveformPalette) {
        self.peaks = peaks
        self.viewport = viewport
        self.palette = palette
    }

    var body: some View {
        GeometryReader { proxy in
            let span = Double(proxy.size.width) / max(viewport.pointsPerSecond, 1e-6)
            MetalWaveformView(
                source: source,
                timeline: .range(viewport.start...(viewport.start + span), playhead: viewport.played),
                overlays: trimOverlays,
                style: style
            )
        }
        .allowsHitTesting(false)
    }

    private var source: MetalWaveformSource? {
        guard let peaks, let finest = peaks.levels.first else { return nil }
        return MetalWaveformSourceCache.shared.envelope(id: peaks.id.uuidString, samples: finest.values, duration: peaks.duration)
    }

    private var style: MetalWaveformStyle {
        var style = MetalWaveformStyle.mono(SIMD4<Float>(palette.played))
        style.unplayedTint = SIMD4(1, 1, 1, 0.34)
        style.playheadColor = SIMD4(0, 0, 0, 0)
        return style
    }

    private var trimOverlays: [MetalWaveformOverlay] {
        guard let peaks else { return [] }
        var overlays: [MetalWaveformOverlay] = []
        if viewport.trim.lowerBound > 0 {
            overlays.append(MetalWaveformOverlay(id: "trim.start", kind: .region(0...viewport.trim.lowerBound), color: SIMD4(0, 0, 0, 0.55)))
        }
        if viewport.trim.upperBound < peaks.duration {
            overlays.append(MetalWaveformOverlay(id: "trim.end", kind: .region(viewport.trim.upperBound...peaks.duration), color: SIMD4(0, 0, 0, 0.55)))
        }
        return overlays
    }
}

#if DEBUG
enum TapeFrameProbe {
    nonisolated(unsafe) static let isEnabled = ProcessInfo.processInfo.environment["SOUNDING_TV_TAPE_PROBE"] == "1"
    nonisolated(unsafe) private static var draws = 0
    nonisolated(unsafe) private static var total: Double = 0
    nonisolated(unsafe) private static var worst: Double = 0
    nonisolated(unsafe) private static var firstAt: Double = 0
    nonisolated(unsafe) private static var gapWorst: Double = 0
    nonisolated(unsafe) private static var lastAt: Double = 0

    static func record(began: Double) {
        let now = CACurrentMediaTime()
        let cost = now - began
        if draws == 0 { firstAt = now }
        if lastAt > 0, now - lastAt < 0.1 { gapWorst = max(gapWorst, now - lastAt) }
        lastAt = now
        draws += 1
        total += cost
        worst = max(worst, cost)
        guard draws == 240 else { return }
        let span = max(now - firstAt, 0.001)
        print(String(format: "tape-probe draws=240 avgDraw=%.3fms worstDraw=%.3fms rate=%.0fHz worstGap=%.1fms", total / 240 * 1000, worst * 1000, 239 / span, gapWorst * 1000))
        draws = 0
        total = 0
        worst = 0
        gapWorst = 0
    }
}
#endif

// MARK: - Model

struct TapeClock: Equatable {
    var position: TimeInterval
    var date: Date
    var rate: Double
    var duration: TimeInterval

    var isAdvancing: Bool { rate > 0 }

    func position(at date: Date) -> TimeInterval {
        let raw = max(0, position + rate * max(0, date.timeIntervalSince(self.date)))
        return duration > 0 ? min(duration, raw) : raw
    }
}

struct TapeEntry: Identifiable, Equatable {
    let id: String
    let start: TimeInterval
    let title: String
    let artist: String?

    private static let placeholders: Set<String> = ["id", "unidentified", "unknown", "?", "??", "???"]

    static func parse(id: String, start: TimeInterval, title: String, artist: String?, isUnknown: Bool) -> TapeEntry {
        var title = title.trimmingCharacters(in: .whitespaces)
        var artist = artist?.trimmingCharacters(in: .whitespaces)
        if artist?.isEmpty ?? true {
            artist = nil
            for separator in [" — ", " – ", " - "] where title.contains(separator) {
                let pieces = title.components(separatedBy: separator)
                artist = pieces[0]
                title = pieces.dropFirst().joined(separator: separator)
                break
            }
        }
        let unknown = isUnknown || (placeholders.contains(title.lowercased()) && placeholders.contains(artist?.lowercased() ?? "id"))
        return unknown ? TapeEntry(id: id, start: start, title: "ID", artist: nil) : TapeEntry(id: id, start: start, title: title, artist: artist)
    }
}

struct TapeComment: Identifiable, Equatable {
    let id: String
    let time: TimeInterval
    let body: String
    let avatarURL: URL?
    let name: String
}

struct TapeBleed: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}

struct TapeScrubberStyle: Equatable {
    var waveHeight: CGFloat = 36
    var labelHeight: CGFloat = 18
    var labelGap: CGFloat = 6
    var avatarSize: CGFloat = 20
    var avatarGap: CGFloat = 6
    var timesGap: CGFloat = 6
    var timesHeight: CGFloat = 16
    var labelFont: Font = .footnote
    var timeFont: Font = .caption.weight(.medium)
    var pitch: CGFloat = 3.6
    var timeMinWidth: CGFloat = 44
    var markerSize: CGFloat = 10

    var height: CGFloat { labelHeight + labelGap + waveHeight + avatarGap + avatarSize + 4 + timesGap + timesHeight }
    var compactHeight: CGFloat { waveHeight + timesGap + timesHeight }
}

private struct TapeGlide: Equatable {
    let from: Double
    let to: Double
    let start: Date
    let duration: Double

    func value(at date: Date) -> Double {
        let progress = min(1, max(0, date.timeIntervalSince(start) / duration))
        let eased = 1 - pow(1 - progress, 3)
        return from + (to - from) * eased
    }
}

enum TapeTime {
    static func string(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func spoken(_ seconds: TimeInterval) -> String { string(seconds) }
}

// MARK: - Scrubber

struct TapeScrubber<Avatar: View>: View {
    let clock: TapeClock
    let isActive: Bool
    let peaks: TapeWaveformPeaks?
    let trim: TrackTrimTimeline
    let entries: [TapeEntry]
    let comments: [TapeComment]
    var style = TapeScrubberStyle()
    var bleed = TapeBleed()
    var compact = false
    var initialSpan: TimeInterval = 240
    var bubbleTint: Color = .white
    var startsScrubbing = false
    var showsBubbleOnAppear = false
    let onSeek: (TimeInterval) -> Void
    var onScrubChange: (TimeInterval?) -> Void = { _ in }
    var onZoomOutToFit: (() -> Void)?
    @ViewBuilder let avatar: (TapeComment, CGFloat) -> Avatar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    @State private var width: CGFloat = 0
    @State private var span: TimeInterval?
    @State private var spanGlide: TapeGlide?
    @State private var pinchBase: TimeInterval?
    @State private var scrub: TimeInterval?
    @State private var dragOrigin: TimeInterval?
    @State private var glide: TapeGlide?
    @State private var snapped: String?
    @State private var snapTick = 0
    @State private var grabTick = 0
    @State private var shown: TapeComment?
    @State private var lastShownAt = Date.distantPast
    @State private var bubbleWidth: CGFloat = 0
    @State private var mapWidth: CGFloat = 0
    @State private var hover: CGPoint?

    private static var visibleFor: TimeInterval { 3.6 }
    private static var minimumGap: TimeInterval { 7 }

    private var duration: TimeInterval { max(clock.duration, 1) }
    private var minSpan: TimeInterval { min(60, duration) }
    private var maxSpan: TimeInterval { min(900, duration) }
    private var settledSpan: TimeInterval { min(maxSpan, max(minSpan, span ?? initialSpan)) }
    private var isScrubbing: Bool { scrub != nil || glide != nil }
    private var growth: CGFloat { isScrubbing && !reduceMotion ? style.waveHeight * 0.15 : 0 }

    private struct Frame {
        let start: TimeInterval
        let pps: Double
        let playheadX: CGFloat
        let position: TimeInterval
        let span: TimeInterval
        let fits: Bool

        func x(_ time: TimeInterval) -> CGFloat { CGFloat((time - start) * pps) }
    }

    private func currentSpan(at date: Date) -> TimeInterval { spanGlide?.value(at: date) ?? settledSpan }

    private func position(at date: Date) -> TimeInterval {
        if let glide { return glide.value(at: date) }
        return scrub ?? clock.position(at: date)
    }

    private func frame(at date: Date) -> Frame {
        let w = Double(max(width, 1))
        let span = currentSpan(at: date)
        let position = position(at: date)
        if span >= duration - 0.5 {
            let pps = w / duration
            return Frame(start: 0, pps: pps, playheadX: CGFloat(position * pps), position: position, span: duration, fits: true)
        }
        let pps = w / span
        var anchor = position
        if reduceMotion, !isScrubbing { anchor = (position / 60).rounded(.down) * 60 + 30 }
        let start = anchor - w / 2 / pps
        return Frame(start: start, pps: pps, playheadX: CGFloat((position - start) * pps), position: position, span: span, fits: false)
    }

    private var needsTicks: Bool {
        (clock.isAdvancing && isActive) || isScrubbing || spanGlide != nil || pinchBase != nil
    }

    private var tickInterval: Double? {
        #if DEBUG
        if TapeFrameProbe.isEnabled { return nil }
        #endif
        if isScrubbing || spanGlide != nil || pinchBase != nil { return nil }
        if reduceMotion { return 1 }
        let pixels = Double(max(width, 1) * displayScale)
        return min(1, max(1.0 / 120, settledSpan / pixels))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: tickInterval, paused: !needsTicks)) { context in
            content(frame(at: context.date), audio: clock.position(at: context.date))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard !compact, !comments.isEmpty else { return }
            let top = style.labelHeight + style.labelGap + style.waveHeight + style.avatarGap
            switch phase {
            case .active(let point) where point.y >= top - 6 && point.y <= top + style.avatarSize + 10:
                hover = point
            default:
                if hover != nil { hover = nil }
            }
        }
        .overlay { accessibilityElement }
        .sensoryFeedback(.selection, trigger: snapTick)
        .sensoryFeedback(.selection, trigger: grabTick)
        .onChange(of: scrub) { _, value in onScrubChange(value) }
        .task(id: glide) { await finishGlide() }
        .task(id: spanGlide) { await finishSpanGlide() }
        .task(id: CommentWatch(count: comments.count, enabled: commentsEnabled, clock: clock)) { await watchComments() }
        .task(id: comments.count) {
            guard showsBubbleOnAppear, shown == nil, !comments.isEmpty else { return }
            try? await Task.sleep(for: .seconds(0.6))
            let position = clock.position(at: .now)
            shown = comments.filter { $0.time > position }.min { $0.time < $1.time }
            lastShownAt = .distantFuture
        }
        .task {
            if startsScrubbing {
                try? await Task.sleep(for: .seconds(1.2))
                scrub = trim.clamped(clock.position(at: .now) + 78)
            }
        }
    }

    // MARK: Layout

    private func content(_ f: Frame, audio: TimeInterval) -> some View {
        VStack(spacing: 0) {
            if !compact {
                labelRow(f)
                    .frame(height: style.labelHeight)
                    .padding(.bottom, style.labelGap)
                    .offset(y: -growth)
            }
            wave(f)
                .frame(height: style.waveHeight)
            if !compact {
                avatarRow(f)
                    .frame(height: style.avatarSize + 4)
                    .padding(.top, style.avatarGap)
                    .offset(y: growth)
            }
            timeRow(f, audio: audio)
                .frame(height: style.timesHeight)
                .padding(.top, style.timesGap)
                .offset(y: growth)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35), value: isScrubbing)
    }

    private func wave(_ f: Frame) -> some View {
        let leading = f.fits ? 0 : bleed.leading
        let trailing = f.fits ? 0 : bleed.trailing
        let viewport = TapeViewport(
            start: f.start - Double(leading) / f.pps,
            pointsPerSecond: f.pps,
            played: f.position,
            trim: trim.range
        )
        return ZStack(alignment: .topLeading) {
            renderer(viewport)
                .frame(width: width + leading + trailing, height: style.waveHeight)
                .mask { edgeFade(enabled: !f.fits, leading: leading, trailing: trailing) }
                .scaleEffect(x: 1, y: isScrubbing && !reduceMotion ? 1.3 : 1, anchor: .center)
                .offset(x: -leading)
            marks(f, leading: leading, trailing: trailing)
        }
        .frame(width: width, height: style.waveHeight, alignment: .topLeading)
        .contentShape(Rectangle().inset(by: -14))
        .gesture(dragGesture(f))
        .simultaneousGesture(pinchGesture)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func renderer(_ viewport: TapeViewport) -> some View {
        let palette = TapeWaveformPalette(targetPitch: style.pitch)
        if TapeRendering.prefersMetal {
            TapeMetalWaveform(peaks: peaks, viewport: viewport, palette: palette)
        } else {
            TapeWaveformRenderer(peaks: peaks, viewport: viewport, palette: palette)
        }
    }

    private func edgeFade(enabled: Bool, leading: CGFloat, trailing: CGFloat) -> some View {
        let total = max(1, width + leading + trailing)
        let fade = min(0.12, 28 / total)
        return LinearGradient(
            stops: enabled
                ? [.init(color: .clear, location: 0), .init(color: .black, location: fade), .init(color: .black, location: 1 - fade), .init(color: .clear, location: 1)]
                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func marks(_ f: Frame, leading: CGFloat, trailing: CGFloat) -> some View {
        let above = compact ? 0 : style.labelHeight + style.labelGap + growth
        let below = growth
        let lines = boundaryXs(f, from: -leading, to: width + trailing)
        let showsPlayhead = !f.fits || isScrubbing
        return Canvas(rendersAsynchronously: false) { context, size in
            for x in lines {
                context.fill(Path(CGRect(x: x + leading - 0.5, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.32)))
            }
            if showsPlayhead {
                let top = isScrubbing ? above * 0.35 : max(0, above - 6)
                context.fill(Path(roundedRect: CGRect(x: f.playheadX + leading - 1, y: top, width: 2, height: size.height - top), cornerRadius: 1), with: .color(.white))
            }
        }
        .frame(width: width + leading + trailing, height: style.waveHeight + above + below)
        .offset(x: -leading, y: -above)
        .allowsHitTesting(false)
    }

    private func boundaryXs(_ f: Frame, from low: CGFloat, to high: CGFloat) -> [CGFloat] {
        guard !entries.isEmpty else { return [] }
        let first = entryIndex(atOrAfter: f.start + Double(low) / f.pps)
        var xs: [CGFloat] = []
        var index = first
        while index < entries.count {
            let x = f.x(entries[index].start)
            if x > high { break }
            if entries[index].start > 0.5, x >= low { xs.append(x) }
            index += 1
        }
        return xs
    }

    private func entryIndex(atOrAfter time: TimeInterval) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].start < time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func currentEntryIndex(at time: TimeInterval) -> Int? {
        let index = entryIndex(atOrAfter: time + 0.001) - 1
        return index >= 0 ? index : (entries.isEmpty ? nil : 0)
    }

    // MARK: Labels

    private struct LabelSlot: Identifiable {
        let id: String
        let entry: TapeEntry
        let x: CGFloat
        let width: CGFloat
    }

    private func labelSlots(_ f: Frame) -> [LabelSlot] {
        guard !entries.isEmpty, width > 0 else { return [] }
        let startIndex = currentEntryIndex(at: f.start) ?? 0
        var slots: [LabelSlot] = []
        var index = startIndex
        while index < entries.count {
            let entry = entries[index]
            let boundary = entry.start > 0.5 ? f.x(entry.start) : -.infinity
            if boundary > width { break }
            let nextBoundary = index + 1 < entries.count ? f.x(entries[index + 1].start) : .infinity
            let x = max(0, boundary + 6)
            let available = min(width, nextBoundary - 8) - x
            var slotX = x
            var slotWidth = available
            if isScrubbing {
                let half = max(bubbleWidth, 60) / 2
                let bubbleLeft = min(max(f.playheadX, half), max(half, width - half)) - half
                let bubbleRight = bubbleLeft + half * 2
                if slotX >= bubbleLeft - 4, slotX < bubbleRight + 8 {
                    slotWidth -= bubbleRight + 8 - slotX
                    slotX = bubbleRight + 8
                } else if slotX < bubbleLeft, slotX + slotWidth > bubbleLeft - 8 {
                    slotWidth = bubbleLeft - 8 - slotX
                }
            }
            if slotWidth > 18 {
                slots.append(LabelSlot(id: entry.id, entry: entry, x: slotX, width: slotWidth))
            }
            index += 1
        }
        return slots
    }

    private func labelRow(_ f: Frame) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(labelSlots(f)) { slot in
                entryLabel(slot.entry)
                    .frame(maxWidth: slot.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: slot.x)
            }
            if isScrubbing {
                timeBubble(f)
            }
        }
        .frame(width: width, height: style.labelHeight, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }

    private func entryLabel(_ entry: TapeEntry) -> some View {
        let title = Text(entry.title).fontWeight(.semibold).foregroundStyle(.white.opacity(0.95))
        let artist = entry.artist.map { Text(" · \($0)").foregroundStyle(.white.opacity(0.6)) }
        return Text("\(title)\(artist ?? Text(""))")
            .font(style.labelFont)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func timeBubble(_ f: Frame) -> some View {
        let half = max(bubbleWidth, 60) / 2
        let x = min(max(f.playheadX, half), max(half, width - half))
        let solid = reduceTransparency || contrast == .increased
        return Text(TapeTime.string(trim.elapsed(at: f.position)))
            .font(style.labelFont.weight(.semibold).monospacedDigit())
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                if solid {
                    Capsule().fill(.white)
                } else {
                    Capsule().fill(.clear).glassEffect(.regular.tint(.white), in: .capsule)
                }
            }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { bubbleWidth = $0 }
            .offset(x: x - half, y: 4)
            .transition(.opacity)
    }

    // MARK: Comments

    private struct CommentMarker: Identifiable {
        let comments: [TapeComment]
        let x: CGFloat
        var id: String { comments[0].id }
    }

    private struct CommentMarkers {
        var items: [CommentMarker] = []
        var reach: CGFloat?
    }

    private struct CommentFocus {
        let comment: TapeComment
        let x: CGFloat
        let others: Int
    }

    private var markerPitch: CGFloat { style.markerSize * 2.2 }

    private var markerCap: Int { max(6, Int(width / max(1, style.markerSize * 4))) }

    private func commentIndex(atOrAfter time: TimeInterval) -> Int {
        var lower = 0
        var upper = comments.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if comments[mid].time < time { lower = mid + 1 } else { upper = mid }
        }
        return lower
    }

    private func commentMarkers(_ f: Frame) -> CommentMarkers {
        guard !comments.isEmpty, width > 0, f.pps > 0 else { return CommentMarkers() }
        let leading = f.fits ? 0 : bleed.leading
        let trailing = f.fits ? 0 : bleed.trailing
        let bucket = Double(markerPitch) / f.pps
        let low = max(0, f.start - Double(leading) / f.pps - bucket)
        let high = f.start + Double(width + trailing) / f.pps + bucket
        var markers: [CommentMarker] = []
        var group: [TapeComment] = []
        var key = Int.min
        var index = commentIndex(atOrAfter: low)
        func flush() {
            guard !group.isEmpty else { return }
            let centre = (Double(key) + 0.5) * bucket
            let mean = group.reduce(0) { $0 + $1.time } / Double(group.count)
            let time = min(max(mean, centre - bucket * 0.1), centre + bucket * 0.1)
            markers.append(CommentMarker(comments: group, x: f.x(time)))
            group = []
        }
        while index < comments.count, comments[index].time <= high {
            let k = Int((max(0, comments[index].time) / bucket).rounded(.down))
            if k != key {
                flush()
                key = k
            }
            group.append(comments[index])
            index += 1
        }
        flush()
        guard markers.count > markerCap else { return CommentMarkers(items: markers) }
        let nearest = markers.sorted { abs($0.x - f.playheadX) < abs($1.x - f.playheadX) }.prefix(markerCap)
        let kept = Set(nearest.map(\.id))
        return CommentMarkers(
            items: markers.filter { kept.contains($0.id) },
            reach: nearest.last.map { abs($0.x - f.playheadX) }
        )
    }

    private func hoverFocus(_ markers: [CommentMarker], f: Frame) -> CommentFocus? {
        guard let hover, !compact, !isScrubbing, f.pps > 0 else { return nil }
        let top = style.labelHeight + style.labelGap + style.waveHeight + style.avatarGap
        guard hover.y >= top - 6, hover.y <= top + style.avatarSize + 10 else { return nil }
        guard let nearest = markers.min(by: { abs($0.x - hover.x) < abs($1.x - hover.x) }),
              abs(nearest.x - hover.x) <= markerPitch / 2 + 2 else { return nil }
        let time = f.start + Double(hover.x) / f.pps
        let comment = nearest.comments.min { abs($0.time - time) < abs($1.time - time) } ?? nearest.comments[0]
        return CommentFocus(comment: comment, x: nearest.x, others: nearest.comments.count - 1)
    }

    private func playbackFocus(_ markers: [CommentMarker], f: Frame) -> CommentFocus? {
        guard let shown else { return nil }
        let marker = markers.first { $0.comments.contains { $0.id == shown.id } }
        return CommentFocus(comment: shown, x: marker?.x ?? f.x(shown.time), others: 0)
    }

    private func avatarRow(_ f: Frame) -> some View {
        let leading = f.fits ? 0 : bleed.leading
        let trailing = f.fits ? 0 : bleed.trailing
        let markers = commentMarkers(f)
        let focus = hoverFocus(markers.items, f: f) ?? playbackFocus(markers.items, f: f)
        let focusID = focus?.comment.id
        return ZStack(alignment: .topLeading) {
            ForEach(markers.items) { marker in
                let hidden = focusID.map { id in marker.comments.contains { $0.id == id } } ?? false
                markerView(marker)
                    .opacity(hidden ? 0 : markerOpacity(marker.x, f: f, reach: markers.reach, leading: leading, trailing: trailing))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hidden)
                    .frame(width: markerPitch, height: style.markerSize + 2)
                    .offset(x: marker.x - markerPitch / 2, y: 2)
            }
            ZStack(alignment: .topLeading) {
                if let focus {
                    commentBubble(focus, leading: leading, trailing: trailing)
                        .id(focus.comment.id)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.3, anchor: .leading).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3), value: focusID)
        }
        .frame(width: width, height: style.avatarSize + 4, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func markerView(_ marker: CommentMarker) -> some View {
        let size = style.markerSize
        let strong = contrast == .increased
        if marker.comments.count == 1 {
            avatar(marker.comments[0], size)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(strong ? 0.6 : 0.18), lineWidth: 0.5))
                .opacity(strong ? 1 : 0.85)
        } else {
            Text(marker.comments.count > 99 ? "99+" : "\(marker.comments.count)")
                .font(.system(size: max(7, size * 0.62), weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(strong ? 0.9 : 0.62))
                .lineLimit(1)
                .padding(.horizontal, size * 0.22)
                .frame(minWidth: size, minHeight: size)
                .background(.white.opacity(strong ? 0.3 : 0.1), in: Capsule())
                .fixedSize()
        }
    }

    private func markerOpacity(_ x: CGFloat, f: Frame, reach: CGFloat?, leading: CGFloat, trailing: CGFloat) -> Double {
        let edge = edgeOpacity(x, leading: leading, trailing: trailing)
        let distance = abs(x - f.playheadX)
        let span = max(reach ?? max(width - f.playheadX, f.playheadX), 1)
        let near = 0.5 + 0.5 * Double(max(0, 1 - distance / span))
        let fade = reach.map { Double(min(1, max(0, ($0 - distance) / 24 + 0.15))) } ?? 1
        return edge * near * fade
    }

    private func edgeOpacity(_ x: CGFloat, leading: CGFloat, trailing: CGFloat) -> Double {
        let left = x + leading
        let right = width + trailing - x
        return Double(min(1, max(0, min(left, right) / 28)))
    }

    private func commentBubble(_ focus: CommentFocus, leading: CGFloat, trailing: CGFloat) -> some View {
        let size = style.avatarSize
        let start = focus.x - style.markerSize / 2 - 3
        let maxWidth = max(80, min(width * 0.7, 300))
        let clamped = min(max(start, -leading + 4), width + trailing - max(bubbleWidth, 80) - 4)
        return HStack(spacing: 6) {
            avatar(focus.comment, size)
                .frame(width: size, height: size)
                .clipShape(Circle())
            Text(focus.comment.body)
                .font(style.labelFont)
                .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.86))
                .lineLimit(1)
            if focus.others > 0 {
                Text("+\(focus.others)")
                    .font(style.labelFont.monospacedDigit())
                    .foregroundStyle(.white.opacity(contrast == .increased ? 0.8 : 0.5))
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 9)
        .padding(.vertical, 2)
        .background(.black.opacity(contrast == .increased ? 0.72 : 0.3), in: Capsule())
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { bubbleWidth = $0 }
        .offset(x: clamped)
        .accessibilityElement(children: .combine)
    }

    private struct CommentWatch: Equatable {
        let count: Int
        let enabled: Bool
        let clock: TapeClock
    }

    private var commentsEnabled: Bool {
        !compact && clock.isAdvancing && isActive && !isScrubbing && !comments.isEmpty
    }

    private func watchComments() async {
        guard commentsEnabled else {
            if !showsBubbleOnAppear, isScrubbing || compact { shown = nil }
            return
        }
        var previous = clock.position(at: .now)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let now = Date.now
            let position = clock.position(at: now)
            if shown != nil, now.timeIntervalSince(lastShownAt) >= Self.visibleFor { shown = nil }
            if position - previous < 2, position >= previous, now.timeIntervalSince(lastShownAt) >= Self.minimumGap,
               let item = comments.last(where: { $0.time > previous && $0.time <= position + 0.5 }) {
                bubbleWidth = 0
                shown = item
                lastShownAt = now
            }
            previous = position
        }
    }

    // MARK: Time row

    private func timeRow(_ f: Frame, audio: TimeInterval) -> some View {
        HStack(spacing: 12) {
            Text(TapeTime.string(trim.elapsed(at: f.position)))
                .frame(minWidth: style.timeMinWidth, alignment: .leading)
            if f.fits || peaks == nil {
                Spacer(minLength: 0)
            } else {
                miniMap(f, audio: audio)
            }
            Text("−" + TapeTime.string(trim.remaining(at: f.position)))
                .frame(minWidth: style.timeMinWidth, alignment: .trailing)
        }
        .font(style.timeFont.monospacedDigit())
        .foregroundStyle(.white.opacity(isScrubbing ? 0.95 : 0.6))
        .lineLimit(1)
        .accessibilityHidden(true)
    }

    private func miniMap(_ f: Frame, audio: TimeInterval) -> some View {
        let w = max(mapWidth, 1)
        let fraction = CGFloat(min(1, max(0, f.position / duration)))
        let thumbWidth = max(8, CGFloat(f.span / duration) * w)
        let thumbX = min(max(0, CGFloat((f.position - f.span / 2) / duration) * w), w - thumbWidth)
        let audioX = CGFloat(min(1, max(0, audio / duration))) * w
        return ZStack(alignment: .leading) {
            TapeOverview(peaks: peaks, color: .white.opacity(0.32))
                .equatable()
            TapeOverview(peaks: peaks, color: .white.opacity(0.9))
                .equatable()
                .mask(alignment: .leading) { Rectangle().frame(width: fraction * w) }
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(.white, lineWidth: 1.5)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .frame(width: thumbWidth, height: style.timesHeight + 4)
                .offset(x: thumbX)
            if isScrubbing {
                Circle()
                    .fill(.white.opacity(0.8))
                    .frame(width: 4, height: 4)
                    .offset(x: audioX - 2, y: style.timesHeight / 2 + 6)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { mapWidth = $0 }
        .contentShape(Rectangle().inset(by: -8))
        .gesture(mapGesture)
    }

    // MARK: Gestures

    private func rubber(_ value: TimeInterval, limit: TimeInterval) -> TimeInterval {
        let range = trim.range
        if value < range.lowerBound {
            let over = range.lowerBound - value
            return range.lowerBound - limit * (1 - 1 / (over / limit * 0.55 + 1))
        }
        if value > range.upperBound {
            let over = value - range.upperBound
            return range.upperBound + limit * (1 - 1 / (over / limit * 0.55 + 1))
        }
        return value
    }

    private func snapTarget(_ time: TimeInterval, pps: Double, threshold: CGFloat) -> TapeEntry? {
        guard !entries.isEmpty else { return nil }
        let index = entryIndex(atOrAfter: time)
        let candidates = [index - 1, index].filter { entries.indices.contains($0) }
        let nearest = candidates.min { abs(entries[$0].start - time) < abs(entries[$1].start - time) }
        guard let nearest, entries[nearest].start > 0.5, CGFloat(abs(entries[nearest].start - time) * pps) <= threshold else { return nil }
        return entries[nearest]
    }

    private func dragGesture(_ f: Frame) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard pinchBase == nil, width > 0 else { return }
                let now = Date.now
                let live = frame(at: now)
                if live.fits {
                    if scrub == nil { grabTick += 1 }
                    glide = nil
                    scrub = trim.clamped(min(duration, max(0, Double(value.location.x) / live.pps)))
                    return
                }
                if dragOrigin == nil {
                    dragOrigin = position(at: now)
                    glide = nil
                }
                guard let origin = dragOrigin else { return }
                if scrub == nil, abs(value.translation.width) < 4 { return }
                if scrub == nil { grabTick += 1 }
                var target = rubber(origin - Double(value.translation.width) / live.pps, limit: live.span * 0.15)
                if let entry = snapTarget(target, pps: live.pps, threshold: 6) {
                    target = entry.start
                    if snapped != entry.id {
                        snapped = entry.id
                        snapTick += 1
                    }
                } else {
                    snapped = nil
                }
                scrub = target
            }
            .onEnded { value in
                dragOrigin = nil
                snapped = nil
                guard let current = scrub else { return }
                let live = frame(at: .now)
                if live.fits {
                    onSeek(current)
                    scrub = nil
                    return
                }
                var target = current
                let velocity = Double(value.velocity.width)
                if abs(velocity) > 220 { target -= velocity * 0.32 / live.pps }
                target = trim.clamped(target)
                if let entry = snapTarget(target, pps: live.pps, threshold: 10) { target = entry.start }
                if abs(target - current) * live.pps < 1 {
                    onSeek(target)
                    scrub = nil
                } else {
                    let outside = current < trim.range.lowerBound || current > trim.range.upperBound
                    glide = TapeGlide(from: current, to: target, start: .now, duration: outside ? 0.35 : 0.6)
                    scrub = target
                }
            }
    }

    private var mapGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard mapWidth > 0 else { return }
                if scrub == nil { grabTick += 1 }
                glide = nil
                scrub = trim.clamped(Double(value.location.x / mapWidth) * duration)
            }
            .onEnded { _ in
                if let scrub { onSeek(scrub) }
                scrub = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? currentSpan(at: .now)
                if pinchBase == nil {
                    pinchBase = base
                    spanGlide = nil
                }
                let raw = base / max(0.05, Double(value.magnification))
                span = rubberSpan(raw)
            }
            .onEnded { value in
                let base = pinchBase ?? settledSpan
                pinchBase = nil
                let current = span ?? base
                let projected = max(0.05, Double(value.magnification) + Double(value.velocity) * 0.2)
                let target = min(maxSpan, max(minSpan, base / projected))
                if let onZoomOutToFit, target >= duration * 0.92 {
                    onZoomOutToFit()
                    return
                }
                span = target
                spanGlide = TapeGlide(from: current, to: target, start: .now, duration: 0.45)
            }
    }

    private func rubberSpan(_ value: TimeInterval) -> TimeInterval {
        if value < minSpan { return minSpan - minSpan * 0.3 * (1 - 1 / ((minSpan - value) / minSpan + 1)) }
        if value > maxSpan { return maxSpan + maxSpan * 0.3 * (1 - 1 / ((value - maxSpan) / maxSpan + 1)) }
        return value
    }

    private func finishGlide() async {
        guard let glide else { return }
        try? await Task.sleep(for: .seconds(max(0, glide.duration - Date.now.timeIntervalSince(glide.start))))
        guard !Task.isCancelled, self.glide == glide else { return }
        onSeek(glide.to)
        self.glide = nil
        scrub = nil
    }

    private func finishSpanGlide() async {
        guard let spanGlide else { return }
        try? await Task.sleep(for: .seconds(spanGlide.duration))
        guard !Task.isCancelled, self.spanGlide == spanGlide else { return }
        self.spanGlide = nil
    }

    // MARK: Accessibility

    private var accessibilityElement: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !(clock.isAdvancing && isActive))) { context in
            let position = scrub ?? clock.position(at: context.date)
            let entry = currentEntryIndex(at: position).map { entries[$0] }
            Color.clear
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue(accessibilityValue(position: position, entry: entry))
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityAdjustableAction { direction in
                    let delta: TimeInterval = direction == .increment ? 10 : -10
                    onSeek(trim.clamped(clock.position(at: .now) + delta))
                }
                .accessibilityActions {
                    if entries.count > 1 {
                        Button("Next Track in Mix") { stepEntry(by: 1) }
                        Button("Previous Track in Mix") { stepEntry(by: -1) }
                    }
                }
        }
        .allowsHitTesting(false)
    }

    private func accessibilityValue(position: TimeInterval, entry: TapeEntry?) -> String {
        let time = "\(TapeTime.spoken(trim.elapsed(at: position))) of \(TapeTime.spoken(trim.length))"
        guard let entry else { return time }
        return "\(time), \(entry.title)\(entry.artist.map { " by \($0)" } ?? "")"
    }

    private func stepEntry(by delta: Int) {
        let position = clock.position(at: .now)
        guard let index = currentEntryIndex(at: position) else { return }
        var target = index + delta
        if delta < 0, position - entries[index].start > 3 { target = index }
        guard entries.indices.contains(target) else { return }
        onSeek(trim.clamped(entries[target].start))
    }
}

private struct TapeOverview: View, Equatable {
    let peaks: TapeWaveformPeaks?
    let color: Color

    nonisolated static func == (lhs: TapeOverview, rhs: TapeOverview) -> Bool {
        lhs.peaks?.id == rhs.peaks?.id && lhs.color == rhs.color
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard let peaks, size.width > 4 else { return }
            let pitch: CGFloat = 2.5
            let count = Int(size.width / pitch)
            let values = peaks.overview(count: count)
            var path = Path()
            for (index, value) in values.enumerated() {
                let height = max(1.5, CGFloat(value) * size.height * 0.7)
                path.addRect(CGRect(x: CGFloat(index) * pitch, y: (size.height - height) / 2, width: 1.4, height: height))
            }
            context.fill(path, with: .color(color))
        }
        .allowsHitTesting(false)
    }
}
#endif
