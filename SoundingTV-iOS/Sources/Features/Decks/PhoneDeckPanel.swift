import SwiftUI

struct PhoneDeckMetrics {
    var artwork: CGFloat
    var button: CGFloat
    var padHeight: CGFloat
    var tempoKnob: CGFloat
    var knob: CGFloat
    var knobRow: CGFloat
    var spacing: CGFloat
    var title: Font
    var readout: Font

    static let compact = PhoneDeckMetrics(artwork: 36, button: 44, padHeight: 48, tempoKnob: 40, knob: 44, knobRow: 50, spacing: 8, title: .subheadline.weight(.semibold), readout: .title3.weight(.semibold).monospacedDigit())
    static let regular = PhoneDeckMetrics(artwork: 56, button: 56, padHeight: 60, tempoKnob: 48, knob: 50, knobRow: 60, spacing: 12, title: .headline, readout: .title2.weight(.semibold).monospacedDigit())
}

struct PhoneDeckPanel: View {
    let deck: MixEngine.Deck
    let state: MacDJPerformState
    @ObservedObject var model: PhoneDecksModel
    var metrics: PhoneDeckMetrics = .compact
    var mirrored = false
    var showsTempoLabel = true
    let onLoad: () -> Void
    var onTempoKey: (Track) -> Void = { _ in }

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var cueHeld = false
    @State private var isDropTarget = false

    private var d: MacDJDeckState { state.deck(deck) }
    private var tempoControl: MixControl { MixControl(.tempo, deck: deck) }

