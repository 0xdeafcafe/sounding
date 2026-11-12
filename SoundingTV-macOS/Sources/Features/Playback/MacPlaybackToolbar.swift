import SwiftUI
import AppKit

enum MacToolbarMetrics {
    static let edge: CGFloat = 8
    static let button: CGFloat = 37
    static let groupPadding: CGFloat = 6
    static let gap: CGFloat = 12
    static let clearance: CGFloat = 26
    static let windowControls: CGFloat = 140
    static let capsuleMin: CGFloat = 180
    static let capsuleFloor: CGFloat = 110
    static let capsuleMax: CGFloat = 440
    static let capsuleComfortable: CGFloat = 300
    static let title: CGFloat = 180
}

struct MacScrolledPageTitle: ToolbarContent {
    let title: String

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: MacToolbarMetrics.title, alignment: .leading)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

@MainActor
@Observable
final class MacPageTitleVisibility {
    static let shared = MacPageTitleVisibility()
    var isShowingPushedTitle = false
}

struct MacPlaybackToolbar: ToolbarContent {
    var capsuleWidth: CGFloat

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            MacTransportButton(kind: .previous)
            MacTransportButton(kind: .playPause)
            MacTransportButton(kind: .next)
        }

        ToolbarItem(placement: .principal) {
            MacNowPlayingCapsule(width: capsuleWidth)
        }
    }
}

private struct MacTransportButton: View {
    enum Kind { case previous, playPause, next }
    let kind: Kind

    private var model: MacNowPlayingModel { .shared }
    private var timeline: MacPlaybackTimeline { .shared }

    var body: some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .contentTransition(.symbolEffect(.replace))
        }
        .disabled(model.track == nil)
        .help(title)
    }

    private var title: String {
        switch kind {
        case .previous: return "Previous"
        case .next: return "Next"
        case .playPause: return timeline.isPlaying ? "Pause" : "Play"
        }
    }

    private var symbol: String {
        switch kind {
        case .previous: return "backward.fill"
        case .next: return "forward.fill"
        case .playPause: return timeline.isPlaying ? "pause.fill" : "play.fill"
        }
    }

    private func perform() {
        if let remote = MacPlaybackTarget.output {
            switch kind {
            case .previous: remote.previous()
            case .next: remote.next()
            case .playPause: remote.togglePlayPause()
            }
            return
        }
        switch kind {
        case .previous: Task { await InstantReplay.previous(PlayerService.shared) }
        case .next: Task { await PlayerService.shared.playNext() }
        case .playPause: timeline.togglePlayPause()
        }
    }
}

private struct MacToolbarItemSizeSync: NSViewRepresentable {
    var width: CGFloat

    func makeNSView(context: Context) -> SyncView { SyncView() }

    func updateNSView(_ nsView: SyncView, context: Context) {
        guard nsView.width != width else { return }
        nsView.width = width
        DispatchQueue.main.async { nsView.invalidateToolbarItem() }
    }

    final class SyncView: NSView {
        var width: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            invalidateToolbarItem()
        }

