import Foundation

enum RekordboxMapping {

    static let mixInName = "Mix In"
    static let mixOutName = "Mix Out"

    static func prep(from track: RekordboxTrack, trackId: String, now: Int64, writerId: String) -> TrackPrep {
        var prep = TrackPrep(trackId: trackId)
        let segments = track.tempos.map { tempo in
            PrepTempoSegment(
                startMillis: CueTime.millis(fromSeconds: tempo.inizio),
                bpm: tempo.bpm,
                beatsPerBar: Int(tempo.metro.split(separator: "/").first ?? "4") ?? 4,
                beatInBar: tempo.battito
            )
        }
        if !segments.isEmpty {
            prep.grid = PrepField(PrepGrid(segments: compact(segments)), source: .rekordbox, updatedAtMillis: now, writerId: writerId)
        }
        if let tonality = track.tonality, let key = PrepKey(parsing: tonality) {
            prep.key = PrepField(key, source: .rekordbox, updatedAtMillis: now, writerId: writerId)
        }
        if let colour = track.colour {
            prep.colour = PrepField(colour, source: .rekordbox, updatedAtMillis: now, writerId: writerId)
        }
        if let comment = track.comments {
            prep.comment = PrepField(comment, source: .rekordbox, updatedAtMillis: now, writerId: writerId)
        }
        return prep
    }

    static func compact(_ segments: [PrepTempoSegment]) -> [PrepTempoSegment] {
        var out: [PrepTempoSegment] = []
        for segment in segments.sorted(by: { $0.startMillis < $1.startMillis }) {
            if let last = out.last, abs(last.bpm - segment.bpm) < 0.005, last.beatsPerBar == segment.beatsPerBar {
                let period = last.beatPeriodMillis
                let beats = period > 0 ? (Double(segment.startMillis - last.startMillis) / period).rounded() : 0
                let expectedInBar = ((last.beatInBar - 1 + Int(beats)) % last.beatsPerBar + last.beatsPerBar) % last.beatsPerBar + 1
                let drift = abs(Double(last.startMillis) + beats * period - Double(segment.startMillis))
                if expectedInBar == segment.beatInBar, drift <= 2 { continue }
            }
            out.append(segment)
        }
        return out
    }

    static func cues(from track: RekordboxTrack, trackId: String, now: Int64, writerId: String) -> (cues: [CuePoint], unsupported: Int) {
        var out: [CuePoint] = []
        var unsupported = 0
        for mark in track.marks {
            let start = CueTime.millis(fromSeconds: mark.start)
            let end = mark.end.map(CueTime.millis(fromSeconds:))
            let color = mark.rgb.map(CueColor.init(rgb:))
            let slot = (0..<CuePoint.hotCueSlotCount).contains(mark.num) ? mark.num : nil
            let kind: CueKind
            var hotIndex: Int?
            var id: String?
            switch (mark.type, slot) {
            case (0, nil) where mark.name == mixInName:
                kind = .mixIn
            case (0, nil) where mark.name == mixOutName:
                kind = .mixOut
            case (0, nil):
                kind = .memory
                id = "\(trackId)#memory#rekordbox#\(start)"
            case (0, let index?):
                kind = .hotCue
                hotIndex = index
            case (4, let index) where end != nil:
                kind = .loop
                hotIndex = index
                if index == nil { id = "\(trackId)#loop#rekordbox#\(start)-\(end ?? start)" }
            case (1, _):
                kind = .mixIn
            case (2, _):
                kind = .mixOut
            default:
                unsupported += 1
                continue
            }
            out.append(CuePoint(
                id: id,
                trackId: trackId,
                kind: kind,
                positionMillis: start,
                endMillis: kind == .loop ? end : nil,
                hotCueIndex: hotIndex,
                label: (kind == .mixIn || kind == .mixOut) && (mark.name == mixInName || mark.name == mixOutName) ? (kind == .mixIn ? "Mix in" : "Mix out") : mark.name,
                color: kind == .hotCue || (kind == .loop && hotIndex != nil) ? color : nil,
                createdAtMillis: now,
                updatedAtMillis: now,
                writerId: writerId,
                origin: .imported
            ))
        }
        var seen = Set<String>()
        let unique = out.reversed().filter { seen.insert($0.id).inserted }.reversed()
        return (Array(unique), unsupported)
    }

