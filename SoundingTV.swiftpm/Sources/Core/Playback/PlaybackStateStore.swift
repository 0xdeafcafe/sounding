import Foundation

enum PlaybackStateStore {
    private static let defaultsKey = "red.forbes.sounding.playbackState.v1"
    private static let encryptedKeyPrefix = "red.forbes.sounding.playbackState.encrypted.v1."
    private static let purpose = "playback-state-v1"

    struct Snapshot: Codable, Equatable {
        var trackIds: [String]
        var currentIndex: Int
        var positionSeconds: TimeInterval
        var isShuffleEnabled: Bool
        var repeatMode: RepeatMode
        var collectionId: String? = nil
        var djProfileId: DJProfileID? = nil
        var collectionAutoMixWasActive: Bool? = nil
        var savedAt: Date
    }

    static func save(_ snapshot: Snapshot, accountID: String) {
        guard let data = try? JSONEncoder().encode(snapshot),
              let sealed = AccountDataVault.seal(data, accountID: accountID, purpose: purpose) else { return }
        UserDefaults.standard.set(sealed, forKey: encryptedKey(accountID))
    }

    static func load(accountID: String) -> Snapshot? {
        let key = encryptedKey(accountID)
        if let sealed = UserDefaults.standard.data(forKey: key),
           let data = AccountDataVault.open(sealed, accountID: accountID, purpose: purpose) {
            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }
        return migrateLegacyState(accountID: accountID)
    }

    static func clear(accountID: String) {
        UserDefaults.standard.removeObject(forKey: encryptedKey(accountID))
    }

    private static func encryptedKey(_ accountID: String) -> String {
        encryptedKeyPrefix + AccountDataVault.storageSuffix(for: accountID)
    }

    // LEGACY MIGRATION: remove after the account-vault rollout window.
    private static func migrateLegacyState(accountID: String) -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        save(snapshot, accountID: accountID)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return snapshot
    }
}
