import Foundation
import HealthKit

@MainActor
final class WatchWorkoutEnergy: NSObject, ObservableObject {
    static let shared = WatchWorkoutEnergy()

    @Published private(set) var isRunning = false
    @Published private(set) var heartRate: Double?
    @Published private(set) var isAvailable = HKHealthStore.isHealthDataAvailable()
    @Published private(set) var failure: Failure?

    enum Failure: Equatable {
        case denied
        case couldNotStart
    }

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var lastSent = Date.distantPast
    private weak var link: WatchLinkClient?
    private static let sendInterval: TimeInterval = 5

    func attach(_ link: WatchLinkClient) {
        self.link = link
        #if DEBUG
        if WatchUIPreview.hasFlag("-SoundingWatchUIHealthDenied") { failure = .denied }
        #endif
    }

    func start() async {
        guard isAvailable, session == nil else { return }
        failure = nil
        let heartRate = HKQuantityType(.heartRate)
        do {
            if store.authorizationStatus(for: HKObjectType.workoutType()) == .notDetermined {
                try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [heartRate])
            }
            guard store.authorizationStatus(for: HKObjectType.workoutType()) != .sharingDenied else {
                failure = .denied
                return
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .mixedCardio
            configuration.locationType = .indoor
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            builder.delegate = self
            session.delegate = self
            self.session = session
            self.builder = builder
            let now = Date()
            session.startActivity(with: now)
            try await builder.beginCollection(at: now)
            isRunning = true
        } catch {
            session = nil
            builder = nil
            isRunning = false
            failure = (error as? HKError)?.code == .errorAuthorizationDenied ? .denied : .couldNotStart
        }
    }

    func stop() async {
        failure = nil
        guard let session, let builder else { return }
        session.end()
        let now = Date()
        try? await builder.endCollection(at: now)
        _ = try? await builder.finishWorkout()
        self.session = nil
        self.builder = nil
        isRunning = false
        heartRate = nil
    }

    fileprivate func note(_ bpm: Double) {
        heartRate = bpm
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= Self.sendInterval else { return }
        lastSent = now
        link?.sendHeartRate(bpm)
    }

    fileprivate func sessionEnded() {
        session = nil
        builder = nil
        isRunning = false
        heartRate = nil
    }
}

extension WatchWorkoutEnergy: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let type = HKQuantityType(.heartRate)
        guard collectedTypes.contains(type),
              let quantity = workoutBuilder.statistics(for: type)?.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        Task { @MainActor in WatchWorkoutEnergy.shared.note(bpm) }
    }
}

extension WatchWorkoutEnergy: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor in WatchWorkoutEnergy.shared.sessionEnded() }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in WatchWorkoutEnergy.shared.sessionEnded() }
    }
}
