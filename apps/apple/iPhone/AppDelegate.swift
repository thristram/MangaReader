import UIKit

@main final class PhoneAppDelegate: UIResponder, UIApplicationDelegate {
  let session = AppSession()
  func application(
    _ application: UIApplication, configurationForConnecting sceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    UISceneConfiguration(name: "Default", sessionRole: sceneSession.role)
  }
}
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene,
      let app = UIApplication.shared.delegate as? PhoneAppDelegate
    else { return }
    let w = UIWindow(windowScene: scene)
    w.rootViewController = PhoneRootController(session: app.session)
    window = w
    w.makeKeyAndVisible()
    app.session.restore()
  }
  func sceneDidBecomeActive(_ scene: UIScene) {
    guard let app = UIApplication.shared.delegate as? PhoneAppDelegate, app.session.account != nil
    else { return }
    Task { try? await app.session.synchronize() }
  }
}
