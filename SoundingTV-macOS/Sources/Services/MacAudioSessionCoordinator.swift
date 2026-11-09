import Foundation
import CoreAudio
import AudioToolbox
import os

@MainActor
final class MacAudioSessionCoordinator: AudioSessionCoordinating {
    static let shared = MacAudioSessionCoordinator()

    private(set) var outputName: String?
    private(set) var outputKind: AudioOutputKind = .unknown
    private(set) var maximumOutputChannels: Int = 2
    private(set) var supportsMultichannel: Bool = false

    private nonisolated(unsafe) var listenerBlock: AudioObjectPropertyListenerBlock?

    private nonisolated(unsafe) var deviceConfigListenerBlock: AudioObjectPropertyListenerBlock?
    private var watchedDeviceID: AudioDeviceID?

    private init() {}

    deinit {
        if let listenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listenerBlock
            )
        }
        if let deviceConfigListenerBlock, let watchedDeviceID {
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                watchedDeviceID, &streamAddress, DispatchQueue.main, deviceConfigListenerBlock
            )
        }
    }

    static func install() {
        PlatformAudioSession.coordinator = shared
        shared.startWatchingDefaultDevice()
        shared.refreshRoute()
    }

    func activatePlayback() {
        refreshRoute()
    }

    func refreshRoute() {
        guard let device = Self.defaultOutputDevice() else {
            outputName = nil
            outputKind = .unknown
            maximumOutputChannels = 2
            supportsMultichannel = false
            retargetDeviceConfigListener(to: nil)
            return
        }

        outputName = Self.name(of: device)
        maximumOutputChannels = Self.outputChannelCount(of: device)
        supportsMultichannel = maximumOutputChannels > 2
        outputKind = Self.kind(of: device)

        retargetDeviceConfigListener(to: device)
    }

    private func startWatchingDefaultDevice() {
        guard listenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated {
                MacAudioSessionCoordinator.shared.refreshRoute()
                PlatformAudioSession.noteRouteChange()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )

        if status == noErr {
            listenerBlock = block
        } else {
            Log.player.error("MacAudioSession failed to observe default output device: \(status, privacy: .public)")
        }
    }

    private func retargetDeviceConfigListener(to device: AudioDeviceID?) {
        if let oldDevice = watchedDeviceID, let oldBlock = deviceConfigListenerBlock, oldDevice != device {
            var oldAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(oldDevice, &oldAddress, DispatchQueue.main, oldBlock)
            deviceConfigListenerBlock = nil
            watchedDeviceID = nil
        }

        guard let device, device != watchedDeviceID else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated {
                MacAudioSessionCoordinator.shared.refreshRoute()
                PlatformAudioSession.noteRouteChange()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
        if status == noErr {
            deviceConfigListenerBlock = block
            watchedDeviceID = device
        } else {
            Log.player.error("MacAudioSession failed to observe stream configuration on device \(device, privacy: .public): \(status, privacy: .public)")
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return name as String?
    }

    private static func outputChannelCount(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return 2
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return 2
        }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func kind(of device: AudioDeviceID) -> AudioOutputKind {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return .unknown
        }

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .hdmi
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeAggregate: return .usb
        default: return .unknown
        }
    }
}
