import QuartzCore
import SwiftUI

struct MacDJStackedWaveforms: View {
    let state: MacDJPerformState
    let usesCanvas: Bool
    var layout: MacDJPerformLayout = .full
    var onZoom: (Double) -> Void = { _ in }

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pinchStart: Double?

    private let gutter: CGFloat = 64
    private let band: CGFloat = 46

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let laneH = (size.height - band - 8) / 2
            let laneA = CGRect(x: gutter, y: 4, width: size.width - gutter, height: laneH)
            let laneB = CGRect(x: gutter, y: 4 + laneH + band, width: size.width - gutter, height: laneH)
            let geometry = Geometry(width: size.width - gutter, gutter: gutter, nowBar: state.mix?.nowBar ?? 0, span: state.zoomBars)
            ZStack(alignment: .topLeading) {
                lane(.a, rect: laneA, geometry: geometry)
                lane(.b, rect: laneB, geometry: geometry)
                if let mix = state.mix {
                    ZStack(alignment: .topLeading) {
                        mixOverlays(mix, laneA: laneA, laneB: laneB, geometry: geometry)
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .mask(alignment: .topLeading) {
                            Rectangle().frame(width: max(0, size.width - gutter), height: size.height).offset(x: gutter)
                        }
                }
                ownershipTags(laneA: laneA, laneB: laneB, geometry: geometry)
                playhead(height: size.height, x: geometry.playheadX)
                gutterLabel(.a, rect: laneA)
                gutterLabel(.b, rect: laneB)
                zoomHint(laneB: laneB, width: size.width)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .background(MacDJPalette.well)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(contrast == .increased ? 0.5 : 0.09), lineWidth: contrast == .increased ? 1 : 0.5))
        .gesture(MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = state.zoomBars }
                onZoom(min(64, max(8, ((pinchStart ?? 22) / value.magnification).rounded())))
            }
            .onEnded { _ in pinchStart = nil })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Decks A and B")
    }

    struct Geometry {
        var width: CGFloat
        var gutter: CGFloat
        var nowBar: Double
        var span: Double

        var playheadX: CGFloat { gutter + width / 2 }
        func x(_ bar: Double) -> CGFloat { gutter + width / 2 + CGFloat((bar - nowBar) / span) * width }
    }

    // MARK: Lanes

    @ViewBuilder
    private func lane(_ deck: MixEngine.Deck, rect: CGRect, geometry: Geometry) -> some View {
        let d = state.deck(deck)
        ZStack(alignment: .topLeading) {
            if usesCanvas || !MetalWaveformView.isSupported {
                MacDJCanvasLane(deck: deck, state: state, geometry: geometry)
            } else if let source = metalSource(d), let bar = d.barSeconds {
                MetalWaveformView(
                    source: source,
                    timeline: .following(
                        anchor: d.position, hostTime: CACurrentMediaTime(),
                        rate: d.isPlaying && !reduceMotion ? 1 + d.pitchPercent / 100 : 0,
                        window: state.zoomBars * bar, playheadFraction: 0.5
                    ),
                    grid: d.bpm.map { MetalWaveformBeatGrid(bpm: $0) },
                    overlays: [],
                    style: MacDJLaneStyle.metal(for: d)
                )
            }
            if d.analysis != .ready, case .noGrid(let range) = d.analysis {
                Text("No grid \u{00B7} \(range)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 3)
                    .padding(8)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipped()
        .offset(x: rect.minX, y: rect.minY)
        .accessibilityElement()
        .accessibilityLabel("Deck \(deck.label) waveform")
        .accessibilityValue(d.isEmpty ? "Empty" : "\(d.title), \(d.remainingText) left")
    }

    private func metalSource(_ deck: MacDJDeckState) -> MetalWaveformSource? {
        guard let id = deck.trackId, deck.duration > 0 else { return nil }
        return MetalWaveformSourceCache.shared.envelope(id: id, samples: deck.samples, duration: deck.duration)
    }

    // MARK: Mix overlays

    @ViewBuilder
    private func mixOverlays(_ mix: MacDJMixState, laneA: CGRect, laneB: CGRect, geometry: Geometry) -> some View {
        let leavingLane = mix.leaving == .a ? laneA : laneB
        let enteringLane = mix.leaving == .a ? laneB : laneA
        let startX = geometry.x(1)
        if startX > enteringLane.minX {
            MacDJHatch(color: .white.opacity(0.03), spacing: 10)
                .frame(width: min(enteringLane.width, startX - enteringLane.minX), height: enteringLane.height)
                .offset(x: enteringLane.minX, y: enteringLane.minY)
            Text(mix.enteringNote)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(contrast.djInk(0.6))
                .lineLimit(1)
                .frame(width: max(0, startX - enteringLane.minX - 16), alignment: .leading)
                .offset(x: enteringLane.minX + 14, y: enteringLane.midY - 8)
        }
        ForEach(Array(mix.loops.enumerated()), id: \.element.id) { index, loop in
            let x0 = geometry.x(loop.fromBar), x1 = geometry.x(loop.toBar)
            let current = mix.nowBar >= loop.fromBar && mix.nowBar < loop.toBar
            Rectangle()
                .fill(MacDJPalette.auto.opacity(current ? 0.15 : 0.08))
                .overlay(alignment: .leading) { Rectangle().fill(MacDJPalette.auto).frame(width: index == 0 ? 1.5 : 0.5) }
                .overlay(alignment: .trailing) { Rectangle().fill(MacDJPalette.auto).frame(width: index == mix.loops.count - 1 ? 1.5 : 0.5) }
                .frame(width: max(0, x1 - x0), height: enteringLane.height)
                .offset(x: x0, y: enteringLane.minY)
            MacDJLaneTag(text: loop.label, symbol: "repeat", style: .auto)
                .offset(x: x0 + 5, y: enteringLane.minY + 5)
        }
        if let fade = mix.fadeOutFromBar {
            let x0 = geometry.x(fade), x1 = geometry.x(mix.totalBars + 1)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(0, x1 - x0), height: leavingLane.height)
                .offset(x: x0, y: leavingLane.minY)
            MacDJPalette.well
                .frame(width: max(0, leavingLane.maxX - x1), height: leavingLane.height)
                .offset(x: x1, y: leavingLane.minY)
        }
        if let label = mix.leavingLabel, let bar = mix.leavingLabelBar {
            sectionLabel(label, color: MacDJPalette.leavingLabel).offset(x: max(geometry.gutter + 8, geometry.x(bar) + 6), y: leavingLane.maxY - 22)
        }
        if let label = mix.enteringLabel, let bar = mix.enteringLabelBar {
            sectionLabel(label, color: MacDJPalette.enteringLabel).offset(x: max(geometry.gutter + 8, geometry.x(bar) + 6), y: enteringLane.maxY - 22)
        }
        if let cue = mix.mixOutCue {
            let x = geometry.x(cue.bar)
            Rectangle().fill(cue.color).frame(width: 1.5, height: leavingLane.height).offset(x: x - 0.75, y: leavingLane.minY)
            Text(cue.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background(UnevenRoundedRectangle(bottomTrailingRadius: 5, topTrailingRadius: 5).fill(cue.color))
                .fixedSize()
                .offset(x: x, y: leavingLane.minY)
        }
        if let marker = mix.mixOutMarkerBar {
            Triangle()
                .fill(MacDJPalette.onAir)
                .frame(width: 10, height: 8)
                .offset(x: geometry.x(marker) - 5, y: leavingLane.maxY - 8)
        }
        stepBand(mix, top: laneA.maxY, geometry: geometry, left: laneA.minX)
    }

    private func sectionLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .shadow(color: .black, radius: 3)
            .shadow(color: .black, radius: 6)
            .fixedSize()
    }

    @ViewBuilder
    private func stepBand(_ mix: MacDJMixState, top: CGFloat, geometry: Geometry, left: CGFloat) -> some View {
        let total = Int(mix.totalBars)
        ForEach(1...max(1, total), id: \.self) { bar in
            let x = geometry.x(Double(bar))
            if x > left, x < left + geometry.width {
                Text("\(bar)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(bar == Int(mix.nowBar.rounded(.down)) ? 0.95 : 0.6))
                    .fixedSize()
                    .offset(x: x + 3, y: top + 2)
            }
        }
        if layout.showsStepTracker { ForEach(mix.steps) { step in
            let x0 = max(left, geometry.x(step.fromBar) + 1)
            let x1 = geometry.x(step.toBar) - 1
            if x1 > x0 + 8 {
                MacDJStepPill(step: step, mode: mix.mode(of: step), nowBar: mix.nowBar, splitX: geometry.x(mix.nowBar) - x0)
                    .frame(width: x1 - x0, height: 22)
                    .offset(x: x0, y: top + 17)
            }
        } }
        if layout.showsPhaseMeter, let phase = mix.phase {
            let width = geometry.x(1) - left - 22
            if width > 70 {
                MacDJPhaseMeter(phase: phase)
                    .frame(width: width)
                    .offset(x: left + 10, y: top + 8)
            }
        }
    }

    @ViewBuilder
    private func ownershipTags(laneA: CGRect, laneB: CGRect, geometry: Geometry) -> some View {
        ForEach(Array(state.owned.enumerated()), id: \.element.id) { index, owned in
            let lane = owned.control.deck == .a ? laneA : laneB
            MacDJLaneTag(text: "\(owned.control.name) \u{00B7} yours \u{00B7} \(owned.valueText)", symbol: "hand.raised", style: .yours)
                .offset(x: geometry.playheadX + 8, y: lane.minY + 30 + CGFloat(index) * 22)
        }
    }

    private func playhead(height: CGFloat, x: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.white).frame(width: 2, height: height).offset(x: x - 1)
            Triangle().rotation(.degrees(180)).fill(.white).frame(width: 12, height: 7).offset(x: x - 6)
            Triangle().fill(.white).frame(width: 12, height: 7).offset(x: x - 6, y: height - 7)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func gutterLabel(_ deck: MixEngine.Deck, rect: CGRect) -> some View {
        let leaving = (state.mix?.leaving ?? .a) == deck
        let word = state.mix == nil ? state.deck(deck).title.isEmpty ? "Empty" : "Deck \(deck.label)" : (leaving ? "Leaving" : "Entering")
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 5) {
                MacDJDeckBadge(deck: deck, size: 24)
                Text(word)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MacDJPalette.deck(deck))
            }
            .frame(width: gutter, height: rect.height)
            Group {
                if deck == .a {
                    RoundedRectangle(cornerRadius: 2).fill(MacDJPalette.deckA)
                } else {
                    Path { path in
                        path.move(to: CGPoint(x: 1.5, y: 0))
                        path.addLine(to: CGPoint(x: 1.5, y: rect.height - 12))
                    }
                    .stroke(MacDJPalette.deckB, style: StrokeStyle(lineWidth: 3, dash: [4, 3]))
                }
            }
            .frame(width: 3, height: rect.height - 12)
            .offset(x: gutter - 3, y: 6)
        }
        .offset(y: rect.minY)
        .accessibilityHidden(true)
    }

    private func zoomHint(laneB: CGRect, width: CGFloat) -> some View {
        Text("\(Int(state.zoomBars)) bars \u{00B7} pinch to zoom")
            .font(.system(size: 11))
            .foregroundStyle(contrast.djInk(0.75))
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(Capsule().fill(Color(white: 0.08).opacity(0.88)))
            .fixedSize()
            .frame(width: width - 8, alignment: .trailing)
            .offset(y: laneB.maxY - 24)
            .allowsHitTesting(false)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct MacDJLaneTag: View {
    enum Style {
        case auto
        case yours
    }

    let text: String
    let symbol: String
    let style: Style

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .labelStyle(TagLabelStyle())
            .foregroundStyle(style == .auto ? MacDJPalette.auto : MacDJPalette.yours)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(style == .auto ? Color(red: 0.04, green: 0.12, blue: 0.10).opacity(0.9) : Color(red: 0.19, green: 0.165, blue: 0.024).opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(style == .auto ? MacDJPalette.auto.opacity(0.5) : MacDJPalette.yours.opacity(0.55), lineWidth: style == .auto ? 0.5 : 1))
            .fixedSize()
    }

    private struct TagLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon.font(.system(size: 10, weight: .semibold))
                configuration.title
            }
        }
    }
}

