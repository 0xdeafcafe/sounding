import SwiftUI

@MainActor
final class RemoteRequest: ObservableObject {
    static let shared = RemoteRequest()
    static let tabSymbol = "appletvremote.gen4"

    @Published private(set) var request: UUID?

    func open() {
        request = UUID()
    }
}

struct RemoteControlView: View {
    @ObservedObject var client: CompanionClient
    var sessionId: String?
    var router: OutputRouter?
    var onAddDevice: (() -> Void)?

    init(
        client: CompanionClient,
        sessionId: String? = nil,
        router: OutputRouter? = nil,
        onAddDevice: (() -> Void)? = nil
    ) {
        self.client = client
        self.sessionId = sessionId
        self.router = router
        self.onAddDevice = onAddDevice
    }

    var body: some View {
        CompanionTelemetryReader(client.telemetry) { telemetry in
            content(telemetry)
        }
        .navigationTitle(title)
        .task(id: sessionId) {
            if let sessionId {
                client.select(sessionId: sessionId)
            } else {
                client.connect()
            }
        }
    }

    private var title: String {
        guard client.isLinked else { return "Remote" }
        #if os(macOS)
        return "\(client.linkedName) Remote"
        #else
        return client.linkedName
        #endif
    }

    private var linkStatus: RemoteLinkStatus {
        if client.state == .unlinked { return .unlinked }
        if client.state == .connected { return .connected }
        if case .failed = client.state { return .unreachable }
        return .connecting
    }

    private var failureMessage: String {
        guard case .failed(let failure) = client.state else { return CompanionFailure.notFound.message() }
        return failure.message()
    }

