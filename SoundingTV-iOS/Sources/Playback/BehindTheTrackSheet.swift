import SwiftUI

struct BehindTheTrackSheet: View {
    let track: Track

    @StateObject private var model: BehindTheTrackModel
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ObservedObject private var generated = GeneratedInsightsService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()

    init(track: Track) {
        self.track = track
        _model = StateObject(wrappedValue: BehindTheTrackModel(track: track))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                BehindTheTrackContent(model: model, actions: actions, showsHeader: true) {
                    GeneratedInsightsSection(insights: generated.insights(for: track.id))
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .navigationTitle("Behind the Track")
            .navigationBarTitleDisplayMode(.inline)
            .appNavigationDestinations()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .addToPlaylistHost()
    }

    private var actions: BehindTheTrackActions {
        BehindTheTrackActions(
            openUser: { path.append($0) },
            search: { query in
                dismiss()
                SearchRequestRouter.shared.search(query)
            },
            seek: track.streamURL == nil ? nil : { seek(to: $0) },
            openAlbum: { path.append(LibraryCollectionRoute.playlist($0)) }
        )
    }

    private func seek(to seconds: TimeInterval) {
        if coordinator.nowPlaying?.trackId == track.id {
            coordinator.seek(to: seconds)
            if coordinator.nowPlaying?.isPlaying == false { coordinator.play() }
            return
        }
        Task {
            _ = await coordinator.play(track, in: [track])
            coordinator.seek(to: seconds)
        }
    }
}
