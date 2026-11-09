import SwiftUI
import UIKit

enum PhoneRadius {
    static let card: CGFloat = 20
    static let tile: CGFloat = 14
    static let artwork: CGFloat = 22
}

enum NowPlayingPane: String, CaseIterable, Identifiable {
    case upNext = "Up Next"
    case lyrics = "Lyrics"
    case comments = "Comments"
    case tracklist = "Tracklist"
    case about = "Behind the Track"

    var id: Self { self }

    static let phone: [NowPlayingPane] = [.comments, .tracklist, .about, .lyrics, .upNext]

    static func phoneTabs(isMix: Bool, isDeviceTrack: Bool = false, hidesLyrics: Bool = false, showing current: NowPlayingPane) -> [NowPlayingPane] {
        let primary: Set<NowPlayingPane> = [isMix || isDeviceTrack ? .tracklist : .comments, .about, .lyrics, .upNext, current]
        return phone.filter { primary.contains($0) && !(isDeviceTrack && $0 == .comments) && !(hidesLyrics && $0 == .lyrics) }
    }

    static func padTabs(isDeviceTrack: Bool, hidesLyrics: Bool = false) -> [NowPlayingPane] {
        allCases.filter { !(isDeviceTrack && $0 == .comments) && !(hidesLyrics && $0 == .lyrics) }
    }
}

enum NPInk {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.76)
    static let tertiary = Color.white.opacity(0.66)
    static let faint = Color.white.opacity(0.2)
    static let fill = Color.white.opacity(0.09)
    static let fillStrong = Color.white.opacity(0.15)
}

enum NPMotion {
    static let spring = Animation.spring(response: 0.5, dampingFraction: 0.86)
    static let bouncy = Animation.spring(response: 0.46, dampingFraction: 0.7)

    static func spring(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : spring
    }
}

struct NowPlayingPaneStyle {
    var inset: CGFloat = 24
    var titleFont: Font = .title3.weight(.bold)
}

private struct NowPlayingPaneHeader<Eyebrow: View, Actions: View>: View {
    let title: String
    let style: NowPlayingPaneStyle
    @ViewBuilder var eyebrow: () -> Eyebrow
    @ViewBuilder var actions: () -> Actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize >= .xxxLarge {
                VStack(alignment: .leading, spacing: 8) {
                    titles(limit: 3)
                    HStack(spacing: 8) { actions() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .bottom, spacing: 12) {
                    titles(limit: 1)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) { actions() }
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, style.inset)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
    }

    private func titles(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            eyebrow()
                .font(.footnote.weight(.medium))
                .foregroundStyle(NPInk.secondary)
                .lineLimit(limit)
            Text(title)
                .font(style.titleFont)
                .foregroundStyle(NPInk.primary)
                .lineLimit(limit)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

extension View {
    func nowPlayingPaneFade() -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 12)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
            }
        }
    }
}

struct NowPlayingToggleCircle: View {
    let systemImage: String
    let isOn: Bool
    let label: String
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 36

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? Color.black : NPInk.secondary)
                .frame(width: diameter, height: diameter)
                .background(isOn ? Color.white : NPInk.fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(label)
    }
}

struct NowPlayingAvatar: View {
    let url: URL?
    let name: String
    let size: CGFloat

