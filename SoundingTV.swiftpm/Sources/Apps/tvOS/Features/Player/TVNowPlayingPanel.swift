import AVKit
import SwiftUI

struct NPPanelActions {
    var select: (NPPanelKind) -> Void
    var close: () -> Void
    var seek: (TimeInterval) -> Void
    var openAllComments: () -> Void
    var openSetlistEditor: () -> Void
    var openTrackMap: () -> Void
    var openDecks: () -> Void
    var openDetails: () -> Void
}

struct NPPanel: View {
    let kind: NPPanelKind
    let accent: Color
    let collectionTitle: String?
    @ObservedObject var comments: TrackCommentsStore
    @ObservedObject var cueBoard: CueBoard
    var focus: FocusState<NPFocus?>.Binding
    let actions: NPPanelActions

    var body: some View {
        VStack(spacing: 0) {
            if kind.isTab {
                NPTabBar(selected: kind, focus: focus, onSelect: actions.select)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
            }
            content
        }
        .frame(width: 800)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .upNext:
            NPUpNextPane(collectionTitle: collectionTitle, focus: focus)
        case .comments:
            NPCommentsPane(store: comments, focus: focus, onSeek: actions.seek, onOpenAll: actions.openAllComments)
        case .tracklist:
            NPTracklistPane(focus: focus, onSeek: actions.seek, onIdentify: actions.openSetlistEditor)
        case .output:
            NPOutputPane(focus: focus)
        case .more:
            NPMorePane(cueBoard: cueBoard, focus: focus, actions: actions)
        case .cues:
            NPCuesPane(board: cueBoard, focus: focus, onSeek: actions.seek, onTrackMap: actions.openTrackMap)
        case .sleepTimer:
            NPSleepTimerPane(focus: focus, onDone: { actions.select(.more) })
        }
    }
}

private struct NPTabBar: View {
    let selected: NPPanelKind
    var focus: FocusState<NPFocus?>.Binding
    let onSelect: (NPPanelKind) -> Void

    @EnvironmentObject private var player: PlayerService

    private var tabs: [NPPanelKind] {
        let showsComments = player.currentTrack?.supportsSoundCloudActions ?? true
        return NPPanelKind.tabs.filter { showsComments || $0 != .comments }
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 14) {
                ForEach(tabs, id: \.self) { tab in
                    Button { onSelect(tab) } label: {
                        Text(tab.title)
                            .font(.callout.weight(.semibold))
                            .npInk(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                    }
                    .buttonStyle(NPPillStyle(isSelected: tab == selected))
                    .focused(focus, equals: .tab(tab))
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(tab == selected ? .isSelected : [])
                }
            }
        }
        .focusSection()
    }
}

private struct NPPaneHeader<Trailing: View>: View {
    let eyebrow: String?
    let title: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    if let eyebrow {
                        Text(eyebrow)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.66))
                            .lineLimit(1)
                    }
                    Text(title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 18)
        .accessibilityElement(children: .contain)
    }
}

private struct NPPill: View {
    let symbol: String
    let title: String
    let id: String
    var focus: FocusState<NPFocus?>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .npInk(.primary)
            .padding(.horizontal, 24)
            .frame(height: 56)
        }
        .buttonStyle(NPPillStyle())
        .focused(focus, equals: .pill(id))
        .accessibilityLabel(title)
    }
}

