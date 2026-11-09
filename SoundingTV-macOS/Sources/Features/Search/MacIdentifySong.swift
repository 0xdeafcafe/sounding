import SwiftUI

extension View {
    func macIdentifySongHost() -> some View {
        modifier(MacIdentifySongHost())
    }
}

private struct MacIdentifySongHost: ViewModifier {
    @ObservedObject private var presenter = IdentifySongPresenter.shared
    @ObservedObject private var requests = IdentifySongRequests.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenter.request) { request in
                IdentifySongSheet(request: request)
                    .environment(\.identifySongActions, Self.actions)
                    .frame(minWidth: 440, idealWidth: 480, minHeight: 560, idealHeight: 660)
            }
            .onReceive(requests.$pendingListen) { pending in
                guard pending, requests.consume() else { return }
                presenter.listen()
            }
    }

    private static var actions: IdentifySongActions {
        IdentifySongActions(
            play: { track, queue in
                Task { await MacPlayback.play(track, in: queue) }
            },
            addToPlaylist: { track in
                IdentifySongPresenter.shared.dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    MacRootSelection.shared.requestAddToPlaylist(PlaylistTrackRef(track: track))
                }
            }
        )
    }
}

struct MacIdentifySongToolbarButton: View {
    var body: some View {
        Button {
            IdentifySongPresenter.shared.listen()
        } label: {
            Label("Identify Song", systemImage: "shazam.logo")
        }
        .help("Identify the song playing around you (⇧⌘I)")
    }
}
