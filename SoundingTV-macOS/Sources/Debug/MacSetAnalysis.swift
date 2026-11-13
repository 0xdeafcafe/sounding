import AppKit
import Foundation

#if DEBUG
enum MacSetAnalysis {
    private struct Cue: Codable {
        var seconds: Double
        var label: String?
        var earliest: Double?
        var latest: Double?
    }

    private struct Source: Codable {
        var id: String
        var title: String
        var artist: String
        var genre: String?
        var origin: String
        var durationSeconds: Double
        var cues: [Cue]
    }

    private struct Candidate: Codable {
        var trackID: String
        var fileExtension: String
        var fileBytes: Int64
        var source: Source
    }

    private enum Failure: Error, CustomStringConvertible {
        case otherInstance
        case noAccount
        case noIndex
        case unreadableIndex
        case noKey
        case notDownloaded(String)
        case unwritable(String)

        var description: String {
            switch self {
            case .otherInstance: return "Sounding is open, quit it and I'll resume"
            case .noAccount: return "no cached account"
            case .noIndex: return "no download index"
            case .unreadableIndex: return "download index could not be opened"
            case .noKey: return "download key unavailable"
            case .notDownloaded(let id): return "track \(id) is not downloaded"
            case .unwritable(let path): return "cannot write \(path)"
            }
        }
    }

    private static let accountKey = "red.forbes.sounding.lockedCacheAccountID"
    private static var minimumSeconds: Double {
        ProcessInfo.processInfo.environment["SOUNDING_TV_SET_ANALYSIS_MIN_SECONDS"].flatMap(Double.init) ?? 30 * 60
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["SOUNDING_TV_SET_ANALYSIS"] != nil
    }

    static func runAndExit() -> Never {
        let environment = ProcessInfo.processInfo.environment
        Task { @MainActor in
            let code: Int32
            do {
                try run(environment)
                code = 0
            } catch let failure as Failure {
                emit("ERROR \(failure)")
                if case .otherInstance = failure { code = 3 } else { code = 2 }
            } catch {
                emit("ERROR \(type(of: error))")
                code = 2
            }
            exit(code)
        }
        dispatchMain()
    }

    @MainActor
    private static func run(_ environment: [String: String]) throws {
        try ensureOnlyInstance()
        let output = try outputDirectory(environment["SOUNDING_TV_SET_ANALYSIS"] ?? "")
        emit("OUT \(output.path)")
        let step = environment["SOUNDING_TV_SET_ANALYSIS_STEP"] ?? "list"
        let (accountID, directory, entries) = try loadIndex()
        if step == "list" {
            try list(entries: entries, accountID: accountID, directory: directory, output: output)
        } else if step.hasPrefix("decrypt:") {
            try ensureOnlyInstance()
            try decrypt(trackID: String(step.dropFirst("decrypt:".count)), entries: entries, accountID: accountID, directory: directory, output: output)
        }
    }

