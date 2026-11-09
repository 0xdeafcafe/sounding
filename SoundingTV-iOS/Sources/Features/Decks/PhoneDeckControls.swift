import SwiftUI
import UIKit

@MainActor
enum DeckHaptics {
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notice = UINotificationFeedbackGenerator()

    static func detent() { rigid.impactOccurred(intensity: 0.8) }
    static func edge() { soft.impactOccurred(intensity: 0.6) }
    static func beat() { selection.selectionChanged() }
    static func press() { rigid.impactOccurred(intensity: 0.5) }
    static func success() { notice.notificationOccurred(.success) }
    static func warning() { notice.notificationOccurred(.warning) }
}

enum DeckDragMode: Equatable {
    case idle
    case coarse
    case fine
}

enum DeckDragAxis {
    case rotary
    case vertical
    case horizontal
}

struct DeckDragControl: ViewModifier {
    let value: Double
    var axis: DeckDragAxis
    var span: CGFloat
    var detent: Double?
    var resetValue: Double?
    var isDisabled = false
    @Binding var mode: DeckDragMode
    var onGrab: () -> Void
    var onChange: (Double) -> Void

    @State private var start: Double?
    @State private var moved = false
    @State private var fineTimer: Task<Void, Never>?
    @State private var lastTap: Date?
    @State private var lastOutput: Double?

    private static let fineScale = 0.2
    private static let fineDelay: Duration = .milliseconds(350)

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(isDisabled ? nil : drag)
            .accessibilityAdjustableAction { direction in
                guard !isDisabled else { return }
                onGrab()
                var next = value + (direction == .increment ? 0.05 : -0.05)
                if let detent, (value - detent) * (next - detent) < 0 { next = detent }
                onChange(min(1, max(0, next)))
            }
            .accessibilityActions {
                if let resetValue, !isDisabled {
                    Button("Reset") {
                        onGrab()
                        onChange(resetValue)
                    }
                }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if start == nil { begin() }
                let distance = travel(of: gesture.translation)
                if !moved {
                    guard mode == .fine || abs(distance) >= 3 else { return }
                    moved = true
                    fineTimer?.cancel()
                    if mode != .fine {
                        mode = .coarse
                        onGrab()
                    }
                }
                let scale = mode == .fine ? Self.fineScale : 1
                var next = min(1, max(0, (start ?? value) + Double(distance / max(1, span)) * scale))
                if let detent, abs(next - detent) < (mode == .fine ? 0.006 : 0.03) { next = detent }
                feedback(next)
                onChange(next)
            }
            .onEnded { _ in
                fineTimer?.cancel()
                if !moved, mode != .fine { tapped() }
                start = nil
                moved = false
                lastOutput = nil
                mode = .idle
            }
    }

    private func travel(of translation: CGSize) -> CGFloat {
        switch axis {
        case .rotary: return translation.width - translation.height
        case .vertical: return -translation.height
        case .horizontal: return translation.width
        }
    }

    private func begin() {
        start = value
        lastOutput = value
        fineTimer?.cancel()
        fineTimer = Task { @MainActor in
            try? await Task.sleep(for: Self.fineDelay)
            guard !Task.isCancelled, !moved, start != nil else { return }
            mode = .fine
            DeckHaptics.press()
            onGrab()
        }
    }

    private func feedback(_ next: Double) {
        defer { lastOutput = next }
        guard let last = lastOutput, last != next else { return }
        if let detent, next == detent {
            DeckHaptics.detent()
        } else if next <= 0 || next >= 1 {
            DeckHaptics.edge()
        }
    }

    private func tapped() {
        let now = Date()
        guard let previous = lastTap, now.timeIntervalSince(previous) < 0.35, let resetValue else {
            lastTap = now
            return
        }
        lastTap = nil
        onGrab()
        onChange(resetValue)
        DeckHaptics.detent()
    }
}

struct DeckValueBubble: View {
    let text: String
    var isFine = false

