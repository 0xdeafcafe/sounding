import SwiftUI

struct FeedView: View {
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @StateObject private var viewModel = FeedViewModel()
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmation: FeedConfirmation?
    @State private var isShowingSignIn = false

    var body: some View {
        Group {
            #if DEBUG
            if let forced = Self.debugForcedState {
                switch forced {
                case .loading:
                    FeedLoadingState(message: "Loading your stream…")
                case .error:
                    SCEmptyState(
                        kind: .error, title: LoadFailure.sessionRejected.title,
                        message: LoadFailure.sessionRejected.message(subject: "your stream"),
                        actionTitle: LoadFailure.sessionRejected.actionTitle, action: {}, style: .phone
                    )
                case .empty:
                    SCEmptyState(
                        icon: "dot.radiowaves.up.forward", title: "Nothing Here Yet",
                        message: "Follow artists on SoundCloud. Their uploads, playlists and reposts show up here.",
                        actionTitle: "Refresh", action: {}, style: .phone
                    )
                case .loaded:
                    List {
                        ForEach(FeedDebugFixtures.activities) { activity in
                            FeedActivityRow(
                                activity: activity,
                                context: { FeedDebugFixtures.activities.compactMap(\.track) },
                                confirmation: $confirmation
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
        .scrollContentBackground(.hidden)
        .background(Color.scBgBase.ignoresSafeArea())
        .task {
            credentials.refreshFromStore()
            await loadFeedIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            credentials.refreshFromStore()
        }
        .feedConfirmationOverlay($confirmation)
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
        if !viewModel.loadedOnce || (viewModel.isLoading && viewModel.items.isEmpty) {
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
            FeedLoadingState(message: "Loading your stream…")

        case .failed(let failure):
            SCEmptyState(
                kind: failure.isFault ? .error : .empty,
                icon: failure.icon,
                title: failure.title,
                message: failure.message(subject: "your stream"),
                actionTitle: failure.actionTitle,
                action: { recover(from: failure) },
                style: .phone
            )
            .phoneStateLayout()

        case .empty:
            SCEmptyState(
                icon: "dot.radiowaves.up.forward",
                title: "Nothing Here Yet",
                message: "Follow artists on SoundCloud. Their uploads, playlists and reposts show up here.",
                actionTitle: "Refresh", action: { Task { await loadFeed() } },
                style: .phone
            )
            .phoneStateLayout()

        case .loaded:
            List {
                ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, activity in
                    FeedActivityRow(
                        activity: activity,
                        context: { viewModel.items.compactMap(\.track) },
                        confirmation: $confirmation
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        guard viewModel.items.isNearEnd(activity, lead: 10) else { return }
                        Task { await viewModel.loadMore() }
                    }
                    .onAppear {
                        let lookahead = viewModel.items[index..<min(index + Self.artworkLookahead, viewModel.items.count)]
                        ArtworkCache.shared.prefetch(lookahead.compactMap { $0.track?.artworkURL ?? $0.playlist?.displayArtworkURL })
                    }
                }
                if viewModel.isLoadingMore {
                    FeedLoadingMoreRow()
                }
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
            message: failure.message(subject: "your stream"),
            actionTitle: failure.actionTitle,
            action: { isShowingSignIn = true },
            style: .phone
        )
        .phoneStateLayout()
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
        await viewModel.loadContentIfNeeded()
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
          "avatar_url": "https://i1.sndcdn.com/avatars-000\(id)-000000-large.jpg",
          "full_name": "\(name.capitalized)" }
        """
    }

    private static func trackJSON(id: Int, title: String, ownerID: Int, ownerName: String) -> String {
        """
        {
            "id": \(id), "title": "\(title)", "description": null,
            "artwork_url": "https://i1.sndcdn.com/artworks-000\(id)-000000-large.jpg",
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
            "artwork_url": "https://i1.sndcdn.com/artworks-000\(id)-000000-large.jpg",
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

private struct FeedConfirmation: Equatable {
    let id = UUID()
    let message: String
    let icon: String
}

private extension View {
    func feedConfirmationOverlay(_ confirmation: Binding<FeedConfirmation?>) -> some View {
        overlay(alignment: .bottom) {
            if let value = confirmation.wrappedValue {
                Label(value.message, systemImage: value.icon)
                    .font(.scSubhead)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.bottom, Spacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: value.id) {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        confirmation.wrappedValue = nil
                    }
            }
        }
        .animation(SCContentMotion.gentle, value: confirmation.wrappedValue)
    }
}

private struct FeedActivityRow: View {
    let activity: FeedActivity
    let context: () -> [Track]
    @Binding var confirmation: FeedConfirmation?

    var body: some View {
        switch activity.kind {
        case .track, .trackRepost:
            if let track = activity.track {
                FeedTrackRow(activity: activity, track: track, context: context, confirmation: $confirmation)
            }

        case .playlist, .playlistRepost:
            if let playlist = activity.playlist {
                FeedPlaylistRow(activity: activity, playlist: playlist, confirmation: $confirmation)
            }
        }
    }
}

private struct FeedPlaylistRow: View {
    let activity: FeedActivity
    let playlist: Playlist
    @Binding var confirmation: FeedConfirmation?

    @State private var isLiked: Bool
    @State private var isReposted: Bool
    @State private var isMutating = false

    init(activity: FeedActivity, playlist: Playlist, confirmation: Binding<FeedConfirmation?>) {
        self.activity = activity
        self.playlist = playlist
        _confirmation = confirmation
        _isLiked = State(initialValue: playlist.userFavorite)
        _isReposted = State(initialValue: playlist.userReposted)
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            NavigationLink {
                FeedPlaylistDetailView(playlist: playlist)
            } label: {
                FeedRowLabel(activity: activity)
            }
            .buttonStyle(.plain)

            Divider().opacity(0.55)

            HStack(spacing: Spacing.xs) {
                action(isLiked ? "Liked" : "Like", icon: isLiked ? "heart.fill" : "heart") {
                    mutateLike()
                }
                action(isReposted ? "Reposted" : "Repost", icon: "arrow.2.squarepath") {
                    mutateRepost()
                }
                Spacer(minLength: 0)
                ShareLink(item: playlist.permalinkURL) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 34, height: 30)
                }
                .accessibilityLabel("Share \(playlist.title)")
            }
            .font(.scCaption)
            .foregroundStyle(.secondary)
        }
        .scCard(cornerRadius: Corner.panel, padding: Spacing.md)
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(title == "Liked" || title == "Reposted" ? Color.scAccent : .secondary)
        .disabled(isMutating)
    }

    private func mutateLike() {
        let target = !isLiked
        isLiked = target
        isMutating = true
        Task {
            do { try await SoundCloudAPI.shared.setPlaylistLiked(target, playlist: playlist) }
            catch {
                isLiked.toggle()
                confirmation = FeedConfirmation(message: error.localizedDescription, icon: "exclamationmark.triangle.fill")
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
                confirmation = FeedConfirmation(message: error.localizedDescription, icon: "exclamationmark.triangle.fill")
            }
            isMutating = false
        }
    }
}

private struct FeedTrackRow: View {
    let activity: FeedActivity
    let track: Track
    let context: () -> [Track]
    @Binding var confirmation: FeedConfirmation?

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var isLiked: Bool
    @State private var isReposted: Bool
    @State private var isMutating = false
    @State private var isShowingComments = false

    init(
        activity: FeedActivity,
        track: Track,
        context: @escaping () -> [Track],
        confirmation: Binding<FeedConfirmation?>
    ) {
        self.activity = activity
        self.track = track
        self.context = context
        _confirmation = confirmation
        _isLiked = State(initialValue: track.userFavorite)
        _isReposted = State(initialValue: track.userReposted)
    }

    private var isPlayable: Bool { track.streamURL != nil }
    private var downloadState: DownloadState { downloadManager.state(for: track.id) }
    private var canDownload: Bool { isPlayable && downloadManager.downloadRefusalReason(for: track) == nil }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Button {
                Task { await coordinator.playHere(track, in: context()) }
            } label: {
                FeedRowLabel(activity: activity, activityState: rowActivity)
            }
            .buttonStyle(.plain)
            .disabled(!isPlayable)

            Divider().opacity(0.55)

            HStack(spacing: Spacing.xs) {
                socialButton(isLiked ? "Liked" : "Like", icon: isLiked ? "heart.fill" : "heart") {
                    mutateLike()
                }
                socialButton(isReposted ? "Reposted" : "Repost", icon: "arrow.2.squarepath") {
                    mutateRepost()
                }
                socialButton("Comment", icon: "bubble.left") {
                    isShowingComments = true
                }
                Spacer(minLength: 0)
                ShareLink(item: track.permalinkURL) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Share \(track.title)")
            }
            .font(.scCaption)
            .foregroundStyle(.secondary)
        }
        .scCard(cornerRadius: Corner.panel, padding: Spacing.md)
        .contextMenu { secondaryActions }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isPlayable {
                Button { queue() } label: {
                    Label("Queue", systemImage: "text.append")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if canDownload {
                downloadSwipeAction
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title) by \(track.user.displayName)")
        .sheet(isPresented: $isShowingComments) {
            FeedCommentsSheet(track: track)
        }
    }

    private func socialButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(title == "Liked" || title == "Reposted" ? Color.scAccent : .secondary)
        .disabled(isMutating)
    }

    private func mutateLike() {
        let target = !isLiked
        isLiked = target
        isMutating = true
        Task {
            do {
                if target { try await SoundCloudAPI.shared.likeTrack(track) }
                else { try await SoundCloudAPI.shared.unlikeTrack(track) }
            } catch {
                isLiked.toggle()
                confirmation = FeedConfirmation(message: error.localizedDescription, icon: "exclamationmark.triangle.fill")
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
                confirmation = FeedConfirmation(message: error.localizedDescription, icon: "exclamationmark.triangle.fill")
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
            if coordinator.isAppleTVAvailable {
                Button {
                    coordinator.playOnAppleTV(track)
                    confirmation = FeedConfirmation(message: "Playing \u{201C}\(track.title)\u{201D} on Apple TV", icon: "appletv.fill")
                } label: {
                    Label("Play on Apple TV", systemImage: "appletv")
                }
            }
            Button { queue() } label: {
                Label("Add to Up Next", systemImage: "text.append")
            }
            if canDownload {
                downloadMenuItems
            }
        }
    }

    @ViewBuilder
    private var downloadMenuItems: some View {
        switch downloadState {
        case .notDownloaded:
            Button { downloadManager.download(track) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        case .queued, .downloading:
            Button(role: .destructive) { downloadManager.cancel(trackId: track.id) } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        case .paused:
            Button { downloadManager.resume(trackId: track.id) } label: {
                Label("Resume Download", systemImage: "arrow.down.circle")
            }
            Button(role: .destructive) { downloadManager.cancel(trackId: track.id) } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        case .downloaded:
            Button(role: .destructive) { downloadManager.cancel(trackId: track.id) } label: {
                Label("Remove Download", systemImage: "trash")
            }
        case .failed:
            Button { downloadManager.download(track) } label: {
                Label("Retry Download", systemImage: "arrow.clockwise")
            }
        }
    }

    @ViewBuilder
    private var downloadSwipeAction: some View {
        switch downloadState {
        case .notDownloaded, .failed:
            Button { downloadManager.download(track) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        case .queued, .downloading, .paused:
            Button(role: .destructive) { downloadManager.cancel(trackId: track.id) } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
        case .downloaded:
            Button(role: .destructive) { downloadManager.cancel(trackId: track.id) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func queue() {
        coordinator.addToQueue(track)
        confirmation = FeedConfirmation(message: "Added \u{201C}\(track.title)\u{201D} to Up Next", icon: "checkmark.circle.fill")
    }
}

private enum FeedTrackActivity: Equatable {
    case none, loading, playing, paused
}

private struct FeedCommentsSheet: View {
    let track: Track

    @Environment(\.dismiss) private var dismiss
    @State private var comments: [Comment] = []
    @State private var draft = ""
    @State private var isLoading = true
    @State private var isPosting = false
    @State private var errorMessage: String?
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && comments.isEmpty {
                    ProgressView("Loading comments…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if comments.isEmpty {
                    ContentUnavailableView(
                        "No Comments Yet",
                        systemImage: "bubble.left",
                        description: Text("Start the conversation on “\(track.title)”.")
                    )
                } else {
                    List(comments) { comment in
                        SCCommentRow(comment: comment, style: .phone)
                            .padding(.vertical, 4)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button {
                                    draft = "@\(comment.user.username) "
                                    composerFocused = true
                                } label: {
                                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                                }
                            }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.scBgBase.ignoresSafeArea())
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button { Task { await post() } } label: {
                if isPosting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
            }
            .disabled(isPosting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Post comment")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(.bar)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { comments = try await SoundCloudAPI.shared.getComments(trackId: track.id).collection }
        catch { errorMessage = error.localizedDescription }
    }

    private func post() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        isPosting = true
        defer { isPosting = false }
        do {
            let comment = try await SoundCloudAPI.shared.postComment(trackId: track.id, body: body)
            comments.append(comment)
            draft = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FeedRowLabel: View {
    let activity: FeedActivity
    var activityState: FeedTrackActivity = .none

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPlayableTrack: Bool { activity.track == nil || activity.track?.streamURL != nil }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ArtworkImage(
                url: activity.track?.artworkURL ?? activity.playlist?.displayArtworkURL,
                icon: activity.playlist != nil ? "music.note.list" : "music.note"
            )
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: Corner.thumb, style: .continuous))
            .kyleCrowned(
                user: activity.track?.user ?? activity.playlist?.user,
                context: activity.track?.title ?? activity.playlist?.title
            )

            VStack(alignment: .leading, spacing: 3) {
                if activity.isRepost {
                    Label("Reposted by \(activity.actor.displayName)", systemImage: "arrow.2.squarepath")
                        .font(.scCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(activity.track?.title ?? activity.playlist?.title ?? "")
                    .font(.scBody)
                    .fontWeight(.semibold)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.sm)

            trailing
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
        .opacity(isPlayableTrack ? 1 : 0.5)
    }

    private var titleColor: Color {
        Color.primary
    }

    private var subtitle: String {
        if let playlist = activity.playlist {
            return "\(playlist.trackCount) tracks \u{00B7} \(playlist.user.displayName)"
        }
        return activity.track?.user.displayName ?? ""
    }

    @ViewBuilder
    private var trailing: some View {
        switch activityState {
        case .loading:
            ProgressView().controlSize(.small)
        case .playing:
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.scAccent)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.scAccent.opacity(0.7))
        case .none:
            trailingIdle
        }
    }

    @ViewBuilder
    private var trailingIdle: some View {
        if let track = activity.track {
            if track.streamURL != nil {
                Text(track.formattedDuration)
                    .font(.scNumeric.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct FeedPlaylistDetailView: View {
    let playlist: Playlist
    @StateObject private var viewModel = FeedPlaylistDetailViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .scrollContentBackground(.hidden)
        .background(Color.scBgBase.ignoresSafeArea())
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(playlist: playlist) }
        .feedConfirmationOverlay($viewModel.banner)
    }

    private var header: some View {
        HStack(spacing: Spacing.md) {
            ArtworkImage(url: playlist.displayArtworkURL, icon: "music.note.list")
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: Corner.thumb, style: .continuous))
                .kyleCrowned(user: playlist.user, context: playlist.title)
                .shadow(color: .black.opacity(0.28), radius: 14, y: 7)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.scTitle)
                    .kerning(-0.3)
                    .lineLimit(2)
                Text("\(playlist.trackCount) tracks \u{00B7} \(playlist.user.displayName)")
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.md)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            FeedLoadingState(message: "Loading playlist…")
        case .failed(let failure):
            SCEmptyState(
                kind: failure.isFault ? .error : .empty,
                icon: failure.icon,
                title: failure.title,
                message: failure.message(subject: "this playlist"),
                actionTitle: "Try Again",
                action: { Task { await viewModel.load(playlist: playlist) } },
                style: .phone
            )
        case .empty:
            SCEmptyState(icon: "music.note.list", title: "Empty Playlist",
                         message: "This playlist has no tracks.", style: .phone)
        case .loaded:
            List {
                ForEach(viewModel.tracks) { track in
                    FeedTrackRow(
                        activity: FeedActivity(
                            kind: .track, createdAt: track.createdAt, actor: track.user,
                            uuid: nil, caption: nil, track: track, playlist: nil
                        ),
                        track: track,
                        context: { viewModel.tracks },
                        confirmation: $viewModel.banner
                    )
                }
            }
            .listStyle(.plain)
            .prefetchArtwork(viewModel.tracks.compactMap(\.artworkURL))
        }
    }
}

@MainActor
private final class FeedPlaylistDetailViewModel: ObservableObject {
    enum State: Equatable {
        case loading, loaded, empty, failed(LoadFailure)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var tracks: [Track] = []
    @Published var banner: FeedConfirmation?

    func load(playlist: Playlist) async {
        state = .loading
        do {
            let full = try await SoundCloudAPI.shared.getPlaylist(id: playlist.id)
            let fetched = full.tracks ?? []
            tracks = fetched
            state = fetched.isEmpty ? .empty : .loaded
        } catch {
            guard !error.isTaskCancellation else { return }
            state = .failed(LoadFailure.classify(error))
        }
    }
}

private struct FeedLoadingState: View {
    let message: String

    var body: some View {
        VStack(spacing: Spacing.md) {
            Spacer(minLength: 60)
            ProgressView()
                .controlSize(.large)
            Text(message)
                .font(.scSubhead)
                .foregroundStyle(.secondary)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FeedLoadingMoreRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, Spacing.sm)
        .listRowSeparator(.hidden)
    }
}
