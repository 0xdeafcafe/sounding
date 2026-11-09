import CarPlay
import UIKit

@MainActor
enum CarPlayAppContext {
    static var coordinator: PhonePlaybackCoordinator?
    static var startRuntime: (@MainActor () async -> Void)?
}

@objc(SoundingCarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        controller?.stop()
        guard let coordinator = CarPlayAppContext.coordinator else { return }
        let controller = CarPlayController(interfaceController: interfaceController, coordinator: coordinator)
        self.controller = controller
        controller.start()
        Task { @MainActor in
            await CarPlayAppContext.startRuntime?()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        controller?.stop()
        controller = nil
    }
}
