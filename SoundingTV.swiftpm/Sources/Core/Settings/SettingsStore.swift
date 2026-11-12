import Foundation

@MainActor
protocol SettingsSynchronizationReceiving: AnyObject, Sendable {
    func noteSettingsMutation()
    func noteSettingsNeedFullFetch()
}
import Combine
import CryptoKit
import Security
import SwiftUI

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

    static let didForgetAccountData = Notification.Name("red.forbes.sounding.account-data-vault.didForget")

    static let unsuffixedAccountKeys = [
        "playedTrackLog.v1",
        "red.forbes.sounding.mac.profileActivity",
    ]

    static func forget(accountID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
        SoundingKeychain.delete(query)
        removeDefaults(for: accountID, in: .standard)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didForgetAccountData, object: nil)
        }
    }

    static func removeDefaults(for accountID: String, in defaults: UserDefaults) {
        let suffix = storageSuffix(for: accountID)
        for key in defaults.dictionaryRepresentation().keys where key.contains(suffix) {
            defaults.removeObject(forKey: key)
        }
        for key in unsuffixedAccountKeys {
            defaults.removeObject(forKey: key)
        }
    }

    private static func key(for accountID: String, createIfMissing: Bool = true) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        switch SoundingKeychain.copyData(query) {
        case .present(let data):
            guard data.count == 32 else { return nil }
            return SymmetricKey(data: data)
        case .failed:
            return nil
        case .absent:
            break
        }
        guard createIfMissing, SoundingKeychain.isDurable else { return nil }
        var bytes = Data(count: 32)
        guard bytes.withUnsafeMutableBytes({ buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }) == errSecSuccess else { return nil }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard SoundingKeychain.add(add) == errSecSuccess else {
            return key(for: accountID, createIfMissing: false)
        }
        return SymmetricKey(data: bytes)
    }
}

enum SettingScope: String, Codable, Equatable {
    case deviceLocal
    case synced
    case account
    case accountDeviceLocal

    var syncsWithICloud: Bool { self == .synced || self == .account }
    var isAccountBound: Bool { self == .account || self == .accountDeviceLocal }
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

enum AnalysisSettingMigration {
    static let legacyRulesId = "automaticAnalysisPolicy"
    static let legacyExecutionId = "automaticAnalysisExecutionPolicy"

    struct LegacyRules: Codable, Equatable, Sendable {
        var likedTracks: Bool
        var yourPlaylists: Bool
    }

    static func analyseOnDevice(legacyRules: LegacyRules?) -> Bool {
        guard let legacyRules else { return SettingKeys.AnalyseMusicOnDevice.defaultValue }
        return legacyRules.likedTracks || legacyRules.yourPlaylists
    }
}

// MARK: - Synced collection policy model

enum DJCollectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case autoDJ
    case djOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal Playlist"
        case .autoDJ: return "Prefer Auto Mix"
        case .djOnly: return "DJ Only"
        }
    }

    var explanation: String {
        switch self {
        case .normal: return "Plays normally unless Auto Mix is already on."
        case .autoDJ: return "Turns on Auto Mix when playback starts, but manual playback remains available."
        case .djOnly: return "Always starts as an Auto Mix session and keeps its DJ rules attached to the queue."
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

enum DJBlendLength: String, Codable, CaseIterable, Identifiable, Sendable {
    case short
    case normal
    case long

    var id: String { rawValue }

    var bars: Int {
        switch self {
        case .short: return 16
        case .normal: return 32
        case .long: return 64
        }
    }

    var displayName: String {
        switch self {
        case .short: return "Short"
        case .normal: return "Auto"
        case .long: return "Long"
        }
    }
}

enum PrepAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case matchWindow
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .matchWindow: return "Match Window"
        case .dark:        return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .matchWindow: return nil
        case .dark:        return .dark
        }
    }
}

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

enum DownloadCollectionKind: String, Codable, Equatable, Sendable {
    case playlist
    case likes
}

struct DownloadedCollectionRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: DownloadCollectionKind
    var title: String
    var artworkURL: URL?
    var addedAt: Date
    var excludedTrackIDs: Set<String>

    init(
        id: String,
        kind: DownloadCollectionKind,
        title: String,
        artworkURL: URL? = nil,
        addedAt: Date = Date(),
        excludedTrackIDs: Set<String> = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.artworkURL = artworkURL
        self.addedAt = addedAt
        self.excludedTrackIDs = excludedTrackIDs
    }
}

struct CollectionPolicy: Codable, Equatable, Sendable {
    var qualityCeiling: QualityCeiling?
    private(set) var legacyAutomaticDownloads: Bool = false
    var djMode: DJCollectionMode
    var isDefaultDJSource: Bool
    var djProfileId: DJProfileID
    var queueOrder: DJQueueOrderPolicy
    var setHandling: DJSetHandling
    var avoidVocalOverlap: Bool
    var maximumTransitionBars: Int

    static let standard = CollectionPolicy(
        qualityCeiling: nil,
        djMode: .normal,
        isDefaultDJSource: false,
        djProfileId: .automatic,
        queueOrder: .profileDefault,
        setHandling: .include,
        avoidVocalOverlap: true,
        maximumTransitionBars: 16
    )

    private enum CodingKeys: String, CodingKey {
        case qualityCeiling
        case djMode, isDefaultDJSource, djProfileId, queueOrder, setHandling
        case avoidVocalOverlap, maximumTransitionBars
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case automaticDownloads
    }

    init(
        qualityCeiling: QualityCeiling?,
        djMode: DJCollectionMode,
        isDefaultDJSource: Bool,
        djProfileId: DJProfileID,
        queueOrder: DJQueueOrderPolicy,
        setHandling: DJSetHandling,
        avoidVocalOverlap: Bool,
        maximumTransitionBars: Int
    ) {
        self.qualityCeiling = qualityCeiling
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
        legacyAutomaticDownloads = (try? decoder.container(keyedBy: LegacyCodingKeys.self)
            .decodeIfPresent(Bool.self, forKey: .automaticDownloads)) ?? false
        djMode = try container.decodeIfPresent(DJCollectionMode.self, forKey: .djMode) ?? defaults.djMode
        isDefaultDJSource = try container.decodeIfPresent(Bool.self, forKey: .isDefaultDJSource) ?? defaults.isDefaultDJSource
        djProfileId = try container.decodeIfPresent(DJProfileID.self, forKey: .djProfileId) ?? defaults.djProfileId
        queueOrder = try container.decodeIfPresent(DJQueueOrderPolicy.self, forKey: .queueOrder) ?? defaults.queueOrder
        setHandling = try container.decodeIfPresent(DJSetHandling.self, forKey: .setHandling) ?? defaults.setHandling
        avoidVocalOverlap = try container.decodeIfPresent(Bool.self, forKey: .avoidVocalOverlap) ?? defaults.avoidVocalOverlap
        maximumTransitionBars = try container.decodeIfPresent(Int.self, forKey: .maximumTransitionBars) ?? defaults.maximumTransitionBars
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(qualityCeiling, forKey: .qualityCeiling)
        try container.encode(djMode, forKey: .djMode)
        try container.encode(isDefaultDJSource, forKey: .isDefaultDJSource)
        try container.encode(djProfileId, forKey: .djProfileId)
        try container.encode(queueOrder, forKey: .queueOrder)
        try container.encode(setHandling, forKey: .setHandling)
        try container.encode(avoidVocalOverlap, forKey: .avoidVocalOverlap)
        try container.encode(maximumTransitionBars, forKey: .maximumTransitionBars)
    }

