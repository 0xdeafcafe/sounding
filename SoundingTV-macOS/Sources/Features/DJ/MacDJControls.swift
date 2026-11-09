import SwiftUI

enum MacDJPalette {
    static let deckA = Color(red: 0.353, green: 0.663, blue: 1.0)
    static let deckB = Color(red: 0.824, green: 0.714, blue: 1.0)
    static let auto = Color(red: 0.427, green: 0.800, blue: 0.702)
    static let yours = Color(red: 1.0, green: 0.839, blue: 0.039)
    static let onAir = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let play = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let well = Color(red: 0.016, green: 0.016, blue: 0.020)
    static let chassis = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let panel = Color(red: 0.071, green: 0.071, blue: 0.078)
    static let leavingLabel = Color(red: 0.749, green: 0.855, blue: 1.0)
    static let enteringLabel = Color(red: 0.886, green: 0.824, blue: 1.0)

    static func deck(_ deck: MixEngine.Deck) -> Color { deck == .a ? deckA : deckB }

    enum Cue {
        static let green = Color(red: 0.188, green: 0.820, blue: 0.345)
        static let pink = Color(red: 1.0, green: 0.478, blue: 0.776)
        static let red = Color(red: 1.0, green: 0.271, blue: 0.227)
        static let purple = Color(red: 0.749, green: 0.353, blue: 0.949)
        static let cyan = Color(red: 0.392, green: 0.824, blue: 1.0)
        static let blue = Color(red: 0.039, green: 0.518, blue: 1.0)
        static let grey = Color(red: 0.557, green: 0.557, blue: 0.576)

        static let byIndex: [Color] = [green, pink, red, purple, red, cyan, mint, blue]
        static let mint = Color(red: 0.400, green: 0.831, blue: 0.812)
    }
}

extension ColorSchemeContrast {
    func djInk(_ standard: Double) -> Color {
        .white.opacity(self == .increased ? max(0.85, standard) : standard)
    }
}

struct MacDJDeckBadge: View {
    let deck: MixEngine.Deck
    var size: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Text(deck.label)
            .font(.system(size: size * 0.6, weight: .heavy))
            .frame(width: size, height: size)
            .foregroundStyle(deck == .a ? Color(red: 0, green: 0.1, blue: 0.2) : MacDJPalette.deckB)
            .background {
                if deck == .a {
                    shape.fill(MacDJPalette.deckA)
                } else {
                    MacDJHatch(color: MacDJPalette.deckB.opacity(0.18), spacing: 4).clipShape(shape)
                        .overlay(shape.strokeBorder(MacDJPalette.deckB, lineWidth: max(1.5, size / 12)))
                }
            }
            .accessibilityLabel("Deck \(deck.label)")
    }
}

struct MacDJHatch: View {
    var color: Color
    var spacing: CGFloat = 10
    var lineWidth: CGFloat?

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(color), lineWidth: lineWidth ?? spacing / 2)
        }
        .accessibilityHidden(true)
    }
}

struct MacDJChip: View {
    enum Kind {
        case onAir
        case mixingIn
        case autoMixOnly
        case freeRunning
        case custom(String, Color, Color)
    }

    let kind: Kind

    var body: some View {
        HStack(spacing: 5) {
            switch kind {
            case .onAir:
                Circle().fill(MacDJPalette.onAir).frame(width: 6, height: 6)
                Text("On Air")
            case .mixingIn:
                Circle().fill(MacDJPalette.auto).frame(width: 6, height: 6)
                Text("Mixing In")
            case .autoMixOnly:
                Image(systemName: "cloud")
                Text("Auto Mix only")
            case .freeRunning:
                Text("Free-running")
            case .custom(let text, _, _):
                Text(text)
            }
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .frame(height: 19)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(background))
        .lineLimit(1)
        .fixedSize()
    }

    private var foreground: Color {
        switch kind {
        case .onAir: return Color(red: 1, green: 0.61, blue: 0.57)
        case .mixingIn: return MacDJPalette.auto
        case .autoMixOnly, .freeRunning: return .white.opacity(0.85)
        case .custom(_, let fg, _): return fg
        }
    }

    private var background: Color {
        switch kind {
        case .onAir: return MacDJPalette.onAir.opacity(0.16)
        case .mixingIn: return MacDJPalette.auto.opacity(0.16)
        case .autoMixOnly, .freeRunning: return .white.opacity(0.1)
        case .custom(_, _, let bg): return bg
        }
    }
}

struct MacDJControlButtonStyle: ButtonStyle {
    var isOn = false
    var tint: Color?
    var height: CGFloat = 24
    var shape: Shape = .capsule

