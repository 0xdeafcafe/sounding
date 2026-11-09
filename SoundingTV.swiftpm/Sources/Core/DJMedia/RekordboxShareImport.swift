import Foundation

extension DJExportPhrases {
    init?(prepPhrases: [PrepPhrase], durationSeconds: Double) {
        let codes = prepPhrases.compactMap { phrase in
            phrase.rekordbox.map { RekordboxSharePhrase(startMillis: phrase.startMillis, mood: $0.mood, kind: $0.kind) }
        }
        guard !codes.isEmpty, codes.count == prepPhrases.count else { return nil }
        self.init(rekordbox: codes, durationSeconds: durationSeconds)
    }
}

extension RekordboxShareEntry {
    var matchKey: RekordboxShareKey {
        RekordboxShareKey(
            id: id,
            fileName: fileName,
            devicePath: devicePath,
            durationSeconds: durationSeconds,
            richness: analysis.marks.count * 4 + phrases.count * 2 + analysis.tempos.count + (hasGrid ? 1 : 0)
        )
    }
}

struct RekordboxShareMatch: Identifiable, Sendable {
    var entry: RekordboxShareEntry
    var outcome: RekordboxShareOutcome
    var xml: RekordboxTrack?

    var id: String { entry.id }
    var trackId: String? { outcome.trackId }
}

enum RekordboxShareMapping {
    static func match(
        _ entries: [RekordboxShareEntry],
        files: [RekordboxShareLocalFile],
        xml: RekordboxLibrary?,
        candidates: [MatchCandidate]
    ) -> [RekordboxShareMatch] {
        let byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return RekordboxShareMatcher.match(entries.map(\.matchKey), files: files, xml: xml, candidates: candidates).compactMap { resolution in
            byId[resolution.key.id].map { RekordboxShareMatch(entry: $0, outcome: resolution.outcome, xml: resolution.xml) }
        }
    }

    static func rekordboxTrack(_ match: RekordboxShareMatch) -> RekordboxTrack {
        let entry = match.entry
        var attributes = match.xml?.attributes ?? [:]
        if attributes["Name"] == nil { attributes["Name"] = entry.stem }
        if attributes["TotalTime"] == nil, let duration = entry.durationSeconds { attributes["TotalTime"] = String(Int(duration.rounded())) }
        let tempos = entry.analysis.tempos.isEmpty
            ? match.xml?.tempos ?? []
            : entry.analysis.tempos.map { RekordboxTempo(inizio: $0.startSeconds, bpm: $0.bpm, metro: "4/4", battito: $0.beatInBar) }
        let marks = entry.analysis.marks.isEmpty
            ? match.xml?.marks ?? []
            : entry.analysis.marks.map {
                RekordboxMark(name: $0.label, type: $0.xmlType, start: $0.startSeconds, end: $0.endSeconds, num: $0.xmlNum, red: $0.red, green: $0.green, blue: $0.blue)
            }
        return RekordboxTrack(trackId: match.xml?.trackId ?? "anlz:\(entry.id)", attributes: attributes, tempos: tempos, marks: marks)
    }

    static func phrases(_ entry: RekordboxShareEntry) -> [PrepPhrase] {
        entry.phrases.map {
            let code = RekordboxPhraseCode(mood: $0.mood, kind: $0.kind)
            return PrepPhrase(startMillis: $0.startMillis, kind: code.sectionKind, mood: nil, rekordbox: code)
        }
    }

    static func phrasePrep(_ entry: RekordboxShareEntry, trackId: String, now: Int64, writerId: String) -> TrackPrep? {
        let list = phrases(entry)
        guard list.count >= 2 else { return nil }
        var prep = TrackPrep(trackId: trackId)
        prep.phrases = PrepField(list, source: .rekordbox, updatedAtMillis: now, writerId: writerId)
        return prep
    }
}
