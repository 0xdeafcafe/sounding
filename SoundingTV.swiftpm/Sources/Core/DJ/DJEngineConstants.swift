import Foundation
import AVFoundation

enum MixEngineError: LocalizedError, Equatable {
    case httpStatus(Int)
    case networkFailure(String)
    case emptyPlaylist
    case encryptedStream
    case byteRangeSegments
    case playlistTooDeep
    case unsupportedFormat(String)
    case decodeFailed(String)
    case unexpectedDecodedFormat(String)
    case engineStartFailed(String)
    case graphBuildFailed(String)
    case playbackStartFailed(String)
    case deckEmpty
    case cancelled

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "Stream request failed with HTTP \(code)."
        case .networkFailure(let detail):
            return "Network error while fetching audio: \(detail)"
        case .emptyPlaylist:
            return "The HLS playlist contained no media segments."
        case .encryptedStream:
            return "This stream is AES-encrypted; segments cannot be assembled offline."
        case .byteRangeSegments:
            return "This HLS playlist uses byte-range segments, which cannot be concatenated."
        case .playlistTooDeep:
            return "The HLS playlist nests variant playlists too deeply."
        case .unsupportedFormat(let detail):
            return "Unsupported audio format: \(detail)"
        case .decodeFailed(let detail):
            return "Could not decode the audio: \(detail)"
        case .unexpectedDecodedFormat(let detail):
            return "Decoder returned an unexpected PCM layout: \(detail)"
        case .engineStartFailed(let detail):
            return "Could not start the audio engine: \(detail)"
        case .graphBuildFailed(let detail):
            return "DJ mode is unavailable: the audio graph could not be built (\(detail))."
        case .playbackStartFailed(let detail):
            return "Playback could not be started: \(detail)"
        case .deckEmpty:
            return "That deck has no audio loaded."
        case .cancelled:
            return "Loading was cancelled."
        }
    }

    var displayMessage: String {
        switch self {
        case .httpStatus, .networkFailure:
            return "Couldn't download the audio."
        case .emptyPlaylist, .encryptedStream, .byteRangeSegments, .playlistTooDeep,
             .unsupportedFormat, .decodeFailed, .unexpectedDecodedFormat:
            return "This track can't be mixed."
        case .engineStartFailed, .graphBuildFailed, .playbackStartFailed:
            return "Mixing isn't available right now."
        case .deckEmpty:
            return "Nothing is loaded on this deck."
        case .cancelled:
            return "Cancelled."
        }
    }
}

enum DJEngineConstants {
    nonisolated static let canonicalSampleRate: Double = 44_100
    nonisolated static let canonicalChannels: AVAudioChannelCount = 2
}
