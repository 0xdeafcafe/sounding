import SwiftUI

struct MacPrepView: View {
    private let model: () -> MacPrepModel
    @ObservedObject private var engine = MixEngine.shared
    @ObservedObject private var registry = MacDeckTrackRegistry.shared

    init(model: @autoclosure @escaping () -> MacPrepModel = MacPrepModel()) {
        self.model = model
    }

    var body: some View {
        DJPrepScreen(model: model(), context: .live(tracks: { MacPrepTrackSource.live.track($0) }))
            .navigationTitle("Prep")
            .frame(minWidth: 1080, minHeight: 640)
            .tint(Color.scAccent)
    }
}

struct MacPrepInspectorPane: View {
    let track: Track
    @StateObject private var model: MacPrepModel
    @Environment(\.openWindow) private var openWindow

    init(track: Track, model: @autoclosure @escaping () -> MacPrepModel = MacPrepModel()) {
        self.track = track
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SCArtworkResolver(url: track.artworkURL) { image in
                    SCArtwork(image: image, identity: track.id, style: .mac, cornerRadius: 6)
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(track.user.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Open in Prep") { MacPrepRoute.shared.openPage(trackId: track.id) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DJPrepInspector(model: model)
            }
        }
        .task(id: track.id) { await model.show(trackId: track.id) }
    }
}

struct MacPrepPane: View {
    @StateObject private var model = MacPrepModel()
    @ObservedObject private var registry = MacDeckTrackRegistry.shared

    var body: some View {
        DJPrepScreen(model: model, context: .live(tracks: { MacPrepTrackSource.live.track($0) }))
            .navigationTitle("Prep")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.inspectorChoice = !model.isInspectorShown
                    } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                    .help("Show or hide the inspector (\u{2325}\u{2318}I)")
                }
            }
    }
}

extension FocusedValues {
    @Entry var macPrep: MacPrepModel?
}

struct MacPrepCommands: Commands {
    @FocusedValue(\.macPrep) private var model
    @Environment(\.openWindow) private var openWindow

    static let windowID = "prep"

    var body: some Commands {
        CommandGroup(before: .windowArrangement) {
            Button("Prep Window") { openWindow(id: Self.windowID) }
        }
        CommandMenu("Prep") {
            Button("Show Prep") { MacPrepRoute.shared.openPage() }
                .keyboardShortcut("p", modifiers: [.option, .command])
            Button("Import rekordbox Library…") { MacRekordboxFolderPresenter.choose() }
            Divider()
            Group {
                Button("Set Downbeat at Cursor") { model?.setDownbeat() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Lock Grid") { model?.toggleLock() }
                    .keyboardShortcut("l", modifiers: [.option, .command])
                Button("Halve Tempo") { model?.halveTempo() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Double Tempo") { model?.doubleTempo() }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
                Button("Add Memory Cue") { model?.addMemoryCue() }
                Button("Add Loop") { model?.addLoop() }
                Button("Delete Cue Point") { model?.deleteSelectedCue() }
                Divider()
                Button("Export to USB…") { model?.showsUSBExport = true }
                    .keyboardShortcut("e", modifiers: [.shift, .command])
            }
            .disabled(model == nil)
        }
    }
}
