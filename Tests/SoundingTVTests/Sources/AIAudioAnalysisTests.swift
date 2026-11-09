import XCTest
@testable import SoundingTV

final class AIAudioAnalysisTests: XCTestCase {
    private func grid(bpm: Double, start: Double, count: Int, confidence: Double) -> BeatTrackerResult {
        let period = 60 / bpm
        let beats = (0..<count).map { start + Double($0) * period }
        return BeatTrackerResult(
            version: BeatTracker.version, bpm: bpm, beats: beats,
            downbeats: stride(from: 0, to: count, by: 4).map { beats[$0] },
            phraseOffsetBars: 0, phraseStarts: [], sectionStarts: [], tempoSegments: [],
            confidence: confidence, beatConfidence: confidence, downbeatConfidence: confidence,
            tempoClarity: 1, analysedSeconds: beats.last ?? 0
        )
    }

    private func result(confidence: Double, downbeat: Double, meter: Int? = 4, stems: AIAudioAnalysisResult.Stems? = nil) -> AIAudioAnalysisResult {
        AIAudioAnalysisResult(
            version: AIAudioAnalysisResult.version,
            grid: grid(bpm: 125, start: 0.06, count: 400, confidence: min(confidence, downbeat)),
            gridConfidence: confidence, downbeatConfidence: downbeat, beatsPerBar: meter, stems: stems
        )
    }

    func testTrustGateNeedsBothConfidencesAndFourFour() {
        XCTAssertTrue(result(confidence: 0.85, downbeat: 0.6).isGridTrusted)
        XCTAssertFalse(result(confidence: 0.79, downbeat: 0.9).isGridTrusted)
        XCTAssertFalse(result(confidence: 0.95, downbeat: 0.49).isGridTrusted)
        XCTAssertFalse(result(confidence: 0.95, downbeat: 0.9, meter: 3).isGridTrusted)
    }

