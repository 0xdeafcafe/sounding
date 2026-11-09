import SwiftUI
import Foundation

extension DJPlanPayload {
    init(plan: PhantomDJEngine.Plan, profileName: String?) {
        self.init(
            templateName: plan.rationale?.templateName
                ?? plan.templateId.map { DJTemplates.displayName(for: $0) },
            profileName: profileName,
            mixPointSeconds: plan.mixPointSeconds,
            transitionSeconds: plan.transitionSeconds,
            entrySeconds: plan.entrySeconds,
            reasoning: plan.rationale?.reasoning ?? plan.reasoning,
            score: plan.rationale?.score,
            stages: plan.presentationStages.map {
                DJPlanStagePayload(
                    atSeconds: $0.atSeconds,
                    deck: $0.deck.rawValue,
                    action: $0.action.summary,
                    snap: $0.snap.rawValue,
                    durationSeconds: $0.action.durationSeconds
                )
            }
        )
    }
}

/// The measured controls displayed alongside a transition plan. Both local
/// consoles and the remote iPhone adapt their native session read models to
/// this small value, keeping the presentation and formatting shared.
struct DJAutomationReadout: Equatable {
    struct Deck: Equatable {
        let lowDB: Double
        let midDB: Double
        let highDB: Double
        let filterCutoffHz: Double
        let highPassCutoffHz: Double?
        let filterResonance: Double
        let rate: Double
        let delayWet: Double?
        let loopLengthSeconds: Double?
        let level: Double?
        let peak: Double?
    }

    let deckA: Deck
    let deckB: Deck
    let crossfade: Double

    init(deckA: DJDeckStatePayload, deckB: DJDeckStatePayload, crossfade: Double) {
        self.deckA = Deck(
            lowDB: deckA.eqLowDb,
            midDB: deckA.eqMidDb,
            highDB: deckA.eqHighDb,
            filterCutoffHz: deckA.filterCutoffHz,
            highPassCutoffHz: deckA.highPassCutoffHz,
            filterResonance: deckA.filterResonance,
            rate: deckA.rate,
            delayWet: deckA.delayWetMix,
            loopLengthSeconds: deckA.loopLengthSeconds,
            level: deckA.level,
            peak: deckA.peak
        )
        self.deckB = Deck(
            lowDB: deckB.eqLowDb,
            midDB: deckB.eqMidDb,
            highDB: deckB.eqHighDb,
            filterCutoffHz: deckB.filterCutoffHz,
            highPassCutoffHz: deckB.highPassCutoffHz,
            filterResonance: deckB.filterResonance,
            rate: deckB.rate,
            delayWet: deckB.delayWetMix,
            loopLengthSeconds: deckB.loopLengthSeconds,
            level: deckB.level,
            peak: deckB.peak
        )
        self.crossfade = crossfade
    }

    init(snapshot: DJSessionSnapshot) {
        func deck(_ identity: MixEngine.Deck) -> Deck {
            guard let state = snapshot.decks.first(where: { $0.deck == identity })?.state else {
                return Deck(
                    lowDB: 0, midDB: 0, highDB: 0,
                    filterCutoffHz: 20_000, highPassCutoffHz: 20,
                    filterResonance: 0, rate: 1, delayWet: 0,
                    loopLengthSeconds: nil, level: 0, peak: 0
                )
            }
            return Deck(
                lowDB: state.low,
                midDB: state.mid,
                highDB: state.high,
                filterCutoffHz: state.filterCutoff,
                highPassCutoffHz: state.highPassCutoff,
                filterResonance: state.filterResonance,
                rate: state.rate,
                delayWet: state.delayWet,
                loopLengthSeconds: state.loopLengthSeconds,
                level: Double(state.level),
                peak: Double(state.peak)
            )
        }
        deckA = deck(.a)
        deckB = deck(.b)
        crossfade = snapshot.crossfade
    }
}

/// Shared, ordered executor timeline. Stage offsets are relative to the mix
/// point, just as they are in the executor; while a plan is running, completed
/// stages brighten and the next stage is accented from the live playhead.
struct DJTransitionStageTimeline: View {
    let plan: DJPlanPayload
    let currentTime: TimeInterval
    let isExecuting: Bool
    var tint: Color = .scAccent
    var maxStages = 5
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleStages: [DJPlanStagePayload] {
        Array(plan.stages.sorted { $0.atSeconds < $1.atSeconds }.prefix(maxStages))
    }

    private var elapsed: TimeInterval? {
        guard isExecuting else { return nil }
        return max(0, currentTime - plan.mixPointSeconds)
    }

