import Foundation

extension DJExportCue {
    init?(_ cue: CuePoint) {
        guard !cue.isDeleted else { return nil }
        let role: Role
        switch cue.kind {
        case .hotCue: role = .hotCue(slot: cue.hotCueIndex ?? 0)
        case .memory, .loop: role = .memory
        case .mixIn: role = .mixIn
        case .mixOut: role = .mixOut
        }
        let isDefault = cue.color == CueColor.default(for: cue.kind, hotCueIndex: cue.hotCueIndex)
        self.init(
            role: role,
            startSeconds: cue.positionSeconds,
            endSeconds: cue.endSeconds,
            label: cue.label,
            colorRGB: cue.kind == .hotCue || !isDefault ? cue.color.rgb : nil
        )
    }
}

extension DJExportBeatGrid {
    init?(_ grid: BeatGrid) {
        guard grid.bpm.isFinite, grid.bpm > 0 else { return nil }
        self.init(
            bpm: grid.bpm,
            firstBeatSeconds: grid.anchor,
            firstDownbeatOffset: grid.downbeatOffset,
            beats: grid.beats,
            downbeats: grid.downbeats
        )
    }
}

extension DJExportKey {
    init?(_ key: CamelotKey) {
        guard let parsed = DJExportKey.parse(key.label) else { return nil }
        self = parsed
    }
}

extension DJExportPhrases {
    init?(sections: [TrackSection], duration: TimeInterval) {
        let phrases = sections.compactMap { section -> DJExportPhrase? in
            let kind: DJExportPhrase.Kind
            switch section.kind {
            case .ambientIntro, .intro: kind = .intro
            case .buildup, .build: kind = .up
            case .drop: kind = .chorus
            case .breakdown, .bridge, .cooldown: kind = .down
            case .outro, .ambientOutro: kind = .outro
            case .unknown: return nil
            }
            return DJExportPhrase(startSeconds: section.start, kind: kind)
        }
        guard !phrases.isEmpty else { return nil }
        self.init(mood: .high, phrases: phrases, endSeconds: sections.map(\.end).max() ?? duration)
    }
}

extension DJExportWaveform {
    init(_ waveform: Waveform) {
        self.init(amplitude: waveform.samples)
    }
}

extension DJExportTrackRecord {
    init(
        exportID: String,
        localFile: URL,
        metadata: DJExportMetadata,
        features: TrackFeatures?,
        cues: [CuePoint],
        waveform: DJExportWaveform?
    ) {
        var dominant: CamelotKey?
        if let regions = features?.keyRegions, !regions.isEmpty {
            var totals: [CamelotKey: Double] = [:]
            for region in regions { totals[region.key, default: 0] += max(0, region.end - region.start) }
            dominant = totals.max { $0.value < $1.value }?.key
        }
        self.init(
            exportID: exportID,
            audioFileURL: localFile,
            metadata: metadata,
            beatGrid: features?.beatGrid.flatMap { DJExportBeatGrid($0) },
            cues: cues.compactMap { DJExportCue($0) },
            phrases: features.flatMap { DJExportPhrases(sections: $0.sections, duration: $0.duration) },
            waveform: waveform ?? features.flatMap { $0.envelope.isEmpty ? nil : DJExportWaveform(amplitude: $0.envelope) },
            key: dominant.flatMap { DJExportKey($0) }
        )
    }
}
