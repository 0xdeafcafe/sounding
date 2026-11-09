#if DEBUG
import Foundation
import AVFoundation
import Accelerate
import XCTest
import Darwin
@testable import SoundingTV

final class BeatTrackerTests: XCTestCase {

    func testBeatTrackerAccuracy() async throws {
        let report = try await BeatTrackerEvaluation.run()
        let failures = BeatTrackerGates.evaluate(report)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testBeatTrackerResourceBudget() async throws {
        let report = try await BeatTrackerEvaluation.runResources()
        let failures = BeatTrackerGates.evaluateResources(report)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testHalfBeatShiftAndWholeTrackPhaseVote() {
        let beats = (0..<40).map { 1 + Double($0) * 0.5 }
        let shifted = BeatTracker.shiftedHalfBeat(beats, until: 30)
        XCTAssertEqual(shifted.first ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(shifted.count, beats.count + 1)
        var bar = BeatTracker.BarEstimate(downbeatIndices: [0, 4, 8, 12], parityStrength: 0, parityAgreement: 0, halfBarStrength: 0, halfBarAgreement: 0)
        bar.shiftScores = (0..<8).map { _ in [0, 0, 5, 0] }
        let vote = BeatTracker.barPhaseVote(bar)
        XCTAssertEqual(vote.shift, 2)
        XCTAssertGreaterThan(vote.confidence, 0.25)
        XCTAssertEqual(bar.shifted(by: vote.shift, beatCount: 16).downbeatIndices, [2, 6, 10, 14])
    }

    @MainActor
    func testTrackedGridFeedsThePlannerOnlyWhenConfident() {
        let beats = (0..<400).map { 0.25 + Double($0) * 60 / 124 }
        let downbeats = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
        func result(confidence: Double, beatConfidence: Double) -> BeatTrackerResult {
            BeatTrackerResult(
                version: BeatTracker.version, bpm: 124, beats: beats, downbeats: downbeats,
                phraseOffsetBars: 0, phraseStarts: stride(from: 0, to: downbeats.count, by: 8).map { downbeats[$0] },
                sectionStarts: [], tempoSegments: [], confidence: confidence, beatConfidence: beatConfidence,
                downbeatConfidence: confidence, tempoClarity: 0.8, analysedSeconds: 200
            )
        }
        let track = MixRenderer.syntheticTrack(id: "tracked-grid", duration: 200)
        let confident = DJSessionDirector.assembleFeatures(
            for: track, envelope: [], cachedAnalysis: nil, legacyAnalysis: nil, userCues: [],
            trackedBeats: result(confidence: 0.86, beatConfidence: 0.95)
        )
        XCTAssertTrue(confident.provenance.contains(.measuredBeatGrid))
        XCTAssertTrue(confident.provenance.contains(.measuredDownbeats))
        XCTAssertEqual(confident.beatGrid?.confidence ?? 0, 0.86, accuracy: 1e-9)
        XCTAssertTrue(DJGridTrust.phaseLocked(confident, profile: .automaticDJ))

        let ambiguous = DJSessionDirector.assembleFeatures(
            for: track, envelope: [], cachedAnalysis: nil, legacyAnalysis: nil, userCues: [],
            trackedBeats: result(confidence: 0.3, beatConfidence: 0.95)
        )
        XCTAssertFalse(ambiguous.provenance.contains(.measuredBeatGrid))
        XCTAssertTrue(ambiguous.provenance.contains(.measuredTempo))
        XCTAssertEqual(ambiguous.beatGrid?.confidence ?? 1, DJEngineConstants.tempoOnlyGridConfidence, accuracy: 1e-9)
        XCTAssertFalse(DJGridTrust.phaseLocked(ambiguous, profile: .automaticDJ))

        let noise = DJSessionDirector.assembleFeatures(
            for: track, envelope: [], cachedAnalysis: nil, legacyAnalysis: nil, userCues: [],
            trackedBeats: result(confidence: 0.1, beatConfidence: 0.2)
        )
        XCTAssertNil(noise.beatGrid)
        XCTAssertFalse(noise.provenance.contains(.measuredTempo))
    }

    func testPhraseOffsetMovesPhraseStarts() {
        let beats = (0..<256).map { Double($0) * 0.5 }
        let bars = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
        let grid = BeatGrid.fromMeasuredBars(bpm: 120, beats: beats, bars: bars, confidence: 0.9, phraseOffsetBars: 3)
        XCTAssertEqual(grid?.phraseStarts(from: 0, through: 60), [6, 22, 38, 54])
        let plain = BeatGrid.fromMeasuredBars(bpm: 120, beats: beats, bars: bars, confidence: 0.9)
        XCTAssertEqual(plain?.phraseStarts(from: 0, through: 60), [0, 16, 32, 48])
    }
}

struct BeatTrackerReport: Codable {
    var rows: [String: [String: Double]] = [:]
    var notes: [String: String] = [:]
}

struct BeatTrackerEvaluationCase {
    let id: String
    let truthBeats: [Double]
    let truthDownbeats: [Double]
    let isLiveSet: Bool
    let kind: Kind

    enum Kind {
        case steady
        case drifting
        case ambiguousBar
        case beatless
    }
}

enum BeatTrackerEvaluation {

    static var outputDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        return env["AUTOMIX_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("automix", isDirectory: true)
    }

    static var fixtureDirectory: URL { outputDirectory.appendingPathComponent("fixtures", isDirectory: true) }

    static func run() async throws -> BeatTrackerReport {
        var report = BeatTrackerReport()
        for spec in AutoMixFixtures.all {
            let fixture = try MixFixtureFactory.fixture(spec, in: fixtureDirectory)
            let result = try await BeatTracker.analyze(fileURL: fixture.url)
            let truth = fixture.truth
            let kind: BeatTrackerEvaluationCase.Kind = spec.bpmStart == spec.bpmEnd ? .steady : .drifting
            record(
                &report, id: spec.id, result: result,
                truth: BeatTrackerEvaluationCase(id: spec.id, truthBeats: truth.beats, truthDownbeats: truth.downbeats, isLiveSet: kind == .drifting, kind: kind),
                meanBPM: spec.meanBPM
            )
        }
        for pattern in BeatTrackerPatterns.all {
            let rendered = pattern.render()
            let result = BeatTracker.analyze(samples: rendered.samples, options: BeatTracker.Options(tempoPrior: pattern.tempoPrior))
            record(
                &report, id: pattern.id, result: result,
                truth: BeatTrackerEvaluationCase(
                    id: pattern.id, truthBeats: rendered.beats, truthDownbeats: rendered.downbeats,
                    isLiveSet: pattern.bpmStart != pattern.bpmEnd, kind: pattern.kind
                ),
                meanBPM: rendered.meanBPM
            )
        }
        write(report, name: "beat-tracker")
        return report
    }

    static func record(
        _ report: inout BeatTrackerReport,
        id: String,
        result: BeatTrackerResult,
        truth: BeatTrackerEvaluationCase,
        meanBPM: Double
    ) {
        var row: [String: Double] = [:]
        row["bpmTruth"] = meanBPM
        row["bpmMeasured"] = result.bpm ?? .nan
        row["bpmErrorPercent"] = result.bpm.map { abs($0 - meanBPM) / meanBPM * 100 } ?? .nan
        let beatScore = fMeasure(estimated: result.beats, truth: truth.truthBeats)
        row["beatF"] = beatScore.f
        row["beatMedianErrorMs"] = beatScore.medianErrorMs
        row["beatMeanSignedErrorMs"] = beatScore.meanSignedErrorMs
        let downbeatScore = fMeasure(estimated: result.downbeats, truth: truth.truthDownbeats)
        row["downbeatF"] = downbeatScore.f
        row["downbeatMedianErrorMs"] = downbeatScore.medianErrorMs
        row["confidence"] = result.confidence
        row["beatConfidence"] = result.beatConfidence
        row["downbeatConfidence"] = result.downbeatConfidence
        row["tempoClarity"] = result.tempoClarity
        row["phaseReliable"] = result.isPhaseReliable ? 1 : 0
        row["tempoReliable"] = result.isTempoReliable ? 1 : 0
        row["phraseOffsetBars"] = Double(result.phraseOffsetBars)
        row["sections"] = Double(result.sectionStarts.count)
        if truth.isLiveSet {
            let drift = driftErrors(result: result, truthBeats: truth.truthBeats)
            row["driftMaxBPMError"] = drift.max
            row["driftMedianBPMError"] = drift.median
            row["driftSegments"] = Double(drift.count)
            row["tempoStartMeasured"] = result.tempoSegments.first?.bpm ?? .nan
            row["tempoEndMeasured"] = result.tempoSegments.last?.bpm ?? .nan
        }
        report.rows[id] = row
        report.notes[id] = "sections \(result.sectionStarts.map { String(format: "%.1f", $0) }.joined(separator: ","))"
        print("BEATTRACKER \(id) " + row.keys.sorted().map { "\($0)=\(String(format: "%.4f", row[$0] ?? .nan))" }.joined(separator: " "))
    }

    struct Score {
        let f: Double
        let medianErrorMs: Double
        let meanSignedErrorMs: Double
    }

    static func fMeasure(estimated: [Double], truth: [Double], tolerance: Double = 0.07, skip: Double = 5) -> Score {
        let est = estimated.filter { $0 >= skip }
        let ref = truth.filter { $0 >= skip }
        guard !est.isEmpty, !ref.isEmpty else { return Score(f: 0, medianErrorMs: .nan, meanSignedErrorMs: .nan) }
        var used = [Bool](repeating: false, count: est.count)
        var matched = 0
        var errors: [Double] = []
        var cursor = 0
        for r in ref {
            while cursor < est.count, est[cursor] < r - tolerance { cursor += 1 }
            var best = -1
            var bestDistance = tolerance
            var k = cursor
            while k < est.count, est[k] <= r + tolerance {
                if !used[k], abs(est[k] - r) <= bestDistance {
                    best = k
                    bestDistance = abs(est[k] - r)
                }
                k += 1
            }
            if best >= 0 {
                used[best] = true
                matched += 1
                errors.append((est[best] - r) * 1000)
            }
        }
        let precision = Double(matched) / Double(est.count)
        let recall = Double(matched) / Double(ref.count)
        let f = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        let absErrors = errors.map(abs)
        return Score(
            f: f,
            medianErrorMs: absErrors.isEmpty ? .nan : MixMetrics.median(absErrors),
            meanSignedErrorMs: errors.isEmpty ? .nan : errors.reduce(0, +) / Double(errors.count)
        )
    }

    static func driftErrors(result: BeatTrackerResult, truthBeats: [Double]) -> (max: Double, median: Double, count: Int) {
        var errors: [Double] = []
        let beats = result.beats
        var index = 0
        while index + 32 < beats.count {
            let start = beats[index], end = beats[index + 32]
            let measured = 60 * 32 / (end - start)
            let inside = truthBeats.filter { $0 >= start - 0.1 && $0 <= end + 0.1 }
            if inside.count >= 24 {
                let truthBPM = 60 * Double(inside.count - 1) / (inside[inside.count - 1] - inside[0])
                errors.append(abs(measured - truthBPM))
            }
            index += 32
        }
        guard !errors.isEmpty else { return (.nan, .nan, 0) }
        return (errors.max() ?? .nan, MixMetrics.median(errors), errors.count)
    }

    // MARK: - Resources

    static func runResources() async throws -> BeatTrackerReport {
        var report = BeatTrackerReport()
        let house = try MixFixtureFactory.fixture(AutoMixFixtures.houseA, in: fixtureDirectory)
        let live = try MixFixtureFactory.fixture(AutoMixFixtures.liveSetD, in: fixtureDirectory)
        let long = try BeatTrackerPatterns.longSetFile(in: fixtureDirectory)
        for (id, url, seconds) in [
            ("house-a", house.url, AutoMixFixtures.houseA.duration),
            ("live-set-d", live.url, AutoMixFixtures.liveSetD.duration),
            ("long-set-60min", long.url, long.seconds)
        ] {
            let measurement = try await measure { try await BeatTracker.analyze(fileURL: url) }
            var row: [String: Double] = [:]
            row["audioSeconds"] = seconds
            row["peakFootprintDeltaMB"] = measurement.peakDeltaMB
            row["cpuSeconds"] = measurement.cpuSeconds
            row["wallSeconds"] = measurement.wallSeconds
            row["realtimeFactorCPU"] = seconds / max(1e-6, measurement.cpuSeconds)
            row["cpuSecondsPerAudioMinute"] = measurement.cpuSeconds / (seconds / 60)
            row["confidence"] = measurement.result.confidence
            row["beatConfidence"] = measurement.result.beatConfidence
            row["downbeatConfidence"] = measurement.result.downbeatConfidence
            row["bpm"] = measurement.result.bpm ?? .nan
            report.rows[id] = row
            print("BEATTRACKER_RESOURCES \(id) " + row.keys.sorted().map { "\($0)=\(String(format: "%.3f", row[$0] ?? .nan))" }.joined(separator: " "))
        }
        write(report, name: "beat-tracker-resources")
        return report
    }

    struct Measurement {
        let result: BeatTrackerResult
        let peakDeltaMB: Double
        let cpuSeconds: Double
        let wallSeconds: Double
    }

    static func measure(_ body: () async throws -> BeatTrackerResult) async throws -> Measurement {
        let sampler = FootprintSampler()
        let baseline = FootprintSampler.footprint()
        let cpuBefore = processCPUSeconds()
        let wallBefore = Date()
        sampler.start()
        let result = try await body()
        let peak = sampler.stop()
        let cpu = processCPUSeconds() - cpuBefore
        return Measurement(
            result: result,
            peakDeltaMB: Double(peak > baseline ? peak - baseline : 0) / 1_048_576,
            cpuSeconds: cpu,
            wallSeconds: Date().timeIntervalSince(wallBefore)
        )
    }

    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    static func write(_ report: BeatTrackerReport, name: String) {
        let label = ProcessInfo.processInfo.environment["AUTOMIX_LABEL"] ?? "latest"
        let directory = outputDirectory.appendingPathComponent(label, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sanitized = BeatTrackerReport(rows: report.rows.mapValues { $0.mapValues { $0.isFinite ? $0 : -999 } }, notes: report.notes)
        try? encoder.encode(sanitized).write(to: directory.appendingPathComponent("\(name).json"))
    }
}

final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var peak: UInt64 = 0
    private var thread: Thread?

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func start() {
        lock.lock()
        running = true
        peak = Self.footprint()
        lock.unlock()
        let thread = Thread { [weak self] in
            while let self, self.isRunning {
                let value = Self.footprint()
                self.lock.lock()
                self.peak = max(self.peak, value)
                self.lock.unlock()
                usleep(2_000)
            }
        }
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func stop() -> UInt64 {
        let last = Self.footprint()
        lock.lock()
        running = false
        peak = max(peak, last)
        let value = peak
        lock.unlock()
        usleep(5_000)
        return value
    }
}

enum BeatTrackerGates {
    struct Gate {
        let row: String
        let metric: String
        let maximum: Double?
        let minimum: Double?

        static func max(_ row: String, _ metric: String, _ value: Double) -> Gate { Gate(row: row, metric: metric, maximum: value, minimum: nil) }
        static func min(_ row: String, _ metric: String, _ value: Double) -> Gate { Gate(row: row, metric: metric, maximum: nil, minimum: value) }
    }

    static let accurate = ["house-a", "house-b", "pickup-c", "live-set-d", "vocal-outro-e", "vocal-intro-f", "breakbeat-g", "swung-drums-h", "live-drummer-i"]
    static let confident = ["house-a", "house-b", "live-set-d", "breakbeat-g", "swung-drums-h", "live-drummer-i"]

    static let gates: [Gate] = accurate.flatMap { id in
        [
            .max(id, "bpmErrorPercent", 0.1),
            .min(id, "beatF", 0.97),
            .max(id, "beatMedianErrorMs", 5),
            .min(id, "downbeatF", 0.95)
        ]
    } + confident.map { .min($0, "confidence", 0.65) } + [
        .max("live-set-d", "driftMaxBPMError", 0.2),
        .max("live-drummer-i", "driftMaxBPMError", 0.5),
        .min("kick-only-j", "beatF", 0.97),
        .max("kick-only-j", "phaseReliable", 0),
        .max("beatless-k", "phaseReliable", 0),
        .max("beatless-k", "tempoReliable", 0)
    ]

    static func evaluate(_ report: BeatTrackerReport) -> [String] {
        let confidentAndWrong = report.rows.compactMap { id, row -> String? in
            guard row["phaseReliable"] == 1, let f = row["downbeatF"], f < 0.95 else { return nil }
            return "\(id) claims reliable downbeats with downbeatF = \(f)"
        }
        return confidentAndWrong + gates.compactMap { gate in
            guard let value = report.rows[gate.row]?[gate.metric] else { return "\(gate.row).\(gate.metric) was not measured" }
            if let maximum = gate.maximum, !(value <= maximum) { return "\(gate.row).\(gate.metric) = \(value), gate ≤ \(maximum)" }
            if let minimum = gate.minimum, !(value >= minimum) { return "\(gate.row).\(gate.metric) = \(value), gate ≥ \(minimum)" }
            return nil
        }
    }

    static func evaluateResources(_ report: BeatTrackerReport) -> [String] {
        var failures: [String] = []
        for (id, row) in report.rows {
            if let peak = row["peakFootprintDeltaMB"], peak > 60 { failures.append("\(id) peak footprint +\(peak) MB, budget 60 MB") }
            if let factor = row["realtimeFactorCPU"], factor < 10 { failures.append("\(id) analysed at \(factor)× real time on CPU, floor 10×") }
        }
        return failures
    }
}

struct BeatTrackerPattern {
    let id: String
    let duration: Double
    let bpmStart: Double
    let bpmEnd: Double
    let jitterMs: Double
    let firstDownbeat: Double
    let kicks: [Double]
    let snares: [Double]
    let hats: [Double]
    let swing: Double
    let chords: Bool
    let bassline: [Double]
    let beatless: Bool
    let kind: BeatTrackerEvaluationCase.Kind
    var tempoPrior: Double? = nil

    struct Rendered {
        let samples: [Float]
        let beats: [Double]
        let downbeats: [Double]
        let meanBPM: Double
    }

    func beatTimes() -> [Double] {
        var noise = SplitMix(seed: MixFixtureFactory.stableHash(id))
        var beats: [Double] = []
        var t = firstDownbeat
        var i = 0
        let estimated = Double(duration) / (60 / max(bpmStart, bpmEnd)) + 8
        while t < duration - 0.05 {
            let jitter = jitterMs > 0 ? (noise.unit() * 2 - 1) * jitterMs / 1000 : 0
            beats.append(t + jitter)
            let progress = min(1, Double(i) / estimated)
            t += 60 / (bpmStart + (bpmEnd - bpmStart) * progress)
            i += 1
        }
        return beats
    }

    func render(sampleRate: Double = BeatTracker.sampleRate) -> Rendered {
        let beats = beatless ? [] : beatTimes()
        let total = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: total)
        let kick = OneShots.kick(sampleRate: sampleRate)
        let snare = OneShots.snare(sampleRate: sampleRate)
        let hat = OneShots.hat(sampleRate: sampleRate)

        func timeAt(beat position: Double) -> Double? {
            guard !beats.isEmpty else { return nil }
            let i = Int(position.rounded(.down))
            let f = position - Double(i)
            guard i >= 0, i < beats.count else { return nil }
            let next = i + 1 < beats.count ? beats[i + 1] : beats[i] + (beats[i] - beats[max(0, i - 1)])
            return beats[i] + f * (next - beats[i])
        }
        func add(_ shot: [Float], at seconds: Double, gain: Float) {
            let start = Int(seconds * sampleRate)
            guard start >= 0, start < total else { return }
            let count = min(shot.count, total - start)
            out.withUnsafeMutableBufferPointer { dst in
                shot.withUnsafeBufferPointer { src in
                    var g = gain
                    vDSP_vsma(src.baseAddress!, 1, &g, dst.baseAddress! + start, 1, dst.baseAddress! + start, 1, vDSP_Length(count))
                }
            }
        }

        let progression: [[Double]] = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]
        let roots: [Double] = [33, 29, 36, 31]
        if beatless {
            var t = 0.0
            var index = 0
            while t < duration {
                let chord = progression[index % progression.count]
                addTone(&out, frequencies: chord.map(midiHz), start: t, length: 4.1, gain: 0.08, sampleRate: sampleRate, attack: 1.2)
                t += 4
                index += 1
            }
            var noise = SplitMix(seed: 7)
            var swellStart = 2.0
            while swellStart < duration {
                let length = 3 + noise.unit() * 3
                let first = Int(swellStart * sampleRate)
                let last = min(total, Int((swellStart + length) * sampleRate))
                var lp: Float = 0
                if first < last {
                    for n in first..<last {
                        let x = Float(noise.unit() * 2 - 1)
                        lp += 0.05 * (x - lp)
                        let phase = Double(n - first) / Double(last - first)
                        out[n] += lp * Float(sin(.pi * phase)) * 0.25
                    }
                }
                swellStart += length + 1 + noise.unit() * 4
            }
        } else {
            let bars = beats.count / 4
            for bar in 0..<bars {
                let base = Double(bar * 4)
                for k in kicks { if let t = timeAt(beat: base + k) { add(kick, at: t, gain: 0.9) } }
                for s in snares { if let t = timeAt(beat: base + s) { add(snare, at: t, gain: 0.5) } }
                for h in hats {
                    let swung = h.truncatingRemainder(dividingBy: 1) == 0.5 ? h + swing : h
                    if let t = timeAt(beat: base + swung) { add(hat, at: t, gain: 0.18) }
                }
                if chords, let t = timeAt(beat: base), let end = timeAt(beat: base + 4) ?? Optional(t + 4 * 60 / bpmEnd) {
                    let chord = progression[(bar / 2) % progression.count]
                    addTone(&out, frequencies: chord.map(midiHz), start: t, length: end - t, gain: 0.05, sampleRate: sampleRate, attack: 0.01)
                }
                for b in bassline {
                    if let t = timeAt(beat: base + b) {
                        let root = roots[(bar / 2) % roots.count]
                        addTone(&out, frequencies: [midiHz(root), midiHz(root + 12)], start: t, length: 0.3, gain: 0.22, sampleRate: sampleRate, attack: 0.008)
                    }
                }
            }
        }

        var peak: Float = 0
        vDSP_maxmgv(out, 1, &peak, vDSP_Length(out.count))
        if peak > 0 {
            var scale = 0.89 / peak
            vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(out.count))
        }
        let downbeats = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
        let mean = beats.count > 1 ? 60 * Double(beats.count - 1) / (beats[beats.count - 1] - beats[0]) : 0
        return Rendered(samples: out, beats: beats, downbeats: downbeats, meanBPM: mean)
    }

    private func midiHz(_ note: Double) -> Double { 440 * pow(2, (note - 69) / 12) }

    private func addTone(
        _ out: inout [Float], frequencies: [Double], start: Double, length: Double,
        gain: Float, sampleRate: Double, attack: Double
    ) {
        let first = max(0, Int(start * sampleRate))
        let last = min(out.count, Int((start + length) * sampleRate))
        guard last > first else { return }
        let count = last - first
        var buffer = [Float](repeating: 0, count: count)
        var ramp = [Float](repeating: 0, count: count)
        for f in frequencies {
            var phase: Float = 0
            var increment = Float(2 * Double.pi * f / sampleRate)
            vDSP_vramp(&phase, &increment, &ramp, 1, vDSP_Length(count))
            var n = Int32(count)
            vvsinf(&ramp, ramp, &n)
            vDSP_vadd(buffer, 1, ramp, 1, &buffer, 1, vDSP_Length(count))
        }
        let attackSamples = max(1, Int(attack * sampleRate))
        let releaseSamples = min(count, max(1, Int(0.02 * sampleRate)))
        for i in 0..<count {
            var env: Float = 1
            if i < attackSamples { env = Float(i) / Float(attackSamples) }
            if i > count - releaseSamples { env = min(env, Float(count - i) / Float(releaseSamples)) }
            buffer[i] *= env * gain
        }
        out.withUnsafeMutableBufferPointer { dst in
            vDSP_vadd(dst.baseAddress! + first, 1, buffer, 1, dst.baseAddress! + first, 1, vDSP_Length(count))
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

enum OneShots {
    static func kick(sampleRate: Double) -> [Float] {
        let count = Int(0.28 * sampleRate)
        var out = [Float](repeating: 0, count: count)
        var phase = 0.0
        for n in 0..<count {
            let t = Double(n) / sampleRate
            phase += 2 * .pi * (48 + 110 * exp(-t * 32)) / sampleRate
            out[n] = Float(sin(phase) * min(1, t / 0.0015) * exp(-t * 8.5))
        }
        return out
    }

    static func snare(sampleRate: Double) -> [Float] {
        let count = Int(0.2 * sampleRate)
        var out = [Float](repeating: 0, count: count)
        var noise = SplitMix(seed: 11)
        var lp: Float = 0
        for n in 0..<count {
            let t = Double(n) / sampleRate
            let x = Float(noise.unit() * 2 - 1)
            lp += 0.3 * (x - lp)
            let body = sin(2 * .pi * 185 * t) * exp(-t * 30)
            out[n] = Float(Double(x - lp) * exp(-t * 18) * 0.8 + body * 0.5)
        }
        return out
    }

    static func hat(sampleRate: Double) -> [Float] {
        let count = Int(0.05 * sampleRate)
        var out = [Float](repeating: 0, count: count)
        var noise = SplitMix(seed: 5)
        var previous: Float = 0
        for n in 0..<count {
            let t = Double(n) / sampleRate
            let x = Float(noise.unit() * 2 - 1)
            out[n] = (x - previous) * Float(exp(-t * 70))
            previous = x
        }
        return out
    }
}

enum BeatTrackerPatterns {
    static let breakbeat = BeatTrackerPattern(
        id: "breakbeat-g", duration: 180, bpmStart: 96, bpmEnd: 96, jitterMs: 0, firstDownbeat: 0.3,
        kicks: [0, 2.5], snares: [1, 3], hats: [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5], swing: 0,
        chords: true, bassline: [0, 2.5], beatless: false, kind: .steady
    )
    static let swungDrums = BeatTrackerPattern(
        id: "swung-drums-h", duration: 180, bpmStart: 88, bpmEnd: 88, jitterMs: 0, firstDownbeat: 0.6,
        kicks: [0, 1.75, 2.5], snares: [1, 3], hats: [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5], swing: 0.12,
        chords: true, bassline: [0, 1.75, 2.5], beatless: false, kind: .steady
    )
    static let liveDrummer = BeatTrackerPattern(
        id: "live-drummer-i", duration: 360, bpmStart: 118, bpmEnd: 128, jitterMs: 8, firstDownbeat: 0.2,
        kicks: [0, 2], snares: [1, 3], hats: [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5], swing: 0,
        chords: true, bassline: [0, 1.5, 2], beatless: false, kind: .drifting
    )
    static let kickOnly = BeatTrackerPattern(
        id: "kick-only-j", duration: 180, bpmStart: 124, bpmEnd: 124, jitterMs: 0, firstDownbeat: 0.15,
        kicks: [0, 1, 2, 3], snares: [], hats: [], swing: 0,
        chords: false, bassline: [], beatless: false, kind: .ambiguousBar
    )
    static let beatless = BeatTrackerPattern(
        id: "beatless-k", duration: 150, bpmStart: 0, bpmEnd: 0, jitterMs: 0, firstDownbeat: 0,
        kicks: [], snares: [], hats: [], swing: 0,
        chords: false, bassline: [], beatless: true, kind: .beatless
    )

    static let all = [breakbeat, swungDrums, liveDrummer, kickOnly, beatless]

    static func longSetFile(in directory: URL) throws -> (url: URL, seconds: Double) {
        let seconds = 3600.0
        let pattern = BeatTrackerPattern(
            id: "long-set-60min", duration: seconds, bpmStart: 122, bpmEnd: 127, jitterMs: 0, firstDownbeat: 0.1,
            kicks: [0, 1, 2, 3], snares: [1, 3], hats: [0.5, 1.5, 2.5, 3.5], swing: 0,
            chords: true, bassline: [0.5, 1.5, 2.5, 3.5], beatless: false, kind: .drifting
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("long-set-60min-v1.caf")
        if FileManager.default.fileExists(atPath: url.path) { return (url, seconds) }
        let samples = pattern.render().samples
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: BeatTracker.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let partial = url.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        let file = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)),
              let channel = buffer.floatChannelData?[0] else { throw BeatTracker.TrackerError.readerFailed }
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            samples.withUnsafeBufferPointer { src in channel.update(from: src.baseAddress! + offset, count: count) }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
        try FileManager.default.moveItem(at: partial, to: url)
        return (url, seconds)
    }
}

extension MixRenderer {
    static func syntheticTrack(id: String, duration: TimeInterval) -> Track {
        let spec = MixFixtureSpec(
            id: id, duration: duration, bpmStart: 124, bpmEnd: 124, firstDownbeat: 0, pickupBeats: 0,
            keyPitchClass: 0, isMinor: false, introBars: 0, outroBars: 0, vocalBars: [], breakdownBars: []
        )
        let truth = MixFixtureTruth.make(spec)
        return track(for: MixFixture(spec: spec, truth: truth, url: URL(fileURLWithPath: "/dev/null"), waveform: [], integratedLUFS: -10))
    }
}
#endif
