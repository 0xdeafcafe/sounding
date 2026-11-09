import Foundation

struct DJExportJournal: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case started, committing, completed, rolledBack
    }

    static let fileName = "SOUNDING-EXPORT.json"
    static let incomingPrefix = ".sounding-incoming-"
    static let backupInfix = ".before-sounding-"

    var version = 1
    var id: String
    var state: State
    var destination: String
    var incoming: String
    var finalFolder: String?
    var backupStamp: String?
    var addedToContents: [String] = []
    var rootHadLibrary: Bool
    var rootHadContents: Bool
    var startedAt: Date
    var updatedAt: Date

    static func url(_ volume: URL) -> URL { volume.appending(path: fileName) }

    static func read(volume: URL, fs: any DJExportFileSystem) -> DJExportJournal? {
        guard let data = try? fs.read(url(volume)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DJExportJournal.self, from: data)
    }

    mutating func write(volume: URL, state newState: State, fs: any DJExportFileSystem, now: Date = Date()) throws {
        state = newState
        updatedAt = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fs.writeAtomically(try encoder.encode(self), to: Self.url(volume))
    }
}

enum DJExportScrubber {
    static func isStray(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store"
    }

    @discardableResult
    static func scrub(_ roots: [URL], fs: any DJExportFileSystem) throws -> [String] {
        var removed: [String] = []
        func walk(_ directory: URL) throws {
            for name in try fs.list(directory) {
                let child = directory.appending(path: name)
                if isStray(name) {
                    try fs.remove(child)
                    removed.append(child.path)
                } else if fs.isDirectory(child) {
                    try walk(child)
                }
            }
            if !removed.isEmpty { try fs.syncDirectory(directory) }
        }
        for root in roots where fs.isDirectory(root) { try walk(root) }
        return removed
    }

    static func strays(_ roots: [URL], fs: any DJExportFileSystem) -> [String] {
        var found: [String] = []
        func walk(_ directory: URL) {
            for name in (try? fs.list(directory)) ?? [] {
                let child = directory.appending(path: name)
                if isStray(name) { found.append(child.path) } else if fs.isDirectory(child) { walk(child) }
            }
        }
        for root in roots where fs.isDirectory(root) { walk(root) }
        return found
    }
}

struct DJRecoveryFindings: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case clean
        case unfinished
        case needsLook
    }

    var kind: Kind
    var summary: String
    var details: [String] = []

    var needsRepair: Bool { kind != .clean }
}

struct DJRecoveryReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case nothingToDo
        case cleanedUp
        case rolledBack
        case completed
        case needsAttention
    }

    var outcome: Outcome
    var notes: [String] = []
    var problems: [String] = []
}

enum DJExportRecovery {

    static func orphanedIncoming(volume: URL, fs: any DJExportFileSystem) -> [String] {
        ((try? fs.list(volume)) ?? []).filter { $0.hasPrefix(DJExportJournal.incomingPrefix) }
    }

    static func backups(volume: URL, fs: any DJExportFileSystem) -> [String] {
        ((try? fs.list(volume)) ?? []).filter {
            ($0.hasPrefix("PIONEER") || $0.hasPrefix(".PIONEER")) && $0.contains(DJExportJournal.backupInfix)
        }
    }

    static func hasLibrary(volume: URL, fs: any DJExportFileSystem) -> Bool {
        fs.exists(volume.appending(path: "PIONEER")) || fs.exists(volume.appending(path: ".PIONEER"))
    }

