import SwiftUI

struct WatchDJView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @ObservedObject private var workout = WatchWorkoutEnergy.shared
    @State private var showsHealthAlert = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: link.djState.mixInSeconds == nil && link.djState.live == nil)) { context in
            content(at: context.date)
        }
        .navigationTitle("Auto Mix")
        .task { workout.attach(link) }
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        let dj = link.djState
        let mixIn = dj.projectedMixIn(at: date, since: link.djStateReceivedAt)

        ScrollViewReader { proxy in
            List {
                Section {
                    Toggle("Auto Mix", isOn: Binding(
                        get: { dj.isAutoEnabled },
                        set: { link.dj($0 ? .autoEnable : .autoDisable) }
                    ))
                    LabeledContent("Status", value: dj.isEngineLive ? "Mixing" : "Idle")
                        .accessibilityElement(children: .combine)
                } footer: {
                    if !link.isReachable {
                        Text("iPhone not reachable.")
                    }
                }

                Section("Next") {
                    if let nextTitle = dj.nextTitle {
                        WatchTrackRow(
                            title: nextTitle,
                            subtitle: dj.nextArtist ?? "",
                            artworkURL: dj.nextArtworkURL
                        )
                        if let live = AutoMixLiveState.decode(dj.live) {
                            WatchAutoMixLine(state: live, date: date)
                        }
                        if let mixIn {
                            LabeledContent("Mixing In", value: mixIn.watchClockString)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Mixing in")
                                .accessibilityValue(mixIn.watchSpokenDuration)
                        }
                        if let reasoning = dj.reasoning, !reasoning.isEmpty {
                            Text(reasoning)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            link.dj(.mixNow)
                        } label: {
                            Label("Mix Now", systemImage: "bolt.fill")
                        }
                        .accessibilityHint("Mixes into the next track immediately")
                        Button {
                            link.dj(.extend)
                        } label: {
                            Label("Extend", systemImage: "arrow.right.to.line")
                        }
                        .accessibilityHint("Plays eight more bars before the mix")
                        .id("extend")
                    } else {
                        Text("Nothing queued")
                            .foregroundStyle(.secondary)
                    }
                }

                if workout.isAvailable {
                    Section {
                        Toggle("Match My Workout", isOn: Binding(
                            get: { workout.isRunning },
                            set: { enabled in
                                Task {
                                    if enabled {
                                        await workout.start()
                                        showsHealthAlert = workout.failure == .denied
                                    } else {
                                        await workout.stop()
                                    }
                                }
                            }
                        ))
                        .id("workout")
                        if let bpm = workout.heartRate {
                            LabeledContent("Heart Rate", value: "\(Int(bpm.rounded())) BPM")
                        }
                    } header: {
                        Text("Energy")
                    } footer: {
                        switch workout.failure {
                        case .denied:
                            Text("Allow Health access in the Health app on iPhone.")
                        case .couldNotStart:
                            Text("Couldn’t start a workout. Try again.")
                        case nil:
                            Text("Starts a workout. Your heart rate sets the energy.")
                        }
                    }
                }
            }
            .disabled(!link.isReachable)
            .alert("Health Access Needed", isPresented: $showsHealthAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Allow Health access in the Health app on iPhone.")
            }
            .task {
                if let target = WatchUIPreview.value(for: "-SoundingWatchUIScrollTo") {
                    try? await Task.sleep(for: .milliseconds(600))
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }
    }
}
