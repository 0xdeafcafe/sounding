import Foundation
import CoreGraphics
import CryptoKit
import ImageIO

extension ArtworkVariant {
    var maxDecodedPixelSize: Int {
        switch self {
        case .standard: return 800
        case .hero, .signed: return 2160
        }
    }
}

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

actor SCArtworkStore {
    static let shared = SCArtworkStore()

    static let maxDiskBytes: Int64 = 256_000_000
    static let evictionTargetBytes: Int64 = 192_000_000
    static let negativeRetryInterval: TimeInterval = 600
    static let maxConcurrentPrefetches = 3
    private static let sweepWriteInterval: Int64 = 16_000_000

    private struct Flight {
        let token: UUID
        let task: Task<CGImage?, Never>
        var interest: Int
    }

    private let directory: URL
    private let session: URLSession
    private var flights: [String: Flight] = [:]
    private var negativeUntil: [String: Date] = [:]
    private var bytesWrittenSinceSweep: Int64 = 0
    private var didInitialSweep = false
    private var sweepRunning = false
    private var activePrefetches = 0

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let resolved = directory ?? base.appendingPathComponent("Artwork", isDirectory: true)
        self.directory = resolved
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    static func key(for url: URL, variant: ArtworkVariant) -> String {
        "\(url.absoluteString)#\(variant)"
    }

    func cgImage(for url: URL, variant: ArtworkVariant) async -> CGImage? {
        await load(url: url, variant: variant, priority: .userInitiated)
    }

    func prefetchImage(for url: URL, variant: ArtworkVariant) async -> CGImage? {
        let key = Self.key(for: url, variant: variant)
        if flights[key] == nil {
            while activePrefetches >= Self.maxConcurrentPrefetches {
                if Task.isCancelled { return nil }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        if Task.isCancelled { return nil }
        activePrefetches += 1
        defer { activePrefetches -= 1 }
        return await load(url: url, variant: variant, priority: .utility)
    }

    func removeAll() {
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
        negativeUntil.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func load(url: URL, variant: ArtworkVariant, priority: TaskPriority) async -> CGImage? {
        let key = Self.key(for: url, variant: variant)

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
            scheduleSweep()
        }

        let file = fileURL(forKey: key)
        let candidates = variant.requestURLs(for: url)
        let maxPixel = variant.maxDecodedPixelSize
        let token = UUID()
        let task = Task.detached(priority: priority) { () -> CGImage? in
            let result = await self.produce(key: key, file: file, candidates: candidates, maxPixel: maxPixel)
            await self.completeFlight(key, token: token)
            return result
        }
        let flight = Flight(token: token, task: task, interest: 1)
        flights[key] = flight
        return await join(key, flight)
    }

    private nonisolated func produce(key: String, file: URL, candidates: [URL], maxPixel: Int) async -> CGImage? {
        if let data = Self.readDisk(at: file) {
            #if DEBUG
            SCArtworkMetrics.event("DISK", "bytes=\(data.count) \(key)")
            #endif
            if let image = Self.decode(data, maxPixelSize: maxPixel) {
                return image
            }
            try? FileManager.default.removeItem(at: file)
        }

        var attempted = Set<URL>()
        for candidate in candidates {
            guard attempted.insert(candidate).inserted else { continue }
            if Task.isCancelled { return nil }
            guard let (data, response) = try? await session.data(from: candidate) else { continue }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                continue
            }
            guard let image = Self.decode(data, maxPixelSize: maxPixel) else { continue }
            #if DEBUG
            SCArtworkMetrics.event("NET", "bytes=\(data.count) \(candidate.absoluteString)")
            #endif
            Self.writeDisk(data, to: file)
            await self.noteWrite(Int64(data.count))
            return image
        }

        if !Task.isCancelled {
            await self.noteFailure(key)
        }
        return nil
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
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(Self.digest(of: key), isDirectory: false)
    }

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
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as [CFString: Any] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
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
