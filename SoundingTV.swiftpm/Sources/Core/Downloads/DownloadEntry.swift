import Foundation

struct DownloadEntry: Codable, @unchecked Sendable {
    var track: Track
    var isPinned: Bool
    var pinningCollectionIds: Set<String>
    var addedAt: Date
    var lastPlayedAt: Date
    var fileName: String?
    var fileSize: Int64
    var encryptionAccountID: String? = nil
    var originalFileExtension: String? = nil
    /// Stable description of the selected SoundCloud transcoding. Optional so
    /// indexes written by earlier builds remain decodable.
    var sourceFingerprint: String? = nil

    var isEffectivelyPinned: Bool { isPinned || !pinningCollectionIds.isEmpty }
    var isDownloaded: Bool { fileName != nil }
}
