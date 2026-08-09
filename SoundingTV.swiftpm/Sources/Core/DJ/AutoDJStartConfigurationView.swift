import SwiftUI

/// A deliberately short, native sheet shown before an unconfigured Auto DJ
/// session begins. It is shared so a phone, Mac, and TV never disagree about
/// what these three choices mean.
struct AutoDJStartConfigurationView: View {
    @Environment(\.dismiss) private var dismiss

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

    #if os(tvOS)
    private var tvOSBody: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
            HStack(alignment: .top, spacing: Space.base) {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text("Start Auto DJ")
                        .font(.tvTitle)
                    Text("Choose how the next tracks are selected.")
                        .font(.tvCallout)
                        .foregroundStyle(Color.scTextSecondary)
                }

                Spacer(minLength: Space.roomy)

                Button("Cancel") { cancel() }
                    .buttonStyle(.bordered)

                Button("Start") { start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.scAccent)
            }

            Divider()
                .overlay(Color.scSeparator)

            configurationChoice(
                title: "Long mixes",
                explanation: "Sets are long-form uploads. This only controls what Auto DJ selects next."
            ) {
                Picker("Long mixes", selection: $configuration.setHandling) {
                    Text("Include sets").tag(DJSetHandling.include)
                    Text("Skip sets").tag(DJSetHandling.skip)
                }
            }

            configurationChoice(
                title: "Music source",
                explanation: configuration.sourceStrategy.explanation
            ) {
                Picker("Music source", selection: $configuration.sourceStrategy) {
                    ForEach(DJSourceStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
            }

            configurationChoice(
                title: "Play order",
                explanation: orderExplanation
            ) {
                Picker("Play order", selection: $configuration.queueOrder) {
                    Text("Random").tag(DJQueueOrderPolicy.random)
                    Text("Energy match").tag(DJQueueOrderPolicy.mayReorder)
                    Text("Exact order").tag(DJQueueOrderPolicy.preserve)
                }
            }
        }
        .padding(Space.section)
        .frame(width: 1_120, height: 760, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Corner.panel, style: .continuous)
                .fill(Color.scBgRaised.opacity(0.92))
        )
        .onExitCommand { cancel() }
    }

    private func configurationChoice<Content: View>(
        title: String,
        explanation: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Space.base) {
                Text(title)
                    .font(.tvCalloutEmph)
                    .frame(width: 190, alignment: .leading)

                control()
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
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
                Section("Long mixes") {
                    Picker("Sets", selection: $configuration.setHandling) {
                        Text("Include Sets").tag(DJSetHandling.include)
                        Text("Skip Sets").tag(DJSetHandling.skip)
                    }
                    Text("A set is a long-form upload. You can still play one yourself; this only controls what Auto DJ selects next.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Music source") {
                    Picker("Source", selection: $configuration.sourceStrategy) {
                        ForEach(DJSourceStrategy.allCases) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }
                    Text(configuration.sourceStrategy.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Play order") {
                    Picker("Order", selection: $configuration.queueOrder) {
                        Text("Random").tag(DJQueueOrderPolicy.random)
                        Text("Good Energy Matches").tag(DJQueueOrderPolicy.mayReorder)
                        Text("Keep Exact Order").tag(DJQueueOrderPolicy.preserve)
                    }
                    Text(orderExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Start Auto DJ")
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
        .presentationDetents([.medium])
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
            return "Uses the selected Auto DJ profile's normal order rule."
        }
    }
}
