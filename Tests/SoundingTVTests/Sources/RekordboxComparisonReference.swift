import Foundation
#if os(macOS)
@testable import SoundingTV_macOS
#else
@testable import SoundingTV
#endif

struct RekordboxReferenceTrack: Sendable {
    let anlzID: String
    let devicePath: String
    let durationSeconds: Double?
    let beats: [ANLZBeat]
    let phrases: [RekordboxSharePhrase]
    let phraseEndSeconds: Double?
    let mood: Int?
    let cueSeconds: [Double]
    var audioPath: String?
    var match = "missing"
    var xml: RekordboxTrack?

    var fileName: String { RekordboxShareLayout.fileName(fromDevicePath: devicePath) }
    var beatTimes: [Double] { beats.map(\.seconds) }
    var downbeatTimes: [Double] { beats.filter { $0.beatNumber == 1 }.map(\.seconds) }
    var phraseStarts: [Double] { phrases.map { Double($0.startMillis) / 1000 } }
    var phraseLabels: [String] { phrases.map { RekordboxPhraseCode(mood: $0.mood, kind: $0.kind).label } }

    var allCueSeconds: [Double] {
        var out: [Double] = []
        for t in (cueSeconds + (xml?.marks.map(\.start) ?? [])).sorted() where out.last.map({ t - $0 > 0.05 }) ?? true {
            out.append(t)
        }
        return out
    }

    var dominantBPM: Double? {
        guard beats.count >= 2 else { return beats.first.map(\.bpm) }
        var weight: [Int: Double] = [:]
        for i in 0 ..< beats.count - 1 where beats[i].tempo > 0 {
            weight[Int(beats[i].tempo), default: 0] += max(0, beats[i + 1].seconds - beats[i].seconds)
        }
        return weight.max { $0.value < $1.value }.map { Double($0.key) / 100 }
    }

    var tempoSegments: [(start: Double, bpm: Double, beats: Int)] {
        var out: [(start: Double, bpm: Double, beats: Int)] = []
        for beat in beats where beat.tempo > 0 {
            if let last = out.last, abs(last.bpm - beat.bpm) < 0.005 {
                out[out.count - 1].beats += 1
            } else {
                out.append((beat.seconds, beat.bpm, 1))
            }
        }
        return out
    }

    var hasVariableTempo: Bool {
        let lasting = tempoSegments.filter { $0.beats >= 4 }.map(\.bpm)
        guard let low = lasting.min(), let high = lasting.max() else { return false }
        return lasting.count >= 2 && high - low >= 0.3
    }

    var medianBeatPeriod: Double {
        let times = beatTimes
        guard times.count >= 2 else { return 0.5 }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        return gaps.isEmpty ? 0.5 : gaps[gaps.count / 2]
    }

    var introEndSeconds: Double? {
        let labels = phraseLabels
        guard !labels.isEmpty else { return nil }
        let starts = phraseStarts
        guard labels[0] == "Intro" else { return starts.first }
        let firstOther = labels.firstIndex { $0 != "Intro" }
        return firstOther.map { starts[$0] } ?? phraseEndSeconds
    }

    var outroStartSeconds: Double? {
        let labels = phraseLabels
        guard !labels.isEmpty else { return nil }
        let starts = phraseStarts
        guard labels.last == "Outro" else { return phraseEndSeconds ?? beatTimes.last }
        var index = labels.count - 1
        while index > 0, labels[index - 1] == "Outro" { index -= 1 }
        return starts[index]
    }
}

struct RekordboxReferenceScan: Sendable {
    var tracks: [RekordboxReferenceTrack] = []
    var unreadable: [String] = []
    var pairs = 0
    var audioFilesIndexed = 0
}

enum RekordboxReferenceLoader {
    static func realHome() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    static func defaultRoot() -> String {
        RekordboxShareLayout.defaultRoot(home: realHome())
    }

    static func defaultMusicRoots() -> [String] {
        [realHome() + "/Music"]
    }

