import SwiftUI

struct SCWaveformMarker: Identifiable, Equatable {
    let id: String
    var position: Double
    var color: Color?
    var label: String?

    init(id: String, position: Double, color: Color? = nil, label: String? = nil) {
        self.id = id
        self.position = position.scUnitClamped
        self.color = color
        self.label = label
    }
}

struct SCBeatGrid: Equatable {
    var bpm: Double
    var phaseOffsetSeconds: Double = 0
    var beatsPerBar: Int = 4
    var barsPerPhrase: Int = 8

    var isDrawable: Bool { bpm > 0 && beatsPerBar > 0 }
}

enum SCWaveformPlayheadMode: Equatable {
    case fixed
    case centered(windowSeconds: Double)
}

struct SCWaveformStyle {
    var barPitch: CGFloat
    var barGap: CGFloat
    var barCornerRadius: CGFloat
    var restFraction: CGFloat
    var verticalInset: CGFloat
    var minBarHalfHeight: CGFloat

    var shellDepths: [CGFloat]
    var unplayedShellColors: [Color]
    var playedShellColors: [Color]
    var unplayedStroke: Color?
    var playedStroke: Color?

    var axisColor: Color
    var showAxis: Bool

    var playheadColor: Color
    var playheadHaloColor: Color?
    var playheadWidth: CGFloat

    var playedGlow: Bool
    var glowColor: Color
    var glowBlurRadius: CGFloat

    var unplayedSheen: [Color]?
    var playedSheen: [Color]?

    var nearHighlightBase: Double
    var nearHighlightGain: Double

    var glowBaseOpacity: Double
    var glowEnergyGain: Double

    var beatPhraseColor: Color
    var beatBarColor: Color
    var beatBeatColor: Color

    var cueColor: Color
    var cueLineWidth: CGFloat

    var placeholderColor: Color
    var placeholderHighlightColor: Color
    var placeholderRestFraction: CGFloat
    var lowerHalfOpacity: Double = 1

    static let tv: SCWaveformStyle = {
        var style = derived(from: .tv, dense: false)
        style.barPitch = 5
        style.barGap = 2
        style.barCornerRadius = 2.5
        style.verticalInset = 3
        style.minBarHalfHeight = 3
        return style
    }()

    static let phone: SCWaveformStyle = {
        var style = derived(from: .phone, dense: false)
        style.barPitch = 3
        style.barGap = 1.5
        style.barCornerRadius = 1.5
        style.verticalInset = 1.5
        style.minBarHalfHeight = 1.5
        style.unplayedSheen = [.white.opacity(0.30), .white.opacity(0.13)]
        style.unplayedStroke = nil
        style.playedStroke = nil
        style.axisColor = .white.opacity(0.12)
        style.playheadWidth = 2
        style.playheadHaloColor = nil
        style.glowBlurRadius = 10
        style.glowBaseOpacity = 0.34
        style.glowEnergyGain = 0.22
        return style
    }()

    static let decks: SCWaveformStyle = {
        var style = derived(from: .decksConsole, dense: true)
        style.shellDepths = [1.0, 0.62, 0.28]
        style.unplayedShellColors = [
            Color(white: 0.62), Color(white: 0.80), Color(white: 0.96),
        ]
        style.playedShellColors = [
            style.playedShellColors[0].opacity(0.95),
            style.playedShellColors[0],
            .white,
        ]
        return style
    }()

