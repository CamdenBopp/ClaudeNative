import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let chatController = DemoChatViewController()
        chatController.title = "ChatMarkdownKit"
        window.rootViewController = UINavigationController(rootViewController: chatController)
        window.makeKeyAndVisible()
        self.window = window
    }
}