    static func track(
        link: TrackLink,
        fileURL: URL,
        prep: TrackPrep?,
        cues: [CuePoint],
        fallbackTrackId: String
    ) -> RekordboxTrack {
        var attributes: [String: String] = [
            "Name": link.title,
            "Artist": link.artist,
            "Kind": kind(for: fileURL),
            "TotalTime": String(Int((Double(link.durationMillis) / 1000).rounded())),
            "Location": RekordboxXML.location(for: fileURL),
        ]
        if let grid = prep?.grid?.value, grid.bpm > 0 { attributes["AverageBpm"] = RekordboxXML.bpm(grid.bpm) }
        if let key = prep?.key?.value { attributes["Tonality"] = key.original.isEmpty ? key.camelot : key.original }
        if let colour = prep?.colour?.value { attributes["Colour"] = String(format: "0x%06X", colour) }
        if let comment = prep?.comment?.value, !comment.isEmpty { attributes["Comments"] = comment }

        let tempos = (prep?.grid?.value.segments ?? []).map { segment in
            RekordboxTempo(
                inizio: CueTime.seconds(fromMillis: segment.startMillis),
                bpm: segment.bpm,
                metro: "\(segment.beatsPerBar)/4",
                battito: segment.beatInBar
            )
        }

        let marks = cues.filter { !$0.isDeleted }.sorted { $0.positionMillis < $1.positionMillis }.map { cue -> RekordboxMark in
            let slot = cue.hotCueIndex ?? -1
            let hasColour = cue.hotCueIndex != nil
            let name: String
            switch cue.kind {
            case .mixIn:  name = mixInName
            case .mixOut: name = mixOutName
            default:      name = cue.label
            }
            return RekordboxMark(
                name: name,
                type: cue.kind == .loop ? 4 : 0,
                start: cue.positionSeconds,
                end: cue.kind == .loop ? cue.endSeconds : nil,
                num: cue.kind == .hotCue || cue.kind == .loop ? slot : -1,
                red: hasColour ? Int(cue.color.red) : nil,
                green: hasColour ? Int(cue.color.green) : nil,
                blue: hasColour ? Int(cue.color.blue) : nil
            )
        }
        return RekordboxTrack(
            trackId: link.rekordboxTrackId ?? fallbackTrackId,
            attributes: attributes,
            tempos: tempos,
            marks: marks
        )
    }

    static func kind(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3":         return "MP3 File"
        case "m4a", "aac":  return "M4A File"
        case "wav":         return "WAV File"
        case "aif", "aiff": return "AIFF File"
        case "flac":        return "FLAC File"
        default:            return "\(url.pathExtension.uppercased()) File"
        }
    }
}

struct ImportConflict: Identifiable, Hashable, Sendable {
    enum Subject: Hashable, Sendable {
        case prep(PrepItem)
        case cue(CuePoint)
    }

    let trackId: String
    let trackTitle: String
    let subject: Subject
    let soundingValue: String
    let importedValue: String

    var id: String {
        switch subject {
        case .prep(let item): return "\(trackId)|prep|\(item)"
        case .cue(let cue):   return "\(trackId)|cue|\(cue.id)"
        }
    }

    var itemName: String {
        switch subject {
        case .prep(.grid):     return "Beat Grid"
        case .prep(.key):      return "Key"
        case .prep(.energy):   return "Energy"
        case .prep(.phrases):  return "Phrases"
        case .prep(.colour):   return "Colour"
        case .prep(.comment):  return "Comment"
        case .cue(let cue):
            switch cue.kind {
            case .hotCue: return "Hot Cue \(CuePoint.slotLetter(cue.hotCueIndex ?? 0))"
            case .loop:   return cue.hotCueIndex.map { "Hot Loop \(CuePoint.slotLetter($0))" } ?? "Loop"
            case .mixIn:  return "Mix In"
            case .mixOut: return "Mix Out"
            case .memory: return "Memory Cue"
            }
        }
    }
}

enum ImportChoice: String, Hashable, Sendable, CaseIterable {
    case keepSounding
    case useImported
}

struct RekordboxImportPreview: Sendable {
    struct Row: Identifiable, Sendable, Hashable {
        let track: RekordboxTrack
        let outcome: MatchOutcome
        var id: String { track.trackId }
    }

    let library: RekordboxLibrary
    let rows: [Row]

    var matched: [Row] { rows.filter { $0.outcome.matchedTrackId != nil } }
    var ambiguous: [Row] { rows.filter { if case .ambiguous = $0.outcome { return true }; return false } }
    var missing: [Row] { rows.filter { $0.outcome == .missing } }
}

