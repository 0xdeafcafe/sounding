#if DEBUG
import Foundation
import SwiftUI

@MainActor
enum MixHistoryHarness {
    @ViewBuilder
    static func view(route: String?) -> some View {
        let store = MixHistoryStore.shared
        switch route {
        case "overview":
            if let session = store.sessions.first {
                MixSetOverviewView(session: session, name: "Friday warm-up")
            }
        case "detail":
            if let entry = store.entries.first {
                MixTransitionDetailView(entry: entry)
            }
        default:
            MixHistoryView()
        }
    }

    @ViewBuilder
    static func staticView(route: String?, width: CGFloat) -> some View {
        #if os(macOS)
        if route == "dj-plan" {
            DJPlanFixtureScreen()
        } else {
            historyView(route: route, width: width)
        }
        #else
        historyView(route: route, width: width)
        #endif
    }

    @ViewBuilder
    private static func historyView(route: String?, width: CGFloat) -> some View {
        let store = MixHistoryStore.shared
        VStack(alignment: .leading, spacing: 14) {
            switch route {
            case "overview":
                if let session = store.sessions.first {
                    let layout = MixSetLayout(session: session)
                    Text("Friday warm-up").font(.title2.bold())
                    MixSetTimelineCanvas(layout: layout, perSecond: (width - 40) / CGFloat(layout.duration), selectedTime: layout.blends[2].setStart + 4, hoverTime: layout.blends[2].setStart + 4)
                        .frame(height: MixSetTimelineCanvas.height)
                        .background(Color.black)
                        .environment(\.colorScheme, .dark)
                    Text("Tracklist").font(.headline)
                    ForEach(layout.segments) { segment in
                        HStack {
                            Text(MixSetLayout.timestamp(segment.setStart)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                            Text(segment.track.title)
                            Text(segment.track.artist).foregroundStyle(.secondary)
                            Spacer()
                            Text(MixTransitionDetailView.trackDetail(segment.track)).foregroundStyle(.secondary)
                        }
                    }
                }
            case "detail":
                if let entry = store.entries.first {
                    let state = entry.liveState(now: Date(timeIntervalSinceReferenceDate: 0))
                    Text(entry.title).font(.title2.bold())
                    VStack(alignment: .leading, spacing: 8) {
                        AutoMixTransitionView(state: state, scale: .mac, tint: .white)
                        if let outgoing = state.outgoing {
                            AutoMixDeckLane(state: state, deck: outgoing, label: "A", audibility: 1, position: outgoing.positionSeconds, scale: .mac, showsLoop: true)
                        }
                        if let incoming = state.incoming {
                            AutoMixDeckLane(state: state, deck: incoming, label: "B", audibility: 1, position: incoming.positionSeconds, scale: .mac)
                        }
                    }
                    .padding(12)
                    .background(Color.black)
                    .environment(\.colorScheme, .dark)
                    LabeledContent("Move", value: entry.moveName)
                    LabeledContent("Exit", value: MixTransitionDetailView.point(entry.plan.mixPointSeconds, bar: entry.plan.exitBar))
                    LabeledContent("Entry", value: MixTransitionDetailView.point(entry.execution.entrySeconds, bar: entry.plan.entryBar))
                    LabeledContent("Tempo", value: MixTransitionDetailView.tempo(entry))
                    LabeledContent("Rating", value: entry.ratingLabel ?? "Not rated")
                }
            default:
                Text("Mixes").font(.title2.bold())
                ForEach(store.recent) { entry in
                    MixHistoryRow(entry: entry)
                }
            }
        }
        .padding(20)
        .frame(width: width, alignment: .topLeading)
    }
}

extension MixHistoryStore {
    static var isFixtureRequested: Bool {
        ProcessInfo.processInfo.environment["SOUNDING_TV_MIX_HISTORY_FIXTURE"] != nil
    }

