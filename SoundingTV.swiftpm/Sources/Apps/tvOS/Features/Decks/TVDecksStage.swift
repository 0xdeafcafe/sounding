import SwiftUI
import QuartzCore

// MARK: - Deck heads

struct TVDeckHeads: View {
    let model: DecksLiveModel
    let accent: Color
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            TVDeckHead(model: model, slot: .onAir, accent: accent, namespace: namespace)
            TVDeckHead(model: model, slot: .next, accent: accent, namespace: namespace)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.7), value: model.onAir.trackId)
    }
}

struct TVDeckHead: View {
    let model: DecksLiveModel
    let slot: DeckSlot
    let accent: Color
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isTrailing: Bool { slot == .next }

    var body: some View {
        let deck = model.deck(slot)
        let presence = slot == .onAir ? 1 - 0.45 * model.blend : 0.55 + 0.45 * model.blend
        HStack(alignment: .top, spacing: 32) {
            if isTrailing {
                Spacer(minLength: 0)
                details(deck)
                artwork(deck)
            } else {
                artwork(deck)
                details(deck)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(deck.isEmpty ? 0.6 : presence)
        .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: presence)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(deck))
    }

    @ViewBuilder
    private func artwork(_ deck: DeckLiveSnapshot) -> some View {
        if let track = deck.track {
            ArtworkImage(url: track.largeArtworkURL ?? track.artworkURL, variant: .hero, identity: track.id)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 248, height: 248)
                .clipShape(RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
                .matchedGeometryEffect(id: "art.\(track.id)", in: namespace)
        } else {
            RoundedRectangle(cornerRadius: Corner.panel, style: .continuous)
                .fill(Color.black.opacity(0.26))
                .overlay {
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 64, weight: .regular))
                        .foregroundStyle(Color.scTextTertiary)
                }
                .frame(width: 248, height: 248)
                .matchedGeometryEffect(id: "art.\(slot.rawValue)", in: namespace)
                .accessibilityHidden(true)
        }
    }

    private func details(_ deck: DeckLiveSnapshot) -> some View {
        VStack(alignment: isTrailing ? .trailing : .leading, spacing: Space.tight) {
            TVDeckRoleLine(model: model, slot: slot, deck: deck, accent: accent)
            Text(deck.track?.title ?? (slot == .onAir ? "Nothing Playing" : "Nothing Up Next"))
                .font(.tvTitle)
                .foregroundStyle(deck.isEmpty ? Color.scTextTertiary : Color.scTextPrimary)
                .lineLimit(2)
                .multilineTextAlignment(isTrailing ? .trailing : .leading)
                .matchedGeometryEffect(id: "title.\(deck.trackId ?? slot.rawValue)", in: namespace)
            if let artist = deck.track?.user.displayName {
                Text(artist)
                    .font(.tvSubheadline)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(1)
            }
            if !deck.isEmpty {
                TVDeckStats(deck: deck, slot: slot, isTrailing: isTrailing)
                    .padding(.top, Space.tight)
            }
        }
        .frame(maxWidth: 560, alignment: isTrailing ? .trailing : .leading)
    }

    private func accessibilityText(_ deck: DeckLiveSnapshot) -> String {
        guard let track = deck.track else { return slot == .onAir ? "Nothing playing" : "Nothing up next" }
        return "\(deck.role.title), \(track.title) by \(track.user.displayName), \(deck.readout.spokenSummary)"
    }
}

private struct TVDeckRoleLine: View {
    let model: DecksLiveModel
    let slot: DeckSlot
    let deck: DeckLiveSnapshot
    let accent: Color

    var body: some View {
        HStack(spacing: Space.snug) {
            Text(deck.role.title.uppercased())
                .font(.tvEyebrow)
                .kerning(1.2)
                .foregroundStyle(roleColor)
            if slot == .next, !deck.isEmpty {
                TVDeckCountdown()
            }
            if deck.isAutoMixOnly {
                Text("Auto Mix only")
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextTertiary)
            }
        }
    }

    private var roleColor: Color {
        switch deck.role {
        case .onAir: return Color.scTextPrimary
        case .mixingIn: return accent
        case .failed: return Color.scWarning
        default: return Color.scTextSecondary
        }
    }
}

