#if os(macOS)
import Foundation
import AudioToolbox
import CoreAudio
import Combine
import Synchronization

struct MixOutputDevice: Identifiable, Hashable, Sendable {
    var uid: String
    var name: String
    var outputChannels: Int
    var id: String { uid }

    var channelPairs: [Int] { Array(0..<max(1, outputChannels / 2)) }

    static func pairLabel(_ pair: Int) -> String { "Out \(pair * 2 + 1)–\(pair * 2 + 2)" }
}

struct MixPhonesRoute: Codable, Equatable, Hashable, Sendable {
    var deviceUID: String
    var channelPair: Int
}

final class MixPhonesRenderContext: @unchecked Sendable {
    let ring: MixPhonesRing
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let previewLeft: UnsafeMutablePointer<Float>
    let previewRight: UnsafeMutablePointer<Float>
    let capacity = 8192
    let targetFrames: Int
    let preview: MixPhonesPreviewSlot

    init(ring: MixPhonesRing, targetFrames: Int, preview: MixPhonesPreviewSlot) {
        self.ring = ring
        self.targetFrames = targetFrames
        self.preview = preview
        func buffer() -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
            pointer.initialize(repeating: 0, count: 8192)
            return pointer
        }
        left = buffer()
        right = buffer()
        previewLeft = buffer()
        previewRight = buffer()
    }

    deinit {
        left.deallocate()
        right.deallocate()
        previewLeft.deallocate()
        previewRight.deallocate()
    }
}

final class MixPhonesPreviewSlot: @unchecked Sendable {
    private let core = Atomic<UInt>(0)
    private let level = Atomic<UInt32>(Float(0.5).bitPattern)
    private let split = Atomic<Bool>(false)

    func attach(_ preview: MixRenderCore?, level gain: Float, split isSplit: Bool) {
        level.store(gain.bitPattern, ordering: .relaxed)
        split.store(isSplit, ordering: .relaxed)
        let bits = preview.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
        core.store(bits, ordering: .releasing)
    }

    @inline(__always)
    func mix(into left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, scratchLeft: UnsafeMutablePointer<Float>, scratchRight: UnsafeMutablePointer<Float>, frames: Int) {
        let bits = core.load(ordering: .acquiring)
        guard bits != 0, let raw = UnsafeRawPointer(bitPattern: bits) else { return }
        let preview = Unmanaged<MixRenderCore>.fromOpaque(raw)
        preview._withUnsafeGuaranteedRef { $0.render(frames: frames, left: scratchLeft, right: scratchRight) }
        let gain = Float(bitPattern: level.load(ordering: .relaxed))
        if split.load(ordering: .relaxed) {
            for n in 0..<frames {
                left[n] = min(1, max(-1, left[n] + (scratchLeft[n] + scratchRight[n]) * 0.5 * gain))
            }
        } else {
            for n in 0..<frames {
                left[n] = min(1, max(-1, left[n] + scratchLeft[n] * gain))
                right[n] = min(1, max(-1, right[n] + scratchRight[n] * gain))
            }
        }
    }
}

private func phonesRenderCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32,
    _ frameCount: UInt32,
    _ data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let context = Unmanaged<MixPhonesRenderContext>.fromOpaque(refCon).takeUnretainedValue()
    guard let data else { return noErr }
    let list = UnsafeMutableAudioBufferListPointer(data)
    guard list.count >= 2,
          let left = list[0].mData?.assumingMemoryBound(to: Float.self),
          let right = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
    var done = 0
    let total = Int(frameCount)
    while done < total {
        let count = min(context.capacity, total - done)
        _ = context.ring.read(left: context.left, right: context.right, frames: count, target: context.targetFrames)
        context.preview.mix(into: context.left, context.right, scratchLeft: context.previewLeft, scratchRight: context.previewRight, frames: count)
        (left + done).update(from: context.left, count: count)
        (right + done).update(from: context.right, count: count)
        done += count
    }
    return noErr
}

