import SwiftUI

struct GeneratedTagChips: View {
    let tags: [String]
    var font: Font = .footnote
    var foreground: Color = .secondary
    var fill: Color = Color.secondary.opacity(0.14)

    var body: some View {
        if !tags.isEmpty {
            ChipFlowLayout(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(font)
                    .foregroundStyle(foreground)
                    .padding(.vertical, 4)
                    .accessibilityHidden(true)
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(font)
                        .foregroundStyle(foreground)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(fill, in: Capsule())
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Generated tags: \(tags.joined(separator: ", "))")
        }
    }
}

struct GeneratedSummaryBlock: View {
    let title: String
    let text: String
    var foreground: Color = .primary
    var secondary: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Generated on this device")
    }
}

struct GeneratedInsightsSection: View {
    let insights: GeneratedInsights?
    var foreground: Color = .primary
    var secondary: Color = .secondary
    var chipFill: Color = Color.secondary.opacity(0.14)

    var body: some View {
        if let insights {
            VStack(alignment: .leading, spacing: 14) {
                if let summary = insights.setSummary {
                    GeneratedSummaryBlock(title: "Summary", text: summary, foreground: foreground, secondary: secondary)
                }
                if let summary = insights.commentSummary {
                    GeneratedSummaryBlock(title: "What People Are Saying", text: summary, foreground: foreground, secondary: secondary)
                }
                GeneratedTagChips(tags: insights.tags, foreground: secondary, fill: chipFill)
            }
        }
    }
}

enum GeneratedInsightInputs {
    @MainActor
    static func input(for track: Track, comments: [Comment], waveform: [Float]?) -> InsightInput {
        let summary = AnalysisSummaries.shared.summary(for: track.id)
        let tracklist = SetlistIntelligenceStore.shared.setlist(for: track.id)?.activeSegments.map { segment in
            [segment.artist, segment.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – ")
        } ?? []
        return InsightInput(
            track: track,
            comments: comments,
            tracklist: tracklist,
            bpm: summary?.bpm,
            key: summary?.key?.label,
            energy: waveform.flatMap(energy)
        )
    }

    static func energy(_ samples: [Float]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let peak = samples.max() ?? 0
        guard peak > 0 else { return nil }
        let mean = samples.reduce(0, +) / Float(samples.count)
        return Double(mean / peak)
    }
}
