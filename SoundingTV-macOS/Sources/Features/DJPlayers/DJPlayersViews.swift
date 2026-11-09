import SwiftUI

struct DJPlayersSettingsTab: View {
    @ObservedObject private var controller = DJPlayersController.shared

    var body: some View {
        Group {
            if let blocking = DJPlayersBlockingState(controller.state) {
                DJPlayersBlockingView(state: blocking)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        .onAppear { controller.refreshInterfaces() }
    }

    private var form: some View {
        Form {
            if controller.state == .connected {
                Section("Players") {
                    ForEach(controller.visiblePlayers) { player in
                        DJPlayerRow(player: player)
                    }
                }
            }

            Section("Network") {
                if controller.state == .connected {
                    LabeledContent("Network", value: controller.selectedInterface.map(DJPlayersFormat.interfaceLabel) ?? "")
                    LabeledContent("This Mac", value: DJPlayersFormat.identityLabel(controller))
                    Button("Disconnect") { controller.disconnect() }
                } else {
                    Picker("Network", selection: $controller.selectedInterfaceName) {
                        ForEach(controller.interfaces) { interface in
                            Text(DJPlayersFormat.interfaceLabel(interface)).tag(Optional(interface.bsdName))
                        }
                    }
                    .disabled(controller.interfaces.isEmpty)
                    Button("Connect") { controller.connect() }
                        .keyboardShortcut(.defaultAction)
                }
            }

            Section {
                Toggle("Use as Virtual Deck", isOn: $controller.usesVirtualDeck)
                Picker("Player Number", selection: $controller.virtualDeckNumber) {
                    Text("Automatic").tag(0)
                    ForEach(controller.availableVirtualNumbers(), id: \.self) { number in
                        Text("Player \(number)").tag(number)
                    }
                }
                .disabled(!controller.usesVirtualDeck)
                if controller.usesVirtualDeck, controller.state == .connected, controller.ownNumber != nil {
                    LabeledContent("Tempo Master") {
                        if controller.isVirtualDeckMaster {
                            Text("This Mac")
                        } else {
                            Button("Become Master") { controller.becomeMaster() }
                        }
                    }
                }
            } header: {
                Text("Virtual Deck")
            } footer: {
                Text("Players can sync to whatever is playing in Decks. Quit rekordbox first.")
            }

            Section("Setlists") {
                Toggle("Record Setlists", isOn: $controller.recordsSetlists)
                Picker("Count a Track After", selection: $controller.setlistBars) {
                    ForEach(DJPlayersController.setlistBarChoices, id: \.self) { bars in
                        Text("\(bars) Bars").tag(bars)
                    }
                }
                .disabled(!controller.recordsSetlists)
                if let title = controller.recordingTitle {
                    LabeledContent(title, value: DJPlayersFormat.trackCount(controller.recordedCount))
                }
            }

            Section {
            } footer: {
                Text("Uses Pro DJ Link. Not affiliated with AlphaTheta.")
                    .font(.footnote)
                    .foregroundStyle(MacSecondaryStyle())
            }
        }
        .formStyle(.grouped)
    }
}

struct DJPlayersDecksPanel: View {
    @ObservedObject private var controller = DJPlayersController.shared
    let openSettings: () -> Void

    var body: some View {
        Group {
            if let blocking = DJPlayersBlockingState(controller.state) {
                DJPlayersBlockingView(state: blocking, compact: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.state == .disconnected {
                ContentUnavailableView {
                    Label("DJ Players", systemImage: "opticaldiscdrive")
                } description: {
                    Text("See what your players are doing and keep Decks in time with them.")
                } actions: {
                    Button("Connect") { controller.connect() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button("Settings…", action: openSettings)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                connected
            }
        }
        .frame(width: 420, height: 460)
    }

    private var connected: some View {
        Form {
            Section("Players") {
                ForEach(controller.visiblePlayers) { player in
                    DJPlayerRow(player: player, compact: true)
                }
            }
            Section {
                Toggle(isOn: $controller.syncsDecks) {
                    Text("Sync to DJ Players")
                    if let tempo = controller.tempo {
                        Text("Player \(tempo.masterNumber) · \(DJPlayersFormat.bpm(tempo.bpm))")
                    } else {
                        Text("No tempo master")
                    }
                }
                Toggle("Use as Virtual Deck", isOn: $controller.usesVirtualDeck)
                if controller.usesVirtualDeck, controller.ownNumber != nil, !controller.isVirtualDeckMaster {
                    Button("Become Master") { controller.becomeMaster() }
                }
            }
            Section {
                Button("Settings…", action: openSettings)
                Button("Disconnect") { controller.disconnect() }
            }
        }
        .formStyle(.grouped)
    }
}

struct DJPlayersToolbarButton: View {
    @ObservedObject private var controller = DJPlayersController.shared
    @Environment(\.openSettings) private var openSettings
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("DJ Players", systemImage: controller.state == .connected ? "opticaldiscdrive.fill" : "opticaldiscdrive")
        }
        .help("DJ Players")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DJPlayersDecksPanel {
                isPresented = false
                MacSettingsNavigation.shared.selection = .djPlayers
                openSettings()
            }
        }
    }
}

struct DJPlayerRow: View {
    @ObservedObject private var controller = DJPlayersController.shared
    let player: DJPlayer
    var compact = false

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                if let bpm = player.status?.effectiveBPM {
                    Text(DJPlayersFormat.bpm(bpm))
                        .monospacedDigit()
                }
                if let status = player.status, player.isPlayer, status.track != nil {
                    Text(DJPlayersFormat.pitch(status.pitchPercent))
                        .monospacedDigit()
                        .foregroundStyle(MacSecondaryStyle())
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(player.name)
                    if player.status?.isMaster == true {
                        Text("Master")
                            .foregroundStyle(MacSecondaryStyle())
                    }
                    if player.status?.isOnAir == true {
                        Text("On Air")
                            .foregroundStyle(.red)
                    }
                }
                Text(DJPlayersFormat.detail(for: player, controller: controller, compact: compact))
                    .foregroundStyle(MacSecondaryStyle())
                    .lineLimit(compact ? 1 : 2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum DJPlayersBlockingState: Equatable {
    case priming
    case looking
    case noPlayers
    case notAllowed
    case rekordboxRunning
    case portsInUse
    case noNetwork
    case numberTaken(Int)

    init?(_ state: DJPlayersConnectionState) {
        switch state {
        case .priming: self = .priming
        case .looking: self = .looking
        case .noPlayers: self = .noPlayers
        case .notAllowed: self = .notAllowed
        case .rekordboxRunning: self = .rekordboxRunning
        case .portsInUse: self = .portsInUse
        case .noNetwork: self = .noNetwork
        case .numberTaken(let number): self = .numberTaken(number)
        case .disconnected, .connected: return nil
        }
    }
}

struct DJPlayersBlockingView: View {
    @ObservedObject private var controller = DJPlayersController.shared
    let state: DJPlayersBlockingState
    var compact = false

    var body: some View {
        switch state {
        case .priming:
            ContentUnavailableView {
                Label("Find Your DJ Players", systemImage: "network")
            } description: {
                Text("Sounding talks to players on the network you choose, only while DJ Players is connected. Your Mac asks for Local Network access next.")
            } actions: {
                Button("Continue") { controller.continueAfterPriming() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Not Now") { controller.cancelPriming() }
            }

        case .looking:
            ProgressView("Looking for players…")
                .controlSize(.large)

        case .noPlayers:
            ContentUnavailableView {
                Label("No Players Found", systemImage: "magnifyingglass")
            } description: {
                Text("Check that your players are on and connected to \(controller.selectedInterface?.displayName ?? "this network").")
            } actions: {
                Button("Disconnect") { controller.disconnect() }
            }

        case .notAllowed:
            ContentUnavailableView {
                Label("Local Network Is Off", systemImage: "network.slash")
            } description: {
                Text("To see your players, turn on Local Network for Sounding in System Settings.")
            } actions: {
                Button("Open System Settings") { controller.openLocalNetworkSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Try Again") { controller.retry() }
            }

        case .rekordboxRunning:
            ContentUnavailableView {
                Label("Quit rekordbox to Use DJ Players", systemImage: "xmark.circle")
            } description: {
                Text("rekordbox and Sounding can't both talk to your players at once.")
            } actions: {
                Button("Try Again") { controller.retry() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { controller.disconnect() }
            }

        case .portsInUse:
            ContentUnavailableView {
                Label("Another App Is Using Your Players", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Quit other DJ software on this Mac, then try again.")
            } actions: {
                Button("Try Again") { controller.retry() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { controller.disconnect() }
            }

        case .noNetwork:
            ContentUnavailableView {
                Label("Connect to Your Players", systemImage: "cable.connector")
            } description: {
                Text("Plug this Mac into the same network as your players. A USB-C Ethernet adapter works.")
            } actions: {
                Button("Cancel") { controller.disconnect() }
            }

        case .numberTaken(let number):
            ContentUnavailableView {
                Label("Player \(number) Is Taken", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Another player is already using that number.")
            } actions: {
                Button("Choose Automatically") {
                    controller.virtualDeckNumber = 0
                    controller.retry()
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { controller.disconnect() }
            }
        }
    }
}

enum DJPlayersFormat {
    static func bpm(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2)))) BPM"
    }

    static func pitch(_ percent: Double) -> String {
        let rounded = (percent * 100).rounded() / 100
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "−" : "")
        return "\(sign)\(abs(rounded).formatted(.number.precision(.fractionLength(2))))%"
    }

    static func clock(millis: Int) -> String {
        let seconds = max(0, millis / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func trackCount(_ count: Int) -> String {
        count == 1 ? "1 track" : "\(count) tracks"
    }

    static func interfaceLabel(_ interface: DJLinkInterface) -> String {
        "\(interface.displayName) (\(interface.ip))"
    }

    @MainActor
    static func identityLabel(_ controller: DJPlayersController) -> String {
        if controller.isClaimingNumber { return "Joining…" }
        guard let number = controller.ownNumber else { return "Listening" }
        return controller.usesVirtualDeck ? "Player \(number)" : "Listening"
    }

    @MainActor
    static func detail(for player: DJPlayer, controller: DJPlayersController, compact: Bool) -> String {
        if player.isMixer { return "Mixer" }
        if player.isComputer { return "Computer" }
        var parts = ["Player \(player.number)"]
        guard let status = player.status else { return parts.joined(separator: " · ") }
        parts.append(status.activity.displayName)
        if let track = status.track {
            parts.append(controller.title(for: track))
            if !compact {
                if let playhead = status.playheadMillis {
                    var position = clock(millis: playhead)
                    if let length = status.trackLengthSeconds, length > 0 { position += " of \(clock(millis: length * 1000))" }
                    parts.append(position)
                } else if let beat = status.beatNumber, beat > 0 {
                    parts.append("Beat \(beat)")
                }
            }
        }
        return parts.joined(separator: " · ")
    }
}
