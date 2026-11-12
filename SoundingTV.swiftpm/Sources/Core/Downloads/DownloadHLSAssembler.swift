import CryptoKit
import Foundation
import Network

enum DownloadHLSAssembler {
    static let maxPlaylistDepth = 3

    static func assemble(
        playlistURL: URL,
        scratchDirectory: URL,
        trackId: String,
        sealingWith key: SymmetricKey? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let data = try await fetchData(playlistURL)
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
            throw DownloadError.emptyPlaylist
        }
        return try await assemble(
            playlistText: text,
            playlistURL: playlistURL,
            directory: scratchDirectory,
            trackId: trackId,
            key: key,
            depth: 0,
            progress: progress
        )
    }

    private final class FileWriter: @unchecked Sendable {
        private let handle: FileHandle?
        private let sealer: DownloadVault.SealingWriter?
        private let lock = NSLock()

        init(url: URL, sealingWith key: SymmetricKey?) throws {
            if let key {
                sealer = try DownloadVault.SealingWriter(url: url, key: key)
                handle = nil
                return
            }
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw DownloadError.unsupportedContainer
            }
            sealer = nil
            handle = try FileHandle(forWritingTo: url)
        }

        func write(_ data: Data) throws {
            lock.lock()
            defer { lock.unlock() }
            if let sealer {
                try sealer.append(data)
            } else {
                try handle?.write(contentsOf: data)
            }
        }

        func synchronize() throws {
            lock.lock()
            defer { lock.unlock() }
            if let sealer {
                try sealer.finish()
            } else {
                try handle?.synchronize()
            }
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            sealer?.close()
            try? handle?.close()
        }
    }

    private static func assemble(
        playlistText: String,
        playlistURL: URL,
        directory: URL,
        trackId: String,
        key: SymmetricKey?,
        depth: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard depth < maxPlaylistDepth else { throw DownloadError.playlistTooDeep }

        let lines = playlistText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            guard let variant = bestVariant(in: lines, relativeTo: playlistURL) else {
                throw DownloadError.emptyPlaylist
            }
            let data = try await fetchData(variant)
            guard let text = String(data: data, encoding: .utf8) else { throw DownloadError.emptyPlaylist }
            return try await assemble(
                playlistText: text,
                playlistURL: variant,
                directory: directory,
                trackId: trackId,
                key: key,
                depth: depth + 1,
                progress: progress
            )
        }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-KEY") && !$0.contains("METHOD=NONE") }) {
            throw DownloadError.encryptedStream
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-BYTERANGE") }) {
            throw DownloadError.byteRangeSegments
        }

        var initSegment: URL?
        if let mapLine = lines.first(where: { $0.hasPrefix("#EXT-X-MAP") }), let uri = attribute("URI", in: mapLine) {
            initSegment = URL(string: uri, relativeTo: playlistURL)?.absoluteURL
        }

        let segments: [URL] = lines
            .filter { !$0.hasPrefix("#") }
            .compactMap { URL(string: $0, relativeTo: playlistURL)?.absoluteURL }
        guard !segments.isEmpty else { throw DownloadError.emptyPlaylist }

        // Fetch the init segment (if any) and the first media segment up front so we
        // can sniff the container and open the output file before the rest arrive.
        var head = Data()
        if let initSegment { head = try await fetchData(initSegment) }
        let firstSegmentData = try await fetchData(segments[0])

        let sniffTarget = head.isEmpty ? firstSegmentData : head
        guard let ext = containerExtension(for: sniffTarget) else { throw DownloadError.unsupportedContainer }

        let assembled = directory.appendingPathComponent("\(trackId)-assembled-\(UUID().uuidString).\(ext)")
        let writer = try FileWriter(url: assembled, sealingWith: key)
        var completedSuccessfully = false
        defer {
            writer.close()
            if !completedSuccessfully {
                try? FileManager.default.removeItem(at: assembled)
            }
        }

        if !head.isEmpty { try writer.write(head) }
        try writer.write(firstSegmentData)

        let total = segments.count
        var completed = 1
        progress(Double(completed) / Double(total))

        guard total > 1 else {
            try writer.synchronize()
            completedSuccessfully = true
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
        completedSuccessfully = true
        return assembled
    }

    private static func fetchData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await SoundCloudGateway.shared.data(
            for: request,
            context: .init(intent: .playback, lane: .media, allowsBackground: true)
        )
        guard (200..<300).contains(response.statusCode) else {
            throw DownloadError.streamResolutionFailed
        }
        return data
    }

    private static func bestVariant(in lines: [String], relativeTo base: URL) -> URL? {
        var best: (bandwidth: Int, url: URL)?
        var pendingBandwidth: Int?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = attribute("BANDWIDTH", in: line).flatMap(Int.init) ?? 0
            } else if !line.hasPrefix("#"), let bandwidth = pendingBandwidth {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    if best == nil || bandwidth > best!.bandwidth { best = (bandwidth, url) }
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
            if let end = value.firstIndex(of: "\"") { return String(value[value.startIndex..<end]) }
            return nil
        }
        if let end = value.firstIndex(of: ",") { value = String(value[value.startIndex..<end]) }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func containerExtension(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 4 else { return nil }
        if bytes.starts(with: Array("OggS".utf8)) { return nil }
        if bytes.starts(with: Array("ID3".utf8)) { return "mp3" }
        if bytes.count >= 8, Array(bytes[4..<8]) == Array("ftyp".utf8) { return "m4a" }
        if bytes[0] == 0x47 { return "ts" }
        if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
            let layer = (bytes[1] >> 1) & 0x03
            return layer == 0 ? "aac" : "mp3"
        }
        return nil
    }
}
