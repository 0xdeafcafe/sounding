import Foundation
import AVFoundation

enum LoopMath {
    static func resolve(
        startSeconds: Double,
        lengthSeconds: Double,
        durationSeconds: Double,
        sampleRate: Double
    ) -> (startFrame: AVAudioFramePosition, lengthFrames: AVAudioFrameCount)? {
        guard sampleRate > 0, durationSeconds > 0 else { return nil }
        guard lengthSeconds > 0, startSeconds >= 0, startSeconds < durationSeconds else { return nil }

        let totalFrames = AVAudioFramePosition((durationSeconds * sampleRate).rounded())
        let startFrame = max(0, min(AVAudioFramePosition((startSeconds * sampleRate).rounded()), totalFrames))
        let maxLengthFrames = totalFrames - startFrame
        guard maxLengthFrames > 0 else { return nil }

        let requestedLengthFrames = AVAudioFramePosition((lengthSeconds * sampleRate).rounded())
        let lengthFrames = max(1, min(requestedLengthFrames, maxLengthFrames))
        return (startFrame, AVAudioFrameCount(lengthFrames))
    }

    static func wrap(
        elapsedFrames: AVAudioFramePosition,
        loopStartFrame: AVAudioFramePosition,
        lengthFrames: AVAudioFrameCount
    ) -> AVAudioFramePosition {
        guard lengthFrames > 0 else { return loopStartFrame }
        let length = AVAudioFramePosition(lengthFrames)
        let normalized = elapsedFrames % length
        let positive = normalized >= 0 ? normalized : normalized + length
        return loopStartFrame + positive
    }
}
