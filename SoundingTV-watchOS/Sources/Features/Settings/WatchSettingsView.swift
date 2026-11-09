import SwiftUI

struct WatchSettingsView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @EnvironmentObject private var credentials: WatchCredentialSource
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var displayName: String {
        if let name = credentials.currentUser?.displayName ?? link.authState.displayName {
            return name
        }
        return credentials.isSignedIn ? "SoundCloud" : "Not Signed In"
    }

    private var avatarURL: URL? {
        credentials.currentUser?.avatarURL ?? link.authState.avatarURL
    }

    private var outputSelection: Binding<String> {
        Binding(
            get: { link.nowPlaying.outputOptions.first(where: link.nowPlaying.isSelected)?.id ?? WatchOutputOption.thisPhoneID },
            set: { id in
                guard let option = link.nowPlaying.outputOptions.first(where: { $0.id == id }) else { return }
                link.selectOutput(option)
            }
        )
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    WatchArtwork(url: avatarURL, size: 36, corner: 18, identity: displayName)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName)
                            .font(.body)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        Text(credentials.isSignedIn ? "Signed In" : "Signed Out")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                if credentials.isSignedIn {
                    Button("Sign Out", role: .destructive) {
                        credentials.signOut()
                    }
                }
            } header: {
                Text("Account")
            }

            Section {
                Picker("Output", selection: outputSelection) {
                    ForEach(link.nowPlaying.outputOptions) { option in
                        Label(option.name, systemImage: option.deviceClass.symbolName)
                            .tag(option.id)
                    }
                }
                .pickerStyle(.navigationLink)
            }

            Section {
                NavigationLink {
                    WatchDownloadsView()
                } label: {
                    LabeledContent("Storage") {
                        WatchOfflineStorageLine()
                    }
                }
            } header: {
                Text("On This Watch")
            } footer: {
                Text("Change the limit on iPhone.")
            }

            if !link.settings.items.isEmpty {
                Section {
                    ForEach(link.settings.items) { item in
                        LabeledContent(item.title, value: item.value)
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Change on iPhone.")
                }
            }

            if !settings.recentSearchQueries.isEmpty {
                Section {
                    Button("Clear Recent Searches", role: .destructive) {
                        settings.setRecentSearchQueries([])
                    }
                }
            }

            Section {
                LabeledContent("iPhone", value: link.isReachable ? "Connected" : "Not Reachable")
                LabeledContent("Sounding on iPhone", value: link.isCompanionInstalled ? "Installed" : "Not Installed")
                Button {
                    link.requestSnapshot()
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityHint("Requests the latest state from iPhone")
            } header: {
                Text("Connection")
            }
        }
        .navigationTitle("Settings")
    }
}