    var body: some View {
        SCArtworkResolver(url: url, variant: .thumbnail) { image in
            SCArtwork(image: image, identity: name, style: .phone, cornerRadius: size / 2, subject: .person)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

// MARK: - Up Next

struct NowPlayingUpNextPane: View {
    var style = NowPlayingPaneStyle()

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ScaledMetric(relativeTo: .body) private var artSize: CGFloat = 46

    var body: some View {
        let entries = coordinator.upNextEntries
        VStack(spacing: 0) {
            NowPlayingPaneHeader(title: "Up Next", style: style) {
                if let source = coordinator.queueSource {
                    Text("Playing from \(source.title)")
                } else {
                    Text(entries.isEmpty ? "Queue" : "\(entries.count) \(entries.count == 1 ? "track" : "tracks")")
                }
            } actions: {
                if coordinator.canChangePlaybackModes {
                    NowPlayingToggleCircle(
                        systemImage: "shuffle",
                        isOn: coordinator.isShuffleEnabled,
                        label: coordinator.isShuffleEnabled ? "Shuffle, on" : "Shuffle, off",
                        action: { coordinator.toggleShuffle() }
                    )
                    NowPlayingToggleCircle(
                        systemImage: coordinator.repeatMode.icon,
                        isOn: coordinator.repeatMode.isActive,
                        label: "Repeat, \(coordinator.repeatMode.rawValue)",
                        action: { coordinator.cycleRepeatMode() }
                    )
                }
            }

            if entries.isEmpty {
                ContentUnavailableView(
                    "Up Next Is Empty",
                    systemImage: "text.line.last.and.arrowtriangle.forward",
                    description: Text("Add another track and it will appear here.")
                )
                .frame(maxHeight: .infinity)
                .upNextFillTarget { tracks in
                    for track in tracks { coordinator.addToQueue(track) }
                }
            } else {
                let layout = coordinator.upNextLayout(count: entries.count)
                List {
                    if !layout.playingNext.isEmpty {
                        Section {
                            queueRows(entries, range: layout.playingNext, layout: layout)
                        } header: {
                            sectionHeader("Playing Next", note: autoMixOn ? "Plays before Auto Mix" : nil)
                        }
                    }
                    if let pick = layout.autoMixPick {
                        Section {
                            queueRows(entries, range: pick..<(pick + 1), layout: layout)
                        } header: {
                            sectionHeader("Auto Mix", systemImage: "arrow.triangle.merge")
                        }
                    }
                    if !layout.continuePlaying.isEmpty {
                        Section {
                            queueRows(entries, range: layout.continuePlaying, layout: layout)
                        } header: {
                            sectionHeader("Continue Playing")
                        }
                    }
                }
                .environment(\.editMode, .constant(.active))
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 44)
                .contentMargins(.bottom, 28, for: .scrollContent)
                .nowPlayingPaneFade()
            }
        }
    }

    private var autoMixOn: Bool {
        coordinator.autoMixLive != nil || coordinator.djSnapshot.isAutoEnabled
    }

    private func sectionHeader(_ title: String, systemImage: String? = nil, note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(NPInk.secondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .foregroundStyle(NPInk.secondary)
            Spacer(minLength: 8)
            if let note {
                Text(note)
                    .foregroundStyle(NPInk.tertiary)
            }
        }
        .font(.footnote.weight(.semibold))
        .textCase(nil)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .listRowInsets(EdgeInsets(top: 0, leading: style.inset, bottom: 0, trailing: style.inset))
        .accessibilityAddTraits(.isHeader)
    }

    private func queueRows(_ entries: [PhonePlaybackCoordinator.UpNextEntry], range: Range<Int>, layout: UpNextLayout) -> some View {
        let slice = Array(entries[range])
        return ForEach(Array(slice.enumerated()), id: \.element.id) { offset, entry in
            row(entry, position: range.lowerBound + offset + 1, count: entries.count, section: layout.section(at: range.lowerBound + offset))
        }
        .onMove { source, destination in
            guard range.count > 1, let from = source.first,
                  let move = QueueReorder.move(source: from, before: destination, count: range.count) else { return }
            coordinator.applyUpNextMove(QueueReorder.Move(from: range.lowerBound + move.from, to: range.lowerBound + move.to), in: entries)
        }
        .dropDestination(for: SoundingDrop.self) { (drops: [SoundingDrop], offset: Int) in
            insertDropped(drops, at: offset, entries: entries, range: range)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: style.inset, bottom: 0, trailing: style.inset - 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func insertDropped(_ drops: [SoundingDrop], at offset: Int, entries: [PhonePlaybackCoordinator.UpNextEntry], range: Range<Int>) {
        guard entries.indices.contains(range.lowerBound), let first = entries[range.lowerBound].queueIndex else { return }
        let destination = first + offset
        Task { @MainActor in
            let tracks = await DropResolver.tracks(drops)
            guard !tracks.isEmpty else { return }
            coordinator.insertIntoQueue(tracks, at: destination)
        }
    }

    private func reason(for entry: PhonePlaybackCoordinator.UpNextEntry, section: UpNextSection) -> String? {
        guard section == .autoMix else { return nil }
        return coordinator.autoMixReason(for: entry) ?? "Picked to match this track"
    }

    @ViewBuilder
    private func row(_ entry: PhonePlaybackCoordinator.UpNextEntry, position: Int, count: Int, section: UpNextSection) -> some View {
        let why = reason(for: entry, section: section)
        let mix = position == 1 ? coordinator.autoMixLive.flatMap { $0.stage == .upcoming ? $0 : nil } : nil
        let content = HStack(spacing: 12) {
            SCArtworkResolver(url: entry.artworkURL.flatMap(URL.init(string:)), variant: .thumbnail) { image in
                SCArtwork(image: image, identity: entry.trackID, style: .phone, cornerRadius: 7)
            }
            .frame(width: artSize, height: artSize)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NPInk.primary)
                    .lineLimit(1)
                Text(entry.artist)
                    .font(.footnote)
                    .foregroundStyle(NPInk.secondary)
                    .lineLimit(1)
                if let why {
                    Text(why)
                        .font(.footnote)
                        .foregroundStyle(NPInk.tertiary)
                        .lineLimit(1)
                }
                if let mix {
                    UpNextMixCountdown(state: mix)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.formattedDuration)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(NPInk.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([ "\(position). \(entry.title), \(entry.artist), \(entry.formattedDuration)", why ].compactMap { $0 }.joined(separator: ". "))
        .accessibilityActions {
            if position > 1 {
                Button("Move Up") { coordinator.moveUpNextEntry(entry, up: true) }
            }
            if position < count {
                Button("Move Down") { coordinator.moveUpNextEntry(entry, up: false) }
            }
            if section != .playingNext {
                Button("Play Next") { coordinator.moveUpNextEntryToPlayingNext(entry) }
            }
            AddToPlaylistMenuButton(trackID: entry.trackID, title: entry.title)
            if let index = entry.queueIndex {
                Button("Remove from Queue") { coordinator.removeQueueItem(at: index) }
            }
        }

        if let index = entry.queueIndex {
            Button { coordinator.playQueueItem(at: index) } label: { content }
                .buttonStyle(.plain)
                .accessibilityHint("Plays this track now")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { coordinator.removeQueueItem(at: index) } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
                .swipeActions(edge: .leading) {
                    if section != .playingNext {
                        Button { coordinator.moveUpNextEntryToPlayingNext(entry) } label: {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                    }
                }
                .libraryRowPreviewShape()
                .contextMenu {
                    Button { coordinator.playQueueItem(at: index) } label: {
                        Label("Play Now", systemImage: "play.fill")
                    }
                    if section != .playingNext {
                        Button { coordinator.moveUpNextEntryToPlayingNext(entry) } label: {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                    }
                    AddToPlaylistMenuButton(trackID: entry.trackID, title: entry.title)
                    Button(role: .destructive) { coordinator.removeQueueItem(at: index) } label: {
                        Label("Remove from Queue", systemImage: "minus.circle")
                    }
                }
        } else {
            content
        }
    }
}

struct UpNextMixCountdown: View {
    let state: AutoMixLiveState

    var body: some View {
        TimelineView(.periodic(from: state.startsAt, by: state.isPlaying ? 1 : 3_600)) { context in
            let seconds = state.clock(at: context.date).secondsUntilStart
            HStack(spacing: 4) {
                Image(systemName: state.symbolName)
                    .imageScale(.small)
                Text("\(state.moveName) \(AutoMixLiveState.countdown(seconds))")
                    .monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(NPInk.secondary)
            .lineLimit(1)
        }
    }
}

// MARK: - Comments

struct NowPlayingCommentsPane: View {
    let trackId: String?
    let tint: Color
    @ObservedObject var store: PhoneWaveformStore
    let timeline: NowPlayingTimeline
    let onSeek: (TimeInterval) -> Void
    var style = NowPlayingPaneStyle()
    var onError: (String) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var timed = TimedComments.empty
    @State private var revealed = 0
    @State private var currentID: String?
    @State private var lastUserScroll = Date.distantPast
    @State private var isShowingSignIn = false

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingPaneHeader(title: title, style: style) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text("Following playback")
                }
            } actions: {
                EmptyView()
            }

            content
                .frame(maxHeight: .infinity)

            if store.commentsState == .loaded || store.commentsState == .signedOut {
                NowPlayingCommentComposer(
                    trackId: trackId,
                    timeline: timeline,
                    store: store,
                    onSignIn: { isShowingSignIn = true },
                    onError: onError
                )
                .padding(.horizontal, style.inset)
                .padding(.top, 6)
            }
        }
        .task(id: TimedComments.Key(store.comments)) {
            timed = TimedComments(store.comments)
        }
        .task(id: FollowKey(trackId: trackId, anchor: timeline.anchor, count: timed.items.count)) {
            await follow()
        }
        .sheet(isPresented: $isShowingSignIn) {
            NavigationStack {
                SoundCloudLoginView.standalone {
                    isShowingSignIn = false
                    SoundCloudCredentialSource.shared.refreshFromStore()
                    store.retry(trackId: trackId)
                }
            }
        }
    }

    private var title: String {
        guard store.commentsState == .loaded else { return "Comments" }
        let count = store.comments.count
        return count == 1 ? "1 comment" : "\(count.formatted()) comments"
    }

    @ViewBuilder
    private var content: some View {
        switch store.commentsState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading comments")
        case .signedOut:
            ContentUnavailableView {
                Label("Sign In to See Comments", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("Comments need a SoundCloud sign-in on this device.")
            } actions: {
                Button("Sign In") { isShowingSignIn = true }
                    .buttonStyle(.borderedProminent)
            }
        case .failed:
            ContentUnavailableView {
                Label("Couldn't Load Comments", systemImage: "wifi.slash")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { store.retry(trackId: trackId) }
                    .buttonStyle(.bordered)
            }
        case .loaded:
            commentList
        }
    }

    private var commentList: some View {
        let later = timed.items.dropFirst(revealed)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if timed.items.isEmpty {
                        Text(store.comments.isEmpty ? "No comments yet.\nBe the first." : "No comments yet at this point.\nBe the first.")
                            .font(.subheadline)
                            .foregroundStyle(NPInk.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    ForEach(timed.items.prefix(revealed)) { item in
                        NowPlayingCommentRow(
                            comment: item.comment,
                            time: item.time,
                            tint: tint,
                            isCurrent: item.id == currentID,
                            onSeek: { onSeek(item.time) }
                        )
                        .id(item.id)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 16)))
                    }
                    if !later.isEmpty {
                        Text(CommentTimeline.laterTitle)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(NPInk.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.top, revealed == 0 ? 4 : 20)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                            .id(Self.laterHeaderID)
                        ForEach(later) { item in
                            NowPlayingCommentRow(
                                comment: item.comment,
                                time: item.time,
                                tint: tint,
                                isCurrent: false,
                                isLater: true,
                                onSeek: { onSeek(item.time) }
                            )
                            .id(item.id)
                            .transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, style.inset - 8)
                .padding(.top, 4)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : NPMotion.spring, value: revealed)
                .animation(.easeInOut(duration: 0.45), value: currentID)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.bottom, 28, for: .scrollContent)
            .nowPlayingPaneFade()
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { lastUserScroll = .now }
            }
            .onAppear { followPlayhead(proxy) }
            .onChange(of: revealed) { _, _ in
                guard Date.now.timeIntervalSince(lastUserScroll) > 4 else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                    followPlayhead(proxy)
                }
            }
        }
    }

    private static let laterHeaderID = "comments.later"

    private func followPlayhead(_ proxy: ScrollViewProxy) {
        let anchor = UnitPoint(x: 0.5, y: 0.3)
        if revealed > 0, revealed <= timed.items.count {
            proxy.scrollTo(timed.items[revealed - 1].id, anchor: anchor)
        } else if revealed == 0, timed.items.isEmpty == false {
            proxy.scrollTo(Self.laterHeaderID, anchor: .top)
        }
    }

    private struct FollowKey: Equatable {
        let trackId: String?
        let anchor: PlaybackAnchor
        let count: Int
    }

    private func follow() async {
        while !Task.isCancelled {
            let anchor = timeline.anchor
            let position = anchor.position(at: .now)
            let split = CommentTimeline.split(timed.items, at: position) { $0.time }
            let count = split.reachedCount
            let last = count > 0 ? timed.items[count - 1] : nil
            let current = split.currentIndex.map { timed.items[$0].id }
            if count != revealed { revealed = count }
            if current != currentID { currentID = current }
            guard anchor.isAdvancing else { return }
            var wait: TimeInterval = 30
            if count < timed.items.count { wait = min(wait, timed.items[count].time - 0.5 - position) }
            if let last, current != nil { wait = min(wait, last.time + 25 - position) }
            try? await Task.sleep(for: .seconds(max(0.25, wait / max(anchor.rate, 0.01))))
        }
    }
}

