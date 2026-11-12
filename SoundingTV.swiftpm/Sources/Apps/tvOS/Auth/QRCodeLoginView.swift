import SwiftUI
import UIKit
import Combine
import Foundation
import DeviceDiscoveryUI
import Network
import QuartzCore

struct QRCodeLoginView: View {
    enum Purpose {
        case signIn
        case companion
    }

    var onClose: (() -> Void)?
    var purpose: Purpose = .signIn
    var useWithoutSoundCloud: (() -> Void)?

    @EnvironmentObject var authService: AuthenticationService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var bonjourServer = LinkServer()
    @StateObject private var nearbyPhone = NearbyPhonePresence()
    @ObservedObject private var companionServer = CompanionServer.shared
    @State private var chimePlayer = ChimePlayer()
    @State private var timeRemaining: Int = Int(BonjourConstants.sessionTimeout)
    @State private var timerTask: Task<Void, Never>?
    @State private var completionTask: Task<Void, Never>?
    @State private var plateCentre: CGPoint?
    @State private var chimeSchedule: ChimeSchedule?
    @State private var storyEvents = PassthroughSubject<SignInEvent, Never>()
    @State private var stage: SignInStage?
    @State private var stageReset: Task<Void, Never>?
    @State private var requestPublisher: SignInRequestPublisher?
    @State private var inviter = DevicePickerInviter()
    @FocusState private var focus: Focus?
    @Environment(\.devicePickerSupports) private var devicePickerSupports

    private enum Focus: Hashable {
        case close, action, sound, picker, withoutSoundCloud
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
            if isConnecting {
                ContentUnavailableView {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.scAccent)
                } description: {
                    Text(connectingTitle)
                        .font(.tvBody)
                        .foregroundStyle(SignInInk.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .remoteFocusTarget()
                .accessibilityIdentifier("login.connecting")
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: Space.roomy)

                    header

                    Spacer().frame(height: Space.roomy)

                    if state == .completed {
                        SuccessBeat(focused: $focus, tag: Focus.action, reduceMotion: reduceMotion) {
                            advance()
                        }
                        .accessibilityIdentifier("login.success.continue")
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    } else if isFaultScreen, case .failed(let fault) = state {
                        FaultGuidance(fault: fault, peer: bonjourServer.peerDevice)
                            .frame(maxWidth: 900)
                    } else if let code = bonjourServer.numericComparisonCode {
                        NumericComparisonGuidance(code: code)
                            .frame(maxWidth: 900)
                    } else {
                        ChimePulse(schedule: chimeSchedule) {
                            CodePlate(
                                state: state,
                                credentials: bonjourServer.credentials,
                                reduceMotion: reduceMotion,
                                onPlateMoved: { plateCentre = $0 }
                            )
                        }

                        Spacer().frame(height: Space.base)

                        LinkStatusLine(
                            state: state,
                            stage: stage,
                            waiting: hint,
                            nearbyName: nearbyPhone.name,
                            nearbyKind: nearbyPhone.kind,
                            peer: bonjourServer.peerDevice
                        )
                        .frame(maxWidth: 1100)

                        Text(countdown ?? " ")
                            .font(.tvCaption)
                            .foregroundStyle(SignInInk.secondary)
                            .monospacedDigit()
                            .padding(.top, Space.tight)
                            .accessibilityHidden(countdown == nil)
                    }

                    if state != .completed {
                        Spacer().frame(height: Space.base)
                        controls

                        if let useWithoutSoundCloud {
                            Spacer().frame(height: Space.snug)
                            Button("Use Without SoundCloud", action: useWithoutSoundCloud)
                                .buttonStyle(SignInChromeButtonStyle(reduceMotion: reduceMotion, isQuiet: true))
                                .focusEffectDisabled()
                                .focused($focus, equals: .withoutSoundCloud)
                                .accessibilityIdentifier("login.withoutSoundCloud")
                        }
                    }

                    Spacer(minLength: Space.roomy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, Space.page)
                .scMotion(Motion.settle, reduceMotion: reduceMotion, value: state)
            }

