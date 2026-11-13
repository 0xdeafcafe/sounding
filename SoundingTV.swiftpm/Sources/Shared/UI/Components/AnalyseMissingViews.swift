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
        guard !analysesElsewhere, tracks.count > 1, let count, count.missing > 0 else { return scopeTitle }
        let tracks = count.analysable > 0 ? AnalysisStatusCopy.tracks(count.analysable) : "Download tracks first"
        guard let scopeTitle else { return tracks }
        return "\(tracks) · \(scopeTitle)"
    }
}

struct MissingAnalysisProgressLine: View {
    @ObservedObject private var run = MissingAnalysisRun.shared

    var body: some View {
        if run.hasStatus {
            VStack(alignment: .leading, spacing: 4) {
                if let status = run.statusLine {
                    HStack(spacing: 8) {
                        if run.isPreparing, !run.isActive {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(status)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer(minLength: 8)
                        if run.isActive {
                            if run.isPaused {
                                Button("Resume") { run.resume() }
                            } else {
                                Button("Pause") { run.pause() }
                            }
                            Button("Stop") { run.stop() }
                        }
                    }
                    if run.isActive {
                        ProgressView(value: Double(run.progress.done), total: Double(max(1, run.progress.total)))
                            .labelsHidden()
                    }
                }
                if let message = run.message {
                    HStack(spacing: 8) {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("OK") { run.dismissMessage() }
                    }
                }
            }
            .font(.footnote)
            .buttonStyle(.borderless)
            .padding(.vertical, 4)
            .animation(.smooth, value: run.statusLine)
        }
    }
}
