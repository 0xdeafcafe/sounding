import SwiftUI

private enum AutoDJStartOptionText {
    static let includeSets = "Include Sets"
    static let skipSets = "Skip Sets"
    static let random = "Random"
    static let goodEnergyMatches = "Good Energy Matches"
    static let keepExactOrder = "Keep Exact Order"
}

private enum AutoDJStartLayout {
    static let tight: CGFloat = 8
    static let base: CGFloat = 24
    static let roomy: CGFloat = 32
    static let section: CGFloat = 48
    static let panelRadius: CGFloat = 32
}

/// A deliberately short, native sheet shown before an unconfigured Auto DJ
/// session begins. It is shared so a phone, Mac, and TV never disagree about
/// what these three choices mean.
struct AutoDJStartConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared

    private let onStart: (DJStartConfiguration) -> Void
    private let onCancel: () -> Void
    @State private var configuration: DJStartConfiguration

    init(
        configuration: DJStartConfiguration = SettingsStore.shared.djStartConfiguration,
        onStart: @escaping (DJStartConfiguration) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        _configuration = State(initialValue: configuration)
        self.onStart = onStart
        self.onCancel = onCancel
    }

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        standardBody
        #endif
    }

    private var selectedProfile: DJProfile {
        DJProfile.profile(id: settings.djDefaultProfileId) ?? .automaticDJ
    }

    private var summaryText: String {
        let source = configuration.sourceStrategy == .goodMatches ? "Good matches" : "Your queue"
        return "\(source) \u{00B7} \(selectedProfile.styleName) \u{00B7} \(settings.djBlend.displayName) blends"
    }

    #if os(tvOS)
    private var tvOSBody: some View {
        VStack(alignment: .leading, spacing: AutoDJStartLayout.base) {
            HStack(alignment: .top, spacing: AutoDJStartLayout.base) {
                VStack(alignment: .leading, spacing: AutoDJStartLayout.tight) {
                    Text("Start Auto Mix")
                        .font(.tvTitle)
                    Text("Choose a personality, then how the next tracks are selected.")
                        .font(.tvCallout)
                        .foregroundStyle(Color.scTextSecondary)
                }

                Spacer(minLength: AutoDJStartLayout.roomy)

                Button("Cancel") { cancel() }
                    .buttonStyle(.bordered)

                Button("Start") { start() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("autoMix.start")
            }

            Divider()
                .overlay(Color.scSeparator)

            configurationChoice(
                title: "Style",
                explanation: selectedProfile.blurb
            ) {
                TVGlassTabs(
                    options: DJProfile.all.map { TVGlassTabs.Option(value: $0.id, title: $0.styleName) },
                    selection: settings.djDefaultProfileIdBinding
                )
            }

            configurationChoice(
                title: "Blend",
                explanation: "8, 16 or 32 bars."
            ) {
                TVGlassTabs(
                    options: DJBlendLength.allCases.map { TVGlassTabs.Option(value: $0, title: $0.displayName) },
                    selection: settings.djBlendBinding
                )
            }

            Divider()
                .overlay(Color.scSeparator)

            configurationChoice(
                title: "Long mixes",
                explanation: "Sets are long-form uploads. This only controls what Auto Mix selects next."
            ) {
                TVGlassTabs(
                    options: [
                        .init(value: DJSetHandling.include, title: AutoDJStartOptionText.includeSets),
                        .init(value: DJSetHandling.skip, title: AutoDJStartOptionText.skipSets)
                    ],
                    selection: $configuration.setHandling
                )
            }

            configurationChoice(
                title: "Music source",
                explanation: configuration.sourceStrategy.explanation
            ) {
                TVGlassTabs(
                    options: DJSourceStrategy.allCases.map { TVGlassTabs.Option(value: $0, title: $0.displayName) },
                    selection: $configuration.sourceStrategy
                )
            }

            configurationChoice(
                title: "Play order",
                explanation: orderExplanation
            ) {
                TVGlassTabs(
                    options: [
                        .init(value: DJQueueOrderPolicy.random, title: AutoDJStartOptionText.random),
                        .init(value: DJQueueOrderPolicy.mayReorder, title: AutoDJStartOptionText.goodEnergyMatches),
                        .init(value: DJQueueOrderPolicy.preserve, title: AutoDJStartOptionText.keepExactOrder)
                    ],
                    selection: $configuration.queueOrder
                )
            }
        }
        .padding(AutoDJStartLayout.section)
        .frame(width: 1_120, height: 940, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: AutoDJStartLayout.panelRadius, style: .continuous)
                .fill(Color.scBgRaised.opacity(0.92))
        )
        .onExitCommand { cancel() }
    }

    private func configurationChoice<Content: View>(
        title: String,
        explanation: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AutoDJStartLayout.tight) {
            HStack(alignment: .firstTextBaseline, spacing: AutoDJStartLayout.base) {
                Text(title)
                    .font(.tvCalloutEmph)
                    .frame(width: 190, alignment: .leading)

                control()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(explanation)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(Color.scTextTertiary)
                .padding(.leading, 214)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    #endif

    #if !os(tvOS)
    private var standardBody: some View {
        NavigationStack {
            Form {
                Section("Style") {
                    Picker("Style", selection: settings.djDefaultProfileIdBinding) {
                        ForEach(DJProfile.all) { profile in
                            Text(profile.styleName).tag(profile.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    #if os(macOS)
                    .labelsHidden()
                    #endif
                    Text(selectedProfile.blurb)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Picker("Blend", selection: settings.djBlendBinding) {
                        ForEach(DJBlendLength.allCases) { blend in
                            Text(blend.displayName).tag(blend)
                        }
                    }
                } footer: {
                    Text("8, 16 or 32 bars.")
                }

                Section("Long mixes") {
                    Picker("Sets", selection: $configuration.setHandling) {
                        Text(AutoDJStartOptionText.includeSets).tag(DJSetHandling.include)
                        Text(AutoDJStartOptionText.skipSets).tag(DJSetHandling.skip)
                    }
                    #if os(macOS)
                    .labelsHidden()
                    #endif
                    Text("A set is a long-form upload. You can still play one yourself; this only controls what Auto Mix selects next.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Music source") {
                    Picker("Source", selection: $configuration.sourceStrategy) {
                        ForEach(DJSourceStrategy.allCases) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }
                    #if os(macOS)
                    .labelsHidden()
                    #endif
                    Text(configuration.sourceStrategy.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Play order") {
                    Picker("Order", selection: $configuration.queueOrder) {
                        Text(AutoDJStartOptionText.random).tag(DJQueueOrderPolicy.random)
                        Text(AutoDJStartOptionText.goodEnergyMatches).tag(DJQueueOrderPolicy.mayReorder)
                        Text(AutoDJStartOptionText.keepExactOrder).tag(DJQueueOrderPolicy.preserve)
                    }
                    #if os(macOS)
                    .labelsHidden()
                    #endif
                    Text(orderExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Text(summaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Start Auto Mix")
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }
    #endif

    private func cancel() {
        onCancel()
        dismiss()
    }

    private func start() {
        onStart(configuration)
        dismiss()
    }

    private var orderExplanation: String {
        switch configuration.queueOrder {
        case .random:
            return "Shuffles what is still to play, while leaving the current track alone."
        case .mayReorder:
            return "Looks ahead and promotes the most compatible next track from the available source."
        case .preserve:
            return "Mixes into the next track in the exact queue order."
        case .profileDefault:
            return "Uses the selected Auto Mix profile's normal order rule."
        }
    }
}

#if os(tvOS)
struct TVGlassTabs<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    let options: [Option]
    @Binding var selection: Value

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                    } label: {
                        Text(option.title)
                            .font(.tvCalloutEmph)
                            .lineLimit(1)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(TVGlassTabStyle(isSelected: selection == option.value))
                    .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                }
            }
        }
        .focusSection()
    }
}

private struct TVGlassTabStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isSelected: isSelected)
    }

    private struct Styled: View {
        let configuration: Configuration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .background {
                    if isFocused { Capsule().fill(Color.scChromeFocus) }
                }
                .glassEffect(
                    isFocused ? .identity : (isSelected ? .regular.tint(.white.opacity(0.32)) : .regular),
                    in: Capsule()
                )
                .contentShape(Capsule())
                .scaleEffect(isFocused ? 1.08 : 1)
                .shadow(color: isFocused ? Color.black.opacity(0.4) : .clear, radius: 16, y: 8)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}
#endif
