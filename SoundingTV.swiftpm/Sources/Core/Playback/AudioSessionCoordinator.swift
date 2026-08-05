import Foundation
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

@MainActor
protocol AudioSessionCoordinating: AnyObject {
    func activatePlayback()

    var outputName: String? { get }

    var outputKind: AudioOutputKind { get }

    var maximumOutputChannels: Int { get }

    var supportsMultichannel: Bool { get }

    func refreshRoute()
}

extension Notification.Name {
    static let audioOutputRouteDidChange = Notification.Name("red.forbes.sounding.audioOutputRouteDidChange")
}

extension AudioSessionCoordinating {
    var isAirPlayRoute: Bool { outputKind == .airPlay }

    var supportsSeparateCueBus: Bool { maximumOutputChannels >= 4 }
}

@MainActor
enum PlatformAudioSession {
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

    static func refreshRoute() {
        coordinator?.refreshRoute()
    }
}

#if os(iOS) || os(tvOS) || os(watchOS)

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
        ) { original in
            MainActor.assumeIsolated {
                PlatformAudioSession.coordinator?.refreshRoute()
            }
            NotificationCenter.default.post(name: .audioOutputRouteDidChange, object: original)
        }
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    func activatePlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
            refreshRoute()
        } catch {
            Log.player.error("[AudioSession] activation failed: \(error.localizedDescription, privacy: .public)")
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
