import SwiftUI

struct WatchNowPlayingView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @ObservedObject private var playback = WatchPlayback.shared
    @ObservedObject private var store = WatchOfflineStore.shared
    @ObservedObject private var theme = WatchNowPlayingTheme.shared
    @ObservedObject private var details = WatchNowPlayingDetails.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase

    @State private var scrubPosition: Double = 0
    @State private var lastSyncedPosition: Double = 0
    @State private var isScrubbing = false
    @State private var scrubCommitTask: Task<Void, Never>?
    @State private var crownVolume: Double = 0
    @State private var isAdjustingVolume = false
    @State private var volumeHideTask: Task<Void, Never>?
    @FocusState private var isCrownFocused: Bool

    private var secondaryStyle: HierarchicalShapeStyle {
        contrast == .increased ? .primary : .secondary
    }

    private var tickInterval: TimeInterval {
        isLuminanceReduced || scenePhase != .active || !playback.nowPlaying.isPlaying ? 60 : 1
    }

    private var usesScrollLayout: Bool {
        dynamicTypeSize >= .xxLarge
    }

    private var isRemoteOutput: Bool {
        playback.nowPlaying.isRemoteOutput
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: tickInterval)) { context in
            screen(at: context.date)
        }
        .navigationTitle(Text(verbatim: playback.nowPlaying.displayOutputName))
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.palette.tint)
        .preferredColorScheme(.dark)
        .toolbar { toolbarItems }
        .task(id: playback.nowPlaying.artworkURL) {
            theme.update(for: playback.nowPlaying.artworkURL)
        }
        .task(id: playback.nowPlaying.trackId) {
            details.load(trackId: WatchPlayback.detailsTrackID(playback.nowPlaying.trackId))
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if !usesScrollLayout {
            ToolbarItemGroup(placement: .bottomBar) {
                outputLink
                Spacer()
                listLink
                Spacer()
                moreLink
            }
        }
    }

    private var outputLink: some View {
        NavigationLink {
            WatchOutputPickerView()
        } label: {
            Label("Output", systemImage: isRemoteOutput ? playback.nowPlaying.output.symbolName : "airplayaudio")
                .foregroundStyle(isRemoteOutput ? theme.palette.tint : .primary)
        }
        .accessibilityValue(playback.nowPlaying.displayOutputName)
    }

    @ViewBuilder
    private var listLink: some View {
        if details.tracklist != nil {
            NavigationLink {
                WatchTracklistView()
            } label: {
                Label("Tracklist", systemImage: "list.number")
            }
        } else {
            NavigationLink {
                WatchUpNextView()
            } label: {
                Label("Up Next", systemImage: "list.bullet")
            }
        }
    }

    private var moreLink: some View {
        NavigationLink {
            WatchNowPlayingMoreView()
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .disabled(!playback.nowPlaying.hasTrack)
    }

    private var scrollActions: some View {
        VStack(spacing: 6) {
            outputLink
            listLink
            moreLink
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var nothingPlaying: some View {
        if playback.isLocal {
            ContentUnavailableView {
                Label("Nothing Playing", systemImage: "applewatch")
            } description: {
                Text("Pick something on this watch.")
            } actions: {
                NavigationLink {
                    WatchOnThisWatchView()
                } label: {
                    Text("On This Watch")
                }
                .buttonStyle(.glass)
                WatchRouteSwitch()
            }
        } else {
            ContentUnavailableView {
                Label("Nothing Playing", systemImage: "music.note")
            } description: {
                Text("Pick something from Listen Now or Library.")
            } actions: {
                if !store.isEmpty {
                    WatchRouteSwitch()
                }
            }
        }
    }

    @ViewBuilder
    private func screen(at date: Date) -> some View {
        let np = playback.nowPlaying

        Group {
            if np.hasTrack {
                playingContent(np: np, date: date)
            } else {
                nothingPlaying
            }
        }
        .containerBackground(for: .navigation) {
            WatchNowPlayingBackdrop(palette: theme.palette, artworkURL: np.artworkURL)
        }
        .onChange(of: date) { _, newDate in
            guard !isScrubbing, np.hasTrack else { return }
            let projected = np.projectedPosition(at: newDate, since: playback.receivedAt)
            lastSyncedPosition = projected
            scrubPosition = projected
        }
    }

    @ViewBuilder
    private func playingContent(np: WatchNowPlaying, date: Date) -> some View {
        let duration = max(np.durationSeconds, 1)
        let projected = np.projectedPosition(at: date, since: playback.receivedAt)
        let displayPosition = isScrubbing ? scrubPosition : projected

        if usesScrollLayout {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        header(np, date: date)
                        transport(np, duration: duration, displayPosition: displayPosition)
                            .id("transport")
                        scrollActions
                            .id("actions")
                    }
                    .padding(.horizontal, 6)
                }
                .task { await proxy.scrollToPreviewTarget() }
            }
        } else if playback.volume != nil {
            stage(np, date: date, duration: duration, displayPosition: displayPosition)
                .digitalCrownRotation(
                    $crownVolume,
                    from: 0,
                    through: 1,
                    by: 0.02,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )
                .onAppear { crownVolume = playback.volume ?? 0 }
                .onChange(of: crownVolume) { _, newValue in
                    guard abs(newValue - (playback.volume ?? 0)) > 0.005 else { return }
                    playback.setVolume(newValue)
                    flashVolume()
                }
                .onChange(of: playback.volume) { _, newValue in
                    guard !isAdjustingVolume, let newValue else { return }
                    crownVolume = newValue
                }
                .overlay(alignment: .top) {
                    if isAdjustingVolume {
                        volumeIndicator
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isAdjustingVolume)
        } else {
            stage(np, date: date, duration: duration, displayPosition: displayPosition)
                .digitalCrownRotation(
                    $scrubPosition,
                    from: 0,
                    through: duration,
                    by: crownStep(for: duration),
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )
                .onChange(of: scrubPosition) { _, newValue in
                    guard abs(newValue - lastSyncedPosition) > crownStep(for: duration) * 0.75 else { return }
                    scheduleSeek(to: newValue)
                }
        }
    }

    private func stage(_ np: WatchNowPlaying, date: Date, duration: Double, displayPosition: Double) -> some View {
        VStack(spacing: 0) {
            header(np, date: date)
            Spacer(minLength: 6)
            transport(np, duration: duration, displayPosition: displayPosition)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .focusable()
        .focused($isCrownFocused)
        .onAppear { isCrownFocused = true }
    }

    private var volumeIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
            ProgressView(value: crownVolume)
                .progressViewStyle(.linear)
                .tint(.white)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption2)
        .watchGlassPlate()
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((crownVolume * 100).rounded())) percent")
    }

    private func flashVolume() {
        isAdjustingVolume = true
        volumeHideTask?.cancel()
        volumeHideTask = Task {
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            isAdjustingVolume = false
        }
    }

    private func crownStep(for duration: Double) -> Double {
        duration > 1200 ? 5 : 1
    }

    private func scheduleSeek(to position: Double) {
        isScrubbing = true
        scrubCommitTask?.cancel()
        scrubCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            playback.seek(to: position)
            isScrubbing = false
        }
    }

    private func nudge(_ direction: AccessibilityAdjustmentDirection, duration: Double) {
        let step: Double = direction == .increment ? 10 : -10
        let base = isScrubbing ? scrubPosition : lastSyncedPosition
        scrubPosition = min(max(base + step, 0), duration)
        scheduleSeek(to: scrubPosition)
    }

    private func header(_ np: WatchNowPlaying, date: Date) -> some View {
        let position = np.projectedPosition(at: date, since: playback.receivedAt)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                titles(np)
                if details.canLike, !dynamicTypeSize.isAccessibilitySize {
                    likeButton
                }
            }
            if details.canLike, dynamicTypeSize.isAccessibilitySize {
                likeButton
            }
            mixTrackLine(position: position)
            if !playback.isLocal, let live = AutoMixLiveState.decode(link.djState.live) {
                WatchAutoMixLine(state: live, date: date, showsHeading: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .watchGlassPlate()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private func titles(_ np: WatchNowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            headerLine(np.title)
                .font(.headline)
            if playback.isControllable {
                headerLine(np.artist)
                    .font(.subheadline)
                    .foregroundStyle(secondaryStyle)
            } else {
                Label("iPhone not reachable", systemImage: "iphone.slash")
                    .font(.subheadline)
                    .foregroundStyle(secondaryStyle)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var likeButton: some View {
        Button {
            Task { await details.toggleLike() }
        } label: {
            Image(systemName: details.isLiked ? "heart.fill" : "heart")
                .font(.footnote.weight(.semibold))
                .frame(width: 26, height: 26)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(details.isLiked ? theme.palette.glass : nil)
        .disabled(details.isUpdatingLike)
        .accessibilityLabel(details.isLiked ? "Liked" : "Like")
        .accessibilityValue("\(SCStatFormat.compactCount(details.likeCount)) likes")
        .accessibilityHint(details.isLiked ? "Removes this track from your likes" : "Adds this track to your likes")
    }

    @ViewBuilder
    private func mixTrackLine(position: TimeInterval) -> some View {
        if let entry = details.tracklist?.currentEntry(at: position) {
            NavigationLink {
                WatchTracklistView()
            } label: {
                Label {
                    Text(entry.segment.artist.map { "\($0) – \(entry.segment.title)" } ?? entry.segment.title)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                } icon: {
                    Image(systemName: "waveform")
                }
                .font(.caption2)
                .foregroundStyle(secondaryStyle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("In the mix, \(entry.segment.title)")
            .accessibilityHint("Shows the tracklist")
        }
    }

    @ViewBuilder
    private func headerLine(_ text: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            Text(text)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            WatchFadingText(text)
                .lineLimit(1)
        }
    }

    private func transport(_ np: WatchNowPlaying, duration: Double, displayPosition: Double) -> some View {
        let clamped = min(max(displayPosition, 0), duration)

        return GlassEffectContainer(spacing: 14) {
            HStack(spacing: 0) {
                skipButton("Previous track", systemImage: "backward.fill") {
                    playback.transport(.previous)
                }
                Spacer(minLength: 0)
                ZStack {
                    playButton(np, position: clamped)
                    progressRing(progress: clamped / duration)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(clamped.watchSpokenDuration) of \(duration.watchSpokenDuration)")
                        .accessibilityHint("Swipe up or down to seek")
                        .accessibilityAdjustableAction { direction in
                            nudge(direction, duration: duration)
                        }
                }
                Spacer(minLength: 0)
                skipButton("Next track", systemImage: "forward.fill") {
                    playback.transport(.next)
                }
            }
        }
        .padding(.horizontal, 6)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: np.isPlaying)
    }

    private func skipButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    private func playButton(_ np: WatchNowPlaying, position: Double) -> some View {
        Button {
            playback.transport(.toggle)
        } label: {
            ZStack {
                if isScrubbing {
                    Text(position.watchClockString)
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                } else {
                    Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .medium))
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
            }
            .frame(width: 76, height: 76)
            .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(theme.palette.glass)
        .accessibilityLabel(np.isPlaying ? "Pause" : "Play")
    }

    private func progressRing(progress: Double) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(contrast == .increased ? 0.35 : 0.16), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 70, height: 70)
        .allowsHitTesting(false)
    }
}

struct WatchFadingText: View {
    let text: String

    @State private var overflows = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    if overflows {
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 22)
                    }
                }
            }
            .background {
                Text(text)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { intrinsic in
                        measure(intrinsic: intrinsic)
                    }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available in
                availableWidth = available
                measure(intrinsic: intrinsicWidth)
            }
            .accessibilityLabel(text)
    }

    @State private var intrinsicWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0

    private func measure(intrinsic: CGFloat) {
        intrinsicWidth = intrinsic
        let next = availableWidth > 0 && intrinsic > availableWidth + 0.5
        if next != overflows { overflows = next }
    }
}

