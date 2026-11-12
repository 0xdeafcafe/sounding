import SwiftUI

struct DJPrepScreen<Strip: View>: View {
    @StateObject private var model: MacPrepModel
    private let context: DJDeckContext
    private let strip: Strip
    @ObservedObject private var sticks = MacDJSticks.shared
    @Environment(\.undoManager) private var undoManager
    @Environment(\.macMainSidebarVisible) private var mainSidebarVisible
    @Environment(\.macMainInspectorVisible) private var mainInspectorVisible
    @State private var showsImport = false
    @State private var refusal: String?
    @State private var sortOrder: [KeyPathComparator<MacPrepModel.Row>] = []
    @State private var newCrateName = ""
    @State private var showsNewCrate = false
    @SceneStorage("djPrep.columns") private var columns = TableColumnCustomization<MacPrepModel.Row>()

    init(
        model: @autoclosure @escaping () -> MacPrepModel = MacPrepModel(),
        context: DJDeckContext = .none,
        @ViewBuilder strip: () -> Strip
    ) {
        _model = StateObject(wrappedValue: model())
        self.context = context
        self.strip = strip()
    }

    @State private var width: CGFloat = 1280

    private var showsInspector: Bool { !mainInspectorVisible && (model.inspectorChoice ?? (width >= 1180)) }

