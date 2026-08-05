import SwiftUI

struct TrackSortMenu: View {
    @Binding var sortKey: TrackSortKey
    @Binding var ascending: Bool

    var body: some View {
        Menu {
            Picker("Sort by", selection: $sortKey) {
                ForEach(TrackSortKey.allCases) { key in
                    Label(key.rawValue, systemImage: key.icon).tag(key)
                }
            }

            Section {
                Button {
                    ascending.toggle()
                } label: {
                    Label(ascending ? "Ascending" : "Descending", systemImage: ascending ? "arrow.up" : "arrow.down")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
        .onChange(of: sortKey) { _, newKey in
            ascending = newKey.defaultAscending
        }
        .accessibilityLabel("Sort")
    }
}
