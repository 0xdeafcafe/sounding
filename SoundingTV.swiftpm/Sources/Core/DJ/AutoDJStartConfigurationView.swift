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
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        onStart(configuration)
                        dismiss()
                    }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
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
