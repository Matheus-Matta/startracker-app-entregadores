import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_collection.dart';
import 'package:star_tracker/core/network/api_failure.dart';
import 'package:star_tracker/core/network/offline_request_queue.dart';

import '../../support/fault_server.dart';

DioException _http(
  int status, {
  Object? data,
  Map<String, List<String>> headers = const {},
  String path = '/api/v1/delivery/paradas/42/complete/',
  String method = 'POST',
}) {
  final request = RequestOptions(path: path, method: method);
  return DioException(
    requestOptions: request,
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      requestOptions: request,
      statusCode: status,
      data: data,
      headers: Headers.fromMap(headers),
    ),
  );
}

DioException _transport(DioExceptionType type, {Object? error}) => DioException(
  requestOptions: RequestOptions(path: '/api/v1/delivery/paradas/'),
  type: type,
  error: error,
);

void main() {
  setUp(ApiFailureLog.instance.clear);

  group('classificacao de cada falha', () {
    // (falha, tipo esperado, transitória?) — transitória = fica na fila.
    final cases = <String, (DioException, ApiFailureKind, bool)>{
      'sem rede': (
        _transport(
          DioExceptionType.connectionError,
          error: const SocketException('x'),
        ),
        ApiFailureKind.offline,
        true,
      ),
      'TLS cortado no 4G': (
        _transport(
          DioExceptionType.connectionError,
          error: const HandshakeException('x'),
        ),
        ApiFailureKind.insecureConnection,
        true,
      ),
      'upload lento': (
        _transport(DioExceptionType.sendTimeout),
        ApiFailureKind.timeout,
        true,
      ),
      'resposta lenta': (
        _transport(DioExceptionType.receiveTimeout),
        ApiFailureKind.timeout,
        true,
      ),
      'conexão caiu no meio': (
        _transport(
          DioExceptionType.unknown,
          error: const HttpException('closed'),
        ),
        ApiFailureKind.offline,
        true,
      ),
      'JSON truncado': (
        _transport(
          DioExceptionType.unknown,
          error: const FormatException('fim'),
        ),
        ApiFailureKind.invalidResponse,
        true,
      ),
      'portal da operadora': (
        _transport(
          DioExceptionType.badResponse,
          error: const UnexpectedResponseFormat('html'),
        ),
        ApiFailureKind.invalidResponse,
        true,
      ),
      'desafio do Cloudflare': (
        _http(
          403,
          headers: {
            'cf-mitigated': ['challenge'],
          },
        ),
        ApiFailureKind.blockedByProxy,
        true,
      ),
      'proxy sem origem (502)': (_http(502), ApiFailureKind.gateway, true),
      'origem fora (521)': (_http(521), ApiFailureKind.gateway, true),
      'banco fora (503)': (_http(503), ApiFailureKind.serverBusy, true),
      'limite (429)': (_http(429), ApiFailureKind.rateLimited, true),
      'bug no servidor (500)': (_http(500), ApiFailureKind.serverError, false),
      'sessão (401)': (_http(401), ApiFailureKind.sessionExpired, false),
      'permissão (403)': (_http(403), ApiFailureKind.forbidden, false),
      'parada sumiu (404)': (_http(404), ApiFailureKind.notFound, false),
      'conflito (409)': (_http(409), ApiFailureKind.conflict, false),
      'foto grande (413)': (_http(413), ApiFailureKind.tooLarge, false),
      'validação (400)': (_http(400), ApiFailureKind.rejected, false),
      'cancelada': (
        _transport(DioExceptionType.cancel),
        ApiFailureKind.cancelled,
        false,
      ),
    };

    for (final MapEntry(key: name, value: (error, kind, transient))
        in cases.entries) {
      test(name, () {
        final failure = ApiFailure.fromDio(error);
        expect(failure.kind, kind);
        expect(failure.isTransient, transient);
        // A fila e o diagnóstico precisam concordar: o que o diagnóstico
        // chama de transitório é exatamente o que a fila guarda.
        expect(
          OfflineRequestQueue.isNetworkFailure(error),
          transient,
          reason: 'fila e diagnóstico divergem em "$name"',
        );
      });
    }
  });

  group('mensagem diz etapa, motivo e referencia', () {
    test('erro de validação aninhado do DRF vira texto legível', () {
      final failure = ApiFailure.fromDio(
        _http(
          400,
          data: {
            'file': ['Foto corrompida ou em formato inválido.'],
            'non_field_errors': ['Sequência já usada.'],
            'items': {
              '0': ['Status inválido'],
            },
            'code': 'invalid',
          },
          headers: {
            'X-Request-ID': ['mabc123defg'],
          },
          path: '/api/v1/delivery/fotos-comprovante/',
        ),
      );

      expect(failure.stage, 'Enviar foto');
      expect(failure.serverMessages, [
        'Foto: Foto corrompida ou em formato inválido.',
        'Sequência já usada.',
        'Itens: Status inválido',
      ]);
      expect(failure.code, 'E400-RECUSA');
      expect(failure.userMessage, startsWith('Enviar foto: Foto: Foto corr'));
      expect(failure.userMessage, endsWith('(E400-RECUSA · ref mabc123defg)'));
    });

    test('pagina HTML de erro nunca aparece para o entregador', () {
      final failure = ApiFailure.fromDio(
        _http(500, data: '<!doctype html><h1>Server Error (500)</h1>'),
      );

      expect(failure.serverMessages, isEmpty);
      expect(
        failure.userMessage,
        startsWith('Confirmar entrega: erro interno no servidor'),
      );
    });

    test('etapa explicita tem prioridade sobre a rota', () {
      final request = RequestOptions(
        path: '/api/v1/delivery/fotos-comprovante/',
        method: 'POST',
        extra: {ApiFailure.stageKey: 'Enviar foto 2 de 3'},
      );
      expect(ApiFailure.stageOf(request), 'Enviar foto 2 de 3');
    });

    test('rotas conhecidas tem nome de etapa', () {
      String stage(String method, String path) =>
          ApiFailure.stageOf(RequestOptions(path: path, method: method));

      expect(
        stage('GET', '/api/v1/delivery/paradas/?route=3'),
        'Carregar paradas',
      );
      expect(
        stage('POST', '/api/v1/delivery/paradas/9/fail/'),
        'Registrar falha',
      );
      expect(stage('POST', '/api/v1/delivery/rotas/9/start/'), 'Iniciar rota');
      expect(stage('GET', '/api/v1/delivery/armazens/'), 'Carregar armazéns');
      expect(
        stage('PATCH', '/api/v1/delivery/comprovantes/5/'),
        'Enviar comprovante',
      );
      expect(stage('GET', '/api/v1/desconhecido/'), 'Carregar dados');
      expect(
        ApiFailure.normalizedPath('/api/v1/delivery/waves/12/retirada/?x=1'),
        '/api/v1/delivery/waves/N/retirada/',
      );
    });
  });

  group('validador de resposta no ApiClient', () {
    test('toda requisicao leva um codigo de referencia unico', () async {
      final server = FaultServer()
        ..always('GET', '/api/v1/delivery/rotas/1/', {'id': 1});
      final client = faultClient(server);

      await client.dio.get<dynamic>('/api/v1/delivery/rotas/1/');
      await client.dio.get<dynamic>('/api/v1/delivery/rotas/1/');

      final ids = server.seen.map((request) => request.requestId).toList();
      expect(ids, everyElement(matches(RegExp(r'^m[a-z2-9]{10}$'))));
      expect(ids.toSet(), hasLength(2));
    });

    test('portal da operadora com 200 vira falha transitoria e repete a '
        'leitura com o mesmo codigo', () async {
      final server = FaultServer()
        ..always(
          'GET',
          '/api/v1/delivery/rotas/1/',
          const FaultReply.captivePortal(),
        );
      final client = faultClient(server);

      final error = await client.dio
          .get<dynamic>('/api/v1/delivery/rotas/1/')
          .then<DioException?>(
            (_) => null,
            onError: (Object e) => e as DioException,
          );

      expect(error, isNotNull);
      final failure = ApiFailure.fromDio(error!);
      expect(failure.kind, ApiFailureKind.invalidResponse);
      expect(failure.detail, contains('text/html'));
      expect(failure.detail, contains('pacote de dados acabou'));
      // 1 tentativa + 2 repetições da leitura, sempre com o mesmo código.
      expect(server.seen, hasLength(3));
      expect(server.seen.map((r) => r.requestId).toSet(), hasLength(1));
      expect(ApiFailureLog.instance.entries.value, isNotEmpty);
      expect(
        ApiFailureLog.instance.export(),
        contains('ERESP Carregar rota GET /api/v1/delivery/rotas/N/'),
      );
    });

    test('JSON truncado e corpo vazio numa leitura sao detectados', () async {
      final server = FaultServer()
        ..always(
          'GET',
          '/api/v1/delivery/paradas/',
          const FaultReply.truncatedJson(),
        )
        ..always('GET', '/api/v1/delivery/pedidos/', const FaultReply(200));
      final client = faultClient(server);

      for (final path in [
        '/api/v1/delivery/paradas/',
        '/api/v1/delivery/pedidos/',
      ]) {
        await expectLater(
          client.dio.get<dynamic>(path),
          throwsA(
            isA<DioException>().having(
              (error) => ApiFailure.fromDio(error).kind,
              'kind',
              ApiFailureKind.invalidResponse,
            ),
          ),
          reason: path,
        );
      }
    });

    test('escrita sem corpo (201/204) continua valida', () async {
      final server = FaultServer()
        ..always(
          'POST',
          '/api/v1/delivery/paradas/1/arrive/',
          const FaultReply(201),
        )
        ..always(
          'DELETE',
          '/api/v1/delivery/fotos-comprovante/1/',
          const FaultReply(204),
        );
      final client = faultClient(server);

      await client.dio.post<dynamic>('/api/v1/delivery/paradas/1/arrive/');
      await client.dio.delete<dynamic>('/api/v1/delivery/fotos-comprovante/1/');
    });

    test(
      'pagina com objeto de erro em vez de lista nao vira lista vazia',
      () async {
        final server = FaultServer()
          ..always('GET', '/api/v1/delivery/paradas/', {
            'detail': 'Filtro inválido',
          });
        final client = faultClient(server);

        await expectLater(
          client.getAllPages('/api/v1/delivery/paradas/'),
          throwsA(
            isA<DioException>().having(
              (error) => ApiFailure.fromDio(error).detail,
              'detail',
              contains('objeto sem "results" (detail)'),
            ),
          ),
        );
      },
    );
  });

  test('historico guarda no maximo a capacidade, mais recente primeiro', () {
    final log = ApiFailureLog.instance;
    for (var index = 0; index < ApiFailureLog.capacity + 5; index++) {
      log.record(
        ApiFailure(stage: 'Etapa $index', kind: ApiFailureKind.offline),
        at: DateTime(2026, 1, 1, 0, 0, index),
      );
    }

    expect(log.entries.value, hasLength(ApiFailureLog.capacity));
    expect(log.entries.value.first.failure.stage, 'Etapa 44');
    expect(log.export().split('\n').first, contains('EREDE Etapa 44'));
  });

  test('describeFailure aceita qualquer erro da fila', () {
    expect(describeFailure(null), 'Motivo não informado.');
    expect(describeFailure(_http(404)), contains('registro não encontrado'));
    expect(describeFailure(StateError('x')), contains('x'));
  });
}
