import SwiftUI

struct MacUSBExportSheet: View {
    @StateObject private var model: MacUSBExportModel
    let onClose: () -> Void

    init(model: @autoclosure @escaping () -> MacUSBExportModel, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model())
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 520, height: sheetHeight)
        .task { await model.load() }
        .onDisappear { model.close() }
        .alert("Replace the Library on “\(model.volume?.name ?? "the Stick")”?", isPresented: $model.confirmsReplace) {
            Button("Replace Library", role: .destructive) { model.startExport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current library is kept on the stick as \(model.backupFolderName). Your music files stay where they are.")
        }
    }

    private var sheetHeight: CGFloat {
        switch model.phase {
        case .setup:
            return model.isLoading || !model.hasAnyEligible || model.volumes.isEmpty ? 360 : 720
        case .working:
            return 420
        case .finished, .failed:
            return 360
        }
    }

    private func close() {
        model.close()
        onClose()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .setup:
            setup
        case .working(let working):
            progress(working)
        case .finished(let finished):
            finishedView(finished)
        case .failed(let failure):
            ContentUnavailableView {
                Label(failure.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.message)
            } actions: {
                Button(failure.retryTitle) { model.retry(failure) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var setup: some View {
        if model.isLoading {
            ProgressView()
        } else if !model.hasAnyEligible {
            ContentUnavailableView {
                Label("No Tracks Ready", systemImage: "externaldrive.badge.questionmark")
            } description: {
                Text("Only tracks with a file on this Mac can go on a stick. Link one in Prep.")
            }
        } else if model.volumes.isEmpty {
            ContentUnavailableView {
                Label("No USB Stick or SD Card", systemImage: "externaldrive.badge.xmark")
            } description: {
                Text("Insert one, or choose a volume.")
            } actions: {
                Button("Choose Volume…") { model.allowAccess(chooseAnyVolume: true) }
            }
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            tracksSection
            destinationSection
            previewSection
        }
        .formStyle(.grouped)
    }

    private var tracksSection: some View {
        Section {
            ForEach(model.sources) { source in
                Toggle(isOn: Binding(get: { model.isChosen(source) }, set: { model.setChosen(source, $0) })) {
                    Text(source.name)
                    Text(model.count(source) == 1 ? "1 track" : "\(model.count(source)) tracks")
                }
            }
            LabeledContent("Ready") {
                Text("\(model.eligible.count) of \(model.scopedCandidates.count)")
                    .monospacedDigit()
            }
            if !model.streamOnly.isEmpty {
                DisclosureGroup("No File on This Mac (\(model.streamOnly.count))") {
                    ForEach(model.streamOnly.prefix(50)) { candidate in
                        LabeledContent {
                            Button("Find Local File…") { model.findLocalFile(for: candidate) }
                                .controlSize(.small)
                        } label: {
                            Text(candidate.title).lineLimit(1)
                        }
                    }
                    if model.streamOnly.count > 50 {
                        Text("and \(model.streamOnly.count - 50) more")
                            .foregroundStyle(MacSecondaryStyle())
                    }
                }
            }
        } header: {
            Text("Playlists")
        } footer: {
            if !model.streamOnly.isEmpty {
                #if SOUNDING_PERSONAL
                Text(model.fetchesMissingAudio ? "Tracks without a file on this Mac are fetched from SoundCloud first, one at a time." : "Tracks without a file on this Mac are left off the stick.")
                #else
                Text("Tracks without a file on this Mac are left off the stick.")
                #endif
            }
        }
    }

    private var destinationSection: some View {
        Section {
            Picker("Volume", selection: $model.volumeId) {
                ForEach(model.volumes) { volume in
                    Text(volume.name).tag(Optional(volume.id))
                }
            }
            if let volume = model.volume {
                LabeledContent("Free Space") {
                    Text("\(MacUSBExportModel.byteString(volume.availableBytes)) of \(MacUSBExportModel.byteString(volume.totalBytes))")
                        .monospacedDigit()
                }
                LabeledContent("Format", value: volume.formatName)
                if let findings = model.findings {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(findings.summary, systemImage: "exclamationmark.triangle")
                        HStack {
                            Button("Repair…") { model.repair() }
                                .disabled(model.isRepairing)
                            if model.isRepairing { ProgressView().controlSize(.small) }
                        }
                    }
                }
                if let message = model.repairMessage {
                    Text(message).foregroundStyle(MacSecondaryStyle())
                }
                ForEach(model.libraryProblems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(MacSecondaryStyle())
                }
                if volume.isWritable {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(model.availableModes, id: \.self) { mode in
                            Text(Self.title(mode)).tag(mode)
                        }
                    }
                } else {
                    LabeledContent("Access") {
                        Button("Allow Access…") { model.allowAccess() }
                    }
                    if let message = model.accessMessage {
                        Text(message).foregroundStyle(MacSecondaryStyle())
                    }
                }
            }
            Button("Choose Another Volume…") { model.allowAccess(chooseAnyVolume: true) }
        } header: {
            Text("Destination")
        } footer: {
            if let volume = model.volume, volume.isWritable {
                Text(Self.footer(model.mode, backup: model.backupFolderName))
            } else {
                Text("Sounding needs your permission to write to a stick.")
            }
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            if model.isPreviewing {
                LabeledContent("Tracks") { ProgressView().controlSize(.small) }
            } else {
                LabeledContent("Tracks") {
                    Text("\(model.preview.tracks), \(MacUSBExportModel.byteString(model.preview.bytes))")
                        .monospacedDigit()
                }
                ForEach(model.preview.errors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                ForEach(model.preview.notes.prefix(6)) { note in
                    LabeledContent(note.title) {
                        Text(note.detail).foregroundStyle(MacSecondaryStyle())
                    }
                }
                if model.preview.notes.count > 6 {
                    Text("and \(model.preview.notes.count - 6) more")
                        .foregroundStyle(MacSecondaryStyle())
                }
            }
        }
    }

    static func title(_ mode: MacUSBExportModel.Mode) -> String {
        switch mode {
        case .newFolder: return "New Folder"
        case .blankRoot: return "Blank Stick (Root)"
        case .replace:   return "Replace Library"
        }
    }

    static func footer(_ mode: MacUSBExportModel.Mode, backup: String) -> String {
        switch mode {
        case .newFolder:
            return "Adds a Sounding Export folder and leaves everything else alone. DJ players only read a stick's root, so they won't see it there."
        case .blankRoot:
            return "Puts the library at the stick's root, where DJ players look. Only offered for sticks with no library."
        case .replace:
            return "Swaps in a new library. The old one stays on the stick in a PIONEER.before-sounding folder."
        }
    }

    private func progress(_ working: MacUSBExportModel.Working) -> some View {
        Form {
            Section {
                ProgressView(value: working.fraction)
                ForEach(MacUSBExportModel.Stage.allCases, id: \.self) { stage in
                    HStack {
                        stageIcon(stage, current: working.stage)
                        Text(stage.title)
                            .foregroundStyle(stage.rawValue > working.stage.rawValue ? .secondary : .primary)
                        Spacer()
                        if stage == working.stage, working.total > 1 {
                            Text("\(min(working.completed, working.total)) of \(working.total)")
                                .foregroundStyle(MacSecondaryStyle())
                                .monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Exporting to “\(model.volume?.name ?? "the Stick")”")
            } footer: {
                Text("What's already on the stick isn't touched until the end, and cancelling leaves it as it was.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func stageIcon(_ stage: MacUSBExportModel.Stage, current: MacUSBExportModel.Stage) -> some View {
        if stage.rawValue < current.rawValue {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(MacSecondaryStyle())
        } else if stage == current {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    static func leftOut(_ finished: MacUSBExportModel.Finished) -> String {
        let names = finished.leftOut.prefix(3).map { "“\($0)”" }
        guard !names.isEmpty else { return "\(finished.skipped) left out." }
        let more = finished.leftOut.count - names.count
        let list = ListFormatter.localizedString(byJoining: more > 0 ? names + ["\(more) more"] : names)
        return "Left out: \(list)."
    }

    private func finishedView(_ finished: MacUSBExportModel.Finished) -> some View {
        ContentUnavailableView {
            Label("Exported", systemImage: "checkmark.circle")
        } description: {
            VStack(spacing: 4) {
                Text("\(finished.tracks) \(finished.tracks == 1 ? "track is" : "tracks are") on “\(finished.volume.name)”.")
                if finished.skipped > 0 {
                    Text(Self.leftOut(finished))
                }
                Text(model.ejectMessage ?? "Done. You can unplug the stick.")
            }
        } actions: {
            HStack {
                Button("Show in Finder") { model.revealInFinder() }
                Button("Eject") { model.eject() }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch model.phase {
            case .setup:
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(model.mode == .replace ? "Replace Library…" : "Export") { model.requestExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canExport)
            case .working:
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .finished:
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Spacer()
                Button("Close", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
