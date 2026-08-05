import SwiftUI

struct CommentsListView: View {
    let track: Track?
    @ObservedObject var store: TrackCommentsStore
    let palette: ArtworkColors.Palette
    let onSeek: (TimeInterval) -> Void

    @EnvironmentObject var navigationState: NavigationState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
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
        .padding(Spacing.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.scBackground.ignoresSafeArea())
        .defaultFocus($closeFocused, true)
        .onAppear { DispatchQueue.main.async { closeFocused = true } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Eyebrow(text: "Comments")
                Text(track?.title ?? "Comments")
                    .font(.tvTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer()
            PanelCloseButton { dismiss() }
                .focused($closeFocused)
                .accessibilityIdentifier("comments.close")
        }
    }

    private var commentsList: some View {
        let threadSet = CommentThreadBuilder.build(store.comments)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.tight) {
                if !threadSet.timed.isEmpty {
                    Eyebrow(text: "On This Track")
                    threadRows(threadSet.timed)
                }
                if !threadSet.untimed.isEmpty {
                    Eyebrow(text: "General")
                        .padding(.top, threadSet.timed.isEmpty ? 0 : Space.base)
                    threadRows(threadSet.untimed)
                }
            }
            .padding(.bottom, Spacing.xl)
        }
        // Only a focus section when it actually contains focusable rows.
        .focusSection(when: !threadSet.timed.isEmpty || !threadSet.untimed.isEmpty)
    }

    @ViewBuilder
    private func threadRows(_ threads: [CommentThread]) -> some View {
        ForEach(threads) { thread in
            TVCommentRow(
                comment: thread.root,
                onSeek: onSeek,
                onSearch: searchAction(for: thread.root)
            )
            ForEach(thread.replies) { reply in
                TVCommentRow(
                    comment: reply,
                    isReply: true,
                    onSeek: onSeek,
                    onSearch: searchAction(for: reply)
                )
            }
        }
    }

    private func searchAction(for comment: Comment) -> (() -> Void)? {
        guard comment.searchQuery != nil else { return nil }
        return {
            navigationState.selectedTab = .search
            dismiss()
        }
    }
}

private struct TVCommentRow: View {
    let comment: Comment
    var isReply: Bool = false
    let onSeek: (TimeInterval) -> Void
    let onSearch: (() -> Void)?

    @FocusState private var rowFocused: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSeekable: Bool { comment.timeInTrack != nil }

    var body: some View {
        HStack(alignment: .top, spacing: Space.snug) {
            SCCommentRow(comment: comment, isReply: isReply, style: .tv)

            if let onSearch {
                SearchThisButton(action: onSearch)
                    .focused($searchFocused)
            }
        }
        .padding(.horizontal, Space.snug)
        .padding(.vertical, Space.tight)
        .background(
            RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                .fill(Color.white.opacity(rowFocused ? (isSeekable ? 0.14 : 0.08) : 0))
        )
        .scFocus(rowFocused, cornerRadius: Corner.card, reduceMotion: reduceMotion)
        .contentShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
        .focusable()
        .focused($rowFocused)
        .focusEffectDisabled()
        .onTapGesture {
            guard let time = comment.timeInTrack else { return }
            onSeek(time)
        }
        .accessibilityIdentifier("comments.row.\(comment.id)")
    }
}

private struct SearchThisButton: View {
    let action: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
            Text("Search")
        }
        .font(.tvCaptionEmph)
        .foregroundStyle(Color.scTextPrimary)
        .padding(.horizontal, Space.snug)
        .padding(.vertical, Space.tight)
        .liquidGlass(in: Capsule(), interactive: true)
        .scFocus(focused, in: Capsule(), reduceMotion: reduceMotion)
        .contentShape(Capsule())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
    }
}
