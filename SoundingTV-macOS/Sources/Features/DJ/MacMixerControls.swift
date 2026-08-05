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
    var tint: Color = .accentColor

    @State private var current: Double?

    var body: some View {
        MacHorizontalFader(
            value: Binding(get: { current ?? value() }, set: setValue),
            tint: tint
        )
        .onReceive(publisher) { current = $0 }
    }
}

struct MacKnob: View {
    let label: String
    @Binding var value: Double   // 0...1
    var bipolar = true
    var tint: Color = .accentColor
    var resetValue: Double?
    var diameter: CGFloat = 46
    var valueLabel: String?

    @State private var dragOrigin: Double?

    private let sweepDegrees: Double = 135

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(Color.white.opacity(0.07))
                Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)

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
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            if let valueLabel {
                Text(valueLabel)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
            }
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
    @Binding var value: Double   // 0...1
    var tint: Color = .accentColor
    var trackHeight: CGFloat = 6
    var knobDiameter: CGFloat = 20

    @State private var fineOrigin: (value: Double, x: CGFloat)?

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - knobDiameter)
            let knobX = width * value.clampedToUnit

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: trackHeight)
                    .frame(maxWidth: .infinity)

                Circle()
                    .fill(tint)
                    .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
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
    }
}

enum MacDeckUnits {
    static func eqDecibels(fromKnob knob: Double) -> Double {
        knob <= 0.5 ? -60 + (knob / 0.5) * 60 : (knob - 0.5) / 0.5 * 12
    }

    static func eqKnob(fromDecibels decibels: Double) -> Double {
        decibels <= 0 ? (decibels + 60) / 60 * 0.5 : 0.5 + (decibels / 12) * 0.5
    }

    static func filterHertz(fromKnob knob: Double) -> Double {
        let lo = log(MixEngine.filterCutoffRange.lowerBound)
        let hi = log(MixEngine.filterCutoffRange.upperBound)
        return exp(lo + knob.clampedToUnit * (hi - lo))
    }

    static func filterKnob(fromHertz hertz: Double) -> Double {
        let lo = log(MixEngine.filterCutoffRange.lowerBound)
        let hi = log(MixEngine.filterCutoffRange.upperBound)
        return ((log(max(hertz, 1)) - lo) / (hi - lo)).clampedToUnit
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

    private var angleDegrees: Double {
        guard secondsPerRevolution > 0 else { return 0 }
        let wrapped = positionSeconds.truncatingRemainder(dividingBy: secondsPerRevolution)
        return (wrapped / secondsPerRevolution) * 360
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.15), Color(white: 0.04)], center: .center, startRadius: 0, endRadius: diameter / 2))

            ForEach(1..<4, id: \.self) { ring in
                Circle()
                    .strokeBorder(.white.opacity(0.05), lineWidth: 1)
                    .padding(diameter * 0.09 * CGFloat(ring))
            }

            Circle()
                .strokeBorder(tint.opacity(isPlaying ? 0.85 : 0.28), lineWidth: 2)

            Rectangle()
                .fill(tint.opacity(isPlaying ? 1 : 0.4))
                .frame(width: 2.5, height: diameter * 0.40)
                .offset(y: -diameter * 0.20)
                .rotationEffect(.degrees(angleDegrees))

            SCArtwork(image: artwork, identity: identity, style: .mac, cornerRadius: diameter * 0.26)
                .frame(width: diameter * 0.52, height: diameter * 0.52)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 0.75))
                .rotationEffect(.degrees(angleDegrees))

            Circle()
                .fill(.white.opacity(0.92))
                .frame(width: 5, height: 5)
        }
        .frame(width: diameter, height: diameter)
    }
}

struct MacConsoleButton: View {
    var title: String? = nil
    var systemImage: String? = nil
    var isActive = false
    var tint: Color = .white
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(title ?? "")
                }
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.82))
            .frame(minWidth: 28, minHeight: 22)
            .padding(.horizontal, 7)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(isActive ? tint : Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(isActive ? tint : Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
    }
}

struct MacInlineShortcutHint: View {
    let keys: String
    var detail: String?

    init(_ keys: String, detail: String? = nil) {
        self.keys = keys
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(keys)
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
            if let detail {
                Text(detail)
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
    }
}

struct MacLevelMeter: View {
    let level: Float
    let peak: Float
    var tint: Color = .green

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.10))
                Rectangle()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .bottom, endPoint: .top))
                    .frame(height: geo.size.height * CGFloat(min(1, max(0, level))))
                Rectangle()
                    .fill(.white.opacity(0.8))
                    .frame(height: 1.5)
                    .offset(y: -geo.size.height * CGFloat(min(1, max(0, peak))))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}
