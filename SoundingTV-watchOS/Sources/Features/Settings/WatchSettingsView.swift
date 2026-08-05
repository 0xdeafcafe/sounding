import SwiftUI

struct WatchSettingsView: View {
    @EnvironmentObject private var link: WatchLinkClient
    @EnvironmentObject private var credentials: WatchCredentialSource
    @ObservedObject private var settings = SettingsStore.shared

    private var displayName: String {
        if let name = credentials.currentUser?.displayName ?? link.authState.displayName {
            return name
        }
        return credentials.isSignedIn ? "SoundCloud Account" : "No Account"
    }

    private var avatarURL: URL? {
        credentials.currentUser?.avatarURL ?? link.authState.avatarURL
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: WatchStyle.style.spaceTight) {
                    SCArtworkResolver(url: avatarURL, variant: .standard) { image in
                        if let image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Circle()
                                .fill(WatchStyle.style.bgOverlay)
                                .overlay {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(WatchStyle.style.textTertiary)
                                }
                        }
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName)
                            .font(WatchStyle.style.fontBodyEmphasis)
                            .foregroundStyle(WatchStyle.style.textPrimary)
                            .lineLimit(1)
                        Text(credentials.isSignedIn ? "Signed In" : "Signed Out")
                            .font(WatchStyle.style.fontCaption)
                            .foregroundStyle(WatchStyle.style.textSecondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)

                if credentials.isSignedIn {
                    Button(role: .destructive) {
                        credentials.signOut()
                    } label: {
                        Text("Sign Out")
                    }
                }
            } header: {
                WatchSectionHeader(title: "Account")
            }

            Section {
                WatchOutputOptionRow(
                    title: "iPhone",
                    systemImage: "iphone.gen3",
                    isSelected: link.nowPlaying.output == .phone
                ) {
                    link.selectOutput(.phone)
                }
                WatchOutputOptionRow(
                    title: "Apple TV",
                    systemImage: "appletv.fill",
                    isSelected: link.nowPlaying.output == .tv
                ) {
                    link.selectOutput(.tv)
                }
            } header: {
                WatchSectionHeader(title: "Output")
            }

            if !link.settings.items.isEmpty {
                Section {
                    ForEach(link.settings.items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title)
                                .font(WatchStyle.style.fontBody)
                                .foregroundStyle(WatchStyle.style.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: WatchStyle.style.spaceTight)
                            Text(item.value)
                                .font(WatchStyle.style.fontCaption)
                                .foregroundStyle(WatchStyle.style.textSecondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    WatchSectionHeader(title: "Playback")
                } footer: {
                    Text("Change these on iPhone.")
                        .font(WatchStyle.style.fontCaption)
                        .foregroundStyle(WatchStyle.style.textTertiary)
                }
            }

            if !settings.recentSearchQueries.isEmpty {
                Section {
                    Button(role: .destructive) {
                        settings.setRecentSearchQueries([])
                    } label: {
                        Label("Clear Recent Searches", systemImage: "trash")
                    }
                } header: {
                    WatchSectionHeader(title: "This Watch")
                }
            }

            Section {
                HStack {
                    Text("iPhone")
                        .font(WatchStyle.style.fontBody)
                        .foregroundStyle(WatchStyle.style.textPrimary)
                    Spacer()
                    Text(link.isReachable ? "Connected" : "Unreachable")
                        .font(WatchStyle.style.fontCaption)
                        .foregroundStyle(link.isReachable ? WatchStyle.style.success : WatchStyle.style.destructive)
                }

                HStack {
                    Text("Companion App")
                        .font(WatchStyle.style.fontBody)
                        .foregroundStyle(WatchStyle.style.textPrimary)
                    Spacer()
                    Text(link.isCompanionInstalled ? "Installed" : "Not Installed")
                        .font(WatchStyle.style.fontCaption)
                        .foregroundStyle(link.isCompanionInstalled ? WatchStyle.style.success : WatchStyle.style.textTertiary)
                }

                Button {
                    link.requestSnapshot()
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
            } header: {
                WatchSectionHeader(title: "Connection")
            }
        }
        .navigationTitle("Settings")
    }
}

private struct WatchOutputOptionRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: WatchStyle.style.spaceTight) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? WatchStyle.style.accent : WatchStyle.style.textSecondary)
                    .frame(width: 22)
                Text(title)
                    .font(WatchStyle.style.fontBodyEmphasis)
                    .foregroundStyle(WatchStyle.style.textPrimary)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(WatchStyle.style.accent)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
