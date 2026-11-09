import Foundation

struct SoundingDataJournalOp<Value: Codable & Sendable>: Codable, Sendable {
    var id: String
    var at: Int64
    var device: String
    var seq: Int64
    var value: Value?
    var clear: Bool?

    var isClear: Bool { clear == true }

    func isNewer(than other: SoundingDataJournalOp<Value>) -> Bool {
        (at, device, seq) > (other.at, other.device, other.seq)
    }
}

struct SoundingDataJournalSegment<Value: Codable & Sendable>: Codable, Sendable {
    var format: Int
    var device: String
    var ops: [SoundingDataJournalOp<Value>]
}

enum SoundingDataJournalMerge {
    static func merge<Value>(_ ops: [SoundingDataJournalOp<Value>]) -> [String: Value] {
        let (barrier, latest) = reduce(ops)
        var out: [String: Value] = [:]
        for (id, op) in latest {
            if let barrier, !op.isNewer(than: barrier) { continue }
            if let value = op.value { out[id] = value }
        }
        return out
    }

    static func reduce<Value>(_ ops: [SoundingDataJournalOp<Value>]) -> (barrier: SoundingDataJournalOp<Value>?, latest: [String: SoundingDataJournalOp<Value>]) {
        var barrier: SoundingDataJournalOp<Value>?
        var latest: [String: SoundingDataJournalOp<Value>] = [:]
        for op in ops {
            if op.isClear {
                if barrier.map({ op.isNewer(than: $0) }) ?? true { barrier = op }
                continue
            }
            if let existing = latest[op.id], !op.isNewer(than: existing) { continue }
            latest[op.id] = op
        }
        return (barrier, latest)
    }

    static func compacted<Value>(
        _ ops: [SoundingDataJournalOp<Value>],
        now: Int64,
        tombstoneLifetimeMillis: Int64 = 180 * 86_400_000
    ) -> [SoundingDataJournalOp<Value>] {
        let (barrier, latest) = reduce(ops)
        var kept: [SoundingDataJournalOp<Value>] = []
        if let barrier { kept.append(barrier) }
        for op in latest.values {
            if let barrier, !op.isNewer(than: barrier) { continue }
            if op.value == nil, now - op.at > tombstoneLifetimeMillis { continue }
            kept.append(op)
        }
        return kept.sorted { ($0.at, $0.seq, $0.id) < ($1.at, $1.seq, $1.id) }
    }
}

enum SoundingDataJournalClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastAt: Int64 = 0
    nonisolated(unsafe) private static var sequence: Int64 = 0

    static func next(at requested: Int64? = nil) -> (at: Int64, seq: Int64) {
        lock.withLock {
            sequence += 1
            if let requested { return (requested, sequence) }
            let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
            lastAt = max(now, lastAt + 1)
            return (lastAt, sequence)
        }
    }
}

enum SoundingDataJournalQueue {
    static let queue = DispatchQueue(label: "red.forbes.sounding.data.journal", qos: .utility)

    struct Pending {
        var device: String
        var ops: [Data] = []
        var scheduled = false
        var compact: (@Sendable () -> Void)?
    }

    nonisolated(unsafe) static var pending: [String: Pending] = [:]

    static func flushLocked(_ directory: URL) {
        let key = directory.standardizedFileURL.path
        guard var batch = pending[key], !batch.ops.isEmpty else { return }
        let ops = batch.ops
        batch.ops = []
        batch.scheduled = false
        pending[key] = batch
        writeSegment(ops: ops, device: batch.device, directory: directory)
        batch.compact?()
    }

