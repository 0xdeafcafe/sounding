import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

#if DEBUG
enum SCArtworkMetrics {
    static let enabled = ProcessInfo.processInfo.environment["SOUNDING_TV_ARTMETRICS"] == "1"
    private static let started = Date()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counters: [String: Int] = [:]

    static func event(_ kind: String, _ detail: @autoclosure () -> String) {
        guard enabled else { return }
        lock.lock()
        let count = (counters[kind] ?? 0) + 1
        counters[kind] = count
        let elapsed = Date().timeIntervalSince(started)
        lock.unlock()
        print(String(format: "[ArtMetrics] +%.3fs %@ n=%d %@", elapsed, kind, count, detail()))
    }
}
#endif

final class SCArtworkMemoryCache: @unchecked Sendable {
    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    static let defaultCostLimit: Int = {
        let megabyte = 1024 * 1024
        #if os(watchOS)
        return 16 * megabyte
        #else
        let share = Int(clamping: ProcessInfo.processInfo.physicalMemory / 32)
        #if os(macOS)
        return min(max(share, 128 * megabyte), 384 * megabyte)
        #elseif os(tvOS)
        return min(max(share, 64 * megabyte), 128 * megabyte)
        #else
        return min(max(share, 64 * megabyte), 192 * megabyte)
        #endif
        #endif
    }()

    static let defaultCountLimit: Int = {
        #if os(watchOS)
        return 200
        #else
        return 1500
        #endif
    }()

    private let cache = NSCache<NSString, Entry>()

    init(costLimit: Int = SCArtworkMemoryCache.defaultCostLimit, countLimit: Int = SCArtworkMemoryCache.defaultCountLimit) {
        cache.totalCostLimit = costLimit
        cache.countLimit = countLimit
    }

