import UIKit
import SwiftUI

@MainActor
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        ShareCredentialSource.install() // Must precede any SoundCloudAPI call this extension makes.

        let viewModel = ShareViewModel()
        let root = ShareRootView(viewModel: viewModel) { [weak self] in
            self?.finish()
        }
        embed(UIHostingController(rootView: root))

        Task { [weak self] in
            guard let self else { return }
            let url = await self.extractSoundCloudCandidateURL()
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

    private func extractSoundCloudCandidateURL() async -> URL? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if let url = await Self.loadURL(from: provider) {
                    return url
                }
            }
        }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        if provider.canLoadObject(ofClass: NSURL.self),
           let url = await urlObject(from: provider) {
            return url
        }

        if provider.canLoadObject(ofClass: NSString.self),
           let text = await stringObject(from: provider) {
            return firstURL(in: text)
        }

        return nil
    }

    private static func urlObject(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                let url = (object as? NSURL).map { $0 as URL }
                continuation.resume(returning: url)
            }
        }
    }

    private static func stringObject(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSString.self) { object, _ in
                let string = (object as? NSString).map { $0 as String }
                continuation.resume(returning: string)
            }
        }
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let urls = detector.matches(in: text, range: range).compactMap(\.url)
        return urls.first { ShareViewModel.isSoundCloudHost($0) } ?? urls.first
    }
}
