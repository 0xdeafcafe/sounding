import Foundation

struct AnalysisDataRecord: Equatable, Sendable {
    let cacheKey: String
    let trackId: String
    let engineName: String
    let engineVersion: Int
    let schemaVersion: Int
    let durationMillis: Int
    let preset: String
    let bitrate: Int
    let codec: String
    let payload: Data
    let bpm: Double?
    let keyWheelPosition: Int?
    let keyMode: Int?
    let genre: String?
    let producedAtMillis: Int64
    let producerId: String

    func isNewer(than other: AnalysisDataRecord) -> Bool {
        (producedAtMillis, producerId) > (other.producedAtMillis, other.producerId)
    }

    var isUserCorrection: Bool { engineName == AnalysisEngineIdentity.userCorrection().name }

    var key: AnalysisCacheKey {
        AnalysisCacheKey(
            trackId: trackId,
            engine: AnalysisEngineIdentity(name: engineName, version: engineVersion),
            schemaVersion: schemaVersion,
            fingerprint: AnalyzedAudioFingerprint(durationMillis: durationMillis, preset: preset, bitrate: bitrate, codec: codec)
        )
    }

    var features: AnalysisFeatures {
        var features = AnalysisFeatures(bpm: bpm, genre: genre)
        if let keyWheelPosition, let keyMode, let mode = CamelotKey.CamelotMode(rawValue: keyMode) {
            features.key = CamelotKey(wheelPosition: keyWheelPosition, mode: mode)
        }
        return features
    }
}

enum AnalysisDataFiles {
    static let fileExtension = "snda"
    static let recordVersion = 1

    static func trackDirectory(trackId: String, in root: URL) -> URL {
        let hash = SoundingDataFiles.hashName(trackId, length: 16)
        return SoundingDataFiles.shardedDirectory(in: root, for: hash).appendingPathComponent(hash, isDirectory: true)
    }

    static func url(for record: AnalysisDataRecord, in root: URL) -> URL {
        url(cacheKey: record.cacheKey, trackId: record.trackId, engineName: record.engineName, in: root)
    }

    static func url(cacheKey: String, trackId: String, engineName: String, in root: URL) -> URL {
        trackDirectory(trackId: trackId, in: root)
            .appendingPathComponent("\(slug(engineName))-\(SoundingDataFiles.hashName(cacheKey, length: 16))")
            .appendingPathExtension(fileExtension)
    }

    static func isUserCorrection(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(slug(AnalysisEngineIdentity.userCorrection().name) + "-")
    }

    static func slug(_ text: String) -> String {
        String(text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "." ? Character($0) : "_" })
    }

    static func encode(_ record: AnalysisDataRecord) throws -> Data {
        var object: [String: Any] = [
            "v": recordVersion,
            "cacheKey": record.cacheKey,
            "trackId": record.trackId,
            "engine": record.engineName,
            "engineVersion": record.engineVersion,
            "schemaVersion": record.schemaVersion,
            "durationMillis": record.durationMillis,
            "preset": record.preset,
            "bitrate": record.bitrate,
            "codec": record.codec,
            "producedAt": record.producedAtMillis,
            "producer": record.producerId,
            "payload": try PackedJSON.parse(record.payload),
        ]
        if let bpm = record.bpm { object["bpm"] = bpm }
        if let keyWheelPosition = record.keyWheelPosition { object["keyWheel"] = keyWheelPosition }
        if let keyMode = record.keyMode { object["keyMode"] = keyMode }
        if let genre = record.genre { object["genre"] = genre }
        return SoundingDataFormat.wrap(try PackedJSON.packObject(object), kind: .analysisRecord)
    }

    static func decode(_ data: Data) throws -> AnalysisDataRecord {
        let body = try SoundingDataFormat.unwrap(data, expecting: .analysisRecord)
        guard let object = try PackedJSON.unpackObject(body) as? [String: Any],
              let version = (object["v"] as? NSNumber)?.intValue, version <= recordVersion,
              let cacheKey = object["cacheKey"] as? String,
              let trackId = object["trackId"] as? String,
              let engineName = object["engine"] as? String,
              let engineVersion = (object["engineVersion"] as? NSNumber)?.intValue,
              let schemaVersion = (object["schemaVersion"] as? NSNumber)?.intValue,
              let durationMillis = (object["durationMillis"] as? NSNumber)?.intValue,
              let preset = object["preset"] as? String,
              let bitrate = (object["bitrate"] as? NSNumber)?.intValue,
              let codec = object["codec"] as? String,
              let producedAt = (object["producedAt"] as? NSNumber)?.int64Value,
              let producer = object["producer"] as? String,
              let payload = object["payload"] else { throw SoundingDataFormatError.corrupt }
        return AnalysisDataRecord(
            cacheKey: cacheKey,
            trackId: trackId,
            engineName: engineName,
            engineVersion: engineVersion,
            schemaVersion: schemaVersion,
            durationMillis: durationMillis,
            preset: preset,
            bitrate: bitrate,
            codec: codec,
            payload: try PackedJSON.serialize(payload),
            bpm: (object["bpm"] as? NSNumber)?.doubleValue,
            keyWheelPosition: (object["keyWheel"] as? NSNumber)?.intValue,
            keyMode: (object["keyMode"] as? NSNumber)?.intValue,
            genre: object["genre"] as? String,
            producedAtMillis: producedAt,
            producerId: producer
        )
    }

    static func merge(current: Data, other: Data) -> Data? {
        guard let otherRecord = try? decode(other) else { return nil }
        guard let currentRecord = try? decode(current) else { return other }
        return otherRecord.isNewer(than: currentRecord) ? other : nil
    }
}

