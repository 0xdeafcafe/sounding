import XCTest
@testable import SoundingTV

final class SonosStreamPacerTests: XCTestCase {
    private let rate = 44_100.0

    private func ns(_ seconds: Double) -> UInt64 {
        UInt64((seconds * 1_000_000_000).rounded())
    }

    private struct Run {
        var pacer: SonosStreamPacer
        var ring = 0
        var produced = 0
        var read = 0
        var silence = 0
        var discarded = 0
        var maxLagFrames = 0
        var maxLeadFrames = 0

        mutating func tick(at now: UInt64) {
            let step = pacer.step(at: now, available: ring)
            ring -= step.discard + step.read
            read += step.read
            silence += step.silence
            discarded += step.discard
            let target = Int(pacer.targetFrames(at: now))
            let emitted = Int(pacer.emittedFrames)
            maxLagFrames = max(maxLagFrames, target - emitted)
            maxLeadFrames = max(maxLeadFrames, emitted - target)
        }
    }

    private func start() -> Run {
        var pacer = SonosStreamPacer(sampleRate: rate)
        pacer.reset(at: 0)
        return Run(pacer: pacer)
    }

    func testRealtimeDeliveryPassesThroughUntouched() {
        var run = start()
        for tick in 1...500 {
            let now = ns(Double(tick) * 0.02)
            if tick % 5 == 0 {
                run.ring += 4_410
                run.produced += 4_410
            }
            run.tick(at: now)
        }
        XCTAssertEqual(run.silence, 0)
        XCTAssertEqual(run.discarded, 0)
        XCTAssertEqual(run.read, run.produced)
    }

    func testSlowRenderDuringMixIsPaddedSoSonosNeverStarves() {
        var run = start()
        var owed = 0.0
        for tick in 1...3_000 {
            let now = ns(Double(tick) * 0.02)
            owed += 0.02 * rate * 0.7
            if tick % 5 == 0 {
                run.ring += Int(owed)
                run.produced += Int(owed)
                owed -= Double(Int(owed))
            }
            run.tick(at: now)
        }
        let wall = Int(60 * rate)
        XCTAssertGreaterThan(run.silence, 0)
        XCTAssertLessThanOrEqual(run.maxLagFrames, run.pacer.lagFrames + 4_410)
        XCTAssertGreaterThanOrEqual(Int(run.pacer.emittedFrames), wall - run.pacer.lagFrames - 4_410)
    }

    func testLateBurstAfterStallKeepsTheLiveEdgeAndNeverRunsAhead() {
        var run = start()
        for tick in 1...100 {
            if tick % 5 == 0 { run.ring += 4_410 }
            run.tick(at: ns(Double(tick) * 0.02))
        }
        for tick in 101...150 {
            run.tick(at: ns(Double(tick) * 0.02))
        }
        XCTAssertGreaterThan(run.silence, 0)
        run.ring += Int(2 * rate)
        run.tick(at: ns(151 * 0.02))
        XCTAssertLessThanOrEqual(run.maxLeadFrames, run.pacer.leadFrames)
        XCTAssertLessThanOrEqual(run.ring, run.pacer.backlogFrames)
        XCTAssertGreaterThan(run.discarded, 0)
    }

    func testStreamNeverRunsAheadOfTheWallClock() {
        var run = start()
        for tick in 1...200 {
            run.ring += 2_000
            run.tick(at: ns(Double(tick) * 0.02))
        }
        XCTAssertLessThanOrEqual(run.maxLeadFrames, run.pacer.leadFrames)
        XCTAssertLessThanOrEqual(run.ring, run.pacer.backlogFrames + run.pacer.leadFrames)
    }

    func testPausedEngineStreamsSilenceAtRealtime() {
        var run = start()
        for tick in 1...500 {
            run.tick(at: ns(Double(tick) * 0.02))
        }
        let wall = Int(10 * rate)
        XCTAssertEqual(run.read, 0)
        XCTAssertGreaterThanOrEqual(run.silence, wall - run.pacer.lagFrames - 1)
        XCTAssertLessThanOrEqual(run.silence, wall)
    }

    func testLongSuspensionResyncsInsteadOfBurstingMinutesOfSilence() {
        var run = start()
        run.tick(at: ns(0.02))
        run.tick(at: ns(120))
        XCTAssertLessThanOrEqual(run.silence, run.pacer.resyncFrames)
        run.tick(at: ns(120.02))
        XCTAssertLessThanOrEqual(run.maxLeadFrames, run.pacer.leadFrames)
        XCTAssertLessThanOrEqual(Int(run.pacer.targetFrames(at: ns(120.02))) - Int(run.pacer.emittedFrames), run.pacer.lagFrames + 1_000)
    }

    func testDiscardDropsTheOldestFramesSoReadsStayLive() {
        let ring = SonosAudioRingBuffer(capacityFrames: 16, channels: 2)
        let left: [Float] = (1...10).map(Float.init)
        left.withUnsafeBufferPointer { l in
            let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
            pointers[0] = UnsafeMutablePointer(mutating: l.baseAddress!)
            pointers[1] = UnsafeMutablePointer(mutating: l.baseAddress!)
            ring.write(UnsafePointer(pointers), channelCount: 2, frames: 10)
            pointers.deallocate()
        }
        XCTAssertEqual(ring.discard(frames: 7), 7)
        var out = [Float](repeating: 0, count: 3)
        out.withUnsafeMutableBufferPointer { o in
            let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1)
            pointers[0] = o.baseAddress!
            XCTAssertEqual(ring.read(into: UnsafePointer(pointers), channelCount: 1, frames: 3), 3)
            pointers.deallocate()
        }
        XCTAssertEqual(out, [8, 9, 10])
    }
}