            if useWithoutSoundCloud == nil, let onClose {
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
        .background(
            LinkBackdrop(
                state: state,
                mode: backdropMode,
                plate: plateFrame,
                showsPlate: showsPlate
            )
                .ignoresSafeArea()
        )
        .onExitCommand { onClose?() }
        .alert(
            approvalTitle,
            isPresented: Binding(get: { bonjourServer.linkApproval != nil }, set: { _ in }),
            presenting: bonjourServer.linkApproval
        ) { _ in
            Button("Allow") { bonjourServer.approveLink() }
            Button("Don't Allow", role: .cancel) { bonjourServer.declineLink() }
        } message: { approval in
            Text("\(Self.approvalMessage(approval))\n\n\(Self.grouped(approval.code))")
                .monospacedDigit()
                .multilineTextAlignment(.center)
        }
        .defaultFocus($focus, defaultFocus)
        .onAppear {
            SameAccountLinkAdvertiser.shared.hold()
            prepareSignInRequest()
            bonjourServer.onChimeRequested = { [chimePlayer] in chimePlayer.playChime() }
            nearbyPhone.start()
            startSession()
        }
        .onDisappear {
            SameAccountLinkAdvertiser.shared.release()
            bonjourServer.onChimeRequested = nil
            nearbyPhone.stop()
            stopSession()
            requestPublisher?.withdraw()
            inviter.cancel()
        }
        .onChange(of: state) { _, newState in
            if newState == .timeout, LinkServer.debugStateOverride == nil {
                startSession()
            }
            if newState == .advertising { requestPublisher?.publish() }
            if newState == .completed { requestPublisher?.withdraw() }
            updateChime()
        }
        .onReceive(backdropEvents) { observe($0) }
        .onChange(of: bonjourServer.chimeCode) { _, _ in updateChime() }
        .onChange(of: scenePhase) { _, _ in updateChime() }
        .onChange(of: authService.isAuthenticated) { _, authenticated in
            if authenticated, companionServer.authHandoffDeviceName != nil { advance() }
        }
        .onChange(of: showRetry) { _, retryAvailable in
            if retryAvailable { focus = .action }
        }
        .onChange(of: state == .completed) { _, completed in
            if completed {
                focus = .action
                chimePlayer.playSuccess()
            }
        }
        .userActivity(HandoffActivityType.link, isActive: isPairingHandoffActive) { activity in
            configurePairingActivity(activity)
        }
        #if DEBUG
        .task {
            guard let story = SignInStory.current else { return }
            await story.run(send: { storyEvents.send($0) }, chime: { chimePlayer.playChime() })
        }
        #endif
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Space.base) {
            if showRetry {
                RecoveryButton(
                    title: "Try Again",
                    focused: $focus,
                    tag: Focus.action,
                    reduceMotion: reduceMotion
                ) { startSession() }
                .accessibilityIdentifier("login.recovery")
            }

            if bonjourServer.chimeCode != nil, !isFaultScreen {
                Button { chimePlayer.playChime() } label: {
                    Label("Play Sound", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(SignInChromeButtonStyle(reduceMotion: reduceMotion))
                .focusEffectDisabled()
                .focused($focus, equals: .sound)
                .accessibilityIdentifier("login.playSound")
            }

            if showsDevicePicker {
                Group {
                    if devicePickerIsSupported {
                        DevicePicker(
                            DevicePickerInviter.descriptor,
                            onSelect: { invite($0) },
                            label: { Label(TVPairingCopy.pickerTitle, systemImage: TVPairingCopy.pickerSymbolName) },
                            fallback: { EmptyView() },
                            parameters: { DevicePickerInviter.parameters }
                        )
                    } else {
                        Button {} label: { Label(TVPairingCopy.pickerTitle, systemImage: TVPairingCopy.pickerSymbolName) }
                    }
                }
                .buttonStyle(SignInChromeButtonStyle(reduceMotion: reduceMotion))
                .focusEffectDisabled()
                .focused($focus, equals: .picker)
                .accessibilityIdentifier("login.devicePicker")
            }
        }
    }

    private var defaultFocus: Focus {
        if showRetry || state == .completed { return .action }
        if bonjourServer.chimeCode != nil { return .sound }
        return useWithoutSoundCloud != nil ? .withoutSoundCloud : .close
    }

    private var hint: String {
        switch state {
        case .connected, .receivingToken:
            return TVPairingCopy.finishOn(bonjourServer.peerDevice)
        default:
            return purpose == .companion ? TVPairingCopy.companionScanHint : TVPairingCopy.scanHint
        }
    }

    private var showsPlate: Bool {
        !isConnecting && state != .completed && !isFaultScreen && bonjourServer.numericComparisonCode == nil
    }

    private var isConnecting: Bool {
        if companionServer.authHandoffDeviceName != nil { return true }
        guard !state.isTerminal else { return false }
        if bonjourServer.linkApproval != nil { return false }
        return state == .connected || state == .receivingToken
            || bonjourServer.isLinkInProgress || stage == .pickerConnecting
    }

    private var connectingTitle: String {
        let name = companionServer.authHandoffDeviceName
            ?? bonjourServer.connectingDeviceName
            ?? nearbyPhone.name
        return name.map { "Connecting to \($0)…" } ?? "Connecting…"
    }

    private var countdown: String? {
        guard state == .advertising, timeRemaining <= 60, timeRemaining > 0 else { return nil }
        return "New code in \(timeRemaining)s"
    }

    private var plateFrame: CGRect? {
        plateCentre.map { centre in
            CGRect(
                x: centre.x - CodePlate.side / 2,
                y: centre.y - CodePlate.side / 2,
                width: CodePlate.side,
                height: CodePlate.side
            )
        }
    }

    private var backdropMode: SignInBackdropMode {
        if isConnecting { return .connecting }
        switch state {
        case .connected, .receivingToken:
            return .connecting
        case .completed:
            return .resolved
        case .failed(let fault) where !fault.codeIsStillLive:
            return .unavailable
        default:
            return .listening
        }
    }

    private func observe(_ event: SignInEvent) {
        let next: SignInStage?
        switch event {
        case .scanned:         next = .phoneConnected
        case .offerReceived:   next = .phoneFound
        case .exchangeStarted: next = .signingIn
        case .failed:          next = .couldntSignIn
        case .signedIn:        next = .signedIn
        case .notificationSent: next = .notified
        case .phoneConnecting: next = .pickerConnecting
        case .codeRotated, .offerClosed: next = nil
        case .chime(let schedule):
            chimeSchedule = schedule
            return
        case .carrier, .confirmed: return
        }
        stageReset?.cancel()
        stageReset = nil
        stage = next
        guard next == .couldntSignIn || next == .phoneFound || next == .notified || next == .pickerConnecting else { return }
        stageReset = Task {
            try? await Task.sleep(for: .seconds(next == .couldntSignIn ? 8 : 20))
            if !Task.isCancelled { stage = nil }
        }
    }

    private var showsDevicePicker: Bool {
        guard !isFaultScreen, bonjourServer.credentials != nil || Self.forcesDevicePicker else { return false }
        return Self.forcesDevicePicker || devicePickerIsSupported
    }

    private var devicePickerIsSupported: Bool {
        devicePickerSupports(DevicePickerInviter.descriptor, parameters: { DevicePickerInviter.parameters })
    }

    private static var forcesDevicePicker: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_DEVICE_PICKER"] == "1"
        #else
        false
        #endif
    }

