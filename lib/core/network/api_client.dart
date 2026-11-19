import 'package:dio/dio.dart';

import '../storage/session_storage.dart';
import 'api_failure.dart';
import 'offline_request_queue.dart';
import 'offline_request_store.dart';

class ApiClient {
  ApiClient({
    required String baseUrl,
    required SessionStorage storage,
    Dio? refreshClient,
    OfflineRequestStore? offlineStore,
  }) : _storage = storage,
       _refreshClient =
           refreshClient ??
           Dio(
             BaseOptions(
               baseUrl: baseUrl.replaceFirst(RegExp(r'/$'), ''),
               connectTimeout: const Duration(seconds: 30),
               sendTimeout: const Duration(seconds: 30),
               receiveTimeout: const Duration(seconds: 30),
               headers: const {'Accept': 'application/json'},
             ),
           ),
       dio = Dio(
         BaseOptions(
           baseUrl: baseUrl.replaceFirst(RegExp(r'/$'), ''),
           // Em 3G/4G fraco o handshake TLS e o envio do corpo demoram bem
           // mais que no Wi-Fi; os limites antigos (15 s/30 s) cortavam o
           // envio da entrega no meio e ela nunca chegava ao backend.
           connectTimeout: const Duration(seconds: 30),
           sendTimeout: const Duration(seconds: 60),
           receiveTimeout: const Duration(seconds: 45),
           headers: const {'Accept': 'application/json'},
         ),
       ) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          final problem = unexpectedFormat(response);
          if (problem == null) {
            handler.next(response);
            return;
          }
          handler.reject(
            DioException(
              requestOptions: response.requestOptions,
              response: response,
              type: DioExceptionType.badResponse,
              error: UnexpectedResponseFormat(problem),
            ),
            true,
          );
        },
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await storage.readToken();
          if (token != null) options.headers['Authorization'] = 'Bearer $token';
          // Mesmo código no log do servidor e na mensagem de erro do app,
          // inclusive quando a resposta nunca chega (timeout no 4G).
          options.headers.putIfAbsent(ApiFailure.requestIdHeader, newRequestId);
          handler.next(options);
        },
        onError: (error, handler) async {
          final request = error.requestOptions;
          if (error.response?.statusCode != 401 ||
              request.extra['tokenRefreshAttempted'] == true ||
              _isLoginOrTokenRequest(request.path)) {
            handler.next(error);
            return;
          }

          final String? access;
          try {
            access = await _refreshAccessToken();
          } on _RefreshUnavailable catch (unavailable) {
            // Renovação sem sinal (ou servidor fora): não é sessão expirada.
            // Seguir com o 401 fazia a fila pedir login e as telas não
            // usarem a cópia do aparelho.
            final cause = unavailable.error;
            handler.next(
              DioException(
                requestOptions: request,
                response: cause.response,
                type: cause.response == null
                    ? cause.type
                    : DioExceptionType.badResponse,
                error: cause.error,
                message: 'Não foi possível renovar a sessão agora.',
              ),
            );
            return;
          }
          if (access == null) {
            handler.next(error);
            return;
          }

          request.extra['tokenRefreshAttempted'] = true;
          request.headers['Authorization'] = 'Bearer $access';
          try {
            handler.resolve(await dio.fetch<dynamic>(request));
          } on DioException catch (retryError) {
            handler.next(retryError);
          }
        },
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) async {
          final request = error.requestOptions;
          final attempt = (request.extra[_readRetryKey] as int?) ?? 0;
          if (!_isRetryableRead(request) ||
              attempt >= readRetryDelays.length ||
              !OfflineRequestQueue.isNetworkFailure(error)) {
            handler.next(error);
            return;
          }
          // Leitura é idempotente: no 4G uma oscilação curta ou um 502 do
          // proxy derrubava a tela inteira (o mapa faz ~8 GETs ao abrir e
          // bastava um falhar). Repete com espera crescente antes de desistir.
          await Future<void>.delayed(readRetryDelays[attempt]);
          request.extra[_readRetryKey] = attempt + 1;
          try {
            handler.resolve(await dio.fetch<dynamic>(request));
          } on DioException catch (retryError) {
            handler.next(retryError);
          }
        },
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) {
          // Sonda de conectividade sem sinal falha a cada tentativa; no log
          // (40 entradas) ela empurrava para fora a falha real que o suporte
          // precisa ver.
          if (error.type != DioExceptionType.cancel &&
              error.requestOptions.extra[noFailureLog] != true) {
            failureLog.record(ApiFailure.fromDio(error));
          }
          handler.next(error);
        },
      ),
    );
    offlineRequests = OfflineRequestQueue(dio, storage, store: offlineStore);
  }

  /// Histórico das últimas falhas (tela de diagnóstico).
  ApiFailureLog failureLog = ApiFailureLog.instance;

  /// Motivo pelo qual uma resposta 2xx não é o JSON esperado da API, ou
  /// `null` quando está tudo certo.
  ///
  /// No 4G, quando o pacote de dados acaba ou num Wi-Fi com login, a
  /// operadora responde 200 com uma página HTML no lugar da API. Antes isso
  /// era aceito: a baixa saía da fila como enviada sem nunca ter chegado ao
  /// servidor, e a entrega "voltava" depois.
  static String? unexpectedFormat(Response<dynamic> response) {
    final request = response.requestOptions;
    if (request.responseType != ResponseType.json) return null;
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300 || status == 204) return null;
    final data = response.data;
    if (data is Map || data is List || data is num || data is bool) {
      return null;
    }
    final text = data?.toString().trim() ?? '';
    final read = request.method == 'GET' || request.method == 'HEAD';
    if (text.isEmpty) return read ? 'resposta vazia' : null;
    final contentType = response.headers.value(Headers.contentTypeHeader);
    final preview = text.length > 60 ? '${text.substring(0, 60)}…' : text;
    return 'corpo não JSON (${contentType ?? 'sem content-type'}): '
        '${preview.replaceAll(RegExp(r'\s+'), ' ')}';
  }

  static const _readRetryKey = 'readRetryAttempt';

  /// Marque `extra[ApiClient.noReadRetry] = true` em sondas que precisam
  /// falhar rápido (ex.: teste de alcance da fila offline).
  static const noReadRetry = 'noReadRetry';

  /// Marque `extra[ApiClient.noFailureLog] = true` em requisições cuja falha
  /// é esperada e não deve ir para o histórico de diagnóstico.
  static const noFailureLog = 'noFailureLog';

  /// Espera antes de cada nova tentativa de leitura.
  List<Duration> readRetryDelays = const [
    Duration(milliseconds: 800),
    Duration(seconds: 2),
  ];

  static bool _isRetryableRead(RequestOptions request) =>
      (request.method == 'GET' || request.method == 'HEAD') &&
      request.extra[noReadRetry] != true;

  Future<String?>? _refreshOperation;
  Future<void> Function()? onSessionRenewed;

  final SessionStorage _storage;
  final Dio _refreshClient;
  final Dio dio;
  late final OfflineRequestQueue offlineRequests;

  bool _isLoginOrTokenRequest(String path) {
    return path.endsWith('/api/v1/auth/entregadores/token/') ||
        path.endsWith('/api/v1/auth/token/') ||
        path.endsWith('/api/v1/auth/token/verify/') ||
        path.endsWith('/api/v1/auth/token/refresh/');
  }

  Future<String?> _refreshAccessToken() async {
    final ongoing = _refreshOperation;
    if (ongoing != null) return ongoing;

    final operation = _requestNewAccessToken();
    _refreshOperation = operation;
    String? access;
    try {
      access = await operation;
    } finally {
      if (identical(_refreshOperation, operation)) {
        _refreshOperation = null;
      }
    }
    if (access != null) {
      try {
        await onSessionRenewed?.call();
      } catch (_) {
        // A renovacao do token continua valida mesmo se a sincronizacao da
        // configuracao estiver temporariamente indisponivel.
      }
    }
    return access;
  }

  /// Renova o access token para clientes autenticados que não passam pelo
  /// interceptor HTTP, como o handshake do WebSocket. `null` se não deu.
  Future<String?> refreshAccessToken() async {
    try {
      return await _refreshAccessToken();
    } on _RefreshUnavailable {
      return null;
    }
  }

  Future<String?> _requestNewAccessToken() async {
    final sessionGeneration = _storage.sessionGeneration;
    final refresh = await _storage.readRefreshToken();
    if (refresh == null || refresh.isEmpty) return null;

    try {
      final response = await _refreshClient.post<dynamic>(
        '/api/v1/auth/token/refresh/',
        data: {'refresh': refresh},
      );
      final data = response.data;
      if (data is! Map) return null;

      final access = data['access']?.toString();
      if (access == null || access.isEmpty) return null;

      // O usuario pode ter feito logout ou entrado em outra conta enquanto o
      // refresh estava em voo. Nesse caso a resposta antiga deve ser descartada.
      if (_storage.sessionGeneration != sessionGeneration) return null;

      final rotatedRefresh = data['refresh']?.toString();
      if (rotatedRefresh != null && rotatedRefresh.isNotEmpty) {
        await _storage.saveTokens(access: access, refresh: rotatedRefresh);
      } else {
        await _storage.saveToken(access);
      }
      return access;
    } on DioException catch (error) {
      final status = error.response?.statusCode ?? 0;
      if (status == 400 || status == 401 || status == 403) {
        await _storage.clear();
        return null;
      }
      if (OfflineRequestQueue.isNetworkFailure(error) || status >= 500) {
        throw _RefreshUnavailable(error);
      }
      return null;
    }
  }
}

/// A renovação do token não chegou a uma resposta da API (sem sinal,
/// servidor fora): a sessão continua válida no aparelho.
class _RefreshUnavailable implements Exception {
  const _RefreshUnavailable(this.error);
  final DioException error;
}
