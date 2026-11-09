#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers

enum MusicStep {
    static let answeredKey = "red.forbes.sounding.didAnswerMusicStep"
    static let pendingKey = "red.forbes.sounding.musicStepPending"

    static var isForced: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_MUSIC_STEP"] == "1"
        #else
        false
        #endif
    }

    static var isSuppressed: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["SOUNDING_TV_WELCOME"] == "1" { return false }
        return VisualFixtures.isEnabled
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["SOUNDING_TV_DISMISS_WELCOME"] == "1"
        #else
        false
        #endif
    }
}

struct MusicStepPage: View {
    let onAnswered: (_ addedFolder: Bool) -> Void

    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @State private var isChoosingFolder = false

    static let tint = Color.scAccent

    private var account: OnboardingAccount? {
        guard !credentials.isSignedOut, let user = credentials.currentUser else { return nil }
        return OnboardingAccount(user: user)
    }

    var body: some View {
        OnboardingFeaturePage(
            account: account,
            symbol: "folder.fill.badge.plus",
            title: "Add Your Own Music",
            features: OnboardingFeature.ownMusic
        ) {
            Button { isChoosingFolder = true } label: {
                Text("Choose Folder…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Self.tint)
            #if os(macOS)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            #else
            .controlSize(.large)
            #endif
            .accessibilityIdentifier("musicStep.chooseFolder")

            notNowButton
                .accessibilityIdentifier("musicStep.notNow")
        }
        .addMusicFolderImporter(isPresented: $isChoosingFolder) { onAnswered(true) }
    }

    @ViewBuilder
    private var notNowButton: some View {
        #if os(macOS)
        Button { onAnswered(false) } label: {
            Text("Not Now")
                .font(.body.weight(.medium))
                .foregroundStyle(Self.tint)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .keyboardShortcut(.cancelAction)
        #else
        Button("Not Now") { onAnswered(false) }
            .buttonStyle(.borderless)
            .font(.callout.weight(.medium))
            .tint(Self.tint)
            .frame(minHeight: 44)
        #endif
    }
}

@MainActor
enum LocalMusicFormat {
    static func trackCount(_ count: Int) -> String {
        count == 1 ? "1 track" : "\(count) tracks"
    }

    static func folderSummary(_ library: LocalMusicLibrary) -> String {
        switch library.folders.count {
        case 0: return "None"
        case 1: return "1 folder"
        default: return "\(library.folders.count) folders"
        }
    }

    static func status(of folder: MusicFolder, in library: LocalMusicLibrary) -> String {
        if library.unavailableFolderIDs.contains(folder.id) { return "Not Available" }
        if library.isScanning(folder.id) {
            guard let progress = library.scanProgress[folder.id], progress.total > 0 else { return "Scanning…" }
            return "Scanning \(progress.done) of \(progress.total)…"
        }
        let waiting = folder.files.filter { !$0.isDownloaded }.count
        if waiting > 0 { return "\(trackCount(folder.files.count)), \(waiting) downloading" }
        return trackCount(folder.files.count)
    }
}

struct AddMusicFolderModifier: ViewModifier {
    @Binding var isPresented: Bool
    var onAdded: (() -> Void)?
    @ObservedObject private var library = LocalMusicLibrary.shared
    @State private var failedNames: [String] = []
    @State private var addedSome = false

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    var failed: [String] = []
                    for url in urls {
                        do { try library.addFolder(at: url) } catch { failed.append(url.lastPathComponent) }
                    }
                    addedSome = failed.count < urls.count
                    failedNames = failed
                    if failed.isEmpty, addedSome { finish() }
                case .failure:
                    failedNames = [""]
                }
            }
            .alert(
                failedNames.count == 1 && !failedNames[0].isEmpty ? "Couldn’t Add “\(failedNames[0])”" : "Couldn’t Add Folder",
                isPresented: Binding(get: { !failedNames.isEmpty }, set: { if !$0 { failedNames = [] } })
            ) {
                Button("OK", role: .cancel) {
                    failedNames = []
                    if addedSome { finish() }
                }
            } message: {
                Text("Sounding couldn’t get access to that folder. Try choosing it again.")
            }
    }

    private func finish() {
        addedSome = false
        onAdded?()
    }
}

extension View {
    func addMusicFolderImporter(isPresented: Binding<Bool>, onAdded: (() -> Void)? = nil) -> some View {
        modifier(AddMusicFolderModifier(isPresented: isPresented, onAdded: onAdded))
    }
}

struct MusicFoldersSection: View {
    @ObservedObject private var library = LocalMusicLibrary.shared
    @State private var isAdding = Self.debugOpensImporter

