import SwiftUI

struct TrackListDensityPicker: View {
    @Binding var density: TrackListDensity

    var body: some View {
        Section {
            Picker("View As", selection: $density) {
                ForEach(TrackListDensity.allCases) { density in
                    Label(density.title, systemImage: density.systemImage).tag(density)
                }
            }
            .pickerStyle(.inline)
        }
    }
}

struct TrackListColumnsToggle: View {
    @Binding var showsColumns: Bool

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { showsColumns },
                set: { value in withAnimation(.smooth) { showsColumns = value } }
            )) {
                Label("Show Columns", systemImage: "tablecells")
            }
        }
    }
}

struct TrackCollectionMenuItems: View {
    @Binding var query: TrackCollectionQuery
    var density: Binding<TrackListDensity>? = nil
    var showsColumns: Binding<Bool>? = nil
    var sortKeys: [TrackSortKey] = TrackSortKey.allCases
    var dateLabel = "Date Added"
    var naturalOrderLabel: String? = nil
    var filters: [TrackFilter] = TrackFilter.allCases

    private var sortBinding: Binding<TrackSortKey?> {
        Binding(get: { query.sortKey }, set: { query.select($0) })
    }

    var body: some View {
        if let density {
            TrackListDensityPicker(density: density)
        }

        if let showsColumns {
            TrackListColumnsToggle(showsColumns: showsColumns)
        }

        Section("Sort By") {
            Picker("Sort By", selection: sortBinding) {
                if let naturalOrderLabel {
                    Label(naturalOrderLabel, systemImage: "list.number").tag(TrackSortKey?.none)
                }
                ForEach(sortKeys) { key in
                    Label(key.title(dateLabel: dateLabel), systemImage: key.icon).tag(TrackSortKey?.some(key))
                }
            }
            .pickerStyle(.inline)
        }

        if query.sortKey != nil {
            Section {
                Picker("Order", selection: $query.ascending) {
                    Label("Ascending", systemImage: "arrow.up").tag(true)
                    Label("Descending", systemImage: "arrow.down").tag(false)
                }
                .pickerStyle(.inline)
            }
        }

        let sources = filters.filter(\.isSource)
        if !sources.isEmpty {
            Section("Show") {
                ForEach(sources) { filter in toggle(filter) }
            }
        }

        Section {
            ForEach(filters.filter { !$0.isSource }) { filter in toggle(filter) }
            Menu {
                Picker("Tempo", selection: $query.bpmRange) {
                    Text("Any Tempo").tag(TrackBPMRange?.none)
                    ForEach(TrackBPMRange.presets) { range in
                        Text(range.label).tag(TrackBPMRange?.some(range))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(query.bpmRange?.label ?? "Tempo", systemImage: "metronome")
            }
        }

        if query.isFiltering {
            Section {
                Button("Clear Filters", systemImage: "xmark.circle") { query.clearFilters() }
            }
        }
    }

    private func toggle(_ filter: TrackFilter) -> some View {
        Toggle(isOn: Binding(
            get: { query.filters.contains(filter) },
            set: { _ in query.toggle(filter) }
        )) {
            Label(filter.title, systemImage: filter.icon)
        }
        .menuActionDismissBehavior(.disabled)
    }
}
