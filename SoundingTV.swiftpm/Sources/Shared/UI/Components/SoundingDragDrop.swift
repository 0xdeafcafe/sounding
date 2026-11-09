#if os(iOS) || os(macOS)
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

extension UTType {
    static let soundingTrack = UTType(exportedAs: "red.forbes.sounding.track")
    static let soundingLocalTrack = UTType(exportedAs: "red.forbes.sounding.local-track")
    static let soundingCollection = UTType(exportedAs: "red.forbes.sounding.collection")
}

extension EnvironmentValues {
    @Entry var announcePlaylistChange: @MainActor (String, String) -> Void = { _, _ in }
}

struct DraggedTrack: Codable, Transferable {
    let tracks: [Track]

    init(tracks: [Track]) {
        self.tracks = tracks
    }

    init(track: Track) {
        tracks = [track]
    }

    var linkURL: URL {
        tracks.first?.permalinkURL ?? URL(string: "https://soundcloud.com")!
    }

    var linkText: String {
        tracks
            .map { "\($0.title) – \($0.user.displayName)\n\($0.permalinkURL.absoluteString)" }
            .joined(separator: "\n\n")
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .soundingTrack)
        ProxyRepresentation(exporting: \.linkURL)
        ProxyRepresentation(exporting: \.linkText)
    }
}

struct DraggedLocalTrack: Codable, Transferable {
    let tracks: [Track]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .soundingLocalTrack)
    }
}

struct DraggedCollection: Codable, Transferable {
    let id: String
    let title: String
    let isAlbum: Bool
    let permalinkURL: URL

    init(_ playlist: Playlist) {
        id = playlist.id
        title = playlist.title
        isAlbum = playlist.isAlbum
        permalinkURL = playlist.permalinkURL
    }

    var reference: PlaylistReference {
        PlaylistReference(child: .playlist(id))
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .soundingCollection)
        ProxyRepresentation(exporting: \.reference)
        ProxyRepresentation(exporting: \.permalinkURL)
    }
}

struct SoundingDrop: Transferable {
    var tracks: [Track] = []
    var collections: [DraggedCollection] = []

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .soundingTrack) { data in
            SoundingDrop(tracks: try JSONDecoder().decode(DraggedTrack.self, from: data).tracks)
        }
        DataRepresentation(importedContentType: .soundingLocalTrack) { data in
            SoundingDrop(tracks: try JSONDecoder().decode(DraggedLocalTrack.self, from: data).tracks)
        }
        DataRepresentation(importedContentType: .soundingCollection) { data in
            SoundingDrop(collections: [try JSONDecoder().decode(DraggedCollection.self, from: data)])
        }
    }
}

struct PlaylistDrop: Transferable {
    var tracks: [Track]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .soundingTrack) { data in
            PlaylistDrop(tracks: try JSONDecoder().decode(DraggedTrack.self, from: data).tracks)
        }
    }
}

@MainActor
enum DropResolver {
    static func tracks(_ drops: [SoundingDrop]) async -> [Track] {
        var result = drops.flatMap(\.tracks)
        for collection in drops.flatMap(\.collections) {
            result += await tracks(of: collection)
        }
        return result
    }

    static func tracks(of collection: DraggedCollection) async -> [Track] {
        if let stored = await LibraryDB.playlistTracks(id: collection.id), !stored.isEmpty {
            return stored
        }
        guard let playlist = try? await SoundCloudAPI.shared.getPlaylist(id: collection.id) else { return [] }
        let ids = playlist.trackIDs ?? playlist.loadedTracks.map(\.id)
        return (try? await SoundCloudAPI.shared.getPlaylistTracks(playlist, ids: ids)) ?? playlist.loadedTracks
    }
}

@MainActor
enum PlaylistDropActions {
    static func isWritable(_ playlist: Playlist) -> Bool {
        guard let user = SoundCloudCredentialSource.shared.currentUser else { return false }
        return user.id == playlist.user.id && !playlist.isAlbum
    }

