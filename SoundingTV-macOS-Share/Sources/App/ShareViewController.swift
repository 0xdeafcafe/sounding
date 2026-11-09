import AppKit
import SwiftUI

@MainActor
final class ShareViewController: NSViewController {
    private static let size = NSSize(width: 380, height: 440)

    override func loadView() {
        ShareCredentialSource.install()

        let viewModel = ShareViewModel { source, action in
            Self.openInSounding(source, action: action)
        }
        let root = ShareRootView(viewModel: viewModel) { [weak self] in
            self?.finish()
        }
        .frame(width: Self.size.width, height: Self.size.height)

        view = NSHostingView(rootView: root)
        preferredContentSize = Self.size

        Task { [weak self] in
            guard let self else { return }
            let items = self.extensionContext?.inputItems as? [NSExtensionItem] ?? []
            let url = await ShareItemExtractor.soundCloudCandidateURL(in: items)
            await viewModel.begin(with: url)
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private static func openInSounding(_ source: URL, action: ShareViewModel.QueueAction) -> Bool {
        let placement: SoundingWidgetLink.Placement
        switch action {
        case .playNow, .replace:
            placement = .now
        case .playNext:
            placement = .next
        case .addToEnd:
            placement = .last
        }
        return NSWorkspace.shared.open(SoundingWidgetLink.open(source: source, placement: placement).url)
    }
}
