import Foundation
import XCTest
@testable import SoundingTV

final class ManualTempoKeyTests: XCTestCase {
    private let fingerprint = AnalyzedAudioFingerprint(durationMillis: 200_000, preset: "aac_256k", bitrate: 256, codec: "aac")

    private func row(
        _ engine: AnalysisEngineIdentity,
        schema: Int = 1,
        bpm: Double? = nil,
        key: CamelotKey? = nil,
        genre: String? = nil,
        producedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> AnalysisRecallRow {
        AnalysisRecallRow(
            cacheKey: "\(engine.name)#\(schema)#\(producedAt.timeIntervalSince1970)",
            trackId: "t",
            generation: AnalysisGeneration(engine: engine, schemaVersion: schema),
            fingerprint: fingerprint,
            bpm: bpm, key: key, genre: genre,
            byteSize: 10,
            producedAt: producedAt,
            lastAccessedAt: producedAt,
            producerId: nil
        )
    }

    private var measured: AnalysisGeneration { MusicUnderstandingProducer().generation }

    func testManualTempoAndKeyOverrideAnalysis() {
        let rows = [
            row(measured.engine, schema: measured.schemaVersion, bpm: 128, key: CamelotKey(wheelPosition: 8, mode: .minor), producedAt: Date(timeIntervalSince1970: 50_000)),
            row(.userCorrection(), bpm: 126.5, key: CamelotKey(wheelPosition: 5, mode: .major)),
        ]
        let summary = AnalysisSummaryStore.summarise(rows, expectedDurationMillis: 200_000, preferred: fingerprint)
        XCTAssertEqual(summary?.bpm, 126.5)
        XCTAssertEqual(summary?.key?.label, "5B")
        XCTAssertEqual(summary?.bpmAuthority, .corrected)
        XCTAssertEqual(summary?.keyAuthority, .corrected)
        XCTAssertEqual(summary.map(TrackAnalysisSummary.init)?.bpmProvenance, .stated)
    }

    func testManualKeyAloneKeepsAnalysedTempo() {
        let rows = [
            row(measured.engine, schema: measured.schemaVersion, bpm: 128, key: CamelotKey(wheelPosition: 8, mode: .minor)),
            row(.userCorrection(), key: CamelotKey(wheelPosition: 9, mode: .minor)),
        ]
        let summary = AnalysisSummaryStore.summarise(rows, expectedDurationMillis: 200_000, preferred: fingerprint)
        XCTAssertEqual(summary?.bpm, 128)
        XCTAssertEqual(summary?.bpmAuthority, .measured)
        XCTAssertEqual(summary?.key?.label, "9A")
        XCTAssertEqual(summary?.keyAuthority, .corrected)
    }

    func testResetRowFallsBackToAnalysedButKeepsGenre() {
        let rows = [
            row(measured.engine, schema: measured.schemaVersion, bpm: 128, key: CamelotKey(wheelPosition: 8, mode: .minor)),
            row(.userCorrection(), genre: "techno", producedAt: Date(timeIntervalSince1970: 99_000)),
        ]
        let summary = AnalysisSummaryStore.summarise(rows, expectedDurationMillis: 200_000, preferred: fingerprint)
        XCTAssertEqual(summary?.bpm, 128)
        XCTAssertEqual(summary?.bpmAuthority, .measured)
        XCTAssertEqual(summary?.key?.label, "8A")
        XCTAssertEqual(summary?.keyAuthority, .measured)
        XCTAssertEqual(summary?.genre, "techno")
    }

    func testEmptyResetRowLeavesOnlyAnalysis() {
        let rows = [
            row(measured.engine, schema: measured.schemaVersion, bpm: 174),
            row(.userCorrection()),
        ]
        let summary = AnalysisSummaryStore.summarise(rows, expectedDurationMillis: nil)
        XCTAssertEqual(summary?.bpm, 174)
        XCTAssertEqual(summary?.bpmAuthority, .measured)
        XCTAssertNil(AnalysisSummaryStore.summarise([row(.userCorrection())], expectedDurationMillis: nil))
    }

    func testResetIsAFreshSyncedRecordThatWinsOverTheOldOverride() {
        let old = AnalysisSyncLocalSummary(cacheKey: "k", payloadDigest: "old", byteSize: 40, producedAtMillis: 1_000, producerId: "a")
        let reset = AnalysisSyncRecord(
            cacheKey: "k", trackId: "t", engineName: "sounding.userCorrection", engineVersion: 1, schemaVersion: 1,
            durationMillis: 200_000, preset: "aac_256k", bitrate: 256, codec: "aac",
            payload: Data("{}".utf8), payloadEncoding: .raw, uncompressedByteSize: 2, payloadDigest: "new",
            bpm: nil, keyWheelPosition: nil, keyMode: nil, genre: nil,
            producedAtMillis: 2_000, producerId: "b"
        )
        XCTAssertTrue(AnalysisSyncPolicy.remoteWins(local: old, remote: reset))
    }

    func testManualTempoReachesAutoMixFeatures() {
        let track = VisualFixtures.tracks[0]
        let features = DJSessionDirector.assembleFeatures(
            for: track,
            envelope: [],
            cachedAnalysis: nil,
            legacyAnalysis: TrackAnalysis(trackId: track.id, bpm: 120, key: "8A", energy: 0.5, intro: 0, outro: 100, isEstimated: false),
            userCues: [],
            manual: ManualTempoKeyOverride(bpm: 124, key: CamelotKey(wheelPosition: 4, mode: .major))
        )
        XCTAssertEqual(features.beatGrid?.bpm ?? 0, 124, accuracy: 0.001)
        XCTAssertEqual(features.keyRegions.first?.key.label, "4B")
    }

    func testBPMParsingAndRange() {
        XCTAssertEqual(ManualTempoKey.parseBPM("128"), 128)
        XCTAssertEqual(ManualTempoKey.parseBPM("127,5"), 127.5)
        XCTAssertEqual(ManualTempoKey.parseBPM(" 40 "), 40)
        XCTAssertEqual(ManualTempoKey.parseBPM("250"), 250)
        XCTAssertNil(ManualTempoKey.parseBPM("39.9"))
        XCTAssertNil(ManualTempoKey.parseBPM("251"))
        XCTAssertNil(ManualTempoKey.parseBPM("fast"))
        XCTAssertTrue(ManualTempoKey.isValidBPMText(""))
        XCTAssertEqual(ManualTempoKey.format(128), "128")
        XCTAssertEqual(ManualTempoKey.format(127.5), "127.5")
    }

    func testTwentyFourKeysWithMusicalNames() {
        XCTAssertEqual(CamelotKey.all.count, 24)
        XCTAssertEqual(Set(CamelotKey.all).count, 24)
        XCTAssertEqual(CamelotKey(pitchClass: 9, isMinor: true).musicalName, "A minor")
        XCTAssertEqual(CamelotKey(pitchClass: 0, isMinor: false).musicalName, "C major")
        for key in CamelotKey.all {
            let name = key.musicalName
            let root = String(name.split(separator: " ")[0])
                .replacingOccurrences(of: "♯", with: "#")
                .replacingOccurrences(of: "♭", with: "b")
            XCTAssertEqual(CamelotKey.parse(root + (key.isMinor ? "m" : "")), key, name)
        }
    }
}

final class TapTempoTests: XCTestCase {
    func testNeedsFourTaps() {
        var tempo = TapTempo()
        XCTAssertNil(tempo.tap(at: 0))
        XCTAssertNil(tempo.tap(at: 0.5))
        XCTAssertNil(tempo.tap(at: 1.0))
        XCTAssertEqual(tempo.tap(at: 1.5), 120)
    }

