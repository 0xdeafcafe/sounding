import Foundation
import SwiftUI

struct TrackAnalysisSummary: Sendable, Equatable {
    var bpm: Double?
    var key: CamelotKey?
    var genre: String?
    var bpmProvenance: SCAnalysisProvenance = .inferred
    var keyProvenance: SCAnalysisProvenance = .inferred
    var genreProvenance: SCAnalysisProvenance = .inferred

    var isEmpty: Bool { bpm == nil && key == nil && genre == nil }
}

@MainActor
enum AnalysisLookup {
    static var liveGenerations: [AnalysisProducerGeneration] {
        AnalysisProducerRegistry.v1.liveGenerations + [
            AnalysisProducerGeneration(
                producerId: "user",
                tier: .materialisedAudio,
                generation: AnalysisGeneration(engine: .userCorrection(), schemaVersion: 1)
            )
        ]
    }

    static func summaries(for tracks: [Track]) async -> [String: TrackAnalysisSummary] {
        await summaries(for: tracks, cache: AnalysisCache.shared)
    }

    static func summaries(for tracks: [Track], cache: AnalysisCache) async -> [String: TrackAnalysisSummary] {
        guard !tracks.isEmpty else { return [:] }

        var fingerprintByTrackID: [String: AnalyzedAudioFingerprint] = [:]
        for track in tracks {
            let transcoding = track.transcodings.max { $0.playbackRank < $1.playbackRank }
            guard let fingerprint = AnalyzedAudioFingerprint(duration: track.duration, transcoding: transcoding) else { continue }
            fingerprintByTrackID[track.id] = fingerprint
        }
        guard !fingerprintByTrackID.isEmpty else { return [:] }

        let live = liveGenerations
        var tierByEngine: [AnalysisEngineIdentity: AnalysisTier] = [:]
        for entry in live { tierByEngine[entry.generation.engine] = entry.tier }

        let rowsByTrackID = await cache.recallRows(
            forTrackIds: Array(fingerprintByTrackID.keys),
            scope: .engines(Array(tierByEngine.keys))
        )
        guard !rowsByTrackID.isEmpty else { return [:] }

        var result: [String: TrackAnalysisSummary] = [:]
        for (trackID, fingerprint) in fingerprintByTrackID {
            guard let rows = rowsByTrackID[trackID] else { continue }
            let summary = merge(rows: rows, fingerprint: fingerprint, tierByEngine: tierByEngine)
            guard !summary.isEmpty else { continue }
            result[trackID] = summary
        }
        return result
    }

    private static func merge(
        rows: [AnalysisRecallRow],
        fingerprint: AnalyzedAudioFingerprint,
        tierByEngine: [AnalysisEngineIdentity: AnalysisTier]
    ) -> TrackAnalysisSummary {
        let ranked = rows
            .compactMap { row -> (row: AnalysisRecallRow, authority: Int)? in
                guard row.fingerprint == fingerprint else { return nil }
                guard let tier = tierByEngine[row.generation.engine] else { return nil }
                return (row, authority(of: tier))
            }
            .sorted {
                $0.authority != $1.authority
                    ? $0.authority < $1.authority
                    : $0.row.generation.schemaVersion > $1.row.generation.schemaVersion
            }

        var summary = TrackAnalysisSummary()
        for entry in ranked {
            let row = entry.row
            let provenance: SCAnalysisProvenance =
                entry.authority == authority(of: .materialisedAudio) ? .measured : .inferred
            if summary.bpm == nil, let bpm = row.bpm, bpm.isFinite, bpm > 0 {
                summary.bpm = bpm
                summary.bpmProvenance = provenance
            }
            if summary.key == nil, let key = row.key {
                summary.key = key
                summary.keyProvenance = provenance
            }
            if summary.genre == nil, let genre = row.genre, !genre.isEmpty {
                summary.genre = genre
                summary.genreProvenance = provenance
            }
        }
        return summary
    }

    private static func authority(of tier: AnalysisTier) -> Int {
        switch tier {
        case .materialisedAudio: return 0
        case .metadata: return 1
        }
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