    static func analysisFiles(root: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        while let relative = walker.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent.uppercased()
            guard name.hasPrefix("ANLZ"), name.hasSuffix(".DAT") else { continue }
            out.append(root + "/" + relative)
        }
        return out.sorted()
    }

    static func audioFiles(roots: [String]) -> [String] {
        var out: [String] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(atPath: root) else { continue }
            while let relative = walker.nextObject() as? String {
                let path = root + "/" + relative
                if LocalMusicScanner.isSupported(URL(fileURLWithPath: path)) { out.append(path) }
            }
        }
        return out
    }

    static func readANLZ(_ path: String) -> ANLZFile? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? ANLZCodec.read(data).file
    }

    static func sibling(of datPath: String, extension ext: String) -> String? {
        let stem = (datPath as NSString).deletingPathExtension
        for candidate in [stem + "." + ext.uppercased(), stem + "." + ext.lowercased()] where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static func scan(root: String) -> RekordboxReferenceScan {
        var scan = RekordboxReferenceScan()
        for datPath in analysisFiles(root: root) {
            scan.pairs += 1
            guard let dat = readANLZ(datPath) else {
                scan.unreadable.append(datPath)
                continue
            }
            let ext = sibling(of: datPath, extension: "EXT").flatMap(readANLZ)
            guard let track = reference(id: String(datPath.dropFirst(root.count + 1)), dat: dat, ext: ext) else {
                scan.unreadable.append(datPath)
                continue
            }
            scan.tracks.append(track)
        }
        return scan
    }

    static func reference(id: String, dat: ANLZFile, ext: ANLZFile?) -> RekordboxReferenceTrack? {
        guard let path = dat.path ?? ext?.path, !path.isEmpty else { return nil }
        let beats = dat.beatGrid ?? ext?.beatGrid ?? []
        var duration: Double?
        for case .waveformDetail(let detail) in (ext?.tags ?? []) + dat.tags where !detail.isEmpty {
            duration = Double(detail.count) / RekordboxShareLayout.detailEntriesPerSecond
            break
        }
        if duration == nil, let last = beats.last { duration = last.seconds }
        var phrases: [RekordboxSharePhrase] = []
        var mood: Int?
        var phraseEnd: Double?
        if let structure = ext?.songStructure ?? dat.songStructure, !beats.isEmpty {
            mood = Int(structure.mood)
            phrases = RekordboxShareScanner.phrases(structure, beats: beats)
            phraseEnd = RekordboxShareScanner.millis(ofBeat: Int(structure.endBeat), beats: beats).map { Double($0) / 1000 }
        }
        var cues: [ANLZCue] = []
        for kind in [ANLZCueListKind.memory, .hotCues] {
            if let list = ext?.cueList(kind, extended: true) ?? dat.cueList(kind, extended: true) ?? dat.cueList(kind, extended: false) {
                cues += list.cues
            }
        }
        return RekordboxReferenceTrack(
            anlzID: id,
            devicePath: path,
            durationSeconds: duration,
            beats: beats,
            phrases: phrases,
            phraseEndSeconds: phraseEnd,
            mood: mood,
            cueSeconds: cues.map { Double($0.timeMillis) / 1000 }.sorted(),
            audioPath: path.hasPrefix("/") ? path : nil
        )
    }

    static func xmlLibrary(path: String) throws -> RekordboxLibrary {
        try RekordboxXML.parse(Data(contentsOf: URL(fileURLWithPath: path)))
    }

    static func resolveAudio(_ scan: inout RekordboxReferenceScan, xml: RekordboxLibrary?, musicRoots: [String]) {
        var paths = audioFiles(roots: musicRoots)
        paths += scan.tracks.compactMap(\.audioPath)
        paths += (xml?.tracks ?? []).compactMap { $0.fileURL?.path(percentEncoded: false) }
        var seen = Set<String>()
        let files = paths
            .filter { FileManager.default.isReadableFile(atPath: $0) && seen.insert(RekordboxShareMatcher.normalisedPath($0)).inserted }
            .map { RekordboxShareLocalFile(trackId: $0, path: $0, durationSeconds: nil) }
        scan.audioFilesIndexed = files.count
        let keys = scan.tracks.map {
            RekordboxShareKey(
                id: $0.anlzID,
                fileName: $0.fileName,
                devicePath: $0.devicePath,
                durationSeconds: $0.durationSeconds,
                richness: $0.cueSeconds.count * 4 + $0.phrases.count * 2 + ($0.beats.isEmpty ? 0 : 1)
            )
        }
        let resolutions = Dictionary(
            RekordboxShareMatcher.match(keys, files: files, xml: xml).map { ($0.key.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for index in scan.tracks.indices {
            guard let resolution = resolutions[scan.tracks[index].anlzID] else { continue }
            scan.tracks[index].xml = resolution.xml
            switch resolution.outcome {
            case .path(let path):
                scan.tracks[index].audioPath = path
                scan.tracks[index].match = "path"
            case .fileName(let path):
                scan.tracks[index].audioPath = path
                scan.tracks[index].match = "file name"
            case .title, .missing:
                scan.tracks[index].audioPath = nil
                scan.tracks[index].match = "missing"
            case .ambiguous:
                scan.tracks[index].audioPath = nil
                scan.tracks[index].match = "ambiguous"
            }
        }
    }
}
