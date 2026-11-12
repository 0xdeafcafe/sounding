import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DJMediaExportError: Error, Equatable, Sendable {
    case volumeNotFound(String)
    case volumeRemoved(String)
    case readOnlyVolume(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case existingLibrary(String)
    case destinationExists(String)
    case nothingToExport
    case invalidExport([String])
    case copyMismatch(String)
    case io(String)
}

struct DJExportProgress: Sendable {
    enum Phase: Sendable { case planning, staging, verifying, copying, flushing, finishing }

    var phase: Phase
    var completed: Int
    var total: Int
}

struct DJExportReport: Sendable {
    var exportRoot: URL
    var exportedTrackCount: Int
    var skipped: [DJSkippedTrack]
    var warnings: [String]
    var bytesWritten: Int64
    var volumeInfo: DJVolumeInfo?
}

struct DJMediaExporter: Sendable {
    var fileSystem: any DJExportFileSystem = DJPosixFileSystem()
    var heartbeat: (@Sendable () -> Void)?
    var spaceMargin: Int64 = 16 << 20

    func export(
        tracks: [any DJExportTrack],
        playlists: [DJExportPlaylist],
        to volume: URL,
        options: DJExportOptions = DJExportOptions(),
        now: Date = Date(),
        progress: (@Sendable (DJExportProgress) -> Void)? = nil
    ) async throws -> DJExportReport {
        let fm = FileManager.default
        let fs = fileSystem
        guard fs.isDirectory(volume) else { throw DJMediaExportError.volumeNotFound(volume.path) }
        let info = DJVolumeInfo.inspect(volume)
        if info?.isReadOnly == true { throw DJMediaExportError.readOnlyVolume(volume.path) }

        progress?(DJExportProgress(phase: .planning, completed: 0, total: tracks.count))
        var missing: [DJSkippedTrack] = []
        var prepared: [any DJExportTrack] = []
        for track in tracks {
            guard track.audioFileURL.isFileURL,
                  let size = (try? fm.attributesOfItem(atPath: track.audioFileURL.path)[.size] as? NSNumber)?.int64Value
            else {
                missing.append(DJSkippedTrack(id: track.exportID, reason: "audio file is missing"))
                continue
            }
            var record = DJExportTrackRecord(track)
            record.metadata.fileSize = size
            prepared.append(record)
        }
        var plan = try DJExportPlanner.plan(tracks: prepared, playlists: playlists, options: options, now: now)
        plan.skipped = missing + plan.skipped
        guard !plan.copies.isEmpty else { throw DJMediaExportError.nothingToExport }

        var warnings = plan.warnings
        if let info {
            if !info.isDJPlayerFormat {
                warnings.append("\(info.displayName) sticks can't be read by DJ players. Use exFAT or FAT32.")
            }
            let needed = plannedBytes(plan, fm: fm)
            let required = needed + max(spaceMargin, needed / 50)
            if info.freeBytes < required {
                throw DJMediaExportError.notEnoughSpace(needed: required, available: info.freeBytes)
            }
        }

        let finalRoot = try resolveDestination(options.destination, volume: volume, now: now, fs: fs)
        let staging = fm.temporaryDirectory.appending(path: "SoundingDJExport-\(UUID().uuidString)", directoryHint: .isDirectory)
        let incomingName = "\(DJExportJournal.incomingPrefix)\(UUID().uuidString)"
        let incoming = volume.appending(path: incomingName, directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }

        progress?(DJExportProgress(phase: .staging, completed: 0, total: plan.analysis.count))
        let generated = try stage(plan, at: staging, fm: fm)
        try Task.checkCancellation()

        progress?(DJExportProgress(phase: .verifying, completed: 0, total: 1))
        try verifyStaged(plan, staging: staging)
        try Task.checkCancellation()

        var journal = DJExportJournal(
            id: UUID().uuidString,
            state: .started,
            destination: Self.destinationName(options.destination),
            incoming: incomingName,
            finalFolder: finalFolderName(options.destination, finalRoot: finalRoot),
            backupStamp: Self.stamp(now),
            rootHadLibrary: DJExportRecovery.hasLibrary(volume: volume, fs: fs),
            rootHadContents: fs.exists(volume.appending(path: "Contents")),
            startedAt: now,
            updatedAt: now
        )

        var committing = false
        do {
            prepareVolume(volume, fs: fs)
            try journal.write(volume: volume, state: .started, fs: fs, now: now)
            try fs.createDirectory(incoming)

            var bytes: Int64 = 0
            let total = plan.copies.count + generated.count
            var done = 0
            for copy in plan.copies {
                try Task.checkCancellation()
                let target = incoming.appending(path: relative(copy.devicePath))
                try fs.createDirectory(target.deletingLastPathComponent())
                bytes += try fs.copy(from: copy.source, to: target, verify: options.verifyCopiedAudio, onChunk: beat)
                done += 1
                progress?(DJExportProgress(phase: .copying, completed: done, total: total))
            }
            for path in generated {
                try Task.checkCancellation()
                let target = incoming.appending(path: path)
                try fs.createDirectory(target.deletingLastPathComponent())
                bytes += try fs.copy(from: staging.appending(path: path), to: target, verify: true, onChunk: beat)
                done += 1
                progress?(DJExportProgress(phase: .copying, completed: done, total: total))
            }
            try fs.syncTree(incoming)

            progress?(DJExportProgress(phase: .flushing, completed: 0, total: 1))
            let report = DJMediaValidator.validate(exportRoot: incoming)
            guard report.isValid else { throw DJMediaExportError.invalidExport(report.errors.map(\.message)) }
            try Task.checkCancellation()

            progress?(DJExportProgress(phase: .finishing, completed: 0, total: 1))
            let added = try planContents(options.destination, incoming: incoming, root: volume, fs: fs)
            journal.addedToContents = added
            try journal.write(volume: volume, state: .committing, fs: fs)
            committing = true
            try commit(incoming: incoming, to: finalRoot, volume: volume, destination: options.destination, journal: journal, added: added, fs: fs)
            try DJExportScrubber.scrub(DJExportRecovery.scrubRoots(volume: volume, journal: journal), fs: fs)
            try fs.syncTree(finalRoot)
            try fs.syncDirectory(volume)

            let verdict = DJMediaValidator.validate(exportRoot: finalRoot)
            guard verdict.isValid else { throw DJMediaExportError.invalidExport(verdict.errors.map(\.message)) }
            try journal.write(volume: volume, state: .completed, fs: fs)
            if fs.exists(incoming) { try fs.remove(incoming) }
            try fs.syncDirectory(volume)

            return DJExportReport(
                exportRoot: finalRoot,
                exportedTrackCount: plan.copies.count,
                skipped: plan.skipped,
                warnings: warnings,
                bytesWritten: bytes,
                volumeInfo: info
            )
        } catch {
            if committing {
                _ = try? DJExportRecovery.recover(volume: volume, fs: fs)
            } else {
                try? fs.remove(incoming)
                _ = try? journal.write(volume: volume, state: .rolledBack, fs: fs)
            }
            if let io = error as? DJVolumeIOError {
                if io.looksLikeRemoval || !fs.isDirectory(volume) { throw DJMediaExportError.volumeRemoved(volume.path) }
                throw DJMediaExportError.io(io.description)
            }
            throw error
        }
    }

    private func beat() throws {
        try Task.checkCancellation()
        heartbeat?()
    }

    private func prepareVolume(_ volume: URL, fs: any DJExportFileSystem) {
        let marker = volume.appending(path: ".metadata_never_index")
        if !fs.exists(marker) { try? fs.write(Data(), to: marker) }
        let events = volume.appending(path: ".fseventsd", directoryHint: .isDirectory)
        if !fs.exists(events) {
            try? fs.createDirectory(events)
            try? fs.write(Data(), to: events.appending(path: "no_log"))
            try? fs.syncDirectory(events)
        }
        let trashes = volume.appending(path: ".Trashes", directoryHint: .isDirectory)
        if !fs.exists(trashes) { try? fs.createDirectory(trashes) }
        try? fs.syncDirectory(volume)
    }

    private func plannedBytes(_ plan: DJExportPlan, fm: FileManager) -> Int64 {
        var total: Int64 = 0
        for copy in plan.copies {
            total += (try? fm.attributesOfItem(atPath: copy.source.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        for artwork in plan.artwork { total += Int64(artwork.jpeg.count) }
        return total + (8 << 20)
    }

    static func destinationName(_ destination: DJExportOptions.Destination) -> String {
        switch destination {
        case .newFolder:               return "newFolder"
        case .volumeRoot:              return "volumeRoot"
        case .replaceExistingLibrary:  return "replace"
        }
    }

    private func finalFolderName(_ destination: DJExportOptions.Destination, finalRoot: URL) -> String? {
        if case .newFolder = destination { return finalRoot.lastPathComponent }
        return nil
    }

    static func stamp(_ now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: now)
    }

    // MARK: - Destination

    static func defaultFolderName(_ now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "Sounding Export \(f.string(from: now))"
    }

    func resolveDestination(_ destination: DJExportOptions.Destination, volume: URL, now: Date, fs: any DJExportFileSystem) throws -> URL {
        let hasLibrary = DJExportRecovery.hasLibrary(volume: volume, fs: fs)
        switch destination {
        case .newFolder(let name):
            let base = DJDevicePath.component(name ?? Self.defaultFolderName(now), fallback: "Sounding Export")
            var candidate = volume.appending(path: base, directoryHint: .isDirectory)
            var n = 2
            while fs.exists(candidate) {
                candidate = volume.appending(path: "\(base) \(n)", directoryHint: .isDirectory)
                n += 1
            }
            return candidate
        case .volumeRoot:
            if hasLibrary { throw DJMediaExportError.existingLibrary(volume.path) }
            if fs.exists(volume.appending(path: "Contents")) {
                throw DJMediaExportError.destinationExists(volume.appending(path: "Contents").path)
            }
            return volume
        case .replaceExistingLibrary:
            return volume
        }
    }

    func relative(_ devicePath: String) -> String {
        String(devicePath.drop { $0 == "/" })
    }

    // MARK: - Staging

    func stage(_ plan: DJExportPlan, at staging: URL, fm: FileManager) throws -> [String] {
        var written: [String] = []
        func put(_ data: Data, _ path: String) throws {
            let url = staging.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            written.append(path)
        }
        for a in plan.analysis {
            try put(ANLZCodec.write(a.dat), relative(a.datPath))
            try put(ANLZCodec.write(a.ext), relative(a.extPath))
            if let ex2 = a.ex2 { try put(ANLZCodec.write(ex2), relative(a.ex2Path)) }
        }
        for art in plan.artwork {
            try put(DJArtwork.jpeg(art.jpeg, side: 80) ?? art.jpeg, relative(art.devicePath))
            try put(DJArtwork.jpeg(art.jpeg, side: 240) ?? art.jpeg, relative(art.largeDevicePath))
        }
        try put(PDBWriter.write(plan.database), "PIONEER/rekordbox/export.pdb")
        return written
    }

    func verifyStaged(_ plan: DJExportPlan, staging: URL) throws {
        let pdb = try Data(contentsOf: staging.appending(path: "PIONEER/rekordbox/export.pdb"))
        let sizes = Dictionary(plan.copies.map { ($0.devicePath, $0.source) }, uniquingKeysWith: { a, _ in a })
        let report = DJMediaValidator.validate(pdb: pdb, file: { path in
            try? Data(contentsOf: staging.appending(path: relative(path)))
        }, fileSize: { path in
            let url = sizes[path] ?? staging.appending(path: relative(path))
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        })
        guard report.isValid else { throw DJMediaExportError.invalidExport(report.errors.map(\.message)) }
        let reread = try PDBReader.read(pdb).database
        guard reread.tracks == plan.database.tracks, reread.playlistEntries == plan.database.playlistEntries else {
            throw DJMediaExportError.invalidExport(["export.pdb does not read back as written"])
        }
    }

    // MARK: - Commit

    func planContents(_ destination: DJExportOptions.Destination, incoming: URL, root: URL, fs: any DJExportFileSystem) throws -> [String] {
        guard case .replaceExistingLibrary = destination else { return [] }
        let source = incoming.appending(path: "Contents", directoryHint: .isDirectory)
        let target = root.appending(path: "Contents", directoryHint: .isDirectory)
        var added: [String] = []
        for file in fs.allFiles(under: source) {
            let rel = String(file.path.dropFirst(source.path.count).drop { $0 == "/" })
            let existing = target.appending(path: rel)
            if fs.exists(existing) {
                if fs.fileSize(existing) == fs.fileSize(file), try fs.digest(existing) == fs.digest(file) { continue }
                throw DJMediaExportError.destinationExists(existing.path)
            }
            added.append(rel)
        }
        return added
    }

    func commit(
        incoming: URL,
        to root: URL,
        volume: URL,
        destination: DJExportOptions.Destination,
        journal: DJExportJournal,
        added: [String],
        fs: any DJExportFileSystem
    ) throws {
        switch destination {
        case .newFolder:
            try fs.rename(incoming, to: root)
            try fs.syncDirectory(volume)
        case .volumeRoot:
            try fs.rename(incoming.appending(path: "Contents"), to: root.appending(path: "Contents"))
            try fs.syncDirectory(root)
            try fs.rename(incoming.appending(path: "PIONEER"), to: root.appending(path: "PIONEER"))
            try fs.syncDirectory(root)
        case .replaceExistingLibrary:
            let source = incoming.appending(path: "Contents", directoryHint: .isDirectory)
            let target = root.appending(path: "Contents", directoryHint: .isDirectory)
            for rel in added {
                let destination = target.appending(path: rel)
                try fs.createDirectory(destination.deletingLastPathComponent())
                try fs.rename(source.appending(path: rel), to: destination)
                try fs.syncDirectory(destination.deletingLastPathComponent())
            }
            try fs.syncDirectory(root)
            let stamp = journal.backupStamp ?? Self.stamp(Date())
            for name in ["PIONEER", ".PIONEER"] where fs.exists(root.appending(path: name)) {
                try fs.rename(root.appending(path: name), to: root.appending(path: "\(name)\(DJExportJournal.backupInfix)\(stamp)"))
                try fs.syncDirectory(root)
            }
            try fs.rename(incoming.appending(path: "PIONEER"), to: root.appending(path: "PIONEER"))
            try fs.syncDirectory(root)
        }
    }
}

enum DJArtwork {
    static func jpeg(_ data: Data, side: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = ImageThumbnail.create(from: source, maxPixelSize: side) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