    @MainActor
    private static func ensureOnlyInstance() throws {
        let own = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != own else { return false }
            if app.bundleIdentifier == Bundle.main.bundleIdentifier { return true }
            return app.localizedName == "Sounding" || app.executableURL?.lastPathComponent == "Sounding"
        }
        if !others.isEmpty { throw Failure.otherInstance }
    }

    private static func outputDirectory(_ requested: String) throws -> URL {
        let fileManager = FileManager.default
        if !requested.isEmpty, requested != "-" {
            let url = URL(fileURLWithPath: requested, isDirectory: true)
            if (try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)) != nil,
               fileManager.isWritableFile(atPath: url.path) {
                return url
            }
        }
        let fallback = fileManager.temporaryDirectory.appendingPathComponent("SetAnalysis", isDirectory: true)
        do {
            try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        } catch {
            throw Failure.unwritable(fallback.path)
        }
        return fallback
    }

    private static func loadIndex() throws -> (String, URL, [String: DownloadEntry]) {
        guard let accountID = UserDefaults.sounding.string(forKey: accountKey), !accountID.isEmpty else {
            throw Failure.noAccount
        }
        guard let support = FileManager.default.soundingDirectory(.applicationSupportDirectory) else {
            throw Failure.noIndex
        }
        let directory = DownloadStoragePolicy.accountDirectory(
            root: support.appendingPathComponent("Downloads", isDirectory: true),
            accountID: accountID
        )
        let indexURL = directory.appendingPathComponent(DownloadStoragePolicy.accountIndexFileName)
        guard let sealed = try? Data(contentsOf: indexURL) else { throw Failure.noIndex }
        guard let data = AccountDataVault.open(sealed, accountID: accountID, purpose: "download-index-v1"),
              let entries = try? JSONDecoder().decode([String: DownloadEntry].self, from: data) else {
            throw Failure.unreadableIndex
        }
        return (accountID, directory, entries)
    }

    private static func isUsable(_ entry: DownloadEntry, accountID: String, directory: URL) -> Bool {
        guard let fileName = entry.fileName, entry.encryptionAccountID == accountID else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
    }

    private static func list(entries: [String: DownloadEntry], accountID: String, directory: URL, output: URL) throws {
        let downloaded = entries.values.filter { isUsable($0, accountID: accountID, directory: directory) }
        let sets = downloaded.filter { $0.track.duration >= minimumSeconds }
        let candidates = sets.map { entry -> Candidate in
            let track = entry.track
            let described = DeckIdentityResolver.descriptionIdentities(for: track).compactMap { identity -> Cue? in
                identity.startsAt.map { Cue(seconds: $0, label: identity.label) }
            }
            let scanned = setlistCues(trackID: track.id)
            let cues = described.count >= 2 ? described : scanned
            let origin = described.count >= 2 ? "description" : (scanned.count >= 2 ? "setlist" : "none")
            let source = Source(
                id: "sc-\(track.id)",
                title: track.title,
                artist: track.user.username,
                genre: track.genre,
                origin: "download:\(track.id) tracklist:\(origin)",
                durationSeconds: track.duration,
                cues: cues
            )
            return Candidate(
                trackID: track.id,
                fileExtension: entry.originalFileExtension ?? "audio",
                fileBytes: entry.fileSize,
                source: source
            )
        }
        .sorted { ($0.source.cues.count, $0.source.durationSeconds) > ($1.source.cues.count, $1.source.durationSeconds) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(candidates).write(to: output.appendingPathComponent("candidates.json"))
        emit("LIST downloaded=\(downloaded.count) sets=\(candidates.count) withTracklist=\(candidates.filter { $0.source.cues.count >= 2 }.count)")
    }

    private static func setlistCues(trackID: String) -> [Cue] {
        guard let support = FileManager.default.soundingDirectory(.applicationSupportDirectory) else { return [] }
        let safe = trackID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trackID
        let url = support.appendingPathComponent("Setlists", isDirectory: true).appendingPathComponent("\(safe).json")
        guard let data = try? Data(contentsOf: url),
              let setlist = try? JSONDecoder().decode(GeneratedSetlist.self, from: data) else { return [] }
        struct Run {
            var key: String
            var label: String
            var start: Double
            var firstSeen: Double
            var lastSeen: Double
        }
        var runs: [Run] = []
        for entry in Tracklist(setlist).entries {
            let segment = entry.segment
            let label = [segment.artist, segment.title].compactMap { $0 }.joined(separator: " – ")
            let key = label.lowercased()
            let seen = segment.observedAtSeconds
            if let last = runs.last, last.key == key {
                runs[runs.count - 1].lastSeen = max(last.lastSeen, seen)
                runs[runs.count - 1].firstSeen = min(last.firstSeen, seen)
                continue
            }
            runs.append(Run(key: key, label: label, start: segment.startSeconds, firstSeen: seen, lastSeen: seen))
        }
        var cues: [Cue] = []
        for (previous, next) in zip(runs, runs.dropFirst()) {
            let earliest = previous.lastSeen
            let latest = next.firstSeen
            guard latest - earliest >= 20 else { continue }
            cues.append(Cue(seconds: min(latest, max(earliest, next.start)), label: next.label, earliest: earliest, latest: latest))
        }
        return cues
    }

    private static func decrypt(trackID: String, entries: [String: DownloadEntry], accountID: String, directory: URL, output: URL) throws {
        guard let entry = entries[trackID], isUsable(entry, accountID: accountID, directory: directory),
              let fileName = entry.fileName else {
            throw Failure.notDownloaded(trackID)
        }
        guard let key = DownloadVault.key(for: accountID, createIfMissing: false) else { throw Failure.noKey }
        let audioDirectory = output.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let destination = audioDirectory.appendingPathComponent("\(trackID).\(entry.originalFileExtension ?? "audio")")
        try DownloadVault.decryptFile(at: directory.appendingPathComponent(fileName), to: destination, using: key)
        emit("AUDIO \(destination.path)")
    }

    private static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

#endif
