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
            .preferredColorScheme(.dark)
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
            Button("Prep") { openWindow(id: Self.windowID) }
                .keyboardShortcut("p", modifiers: [.option, .command])
        }
        CommandMenu("Prep") {
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
                Button(TrackMapCopy.saveCuePoint) { model?.trackMap.saveCue() }
                Button(TrackMapCopy.addLoop) { model?.trackMap.addLoop() }
                Button(TrackMapCopy.delete) { model?.trackMap.deleteSelected() }
                Divider()
                Button("Export to USB…") { model?.showsUSBExport = true }
                    .keyboardShortcut("e", modifiers: [.shift, .command])
            }
            .disabled(model == nil)
        }
    }
}
