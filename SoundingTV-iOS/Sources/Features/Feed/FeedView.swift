import SwiftUI

struct FeedView: View {
    @ObservedObject var viewModel: FeedViewModel
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var confirmation = QueueConfirmationController()
    @State private var isShowingSignIn = false

    private static let subject = "Following"

    var body: some View {
        Group {
            #if DEBUG
            if let forced = Self.debugForcedState {
                switch forced {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .error:
                    SCEmptyState(
                        kind: .error, title: LoadFailure.sessionRejected.title,
                        message: LoadFailure.sessionRejected.message(subject: Self.subject),
                        actionTitle: LoadFailure.sessionRejected.actionTitle, action: {}, style: .phone
                    )
                case .empty:
                    SCEmptyState(
                        icon: "person.2", title: "Nothing Here Yet",
                        message: "Follow artists on SoundCloud. Their uploads, playlists and reposts show up here.",
                        actionTitle: "Refresh", action: {}, style: .phone
                    )
                case .loaded:
                    List {
                        ForEach(FeedDebugFixtures.activities) { activity in
                            FeedActivityRow(
                                activity: activity,
                                context: { FeedDebugFixtures.activities.compactMap(\.track) },
                                confirmation: confirmation
                            )
                        }
                    }
                    .listStyle(.plain)
                }
            } else if credentials.needsSignIn && !usesVisualFixtures {
                signInPrompt
            } else {
                browserContent
            }
            #else
            if credentials.needsSignIn {
                signInPrompt
            } else {
                browserContent
            }
            #endif
        }
        .task {
            await credentials.prepareStoreAtLaunch()
            await loadFeedIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            credentials.refreshFromStore()
        }
        .queueConfirmationOverlay(confirmation)
        .sheet(isPresented: $isShowingSignIn) { signInSheet }
    }

    private var usesVisualFixtures: Bool {
        #if DEBUG
        VisualFixtures.isEnabled
        #else
        false
        #endif
    }

    private enum FeedBrowserState: Equatable {
        case loading, loaded, empty, failed(LoadFailure)
    }

    private var feedState: FeedBrowserState {
        if !viewModel.items.isEmpty { return .loaded }
        if !viewModel.loadedOnce || ((viewModel.isLoading || viewModel.pager.isPaused) && viewModel.items.isEmpty) {
            return .loading
        }
        if let error = viewModel.error, viewModel.items.isEmpty {
            return .failed(LoadFailure.classify(error))
        }
        if viewModel.items.isEmpty {
            return .empty
        }
        return .loaded
    }

    @ViewBuilder
    private var browserContent: some View {
        switch feedState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let failure):
            SCEmptyState(
                kind: failure.isFault ? .error : .empty,
                icon: failure.icon,
                title: failure.title,
                message: failure.message(subject: Self.subject),
                actionTitle: failure.actionTitle,
                action: { recover(from: failure) },
                style: .phone
            )

        case .empty:
            SCEmptyState(
                icon: "person.2",
                title: "Nothing Here Yet",
                message: "Follow artists on SoundCloud. Their uploads, playlists and reposts show up here.",
                actionTitle: "Refresh", action: { Task { await loadFeed() } },
                style: .phone
            )

