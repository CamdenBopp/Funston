import CarPlay
import UIKit

/// CarPlay can launch without an iPhone window. Both scenes use the app's services.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?
    private var connectionTask: Task<Void, Never>?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            do {
                guard let delegate = UIApplication.shared.delegate as? AppDelegate else { return }
                let environment = try await delegate.prepareEnvironment()
                try Task.checkCancellation()
                guard let self else { return }
                let controller = CarPlayController(environment: environment, interfaceController: interfaceController)
                self.controller = controller
                controller.connect()
                await environment.downloads.refreshAvailability()
                await environment.start()
                try Task.checkCancellation()
                controller.refreshRecentListening()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let retry = CPListItem(text: "Try Again", detailText: error.localizedDescription)
                retry.handler = { [weak self, weak templateApplicationScene, weak interfaceController] _, completion in
                    if let templateApplicationScene, let interfaceController {
                        self?.templateApplicationScene(templateApplicationScene, didConnect: interfaceController)
                    }
                    completion()
                }
                interfaceController.setRootTemplate(
                    CPListTemplate(title: "Library unavailable", sections: [CPListSection(items: [retry])]),
                    animated: false, completion: nil)
            }
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        connectionTask?.cancel()
        connectionTask = nil
        controller?.disconnect()
        controller = nil
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        controller?.refreshRecentListening()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        controller?.savePlaybackPosition()
    }
}
