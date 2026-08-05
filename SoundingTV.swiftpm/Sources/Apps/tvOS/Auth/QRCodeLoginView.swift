import SwiftUI
import Foundation

struct QRCodeLoginView: View {
    enum Purpose {
        case signIn
        case companion
    }

    var onClose: (() -> Void)?
    var purpose: Purpose = .signIn

    @EnvironmentObject var authService: AuthenticationService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var bonjourServer = LinkServer()
    @State private var timeRemaining: Int = Int(BonjourConstants.sessionTimeout)
    @State private var timerTask: Task<Void, Never>?
    @State private var completionTask: Task<Void, Never>?
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case close, action
    }

    private var state: LinkServer.State {
        Self.debugForcedState ?? bonjourServer.state
    }

    private static let debugForcedState: LinkServer.State? = {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_PAIRING_FAULT"] {
        case "cannotListen":
            return .failed(.cannotListen("Network.NWError error -65569 - DefunctConnection"))
        case "cannotGenerateSession":
            return .failed(.cannotGenerateSession)
        case "localNetworkDenied":
            return .failed(.localNetworkDenied)
        case "connectionLost":
            return .failed(.connectionLost("Connection reset by peer"))
        case "rejected":
            return .failed(.rejected("signature mismatch"))
        default:
            return nil
        }
        #else
        return nil
        #endif
    }()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                header

                Spacer().frame(height: Space.section)

                if state == .completed {
                    SuccessBeat(focused: $focus, tag: Focus.action, reduceMotion: reduceMotion) {
                        advance()
                    }
                    .accessibilityIdentifier("login.success.continue")
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                } else {
                    HStack(alignment: .center, spacing: Space.section + Space.snug) {
                        CodePlate(
                            state: state,
                            credentials: bonjourServer.credentials,
                            fractionRemaining: fractionRemaining,
                            reduceMotion: reduceMotion
                        )

                        GuidancePanel(state: state, numericComparisonCode: bonjourServer.numericComparisonCode)
                            .frame(width: 720, alignment: .leading)
                    }

                    Spacer().frame(height: Space.roomy)

                    LinkStatusPill(state: state, timeRemaining: timeRemaining)

                    Spacer().frame(height: Space.roomy)

                    RecoveryButton(
                        title: showRetry ? "Try Again" : "Get a New Code",
                        isPrimary: showRetry,
                        focused: $focus,
                        tag: Focus.action,
                        reduceMotion: reduceMotion
                    ) { startSession() }
                    .accessibilityIdentifier("login.recovery")
                }

                Spacer().frame(height: Space.section)

                if state != .completed {
                    HStack(spacing: Space.tight + 2) {
                        Image(systemName: "lock.fill")
                        Text("Signed and sent directly over your Wi-Fi")
                    }
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextTertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Space.page)
            .scMotion(Motion.settle, reduceMotion: reduceMotion, value: state)

            if let onClose {
                CloseButton(
                    focused: $focus,
                    tag: Focus.close,
                    reduceMotion: reduceMotion,
                    action: onClose
                )
                .accessibilityIdentifier("login.close")
                .padding(.trailing, Space.page)
                .padding(.top, Space.section)
            }
        }
        .background(LinkBackdrop(state: state).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onExitCommand { onClose?() }
        .defaultFocus($focus, .action)
        .onAppear { startSession() }
        .onDisappear { stopSession() }
        .onChange(of: state) { _, newState in
            if newState == .timeout, LinkServer.debugStateOverride == nil {
                startSession()
            }
        }
        .onChange(of: showRetry) { _, retryAvailable in
            if retryAvailable { focus = .action }
        }
        .onChange(of: state == .completed) { _, completed in
            if completed { focus = .action }
        }
        .userActivity(HandoffActivityType.link, isActive: isPairingHandoffActive) { activity in
            configurePairingActivity(activity)
        }
    }

    private var header: some View {
        VStack(spacing: Space.snug) {
            Text(title)
                .font(.tvLargeTitle)
                .tracking(-0.8)
                .foregroundStyle(Color.scTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(subtitle)
                .font(.tvBody)
                .foregroundStyle(Color.scTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
        }
    }

    private var title: String {
        if purpose == .companion {
            return state == .completed ? "Companion Connected" : "Pair a Companion"
        }
        switch state {
        case .completed:
            return "You're signed in"
        case .failed(let fault) where !fault.codeIsStillLive:
            return "Can't start link"
        default:
            return "Sign in with iPhone"
        }
    }

    private var subtitle: String {
        if purpose == .companion {
            if state == .completed { return "Your iPhone can now control this Apple TV." }
            return "Scan with SoundingCloud on iPhone, then compare the six-digit code on both screens."
        }
        switch state {
        case .completed:
            return "Enjoy your music."
        case .connected, .receivingToken:
            return "Hold tight. Finishing up on your iPhone."
        case .failed(let fault) where !fault.codeIsStillLive:
            return "Nothing is listening for your iPhone yet, so there's no code to scan."
        default:
            return "Two ways in. Take whichever your iPhone offers first."
        }
    }

    private var isPairingHandoffActive: Bool {
        guard bonjourServer.credentials != nil else { return false }
        switch state {
        case .idle, .advertising, .connected, .receivingToken:
            return true
        case .completed, .timeout:
            return false
        case .failed(let fault):
            return fault.codeIsStillLive
        }
    }

    private func configurePairingActivity(_ activity: NSUserActivity) {
        guard let credentials = bonjourServer.credentials else { return }
        activity.title = "Sign in to SoundingCloud"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.userInfo = ["pairingURL": QRCodeGenerator.buildPairingURL(for: credentials)]
        activity.requiredUserInfoKeys = ["pairingURL"]
    }

    private var showRetry: Bool {
        if case .failed = state { return true }
        return state == .timeout
    }

    private var fractionRemaining: Double {
        guard BonjourConstants.sessionTimeout > 0 else { return 0 }
        return min(1, max(0, Double(timeRemaining) / BonjourConstants.sessionTimeout))
    }

    private func startSession() {
        timeRemaining = Int(BonjourConstants.sessionTimeout)
        bonjourServer.onTokenReceived = { token, refreshToken, clientId, expiry in
            completionTask = Task {
                await authService.authenticate(
                    token: token,
                    refreshToken: refreshToken,
                    clientId: clientId,
                    expiry: expiry,
                    presentationDelay: .seconds(1.5)
                )
                onClose?()
            }
        }
        bonjourServer.start()
        startTimer()
    }

    private func stopSession() {
        timerTask?.cancel()
        timerTask = nil
        completionTask?.cancel()
        completionTask = nil
        bonjourServer.stop()
    }

    private func advance() {
        completionTask?.cancel()
        completionTask = nil
        onClose?()
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled && timeRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { timeRemaining -= 1 }
            }
        }
    }
}

