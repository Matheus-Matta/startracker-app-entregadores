import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Por que uma requisição falhou, do ponto de vista de quem vai agir.
enum ApiFailureKind {
  offline('REDE', transient: true),
  timeout('TEMPO', transient: true),
  insecureConnection('TLS', transient: true),
  blockedByProxy('CDN', transient: true),
  gateway('GW', transient: true),
  serverBusy('OCUP', transient: true),
  rateLimited('LIMITE', transient: true),
  invalidResponse('RESP', transient: true),
  serverError('SRV'),
  sessionExpired('SESSAO'),
  forbidden('PERM'),
  notFound('N/E'),
  conflict('CONFL'),
  rejected('RECUSA'),
  tooLarge('GRANDE'),
  cancelled('CANC'),
  unknown('DESC');

  const ApiFailureKind(this.code, {this.transient = false});

  /// Prefixo curto do código mostrado ao entregador.
  final String code;

  /// Falha de caminho (rede/proxy/servidor ocupado): repetir resolve e a
  /// operação nunca deve ser descartada.
  final bool transient;
}

/// Resposta 2xx que não é o JSON da API: portal de login da operadora ou do
/// Wi-Fi, página de proxy, corpo truncado. A requisição pode nem ter chegado
/// ao servidor, então é tratada como falha de rede (fica na fila).
class UnexpectedResponseFormat implements Exception {
  const UnexpectedResponseFormat(this.reason);
  final String reason;

  @override
  String toString() => 'UnexpectedResponseFormat: $reason';
}

/// Falha de uma chamada à API com tudo que é preciso para saber onde e por
/// que ela aconteceu: etapa, tipo, status, rota e código de referência
/// (o mesmo `X-Request-ID` gravado no log do servidor).
@immutable
class ApiFailure implements Exception {
  const ApiFailure({
    required this.stage,
    required this.kind,
    this.statusCode,
    this.method = '',
    this.path = '',
    this.requestId = '',
    this.serverMessages = const [],
    this.detail = '',
  });

  factory ApiFailure.fromDio(DioException error, {String? stage}) {
    final request = error.requestOptions;
    final response = error.response;
    final status = response?.statusCode;
    return ApiFailure(
      stage: stage ?? stageOf(request),
      kind: classify(error),
      statusCode: status,
      method: request.method,
      path: normalizedPath(request.path),
      requestId:
          response?.headers.value(requestIdHeader) ??
          request.headers[requestIdHeader]?.toString() ??
          '',
      serverMessages: serverMessagesOf(response?.data),
      detail: switch (error.error) {
        final UnexpectedResponseFormat format => format.reason,
        final FormatException format => 'JSON inválido: ${format.message}',
        final Object cause => cause.runtimeType.toString(),
        null => error.type.name,
      },
    );
  }

  static const requestIdHeader = 'X-Request-ID';

  /// Chave de `RequestOptions.extra` com o nome da etapa (ex.: "Enviar foto
  /// 2 de 3"). Sem ela a etapa sai da rota chamada.
  static const stageKey = 'stage';

  final String stage;
  final ApiFailureKind kind;
  final int? statusCode;
  final String method;
  final String path;
  final String requestId;
  final List<String> serverMessages;

  /// Detalhe técnico (exceção de origem, motivo da resposta inválida).
  final String detail;

  bool get isTransient => kind.transient;

  /// Ex.: `E400-RECUSA`, `ETEMPO`. Curto para caber num print de tela.
  String get code =>
      (statusCode ?? 0) < 400 ? 'E${kind.code}' : 'E$statusCode-${kind.code}';

  String get reason => switch (kind) {
    ApiFailureKind.offline => 'sem conexão com a internet',
    ApiFailureKind.timeout => 'a rede demorou demais para responder',
    ApiFailureKind.insecureConnection =>
      'a conexão segura foi interrompida (sinal fraco ou Wi-Fi com login)',
    ApiFailureKind.blockedByProxy =>
      'a proteção do servidor bloqueou o acesso por um momento',
    ApiFailureKind.gateway => 'o servidor está fora do ar por um momento',
    ApiFailureKind.serverBusy => 'o servidor está ocupado no momento',
    ApiFailureKind.rateLimited => 'muitas tentativas seguidas; aguarde',
    ApiFailureKind.invalidResponse =>
      'resposta inesperada (portal de login da operadora ou do Wi-Fi?)',
    ApiFailureKind.serverError => 'erro interno no servidor',
    ApiFailureKind.sessionExpired => 'sessão expirada; entre novamente',
    ApiFailureKind.forbidden => 'sem permissão para esta ação',
    ApiFailureKind.notFound =>
      'registro não encontrado (removido ou passado a outro entregador)',
    ApiFailureKind.conflict => 'o registro foi alterado por outra pessoa',
    ApiFailureKind.rejected => 'o servidor recusou os dados',
    ApiFailureKind.tooLarge => 'arquivo grande demais para o servidor',
    ApiFailureKind.cancelled => 'operação cancelada',
    ApiFailureKind.unknown => 'falha inesperada',
  };

