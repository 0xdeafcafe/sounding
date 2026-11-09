import SwiftUI

struct AutoMixRatingView: View {
    @State private var store = AutoMixFeedbackStore.shared

    var body: some View {
        if let pending = store.pending {
            HStack(spacing: 12) {
                Text("How was that mix?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    store.rate(liked: true)
                } label: {
                    Label("Nice", systemImage: "hand.thumbsup")
                }
                Button {
                    store.rate(liked: false)
                } label: {
                    Label("Not Great", systemImage: "hand.thumbsdown")
                }
                #if !os(tvOS)
                MixSaveLatestButton()
                #endif
            }
            .buttonStyle(.bordered)
            .id(pending.id)
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Rate the mix into \(pending.incomingTitle ?? "this track")")
        }
    }
}

struct MixSaveLatestButton: View {
    var title = "Save Mix"
    var iconOnly = true
    @State private var history = MixHistoryStore.shared

    var body: some View {
        let saved = history.latest.map(history.isSaved) ?? false
        Button {
            history.saveLatest()
        } label: {
            if iconOnly {
                Label(saved ? "Saved" : title, systemImage: saved ? "bookmark.fill" : "bookmark")
                    .labelStyle(.iconOnly)
            } else {
                Label(saved ? "Saved" : title, systemImage: saved ? "bookmark.fill" : "bookmark")
            }
        }
        .disabled(history.latest == nil || saved)
        .accessibilityLabel(saved ? "Mix saved" : title)
    }
}

struct AutoMixLearnedPreferencesRow: View {
    @State private var store = AutoMixFeedbackStore.shared
    @State private var confirming = false

    var body: some View {
        Button("Reset Learned Mix Preferences", role: .destructive) {
            confirming = true
        }
        .disabled(!store.hasLearned)
        .confirmationDialog("Reset learned mix preferences?", isPresented: $confirming) {
            Button("Reset", role: .destructive) { store.reset() }
        } message: {
            Text("Auto Mix forgets how you rated its transitions.")
        }
    }
}
