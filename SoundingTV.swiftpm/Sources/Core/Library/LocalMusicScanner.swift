import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct LocalMusicFileEntry: Codable, Hashable, Sendable {
    let relativePath: String
    var fileSize: Int64
    var modifiedAt: Date
    var title: String
    var artist: String?
    var album: String?
    var genre: String?
    var duration: TimeInterval
    var hasArtwork: Bool
    var isDownloaded: Bool
    var addedAt: Date? = nil
}

struct LocalMusicMetadata: Hashable, Sendable {
    var title: String
    var artist: String?
    var album: String?
    var genre: String?
    var duration: TimeInterval
    var artwork: Data?
}

struct LocalMusicFoundFile: Hashable, Sendable {
    let url: URL
    let relativePath: String
    let fileSize: Int64
    let modifiedAt: Date
    let isDownloaded: Bool
}

enum LocalMusicScanner {
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc", "flac", "alac", "caf",
    ]
    static let maximumFilesPerFolder = 10_000

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func trackID(folderID: String, relativePath: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(folderID)|\(relativePath.precomposedStringWithCanonicalMapping)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let magnitude = Int(hash & 0x000F_FFFF_FFFF_FFFF) + 1
        return String(-magnitude)
    }

    static func audioFiles(in folder: URL) -> [LocalMusicFoundFile] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }

        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var found: [String: LocalMusicFoundFile] = [:]
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix("."), !name.hasSuffix(".icloud") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let placeholder = placeholderTarget(for: url)
            let audioURL = placeholder ?? url
            guard isSupported(audioURL) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard placeholder != nil || values?.isRegularFile == true else { continue }

            let relative = relativePath(of: audioURL, base: base)
            let downloaded: Bool
            if placeholder != nil {
                downloaded = false
            } else if values?.isUbiquitousItem == true {
                downloaded = values?.ubiquitousItemDownloadingStatus != .notDownloaded
            } else {
                downloaded = true
            }
            let file = LocalMusicFoundFile(
                url: audioURL,
                relativePath: relative,
                fileSize: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                isDownloaded: downloaded
            )
            if let existing = found[relative], existing.isDownloaded, !file.isDownloaded { continue }
            found[relative] = file
            if found.count >= maximumFilesPerFolder { break }
        }
        return found.values.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    static func placeholderTarget(for url: URL) -> URL? {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let real = String(name.dropFirst().dropLast(".icloud".count))
        guard !real.isEmpty else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(real)
    }

    static func relativePath(of url: URL, base: String) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        if parent.hasPrefix(prefix) {
            return String(parent.dropFirst(prefix.count)) + "/" + url.lastPathComponent
        }
        return url.lastPathComponent
    }

    static func metadata(for url: URL) async -> LocalMusicMetadata {
        let fallback = fallbackTitleAndArtist(fromFileName: url.deletingPathExtension().lastPathComponent)
        var result = LocalMusicMetadata(title: fallback.title, artist: fallback.artist, duration: 0)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            result.duration = duration.seconds
        } else if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
            result.duration = Double(file.length) / file.fileFormat.sampleRate
        }
        var items: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) { items += common }
        if let all = try? await asset.load(.metadata) { items += all }
        guard !items.isEmpty else { return result }

        if let title = await string(in: items, identifiers: [.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName]) {
            result.title = title
        }
        if let artist = await string(in: items, identifiers: [.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist, .iTunesMetadataAlbumArtist]) {
            result.artist = artist
        }
        result.album = await string(in: items, identifiers: [.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum])
        if let genre = await string(in: items, identifiers: [.id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre, .commonIdentifierType]) {
            result.genre = normalisedGenre(genre)
        }
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork)
            + AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .id3MetadataAttachedPicture)
            + AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataCoverArt) {
            if let data = try? await item.load(.dataValue), !data.isEmpty {
                result.artwork = data
                break
            }
        }
        return result
    }

    private static func string(in items: [AVMetadataItem], identifiers: [AVMetadataIdentifier]) async -> String? {
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let value = try? await item.load(.stringValue) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return nil
    }

    static func normalisedGenre(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("("), let close = value.firstIndex(of: ")") {
            let rest = value[value.index(after: close)...].trimmingCharacters(in: .whitespaces)
            value = rest
        }
        return value.isEmpty ? nil : value
    }

    static func fallbackTitleAndArtist(fromFileName name: String) -> (title: String, artist: String?) {
        var stem = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        if let match = stem.range(of: #"^\d{1,3}[\s.\-]+"#, options: .regularExpression),
           stem[match.upperBound...].contains(where: \.isLetter) {
            stem = String(stem[match.upperBound...])
        }
        for separator in [" - ", " – ", " — "] {
            if let range = stem.range(of: separator) {
                let artist = stem[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let title = stem[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !title.isEmpty { return (title, artist) }
            }
        }
        return (stem.isEmpty ? name : stem, nil)
    }

    static func thumbnail(from data: Data, maxPixelSize: Int = 600) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func scan(
        folderID: String,
        folderURL: URL,
        previous: [LocalMusicFileEntry],
        artworkDirectory: URL?,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [LocalMusicFileEntry] {
        let known = Dictionary(previous.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let scannedBefore = !previous.isEmpty
        let scanDate = Date()
        func addedAt(_ path: String) -> Date? {
            if let old = known[path] { return old.addedAt }
            return scannedBefore ? scanDate : nil
        }
        var entries: [LocalMusicFileEntry] = []
        let files = audioFiles(in: folderURL)
        progress?(0, files.count)
        for (index, file) in files.enumerated() {
            if Task.isCancelled { return previous }
            if index > 0, index % 8 == 0 { progress?(index, files.count) }
            if let old = known[file.relativePath],
               old.fileSize == file.fileSize,
               old.modifiedAt == file.modifiedAt,
               old.isDownloaded || !file.isDownloaded {
                entries.append(old)
                continue
            }
            guard file.isDownloaded else {
                let fallback = fallbackTitleAndArtist(fromFileName: file.url.deletingPathExtension().lastPathComponent)
                entries.append(LocalMusicFileEntry(
                    relativePath: file.relativePath, fileSize: file.fileSize, modifiedAt: file.modifiedAt,
                    title: known[file.relativePath]?.title ?? fallback.title,
                    artist: known[file.relativePath]?.artist ?? fallback.artist,
                    album: known[file.relativePath]?.album, genre: known[file.relativePath]?.genre,
                    duration: known[file.relativePath]?.duration ?? 0,
                    hasArtwork: known[file.relativePath]?.hasArtwork ?? false,
                    isDownloaded: false,
                    addedAt: addedAt(file.relativePath)
                ))
                continue
            }
            let metadata = await metadata(for: file.url)
            var hasArtwork = false
            if let artwork = metadata.artwork, let artworkDirectory,
               let thumbnail = thumbnail(from: artwork) {
                let id = trackID(folderID: folderID, relativePath: file.relativePath)
                let target = artworkDirectory.appendingPathComponent("\(id).jpg")
                hasArtwork = (try? thumbnail.write(to: target, options: .atomic)) != nil
            }
            entries.append(LocalMusicFileEntry(
                relativePath: file.relativePath, fileSize: file.fileSize, modifiedAt: file.modifiedAt,
                title: metadata.title, artist: metadata.artist, album: metadata.album, genre: metadata.genre,
                duration: metadata.duration, hasArtwork: hasArtwork, isDownloaded: true,
                addedAt: addedAt(file.relativePath)
            ))
        }
        return entries
    }
}
