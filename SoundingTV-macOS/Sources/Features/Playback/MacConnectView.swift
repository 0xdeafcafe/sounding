import AppKit
import SwiftUI

struct MacConnectButton: View {
    @ObservedObject var router: OutputRouter
    @ObservedObject private var sonos = SonosOutputController.shared
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Play On", systemImage: symbol)
        }
        .foregroundStyle(isElsewhere ? Color.scAccent : Color.primary)
        .help(helpText)
        .accessibilityLabel("Play On")
        .accessibilityValue(sonos.activeGroup?.displayName ?? (router.isRemote ? router.current.name : "This Mac"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            MacConnectView(router: router, onDone: { isPresented = false })
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_OPEN_CONNECT"] == "1" {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    isPresented = true
                }
            }
            #endif
        }
    }

    private var isElsewhere: Bool { router.isRemote || sonos.isActive }

    private var symbol: String {
        if let group = sonos.activeGroup { return group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill" }
        return router.isRemote ? router.current.symbolName : "airplay.audio"
    }

    private var helpText: String {
        if let group = sonos.activeGroup { return "Playing on \(group.displayName)" }
        return router.isRemote ? "Playing on \(router.current.name)" : "Play On"
    }
}

struct MacConnectView: View {
    @ObservedObject var router: OutputRouter
    let onDone: () -> Void

    @ObservedObject private var sonos = SonosOutputController.shared
    @Environment(\.openSettings) private var openSettings
    @State private var pending: String?
    @State private var failure: String?
    @StateObject private var linking = PlayOnNearbyLinking()

