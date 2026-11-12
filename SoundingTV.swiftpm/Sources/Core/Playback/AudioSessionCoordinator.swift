import Foundation
import Combine
import os
#if canImport(AVFAudio)
import AVFAudio
#endif

enum AudioOutputKind: String, Codable, Sendable, Hashable {
    case builtIn
    case headphones
    case bluetooth
    case airPlay
    case hdmi
    case usb
    case unknown
}

struct AudioOutputRouteChange: Sendable, Equatable {
    let shouldPausePlayback: Bool
}

@MainActor
protocol AudioSessionCoordinating: AnyObject {
    func activatePlayback()

    var outputName: String? { get }

    var outputKind: AudioOutputKind { get }

    var maximumOutputChannels: Int { get }

    var supportsMultichannel: Bool { get }

    func refreshRoute()
}

extension AudioSessionCoordinating {
    var isAirPlayRoute: Bool { outputKind == .airPlay }

    var supportsSeparateCueBus: Bool { maximumOutputChannels >= 4 }
}

@MainActor
enum PlatformAudioSession {
    private static let routeChangeSubject = PassthroughSubject<AudioOutputRouteChange, Never>()

    static var coordinator: (any AudioSessionCoordinating)? = {
        #if os(iOS) || os(tvOS) || os(watchOS)
        return AVAudioSessionCoordinator()
        #else
        return nil
        #endif
    }()

    static func activatePlayback() {
        coordinator?.activatePlayback()
    }

    static var outputName: String? { coordinator?.outputName }
    static var outputKind: AudioOutputKind { coordinator?.outputKind ?? .unknown }
    static var maximumOutputChannels: Int { coordinator?.maximumOutputChannels ?? 2 }
    static var supportsMultichannel: Bool { coordinator?.supportsMultichannel ?? false }
    static var isAirPlayRoute: Bool { coordinator?.isAirPlayRoute ?? false }
    static var supportsSeparateCueBus: Bool { coordinator?.supportsSeparateCueBus ?? false }
    static var routeChanges: AnyPublisher<AudioOutputRouteChange, Never> {
        routeChangeSubject.eraseToAnyPublisher()
    }

    static func refreshRoute() {
        coordinator?.refreshRoute()
    }

    static func noteRouteChange(shouldPausePlayback: Bool = false) {
        routeChangeSubject.send(AudioOutputRouteChange(shouldPausePlayback: shouldPausePlayback))
    }
}

#if os(iOS) || os(tvOS) || os(watchOS)

enum AudioSessionQueue {
    private static let queue = DispatchQueue(label: "red.forbes.sounding.audio-session", qos: .userInitiated)

    static func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

struct AudioSessionActivation: Sendable {
    let changedCategory: Bool
    let failure: String?
}

@MainActor
final class AVAudioSessionCoordinator: AudioSessionCoordinating {
    private(set) var outputName: String?
    private(set) var outputKind: AudioOutputKind = .unknown
    private(set) var maximumOutputChannels: Int = 2
    private(set) var supportsMultichannel: Bool = false

    private nonisolated(unsafe) var routeObserver: NSObjectProtocol?

    init() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let shouldPause = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable
            MainActor.assumeIsolated {
                PlatformAudioSession.coordinator?.refreshRoute()
                PlatformAudioSession.noteRouteChange(shouldPausePlayback: shouldPause)
            }
        }
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    func activatePlayback() {
        AudioSessionQueue.async(Self.playbackActivationWork())
    }

    private nonisolated static func playbackActivationWork() -> @Sendable () -> Void {
        {
            let activation = AVAudioSessionCoordinator.activatePlaybackSession()
            Task { @MainActor in
                AVAudioSessionCoordinator.finishActivation(activation)
            }
        }
    }

    nonisolated static func activatePlaybackSession() -> AudioSessionActivation {
        let session = AVAudioSession.sharedInstance()
        let needsCategory = session.category != .playback
            || session.mode != .default
            || session.routeSharingPolicy != .longFormAudio
            || !session.categoryOptions.isEmpty
        do {
            if needsCategory {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            }
            try session.setActive(true)
            return AudioSessionActivation(changedCategory: needsCategory, failure: nil)
        } catch {
            return AudioSessionActivation(changedCategory: needsCategory, failure: error.localizedDescription)
        }
    }

    private static func finishActivation(_ activation: AudioSessionActivation) {
        if let failure = activation.failure {
            Log.player.error("[AudioSession] activation failed: \(failure, privacy: .public)")
        }
        PlatformAudioSession.refreshRoute()
        if activation.changedCategory {
            PlatformAudioSession.noteRouteChange()
        }
    }

    func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        outputName = output?.portName
        outputKind = Self.kind(for: output?.portType)
        maximumOutputChannels = session.maximumOutputNumberOfChannels
        supportsMultichannel = session.supportsMultichannelContent
    }

    private static func kind(for port: AVAudioSession.Port?) -> AudioOutputKind {
        guard let port else { return .unknown }
        switch port {
        case .airPlay: return .airPlay
        case .headphones: return .headphones
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return .bluetooth
        case .HDMI: return .hdmi
        case .usbAudio: return .usb
        case .builtInSpeaker, .builtInReceiver: return .builtIn
        default: return .unknown
        }
    }
}

#endif
