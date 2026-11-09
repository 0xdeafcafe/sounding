import SwiftUI

struct DJMixerColumn: View {
    let state: MacDJPerformState
    @ObservedObject var model: MacDJPerformModel
    @ObservedObject var mixer: DJMixerModel

    init(state: MacDJPerformState, model: MacDJPerformModel, mixer: DJMixerModel = .shared) {
        self.state = state
        self.model = model
        self.mixer = mixer
    }

    private let rows: [(MixControl.Kind, String)] = [(.trim, "Trim"), (.high, "High"), (.mid, "Mid"), (.low, "Low"), (.filter, "Filter")]
    private static let knobX: CGFloat = 30
    private static let cueY: CGFloat = 254
    private static let faderY: CGFloat = 290

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .topLeading) {
                if let label = state.mixerLabel {
                    Label(label, systemImage: "sparkle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MacDJPalette.auto)
                        .labelStyle(MacDJAutoLabelStyle())
                        .lineLimit(1)
                        .frame(width: w)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let y = 18 + CGFloat(index) * 46
                    knob(MixControl(row.0, deck: .a), x: Self.knobX, y: y)
                    knob(MixControl(row.0, deck: .b), x: w - Self.knobX, y: y)
                    Text(row.1)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 80)
                        .offset(x: w / 2 - 40, y: y + 9)
                        .accessibilityHidden(true)
                }
                if let viewOnly = state.decks.first(where: { $0.isViewOnly && !$0.isEmpty }) {
                    Text("Auto Mix only")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize()
                        .frame(width: 68)
                        .offset(x: (viewOnly.deck == .a ? Self.knobX : w - Self.knobX) - 34, y: 18 + 5 * 46 - 6)
                }
                ForEach(state.owned.filter { owned in rows.contains { $0.0 == owned.control.kind } }) { owned in
                    if let index = rows.firstIndex(where: { $0.0 == owned.control.kind }) {
                        MacDJYoursChip(valueText: owned.valueText) { model.handBack(owned.control) }
                            .frame(width: w - 104, alignment: owned.control.deck == .a ? .leading : .trailing)
                            .offset(x: 52, y: 18 + CGFloat(index) * 46 + 4)
                    }
                }
                cueButtons(width: w)
                faders(width: w)
                DJMixerMeterStrip(mixer: mixer, state: state, isFixture: model.isFixture, width: w)
                    .offset(y: Self.faderY)
                MacDJCrossfader(
                    value: state.value(.crossfader),
                    target: state.targets[.crossfader]?.value,
                    isYours: state.ownership(.crossfader) != nil,
                    onGrab: { model.grab(.crossfader) },
                    onChange: { model.set(.crossfader, to: $0) }
                )
                .frame(width: w - 12)
                .offset(x: 6, y: 386)
                levelKnobs(width: w)
                    .offset(y: 416)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mixer")
    }

    // MARK: - Trim, EQ and filter

    private func knob(_ control: MixControl, x: CGFloat, y: CGFloat) -> some View {
        let viewOnly = state.deck(control.deck ?? .a).isViewOnly
        let target = state.targets[control]
        return ZStack(alignment: .top) {
            MacDJKnob(
                value: state.value(control),
                target: target?.value,
                isYours: state.ownership(control) != nil,
                isDisabled: viewOnly,
                onGrab: { model.grab(control) },
                onChange: { model.set(control, to: $0) },
                onDoubleClick: { model.set(control, to: MacDJPerformState.defaultValue(control)) }
            )
            .accessibilityLabel(control.name)
            if let label = target?.label, !viewOnly, state.ownership(control) == nil {
                Text(label)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(MacDJPalette.auto)
                    .fixedSize()
                    .offset(y: 32)
            }
        }
        .frame(width: 32)
        .offset(x: x - 16, y: y)
    }

    // MARK: - Headphone cue

    private func cueButtons(width w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(MixEngine.Deck.allCases) { deck in
                let x = deck == .a ? Self.knobX : w - Self.knobX
                let isOn = mixer.isCued(deck)
                Button {
                    mixer.toggleCue(deck)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "headphones")
                            .font(.system(size: 10, weight: .semibold))
                        Text(deck.label)
                            .font(.system(size: 11, weight: .bold))
                    }
                    .frame(width: 30)
                }
                .buttonStyle(MacDJControlButtonStyle(isOn: isOn))
                .offset(x: x - 23, y: Self.cueY)
                .help("Cue Deck \(deck.label) in your headphones")
                .accessibilityLabel("Cue Deck \(deck.label) in Headphones")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            Text("Cue")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 80)
                .offset(x: w / 2 - 40, y: Self.cueY + 5)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Channel faders

    @ViewBuilder
    private func faders(width w: CGFloat) -> some View {
        ForEach(MixEngine.Deck.allCases) { deck in
            let control = MixControl(.volume, deck: deck)
            let x: CGFloat = deck == .a ? Self.knobX : w - Self.knobX
            MacDJVerticalFader(
                value: state.value(control),
                target: state.targets[control]?.value,
                isYours: state.ownership(control) != nil,
                isDisabled: state.deck(deck).isViewOnly,
                onGrab: { model.grab(control) },
                onChange: { model.set(control, to: $0) }
            )
            .frame(width: 36)
            .offset(x: x - 18, y: Self.faderY)
            .accessibilityLabel(control.name)
        }
    }

    // MARK: - Master, Cue Mix, Phones

    private func levelKnobs(width w: CGFloat) -> some View {
        HStack(spacing: 0) {
            levelKnob("Master", control: .masterLevel, reset: 1)
            Spacer(minLength: 4)
            levelKnob("Cue Mix", control: .cueMix, reset: 0.5)
            Spacer(minLength: 4)
            levelKnob("Phones", control: .phonesLevel, reset: nil)
        }
        .padding(.horizontal, 4)
        .frame(width: w, height: 26)
    }

    private func levelKnob(_ title: String, control: DeckControl, reset: Double?) -> some View {
        let address = DJMixerModel.address(control)
        let detail = mixer.valueText(control)
        return HStack(spacing: 5) {
            MacDJKnob(
                value: mixer.value(address),
                size: 24,
                bipolar: false,
                onChange: { value in
                    mixer.set(address, value)
                    mixer.persistLevels()
                },
                onDoubleClick: {
                    if let reset { mixer.set(address, reset) }
                    mixer.persistLevels()
                }
            )
            .accessibilityLabel(title)
            .accessibilityValue(detail)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(detail)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
        }
    }
}