    var body: some View {
        if !visibleStages.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                HStack(spacing: 6) {
                    Text(isExecuting ? "PERFORMING" : "AUTOMATION")
                    if let elapsed {
                        Text("\(Self.clock(elapsed)) / \(Self.clock(plan.transitionSeconds))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font((compact ? Font.caption2 : Font.caption).monospaced().weight(.heavy))
                .foregroundStyle(tint)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: compact ? 4 : 7) {
                            ForEach(Array(visibleStages.enumerated()), id: \.offset) { index, stage in
                                stageCell(stage, index: index)
                                    .id(index)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: activeAnchorIndex, initial: true) { _, index in
                        guard let index else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
        }
    }

    private func stageCell(_ stage: DJPlanStagePayload, index: Int) -> some View {
        let state = stageState(stage, index: index)
        let isHighlighted = state.isActive || state.isNext || state.isComplete

        return VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(state.isActive || state.isNext ? tint : Color.white.opacity(state.isComplete ? 0.55 : 0.18))
                    .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
                Text(timingLabel(for: stage))
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text(state.label)
                    .foregroundStyle(state.isActive ? tint : .secondary)
            }
            .font((compact ? Font.caption2 : Font.caption).monospaced().weight(.heavy))
            .foregroundStyle(state.isActive || state.isNext ? tint : .secondary)

            Text("\(stage.deck == "outgoing" ? "OUT" : "IN") · \(stage.action)")
                .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
                .foregroundStyle(.primary.opacity(isHighlighted ? 0.92 : 0.55))
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            GeometryReader { proxy in
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(state.isActive || state.isComplete ? tint : Color.white.opacity(0.20))
                            .frame(width: max(2, proxy.size.width * state.progress))
                    }
            }
            .frame(height: compact ? 3 : 4)
        }
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 4 : 6)
        .frame(width: compact ? 118 : 148, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous)
                .fill((isHighlighted ? tint : Color.white).opacity(isHighlighted ? 0.10 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous)
                .stroke((state.isActive || state.isNext ? tint : Color.white).opacity(state.isActive || state.isNext ? 0.34 : 0.08))
        )
    }

    private var activeAnchorIndex: Int? {
        guard !visibleStages.isEmpty else { return nil }
        guard let elapsed else { return 0 }
        if let latest = visibleStages.indices.last(where: { visibleStages[$0].atSeconds <= elapsed }) {
            return latest
        }
        return visibleStages.indices.first
    }

    private struct StageState {
        var isActive = false
        var isNext = false
        var isComplete = false
        var progress = 0.0

        var label: String {
            if isActive { return "LIVE" }
            if isComplete { return "DONE" }
            if isNext { return "NEXT" }
            return "QUEUED"
        }
    }

    private func stageState(_ stage: DJPlanStagePayload, index: Int) -> StageState {
        guard let elapsed else {
            let firstTime = visibleStages.first?.atSeconds
            return StageState(isNext: stage.atSeconds == firstTime)
        }

        guard elapsed >= stage.atSeconds else {
            let nextTime = visibleStages
                .map(\.atSeconds)
                .filter { $0 > elapsed }
                .min()
            return StageState(isNext: stage.atSeconds == nextTime)
        }

        let explicitDuration = max(0, stage.durationSeconds ?? 0)
        let nextTime = visibleStages
            .map(\.atSeconds)
            .filter { $0 > stage.atSeconds }
            .min()
        let inferredDuration = max(0, (nextTime ?? plan.transitionSeconds) - stage.atSeconds)
        let duration = explicitDuration > 0 ? explicitDuration : inferredDuration

        // Loops remain live until the next operation; other zero-duration
        // actions (release, snap, cut) complete immediately.
        let isLoop = stage.action.localizedCaseInsensitiveContains("loop")
            && !stage.action.localizedCaseInsensitiveContains("release")
        if duration > 0 && (explicitDuration > 0 || isLoop) && elapsed < stage.atSeconds + duration {
            return StageState(
                isActive: true,
                progress: min(1, max(0, (elapsed - stage.atSeconds) / duration))
            )
        }
        return StageState(isComplete: true, progress: 1)
    }

    private func timingLabel(for stage: DJPlanStagePayload) -> String {
        if !isExecuting {
            let remaining = plan.mixPointSeconds + stage.atSeconds - currentTime
            if remaining > 0 { return "in \(Self.clock(remaining))" }
        }
        return String(format: "+%.1fs", stage.atSeconds)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private var accessibilitySummary: String {
        visibleStages.map { stage in
            "At plus \(String(format: "%.1f", stage.atSeconds)) seconds, \(stage.deck), \(stage.action)"
        }.joined(separator: ". ")
    }
}

/// Shared plan/rationale/automation card used by phone and Mac. The TV embeds
/// the same stage timeline in its denser mixer panel and keeps its larger
/// physical knob treatment beneath it.
struct DJTransitionPlanCard: View {
    let decision: DJAutomaticMixDecision
    let plan: DJPlanPayload?
    let currentTime: TimeInterval
    let automation: DJAutomationReadout
    var tint: Color = .scAccent
    var compact = false