    private func prepareSignInRequest() {
        guard purpose == .signIn, !authService.isAuthenticated, requestPublisher == nil else { return }
        let publisher = SignInRequestPublisher()
        publisher.onSent = { [storyEvents] in storyEvents.send(.notificationSent) }
        requestPublisher = publisher
        bonjourServer.rendezvous = publisher.rendezvous
    }

    private func invite(_ endpoint: NWEndpoint) {
        guard let credentials = bonjourServer.credentials, !credentials.isExpired else { return }
        storyEvents.send(.phoneConnecting)
        inviter.send(to: endpoint, credentials: credentials) { outcome in
            if outcome == .failed { storyEvents.send(.failed) }
        }
    }

    private var backdropEvents: AnyPublisher<SignInEvent, Never> {
        bonjourServer.events
            .merge(with: chimePlayer.events, storyEvents)
            .eraseToAnyPublisher()
    }

    private var header: some View {
        SoundingWelcomeTitle(
            title: title,
            message: subtitle,
            titleFont: .tvLargeTitle,
            messageFont: .tvBody,
            messageStyle: AnyShapeStyle(SignInInk.secondary),
            spacing: Space.snug
        )
        .foregroundStyle(SignInInk.primary)
        .frame(maxWidth: 1100)
    }

    private var isFaultScreen: Bool {
        if case .failed(let fault) = state { return !fault.codeIsStillLive }
        return false
    }