    var body: some View {
        Group {
            if let problem = d.problem {
                problemView(problem)
            } else if d.isEmpty {
                ContentUnavailableView {
                    Label("Deck \(deck.label) Is Empty", systemImage: "opticaldisc")
                } description: {
                    if metrics.button > PhoneDeckMetrics.compact.button {
                        Text("Drop a track here, or choose one.")
                    }
                } actions: {
                    Button("Load Track\u{2026}", action: onLoad).buttonStyle(.glass)
                }
                .controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: metrics.spacing) {
                    header
                    transport
                    if d.isViewOnly {
                        viewOnlyNote
                    } else {
                        pads
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(MacDJPalette.deck(deck), lineWidth: 2)
                    .padding(-6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: SoundingDrop.self) { items, _ in
            guard let track = items.lazy.compactMap(\.tracks.first).first else { return false }
            model.load(track, onto: deck)
            return true
        } isTargeted: { isDropTarget = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deck \(deck.label)")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if mirrored {
                readout
                Spacer(minLength: 4)
                titles
                artwork
            } else {
                artwork
                titles
                Spacer(minLength: 4)
                readout
            }
        }
        .contentShape(Rectangle())
        .contextMenu { deckMenu }
        .accessibilityElement(children: .combine)
        .accessibilityValue([d.remainingText.isEmpty ? nil : "\(d.remainingText) left", d.statusTitle].compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder
    private var deckMenu: some View {
        Button("Load Another Track\u{2026}", systemImage: "square.and.arrow.down", action: onLoad)
        if let track = model.track(on: deck) {
            TrackTempoKeyMenuItems(track: track) { onTempoKey($0) }
        }
        if model.canEject(deck) {
            Button("Eject", systemImage: "eject") { model.eject(deck) }
        }
    }

    private var titles: some View {
        VStack(alignment: mirrored ? .trailing : .leading, spacing: 2) {
            HStack(spacing: 5) {
                if !mirrored { MacDJDeckBadge(deck: deck, size: 16) }
                Text(d.title).font(metrics.title).lineLimit(1)
                if mirrored { MacDJDeckBadge(deck: deck, size: 16) }
            }
            HStack(spacing: 5) {
                if mirrored { Text(d.artist).lineLimit(1) }
                chip
                if d.isSoundCloud { Image(systemName: "cloud").imageScale(.small) }
                if !mirrored { Text(d.artist).lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(contrast.djInk(0.6))
        }
        .layoutPriority(-1)
    }

    private var readout: some View {
        VStack(alignment: mirrored ? .leading : .trailing, spacing: 2) {
            Text(d.remainingText.isEmpty ? " " : d.remainingText)
                .font(metrics.readout)
            Text(readoutDetail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(contrast.djInk(d.bpm == nil ? 0.85 : 0.6))
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var readoutDetail: String {
        if let status = d.statusTitle { return status }
        return [d.bpm == nil ? nil : "\(d.bpmText) BPM", d.key].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private var artwork: some View {
        ArtworkImage(url: d.artworkURL, variant: .thumbnail, identity: d.trackId)
            .frame(width: metrics.artwork, height: metrics.artwork)
            .clipShape(RoundedRectangle(cornerRadius: metrics.artwork * 0.2, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var chip: some View {
        if d.isViewOnly {
            MacDJChip(kind: .autoMixOnly)
        } else {
            switch d.role {
            case .onAir: MacDJChip(kind: .onAir)
            case .mixingIn: MacDJChip(kind: .mixingIn)
            case .idle: EmptyView()
            }
        }
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 8) {
            if mirrored {
                tempo
                Spacer(minLength: 0)
                syncButton
                playButton
                cueButton
            } else {
                cueButton
                playButton
                syncButton
                Spacer(minLength: 0)
                tempo
            }
        }
        .disabled(d.isViewOnly)
        .opacity(d.isViewOnly ? 0.4 : 1)
    }

    private var cueButton: some View {
        Text("CUE")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: metrics.button, height: metrics.button)
            .background(Circle().fill(.white.opacity(cueHeld ? 0.26 : 0.08)).overlay(Circle().strokeBorder(.white.opacity(contrast == .increased ? 0.5 : 0.16), lineWidth: 0.5)))
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !cueHeld else { return }
                    cueHeld = true
                    DeckHaptics.press()
                    model.press(.cue, on: deck, isDown: true)
                }
                .onEnded { _ in
                    cueHeld = false
                    model.press(.cue, on: deck, isDown: false)
                })
            .accessibilityElement()
            .accessibilityLabel("Cue")
            .accessibilityHint(d.isPlaying ? "Returns to the cue point" : "Hold to preview from here")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                model.press(.cue, on: deck, isDown: true)
                model.press(.cue, on: deck, isDown: false)
            }
    }

    private var playButton: some View {
        Button {
            DeckHaptics.press()
            model.press(.play, on: deck)
        } label: {
            Image(systemName: d.isPlaying ? "pause.fill" : "play.fill")
                .font(metrics.button > 44 ? .title3 : .body)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(MacDJControlButtonStyle(tint: MacDJPalette.play, height: metrics.button, shape: .circle))
        .accessibilityLabel(d.isPlaying ? "Pause" : "Play")
    }

    private var syncButton: some View {
        Button {
            model.toggleSync(deck)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(MacDJControlButtonStyle(isOn: d.isSynced, tint: d.isSynced ? MacDJPalette.deck(deck) : nil, height: metrics.button, shape: .circle))
        .disabled(d.bpm == nil)
        .accessibilityLabel("Sync")
        .accessibilityValue(d.isSynced ? "On" : (d.bpm == nil ? "Needs a BPM" : "Off"))
    }

    private var tempo: some View {
        let value = state.value(tempoControl)
        let text = PhoneDecksModel.valueText(.tempo, value: value)
        return HStack(spacing: 6) {
            if mirrored {
                tempoKnob(value: value, text: text)
                if showsTempoLabel { tempoText(text) }
            } else {
                if showsTempoLabel { tempoText(text) }
                tempoKnob(value: value, text: text)
            }
        }
    }

    private func tempoText(_ text: String) -> some View {
        VStack(alignment: mirrored ? .leading : .trailing, spacing: 0) {
            Text("Tempo")
                .font(.caption2)
                .foregroundStyle(contrast.djInk(0.5))
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(contrast.djInk(0.8))
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func tempoKnob(value: Double, text: String) -> some View {
        PhoneDeckKnob(
            value: value,
            isYours: state.ownership(tempoControl) != nil,
            isDisabled: d.isViewOnly || d.isEmpty,
            size: metrics.tempoKnob,
            valueText: text,
            onGrab: { model.grab(tempoControl) },
            onChange: { model.set(tempoControl, to: $0) }
        )
        .accessibilityLabel("Tempo")
    }

    // MARK: Pads

    private var autoLoop: Bool { d.isLooping && state.isAutoMixDriving }

    private var pads: some View {
        HStack(spacing: 6) {
            if !mirrored { loopButton }
            if d.isLooping {
                ForEach(Array([1.0, 2, 4, 8].enumerated()), id: \.offset) { index, bars in
                    let lit = abs(d.loopBars - bars) < 0.01
                    pad(number: "\(index + 1)", label: bars == 1 ? "1 bar" : "\(Int(bars)) bars", color: lit ? MacDJPalette.auto : MacDJPalette.Cue.grey, lit: lit, sparkle: lit && autoLoop) {
                        model.setLoopBars(bars, on: deck)
                    }
                    .accessibilityLabel("Loop \(Self.loopText(bars))")
                    .accessibilityAddTraits(lit ? .isSelected : [])
                }
            } else {
                ForEach(0..<4, id: \.self) { index in
                    hotCuePad(index)
                }
            }
            if mirrored { loopButton }
        }
        .frame(height: metrics.padHeight)
    }

    private func hotCuePad(_ index: Int) -> some View {
        let cue = d.cues.first { $0.index == index }
        let letter = String(UnicodeScalar(UInt8(65 + index)))
        return pad(number: letter, label: cue.map { $0.label.isEmpty ? MacDJPadTime.text($0.seconds) : $0.label } ?? "Set", color: cue?.color ?? MacDJPalette.Cue.grey, lit: false, sparkle: false, isEmpty: cue == nil) {
            model.press(.hotCue, on: deck, index: index)
        }
        .contextMenu {
            if cue != nil {
                Button("Delete Hot Cue \(letter)", systemImage: "trash", role: .destructive) {
                    model.deleteHotCue(index, on: deck)
                }
            }
        }
        .accessibilityLabel("Hot cue \(letter)")
        .accessibilityValue(cue.map { MacDJPadTime.text($0.seconds) } ?? "Empty, sets a cue here")
    }

    private var loopButton: some View {
        Menu {
            Picker("Loop Length", selection: Binding(get: { d.loopBars }, set: { model.setLoopBars($0, on: deck) })) {
                ForEach([0.25, 0.5, 1.0, 2, 4, 8, 16], id: \.self) { bars in
                    Text(Self.loopText(bars)).tag(bars)
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "repeat")
                    .font(.footnote.weight(.semibold))
                Text(Self.loopText(d.loopBars))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(d.isLooping ? (autoLoop ? MacDJPalette.auto : .white) : .white.opacity(0.85))
            .frame(width: metrics.padHeight, height: metrics.padHeight)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                shape.fill(.white.opacity(d.isLooping ? 0.24 : 0.08))
                    .overlay(shape.strokeBorder(d.isLooping ? (autoLoop ? MacDJPalette.auto : .white.opacity(0.5)) : .white.opacity(contrast == .increased ? 0.5 : 0.14), lineWidth: d.isLooping ? 1 : 0.5))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } primaryAction: {
            model.press(.loopToggle, on: deck)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Loop")
        .accessibilityValue(d.isLooping ? "\(Self.loopText(d.loopBars)), on" : Self.loopText(d.loopBars))
        .accessibilityHint("Hold to choose the length")
    }

    static func loopText(_ bars: Double) -> String {
        if bars >= 1 { return bars == 1 ? "1 Bar" : "\(Int(bars)) Bars" }
        let beats = bars * 4
        return beats == 1 ? "1 Beat" : "\(beats.formatted()) Beats"
    }

    private func pad(number: String, label: String, color: Color, lit: Bool, sparkle: Bool, isEmpty: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(number).font(.caption2.weight(.bold)).foregroundStyle(lit ? .white : color)
                    Spacer(minLength: 0)
                    if sparkle { Image(systemName: "sparkle").font(.caption2).foregroundStyle(MacDJPalette.auto) }
                }
                Spacer(minLength: 0)
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isEmpty ? contrast.djInk(0.55) : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                shape.fill(LinearGradient(colors: [color.opacity(lit ? 0.4 : 0.17), color.opacity(lit ? 0.22 : 0.09)], startPoint: .top, endPoint: .bottom))
                    .overlay(shape.strokeBorder(color.opacity(lit ? 1 : (contrast == .increased ? 0.9 : 0.5)), lineWidth: lit ? 1 : 0.5))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var viewOnlyNote: some View {
        Label("Go+ unlocks decks", systemImage: "cloud")
            .font(.footnote)
            .foregroundStyle(contrast.djInk(0.6))
            .frame(maxWidth: .infinity, minHeight: metrics.padHeight, alignment: mirrored ? .trailing : .leading)
    }

    // MARK: Problems

    @ViewBuilder
    private func problemView(_ problem: MacDJDeckProblem) -> some View {
        switch problem {
        case .failed(let title, let message):
            ContentUnavailableView {
                Label(title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Choose Another Track", action: onLoad).buttonStyle(.glass)
            }
            .controlSize(.small)
        case .fileMissing(let title, _):
            ContentUnavailableView {
                Label("Can\u{2019}t Play \(title)", systemImage: "doc")
            } actions: {
                Button("Choose Another Track", action: onLoad).buttonStyle(.glass)
            }
            .controlSize(.small)
        }
    }
}

enum MacDJPadTime {
    static func text(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}
