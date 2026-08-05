import Foundation
import Combine
import CryptoKit
import Security
import SwiftUI

/// Encrypts account-owned metadata with a per-account key. Callers must still
/// require a freshly verified account before asking the vault to open data.
enum AccountDataVault {
    private static let service = "red.forbes.sounding.account-data-vault"

    static func seal(_ plaintext: Data, accountID: String, purpose: String) -> Data? {
        guard let key = key(for: accountID) else { return nil }
        return try? AES.GCM.seal(
            plaintext, using: key, authenticating: Data(purpose.utf8)
        ).combined
    }

    static func open(_ ciphertext: Data, accountID: String, purpose: String) -> Data? {
        guard let key = key(for: accountID, createIfMissing: false),
              let box = try? AES.GCM.SealedBox(combined: ciphertext) else { return nil }
        return try? AES.GCM.open(
            box, using: key, authenticating: Data(purpose.utf8)
        )
    }

    static func storageSuffix(for accountID: String) -> String {
        SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func key(for accountID: String, createIfMissing: Bool = true) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard createIfMissing else { return nil }
        var bytes = Data(count: 32)
        guard bytes.withUnsafeMutableBytes({ buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }) == errSecSuccess else { return nil }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            return key(for: accountID, createIfMissing: false)
        }
        return SymmetricKey(data: bytes)
    }
}

enum SettingScope: String, Codable, Equatable {
    case deviceLocal
    case synced
}

protocol SettingDefinition {
    associatedtype Value: Codable & Equatable

    static var id: String { get }
    static var defaultScope: SettingScope { get }
    static var defaultValue: Value { get }

    static var isScopeOverridable: Bool { get }
}

extension SettingDefinition {
    static var isScopeOverridable: Bool { false }
}

enum QualityCeiling: String, Codable, CaseIterable, Comparable, Identifiable {
    case efficient
    case standard
    case high
    case maximum

    var id: String { rawValue }

    private var order: Int {
        switch self {
        case .efficient: return 0
        case .standard:  return 1
        case .high:      return 2
        case .maximum:   return 3
        }
    }

    static func < (lhs: QualityCeiling, rhs: QualityCeiling) -> Bool {
        lhs.order < rhs.order
    }

    var displayName: String {
        switch self {
        case .efficient: return "Data Saver"
        case .standard:  return "Standard"
        case .high:      return "High"
        case .maximum:   return "Maximum"
        }
    }

    func bestTranscoding(among transcodings: [Transcoding]) -> Transcoding? {
        guard self != .maximum else {
            return transcodings.max { $0.playbackRank < $1.playbackRank }
        }
        let capped = transcodings.filter { $0.bitrate <= maxBitrateKbps }
        let pool = capped.isEmpty ? transcodings : capped
        return pool.max { $0.playbackRank < $1.playbackRank }
    }

    func capping(_ transcodings: [Transcoding]) -> [Transcoding] {
        guard self != .maximum else { return transcodings }
        let capped = transcodings.filter { $0.bitrate <= maxBitrateKbps }
        return capped.isEmpty ? transcodings : capped
    }

    private var maxBitrateKbps: Int {
        switch self {
        case .efficient: return 96
        case .standard:  return 160
        case .high:      return 320
        case .maximum:   return .max
        }
    }
}

/// The shared answer to *which* saved music is worth analysing.  This never
/// authorises a download: devices only act when they already have local audio.
struct AutomaticAnalysisRules: Codable, Equatable, Sendable {
    var likedTracks: Bool
    var yourPlaylists: Bool

    static let standard = AutomaticAnalysisRules(likedTracks: true, yourPlaylists: true)

    var isEnabled: Bool { likedTracks || yourPlaylists }

    var summary: String {
        switch (likedTracks, yourPlaylists) {
        case (true, true): return "Liked tracks and your playlists"
        case (true, false): return "Liked tracks"
        case (false, true): return "Your playlists"
        case (false, false): return "Off"
        }
    }
}

/// A deliberately local answer to *when* this device may spend CPU and disk
/// on the shared automatic-analysis policy.
enum AutomaticAnalysisExecutionPolicyValue: String, Codable, CaseIterable, Identifiable, Sendable {
    case conservative
    case balanced
    case eager

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conservative: return "Only when charging"
        case .balanced: return "Balanced"
        case .eager: return "Whenever ready"
        }
    }

    var explanation: String {
        switch self {
        case .conservative: return "Waits for external power and ample free storage."
        case .balanced: return "Avoids Low Power Mode and keeps a healthy storage reserve."
        case .eager: return "Runs whenever this device can analyse a local file."
        }
    }
}

/// Preserves the public type name while avoiding a shadowing collision with
/// `SettingKeys.AutomaticAnalysisExecutionPolicy`.
typealias AutomaticAnalysisExecutionPolicy = AutomaticAnalysisExecutionPolicyValue

// MARK: - Synced collection policy model

