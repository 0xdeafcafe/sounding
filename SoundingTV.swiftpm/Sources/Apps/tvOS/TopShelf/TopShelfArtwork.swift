import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum TopShelfArtwork {
    static let pixelSide = 800

    private static var task: Task<Void, Never>?
    private static var isPending = false
    private static var failed = Set<String>()

    nonisolated static func fileName(for remote: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in remote.soundCloudArtworkIdentity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16) + ".jpg"
    }

    nonisolated static func isRemote(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    nonisolated static func localURL(for remote: URL?) -> URL? {
        guard let remote, isRemote(remote),
              let directory = TopShelfStore.artworkDirectoryURL else { return nil }
        let url = directory.appendingPathComponent(fileName(for: remote))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func sync() {
        isPending = true
        guard task == nil else { return }
        task = Task { await drain() }
    }

    static func removeAll() {
        task?.cancel()
        task = nil
        isPending = false
        failed.removeAll()
        guard let directory = TopShelfStore.artworkDirectoryURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func drain() async {
        while isPending, !Task.isCancelled {
            isPending = false
            await localiseCurrentSnapshot()
        }
        task = nil
    }

    private static func localiseCurrentSnapshot() async {
        guard let directory = TopShelfStore.artworkDirectoryURL,
              let snapshot = TopShelfStore.load(), snapshot.isSignedIn else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var seen = Set<String>()
        let remotes = snapshot.sections
            .flatMap(\.entries)
            .compactMap { $0.artworkURL }
            .filter { isRemote($0) && seen.insert(fileName(for: $0)).inserted }

        for remote in remotes where !Task.isCancelled {
            let name = fileName(for: remote)
            guard localURL(for: remote) == nil, !failed.contains(name) else { continue }
            guard let image = await SCArtworkStore.shared.prefetchImage(for: remote, variant: .hero) else {
                failed.insert(name)
                continue
            }
            let side = pixelSide
            let data = await Task.detached(priority: .utility) { TopShelfArtwork.jpeg(from: image, side: side) }.value
            guard let data, (try? data.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil else {
                failed.insert(name)
                continue
            }
        }
        guard !Task.isCancelled else { return }
        TopShelfPublisher.adoptLocalArtwork()
        prune(keeping: referencedFileNames(), in: directory)
    }

    private static func referencedFileNames() -> Set<String> {
        let entries = TopShelfStore.load()?.sections.flatMap(\.entries) ?? []
        var names = Set<String>()
        for entry in entries {
            for url in [entry.artworkURL, entry.artworkURL2x].compactMap({ $0 }) {
                if url.isFileURL {
                    names.insert(url.lastPathComponent)
                } else if isRemote(url) {
                    names.insert(fileName(for: url))
                }
            }
        }
        return names
    }

    private static func prune(keeping names: Set<String>, in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    nonisolated static func jpeg(from image: CGImage, side: Int) -> Data? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }
        let target = min(side, max(image.width, image.height))
        guard let context = CGContext(
            data: nil,
            width: target,
            height: target,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let factor = max(CGFloat(target) / width, CGFloat(target) / height)
        let drawn = CGSize(width: width * factor, height: height * factor)
        context.draw(image, in: CGRect(
            x: (CGFloat(target) - drawn.width) / 2,
            y: (CGFloat(target) - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