    static func derived(from contentStyle: SCContentStyle, dense: Bool) -> SCWaveformStyle {
        let pitch: CGFloat = dense ? 3 : max(5, contentStyle.iconStrokeWidth * 2)
        return SCWaveformStyle(
            barPitch: pitch,
            barGap: dense ? 0.5 : max(1.5, contentStyle.spaceHair * 0.6),
            barCornerRadius: dense ? 0 : pitch / 2,
            restFraction: 0.90,
            verticalInset: 1,
            minBarHalfHeight: 2,
            shellDepths: [1.0],
            unplayedShellColors: [contentStyle.textPrimary.opacity(0.55)],
            playedShellColors: [contentStyle.accent],
            unplayedStroke: contentStyle.textPrimary.opacity(dense ? 0 : 0.10),
            playedStroke: dense ? nil : Color.black.opacity(0.22),
            axisColor: contentStyle.textPrimary.opacity(dense ? 0.20 : 0.14),
            showAxis: !dense,
            playheadColor: contentStyle.textPrimary.opacity(0.92),
            playheadHaloColor: contentStyle.accent,
            playheadWidth: dense ? 2 : 3,
            playedGlow: !dense,
            glowColor: contentStyle.accent,
            glowBlurRadius: 16,
            unplayedSheen: dense ? nil : [contentStyle.textPrimary.opacity(0.55), contentStyle.textPrimary.opacity(0.28)],
            playedSheen: dense ? nil : [
                contentStyle.accent.opacity(0.95), contentStyle.accent, contentStyle.accent.opacity(0.80),
            ],
            nearHighlightBase: dense ? 0 : 0.05,
            nearHighlightGain: dense ? 0 : 0.08,
            glowBaseOpacity: dense ? 0 : 0.38,
            glowEnergyGain: dense ? 0 : 0.24,
            beatPhraseColor: contentStyle.textPrimary.opacity(0.5),
            beatBarColor: contentStyle.textPrimary.opacity(0.32),
            beatBeatColor: contentStyle.textPrimary.opacity(0.14),
            cueColor: contentStyle.warning,
            cueLineWidth: dense ? 1 : 2,
            placeholderColor: contentStyle.textPrimary.opacity(dense ? 0.16 : 0.13),
            placeholderHighlightColor: contentStyle.textPrimary.opacity(dense ? 0.34 : 0.40),
            placeholderRestFraction: dense ? 0.10 : 0.13
        )
    }
}

enum SCWaveformPlaceholder: Equatable {
    case loading
    case unavailable
}

struct SCWaveformPlaceholderLane: View {
    var placeholder: SCWaveformPlaceholder = .loading
    var progress: Double = 0
    var style: SCWaveformStyle = .tv
    var motionSuppressed: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sweepSeconds: Double = 1.7

    private var isAnimated: Bool { placeholder == .loading && !reduceMotion && !motionSuppressed }

    var body: some View {
        if isAnimated {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                Canvas { ctx, size in
                    draw(in: ctx, size: size, sweep: Self.sweep(at: context.date))
                }
            }
        } else {
            Canvas { ctx, size in
                draw(in: ctx, size: size, sweep: nil)
            }
        }
    }

    private static func sweep(at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: sweepSeconds) / sweepSeconds
        return CGFloat(-0.18 + phase * 1.36)
    }

    private func draw(in context: GraphicsContext, size: CGSize, sweep: CGFloat?) {
        guard size.width > 0, size.height > 0 else { return }

        let totalPitch = style.barPitch + style.barGap
        let count = max(1, Int(size.width / totalPitch))
        let mid = size.height / 2
        let restHalf = max(1.5, (mid - 1) * style.placeholderRestFraction)
        let corner = style.barCornerRadius
        let window: CGFloat = 0.13

        var base = Path()
        var highlight = Path()

        for index in 0..<count {
            let x = CGFloat(index) * totalPitch
            guard x < size.width else { break }

            var gain: CGFloat = 0
            if let sweep {
                let centre = (x + style.barPitch / 2) / size.width
                let distance = abs(centre - sweep)
                if distance < window {
                    let falloff = 1 - distance / window
                    gain = falloff * falloff
                }
            }

            let half = restHalf * (1 + 0.85 * gain)
            let rect = CGRect(x: x, y: mid - half, width: style.barPitch, height: half * 2)
            let path = Path(roundedRect: rect, cornerRadius: corner)
            base.addPath(path)
            if gain > 0.04 { highlight.addPath(path) }
        }

        context.fill(base, with: .color(style.placeholderColor))
        if !highlight.isEmpty {
            context.fill(highlight, with: .color(style.placeholderHighlightColor))
        }

        let played = size.width * min(1, max(0, progress))
        if played > 0 {
            var line = Path()
            line.addRect(CGRect(x: 0, y: mid - 1, width: played, height: 2))
            context.fill(line, with: .color(style.playheadColor.opacity(0.5)))
        }
    }
}

extension SCContentMotion {
    static let waveformReveal = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.85)
}

struct SCWaveformReveal: Equatable, Sendable {
    var phase: Double
    var origin: Double

    private static let front: Double = 0.34
    private static let inkWindow: Double = 0.30