struct MacDJStepPill: View {
    let step: MacDJStep
    let mode: MacDJMixState.StepMode
    let nowBar: Double
    let splitX: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(countdown: true, fits: true)
            row(countdown: false, fits: true)
            row(countdown: false, fits: false)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(ring, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityValue(mode == .now ? "Now" : mode == .done ? "Done" : "Next")
    }

    private func row(countdown: Bool, fits: Bool) -> some View {
        HStack(spacing: 4) {
            if mode == .done {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
            }
            Text(step.label)
                .lineLimit(1)
                .fixedSize(horizontal: fits, vertical: false)
            if mode == .next, countdown {
                Spacer(minLength: 4)
                Text("in \(Int((step.fromBar - nowBar).rounded(.up)))")
                    .fontWeight(.medium)
                    .opacity(0.75)
                    .fixedSize()
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        switch mode {
        case .done: MacDJPalette.auto.opacity(0.16)
        case .next: Color.white.opacity(0.06)
        case .now:
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    MacDJPalette.auto.opacity(0.42).frame(width: max(0, min(proxy.size.width, splitX)))
                    MacDJPalette.auto.opacity(0.12)
                }
            }
        }
    }

    private var foreground: Color {
        switch mode {
        case .done: return Color(red: 0.59, green: 0.9, blue: 0.8)
        case .now: return Color(red: 0.94, green: 1, blue: 0.98)
        case .next: return .white.opacity(0.88)
        }
    }

