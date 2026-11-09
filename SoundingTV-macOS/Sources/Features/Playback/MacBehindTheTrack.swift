import SwiftUI

@MainActor
enum MacBehindTheTrack {
    static func actions(for track: Track, dismiss: (() -> Void)? = nil, openTracklist: (() -> Void)? = nil) -> BehindTheTrackActions {
        BehindTheTrackActions(
            openUser: { user in
                dismiss?()
                if MacNowPlayingPresentation.shared.isFullWindow { MacNowPlayingPresentation.shared.requestClose() }
                MacRootSelection.shared.request(artist: user)
            },
            search: { query in
                dismiss?()
                SearchRequestRouter.shared.search(query)
            },
            seek: track.streamURL == nil ? nil : { seek(track, to: $0) },
            openTracklist: openTracklist,
            openAlbum: { album in
                dismiss?()
                if MacNowPlayingPresentation.shared.isFullWindow { MacNowPlayingPresentation.shared.requestClose() }
                MacRootSelection.shared.request(playlist: album)
            }
        )
    }

    static func seek(_ track: Track, to seconds: TimeInterval) {
        let timeline = MacPlaybackTimeline.shared
        if PlayerService.shared.currentTrack?.id == track.id {
            timeline.seek(to: seconds)
            if !timeline.isPlaying { timeline.togglePlayPause() }
            return
        }
        Task {
            await MacPlayback.play(track, in: [track])
            timeline.seek(to: seconds)
        }
    }
}

struct MacBehindTheTrackSheet: View {
    let track: Track

    @StateObject private var model: BehindTheTrackModel
    @ObservedObject private var generated = GeneratedInsightsService.shared
    @Environment(\.dismiss) private var dismiss

    init(track: Track) {
        self.track = track
        _model = StateObject(wrappedValue: BehindTheTrackModel(track: track))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                BehindTheTrackContent(
                    model: model,
                    actions: MacBehindTheTrack.actions(for: track, dismiss: { dismiss() }),
                    showsHeader: true
                ) {
                    GeneratedInsightsSection(insights: generated.insights(for: track.id))
                }
                .padding(24)
            }
            Divider()
            HStack {
                Text("Behind the Track")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 700)
    }
}

struct MacBehindTheTrackPane<Heading: View>: View {
    let track: Track
    let surface: MacNowPlayingSurface
    let heading: Heading
    let onTracklist: () -> Void

    @StateObject private var model: BehindTheTrackModel
    @ObservedObject private var generated = GeneratedInsightsService.shared

    private var nowPlaying: MacNowPlayingModel { .shared }

    init(track: Track, surface: MacNowPlayingSurface, onTracklist: @escaping () -> Void, @ViewBuilder heading: () -> Heading) {
        self.track = track
        self.surface = surface
        self.heading = heading()
        self.onTracklist = onTracklist
        _model = StateObject(wrappedValue: BehindTheTrackModel(track: track))
    }

    var body: some View {
        VStack(spacing: 0) {
            heading
            ScrollView {
                BehindTheTrackContent(
                    model: model,
                    actions: MacBehindTheTrack.actions(for: track, openTracklist: onTracklist),
                    loadedCommentCount: nowPlaying.commentCount
                ) {
                    GeneratedInsightsSection(insights: generated.insights(for: track.id))
                }
                .padding(.horizontal, surface.inset)
                .padding(.bottom, 20)
            }
        }
        .onChange(of: track) { _, next in model.show(next) }
        .task(id: "\(track.id)#\(nowPlaying.timedComments.count)") {
            generated.request(GeneratedInsightInputs.input(for: track, comments: nowPlaying.timedComments, waveform: nil))
        }
    }
}
