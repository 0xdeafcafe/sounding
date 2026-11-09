import Foundation
import AVFoundation
import AudioToolbox
import Combine
import CryptoKit

enum SourceImporter {

    static let maxCacheBytes: Int64 = 400_000_000
    static let maxCacheFiles = 8
    static let maxPlaylistDepth = 3

    private static let protectedKeysLock = NSLock()
    nonisolated(unsafe) private static var protectedKeys: Set<String> = []

    static func protect(cacheKey: String, in directory: URL) {
        let name = cachedURL(for: cacheKey, in: directory).lastPathComponent
        protectedKeysLock.lock()
        protectedKeys.insert(name)
        protectedKeysLock.unlock()
    }

    static func unprotect(cacheKey: String, in directory: URL) {
        let name = cachedURL(for: cacheKey, in: directory).lastPathComponent
        protectedKeysLock.lock()
        protectedKeys.remove(name)
        protectedKeysLock.unlock()
    }
    /// Canonical float PCM is useful for small tracks, but grows at roughly
    /// 21 MB per minute. Keep longer sources compressed and let
    /// AVAudioPlayerNode decode them in real time instead of manufacturing a
    /// multi-gigabyte cache file.
    static let maxCanonicalPCMBytes: Double = 120_000_000

    #if DEBUG
    nonisolated(unsafe) static var debugOnCancelReading: (@Sendable () -> Void)?
    #endif

    private static func notifyDebugCancellation() {
        #if DEBUG
        debugOnCancelReading?()
        #endif
    }

    static func materialise(
        remoteURL: URL,
        cacheKey: String,
        in directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let destination = cachedURL(for: cacheKey, in: directory)

        if FileManager.default.fileExists(atPath: destination.path),
           let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64,
           size > 0 {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            progress(1)
            return destination
        }

        progress(0.02)
        let downloaded: URL?
        if remoteURL.isFileURL {
            downloaded = nil
        } else {
            downloaded = try await download(remoteURL, into: directory)
        }
        defer {
            if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
        }

        try Task.checkCancellation()
        progress(0.30)

        let source = downloaded ?? remoteURL
        let media: URL
        var intermediate: URL?
        if isPlaylist(at: source) {
            let playlistText = try playlistText(at: source)
            let assembled = try await assembleHLS(
                playlistText: playlistText,
                playlistURL: remoteURL,
                directory: directory,
                depth: 0
            ) { fraction in
                progress(0.30 + fraction * 0.35)
            }
            intermediate = assembled
            media = assembled
        } else {
            media = try renamedWithSniffedExtension(source, in: directory) ?? source
            if media != source { intermediate = media }
        }
        defer { if let intermediate { try? FileManager.default.removeItem(at: intermediate) } }

        try Task.checkCancellation()
        progress(0.65)

        if try await shouldPreserveCompressed(media) {
            try installCompressed(media, at: destination)
            pruneCache(in: directory)
            progress(1)
            return destination
        }

        let scratch = directory.appendingPathComponent("import-\(UUID().uuidString).caf")
        do {
            try await transcode(localURL: media, to: scratch) { fraction in
                progress(0.65 + fraction * 0.35)
            }
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: scratch, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw MixEngineError.decodeFailed("Could not install decoded audio: \(error.localizedDescription)")
        }

        pruneCache(in: directory)
        progress(1)
        return destination
    }

    private static func shouldPreserveCompressed(_ localURL: URL) async throws -> Bool {
        let asset = AVURLAsset(url: localURL)
        let duration: TimeInterval
        do {
            let value = try await asset.load(.duration)
            duration = CMTimeGetSeconds(value)
        } catch {
            throw MixEngineError.unsupportedFormat(
                "AVFoundation could not inspect the downloaded audio (\(error.localizedDescription))"
            )
        }
        guard duration.isFinite, duration > 0 else { return false }
        let canonicalBytes = duration
            * DJEngineConstants.canonicalSampleRate
            * Double(DJEngineConstants.canonicalChannels)
            * Double(MemoryLayout<Float>.size)
        return canonicalBytes > maxCanonicalPCMBytes
    }

