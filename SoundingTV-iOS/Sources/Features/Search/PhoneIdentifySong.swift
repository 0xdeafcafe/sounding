import SwiftUI

extension View {
    func phoneIdentifySongHost(isNowPlayingExpanded: Binding<Bool>) -> some View {
        modifier(PhoneIdentifySongHost(isNowPlayingExpanded: isNowPlayingExpanded))
    }
}

private struct PhoneIdentifySongHost: ViewModifier {
    @Binding var isNowPlayingExpanded: Bool
    @ObservedObject private var presenter = IdentifySongPresenter.shared
    @ObservedObject private var requests = IdentifySongRequests.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenter.request) { request in
                PhoneIdentifySongSheet(request: request)
            }
            .onReceive(requests.$pendingListen) { pending in
                guard pending, requests.consume() else { return }
                let wasExpanded = isNowPlayingExpanded
                isNowPlayingExpanded = false
                Task {
                    if wasExpanded { try? await Task.sleep(for: .milliseconds(450)) }
                    presenter.listen()
                }
            }
    }
}

struct PhoneIdentifySongSheet: View {
    let request: IdentifySongRequest

    var body: some View {
        PhoneIdentifySongContent(request: request)
            .addToPlaylistHost()
            .tint(Color.scAccent)
    }
}

private struct PhoneIdentifySongContent: View {
    let request: IdentifySongRequest

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.presentAddToPlaylist) private var presentAddToPlaylist

    var body: some View {
        IdentifySongSheet(request: request)
            .environment(\.identifySongActions, IdentifySongActions(
                play: { track, queue in
                    Task { _ = await coordinator.play(track, in: queue) }
                },
                addToPlaylist: { track in
                    presentAddToPlaylist(PlaylistTrackRef(track: track))
                }
            ))
    }
}

struct IdentifySongToolbarButton: View {
    var body: some View {
        Button {
            IdentifySongPresenter.shared.listen()
        } label: {
            Label("Identify Song", systemImage: "shazam.logo")
        }
        .accessibilityHint("Listens and names the song playing around you")
    }
}