  /// Mensagem para o entregador: etapa, motivo, texto do servidor e código.
  String get userMessage {
    final server = serverMessages.take(3).join(' ');
    final explanation = server.isEmpty ? reason : server;
    final reference = requestId.isEmpty ? code : '$code · ref $requestId';
    return '$stage: $explanation ($reference)';
  }

  /// Linha completa para o histórico de diagnóstico.
  String get diagnostic => [
    code,
    stage,
    '$method $path'.trim(),
    if (requestId.isNotEmpty) 'ref=$requestId',
    if (serverMessages.isNotEmpty) 'servidor="${serverMessages.join(' | ')}"',
    if (detail.isNotEmpty) 'detalhe=$detail',
  ].join(' ');

  @override
  String toString() => 'ApiFailure($diagnostic)';

  static ApiFailureKind classify(DioException error) {
    if (error.type == DioExceptionType.cancel) return ApiFailureKind.cancelled;
    final cause = error.error;
    if (cause is UnexpectedResponseFormat || cause is FormatException) {
      return ApiFailureKind.invalidResponse;
    }
    final response = error.response;
    if (response != null && (response.statusCode ?? 0) > 0) {
      if (response.headers.value('cf-mitigated') != null) {
        return ApiFailureKind.blockedByProxy;
      }
      final status = response.statusCode!;
      return switch (status) {
        401 => ApiFailureKind.sessionExpired,
        403 => ApiFailureKind.forbidden,
        404 => ApiFailureKind.notFound,
        408 => ApiFailureKind.timeout,
        409 || 412 => ApiFailureKind.conflict,
        413 => ApiFailureKind.tooLarge,
        429 => ApiFailureKind.rateLimited,
        503 => ApiFailureKind.serverBusy,
        502 || 504 || (>= 520 && <= 530) => ApiFailureKind.gateway,
        >= 500 => ApiFailureKind.serverError,
        >= 400 => ApiFailureKind.rejected,
        _ => ApiFailureKind.unknown,
      };
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => ApiFailureKind.timeout,
      DioExceptionType.badCertificate => ApiFailureKind.insecureConnection,
      DioExceptionType.connectionError when cause is HandshakeException =>
        ApiFailureKind.insecureConnection,
      DioExceptionType.connectionError => ApiFailureKind.offline,
      _ when cause is TlsException => ApiFailureKind.insecureConnection,
      _ when cause is TimeoutException => ApiFailureKind.timeout,
      _ when cause is IOException => ApiFailureKind.offline,
      _ => ApiFailureKind.unknown,
    };
  }