// These value types live beside SettingsStore because every companion target
// decodes synced settings, even when it does not include the full download and
// collection-policy editor implementation.
enum CollectionIntelligenceLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case useful
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:    return "Off"
        case .useful: return "Useful"
        case .full:   return "Full DJ Analysis"
        }
    }

    var explanation: String {
        switch self {
        case .off:    return "Does not proactively analyse this collection."
        case .useful: return "Learns genre and waveform shape in the background without downloading audio."
        case .full:   return "Also learns tempo, key, phrases and structure whenever a local file is available."
        }
    }
}

enum DJCollectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case autoDJ
    case djOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal Playlist"
        case .autoDJ: return "Prefer Auto DJ"
        case .djOnly: return "DJ Only"
        }
    }

    var explanation: String {
        switch self {
        case .normal: return "Plays normally unless Auto DJ is already on."
        case .autoDJ: return "Turns on Auto DJ when playback starts, but manual playback remains available."
        case .djOnly: return "Always starts as an Auto DJ session and keeps its DJ rules attached to the queue."
        }
    }
}

enum DJSetHandling: String, Codable, CaseIterable, Identifiable, Sendable {
    case include
    case skip
    case onlySets

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .include:  return "Include Sets"
        case .skip:     return "Skip Sets"
        case .onlySets: return "Sets Only"
        }
    }
}

enum DJQueueOrderPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case profileDefault
    case preserve
    case mayReorder
    case random

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .profileDefault: return "Use Profile Default"
        case .preserve:       return "Preserve Playlist Order"
        case .mayReorder:     return "Choose the Best Next Track"
        case .random:         return "Random Order"
        }
    }
}

/// The choices made when starting a new Auto DJ session. Collection policies
/// remain the per-playlist contract; this is the person's shared starting
/// preference for an ad-hoc session.
enum DJSourceStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case currentSources
    case goodMatches

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .currentSources: return "Current Playlist or Library"
        case .goodMatches:    return "Find Good Matches"
        }
    }

    var explanation: String {
        switch self {
        case .currentSources:
            return "Keep choosing from the queue and saved music you started with."
        case .goodMatches:
            return "Add related SoundCloud tracks around what is playing, then choose the strongest fit."
        }
    }
}

struct DJStartConfiguration: Codable, Equatable, Sendable {
    var setHandling: DJSetHandling
    var sourceStrategy: DJSourceStrategy
    var queueOrder: DJQueueOrderPolicy

    static let standard = DJStartConfiguration(
        setHandling: .skip,
        sourceStrategy: .currentSources,
        queueOrder: .mayReorder
    )
}

struct CollectionPolicy: Codable, Equatable, Sendable {
    var qualityCeiling: QualityCeiling?
    var automaticDownloads: Bool
    var intelligence: CollectionIntelligenceLevel
    var djMode: DJCollectionMode
    var isDefaultDJSource: Bool
    var djProfileId: DJProfileID
    var queueOrder: DJQueueOrderPolicy
    var setHandling: DJSetHandling
    var avoidVocalOverlap: Bool
    var maximumTransitionBars: Int

    static let standard = CollectionPolicy(
        qualityCeiling: nil,
        automaticDownloads: false,
        intelligence: .useful,
        djMode: .normal,
        isDefaultDJSource: false,
        djProfileId: .automatic,
        queueOrder: .profileDefault,
        setHandling: .include,
        avoidVocalOverlap: true,
        maximumTransitionBars: 16
    )

    var resolvedIntelligence: CollectionIntelligenceLevel {
        djMode == .normal ? intelligence : .full
    }

    private enum CodingKeys: String, CodingKey {
        case qualityCeiling, automaticDownloads, intelligence
        case djMode, isDefaultDJSource, djProfileId, queueOrder, setHandling
        case avoidVocalOverlap, maximumTransitionBars
    }

    init(
        qualityCeiling: QualityCeiling?,
        automaticDownloads: Bool,
        intelligence: CollectionIntelligenceLevel,
        djMode: DJCollectionMode,
        isDefaultDJSource: Bool,
        djProfileId: DJProfileID,
        queueOrder: DJQueueOrderPolicy,
        setHandling: DJSetHandling,
        avoidVocalOverlap: Bool,
        maximumTransitionBars: Int
    ) {
        self.qualityCeiling = qualityCeiling
        self.automaticDownloads = automaticDownloads
        self.intelligence = intelligence
        self.djMode = djMode
        self.isDefaultDJSource = isDefaultDJSource
        self.djProfileId = djProfileId
        self.queueOrder = queueOrder
        self.setHandling = setHandling
        self.avoidVocalOverlap = avoidVocalOverlap
        self.maximumTransitionBars = maximumTransitionBars
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.standard
        let container = try decoder.container(keyedBy: CodingKeys.self)
        qualityCeiling = try container.decodeIfPresent(QualityCeiling.self, forKey: .qualityCeiling)
        automaticDownloads = try container.decodeIfPresent(Bool.self, forKey: .automaticDownloads) ?? defaults.automaticDownloads
        intelligence = try container.decodeIfPresent(CollectionIntelligenceLevel.self, forKey: .intelligence) ?? defaults.intelligence
        djMode = try container.decodeIfPresent(DJCollectionMode.self, forKey: .djMode) ?? defaults.djMode
        isDefaultDJSource = try container.decodeIfPresent(Bool.self, forKey: .isDefaultDJSource) ?? defaults.isDefaultDJSource
        djProfileId = try container.decodeIfPresent(DJProfileID.self, forKey: .djProfileId) ?? defaults.djProfileId
        queueOrder = try container.decodeIfPresent(DJQueueOrderPolicy.self, forKey: .queueOrder) ?? defaults.queueOrder
        setHandling = try container.decodeIfPresent(DJSetHandling.self, forKey: .setHandling) ?? defaults.setHandling
        avoidVocalOverlap = try container.decodeIfPresent(Bool.self, forKey: .avoidVocalOverlap) ?? defaults.avoidVocalOverlap
        maximumTransitionBars = try container.decodeIfPresent(Int.self, forKey: .maximumTransitionBars) ?? defaults.maximumTransitionBars
    }
}

