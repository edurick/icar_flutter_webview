# 🔔 Configuração da APN Key no Firebase Console para Produção

## 📋 Informações da APN Key

- **Nome:** icarapn
- **Key ID:** GV634YSGV9
- **Serviço:** Apple Push Notifications service (APNs)
- **Arquivo:** `AuthKey_GV634YSGV9.p8`
- **Localização:** `/icar_flutter_webview/AuthKey_GV634YSGV9.p8`

## 🚀 Passo a Passo para Configurar no Firebase Console

### 1. Acessar o Firebase Console

1. Acesse: https://console.firebase.google.com
2. Selecione o projeto: **icar-2d12c**
3. Vá em **Project Settings** (ícone de engrenagem ⚙️ no canto superior esquerdo)

### 2. Configurar APN Key na aba Cloud Messaging

1. Na página de configurações, vá na aba **Cloud Messaging**
2. Role até a seção **Apple app configuration**
3. Localize o app iOS: **com.mycompany.icarusers**
4. Clique em **Upload** ao lado de "APNs Authentication Key"

### 3. Fazer Upload da APN Key

1. Clique em **Upload** ou **Select a file**
2. Selecione o arquivo: `AuthKey_GV634YSGV9.p8`
   - Localização: `/icar_flutter_webview/AuthKey_GV634YSGV9.p8`
3. No campo **Key ID**, insira: `GV634YSGV9`
4. No campo **Team ID**, insira o Team ID da sua conta Apple Developer
   - Team ID atual no projeto: `ZUPDD7DT87`
5. Clique em **Upload**

### 4. Verificar Configuração

Após o upload, você deve ver:
- ✅ Status: "Active" ou "Ativo"
- ✅ Key ID: GV634YSGV9
- ✅ Tipo: APNs Authentication Key (Production)

## ⚠️ Importante

### Ambiente Configurado

O projeto está configurado para **PRODUÇÃO**:
- ✅ `aps-environment` = `production` no arquivo `Runner.entitlements`

### Diferença entre Development e Production

- **Development:** Usado para testes durante o desenvolvimento
- **Production:** Usado para apps publicados na App Store

### Verificações Necessárias

1. ✅ Certifique-se de que o **Team ID** está correto (`ZUPDD7DT87`)
2. ✅ Verifique se o **Bundle ID** está correto (`com.mycompany.icarusers`)
3. ✅ Confirme que a APN Key está ativa no Apple Developer Portal
4. ✅ Verifique se o App ID no Apple Developer Portal tem Push Notifications habilitado

## 🔍 Verificar no Apple Developer Portal

1. Acesse: https://developer.apple.com/account
2. Vá em **Certificates, Identifiers & Profiles**
3. Em **Keys**, verifique se a key `icarapn` (GV634YSGV9) está ativa
4. Em **Identifiers**, verifique se o App ID `com.mycompany.icarusers` tem:
   - ✅ Push Notifications habilitado
   - ✅ Configuração de Push Notifications configurada

## 📝 Notas Técnicas

- A APN Key (.p8) é mais moderna e recomendada que certificados (.p12)
- Uma única APN Key pode ser usada para múltiplos apps
- A APN Key não expira (diferente dos certificados que expiram anualmente)
- O arquivo `.p8` contém a chave privada - **NÃO compartilhe publicamente**

## 🧪 Testar Notificações Push

Após configurar:

1. Faça um build de produção do app iOS
2. Instale no dispositivo físico (não funciona no simulador)
3. Verifique os logs no Xcode para confirmar que o token APNs foi registrado:
   ```
   📱 APNS token registrado com sucesso
   📱 Firebase registration token: [token]
   ```
4. Envie uma notificação de teste pelo Firebase Console ou pelo backend

## 🐛 Troubleshooting

### Erro: "Invalid APNs Key"
- Verifique se o Key ID está correto: `GV634YSGV9`
- Verifique se o Team ID está correto: `ZUPDD7DT87`
- Confirme que a key está ativa no Apple Developer Portal

### Erro: "APNs token not registered"
- Verifique se o app está rodando em um dispositivo físico (não simulador)
- Confirme que as permissões de notificação foram concedidas
- Verifique os logs do app para erros específicos

### Notificações não aparecem
- Verifique se `aps-environment` está como `production` no `Runner.entitlements`
- Confirme que a APN Key está configurada no Firebase Console
- Verifique se o app tem permissão para notificações nas configurações do iOS












