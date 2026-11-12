import SwiftUI

struct CommentsListView: View {
    let track: Track?
    @ObservedObject var store: TrackCommentsStore
    let palette: ArtworkColors.Palette
    let onSeek: (TimeInterval) -> Void

    @EnvironmentObject var navigationState: NavigationState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedRow: String?

    private static let contentTop: CGFloat = 96
    private static let columnWidth: CGFloat = 1400

    var body: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
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
        .padding(.top, Self.contentTop)
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .background { NPCoverBackdrop(artworkURL: track?.artworkURL, palette: palette) }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(track?.title ?? "")
                .font(.callout)
                .foregroundStyle(Color.white.opacity(0.66))
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: Space.base) {
                Text("Comments")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                if let count = countText {
                    Text(count)
                        .font(.callout)
                        .foregroundStyle(Color.white.opacity(0.66))
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("comments.header")
    }

    private var countText: String? {
        guard store.state == .loaded, !store.comments.isEmpty else { return nil }
        return store.pager.countText(singular: "comment", plural: "comments")
    }

    private var commentsList: some View {
        let threadSet = CommentThreadBuilder.build(store.comments)
        let firstRootID = (threadSet.timed.first ?? threadSet.untimed.first)?.root.id
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.hair) {
                if !threadSet.timed.isEmpty {
                    sectionHeader("On This Track")
                    threadRows(threadSet.timed)
                }
                if !threadSet.untimed.isEmpty {
                    sectionHeader("General")
                        .padding(.top, threadSet.timed.isEmpty ? 0 : Space.roomy)
                    threadRows(threadSet.untimed)
                }
                if let paging = TVPaging(store.pager) {
                    TVPagedFooter(paging: paging)
                }
            }
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Space.section)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .defaultFocus($focusedRow, firstRootID, priority: .userInitiated)
        .focusSection(when: !threadSet.timed.isEmpty || !threadSet.untimed.isEmpty)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Color.white.opacity(0.66))
            .padding(.bottom, Space.tight)
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
                    .padding(.horizontal, 22)
                    .padding(.vertical, Space.snug)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(CommentRowStyle(isSeekable: isSeekable))
            .focused(focus, equals: comment.id)
            .accessibilityHint(isSeekable ? "Jumps to this moment in the track" : "")
            .accessibilityIdentifier("comments.row.\(comment.id)")

            if let onSearch {
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 26, weight: .semibold))
                }
                .buttonStyle(NPCircleStyle(diameter: Control.circle, label: "Search"))
                .accessibilityLabel("Search")
                .accessibilityHint("Searches SoundCloud for this comment's track")
                .accessibilityIdentifier("comments.search.\(comment.id)")
            }
        }
        .padding(.leading, -22)
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
                .contentShape(shape)
                .scaleEffect(isFocused ? 1.02 : 1)
                .offset(y: isFocused ? -2 : 0)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 20, y: 10)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}