struct RekordboxImportPlan: Sendable {
    struct Change: Sendable {
        let trackId: String
        let rekordbox: RekordboxTrack
        let prep: TrackPrep
        let cues: [CuePoint]
    }

    let changes: [Change]
    let conflicts: [ImportConflict]
    let unsupportedMarks: Int

    var cueCount: Int { changes.reduce(0) { $0 + $1.cues.count } }
}

enum RekordboxImport {

    static let sameCueToleranceMillis: Int64 = 5

    static func preview(_ library: RekordboxLibrary, candidates: [MatchCandidate], isrcByTrackId: [String: String] = [:]) -> RekordboxImportPreview {
        let index = TrackMatcher.Index(candidates)
        let rows = library.tracks.map { track in
            RekordboxImportPreview.Row(
                track: track,
                outcome: TrackMatcher.match(
                    MatchQuery(title: track.name, artist: track.artist, durationSeconds: track.totalTime, isrc: isrcByTrackId[track.trackId]),
                    in: index
                )
            )
        }
        return RekordboxImportPreview(library: library, rows: rows)
    }

    static func plan(
        pairs: [(track: RekordboxTrack, trackId: String, title: String)],
        localPreps: [String: TrackPrep],
        localCues: [String: [CuePoint]],
        writerId: String,
        now: Int64 = CueTime.nowMillis()
    ) -> RekordboxImportPlan {
        var changes: [RekordboxImportPlan.Change] = []
        var conflicts: [ImportConflict] = []
        var unsupported = 0

        for pair in pairs {
            let candidatePrep = RekordboxMapping.prep(from: pair.track, trackId: pair.trackId, now: now, writerId: writerId)
            let mapped = RekordboxMapping.cues(from: pair.track, trackId: pair.trackId, now: now, writerId: writerId)
            unsupported += mapped.unsupported

            let local = localPreps[pair.trackId]
            for item in TrackPrepPolicy.blockedItems(local: local, incoming: candidatePrep) {
                conflicts.append(ImportConflict(
                    trackId: pair.trackId,
                    trackTitle: pair.title,
                    subject: .prep(item),
                    soundingValue: describe(item, local),
                    importedValue: describe(item, candidatePrep)
                ))
            }

            let liveCues = (localCues[pair.trackId] ?? []).filter { !$0.isDeleted }
            let byId = Dictionary(liveCues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var writes: [CuePoint] = []
            for cue in mapped.cues {
                if let existing = byId[cue.id] {
                    if same(existing, cue) { continue }
                    if existing.origin == .user {
                        conflicts.append(ImportConflict(
                            trackId: pair.trackId,
                            trackTitle: pair.title,
                            subject: .cue(cue),
                            soundingValue: describe(existing),
                            importedValue: describe(cue)
                        ))
                        continue
                    }
                    writes.append(cue)
                    continue
                }
                if cue.hotCueIndex == nil, cue.kind == .memory || cue.kind == .loop,
                   liveCues.contains(where: { $0.kind == cue.kind && abs($0.positionMillis - cue.positionMillis) <= sameCueToleranceMillis }) {
                    continue
                }
                writes.append(cue)
            }
            changes.append(.init(trackId: pair.trackId, rekordbox: pair.track, prep: candidatePrep, cues: writes))
        }
        return RekordboxImportPlan(changes: changes, conflicts: conflicts, unsupportedMarks: unsupported)
    }

    static func same(_ lhs: CuePoint, _ rhs: CuePoint) -> Bool {
        guard lhs.kind == rhs.kind, lhs.hotCueIndex == rhs.hotCueIndex else { return false }
        guard abs(lhs.positionMillis - rhs.positionMillis) <= sameCueToleranceMillis else { return false }
        if let l = lhs.endMillis, let r = rhs.endMillis, abs(l - r) > sameCueToleranceMillis { return false }
        if (lhs.endMillis == nil) != (rhs.endMillis == nil) { return false }
        return lhs.label == rhs.label || rhs.label.isEmpty
    }

    static func importMerging(
        _ track: RekordboxTrack,
        trackId: String,
        title: String,
        store: CueStore,
        now: Int64 = CueTime.nowMillis()
    ) async -> (cues: Int, keptYours: Int) {
        let prep = await store.prep(forTrack: trackId)
        let cues = await store.cues(forTrack: trackId)
        let plan = plan(
            pairs: [(track: track, trackId: trackId, title: title)],
            localPreps: prep.map { [trackId: $0] } ?? [:],
            localCues: [trackId: cues],
            writerId: store.writerId,
            now: now
        )
        let result = await apply(plan, choices: [:], store: store, now: now)
        return (result.cues, plan.conflicts.count)
    }

    static func apply(
        _ plan: RekordboxImportPlan,
        choices: [String: ImportChoice],
        store: CueStore,
        now: Int64 = CueTime.nowMillis()
    ) async -> (prepared: Int, cues: Int) {
        var cueCount = 0
        for change in plan.changes {
            let result = await store.applyCandidatePrep(change.prep)
            let overrides = plan.conflicts.filter { $0.trackId == change.trackId && choices[$0.id] == .useImported }
            if !overrides.isEmpty {
                var prep = result.prep
                for conflict in overrides {
                    guard case .prep(let item) = conflict.subject else { continue }
                    switch item {
                    case .grid:
                        if var field = change.prep.grid {
                            field.value.locked = prep.grid?.value.locked ?? false
                            field.updatedAtMillis = now
                            prep.grid = field
                        }
                    case .key:     prep.key = change.prep.key.map { restamp($0, now) }
                    case .energy:  prep.energy = change.prep.energy.map { restamp($0, now) }
                    case .phrases: prep.phrases = change.prep.phrases.map { restamp($0, now) }
                    case .colour:  prep.colour = change.prep.colour.map { restamp($0, now) }
                    case .comment: prep.comment = change.prep.comment.map { restamp($0, now) }
                    }
                }
                await store.savePrep(prep)
                for conflict in overrides {
                    guard case .cue(let cue) = conflict.subject else { continue }
                    await store.upsert(cue, now: now)
                    cueCount += 1
                }
            }
            for cue in change.cues {
                await store.upsert(cue, now: now)
                cueCount += 1
            }
        }
        return (plan.changes.count, cueCount)
    }

    private static func restamp<V>(_ field: PrepField<V>, _ now: Int64) -> PrepField<V> {
        var copy = field
        copy.updatedAtMillis = now
        return copy
    }

    static func describe(_ item: PrepItem, _ prep: TrackPrep?) -> String {
        guard let prep else { return "None" }
        switch item {
        case .grid:
            guard let grid = prep.grid?.value else { return "None" }
            let first = grid.segments.first.map { String(format: ", %.2f s", CueTime.seconds(fromMillis: $0.startMillis)) } ?? ""
            return "\(String(format: "%.2f", grid.bpm)) BPM\(first)\(grid.isVariable ? ", variable" : "")"
        case .key:     return prep.key?.value.camelot ?? "None"
        case .energy:  return prep.energy.map { "\($0.value)" } ?? "None"
        case .phrases: return prep.phrases.map { "\($0.value.count) phrases" } ?? "None"
        case .colour:  return prep.colour.map { String(format: "#%06X", $0.value) } ?? "None"
        case .comment: return prep.comment?.value ?? "None"
        }
    }

    static func describe(_ cue: CuePoint) -> String {
        var text = DJFormat.time(cue.positionSeconds)
        if let end = cue.endSeconds { text += "–\(DJFormat.time(end))" }
        if !cue.label.isEmpty { text += " \(cue.label)" }
        return text
    }

    static func playlists(from library: RekordboxLibrary, trackIdByRekordboxId: [String: String]) -> [RekordboxPlaylistRecord] {
        library.flattenedPlaylists().enumerated().compactMap { index, playlist in
            let ids = playlist.trackIds.compactMap { trackIdByRekordboxId[$0] }
            guard !ids.isEmpty else { return nil }
            return RekordboxPlaylistRecord(
                id: "\(index)#" + (playlist.path + [playlist.name]).joined(separator: "/"),
                name: playlist.name,
                path: playlist.path,
                trackIds: ids
            )
        }
    }
}

struct RekordboxExportItem: Sendable {
    let link: TrackLink
    let fileURL: URL
    let prep: TrackPrep?
    let cues: [CuePoint]
    let pendingSuggestions: Int
}

struct RekordboxExportSummary: Equatable, Sendable {
    var tracks = 0
    var cues = 0
    var skippedSoundCloudOnly = 0
    var droppedPhrases = 0
    var droppedEnergy = 0
    var droppedSuggestions = 0
    var droppedMemoryColours = 0
}

enum RekordboxExport {

