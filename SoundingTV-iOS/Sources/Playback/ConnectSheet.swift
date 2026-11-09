import AVKit
import SwiftUI

struct ConnectSheet: View {
    let onDone: () -> Void

    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @EnvironmentObject private var nearby: LinkOfferBrowser
    @EnvironmentObject private var pairing: DevicePairingFlow
    @ObservedObject private var sonos = SonosOutputController.shared
    @StateObject private var linking = PlayOnNearbyLinking()
    @State private var pending: String?
    @State private var failure: String?
    @State private var routePicker = ConnectRoutePicker()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ConnectCurrentOutput(sonos: sonos)
                } footer: {
                    if sonos.isActive {
                        Text("Keep this \(DeviceClass.current.displayName) on the same Wi-Fi while it plays on Sonos.")
                    } else if let notice = coordinator.output.notice {
                        Text(notice)
                    }
                }

                Section {
                    ForEach(coordinator.outputs.filter { !isCurrent($0) }) { device in
                        deviceRow(device)
                    }
                }
                .transaction { $0.animation = nil }

                if !linking.rows.isEmpty {
                    Section("Nearby") {
                        ForEach(linking.rows) { row in
                            Button {
                                linking.select(row)
                            } label: {
                                PlayOnNearbyRowLabel(row: row)
                            }
                            .disabled(pending != nil || !linking.isEnabled(row))
                        }
                    }
                    .transaction { $0.animation = nil }
                } else if coordinator.output.linkedDevices.isEmpty {
                    Section {
                        Button("Add Apple TV…", action: addAppleTV)
                    }
                }

                if !sonos.groups.isEmpty {
                    Section("Sonos") {
                        if let active = sonos.activeGroup {
                            sonosRow(active)
                        }
                        ForEach(sonos.groups.filter { !sonos.isPlaying(on: $0) }) { group in
                            sonosRow(group)
                        }
                    }
                }

                Section {
                    Button {
                        routePicker.present()
                    } label: {
                        Label("Bluetooth & AirPlay", systemImage: "airplay.audio")
                    }
                    .background(ConnectRoutePickerHost(picker: routePicker).frame(width: 1, height: 1).opacity(0.01))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Play On")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .alert("Couldn't Change Output", isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { failure = nil } }
            )) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
            .sheet(isPresented: Binding(
                get: { linking.comparison != nil },
                set: { if !$0 { linking.cancelComparison() } }
            )) {
                if let handshake = linking.comparison {
                    NavigationStack {
                        PlayOnLinkCodeView(handshake: handshake)
                            .navigationTitle("Link \(handshake.claimedName)")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel") { linking.cancelComparison() }
                                }
                            }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
        }
        .onAppear {
            sonos.startDiscovery()
            linking.attach(browser: nearby, router: coordinator.output)
        }
        .onDisappear {
            sonos.stopDiscovery()
            linking.closed()
        }
    }

    private func addAppleTV() {
        onDone()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            pairing.addDevice()
        }
    }

    private func isCurrent(_ device: OutputDevice) -> Bool {
        !sonos.isActive && device == coordinator.currentOutput
    }

    private func deviceRow(_ device: OutputDevice) -> some View {
        let availability = coordinator.availability(of: device) ?? .notResponding
        let reachable = device.isLocal || availability.isSelectable
        return Button {
            select(device)
        } label: {
            ConnectRowLabel(
                title: device.name,
                subtitle: pending == device.id ? "Connecting…" : (device.isLocal ? nil : (availability.label ?? device.deviceClass.displayName)),
                systemImage: device.isLocal ? DeviceClass.current.symbolName : device.symbolName,
                isPending: pending == device.id
            )
        }
        .disabled(pending != nil || (!device.isLocal && !reachable))
        .tint(.primary)
    }

    private func sonosRow(_ group: SonosGroup) -> some View {
        let isCurrent = sonos.isPlaying(on: group)
        return HStack(spacing: 0) {
            Button {
                select(group)
            } label: {
                ConnectRowLabel(
                    title: group.displayName,
                    subtitle: pending == group.id ? "Connecting…" : (isCurrent ? "Playing" : "Sonos"),
                    systemImage: group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill",
                    isPending: pending == group.id,
                    isSelected: isCurrent
                )
            }
            .buttonStyle(.borderless)
            .disabled(pending != nil)
            .tint(.primary)
            ConnectGroupMenu(group: group, sonos: sonos) { failure = $0 }
        }
    }

    private func select(_ device: OutputDevice) {
        guard pending == nil else { return }
        pending = device.id
        Task {
            if sonos.isActive { await sonos.stop() }
            let message = device == coordinator.currentOutput ? nil : await coordinator.move(to: device)
            pending = nil
            if let message { failure = message } else { onDone() }
        }
    }

    private func select(_ group: SonosGroup) {
        guard pending == nil, !sonos.isPlaying(on: group) else { return }
        pending = group.id
        Task {
            if coordinator.isRemoteOutput {
                if let message = await coordinator.move(to: .thisDevice) {
                    pending = nil
                    failure = message
                    return
                }
            }
            let message = await sonos.play(on: group)
            pending = nil
            if let message { failure = message }
        }
    }
}

