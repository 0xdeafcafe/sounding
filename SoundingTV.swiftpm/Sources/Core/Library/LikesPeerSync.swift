import Foundation

actor LikesPeerImportCoordinator {
    static let shared = LikesPeerImportCoordinator(cache: .shared)

    private let cache: LibraryCache
    private var generations: [String: Int64] = [:]

    init(cache: LibraryCache) {
        self.cache = cache
    }

    @discardableResult
    func adopt(_ body: LikesPeerBody, expectedAccountId: String) async -> Int {
        guard body.accountId == expectedAccountId else { return 0 }
        let generation: Int64
        if let existing = generations[body.snapshotId] {
            generation = existing
        } else {
            let current = Int64(await cache.syncValue(forKey: "likes.generation") ?? "0") ?? 0
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
        await cache.upsertLikes(rows, generation: generation)
        if body.isComplete {
            _ = await cache.pruneLikes(olderThanGeneration: generation)
            await cache.setSyncValue(String(generation), forKey: "likes.generation")
            await cache.setSyncValue(
                String(Date().timeIntervalSince1970), forKey: "likes.completedAt"
            )
            generations[body.snapshotId] = nil
        }
        return rows.count
    }
}