    func image(forKey key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func insert(_ image: CGImage, forKey key: String) {
        cache.setObject(Entry(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

actor SCArtworkStore {
    static let shared = SCArtworkStore()

    static let maxDiskBytes: Int64 = {
        #if os(watchOS)
        return 32_000_000
        #elseif os(tvOS)
        return 128_000_000
        #elseif os(macOS)
        return 512_000_000
        #else
        return 256_000_000
        #endif
    }()
    static let evictionTargetBytes: Int64 = maxDiskBytes / 4 * 3
    static let negativeRetryInterval: TimeInterval = 600
    static let maxConcurrentPrefetches = 3
    static let maxQueuedPrefetches = 48
    static let formatVersion = 2
    private static let sweepWriteInterval: Int64 = maxDiskBytes / 16

    private struct Flight {
        let token: UUID
        let task: Task<CGImage?, Never>
        var interest: Int
    }

    private struct PrefetchJob: Sendable {
        let key: String
        let url: URL
        let variant: ArtworkVariant
    }

    private struct DerivationSource: Sendable {
        let key: String
        let file: URL
    }

    let memory = SCArtworkMemoryCache()

    private let directory: URL
    private let session: URLSession
    private var flights: [String: Flight] = [:]
    private var negativeUntil: [String: Date] = [:]
    private var bytesWrittenSinceSweep: Int64 = 0
    private var didInitialSweep = false
    private var sweepRunning = false
    private var activePrefetches = 0
    private var prefetchQueue: [PrefetchJob] = []

    init(directory: URL? = nil) {
        let base = FileManager.default.soundingDirectory(.cachesDirectory)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let resolved = directory ?? base.appendingPathComponent("Artwork", isDirectory: true)
        self.directory = resolved
        Self.prepareDirectory(resolved)

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    nonisolated static func storageKey(for url: URL, variant: ArtworkVariant) -> String {
        storageKey(identity: url.soundCloudArtworkIdentity, variant: variant)
    }

    nonisolated static func storageKey(identity: String, variant: ArtworkVariant) -> String {
        identity + "#" + variant.diskTag
    }

    nonisolated func cachedImage(for url: URL, variant: ArtworkVariant) -> CGImage? {
        memory.image(forKey: Self.storageKey(for: url, variant: variant))
    }

    nonisolated func cachedImage(forKey key: String) -> CGImage? {
        memory.image(forKey: key)
    }

    nonisolated func insertIntoMemory(_ image: CGImage, forKey key: String) {
        memory.insert(image, forKey: key)
    }

    nonisolated func purgeMemory() {
        memory.removeAll()
    }

    func cgImage(for url: URL, variant: ArtworkVariant) async -> CGImage? {
        await load(url: url, variant: variant, priority: .userInitiated)
    }

    func prefetchImage(for url: URL, variant: ArtworkVariant) async -> CGImage? {
        let key = Self.storageKey(for: url, variant: variant)
        if let hit = memory.image(forKey: key) { return hit }
        if flights[key] == nil {
            while activePrefetches >= Self.maxConcurrentPrefetches {
                if Task.isCancelled { return nil }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        if Task.isCancelled { return nil }
        activePrefetches += 1
        defer {
            activePrefetches -= 1
            pumpPrefetches()
        }
        return await load(url: url, variant: variant, priority: .utility)
    }

    nonisolated func prefetch(_ urls: [URL], variant: ArtworkVariant) {
        let jobs = urls.compactMap { url -> PrefetchJob? in
            let key = Self.storageKey(for: url, variant: variant)
            guard memory.image(forKey: key) == nil else { return nil }
            return PrefetchJob(key: key, url: url, variant: variant)
        }
        guard !jobs.isEmpty else { return }
        Task(priority: .utility) { await self.enqueuePrefetches(jobs) }
    }

    nonisolated func cancelPrefetch(_ urls: [URL], variant: ArtworkVariant) {
        let keys = Set(urls.map { Self.storageKey(for: $0, variant: variant) })
        guard !keys.isEmpty else { return }
        Task(priority: .utility) { await self.dropQueuedPrefetches(keys) }
    }

    private func enqueuePrefetches(_ jobs: [PrefetchJob]) {
        let incoming = Set(jobs.map(\.key))
        prefetchQueue.removeAll { incoming.contains($0.key) }
        prefetchQueue.append(contentsOf: jobs.reversed())
        if prefetchQueue.count > Self.maxQueuedPrefetches {
            prefetchQueue.removeFirst(prefetchQueue.count - Self.maxQueuedPrefetches)
        }
        pumpPrefetches()
    }

    private func dropQueuedPrefetches(_ keys: Set<String>) {
        prefetchQueue.removeAll { keys.contains($0.key) }
    }

    private func pumpPrefetches() {
        while activePrefetches < Self.maxConcurrentPrefetches, let job = prefetchQueue.popLast() {
            if memory.image(forKey: job.key) != nil || flights[job.key] != nil { continue }
            if let until = negativeUntil[job.key], until > Date() { continue }
            activePrefetches += 1
            Task(priority: .utility) {
                _ = await self.load(url: job.url, variant: job.variant, priority: .utility)
                self.prefetchFinished()
            }
        }
    }

    private func prefetchFinished() {
        activePrefetches -= 1
        pumpPrefetches()
    }

    func removeAll() {
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
        negativeUntil.removeAll()
        memory.removeAll()
        try? FileManager.default.removeItem(at: directory)
        Self.prepareDirectory(directory)
    }

    private func load(url: URL, variant: ArtworkVariant, priority: TaskPriority) async -> CGImage? {
        let key = Self.storageKey(for: url, variant: variant)

        if let hit = memory.image(forKey: key) {
            #if DEBUG
            SCArtworkMetrics.event("MEM", key)
            #endif
            return hit
        }

        if let until = negativeUntil[key] {
            if until > Date() {
                #if DEBUG
                SCArtworkMetrics.event("NEG", key)
                #endif
                return nil
            }
            negativeUntil[key] = nil
        }

        if var flight = flights[key] {
            flight.interest += 1
            flights[key] = flight
            return await join(key, flight)
        }

        if !didInitialSweep {
            didInitialSweep = true
            if Self.initialSweepIsDue(for: directory) {
                scheduleSweep()
            }
        }

        let file = fileURL(forKey: key)
        let identity = url.soundCloudArtworkIdentity
        let sources = variant.derivationSources.map { source -> DerivationSource in
            let sourceKey = Self.storageKey(identity: identity, variant: source)
            return DerivationSource(key: sourceKey, file: fileURL(forKey: sourceKey))
        }
        let candidates = variant.requestURLs(for: url)
        let maxPixel = variant.maxPixelSize
        let token = UUID()
        let task = Task.detached(priority: priority) { () -> CGImage? in
            let result = await self.produce(
                key: key, file: file, sources: sources, candidates: candidates, maxPixel: maxPixel
            )
            await self.completeFlight(key, token: token)
            return result
        }
        let flight = Flight(token: token, task: task, interest: 1)
        flights[key] = flight
        return await join(key, flight)
    }

    private nonisolated func produce(
        key: String, file: URL, sources: [DerivationSource], candidates: [URL], maxPixel: Int
    ) async -> CGImage? {
        if let local = candidates.first, local.isFileURL {
            guard let data = try? Data(contentsOf: local), let image = Self.decode(data, maxPixelSize: maxPixel) else { return nil }
            return remember(Self.displayReady(image), forKey: key)
        }

        if let data = Self.readDisk(at: file) {
            #if DEBUG
            SCArtworkMetrics.event("DISK", "bytes=\(data.count) \(key)")
            #endif
            if let image = Self.decode(data, maxPixelSize: maxPixel) {
                return remember(Self.displayReady(image), forKey: key)
            }
            try? FileManager.default.removeItem(at: file)
        }

        for source in sources {
            guard let larger = memory.image(forKey: source.key),
                  let image = Self.downscale(larger, maxPixelSize: maxPixel) else { continue }
            #if DEBUG
            SCArtworkMetrics.event("DERIVE", "from=memory \(key)")
            #endif
            persist(image, fallback: nil, to: file)
            return remember(image, forKey: key)
        }

        for source in sources {
            guard let data = Self.readDisk(at: source.file),
                  let image = Self.decode(data, maxPixelSize: maxPixel) else { continue }
            #if DEBUG
            SCArtworkMetrics.event("DERIVE", "from=\(source.file.lastPathComponent.prefix(12)) \(key)")
            #endif
            persist(image, fallback: nil, to: file)
            return remember(Self.displayReady(image), forKey: key)
        }

        var attempted = Set<URL>()
        for candidate in candidates {
            guard attempted.insert(candidate).inserted else { continue }
            if Task.isCancelled { return nil }
            #if DEBUG
            SoundCloudRequestLedger.shared.record(
                URLRequest(url: candidate), lane: "artwork", intent: "display",
                outcome: "wire", caller: "SCArtworkStore.\(maxPixel)px"
            )
            if SoundCloudMockService.isEnabled { continue }
            #endif
            guard let (data, response) = try? await session.loggedData(from: candidate, feature: .artwork) else { continue }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                continue
            }
            guard let image = Self.decode(data, maxPixelSize: maxPixel) else { continue }
            #if DEBUG
            SCArtworkMetrics.event("NET", "bytes=\(data.count) \(candidate.absoluteString)")
            #endif
            persist(image, fallback: data, to: file)
            return remember(Self.displayReady(image), forKey: key)
        }

        if !Task.isCancelled {
            await self.noteFailure(key)
        }
        return nil
    }

    private nonisolated func remember(_ image: CGImage, forKey key: String) -> CGImage {
        memory.insert(image, forKey: key)
        return image
    }

    private static let persistQueue = DispatchQueue(label: "SCArtworkStore.persist", qos: .utility)

    private nonisolated func persist(_ image: CGImage, fallback: Data?, to file: URL) {
        Self.persistQueue.async {
            guard let stored = Self.encode(image) ?? fallback else { return }
            Self.writeDisk(stored, to: file)
            Task { await self.noteWrite(Int64(stored.count)) }
        }
    }

    private func join(_ key: String, _ flight: Flight) async -> CGImage? {
        let token = flight.token
        let task = flight.task
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.releaseInterest(key, token: token) }
        }
    }

    private func releaseInterest(_ key: String, token: UUID) {
        guard var flight = flights[key], flight.token == token else { return }
        flight.interest -= 1
        if flight.interest <= 0 {
            flight.task.cancel()
            flights[key] = nil
        } else {
            flights[key] = flight
        }
    }

    private func completeFlight(_ key: String, token: UUID) {
        guard flights[key]?.token == token else { return }
        flights[key] = nil
    }

    private func noteWrite(_ bytes: Int64) {
        bytesWrittenSinceSweep += bytes
        if bytesWrittenSinceSweep >= Self.sweepWriteInterval {
            scheduleSweep()
        }
    }

    private func noteFailure(_ key: String) {
        if negativeUntil.count > 512 {
            let now = Date()
            negativeUntil = negativeUntil.filter { $0.value > now }
        }
        negativeUntil[key] = Date().addingTimeInterval(Self.negativeRetryInterval)
        #if DEBUG
        SCArtworkMetrics.event("FAIL", key)
        #endif
    }

    private func scheduleSweep() {
        guard !sweepRunning else { return }
        sweepRunning = true
        bytesWrittenSinceSweep = 0
        Task.detached(priority: .background) {
            Self.removeLegacyDirectories(besides: self.directory)
            Self.sweep(
                directory: self.directory,
                maxBytes: Self.maxDiskBytes,
                targetBytes: Self.evictionTargetBytes
            )
            await self.sweepFinished()
        }
    }

    private func sweepFinished() {
        sweepRunning = false
        UserDefaults.sounding.set(Date(), forKey: Self.sweepDefaultsKey(for: directory))
    }

    private static let initialSweepInterval: TimeInterval = 24 * 60 * 60

    private static func sweepDefaultsKey(for directory: URL) -> String {
        "SCArtworkStore.lastSweep." + directory.path
    }

    private static func initialSweepIsDue(for directory: URL) -> Bool {
        guard let last = UserDefaults.sounding.object(forKey: sweepDefaultsKey(for: directory)) as? Date else {
            return true
        }
        return Date().timeIntervalSince(last) >= initialSweepInterval
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(Self.digest(of: key), isDirectory: false)
    }

    private nonisolated static func formatMarker(in directory: URL) -> URL {
        directory.appendingPathComponent(".format-\(formatVersion)", isDirectory: false)
    }

    private nonisolated static func legacyPrefix(for directory: URL) -> String {
        directory.lastPathComponent + ".legacy-"
    }

    nonisolated static func prepareDirectory(_ directory: URL) {
        let fm = FileManager.default
        let marker = formatMarker(in: directory)
        if fm.fileExists(atPath: marker.path) { return }
        if fm.fileExists(atPath: directory.path) {
            let legacy = directory.deletingLastPathComponent()
                .appendingPathComponent(legacyPrefix(for: directory) + UUID().uuidString, isDirectory: true)
            if (try? fm.moveItem(at: directory, to: legacy)) != nil {
                Task.detached(priority: .background) {
                    try? FileManager.default.removeItem(at: legacy)
                }
            } else {
                try? fm.removeItem(at: directory)
            }
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        fm.createFile(atPath: marker.path, contents: Data())
    }

    nonisolated static func removeLegacyDirectories(besides directory: URL) {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        let prefix = legacyPrefix(for: directory)
        guard let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            try? fm.removeItem(at: parent.appendingPathComponent(name, isDirectory: true))
        }
    }

    // MARK: Codec

    nonisolated static func digest(of key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func readDisk(at file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file.path
        )
        return data
    }

    nonisolated static func writeDisk(_ data: Data, to file: URL) {
        try? data.write(to: file, options: .atomic)
    }

    nonisolated static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return ImageThumbnail.create(from: source, maxPixelSize: maxPixelSize, cacheImmediately: true)
    }

    nonisolated static func downscale(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize else { return image }
        let ratio = Double(maxPixelSize) / Double(longest)
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        let opaque = !hasAlpha(image)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | (opaque ? CGImageAlphaInfo.noneSkipFirst.rawValue : CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: bitmapInfo
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    nonisolated static func displayReady(_ image: CGImage) -> CGImage {
        #if os(iOS) || os(tvOS) || os(visionOS)
        return UIImage(cgImage: image).preparingForDisplay()?.cgImage ?? image
        #else
        return image
        #endif
    }

    private static let heicType = "public.heic"
    private static let jpegType = "public.jpeg"
    private static let pngType = "public.png"

    private static let canEncodeHEIC: Bool = {
        let types = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return types.contains(heicType)
    }()

    nonisolated static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    nonisolated static func encode(_ image: CGImage) -> Data? {
        let formats: [(type: String, quality: Double?)]
        if hasAlpha(image) {
            formats = [(pngType, nil)]
        } else if canEncodeHEIC {
            formats = [(heicType, 0.72), (jpegType, 0.8)]
        } else {
            formats = [(jpegType, 0.8)]
        }
        for format in formats {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, format.type as CFString, 1, nil
            ) else { continue }
            var properties: [CFString: Any] = [:]
            if let quality = format.quality {
                properties[kCGImageDestinationLossyCompressionQuality] = quality
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination), output.length > 0 else { continue }
            return output as Data
        }
        return nil
    }

    nonisolated static func sweep(directory: URL, maxBytes: Int64, targetBytes: Int64) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
        ) else { return }

        var entries: [DownloadBudgetPolicy.Entry] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            entries.append(.init(
                id: url.lastPathComponent,
                bytes: Int64(values.fileSize ?? 0),
                lastPlayedAt: values.contentModificationDate ?? .distantPast,
                isPinned: false
            ))
        }

        let total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > maxBytes else { return }
        for victim in DownloadBudgetPolicy.victims(entries: entries, maxBytes: targetBytes) {
            try? fm.removeItem(at: directory.appendingPathComponent(victim))
        }
        #if DEBUG
        SCArtworkMetrics.event("SWEEP", "total=\(total) victims evicted to \(targetBytes)")
        #endif
    }
}