    static func library(_ items: [RekordboxExportItem], playlistName: String = "Sounding", version: String = "") -> RekordboxLibrary {
        var usedIds = Set<String>()
        var tracks: [RekordboxTrack] = []
        for item in items {
            var candidate = item.link.rekordboxTrackId ?? numericId(for: item.link.trackId)
            while usedIds.contains(candidate) { candidate = String((Int(candidate) ?? 0) &+ 1) }
            usedIds.insert(candidate)
            var track = RekordboxMapping.track(link: item.link, fileURL: item.fileURL, prep: item.prep, cues: item.cues, fallbackTrackId: candidate)
            track.trackId = candidate
            tracks.append(track)
        }
        return RekordboxLibrary(
            productName: "Sounding",
            productVersion: version,
            productCompany: "Sounding",
            tracks: tracks,
            playlists: [.playlist(name: playlistName, keyType: 0, trackKeys: tracks.map(\.trackId))]
        )
    }

    static func numericId(for trackId: String) -> String {
        if let value = Int(trackId.filter(\.isNumber).suffix(9)), value > 0 { return String(value) }
        var hash: UInt32 = 2_166_136_261
        for byte in trackId.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(hash % 900_000_000 + 1)
    }

    static func summary(_ items: [RekordboxExportItem], skipped: Int) -> RekordboxExportSummary {
        var summary = RekordboxExportSummary()
        summary.tracks = items.count
        summary.skippedSoundCloudOnly = skipped
        for item in items {
            summary.cues += item.cues.filter { !$0.isDeleted }.count
            if let phrases = item.prep?.phrases?.value, !phrases.isEmpty { summary.droppedPhrases += 1 }
            if item.prep?.energy != nil { summary.droppedEnergy += 1 }
            summary.droppedSuggestions += item.pendingSuggestions
            summary.droppedMemoryColours += item.cues.filter {
                !$0.isDeleted && $0.kind == .memory && $0.color != .memory
            }.count
        }
        return summary
    }
}

// MARK: - rekordbox analysis folder

struct RekordboxShareLocalFile: Hashable, Sendable {
    var trackId: String
    var path: String
    var durationSeconds: Double?
}

struct RekordboxShareKey: Hashable, Sendable {
    var id: String
    var fileName: String
    var devicePath: String
    var durationSeconds: Double?
    var richness: Int

