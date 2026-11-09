import SwiftUI

struct MacDJDeckView: View {
    let deck: MixEngine.Deck
    let state: MacDJPerformState
    let usesCanvas: Bool
    @ObservedObject var model: MacDJPerformModel

    @Environment(\.colorSchemeContrast) private var contrast

    private var d: MacDJDeckState { state.deck(deck) }
    private var layout: MacDJPerformLayout { model.layout }
    private var console: MacConsoleController { .shared }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > 400
            VStack(alignment: .leading, spacing: 0) {
                if d.isEmpty, d.problem == nil {
                    MacDJEmptyDeck(deck: deck)
                } else {
                    deckBody(wide: wide, width: proxy.size.width)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func deckBody(wide: Bool, width: CGFloat) -> some View {
        header
            .frame(height: 50, alignment: .top)
        infoRow
            .frame(height: 24)
            .padding(.top, 4)
        if let problem = d.problem {
            MacDJDeckProblemView(problem: problem, deck: deck)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .analysing(let progress, let fallback) = d.analysis {
            MacDJAnalysingView(progress: progress, fallbackTitle: fallback, usesCanvas: usesCanvas, deck: d)
                .padding(.top, 10)
            Spacer(minLength: 0)
        } else {
            if layout.showsOverview {
                overview
                    .frame(height: 40)
                    .padding(.top, 8)
            }
            if case .noGrid = d.analysis {
                MacDJNoGridControls(deck: deck)
                    .padding(.top, 10)
                Spacer(minLength: 0)
            } else {
                if layout.showsJog || layout.showsLoopControls || layout.showsTempoFader {
                    transport(wide: wide)
                        .frame(height: wide ? 120 : 100)
                        .padding(.top, 14)
                }
                if d.isViewOnly {
                    sectionsList
                        .padding(.top, 10)
                } else {
                    if layout.showsPads {
                        pads(wide: wide, width: width)
                            .padding(.top, 10)
                    }
                    if layout.showsEffects {
                        DJDeckFXRow(deck: deck)
                            .frame(height: 26)
                            .padding(.top, 8)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var accessibilitySummary: String {
        guard !d.isEmpty else { return "Deck \(deck.label), empty" }
        var parts = ["Deck \(deck.label)", d.title]
        if d.role == .onAir { parts.append("on air") }
        if d.role == .mixingIn { parts.append("mixing in") }
        if !d.remainingText.isEmpty { parts.append("\(d.remainingText) left") }
        if d.isMaster { parts.append("master") }
        return parts.joined(separator: ", ")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if !d.isEmpty {
                SCArtworkResolver(url: d.artworkURL) { image in
                    SCArtwork(image: image, identity: d.trackId ?? "deck\(deck.label)", style: .mac, cornerRadius: 9)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    MacDJDeckBadge(deck: deck)
                    Text(d.isEmpty ? "No Track" : d.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    if d.isSoundCloud { Image(systemName: "cloud") }
                    Text([d.artist, d.source].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                        .lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(contrast.djInk(0.66))
            }
            Spacer(minLength: 8)
            if !d.isEmpty { VStack(alignment: .trailing, spacing: 4) {
                Text(d.bpmText)
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .tracking(-0.4)
                if d.bpm != nil {
                    Text("\(d.pitchText) \u{00B7} BPM")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(contrast.djInk(0.62))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tempo") }
        }
    }

    private var infoRow: some View {
        HStack(spacing: 7) {
            if let key = d.key {
                Text(key)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(d.keyColor)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 30, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(d.keyColor.opacity(0.17)))
                    .accessibilityLabel("Key \(key)")
            }
            Text(d.remainingText)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .fixedSize()
                .layoutPriority(2)
            switch d.role {
            case .onAir: MacDJChip(kind: .onAir)
            case .mixingIn: MacDJChip(kind: .mixingIn)
            case .idle: EmptyView()
            }
            Spacer(minLength: 4)
            if d.isViewOnly {
                MacDJChip(kind: .autoMixOnly)
            } else if case .noGrid = d.analysis {
                MacDJChip(kind: .freeRunning)
            } else if !d.isEmpty {
                ViewThatFits(in: .horizontal) {
                    tempoButtons(compact: false)
                    tempoButtons(compact: true)
                }
                .layoutPriority(1)
            }
        }
    }

    private func tempoButtons(compact: Bool) -> some View {
        HStack(spacing: 7) {
            Button { console.sync(deck) } label: {
                if compact {
                    Image(systemName: "arrow.triangle.2.circlepath").padding(.horizontal, 1)
                } else {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(MacDJControlButtonStyle(isOn: d.isSynced, height: 24))
            .fixedSize()
            .disabled(d.bpm == nil)
            .help(d.bpm == nil ? "Available when the grid is ready" : "Match tempo and phase to the other deck")
            .accessibilityLabel("Sync")
            Button("Master") { model.makeMaster(deck) }
                .buttonStyle(MacDJControlButtonStyle(isOn: d.isMaster, height: 24))
                .fixedSize()
                .help("Tempo master: Sync follows this deck")
                .accessibilityAddTraits(d.isMaster ? .isSelected : [])
        }
        .fixedSize()
    }

    // MARK: Overview

    private var overview: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .topLeading) {
                Group {
                    if usesCanvas || !MetalWaveformView.isSupported {
                        MacDJOverviewCanvas(deck: d)
                    } else if let id = d.trackId, d.duration > 0,
                              let source = MetalWaveformSourceCache.shared.envelope(id: id, samples: d.samples, duration: d.duration) {
                        MetalWaveformView(
                            source: source,
                            timeline: .range(0 ... d.duration, playhead: d.position),
                            overlays: [],
                            style: d.isViewOnly ? .threeBand : MetalWaveformStyle.blue.dimmingPlayed(0.55)
                        )
                    }
                }
                .frame(width: w, height: 24)
                .offset(y: 12)
                ForEach(d.phrases) { phrase in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(phrase.color.opacity(0.85))
                        .frame(width: max(1, (phrase.end - phrase.start) * w - 2), height: 4)
                        .offset(x: phrase.start * w + 1, y: 36)
                }
                if !d.isViewOnly {
                    ForEach(d.cues) { cue in
                        let x = d.duration > 0 ? cue.seconds / d.duration * w : 0
                        Rectangle().fill(cue.color.opacity(0.8)).frame(width: 1, height: 36).offset(x: x)
                        Text(cue.letter)
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 3)
                            .frame(height: 12)
                            .background(UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3).fill(cue.color))
                            .offset(x: x)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard !d.isViewOnly, d.duration > 0, !model.isFixture else { return }
                MixEngine.shared.seek(deck: deck, to: Double(location.x / w) * d.duration)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Deck \(deck.label) overview")
        .accessibilityValue("\(Int(d.progress * 100)) percent played")
    }

    // MARK: Transport

    private func transport(wide: Bool) -> some View {
        let jog: CGFloat = wide ? 120 : 100
        let tempoControl = MixControl(.tempo, deck: deck)
        return HStack(alignment: .top, spacing: 12) {
            if layout.showsJog {
                MacDJJog(deck: d, size: jog)
                    .opacity(d.isViewOnly ? 0.4 : 1)
            }
            if layout.showsLoopControls {
                loopAndTransport(wide: wide)
            }
            Spacer(minLength: 0)
            if layout.showsTempoFader {
                tempoFader(jog: jog, control: tempoControl)
            }
        }
    }

    private func loopAndTransport(wide: Bool) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                Text("Loop")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(contrast.djInk(0.65))
                    .padding(.bottom, 5)
                HStack(spacing: 5) {
                    Button { console.halveLoop(deck) } label: { Image(systemName: "minus") }
                        .buttonStyle(MacDJControlButtonStyle(shape: .circle))
                        .accessibilityLabel("Halve Loop")
                    Button { console.toggleLoop(deck) } label: {
                        HStack(spacing: 4) {
                            if d.isLooping { Image(systemName: "repeat") }
                            Text(MacDJUnits.loopText(d.loopBars))
                        }
                        .frame(minWidth: 52)
                        .fixedSize()
                    }
                    .buttonStyle(MacDJControlButtonStyle(isOn: d.isLooping, tint: d.isLooping ? MacDJPalette.auto : nil))
                    .accessibilityLabel(d.isLooping ? "Loop on, \(MacDJUnits.loopText(d.loopBars))" : "Loop \(MacDJUnits.loopText(d.loopBars))")
                    Button { console.doubleLoop(deck) } label: { Image(systemName: "plus") }
                        .buttonStyle(MacDJControlButtonStyle(shape: .circle))
                        .accessibilityLabel("Double Loop")
                    if wide {
                        Button("In") { MacDeckControlSurface.shared.press(DeckControlAddress(group: .deck(deck), control: .loopIn), isDown: true) }
                            .buttonStyle(MacDJControlButtonStyle())
                        Button("Out") { MacDeckControlSurface.shared.press(DeckControlAddress(group: .deck(deck), control: .loopOut), isDown: true) }
                            .buttonStyle(MacDJControlButtonStyle())
                    }
                }
                HStack(spacing: 8) {
                    Button("CUE") {}
                        .font(.system(size: 11, weight: .bold))
                        .buttonStyle(MacDJCueButtonStyle(deck: deck))
                    Button { console.togglePlayPause(deck) } label: {
                        Image(systemName: d.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MacDJPalette.play)
                    }
                    .buttonStyle(MacDJControlButtonStyle(height: 42, shape: .circle))
                    .accessibilityLabel(d.isPlaying ? "Pause Deck \(deck.label)" : "Play Deck \(deck.label)")
                    if wide, let title = d.statusTitle {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.system(size: 11)).foregroundStyle(contrast.djInk(0.62))
                            if let detail = d.statusDetail {
                                Text(detail).font(.system(size: 12)).lineLimit(1)
                            }
                        }
                        .padding(.leading, 8)
                    }
                }
                .padding(.top, 13)
            }
            .disabled(d.isViewOnly)
            .opacity(d.isViewOnly ? 0.35 : 1)
    }

    private func tempoFader(jog: CGFloat, control tempoControl: MixControl) -> some View {
            VStack(spacing: 2) {
                MacDJVerticalFader(
                    value: (d.tempo + 1) / 2,
                    target: state.targets[tempoControl]?.value,
                    isYours: state.ownership(tempoControl) != nil,
                    isDisabled: d.isViewOnly,
                    height: jog - 24,
                    centreDetent: true,
                    onGrab: { model.grab(tempoControl) },
                    onChange: { model.set(tempoControl, to: $0) }
                )
                .frame(width: 30)
                .accessibilityLabel("Tempo, Deck \(deck.label)")
                Text("\u{00B1}16%")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(contrast.djInk(0.62))
            }
            .opacity(d.isViewOnly ? 0.35 : 1)
    }

    // MARK: Pads

    private func pads(wide: Bool, width: CGFloat) -> some View {
        let mode = model.padModes[deck] ?? .hotCue
        let padWidth = (width - 18) / 4
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                MacDJSegmented(
                    options: MacDJPadMode.allCases.map { ($0, $0.rawValue) },
                    selection: Binding(get: { mode }, set: { model.padModes[deck] = $0 }),
                    height: 20,
                    spacing: wide ? 10 : 6
                )
                .accessibilityLabel("Pad Mode")
                Spacer()
                if wide, let note = d.padNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(contrast.djInk(0.62))
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(padWidth), spacing: 6), count: 4), spacing: 6) {
                ForEach(0..<8, id: \.self) { index in
                    MacDJPad(content: padContent(mode: mode, index: index)) {
                        tapPad(mode: mode, index: index)
                    }
                    .frame(height: 46)
                }
            }
        }
    }

    private func padContent(mode: MacDJPadMode, index: Int) -> MacDJPad.Content {
        switch mode {
        case .hotCue:
            guard let cue = d.cues.first(where: { $0.index == index }) else {
                return .empty(number: String(UnicodeScalar(UInt8(65 + index))))
            }
            return .cue(letter: cue.letter, label: cue.label.isEmpty ? "Cue \(cue.letter)" : cue.label, time: MacDJUnits.time(cue.seconds), color: cue.color)
        case .loop, .roll:
            let sizes = mode == .loop ? Self.loopSizes : Self.rollSizes
            let bars = sizes[index]
            let lit = d.isLooping && abs(d.loopBars - bars) < 0.001
            return .size(number: "\(index + 1)", value: Self.fraction(bars), unit: Self.unit(bars), isLit: lit && mode == .loop, isAuto: lit && state.isAutoMixDriving)
        case .beatJump:
            let jumps = [-1.0, 1, -4, 4, -16, 16, -32, 32]
            let beats = jumps[index]
            return .size(number: "\(index + 1)", value: (beats > 0 ? "+" : "\u{2212}") + "\(Int(abs(beats)))", unit: abs(beats) == 1 ? "beat" : "beats", isLit: false, isAuto: false)
        }
    }

    static let loopSizes = [0.0625, 0.125, 0.25, 0.5, 4, 8, 16, 32]
    static let rollSizes = [0.03125, 0.0625, 0.125, 0.25, 0.5, 1, 2, 4]

    private static func fraction(_ bars: Double) -> String {
        if bars >= 1 { return "\(Int(bars))" }
        let beats = bars * 4
        if beats >= 1 { return "\(Int(beats))" }
        return "1/\(Int((1 / beats).rounded()))"
    }

    private static func unit(_ bars: Double) -> String {
        if bars >= 1 { return bars == 1 ? "bar" : "bars" }
        return bars * 4 > 1 ? "beats" : "beat"
    }

    private func tapPad(mode: MacDJPadMode, index: Int) {
        guard !model.isFixture else { return }
        let engine = MixEngine.shared
        switch mode {
        case .hotCue:
            console.hotCue(deck, index: index)
        case .loop, .roll:
            let sizes = mode == .loop ? Self.loopSizes : Self.rollSizes
            guard let bar = d.barSeconds else { return }
            console.loopSeconds[deck.rawValue] = sizes[index] * bar
            engine.setLoop(on: deck, startSeconds: engine[deck].position, lengthSeconds: sizes[index] * bar)
        case .beatJump:
            let jumps = [-1.0, 1, -4, 4, -16, 16, -32, 32]
            guard let bar = d.barSeconds else { return }
            engine.seek(deck: deck, byNudging: jumps[index] * bar / 4)
        }
    }

    // MARK: Read-only sections

    private var sectionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sections")
                Spacer()
                Label("Follows Auto Mix", systemImage: "cloud")
                    .fontWeight(.medium)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(contrast.djInk(0.65))
            .padding(.bottom, 5)
            ForEach(d.sections) { section in
                HStack(spacing: 8) {
                    Circle().fill(section.color).frame(width: 8, height: 8)
                    Text(section.name)
                    if section.hasVocals {
                        Text("\u{00B7} vocals").foregroundStyle(contrast.djInk(0.58))
                    }
                    Spacer()
                    Text("\(section.firstBar)\u{2013}\(section.lastBar)")
                        .monospacedDigit()
                        .foregroundStyle(contrast.djInk(0.58))
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(section.isPast ? 0.55 : 0.9))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(section.isCurrent ? .white.opacity(0.08) : .clear))
            }
            if let note = d.viewOnlyNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(contrast.djInk(0.62))
                    .padding(.top, 6)
            }
        }
    }
}

struct MacDJEmptyDeck: View {
    let deck: MixEngine.Deck

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                MacDJDeckBadge(deck: deck)
                Text("Deck \(deck.label)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 22)
            ContentUnavailableView {
                Label("No Track", systemImage: "square.and.arrow.down")
            } description: {
                Text("Drag a track here, or load one from your library.")
            } actions: {
                Button("Load Track\u{2026}") { MacConsoleController.shared.loadTarget = deck }
                    .buttonStyle(.bordered)
                    .help("Choose a track for Deck \(deck.label)")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(.white.opacity(0.025)))
            .overlay(shape.strokeBorder(.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deck \(deck.label), empty")
    }
}

struct MacDJDeckDropZone<Content: View>: View {
    let content: () -> Content
    let onDrop: (String) -> Void
    @State private var isTargeted = false

    init(@ViewBuilder content: @escaping () -> Content, onDrop: @escaping (String) -> Void) {
        self.content = content
        self.onDrop = onDrop
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content()
            .overlay {
                if isTargeted {
                    shape
                        .fill(Color.scAccent.opacity(0.08))
                        .overlay(shape.strokeBorder(Color.scAccent, lineWidth: 2))
                        .padding(-6)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                onDrop(id)
                return true
            } isTargeted: { isTargeted = $0 }
    }
}

struct MacDJCueButtonStyle: ButtonStyle {
    let deck: MixEngine.Deck

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tracking(0.4)
            .frame(width: 42, height: 42)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .contentShape(Circle())
            .onChange(of: configuration.isPressed) { _, pressed in
                pressed ? MacConsoleController.shared.cueDown(deck) : MacConsoleController.shared.cueUp(deck)
            }
    }
}

struct MacDJJog: View {
    let deck: MacDJDeckState
    let size: CGFloat

    var body: some View {
        let ring = deck.isViewOnly ? Color.white.opacity(0.3) : MacDJPalette.deck(deck.deck)
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: 3.5).padding(1.75)
            Circle()
                .trim(from: 0, to: deck.progress)
                .rotation(.degrees(-90))
                .stroke(ring, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: deck.deck == .b && !deck.isViewOnly ? [7, 3] : []))
                .padding(1.75)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.17, green: 0.17, blue: 0.19), Color(red: 0.07, green: 0.07, blue: 0.08)], center: UnitPoint(x: 0.45, y: 0.35), startRadius: 0, endRadius: size * 0.55))
                .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.6))
                .padding(9)
            ForEach(0..<8, id: \.self) { i in
                Circle()
                    .stroke(.white.opacity(i % 3 == 0 ? 0.06 : 0.03), lineWidth: 0.6)
                    .frame(width: size * (0.4 + CGFloat(i) * 0.065), height: size * (0.4 + CGFloat(i) * 0.065))
            }
            Capsule()
                .fill(.white)
                .frame(width: 3, height: 12)
                .offset(y: -(size / 2 - 18))
                .rotationEffect(.radians(deck.jogAngle))
            VStack(spacing: 1) {
                Text(deck.barReadout)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text(deck.barSeconds == nil ? "Time" : "Bar")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Jog, Deck \(deck.deck.label)")
        .accessibilityValue(deck.barSeconds == nil ? deck.barReadout : "Bar \(deck.barReadout)")
    }
}

