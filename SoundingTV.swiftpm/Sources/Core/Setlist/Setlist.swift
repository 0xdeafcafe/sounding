import Foundation

enum SetlistSegmentSource: String, Codable, Sendable {
    case uploaderTracklist
    case shazam
    case listenerComment
    case user

    var displayName: String {
        switch self {
        case .uploaderTracklist: return "Uploader track list"
        case .shazam:            return "Shazam"
        case .listenerComment:   return "Listener comment"
        case .user:              return "Edited by you"
        }
    }
}

struct SetlistSegment: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var startSeconds: TimeInterval
    var observedAtSeconds: TimeInterval
    var artist: String?
    var title: String
    var version: String?
    var source: SetlistSegmentSource
    var confidence: Double
    var evidence: String?
    var shazamId: String?
    var soundCloudTrackId: String?
    var isUserEdited: Bool
    /// Per-entry revision metadata prevents an unrelated probe on another
    /// device from overwriting a newer user edit.
    var updatedAt: Date? = nil
    /// Deletions travel as tombstones. Removing the row outright would allow an
    /// older per-device CloudKit snapshot to resurrect it on the next merge.
    var deletedAt: Date? = nil

    var isDeleted: Bool { deletedAt != nil }

    var displayLabel: String {
        let base = [artist, title].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: artist == nil ? "" : " – ")
        guard let version, !version.isEmpty else { return base }
        return "\(base) (\(version))"
    }

    var searchQuery: String { displayLabel }
}

enum SetlistScanOutcome: String, Codable, Sendable {
    case matched
    case noMatch
    case failed
}

struct SetlistScanProbe: Codable, Equatable, Sendable {
    var positionSeconds: TimeInterval
    var outcome: SetlistScanOutcome
    var shazamId: String?
    var attemptedAt: Date
}

struct GeneratedSetlist: Codable, Equatable, Sendable {
    var trackId: String
    var trackTitle: String
    var duration: TimeInterval
    var segments: [SetlistSegment]
    var isSaved: Bool
    var updatedAt: Date
    /// Optional keeps v1 persisted setlists decodable. New scans always write
    /// an array and use it as a durable resume ledger for multi-hour sets.
    var probes: [SetlistScanProbe]? = nil
    /// Saved state has its own revision because scan progress must not undo a
    /// Save/Remove-from-Library action made on another device.
    var savedUpdatedAt: Date? = nil

    var completedProbeCount: Int { probes?.count ?? 0 }
    var recognizedProbeCount: Int { probes?.filter { $0.outcome == .matched }.count ?? 0 }

    func segment(at position: TimeInterval) -> SetlistSegment? {
        segments.filter { !$0.isDeleted }
            .sorted { $0.startSeconds < $1.startSeconds }
            .last(where: { $0.startSeconds <= position + 2 })
    }
}

@MainActor
enum SetlistSyncTarget {
    /// Installed by the full apps. Extensions keep this nil and remain local.
    static var requestSync: (() -> Void)?
}
