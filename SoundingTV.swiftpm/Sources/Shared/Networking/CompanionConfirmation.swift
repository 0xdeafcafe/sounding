import Foundation

@MainActor
final class PlaybackConfirmationTracker {
    enum Outcome: Equatable, Sendable {
        case confirmed
        case rejected(String)
        case timedOut
        case disconnected
    }

    private struct Waiter {
        let trackId: String
        let continuation: CheckedContinuation<Outcome, Never>
        var timeout: Task<Void, Never>?
    }

    private var waiters: [UInt64: Waiter] = [:]
    private var nextID: UInt64 = 0

    var pendingCount: Int { waiters.count }

    func confirm(trackId: String, timeout: Duration, send: () -> Bool) async -> Outcome {
        nextID &+= 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = Waiter(trackId: trackId, continuation: continuation)
                guard send() else {
                    resolve(id, with: .disconnected)
                    return
                }
                guard waiters[id] != nil else { return }
                waiters[id]?.timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.resolve(id, with: .timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id, with: .timedOut) }
        }
    }

    func observePlayback(trackId: String?) {
        guard let trackId else { return }
        for (id, waiter) in waiters where waiter.trackId == trackId {
            resolve(id, with: .confirmed)
        }
    }

    func observeRejection(_ reason: String) {
        for id in Array(waiters.keys) { resolve(id, with: .rejected(reason)) }
    }

    func observeDisconnect() {
        for id in Array(waiters.keys) { resolve(id, with: .disconnected) }
    }

    private func resolve(_ id: UInt64, with outcome: Outcome) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout?.cancel()
        waiter.continuation.resume(returning: outcome)
    }
}

struct PendingRemoteSeek: Equatable, Sendable {
    static let grace: TimeInterval = 1
    static let deadline: TimeInterval = 3
    static let tolerance: TimeInterval = 2

    enum Resolution: Equatable, Sendable {
        case hold
        case settle
    }

    let target: TimeInterval
    let rate: Double
    let issuedAt: Date
    let baselineRevision: Int

    func resolution(revision: Int?, position: TimeInterval?, at now: Date) -> Resolution {
        let elapsed = max(0, now.timeIntervalSince(issuedAt))
        if elapsed >= Self.deadline { return .settle }
        guard let revision, revision > baselineRevision, let position else { return .hold }
        let expected = target + rate * elapsed
        if abs(position - expected) <= Self.tolerance { return .settle }
        return elapsed >= Self.grace ? .settle : .hold
    }
}

struct PendingLocalSeek: Equatable, Sendable {
    static let deadline: TimeInterval = 3
    static let tolerance: TimeInterval = 1.5

    let target: TimeInterval
    let issuedAt: Date
    let trackID: String?

    func isExpired(at now: Date, trackID current: String?) -> Bool {
        current != trackID || now.timeIntervalSince(issuedAt) >= Self.deadline
    }

    func accepts(_ position: TimeInterval, at now: Date) -> Bool {
        let elapsed = max(0, now.timeIntervalSince(issuedAt))
        return position >= target - Self.tolerance && position <= target + elapsed * 2 + Self.tolerance
    }
}
