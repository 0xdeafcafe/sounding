import SwiftUI

struct MacLibrarySettingsTab: View {
    @ObservedObject var library: MacRekordboxLibrary
    @Environment(\.openWindow) private var openWindow
    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
        case importLibrary
        case importAnalysis
        case export(MacRekordboxLibrary.ExportDraft)
        case usb

        var id: String {
            switch self {
            case .importLibrary: return "import"
            case .importAnalysis: return "analysis"
            case .export: return "export"
            case .usb: return "usb"
            }
        }
    }

    init(library: MacRekordboxLibrary = .shared) {
        self.library = library
    }

    var body: some View {
        Form {
            MusicFoldersSection()

            TrackColumnsSection()

            Section {
                LabeledContent("Library") {
                    HStack {
                        Text(library.xmlName ?? "None")
                            .foregroundStyle(library.xmlName == nil ? .secondary : .primary)
                        Button("Choose…") { library.chooseXML() }
                    }
                }
                LabeledContent("Music Folder") {
                    HStack {
                        Text(library.musicFolderName ?? "None")
                            .foregroundStyle(library.musicFolderName == nil ? .secondary : .primary)
                        Button("Choose…") { library.chooseMusicFolder() }
                    }
                }
                LabeledContent("Linked Tracks", value: "\(library.linkedCount)")
                LabeledContent("With a File", value: "\(library.fileCount)")
                HStack {
                    Button("Import…") { sheet = .importLibrary }
                    Button("Import Analysis…") { sheet = .importAnalysis }
                    Button("Export for rekordbox…") {
                        Task {
                            let draft = await library.prepareExport()
                            sheet = .export(draft)
                        }
                    }
                    .disabled(library.fileCount == 0)
                }
            } header: {
                Text("rekordbox")
            } footer: {
                Text("Sounding never changes your rekordbox library.")
            }

            Section {
                Button("Open Prep") { openWindow(id: MacPrepCommands.windowID) }
                Button("Export to USB…") { sheet = .usb }
                    .disabled(library.fileCount == 0)
            } header: {
                Text("Prep")
            } footer: {
                Text("Beat grids, cue points and loops for each track. Export puts your own files and their prep on a stick.")
            }
        }
        .formStyle(.grouped)
        .task { await library.refreshCounts() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .importLibrary:
                MacRekordboxImportSheet(library: library) { self.sheet = nil }
            case .importAnalysis:
                MacRekordboxShareSheet(model: MacRekordboxShareImport(library: library)) { self.sheet = nil }
            case .usb:
                MacUSBExportSheet(model: MacUSBExportModel(store: library.store)) { self.sheet = nil }
            case .export(let draft):
                MacRekordboxExportSheet(library: library, draft: draft) { self.sheet = nil }
            }
        }
    }
}

