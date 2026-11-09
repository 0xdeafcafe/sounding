import Foundation

enum RekordboxShareLayout {
    static let analysisFolder = "Library/Pioneer/rekordbox/share/PIONEER/USBANLZ"
    static let readExtensions = ["DAT", "EXT", "2EX"]
    static let maxAnalysisFiles = 200_000
    static let detailEntriesPerSecond = 150.0

    static func defaultRoot(home: String) -> String {
        (home.hasSuffix("/") ? String(home.dropLast()) : home) + "/" + analysisFolder
    }

    static func analysisRoot(within chosen: String, exists: (String) -> Bool) -> String? {
        let base = chosen.hasSuffix("/") ? String(chosen.dropLast()) : chosen
        let tails = ["", "/USBANLZ", "/PIONEER/USBANLZ", "/share/PIONEER/USBANLZ", "/rekordbox/share/PIONEER/USBANLZ", "/Pioneer/rekordbox/share/PIONEER/USBANLZ", "/" + analysisFolder]
        for tail in tails {
            let candidate = base + tail
            if (candidate as NSString).lastPathComponent == "USBANLZ", exists(candidate) { return candidate }
        }
        return nil
    }

    static func fileName(fromDevicePath path: String) -> String {
        let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
        return name.precomposedStringWithCanonicalMapping
    }

    static func matchKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}

struct RekordboxSharePhrase: Equatable, Sendable {
    var startMillis: Int64
    var mood: Int
    var kind: Int
}

extension DJExportPhrase.Kind {
    static func rekordbox(mood: Int, kind: Int) -> DJExportPhrase.Kind {
        switch (mood, kind) {
        case (_, 1): return .intro
        case (1, 2): return .up
        case (1, 3): return .down
        case (1, 5): return .chorus
        case (1, 6): return .outro
        case (2, 2 ... 7): return .verse(kind - 1)
        case (3, 2 ... 4): return .verse(1)
        case (3, 5 ... 7): return .verse(2)
        case (2 ... 3, 8): return .bridge
        case (2 ... 3, 9): return .chorus
        case (2 ... 3, 10): return .outro
        default: return mood == 1 ? .up : .verse(1)
        }
    }
}

extension DJExportPhrases {
    init?(rekordbox phrases: [RekordboxSharePhrase], durationSeconds: Double) {
        let sorted = phrases.sorted { $0.startMillis < $1.startMillis }
        guard let first = sorted.first, let mood = ANLZMood(rawValue: UInt16(clamping: first.mood)),
              sorted.allSatisfy({ $0.mood == first.mood }) else { return nil }
        self.init(
            mood: mood,
            phrases: sorted.map { DJExportPhrase(startSeconds: Double($0.startMillis) / 1000, kind: .rekordbox(mood: $0.mood, kind: $0.kind)) },
            endSeconds: durationSeconds
        )
    }
}

struct RekordboxShareEntry: Identifiable, Equatable, Sendable {
    var id: String
    var devicePath: String
    var fileName: String
    var durationSeconds: Double?
    var analysis: DJStickAnalysis
    var phrases: [RekordboxSharePhrase]
    var mood: Int?
    var phraseEndMillis: Int64?
    var hasThreeBandWaveform: Bool
    var hasVocalAnalysis: Bool

    var stem: String { (fileName as NSString).deletingPathExtension }
    var hasGrid: Bool { !analysis.tempos.isEmpty }
    var hotCueCount: Int { analysis.marks.filter { $0.slot != nil }.count }
    var memoryCount: Int { analysis.marks.filter { $0.slot == nil }.count }
    var loopCount: Int { analysis.marks.filter { $0.kind == .loop }.count }
}

struct RekordboxShareScan: Equatable, Sendable {
    var entries: [RekordboxShareEntry] = []
    var unreadable = 0

    var withGrid: Int { entries.filter(\.hasGrid).count }
    var withCues: Int { entries.filter { !$0.analysis.marks.isEmpty }.count }
    var withPhrases: Int { entries.filter { !$0.phrases.isEmpty }.count }
    var withThreeBand: Int { entries.filter(\.hasThreeBandWaveform).count }
    var withVocals: Int { entries.filter(\.hasVocalAnalysis).count }
    var cueCount: Int { entries.reduce(0) { $0 + $1.analysis.marks.count } }
}