    private var title: String {
        if isFaultScreen { return "Can't Add a Device" }
        if purpose == .companion {
            return state == .completed ? "Device Added" : "Add a Device"
        }
        return state == .completed ? "You're signed in" : SoundingWelcome.headline
    }

    private var subtitle: String {
        if isFaultScreen { return "" }
        if purpose == .companion {
            if state == .completed { return "It can now play music on this Apple TV and control it." }
            return "Link an iPhone, iPad or Mac to this Apple TV."
        }
        return state == .completed ? TVAccountCopy.tvSignedInSubtitle(authService.currentUser.map(PeerAccount.init(user:))) : SoundingWelcome.tagline
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
        activity.title = "Sign in to Sounding"
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
        bonjourServer.onLinked = {
            completionTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                onClose?()
            }
        }
        advertiseSignedInAccount()
        bonjourServer.start()
        startTimer()
    }

    private func advertiseSignedInAccount() {
        guard authService.isAuthenticated,
              let accountId = SameAccountLinkAdvertiser.currentAccountId, !accountId.isEmpty,
              let salt = LinkAccountHint.makeSalt() else {
            bonjourServer.accountHint = nil
            bonjourServer.ownerAccountId = nil
            return
        }
        bonjourServer.accountHint = LinkAccountHint.advert(
            accountId: accountId,
            linkedDeviceIds: CompanionServer.shared.devices.compactMap(\.deviceId),
            salt: salt
        )
        bonjourServer.ownerAccountId = accountId
        LinkOwnerKeyCloud.shared.refreshIfNeeded()
    }

    private func stopSession() {
        timerTask?.cancel()
        timerTask = nil
        completionTask?.cancel()
        completionTask = nil
        chimePlayer.stop()
        bonjourServer.stop()
    }

    private var approvalTitle: String {
        let name = bonjourServer.linkApproval?.deviceName ?? "A nearby device"
        if bonjourServer.linkApproval?.account == .different { return TVAccountCopy.tvAllowTitle(device: name) }
        return "Allow “\(name)” to link to this Apple TV?"
    }

    static func approvalMessage(_ approval: LinkServer.LinkApproval) -> String {
        switch approval.account {
        case .none: return "Only allow it if \(approval.deviceName) shows this code."
        case .same: return TVAccountCopy.tvAllowMessage(device: approval.deviceName, sameAccount: true)
        case .different: return TVAccountCopy.tvAllowMessage(device: approval.deviceName, sameAccount: false)
        }
    }