@MainActor
final class MixPhonesOutput: ObservableObject {
    @Published private(set) var devices: [MixOutputDevice] = []
    @Published private(set) var route: MixPhonesRoute?
    @Published private(set) var failure: String?

    private let core: MixRenderCore
    let previewSlot = MixPhonesPreviewSlot()
    private var unit: AudioUnit?
    private var context: MixPhonesRenderContext?
    private var listener: AudioObjectPropertyListenerBlock?

    static let routeKey = "dj.phones.route"

    init(core: MixRenderCore) {
        self.core = core
        refreshDevices()
        observeDevices()
        if let data = UserDefaults.standard.data(forKey: Self.routeKey),
           let saved = try? JSONDecoder().decode(MixPhonesRoute.self, from: data) {
            route = saved
        }
    }

    var isRunning: Bool { unit != nil }

    func device(for uid: String) -> MixOutputDevice? { devices.first { $0.uid == uid } }

    func select(_ route: MixPhonesRoute?) {
        self.route = route
        if let route, let data = try? JSONEncoder().encode(route) {
            UserDefaults.standard.set(data, forKey: Self.routeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.routeKey)
        }
        if isRunning || route == nil { restart() }
    }

    func start() {
        guard unit == nil else { return }
        restart()
    }

    func stop() {
        core.phonesActive.store(false, ordering: .relaxed)
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        context = nil
    }

    private func restart() {
        stop()
        failure = nil
        guard let route else { return }
        guard let device = device(for: route.deviceUID), let deviceID = Self.deviceID(uid: route.deviceUID) else {
            failure = "Output unavailable"
            return
        }
        do {
            try open(deviceID: deviceID, channels: device.outputChannels, pair: min(route.channelPair, device.channelPairs.count - 1))
        } catch {
            stop()
            failure = "Couldn’t open \(device.name)"
        }
    }

    private struct StatusError: Error { let status: OSStatus }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw StatusError(status: status) }
    }

    private func open(deviceID: AudioDeviceID, channels: Int, pair: Int) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw StatusError(status: -1) }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance))
        guard let instance else { throw StatusError(status: -1) }
        unit = instance

        var device = deviceID
        try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)))

        var format = AudioStreamBasicDescription(
            mSampleRate: core.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try check(AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        var map = [Int32](repeating: -1, count: max(2, channels))
        let first = pair * 2
        if first + 1 < map.count {
            map[first] = 0
            map[first + 1] = 1
        }
        let mapSize = UInt32(map.count * MemoryLayout<Int32>.size)
        let mapped = map.withUnsafeMutableBufferPointer { buffer in
            AudioUnitSetProperty(instance, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 0, buffer.baseAddress, mapSize)
        }
        if mapped != noErr {
            try map.withUnsafeMutableBufferPointer { buffer in
                try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 0, buffer.baseAddress, mapSize))
            }
        }

        let context = MixPhonesRenderContext(ring: core.phonesRing, targetFrames: Int(core.sampleRate * 0.03), preview: previewSlot)
        self.context = context
        var callback = AURenderCallbackStruct(
            inputProc: phonesRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        try check(AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check(AudioUnitInitialize(instance))
        core.phonesRing.reset()
        core.phonesActive.store(true, ordering: .relaxed)
        try check(AudioOutputUnitStart(instance))
    }

    // MARK: - Devices

    func refreshDevices() {
        devices = Self.outputDevices()
    }

    private func observeDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshDevices()
                if let route = self.route, self.isRunning, self.device(for: route.deviceUID) == nil {
                    self.stop()
                    self.failure = "Output disconnected"
                }
            }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    nonisolated static func outputDevices() -> [MixOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = outputChannelCount(id)
            guard channels >= 2, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return MixOutputDevice(uid: uid, name: name, outputChannels: channels)
        }
    }

    nonisolated static func deviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    nonisolated private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    nonisolated private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
#endif
