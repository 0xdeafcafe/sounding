import SwiftUI

private struct PresentAddToPlaylistKey: EnvironmentKey {
    static let defaultValue: @MainActor (PlaylistTrackRef) -> Void = { _ in }
}

extension EnvironmentValues {
    var presentAddToPlaylist: @MainActor (PlaylistTrackRef) -> Void {
        get { self[PresentAddToPlaylistKey.self] }
        set { self[PresentAddToPlaylistKey.self] = newValue }
    }
}

enum PlaylistEditFailure {
    static func message(for error: Error, action: String) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .rateLimited:
                return "SoundCloud is limiting requests. Try again in a little while."
            case .unauthorized, .forbidden:
                return "Sign in to SoundCloud again, then try again."
            default:
                break
            }
        }
        return "SoundCloud couldn’t \(action). Check your connection and try again."
    }
}

struct PlaylistTrackRef: Identifiable, Equatable {
    let id: String
    let title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(track: Track) {
        self.init(id: track.id, title: track.title)
    }
}

@MainActor
final class AddToPlaylistModel: ObservableObject {
    enum LoadState {
        case loading
        case failed
        case loaded([PlaylistSummary])
    }

    let track: PlaylistTrackRef

    @Published private(set) var state: LoadState = .loading
    @Published private(set) var pendingID: String?
    @Published var query = ""
    @Published var failure: String?

    private var retry: (() -> Void)?

    init(track: PlaylistTrackRef) {
        self.track = track
    }

    var isAdding: Bool { pendingID != nil }

    func load() async {
        state = .loading
        do {
            state = .loaded(try await PlaylistWriter.myPlaylists())
        } catch {
            state = .failed
        }
    }

    func playlists(from all: [PlaylistSummary]) -> [PlaylistSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.title.localizedStandardContains(needle) }
    }

    func add(to playlist: PlaylistSummary, onAdded: @escaping @MainActor (PlaylistSummary) -> Void) {
        guard pendingID == nil else { return }
        pendingID = playlist.id
        Task {
            do {
                try await PlaylistWriter.add(track.id, to: playlist)
                onAdded(playlist)
            } catch {
                pendingID = nil
                retry = { [weak self] in self?.add(to: playlist, onAdded: onAdded) }
                failure = PlaylistEditFailure.message(for: error, action: "add the track")
            }
        }
    }

    func create(title: String, onAdded: @escaping @MainActor (PlaylistSummary) -> Void) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pendingID == nil, !name.isEmpty else { return }
        pendingID = Self.newPlaylistID
        Task {
            do {
                let made = try await PlaylistWriter.create(title: name, containing: track.id)
                onAdded(made)
            } catch {
                pendingID = nil
                retry = { [weak self] in self?.create(title: name, onAdded: onAdded) }
                failure = PlaylistEditFailure.message(for: error, action: "make the playlist")
            }
        }
    }

    static let newPlaylistID = "new-playlist"

    func retryLastAdd() {
        retry?()
    }
}
