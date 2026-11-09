import Foundation
import Combine

/// The process-wide admission point for non-real-time autonomous work.
///
/// Systems retain ownership of their operations and state. This scheduler
/// owns only timing, coalescing, ordering, cancellation scopes, and observable
/// policy metrics. Audio/render clocks and protocol deadlines intentionally do
/// not pass through this type.
@MainActor
final class WorkScheduler: ObservableObject {
    static let shared = WorkScheduler()

    struct QueueID: RawRepresentable, Hashable, Sendable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    enum Delivery: Equatable, Sendable {
        /// Every admitted operation runs in submission order.
        case fifo
        /// A pending operation with the same key is replaced by the newest.
        case latest
    }

    enum Urgency: Equatable, Sendable {
        case normal
        case immediate
    }

    enum Priority: Int, Equatable, Sendable {
        case background = 0
        case normal = 1
        case userInitiated = 2

        var taskPriority: TaskPriority {
            switch self {
            case .background:      return .background
            case .normal:          return .utility
            case .userInitiated:   return .userInitiated
            }
        }
    }

    struct Constraints: OptionSet, Hashable, Sendable {
        let rawValue: Int

        static let foreground = Constraints(rawValue: 1 << 0)
        static let network = Constraints(rawValue: 1 << 1)
        static let externalPower = Constraints(rawValue: 1 << 2)
    }

    struct Environment: Equatable, Sendable {
        var isForeground = true
        var hasNetwork = true
        var isExpensiveNetwork = false
        var isConstrainedNetwork = false
        var isOnExternalPower = true

        var hasUnmeteredNetwork: Bool {
            hasNetwork && !isExpensiveNetwork && !isConstrainedNetwork
        }
    }

    struct RetryPolicy: Equatable, Sendable {
        var maximumAttempts = 4
        var initialDelay: Duration = .seconds(2)
        var maximumDelay: Duration = .seconds(5 * 60)
        var multiplier = 2.0
        var jitterFraction = 0.15
    }

    struct Metrics: Equatable, Sendable {
        var submitted = 0
        var delivered = 0
        var coalesced = 0
        var duplicateDrops = 0
        var cancelled = 0
        var pending = 0
        var periodicRuns = 0
        var retries = 0
    }

    struct PeriodicDiagnostic: Equatable, Sendable {
        let id: String
        let scope: String
        let nextRunAt: Date?
        let interval: Duration
        let constraints: Constraints
    }

    struct Snapshot: Equatable, Sendable {
        let environment: Environment
        let queues: [String: Metrics]
        let periodic: [PeriodicDiagnostic]
    }

    private struct Pending {
        let key: String
        let fingerprint: Int?
        let priority: Priority
        let sequence: UInt64
        let operation: @MainActor () async -> Void
    }

    private struct QueueState {
        var fifo: [Pending] = []
        var latest: [String: Pending] = [:]
        var latestOrder: [String] = []
        var delay: Duration = .zero

        var isEmpty: Bool { fifo.isEmpty && latest.isEmpty }
        var count: Int { fifo.count + latest.count }
    }

    private struct PeriodicRegistration {
        let scope: String
        let task: Task<Void, Never>
        let interval: Duration
        let constraints: Constraints
        var nextRunAt: Date?
    }

    private struct Worker {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var states: [QueueID: QueueState] = [:]
    private var workers: [QueueID: Worker] = [:]
    private var sleepingWorkers: [QueueID: UUID] = [:]
    private var lastDeliveredFingerprints: [String: Int] = [:]
    private var queueMetrics: [QueueID: Metrics] = [:]
    private var periodic: [String: PeriodicRegistration] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var environmentWaiters: [String: @MainActor () -> Void] = [:]
    @Published private(set) var environment = Environment()
    private var sequence: UInt64 = 0

    private init() {}

