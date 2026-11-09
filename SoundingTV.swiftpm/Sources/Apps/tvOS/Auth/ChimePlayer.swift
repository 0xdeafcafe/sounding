import AVFoundation
import Combine
import QuartzCore
import os

@MainActor
final class ChimePlayer {
    struct RenderState {
        var carrier: CarrierOscillator?
        var nextCarrier: CarrierOscillator?
        var carrierWanted = false
        var carrierGain: Float = 0
        var carrierBoost: Float = 1
        var carrierBoostTarget: Float = 1
        var carrierBoostHold = 0
        var cue = ChimeStereo(seconds: 0, sampleRate: 48_000)
        var cuePosition = 0
        var ping = ChimeStereo(seconds: 0, sampleRate: 48_000)
        var pingPosition = 0
        var pingWanted = false
        var pingsLeft = ChimeSynth.audiblePings

        var cueIsPlaying: Bool { cuePosition < cue.count }
        var isSilent: Bool { carrierGain == 0 && !cueIsPlaying && !pingWanted }
    }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let state = OSAllocatedUnfairLock(initialState: RenderState())
    private var sampleRate: Double = 48_000
    private var code: ChimeCode?
    private var stopTask: Task<Void, Never>?
    private var carrierAnnounced = false
    private var carrierOff: Task<Void, Never>?
    private var rendering: Task<Void, Never>?

    let events = PassthroughSubject<SignInEvent, Never>()

    nonisolated static let fadeSeconds: Double = 0.45
    nonisolated static let pingRestSeconds: Double = 1.4
    nonisolated static let carrierFrames: Double = 2

    func prepare(_ newCode: ChimeCode?, canPlay: Bool) {
        let next = canPlay ? newCode : nil
        let changed = next != code
        code = next
        if changed { silenceCarrier() }
    }

    func playChime() {
        guard let code, rendering == nil, !state.withLock({ $0.cueIsPlaying }), start() else { return }
        let rate = sampleRate
        rendering = Task { [weak self] in
            let handshake = await Self.renderWelcomeTone(sampleRate: rate)
            guard let self else { return }
            self.rendering = nil
            guard !Task.isCancelled, self.code == code, self.start() else { return }
            self.sound(handshake, code: code)
        }
    }

    @concurrent private nonisolated static func renderWelcomeTone(sampleRate: Double) async -> ChimeStereo {
        ChimeSynth.renderWelcomeTone(sampleRate: sampleRate)
    }

    private func sound(_ handshake: ChimeStereo, code: ChimeCode) {
        carrierOff?.cancel()
        let oscillator = CarrierOscillator(code: code, sampleRate: sampleRate)
        let boost = ChimeReplay.carrierGain(for: .playSound)
        let frame = ChimeLayer.carrier.frameDuration
        let hold = handshake.count + Int(frame * sampleRate)
        let swapsLater = state.withLock { render -> Bool in
            render.carrierWanted = true
            render.pingWanted = false
            render.carrierBoostTarget = boost
            render.carrierBoostHold = hold
            if render.carrier == nil || render.carrierGain == 0 {
                render.carrier = oscillator
                render.nextCarrier = nil
                return false
            }
            render.nextCarrier = oscillator
            return true
        }
        announceCarrier(ChimeCarrierLoop(
            start: CACurrentMediaTime() + outputDelay + (swapsLater ? Self.fadeSeconds : 0),
            period: frame
        ))
        play(handshake, schedule: handshake, delay: 0)
        let carrierSeconds = Double(handshake.count) / sampleRate + Self.carrierFrames * frame
        carrierOff = Task { [weak self] in
            try? await Task.sleep(for: .seconds(carrierSeconds))
            guard let self, !Task.isCancelled else { return }
            self.silenceCarrier()
        }
    }

    private func silenceCarrier() {
        carrierOff?.cancel()
        carrierOff = nil
        state.withLock {
            $0.carrierWanted = false
            $0.pingWanted = false
        }
        announceCarrier(nil)
        scheduleStopWhenSilent()
    }

    func playSuccess() {
        guard start() else { return }
        let success = ChimeSynth.renderWelcomeTone(sampleRate: sampleRate, success: true)
        state.withLock { render in
            render.pingWanted = false
            render.cue = success
            render.cuePosition = 0
        }
        scheduleStopWhenSilent()
    }

    private func play(_ cue: ChimeStereo, schedule handshake: ChimeStereo, delay: Double) {
        state.withLock { render in
            render.cue = cue
            render.cuePosition = 0
        }
        events.send(.chime(ChimeSchedule(
            start: CACurrentMediaTime() + outputDelay + delay,
            duration: Double(handshake.count) / sampleRate,
            beats: [],
            pump: [],
            sparkle: []
        )))
        scheduleStopWhenSilent()
    }

    private var outputDelay: TimeInterval {
        let session = AVAudioSession.sharedInstance()
        return session.outputLatency + session.ioBufferDuration
    }

