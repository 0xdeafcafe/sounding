import SwiftUI

enum AppleTVDebugStory {
    static let forcedState: CompanionClient.State? = {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_TV_STORY"] {
        case "neverPaired": return .unlinked
        case "looking":     return .searching
        case "unreachable": return .failed("Your Apple TV didn't respond. It's probably asleep, or on a different Wi-Fi network.")
        case "connected":   return .connected
        default:            return nil
        }
        #else
        return nil
        #endif
    }()
}

struct CompanionRootView: View {
    var showsSignIn: Bool = false

    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @EnvironmentObject private var linkOffers: LinkOfferBrowser
    @ObservedObject private var palette = NowPlayingPalette.shared
    @ObservedObject private var registry = CompanionRegistry.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var navigateToDJAfterEnabling = false
    @State private var showingAutoDJStartConfiguration = false
    @State private var isMovingSession = false
    @State private var livePulse = false

    @State private var handshake: LinkConfirmationHandshake?
    @State private var cloudOffer: LinkOffer?
    @State private var pendingPairing: LinkRequest?
    @State private var pendingPairingPeerName: String?
    @State private var pendingPairingPeerClass: DeviceClass = .tv
    @State private var showingForgetTVConfirmation = false
    @State private var isSigningIn = false

    private static let rosterRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private var presentedState: CompanionClient.State {
        AppleTVDebugStory.forcedState ?? client.state
    }

    private var presentedIsPaired: Bool {
        if let forced = AppleTVDebugStory.forcedState { return forced != .unlinked }
        return client.isLinked
    }