    static func == (lhs: CollectionPolicy, rhs: CollectionPolicy) -> Bool {
        lhs.qualityCeiling == rhs.qualityCeiling
            && lhs.djMode == rhs.djMode
            && lhs.isDefaultDJSource == rhs.isDefaultDJSource
            && lhs.djProfileId == rhs.djProfileId
            && lhs.queueOrder == rhs.queueOrder
            && lhs.setHandling == rhs.setHandling
            && lhs.avoidVocalOverlap == rhs.avoidVocalOverlap
            && lhs.maximumTransitionBars == rhs.maximumTransitionBars
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

    enum LiveActivitiesEnabled: SettingDefinition {
        static let id = "liveActivitiesEnabled"
        static let defaultScope: SettingScope = .deviceLocal
        static let defaultValue: Bool = true
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

    enum OptimiseStorage: SettingDefinition {
        static let id = "optimiseDownloadStorage"
        static let defaultScope: SettingScope = .deviceLocal
        static var defaultValue: Bool {
            #if os(tvOS)
            return true
            #else
            return false
            #endif
        }
        static var isAlwaysOn: Bool {
            #if os(tvOS)
            return true
            #else
            return false
            #endif
        }
    }

    enum OptimiseStorageMinimumBytes: SettingDefinition {
        static let id = "optimiseDownloadStorageMinimumBytes"
        static let defaultScope: SettingScope = .deviceLocal
        static let defaultValue: Int64 = 0
    }

    enum DownloadedCollections: SettingDefinition {
        static let id = "downloadedCollections"
        static let defaultScope: SettingScope = .accountDeviceLocal
        static let defaultValue: [String: DownloadedCollectionRecord] = [:]
    }

    enum DownloadModelVersion: SettingDefinition {
        static let id = "downloadModelVersion"
        static let defaultScope: SettingScope = .accountDeviceLocal
        static let defaultValue: Int = 0
        static let captured = 1
        static let current = 2
    }

    enum LegacyDownloadCollectionIDs: SettingDefinition {
        static let id = "legacyDownloadCollectionIDs"
        static let defaultScope: SettingScope = .accountDeviceLocal
        static let defaultValue: Set<String> = []
    }

    enum ShareSoundingLinks: SettingDefinition {
        static let id = "shareSoundingLinks"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: Bool = false
    }

    enum LyricsSourceSetting: SettingDefinition {
        static let id = "lyricsSource"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: LyricsProvider = .unset
    }

    enum DJAutoMixEnabled: SettingDefinition {
        static let id = "djAutoMixEnabled"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: Bool = false
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

    enum DJBlend: SettingDefinition {
        static let id = "djBlend"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: DJBlendLength = .normal
        static let isScopeOverridable = true
    }

    enum DJKeepQueueOrder: SettingDefinition {
        static let id = "djKeepQueueOrder"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: Bool = true
        static let isScopeOverridable = true
    }

    enum DJEnergyLevel: SettingDefinition {
        static let id = "djEnergyLevel"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: Double = 0.6
        static let isScopeOverridable = true
    }

    enum DJRiserLevel: SettingDefinition {
        static let id = "djRiserLevel"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: Double = 0.5
        static let isScopeOverridable = true
    }

    enum DJPerformanceLevel: SettingDefinition {
        static let id = "djPerformanceLevel"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: MixPerformanceLevel = .subtle
        static let isScopeOverridable = true
    }

    enum DJMoveStyle: SettingDefinition {
        static let id = "djMoveStyle"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: AutoMixStyle = .standard
        static let isScopeOverridable = true
    }

    enum DJEnergyFollowsNight: SettingDefinition {
        static let id = "djEnergyFollowsNight"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: Bool = true
        static let isScopeOverridable = true
    }

    enum DJMatchWorkout: SettingDefinition {
        static let id = "djMatchWorkout"
        static let defaultScope: SettingScope = .deviceLocal
        static let defaultValue: Bool = false
    }

    enum PrepAppearanceSetting: SettingDefinition {
        static let id = "prepAppearance"
        static let defaultScope: SettingScope = .deviceLocal
        static let defaultValue: PrepAppearance = .matchWindow
    }

    enum DJStartOptions: SettingDefinition {
        static let id = "djStartConfiguration"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: DJStartConfiguration = .standard
        static let isScopeOverridable = true
    }

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
        static let defaultScope: SettingScope = .account
        static let defaultValue: [RecentSearchEntry] = []
    }

    enum CollectionPolicies: SettingDefinition {
        static let id = "collectionPolicies"
        static let defaultScope: SettingScope = .account
        static let defaultValue: [String: CollectionPolicy] = [:]
        static let isScopeOverridable = true
    }

    enum SyncSettingsWithICloud: SettingDefinition {
        static let id = "syncSettingsWithICloud"
        static let defaultScope: SettingScope = .deviceLocal
        static let defaultValue: Bool = true
    }

    enum AnalyseMusicOnDevice: SettingDefinition {
        static let id = "analyseMusicOnDevice"
        static let defaultScope: SettingScope = .deviceLocal
        static let defaultValue: Bool = true
    }

    enum TrackTrims: SettingDefinition {
        static let id = "trackTrims"
        static let defaultScope: SettingScope = .account
        static let defaultValue: [String: TrackTrim] = [:]
    }

    enum CollectionViewModes: SettingDefinition {
        static let id = "collectionViewModes"
        static let defaultScope: SettingScope = .synced
        static let defaultValue: [String: CollectionViewMode] = [:]
    }

    enum SavedMixes: SettingDefinition {
        static let id = "savedMixes"
        static let defaultScope: SettingScope = .account
        static let defaultValue: Data = Data()
    }

    enum DJPlanEdits: SettingDefinition {
        static let id = "djPlanEdits"
        static let defaultScope: SettingScope = .account
        static let defaultValue: Data = Data()
    }

    enum RecentPlays: SettingDefinition {
        static let id = "recentPlays"
        static let defaultScope: SettingScope = .account
        static let defaultValue: [RecentPlay] = []
    }

    enum ContinueSessions: SettingDefinition {
        static let id = "continueSessions"
        static let defaultScope: SettingScope = .account
        static let defaultValue: [ContinueSession] = []
    }

    enum PlaylistFolders: SettingDefinition {
        static let id = "playlistFolders"
        static let defaultScope: SettingScope = .account
        static let defaultValue: [String: SyncedRecord] = [:]
    }

    enum SidebarPins: SettingDefinition {
        static let id = "sidebarPins"
        static let defaultScope: SettingScope = .account
        static let defaultValue: [String: SyncedRecord] = [:]
    }
}

struct SyncedRecord: Codable, Equatable, Sendable {
    var modifiedAtMillis: Int64
    var writerId: String
    var payload: Data
}

enum SyncedRecordMerge {
    static func remoteWins(local: SyncedRecord, remote: SyncedRecord) -> Bool {
        if remote.modifiedAtMillis != local.modifiedAtMillis {
            return remote.modifiedAtMillis > local.modifiedAtMillis
        }
        return remote.writerId > local.writerId
    }

    static func merge(local: [String: SyncedRecord], remote: [String: SyncedRecord]) -> [String: SyncedRecord] {
        var merged = local
        for (id, record) in remote {
            if let existing = merged[id], !remoteWins(local: existing, remote: record) { continue }
            merged[id] = record
        }
        return merged
    }
}

enum CollectionViewMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case grid
    case list

    var id: Self { self }

    var title: String {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        }
    }

    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

struct RecentSearchEntry: Codable, Equatable, Identifiable {
    var id: String { itemID ?? query }
    let query: String
    let avatarURL: URL?
    let subtitle: String
    var itemID: String? = nil
    var kind: String? = nil
    var payload: Data? = nil
}

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
    enum Scope: String, Codable, Equatable {
        case appleID
        case account
    }

    struct Entry: Codable, Equatable {
        let id: String
        let valueJSON: Data
        let revision: UInt64
        let updatedAtMillis: Int64
        let writerId: String
    }

    static let currentFormat = 2

    var entries: [Entry]
    var scope: Scope
    var accountTag: String?
    private(set) var isLegacy: Bool

    init(entries: [Entry], scope: Scope = .appleID, accountTag: String? = nil) {
        self.entries = entries
        self.scope = scope
        self.accountTag = accountTag
        self.isLegacy = false
    }