    var body: some View {
        Text(isFine ? "Fine \u{00B7} \(text)" : text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: Capsule())
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct PhoneDeckKnob: View {
    let value: Double
    var target: Double?
    var isYours = false
    var isDisabled = false
    var size: CGFloat = 44
    var detent: Double? = 0.5
    var resetValue: Double? = 0.5
    var valueText: String?
    var onGrab: () -> Void = {}
    var onChange: (Double) -> Void = { _ in }

    @State private var mode: DeckDragMode = .idle

    var body: some View {
        MacDJKnob(value: value, target: target, isYours: isYours, isDisabled: isDisabled, size: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .scaleEffect(mode == .idle ? 1 : 1.1)
            .animation(.snappy(duration: 0.15), value: mode)
            .frame(width: max(44, size), height: max(44, size))
            .overlay(alignment: .top) {
                if mode != .idle, let valueText {
                    DeckValueBubble(text: valueText, isFine: mode == .fine)
                        .offset(y: -max(44, size) * 0.5 - 6)
                }
            }
            .zIndex(mode == .idle ? 0 : 1)
            .accessibilityElement()
            .accessibilityValue(valueText ?? "\(Int((value * 100).rounded())) percent")
            .modifier(DeckDragControl(
                value: value,
                axis: .rotary,
                span: 160,
                detent: detent,
                resetValue: resetValue,
                isDisabled: isDisabled,
                mode: $mode,
                onGrab: onGrab,
                onChange: onChange
            ))
    }
}

struct PhoneDeckFader: View {
    let value: Double
    var target: Double?
    var isYours = false
    var isDisabled = false
    var height: CGFloat
    var valueText: String?
    var onGrab: () -> Void = {}
    var onChange: (Double) -> Void = { _ in }

    @State private var mode: DeckDragMode = .idle

    var body: some View {
        MacDJVerticalFader(value: value, target: target, isYours: isYours, isDisabled: isDisabled, height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .frame(width: 20, height: height)
            .padding(.horizontal, 6)
            .overlay(alignment: .top) {
                if mode != .idle, let valueText {
                    DeckValueBubble(text: valueText, isFine: mode == .fine)
                        .offset(y: CGFloat(1 - value) * height - 34)
                }
            }
            .zIndex(mode == .idle ? 0 : 1)
            .accessibilityElement()
            .accessibilityValue(valueText ?? "\(Int((value * 100).rounded())) percent")
            .modifier(DeckDragControl(
                value: value,
                axis: .vertical,
                span: height,
                detent: nil,
                resetValue: 1,
                isDisabled: isDisabled,
                mode: $mode,
                onGrab: onGrab,
                onChange: onChange
            ))
    }
}

struct PhoneDeckCrossfader: View {
    let value: Double
    var target: Double?
    var isYours = false
    var isDisabled = false
    var onGrab: () -> Void = {}
    var onChange: (Double) -> Void = { _ in }

    @State private var mode: DeckDragMode = .idle
    @State private var width: CGFloat = 200

    var body: some View {
        MacDJCrossfader(value: value, target: target, isYours: isYours)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .frame(height: 44)
            .opacity(isDisabled ? 0.4 : 1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .top) {
                if mode == .fine {
                    DeckValueBubble(text: Self.text(value), isFine: true).offset(y: -22)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Crossfader")
            .accessibilityValue(Self.text(value))
            .modifier(DeckDragControl(
                value: value,
                axis: .horizontal,
                span: max(60, width - 44),
                detent: 0.5,
                resetValue: 0.5,
                isDisabled: isDisabled,
                mode: $mode,
                onGrab: onGrab,
                onChange: onChange
            ))
    }

    static func text(_ value: Double) -> String {
        if abs(value - 0.5) < 0.005 { return "Centre" }
        let percent = Int((abs(value - 0.5) * 200).rounded())
        return value < 0.5 ? "A \(percent)%" : "B \(percent)%"
    }
}

// MARK: Orientation

@MainActor
enum DecksOrientationLock {
    static let storageKey = "decks.lockLandscape"
    private(set) static var mask: UIInterfaceOrientationMask = .all

    static var isAvailable: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    static func apply(_ locked: Bool) {
        guard isAvailable else { return }
        let next: UIInterfaceOrientationMask = locked ? .landscape : .all
        guard next != mask else { return }
        mask = next
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: locked ? .landscape : .allButUpsideDown)) { _ in }
    }
}

// MARK: Backdrop

struct PhoneDecksBackdrop: View {
    let url: URL?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            MacDJPalette.chassis
            if !reduceTransparency, url != nil {
                CollectionPageMesh(url: url)
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