    var stem: String { (fileName as NSString).deletingPathExtension }
}

enum RekordboxShareOutcome: Hashable, Sendable {
    case path(String)
    case fileName(String)
    case title(String)
    case ambiguous
    case missing

    var trackId: String? {
        switch self {
        case .path(let id), .fileName(let id), .title(let id): return id
        case .ambiguous, .missing: return nil
        }
    }
}

struct RekordboxShareResolution: Sendable {
    var key: RekordboxShareKey
    var outcome: RekordboxShareOutcome
    var xml: RekordboxTrack?
}

struct RekordboxShareSummary: Equatable, Sendable {
    var analysed = 0
    var byPath = 0
    var byFileName = 0
    var byTitle = 0
    var ambiguous = 0
    var missing = 0
    var withXML = 0

    var matched: Int { byPath + byFileName + byTitle }
}

enum RekordboxShareMatcher {
    static let durationTolerance: TimeInterval = 2

    static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func match(
        _ keys: [RekordboxShareKey],
        files: [RekordboxShareLocalFile],
        xml: RekordboxLibrary? = nil,
        candidates: [MatchCandidate] = []
    ) -> [RekordboxShareResolution] {
        let byPath = Dictionary(grouping: files) { normalisedPath($0.path) }
        let byName = Dictionary(grouping: files) { nameKey(($0.path as NSString).lastPathComponent) }
        let xmlByName = Dictionary(grouping: xml?.tracks ?? []) { nameKey($0.fileURL?.lastPathComponent ?? "") }
        let index = TrackMatcher.Index(candidates)
        var out: [RekordboxShareResolution] = []
        for key in keys {
            let name = nameKey(key.fileName)
            let xmlTrack = pick(xmlByName[name] ?? [], duration: key.durationSeconds) { $0.totalTime > 0 ? $0.totalTime : nil }
            var outcome: RekordboxShareOutcome = .missing
            let fullPath = xmlTrack?.fileURL?.path ?? (key.devicePath.hasPrefix("/") ? key.devicePath : nil)
            if let fullPath, let file = pick(byPath[normalisedPath(fullPath)] ?? [], duration: key.durationSeconds, { $0.durationSeconds }) {
                outcome = .path(file.trackId)
            } else {
                let named = byName[name] ?? []
                if let file = pick(named, duration: key.durationSeconds, { $0.durationSeconds }) {
                    outcome = .fileName(file.trackId)
                } else if Set(named.map(\.trackId)).count > 1 {
                    outcome = .ambiguous
                }
            }
            if outcome == .missing {
                let query = MatchQuery(
                    title: xmlTrack?.name ?? key.stem,
                    artist: xmlTrack?.artist ?? "",
                    durationSeconds: key.durationSeconds ?? xmlTrack?.totalTime ?? 0,
                    isrc: nil
                )
                switch TrackMatcher.match(query, in: index) {
                case .matched(let id): outcome = .title(id)
                case .ambiguous: outcome = .ambiguous
                case .missing: break
                }
            }
            out.append(RekordboxShareResolution(key: key, outcome: outcome, xml: xmlTrack))
        }
        return deduplicated(out)
    }

