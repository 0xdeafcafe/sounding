import SwiftUI

struct DJPrepSidebar: View {
    @ObservedObject var model: MacPrepModel
    @ObservedObject var sticks: MacDJSticks
    @Binding var showsImport: Bool
    @Binding var showsNewCrate: Bool

    private var selection: Binding<MacPrepModel.Source?> {
        Binding(
            get: { model.source },
            set: { if let value = $0 { model.source = value } }
        )
    }

    private var selectableSources: [MacPrepModel.Source] {
        var sources: [MacPrepModel.Source] = [.likes, .all]
        sources += model.folders.map { MacPrepModel.Source.folder($0.name) }
        sources += model.playlists.map { MacPrepModel.Source.playlist($0.id) }
        sources += MacPrepModel.SmartCrate.allCases.map { MacPrepModel.Source.smart($0) }
        sources += sticks.volumes.map { MacPrepModel.Source.stick(volume: $0.id, playlist: nil) }
        return sources
    }

    var body: some View {
        List {
            Section {
                item("Likes", systemImage: "heart.fill", count: model.likesCount, source: .likes)
            } header: {
                HStack {
                    Text("SoundCloud")
                    Spacer()
                    Text(model.streamsAllowed ? "Go+" : "Auto Mix")
                        .foregroundStyle(.secondary)
                        .help(model.streamsAllowed ? "SoundCloud tracks stream into Prep and the decks" : "SoundCloud tracks are Auto Mix only. Go+ unlocks decks.")
                }
            }

            Section("On This Mac") {
                item("All Tracks", systemImage: "music.note.list", count: model.count(.all), source: .all)
                ForEach(model.folders, id: \.name) { folder in
                    item(folder.name, systemImage: "folder", count: folder.count, source: .folder(folder.name))
                }
            }

            Section {
                ForEach(model.playlists) { crate in
                    item(crate.name, systemImage: "square.stack", count: crate.trackIds.count, source: .playlist(crate.id))
                        .dropDestination(for: String.self) { ids, _ in
                            model.add(ids, toCrate: crate.id)
                            return true
                        }
                }
            } header: {
                HStack {
                    Text("Crates")
                    Spacer()
                    Button {
                        showsNewCrate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Crate")
                    .accessibilityLabel("New Crate")
                }
            }

            Section("Smart Crates") {
                ForEach(MacPrepModel.SmartCrate.allCases, id: \.self) { crate in
                    item(crate.title, systemImage: "sparkles", count: model.count(crate), source: .smart(crate))
                }
            }

            Section("USB Sticks") {
                ForEach(sticks.volumes) { volume in
                    HStack {
                        Label(volume.name, systemImage: "externaldrive")
                        Spacer()
                        if let free = freeSpace(volume.name) {
                            Text(free).foregroundStyle(MacSecondaryStyle()).monospacedDigit()
                        }
                    }
                    .macSelectableRow(MacPrepModel.Source.stick(volume: volume.id, playlist: nil), selection: selection)
                }
                ForEach(model.volumes.filter { volume in !sticks.volumes.contains { $0.name == volume.name } }) { volume in
                    Button {
                        Task { await sticks.addStick() }
                    } label: {
                        HStack {
                            Label(volume.name, systemImage: "externaldrive")
                            Spacer()
                            Text("\(MacUSBExportModel.byteString(volume.availableBytes)) free")
                                .foregroundStyle(MacSecondaryStyle())
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .macSidebarRowChrome()
                    .help("Browse this stick in Prep")
                }
            }

            Section("rekordbox") {
                Button {
                    MacRekordboxFolderPresenter.choose()
                } label: {
                    Label("Import Library…", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .macSidebarRowChrome()
                .help("Import a whole rekordbox folder, USB export or collection")
                Button {
                    showsImport = true
                } label: {
                    Label("Import XML…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .macSidebarRowChrome()
                .help("Import cue points, grids and playlists from a rekordbox xml file")
            }
        }
        .listStyle(.sidebar)
        .macListKeyboardSelection(ids: selectableSources, selection: selection)
        .scrollContentBackground(.hidden)
        .background(MacVisualEffectBackground(role: .sidebar, blending: .withinWindow).ignoresSafeArea())
    }

    private func item(_ title: String, systemImage: String, count: Int, source: MacPrepModel.Source) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(count.formatted())
                .foregroundStyle(MacSecondaryStyle())
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .macSelectableRow(source, selection: selection)
    }

    private func freeSpace(_ name: String) -> String? {
        guard let volume = model.volumes.first(where: { $0.name == name }) else { return nil }
        return "\(MacUSBExportModel.byteString(volume.availableBytes)) free"
    }
}
