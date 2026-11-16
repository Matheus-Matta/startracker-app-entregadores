import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/storage/session_storage.dart';

/// Resposta roteirizada: status, corpo cru e cabeçalhos.
class FaultReply {
  const FaultReply(
    this.status, {
    this.body = '',
    this.contentType = Headers.jsonContentType,
    this.headers = const {},
  });

  FaultReply.json(
    Object? data, {
    int status = 200,
    Map<String, String>? headers,
  }) : this(status, body: jsonEncode(data), headers: headers ?? const {});

  /// Página de login da operadora / Wi-Fi: 200 com HTML no lugar da API.
  const FaultReply.captivePortal()
    : this(
        200,
        body:
            '<html><body>Seu pacote de dados acabou. Recarregue.</body></html>',
        contentType: 'text/html; charset=utf-8',
      );

  /// JSON cortado no meio (conexão caiu durante a resposta).
  const FaultReply.truncatedJson()
    : this(200, body: '{"results": [{"id": 1, "sta');

  /// Página de erro do Cloudflare quando a origem está fora.
  const FaultReply.cloudflare(int status)
    : this(
        status,
        body: '<html>origin unreachable</html>',
        contentType: 'text/html',
      );

  final int status;
  final String body;
  final String contentType;
  final Map<String, String> headers;
}

typedef FaultResponder = Object Function(RequestOptions request, int call);

/// Requisição recebida pelo servidor falso, com o que importa para os testes.
class SeenRequest {
  SeenRequest(this.options);
  final RequestOptions options;

  String get method => options.method;
  String get path => options.path;
  String? get requestId => options.headers['X-Request-ID']?.toString();
  String? get idempotencyKey => options.headers['Idempotency-Key']?.toString();
  String? get stage => options.extra['stage']?.toString();
  String get key => '$method $path';
}

/// Servidor falso com falhas programáveis por rota.
///
/// Cada regra recebe a requisição e quantas vezes aquela regra já foi
/// chamada, e devolve uma [FaultReply], um `Map`/`List` (vira JSON 200) ou
/// lança uma exceção (falha de transporte). Rotas sem regra respondem lista
/// vazia, como a API para filtros sem resultado.
class FaultServer implements HttpClientAdapter {
  final List<(String, RegExp, FaultResponder)> _rules = [];
  final Map<int, int> _calls = {};
  final List<SeenRequest> seen = [];

  void on(String method, String pathPattern, FaultResponder responder) {
    _rules.add((method, RegExp('^$pathPattern\$'), responder));
  }

  /// Atalho: a mesma resposta sempre.
  void always(String method, String pathPattern, Object reply) =>
      on(method, pathPattern, (_, _) => reply);

  /// Falha nas primeiras [failures] chamadas e depois responde [then].
  void flaky(
    String method,
    String pathPattern, {
    required int failures,
    required Object Function(RequestOptions) failure,
    required Object then,
  }) => on(
    method,
    pathPattern,
    (request, call) => call < failures ? failure(request) : then,
  );

  Iterable<SeenRequest> requestsTo(String method, String pathPattern) {
    final pattern = RegExp('^$pathPattern\$');
    return seen.where(
      (request) => request.method == method && pattern.hasMatch(request.path),
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(SeenRequest(options));
    for (final (index, (method, pattern, responder)) in _rules.indexed) {
      if (method != options.method || !pattern.hasMatch(options.path)) {
        continue;
      }
      final call = _calls[index] ?? 0;
      _calls[index] = call + 1;
      final result = responder(options, call);
      if (result is Exception || result is Error) throw result;
      return _body(result);
    }
    return _body(<String, dynamic>{'results': <dynamic>[], 'next': null});
  }

  ResponseBody _body(Object result) {
    final reply = result is FaultReply ? result : FaultReply.json(result);
    return ResponseBody.fromString(
      reply.body,
      reply.status,
      headers: {
        Headers.contentTypeHeader: [reply.contentType],
        for (final entry in reply.headers.entries) entry.key: [entry.value],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

DioException networkDown(RequestOptions request) =>
    DioException.connectionError(
      requestOptions: request,
      reason: 'Connection reset by peer',
    );

DioException uploadTimeout(RequestOptions request) =>
    DioException(requestOptions: request, type: DioExceptionType.sendTimeout);

class FakeSessionStorage extends SessionStorage {
  const FakeSessionStorage();

  @override
  Future<String?> readToken() async => 'token-de-teste';

  @override
  Future<String?> readRefreshToken() async => null;

  @override
  Future<Map<String, dynamic>> readDeliveryConfig() async => const {};
}

/// Cliente com o servidor falso, sem espera entre repetições de leitura.
ApiClient faultClient(FaultServer server) {
  final client = ApiClient(
    baseUrl: 'https://api.example.test',
    storage: const FakeSessionStorage(),
    refreshClient: Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = server,
  )..readRetryDelays = const [Duration.zero, Duration.zero];
  client.dio.httpClientAdapter = server;
  return client;
}