    func testSmoothingRemovesFrameQuantisation() {
        let period = 60.0 / 126.98
        let truth = (0..<200).map { 0.26 + Double($0) * period }
        let quantised = truth.map { ($0 * 50).rounded() / 50 }
        let smoothed = BeatTracker.smoothedBeats(quantised)
        let worst = zip(smoothed, truth).dropFirst(8).dropLast(8).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 0.004)
    }

    func testTrustedGridAndStemsReplaceTheTrackedGrid() {
        let track = VisualFixtures.tracks[0]
        let stems = AIAudioAnalysisResult.Stems(
            vocals: [.init(start: 30, end: 60)],
            drumsOnly: [.init(start: 0.06, end: 15.42)],
            bass: [.init(start: 16, end: 120)]
        )
        let ai = result(confidence: 0.9, downbeat: 0.7, stems: stems)
        let tracked = grid(bpm: 126.9, start: 0.3, count: 400, confidence: 0.9)
        let features = DJSessionDirector.assembleFeatures(
            for: track, envelope: [], cachedAnalysis: nil, legacyAnalysis: nil, userCues: [],
            trackedBeats: tracked, aiAudio: ai
        )
        XCTAssertEqual(features.beatGrid?.bpm ?? 0, 125, accuracy: 0.05)
        XCTAssertEqual(features.vocalRanges, [30...60])
        XCTAssertEqual(features.bassRanges, [16...120])
        XCTAssertEqual(features.loopRanges, [0.06...15.42])
        XCTAssertTrue(features.provenance.contains(.measuredStems))

        let untrusted = DJSessionDirector.assembleFeatures(
            for: track, envelope: [], cachedAnalysis: nil, legacyAnalysis: nil, userCues: [],
            trackedBeats: tracked, aiAudio: result(confidence: 0.5, downbeat: 0.7)
        )
        XCTAssertEqual(untrusted.beatGrid?.bpm ?? 0, 126.9, accuracy: 0.05)
        XCTAssertFalse(untrusted.provenance.contains(.measuredStems))
    }

    private func tracker(on beats: [Double], phase: Int, offbeatUntil: Double) -> BeatTrackerResult {
        let period = beats[1] - beats[0]
        let downbeats = stride(from: phase, to: beats.count, by: 4).map { beats[$0] < offbeatUntil ? beats[$0] + period / 2 : beats[$0] }
        let tracked = (0..<beats.count).map { beats[$0] < offbeatUntil ? beats[$0] + period / 2 : beats[$0] }
        return BeatTrackerResult(
            version: BeatTracker.version, bpm: 60 / period, beats: tracked, downbeats: downbeats,
            phraseOffsetBars: 0, phraseStarts: stride(from: 0, to: downbeats.count, by: 8).map { downbeats[$0] },
            sectionStarts: [], tempoSegments: [], confidence: 0.2, beatConfidence: 0.7, downbeatConfidence: 0.2,
            tempoClarity: 1, analysedSeconds: beats.last ?? 0
        )
    }

    func testConfidentBeatsWithWeakDownbeatsKeepTheTrackersBarPhase() throws {
        let ai = result(confidence: 0.95, downbeat: 0.3)
        let beats = ai.grid!.beats
        let tracked = tracker(on: beats, phase: 2, offbeatUntil: 60)
        let features = DJSessionDirector.assembleFeatures(
            for: VisualFixtures.tracks[0], envelope: [], cachedAnalysis: nil, legacyAnalysis: nil, userCues: [],
            trackedBeats: tracked, aiAudio: ai
        )
        let grid = try XCTUnwrap(features.beatGrid)
        XCTAssertEqual(grid.beats, beats)
        XCTAssertEqual(grid.downbeats, stride(from: 2, to: beats.count, by: 4).map { beats[$0] })
        XCTAssertEqual(grid.bpm, 125, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(grid.confidence, 0.9)
        XCTAssertTrue(features.provenance.contains(.measuredDownbeats))
        let onBeat = tracked.downbeats.filter { $0 >= 60 }
        XCTAssertTrue(onBeat.allSatisfy { d in grid.downbeats!.contains { abs($0 - d) < 0.001 } })
        XCTAssertEqual(grid.firstPhraseBar, grid.downbeats!.firstIndex { abs($0 - tracked.phraseStarts.first { $0 >= 60 }!) < 0.3 }! % 8)
    }

    func testConfidentDownbeatsStillUseTheAIBarPhase() {
        let ai = result(confidence: 0.95, downbeat: 0.7)
        let beats = ai.grid!.beats
        let features = DJSessionDirector.assembleFeatures(
            for: VisualFixtures.tracks[0], envelope: [], cachedAnalysis: nil, legacyAnalysis: nil, userCues: [],
            trackedBeats: tracker(on: beats, phase: 2, offbeatUntil: 0), aiAudio: ai
        )
        XCTAssertEqual(features.beatGrid?.downbeats?.first, beats[0])
    }

    func testBarPhaseIgnoresOffBeatReferenceDownbeats() {
        let beats = (0..<64).map { 0.5 + Double($0) * 0.48 }
        let offbeat = stride(from: 0, to: 32, by: 4).map { beats[$0] + 0.24 }
        let onPhaseThree = stride(from: 35, to: 64, by: 4).map { beats[$0] }
        let vote = BeatTrackerResult.barPhase(beats: beats, downbeats: offbeat + onPhaseThree)
        XCTAssertEqual(vote?.phase, 3)
        XCTAssertEqual(vote?.agreement ?? 0, 1, accuracy: 1e-9)
        XCTAssertNil(BeatTrackerResult.barPhase(beats: beats, downbeats: offbeat))
    }

    func testBeatSlotsSurviveGapsAndExtraBeats() {
        let period = 60.0 / 121.98
        let truth = (0..<200).map { 0.04 + Double($0) * period }
        var raw = truth.enumerated().filter { !(60..<117).contains($0.offset) }.map { ($0.element * 50).rounded() / 50 }
        raw.insert(raw[20] + 0.1, at: 21)
        let grid = BeatTracker.beatSlots(raw)
        XCTAssertEqual(grid.beats.count, 200 - 57)
        XCTAssertEqual(grid.slots.last, 199)
        XCTAssertEqual(60 / grid.period, 121.98, accuracy: 0.5)
        let downbeats = stride(from: 1, to: 200, by: 4).map { truth[$0] }.filter { $0 > truth[130] }
        XCTAssertEqual(BeatTrackerResult.barPhase(beats: raw, downbeats: downbeats)?.phase, 1)
    }
}