    private static func installCompressed(_ source: URL, at destination: URL) throws {
        do {
            let file = try AVAudioFile(forReading: source)
            guard file.length > 0 else {
                throw MixEngineError.decodeFailed("the compressed source contains no audio")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch let error as MixEngineError {
            throw error
        } catch {
            throw MixEngineError.decodeFailed(
                "Could not preserve the compressed audio: \(error.localizedDescription)"
            )
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    private static func download(_ url: URL, into directory: URL) async throws -> URL {
        try await SoundCloudGateway.shared.admitMediaURL(url)
        let (temporaryURL, response) = try await withHTTPErrors { try await session.download(from: url) }
        try validate(response)

        let owned = directory.appendingPathComponent("dl-\(UUID().uuidString)")
        do {
            try? FileManager.default.removeItem(at: owned)
            try FileManager.default.moveItem(at: temporaryURL, to: owned)
        } catch {
            throw MixEngineError.networkFailure("Could not stage the download: \(error.localizedDescription)")
        }
        return owned
    }

    private static func fetchData(_ url: URL) async throws -> Data {
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            let (data, response) = try await SoundCloudGateway.shared.data(
                for: request,
                context: .init(intent: .playback, lane: .media, allowsBackground: true)
            )
            try validate(response)
            return data
        } catch is CancellationError {
            throw MixEngineError.cancelled
        } catch {
            throw MixEngineError.networkFailure(error.localizedDescription)
        }
    }

    private static func withHTTPErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as MixEngineError {
            throw error
        } catch is CancellationError {
            throw MixEngineError.cancelled
        } catch {
            throw MixEngineError.networkFailure(error.localizedDescription)
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw MixEngineError.httpStatus(http.statusCode)
        }
    }

    private static func isPlaylist(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        guard let text = String(data: head, encoding: .utf8) else { return false }
        return text.hasPrefix("#EXTM3U")
    }

    private static func playlistText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MixEngineError.unsupportedFormat("playlist was not valid UTF-8")
        }
        return text
    }

    private final class FileWriter: @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()