    enum Shape {
        case capsule
        case circle
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint ?? .white.opacity(0.92))
            .padding(.horizontal, shape == .circle ? 0 : 9)
            .frame(minWidth: shape == .circle ? height : nil, minHeight: height, maxHeight: height)
            .background(background(pressed: configuration.isPressed))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(shapeView)
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        let fill: Color = {
            if let tint, isOn { return tint.opacity(0.22) }
            return .white.opacity(isOn ? 0.24 : (pressed ? 0.16 : 0.08))
        }()
        let stroke: Color = {
            if let tint, isOn { return tint.opacity(0.6) }
            return .white.opacity(contrast == .increased ? 0.5 : (isOn ? 0.3 : 0.14))
        }()
        switch shape {
        case .capsule:
            Capsule().fill(fill).overlay(Capsule().strokeBorder(stroke, lineWidth: 0.5))
        case .circle:
            Circle().fill(fill).overlay(Circle().strokeBorder(stroke, lineWidth: 0.5))
        }
    }

    private var shapeView: AnyShape {
        shape == .circle ? AnyShape(Circle()) : AnyShape(Capsule())
    }
}

struct MacDJSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var height: CGFloat = 20
    var spacing: CGFloat = 10

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, spacing)
                        .frame(height: height)
                        .background {
                            if selection == option.0 {
                                Capsule().fill(.white.opacity(0.24)).overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.92))
                .accessibilityAddTraits(selection == option.0 ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.06)))
    }
}

struct MacDJYoursChip: View {
    let valueText: String
    let onHandBack: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(valueText)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(MacDJPalette.yours)
            Button(action: onHandBack) {
                Label("Hand Back", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .background(Capsule().fill(MacDJPalette.yours))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .frame(height: 25)
        .background(Capsule().fill(Color(red: 0.19, green: 0.165, blue: 0.024).opacity(0.97)))
        .overlay(Capsule().strokeBorder(MacDJPalette.yours.opacity(0.55), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Yours, \(valueText)")
    }
}

struct MacDJKnob: View {
    let value: Double
    var target: Double?
    var isYours = false
    var isDisabled = false
    var size: CGFloat = 32
    var bipolar = true
    var onGrab: () -> Void = {}
    var onChange: (Double) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}

    @State private var dragStart: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sweep = 300.0
    private static let start = -150.0

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: Self.sweep / 360)
                .rotation(.degrees(90 + (360 - Self.sweep) / 2))
                .stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            if let target, !isYours, !isDisabled {
                let lo = min(value, target), hi = max(value, target)
                Circle()
                    .trim(from: lo * Self.sweep / 360, to: hi * Self.sweep / 360)
                    .rotation(.degrees(90 + (360 - Self.sweep) / 2))
                    .stroke(MacDJPalette.auto, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 3]))
                Circle()
                    .fill(MacDJPalette.auto)
                    .frame(width: 5, height: 5)
                    .offset(y: -size / 2)
                    .rotationEffect(.degrees(Self.start + target * Self.sweep))
            }
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.2), Color(white: 0.08)], center: UnitPoint(x: 0.45, y: 0.35), startRadius: 0, endRadius: size * 0.6))
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.6))
                .padding(size * 0.16)
            Capsule()
                .fill(isYours ? MacDJPalette.yours : .white)
                .frame(width: 2.5, height: size * 0.22)
                .offset(y: -size * 0.2)
                .rotationEffect(.degrees(Self.start + value * Self.sweep))
            if isYours {
                Circle().strokeBorder(MacDJPalette.yours, lineWidth: 2).padding(-4)
            }
        }
        .frame(width: size, height: size)
        .opacity(isDisabled ? 0.4 : 1)
        .contentShape(Circle())
        .gesture(isDisabled ? nil : drag)
        .onTapGesture(count: 2) { if !isDisabled { onGrab(); onDoubleClick() } }
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard !isDisabled else { return }
            onGrab()
            onChange(min(1, max(0, value + (direction == .increment ? 0.05 : -0.05))))
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if dragStart == nil {
                    dragStart = value
                    onGrab()
                }
                let delta = Double(-gesture.translation.height + gesture.translation.width) / 160
                onChange(min(1, max(0, (dragStart ?? value) + delta)))
            }
            .onEnded { _ in dragStart = nil }
    }
}

