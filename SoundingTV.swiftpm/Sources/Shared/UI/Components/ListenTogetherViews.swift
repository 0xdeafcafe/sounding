import GroupActivities
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ListenTogetherIndicator: View {
    @ObservedObject private var listenTogether = ListenTogether.shared

    var body: some View {
        if listenTogether.isActive {
            Label {
                Text("Listening Together · \(listenTogether.participantCount)")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "shareplay")
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityText(count: listenTogether.participantCount))
        }
    }

    static func accessibilityText(count: Int) -> String {
        count == 1 ? "Listening together, 1 person" : "Listening together, \(count) people"
    }
}

struct ListenTogetherMenuItems: View {
    @ObservedObject private var listenTogether = ListenTogether.shared
    #if os(iOS)
    @State private var isShowingSharingController = false
    #endif

    var body: some View {
        if listenTogether.isActive {
            Button(role: .destructive) {
                listenTogether.leave()
            } label: {
                Label("Leave SharePlay", systemImage: "shareplay.slash")
            }
        } else if listenTogether.isEligible {
            Button {
                Task { await listenTogether.start() }
            } label: {
                Label("SharePlay", systemImage: "shareplay")
            }
        } else {
            #if os(iOS)
            Button {
                ListenTogetherSharingPresenter.present()
            } label: {
                Label("SharePlay", systemImage: "shareplay")
            }
            #endif
        }
    }
}

#if !os(tvOS)
struct ListenTogetherShareLink<Label: View>: View {
    let url: URL
    let trackID: String?
    let title: String
    @ViewBuilder let label: () -> Label
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        if settings.shareSoundingLinks,
           let item = ListenTogether.shared.shareItem(),
           item.activity.initial.trackID == trackID {
            ShareLink(item: item, preview: SharePreview(title), label: label)
        } else {
            ShareLink(item: url, preview: SharePreview(title), label: label)
        }
    }
}
#endif

#if os(iOS)
@MainActor
enum ListenTogetherSharingPresenter {
    static func present() {
        guard let activity = ListenTogether.shared.makeActivity(),
              let controller = try? GroupActivitySharingController(activity),
              let presenter = topViewController() else { return }
        presenter.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
#endif

struct ListenTogetherModifier: ViewModifier {
    let onSignIn: () -> Void
    @ObservedObject private var listenTogether = ListenTogether.shared

    func body(content: Content) -> some View {
        content
            .task { listenTogether.startObserving() }
            .alert("Sign In to Listen Together", isPresented: $listenTogether.isShowingSignInPrompt) {
                Button("Sign In", action: onSignIn)
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("Everyone in SharePlay listens with their own SoundCloud account.")
            }
    }
}

extension View {
    func listenTogether(onSignIn: @escaping () -> Void = {}) -> some View {
        modifier(ListenTogetherModifier(onSignIn: onSignIn))
    }
}
