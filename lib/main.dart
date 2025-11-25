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
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
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
  print('📱 [BACKGROUND] Notificação em background recebida: ${message.messageId}');
  print('📱 [BACKGROUND] Título: ${message.notification?.title}');
  print('📱 [BACKGROUND] Corpo: ${message.notification?.body}');
  print('📱 [BACKGROUND] Dados: ${message.data}');
  print('📱 [BACKGROUND] Tem notification: ${message.notification != null}');
  
  // Em dispositivos Samsung, mesmo com o campo 'notification', as notificações podem não aparecer
  // se o app estiver em background. Vamos garantir que a notificação seja exibida usando
  // notificações locais como fallback.
  
  try {
    final FlutterLocalNotificationsPlugin localNotifications = FlutterLocalNotificationsPlugin();
    
    // Inicializar notificações locais se ainda não estiverem inicializadas
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
    
    await localNotifications.initialize(initSettings);
    
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
      
      await localNotifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidChannel);
    }
    
    // Exibir notificação local se tiver conteúdo
    if (message.notification != null) {
      final androidDetails = AndroidNotificationDetails(
        'high_importance_channel',
        'Notificações Importantes',
        channelDescription: 'Este canal é usado para notificações importantes',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        playSound: true,
        enableVibration: true,
        icon: '@drawable/ic_notification_car',
      );
      
      final iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );
      
      final details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );
      
      // Criar payload JSON para a notificação local
      final payloadJson = jsonEncode(message.data);
      
      await localNotifications.show(
        message.hashCode,
        message.notification?.title ?? 'Nova notificação',
        message.notification?.body ?? '',
        details,
        payload: payloadJson,
      );
      
      print('✅ [BACKGROUND] Notificação local exibida com sucesso');
    } else {
      print('⚠️ [BACKGROUND] Notificação sem campo notification - não foi possível exibir');
    }
  } catch (e, stackTrace) {
    print('❌ [BACKGROUND] Erro ao exibir notificação local: $e');
    print('❌ [BACKGROUND] Stack trace: $stackTrace');
    
    // Log adicional para debug
    if (message.notification == null) {
      print('⚠️ [BACKGROUND] Notificação sem campo notification - pode não aparecer automaticamente');
    } else {
      print('✅ [BACKGROUND] Notificação com campo notification - Firebase deve exibir automaticamente');
    }
  }
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
        // Desabilitar escalonamento de fontes do sistema operacional
        // Fixar em 1.0 para Android e iOS para evitar textos muito grandes
        final mediaQuery = MediaQuery.of(context);
        final textScaleFactor = 1.0; // Fixar em 1.0 para ambos Android e iOS

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
  Map<String, dynamic>? _pendingNotificationData;  // Dados da notificação pendente para salvar no sessionStorage

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // Inicializar WebView após o frame estar pronto para evitar crashes no iOS
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        print('🍎 [iOS] Iniciando inicialização do WebView após frame estar pronto...');
        _initWebView();
      } catch (e, stackTrace) {
        print('❌ [iOS] Erro crítico ao inicializar WebView: $e');
        print('❌ [iOS] Stack trace: $stackTrace');
        // Tentar novamente após um pequeno delay
        Future.delayed(const Duration(milliseconds: 500), () {
          try {
            print('🔄 [iOS] Tentando reinicializar WebView...');
            _initWebView();
          } catch (e2) {
            print('❌ [iOS] Erro ao reinicializar WebView: $e2');
          }
        });
      }
    });
    
    // Solicitar permissão de localização no início do app
    _requestLocationPermission();
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
    try {
      print('🍎 [iOS] Iniciando configuração do WebViewController...');
      
      // User-Agent diferente para Android (Chrome) e iOS (Safari)
      final userAgent = Platform.isAndroid
          ? 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'
          : 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

      print('🍎 [iOS] User-Agent configurado: $userAgent');

      // Configuração base do WebViewController
      controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..enableZoom(false)
        ..setUserAgent(userAgent);
      
      // Configurações específicas do iOS
      if (Platform.isIOS) {
        print('🍎 [iOS] Aplicando configurações específicas do iOS...');
        try {
          // Configurar propriedades do WKWebView via platform-specific settings
          // Estas configurações ajudam a evitar crashes no iOS
          controller.setBackgroundColor(Colors.white);
          print('🍎 [iOS] Cor de fundo configurada');
        } catch (e) {
          print('⚠️ [iOS] Erro ao configurar propriedades específicas do iOS: $e');
        }
      }
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            if (Platform.isIOS && progress % 25 == 0) {
              print('🍎 [iOS] Progresso do carregamento: $progress%');
            }
            if (progress == 100) {
              print('✅ [iOS] Página carregada completamente (100%)');
              setState(() {
                _isLoading = false;
              });
            }
          },
          onPageStarted: (String url) {
            print('🍎 [iOS] Iniciando carregamento da página: $url');
            setState(() {
              _isLoading = true;
            });
          },
          onPageFinished: (String url) {
            print('✅ [iOS] Página carregada com sucesso: $url');
            setState(() {
              _isLoading = false;
            });
            try {
              print('🍎 [iOS] Aplicando configurações pós-carregamento...');
              _disablePageZoom();
              _disableFontScaling();
              _injectJavaScriptChannels();
              _startLocationMonitoring();
              _startAuthMonitoring();
              print('✅ [iOS] Configurações pós-carregamento aplicadas');
            } catch (e, stackTrace) {
              print('❌ [iOS] Erro ao aplicar configurações pós-carregamento: $e');
              print('❌ [iOS] Stack trace: $stackTrace');
            }

            // Token já foi injetado no onNavigationRequest, apenas log
            if (url.contains('auth_success=true')) {
              print('✅ Página com auth_success carregada');
            }

            // Se há dados de notificação pendentes e estamos na página de chat, salvar no sessionStorage
            if (_pendingNotificationData != null && url.contains('/chat')) {
              print('💬 Página de chat carregada, salvando dados da notificação no sessionStorage...');
              
              // Aguardar um pouco para garantir que a página está totalmente carregada
              Future.delayed(const Duration(milliseconds: 300), () {
                _saveNotificationDataToSessionStorage(_pendingNotificationData!);
                
                // Aguardar mais um pouco e disparar evento para o frontend detectar os dados
                Future.delayed(const Duration(milliseconds: 500), () {
                  final triggerCode = '''
                    (function() {
                      try {
                        // Verificar se os dados foram salvos
                        const oficinaData = sessionStorage.getItem('oficinaData');
                        const oficinaId = sessionStorage.getItem('oficinaId');
                        const sosId = sessionStorage.getItem('sosId');
                        
                        console.log('🔍 [Flutter] Verificando dados salvos:');
                        console.log('   oficinaData:', oficinaData);
                        console.log('   oficinaId:', oficinaId);
                        console.log('   sosId:', sosId);
                        
                        // Disparar evento customizado para o frontend detectar os dados
                        window.dispatchEvent(new CustomEvent('notificationDataLoaded', {
                          detail: {
                            oficina_id: ${_pendingNotificationData!['oficina_id']},
                            sos_id: ${_pendingNotificationData!['sos_id'] ?? 'null'}
                          }
                        }));
                        console.log('✅ [Flutter] Evento notificationDataLoaded disparado');
                        
                        // Forçar reload da página se os dados não estiverem sendo detectados
                        if (oficinaData && oficinaId) {
                          console.log('🔄 [Flutter] Dados confirmados, forçando reload do componente...');
                          // Tentar recarregar o componente React se possível
                          if (typeof window.location !== 'undefined') {
                            // Não recarregar a página, apenas disparar evento
                            window.dispatchEvent(new Event('storage'));
                          }
                        }
                      } catch(e) {
                        console.error('❌ [Flutter] Erro ao disparar evento:', e);
                      }
                    })();
                  ''';
                  controller.runJavaScript(triggerCode);
                });
              });
              
              _pendingNotificationData = null; // Limpar após salvar
            }

            // Não restaurar sessão durante o fluxo do Apple Sign In
            if (!_isInAuthFlow) {
              _restoreAuthIfNeeded();
            }
          },
          onHttpError: (HttpResponseError error) {
            print('❌ [iOS] HTTP error: ${error.response?.statusCode}');
            print('❌ [iOS] Response: ${error.response}');
            if (Platform.isIOS) {
              print('🍎 [iOS] Erro HTTP no iOS - Status: ${error.response?.statusCode}');
            }
          },
          onWebResourceError: (WebResourceError error) {
            print('❌ [iOS] Web resource error: ${error.description}');
            print('❌ [iOS] Error code: ${error.errorCode}');
            print('❌ [iOS] Error type: ${error.errorType}');
            if (Platform.isIOS) {
              print('🍎 [iOS] Detalhes do erro no iOS:');
              print('   - Description: ${error.description}');
              print('   - Code: ${error.errorCode}');
              print('   - Type: ${error.errorType}');
            }
          },
          onNavigationRequest: (NavigationRequest request) {
            if (Platform.isIOS) {
              print('🍎 [iOS] Navigation request para: ${request.url}');
            } else {
              print('Navigation to: ${request.url}');
            }

            // Interceptar URLs externas (Google Maps, intent://, etc.) e abrir com url_launcher
            if (request.url.startsWith('intent://') ||
                request.url.startsWith('maps.google.com') ||
                request.url.startsWith('https://maps.google.com') ||
                request.url.startsWith('https://www.google.com/maps') ||
                request.url.contains('mapclient=embed')) {
              print('🗺️ Interceptando navegação para URL externa: ${request.url}');
              _launchExternalUrl(request.url);
              return NavigationDecision.prevent;
            }

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
                  // Para OAuth (Google/Apple), sempre salvar com rememberMe=true
                  _authService.saveAuthData(token, user, rememberMe: true);
                  print('✅ Token salvo no Flutter também (OAuth - rememberMe ativado)');

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
      );
      
      print('🍎 [iOS] WebViewController configurado, carregando URL...');
      
      // Carregar URL com tratamento de erros
      try {
        controller.loadRequest(Uri.parse('https://icarfront.vercel.app/?source=mobile'));
        print('✅ [iOS] URL carregada com sucesso');
      } catch (e, stackTrace) {
        print('❌ [iOS] Erro ao carregar URL: $e');
        print('❌ [iOS] Stack trace: $stackTrace');
        // Tentar novamente após um delay
        Future.delayed(const Duration(seconds: 1), () {
          try {
            print('🔄 [iOS] Tentando recarregar URL...');
            controller.loadRequest(Uri.parse('https://icarfront.vercel.app/?source=mobile'));
          } catch (e2) {
            print('❌ [iOS] Erro ao recarregar URL: $e2');
          }
        });
      }
      
      print('✅ [iOS] WebView inicializado com sucesso');
    } catch (e, stackTrace) {
      print('❌ [iOS] Erro crítico na inicialização do WebView: $e');
      print('❌ [iOS] Stack trace: $stackTrace');
      rethrow; // Re-throw para que o erro seja capturado no initState
    }
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

  Future<void> _launchExternalUrl(String url) async {
    try {
      print('🚀 Tentando abrir URL externa: $url');
      
      // Tratar URLs intent:// (Android)
      if (url.startsWith('intent://')) {
        // Extrair a URL de fallback do intent
        final uri = Uri.parse(url);
        final fallbackUrl = uri.queryParameters['S.browser_fallback_url'];
        if (fallbackUrl != null) {
          final decodedUrl = Uri.decodeComponent(fallbackUrl);
          print('📱 Usando URL de fallback: $decodedUrl');
          url = decodedUrl;
        } else {
          // Tentar extrair URL do intent de outra forma
          final match = RegExp(r'https?://[^\s;]+').firstMatch(url);
          if (match != null) {
            url = match.group(0)!;
            print('📱 Extraída URL do intent: $url');
          }
        }
      }
      
      final uri = Uri.parse(url);
      
      // Verificar se a URL pode ser aberta
      if (await url_launcher.canLaunchUrl(uri)) {
        await url_launcher.launchUrl(
          uri,
          mode: url_launcher.LaunchMode.externalApplication,
        );
        print('✅ URL externa aberta com sucesso');
      } else {
        print('❌ Não foi possível abrir a URL: $url');
      }
    } catch (e) {
      print('❌ Erro ao abrir URL externa: $e');
    }
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
          // Para deep links, verificar se há rememberMe na URL ou sempre salvar (OAuth)
          final rememberMe = uri.queryParameters['rememberMe'] == 'true' || true;
          await _authService.saveAuthData(token, user, rememberMe: rememberMe);

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

  Future<void> _sendTokenToWebView(String token, Map<String, dynamic> user, {String provider = 'google', bool rememberMe = true}) async {
    try {
      final userJson = jsonEncode(user);
      print('🔄 Enviando token para WebView: $token (rememberMe: $rememberMe)');

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
        localStorage.setItem('user_data', '$userJson');
        localStorage.setItem('rememberMe', '$rememberMe');
        $emailJsCode

        // Também salvar no sessionStorage para a sessão atual
        sessionStorage.setItem('access_token', '$token');
        sessionStorage.setItem('auth_token', '$token');
        sessionStorage.setItem('authToken', '$token');
        sessionStorage.setItem('token', '$token');
        sessionStorage.setItem('user_data', '$userJson');

        console.log('Flutter: Token do $provider Auth salvo no localStorage (rememberMe: $rememberMe)');

        // Disparar evento customizado para o frontend processar
        window.dispatchEvent(new CustomEvent('authSuccess', {
          detail: {
            token: '$token',
            user: $userJson,
            provider: '$provider',
            rememberMe: $rememberMe
          }
        }));

        console.log('Flutter: Evento authSuccess disparado - frontend deve processar login');

        // Também enviar via postMessage (caso o frontend use essa abordagem)
        window.postMessage({
          type: 'authSuccess',
          token: '$token',
          user: $userJson,
          provider: '$provider',
          rememberMe: $rememberMe,
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
      // Verificar se "lembrar de mim" está ativo antes de restaurar
      final shouldRemember = await _authService.shouldRememberMe();
      if (!shouldRemember) {
        print('ℹ️ "Lembrar de mim" não está ativo - não restaurando sessão');
        return;
      }

      final token = await _authService.getToken();
      final user = await _authService.getUser();

      if (token != null && user != null) {
        print('🔄 Restaurando sessão do usuário (Lembrar de mim ativo)...');
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
          localStorage.setItem('user_data', '${jsonEncode(user)}');
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
          sessionStorage.setItem('user_data', '${jsonEncode(user)}');
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
        
        // Verificar permissão básica de localização (usar locationWhenInUse no Android)
        var locationStatus = Platform.isAndroid 
            ? await Permission.locationWhenInUse.status
            : await Permission.location.status;
        
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
          
          // Pequeno delay para garantir que o diálogo foi completamente fechado
          await Future.delayed(const Duration(milliseconds: 300));
          
          // No Android, usar locationWhenInUse é mais confiável
          if (Platform.isAndroid) {
            locationStatus = await Permission.locationWhenInUse.request();
          } else {
            locationStatus = await Permission.location.request();
          }
          
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

    print('📍 Iniciando monitoramento de localização via localStorage...');

    // Iniciar timer para verificar requisições de localização
    _locationMonitorTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      if (_isProcessingLocationRequest) {
        return; // Já está processando uma requisição
      }

      final jsCode = '''
        (function() {
          try {
            // Verificar se estamos em uma página de erro
            if (window.location.protocol === 'chrome-error:' || 
                window.location.href.startsWith('chrome-error://') ||
                typeof localStorage === 'undefined' || localStorage === null) {
              return null;
            }
            
            const request = localStorage.getItem('flutter_location_request');
            if (request) {
              // Remover imediatamente para evitar processamento duplicado
              localStorage.removeItem('flutter_location_request');
              return request;
            }
            return null;
          } catch(e) {
            return null;
          }
        })();
      ''';

      try {
        final result = await controller.runJavaScriptReturningResult(jsCode);
        final requestStr = result.toString().trim();
        
        // Remover aspas se o resultado vier como string JSON
        String cleanRequestStr = requestStr;
        if (cleanRequestStr.startsWith('"') && cleanRequestStr.endsWith('"')) {
          cleanRequestStr = cleanRequestStr.substring(1, cleanRequestStr.length - 1);
          cleanRequestStr = cleanRequestStr.replaceAll('\\"', '"');
        }

        if (cleanRequestStr != 'null' && cleanRequestStr.isNotEmpty && cleanRequestStr != '') {
          print('📍 Requisição de localização detectada no localStorage: $cleanRequestStr');
          _handleLocationRequest(cleanRequestStr);
        }
      } catch (e) {
        // Erro ao executar JavaScript, ignorar silenciosamente
        // (pode acontecer se a página ainda não carregou completamente)
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
        
        // Verificar permissão de localização (usar locationWhenInUse no Android)
        var locationStatus = Platform.isAndroid 
            ? await Permission.locationWhenInUse.status
            : await Permission.location.status;
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
          print('⚠️ Permissão de localização não concedida, mostrando rationale...');
          
          // Mostrar diálogo de rationale antes de solicitar permissão
          if (mounted) {
            final shouldRequest = await _showLocationRationale();
            if (!shouldRequest) {
              print('❌ Usuário cancelou a solicitação de permissão');
              await _sendLocationError('Permissão de localização cancelada pelo usuário', requestId);
              _isProcessingLocationRequest = false;
              return;
            }
            
            // Pequeno delay para garantir que o diálogo foi completamente fechado
            await Future.delayed(const Duration(milliseconds: 300));
          }
          
          print('⚠️ Solicitando permissão de localização...');
          // No Android, usar locationWhenInUse é mais confiável
          try {
            if (Platform.isAndroid) {
              print('📱 Android: Solicitando Permission.locationWhenInUse...');
              locationStatus = await Permission.locationWhenInUse.request();
              print('📱 Android: Resultado da solicitação: $locationStatus');
            } else {
              print('📱 iOS: Solicitando Permission.location...');
              locationStatus = await Permission.location.request();
              print('📱 iOS: Resultado da solicitação: $locationStatus');
            }
          } catch (e) {
            print('❌ Erro ao solicitar permissão: $e');
            await _sendLocationError('Erro ao solicitar permissão de localização: $e', requestId);
            _isProcessingLocationRequest = false;
            return;
          }
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
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 30),
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
        ),
      );

      print('✅ Localização obtida com sucesso!');
      print('   Latitude: ${position.latitude}');
      print('   Longitude: ${position.longitude}');
      print('   Precisão: ${position.accuracy}m');

      // Validar precisão da localização (deve ser < 10 metros para ser considerada precisa)
      const double maxAcceptableAccuracy = 10.0; // metros
      if (position.accuracy > maxAcceptableAccuracy) {
        print('⚠️ Precisão da localização (${position.accuracy}m) está acima do esperado (${maxAcceptableAccuracy}m)');
        // Ainda assim, enviar a localização, mas com aviso
        // Em alguns casos, mesmo com precisão menor, a localização pode ser útil
        // O usuário pode verificar se o endereço está correto
      } else {
        print('✅ Precisão da localização está dentro do esperado (${position.accuracy}m <= ${maxAcceptableAccuracy}m)');
      }

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
      // Criar wrapper para comunicação com Flutter WebView
      window.FlutterWebViewChannel = {
        postMessage: function(message) {
          try {
            // Tentar usar o channel FlutterWebView diretamente (criado pelo addJavaScriptChannel)
            if (typeof FlutterWebView !== 'undefined' && FlutterWebView.postMessage) {
              FlutterWebView.postMessage(JSON.stringify(message));
              console.log('✅ Mensagem enviada via FlutterWebView.postMessage');
              return;
            }
            // Fallback: tentar window.FlutterWebView (caso esteja disponível)
            if (window.FlutterWebView && window.FlutterWebView.postMessage) {
              window.FlutterWebView.postMessage(JSON.stringify(message));
              console.log('✅ Mensagem enviada via window.FlutterWebView.postMessage');
              return;
            }
            console.warn('⚠️ FlutterWebView channel não disponível');
          } catch (e) {
            console.error('❌ Erro ao enviar mensagem para Flutter:', e);
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
        
        console.log('📍 React: Solicitando localização do Flutter', request);
        
        // Método 1: Tentar enviar via canal JavaScript direto (mais rápido)
        try {
          if (window.FlutterWebViewChannel && window.FlutterWebViewChannel.postMessage) {
            console.log('📍 Tentando enviar via FlutterWebViewChannel...');
            window.FlutterWebViewChannel.postMessage({
              type: 'locationRequest',
              ...request
            });
            console.log('✅ Mensagem enviada via FlutterWebViewChannel');
          } else {
            console.warn('⚠️ FlutterWebViewChannel não disponível');
          }
        } catch (e) {
          console.error('❌ Erro ao enviar via FlutterWebViewChannel:', e);
        }
        
        // Método 2: Sempre enviar via localStorage também (garantir que será processado)
        try {
          localStorage.setItem('flutter_location_request', JSON.stringify(request));
          console.log('✅ Requisição salva no localStorage como fallback');
        } catch (e) {
          console.error('❌ Erro ao salvar no localStorage:', e);
        }
        
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

  void _disableFontScaling() {
    const js = '''
      (function() {
        try {
          // Criar ou atualizar estilo CSS para desabilitar font scaling
          var styleId = 'flutter-disable-font-scaling';
          var existingStyle = document.getElementById(styleId);
          
          if (existingStyle) {
            existingStyle.remove();
          }
          
          var style = document.createElement('style');
          style.id = styleId;
          style.textContent = `
            * {
              -webkit-text-size-adjust: 100% !important;
              text-size-adjust: 100% !important;
              -moz-text-size-adjust: 100% !important;
            }
            html {
              -webkit-text-size-adjust: 100% !important;
              text-size-adjust: 100% !important;
              -moz-text-size-adjust: 100% !important;
            }
            body {
              -webkit-text-size-adjust: 100% !important;
              text-size-adjust: 100% !important;
              -moz-text-size-adjust: 100% !important;
            }
          `;
          
          var head = document.head || document.getElementsByTagName('head')[0];
          if (head) {
            head.appendChild(style);
          }
          
          // Aplicar diretamente nos elementos principais também
          if (document.documentElement) {
            document.documentElement.style.setProperty('-webkit-text-size-adjust', '100%', 'important');
            document.documentElement.style.setProperty('text-size-adjust', '100%', 'important');
            document.documentElement.style.setProperty('-moz-text-size-adjust', '100%', 'important');
          }
          
          if (document.body) {
            document.body.style.setProperty('-webkit-text-size-adjust', '100%', 'important');
            document.body.style.setProperty('text-size-adjust', '100%', 'important');
            document.body.style.setProperty('-moz-text-size-adjust', '100%', 'important');
          }
          
          // Observar mudanças no DOM para aplicar em elementos dinâmicos
          if (window.MutationObserver) {
            var observer = new MutationObserver(function(mutations) {
              mutations.forEach(function(mutation) {
                mutation.addedNodes.forEach(function(node) {
                  if (node.nodeType === 1) { // Element node
                    node.style.setProperty('-webkit-text-size-adjust', '100%', 'important');
                    node.style.setProperty('text-size-adjust', '100%', 'important');
                    node.style.setProperty('-moz-text-size-adjust', '100%', 'important');
                  }
                });
              });
            });
            
            observer.observe(document.body || document.documentElement, {
              childList: true,
              subtree: true
            });
          }
        } catch (e) {
          console.log('Flutter: erro ao desabilitar font scaling', e);
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
              // Verificar se estamos em uma página de erro (chrome-error://)
              if (window.location.protocol === 'chrome-error:' || 
                  window.location.href.startsWith('chrome-error://') ||
                  window.location.href.startsWith('about:blank')) {
                return JSON.stringify({error: 'Página de erro - localStorage não disponível'});
              }
              
              // Verificar se localStorage está disponível
              if (typeof localStorage === 'undefined' || localStorage === null) {
                return JSON.stringify({error: 'localStorage não disponível'});
              }
              
              const allItems = {};
              // Ler todas as chaves do localStorage
              for (let i = 0; i < localStorage.length; i++) {
                const key = localStorage.key(i);
                if (key) {
                  try {
                    const value = localStorage.getItem(key);
                    // Tentar parsear como JSON se possível, senão usar como string
                    if (value && (value.trim().startsWith('{') || value.trim().startsWith('['))) {
                      try {
                        allItems[key] = JSON.parse(value);
                      } catch(e) {
                        allItems[key] = value;
                      }
                    } else {
                      allItems[key] = value;
                    }
                  } catch(e) {
                    // Se houver erro ao ler um item específico, pular
                    console.warn('Erro ao ler localStorage key:', key, e);
                  }
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
        
        // Tratar resultado nulo ou vazio
        if (resultStr.isEmpty || resultStr == 'null' || resultStr == 'undefined') {
          return;
        }
        
        // Remover aspas extras se houver (mas apenas se for uma string JSON válida)
        if (resultStr.startsWith('"') && resultStr.endsWith('"')) {
          // Verificar se é uma string JSON válida (começa e termina com aspas)
          try {
            // Tentar decodificar como string JSON primeiro
            resultStr = jsonDecode(resultStr) as String;
          } catch (e) {
            // Se falhar, apenas remover as aspas externas
            resultStr = resultStr.substring(1, resultStr.length - 1);
          }
        }
        
        // Tentar fazer unescape de caracteres especiais
        resultStr = resultStr.replaceAll('\\"', '"');
        resultStr = resultStr.replaceAll('\\n', '\n');
        resultStr = resultStr.replaceAll('\\r', '\r');
        resultStr = resultStr.replaceAll('\\t', '\t');
        resultStr = resultStr.replaceAll('\\\\', '\\');
        
        try {
          final Map<String, dynamic> localStorageData = jsonDecode(resultStr);
          
          // Verificar se há erro (página de erro, localStorage não disponível, etc.)
          if (localStorageData.containsKey('error')) {
            final errorMsg = localStorageData['error'].toString();
            // Só logar erro a cada 6 ciclos para não poluir os logs
            if (timer.tick % 6 == 0) {
              print('⚠️ [Ciclo ${timer.tick}] Erro ao acessar localStorage: $errorMsg');
            }
            return; // Parar processamento neste ciclo
          }
          
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
          // Log mais detalhado do erro
          final errorMsg = e.toString();
          final errorPos = errorMsg.contains('at character') 
              ? errorMsg.substring(errorMsg.indexOf('at character') + 13).split(')').first
              : 'unknown';
          
          // Mostrar contexto ao redor do erro
          if (resultStr.length > 300) {
            final pos = int.tryParse(errorPos) ?? 0;
            final start = (pos - 50).clamp(0, resultStr.length);
            final end = (pos + 50).clamp(0, resultStr.length);
            print('⚠️ Erro ao parsear localStorage: $e');
            print('📦 Posição do erro: caractere $errorPos');
            print('📦 Contexto (chars ${start}-${end}): ${resultStr.substring(start, end)}');
          } else {
            print('⚠️ Erro ao parsear localStorage: $e');
            print('📦 localStorage raw (${resultStr.length} chars): ${resultStr.length > 500 ? resultStr.substring(0, 500) + "..." : resultStr}');
          }
          
          // Tentar parsear parcialmente se possível
          try {
            // Tentar encontrar onde está o problema e pular valores problemáticos
            final sanitized = resultStr.replaceAll(RegExp(r'[^\x20-\x7E]'), '');
            if (sanitized != resultStr) {
              final Map<String, dynamic> partialData = jsonDecode(sanitized);
              print('📦 Parse parcial bem-sucedido após sanitização');
            }
          } catch (e2) {
            // Ignorar erro do parse parcial
          }
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
        final rememberMe = data['rememberMe'] == true || data['rememberMe'] == 'true';
        _handleAuthSuccess(data['token'], data['user'], rememberMe: rememberMe);
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

        // Salvar dados localmente (OAuth Apple - sempre salvar com rememberMe)
        await _authService.saveAuthData(token, user, rememberMe: true);

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

  void _handleAuthSuccess(String token, Map<String, dynamic> user, {bool rememberMe = false}) async {
    try {
      print('✅ Processando autenticação bem-sucedida (rememberMe: $rememberMe)');
      
      // Salvar dados de autenticação no Flutter apenas se "lembrar de mim" estiver ativo
      await _authService.saveAuthData(token, user, rememberMe: rememberMe);
      _lastKnownToken = rememberMe ? token : null;
      
      print('✅ Autenticação processada com sucesso');
    } catch (e) {
      print('❌ Erro ao processar autenticação: $e');
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
      print('🚪 Iniciando processo de logout...');
      
      // Limpar dados de autenticação no Flutter
      await _authService.logout();
      _lastKnownToken = null;
      _lastRegisteredEmail = null; // Limpar email registrado ao fazer logout
      _lastFcmFailedEmail = null; // Limpar email que falhou
      _firebaseBlockedUntil = null; // Limpar bloqueio do Firebase
      _lastFcmRegistrationAttempt = null; // Limpar tentativa de registro
      
      // Limpar todos os dados de autenticação na WebView
      final jsCode = '''
        // Limpar localStorage
        localStorage.removeItem('access_token');
        localStorage.removeItem('auth_token');
        localStorage.removeItem('authToken');
        localStorage.removeItem('token');
        localStorage.removeItem('user');
        localStorage.removeItem('nameUser');
        localStorage.removeItem('userName');
        localStorage.removeItem('idUser');
        localStorage.removeItem('userId');
        localStorage.removeItem('user_id');
        localStorage.removeItem('rememberMe');
        localStorage.removeItem('userEmail');
        localStorage.removeItem('user_email');
        localStorage.removeItem('email');
        
        // Limpar sessionStorage
        sessionStorage.removeItem('access_token');
        sessionStorage.removeItem('auth_token');
        sessionStorage.removeItem('authToken');
        sessionStorage.removeItem('token');
        sessionStorage.removeItem('user');
        sessionStorage.removeItem('nameUser');
        sessionStorage.removeItem('userName');
        sessionStorage.removeItem('idUser');
        sessionStorage.removeItem('userId');
        sessionStorage.removeItem('user_id');
        sessionStorage.removeItem('userEmail');
        
        // Disparar evento de logout
        window.postMessage({
          type: 'logoutSuccess',
          source: 'flutter'
        }, '*');
        
        // Disparar evento customizado
        window.dispatchEvent(new CustomEvent('logout', {
          detail: {
            source: 'flutter'
          }
        }));
        
        console.log('✅ Flutter: Logout realizado com sucesso - todos os dados foram limpos');
      ''';
      
      await controller.runJavaScript(jsCode);
      print('✅ Logout realizado com sucesso - dados limpos no Flutter e WebView');
      
      // Recarregar página de login
      controller.loadRequest(Uri.parse('https://icarfront.vercel.app/?source=mobile'));
    } catch (e) {
      print('❌ Erro ao fazer logout: $e');
    }
  }

  // Inicializar push notifications
  Future<void> _initPushNotifications() async {
    try {
      // Inicializar notificações locais
      await _initializeLocalNotifications();
      
      // Solicitar permissões do Android (especialmente importante para Android 13+ e Samsung)
      if (Platform.isAndroid) {
        // Solicitar permissão POST_NOTIFICATIONS (Android 13+)
        final notificationPermission = await Permission.notification.request();
        print('📱 Permissão POST_NOTIFICATIONS: $notificationPermission');
        
        // Solicitar permissão para ignorar otimização de bateria (especialmente importante para Samsung)
        try {
          final batteryOptimizationStatus = await Permission.ignoreBatteryOptimizations.status;
          if (batteryOptimizationStatus.isDenied) {
            print('📱 Solicitando permissão para ignorar otimização de bateria...');
            final batteryResult = await Permission.ignoreBatteryOptimizations.request();
            print('📱 Permissão de otimização de bateria: $batteryResult');
          } else {
            print('✅ Permissão de otimização de bateria já concedida');
          }
        } catch (e) {
          print('⚠️ Erro ao solicitar permissão de otimização de bateria: $e');
        }
      }
      
      // Solicitar permissão de notificações do Firebase
      final messaging = FirebaseMessaging.instance;
      
      NotificationSettings settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      print('📱 Permissão de notificações Firebase: ${settings.authorizationStatus}');

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
        _handleNotificationClick(message);
      });

      // Verificar se o app foi aberto por uma notificação
      RemoteMessage? initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        print('📱 App aberto por notificação: ${initialMessage.messageId}');
        _handleNotificationClick(initialMessage);
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
        
        // Tentar parsear o payload como dados JSON
        if (response.payload != null && response.payload!.isNotEmpty) {
          try {
            // O payload vem como JSON string, precisamos parsear
            final payloadMap = jsonDecode(response.payload!) as Map<String, dynamic>;
            
            // Verificar se é uma notificação de chat
            if (payloadMap['type'] == 'chat') {
              // Criar RemoteMessage simulado para usar a mesma função de navegação
              final simulatedMessage = RemoteMessage(
                messageId: response.id.toString(),
                data: payloadMap,
              );
              _handleNotificationClick(simulatedMessage);
            }
          } catch (e) {
            print('❌ Erro ao processar payload da notificação local: $e');
            print('   Tentando método alternativo...');
            
            // Fallback: tentar extrair dados básicos do payload string
            try {
              final payloadString = response.payload!;
              if (payloadString.contains('type') && payloadString.contains('chat')) {
                final oficinaIdMatch = RegExp(r'oficina_id[:\s]*(\d+)').firstMatch(payloadString);
                final sosIdMatch = RegExp(r'sos_id[:\s]*(\d+)').firstMatch(payloadString);
                
                if (oficinaIdMatch != null) {
                  final payloadMap = <String, dynamic>{
                    'type': 'chat',
                    'oficina_id': oficinaIdMatch.group(1),
                  };
                  if (sosIdMatch != null) {
                    payloadMap['sos_id'] = sosIdMatch.group(1);
                  }
                  
                  final simulatedMessage = RemoteMessage(
                    messageId: response.id.toString(),
                    data: payloadMap,
                  );
                  _handleNotificationClick(simulatedMessage);
                }
              }
            } catch (e2) {
              print('❌ Erro no método alternativo: $e2');
            }
          }
        }
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

    // Log de todos os dados recebidos
    print('📱 Dados da notificação: ${message.data}');
    print('📱 Chaves dos dados: ${message.data.keys.toList()}');

    // Buscar URL do ícone do remetente nos dados
    // PRIORIDADE: sender_icon_url > image (se image for do sender)
    String? senderIconUrl;
    if (message.data.containsKey('sender_icon_url')) {
      senderIconUrl = message.data['sender_icon_url'];
      print('📱 URL do ícone do remetente encontrada (sender_icon_url): $senderIconUrl');
    } else if (message.data.containsKey('image')) {
      // Se não temos sender_icon_url, verificar se 'image' é do sender
      // (se image == sender_icon_url ou se não temos sender_icon_url mas temos image)
      final imageUrl = message.data['image'];
      // Verificar se image não é o logo padrão do iCar
      if (imageUrl != null && 
          imageUrl.toString().isNotEmpty && 
          !imageUrl.toString().contains('icar.skalacode.com/images/logo.png')) {
        senderIconUrl = imageUrl.toString();
        print('📱 Usando image como senderIconUrl (não é logo padrão): $senderIconUrl');
      } else {
        print('⚠️ image é logo padrão do iCar, ignorando');
      }
    } else {
      print('⚠️ sender_icon_url e image não encontrados nos dados');
    }

    // Baixar imagem do ícone se disponível
    String? largeIconPath;
    if (senderIconUrl != null && senderIconUrl.isNotEmpty && senderIconUrl != 'null') {
      try {
        print('📥 Baixando ícone de: $senderIconUrl');
        // Baixar imagem da URL
        final response = await http.get(Uri.parse(senderIconUrl));
        print('📥 Status da resposta: ${response.statusCode}');
        print('📥 Tamanho da resposta: ${response.bodyBytes.length} bytes');
        
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          // Salvar temporariamente
          final tempDir = await getTemporaryDirectory();
          final file = File('${tempDir.path}/notification_icon_${message.hashCode}.png');
          await file.writeAsBytes(response.bodyBytes);
          largeIconPath = file.path;
          
          // Verificar se o arquivo foi criado
          final fileExists = await file.exists();
          final fileSize = await file.length();
          print('✅ Ícone do remetente baixado: $largeIconPath');
          print('✅ Arquivo existe: $fileExists, Tamanho: $fileSize bytes');
        } else {
          print('❌ Falha ao baixar: status ${response.statusCode}, tamanho ${response.bodyBytes.length}');
        }
      } catch (e, stackTrace) {
        print('❌ Erro ao baixar ícone do remetente: $e');
        print('❌ Stack trace: $stackTrace');
      }
    } else {
      print('⚠️ senderIconUrl é null, vazio ou "null"');
    }

    // Log antes de criar AndroidNotificationDetails
    print('📱 Criando AndroidNotificationDetails com largeIcon: ${largeIconPath ?? "null"}');
    
    // O smallIcon (icon) no Android deve ser um recurso drawable, não um arquivo
    // Usar @drawable/ic_notification_car conforme configurado no AndroidManifest.xml
    // Se app_icon_url estiver presente nos dados, logamos para referência
    String? appIconUrl = message.data['app_icon_url'];
    if (appIconUrl != null && appIconUrl.isNotEmpty && appIconUrl != 'null') {
      print('📱 Ícone do iCar disponível em app_icon_url: $appIconUrl (usando @drawable/ic_notification_car como smallIcon)');
    }
    
    final androidDetails = AndroidNotificationDetails(
      'high_importance_channel',
      'Notificações Importantes',
      channelDescription: 'Este canal é usado para notificações importantes',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      playSound: true,
      enableVibration: true,
      largeIcon: largeIconPath != null ? FilePathAndroidBitmap(largeIconPath) : null,
      // Usar ícone de notificação específico do iCar (ic_notification_car)
      icon: '@drawable/ic_notification_car', // Ícone de notificação do iCar
    );
    
    print('📱 AndroidNotificationDetails criado com largeIcon: ${androidDetails.largeIcon != null}');

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Criar payload JSON para a notificação local
    final payloadJson = jsonEncode(message.data);
    
    await _localNotifications.show(
      message.hashCode,
      notification.title ?? 'Nova notificação',
      notification.body ?? '',
      details,
      payload: payloadJson,
    );
  }

  // Função para salvar dados da notificação no sessionStorage
  void _saveNotificationDataToSessionStorage(Map<String, dynamic> data) {
    final oficinaId = data['oficina_id'];
    final sosId = data['sos_id'];
    final oficinaNome = data['oficina_nome'] ?? 'Oficina';
    
    final sosIdStr = sosId?.toString() ?? '';
    final oficinaIdStr = oficinaId?.toString() ?? '';
    final oficinaNomeEscaped = oficinaNome.replaceAll("'", "\\'").replaceAll("\n", "\\n").replaceAll("\r", "");
    
    print('💾 Salvando dados no sessionStorage:');
    print('   oficinaId: $oficinaIdStr');
    print('   sosId: $sosIdStr');
    print('   oficinaNome: $oficinaNomeEscaped');
    
    final jsCode = '''
      (function() {
        try {
          console.log('💾 [Flutter] Iniciando salvamento de dados no sessionStorage...');
          
          // Salvar dados da oficina no sessionStorage
          const oficinaData = {
            id: parseInt('$oficinaIdStr'),
            name: '$oficinaNomeEscaped',
            sos_id: ${sosIdStr.isNotEmpty && sosIdStr != '0' ? "parseInt('$sosIdStr')" : 'null'}
          };
          
          sessionStorage.setItem('oficinaData', JSON.stringify(oficinaData));
          sessionStorage.setItem('oficinaId', '$oficinaIdStr');
          
          ${sosIdStr.isNotEmpty && sosIdStr != '0' ? "sessionStorage.setItem('sosId', '$sosIdStr');" : ''}
          ${sosIdStr.isNotEmpty && sosIdStr != '0' ? "sessionStorage.setItem('current_sos_id', '$sosIdStr');" : ''}
          
          // Verificar se foi salvo corretamente
          const savedOficinaData = sessionStorage.getItem('oficinaData');
          const savedOficinaId = sessionStorage.getItem('oficinaId');
          const savedSosId = sessionStorage.getItem('sosId');
          const savedCurrentSosId = sessionStorage.getItem('current_sos_id');
          
          console.log('✅ [Flutter] Dados salvos no sessionStorage:');
          console.log('   oficinaData:', savedOficinaData);
          console.log('   oficinaId:', savedOficinaId);
          console.log('   sosId:', savedSosId);
          console.log('   current_sos_id:', savedCurrentSosId);
          
          // Disparar evento para o componente detectar
          window.dispatchEvent(new StorageEvent('storage', {
            key: 'oficinaData',
            newValue: savedOficinaData
          }));
          
          // Forçar reload se estiver na página de chat
          if (window.location.pathname.includes('/chat')) {
            console.log('🔄 [Flutter] Detectado que está na página de chat, disparando evento de reload...');
            window.dispatchEvent(new CustomEvent('chatDataUpdated', {
              detail: {
                oficinaId: '$oficinaIdStr',
                sosId: '${sosIdStr.isNotEmpty && sosIdStr != '0' ? sosIdStr : ''}'
              }
            }));
          }
        } catch(e) {
          console.error('❌ [Flutter] Erro ao salvar dados no sessionStorage:', e);
          console.error('   Stack:', e.stack);
        }
      })();
    ''';
    
    controller.runJavaScript(jsCode);
    print('💾 Comando JavaScript enviado para salvar dados');
  }

  // Função para tratar clique em notificação e navegar para o chat
  Future<void> _handleNotificationClick(RemoteMessage message) async {
    print('🔍 Processando clique na notificação...');
    print('📱 Tipo: ${message.data['type']}');
    print('📱 Dados completos: ${message.data}');
    
    // Verificar se é uma notificação de chat
    if (message.data['type'] == 'chat') {
      final oficinaId = message.data['oficina_id'];
      final sosId = message.data['sos_id'];
      final oficinaNome = message.data['oficina_nome'] ?? 'Oficina';
      
      print('💬 Notificação de chat detectada');
      print('   Oficina ID: $oficinaId');
      print('   SOS ID: $sosId');
      print('   Oficina Nome: $oficinaNome');
      
      if (oficinaId != null) {
        // Preparar dados
        final dataToSave = {
          'oficina_id': oficinaId,
          'sos_id': sosId,
          'oficina_nome': oficinaNome,
        };
        
        // Salvar dados no sessionStorage ANTES de navegar
        // Isso garante que os dados estejam disponíveis quando o componente carregar
        final sosIdStr = sosId?.toString() ?? '';
        final oficinaIdStr = oficinaId.toString();
        final oficinaNomeEscaped = oficinaNome.replaceAll("'", "\\'").replaceAll("\n", "\\n").replaceAll("\r", "");
        
        print('💾 Salvando dados no sessionStorage ANTES de navegar...');
        final preSaveJsCode = '''
          (function() {
            try {
              console.log('💾 [Flutter] Salvando dados ANTES da navegação...');
              
              const oficinaData = {
                id: parseInt('$oficinaIdStr'),
                name: '$oficinaNomeEscaped',
                sos_id: ${sosIdStr.isNotEmpty && sosIdStr != '0' ? "parseInt('$sosIdStr')" : 'null'}
              };
              
              sessionStorage.setItem('oficinaData', JSON.stringify(oficinaData));
              sessionStorage.setItem('oficinaId', '$oficinaIdStr');
              
              ${sosIdStr.isNotEmpty && sosIdStr != '0' ? "sessionStorage.setItem('sosId', '$sosIdStr');" : ''}
              ${sosIdStr.isNotEmpty && sosIdStr != '0' ? "sessionStorage.setItem('current_sos_id', '$sosIdStr');" : ''}
              
              console.log('✅ [Flutter] Dados salvos ANTES da navegação:', {
                oficinaData: JSON.stringify(oficinaData),
                oficinaId: '$oficinaIdStr',
                sosId: '${sosIdStr.isNotEmpty && sosIdStr != '0' ? sosIdStr : 'null'}'
              });
            } catch(e) {
              console.error('❌ [Flutter] Erro ao salvar dados:', e);
            }
          })();
        ''';
        
        // Executar JavaScript para salvar dados antes de navegar
        controller.runJavaScript(preSaveJsCode);
        
        // Aguardar um pouco para garantir que o JS foi executado
        await Future.delayed(const Duration(milliseconds: 200));
        
        // Armazenar dados também para salvar novamente quando a página carregar (backup)
        _pendingNotificationData = dataToSave;
        
        // Construir URL do chat com parâmetros
        String chatUrl = 'https://icarfront.vercel.app/chat?source=mobile';
        if (oficinaId != null && oficinaId.toString().isNotEmpty) {
          chatUrl += '&oficina_id=$oficinaId';
        }
        if (sosId != null && sosId.toString().isNotEmpty && sosId != '0') {
          chatUrl += '&sos_id=$sosId';
        }
        
        print('🔄 Navegando para: $chatUrl');
        
        // Navegar para o chat
        controller.loadRequest(Uri.parse(chatUrl));
      } else {
        print('⚠️ Oficina ID não encontrado, navegando para chat genérico');
        controller.loadRequest(Uri.parse('https://icarfront.vercel.app/chat?source=mobile'));
      }
    } else {
      print('ℹ️ Notificação não é do tipo chat, ignorando navegação');
    }
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
            try {
              // Verificar se estamos em uma página de erro
              if (window.location.protocol === 'chrome-error:' || 
                  window.location.href.startsWith('chrome-error://') ||
                  typeof localStorage === 'undefined' || localStorage === null) {
                return JSON.stringify({error: 'Página de erro - storage não disponível'});
              }
              
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
          } catch(e) {
            return JSON.stringify({error: e.toString()});
          }
        })();
        ''';

        debugLogger.addLog('🔍 [Ciclo ${timer.tick}] Executando JavaScript para ler localStorage...', level: LogLevel.debug);
        
        final result = await controller.runJavaScriptReturningResult(jsCode);
        String resultStr = result.toString().trim();
        
        debugLogger.addLog('📦 [Ciclo ${timer.tick}] Resultado raw do JavaScript: ${resultStr.length > 200 ? resultStr.substring(0, 200) + "..." : resultStr}', level: LogLevel.debug);
        
        // Tratar resultado nulo ou vazio
        if (resultStr.isEmpty || resultStr == 'null' || resultStr == 'undefined') {
          return;
        }
        
        // Remover aspas extras se houver (mas apenas se for uma string JSON válida)
        if (resultStr.startsWith('"') && resultStr.endsWith('"')) {
          try {
            // Tentar decodificar como string JSON primeiro
            resultStr = jsonDecode(resultStr) as String;
          } catch (e) {
            // Se falhar, apenas remover as aspas externas
            resultStr = resultStr.substring(1, resultStr.length - 1);
          }
        }
        
        // Tentar fazer unescape de caracteres especiais
        resultStr = resultStr.replaceAll('\\"', '"');
        resultStr = resultStr.replaceAll('\\n', '\n');
        resultStr = resultStr.replaceAll('\\r', '\r');
        resultStr = resultStr.replaceAll('\\t', '\t');
        resultStr = resultStr.replaceAll('\\\\', '\\');
        
        // Parse do resultado JSON
        Map<String, dynamic>? data;
        try {
          data = jsonDecode(resultStr);
          
          // Verificar se há erro (página de erro, storage não disponível, etc.)
          if (data != null && data.containsKey('error')) {
            final errorMsg = data['error'].toString();
            // Só logar erro a cada 6 ciclos para não poluir os logs
            if (timer.tick % 6 == 0) {
              debugLogger.addLog('⚠️ [Ciclo ${timer.tick}] Erro ao acessar storage: $errorMsg', level: LogLevel.warning);
              print('⚠️ [Ciclo ${timer.tick}] Erro ao acessar storage: $errorMsg');
            }
            return; // Parar processamento neste ciclo
          }
          
          debugLogger.addLog('✅ [Ciclo ${timer.tick}] JSON parseado com sucesso', level: LogLevel.debug);
        } catch (e) {
          // Log mais detalhado do erro
          final errorMsg = e.toString();
          final errorPos = errorMsg.contains('at character') 
              ? errorMsg.substring(errorMsg.indexOf('at character') + 13).split(')').first
              : 'unknown';
          
          debugLogger.addLog('❌ [Ciclo ${timer.tick}] Erro ao parsear resultado do monitoramento: $e', level: LogLevel.error);
          
          // Mostrar contexto ao redor do erro
          if (resultStr.length > 300) {
            final pos = int.tryParse(errorPos) ?? 0;
            final start = (pos - 50).clamp(0, resultStr.length);
            final end = (pos + 50).clamp(0, resultStr.length);
            debugLogger.addLog('📦 [Ciclo ${timer.tick}] Posição do erro: caractere $errorPos', level: LogLevel.error);
            debugLogger.addLog('📦 [Ciclo ${timer.tick}] Contexto (chars ${start}-${end}): ${resultStr.substring(start, end)}', level: LogLevel.error);
          } else {
            debugLogger.addLog('📦 [Ciclo ${timer.tick}] Resultado raw (${resultStr.length} chars): ${resultStr.length > 500 ? resultStr.substring(0, 500) + "..." : resultStr}', level: LogLevel.error);
          }
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
        
        // Log apenas quando houver mudança significativa (email encontrado ou token registrado)
        if (emailToUse != null && emailToUse.isNotEmpty && emailToUse.contains('@')) {
          final logMessage = '📧 Email detectado: ${emailToUse.substring(0, emailToUse.indexOf('@'))}@***, FCM=${hasFcmToken ? "SIM" : "NÃO"}';
          debugLogger.addLog(logMessage, level: LogLevel.info);
        }
        
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

      // 1. Autenticar no Firebase
      UserCredential? userCredential;
      try {
        // Tentar fazer login primeiro
        userCredential = await _auth.signInWithEmailAndPassword(
          email: email,
          password: _defaultPassword,
        );
        
        debugLogger.addLog('✅ [PushNotificationService] Login Firebase bem-sucedido', level: LogLevel.info);
      } catch (e) {
        debugLogger.addLog('⚠️ [PushNotificationService] Erro ao fazer login: $e', level: LogLevel.warning);
        
        // Se o usuário não existe ou credenciais inválidas, tentar criar conta
        // invalid-credential pode significar que o usuário não existe
        if (e.toString().contains('user-not-found') || 
            e.toString().contains('wrong-password') ||
            e.toString().contains('invalid-credential')) {
          debugLogger.addLog('📝 [PushNotificationService] Usuário não encontrado, criando conta...', level: LogLevel.info);
          try {
            userCredential = await _auth.createUserWithEmailAndPassword(
              email: email,
              password: _defaultPassword,
            );
            
            debugLogger.addLog('✅ [PushNotificationService] Conta Firebase criada com sucesso', level: LogLevel.info);
          } catch (createError) {
            debugLogger.addLog('❌ [PushNotificationService] Erro ao criar conta Firebase: $createError', level: LogLevel.error);
            // Se falhar ao criar (pode ser que já exista), tentar login novamente
            try {
              userCredential = await _auth.signInWithEmailAndPassword(
                email: email,
                password: _defaultPassword,
              );
              
              debugLogger.addLog('✅ [PushNotificationService] Login Firebase bem-sucedido após tentativa de criação', level: LogLevel.info);
            } catch (retryError) {
              debugLogger.addLog('❌ [PushNotificationService] Erro ao fazer login após tentativa de criação: $retryError', level: LogLevel.error);
              // Lançar exceção para que o erro seja capturado no _registerPushToken
              rethrow;
            }
          }
        } else {
          debugLogger.addLog('❌ [PushNotificationService] Erro ao autenticar no Firebase: $e', level: LogLevel.error);
          
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
        
        fcmToken = await _messaging.getToken();
        
        if (fcmToken == null) {
          debugLogger.addLog('❌ [PushNotificationService] Token FCM é null', level: LogLevel.error);
          return null;
        }
        
        debugLogger.addLog('✅ [PushNotificationService] Token FCM obtido com sucesso', level: LogLevel.info);
      } catch (e) {
        debugLogger.addLog('❌ [PushNotificationService] Erro ao obter token FCM: $e', level: LogLevel.error);
        return null;
      }

      // 3. Enviar token para o backend
      try {
        debugLogger.addLog('📱 [PushNotificationService] Enviando token para o backend...', level: LogLevel.info);
        
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
        }

        final requestData = {
          'email': email,
          'fcm_token': fcmToken,
          'platform': platform,
        };

        final response = await _dio.post(
          '/api/push-token',
          data: requestData,
          options: Options(headers: headers),
        );
        
        if (response.statusCode == 200 || response.statusCode == 201) {
          debugLogger.addLog('✅ [PushNotificationService] Token FCM registrado com sucesso no backend', level: LogLevel.info);
          return fcmToken;
        } else {
          debugLogger.addLog('⚠️ [PushNotificationService] Resposta inesperada do backend: ${response.statusCode}', level: LogLevel.warning);
          return null;
        }
      } on DioException catch (e) {
        debugLogger.addLog('❌ [PushNotificationService] Erro ao enviar token: ${e.type}, Status: ${e.response?.statusCode}', level: LogLevel.error);
        
        // Se for erro 422 (validação) ou 404 (usuário não encontrado), retornar null
        if (e.response?.statusCode == 422 || e.response?.statusCode == 404) {
          return null;
        }
        
        // Para outros erros, considerar sucesso parcial (token foi obtido)
        return fcmToken;
      } catch (e) {
        debugLogger.addLog('❌ [PushNotificationService] Erro geral ao enviar token: $e', level: LogLevel.error);
        return fcmToken; // Retornar o token mesmo com erro parcial
      }
    } catch (e, stackTrace) {
      debugLogger.addLog('❌ [PushNotificationService] Erro geral ao registrar token: $e', level: LogLevel.error);
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
  static const _rememberMeKey = 'remember_me';
  
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

  Future<bool> shouldRememberMe() async {
    final rememberMe = await _storage.read(key: _rememberMeKey);
    // Se não estiver definido, assumir false (não lembrar)
    if (rememberMe == null) {
      return false;
    }
    return rememberMe == 'true';
  }

  Future<String?> getToken() async {
    // Verificar se "lembrar de mim" está ativo antes de retornar o token
    final shouldRemember = await shouldRememberMe();
    if (!shouldRemember) {
      return null;
    }
    return await _storage.read(key: _tokenKey);
  }

  Future<Map<String, dynamic>?> getUser() async {
    // Verificar se "lembrar de mim" está ativo antes de retornar os dados do usuário
    final shouldRemember = await shouldRememberMe();
    if (!shouldRemember) {
      return null;
    }
    final userJson = await _storage.read(key: _userKey);
    if (userJson != null) {
      return jsonDecode(userJson);
    }
    return null;
  }

  Future<void> saveAuthData(String token, Map<String, dynamic> user, {bool rememberMe = false}) async {
    if (rememberMe) {
      // Salvar dados apenas se "lembrar de mim" estiver ativo
      await _storage.write(key: _tokenKey, value: token);
      await _storage.write(key: _userKey, value: jsonEncode(user));
      await _storage.write(key: _rememberMeKey, value: 'true');
      print('✅ Credenciais salvas com "Lembrar de mim" ativado');
    } else {
      // Não salvar no FlutterSecureStorage se "lembrar de mim" não estiver ativo
      // Mas limpar qualquer dado anterior
      await _storage.delete(key: _tokenKey);
      await _storage.delete(key: _userKey);
      await _storage.write(key: _rememberMeKey, value: 'false');
      print('ℹ️ Credenciais não salvas (Lembrar de mim desativado)');
    }
  }

  Future<void> logout() async {
    // Limpar todos os dados de autenticação
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userKey);
    await _storage.delete(key: _rememberMeKey);
    print('✅ Todos os dados de autenticação foram removidos');
  }

  Dio get httpClient => _dio;
}