import SwiftUI

struct LibrarySyncStatusLine: View {
    @ObservedObject private var engine = LibrarySyncEngine.shared
    var showsWhenComplete = false

    var body: some View {
        if let text = engine.statusText, engine.isBackfilling || showsWhenComplete {
            HStack(spacing: 8) {
                #if !os(tvOS)
                if engine.isBackfilling {
                    ProgressView()
                        .controlSize(.small)
                }
                #endif
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}

struct LibraryLoadingState: View {
    var style: LoadingPlaceholderStyle = .platformTrackList

    var body: some View {
        LoadingPlaceholder(style, showsSyncStatus: true)
    }
}

struct LibrarySyncStatusRow: View {
    @ObservedObject private var engine = LibrarySyncEngine.shared
    @ObservedObject private var analysis = AutomaticAnalysisStatus.shared

    var body: some View {
        if let text = engine.itemsText ?? engine.statusText {
            statusLine(text, busy: engine.isBackfilling)
        }
        if let text = analysis.backlogText {
            statusLine(text, busy: analysis.backlog.isRunning && analysis.backlog.pause == nil)
        }
    }

    private func statusLine(_ text: String, busy: Bool) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
            #if !os(tvOS)
            if busy {
                ProgressView()
                    .controlSize(.small)
            }
            #endif
        }
        .accessibilityElement(children: .combine)
    }
}