    static func inspect(volume: URL, fs: any DJExportFileSystem = DJPosixFileSystem()) -> DJRecoveryFindings {
        let journal = DJExportJournal.read(volume: volume, fs: fs)
        let orphans = orphanedIncoming(volume: volume, fs: fs)
        let stale = fs.exists(volume.appending(path: ".\(DJExportJournal.fileName).tmp"))
        switch journal?.state {
        case .started?, .committing?:
            return DJRecoveryFindings(
                kind: .unfinished,
                summary: "An export to this stick didn't finish.",
                details: orphans + backups(volume: volume, fs: fs)
            )
        default:
            break
        }
        if !orphans.isEmpty || stale {
            return DJRecoveryFindings(kind: .unfinished, summary: "Leftovers from an export that didn't finish.", details: orphans)
        }
        if !hasLibrary(volume: volume, fs: fs), let backup = backups(volume: volume, fs: fs).first {
            return DJRecoveryFindings(kind: .needsLook, summary: "This stick's library was set aside during an export.", details: [backup])
        }
        return DJRecoveryFindings(kind: .clean, summary: "")
    }

    static func recover(volume: URL, fs: any DJExportFileSystem = DJPosixFileSystem()) throws -> DJRecoveryReport {
        let journal = DJExportJournal.read(volume: volume, fs: fs)
        let orphans = orphanedIncoming(volume: volume, fs: fs)
        var report = DJRecoveryReport(outcome: .nothingToDo)

        func removeIncoming() throws {
            for name in orphanedIncoming(volume: volume, fs: fs) {
                try fs.remove(volume.appending(path: name))
                report.notes.append("Removed unfinished files")
            }
            let stale = volume.appending(path: ".\(DJExportJournal.fileName).tmp")
            if fs.exists(stale) { try fs.remove(stale) }
            try fs.syncDirectory(volume)
        }

        let staleJournal = volume.appending(path: ".\(DJExportJournal.fileName).tmp")
        if fs.exists(staleJournal) {
            try fs.remove(staleJournal)
            try fs.syncDirectory(volume)
        }

        guard var current = journal else {
            if !orphans.isEmpty {
                try removeIncoming()
                report.outcome = .cleanedUp
            }
            try restoreOrphanedBackupIfLibraryMissing(volume: volume, fs: fs, report: &report)
            return report
        }

        switch current.state {
        case .rolledBack:
            if !orphans.isEmpty { try removeIncoming(); report.outcome = .cleanedUp }
        case .completed:
            if !orphans.isEmpty { try removeIncoming(); report.outcome = .cleanedUp }
            let location = libraryRoot(volume: volume, journal: current)
            let validation = DJMediaValidator.validate(exportRoot: location)
            if !validation.isValid {
                report.outcome = .needsAttention
                report.problems = validation.errors.map(\.message)
            }
        case .started:
            try removeIncoming()
            try current.write(volume: volume, state: .rolledBack, fs: fs)
            report.outcome = .rolledBack
            report.notes.append("The stick is as it was before the export.")
        case .committing:
            report = try settleCommit(volume: volume, journal: &current, fs: fs, report: report, removeIncoming: removeIncoming)
        }
        return report
    }

    static func libraryRoot(volume: URL, journal: DJExportJournal) -> URL {
        if let folder = journal.finalFolder { return volume.appending(path: folder, directoryHint: .isDirectory) }
        return volume
    }

    private static func restoreOrphanedBackupIfLibraryMissing(volume: URL, fs: any DJExportFileSystem, report: inout DJRecoveryReport) throws {
        guard !hasLibrary(volume: volume, fs: fs) else { return }
        let found = backups(volume: volume, fs: fs)
        guard found.count == 1, let backup = found.first, let range = backup.range(of: DJExportJournal.backupInfix) else { return }
        let original = String(backup[backup.startIndex ..< range.lowerBound])
        try fs.rename(volume.appending(path: backup), to: volume.appending(path: original))
        try fs.syncDirectory(volume)
        report.outcome = .rolledBack
        report.notes.append("Put the stick's library back.")
    }

