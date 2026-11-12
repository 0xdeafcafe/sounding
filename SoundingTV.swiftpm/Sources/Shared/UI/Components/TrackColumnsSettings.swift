#if os(iOS) || os(macOS)
import SwiftUI

struct TrackColumnsSection: View {
    @AppStorage(TrackColumnLayout.storageKey, store: .sounding) private var layout = TrackColumnLayout.standard

    var body: some View {
        Section {
            Toggle(TrackTableColumn.title.settingsTitle, isOn: .constant(true))
                .disabled(true)
            ForEach(layout.movable) { column in
                Toggle(column.settingsTitle, isOn: binding(column))
                    #if os(macOS)
                    .contextMenu { moveMenu(column) }
                    #endif
            }
            .onMove { source, destination in
                var next = layout
                next.move(fromOffsets: source, toOffset: destination)
                layout = next
            }
        } header: {
            #if os(macOS)
            Text("Columns")
            #endif
        } footer: {
            Text("Tables show these in this order.")
        }

        Section {
            Button("Reset to Default") { layout = .standard }
                .disabled(layout.isStandard)
        }
    }

    private func binding(_ column: TrackTableColumn) -> Binding<Bool> {
        Binding(
            get: { layout.isVisible(column) },
            set: { isVisible in
                var next = layout
                next.setVisible(column, isVisible)
                layout = next
            }
        )
    }

    #if os(macOS)
    @ViewBuilder
    private func moveMenu(_ column: TrackTableColumn) -> some View {
        let movable = layout.movable
        if let index = movable.firstIndex(of: column) {
            Button("Move Up") { move(index, by: -1) }
                .disabled(index == 0)
            Button("Move Down") { move(index, by: 1) }
                .disabled(index == movable.count - 1)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        var next = layout
        next.move(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? index + 2 : index - 1)
        layout = next
    }
    #endif
}

#if os(iOS)
struct TrackColumnsSettingsView: View {
    var body: some View {
        Form {
            TrackColumnsSection()
        }
        .navigationTitle("Columns")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }
}
#endif
#endif
