import Foundation
import Network

/// Every replicated mutation enters the system as a domain event. CloudKit
/// and nearby Companion links are delivery lanes for the same event, not two
/// independent synchronization systems.
enum SynchronizationDomain: String, CaseIterable, Sendable {
    case session
    case cues
    case analysis
    case downloadManifest
    case setlists
    case settings
    case companionRoster
}

/// The one pacing and deduplication boundary for outbound synchronization.
/// Transport adapters still own framing and connectivity, while this gateway
/// owns when work may leave the process and whether a newer snapshot replaces
/// stale pending work.
@MainActor
final class SynchronizationGateway {
    static let shared = SynchronizationGateway()

    enum Lane: String, CaseIterable, Hashable, Sendable {
        case cloud
        case companionHandshake
        case companionCommand
        case companionState
        case companionContinuous
        case companionBulk
    }

    enum Delivery: Equatable, Sendable {
        case reliable
        case latest
    }

    enum Urgency: Equatable, Sendable {
        case normal
        case immediate
    }

    struct Metrics: Equatable, Sendable {
        var submitted = 0
        var delivered = 0
        var coalesced = 0
        var duplicateDrops = 0
        var cancelled = 0
        var pending = 0
    }

    private struct Policy {
        let delivery: WorkScheduler.Delivery
        let delay: Duration
    }

    private let scheduler = WorkScheduler.shared

    var metrics: Metrics {
        let value = scheduler.combinedMetrics(for: Lane.allCases.map(Self.queueID(for:)))
        return Metrics(
            submitted: value.submitted,
            delivered: value.delivered,
            coalesced: value.coalesced,
            duplicateDrops: value.duplicateDrops,
            cancelled: value.cancelled,
            pending: value.pending
        )
    }

    private init() {}

    /// `key` is stable for replaceable state (for example `tv.playback`) and
    /// unique for discrete commands. A fingerprint suppresses an identical
    /// snapshot after it has already crossed the boundary.
    func submit(
        lane: Lane,
        key: String,
        fingerprint: Int? = nil,
        urgency: Urgency = .normal,
        operation: @escaping @MainActor () async -> Void
    ) {
        let policy = Self.policy(for: lane)
        scheduler.submit(
            queue: Self.queueID(for: lane),
            key: key,
            delivery: policy.delivery,
            delay: policy.delay,
            fingerprint: fingerprint,
            urgency: urgency == .immediate ? .immediate : .normal,
            operation: operation
        )
    }

    func flush(_ lane: Lane) async {
        await scheduler.flush(Self.queueID(for: lane))
    }

    /// The sole outbound boundary for Companion protocol frames. Adapters
    /// create and validate protocol payloads; the gateway assigns traffic
    /// policy, coalesces replaceable state, and preserves ordered commands.
    func sendCompanionFrame(
        _ data: Data,
        type: MessageType,
        ownerID: String,
        fingerprint: Int? = nil,
        urgency: Urgency = .normal,
        connection: NWConnection,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        let lane = Self.companionLane(for: type)
        submit(
            lane: lane,
            key: "\(ownerID).\(type.rawValue)",
            fingerprint: fingerprint,
            urgency: Self.isImmediateCompanionLane(lane) ? .immediate : urgency
        ) { [weak connection] in
            guard let connection, isCurrent() else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    /// Bulk rounds and continuous-control batches have already been admitted
    /// by `submit`. Their individual frames still cross the same physical send
    /// boundary without being re-debounced or accidentally coalesced together.
    func transmitAdmittedCompanionFrame(
        _ data: Data,
        connection: NWConnection,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        guard isCurrent() else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Drops delayed snapshots belonging to a disconnected transport. Work
    /// already handed to Network.framework remains its responsibility.
    func cancel(keyPrefix: String) {
        scheduler.cancelPending(
            keyPrefix: keyPrefix,
            in: Lane.allCases.map(Self.queueID(for:))
        )
    }

    private static func policy(for lane: Lane) -> Policy {
        switch lane {
        case .cloud:
            return Policy(delivery: .latest, delay: .seconds(2))
        case .companionHandshake, .companionCommand:
            return Policy(delivery: .fifo, delay: .zero)
        case .companionState:
            return Policy(delivery: .latest, delay: .milliseconds(200))
        case .companionContinuous:
            return Policy(delivery: .latest, delay: .milliseconds(33))
        case .companionBulk:
            return Policy(delivery: .latest, delay: .milliseconds(400))
        }
    }

    private static func queueID(for lane: Lane) -> WorkScheduler.QueueID {
        WorkScheduler.QueueID(rawValue: "synchronization.\(lane.rawValue)")
    }

    private static func companionLane(for type: MessageType) -> Lane {
        switch type {
        case .queueState, .playbackState, .djState:
            return .companionState
        case .cueSync, .likesSync:
            return .companionBulk
        default:
            if type.isQueueCommand || type.isControlCommand {
                return type.isContinuousControl ? .companionContinuous : .companionCommand
            }
            return .companionHandshake
        }
    }

    private static func isImmediateCompanionLane(_ lane: Lane) -> Bool {
        lane == .companionHandshake || lane == .companionCommand
    }
}

actor CloudSyncInbox<Record: Sendable> {
    private var buffered: [Record] = []
    func append(_ records: [Record]) { buffered.append(contentsOf: records) }
    func drain() -> [Record] {
        defer { buffered.removeAll() }
        return buffered
    }
}