    static let complete = SCWaveformReveal(phase: 1, origin: 0)

    var isComplete: Bool { phase >= 1 }

    func amount(atFraction fraction: Double) -> Double {
        guard phase < 1 else { return 1 }
        guard phase > 0 else { return 0 }
        let reach = max(origin, 1 - origin)
        let travelled = phase * (reach + Self.front)
        let raw = (travelled - abs(fraction - origin)) / Self.front
        let t = min(1, max(0, raw))
        let inverse = 1 - t
        return 1 - inverse * inverse * inverse
    }

    func half(from seed: CGFloat, to target: CGFloat, atFraction fraction: Double) -> CGFloat {
        guard phase < 1 else { return target }
        return seed + (target - seed) * CGFloat(amount(atFraction: fraction))
    }

    var inkOpacity: Double {
        guard phase < 1 else { return 1 }
        let t = min(1, max(0, phase / Self.inkWindow))
        return 0.24 + 0.76 * t
    }
}

struct SCWaveformRevealHost<Content: View>: View {
    var isRevealed: Bool
    var identity: String?
    var origin: Double
    var reduceMotion: Bool
    @ViewBuilder var content: (SCWaveformReveal) -> Content

    @State private var phase: Double = 0
    @State private var frozenOrigin: Double = 0

    private struct Trigger: Equatable {
        var isRevealed: Bool
        var identity: String?
    }

    private var trigger: Trigger { Trigger(isRevealed: isRevealed, identity: identity) }

    var body: some View {
        SCWaveformRevealStage(
            reveal: SCWaveformReveal(phase: phase, origin: frozenOrigin),
            content: content
        )
        .onChange(of: trigger, initial: true) { _, new in
            restart(for: new)
        }
    }

    private func restart(for trigger: Trigger) {
        guard trigger.isRevealed else {
            withoutAnimation { phase = 0 }
            return
        }
        guard !reduceMotion else {
            withoutAnimation {
                frozenOrigin = origin.scUnitClamped
                phase = 1
            }
            return
        }
        withoutAnimation {
            frozenOrigin = origin.scUnitClamped
            phase = 0
        }
        DispatchQueue.main.async {
            withAnimation(SCContentMotion.waveformReveal) { phase = 1 }
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}

private struct SCWaveformRevealStage<Content: View>: View, @MainActor Animatable {
    var reveal: SCWaveformReveal
    @ViewBuilder var content: (SCWaveformReveal) -> Content

    var animatableData: Double {
        get { reveal.phase }
        set { reveal.phase = newValue }
    }

    var body: some View { content(reveal) }
}

enum SCWaveformSampler {
    /// Expands a compact amplitude envelope for display while preserving its
    /// ordering and relative shape. Published envelopes are often clustered
    /// into a very narrow range, which otherwise collapses into the minimum
    /// bar height in short lanes.
    static func visuallyNormalized(_ samples: [Float], floor: Float = 0.16) -> [Float] {
        guard samples.count > 2 else { return samples }
        let finite = samples.map { $0.isFinite ? max(0, $0) : 0 }
        let sorted = finite.sorted()
        // Most published SoundCloud envelopes occupy a tiny, noisy middle
        // band. Preserve the outliers but spread the useful 2–98% range so a
        // full-size player waveform reads as music rather than a flat fence.
        let low = sorted[Int(Double(sorted.count - 1) * 0.02)]
        let high = sorted[Int(Double(sorted.count - 1) * 0.98)]
        let span = high - low
        guard span > 0.001 else {
            return finite.map { min(1, max(floor, $0)) }
        }
        return finite.map { sample in
            let unit = min(1, max(0, (sample - low) / span))
            // Lift the middle of compact server-side envelopes. The former
            // steep curve made nearly every bar hit the minimum height in
            // desktop transport lanes even when the source had variation.
            let shaped = pow(unit, 0.78)
            return floor + (1 - floor) * shaped
        }
    }

    static func resample(_ samples: [Float], toCount count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return [] }
        if samples.count == count { return samples }
        var out = [Float](repeating: 0, count: count)
        let ratio = Double(samples.count) / Double(count)
        for i in 0..<count {
            let start = Int(Double(i) * ratio)
            let end = max(start + 1, min(samples.count, Int(Double(i + 1) * ratio)))
            out[i] = samples[start..<end].max() ?? 0
        }
        return out
    }

    static func amplitude(in samples: [Float], duration: TimeInterval, at time: TimeInterval) -> Float {
        guard !samples.isEmpty, duration > 0 else { return 0 }
        let t = max(0, min(duration, time))
        let idx = Int((t / duration) * Double(samples.count - 1))
        return samples[max(0, min(samples.count - 1, idx))]
    }
}

private final class SCWaveformBarCache {
    private var source: [Float] = []
    private var count: Int = -1
    private var cached: [Float] = []