    private var presentedPlayback: PlaybackStatePayload? {
        #if DEBUG
        if AppleTVDebugStory.forcedState == .connected, client.playback == nil {
            return PlaybackStatePayload(
                isPlaying: true, positionSeconds: 83, durationSeconds: 241,
                trackId: "demo-track", title: "Coastline", artist: "Midnight Drift",
                artworkURL: nil, isDJEngineLive: false, revision: 1,
                issuedAtMillis: 0, signature: ""
            )
        }
        #endif
        return client.playback
    }

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(spacing: Spacing.lg) {
                    deviceRosterSection

                    if !presentedIsPaired {
                        pairingOfferCard
                        cloudOfferCard
                    }

                    if story == .neverPaired {
                        unlinkedCard
                    } else {
                        tvStatusCard
                    }

                    signInCard

                    if story == .connected {
                        nowPlayingSection
                        djCard
                        forgetFootnote
                    }
                }
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.xxl)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: PhoneChrome.floatingClearance) }
        }
        .navigationTitle("Companion")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: $navigateToDJAfterEnabling) {
            DJControlView(client: client)
        }
        .sheet(isPresented: $showingAutoDJStartConfiguration) {
            AutoDJStartConfigurationView { configuration in
                coordinator.startDJSession(configuration: configuration)
                navigateToDJAfterEnabling = true
            }
        }
        .confirmationDialog("Forget This \(client.linkedClass.displayName)", isPresented: $showingForgetTVConfirmation) {
            Button("Forget This \(client.linkedClass.displayName)", role: .destructive) { forgetAppleTV() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to scan the sign-in code again to relink your \(client.linkedClass.displayName).")
        }
        .task {
            client.connect()
        }
        .task {
            while !Task.isCancelled {
                refreshCloudOffer()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshCloudOffer()
        }
        .onChange(of: client.isLinked) { _, isLinked in
            guard isLinked else { return }
            handshake?.stop()
            handshake = nil
            cloudOffer = nil
        }
        .task {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                livePulse = true
            }
        }
        .sheet(isPresented: Binding(
            get: { handshake != nil },
            set: { isPresented in
                if !isPresented {
                    handshake?.stop()
                    handshake = nil
                }
            }
        )) {
            if let handshake {
                NumericComparisonSheet(handshake: handshake) { sessionId, secret in
                    pendingPairingPeerName = handshake.claimedName
                    pendingPairingPeerClass = handshake.kind
                    self.handshake = nil
                    pendingPairing = LinkRequest(sessionId: sessionId, secret: secret)
                }
            }
        }
        .fullScreenCover(item: $pendingPairing) { request in
            NavigationStack {
                SoundCloudLoginView(
                    sessionId: request.sessionId,
                    sessionSecret: request.secret,
                    peerName: pendingPairingPeerName,
                    peerClass: pendingPairingPeerClass,
                    onComplete: { pendingPairing = nil }
                )
            }
        }
        .fullScreenCover(isPresented: $isSigningIn) {
            NavigationStack {
                SoundCloudLoginView.standalone {
                    isSigningIn = false
                }
            }
        }
    }

    @ViewBuilder
    private var deviceRosterSection: some View {
        if !registry.devices.isEmpty {
            VStack(alignment: .leading, spacing: Space.snug) {
                SCSectionHeader(title: "Your Devices", style: .phoneSectionHeader)
                    .padding(.horizontal, Spacing.xl)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(registry.devices.enumerated()), id: \.element.deviceId) { index, record in
                        deviceRosterRow(record)

                        if index < registry.devices.count - 1 {
                            ScRowDivider(leading: 0)
                                .padding(.vertical, Space.tight)
                        }
                    }
                }
                .scCard(cornerRadius: Radius.lg, padding: Spacing.lg)
                .padding(.horizontal, Spacing.xl)
            }
        }
    }

    private func deviceRosterRow(_ record: CompanionDeviceRecord) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: record.deviceClass.symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.scAccent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayName)
                    .font(.scHeadline)
                    .foregroundStyle(Color.scTextPrimary)

                rosterStatusLine(record)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.tight)
    }

    private func rosterStatusLine(_ record: CompanionDeviceRecord) -> some View {
        HStack(spacing: 6) {
            if isConnectedCompanion(record) {
                Circle()
                    .fill(Color.scSuccess)
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.scSuccess.opacity(0.7), radius: 4)
                    .scaleEffect(livePulse ? 1.4 : 1.0)
                    .opacity(livePulse ? 0.55 : 1.0)
            }
            Text(rosterStatusText(record))
        }
        .font(.scCaption)
        .foregroundStyle(rosterIsDimmed(record) ? Color.scTextTertiary : Color.scTextSecondary)
    }

    private func isConnectedCompanion(_ record: CompanionDeviceRecord) -> Bool {
        record.deviceClass == client.linkedClass && client.isReachable
    }

    private func rosterIsDimmed(_ record: CompanionDeviceRecord) -> Bool {
        !isConnectedCompanion(record) && record.deviceId != registry.localDeviceId
    }

    private func rosterStatusText(_ record: CompanionDeviceRecord) -> String {
        var base: String
        if isConnectedCompanion(record) {
            base = "Connected"
        } else if record.deviceId == registry.localDeviceId {
            base = "This \(record.deviceClass.displayName)"
        } else {
            base = "Last seen \(Self.rosterRelativeFormatter.localizedString(for: record.lastSeenAt, relativeTo: Date()))"
        }
        if let batterySuffix = rosterBatterySuffix(record) {
            base += " · \(batterySuffix)"
        }
        return base
    }

    private func rosterBatterySuffix(_ record: CompanionDeviceRecord) -> String? {
        guard record.deviceClass.hasBattery, let fraction = record.conditions.batteryFraction else { return nil }
        let percent = Int((fraction * 100).rounded())
        if record.conditions.isPluggedIn { return "\(percent)% · Plugged In" }
        if record.conditions.isLowPowerMode { return "\(percent)% · Low Power Mode" }
        return "\(percent)%"
    }

    @ViewBuilder
    private var pairingOfferCard: some View {
        if let offer = linkOffers.offer {
            Button {
                handshake = LinkConfirmationHandshake(offer: offer)
            } label: {
                HStack(spacing: Spacing.md) {
                    Image(systemName: offer.kind.symbolName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.scAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(offer.displayIdentity) wants to sign in")
                            .font(.scHeadline)
                            .foregroundStyle(.primary)
                        Text("Tap to check the code matches")
                            .font(.scCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .scCard(cornerRadius: Radius.lg, padding: Spacing.lg)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.xl)
        }
    }

    @ViewBuilder
    private var cloudOfferCard: some View {
        if linkOffers.offer == nil, let offer = cloudOffer, let secret = offer.secret {
            Button {
                LinkOfferStore.discard(offer)
                cloudOffer = nil
                pendingPairingPeerName = offer.tvName
                pendingPairingPeerClass = .tv
                pendingPairing = LinkRequest(sessionId: offer.sessionId, secret: secret)
            } label: {
                HStack(spacing: Spacing.md) {
                    Image(systemName: DeviceClass.tv.symbolName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.scAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(offer.tvName) is waiting to sign in")
                            .font(.scHeadline)
                            .foregroundStyle(.primary)
                        Text("Shared through iCloud, so no camera needed. Tap to continue on this iPhone.")
                            .font(.scCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .scCard(cornerRadius: Radius.lg, padding: Spacing.lg)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.xl)
        }
    }

    private func refreshCloudOffer() {
        if let forced = Self.debugCloudOffer {
            cloudOffer = forced
            return
        }
        let offer = LinkOfferStore.fetchLatest()
        if let offer, offer.secret == nil {
            LinkOfferStore.discard(offer)
            cloudOffer = nil
            return
        }
        cloudOffer = offer
    }

    private static var debugCloudOffer: LinkOffer? {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SOUNDING_TV_CLOUD_OFFER"] == "1" else { return nil }
        return LinkOffer(
            sessionId: UUID().uuidString,
            secretBase64: Data(repeating: 0, count: 32).base64EncodedString(),
            createdAt: Date(),
            tvName: "Living Room"
        )
        #else
        return nil
        #endif
    }

    private var background: some View {
        ZStack {
            Color.scBgBase
            if coordinator.nowPlaying != nil {
                RadialGradient(
                    colors: [palette.current.accent.opacity(0.28), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 420
                )
                .animation(.scMotion(SCContentMotion.ambient, reduceMotion: reduceMotion), value: palette.current)
            }
        }
        .ignoresSafeArea()
    }

    private enum TVStory: Equatable {
        case neverPaired
        case looking
        case unreachable(String)
        case connected
    }

    private var story: TVStory {
        switch presentedState {
        case .unlinked:  return .neverPaired
        case .connected: return .connected
        case .failed(let message):
            return presentedIsPaired ? .unreachable(message) : .neverPaired
        case .idle, .searching, .connecting:
            return presentedIsPaired ? .looking : .neverPaired
        }
    }

    private var unlinkedCard: some View {
        statusCard(
            icon: "qrcode.viewfinder",
            tint: Color.scAccent,
            title: "No Apple TV Paired",
            message: "Open SoundingCloud on your Apple TV and scan the on-screen QR code with your iPhone Camera. You can keep listening here in the meantime."
        )
    }

    private var tvStatusCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Image(systemName: client.linkedClass.symbolName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.scAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Your \(client.linkedClass.displayName)")
                        .font(.scHeadline)
                    statusLine
                }

                Spacer(minLength: 0)

                statusAccessory
            }

            switch story {
            case .looking:
                Text("If it's asleep or on a different Wi-Fi network, it reconnects on its own. Nothing for you to do.")
                    .font(.scCaption)
                    .foregroundStyle(.secondary)
                forgetAction

            case .unreachable(let message):
                Text(message)
                    .font(.scCaption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Try Again") { client.retry() }
                        .buttonStyle(.borderedProminent)
                        .tint(.scAccent)
                    Spacer(minLength: Spacing.md)
                    forgetAction
                }

            case .connected:
                outputPicker

            case .neverPaired:
                EmptyView()
            }
        }
        .scCard(cornerRadius: Radius.lg, padding: Spacing.lg)
        .padding(.horizontal, Spacing.xl)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            switch story {
            case .connected:
                Circle()
                    .fill(Color.scSuccess)
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.scSuccess.opacity(0.7), radius: 4)
                    .scaleEffect(livePulse ? 1.4 : 1.0)
                    .opacity(livePulse ? 0.55 : 1.0)
                Text("Connected")
            case .looking:
                Text("Paired · looking for it…")
            case .unreachable:
                Text("Paired · not responding")
            case .neverPaired:
                EmptyView()
            }
        }
        .font(.scCaption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch story {
        case .looking:
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
        case .unreachable:
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.scWarning)
        case .connected, .neverPaired:
            EmptyView()
        }
    }

    private var forgetAction: some View {
        Button(role: .destructive) {
            showingForgetTVConfirmation = true
        } label: {
            Text("Forget This \(client.linkedClass.displayName)")
                .font(.scCaption)
                .foregroundStyle(Color.scDestructive)
        }
        .buttonStyle(.plain)
    }

    private func statusCard(
        icon: String,
        tint: Color,
        title: String,
        message: String,
        showsProgress: Bool = false,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                if showsProgress {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.3)
                        .tint(tint)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(height: 52)

            Text(title)
                .font(.scTitle2)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.scSubhead)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            action()
        }
        .frame(maxWidth: .infinity)
        .scCard(cornerRadius: Radius.lg, padding: Spacing.lg)
        .padding(.horizontal, Spacing.xl)
    }

    @ViewBuilder
    private var signInCard: some View {
        if showsSignIn {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.scAccent)
                    Text("Listen on This iPhone")
                        .font(.scTitle2)
                    Spacer()
                }

                Text("Sign in with your SoundCloud account to browse, search and play music here. The Apple TV remote keeps working either way.")
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)

                Button {
                    isSigningIn = true
                } label: {
                    Text("Sign In with SoundCloud")
                        .font(.scHeadline)
                        .foregroundStyle(Color.scAccentOn)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.scAccentGradient, in: Capsule())
                }
                .buttonStyle(BouncyPressStyle(reduceMotion: reduceMotion))
                .accessibilityHint("Signs in to SoundCloud on this iPhone")
            }
            .scCard(cornerRadius: Radius.lg, padding: Spacing.lg)
            .padding(.horizontal, Spacing.xl)
        }
    }

    private var outputPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Picker("Playing On", selection: outputBinding) {
                Label(PlaybackOutput.thisDevice.displayName, systemImage: PlaybackOutput.thisDevice.symbolName)
                    .tag(PlaybackOutput.thisDevice)
                ForEach(PlaybackOutput.deviceClassesWithCompanionServerToday, id: \.self) { deviceClass in
                    let output = PlaybackOutput.companion(deviceClass)
                    Label(output.displayName, systemImage: output.symbolName).tag(output)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isMovingSession)

            Text("Switching keeps your place. The track carries over rather than starting again.")
                .font(.scCaption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, Spacing.xs)
    }

    private var outputBinding: Binding<PlaybackOutput> {
        Binding(
            get: { coordinator.activeSource },
            set: { target in
                guard target != coordinator.activeSource, !isMovingSession else { return }
                isMovingSession = true
                Task {
                    await coordinator.moveSession(to: target)
                    isMovingSession = false
                }
            }
        )
    }

    private var nowPlayingSection: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            SCSectionHeader(title: "On Your \(client.linkedClass.displayName)", style: .phoneSectionHeader)
                .padding(.horizontal, Spacing.xl)

            VStack(alignment: .leading, spacing: 0) {
                if let playback = presentedPlayback, playback.trackId != nil {
                    SCArtworkResolver(url: playback.artworkURL.flatMap(URL.init(string:))) { image in
                        SCTrackRow(
                            title: playback.title ?? "Unknown Track",
                            subtitle: playback.artist ?? "Unknown Artist",
                            artworkImage: image,
                            crownUser: nil,
                            crownContext: playback.artist,
                            style: .phone
                        ) {
                            Image(systemName: playback.isPlaying ? "waveform" : "pause.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .symbolEffect(.variableColor.iterative, isActive: playback.isPlaying && !reduceMotion)
                        }
                    }
                } else {
                    HStack(spacing: Spacing.md) {
                        Image(systemName: "speaker.slash")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text("Nothing playing")
                            .font(.scSubhead)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Space.tight)
                }

                ScRowDivider(leading: 0)
                    .padding(.vertical, Space.tight)

                NavigationLink {
                    QueueManagerView()
                } label: {
                    HStack(spacing: Spacing.md) {
                        Image(systemName: "list.bullet.indent")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Queue")
                            .font(.scHeadline)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, Space.tight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .scCard(cornerRadius: Radius.lg, padding: Spacing.lg)
            .padding(.horizontal, Spacing.xl)
        }
    }

    private var djCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.scAccent)
                Text("Decks")
                    .font(.scTitle2)
                Spacer()
                djStatusPill
            }

            if client.isDJControlLive {
                NavigationLink {
                    DJControlView(client: client)
                } label: {
                    Text("Open Decks")
                        .font(.scHeadline)
                        .foregroundStyle(Color.scAccentOn)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.scAccentGradient, in: Capsule())
                }
                .buttonStyle(BouncyPressStyle(reduceMotion: reduceMotion))
            } else {
                Text("Mix live from your phone. EQ, filter, crossfader and jog wheels for both decks.")
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)

                Button {
                    if SettingsStore.shared.hasStoredValue(SettingKeys.DJStartOptions.self) {
                        coordinator.startDJSession(configuration: SettingsStore.shared.djStartConfiguration)
                        navigateToDJAfterEnabling = true
                    } else {
                        showingAutoDJStartConfiguration = true
                    }
                } label: {
                    Text("Turn On Decks")
                        .font(.scHeadline)
                        .foregroundStyle(Color.scAccentOn)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.scAccentGradient, in: Capsule())
                }
                .buttonStyle(BouncyPressStyle(reduceMotion: reduceMotion))
            }
        }
        .scCard(cornerRadius: Radius.lg, padding: Spacing.lg)
        .padding(.horizontal, Spacing.xl)
    }

    private var djStatusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(client.isDJControlLive ? Color.scSuccess : Color.scTextTertiary)
                .frame(width: 7, height: 7)
                .shadow(color: client.isDJControlLive ? Color.scSuccess.opacity(0.7) : .clear, radius: 4)
                .scaleEffect(client.isDJControlLive && livePulse ? 1.4 : 1.0)
                .opacity(client.isDJControlLive && livePulse ? 0.55 : 1.0)
            Text(client.isDJControlLive ? "Live" : "Off")
                .font(.scCaption)
                .foregroundStyle(.secondary)
        }
    }

    private var forgetFootnote: some View {
        Button(role: .destructive) {
            showingForgetTVConfirmation = true
        } label: {
            Text("Forget This \(client.linkedClass.displayName)")
                .font(.scSubhead)
                .foregroundStyle(Color.scDestructive)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.sm)
    }

    private func forgetAppleTV() {
        client.disconnect()
        LinkedCompanionStore.clear()
        client.connect()
    }
}