struct WatchOutputPickerView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @ObservedObject private var playback = WatchPlayback.shared
    @ObservedObject private var local = WatchLocalPlayer.shared

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { playback.volume ?? 0 },
            set: { playback.setVolume($0) }
        )
    }

    var body: some View {
        List {
            Section {
                WatchRouteSwitch()
                    .listRowBackground(Color.clear)
            } footer: {
                if playback.isLocal, let routeName = local.routeName {
                    Text(routeName)
                }
            }

            if playback.volume != nil {
                Section {
                    Slider(value: volumeBinding, in: 0...1, step: 0.05) {
                        Text("Volume")
                    } minimumValueLabel: {
                        Image(systemName: "speaker.fill")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    .disabled(!playback.isControllable)
                    .accessibilityValue("\(Int(((playback.volume ?? 0) * 100).rounded())) percent")
                    .listRowBackground(Color.clear)
                }
            }

            if !playback.isLocal {
                Section {
                    ForEach(link.nowPlaying.outputOptions) { option in
                        let isSelected = link.nowPlaying.isSelected(option)
                        Button {
                            link.selectOutput(option)
                        } label: {
                            WatchNowPlayingRow(
                                title: option.name,
                                subtitle: isSelected ? "Playing" : (option.isAvailable ? "" : "Not Reachable"),
                                isCurrent: isSelected
                            ) {
                                WatchRoundIcon(systemImage: option.deviceClass.symbolName, tinted: isSelected)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!option.isAvailable && !isSelected)
                        .watchNowPlayingRowBackground(isCurrent: isSelected)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
        }
        .watchNowPlayingScreen("Output")
    }
}

struct WatchNowPlayingMoreView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @ObservedObject private var playback = WatchPlayback.shared
    @ObservedObject private var details = WatchNowPlayingDetails.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var upNextCount: Int {
        if playback.isLocal { return WatchLocalPlayer.shared.upNext.count }
        let items = link.queue.items
        if items.isEmpty { return playback.nowPlaying.queueCount + (link.djState.nextTitle == nil ? 0 : 1) }
        return items.count + (link.djState.nextTitle == nil || link.djState.nextTitle == items.first?.title ? 0 : 1)
    }

    var body: some View {
        List {
            NavigationLink {
                WatchUpNextView()
            } label: {
                WatchNowPlayingRow(
                    title: "Up Next",
                    subtitle: upNextCount == 0 ? "Nothing queued" : (upNextCount == 1 ? "1 track" : "\(upNextCount) tracks")
                ) {
                    WatchRoundIcon(systemImage: "list.bullet")
                }
            }
            .watchNowPlayingRowBackground()

            if let tracklist = details.tracklist {
                NavigationLink {
                    WatchTracklistView()
                } label: {
                    WatchNowPlayingRow(
                        title: "Tracklist",
                        subtitle: tracklist.entries.count == 1 ? "1 track" : "\(tracklist.entries.count) tracks"
                    ) {
                        WatchRoundIcon(systemImage: "list.number")
                    }
                }
                .watchNowPlayingRowBackground()
            }

            Toggle(isOn: Binding(
                get: { link.djState.isAutoEnabled },
                set: { link.dj($0 ? .autoEnable : .autoDisable) }
            )) {
                WatchNowPlayingRow(
                    title: "Auto Mix",
                    subtitle: link.djState.isAutoEnabled ? "On" : "Off"
                ) {
                    WatchRoundIcon(systemImage: "wand.and.stars")
                }
            }
            .disabled(!link.isReachable || playback.isLocal)
            .watchNowPlayingRowBackground()

            NavigationLink {
                WatchTrackInfoView()
            } label: {
                WatchNowPlayingRow(title: "About") {
                    WatchRoundIcon(systemImage: "info")
                }
            }
            .watchNowPlayingRowBackground()
            .accessibilityHint("Shows details for this track")
        }
        .watchNowPlayingScreen("More")
        .task(id: playback.nowPlaying.trackId) { details.load(trackId: WatchPlayback.detailsTrackID(playback.nowPlaying.trackId)) }
    }
}
