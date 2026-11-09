#if SOUNDING_PERSONAL
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol PersonalAudioProvider: Sendable {
    @MainActor var isEnabled: Bool { get }
    func localAudioFile(for track: Track, metadata: DJExportMetadata) async throws -> URL
    func localAudioFile(forTrackID trackID: String, metadata: DJExportMetadata) async throws -> URL
    func cancelAll() async
}

extension PersonalAudioProvider {
    func exportTrack(_ record: DJExportTrackRecord, track: Track) async throws -> DJExportTrackRecord {
        var updated = record
        updated.audioFileURL = try await localAudioFile(for: track, metadata: record.metadata)
        return updated
    }
}

enum PersonalAudioError: Error, Equatable {
    case locked
    case previewOnly
    case downloadFailed(String)
    case timedOut
    case unsupportedFormat(String)
}

final class SoundCloudPersonalAudioProvider: PersonalAudioProvider {
    static let shared = SoundCloudPersonalAudioProvider()

    let cacheDirectory: URL
    private let queue: PersonalFetchQueue
    private let downloadTimeout: TimeInterval

    init(
        cacheDirectory: URL = SoundCloudPersonalAudioProvider.defaultCacheDirectory(),
        queue: PersonalFetchQueue = PersonalFetchQueue(pausedUntil: { await SoundCloudPersonalAudioProvider.soundCloudPausedUntil() }),
        downloadTimeout: TimeInterval = 30 * 60
    ) {
        self.cacheDirectory = cacheDirectory
        self.queue = queue
        self.downloadTimeout = downloadTimeout
    }

    static func defaultCacheDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Personal/DJ Audio", directoryHint: .isDirectory)
    }

    @MainActor var isEnabled: Bool { PersonalCodeLock.live().isUnlocked }

    func localAudioFile(for track: Track, metadata: DJExportMetadata) async throws -> URL {
        try await enqueue(trackID: track.id, metadata: metadata) { try await Self.playableTrack(track) }
    }

    func localAudioFile(forTrackID trackID: String, metadata: DJExportMetadata) async throws -> URL {
        try await enqueue(trackID: trackID, metadata: metadata) { try await Self.playableTrack(id: trackID) }
    }

    private func enqueue(
        trackID: String,
        metadata: DJExportMetadata,
        resolve: @escaping @Sendable () async throws -> Track
    ) async throws -> URL {
        guard await isEnabled else { throw PersonalAudioError.locked }
        if let cached = cachedFile(trackID: trackID) { return cached }
        return try await queue.file(for: trackID) { [self] in
            if let cached = self.cachedFile(trackID: trackID) { return cached }
            return try await self.fetch(track: try await resolve(), metadata: metadata)
        }
    }

    func cancelAll() async {
        await queue.cancelAll()
    }

    func cachedFile(trackID: String) -> URL? {
        for ext in ["mp3", "m4a", "flac"] {
            let url = cacheDirectory.appending(path: "\(trackID).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func clearCache() throws {
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return }
        try FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: - Fetch

    private func fetch(track playable: Track, metadata: DJExportMetadata) async throws -> URL {
        let addedByUs = try await Self.ensureDownloaded(playable, timeout: downloadTimeout)
        var tags = Self.tags(from: metadata, track: playable)
        if tags.artworkJPEG == nil { tags.artworkJPEG = await Self.artworkJPEG(for: playable) }
        guard let plaintext = await DownloadManager.shared.temporaryPlaintextFile(trackID: playable.id) else {
            await Self.discardDownload(playable.id, if: addedByUs)
            throw PersonalAudioError.downloadFailed(playable.id)
        }
        do {
            let url = try await store(plaintext.url, trackID: playable.id, tags: tags)
            plaintext.release()
            await Self.discardDownload(playable.id, if: addedByUs)
            return url
        } catch {
            plaintext.release()
            await Self.discardDownload(playable.id, if: addedByUs)
            throw error
        }
    }

    private func store(_ plaintext: URL, trackID: String, tags: PersonalAudioTags) async throws -> URL {
        let sourceExtension = plaintext.pathExtension.lowercased()
        guard let outputExtension = PersonalAudioTagger.outputExtension(forSource: sourceExtension) else {
            throw PersonalAudioError.unsupportedFormat(sourceExtension)
        }
        let fm = FileManager.default
        let staging = cacheDirectory.appending(path: ".staging", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var root = cacheDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)

        let staged = staging.appending(path: "\(UUID().uuidString).\(outputExtension)")
        defer { try? fm.removeItem(at: staged) }
        try await PersonalAudioTagger.write(tags, from: plaintext, to: staged)
        let destination = cacheDirectory.appending(path: "\(trackID).\(outputExtension)")
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staged, to: destination)
        return destination
    }

    static func tags(from metadata: DJExportMetadata, track: Track) -> PersonalAudioTags {
        PersonalAudioTags(
            title: metadata.title.isEmpty ? track.title : metadata.title,
            artist: metadata.artist.isEmpty ? track.user.displayName : metadata.artist,
            album: metadata.album,
            genre: metadata.genre.isEmpty ? (track.genre ?? "") : metadata.genre,
            isrc: metadata.isrc,
            year: metadata.year,
            comment: metadata.comment,
            artworkJPEG: metadata.artworkJPEG
        )
    }

    // MARK: - Download engine

    @MainActor
    private static func playableTrack(_ track: Track) async throws -> Track {
        guard track.transcodings.isEmpty else { return track }
        return try await playableTrack(id: track.id)
    }

    @MainActor
    private static func playableTrack(id: String) async throws -> Track {
        if let cached = DownloadManager.shared.cachedTrack(forTrackId: id), !cached.transcodings.isEmpty {
            return cached
        }
        let fetched = try await SoundCloudAPI.shared.getTrack(id: id)
        guard !fetched.transcodings.isEmpty else { throw PersonalAudioError.previewOnly }
        return fetched
    }

    @MainActor
    private static func ensureDownloaded(_ track: Track, timeout: TimeInterval) async throws -> Bool {
        let manager = DownloadManager.shared
        if manager.isLocallyAvailable(trackId: track.id) { return false }
        let addedByUs = manager.state(for: track.id) == .notDownloaded
        if case .refused(let error) = manager.download(track: track, confirmed: true) {
            throw error == .previewOnly ? PersonalAudioError.previewOnly : PersonalAudioError.downloadFailed(error.localizedDescription)
        }
        if case .paused = manager.state(for: track.id) { manager.resume(trackId: track.id) }
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while true {
                try Task.checkCancellation()
                switch manager.state(for: track.id) {
                case .downloaded where manager.isLocallyAvailable(trackId: track.id):
                    return addedByUs
                case .failed(let reason):
                    throw PersonalAudioError.downloadFailed(reason)
                default:
                    break
                }
                guard Date() < deadline else { throw PersonalAudioError.timedOut }
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            discardDownload(track.id, if: addedByUs)
            throw error
        }
    }

    @MainActor
    private static func discardDownload(_ trackID: String, if addedByUs: Bool) {
        guard addedByUs else { return }
        DownloadManager.shared.removeDownload(.track(trackID))
    }

    static func soundCloudPausedUntil() async -> Date? {
        await MainActor.run {
            let gateway = SoundCloudGateway.shared
            var until = gateway.backgroundWorkPausedUntil
            if case .waiting(_, let blocked) = gateway.trafficSafetyState() {
                until = max(until ?? blocked, blocked)
            }
            return until
        }
    }

    private static func artworkJPEG(for track: Track) async -> Data? {
        guard let url = track.artworkURL,
              let image = await SCArtworkStore.shared.cgImage(for: url, variant: .standard) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
