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
    var loopStartSeconds: Double?
    var loopLengthSeconds: Double?

    init(_ state: MixEngine.DeckState) {
        position = state.position
        duration = state.duration
        isPlaying = state.isPlaying
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

    private var track: Track? { registry.track(for: deck) }

    var body: some View {
        let track = self.track
        let waveformState = track.map { waveforms.state(for: $0.id) } ?? .pending
        let bpm = controller.analysisByDeck[deck.rawValue]?.bpm
        let cues = controller.hotCues[deck.rawValue] ?? []
        MacDeckSlice(deck: deck, read: MacLaneState.init) { lane in
            #if DEBUG
            let _ = MacBodyMeter.count("lane\(deck.label)")
            #endif
            SCWaveformRenderer(
                envelope: macEnvelope(waveformState),
                duration: lane.duration,
                progress: lane.progress,
                mode: .centered(windowSeconds: 10),
                showsPlayhead: false,
                beatGrid: bpm.flatMap { $0 > 0 ? SCBeatGrid(bpm: $0) : nil },
                cueMarkers: markers(for: lane, cues: cues),
                placeholder: track == nil ? .unavailable : macPlaceholder(waveformState),
                identity: track?.id,
                style: MacWaveformPalette.detail(for: deck)
            )
            .overlay(alignment: .top) { laneHeader(track: track, lane: lane) }
            .overlay(alignment: .bottomTrailing) { gridBadge(bpm) }
            .overlay {
                if case .failed = waveformState {
                    Text("No waveform").font(.caption2).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func laneHeader(track: Track?, lane: MacLaneState) -> some View {
        HStack(spacing: 6) {
            Text(deck.label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(.black)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint))
            Text(track?.title ?? "No track loaded")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(track == nil ? 0.35 : 0.85))
                .lineLimit(1)
            Spacer(minLength: 8)
            if lane.duration > 0 {
                Text("\(Self.timeString(lane.position))  -\(Self.timeString(max(0, lane.duration - lane.position)))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .shadow(color: .black.opacity(0.8), radius: 2)
        .padding(.horizontal, 6)
        .padding(.top, 5)
    }

    @ViewBuilder
    private func gridBadge(_ bpm: Double?) -> some View {
        if let bpm, bpm > 0 {
            Text("GRID \(String(format: "%.0f", bpm)) BPM (est.)")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
        }
    }

    private func markers(for lane: MacLaneState, cues: [CuePoint]) -> [SCWaveformMarker] {
        guard lane.duration > 0 else { return [] }
        var markers = cues.compactMap { cue -> SCWaveformMarker? in
            guard cue.hotCueIndex != nil else { return nil }
            return SCWaveformMarker(
                id: cue.id,
                position: cue.positionSeconds / lane.duration,
                color: macCueColor(cue)
            )
        }
        if let start = lane.loopStartSeconds {
            markers.append(SCWaveformMarker(id: "loop-in", position: start / lane.duration, color: .white.opacity(0.8)))
            if let length = lane.loopLengthSeconds {
                markers.append(SCWaveformMarker(id: "loop-out", position: (start + length) / lane.duration, color: .white.opacity(0.8)))
            }
        }
        return markers
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

    var body: some View {
        SCWaveformRenderer(
            envelope: macEnvelope(state),
            duration: duration,
            progress: progress,
            mode: .fixed,
            cueMarkers: markers,
            placeholder: macPlaceholder(state),
            identity: trackId,
            style: MacWaveformPalette.overview(for: deck)
        )
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
