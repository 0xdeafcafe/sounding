import UIKit
import SwiftUI

@MainActor
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        ShareCredentialSource.install()

        let viewModel = ShareViewModel()
        let root = ShareRootView(viewModel: viewModel) { [weak self] in
            self?.finish()
        }
        embed(UIHostingController(rootView: root))

        Task { [weak self] in
            guard let self else { return }
            let items = self.extensionContext?.inputItems as? [NSExtensionItem] ?? []
            let url = await ShareItemExtractor.soundCloudCandidateURL(in: items)
            await viewModel.begin(with: url)
        }
    }

    private func embed<Content: View>(_ hosting: UIHostingController<Content>) {
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