    private var isExecuting: Bool {
        decision.phase == .mixing || decision.phase == .cutting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            header

            if let reasoning = plan?.reasoning ?? decision.reasoning,
               !reasoning.isEmpty, reasoning != decision.headline {
                Text(reasoning)
                    .font((compact ? Font.caption : Font.footnote).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 3)
            }

            if let plan {
                DJTransitionStageTimeline(
                    plan: plan,
                    currentTime: currentTime,
                    isExecuting: isExecuting,
                    tint: tint,
                    maxStages: 10,
                    compact: compact
                )
            }

            automationRows
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: decision.isFallback ? "arrow.right.circle.fill" : "wand.and.stars.inverse")
                .font((compact ? Font.callout : Font.title3).weight(.bold))
                .foregroundStyle(decision.isFallback ? Color.orange : tint)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(decision.statusLabel.uppercased())
                    if let countdown = decision.countdownText(currentTime: currentTime) {
                        Text("· \(countdown)")
                    }
                    if let score = plan?.score ?? decision.score {
                        Text("· \(Int((score * 100).rounded()))%")
                    }
                }
                .font((compact ? Font.caption2 : Font.caption).monospaced().weight(.heavy))
                .foregroundStyle(decision.isFallback ? Color.orange : tint)

                Text(plan?.templateName ?? decision.templateName ?? decision.headline)
                    .font((compact ? Font.footnote : Font.subheadline).weight(.bold))
                    .lineLimit(1)

                if let profile = plan?.profileName ?? decision.profileName {
                    Text(profile)
                        .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var automationRows: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                deckReadout("A", automation.deckA)
                crossfaderReadout
                deckReadout("B", automation.deckB)
            }
            VStack(spacing: 6) {
                deckReadout("A", automation.deckA)
                crossfaderReadout
                deckReadout("B", automation.deckB)
            }
        }
    }

    private func deckReadout(_ label: String, _ deck: DJAutomationReadout.Deck) -> some View {
        HStack(spacing: compact ? 5 : 7) {
            Text(label)
                .font(Font.caption2.monospaced().weight(.black))
                .foregroundStyle(tint)
            automationValue("LOW", Self.db(deck.lowDB))
            automationValue("MID", Self.db(deck.midDB))
            automationValue("HIGH", Self.db(deck.highDB))
            automationValue("LP", Self.hertz(deck.filterCutoffHz))
            if let highPass = deck.highPassCutoffHz, highPass > 25 {
                automationValue("HP", Self.hertz(highPass))
            }
            if deck.filterResonance > 0.01 {
                automationValue("RES", String(format: "%.2f", deck.filterResonance))
            }
            automationValue("RATE", String(format: "×%.3f", deck.rate))
            if let wet = deck.delayWet, wet > 0.005 {
                automationValue("DELAY", "\(Int((wet * 100).rounded()))%")
            }
            if let loopLength = deck.loopLengthSeconds {
                automationValue("LOOP", Self.seconds(loopLength))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var crossfaderReadout: some View {
        VStack(spacing: 3) {
            Text("CROSSFADER \(Int((automation.crossfade * 100).rounded()))%")
                .font(Font.caption2.monospaced().weight(.heavy))
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(tint)
                            .frame(width: 7, height: 7)
                            .offset(x: max(0, (proxy.size.width - 7) * min(1, max(0, automation.crossfade))))
                    }
            }
            .frame(minWidth: 54, maxWidth: 90, minHeight: 7, maxHeight: 7)
        }
    }

    private func automationValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(Font.caption2.monospaced().weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font((compact ? Font.caption2 : Font.caption).monospaced().weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private static func db(_ value: Double) -> String {
        value <= -40 ? "−∞" : String(format: "%+.0f", value)
    }

    private static func hertz(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.1fk", value / 1_000) : "\(Int(value.rounded()))"
    }

    private static func seconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1fs", value) : "\(Int(value.rounded()))s"
    }
}

struct AutoMixJourney: Equatable {
    struct Step: Equatable {
        let outgoingTitle: String
        let outgoingDuration: Double?
        let leaveAtSeconds: Double
        let styleName: String?
        let blendSeconds: Double
        let incomingTitle: String?
        let joinAtSeconds: Double

        var leavesMidTrack: Bool {
            guard let outgoingDuration, outgoingDuration > 0 else { return false }
            return leaveAtSeconds + blendSeconds < outgoingDuration - 45
        }

        var joinsMidTrack: Bool { joinAtSeconds > 1 }
    }

    let profileName: String?
    let currentPosition: Double?
    let next: Step
    let later: Step?

    init?(
        snapshot: DJSessionSnapshot,
        nowTitle: String?,
        nextTitle: String?,
        laterTitle: String?
    ) {
        guard snapshot.isAutoMixEnabled else { return nil }
        guard let plan = snapshot.activePlan ?? snapshot.upcomingPlan else { return nil }
        let live = snapshot.liveDeckSnapshot
        profileName = snapshot.profile?.displayName
        currentPosition = live?.position
        next = Step(
            outgoingTitle: nowTitle ?? "Current track",
            outgoingDuration: live.map(\.duration),
            leaveAtSeconds: plan.mixPointSeconds,
            styleName: plan.rationale?.templateName
                ?? plan.templateId.map { DJTemplates.displayName(for: $0) },
            blendSeconds: plan.transitionSeconds,
            incomingTitle: nextTitle,
            joinAtSeconds: plan.entrySeconds
        )
        if snapshot.activePlan != nil, let following = snapshot.upcomingPlan,
           following != snapshot.activePlan {
            later = Step(
                outgoingTitle: nextTitle ?? "Next track",
                outgoingDuration: nil,
                leaveAtSeconds: following.mixPointSeconds,
                styleName: following.rationale?.templateName
                    ?? following.templateId.map { DJTemplates.displayName(for: $0) },
                blendSeconds: following.transitionSeconds,
                incomingTitle: laterTitle,
                joinAtSeconds: following.entrySeconds
            )
        } else {
            later = nil
        }
    }

    init?(
        payload: DJPlanPayload?,
        profileName: String?,
        nowTitle: String?,
        nextTitle: String?,
        currentPosition: Double?,
        nowDuration: Double?
    ) {
        guard let payload else { return nil }
        self.profileName = profileName ?? payload.profileName
        self.currentPosition = currentPosition
        next = Step(
            outgoingTitle: nowTitle ?? "Current track",
            outgoingDuration: nowDuration,
            leaveAtSeconds: payload.mixPointSeconds,
            styleName: payload.templateName,
            blendSeconds: payload.transitionSeconds,
            incomingTitle: nextTitle,
            joinAtSeconds: payload.entrySeconds
        )
        later = nil
    }
}

struct AutoMixJourneyView: View {
    let journey: AutoMixJourney

    #if os(tvOS)
    private static let rowSpacing: CGFloat = 14
    #else
    private static let rowSpacing: CGFloat = 7
    #endif

    @ScaledMetric(relativeTo: .footnote) private var iconWidth: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(Font.footnote.weight(.semibold))
                    .foregroundStyle(Color.scAccent)
                Text(journey.profileName.map { "Auto Mix · \($0)" } ?? "Auto Mix")
                    .font(Font.subheadline.weight(.bold))
            }
            row(
                icon: "play.fill",
                title: journey.next.outgoingTitle,
                detail: nowDetail(for: journey.next)
            )
            row(
                icon: "arrow.triangle.merge",
                title: blendTitle(for: journey.next),
                detail: blendDetail(for: journey.next)
            )
            if let incoming = journey.next.incomingTitle {
                row(
                    icon: "forward.fill",
                    title: incoming,
                    detail: joinDetail(for: journey.next)
                )
            }
            if let later = journey.later {
                row(
                    icon: "ellipsis",
                    title: laterTitle(for: later),
                    detail: laterDetail(for: later)
                )
            }
        }
    }

    private func row(icon: String, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(Font.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Font.footnote.weight(.semibold))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func nowDetail(for step: AutoMixJourney.Step) -> String {
        var parts: [String] = []
        if step.leavesMidTrack {
            parts.append("leaving early at \(Self.clock(step.leaveAtSeconds))")
        } else {
            parts.append("mixing out at \(Self.clock(step.leaveAtSeconds))")
        }
        if let position = journey.currentPosition {
            let remaining = step.leaveAtSeconds - position
            if remaining > 0, remaining < 3_600 {
                parts.append("in \(Self.clock(remaining))")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func blendTitle(for step: AutoMixJourney.Step) -> String {
        step.styleName ?? "Blend"
    }

    private func blendDetail(for step: AutoMixJourney.Step) -> String {
        let rounded = max(1, Int(step.blendSeconds.rounded()))
        return rounded <= 2 ? "a quick switch" : "about \(rounded) seconds long"
    }

    private func joinDetail(for step: AutoMixJourney.Step) -> String {
        step.joinsMidTrack
            ? "joins partway in, from \(Self.clock(step.joinAtSeconds))"
            : "starts from the top"
    }

    private func laterTitle(for step: AutoMixJourney.Step) -> String {
        if let incoming = step.incomingTitle { return "Then \(incoming)" }
        return "After that"
    }

    private func laterDetail(for step: AutoMixJourney.Step) -> String {
        var text = step.styleName.map { "\($0.lowercased()) out of \(step.outgoingTitle)" }
            ?? "mixing out of \(step.outgoingTitle)"
        if step.leavesMidTrack { text += ", leaving early" }
        return text
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