struct MacDJPad: View {
    enum Content {
        case empty(number: String)
        case cue(letter: String, label: String, time: String, color: Color)
        case size(number: String, value: String, unit: String, isLit: Bool, isAuto: Bool)
    }

    let content: Content
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                switch content {
                case .empty(let number):
                    Text(number).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    Spacer(minLength: 0)
                    Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                case .cue(let letter, let label, let time, let color):
                    HStack {
                        Text(letter).font(.system(size: 10, weight: .heavy)).foregroundStyle(color)
                        Spacer()
                        Text(time).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer(minLength: 0)
                    Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                case .size(let number, let value, let unit, let isLit, let isAuto):
                    HStack {
                        Text(number).font(.system(size: 10, weight: .heavy)).foregroundStyle(isLit ? .white : Color(white: 0.56))
                        Spacer()
                        if isAuto { Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(MacDJPalette.auto) }
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value).font(.system(size: 12, weight: .semibold))
                        Text(unit).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(background)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        switch content {
        case .empty:
            shape.fill(.white.opacity(0.035)).overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        case .cue(_, _, _, let color):
            shape.fill(LinearGradient(colors: [color.opacity(0.19), color.opacity(0.10)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(color.opacity(0.6), lineWidth: 0.5))
        case .size(_, _, _, let isLit, _):
            let color = isLit ? MacDJPalette.auto : Color(white: 0.56)
            shape.fill(LinearGradient(colors: [color.opacity(isLit ? 0.4 : 0.19), color.opacity(isLit ? 0.22 : 0.10)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(isLit ? color : color.opacity(0.6), lineWidth: isLit ? 1 : 0.5))
        }
    }
}

struct MacDJOverviewCanvas: View {
    let deck: MacDJDeckState

    var body: some View {
        Canvas { context, size in
            let columns = Int(size.width / 1.5)
            for column in 0..<columns {
                let x = CGFloat(column) * 1.5
                let t = Double(x / size.width)
                let section = deck.phrases.first { t >= $0.start && t < $0.end }
                let energy = section.map { Self.energy($0.color) } ?? 0.5
                let wobble = (sin(t * 410 + Double(deck.deck.rawValue) * 3) + 1) / 2
                let amp = CGFloat(0.25 + energy * 0.55 + wobble * 0.2) * size.height / 2
                let played = t < deck.progress
                let base: Color
                if deck.isViewOnly || (section.map { Self.isVocal($0.color) } ?? false) {
                    base = Color(red: 0.98, green: 0.62, blue: 0.18)
                } else {
                    base = Color(red: 0.25, green: 0.5, blue: 1.0)
                }
                context.fill(Path(CGRect(x: x, y: size.height / 2 - amp, width: 1, height: amp * 2)), with: .color(base.opacity(played ? 0.5 : 1)))
                context.fill(Path(CGRect(x: x, y: size.height / 2 - amp * 0.35, width: 1, height: amp * 0.7)), with: .color(.white.opacity(played ? 0.4 : 0.85)))
            }
            let px = CGFloat(deck.progress) * size.width
            context.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
        }
        .accessibilityHidden(true)
    }

    private static func energy(_ color: Color) -> Double {
        color == MacDJPalette.Cue.red ? 0.9 : color == MacDJPalette.Cue.purple ? 0.35 : 0.6
    }

    private static func isVocal(_ color: Color) -> Bool {
        color == MacDJPalette.Cue.purple
    }
}