enum RekordboxShareScanner {
    static func scan(root: String, io: DJStickIO = DJStickPOSIXIO(), list: (String) -> [String] = RekordboxShareScanner.listDirectory) -> RekordboxShareScan {
        var scan = RekordboxShareScan()
        var stack: [(path: String, relative: String, depth: Int)] = [(root, "", 0)]
        var seen = 0
        while let folder = stack.popLast() {
            let names = list(folder.path).filter { !$0.hasPrefix(".") }.sorted()
            var stems: [String] = []
            for name in names {
                let path = folder.path + "/" + name
                let upper = name.uppercased()
                if upper.hasPrefix("ANLZ"), upper.hasSuffix(".DAT") {
                    stems.append(String(name.dropLast(4)))
                } else if folder.depth < 3, !upper.contains("."), io.stamp(atPath: path) == nil {
                    stack.append((path, folder.relative.isEmpty ? name : folder.relative + "/" + name, folder.depth + 1))
                }
            }
            for stem in stems {
                seen += 1
                guard seen <= RekordboxShareLayout.maxAnalysisFiles else { return scan }
                let id = (folder.relative.isEmpty ? "" : folder.relative + "/") + stem
                if let entry = read(id: id, base: folder.path + "/" + stem, names: Set(names), stem: stem, io: io) {
                    scan.entries.append(entry)
                } else {
                    scan.unreadable += 1
                }
            }
        }
        scan.entries.sort { $0.id < $1.id }
        return scan
    }

    static func listDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    static func read(id: String, base: String, names: Set<String>, stem: String, io: DJStickIO) -> RekordboxShareEntry? {
        func file(_ ext: String) -> ANLZFile? {
            let candidates = [stem + "." + ext, stem + "." + ext.lowercased()]
            guard let name = candidates.first(where: { names.contains($0) }) else { return nil }
            let path = (base as NSString).deletingLastPathComponent + "/" + name
            guard let data = try? io.readFile(atPath: path, maxBytes: DJStickLayout.maxAnalysisBytes) else { return nil }
            return try? ANLZCodec.read(data).file
        }
        guard let dat = file("DAT") else { return nil }
        let ext = file("EXT")
        let twoEx = file("2EX")
        return entry(id: id, dat: dat, ext: ext, twoEx: twoEx)
    }

    static func entry(id: String, dat: ANLZFile, ext: ANLZFile?, twoEx: ANLZFile?) -> RekordboxShareEntry? {
        guard let devicePath = dat.path ?? ext?.path ?? twoEx?.path, !devicePath.isEmpty else { return nil }
        let beats = dat.beatGrid ?? ext?.beatGrid ?? []
        var duration: Double?
        for case .waveformDetail(let detail) in (ext?.tags ?? []) + dat.tags where !detail.isEmpty {
            duration = Double(detail.count) / RekordboxShareLayout.detailEntriesPerSecond
            break
        }
        if duration == nil, let last = beats.last { duration = Double(last.timeMillis) / 1000 }
        var phrases: [RekordboxSharePhrase] = []
        var mood: Int?
        var phraseEnd: Int64?
        if let structure = ext?.songStructure ?? dat.songStructure, !beats.isEmpty {
            mood = Int(structure.mood)
            phrases = self.phrases(structure, beats: beats)
            phraseEnd = millis(ofBeat: Int(structure.endBeat), beats: beats)
        }
        let hasThreeBand = twoEx?.threeBandPreview?.isEmpty == false || twoEx?.threeBandDetail?.isEmpty == false
        let hasVocals = twoEx?.tag("PVDI") != nil || ext?.tag("PVDI") != nil
        return RekordboxShareEntry(
            id: id,
            devicePath: devicePath,
            fileName: RekordboxShareLayout.fileName(fromDevicePath: devicePath),
            durationSeconds: duration,
            analysis: DJStickAnalysis.summarise(dat: dat, ext: ext),
            phrases: phrases,
            mood: mood,
            phraseEndMillis: phraseEnd,
            hasThreeBandWaveform: hasThreeBand,
            hasVocalAnalysis: hasVocals
        )
    }

    static func phrases(_ structure: ANLZSongStructure, beats: [ANLZBeat]) -> [RekordboxSharePhrase] {
        var out: [RekordboxSharePhrase] = []
        for phrase in structure.phrases.sorted(by: { $0.beat < $1.beat }) {
            guard let start = millis(ofBeat: Int(phrase.beat), beats: beats) else { continue }
            if let last = out.last, last.startMillis >= start { continue }
            out.append(RekordboxSharePhrase(startMillis: start, mood: Int(structure.mood), kind: Int(phrase.kind)))
        }
        return out
    }

    static func millis(ofBeat beat: Int, beats: [ANLZBeat]) -> Int64? {
        guard beat >= 1, !beats.isEmpty else { return nil }
        return Int64(beats[min(beat, beats.count) - 1].timeMillis)
    }
}
