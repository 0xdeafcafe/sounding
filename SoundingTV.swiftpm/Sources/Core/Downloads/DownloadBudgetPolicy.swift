import Foundation

enum DownloadBudgetPolicy {
    struct Entry {
        let id: String
        let bytes: Int64
        let lastPlayedAt: Date
        let isPinned: Bool
    }

    static func victims(entries: [Entry], maxBytes: Int64) -> [String] {
        guard maxBytes >= 0 else { return [] }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > maxBytes else { return [] }

        let candidates = entries
            .filter { !$0.isPinned }
            .sorted { $0.lastPlayedAt < $1.lastPlayedAt }

        var victims: [String] = []
        for entry in candidates {
            guard total > maxBytes else { break }
            victims.append(entry.id)
            total -= entry.bytes
        }
        return victims
    }
}

enum OptimiseStoragePolicy {
    struct Candidate: Equatable {
        let id: String
        let bytes: Int64
        let lastPlayedAt: Date
    }

    static let lowSpaceThresholdBytes: Int64 = 2_000_000_000
    static let targetFreeBytes: Int64 = 4_000_000_000
    static let recentlyPlayedWindow: TimeInterval = 24 * 60 * 60
    static let admissionReserveBytes: Int64 = 500_000_000
    static let minimumChoices: [Int64] = [0, 4_000_000_000, 8_000_000_000, 16_000_000_000, 32_000_000_000]

    static func victims(
        candidates: [Candidate],
        availableBytes: Int64,
        minimumKeptBytes: Int64,
        now: Date = Date(),
        lowSpaceThreshold: Int64 = lowSpaceThresholdBytes,
        targetFree: Int64 = targetFreeBytes,
        recentWindow: TimeInterval = recentlyPlayedWindow
    ) -> [String] {
        guard availableBytes < lowSpaceThreshold else { return [] }
        var deficit = max(targetFree, lowSpaceThreshold) - availableBytes
        var kept = candidates.reduce(Int64(0)) { $0 + $1.bytes }
        let cutoff = now.addingTimeInterval(-recentWindow)
        let ordered = candidates
            .filter { $0.lastPlayedAt <= cutoff }
            .sorted { ($0.lastPlayedAt, $0.id) < ($1.lastPlayedAt, $1.id) }

        var victims: [String] = []
        for candidate in ordered {
            guard deficit > 0 else { break }
            guard kept - candidate.bytes >= minimumKeptBytes else { continue }
            victims.append(candidate.id)
            deficit -= candidate.bytes
            kept -= candidate.bytes
        }
        return victims
    }

    static func admitsNewTransfers(availableBytes: Int64?) -> Bool {
        guard let availableBytes else { return true }
        return availableBytes >= admissionReserveBytes
    }
}