    /// Admit one operation into a serial queue.
    ///
    /// - Parameters:
    ///   - queue: The independent ordering lane.
    ///   - key: Stable identity within the queue and cancellation scope.
    ///   - delivery: FIFO for commands, latest for replaceable state.
    ///   - delay: Admission debounce. It is applied once per pending batch.
    ///   - fingerprint: Suppresses identical latest-value snapshots both while
    ///     pending and after delivery.
    ///
    /// The submitted closure runs on the main actor. CPU-heavy work must detach
    /// itself; use `submitBackground(_:...)` when the entire operation can run
    /// off the main actor.
    func submit(
        queue: QueueID,
        key: String,
        delivery: Delivery,
        delay: Duration = .zero,
        fingerprint: Int? = nil,
        urgency: Urgency = .normal,
        priority: Priority = .normal,
        operation: @escaping @MainActor () async -> Void
    ) {
        var metrics = queueMetrics[queue] ?? Metrics()
        metrics.submitted += 1

        let scopedKey = "\(queue.rawValue)#\(key)"
        var state = states[queue] ?? QueueState()
        state.delay = delay
        sequence &+= 1
        let pendingSequence = sequence

        switch delivery {
        case .fifo:
            state.fifo.append(Pending(
                key: scopedKey,
                fingerprint: fingerprint,
                priority: priority,
                sequence: pendingSequence,
                operation: operation
            ))

        case .latest:
            if let fingerprint,
               lastDeliveredFingerprints[scopedKey] == fingerprint
                || state.latest[scopedKey]?.fingerprint == fingerprint {
                metrics.duplicateDrops += 1
                queueMetrics[queue] = metrics
                return
            }
            if state.latest[scopedKey] != nil {
                metrics.coalesced += 1
            } else {
                state.latestOrder.append(scopedKey)
            }
            state.latest[scopedKey] = Pending(
                key: scopedKey,
                fingerprint: fingerprint,
                priority: priority,
                sequence: pendingSequence,
                operation: operation
            )
        }

        states[queue] = state
        metrics.pending = state.count
        queueMetrics[queue] = metrics
        if let worker = workers[queue], sleepingWorkers[queue] == worker.id,
           delivery == .latest || urgency == .immediate {
            worker.task.cancel()
            workers[queue] = nil
            sleepingWorkers[queue] = nil
        }
        startWorkerIfNeeded(for: queue, immediate: urgency == .immediate)
    }

    /// Convenience admission for work that does not need the main actor at all.
    /// The supplied closure runs in a detached task when the scheduler delivers
    /// it, leaving the main actor free for UI while CPU or I/O work proceeds.
    func submitBackground(
        queue: QueueID,
        key: String,
        delivery: Delivery = .latest,
        delay: Duration = .zero,
        fingerprint: Int? = nil,
        urgency: Urgency = .normal,
        priority: Priority = .normal,
        operation: @escaping @Sendable () async -> Void
    ) {
        submit(
            queue: queue,
            key: key,
            delivery: delivery,
            delay: delay,
            fingerprint: fingerprint,
            urgency: urgency,
            priority: priority
        ) {
            Task.detached(priority: priority.taskPriority) {
                await operation()
            }
        }
    }

    /// Wait until all work currently admitted to a queue has drained. Work
    /// submitted by a running operation is included before this returns.
    func flush(_ queue: QueueID) async {
        while let worker = workers[queue] {
            await worker.task.value
        }
    }

    /// Cancel pending operations whose key begins with the supplied owner
    /// prefix. Operations already handed to a transport are not retractable.
    func cancelPending(keyPrefix: String, in queues: some Sequence<QueueID>) {
        for queue in queues {
            let retryMarker = "\(queue.rawValue)#\(keyPrefix)"
            for key in retryTasks.keys.filter({ $0.hasPrefix(retryMarker) }) {
                retryTasks.removeValue(forKey: key)?.cancel()
            }
            for key in environmentWaiters.keys.filter({ $0.hasPrefix(retryMarker) }) {
                environmentWaiters[key] = nil
            }
            guard var state = states[queue] else { continue }
            let marker = "\(queue.rawValue)#\(keyPrefix)"
            let fifoBefore = state.fifo.count
            state.fifo.removeAll { $0.key.hasPrefix(marker) }
            let removedLatest = state.latest.keys.filter { $0.hasPrefix(marker) }
            for key in removedLatest { state.latest[key] = nil }
            state.latestOrder.removeAll { removedLatest.contains($0) }
            let deliveredKeys = lastDeliveredFingerprints.keys.filter { $0.hasPrefix(marker) }
            for key in deliveredKeys { lastDeliveredFingerprints[key] = nil }
            states[queue] = state

            var metrics = queueMetrics[queue] ?? Metrics()
            metrics.cancelled += fifoBefore - state.fifo.count + removedLatest.count
            metrics.pending = state.count
            queueMetrics[queue] = metrics
            if state.isEmpty,
               let worker = workers[queue],
               sleepingWorkers[queue] == worker.id {
                worker.task.cancel()
                workers[queue] = nil
                sleepingWorkers[queue] = nil
            }
        }
    }

    func metrics(for queue: QueueID) -> Metrics {
        queueMetrics[queue] ?? Metrics()
    }

