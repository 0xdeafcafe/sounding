import Foundation
import Combine

#if canImport(UIKit)
import UIKit
#endif

/// One small, local queue for work that needs an actual audio file.  It makes
/// background collection work polite and lets a deck-load jump the queue.
enum AnalysisWorkPriority: Int, Sendable {
    case background = 0
    case interactive = 1
}

enum AnalysisWorkState: Equatable {
    case notEligible(String)
    case queued(position: Int)
    case analysing
    case failed(String)
    case complete

    var label: String {
        switch self {
        case .notEligible(let reason): return reason
        case .queued(let position): return position == 1 ? "Queued next" : "Queued #\(position)"
        case .analysing: return "Analysing…"
        case .failed: return "Analysis failed"
        case .complete: return "Analysed"
        }
    }

    var isQueued: Bool {
        if case .queued = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

@MainActor
final class AutomaticAnalysisStatus: ObservableObject {
    static let shared = AutomaticAnalysisStatus()

    @Published private(set) var states: [String: AnalysisWorkState] = [:]

    private init() {}

    func state(for trackId: String) -> AnalysisWorkState? { states[trackId] }
    func set(_ state: AnalysisWorkState, for trackId: String) { states[trackId] = state }
}

/// Whether this particular device is currently willing to run automatic work.
/// No branch here can request network audio; the scheduler is passed a verified
/// local file URL by DownloadManager or the deck loader.
@MainActor
enum AutomaticAnalysisEligibility {
    static func blockedReason(for localFileURL: URL) -> String? {
        let policy = SettingsStore.shared.automaticAnalysisExecutionPolicy
        guard DeviceClass.current.supports(.deepAnalysis) else {
            return "This device can’t run deep analysis"
        }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            return "Waiting for Low Power Mode to end"
        }

        let reserve: Int64
        switch policy {
        case .conservative: reserve = 750_000_000
        case .balanced: reserve = 300_000_000
        case .eager: reserve = 100_000_000
        }
        if let free = freeBytes(near: localFileURL), free < reserve {
            return "Waiting for free storage"
        }

        #if canImport(UIKit) && !os(tvOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = UIDevice.current.batteryState
        let isCharging = battery == .charging || battery == .full
        if policy == .conservative && !isCharging { return "Waiting for charging" }
        if policy == .balanced, UIDevice.current.batteryLevel >= 0, UIDevice.current.batteryLevel < 0.30 {
            return "Waiting for battery to charge"
        }
        #endif
        return nil
    }

    private static func freeBytes(near url: URL) -> Int64? {
        #if os(tvOS)
        // tvOS does not expose the "important usage" volume-capacity API.
        // Let the platform enforce its own cache quota instead of failing
        // eligibility checks (or compiling against an unavailable symbol).
        return nil
        #else
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #endif
    }
}

actor AutomaticAnalysisScheduler {
    static let shared = AutomaticAnalysisScheduler()

    private struct Job: Sendable {
        let track: Track
        let transcoding: Transcoding?
        let localFileURL: URL
        let priority: AnalysisWorkPriority
    }

    private var jobs: [Job] = []
    private var isRunning = false

    func enqueue(
        track: Track,
        transcoding: Transcoding?,
        localFileURL: URL,
        priority: AnalysisWorkPriority,
        enforceDeviceEligibility: Bool
    ) async {
        if enforceDeviceEligibility,
           let reason = await MainActor.run(body: { AutomaticAnalysisEligibility.blockedReason(for: localFileURL) }) {
            await MainActor.run { AutomaticAnalysisStatus.shared.set(.notEligible(reason), for: track.id) }
            return
        }

        jobs.removeAll { $0.track.id == track.id }
        let job = Job(track: track, transcoding: transcoding, localFileURL: localFileURL, priority: priority)
        let insertion = jobs.firstIndex { $0.priority.rawValue < priority.rawValue } ?? jobs.endIndex
        jobs.insert(job, at: insertion)
        await publishQueue()
        guard !isRunning else { return }
        isRunning = true
        await run()
        isRunning = false
    }

    private func run() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            await MainActor.run { AutomaticAnalysisStatus.shared.set(.analysing, for: job.track.id) }
            let result: AnalysisCoordinator.RunResult
            if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
                result = await AnalysisCoordinator.analyze(
                    track: job.track,
                    transcoding: job.transcoding,
                    localFileURL: job.localFileURL,
                    registry: AnalysisProducerRegistry([MusicUnderstandingProducer()]),
                    cache: .shared
                )
            } else {
                result = AnalysisCoordinator.RunResult(outcomes: [:], isEntitled: true)
            }
            let failures = result.outcomes.values.compactMap { outcome -> String? in
                if case .failed(let reason) = outcome { return reason }
                return nil
            }
            let state: AnalysisWorkState
            if !result.isEntitled {
                state = .notEligible("Analysis isn’t available")
            } else if result.stored.isEmpty, let reason = failures.first {
                state = .failed(reason)
            } else {
                state = .complete
            }
            await MainActor.run { AutomaticAnalysisStatus.shared.set(state, for: job.track.id) }
            await publishQueue()
        }
    }

    private func publishQueue() async {
        for (offset, job) in jobs.enumerated() {
            await MainActor.run {
                AutomaticAnalysisStatus.shared.set(.queued(position: offset + 1), for: job.track.id)
            }
        }
    }
}

enum AnalysisOpportunity {
    static func schedule(
        track: Track,
        transcoding: Transcoding? = nil,
        genreField: String? = nil,
        tags: [String] = [],
        waveformSamples: [Float] = [],
        localFileURL: URL? = nil,
        registry: AnalysisProducerRegistry = .v1,
        priority: AnalysisWorkPriority = .background,
        enforceDeviceEligibility: Bool = true
    ) {
        // Materialised-audio work is serialized so collection scans do not
        // compete with a track the listener has just put on a deck.
        let usesMusicUnderstanding: Bool = {
            if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
                return registry.producers.contains(where: { $0.id == MusicUnderstandingProducer().id })
            }
            return false
        }()
        if let localFileURL, usesMusicUnderstanding {
            Task {
                await AutomaticAnalysisScheduler.shared.enqueue(
                    track: track,
                    transcoding: transcoding,
                    localFileURL: localFileURL,
                    priority: priority,
                    enforceDeviceEligibility: enforceDeviceEligibility
                )
            }
            return
        }
        Task.detached(priority: .utility) {
            let result = await AnalysisCoordinator.analyze(
                track: track, transcoding: transcoding,
                genreField: genreField, tags: tags,
                waveformSamples: waveformSamples, localFileURL: localFileURL,
                registry: registry, cache: .shared
            )
            guard result.isEntitled else { return }
            for (id, outcome) in result.outcomes {
                if case .failed(let reason) = outcome {
                    Log.analysis.error("\(id, privacy: .public) failed for \(track.id, privacy: .public): \(reason, privacy: .public)")
                }
            }
        }
    }
}
