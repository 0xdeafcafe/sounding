import Foundation
import CryptoKit

struct SyncedSoundCloudSession: Codable, Sendable, Equatable {
    let oauthToken: String
    let refreshToken: String?
    let clientId: String?
    let expiresAtMillis: Int64?

    let updatedAtMillis: Int64
    let writerId: String
    var issuedAtMillis: Int64? = nil
    var generation: Int64? = nil
    var accountTag: String? = nil
    var accountName: String? = nil
    var writerName: String? = nil
    var writerKind: String? = nil

    var lineage: String? { SessionSyncBookkeeping.lineageDigest(refreshToken: refreshToken) }

    func carriesSameCredentials(as other: SyncedSoundCloudSession) -> Bool {
        oauthToken == other.oauthToken
            && refreshToken == other.refreshToken
            && clientId == other.clientId
    }

    static func == (lhs: SyncedSoundCloudSession, rhs: SyncedSoundCloudSession) -> Bool {
        lhs.oauthToken == rhs.oauthToken
            && lhs.refreshToken == rhs.refreshToken
            && lhs.clientId == rhs.clientId
            && lhs.expiresAtMillis == rhs.expiresAtMillis
            && lhs.updatedAtMillis == rhs.updatedAtMillis
            && lhs.writerId == rhs.writerId
            && lhs.issuedAtMillis == rhs.issuedAtMillis
            && lhs.generation == rhs.generation
    }

    func describingAccount(tag: String?, name: String?, writerName: String?, writerKind: String?) -> SyncedSoundCloudSession {
        var copy = self
        copy.accountTag = tag
        copy.accountName = name
        copy.writerName = writerName
        copy.writerKind = writerKind
        return copy
    }

    var storedSession: StoredSession {
        StoredSession(
            oauthToken: oauthToken,
            refreshToken: refreshToken,
            clientId: clientId,
            expiresAt: expiresAtMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            issuedAt: Date(timeIntervalSince1970: Double(issuedAtMillis ?? updatedAtMillis) / 1000),
            generation: generation.map { Int($0) }
        )
    }
}

enum SessionSyncBookkeeping {
    private static let writerIdKey = "red.forbes.sounding.sessionsync.writerId"
    private static let updatedAtMillisKey = "red.forbes.sounding.sessionsync.updatedAtMillis"

    private static let localSignOutMillisKey = "red.forbes.sounding.sessionsync.localSignOutMillis"

    static func writerId(defaults: UserDefaults = .sounding) -> String {
        if let existing = defaults.string(forKey: writerIdKey), !existing.isEmpty { return existing }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: writerIdKey)
        return generated
    }

    static func lastUpdatedAtMillis(defaults: UserDefaults = .sounding) -> Int64 {
        (defaults.object(forKey: updatedAtMillisKey) as? NSNumber)?.int64Value ?? 0
    }

    static func adoptForeignProvenance(
        updatedAtMillis: Int64,
        digest: String? = nil,
        defaults: UserDefaults = .sounding,
        store: ObservedDigestStore = .defaults
    ) {
        defaults.set(NSNumber(value: updatedAtMillis), forKey: updatedAtMillisKey)
        if let digest { store.write(digest) }
    }

    @discardableResult
    static func recordIfChanged(
        digest: String,
        defaults: UserDefaults = .sounding,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        store: ObservedDigestStore = .defaults
    ) -> Int64 {
        if store.read() == digest {
            return lastUpdatedAtMillis(defaults: defaults)
        }
        store.write(digest)
        defaults.set(NSNumber(value: now), forKey: updatedAtMillisKey)
        return now
    }

    static func digest(oauthToken: String, refreshToken: String?, clientId: String?, expiresAtMillis: Int64?) -> String {
        let combined = "\(oauthToken)|\(refreshToken ?? "")|\(clientId ?? "")|\(expiresAtMillis.map(String.init) ?? "")"
        return Data(SHA256.hash(data: Data(combined.utf8))).base64EncodedString()
    }

    static func lineageDigest(refreshToken: String?) -> String? {
        guard let refreshToken, !refreshToken.isEmpty else { return nil }
        return Data(SHA256.hash(data: Data("lineage|\(refreshToken)".utf8))).base64EncodedString()
    }

    static func localSignOutMillis(defaults: UserDefaults = .sounding) -> Int64? {
        (defaults.object(forKey: localSignOutMillisKey) as? NSNumber)?.int64Value
    }

    static func recordLocalSignOut(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000), defaults: UserDefaults = .sounding) {
        defaults.set(NSNumber(value: now), forKey: localSignOutMillisKey)
    }

    static func clearLocalSignOut(defaults: UserDefaults = .sounding) {
        defaults.removeObject(forKey: localSignOutMillisKey)
    }

    static func clearObservedDigest(store: ObservedDigestStore = .defaults) {
        store.delete()
    }
}

