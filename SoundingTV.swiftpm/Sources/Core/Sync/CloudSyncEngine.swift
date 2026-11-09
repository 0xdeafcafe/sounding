import Foundation
import CloudKit
import Darwin

enum CloudSyncContainer {
    static let identifier = "iCloud.red.forbes.sounding"
}

enum CloudSyncAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

enum CloudSyncZone {
    static let cues = CKRecordZone.ID(zoneName: "Cues", ownerName: CKCurrentUserDefaultName)
    static let analysis = CKRecordZone.ID(zoneName: "Analysis", ownerName: CKCurrentUserDefaultName)
    static let session = CKRecordZone.ID(zoneName: "Session", ownerName: CKCurrentUserDefaultName)
    static let downloadManifests = CKRecordZone.ID(zoneName: "DownloadManifests", ownerName: CKCurrentUserDefaultName)
    static let setlists = CKRecordZone.ID(zoneName: "Setlists", ownerName: CKCurrentUserDefaultName)
    static let companion = CKRecordZone.ID(zoneName: "Companion", ownerName: CKCurrentUserDefaultName)
    static let library = CKRecordZone.ID(zoneName: "Library", ownerName: CKCurrentUserDefaultName)

    static let all: [CKRecordZone.ID] = [cues, analysis, session, downloadManifests, setlists, companion, library]
}

enum CloudSyncRecordType {
    static let cue = "Cue"
    static let cueDismissal = "CueDismissal"
    static let analysisRow = "AnalysisRow"
    static let session = "SoundCloudSession"
    static let downloadManifestEntry = "DownloadManifestEntry"
    static let setlistSnapshot = "SetlistSnapshot"
    static let companionDevice = "CompanionDevice"
    static let settingsEntry = "SettingsEntry"
    static let libraryChunk = "LibraryChunk"
}

struct SetlistSyncRecord: Sendable, Equatable {
    let trackId: String
    let deviceId: String
    let payload: Data
    let updatedAtMillis: Int64

    var recordKey: String { "\(deviceId)#\(trackId)" }

    init?(setlist: GeneratedSetlist, deviceId: String) {
        guard !setlist.trackId.isEmpty,
              !deviceId.isEmpty,
              let payload = try? JSONEncoder().encode(setlist) else { return nil }
        self.trackId = setlist.trackId
        self.deviceId = deviceId
        self.payload = payload
        self.updatedAtMillis = Int64((setlist.updatedAt.timeIntervalSince1970 * 1000).rounded())
    }

    init(trackId: String, deviceId: String, payload: Data, updatedAtMillis: Int64) {
        self.trackId = trackId
        self.deviceId = deviceId
        self.payload = payload
        self.updatedAtMillis = updatedAtMillis
    }

    var setlist: GeneratedSetlist? {
        try? JSONDecoder().decode(GeneratedSetlist.self, from: payload)
    }
}

struct SettingsSyncRecord: Sendable, Equatable {
    let deviceId: String
    let payload: Data
    let writerId: String
    let updatedAtMillis: Int64
    var accountTag: String? = nil

    static let accountSeparator = ".account."

    var recordName: String { Self.recordName(deviceId: deviceId, accountTag: accountTag) }

    static func recordName(deviceId: String, accountTag: String?) -> String {
        guard let accountTag else { return deviceId }
        return deviceId + accountSeparator + accountTag
    }

    static func parse(recordName: String) -> (deviceId: String, accountTag: String?) {
        guard let range = recordName.range(of: accountSeparator) else { return (recordName, nil) }
        return (String(recordName[..<range.lowerBound]), String(recordName[range.upperBound...]))
    }
}