private struct NPSectionLabel: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.white.opacity(0.6))
        .padding(.horizontal, 14)
        .padding(.top, 20)
        .padding(.bottom, 10)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct NPEmptyNote: View {
    let symbol: String
    let title: String
    var message: String?
    var isLoading = false

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 24) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.4)
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            } else {
                ContentUnavailableView {
                    Label(title, systemImage: symbol)
                } description: {
                    if let message { Text(message) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.bottom, 60)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private func npFocusSoon(_ focus: FocusState<NPFocus?>.Binding, _ target: NPFocus?) {
    guard let target else { return }
    Task { @MainActor in
        await Task.yield()
        if case .tab = focus.wrappedValue { return }
        focus.wrappedValue = target
    }
}

private struct NPTrackRow: View {
    let track: Track
    let rowID: String
    var focus: FocusState<NPFocus?>.Binding
    var detail: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                ArtworkImage(url: track.artworkURL, identity: track.id)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .kyleCrowned(user: track.user, context: track.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body.weight(.semibold))
                        .npInk(.primary)
                        .lineLimit(1)
                    Text(track.user.displayName)
                        .font(.caption)
                        .npInk(.secondary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .npInk(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Text(track.formattedDuration)
                    .font(.caption)
                    .monospacedDigit()
                    .npInk(.tertiary)
            }
            .padding(.horizontal, 18)
            .frame(height: 100)
        }
        .buttonStyle(NPRowStyle())
        .focused(focus, equals: .row(rowID))
        .accessibilityLabel("\(track.title), \(track.user.displayName)")
        .accessibilityHint("Plays this track now")
        .accessibilityIdentifier("nowplaying.upnext.\(track.id)")
    }
}

private struct NPUpNextPane: View {
    let collectionTitle: String?
    var focus: FocusState<NPFocus?>.Binding

    @EnvironmentObject private var player: PlayerService

    private var upcoming: [(index: Int, track: Track)] {
        let start = player.currentIndex + 1
        guard start < player.queue.count else { return [] }
        return player.queue[start...].prefix(60).enumerated().map { (start + $0.offset, $0.element) }
    }

    var body: some View {
        let entries = upcoming
        VStack(spacing: 0) {
            NPPaneHeader(eyebrow: collectionTitle == nil ? nil : "Playing from", title: collectionTitle) {
                HStack(spacing: 12) {
                    NPIconButton(
                        symbol: "shuffle", label: "", id: .pill("shuffle"), focus: focus,
                        diameter: 56, iconSize: 24, isOn: player.isShuffleEnabled,
                        accessibilityTitle: "Shuffle", accessibilityValue: player.isShuffleEnabled ? "On" : "Off"
                    ) { player.toggleShuffle() }
                    NPIconButton(
                        symbol: player.repeatMode.icon, label: "", id: .pill("repeat"), focus: focus,
                        diameter: 56, iconSize: 24, isOn: player.repeatMode.isActive,
                        accessibilityTitle: "Repeat", accessibilityValue: repeatValue
                    ) { player.cycleRepeatMode() }
                }
            }
            if entries.isEmpty {
                NPEmptyNote(symbol: "list.bullet", title: "Nothing Queued", message: "Tracks you add will appear here.")
            } else {
                ScrollView {
                    let mix = AutoMixLive.shared.state
                    let layout = UpNextLayout.make(upcomingCount: entries.count, playingNextCount: player.playingNextCount, autoMixOn: player.isAutoMixEnabled || mix != nil)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !layout.playingNext.isEmpty {
                            NPSectionLabel(title: "Playing Next", trailing: player.isAutoMixEnabled || mix != nil ? "Plays before Auto Mix" : nil)
                            rows(entries, layout.playingNext, section: .playingNext, mix: mix)
                        }
                        if let pick = layout.autoMixPick {
                            NPSectionLabel(title: "Auto Mix")
                            rows(entries, pick..<(pick + 1), section: .autoMix, mix: mix)
                        }
                        if !layout.continuePlaying.isEmpty {
                            NPSectionLabel(title: "Continue Playing")
                            rows(entries, layout.continuePlaying, section: .continuePlaying, mix: mix)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 40)
                }
                .scrollClipDisabled()
            }
        }
        .onAppear {
            npFocusSoon(focus, entries.first.map { .row("q\($0.index)") })
        }
    }

    private func rows(_ entries: [(index: Int, track: Track)], _ range: Range<Int>, section: UpNextSection, mix: AutoMixLiveState?) -> some View {
        ForEach(range, id: \.self) { offset in
            let entry = entries[offset]
            NPTrackRow(
                track: entry.track,
                rowID: "q\(entry.index)",
                focus: focus,
                detail: detail(for: entry.track, offset: offset, section: section, mix: mix)
            ) {
                Task { await player.playTrackAt(index: entry.index) }
            }
            .contextMenu {
                if section != .playingNext {
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        player.moveToPlayingNext(at: entry.index)
                    }
                }
                Button("Remove from Up Next", systemImage: "minus.circle", role: .destructive) {
                    Task { await player.removeFromQueue(at: entry.index) }
                }
            }
        }
    }

    private func detail(for track: Track, offset: Int, section: UpNextSection, mix: AutoMixLiveState?) -> String? {
        var parts: [String] = []
        if section == .autoMix {
            let why = mix.flatMap { $0.incomingTrackId == track.id || AutoMixLive.shared.isFixture ? $0.why : nil }
            parts.append(why ?? "Picked to match this track")
        }
        if offset == 0, let mix, mix.stage == .upcoming {
            parts.append(mix.moveName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var repeatValue: String {
        switch player.repeatMode {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "One"
        }
    }
}

private struct NPCommentsPane: View {
    @ObservedObject var store: TrackCommentsStore
    var focus: FocusState<NPFocus?>.Binding
    let onSeek: (TimeInterval) -> Void
    let onOpenAll: () -> Void

    @EnvironmentObject private var player: PlayerService
    @State private var timed: [Comment] = []
    @State private var visibleCount = 0

    private var visible: ArraySlice<Comment> { timed.prefix(visibleCount) }
    private var later: ArraySlice<Comment> { timed.dropFirst(visibleCount) }

    var body: some View {
        VStack(spacing: 0) {
            NPPaneHeader(eyebrow: "\u{2022} Following playback", title: store.state == .loaded ? store.pager.countText(singular: "comment", plural: "comments") : nil) {
                NPPill(symbol: "text.bubble", title: "All", id: "allComments", focus: focus, action: onOpenAll)
            }
            switch store.state {
            case .idle, .loading:
                NPEmptyNote(symbol: "text.bubble", title: "Loading Comments", isLoading: true)
            case .failed:
                NPEmptyNote(symbol: "wifi.exclamationmark", title: "Couldn\u{2019}t Load Comments", message: "Check this Apple TV\u{2019}s network connection.")
            case .loaded:
                if timed.isEmpty {
                    NPEmptyNote(symbol: "text.bubble", title: "No Timed Comments", message: "Comments left at a moment in the track appear here.")
                } else {
                    list
                }
            }
        }
        .task(id: store.comments.count) {
            timed = store.timedComments
            visibleCount = Self.count(in: timed, at: player.currentTime)
        }
        .task(id: store.comments.count) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                let count = Self.count(in: timed, at: player.currentTime)
                if count != visibleCount { advance(to: count) }
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { comment in
                        NPCommentRow(comment: comment, focus: focus) {
                            if let time = comment.timeInTrack { onSeek(time) }
                        }
                        .id(comment.id)
                    }
                    if !later.isEmpty {
                        Text(CommentTimeline.laterTitle)
                            .font(.caption.weight(.semibold))
                            .npInk(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.top, visible.isEmpty ? 0 : 24)
                            .padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                            .id("later")
                        ForEach(later) { comment in
                            NPCommentRow(comment: comment, isLater: true, focus: focus) {
                                if let time = comment.timeInTrack { onSeek(time) }
                            }
                            .id(comment.id)
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 40)
            }
            .scrollClipDisabled()
            .onAppear {
                if let last = visible.last {
                    proxy.scrollTo(last.id, anchor: UnitPoint(x: 0.5, y: 0.3))
                    npFocusSoon(focus, .row("c\(last.id)"))
                } else if let first = later.first {
                    npFocusSoon(focus, .row("c\(first.id)"))
                }
            }
            .onChange(of: visibleCount) { _, _ in
                guard let last = visible.last else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(last.id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
        }
    }

    private func advance(to count: Int) {
        let previousLast = visible.last
        visibleCount = count
        guard let newLast = visible.last, newLast.id != previousLast?.id else { return }
        if previousLast == nil || focus.wrappedValue == .row("c\(previousLast?.id ?? "")") {
            focus.wrappedValue = .row("c\(newLast.id)")
        }
    }

    private static func count(in comments: [Comment], at position: TimeInterval) -> Int {
        CommentTimeline.split(comments, at: position, tolerance: 1).reachedCount
    }
}

private struct NPCommentRow: View {
    let comment: Comment
    var isLater = false
    var focus: FocusState<NPFocus?>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 18) {
                ArtworkImage(url: comment.user.avatarURL, icon: "person.fill", identity: comment.user.id)
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
                    .kyleCrowned(user: comment.user, context: comment.user.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Text(comment.user.displayName)
                            .font(.caption2.weight(.semibold))
                            .npInk(isLater ? .secondary : .primary)
                            .lineLimit(1)
                        if isLater {
                            Label("at \(NPFormat.time(comment.timeInTrack ?? 0))", systemImage: CommentTimeline.laterSymbol)
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                                .npInk(.secondary)
                        } else {
                            Text(NPFormat.time(comment.timeInTrack ?? 0))
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                                .npInk(.tertiary)
                        }
                    }
                    Text(comment.body)
                        .font(.subheadline)
                        .npInk(isLater ? .secondary : .primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(NPRowStyle())
        .focused(focus, equals: .row("c\(comment.id)"))
        .accessibilityLabel(
            isLater
                ? CommentTimeline.laterAccessibilityLabel(name: comment.user.displayName, clock: NPFormat.time(comment.timeInTrack ?? 0), body: comment.body)
                : "\(comment.user.displayName), \(NPFormat.time(comment.timeInTrack ?? 0)): \(comment.body)"
        )
        .accessibilityHint("Jumps to this moment")
    }
}

private struct NPTracklistPane: View {
    var focus: FocusState<NPFocus?>.Binding
    let onSeek: (TimeInterval) -> Void
    let onIdentify: () -> Void

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var store = SetlistIntelligenceStore.shared
    @State private var position: TimeInterval = 0

    private var tracklist: Tracklist? {
        guard let id = player.currentTrack?.id, let list = store.tracklist(for: id), !list.isEmpty else { return nil }
        return list
    }

    var body: some View {
        let list = tracklist
        let current = list?.currentIndex(at: position)
        VStack(spacing: 0) {
            NPPaneHeader(eyebrow: list == nil ? nil : eyebrow, title: list.map { "\($0.entries.count) tracks" }) {
                NPPill(symbol: "waveform.badge.magnifyingglass", title: "Identify", id: "identify", focus: focus, action: onIdentify)
            }
            if let list {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(list.entries) { entry in
                                NPTracklistRow(
                                    entry: entry,
                                    isCurrent: entry.index == current,
                                    position: position,
                                    focus: focus
                                ) { onSeek(entry.startSeconds + 0.05) }
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 26)
                        .padding(.bottom, 40)
                    }
                    .scrollClipDisabled()
                    .onAppear {
                        if let current, list.entries.indices.contains(current) {
                            proxy.scrollTo(list.entries[current].id, anchor: .center)
                        }
                    }
                }
            } else {
                NPEmptyNote(
                    symbol: "music.note.list",
                    title: store.scanningTrackIds.contains(player.currentTrack?.id ?? "") ? "Identifying\u{2026}" : "No Tracklist Yet",
                    message: "Identify listens to this mix and builds a tracklist."
                )
            }
        }
        .task(id: player.currentTrack?.id) {
            while !Task.isCancelled {
                if position != player.currentTime { position = player.currentTime }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onAppear {
            position = player.currentTime
            if let list, let index = list.currentIndex(at: player.currentTime), list.entries.indices.contains(index) {
                npFocusSoon(focus, .row("t\(list.entries[index].id)"))
            } else if let first = list?.entries.first {
                npFocusSoon(focus, .row("t\(first.id)"))
            } else {
                npFocusSoon(focus, .pill("identify"))
            }
        }
    }

    private var eyebrow: String {
        guard let list = tracklist else { return "Tracklist" }
        let sources = Set(list.entries.map(\.segment.source))
        if sources == [.uploaderTracklist] { return "From the uploader" }
        if sources == [.shazam] { return "Identified by listening" }
        return "Tracklist"
    }
}

private struct NPTracklistRow: View {
    let entry: TracklistEntry
    let isCurrent: Bool
    let position: TimeInterval
    var focus: FocusState<NPFocus?>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(NPFormat.time(entry.startSeconds))
                    .font(.caption)
                    .monospacedDigit()
                    .npInk(.tertiary)
                    .frame(width: 90, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .npInk(.primary)
                        .lineLimit(1)
                    if let artist {
                        Text(artist)
                            .font(.caption)
                            .npInk(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .npInk(.primary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .overlay(alignment: .bottomLeading) {
                if isCurrent {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: max(0, geo.size.width - 44) * progress, height: 3)
                            .offset(x: 22, y: geo.size.height - 11)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(NPRowStyle())
        .focused(focus, equals: .row("t\(entry.id)"))
        .accessibilityLabel("\(NPFormat.time(entry.startSeconds)), \(entry.segment.displayLabel)")
        .accessibilityValue(isCurrent ? "Now Playing" : "")
        .accessibilityHint("Jumps to this track")
    }

    private var title: String {
        let raw: String = entry.segment.title
        let base = SetlistText.normalized(raw)
        guard let version = SetlistText.normalized(entry.segment.version) else { return base }
        return "\(base) (\(version))"
    }

    private var artist: String? { SetlistText.normalized(entry.segment.artist) }

    private var progress: CGFloat {
        guard entry.durationSeconds > 0 else { return 0 }
        return CGFloat(min(1, max(0, (position - entry.startSeconds) / entry.durationSeconds)))
    }
}

private struct NPMenuRow: View {
    enum Trailing {
        case chevron
        case text(String)
        case check
        case none
    }

    let symbol: String
    let title: String
    var subtitle: String?
    var trailing: Trailing = .chevron
    let id: String
    var focus: FocusState<NPFocus?>.Binding
    var identifier: String?
    var accessibilityValue = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .npInk(.primary)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .npInk(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .npInk(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                switch trailing {
                case .chevron:
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .npInk(.primary)
                case .text(let value):
                    Text(value)
                        .font(.caption)
                        .npInk(.secondary)
                case .check:
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .semibold))
                        .npInk(.primary)
                case .none:
                    EmptyView()
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(minHeight: 96)
        }
        .buttonStyle(NPRowStyle())
        .focused(focus, equals: .row(id))
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(subtitle ?? "")
        .accessibilityIdentifier(identifier ?? "")
    }
}

private struct NPOutputPane: View {
    var focus: FocusState<NPFocus?>.Binding

    @EnvironmentObject private var player: PlayerService
    @State private var routePicker = NPRoutePicker()
    @ObservedObject private var sonos = SonosOutputController.shared
    @State private var sonosFailure: String?

    private func sonosRow(_ group: SonosGroup) -> some View {
        let isCurrent = sonos.isPlaying(on: group)
        return NPMenuRow(
            symbol: group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill",
            title: group.displayName,
            subtitle: isCurrent ? "Sonos \u{00B7} \(sonos.qualityLabel)" : "Sonos",
            trailing: isCurrent ? .check : .none,
            id: "out.sonos.\(group.id)", focus: focus, identifier: "nowplaying.output.sonos",
            accessibilityValue: isCurrent ? "Selected" : ""
        ) {
            guard !isCurrent else { return }
            Task { sonosFailure = await sonos.play(on: group) }
        }
        .contextMenu {
            let addable = sonos.rooms(addableTo: group)
            ForEach(addable) { room in
                Button("Add \(room.roomName)") { Task { sonosFailure = await sonos.add(room, to: group) } }
            }
            if group.members.count > 1 {
                ForEach(group.members) { room in
                    Button("Remove \(room.roomName)") { Task { sonosFailure = await sonos.remove(room) } }
                }
            }
        }
    }

    var body: some View {
        let route = currentRoute
        VStack(spacing: 0) {
            NPPaneHeader(eyebrow: "Output", title: "Play On") { EmptyView() }
            ScrollView {
                VStack(spacing: 0) {
                    if let active = sonos.activeGroup {
                        sonosRow(active)
                    }
                    NPMenuRow(
                        symbol: route.symbol, title: route.title, subtitle: route.subtitle, trailing: sonos.isActive ? .none : .check,
                        id: "out.local", focus: focus, identifier: "nowplaying.output.current", accessibilityValue: sonos.isActive ? "" : "Selected"
                    ) {
                        guard sonos.isActive else { return }
                        Task { await sonos.stop() }
                    }
                    ForEach(sonos.groups.filter { !sonos.isPlaying(on: $0) }) { group in
                        sonosRow(group)
                    }
                    NPMenuRow(
                        symbol: "airplay.audio", title: "AirPlay & Bluetooth", subtitle: "Speakers and headphones", trailing: .none,
                        id: "out.route", focus: focus, identifier: "nowplaying.output.route"
                    ) { routePicker.present() }
                }
                .padding(.horizontal, 26)
            }
            .scrollClipDisabled()
        }
        .background {
            NPRoutePickerHost(picker: routePicker)
                .frame(width: 2, height: 2)
                .accessibilityHidden(true)
        }
        .alert("Couldn't Play on Sonos", isPresented: Binding(
            get: { sonosFailure != nil },
            set: { if !$0 { sonosFailure = nil } }
        )) {
            Button("OK", role: .cancel) { sonosFailure = nil }
        } message: {
            Text(sonosFailure ?? "")
        }
        .onDisappear { sonos.stopDiscovery() }
        .onAppear {
            sonos.startDiscovery()
            routePicker.onDismiss = { [focus] in npFocusSoon(focus, .row("out.route")) }
            npFocusSoon(focus, .row(initialRow))
            #if DEBUG
            if ProcessInfo.processInfo.environment["SOUNDING_TV_NP_ROUTE_PICKER"] == "1" {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    routePicker.present()
                }
            }
            #endif
        }
    }

    private var initialRow: String {
        #if DEBUG
        if let row = ProcessInfo.processInfo.environment["SOUNDING_TV_NP_PANEL_ROW"] { return row }
        #endif
        return "out.local"
    }

    private var currentRoute: (symbol: String, title: String, subtitle: String) {
        let route = player.outputRoute
        let name = route.outputName.flatMap { $0.isEmpty ? nil : $0 }
        switch route.outputKind {
        case .airPlay: return ("airplay.audio", name ?? "AirPlay", "AirPlay")
        case .bluetooth: return ("headphones", name ?? "Bluetooth", "Bluetooth")
        case .headphones: return ("headphones", name ?? "Headphones", "Headphones")
        case .usb: return ("hifispeaker", name ?? "USB Audio", "USB")
        case .hdmi: return ("tv", "This Apple TV", name ?? "HDMI")
        case .builtIn, .unknown: return ("tv", "This Apple TV", name ?? "Apple TV")
        }
    }
}

@MainActor
private final class NPRoutePicker: NSObject, AVRoutePickerViewDelegate {
    var onDismiss: () -> Void = {}

    lazy var picker: AVRoutePickerView = {
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        picker.alpha = 0.02
        picker.isUserInteractionEnabled = true
        picker.delegate = self
        return picker
    }()

    nonisolated func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        Task { @MainActor in self.onDismiss() }
    }

    lazy var container: NPUnfocusableContainer = {
        let container = NPUnfocusableContainer(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        container.addSubview(picker)
        return container
    }()

    func present() {
        guard let button = Self.button(in: picker) else { return }
        button.sendActions(for: .primaryActionTriggered)
    }

    private static func button(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for subview in view.subviews {
            if let button = button(in: subview) { return button }
        }
        return nil
    }
}

private final class NPUnfocusableContainer: UIView {
    override var canBecomeFocused: Bool { false }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard let next = context.nextFocusedView else { return true }
        return !next.isDescendant(of: self)
    }
}

private struct NPRoutePickerHost: UIViewRepresentable {
    let picker: NPRoutePicker

    func makeUIView(context: Context) -> NPUnfocusableContainer { picker.container }

    func updateUIView(_ uiView: NPUnfocusableContainer, context: Context) {}
}

private struct NPMorePane: View {
    @ObservedObject var cueBoard: CueBoard
    var focus: FocusState<NPFocus?>.Binding
    let actions: NPPanelActions

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var setlistStore = SetlistIntelligenceStore.shared
    @ObservedObject private var sleepTimer = SleepTimer.shared
    @ObservedObject private var listenTogether = ListenTogether.shared
    @ObservedObject private var trims = TrackTrimStore.shared
    @Environment(\.presentAddToPlaylist) private var presentAddToPlaylist
    @Environment(\.presentTrackTrim) private var presentTrackTrim

    private func trimSubtitle(_ track: Track) -> String {
        let timeline = TrackTrimTimeline(range: trims.effectiveRange(for: track), duration: track.duration)
        guard timeline.isTrimmed else { return "Plays the whole track" }
        return "\(TrackTrimFormat.string(timeline.range.lowerBound)) to \(TrackTrimFormat.string(timeline.range.upperBound))"
    }

    private var tracklistCount: Int? {
        guard let id = player.currentTrack?.id, let list = setlistStore.tracklist(for: id), !list.isEmpty else { return nil }
        return list.entries.count
    }

    private var cueCount: Int { cueBoard.sheet.entries.count }

    private var commentsLiveHere: Bool {
        guard player.currentTrack?.supportsSoundCloudActions == true else { return false }
        return NPButtonSlots.showsTracklist(for: player.currentTrack, store: setlistStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            NPPaneHeader(eyebrow: player.currentTrack?.title ?? "Now Playing", title: "More") { EmptyView() }
            ScrollView {
                VStack(spacing: 0) {
                    if commentsLiveHere {
                        NPMenuRow(
                            symbol: "bubble.left", title: "Comments",
                            subtitle: "Follows playback",
                            id: "more.comments", focus: focus,
                            identifier: "nowplaying.action.comments"
                        ) { actions.select(.comments) }
                    }
                    if let count = tracklistCount ?? (player.currentTrack.map { DeckIdentityResolver.isLikelyMix($0) } == true ? 0 : nil) {
                        NPMenuRow(
                            symbol: "music.note.list", title: "Tracklist",
                            subtitle: count > 0 ? "\(count) tracks \u{00B7} Identify" : "Identify what\u{2019}s playing",
                            id: "more.tracklist", focus: focus
                        ) { actions.select(.tracklist) }
                    }
                    NPMenuRow(
                        symbol: "flag", title: "Cue Points",
                        subtitle: cueCount == 1 ? "1 cue" : "\(cueCount) cues",
                        id: "more.cues", focus: focus,
                        identifier: "nowplaying.action.trackMap",
                        accessibilityValue: cueCount == 0 ? "" : "\(cueCount) marked"
                    ) { actions.select(.cues) }
                    if listenTogether.isActive {
                        NPMenuRow(
                            symbol: "shareplay.slash", title: "Leave SharePlay",
                            subtitle: "Listening Together \u{00B7} \(listenTogether.participantCount)",
                            id: "more.shareplay", focus: focus,
                            identifier: "nowplaying.action.sharePlay"
                        ) { listenTogether.leave() }
                    } else if listenTogether.isEligible {
                        NPMenuRow(
                            symbol: "shareplay", title: "SharePlay",
                            subtitle: "Listen together on this call",
                            id: "more.shareplay", focus: focus,
                            identifier: "nowplaying.action.sharePlay"
                        ) { Task { await listenTogether.start() } }
                    }
                    NPMenuRow(
                        symbol: "infinity", title: "Auto Mix",
                        subtitle: listenTogether.isActive ? "Off during SharePlay" : "Matches tempo and key between tracks",
                        trailing: .text(player.isAutoMixEnabled && !listenTogether.isActive ? "On" : "Off"),
                        id: "more.automix", focus: focus,
                        identifier: "nowplaying.action.autoMix",
                        accessibilityValue: player.isAutoMixEnabled && !listenTogether.isActive ? "On" : "Off"
                    ) {
                        guard !listenTogether.isActive else { return }
                        player.setAutomaticMixEnabled(!player.isAutoMixEnabled)
                    }
                    NPMenuRow(
                        symbol: "moon.zzz", title: "Sleep Timer",
                        subtitle: sleepTimer.status.map(\.mode.title),
                        trailing: .text(sleepTimer.status == nil ? "Off" : "On"),
                        id: "more.sleep", focus: focus,
                        identifier: "nowplaying.action.sleepTimer",
                        accessibilityValue: sleepTimer.status?.mode.title ?? "Off"
                    ) { actions.select(.sleepTimer) }
                    if let track = player.currentTrack, track.supportsSoundCloudActions {
                        NPMenuRow(
                            symbol: "text.badge.plus", title: "Add to Playlist",
                            subtitle: "Your SoundCloud playlists",
                            id: "more.addToPlaylist", focus: focus,
                            identifier: "nowplaying.action.addToPlaylist"
                        ) { presentAddToPlaylist(PlaylistTrackRef(track: track)) }
                    }
                    if let track = player.currentTrack, track.duration > TrackTrim.minimumLength {
                        NPMenuRow(
                            symbol: "timeline.selection", title: "Start & End",
                            subtitle: trimSubtitle(track),
                            id: "more.trim", focus: focus,
                            identifier: "nowplaying.action.trim"
                        ) { presentTrackTrim(track) }
                    }
                    NPMenuRow(
                        symbol: "dial.medium", title: "Decks", subtitle: "Open the DJ console",
                        id: "more.decks", focus: focus,
                        identifier: "nowplaying.action.decks", action: actions.openDecks
                    )
                    NPMenuRow(
                        symbol: "info.circle", title: "Behind the Track",
                        subtitle: [player.currentTrack?.user.displayName, player.currentTrack?.genre].compactMap { $0 }.joined(separator: " \u{00B7} "),
                        id: "more.about", focus: focus,
                        identifier: "nowplaying.action.about", action: actions.openDetails
                    )
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 40)
            }
            .scrollClipDisabled()
        }
        .onAppear { npFocusSoon(focus, .row(tracklistCount == nil ? "more.cues" : "more.tracklist")) }
    }
}

private struct NPCuesPane: View {
    @ObservedObject var board: CueBoard
    var focus: FocusState<NPFocus?>.Binding
    let onSeek: (TimeInterval) -> Void
    let onTrackMap: () -> Void

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        VStack(spacing: 0) {
            NPPaneHeader(eyebrow: player.currentTrack?.title ?? "Now Playing", title: "Cue Points") { EmptyView() }
            ScrollView {
                VStack(spacing: 0) {
                    NPMenuRow(
                        symbol: "waveform.path", title: "Track Map", subtitle: "Add, move and rename cues",
                        id: "cue.map", focus: focus, action: onTrackMap
                    )
                    ForEach(board.sheet.entries) { cue in
                        Button { onSeek(cue.positionSeconds) } label: {
                            HStack(spacing: 20) {
                                Circle()
                                    .fill(cue.color.color)
                                    .frame(width: 18, height: 18)
                                    .frame(width: 64)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cue.label.isEmpty ? cue.kind.displayName.capitalized : cue.label)
                                        .font(.body.weight(.semibold))
                                        .npInk(.primary)
                                        .lineLimit(1)
                                    if cue.isSuggestion {
                                        Text("Suggested")
                                            .font(.caption2)
                                            .npInk(.secondary)
                                    }
                                }
                                Spacer(minLength: 12)
                                Text(NPFormat.time(cue.positionSeconds))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .npInk(.secondary)
                            }
                            .padding(.horizontal, 22)
                            .padding(.vertical, 16)
                            .frame(minHeight: 80)
                        }
                        .buttonStyle(NPRowStyle())
                        .focused(focus, equals: .row("cue.\(cue.id)"))
                        .accessibilityLabel("\(cue.label.isEmpty ? cue.kind.displayName : cue.label), \(NPFormat.time(cue.positionSeconds))")
                        .accessibilityHint("Jumps to this cue")
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 40)
            }
            .scrollClipDisabled()
        }
        .onAppear { npFocusSoon(focus, .row(board.sheet.entries.first.map { "cue.\($0.id)" } ?? "cue.map")) }
    }
}

private struct NPSleepTimerPane: View {
    var focus: FocusState<NPFocus?>.Binding
    let onDone: () -> Void

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var timer = SleepTimer.shared

    private var choices: [SleepTimerMode] {
        SleepTimerMode.choices(offersEndOfMix: SleepTimer.offersEndOfMix(trackID: player.currentTrack?.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            NPPaneHeader(eyebrow: player.currentTrack?.title ?? "Now Playing", title: "Sleep Timer") {
                if let status = timer.status {
                    SleepTimerIndicator(status: status)
                        .font(.caption.weight(.semibold))
                        .npInk(.secondary)
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    NPMenuRow(
                        symbol: "moon.zzz", title: "Off",
                        trailing: timer.status == nil ? .check : .none,
                        id: "sleep.off", focus: focus
                    ) {
                        timer.cancel()
                        onDone()
                    }
                    ForEach(choices, id: \.self) { mode in
                        NPMenuRow(
                            symbol: Self.symbol(for: mode), title: mode.title,
                            trailing: timer.status?.mode == mode ? .check : .none,
                            id: "sleep.\(mode.wireKind).\(mode.wireMinutes)", focus: focus
                        ) {
                            timer.start(mode)
                            onDone()
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 40)
            }
            .scrollClipDisabled()
        }
        .onAppear {
            let current = timer.status.map { "sleep.\($0.mode.wireKind).\($0.mode.wireMinutes)" } ?? "sleep.off"
            npFocusSoon(focus, .row(current))
        }
    }

    private static func symbol(for mode: SleepTimerMode) -> String {
        switch mode {
        case .minutes: return "timer"
        case .endOfTrack: return "music.note"
        case .endOfMix: return "music.note.list"
        }
    }
}

struct NPListenTogetherLine: View {
    var body: some View {
        ListenTogetherIndicator()
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.white.opacity(0.66))
    }
}

struct NPSleepTimerLine: View {
    @ObservedObject private var timer = SleepTimer.shared

    var body: some View {
        if let status = timer.status {
            SleepTimerIndicator(status: status)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.66))
        }
    }
}