private struct TVDeckCountdown: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let state = AutoMixLive.shared.state, state.stage == .upcoming {
            TimelineView(.periodic(from: .now, by: state.isPlaying ? 0.5 : 60)) { context in
                let clock = state.clock(at: state.isPlaying ? context.date : state.anchoredAt)
                Text(clock.barsUntilStart <= 8 && clock.secondsUntilStart > 0 ? clock.countdownText : AutoMixLiveState.countdown(clock.secondsUntilStart))
                    .font(.tvCalloutEmph)
                    .monospacedDigit()
                    .foregroundStyle(clock.barsUntilStart <= 4 ? Color.scTextPrimary : Color.scTextSecondary)
                    .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
            }
        }
    }
}

struct TVDeckStats: View {
    let deck: DeckLiveSnapshot
    let slot: DeckSlot
    let isTrailing: Bool

    var body: some View {
        let tempo = deck.tempo.map { String(format: "%.0f", $0) }
        let estimated = deck.readout.isEstimated && deck.beats == nil
        let hasValues = tempo != nil || deck.readout.key != nil || deck.readout.energyText != nil || deck.beats != nil
        HStack(alignment: .firstTextBaseline, spacing: 44) {
            if hasValues {
                if let tempo {
                    stat(estimated ? "~\(tempo)" : tempo, caption: "BPM")
                }
                if let key = deck.readout.key {
                    stat(key, caption: "Key")
                }
                if slot == .onAir, let beats = deck.beats {
                    TVDeckBeatCounter(anchor: deck.anchor, beats: beats)
                } else if let energy = deck.readout.energyText {
                    stat(energy, caption: "Energy")
                }
            } else {
                HStack(spacing: Space.snug) {
                    if deck.readout.isAnalyzing { ProgressView() }
                    Text(deck.readout.isAnalyzing ? "Analysing…" : (AnalysisStatusCopy.gate(.unsupported, device: .tv) ?? ""))
                        .font(.tvCallout)
                        .foregroundStyle(Color.scTextSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(isTrailing ? .trailing : .leading)
                }
                .frame(height: 92)
            }
        }
    }

    private func stat(_ value: String, caption: String) -> some View {
        VStack(alignment: isTrailing ? .trailing : .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 60, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.scTextPrimary)
                .lineLimit(1)
            Text(caption)
                .font(.tvCaption)
                .foregroundStyle(Color.scTextTertiary)
        }
    }
}

struct TVDeckBeatCounter: View {
    let anchor: DeckAnchor
    let beats: DeckBeatClock

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(DeckBeatSchedule(anchor: anchor, beats: beats)) { context in
            let host = CACurrentMediaTime() + context.date.timeIntervalSinceNow
            let reading = beats.reading(at: anchor.position(at: host))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(reading.map { "\($0.barInPhrase)/\(beats.barsPerPhrase)" } ?? "–")
                        .font(.system(size: 60, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.scTextPrimary)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    HStack(spacing: 8) {
                        ForEach(1...beats.beatsPerBar, id: \.self) { beat in
                            Circle()
                                .fill(Color.white.opacity((reading?.beatInBar ?? 0) >= beat ? 0.95 : 0.22))
                                .frame(width: 14, height: 14)
                        }
                    }
                }
                Text(reading.map { "Bar · Phrase \($0.phrase)" } ?? "Bar")
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextTertiary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(reading.map { "Bar \($0.barInPhrase) of \(beats.barsPerPhrase), phrase \($0.phrase)" } ?? "Before the first bar")
        }
    }
}

struct DeckBeatSchedule: TimelineSchedule {
    let anchor: DeckAnchor
    let beats: DeckBeatClock

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        let host = CACurrentMediaTime() + startDate.timeIntervalSinceNow
        let position = anchor.position(at: host)
        guard anchor.rate > 0 else { return Entries(first: startDate, step: 0) }
        let next = beats.nextBeat(after: position)
        let first = startDate.addingTimeInterval((next - position) / anchor.rate + 0.01)
        let step = beats.beatPeriod / anchor.rate
        return Entries(first: startDate, then: first, step: mode == .lowFrequency ? step * 4 : step)
    }

    struct Entries: Sequence, IteratorProtocol {
        private var pending: [Date]
        private var cursor: Date?
        private let step: TimeInterval

        init(first: Date, step: TimeInterval) {
            pending = [first]
            cursor = nil
            self.step = step
        }

        init(first: Date, then next: Date, step: TimeInterval) {
            pending = [first]
            cursor = next
            self.step = step
        }

        mutating func next() -> Date? {
            if !pending.isEmpty { return pending.removeFirst() }
            guard let cursor, step > 0.05 else { return nil }
            self.cursor = cursor.addingTimeInterval(step)
            return cursor
        }
    }
}

