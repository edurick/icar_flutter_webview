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
    print("🍎 [iOS] ========== AppDelegate.didFinishLaunchingWithOptions ==========")
    print("🍎 [iOS] Iniciando configuração do app...")
    
    // Configurar Firebase (com fallback quando o GoogleService-Info.plist não estiver embutido)
    print("🍎 [iOS] Configurando Firebase...")
    configureFirebaseApp()
    
    // Verificar se Firebase foi configurado corretamente
    if FirebaseApp.app() == nil {
      print("❌ [iOS] ERRO: Firebase não foi configurado!")
    } else {
      print("✅ [iOS] Firebase configurado com sucesso")
      if let app = FirebaseApp.app() {
        print("✅ [iOS] Firebase App Name: \(app.name)")
        print("✅ [iOS] Firebase App Options: \(app.options.projectID ?? "N/A")")
      }
    }
    
    // Configurar Firebase Messaging
    print("🍎 [iOS] Configurando Firebase Messaging...")
    if #available(iOS 10.0, *) {
      print("🍎 [iOS] iOS 10.0+ detectado, usando UNUserNotificationCenter")
      UNUserNotificationCenter.current().delegate = self
      print("✅ [iOS] UNUserNotificationCenter delegate configurado")
      
      let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
      print("🍎 [iOS] Solicitando autorização de notificações...")
      UNUserNotificationCenter.current().requestAuthorization(
        options: authOptions,
        completionHandler: { granted, error in
          if let error = error {
            print("❌ [iOS] Erro ao solicitar autorização de notificações: \(error.localizedDescription)")
          } else {
            print("✅ [iOS] Autorização de notificações: \(granted ? "concedida" : "negada")")
          }
        }
      )
    } else {
      print("🍎 [iOS] iOS < 10.0, usando UIUserNotificationSettings")
      let settings: UIUserNotificationSettings =
        UIUserNotificationSettings(types: [.alert, .badge, .sound], categories: nil)
      application.registerUserNotificationSettings(settings)
    }
    
    print("🍎 [iOS] Registrando para remote notifications...")
    application.registerForRemoteNotifications()
    
    // Configurar delegate do Firebase Messaging
    print("🍎 [iOS] Configurando Firebase Messaging delegate...")
    Messaging.messaging().delegate = self
    print("✅ [iOS] Firebase Messaging delegate configurado")
    
    // Verificar se o método swizzling está habilitado
    if let infoPlist = Bundle.main.infoDictionary,
       let proxyEnabled = infoPlist["FirebaseAppDelegateProxyEnabled"] as? Bool {
      print("🍎 [iOS] FirebaseAppDelegateProxyEnabled: \(proxyEnabled)")
      if !proxyEnabled {
        print("⚠️ [iOS] AVISO: FirebaseAppDelegateProxyEnabled está desabilitado!")
        print("⚠️ [iOS] Isso pode causar problemas com push notifications")
      }
    } else {
      print("⚠️ [iOS] AVISO: FirebaseAppDelegateProxyEnabled não encontrado no Info.plist")
    }
    
    GeneratedPluginRegistrant.register(with: self)
    print("✅ [iOS] GeneratedPluginRegistrant registrado")
    print("🍎 [iOS] ================================================================")
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
    print("🍎 [iOS] Device Token APNS (hex): \(token)")
    print("🍎 [iOS] Device Token APNS (tamanho): \(deviceToken.count) bytes")
    
    // Verificar se Firebase Messaging está disponível
    if Messaging.messaging().apnsToken == nil {
      print("🍎 [iOS] Firebase Messaging apnsToken ainda é nil, configurando agora...")
    } else {
      print("🍎 [iOS] Firebase Messaging já tinha um apnsToken anterior")
    }
    
    // Passar o token para Firebase Messaging
    print("🍎 [iOS] Passando token APNS para Firebase Messaging...")
    Messaging.messaging().apnsToken = deviceToken
    
    // Verificar se foi configurado corretamente
    if Messaging.messaging().apnsToken != nil {
      print("✅ [iOS] Token APNS passado para Firebase Messaging com sucesso")
    } else {
      print("❌ [iOS] ERRO: Token APNS não foi configurado no Firebase Messaging!")
    }
    
    // Obter token FCM após receber APNS token
    print("🍎 [iOS] Solicitando token FCM do Firebase...")
    Messaging.messaging().token { token, error in
      if let error = error {
        print("❌ [iOS] ========== ERRO AO OBTER TOKEN FCM ==========")
        print("❌ [iOS] Erro: \(error.localizedDescription)")
        print("❌ [iOS] Código do erro: \((error as NSError).code)")
        print("❌ [iOS] Domínio do erro: \((error as NSError).domain)")
        print("❌ [iOS] UserInfo: \((error as NSError).userInfo)")
        print("❌ [iOS] ============================================")
      } else if let token = token {
        print("✅ [iOS] ========== TOKEN FCM OBTIDO COM SUCESSO ==========")
        print("✅ [iOS] Token FCM (início): \(token.prefix(20))")
        print("✅ [iOS] Token FCM (fim): \(token.suffix(20))")
        print("✅ [iOS] Token FCM (tamanho): \(token.count) caracteres")
        print("✅ [iOS] ================================================")
      } else {
        print("⚠️ [iOS] Token FCM é nil (pode ser normal se ainda estiver sendo gerado)")
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
    print("🍎 [iOS] ========== TOKEN FCM RECEBIDO (MessagingDelegate) ==========")
    print("🍎 [iOS] Método didReceiveRegistrationToken chamado")
    
    if let token = fcmToken {
      print("✅ [iOS] Token FCM recebido: \(token.prefix(20))...\(token.suffix(20))")
      print("✅ [iOS] Tamanho do token: \(token.count) caracteres")
      print("✅ [iOS] Token FCM completo: \(token)")
    } else {
      print("⚠️ [iOS] Token FCM é nil")
      print("⚠️ [iOS] Possíveis causas:")
      print("⚠️ [iOS]   - APNS token ainda não foi registrado")
      print("⚠️ [iOS]   - APN Key não configurada no Firebase Console")
      print("⚠️ [iOS]   - Problema de conectividade com Firebase")
    }
    
    // Verificar se o APNS token está configurado
    if let apnsToken = messaging.apnsToken {
      let apnsTokenHex = apnsToken.map { String(format: "%02.2hhx", $0) }.joined()
      print("✅ [iOS] APNS token está configurado: \(apnsTokenHex.prefix(20))...")
    } else {
      print("⚠️ [iOS] APNS token NÃO está configurado no Firebase Messaging")
    }
    
    print("🍎 [iOS] Enviando notificação para Flutter sobre mudança de token...")
    // Enviar notificação para Flutter sobre mudança de token
    let dataDict: [String: String] = ["token": fcmToken ?? ""]
    NotificationCenter.default.post(
      name: Notification.Name("FCMToken"),
      object: nil,
      userInfo: dataDict
    )
    print("✅ [iOS] Notificação enviada para Flutter")
    print("🍎 [iOS] ============================================================")
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
    
    print("📱 [iOS] ========== NOTIFICAÇÃO RECEBIDA EM FOREGROUND ==========")
    print("📱 [iOS] Método willPresentNotification chamado")
    print("📱 [iOS] UserInfo: \(userInfo)")
    print("📱 [iOS] Título: \(notification.request.content.title)")
    print("📱 [iOS] Corpo: \(notification.request.content.body)")
    print("📱 [iOS] Badge: \(notification.request.content.badge?.intValue ?? 0)")
    print("📱 [iOS] Sound: \(notification.request.content.sound?.description ?? "N/A")")
    
    // Processar a mensagem com Firebase Messaging
    print("📱 [iOS] Processando mensagem com Firebase Messaging...")
    Messaging.messaging().appDidReceiveMessage(userInfo)
    
    // Não exibir notificação quando o app está em foreground
    // Apenas atualizar badge e tocar som, sem exibir banner/alert
    // As notificações push do sistema continuarão funcionando normalmente em background
    print("📱 [iOS] Notificação recebida em foreground - não exibindo banner (apenas push notifications em background)")
    if #available(iOS 14.0, *) {
      completionHandler([.badge, .sound]) // Removido .banner e .list para não exibir visualmente
    } else {
      completionHandler([.badge, .sound]) // Removido .alert para não exibir visualmente
    }
    print("📱 [iOS] ======================================================")
  }
  
  // Método chamado quando o usuário toca em uma notificação
  @available(iOS 10.0, *)
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                              didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    let userInfo = response.notification.request.content.userInfo
    
    print("📱 [iOS] ========== USUÁRIO TOCOU NA NOTIFICAÇÃO ==========")
    print("📱 [iOS] Método didReceiveNotificationResponse chamado")
    print("📱 [iOS] Action Identifier: \(response.actionIdentifier)")
    print("📱 [iOS] UserInfo: \(userInfo)")
    print("📱 [iOS] Título: \(response.notification.request.content.title)")
    print("📱 [iOS] Corpo: \(response.notification.request.content.body)")
    
    // Processar a notificação tocada
    // O Flutter receberá isso através do FirebaseMessaging.onMessageOpenedApp
    print("📱 [iOS] Processando mensagem com Firebase Messaging...")
    Messaging.messaging().appDidReceiveMessage(userInfo)
    print("✅ [iOS] Mensagem processada")
    
    // Chamar o método do super para garantir que o FlutterAppDelegate processe corretamente
    // Isso é necessário para que o Firebase Messaging possa notificar o Flutter via onMessageOpenedApp
    super.userNotificationCenter(center, didReceive: response) {
      completionHandler()
      print("📱 [iOS] ==================================================")
    }
  }
}