        case .loaded:
            List {
                ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, activity in
                    FeedActivityRow(
                        activity: activity,
                        context: { viewModel.items.compactMap(\.track) },
                        confirmation: confirmation
                    )
                    .promotedImpression(activity)
                    .onAppear {
                        guard viewModel.items.isNearEnd(activity, lead: 10) else { return }
                        viewModel.requestMore()
                    }
                    .onAppear {
                        let lookahead = viewModel.items[index..<min(index + Self.artworkLookahead, viewModel.items.count)]
                        ArtworkCache.shared.prefetch(lookahead.compactMap { $0.track?.artworkURL ?? $0.playlist?.displayArtworkURL }, variant: .thumbnail)
                    }
                }
                PagedFooter(pager: viewModel.pager)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .refreshable { await loadFeed() }
        }
    }

    private static let artworkLookahead = 10

    private var signInPrompt: some View {
        let failure = LoadFailure.credentialFailure()
        return SCEmptyState(
            kind: .empty,
            icon: failure.icon,
            title: failure.title,
            message: failure.message(subject: Self.subject),
            actionTitle: failure.actionTitle,
            action: { isShowingSignIn = true },
            style: .phone
        )
    }

    private func recover(from failure: LoadFailure) {
        switch failure.recovery {
        case .retry:  Task { await loadFeed() }
        case .signIn: isShowingSignIn = true
        }
    }

    private var signInSheet: some View {
        NavigationStack {
            SoundCloudLoginView.standalone {
                isShowingSignIn = false
                credentials.refreshFromStore()
                Task { await loadFeed() }
            }
        }
    }

    private func loadFeedIfNeeded() async {
        guard usesVisualFixtures || SoundCloudCredentialSource.shared.accessToken != nil else { return }
        await viewModel.refreshIfStale()
    }

    private func loadFeed() async {
        guard SoundCloudCredentialSource.shared.accessToken != nil else { return }
        await viewModel.loadContent()
    }

    private enum DebugForcedFeedState { case loading, error, empty, loaded }

    private static var debugForcedState: DebugForcedFeedState? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_FEED_STATE"] {
        case "loading": return .loading
        case "error":   return .error
        case "empty":   return .empty
        case "loaded":  return .loaded
        default:        return nil
        }
        #else
        return nil
        #endif
    }
}

#if DEBUG
private enum FeedDebugFixtures {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .formatted(formatter)
        return d
    }()

    private static func userJSON(id: Int, name: String) -> String {
        """
        { "id": \(id), "username": "\(name)", "permalink": "\(name)",
          "permalink_url": "https://soundcloud.com/\(name)",
          "avatar_url": null,
          "full_name": "\(name.capitalized)" }
        """
    }

    private static func trackJSON(id: Int, title: String, ownerID: Int, ownerName: String) -> String {
        """
        {
            "id": \(id), "title": "\(title)", "description": null,
            "artwork_url": null,
            "waveform_url": null,
            "permalink_url": "https://soundcloud.com/\(ownerName)/\(id)",
            "playback_count": \(id * 137), "likes_count": \(id * 11), "reposts_count": 4,
            "created_at": "2024-09-01T12:00:00Z",
            "user": \(userJSON(id: ownerID, name: ownerName)),
            "media": { "transcodings": [
                { "url": "https://api-v2.soundcloud.com/media/soundcloud:tracks:\(id)/stream/progressive",
                  "preset": "mp3_1_0", "duration": 210000, "quality": "sq", "snipped": false,
                  "format": { "protocol": "progressive", "mime_type": "audio/mpeg" } }
            ] }
        }
        """
    }

    private static func playlistJSON(id: Int, title: String, ownerID: Int, ownerName: String) -> String {
        """
        {
            "id": \(id), "title": "\(title)", "description": null,
            "artwork_url": null,
            "permalink_url": "https://soundcloud.com/\(ownerName)/sets/\(id)",
            "duration": 5400000, "track_count": 22, "likes_count": 340, "reposts_count": 12,
            "created_at": "2024-09-01T12:00:00Z", "is_album": false,
            "user": \(userJSON(id: ownerID, name: ownerName))
        }
        """
    }

    private static func activityJSON(type: String, actorID: Int, actorName: String, uuid: String, body: String) -> String {
        """
        { "type": "\(type)", "created_at": "2024-09-02T08:00:00Z", "uuid": "\(uuid)",
          "user": \(userJSON(id: actorID, name: actorName)), \(body) }
        """
    }

    static let activities: [FeedActivity] = {
        let sources: [String] = [
            activityJSON(
                type: "track", actorID: 100, actorName: "midnight-runner", uuid: "fixture-1",
                body: "\"track\": \(trackJSON(id: 1, title: "Coastline", ownerID: 100, ownerName: "midnight-runner"))"
            ),
            activityJSON(
                type: "track-repost", actorID: 200, actorName: "afr", uuid: "fixture-2",
                body: "\"track\": \(trackJSON(id: 2, title: "Late Bloomer", ownerID: 101, ownerName: "phoebe-b"))"
            ),
            activityJSON(
                type: "playlist", actorID: 102, actorName: "night-drives", uuid: "fixture-3",
                body: "\"playlist\": \(playlistJSON(id: 10, title: "Late Night", ownerID: 102, ownerName: "night-drives"))"
            ),
            activityJSON(
                type: "playlist-repost", actorID: 200, actorName: "afr", uuid: "fixture-4",
                body: "\"playlist\": \(playlistJSON(id: 11, title: "Focus", ownerID: 103, ownerName: "study-beats"))"
            ),
            activityJSON(
                type: "track", actorID: 104, actorName: "fred-again", uuid: "fixture-5",
                body: "\"track\": \(trackJSON(id: 3, title: "Daylight", ownerID: 104, ownerName: "fred-again"))"
            ),
        ]
        return sources.compactMap { try? decoder.decode(FeedActivity.self, from: Data($0.utf8)) }
    }()
}
#endif

