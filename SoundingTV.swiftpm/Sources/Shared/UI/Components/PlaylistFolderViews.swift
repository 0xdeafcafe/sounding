import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let soundingPlaylistReference = UTType(exportedAs: "red.forbes.sounding.playlist-reference")
}

struct PlaylistReference: Codable, Hashable, Transferable {
    let child: PlaylistFolderChild

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .soundingPlaylistReference)
    }
}

struct PlaylistFolderArtwork: View {
    var cornerRadius: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay {
                    Image(systemName: "folder")
                        .font(.system(size: max(12, side * 0.38)))
                        .foregroundStyle(.secondary)
                }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct PlaylistFolderTile: View {
    let folder: PlaylistFolder
    var cornerRadius: CGFloat

    @ObservedObject private var store = PlaylistFolderStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PlaylistFolderArtwork(cornerRadius: cornerRadius)
                .frame(maxWidth: .infinity)
            Text(folder.name)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Text(store.summary(for: folder.id))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Folder")
    }
}

struct PlaylistFolderCard: View {
    let folder: PlaylistFolder
    var style: SCContentStyle

    @ObservedObject private var store = PlaylistFolderStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: style.spaceTight) {
            PlaylistFolderArtwork(cornerRadius: style.artworkCorner)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(style.fontBodyEmphasis)
                    .foregroundStyle(style.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(store.summary(for: folder.id))
                    .font(style.fontCaption)
                    .foregroundStyle(style.textSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Folder")
    }
}

struct PlaylistFolderRow: View {
    let folder: PlaylistFolder
    var artworkSize: CGFloat = 56
    var cornerRadius: CGFloat

    @ObservedObject private var store = PlaylistFolderStore.shared

    var body: some View {
        HStack(spacing: 12) {
            PlaylistFolderArtwork(cornerRadius: cornerRadius)
                .frame(width: artworkSize, height: artworkSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.body)
                    .lineLimit(1)
                Text(store.summary(for: folder.id))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Folder")
    }
}

@MainActor
final class PlaylistFolderPrompter: ObservableObject {
    enum Prompt: Equatable {
        case newFolder(parentID: String?, playlistIDs: [String])
        case rename(folderID: String)
        case delete(folderID: String)
    }

    static let shared = PlaylistFolderPrompter()

    @Published var prompt: Prompt?

    func newFolder(in parentID: String? = nil, containing playlistIDs: [String] = []) {
        prompt = .newFolder(parentID: parentID, playlistIDs: playlistIDs)
    }

    func rename(_ folderID: String) {
        prompt = .rename(folderID: folderID)
    }

    func delete(_ folderID: String) {
        prompt = .delete(folderID: folderID)
    }
}

extension View {
    func playlistFolderPrompts(isEnabled: Bool = true) -> some View {
        modifier(PlaylistFolderPromptHost(isEnabled: isEnabled))
    }
}

private struct PlaylistFolderPromptHost: ViewModifier {
    let isEnabled: Bool

    @ObservedObject private var prompter = PlaylistFolderPrompter.shared
    @ObservedObject private var store = PlaylistFolderStore.shared
    @State private var active: PlaylistFolderPrompter.Prompt?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("New Playlist Folder", isPresented: presented { if case .newFolder = $0 { true } else { false } }) {
                TextField("Folder Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Create", action: create)
            }
            .alert("Rename Folder", isPresented: presented { if case .rename = $0 { true } else { false } }) {
                TextField("Folder Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Rename", action: rename)
            }
            .alert(deleteTitle, isPresented: presented { if case .delete = $0 { true } else { false } }) {
                Button("Delete Folder", role: .destructive, action: delete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The playlists in it stay in your library.")
            }
            .onChange(of: prompter.prompt, initial: true) { _, prompt in
                guard isEnabled, let prompt else { return }
                active = prompt
                switch prompt {
                case .newFolder: name = ""
                case .rename(let id): name = store.folder(id)?.name ?? ""
                case .delete: break
                }
            }
    }

    private var deleteTitle: String {
        guard case .delete(let id) = active, let folder = store.folder(id) else { return "Delete Folder?" }
        return "Delete \u{201C}\(folder.name)\u{201D}?"
    }

    private func presented(_ matches: @escaping (PlaylistFolderPrompter.Prompt) -> Bool) -> Binding<Bool> {
        Binding(
            get: { isEnabled && prompter.prompt.map(matches) == true },
            set: { if !$0, let prompt = prompter.prompt, matches(prompt) { prompter.prompt = nil } }
        )
    }

    private func create() {
        guard case .newFolder(let parentID, let playlistIDs) = active else { return }
        let title = name
        withAnimation(.snappy) {
            _ = store.createFolder(named: title, in: parentID, containing: playlistIDs)
        }
        active = nil
    }

    private func rename() {
        guard case .rename(let id) = active else { return }
        let title = name
        withAnimation(.snappy) { store.rename(id, to: title) }
        active = nil
    }

    private func delete() {
        guard case .delete(let id) = active else { return }
        withAnimation(.snappy) { store.delete(id) }
        active = nil
    }
}

struct PlaylistFolderMenuItems: View {
    let playlist: Playlist

    @ObservedObject private var store = PlaylistFolderStore.shared

    var body: some View {
        if store.canEdit, store.canFolder(playlist) {
            let current = store.folderID(containing: playlist.id)
            Menu {
                ForEach(folderChoices) { choice in
                    Button {
                        withAnimation(.snappy) { store.movePlaylist(playlist.id, to: choice.folder.id) }
                    } label: {
                        Label(choice.title, systemImage: "folder")
                    }
                    .disabled(current == choice.folder.id)
                }
                if !folderChoices.isEmpty {
                    Divider()
                }
                Button {
                    PlaylistFolderPrompter.shared.newFolder(containing: [playlist.id])
                } label: {
                    Label("New Folder\u{2026}", systemImage: "folder.badge.plus")
                }
            } label: {
                Label("Add to Folder", systemImage: "folder.badge.plus")
            }
            if current != nil {
                Button {
                    withAnimation(.snappy) { store.movePlaylist(playlist.id, to: nil) }
                } label: {
                    Label("Remove from Folder", systemImage: "folder.badge.minus")
                }
            }
        }
    }

    private struct FolderChoice: Identifiable {
        let folder: PlaylistFolder
        let title: String

        var id: String { folder.id }
    }

    private var folderChoices: [FolderChoice] {
        store.allFolders
            .map { FolderChoice(folder: $0, title: store.path(to: $0.id).map(\.name).joined(separator: " \u{203A} ")) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct PlaylistFolderMenuActions: View {
    let folder: PlaylistFolder

    @ObservedObject private var store = PlaylistFolderStore.shared

    var body: some View {
        #if os(iOS) || os(macOS)
        SidebarPinButton(folder: folder)
        #endif
        if store.canEdit {
            Button {
                PlaylistFolderPrompter.shared.rename(folder.id)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            if store.parentID(of: folder.id) != nil {
                Button {
                    withAnimation(.snappy) { _ = store.moveFolder(folder.id, to: nil) }
                } label: {
                    Label("Remove from Folder", systemImage: "folder.badge.minus")
                }
            }
            Divider()
            Button(role: .destructive) {
                PlaylistFolderPrompter.shared.delete(folder.id)
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }
}

#if os(iOS) || os(macOS)
extension View {
    func playlistFolderDragSource(_ child: PlaylistFolderChild) -> some View {
        modifier(PlaylistFolderDragSource(child: child))
    }

    func playlistFolderDropTarget(_ folderID: String, before target: PlaylistFolderChild? = nil, highlightCorner: CGFloat = 10) -> some View {
        modifier(PlaylistFolderDropTarget(folderID: folderID, target: target, corner: highlightCorner))
    }
}

private struct PlaylistFolderDragSource: ViewModifier {
    let child: PlaylistFolderChild

    @ObservedObject private var store = PlaylistFolderStore.shared

    func body(content: Content) -> some View {
        if store.canEdit {
            content.draggable(PlaylistReference(child: child))
        } else {
            content
        }
    }
}

private struct PlaylistFolderDropTarget: ViewModifier {
    let folderID: String
    let target: PlaylistFolderChild?
    let corner: CGFloat

    @ObservedObject private var store = PlaylistFolderStore.shared
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.tint.opacity(isTargeted ? 0.18 : 0))
                    .padding(-4)
                    .allowsHitTesting(false)
            }
            .dropDestination(for: PlaylistReference.self) { items, _ in
                accept(items.map(\.child))
            } isTargeted: { targeted in
                withAnimation(.easeOut(duration: 0.15)) { isTargeted = targeted }
            }
    }

    private func accept(_ children: [PlaylistFolderChild]) -> Bool {
        PlaylistFolderDrop.accept(children, into: folderID, before: target)
    }
}

@MainActor
enum PlaylistFolderDrop {
    @discardableResult
    static func accept(_ children: [PlaylistFolderChild], into folderID: String, before target: PlaylistFolderChild? = nil) -> Bool {
        let store = PlaylistFolderStore.shared
        let movable = children.filter { child in
            guard child != target, child != .folder(folderID) else { return false }
            if case .folder(let id) = child { return store.canMove(folder: id, into: folderID) }
            return store.playlist(playlistID(child)) != nil
        }
        guard store.canEdit, !movable.isEmpty else { return false }
        withAnimation(.snappy) {
            for child in movable {
                store.move(child, to: folderID, before: target)
            }
        }
        return true
    }

    private static func playlistID(_ child: PlaylistFolderChild) -> String {
        if case .playlist(let id) = child { return id }
        return ""
    }
}
#endif

#if os(iOS) || os(macOS)
struct PlaylistFolderSidebarItems<PlaylistLabel: View>: View {
    var parentID: String?
    var onOpenFolder: ((PlaylistFolder) -> Void)?
    let playlistRow: (Playlist) -> PlaylistLabel

    @ObservedObject private var store = PlaylistFolderStore.shared

    init(
        parentID: String? = nil,
        onOpenFolder: ((PlaylistFolder) -> Void)? = nil,
        @ViewBuilder playlistRow: @escaping (Playlist) -> PlaylistLabel
    ) {
        self.parentID = parentID
        self.onOpenFolder = onOpenFolder
        self.playlistRow = playlistRow
    }

    var body: some View {
        ForEach(store.subfolders(of: parentID)) { folder in
            PlaylistFolderSidebarRow(folder: folder, onOpenFolder: onOpenFolder, playlistRow: playlistRow)
        }
    }
}

struct PlaylistFolderSidebarRow<PlaylistLabel: View>: View {
    let folder: PlaylistFolder
    var onOpenFolder: ((PlaylistFolder) -> Void)?
    let playlistRow: (Playlist) -> PlaylistLabel

    @ObservedObject private var store = PlaylistFolderStore.shared
    @AppStorage private var isExpanded: Bool

    init(
        folder: PlaylistFolder,
        onOpenFolder: ((PlaylistFolder) -> Void)? = nil,
        @ViewBuilder playlistRow: @escaping (Playlist) -> PlaylistLabel
    ) {
        self.folder = folder
        self.onOpenFolder = onOpenFolder
        self.playlistRow = playlistRow
        _isExpanded = AppStorage(wrappedValue: false, "sidebar.playlistFolder.\(folder.id).expanded")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded.animation(.snappy)) {
            ForEach(store.entries(in: folder.id)) { entry in
                switch entry {
                case .folder(let child):
                    PlaylistFolderSidebarRow(folder: child, onOpenFolder: onOpenFolder, playlistRow: playlistRow)
                case .playlist(let playlist):
                    playlistRow(playlist)
                        .playlistFolderDragSource(.playlist(playlist.id))
                }
            }
        } label: {
            label
        }
    }

    @ViewBuilder
    private var label: some View {
        let content = Label(folder.name, systemImage: "folder")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu { PlaylistFolderMenuActions(folder: folder) }
        if let onOpenFolder {
            Button { onOpenFolder(folder) } label: { content }
                .buttonStyle(.plain)
                .playlistFolderDragSource(.folder(folder.id))
                .playlistFolderDropTarget(folder.id, highlightCorner: 6)
        } else {
            content
                .playlistFolderDragSource(.folder(folder.id))
                .playlistFolderDropTarget(folder.id, highlightCorner: 6)
        }
    }
}
#endif
