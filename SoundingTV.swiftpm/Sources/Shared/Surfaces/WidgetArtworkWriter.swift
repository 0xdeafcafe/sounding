import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class WidgetArtworkWriter {
    static let shared = WidgetArtworkWriter()

    private var task: Task<Void, Never>?
    private var pending: SoundingSnapshot?
    private var skipped = Set<String>()
    private var onWritten: (@MainActor () -> Void)?

    func sync(_ snapshot: SoundingSnapshot, onWritten: @escaping @MainActor () -> Void) {
        self.onWritten = onWritten
        pending = snapshot
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.drain()
        }
    }

    func reset() {
        task?.cancel()
        pending = nil
        skipped.removeAll()
        WidgetArtworkStore.removeAll()
    }

    private func drain() async {
        var wrote = false
        while let snapshot = pending, !Task.isCancelled {
            pending = nil
            let items = Self.items(in: snapshot)
            WidgetArtworkStore.prune(keeping: Set(items.map(WidgetArtworkStore.fileName(for:))))
            for item in items where !WidgetArtworkStore.exists(for: item) {
                let key = WidgetArtworkStore.fileName(for: item)
                guard !skipped.contains(key), let url = item.artworkURL else { continue }
                guard let source = await SCArtworkStore.shared.cgImage(for: url, variant: .thumbnail),
                      let data = Self.jpeg(from: source, side: WidgetArtworkStore.pixelSize),
                      WidgetArtworkStore.write(data, for: item) else {
                    skipped.insert(key)
                    continue
                }
                wrote = true
            }
        }
        task = nil
        if wrote { onWritten?() }
        if pending != nil {
            task = Task { [weak self] in
                await self?.drain()
            }
        }
    }

    static func items(in snapshot: SoundingSnapshot) -> [SoundingSnapshot.Item] {
        var items: [SoundingSnapshot.Item] = []
        if let nowPlaying = snapshot.nowPlaying { items.append(nowPlaying.item) }
        if let lastMix = snapshot.lastMix { items.append(lastMix.item) }
        items.append(contentsOf: snapshot.recents)
        items.append(contentsOf: WidgetCollectionStore.load().map(\.artworkItem))
        var seen = Set<String>()
        return items.filter { seen.insert(WidgetArtworkStore.fileName(for: $0)).inserted }
    }

    nonisolated static func jpeg(from image: CGImage, side: Int) -> Data? {
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let factor = max(CGFloat(side) / width, CGFloat(side) / height)
        let drawn = CGSize(width: width * factor, height: height * factor)
        context.draw(image, in: CGRect(
            x: (CGFloat(side) - drawn.width) / 2,
            y: (CGFloat(side) - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
