import SwiftUI

struct DJDeckFXRow: View {
    let deck: MixEngine.Deck
    @ObservedObject var model: DJMixerModel
    @ObservedObject private var rack = MacEffectRack.shared
    @ObservedObject private var presets = MacEffectPresetStore.shared

    init(deck: MixEngine.Deck, model: DJMixerModel = .shared) {
        self.deck = deck
        self.model = model
    }

    private var fx: MixEngine.DeckFX { model.fx(deck) }
    private var slot: MixEngine.EffectSlot { .deck(deck) }
    private var plugin: MixEngine.LoadedEffect? { rack.effects[slot] }

    var body: some View {
        HStack(spacing: 6) {
            Text("FX")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 18, alignment: .leading)
                .accessibilityHidden(true)
            effectMenu
            beatsMenu
            Slider(value: Binding(
                get: { fx.amount },
                set: { model.setFXAmount($0, on: deck) }
            ), in: 0...1)
            .controlSize(.small)
            .tint(.white.opacity(0.7))
            .frame(minWidth: 30)
            .padding(.horizontal, 4)
            .accessibilityLabel("Deck \(deck.label) Effect Amount")
            .accessibilityValue("\(Int((fx.amount * 100).rounded())) percent")
            Button(fx.isOn ? "On" : "Off") {
                model.toggleFX(on: deck)
            }
            .buttonStyle(MacDJControlButtonStyle(isOn: fx.isOn))
            .accessibilityLabel("Deck \(deck.label) Effect")
            .accessibilityValue(fx.isOn ? "On" : "Off")
        }
        .frame(height: 26)
        .lineLimit(1)
    }

    private var effectTitle: String {
        fx.kind == .plugin ? (plugin?.name ?? MixFXKind.plugin.title) : fx.kind.title
    }

    private var effectMenu: some View {
        Menu {
            Picker("Effect", selection: Binding(
                get: { fx.kind.isBuiltIn ? fx.kind : nil },
                set: { kind in if let kind { model.selectFX(kind, on: deck) } }
            )) {
                ForEach(MixFXKind.allCases.filter(\.isBuiltIn), id: \.self) { kind in
                    Text(kind.title).tag(Optional(kind))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if let plugin {
                Section("Plug-in") {
                    Toggle(plugin.name, isOn: Binding(
                        get: { fx.kind == .plugin },
                        set: { if $0 { model.selectFX(.plugin, on: deck) } }
                    ))
                    ForEach(presets.presets(for: slot)) { preset in
                        Button(preset.name) {
                            Task {
                                await rack.apply(preset, to: slot)
                                model.selectFX(.plugin, on: deck)
                            }
                        }
                    }
                }
            }
        } label: {
            menuLabel(effectTitle)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(MacDJControlButtonStyle())
        .fixedSize()
        .accessibilityLabel("Deck \(deck.label) Effect")
        .accessibilityValue(effectTitle)
    }

    private var beatsMenu: some View {
        Menu {
            Picker("Timing", selection: Binding(
                get: { fx.beats },
                set: { model.selectFXBeats($0, on: deck) }
            )) {
                ForEach(MixEngine.DeckFX.beatChoices, id: \.self) { beats in
                    Text(DJMixerUnits.beatsLabel(beats)).tag(beats)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            menuLabel(DJMixerUnits.beatsLabel(fx.beats))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(MacDJControlButtonStyle())
        .fixedSize()
        .disabled(fx.kind == .plugin)
        .accessibilityLabel("Deck \(deck.label) Effect Timing")
        .accessibilityValue(DJMixerUnits.beatsLabel(fx.beats))
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
    }
}
