#if os(macOS) || os(iOS)
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct DJControllersSection: View {
    @ObservedObject var hub: DJControllerHub

    var body: some View {
        SwiftUI.Section {
            if let error = hub.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if hub.controllers.isEmpty {
                Text("No controllers connected")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hub.controllers) { controller in
                    LabeledContent {
                        Text(controller.profileName ?? "Not Supported")
                    } label: {
                        Text(controller.name)
                        if let detail = detail(for: controller) {
                            Text(detail)
                        }
                    }
                }
            }
        } header: {
            Text("Controllers")
        } footer: {
            Text("Supported controllers work in Decks as soon as you plug them in.")
        }
    }

    private func detail(for controller: ConnectedController) -> String? {
        switch (controller.isNetwork, controller.hasLights) {
        case (true, true): "Network · Lights"
        case (true, false): "Network"
        case (false, true): "Lights"
        case (false, false): nil
        }
    }
}

struct NetworkMIDISection: View {
    @ObservedObject var hub: DJControllerHub
    @ObservedObject private var network = NetworkMIDI.shared

    var body: some View {
        if NetworkMIDI.managesSession {
            sessionSection
        } else {
            setupSection
        }
    }

    private var sessionSection: some View {
        SwiftUI.Section {
            Toggle("Network MIDI", isOn: Binding(
                get: { network.isEnabled },
                set: { network.setEnabled($0) }
            ))
            if network.isEnabled {
                if network.hosts.isEmpty {
                    LabeledContent("Looking for Network MIDI") {
                        ProgressView()
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(network.hosts) { host in
                        LabeledContent(host.name) {
                            if host.isConnected {
                                Button("Disconnect") { network.disconnect(host) }
                            } else {
                                Button("Connect") { network.connect(host) }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Network MIDI")
        } footer: {
            Text("Wireless controllers and computers sharing MIDI on your network can connect.")
        }
    }

    private var setupSection: some View {
        SwiftUI.Section {
            let sessions = hub.controllers.filter(\.isNetwork)
            if sessions.isEmpty {
                Text("No network sessions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { session in
                    LabeledContent(session.name, value: session.profileName ?? "Not Supported")
                }
            }
            #if os(macOS)
            Button("Open Audio MIDI Setup") { Self.openAudioMIDISetup() }
            #endif
        } header: {
            Text("Network MIDI")
        } footer: {
            Text("Turn on a session in Audio MIDI Setup, under MIDI Network Setup. Name it after a supported controller to use it in Decks.")
        }
    }

    #if os(macOS)
    private static func openAudioMIDISetup() {
        let workspace = NSWorkspace.shared
        let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.audio.AudioMIDISetup")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
        workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
    #endif
}

struct DJControllersSheet: View {
    @ObservedObject var hub = DJControllerHub.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DJControllersSection(hub: hub)
                NetworkMIDISection(hub: hub)
            }
            .formStyle(.grouped)
            .navigationTitle("Controllers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
