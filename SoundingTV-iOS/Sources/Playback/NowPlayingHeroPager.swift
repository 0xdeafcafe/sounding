import SwiftUI

struct SkipCarousel<Page: View>: View {
    typealias Preview = PhonePlaybackCoordinator.SkipPreview

    let current: Preview
    let currentID: String
    let previous: @MainActor () -> Preview?
    let next: Preview?
    let commitThreshold: CGFloat
    let isEnabled: Bool
    let gap: CGFloat
    let clips: Bool
    let onCommit: (Edge) -> Void
    let page: (Preview, Bool) -> Page

    init(
        current: Preview,
        currentID: String,
        previous: @autoclosure @escaping @MainActor () -> Preview?,
        next: Preview?,
        commitThreshold: CGFloat = 0.28,
        isEnabled: Bool = true,
        gap: CGFloat = 0,
        clips: Bool = true,
        onCommit: @escaping (Edge) -> Void,
        @ViewBuilder page: @escaping (Preview, Bool) -> Page
    ) {
        self.current = current
        self.currentID = currentID
        self.previous = previous
        self.next = next
        self.commitThreshold = commitThreshold
        self.isEnabled = isEnabled
        self.gap = gap
        self.clips = clips
        self.onCommit = onCommit
        self.page = page
    }

    private static var settle: Animation { .spring(response: 0.5, dampingFraction: 0.86) }

    private var stride: CGFloat { width + gap }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragX: CGFloat = 0
    @State private var width: CGFloat = 320
    @State private var phase: Phase = .idle
    @State private var frozen: Frozen?
    @State private var pendingSnapshotChange = false
    @State private var commitFeedback = 0
    @State private var releaseTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case idle
        case dragging
        case settling
        case awaitingSnapshot
    }

    private struct Frozen {
        let current: Preview
        let previous: Preview?
        let next: Preview?
    }

    private var shownCurrent: Preview { frozen?.current ?? current }
    private var shownPrevious: Preview? { frozen?.previous ?? previous() }
    private var shownNext: Preview? { frozen?.next ?? next }
    private var showsNeighbours: Bool { dragX != 0 || phase != .idle }

    var body: some View {
        ZStack {
            page(shownCurrent, true)
                .offset(x: dragX)
                .opacity(1 - transitionProgress * 0.35)

            if showsNeighbours, let next = shownNext {
                page(next, false)
                    .offset(x: dragX + stride)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if showsNeighbours, let previous = shownPrevious {
                page(previous, false)
                    .offset(x: dragX - stride)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .modifier(SkipCarouselClip(clips: clips))
        .contentShape(Rectangle())
        .gesture(panGesture)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
        .onChange(of: currentID) { _, _ in snapshotDidChange() }
        .sensoryFeedback(.selection, trigger: commitFeedback)
        .accessibilityAction(named: "Next Track") { commit(.trailing) }
        .accessibilityAction(named: "Previous Track") { commit(.leading) }
    }

    private var transitionProgress: CGFloat {
        min(1, abs(dragX) / stride)
    }

    private var panGesture: HorizontalPanGesture {
        HorizontalPanGesture(
            onChanged: { translation in
                guard isEnabled, phase == .idle || phase == .dragging else { return }
                phase = .dragging
                let dx = translation.width
                let hasNeighbour = dx < 0 ? next != nil : previous() != nil
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragX = hasNeighbour ? dx : Self.rubberBand(dx, limit: width * 0.22)
                }
            },
            onEnded: { translation, projected in
                guard phase == .dragging else { return }
                let dx = translation.width
                let threshold = width * commitThreshold
                let flick = abs(projected.width - dx) > width * 0.3
                if (min(dx, projected.width) <= -threshold || (flick && dx < -24)), next != nil {
                    commit(.trailing)
                } else if (max(dx, projected.width) >= threshold || (flick && dx > 24)), previous() != nil {
                    commit(.leading)
                } else {
                    phase = .idle
                    withAnimation(reduceMotion ? nil : Self.settle) { dragX = 0 }
                }
            }
        )
    }

    private static func rubberBand(_ dx: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0, dx != 0 else { return 0 }
        let magnitude = abs(dx)
        let banded = limit * (1 - 1 / (magnitude / limit + 1))
        return dx < 0 ? -banded : banded
    }

    private func commit(_ edge: Edge) {
        guard phase == .idle || phase == .dragging else { return }
        let previousPreview = previous()
        guard let destination = edge == .trailing ? next : previousPreview else { return }
        if destination == current {
            phase = .idle
            commitFeedback += 1
            onCommit(edge)
            withAnimation(reduceMotion ? nil : Self.settle) { dragX = 0 }
            return
        }
        frozen = Frozen(current: current, previous: previousPreview, next: next)
        pendingSnapshotChange = false
        phase = .settling
        commitFeedback += 1
        onCommit(edge)

        let target: CGFloat = edge == .trailing ? -stride : stride
        if reduceMotion {
            dragX = target
            finishSettling()
        } else {
            withAnimation(Self.settle) {
                dragX = target
            } completion: {
                finishSettling()
            }
        }
    }

    private func finishSettling() {
        guard phase == .settling else { return }
        if pendingSnapshotChange {
            release()
            return
        }
        phase = .awaitingSnapshot
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, phase == .awaitingSnapshot else { return }
            phase = .idle
            frozen = nil
            withAnimation(reduceMotion ? nil : Self.settle) { dragX = 0 }
        }
    }

    private func snapshotDidChange() {
        switch phase {
        case .settling:
            pendingSnapshotChange = true
        case .awaitingSnapshot, .idle, .dragging:
            release()
        }
    }

    private func release() {
        releaseTask?.cancel()
        releaseTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragX = 0
            frozen = nil
            pendingSnapshotChange = false
            phase = .idle
        }
    }
}

private struct SkipCarouselClip: ViewModifier {
    let clips: Bool

    func body(content: Content) -> some View {
        if clips {
            content.clipped()
        } else {
            content
        }
    }
}
