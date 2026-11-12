import SwiftUI

struct CommentsListView: View {
    let track: Track?
    @ObservedObject var store: TrackCommentsStore
    let palette: ArtworkColors.Palette
    let onSeek: (TimeInterval) -> Void

    @EnvironmentObject var navigationState: NavigationState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var closeFocused: Bool
    @FocusState private var focusedRow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            header

            Group {
                switch store.state {
                case .idle, .loading:
                    StatusPanel(kind: .loading, title: "Loading Comments…")
                case .failed:
                    StatusPanel(
                        kind: .error,
                        title: "Couldn't Load Comments",
                        message: "Check this Apple TV's network connection.",
                        actionTitle: "Try Again",
                        action: { store.retry(for: track) }
                    )
                case .loaded where store.comments.isEmpty:
                    StatusPanel(
                        kind: .empty,
                        icon: "bubble.left.and.bubble.right",
                        title: "No Comments Yet",
                        message: "Nobody's said anything on this one yet."
                    )
                case .loaded:
                    commentsList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, Space.page)
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(edges: [.horizontal, .bottom])
        .background { backdrop }
        .environment(\.colorScheme, .dark)
        .defaultFocus($closeFocused, true)
        .onAppear { DispatchQueue.main.async { closeFocused = true } }
    }

    private var backdrop: some View {
        ZStack {
            NPBackdrop(artworkURL: track?.artworkURL, palette: palette, isAnimating: !reduceMotion && scenePhase == .active)
            NPLegibilityScrim(palette: palette)
            Color.black.opacity(0.22)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 26) {
            ArtworkImage(url: track?.artworkURL, identity: track?.id)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Comments")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            PanelCloseButton { dismiss() }
                .focused($closeFocused)
                .accessibilityIdentifier("comments.close")
        }
    }

    private var subtitle: String {
        guard let track else { return "" }
        guard store.state == .loaded, !store.comments.isEmpty else { return track.title }
        return "\(track.title) \u{00B7} \(store.pager.countText(singular: "comment", plural: "comments"))"
    }

    private var commentsList: some View {
        let threadSet = CommentThreadBuilder.build(store.comments)
        let firstRootID = (threadSet.timed.first ?? threadSet.untimed.first)?.root.id
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if !threadSet.timed.isEmpty {
                    sectionHeader("On This Track")
                    threadRows(threadSet.timed)
                }
                if !threadSet.untimed.isEmpty {
                    sectionHeader("General")
                        .padding(.top, threadSet.timed.isEmpty ? 0 : 30)
                    threadRows(threadSet.untimed)
                }
                if let paging = TVPaging(store.pager) {
                    TVPagedFooter(paging: paging)
                }
            }
            .frame(maxWidth: 1400, alignment: .leading)
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .defaultFocus($focusedRow, firstRootID, priority: .userInitiated)
        .focusSection(when: !threadSet.timed.isEmpty || !threadSet.untimed.isEmpty)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func threadRows(_ threads: [CommentThread]) -> some View {
        ForEach(threads) { thread in
            TVCommentRow(
                comment: thread.root,
                focus: $focusedRow,
                onSeek: onSeek,
                onSearch: searchAction(for: thread.root)
            )
            ForEach(thread.replies) { reply in
                TVCommentRow(
                    comment: reply,
                    isReply: true,
                    focus: $focusedRow,
                    onSeek: onSeek,
                    onSearch: searchAction(for: reply)
                )
            }
        }
    }

    private func searchAction(for comment: Comment) -> (() -> Void)? {
        guard let query = comment.searchQuery else { return nil }
        return {
            navigationState.pendingSearchQuery = query
            navigationState.selectedTab = .search
            dismiss()
        }
    }
}

private struct TVCommentRow: View {
    let comment: Comment
    var isReply: Bool = false
    var focus: FocusState<String?>.Binding
    let onSeek: (TimeInterval) -> Void
    let onSearch: (() -> Void)?

    private var isSeekable: Bool { comment.timeInTrack != nil }

    private static let style: SCContentStyle = {
        var style = SCContentStyle.tv
        style.accent = style.textSecondary
        return style
    }()

    var body: some View {
        HStack(alignment: .center, spacing: Space.base) {
            Button {
                guard let time = comment.timeInTrack else { return }
                onSeek(time)
            } label: {
                SCCommentRow(comment: comment, isReply: isReply, style: Self.style)
                    .padding(.horizontal, Space.snug)
                    .padding(.vertical, Space.tight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
            }
            .buttonStyle(CommentRowStyle(isSeekable: isSeekable))
            .focused(focus, equals: comment.id)
            .accessibilityHint(isSeekable ? "Jumps to this moment in the track" : "")
            .accessibilityIdentifier("comments.row.\(comment.id)")

            if let onSearch {
                SearchThisButton(action: onSearch)
                    .accessibilityIdentifier("comments.search.\(comment.id)")
            }
        }
        .padding(.horizontal, Space.snug)
    }
}

private struct SearchThisButton: View {
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Label("Search", systemImage: "magnifyingglass")
                .font(.tvCaptionEmph)
                .foregroundStyle(focused ? Color.scChromeFocusOn : Color.scTextPrimary)
                .padding(.horizontal, Space.snug)
                .padding(.vertical, Space.tight)
                .background { Capsule().fill(Color.scChromeFocus).opacity(focused ? 1 : 0) }
                .liquidGlass(in: Capsule(), interactive: true)
                .contentShape(Capsule())
        }
        .buttonStyle(SCShapeButtonStyle(shape: Capsule(), sizeClass: .card))
        .focused($focused)
        .accessibilityLabel("Search")
        .accessibilityHint("Searches SoundCloud for this comment's track")
    }
}

private struct CommentRowStyle: ButtonStyle {
    let isSeekable: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isSeekable: isSeekable)
    }

    private struct Styled: View {
        let configuration: Configuration
        let isSeekable: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
            configuration.label
                .background {
                    shape
                        .fill(Color.white.opacity(isSeekable ? 0.14 : 0.08))
                        .opacity(isFocused ? 1 : 0)
                }
                .overlay {
                    shape
                        .fill(LinearGradient(colors: [Color.white.opacity(0.12), .clear], startPoint: .top, endPoint: .center))
                        .opacity(isFocused ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .scaleEffect(isFocused ? 1.02 : 1)
                .offset(y: isFocused ? -2 : 0)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 20, y: 10)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}