  /// Textos de erro do corpo da resposta (formato do DRF), sem HTML.
  static List<String> serverMessagesOf(dynamic data) {
    final messages = <String>[];
    void visit(dynamic value, String field) {
      if (messages.length >= 6) return;
      if (value is String) {
        final text = value.trim();
        if (text.isEmpty || text.startsWith('<')) return;
        final clean = text.length > 200 ? '${text.substring(0, 200)}…' : text;
        messages.add(field.isEmpty ? clean : '$field: $clean');
      } else if (value is Iterable) {
        for (final item in value) {
          visit(item, field);
        }
      } else if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key.toString();
          if (const {'code', 'status_code', 'request_id'}.contains(key)) {
            continue;
          }
          // `detail`, `non_field_errors` e índices de lista (`items.0`)
          // herdam o nome do campo de cima.
          final inherits =
              const {'detail', 'non_field_errors'}.contains(key) ||
              int.tryParse(key) != null;
          final named = inherits ? field : _fieldLabels[key] ?? key;
          visit(entry.value, named);
        }
      }
    }

    visit(data, '');
    return List.unmodifiable(messages.toSet());
  }

  static const _fieldLabels = {
    'file': 'Foto',
    'signature_file': 'Assinatura',
    'sequence': 'Ordem da foto',
    'recipient_name': 'Recebedor',
    'recipient_document': 'Documento',
    'items': 'Itens',
    'lat': 'Latitude',
    'lon': 'Longitude',
    'route_stop': 'Parada',
    'delivery_proof': 'Comprovante',
  };

  /// Etapa legível a partir da rota quando a chamada não informou uma.
  static String stageOf(RequestOptions request) {
    final explicit = request.extra[stageKey];
    if (explicit is String && explicit.isNotEmpty) return explicit;
    final path = normalizedPath(request.path);
    final write = request.method != 'GET' && request.method != 'HEAD';
    for (final (pattern, read, change) in _stages) {
      if (path.contains(pattern)) return write ? change : read;
    }
    return write ? 'Enviar dados' : 'Carregar dados';
  }

  static const _stages = [
    ('/paradas/N/complete/', 'Confirmar entrega', 'Confirmar entrega'),
    ('/paradas/N/fail/', 'Registrar falha', 'Registrar falha'),
    ('/paradas/N/arrive/', 'Registrar chegada', 'Registrar chegada'),
    ('/paradas/N/begin/', 'Iniciar entrega', 'Iniciar entrega'),
    ('/paradas/N/skip/', 'Pular entrega', 'Pular entrega'),
    ('/rotas/N/start/', 'Iniciar rota', 'Iniciar rota'),
    ('/fotos-comprovante/', 'Carregar fotos', 'Enviar foto'),
    ('/comprovantes/', 'Carregar comprovantes', 'Enviar comprovante'),
    ('/paradas/', 'Carregar paradas', 'Atualizar parada'),
    ('/rotas/', 'Carregar rota', 'Atualizar rota'),
    ('/pedidos/', 'Carregar pedidos', 'Atualizar pedido'),
    ('/armazens/', 'Carregar armazéns', 'Atualizar armazém'),
    ('/retirada', 'Carregar retirada', 'Registrar retirada'),
    ('/waves/', 'Carregar cargas', 'Atualizar carga'),
    ('/configuracao/', 'Carregar configuração', 'Salvar configuração'),
    ('/token/', 'Entrar', 'Entrar'),
    ('/mapbox/', 'Carregar mapa', 'Carregar mapa'),
    ('/notificacoes/', 'Carregar avisos', 'Atualizar avisos'),
  ];

  /// `/api/v1/delivery/paradas/123/` → `/api/v1/delivery/paradas/N/`.
  static String normalizedPath(String path) {
    final uri = Uri.tryParse(path);
    final clean = uri?.path ?? path.split('?').first;
    return clean.replaceAll(RegExp(r'/\d+(?=/|$)'), '/N');
  }
}

/// Texto de qualquer erro vindo da fila ou de um serviço, para a interface.
String describeFailure(Object? error) => switch (error) {
  null => 'Motivo não informado.',
  final DioException dio => ApiFailure.fromDio(dio).userMessage,
  final ApiFailure failure => failure.userMessage,
  _ => error.toString(),
};

/// Gera códigos curtos (`m` + 10 caracteres) para o `X-Request-ID`.
String newRequestId([Random? random]) {
  const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
  final source = random ?? _random;
  return 'm${List.generate(10, (_) => alphabet[source.nextInt(alphabet.length)]).join()}';
}

final _random = Random.secure();

/// Últimas falhas da sessão, para a tela de diagnóstico e o suporte.
class ApiFailureLog {
  ApiFailureLog._();

  static final ApiFailureLog instance = ApiFailureLog._();
  static const capacity = 40;

  final ValueNotifier<List<ApiFailureLogEntry>> entries = ValueNotifier(
    const [],
  );

  void record(ApiFailure failure, {DateTime? at}) {
    final entry = ApiFailureLogEntry(at ?? DateTime.now(), failure);
    final next = [entry, ...entries.value];
    entries.value = List.unmodifiable(next.take(capacity));
    if (kDebugMode) debugPrint('[api] ${failure.diagnostic}');
  }

  void clear() => entries.value = const [];

  /// Texto pronto para copiar e mandar ao suporte.
  String export() => [
    for (final entry in entries.value)
      '${entry.at.toIso8601String()} ${entry.failure.diagnostic}',
  ].join('\n');
}

@immutable
class ApiFailureLogEntry {
  const ApiFailureLogEntry(this.at, this.failure);
  final DateTime at;
  final ApiFailure failure;
}