    @ViewBuilder
    private func content(_ telemetry: CompanionTelemetry) -> some View {
        let link = linkStatus
        let phase = RemotePhase.resolve(
            link: link == .connected && !telemetry.isLive && !client.peerNeedsSignIn ? .connecting : link,
            peerNeedsSignIn: client.peerNeedsSignIn,
            hasPlayback: telemetry.claimsTrack(),
            isLive: telemetry.isLive
        )
        switch phase {
        case .unlinked:
            ContentUnavailableView {
                Label("No Apple TV", systemImage: DeviceClass.tv.symbolName)
            } description: {
                Text("Link an Apple TV to control it from here.")
            } actions: {
                if let onAddDevice {
                    Button("Add Apple TV…", action: onAddDevice)
                }
            }
        case .connecting:
            ProgressView("Connecting to \(client.linkedName)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unreachable:
            ContentUnavailableView {
                Label("\(client.linkedName) Isn’t Reachable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(failureMessage)
            } actions: {
                Button("Try Again") { client.retry() }
            }
        case .needsSignIn:
            ContentUnavailableView {
                Label("\(client.linkedName) Needs Sign-In", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("Sign in to control it from here.")
            } actions: {
                Button("Sign In This \(client.linkedClass.displayName)") { client.requestPeerSignIn() }
                    .disabled(client.isRequestingPeerSignIn)
            }
        case .nothingPlaying:
            RemoteIdleForm(client: client, router: router)
        case .playing(let isLive):
            if let playback = telemetry.playback {
                RemoteControlForm(client: client, telemetry: telemetry, playback: playback, isLive: isLive)
            }
        }
    }
}

private struct RemoteControlForm: View {
    @ObservedObject var client: CompanionClient
    @ObservedObject var telemetry: CompanionTelemetry
    let playback: PlaybackStatePayload
    let isLive: Bool

    private let likes = NowPlayingLikeModel.shared

    var body: some View {
        Form {
            Section {
                VStack(spacing: 18) {
                    RemoteNowPlayingHeader(playback: playback, artworkURL: artworkURL)
                    RemoteScrubber(client: client, telemetry: telemetry, isLive: isLive)
                    RemoteTransport(client: client, isPlaying: playback.isPlaying, isLive: isLive)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            } footer: {
                if !isLive {
                    Text("Reconnecting…")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }

            if isLive, client.volume != nil {
                Section {
                    RemoteVolumeRow(client: client)
                }
            }

            let upNext = client.upNext
            if !upNext.isEmpty {
                let layout = client.upNextLayout
                if !layout.playingNext.isEmpty {
                    Section {
                        queueRows(upNext, layout.playingNext)
                    } header: {
                        Text("Playing Next")
                    } footer: {
                        if layout.autoMixPick == nil, isAutoMixOn { Text("Plays before Auto Mix") }
                    }
                }
                if let pick = layout.autoMixPick {
                    Section {
                        queueRows(upNext, pick..<(pick + 1))
                    } header: {
                        Label("Auto Mix", systemImage: "arrow.triangle.merge")
                    }
                }
                if !layout.continuePlaying.isEmpty {
                    Section(layout.continuePlaying.count == upNext.count ? "Up Next" : "Continue Playing") {
                        queueRows(upNext, layout.continuePlaying)
                    }
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: PhoneChrome.floatingClearance) }
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                likeButton
            }
        }
        .task(id: playback.trackId) {
            likes.refresh(trackId: playback.trackId, resolved: nil)
        }
        .onReceive(LikesSyncEngine.shared.$revision.dropFirst()) { _ in
            likes.refresh(trackId: playback.trackId, resolved: nil)
        }
    }

    private var isAutoMixOn: Bool {
        telemetry.autoMixLive != nil || telemetry.djState?.isAutoMixEnabled == true
    }

    private func queueRows(_ entries: [(index: Int, track: QueueTrack)], _ range: Range<Int>) -> some View {
        ForEach(entries[range], id: \.index) { entry in
            RemoteQueueRow(client: client, index: entry.index, track: entry.track, isLive: isLive)
        }
    }

    private var artworkURL: URL? {
        if let raw = playback.artworkURL, let url = URL(string: raw) { return url }
        guard let trackId = playback.trackId else { return nil }
        return client.tracks.first { $0.id == trackId }?.artworkURL
    }

    private var likeButton: some View {
        let isLiked = playback.trackId.map { likes.isLiked($0, resolved: nil) } ?? false
        return Button {
            guard let trackId = playback.trackId else { return }
            likes.toggle(trackId: trackId, resolved: nil)
        } label: {
            Label(isLiked ? "Remove from Likes" : "Add to Likes", systemImage: isLiked ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
        }
        .disabled(playback.trackId == nil)
        .help(isLiked ? "Remove from Likes" : "Add to Likes")
        .sensoryFeedback(.impact(weight: .light), trigger: isLiked)
    }
}

private struct RemoteIdleForm: View {
    @ObservedObject var client: CompanionClient
    let router: OutputRouter?

    @ObservedObject private var recent = RecentlyPlayed.shared
    @State private var starting: String?
    @State private var failure: String?

    private var name: String { client.linkedName }

    private var device: OutputDevice? {
        router?.remoteTarget ?? client.linkedOutputDevice
    }

    private var recentTracks: [Track] {
        Array(recent.items.map(\.track).filter { !$0.isLocal }.prefix(Self.recentLimit))
    }

    private static let recentLimit = 8
    private static let likesSample = 200

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: client.linkedClass.symbolName)
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Nothing Playing on \(name)")
                        .font(.title3.weight(.semibold))
                    Text("Choose something below to play it there.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }

            if let router, let device {
                Section {
                    if let track = router.localResumableTrack {
                        startButton(id: "resume", title: "Resume on \(name)", subtitle: track.title, systemImage: "play.fill") {
                            await router.resumeThisDevice(on: device)
                        }
                    }
                    startButton(id: "likes", title: "Shuffle Likes", subtitle: nil, systemImage: "shuffle") {
                        await shuffleLikes(router: router, device: device)
                    }
                } footer: {
                    if let failure {
                        Text(failure)
                    }
                }

                let tracks = recentTracks
                if !tracks.isEmpty {
                    Section("Recently Played") {
                        ForEach(tracks) { track in
                            Button {
                                start(id: track.id) { await router.play(track, in: tracks, on: device) }
                            } label: {
                                HStack(spacing: 12) {
                                    RemoteArtwork(url: track.artworkURL, identity: track.id, size: 44, cornerRadius: 6)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(track.user.displayName)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    if starting == track.id { ProgressView() }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(starting != nil)
                            .accessibilityHint("Plays it on \(name)")
                        }
                    }
                }
            }

            Section {
                if client.volume != nil {
                    RemoteVolumeRow(client: client)
                }
                RemoteTransport(client: client, isPlaying: false, isLive: false)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } footer: {
                Text("Play, pause and skip work once something is playing on \(name).")
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: PhoneChrome.floatingClearance) }
        #endif
    }

    private func startButton(
        id: String,
        title: String,
        subtitle: String?,
        systemImage: String,
        action: @escaping () async -> String?
    ) -> some View {
        Button {
            start(id: id, action)
        } label: {
            HStack {
                Label {
                    Text(title)
                    if let subtitle { Text(subtitle) }
                } icon: {
                    Image(systemName: systemImage)
                }
                Spacer(minLength: 8)
                if starting == id { ProgressView() }
            }
        }
        .disabled(starting != nil)
    }

    private func start(id: String, _ action: @escaping () async -> String?) {
        guard starting == nil else { return }
        starting = id
        failure = nil
        Task { @MainActor in
            failure = await action()
            starting = nil
        }
    }

    private func shuffleLikes(router: OutputRouter, device: OutputDevice) async -> String? {
        let page = await LibraryDB.tracks(.likes, offset: 0, limit: Self.likesSample)
        let tracks = page.tracks.filter { !$0.isLocal }
        guard let pick = tracks.randomElement() else { return "Your Likes aren't on this \(DeviceClass.current.displayName) yet." }
        let rest = tracks.filter { $0.id != pick.id }.shuffled()
        return await router.play(pick, in: [pick] + rest, on: device, source: .likes)
    }
}

private struct RemoteVolumeRow: View {
    @ObservedObject var client: CompanionClient

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(
                value: Binding(get: { client.volume ?? 0 }, set: { client.setVolume($0) }),
                in: 0...1,
                onEditingChanged: { editing in
                    editing ? client.beginVolumeChange() : client.endVolumeChange()
                }
            )
            .labelsHidden()
            .accessibilityLabel("\(client.linkedName) Volume")
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .disabled(!client.isReachable)
    }
}

private struct RemoteNowPlayingHeader: View {
    let playback: PlaybackStatePayload
    let artworkURL: URL?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 14) {
            RemoteHeroArtwork(
                url: artworkURL,
                identity: playback.trackId ?? playback.title ?? "remote",
                size: dynamicTypeSize.isAccessibilitySize ? 140 : 200,
                cornerRadius: 12
            )
            .scaleEffect(playback.isPlaying ? 1 : 0.94)
            .animation(.smooth, value: playback.isPlaying)

            VStack(spacing: 4) {
                Text(playback.title ?? "Unknown Track")
                    .font(.title3.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                Text(playback.artist ?? "Unknown Artist")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct RemoteScrubber: View {
    @ObservedObject var client: CompanionClient
    @ObservedObject var telemetry: CompanionTelemetry
    let isLive: Bool

    @State private var scrub: Double?

    var body: some View {
        let duration = max(1, telemetry.playback?.durationSeconds ?? 0)
        let isAdvancing = isLive && telemetry.playback?.isPlaying == true && scrub == nil
        TimelineView(.animation(minimumInterval: 0.5, paused: !isAdvancing)) { context in
            let position = min(duration, scrub ?? telemetry.estimatedPosition(at: context.date))
            VStack(spacing: 4) {
                Slider(
                    value: Binding(get: { position }, set: { scrub = $0 }),
                    in: 0...duration,
                    onEditingChanged: { editing in
                        guard !editing, let target = scrub else { return }
                        client.seek(toSeconds: target)
                        scrub = nil
                    }
                )
                .labelsHidden()
                .disabled(!isLive)
                .accessibilityLabel("Position")
                .accessibilityValue("\(remoteSpokenTime(position)) of \(remoteSpokenTime(duration))")

                HStack {
                    Text(remoteFormatTime(position))
                    Spacer()
                    Text("−" + remoteFormatTime(max(0, duration.rounded(.down) - position.rounded(.down))))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct RemoteTransport: View {
    @ObservedObject var client: CompanionClient
    let isPlaying: Bool
    let isLive: Bool

    var body: some View {
        HStack(spacing: 44) {
            Button { client.previous() } label: {
                Label("Previous", systemImage: "backward.fill")
                    .font(.title)
            }
            Button { client.togglePlayPause() } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .font(.largeTitle)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 52, height: 52)
            }
            Button { client.next() } label: {
                Label("Next", systemImage: "forward.fill")
                    .font(.title)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .frame(minHeight: 52)
        .disabled(!isLive)
        .sensoryFeedback(.selection, trigger: isPlaying)
    }
}

private struct RemoteQueueRow: View {
    @ObservedObject var client: CompanionClient
    let index: Int
    let track: QueueTrack
    let isLive: Bool

    var body: some View {
        Button { client.jump(to: index) } label: {
            HStack(spacing: 12) {
                RemoteArtwork(url: track.artworkURL, identity: track.id, size: 44, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(track.formattedDuration)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isLive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(track.title), \(track.artist), \(track.formattedDuration)")
        .accessibilityHint("Plays this track")
        .accessibilityAction(named: "Play Next") { client.playNext(queueIndex: index) }
        .accessibilityAction(named: "Remove from Up Next") { client.remove(at: index) }
        .libraryRowPreviewShape()
        .contextMenu {
            Button { client.playNext(queueIndex: index) } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            Button(role: .destructive) { client.remove(at: index) } label: {
                Label("Remove from Up Next", systemImage: "minus.circle")
            }
        }
        .swipeActions(edge: .leading) {
            Button { client.playNext(queueIndex: index) } label: {
                Label("Play Next", systemImage: "text.insert")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { client.remove(at: index) } label: {
                Label("Remove", systemImage: "minus.circle")
            }
        }
    }
}

private struct RemoteArtwork: View {
    let url: URL?
    let identity: String
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        #if os(macOS)
        ArtworkThumbnail(url: url, identity: identity, size: size, cornerRadius: cornerRadius)
        #else
        ArtworkThumbnail(url: url, size: size, cornerRadius: cornerRadius, identity: identity)
        #endif
    }
}

private struct RemoteHeroArtwork: View {
    let url: URL?
    let identity: String
    let size: CGFloat
    let cornerRadius: CGFloat

    #if os(macOS)
    var body: some View {
        RemoteArtwork(url: url, identity: identity, size: size, cornerRadius: cornerRadius)
    }
    #else
    @State private var loaded: (url: URL, image: UIImage)?

    private var thumbnailURL: URL? { url?.soundCloudArtworkVariant("t200x200") }

    private var image: UIImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return ArtworkCache.shared.cachedImage(for: url, variant: .standard)
            ?? thumbnailURL.flatMap { ArtworkCache.shared.cachedImage(for: $0, variant: .thumbnail) }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                SoundingArtworkView(identity: identity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { return }
            if let full = await ArtworkCache.shared.image(for: url, variant: .standard) {
                loaded = (url, full)
            } else if let thumbnailURL, let small = await ArtworkCache.shared.image(for: thumbnailURL, variant: .thumbnail) {
                loaded = (url, small)
            }
        }
    }
    #endif
}

func remoteFormatTime(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    guard hours > 0 else { return String(format: "%d:%02d", minutes, secs) }
    return String(format: "%d:%02d:%02d", hours, minutes, secs)
}

private func remoteSpokenTime(_ seconds: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
    formatter.unitsStyle = .full
    return formatter.string(from: max(0, seconds.rounded(.down))) ?? remoteFormatTime(seconds)
}