    var body: some View {
        HStack(spacing: 0) {
            if !mainSidebarVisible {
                DJPrepSidebar(model: model, sticks: sticks, showsImport: $showsImport, showsNewCrate: $showsNewCrate)
                    .frame(width: 220)
                Divider()
            }
            VStack(alignment: .leading, spacing: 0) {
                strip
                center
            }
            .frame(minWidth: 520, maxWidth: .infinity)
            if showsInspector {
                if model.source.isStick {
                    if !model.stick.rows.isEmpty {
                        Divider()
                        MacPrepStickInspector(stick: model.stick)
                            .frame(width: 320)
                    }
                } else if !model.allRows.isEmpty {
                    Divider()
                    Group {
                        if model.detail != nil {
                            DJPrepInspector(model: model)
                        } else {
                            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing", description: Text("Choose a track to see its grid and cues."))
                        }
                    }
                    .frame(width: 330)
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: showsInspector, initial: true) { _, shown in model.isInspectorShown = shown }
        .overlay(alignment: .top) { refusalBanner }
        .background {
            Group {
                Button("Load on Deck A") { loadSelection(onto: .a) }
                    .keyboardShortcut("1", modifiers: .shift)
                Button("Load on Deck B") { loadSelection(onto: .b) }
                    .keyboardShortcut("2", modifiers: .shift)
                Button("Inspector") { model.inspectorChoice = !showsInspector }
                    .keyboardShortcut("i", modifiers: [.option, .command])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onChange(of: sticks.volumes.map(\.id)) { _, ids in
            if case .stick(let volume, _) = model.source, !ids.contains(volume) { model.source = .all }
        }
        .focusedSceneValue(\.macPrep, model)
        .macRekordboxFolderImport { Task { await model.reload() } }
        .sheet(item: presentedSheet) { sheet in
            switch sheet {
            case .importLibrary:
                MacRekordboxImportSheet(library: .shared) {
                    showsImport = false
                    Task { await model.reload() }
                }
            case .usbExport:
                MacUSBExportSheet(model: MacUSBExportModel(store: model.store, selectionIds: model.selection.map { [$0] } ?? [])) {
                    model.showsUSBExport = false
                    Task { await model.reload() }
                }
            }
        }
        .alert("New Crate", isPresented: $showsNewCrate) {
            TextField("Name", text: $newCrateName)
            Button("Create") {
                let name = newCrateName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.addCrate(named: name) }
                newCrateName = ""
            }
            Button("Cancel", role: .cancel) { newCrateName = "" }
        }
        .task {
            model.undoManager = undoManager
            await model.reload()
            if let id = MacPrepRoute.shared.consumePendingTrack() { await model.show(trackId: id) }
        }
        .onReceive(MacPrepRoute.shared.$pendingTrackId.compactMap { $0 }) { id in
            guard !model.isLoading else { return }
            MacPrepRoute.shared.pendingTrackId = nil
            Task { await model.show(trackId: id) }
        }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }

    private enum PrepSheet: String, Identifiable {
        case importLibrary
        case usbExport

        var id: String { rawValue }
    }

    private var presentedSheet: Binding<PrepSheet?> {
        Binding(
            get: { showsImport ? .importLibrary : (model.showsUSBExport ? .usbExport : nil) },
            set: { sheet in
                if sheet == nil {
                    showsImport = false
                    model.showsUSBExport = false
                }
            }
        )
    }

    @ViewBuilder
    private var center: some View {
        if model.source.isStick {
            MacPrepStickView(stick: model.stick, searchText: model.searchText)
        } else if model.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.allRows.isEmpty {
            ContentUnavailableView {
                Label("No Tracks to Prepare", systemImage: "waveform.path.badge.plus")
            } description: {
                Text("Import a rekordbox library, add a music folder, or like tracks on SoundCloud.")
            } actions: {
                Button("Import rekordbox Library…") { MacRekordboxFolderPresenter.choose() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                table
                    .frame(minHeight: 180, maxHeight: .infinity)
                Divider()
                DJPrepEditor(model: model, context: context)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 10) {
                if mainSidebarVisible {
                    DJPrepSourcePicker(model: model, sticks: sticks)
                } else {
                    Text(model.title(for: model.source))
                        .font(.title.weight(.bold))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                DJDeckDropTargets(context: context, refusal: $refusal)
                Menu("Analyse") {
                    Button("Analyse Selected") { model.analyse(model.selection.map { [$0] } ?? []) }
                        .disabled(model.selection == nil)
                    Button("Analyse Everything Missing") {
                        model.analyse(model.visibleRows.filter { $0.analysis == .missing }.map(\.id))
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                Menu("Columns") {
                    ForEach(DJPrepColumn.allCases, id: \.self) { column in
                        Toggle(column.title, isOn: Binding(
                            get: { columns[visibility: column.rawValue] != .hidden && !(column == .added && columns[visibility: column.rawValue] == .automatic) },
                            set: { columns[visibility: column.rawValue] = $0 ? .visible : .hidden }
                        ))
                    }
                }
                .menuStyle(.button)
                .fixedSize()
            }
            Text(summary)
                .font(.callout)
                .foregroundStyle(MacSecondaryStyle())
                .lineLimit(1)
        }
    }

    private var summary: String {
        let rows = model.visibleRows
        let seconds = rows.reduce(0) { $0 + $1.durationSeconds }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        var parts = ["\(rows.count) \(rows.count == 1 ? "track" : "tracks")"]
        parts.append(hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min")
        let local = rows.filter { $0.access == .local }.count
        let streaming = rows.count - local
        if local > 0 { parts.append("\(local) \(local == 1 ? "file" : "files") on this Mac") }
        if streaming > 0 { parts.append(model.streamsAllowed ? "\(streaming) streaming from SoundCloud" : "\(streaming) Auto Mix only") }
        if context.decks.contains(where: \.isOnAir) { parts.append("Analysis waits while you mix") }
        return parts.joined(separator: " · ")
    }

    // MARK: Table

    private var sortedRows: [MacPrepModel.Row] {
        sortOrder.isEmpty ? model.visibleRows : model.visibleRows.sorted(using: sortOrder)
    }

    private var table: some View {
        Table(of: MacPrepModel.Row.self, selection: $model.selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("") { row in
                if let slot = context.deck(holding: row.id) {
                    Text(slot.letter)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.scAccent)
                        .accessibilityLabel("On deck \(slot.letter)")
                } else if let index = sortedRows.firstIndex(of: row) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .width(22)
            .customizationID("index")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Title", value: \.title) { row in
                Text(row.title)
                    .fontWeight(.medium)
                    .foregroundStyle(row.access == .autoMixOnly ? .secondary : .primary)
            }
            .width(min: 112, ideal: 136)
            .customizationID(DJPrepColumn.title.rawValue)
            TableColumn("Artist", value: \.artist) { row in
                Text(row.artist).foregroundStyle(MacSecondaryStyle())
            }
            .width(min: 56, ideal: 80)
            .customizationID(DJPrepColumn.artist.rawValue)
            TableColumn("BPM", value: \.sortBPM) { row in
                if row.analysis == .analysing {
                    DJAnalysingCell()
                } else {
                    Text(row.bpmText).monospacedDigit()
                }
            }
            .width(56)
            .customizationID(DJPrepColumn.bpm.rawValue)
            TableColumn("Key", value: \.sortKey) { row in
                if row.analysis == .analysing { EmptyView() } else { DJKeyBadge(key: row.key) }
            }
            .width(40)
            .customizationID(DJPrepColumn.key.rawValue)
            TableColumn("Energy", value: \.sortEnergy) { row in
                DJEnergyBars(energy: row.energy)
            }
            .width(50)
            .customizationID(DJPrepColumn.energy.rawValue)
            TableColumn("Time", value: \.durationSeconds) { row in
                Text(row.timeText).monospacedDigit().foregroundStyle(MacSecondaryStyle())
            }
            .width(40)
            .customizationID(DJPrepColumn.time.rawValue)
            Group {
                TableColumn("Cues", value: \MacPrepModel.Row.cueCount) { row in
                    Text(row.cuesText).monospacedDigit()
                }
                .width(32)
                .customizationID(DJPrepColumn.cues.rawValue)
                TableColumn("Grid") { (row: MacPrepModel.Row) in
                    if row.gridLocked {
                        Image(systemName: "lock.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Grid locked")
                    } else if row.needsGridCheck {
                        Image(systemName: "exclamationmark.triangle")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Grid needs a check")
                    }
                }
                .width(28)
                .customizationID(DJPrepColumn.grid.rawValue)
                TableColumn("Source", value: \MacPrepModel.Row.sortSource) { row in
                    DJSourceCell(row: row, onRelink: { model.selection = row.id; model.linkFile() })
                }
                .width(min: 72, ideal: 92)
                .customizationID(DJPrepColumn.source.rawValue)
                TableColumn("Added", value: \MacPrepModel.Row.addedMillis) { row in
                    Text(addedText(row.addedMillis)).foregroundStyle(MacSecondaryStyle())
                }
                .width(min: 60, ideal: 76)
                .customizationID(DJPrepColumn.added.rawValue)
                .defaultVisibility(.hidden)
            }
        } rows: {
            ForEach(sortedRows) { row in
                TableRow(row)
                    .draggable(row.id)
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = model.row(id) {
                DJTrackMenu(row: row, model: model, context: context, refusal: $refusal)
            }
        } primaryAction: { ids in
            guard let id = ids.first, let row = model.row(id), row.access.canLoad else { return }
            let deck: MixEngine.Deck = context.slot(.a)?.isOnAir == true ? .b : .a
            show(context.request(id, onto: deck))
        }
        .overlay {
            if model.visibleRows.isEmpty {
                if model.searchText.isEmpty {
                    ContentUnavailableView("Nothing Here Yet", systemImage: "music.note.list", description: Text(emptyMessage))
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
    }

    private var emptyMessage: String {
        switch model.source {
        case .smart(.needsGridCheck): return "Every grid is locked or set by you."
        case .smart(.notOnStick): return "Everything with a file is on the stick."
        case .smart(.duplicates): return "No tracks appear twice."
        case .playlist: return "Drag tracks here to add them to this crate."
        default: return "Tracks you add appear here."
        }
    }

    private func addedText(_ millis: Int64) -> String {
        guard millis > 0 else { return "–" }
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func loadSelection(onto deck: MixEngine.Deck) {
        guard let id = model.selection, let row = model.row(id), row.access.canLoad else { return }
        show(context.request(id, onto: deck))
    }

    private func show(_ result: DJLoadResult) {
        if case .refused(let message) = result { refusal = message }
    }

    @ViewBuilder
    private var refusalBanner: some View {
        if let refusal {
            DJRefusalBanner(message: refusal)
                .padding(.top, 54)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: refusal) {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation { self.refusal = nil }
                }
        }
    }
}

struct DJPrepSourcePicker: View {
    @ObservedObject var model: MacPrepModel
    @ObservedObject var sticks: MacDJSticks

    var body: some View {
        Menu {
            Picker("Show", selection: Binding(get: { model.source }, set: { model.source = $0 })) {
                Text("Likes").tag(MacPrepModel.Source.likes)
                Text("All Tracks").tag(MacPrepModel.Source.all)
                ForEach(model.folders, id: \.name) { folder in
                    Text(folder.name).tag(MacPrepModel.Source.folder(folder.name))
                }
            }
            .pickerStyle(.inline)
            if !model.playlists.isEmpty {
                Picker("Crates", selection: Binding(get: { model.source }, set: { model.source = $0 })) {
                    ForEach(model.playlists) { crate in
                        Text(crate.name).tag(MacPrepModel.Source.playlist(crate.id))
                    }
                }
                .pickerStyle(.inline)
            }
            Picker("Smart Crates", selection: Binding(get: { model.source }, set: { model.source = $0 })) {
                ForEach(MacPrepModel.SmartCrate.allCases, id: \.self) { crate in
                    Text(crate.title).tag(MacPrepModel.Source.smart(crate))
                }
            }
            .pickerStyle(.inline)
            if !sticks.volumes.isEmpty {
                Picker("USB Sticks", selection: Binding(get: { model.source }, set: { model.source = $0 })) {
                    ForEach(sticks.volumes) { volume in
                        Text(volume.name).tag(MacPrepModel.Source.stick(volume: volume.id, playlist: nil))
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Text(model.title(for: model.source))
                .font(.title.weight(.bold))
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Show")
    }
}

extension DJPrepScreen where Strip == EmptyView {
    init(model: @autoclosure @escaping () -> MacPrepModel = MacPrepModel(), context: DJDeckContext = .none) {
        self.init(model: model(), context: context) { EmptyView() }
    }
}

enum DJPrepColumn: String, CaseIterable {
    case title, artist, bpm, key, energy, time, cues, grid, source, added

    var title: String {
        switch self {
        case .bpm: return "BPM"
        default: return rawValue.capitalized
        }
    }
}

// MARK: Cells

struct DJAnalysingCell: View {
    var body: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text("Analysing").font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct DJEnergyBars: View {
    let energy: Int?

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<10, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(index < (energy ?? 0) ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: 2.5, height: 11)
            }
        }
        .opacity(energy == nil ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(energy.map { "Energy \($0) of 10" } ?? "Energy unknown")
    }
}

struct DJSourceCell: View {
    let row: MacPrepModel.Row
    var onRelink: () -> Void = {}

    var body: some View {
        switch row.access {
        case .local where row.fileMissing:
            HStack(spacing: 4) {
                Label("File moved", systemImage: "exclamationmark.triangle")
                    .labelStyle(.titleAndIcon)
                Button("Relink", action: onRelink)
                    .buttonStyle(.link)
            }
            .fontWeight(.medium)
        case .local:
            Text(row.sourceText).foregroundStyle(MacSecondaryStyle())
        case .streams:
            Label(row.sourceText, systemImage: "cloud")
                .foregroundStyle(MacSecondaryStyle())
        case .autoMixOnly:
            Label(row.sourceText, systemImage: "cloud")
                .foregroundStyle(.tertiary)
        }
    }
}

struct DJRefusalBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "lock.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .accessibilityAddTraits(.isStaticText)
    }
}

struct DJDeckDropTargets: View {
    let context: DJDeckContext
    @Binding var refusal: String?

    var body: some View {
        if !context.decks.isEmpty {
            HStack(spacing: 6) {
                ForEach(context.decks) { slot in
                    DJDeckDropTarget(slot: slot) { id in
                        if case .refused(let message) = context.request(id, onto: slot.deck) { refusal = message }
                    }
                }
            }
        }
    }
}

private struct DJDeckDropTarget: View {
    let slot: DJDeckSlot
    let onDrop: (String) -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 5) {
            Text(slot.letter)
                .font(.caption.weight(.bold))
                .frame(width: 16, height: 16)
                .background {
                    if slot.deck == .a {
                        RoundedRectangle(cornerRadius: 4).fill(Color.scAccent)
                    } else {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(Color.scAccent, lineWidth: 1.5)
                    }
                }
                .foregroundStyle(slot.deck == .a ? Color.white : Color.scAccent)
            Text(slot.trackId == nil ? "Empty" : slot.title)
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .leading)
            if slot.isOnAir {
                Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(targeted ? Color.scAccent.opacity(0.25) : Color.clear, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }
            onDrop(id)
            return true
        } isTargeted: { targeted = $0 }
        .help(slot.isOnAir ? "Deck \(slot.letter) is on air" : "Drop a track to load it on Deck \(slot.letter)")
        .accessibilityLabel("Deck \(slot.letter), \(slot.trackId == nil ? "empty" : slot.title)\(slot.isOnAir ? ", on air" : "")")
    }
}

struct DJTrackMenu: View {
    let row: MacPrepModel.Row
    let model: MacPrepModel
    let context: DJDeckContext
    @Binding var refusal: String?

    var body: some View {
        Button("Play Next") { context.playNext(row.id) }
        Button("Add to Auto Mix Queue") { context.addToAutoMix(row.id) }
        Button("Plan Transition In") { context.planTransition(row.id) }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(!row.access.canLoad)
        Divider()
        Button("Load on Deck A") { load(.a) }
            .keyboardShortcut("1", modifiers: .shift)
            .disabled(!row.access.canLoad || context.decks.isEmpty)
        Button("Load on Deck B") { load(.b) }
            .keyboardShortcut("2", modifiers: .shift)
            .disabled(!row.access.canLoad || context.decks.isEmpty)
        Button("Edit Grid & Cues") { model.selection = row.id }
            .disabled(!row.access.canEdit)
        Button("Export to USB…") { model.showsUSBExport = true }
            .disabled(!row.canExport)
        if !model.playlists.isEmpty {
            Menu("Add to Crate") {
                ForEach(model.playlists) { crate in
                    Button(crate.name) { model.add([row.id], toCrate: crate.id) }
                }
            }
        }
        switch row.access {
        case .streams:
            Divider()
            Text("Streams on Go+ · SoundCloud audio isn’t exported")
        case .autoMixOnly:
            Divider()
            Text("Auto Mix only · Go+ unlocks decks")
        case .local:
            EmptyView()
        }
    }

    private func load(_ deck: MixEngine.Deck) {
        if case .refused(let message) = context.request(row.id, onto: deck) { refusal = message }
    }
}