    private static func grouped(_ code: String) -> String {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return code }
        let split = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[..<split]) - \(digits[split...])"
    }

    private var chimeCanPlay: Bool {
        scenePhase == .active && state != .completed && !isConnecting && !isFaultScreen && Self.debugForcedState == nil && Self.storyAllowsChime
    }

    private static var storyAllowsChime: Bool {
        #if DEBUG
        SignInStory.current?.wantsCarrier ?? true
        #else
        true
        #endif
    }

    private func updateChime() {
        chimePlayer.prepare(bonjourServer.chimeCode, canPlay: chimeCanPlay)
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

private struct NumericComparisonGuidance: View {
    let code: String

    var body: some View {
        VStack(spacing: Space.base) {
            Label("A nearby device wants to pair", systemImage: "link")
                .font(.tvHeadline)
                .foregroundStyle(SignInInk.primary)

            Text("Confirm this matches the code on the other device:")
                .font(.tvBody)
                .foregroundStyle(SignInInk.secondary)

            Text(codeGroups.joined(separator: " - "))
                .font(.tvLargeTitle)
                .monospacedDigit()
                .foregroundStyle(SignInInk.primary)
                .frame(minWidth: CodePlate.side)
                .padding(.vertical, Space.base)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Pairing code \(codeGroups.joined(separator: ", "))")

            Text("If it doesn't match, someone else on this Wi-Fi network may be trying to sign in.")
                .font(.tvCaption)
                .foregroundStyle(SignInInk.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
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
    var peer = PeerDevice.unknown

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            Label(headline, systemImage: "exclamationmark.triangle")
                .font(.tvHeadline)
                .foregroundStyle(SignInInk.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(instruction)
                .font(.tvBody)
                .foregroundStyle(SignInInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headline: String {
        switch fault {
        case .cannotListen:          return "This Apple TV can't be found on your network"
        case .localNetworkDenied:    return "Local Network access is off"
        case .cannotGenerateSession: return "Couldn't create a code"
        case .connectionLost:        return TVPairingCopy.droppedOff(peer)
        case .rejected:              return "That sign-in was refused"
        case .validationUnavailable: return "SoundCloud couldn't be reached"
        }
    }

    private var instruction: String {
        switch fault {
        case .cannotListen:
            return "Check that this Apple TV is on Wi-Fi, then try again."
        case .localNetworkDenied:
            return "Turn on Local Network for Sounding in Settings › Apps, then try again."
        case .cannotGenerateSession:
            return "Try again. If it keeps happening, restart Sounding."
        case .connectionLost:
            return "The connection closed before it finished. Try again for a fresh code."
        case .rejected:
            return TVPairingCopy.signInOnceMore(peer)
        case .validationUnavailable:
            return "Check this Apple TV's internet connection, then try again."
        }
    }
}

private enum SignInInk {
    static let primary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.965, green: 0.94, blue: 0.905, alpha: 1)
            : UIColor(red: 0.16, green: 0.11, blue: 0.09, alpha: 1)
    })
    static let secondary = primary.opacity(0.7)
    static let tertiary = primary.opacity(0.52)
    static let quietFill = primary.opacity(0.07)
    static let stroke = primary.opacity(0.12)
    static let focusFill = primary
    static let focusLabel = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.06, green: 0.05, blue: 0.045, alpha: 1)
            : UIColor(red: 0.985, green: 0.962, blue: 0.930, alpha: 1)
    })
}

private struct LinkBackdrop: View {
    let state: LinkServer.State
    let mode: SignInBackdropMode
    let plate: CGRect?
    let showsPlate: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = SoundingArtPalette.resolve(colorScheme)
        ZStack {
            palette.ground

            if state == .completed {
                RadialGradient(
                    colors: [Color.scSuccess.opacity(0.16), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 700
                )
            }

            SignInLineArt(mode: mode, plate: plate, showsPlate: showsPlate, palette: palette)
        }
        .accessibilityHidden(true)
    }
}

private struct ChimePulse<Content: View>: View {
    let schedule: ChimeSchedule?
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var glow = 0.0
    @State private var spread = 1.0

    var body: some View {
        content()
        .background {
            RoundedRectangle(cornerRadius: Corner.hero, style: .continuous)
                .stroke(Color.scAccent, lineWidth: 2)
                .shadow(color: Color.scAccent.opacity(0.6), radius: 22)
                .scaleEffect(reduceMotion ? 1 : spread)
                .opacity(glow)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .task(id: schedule?.start) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                glow = 0
                spread = 1
            }
            guard let schedule, scenePhase == .active,
                  CACurrentMediaTime() < schedule.start + schedule.duration else { return }
            try? await Task.sleep(for: .seconds(max(0, schedule.start - CACurrentMediaTime())))
            guard !Task.isCancelled, scenePhase == .active else { return }
            withAnimation(.easeInOut(duration: 0.25)) { glow = 0.45 }
            if !reduceMotion {
                withAnimation(.spring(duration: 0.45, bounce: 0)) { spread = 1.13 }
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 1.1)) { glow = 0 }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { glow = 0 }
        }
    }
}

private struct CodePlate: View {
    let state: LinkServer.State
    let credentials: SessionCredentials?
    let reduceMotion: Bool
    var onPlateMoved: (CGPoint) -> Void = { _ in }

    static let side: CGFloat = 360

    private let plate: CGFloat = Self.side
    private let radius: CGFloat = Corner.hero

    @State private var matrix: QRMatrix?

