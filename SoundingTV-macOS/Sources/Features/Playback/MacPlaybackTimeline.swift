import SwiftUI
import AppKit
import Combine
import CoreAudio
import AudioToolbox
import Observation

@MainActor
@Observable
final class MacPlaybackTimeline {
    static let shared = MacPlaybackTimeline()

    private(set) var anchor: PlaybackAnchor = .idle
    private(set) var isPlaying = false

    @ObservationIgnored private let player = PlayerService.shared
    @ObservationIgnored private var output: OutputRouter?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var outputCancellables = Set<AnyCancellable>()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var fixture: PlaybackAnchor?
    @ObservationIgnored private var pendingSeek: PendingRemoteSeek?
    @ObservationIgnored private var seekSettleTask: Task<Void, Never>?

    private init() {
        player.clock.$currentTime
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        player.clock.$duration
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        player.$isPlaying
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        player.$currentTrack
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        refresh()
    }

    func attach(output: OutputRouter) {
        guard self.output !== output else { return }
        self.output = output
        outputCancellables.removeAll()
        output.$current
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &outputCancellables)
        output.client.telemetry.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &outputCancellables)
        scheduleRefresh()
    }

    func position(at date: Date = .now) -> TimeInterval {
        anchor.position(at: date)
    }

    func seek(to position: TimeInterval) {
        noteSeek(to: position)
        guard fixture == nil else { return }
        if let output, output.isRemote {
            output.seek(to: position)
        } else {
            player.seek(to: position)
        }
    }

    func togglePlayPause() {
        if var fixture {
            let now = Date()
            fixture = PlaybackAnchor(
                position: fixture.position(at: now),
                date: now,
                rate: fixture.isAdvancing ? 0 : 1,
                duration: fixture.duration
            )
            self.fixture = fixture
            publish(fixture)
            return
        }
        if let output, output.isRemote {
            output.client.togglePlayPause()
        } else {
            player.togglePlayPause()
        }
    }

    #if DEBUG
    func adoptFixture(position: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        let fixed = PlaybackAnchor(position: position, date: .now, rate: isPlaying ? 1 : 0, duration: duration)
        fixture = fixed
        publish(fixed)
    }
    #endif

    private func noteSeek(to position: TimeInterval) {
        let now = Date()
        let next = anchor.seeking(to: position, at: now)
        let bounded = next.position
        if fixture != nil { fixture = next }
        publish(next)
        guard fixture == nil, let output, !output.current.isLocal else {
            clearPendingSeek()
            return
        }
        pendingSeek = PendingRemoteSeek(
            target: bounded,
            rate: anchor.rate,
            issuedAt: now,
            baselineRevision: output.client.telemetry.playback?.revision ?? 0
        )
        seekSettleTask?.cancel()
        seekSettleTask = Task { @MainActor [weak self] in
            for delay in [PendingRemoteSeek.grace, PendingRemoteSeek.deadline - PendingRemoteSeek.grace + 0.05] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private func clearPendingSeek() {
        pendingSeek = nil
        seekSettleTask?.cancel()
        seekSettleTask = nil
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.refreshTask = nil
            self.refresh()
        }
    }

    private func refresh() {
        if let fixture {
            if fixture != anchor { publish(fixture) }
            return
        }
        guard let output, !output.current.isLocal else {
            if pendingSeek != nil { clearPendingSeek() }
            let clock = player.clock
            let duration = clock.duration > 0 ? clock.duration : (player.currentTrack?.duration ?? 0)
            guard player.currentTrack != nil else {
                if anchor != .idle { publish(.idle) }
                return
            }
            reconcile(
                position: clock.currentTime,
                observedAt: clock.updatedAt,
                rate: player.isPlaying ? 1 : 0,
                duration: duration
            )
            return
        }
        let telemetry = output.client.telemetry
        guard let playback = telemetry.playback else {
            if anchor != .idle { publish(.idle) }
            return
        }
        let live = telemetry.isLive
        let now = Date()
        if let pendingSeek {
            let resolution = pendingSeek.resolution(
                revision: playback.revision,
                position: live ? telemetry.estimatedPosition(at: now) : nil,
                at: now
            )
            guard resolution == .settle else { return }
            clearPendingSeek()
        }
        reconcile(
            position: telemetry.estimatedPosition(at: now),
            observedAt: now,
            rate: live && playback.isPlaying ? playback.effectiveRate : 0,
            duration: playback.durationSeconds
        )
    }

    private func reconcile(position: TimeInterval, observedAt: Date, rate: Double, duration: TimeInterval) {
        guard let next = anchor.reconciled(position: position, observedAt: observedAt, rate: rate, duration: duration) else { return }
        publish(next)
    }

    private func publish(_ next: PlaybackAnchor) {
        if anchor != next { anchor = next }
        let playing: Bool
        if let fixture {
            playing = fixture.isAdvancing
        } else if let output, !output.current.isLocal {
            playing = next.isAdvancing
        } else {
            playing = player.isPlaying
        }
        if isPlaying != playing { isPlaying = playing }
    }
}


