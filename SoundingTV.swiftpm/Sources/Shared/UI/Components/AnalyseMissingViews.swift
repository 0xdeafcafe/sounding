import SwiftUI

struct AnalyseMissingMenuItems: View {
    let tracks: [Track]
    let scopeTitle: String?

    @ObservedObject private var summaries = AnalysisSummaries.shared
    @ObservedObject private var run = MissingAnalysisRun.shared

    init(tracks: [Track], scopeTitle: String? = nil) {
        self.tracks = tracks
        self.scopeTitle = scopeTitle
    }

    private var analysesElsewhere: Bool {
        DeviceClass.current == .tv || DeviceClass.current == .watch
    }

    var body: some View {
        let count = run.count(in: tracks)
        if isOffered(count) {
            Button {
                run.start(tracks)
            } label: {
                Label("Analyse Missing", systemImage: "waveform.badge.magnifyingglass")
                if let detail = detail(count) {
                    Text(detail)
                }
            }
            .disabled(!analysesElsewhere && count?.missing == 0)
        }
    }

    private func isOffered(_ count: MissingAnalysisCount?) -> Bool {
        guard !tracks.isEmpty else { return false }
        guard tracks.count == 1, let track = tracks.first else { return true }
        guard let count, count.missing > 0 else { return false }
        if analysesElsewhere { return true }
        guard count.analysable > 0 else { return false }
        let summary = summaries.summary(for: track)
        return summary?.bpm != nil || summary?.key != nil
    }

    private func detail(_ count: MissingAnalysisCount?) -> String? {
        guard !analysesElsewhere, tracks.count > 1, let count, count.analysable > 0 else { return scopeTitle }
        let tracks = AnalysisStatusCopy.tracks(count.analysable)
        guard let scopeTitle else { return tracks }
        return "\(tracks) · \(scopeTitle)"
    }
}

struct MissingAnalysisProgressLine: View {
    @ObservedObject private var run = MissingAnalysisRun.shared

    var body: some View {
        if run.statusLine != nil || run.message != nil {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let status = run.statusLine {
                    HStack(spacing: Spacing.sm) {
                        Text(status)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer(minLength: Spacing.sm)
                        if run.isPaused {
                            Button("Resume") { run.resume() }
                        } else {
                            Button("Pause") { run.pause() }
                        }
                        Button("Stop") { run.stop() }
                    }
                }
                if let message = run.message {
                    HStack(spacing: Spacing.sm) {
                        Text(message)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: Spacing.sm)
                        Button("OK") { run.dismissMessage() }
                    }
                }
            }
            .font(.footnote)
            .buttonStyle(.borderless)
            .padding(.vertical, Spacing.xs)
        }
    }
}