    private var ring: Color {
        switch mode {
        case .done: return MacDJPalette.auto.opacity(0.4)
        case .now: return MacDJPalette.auto.opacity(0.8)
        case .next: return .white.opacity(0.2)
        }
    }
}

struct MacDJPhaseMeter: View {
    let phase: MacDJPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Phase").foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(phase.text).foregroundStyle(phase.isKnown ? MacDJPalette.auto : .white.opacity(0.7))
            }
            .font(.system(size: 11, weight: .semibold))
            GeometryReader { proxy in
                let cell = proxy.size.width / 4
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08))
                    if phase.isKnown {
                        ForEach(0..<4, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(i == phase.beat ? MacDJPalette.deckA : MacDJPalette.deckA.opacity(0.35))
                                .frame(width: cell - 2, height: 5)
                                .offset(x: CGFloat(i) * cell)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(i == phase.beat ? MacDJPalette.deckB : MacDJPalette.deckB.opacity(0.3))
                                .frame(width: cell - 2, height: 5)
                                .offset(x: CGFloat(i) * cell, y: 7)
                        }
                    }
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Phase")
        .accessibilityValue(phase.text)
    }
}

enum MacDJLaneStyle {
    static func metal(for deck: MacDJDeckState) -> MetalWaveformStyle {
        var style = MetalWaveformStyle.blue
        style.playheadWidth = 0
        if deck.isSoundCloud && deck.isViewOnly {
            style = MetalWaveformStyle.threeBand
            style.playheadWidth = 0
        }
        return style.dimmingUnplayed(1).dimmingPlayed(0.55)
    }
}