enum SettingKeys {
    enum StreamingQualityCeiling: SettingDefinition {
        static let id = "streamingQualityCeiling"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: QualityCeiling = .high
        static let isScopeOverridable = true
    }

    enum DownloadQualityCeiling: SettingDefinition {
        static let id = "downloadQualityCeiling"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: QualityCeiling = .high
        static let isScopeOverridable = true
    }

    enum CellularStreamingAllowed: SettingDefinition {
        static let id = "cellularStreamingAllowed"
        static let defaultScope: SettingScope = .deviceLocal
        static let defaultValue: Bool = true
    }

    enum CellularDownloadsAllowed: SettingDefinition {
        static let id = "cellularDownloadsAllowed"
        static let defaultScope: SettingScope = .deviceLocal
        static let defaultValue: Bool = false
    }

    enum DownloadStorageCapBytes: SettingDefinition {
        static let id = "downloadStorageCapBytes"
        static let defaultScope: SettingScope = .deviceLocal
        static var defaultValue: Int64 {
            #if os(tvOS)
            return 10_000_000_000 // 10 GB
            #else
            return 2_000_000_000 // 2 GB
            #endif
        }
    }

    enum DJAutoMixEnabled: SettingDefinition {
        static let id = "djAutoMixEnabled"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: Bool = true
        static let isScopeOverridable = true
    }

    enum DJDefaultProfileId: SettingDefinition {
        static let id = "djDefaultProfileId"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: DJProfileID = .automatic
        static let isScopeOverridable = true
    }

    enum DJTransitionLengthSeconds: SettingDefinition {
        static let id = "djTransitionLengthSeconds"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: Double = 8.0
        static let isScopeOverridable = true
    }

    enum DJStartOptions: SettingDefinition {
        static let id = "djStartConfiguration"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: DJStartConfiguration = .standard
        static let isScopeOverridable = true
    }

    /// The duration at which a saved track is presented as a long-form set.
    /// This is metadata-only: changing it never requests or downloads audio.
    enum SetMinimumDurationSeconds: SettingDefinition {
        static let id = "setMinimumDurationSeconds"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: Double = 45 * 60
        static let isScopeOverridable = true
    }

    enum AmbientScreensaverTimeoutSeconds: SettingDefinition {
        static let id = "ambientScreensaverTimeoutSeconds"
        static let defaultScope: SettingScope = .deviceLocal
        static let defaultValue: Double = 90
    }

    enum RecentSearchQueries: SettingDefinition {
        static let id = "recentSearchQueries"
        static let defaultScope: SettingScope = .deviceLocal
        static let defaultValue: [RecentSearchEntry] = []
    }

    enum CollectionPolicies: SettingDefinition {
        static let id = "collectionPolicies"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: [String: CollectionPolicy] = [:]
        static let isScopeOverridable = true
    }

    enum AutomaticAnalysisPolicy: SettingDefinition {
        static let id = "automaticAnalysisPolicy"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: AutomaticAnalysisRules = .standard
    }

    enum AutomaticAnalysisExecutionPolicy: SettingDefinition {
        static let id = "automaticAnalysisExecutionPolicy"
        static let defaultScope: SettingScope = .deviceLocal
        static let defaultValue: AutomaticAnalysisExecutionPolicyValue = .balanced
    }
}

struct RecentSearchEntry: Codable, Equatable, Identifiable {
    var id: String { query }
    let query: String
    let avatarURL: URL?
    let subtitle: String
}

/// Generated library collections deliberately work from already-cached track
/// metadata. They must never cause a stream or download to be requested.
enum GeneratedLibraryCollections {
    static let setDurationPresets: [Double] = [30 * 60, 45 * 60, 60 * 60, 90 * 60, 120 * 60]

    static func sets(from tracks: [Track], minimumDuration: Double) -> [Track] {
        var seen = Set<String>()
        return tracks
            .filter { $0.duration >= minimumDuration && seen.insert($0.id).inserted }
            .sorted {
                if $0.duration == $1.duration { return $0.title < $1.title }
                return $0.duration > $1.duration
            }
    }

    static func durationLabel(_ duration: Double) -> String {
        let minutes = Int((duration / 60).rounded())
        if minutes >= 60, minutes.isMultiple(of: 60) {
            return "\(minutes / 60) hr"
        }
        return "\(minutes) min"
    }
}