    var body: some View {
        Form {
            Section {
                MacConnectCurrentOutput(router: router, sonos: sonos)
            } footer: {
                if sonos.isActive {
                    Text("Keep this Mac awake and on the same Wi-Fi while it plays on Sonos.")
                } else if let notice = router.notice {
                    Text(notice)
                }
            }

            Section {
                ForEach(router.devices.filter { !isCurrent($0) }) { device in
                    deviceRow(device)
                }
                .transaction { $0.animation = nil }
                if router.linkedDevice == nil, linking.rows.isEmpty {
                    Button("Add Apple TV…") {
                        onDone()
                        MacSettingsNavigation.shared.selection = .devices
                        openSettings()
                    }
                }
            }

            if !linking.rows.isEmpty {
                Section("Nearby") {
                    ForEach(linking.rows) { row in
                        Button {
                            linking.select(row)
                        } label: {
                            PlayOnNearbyRowLabel(row: row)
                        }
                        .buttonStyle(.plain)
                        .disabled(pending != nil || router.isMoving || !linking.isEnabled(row))
                        .help(rowHelp(row))
                    }
                    if let handshake = linking.comparison {
                        MacPlayOnLinkCode(handshake: handshake) { linking.cancelComparison() }
                    }
                }
                .transaction { $0.animation = nil }
            }

            if !sonos.groups.isEmpty {
                Section("Sonos") {
                    ForEach(sonos.groups.sorted { sonos.isPlaying(on: $0) && !sonos.isPlaying(on: $1) }) { group in
                        sonosRow(group)
                    }
                }
            }

            Section {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?output") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Bluetooth & AirPlay…", systemImage: "airplay.audio")
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 540)
        .modifier(PlayOnOtherAccountConfirmation(linking: linking))
        .onAppear {
            sonos.startDiscovery()
            linking.attach(browser: MacTVLinking.shared.nearby, router: router)
        }
        .onDisappear {
            sonos.stopDiscovery()
            linking.closed()
        }
        .alert("Couldn’t Change Output", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func rowHelp(_ row: PlayOnNearbyLinking.Row) -> String {
        if case .failed(let message) = row.state { return message }
        return "Link \(row.name)"
    }

    private func isCurrent(_ device: OutputDevice) -> Bool {
        !sonos.isActive && device == router.current
    }

    private func deviceRow(_ device: OutputDevice) -> some View {
        let availability = router.availability(of: device) ?? .notResponding
        let reachable = device.isLocal || availability.isSelectable
        return Button {
            select(device)
        } label: {
            MacConnectRow(
                title: device.isLocal ? "This Mac" : device.name,
                subtitle: device.isLocal ? nil : (availability.label ?? router.accountSubtitle(for: device) ?? device.deviceClass.displayName),
                systemImage: device.symbolName,
                isPending: pending == device.id
            )
        }
        .buttonStyle(.plain)
        .disabled(pending != nil || router.isMoving || (!device.isLocal && !reachable))
    }

    private func sonosRow(_ group: SonosGroup) -> some View {
        let isCurrent = sonos.isPlaying(on: group)
        return HStack {
            Button {
                select(group)
            } label: {
                MacConnectRow(
                    title: group.displayName,
                    subtitle: isCurrent ? "Playing" : nil,
                    systemImage: group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill",
                    isPending: pending == group.id,
                    isSelected: isCurrent
                )
            }
            .buttonStyle(.plain)
            .disabled(pending != nil)
            MacConnectGroupMenu(group: group, sonos: sonos) { failure = $0 }
        }
    }

    private func select(_ device: OutputDevice) {
        guard pending == nil else { return }
        pending = device.id
        Task {
            if sonos.isActive { await sonos.stop() }
            let message = device == router.current ? nil : await router.move(to: device)
            pending = nil
            if let message { failure = message }
        }
    }

    private func select(_ group: SonosGroup) {
        guard pending == nil, !sonos.isPlaying(on: group) else { return }
        pending = group.id
        Task {
            if router.isRemote, let message = await router.move(to: .thisDevice) {
                pending = nil
                failure = message
                return
            }
            let message = await sonos.play(on: group)
            pending = nil
            if let message { failure = message }
        }
    }
}

private struct MacConnectCurrentOutput: View {
    @ObservedObject var router: OutputRouter
    @ObservedObject var sonos: SonosOutputController

    private var nowPlaying: MacNowPlayingModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.scAccent.gradient, in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                    if let quality {
                        Text(quality)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.fill.tertiary, in: .capsule)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if let track = nowPlaying.track {
                HStack(spacing: 10) {
                    Group {
                        if let artwork = nowPlaying.artwork {
                            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            SoundingArtworkView(identity: track.id, subject: .track)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(.rect(cornerRadius: 5))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(track.user.username).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            MacVolumeSlider(showsEndCaps: true)
        }
        .padding(.vertical, 4)
    }

    private var name: String {
        if let group = sonos.activeGroup { return group.displayName }
        return router.isRemote ? router.current.name : "This Mac"
    }

    private var symbol: String {
        if let group = sonos.activeGroup { return group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill" }
        return router.current.symbolName
    }

    private var quality: String? {
        if sonos.isActive { return "Sonos · \(sonos.qualityLabel)" }
        guard router.isRemote else { return nil }
        return router.availability(of: router.current)?.label ?? router.current.deviceClass.displayName
    }
}

private struct MacPlayOnLinkCode: View {
    @ObservedObject var handshake: LinkConfirmationHandshake
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(handshake.instruction)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if case .awaitingComparison(let code) = handshake.state {
                Text(LinkConfirmationHandshake.codeGroups(code).joined(separator: "  "))
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .accessibilityLabel("Code \(LinkConfirmationHandshake.codeGroups(code).joined(separator: ", "))")
                HStack {
                    Button("It Doesn't Match", role: .destructive) { handshake.decline() }
                    Button("It Matches") { handshake.confirm() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

private struct MacConnectRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    var isPending = false
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(isSelected ? Color.scAccent : .primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isPending {
                ProgressView().controlSize(.small)
            } else if isSelected {
                Image(systemName: "checkmark").foregroundStyle(Color.scAccent)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MacConnectGroupMenu: View {
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
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Group \(group.displayName)")
    }

    private func run(_ action: @escaping @MainActor () async -> String?) {
        Task { if let message = await action() { onFailure(message) } }
    }
}
