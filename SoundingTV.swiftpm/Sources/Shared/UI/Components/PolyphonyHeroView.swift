import SwiftUI

struct PolyphonyHeroView: View {
    var deviceClasses: [DeviceClass] = [.tv, .phone, .pad, .mac]
    var leaderClass: DeviceClass = .tv

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var ringScales: [CGFloat] = [0, 0, 0]
    @State private var ringOpacities: [Double] = [0, 0, 0]
    @State private var litSpeakers: Set<DeviceClass> = []
    @State private var loopTask: Task<Void, Never>?

    private var speakerClasses: [DeviceClass] {
        deviceClasses.filter { $0 != leaderClass }
    }

    private let accent = Color.scAccent
    private let accentOn = Color.scAccentOn

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                ripples(side: side)
                deviceLayout(side: side)
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private var accessibilityDescription: String {
        let count = speakerClasses.count
        let goodBoys = count == 1 ? "1 good boy" : "\(count) good boys"
        return "Animation of \(leaderClass.displayName) leading Polyphony, sending playback in sync to \(goodBoys)."
    }

    // MARK: - Layers

    @ViewBuilder
    private func ripples(side: CGFloat) -> some View {
        if !reduceMotion {
            ForEach(ringScales.indices, id: \.self) { index in
                Circle()
                    .stroke(accent, lineWidth: max(1, side * 0.012))
                    .frame(width: side * 0.32, height: side * 0.32)
                    .scaleEffect(ringScales[index])
                    .opacity(ringOpacities[index])
            }
            .accessibilityHidden(true)
        }
    }

    private func deviceLayout(side: CGFloat) -> some View {
        let radius = side * 0.36
        let leaderSize = side * 0.24
        let speakerSize = side * 0.155

        return ZStack {
            deviceGlyph(leaderClass, size: leaderSize, isLit: true)
                .overlay(alignment: .bottomTrailing) {
                    if !reduceMotion {
                        Image(systemName: "dot.radiowaves.forward")
                            .font(.system(size: side * 0.07, weight: .bold))
                            .foregroundStyle(accentOn)
                            .padding(side * 0.035)
                            .background(accent, in: Circle())
                            .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                            .offset(x: side * 0.03, y: side * 0.03)
                    }
                }

            ForEach(Array(speakerClasses.enumerated()), id: \.offset) { index, deviceClass in
                let angle = angle(for: index, count: speakerClasses.count)
                deviceGlyph(
                    deviceClass,
                    size: speakerSize,
                    isLit: reduceMotion || litSpeakers.contains(deviceClass)
                )
                .offset(x: cos(angle) * radius, y: sin(angle) * radius)
            }
        }
        .accessibilityHidden(true)
    }

    private func deviceGlyph(_ deviceClass: DeviceClass, size: CGFloat, isLit: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isLit ? accent : Color.white.opacity(0.12))
            Image(systemName: deviceClass.symbolName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(isLit ? accentOn : Color.white.opacity(0.6))
        }
        .frame(width: size, height: size)
        .shadow(color: isLit ? accent.opacity(0.5) : .clear, radius: size * 0.3)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: isLit)
    }

    private func angle(for index: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return -Double.pi / 2 + (2 * Double.pi / Double(count)) * Double(index)
    }

    // MARK: - Loop

    private func start() {
        guard loopTask == nil else { return }
        if reduceMotion {
            litSpeakers = Set(speakerClasses)
            return
        }
        loopTask = Task { await runLoop() }
    }

    private func stop() {
        loopTask?.cancel()
        loopTask = nil
        ringScales = [0, 0, 0]
        ringOpacities = [0, 0, 0]
        litSpeakers = []
    }

    private func runLoop() async {
        while !Task.isCancelled {
            litSpeakers = []
            for index in ringScales.indices {
                ringScales[index] = 0
                ringOpacities[index] = 0
            }

            guard await sleepBeat(0.35) else { return }

            for ring in ringScales.indices {
                emitRipple(ring)
                guard await sleepBeat(0.3) else { return }
            }

            guard await sleepBeat(0.4) else { return }

            for deviceClass in speakerClasses {
                guard await sleepBeat(0.18) else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    _ = litSpeakers.insert(deviceClass)
                }
            }

            guard await sleepBeat(1.2) else { return }

            withAnimation(.easeInOut(duration: 0.4)) { self.litSpeakers = [] }

            guard await sleepBeat(0.5) else { return }
        }
    }

    private func emitRipple(_ index: Int) {
        ringScales[index] = 0.15
        ringOpacities[index] = 0.85
        withAnimation(.easeOut(duration: 1.3)) {
            ringScales[index] = 1.7
            ringOpacities[index] = 0
        }
    }

    @discardableResult
    private func sleepBeat(_ seconds: Double) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return !Task.isCancelled
    }
}