        init(url: URL) throws {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw MixEngineError.decodeFailed("could not open a scratch file for HLS assembly")
            }
            self.handle = try FileHandle(forWritingTo: url)
        }

        func write(_ data: Data) throws {
            lock.lock()
            defer { lock.unlock() }
            try handle.write(contentsOf: data)
        }

        func synchronize() throws {
            lock.lock()
            defer { lock.unlock() }
            try handle.synchronize()
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            try? handle.close()
        }
    }

    private static func assembleHLS(
        playlistText: String,
        playlistURL: URL,
        directory: URL,
        depth: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard depth < maxPlaylistDepth else { throw MixEngineError.playlistTooDeep }

        let lines = playlistText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            guard let variant = bestVariant(in: lines, relativeTo: playlistURL) else {
                throw MixEngineError.emptyPlaylist
            }
            let data = try await fetchData(variant)
            guard let text = String(data: data, encoding: .utf8) else {
                throw MixEngineError.unsupportedFormat("variant playlist was not valid UTF-8")
            }
            return try await assembleHLS(
                playlistText: text,
                playlistURL: variant,
                directory: directory,
                depth: depth + 1,
                progress: progress
            )
        }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-KEY") && !$0.contains("METHOD=NONE") }) {
            throw MixEngineError.encryptedStream
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-BYTERANGE") }) {
            throw MixEngineError.byteRangeSegments
        }

        var initSegment: URL?
        if let mapLine = lines.first(where: { $0.hasPrefix("#EXT-X-MAP") }),
           let uri = attribute("URI", in: mapLine) {
            initSegment = URL(string: uri, relativeTo: playlistURL)?.absoluteURL
        }

        let segments: [URL] = lines
            .filter { !$0.hasPrefix("#") }
            .compactMap { URL(string: $0, relativeTo: playlistURL)?.absoluteURL }

        guard !segments.isEmpty else { throw MixEngineError.emptyPlaylist }

        // Fetch the init segment (if any) and the first media segment up front so we
        // can sniff the container and open the output file before the rest arrive.
        var head = Data()
        if let initSegment {
            head = try await fetchData(initSegment)
        }
        let firstSegmentData = try await fetchData(segments[0])

        let sniffTarget = head.isEmpty ? firstSegmentData : head
        guard let ext = containerExtension(for: sniffTarget) else {
            throw MixEngineError.unsupportedFormat(
                "the HLS segments are in a container AVFoundation cannot decode"
                    + (sniffTarget.starts(with: Array("OggS".utf8)) ? " (Ogg/Opus)" : "")
            )
        }

        let assembled = directory.appendingPathComponent("hls-\(UUID().uuidString).\(ext)")
        let writer = try FileWriter(url: assembled)
        defer { writer.close() }

        if !head.isEmpty { try writer.write(head) }
        try writer.write(firstSegmentData)

        let total = segments.count
        var completed = 1
        progress(Double(completed) / Double(total))

        guard total > 1 else {
            try writer.synchronize()
            return assembled
        }

        // Download the remaining segments concurrently with a window of 4, but write
        // each one to disk as soon as it is the next segment in order. A small
        // dictionary holds segments that finish out of order; it can never grow
        // larger than the in-flight window.
        var buffer: [Int: Data] = [:]
        var expectedWriteIndex = 1

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 1
            let window = min(4, total - 1)
            for _ in 0..<window {
                let index = next
                group.addTask { (index, try await fetchData(segments[index])) }
                next += 1
            }

            while let (index, data) = try await group.next() {
                completed += 1
                progress(Double(completed) / Double(total))

                if index == expectedWriteIndex {
                    try writer.write(data)
                    expectedWriteIndex += 1
                    while let buffered = buffer.removeValue(forKey: expectedWriteIndex) {
                        try writer.write(buffered)
                        expectedWriteIndex += 1
                    }
                } else {
                    buffer[index] = data
                }

                if next < total {
                    let index = next
                    group.addTask { (index, try await fetchData(segments[index])) }
                    next += 1
                }
            }
        }

        try writer.synchronize()
        return assembled
    }

    private static func bestVariant(in lines: [String], relativeTo base: URL) -> URL? {
        var best: (bandwidth: Int, url: URL)?
        var pendingBandwidth: Int?

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = attribute("BANDWIDTH", in: line).flatMap(Int.init) ?? 0
            } else if !line.hasPrefix("#"), let bandwidth = pendingBandwidth {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    if let current = best, bandwidth > current.bandwidth {
                        best = (bandwidth, url)
                    } else if best == nil {
                        best = (bandwidth, url)
                    }
                }
                pendingBandwidth = nil
            }
        }
        return best?.url
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)=") else { return nil }
        var value = String(line[range.upperBound...])
        if value.hasPrefix("\"") {
            value.removeFirst()
            if let end = value.firstIndex(of: "\"") {
                return String(value[value.startIndex..<end])
            }
            return nil
        }
        if let end = value.firstIndex(of: ",") {
            value = String(value[value.startIndex..<end])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func containerExtension(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 4 else { return nil }

        if bytes.starts(with: Array("OggS".utf8)) { return nil }        // Opus/Vorbis: no decoder
        if bytes.starts(with: Array("ID3".utf8)) { return "mp3" }
        if bytes.starts(with: Array("RIFF".utf8)) { return "wav" }
        if bytes.starts(with: Array("fLaC".utf8)) { return "flac" }
        if bytes.count >= 8, Array(bytes[4..<8]) == Array("ftyp".utf8) { return "mp4" }
        if bytes[0] == 0x47 { return "ts" }                             // MPEG-TS sync byte

        if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
            let layer = (bytes[1] >> 1) & 0x03
            return layer == 0 ? "aac" : "mp3"
        }
        return nil
    }

    private static func renamedWithSniffedExtension(_ url: URL, in directory: URL) throws -> URL? {
        guard url.pathExtension.isEmpty else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        try? handle.close()

        guard let ext = containerExtension(for: head) else {
            if head.starts(with: Array("OggS".utf8)) {
                throw MixEngineError.unsupportedFormat(
                    "Ogg/Opus — AVFoundation has no Opus decoder, so this transcoding cannot be mixed"
                )
            }
            return nil
        }

        let renamed = directory.appendingPathComponent("\(url.lastPathComponent).\(ext)")
        try? FileManager.default.removeItem(at: renamed)
        try FileManager.default.copyItem(at: url, to: renamed)
        return renamed
    }

    static func transcode(
        localURL: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: localURL)

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw MixEngineError.unsupportedFormat(
                "AVFoundation could not open the container (\(error.localizedDescription))"
            )
        }
        guard let track = tracks.first else {
            throw MixEngineError.unsupportedFormat("the file contains no audio track")
        }

        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0

        try await runTranscode(
            asset: asset,
            track: track,
            duration: duration.isFinite && duration > 0 ? duration : 0,
            destination: destination,
            progress: progress
        )
    }

    static func runTranscode(
        asset: AVURLAsset,
        track: AVAssetTrack,
        duration: TimeInterval,
        destination: URL,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let sampleRate = DJEngineConstants.canonicalSampleRate
        let channels = Int(DJEngineConstants.canonicalChannels)

        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MixEngineError.unsupportedFormat(
                "AVAssetReader cannot read this asset (\(error.localizedDescription))"
            )
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        let provider = reader.outputProvider(for: output)

        do {
            try reader.start()
        } catch {
            throw MixEngineError.decodeFailed(error.localizedDescription)
        }

        guard let writeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: DJEngineConstants.canonicalChannels,
            interleaved: true
        ) else {
            throw MixEngineError.decodeFailed("could not build the intermediate PCM format")
        }

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: destination,
                settings: fileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
        } catch {
            throw MixEngineError.decodeFailed("could not create the decoded file: \(error.localizedDescription)")
        }

        var wroteAnything = false

        while reader.status == .reading {
            guard !Task.isCancelled else {
                reader.cancelReading()
                notifyDebugCancellation()
                throw MixEngineError.cancelled
            }
            let nextBuffer: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?
            do {
                nextBuffer = try await provider.next()
            } catch {
                reader.cancelReading()
                notifyDebugCancellation()
                throw MixEngineError.decodeFailed(error.localizedDescription)
            }
            guard let readyBuffer = nextBuffer else { break }

            let wroteFrame: Bool
            do {
                wroteFrame = try readyBuffer.withUnsafeSampleBuffer { sampleBuffer -> Bool in
                    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
                          let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
                    else { return false }

                    guard asbd.mFormatID == kAudioFormatLinearPCM,
                          asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                          asbd.mBitsPerChannel == 32,
                          asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                    else {
                        throw MixEngineError.unexpectedDecodedFormat(
                            "expected interleaved float32, got formatID \(asbd.mFormatID) flags \(asbd.mFormatFlags)"
                        )
                    }
                    guard abs(asbd.mSampleRate - sampleRate) < 1 else {
                        throw MixEngineError.unexpectedDecodedFormat(
                            "expected \(Int(sampleRate)) Hz, got \(Int(asbd.mSampleRate)) Hz"
                        )
                    }

                    let decodedChannels = Int(asbd.mChannelsPerFrame)
                    guard decodedChannels == 1 || decodedChannels == 2 else {
                        throw MixEngineError.unexpectedDecodedFormat("\(decodedChannels)-channel audio is not supported")
                    }

                    let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                    let frameCount = byteCount / (MemoryLayout<Float>.size * decodedChannels)
                    guard frameCount > 0 else { return false }

                    var decoded = [Float](repeating: 0, count: frameCount * decodedChannels)
                    let copyStatus = decoded.withUnsafeMutableBytes { raw -> OSStatus in
                        guard let base = raw.baseAddress else { return -1 }
                        return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: base)
                    }
                    guard copyStatus == kCMBlockBufferNoErr else {
                        throw MixEngineError.decodeFailed("could not copy decoded samples out of the sample buffer")
                    }

                    guard let buffer = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: AVAudioFrameCount(frameCount)),
                          let target = buffer.floatChannelData?[0] else {
                        throw MixEngineError.decodeFailed("could not allocate a PCM buffer")
                    }
                    buffer.frameLength = AVAudioFrameCount(frameCount)

                    if decodedChannels == 2 {
                        decoded.withUnsafeBufferPointer { source in
                            target.update(from: source.baseAddress!, count: frameCount * 2)
                        }
                    } else {
                        decoded.withUnsafeBufferPointer { source in
                            guard let base = source.baseAddress else { return }
                            for frame in 0..<frameCount {
                                target[frame * 2] = base[frame]
                                target[frame * 2 + 1] = base[frame]
                            }
                        }
                    }

                    do {
                        try outputFile.write(from: buffer)
                    } catch {
                        throw MixEngineError.decodeFailed("write failed: \(error.localizedDescription)")
                    }

                    if duration > 0 {
                        let presentation = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                        if presentation.isFinite {
                            progress(min(1, max(0, presentation / duration)))
                        }
                    }

                    return true
                }
            } catch {
                reader.cancelReading()
                notifyDebugCancellation()
                throw error
            }

            if wroteFrame { wroteAnything = true }
        }

        if reader.status == .failed {
            throw MixEngineError.decodeFailed(reader.error?.localizedDescription ?? "decoding failed")
        }
        guard wroteAnything else {
            throw MixEngineError.decodeFailed("the decoder produced no audio")
        }
        progress(1)
    }

    static func hasCachedSource(cacheKey: String, in directory: URL) -> Bool {
        let path = cachedURL(for: cacheKey, in: directory).path
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 else { return false }
        return size > 0
    }

    static func cachedURL(for key: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).caf")
    }

    static func clearCache(in directory: URL) {
        for entry in cacheEntries(in: directory) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    static func pruneCache(in directory: URL) {
        sweepScratchFiles(in: directory)

        protectedKeysLock.lock()
        let protected = protectedKeys
        protectedKeysLock.unlock()

        var entries = cacheEntries(in: directory).sorted { $0.modified > $1.modified }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }

        while entries.count > maxCacheFiles || total > maxCacheBytes {
            guard let index = entries.lastIndex(where: { !protected.contains($0.url.lastPathComponent) }) else { break }
            let oldest = entries.remove(at: index)
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
    }

    private static func sweepScratchFiles(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-3600)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in contents where url.pathExtension != "caf" {
            let name = url.lastPathComponent
            guard name.hasPrefix("dl-") || name.hasPrefix("hls-") else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func cacheEntries(in directory: URL) -> [(url: URL, size: Int64, modified: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.compactMap { url in
            guard url.pathExtension == "caf" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (
                url,
                Int64(values?.fileSize ?? 0),
                values?.contentModificationDate ?? .distantPast
            )
        }
    }
}

// MARK: - Windows

extension SourceImporter {
    struct HLSWindowIndex: Sendable {
        struct Segment: Sendable {
            let url: URL
            let start: TimeInterval
            let duration: TimeInterval
        }

        let initSegment: URL?
        let segments: [Segment]

        var duration: TimeInterval { segments.last.map { $0.start + $0.duration } ?? 0 }

        func segments(covering start: TimeInterval, duration: TimeInterval) -> [Segment] {
            let end = start + duration
            return segments.filter { $0.start < end && $0.start + $0.duration > start }
        }
    }

    static func hlsWindowIndex(remoteURL: URL) async throws -> HLSWindowIndex? {
        try await hlsWindowIndex(playlistURL: remoteURL, depth: 0)
    }

    private static func hlsWindowIndex(playlistURL: URL, depth: Int) async throws -> HLSWindowIndex? {
        guard depth < maxPlaylistDepth else { throw MixEngineError.playlistTooDeep }
        let data = try await fetchData(playlistURL)
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { return nil }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            guard let variant = bestVariant(in: lines, relativeTo: playlistURL) else {
                throw MixEngineError.emptyPlaylist
            }
            return try await hlsWindowIndex(playlistURL: variant, depth: depth + 1)
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-KEY") && !$0.contains("METHOD=NONE") }) {
            throw MixEngineError.encryptedStream
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-BYTERANGE") }) {
            throw MixEngineError.byteRangeSegments
        }

        var initSegment: URL?
        if let mapLine = lines.first(where: { $0.hasPrefix("#EXT-X-MAP") }),
           let uri = attribute("URI", in: mapLine) {
            initSegment = URL(string: uri, relativeTo: playlistURL)?.absoluteURL
        }

        var segments: [HLSWindowIndex.Segment] = []
        var pendingDuration: TimeInterval?
        var cursor: TimeInterval = 0
        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init) ?? ""
                pendingDuration = TimeInterval(value.trimmingCharacters(in: .whitespaces))
            } else if !line.hasPrefix("#"), let url = URL(string: line, relativeTo: playlistURL)?.absoluteURL {
                let duration = max(0, pendingDuration ?? 0)
                segments.append(.init(url: url, start: cursor, duration: duration))
                cursor += duration
                pendingDuration = nil
            }
        }
        guard !segments.isEmpty else { throw MixEngineError.emptyPlaylist }
        return HLSWindowIndex(initSegment: initSegment, segments: segments)
    }

    static func materialiseWindow(
        _ index: HLSWindowIndex,
        start: TimeInterval,
        duration: TimeInterval,
        in directory: URL
    ) async throws -> (url: URL, startSeconds: TimeInterval) {
        let covering = index.segments(covering: max(0, start), duration: duration)
        guard let first = covering.first else { throw MixEngineError.emptyPlaylist }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var payload = Data()
        if let initSegment = index.initSegment { payload.append(try await fetchData(initSegment)) }
        for segment in covering {
            try Task.checkCancellation()
            payload.append(try await fetchData(segment.url))
        }
        guard let ext = containerExtension(for: payload) else {
            throw MixEngineError.unsupportedFormat("the stream is in a container AVFoundation cannot decode")
        }

        let assembled = directory.appendingPathComponent("window-\(UUID().uuidString).\(ext)")
        try payload.write(to: assembled, options: .atomic)
        if (try? AVAudioFile(forReading: assembled)) != nil {
            return (assembled, first.start)
        }

        let decoded = directory.appendingPathComponent("window-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: assembled) }
        do {
            try await transcode(localURL: assembled, to: decoded) { _ in }
        } catch {
            try? FileManager.default.removeItem(at: decoded)
            throw error
        }
        return (decoded, first.start)
    }
}