    func bars(for envelope: [Float], count wanted: Int) -> [Float] {
        if wanted == count, source == envelope { return cached }
        cached = SCWaveformSampler.resample(envelope, toCount: wanted)
        source = envelope
        count = wanted
        return cached
    }
}

private extension Double {
    var scUnitClamped: Double { min(1, max(0, self)) }
}

struct SCWaveformRenderer: View {
    let envelope: [Float]
    let duration: TimeInterval
    let progress: Double
    var mode: SCWaveformPlayheadMode = .fixed
    var showsPlayhead: Bool = true
    var beatGrid: SCBeatGrid?
    var cueMarkers: [SCWaveformMarker] = []
    var playheadEmphasis: Double = 0
    var pulseEnergy: Double = 0
    var placeholder: SCWaveformPlaceholder = .unavailable
    var identity: String?
    var motionSuppressed: Bool = false
    var style: SCWaveformStyle = .tv

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var barCache = SCWaveformBarCache()

    private var hasEnvelope: Bool { !envelope.isEmpty }

    /// A Canvas layer is clipped by its host before a blur can be composited.
    /// That produced bright cyan/white crescents at the leading and trailing
    /// edges of waveform lanes on macOS, iOS and tvOS. A subtle playhead and
    /// played/unplayed colour split carries the same state without allowing
    /// an effect to escape (or visibly collide with) the waveform's bounds.
    /// Keep this central: individual screens must not need to guess how much
    /// extra padding a renderer needs in their particular container.
    private var drawsBlurredGlow: Bool { false }

    private var revealOrigin: Double {
        switch mode {
        case .fixed:    return progress.scUnitClamped
        case .centered: return 0.5
        }
    }

