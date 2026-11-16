import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/network/api_failure.dart';
import 'package:star_tracker/core/network/offline_request_queue.dart';
import 'package:star_tracker/features/waves/data/active_route_service.dart';

import '../../../support/fault_server.dart';

const _stopPath = '/api/v1/delivery/paradas/42/';
const _completePath = '/api/v1/delivery/paradas/42/complete/';
const _proofsPath = '/api/v1/delivery/comprovantes/';
const _photosPath = '/api/v1/delivery/fotos-comprovante/';

/// Servidor falso com estado, que se comporta como o Django de verdade:
/// comprovante é único por parada, a ordem da foto é única por comprovante
/// (400 na repetição), conclusão repetida devolve 200 sem refazer nada.
class _DeliveryBackend {
  _DeliveryBackend() {
    server
      ..on(
        'POST',
        _proofsPath,
        (request, _) => _step('proof', request, () {
          if (proofId != null) {
            return FaultReply.json({
              'route_stop': ['Já existe comprovante para esta parada.'],
            }, status: 400);
          }
          proofCreates++;
          proofId = 15;
          return {'id': proofId};
        }),
      )
      ..on(
        'PATCH',
        '${_proofsPath}15/',
        (request, _) => _step('proof', request, () {
          proofPatches++;
          return {'id': 15};
        }),
      )
      ..on('POST', _photosPath, (request, _) {
        final sequence = _field(request, 'sequence');
        return _step('photo-$sequence', request, () {
          if (!sequences.add(sequence)) {
            return FaultReply.json({
              'non_field_errors': ['Sequência já usada.'],
            }, status: 400);
          }
          return {'id': 100 + sequences.length};
        });
      })
      ..on(
        'GET',
        _photosPath,
        (_, _) => {
          'results': [
            for (final sequence in sequences)
              {'delivery_proof': 15, 'sequence': int.parse(sequence)},
          ],
          'next': null,
        },
      )
      ..on(
        'GET',
        _stopPath,
        (_, _) => {
          'id': 42,
          'status': completed ? 'completed' : 'delivering',
          'proof': proofId == null ? null : {'id': proofId},
        },
      )
      ..on(
        'POST',
        _completePath,
        (request, _) => _step('complete', request, () {
          if (!completed) completions++;
          completed = true;
          return {'id': 42, 'status': 'completed'};
        }),
      );
  }

  final server = FaultServer();
  int? proofId;
  int proofCreates = 0;
  int proofPatches = 0;
  int completions = 0;
  bool completed = false;
  final Set<String> sequences = {};

  /// Falhas programadas por etapa ('proof', 'photo-1', 'photo-2',
  /// 'complete'): devolvem a falha em vez da resposta normal.
  final Map<
    String,
    Object Function(RequestOptions request, Object Function() apply)
  >
  faults = {};

  Object _step(String step, RequestOptions request, Object Function() apply) {
    final fault = faults.remove(step);
    return fault == null ? apply() : fault(request, apply);
  }

  static String _field(RequestOptions request, String name) =>
      (request.data as FormData).fields
          .firstWhere((entry) => entry.key == name)
          .value;
}

ActiveRouteStop _stop() => ActiveRouteStop(
  stopId: 42,
  orderId: 42,
  sequence: 1,
  status: 'delivering',
  orderStatus: 'out_for_delivery',
  isManual: false,
  plannedEta: null,
  orderNumber: 'PED-42',
  customerName: 'Cliente',
  customerPhone: '',
  fullAddress: '',
  latitude: null,
  longitude: null,
  units: 1,
  weightGrams: 0,
  contents: const [],
  proofOverrides: const {},
  policy: CompletionPolicy.fromOverrides(const {}),
  existingProofId: null,
  existingPhotoCount: 0,
  hasSignature: false,
  existingRecipientName: '',
  existingRecipientDocument: '',
  existingNotes: '',
);

DeliveryProofSubmission _submission() => DeliveryProofSubmission(
  stop: _stop(),
  recipientName: 'Maria',
  recipientDocument: '',
  notes: '',
  photos: [
    DeliveryPhotoUpload(bytes: Uint8List(8), filename: 'a.jpg'),
    DeliveryPhotoUpload(bytes: Uint8List(8), filename: 'b.jpg'),
  ],
  signatureBytes: null,
  latitude: -22.8,
  longitude: -43.0,
  itemResults: const [],
);