struct SettingRevision: Codable, Equatable {
    var revision: UInt64
    var updatedAtMillis: Int64
    var writerId: String
}

struct SettingsSyncPayload: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let id: String
        let valueJSON: Data
        let revision: UInt64
        let updatedAtMillis: Int64
        let writerId: String
    }

    var entries: [Entry]
}

enum SettingsMerge {
    struct Outcome: Equatable {
        var appliedIds: [String] = []
        var keptIds: [String] = []
        var skippedDeviceLocalIds: [String] = []
        var unknownIds: [String] = []
    }

    static func remoteWins(local: SettingRevision?, remote: SettingRevision) -> Bool {
        guard let local else { return true }
        if remote.revision != local.revision {
            return remote.revision > local.revision
        }
        if remote.updatedAtMillis != local.updatedAtMillis {
            return remote.updatedAtMillis > local.updatedAtMillis
        }
        return remote.writerId > local.writerId
    }

    static func reconcile(
        payload: SettingsSyncPayload,
        knownIds: Set<String>,
        deviceLocalIds: Set<String>,
        localRevisions: (String) -> SettingRevision?
    ) -> (winners: [SettingsSyncPayload.Entry], outcome: Outcome) {
        var outcome = Outcome()
        var winners: [SettingsSyncPayload.Entry] = []

        for entry in payload.entries {
            guard !deviceLocalIds.contains(entry.id) else {
                outcome.skippedDeviceLocalIds.append(entry.id)
                continue
            }
            guard knownIds.contains(entry.id) else {
                outcome.unknownIds.append(entry.id)
                continue
            }
            let remote = SettingRevision(
                revision: entry.revision,
                updatedAtMillis: entry.updatedAtMillis,
                writerId: entry.writerId
            )
            if remoteWins(local: localRevisions(entry.id), remote: remote) {
                winners.append(entry)
                outcome.appliedIds.append(entry.id)
            } else {
                outcome.keptIds.append(entry.id)
            }
        }
        return (winners, outcome)
    }
}

@MainActor
enum SettingsSyncTarget {
    /// Installed by full CloudKit-capable apps; lightweight extensions and
    /// watch builds keep settings local until a companion syncs them.
    static var requestSync: (() -> Void)?
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    static let djTransitionLengthRange: ClosedRange<Double> = 2...30
    static let ambientScreensaverTimeoutRange: ClosedRange<Double> = 15...900
    static let setMinimumDurationRange: ClosedRange<Double> = 15 * 60...4 * 60 * 60

    @Published private(set) var streamingQualityCeiling: QualityCeiling
    @Published private(set) var downloadQualityCeiling: QualityCeiling
    @Published private(set) var cellularStreamingAllowed: Bool
    @Published private(set) var cellularDownloadsAllowed: Bool
    @Published private(set) var downloadStorageCapBytes: Int64
    @Published private(set) var djAutoMixEnabled: Bool
    @Published private(set) var djDefaultProfileId: DJProfileID
    @Published private(set) var djTransitionLengthSeconds: Double
    @Published private(set) var djStartConfiguration: DJStartConfiguration
    @Published private(set) var setMinimumDurationSeconds: Double
    @Published private(set) var ambientScreensaverTimeoutSeconds: Double
    @Published private(set) var recentSearchQueries: [RecentSearchEntry]
    @Published private(set) var collectionPolicies: [String: CollectionPolicy]
    @Published private(set) var automaticAnalysisPolicy: AutomaticAnalysisRules
    @Published private(set) var automaticAnalysisExecutionPolicy: AutomaticAnalysisExecutionPolicy

    @Published private(set) var deviceLocalOverrideIds: Set<String>

    private var activeAccountID: String?
    private let writerId: String

    var writerIdForSync: String { writerId }

    private init() {
        writerId = Self.loadOrCreateWriterId()
        streamingQualityCeiling = SettingKeys.StreamingQualityCeiling.defaultValue
        downloadQualityCeiling = SettingKeys.DownloadQualityCeiling.defaultValue
        cellularStreamingAllowed = SettingKeys.CellularStreamingAllowed.defaultValue
        cellularDownloadsAllowed = SettingKeys.CellularDownloadsAllowed.defaultValue
        downloadStorageCapBytes = SettingKeys.DownloadStorageCapBytes.defaultValue
        djAutoMixEnabled = SettingKeys.DJAutoMixEnabled.defaultValue
        djDefaultProfileId = SettingKeys.DJDefaultProfileId.defaultValue
        djTransitionLengthSeconds = SettingKeys.DJTransitionLengthSeconds.defaultValue
        djStartConfiguration = SettingKeys.DJStartOptions.defaultValue
        setMinimumDurationSeconds = SettingKeys.SetMinimumDurationSeconds.defaultValue
        ambientScreensaverTimeoutSeconds = SettingKeys.AmbientScreensaverTimeoutSeconds.defaultValue
        recentSearchQueries = []
        collectionPolicies = SettingKeys.CollectionPolicies.defaultValue
        automaticAnalysisPolicy = SettingKeys.AutomaticAnalysisPolicy.defaultValue
        automaticAnalysisExecutionPolicy = SettingKeys.AutomaticAnalysisExecutionPolicy.defaultValue
        deviceLocalOverrideIds = []
    }