    static func summary(_ resolutions: [RekordboxShareResolution]) -> RekordboxShareSummary {
        var s = RekordboxShareSummary()
        s.analysed = resolutions.count
        for resolution in resolutions {
            if resolution.xml != nil { s.withXML += 1 }
            switch resolution.outcome {
            case .path: s.byPath += 1
            case .fileName: s.byFileName += 1
            case .title: s.byTitle += 1
            case .ambiguous: s.ambiguous += 1
            case .missing: s.missing += 1
            }
        }
        return s
    }

    static func normalisedPath(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        let trimmed = standard.hasPrefix("/private/var/") ? String(standard.dropFirst(8)) : standard
        return trimmed.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func pick<T>(_ items: [T], duration: Double?, _ itemDuration: (T) -> Double?) -> T? {
        guard !items.isEmpty else { return nil }
        let fitting = items.filter { item in
            guard let duration, let other = itemDuration(item) else { return true }
            return abs(duration - other) <= durationTolerance
        }
        if fitting.count == 1 { return fitting[0] }
        guard fitting.count > 1, let duration else { return nil }
        let timed = fitting.compactMap { item in itemDuration(item).map { (item, abs($0 - duration)) } }
        guard timed.count == fitting.count else { return nil }
        let sorted = timed.sorted { $0.1 < $1.1 }
        return sorted[0].1 < sorted[1].1 ? sorted[0].0 : nil
    }

    private static func deduplicated(_ resolutions: [RekordboxShareResolution]) -> [RekordboxShareResolution] {
        var best: [String: Int] = [:]
        for (index, resolution) in resolutions.enumerated() {
            guard let id = resolution.outcome.trackId else { continue }
            if let current = best[id] {
                if resolution.key.richness > resolutions[current].key.richness { best[id] = index }
            } else {
                best[id] = index
            }
        }
        return resolutions.enumerated().map { index, resolution in
            guard let id = resolution.outcome.trackId, best[id] != index else { return resolution }
            var copy = resolution
            copy.outcome = .ambiguous
            return copy
        }
    }
}

struct RekordboxKeyAgreement: Equatable, Sendable {
    var compared = 0
    var exact = 0
    var relative = 0
    var neighbour = 0

    var exactRate: Double { compared == 0 ? 0 : Double(exact) / Double(compared) }
    var closeRate: Double { compared == 0 ? 0 : Double(exact + relative + neighbour) / Double(compared) }

    enum Relation: Equatable, Sendable {
        case exact
        case relative
        case neighbour
        case other
    }

    static func relation(ours: String, theirs: String) -> Relation? {
        guard let a = CamelotKey.parse(ours), let b = CamelotKey.parse(theirs) else { return nil }
        if a == b { return .exact }
        if a.wheelPosition == b.wheelPosition { return .relative }
        let step = (a.wheelPosition - b.wheelPosition + 12) % 12
        if a.mode == b.mode, step == 1 || step == 11 { return .neighbour }
        return .other
    }

    mutating func add(ours: String, theirs: String) {
        guard let relation = Self.relation(ours: ours, theirs: theirs) else { return }
        compared += 1
        switch relation {
        case .exact: exact += 1
        case .relative: relative += 1
        case .neighbour: neighbour += 1
        case .other: break
        }
    }
}