    static func fixtureEntries(now: Date = Date()) -> [MixHistoryEntry] {
        let tracks = Array(VisualFixtures.tracks.prefix(6))
        let bpms: [Double] = [122, 124, 124, 126, 126, 128]
        let keys = ["8A", "8A", "9A", "9B", "10A", "10A"]
        let energy = [4, 5, 6, 7, 8, 7]
        let moves: [MixMove] = [
            .loopMix(outLoop: 4, inLoop: 4, fadeIn: 8, fadeOut: 4),
            .blend(bars: 16, swapAt: 8),
            .loopRoll(MixMove.standardLadder),
            .dropIn(buildBars: 8, outBars: 2),
            .echoOut
        ]
        let ratings: [Bool?] = [true, nil, true, false, nil]
        let session = UUID()
        var entries: [MixHistoryEntry] = []
        var clock = now.addingTimeInterval(-3 * 3600)
        for index in 0..<moves.count {
            let out = tracks[index]
            let into = tracks[index + 1]
            let outGrid = BeatGrid(anchor: 0.1, beatPeriod: 60 / bpms[index], confidence: 0.9)
            let inGrid = BeatGrid(anchor: 0.05, beatPeriod: 60 / bpms[index + 1], confidence: 0.9)
            let move = moves[index]
            let bar = outGrid.barDuration
            let mixPoint = outGrid.nearestDownbeat(to: out.duration - Double(move.totalBars + 6) * bar)
            let entry = inGrid.nearestDownbeat(to: 8 * inGrid.barDuration)
            let window = Double(move.totalBars) * bar
            var stages: [TransitionStage] = []
            if move.kind == .loopRoll {
                stages.append(TransitionStage(at: 0, on: .outgoing, .loop(bars: 8)))
            }
            let plan = MixPlanRecord(
                mixPointSeconds: mixPoint,
                transitionSeconds: window,
                outroShape: "breakdown",
                accent: nil,
                reasoning: "Fixture",
                entrySeconds: entry,
                bassSwapAtSeconds: window * 0.55,
                bassSwapSeconds: 0.5,
                incomingRateRatio: bpms[index] / bpms[index + 1],
                incomingTrackId: into.id,
                profileId: nil,
                templateId: nil,
                stages: stages,
                outgoingBeatGrid: outGrid,
                incomingBeatGrid: inGrid,
                move: move,
                incomingTitle: into.title,
                incomingMidCutDecibels: 0
            )
            let execution = MixExecutionRecord(
                startSourceSeconds: mixPoint,
                windowSeconds: window,
                entrySeconds: entry,
                outgoingRate: 1,
                incomingRate: bpms[index] / bpms[index + 1],
                startedAtPlannedBoundary: true,
                riserLevel: 0.5,
                sampleRate: 48_000
            )
            let performanceStart = outGrid.nearestDownbeat(to: mixPoint * 0.5)
            let performance: [MixPerformanceMove] = index == 1 || index == 3 ? [
                MixPerformanceMove(
                    kind: index == 1 ? .loopRoll : .highPassBuild,
                    startSeconds: performanceStart,
                    landingSeconds: performanceStart + 4 * bar,
                    endSeconds: performanceStart + 5 * bar,
                    startBar: Int(performanceStart / bar),
                    landingBar: Int(performanceStart / bar) + 4,
                    lengthBeats: 16,
                    depth: 0.6
                )
            ] : []
            func snapshot(_ i: Int) -> MixTrackSnapshot {
                MixTrackSnapshot(track: tracks[i], bpm: bpms[i], camelot: keys[i], energyLevel: energy[i])
            }
            clock = clock.addingTimeInterval(out.duration - entry)
            entries.append(MixHistoryEntry(
                id: UUID(),
                date: clock,
                sessionID: session,
                outgoing: snapshot(index),
                incoming: snapshot(index + 1),
                plan: plan,
                execution: execution,
                performance: performance,
                feedback: nil,
                liked: ratings[index]
            ))
        }
        return entries
    }
}
#endif
