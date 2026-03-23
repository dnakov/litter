import CarPlay
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var voiceManager: CarPlayVoiceManager?

    // MARK: - Scene Lifecycle

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController

        let vm = CarPlayVoiceManager(
            voiceActions: VoiceRuntimeController.shared,
            appModel: AppModel.shared,
            interfaceController: interfaceController
        )
        self.voiceManager = vm

        let tabBar = CPTabBarTemplate(templates: [
            vm.buildVoiceTab(),
            vm.buildSessionsTab()
        ])
        interfaceController.setRootTemplate(tabBar, animated: false)
        vm.startObserving()
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        voiceManager?.stopObserving()
        voiceManager = nil
        self.interfaceController = nil
    }
}
