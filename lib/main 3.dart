import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iCar',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const AuthWrapper(),
    );
  }
}

// Tela principal com WebView único
class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  late final WebViewController controller;
  final AuthService _authService = AuthService();
  late AppLinks _appLinks;
  StreamSubscription? _linkSubscription;
  Timer? _locationMonitorTimer;
  Timer? _authMonitorTimer;
  bool _isProcessingLocationRequest = false;
  bool _isLoading = true;
  bool _awaitingCallback = false;
  String? _lastKnownToken;
  bool _isInAuthFlow = false;
  String? _lastAppleAuthUrl;  // Para evitar navegação duplicada

  @override
  void initState() {
    super.initState();
    // REMOVIDO: _requestLocationPermission();
    // A permissão agora só será solicitada quando realmente necessário (ex: ao usar SOS)
    _initWebView();
    _initDeepLinkListener();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    _locationMonitorTimer?.cancel();
    _authMonitorTimer?.cancel();
    super.dispose();
  }

  void _initWebView() {
    // User-Agent diferente para Android (Chrome) e iOS (Safari)
    final userAgent = Platform.isAndroid
        ? 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'
        : 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(false)
      ..setUserAgent(userAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            if (progress == 100) {
              setState(() {
                _isLoading = false;
              });
            }
          },
          onPageStarted: (String url) {
            setState(() {
              _isLoading = true;
            });
          },
          onPageFinished: (String url) {
            setState(() {
              _isLoading = false;
            });
            _injectJavaScriptChannels();
            _startLocationMonitoring();
            _startAuthMonitoring();

            // Token já foi injetado no onNavigationRequest, apenas log
            if (url.contains('auth_success=true')) {
              print('✅ Página com auth_success carregada');
            }

            // Não restaurar sessão durante o fluxo do Apple Sign In
            if (!_isInAuthFlow) {
              _restoreAuthIfNeeded();
            }
          },
          onHttpError: (HttpResponseError error) {
            print('HTTP error: ${error.response?.statusCode}');
          },
          onWebResourceError: (WebResourceError error) {
            print('Web resource error: ${error.description}');
          },
          onNavigationRequest: (NavigationRequest request) {
            print('Navigation to: ${request.url}');

            // Se navegando para o backend do Apple Sign In, não bloquear
            if (request.url.contains('icar.skalacode.com/auth/apple') ||
                request.url.contains('icar-main-g5fjum.laravel.cloud/auth/apple')) {
              print('🔄 Navegando para backend do Apple Sign In...');
              return NavigationDecision.navigate;
            }

            // Interceptar deep link ANTES de permitir outras navegações
            if (request.url.startsWith('com.mycompany.icarusers://')) {
              print('🔗 Intercepting deep link in navigation: ${request.url}');
              setState(() {
                _awaitingCallback = true;
              });

              _handleDeepLink(request.url);
              return NavigationDecision.prevent;
            }

            // Se navegando para React com callback e token, processar
            if (request.url.contains('/auth/callback') && request.url.contains('token=')) {
              print('🎯 React recebendo token via URL - backend -> frontend direto!');

              // Extrair token da URL para salvar no Flutter também
              final uri = Uri.parse(request.url);
              final token = uri.queryParameters['token'];
              final userParam = uri.queryParameters['user'];

              if (token != null && userParam != null) {
                try {
                  final user = jsonDecode(Uri.decodeComponent(userParam));
                  _authService.saveAuthData(token, user);
                  print('✅ Token salvo no Flutter também');

                  // Enviar token para WebView também (sem await pois não é async)
                  _sendTokenToWebView(token, user, provider: 'google');

                  // Limpar flags de autenticação
                  setState(() {
                    _awaitingCallback = false;
                    _isInAuthFlow = false;
                    _lastAppleAuthUrl = null; // Limpar URL armazenada após sucesso
                  });
                } catch (e) {
                  print('Erro ao salvar token: $e');
                }
              }
            }

            // Se voltou para o React com erro, limpar flags
            if (request.url.contains('icarfront.vercel.app') && request.url.contains('error=')) {
              print('❌ Erro detectado na URL, limpando flags de autenticação');
              setState(() {
                _awaitingCallback = false;
                _isInAuthFlow = false;
                _lastAppleAuthUrl = null; // Limpar URL armazenada
              });
            }

            // Permitir navegação para Apple Sign In com controle de duplicação
            if (request.url.contains('appleid.apple.com')) {
              // Se já estamos aguardando callback, ignorar navegações duplicadas
              if (_awaitingCallback && _lastAppleAuthUrl == request.url) {
                print('⚠️ Ignorando navegação duplicada para Apple Sign In');
                return NavigationDecision.prevent;
              }

              print('🍎 Navegando para Apple Sign In...');
              _lastAppleAuthUrl = request.url;

              // Marcar que estamos aguardando callback se ainda não estiver marcado
              if (!_awaitingCallback) {
                setState(() {
                  _awaitingCallback = true;
                });
              }

              // Limpar a URL duplicada após um delay para permitir futuras navegações
              Future.delayed(const Duration(seconds: 2), () {
                _lastAppleAuthUrl = null;
              });

              return NavigationDecision.navigate;
            }

            // Se navegou para Google, marcar que estamos aguardando callback
            if (request.url.contains('accounts.google.com')) {
              print('🔍 Navegando para Google Sign In, aguardando callback...');
              // Apenas marca se não estiver já marcado para evitar duplicação
              if (!_awaitingCallback) {
                setState(() {
                  _awaitingCallback = true;
                });
              }
            }

            // Permitir navegações para Apple, Google, backend e frontend
            if (request.url.contains('appleid.apple.com') ||
                request.url.contains('accounts.google.com') ||
                request.url.contains('icar.skalacode.com') ||
                request.url.contains('icar-main-g5fjum.laravel.cloud') ||
                request.url.contains('icarfront.vercel.app')) {
              return NavigationDecision.navigate;
            }

            return NavigationDecision.navigate;
          },
        ),
      )
      ..addJavaScriptChannel(
        'FlutterWebView',
        onMessageReceived: (JavaScriptMessage message) {
          _handleWebViewMessage(message.message);
        },
      )
      ..loadRequest(Uri.parse('https://icarfront.vercel.app/?source=mobile'));
  }

  void _initDeepLinkListener() async {
    _appLinks = AppLinks();
    
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        print('App opened with initial link: $initialUri');
        _handleDeepLink(initialUri.toString());
      }
    } catch (e) {
      print('Error getting initial link: $e');
    }
    
    _linkSubscription = _appLinks.uriLinkStream.listen(
      (Uri uri) {
        print('Received URI from stream: $uri');
        _handleDeepLink(uri.toString());
      },
      onError: (err) {
        print('Deep link error: $err');
      },
    );
  }

  Future<void> _handleDeepLink(String link) async {
    print('🔗 DEEP LINK RECEIVED: $link');
    
    final uri = Uri.parse(link);
    print('🔍 URI parsed - scheme: ${uri.scheme}, host: ${uri.host}, path: ${uri.path}');
    
    setState(() {
      _awaitingCallback = false;
      _isInAuthFlow = false; // Finalizar fluxo de autenticação
    });
    
    if (uri.scheme == 'com.mycompany.icarusers' && 
        uri.host == 'auth' && 
        uri.path == '/callback') {
      
      print('✅ Deep link matches expected pattern');
      
      final token = uri.queryParameters['token'];
      final userParam = uri.queryParameters['user'];
      
      if (token != null && userParam != null) {
        try {
          final user = jsonDecode(Uri.decodeComponent(userParam));
          await _authService.saveAuthData(token, user);
          
          print('✅ Login successful via deep link');
          _showSuccess('Login realizado com sucesso!');
          
          // Enviar token para WebView para login automático
          await _sendTokenToWebView(token, user, provider: 'google');

          // Navegar para home após enviar o token
          await Future.delayed(const Duration(milliseconds: 500));
          controller.loadRequest(Uri.parse('https://icarfront.vercel.app/home?source=mobile'));
        } catch (e) {
          print('❌ Error processing deep link data: $e');
          _showError('Erro ao processar dados de autenticação');
        }
      } else {
        print('❌ Missing token or user data in deep link');
        _showError('Dados de autenticação incompletos');
        controller.loadRequest(Uri.parse('https://icarfront.vercel.app/?source=mobile'));
      }
    } else {
      print('❌ Deep link does not match expected pattern');
      controller.loadRequest(Uri.parse('https://icarfront.vercel.app/?source=mobile'));
    }
  }

  Future<void> _sendTokenToWebView(String token, Map<String, dynamic> user, {String provider = 'google'}) async {
    try {
      final userJson = jsonEncode(user);
      print('🔄 Enviando token para WebView: $token');

      final jsCode = '''
        // Salvar token no localStorage
        localStorage.setItem('access_token', '$token');
        localStorage.setItem('auth_token', '$token');
        localStorage.setItem('authToken', '$token');
        localStorage.setItem('user', '$userJson');

        console.log('Flutter: Token do $provider Auth salvo no localStorage');

        // Disparar evento customizado para o frontend processar
        window.dispatchEvent(new CustomEvent('authSuccess', {
          detail: {
            token: '$token',
            user: $userJson,
            provider: '$provider'
          }
        }));

        console.log('Flutter: Evento authSuccess disparado - frontend deve processar login');

        // Também enviar via postMessage (caso o frontend use essa abordagem)
        window.postMessage({
          type: 'authSuccess',
          token: '$token',
          user: $userJson,
          provider: '$provider',
          source: 'flutter'
        }, '*');

        // Não fazer reload automático - deixar o frontend processar o token
        // O frontend deve escutar o evento 'authSuccess' ou 'message' e processar o login
      ''';

      await controller.runJavaScript(jsCode);
      print('✅ Token enviado para WebView com sucesso');

    } catch (e) {
      print('❌ Erro ao enviar token para WebView: $e');
    }
  }

  Future<void> _restoreAuthIfNeeded() async {
    try {
      final token = await _authService.getToken();
      final user = await _authService.getUser();

      if (token != null && user != null) {
        print('🔄 Restaurando sessão do usuário...');
        _lastKnownToken = token;

        // Restaurar dados completos no localStorage e sessionStorage
        final userName = user['nome'] ?? user['name'] ?? 'Usuário';
        final userId = user['id']?.toString() ?? '';

        final jsCode = '''
          // Restaurar no localStorage (persistente)
          localStorage.setItem('access_token', '$token');
          localStorage.setItem('auth_token', '$token');
          localStorage.setItem('authToken', '$token');
          localStorage.setItem('user', '${jsonEncode(user)}');
          localStorage.setItem('nameUser', '$userName');
          localStorage.setItem('userName', '$userName');
          localStorage.setItem('idUser', '$userId');
          localStorage.setItem('userId', '$userId');
          localStorage.setItem('user_id', '$userId');
          localStorage.setItem('rememberMe', 'true');

          // Também restaurar no sessionStorage para a sessão atual
          sessionStorage.setItem('auth_token', '$token');
          sessionStorage.setItem('authToken', '$token');
          sessionStorage.setItem('token', '$token');
          sessionStorage.setItem('nameUser', '$userName');
          sessionStorage.setItem('userName', '$userName');
          sessionStorage.setItem('idUser', '$userId');
          sessionStorage.setItem('userId', '$userId');
          sessionStorage.setItem('user_id', '$userId');

          console.log('✅ Flutter: Token e dados do usuário restaurados com sucesso');
          console.log('Token no localStorage:', localStorage.getItem('authToken'));
          console.log('Token no sessionStorage:', sessionStorage.getItem('authToken'));
          console.log('Nome do usuário:', '$userName');

          // Disparar evento para o React processar a autenticação restaurada
          window.dispatchEvent(new CustomEvent('authRestored', {
            detail: {
              token: '$token',
              user: ${jsonEncode(user)},
              source: 'flutter_restore'
            }
          }));
        ''';
        await controller.runJavaScript(jsCode);

        print('✅ Sessão restaurada no WebView com sucesso');
      } else {
        print('ℹ️ Nenhuma sessão anterior encontrada para restaurar');
      }
    } catch (e) {
      print('❌ Erro ao restaurar autenticação: $e');
    }
  }

  Future<void> _requestLocationPermission() async {
    try {
      print('Verificando permissões de localização...');
      
      var locationStatus = await Permission.location.status;
      
      if (!locationStatus.isGranted) {
        final shouldRequest = await _showLocationRationale();
        if (!shouldRequest) return;
        
        locationStatus = await Permission.location.request();
      }
      
      if (locationStatus.isGranted) {
        print('Permissão de localização concedida');
        
        final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          print('Serviço de localização desabilitado no dispositivo');
        }
      } else if (locationStatus.isDenied) {
        print('Permissão de localização negada');
      } else if (locationStatus.isPermanentlyDenied) {
        print('Permissão de localização permanentemente negada');
        await _showOpenSettingsDialog();
      }
    } catch (e) {
      print('Erro ao solicitar permissão de localização: $e');
    }
  }

  Future<bool> _showLocationRationale() async {
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Permissão de Localização'),
          content: const Text(
            'O iCar precisa acessar sua localização para mostrar sua posição no mapa e encontrar veículos próximos a você.\n\n'
            'Suas informações de localização são usadas apenas enquanto você está usando o aplicativo.'
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancelar'),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            TextButton(
              child: const Text('Permitir'),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    ) ?? false;
  }

  Future<void> _showOpenSettingsDialog() async {
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Permissão Necessária'),
          content: const Text(
            'A permissão de localização foi negada permanentemente. '
            'Por favor, habilite-a nas configurações do aplicativo.'
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancelar'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('Abrir Configurações'),
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
              },
            ),
          ],
        );
      },
    );
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _startAuthMonitoring() {
    _authMonitorTimer?.cancel();
    return; // Temporariamente desabilitado
  }

  void _startLocationMonitoring() {
    _locationMonitorTimer?.cancel();
    return; // Temporariamente desabilitado
  }

  void _injectJavaScriptChannels() {
    const jsCode = '''
      window.FlutterWebViewChannel = {
        postMessage: function(message) {
          if (window.FlutterWebView && window.FlutterWebView.postMessage) {
            window.FlutterWebView.postMessage(JSON.stringify(message));
          }
        }
      };
      
      window.addEventListener('message', function(event) {
        if (event.data && event.data.type === 'logout') {
          window.FlutterWebViewChannel.postMessage({
            type: 'logout'
          });
        }
      });
      
      window.postMessage({
        type: 'flutterReady',
        source: 'flutter'
      }, '*');
      
      console.log('Flutter: Sistema de localização via localStorage ativado');
    ''';
    
    controller.runJavaScript(jsCode);
  }

  void _handleWebViewMessage(String message) {
    try {
      print('Mensagem recebida do WebView: $message');
      final data = jsonDecode(message);

      if (data['type'] == 'logout') {
        print('Processando logout...');
        _handleLogout();
      } else if (data['type'] == 'openAppleAuth') {
        print('Abrindo Apple Sign In no navegador externo...');
        _handleOpenAppleAuth(data['url']);
      } else if (data['type'] == 'openGoogleAuth') {
        print('Abrindo Google Sign In no navegador externo...');
        _handleOpenGoogleAuth(data['url']);
      } else if (data['type'] == 'authSuccess') {
        print('✅ Autenticação bem-sucedida!');
        _handleAuthSuccess(data['token'], data['user']);
      } else if (data['type'] == 'closeWebView') {
        print('Fechando overlay de autenticação...');
        _handleCloseWebView();
      }
    } catch (e) {
      print('Erro ao processar mensagem do WebView: $e');
    }
  }

  void _handleOpenAppleAuth(String url) async {
    // Prevenir múltiplas chamadas
    if (_isInAuthFlow) {
      print('⚠️ Apple Sign In já está em andamento, ignorando nova chamada');
      return;
    }

    print('Iniciando Apple Sign In nativo...');
    setState(() {
      _awaitingCallback = true;
      _isInAuthFlow = true;
    });

    try {
      // Usar Sign in with Apple nativo
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        webAuthenticationOptions: WebAuthenticationOptions(
          clientId: 'com.mycompany.icarusers', // Corrigido para corresponder ao bundle ID
          redirectUri: Uri.parse('https://icar.skalacode.com/auth/apple/callback'),
        ),
      );

      print('✅ Apple Sign In bem-sucedido!');
      print('User ID: ${credential.userIdentifier}');
      print('Email: ${credential.email}');
      print('Nome: ${credential.givenName} ${credential.familyName}');

      // Enviar dados para o backend
      final backendUrl = 'https://icar.skalacode.com/api/auth/apple/mobile';

      // Preparar dados do usuário (se disponível)
      Map<String, dynamic>? userData;
      if (credential.givenName != null || credential.familyName != null || credential.email != null) {
        userData = {
          'givenName': credential.givenName ?? '',
          'familyName': credential.familyName ?? '',
          'email': credential.email ?? '',
        };
      }

      print('Enviando para backend: $backendUrl');
      print('Authorization Code: ${credential.authorizationCode}');
      print('Identity Token: ${credential.identityToken?.substring(0, 50)}...');

      // Fazer chamada sem autenticação pois é endpoint público
      final dio = Dio();

      // Adicionar interceptor para debug
      dio.interceptors.add(LogInterceptor(
        requestBody: true,
        responseBody: true,
        error: true,
      ));

      final response = await dio.post(
        backendUrl,
        data: {
          'authorization_code': credential.authorizationCode,
          'identity_token': credential.identityToken,
          'user': userData,
        },
        options: Options(
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          validateStatus: (status) => status! < 500, // Aceitar respostas até 499
        ),
      );

      if (response.statusCode == 200 && response.data['success'] == true) {
        final token = response.data['token'];
        final user = response.data['user'];

        // Salvar dados localmente
        await _authService.saveAuthData(token, user);

        // Enviar para o WebView com provider 'apple'
        await _sendTokenToWebView(token, user, provider: 'apple');

        print('✅ Login com Apple completado com sucesso!');
        _showSuccess('Login realizado com sucesso!');

        setState(() {
          _awaitingCallback = false;
          _isInAuthFlow = false;
        });

        // Navegar para home após sucesso
        await Future.delayed(const Duration(milliseconds: 500));
        controller.loadRequest(Uri.parse('https://icarfront.vercel.app/home?source=mobile'));
      } else {
        print('❌ Resposta inválida do servidor: ${response.data}');
        throw Exception('Falha na autenticação com o servidor');
      }

    } on DioException catch (e) {
      print('❌ Erro de rede ao chamar backend: ${e.response?.statusCode}');
      print('Response data: ${e.response?.data}');

      String errorMessage = 'Erro ao conectar com o servidor';
      if (e.response?.statusCode == 401) {
        errorMessage = 'Credenciais inválidas';
      } else if (e.response?.statusCode == 400) {
        errorMessage = e.response?.data['message'] ?? 'Dados inválidos';
      }

      _showError(errorMessage);
      setState(() {
        _awaitingCallback = false;
        _isInAuthFlow = false;
      });
    } on SignInWithAppleAuthorizationException catch (e) {
      print('❌ Erro no Apple Sign In: ${e.code} - ${e.message}');

      String errorMessage = 'Erro na autenticação com Apple';
      if (e.code == AuthorizationErrorCode.canceled) {
        errorMessage = 'Login cancelado pelo usuário';
      } else if (e.code == AuthorizationErrorCode.failed) {
        errorMessage = 'Falha na autenticação com Apple';
      } else if (e.code == AuthorizationErrorCode.notHandled) {
        errorMessage = 'Operação não suportada';
      }

      _showError(errorMessage);
      setState(() {
        _awaitingCallback = false;
        _isInAuthFlow = false;
      });
    } catch (e) {
      print('❌ Erro geral no Apple Sign In: $e');
      _showError('Erro ao fazer login com Apple');
      setState(() {
        _awaitingCallback = false;
        _isInAuthFlow = false;
      });
    }
  }

  void _handleOpenGoogleAuth(String url) async {
    // Prevenir múltiplas chamadas
    if (_isInAuthFlow) {
      print('⚠️ Google Sign In já está em andamento, ignorando nova chamada');
      return;
    }

    print('Abrindo Google Sign In via Chrome Custom Tabs: $url');
    setState(() {
      _awaitingCallback = true;
      _isInAuthFlow = true;
    });

    try {
      // Usar Chrome Custom Tabs (Android) ou Safari (iOS) - aprovado pelo Google para OAuth
      await launchUrl(
        Uri.parse(url),
        customTabsOptions: CustomTabsOptions(
          colorSchemes: CustomTabsColorSchemes.defaults(
            toolbarColor: Colors.white,
          ),
          shareState: CustomTabsShareState.off,
          urlBarHidingEnabled: true,
          showTitle: true,
        ),
        safariVCOptions: SafariViewControllerOptions(
          preferredBarTintColor: Colors.white,
          preferredControlTintColor: Colors.black,
          barCollapsingEnabled: true,
          dismissButtonStyle: SafariViewControllerDismissButtonStyle.close,
        ),
      );

      print('✅ Google Auth aberto via Custom Tabs');

      // O callback será tratado via deep link
    } catch (e) {
      print('❌ Erro ao abrir Google Auth: $e');
      _showError('Erro ao abrir autenticação do Google');
      setState(() {
        _awaitingCallback = false;
        _isInAuthFlow = false;
      });
    }
  }

  void _handleAuthSuccess(String token, Map<String, dynamic> user) async {
    try {
      // REMOVIDO - não precisamos mais disso
      // O backend vai enviar direto para o React
      print('❌ DEPRECATED: _handleAuthSuccess não deveria ser chamado mais');
      print('Token recebido mas será ignorado - backend -> frontend direto agora');
    } catch (e) {
      print('Erro: $e');
    }
  }

  void _handleCloseWebView() {
    // Finalizar fluxo de autenticação e remover overlay
    setState(() {
      _awaitingCallback = false;
      _isInAuthFlow = false;
    });
    print('Overlay de autenticação removido');
  }

  void _handleLogout() async {
    try {
      await _authService.logout();
      _lastKnownToken = null;
      
      final jsCode = '''
        localStorage.removeItem('access_token');
        localStorage.removeItem('user');
        
        window.postMessage({
          type: 'logoutSuccess',
          source: 'flutter'
        }, '*');
        
        console.log('Flutter: Logout realizado com sucesso');
      ''';
      
      await controller.runJavaScript(jsCode);
      print('Logout realizado com sucesso');
      
      // Recarregar página de login
      controller.loadRequest(Uri.parse('https://icarfront.vercel.app/?source=mobile'));
    } catch (e) {
      print('Erro ao fazer logout: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          WebViewWidget(controller: controller),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
          if (_awaitingCallback && !_isLoading)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      'Processando autenticação...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Serviço de autenticação
class AuthService {
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'auth_token';
  static const _userKey = 'user_data';
  
  late Dio _dio;

  AuthService() {
    _dio = Dio();
    _setupInterceptors();
  }

  void _setupInterceptors() {
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await getToken();
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        options.headers['Accept'] = 'application/json';
        options.headers['Content-Type'] = 'application/json';
        handler.next(options);
      },
      onError: (error, handler) async {
        if (error.response?.statusCode == 401) {
          await logout();
        }
        handler.next(error);
      },
    ));
  }

  Future<bool> isAuthenticated() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
  }

  Future<String?> getToken() async {
    return await _storage.read(key: _tokenKey);
  }

  Future<Map<String, dynamic>?> getUser() async {
    final userJson = await _storage.read(key: _userKey);
    if (userJson != null) {
      return jsonDecode(userJson);
    }
    return null;
  }

  Future<void> saveAuthData(String token, Map<String, dynamic> user) async {
    await _storage.write(key: _tokenKey, value: token);
    await _storage.write(key: _userKey, value: jsonEncode(user));
  }

  Future<void> logout() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userKey);
  }

  Dio get httpClient => _dio;
}