    func combinedMetrics(for queues: some Sequence<QueueID>) -> Metrics {
        queues.reduce(into: Metrics()) { result, queue in
            let value = metrics(for: queue)
            result.submitted += value.submitted
            result.delivered += value.delivered
            result.coalesced += value.coalesced
            result.duplicateDrops += value.duplicateDrops
            result.cancelled += value.cancelled
            result.pending += value.pending
            result.periodicRuns += value.periodicRuns
            result.retries += value.retries
        }
    }

    func updateEnvironment(_ environment: Environment) {
        guard self.environment != environment else { return }
        self.environment = environment
        let waiters = environmentWaiters.values
        environmentWaiters.removeAll()
        for resume in waiters { resume() }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            environment: environment,
            queues: Dictionary(uniqueKeysWithValues: queueMetrics.map { ($0.key.rawValue, $0.value) }),
            periodic: periodic.map { id, registration in
                PeriodicDiagnostic(
                    id: id,
                    scope: registration.scope,
                    nextRunAt: registration.nextRunAt,
                    interval: registration.interval,
                    constraints: registration.constraints
                )
            }.sorted { $0.id < $1.id }
        )
    }

    /// Retryable work is re-admitted after bounded jittered backoff instead of
    /// sleeping inside a queue and blocking unrelated jobs on the same lane.
    func submitRetrying(
        queue: QueueID,
        key: String,
        delivery: Delivery = .latest,
        priority: Priority = .background,
        constraints: Constraints = [.network],
        policy: RetryPolicy = RetryPolicy(),
        operation: @escaping @MainActor () async throws -> Void
    ) {
        retryTasks.removeValue(forKey: "\(queue.rawValue)#\(key)")?.cancel()
        admitRetry(
            queue: queue,
            key: key,
            delivery: delivery,
            priority: priority,
            constraints: constraints,
            policy: policy,
            attempt: 1,
            operation: operation
        )
    }

