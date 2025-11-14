import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'firebase_options.dart';

// Classe para gerenciar logs de debug
class DebugLogger {
  static final DebugLogger _instance = DebugLogger._internal();
  factory DebugLogger() => _instance;
  DebugLogger._internal();

  final List<LogEntry> _logs = [];
  final int _maxLogs = 1000; // Limitar a 1000 logs para não consumir muita memória
  final StreamController<LogEntry> _logController = StreamController<LogEntry>.broadcast();

  Stream<LogEntry> get logStream => _logController.stream;

  void addLog(String message, {LogLevel level = LogLevel.info}) {
    final entry = LogEntry(
      message: message,
      level: level,
      timestamp: DateTime.now(),
    );

    _logs.add(entry);
    
    // Limitar o número de logs
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }

    _logController.add(entry);
  }

  List<LogEntry> getLogs() => List.unmodifiable(_logs);

  void clearLogs() {
    _logs.clear();
  }

  void dispose() {
    _logController.close();
  }
}

enum LogLevel {
  debug,
  info,
  warning,
  error,
}

class LogEntry {
  final String message;
  final LogLevel level;
  final DateTime timestamp;

  LogEntry({
    required this.message,
    required this.level,
    required this.timestamp,
  });

  Color get color {
    switch (level) {
      case LogLevel.error:
        return Colors.red;
      case LogLevel.warning:
        return Colors.orange;
      case LogLevel.info:
        return Colors.blue;
      case LogLevel.debug:
        return Colors.grey;
    }
  }

  String get levelString {
    switch (level) {
      case LogLevel.error:
        return 'ERROR';
      case LogLevel.warning:
        return 'WARN';
      case LogLevel.info:
        return 'INFO';
      case LogLevel.debug:
        return 'DEBUG';
    }
  }
}

// Função helper para print com logging automático
void debugPrint(Object? object) {
  print(object);
  final message = object.toString();
  LogLevel level = LogLevel.info;
  
  if (message.contains('❌') || message.contains('ERROR') || message.contains('Erro')) {
    level = LogLevel.error;
  } else if (message.contains('⚠️') || message.contains('WARNING') || message.contains('Aviso')) {
    level = LogLevel.warning;
  } else if (message.contains('🔍') || message.contains('DEBUG')) {
    level = LogLevel.debug;
  }
  
  DebugLogger().addLog(message, level: level);
}