    var body: some View {
        SCWaveformRevealHost(
            isRevealed: hasEnvelope,
            identity: identity,
            origin: revealOrigin,
            reduceMotion: reduceMotion || motionSuppressed
        ) { reveal in
            Group {
                if hasEnvelope {
                    Canvas { context, size in
                        draw(in: context, size: size, reveal: reveal)
                    }
                } else {
                    SCWaveformPlaceholderLane(
                        placeholder: placeholder,
                        progress: progress,
                        style: style,
                        motionSuppressed: motionSuppressed
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fadeEdges(of layer: inout GraphicsContext, size: CGSize, band: CGFloat) {
        guard band > 0 else { return }
        layer.blendMode = .destinationOut

        let v = min(band, size.height * 0.3)
        layer.fill(
            Path(CGRect(x: 0, y: 0, width: size.width, height: v)),
            with: .linearGradient(
                Gradient(colors: [.black, .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: v)
            )
        )
        layer.fill(
            Path(CGRect(x: 0, y: size.height - v, width: size.width, height: v)),
            with: .linearGradient(
                Gradient(colors: [.clear, .black]),
                startPoint: CGPoint(x: 0, y: size.height - v), endPoint: CGPoint(x: 0, y: size.height)
            )
        )

        let h = min(band, size.width * 0.1)
        layer.fill(
            Path(CGRect(x: 0, y: 0, width: h, height: size.height)),
            with: .linearGradient(
                Gradient(colors: [.black, .clear]),
                startPoint: .zero, endPoint: CGPoint(x: h, y: 0)
            )
        )
        layer.fill(
            Path(CGRect(x: size.width - h, y: 0, width: h, height: size.height)),
            with: .linearGradient(
                Gradient(colors: [.clear, .black]),
                startPoint: CGPoint(x: size.width - h, y: 0), endPoint: CGPoint(x: size.width, y: 0)
            )
        )

        layer.blendMode = .normal
    }

    private func draw(in context: GraphicsContext, size: CGSize, reveal: SCWaveformReveal) {
        guard size.width > 0, size.height > 0 else { return }

        switch mode {
        case .fixed:
            drawFixed(in: context, size: size, reveal: reveal)
        case .centered(let windowSeconds):
            drawCentered(in: context, size: size, windowSeconds: max(0.5, windowSeconds), reveal: reveal)
        }
    }

    private func drawFixed(in context: GraphicsContext, size: CGSize, reveal: SCWaveformReveal) {
        let totalPitch = style.barPitch + style.barGap
        let barCount = max(1, Int(size.width / totalPitch))
        let bars = barCache.bars(for: envelope, count: barCount)
        guard !bars.isEmpty else { return }

        let mid = size.height / 2
        let glowSafeInset = drawsBlurredGlow ? style.glowBlurRadius + 2 : 0
        let usableHalf = max(style.minBarHalfHeight, mid - max(style.verticalInset, glowSafeInset))
        let restHalf = usableHalf * style.restFraction
        let seedHalf = max(1.5, (mid - 1) * style.placeholderRestFraction)
        let playedCount = Int((progress.scUnitClamped * Double(bars.count)).rounded())
        let playheadX = CGFloat(playedCount) * totalPitch
        let emphasisWindow = size.height * 1.2
        let emphasisGain = CGFloat(playheadEmphasis) * (1 - style.restFraction) / max(0.01, style.restFraction)
        let corner = style.barCornerRadius
        let growing = !reveal.isComplete
        let inverseWidth = 1 / max(1, size.width)

        var ink = context
        if growing { ink.opacity = reveal.inkOpacity }

        if style.showAxis {
            var axis = Path()
            axis.addRect(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1))
            ink.fill(axis, with: .color(style.axisColor))
        }

        drawBeatGridIfNeeded(in: ink, size: size, reveal: reveal, growing: growing) { t in
            (t / max(0.001, duration)) * size.width
        }
        drawMarkers(cueMarkers, in: ink, size: size, reveal: reveal, growing: growing) { t in
            (t / max(0.001, duration)) * size.width
        }

        for layerIndex in style.shellDepths.indices {
            let depth = style.shellDepths[layerIndex]
            var playedPath = Path()
            var unplayedPath = Path()
            var nearPath = Path()

            for (index, sample) in bars.enumerated() {
                let x = CGFloat(index) * totalPitch
                guard x < size.width else { break }

                var scale: CGFloat = 1
                var nearness: CGFloat = 0
                if emphasisGain > 0 {
                    let distance = abs(x + corner - playheadX)
                    if distance < emphasisWindow {
                        let falloff = 1 - distance / emphasisWindow
                        nearness = falloff * falloff
                        scale += emphasisGain * nearness
                    }
                }

                var half = CGFloat(sample) * restHalf * scale * depth
                if growing {
                    half = reveal.half(
                        from: seedHalf * depth, to: half,
                        atFraction: Double((x + style.barPitch / 2) * inverseWidth)
                    )
                }
                let height = max(style.minBarHalfHeight, half)
                let rect = CGRect(x: x, y: mid - height, width: style.barPitch, height: height * 2)
                let path = Path(roundedRect: rect, cornerRadius: corner)
                if index < playedCount {
                    playedPath.addPath(path)
                } else {
                    unplayedPath.addPath(path)
                }
                if layerIndex == 0, nearness > 0.05 {
                    nearPath.addPath(path)
                }
            }

            if layerIndex == 0, drawsBlurredGlow, playheadX > 4 {
                ink.drawLayer { layer in
                    layer.addFilter(.blur(radius: style.glowBlurRadius))
                    layer.opacity = style.glowBaseOpacity + style.glowEnergyGain * pulseEnergy.scUnitClamped
                    layer.fill(playedPath, with: .color(style.glowColor))
                    fadeEdges(of: &layer, size: size, band: style.glowBlurRadius * 1.25)
                }
            }

            let unplayedColor = style.unplayedShellColors[safe: layerIndex] ?? style.unplayedShellColors.last ?? .gray
            let playedColor = style.playedShellColors[safe: layerIndex] ?? style.playedShellColors.last ?? .orange
            fillLane(
                unplayedPath: unplayedPath, playedPath: playedPath,
                unplayedColor: unplayedColor, playedColor: playedColor,
                sheenApplies: layerIndex == 0, mid: mid, usableHalf: usableHalf, in: ink
            )
            if let stroke = style.unplayedStroke, layerIndex == 0 {
                ink.stroke(unplayedPath, with: .color(stroke), lineWidth: 1)
            }
            if let stroke = style.playedStroke, layerIndex == 0 {
                ink.stroke(playedPath, with: .color(stroke), lineWidth: 1)
            }
            if layerIndex == 0, !nearPath.isEmpty, style.nearHighlightGain > 0 || style.nearHighlightBase > 0 {
                let opacity = style.nearHighlightBase + style.nearHighlightGain * playheadEmphasis.scUnitClamped
                ink.fill(nearPath, with: .color(style.playheadColor.opacity(opacity)))
            }
        }

        if showsPlayhead {
            drawPlayhead(at: playheadX, in: context, size: size, usableHalf: usableHalf, reveal: reveal)
        }
    }

    private func fillLane(
        unplayedPath: Path, playedPath: Path,
        unplayedColor: Color, playedColor: Color,
        sheenApplies: Bool, mid: CGFloat, usableHalf: CGFloat, in context: GraphicsContext
    ) {
        let top = CGPoint(x: 0, y: mid - usableHalf)
        let bottom = CGPoint(x: 0, y: mid + usableHalf)

        func drawFills(in target: inout GraphicsContext) {
            if sheenApplies, let sheen = style.unplayedSheen, sheen.count >= 2 {
                target.fill(
                    unplayedPath,
                    with: .linearGradient(Gradient(colors: sheen), startPoint: top, endPoint: bottom)
                )
            } else {
                target.fill(unplayedPath, with: .color(unplayedColor))
            }

            if sheenApplies, let sheen = style.playedSheen, sheen.count >= 2 {
                target.fill(
                    playedPath,
                    with: .linearGradient(Gradient(colors: sheen), startPoint: top, endPoint: bottom)
                )
            } else {
                target.fill(playedPath, with: .color(playedColor))
            }
        }

        guard style.lowerHalfOpacity < 0.999 else {
            var whole = context
            drawFills(in: &whole)
            return
        }

        let laneBounds = unplayedPath.boundingRect.union(playedPath.boundingRect)
        let laneWidth = max(1, laneBounds.maxX + style.barPitch)

        var upper = context
        upper.clip(to: Path(CGRect(x: 0, y: 0, width: laneWidth, height: mid)))
        drawFills(in: &upper)

        var lower = context
        lower.clip(to: Path(CGRect(
            x: 0,
            y: mid,
            width: laneWidth,
            height: max(1, mid)
        )))
        lower.opacity *= max(0, style.lowerHalfOpacity)
        drawFills(in: &lower)
    }

    private func drawCentered(
        in context: GraphicsContext, size: CGSize, windowSeconds: Double, reveal: SCWaveformReveal
    ) {
        guard duration > 0, !envelope.isEmpty else { return }
        let position = progress.scUnitClamped * duration
        let start = position - windowSeconds / 2
        let secondsPerPoint = windowSeconds / Double(size.width)
        let mid = size.height / 2
        let glowSafeInset = drawsBlurredGlow ? style.glowBlurRadius + 2 : 0
        let usableHalf = max(style.minBarHalfHeight, mid - max(style.verticalInset, glowSafeInset))
        let seedHalf = max(1.5, (mid - 1) * style.placeholderRestFraction)
        let growing = !reveal.isComplete
        let inverseWidth = 1 / max(1, size.width)

        var ink = context
        if growing { ink.opacity = reveal.inkOpacity }

        func xFor(_ t: Double) -> CGFloat { CGFloat((t - start) / secondsPerPoint) }

        drawBeatGridIfNeeded(in: ink, size: size, reveal: reveal, growing: growing, xFor: xFor)
        drawMarkers(cueMarkers, in: ink, size: size, reveal: reveal, growing: growing, xFor: xFor)

        let centerX = size.width / 2
        let emphasisWindow = size.height * 1.2
        let emphasisGain = CGFloat(playheadEmphasis.scUnitClamped) * (1 - style.restFraction) / max(0.01, style.restFraction)

        let totalPitch = style.barPitch + style.barGap
        for layerIndex in style.shellDepths.indices {
            let depth = style.shellDepths[layerIndex]
            var playedPath = Path()
            var futurePath = Path()
            var nearPath = Path()
            var x: CGFloat = 0
            while x < size.width {
                let t = start + Double(x) * secondsPerPoint
                let amplitude = (t < 0 || t > duration)
                    ? 0
                    : SCWaveformSampler.amplitude(in: envelope, duration: duration, at: t)

                var scale: CGFloat = 1
                var nearness: CGFloat = 0
                if emphasisGain > 0 {
                    let distance = abs(x - centerX)
                    if distance < emphasisWindow {
                        let falloff = 1 - distance / emphasisWindow
                        nearness = falloff * falloff
                        scale += emphasisGain * nearness
                    }
                }

                var half = CGFloat(amplitude) * usableHalf * style.restFraction * scale * depth
                if growing {
                    half = reveal.half(
                        from: seedHalf * depth, to: half, atFraction: Double(x * inverseWidth)
                    )
                }
                let height = max(style.minBarHalfHeight, half)
                let rect = CGRect(x: x, y: mid - height, width: max(1, style.barPitch), height: height * 2)
                let path = Path(roundedRect: rect, cornerRadius: style.barCornerRadius)
                if t <= position {
                    playedPath.addPath(path)
                } else {
                    futurePath.addPath(path)
                }
                if layerIndex == 0, nearness > 0.05 {
                    nearPath.addPath(path)
                }
                x += totalPitch
            }

            if layerIndex == 0, drawsBlurredGlow, !playedPath.isEmpty {
                ink.drawLayer { layer in
                    layer.addFilter(.blur(radius: style.glowBlurRadius))
                    layer.opacity = style.glowBaseOpacity + style.glowEnergyGain * pulseEnergy.scUnitClamped
                    layer.fill(playedPath, with: .color(style.glowColor))
                    fadeEdges(of: &layer, size: size, band: style.glowBlurRadius * 1.25)
                }
            }

            let unplayedColor = style.unplayedShellColors[safe: layerIndex] ?? style.unplayedShellColors.last ?? .gray
            let playedColor = style.playedShellColors[safe: layerIndex] ?? style.playedShellColors.last ?? .orange
            fillLane(
                unplayedPath: futurePath, playedPath: playedPath,
                unplayedColor: unplayedColor, playedColor: playedColor,
                sheenApplies: layerIndex == 0, mid: mid, usableHalf: usableHalf, in: ink
            )
            if layerIndex == 0, !nearPath.isEmpty, style.nearHighlightGain > 0 || style.nearHighlightBase > 0 {
                let opacity = style.nearHighlightBase + style.nearHighlightGain * playheadEmphasis.scUnitClamped
                ink.fill(nearPath, with: .color(style.playheadColor.opacity(opacity)))
            }
        }

        if style.showAxis {
            context.fill(
                Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)),
                with: .color(style.axisColor)
            )
        }

        if showsPlayhead {
            drawPlayhead(at: size.width / 2, in: context, size: size, usableHalf: usableHalf, reveal: reveal)
        }
    }

    private func drawBeatGridIfNeeded(
        in context: GraphicsContext, size: CGSize,
        reveal: SCWaveformReveal, growing: Bool, xFor: (Double) -> CGFloat
    ) {
        guard let beatGrid, beatGrid.isDrawable else { return }
        let beatInterval = 60.0 / beatGrid.bpm
        guard beatInterval > 0.02 else { return }

        let visibleStart: Double
        let visibleEnd: Double
        switch mode {
        case .fixed:
            visibleStart = 0
            visibleEnd = duration
        case .centered(let windowSeconds):
            let position = progress.scUnitClamped * duration
            visibleStart = position - windowSeconds / 2
            visibleEnd = position + windowSeconds / 2
        }

        let pixelsPerBeat = abs(xFor(beatInterval) - xFor(0))
        guard pixelsPerBeat > 0.001 else { return }
        let beatsPerBar = max(1, beatGrid.beatsPerBar)
        let phraseBeats = max(1, beatGrid.beatsPerBar * beatGrid.barsPerPhrase)
        let drawBars = pixelsPerBeat * CGFloat(beatsPerBar) >= 24
        let drawBeats = drawBars && pixelsPerBeat >= 6
        var phraseStep = 1
        while pixelsPerBeat * CGFloat(phraseBeats * phraseStep) < 24 { phraseStep *= 2 }

        var beatIndex = Int(((visibleStart - beatGrid.phaseOffsetSeconds) / beatInterval).rounded(.down))
        while true {
            let t = beatGrid.phaseOffsetSeconds + Double(beatIndex) * beatInterval
            if t > visibleEnd { break }
            defer { beatIndex += 1 }
            guard t >= max(0, visibleStart) else { continue }

            let x = xFor(t)
            guard x >= -4, x <= size.width + 4 else { continue }

            let isPhraseStart = beatIndex % phraseBeats == 0
            let isBarStart = beatIndex % beatsPerBar == 0
            if isPhraseStart {
                guard beatIndex % (phraseBeats * phraseStep) == 0 else { continue }
            } else if isBarStart {
                guard drawBars else { continue }
            } else {
                guard drawBeats else { continue }
            }
            var lineHeight: CGFloat = isPhraseStart ? size.height : (isBarStart ? size.height * 0.7 : size.height * 0.28)
            let color = isPhraseStart ? style.beatPhraseColor : (isBarStart ? style.beatBarColor : style.beatBeatColor)
            let lineWidth: CGFloat = isPhraseStart ? 1.6 : (isBarStart ? 1.2 : 0.7)

            var alpha: Double = 1
            if growing {
                let grown = reveal.amount(atFraction: Double(x / max(1, size.width)))
                guard grown > 0.001 else { continue }
                lineHeight *= CGFloat(grown)
                alpha = grown
            }

            context.stroke(
                Path {
                    $0.move(to: CGPoint(x: x, y: (size.height - lineHeight) / 2))
                    $0.addLine(to: CGPoint(x: x, y: (size.height + lineHeight) / 2))
                },
                with: .color(alpha < 1 ? color.opacity(alpha) : color),
                lineWidth: lineWidth
            )
        }
    }

    private func drawMarkers(
        _ markers: [SCWaveformMarker], in context: GraphicsContext, size: CGSize,
        reveal: SCWaveformReveal, growing: Bool, xFor: (Double) -> CGFloat
    ) {
        for marker in markers {
            let t = marker.position * duration
            let x = xFor(t)
            guard x >= -2, x <= size.width + 2 else { continue }
            var height = size.height
            var color = marker.color ?? style.cueColor
            if growing {
                let grown = reveal.amount(atFraction: Double(x / max(1, size.width)))
                guard grown > 0.001 else { continue }
                height *= CGFloat(grown)
                color = color.opacity(grown)
            }
            var line = Path()
            line.move(to: CGPoint(x: x, y: (size.height - height) / 2))
            line.addLine(to: CGPoint(x: x, y: (size.height + height) / 2))
            context.stroke(line, with: .color(color), lineWidth: style.cueLineWidth)
        }
    }

    private func drawPlayhead(
        at x: CGFloat, in context: GraphicsContext, size: CGSize,
        usableHalf: CGFloat, reveal: SCWaveformReveal
    ) {
        guard x >= 0, x <= size.width else { return }
        let mid = size.height / 2
        let settled = reveal.isComplete ? 1 : reveal.amount(atFraction: reveal.origin)

        if settled < 1 {
            var elapsed = Path()
            elapsed.addRect(CGRect(x: 0, y: mid - 1, width: x, height: 2))
            context.fill(elapsed, with: .color(style.playheadColor.opacity(0.5 * (1 - settled))))
        }
        guard settled > 0.001 else { return }

        var head = context
        if settled < 1 { head.opacity = settled }

        if let haloColor = style.playheadHaloColor, drawsBlurredGlow {
            head.drawLayer { layer in
                layer.addFilter(.blur(radius: 14))
                layer.opacity = 0.55
                let halo = Path(ellipseIn: CGRect(x: x - 16, y: mid - usableHalf, width: 32, height: usableHalf * 2))
                layer.fill(halo, with: .color(haloColor))
                fadeEdges(of: &layer, size: size, band: 14)
            }
        }

        var column = Path()
        column.addRoundedRect(
            in: CGRect(
                x: x - style.playheadWidth / 2, y: mid - usableHalf - 2,
                width: style.playheadWidth, height: usableHalf * 2 + 4
            ),
            cornerSize: CGSize(width: style.playheadWidth / 2, height: style.playheadWidth / 2)
        )
        head.fill(column, with: .color(style.playheadColor))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
