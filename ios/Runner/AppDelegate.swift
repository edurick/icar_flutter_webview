import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Configurar Firebase
    FirebaseApp.configure()
    
    // Configurar Firebase Messaging
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
      let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
      UNUserNotificationCenter.current().requestAuthorization(
        options: authOptions,
        completionHandler: { _, _ in }
      )
    } else {
      let settings: UIUserNotificationSettings =
        UIUserNotificationSettings(types: [.alert, .badge, .sound], categories: nil)
      application.registerUserNotificationSettings(settings)
    }
    
    application.registerForRemoteNotifications()
    
    // Configurar delegate do Firebase Messaging
    Messaging.messaging().delegate = self
    
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  // Registrar token APNS
  override func application(_ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    print("📱 APNS token registrado com sucesso")
    Messaging.messaging().apnsToken = deviceToken
  }
  
  // Tratar erro ao registrar notificações remotas
  override func application(_ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error) {
    print("❌ Erro ao registrar notificações remotas: \(error.localizedDescription)")
  }
}

// Extensão para Firebase Messaging Delegate
extension AppDelegate: MessagingDelegate {
  func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    print("📱 Firebase registration token: \(String(describing: fcmToken))")
    
    let dataDict: [String: String] = ["token": fcmToken ?? ""]
    NotificationCenter.default.post(
      name: Notification.Name("FCMToken"),
      object: nil,
      userInfo: dataDict
    )
  }
}

// Extensão para UNUserNotificationCenterDelegate
// Necessário para que as notificações funcionem corretamente no iOS
// Nota: FlutterAppDelegate já implementa UNUserNotificationCenterDelegate,
// então estamos apenas sobrescrevendo os métodos
extension AppDelegate {
  // Método chamado quando uma notificação é recebida enquanto o app está em foreground
  @available(iOS 10.0, *)
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                              willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    let userInfo = notification.request.content.userInfo
    
    print("📱 Notificação recebida em foreground: \(userInfo)")
    
    // Exibir a notificação mesmo quando o app está em foreground
    // Isso permite que o usuário veja a notificação enquanto usa o app
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .badge, .sound, .list])
    } else {
      completionHandler([.alert, .badge, .sound])
    }
  }
  
  // Método chamado quando o usuário toca em uma notificação
  @available(iOS 10.0, *)
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                              didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    let userInfo = response.notification.request.content.userInfo
    
    print("📱 Usuário tocou na notificação: \(userInfo)")
    
    // Processar a notificação tocada
    // O Flutter receberá isso através do FirebaseMessaging.onMessageOpenedApp
    Messaging.messaging().appDidReceiveMessage(userInfo)
    
    completionHandler()
  }
}