private struct GuidancePanel: View {
    let state: LinkServer.State
    let numericComparisonCode: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
            switch state {
            case .failed(let fault) where !fault.codeIsStillLive:
                FaultGuidance(fault: fault)

            case .completed:
                EmptyView()

            default:
                if let numericComparisonCode {
                    // Numeric confirmation is the active security decision.
                    // The server changes to `.receivingToken` while the phone
                    // is still showing its code, so it must not be hidden by
                    // the generic transfer guidance below.
                    NumericComparisonGuidance(code: numericComparisonCode)
                } else if case .connected = state {
                    Route(
                        icon: "iphone.gen3.radiowaves.left.and.right",
                        title: "Finish on the other device",
                        detail: "Complete the secure sign-in there. This device is waiting."
                    )
                } else if case .receivingToken = state {
                    Route(
                        icon: "iphone.gen3.radiowaves.left.and.right",
                        title: "Finish on the other device",
                        detail: "Complete the secure sign-in there. This device is waiting."
                    )
                } else {
                    Route(
                        icon: "camera.viewfinder",
                        title: "Scan the code",
                        detail: "Open Camera on your iPhone and hold it up to the code. Tap the link that appears."
                    )

                    OrDivider()

                    Route(
                        icon: "square.on.square",
                        title: "Or skip the camera",
                        detail: "Already have SoundingCloud on your iPhone? Open the App Switcher and tap the SoundingCloud banner along the bottom."
                    )

                    if case .failed(let fault) = state, let detail = faultLine(fault) {
                        Text(detail)
                            .font(.tvCaption)
                            .foregroundStyle(Color.scTextTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func faultLine(_ fault: LinkServer.Fault) -> String? {
        switch fault {
        case .connectionLost:
            return "An iPhone reached this Apple TV and then dropped off. The code is still good, try it again."
        case .rejected(let detail):
            return "The last attempt was refused (\(detail)). The code is still good, try it again."
        case .validationUnavailable:
            return "This Apple TV couldn't reach SoundCloud to check the sign-in. Check its internet connection. The code is still good."
        case .cannotListen, .localNetworkDenied, .cannotGenerateSession:
            return nil
        }
    }
}

private struct NumericComparisonGuidance: View {
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            Label("A nearby device wants to pair", systemImage: "link")
                .font(.tvHeadline)
                .foregroundStyle(Color.scTextPrimary)

            Text("Confirm this matches the code on the other device:")
                .font(.tvBody)
                .foregroundStyle(Color.scTextSecondary)

            HStack(spacing: Space.snug) {
                ForEach(Array(codeGroups.enumerated()), id: \.offset) { _, group in
                    Text(group)
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .tracking(7)
                        .monospacedDigit()
                        .foregroundStyle(Color.scTextPrimary)
                        .frame(width: 220)
                        .padding(.vertical, Space.snug)
                        .background(
                            RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                                .fill(Color.scBgRaised)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                                .stroke(Color.scAccent.opacity(0.42), lineWidth: 2)
                        }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pairing code \(codeGroups.joined(separator: ", "))")

            Text("If it doesn't match, someone else on this Wi-Fi network may be trying to sign in.")
                .font(.tvCaption)
                .foregroundStyle(Color.scTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var codeGroups: [String] {
        let digits = code.filter { $0.isNumber }
        guard digits.count == 6 else { return [code] }
        let midpoint = digits.index(digits.startIndex, offsetBy: 3)
        return [String(digits[..<midpoint]), String(digits[midpoint...])]
    }
}

private struct FaultGuidance: View {
    let fault: LinkServer.Fault

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            Label(headline, systemImage: "exclamationmark.triangle.fill")
                .font(.tvHeadline)
                .foregroundStyle(Color.scDestructive)
                .fixedSize(horizontal: false, vertical: true)

            Text(instruction)
                .font(.tvBody)
                .foregroundStyle(Color.scTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = fault.detail {
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text("Technical details")
                        .font(.tvCaptionEmph)
                    Text(detail)
                        .font(.tvCaption.monospaced())
                }
                .foregroundStyle(Color.scTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: String {
        switch fault {
        case .cannotListen:          return "This Apple TV isn't visible"
        case .localNetworkDenied:    return "Local Network access is off"
        case .cannotGenerateSession: return "Couldn't create a secure session"
        case .connectionLost:        return "Your iPhone dropped off"
        case .rejected:              return "That sign-in was refused"
        case .validationUnavailable: return "SoundCloud couldn't be reached"
        }
    }

    private var instruction: String {
        switch fault {
        case .cannotListen:
            return "SoundingCloud couldn't announce this Apple TV on your Wi-Fi network, so your iPhone has nothing to find. Open Settings › Apps › SoundingCloud here, turn Local Network on, then press Try Again."
        case .localNetworkDenied:
            return "Open Settings › Apps › SoundingCloud on this Apple TV, turn Local Network on, then return here and press Try Again."
        case .cannotGenerateSession:
            return "This Apple TV couldn't generate a link key, so there's no code. Press Try Again. If it keeps happening, restart SoundingCloud."
        case .connectionLost:
            return "The connection closed before sign-in finished. Press Try Again for a fresh code."
        case .rejected:
            return "Press Try Again for a fresh code, then sign in on your iPhone once more."
        case .validationUnavailable:
            return "Check this Apple TV's internet connection, then press Try Again."
        }
    }
}

private struct Route: View {
    let icon: String
    let title: String
    let detail: String
    var tint: Color = .scAccent

    var body: some View {
        HStack(alignment: .top, spacing: Space.base) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 52, alignment: .center)

            VStack(alignment: .leading, spacing: Space.tight) {
                Text(title)
                    .font(.tvSubheadline)
                    .foregroundStyle(Color.scTextPrimary)
                Text(detail)
                    .font(.tvBody)
                    .foregroundStyle(Color.scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OrDivider: View {
    var body: some View {
        HStack(spacing: Space.snug) {
            line
            Text("or")
                .font(.tvCaptionEmph)
                .foregroundStyle(Color.scTextTertiary)
            line
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color.scSeparator)
            .frame(height: 1)
    }
}

private struct LinkBackdrop: View {
    let state: LinkServer.State

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift: CGFloat = 0

    private var energy: Double {
        switch state {
        case .idle, .advertising:         return 0.72
        case .connected, .receivingToken: return 1.0
        case .completed:                  return 1.0
        case .timeout:                    return 0.45
        case .failed(let fault):          return fault.codeIsStillLive ? 0.6 : 0.32
        }
    }

    private var bloom: Color {
        switch state {
        case .completed:
            return .scSuccess
        case .failed(let fault) where !fault.codeIsStillLive:
            return .scDestructive
        default:
            return .scAccent
        }
    }

    private var bloomCentre: CGFloat { 0.32 }

    var body: some View {
        ZStack {
            Color(red: 0.027, green: 0.027, blue: 0.043)

            RadialGradient(
                colors: [bloom.opacity(0.26 * energy), .clear],
                center: UnitPoint(x: bloomCentre, y: 0.50 + drift * 0.015),
                startRadius: 0,
                endRadius: 1050
            )

            RadialGradient(
                colors: [bloom.opacity(0.13 * energy), .clear],
                center: UnitPoint(x: bloomCentre, y: 0.50),
                startRadius: 0,
                endRadius: 520
            )

            RadialGradient(
                colors: [Color(red: 0.24, green: 0.16, blue: 0.52).opacity(0.40), .clear],
                center: UnitPoint(x: 1.02, y: 1.04 - drift * 0.02),
                startRadius: 0,
                endRadius: 950
            )

            RadialGradient(
                colors: [.clear, .black.opacity(0.55)],
                center: .center,
                startRadius: 520,
                endRadius: 1320
            )
        }
        .animation(Motion.ambient, value: energy)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) {
                drift = 1
            }
        }
    }
}

private struct CodePlate: View {
    let state: LinkServer.State
    let credentials: SessionCredentials?
    let fractionRemaining: Double
    let reduceMotion: Bool

    private let plate: CGFloat = 360
    private let radius: CGFloat = Corner.hero

    @State private var matrix: QRMatrix?

    private var codeIsRedeemable: Bool {
        switch state {
        case .idle, .advertising, .connected, .receivingToken: return true
        case .completed, .timeout:                             return false
        case .failed(let fault):                               return fault.codeIsStillLive
        }
    }

    private var showsBrightField: Bool {
        codeIsRedeemable
    }

    private var glow: Color {
        switch state {
        case .failed(let fault) where !fault.codeIsStillLive: return .scDestructive
        default:                                          return .scAccent
        }
    }

    var body: some View {
        VStack(spacing: Space.base) {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(glow.opacity(0.30))
                    .frame(width: plate, height: plate)
                    .blur(radius: 58)
                    .scaleEffect(1.16)

                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(showsBrightField ? AnyShapeStyle(.white) : AnyShapeStyle(Color.scBgRaised))
                    .frame(width: plate, height: plate)
                    .shadow(color: .black.opacity(showsBrightField ? 0.6 : 0.3), radius: 48, y: 18)
                    .overlay { plateContents }
            }
            .frame(width: plate + 56, height: plate + 56)

            expiryBar
        }
        .scMotion(Motion.settle, reduceMotion: reduceMotion, value: state)
        .task(id: credentials?.sessionId) {
            matrix = credentials.flatMap { QRCodeGenerator.matrix(for: $0) }
        }
    }

    @ViewBuilder
    private var plateContents: some View {
        if !codeIsRedeemable {
            deadPlate
        } else if let matrix {
            QRCodeView(matrix: matrix)
                .frame(width: plate * 0.88, height: plate * 0.88)
                .transition(.opacity)
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.5)
                .tint(.black.opacity(0.4))
        }
    }

    private var deadPlate: some View {
        VStack(spacing: Space.snug) {
            Image(systemName: state == .timeout ? "clock.badge.exclamationmark" : "qrcode")
                .font(.system(size: 96, weight: .regular))
                .foregroundStyle(Color.scTextTertiary)
            Text(state == .timeout ? "Code expired" : "No code")
                .font(.tvSubheadline)
                .foregroundStyle(Color.scTextSecondary)
        }
    }

    @ViewBuilder
    private var expiryBar: some View {
        if state == .advertising {
            VStack(spacing: Space.hair) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule()
                            .fill(Color.scAccent.opacity(0.8))
                            .frame(width: geo.size.width * fractionRemaining)
                    }
                }
                .frame(width: plate * 0.55, height: 6)
                .animation(reduceMotion ? nil : .linear(duration: 1), value: fractionRemaining)

                Text("Session timer")
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextTertiary)
            }
            .frame(height: Self.expiryRowHeight)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Code expires in \(Int(fractionRemaining * BonjourConstants.sessionTimeout)) seconds")
        } else {
            Color.clear.frame(height: Self.expiryRowHeight)
        }
    }

    private static let expiryRowHeight: CGFloat = 6 + Space.hair + 34
}

private struct LinkStatusPill: View {
    let state: LinkServer.State
    let timeRemaining: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: Space.snug) {
            indicator

            Text(title)
                .font(.tvCalloutEmph)
                .foregroundStyle(tint)

            if let trailing {
                Text(trailing)
                    .font(.tvCallout)
                    .foregroundStyle(Color.scTextSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Space.base + 2)
        .padding(.vertical, Space.snug)
        .liquidGlass(in: Capsule(), tint: .black.opacity(0.28))
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
        .animation(Motion.settle, value: title)
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .connected, .receivingToken:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(0.8)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.tvCalloutEmph)
                .foregroundStyle(Color.scSuccess)
        case .failed, .timeout:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.tvCalloutEmph)
                .foregroundStyle(Color.scDestructive)
        case .idle, .advertising:
            Circle()
                .fill(Color.scAccent)
                .frame(width: 14, height: 14)
                .shadow(color: Color.scAccent.opacity(0.9), radius: pulse ? 12 : 3)
                .scaleEffect(pulse ? 1.15 : 0.85)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
        }
    }

    private var title: String {
        switch state {
        case .idle:           return "Getting ready…"
        case .advertising:    return "Waiting for your iPhone"
        case .connected:      return "iPhone connected"
        case .receivingToken: return "Signing you in…"
        case .completed:      return "Signed in"
        case .timeout:        return "Code expired, getting a new one"
        case .failed(let fault):
            return fault.codeIsStillLive ? "Last attempt didn't finish" : "Pairing unavailable"
        }
    }

    private var trailing: String? {
        guard state == .advertising, timeRemaining <= 60, timeRemaining > 0 else { return nil }
        return "\(timeRemaining)s"
    }

    private var tint: Color {
        switch state {
        case .completed:        return Color.scSuccess
        case .failed, .timeout: return Color.scDestructive
        case .idle:             return Color.scTextSecondary
        default:                return Color.scTextPrimary
        }
    }
}

private struct RecoveryButton<Tag: Hashable>: View {
    let title: String
    let isPrimary: Bool
    var focused: FocusState<Tag?>.Binding
    let tag: Tag
    let reduceMotion: Bool
    let action: () -> Void