private struct ConnectCurrentOutput: View {
    @ObservedObject var sonos: SonosOutputController
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @ScaledMetric(relativeTo: .title2) private var icon: CGFloat = 52
    @ScaledMetric(relativeTo: .body) private var artwork: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: icon, height: icon)
                    .background(Color.scAccent.gradient, in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                    if let quality {
                        Text(quality)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary, in: .capsule)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(["Playing on \(name)", quality].compactMap { $0 }.joined(separator: ", "))

            if let snapshot = coordinator.nowPlaying {
                HStack(spacing: 12) {
                    ConnectArtwork(url: snapshot.artworkURL.flatMap(URL.init(string:)), identity: snapshot.trackId ?? snapshot.displayTitle)
                        .frame(width: artwork, height: artwork)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(snapshot.displayArtist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            ConnectVolumeSlider()
        }
        .padding(.vertical, 6)
    }

    private var name: String {
        if let group = sonos.activeGroup { return group.displayName }
        return coordinator.currentOutput.isLocal ? "This \(DeviceClass.current.displayName)" : coordinator.currentOutput.name
    }

    private var symbol: String {
        if let group = sonos.activeGroup { return group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill" }
        return coordinator.currentOutput.isLocal ? DeviceClass.current.symbolName : coordinator.currentOutput.symbolName
    }

    private var quality: String? {
        if sonos.isActive { return "Sonos · \(sonos.qualityLabel)" }
        let output = coordinator.currentOutput
        return output.isLocal ? nil : (coordinator.availability(of: output)?.label ?? output.deviceClass.displayName)
    }
}

private struct ConnectVolumeSlider: View {
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @State private var dragLevel: Double?

    private var system: NowPlayingVolume { .shared }

    var body: some View {
        if coordinator.volumeRoute.isRemote {
            if let reported = coordinator.remoteVolume {
                slider(
                    Binding(get: { dragLevel ?? reported }, set: { value in
                        dragLevel = value
                        coordinator.setRemoteVolume(value)
                    })
                ) { editing in
                    if editing {
                        coordinator.beginRemoteVolumeChange()
                    } else {
                        coordinator.endRemoteVolumeChange()
                        dragLevel = nil
                    }
                }
            }
        } else {
            slider(
                Binding(get: { Double(system.level) }, set: { system.set(Float($0)) })
            ) { editing in
                if editing { system.begin() } else { system.end() }
            }
            .background { SystemVolumeHost().frame(width: 4, height: 4).accessibilityHidden(true) }
        }
    }

    private func slider(_ value: Binding<Double>, onEditingChanged: @escaping (Bool) -> Void) -> some View {
        Slider(
            value: value,
            in: 0...1,
            label: { Text("Volume") },
            minimumValueLabel: { Image(systemName: "speaker.fill").foregroundStyle(.secondary) },
            maximumValueLabel: { Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary) },
            onEditingChanged: onEditingChanged
        )
    }
}

private struct ConnectRowLabel: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    var isPending = false
    var isSelected = false
    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = 32

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(isSelected ? Color.scAccent : .primary)
                .frame(width: icon, height: icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isPending {
                ProgressView()
            } else if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.scAccent)
                    .fontWeight(.semibold)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ConnectGroupMenu: View {
    let group: SonosGroup
    @ObservedObject var sonos: SonosOutputController
    let onFailure: (String) -> Void

    var body: some View {
        Menu {
            let addable = sonos.rooms(addableTo: group)
            if !addable.isEmpty {
                Section("Add to Group") {
                    ForEach(addable) { room in
                        Button(room.roomName) { run { await sonos.add(room, to: group) } }
                    }
                }
            }
            if group.members.count > 1 {
                Section("Remove from Group") {
                    ForEach(group.members) { room in
                        Button(room.roomName) { run { await sonos.remove(room) } }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Group \(group.displayName)")
    }

    private func run(_ action: @escaping @MainActor () async -> String?) {
        Task { if let message = await action() { onFailure(message) } }
    }
}

private struct ConnectArtwork: View {
    let url: URL?
    let identity: String

    var body: some View {
        ArtworkImage(url: url) {
            SoundingArtworkView(identity: identity, subject: .track)
        }
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

@MainActor
final class ConnectRoutePicker {
    let view: AVRoutePickerView = {
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.prioritizesVideoDevices = false
        return picker
    }()

    func present() {
        for case let button as UIButton in view.subviews {
            button.sendActions(for: .touchUpInside)
            return
        }
    }
}

private struct ConnectRoutePickerHost: UIViewRepresentable {
    let picker: ConnectRoutePicker

    func makeUIView(context: Context) -> AVRoutePickerView { picker.view }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
