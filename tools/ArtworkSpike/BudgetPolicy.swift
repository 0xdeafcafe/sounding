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