struct MacRekordboxImportSheet: View {
    @ObservedObject var library: MacRekordboxLibrary
    let onClose: () -> Void
    var startsImmediately = true

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 720, height: 520)
        .onDisappear {
            if case .applying = library.phase { return }
            library.reset()
        }
        .task {
            guard startsImmediately else { return }
            switch library.phase {
            case .loading, .applying, .preview, .review:
                return
            case .done, .failed:
                library.reset()
            case .idle:
                break
            }
            guard library.hasChosenXML else { return }
            await library.beginImport()
        }
    }

    private func close() {
        library.reset()
        onClose()
    }

    private func chooseAndImport() {
        guard library.chooseXML() else { return }
        Task { await library.beginImport() }
    }

    @ViewBuilder
    private var content: some View {
        switch library.phase {
        case .idle where !library.hasChosenXML:
            ContentUnavailableView {
                Label("Import from rekordbox", systemImage: "square.and.arrow.down")
            } description: {
                Text("In rekordbox, choose File › Export Collection in xml format, then choose that file.")
            } actions: {
                Button("Choose File…", action: chooseAndImport)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .idle, .loading, .applying:
            ProgressView()
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t Read This File", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Choose a library exported from rekordbox with File › Export Collection in xml format.")
            } actions: {
                Button("Choose Another File…", action: chooseAndImport)
            }
        case .preview(let preview):
            MacRekordboxPreviewView(library: library, preview: preview)
        case .review(let plan):
            MacRekordboxConflictReview(library: library, plan: plan)
        case .done(let tracks, let cues):
            ContentUnavailableView {
                Label("Imported", systemImage: "checkmark.circle")
            } description: {
                Text("\(tracks) \(tracks == 1 ? "track" : "tracks") and \(cues) cue \(cues == 1 ? "point" : "points") from rekordbox.")
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch library.phase {
            case .preview(let preview):
                Text(summary(preview))
                    .foregroundStyle(MacSecondaryStyle())
                    .monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { Task { await library.continueImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.matched.isEmpty && library.ambiguousChoices.isEmpty)
            case .review(let plan):
                Text("\(plan.conflicts.count) \(plan.conflicts.count == 1 ? "difference" : "differences")")
                    .foregroundStyle(MacSecondaryStyle())
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { Task { await library.apply(plan) } }
                    .keyboardShortcut(.defaultAction)
            case .done, .failed:
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            case .idle, .loading, .applying:
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func summary(_ preview: RekordboxImportPreview) -> String {
        let chosen = library.ambiguousChoices.count
        return "\(preview.matched.count + chosen) of \(preview.rows.count) tracks will import"
    }
}

struct MacRekordboxPreviewView: View {
    @ObservedObject var library: MacRekordboxLibrary
    let preview: RekordboxImportPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import from rekordbox")
                        .font(.title3.weight(.semibold))
                    Text(detailLine)
                        .foregroundStyle(MacSecondaryStyle())
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("Choose Another File…") {
                    guard library.chooseXML() else { return }
                    Task { await library.beginImport() }
                }
            }
            MacGlassTabs(
                "Show",
                selection: $library.bucket,
                options: [.matched, .choose, .missing],
                compact: true
            ) { bucket in
                switch bucket {
                case .matched: "Matched \(preview.matched.count)"
                case .choose: "Choose \(preview.ambiguous.count)"
                case .missing: "Not in Sounding \(preview.missing.count)"
                }
            }
            .controlSize(.small)

            table
                .overlay { emptyState }

            LabeledContent("Music Folder") {
                HStack {
                    Text(library.musicFolderName ?? "No access")
                        .foregroundStyle(library.musicFolderName == nil ? .secondary : .primary)
                    Button("Allow Access…") { library.chooseMusicFolder() }
                }
            }
            .help("Lets Sounding link your files so they can go back to rekordbox.")
        }
        .padding(16)
    }

    private var detailLine: String {
        let playlists = preview.library.flattenedPlaylists().count
        return "\(library.xmlName ?? "rekordbox.xml") · \(preview.rows.count) tracks · \(playlists) \(playlists == 1 ? "playlist" : "playlists")"
    }

    private var rows: [RekordboxImportPreview.Row] {
        switch library.bucket {
        case .matched: return preview.matched
        case .choose:  return preview.ambiguous
        case .missing: return preview.missing
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if rows.isEmpty {
            switch library.bucket {
            case .matched:
                ContentUnavailableView("No Matches", systemImage: "music.note.list", description: Text("None of these tracks are in your Sounding library yet."))
            case .choose:
                ContentUnavailableView("Nothing to Choose", systemImage: "checkmark.circle", description: Text("Every match is certain."))
            case .missing:
                ContentUnavailableView("Everything Matched", systemImage: "checkmark.circle", description: Text("Every track is in your Sounding library."))
            }
        }
    }

    private var table: some View {
        Table(rows) {
            TableColumn("Title") { row in Text(row.track.name) }
            TableColumn("Artist") { row in Text(row.track.artist).foregroundStyle(MacSecondaryStyle()) }
            TableColumn("Time") { row in
                Text(DJFormat.time(row.track.totalTime)).monospacedDigit().foregroundStyle(MacSecondaryStyle())
            }
            .width(52)
            TableColumn("Cues") { row in
                Text("\(row.track.marks.count)").monospacedDigit().foregroundStyle(MacSecondaryStyle())
            }
            .width(40)
            TableColumn(library.bucket == .missing ? "" : "In Sounding") { row in
                matchCell(row)
            }
            .width(min: 120, ideal: 220)
        }
    }

    @ViewBuilder
    private func matchCell(_ row: RekordboxImportPreview.Row) -> some View {
        switch row.outcome {
        case .matched(let id):
            Text(library.candidatesById[id].map { "\($0.title)" } ?? "Matched")
                .foregroundStyle(MacSecondaryStyle())
                .lineLimit(1)
        case .ambiguous(let ids):
            Picker("Sounding Track", selection: Binding(
                get: { library.ambiguousChoices[row.id] ?? "" },
                set: { library.ambiguousChoices[row.id] = $0.isEmpty ? nil : $0 }
            )) {
                Text("Skip").tag("")
                ForEach(ids, id: \.self) { id in
                    let candidate = library.candidatesById[id]
                    Text(candidate.map { "\($0.title) · \($0.artist) · \(DJFormat.time($0.durationSeconds))" } ?? id).tag(id)
                }
            }
            .labelsHidden()
        case .missing:
            Text("Stays in rekordbox")
                .foregroundStyle(.tertiary)
        }
    }
}

struct MacRekordboxConflictReview: View {
    @ObservedObject var library: MacRekordboxLibrary
    let plan: RekordboxImportPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Changes")
                        .font(.title3.weight(.semibold))
                    Text("These differ from what you set in Sounding.")
                        .foregroundStyle(MacSecondaryStyle())
                }
                Spacer()
                Button("Keep All Sounding") { library.setAllConflicts(.keepSounding) }
                Button("Use All Imported") { library.setAllConflicts(.useImported) }
            }
            Table(plan.conflicts) {
                TableColumn("Track") { conflict in Text(conflict.trackTitle).lineLimit(1) }
                TableColumn("Item") { conflict in Text(conflict.itemName) }
                    .width(100)
                TableColumn("Sounding") { conflict in
                    Text(conflict.soundingValue).monospacedDigit().lineLimit(1)
                }
                TableColumn("Imported") { conflict in
                    Text(conflict.importedValue).monospacedDigit().lineLimit(1)
                }
                TableColumn("Keep") { conflict in
                    Picker("Keep", selection: Binding(
                        get: { library.conflictChoices[conflict.id] ?? .keepSounding },
                        set: { library.conflictChoices[conflict.id] = $0 }
                    )) {
                        Text("Sounding").tag(ImportChoice.keepSounding)
                        Text("Imported").tag(ImportChoice.useImported)
                    }
                    .labelsHidden()
                }
                .width(120)
            }
        }
        .padding(16)
    }
}

