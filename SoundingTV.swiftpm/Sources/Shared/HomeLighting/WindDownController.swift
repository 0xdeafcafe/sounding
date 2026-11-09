import Combine
import Foundation

@MainActor
final class WindDownController: ObservableObject {
    static let shared = WindDownController()

    @Published private(set) var endsAt: Date?

    private let player: PlayerService
    private var task: Task<Void, Never>?
    private var baseMaster: Double = 1
    private var basePlayerVolume: Float = 1
    private var lastWrittenVolume: Float?

    init(player: PlayerService = .shared) {
        self.player = player
    }

    var isActive: Bool { endsAt != nil }

    nonisolated static func gain(at progress: Double) -> Double {
        let p = min(1, max(0, progress))
        return 0.5 + 0.5 * cos(.pi * p)
    }

    func start(minutes: Double) {
        cancel()
        let duration = max(1, minutes) * 60
        endsAt = Date().addingTimeInterval(duration)
        baseMaster = MixEngine.shared.masterVolume
        basePlayerVolume = player.avPlayer?.volume ?? 1
        lastWrittenVolume = nil
        #if canImport(HomeKit)
        HomeLightingDirector.shared.beginWindDown(over: duration)
        #endif

        let started = ProcessInfo.processInfo.systemUptime
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let progress = (ProcessInfo.processInfo.systemUptime - started) / duration
                if progress >= 1 {
                    self.finish()
                    return
                }
                if !self.player.isPlaying, !self.player.isLoading {
                    self.cancel()
                    return
                }
                self.apply(Self.gain(at: progress))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        guard endsAt != nil else { return }
        endsAt = nil
        restoreVolume()
        #if canImport(HomeKit)
        HomeLightingDirector.shared.endWindDown()
        #endif
    }

    private func finish() {
        task = nil
        player.pause()
        endsAt = nil
        restoreVolume()
    }

    private func apply(_ gain: Double) {
        if player.isMixEngineLive {
            MixEngine.shared.masterVolume = baseMaster * gain
        }
        if let avPlayer = player.avPlayer {
            if let lastWrittenVolume, abs(avPlayer.volume - lastWrittenVolume) > 0.001 {
                basePlayerVolume = avPlayer.volume
            }
            let volume = basePlayerVolume * Float(gain)
            avPlayer.volume = volume
            lastWrittenVolume = volume
        }
    }

    private func restoreVolume() {
        MixEngine.shared.masterVolume = baseMaster
        if let avPlayer = player.avPlayer, lastWrittenVolume != nil {
            avPlayer.volume = basePlayerVolume
        }
        lastWrittenVolume = nil
    }
}