    private var isFocused: Bool { focused.wrappedValue == tag }

    var body: some View {
        HStack(spacing: Space.snug) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: Control.circleIcon, weight: .bold))
            Text(title)
                .font(.tvCalloutEmph)
        }
        .foregroundStyle(
            isFocused ? Color.scChromeFocusOn
                      : (isPrimary ? Color.scAccentOn : Color.scTextPrimary)
        )
        .padding(.horizontal, Space.base + 2)
        .padding(.vertical, Space.snug)
        .background {
            if isFocused {
                Capsule().fill(Color.scChromeFocus)
            } else if isPrimary {
                Capsule().fill(Color.scAccent)
            }
        }
        .liquidGlass(in: Capsule())
        .overlay(
            Capsule().stroke(
                (isPrimary || isFocused) ? Color.clear : Color.white.opacity(0.16),
                lineWidth: 1
            )
        )
        .contentShape(Capsule())
        .focusable()
        .focused(focused, equals: tag)
        .focusEffectDisabled()
        .scMotion(Motion.focus, reduceMotion: reduceMotion, value: isFocused)
        .onTapGesture(perform: action)
    }
}

private struct SuccessBeat<Tag: Hashable>: View {
    var focused: FocusState<Tag?>.Binding
    let tag: Tag
    let reduceMotion: Bool
    let action: () -> Void