@MainActor
private func feedFailureMessage(_ error: Error) -> String {
    LoadFailure.classify(error).title
}

private struct FeedActivityRow: View {
    let activity: FeedActivity
    let context: () -> [Track]
    @ObservedObject var confirmation: QueueConfirmationController

    var body: some View {
        switch activity.kind {
        case .track, .trackRepost, .trackPromoted:
            if let track = activity.track {
                FeedTrackRow(activity: activity, track: track, context: context, confirmation: confirmation)
            }

        case .playlist, .playlistRepost, .playlistPromoted:
            if let playlist = activity.playlist {
                FeedPlaylistRow(activity: activity, playlist: playlist, confirmation: confirmation)
            }
        }
    }
}

private struct FeedSocialActions: View {
    let isLiked: Bool
    let isReposted: Bool
    let isMutating: Bool
    let like: () -> Void
    let repost: () -> Void
    var comment: (() -> Void)?

    var body: some View {
        Button(action: like) {
            Label(isLiked ? "Unlike" : "Like", systemImage: isLiked ? "heart.slash" : "heart")
        }
        .disabled(isMutating)
        Button(action: repost) {
            Label(isReposted ? "Remove Repost" : "Repost", systemImage: "arrow.2.squarepath")
        }
        .disabled(isMutating)
        if let comment {
            Button(action: comment) {
                Label("Comment", systemImage: "bubble.left")
            }
        }
    }
}

private struct FeedMoreButton<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More actions for \(title)")
    }
}

private struct FeedPlaylistRow: View {
    let activity: FeedActivity
    let playlist: Playlist
    @ObservedObject var confirmation: QueueConfirmationController

    @State private var isLiked: Bool
    @State private var isReposted: Bool
    @State private var isMutating = false
    @Namespace private var heroNamespace