FaultReply _echoRef(RequestOptions request, FaultReply reply) => FaultReply(
  reply.status,
  body: reply.body,
  contentType: reply.contentType,
  headers: {
    ...reply.headers,
    'X-Request-ID': request.headers['X-Request-ID'].toString(),
  },
);

void main() {
  late _DeliveryBackend backend;
  late ApiClient client;
  late ActiveRouteService service;
  late List<OfflineQueueEvent> events;
  late StreamSubscription<OfflineQueueEvent> subscription;

  setUp(() {
    ApiFailureLog.instance.clear();
    backend = _DeliveryBackend();
    client = faultClient(backend.server);
    service = ActiveRouteService(client, storage: const FakeSessionStorage());
    events = [];
    subscription = client.offlineRequests.events.listen(events.add);
  });
  tearDown(() => subscription.cancel());

  /// Invariantes de uma baixa bem-sucedida, venha de quantas tentativas vier.
  void expectDeliveredExactlyOnce() {
    expect(backend.completed, isTrue, reason: 'a baixa não chegou ao servidor');
    expect(backend.completions, 1);
    expect(backend.proofCreates, 1, reason: 'comprovante duplicado');
    expect(backend.sequences, {'1', '2'});
    expect(client.offlineRequests.pendingCount, 0);
    expect(
      events.where((event) => event.type == OfflineQueueEventType.rejected),
      isEmpty,
      reason: 'a baixa foi descartada: ${events.map((e) => e.error)}',
    );
  }

  group('queda de rede em cada etapa da baixa', () {
    // "antes": a requisição não chegou. "resposta perdida": o servidor
    // gravou e a resposta se perdeu no 4G — o caso que desfazia a entrega.
    for (final step in ['proof', 'photo-1', 'photo-2', 'complete']) {
      for (final lost in [false, true]) {
        final label = lost ? 'resposta perdida' : 'antes de chegar';
        test('$step / $label: fica na fila e conclui uma vez só', () async {
          backend.faults[step] = (request, apply) {
            if (lost) apply();
            return networkDown(request);
          };

          final first = await service.complete(_submission());
          expect(first.queued, isTrue);
          expect(
            service.cachedRoute(42),
            isNull,
            reason: 'sem rota em cache não há o que restaurar',
          );

          await client.offlineRequests.retryNow(manual: true);

          expectDeliveredExactlyOnce();
          // O reenvio usa a mesma chave base de idempotência.
          final keys = backend.server
              .requestsTo('POST', _completePath)
              .map((request) => request.idempotencyKey)
              .toSet();
          expect(keys, hasLength(1));
        });
      }
    }

    test('timeout no upload da foto e servidor ocupado em seguida', () async {
      backend.faults['photo-1'] = (request, _) => uploadTimeout(request);
      backend.faults['complete'] = (request, _) => FaultReply.json({
        'detail': 'Servidor ocupado no momento. Tente novamente.',
      }, status: 503);

      expect((await service.complete(_submission())).queued, isTrue);
      await client.offlineRequests.retryNow(manual: true);
      expect(client.offlineRequests.pendingCount, 1, reason: '503 mantém');
      await client.offlineRequests.retryNow(manual: true);

      expectDeliveredExactlyOnce();
      final log = ApiFailureLog.instance.export();
      expect(log, contains('ETEMPO Enviar foto 1 de 2'));
      expect(log, contains('E503-OCUP Confirmar entrega'));
    });
  });

  group('resposta que nao e da API', () {
    test(
      'portal da operadora na confirmacao nao conta como entregue',
      () async {
        backend.faults['complete'] = (_, _) => const FaultReply.captivePortal();

        final first = await service.complete(_submission());

        expect(
          first.queued,
          isTrue,
          reason: 'HTML 200 era aceito como sucesso',
        );
        expect(backend.completed, isFalse);
        await client.offlineRequests.retryNow(manual: true);
        expectDeliveredExactlyOnce();
      },
    );

    test('portal depois de o servidor concluir: reenvio so confere', () async {
      backend.faults['complete'] = (_, apply) {
        apply();
        return const FaultReply.captivePortal();
      };

      expect((await service.complete(_submission())).queued, isTrue);
      await client.offlineRequests.retryNow(manual: true);

      expectDeliveredExactlyOnce();
      expect(backend.server.requestsTo('POST', _completePath), hasLength(1));
    });

    test(
      'comprovante criado sem id fica na fila e retoma pelo servidor',
      () async {
        backend.faults['proof'] = (_, apply) {
          apply();
          return <String, dynamic>{};
        };

        expect((await service.complete(_submission())).queued, isTrue);
        await client.offlineRequests.retryNow(manual: true);

        expectDeliveredExactlyOnce();
        expect(backend.proofPatches, 1);
      },
    );

    test('Cloudflare bloqueando o IP da operadora fica na fila', () async {
      backend.faults['proof'] = (_, _) => const FaultReply(
        403,
        body: '<html>challenge</html>',
        contentType: 'text/html',
        headers: {'cf-mitigated': 'challenge'},
      );

      expect((await service.complete(_submission())).queued, isTrue);
      await client.offlineRequests.retryNow(manual: true);
      expectDeliveredExactlyOnce();
    });
  });

  group('recusa definitiva diz etapa, campo, motivo e referencia', () {
    Future<String> refusal() async {
      try {
        await service.complete(_submission());
      } on ActiveRouteException catch (error) {
        expect(client.offlineRequests.pendingCount, 0);
        return error.message;
      }
      fail('a baixa deveria ter sido recusada');
    }

    test('foto 2 corrompida (400)', () async {
      backend.faults['photo-2'] = (request, _) => _echoRef(
        request,
        FaultReply.json({
          'file': [
            'Foto corrompida ou em formato inválido. Tire a foto novamente.',
          ],
        }, status: 400),
      );

      final message = await refusal();

      expect(message, startsWith('Enviar foto 2 de 2: Foto: Foto corrompida'));
      expect(message, matches(RegExp(r'\(E400-RECUSA · ref m[a-z2-9]{10}\)$')));
      expect(backend.completed, isFalse);
    });

    test('erro interno com pagina HTML (500)', () async {
      backend.faults['complete'] = (_, _) => const FaultReply(
        500,
        body: '<h1>Server Error (500)</h1>',
        contentType: 'text/html',
      );

      final message = await refusal();

      expect(
        message,
        startsWith('Confirmar entrega: erro interno no servidor'),
      );
      expect(message, contains('E500-SRV · ref m'));
      expect(message, isNot(contains('<h1>')));
    });

    test('comprovante grande demais para o proxy (413)', () async {
      backend.faults['proof'] = (_, _) => const FaultReply(
        413,
        body: '<html>413 Request Entity Too Large</html>',
        contentType: 'text/html',
      );

      expect(
        await refusal(),
        startsWith('Enviar comprovante: arquivo grande demais'),
      );
    });

    test('sessao expirada sem refresh (401)', () async {
      backend.faults['proof'] = (_, _) => FaultReply.json({
        'detail': 'Token inválido ou expirado.',
      }, status: 401);

      final message = await refusal();

      expect(message, contains('Enviar comprovante: Token inválido'));
      expect(message, contains('E401-SESSAO'));
    });

    test('parada transferida para outro entregador (404)', () async {
      backend.faults['complete'] = (_, _) =>
          FaultReply.json({'detail': 'Não encontrado.'}, status: 404);

      expect(await refusal(), contains('Confirmar entrega: Não encontrado.'));
    });

    test('coordenadas invalidas sao barradas antes da rede', () async {
      for (final (lat, lon) in [
        (double.nan, -43.0),
        (-22.8, double.infinity),
        (95.0, -43.0),
        (-22.8, 190.0),
      ]) {
        final submission = _submission();
        await expectLater(
          service.complete(
            DeliveryProofSubmission(
              stop: submission.stop,
              recipientName: 'Maria',
              recipientDocument: '',
              notes: '',
              photos: submission.photos,
              signatureBytes: null,
              latitude: lat,
              longitude: lon,
              itemResults: const [],
            ),
          ),
          throwsA(isA<ActiveRouteException>()),
          reason: '$lat,$lon',
        );
      }
      expect(backend.server.seen, isEmpty);
    });
  });

  test('reenvio esgotado mantem a baixa e o diagnostico registra cada '
      'tentativa com etapa e referencia', () async {
    backend.server.on('GET', '/api/v1/', (request, _) => networkDown(request));
    backend.faults['proof'] = (request, _) => networkDown(request);

    expect((await service.complete(_submission())).queued, isTrue);
    for (var attempt = 0; attempt < 3; attempt++) {
      await client.offlineRequests.retryNow(manual: attempt == 0);
    }

    expect(client.offlineRequests.pendingCount, 1, reason: 'nunca descarta');
    final entries = ApiFailureLog.instance.entries.value;
    expect(
      entries.map((entry) => entry.failure.stage),
      contains('Enviar comprovante'),
    );
    expect(
      entries.every((entry) => entry.failure.requestId.startsWith('m')),
      isTrue,
    );
  });
}