    func unlockAccount(_ accountID: String) {
        guard activeAccountID != accountID else { return }
        activeAccountID = accountID
        streamingQualityCeiling = Self.loadValue(SettingKeys.StreamingQualityCeiling.self, accountID: accountID)
        downloadQualityCeiling = Self.loadValue(SettingKeys.DownloadQualityCeiling.self, accountID: accountID)
        cellularStreamingAllowed = Self.loadValue(SettingKeys.CellularStreamingAllowed.self, accountID: accountID)
        cellularDownloadsAllowed = Self.loadValue(SettingKeys.CellularDownloadsAllowed.self, accountID: accountID)
        downloadStorageCapBytes = Self.loadValue(SettingKeys.DownloadStorageCapBytes.self, accountID: accountID)
        djAutoMixEnabled = Self.loadValue(SettingKeys.DJAutoMixEnabled.self, accountID: accountID)
        djDefaultProfileId = Self.loadValue(SettingKeys.DJDefaultProfileId.self, accountID: accountID)
        djTransitionLengthSeconds = Self.loadValue(SettingKeys.DJTransitionLengthSeconds.self, accountID: accountID)
        djStartConfiguration = Self.loadValue(SettingKeys.DJStartOptions.self, accountID: accountID)
        setMinimumDurationSeconds = Self.loadValue(SettingKeys.SetMinimumDurationSeconds.self, accountID: accountID)
        ambientScreensaverTimeoutSeconds = Self.loadValue(SettingKeys.AmbientScreensaverTimeoutSeconds.self, accountID: accountID)
        recentSearchQueries = Self.loadValue(SettingKeys.RecentSearchQueries.self, accountID: accountID)
        collectionPolicies = Self.loadValue(SettingKeys.CollectionPolicies.self, accountID: accountID)
        automaticAnalysisPolicy = Self.loadValue(SettingKeys.AutomaticAnalysisPolicy.self, accountID: accountID)
        automaticAnalysisExecutionPolicy = Self.loadValue(SettingKeys.AutomaticAnalysisExecutionPolicy.self, accountID: accountID)
        deviceLocalOverrideIds = Self.loadEncrypted(
            Set<String>.self, key: DefaultsKey.deviceLocalOverrides, accountID: accountID
        ) ?? []
    }

    func lockAccount() {
        guard activeAccountID != nil else { return }
        activeAccountID = nil
        streamingQualityCeiling = SettingKeys.StreamingQualityCeiling.defaultValue
        downloadQualityCeiling = SettingKeys.DownloadQualityCeiling.defaultValue
        cellularStreamingAllowed = SettingKeys.CellularStreamingAllowed.defaultValue
        cellularDownloadsAllowed = SettingKeys.CellularDownloadsAllowed.defaultValue
        downloadStorageCapBytes = SettingKeys.DownloadStorageCapBytes.defaultValue
        djAutoMixEnabled = SettingKeys.DJAutoMixEnabled.defaultValue
        djDefaultProfileId = SettingKeys.DJDefaultProfileId.defaultValue
        djTransitionLengthSeconds = SettingKeys.DJTransitionLengthSeconds.defaultValue
        djStartConfiguration = SettingKeys.DJStartOptions.defaultValue
        setMinimumDurationSeconds = SettingKeys.SetMinimumDurationSeconds.defaultValue
        ambientScreensaverTimeoutSeconds = SettingKeys.AmbientScreensaverTimeoutSeconds.defaultValue
        recentSearchQueries = []
        collectionPolicies = SettingKeys.CollectionPolicies.defaultValue
        automaticAnalysisPolicy = SettingKeys.AutomaticAnalysisPolicy.defaultValue
        automaticAnalysisExecutionPolicy = SettingKeys.AutomaticAnalysisExecutionPolicy.defaultValue
        deviceLocalOverrideIds = []
    }

    func setStreamingQualityCeiling(_ value: QualityCeiling) {
        guard value != streamingQualityCeiling else { return }
        streamingQualityCeiling = value
        writeLocal(SettingKeys.StreamingQualityCeiling.self, value)
    }

    func setDownloadQualityCeiling(_ value: QualityCeiling) {
        guard value != downloadQualityCeiling else { return }
        downloadQualityCeiling = value
        writeLocal(SettingKeys.DownloadQualityCeiling.self, value)
    }

    func setCellularStreamingAllowed(_ value: Bool) {
        guard value != cellularStreamingAllowed else { return }
        cellularStreamingAllowed = value
        writeLocal(SettingKeys.CellularStreamingAllowed.self, value)
    }

    func setCellularDownloadsAllowed(_ value: Bool) {
        guard value != cellularDownloadsAllowed else { return }
        cellularDownloadsAllowed = value
        writeLocal(SettingKeys.CellularDownloadsAllowed.self, value)
    }

    func setDownloadStorageCapBytes(_ value: Int64) {
        let clamped = max(0, value)
        guard clamped != downloadStorageCapBytes else { return }
        downloadStorageCapBytes = clamped
        writeLocal(SettingKeys.DownloadStorageCapBytes.self, clamped)
    }