    private enum CodingKeys: String, CodingKey {
        case format, items, entries, scope, accountTag
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let items = try container.decodeIfPresent([Entry].self, forKey: .items) {
            entries = items
            scope = try container.decode(Scope.self, forKey: .scope)
            accountTag = try container.decodeIfPresent(String.self, forKey: .accountTag)
            isLegacy = false
        } else {
            entries = try container.decode([Entry].self, forKey: .entries)
            scope = .appleID
            accountTag = nil
            isLegacy = true
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormat, forKey: .format)
        try container.encode(entries, forKey: .items)
        try container.encode(scope, forKey: .scope)
        try container.encodeIfPresent(accountTag, forKey: .accountTag)
    }
}

struct SettingsSyncSnapshot: Equatable {
    let payload: Data
    let scope: SettingsSyncPayload.Scope
    let accountTag: String?
    let newestUpdateMillis: Int64
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
        if remote.updatedAtMillis != local.updatedAtMillis {
            return remote.updatedAtMillis > local.updatedAtMillis
        }
        if remote.revision != local.revision {
            return remote.revision > local.revision
        }
        return remote.writerId > local.writerId
    }

    static func nextRevision(after current: SettingRevision?, nowMillis: Int64, writerId: String) -> SettingRevision {
        SettingRevision(
            revision: (current?.revision ?? 0) + 1,
            updatedAtMillis: max(nowMillis, (current?.updatedAtMillis ?? 0) + 1),
            writerId: writerId
        )
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

struct SettingsVault: Sendable {
    let seal: @Sendable (Data, String, String) -> Data?
    let open: @Sendable (Data, String, String) -> Data?

    static let keychain = SettingsVault(
        seal: { AccountDataVault.seal($0, accountID: $1, purpose: $2) },
        open: { AccountDataVault.open($0, accountID: $1, purpose: $2) }
    )

    static let unsealed = SettingsVault(seal: { data, _, _ in data }, open: { data, _, _ in data })
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore(defaults: .standard, vault: .keychain, observesPreferences: true)

    static let djTransitionLengthRange: ClosedRange<Double> = 2...30
    static let ambientScreensaverTimeoutRange: ClosedRange<Double> = 15...900
    static let setMinimumDurationRange: ClosedRange<Double> = 15 * 60...4 * 60 * 60

    private weak var synchronizationSink: (any SettingsSynchronizationReceiving)?

    @Published private(set) var streamingQualityCeiling: QualityCeiling
    @Published private(set) var downloadQualityCeiling: QualityCeiling
    @Published private(set) var cellularStreamingAllowed: Bool
    @Published private(set) var liveActivitiesEnabled: Bool
    @Published private(set) var cellularDownloadsAllowed: Bool
    @Published private(set) var optimiseStorage: Bool
    @Published private(set) var optimiseStorageMinimumBytes: Int64
    @Published private(set) var downloadedCollections: [String: DownloadedCollectionRecord]
    @Published private(set) var downloadModelVersion: Int
    @Published private(set) var legacyDownloadCollectionIDs: Set<String>
    @Published private(set) var shareSoundingLinks: Bool
    @Published private(set) var lyricsSource: LyricsProvider
    @Published private(set) var djAutoMixEnabled: Bool
    @Published private(set) var djDefaultProfileId: DJProfileID
    @Published private(set) var djTransitionLengthSeconds: Double
    @Published private(set) var djEnergyLevel: Double
    @Published private(set) var djBlend: DJBlendLength
    @Published private(set) var djKeepQueueOrder: Bool
    @Published private(set) var djEnergyFollowsNight: Bool
    @Published private(set) var djRiserLevel: Double
    @Published private(set) var djPerformanceLevel: MixPerformanceLevel
    @Published private(set) var djMoveStyle: AutoMixStyle
    @Published private(set) var djMatchWorkout: Bool
    @Published private(set) var prepAppearance: PrepAppearance
    @Published private(set) var djStartConfiguration: DJStartConfiguration
    @Published private(set) var setMinimumDurationSeconds: Double
    @Published private(set) var ambientScreensaverTimeoutSeconds: Double
    @Published private(set) var recentSearchQueries: [RecentSearchEntry]
    @Published private(set) var collectionPolicies: [String: CollectionPolicy]
    @Published private(set) var analyseMusicOnDevice: Bool
    @Published private(set) var trackTrims: [String: TrackTrim]
    @Published private(set) var collectionViewModes: [String: CollectionViewMode]
    @Published private(set) var savedMixLibrary: Data
    @Published private(set) var djPlanEdits: Data
    @Published private(set) var recentPlays: [RecentPlay]
    @Published private(set) var continueSessions: [ContinueSession]
    @Published private(set) var playlistFolders: [String: SyncedRecord]
    @Published private(set) var sidebarPins: [String: SyncedRecord]
    @Published private(set) var syncSettingsWithICloud: Bool

    @Published private(set) var deviceLocalOverrideIds: Set<String>

    let preferences: SyncedPreferences
    private let defaults: UserDefaults
    private let vault: SettingsVault
    private let now: () -> Date
    private var activeAccountID: String?
    private let writerId: String

    var writerIdForSync: String { writerId }

    var activeAccountTag: String? {
        activeAccountID.map { AccountDataVault.storageSuffix(for: $0) }
    }

    func connectSynchronization(to sink: any SettingsSynchronizationReceiving) {
        synchronizationSink = sink
    }

    init(
        defaults: UserDefaults,
        vault: SettingsVault,
        writerId: String? = nil,
        now: @escaping () -> Date = { Date() },
        observesPreferences: Bool = false
    ) {
        self.defaults = defaults
        self.vault = vault
        self.now = now
        let resolvedWriterId = writerId ?? Self.loadOrCreateWriterId(in: defaults)
        self.writerId = resolvedWriterId
        preferences = SyncedPreferences(defaults: defaults, rules: .appleID, writerId: resolvedWriterId, now: now)
        streamingQualityCeiling = SettingKeys.StreamingQualityCeiling.defaultValue
        downloadQualityCeiling = SettingKeys.DownloadQualityCeiling.defaultValue
        cellularStreamingAllowed = SettingKeys.CellularStreamingAllowed.defaultValue
        liveActivitiesEnabled = SettingKeys.LiveActivitiesEnabled.defaultValue
        cellularDownloadsAllowed = SettingKeys.CellularDownloadsAllowed.defaultValue
        optimiseStorage = SettingKeys.OptimiseStorage.defaultValue
        optimiseStorageMinimumBytes = SettingKeys.OptimiseStorageMinimumBytes.defaultValue
        downloadedCollections = SettingKeys.DownloadedCollections.defaultValue
        downloadModelVersion = SettingKeys.DownloadModelVersion.defaultValue
        legacyDownloadCollectionIDs = SettingKeys.LegacyDownloadCollectionIDs.defaultValue
        shareSoundingLinks = SettingKeys.ShareSoundingLinks.defaultValue
        lyricsSource = SettingKeys.LyricsSourceSetting.defaultValue
        djAutoMixEnabled = SettingKeys.DJAutoMixEnabled.defaultValue
        djDefaultProfileId = SettingKeys.DJDefaultProfileId.defaultValue
        djTransitionLengthSeconds = SettingKeys.DJTransitionLengthSeconds.defaultValue
        djEnergyLevel = SettingKeys.DJEnergyLevel.defaultValue
        djBlend = SettingKeys.DJBlend.defaultValue
        djKeepQueueOrder = SettingKeys.DJKeepQueueOrder.defaultValue
        djEnergyFollowsNight = SettingKeys.DJEnergyFollowsNight.defaultValue
        djRiserLevel = SettingKeys.DJRiserLevel.defaultValue
        djPerformanceLevel = SettingKeys.DJPerformanceLevel.defaultValue
        djMoveStyle = SettingKeys.DJMoveStyle.defaultValue
        djMatchWorkout = SettingKeys.DJMatchWorkout.defaultValue
        prepAppearance = SettingKeys.PrepAppearanceSetting.defaultValue
        djStartConfiguration = SettingKeys.DJStartOptions.defaultValue
        setMinimumDurationSeconds = SettingKeys.SetMinimumDurationSeconds.defaultValue
        ambientScreensaverTimeoutSeconds = SettingKeys.AmbientScreensaverTimeoutSeconds.defaultValue
        recentSearchQueries = SettingKeys.RecentSearchQueries.defaultValue
        collectionPolicies = SettingKeys.CollectionPolicies.defaultValue
        analyseMusicOnDevice = SettingKeys.AnalyseMusicOnDevice.defaultValue
        trackTrims = SettingKeys.TrackTrims.defaultValue
        collectionViewModes = SettingKeys.CollectionViewModes.defaultValue
        savedMixLibrary = SettingKeys.SavedMixes.defaultValue
        djPlanEdits = SettingKeys.DJPlanEdits.defaultValue
        recentPlays = SettingKeys.RecentPlays.defaultValue
        continueSessions = SettingKeys.ContinueSessions.defaultValue
        playlistFolders = SettingKeys.PlaylistFolders.defaultValue
        sidebarPins = SettingKeys.SidebarPins.defaultValue
        syncSettingsWithICloud = SettingKeys.SyncSettingsWithICloud.defaultValue
        deviceLocalOverrideIds = []
        loadDeviceValues()
        preferences.onLocalChange = { [weak self] in
            self?.synchronizationSink?.noteSettingsMutation()
        }
        if observesPreferences {
            preferences.startObserving()
            applyDebugAutoMix()
        }
    }

    // MARK: - Account

    func unlockAccount(_ accountID: String) {
        guard activeAccountID != accountID else { return }
        activeAccountID = accountID
        adoptDeviceValuesFromAccount(accountID)
        loadAccountValues(accountID)
        captureLegacyDownloadCollectionsIfNeeded()
        applyDebugAutoMix()
        synchronizationSink?.noteSettingsNeedFullFetch()
    }

    func lockAccount() {
        guard activeAccountID != nil else { return }
        activeAccountID = nil
        resetAccountValues()
        synchronizationSink?.noteSettingsNeedFullFetch()
    }

    private func loadDeviceValues() {
        streamingQualityCeiling = deviceValue(SettingKeys.StreamingQualityCeiling.self)
        downloadQualityCeiling = deviceValue(SettingKeys.DownloadQualityCeiling.self)
        cellularStreamingAllowed = deviceValue(SettingKeys.CellularStreamingAllowed.self)
        liveActivitiesEnabled = deviceValue(SettingKeys.LiveActivitiesEnabled.self)
        cellularDownloadsAllowed = deviceValue(SettingKeys.CellularDownloadsAllowed.self)
        optimiseStorage = SettingKeys.OptimiseStorage.isAlwaysOn
            || deviceValue(SettingKeys.OptimiseStorage.self)
        optimiseStorageMinimumBytes = deviceValue(SettingKeys.OptimiseStorageMinimumBytes.self)
        shareSoundingLinks = deviceValue(SettingKeys.ShareSoundingLinks.self)
        lyricsSource = deviceValue(SettingKeys.LyricsSourceSetting.self)
        djAutoMixEnabled = deviceValue(SettingKeys.DJAutoMixEnabled.self)
        djDefaultProfileId = deviceValue(SettingKeys.DJDefaultProfileId.self)
        djTransitionLengthSeconds = deviceValue(SettingKeys.DJTransitionLengthSeconds.self)
        djEnergyLevel = deviceValue(SettingKeys.DJEnergyLevel.self)
        djBlend = deviceValue(SettingKeys.DJBlend.self)
        djKeepQueueOrder = deviceValue(SettingKeys.DJKeepQueueOrder.self)
        djEnergyFollowsNight = deviceValue(SettingKeys.DJEnergyFollowsNight.self)
        djRiserLevel = deviceValue(SettingKeys.DJRiserLevel.self)
        djPerformanceLevel = deviceValue(SettingKeys.DJPerformanceLevel.self)
        djMoveStyle = deviceValue(SettingKeys.DJMoveStyle.self)
        djMatchWorkout = deviceValue(SettingKeys.DJMatchWorkout.self)
        prepAppearance = deviceValue(SettingKeys.PrepAppearanceSetting.self)
        djStartConfiguration = deviceValue(SettingKeys.DJStartOptions.self)
        setMinimumDurationSeconds = deviceValue(SettingKeys.SetMinimumDurationSeconds.self)
        ambientScreensaverTimeoutSeconds = deviceValue(SettingKeys.AmbientScreensaverTimeoutSeconds.self)
        analyseMusicOnDevice = deviceValue(SettingKeys.AnalyseMusicOnDevice.self)
        collectionViewModes = deviceValue(SettingKeys.CollectionViewModes.self)
        syncSettingsWithICloud = deviceValue(SettingKeys.SyncSettingsWithICloud.self)
        deviceLocalOverrideIds = deviceStored(Set<String>.self, key: DefaultsKey.deviceOverrides) ?? []
    }

    private func loadAccountValues(_ accountID: String) {
        downloadedCollections = accountValue(SettingKeys.DownloadedCollections.self, accountID: accountID)
        downloadModelVersion = accountValue(SettingKeys.DownloadModelVersion.self, accountID: accountID)
        legacyDownloadCollectionIDs = accountValue(SettingKeys.LegacyDownloadCollectionIDs.self, accountID: accountID)
        recentSearchQueries = accountValue(SettingKeys.RecentSearchQueries.self, accountID: accountID)
        collectionPolicies = accountValue(SettingKeys.CollectionPolicies.self, accountID: accountID)
        trackTrims = accountValue(SettingKeys.TrackTrims.self, accountID: accountID)
        savedMixLibrary = accountValue(SettingKeys.SavedMixes.self, accountID: accountID)
        djPlanEdits = accountValue(SettingKeys.DJPlanEdits.self, accountID: accountID)
        recentPlays = accountValue(SettingKeys.RecentPlays.self, accountID: accountID)
        continueSessions = accountValue(SettingKeys.ContinueSessions.self, accountID: accountID)
        playlistFolders = accountValue(SettingKeys.PlaylistFolders.self, accountID: accountID)
        sidebarPins = accountValue(SettingKeys.SidebarPins.self, accountID: accountID)
    }

    private func resetAccountValues() {
        downloadedCollections = SettingKeys.DownloadedCollections.defaultValue
        downloadModelVersion = SettingKeys.DownloadModelVersion.defaultValue
        legacyDownloadCollectionIDs = SettingKeys.LegacyDownloadCollectionIDs.defaultValue
        recentSearchQueries = SettingKeys.RecentSearchQueries.defaultValue
        collectionPolicies = SettingKeys.CollectionPolicies.defaultValue
        trackTrims = SettingKeys.TrackTrims.defaultValue
        savedMixLibrary = SettingKeys.SavedMixes.defaultValue
        djPlanEdits = SettingKeys.DJPlanEdits.defaultValue
        recentPlays = SettingKeys.RecentPlays.defaultValue
        continueSessions = SettingKeys.ContinueSessions.defaultValue
        playlistFolders = SettingKeys.PlaylistFolders.defaultValue
        sidebarPins = SettingKeys.SidebarPins.defaultValue
    }

    private func adoptDeviceValuesFromAccount(_ accountID: String) {
        var adopted = [
            adoptFromAccount(SettingKeys.StreamingQualityCeiling.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DownloadQualityCeiling.self, accountID: accountID),
            adoptFromAccount(SettingKeys.CellularStreamingAllowed.self, accountID: accountID),
            adoptFromAccount(SettingKeys.LiveActivitiesEnabled.self, accountID: accountID),
            adoptFromAccount(SettingKeys.CellularDownloadsAllowed.self, accountID: accountID),
            adoptFromAccount(SettingKeys.OptimiseStorage.self, accountID: accountID),
            adoptFromAccount(SettingKeys.OptimiseStorageMinimumBytes.self, accountID: accountID),
            adoptFromAccount(SettingKeys.ShareSoundingLinks.self, accountID: accountID),
            adoptFromAccount(SettingKeys.LyricsSourceSetting.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DJAutoMixEnabled.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DJDefaultProfileId.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DJTransitionLengthSeconds.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DJEnergyLevel.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DJBlend.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DJKeepQueueOrder.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DJEnergyFollowsNight.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DJRiserLevel.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DJPerformanceLevel.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DJMoveStyle.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DJMatchWorkout.self, accountID: accountID),
            adoptFromAccount(SettingKeys.PrepAppearanceSetting.self, accountID: accountID),
            adoptFromAccount(SettingKeys.DJStartOptions.self, accountID: accountID),
            adoptFromAccount(SettingKeys.SetMinimumDurationSeconds.self, accountID: accountID),
            adoptFromAccount(SettingKeys.AmbientScreensaverTimeoutSeconds.self, accountID: accountID),
            adoptFromAccount(SettingKeys.CollectionViewModes.self, accountID: accountID),
        ].contains(true)
        if defaults.data(forKey: DefaultsKey.device(SettingKeys.AnalyseMusicOnDevice.id)) == nil {
            persistDevice(SettingKeys.AnalyseMusicOnDevice.self, loadAnalyseMusicOnDevice(accountID: accountID))
            adopted = true
        }
        if defaults.data(forKey: DefaultsKey.deviceOverrides) == nil,
           let ids = accountStored(Set<String>.self, key: DefaultsKey.deviceLocalOverrides, accountID: accountID) {
            persistDeviceRaw(ids, key: DefaultsKey.deviceOverrides)
            adopted = true
        }
        if adopted { loadDeviceValues() }
    }

    private func adoptFromAccount<K: SettingDefinition>(_ key: K.Type, accountID: String) -> Bool {
        guard defaults.data(forKey: DefaultsKey.device(key.id)) == nil,
              let value = accountStored(K.Value.self, key: DefaultsKey.value(for: key.id), accountID: accountID)
        else { return false }
        persistDevice(key, value)
        if key.defaultScope == .synced,
           let revision = accountStored(
               [String: SettingRevision].self, key: DefaultsKey.revisions, accountID: accountID
           )?[key.id] {
            var all = deviceRevisions
            if all[key.id] == nil {
                all[key.id] = revision
                deviceRevisions = all
            }
        }
        return true
    }

    private func applyDebugAutoMix() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let appearance = env["SOUNDING_TV_PREP_APPEARANCE"].flatMap(PrepAppearance.init(rawValue:)) {
            setPrepAppearance(appearance)
        }
        guard let raw = env["SOUNDING_TV_AUTOMIX"] else { return }
        setDJAutoMixEnabled(raw == "1")
        if let profile = env["SOUNDING_TV_AUTOMIX_PROFILE"] { setDJDefaultProfileId(DJProfileID(profile)) }
        if let night = env["SOUNDING_TV_AUTOMIX_NIGHT"] { setDJEnergyFollowsNight(night == "1") }
        if let level = env["SOUNDING_TV_AUTOMIX_ENERGY"].flatMap(Double.init) { setDJEnergyLevel(level) }
        if let workout = env["SOUNDING_TV_AUTOMIX_WORKOUT"] { setDJMatchWorkout(workout == "1") }
        #endif
    }

    private func captureLegacyDownloadCollectionsIfNeeded() {
        guard downloadModelVersion < SettingKeys.DownloadModelVersion.captured else { return }
        var flagged = Set(collectionPolicies.filter { $0.value.legacyAutomaticDownloads }.keys)
        if let data = defaults.data(forKey: "collectionPolicies.v2"),
           let mirrored = try? JSONDecoder().decode([String: CollectionPolicy].self, from: data) {
            flagged.formUnion(mirrored.filter { $0.value.legacyAutomaticDownloads }.keys)
        }
        legacyDownloadCollectionIDs = flagged
        writeLocal(SettingKeys.LegacyDownloadCollectionIDs.self, flagged)
        downloadModelVersion = SettingKeys.DownloadModelVersion.captured
        writeLocal(SettingKeys.DownloadModelVersion.self, downloadModelVersion)
    }

    func completeDownloadModelMigration() {
        legacyDownloadCollectionIDs = []
        writeLocal(SettingKeys.LegacyDownloadCollectionIDs.self, [])
        downloadModelVersion = SettingKeys.DownloadModelVersion.current
        writeLocal(SettingKeys.DownloadModelVersion.self, downloadModelVersion)
    }

    // MARK: - Setters

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

    func setLiveActivitiesEnabled(_ value: Bool) {
        guard value != liveActivitiesEnabled else { return }
        liveActivitiesEnabled = value
        writeLocal(SettingKeys.LiveActivitiesEnabled.self, value)
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

    func setOptimiseStorage(_ value: Bool) {
        let resolved = SettingKeys.OptimiseStorage.isAlwaysOn || value
        guard resolved != optimiseStorage else { return }
        optimiseStorage = resolved
        writeLocal(SettingKeys.OptimiseStorage.self, resolved)
    }

    func setOptimiseStorageMinimumBytes(_ value: Int64) {
        let clamped = max(0, value)
        guard clamped != optimiseStorageMinimumBytes else { return }
        optimiseStorageMinimumBytes = clamped
        writeLocal(SettingKeys.OptimiseStorageMinimumBytes.self, clamped)
    }

    func setDownloadedCollections(_ value: [String: DownloadedCollectionRecord]) {
        guard value != downloadedCollections else { return }
        downloadedCollections = value
        writeLocal(SettingKeys.DownloadedCollections.self, value)
    }

    func setLyricsSource(_ value: LyricsProvider) {
        guard value != lyricsSource else { return }
        lyricsSource = value
        writeLocal(SettingKeys.LyricsSourceSetting.self, value)
    }

    var lyricsEnabledBinding: Binding<Bool> {
        Binding(get: { self.lyricsSource == .lrclib }, set: { self.setLyricsSource($0 ? .lrclib : .off) })
    }

    func setShareSoundingLinks(_ value: Bool) {
        guard value != shareSoundingLinks else { return }
        shareSoundingLinks = value
        writeLocal(SettingKeys.ShareSoundingLinks.self, value)
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

    func setDJBlend(_ value: DJBlendLength) {
        guard value != djBlend else { return }
        djBlend = value
        writeLocal(SettingKeys.DJBlend.self, value)
    }

    func setDJKeepQueueOrder(_ value: Bool) {
        guard value != djKeepQueueOrder else { return }
        djKeepQueueOrder = value
        writeLocal(SettingKeys.DJKeepQueueOrder.self, value)
    }

    func setDJEnergyLevel(_ value: Double) {
        let clamped = min(1, max(0, value))
        guard clamped != djEnergyLevel else { return }
        djEnergyLevel = clamped
        writeLocal(SettingKeys.DJEnergyLevel.self, clamped)
    }

    func setDJRiserLevel(_ value: Double) {
        let clamped = min(1, max(0, value))
        guard clamped != djRiserLevel else { return }
        djRiserLevel = clamped
        writeLocal(SettingKeys.DJRiserLevel.self, clamped)
    }

    func setDJMoveStyle(_ value: AutoMixStyle) {
        guard value != djMoveStyle else { return }
        djMoveStyle = value
        writeLocal(SettingKeys.DJMoveStyle.self, value)
    }

    func updateDJMoveStyle(_ change: (inout AutoMixStyle) -> Void) {
        var next = djMoveStyle
        change(&next)
        setDJMoveStyle(next)
    }

    func setDJPerformanceLevel(_ value: MixPerformanceLevel) {
        guard value != djPerformanceLevel else { return }
        djPerformanceLevel = value
        writeLocal(SettingKeys.DJPerformanceLevel.self, value)
    }

    func setDJEnergyFollowsNight(_ value: Bool) {
        guard value != djEnergyFollowsNight else { return }
        djEnergyFollowsNight = value
        writeLocal(SettingKeys.DJEnergyFollowsNight.self, value)
    }

    func setDJMatchWorkout(_ value: Bool) {
        guard value != djMatchWorkout else { return }
        djMatchWorkout = value
        writeLocal(SettingKeys.DJMatchWorkout.self, value)
    }

    func setPrepAppearance(_ value: PrepAppearance) {
        guard value != prepAppearance else { return }
        prepAppearance = value
        writeLocal(SettingKeys.PrepAppearanceSetting.self, value)
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

    func setAnalyseMusicOnDevice(_ value: Bool) {
        guard value != analyseMusicOnDevice else { return }
        analyseMusicOnDevice = value
        writeLocal(SettingKeys.AnalyseMusicOnDevice.self, value)
    }

    func setTrackTrims(_ value: [String: TrackTrim]) {
        guard value != trackTrims else { return }
        trackTrims = value
        writeLocal(SettingKeys.TrackTrims.self, value)
    }

    func collectionViewMode(for page: String, default fallback: CollectionViewMode = .grid) -> CollectionViewMode {
        collectionViewModes[page] ?? fallback
    }

    func setCollectionViewMode(_ mode: CollectionViewMode, for page: String) {
        var value = collectionViewModes
        value[page] = mode
        guard value != collectionViewModes else { return }
        collectionViewModes = value
        writeLocal(SettingKeys.CollectionViewModes.self, value)
    }

    func setSavedMixLibrary(_ value: Data) {
        guard value != savedMixLibrary else { return }
        savedMixLibrary = value
        writeLocal(SettingKeys.SavedMixes.self, value)
    }

    func setDJPlanEdits(_ value: Data) {
        guard value != djPlanEdits else { return }
        djPlanEdits = value
        writeLocal(SettingKeys.DJPlanEdits.self, value)
    }

    func setRecentPlays(_ value: [RecentPlay]) {
        guard activeAccountID != nil, value != recentPlays else { return }
        recentPlays = value
        writeLocal(SettingKeys.RecentPlays.self, value)
    }

    func setContinueSessions(_ value: [ContinueSession]) {
        guard activeAccountID != nil, value != continueSessions else { return }
        continueSessions = value
        writeLocal(SettingKeys.ContinueSessions.self, value)
    }

    var hasActiveAccount: Bool { activeAccountID != nil }

    func setPlaylistFolders(_ value: [String: SyncedRecord]) {
        guard activeAccountID != nil, value != playlistFolders else { return }
        playlistFolders = value
        writeLocal(SettingKeys.PlaylistFolders.self, value)
    }

    func setSidebarPins(_ value: [String: SyncedRecord]) {
        guard activeAccountID != nil, value != sidebarPins else { return }
        sidebarPins = value
        writeLocal(SettingKeys.SidebarPins.self, value)
    }

    func setSyncSettingsWithICloud(_ value: Bool) {
        guard value != syncSettingsWithICloud else { return }
        syncSettingsWithICloud = value
        writeLocal(SettingKeys.SyncSettingsWithICloud.self, value)
        if value { synchronizationSink?.noteSettingsNeedFullFetch() }
    }

    func hasStoredValue<K: SettingDefinition>(_ key: K.Type) -> Bool {
        guard key.defaultScope.isAccountBound else {
            return defaults.data(forKey: DefaultsKey.device(key.id)) != nil
        }
        guard let accountID = activeAccountID else { return false }
        return defaults.data(
            forKey: DefaultsKey.encrypted(DefaultsKey.value(for: key.id), accountID: accountID)
        ) != nil
    }

    private var nowMillis: Int64 { Int64(now().timeIntervalSince1970 * 1000) }

    private func writeLocal<K: SettingDefinition>(_ key: K.Type, _ value: K.Value) {
        if key.defaultScope.isAccountBound {
            guard let accountID = activeAccountID else { return }
            persistAccount(key, value, accountID: accountID)
            guard key.defaultScope == .account else { return }
            var all = accountRevisions
            all[key.id] = SettingsMerge.nextRevision(after: all[key.id], nowMillis: nowMillis, writerId: writerId)
            accountRevisions = all
        } else {
            persistDevice(key, value)
            guard key.defaultScope == .synced else { return }
            var all = deviceRevisions
            all[key.id] = SettingsMerge.nextRevision(after: all[key.id], nowMillis: nowMillis, writerId: writerId)
            deviceRevisions = all
        }
        synchronizationSink?.noteSettingsMutation()
    }

    func isForcedDeviceLocal<K: SettingDefinition>(_ key: K.Type) -> Bool {
        deviceLocalOverrideIds.contains(key.id)
    }

    func effectiveScope<K: SettingDefinition>(_ key: K.Type) -> SettingScope {
        guard isForcedDeviceLocal(key) else { return key.defaultScope }
        switch key.defaultScope {
        case .synced: return .deviceLocal
        case .account: return .accountDeviceLocal
        case .deviceLocal, .accountDeviceLocal: return key.defaultScope
        }
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
        persistDeviceRaw(ids, key: DefaultsKey.deviceOverrides)
        synchronizationSink?.noteSettingsMutation()
    }

    // MARK: - Bindings

    var streamingQualityCeilingBinding: Binding<QualityCeiling> {
        Binding(get: { self.streamingQualityCeiling }, set: { self.setStreamingQualityCeiling($0) })
    }

    var liveActivitiesEnabledBinding: Binding<Bool> {
        Binding(get: { self.liveActivitiesEnabled }, set: { self.setLiveActivitiesEnabled($0) })
    }

    var cellularStreamingAllowedBinding: Binding<Bool> {
        Binding(get: { self.cellularStreamingAllowed }, set: { self.setCellularStreamingAllowed($0) })
    }

    var shareSoundingLinksBinding: Binding<Bool> {
        Binding(get: { self.shareSoundingLinks }, set: { self.setShareSoundingLinks($0) })
    }

    var djAutoMixEnabledBinding: Binding<Bool> {
        Binding(get: { self.djAutoMixEnabled }, set: { self.setDJAutoMixEnabled($0) })
    }

    var djDefaultProfileIdBinding: Binding<DJProfileID> {
        Binding(get: { self.djDefaultProfileId }, set: { self.setDJDefaultProfileId($0) })
    }

    var djBlendBinding: Binding<DJBlendLength> {
        Binding(get: { self.djBlend }, set: { self.setDJBlend($0) })
    }

    var djKeepQueueOrderBinding: Binding<Bool> {
        Binding(get: { self.djKeepQueueOrder }, set: { self.setDJKeepQueueOrder($0) })
    }

    var djEnergyLevelBinding: Binding<Double> {
        Binding(get: { self.djEnergyLevel }, set: { self.setDJEnergyLevel($0) })
    }

    var djRiserLevelBinding: Binding<Double> {
        Binding(get: { self.djRiserLevel }, set: { self.setDJRiserLevel($0) })
    }

    var djPerformanceLevelBinding: Binding<MixPerformanceLevel> {
        Binding(get: { self.djPerformanceLevel }, set: { self.setDJPerformanceLevel($0) })
    }

    var djEnergyFollowsNightBinding: Binding<Bool> {
        Binding(get: { self.djEnergyFollowsNight }, set: { self.setDJEnergyFollowsNight($0) })
    }

    var djMatchWorkoutBinding: Binding<Bool> {
        Binding(get: { self.djMatchWorkout }, set: { self.setDJMatchWorkout($0) })
    }

    var prepAppearanceBinding: Binding<PrepAppearance> {
        Binding(get: { self.prepAppearance }, set: { self.setPrepAppearance($0) })
    }

    var djTransitionLengthSecondsBinding: Binding<Double> {
        Binding(get: { self.djTransitionLengthSeconds }, set: { self.setDJTransitionLengthSeconds($0) })
    }

    var setMinimumDurationSecondsBinding: Binding<Double> {
        Binding(get: { self.setMinimumDurationSeconds }, set: { self.setSetMinimumDurationSeconds($0) })
    }

    var ambientScreensaverTimeoutSecondsBinding: Binding<Double> {
        Binding(get: { self.ambientScreensaverTimeoutSeconds }, set: { self.setAmbientScreensaverTimeoutSeconds($0) })
    }

    var analyseMusicOnDeviceBinding: Binding<Bool> {
        Binding(get: { self.analyseMusicOnDevice }, set: { self.setAnalyseMusicOnDevice($0) })
    }

    var syncSettingsWithICloudBinding: Binding<Bool> {
        Binding(get: { self.syncSettingsWithICloud }, set: { self.setSyncSettingsWithICloud($0) })
    }

    // MARK: - Sync

    func exportSyncSnapshot(scope: SettingsSyncPayload.Scope) -> SettingsSyncSnapshot? {
        let settingScope: SettingScope = scope == .account ? .account : .synced
        var entries: [SettingsSyncPayload.Entry] = syncRegistry.compactMap { entry in
            guard entry.scope == settingScope, !deviceLocalOverrideIds.contains(entry.id) else { return nil }
            guard let revision = entry.getRevision(), let value = entry.encodeCurrentValue() else { return nil }
            return SettingsSyncPayload.Entry(
                id: entry.id,
                valueJSON: value,
                revision: revision.revision,
                updatedAtMillis: revision.updatedAtMillis,
                writerId: revision.writerId
            )
        }
        let accountTag: String?
        switch scope {
        case .appleID:
            entries += preferences.entries()
            accountTag = nil
        case .account:
            guard let tag = activeAccountTag else { return nil }
            accountTag = tag
        }
        guard !entries.isEmpty,
              let data = try? JSONEncoder().encode(
                  SettingsSyncPayload(entries: entries, scope: scope, accountTag: accountTag)
              ) else { return nil }
        return SettingsSyncSnapshot(
            payload: data,
            scope: scope,
            accountTag: accountTag,
            newestUpdateMillis: entries.map(\.updatedAtMillis).max() ?? 0
        )
    }

    func exportSyncPayload(scope: SettingsSyncPayload.Scope = .appleID) -> Data? {
        exportSyncSnapshot(scope: scope)?.payload
    }

    struct MergeResult {
        var applied: [String] = []
        var kept: [String] = []
        var skippedDeviceLocal: [String] = []
        var unknownIds: [String] = []
        var malformed: [String] = []
        var decodeFailed = false
        var accountMismatch = false
    }

    @discardableResult
    func merge(_ data: Data) -> MergeResult {
        var result = MergeResult()
        guard var payload = try? JSONDecoder().decode(SettingsSyncPayload.self, from: data) else {
            result.decodeFailed = true
            return result
        }

        let settingScope: SettingScope
        switch payload.scope {
        case .appleID:
            settingScope = .synced
        case .account:
            guard let tag = payload.accountTag, tag == activeAccountTag else {
                result.accountMismatch = true
                return result
            }
            settingScope = .account
        }

        if settingScope == .account {
            let recordIDs: Set<String> = [SettingKeys.PlaylistFolders.id, SettingKeys.SidebarPins.id]
            let recordEntries = payload.entries.filter { recordIDs.contains($0.id) }
            payload.entries.removeAll { recordIDs.contains($0.id) }
            for entry in recordEntries where !deviceLocalOverrideIds.contains(entry.id) {
                let merged: Bool
                if entry.id == SettingKeys.SidebarPins.id {
                    merged = mergeRecords(entry, key: SettingKeys.SidebarPins.self, local: sidebarPins, apply: { self.sidebarPins = $0 })
                } else {
                    merged = mergeRecords(entry, key: SettingKeys.PlaylistFolders.self, local: playlistFolders, apply: { self.playlistFolders = $0 })
                }
                if merged {
                    result.applied.append(entry.id)
                } else {
                    result.malformed.append(entry.id)
                }
            }
        }

        let typed = syncRegistry.filter { $0.scope == settingScope }
        var knownIds = Set(typed.map(\.id))
        if settingScope == .synced {
            knownIds.formUnion(payload.entries.map(\.id).filter { preferences.knows($0) })
        }
        let (winners, outcome) = SettingsMerge.reconcile(
            payload: payload,
            knownIds: knownIds,
            deviceLocalIds: deviceLocalOverrideIds,
            localRevisions: { [weak self] id in self?.storedRevision(forSyncId: id, scope: settingScope) }
        )
        result.kept = outcome.keptIds
        result.skippedDeviceLocal = outcome.skippedDeviceLocalIds
        result.unknownIds = outcome.unknownIds

        for winner in winners {
            let record = SettingRevision(
                revision: winner.revision,
                updatedAtMillis: winner.updatedAtMillis,
                writerId: winner.writerId
            )
            let didApply: Bool
            if let entry = typed.first(where: { $0.id == winner.id }) {
                didApply = entry.applyRemote(winner.valueJSON, record)
            } else {
                didApply = preferences.apply(winner)
            }
            if didApply {
                result.applied.append(winner.id)
            } else {
                result.malformed.append(winner.id)
            }
        }
        return result
    }

    private func mergeRecords<K: SettingDefinition>(
        _ entry: SettingsSyncPayload.Entry,
        key: K.Type,
        local: [String: SyncedRecord],
        apply: ([String: SyncedRecord]) -> Void
    ) -> Bool where K.Value == [String: SyncedRecord] {
        guard activeAccountID != nil,
              let remote = try? JSONDecoder().decode([String: SyncedRecord].self, from: entry.valueJSON) else {
            return false
        }
        let merged = SyncedRecordMerge.merge(local: local, remote: remote)
        let remoteRevision = SettingRevision(
            revision: entry.revision,
            updatedAtMillis: entry.updatedAtMillis,
            writerId: entry.writerId
        )
        let localRevision = accountRevisions[key.id]
        let newest: SettingRevision? = SettingsMerge.remoteWins(local: localRevision, remote: remoteRevision) ? remoteRevision : localRevision
        guard merged != local else { return true }
        apply(merged)
        if let accountID = activeAccountID { persistAccount(key, merged, accountID: accountID) }
        var all = accountRevisions
        if merged == remote {
            all[key.id] = newest
            accountRevisions = all
        } else {
            all[key.id] = SettingsMerge.nextRevision(after: newest, nowMillis: nowMillis, writerId: writerId)
            accountRevisions = all
            synchronizationSink?.noteSettingsMutation()
        }
        return true
    }

    private func storedRevision(forSyncId id: String, scope: SettingScope) -> SettingRevision? {
        if preferences.knows(id) { return preferences.revision(for: id) }
        return scope.isAccountBound ? accountRevisions[id] : deviceRevisions[id]
    }

    private struct SyncableSetting {
        let id: String
        let scope: SettingScope
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
            SettingKeys.ShareSoundingLinks.self,
            get: { self.shareSoundingLinks },
            set: { self.shareSoundingLinks = $0 }
        ),
        syncableEntry(
            SettingKeys.LyricsSourceSetting.self,
            get: { self.lyricsSource },
            set: { self.lyricsSource = $0 }
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
            SettingKeys.DJBlend.self,
            get: { self.djBlend },
            set: { self.djBlend = $0 }
        ),
        syncableEntry(
            SettingKeys.DJKeepQueueOrder.self,
            get: { self.djKeepQueueOrder },
            set: { self.djKeepQueueOrder = $0 }
        ),
        syncableEntry(
            SettingKeys.DJEnergyLevel.self,
            get: { self.djEnergyLevel },
            set: { self.djEnergyLevel = $0 }
        ),
        syncableEntry(
            SettingKeys.DJEnergyFollowsNight.self,
            get: { self.djEnergyFollowsNight },
            set: { self.djEnergyFollowsNight = $0 }
        ),
        syncableEntry(
            SettingKeys.DJRiserLevel.self,
            get: { self.djRiserLevel },
            set: { self.djRiserLevel = $0 }
        ),
        syncableEntry(
            SettingKeys.DJPerformanceLevel.self,
            get: { self.djPerformanceLevel },
            set: { self.djPerformanceLevel = $0 }
        ),
        syncableEntry(
            SettingKeys.DJMoveStyle.self,
            get: { self.djMoveStyle },
            set: { self.djMoveStyle = $0 }
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
            SettingKeys.RecentSearchQueries.self,
            get: { self.recentSearchQueries },
            set: { self.recentSearchQueries = $0 }
        ),
        syncableEntry(
            SettingKeys.CollectionPolicies.self,
            get: { self.collectionPolicies },
            set: { self.collectionPolicies = $0 }
        ),
        syncableEntry(
            SettingKeys.TrackTrims.self,
            get: { self.trackTrims },
            set: { self.trackTrims = $0 }
        ),
        syncableEntry(
            SettingKeys.CollectionViewModes.self,
            get: { self.collectionViewModes },
            set: { self.collectionViewModes = $0 }
        ),
        syncableEntry(
            SettingKeys.SavedMixes.self,
            get: { self.savedMixLibrary },
            set: { self.savedMixLibrary = $0 }
        ),
        syncableEntry(
            SettingKeys.DJPlanEdits.self,
            get: { self.djPlanEdits },
            set: { self.djPlanEdits = $0 }
        ),
        syncableEntry(
            SettingKeys.RecentPlays.self,
            get: { self.recentPlays },
            set: { self.recentPlays = $0 }
        ),
        syncableEntry(
            SettingKeys.ContinueSessions.self,
            get: { self.continueSessions },
            set: { self.continueSessions = $0 }
        ),
        syncableEntry(
            SettingKeys.PlaylistFolders.self,
            get: { self.playlistFolders },
            set: { self.playlistFolders = $0 }
        ),
        syncableEntry(
            SettingKeys.SidebarPins.self,
            get: { self.sidebarPins },
            set: { self.sidebarPins = $0 }
        ),
    ]

    private func syncableEntry<K: SettingDefinition>(
        _ key: K.Type,
        get: @escaping () -> K.Value,
        set: @escaping (K.Value) -> Void
    ) -> SyncableSetting {
        SyncableSetting(
            id: key.id,
            scope: key.defaultScope,
            getRevision: { [weak self] in
                guard let self else { return nil }
                return key.defaultScope.isAccountBound ? self.accountRevisions[key.id] : self.deviceRevisions[key.id]
            },
            encodeCurrentValue: { try? JSONEncoder().encode(get()) },
            applyRemote: { [weak self] data, record in
                guard let self, let decoded = try? JSONDecoder().decode(K.Value.self, from: data) else {
                    return false
                }
                if key.defaultScope.isAccountBound {
                    guard let accountID = self.activeAccountID else { return false }
                    set(decoded)
                    self.persistAccount(key, decoded, accountID: accountID)
                    var all = self.accountRevisions
                    all[key.id] = record
                    self.accountRevisions = all
                } else {
                    set(decoded)
                    self.persistDevice(key, decoded)
                    var all = self.deviceRevisions
                    all[key.id] = record
                    self.deviceRevisions = all
                }
                return true
            }
        )
    }

    // MARK: - Storage

    private enum DefaultsKey {
        static let revisions = "red.forbes.sounding.settings.revisions"
        static let deviceLocalOverrides = "red.forbes.sounding.settings.deviceLocalOverrides"
        static let writerId = "red.forbes.sounding.settings.writerId"
        static let deviceRevisions = "red.forbes.sounding.settings.device.v1.revisions"
        static let deviceOverrides = "red.forbes.sounding.settings.device.v1.deviceLocalOverrides"
        static func device(_ id: String) -> String { "red.forbes.sounding.settings.device.v1.value.\(id)" }
        static func value(for id: String) -> String { "red.forbes.sounding.settings.value.\(id)" }
        static func encrypted(_ key: String, accountID: String) -> String {
            "red.forbes.sounding.settings.encrypted.v1.\(AccountDataVault.storageSuffix(for: accountID)).\(key)"
        }
    }

    private var deviceRevisions: [String: SettingRevision] {
        get { deviceStored([String: SettingRevision].self, key: DefaultsKey.deviceRevisions) ?? [:] }
        set { persistDeviceRaw(newValue, key: DefaultsKey.deviceRevisions) }
    }

    private var accountRevisions: [String: SettingRevision] {
        get {
            guard let accountID = activeAccountID else { return [:] }
            return accountStored([String: SettingRevision].self, key: DefaultsKey.revisions, accountID: accountID) ?? [:]
        }
        set {
            guard let accountID = activeAccountID else { return }
            persistEncrypted(newValue, key: DefaultsKey.revisions, accountID: accountID)
        }
    }

    private func loadAnalyseMusicOnDevice(accountID: String) -> Bool {
        let key = SettingKeys.AnalyseMusicOnDevice.self
        if let stored = accountStored(Bool.self, key: DefaultsKey.value(for: key.id), accountID: accountID) {
            return stored
        }
        let rulesKey = DefaultsKey.value(for: AnalysisSettingMigration.legacyRulesId)
        let legacyRules = accountStored(AnalysisSettingMigration.LegacyRules.self, key: rulesKey, accountID: accountID)
            ?? defaults.data(forKey: rulesKey).flatMap {
                try? JSONDecoder().decode(AnalysisSettingMigration.LegacyRules.self, from: $0)
            }
        let migrated = AnalysisSettingMigration.analyseOnDevice(legacyRules: legacyRules)
        for legacyId in [AnalysisSettingMigration.legacyRulesId, AnalysisSettingMigration.legacyExecutionId] {
            let legacyKey = DefaultsKey.value(for: legacyId)
            defaults.removeObject(forKey: DefaultsKey.encrypted(legacyKey, accountID: accountID))
            defaults.removeObject(forKey: legacyKey)
        }
        var all = accountStored([String: SettingRevision].self, key: DefaultsKey.revisions, accountID: accountID) ?? [:]
        if all.removeValue(forKey: AnalysisSettingMigration.legacyRulesId) != nil {
            persistEncrypted(all, key: DefaultsKey.revisions, accountID: accountID)
        }
        return migrated
    }

    private func deviceValue<K: SettingDefinition>(_ key: K.Type) -> K.Value {
        if let value = deviceStored(K.Value.self, key: DefaultsKey.device(key.id)) { return value }
        let legacyKey = DefaultsKey.value(for: key.id)
        guard let data = defaults.data(forKey: legacyKey),
              let value = try? JSONDecoder().decode(K.Value.self, from: data) else { return key.defaultValue }
        persistDevice(key, value)
        defaults.removeObject(forKey: legacyKey)
        return value
    }

    private func accountValue<K: SettingDefinition>(_ key: K.Type, accountID: String) -> K.Value {
        if let value = accountStored(K.Value.self, key: DefaultsKey.value(for: key.id), accountID: accountID) {
            return value
        }
        let legacyKey = DefaultsKey.value(for: key.id)
        guard let data = defaults.data(forKey: legacyKey),
              let value = try? JSONDecoder().decode(K.Value.self, from: data) else { return key.defaultValue }
        persistAccount(key, value, accountID: accountID)
        defaults.removeObject(forKey: legacyKey)
        return value
    }

    private func persistDevice<K: SettingDefinition>(_ key: K.Type, _ value: K.Value) {
        persistDeviceRaw(value, key: DefaultsKey.device(key.id))
    }

    private func persistAccount<K: SettingDefinition>(_ key: K.Type, _ value: K.Value, accountID: String) {
        persistEncrypted(value, key: DefaultsKey.value(for: key.id), accountID: accountID)
    }

    private func deviceStored<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func persistDeviceRaw<Value: Encodable>(_ value: Value, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func accountStored<Value: Decodable>(
        _ type: Value.Type, key: String, accountID: String
    ) -> Value? {
        let storageKey = DefaultsKey.encrypted(key, accountID: accountID)
        guard let sealed = defaults.data(forKey: storageKey),
              let data = vault.open(sealed, accountID, key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func persistEncrypted<Value: Encodable>(
        _ value: Value, key: String, accountID: String
    ) {
        guard let data = try? JSONEncoder().encode(value),
              let sealed = vault.seal(data, accountID, key) else { return }
        defaults.set(sealed, forKey: DefaultsKey.encrypted(key, accountID: accountID))
    }

    private static func loadOrCreateWriterId(in defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: DefaultsKey.writerId) {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: DefaultsKey.writerId)
        return generated
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
