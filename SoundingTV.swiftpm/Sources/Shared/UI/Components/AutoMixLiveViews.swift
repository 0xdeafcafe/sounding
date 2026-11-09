import SwiftUI

enum AutoMixLiveScale {
    case phone
    case mac
    case tv

    var visibleBeats: Double { self == .tv ? 24 : 16 }
    var laneHeight: CGFloat {
        switch self {
        case .phone: return 50
        case .mac: return 52
        case .tv: return 88
        }
    }
    var spacing: CGFloat { self == .tv ? 12 : 8 }
    var meterWidth: CGFloat { self == .tv ? 28 : 10 }
    var barStep: CGFloat { self == .tv ? 9 : 4 }
    var stripHeight: CGFloat { self == .tv ? 8 : 4 }
    var phaseFont: Font { self == .tv ? .title2.weight(.semibold) : .subheadline.weight(.semibold) }
    var captionFont: Font { self == .tv ? .callout : .caption2 }
    var detailFont: Font { self == .tv ? .headline : .caption }
    var nextMixHeight: CGFloat {
        switch self {
        case .phone: return 56
        case .mac: return 52
        case .tv: return 84
        }
    }
}

@MainActor
enum AutoMixEnvelopes {
    static func samples(for deck: AutoMixLiveState.Deck) -> [Float]? {
        guard let id = deck.trackId else { return nil }
        #if DEBUG
        if id.hasPrefix("fixture.") { return fixture(id, duration: deck.durationSeconds) }
        #endif
        guard let samples = WaveformService.shared.state(for: id).waveform?.samples, !samples.isEmpty else { return nil }
        return samples
    }

    #if DEBUG
    private static var fixtures: [String: [Float]] = [:]

    private static func fixture(_ id: String, duration: Double) -> [Float] {
        if let cached = fixtures[id] { return cached }
        let count = max(64, Int(duration * 8))
        var seed: UInt64 = id.unicodeScalars.reduce(1469598103934665603) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(seed >> 40) / Float(1 << 24)
            let beat = Double(i) / 8.0 / (60.0 / (id.hasSuffix("in") ? 126 : 124))
            let pulse = Float(pow(1 - (beat - beat.rounded(.down)), 3))
            let section = 0.6 + 0.4 * Float(sin(Double(i) / Double(count) * 40 + Double(seed % 7)))
            out[i] = min(1, section * (0.3 + 0.5 * pulse) + 0.2 * noise)
        }
        fixtures[id] = out
        return out
    }
    #endif
}

// MARK: - Next mix

struct AutoMixNextMixCapsule<Artwork: View>: View {
    let state: AutoMixLiveState
    var scale: AutoMixLiveScale = .phone
    var tint: Color = .white
    @ViewBuilder var artwork: () -> Artwork

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var artSize: CGFloat {
        switch scale {
        case .phone: return 36
        case .mac: return 32
        case .tv: return 56
        }
    }

    private var titleFont: Font {
        switch scale {
        case .phone: return .subheadline
        case .mac: return .callout
        case .tv: return .headline
        }
    }

    private var detailFont: Font { scale == .tv ? .callout : .footnote }
    private var glyphSize: CGSize { scale == .tv ? CGSize(width: 64, height: 30) : CGSize(width: 38, height: 18) }

    private var schedule: PeriodicTimelineSchedule {
        let interval = state.isPlaying ? max(0.25, min(1, state.beatSeconds)) : 3_600
        let back = (max(0, state.startsAt.timeIntervalSince(state.anchoredAt)) / interval).rounded(.up) + 1
        return .periodic(from: state.startsAt.addingTimeInterval(-back * interval), by: interval)
    }