    func setDJAutoMixEnabled(_ value: Bool) {
        guard value != djAutoMixEnabled else { return }
        djAutoMixEnabled = value
        writeLocal(SettingKeys.DJAutoMixEnabled.self, value)
    }

    func setDJDefaultProfileId(_ value: DJProfileID) {
        guard value != djDefaultProfileId else { return }
        djDefaultProfileId = value
        writeLocal(SettingKeys.DJDefaultProfileId.self, value)
    }

    func setDJTransitionLengthSeconds(_ value: Double) {
        let clamped = value.clamped(to: Self.djTransitionLengthRange)
        guard clamped != djTransitionLengthSeconds else { return }
        djTransitionLengthSeconds = clamped
        writeLocal(SettingKeys.DJTransitionLengthSeconds.self, clamped)
    }

    func setDJStartConfiguration(_ value: DJStartConfiguration) {
        guard value != djStartConfiguration else { return }
        djStartConfiguration = value
        writeLocal(SettingKeys.DJStartOptions.self, value)
    }

    func setSetMinimumDurationSeconds(_ value: Double) {
        let clamped = value.clamped(to: Self.setMinimumDurationRange)
        guard clamped != setMinimumDurationSeconds else { return }
        setMinimumDurationSeconds = clamped
        writeLocal(SettingKeys.SetMinimumDurationSeconds.self, clamped)
    }

    func setAmbientScreensaverTimeoutSeconds(_ value: Double) {
        let clamped = value.clamped(to: Self.ambientScreensaverTimeoutRange)
        guard clamped != ambientScreensaverTimeoutSeconds else { return }
        ambientScreensaverTimeoutSeconds = clamped
        writeLocal(SettingKeys.AmbientScreensaverTimeoutSeconds.self, clamped)
    }

    func setRecentSearchQueries(_ value: [RecentSearchEntry]) {
        guard value != recentSearchQueries else { return }
        recentSearchQueries = value
        writeLocal(SettingKeys.RecentSearchQueries.self, value)
    }

    func setCollectionPolicies(_ value: [String: CollectionPolicy]) {
        guard value != collectionPolicies else { return }
        collectionPolicies = value
        writeLocal(SettingKeys.CollectionPolicies.self, value)
    }

    func setAutomaticAnalysisPolicy(_ value: AutomaticAnalysisRules) {
        guard value != automaticAnalysisPolicy else { return }
        automaticAnalysisPolicy = value
        writeLocal(SettingKeys.AutomaticAnalysisPolicy.self, value)
    }

    func setAutomaticAnalysisExecutionPolicy(_ value: AutomaticAnalysisExecutionPolicy) {
        guard value != automaticAnalysisExecutionPolicy else { return }
        automaticAnalysisExecutionPolicy = value
        writeLocal(SettingKeys.AutomaticAnalysisExecutionPolicy.self, value)
    }

    func hasStoredValue<K: SettingDefinition>(_ key: K.Type) -> Bool {
        guard let accountID = activeAccountID else { return false }
        return UserDefaults.standard.data(
            forKey: DefaultsKey.encrypted(DefaultsKey.value(for: key.id), accountID: accountID)
        ) != nil
    }

    private func writeLocal<K: SettingDefinition>(_ key: K.Type, _ value: K.Value) {
        guard let accountID = activeAccountID else { return }
        Self.persistValue(key, value, accountID: accountID)
        guard key.defaultScope == .synced else { return }
        var all = revisions
        let current = all[key.id]
        all[key.id] = SettingRevision(
            revision: (current?.revision ?? 0) + 1,
            updatedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            writerId: writerId
        )
        revisions = all
        SettingsSyncTarget.requestSync?()
    }

    func isForcedDeviceLocal<K: SettingDefinition>(_ key: K.Type) -> Bool {
        deviceLocalOverrideIds.contains(key.id)
    }

    func effectiveScope<K: SettingDefinition>(_ key: K.Type) -> SettingScope {
        (key.defaultScope == .synced && isForcedDeviceLocal(key)) ? .deviceLocal : key.defaultScope
    }

    func setForceDeviceLocal<K: SettingDefinition>(_ key: K.Type, _ forced: Bool) {
        guard key.isScopeOverridable else { return }
        guard forced != deviceLocalOverrideIds.contains(key.id) else { return }
        var ids = deviceLocalOverrideIds
        if forced {
            ids.insert(key.id)
        } else {
            ids.remove(key.id)
        }
        deviceLocalOverrideIds = ids
        guard let accountID = activeAccountID else { return }
        Self.persistEncrypted(ids, key: DefaultsKey.deviceLocalOverrides, accountID: accountID)
        SettingsSyncTarget.requestSync?()
    }

    var streamingQualityCeilingBinding: Binding<QualityCeiling> {
        Binding(get: { self.streamingQualityCeiling }, set: { self.setStreamingQualityCeiling($0) })
    }

    var downloadQualityCeilingBinding: Binding<QualityCeiling> {
        Binding(get: { self.downloadQualityCeiling }, set: { self.setDownloadQualityCeiling($0) })
    }

    var cellularStreamingAllowedBinding: Binding<Bool> {
        Binding(get: { self.cellularStreamingAllowed }, set: { self.setCellularStreamingAllowed($0) })
    }

