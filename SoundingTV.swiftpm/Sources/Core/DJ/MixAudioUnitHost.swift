import Foundation
import AVFoundation
import AudioToolbox

final class MixAudioUnitHost: @unchecked Sendable {
    static let maximumFrames = 4096

    let audioUnit: AUAudioUnit
    let name: String
    let manufacturer: String
    let componentDescription: AudioComponentDescription
    private let renderBlock: AURenderBlock
    private let inputLeft: UnsafeMutablePointer<Float>
    private let inputRight: UnsafeMutablePointer<Float>
    private let outputLeft: UnsafeMutablePointer<Float>
    private let outputRight: UnsafeMutablePointer<Float>
    private let outputList: UnsafeMutableAudioBufferListPointer
    private var timestamp = AudioTimeStamp()
    private var sampleTime: Double = 0
    private var pull: AURenderPullInputBlock!
    private(set) var failures = 0

    var latencySeconds: TimeInterval { audioUnit.latency }
    let latencyFrames: Int

    static func instantiate(_ description: AudioComponentDescription, name: String, manufacturer: String) async throws -> MixAudioUnitHost {
        let unit = try await AUAudioUnit.instantiate(with: description, options: [])
        return try MixAudioUnitHost(audioUnit: unit, description: description, name: name, manufacturer: manufacturer)
    }

    init(audioUnit: AUAudioUnit, description: AudioComponentDescription, name: String, manufacturer: String) throws {
        self.audioUnit = audioUnit
        self.name = name
        self.manufacturer = manufacturer
        componentDescription = description
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: DJEngineConstants.canonicalSampleRate,
            channels: 2
        ) else { throw MixEngineError.graphBuildFailed("no canonical format") }
        if audioUnit.inputBusses.count > 0 {
            try audioUnit.inputBusses[0].setFormat(format)
            audioUnit.inputBusses[0].isEnabled = true
        }
        guard audioUnit.outputBusses.count > 0 else {
            throw MixEngineError.graphBuildFailed("the effect has no output")
        }
        try audioUnit.outputBusses[0].setFormat(format)
        audioUnit.outputBusses[0].isEnabled = true
        audioUnit.maximumFramesToRender = AUAudioFrameCount(Self.maximumFrames)
        try audioUnit.allocateRenderResources()
        renderBlock = audioUnit.renderBlock
        let latency = audioUnit.latency
        latencyFrames = latency.isFinite && latency > 0
            ? min(MixLatencyDelay.maximumDelay, Int((latency * DJEngineConstants.canonicalSampleRate).rounded()))
            : 0
        inputLeft = .allocate(capacity: Self.maximumFrames)
        inputRight = .allocate(capacity: Self.maximumFrames)
        outputLeft = .allocate(capacity: Self.maximumFrames)
        outputRight = .allocate(capacity: Self.maximumFrames)
        inputLeft.initialize(repeating: 0, count: Self.maximumFrames)
        inputRight.initialize(repeating: 0, count: Self.maximumFrames)
        outputLeft.initialize(repeating: 0, count: Self.maximumFrames)
        outputRight.initialize(repeating: 0, count: Self.maximumFrames)
        outputList = AudioBufferList.allocate(maximumBuffers: 2)
        let left = inputLeft
        let right = inputRight
        pull = { _, _, frameCount, _, data in
            let list = UnsafeMutableAudioBufferListPointer(data)
            let bytes = Int(frameCount) * MemoryLayout<Float>.size
            if list.count > 0 { Self.fill(list, 0, from: left, bytes: bytes) }
            if list.count > 1 { Self.fill(list, 1, from: right, bytes: bytes) }
            return noErr
        }
    }

    @inline(__always)
    private static func fill(
        _ list: UnsafeMutableAudioBufferListPointer,
        _ index: Int,
        from source: UnsafeMutablePointer<Float>,
        bytes: Int
    ) {
        if let destination = list[index].mData {
            destination.copyMemory(from: source, byteCount: bytes)
        } else {
            list[index].mData = UnsafeMutableRawPointer(source)
        }
        list[index].mDataByteSize = UInt32(bytes)
        list[index].mNumberChannels = 1
    }

    deinit {
        audioUnit.deallocateRenderResources()
        inputLeft.deallocate()
        inputRight.deallocate()
        outputLeft.deallocate()
        outputRight.deallocate()
        free(outputList.unsafeMutablePointer)
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0, frames <= Self.maximumFrames else { return }
        inputLeft.update(from: left, count: frames)
        inputRight.update(from: right, count: frames)
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        outputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outputLeft))
        outputList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outputRight))
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        var flags = AudioUnitRenderActionFlags()
        let status = renderBlock(&flags, &timestamp, AUAudioFrameCount(frames), 0, outputList.unsafeMutablePointer, pull)
        sampleTime += Double(frames)
        guard status == noErr else {
            failures += 1
            return
        }
        if let data = outputList[0].mData {
            left.update(from: data.assumingMemoryBound(to: Float.self), count: frames)
        }
        if outputList.count > 1, let data = outputList[1].mData {
            right.update(from: data.assumingMemoryBound(to: Float.self), count: frames)
        }
    }

    func resetState() {
        audioUnit.reset()
    }
}
