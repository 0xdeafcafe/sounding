import SwiftUI

struct MacRekordboxFolderSheet: View {
    static let width: CGFloat = 720
    static let height: CGFloat = 540

    @ObservedObject var model: MacRekordboxFolderImport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: Self.width, height: Self.height)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .scanning:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text("Looking in \(model.folderName)…")
                    .font(.headline)
                Text(progressLine)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .needsExport:
            ContentUnavailableView {
                Label("Export from rekordbox First", systemImage: "square.and.arrow.up")
            } description: {
                Text("Sounding reads rekordbox’s XML export or a rekordbox USB or SD export.")
            } actions: {
                Button("How to Export…") { model.openExportHelp() }
            }
        case .nothingFound:
            ContentUnavailableView(
                "Nothing to Import",
                systemImage: "folder",
                description: Text("There’s no rekordbox library or music in \(model.folderName).")
            )
        case .ready(let found):
            if model.showsMissing {
                missingTable
            } else {
                summary(found)
            }
        case .review(let plan):
            MacRekordboxConflictReview(library: model.library, plan: plan)
        case .importing:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text("Importing…")
                    .font(.headline)
            }
        case .done(let result):
            if model.showsMissing {
                missingTable
            } else {
                ContentUnavailableView {
                    Label("Imported from rekordbox", systemImage: "checkmark.circle")
                } description: {
                    Text(doneText(result))
                } actions: {
                    if result.missing > 0 {
                        Button("Show Missing Files") { model.showsMissing = true }
                    }
                }
            }
        }
    }

    private var progressLine: String {
        let found = model.progress
        return "Found \(count(found.tracks, "track", "tracks")), \(count(found.playlists, "playlist", "playlists")), \(count(found.cues, "cue", "cues"))"
    }

    private func summary(_ found: MacRekordboxFolderImport.Found) -> some View {
        let summary = found.summary
        return Form {
            Section {
                LabeledContent("Tracks", value: summary.tracks.formatted())
                LabeledContent("Playlists", value: summary.playlists.formatted())
                LabeledContent("Cue Points", value: summary.cues.formatted())
                LabeledContent("Beat Grids", value: summary.grids.formatted())
                if summary.keys > 0 {
                    LabeledContent("Keys", value: summary.keys.formatted())
                }
                if summary.audioFiles > 0 {
                    LabeledContent("Music Files", value: summary.audioFiles.formatted())
                }
            } header: {
                Text(model.folderName)
            } footer: {
                if found.scan.isAnalysisOnly {
                    HStack {
                        Text("Keys and cue points need rekordbox’s XML export.")
                        Button("How to Export…") { model.openExportHelp() }
                            .buttonStyle(.link)
                    }
                }
            }

            Section {
                LabeledContent("Matched by File", value: summary.byFile.formatted())
                LabeledContent("Matched by Title", value: summary.byTitle.formatted())
                if summary.newAudioFiles > 0 {
                    LabeledContent("New to Your Library", value: summary.newAudioFiles.formatted())
                }
                LabeledContent("Missing Files") {
                    HStack {
                        Text(summary.notFound.formatted())
                        if summary.notFound > 0 {
                            Button("Show") { model.showsMissing = true }
                        }
                    }
                }
            } header: {
                Text("In Sounding")
            } footer: {
                if model.canAllowMusicAccess {
                    HStack {
                        Text(found.scan.classification.stickOutsideSelection
                             ? "Choose the whole drive to bring its music in too."
                             : "Choose the folder that holds your music to find more.")
                        Button("Allow Access…") { model.allowMusicAccess() }
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
    }

    private var missingTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Missing Files")
                .font(.title3.weight(.semibold))
            Table(model.missing) {
                TableColumn("Title") { match in Text(match.item.title).lineLimit(1) }
                TableColumn("Artist") { match in
                    Text(match.item.track.artist).foregroundStyle(.secondary).lineLimit(1)
                }
                TableColumn("Location") { match in
                    Text(match.item.filePath ?? match.item.fileName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(match.item.filePath ?? match.item.fileName)
                }
                .width(min: 160, ideal: 300)
            }
            .overlay {
                if model.missing.isEmpty {
                    ContentUnavailableView("Nothing Missing", systemImage: "checkmark.circle")
                }
            }
        }
        .padding(16)
    }

    private func doneText(_ result: RekordboxFolderResult) -> String {
        var parts = [count(result.tracks, "track", "tracks"), count(result.cues, "cue point", "cue points")]
        if result.playlists > 0 { parts.append(count(result.playlists, "playlist", "playlists")) }
        if result.phrases > 0 { parts.append("\(result.phrases.formatted()) with phrases") }
        var text = parts.joined(separator: " · ") + "."
        if result.keptYours > 0 { text += " Kept your own edits on \(result.keptYours.formatted())." }
        if result.missing > 0 { text += " \(count(result.missing, "file", "files")) couldn’t be found." }
        return text
    }

    private func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch model.phase {
            case .ready(let found):
                if model.showsMissing {
                    Button("Back") { model.showsMissing = false }
                    Spacer()
                } else {
                    Text("\(found.summary.matched.formatted()) of \(found.summary.tracks.formatted()) tracks will import")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                }
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { Task { await model.commit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(found.summary.matched == 0 && found.summary.newAudioFiles == 0)
            case .review(let plan):
                Text("\(plan.conflicts.count.formatted()) \(plan.conflicts.count == 1 ? "difference" : "differences")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { Task { await model.apply(plan) } }
                    .keyboardShortcut(.defaultAction)
            case .done:
                if model.showsMissing {
                    Button("Back") { model.showsMissing = false }
                }
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            case .needsExport, .nothingFound:
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            case .scanning:
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
            case .importing:
                Spacer()
            }
        }
    }
}
