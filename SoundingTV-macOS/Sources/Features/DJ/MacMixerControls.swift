import SwiftUI
import AppKit
import Combine

struct MacDeckSlice<Value: Equatable, Content: View>: View {
    private let read: ([MixEngine.DeckState]) -> Value
    private let content: (Value) -> Content
    @State private var value: Value?

    init(
        deck: MixEngine.Deck,
        read: @escaping (MixEngine.DeckState) -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.read = { read($0[deck.rawValue]) }
        self.content = content
    }

    init(
        read: @escaping ([MixEngine.DeckState]) -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.read = read
        self.content = content
    }

    var body: some View {
        content(value ?? read(MixEngine.shared.decks))
            .onReceive(MixEngine.shared.$decks.map(read).removeDuplicates()) { value = $0 }
    }
}

struct MacDeckPlayhead: Equatable {
    var position: TimeInterval
    var duration: TimeInterval
    var isPlaying: Bool

    init(_ state: MixEngine.DeckState) {
        position = state.position
        duration = state.duration
        isPlaying = state.isPlaying
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return (position / duration).clampedToUnit
    }
}

struct MacDeckLevels: Equatable {
    var level: Float
    var peak: Float

    init(_ state: MixEngine.DeckState) {
        level = state.level
        peak = state.peak
    }
}

struct MacEngineFader: View {
    let value: @MainActor @Sendable () -> Double
    let setValue: @MainActor @Sendable (Double) -> Void
    let publisher: AnyPublisher<Double, Never>
    var tint: Color = .scAccent
    var accessibilityLabel: String = "Fader"

    @State private var current: Double?

    var body: some View {
        MacHorizontalFader(
            value: Binding(get: { current ?? value() }, set: setValue),
            tint: tint,
            accessibilityLabel: accessibilityLabel
        )
        .onReceive(publisher) { current = $0 }
    }
}

struct MacKnob: View {
    let label: String
    @Binding var value: Double
    var bipolar = true
    var tint: Color = .scAccent
    var resetValue: Double?
    var diameter: CGFloat = 46
    var valueLabel: String?

    @State private var dragOrigin: Double?
    @Environment(\.colorSchemeContrast) private var contrast

    private let sweepDegrees: Double = 135

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(Color.white.opacity(0.07))
                Circle().strokeBorder(Color.white.opacity(contrast == .increased ? 0.5 : 0.22), lineWidth: 1)

                arc(from: fillStartDegrees, to: angleDegrees)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))

                Capsule()
                    .fill(.white.opacity(0.88))
                    .frame(width: 2, height: diameter * 0.30)
                    .offset(y: -diameter * 0.22)
                    .rotationEffect(.degrees(angleDegrees))
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(dragGesture)
            .onTapGesture(count: 2) {
                if let resetValue { value = resetValue }
            }
            .help("\(label): drag vertically · hold Option for fine adjustment · double-click to reset")

            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(contrast.macInk(0.5, increased: 0.85))
            if let valueLabel {
                Text(valueLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(contrast.macInk(0.45, increased: 0.85))
            }
        }
        .focusable()
        .onKeyPress(.upArrow) {
            value = (value + 0.05).clampedToUnit
            return .handled
        }
        .onKeyPress(.downArrow) {
            value = (value - 0.05).clampedToUnit
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueLabel ?? "\(Int(value.clampedToUnit * 100)) percent")
        .accessibilityHint("Use up and down arrows to adjust")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = (value + 0.05).clampedToUnit
            case .decrement: value = (value - 0.05).clampedToUnit
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset") {
            if let resetValue { value = resetValue }
        }
    }

    private var angleDegrees: Double { (value.clampedToUnit * 2 - 1) * sweepDegrees }
    private var fillStartDegrees: Double { bipolar ? 0 : -sweepDegrees }

    private func arc(from start: Double, to end: Double) -> Path {
        Path { path in
            path.addArc(
                center: CGPoint(x: diameter / 2, y: diameter / 2),
                radius: diameter / 2 - 3,
                startAngle: .degrees(min(start, end) - 90),
                endAngle: .degrees(max(start, end) - 90),
                clockwise: false
            )
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag in
                if dragOrigin == nil { dragOrigin = value }
                let fine = NSEvent.modifierFlags.contains(.option)
                let sensitivity: Double = fine ? 1300 : 130
                let delta = Double(-drag.translation.height) / sensitivity
                value = ((dragOrigin ?? value) + delta).clampedToUnit
            }
            .onEnded { _ in dragOrigin = nil }
    }
}

