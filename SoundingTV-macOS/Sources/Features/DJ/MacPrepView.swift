import SwiftUI

struct MacPrepInspectorPane: View {
    let track: Track
    @StateObject private var model: MacPrepModel
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.undoManager) private var undoManager

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
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .focusedSceneValue(\.macPrep, model)
        .focusedSceneValue(\.macUSBExportSource, MacUSBExportSource(id: "tracks:inspected:\(track.id)", name: track.title, items: [MacUSBExportSource.Item(track)]))
        .preferredColorScheme(settings.prepAppearance.colorScheme)
    }
}

extension FocusedValues {
    @Entry var macPrep: MacPrepModel?
    @Entry var macPrepLane: MacPrepModel?
}
