import QuartzCore
import SwiftUI

enum MacWaveformPalette {
    struct Lane {
        let outer: Color
        let mid: Color
        let inner: Color
        let rest: Color
    }

    static let deckA = Lane(
        outer: Color(red: 0.45, green: 0.20, blue: 0.05),
        mid: Color(red: 1.00, green: 0.52, blue: 0.16),
        inner: Color(red: 1.00, green: 0.86, blue: 0.60),
        rest: Color(red: 0.30, green: 0.15, blue: 0.06)
    )

    static let deckB = Lane(
        outer: Color(red: 0.17, green: 0.15, blue: 0.48),
        mid: Color(red: 0.55, green: 0.52, blue: 1.00),
        inner: Color(red: 0.87, green: 0.86, blue: 1.00),
        rest: Color(red: 0.13, green: 0.12, blue: 0.34)
    )

    static func detail(for deck: MixEngine.Deck) -> SCWaveformStyle {
        deck == .a ? detailA : detailB
    }

    static func overview(for deck: MixEngine.Deck) -> SCWaveformStyle {
        deck == .a ? overviewA : overviewB
    }

    private static let detailA = detailStyle(deckA)
    private static let detailB = detailStyle(deckB)
    private static let overviewA = overviewStyle(deckA)
    private static let overviewB = overviewStyle(deckB)

    static func metalDetail(for deck: MixEngine.Deck) -> MetalWaveformStyle {
        deck == .a ? metalDetailA : metalDetailB
    }

    static func metalOverview(for deck: MixEngine.Deck) -> MetalWaveformStyle {
        deck == .a ? metalOverviewA : metalOverviewB
    }

    private static let metalDetailA = metalDetailStyle(deckA)
    private static let metalDetailB = metalDetailStyle(deckB)
    private static let metalOverviewA = metalOverviewStyle(deckA)
    private static let metalOverviewB = metalOverviewStyle(deckB)

    private static func metalDetailStyle(_ lane: Lane) -> MetalWaveformStyle {
        var style = MetalWaveformStyle.mono(SIMD4(lane.mid))
        style.playheadWidth = 0
        style.highColor = SIMD4(lane.inner)
        return style
    }

    private static func metalOverviewStyle(_ lane: Lane) -> MetalWaveformStyle {
        var style = MetalWaveformStyle.mono(SIMD4(1, 1, 1, 1))
        style.playedTint = SIMD4(lane.mid)
        style.unplayedTint = SIMD4(lane.rest)
        style.playheadColor = SIMD4(lane.inner)
        style.playheadWidth = 1.5
        style.verticalScale = 0.86
        return style
    }

    private static func detailStyle(_ lane: Lane) -> SCWaveformStyle {
        var style = SCWaveformStyle.decks
        let shells = [lane.outer, lane.mid, lane.inner]
        style.unplayedShellColors = shells
        style.playedShellColors = shells
        style.playheadColor = .white.opacity(0.95)
        style.playheadWidth = 2
        style.barPitch = 1.5
        style.barGap = 0.5
        return style
    }

    private static func overviewStyle(_ lane: Lane) -> SCWaveformStyle {
        var style = SCWaveformStyle.decks
        style.shellDepths = [1.0]
        style.unplayedShellColors = [lane.rest]
        style.playedShellColors = [lane.mid]
        style.playheadColor = lane.inner
        style.playheadWidth = 1.5
        style.barPitch = 1.5
        style.barGap = 0.5
        return style
    }
}

func macCueColor(_ cue: CuePoint) -> Color {
    Color(
        red: Double(cue.color.red) / 255,
        green: Double(cue.color.green) / 255,
        blue: Double(cue.color.blue) / 255
    )
}

private func macEnvelope(_ state: WaveformState) -> [Float] {
    guard case .ready(let waveform) = state else { return [] }
    return waveform.samples
}

private func macPlaceholder(_ state: WaveformState) -> SCWaveformPlaceholder {
    switch state {
    case .pending, .loading:   return .loading
    case .ready(let waveform): return waveform.isEmpty ? .unavailable : .loading
    case .failed:              return .unavailable
    }
}

struct MacLaneState: Equatable {
    var position: TimeInterval
    var duration: TimeInterval
    var isPlaying: Bool
    var rate: Double
    var loopStartSeconds: Double?
    var loopLengthSeconds: Double?

    init(_ state: MixEngine.DeckState) {
        position = state.position
        duration = state.duration
        isPlaying = state.isPlaying
        rate = state.rate
        loopStartSeconds = state.loopStartSeconds
        loopLengthSeconds = state.loopLengthSeconds
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return (position / duration).clampedToUnit
    }
}

struct MacMixLaneStack: View {
    @ObservedObject var controller: MacConsoleController
    let deckATint: Color
    let deckBTint: Color