private struct DJMixerMeterStrip: View {
    @ObservedObject var mixer: DJMixerModel
    let state: MacDJPerformState
    let isFixture: Bool
    let width: CGFloat

    private static let height: CGFloat = 76

    private var meters: DJMixerMeters {
        guard isFixture else { return mixer.meters }
        return .display(a: state.levels[.a] ?? 0, b: state.levels[.b] ?? 0, master: state.masterLevel)
    }

    var body: some View {
        let meters = meters
        let h = Self.height
        ZStack(alignment: .topLeading) {
            labelledMeter(meters.a, label: "A", x: 30 + 24)
            labelledMeter(meters.b, label: "B", x: width - 30 - 29)
            DJSegmentMeter(meter: meters.masterLeft, showsClip: false, height: h)
                .offset(x: width / 2 - 7)
            DJSegmentMeter(meter: meters.masterRight, showsClip: false, height: h)
                .offset(x: width / 2 + 2)
            RoundedRectangle(cornerRadius: 2)
                .fill(DJSegmentMeter.clip.opacity(meters.master.isClipping ? 1 : 0.25))
                .frame(width: 12, height: 5)
                .offset(x: width / 2 - 6, y: -9)
            Text("Master")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 60)
                .offset(x: width / 2 - 30, y: h + 3)
        }
        .frame(width: width, height: h + 16, alignment: .topLeading)
        .onAppear { if !isFixture { mixer.startMetering() } }
        .onDisappear { if !isFixture { mixer.stopMetering() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Levels")
        .accessibilityValue(meters.master.isClipping ? "Master clipping" : "")
    }

    private func labelledMeter(_ meter: DJMeterBallistics, label: String, x: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            DJSegmentMeter(meter: meter, height: Self.height)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 25)
                .offset(x: -10, y: Self.height + 3)
        }
        .offset(x: x)
    }
}
