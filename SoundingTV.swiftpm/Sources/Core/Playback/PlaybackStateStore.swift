import Foundation

enum PlaybackStateStore {
    private static let defaultsKey = "red.forbes.sounding.playbackState.v1"
    private static let encryptedKeyPrefix = "red.forbes.sounding.playbackState.encrypted.v1."
    private static let rememberedAccountKey = "red.forbes.sounding.playbackState.account.v1"
    private static let purpose = "playback-state-v1"

    struct Snapshot: Codable, Equatable {
        var trackIds: [String]
        var currentIndex: Int
        var positionSeconds: TimeInterval
        var isShuffleEnabled: Bool
        var repeatMode: RepeatMode
        var collectionId: String? = nil
        var queueSource: PlaybackQueueSource? = nil
        var djProfileId: DJProfileID? = nil
        var collectionAutoMixWasActive: Bool? = nil
        var autoMixWasActive: Bool? = nil
        var djSessionWasRequested: Bool? = nil
        var originalTrackIds: [String]? = nil
        var currentTrackPayload: Data? = nil
        var savedAt: Date

        var currentTrackId: String? {
            trackIds.indices.contains(currentIndex) ? trackIds[currentIndex] : nil
        }

        var wantsMix: Bool {
            collectionAutoMixWasActive == true || autoMixWasActive == true
        }
    }

    static func save(_ snapshot: Snapshot, accountID: String) {
        guard let data = try? JSONEncoder().encode(snapshot),
              let sealed = AccountDataVault.seal(data, accountID: accountID, purpose: purpose) else { return }
        UserDefaults.sounding.set(sealed, forKey: encryptedKey(accountID))
        if accountID != PlaybackPersistenceAccountPolicy.guestAccountID {
            UserDefaults.sounding.set(accountID, forKey: rememberedAccountKey)
        }
    }

    static func load(accountID: String) -> Snapshot? {
        let key = encryptedKey(accountID)
        let snapshot: Snapshot?
        if let sealed = UserDefaults.sounding.data(forKey: key),
           let data = AccountDataVault.open(sealed, accountID: accountID, purpose: purpose) {
            snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        } else {
            snapshot = migrateLegacyState(accountID: accountID)
        }
        if let snapshot, snapshot.trackIds.contains(where: isFixtureTrackID) {
            clear(accountID: accountID)
            return nil
        }
        return snapshot
    }

    static var rememberedAccountID: String? {
        UserDefaults.sounding.string(forKey: rememberedAccountKey)
    }

    static func forgetRememberedAccount() {
        UserDefaults.sounding.removeObject(forKey: rememberedAccountKey)
    }

    static func encodeTrack(_ track: Track) -> Data? {
        try? LikesSyncEngine.makeEncoder().encode(track)
    }

    static func decodeTrack(_ data: Data) -> Track? {
        try? LikesSyncEngine.makeDecoder().decode(Track.self, from: data)
    }

    private static func isFixtureTrackID(_ id: String) -> Bool {
        guard let value = Int(id) else { return false }
        return (1_000..<3_000).contains(value)
    }

    static func clear(accountID: String) {
        UserDefaults.sounding.removeObject(forKey: encryptedKey(accountID))
    }

    private static func encryptedKey(_ accountID: String) -> String {
        encryptedKeyPrefix + AccountDataVault.storageSuffix(for: accountID)
    }

    // LEGACY MIGRATION: remove after the account-vault rollout window.
    private static func migrateLegacyState(accountID: String) -> Snapshot? {
        guard let data = UserDefaults.sounding.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        save(snapshot, accountID: accountID)
        UserDefaults.sounding.removeObject(forKey: defaultsKey)
        return snapshot
    }
}

enum PlaybackPersistenceAccountPolicy {
    static let guestAccountID = "device-public-playback"

    static func accountID(
        authenticatedAccountID: String?,
        currentUserID: String?,
        rememberedAccountID: String?,
        isSignedOut: Bool
    ) -> String? {
        if isSignedOut { return guestAccountID }
        return authenticatedAccountID ?? currentUserID ?? rememberedAccountID
    }
}

enum PlaybackAccountReadiness: Equatable {
    case resolveNow
    case waitForAccount

    static let maximumWait: Duration = .seconds(10)

    static func decision(
        trackIsLocal: Bool,
        isSignedOut: Bool,
        isEstablishingSession: Bool,
        hasAccessToken: Bool
    ) -> PlaybackAccountReadiness {
        guard !trackIsLocal, !isSignedOut, !hasAccessToken else { return .resolveNow }
        return isEstablishingSession ? .waitForAccount : .resolveNow
    }
}

enum PlaybackAccountTransition: Equatable {
    case keep
    case adopt(String)
    case restore(String)
    case replace(String)
}

enum PlaybackAccountTransitionPolicy {
    static func transition(
        from sessionAccountID: String?,
        to accountID: String?,
        hasLiveSession: Bool
    ) -> PlaybackAccountTransition {
        guard let accountID else { return .keep }
        guard sessionAccountID != accountID else { return .keep }
        let previousWasAccount = sessionAccountID.map { $0 != PlaybackPersistenceAccountPolicy.guestAccountID } ?? false
        guard hasLiveSession else { return .restore(accountID) }
        return previousWasAccount ? .replace(accountID) : .adopt(accountID)
    }
}

struct PlaybackRestoreLedger: Equatable {
    var snapshotIds: [String]
    var resolvedIds: Set<String>

    var keptIds: [String] { snapshotIds.filter(resolvedIds.contains) }

    var isComplete: Bool { snapshotIds.allSatisfy(resolvedIds.contains) }

    private var keptPositions: [Int] {
        snapshotIds.indices.filter { resolvedIds.contains(snapshotIds[$0]) }
    }

    func snapshotPosition(liveIds: [String], liveIndex: Int) -> Int? {
        let positions = keptPositions
        guard liveIds == positions.map({ snapshotIds[$0] }),
              positions.indices.contains(liveIndex) else { return nil }
        return positions[liveIndex]
    }

    func persistedOrder(liveIds: [String], liveIndex: Int) -> (ids: [String], index: Int)? {
        guard let position = snapshotPosition(liveIds: liveIds, liveIndex: liveIndex) else { return nil }
        return (snapshotIds, position)
    }

    func enriched(with newlyResolved: Set<String>, liveIds: [String], liveIndex: Int) -> (ledger: PlaybackRestoreLedger, index: Int)? {
        guard let position = snapshotPosition(liveIds: liveIds, liveIndex: liveIndex) else { return nil }
        let next = PlaybackRestoreLedger(snapshotIds: snapshotIds, resolvedIds: resolvedIds.union(newlyResolved))
        let index = snapshotIds[..<position].filter(next.resolvedIds.contains).count
        return (next, index)
    }
}
