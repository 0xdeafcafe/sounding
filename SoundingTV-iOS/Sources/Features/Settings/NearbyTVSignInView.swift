import SwiftUI
import UIKit

enum NearbyTVDebugStory {
    static let forcedPhase: NearbyTVSignIn.Phase? = {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_NEARBY_STORY"] {
        case "priming":   return .needsPermission
        case "denied":    return .permissionDenied
        case "listening": return .listening
        case "checking":  return .checking
        case "found":     return .found(name: "Living Room", kind: .tv)
        case "signingIn": return .signingIn(name: "Living Room")
        case "failed":    return .failed("Couldn't finish signing in. Make sure the Apple TV is still on its sign-in screen.")
        default:          return nil
        }
        #else
        return nil
        #endif
    }()
}

struct NearbyTVSignInView: View {
    @ObservedObject var model: NearbyTVSignIn
    @ObservedObject var nearby: LinkOfferBrowser
    let onUseQRCode: () -> Void
    let onCancel: () -> Void
    let onLinked: (NearbyTVSignIn.Linked) -> Void
    var onUseCode: ((LinkOfferBrowser.Offer) -> Void)? = nil

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsGuidance = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .smooth, value: model.phase)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: if model.phase == .idle { model.start() }
                case .background: model.stop()
                default: break
                }
            }
            .onChange(of: model.linked) { _, linked in
                if let linked { onLinked(linked) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle where model.invitedName != nil, .listening where model.invitedName != nil, .checking where model.invitedName != nil:
            ContentUnavailableView {
                Label {
                    Text("Connecting to \(model.invitedName ?? "Apple TV")…")
                } icon: {
                    Image(systemName: DeviceClass.tv.symbolName)
                        .symbolEffect(.pulse, isActive: !reduceMotion)
                }
            } description: {
                Text("Keep this \(DeviceClass.current.displayName) near the Apple TV.")
            } actions: {
                if let offer = model.invitedOffer, let onUseCode {
                    Button("Use a Code Instead") { onUseCode(offer) }
                }
                qrButton
            }

        case .idle, .listening:
            listening

        case .needsPermission:
            ContentUnavailableView {
                Label("Listen for Your Apple TV", systemImage: "ear")
            } description: {
                Text("Your Apple TV plays a short chime. Sounding listens for it to find the TV, only while this screen is open. Nothing is recorded or sent anywhere.")
            } actions: {
                Button("Continue") { model.continueAfterPriming() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                qrButton
            }

        case .permissionDenied:
            ContentUnavailableView {
                Label("Microphone Access Is Off", systemImage: "mic.slash")
            } description: {
                Text("To find your Apple TV by its chime, turn on Microphone for Sounding in Settings.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                qrButton
            }

        case .checking:
            progress("Connecting…")

        case .found(let name, let kind):
            ContentUnavailableView {
                Label(name, systemImage: kind.symbolName)
            } description: {
                Text("Sign in to Sounding on this \(kind.displayName)?")
            } actions: {
                Button("Sign In") { model.signIn() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Not Now", action: onCancel)
            }

        case .signingIn(let name):
            progress("Signing in \(name)…")

        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Sign In", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retry() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                qrButton
            }
        }
    }

    private var listening: some View {
        List {
            Section {
                NearbySearchHeader(guidance: guidance)
                    .listRowBackground(Color.clear)
                    .animation(reduceMotion ? nil : .smooth, value: guidance)
            }

            if model.localNetworkDenied {
                Section {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } footer: {
                    Text("Turn on Local Network for Sounding in Settings to see Apple TVs on your network.")
                }
            }

            if let onUseCode, !offers.isEmpty {
                Section("Nearby") {
                    ForEach(offers, id: \.sessionIdPrefix) { offer in
                        NearbyDeviceRow(offer: offer) { onUseCode(offer) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaBar(edge: .bottom) {
            qrButton
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? nil : .smooth, value: offers.map(\.sessionIdPrefix))
        .task {
            try? await Task.sleep(for: .seconds(4))
            showsGuidance = true
        }
    }

    private var offers: [LinkOfferBrowser.Offer] {
        nearby.distinctOffers.filter { $0.kind == .tv }
    }

    private var guidance: String? {
        if model.isHearingNothing {
            return offers.isEmpty
                ? "Open Sounding on your Apple TV, choose Add a Device and turn the volume up."
                : "Choose your Apple TV below to link it with a code."
        }
        guard showsGuidance, offers.isEmpty, !model.localNetworkDenied else { return nil }
        return "Open Sounding on your Apple TV and keep this \(DeviceClass.current.displayName) nearby."
    }

    private var qrButton: some View {
        Button("Use QR Code Instead", action: onUseQRCode)
    }

    private func progress(_ title: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