    init(activity: FeedActivity, playlist: Playlist, confirmation: QueueConfirmationController) {
        self.activity = activity
        self.playlist = playlist
        self.confirmation = confirmation
        _isLiked = State(initialValue: playlist.userFavorite)
        _isReposted = State(initialValue: playlist.userReposted)
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            PlaylistLink(playlist, heroNamespace: heroNamespace, onOpen: { PromotedTracking.shared.record(.click, for: activity) }) {
                FeedRowLabel(activity: activity, isLiked: isLiked)
                    .matchedTransitionSource(id: playlist.id, in: heroNamespace)
            }

            FeedMoreButton(title: playlist.title) { menuActions }
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 52 + Spacing.md }
        .libraryRowPreviewShape()
        .contextMenu { menuActions }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: mutateLike) {
                Label(isLiked ? "Unlike" : "Like", systemImage: isLiked ? "heart.slash" : "heart")
            }
            .tint(.pink)
            Button(action: mutateRepost) {
                Label(isReposted ? "Remove Repost" : "Repost", systemImage: "arrow.2.squarepath")
            }
            .tint(.indigo)
        }
        .accessibilityActions { socialActions }
    }

    @ViewBuilder
    private var socialActions: some View {
        FeedSocialActions(
            isLiked: isLiked, isReposted: isReposted, isMutating: isMutating,
            like: mutateLike, repost: mutateRepost
        )
    }

    @ViewBuilder
    private var menuActions: some View {
        socialActions
        ShareLink(item: playlist.permalinkURL, preview: SharePreview(playlist.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private func mutateLike() {
        let target = !isLiked
        isLiked = target
        isMutating = true
        Task {
            do { try await SoundCloudAPI.shared.setPlaylistLiked(target, playlist: playlist) }
            catch {
                isLiked.toggle()
                confirmation.show(feedFailureMessage(error), icon: "exclamationmark.triangle.fill")
            }
            isMutating = false
        }
    }

    private func mutateRepost() {
        let target = !isReposted
        isReposted = target
        isMutating = true
        Task {
            do { try await SoundCloudAPI.shared.setPlaylistReposted(target, playlist: playlist) }
            catch {
                isReposted.toggle()
                confirmation.show(feedFailureMessage(error), icon: "exclamationmark.triangle.fill")
            }
            isMutating = false
        }
    }
}

private struct FeedTrackRow: View {
    let activity: FeedActivity
    let track: Track
    let context: () -> [Track]
    @ObservedObject var confirmation: QueueConfirmationController

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    @State private var isLiked: Bool
    @State private var isReposted: Bool
    @State private var isMutating = false
    @State private var isShowingComments = false
    @State private var locallyMutatedLikeTrackId: String?

    init(
        activity: FeedActivity,
        track: Track,
        context: @escaping () -> [Track],
        confirmation: QueueConfirmationController
    ) {
        self.activity = activity
        self.track = track
        self.context = context
        self.confirmation = confirmation
        _isLiked = State(initialValue: track.userFavorite)
        _isReposted = State(initialValue: track.userReposted)
    }

    private var isPlayable: Bool { track.streamURL != nil }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Button {
                PromotedTracking.shared.record(.play, for: activity)
                Task { await coordinator.play(track, in: context()) }
            } label: {
                FeedRowLabel(activity: activity, activityState: rowActivity, isLiked: isLiked)
            }
            .buttonStyle(WarmStreamOnPressButtonStyle(track: track))
            .disabled(!isPlayable)
            .accessibilityLabel("\(track.title) by \(track.user.displayName)\(isPlayable ? "" : ", unavailable")")
            .accessibilityHint(isPlayable ? "Plays on this device" : "This track isn't available to play")

            FeedMoreButton(title: track.title) { menuActions }
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 52 + Spacing.md }
        .libraryRowPreviewShape()
        .contextMenu { menuActions }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: mutateLike) {
                Label(isLiked ? "Unlike" : "Like", systemImage: isLiked ? "heart.slash" : "heart")
            }
            .tint(.pink)
            Button(action: mutateRepost) {
                Label(isReposted ? "Remove Repost" : "Repost", systemImage: "arrow.2.squarepath")
            }
            .tint(.indigo)
            Button { isShowingComments = true } label: {
                Label("Comment", systemImage: "bubble.left")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if isPlayable {
                Button { queue() } label: {
                    Label("Add to Up Next", systemImage: "text.append")
                }
                TrackDownloadSwipeAction(track: track)
            }
        }
        .accessibilityActions {
            socialActions
            secondaryActions
        }
        .sheet(isPresented: $isShowingComments) {
            FeedCommentsSheet(track: track)
        }
        .task(id: track.id) {
            await refreshLikeState()
        }
        .onReceive(LikesSyncEngine.shared.$revision.dropFirst()) { _ in
            Task { await refreshLikeState() }
        }
    }

    @ViewBuilder
    private var socialActions: some View {
        FeedSocialActions(
            isLiked: isLiked, isReposted: isReposted, isMutating: isMutating,
            like: mutateLike, repost: mutateRepost, comment: { isShowingComments = true }
        )
    }

    @ViewBuilder
    private var menuActions: some View {
        BehindTheTrackMenuButton(track: track)
        socialActions
        Divider()
        secondaryActions
        ShareLink(item: track.permalinkURL, preview: SharePreview(track.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private func refreshLikeState() async {
        guard locallyMutatedLikeTrackId != track.id else { return }
        let indexed = await LibraryCache.shared.containsLike(id: track.id)
        guard locallyMutatedLikeTrackId != track.id else { return }
        isLiked = track.userFavorite || indexed
    }

    private func mutateLike() {
        let target = !isLiked
        isLiked = target
        isMutating = true
        locallyMutatedLikeTrackId = track.id
        Task {
            do {
                if target { try await SoundCloudAPI.shared.likeTrack(track) }
                else { try await SoundCloudAPI.shared.unlikeTrack(track) }
            } catch {
                isLiked.toggle()
                locallyMutatedLikeTrackId = nil
                confirmation.show(feedFailureMessage(error), icon: "exclamationmark.triangle.fill")
            }
            isMutating = false
        }
    }

    private func mutateRepost() {
        let target = !isReposted
        isReposted = target
        isMutating = true
        Task {
            do { try await SoundCloudAPI.shared.setTrackReposted(target, track: track) }
            catch {
                isReposted.toggle()
                confirmation.show(feedFailureMessage(error), icon: "exclamationmark.triangle.fill")
            }
            isMutating = false
        }
    }

    private var rowActivity: FeedTrackActivity {
        guard let snapshot = coordinator.nowPlaying, snapshot.trackId == track.id else { return .none }
        if snapshot.isLoading { return .loading }
        return snapshot.isPlaying ? .playing : .paused
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if isPlayable {
            Button { queue() } label: {
                Label("Add to Up Next", systemImage: "text.append")
            }
            TrackDownloadMenuItems(track: track)
        }
        AddToPlaylistMenuButton(track: track)
        WakeToThisMenuButton(track: track)
    }

    private func queue() {
        coordinator.addToQueue(track)
        confirmation.show("Added \u{201C}\(track.title)\u{201D} to Up Next")
    }
}

private enum FeedTrackActivity: Equatable {
    case none, loading, playing, paused
}

private struct FeedCommentsSheet: View {
    let track: Track

    @Environment(\.dismiss) private var dismiss
    @StateObject private var pager: Paginator<Comment>
    @State private var draft = ""
    @State private var isPosting = false
    @State private var errorMessage: String?
    @FocusState private var composerFocused: Bool

    init(track: Track) {
        self.track = track
        let trackId = track.id
        _pager = StateObject(wrappedValue: Paginator(soundCloudSource: PagedSource(
            first: {
                let page = try await SoundCloudAPI.shared.getComments(trackId: trackId)
                return PagedChunk(items: page.collection, next: page.nextHref.map { .url($0) })
            },
            next: { cursor in
                guard case .url(let url) = cursor else { return PagedChunk(items: []) }
                let page = try await SoundCloudAPI.shared.getPage(Comment.self, from: url)
                return PagedChunk(items: page.collection, next: page.nextHref.map { .url($0) })
            }
        )))
    }

    private var comments: [Comment] { pager.items }

    var body: some View {
        NavigationStack {
            Group {
                if (pager.isLoadingFirst || !pager.hasLoadedFirst && pager.firstError == nil) && comments.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError = loadErrorMessage, comments.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn\u{2019}t Load Comments", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if comments.isEmpty {
                    ContentUnavailableView(
                        "No Comments Yet",
                        systemImage: "bubble.left",
                        description: Text("Start the conversation on “\(track.title)”.")
                    )
                } else {
                    List {
                        ForEach(comments) { comment in
                            SCCommentRow(comment: comment, style: .phone)
                                .padding(.vertical, 4)
                                .contextMenu {
                                    Button {
                                        draft = "@\(comment.user.username) "
                                        composerFocused = true
                                    } label: {
                                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                                    }
                                }
                                .onAppear { pager.loadMoreIfNeeded(after: comment, lead: 10) }
                        }
                        PagedFooter(pager: pager)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .task { await load() }
            .alert("Couldn’t Post Comment", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Try again.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Spacing.sm) {
            TextField("Add a comment", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Button { Task { await post() } } label: {
                if isPosting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(width: 44, height: 44)
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(isPosting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Post comment")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private var loadErrorMessage: String? {
        pager.firstError.map { LoadFailure.classify($0).message(subject: "comments") }
    }

    private func load() async {
        await pager.reload()
    }

    private func post() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        isPosting = true
        defer { isPosting = false }
        do {
            let comment = try await SoundCloudAPI.shared.postComment(trackId: track.id, body: body)
            pager.prime(items: pager.items + [comment], cursor: pager.cursor, total: pager.total)
            draft = ""
        } catch {
            errorMessage = LoadFailure.classify(error).title
        }
    }
}

private struct FeedRowLabel: View {
    let activity: FeedActivity
    var activityState: FeedTrackActivity = .none
    var isLiked = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isPlayableTrack: Bool { activity.track == nil || activity.track?.streamURL != nil }

    var body: some View {
        HStack(spacing: Spacing.md) {
            if !dynamicTypeSize.isAccessibilitySize {
                ArtworkImage(
                    url: activity.track?.artworkURL ?? activity.playlist?.displayArtworkURL,
                    variant: .thumbnail,
                    icon: activity.playlist != nil ? "music.note.list" : "music.note",
                    identity: activity.track?.id ?? activity.playlist?.id
                )
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: Corner.thumb, style: .continuous))
                .kyleCrowned(
                    user: activity.track?.user ?? activity.playlist?.user,
                    context: activity.track?.title ?? activity.playlist?.title
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                if let promotedLabel = activity.promotedLabel {
                    Text(promotedLabel)
                        .font(.scCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                } else if activity.isRepost {
                    Label("Reposted by \(activity.actor.displayName)", systemImage: "arrow.2.squarepath")
                        .font(.scCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
                Text(activity.track?.title ?? activity.playlist?.title ?? "")
                    .font(.scBody)
                    .foregroundStyle(activityState == .none ? Color.primary : Color.scAccent)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                Text(subtitle)
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            }

            Spacer(minLength: Spacing.sm)

            if isLiked {
                Image(systemName: "heart.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Liked")
            }

            trailing
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
        .opacity(isPlayableTrack ? 1 : 0.5)
    }

    private var subtitle: String {
        if let playlist = activity.playlist {
            return "\(playlist.trackCount.trackCountLabel) \u{00B7} \(playlist.user.displayName)"
        }
        return activity.track?.user.displayName ?? ""
    }

    @ViewBuilder
    private var trailing: some View {
        switch activityState {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading")
        case .playing:
            Image(systemName: "waveform")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.scAccent)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                .accessibilityLabel("Now Playing")
        case .paused:
            Image(systemName: "pause.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.scAccent)
                .accessibilityLabel("Paused")
        case .none:
            trailingIdle
        }
    }

    @ViewBuilder
    private var trailingIdle: some View {
        if let track = activity.track {
            if track.streamURL != nil {
                Text(SubscriptionService.shared.displayedDuration(for: track))
                    .font(.scNumeric)
                    .foregroundStyle(.secondary)
            } else {
                Label("Unavailable", systemImage: "lock.fill")
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