struct TimedComments: Equatable {
    struct Item: Identifiable, Equatable {
        let comment: Comment
        let time: TimeInterval
        var id: String { comment.id }
    }

    struct Key: Equatable {
        let count: Int
        let first: String?
        let last: String?

        init(_ comments: [Comment]) {
            count = comments.count
            first = comments.first?.id
            last = comments.last?.id
        }
    }

    let items: [Item]

    static let empty = TimedComments(items: [])

    init(items: [Item]) { self.items = items }

    init(_ comments: [Comment]) {
        items = CommentTimeline.ordered(comments)
            .compactMap { comment in comment.timeInTrack.map { Item(comment: comment, time: $0) } }
    }

    func revealedCount(at position: TimeInterval) -> Int {
        CommentTimeline.split(items, at: position) { $0.time }.reachedCount
    }

    func latest(after start: TimeInterval, through end: TimeInterval) -> Item? {
        guard end > start else { return nil }
        let upper = revealedCount(at: end - 0.5)
        guard upper > 0 else { return nil }
        let candidate = items[upper - 1]
        return candidate.time > start ? candidate : nil
    }
}

private struct NowPlayingCommentRow: View {
    let comment: Comment
    let time: TimeInterval
    let tint: Color
    let isCurrent: Bool
    var isLater = false
    let onSeek: () -> Void