    /// Register a fixed-delay autonomous job. Re-registering the same ID
    /// replaces the old task, so lifecycle setup cannot accidentally multiply
    /// a periodic loop.
    func registerPeriodic(
        id: String,
        scope: String,
        initialDelay: Duration = .zero,
        interval: Duration,
        constraints: Constraints = [],
        jitterFraction: Double = 0,
        condition: @escaping @MainActor () -> Bool = { true },
        operation: @escaping @MainActor () async -> Void
    ) {
        cancelPeriodic(id: id)
        let task = Task { @MainActor [weak self] in
            if initialDelay > .zero {
                do {
                    try await Task.sleep(for: initialDelay)
                } catch {
                    return
                }
            }
            while !Task.isCancelled {
                if self?.allows(constraints) == true, condition() {
                    await operation()
                    self?.recordPeriodicRun(scope: scope)
                }
                let delay = Self.jittered(interval, fraction: jitterFraction)
                self?.setNextRun(id: id, after: delay)
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
        periodic[id] = PeriodicRegistration(
            scope: scope,
            task: task,
            interval: interval,
            constraints: constraints,
            nextRunAt: initialDelay > .zero
                ? Date().addingTimeInterval(initialDelay.timeInterval)
                : Date()
        )
    }

    func cancelPeriodic(id: String) {
        periodic.removeValue(forKey: id)?.task.cancel()
    }

    func cancelPeriodic(scope: String) {
        let ids = periodic.compactMap { id, registration in
            registration.scope == scope ? id : nil
        }
        for id in ids { cancelPeriodic(id: id) }
    }

    private func startWorkerIfNeeded(for queue: QueueID, immediate: Bool) {
        guard workers[queue] == nil else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(queue, workerID: id, skipInitialDelay: immediate)
        }
        workers[queue] = Worker(id: id, task: task)
    }

    private func run(_ queue: QueueID, workerID: UUID, skipInitialDelay: Bool) async {
        var skipDelay = skipInitialDelay
        while !Task.isCancelled {
            guard let state = states[queue], !state.isEmpty else { break }
            if !skipDelay, state.delay > .zero {
                sleepingWorkers[queue] = workerID
                do {
                    try await Task.sleep(for: state.delay)
                } catch {
                    if sleepingWorkers[queue] == workerID { sleepingWorkers[queue] = nil }
                    break
                }
                if sleepingWorkers[queue] == workerID { sleepingWorkers[queue] = nil }
            }
            skipDelay = false

            guard !Task.isCancelled,
                  var ready = states[queue],
                  !ready.isEmpty else { break }
            let batch = (ready.fifo + ready.latestOrder.compactMap { ready.latest[$0] }).sorted {
                $0.priority != $1.priority
                    ? $0.priority.rawValue > $1.priority.rawValue
                    : $0.sequence < $1.sequence
            }
            ready.fifo.removeAll(keepingCapacity: true)
            ready.latest.removeAll(keepingCapacity: true)
            ready.latestOrder.removeAll(keepingCapacity: true)
            states[queue] = ready
            updatePendingMetric(for: queue)

            for pending in batch where !Task.isCancelled {
                // These closures are explicitly MainActor-isolated. Do not
                // wrap them in a differently-prioritized child task: on the
                // Swift 6.4/macOS 27 beta runtime that combination has been
                // observed on a cooperative utility queue, followed by
                // pointer-authentication failures when SwiftUI checks the
                // main executor. Priority continues to determine admission
                // order. An owner that needs background CPU work must detach
                // immutable inputs itself and hop back only for state changes.
                await pending.operation()
                if let fingerprint = pending.fingerprint {
                    lastDeliveredFingerprints[pending.key] = fingerprint
                }
                var metrics = queueMetrics[queue] ?? Metrics()
                metrics.delivered += 1
                queueMetrics[queue] = metrics
            }
        }

        guard workers[queue]?.id == workerID else { return }
        workers[queue] = nil
        sleepingWorkers[queue] = nil
        updatePendingMetric(for: queue)
        if states[queue]?.isEmpty == false {
            startWorkerIfNeeded(for: queue, immediate: false)
        }
    }

    private func updatePendingMetric(for queue: QueueID) {
        var metrics = queueMetrics[queue] ?? Metrics()
        metrics.pending = states[queue]?.count ?? 0
        queueMetrics[queue] = metrics
    }

    private func recordPeriodicRun(scope: String) {
        let queue = QueueID(rawValue: "periodic.\(scope)")
        var metrics = queueMetrics[queue] ?? Metrics()
        metrics.periodicRuns += 1
        queueMetrics[queue] = metrics
    }

    private func allows(_ constraints: Constraints) -> Bool {
        (!constraints.contains(.foreground) || environment.isForeground)
            && (!constraints.contains(.network) || environment.hasNetwork)
            && (!constraints.contains(.externalPower) || environment.isOnExternalPower)
    }

    private func setNextRun(id: String, after delay: Duration) {
        guard var registration = periodic[id] else { return }
        registration.nextRunAt = Date().addingTimeInterval(delay.timeInterval)
        periodic[id] = registration
    }

    private func admitRetry(
        queue: QueueID,
        key: String,
        delivery: Delivery,
        priority: Priority,
        constraints: Constraints,
        policy: RetryPolicy,
        attempt: Int,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        submit(queue: queue, key: key, delivery: delivery, priority: priority) { [weak self] in
            guard let self else { return }
            let retryKey = "\(queue.rawValue)#\(key)"
            guard self.allows(constraints) else {
                self.environmentWaiters[retryKey] = { [weak self] in
                    self?.admitRetry(
                        queue: queue,
                        key: key,
                        delivery: delivery,
                        priority: priority,
                        constraints: constraints,
                        policy: policy,
                        attempt: attempt,
                        operation: operation
                    )
                }
                return
            }
            do {
                try await operation()
                self.retryTasks[retryKey] = nil
            } catch {
                guard attempt < max(1, policy.maximumAttempts) else { return }
                var metrics = self.queueMetrics[queue] ?? Metrics()
                metrics.retries += 1
                self.queueMetrics[queue] = metrics

                let exponential = policy.initialDelay.timeInterval
                    * pow(max(1, policy.multiplier), Double(attempt - 1))
                let capped = min(policy.maximumDelay.timeInterval, exponential)
                let spread = capped * min(0.9, max(0, policy.jitterFraction))
                let seconds = max(0, capped + Double.random(in: -spread...spread))
                self.retryTasks[retryKey]?.cancel()
                self.retryTasks[retryKey] = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    guard let self else { return }
                    self.admitRetry(
                        queue: queue,
                        key: key,
                        delivery: delivery,
                        priority: priority,
                        constraints: constraints,
                        policy: policy,
                        attempt: attempt + 1,
                        operation: operation
                    )
                }
            }
        }
    }

    private static func jittered(_ duration: Duration, fraction: Double) -> Duration {
        guard fraction > 0 else { return duration }
        let seconds = duration.timeInterval
        let spread = seconds * min(0.9, max(0, fraction))
        return .seconds(max(0, seconds + Double.random(in: -spread...spread)))
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds)
            + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
