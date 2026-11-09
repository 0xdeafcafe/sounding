import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import Observation

@MainActor
enum TVDecksPresence {
    static var isOnScreen = false
}

struct TVDecksTouchSurface: UIViewRepresentable {
    var isActive: Bool
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    static let engageThreshold: CGFloat = 12

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onWindowChange = { [coordinator = context.coordinator] window in
            coordinator.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(surface: self)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(surface: self) }

    private final class HostView: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var surface: TVDecksTouchSurface
        private weak var attachedWindow: UIWindow?
        private var engaged = false

        private lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            recognizer.cancelsTouchesInView = true
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        init(surface: TVDecksTouchSurface) {
            self.surface = surface
        }

        func update(surface: TVDecksTouchSurface) {
            self.surface = surface
            pan.isEnabled = surface.isActive
            if !surface.isActive, engaged {
                engaged = false
                surface.onEnded()
            }
        }

        func attach(to window: UIWindow?) {
            guard attachedWindow !== window else { return }
            attachedWindow?.removeGestureRecognizer(pan)
            attachedWindow = window
            window?.addGestureRecognizer(pan)
            pan.isEnabled = surface.isActive
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            switch recognizer.state {
            case .began:
                engaged = false
            case .changed:
                if !engaged {
                    guard abs(translation.x) >= TVDecksTouchSurface.engageThreshold,
                          abs(translation.x) > abs(translation.y) else { return }
                    engaged = true
                    surface.onBegan()
                }
                surface.onChanged(translation.x)
            case .ended, .cancelled, .failed:
                guard engaged else { return }
                engaged = false
                surface.onEnded()
            default:
                break
            }
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

@MainActor
@Observable
final class TVDecksShowMode {
    private(set) var isShowing = false

    @ObservationIgnored private var eligible = false
    @ObservationIgnored private var lastInput = Date.now
    @ObservationIgnored private var waiter: Task<Void, Never>?
    @ObservationIgnored private var spy: TVDecksInputSpy?

    static var timeout: TimeInterval {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_DECKS_SHOW_AFTER"], let seconds = Double(raw), seconds > 0 {
            return seconds
        }
        #endif
        return 15
    }

    func setEligible(_ value: Bool) {
        guard value != eligible else { return }
        eligible = value
        if value {
            lastInput = .now
            attachSpy()
            arm()
        } else {
            waiter?.cancel()
            waiter = nil
            detachSpy()
            if isShowing { isShowing = false }
        }
    }

    func wake() {
        lastInput = .now
        guard isShowing else { return }
        isShowing = false
        arm()
    }

    private func noteInput() {
        guard !isShowing else { return }
        lastInput = .now
    }

    private func arm() {
        waiter?.cancel()
        waiter = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.eligible else { return }
                let remaining = Self.timeout - Date.now.timeIntervalSince(self.lastInput)
                if remaining <= 0 {
                    self.isShowing = true
                    return
                }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    private func attachSpy() {
        guard spy == nil, let window = Self.keyWindow else { return }
        let recognizer = TVDecksInputSpy()
        recognizer.onInput = { [weak self] in self?.noteInput() }
        window.addGestureRecognizer(recognizer)
        spy = recognizer
    }

    private func detachSpy() {
        if let spy { spy.view?.removeGestureRecognizer(spy) }
        spy = nil
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

private final class TVDecksInputSpy: UIGestureRecognizer {
    var onInput: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onInput?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        onInput?()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        onInput?()
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        onInput?()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = .failed
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = .failed
    }
}
