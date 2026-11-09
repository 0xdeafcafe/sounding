import SwiftUI

struct PhoneDecksMixer: View {
    let state: MacDJPerformState
    @ObservedObject var model: PhoneDecksModel
    var showsAllBands = false
    var showsCrossfader = true
    var showsCaption = true
    var metrics: PhoneDeckMetrics = .compact

    @Environment(\.colorSchemeContrast) private var contrast

    private var bands: [MixControl.Kind] { showsAllBands ? [.high, .mid, .low, .filter] : [model.eqBand, .filter] }

    var body: some View {
        VStack(spacing: 6) {
            if !showsAllBands {
                Picker("EQ Band", selection: $model.eqBand) {
                    Text("High").tag(MixControl.Kind.high)
                    Text("Mid").tag(MixControl.Kind.mid)
                    Text("Low").tag(MixControl.Kind.low)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            HStack(alignment: .top, spacing: 4) {
                knobs(.a)
                fader(.a)
                VStack(spacing: 0) {
                    ForEach(bands, id: \.self) { kind in
                        label(kind).frame(height: metrics.knobRow)
                    }
                }
                .frame(maxWidth: .infinity)
                fader(.b)
                knobs(.b)
            }
            if showsCrossfader {
                PhoneDecksCrossfader(state: state, model: model)
            }
            caption
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mixer")
    }

    private func knobs(_ deck: MixEngine.Deck) -> some View {
        VStack(spacing: 0) {
            ForEach(bands, id: \.self) { kind in
                let control = MixControl(kind, deck: deck)
                PhoneDeckKnob(
                    value: state.value(control),
                    target: state.targets[control]?.value,
                    isYours: state.ownership(control) != nil,
                    isDisabled: state.deck(deck).isViewOnly || state.deck(deck).isEmpty,
                    size: metrics.knob,
                    valueText: model.valueText(control, in: state),
                    onGrab: { model.grab(control) },
                    onChange: { model.set(control, to: $0) }
                )
                .frame(height: metrics.knobRow)
                .accessibilityLabel(control.name)
            }
        }
    }

    private func fader(_ deck: MixEngine.Deck) -> some View {
        let control = MixControl(.volume, deck: deck)
        return PhoneDeckFader(
            value: state.value(control),
            target: state.targets[control]?.value,
            isYours: state.ownership(control) != nil,
            isDisabled: state.deck(deck).isViewOnly || state.deck(deck).isEmpty,
            height: CGFloat(bands.count) * metrics.knobRow - 8,
            valueText: model.valueText(control, in: state),
            onGrab: { model.grab(control) },
            onChange: { model.set(control, to: $0) }
        )
        .padding(.top, 4)
        .accessibilityLabel(control.name)
    }

    private func label(_ kind: MixControl.Kind) -> some View {
        Text(MixControl(kind, deck: nil).name)
            .font(.caption)
            .foregroundStyle(contrast.djInk(0.6))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var caption: some View {
        if showsCaption, state.isAutoMixDriving, state.owned.isEmpty {
            Label("Touch any control to take over", systemImage: "sparkle")
                .labelStyle(CompactLabelStyle())
                .font(.caption2)
                .foregroundStyle(MacDJPalette.auto)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

struct PhoneDecksCrossfader: View {
    let state: MacDJPerformState
    @ObservedObject var model: PhoneDecksModel

    var body: some View {
        PhoneDeckCrossfader(
            value: state.value(.crossfader),
            target: state.targets[.crossfader]?.value,
            isYours: state.ownership(.crossfader) != nil,
            onGrab: { model.grab(.crossfader) },
            onChange: { model.set(.crossfader, to: $0) }
        )
    }
}