        func invalidateToolbarItem() {
            var ancestor = superview
            while let view = ancestor {
                view.invalidateIntrinsicContentSize()
                if String(describing: type(of: view)).contains("ToolbarItemViewer") {
                    view.superview?.needsLayout = true
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

struct MacNowPlayingCapsule: View {
    var width: CGFloat

    @Environment(\.outputRouter) private var outputRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var continueFrom = ContinueFrom.shared
    @ObservedObject private var presence = DevicePresenceModel.shared
    @State private var scrubTime: TimeInterval?
    @State private var isHovering = false

    private var model: MacNowPlayingModel { .shared }
    private var timeline: MacPlaybackTimeline { .shared }

    static let height: CGFloat = 38
    static let artworkSize: CGFloat = 30

    private var otherDevices: [DevicePresenceEntry] {
        presence.others(excludingOutput: true)
    }

    var body: some View {
        Group {
            if let track = model.track {
                playing(track)
            } else if let offer = continueFrom.offer ?? continueFrom.loading {
                offerCapsule(offer, isLoading: continueFrom.offer == nil)
            } else if let entry = presence.primary {
                presenceCapsule(entry, all: presence.entries)
            } else {
                idle
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: continueFrom.offer?.id)
        .animation(reduceMotion ? nil : .smooth, value: presence.primary?.id)
        .devicePresenceFailureAlert()
        .frame(width: width, height: Self.height)
        .contentShape(Capsule())
        .onChange(of: continueFrom.expandRequest) { _, _ in open() }
        .onHover { isHovering = $0 }
        .background(MacToolbarItemSizeSync(width: width))
    }

    private func playing(_ track: Track) -> some View {
        let duration = timeline.anchor.duration > 0 ? timeline.anchor.duration : track.duration
        let showsTimes = isHovering || scrubTime != nil
        return HStack(spacing: 8) {
            Button(action: open) {
                ArtworkThumbnail(
                    url: track.artworkURL,
                    identity: track.id,
                    size: Self.artworkSize,
                    cornerRadius: 7,
                    crownUser: track.user,
                    crownContext: track.title
                )
                .background(MacViewAnchor { MacNowPlayingPresentation.shared.capsuleArtworkView = $0 })
            }
            .buttonStyle(.plain)
            .help("Open Now Playing")
            .accessibilityLabel("Open Now Playing")

            VStack(spacing: 2) {
                Button(action: open) {
                    titleLine(track)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens Now Playing")

                HStack(spacing: 6) {
                    if showsTimes {
                        MacLiveClock(override: scrubTime) { position in
                            Text(macFormatTime(TrackTrimTimeline(trackID: track.id, duration: duration).elapsed(at: position)))
                        }
                    }
                    MacProgressScrubber(duration: duration, scrubTime: $scrubTime, restingThickness: 2)
                    if showsTimes {
                        MacLiveClock(override: scrubTime) { position in
                            Text(macFormatRemaining(current: TrackTrimTimeline(trackID: track.id, duration: duration).elapsed(at: position), duration: TrackTrimTimeline(trackID: track.id, duration: duration).length))
                        }
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(MacSecondaryStyle())
                .frame(height: 10)
            }

            if !otherDevices.isEmpty {
                presenceMenu(otherDevices)
            }
        }
        .padding(.leading, (Self.height - Self.artworkSize) / 2)
        .padding(.trailing, otherDevices.isEmpty ? Self.height / 2 : (Self.height - Self.artworkSize) / 2)
        .contextMenu {
            MacTrackContextMenu(track: track)
            DevicePresenceMenuItems(entries: otherDevices)
        }
    }

    private func presenceMenu(_ entries: [DevicePresenceEntry]) -> some View {
        let summary = DevicePresence.summary(localTitle: nil, others: entries, now: Date())
        return Menu {
            DevicePresenceMenuItems(entries: entries)
        } label: {
            DevicePresenceBadge(entries: entries, font: .subheadline)
                .frame(minWidth: Self.artworkSize, minHeight: Self.artworkSize)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(summary)
        .accessibilityLabel(summary)
        .accessibilityHint("Shows your other devices")
    }

    private func presenceCapsule(_ entry: DevicePresenceEntry, all: [DevicePresenceEntry]) -> some View {
        let now = Date()
        let summary = DevicePresence.summary(localTitle: nil, others: all, now: now)
        return Menu {
            DevicePresenceMenuItems(entries: all)
        } label: {
            HStack(spacing: 8) {
                ArtworkThumbnail(
                    url: entry.artworkURL,
                    identity: entry.trackID,
                    size: Self.artworkSize,
                    cornerRadius: 7,
                    crownContext: entry.artist
                )
                .opacity(entry.isLive ? 1 : 0.7)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: entry.deviceClass.symbolName)
                        Text(entry.caption(at: now))
                            .lineLimit(1)
                        if let more = DevicePresence.moreLabel(count: all.count) {
                            Text(more)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(MacSecondaryStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, (Self.height - Self.artworkSize) / 2)
            .padding(.trailing, Self.height / 2)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(summary)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
        .accessibilityLabel(summary)
        .accessibilityHint("Shows what you can do with it")
    }

    private func titleLine(_ track: Track) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                subtitle(track)
                    .font(.subheadline)
                    .foregroundStyle(MacSecondaryStyle())
            }
            .fixedSize()

            Text(track.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .truncationMode(.tail)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func subtitle(_ track: Track) -> some View {
        if let outputRouter {
            MacRouteSubtitle(router: outputRouter, artist: track.user.displayName)
        } else {
            Text(track.user.displayName)
        }
    }

    private func offerCapsule(_ offer: ContinueFrom.Offer, isLoading: Bool) -> some View {
        let title = offer.session.title.isEmpty ? "Continue from \(offer.deviceName)" : offer.session.title
        return HStack(spacing: 8) {
            ArtworkThumbnail(
                url: offer.session.artworkURL,
                identity: offer.session.trackID,
                size: Self.artworkSize,
                cornerRadius: 7,
                crownContext: offer.session.artist
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Label {
                    Text(offer.miniCaption)
                } icon: {
                    Image(systemName: offer.session.deviceClass.symbolName)
                }
                .font(.caption2)
                .foregroundStyle(MacSecondaryStyle())
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    continueFrom.accept(offer, play: true)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help("Play Here")
                .accessibilityLabel("Play Here")
            }
        }
        .padding(.leading, (Self.height - Self.artworkSize) / 2)
        .padding(.trailing, (Self.height - Self.artworkSize) / 2)
        .contentShape(Capsule())
        .onTapGesture {
            guard !isLoading else { return }
            continueFrom.accept(offer, expand: true)
        }
        .contextMenu {
            if !isLoading {
                Button("Not Now", systemImage: "xmark") { continueFrom.dismiss(offer) }
                DevicePresenceMenuItems(entries: presence.entries)
            }
        }
        .help("Open \(title) here, paused")
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(offer.miniCaption)")
        .accessibilityHint("Opens Now Playing, paused")
    }

    private static let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    private var idle: some View {
        HStack(spacing: 8) {
            Image(nsImage: Self.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text("Sounding")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MacSecondaryStyle())
        }
        .frame(maxWidth: .infinity)
    }

    private func open() {
        MacNowPlayingPresentation.shared.present()
    }
}

private struct MacRouteSubtitle: View {
    @ObservedObject var router: OutputRouter
    let artist: String

    var body: some View {
        if router.isRemote {
            MacRemoteRouteLabel(device: router.current, client: router.client, telemetry: router.client.telemetry)
        } else {
            Text(artist)
        }
    }
}

private struct MacRemoteRouteLabel: View {
    let device: OutputDevice
    @ObservedObject var client: CompanionClient
    @ObservedObject var telemetry: CompanionTelemetry

    var body: some View {
        if let caption = client.refusalCaption {
            Label(caption, systemImage: "exclamationmark.circle")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        } else {
            phaseLabel
        }
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch client.connectionPhase {
        case .live:
            Label("Playing on \(device.name)", systemImage: device.symbolName)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.scAccent)
        case .connecting:
            Label("Connecting to \(device.name)…", systemImage: device.symbolName)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        case .unreachable:
            Label("\(device.name) isn’t reachable", systemImage: "wifi.exclamationmark")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        }
    }
}

struct MacToolbarPlayOn: View {
    @Environment(\.outputRouter) private var outputRouter

    var body: some View {
        if let outputRouter {
            MacConnectButton(router: outputRouter)
        }
    }
}

struct MacPlayOnMenu: View {
    enum Style { case toolbar, pill }

    @ObservedObject var router: OutputRouter
    var style: Style

    @Environment(\.openSettings) private var openSettings
    @State private var errorMessage: String?

    var body: some View {
        menu
            .help(router.isRemote ? "Playing on \(router.current.name)" : "Play On")
            .accessibilityLabel("Play On")
            .accessibilityValue(router.isRemote ? router.current.name : "This Mac")
            .alert("Couldn’t Move Playback", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var menu: some View {
        switch style {
        case .toolbar:
            Menu {
                items
            } label: {
                Label("Play On", systemImage: router.isRemote ? router.current.symbolName : "airplay.audio")
            }
            .menuIndicator(.hidden)
            .foregroundStyle(router.isRemote ? Color.scAccent : Color.primary)
        case .pill:
            Menu {
                items
            } label: {
                Label(router.isRemote ? router.current.name : "This Mac", systemImage: "airplay.audio")
                    .font(.subheadline.weight(.semibold))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var items: some View {
        Section("Play On") {
            ForEach(router.devices) { device in
                Toggle(isOn: Binding(
                    get: { router.current == device },
                    set: { selected in
                        guard selected else { return }
                        Task { errorMessage = await router.move(to: device) }
                    }
                )) {
                    Label(device.isLocal ? "This Mac" : device.name, systemImage: device.symbolName)
                }
                .disabled(!router.isReachable(device) || router.isMoving)
            }
        }
        if router.linkedDevice == nil {
            Section {
                Button("Add Apple TV…") {
                    MacSettingsNavigation.shared.selection = .devices
                    openSettings()
                }
            }
        }
    }
}

struct MacVolumeSlider: View {
    var showsEndCaps: Bool

    @Environment(\.outputRouter) private var outputRouter
    @ObservedObject private var sonos = SonosOutputController.shared

    private var volume: MacSystemVolume { .shared }

    var body: some View {
        if sonos.isActive {
            slider(
                value: Binding(get: { sonos.volume }, set: { sonos.setVolume($0) }),
                enabled: true,
                help: "\(sonos.activeGroup?.displayName ?? "Sonos") Volume",
                onEditingChanged: { editing in
                    if editing { sonos.beginVolumeChange() } else { sonos.endVolumeChange() }
                }
            )
        } else if let outputRouter {
            OutputModesReader(outputRouter) { router in
                if !router.isRemote {
                    systemSlider
                } else if let level = router.client.volume {
                    slider(
                        value: Binding(get: { level }, set: { router.client.setVolume($0) }),
                        enabled: router.client.isReachable,
                        help: "\(router.current.name) Volume",
                        onEditingChanged: { editing in
                            if editing { router.client.beginVolumeChange() } else { router.client.endVolumeChange() }
                        }
                    )
                }
            }
        } else {
            systemSlider
        }
    }

    private var systemSlider: some View {
        slider(
            value: Binding(get: { volume.volume }, set: { volume.set($0) }),
            enabled: volume.isAvailable,
            help: "Volume"
        )
        .task { volume.start() }
    }

    private func slider(
        value: Binding<Double>,
        enabled: Bool,
        help: String,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        HStack(spacing: 6) {
            if showsEndCaps {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(MacSecondaryStyle())
                    .accessibilityHidden(true)
            } else {
                Image(systemName: Self.symbol(for: value.wrappedValue))
                    .font(.callout)
                    .foregroundStyle(MacSecondaryStyle())
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            Slider(value: value, in: 0...1, onEditingChanged: onEditingChanged)
                .controlSize(showsEndCaps ? .small : .mini)
                .labelsHidden()
            if showsEndCaps {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(MacSecondaryStyle())
                    .accessibilityHidden(true)
            }
        }
        .disabled(!enabled)
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(help)
    }

    private static func symbol(for level: Double) -> String {
        switch level {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

struct MacUpNextToggle: View {
    @Binding var selection: MacNowPlayingPane?

    var body: some View {
        Toggle(isOn: Binding(
            get: { selection != nil },
            set: { selection = $0 ? .queue : nil }
        )) {
            Label(MacNowPlayingPane.queue.title, systemImage: MacNowPlayingPane.queue.systemImage)
        }
        .toggleStyle(.button)
        .help(selection == nil ? "Show Up Next" : "Hide Up Next")
        .accessibilityValue(selection == nil ? "Hidden" : "Shown")
    }
}

enum MacTrackActionStyle { case toolbar, circle }

struct MacActionGlyph: ViewModifier {
    let style: MacTrackActionStyle

    func body(content: Content) -> some View {
        switch style {
        case .toolbar:
            content
        case .circle:
            content
                .labelStyle(.iconOnly)
                .frame(width: 22, height: 22)
        }
    }
}

struct MacLikeButton: View {
    let track: Track
    var style: MacTrackActionStyle

    @ObservedObject private var engagement = MacTrackEngagement.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let liked = engagement.isLiked(track)
        let button = Button {
            Task { await engagement.toggleLike(track) }
        } label: {
            Label(liked ? "Unlike" : "Like", systemImage: liked ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : liked)
                .modifier(MacActionGlyph(style: style))
        }
        .disabled(engagement.isPending(track))
        .help(liked ? "Unlike" : "Like")
        .accessibilityValue(liked ? "Liked" : "Not liked")

        switch style {
        case .toolbar:
            button
        case .circle:
            button
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
        }
    }
}

struct MacMoreMenu: View {
    let track: Track
    var style: MacTrackActionStyle
    let showPane: (MacNowPlayingPane) -> Void

    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var setlists = SetlistIntelligenceStore.shared
    @ObservedObject private var listenTogether = ListenTogether.shared

    var body: some View {
        let menu = Menu {
            content
        } label: {
            Label("More", systemImage: "ellipsis")
                .modifier(MacActionGlyph(style: style))
        }
        .menuIndicator(.hidden)
        .help("More")

        switch style {
        case .toolbar:
            menu
        case .circle:
            menu
                .labelStyle(.iconOnly)
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var content: some View {
        if track.supportsSoundCloudActions {
            ListenTogetherShareLink(url: track.permalinkURL, trackID: track.id, title: track.title) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            if track.id == player.currentTrack?.id || listenTogether.isActive {
                ListenTogetherMenuItems()
            }
        }
        MacAddToPlaylistMenuButton(track: track)
        Divider()
        Button {
            showPane(.tracklist)
        } label: {
            Label(tracklistTitle, systemImage: "music.note.list")
        }
        Button {
            showPane(.about)
        } label: {
            Label("Behind the Track", systemImage: "info.circle")
        }
        Divider()
        Toggle(isOn: Binding(
            get: { isAutoMixOn && !listenTogether.isActive },
            set: { enabled in
                if enabled {
                    MacNowPlayingPresentation.shared.showsAutoMixSetup = true
                } else {
                    player.endDJSession()
                }
            }
        )) {
            Label("Auto Mix", systemImage: "infinity")
        }
        .disabled(listenTogether.isActive)
        .help(listenTogether.isActive ? "Off during SharePlay" : "")
        Button {
            MacRootSelection.shared.request(.console)
        } label: {
            Label("Decks", systemImage: "slider.horizontal.3")
        }
        if isAutoMixOn {
            MixSaveLatestButton(title: "Save Last Mix", iconOnly: false)
        }
        Divider()
        MacSleepTimerMenu(trackID: track.id)
        if player.queue.count > player.currentIndex + 1 {
            Divider()
            Button("Clear Up Next", role: .destructive) { player.clearQueue() }
        }
    }

    private var tracklistTitle: String {
        guard let count = setlists.tracklist(for: track.id)?.entries.count, count > 0 else { return "Tracklist" }
        return "Tracklist · \(count) Tracks"
    }

    private var isAutoMixOn: Bool {
        player.djDirector.snapshot?.isAutoMixEnabled ?? player.isAutoMixEnabled
    }
}

struct MacSleepTimerMenu: View {
    let trackID: String?

    @Environment(\.outputRouter) private var outputRouter
    @ObservedObject private var timer = SleepTimer.shared

    var body: some View {
        if let outputRouter {
            CompanionTelemetryReader(outputRouter.client.telemetry) { _ in
                picker(status: outputRouter.sleepTimer) { outputRouter.setSleepTimer($0) }
            }
        } else {
            picker(status: timer.status) { mode in
                if let mode { timer.start(mode) } else { timer.cancel() }
            }
        }
    }

    private func picker(status: SleepTimerStatus?, select: @escaping (SleepTimerMode?) -> Void) -> some View {
        SleepTimerPicker(
            status: status,
            offersEndOfMix: SleepTimer.offersEndOfMix(trackID: trackID),
            onSelect: select
        )
    }
}

struct MacSleepTimerBadge: View {
    @Environment(\.outputRouter) private var outputRouter
    @ObservedObject private var timer = SleepTimer.shared

    var body: some View {
        if let outputRouter {
            CompanionTelemetryReader(outputRouter.client.telemetry) { _ in
                badge(outputRouter.sleepTimer)
            }
        } else {
            badge(timer.status)
        }
    }

    @ViewBuilder
    private func badge(_ status: SleepTimerStatus?) -> some View {
        if let status {
            SleepTimerIndicator(status: status)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }
}

struct MacShuffleToggle: View {
    @Environment(\.outputRouter) private var outputRouter
    @ObservedObject private var player = PlayerService.shared

    var body: some View {
        if let outputRouter {
            OutputModesReader(outputRouter) { router in
                toggle(isOn: router.isShuffleEnabled, enabled: router.canChangePlaybackModes) {
                    router.toggleShuffle()
                }
            }
        } else {
            toggle(isOn: player.isShuffleEnabled, enabled: true) {
                player.toggleShuffle()
            }
        }
    }

    private func toggle(isOn: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            Label("Shuffle", systemImage: "shuffle")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .disabled(!enabled)
        .help("Shuffle")
        .accessibilityLabel("Shuffle")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct MacRepeatToggle: View {
    @Environment(\.outputRouter) private var outputRouter
    @ObservedObject private var player = PlayerService.shared

    var body: some View {
        if let outputRouter {
            OutputModesReader(outputRouter) { router in
                toggle(mode: router.repeatMode, enabled: router.canChangePlaybackModes) {
                    router.cycleRepeatMode()
                }
            }
        } else {
            toggle(mode: player.repeatMode, enabled: true) {
                player.repeatMode = Self.next(after: player.repeatMode)
            }
        }
    }

    private func toggle(mode: RepeatMode, enabled: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { mode.isActive }, set: { _ in action() })) {
            Label("Repeat", systemImage: mode.icon)
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .disabled(!enabled)
        .help("Repeat")
        .accessibilityLabel("Repeat")
        .accessibilityValue(Self.value(mode))
    }

    static func value(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "One"
        }
    }

    static func next(after mode: RepeatMode) -> RepeatMode {
        switch mode {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

private struct OutputRouterKey: EnvironmentKey {
    static var defaultValue: OutputRouter? { nil }
}

extension EnvironmentValues {
    var outputRouter: OutputRouter? {
        get { self[OutputRouterKey.self] }
        set { self[OutputRouterKey.self] = newValue }
    }
}

enum InstantReplay {
    static let threshold: TimeInterval = 3

    @MainActor
    static func previous(_ player: PlayerService) async {
        if MacPlaybackTimeline.shared.position() > threshold {
            MacPlaybackTimeline.shared.seek(to: 0)
        } else {
            await player.playPrevious()
        }
    }
}

struct ArtworkThumbnail: View {
    var candidates: [URL]
    var identity: String = ""
    var size: CGFloat = 40
    var cornerRadius: CGFloat = 5
    var isAvailable: Bool = true
    var crownUser: User?
    var crownContext: String?

    @State private var loaded: SCResolvedArtwork?
    @State private var settled: [URL]?

    private struct Request: Hashable {
        let candidates: [URL]
        let variant: ArtworkVariant
    }

    init(
        url: URL?, identity: String = "", size: CGFloat = 40,
        cornerRadius: CGFloat = 5, isAvailable: Bool = true,
        crownUser: User? = nil, crownContext: String? = nil
    ) {
        self.candidates = url.map { [$0] } ?? []
        self.identity = identity
        self.size = size
        self.cornerRadius = cornerRadius
        self.isAvailable = isAvailable
        self.crownUser = crownUser
        self.crownContext = crownContext
    }

    init(
        candidates: [URL], identity: String = "", size: CGFloat = 40,
        cornerRadius: CGFloat = 5, isAvailable: Bool = true,
        crownUser: User? = nil, crownContext: String? = nil
    ) {
        self.candidates = candidates
        self.identity = identity
        self.size = size
        self.cornerRadius = cornerRadius
        self.isAvailable = isAvailable
        self.crownUser = crownUser
        self.crownContext = crownContext
    }

    private var variant: ArtworkVariant { size <= 64 ? .thumbnail : .standard }

    private var lookups: ArraySlice<URL> { candidates.prefix(4) }

    private var displayed: NSImage? {
        let variant = variant
        if let loaded, lookups.contains(loaded.url), loaded.variant == variant { return loaded.image }
        for url in lookups {
            if let hit = ArtworkCache.shared.bestCachedImage(for: url, variant: variant) { return hit }
        }
        return nil
    }

    var body: some View {
        let displayed = displayed
        SCArtwork(
            image: displayed.map { Image(nsImage: $0) },
            identity: identity.isEmpty ? candidates.first?.absoluteString ?? "" : identity,
            isAvailable: isAvailable,
            style: .mac,
            cornerRadius: cornerRadius,
            subject: cornerRadius * 2 >= size ? .person : .track
        )
        .environment(\.soundingArtworkPending, displayed == nil && !candidates.isEmpty && settled != candidates)
        .frame(width: size, height: size)
        .kyleCrowned(user: crownUser, context: crownContext)
        .accessibilityHidden(true)
        .task(id: Request(candidates: candidates, variant: variant)) {
            await load()
        }
    }

    private func load() async {
        let variant = variant
        let urls = Array(lookups)
        if let loaded, urls.contains(loaded.url), loaded.variant == variant { return }
        for url in urls {
            if let exact = ArtworkCache.shared.cachedImage(for: url, variant: variant) {
                scWithoutAnimation { loaded = SCResolvedArtwork(url: url, variant: variant, image: exact) }
                return
            }
        }
        for url in urls {
            let image = await ArtworkCache.shared.image(for: url, variant: variant)
            guard !Task.isCancelled else { return }
            if let image {
                scWithoutAnimation {
                    loaded = SCResolvedArtwork(url: url, variant: variant, image: image)
                    settled = candidates
                }
                return
            }
        }
        scWithoutAnimation { settled = candidates }
    }
}
