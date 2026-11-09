import SwiftUI

struct ScoutSettingsView: View {
    @ObservedObject private var scout = ScoutMonitor.shared
    @ObservedObject private var notifications = ScoutNotifications.shared

    var body: some View {
        Form {
            Section {
                Toggle("Scout", isOn: Binding(
                    get: { scout.isEnabled },
                    set: { scout.setMasterEnabled($0) }
                ))
            } footer: {
                Text("Get a notification when an artist you scout posts a new track or set, or plays a set someone else posts.")
            }

            if scout.isEnabled, notifications.status == .denied {
                Section {
                    Text("Notifications are off for Sounding.")
                    #if os(iOS)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    #endif
                }
            }

            if !scout.artists.isEmpty {
                Section("Artists") {
                    ForEach(scout.artists) { artist in
                        Toggle(artist.name, isOn: Binding(
                            get: { artist.isEnabled },
                            set: { scout.setEnabled($0, artistID: artist.id) }
                        ))
                        .disabled(!scout.isEnabled)
                        .contextMenu {
                            Button("Stop Scouting", systemImage: "bell.slash", role: .destructive) {
                                scout.remove(artistIDs: [artist.id])
                            }
                        }
                    }
                    .onDelete { offsets in
                        scout.remove(artistIDs: offsets.map { scout.artists[$0].id })
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if scout.artists.isEmpty {
                ContentUnavailableView {
                    Label("No Artists", systemImage: "binoculars")
                } description: {
                    Text("Choose Scout on an artist’s page or in Following.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .padding(.top, 120)
            }
        }
        .navigationTitle("Scout")
        .task { await notifications.refresh() }
    }
}

struct ScoutPrimingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ContentUnavailableView {
            Label("Know When They Post", systemImage: "binoculars")
        } description: {
            Text("Sounding sends a notification when an artist you scout posts a new track or set. Tap it to play.")
        } actions: {
            Button("Continue") {
                Task { await ScoutNotifications.shared.requestAuthorization() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Not Now") {
                ScoutMonitor.shared.isPriming = false
                dismiss()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 320)
        #endif
    }
}

struct ScoutToggleButton: View {
    let user: User
    var isFollowed: Bool?
    @ObservedObject private var scout = ScoutMonitor.shared

    var body: some View {
        let scouting = scout.isScouting(user.id)
        Button {
            scout.toggle(user, isFollowed: isFollowed)
        } label: {
            Label(scouting ? "Scouting" : "Scout", systemImage: scouting ? "binoculars.fill" : "binoculars")
        }
        .accessibilityLabel(scouting ? "Stop scouting \(user.displayName)" : "Scout \(user.displayName)")
        .accessibilityValue(scouting ? "On" : "Off")
        .help(scouting ? "Stop getting notifications when \(user.displayName) posts" : "Get a notification when \(user.displayName) posts")
    }
}

struct ScoutPrimingHost: ViewModifier {
    let isActive: Bool
    @ObservedObject private var scout = ScoutMonitor.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: isActive ? $scout.isPriming : .constant(false)) { ScoutPrimingView() }
    }
}

extension View {
    func scoutPriming(isActive: Bool = true) -> some View { modifier(ScoutPrimingHost(isActive: isActive)) }
}
