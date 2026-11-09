import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import SoundingTV

final class LocalMusicScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMusicScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFindsSupportedAudioRecursivelyAndSkipsEverythingElse() throws {
        try LocalMusicFixtures.writeTone(to: root.appendingPathComponent("Opener.wav"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Crate/Deep"), withIntermediateDirectories: true)
        try LocalMusicFixtures.writeTone(to: root.appendingPathComponent("Crate/Deep/Closer.aiff"))
        try Data("not audio".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try LocalMusicFixtures.writeTone(to: root.appendingPathComponent(".hidden.wav"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        try LocalMusicFixtures.writeTone(to: root.appendingPathComponent(".Trash/Gone.wav"))
        try Data().write(to: root.appendingPathComponent(".Cloud Only.mp3.icloud"))

        let found = LocalMusicScanner.audioFiles(in: root)

        XCTAssertEqual(found.map(\.relativePath), ["Cloud Only.mp3", "Crate/Deep/Closer.aiff", "Opener.wav"])
        XCTAssertEqual(found.first { $0.relativePath == "Cloud Only.mp3" }?.isDownloaded, false)
        XCTAssertEqual(found.first { $0.relativePath == "Opener.wav" }?.isDownloaded, true)
    }

    func testEveryRequestedFormatIsSupported() {
        for ext in ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac"] {
            XCTAssertTrue(LocalMusicScanner.isSupported(URL(fileURLWithPath: "/x/track.\(ext.uppercased())")), ext)
        }
        XCTAssertFalse(LocalMusicScanner.isSupported(URL(fileURLWithPath: "/x/cover.jpg")))
    }

    func testFileNamesFallBackToArtistAndTitle() {
        XCTAssertEqual(LocalMusicScanner.fallbackTitleAndArtist(fromFileName: "07 - Night Tapes - Drifting").title, "Drifting")
        XCTAssertEqual(LocalMusicScanner.fallbackTitleAndArtist(fromFileName: "07 - Night Tapes - Drifting").artist, "Night Tapes")
        XCTAssertEqual(LocalMusicScanner.fallbackTitleAndArtist(fromFileName: "Low_Sun_Open_Water").title, "Low Sun Open Water")
        XCTAssertNil(LocalMusicScanner.fallbackTitleAndArtist(fromFileName: "Low_Sun_Open_Water").artist)
        XCTAssertEqual(LocalMusicScanner.fallbackTitleAndArtist(fromFileName: "1999").title, "1999")
    }

    func testUntaggedFileUsesItsNameAndMeasuresDuration() async throws {
        let url = root.appendingPathComponent("Glass District - After Hours.wav")
        try LocalMusicFixtures.writeTone(to: url, seconds: 2)

        let metadata = await LocalMusicScanner.metadata(for: url)

        XCTAssertEqual(metadata.title, "After Hours")
        XCTAssertEqual(metadata.artist, "Glass District")
        XCTAssertEqual(metadata.duration, 2, accuracy: 0.05)
        XCTAssertNil(metadata.artwork)
    }

    func testTaggedFileReadsTitleArtistGenreAndArtwork() async throws {
        let source = root.appendingPathComponent("source.wav")
        try LocalMusicFixtures.writeTone(to: source, seconds: 1.5)
        let tagged = root.appendingPathComponent("file name.m4a")
        try await LocalMusicFixtures.exportTagged(
            source: source, to: tagged,
            title: "Neon Weather", artist: "Maya Sol", album: "Weather Systems", genre: "House"
        )

        let metadata = await LocalMusicScanner.metadata(for: tagged)

        XCTAssertEqual(metadata.title, "Neon Weather")
        XCTAssertEqual(metadata.artist, "Maya Sol")
        XCTAssertEqual(metadata.album, "Weather Systems")
        XCTAssertEqual(metadata.genre, "House")
        XCTAssertEqual(metadata.duration, 1.5, accuracy: 0.1)
        XCTAssertNotNil(metadata.artwork.flatMap { LocalMusicScanner.thumbnail(from: $0, maxPixelSize: 32) })
    }

    func testTrackIDsAreStableNegativeAndDistinct() {
        let a = LocalMusicScanner.trackID(folderID: "F", relativePath: "Crate/One.mp3")
        XCTAssertEqual(a, LocalMusicScanner.trackID(folderID: "F", relativePath: "Crate/One.mp3"))
        XCTAssertNotEqual(a, LocalMusicScanner.trackID(folderID: "F", relativePath: "Crate/Two.mp3"))
        XCTAssertNotEqual(a, LocalMusicScanner.trackID(folderID: "G", relativePath: "Crate/One.mp3"))
        XCTAssertTrue(LocalTrackFile.isLocalTrackID(a))
        XCTAssertNotNil(Int(a))
        XCTAssertLessThan(Int(a) ?? 0, 0)
        XCTAssertFalse(LocalTrackFile.isLocalTrackID("123456"))
    }

    func testRescanKeepsUnchangedEntriesAndFollowsAddsAndDeletes() async throws {
        try LocalMusicFixtures.writeTone(to: root.appendingPathComponent("A - One.wav"))
        try LocalMusicFixtures.writeTone(to: root.appendingPathComponent("B - Two.wav"))
        let first = await LocalMusicScanner.scan(folderID: "F", folderURL: root, previous: [], artworkDirectory: nil)
        XCTAssertEqual(first.map(\.title), ["One", "Two"])

        let renamed = first.map { entry -> LocalMusicFileEntry in
            var copy = entry
            copy.title = "Kept \(entry.title)"
            return copy
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("B - Two.wav"))
        try LocalMusicFixtures.writeTone(to: root.appendingPathComponent("C - Three.wav"))

        let second = await LocalMusicScanner.scan(folderID: "F", folderURL: root, previous: renamed, artworkDirectory: nil)

        XCTAssertEqual(second.map(\.title), ["Kept One", "Three"])
        XCTAssertTrue(second.allSatisfy(\.isDownloaded))
    }
}

enum LocalMusicFixtures {
    static func writeTone(to url: URL, seconds: Double = 1, sampleRate: Double = 44_100) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate) * 0.25)
            }
        }
        let fileType: AudioFileTypeID = url.pathExtension.lowercased().hasPrefix("aif") ? kAudioFileAIFFType : kAudioFileWAVEType
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: fileType == kAudioFileAIFFType,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    static func exportTagged(source: URL, to destination: URL, title: String, artist: String, album: String, genre: String) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.featureUnsupported)
        }
        func item(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            return item
        }
        session.metadata = [
            item(.commonIdentifierTitle, title as NSString),
            item(.commonIdentifierArtist, artist as NSString),
            item(.commonIdentifierAlbumName, album as NSString),
            item(.iTunesMetadataUserGenre, genre as NSString),
            item(.commonIdentifierArtwork, artworkPNG() as NSData),
        ]
        try await session.export(to: destination, as: .m4a)
    }

    static func artworkPNG(size: Int = 64) -> Data {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0.42, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
