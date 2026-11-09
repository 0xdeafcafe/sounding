import SwiftUI
import UIKit

struct HomeLightingSettingsView: View {
    @ObservedObject private var director = HomeLightingDirector.shared
    @ObservedObject private var settings = HomeLightingSettings.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch director.snapshot.access {
            case .notRequested:
                priming
            case .waiting:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .remoteFocusTarget()
            case .denied:
                denied
            case .ready:
                if let home = director.snapshot.home(id: settings.homeID) {
                    if home.lights.isEmpty {
                        noLights(in: home)
                    } else {
                        form(for: home)
                    }
                } else {
                    noHome
                }
            }
        }
        .onAppear {
            if settings.hasRequestedAccess { director.requestAccess() }
        }
    }

    // MARK: - States

    private var priming: some View {
        ContentUnavailableView {
            Label("Lights That Follow the Music", systemImage: "lightbulb.2")
        } description: {
            Text("Sounding can colour your lights from the artwork and set their brightness to the music. It only changes the lights you choose.")
        } actions: {
            Button("Continue") { director.requestAccess() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var denied: some View {
        ContentUnavailableView {
            Label("Home Access Is Off", systemImage: "house.slash")
        } description: {
            Text("To use your lights, turn on Home for Sounding in Settings.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noHome: some View {
        ContentUnavailableView(
            "No Home",
            systemImage: "house",
            description: Text("Set up a home in the Home app to use your lights here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .remoteFocusTarget()
    }

    private func noLights(in home: HomeInfo) -> some View {
        ContentUnavailableView(
            "No Lights",
            systemImage: "lightbulb.slash",
            description: Text("Add lights to \(home.name) in the Home app to use them here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .remoteFocusTarget()
    }

    // MARK: - Form

    private func form(for home: HomeInfo) -> some View {
        Form {
            Section {
                Picker("Intensity", selection: $settings.intensity) {
                    ForEach(LightingIntensity.allCases) { intensity in
                        Text(intensity.displayName).tag(intensity)
                    }
                }
                #if os(tvOS)
                .pickerStyle(.navigationLink)
                #else
                .pickerStyle(.inline)
                .labelsHidden()
                #endif
            } header: {
                #if os(tvOS)
                header("Lights")
                #else
                header("Intensity")
                #endif
            } footer: {
                footer(intensityFooter)
            }

            if director.snapshot.homes.count > 1 {
                Section {
                    Picker("Home", selection: homeSelection(default: home.id)) {
                        ForEach(director.snapshot.homes) { home in
                            Text(home.name).tag(home.id)
                        }
                    }
                    #if os(tvOS)
                    .pickerStyle(.navigationLink)
                    #endif
                }
            }

            ForEach(home.rooms) { room in
                Section {
                    Toggle("Whole Room", isOn: roomBinding(room))
                    ForEach(room.lights) { light in
                        Toggle(isOn: lightBinding(light)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(light.name)
                                if !light.capabilities.contains(.color) {
                                    Text("Brightness only")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(settings.isRoomSelected(room))
                    }
                } header: {
                    header(room.name)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var intensityFooter: String {
        if case .elsewhere(let name) = director.leadership, settings.intensity != .off {
            return "While \(name) is the Output, it sets the lights."
        }
        switch settings.intensity {
        case .subtle: return "Colours come from the artwork and brightness follows the music, phrase by phrase."
        case .party: return "Brighter, with a pulse on each drop."
        case .off: return "Your lights are left as they are."
        }
    }

    @ViewBuilder
    private func header(_ title: String) -> some View {
        #if os(tvOS)
        SettingsSectionTitle(title)
        #else
        Text(title)
        #endif
    }

    @ViewBuilder
    private func footer(_ text: String) -> some View {
        #if os(tvOS)
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
        #else
        Text(text)
        #endif
    }

    private func homeSelection(default id: String) -> Binding<String> {
        Binding(
            get: { settings.homeID ?? id },
            set: { settings.homeID = $0 }
        )
    }

    private func roomBinding(_ room: HomeRoomInfo) -> Binding<Bool> {
        Binding(
            get: { settings.isRoomSelected(room) },
            set: { settings.setRoom(room, selected: $0) }
        )
    }

    private func lightBinding(_ light: HomeLightInfo) -> Binding<Bool> {
        Binding(
            get: { settings.isLightSelected(light) },
            set: { settings.setLight(light, selected: $0) }
        )
    }
}

extension HomeLightingDirector {
    var summary: String {
        guard settings.hasRequestedAccess, snapshot.access == .ready, !selectedLights.isEmpty else { return "Off" }
        return settings.intensity.displayName
    }
}
