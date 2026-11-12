import SwiftUI

struct DeviceIllustration: View {
    enum Status: Equatable {
        case idle
        case working
        case done
    }

    let kind: DeviceClass
    var status: Status = .idle
    var size: CGFloat = 96

    static var cardSize: CGFloat {
        #if os(macOS)
        120
        #else
        DeviceClass.current == .pad ? 120 : 96
        #endif
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @State private var turn: Double = 0
    @State private var sweep: CGFloat = DeviceIllustration.sweepRest
    @State private var lit = false
    @State private var isOnScreen = false
    @State private var turning: Task<Void, Never>?

    private static let swing: Double = 12
    private static let sweepRest: CGFloat = -2.2
    private static let sweepEnd: CGFloat = 4.2

    private var turns: Bool { isOnScreen && !reduceMotion && status != .done && scenePhase == .active }
    private var pulses: Bool { isOnScreen && !reduceMotion && status == .working && scenePhase == .active }
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: size * 0.03) {
            device
                .overlay { sheen }
                .mask { device }
                .rotation3DEffect(.degrees(turn), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            Ellipse()
                .fill(Color.black.opacity(isDark ? 0.6 : 0.24))
                .frame(width: footprint, height: size * 0.07)
                .blur(radius: size * 0.035)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if status == .done {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.system(size: size * 0.24, weight: .semibold))
                    .background(Circle().fill(.background).padding(-2))
                    .offset(x: size * 0.04, y: -size * 0.08)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: status)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onChange(of: turns, initial: true) { _, on in
            if on { startTurning() } else { settle() }
        }
        .onChange(of: pulses, initial: true) { _, on in
            if on {
                lit = false
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
            } else {
                withAnimation(.easeOut(duration: 0.25)) { lit = false }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Motion

    private func startTurning() {
        turning?.cancel()
        turning = Task { @MainActor in
            withAnimation(.easeInOut(duration: 1.5)) { turn = -Self.swing }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { turn = Self.swing }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { sweep = Self.sweepRest }
            withAnimation(.linear(duration: 6.5).repeatForever(autoreverses: false)) { sweep = Self.sweepEnd }
        }
    }

    private func settle() {
        turning?.cancel()
        turning = nil
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { sweep = Self.sweepRest }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.7)) { turn = 0 }
    }

    private var lightLevel: Double {
        switch status {
        case .idle: return 0.25
        case .working: return pulses ? (lit ? 1 : 0.3) : 0.9
        case .done: return 0.9
        }
    }

    // MARK: - Drawing

    private var footprint: CGFloat {
        switch kind {
        case .tv: return size * 0.8
        case .phone: return size * 0.42
        case .pad: return size * 0.62
        case .mac: return size * 0.42
        case .watch: return size * 0.34
        }
    }

    @ViewBuilder
    private var device: some View {
        switch kind {
        case .tv:
            appleTV
        case .phone:
            slate(width: size * 0.44, height: size * 0.86, corner: size * 0.1, bezel: size * 0.022, island: true)
        case .pad:
            slate(width: size * 0.66, height: size * 0.86, corner: size * 0.07, bezel: size * 0.032, island: false)
        case .mac:
            mac
        case .watch:
            watch
        }
    }

    private var sheen: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            LinearGradient(
                colors: [.clear, .white.opacity(isDark ? 0.22 : 0.3), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width * 0.4, height: proxy.size.height * 1.8)
            .rotationEffect(.degrees(20))
            .frame(width: width, height: proxy.size.height)
            .offset(x: sweep * width * 0.5)
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    private var appleTV: some View {
        let width = size * 0.8
        let lid = width * 0.42
        let depth = width * 0.22
        return ZStack(alignment: .top) {
            SlabSilhouette(lidHeight: lid)
                .fill(LinearGradient(
                    colors: [Color(white: isDark ? 0.17 : 0.11), Color(white: isDark ? 0.06 : 0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            SquashedSquircle()
                .fill(LinearGradient(
                    colors: [Color(white: isDark ? 0.26 : 0.17), Color(white: isDark ? 0.1 : 0.05)],
                    startPoint: .bottom,
                    endPoint: .top
                ))
                .overlay {
                    SquashedSquircle()
                        .fill(RadialGradient(
                            colors: [.white.opacity(isDark ? 0.26 : 0.34), .clear],
                            center: UnitPoint(x: 0.32, y: 0.18),
                            startRadius: 0,
                            endRadius: width * 0.55
                        ))
                }
                .overlay {
                    SquashedSquircle()
                        .stroke(.white.opacity(isDark ? 0.3 : 0.16), lineWidth: 0.75)
                }
                .frame(width: width, height: lid)
            Capsule()
                .fill(Color.white)
                .frame(width: size * 0.045, height: size * 0.016)
                .shadow(color: .white.opacity(status == .working ? 0.9 : 0), radius: size * 0.03)
                .opacity(lightLevel)
                .offset(x: width * 0.24, y: lid + depth * 0.42)
        }
        .frame(width: width, height: lid + depth)
    }

    private var mac: some View {
        VStack(spacing: 0) {
            slate(width: size * 0.92, height: size * 0.58, corner: size * 0.035, bezel: size * 0.026, island: false)
            Rectangle()
                .fill(LinearGradient(colors: [metalDark, metalLight], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.18, height: size * 0.13)
            Capsule()
                .fill(metalLight)
                .frame(width: size * 0.36, height: size * 0.024)
        }
    }

    private var watch: some View {
        ZStack {
            VStack(spacing: size * 0.4) {
                RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
                    .fill(Color(white: isDark ? 0.3 : 0.22))
                    .frame(width: size * 0.32, height: size * 0.2)
                RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
                    .fill(Color(white: isDark ? 0.3 : 0.22))
                    .frame(width: size * 0.32, height: size * 0.2)
            }
            slate(width: size * 0.44, height: size * 0.54, corner: size * 0.13, bezel: size * 0.04, island: false)
                .overlay(alignment: .trailing) {
                    Capsule()
                        .fill(metalLight)
                        .frame(width: size * 0.03, height: size * 0.1)
                        .offset(x: size * 0.02, y: -size * 0.06)
                }
        }
    }

    private var metalLight: Color { Color(white: isDark ? 0.62 : 0.84) }
    private var metalDark: Color { Color(white: isDark ? 0.36 : 0.62) }

    private func slate(width: CGFloat, height: CGFloat, corner: CGFloat, bezel: CGFloat, island: Bool) -> some View {
        let outline = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let glass = RoundedRectangle(cornerRadius: max(1, corner - bezel), style: .continuous)
        return outline
            .fill(LinearGradient(colors: [metalLight, metalDark], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                glass
                    .fill(LinearGradient(
                        colors: [Color(white: 0.16), Color(white: 0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay {
                        glass.fill(RadialGradient(
                            colors: [.white.opacity(0.32), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: min(width, height) * 0.45
                        ))
                        .opacity(lightLevel)
                    }
                    .padding(bezel)
            }
            .overlay(alignment: .top) {
                if island {
                    Capsule()
                        .fill(.black)
                        .frame(width: width * 0.3, height: width * 0.075)
                        .padding(.top, bezel + width * 0.035)
                }
            }
            .overlay { outline.strokeBorder(.white.opacity(isDark ? 0.24 : 0.4), lineWidth: 0.75) }
            .frame(width: width, height: height)
    }
}

private struct SquashedSquircle: Shape {
    func path(in rect: CGRect) -> Path {
        let side = max(rect.width, 1)
        let square = RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
            .path(in: CGRect(x: 0, y: 0, width: side, height: side))
        return square.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: rect.height / side, tx: rect.minX, ty: rect.minY))
    }
}

private struct SlabSilhouette: Shape {
    var lidHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let lid = SquashedSquircle().path(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: lidHeight))
        let base = SquashedSquircle().path(in: CGRect(x: rect.minX, y: rect.maxY - lidHeight, width: rect.width, height: lidHeight))
        let band = Path(CGRect(x: rect.minX, y: rect.minY + lidHeight / 2, width: rect.width, height: max(0, rect.height - lidHeight)))
        return base.union(band).union(lid)
    }
}

// MARK: - Nearby list

extension LinkOfferBrowser.Offer {
    @MainActor
    var nearbyStatus: String {
        if accountHint?.isLinked(toDeviceId: LinkPeerIdentity.localDeviceId()) == true { return "Linked" }
        if isOtherAccount { return TVAccountCopy.anotherAccountStatus }
        return isSignedIn ? "Signed in" : "Ready to sign in"
    }

    @MainActor
    var isOtherAccount: Bool {
        guard let accountHint, let accountId = SameAccountLinkModel.accountId else { return false }
        return !accountHint.matches(accountId: accountId)
    }
}

struct NearbySearchHeader: View {
    var kind: DeviceClass = .tv
    var guidance: String?

    var body: some View {
        VStack(spacing: 8) {
            DeviceIllustration(kind: kind, status: .working, size: 84)
            Text("Looking for \(kind.displayName)s nearby…")
                .font(.headline)
                .multilineTextAlignment(.center)
            if let guidance {
                Text(guidance)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct NearbyDeviceRow: View {
    let offer: LinkOfferBrowser.Offer
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: offer.kind.symbolName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.claimedName)
                        .foregroundStyle(.primary)
                    Text(offer.nearbyStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel("\(offer.claimedName), \(offer.nearbyStatus)")
        .accessibilityHint("Links it with a code")
    }
}