    var cellularDownloadsAllowedBinding: Binding<Bool> {
        Binding(get: { self.cellularDownloadsAllowed }, set: { self.setCellularDownloadsAllowed($0) })
    }

    var downloadStorageCapBytesBinding: Binding<Int64> {
        Binding(get: { self.downloadStorageCapBytes }, set: { self.setDownloadStorageCapBytes($0) })
    }

    var djAutoMixEnabledBinding: Binding<Bool> {
        Binding(get: { self.djAutoMixEnabled }, set: { self.setDJAutoMixEnabled($0) })
    }

    var djDefaultProfileIdBinding: Binding<DJProfileID> {
        Binding(get: { self.djDefaultProfileId }, set: { self.setDJDefaultProfileId($0) })
    }

    var djTransitionLengthSecondsBinding: Binding<Double> {
        Binding(get: { self.djTransitionLengthSeconds }, set: { self.setDJTransitionLengthSeconds($0) })
    }

    var djStartConfigurationBinding: Binding<DJStartConfiguration> {
        Binding(get: { self.djStartConfiguration }, set: { self.setDJStartConfiguration($0) })
    }

    var setMinimumDurationSecondsBinding: Binding<Double> {
        Binding(get: { self.setMinimumDurationSeconds }, set: { self.setSetMinimumDurationSeconds($0) })
    }

    var ambientScreensaverTimeoutSecondsBinding: Binding<Double> {
        Binding(get: { self.ambientScreensaverTimeoutSeconds }, set: { self.setAmbientScreensaverTimeoutSeconds($0) })
    }

    var automaticAnalysisPolicyBinding: Binding<AutomaticAnalysisRules> {
        Binding(get: { self.automaticAnalysisPolicy }, set: { self.setAutomaticAnalysisPolicy($0) })
    }

    var automaticAnalysisExecutionPolicyBinding: Binding<AutomaticAnalysisExecutionPolicy> {
        Binding(get: { self.automaticAnalysisExecutionPolicy }, set: { self.setAutomaticAnalysisExecutionPolicy($0) })
    }

    func exportSyncPayload() -> Data? {
        let entries: [SettingsSyncPayload.Entry] = syncRegistry.compactMap { entry in
            guard !isForcedDeviceLocalById(entry.id) else { return nil }
            guard let revision = entry.getRevision(), let value = entry.encodeCurrentValue() else { return nil }
            return SettingsSyncPayload.Entry(
                id: entry.id,
                valueJSON: value,
                revision: revision.revision,
                updatedAtMillis: revision.updatedAtMillis,
                writerId: revision.writerId
            )
        }
        guard !entries.isEmpty else { return nil }
        return try? JSONEncoder().encode(SettingsSyncPayload(entries: entries))
    }

    struct MergeResult {
        var applied: [String] = []
        var kept: [String] = []
        var skippedDeviceLocal: [String] = []
        var unknownIds: [String] = []
        var malformed: [String] = []
        var decodeFailed = false
    }

    @discardableResult
    func merge(_ data: Data) -> MergeResult {
        var result = MergeResult()
        guard let payload = try? JSONDecoder().decode(SettingsSyncPayload.self, from: data) else {
            result.decodeFailed = true
            return result
        }

        let knownIds = Set(syncRegistry.map(\.id))
        let (winners, outcome) = SettingsMerge.reconcile(
            payload: payload,
            knownIds: knownIds,
            deviceLocalIds: deviceLocalOverrideIds,
            localRevisions: { [weak self] id in self?.revisions[id] }
        )
        result.kept = outcome.keptIds
        result.skippedDeviceLocal = outcome.skippedDeviceLocalIds
        result.unknownIds = outcome.unknownIds

        for winner in winners {
            guard let entry = syncRegistry.first(where: { $0.id == winner.id }) else { continue }
            let record = SettingRevision(
                revision: winner.revision,
                updatedAtMillis: winner.updatedAtMillis,
                writerId: winner.writerId
            )
            if entry.applyRemote(winner.valueJSON, record) {
                result.applied.append(winner.id)
            } else {
                result.malformed.append(winner.id)
            }
        }
        return result
    }

    private func isForcedDeviceLocalById(_ id: String) -> Bool {
        deviceLocalOverrideIds.contains(id)
    }

    private struct SyncableSetting {
        let id: String
        let getRevision: () -> SettingRevision?
        let encodeCurrentValue: () -> Data?
        let applyRemote: (Data, SettingRevision) -> Bool
    }

