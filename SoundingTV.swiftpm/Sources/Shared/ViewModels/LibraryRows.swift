import SwiftUI

enum LibraryPageRow: String, CaseIterable, Identifiable, Sendable {
    case recentlyAdded
    case tracks
    case albums
    case artists
    case stations
    case decks
    case sets
    case downloads
    case mixes
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .tracks: "Tracks"
        case .albums: "Albums"
        case .artists: "Artists"
        case .stations: "Stations"
        case .decks: "Decks"
        case .sets: "Sets"
        case .downloads: "Downloads"
        case .mixes: "Mixes"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .recentlyAdded: SidebarSymbol.recentlyAdded
        case .tracks: SidebarSymbol.tracks
        case .albums: SidebarSymbol.albums
        case .artists: SidebarSymbol.artists
        case .stations: SidebarSymbol.stations
        case .decks: SidebarSymbol.decks
        case .sets: SidebarSymbol.sets
        case .downloads: SidebarSymbol.downloads
        case .mixes: SidebarSymbol.mixes
        case .history: SidebarSymbol.history
        }
    }
}

struct LibraryRowChoices: Equatable, Sendable {
    static let storageKey = "red.forbes.sounding.synced.libraryRows"

    enum Surface: Sendable {
        case phoneList
        case padSidebar

        var rows: [LibraryPageRow] {
            switch self {
            case .phoneList: [.tracks, .albums, .artists, .stations, .decks, .sets, .downloads, .mixes, .history]
            case .padSidebar: [.recentlyAdded, .tracks, .albums, .artists, .sets, .downloads, .history]
            }
        }

        var hiddenByDefault: Set<LibraryPageRow> {
            switch self {
            case .phoneList: [.sets, .mixes]
            case .padSidebar: [.sets, .downloads]
            }
        }
    }

    private(set) var order: [LibraryPageRow] = []
    private(set) var shown: [LibraryPageRow: Bool] = [:]

    init(order: [LibraryPageRow] = [], shown: [LibraryPageRow: Bool] = [:]) {
        self.order = order
        self.shown = shown
    }

    init(raw: String) {
        for token in raw.split(separator: ",") {
            let hidden = token.hasPrefix("-")
            let name = hidden ? String(token.dropFirst()) : String(token)
            guard let row = LibraryPageRow(rawValue: name), !order.contains(row) else { continue }
            order.append(row)
            if hidden || token.hasPrefix("+") {
                shown[row] = !hidden
            }
        }
    }

    var raw: String {
        order.map { row in
            switch shown[row] {
            case true?: "+" + row.rawValue
            case false?: "-" + row.rawValue
            case nil: row.rawValue
            }
        }
        .joined(separator: ",")
    }

    func isShown(_ row: LibraryPageRow, on surface: Surface) -> Bool {
        shown[row] ?? !surface.hiddenByDefault.contains(row)
    }

    func isExplicit(_ row: LibraryPageRow) -> Bool {
        shown[row] != nil
    }

    func ordered(for surface: Surface) -> [LibraryPageRow] {
        Self.arrange(order, surface.rows)
    }

    func visible(on surface: Surface) -> [LibraryPageRow] {
        ordered(for: surface).filter { isShown($0, on: surface) }
    }

    mutating func setShown(_ isShown: Bool, for row: LibraryPageRow, on surface: Surface) {
        if !LibraryPageRow.allCases.allSatisfy(order.contains) { order = fullOrder }
        shown[row] = isShown
    }

    mutating func setOrder(_ rows: [LibraryPageRow], on surface: Surface) {
        var pending = rows.filter { surface.rows.contains($0) }
        let missing = surface.rows.filter { !pending.contains($0) }
        pending += missing
        var next: [LibraryPageRow] = []
        for row in fullOrder {
            if surface.rows.contains(row) {
                next.append(pending.removeFirst())
            } else {
                next.append(row)
            }
        }
        order = next
    }

    private var fullOrder: [LibraryPageRow] {
        Self.arrange(order, [.recentlyAdded] + Surface.phoneList.rows)
    }

    private static func arrange(_ preferred: [LibraryPageRow], _ rows: [LibraryPageRow]) -> [LibraryPageRow] {
        var result = preferred.filter { rows.contains($0) }
        for (index, row) in rows.enumerated() where !result.contains(row) {
            if let previous = rows[..<index].last(where: { result.contains($0) }), let position = result.firstIndex(of: previous) {
                result.insert(row, at: position + 1)
            } else {
                result.insert(row, at: 0)
            }
        }
        return result
    }
}

#if os(iOS)
struct LibraryRowsEditor: View {
    @AppStorage(LibraryRowChoices.storageKey) private var raw = ""
    @Environment(\.dismiss) private var dismiss

    private let surface = LibraryRowChoices.Surface.phoneList

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows) { row in
                    Button {
                        toggle(row)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: choices.isShown(row, on: surface) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(choices.isShown(row, on: surface) ? AnyShapeStyle(Color.scAccent) : AnyShapeStyle(.tertiary))
                                .accessibilityHidden(true)
                            Label {
                                Text(row.title).foregroundStyle(.primary)
                            } icon: {
                                SidebarGlyph(row.symbol)
                            }
                        }
                    }
                    .accessibilityAddTraits(choices.isShown(row, on: surface) ? .isSelected : [])
                }
                .onMove(perform: move)
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .close) { dismiss() }
                }
            }
        }
        .tint(Color.scAccent)
    }

    private var choices: LibraryRowChoices { LibraryRowChoices(raw: raw) }

    private var rows: [LibraryPageRow] { choices.ordered(for: surface) }

    private func toggle(_ row: LibraryPageRow) {
        var next = choices
        next.setShown(!next.isShown(row, on: surface), for: row, on: surface)
        raw = next.raw
    }

    private func move(_ source: IndexSet, _ destination: Int) {
        var next = choices
        var ordered = rows
        ordered.move(fromOffsets: source, toOffset: destination)
        next.setOrder(ordered, on: surface)
        raw = next.raw
    }
}
#endif