// MARK: - Lanes

struct TVDeckLane: View {
    let model: DecksLiveModel
    let slot: DeckSlot
    let accent: Color
    let isShowing: Bool
    var focus: FocusState<TVDecksFocus?>.Binding
    let onPickNext: () -> Void

    @State private var sweep: Double?
    @State private var jogStart: TimeInterval?
    @State private var jogBeats = 0

    static let height: CGFloat = 132

    var body: some View {
        let deck = model.deck(slot)
        let isFocused = focus.wrappedValue == .lane(slot)
        Button(action: primary) {
            TVDeckWave(deck: deck, slot: slot, accent: accent, presence: presence)
                .frame(height: Self.height)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
                .overlay(alignment: .topLeading) { tag(deck) }
                .overlay(alignment: .bottomLeading) {
                    if isFocused, !isShowing { hint(deck) }
                }
        }
        .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.panel, sizeClass: .hero))
        .focused(focus, equals: .lane(slot))
        .disabled(isShowing)
        .background(
            TVDecksTouchSurface(
                isActive: isFocused && !isShowing && (model.canPerform(on: slot) || model.canJog(slot)),
                onBegan: { began(deck) },
                onChanged: { changed($0) },
                onEnded: ended
            )
            .allowsHitTesting(false)
        )
        .contextMenu { menu(deck) }
        .accessibilityLabel(slot == .onAir ? "On Air deck" : "Next deck")
        .accessibilityValue(deck.track.map { "\($0.title), \(deck.role.title)" } ?? "Empty")
        .accessibilityHint(accessibilityHint(deck))
        .accessibilityIdentifier(slot == .onAir ? "decks.deck.A" : "decks.deck.B")
    }

    private var presence: Double {
        slot == .onAir ? 1 - 0.6 * model.blend : 0.4 + 0.6 * model.blend
    }

    private func primary() {
        switch slot {
        case .onAir:
            model.togglePlayPause()
        case .next:
            if model.canMixNow { model.mixNow() } else if !model.isMixing { onPickNext() }
        }
    }

    @ViewBuilder
    private func tag(_ deck: DeckLiveSnapshot) -> some View {
        if let text = liveTag(deck) {
            Text(text)
                .font(.tvCaptionEmph)
                .monospacedDigit()
                .foregroundStyle(Color.scChromeFocusOn)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(Capsule().fill(Color.scChromeFocus))
                .padding(16)
                .transition(.opacity)
        }
    }

    private func liveTag(_ deck: DeckLiveSnapshot) -> String? {
        if let sweep { return DecksFilterSweep.label(for: sweep) ?? "Filter open" }
        if jogStart != nil { return jogBeats == 0 ? "Jog" : String(format: "%+d beats", jogBeats) }
        if let filter = deck.filterLabel { return filter }
        if let loop = deck.loop, let beats = deck.beats {
            let bars = (loop.upperBound - loop.lowerBound) / beats.barSeconds
            return bars >= 1 ? "Loop \(Int(bars.rounded())) bar\(bars.rounded() == 1 ? "" : "s")" : "Loop"
        }
        return nil
    }

    private func hint(_ deck: DeckLiveSnapshot) -> some View {
        Text(hintText(deck))
            .font(.tvCaption)
            .foregroundStyle(Color.scTextSecondary)
            .shadow(color: .black.opacity(0.8), radius: 6)
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
            .transition(.opacity)
    }

    private func hintText(_ deck: DeckLiveSnapshot) -> String {
        if deck.isAutoMixOnly { return "Go+ unlocks the filter and loops for SoundCloud tracks." }
        switch slot {
        case .onAir:
            if model.canJog(.onAir) { return "Swipe to move by beats · Click to play" }
            return model.canPerform(on: .onAir) ? "Swipe to sweep the filter · Click to pause · Hold for loops" : "Click to play or pause"
        case .next:
            if model.canMixNow { return "Click to mix in now · Swipe to sweep its filter" }
            return model.isMixing ? "Swipe to sweep the filter" : "Click to choose what plays next"
        }
    }

    private func accessibilityHint(_ deck: DeckLiveSnapshot) -> String {
        switch slot {
        case .onAir: return "Plays or pauses. Swipe left or right to sweep the filter."
        case .next: return model.canMixNow ? "Mixes into this track now." : "Chooses what plays next."
        }
    }

    @ViewBuilder
    private func menu(_ deck: DeckLiveSnapshot) -> some View {
        switch slot {
        case .onAir:
            if deck.loop == nil {
                Button("Loop 4 Bars", systemImage: "repeat") { model.loop(beats: 16) }
                    .disabled(!model.canPerform(on: .onAir) || deck.beats == nil)
                Button("Loop 1 Bar", systemImage: "repeat.1") { model.loop(beats: 4) }
                    .disabled(!model.canPerform(on: .onAir) || deck.beats == nil)
            } else {
                Button("Exit Loop", systemImage: "repeat") { model.exitLoop() }
            }
            if !model.owned.isEmpty {
                Button("Hand Back", systemImage: "hand.raised") { model.handBack() }
            }
        case .next:
            Button("Mix Now", systemImage: "arrow.triangle.merge") { model.mixNow() }
                .disabled(!model.canMixNow)
            Button("Choose a Different Track…", systemImage: "text.badge.plus", action: onPickNext)
        }
    }

    private func began(_ deck: DeckLiveSnapshot) {
        if model.canJog(slot) {
            jogStart = deck.anchor.position(at: CACurrentMediaTime())
            jogBeats = 0
        } else {
            sweep = 0
        }
    }

    private func changed(_ translation: CGFloat) {
        if let start = jogStart {
            let beats = Int((translation / 70).rounded())
            guard beats != jogBeats else { return }
            jogBeats = beats
            model.jog(from: start, beats: Double(beats))
            return
        }
        let amount = min(1, max(-1, Double(translation / 560)))
        sweep = DecksLiveModel.quantised(amount, step: 0.01)
        model.sweepFilter(slot, to: amount)
    }

    private func ended() {
        if jogStart != nil {
            jogStart = nil
            jogBeats = 0
            return
        }
        guard sweep != nil else { return }
        sweep = nil
        model.releaseFilter(slot)
    }
}

