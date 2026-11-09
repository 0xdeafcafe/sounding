import Foundation

extension AutoMixNetObservation {
    nonisolated init(plan: DJTransitionPlan, outgoing: TrackFeatures, incoming: TrackFeatures) {
        let exit = plan.exit.seconds
        let entry = plan.entry.seconds
        let barSeconds = max(0.1, outgoing.beatGrid?.barDuration ?? 2)
        let blend = max(0, Int((plan.overlapSeconds / barSeconds).rounded()))
        func barIndex(_ starts: [TimeInterval], _ seconds: TimeInterval) -> Int? {
            guard !starts.isEmpty else { return nil }
            return starts.lastIndex { $0 <= seconds + 0.05 } ?? 0
        }
        let exitBar = barIndex(outgoing.barStarts, exit)
        let entryBar = barIndex(incoming.barStarts, entry)
        var bands: MixWindowBands?
        var energy: Double?
        var peak: Double?
        if let exitBar, let entryBar {
            bands = AutoMixNetFeatures.estimatedBands(
                outgoingBars: AutoMixNetFeatures.barBands(outgoing.barProfile), exitBar: exitBar,
                incomingBars: AutoMixNetFeatures.barBands(incoming.barProfile), entryBar: entryBar,
                blendBars: blend,
                bassSwapFraction: plan.overlapSeconds > 0 ? plan.bassSwapAtSeconds / plan.overlapSeconds : 0,
                bassSwapBars: plan.bassSwapSeconds / barSeconds
            )
            if let a = outgoing.barProfile?.level, let b = incoming.barProfile?.level {
                energy = AutoMixNetFeatures.energyStep(outgoingLevels: a, exitBar: exitBar, incomingLevels: b, entryBar: entryBar, blendBars: blend)
                let p = [AutoMixNetFeatures.peakProximity(levels: a, from: exitBar), AutoMixNetFeatures.peakProximity(levels: b, from: entryBar)].compactMap { $0 }
                peak = p.min()
            }
        }
        if energy == nil, let a = outgoing.energyLevel, let b = incoming.energyLevel { energy = Double(b - a) }
        var bpm: Double?
        if let a = outgoing.beatGrid?.bpm, let b = incoming.beatGrid?.bpm, a > 0, b > 0 {
            bpm = AutoMixNetFeatures.residualTempoPercent(outgoingBPM: a, incomingBPM: b, rate: plan.incomingRateRatio)
        }
        var vocal: Double?
        if outgoing.provenance.contains(.measuredVocals), incoming.provenance.contains(.measuredVocals) {
            vocal = DJMixRules.vocalOverlapSeconds(outgoing: outgoing.vocalRanges, from: exit, length: plan.overlapSeconds, incoming: incoming.vocalRanges, entry: entry)
        }
        var phase: Double?
        if let a = outgoing.beatGrid, let b = incoming.beatGrid {
            let errors = [
                AutoMixNetFeatures.phaseErrorBeats(exit, downbeats: a.downbeats ?? [a.nearestDownbeat(to: exit)], beatPeriod: a.beatPeriod),
                AutoMixNetFeatures.phaseErrorBeats(entry, downbeats: b.downbeats ?? [b.nearestDownbeat(to: entry)], beatPeriod: b.beatPeriod)
            ].compactMap { $0 }
            phase = errors.max()
        }
        let confidences = [outgoing.beatGrid?.confidence, incoming.beatGrid?.confidence].compactMap { $0 }
        self.init(
            moveType: AutoMixTransitionFeatures.moveType(templateId: plan.templateId, move: plan.move?.kind),
            blendBars: Double(blend),
            energyStep: energy,
            bands: bands,
            vocalOverlapSeconds: vocal,
            phaseErrorBeats: phase,
            gridConfidence: confidences.min(),
            keyDistance: DJMoveSupport.keySteps(outgoing, at: exit, incoming, at: entry),
            bpmDeltaPercent: bpm,
            exitSection: plan.exit.kind.rawValue,
            entrySection: plan.entry.kind.rawValue,
            peakProximityBars: peak
        )
    }
}

extension AutoMixNetModel {
    nonisolated func adjustment(for plan: DJTransitionPlan, outgoing: TrackFeatures, incoming: TrackFeatures) -> Double {
        guard let prediction = predict(AutoMixNetObservation(plan: plan, outgoing: outgoing, incoming: incoming)) else { return 0 }
        return AutoMixNetExperiment.adjustment(good: prediction.good)
    }
}