struct MacDJVerticalFader: View {
    let value: Double
    var target: Double?
    var isYours = false
    var isDisabled = false
    var height: CGFloat = 76
    var centreDetent = false
    var onGrab: () -> Void = {}
    var onChange: (Double) -> Void = { _ in }

    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            let w = proxy.size.width
            let capY = (1 - value) * h
            ZStack(alignment: .topLeading) {
                ForEach(0..<9, id: \.self) { k in
                    Rectangle()
                        .fill(.white.opacity(k % 4 == 0 ? 0.28 : 0.14))
                        .frame(width: k % 4 == 0 ? w * 0.66 : w * 0.5, height: 0.5)
                        .offset(x: k % 4 == 0 ? w * 0.17 : w * 0.25, y: CGFloat(k) / 8 * h)
                }
                if centreDetent {
                    Rectangle().fill(.white.opacity(0.5)).frame(width: w * 0.5, height: 0.5).offset(x: w * 0.25, y: h / 2)
                }
                Capsule().fill(.white.opacity(0.12)).frame(width: 4, height: h).offset(x: w / 2 - 2)
                if let target, !isYours, !isDisabled {
                    let ty = (1 - target) * h
                    Path { path in
                        path.move(to: CGPoint(x: w / 2, y: ty))
                        path.addLine(to: CGPoint(x: w / 2, y: capY))
                    }
                    .stroke(MacDJPalette.auto, style: StrokeStyle(lineWidth: 2, dash: [2, 2]))
                    Capsule().fill(MacDJPalette.auto).frame(width: w * 0.78, height: 2).offset(x: w * 0.11, y: ty - 1)
                }
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.18)], startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .center) {
                        Rectangle().fill(isYours ? MacDJPalette.yours : .white.opacity(0.85)).frame(height: 1).padding(.horizontal, 4)
                    }
                    .overlay {
                        if isYours {
                            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(MacDJPalette.yours, lineWidth: 1.5)
                        }
                    }
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                    .frame(width: w * 0.9, height: 18)
                    .offset(x: w * 0.05, y: capY - 9)
            }
            .contentShape(Rectangle())
            .gesture(isDisabled ? nil : DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if dragStart == nil {
                        dragStart = value
                        onGrab()
                    }
                    onChange(min(1, max(0, (dragStart ?? value) - Double(gesture.translation.height / h))))
                }
                .onEnded { _ in dragStart = nil })
        }
        .frame(height: height)
        .opacity(isDisabled ? 0.4 : 1)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard !isDisabled else { return }
            onGrab()
            onChange(min(1, max(0, value + (direction == .increment ? 0.05 : -0.05))))
        }
    }
}

struct MacDJCrossfader: View {
    let value: Double
    var target: Double?
    var isYours = false
    var onGrab: () -> Void = {}
    var onChange: (Double) -> Void = { _ in }

    @State private var dragStart: Double?

    var body: some View {
        HStack(spacing: 6) {
            MacDJDeckBadge(deck: .a, size: 16)
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12)).frame(height: 4)
                    Rectangle().fill(.white.opacity(0.45)).frame(width: 0.5, height: 22).offset(x: w / 2)
                    if let target, !isYours {
                        let lo = min(value, target) * w, hi = max(value, target) * w
                        Path { path in
                            path.move(to: CGPoint(x: lo, y: h / 2))
                            path.addLine(to: CGPoint(x: hi, y: h / 2))
                        }
                        .stroke(MacDJPalette.auto, style: StrokeStyle(lineWidth: 2, dash: [2, 2]))
                        Capsule().fill(MacDJPalette.auto).frame(width: 2, height: 24).offset(x: target * w - 1)
                    }
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.33), Color(white: 0.18)], startPoint: .leading, endPoint: .trailing))
                        .overlay { Rectangle().fill(isYours ? MacDJPalette.yours : .white).frame(width: 1).padding(.vertical, 4) }
                        .overlay {
                            if isYours { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(MacDJPalette.yours, lineWidth: 1.5) }
                        }
                        .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                        .frame(width: 18, height: 30)
                        .offset(x: value * w - 9)
                }
                .frame(height: h)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStart == nil {
                            dragStart = value
                            onGrab()
                        }
                        onChange(min(1, max(0, (dragStart ?? value) + Double(gesture.translation.width / w))))
                    }
                    .onEnded { _ in dragStart = nil })
            }
            .frame(height: 30)
            MacDJDeckBadge(deck: .b, size: 16)
        }
        .accessibilityElement()
        .accessibilityLabel("Crossfader")
        .accessibilityValue("\(Int((value * 100).rounded())) percent toward B")
        .accessibilityAdjustableAction { direction in
            onGrab()
            onChange(min(1, max(0, value + (direction == .increment ? 0.05 : -0.05))))
        }
    }
}

struct MacDJLevelMeter: View {
    let level: Double
    var peak: Double = 0
    var segments = 16

    var body: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            let cell = h / CGFloat(segments)
            ZStack(alignment: .bottom) {
                VStack(spacing: 1.4) {
                    ForEach((0..<segments).reversed(), id: \.self) { i in
                        let t = Double(i) / Double(segments)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(t < level ? (t > 0.86 ? Color(red: 1, green: 0.42, blue: 0.35) : MacDJPalette.play) : .white.opacity(0.08))
                    }
                }
                Rectangle().fill(.white).frame(height: 1.5).padding(.horizontal, -1).offset(y: -CGFloat(peak) * h + cell / 2)
            }
        }
        .frame(width: 5)
        .accessibilityHidden(true)
    }
}
