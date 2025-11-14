# Guia de Teste de Push Notifications

## Pré-requisitos

1. **App instalado e rodando** no dispositivo Android ou iOS
2. **Usuário logado** no app (o email será capturado automaticamente)
3. **Permissões de notificação** concedidas

## Como Testar

### 1. Verificar se o email foi capturado

1. Faça login no app
2. O email será automaticamente:
   - Capturado do localStorage/sessionStorage da WebView
   - Salvo no SharedPreferences do Flutter
   - Usado para registrar o token FCM no Firebase

### 2. Verificar se o token FCM foi registrado

O token FCM será registrado automaticamente quando:
- O email for detectado
- O usuário não tiver token FCM registrado ainda
- Não houver tentativa recente que falhou (cooldown de 30 minutos)

### 3. Testar envio de notificação

#### Opção A: Via Firebase Console

1. Acesse o [Firebase Console](https://console.firebase.google.com/)
2. Selecione o projeto
3. Vá em **Cloud Messaging**
4. Clique em **Send test message**
5. Cole o **FCM Token** do dispositivo (obtenha dos logs do Flutter)
6. Digite uma mensagem de teste
7. **IMPORTANTE:** Certifique-se de que o app está rodando (foreground ou background)
8. Clique em **Test**

**Nota:** As notificações agora funcionam tanto em foreground quanto em background. Quando o app está aberto, uma notificação local será exibida automaticamente.

#### Opção B: Via API do Backend

Envie uma requisição POST para o endpoint de notificações do backend:

```bash
curl -X POST https://icar.skalacode.com/api/send-notification \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer SEU_TOKEN" \
  -d '{
    "email": "usuario@email.com",
    "title": "Teste de Notificação",
    "body": "Esta é uma notificação de teste",
    "data": {
      "type": "test",
      "message": "Teste"
    }
  }'
```

### 4. Verificar logs no dispositivo

Os logs do Flutter mostrarão:
- `📧 Email encontrado: [email]` - Email capturado
- `💾 [Flutter Storage] Email salvo no SharedPreferences` - Email salvo
- `📱 [PushNotificationService] Iniciando registro de token` - Início do registro
- `✅ [PushNotificationService] Token FCM obtido` - Token obtido com sucesso
- `✅ Token FCM registrado com sucesso no backend` - Token salvo no backend

### 5. Verificar no banco de dados

Verifique se o token foi salvo na tabela `push_tokens`:

```sql
SELECT * FROM push_tokens WHERE user_id = [ID_DO_USUARIO];
```

## Troubleshooting

### Notificações não estão chegando

1. **Verifique se o token FCM foi registrado:**
   - Verifique os logs do Flutter para confirmar que o token foi obtido
   - Verifique no banco de dados se o token foi salvo

2. **Verifique as permissões:**
   - Android: Permissões de notificação concedidas (POST_NOTIFICATIONS)
   - iOS: Permissões de notificação concedidas
   - Verifique nas configurações do dispositivo se as notificações estão habilitadas

3. **Notificações em foreground:**
   - As notificações agora são exibidas mesmo quando o app está aberto
   - Se não aparecerem, verifique os logs para erros

4. **Teste com o token correto:**
   - Use o token FCM do dispositivo específico
   - Não use tokens antigos ou de outros dispositivos

### Token não está sendo registrado

1. **Verifique se o email foi capturado:**
   - O email deve estar no localStorage da WebView como `userEmail`
   - O email deve estar no SharedPreferences do Flutter

2. **Verifique os logs:**
   - Procure por erros do Firebase
   - Verifique se há bloqueios temporários (cooldown)

3. **Verifique as permissões:**
   - Android: Permissões de notificação concedidas
   - iOS: Permissões de notificação concedidas

### Erro "invalid-credential"

- O sistema tentará criar o usuário no Firebase automaticamente
- Se falhar, aguarde 30 minutos antes de tentar novamente

### Erro "too-many-requests"

- O Firebase bloqueou temporariamente o dispositivo
- Aguarde 60 minutos antes de tentar novamente

## Teste em Produção

1. **Android:**
   - Instale o APK de release
   - Faça login
   - Verifique se o token foi registrado
   - Envie uma notificação de teste

2. **iOS:**
   - Instale o app via TestFlight ou App Store
   - Faça login
   - Verifique se o token foi registrado
   - Envie uma notificação de teste

## Checklist de Teste

- [ ] Email capturado do localStorage
- [ ] Email salvo no SharedPreferences
- [ ] Login no Firebase bem-sucedido (ou criação de conta)
- [ ] Token FCM obtido
- [ ] Token FCM enviado para o backend
- [ ] Token FCM salvo no banco de dados
- [ ] Notificação recebida no dispositivo
- [ ] Notificação exibida corretamente
- [ ] Ao clicar na notificação, o app abre

## Comandos Úteis

### Ver logs do Flutter em tempo real

```bash
flutter logs
```

### Ver logs do Android

```bash
adb logcat | grep -i "flutter\|fcm\|firebase"
```

### Ver logs do iOS

```bash
xcrun simctl spawn booted log stream --predicate 'processImagePath contains "icarwebview"' --level debug
```