    private func announceCarrier(_ loop: ChimeCarrierLoop?) {
        guard loop != nil || carrierAnnounced else { return }
        carrierAnnounced = loop != nil
        events.send(.carrier(loop))
    }

    func stop() {
        code = nil
        rendering?.cancel()
        rendering = nil
        carrierOff?.cancel()
        carrierOff = nil
        announceCarrier(nil)
        state.withLock {
            $0.carrierWanted = false
            $0.pingWanted = false
            $0.pingsLeft = ChimeSynth.audiblePings
            $0.cuePosition = $0.cue.count
            $0.carrierBoostTarget = 1
            $0.carrierBoostHold = 0
        }
        scheduleStopWhenSilent()
    }

    private func start() -> Bool {
        stopTask?.cancel()
        stopTask = nil
        if engine.isRunning { return true }
        configureSession()

        if source == nil {
            let format = engine.outputNode.outputFormat(forBus: 0)
            sampleRate = format.sampleRate > 0 ? format.sampleRate : 48_000
            let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
            let node = AVAudioSourceNode(format: stereoFormat!, renderBlock: Self.renderBlock(state: state, sampleRate: sampleRate))
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: stereoFormat)
            source = node
        }

        do {
            try engine.start()
            return true
        } catch {
            Log.link.error("[ChimePlayer] couldn't start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playback else { return }
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            Log.link.error("[ChimePlayer] audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleStopWhenSilent() {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                let silent = self.state.withLock { !$0.carrierWanted && $0.isSilent }
                if silent {
                    self.engine.stop()
                    self.state.withLock {
                        $0.carrier = nil
                        $0.nextCarrier = nil
                        $0.cue = ChimeStereo(seconds: 0, sampleRate: 48_000)
                        $0.cuePosition = 0
                        $0.ping = ChimeStereo(seconds: 0, sampleRate: 48_000)
                        $0.pingPosition = 0
                    }
                    return
                }
            }
        }
    }

    private nonisolated static func renderBlock(
        state: OSAllocatedUnfairLock<RenderState>,
        sampleRate: Double
    ) -> AVAudioSourceNodeRenderBlock {
        let step = Float(1 / (fadeSeconds * sampleRate))
        let rest = Int(pingRestSeconds * sampleRate)
        return { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            state.withLockUnchecked { render in
                for frame in 0..<Int(frameCount) {
                    let (left, right) = nextFrame(&render, fadeStep: step, pingRest: rest)
                    if buffers.count >= 2 {
                        buffers[0].mData?.assumingMemoryBound(to: Float.self)[frame] = left
                        buffers[1].mData?.assumingMemoryBound(to: Float.self)[frame] = right
                    } else if let buffer = buffers.first {
                        buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = (left + right) / 2
                    }
                }
            }
            return noErr
        }
    }

    nonisolated static func nextFrame(_ render: inout RenderState, fadeStep: Float, pingRest: Int) -> (Float, Float) {
        let target: Float = render.carrierWanted && render.nextCarrier == nil ? 1 : 0
        if render.carrierGain < target {
            render.carrierGain = min(target, render.carrierGain + fadeStep)
        } else if render.carrierGain > target {
            render.carrierGain = max(target, render.carrierGain - fadeStep)
        }
        if render.carrierGain == 0, let next = render.nextCarrier {
            render.carrier = next
            render.nextCarrier = nil
        }

        if render.carrierBoostHold > 0 {
            render.carrierBoostHold -= 1
            if render.carrierBoostHold == 0 { render.carrierBoostTarget = 1 }
        }
        if render.carrierBoost < render.carrierBoostTarget {
            render.carrierBoost = min(render.carrierBoostTarget, render.carrierBoost + fadeStep)
        } else if render.carrierBoost > render.carrierBoostTarget {
            render.carrierBoost = max(render.carrierBoostTarget, render.carrierBoost - fadeStep)
        }

        var carrier: Float = 0
        if render.carrierGain > 0, render.carrier != nil {
            let shaped = 0.5 - 0.5 * cos(Float.pi * render.carrierGain)
            carrier = render.carrier!.next() * ChimeSynth.carrierLevel * render.carrierBoost * shaped
        }
        var left = carrier
        var right = carrier
        if render.cuePosition < render.cue.count {
            left += render.cue.left[render.cuePosition]
            right += render.cue.right[render.cuePosition]
            render.cuePosition += 1
            if render.cuePosition == render.cue.count { render.pingPosition = -pingRest }
        } else if render.pingWanted, render.ping.count > 0 {
            if render.pingPosition >= 0 {
                left += render.ping.left[render.pingPosition]
                right += render.ping.right[render.pingPosition]
            }
            render.pingPosition += 1
            if render.pingPosition >= render.ping.count {
                render.pingPosition = 0
                render.pingsLeft -= 1
                if render.pingsLeft <= 0 { render.pingWanted = false }
            }
        }
        return (left, right)
    }
}