    static func add(
        _ drops: [PlaylistDrop],
        to playlist: Playlist,
        announce: @MainActor (String, String) -> Void,
        onAdded: (@MainActor () -> Void)? = nil
    ) async {
        var seen = Set<String>()
        let ids = drops.flatMap(\.tracks).map(\.id).filter { Int($0) != nil && seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        do {
            try await SoundCloudAPI.shared.addTracks(ids, toPlaylist: playlist.id)
            announce(
                ids.count == 1 ? "Added to \(playlist.title)" : "Added \(ids.count) tracks to \(playlist.title)",
                "checkmark.circle.fill"
            )
            onAdded?()
        } catch {
            announce("Couldn’t add to \(playlist.title)", "exclamationmark.triangle.fill")
            #if os(macOS)
            NSSound.beep()
            #endif
        }
    }
}

extension View {
    func trackDragSource(_ track: Track, selection: [Track] = []) -> some View {
        modifier(TrackDragSource(tracks: selection.count > 1 ? selection : [track]))
    }

    func nowPlayingDragSource(_ track: Track?) -> some View {
        modifier(TrackDragSource(tracks: track.map { [$0] } ?? []))
    }

    func collectionDragSource(_ playlist: Playlist) -> some View {
        draggable(DraggedCollection(playlist))
    }
}

private struct TrackDragSource: ViewModifier {
    let tracks: [Track]

    func body(content: Content) -> some View {
        if tracks.isEmpty {
            content
        } else if tracks.contains(where: \.isLocal) {
            content.draggable(DraggedLocalTrack(tracks: tracks))
        } else {
            content.draggable(DraggedTrack(tracks: tracks))
        }
    }
}

extension View {
    func playlistTrackDropTarget(
        _ playlist: Playlist,
        cornerRadius: CGFloat = 10,
        onAdded: (@MainActor () -> Void)? = nil
    ) -> some View {
        modifier(PlaylistTrackDropTarget(playlist: playlist, cornerRadius: cornerRadius, onAdded: onAdded))
    }
}

private struct PlaylistTrackDropTarget: ViewModifier {
    let playlist: Playlist
    let cornerRadius: CGFloat
    let onAdded: (@MainActor () -> Void)?

    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.announcePlaylistChange) private var announce
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if PlaylistDropActions.isWritable(playlist) {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.tint.opacity(isTargeted ? 0.18 : 0))
                        .padding(-4)
                        .allowsHitTesting(false)
                }
                .dropDestination(for: PlaylistDrop.self) { items, _ in
                    guard !items.isEmpty else { return false }
                    let announce = announce
                    let playlist = playlist
                    let onAdded = onAdded
                    Task { await PlaylistDropActions.add(items, to: playlist, announce: announce, onAdded: onAdded) }
                    return true
                } isTargeted: { targeted in
                    withAnimation(.easeOut(duration: 0.15)) { isTargeted = targeted }
                }
        } else {
            content
        }
    }
}

extension View {
    func upNextOutlineTarget(insert: @escaping @MainActor ([Track]) -> Void) -> some View {
        modifier(UpNextInsertionTarget(style: .outline, insert: insert))
    }

    func upNextInsertionTarget(edge: VerticalEdge, insert: @escaping @MainActor ([Track]) -> Void) -> some View {
        modifier(UpNextInsertionTarget(style: .line(edge), insert: insert))
    }

    func upNextFillTarget(insert: @escaping @MainActor ([Track]) -> Void) -> some View {
        modifier(UpNextInsertionTarget(style: .fill, insert: insert))
    }
}

private struct UpNextInsertionTarget: ViewModifier {
    enum Style {
        case line(VerticalEdge)
        case fill
        case outline
    }

    let style: Style
    let insert: @MainActor ([Track]) -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                highlight
            }
            .dropDestination(for: SoundingDrop.self) { items, _ in
                guard !items.isEmpty else { return false }
                let insert = insert
                Task { @MainActor in
                    let tracks = await DropResolver.tracks(items)
                    guard !tracks.isEmpty else { return }
                    insert(tracks)
                }
                return true
            } isTargeted: { targeted in
                withAnimation(.easeOut(duration: 0.12)) { isTargeted = targeted }
            }
    }

    @ViewBuilder
    private var highlight: some View {
        if isTargeted {
            switch style {
            case .line(let edge):
                Capsule()
                    .fill(.tint)
                    .frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: edge == .top ? .top : .bottom)
                    .padding(.horizontal, 8)
                    .allowsHitTesting(false)
            case .fill:
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.tint.opacity(0.14))
                    .allowsHitTesting(false)
            case .outline:
                Capsule()
                    .strokeBorder(.tint, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}
#endif
