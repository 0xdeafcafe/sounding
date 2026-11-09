import SwiftUI

extension View {
    func phonePlaylistEditing(_ viewModel: PlaylistDetailViewModel) -> some View {
        modifier(PhonePlaylistEditing(viewModel: viewModel))
    }
}

private struct PhonePlaylistEditing: ViewModifier {
    @ObservedObject var viewModel: PlaylistDetailViewModel
    @Environment(\.sidebarNavigator) private var navigator

    func body(content: Content) -> some View {
        content.playlistEditing(viewModel) { [navigator] in navigator?.open(.playlists) }
    }
}
