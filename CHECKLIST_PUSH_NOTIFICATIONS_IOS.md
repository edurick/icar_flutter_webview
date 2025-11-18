# ✅ Checklist Completo - Push Notifications iOS

## 📱 Configurações no Código (Verificado ✅)

### 1. AppDelegate.swift
- ✅ Importa `FirebaseCore`, `FirebaseMessaging`, `UserNotifications`
- ✅ Configura Firebase no `didFinishLaunchingWithOptions`
- ✅ Configura `UNUserNotificationCenter.delegate = self`
- ✅ Solicita autorização de notificações
- ✅ Registra para notificações remotas: `registerForRemoteNotifications()`
- ✅ Implementa `MessagingDelegate` para receber token FCM
- ✅ Implementa `UNUserNotificationCenterDelegate` para:
  - ✅ `willPresentNotification` (notificações em foreground)
  - ✅ `didReceiveNotificationResponse` (quando usuário toca na notificação)
- ✅ Implementa `didRegisterForRemoteNotificationsWithDeviceToken` para registrar token APNS
- ✅ Implementa `didFailToRegisterForRemoteNotificationsWithError` para debug

### 2. Runner.entitlements
- ✅ `aps-environment` configurado como `production`
- ✅ `com.apple.developer.applesignin` configurado

### 3. Info.plist
- ✅ `UIBackgroundModes` com `remote-notification` (adicionado agora)
- ✅ Todas as permissões necessárias configuradas

### 4. firebase_options.dart
- ✅ Configuração iOS presente com:
  - ✅ `apiKey`
  - ✅ `appId`
  - ✅ `messagingSenderId`
  - ✅ `projectId`
  - ✅ `storageBucket`
  - ✅ `iosBundleId: com.mycompany.icarusers`

### 5. main.dart
- ✅ Firebase inicializado com `Firebase.initializeApp()`
- ✅ Background message handler configurado
- ✅ `_initPushNotifications()` implementado
- ✅ Handlers configurados:
  - ✅ `FirebaseMessaging.onMessage` (foreground)
  - ✅ `FirebaseMessaging.onMessageOpenedApp` (quando app é aberto por notificação)
  - ✅ `messaging.getInitialMessage()` (app aberto por notificação)

### 6. pubspec.yaml
- ✅ `firebase_core: ^3.6.0`
- ✅ `firebase_messaging: ^15.1.3`
- ✅ `flutter_local_notifications: ^17.2.3`

## 🔧 Configurações no Xcode (Verificar Manualmente)

### 1. Capabilities
Abra o projeto no Xcode e verifique:
- [ ] **Push Notifications** está habilitado em Signing & Capabilities
- [ ] **Background Modes** está habilitado com "Remote notifications" marcado

### 2. Signing & Capabilities
- [ ] Team ID correto: `ZUPDD7DT87`
- [ ] Bundle Identifier correto: `com.mycompany.icarusers`
- [ ] Provisioning Profile válido e atualizado

## 🌐 Configurações no Apple Developer Portal

### 1. App ID
Acesse: https://developer.apple.com/account > Certificates, Identifiers & Profiles > Identifiers

- [ ] App ID `com.mycompany.icarusers` existe
- [ ] **Push Notifications** está habilitado no App ID
- [ ] Push Notifications está configurado (Development e/ou Production)

### 2. APN Key
Acesse: https://developer.apple.com/account > Certificates, Identifiers & Profiles > Keys

- [ ] Key `icarapn` (GV634YSGV9) existe e está ativa
- [ ] Key tem "Apple Push Notifications service (APNs)" habilitado
- [ ] Arquivo `AuthKey_GV634YSGV9.p8` está salvo com segurança

## 🔥 Configurações no Firebase Console

### 1. APN Key Configuration
Acesse: https://console.firebase.google.com > Project Settings > Cloud Messaging

- [ ] APN Key foi enviada para o Firebase Console
- [ ] Key ID: `GV634YSGV9`
- [ ] Team ID: `ZUPDD7DT87`
- [ ] Status: "Active" ou "Ativo"
- [ ] Tipo: APNs Authentication Key (Production)

### 2. iOS App Configuration
- [ ] App iOS `com.mycompany.icarusers` está registrado no Firebase
- [ ] Bundle ID corresponde: `com.mycompany.icarusers`
- [ ] App ID do Firebase corresponde: `1:832200775771:ios:1b8ff48f5118379515477e`

## 🧪 Testes

### 1. Build e Instalação
- [ ] App compila sem erros
- [ ] App instala em dispositivo físico iOS (não simulador)
- [ ] Permissões de notificação são solicitadas ao abrir o app

### 2. Verificação de Tokens
Verifique os logs do Xcode:
- [ ] `📱 APNS token registrado com sucesso` aparece nos logs
- [ ] `📱 Firebase registration token: [token]` aparece nos logs
- [ ] Token FCM é registrado no backend

### 3. Teste de Notificações
- [ ] Notificações aparecem quando app está em foreground
- [ ] Notificações aparecem quando app está em background
- [ ] Notificações aparecem quando app está fechado
- [ ] Ao tocar na notificação, o app abre corretamente
- [ ] Dados da notificação são processados corretamente

## ⚠️ Problemas Comuns e Soluções

### Erro: "APNs token not registered"
- Verifique se está testando em dispositivo físico (não simulador)
- Verifique se as permissões foram concedidas
- Verifique se o Team ID e Bundle ID estão corretos

### Erro: "Invalid APNs Key"
- Verifique se a Key ID está correta: `GV634YSGV9`
- Verifique se o Team ID está correto: `ZUPDD7DT87`
- Verifique se a key está ativa no Apple Developer Portal

### Notificações não aparecem
- Verifique se `aps-environment` está como `production` no entitlements
- Verifique se a APN Key está configurada no Firebase Console
- Verifique se o app tem permissão nas configurações do iOS
- Verifique se está testando com build de produção (não debug)

### Notificações aparecem mas não abrem o app
- Verifique se `didReceiveNotificationResponse` está implementado
- Verifique se `FirebaseMessaging.onMessageOpenedApp` está configurado
- Verifique se `messaging.getInitialMessage()` está sendo chamado

## 📝 Notas Importantes

1. **Simulador iOS não suporta push notifications** - Sempre teste em dispositivo físico
2. **Development vs Production** - Certifique-se de usar o ambiente correto
3. **APN Key vs Certificado** - A APN Key (.p8) é mais moderna e recomendada
4. **Permissões** - O usuário deve conceder permissão de notificações
5. **Background Modes** - Necessário para notificações em background funcionarem

## ✅ Status Atual

- ✅ Código configurado corretamente
- ✅ Entitlements configurado para produção
- ✅ Info.plist com UIBackgroundModes configurado
- ⚠️ Verificar configurações no Xcode (Capabilities)
- ⚠️ Verificar configurações no Apple Developer Portal
- ⚠️ Verificar configurações no Firebase Console
- ⚠️ Testar em dispositivo físico

