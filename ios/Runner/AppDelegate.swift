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
    // Configurar Firebase (com fallback quando o GoogleService-Info.plist não estiver embutido)
    configureFirebaseApp()
    
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

  /// Garante que o Firebase esteja configurado antes de acessar Messaging/Analytics.
  /// Sem esse fallback o app crasha ao iniciar no iOS sempre que o GoogleService-Info.plist não é encontrado pelo runtime nativo.
  private func configureFirebaseApp() {
    if FirebaseApp.app() != nil {
      print("✅ Firebase já configurado (camada Flutter) - pulando configure() nativo")
      return
    }
    
    if let filePath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
       let options = FirebaseOptions(contentsOfFile: filePath) {
      FirebaseApp.configure(options: options)
      print("✅ Firebase configurado via GoogleService-Info.plist")
      return
    }
    
    print("⚠️ GoogleService-Info.plist não encontrado. Aplicando configuração manual para evitar crash no iOS")
    
    let manualOptions = FirebaseOptions(
      googleAppID: "1:832200775771:ios:1b8ff48f5118379515477e",
      gcmSenderID: "832200775771"
    )
    manualOptions.apiKey = "AIzaSyDgH9dJMTcWGYGxl6Rs0CXPxnlADumLFO4"
    manualOptions.projectID = "icar-2d12c"
    manualOptions.storageBucket = "icar-2d12c.firebasestorage.app"
    manualOptions.bundleID = Bundle.main.bundleIdentifier ?? "com.mycompany.icarusers"
    
    FirebaseApp.configure(options: manualOptions)
    print("✅ Firebase configurado manualmente com opções do projeto icar-2d12c")
  }
  
  // Método chamado quando o dispositivo recebe o token APNS
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    print("🍎 [iOS] ========== TOKEN APNS RECEBIDO ==========")
    let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
    let token = tokenParts.joined()
    print("🍎 [iOS] Device Token APNS: \(token)")
    
    // Passar o token para Firebase Messaging
    Messaging.messaging().apnsToken = deviceToken
    print("✅ [iOS] Token APNS passado para Firebase Messaging")
    
    // Obter token FCM após receber APNS token
    Messaging.messaging().token { token, error in
      if let error = error {
        print("❌ [iOS] Erro ao obter token FCM: \(error.localizedDescription)")
      } else if let token = token {
        print("✅ [iOS] Token FCM obtido: \(token.prefix(20))...\(token.suffix(20))")
      }
    }
    
    print("🍎 [iOS] ========================================")
  }
  
  // Método chamado quando falha ao registrar para remote notifications
  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    print("❌ [iOS] ========== ERRO AO REGISTRAR PARA REMOTE NOTIFICATIONS ==========")
    print("❌ [iOS] Erro: \(error.localizedDescription)")
    print("❌ [iOS] Detalhes: \(error)")
    print("❌ [iOS] =================================================================")
  }
}

// Extensão para implementar Firebase Messaging delegate
@available(iOS 10.0, *)
extension AppDelegate: MessagingDelegate {
  func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    print("🍎 [iOS] ========== TOKEN FCM RECEBIDO ==========")
    if let token = fcmToken {
      print("✅ [iOS] Token FCM: \(token.prefix(20))...\(token.suffix(20))")
      print("✅ [iOS] Tamanho do token: \(token.count) caracteres")
    } else {
      print("⚠️ [iOS] Token FCM é nil")
    }
    print("🍎 [iOS] ======================================")
    
    // Enviar notificação para Flutter sobre mudança de token
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