    func testAveragesUnevenIntervals() {
        var tempo = TapTempo()
        for time in [0.0, 0.48, 1.0, 1.47, 2.0] { tempo.tap(at: time) }
        XCTAssertEqual(tempo.bpm, 120)
    }

    func testKeepsTheLastEightTaps() {
        var tempo = TapTempo()
        for index in 0..<6 { tempo.tap(at: Double(index) * 0.6) }
        let start = 5 * 0.6
        for index in 1...8 { tempo.tap(at: start + Double(index) * 0.5) }
        XCTAssertEqual(tempo.count, 8)
        XCTAssertEqual(tempo.bpm, 120)
    }

    func testAPauseStartsAgain() {
        var tempo = TapTempo()
        for time in [0.0, 0.5, 1.0, 1.5] { tempo.tap(at: time) }
        XCTAssertNil(tempo.tap(at: 4.0))
        XCTAssertEqual(tempo.count, 1)
    }

    func testOutOfRangeTempoIsIgnored() {
        var tempo = TapTempo()
        for time in [0.0, 1.9, 3.8, 5.7] { tempo.tap(at: time) }
        XCTAssertNil(tempo.bpm)
    }
}

final class AnalysisPendingCopyTests: XCTestCase {
    func testGateFollowsTheSchedulerOrder() {
        XCTAssertEqual(AnalysisGateInputs(device: .tv).gate, .unsupported)
        XCTAssertEqual(AnalysisGateInputs(device: .mac, isEnabled: false).gate, .off)
        XCTAssertEqual(AnalysisGateInputs(device: .phone, isLowPowerMode: true, isHot: true).gate, .lowPowerMode)
        XCTAssertEqual(AnalysisGateInputs(device: .mac, isHot: true).gate, .tooWarm)
        XCTAssertEqual(AnalysisGateInputs(device: .phone, batteryLevel: 0.2, isOnPower: false).gate, .lowBattery)
        XCTAssertEqual(AnalysisGateInputs(device: .phone, batteryLevel: 0.2, isOnPower: true).gate, .ready)
        XCTAssertEqual(AnalysisGateInputs(device: .phone, batteryLevel: 0.8, isOnPower: false).gate, .needsPower)
        XCTAssertEqual(AnalysisGateInputs(device: .mac, batteryLevel: 0.8, isOnPower: false).gate, .ready)
        XCTAssertEqual(AnalysisGateInputs(device: .pad, isOnPower: true, isPlaying: true).gate, .playing)
        XCTAssertEqual(AnalysisGateInputs(device: .mac, isPlaying: true).gate, .playing)
    }