struct MacRekordboxExportSheet: View {
    @ObservedObject var library: MacRekordboxLibrary
    let draft: MacRekordboxLibrary.ExportDraft
    let onClose: () -> Void
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Tracks", value: "\(draft.summary.tracks)")
                    LabeledContent("Cue Points", value: "\(draft.summary.cues)")
                } header: {
                    Text("Export for rekordbox")
                } footer: {
                    Text("In rekordbox, add the file under Preferences › Advanced › rekordbox xml.")
                }
                if !notIncluded.isEmpty {
                    Section("Not Included") {
                        ForEach(notIncluded, id: \.0) { row in
                            LabeledContent(row.0, value: row.1)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if failed {
                    Text("Couldn't save the file.")
                        .foregroundStyle(MacSecondaryStyle())
                }
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    if library.export(draft) { onClose() } else { failed = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.items.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 440)
    }

    private var notIncluded: [(String, String)] {
        let summary = draft.summary
        var rows: [(String, String)] = []
        if summary.skippedSoundCloudOnly > 0 { rows.append(("SoundCloud-only tracks", "\(summary.skippedSoundCloudOnly)")) }
        if summary.droppedSuggestions > 0 { rows.append(("Suggested cue points", "\(summary.droppedSuggestions)")) }
        if summary.droppedPhrases > 0 { rows.append(("Phrases", "\(summary.droppedPhrases) tracks")) }
        if summary.droppedEnergy > 0 { rows.append(("Energy", "\(summary.droppedEnergy) tracks")) }
        if summary.droppedMemoryColours > 0 { rows.append(("Memory cue colours", "\(summary.droppedMemoryColours)")) }
        return rows
    }
}