struct AppleTVBanner: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var linkOffers: LinkOfferBrowser
    @EnvironmentObject private var cloudOffers: CloudPairingOfferMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var livePulse = false

    private enum Mode: Equatable {
        case offer(String, DeviceClass)
        case connected
        case looking
        case unreachable
    }

    private var mode: Mode? {
        if !client.isLinked {
            if let offer = linkOffers.offer { return .offer(offer.displayIdentity, offer.kind) }
            if cloudOffers.hasOffer { return .offer("Your Apple TV", .tv) }
        }

        switch AppleTVDebugStory.forcedState ?? client.state {
        case .unlinked:                      return nil
        case .connected:                     return .connected
        case .idle, .searching, .connecting: return .looking
        case .failed:                        return .unreachable
        }
    }

    var body: some View {
        Group {
            if let mode {
                NavigationLink {
                    CompanionRootView()
                } label: {
                    row(mode)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Space.roomy)
                .padding(.bottom, Space.tight)
                .background(Color.scBgBase)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.scMotion(Motion.settle, reduceMotion: reduceMotion), value: mode)
        .task { client.connect() }
        .task {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                livePulse = true
            }
        }
    }

    private func row(_ mode: Mode) -> some View {
        HStack(spacing: Space.snug) {
            glyph(mode)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(title(mode))
                    .font(.scHeadline)
                    .foregroundStyle(Color.scTextPrimary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if mode == .connected {
                        Circle()
                            .fill(Color.scSuccess)
                            .frame(width: 6, height: 6)
                            .shadow(color: Color.scSuccess.opacity(0.7), radius: 4)
                            .scaleEffect(livePulse ? 1.4 : 1.0)
                            .opacity(livePulse ? 0.55 : 1.0)
                    }
                    Text(detail(mode))
                        .font(.scCaption)
                        .foregroundStyle(Color.scTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.scTextTertiary)
        }
        .padding(.horizontal, Space.base)
        .padding(.vertical, Space.snug)
        .background(
            RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                .fill(isOffer(mode) ? Color.scAccentMuted : Color.scBgRaised)
        )
        .contentShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens your \(client.linkedClass.displayName)'s connection, queue and Decks")
    }

    @ViewBuilder
    private func glyph(_ mode: Mode) -> some View {
        switch mode {
        case .looking:
            ProgressView()
                .controlSize(.small)
                .tint(Color.scTextSecondary)
        case .unreachable:
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.scWarning)
        case .offer(_, let kind):
            Image(systemName: kind.symbolName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.scAccent)
        case .connected:
            Image(systemName: client.linkedClass.symbolName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.scAccent)
        }
    }

    private func title(_ mode: Mode) -> String {
        switch mode {
        case .offer(let identity, _):            return "\(identity) wants to sign in"
        case .connected, .looking, .unreachable: return client.linkedClass.displayName
        }
    }

    private func detail(_ mode: Mode) -> String {
        switch mode {
        case .offer:
            return "Tap to check the code matches"
        case .connected:
            if let title = client.playback?.title, !title.isEmpty { return title }
            return "Connected"
        case .looking:
            return "Looking for it on your network…"
        case .unreachable:
            return "Not responding. Tap for options"
        }
    }

    private func isOffer(_ mode: Mode) -> Bool {
        if case .offer = mode { return true }
        return false
    }
}

