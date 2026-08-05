import Foundation

struct LikesPeerRecord: Codable, Sendable, Equatable {
    let id: String
    let payload: Data
    let likedAtMillis: Int64
    let title: String
    let artist: String
}

struct LikesPeerBody: Codable, Sendable, Equatable {
    let accountId: String
    let snapshotId: String
    let records: [LikesPeerRecord]
    let isComplete: Bool

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data) -> LikesPeerBody? {
        try? JSONDecoder().decode(LikesPeerBody.self, from: data)
    }
}

actor LikesPeerImportCoordinator {
    static let shared = LikesPeerImportCoordinator()

    private var generations: [String: Int64] = [:]

    @discardableResult
    func adopt(_ body: LikesPeerBody, expectedAccountId: String) async -> Int {
        guard body.accountId == expectedAccountId else { return 0 }
        let generation: Int64
        if let existing = generations[body.snapshotId] {
            generation = existing
        } else {
            let current = Int64(await LibraryCache.shared.syncValue(forKey: "likes.generation") ?? "0") ?? 0
            generation = max(current + 1, Int64(Date().timeIntervalSince1970 * 1_000))
            generations[body.snapshotId] = generation
        }

        let rows = body.records.map {
            LibraryCache.LikeIndexRow(
                id: $0.id,
                payload: $0.payload,
                likedAtMillis: $0.likedAtMillis,
                title: $0.title,
                artist: $0.artist
            )
        }
        await LibraryCache.shared.upsertLikes(rows, generation: generation)
        if body.isComplete {
            _ = await LibraryCache.shared.pruneLikes(olderThanGeneration: generation)
            await LibraryCache.shared.setSyncValue(String(generation), forKey: "likes.generation")
            await LibraryCache.shared.setSyncValue(
                String(Date().timeIntervalSince1970), forKey: "likes.completedAt"
            )
            generations[body.snapshotId] = nil
        }
        await LikesSyncEngine.shared.didAdoptPeerLikes()
        return rows.count
    }
}