extension MetalWaveformStyle {
    func dimmingPlayed(_ amount: Float) -> MetalWaveformStyle {
        var style = self
        style.playedTint = SIMD4(amount, amount, amount, 1)
        return style
    }
}

struct MacDJCanvasLane: View {
    let deck: MixEngine.Deck
    let state: MacDJPerformState
    let geometry: MacDJStackedWaveforms.Geometry

    var body: some View {
        let d = state.deck(deck)
        let mix = state.mix
        let leaving = (mix?.leaving ?? .a) == deck
        Canvas { context, size in
            let span = geometry.span
            let nowBar = geometry.nowBar
            let barW = size.width / CGFloat(span)
            let firstBar = nowBar - span / 2
            if d.analysis == .ready || d.bpm != nil {
                var beat = (firstBar * 4).rounded(.up) / 4
                while beat <= firstBar + span {
                    let x = CGFloat(beat - firstBar) * barW
                    let isBar = beat.truncatingRemainder(dividingBy: 1) == 0
                    let isPhrase = isBar && Int(beat.rounded()) % 4 == 1
                    let alpha = isPhrase ? 0.3 : isBar ? 0.16 : 0.055
                    context.fill(Path(CGRect(x: x.rounded() - 0.25, y: 0, width: isPhrase ? 1 : 0.5, height: size.height)), with: .color(.white.opacity(alpha)))
                    beat += 0.25
                }
            }
            guard !d.isEmpty else { return }
            let samples = d.samples
            let playheadX = size.width / 2
            let columns = Int(size.width)
            for column in 0..<columns {
                let x = CGFloat(column)
                let bar = firstBar + Double(x / barW)
                guard let amp = MacDJCanvasLane.amplitude(deck: deck, bar: bar, leaving: leaving, mix: mix, samples: samples, analysing: d.analysis) else { continue }
                let h = CGFloat(amp.total) * size.height * 0.46
                let core = CGFloat(amp.high) * size.height * 0.46
                let dim = x < playheadX ? 0.55 : 1.0
                let lowColor: Color
                let highColor: Color
                if d.isViewOnly {
                    lowColor = Color(red: 0.98, green: 0.62, blue: 0.18).opacity(0.9 * dim)
                    highColor = Color(red: 0.98, green: 0.97, blue: 0.94).opacity(0.85 * dim)
                } else if case .analysing = d.analysis {
                    lowColor = .white.opacity(0.18)
                    highColor = .white.opacity(0.22)
                } else {
                    lowColor = Color(red: 0.18, green: 0.42, blue: 1.0).opacity(dim)
                    highColor = Color(red: 0.92, green: 0.95, blue: 1.0).opacity(0.9 * dim)
                }
                context.fill(Path(CGRect(x: x, y: size.height / 2 - h, width: 0.85, height: h * 2)), with: .color(lowColor))
                context.fill(Path(CGRect(x: x, y: size.height / 2 - core, width: 0.85, height: core * 2)), with: .color(highColor))
            }
        }
        .accessibilityHidden(true)
    }

    static func amplitude(deck: MixEngine.Deck, bar: Double, leaving: Bool, mix: MacDJMixState?, samples: [Float], analysing: MacDJDeckAnalysis) -> (total: Float, high: Float)? {
        if let mix {
            if leaving, bar > mix.totalBars + 1 { return nil }
            if !leaving, bar < 1 { return nil }
        }
        let seed = deck == .a ? 17.0 : 41.0
        let beatPhase = bar * 4 - (bar * 4).rounded(.down)
        let kick = Float(max(0, 1 - beatPhase * 3.2))
        let hat = Float(abs(beatPhase - 0.5) < 0.08 ? 0.5 : 0.0)
        let noise = Float((sin(bar * 97.3 + seed) + 1) / 2) * 0.12
        var base: Float = samples.isEmpty ? 0.22 : 0.18
        if case .analysing = analysing { base = 0.35 }
        let total = min(0.98, base + kick * 0.72 + noise)
        let high = min(total, 0.06 + hat * 0.25 + noise * 0.5)
        return (total, high)
    }
}