// Handler para notificações em background (deve ser top-level)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  print('📱 Notificação em background recebida: ${message.messageId}');
  print('📱 Dados: ${message.data}');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Inicializar Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  
  // Configurar handler de notificações em background
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  
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
      builder: (context, child) {
        // Limitar o escalonamento de fontes no Android para evitar fontes muito grandes
        // No iOS, manter o comportamento padrão
        final mediaQuery = MediaQuery.of(context);
        final textScaleFactor = Platform.isAndroid
            ? mediaQuery.textScaleFactor.clamp(0.8, 1.0) // Limitar entre 0.8 e 1.0 no Android
            : mediaQuery.textScaleFactor; // Manter comportamento padrão no iOS

        return MediaQuery(
          data: mediaQuery.copyWith(textScaleFactor: textScaleFactor),
          child: child!,
        );
      },
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

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  late final WebViewController controller;
  final AuthService _authService = AuthService();
  final PushNotificationService _pushNotificationService = PushNotificationService();
  late AppLinks _appLinks;
  StreamSubscription? _linkSubscription;
  Timer? _locationMonitorTimer;
  Timer? _authMonitorTimer;
  Timer? _emailMonitorTimer;
  Timer? _localStorageMonitorTimer;
  bool _isProcessingLocationRequest = false;
  bool _isLoading = true;
  bool _awaitingCallback = false;
  String? _lastKnownToken;
  bool _isInAuthFlow = false;
  String? _lastAppleAuthUrl;  // Para evitar navegação duplicada
  bool _locationPermissionPermanentlyDenied = false;  // Flag para rastrear permissão permanentemente negada
  bool _hasShownSettingsDialog = false;  // Flag para evitar mostrar diálogo múltiplas vezes
  final Set<String> _processedRequestIds = {};  // Rastrear requestIds já processados para evitar duplicação
  String? _lastRegisteredEmail;  // Rastrear último email registrado para evitar duplicação
  DateTime? _lastApiEmailAttempt;  // Rastrear última tentativa de buscar email via API
  String? _lastAttemptedUserId;  // Rastrear último userId tentado
  DateTime? _lastFcmRegistrationAttempt;  // Rastrear última tentativa de registro FCM
  String? _lastFcmFailedEmail;  // Email que falhou no registro FCM
  DateTime? _firebaseBlockedUntil;  // Timestamp até quando o Firebase está bloqueado
  Timer? _emailListenerDebounceTimer;  // Timer para debounce do listener de email
  String? _pendingEmailRegistration;  // Email pendente de registro (para debounce)
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Solicitar permissão de localização no início do app
    _requestLocationPermission();
    _initWebView();
    _initDeepLinkListener();
    _initPushNotifications();
    _loadEmailFromFlutterStorage();
    _startEmailMonitoring();
    _startLocalStorageMonitoring();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSubscription?.cancel();
    _locationMonitorTimer?.cancel();
    _authMonitorTimer?.cancel();
    _emailMonitorTimer?.cancel();
    _localStorageMonitorTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    // Quando o app volta do background (usuário pode ter voltado das configurações)
    if (state == AppLifecycleState.resumed) {
      print('📱 App voltou para o foreground - verificando permissões novamente');
      // Verificar se as permissões mudaram quando o usuário voltou das configurações
      _checkLocationPermissionAfterReturn();
    }
  }

  Future<void> _checkLocationPermissionAfterReturn() async {
    try {
      // Verificar o status atual da permissão
      final locationStatus = await Permission.location.status;
      print('📱 Status da permissão após retornar: $locationStatus');
      
      // Se a permissão foi concedida, resetar as flags
      if (locationStatus.isGranted) {
        if (_locationPermissionPermanentlyDenied) {
          print('✅ Permissão de localização foi concedida nas configurações!');
          _locationPermissionPermanentlyDenied = false;
          _hasShownSettingsDialog = false;
          _showSuccess('Permissão de localização ativada!');
        }
      } else if (locationStatus.isPermanentlyDenied) {
        // Ainda está negada permanentemente
        _locationPermissionPermanentlyDenied = true;
        print('⚠️ Permissão ainda está permanentemente negada');
      } else {
        // Não está mais permanentemente negada, pode tentar solicitar novamente
        _locationPermissionPermanentlyDenied = false;
        _hasShownSettingsDialog = false;
        print('🔄 Permissão não está mais permanentemente negada, pode tentar novamente');
      }
    } catch (e) {
      print('❌ Erro ao verificar permissão após retornar: $e');
    }
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
            _disablePageZoom();
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

    // Custom Tab será fechado automaticamente pelo Android ao voltar para o app

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

          // Verificar se é novo usuário para redirecionar para perfil
          final isNewUser = user['is_new_user'] == true;
          final targetRoute = isNewUser ? '/perfil' : '/home';

          print('🔄 Redirecionando para: $targetRoute (novo usuário: $isNewUser)');

          // Navegar para rota apropriada após enviar o token
          await Future.delayed(const Duration(milliseconds: 500));
          controller.loadRequest(Uri.parse('https://icarfront.vercel.app$targetRoute?source=mobile'));
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

      // Extrair email do objeto user
      final email = _extractEmailFromUser(user);
      
      // Salvar email no localStorage se disponível
      String emailJsCode = '';
      if (email != null && email.isNotEmpty) {
        emailJsCode = "localStorage.setItem('userEmail', '$email');";
        emailJsCode += "localStorage.setItem('user_email', '$email');";
        emailJsCode += "localStorage.setItem('email', '$email');";
        print('📧 Email extraído do user: $email');
        print('📧 Email será salvo no localStorage como: userEmail, user_email, email');
      } else {
        print('⚠️ Email não encontrado no objeto user');
        print('📧 Objeto user: ${user.toString()}');
      }

      final jsCode = '''
        // Salvar token no localStorage
        localStorage.setItem('access_token', '$token');
        localStorage.setItem('auth_token', '$token');
        localStorage.setItem('authToken', '$token');
        localStorage.setItem('user', '$userJson');
        $emailJsCode

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

      // Registrar token FCM imediatamente após salvar dados de autenticação
      if (email != null && email.isNotEmpty) {
        print('📱 Registrando token FCM imediatamente após login...');
        // Usar um pequeno delay para garantir que o Firebase está pronto
        Future.delayed(const Duration(milliseconds: 500), () {
          _registerPushToken(email);
        });
      } else {
        print('⚠️ Email não encontrado no objeto user, aguardando monitoramento...');
      }

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
        final email = _extractEmailFromUser(user);
        
        // Preparar código para salvar email se disponível
        String emailJsCode = '';
        if (email != null && email.isNotEmpty) {
          emailJsCode = "localStorage.setItem('user_email', '$email');";
          emailJsCode += "localStorage.setItem('email', '$email');";
        }

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
          $emailJsCode

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
        
        // Registrar token FCM se email estiver disponível
        if (email != null && email.isNotEmpty) {
          print('📱 Registrando token FCM após restaurar sessão...');
          Future.delayed(const Duration(milliseconds: 500), () {
            _registerPushToken(email);
          });
        }
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
      
      // Se já está permanentemente negada, não tentar novamente
      if (_locationPermissionPermanentlyDenied) {
        print('⚠️ Permissão já está permanentemente negada, pulando verificação');
        return;
      }
      
      // No iOS, usar Geolocator diretamente é mais confiável
      if (Platform.isIOS) {
        print('🍎 iOS: Verificando permissão via Geolocator...');
        
        // Verificar serviço de localização primeiro
        final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          print('Serviço de localização desabilitado no dispositivo');
          _showError('GPS desabilitado! Por favor, ative o GPS nas configurações do seu dispositivo.');
          return;
        }
        
        // Verificar permissão do Geolocator
        var geoPermission = await Geolocator.checkPermission();
        print('📱 Permissão Geolocator inicial: $geoPermission');
        
        if (geoPermission == LocationPermission.denied || geoPermission == LocationPermission.deniedForever) {
          if (geoPermission == LocationPermission.deniedForever) {
            _locationPermissionPermanentlyDenied = true;
            print('Permissão de localização permanentemente negada');
            if (!_hasShownSettingsDialog) {
              _hasShownSettingsDialog = true;
              await _showOpenSettingsDialog();
            }
            return;
          }
          
          // Solicitar permissão
          print('Solicitando permissão do Geolocator no iOS...');
          geoPermission = await Geolocator.requestPermission();
          print('📱 Permissão Geolocator após solicitação: $geoPermission');
          
          if (geoPermission == LocationPermission.deniedForever) {
            _locationPermissionPermanentlyDenied = true;
            print('Permissão de localização permanentemente negada após solicitação');
            if (!_hasShownSettingsDialog) {
              _hasShownSettingsDialog = true;
              await _showOpenSettingsDialog();
            }
            return;
          }
          
          if (geoPermission == LocationPermission.denied) {
            print('Permissão de localização negada (mas não permanentemente)');
            return;
          }
        }
        
        if (geoPermission == LocationPermission.whileInUse || geoPermission == LocationPermission.always) {
          print('✅ Permissão de localização concedida no iOS');
          _locationPermissionPermanentlyDenied = false;
          return;
        }
      } else {
        // Android: usar permission_handler e Geolocator
        print('🤖 Android: Verificando permissão via permission_handler...');
        
        // Verificar permissão básica de localização
        var locationStatus = await Permission.location.status;
        
        // Atualizar flag se estiver permanentemente negada
        if (locationStatus.isPermanentlyDenied) {
          _locationPermissionPermanentlyDenied = true;
          print('Permissão de localização permanentemente negada');
          if (!_hasShownSettingsDialog) {
            _hasShownSettingsDialog = true;
            await _showOpenSettingsDialog();
          }
          return;
        }
        
        if (!locationStatus.isGranted) {
          final shouldRequest = await _showLocationRationale();
          if (!shouldRequest) {
            print('Usuário cancelou a solicitação de permissão');
            return;
          }
          
          locationStatus = await Permission.location.request();
          
          // Verificar novamente após solicitar
          if (locationStatus.isPermanentlyDenied) {
            _locationPermissionPermanentlyDenied = true;
            print('Permissão de localização permanentemente negada após solicitação');
            if (!_hasShownSettingsDialog) {
              _hasShownSettingsDialog = true;
              await _showOpenSettingsDialog();
            }
            return;
          }
        }
        
        if (locationStatus.isGranted) {
          print('Permissão de localização concedida');
          _locationPermissionPermanentlyDenied = false;
          
          // Verificar se o serviço de localização está habilitado
          final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
          if (!serviceEnabled) {
            print('Serviço de localização desabilitado no dispositivo');
            _showError('GPS desabilitado! Por favor, ative o GPS nas configurações do seu dispositivo.');
            return;
          }
          
          // Verificar permissão do Geolocator especificamente
          final geoPermission = await Geolocator.checkPermission();
          if (geoPermission == LocationPermission.denied) {
            print('Solicitando permissão do Geolocator...');
            final newPermission = await Geolocator.requestPermission();
            if (newPermission == LocationPermission.denied || newPermission == LocationPermission.deniedForever) {
              print('Permissão do Geolocator negada');
              if (newPermission == LocationPermission.deniedForever) {
                _locationPermissionPermanentlyDenied = true;
                if (!_hasShownSettingsDialog) {
                  _hasShownSettingsDialog = true;
                  await _showOpenSettingsDialog();
                }
              } else {
                _showError('Permissão de localização negada. O app precisa dessa permissão para funcionar.');
              }
              return;
            }
          }
          
          print('✅ Todas as permissões de localização concedidas');
        } else if (locationStatus.isDenied) {
          print('Permissão de localização negada (mas não permanentemente)');
          // Não mostrar erro aqui, apenas log - pode ser solicitada novamente depois
        }
      }
    } catch (e) {
      print('Erro ao solicitar permissão de localização: $e');
      _showError('Erro ao verificar permissões de localização: $e');
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
    if (!mounted) return;
    
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Permissão de Localização Necessária'),
          content: const Text(
            'A permissão de localização foi negada permanentemente.\n\n'
            'Para usar este recurso, você precisa habilitar a permissão de localização nas configurações do aplicativo.\n\n'
            'Por favor, abra as configurações e ative a permissão de localização.'
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancelar'),
              onPressed: () {
                Navigator.of(context).pop();
                _hasShownSettingsDialog = false;  // Permitir mostrar novamente depois
              },
            ),
            TextButton(
              child: const Text('Abrir Configurações'),
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
                _hasShownSettingsDialog = false;  // Permitir mostrar novamente depois
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

    // Iniciar timer para verificar requisições de localização
    _locationMonitorTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      if (_isProcessingLocationRequest) return;

      final jsCode = '''
        (function() {
          const request = localStorage.getItem('flutter_location_request');
          if (request) {
            // Remover imediatamente para evitar processamento duplicado
            localStorage.removeItem('flutter_location_request');
            return request;
          }
          return null;
        })();
      ''';

      try {
        final result = await controller.runJavaScriptReturningResult(jsCode);
        final requestStr = result.toString();

        if (requestStr != 'null' && requestStr.isNotEmpty) {
          _handleLocationRequest(requestStr);
        }
      } catch (e) {
        // Erro ao executar JavaScript, ignorar
      }
    });
  }

  Future<void> _handleLocationRequest(String requestJson) async {
    if (_isProcessingLocationRequest) return;

    // Extrair requestId da requisição para devolver na resposta
    String? requestId;
    try {
      final requestData = jsonDecode(requestJson);
      requestId = requestData['requestId']?.toString();
      
      // Verificar se já processamos este requestId (evitar duplicação)
      if (requestId != null && _processedRequestIds.contains(requestId)) {
        print('⚠️ Requisição de localização já processada (ID: $requestId), ignorando...');
        return;
      }
      
      // Adicionar requestId ao conjunto de processados
      if (requestId != null) {
        _processedRequestIds.add(requestId);
        // Limitar o tamanho do conjunto para evitar crescimento infinito (manter últimos 100)
        if (_processedRequestIds.length > 100) {
          final firstId = _processedRequestIds.first;
          _processedRequestIds.remove(firstId);
        }
      }
      
      print('📍 Requisição de localização recebida do React com ID: $requestId');
    } catch (e) {
      print('⚠️ Erro ao parsear requisição, usando sem requestId: $e');
    }

    _isProcessingLocationRequest = true;

    try {
      // No iOS, usar Geolocator diretamente é mais confiável
      if (Platform.isIOS) {
        print('🍎 iOS: Verificando permissão via Geolocator...');
        
        // Verificar serviço de localização primeiro
        final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          print('❌ Serviço de localização desabilitado no dispositivo');
          await _sendLocationError('GPS desabilitado! Por favor, ative o GPS nas configurações do seu dispositivo.', requestId);
          _isProcessingLocationRequest = false;
          return;
        }
        
        // Verificar permissão do Geolocator
        var geoPermission = await Geolocator.checkPermission();
        print('📱 Permissão Geolocator inicial: $geoPermission');
        
        // Se está permanentemente negada, enviar erro e retornar
        if (geoPermission == LocationPermission.deniedForever || _locationPermissionPermanentlyDenied) {
          _locationPermissionPermanentlyDenied = true;
          print('❌ Permissão de localização permanentemente negada - não tentando novamente');
          await _sendLocationError(
            'Permissão de localização negada permanentemente. Por favor, habilite nas configurações do aplicativo.',
            requestId
          );
          if (!_hasShownSettingsDialog && mounted) {
            _hasShownSettingsDialog = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _showOpenSettingsDialog();
            });
          }
          _isProcessingLocationRequest = false;
          return;
        }
        
        // Se não está concedida, solicitar
        if (geoPermission == LocationPermission.denied) {
          print('⚠️ Geolocator sem permissão, solicitando...');
          geoPermission = await Geolocator.requestPermission();
          print('📱 Nova permissão Geolocator: $geoPermission');
          
          if (geoPermission == LocationPermission.deniedForever) {
            _locationPermissionPermanentlyDenied = true;
            print('❌ Permissão de localização ficou permanentemente negada após solicitação');
            await _sendLocationError(
              'Permissão de localização negada permanentemente. Por favor, habilite nas configurações do aplicativo.',
              requestId
            );
            if (!_hasShownSettingsDialog && mounted) {
              _hasShownSettingsDialog = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _showOpenSettingsDialog();
              });
            }
            _isProcessingLocationRequest = false;
            return;
          }
          
          if (geoPermission == LocationPermission.denied) {
            print('❌ Permissão de localização negada pelo usuário');
            await _sendLocationError('Permissão de localização negada', requestId);
            _isProcessingLocationRequest = false;
            return;
          }
        }
        
        // Verificar se tem permissão válida
        if (geoPermission != LocationPermission.whileInUse && geoPermission != LocationPermission.always) {
          print('❌ Permissão de localização não concedida');
          await _sendLocationError('Permissão de localização não concedida', requestId);
          _isProcessingLocationRequest = false;
          return;
        }
        
        print('✅ Permissão de localização concedida no iOS');
      } else {
        // Android: usar permission_handler e Geolocator
        print('🤖 Android: Verificando permissão via permission_handler...');
        
        // Verificar permissão de localização
        var locationStatus = await Permission.location.status;
        print('📱 Status da permissão de localização: $locationStatus');

        // Se está permanentemente negada, enviar erro e retornar sem tentar novamente
        if (locationStatus.isPermanentlyDenied || _locationPermissionPermanentlyDenied) {
          _locationPermissionPermanentlyDenied = true;
          print('❌ Permissão de localização permanentemente negada - não tentando novamente');
          await _sendLocationError(
            'Permissão de localização negada permanentemente. Por favor, habilite nas configurações do aplicativo.',
            requestId
          );
          if (!_hasShownSettingsDialog && mounted) {
            _hasShownSettingsDialog = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _showOpenSettingsDialog();
            });
          }
          _isProcessingLocationRequest = false;
          return;
        }

        if (!locationStatus.isGranted) {
          print('⚠️ Permissão de localização não concedida, solicitando...');
          locationStatus = await Permission.location.request();
          print('📱 Status após solicitar: $locationStatus');
          
          // Verificar novamente se ficou permanentemente negada
          if (locationStatus.isPermanentlyDenied) {
            _locationPermissionPermanentlyDenied = true;
            print('❌ Permissão de localização ficou permanentemente negada após solicitação');
            await _sendLocationError(
              'Permissão de localização negada permanentemente. Por favor, habilite nas configurações do aplicativo.',
              requestId
            );
            if (!_hasShownSettingsDialog && mounted) {
              _hasShownSettingsDialog = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _showOpenSettingsDialog();
              });
            }
            _isProcessingLocationRequest = false;
            return;
          }
        }

        if (!locationStatus.isGranted) {
          print('❌ Permissão de localização negada pelo usuário');
          await _sendLocationError('Permissão de localização negada', requestId);
          _isProcessingLocationRequest = false;
          return;
        }

        // Verificar permissão do Geolocator (importante para Android)
        final geoPermission = await Geolocator.checkPermission();
        print('📱 Permissão Geolocator: $geoPermission');

        if (geoPermission == LocationPermission.denied || geoPermission == LocationPermission.deniedForever) {
          print('⚠️ Geolocator sem permissão, solicitando...');
          final newPermission = await Geolocator.requestPermission();
          print('📱 Nova permissão Geolocator: $newPermission');

          if (newPermission == LocationPermission.denied || newPermission == LocationPermission.deniedForever) {
            print('❌ Permissão Geolocator negada');
            if (newPermission == LocationPermission.deniedForever) {
              _locationPermissionPermanentlyDenied = true;
              await _sendLocationError(
                'Permissão de localização negada permanentemente. Por favor, habilite nas configurações do aplicativo.',
                requestId
              );
              if (!_hasShownSettingsDialog && mounted) {
                _hasShownSettingsDialog = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _showOpenSettingsDialog();
                });
              }
            } else {
              await _sendLocationError('Permissão de localização negada', requestId);
            }
            _isProcessingLocationRequest = false;
            return;
          }
        }
      }

      // Verificar se o serviço de localização está habilitado
      final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      print('📱 Serviço de localização habilitado: $serviceEnabled');

      if (!serviceEnabled) {
        print('❌ Serviço de localização desabilitado no dispositivo');
        _showError('GPS desabilitado! Por favor, ative o GPS nas configurações do seu dispositivo.');
        await _sendLocationError('Serviço de localização desabilitado. Por favor, ative o GPS nas configurações.', requestId);
        return;
      }

      // Verificar se há localização recente disponível
      final bool hasLocation = await Geolocator.isLocationServiceEnabled();
      if (!hasLocation) {
        print('❌ Serviço de localização não disponível');
        _showError('Serviço de localização não disponível no dispositivo');
        await _sendLocationError('Serviço de localização não disponível', requestId);
        return;
      }

      // Obter localização atual
      print('🔍 Obtendo localização atual...');

      final Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 20),
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      );

      print('✅ Localização obtida com sucesso!');
      print('   Latitude: ${position.latitude}');
      print('   Longitude: ${position.longitude}');
      print('   Precisão: ${position.accuracy}m');

      // Não mostrar mensagem de sucesso no iOS para evitar spam (o React já mostra feedback)
      // Apenas mostrar no Android se necessário
      if (Platform.isAndroid) {
        _showSuccess('Localização obtida: ${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}');
      }

      // Enviar resposta de sucesso via JavaScript
      await _sendLocationSuccess(position, requestId);

    } catch (e) {
      print('❌ ERRO ao obter localização: $e');
      print('   Tipo do erro: ${e.runtimeType}');

      String errorMessage = 'Erro ao obter localização';

      // Identificar erro específico
      if (e.toString().contains('PERMISSION_DENIED')) {
        errorMessage = 'Permissão de localização negada';
      } else if (e.toString().contains('LOCATION_DISABLED')) {
        errorMessage = 'Serviço de localização desabilitado';
      } else if (e.toString().contains('TIMEOUT')) {
        errorMessage = 'Tempo esgotado. Tente novamente.';
      } else {
        errorMessage = 'Erro ao obter localização: ${e.toString()}';
      }

      // MOSTRAR ERRO NA TELA para debug (apenas se não for permissão negada permanentemente)
      if (!_locationPermissionPermanentlyDenied) {
        _showError('Erro ao obter localização: ${e.toString().substring(0, e.toString().length > 100 ? 100 : e.toString().length)}');
      }

      await _sendLocationError(errorMessage, requestId);
    } finally {
      _isProcessingLocationRequest = false;
    }
  }

  Future<void> _sendLocationSuccess(Position position, String? requestId) async {
    // Usar o requestId recebido ou gerar um novo se não houver
    final finalRequestId = requestId ?? 'flutter_${DateTime.now().millisecondsSinceEpoch}';

    final response = {
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'requestId': finalRequestId,
      'success': true
    };

    // Enviar via canal JavaScript direto
    await _sendLocationResponseToWebView(response);

    final jsCode = '''
      (function() {
        const response = {
          latitude: ${position.latitude},
          longitude: ${position.longitude},
          accuracy: ${position.accuracy},
          timestamp: ${DateTime.now().millisecondsSinceEpoch},
          requestId: '$finalRequestId',
          success: true
        };
        // Atualizar cache no padrão GeolocationPosition
        window.__flutterLastPosition = {
          coords: {
            latitude: ${position.latitude},
            longitude: ${position.longitude},
            accuracy: ${position.accuracy}
          },
          timestamp: ${DateTime.now().millisecondsSinceEpoch}
        };
        
        // Salvar no localStorage
        localStorage.setItem('flutter_location_response', JSON.stringify(response));
        // Requisição já foi removida no monitoramento, não precisa remover novamente
        
        // Disparar evento customizado para o React escutar
        window.dispatchEvent(new CustomEvent('flutterLocationSuccess', {
          detail: response
        }));
        
        // Também enviar via postMessage
        window.postMessage({
          type: 'flutterLocationSuccess',
          data: response,
          source: 'flutter'
        }, '*');
        
        // Chamar função global se existir
        if (window.onFlutterLocationSuccess) {
          window.onFlutterLocationSuccess(response);
        }
        
        // Chamar função específica para SOS se existir
        if (window.onSOSLocationReceived) {
          window.onSOSLocationReceived(response);
        }
        
        console.log('Flutter: Localização enviada para React via múltiplos canais', response);
      })();
    ''';

    await controller.runJavaScript(jsCode);
  }

  Future<void> _sendLocationError(String errorMessage, String? requestId) async {
    // Usar o requestId recebido ou gerar um novo se não houver
    final finalRequestId = requestId ?? 'flutter_${DateTime.now().millisecondsSinceEpoch}';

    final jsCode = '''
      (function() {
        const response = {
          error: '$errorMessage',
          timestamp: ${DateTime.now().millisecondsSinceEpoch},
          requestId: '$finalRequestId',
          success: false
        };
        
        // Salvar no localStorage
        localStorage.setItem('flutter_location_response', JSON.stringify(response));
        // Requisição já foi removida no monitoramento, não precisa remover novamente
        
        // Disparar evento customizado para o React escutar
        window.dispatchEvent(new CustomEvent('flutterLocationError', {
          detail: response
        }));
        
        // Também enviar via postMessage
        window.postMessage({
          type: 'flutterLocationError',
          data: response,
          source: 'flutter'
        }, '*');
        
        console.log('Flutter: Erro de localização enviado para React via múltiplos canais', response);
      })();
    ''';

    await controller.runJavaScript(jsCode);
  }

  Future<void> _sendLocationResponseToWebView(Map<String, dynamic> response) async {
    try {
      final message = {
        'type': 'locationResponse',
        'data': response,
        'timestamp': DateTime.now().millisecondsSinceEpoch
      };
      
      // Enviar via canal JavaScript
      await controller.runJavaScript('''
        if (window.FlutterWebViewChannel && window.FlutterWebViewChannel.postMessage) {
          window.FlutterWebViewChannel.postMessage(${jsonEncode(message)});
        }
      ''');
      
      print('📤 Resposta de localização enviada via canal JavaScript: ${response['latitude']}, ${response['longitude']}');
    } catch (e) {
      print('❌ Erro ao enviar resposta via canal JavaScript: $e');
    }
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
      
      // Listener para mensagens do Flutter
      window.addEventListener('message', function(event) {
        if (event.data && event.data.type === 'logout') {
          window.FlutterWebViewChannel.postMessage({
            type: 'logout'
          });
        }
      });
      
      // Listener para eventos de localização do Flutter
      window.addEventListener('flutterLocationSuccess', function(event) {
        console.log('React: Evento de localização recebido via CustomEvent', event.detail);
        // Disparar evento global para o React processar
        window.dispatchEvent(new CustomEvent('locationReceived', {
          detail: event.detail
        }));
      });
      
      window.addEventListener('flutterLocationError', function(event) {
        console.log('React: Erro de localização recebido via CustomEvent', event.detail);
        // Disparar evento global para o React processar
        window.dispatchEvent(new CustomEvent('locationError', {
          detail: event.detail
        }));
      });
      
      // Função para solicitar localização do Flutter via canal direto
      window.requestFlutterLocation = function(requestId) {
        const request = {
          requestId: requestId || 'react_' + Date.now(),
          action: 'getCurrentLocation',
          timestamp: Date.now()
        };
        
        console.log('React: Solicitando localização do Flutter via canal direto', request);
        
        // Enviar via canal JavaScript direto
        if (window.FlutterWebViewChannel && window.FlutterWebViewChannel.postMessage) {
          window.FlutterWebViewChannel.postMessage({
            type: 'locationRequest',
            ...request
          });
        }
        
        // Também enviar via localStorage (fallback)
        localStorage.setItem('flutter_location_request', JSON.stringify(request));
        
        // Retornar promise para o React aguardar
        return new Promise((resolve, reject) => {
          const timeout = setTimeout(() => {
            reject(new Error('Timeout na requisição de localização'));
          }, 30000);
          
          const successHandler = (event) => {
            clearTimeout(timeout);
            window.removeEventListener('locationReceived', successHandler);
            window.removeEventListener('locationError', errorHandler);
            resolve(event.detail);
          };
          
          const errorHandler = (event) => {
            clearTimeout(timeout);
            window.removeEventListener('locationReceived', successHandler);
            window.removeEventListener('locationError', errorHandler);
            reject(new Error(event.detail.error || 'Erro desconhecido'));
          };
          
          window.addEventListener('locationReceived', successHandler);
          window.addEventListener('locationError', errorHandler);
        });
      };
      
      // Função específica para SOS
      window.requestSOSLocation = function() {
        console.log('React: Solicitando localização para SOS');
        return window.requestFlutterLocation('sos_' + Date.now());
      };
      
      window.postMessage({
        type: 'flutterReady',
        source: 'flutter'
      }, '*');
      
      console.log('Flutter: Sistema de localização via múltiplos canais ativado');
      
      // Listener para detectar mudanças no localStorage (especialmente para email)
      (function() {
        const originalSetItem = localStorage.setItem;
        const originalRemoveItem = localStorage.removeItem;
        const originalClear = localStorage.clear;
        
        localStorage.setItem = function(key, value) {
          originalSetItem.apply(this, arguments);
          
          // Se for uma chave relacionada a email, notificar o Flutter
          if (key && (key.toLowerCase().includes('email') || key.toLowerCase().includes('user'))) {
            console.log('📧 [Flutter Listener] Email/user salvo no localStorage:', key, value);
            if (window.FlutterWebViewChannel && window.FlutterWebViewChannel.postMessage) {
              window.FlutterWebViewChannel.postMessage({
                type: 'localStorageChanged',
                key: key,
                value: value,
                timestamp: new Date().toISOString()
              });
            }
          }
        };
        
        localStorage.removeItem = function(key) {
          originalRemoveItem.apply(this, arguments);
          
          if (key && (key.toLowerCase().includes('email') || key.toLowerCase().includes('user'))) {
            console.log('📧 [Flutter Listener] Email/user removido do localStorage:', key);
            if (window.FlutterWebViewChannel && window.FlutterWebViewChannel.postMessage) {
              window.FlutterWebViewChannel.postMessage({
                type: 'localStorageChanged',
                key: key,
                value: null,
                action: 'removed',
                timestamp: new Date().toISOString()
              });
            }
          }
        };
        
        localStorage.clear = function() {
          originalClear.apply(this, arguments);
          console.log('📧 [Flutter Listener] localStorage limpo');
          if (window.FlutterWebViewChannel && window.FlutterWebViewChannel.postMessage) {
            window.FlutterWebViewChannel.postMessage({
              type: 'localStorageChanged',
              action: 'cleared',
              timestamp: new Date().toISOString()
            });
          }
        };
        
        // Também monitorar sessionStorage
        const originalSessionSetItem = sessionStorage.setItem;
        sessionStorage.setItem = function(key, value) {
          originalSessionSetItem.apply(this, arguments);
          
          if (key && (key.toLowerCase().includes('email') || key.toLowerCase().includes('user'))) {
            console.log('📧 [Flutter Listener] Email/user salvo no sessionStorage:', key, value);
            if (window.FlutterWebViewChannel && window.FlutterWebViewChannel.postMessage) {
              window.FlutterWebViewChannel.postMessage({
                type: 'sessionStorageChanged',
                key: key,
                value: value,
                timestamp: new Date().toISOString()
              });
            }
          }
        };
      })();
      
      // Função para testar localização
      window.testLocation = function() {
        console.log('Testando localização...');
        return window.requestFlutterLocation('test_' + Date.now());
      };
      
      // Função de debug para verificar comunicação
      window.debugLocationCommunication = function() {
        console.log('=== DEBUG COMUNICAÇÃO DE LOCALIZAÇÃO ===');
        console.log('FlutterWebViewChannel disponível:', !!window.FlutterWebViewChannel);
        console.log('FlutterWebView disponível:', !!window.FlutterWebView);
        console.log('requestFlutterLocation disponível:', !!window.requestFlutterLocation);
        console.log('requestSOSLocation disponível:', !!window.requestSOSLocation);
        console.log('testLocation disponível:', !!window.testLocation);
        
        // Testar envio de mensagem
        if (window.FlutterWebViewChannel) {
          window.FlutterWebViewChannel.postMessage({
            type: 'testCommunication',
            message: 'Teste de comunicação Flutter-React',
            timestamp: Date.now()
          });
          console.log('Mensagem de teste enviada via canal JavaScript');
        }
        
        console.log('=== FIM DEBUG ===');
      };

      // Polyfill de Geolocalização: integra coordenadas do Flutter na API Web
      (function() {
        if (!navigator.geolocation) return;
        if (navigator.__flutterGeoPolyfilled) return;
        navigator.__flutterGeoPolyfilled = true;

        const original = navigator.geolocation;

        function toGeoPosition(res) {
          // Converte resposta do Flutter no formato esperado pela Web API
          return {
            coords: {
              latitude: res && res.latitude != null ? res.latitude : (window.__flutterLastPosition && window.__flutterLastPosition.coords.latitude),
              longitude: res && res.longitude != null ? res.longitude : (window.__flutterLastPosition && window.__flutterLastPosition.coords.longitude),
              accuracy: res && res.accuracy != null ? res.accuracy : (window.__flutterLastPosition && window.__flutterLastPosition.coords.accuracy)
            },
            timestamp: (res && res.timestamp) || (window.__flutterLastPosition && window.__flutterLastPosition.timestamp) || Date.now()
          };
        }

        navigator.geolocation.getCurrentPosition = function(success, error, options) {
          try {
            if (window.__flutterLastPosition) {
              success && success(toGeoPosition());
              return;
            }
            window.requestFlutterLocation('geo_' + Date.now())
              .then(function(res) { success && success(toGeoPosition(res)); })
              .catch(function(err) { error && error({ code: 1, message: err && err.message || 'Location error' }); });
          } catch (e) {
            try { original.getCurrentPosition && original.getCurrentPosition(success, error, options); } catch (_) {}
          }
        };

        let __watchIdSeq = 1;
        const __watchers = {};
        navigator.geolocation.watchPosition = function(success, error, options) {
          const id = __watchIdSeq++;
          // Emitir imediatamente se houver cache
          if (window.__flutterLastPosition) {
            try { success && success(toGeoPosition()); } catch (_) {}
          }
          // Solicitar uma atualização única como fallback
          window.requestFlutterLocation('watch_' + id)
            .then(function(res) { success && success(toGeoPosition(res)); })
            .catch(function(err) { error && error({ code: 1, message: err && err.message || 'Location error' }); });
          __watchers[id] = true;
          return id;
        };

        navigator.geolocation.clearWatch = function(id) {
          delete __watchers[id];
        };

        console.log('Flutter: Polyfill de geolocalização instalado');
      })();
    ''';
    
    controller.runJavaScript(jsCode);
  }

  void _disablePageZoom() {
    const js = '''
      (function() {
        try {
          var head = document.head || document.getElementsByTagName('head')[0];
          var meta = document.querySelector('meta[name="viewport"]');
          var content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
          if (meta) {
            meta.setAttribute('content', content);
          } else if (head) {
            meta = document.createElement('meta');
            meta.setAttribute('name', 'viewport');
            meta.setAttribute('content', content);
            head.appendChild(meta);
          }

          // Bloquear pinch/double-tap zoom (especialmente no iOS)
          ['gesturestart','gesturechange','gestureend'].forEach(function(evt) {
            document.addEventListener(evt, function(e){ e.preventDefault(); }, { passive: false });
          });

          // Evitar zoom com Ctrl + scroll
          window.addEventListener('wheel', function(e){ if (e.ctrlKey) e.preventDefault(); }, { passive: false });

          // Reduzir chances de double-tap zoom
          if (document.documentElement && document.documentElement.style) {
            document.documentElement.style.touchAction = 'manipulation';
          }
          if (document.body && document.body.style) {
            document.body.style.touchAction = 'manipulation';
          }
        } catch (e) {
          console.log('Flutter: erro ao desabilitar zoom', e);
        }
      })();
    ''';
    controller.runJavaScript(js);
  }


  // Monitorar localStorage da WebView e printar valores
  void _startLocalStorageMonitoring() {
    _localStorageMonitorTimer?.cancel();
    
    print('📦 Iniciando monitoramento do localStorage (a cada 5 segundos)');
    
    // Verificar localStorage a cada 5 segundos
    _localStorageMonitorTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      try {
        final jsCode = '''
          (function() {
            try {
              const allItems = {};
              // Ler todas as chaves do localStorage
              for (let i = 0; i < localStorage.length; i++) {
                const key = localStorage.key(i);
                if (key) {
                  allItems[key] = localStorage.getItem(key);
                }
              }
              return JSON.stringify(allItems);
            } catch(e) {
              return JSON.stringify({error: e.toString()});
            }
          })();
        ''';

        final result = await controller.runJavaScriptReturningResult(jsCode);
        String resultStr = result.toString().trim();
        
        // Remover aspas extras se houver
        if (resultStr.startsWith('"') && resultStr.endsWith('"')) {
          resultStr = resultStr.substring(1, resultStr.length - 1);
        }
        resultStr = resultStr.replaceAll('\\"', '"');
        
        try {
          final Map<String, dynamic> localStorageData = jsonDecode(resultStr);
          
          // Só imprimir se houver mudanças ou a cada 6 ciclos (30 segundos)
          if (timer.tick % 6 == 0 || localStorageData.isNotEmpty) {
            print('📦 === localStorage da WebView (Ciclo ${timer.tick}) ===');
            print('📦 Total de itens: ${localStorageData.length}');
            
            if (localStorageData.isEmpty) {
              print('📦 ⚠️ localStorage está VAZIO!');
            } else {
              localStorageData.forEach((key, value) {
                // Truncar valores muito longos para melhor visualização
                String displayValue = value.toString();
                if (displayValue.length > 100) {
                  displayValue = '${displayValue.substring(0, 100)}... (${displayValue.length} chars)';
                }
                
                // Destacar chaves importantes
                if (key.contains('email') || key.contains('Email') || 
                    key.contains('fcm') || key.contains('FCM') ||
                    key.contains('token') || key.contains('Token')) {
                  print('  ⭐ $key: $displayValue');
                } else {
                  print('  $key: $displayValue');
                }
              });
            }
            print('📦 === Fim do localStorage ===');
          }
        } catch (e) {
          print('⚠️ Erro ao parsear localStorage: $e');
          print('📦 localStorage raw: $resultStr');
        }
      } catch (e) {
        print('❌ Erro ao monitorar localStorage: $e');
        debugPrint('Erro detalhado: ${e.toString()}');
      }
    });
  }


  void _handleWebViewMessage(String message) {
    final debugLogger = DebugLogger();
    
    try {
      final Map<String, dynamic> data = jsonDecode(message);
      final String type = data['type'] ?? '';
      
      // Processar mudanças no localStorage/sessionStorage
      if (type == 'localStorageChanged' || type == 'sessionStorageChanged') {
        final key = data['key']?.toString();
        final value = data['value']?.toString();
        final action = data['action']?.toString();
        final timestamp = data['timestamp']?.toString();
        
        debugLogger.addLog('📧 [Listener] Mudança detectada no ${type == "localStorageChanged" ? "localStorage" : "sessionStorage"}: key=$key, action=${action ?? "set"}, value=${value != null && value.length > 30 ? value.substring(0, 30) + "..." : value}', level: LogLevel.info);
        print('📧 [DEBUG] [Listener] Mudança detectada no ${type == "localStorageChanged" ? "localStorage" : "sessionStorage"}:');
        print('   Key: $key');
        print('   Action: ${action ?? "set"}');
        print('   Value: ${value != null && value.length > 50 ? value.substring(0, 50) + "..." : value}');
        print('   Timestamp: $timestamp');
        
        // Se for uma chave de email e tiver um valor válido, verificar se precisa registrar FCM token
        if (key != null && 
            (key.toLowerCase().contains('email') || key.toLowerCase().contains('user')) &&
            value != null && 
            value.isNotEmpty && 
            value != 'null' &&
            value.contains('@') &&
            action != 'removed') {
          
          debugLogger.addLog('📧 [Listener] Email válido detectado: $value', level: LogLevel.info);
          print('📧 [DEBUG] [Listener] Email válido detectado: $value');
          
          // Salvar email no SharedPreferences do Flutter (fire and forget)
          _saveEmailToFlutterStorage(value).catchError((e) {
            print('❌ Erro ao salvar email no SharedPreferences: $e');
          });
          
          // Cancelar timer anterior se existir
          _emailListenerDebounceTimer?.cancel();
          
          // Armazenar email pendente
          _pendingEmailRegistration = value;
          
          // Aguardar 2 segundos antes de tentar registrar (debounce para evitar múltiplas chamadas)
          _emailListenerDebounceTimer = Timer(const Duration(seconds: 2), () async {
            if (_pendingEmailRegistration != null) {
              final emailToRegister = _pendingEmailRegistration!;
              _pendingEmailRegistration = null;
              
              // Verificar se o token FCM já está registrado
              try {
                final checkTokenJsCode = '''
                  (function() {
                    const fcmToken = localStorage.getItem('fcm_token') || localStorage.getItem('fcmToken');
                    const fcmLastUpdate = localStorage.getItem('fcm_last_update');
                    return JSON.stringify({
                      hasToken: !!fcmToken,
                      tokenLength: fcmToken ? fcmToken.length : 0,
                      lastUpdate: fcmLastUpdate
                    });
                  })();
                ''';
                
                final checkResult = await controller.runJavaScriptReturningResult(checkTokenJsCode);
                String checkStr = checkResult.toString().trim();
                if (checkStr.startsWith('"') && checkStr.endsWith('"')) {
                  checkStr = checkStr.substring(1, checkStr.length - 1);
                }
                checkStr = checkStr.replaceAll('\\"', '"');
                
                final checkData = jsonDecode(checkStr);
                final hasToken = checkData['hasToken'] == true;
                
                if (hasToken) {
                  debugLogger.addLog('✅ Token FCM já está registrado para $emailToRegister - ignorando', level: LogLevel.info);
                  print('✅ [DEBUG] [Listener] Token FCM já está registrado para $emailToRegister - ignorando');
                  return;
                }
              } catch (e) {
                print('⚠️ [DEBUG] [Listener] Erro ao verificar token FCM: $e');
              }
              
              debugLogger.addLog('📧 [Listener] Token FCM não encontrado - tentando registrar para: $emailToRegister', level: LogLevel.info);
              print('📧 [DEBUG] [Listener] Token FCM não encontrado - tentando registrar para: $emailToRegister');
              
              await _registerPushToken(emailToRegister);
            }
          });
        }
        return;
      }
      
      // Continuar com o processamento normal de outras mensagens
      print('Mensagem recebida do WebView: $message');

      if (type == 'logout') {
        print('Processando logout...');
        _handleLogout();
      } else if (type == 'openAppleAuth') {
        print('Abrindo Apple Sign In no navegador externo...');
        _handleOpenAppleAuth(data['url']);
      } else if (type == 'locationRequest') {
        print('Requisição de localização recebida via canal JavaScript');
        final requestId = data['requestId']?.toString();
        _handleLocationRequest(jsonEncode(data));
      } else if (type == 'testLocation') {
        print('Teste de localização solicitado via canal JavaScript');
        _handleLocationRequest(jsonEncode({
          'requestId': 'test_${DateTime.now().millisecondsSinceEpoch}',
          'action': 'getCurrentLocation'
        }));
      } else if (type == 'openGoogleAuth') {
        print('Abrindo Google Sign In no navegador externo...');
        _handleOpenGoogleAuth(data['url']);
      } else if (type == 'authSuccess') {
        print('✅ Autenticação bem-sucedida!');
        _handleAuthSuccess(data['token'], data['user']);
      } else if (type == 'closeWebView') {
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

        // Verificar se é novo usuário para redirecionar para perfil
        final isNewUser = user['is_new_user'] == true;
        final targetRoute = isNewUser ? '/perfil' : '/home';

        print('🔄 Redirecionando para: $targetRoute (novo usuário: $isNewUser)');

        // Navegar para rota apropriada após sucesso
        await Future.delayed(const Duration(milliseconds: 500));
        controller.loadRequest(Uri.parse('https://icarfront.vercel.app$targetRoute?source=mobile'));
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
      _lastRegisteredEmail = null; // Limpar email registrado ao fazer logout
      _lastFcmFailedEmail = null; // Limpar email que falhou
      _firebaseBlockedUntil = null; // Limpar bloqueio do Firebase
      _lastFcmRegistrationAttempt = null; // Limpar tentativa de registro
      
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

  // Inicializar push notifications
  Future<void> _initPushNotifications() async {
    try {
      // Inicializar notificações locais
      await _initializeLocalNotifications();
      
      // Solicitar permissão de notificações
      final messaging = FirebaseMessaging.instance;
      
      NotificationSettings settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      print('📱 Permissão de notificações: ${settings.authorizationStatus}');

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        print('✅ Permissão de notificações concedida');
      } else if (settings.authorizationStatus == AuthorizationStatus.provisional) {
        print('⚠️ Permissão provisória de notificações');
      } else {
        print('❌ Permissão de notificações negada');
      }

      // Configurar handlers de notificações
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        print('📱 Notificação recebida em foreground: ${message.messageId}');
        print('📱 Título: ${message.notification?.title}');
        print('📱 Corpo: ${message.notification?.body}');
        print('📱 Dados: ${message.data}');
        
        // Exibir notificação local quando o app está em foreground
        _showLocalNotification(message);
      });

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        print('📱 Notificação aberta: ${message.messageId}');
        print('📱 Dados: ${message.data}');
      });

      // Verificar se o app foi aberto por uma notificação
      RemoteMessage? initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        print('📱 App aberto por notificação: ${initialMessage.messageId}');
      }
    } catch (e) {
      print('❌ Erro ao inicializar push notifications: $e');
    }
  }

  // Inicializar notificações locais
  Future<void> _initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        print('📱 Notificação local clicada: ${response.id}');
        print('📱 Payload: ${response.payload}');
      },
    );

    // Criar canal de notificação para Android
    if (Platform.isAndroid) {
      const androidChannel = AndroidNotificationChannel(
        'high_importance_channel',
        'Notificações Importantes',
        description: 'Este canal é usado para notificações importantes',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      );

      await _localNotifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidChannel);
    }
  }

  // Exibir notificação local
  Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    const androidDetails = AndroidNotificationDetails(
      'high_importance_channel',
      'Notificações Importantes',
      channelDescription: 'Este canal é usado para notificações importantes',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      playSound: true,
      enableVibration: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localNotifications.show(
      message.hashCode,
      notification.title ?? 'Nova notificação',
      notification.body ?? '',
      details,
      payload: message.data.toString(),
    );
  }

  // Carregar email do SharedPreferences ao iniciar
  Future<void> _loadEmailFromFlutterStorage() async {
    try {
      final email = await _getEmailFromFlutterStorage();
      if (email != null && email.isNotEmpty && email.contains('@')) {
        print('📖 [Flutter Storage] Email carregado do SharedPreferences: $email');
        final debugLogger = DebugLogger();
        debugLogger.addLog('📖 [Flutter Storage] Email carregado do SharedPreferences: $email', level: LogLevel.info);
        
        // Salvar também no localStorage da WebView para manter sincronizado
        final escapedEmail = email.replaceAll("'", "\\'").replaceAll('"', '\\"');
        final saveEmailJsCode = '''
          (function() {
            try {
              localStorage.setItem('userEmail', '$escapedEmail');
              sessionStorage.setItem('userEmail', '$escapedEmail');
              console.log('✅ Email restaurado do Flutter Storage para WebView: $escapedEmail');
              return 'saved';
            } catch(e) {
              console.error('❌ Erro ao restaurar email:', e);
              return 'error: ' + e.toString();
            }
          })();
        ''';
        
        await controller.runJavaScriptReturningResult(saveEmailJsCode);
      }
    } catch (e) {
      print('❌ Erro ao carregar email do SharedPreferences: $e');
    }
  }

  // Monitorar email no localStorage do WebView
  void _startEmailMonitoring() {
    _emailMonitorTimer?.cancel();
    
    final debugLogger = DebugLogger();
    debugLogger.addLog('🔍 Iniciando monitoramento de email no localStorage (a cada 5 segundos)', level: LogLevel.info);
    print('🔍 [DEBUG] Iniciando monitoramento de email no localStorage (a cada 5 segundos)');
    
    // Verificar email a cada 5 segundos
    _emailMonitorTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      try {
        debugLogger.addLog('🔍 [Ciclo ${timer.tick}] Verificando email no localStorage...', level: LogLevel.debug);
        
        final jsCode = '''
          (function() {
            // Tentar obter email de várias fontes possíveis no localStorage E sessionStorage
            const email = localStorage.getItem('userEmail') || 
                         sessionStorage.getItem('userEmail') ||
                         localStorage.getItem('user_email') || 
                         sessionStorage.getItem('user_email') ||
                         localStorage.getItem('email') || 
                         sessionStorage.getItem('email') ||
                         (() => {
                           try {
                             const user = localStorage.getItem('user') || sessionStorage.getItem('user');
                             if (user) {
                               const userObj = JSON.parse(user);
                               return userObj.email || userObj.user_email || userObj.userEmail || null;
                             }
                           } catch(e) {
                             console.error('Erro ao parsear user:', e);
                           }
                           return null;
                         })();
            // Obter timestamp da última atualização do FCM
            const lastUpdate = localStorage.getItem('fcm_last_update');
            const fcmToken = localStorage.getItem('fcm_token') || localStorage.getItem('fcmToken');
            
            // Obter todas as chaves do localStorage e sessionStorage para debug
            // Filtrar métodos nativos que não são chaves válidas
            const allLocalKeys = Object.keys(localStorage).filter(key => 
              key !== 'setItem' && 
              key !== 'removeItem' && 
              key !== 'clear' && 
              key !== 'getItem' && 
              key !== 'key' && 
              key !== 'length'
            );
            const allSessionKeys = Object.keys(sessionStorage).filter(key => 
              key !== 'setItem' && 
              key !== 'removeItem' && 
              key !== 'clear' && 
              key !== 'getItem' && 
              key !== 'key' && 
              key !== 'length'
            );
            const allKeys = [...new Set([...allLocalKeys, ...allSessionKeys])];
            
            const emailSources = {
              localStorage: {
                userEmail: localStorage.getItem('userEmail'),
                user_email: localStorage.getItem('user_email'),
                email: localStorage.getItem('email'),
                user: localStorage.getItem('user')
              },
              sessionStorage: {
                userEmail: sessionStorage.getItem('userEmail'),
                user_email: sessionStorage.getItem('user_email'),
                email: sessionStorage.getItem('email'),
                user: sessionStorage.getItem('user')
              }
            };
            
            // Obter valores completos de todas as chaves relacionadas a email
            const allEmailValues = {};
            allLocalKeys.forEach(key => {
              if (key.toLowerCase().includes('email') || key.toLowerCase().includes('user')) {
                const value = localStorage.getItem(key);
                allEmailValues['localStorage.' + key] = value ? (value.length > 50 ? value.substring(0, 50) + '...' : value) : null;
              }
            });
            allSessionKeys.forEach(key => {
              if (key.toLowerCase().includes('email') || key.toLowerCase().includes('user')) {
                const value = sessionStorage.getItem(key);
                allEmailValues['sessionStorage.' + key] = value ? (value.length > 50 ? value.substring(0, 50) + '...' : value) : null;
              }
            });
            
            return JSON.stringify({
              email: email,
              lastUpdate: lastUpdate,
              hasFcmToken: !!fcmToken,
              localStorageKeys: allLocalKeys,
              sessionStorageKeys: allSessionKeys,
              allKeys: allKeys,
              emailSources: emailSources,
              allEmailValues: allEmailValues,
              localStorageSize: allLocalKeys.length,
              sessionStorageSize: allSessionKeys.length,
              timestamp: new Date().toISOString()
            });
          })();
        ''';

        debugLogger.addLog('🔍 [Ciclo ${timer.tick}] Executando JavaScript para ler localStorage...', level: LogLevel.debug);
        print('🔍 [DEBUG] [Ciclo ${timer.tick}] Executando JavaScript para ler localStorage...');
        
        final result = await controller.runJavaScriptReturningResult(jsCode);
        String resultStr = result.toString().trim();
        
        debugLogger.addLog('📦 [Ciclo ${timer.tick}] Resultado raw do JavaScript: ${resultStr.length > 200 ? resultStr.substring(0, 200) + "..." : resultStr}', level: LogLevel.debug);
        print('🔍 [DEBUG] [Ciclo ${timer.tick}] Resultado raw do JavaScript: $resultStr');
        
        // Remover aspas extras se houver
        if (resultStr.startsWith('"') && resultStr.endsWith('"')) {
          resultStr = resultStr.substring(1, resultStr.length - 1);
        }
        // Remover escape de aspas
        resultStr = resultStr.replaceAll('\\"', '"');
        
        // Parse do resultado JSON
        Map<String, dynamic>? data;
        try {
          data = jsonDecode(resultStr);
          debugLogger.addLog('✅ [Ciclo ${timer.tick}] JSON parseado com sucesso', level: LogLevel.debug);
          print('🔍 [DEBUG] [Ciclo ${timer.tick}] JSON parseado com sucesso');
        } catch (e) {
          debugLogger.addLog('❌ [Ciclo ${timer.tick}] Erro ao parsear resultado do monitoramento: $e', level: LogLevel.error);
          debugLogger.addLog('📦 [Ciclo ${timer.tick}] Resultado raw (primeiros 500 chars): ${resultStr.length > 500 ? resultStr.substring(0, 500) + "..." : resultStr}', level: LogLevel.error);
          print('⚠️ [DEBUG] [Ciclo ${timer.tick}] Erro ao parsear resultado do monitoramento: $e');
          print('📦 [DEBUG] [Ciclo ${timer.tick}] Resultado raw: $resultStr');
          return;
        }
        
        final email = data?['email']?.toString().trim();
        final lastUpdateStr = data?['lastUpdate']?.toString();
        final hasFcmToken = data?['hasFcmToken'] == true;
        final localKeys = data?['localStorageKeys'] as List<dynamic>?;
        final sessionKeys = data?['sessionStorageKeys'] as List<dynamic>?;
        final allKeys = data?['allKeys'] as List<dynamic>?;
        final emailSources = data?['emailSources'] as Map<String, dynamic>?;
        final allEmailValues = data?['allEmailValues'] as Map<String, dynamic>?;
        final localStorageSize = data?['localStorageSize'] as int?;
        final sessionStorageSize = data?['sessionStorageSize'] as int?;
        final timestamp = data?['timestamp']?.toString();
        
        // Se não encontrou email mas tem userId no sessionStorage, tentar buscar email via API
        String? emailToUse = email;
        if ((emailToUse == null || emailToUse.isEmpty || emailToUse == 'null' || !emailToUse.contains('@')) && 
            sessionKeys != null) {
          // Procurar userId no sessionStorage
          final userId = sessionKeys.contains('userId') || sessionKeys.contains('idUser') || sessionKeys.contains('user_id');
          if (userId) {
            debugLogger.addLog('🔍 [Ciclo ${timer.tick}] Email não encontrado, mas userId presente no sessionStorage - tentando buscar email via API', level: LogLevel.info);
            print('🔍 [DEBUG] [Ciclo ${timer.tick}] Email não encontrado, mas userId presente no sessionStorage');
            print('🔍 [DEBUG] [Ciclo ${timer.tick}] Tentando buscar email via API usando userId...');
            
            // Buscar userId do sessionStorage
            try {
              final userIdJsCode = '''
                (function() {
                  return sessionStorage.getItem('userId') || 
                         sessionStorage.getItem('idUser') || 
                         sessionStorage.getItem('user_id') || 
                         null;
                })();
              ''';
              
              final userIdResult = await controller.runJavaScriptReturningResult(userIdJsCode);
              String userIdStr = userIdResult.toString().trim();
              
              if (userIdStr.startsWith('"') && userIdStr.endsWith('"')) {
                userIdStr = userIdStr.substring(1, userIdStr.length - 1);
              }
              
              if (userIdStr.isNotEmpty && userIdStr != 'null') {
                // Verificar se já tentamos buscar este userId recentemente (evitar muitas requisições)
                final now = DateTime.now();
                final shouldTryApi = _lastApiEmailAttempt == null || 
                                   _lastAttemptedUserId != userIdStr ||
                                   now.difference(_lastApiEmailAttempt!).inMinutes >= 5;
                
                if (!shouldTryApi) {
                  final minutesSinceLastAttempt = now.difference(_lastApiEmailAttempt!).inMinutes;
                  debugLogger.addLog('⏰ [Ciclo ${timer.tick}] Tentativa de API recente (há ${minutesSinceLastAttempt}m) - aguardando 5 minutos', level: LogLevel.debug);
                  print('⏰ [DEBUG] [Ciclo ${timer.tick}] Tentativa de API recente (há ${minutesSinceLastAttempt}m) - aguardando 5 minutos');
                } else {
                  debugLogger.addLog('🔍 [Ciclo ${timer.tick}] userId encontrado: $userIdStr - Buscando email via API', level: LogLevel.info);
                  print('🔍 [DEBUG] [Ciclo ${timer.tick}] userId encontrado: $userIdStr');
                  
                  // Atualizar controle de tentativas
                  _lastApiEmailAttempt = now;
                  _lastAttemptedUserId = userIdStr;
                  
                  // Buscar email via API usando o token do sessionStorage
                  try {
                  // Primeiro tentar obter token do sessionStorage (mais confiável que AuthService)
                  final tokenJsCode = '''
                    (function() {
                      return sessionStorage.getItem('auth_token') || 
                             sessionStorage.getItem('authToken') || 
                             sessionStorage.getItem('token') || 
                             localStorage.getItem('auth_token') || 
                             localStorage.getItem('authToken') || 
                             null;
                    })();
                  ''';
                  
                  final tokenResult = await controller.runJavaScriptReturningResult(tokenJsCode);
                  String? appToken = tokenResult.toString().trim();
                  
                  if (appToken.startsWith('"') && appToken.endsWith('"')) {
                    appToken = appToken.substring(1, appToken.length - 1);
                  }
                  
                  if (appToken.isEmpty || appToken == 'null') {
                    appToken = null;
                  }
                  
                  debugLogger.addLog('🔍 [Ciclo ${timer.tick}] Token obtido: ${appToken != null ? "SIM (${appToken.length} chars)" : "NÃO"}', level: LogLevel.debug);
                  print('🔍 [DEBUG] [Ciclo ${timer.tick}] Token obtido: ${appToken != null ? "SIM (${appToken.length} chars)" : "NÃO"}');
                  
                  final dio = Dio();
                  dio.options.baseUrl = 'https://icar.skalacode.com';
                  dio.options.headers['Accept'] = 'application/json';
                  dio.options.headers['Content-Type'] = 'application/json';
                  
                  if (appToken != null) {
                    dio.options.headers['Authorization'] = 'Bearer $appToken';
                    debugLogger.addLog('🔍 [Ciclo ${timer.tick}] Fazendo requisição autenticada para /api/user', level: LogLevel.info);
                    print('🔍 [DEBUG] [Ciclo ${timer.tick}] Fazendo requisição autenticada para /api/user');
                  } else {
                    debugLogger.addLog('⚠️ [Ciclo ${timer.tick}] Token não encontrado, tentando requisição sem autenticação', level: LogLevel.warning);
                    print('⚠️ [DEBUG] [Ciclo ${timer.tick}] Token não encontrado, tentando requisição sem autenticação');
                  }
                  
                  debugLogger.addLog('🔍 [Ciclo ${timer.tick}] Fazendo requisição GET para /api/perfil...', level: LogLevel.info);
                  print('🔍 [DEBUG] [Ciclo ${timer.tick}] Fazendo requisição GET para /api/perfil...');
                  
                  final response = await dio.get('/api/perfil');
                  
                  debugLogger.addLog('📥 [Ciclo ${timer.tick}] Resposta da API: status=${response.statusCode}', level: LogLevel.info);
                  print('📥 [DEBUG] [Ciclo ${timer.tick}] Resposta da API: status=${response.statusCode}');
                  
                  if (response.statusCode == 200 && response.data != null) {
                    final userData = response.data;
                    debugLogger.addLog('📋 [Ciclo ${timer.tick}] Dados do usuário recebidos: ${userData.toString().length > 100 ? userData.toString().substring(0, 100) + "..." : userData.toString()}', level: LogLevel.debug);
                    print('📋 [DEBUG] [Ciclo ${timer.tick}] Dados do usuário recebidos: $userData');
                    
                    final userEmail = userData['email']?.toString() ?? 
                                    userData['user_email']?.toString() ?? 
                                    userData['e_mail']?.toString();
                    
                    debugLogger.addLog('📧 [Ciclo ${timer.tick}] Email extraído dos dados: ${userEmail ?? "NENHUM"}', level: LogLevel.info);
                    print('📧 [DEBUG] [Ciclo ${timer.tick}] Email extraído dos dados: ${userEmail ?? "NENHUM"}');
                    
                    if (userEmail != null && userEmail.isNotEmpty && userEmail.contains('@')) {
                      debugLogger.addLog('✅ [Ciclo ${timer.tick}] Email encontrado via API: $userEmail', level: LogLevel.info);
                      print('✅ [DEBUG] [Ciclo ${timer.tick}] Email encontrado via API: $userEmail');
                      
                      // Salvar email no localStorage para uso futuro
                      final escapedEmail = userEmail.replaceAll("'", "\\'").replaceAll('"', '\\"');
                      final saveEmailJsCode = '''
                        (function() {
                          try {
                            localStorage.setItem('userEmail', '$escapedEmail');
                            sessionStorage.setItem('userEmail', '$escapedEmail');
                            console.log('✅ Email salvo no localStorage e sessionStorage: $escapedEmail');
                            return 'saved';
                          } catch(e) {
                            console.error('❌ Erro ao salvar email:', e);
                            return 'error: ' + e.toString();
                          }
                        })();
                      ''';
                      
                      debugLogger.addLog('💾 [Ciclo ${timer.tick}] Salvando email no localStorage e sessionStorage...', level: LogLevel.info);
                      print('💾 [DEBUG] [Ciclo ${timer.tick}] Salvando email no localStorage e sessionStorage...');
                      
                      final saveResult = await controller.runJavaScriptReturningResult(saveEmailJsCode);
                      debugLogger.addLog('💾 [Ciclo ${timer.tick}] Resultado do salvamento: $saveResult', level: LogLevel.info);
                      print('💾 [DEBUG] [Ciclo ${timer.tick}] Resultado do salvamento: $saveResult');
                      
                      // Salvar email no SharedPreferences do Flutter
                      await _saveEmailToFlutterStorage(userEmail);
                      
                      emailToUse = userEmail;
                    } else {
                      debugLogger.addLog('⚠️ [Ciclo ${timer.tick}] Email extraído é inválido: "$userEmail"', level: LogLevel.warning);
                      print('⚠️ [DEBUG] [Ciclo ${timer.tick}] Email extraído é inválido: "$userEmail"');
                    }
                  } else {
                    debugLogger.addLog('⚠️ [Ciclo ${timer.tick}] Resposta da API inválida: status=${response.statusCode}, data=${response.data}', level: LogLevel.warning);
                    print('⚠️ [DEBUG] [Ciclo ${timer.tick}] Resposta da API inválida: status=${response.statusCode}, data=${response.data}');
                  }
                } on DioException catch (e) {
                  debugLogger.addLog('❌ [Ciclo ${timer.tick}] Erro DioException ao buscar email via API: ${e.type}, status=${e.response?.statusCode}, message=${e.message}', level: LogLevel.error);
                  print('❌ [DEBUG] [Ciclo ${timer.tick}] Erro DioException ao buscar email via API:');
                  print('   Tipo: ${e.type}');
                  print('   Status: ${e.response?.statusCode}');
                  print('   Mensagem: ${e.message}');
                  if (e.response != null) {
                    print('   Resposta: ${e.response?.data}');
                  }
                } catch (e, stackTrace) {
                  debugLogger.addLog('❌ [Ciclo ${timer.tick}] Erro ao buscar email via API: $e', level: LogLevel.error);
                  print('❌ [DEBUG] [Ciclo ${timer.tick}] Erro ao buscar email via API: $e');
                  print('❌ [DEBUG] [Ciclo ${timer.tick}] Stack trace: $stackTrace');
                }
                }
              }
            } catch (e) {
              debugLogger.addLog('⚠️ [Ciclo ${timer.tick}] Erro ao ler userId do sessionStorage: $e', level: LogLevel.warning);
              print('⚠️ [DEBUG] [Ciclo ${timer.tick}] Erro ao ler userId do sessionStorage: $e');
            }
          }
        }
        
        // Log detalhado SEMPRE para cada ciclo (já que é a cada 5 segundos)
        final logMessage = '🔍 [Ciclo ${timer.tick}] Email=${emailToUse ?? "NENHUM"}, FCM=${hasFcmToken ? "SIM" : "NÃO"}, Keys=${localStorageSize ?? 0}';
        debugLogger.addLog(logMessage, level: LogLevel.info);
        print('🔍 [DEBUG] ========================================');
        print('🔍 [DEBUG] Monitoramento de email - Ciclo ${timer.tick}');
        print('🔍 [DEBUG] Timestamp: ${timestamp ?? DateTime.now().toIso8601String()}');
        print('   📧 Email encontrado: ${emailToUse ?? "NENHUM"}');
        print('   🔑 FCM Token presente: $hasFcmToken');
        print('   ⏰ Última atualização: ${lastUpdateStr ?? "NUNCA"}');
        print('   📦 Total de chaves no localStorage: ${localStorageSize ?? 0}');
        print('   📦 Total de chaves no sessionStorage: ${sessionStorageSize ?? 0}');
        
        if (emailSources != null) {
          print('   📋 Fontes de email verificadas:');
          if (emailSources['localStorage'] != null) {
            print('     localStorage:');
            (emailSources['localStorage'] as Map<String, dynamic>).forEach((key, value) {
              final valueStr = value != null ? (value.toString().length > 50 ? value.toString().substring(0, 50) + "..." : value.toString()) : "null";
              debugLogger.addLog('       - $key: $valueStr', level: LogLevel.debug);
              print('       - $key: $valueStr');
            });
          }
          if (emailSources['sessionStorage'] != null) {
            print('     sessionStorage:');
            (emailSources['sessionStorage'] as Map<String, dynamic>).forEach((key, value) {
              final valueStr = value != null ? (value.toString().length > 50 ? value.toString().substring(0, 50) + "..." : value.toString()) : "null";
              debugLogger.addLog('       - $key: $valueStr', level: LogLevel.debug);
              print('       - $key: $valueStr');
            });
          }
        }
        
        if (allEmailValues != null && allEmailValues.isNotEmpty) {
          print('   📧 Todas as chaves relacionadas a email/user:');
          allEmailValues.forEach((key, value) {
            final valueStr = value != null ? value.toString() : "null";
            debugLogger.addLog('     - $key: $valueStr', level: LogLevel.debug);
            print('     - $key: $valueStr');
          });
        }
        
        if (localKeys != null && localKeys.isNotEmpty) {
          print('   📦 Chaves no localStorage (${localKeys.length}):');
          localKeys.forEach((key) {
            debugLogger.addLog('     - $key', level: LogLevel.debug);
            print('     - $key');
          });
        }
        
        if (sessionKeys != null && sessionKeys.isNotEmpty) {
          print('   📦 Chaves no sessionStorage (${sessionKeys.length}):');
          sessionKeys.forEach((key) {
            debugLogger.addLog('     - $key', level: LogLevel.debug);
            print('     - $key');
          });
        }
        print('🔍 [DEBUG] ========================================');
        
        // Verificar se é um email válido (usar emailToUse que pode ter sido obtido via API)
        if (emailToUse == null || emailToUse.isEmpty || emailToUse == 'null' || !emailToUse.contains('@')) {
          debugLogger.addLog('⚠️ [Ciclo ${timer.tick}] Email não encontrado ou inválido no localStorage/sessionStorage/API', level: LogLevel.warning);
          debugLogger.addLog('⚠️ [Ciclo ${timer.tick}] Email value: "$emailToUse" (null=${emailToUse == null}, empty=${emailToUse?.isEmpty ?? true}, contains@=${emailToUse?.contains("@") ?? false})', level: LogLevel.warning);
          print('⚠️ [DEBUG] [Ciclo ${timer.tick}] Email não encontrado ou inválido no localStorage/sessionStorage/API');
          print('⚠️ [DEBUG] [Ciclo ${timer.tick}] Email value: "$emailToUse"');
          print('⚠️ [DEBUG] [Ciclo ${timer.tick}] null=${emailToUse == null}, empty=${emailToUse?.isEmpty ?? true}, contains@=${emailToUse?.contains("@") ?? false}');
          return;
        }
        
        // Verificar se o token FCM já está registrado
        bool tokenAlreadyRegistered = false;
        try {
          final checkTokenJsCode = '''
            (function() {
              const fcmToken = localStorage.getItem('fcm_token') || localStorage.getItem('fcmToken');
              return !!fcmToken;
            })();
          ''';
          
          final checkResult = await controller.runJavaScriptReturningResult(checkTokenJsCode);
          final hasTokenStr = checkResult.toString().trim().toLowerCase();
          tokenAlreadyRegistered = hasTokenStr == 'true' || hasTokenStr == '"true"';
          
          if (tokenAlreadyRegistered) {
            debugLogger.addLog('✅ [Ciclo ${timer.tick}] Token FCM já está registrado para $emailToUse', level: LogLevel.info);
            print('✅ [DEBUG] [Ciclo ${timer.tick}] Token FCM já está registrado para $emailToUse');
          }
        } catch (e) {
          print('⚠️ [DEBUG] [Ciclo ${timer.tick}] Erro ao verificar token FCM: $e');
        }
        
        // Verificar se passou 5 horas desde a última atualização (apenas se o token não estiver registrado)
        bool shouldUpdate = !tokenAlreadyRegistered;
        if (!tokenAlreadyRegistered && lastUpdateStr != null && lastUpdateStr.isNotEmpty && lastUpdateStr != 'null') {
          try {
            final lastUpdate = DateTime.parse(lastUpdateStr);
            final now = DateTime.now();
            final difference = now.difference(lastUpdate);
            
            if (difference.inHours < 5) {
              shouldUpdate = false;
              if (timer.tick % 15 == 0) { // Log a cada 30 segundos quando aguardando
                debugLogger.addLog('⏰ Última atualização do FCM foi há ${difference.inHours}h ${difference.inMinutes % 60}m - aguardando 5 horas', level: LogLevel.info);
                print('⏰ [DEBUG] Última atualização do FCM foi há ${difference.inHours}h ${difference.inMinutes % 60}m - aguardando 5 horas');
              }
            }
          } catch (e) {
            debugLogger.addLog('⚠️ Erro ao parsear timestamp da última atualização: $e', level: LogLevel.warning);
            print('⚠️ [DEBUG] Erro ao parsear timestamp da última atualização: $e');
            // Se houver erro ao parsear, continuar com o registro
          }
        }
        
        if (shouldUpdate && !tokenAlreadyRegistered) {
          debugLogger.addLog('📧 ✅ Email encontrado: $emailToUse - Iniciando registro de FCM token', level: LogLevel.info);
          print('📧 [DEBUG] ✅ Email encontrado: $emailToUse');
          
          // Salvar email no SharedPreferences do Flutter
          await _saveEmailToFlutterStorage(emailToUse);
          
          print('📧 [DEBUG] Tentando registrar token FCM...');
          await _registerPushToken(emailToUse);
        } else if (tokenAlreadyRegistered) {
          debugLogger.addLog('✅ [Ciclo ${timer.tick}] Token FCM já registrado - nenhuma ação necessária', level: LogLevel.debug);
          print('✅ [DEBUG] [Ciclo ${timer.tick}] Token FCM já registrado - nenhuma ação necessária');
        }
      } catch (e, stackTrace) {
        debugLogger.addLog('❌ Erro no monitoramento de email: $e', level: LogLevel.error);
        print('❌ [DEBUG] Erro no monitoramento de email: $e');
        print('❌ [DEBUG] Stack trace: $stackTrace');
        debugPrint('Erro detalhado: ${e.toString()}');
      }
    });
  }

  // Extrair email do objeto user
  String? _extractEmailFromUser(Map<String, dynamic> user) {
    try {
      return user['email'] as String? ?? 
             user['user_email'] as String? ?? 
             user['e_mail'] as String?;
    } catch (e) {
      print('⚠️ Erro ao extrair email do objeto user: $e');
      return null;
    }
  }

  // Salvar email no SharedPreferences do Flutter
  Future<void> _saveEmailToFlutterStorage(String email) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_email', email);
      print('💾 [Flutter Storage] Email salvo no SharedPreferences: $email');
      final debugLogger = DebugLogger();
      debugLogger.addLog('💾 [Flutter Storage] Email salvo no SharedPreferences: $email', level: LogLevel.info);
    } catch (e) {
      print('❌ Erro ao salvar email no SharedPreferences: $e');
      final debugLogger = DebugLogger();
      debugLogger.addLog('❌ Erro ao salvar email no SharedPreferences: $e', level: LogLevel.error);
    }
  }

  // Ler email do SharedPreferences do Flutter
  Future<String?> _getEmailFromFlutterStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final email = prefs.getString('user_email');
      if (email != null && email.isNotEmpty) {
        print('📖 [Flutter Storage] Email encontrado no SharedPreferences: $email');
        return email;
      }
      return null;
    } catch (e) {
      print('❌ Erro ao ler email do SharedPreferences: $e');
      return null;
    }
  }

  // Registrar token FCM no backend
  Future<void> _registerPushToken(String email) async {
    final debugLogger = DebugLogger();
    final now = DateTime.now();
    
    try {
      // Verificar se o Firebase está bloqueado
      if (_firebaseBlockedUntil != null && now.isBefore(_firebaseBlockedUntil!)) {
        final minutesRemaining = _firebaseBlockedUntil!.difference(now).inMinutes;
        debugLogger.addLog('⏸️ Firebase bloqueado - aguardando ${minutesRemaining + 1} minutos antes de tentar novamente', level: LogLevel.warning);
        print('⏸️ [DEBUG] Firebase bloqueado - aguardando ${minutesRemaining + 1} minutos antes de tentar novamente');
        return;
      }
      
      // Se o Firebase estava bloqueado mas já passou o tempo, limpar o bloqueio
      if (_firebaseBlockedUntil != null && now.isAfter(_firebaseBlockedUntil!)) {
        debugLogger.addLog('✅ Bloqueio do Firebase expirado - tentando novamente', level: LogLevel.info);
        print('✅ [DEBUG] Bloqueio do Firebase expirado - tentando novamente');
        _firebaseBlockedUntil = null;
      }
      
      // Verificar se já registramos este email recentemente (evitar duplicação em memória)
      if (email == _lastRegisteredEmail) {
        debugLogger.addLog('📧 Email já registrado recentemente: $email (ignorando)', level: LogLevel.info);
        print('📧 [DEBUG] Email já registrado recentemente: $email (ignorando)');
        return;
      }
      
      // Verificar se já tentamos registrar este email recentemente e falhou
      if (_lastFcmFailedEmail == email && _lastFcmRegistrationAttempt != null) {
        final minutesSinceLastAttempt = now.difference(_lastFcmRegistrationAttempt!).inMinutes;
        if (minutesSinceLastAttempt < 30) {
          debugLogger.addLog('⏸️ Tentativa de registro FCM falhou recentemente para $email (há ${minutesSinceLastAttempt}m) - aguardando 30 minutos', level: LogLevel.warning);
          print('⏸️ [DEBUG] Tentativa de registro FCM falhou recentemente para $email (há ${minutesSinceLastAttempt}m) - aguardando 30 minutos');
          return;
        }
      }
      
      // Atualizar timestamp da tentativa
      _lastFcmRegistrationAttempt = now;
      
      debugLogger.addLog('📱 ========================================', level: LogLevel.info);
      debugLogger.addLog('📱 INICIANDO REGISTRO DE TOKEN FCM', level: LogLevel.info);
      debugLogger.addLog('📱 Email: $email', level: LogLevel.info);
      debugLogger.addLog('📱 ========================================', level: LogLevel.info);
      
      print('📱 [DEBUG] ========================================');
      print('📱 [DEBUG] INICIANDO REGISTRO DE TOKEN FCM');
      print('📱 [DEBUG] Email: $email');
      print('📱 [DEBUG] Timestamp: ${DateTime.now().toIso8601String()}');
      print('📱 [DEBUG] ========================================');
      
      // Registrar token usando o serviço de push notifications
      // O serviço vai fazer login/registro no Firebase Auth com senha padrão "123456"
      debugLogger.addLog('📱 Chamando PushNotificationService.registerToken()...', level: LogLevel.info);
      print('📱 [DEBUG] Chamando PushNotificationService.registerToken()...');
      print('📱 [DEBUG] Aguardando resposta do serviço...');
      
      final startTime = DateTime.now();
      String? fcmToken;
      String? firebaseError;
      
      try {
        fcmToken = await _pushNotificationService.registerToken(email);
      } catch (e) {
        firebaseError = e.toString();
        debugLogger.addLog('❌ Erro capturado do PushNotificationService: $firebaseError', level: LogLevel.error);
        print('❌ [DEBUG] Erro capturado do PushNotificationService: $firebaseError');
      }
      
      final duration = DateTime.now().difference(startTime);
      
      print('📱 [DEBUG] PushNotificationService.registerToken() concluído em ${duration.inMilliseconds}ms');
      
      // Se houve erro do Firebase, tratar antes de verificar o token
      if (firebaseError != null) {
        if (firebaseError.contains('too-many-requests')) {
          _firebaseBlockedUntil = now.add(const Duration(minutes: 60));
          _lastFcmFailedEmail = email;
          debugLogger.addLog('🚫 Firebase bloqueou o dispositivo - aguardando 60 minutos', level: LogLevel.error);
          print('🚫 [DEBUG] Firebase bloqueou o dispositivo - aguardando 60 minutos');
          return;
        } else if (firebaseError.contains('invalid-credential')) {
          _lastFcmFailedEmail = email;
          debugLogger.addLog('🔒 Credenciais inválidas - aguardando 30 minutos', level: LogLevel.warning);
          print('🔒 [DEBUG] Credenciais inválidas - aguardando 30 minutos');
          return;
        }
      }
      
      if (fcmToken != null) {
        _lastRegisteredEmail = email;
        debugLogger.addLog('✅ Token FCM obtido com sucesso! Tamanho: ${fcmToken.length} caracteres', level: LogLevel.info);
        print('✅ [DEBUG] Token FCM obtido com sucesso!');
        print('✅ [DEBUG] Token (primeiros 30 chars): ${fcmToken.substring(0, fcmToken.length > 30 ? 30 : fcmToken.length)}...');
        print('✅ [DEBUG] Token (últimos 10 chars): ...${fcmToken.substring(fcmToken.length - 10)}');
        print('✅ [DEBUG] Tamanho do token: ${fcmToken.length} caracteres');
        
        // Salvar token FCM e timestamp no localStorage da WebView
        try {
          final platform = Platform.isAndroid ? 'android' : 'ios';
          final now = DateTime.now();
          final registeredAt = now.toIso8601String();
          final lastUpdate = now.toIso8601String(); // Timestamp de controle
          
          // Usar jsonEncode para escapar corretamente o token para JavaScript
          final escapedToken = jsonEncode(fcmToken);
          final tokenPreview = fcmToken.length > 20 ? fcmToken.substring(0, 20) : fcmToken;
          
          debugLogger.addLog('📱 Preparando código JavaScript para salvar no localStorage...', level: LogLevel.info);
          print('📱 [DEBUG] Preparando código JavaScript para salvar no localStorage...');
          print('📱 [DEBUG] Platform: $platform');
          print('📱 [DEBUG] Timestamp: $lastUpdate');
          print('📱 [DEBUG] Token preview: ${tokenPreview}...');
          
          final jsCode = '''
            (function() {
              try {
                console.log('📱 Flutter: Iniciando salvamento do token FCM no localStorage...');
                const fcmToken = $escapedToken;
                localStorage.setItem('fcm_token', fcmToken);
                localStorage.setItem('fcmToken', fcmToken);
                localStorage.setItem('fcm_platform', '$platform');
                localStorage.setItem('fcm_registered_at', '$registeredAt');
                localStorage.setItem('fcm_last_update', '$lastUpdate');
                
                // Verificar se foi salvo corretamente
                const savedToken = localStorage.getItem('fcm_token');
                const savedPlatform = localStorage.getItem('fcm_platform');
                const savedUpdate = localStorage.getItem('fcm_last_update');
                
                console.log('✅ Flutter: Token FCM salvo no localStorage da WebView');
                console.log('📱 Platform: ' + savedPlatform);
                console.log('🔑 Token salvo: ' + (savedToken ? savedToken.substring(0, 20) + '...' : 'NULL'));
                console.log('⏰ Timestamp de controle salvo: ' + savedUpdate);
                console.log('✅ Verificação: Token presente = ' + !!savedToken);
              } catch(e) {
                console.error('❌ Erro ao salvar token FCM no localStorage:', e);
                console.error('❌ Stack trace:', e.stack);
              }
            })();
          ''';
          
          debugLogger.addLog('📱 Executando código JavaScript no WebView...', level: LogLevel.info);
          print('📱 [DEBUG] Executando código JavaScript no WebView...');
          await controller.runJavaScript(jsCode);
          
          // Verificar se foi salvo corretamente
          print('📱 [DEBUG] Aguardando 500ms antes de verificar...');
          await Future.delayed(const Duration(milliseconds: 500));
          
          final verifyJsCode = '''
            (function() {
              const fcmToken = localStorage.getItem('fcm_token');
              const fcmTokenAlt = localStorage.getItem('fcmToken');
              const platform = localStorage.getItem('fcm_platform');
              const lastUpdate = localStorage.getItem('fcm_last_update');
              const registeredAt = localStorage.getItem('fcm_registered_at');
              
              return JSON.stringify({
                fcm_token: fcmToken ? 'PRESENTE' : 'AUSENTE',
                fcmToken: fcmTokenAlt ? 'PRESENTE' : 'AUSENTE',
                fcm_platform: platform,
                fcm_last_update: lastUpdate,
                fcm_registered_at: registeredAt,
                token_length: fcmToken ? fcmToken.length : 0,
                token_preview: fcmToken ? fcmToken.substring(0, 20) + '...' : 'N/A'
              });
            })();
          ''';
          
          print('📱 [DEBUG] Verificando se o token foi salvo corretamente...');
          final verifyResult = await controller.runJavaScriptReturningResult(verifyJsCode);
          String verifyStr = verifyResult.toString().trim();
          
          // Remover aspas extras se houver
          if (verifyStr.startsWith('"') && verifyStr.endsWith('"')) {
            verifyStr = verifyStr.substring(1, verifyStr.length - 1);
          }
          verifyStr = verifyStr.replaceAll('\\"', '"');
          
          print('📱 [DEBUG] Verificação pós-salvamento: $verifyStr');
          
          try {
            final verifyData = jsonDecode(verifyStr);
            debugLogger.addLog('✅ Token FCM salvo no localStorage: ${verifyData['fcm_token']}, Platform: ${verifyData['fcm_platform']}', level: LogLevel.info);
            print('✅ [DEBUG] Token FCM e timestamp salvo no localStorage da WebView');
            print('✅ [DEBUG] Verificação detalhada:');
            print('   - fcm_token: ${verifyData['fcm_token']}');
            print('   - fcmToken: ${verifyData['fcmToken']}');
            print('   - Platform: ${verifyData['fcm_platform']}');
            print('   - Última atualização: ${verifyData['fcm_last_update']}');
            print('   - Registrado em: ${verifyData['fcm_registered_at']}');
            print('   - Tamanho do token: ${verifyData['token_length']}');
            print('   - Preview: ${verifyData['token_preview']}');
          } catch (e) {
            print('⚠️ [DEBUG] Erro ao parsear resultado da verificação: $e');
          }
          
          print('📱 [DEBUG] ========================================');
        } catch (e, stackTrace) {
          debugLogger.addLog('❌ Erro ao salvar token FCM no localStorage: $e', level: LogLevel.error);
          print('❌ [DEBUG] Erro ao salvar token FCM no localStorage: $e');
          print('❌ [DEBUG] Stack trace: $stackTrace');
          debugPrint('Erro detalhado: ${e.toString()}');
          print('📱 [DEBUG] ========================================');
        }
      } else {
        // Marcar que a tentativa falhou
        _lastFcmFailedEmail = email;
        
        // Verificar logs recentes para detectar erros específicos do Firebase
        final recentLogs = debugLogger.getLogs().where((log) {
          final timeDiff = now.difference(log.timestamp);
          return timeDiff.inSeconds < 10; // Últimos 10 segundos
        }).toList();
        
        bool foundTooManyRequests = false;
        bool foundInvalidCredential = false;
        
        for (final log in recentLogs) {
          if (log.message.contains('too-many-requests')) {
            foundTooManyRequests = true;
            break;
          }
          if (log.message.contains('invalid-credential')) {
            foundInvalidCredential = true;
            break;
          }
        }
        
        if (foundTooManyRequests) {
          _firebaseBlockedUntil = now.add(const Duration(minutes: 60));
          debugLogger.addLog('🚫 Firebase bloqueou o dispositivo (detectado nos logs) - aguardando 60 minutos', level: LogLevel.error);
          print('🚫 [DEBUG] Firebase bloqueou o dispositivo (detectado nos logs) - aguardando 60 minutos');
          return;
        } else if (foundInvalidCredential) {
          debugLogger.addLog('🔒 Credenciais inválidas (detectado nos logs) - aguardando 30 minutos', level: LogLevel.warning);
          print('🔒 [DEBUG] Credenciais inválidas (detectado nos logs) - aguardando 30 minutos');
          return;
        }
        
        debugLogger.addLog('⚠️ Falha ao registrar token FCM para: $email - PushNotificationService retornou null', level: LogLevel.warning);
        print('⚠️ [DEBUG] Falha ao registrar token FCM para: $email');
        print('⚠️ [DEBUG] PushNotificationService retornou null');
        print('📱 [DEBUG] ========================================');
      }
    } catch (e) {
      final errorStr = e.toString();
      
      // Detectar erros específicos do Firebase
      if (errorStr.contains('too-many-requests')) {
        // Firebase bloqueou o dispositivo - aguardar 60 minutos
        _firebaseBlockedUntil = now.add(const Duration(minutes: 60));
        _lastFcmFailedEmail = email;
        debugLogger.addLog('🚫 Firebase bloqueou o dispositivo - aguardando 60 minutos antes de tentar novamente', level: LogLevel.error);
        print('🚫 [DEBUG] Firebase bloqueou o dispositivo - aguardando 60 minutos antes de tentar novamente');
      } else if (errorStr.contains('invalid-credential')) {
        // Credenciais inválidas - aguardar 30 minutos
        _lastFcmFailedEmail = email;
        debugLogger.addLog('🔒 Credenciais inválidas - aguardando 30 minutos antes de tentar novamente', level: LogLevel.warning);
        print('🔒 [DEBUG] Credenciais inválidas - aguardando 30 minutos antes de tentar novamente');
      } else {
        // Outro erro - aguardar 30 minutos
        _lastFcmFailedEmail = email;
        debugLogger.addLog('⚠️ Erro ao registrar token FCM - aguardando 30 minutos antes de tentar novamente', level: LogLevel.warning);
        print('⚠️ [DEBUG] Erro ao registrar token FCM - aguardando 30 minutos antes de tentar novamente');
      }
      
      print('❌ Erro ao registrar token FCM: $e');
      debugPrint('Erro detalhado: ${e.toString()}');
      print('📱 ========================================');
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


// Serviço de Push Notifications
class PushNotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final Dio _dio = Dio();
  
  // Senha padrão para autenticação Firebase
  static const String _defaultPassword = '123456';
  
  // URL do backend para salvar o token
  static const String _backendUrl = 'https://icar.skalacode.com/api/push-token';

  PushNotificationService() {
    _dio.options.baseUrl = 'https://icar.skalacode.com';
    _dio.options.headers['Accept'] = 'application/json';
    _dio.options.headers['Content-Type'] = 'application/json';
  }

  /// Registra o token FCM para um email específico
  /// 1. Autentica no Firebase com email e senha padrão
  /// 2. Obtém o token FCM
  /// 3. Envia o token para o backend
  /// Retorna o token FCM se bem-sucedido, null caso contrário
  Future<String?> registerToken(String email) async {
    final debugLogger = DebugLogger();
    
    try {
      debugLogger.addLog('📱 [PushNotificationService] Iniciando registro de token para: $email', level: LogLevel.info);
      print('📱 [DEBUG] [PushNotificationService] Iniciando registro de token para: $email');
      print('📱 [DEBUG] [PushNotificationService] Timestamp: ${DateTime.now().toIso8601String()}');

      // 1. Autenticar no Firebase
      UserCredential? userCredential;
      try {
        debugLogger.addLog('📱 [PushNotificationService] Tentando fazer login no Firebase...', level: LogLevel.info);
        print('📱 [DEBUG] [PushNotificationService] Tentando fazer login no Firebase...');
        print('📱 [DEBUG] [PushNotificationService] Email: $email');
        
        // Tentar fazer login primeiro
        final loginStartTime = DateTime.now();
        userCredential = await _auth.signInWithEmailAndPassword(
          email: email,
          password: _defaultPassword,
        );
        final loginDuration = DateTime.now().difference(loginStartTime);
        
        debugLogger.addLog('✅ [PushNotificationService] Login Firebase bem-sucedido em ${loginDuration.inMilliseconds}ms', level: LogLevel.info);
        print('✅ [DEBUG] [PushNotificationService] Login Firebase bem-sucedido');
        print('✅ [DEBUG] [PushNotificationService] Duração do login: ${loginDuration.inMilliseconds}ms');
        print('✅ [DEBUG] [PushNotificationService] User ID: ${userCredential.user?.uid}');
      } catch (e) {
        debugLogger.addLog('⚠️ [PushNotificationService] Erro ao fazer login: $e', level: LogLevel.warning);
        print('⚠️ [DEBUG] [PushNotificationService] Erro ao fazer login: $e');
        
        // Se o usuário não existe ou credenciais inválidas, tentar criar conta
        // invalid-credential pode significar que o usuário não existe
        if (e.toString().contains('user-not-found') || 
            e.toString().contains('wrong-password') ||
            e.toString().contains('invalid-credential')) {
          debugLogger.addLog('📝 [PushNotificationService] Usuário não encontrado, criando conta...', level: LogLevel.info);
          print('📝 [DEBUG] [PushNotificationService] Usuário não encontrado, criando conta...');
          try {
            final createStartTime = DateTime.now();
            userCredential = await _auth.createUserWithEmailAndPassword(
              email: email,
              password: _defaultPassword,
            );
            final createDuration = DateTime.now().difference(createStartTime);
            
            debugLogger.addLog('✅ [PushNotificationService] Conta Firebase criada com sucesso em ${createDuration.inMilliseconds}ms', level: LogLevel.info);
            print('✅ [DEBUG] [PushNotificationService] Conta Firebase criada com sucesso');
            print('✅ [DEBUG] [PushNotificationService] Duração da criação: ${createDuration.inMilliseconds}ms');
            print('✅ [DEBUG] [PushNotificationService] User ID: ${userCredential.user?.uid}');
          } catch (createError) {
            debugLogger.addLog('❌ [PushNotificationService] Erro ao criar conta Firebase: $createError', level: LogLevel.error);
            print('❌ [DEBUG] [PushNotificationService] Erro ao criar conta Firebase: $createError');
            // Se falhar ao criar (pode ser que já exista), tentar login novamente
            try {
              debugLogger.addLog('🔄 [PushNotificationService] Tentando login novamente após erro de criação...', level: LogLevel.info);
              print('🔄 [DEBUG] [PushNotificationService] Tentando login novamente após erro de criação...');
              
              userCredential = await _auth.signInWithEmailAndPassword(
                email: email,
                password: _defaultPassword,
              );
              
              debugLogger.addLog('✅ [PushNotificationService] Login Firebase bem-sucedido após tentativa de criação', level: LogLevel.info);
              print('✅ [DEBUG] [PushNotificationService] Login Firebase bem-sucedido após tentativa de criação');
            } catch (retryError) {
              debugLogger.addLog('❌ [PushNotificationService] Erro ao fazer login após tentativa de criação: $retryError', level: LogLevel.error);
              print('❌ [DEBUG] [PushNotificationService] Erro ao fazer login após tentativa de criação: $retryError');
              // Lançar exceção para que o erro seja capturado no _registerPushToken
              rethrow;
            }
          }
        } else {
          debugLogger.addLog('❌ [PushNotificationService] Erro ao autenticar no Firebase: $e', level: LogLevel.error);
          print('❌ [DEBUG] [PushNotificationService] Erro ao autenticar no Firebase: $e');
          
          // Se for erro de too-many-requests ou invalid-credential, lançar exceção para ser capturada
          final errorStr = e.toString();
          if (errorStr.contains('too-many-requests') || errorStr.contains('invalid-credential')) {
            rethrow;
          }
          
          return null;
        }
      }

      // 2. Obter token FCM
      String? fcmToken;
      try {
        debugLogger.addLog('📱 [PushNotificationService] Obtendo token FCM...', level: LogLevel.info);
        print('📱 [DEBUG] [PushNotificationService] Obtendo token FCM...');
        
        final tokenStartTime = DateTime.now();
        fcmToken = await _messaging.getToken();
        final tokenDuration = DateTime.now().difference(tokenStartTime);
        
        if (fcmToken == null) {
          debugLogger.addLog('❌ [PushNotificationService] Token FCM é null', level: LogLevel.error);
          print('❌ [DEBUG] [PushNotificationService] Token FCM é null');
          return null;
        }
        
        debugLogger.addLog('✅ [PushNotificationService] Token FCM obtido em ${tokenDuration.inMilliseconds}ms. Tamanho: ${fcmToken.length} caracteres', level: LogLevel.info);
        print('✅ [DEBUG] [PushNotificationService] Token FCM obtido');
        print('✅ [DEBUG] [PushNotificationService] Duração: ${tokenDuration.inMilliseconds}ms');
        print('✅ [DEBUG] [PushNotificationService] Token (primeiros 30 chars): ${fcmToken.substring(0, fcmToken.length > 30 ? 30 : fcmToken.length)}...');
        print('✅ [DEBUG] [PushNotificationService] Token (últimos 10 chars): ...${fcmToken.substring(fcmToken.length - 10)}');
        print('✅ [DEBUG] [PushNotificationService] Tamanho: ${fcmToken.length} caracteres');
      } catch (e) {
        debugLogger.addLog('❌ [PushNotificationService] Erro ao obter token FCM: $e', level: LogLevel.error);
        print('❌ [DEBUG] [PushNotificationService] Erro ao obter token FCM: $e');
        return null;
      }

      // 3. Enviar token para o backend
      try {
        debugLogger.addLog('📱 [PushNotificationService] Preparando envio do token para o backend...', level: LogLevel.info);
        print('📱 [DEBUG] [PushNotificationService] Preparando envio do token para o backend...');
        
        // Obter token de autenticação do app (se disponível)
        final authService = AuthService();
        final appToken = await authService.getToken();
        
        final platform = Platform.isAndroid ? 'android' : 'ios';
        final headers = <String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        };
        
        if (appToken != null) {
          headers['Authorization'] = 'Bearer $appToken';
          debugLogger.addLog('📱 [PushNotificationService] Enviando token com autenticação', level: LogLevel.info);
          print('📱 [DEBUG] [PushNotificationService] Enviando token com autenticação');
          print('📱 [DEBUG] [PushNotificationService] App token presente: ${appToken.substring(0, 20)}...');
        } else {
          debugLogger.addLog('📱 [PushNotificationService] Enviando token sem autenticação (busca por email)', level: LogLevel.info);
          print('📱 [DEBUG] [PushNotificationService] Enviando token sem autenticação (busca por email)');
        }

        final requestData = {
          'email': email,
          'fcm_token': fcmToken,
          'platform': platform,
        };

        debugLogger.addLog('📤 [PushNotificationService] Enviando para: $_backendUrl', level: LogLevel.info);
        print('📤 [DEBUG] [PushNotificationService] Enviando para: $_backendUrl');
        print('📤 [DEBUG] [PushNotificationService] Dados: email=$email, platform=$platform, token_length=${fcmToken.length}');

        final requestStartTime = DateTime.now();
        final response = await _dio.post(
          '/api/push-token',
          data: requestData,
          options: Options(headers: headers),
        );
        final requestDuration = DateTime.now().difference(requestStartTime);

        debugLogger.addLog('📥 [PushNotificationService] Resposta do backend: status=${response.statusCode} em ${requestDuration.inMilliseconds}ms', level: LogLevel.info);
        print('📥 [DEBUG] [PushNotificationService] Resposta do backend: status=${response.statusCode}');
        print('📥 [DEBUG] [PushNotificationService] Duração da requisição: ${requestDuration.inMilliseconds}ms');
        
        if (response.statusCode == 200 || response.statusCode == 201) {
          final responseData = response.data;
          debugLogger.addLog('✅ [PushNotificationService] Token FCM registrado com sucesso no backend', level: LogLevel.info);
          print('✅ [DEBUG] [PushNotificationService] Token FCM registrado com sucesso no backend');
          if (responseData is Map) {
            print('📋 [DEBUG] [PushNotificationService] Dados da resposta: $responseData');
          }
          return fcmToken; // Retornar o token FCM
        } else {
          debugLogger.addLog('⚠️ [PushNotificationService] Resposta inesperada do backend: ${response.statusCode}', level: LogLevel.warning);
          print('⚠️ [DEBUG] [PushNotificationService] Resposta inesperada do backend: ${response.statusCode}');
          print('⚠️ [DEBUG] [PushNotificationService] Dados da resposta: ${response.data}');
          return null;
        }
      } on DioException catch (e) {
        debugLogger.addLog('❌ [PushNotificationService] Erro DioException: ${e.type}, Status: ${e.response?.statusCode}', level: LogLevel.error);
        print('❌ [DEBUG] [PushNotificationService] Erro DioException ao enviar token para o backend:');
        print('   Tipo: ${e.type}');
        print('   Status: ${e.response?.statusCode}');
        print('   Mensagem: ${e.message}');
        if (e.response != null) {
          print('   Resposta: ${e.response?.data}');
        }
        
        // Se for erro 422 (validação) ou 404 (usuário não encontrado), retornar null
        if (e.response?.statusCode == 422 || e.response?.statusCode == 404) {
          debugLogger.addLog('❌ [PushNotificationService] Erro de validação ou usuário não encontrado', level: LogLevel.error);
          print('❌ [DEBUG] [PushNotificationService] Erro de validação ou usuário não encontrado');
          return null;
        }
        
        // Para outros erros, considerar sucesso parcial (token foi obtido)
        debugLogger.addLog('⚠️ [PushNotificationService] Considerando sucesso parcial (token FCM obtido, mas não salvo no backend)', level: LogLevel.warning);
        print('⚠️ [DEBUG] [PushNotificationService] Considerando sucesso parcial (token FCM obtido, mas não salvo no backend)');
        return fcmToken; // Retornar o token mesmo com erro parcial
      } catch (e) {
        debugLogger.addLog('❌ [PushNotificationService] Erro geral ao enviar token para o backend: $e', level: LogLevel.error);
        print('❌ [DEBUG] [PushNotificationService] Erro geral ao enviar token para o backend: $e');
        print('⚠️ [DEBUG] [PushNotificationService] Considerando sucesso parcial (token FCM obtido, mas não salvo no backend)');
        return fcmToken; // Retornar o token mesmo com erro parcial
      }
    } catch (e, stackTrace) {
      debugLogger.addLog('❌ [PushNotificationService] Erro geral ao registrar token: $e', level: LogLevel.error);
      print('❌ [DEBUG] [PushNotificationService] Erro geral ao registrar token: $e');
      print('❌ [DEBUG] [PushNotificationService] Stack trace: $stackTrace');
      return null;
    }
  }

  /// Remove o token quando o usuário faz logout
  Future<void> unregisterToken(String email) async {
    try {
      await _auth.signOut();
      print('✅ Logout do Firebase realizado');
    } catch (e) {
      print('❌ Erro ao fazer logout do Firebase: $e');
    }
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