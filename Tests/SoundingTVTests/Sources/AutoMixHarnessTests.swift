#if DEBUG
import Foundation
import AVFoundation
import XCTest
@testable import SoundingTV

final class AutoMixHarnessTests: XCTestCase {

    @MainActor
    func testAutoMixHarness() async throws {
        let harness = AutoMixHarness()
        let report = try await harness.run()
        let partial = !(ProcessInfo.processInfo.environment["AUTOMIX_SCENARIOS"] ?? "").isEmpty
        let failures = AutoMixGates.evaluate(report).filter { !partial || !$0.hasSuffix("was not measured") }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}

final class MixEffectHostingTests: XCTestCase {

    @MainActor
    func testAudioUnitInsertSendAndBypass() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("automix", isDirectory: true)
            .appendingPathComponent("fixtures", isDirectory: true)
        let fixture = try MixFixtureFactory.fixture(AutoMixFixtures.houseA, in: directory)
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_Delay,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        func engine() throws -> MixEngine {
            let engine = MixEngine(offline: true)
            try engine.loadForOfflineRendering(fileURL: fixture.url, into: .a, trackId: "a")
            engine.seek(deck: .a, to: 60)
            engine.play(deck: .a)
            return engine
        }
        func render(_ engine: MixEngine, seconds: Double) throws -> [Float] {
            var out: [Float] = []
            try engine.renderOffline(frames: AVAudioFrameCount(seconds * 44_100)) { buffer in
                out.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
            return out
        }
        func difference(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
        }

        let dry = try engine()
        let wet = try engine()
        defer { dry.stop(); wet.stop() }
        XCTAssertEqual(difference(try render(dry, seconds: 1), try render(wet, seconds: 1)), 0)

        let host = try await MixAudioUnitHost.instantiate(description, name: "AUDelay", manufacturer: "Apple")
        wet.installEffect(host, in: .deck(.a))
        XCTAssertEqual(wet.effects[.deck(.a)]?.name, "AUDelay")
        let insertDifference = difference(try render(dry, seconds: 2), try render(wet, seconds: 2))
        XCTAssertEqual(host.failures, 0)
        XCTAssertGreaterThan(insertDifference, 0.01, "the insert effect should change the deck's sound")

        wet.setEffectBypassed(true, in: .deck(.a))
        _ = try render(dry, seconds: 1.5)
        _ = try render(wet, seconds: 1.5)
        XCTAssertLessThan(difference(try render(dry, seconds: 1), try render(wet, seconds: 1)), 1e-6, "bypass returns the dry deck")

        wet.removeEffect(from: .deck(.a))
        let sendHost = try await MixAudioUnitHost.instantiate(description, name: "AUDelay", manufacturer: "Apple")
        wet.installEffect(sendHost, in: .send)
        XCTAssertEqual(wet[.a].effectSend, 0.5, accuracy: 1e-9)
        let sendDifference = difference(try render(dry, seconds: 2), try render(wet, seconds: 2))
        XCTAssertGreaterThan(sendDifference, 0.01, "the send effect should be audible")
        wet.setEffectBypassed(true, in: .send)
        _ = try render(dry, seconds: 1.5)
        _ = try render(wet, seconds: 1.5)
        XCTAssertLessThan(difference(try render(dry, seconds: 1), try render(wet, seconds: 1)), 1e-6, "bypassing the send removes its return")
    }
}

extension MixEffectHostingTests {

    @MainActor
    func testAudioUnitLatencyIsCompensated() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("automix", isDirectory: true)
            .appendingPathComponent("fixtures", isDirectory: true)
        let fixture = try MixFixtureFactory.fixture(AutoMixFixtures.houseA, in: directory)
        LatencyProbeUnit.register()

        func engine() throws -> MixEngine {
            let engine = MixEngine(offline: true)
            try engine.loadForOfflineRendering(fileURL: fixture.url, into: .a, trackId: "a")
            try engine.loadForOfflineRendering(fileURL: fixture.url, into: .b, trackId: "b")
            engine.crossfade = 0.5
            engine.seek(deck: .a, to: 60)
            engine.seek(deck: .b, to: 60)
            engine.play(decks: [.a, .b])
            return engine
        }
        func render(_ engine: MixEngine, seconds: Double) throws -> [Float] {
            var out: [Float] = []
            try engine.renderOffline(frames: AVAudioFrameCount(seconds * 44_100)) { buffer in
                out.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
            return out
        }
        func aligned(_ reference: [Float], _ delayed: [Float], lag: Int, from start: Int) -> Float {
            var worst: Float = 0
            for n in start..<(reference.count - lag) { worst = max(worst, abs(reference[n] - delayed[n + lag])) }
            return worst
        }
        let lag = LatencyProbeUnit.delayFrames
        let settle = 44_100 * 2

        let reference = try engine()
        let delayed = try engine()
        defer { reference.stop(); delayed.stop() }
        let insertHost = try await MixAudioUnitHost.instantiate(LatencyProbeUnit.description(delay: true), name: "Latency", manufacturer: "Sounding")
        XCTAssertEqual(insertHost.latencyFrames, lag)
        delayed.installEffect(insertHost, in: .deck(.a))
        let referenceOut = try render(reference, seconds: 4)
        let delayedOut = try render(delayed, seconds: 4)
        XCTAssertGreaterThan(aligned(referenceOut, delayedOut, lag: 0, from: settle), 0.01, "the probe insert really delays the deck")
        let insertError = aligned(referenceOut, delayedOut, lag: lag, from: settle)
        XCTAssertLessThan(insertError, 1e-4, "deck B is delayed by the insert's latency, so both decks stay aligned")

        let sendReference = try engine()
        let sendDelayed = try engine()
        defer { sendReference.stop(); sendDelayed.stop() }
        sendReference.installEffect(
            try await MixAudioUnitHost.instantiate(LatencyProbeUnit.description(delay: false), name: "Identity", manufacturer: "Sounding"),
            in: .send
        )
        sendDelayed.installEffect(
            try await MixAudioUnitHost.instantiate(LatencyProbeUnit.description(delay: true), name: "Latency", manufacturer: "Sounding"),
            in: .send
        )
        let sendReferenceOut = try render(sendReference, seconds: 4)
        let sendDelayedOut = try render(sendDelayed, seconds: 4)
        let sendError = aligned(sendReferenceOut, sendDelayedOut, lag: lag, from: settle)
        XCTAssertLessThan(sendError, 1e-4, "the dry mix waits for the send's latency")
        print("AUTOMIX_LATENCY insert \(insertError) send \(sendError) lag \(lag)")
    }
}

final class StretchPadSpliceTests: XCTestCase {

    @MainActor
    func testSustainedPadStretchSplicesStaySmooth() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("automix", isDirectory: true)
            .appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sustained-pad.wav")
        let sampleRate = 44_100.0
        let frames = Int(sampleRate * 40)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let partials: [(Double, Double)] = [(100, 0.22), (200, 0.16), (300, 0.14), (400, 0.12), (500, 0.08), (600, 0.06)]
        for n in 0..<frames {
            let t = Double(n) / sampleRate
            var value = 0.0
            for (index, partial) in partials.enumerated() {
                value += partial.1 * sin(2 * .pi * partial.0 * t + Double(index) * 1.3)
            }
            buffer.floatChannelData![0][n] = Float(value)
            buffer.floatChannelData![1][n] = Float(value)
        }
        try? FileManager.default.removeItem(at: url)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let env = ProcessInfo.processInfo.environment
        let outputDirectory = env["AUTOMIX_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        var report: [String] = []
        for stretch in [1.0, 1.008, 1.024, 1.04] {
            let engine = MixEngine(offline: true)
            defer { engine.stop() }
            try engine.loadForOfflineRendering(fileURL: url, into: .a, trackId: "pad")
            engine.seek(deck: .a, to: 5)
            engine.setRate(stretch, on: .a)
            engine.play(deck: .a)
            var left: [Float] = []
            try engine.renderOffline(frames: AVAudioFrameCount(sampleRate * 12)) { rendered in
                left.append(contentsOf: UnsafeBufferPointer(start: rendered.floatChannelData![0], count: Int(rendered.frameLength)))
            }
            let window = 441
            let start = Int(sampleRate * 2)
            var levels: [Double] = []
            var n = start
            while n + window <= left.count {
                var sum = 0.0
                for k in n..<(n + window) { sum += Double(left[k] * left[k]) }
                levels.append(10 * log10(max(1e-12, sum / Double(window))))
                n += window
            }
            let sorted = levels.sorted()
            let median = sorted[sorted.count / 2]
            let worstDip = median - (sorted.first ?? median)
            let p99Dip = median - sorted[max(0, sorted.count / 100)]
            report.append(String(format: "stretch %.3f worstDip %.2f dB p1Dip %.2f dB", stretch, worstDip, p99Dip))
            if stretch == 1.0 {
                XCTAssertLessThan(worstDip, 0.3, "the dry pad is level, so every dip below is the stretcher's")
            } else {
                XCTAssertLessThan(worstDip, 1.5, "a stretched sustained pad keeps its level through every splice at \(stretch)")
            }
            if let outputDirectory, stretch == 1.024 {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
                out.frameLength = AVAudioFrameCount(left.count)
                for k in 0..<left.count {
                    out.floatChannelData![0][k] = left[k]
                    out.floatChannelData![1][k] = left[k]
                }
                let wav = try AVAudioFile(forWriting: outputDirectory.appendingPathComponent("pad-stretch-2.4.wav"), settings: format.settings)
                try wav.write(from: out)
            }
        }
        print("AUTOMIX_PAD " + report.joined(separator: " | "))
    }
}

final class LatencyProbeUnit: AUAudioUnit {
    static let delayFrames = 1_000
    private static let registration: Void = {
        AUAudioUnit.registerSubclass(LatencyProbeUnit.self, as: description(delay: true), name: "Sounding: Latency", version: 1)
        AUAudioUnit.registerSubclass(LatencyProbeUnit.self, as: description(delay: false), name: "Sounding: Identity", version: 1)
    }()
    private let delays: Bool
    private var inputArray: AUAudioUnitBusArray!
    private var outputArray: AUAudioUnitBusArray!
    private let state = LatencyProbeState()

