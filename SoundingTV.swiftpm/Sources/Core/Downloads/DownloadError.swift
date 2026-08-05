import Foundation

enum DownloadError: LocalizedError, Equatable {
    case invalidURL
    case streamResolutionFailed
    case emptyPlaylist
    case encryptedStream
    case byteRangeSegments
    case playlistTooDeep
    case unsupportedContainer
    case notEntitled
    case previewOnly
    case trafficStopped(statusCode: Int, until: Date)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid stream URL."
        case .streamResolutionFailed: return "Could not resolve the stream."
        case .emptyPlaylist: return "The stream had no audio segments."
        case .encryptedStream: return "This stream is protected and can't be downloaded."
        case .byteRangeSegments: return "This stream's segment format isn't supported for downloads."
        case .playlistTooDeep: return "This stream's playlist nests too deeply."
        case .unsupportedContainer: return "This track's audio format isn't supported for downloads."
        case .notEntitled: return "Downloads require SoundCloud Go+."
        case .previewOnly: return "Only a preview is available for this track."
        case .trafficStopped(let statusCode, let until):
            return "SoundCloud returned HTTP \(statusCode). Downloads are paused until \(until.formatted(date: .abbreviated, time: .shortened))."
        }
    }
}
