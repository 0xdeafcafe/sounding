#if SOUNDING_PERSONAL
import Foundation

struct PersonalFetchPolicy: Equatable, Sendable {
    var spacing: TimeInterval = 8
    var jitterFraction: Double = 0.25
    var failureBackoff: TimeInterval = 60
    var maximumBackoff: TimeInterval = 15 * 60
    var maximumConsecutiveFailures = 3
}

enum PersonalFetchError: Error, Equatable {
    case stoppedAfterFailures(Int)
}

actor PersonalFetchQueue {
    typealias Operation = @Sendable () async throws -> URL
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    typealias Now = @Sendable () -> Date
    typealias PausedUntil = @Sendable () async -> Date?
    typealias Jitter = @Sendable () -> Double

    private let policy: PersonalFetchPolicy
    private let now: Now
    private let sleep: Sleep
    private let pausedUntil: PausedUntil
    private let jitter: Jitter

    private var tail: Task<Void, Never>?
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var nextStart: Date?
    private var consecutiveFailures = 0
    private var lastFailure: Date?
    private(set) var startedKeys: [String] = []

    init(
        policy: PersonalFetchPolicy = PersonalFetchPolicy(),
        now: @escaping Now = { Date() },
        sleep: @escaping Sleep = { seconds in try await Task.sleep(for: .seconds(seconds)) },
        pausedUntil: @escaping PausedUntil = { nil },
        jitter: @escaping Jitter = { Double.random(in: -1 ... 1) }
    ) {
        self.policy = policy
        self.now = now
        self.sleep = sleep
        self.pausedUntil = pausedUntil
        self.jitter = jitter
    }

    func file(for key: String, operation: @escaping Operation) async throws -> URL {
        let task: Task<URL, Error>
        if let existing = inFlight[key] {
            task = existing
        } else {
            let prior = tail
            task = Task(priority: .background) {
                await prior?.value
                return try await self.perform(key: key, operation: operation)
            }
            inFlight[key] = task
            tail = Task(priority: .background) { _ = try? await task.value }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    func resetFailures() {
        consecutiveFailures = 0
        lastFailure = nil
    }

    private func perform(key: String, operation: Operation) async throws -> URL {
        defer { inFlight[key] = nil }
        if consecutiveFailures >= policy.maximumConsecutiveFailures {
            if let lastFailure, now().timeIntervalSince(lastFailure) < policy.maximumBackoff {
                throw PersonalFetchError.stoppedAfterFailures(consecutiveFailures)
            }
            resetFailures()
        }
        try await waitForTurn()
        startedKeys.append(key)
        do {
            let url = try await operation()
            consecutiveFailures = 0
            scheduleNext()
            return url
        } catch is CancellationError {
            scheduleNext()
            throw CancellationError()
        } catch {
            consecutiveFailures += 1
            lastFailure = now()
            scheduleNext()
            throw error
        }
    }

    private func waitForTurn() async throws {
        while true {
            try Task.checkCancellation()
            let current = now()
            if let paused = await pausedUntil(), paused > current {
                try await sleep(paused.timeIntervalSince(current))
                continue
            }
            if let nextStart, nextStart > current {
                try await sleep(nextStart.timeIntervalSince(current))
                continue
            }
            return
        }
    }

    private func scheduleNext() {
        let spread = max(-1, min(1, jitter()))
        var delay = policy.spacing * (1 + policy.jitterFraction * spread)
        if consecutiveFailures > 0 {
            let backoff = policy.failureBackoff * pow(2, Double(consecutiveFailures - 1))
            delay = max(delay, min(policy.maximumBackoff, backoff))
        }
        nextStart = now().addingTimeInterval(max(0, delay))
    }
}
#endif
