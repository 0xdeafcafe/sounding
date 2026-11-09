import Foundation
import SwiftUI

struct TrackAnalysisSummary: Sendable, Equatable {
    var bpm: Double?
    var key: CamelotKey?
    var genre: String?
    var energy: Int? = nil
    var bpmProvenance: SCAnalysisProvenance = .inferred
    var keyProvenance: SCAnalysisProvenance = .inferred
    var genreProvenance: SCAnalysisProvenance = .inferred

    var isEmpty: Bool { bpm == nil && key == nil && genre == nil }
}

extension TrackAnalysisSummary {
    init(_ summary: AnalysisFeatureSummary) {
        self.init(
            bpm: summary.bpm,
            key: summary.key,
            genre: summary.genre,
            bpmProvenance: Self.provenance(summary.bpmAuthority),
            keyProvenance: Self.provenance(summary.keyAuthority),
            genreProvenance: Self.provenance(summary.genreAuthority)
        )
    }

    static func provenance(_ authority: AnalysisAuthority?) -> SCAnalysisProvenance {
        switch authority {
        case .corrected: return .stated
        case .measured: return .measured
        case .estimated, nil: return .inferred
        }
    }
}

@MainActor
enum AnalysisLookup {
    static var liveGenerations: [AnalysisProducerGeneration] {
        AnalysisSummaryStore.liveGenerations
    }

    static func summary(for track: Track) -> TrackAnalysisSummary? {
        AnalysisSummaries.shared.summary(for: track).map(TrackAnalysisSummary.init)
    }

    static func summaries(for tracks: [Track]) async -> [String: TrackAnalysisSummary] {
        await AnalysisSummaries.shared.summaries(for: tracks).mapValues(TrackAnalysisSummary.init)
    }

    static func summaries(for tracks: [Track], cache: AnalysisCache) async -> [String: TrackAnalysisSummary] {
        await AnalysisSummaryStore.summaries(for: tracks, cache: cache).mapValues(TrackAnalysisSummary.init)
    }
}

extension TrackAnalysisSummary {
    func badgeRow(style: SCContentStyle) -> SCAnalysisBadgeRow {
        SCAnalysisBadgeRow(
            bpm: bpm.map { (value: "\(Int($0.rounded()))", provenance: bpmProvenance) },
            key: key.map { (value: $0.label, provenance: keyProvenance) },
            genre: genre.map { (value: $0, provenance: genreProvenance) },
            style: style
        )
    }
}

extension TrackAnalysisSummary {
    var spokenDescription: String? {
        var parts: [String] = []
        if let bpm { parts.append("\(Int(bpm.rounded())) BPM") }
        if let key { parts.append("key \(key.label)") }
        if let genre, !genre.isEmpty { parts.append(GenrePresentation.displayName(for: genre)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

enum TrackAccessibility {
    static func label(
        title: String,
        artist: String,
        duration: String? = nil,
        isDownloaded: Bool = false,
        isUnavailable: Bool = false,
        analysis: TrackAnalysisSummary? = nil
    ) -> String {
        var parts = [title, artist]
        if let duration { parts.append(duration) }
        if isDownloaded { parts.append("downloaded") }
        if let spoken = analysis?.spokenDescription { parts.append(spoken) }
        if isUnavailable { parts.append("unavailable") }
        return parts.joined(separator: ", ")
    }
}
