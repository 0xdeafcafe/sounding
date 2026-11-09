#if SOUNDING_PERSONAL
import AVFoundation
import Foundation

struct PersonalAudioTags: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String = ""
    var genre: String = ""
    var isrc: String = ""
    var year: Int = 0
    var comment: String = ""
    var artworkJPEG: Data?
}

enum PersonalAudioTaggerError: Error, Equatable {
    case unsupportedFormat(String)
    case exportFailed(String)
}

enum PersonalAudioTagger {
    static func outputExtension(forSource ext: String) -> String? {
        switch ext.lowercased() {
        case "mp3": return "mp3"
        case "m4a", "mp4", "aac": return "m4a"
        case "flac": return "flac"
        default: return nil
        }
    }

    static func write(_ tags: PersonalAudioTags, from source: URL, to destination: URL) async throws {
        let ext = source.pathExtension.lowercased()
        switch ext {
        case "mp3":
            try writeMP3(tags, from: source, to: destination)
        case "m4a", "mp4", "aac":
            try await writeMPEG4(tags, from: source, to: destination)
        case "flac":
            try FileManager.default.copyItem(at: source, to: destination)
        default:
            throw PersonalAudioTaggerError.unsupportedFormat(ext)
        }
    }

    // MARK: - ID3v2.3

    static func id3v2Tag(_ tags: PersonalAudioTags) -> Data {
        var frames = Data()
        frames.append(textFrame("TIT2", tags.title))
        frames.append(textFrame("TPE1", tags.artist))
        frames.append(textFrame("TALB", tags.album))
        frames.append(textFrame("TCON", tags.genre))
        frames.append(textFrame("TSRC", tags.isrc))
        if tags.year > 0 { frames.append(textFrame("TYER", String(tags.year))) }
        if !tags.comment.isEmpty { frames.append(commentFrame(tags.comment)) }
        if let artwork = tags.artworkJPEG, !artwork.isEmpty { frames.append(pictureFrame(artwork)) }

        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [0x03, 0x00, 0x00])
        tag.append(syncsafe(frames.count))
        tag.append(frames)
        return tag
    }

    static func existingID3v2Length(_ header: Data) -> Int {
        let bytes = [UInt8](header.prefix(10))
        guard bytes.count == 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33,
              bytes[6] & 0x80 == 0, bytes[7] & 0x80 == 0, bytes[8] & 0x80 == 0, bytes[9] & 0x80 == 0 else { return 0 }
        let size = Int(bytes[6]) << 21 | Int(bytes[7]) << 14 | Int(bytes[8]) << 7 | Int(bytes[9])
        let footer = bytes[3] >= 4 && bytes[5] & 0x10 != 0 ? 10 : 0
        return 10 + size + footer
    }

    static func writeMP3(_ tags: PersonalAudioTags, from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var skip: UInt64 = 0
        while true {
            try input.seek(toOffset: skip)
            let length = existingID3v2Length(try input.read(upToCount: 10) ?? Data())
            guard length > 0 else { break }
            skip += UInt64(length)
        }
        try input.seek(toOffset: skip)

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw PersonalAudioTaggerError.exportFailed(destination.lastPathComponent)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: id3v2Tag(tags))
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
    }

    private static func textFrame(_ id: String, _ value: String) -> Data {
        guard !value.isEmpty else { return Data() }
        return frame(id, encodedText(value))
    }

    private static func commentFrame(_ value: String) -> Data {
        let latin = value.canBeConverted(to: .isoLatin1)
        var body = Data([latin ? 0x00 : 0x01])
        body.append(contentsOf: Array("eng".utf8))
        body.append(latin ? Data([0x00]) : Data([0xFF, 0xFE, 0x00, 0x00]))
        body.append(latin ? value.data(using: .isoLatin1)! : utf16(value))
        return frame("COMM", body)
    }

    private static func pictureFrame(_ jpeg: Data) -> Data {
        var body = Data([0x00])
        body.append(contentsOf: Array("image/jpeg".utf8))
        body.append(contentsOf: [0x00, 0x03, 0x00])
        body.append(jpeg)
        return frame("APIC", body)
    }

    private static func encodedText(_ value: String) -> Data {
        if let latin = value.data(using: .isoLatin1) {
            return Data([0x00]) + latin
        }
        return Data([0x01]) + utf16(value)
    }

    private static func utf16(_ value: String) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in value.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        return data
    }

    private static func frame(_ id: String, _ body: Data) -> Data {
        var data = Data(id.utf8)
        let size = UInt32(body.count)
        data.append(contentsOf: [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
        data.append(contentsOf: [0x00, 0x00])
        data.append(body)
        return data
    }

    private static func syncsafe(_ value: Int) -> Data {
        Data([
            UInt8(value >> 21 & 0x7F),
            UInt8(value >> 14 & 0x7F),
            UInt8(value >> 7 & 0x7F),
            UInt8(value & 0x7F),
        ])
    }

    // MARK: - MPEG-4

    static func mpeg4Metadata(_ tags: PersonalAudioTags) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: (any NSCopying & NSObjectProtocol)?, dataType: String? = nil) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.extendedLanguageTag = "und"
            if let dataType { item.dataType = dataType }
            items.append(item)
        }
        add(.iTunesMetadataSongName, tags.title.isEmpty ? nil : tags.title as NSString)
        add(.iTunesMetadataArtist, tags.artist.isEmpty ? nil : tags.artist as NSString)
        add(.iTunesMetadataAlbum, tags.album.isEmpty ? nil : tags.album as NSString)
        add(.iTunesMetadataUserGenre, tags.genre.isEmpty ? nil : tags.genre as NSString)
        add(.iTunesMetadataReleaseDate, tags.year > 0 ? String(tags.year) as NSString : nil)
        add(.iTunesMetadataUserComment, tags.comment.isEmpty ? nil : tags.comment as NSString)
        if let artwork = tags.artworkJPEG, !artwork.isEmpty {
            add(.iTunesMetadataCoverArt, artwork as NSData, dataType: kCMMetadataBaseDataType_JPEG as String)
        }
        return items
    }

    static func writeMPEG4(_ tags: PersonalAudioTags, from source: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw PersonalAudioTaggerError.exportFailed(source.lastPathComponent)
        }
        session.metadata = mpeg4Metadata(tags)
        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            throw PersonalAudioTaggerError.exportFailed(source.lastPathComponent)
        }
    }
}
#endif