struct TVDeckWave: View {
    let deck: DeckLiveSnapshot
    let slot: DeckSlot
    let accent: Color
    let presence: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let visibleBeats: Double = 32
    static let fallbackWindow: TimeInterval = 16

    var body: some View {
        if let source, MetalWaveformView.isSupported {
            if reduceMotion, deck.anchor.rate > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    metal(source, position: deck.anchor.position(at: CACurrentMediaTime()), rate: 0)
                }
            } else {
                metal(source, position: deck.anchor.position, rate: deck.anchor.rate, host: deck.anchor.hostTime)
            }
        } else {
            placeholder
        }
    }

    private var source: MetalWaveformSource? {
        guard let track = deck.track, deck.hasWaveform,
              let samples = WaveformService.shared.state(for: track.id).waveform?.samples, !samples.isEmpty else { return nil }
        return MetalWaveformSourceCache.shared.envelope(id: track.id, samples: samples, duration: max(1, deck.duration))
    }

    private func metal(_ source: MetalWaveformSource, position: TimeInterval, rate: Double, host: CFTimeInterval = CACurrentMediaTime()) -> some View {
        MetalWaveformView(
            source: source,
            timeline: .following(
                anchor: position,
                hostTime: host,
                rate: rate,
                window: window,
                playheadFraction: 0.5
            ),
            grid: deck.beats.map {
                MetalWaveformBeatGrid(bpm: $0.bpm, firstBeatSeconds: $0.phraseStart, beatsPerBar: $0.beatsPerBar, barsPerPhrase: $0.barsPerPhrase)
            },
            overlays: overlays,
            style: style
        )
        .allowsHitTesting(false)
    }

    private var window: TimeInterval {
        guard let beats = deck.beats else { return Self.fallbackWindow }
        return Self.visibleBeats * beats.beatPeriod
    }

    private var overlays: [MetalWaveformOverlay] {
        var out: [MetalWaveformOverlay] = []
        let ink = SIMD4<Float>(1, 1, 1, 1)
        if let window = deck.mixWindow {
            out.append(MetalWaveformOverlay(id: "mix", kind: .region(window), color: SIMD4(1, 1, 1, 0.07)))
            out.append(MetalWaveformOverlay(id: "mix.start", kind: .cue(window.lowerBound), color: ink))
        }
        if let entry = deck.entry, slot == .next {
            out.append(MetalWaveformOverlay(id: "entry", kind: .cue(entry), color: SIMD4(accent)))
        }
        if let loop = deck.loop {
            out.append(MetalWaveformOverlay(id: "loop", kind: .loop(loop), color: SIMD4(accent)))
        }
        return out
    }

    private var style: MetalWaveformStyle {
        let level = Float(max(0.25, min(1, presence)))
        let base: SIMD4<Float> = slot == .next ? SIMD4(accent) : SIMD4(1, 1, 1, 1)
        var style = MetalWaveformStyle.mono(SIMD4(base.x, base.y, base.z, 0.95 * level))
        style.playedTint = SIMD4(1, 1, 1, 1)
        style.unplayedTint = SIMD4(1, 1, 1, 0.55)
        style.playheadColor = SIMD4(1, 1, 1, 0.95)
        style.playheadWidth = 3
        style.beatColor = SIMD4(1, 1, 1, 0.08)
        style.barColor = SIMD4(1, 1, 1, 0.2)
        style.phraseColor = SIMD4(1, 1, 1, 0.45)
        return style
    }

    private var placeholder: some View {
        ZStack {
            if deck.isEmpty {
                EmptyView()
            } else if WaveformService.shared.state(for: deck.trackId ?? "").waveform == nil {
                ProgressView()
            }
            Rectangle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Next empty

struct TVDecksNextEmpty: View {
    let model: DecksLiveModel
    let isShowing: Bool
    var focus: FocusState<TVDecksFocus?>.Binding
    let onPickNext: () -> Void

    var body: some View {
        Button(action: onPickNext) {
            VStack(spacing: Space.tight) {
                Label("Choose Next…", systemImage: "text.badge.plus")
                    .font(.tvHeadline)
                    .foregroundStyle(Color.scTextPrimary)
                Text(model.isAutoMixOn ? "Auto Mix picks one if you don't." : "Nothing is queued after this track.")
                    .font(.tvCallout)
                    .foregroundStyle(Color.scTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: TVDeckLane.height)
            .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        }
        .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.panel, sizeClass: .hero))
        .focused(focus, equals: .lane(.next))
        .disabled(isShowing)
        .accessibilityIdentifier("decks.deck.B")
    }
}

// MARK: - Mix band

struct TVDecksMixBand: View {
    let model: DecksLiveModel
    let accent: Color
    var focus: FocusState<TVDecksFocus?>.Binding
    let isShowing: Bool

    static let height: CGFloat = 168

    var body: some View {
        VStack(spacing: Space.snug) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isEngineLive, !model.next.isEmpty {
                AutoMixCrossfader(value: model.crossfade, scale: .tv)
                    .foregroundStyle(Color.scTextPrimary)
                    .frame(maxWidth: 760)
            }
        }
        .padding(.horizontal, Space.section)
        .frame(height: Self.height)
    }

    @ViewBuilder
    private var content: some View {
        if let problem = model.problem {
            HStack(spacing: Space.base) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Decks Can't Mix Right Now").font(.tvHeadline)
                        Text(problem).font(.tvCallout).foregroundStyle(Color.scTextSecondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.scWarning)
                }
                Button("Try Again", systemImage: "arrow.clockwise") {
                    PlayerService.shared.armMixSessionIfNeeded()
                }
                .buttonStyle(TVDecksChromeStyle())
                .focused(focus, equals: .retry)
                .disabled(isShowing)
            }
        } else if let state = AutoMixLive.shared.state {
            AutoMixTransitionView(state: state, scale: .tv, tint: accent)
                .foregroundStyle(Color.scTextPrimary)
                .transition(.opacity)
        } else {
            VStack(spacing: Space.hair) {
                Text(model.status.label)
                    .font(.tvHeadline)
                    .foregroundStyle(Color.scTextPrimary)
                Text(model.status.note)
                    .font(.tvCallout)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