private struct MacPlaybackAnimationsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var macPlaybackAnimationsActive: Bool {
        get { self[MacPlaybackAnimationsActiveKey.self] }
        set { self[MacPlaybackAnimationsActiveKey.self] = newValue }
    }
}

struct MacLiveClock<Content: View>: View {
    var override: TimeInterval? = nil
    @ViewBuilder var content: (TimeInterval) -> Content

    @Environment(\.macPlaybackAnimationsActive) private var animationsActive

    var body: some View {
        let anchor = MacPlaybackTimeline.shared.anchor
        if let override {
            content(override)
        } else if anchor.isAdvancing && animationsActive {
            TimelineView(.periodic(from: anchor.nextWholeSecond(after: .now), by: 1 / anchor.rate)) { context in
                content(anchor.position(at: context.date))
            }
        } else {
            content(anchor.position(at: .now))
        }
    }
}

private struct MacPlayheadSampler: ViewModifier {
    let interval: Duration
    let isEnabled: Bool
    let action: (TimeInterval) -> Void

    @Environment(\.macPlaybackAnimationsActive) private var animationsActive

    private struct Key: Equatable {
        let anchor: PlaybackAnchor
        let live: Bool
    }

    func body(content: Content) -> some View {
        let anchor = MacPlaybackTimeline.shared.anchor
        let live = isEnabled && animationsActive && anchor.isAdvancing
        content.task(id: Key(anchor: anchor, live: live)) {
            guard isEnabled else { return }
            action(anchor.position(at: .now))
            guard live else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                action(anchor.position(at: .now))
            }
        }
    }
}

extension View {
    func macSamplePlayhead(
        every interval: Duration = .milliseconds(500),
        isEnabled: Bool = true,
        perform action: @escaping (TimeInterval) -> Void
    ) -> some View {
        modifier(MacPlayheadSampler(interval: interval, isEnabled: isEnabled, action: action))
    }
}


struct MacWindowActivityReader: NSViewRepresentable {
    @Binding var isActive: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { active in
            if isActive != active { isActive = active }
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = { active in
            if isActive != active { isActive = active }
        }
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private var lastValue: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            rebind()
        }

        private func rebind() {
            let center = NotificationCenter.default
            tokens.forEach(center.removeObserver)
            tokens.removeAll()
            guard let window else { return }
            let windowNames: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            for name in windowNames {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.evaluate() }
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                tokens.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.evaluate() }
                })
            }
            evaluate()
        }

        private func evaluate() {
            guard let window else { return }
            let active = !NSApp.isHidden
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
            guard active != lastValue else { return }
            lastValue = active
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onChange?(active) }
            }
        }
    }
}

struct MacViewAnchor: NSViewRepresentable {
    let onAttach: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassiveView()
        onAttach(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PassiveView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    static func windowRect(of view: NSView?) -> CGRect? {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let rect = view.convert(view.bounds, to: nil)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return CGRect(x: rect.minX, y: window.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }
}


@MainActor
@Observable
final class MacSystemVolume {
    static let shared = MacSystemVolume()

    private(set) var volume: Double = 0.5
    private(set) var isAvailable = false

    @ObservationIgnored private var deviceID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var started = false
    @ObservationIgnored private nonisolated(unsafe) var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private nonisolated(unsafe) var volumeListener: AudioObjectPropertyListenerBlock?

    private init() {}

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        guard !started else { return }
        started = true
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { MacSystemVolume.shared.bindDefaultDevice() }
        }
        defaultDeviceListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, DispatchQueue.main, block
        )
        bindDefaultDevice()
    }

    func set(_ value: Double) {
        guard isAvailable else { return }
        var scalar = Float32(min(1, max(0, value)))
        let status = AudioObjectSetPropertyData(
            deviceID, &Self.volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar
        )
        if status == noErr { volume = Double(scalar) }
    }

    private func bindDefaultDevice() {
        if let volumeListener, deviceID != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(deviceID, &Self.volumeAddress, DispatchQueue.main, volumeListener)
            self.volumeListener = nil
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown,
              AudioObjectHasProperty(device, &Self.volumeAddress) else {
            deviceID = AudioObjectID(kAudioObjectUnknown)
            isAvailable = false
            return
        }
        deviceID = device
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(device, &Self.volumeAddress, &settable)
        isAvailable = settable.boolValue
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { MacSystemVolume.shared.readVolume() }
        }
        volumeListener = block
        AudioObjectAddPropertyListenerBlock(device, &Self.volumeAddress, DispatchQueue.main, block)
        readVolume()
    }

    private func readVolume() {
        guard deviceID != kAudioObjectUnknown else { return }
        var scalar = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &Self.volumeAddress, 0, nil, &size, &scalar)
        guard status == noErr else { return }
        let next = Double(scalar)
        if abs(next - volume) > 0.001 { volume = next }
    }
}
