import SwiftUI
import UIKit
import Combine

// MARK: - Remote touch scrubbing

enum RemoteScrub {
    static let swipeSpan: CGFloat = 900
    static let engageThreshold: CGFloat = 14
    static let shortestSpan: TimeInterval = 45
    static let longTrackMinimumSpan: TimeInterval = 600
    static let longestSpan: TimeInterval = 3600
    static let moveCooldown: Duration = .milliseconds(450)
    static let settleDelay: Duration = .milliseconds(700)

    static func span(for duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 0 }
        if duration <= longTrackMinimumSpan {
            return max(duration, shortestSpan)
        }
        return min(max(duration * 0.4, longTrackMinimumSpan), longestSpan)
    }

    static func time(
        from anchor: TimeInterval,
        translation: CGFloat,
        duration: TimeInterval,
        span overrideSpan: TimeInterval? = nil
    ) -> TimeInterval {
        let raw = Double(translation / swipeSpan)
        let magnitude = min(1.5, abs(raw))
        let accelerated = raw.sign == .minus ? -pow(magnitude, 1.35) : pow(magnitude, 1.35)
        let delta = accelerated * (overrideSpan ?? span(for: duration))
        return min(max(0, anchor + delta), max(duration, 0))
    }

    static func delta(_ seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded())
        guard rounded != 0 else { return "0:00" }
        let sign = rounded < 0 ? "\u{2212}" : "+"
        return sign + DJFormat.time(TimeInterval(abs(rounded)))
    }
}

struct RemoteScrubSurface: UIViewRepresentable {
    var isActive: Bool
    var capturesExit: Bool
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void
    var onCancelled: () -> Void
    var onExit: () -> Void

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
        private var surface: RemoteScrubSurface
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

        private lazy var exitPress: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleExitPress))
            recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            recognizer.cancelsTouchesInView = true
            recognizer.delegate = self
            return recognizer
        }()

        init(surface: RemoteScrubSurface) {
            self.surface = surface
        }

        func update(surface: RemoteScrubSurface) {
            self.surface = surface
            pan.isEnabled = surface.isActive
            exitPress.isEnabled = surface.isActive && surface.capturesExit
            if !surface.isActive, engaged {
                engaged = false
                surface.onCancelled()
            }
        }

        func attach(to window: UIWindow?) {
            guard attachedWindow !== window else { return }
            attachedWindow?.removeGestureRecognizer(pan)
            attachedWindow?.removeGestureRecognizer(exitPress)
            attachedWindow = window
            window?.addGestureRecognizer(pan)
            window?.addGestureRecognizer(exitPress)
            pan.isEnabled = surface.isActive
            exitPress.isEnabled = surface.isActive && surface.capturesExit
        }

        @objc private func handleExitPress() {
            guard surface.isActive, surface.capturesExit else { return }
            surface.onExit()
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view).x

            switch recognizer.state {
            case .began:
                engaged = false
            case .changed:
                if !engaged {
                    guard abs(translation) >= RemoteScrub.engageThreshold else { return }
                    engaged = true
                    surface.onBegan()
                }
                surface.onChanged(translation)
            case .ended:
                guard engaged else { return }
                engaged = false
                surface.onEnded(translation)
            case .cancelled, .failed:
                guard engaged else { return }
                engaged = false
                surface.onCancelled()
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

enum CommentsLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

@MainActor
final class TrackCommentsStore: ObservableObject {
    let pager = Paginator<Comment>(soundCloudSource: PagedSource(
        first: { PagedChunk(items: []) },
        next: { _ in PagedChunk(items: []) }
    ))

    var comments: [Comment] { pager.items }

    var state: CommentsLoadState {
        if loadedTrackId == nil { return .idle }
        if pager.hasLoadedFirst { return .loaded }
        if pager.firstError != nil { return .failed }
        return .loading
    }

    private var loadedTrackId: String?
    private var task: Task<Void, Never>?
    private var pagerObservation: AnyCancellable?

    init() {
        pagerObservation = pager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func ensureLoaded(for track: Track?) {
        guard let track, track.supportsSoundCloudActions else {
            reset()
            return
        }
        guard track.id != loadedTrackId else { return }
        loadedTrackId = track.id
        #if DEBUG
        if CommentDemo.isEnabled {
            pager.prime(items: CommentDemo.comments(), cursor: nil)
            return
        }
        #endif
        pager.reset()
        let trackId = track.id
        pager.setSource(PagedSource(
            first: {
                let page = try await SoundCloudAPI.shared.getComments(trackId: trackId)
                return PagedChunk(items: page.collection, next: page.nextHref.map(PagedCursor.url))
            },
            next: { cursor in
                guard case .url(let url) = cursor else { return PagedChunk(items: []) }
                let page = try await SoundCloudAPI.shared.getPage(Comment.self, from: url)
                return PagedChunk(items: page.collection, next: page.nextHref.map(PagedCursor.url))
            }
        ))
        task?.cancel()
        task = Task { [pager] in
            await pager.reload()
        }
    }

    func retry(for track: Track?) {
        loadedTrackId = nil
        ensureLoaded(for: track)
    }

    private func reset() {
        task?.cancel()
        task = nil
        loadedTrackId = nil
        pager.reset()
    }

    var timedComments: [Comment] {
        CommentTimeline.ordered(comments)
    }
}