    var body: some View {
        TimelineView(schedule) { context in
            let date = state.isPlaying ? context.date : state.anchoredAt
            let clock = state.clock(at: date)
            HStack(spacing: scale == .tv ? 16 : 10) {
                artwork()
                    .frame(width: artSize, height: artSize)
                    .clipShape(RoundedRectangle(cornerRadius: artSize * 0.2, style: .continuous))
                    .opacity(state.stage == .finished ? 0.7 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    title(clock)
                        .font(titleFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    detail(at: date)
                        .font(detailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: clock.phase?.id)
                AutoMixLaneGlyph(state: state, bar: state.barsFromStart(at: date), tint: tint)
                    .frame(width: glyphSize.width, height: glyphSize.height)
                trailing(clock)
                    .font(titleFont)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(clock, at: date))
        }
    }

    private func title(_ clock: AutoMixLiveState.Clock) -> some View {
        Group {
            switch state.stage {
            case .upcoming:
                Text("Mix into \(Text(state.incomingTitle).fontWeight(.semibold))")
            case .mixing:
                Text(state.caption(for: clock.phase) + (clock.isRiser ? " · Riser" : ""))
                    .fontWeight(.semibold)
            case .finished:
                Text("Mixed into \(Text(state.incomingTitle).fontWeight(.semibold))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detail(at date: Date) -> Text {
        if state.stage == .finished, let rating = state.rating { return Text(rating.label) }
        if state.stage != .finished, let cue = state.moveCue { return Text(cueText(cue, at: date)) }
        if state.stage == .upcoming, state.yourMove == true { return Text("Your move · \(state.moveSummary)") }
        return Text(state.moveSummary)
    }

    @ViewBuilder
    private func trailing(_ clock: AutoMixLiveState.Clock) -> some View {
        switch state.stage {
        case .upcoming:
            let text = countdown(clock)
            Text(text)
                .foregroundStyle(clock.barsUntilStart <= 4 ? .primary : .secondary)
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: text)
        case .mixing:
            Text("Bar \(min(state.lengthBars, Int(clock.barInMove) + 1)) of \(state.lengthBars)")
                .foregroundStyle(.secondary)
        case .finished:
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
        }
    }

    private func countdown(_ clock: AutoMixLiveState.Clock) -> String {
        clock.barsUntilStart <= 8 ? clock.countdownText : AutoMixLiveState.countdown(clock.secondsUntilStart)
    }

    private func cueText(_ cue: AutoMixLiveState.MoveCue, at date: Date) -> String {
        guard let startsAt = cue.startsAt else { return cue.title }
        let bars = Int(ceil(startsAt.timeIntervalSince(date) / max(0.1, state.barSeconds)))
        if bars <= 0 { return cue.title }
        return bars == 1 ? "\(cue.title) in 1 bar" : "\(cue.title) in \(bars) bars"
    }

    private func accessibilityText(_ clock: AutoMixLiveState.Clock, at date: Date) -> String {
        switch state.stage {
        case .upcoming:
            return "Next mix into \(state.incomingTitle), \(countdown(clock)). \(state.moveSummary)." + (state.yourMove == true ? " Your move." : "")
        case .mixing:
            return "\(state.caption(for: clock.phase)). Bar \(min(state.lengthBars, Int(clock.barInMove) + 1)) of \(state.lengthBars)."
        case .finished:
            return "Mixed into \(state.incomingTitle)" + (state.rating.map { ". \($0.label)" } ?? "")
        }
    }
}

struct AutoMixLaneGlyph: View {
    let state: AutoMixLiveState
    let bar: Double
    var tint: Color = .white

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 4, size.height > 4 else { return }
        let total = Double(max(1, state.lengthBars))
        let gap: CGFloat = 2
        let lane = (size.height - gap) / 2
        let step: CGFloat = 2
        let barWidth: CGFloat = 1.25
        let progress: Double
        switch state.stage {
        case .upcoming: progress = -1
        case .mixing: progress = bar
        case .finished: progress = total
        }
        let sections = state.sections
        let echoes = sections.filter { $0.label == "Echo out" }
        var outPast = Path()
        var outFuture = Path()
        var inPast = Path()
        var inFuture = Path()
        var x: CGFloat = 0
        while x + barWidth <= size.width {
            let value = Double((x + barWidth / 2) / size.width) * total
            let levels = state.levels(atBar: value)
            var outgoing = levels.outgoing
            if let echo = echoes.first(where: { value >= $0.startBar && value < $0.endBar }) {
                let local = (value - echo.startBar).truncatingRemainder(dividingBy: 1)
                outgoing *= 0.3 + 0.7 * (1 - local)
            }
            let past = value <= progress
            if outgoing > 0.02 {
                let h = max(1.5, CGFloat(outgoing) * lane)
                let rect = CGRect(x: x, y: (lane - h) / 2, width: barWidth, height: h)
                if past { outPast.addRect(rect) } else { outFuture.addRect(rect) }
            }
            if levels.incoming > 0.02 {
                let h = max(1.5, CGFloat(levels.incoming) * lane)
                let rect = CGRect(x: x, y: lane + gap + (lane - h) / 2, width: barWidth, height: h)
                if past { inPast.addRect(rect) } else { inFuture.addRect(rect) }
            }
            x += step
        }
        context.fill(outFuture, with: .color(.primary.opacity(0.45)))
        context.fill(outPast, with: .color(.primary.opacity(0.9)))
        context.fill(inFuture, with: .color(.primary.opacity(0.45)))
        context.fill(inPast, with: .color(tint.opacity(0.9)))
        for section in sections where section.role == .loop {
            let x0 = CGFloat(section.startBar / total) * size.width
            let x1 = CGFloat(section.endBar / total) * size.width
            let rect = CGRect(x: x0, y: -0.5, width: max(2, x1 - x0), height: lane + 1)
            context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(.primary.opacity(0.5)), lineWidth: 0.75)
        }
    }
}

// MARK: - Real-time decks

struct AutoMixDecksView: View {
    let state: AutoMixLiveState
    var scale: AutoMixLiveScale = .phone
    var tint: Color = .white
    var showsTransition = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(schedule) { context in
            let date = reduceMotion || !state.isPlaying ? state.anchoredAt : context.date
            content(at: date)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var schedule: AnimationTimelineSchedule {
        .animation(minimumInterval: scale == .tv ? 1.0 / 30 : 1.0 / 60, paused: reduceMotion || !state.isPlaying)
    }

    private var accessibilityText: String {
        let clock = state.clock(at: state.anchoredAt)
        return "\(state.moveName) into \(state.incomingTitle). \(clock.phase?.name ?? ""), bar \(Int(clock.barInMove) + 1) of \(state.lengthBars)."
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: scale.spacing) {
            if showsTransition {
                AutoMixTransitionView(state: state, scale: scale, tint: tint)
                    .padding(.bottom, scale == .tv ? 6 : 2)
            }
            if let outgoing = state.outgoing {
                AutoMixDeckLane(state: state, deck: outgoing, label: "A", audibility: 1 - state.crossfade, position: state.deckPosition(outgoing, at: date), scale: scale, tint: tint, showsLoop: true)
            }
            AutoMixCrossfader(value: state.crossfade, scale: scale)
            if let incoming = state.incoming {
                AutoMixDeckLane(state: state, deck: incoming, label: "B", audibility: state.crossfade, position: state.deckPosition(incoming, at: date), scale: scale, tint: tint, showsLoop: false)
            }
        }
    }
}

struct AutoMixDeckLane: View {
    let state: AutoMixLiveState
    let deck: AutoMixLiveState.Deck
    let label: String
    let audibility: Double
    let position: Double
    var scale: AutoMixLiveScale = .phone
    var tint: Color = .white
    var showsLoop = false

    var body: some View {
        VStack(alignment: .leading, spacing: scale == .tv ? 6 : 3) {
            HStack(spacing: 6) {
                Text(label).fontWeight(.semibold)
                Text(deck.title).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let filter = deck.filterLabel {
                    Text(filter)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(scale.captionFont)
            .lineLimit(1)
            HStack(spacing: scale == .tv ? 16 : 10) {
                waveform
                    .frame(height: scale.laneHeight)
                AutoMixEQMeters(deck: deck, scale: scale)
                    .frame(height: scale.laneHeight)
            }
        }
    }

    private var waveform: some View {
        let samples = AutoMixEnvelopes.samples(for: deck)
        let normalized = samples.map { SCWaveformSampler.visuallyNormalized($0) }
        return Canvas { context, size in
            let beat = deck.beatSeconds ?? state.beatSeconds
            let pxPerBeat = size.width / CGFloat(scale.visibleBeats)
            let secondsPerPx = beat / Double(pxPerBeat)
            let center = size.width / 2
            let t0 = position - Double(center) * secondsPerPx
            let t1 = position + Double(size.width - center) * secondsPerPx
            if showsLoop, let start = deck.loopStartSeconds, let length = deck.loopLengthSeconds, length > 0 {
                let x0 = center + CGFloat((start - position) / secondsPerPx)
                let x1 = x0 + CGFloat(length / secondsPerPx)
                let rect = CGRect(x: max(0, x0), y: 0, width: max(0, min(size.width, x1) - max(0, x0)), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(tint.opacity(0.22)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(tint.opacity(0.7)), lineWidth: 1)
            }
            if let downbeat = deck.downbeatSeconds, beat > 0.05 {
                var k = ((t0 - downbeat) / beat).rounded(.up)
                while downbeat + k * beat <= t1 {
                    let t = downbeat + k * beat
                    let x = center + CGFloat((t - position) / secondsPerPx)
                    let isBar = Int(k.rounded()) % 4 == 0
                    let h = isBar ? size.height : size.height * 0.2
                    context.fill(Path(CGRect(x: x - 0.5, y: (size.height - h) / 2, width: 1, height: h)), with: .color(.white.opacity(isBar ? 0.22 : 0.12)))
                    k += 1
                }
            }
            let level = 0.25 + 0.75 * max(0, min(1, audibility * deck.gain))
            let step = scale.barStep
            let barWidth = max(1.5, step * 0.6)
            var x: CGFloat = 0
            while x < size.width {
                let t = position + Double(x + barWidth / 2 - center) * secondsPerPx
                let amplitude: CGFloat
                if let normalized, t >= 0, t <= deck.durationSeconds {
                    amplitude = CGFloat(SCWaveformSampler.amplitude(in: normalized, duration: deck.durationSeconds, at: t))
                } else {
                    amplitude = (t >= 0 && t <= deck.durationSeconds) ? 0.12 : 0
                }
                if amplitude > 0 {
                    let h = max(1.5, amplitude * size.height * 0.92)
                    let played = x + barWidth / 2 <= center
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color((played ? tint : .white).opacity(played ? level : level * 0.55)))
                }
                x += step
            }
            context.fill(Path(CGRect(x: center - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.white.opacity(0.9)))
        }
        .opacity(deck.isPlaying || audibility > 0.02 ? 1 : 0.55)
    }
}

struct AutoMixEQMeters: View {
    let deck: AutoMixLiveState.Deck
    var scale: AutoMixLiveScale = .phone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: scale == .tv ? 8 : 4) {
            meter(AutoMixLiveState.Deck.eqLevel(deck.highDb), "H")
            meter(AutoMixLiveState.Deck.eqLevel(deck.midDb), "M")
            meter(AutoMixLiveState.Deck.eqLevel(deck.lowDb), "L")
            filter
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.12), value: deck)
        .accessibilityHidden(true)
    }

    private func meter(_ value: Double, _ label: String) -> some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let h = proxy.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.14))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(value < 0.05 ? Color.white.opacity(0.25) : Color.white.opacity(0.85))
                        .frame(height: max(2, h * value))
                }
            }
            Text(label)
                .font(scale.captionFont)
                .foregroundStyle(value < 0.05 ? .tertiary : .secondary)
        }
        .frame(width: scale.meterWidth)
    }

    private var filter: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let h = proxy.size.height
                let amount = deck.filterAmount
                ZStack {
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.14))
                    Rectangle().fill(.white.opacity(0.3)).frame(height: 1)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(abs(amount) < 0.02 ? 0.25 : 0.85))
                        .frame(height: max(2, h / 2 * abs(amount)))
                        .offset(y: amount > 0 ? -h / 4 * abs(amount) : h / 4 * abs(amount))
                }
            }
            Text("F")
                .font(scale.captionFont)
                .foregroundStyle(abs(deck.filterAmount) < 0.02 ? .tertiary : .secondary)
        }
        .frame(width: scale.meterWidth)
        .padding(.leading, scale == .tv ? 6 : 3)
    }
}