    @ScaledMetric(relativeTo: .body) private var avatar: CGFloat = 32

    var body: some View {
        Button(action: onSeek) {
            HStack(alignment: .top, spacing: 11) {
                NowPlayingAvatar(url: comment.user.avatarURL, name: comment.user.displayName, size: avatar)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(comment.user.displayName)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(isLater ? NPInk.secondary : NPInk.primary)
                            .lineLimit(1)
                        if isLater {
                            Label("at \(scFormatTime(time))", systemImage: CommentTimeline.laterSymbol)
                                .font(.footnote.weight(.medium).monospacedDigit())
                                .foregroundStyle(NPInk.secondary)
                        } else {
                            Text(scFormatTime(time))
                                .font(.footnote.weight(.medium).monospacedDigit())
                                .foregroundStyle(tint)
                        }
                    }
                    Text(comment.body)
                        .font(.subheadline)
                        .foregroundStyle(isLater ? NPInk.secondary : NPInk.primary.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(isCurrent ? NPInk.fillStrong : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .libraryRowPreviewShape(cornerRadius: 16)
        .contextMenu {
            Button {
                UIPasteboard.general.string = comment.body
            } label: {
                Label("Copy Comment", systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isLater
                ? CommentTimeline.laterAccessibilityLabel(name: comment.user.displayName, clock: scFormatTime(time), body: comment.body)
                : "\(comment.user.displayName), at \(scFormatTime(time)), \(comment.body)"
        )
        .accessibilityValue(isCurrent ? "Playing now" : "")
        .accessibilityHint("Plays from this comment")
    }
}

private struct NowPlayingCommentComposer: View {
    let trackId: String?
    let timeline: NowPlayingTimeline
    @ObservedObject var store: PhoneWaveformStore
    let onSignIn: () -> Void
    let onError: (String) -> Void

    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @State private var draft = ""
    @State private var isPosting = false
    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .body) private var avatar: CGFloat = 28

    var body: some View {
        HStack(spacing: 10) {
            NowPlayingAvatar(
                url: credentials.currentUser?.avatarURL,
                name: credentials.currentUser?.displayName ?? "You",
                size: avatar
            )
            TimelineView(.animation(minimumInterval: 1, paused: !timeline.anchor.isAdvancing || isFocused)) { context in
                TextField(
                    "Add a comment",
                    text: $draft,
                    prompt: Text("Comment at \(scFormatTime(timeline.anchor.position(at: context.date)))")
                        .foregroundStyle(NPInk.tertiary)
                )
                .font(.subheadline)
                .foregroundStyle(NPInk.primary)
                .submitLabel(.send)
                .focused($isFocused)
                .onSubmit(post)
                .disabled(isPosting)
            }
            Button(action: post) {
                Group {
                    if isPosting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.black, Color.white)
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPosting)
            .opacity(draft.isEmpty ? 0.6 : 1)
            .accessibilityLabel("Post Comment")
        }
        .padding(.vertical, 5)
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .background(NPInk.fill, in: Capsule())
    }

    private func post() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let trackId, !isPosting else { return }
        guard credentials.accessToken != nil else {
            onSignIn()
            return
        }
        let position = timeline.anchor.position(at: .now)
        isPosting = true
        Task {
            defer { isPosting = false }
            do {
                let comment = try await SoundCloudAPI.shared.postComment(
                    trackId: trackId,
                    body: body,
                    timestampMillis: Int(position * 1000)
                )
                draft = ""
                isFocused = false
                store.insert(comment, trackId: trackId)
            } catch {
                onError("Your comment couldn't be posted. Check your connection and try again.")
            }
        }
    }
}

// MARK: - Tracklist

enum NowPlayingSegmentText {
    private static let unknownTitles: Set<String> = ["id", "unknown", "unknown track", "unidentified", "?", "??", "???", "id - id", "id – id"]

    static func isUnknown(_ segment: SetlistSegment) -> Bool {
        let title = SetlistText.normalized(segment.title).lowercased()
        let artist = SetlistText.normalized(segment.artist)?.lowercased()
        return unknownTitles.contains(title) && (artist == nil || artist == "id" || unknownTitles.contains(artist ?? ""))
    }

    static func parts(_ segment: SetlistSegment) -> (title: String, artist: String?) {
        let title = SetlistText.normalized(segment.title)
        if let artist = SetlistText.normalized(segment.artist) { return (title, artist) }
        for separator in [" — ", " – ", " - "] {
            let pieces = title.components(separatedBy: separator)
            if pieces.count > 1 {
                return (pieces.dropFirst().joined(separator: separator), pieces[0])
            }
        }
        return (title, nil)
    }

    static func line(_ segment: SetlistSegment) -> String {
        if isUnknown(segment) { return "ID — Unidentified" }
        let parts = parts(segment)
        guard let artist = parts.artist else { return parts.title }
        return "\(artist) — \(parts.title)"
    }
}

enum NowPlayingIdentifyState: Equatable {
    case idle
    case listening(TimeInterval)
    case found(SetlistSegment, TimeInterval)
    case noMatch(TimeInterval)
    case failed(String)
}

@MainActor
@Observable
final class NowPlayingIdentifier {
    var state: NowPlayingIdentifyState = .idle
    var song: IdentifiedSong?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var trackId: String?

    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    func identify(track: Track?, trackId: String?, at position: TimeInterval) {
        guard !isListening else { return }
        task?.cancel()
        self.trackId = trackId
        song = nil
        state = .listening(position)
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_NP_SHOT"] == "identify" { return }
        #endif
        guard let track, track.id == trackId else {
            state = .failed("Identify needs the track to finish loading.")
            return
        }
        task = Task { [weak self] in
            let result = await SetlistIntelligenceStore.shared.identify(track, at: position)
            guard let self, !Task.isCancelled, self.trackId == trackId else { return }
            switch result {
            case .matched(let segment):
                self.song = SetlistIntelligenceStore.shared.identifiedSongs[track.id]
                self.state = .found(segment, position)
            case .noMatch: self.state = .noMatch(position)
            case .unavailable(let message), .failed(let message): self.state = .failed(message)
            }
        }
    }

    func dismiss() {
        task?.cancel()
        song = nil
        state = .idle
    }

    func reset(for trackId: String?) {
        guard trackId != self.trackId else { return }
        task?.cancel()
        self.trackId = trackId
        song = nil
        state = .idle
    }
}

struct NowPlayingIdentifyButton: View {
    let identifier: NowPlayingIdentifier
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "shazam.logo.fill")
                    .font(.system(size: 17))
                    .symbolEffect(.pulse, options: .repeating, isActive: identifier.isListening && !reduceMotion)
                Text(identifier.isListening ? "Listening…" : "Identify This Track")
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(identifier.isListening ? NPInk.primary : Color.black)
            .padding(.leading, 9)
            .padding(.trailing, 14)
            .frame(minHeight: 36)
            .background(identifier.isListening ? NPInk.fillStrong : Color.white, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(SquishButtonStyle(reduceMotion: reduceMotion, scale: 0.94))
        .disabled(identifier.isListening)
        .accessibilityLabel(identifier.isListening ? "Listening" : "Identify This Track")
    }
}

struct NowPlayingTracklistPane: View {
    let trackId: String?
    let resolvedTrack: Track?
    let tint: Color
    let timeline: NowPlayingTimeline
    let identifier: NowPlayingIdentifier
    let onSeek: (TimeInterval) -> Void
    let onEdit: () -> Void
    var style = NowPlayingPaneStyle()

    @ObservedObject private var setlists = SetlistIntelligenceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentIndex: Int?
    @State private var lastUserScroll = Date.distantPast

    private var tracklist: Tracklist? {
        guard let list = setlists.tracklist(for: trackId), !list.isEmpty else { return nil }
        return list
    }

    var body: some View {
        let list = tracklist
        VStack(spacing: 0) {
            NowPlayingPaneHeader(title: title(list), style: style) {
                Text(eyebrow(list))
            } actions: {
                NowPlayingIdentifyButton(identifier: identifier, action: identify)
            }
            .contextMenu {
                if resolvedTrack != nil {
                    Button(action: onEdit) { Label("Edit Tracklist", systemImage: "pencil") }
                }
            }

            ZStack(alignment: .top) {
                if let list {
                    rows(list)
                } else {
                    emptyState
                }
                NowPlayingIdentifyCard(identifier: identifier, tint: tint, artworkURL: resolvedTrack?.artworkURL)
                    .padding(.horizontal, style.inset - 8)
                    .padding(.top, 2)
            }
            .frame(maxHeight: .infinity)
        }
        .task(id: FollowKey(trackId: trackId, anchor: timeline.anchor, count: list?.entries.count ?? 0)) {
            await follow()
        }
    }

    private func title(_ list: Tracklist?) -> String {
        guard let list else { return "No tracklist" }
        return list.entries.count == 1 ? "1 track" : "\(list.entries.count) tracks"
    }

    private func eyebrow(_ list: Tracklist?) -> String {
        guard let list else {
            if let trackId, setlists.scanningTrackIds.contains(trackId) { return "Finding tracks…" }
            return "Single track"
        }
        let unknown = list.entries.filter { NowPlayingSegmentText.isUnknown($0.segment) }.count
        return unknown == 0 ? "All identified" : "\(list.entries.count - unknown) identified · \(unknown) unknown"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("Tracklists appear for DJ mixes and long sets.\nIdentify still works on anything playing.")
                .font(.subheadline)
                .foregroundStyle(NPInk.tertiary)
                .multilineTextAlignment(.center)
            if let resolvedTrack, DeckIdentityResolver.isLikelyMix(resolvedTrack) {
                Button("Find Tracks", action: onEdit)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(.horizontal, style.inset)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func rows(_ list: Tracklist) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list.entries) { entry in
                        NowPlayingTracklistRow(
                            entry: entry,
                            isCurrent: entry.index == currentIndex,
                            tint: tint,
                            timeline: timeline,
                            onSeek: {
                                lastUserScroll = .distantPast
                                onSeek(entry.startSeconds + 0.05)
                            }
                        )
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, style.inset - 12)
                .padding(.top, 4)
                .animation(.easeInOut(duration: 0.4), value: currentIndex)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.bottom, 28, for: .scrollContent)
            .nowPlayingPaneFade()
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { lastUserScroll = .now }
            }
            .onAppear { scroll(proxy, list: list, animated: false) }
            .onChange(of: currentIndex) { _, _ in
                guard Date.now.timeIntervalSince(lastUserScroll) > 5 else { return }
                scroll(proxy, list: list, animated: !reduceMotion)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, list: Tracklist, animated: Bool) {
        guard let currentIndex, list.entries.indices.contains(currentIndex) else { return }
        let id = list.entries[currentIndex].id
        if animated {
            withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.28)) }
        } else {
            proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.28))
        }
    }

    private struct FollowKey: Equatable {
        let trackId: String?
        let anchor: PlaybackAnchor
        let count: Int
    }

    private func follow() async {
        while !Task.isCancelled {
            guard let list = tracklist else {
                currentIndex = nil
                return
            }
            let anchor = timeline.anchor
            let position = anchor.position(at: .now)
            let index = list.currentIndex(at: position)
            if index != currentIndex { currentIndex = index }
            guard anchor.isAdvancing else { return }
            let end = index.map { list.entries[$0].endSeconds } ?? list.entries.first?.startSeconds ?? anchor.duration
            let wait = min(30, max(0.25, end - position + 0.05))
            try? await Task.sleep(for: .seconds(wait / max(anchor.rate, 0.01)))
        }
    }

    private func identify() {
        identifier.identify(track: resolvedTrack, trackId: trackId, at: timeline.anchor.position(at: .now))
    }
}

