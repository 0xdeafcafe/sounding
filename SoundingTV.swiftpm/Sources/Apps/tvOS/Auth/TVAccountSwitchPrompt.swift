import SwiftUI

struct TVAccountSwitchPrompt: ViewModifier {
    @ObservedObject private var server = CompanionServer.shared

    func body(content: Content) -> some View {
        content
            .alert(
                server.switchRequest.map { TVAccountCopy.tvSwitchTitle(mine: $0.account) } ?? "",
                isPresented: Binding(
                    get: { server.switchRequest != nil },
                    set: { if !$0, server.switchRequest != nil { server.answerSwitch(accept: false) } }
                ),
                presenting: server.switchRequest
            ) { _ in
                Button("Switch") { server.answerSwitch(accept: true) }
                Button(TVAccountCopy.tvKeep(server.localAccount), role: .cancel) { server.answerSwitch(accept: false) }
            } message: { request in
                Text(TVAccountCopy.tvSwitchMessage(device: request.deviceName, mine: request.account, theirs: server.localAccount))
            }
            .overlay {
                if let account = server.switchingTo {
                    ContentUnavailableView {
                        Label {
                            Text(TVAccountCopy.tvSwitching(to: account))
                        } icon: {
                            ProgressView()
                        }
                    }
                    .tint(Color.scAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .animation(.smooth, value: server.switchingTo)
    }
}