    var body: some View {
        VStack(spacing: 2) {
            MacMixLane(deck: .a, controller: controller, tint: deckATint)
            MacMixLane(deck: .b, controller: controller, tint: deckBTint)
        }
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(Rectangle().fill(Color.white.opacity(0.92)).frame(width: 2))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct MacMixLane: View {
    let deck: MixEngine.Deck
    @ObservedObject var controller: MacConsoleController
    @ObservedObject var registry = MacDeckTrackRegistry.shared
    @ObservedObject var waveforms = WaveformService.shared
    let tint: Color
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var track: Track? { registry.track(for: deck) }

    var body: some View {
        let track = self.track
        let waveformState = track.map { waveforms.state(for: $0.id) } ?? .pending
        let analysis = controller.analysisByDeck[deck.rawValue]
        let bpm = analysis?.bpm
        let cues = controller.hotCues[deck.rawValue] ?? []
        MacDeckSlice(deck: deck, read: MacLaneState.init) { lane in
            #if DEBUG
            let _ = MacBodyMeter.count("lane\(deck.label)")
            #endif
            laneWaveform(track: track, state: waveformState, lane: lane, bpm: bpm, cues: cues)
            .overlay(alignment: .top) { laneHeader(track: track, lane: lane) }
            .overlay(alignment: .bottomTrailing) { gridBadge(bpm, provenance: analysis?.bpmProvenance) }
            .overlay {
                if case .failed = waveformState {
                    Text("No waveform").font(.caption2).foregroundStyle(contrast.macInk(0.4, increased: 0.85))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Deck \(deck.label) waveform")
            .accessibilityValue(laneAccessibilityValue(track: track, lane: lane, bpm: bpm))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func laneWaveform(track: Track?, state: WaveformState, lane: MacLaneState, bpm: Double?, cues: [CuePoint]) -> some View {
        if let track, lane.duration > 0,
           let source = MetalWaveformSourceCache.shared.envelope(id: track.id, samples: macEnvelope(state), duration: lane.duration) {
            MetalWaveformView(
                source: source,
                timeline: .following(
                    anchor: lane.position, hostTime: CACurrentMediaTime(),
                    rate: lane.isPlaying && !reduceMotion ? lane.rate : 0,
                    window: 10, playheadFraction: 0.5
                ),
                grid: bpm.flatMap { $0 > 0 ? MetalWaveformBeatGrid(bpm: $0) : nil },
                overlays: metalOverlays(for: lane, cues: cues),
                style: MacWaveformPalette.metalDetail(for: deck)
            )
        } else {
            SCWaveformPlaceholderLane(
                placeholder: track == nil ? .unavailable : macPlaceholder(state),
                progress: lane.progress,
                style: MacWaveformPalette.detail(for: deck),
                motionSuppressed: reduceMotion
            )
        }
    }

    private func metalOverlays(for lane: MacLaneState, cues: [CuePoint]) -> [MetalWaveformOverlay] {
        var overlays = cues.compactMap { cue -> MetalWaveformOverlay? in
            guard cue.hotCueIndex != nil else { return nil }
            return MetalWaveformOverlay(id: cue.id, kind: .cue(cue.positionSeconds), color: SIMD4(macCueColor(cue)))
        }
        if let start = lane.loopStartSeconds {
            let end = start + max(0, lane.loopLengthSeconds ?? 0)
            overlays.append(MetalWaveformOverlay(id: "loop", kind: .loop(start ... end), color: SIMD4(1, 1, 1, 0.8)))
        }
        return overlays
    }

    private func laneAccessibilityValue(track: Track?, lane: MacLaneState, bpm: Double?) -> String {
        guard let track else { return "No track loaded" }
        var parts = [track.title]
        if lane.duration > 0 {
            parts.append("\(Self.timeString(lane.position)) of \(Self.timeString(lane.duration))")
        }
        if let bpm, bpm > 0 { parts.append("\(Int(bpm.rounded())) BPM") }
        parts.append(lane.isPlaying ? "playing" : "paused")
        return parts.joined(separator: ", ")
    }

    private func laneHeader(track: Track?, lane: MacLaneState) -> some View {
        HStack(spacing: 6) {
            Text(deck.label)
                .font(Font.caption2.monospaced().weight(.black))
                .foregroundStyle(.black)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint))
            Text(track?.title ?? "No track loaded")
                .font(Font.caption2.weight(.semibold))
                .foregroundStyle(track == nil ? contrast.macInk(0.35, increased: 0.8) : contrast.macInk(0.85, increased: 1))
                .lineLimit(1)
            Spacer(minLength: 8)
            if lane.duration > 0 {
                Text("\(Self.timeString(lane.position))  -\(Self.timeString(max(0, lane.duration - lane.position)))")
                    .font(Font.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(contrast.macInk(0.75, increased: 1))
            }
        }
        .shadow(color: .black.opacity(0.8), radius: 2)
        .padding(.horizontal, 6)
        .padding(.top, 5)
    }

    @ViewBuilder
    private func gridBadge(_ bpm: Double?, provenance: SCAnalysisProvenance?) -> some View {
        if let bpm, bpm > 0 {
            let suffix = provenance == .measured ? "" : " (est.)"
            Text("GRID \(String(format: "%.0f", bpm)) BPM\(suffix)")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(contrast.macInk(0.5, increased: 0.85))
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
        }
    }

    private static func timeString(_ time: TimeInterval) -> String {
        let total = Int(time.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct MacWaveformOverview: View {
    let state: WaveformState
    let progress: Double
    var duration: TimeInterval = 0
    var trackId: String?
    var deck: MixEngine.Deck = .a
    var markers: [SCWaveformMarker] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if duration > 0,
               let source = MetalWaveformSourceCache.shared.envelope(id: trackId ?? "overview", samples: macEnvelope(state), duration: duration) {
                MetalWaveformView(
                    source: source,
                    timeline: .range(0 ... duration, playhead: progress * duration),
                    overlays: markers.map { MetalWaveformOverlay(id: $0.id, kind: .cue($0.position * duration), color: SIMD4($0.color ?? .white)) },
                    style: MacWaveformPalette.metalOverview(for: deck)
                )
            } else {
                SCWaveformPlaceholderLane(
                    placeholder: macPlaceholder(state),
                    progress: progress,
                    style: MacWaveformPalette.overview(for: deck),
                    motionSuppressed: reduceMotion
                )
            }
        }
        .overlay {
            if case .failed = state {
                Text("No waveform").font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

extension Double {
    var clampedToUnit: Double { min(1, max(0, self)) }

    func macClamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