    private var isFocused: Bool { focused.wrappedValue == tag }

    @State private var arrived = false
    @State private var ripple = false
    @State private var nudge = false

    var body: some View {
        VStack(spacing: Space.roomy) {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color.scSuccess.opacity(ripple ? 0 : 0.5), .clear],
                        center: .center, startRadius: 0, endRadius: 140
                    ))
                    .scaleEffect(ripple ? 1.35 : 0.55)

                Circle()
                    .stroke(Color.scSuccess.opacity(ripple ? 0 : 0.55), lineWidth: 3)
                    .scaleEffect(ripple ? 1.9 : 1.0)

                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 148, weight: .bold))
                    .foregroundStyle(Color.scSuccess)
                    .scaleEffect(arrived ? 1.0 : 0.55)
                    .opacity(arrived ? 1 : 0)
            }
            .frame(width: 148, height: 148)
            .onAppear {
                withAnimation(reduceMotion ? nil : Motion.settle) {
                    arrived = true
                }
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.7).repeatForever(autoreverses: false)) {
                    ripple = true
                }
            }

            HStack(spacing: Space.snug) {
                Text("Continue")
                    .font(.tvCalloutEmph)
                Image(systemName: "chevron.right")
                    .font(.system(size: Control.circleIcon, weight: .bold))
                    .offset(x: nudge ? 4 : 0)
            }
            .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
            .padding(.horizontal, Space.base + 2)
            .padding(.vertical, Space.snug)
            .background {
                if isFocused { Capsule().fill(Color.scChromeFocus) }
            }
            .liquidGlass(in: Capsule(), tint: Color.scAccent.opacity(0.22))
            .overlay(
                Capsule().stroke(
                    LinearGradient(
                        colors: [.white.opacity(isFocused ? 0 : 0.55), .white.opacity(isFocused ? 0 : 0.08)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
            .focusable()
            .focused(focused, equals: tag)
            .focusEffectDisabled()
            .scMotion(Motion.focus, reduceMotion: reduceMotion, value: isFocused)
            .onTapGesture(perform: action)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    nudge = true
                }
            }
        }
    }
}

private struct CloseButton<Tag: Hashable>: View {
    var focused: FocusState<Tag?>.Binding
    let tag: Tag
    let reduceMotion: Bool
    let action: () -> Void

    private var isFocused: Bool { focused.wrappedValue == tag }

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: Control.circleIcon, weight: .semibold))
            .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary.opacity(0.75))
            .frame(width: Control.circle, height: Control.circle)
            .background {
                if isFocused { Circle().fill(Color.scChromeFocus) }
            }
            .liquidGlass(in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(isFocused ? 0 : 0.16), lineWidth: 1))
            .contentShape(Circle())
            .focusable()
            .focused(focused, equals: tag)
            .focusEffectDisabled()
            .scMotion(Motion.focus, reduceMotion: reduceMotion, value: isFocused)
            .onTapGesture(perform: action)
    }
}

#Preview {
    QRCodeLoginView()
        .environmentObject(AuthenticationService.shared)
}