    func testGateMessages() {
        XCTAssertNil(AnalysisStatusCopy.gate(.ready, device: .phone))
        XCTAssertEqual(AnalysisStatusCopy.gate(.off, device: .mac), "Music Analysis is off on this Mac.")
        XCTAssertEqual(AnalysisStatusCopy.gate(.unsupported, device: .tv), "BPM and key are found when a track is on the decks, or come from your iPhone, iPad or Mac.")
        XCTAssertEqual(AnalysisStatusCopy.gate(.unsupported, device: .watch), "BPM and key come from your iPhone, iPad or Mac.")
        XCTAssertEqual(AnalysisStatusCopy.gate(.lowPowerMode, device: .phone), "Paused: Low Power Mode is on.")
        XCTAssertEqual(AnalysisStatusCopy.gate(.tooWarm, device: .pad), "Paused: your iPad is too warm.")
        XCTAssertEqual(AnalysisStatusCopy.gate(.lowBattery, device: .phone), "Paused until your iPhone is charging.")
        XCTAssertEqual(AnalysisStatusCopy.gate(.needsPower, device: .phone), "BPM and key are found when your iPhone is connected to power with Sounding open.")
        XCTAssertEqual(AnalysisStatusCopy.gate(.playing, device: .mac), "BPM and key are found when your Mac isn’t playing music.")
    }

    func testLibraryStatus() {
        func status(_ gate: AnalysisGate, done: Int = 120, total: Int = 400, analysing: Bool = false, batch: AnalysisBatchPhase = .idle, device: DeviceClass = .phone) -> AnalysisLibraryStatus {
            AnalysisStatusCopy.library(gate: gate, device: device, done: done, total: total, isAnalysing: analysing, batch: batch)
        }
        XCTAssertEqual(status(.needsPower), AnalysisLibraryStatus(
            message: "BPM and key are found when your iPhone is connected to power with Sounding open.",
            detail: "120 of 400 tracks analysed"
        ))
        XCTAssertEqual(status(.ready, analysing: true).message, "Analysing… 120 of 400 tracks")
        XCTAssertEqual(status(.ready), AnalysisLibraryStatus(message: "Analysing soon.", detail: "120 of 400 tracks analysed"))
        XCTAssertEqual(status(.ready, done: 400).message, "All 400 tracks analysed.")
        XCTAssertEqual(status(.ready, done: 1, total: 1).message, "1 track analysed.")
        XCTAssertEqual(status(.ready, done: 0, total: 0).message, "Downloads and your own music are analysed here.")
        XCTAssertEqual(status(.lowPowerMode, batch: .running(done: 3, total: 280)).message, "Analysing… 3 of 280 tracks")
        XCTAssertEqual(status(.ready, batch: .stoppedTooWarm, device: .mac).message, "Stopped: your Mac is too warm.")
        XCTAssertEqual(status(.off, device: .mac), AnalysisLibraryStatus(message: "Music Analysis is off on this Mac.", detail: nil))
    }

    func testTrackStatus() {
        func status(_ gate: AnalysisGate = .ready, work: AnalysisWorkState? = nil, analysable: Bool = true, long: Bool = false, device: DeviceClass = .phone) -> String {
            AnalysisStatusCopy.track(gate: gate, device: device, work: work, isAnalysable: analysable, isLong: long)
        }
        XCTAssertEqual(status(.needsPower), "BPM and key are found when your iPhone is connected to power with Sounding open.")
        XCTAssertEqual(status(.lowPowerMode, work: .queued(position: 2)), "Paused: Low Power Mode is on.")
        XCTAssertEqual(status(work: .queued(position: 1)), "Waiting to analyse.")
        XCTAssertEqual(status(work: .analysing), "Analysing…")
        XCTAssertEqual(status(work: .failed("x")), "Analysis didn’t finish. Choose Analyse Now to try again.")
        XCTAssertEqual(status(work: .complete), "No BPM or key found.")
        XCTAssertEqual(status(analysable: false), "BPM and key are found when this track is downloaded.")
        XCTAssertEqual(status(long: true), "Long mixes are analysed when you choose Analyse Now.")
        XCTAssertEqual(status(.unsupported, device: .tv), "BPM and key are found when a track is on the decks, or come from your iPhone, iPad or Mac.")
        XCTAssertEqual(status(.playing, device: .mac), "BPM and key are found when your Mac isn’t playing music.")
        XCTAssertEqual(status(), "Waiting to analyse.")
    }

    func testPhoneBacklogWaitsForPower() {
        XCTAssertFalse(AnalysisLanePolicy.allowsBacklog(AnalysisLaneConditions(device: .phone, isOnPower: false, isPlaying: false)))
        XCTAssertTrue(AnalysisLanePolicy.allowsBacklog(AnalysisLaneConditions(device: .phone, isOnPower: true, isPlaying: false)))
        XCTAssertTrue(AnalysisLanePolicy.allowsBacklog(AnalysisLaneConditions(device: .mac, isOnPower: false, isPlaying: false)))
    }
}