    private static var debugOpensImporter: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_OPEN_FOLDER_PICKER"] == "1"
        #else
        false
        #endif
    }

    var body: some View {
        Section {
            ForEach(library.folders) { folder in
                folderRow(folder)
            }
            Button("Add Folder…", systemImage: "folder.badge.plus") { isAdding = true }
                .addMusicFolderImporter(isPresented: $isAdding)
            if !library.folders.isEmpty {
                Button("Rescan All", systemImage: "arrow.clockwise") { library.rescanAll() }
                    .disabled(!library.scanningFolderIDs.isEmpty)
            }
        } header: {
            Text("Folders")
        } footer: {
            Text("Your own music plays and mixes like any other track. Linked Apple TVs can play it while Sounding is open here.")
        }
        LocalMusicCloudSection()
    }

    private func folderRow(_ folder: MusicFolder) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                if library.isScanning(folder.id) {
                    ProgressView().controlSize(.small)
                }
                Text(LocalMusicFormat.status(of: folder, in: library))
                    .monospacedDigit()
            }
        } label: {
            Label(folder.name, systemImage: library.unavailableFolderIDs.contains(folder.id) ? "folder.badge.questionmark" : "folder")
        }
        .contextMenu {
            Button("Rescan", systemImage: "arrow.clockwise") { library.rescan(folder.id) }
            Button("Remove", systemImage: "minus.circle", role: .destructive) { library.removeFolder(folder.id) }
        }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash", role: .destructive) { library.removeFolder(folder.id) }
            Button("Rescan", systemImage: "arrow.clockwise") { library.rescan(folder.id) }
        }
        #else
        .accessibilityActions {
            Button("Rescan") { library.rescan(folder.id) }
            Button("Remove") { library.removeFolder(folder.id) }
        }
        #endif
    }
}

struct LocalMusicCloudSection: View {
    @ObservedObject private var uploader = LocalMusicCloudUploader.shared
    @State private var confirmsRemoval = false

    var body: some View {
        Section {
            Toggle("Upload to iCloud", isOn: Binding(
                get: { uploader.isEnabled },
                set: { uploader.setEnabled($0) }
            ))
            if uploader.isEnabled || uploader.bytesUsed > 0 {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if uploader.phase == .checking || uploader.phase == .removing {
                            ProgressView().controlSize(.small)
                        }
                        Text(status).monospacedDigit()
                    }
                }
                if let progress = uploader.progress {
                    ProgressView(value: progress)
                }
                LabeledContent("iCloud Storage Used") {
                    Text(ByteCountFormatter.string(fromByteCount: uploader.bytesUsed, countStyle: .file)).monospacedDigit()
                }
                Button("Remove All from iCloud", systemImage: "icloud.slash", role: .destructive) {
                    confirmsRemoval = true
                }
                .disabled(uploader.phase == .removing)
                .confirmationDialog("Remove your music from iCloud?", isPresented: $confirmsRemoval) {
                    Button("Remove All", role: .destructive) { uploader.removeAll() }
                } message: {
                    Text("The files in your music folders stay on this device.")
                }
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Uploads your own files, never SoundCloud tracks, to your private iCloud on Wi-Fi so Apple TV can play them when this device is away.")
        }
    }

    private var status: String {
        switch uploader.phase {
        case .off: return "Off"
        case .checking: return "Checking…"
        case .waitingForWiFi: return "Waiting for Wi-Fi"
        case .uploading: return "\(uploader.uploadedCount) of \(uploader.totalCount)"
        case .upToDate: return "Up to Date"
        case .removing: return "Removing…"
        case .unavailable(let reason): return reason
        }
    }
}

struct MusicFoldersSettingsView: View {
    var body: some View {
        Form {
            MusicFoldersSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Music Folders")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct LocalMusicEmptyState: View {
    @ObservedObject private var library = LocalMusicLibrary.shared
    let onAdd: () -> Void

    var body: some View {
        Group {
            if library.folders.isEmpty {
                ContentUnavailableView {
                    Label("No Music Folders", systemImage: "folder")
                } description: {
                    Text("Add a folder of your own music to play and mix it here.")
                } actions: {
                    Button("Add Folder…", action: onAdd)
                }
            } else if !library.scanningFolderIDs.isEmpty {
                LocalMusicScanningState()
            } else {
                ContentUnavailableView {
                    Label("No Music Found", systemImage: "music.note")
                } description: {
                    Text("These folders have no MP3, AAC, ALAC, WAV, AIFF or FLAC files.")
                } actions: {
                    Button("Rescan") { library.rescanAll() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LocalMusicScanningState: View {
    @ObservedObject private var library = LocalMusicLibrary.shared

    private var progress: LocalMusicScanProgress? {
        let active = library.scanningFolderIDs.compactMap { library.scanProgress[$0] }
        guard !active.isEmpty else { return nil }
        return LocalMusicScanProgress(done: active.map(\.done).reduce(0, +), total: active.map(\.total).reduce(0, +))
    }

    var body: some View {
        ContentUnavailableView {
            Label("Scanning Your Music", systemImage: "folder")
        } description: {
            if let progress, progress.total > 0 {
                Text("\(progress.done) of \(LocalMusicFormat.trackCount(progress.total))")
                    .monospacedDigit()
            } else {
                Text("Looking for music files…")
            }
        } actions: {
            if let progress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .frame(maxWidth: 240)
            } else {
                ProgressView()
            }
        }
    }
}

struct TrackDurationLabel: View {
    let track: Track

    var body: some View {
        if track.isAwaitingLocalMetadata {
            Image(systemName: "icloud.and.arrow.down")
                .accessibilityLabel("Downloading from iCloud")
                .help("Downloading from iCloud")
        } else {
            Text(SubscriptionService.shared.displayedDuration(for: track))
        }
    }
}
#endif
