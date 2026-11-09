#if os(macOS) || os(iOS)
import Combine
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

@MainActor
final class SoundingDataSettingsModel: ObservableObject {
    @Published private(set) var bytes: Int64?
    @Published private(set) var status: SoundingDataLocation.Status = SoundingDataLocation.shared.status
    @Published private(set) var progress: Double?
    @Published var pendingFolder: URL?
    @Published var pendingFolderHasData = false
    @Published var confirmingReset = false
    @Published var errorMessage: String?

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let center = NotificationCenter.default
        Publishers.Merge(
            center.publisher(for: .soundingDataLocationDidChange),
            center.publisher(for: .analysisDataDidChange)
        )
        .debounce(for: .seconds(3), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            guard let self else { return }
            Task { await self.refresh() }
        }
        .store(in: &cancellables)
    }

    var isMoving: Bool { progress != nil }

    var isCustom: Bool {
        if case .standard = status { return false }
        return true
    }

    var sizeLabel: String {
        bytes.map { DownloadsFormat.bytes($0) } ?? "–"
    }

    var locationLabel: String {
        switch status {
        case .standard: return "On This \(DeviceClass.current.displayName)"
        case .custom(let url), .unavailable(let url): return url.deletingLastPathComponent().lastPathComponent
        }
    }

    var unavailableName: String? {
        guard case .unavailable(let url) = status else { return nil }
        return url.deletingLastPathComponent().lastPathComponent
    }

    func refresh() async {
        status = SoundingDataLocation.shared.status
        let root = SoundingDataLocation.shared.root
        bytes = await Task.detached(priority: .utility) { SoundingDataFiles.bytes(in: root) }.value
    }

    func picked(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        pendingFolderHasData = SoundingDataLocation.containsData(url)
        if accessing { url.stopAccessingSecurityScopedResource() }
        pendingFolder = url
    }

    func adoptPending(_ mode: SoundingDataLocation.AdoptMode) {
        guard let folder = pendingFolder else { return }
        pendingFolder = nil
        run { progress in
            try await SoundingDataLocation.shared.choose(folder, mode: mode, progress: progress)
        }
    }

    func reset(_ mode: SoundingDataLocation.AdoptMode) {
        run { progress in
            try await SoundingDataLocation.shared.resetToStandard(mode: mode, progress: progress)
        }
    }

    #if os(macOS)
    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([SoundingDataLocation.shared.root])
    }
    #endif

    private func run(_ work: @escaping @MainActor (@escaping @Sendable (Double) -> Void) async throws -> Void) {
        progress = 0
        let report: @Sendable (Double) -> Void = { [weak self] value in
            guard let self else { return }
            Task { @MainActor in
                guard self.progress != nil else { return }
                self.progress = value
            }
        }
        Task {
            do {
                try await work(report)
            } catch {
                errorMessage = error.localizedDescription
            }
            progress = nil
            await refresh()
        }
    }
}

struct SoundingDataSettingsSection: View {
    @StateObject private var model = SoundingDataSettingsModel()
    @State private var choosingFolder = false

    var body: some View {
        Section {
            LabeledContent("Size", value: model.sizeLabel)
            if let name = model.unavailableName {
                Label("\(name) isn't available. Saving on this \(DeviceClass.current.displayName) until it's back.", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            #if os(macOS)
            LabeledContent("Location") {
                HStack {
                    Text(model.locationLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Show in Finder") { model.showInFinder() }
                }
            }
            if let progress = model.progress {
                ProgressView(value: progress) {
                    Text("Moving…")
                }
            } else {
                HStack {
                    Spacer()
                    if model.isCustom {
                        Button("Use Default Location…") { model.confirmingReset = true }
                    }
                    Button("Change Location…") { choosingFolder = true }
                }
            }
            #endif
        } header: {
            Text("Sounding Data")
        } footer: {
            Text("Analysis, waveforms, mix history and setlists.")
        }
        .task { await model.refresh() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            model.picked(result)
        }
        .confirmationDialog(
            model.pendingFolderHasData ? "This folder already has Sounding Data." : "Move Sounding Data to “\(model.pendingFolder?.lastPathComponent ?? "")”?",
            isPresented: Binding(get: { model.pendingFolder != nil }, set: { if !$0 { model.pendingFolder = nil } })
        ) {
            if model.pendingFolderHasData {
                Button("Use Existing") { model.adoptPending(.useExisting) }
                Button("Merge") { model.adoptPending(.move) }
            } else {
                Button("Move") { model.adoptPending(.move) }
            }
            Button("Cancel", role: .cancel) { model.pendingFolder = nil }
        } message: {
            if model.pendingFolderHasData {
                Text("Use it as it is, or merge this \(DeviceClass.current.displayName)’s data into it.")
            }
        }
        .confirmationDialog("Use the Default Location?", isPresented: $model.confirmingReset) {
            Button("Move Back") { model.reset(.move) }
            Button("Leave Data in Place") { model.reset(.useExisting) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Couldn’t Move Sounding Data",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
#endif
