import SwiftUI
import HealthKit
import Combine

@MainActor
final class PhoneWorkoutEnergy: ObservableObject {
    static let shared = PhoneWorkoutEnergy()

    enum Access: Equatable {
        case unavailable
        case notRequested
        case requested
    }

    @Published private(set) var access: Access = .notRequested
    @Published private(set) var heartRate: Double?

    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?
    private var lastSent: (level: Int, at: Date)?
    private var cancellables = Set<AnyCancellable>()
    private weak var coordinator: PhonePlaybackCoordinator?
    private static let resendInterval: TimeInterval = 20

    private static var heartRateType: HKQuantityType { HKQuantityType(.heartRate) }

    private init() {
        refreshAccess()
        SettingsStore.shared.$djMatchWorkout
            .combineLatest(AutoMixEnergy.shared.$focus.map(\.workout))
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled, self.access == .requested { self.start() } else if !enabled { self.stop() }
            }
            .store(in: &cancellables)
    }

    func attach(_ coordinator: PhonePlaybackCoordinator) {
        self.coordinator = coordinator
    }

    private func refreshAccess() {
        guard HKHealthStore.isHealthDataAvailable() else {
            access = .unavailable
            return
        }
        store.getRequestStatusForAuthorization(toShare: [], read: [Self.heartRateType]) { [weak self] status, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.access = status == .unnecessary ? .requested : .notRequested
                if self.access == .requested, AutoMixEnergy.shared.matchesWorkout { self.start() }
            }
        }
    }

    func requestAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            access = .unavailable
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: [Self.heartRateType])
            access = .requested
            SettingsStore.shared.setDJMatchWorkout(true)
            start()
        } catch {
            access = .notRequested
        }
    }

    func start() {
        guard query == nil, access == .requested else { return }
        let since = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-120), end: nil, options: .strictStartDate)
        let handler: @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { _, samples, _, _, _ in
            let latest = (samples as? [HKQuantitySample])?.max { $0.endDate < $1.endDate }
            guard let latest else { return }
            let bpm = latest.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            let at = latest.endDate
            Task { @MainActor in PhoneWorkoutEnergy.shared.noteHeartRate(bpm, at: at) }
        }
        let query = HKAnchoredObjectQuery(type: Self.heartRateType, predicate: since, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        query.updateHandler = handler
        store.execute(query)
        self.query = query
    }

    func stop() {
        if let query { store.stop(query) }
        query = nil
        heartRate = nil
        lastSent = nil
    }

    func noteHeartRate(_ bpm: Double, at date: Date = Date()) {
        guard AutoMixEnergy.shared.matchesWorkout else { return }
        heartRate = bpm
        AutoMixEnergy.shared.noteHeartRate(bpm, at: date)
        forward()
    }

    private func forward() {
        guard let coordinator, coordinator.isRemoteOutput else { return }
        let reading = AutoMixEnergy.shared.reading()
        guard reading.source == .workout else { return }
        let now = Date()
        if let lastSent, lastSent.level == reading.level, now.timeIntervalSince(lastSent.at) < Self.resendInterval { return }
        lastSent = (reading.level, now)
        coordinator.sendEnergyTarget(level: reading.level, heartRate: reading.heartRate)
    }
}

struct AutoMixEnergySection: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var workout = PhoneWorkoutEnergy.shared
    @State private var priming = false

    var body: some View {
        Section {
            Toggle("Follow the Night", isOn: store.djEnergyFollowsNightBinding)
            VStack(alignment: .leading, spacing: 4) {
                Text("Energy")
                Slider(value: store.djEnergyLevelBinding, in: 0...1) {
                    Text("Energy")
                }
                HStack {
                    Text("Chill")
                    Spacer()
                    Text("Peak")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
            .disabled(store.djEnergyFollowsNight)
            VStack(alignment: .leading, spacing: 4) {
                Text("Riser")
                Slider(value: store.djRiserLevelBinding, in: 0...1) {
                    Text("Riser")
                }
                HStack {
                    Text("Off")
                    Spacer()
                    Text("Loud")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
            .disabled(store.djDefaultProfileId == .wedding)
            if workout.access != .unavailable {
                Toggle("Match My Workout", isOn: Binding(
                    get: { store.djMatchWorkout },
                    set: { enabled in
                        if enabled, workout.access == .notRequested {
                            priming = true
                        } else {
                            store.setDJMatchWorkout(enabled)
                        }
                    }
                ))
                .sheet(isPresented: $priming) {
                    WorkoutPrimingView {
                        priming = false
                        Task { await workout.requestAccess() }
                    } onCancel: {
                        priming = false
                    }
                }
                if store.djMatchWorkout, let bpm = workout.heartRate {
                    LabeledContent("Heart Rate", value: "\(Int(bpm.rounded())) BPM")
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Energy")
        } footer: {
            Text(store.djMatchWorkout ? "During a workout, your heart rate sets the energy." : "Auto Mix picks moves that lift or settle the room.")
        }
    }
}

struct WorkoutPrimingView: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    ContentUnavailableView {
                        Label("Match Your Workout", systemImage: "heart.circle")
                    } description: {
                        Text("While you work out, Auto Mix reads your heart rate from Apple Watch and lifts or settles the music to match. Sounding only reads heart rate, and it stays on your devices.")
                    } actions: {
                        Button("Continue", action: onContinue)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        Button("Not Now", action: onCancel)
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