final class AnalysisDataMirror: @unchecked Sendable {
    static let shared: AnalysisDataMirror? = {
        #if os(macOS) || os(iOS)
        return AnalysisDataMirror(root: { SoundingDataLocation.shared.directory(.analysis) })
        #else
        return nil
        #endif
    }()

    let root: @Sendable () -> URL
    private let queue = DispatchQueue(label: "red.forbes.sounding.analysis.mirror", qos: .utility)
    private let debounce: TimeInterval
    private var pending: [String: AnalysisDataRecord] = [:]
    private var scheduled = false

    init(root: @escaping @Sendable () -> URL, debounce: TimeInterval = 2) {
        self.root = root
        self.debounce = debounce
    }

    func enqueue(_ record: AnalysisDataRecord) {
        queue.async { [self] in
            pending[record.cacheKey] = record
            guard !scheduled else { return }
            scheduled = true
            queue.asyncAfter(deadline: .now() + debounce) { [self] in flushLocked() }
        }
    }

    func flush() {
        queue.sync { flushLocked() }
    }

    @discardableResult
    func writeNow(_ records: [AnalysisDataRecord]) -> Int {
        queue.sync { records.reduce(0) { $0 + (write($1) ? 1 : 0) } }
    }

    func removeTrack(_ trackId: String) {
        queue.async { [self] in
            pending = pending.filter { $0.value.trackId != trackId }
            let directory = AnalysisDataFiles.trackDirectory(trackId: trackId, in: root())
            for entry in SoundingDataFiles.files(in: directory, extension: AnalysisDataFiles.fileExtension) {
                SoundingDataFiles.remove(entry.url)
            }
        }
    }

    func removeAll(keepingUserCorrections: Bool) {
        queue.async { [self] in
            pending = keepingUserCorrections ? pending.filter { $0.value.isUserCorrection } : [:]
            for entry in SoundingDataFiles.files(in: root(), extension: AnalysisDataFiles.fileExtension) {
                if keepingUserCorrections, AnalysisDataFiles.isUserCorrection(entry.url) { continue }
                SoundingDataFiles.remove(entry.url)
            }
            SoundingDataTransfer.pruneEmptyDirectories(in: root())
        }
    }

    private func flushLocked() {
        scheduled = false
        let batch = pending
        pending = [:]
        for record in batch.values { write(record) }
    }

    @discardableResult
    private func write(_ record: AnalysisDataRecord) -> Bool {
        let url = AnalysisDataFiles.url(for: record, in: root())
        switch SoundingDataFiles.read(url) {
        case .data(let existing):
            if let current = try? AnalysisDataFiles.decode(existing), !record.isNewer(than: current) { return false }
        case .notDownloaded:
            return false
        case .missing:
            break
        }
        do {
            return try SoundingDataFiles.write(try AnalysisDataFiles.encode(record), to: url)
        } catch {
            Log.analysis.error("Analysis file write failed for \(record.trackId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
