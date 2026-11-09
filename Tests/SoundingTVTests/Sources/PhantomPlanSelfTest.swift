import Foundation
import XCTest
@testable import SoundingTV

#if DEBUG

final class PhantomPlanTests: XCTestCase {
    func testPhantomPlanSelfTest() {
        let report = PhantomPlanSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: "\n"))
    }
}

enum PhantomPlanSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[PhantomPlanTest] \(status)"] + lines.map { "[PhantomPlanTest]   \($0)" }
                + failures.map { "[PhantomPlanTest]   ✗ \($0)" }).joined(separator: "\n")
        }
    }

    static func run() -> Report {
        var report = Report()

        func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                report.lines.append("\(name) → ok")
            } else {
                report.failures.append(name)
            }
        }

        do {
            let duration = 100.0
            let loudCount = 70
            let decayCount = 30
            var envelope = [Float](repeating: 0.8, count: loudCount)
            for step in 0..<decayCount {
                let t = Double(step) / Double(decayCount - 1)
                envelope.append(Float(0.78 - t * (0.78 - 0.02)))
            }
            guard let plan = PhantomDJEngine.plan(outgoingDuration: duration, envelope: envelope) else {
                report.failures.append("fade-to-silence: expected a plan, got nil")
                return report
            }
            expect("fade-to-silence shape", plan.outroShape == .fadeToSilence)
            expect("fade-to-silence accent", plan.accent == .incomingFilterOpen)
            expect(
                "fade-to-silence transition in range",
                plan.transitionSeconds >= 6 && plan.transitionSeconds <= DJEngineConstants.maximumTransitionSeconds
            )
            expect(
                "fade-to-silence mix point inside search window",
                plan.mixPointSeconds >= duration * 0.55 && plan.mixPointSeconds < duration
            )
            expect(
                "fade-to-silence transition fits before the end",
                plan.mixEndSeconds <= duration + 0.01
            )
        }

        do {
            let duration = 100.0
            let loudCount = 85
            let dipCount = 15
            let envelope = [Float](repeating: 0.8, count: loudCount) + [Float](repeating: 0.3, count: dipCount)
            guard let plan = PhantomDJEngine.plan(outgoingDuration: duration, envelope: envelope) else {
                report.failures.append("breakdown: expected a plan, got nil")
                return report
            }
            expect("breakdown shape", plan.outroShape == .breakdown)
            expect("breakdown accent", plan.accent == .outgoingFilterClose)
            expect("breakdown mix point before the dip's midpoint", plan.mixPointSeconds <= 92)
        }

        do {
            let duration = 100.0
            let envelope = [Float](repeating: 0.8, count: 100)
            guard let plan = PhantomDJEngine.plan(outgoingDuration: duration, envelope: envelope) else {
                report.failures.append("hard stop: expected a plan, got nil")
                return report
            }
            expect("hard stop shape", plan.outroShape == .hardStop)
            expect("hard stop has no accent", plan.accent == nil)
            expect(
                "hard stop transition is short",
                plan.transitionSeconds == DJEngineConstants.minimumTransitionSeconds
            )
        }

        expect(
            "short track rejected",
            PhantomDJEngine.plan(outgoingDuration: 10, envelope: [Float](repeating: 0.5, count: 10)) == nil
        )
        expect(
            "empty envelope rejected",
            PhantomDJEngine.plan(outgoingDuration: 200, envelope: []) == nil
        )

        if let fallback = PhantomDJEngine.fallbackPlan(outgoingDuration: 200) {
            expect("fallback plan shape", fallback.outroShape == .unknown)
            expect("fallback plan capped", fallback.transitionSeconds <= 16)
            expect("fallback plan reasoning mentions no waveform", fallback.reasoning.contains("No waveform"))
        } else {
            report.failures.append("fallback plan: expected a plan for a 200s track, got nil")
        }
        expect("fallback plan rejects short tracks", PhantomDJEngine.fallbackPlan(outgoingDuration: 10) == nil)

        if let cleanCut = PhantomDJEngine.cleanCutFallbackPlan(
            outgoingDuration: 200,
            incomingTrackId: "next",
            profile: .weddingDJ
        ) {
            expect("deadline fallback is the catalog clean cut", cleanCut.templateId == DJTemplates.cutOnTheOne)
            expect("deadline fallback keeps the incoming track", cleanCut.incomingTrackId == "next")
            expect("deadline fallback plays nearly to the end", cleanCut.mixPointSeconds > 199)
            expect("deadline fallback never becomes a generic blend",
                   cleanCut.transitionSeconds == CutOnTheOneTemplate.fadeSeconds)
            expect("a clean cut projects a hardCut stage, not a fake fader ramp",
                   cleanCut.presentationStages.contains { if case .hardCut = $0.action { return true }; return false })
            expect("a clean cut's projected stages contain no eqLow ramp",
                   !cleanCut.presentationStages.contains { if case .eqLow = $0.action { return true }; return false })
        } else {
            report.failures.append("deadline fallback: expected a clean cut for a 200s track, got nil")
        }

        return report
    }
}
#endif
