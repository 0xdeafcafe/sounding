import SwiftUI

struct AutoMixIntentSection: View {
    @ObservedObject private var store = AutoMixIntentStore.shared
    @State private var text = ""
    @State private var missed = false

    var body: some View {
        Section {
            TextField("Tell Auto Mix…", text: $text, prompt: Text("Warm-up set, peak by midnight, no vocals until 11"))
                .onSubmit(submit)
                .disabled(store.isWorking)
            if store.isWorking {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let active = store.current {
                ForEach(active.intent.summaryParts, id: \.self) { part in
                    Text(part)
                }
                Button("Clear", role: .destructive) {
                    store.clear()
                    text = ""
                }
            }
        } header: {
            Text("Tonight")
        } footer: {
            Text(missed ? "Auto Mix didn’t catch that. Try energy, vocals, tempo or a time." : "Auto Mix plans the set around what you ask for.")
        }
        .onAppear {
            if text.isEmpty, let active = store.current { text = active.intent.text }
        }
    }

    private func submit() {
        let request = text
        Task {
            let outcome = await store.submit(request)
            missed = outcome == .notUnderstood
        }
    }
}

struct AutoMixWhyText: View {
    let why: String
    @State private var line: String?

    var body: some View {
        Text(line ?? why)
            .task(id: why) {
                line = nil
                let natural = await AutoMixLanguage().whyLine(PickReason.split(why))
                line = natural == PickReason.deterministicLine(PickReason.split(why)) ? nil : natural
            }
    }
}

struct AutoMixFlairSummary: View {
    let lines: [String]
    @State private var summary: String?

    var body: some View {
        Group {
            if let summary {
                Text(summary)
            }
        }
        .task(id: lines) {
            summary = await AutoMixLanguage().flairSummary(lines)
        }
    }
}