struct AutoMixCrossfader: View {
    let value: Double
    var scale: AutoMixLiveScale = .phone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: scale == .tv ? 14 : 8) {
            Text("A").font(scale.captionFont.weight(.semibold)).foregroundStyle(value < 0.5 ? .primary : .tertiary)
            GeometryReader { proxy in
                let w = proxy.size.width
                let knob: CGFloat = scale == .tv ? 44 : 26
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: scale == .tv ? 6 : 4)
                    Capsule()
                        .fill(.white)
                        .frame(width: knob, height: scale == .tv ? 20 : 12)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .offset(x: (w - knob) * CGFloat(max(0, min(1, value))))
                }
                .frame(maxHeight: .infinity)
            }
            Text("B").font(scale.captionFont.weight(.semibold)).foregroundStyle(value >= 0.5 ? .primary : .tertiary)
        }
        .frame(height: scale == .tv ? 24 : 14)
        .animation(reduceMotion ? nil : .linear(duration: 0.12), value: value)
        .accessibilityHidden(true)
    }
}

// MARK: - Plan detail

struct AutoMixPlanForm: View {
    let state: AutoMixLiveState
    var onMixNow: (() -> Void)?
    var onExtend: (() -> Void)?
    var onSkip: (() -> Void)?

    var body: some View {
        Form {
            Section {
                AutoMixTransitionView(state: state, scale: .phone, tint: .primary)
                    .padding(.vertical, 4)
            }
            if state.stage == .upcoming {
                Section {
                    if let onMixNow {
                        Button("Mix Now", systemImage: "play.circle", action: onMixNow)
                            .disabled(!state.canMixNow)
                    }
                    if let onExtend {
                        Button("Extend 8 Bars", systemImage: "plus.circle", action: onExtend)
                            .disabled(!state.canExtend)
                    }
                    if let onSkip {
                        Button("Skip This Track", systemImage: "forward.end", role: .destructive, action: onSkip)
                    }
                }
            }
            Section {
                LabeledContent("Into", value: state.incomingTitle)
                if let artist = state.incomingArtist { LabeledContent("Artist", value: artist) }
                TimelineView(.periodic(from: state.startsAt, by: max(0.2, state.beatSeconds))) { context in
                    LabeledContent("Starts", value: startText(state.clock(at: context.date)))
                        .monospacedDigit()
                }
                if state.landingBar > 0 { LabeledContent("Lands", value: "Bar \(state.landingBar + 1)") }
                LabeledContent("Length", value: "\(state.lengthBars) bars")
                if let why = state.why { LabeledContent("Why") { AutoMixWhyText(why: why) } }
                if let rating = state.rating { LabeledContent("Mix", value: rating.label) }
            } header: {
                Text(state.moveName)
            }
            Section("Steps") {
                ForEach(state.phases) { phase in
                    LabeledContent(phase.name, value: phase.bars == 1 ? "1 bar" : "\(Int(phase.bars)) bars")
                }
                if let riser = state.riserStartBar {
                    LabeledContent("Riser", value: "from bar \(Int(riser) + 1)")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func startText(_ clock: AutoMixLiveState.Clock) -> String {
        switch state.stage {
        case .upcoming: return clock.countdownText.prefix(1).uppercased() + clock.countdownText.dropFirst()
        case .mixing: return "Now"
        case .finished: return "Done"
        }
    }
}

// MARK: - Transition

struct AutoMixTransitionView: View {
    let state: AutoMixLiveState
    var scale: AutoMixLiveScale = .phone
    var tint: Color = .white
    var rating: AutoMixLiveState.Rating?
    var moveCue: AutoMixLiveState.MoveCue?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : (scale == .tv ? 1.0 / 20 : 1.0 / 24), paused: !state.isPlaying)) { context in
            let date = state.isPlaying ? context.date : state.anchoredAt
            let clock = state.clock(at: date)
            VStack(alignment: .leading, spacing: scale == .tv ? 10 : 5) {
                caption(clock)
                AutoMixTransitionTimeline(state: state, bar: state.barsFromStart(at: date), scale: scale, tint: tint)
                if let cue = moveCue ?? state.moveCue {
                    cueLine(cue, at: date)
                } else if state.yourMove == true, state.stage == .upcoming {
                    yourMoveLine
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(clock))
        }
    }

    private func caption(_ clock: AutoMixLiveState.Clock) -> some View {
        let font: Font = scale == .tv ? .headline : .footnote
        return HStack(alignment: .firstTextBaseline, spacing: scale == .tv ? 14 : 8) {
            Image(systemName: state.stage == .finished ? "checkmark" : state.symbolName)
                .font(scale == .tv ? .headline : .footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: scale == .tv ? 30 : 18)
            title(clock)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: clock.phase?.id)
            Spacer(minLength: 4)
            trailing(clock)
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func title(_ clock: AutoMixLiveState.Clock) -> Text {
        switch state.stage {
        case .upcoming:
            return Text("Mixing into ") + Text(state.incomingTitle).fontWeight(.semibold)
        case .mixing:
            return Text(state.caption(for: clock.phase) + (clock.isRiser ? " · Riser" : "")).fontWeight(.semibold)
        case .finished:
            return (Text("Mixed into ") + Text(state.incomingTitle).fontWeight(.semibold)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func trailing(_ clock: AutoMixLiveState.Clock) -> some View {
        switch state.stage {
        case .upcoming:
            Text(AutoMixLiveState.countdown(clock.secondsUntilStart))
                .foregroundStyle(clock.barsUntilStart <= 4 ? .primary : .secondary)
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
        case .mixing:
            Text("Bar \(min(state.lengthBars, Int(clock.barInMove) + 1)) of \(state.lengthBars)")
                .foregroundStyle(.secondary)
        case .finished:
            if let rating = rating ?? state.rating {
                Text(rating.label).foregroundStyle(.secondary)
            }
        }
    }

    private var yourMoveLine: some View {
        HStack(spacing: scale == .tv ? 12 : 8) {
            AutoMixYourMoveChip(scale: scale)
            if let why = state.why {
                AutoMixWhyText(why: why)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(scale.detailFont)
    }

    private func cueLine(_ cue: AutoMixLiveState.MoveCue, at date: Date) -> some View {
        HStack(spacing: scale == .tv ? 10 : 6) {
            Image(systemName: cue.symbolName ?? "sparkles")
                .foregroundStyle(.secondary)
            Text(cueText(cue, at: date))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(scale.detailFont)
        .lineLimit(1)
    }

    private func cueText(_ cue: AutoMixLiveState.MoveCue, at date: Date) -> String {
        guard let startsAt = cue.startsAt else { return cue.title }
        let bars = Int(ceil(startsAt.timeIntervalSince(state.isPlaying ? date : state.anchoredAt) / max(0.1, state.barSeconds)))
        if bars <= 0 { return cue.title }
        return bars == 1 ? "\(cue.title) in 1 bar" : "\(cue.title) in \(bars) bars"
    }

    private func accessibilityText(_ clock: AutoMixLiveState.Clock) -> String {
        let steps = state.sections.map(\.label).joined(separator: ", ")
        switch state.stage {
        case .upcoming:
            return "Mixing into \(state.incomingTitle) \(AutoMixLiveState.countdown(clock.secondsUntilStart)). \(state.moveName): \(steps)." + (state.yourMove == true ? " Your move." : "")
        case .mixing:
            return "\(state.caption(for: clock.phase)). Bar \(Int(clock.barInMove) + 1) of \(state.lengthBars)."
        case .finished:
            return "Mixed into \(state.incomingTitle)" + ((rating ?? state.rating).map { ". \($0.label)" } ?? "")
        }
    }
}

struct AutoMixYourMoveChip: View {
    var scale: AutoMixLiveScale = .phone

    var body: some View {
        Label("Your move", systemImage: "checkmark")
            .font(scale == .tv ? .headline : .caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.black)
            .padding(.horizontal, scale == .tv ? 14 : 9)
            .padding(.vertical, scale == .tv ? 6 : 3)
            .background(.white, in: .capsule)
            .fixedSize()
            .accessibilityLabel("Your move")
    }
}

struct AutoMixTransitionTimeline: View {
    let state: AutoMixLiveState
    let bar: Double
    var scale: AutoMixLiveScale = .phone
    var tint: Color = .white

    private var leadBars: Double { scale == .tv ? 8 : 4 }
    private var ribbon: CGFloat { scale == .tv ? 14 : 7 }
    private var gap: CGFloat { scale == .tv ? 6 : 3 }
    private var labelFont: Font { scale == .tv ? .callout : .caption2 }
    private var labelHeight: CGFloat { scale == .tv ? 38 : 15 }

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(height: ribbon * 2 + gap + 6 + labelHeight)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let total = Double(max(1, state.lengthBars))
        let start = -leadBars
        let end = total + 2
        let width = size.width
        func x(_ value: Double) -> CGFloat { CGFloat((value - start) / (end - start)) * width }
        let top: CGFloat = 3
        let inTop = top + ribbon + gap
        let lanesBottom = inTop + ribbon
        let playhead = min(max(bar, start), end)
        let window = CGRect(x: x(0), y: top - 3, width: x(total) - x(0), height: lanesBottom - top + 6)
        context.fill(Path(roundedRect: window, cornerRadius: 4), with: .color(.primary.opacity(0.08)))

        let sections = state.sections
        for section in sections where section.role == .loop {
            let rect = CGRect(x: x(section.startBar), y: top - 1.5, width: x(section.endBar) - x(section.startBar), height: ribbon + 3)
            context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(.primary.opacity(0.55)), lineWidth: 1)
        }

        let step: CGFloat = scale == .tv ? 3 : 2
        var cursor: CGFloat = 0
        var outPast = Path()
        var outFuture = Path()
        var inPast = Path()
        var inFuture = Path()
        while cursor < width {
            let value = start + Double(cursor / width) * (end - start)
            let levels = state.levels(atBar: value)
            let past = state.stage == .finished || value <= playhead
            let outHeight = CGFloat(max(0, levels.outgoing)) * ribbon
            let inHeight = CGFloat(max(0, levels.incoming)) * ribbon
            if outHeight > 0.3 {
                let rect = CGRect(x: cursor, y: top + (ribbon - outHeight) / 2, width: step, height: outHeight)
                if past { outPast.addRect(rect) } else { outFuture.addRect(rect) }
            }
            if inHeight > 0.3 {
                let rect = CGRect(x: cursor, y: inTop + (ribbon - inHeight) / 2, width: step, height: inHeight)
                if past { inPast.addRect(rect) } else { inFuture.addRect(rect) }
            }
            cursor += step
        }
        context.fill(outFuture, with: .color(.primary.opacity(0.32)))
        context.fill(outPast, with: .color(.primary.opacity(0.85)))
        context.fill(inFuture, with: .color(tint.opacity(0.42)))
        context.fill(inPast, with: .color(tint.opacity(0.95)))

        for section in sections.dropFirst() {
            let px = x(section.startBar)
            context.fill(Path(CGRect(x: px - 0.5, y: top - 3, width: 1, height: lanesBottom - top + 6)), with: .color(.primary.opacity(0.22)))
        }
        if let release = state.releaseBar {
            let px = x(release)
            context.fill(Path(CGRect(x: px - 0.75, y: top - 3, width: 1.5, height: lanesBottom - top + 6)), with: .color(.primary.opacity(0.75)))
        }

        let current = state.stage == .mixing ? sections.last(where: { bar >= $0.startBar - 0.0001 }) : nil
        let labelY = lanesBottom + 6 + labelHeight / 2
        var occupied = -CGFloat.infinity
        for section in sections {
            let x0 = x(section.startBar)
            let x1 = x(section.endBar)
            let isCurrent = current?.id == section.id
            let text = context.resolve(
                Text(section.label)
                    .font(isCurrent ? labelFont.weight(.semibold) : labelFont)
                    .foregroundStyle(isCurrent ? Color.primary : Color.primary.opacity(0.62))
            )
            let measured = text.measure(in: CGSize(width: width, height: labelHeight))
            let center = min(max((x0 + x1) / 2, measured.width / 2), width - measured.width / 2)
            guard center - measured.width / 2 >= occupied + 6 else { continue }
            context.draw(text, at: CGPoint(x: center, y: labelY), anchor: .center)
            occupied = center + measured.width / 2
        }

        if state.stage != .finished {
            let px = x(playhead)
            context.fill(Path(roundedRect: CGRect(x: px - 1, y: 0, width: 2, height: lanesBottom + 3), cornerRadius: 1), with: .color(.primary))
        }
    }
}