struct ObservedDigestStore: Sendable {
    var read: @Sendable () -> String?
    var write: @Sendable (String) -> Void
    var delete: @Sendable () -> Void

    static let defaults = ObservedDigestStore(
        read: { UserDefaults.sounding.string(forKey: observedDigestDefaultsKey) },
        write: { UserDefaults.sounding.set($0, forKey: observedDigestDefaultsKey) },
        delete: { UserDefaults.sounding.removeObject(forKey: observedDigestDefaultsKey) }
    )

    static func memory() -> ObservedDigestStore {
        final class Box: @unchecked Sendable {
            var value: String?
        }
        let box = Box()
        return ObservedDigestStore(
            read: { box.value },
            write: { box.value = $0 },
            delete: { box.value = nil }
        )
    }
}

private let observedDigestDefaultsKey = "red.forbes.sounding.sessionsync.observedDigest"

@MainActor
protocol SoundCloudSessionSyncSource: AnyObject, Sendable {
    func currentSessionForSync() -> SyncedSoundCloudSession?

    func adoptSyncedSession(_ session: SyncedSoundCloudSession) async
}

enum SessionSyncPolicy {
    static func sameSessionNeedsNoPush(local: SyncedSoundCloudSession, remote: SyncedSoundCloudSession) -> Bool {
        guard local.carriesSameCredentials(as: remote) else { return false }
        return remote.accountTag != nil || local.accountTag == nil
    }

    static func remoteWins(
        local: SyncedSoundCloudSession?,
        remote: SyncedSoundCloudSession,
        localSignOutMillis: Int64? = nil,
        rejectedLineages: RejectedLineageLedger = .defaults
    ) -> Bool {
        if let lineage = remote.lineage, rejectedLineages.contains(lineage) { return false }
        guard let local else { return localSignOutMillis == nil }
        if local == remote || local.carriesSameCredentials(as: remote) { return false }
        if let mine = local.accountTag, let theirs = remote.accountTag, mine != theirs { return false }
        if let lineage = local.lineage, rejectedLineages.contains(lineage) { return true }
        if remote.issuedAtMillis != nil || local.issuedAtMillis != nil {
            let remoteIssued = remote.issuedAtMillis ?? remote.updatedAtMillis
            let localIssued = local.issuedAtMillis ?? local.updatedAtMillis
            if remoteIssued != localIssued { return remoteIssued > localIssued }
            if (remote.generation ?? 0) != (local.generation ?? 0) { return (remote.generation ?? 0) > (local.generation ?? 0) }
        }
        if remote.updatedAtMillis != local.updatedAtMillis {
            return remote.updatedAtMillis > local.updatedAtMillis
        }
        return remote.writerId > local.writerId
    }
}

enum SessionProvenance: String, Codable, Sendable {
    case local
    case iCloud
    case linkedPeer
    case guest

    static let defaultsKey = "red.forbes.sounding.sessionsync.provenance.v1"

