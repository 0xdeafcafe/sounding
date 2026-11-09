import Foundation

enum SetlistText {
    /// Track lists frequently arrive with a mixture of tabs, non-breaking
    /// spaces, zero-width separators, and even the literal strings `\t`/`\n`.
    /// Keep that transport noise out of every set-list presentation and query.
    static func normalized(_ value: String) -> String {
        let decodedEscapes = value
            .replacingOccurrences(of: #"\\[tnr]"#, with: " ", options: .regularExpression)
        let visible = decodedEscapes.unicodeScalars.map { scalar -> String in
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
                || scalar.value == 0x200B
                || scalar.value == 0xFEFF {
                return " "
            }
            return String(scalar)
        }.joined()
        return visible
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = normalized(value)
        return result.isEmpty ? nil : result
    }
}

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
        let normalizedArtist = SetlistText.normalized(artist)
        let normalizedTitle = SetlistText.normalized(title)
        let base = [normalizedArtist, normalizedTitle]
            .compactMap { $0 }
            .joined(separator: normalizedArtist == nil ? "" : " – ")
        guard let version = SetlistText.normalized(version) else { return base }
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

    var activeSegments: [SetlistSegment] {
        segments.filter { !$0.isDeleted }.sorted { $0.startSeconds < $1.startSeconds }
    }

    /// The end of an entry is the next trustworthy boundary. The final entry
    /// runs to the end of the containing mix. This is more honest than trying
    /// to infer an exact transition length from a twelve-second fingerprint.
    func endSeconds(for segment: SetlistSegment) -> TimeInterval {
        let nextStart = activeSegments.first(where: { $0.startSeconds > segment.startSeconds + 0.5 })?.startSeconds
        return min(max(segment.startSeconds, nextStart ?? duration), max(duration, segment.startSeconds))
    }

    func durationSeconds(for segment: SetlistSegment) -> TimeInterval {
        max(0, endSeconds(for: segment) - segment.startSeconds)
    }

    func segment(at position: TimeInterval) -> SetlistSegment? {
        guard position >= 0, position <= duration else { return nil }
        return activeSegments.last(where: { $0.startSeconds <= position })
    }

    var tracklist: Tracklist { Tracklist(self) }
}

// MARK: - Tracklist

struct TracklistEntry: Identifiable, Equatable, Sendable {
    let index: Int
    let segment: SetlistSegment
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval

    var id: String { segment.id }
    var durationSeconds: TimeInterval { max(0, endSeconds - startSeconds) }

    func contains(_ position: TimeInterval) -> Bool {
        position >= startSeconds && position < endSeconds
    }
}

struct Tracklist: Equatable, Sendable {
    let trackId: String
    let duration: TimeInterval
    let entries: [TracklistEntry]

    init(_ setlist: GeneratedSetlist) {
        let active = setlist.activeSegments
        var entries: [TracklistEntry] = []
        entries.reserveCapacity(active.count)
        for (offset, segment) in active.enumerated() {
            let nextStart = active[(offset + 1)...]
                .first(where: { $0.startSeconds > segment.startSeconds + 0.5 })?
                .startSeconds
            let end = min(max(segment.startSeconds, nextStart ?? setlist.duration), max(setlist.duration, segment.startSeconds))
            entries.append(TracklistEntry(
                index: offset,
                segment: segment,
                startSeconds: segment.startSeconds,
                endSeconds: end
            ))
        }
        self.trackId = setlist.trackId
        self.duration = setlist.duration
        self.entries = entries
    }

    var isEmpty: Bool { entries.isEmpty }

    func currentIndex(at position: TimeInterval) -> Int? {
        guard position >= 0, position <= duration, !entries.isEmpty else { return nil }
        var low = 0
        var high = entries.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if entries[mid].startSeconds <= position {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    func currentEntry(at position: TimeInterval) -> TracklistEntry? {
        currentIndex(at: position).map { entries[$0] }
    }
}