struct NumericComparisonSheet: View {
    @ObservedObject var handshake: LinkConfirmationHandshake
    let onPaired: (String, Data) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                content
                Spacer()
            }
            .padding(Spacing.xl)
            .navigationTitle("Confirm Sign-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        handshake.decline()
                        dismiss()
                    }
                }
            }
            .onChange(of: handshake.state) { _, state in
                if case .succeeded(let sessionId, let secret, _) = state {
                    onPaired(sessionId, secret)
                }
            }
            .onAppear { handshake.start() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch handshake.state {
        case .idle, .connecting:
            ProgressView("Connecting…")

        case .awaitingComparison(let code):
            VStack(spacing: Spacing.lg) {
                Text("Does this match the code on \(handshake.claimedName)?")
                    .font(.scHeadline)
                    .multilineTextAlignment(.center)

                HStack(spacing: Spacing.sm) {
                    ForEach(Array(codeGroups(code).enumerated()), id: \.offset) { _, group in
                        Text(group)
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .tracking(3)
                            .monospacedDigit()
                            .foregroundStyle(Color.scTextPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                    .fill(Color.scBgRaised)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                    .stroke(Color.scAccent.opacity(0.38), lineWidth: 1)
                            }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Pairing code \(codeGroups(code).joined(separator: ", "))")

                Text("If it doesn't match, don't confirm. Something else on your network may be posing as this device.")
                    .font(.scCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: Spacing.sm) {
                    Button {
                        handshake.confirm()
                    } label: {
                        Text("Yes, It Matches")
                            .font(.scHeadline)
                            .foregroundStyle(Color.scAccentOn)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.scAccentGradient, in: Capsule())
                    }

                    Button(role: .destructive) {
                        handshake.decline()
                        dismiss()
                    } label: {
                        Text("It Doesn't Match")
                            .frame(maxWidth: .infinity)
                    }
                }
            }

        case .confirming, .succeeded:
            ProgressView("Signing in…")

        case .failed(let message):
            VStack(spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.scWarning)
                Text(message)
                    .font(.scSubhead)
                    .multilineTextAlignment(.center)
                Button("Close") { dismiss() }
            }

        case .declined:
            EmptyView()
        }
    }

    private func codeGroups(_ code: String) -> [String] {
        let digits = code.filter { $0.isNumber }
        guard digits.count == 6 else { return [code] }
        let midpoint = digits.index(digits.startIndex, offsetBy: 3)
        return [String(digits[..<midpoint]), String(digits[midpoint...])]
    }
}

struct BouncyPressStyle: ButtonStyle {
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55),
                value: configuration.isPressed
            )
    }
}