    static func record(_ provenance: SessionProvenance, defaults: UserDefaults = .sounding) {
        defaults.set(provenance.rawValue, forKey: defaultsKey)
    }

    static func current(defaults: UserDefaults = .sounding) -> SessionProvenance {
        defaults.string(forKey: defaultsKey).flatMap(SessionProvenance.init(rawValue:)) ?? .local
    }

    static func mayPush(
        _ provenance: SessionProvenance,
        isTV: Bool,
        local: SyncedSoundCloudSession,
        remote: SyncedSoundCloudSession?
    ) -> Bool {
        guard isTV, provenance == .guest else { return true }
        guard let tag = local.accountTag, let remoteTag = remote?.accountTag else { return false }
        return tag == remoteTag
    }
}

struct SessionContinueOffer: Codable, Equatable, Sendable {
    static let defaultsKey = "red.forbes.sounding.sessionsync.continueOffer.v1"

    let accountTag: String
    let accountName: String
    let writerName: String?

    init?(_ session: SyncedSoundCloudSession) {
        guard let tag = session.accountTag, !tag.isEmpty else { return nil }
        accountTag = tag
        accountName = session.accountName ?? ""
        writerName = session.writerName
    }

    var account: PeerAccount { PeerAccount(tag: accountTag, name: accountName, username: "") }

    static func load(defaults: UserDefaults = .sounding) -> SessionContinueOffer? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(SessionContinueOffer.self, from: data)
    }

    static func save(_ offer: SessionContinueOffer?, defaults: UserDefaults = .sounding) {
        guard let offer, let data = try? JSONEncoder().encode(offer) else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }
}

protocol SessionSyncTransport: Sendable {
    var transportId: String { get }
    func isReady() async -> Bool
    func push(_ session: SyncedSoundCloudSession) async throws
    func pull() async throws -> SyncedSoundCloudSession?
}

struct SessionSyncRelay: Sendable {
    let source: any SoundCloudSessionSyncSource
    let transport: any SessionSyncTransport

    var localSignOutMillis: @Sendable () -> Int64? = { SessionSyncBookkeeping.localSignOutMillis() }
    var provenance: @Sendable () -> SessionProvenance = { SessionProvenance.current() }

    struct RoundResult: Sendable, Equatable {
        var pulledRemote = false
        var adoptedRemote = false
        var pushedLocal = false
        var skippedNotReady = false
        var declinedBySignOut = false
    }

    func runOnce() async throws -> RoundResult {
        var result = RoundResult()
        guard await transport.isReady() else {
            result.skippedNotReady = true
            return result
        }

        let local = await source.currentSessionForSync()
        let signOutMillis = localSignOutMillis()

        let lastRemote = try await transport.pull()
        if let remote = lastRemote {
            result.pulledRemote = true
            if let local, local == remote || SessionSyncPolicy.sameSessionNeedsNoPush(local: local, remote: remote) {
                Log.sync.debug("\(transport.transportId, privacy: .public): local and remote sessions already match")
                return result
            }
            if SessionSyncPolicy.remoteWins(local: local, remote: remote, localSignOutMillis: signOutMillis) {
                await source.adoptSyncedSession(remote)
                result.adoptedRemote = true
                Log.sync.info("\(transport.transportId, privacy: .public): adopted a session from a peer")
                return result
            }
            if local == nil, signOutMillis != nil {
                SessionContinueOffer.save(SessionContinueOffer(remote))
                result.declinedBySignOut = true
                Log.sync.info("\(transport.transportId, privacy: .public): declined a peer session — this device was explicitly signed out by the user")
            }
        }

        if let local {
            guard SessionProvenance.mayPush(provenance(), isTV: DeviceClass.current == .tv, local: local, remote: lastRemote) else {
                Log.sync.info("\(transport.transportId, privacy: .public): kept a guest sign-in off iCloud")
                return result
            }
            try await transport.push(local)
            result.pushedLocal = true
        }
        return result
    }
}