    static func description(delay: Bool) -> AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: delay ? 0x6C617463 : 0x6964656E,
            componentManufacturer: 0x536E6467,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    static func register() {
        _ = registration
    }

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        delays = componentDescription.componentSubType == Self.description(delay: true).componentSubType
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        inputArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
        outputArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
        maximumFramesToRender = 4_096
        state.delay = delays ? Self.delayFrames : 0
    }

    override var inputBusses: AUAudioUnitBusArray { inputArray }
    override var outputBusses: AUAudioUnitBusArray { outputArray }
    override var latency: TimeInterval { delays ? Double(Self.delayFrames) / 44_100 : 0 }

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = state
        return { _, timestamp, frames, _, output, _, pull in
            guard let pull else { return kAudioUnitErr_NoConnection }
            var flags = AudioUnitRenderActionFlags()
            let status = pull(&flags, timestamp, frames, 0, output)
            guard status == noErr else { return status }
            state.process(UnsafeMutableAudioBufferListPointer(output), frames: Int(frames))
            return noErr
        }
    }
}

final class LatencyProbeState: @unchecked Sendable {
    var delay = 0
    private let capacity = 8_192
    private var write = 0
    private let ring: [UnsafeMutablePointer<Float>]

    init() {
        ring = (0..<2).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 8_192)
            pointer.initialize(repeating: 0, count: 8_192)
            return pointer
        }
    }

    func process(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let start = write
        for channel in 0..<min(2, list.count) {
            guard let data = list[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            var w = start
            for n in 0..<frames {
                ring[channel][w] = data[n]
                data[n] = ring[channel][(w - delay + capacity) % capacity]
                w = (w + 1) % capacity
            }
        }
        write = (start + frames) % capacity
    }
}

struct AutoMixReport: Codable {
    var label: String
    var scenarios: [String: [String: Double]] = [:]
    var notes: [String: [String: String]] = [:]
    var analyzer: [String: [String: Double]] = [:]
}

enum AutoMixFixtures {
    static let houseA = MixFixtureSpec(
        id: "house-a", duration: 240, bpmStart: 124, bpmEnd: 124, firstDownbeat: 0.05, pickupBeats: 0,
        keyPitchClass: 9, isMinor: true, introBars: 16, outroBars: 16,
        vocalBars: [32...63, 80...95], breakdownBars: [64...71]
    )
    static let houseB = MixFixtureSpec(
        id: "house-b", duration: 230, bpmStart: 125, bpmEnd: 125, firstDownbeat: 0.43, pickupBeats: 0,
        keyPitchClass: 4, isMinor: true, introBars: 16, outroBars: 16,
        vocalBars: [24...55], breakdownBars: [56...63]
    )
    static let pickupC = MixFixtureSpec(
        id: "pickup-c", duration: 220, bpmStart: 126, bpmEnd: 126, firstDownbeat: 1.2, pickupBeats: 2,
        keyPitchClass: 2, isMinor: true, introBars: 16, outroBars: 16,
        vocalBars: [24...47], breakdownBars: [48...55]
    )
    static let liveSetD = MixFixtureSpec(
        id: "live-set-d", duration: 420, bpmStart: 122, bpmEnd: 126, firstDownbeat: 0.1, pickupBeats: 0,
        keyPitchClass: 4, isMinor: true, introBars: 8, outroBars: 16,
        vocalBars: [40...71, 120...151], breakdownBars: [96...103]
    )
    static let vocalOutroE = MixFixtureSpec(
        id: "vocal-outro-e", duration: 240, bpmStart: 124, bpmEnd: 124, firstDownbeat: 0.05, pickupBeats: 0,
        keyPitchClass: 0, isMinor: false, introBars: 16, outroBars: 16,
        vocalBars: [24...55, 72...123], breakdownBars: [56...63]
    )
    static let vocalIntroF = MixFixtureSpec(
        id: "vocal-intro-f", duration: 230, bpmStart: 124, bpmEnd: 124, firstDownbeat: 0.05, pickupBeats: 0,
        keyPitchClass: 9, isMinor: true, introBars: 16, outroBars: 16,
        vocalBars: [0...39], breakdownBars: [64...71]
    )

    static let houseG = MixFixtureSpec(
        id: "house-g", duration: 236, bpmStart: 127, bpmEnd: 127, firstDownbeat: 0.21, pickupBeats: 0,
        keyPitchClass: 9, isMinor: true, introBars: 16, outroBars: 16,
        vocalBars: [24...55], breakdownBars: [56...63]
    )

    static let all = [houseA, houseB, pickupC, liveSetD, vocalOutroE, vocalIntroF, houseG]
}

@MainActor
final class AutoMixHarness {
    let outputDirectory: URL
    let label: String

