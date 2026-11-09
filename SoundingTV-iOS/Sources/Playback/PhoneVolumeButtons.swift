import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit

@MainActor
@Observable
final class PhoneVolumeButtons {
    static let shared = PhoneVolumeButtons()

    struct Overlay: Equatable {
        let name: String
        let symbol: String
        let level: Double
    }

    private(set) var overlay: Overlay?

    @ObservationIgnored private weak var coordinator: PhonePlaybackCoordinator?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var tracker: HardwareVolumeTracker?
    @ObservationIgnored private var window: PhoneVolumeWindow?
    @ObservationIgnored private var activatedAmbientSession = false
    @ObservationIgnored private var evaluateTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    private init() {}

    func attach(_ coordinator: PhonePlaybackCoordinator) {
        guard self.coordinator !== coordinator else { return }
        self.coordinator = coordinator
        cancellables.removeAll()
        coordinator.objectWillChange
            .sink { [weak self] _ in self?.scheduleEvaluate() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] _ in self?.scheduleEvaluate() }
            .store(in: &cancellables)
        scheduleEvaluate()
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        if active {
            scheduleEvaluate()
        } else {
            disengage()
        }
    }

    // MARK: - Engagement

    private func scheduleEvaluate() {
        guard evaluateTask == nil else { return }
        evaluateTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.evaluateTask = nil
            self.evaluate()
        }
    }

    private var wantsButtons: Bool {
        guard isForeground, let coordinator, coordinator.volumeRoute.isRemote else { return false }
        return coordinator.remoteVolume != nil
    }

    private func evaluate() {
        if wantsButtons {
            engage()
        } else {
            disengage()
        }
    }

    private func engage() {
        guard tracker == nil, let scene = Self.foregroundScene else { return }
        let session = AVAudioSession.sharedInstance()
        switch session.category {
        case .playback:
            if coordinator?.volumeRoute == .linked, session.isOtherAudioPlaying { return }
        case .ambient, .soloAmbient:
            guard !session.isOtherAudioPlaying else { return }
            do {
                try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
                activatedAmbientSession = true
            } catch {
                return
            }
        default:
            return
        }
        do {
            try session.setActive(true)
        } catch {
            releaseAmbientSession()
            return
        }

        let window = PhoneVolumeWindow(scene: scene, model: self)
        window.isHidden = false
        self.window = window

        let tracker = HardwareVolumeTracker(original: session.outputVolume)
        self.tracker = tracker
        observation = Self.observeOutputVolume { value in
            PhoneVolumeButtons.shared.receive(value)
        }
        if tracker.needsInitialReset { setSystemVolume(tracker.anchor) }
    }

    private func disengage() {
        guard tracker != nil || window != nil else { return }
        observation = nil
        if let restore = tracker?.restoreOnFinish { setSystemVolume(restore) }
        tracker = nil
        hideTask?.cancel()
        hideTask = nil
        overlay = nil
        window?.isHidden = true
        window = nil
        releaseAmbientSession()
    }

    private func releaseAmbientSession() {
        guard activatedAmbientSession else { return }
        activatedAmbientSession = false
        let session = AVAudioSession.sharedInstance()
        guard session.category == .ambient else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func observeOutputVolume(_ handler: @escaping @MainActor @Sendable (Float) -> Void) -> NSKeyValueObservation {
        AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in handler(value) }
        }
    }

    private static var foregroundScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    // MARK: - Buttons

    private func receive(_ value: Float) {
        guard var tracker, let coordinator else { return }
        let reading = tracker.observe(value)
        self.tracker = tracker
        if reading.steps != 0, coordinator.volumeRoute.isRemote {
            coordinator.stepRemoteVolume(reading.steps)
            showOverlay()
        }
        if let reset = reading.resetTo { setSystemVolume(reset) }
    }

    private func setSystemVolume(_ value: Float) {
        guard let slider = window?.slider else { return }
        slider.value = value
        slider.sendActions(for: .valueChanged)
    }

    private func showOverlay() {
        guard let coordinator, let level = coordinator.remoteVolume else { return }
        window?.layoutForOverlay()
        overlay = Overlay(name: coordinator.remoteVolumeName, symbol: coordinator.remoteVolumeSymbol, level: level)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.overlay = nil
        }
    }
}

private final class PhoneVolumeWindow: UIWindow {
    private let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))

    init(scene: UIWindowScene, model: PhoneVolumeButtons) {
        super.init(windowScene: scene)
        windowLevel = .alert + 1
        backgroundColor = .clear
        isUserInteractionEnabled = false
        let host = UIHostingController(rootView: PhoneVolumeOverlayView(model: model).tint(Color.scAccent))
        host.view.backgroundColor = .clear
        rootViewController = host
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        host.view.addSubview(volumeView)
        layoutForOverlay()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    func layoutForOverlay() {
        guard let scene = windowScene else { return }
        let bounds = scene.coordinateSpace.bounds
        let top = scene.windows.first { $0.isKeyWindow }?.safeAreaInsets.top ?? 0
        frame = CGRect(x: 0, y: top + 4, width: bounds.width, height: 64)
    }
}

private struct PhoneVolumeOverlayView: View {
    let model: PhoneVolumeButtons

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let overlay = model.overlay {
                HStack(spacing: 12) {
                    Image(systemName: overlay.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(overlay.name)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        ProgressView(value: overlay.level)
                            .tint(.primary)
                    }
                    .frame(width: 168)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(overlay.name) Volume")
                .accessibilityValue("\(Int((overlay.level * 100).rounded())) percent")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy, value: model.overlay)
    }
}