    static func writeSegment(ops: [Data], device: String, directory: URL) {
        var body = Data("{\"device\":".utf8)
        body.append((try? JSONSerialization.data(withJSONObject: device, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8))
        body.append(Data(",\"format\":\(SoundingDataFormat.version),\"ops\":[".utf8))
        for (index, op) in ops.enumerated() {
            if index > 0 { body.append(UInt8(ascii: ",")) }
            body.append(op)
        }
        body.append(Data("]}".utf8))
        guard let packed = try? PackedJSON.pack(body) else {
            Log.library.error("Journal segment could not be packed")
            return
        }
        let stamp = SoundingDataJournalClock.next()
        let name = String(format: "%013lld-%06lld-%@.sndj", stamp.at, stamp.seq % 1_000_000, String(UUID().uuidString.prefix(4)))
        let url = directory.appendingPathComponent(device, isDirectory: true).appendingPathComponent(name)
        do {
            try SoundingDataFiles.write(SoundingDataFormat.wrap(packed, kind: .journalSegment), to: url)
        } catch {
            Log.library.error("Journal segment write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

final class SoundingDataJournal<Value: Codable & Sendable>: @unchecked Sendable {
    static var fileExtension: String { "sndj" }

    let area: SoundingDataArea?
    let device: String
    let debounce: TimeInterval
    let compactAfter: Int
    private let fixedDirectory: URL?

    init(area: SoundingDataArea, device: String = SoundingDataDevice.id(), debounce: TimeInterval = 1, compactAfter: Int = 24) {
        self.area = area
        fixedDirectory = nil
        self.device = device
        self.debounce = debounce
        self.compactAfter = compactAfter
    }

    init(directory: URL, device: String = SoundingDataDevice.id(), debounce: TimeInterval = 0, compactAfter: Int = 24) {
        area = nil
        fixedDirectory = directory
        self.device = device
        self.debounce = debounce
        self.compactAfter = compactAfter
    }

    var directory: URL {
        if let fixedDirectory { return fixedDirectory }
        return SoundingDataLocation.shared.directory(area ?? .analysis)
    }

    func load() -> [String: Value] {
        let directory = directory
        return SoundingDataJournalQueue.queue.sync {
            SoundingDataJournalQueue.flushLocked(directory)
            return SoundingDataJournalMerge.merge(Self.readOps(in: directory))
        }
    }

    func put(_ id: String, _ value: Value, at: Int64? = nil) {
        append(id: id, value: value, clear: nil, at: at)
    }

    func remove(_ id: String) {
        append(id: id, value: nil, clear: nil, at: nil)
    }

    func clearAll() {
        append(id: "", value: nil, clear: true, at: nil)
    }

    func flush() {
        let directory = directory
        SoundingDataJournalQueue.queue.sync { SoundingDataJournalQueue.flushLocked(directory) }
    }

    func migrateLegacy(file: URL, decode: (Data) -> [(String, Value)]) {
        guard FileManager.default.fileExists(atPath: file.path), let data = try? Data(contentsOf: file) else { return }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let at = Int64((modified.timeIntervalSince1970 * 1000).rounded())
        let items = decode(data)
        for (id, value) in items { put(id, value, at: at) }
        flush()
        let archived = file.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: archived)
        try? FileManager.default.moveItem(at: file, to: archived)
        if !items.isEmpty {
            Log.library.info("Moved \(items.count, privacy: .public) item(s) from \(file.lastPathComponent, privacy: .public) into Sounding Data")
        }
    }

    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> [NSObjectProtocol] {
        let area = area
        let gate = SoundingDataThrottle(delay: 1, minimumInterval: 15, action: handler)
        let disk = NotificationCenter.default.addObserver(forName: .soundingDataDidChangeOnDisk, object: nil, queue: nil) { note in
            let changed = note.userInfo?[SoundingDataLocation.areaKey] as? String
            guard changed == nil || changed == area?.rawValue else { return }
            gate.trigger()
        }
        let moved = NotificationCenter.default.addObserver(forName: .soundingDataLocationDidChange, object: nil, queue: nil) { _ in
            gate.trigger()
        }
        return [disk, moved]
    }

    private func append(id: String, value: Value?, clear: Bool?, at: Int64?) {
        let stamp = SoundingDataJournalClock.next(at: at)
        let op = SoundingDataJournalOp(id: id, at: stamp.at, device: device, seq: stamp.seq, value: value, clear: clear)
        guard let encoded = try? SoundingDataFormat.jsonEncoder.encode(op) else { return }
        let directory = directory
        let key = directory.standardizedFileURL.path
        let device = device
        let debounce = debounce
        let compactAfter = compactAfter
        let compact: @Sendable () -> Void = {
            Self.compactIfNeeded(directory: directory, device: device, limit: compactAfter)
        }
        SoundingDataJournalQueue.queue.async {
            var batch = SoundingDataJournalQueue.pending[key] ?? .init(device: device)
            batch.ops.append(encoded)
            batch.compact = compact
            let needsSchedule = !batch.scheduled
            batch.scheduled = true
            SoundingDataJournalQueue.pending[key] = batch
            guard needsSchedule else { return }
            if debounce <= 0 {
                SoundingDataJournalQueue.flushLocked(directory)
            } else {
                SoundingDataJournalQueue.queue.asyncAfter(deadline: .now() + debounce) {
                    SoundingDataJournalQueue.flushLocked(directory)
                }
            }
        }
        if debounce <= 0 { flush() }
    }

    static func readOps(in directory: URL) -> [SoundingDataJournalOp<Value>] {
        var ops: [SoundingDataJournalOp<Value>] = []
        for entry in SoundingDataFiles.files(in: directory, extension: fileExtension) where entry.isDownloaded {
            guard case .data(let data) = SoundingDataFiles.read(entry.url, knownDownloaded: true),
                  let segment = try? SoundingDataFormat.decode(SoundingDataJournalSegment<Value>.self, from: data, kind: .journalSegment) else { continue }
            ops.append(contentsOf: segment.ops)
        }
        return ops
    }

    static func compactIfNeeded(directory: URL, device: String, limit: Int) {
        let own = directory.appendingPathComponent(device, isDirectory: true)
        let entries = SoundingDataFiles.files(in: own, extension: fileExtension)
        guard entries.count > limit, entries.allSatisfy(\.isDownloaded) else { return }
        var ops: [SoundingDataJournalOp<Value>] = []
        for entry in entries {
            guard case .data(let data) = SoundingDataFiles.read(entry.url, knownDownloaded: true),
                  let segment = try? SoundingDataFormat.decode(SoundingDataJournalSegment<Value>.self, from: data, kind: .journalSegment) else { return }
            ops.append(contentsOf: segment.ops.filter { $0.device == device })
        }
        let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let kept = SoundingDataJournalMerge.compacted(ops, now: now)
        let encoded = kept.compactMap { try? SoundingDataFormat.jsonEncoder.encode($0) }
        guard encoded.count == kept.count else { return }
        SoundingDataJournalQueue.writeSegment(ops: encoded, device: device, directory: directory)
        for entry in entries { SoundingDataFiles.remove(entry.url) }
    }
}

struct SoundingDataThrottlePolicy: Sendable {
    struct Scheduled: Equatable, Sendable {
        let token: Int
        let at: Date
    }

    let delay: TimeInterval
    let minimumInterval: TimeInterval
    private(set) var lastRun: Date?
    private(set) var pending: Scheduled?
    private var nextToken = 0

    init(delay: TimeInterval, minimumInterval: TimeInterval) {
        self.delay = delay
        self.minimumInterval = minimumInterval
    }

    mutating func request(now: Date, after explicit: TimeInterval? = nil) -> Scheduled? {
        var at = now.addingTimeInterval(explicit ?? delay)
        if explicit == nil, let lastRun { at = max(at, lastRun.addingTimeInterval(minimumInterval)) }
        if let pending, pending.at <= at { return nil }
        nextToken += 1
        let scheduled = Scheduled(token: nextToken, at: at)
        pending = scheduled
        return scheduled
    }

    mutating func shouldRun(token: Int, now: Date) -> Bool {
        guard let pending, pending.token == token else { return false }
        self.pending = nil
        lastRun = now
        return true
    }
}

final class SoundingDataThrottle: @unchecked Sendable {
    private let action: @Sendable () -> Void
    private let lock = NSLock()
    private var policy: SoundingDataThrottlePolicy

    init(delay: TimeInterval, minimumInterval: TimeInterval, action: @escaping @Sendable () -> Void) {
        policy = SoundingDataThrottlePolicy(delay: delay, minimumInterval: minimumInterval)
        self.action = action
    }

    func trigger(after explicit: TimeInterval? = nil) {
        let now = Date()
        guard let scheduled = lock.withLock({ policy.request(now: now, after: explicit) }) else { return }
        let wait = max(0, scheduled.at.timeIntervalSince(now))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.lock.withLock({ self.policy.shouldRun(token: scheduled.token, now: Date()) }) else { return }
            self.action()
        }
    }
}