    init() {
        let env = ProcessInfo.processInfo.environment
        let base = env["AUTOMIX_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("automix", isDirectory: true)
        outputDirectory = base
        label = env["AUTOMIX_LABEL"] ?? "latest"
    }

    func run() async throws -> AutoMixReport {
        let env = ProcessInfo.processInfo.environment
        let fixtureDirectory = outputDirectory.appendingPathComponent("fixtures", isDirectory: true)
        let runDirectory = outputDirectory.appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        var fixtures: [String: MixFixture] = [:]
        for spec in AutoMixFixtures.all {
            fixtures[spec.id] = try MixFixtureFactory.fixture(spec, in: fixtureDirectory)
        }

        var report = AutoMixReport(label: label)
        var legacy: [String: TrackAnalysis] = [:]
        for spec in AutoMixFixtures.all {
            guard let fixture = fixtures[spec.id] else { continue }
            let analysis = try await AudioAnalyzer.analyze(streamURL: fixture.url, duration: spec.duration, trackId: spec.id)
            legacy[spec.id] = analysis
            var row: [String: Double] = [:]
            row["bpmTruth"] = spec.meanBPM
            row["bpmMeasured"] = analysis.bpm ?? .nan
            row["bpmErrorPercent"] = analysis.bpm.map { abs($0 - spec.meanBPM) / spec.meanBPM * 100 } ?? .nan
            row["keyCorrect"] = analysis.key == spec.keyName ? 1 : 0
            report.analyzer[spec.id] = row
            report.notes["analyzer.\(spec.id)"] = ["key": analysis.key ?? "none", "truthKey": spec.keyName]
        }

        var tracked: [String: BeatTrackerResult] = [:]
        for spec in AutoMixFixtures.all {
            guard let fixture = fixtures[spec.id] else { continue }
            let result = try await BeatTracker.analyze(fileURL: fixture.url)
            tracked[spec.id] = result
            let beatScore = BeatTrackerEvaluation.fMeasure(estimated: result.beats, truth: fixture.truth.beats)
            let downbeatScore = BeatTrackerEvaluation.fMeasure(estimated: result.downbeats, truth: fixture.truth.downbeats)
            report.analyzer["tracker.\(spec.id)"] = [
                "bpmTruth": spec.meanBPM,
                "bpmMeasured": result.bpm ?? .nan,
                "bpmErrorPercent": result.bpm.map { abs($0 - spec.meanBPM) / spec.meanBPM * 100 } ?? .nan,
                "beatF": beatScore.f,
                "beatMedianErrorMs": beatScore.medianErrorMs,
                "downbeatF": downbeatScore.f,
                "confidence": result.confidence
            ]
        }

        let a = fixtures[AutoMixFixtures.houseA.id]!
        let b = fixtures[AutoMixFixtures.houseB.id]!
        let c = fixtures[AutoMixFixtures.pickupC.id]!
        let d = fixtures[AutoMixFixtures.liveSetD.id]!
        let e = fixtures[AutoMixFixtures.vocalOutroE.id]!
        let f = fixtures[AutoMixFixtures.vocalIntroF.id]!
        let g = fixtures[AutoMixFixtures.houseG.id]!

        let earlyCueSeconds = a.truth.nearestDownbeat(to: a.spec.duration * 0.30) ?? 72
        let earlyCue = CuePoint(
            trackId: MixRenderer.track(for: a).id,
            kind: .mixOut,
            positionMillis: Int64((earlyCueSeconds * 1000).rounded())
        )

        var scenarios: [MixRenderer.Scenario] = [
            MixRenderer.Scenario(name: "measured-blend", outgoing: a, incoming: b),
            MixRenderer.Scenario(name: "bpm-only-grids", outgoing: a, incoming: b, outgoingAnalysis: .bpmOnly, incomingAnalysis: .bpmOnly),
            MixRenderer.Scenario(name: "pickup-downbeat", outgoing: a, incoming: c),
            MixRenderer.Scenario(name: "grid-without-sections", outgoing: a, incoming: c, outgoingAnalysis: .gridOnly, incomingAnalysis: .gridOnly),
            MixRenderer.Scenario(name: "silent-lead-in", outgoing: a, incoming: b, outgoingAnalysis: .gridOnly, incomingAnalysis: .gridOnly),
            MixRenderer.Scenario(name: "live-set-drift", outgoing: d, incoming: b),
            MixRenderer.Scenario(name: "vocal-clash", outgoing: e, incoming: f),
            MixRenderer.Scenario(name: "echo-out", outgoing: a, incoming: b, profile: .junkie, template: DJTemplates.echoOut),
            MixRenderer.Scenario(name: "pause-mid-blend", outgoing: a, incoming: b, events: [.pause(atTransitionFraction: 0.4, seconds: 4)]),
            MixRenderer.Scenario(name: "seek-mid-blend", outgoing: a, incoming: b, events: [.seek(atTransitionFraction: 0.3, bySeconds: 4)]),
            MixRenderer.Scenario(name: "early-mixout-cue", outgoing: a, incoming: b, outgoingCues: [earlyCue]),
            MixRenderer.Scenario(name: "pause-same-tempo", outgoing: a, incoming: f, events: [.pause(atTransitionFraction: 0.4, seconds: 4)]),
            MixRenderer.Scenario(name: "seek-same-tempo", outgoing: a, incoming: f, events: [.seek(atTransitionFraction: 0.3, bySeconds: 4)]),
            MixRenderer.Scenario(name: "wide-stretch", outgoing: a, incoming: g),
            MixRenderer.Scenario(name: "wide-stretch-seek", outgoing: a, incoming: g, events: [.seek(atTransitionFraction: 0.5, bySeconds: 7)])
        ]
        if let legacyA = legacy[a.spec.id], let legacyB = legacy[b.spec.id] {
            scenarios.append(MixRenderer.Scenario(
                name: "legacy-analyser", outgoing: a, incoming: b,
                outgoingAnalysis: .legacy(legacyA), incomingAnalysis: .legacy(legacyB)
            ))
        }

        func trackedMode(_ fixture: MixFixture) -> MixRenderer.AnalysisMode? {
            tracked[fixture.spec.id].map { .tracked($0, legacy: legacy[fixture.spec.id]) }
        }
        for (name, outgoing, incoming) in [
            ("tracker-blend", a, b),
            ("tracker-pickup", a, c),
            ("tracker-live-set", d, b),
            ("tracker-same-tempo", a, f),
            ("tracker-vocal-pair", e, f)
        ] {
            guard let outgoingMode = trackedMode(outgoing), let incomingMode = trackedMode(incoming) else { continue }
            scenarios.append(MixRenderer.Scenario(
                name: name, outgoing: outgoing, incoming: incoming,
                outgoingAnalysis: outgoingMode, incomingAnalysis: incomingMode
            ))
        }

        if let trackedD = trackedMode(d), let trackedB = trackedMode(b) {
            scenarios.append(MixRenderer.Scenario(name: "probe-tracked-out", outgoing: d, incoming: b, outgoingAnalysis: trackedD, incomingAnalysis: .measured))
            scenarios.append(MixRenderer.Scenario(name: "probe-tracked-in", outgoing: d, incoming: b, outgoingAnalysis: .measured, incomingAnalysis: trackedB))
            if let t = tracked[d.spec.id] {
                let truthBeats = BeatTrackerResult(
                    version: t.version, bpm: 124, beats: d.truth.beats, downbeats: d.truth.downbeats,
                    phraseOffsetBars: 0, phraseStarts: t.phraseStarts, sectionStarts: t.sectionStarts, tempoSegments: [],
                    confidence: t.confidence, beatConfidence: t.beatConfidence, downbeatConfidence: t.downbeatConfidence,
                    tempoClarity: t.tempoClarity, analysedSeconds: t.analysedSeconds
                )
                scenarios.append(MixRenderer.Scenario(name: "probe-truth-beats-out", outgoing: d, incoming: b, outgoingAnalysis: .tracked(truthBeats, legacy: legacy[d.spec.id]), incomingAnalysis: .measured))
            }
        }

        if let only = env["AUTOMIX_SCENARIOS"].flatMap({ $0.isEmpty ? nil : Set($0.split(separator: ",").map(String.init)) }) {
            scenarios = scenarios.filter { only.contains($0.name) }
        }
        let renderer = MixRenderer()
        let replayed: Set<String> = ["measured-blend", "echo-out", "live-set-drift", "pickup-downbeat", "early-mixout-cue", "vocal-clash"]
        var cpuNanos: UInt64 = 0
        var cpuFrames: Int64 = 0
        var cpuMaxQuantum: UInt64 = 0
        var cpuQuanta: Int64 = 0
        for scenario in scenarios {
            do {
                let result = try renderer.render(scenario)
                var (metrics, notes) = AutoMixAnalysis.metrics(for: result)
                cpuNanos += result.mix.renderNanos
                cpuFrames += result.mix.renderedFrames
                cpuMaxQuantum = max(cpuMaxQuantum, result.mix.maxQuantumNanos)
                cpuQuanta += result.mix.quanta
                if replayed.contains(scenario.name), let finish = result.mix.finishTime {
                    let replay = try MixRenderer.replay(result, blockSize: 333, seconds: finish - 0.05)
                    metrics["identity.maxAbsDiff"] = AutoMixAnalysis.maxAbsDifference(result.mix, replay)
                    metrics["identity.comparedSeconds"] = Double(replay.left.count) / result.sampleRate
                }
                report.scenarios[scenario.name] = metrics
                report.notes[scenario.name] = notes
                try AutoMixAnalysis.writeWav(result, to: runDirectory.appendingPathComponent("\(scenario.name).wav"))
                if !(env["AUTOMIX_STEMS"] ?? "").isEmpty { try AutoMixRealPack.writeStems(result, base: runDirectory.appendingPathComponent(scenario.name)) }
            } catch {
                report.notes[scenario.name] = ["error": String(describing: error)]
            }
        }
        if cpuFrames > 0 {
            let audioSeconds = Double(cpuFrames) / MixRenderer.sampleRate
            report.scenarios["cpu"] = [
                "percentOfRealtime": Double(cpuNanos) / 1e9 / audioSeconds * 100,
                "meanQuantumMicros": Double(cpuNanos) / Double(max(1, cpuQuanta)) / 1000,
                "maxQuantumMicros": Double(cpuMaxQuantum) / 1000,
                "quantumFrames": 128,
                "audioSeconds": audioSeconds
            ]
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sanitized = AutoMixReport(
            label: report.label,
            scenarios: report.scenarios.mapValues { $0.mapValues { $0.isFinite ? $0 : -999 } },
            notes: report.notes,
            analyzer: report.analyzer.mapValues { $0.mapValues { $0.isFinite ? $0 : -999 } }
        )
        try encoder.encode(sanitized).write(to: runDirectory.appendingPathComponent("report.json"))
        let markdown = AutoMixAnalysis.markdown(report)
        try markdown.write(to: runDirectory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        print("AUTOMIX_REPORT_DIR=\(runDirectory.path)")
        print(markdown)
        return report
    }
}

enum AutoMixAnalysis {

    static func outputTime(
        ofSource source: TimeInterval,
        deckA: Bool,
        log: [MixRenderer.LogEntry],
        after: TimeInterval = 0
    ) -> TimeInterval? {
        var previous: MixRenderer.LogEntry?
        for entry in log where entry.time >= after {
            defer { previous = entry }
            guard let p = previous else { continue }
            let p0 = deckA ? p.positionA : p.positionB
            let p1 = deckA ? entry.positionA : entry.positionB
            guard p1 > p0, p1 - p0 < 0.5, source >= p0, source < p1 else { continue }
            let fraction = (source - p0) / (p1 - p0)
            return p.time + fraction * (entry.time - p.time)
        }
        return nil
    }

    static func sourceTime(at time: TimeInterval, deckA: Bool, log: [MixRenderer.LogEntry]) -> TimeInterval? {
        guard let index = log.firstIndex(where: { $0.time >= time }), index > 0 else { return nil }
        let p = log[index - 1]
        let q = log[index]
        let p0 = deckA ? p.positionA : p.positionB
        let p1 = deckA ? q.positionA : q.positionB
        let fraction = (time - p.time) / max(1e-9, q.time - p.time)
        return p0 + (p1 - p0) * fraction
    }

    static func inRanges(_ t: TimeInterval?, _ ranges: [ClosedRange<TimeInterval>]) -> Bool {
        guard let t else { return false }
        return ranges.contains { t >= $0.lowerBound && t <= $0.upperBound }
    }

    static func gridPhaseErrors(
        result: MixRenderer.Result, from start: TimeInterval, to end: TimeInterval
    ) -> [(time: TimeInterval, error: Double)] {
        let sr = result.sampleRate
        let log = result.mix.log
        let rmsA = MixMetrics.rmsSeries(result.stemA, sampleRate: sr, window: 0.1, hop: 0.01)
        let rmsB = MixMetrics.rmsSeries(result.stemB, sampleRate: sr, window: 0.1, hop: 0.01)
        func audible(_ series: [Double], _ t: TimeInterval) -> Bool {
            guard !series.isEmpty else { return false }
            let i = min(series.count - 1, max(0, Int(t / 0.01)))
            return MixMetrics.db(series[i]) > -45
        }
        let beatsA = result.scenario.outgoing.truth.beats
        var out: [(TimeInterval, Double)] = []
        var cursor = start
        for beat in result.scenario.incoming.truth.beats {
            guard let t = outputTime(ofSource: beat, deckA: false, log: log, after: cursor) else { continue }
            if t > end { break }
            guard t >= start else { continue }
            cursor = max(start, t - 0.05)
            guard audible(rmsA, t), audible(rmsB, t),
                  let sourceA = sourceTime(at: t, deckA: true, log: log),
                  let nearest = beatsA.min(by: { abs($0 - sourceA) < abs($1 - sourceA) }) else { continue }
            let rateA = max(0.01, log.first(where: { $0.time >= t })?.rateA ?? 1)
            out.append((t, (sourceA - nearest) / rateA * 1000))
        }
        return out
    }

    static func selfOffsets(
        result: MixRenderer.Result, deckA: Bool, from start: TimeInterval, to end: TimeInterval
    ) -> [(time: TimeInterval, offset: Double)] {
        let sr = result.sampleRate
        let log = result.mix.log
        let stem = deckA ? result.stemA : result.stemB
        let truth = deckA ? result.scenario.outgoing.truth : result.scenario.incoming.truth
        let lo = max(0, Int((start - 2) * sr))
        let hi = min(stem.count, Int((end + 2) * sr))
        guard hi > lo else { return [] }
        let shift = Double(lo) / sr
        var out: [(TimeInterval, Double)] = []
        for onset in MixMetrics.kickOnsets(Array(stem[lo..<hi]), sampleRate: sr).map({ $0 + shift }) where onset >= start && onset <= end {
            guard let source = sourceTime(at: onset, deckA: deckA, log: log), inRanges(source, truth.kickRanges),
                  let nearest = truth.beats.min(by: { abs($0 - source) < abs($1 - source) }) else { continue }
            let rate = max(0.01, log.first(where: { $0.time >= onset }).map { deckA ? $0.rateA : $0.rateB } ?? 1)
            let offset = (source - nearest) / rate * 1000
            if abs(offset) < 150 { out.append((onset, offset)) }
        }
        return out
    }

    static let fullBassDecibels = -1.0
    static let fullBassHighPassHertz = 45.0
    static let minimumPhasePairs = 16.0

    static func fullBass(at time: TimeInterval, deckA: Bool, log: [MixRenderer.LogEntry]) -> Bool {
        [time, time + 0.05].allSatisfy { t in
            guard let entry = log.first(where: { $0.time >= t }) else { return false }
            let low = deckA ? entry.lowA : entry.lowB
            let highPass = deckA ? entry.highPassA : entry.highPassB
            return low >= fullBassDecibels && highPass <= fullBassHighPassHertz
        }
    }

    static func fullBassKicks(
        result: MixRenderer.Result, deckA: Bool, from start: TimeInterval, to end: TimeInterval
    ) -> [(time: TimeInterval, offset: Double)] {
        let sr = result.sampleRate
        let log = result.mix.log
        let stem = deckA ? result.stemA : result.stemB
        let truth = deckA ? result.scenario.outgoing.truth : result.scenario.incoming.truth
        let rms = MixMetrics.rmsSeries(stem, sampleRate: sr, window: 0.1, hop: 0.01)
        guard !rms.isEmpty else { return [] }
        var out: [(TimeInterval, Double)] = []
        for onset in MixMetrics.kickOnsets(stem, sampleRate: sr) where onset >= start && onset <= end {
            guard MixMetrics.db(rms[min(rms.count - 1, max(0, Int(onset / 0.01)))]) > -42,
                  fullBass(at: onset, deckA: deckA, log: log),
                  let source = sourceTime(at: onset, deckA: deckA, log: log), inRanges(source, truth.kickRanges),
                  let nearest = truth.beats.min(by: { abs($0 - source) < abs($1 - source) }),
                  abs(source - nearest) < 0.04 else { continue }
            let rate = max(0.01, log.first(where: { $0.time >= onset }).map { deckA ? $0.rateA : $0.rateB } ?? 1)
            out.append((onset, (source - nearest) / rate * 1000))
        }
        return out
    }

    static func fullBassPhaseErrors(
        result: MixRenderer.Result, from start: TimeInterval, to end: TimeInterval
    ) -> (errors: [(time: TimeInterval, error: Double, deckA: Bool, bothFullBass: Bool)], referenceA: Double?, referenceB: Double?) {
        let sr = result.sampleRate
        let log = result.mix.log
        let referenceFrom = (result.mix.beginTime ?? start) - 8
        let referenceTo = (result.mix.finishTime ?? end) + 8
        let kicksA = fullBassKicks(result: result, deckA: true, from: referenceFrom, to: referenceTo)
        let kicksB = fullBassKicks(result: result, deckA: false, from: referenceFrom, to: referenceTo)
        guard !kicksA.isEmpty, !kicksB.isEmpty else { return ([], nil, nil) }
        let referenceA = MixMetrics.median(kicksA.map { $0.offset })
        let referenceB = MixMetrics.median(kicksB.map { $0.offset })
        let grid = gridPhaseErrors(result: result, from: start - 1, to: end + 1)
        let rmsA = MixMetrics.rmsSeries(result.stemA, sampleRate: sr, window: 0.1, hop: 0.01)
        let rmsB = MixMetrics.rmsSeries(result.stemB, sampleRate: sr, window: 0.1, hop: 0.01)
        func audible(_ series: [Double], _ t: TimeInterval) -> Bool {
            guard !series.isEmpty else { return false }
            return MixMetrics.db(series[min(series.count - 1, max(0, Int(t / 0.01)))]) > -42
        }
        var out: [(time: TimeInterval, error: Double, deckA: Bool, bothFullBass: Bool)] = []
        for (deckA, kicks) in [(true, kicksA), (false, kicksB)] {
            let otherTruth = deckA ? result.scenario.incoming.truth : result.scenario.outgoing.truth
            for kick in kicks where kick.time >= start && kick.time <= end {
                guard audible(deckA ? rmsB : rmsA, kick.time),
                      inRanges(sourceTime(at: kick.time, deckA: !deckA, log: log), otherTruth.kickRanges),
                      let nearest = grid.min(by: { abs($0.time - kick.time) < abs($1.time - kick.time) }),
                      abs(nearest.time - kick.time) < 0.5 else { continue }
                let error = deckA ? nearest.error + referenceB - kick.offset : nearest.error + kick.offset - referenceA
                out.append((kick.time, error, deckA, fullBass(at: kick.time, deckA: !deckA, log: log)))
            }
        }
        return (out.sorted { $0.time < $1.time }, referenceA, referenceB)
    }

    static func phaseErrors(
        result: MixRenderer.Result, from start: TimeInterval, to end: TimeInterval, localFloor: Bool = false
    ) -> [(time: TimeInterval, error: Double)] {
        let sr = result.sampleRate
        let log = result.mix.log
        func onsets(_ stem: [Float]) -> [TimeInterval] {
            guard localFloor else { return MixMetrics.kickOnsets(stem, sampleRate: sr).filter { $0 >= start && $0 <= end } }
            let lo = max(0, Int((start - 2) * sr))
            let hi = min(stem.count, Int((end + 2) * sr))
            guard hi > lo else { return [] }
            let offset = Double(lo) / sr
            return MixMetrics.kickOnsets(Array(stem[lo..<hi]), sampleRate: sr).map { $0 + offset }.filter { $0 >= start && $0 <= end }
        }
        let onsetsA = onsets(result.stemA)
        let onsetsB = onsets(result.stemB)
        let rmsA = MixMetrics.rmsSeries(result.stemA, sampleRate: sr, window: 0.1, hop: 0.01)
        let rmsB = MixMetrics.rmsSeries(result.stemB, sampleRate: sr, window: 0.1, hop: 0.01)
        func audible(_ series: [Double], _ t: TimeInterval) -> Bool {
            let i = min(series.count - 1, max(0, Int(t / 0.01)))
            return series.isEmpty ? false : MixMetrics.db(series[i]) > -42
        }
        var out: [(TimeInterval, Double)] = []
        let beatsA = result.scenario.outgoing.truth.beats
        let beatsB = result.scenario.incoming.truth.beats
        let kicksA = onsetsA.filter { ta in
            guard let sa = sourceTime(at: ta, deckA: true, log: log),
                  let kick = beatsA.min(by: { abs($0 - sa) < abs($1 - sa) }) else { return false }
            return abs(kick - sa) < 0.04
        }
        for tb in onsetsB {
            guard audible(rmsB, tb), audible(rmsA, tb) else { continue }
            let sourceA = sourceTime(at: tb, deckA: true, log: log)
            let sourceB = sourceTime(at: tb, deckA: false, log: log)
            guard let sb = sourceB, let kick = beatsB.min(by: { abs($0 - sb) < abs($1 - sb) }), abs(kick - sb) < 0.04 else { continue }
            guard inRanges(sourceA, result.scenario.outgoing.truth.kickRanges),
                  inRanges(sourceB, result.scenario.incoming.truth.kickRanges) else { continue }
            guard let ta = kicksA.min(by: { abs($0 - tb) < abs($1 - tb) }) else { continue }
            let period = result.scenario.outgoing.truth.localBeatPeriod(at: sourceA ?? 0)
                / max(0.01, log.first(where: { $0.time >= tb })?.rateA ?? 1)
            guard abs(tb - ta) < period * 0.6 else { continue }
            var error = tb - ta
            while error > period / 2 { error -= period }
            while error < -period / 2 { error += period }
            out.append((tb, error * 1000))
        }
        return out
    }

    static func engineDip(
        _ result: MixRenderer.Result, shortTerm: [Double], hop: TimeInterval, floor: Double,
        begin: TimeInterval, finish: TimeInterval, blendStart: TimeInterval, outside: (TimeInterval) -> Bool
    ) -> Double {
        let sr = result.sampleRate
        func series(_ x: [Float]) -> [Double] { MixMetrics.loudnessSeries(left: x, right: x, sampleRate: sr, window: 3, hop: hop) }
        func body(_ s: [Double], from: TimeInterval, to: TimeInterval) -> Double {
            MixMetrics.median(s.enumerated().compactMap { i, v in
                let start = Double(i) * hop
                return start + 1.5 >= from && start + 1.5 <= to && outside(start) && outside(start + 3) ? v : nil
            })
        }
        let decks = [
            (stem: series(result.stemA), dry: series(AutoMixRealPack.dryStem(result, deckA: true)), bodyFrom: begin - 12, bodyTo: begin - 2),
            (stem: series(result.stemB), dry: series(AutoMixRealPack.dryStem(result, deckA: false)), bodyFrom: finish + 3, bodyTo: finish + 13)
        ].map { deck in (deck.stem, deck.dry, body(deck.dry, from: deck.bodyFrom, to: deck.bodyTo)) }
        var worst = 0.0
        for (i, level) in shortTerm.enumerated() {
            let start = Double(i) * hop
            let center = start + 1.5
            guard center >= blendStart, center <= finish + 1.5, outside(start), outside(start + 3) else { continue }
            let loudest = decks.map { i < $0.0.count ? $0.0[i] : -.infinity }.max() ?? -.infinity
            let drops: [Double] = decks.compactMap { stem, dry, body in
                guard i < stem.count, i < dry.count, body.isFinite, body > -70, stem[i] >= loudest - 12 else { return nil }
                return max(0, body - dry[i])
            }
            worst = max(worst, floor - level - (drops.min() ?? 0))
        }
        return worst
    }

    static func metrics(for result: MixRenderer.Result) -> ([String: Double], [String: String]) {
        var m: [String: Double] = [:]
        var notes: [String: String] = [:]
        let plan = result.plan
        let outgoing = result.scenario.outgoing
        let incoming = result.scenario.incoming
        let sr = result.sampleRate
        let log = result.mix.log

        notes["template"] = plan.templateId?.rawValue ?? "none"
        notes["reasoning"] = plan.reasoning
        m["plan.exitSeconds"] = plan.mixPointSeconds
        m["plan.playFraction"] = plan.mixPointSeconds / outgoing.spec.duration
        m["plan.blendSeconds"] = plan.transitionSeconds
        m["plan.blendBars"] = plan.transitionSeconds / (4 * outgoing.truth.localBeatPeriod(at: plan.mixPointSeconds))
        let beatMatched = plan.move.map { [.blend, .loopMix].contains($0.kind) } ?? (plan.templateId != DJTemplates.cutOnTheOne)
        m["plan.beatBlendBars"] = beatMatched ? m["plan.blendBars"] : 0
        m["plan.secondsLeftAfterBlend"] = outgoing.spec.duration - plan.mixPointSeconds - plan.transitionSeconds
        m["plan.entrySeconds"] = result.entrySeconds
        if let nearest = incoming.truth.nearestDownbeat(to: result.entrySeconds) {
            m["plan.entryOffDownbeatMs"] = abs(result.entrySeconds - nearest) * 1000
        }
        if let nearestExit = outgoing.truth.nearestDownbeat(to: plan.mixPointSeconds) {
            m["plan.exitOffDownbeatMs"] = abs(plan.mixPointSeconds - nearestExit) * 1000
        }
        m["plan.incomingRate"] = plan.incomingRateRatio
        m["plan.outgoingGridConfidence"] = result.outgoingFeatures.beatGrid?.confidence ?? 0
        m["plan.outgoingGridClaimsPhase"] = result.outgoingFeatures.provenance.contains(.measuredBeatGrid) ? 1 : 0
        m["plan.incomingGridClaimsPhase"] = result.incomingFeatures.provenance.contains(.measuredBeatGrid) ? 1 : 0
        m["key.camelotSteps"] = Double(outgoing.spec.camelot.wheelSteps(to: incoming.spec.camelot))
            + (outgoing.spec.camelot.mode == incoming.spec.camelot.mode ? 0 : 0.5)

        guard let begin = result.mix.beginTime else {
            notes["error"] = "transition never started"
            return (m, notes)
        }
        let blendStart = begin + result.mix.leadSeconds
        let finish = result.mix.finishTime ?? (log.last?.time ?? blendStart)
        m["timeline.blendWallSeconds"] = finish - blendStart

        let pauseEvent = result.mix.events.first { $0.label == "pause" }
        let resumeEvent = result.mix.events.first { $0.label == "resume" }
        func outsidePause(_ t: TimeInterval) -> Bool {
            guard let pause = pauseEvent?.time, let resume = resumeEvent?.time else { return true }
            return t < pause - 1.5 || t > resume + 3
        }

        let fullBass = fullBassPhaseErrors(result: result, from: blendStart, to: finish)
        let audioErrors = fullBass.errors.filter { outsidePause($0.time) }
        m["phaseAudio.pairs"] = Double(audioErrors.count)
        m["phaseAudio.pairsOutgoing"] = Double(audioErrors.filter { $0.deckA }.count)
        m["phaseAudio.pairsIncoming"] = Double(audioErrors.filter { !$0.deckA }.count)
        m["phaseAudio.bothFullBassPairs"] = Double(audioErrors.filter { $0.bothFullBass }.count)
        if !audioErrors.isEmpty {
            m["phaseAudio.medianAbsMs"] = MixMetrics.median(audioErrors.map { abs($0.error) })
            m["phaseAudio.p95AbsMs"] = MixMetrics.percentile(audioErrors.map { abs($0.error) }, 0.95)
        }
        if let a = fullBass.referenceA, let b = fullBass.referenceB {
            m["phaseAudio.referenceOutgoingMs"] = a
            m["phaseAudio.referenceIncomingMs"] = b
        }
        m["stretch.splicesIncoming"] = Double(result.mix.splicesB)
        m["stretch.splicesOutgoing"] = Double(result.mix.splicesA)
        m["lock.corrections"] = Double(result.mix.lockCorrections)
        m["stretch.beatOffsetMaxMs"] = result.mix.beatOffsetMaxMs
        m["stretch.beatOffsetMeanMs"] = result.mix.beatOffsetMeanMs
        m["anchors.missed"] = Double(result.mix.missedAnchors)
        let errors = gridPhaseErrors(result: result, from: blendStart, to: finish)
        let absErrors = errors.map { abs($0.error) }
        m["phase.pairs"] = Double(errors.count)
        notes["debug.gridPhase"] = errors.prefix(40).map { String(format: "%.2f:%.1f", $0.time, $0.error) }.joined(separator: " ")
        notes["debug.audioPhase"] = audioErrors.prefix(40).map { String(format: "%.2f:%.1f", $0.time, $0.error) }.joined(separator: " ")
        for (label, deckA, stem, truth) in [
            ("selfA", true, result.stemA, outgoing.truth),
            ("selfB", false, result.stemB, incoming.truth)
        ] {
            let onsets = MixMetrics.kickOnsets(stem, sampleRate: sr).filter { $0 >= begin - 8 && $0 <= finish }
            var offsets: [(TimeInterval, Double)] = []
            for onset in onsets {
                guard let source = sourceTime(at: onset, deckA: deckA, log: log),
                      inRanges(source, truth.kickRanges),
                      let nearest = truth.beats.min(by: { abs($0 - source) < abs($1 - source) }) else { continue }
                let rate = max(0.01, log.first(where: { $0.time >= onset }).map { deckA ? $0.rateA : $0.rateB } ?? 1)
                let offset = (source - nearest) / rate * 1000
                if abs(offset) < 150 { offsets.append((onset, offset)) }
            }
            if !offsets.isEmpty {
                m["\(label).medianMs"] = MixMetrics.median(offsets.map(\.1))
                m["\(label).rangeMs"] = (offsets.map(\.1).max() ?? 0) - (offsets.map(\.1).min() ?? 0)
                notes["debug.\(label)"] = offsets.prefix(40).map { String(format: "%.2f:%.1f", $0.0, $0.1) }.joined(separator: " ")
            }
        }
        if !errors.isEmpty {
            m["phase.medianAbsMs"] = MixMetrics.median(absErrors)
            m["phase.p95AbsMs"] = MixMetrics.percentile(absErrors, 0.95)
            m["phase.maxAbsMs"] = absErrors.max() ?? 0
            let values = errors.map(\.error)
            m["phase.driftRangeMs"] = (values.max() ?? 0) - (values.min() ?? 0)
            let bar = 4 * outgoing.truth.localBeatPeriod(at: plan.mixPointSeconds)
            m["phase.driftMsPerBar"] = MixMetrics.linearSlope(x: errors.map(\.time), y: values) * bar
        }

        var offsets: [Double] = []
        var phraseOffsets: [Double] = []
        let firstDownbeatIndexA = outgoing.truth.beats.firstIndex { abs($0 - outgoing.spec.firstDownbeat) < 1e-6 } ?? 0
        for (barIndex, downbeat) in incoming.truth.downbeats.enumerated() {
            guard let t = outputTime(ofSource: downbeat, deckA: false, log: log, after: blendStart),
                  t >= blendStart, t <= finish,
                  let sourceA = sourceTime(at: t, deckA: true, log: log) else { continue }
            guard let beatIndex = outgoing.truth.beats.indices.min(by: {
                abs(outgoing.truth.beats[$0] - sourceA) < abs(outgoing.truth.beats[$1] - sourceA)
            }) else { continue }
            let rel = beatIndex - firstDownbeatIndexA
            let inBar = ((rel % 4) + 4) % 4
            offsets.append(Double(min(inBar, 4 - inBar)))
            if barIndex % 8 == 0, inBar == 0 {
                let barA = rel / 4
                let phrase = ((barA % 8) + 8) % 8
                phraseOffsets.append(Double(min(phrase, 8 - phrase)))
            }
        }
        if !offsets.isEmpty {
            m["downbeat.medianOffsetBeats"] = MixMetrics.median(offsets)
            m["downbeat.alignedFraction"] = Double(offsets.filter { $0 == 0 }.count) / Double(offsets.count)
        }
        if !phraseOffsets.isEmpty {
            m["phrase.medianOffsetBars"] = MixMetrics.median(phraseOffsets)
        }

        let hop = 0.1
        let shortTerm = MixMetrics.loudnessSeries(left: result.mix.left, right: result.mix.right, sampleRate: sr, window: 3, hop: hop)
        let momentary = MixMetrics.loudnessSeries(left: result.mix.left, right: result.mix.right, sampleRate: sr, window: 0.4, hop: hop)
        func values(_ series: [Double], window: TimeInterval, from: TimeInterval, to: TimeInterval) -> [Double] {
            series.enumerated().compactMap { i, v in
                let center = Double(i) * hop + window / 2
                let start = Double(i) * hop
                guard center >= from, center <= to else { return nil }
                guard outsidePause(start), outsidePause(start + window) else { return nil }
                return v
            }
        }
        let pre = MixMetrics.median(values(shortTerm, window: 3, from: begin - 12, to: begin - 2))
        let post = MixMetrics.median(values(shortTerm, window: 3, from: finish + 3, to: finish + 13))
        let during = values(shortTerm, window: 3, from: blendStart, to: finish + 1.5)
        let duringMomentary = values(momentary, window: 0.4, from: blendStart, to: finish + 0.5)
        let preMomentary = MixMetrics.median(values(momentary, window: 0.4, from: begin - 12, to: begin - 2))
        let postMomentary = MixMetrics.median(values(momentary, window: 0.4, from: finish + 3, to: finish + 13))
        if pre.isFinite, post.isFinite, !during.isEmpty {
            m["loudness.preLUFS"] = pre
            m["loudness.postLUFS"] = post
            m["loudness.stepLU"] = post - pre
            m["loudness.dipLU"] = max(0, (during.map { min(pre, post) - $0 }.max() ?? 0))
            m["loudness.swellLU"] = max(0, (during.map { $0 - max(pre, post) }.max() ?? 0))
            m["loudness.engineDipLU"] = Self.engineDip(result, shortTerm: shortTerm, hop: hop, floor: min(pre, post), begin: begin, finish: finish, blendStart: blendStart, outside: outsidePause)
        }
        if preMomentary.isFinite, postMomentary.isFinite, !duringMomentary.isEmpty {
            m["loudness.momentaryDipLU"] = max(0, (duringMomentary.map { min(preMomentary, postMomentary) - $0 }.max() ?? 0))
        }

        let peakFrom = max(0, Int((begin - 2) * sr))
        let peakTo = min(result.mix.left.count, Int((finish + 5) * sr))
        if peakTo > peakFrom {
            m["truePeak.dBTP"] = MixMetrics.truePeakDB([
                Array(result.mix.left[peakFrom..<peakTo]),
                Array(result.mix.right[peakFrom..<peakTo])
            ])
        }

        let lowA = MixMetrics.filter(result.stemA, [.lowPass(150, sampleRate: sr), .lowPass(150, sampleRate: sr)])
        let lowB = MixMetrics.filter(result.stemB, [.lowPass(150, sampleRate: sr), .lowPass(150, sampleRate: sr)])
        let lowRA = MixMetrics.rmsSeries(lowA, sampleRate: sr, window: 0.1, hop: 0.1)
        let lowRB = MixMetrics.rmsSeries(lowB, sampleRate: sr, window: 0.1, hop: 0.1)
        let fullA = MixMetrics.rmsSeries(result.stemA, sampleRate: sr, window: 0.1, hop: 0.1)
        let fullB = MixMetrics.rmsSeries(result.stemB, sampleRate: sr, window: 0.1, hop: 0.1)
        var clash = 0.0
        var clashTimes: [String] = []
        var vocal = 0.0
        let count = min(lowRA.count, lowRB.count, fullA.count, fullB.count)
        for i in 0..<count {
            let t = Double(i) * 0.1 + 0.05
            guard t >= blendStart, t <= finish else { continue }
            let la = MixMetrics.db(lowRA[i])
            let lb = MixMetrics.db(lowRB[i])
            if la > -40, lb > -40, abs(la - lb) < 12 {
                clash += 0.1
                clashTimes.append(String(format: "%.1f:%.0f/%.0f", t - blendStart, la, lb))
            }
            let fa = MixMetrics.db(fullA[i])
            let fb = MixMetrics.db(fullB[i])
            if fa > -40, fb > -40, abs(fa - fb) < 20,
               inRanges(sourceTime(at: t, deckA: true, log: log), outgoing.truth.vocalRanges),
               inRanges(sourceTime(at: t, deckA: false, log: log), incoming.truth.vocalRanges) {
                vocal += 0.1
            }
        }
        m["bass.clashSeconds"] = clash
        notes["debug.clash"] = clashTimes.prefix(60).joined(separator: " ")
        m["vocal.overlapSeconds"] = vocal

        let clickReport = clicks(result: result, begin: begin, finish: finish)
        m["clicks.count"] = clickReport.mixCount
        m["clicks.maxRatio"] = clickReport.mixRatio
        m["clicks.stemCount"] = clickReport.stemCount
        m["clicks.stemMaxRatio"] = clickReport.stemRatio
        m["clicks.maxAtSeconds"] = clickReport.mixAt
        m["bass.clashBeats"] = clash / outgoing.truth.localBeatPeriod(at: plan.mixPointSeconds)

        if plan.templateId == DJTemplates.echoOut,
           let takeover = log.first(where: { $0.time >= blendStart && $0.crossfade >= 0.99 })?.time {
            let tailSeries = MixMetrics.rmsSeries(result.stemA, sampleRate: sr, window: 0.1, hop: 0.05)
            var lastAudible = takeover
            for (i, v) in tailSeries.enumerated() {
                let t = Double(i) * 0.05 + 0.05
                if t > takeover, MixMetrics.db(v) > -45 { lastAudible = t }
            }
            m["echo.tailSecondsAfterTakeover"] = lastAudible - takeover
            m["echo.takeoverAfterBlendStartSeconds"] = takeover - blendStart
        }

        if let finishEntry = log.first(where: { $0.time >= finish }) {
            let after = log.filter { $0.time >= finish && $0.time <= finish + 30 }
            let rates = after.map(\.rateB)
            m["tempo.rateAtFinish"] = finishEntry.rateB
            m["tempo.postMixChangePercent"] = ((rates.max() ?? 1) - (rates.min() ?? 1)) * 100
        }

        let events = result.mix.events
        if let pause = events.first(where: { $0.label == "pause" }),
           let resume = events.first(where: { $0.label == "resume" }) {
            let atPause = log.last(where: { $0.time <= pause.time })?.crossfade ?? 0
            let atResume = log.first(where: { $0.time >= resume.time })?.crossfade ?? 0
            m["pause.crossfadeJump"] = abs(atResume - atPause)
            m["pause.completedWhilePaused"] = (result.mix.finishTime ?? .infinity) < resume.time ? 1 : 0
            let after = gridPhaseErrors(result: result, from: resume.time + 0.5, to: finish).map { abs($0.error) }
            m["pause.phaseMedianAbsMsAfterResume"] = after.isEmpty ? .nan : MixMetrics.median(after)
            let audio = phaseErrors(result: result, from: resume.time + 0.5, to: finish).map { abs($0.error) }
            m["pause.audioPhaseMedianAbsMsAfterResume"] = audio.isEmpty ? .nan : MixMetrics.median(audio)
        }
        if let seek = events.first(where: { $0.label == "seek" }) {
            let after = gridPhaseErrors(result: result, from: seek.time + 0.5, to: finish).map { abs($0.error) }
            m["seek.phaseMedianAbsMsAfterSeek"] = after.isEmpty ? .nan : MixMetrics.median(after)
            m["seek.pairsAfterSeek"] = Double(after.count)
            let audio = phaseErrors(result: result, from: seek.time + 0.5, to: finish).map { abs($0.error) }
            let local = phaseErrors(result: result, from: seek.time + 0.5, to: finish, localFloor: true)
            m["seek.audioPairsAfterSeek"] = Double(audio.count)
            m["seek.localAudioPairsAfterSeek"] = Double(local.count)
            notes["debug.seekAudioPhase"] = local.map { String(format: "%.2f:%.2f", $0.time, $0.error) }.joined(separator: " ")
            var measured = audio.isEmpty ? local.map { abs($0.error) } : audio
            if measured.isEmpty {
                let before = selfOffsets(result: result, deckA: true, from: blendStart - 8, to: seek.time)
                let selfB = selfOffsets(result: result, deckA: false, from: seek.time + 0.5, to: finish)
                let grid = gridPhaseErrors(result: result, from: seek.time + 0.5, to: finish)
                if !before.isEmpty {
                    let referenceA = MixMetrics.median(before.map(\.offset))
                    measured = selfB.map { b in
                        let g = grid.min { abs($0.time - b.time) < abs($1.time - b.time) }?.error ?? 0
                        return abs(b.offset - referenceA + g)
                    }
                }
                m["seek.selfReferencedPairsAfterSeek"] = Double(measured.count)
            }
            m["seek.audioPhaseMedianAbsMsAfterSeek"] = measured.isEmpty ? .nan : MixMetrics.median(measured)
            let before = log.last(where: { $0.time <= seek.time })?.positionB ?? 0
            let afterB = log.first(where: { $0.time >= seek.time + 0.05 })?.positionB ?? 0
            m["seek.incomingJumpSeconds"] = afterB - before
        }
        return (m, notes)
    }

    static func clicks(
        result: MixRenderer.Result, begin: TimeInterval, finish: TimeInterval
    ) -> (mixCount: Double, mixRatio: Double, stemCount: Double, stemRatio: Double, mixAt: Double) {
        let sr = result.sampleRate
        let count = min(result.mix.left.count, result.stemA.count, result.stemB.count)
        guard count > 2 else { return (0, 0, 0, 0, 0) }
        var mix = [Float](repeating: 0, count: count)
        for i in 0..<count { mix[i] = (result.mix.left[i] + result.mix.right[i]) * 0.5 }
        func delta(_ x: [Float], _ i: Int) -> Float { abs(x[i] - x[i - 1]) }
        func ceiling(_ x: [Float], from: TimeInterval, to: TimeInterval) -> Float {
            let lo = max(1, Int(from * sr))
            let hi = min(count, Int(to * sr))
            var peak: Float = 0
            if hi > lo { for i in lo..<hi { peak = max(peak, delta(x, i)) } }
            return peak
        }
        let mixCeiling = ceiling(mix, from: begin - 10, to: begin - 2)
        let ceilingA = ceiling(result.stemA, from: begin - 10, to: begin - 2)
        let ceilingB = ceiling(result.stemB, from: finish + 2, to: finish + 12)
        let block = 64
        let lo = max(1, Int(begin * sr))
        let hi = min(count - 1, Int((finish + 2) * sr))
        guard hi > lo, mixCeiling > 0 else { return (0, 0, 0, 0, 0) }
        var expected = [Float](repeating: 0, count: (count / block) + 2)
        for i in 1..<count {
            let e = delta(result.stemA, i) + delta(result.stemB, i) + (i < result.stemRiser.count ? delta(result.stemRiser, i) : 0)
            expected[i / block] = max(expected[i / block], e)
        }
        var mixCount = 0.0
        var mixRatio: Float = 0
        var mixAt = 0
        var stemCount = 0.0
        var stemRatio: Float = 0
        for i in lo..<hi {
            let b = i / block
            let local = max(expected[max(0, b - 1)], expected[b], expected[min(expected.count - 1, b + 1)])
            let allowed = max(mixCeiling, local)
            let ratio = delta(mix, i) / allowed
            if ratio > mixRatio { mixRatio = ratio; mixAt = i }
            if ratio > 1.5 { mixCount += 1 }
            if ceilingA > 0 {
                let r = delta(result.stemA, i) / ceilingA
                stemRatio = max(stemRatio, r)
                if r > 1.5 { stemCount += 1 }
            }
            if ceilingB > 0 {
                let r = delta(result.stemB, i) / ceilingB
                stemRatio = max(stemRatio, r)
                if r > 1.5 { stemCount += 1 }
            }
        }
        return (mixCount, Double(mixRatio), stemCount, Double(stemRatio), Double(mixAt) / sr - begin)
    }

    static func maxAbsDifference(_ pass: MixRenderer.Pass, _ replay: (left: [Float], right: [Float])) -> Double {
        let count = min(pass.left.count, replay.left.count)
        var worst: Float = 0
        for i in 0..<count {
            worst = max(worst, abs(pass.left[i] - replay.left[i]), abs(pass.right[i] - replay.right[i]))
        }
        return Double(worst)
    }

    static func writeWav(_ result: MixRenderer.Result, to url: URL) throws {
        let sr = result.sampleRate
        let begin = result.mix.beginTime ?? 0
        let finish = result.mix.finishTime ?? begin
        let from = max(0, Int((begin - 10) * sr))
        let to = min(result.mix.left.count, Int((finish + 15) * sr))
        guard to > from else { return }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = to - from
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        for i in 0..<frames {
            channels[0][i] = result.mix.left[from + i]
            channels[1][i] = result.mix.right[from + i]
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    static let headlineMetrics = [
        "plan.playFraction", "plan.blendBars", "plan.entryOffDownbeatMs",
        "phase.medianAbsMs", "phase.p95AbsMs", "phase.driftRangeMs",
        "downbeat.medianOffsetBeats", "loudness.dipLU", "loudness.engineDipLU", "loudness.momentaryDipLU", "loudness.stepLU",
        "truePeak.dBTP", "bass.clashSeconds", "vocal.overlapSeconds", "clicks.maxRatio",
        "tempo.postMixChangePercent", "pause.crossfadeJump", "pause.phaseMedianAbsMsAfterResume",
        "seek.phaseMedianAbsMsAfterSeek", "phaseAudio.medianAbsMs", "phaseAudio.p95AbsMs", "identity.maxAbsDiff"
    ]

    static func markdown(_ report: AutoMixReport) -> String {
        var lines: [String] = ["# Auto Mix harness — \(report.label)", ""]
        for name in report.scenarios.keys.sorted() {
            let metrics = report.scenarios[name] ?? [:]
            let notes = report.notes[name] ?? [:]
            lines.append("## \(name) (\(notes["template"] ?? "?"))")
            for key in metrics.keys.sorted() {
                let value = metrics[key] ?? .nan
                lines.append("- \(key): \(value.isFinite ? String(format: "%.3f", value) : "n/a")")
            }
            if let error = notes["error"] { lines.append("- error: \(error)") }
            lines.append("")
        }
        lines.append("## Analyser")
        for name in report.analyzer.keys.sorted() {
            let row = report.analyzer[name] ?? [:]
            let note = report.notes["analyzer.\(name)"] ?? [:]
            lines.append("- \(name): bpm \(String(format: "%.2f", row["bpmMeasured"] ?? .nan)) vs \(String(format: "%.2f", row["bpmTruth"] ?? .nan)) (err \(String(format: "%.2f", row["bpmErrorPercent"] ?? .nan))%), key \(note["key"] ?? "?") vs \(note["truthKey"] ?? "?")")
        }
        return lines.joined(separator: "\n")
    }
}

enum AutoMixGates {
    struct Gate {
        let scenario: String
        let metric: String
        let maximum: Double?
        let minimum: Double?

        static func max(_ scenario: String, _ metric: String, _ value: Double) -> Gate {
            Gate(scenario: scenario, metric: metric, maximum: value, minimum: nil)
        }

        static func min(_ scenario: String, _ metric: String, _ value: Double) -> Gate {
            Gate(scenario: scenario, metric: metric, maximum: nil, minimum: value)
        }
    }

    static let measuredBlends = ["measured-blend", "grid-without-sections", "silent-lead-in", "pickup-downbeat", "wide-stretch"]
    static let cpuBudgetPercent = 3.0

    static let gates: [Gate] = measuredBlends.flatMap(blendGates)
        + trackedBlendGates("tracker-blend")
        + ["measured-blend", "echo-out", "live-set-drift", "pickup-downbeat", "early-mixout-cue", "vocal-clash"].map {
            .max($0, "identity.maxAbsDiff", 1e-6)
        }
        + [
            .min("tracker-blend", "plan.blendBars", 15.9),
            .min("tracker-live-set", "plan.blendBars", 8),
            .min("tracker-live-set", "plan.playFraction", 0.65),
            .min("tracker-live-set", "phase.pairs", 8),
            .max("tracker-live-set", "downbeat.medianOffsetBeats", 0),
            .max("tracker-vocal-pair", "vocal.overlapSeconds", 0.5),
            .max("tracker.house-a", "bpmErrorPercent", 0.1),
            .max("tracker.house-b", "bpmErrorPercent", 0.1),
            .max("tracker.pickup-c", "bpmErrorPercent", 0.1),
            .min("tracker.house-a", "downbeatF", 0.95),
            .min("tracker.live-set-d", "downbeatF", 0.95),
            .max("grid-without-sections", "plan.entryOffDownbeatMs", 1),
            .max("silent-lead-in", "plan.entryOffDownbeatMs", 1),
            .min("measured-blend", "plan.blendBars", 15.9),
            .max("bpm-only-grids", "plan.beatBlendBars", 0.1),
            .max("legacy-analyser", "plan.beatBlendBars", 0.1),
            .min("live-set-drift", "plan.playFraction", 0.65),
            .max("live-set-drift", "phase.medianAbsMs", 3),
            .max("live-set-drift", "phase.p95AbsMs", 8),
            .max("live-set-drift", "phaseAudio.medianAbsMs", 3),
            .max("live-set-drift", "phaseAudio.p95AbsMs", 8),
            .min("live-set-drift", "phaseAudio.pairs", AutoMixAnalysis.minimumPhasePairs),
            .max("live-set-drift", "downbeat.medianOffsetBeats", 0),
            .max("live-set-drift", "clicks.count", 0),
            .max("live-set-drift", "loudness.engineDipLU", 1),
            .max("live-set-drift", "clicks.stemCount", 0),
            .max("vocal-clash", "vocal.overlapSeconds", 0.5),
            .min("echo-out", "echo.tailSecondsAfterTakeover", 1),
            .max("echo-out", "clicks.count", 0),
            .max("early-mixout-cue", "plan.exitSeconds", 75),
            .max("pause-mid-blend", "pause.crossfadeJump", 0.02),
            .max("pause-mid-blend", "pause.completedWhilePaused", 0),
            .max("pause-mid-blend", "pause.phaseMedianAbsMsAfterResume", 5),
            .max("pause-mid-blend", "pause.audioPhaseMedianAbsMsAfterResume", 8),
            .max("pause-mid-blend", "stretch.beatOffsetMaxMs", 1),
            .max("pause-mid-blend", "clicks.count", 0),
            .max("pause-same-tempo", "pause.phaseMedianAbsMsAfterResume", 2),
            .min("seek-mid-blend", "seek.incomingJumpSeconds", 3.5),
            .max("seek-mid-blend", "seek.phaseMedianAbsMsAfterSeek", 5),
            .max("seek-mid-blend", "seek.audioPhaseMedianAbsMsAfterSeek", 8),
            .max("seek-mid-blend", "stretch.beatOffsetMaxMs", 1),
            .max("seek-mid-blend", "clicks.count", 0),
            .max("seek-same-tempo", "seek.phaseMedianAbsMsAfterSeek", 2),
            .max("wide-stretch-seek", "seek.phaseMedianAbsMsAfterSeek", 5),
            .max("wide-stretch-seek", "seek.audioPhaseMedianAbsMsAfterSeek", 8),
            .max("wide-stretch-seek", "stretch.beatOffsetMaxMs", 1),
            .max("wide-stretch-seek", "clicks.count", 0),
            .max("cpu", "percentOfRealtime", cpuBudgetPercent),
            .max("house-a", "bpmErrorPercent", 0.1),
            .max("house-b", "bpmErrorPercent", 0.1),
            .max("pickup-c", "bpmErrorPercent", 0.1),
            .min("house-a", "keyCorrect", 1),
            .min("house-b", "keyCorrect", 1),
            .min("pickup-c", "keyCorrect", 1),
            .min("live-set-d", "keyCorrect", 1)
        ]

    static func trackedBlendGates(_ scenario: String) -> [Gate] {
        blendGates(scenario).map { gate in
            switch gate.metric {
            case "phase.medianAbsMs": return .max(scenario, gate.metric, 5)
            case "phaseAudio.medianAbsMs": return .max(scenario, gate.metric, 6)
            case "loudness.engineDipLU": return .max(scenario, gate.metric, 1.5)
            case "phase.p95AbsMs", "phaseAudio.p95AbsMs": return .max(scenario, gate.metric, 10)
            default: return gate
            }
        }
    }

    static func blendGates(_ scenario: String) -> [Gate] {
        [
            .min(scenario, "plan.playFraction", 0.65),
            .min(scenario, "phase.pairs", 8),
            .max(scenario, "phase.medianAbsMs", 3),
            .max(scenario, "phase.p95AbsMs", 8),
            .max(scenario, "phaseAudio.medianAbsMs", 3),
            .max(scenario, "phaseAudio.p95AbsMs", 8),
            .min(scenario, "phaseAudio.pairs", AutoMixAnalysis.minimumPhasePairs),
            .max(scenario, "stretch.beatOffsetMaxMs", 1),
            .max(scenario, "downbeat.medianOffsetBeats", 0),
            .max(scenario, "loudness.engineDipLU", 1),
            .max(scenario, "bass.clashBeats", 1),
            .max(scenario, "clicks.count", 0),
            .max(scenario, "clicks.stemCount", 0),
            .max(scenario, "truePeak.dBTP", -0.3),
            .max(scenario, "tempo.postMixChangePercent", 0.05)
        ]
    }

    static func evaluate(_ report: AutoMixReport) -> [String] {
        var failures: [String] = []
        for (name, notes) in report.notes where notes["error"] != nil {
            failures.append("\(name): \(notes["error"] ?? "")")
        }
        for gate in gates {
            guard let value = report.scenarios[gate.scenario]?[gate.metric] ?? report.analyzer[gate.scenario]?[gate.metric] else {
                failures.append("\(gate.scenario).\(gate.metric) was not measured")
                continue
            }
            if let maximum = gate.maximum, !(value <= maximum) {
                failures.append("\(gate.scenario).\(gate.metric) = \(value), gate ≤ \(maximum)")
            }
            if let minimum = gate.minimum, !(value >= minimum) {
                let reason = gate.metric.hasSuffix(".pairs") ? ": too few pairs" : ""
                failures.append("\(gate.scenario).\(gate.metric) = \(value), gate ≥ \(minimum)\(reason)")
            }
        }
        return failures
    }
}
#endif