    private var codeIsRedeemable: Bool {
        switch state {
        case .idle, .advertising, .connected, .receivingToken: return true
        case .completed, .timeout:                             return false
        case .failed(let fault):                               return fault.codeIsStillLive
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(codeIsRedeemable ? AnyShapeStyle(.white) : AnyShapeStyle(SignInInk.quietFill))
            .frame(width: plate, height: plate)
            .shadow(color: .black.opacity(codeIsRedeemable ? 0.2 : 0), radius: 36, y: 14)
            .overlay { plateContents }
            .onGeometryChange(for: CGPoint.self) { proxy in
                let frame = proxy.frame(in: .global)
                return CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded())
            } action: { onPlateMoved($0) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(plateAccessibilityLabel)
            .scMotion(Motion.settle, reduceMotion: reduceMotion, value: state)
            .task(id: credentials?.sessionId) {
                matrix = credentials.flatMap { QRCodeGenerator.matrix(for: $0) }
            }
    }

    private var plateAccessibilityLabel: String {
        if !codeIsRedeemable {
            return state == .timeout ? "Getting a new code" : "No code"
        }
        return matrix == nil ? "Preparing a sign-in code" : TVPairingCopy.scanAccessibility
    }

    @ViewBuilder
    private var plateContents: some View {
        if codeIsRedeemable, let matrix {
            QRCodeView(matrix: matrix)
                .frame(width: plate * 0.88, height: plate * 0.88)
                .transition(.opacity)
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.5)
                .tint(SignInInk.tertiary)
        }
    }
}

private enum SignInStage: Equatable {
    case phoneConnected, phoneFound, signingIn, signedIn, couldntSignIn, notified, pickerConnecting
}

private struct LinkStatusLine: View {
    let state: LinkServer.State
    var stage: SignInStage?
    let waiting: String
    var nearbyName: String?
    var nearbyKind: DeviceClass?
    var peer = PeerDevice.unknown

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase {
        case preparing, waiting, working, done, failed
    }

    private var staged: SignInStage? {
        switch state {
        case .idle, .advertising: return stage
        default: return nil
        }
    }

    private var phase: Phase {
        if let staged {
            switch staged {
            case .phoneConnected, .phoneFound, .signingIn, .pickerConnecting: return .working
            case .notified: return .waiting
            case .signedIn: return .done
            case .couldntSignIn: return .failed
            }
        }
        switch state {
        case .idle: return .preparing
        case .advertising: return .waiting
        case .connected, .receivingToken: return .working
        case .completed: return .done
        case .failed, .timeout: return .failed
        }
    }

    var body: some View {
        HStack(spacing: Space.tight) {
            indicator

            Text(title)
                .font(.tvBody)
                .foregroundStyle(tint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 44)
        .scMotion(Motion.settle, reduceMotion: reduceMotion, value: title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var indicator: some View {
        switch phase {
        case .working:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(SignInInk.secondary)
                .scaleEffect(0.7)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.tvCalloutEmph)
                .foregroundStyle(Color.scSuccess)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.tvCalloutEmph)
                .foregroundStyle(Color.scDestructive)
        case .preparing, .waiting:
            if isNearby {
                Image(systemName: PeerDevice(deviceClass: nearbyKind).symbolName)
                    .font(.tvCalloutEmph)
                    .foregroundStyle(SignInInk.secondary)
            }
        }
    }

    private var isNearby: Bool {
        staged == nil && state == .advertising && nearbyName != nil
    }

    private var title: String {
        if let staged {
            switch staged {
            case .phoneConnected: return TVPairingCopy.connected(peer)
            case .phoneFound: return TVPairingCopy.found(peer)
            case .signingIn: return "Connecting…"
            case .signedIn: return "Signed in"
            case .couldntSignIn: return "Couldn\u{2019}t sign in"
            case .notified: return TVPairingCopy.notified
            case .pickerConnecting: return TVPairingCopy.pickerConnecting
            }
        }
        switch state {
        case .idle:           return "Getting ready…"
        case .advertising:    return nearbyName.map(TVPairingCopy.nearbyHint) ?? waiting
        case .connected:      return TVPairingCopy.connectedFinish(peer)
        case .receivingToken: return "Signing you in…"
        case .completed:      return "Signed in"
        case .timeout:        return "Code expired, getting a new one"
        case .failed(let fault):
            return fault.codeIsStillLive ? "Last attempt didn't finish" : "Pairing unavailable"
        }
    }

    private var tint: Color {
        switch phase {
        case .done:      return Color.scSuccess
        case .failed:    return Color.scDestructive
        case .preparing: return SignInInk.tertiary
        default:         return SignInInk.secondary
        }
    }
}

private struct RecoveryButton<Tag: Hashable>: View {
    let title: String
    var icon = "arrow.clockwise"
    var focused: FocusState<Tag?>.Binding
    let tag: Tag
    let reduceMotion: Bool
    let action: () -> Void

