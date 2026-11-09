import Foundation
import AVFoundation

enum SonosStreamTap {
    static let bufferSize: AVAudioFrameCount = 1024

    nonisolated static func makeTapBlock(ring: SonosAudioRingBuffer) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let list = buffer.audioBufferList
            ring.write(list, frames: Int(buffer.frameLength))
        }
    }

    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, *)
    nonisolated static func makeTapProvider(ring: SonosAudioRingBuffer) -> @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            let frames = buffer.frameLength
            _ = buffer.withUnsafeAudioBufferList { list in
                ring.write(list, frames: frames)
            }
        }
    }

    nonisolated static func install(on node: AVAudioNode, ring: SonosAudioRingBuffer) {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            try? node.installAudioTap(onBus: 0, bufferSize: bufferSize, format: nil, tapProvider: makeTapProvider(ring: ring))
        } else {
            node.installTap(onBus: 0, bufferSize: bufferSize, format: nil, block: makeTapBlock(ring: ring))
        }
    }
}