private struct NowPlayingTracklistRow: View {
    let entry: TracklistEntry
    let isCurrent: Bool
    let tint: Color
    let timeline: NowPlayingTimeline
    let onSeek: () -> Void

    var body: some View {
        let unknown = NowPlayingSegmentText.isUnknown(entry.segment)
        let parts = NowPlayingSegmentText.parts(entry.segment)
        Button(action: onSeek) {
            HStack(spacing: 10) {
                Text(scFormatTime(entry.startSeconds))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(isCurrent ? NPInk.secondary : NPInk.tertiary)
                    .frame(minWidth: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(unknown ? "ID" : parts.title)
                        .font(.subheadline.weight(.semibold))
                        .tracking(unknown ? 1.5 : 0)
                        .foregroundStyle(isCurrent ? tint : (unknown ? NPInk.secondary : NPInk.primary))
                        .lineLimit(1)
                    Text(unknown ? "Unidentified" : (parts.artist ?? " "))
                        .font(.footnote)
                        .foregroundStyle(NPInk.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                    .opacity(isCurrent ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NPInk.fillStrong)
                }
            }
            .overlay(alignment: .bottom) {
                if isCurrent {
                    NowPlayingEntryProgress(entry: entry, timeline: timeline, tint: tint)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(scFormatTime(entry.startSeconds)), \(NowPlayingSegmentText.line(entry.segment))")
        .accessibilityValue(isCurrent ? "Playing now" : "")
        .accessibilityHint("Plays from this track")
    }
}

private struct NowPlayingEntryProgress: View {
    let entry: TracklistEntry
    let timeline: NowPlayingTimeline
    let tint: Color

    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var width: CGFloat = 0

    private var interval: TimeInterval {
        let pixels = max(1, Double(width * displayScale))
        return min(1, max(1.0 / 30, entry.durationSeconds / pixels))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: !timeline.anchor.isAdvancing || scenePhase != .active)) { context in
            let position = timeline.anchor.position(at: context.date)
            let fraction = entry.durationSeconds > 0
                ? min(1, max(0, (position - entry.startSeconds) / entry.durationSeconds))
                : 0
            Capsule()
                .fill(tint.opacity(0.5))
                .frame(width: width * CGFloat(fraction), height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityHidden(true)
    }
}

private struct NowPlayingIdentifyCard: View {
    let identifier: NowPlayingIdentifier
    let tint: Color
    let artworkURL: URL?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 52
    @State private var detail: IdentifySongRequest?

    var body: some View {
        ZStack {
            if identifier.state != .idle {
                card
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -10)).combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : NPMotion.spring, value: identifier.state)
        .sheet(item: $detail) { request in
            PhoneIdentifySongSheet(request: request)
        }
    }

    private var foundArtworkURL: URL? {
        identifier.song?.artworkURL ?? artworkURL
    }

    private var card: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                switch identifier.state {
                case .idle:
                    EmptyView()
                case .listening(let at):
                    Text("Listening…").font(.callout.weight(.bold))
                    Text("Hold on while we match \(scFormatTime(at))")
                        .font(.footnote).foregroundStyle(NPInk.secondary)
                case .found(let segment, let at):
                    Label("Found at \(scFormatTime(at))", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(SetlistText.normalized(segment.title)).font(.callout.weight(.bold))
                    Text(SetlistText.normalized(segment.artist) ?? "Added to the tracklist")
                        .font(.footnote).foregroundStyle(NPInk.secondary)
                case .noMatch(let at):
                    Text("No match at \(scFormatTime(at))").font(.callout.weight(.bold))
                    Text("Try again in a moment, when the track is clearer.")
                        .font(.footnote).foregroundStyle(NPInk.secondary)
                case .failed(let message):
                    Text("Couldn't Identify").font(.callout.weight(.bold))
                    Text(message).font(.footnote).foregroundStyle(NPInk.secondary)
                }
            }
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            if case .found = identifier.state, let song = identifier.song {
                Button("Details") { detail = IdentifySongRequest(mode: .song(song)) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NPInk.primary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 32)
                    .background(NPInk.fillStrong, in: Capsule())
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the song with SoundCloud matches, Apple Music and Share")
            }
            if !identifier.isListening {
                Button("Done") { identifier.dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 32)
                    .background(.white, in: Capsule())
                    .buttonStyle(.plain)
            }
        }
        .foregroundStyle(NPInk.primary)
        .padding(12)
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassEffect(.regular.tint(tint.opacity(0.2)), in: .rect(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leading: some View {
        switch identifier.state {
        case .found:
            SCArtworkResolver(url: foundArtworkURL, variant: .thumbnail) { image in
                SCArtwork(image: image, identity: identifier.song?.artIdentity ?? "identify", style: .phone, cornerRadius: 10)
            }
            .frame(width: tile, height: tile)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        default:
            Image(systemName: "shazam.logo.fill")
                .font(.system(size: 24))
                .foregroundStyle(tint)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: identifier.isListening && !reduceMotion)
                .frame(width: tile, height: tile)
                .background(NPInk.fillStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - Behind the Track

struct NowPlayingAboutPane: View {
    let track: Track?
    let commentCount: Int
    var style = NowPlayingPaneStyle()
    let onSeek: (TimeInterval) -> Void
    let onTracklist: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingPaneHeader(title: "Behind the Track", style: style) {
                Text(track?.title ?? "Now Playing")
            } actions: {
                EmptyView()
            }
            if let track {
                NowPlayingBehindTheTrack(
                    track: track,
                    commentCount: commentCount,
                    style: style,
                    onSeek: onSeek,
                    onTracklist: onTracklist
                )
            } else {
                ContentUnavailableView(
                    "No Details Yet",
                    systemImage: "info.circle",
                    description: Text("Details appear once the track loads.")
                )
                .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct NowPlayingBehindTheTrack: View {
    let track: Track
    let commentCount: Int
    let style: NowPlayingPaneStyle
    let onSeek: (TimeInterval) -> Void
    let onTracklist: () -> Void

    @StateObject private var model: BehindTheTrackModel
    @ObservedObject private var generated = GeneratedInsightsService.shared
    @State private var artist: User?
    @State private var album: Playlist?
    @Namespace private var albumNamespace

    init(track: Track, commentCount: Int, style: NowPlayingPaneStyle, onSeek: @escaping (TimeInterval) -> Void, onTracklist: @escaping () -> Void) {
        self.track = track
        self.commentCount = commentCount
        self.style = style
        self.onSeek = onSeek
        self.onTracklist = onTracklist
        _model = StateObject(wrappedValue: BehindTheTrackModel(track: track))
    }

    var body: some View {
        ScrollView {
            BehindTheTrackContent(
                model: model,
                actions: BehindTheTrackActions(
                    openUser: { artist = $0 },
                    search: { SearchRequestRouter.shared.search($0) },
                    seek: track.streamURL == nil ? nil : onSeek,
                    openTracklist: onTracklist,
                    openAlbum: { album = $0 }
                ),
                loadedCommentCount: commentCount
            ) {
                GeneratedInsightsSection(
                    insights: generated.insights(for: track.id),
                    foreground: NPInk.primary.opacity(0.9),
                    secondary: NPInk.secondary,
                    chipFill: NPInk.fill
                )
            }
            .padding(.horizontal, style.inset)
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, 28, for: .scrollContent)
        .nowPlayingPaneFade()
        .onChange(of: track, initial: false) { _, next in model.show(next) }
        .sheet(item: $artist) { user in
            NavigationStack {
                ArtistDetailView(user: user)
                    .appNavigationDestinations()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", role: .close) { artist = nil }
                        }
                    }
            }
            .addToPlaylistHost()
        }
        .sheet(item: $album) { playlist in
            NavigationStack {
                PlaylistDetailView(playlist: playlist, heroNamespace: albumNamespace)
                    .appNavigationDestinations()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", role: .close) { album = nil }
                        }
                    }
            }
            .addToPlaylistHost()
        }
    }
}