    private var isFocused: Bool { focused.wrappedValue == tag }

    var body: some View {
        HStack(spacing: Space.snug) {
            Image(systemName: icon)
                .font(.system(size: Control.circleIcon, weight: .bold))
            Text(title)
                .font(.tvCalloutEmph)
        }
        .foregroundStyle(isFocused ? SignInInk.focusLabel : SignInInk.primary)
        .padding(.horizontal, Space.base + 2)
        .padding(.vertical, Space.snug)
        .background { SignInChromeFill(isFocused: isFocused) }
        .contentShape(Capsule())
        .scaleEffect(isFocused ? 1.06 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.22 : 0), radius: 18, y: 10)
        .focusable()
        .focused(focused, equals: tag)
        .focusEffectDisabled()
        .scMotion(Motion.focus, reduceMotion: reduceMotion, value: isFocused)
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
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
            .accessibilityHidden(true)
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
            .foregroundStyle(isFocused ? SignInInk.focusLabel : SignInInk.primary)
            .padding(.horizontal, Space.base + 2)
            .padding(.vertical, Space.snug)
            .background { SignInChromeFill(isFocused: isFocused) }
            .contentShape(Capsule())
            .scaleEffect(isFocused ? 1.06 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.22 : 0), radius: 18, y: 10)
            .focusable()
            .focused(focused, equals: tag)
            .focusEffectDisabled()
            .scMotion(Motion.focus, reduceMotion: reduceMotion, value: isFocused)
            .onTapGesture(perform: action)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Continue")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
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
            .foregroundStyle(isFocused ? SignInInk.focusLabel : SignInInk.primary.opacity(0.75))
            .frame(width: Control.circle, height: Control.circle)
            .background {
                if isFocused {
                    Circle().fill(SignInInk.focusFill)
                } else {
                    Color.clear.glassEffect(.regular, in: Circle())
                }
            }
            .contentShape(Circle())
            .scaleEffect(isFocused ? 1.1 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.22 : 0), radius: 14, y: 8)
            .focusable()
            .focused(focused, equals: tag)
            .focusEffectDisabled()
            .scMotion(Motion.focus, reduceMotion: reduceMotion, value: isFocused)
            .onTapGesture(perform: action)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Close")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}

#Preview {
    QRCodeLoginView()
        .environmentObject(AuthenticationService.shared)
}

private struct SignInChromeButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    var isQuiet = false

    func makeBody(configuration: Configuration) -> some View {
        SignInChromeButtonBody(configuration: configuration, reduceMotion: reduceMotion, isQuiet: isQuiet)
    }
}

private struct SignInChromeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let reduceMotion: Bool
    let isQuiet: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.tvCalloutEmph)
            .foregroundStyle(isFocused ? SignInInk.focusLabel : (isQuiet ? SignInInk.secondary : SignInInk.primary))
            .padding(.horizontal, Space.base + 2)
            .padding(.vertical, Space.snug)
            .background { SignInChromeFill(isFocused: isFocused, isQuiet: isQuiet) }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.06 : 1))
            .shadow(color: .black.opacity(isFocused ? 0.22 : 0), radius: 18, y: 10)
            .scMotion(Motion.focus, reduceMotion: reduceMotion, value: isFocused)
    }
}

private struct SignInChromeFill: View {
    let isFocused: Bool
    var isQuiet = false

    var body: some View {
        if isFocused {
            Capsule().fill(SignInInk.focusFill)
        } else if !isQuiet {
            Color.clear.glassEffect(.regular, in: Capsule())
        }
    }
}