    private static func settleCommit(
        volume: URL,
        journal: inout DJExportJournal,
        fs: any DJExportFileSystem,
        report start: DJRecoveryReport,
        removeIncoming: () throws -> Void
    ) throws -> DJRecoveryReport {
        var report = start
        let incoming = volume.appending(path: journal.incoming, directoryHint: .isDirectory)

        func finishRolledBack() throws {
            try removeIncoming()
            try journal.write(volume: volume, state: .rolledBack, fs: fs)
            report.outcome = .rolledBack
            report.notes.append("The stick is as it was before the export.")
        }

        func finishCompleted() throws {
            try removeIncoming()
            try DJExportScrubber.scrub(scrubRoots(volume: volume, journal: journal), fs: fs)
            try journal.write(volume: volume, state: .completed, fs: fs)
            report.outcome = .completed
            report.notes.append("The export had finished; its files check out.")
        }

        switch journal.destination {
        case "newFolder":
            let final = libraryRoot(volume: volume, journal: journal)
            if journal.finalFolder != nil, fs.exists(final), !fs.exists(incoming) {
                if DJMediaValidator.validate(exportRoot: final).isValid {
                    try finishCompleted()
                } else {
                    try fs.remove(final)
                    try fs.syncDirectory(volume)
                    try finishRolledBack()
                }
            } else {
                try finishRolledBack()
            }

        case "volumeRoot", "replace":
            let stamp = journal.backupStamp ?? ""
            let backups = ["PIONEER", ".PIONEER"].filter { fs.exists(volume.appending(path: "\($0)\(DJExportJournal.backupInfix)\(stamp)")) }
            let newPresent = fs.exists(volume.appending(path: "PIONEER")) && !fs.exists(incoming.appending(path: "PIONEER"))
            if backups.isEmpty && !journal.rootHadLibrary {
                if newPresent, DJMediaValidator.validate(exportRoot: volume).isValid {
                    try finishCompleted()
                } else {
                    try fs.remove(volume.appending(path: "PIONEER"))
                    if !journal.rootHadContents { try fs.remove(volume.appending(path: "Contents")) }
                    try fs.syncDirectory(volume)
                    try removeAdded(volume: volume, journal: journal, fs: fs)
                    try finishRolledBack()
                }
            } else if backups.isEmpty {
                try removeAdded(volume: volume, journal: journal, fs: fs)
                try finishRolledBack()
            } else if newPresent, DJMediaValidator.validate(exportRoot: volume).isValid {
                try finishCompleted()
            } else {
                try fs.remove(volume.appending(path: "PIONEER"))
                for name in backups {
                    let backup = volume.appending(path: "\(name)\(DJExportJournal.backupInfix)\(stamp)")
                    let original = volume.appending(path: name)
                    if fs.exists(original) { try fs.remove(original) }
                    try fs.rename(backup, to: original)
                }
                try fs.syncDirectory(volume)
                try removeAdded(volume: volume, journal: journal, fs: fs)
                try finishRolledBack()
            }

        default:
            try finishRolledBack()
        }
        return report
    }

    private static func removeAdded(volume: URL, journal: DJExportJournal, fs: any DJExportFileSystem) throws {
        let contents = volume.appending(path: "Contents", directoryHint: .isDirectory)
        func removeAndSync(_ url: URL) throws {
            guard fs.exists(url) else { return }
            try fs.remove(url)
            let parent = url.deletingLastPathComponent()
            if fs.isDirectory(parent) { try fs.syncDirectory(parent) }
        }
        for relative in journal.addedToContents.reversed() {
            var url = contents.appending(path: relative)
            try removeAndSync(url)
            while url.deletingLastPathComponent().path != contents.path {
                url = url.deletingLastPathComponent()
                guard fs.isDirectory(url), try fs.list(url).isEmpty else { break }
                try removeAndSync(url)
            }
        }
        if !journal.rootHadContents, fs.isDirectory(contents), try fs.list(contents).isEmpty { try removeAndSync(contents) }
    }

    static func scrubRoots(volume: URL, journal: DJExportJournal) -> [URL] {
        let base = libraryRoot(volume: volume, journal: journal)
        return [base.appending(path: "PIONEER"), base.appending(path: ".PIONEER"), base.appending(path: "Contents")]
    }
}