struct MacHorizontalFader: View {
    @Binding var value: Double
    var tint: Color = .scAccent
    var trackHeight: CGFloat = 6
    var knobDiameter: CGFloat = 20
    var accessibilityLabel: String = "Fader"
    var accessibilityValueText: String?

    @State private var fineOrigin: (value: Double, x: CGFloat)?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - knobDiameter)
            let knobX = width * value.clampedToUnit

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(contrast == .increased ? 0.3 : 0.14))
                    .frame(height: trackHeight)
                    .frame(maxWidth: .infinity)

                Circle()
                    .fill(tint)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : 0.6), lineWidth: 1))
                    .frame(width: knobDiameter, height: knobDiameter)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: knobX)
            }
            .frame(height: max(trackHeight, knobDiameter))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fine = NSEvent.modifierFlags.contains(.option)
                        if fine {
                            if fineOrigin == nil { fineOrigin = (value, drag.startLocation.x) }
                            guard let origin = fineOrigin else { return }
                            let delta = Double(drag.location.x - origin.x) / Double(width) * 0.1
                            value = (origin.value + delta).clampedToUnit
                        } else {
                            fineOrigin = nil
                            value = Double((drag.location.x - knobDiameter / 2) / width).clampedToUnit
                        }
                    }
                    .onEnded { _ in fineOrigin = nil }
            )
        }
        .frame(height: max(trackHeight, knobDiameter))
        .focusable()
        .onKeyPress(.upArrow) {
            value = (value + 0.05).clampedToUnit
            return .handled
        }
        .onKeyPress(.downArrow) {
            value = (value - 0.05).clampedToUnit
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValueText ?? "\(Int(value.clampedToUnit * 100)) percent")
        .accessibilityHint("Use up and down arrows to adjust")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = (value + 0.05).clampedToUnit
            case .decrement: value = (value - 0.05).clampedToUnit
            @unknown default: break
            }
        }
    }
}

struct MacJogWheel: View {
    let positionSeconds: TimeInterval
    let isPlaying: Bool
    let tint: Color
    var artwork: Image? = nil
    var identity: String = "Deck"
    var diameter: CGFloat = 84
    var secondsPerRevolution: Double = 10.8

    var body: some View {
        VinylPlatterView(
            size: diameter,
            position: positionSeconds,
            isPlaying: isPlaying,
            tint: tint,
            revolutionSeconds: secondsPerRevolution,
            labelFraction: 0.48
        ) {
            SCArtwork(image: artwork, identity: identity, style: .mac, cornerRadius: diameter * 0.26)
        }
    }
}

struct MacConsoleButton: View {
    var title: String? = nil
    var systemImage: String? = nil
    var accessibilityLabel: String? = nil
    var isActive = false
    var tint: Color = .white
    var isEnabled = true
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(title ?? "")
                }
            }
            .font(Font.subheadline.monospaced().weight(.bold))
            .foregroundStyle(isActive ? Color.black : Color.white.opacity(contrast == .increased ? 1 : 0.82))
            .frame(minWidth: 28, minHeight: 22)
            .padding(.horizontal, 7)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(isActive ? tint : Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(isActive ? tint : Color.white.opacity(contrast == .increased ? 0.5 : 0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel ?? title ?? "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

struct MacInlineShortcutHint: View {
    let keys: String
    var detail: String?

    init(_ keys: String, detail: String? = nil) {
        self.keys = keys
        self.detail = detail
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 3) {
            Text(keys)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(contrast.macInk(0.78, increased: 1))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(contrast == .increased ? 0.5 : 0.14), lineWidth: 0.75))
            if let detail {
                Text(detail)
                    .font(.caption2.monospaced().weight(.medium))
                    .foregroundStyle(contrast.macInk(0.5, increased: 0.85))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(keys): \($0)" } ?? keys)
    }
}

struct MacLevelMeter: View {
    let level: Float
    let peak: Float
    var tint: Color = .green
    var reduceMotion = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.10))
                Rectangle()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .bottom, endPoint: .top))
                    .frame(height: geo.size.height * CGFloat(min(1, max(0, reduceMotion ? peak : level))))
                Rectangle()
                    .fill(.white.opacity(0.8))
                    .frame(height: 1.5)
                    .offset(y: -geo.size.height * CGFloat(min(1, max(0, peak))))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .accessibilityHidden(true)
    }
}