    private lazy var syncRegistry: [SyncableSetting] = [
        syncableEntry(
            SettingKeys.StreamingQualityCeiling.self,
            get: { self.streamingQualityCeiling },
            set: { self.streamingQualityCeiling = $0 }
        ),
        syncableEntry(
            SettingKeys.DownloadQualityCeiling.self,
            get: { self.downloadQualityCeiling },
            set: { self.downloadQualityCeiling = $0 }
        ),
        syncableEntry(
            SettingKeys.DJAutoMixEnabled.self,
            get: { self.djAutoMixEnabled },
            set: { self.djAutoMixEnabled = $0 }
        ),
        syncableEntry(
            SettingKeys.DJDefaultProfileId.self,
            get: { self.djDefaultProfileId },
            set: { self.djDefaultProfileId = $0 }
        ),
        syncableEntry(
            SettingKeys.DJTransitionLengthSeconds.self,
            get: { self.djTransitionLengthSeconds },
            set: { self.djTransitionLengthSeconds = $0 }
        ),
        syncableEntry(
            SettingKeys.DJStartOptions.self,
            get: { self.djStartConfiguration },
            set: { self.djStartConfiguration = $0 }
        ),
        syncableEntry(
            SettingKeys.SetMinimumDurationSeconds.self,
            get: { self.setMinimumDurationSeconds },
            set: { self.setMinimumDurationSeconds = $0 }
        ),
        syncableEntry(
            SettingKeys.CollectionPolicies.self,
            get: { self.collectionPolicies },
            set: { self.collectionPolicies = $0 }
        ),
        syncableEntry(
            SettingKeys.AutomaticAnalysisPolicy.self,
            get: { self.automaticAnalysisPolicy },
            set: { self.automaticAnalysisPolicy = $0 }
        ),
    ]

    private func syncableEntry<K: SettingDefinition>(
        _ key: K.Type,
        get: @escaping () -> K.Value,
        set: @escaping (K.Value) -> Void
    ) -> SyncableSetting {
        SyncableSetting(
            id: key.id,
            getRevision: { [weak self] in self?.revisions[key.id] },
            encodeCurrentValue: { try? JSONEncoder().encode(get()) },
            applyRemote: { [weak self] data, record in
                guard let self, let decoded = try? JSONDecoder().decode(K.Value.self, from: data) else {
                    return false
                }
                set(decoded)
                guard let accountID = self.activeAccountID else { return false }
                Self.persistValue(key, decoded, accountID: accountID)
                var all = self.revisions
                all[key.id] = record
                self.revisions = all
                return true
            }
        )
    }

    private enum DefaultsKey {
        static let revisions = "red.forbes.sounding.settings.revisions"
        static let deviceLocalOverrides = "red.forbes.sounding.settings.deviceLocalOverrides"
        static let writerId = "red.forbes.sounding.settings.writerId"
        static func value(for id: String) -> String { "red.forbes.sounding.settings.value.\(id)" }
        static func encryptedValue(for id: String, accountID: String) -> String {
            "red.forbes.sounding.settings.encrypted.v1.\(AccountDataVault.storageSuffix(for: accountID)).\(id)"
        }
        static func encrypted(_ key: String, accountID: String) -> String {
            "red.forbes.sounding.settings.encrypted.v1.\(AccountDataVault.storageSuffix(for: accountID)).\(key)"
        }
    }

    private var revisions: [String: SettingRevision] {
        get {
            guard let accountID = activeAccountID else { return [:] }
            return Self.loadEncrypted(
                [String: SettingRevision].self, key: DefaultsKey.revisions, accountID: accountID
            ) ?? [:]
        }
        set {
            guard let accountID = activeAccountID else { return }
            Self.persistEncrypted(newValue, key: DefaultsKey.revisions, accountID: accountID)
        }
    }

    private static func loadValue<K: SettingDefinition>(_ key: K.Type, accountID: String) -> K.Value {
        if let value = loadEncrypted(
            K.Value.self, key: DefaultsKey.value(for: key.id), accountID: accountID
        ) { return value }
        return migrateLegacyValue(key, accountID: accountID) ?? key.defaultValue
    }

    private static func persistValue<K: SettingDefinition>(_ key: K.Type, _ value: K.Value, accountID: String) {
        persistEncrypted(value, key: DefaultsKey.value(for: key.id), accountID: accountID)
    }

    private static func loadEncrypted<Value: Decodable>(
        _ type: Value.Type, key: String, accountID: String
    ) -> Value? {
        let storageKey = DefaultsKey.encrypted(key, accountID: accountID)
        guard let sealed = UserDefaults.standard.data(forKey: storageKey),
              let data = AccountDataVault.open(sealed, accountID: accountID, purpose: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private static func persistEncrypted<Value: Encodable>(
        _ value: Value, key: String, accountID: String
    ) {
        guard let data = try? JSONEncoder().encode(value),
              let sealed = AccountDataVault.seal(data, accountID: accountID, purpose: key) else { return }
        UserDefaults.standard.set(sealed, forKey: DefaultsKey.encrypted(key, accountID: accountID))
    }

    // LEGACY MIGRATION: remove after the account-vault rollout window.
    private static func migrateLegacyValue<K: SettingDefinition>(
        _ key: K.Type, accountID: String
    ) -> K.Value? {
        let legacyKey = DefaultsKey.value(for: key.id)
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let value = try? JSONDecoder().decode(K.Value.self, from: data) else { return nil }
        persistValue(key, value, accountID: accountID)
        UserDefaults.standard.removeObject(forKey: legacyKey)
        return value
    }

    private static func loadOrCreateWriterId() -> String {
        if let existing = UserDefaults.standard.string(forKey: DefaultsKey.writerId) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: DefaultsKey.writerId)
        return generated
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
