import Foundation

struct AnalysisDataSnapshot: Sendable {
    var analysedTrackCount = 0
    var resultCount = 0
    var syncedResultCount = 0
    var tempoKeyCount = 0
    var genreCount = 0
    var waveformCount = 0
    var isTruncated = false
    var usedBytes: Int64 = 0
    var maxBytes: Int64 = AnalysisCache.defaultMaxBytes
    var libraryDiskBytes: Int64 = 0
}

enum AnalysisDataUsage {
    static let rowScanLimit = 20_000

    static func snapshot() async -> AnalysisDataSnapshot {
        var snapshot = AnalysisDataSnapshot()
        let cache = AnalysisCache.shared
        let rows = await cache.allRecallRows(limit: rowScanLimit)
        let localProducerId = AnalysisSyncIdentity.producerId(defaults: .standard)
        let tempoKeyEngines: Set<String> = [
            AnalysisEngineIdentity.musicUnderstanding().name,
            AnalysisEngineIdentity.userCorrection().name,
        ]
        let genreEngine = AnalysisEngineIdentity.genreTaxonomy().name
        let waveformEngine = AnalysisEngineIdentity.soundCloudWaveform().name

        var trackIds = Set<String>()
        for row in rows {
            trackIds.insert(row.trackId)
            let engine = row.generation.engine.name
            if tempoKeyEngines.contains(engine) {
                snapshot.tempoKeyCount += 1
            } else if engine == genreEngine {
                snapshot.genreCount += 1
            } else if engine == waveformEngine {
                snapshot.waveformCount += 1
            }
            if let producerId = row.producerId, producerId != localProducerId {
                snapshot.syncedResultCount += 1
            }
        }
        snapshot.analysedTrackCount = trackIds.count
        snapshot.resultCount = rows.count
        snapshot.isTruncated = rows.count >= rowScanLimit
        snapshot.usedBytes = await cache.usedBytes
        snapshot.maxBytes = await cache.maxBytes
        #if !os(macOS)
        snapshot.libraryDiskBytes = directoryBytes(at: LibraryCache.defaultDirectory())
        #endif
        return snapshot
    }

    static func clearAnalysisData() async {
        await AnalysisCache.shared.removeAll(keepingUserCorrections: true)
    }

    static func storageUsedBytes() async -> Int64 {
        await AnalysisCache.shared.usedBytes
    }

    static func directoryBytes(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}
