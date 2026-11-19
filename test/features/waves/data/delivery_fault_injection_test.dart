import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/network/api_failure.dart';
import 'package:star_tracker/core/network/offline_request_queue.dart';
import 'package:star_tracker/features/waves/data/active_route_service.dart';

import '../../../support/fault_server.dart';

const _syncPath = '/api/v1/delivery/sincronizacao/';

/// Servidor falso que se comporta como `api_sync.py`: aplica cada
/// `client_event_id` uma vez só e devolve o mesmo resultado no reenvio.
class _SyncBackend {
  _SyncBackend() {
    server.on('POST', _syncPath, (request, _) {
      final form = request.data as FormData;
      String field(String name) =>
          form.fields.where((entry) => entry.key == name).first.value;
      final fault = faults.isEmpty ? null : faults.removeAt(0);
      Object apply() {
        final id = field('client_event_id');
        eventIds.add(id);
        if (applied.add(id)) {
          lastForm = form;
          photos = form.files.where((entry) => entry.key == 'photos').length;
        }
        return {
          'client_event_id': id,
          'outcome': 'applied',
          'conflicts': <String>[],
          'stop': {'id': 42, 'status': 'completed'},
          'order': {'id': 42, 'status': 'delivered'},
          'route': {'id': 7, 'status': 'completed'},
          'wave': {'id': 3, 'status': 'completed'},
          'stop_data': {
            'proof': {
              'delivery_within_planned_radius': true,
              'tracker_validation_status': 'match',
            },
          },
        };
      }

      return fault == null ? apply() : fault(request, apply);
    });
  }

  final server = FaultServer();
  final Set<String> applied = {};
  final List<String> eventIds = [];
  FormData? lastForm;
  int photos = 0;

  /// Falhas programadas para as próximas chamadas, em ordem.
  final List<Object Function(RequestOptions request, Object Function() apply)>
  faults = [];
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

DeliveryProofSubmission _submission({
  double? latitude = -22.8,
  double? longitude = -43.0,
}) => DeliveryProofSubmission(
  stop: _stop(),
  recipientName: 'Maria',
  recipientDocument: '',
  notes: '',
  photos: [
    DeliveryPhotoUpload(bytes: Uint8List(8), filename: 'a.jpg'),
    DeliveryPhotoUpload(bytes: Uint8List(8), filename: 'b.jpg'),
  ],
  signatureBytes: Uint8List(4),
  latitude: latitude,
  longitude: longitude,
  itemResults: const [
    DeliveryItemResult(id: 5, status: 'failed', reason: 'avaria', notes: 'x'),
  ],
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
  late _SyncBackend backend;
  late ApiClient client;
  late ActiveRouteService service;
  late OfflineRequestQueue queue;
  late List<OfflineQueueEvent> events;
  late StreamSubscription<OfflineQueueEvent> subscription;

  setUp(() {
    ApiFailureLog.instance.clear();
    backend = _SyncBackend();
    client = faultClient(backend.server);
    service = ActiveRouteService(client, storage: const FakeSessionStorage());
    queue = client.offlineRequests;
    events = [];
    subscription = client.offlineRequests.events.listen(events.add);
  });
  tearDown(() => subscription.cancel());

  void expectDeliveredExactlyOnce() {
    expect(backend.applied, hasLength(1), reason: 'baixa duplicada/perdida');
    expect(backend.photos, 2);
    expect(queue.pendingCount, 0);
    expect(queue.rejectedRequests, isEmpty);
    expect(
      backend.eventIds.toSet(),
      hasLength(1),
      reason: 'todo reenvio usa o mesmo client_event_id',
    );
  }

  test('com sinal, uma requisição só e a auditoria volta na hora', () async {
    final result = await service.complete(_submission());

    expect(result.queued, isFalse);
    expect(result.value!.deliveryWithinPlannedRadius, isTrue);
    expect(result.value!.trackerValidationStatus, 'match');
    expect(backend.server.requestsTo('POST', _syncPath), hasLength(1));
    final fields = {
      for (final entry in backend.lastForm!.fields) entry.key: entry.value,
    };
    expect(fields['kind'], 'stop.complete');
    expect(fields['stop_id'], '42');
    expect(fields['recipient_name'], 'Maria');
    // O servidor lê `items` (o app antigo mandava `item_results`).
    expect(fields['items'], contains('"status":"failed"'));
    expect(fields['occurred_at'], isNotEmpty);
    expect(fields['sent_at'], isNotEmpty);
    expect(
      backend.lastForm!.files.map((entry) => entry.key),
      containsAll(['photos', 'signature']),
    );
    expectDeliveredExactlyOnce();
  });

  group('queda de rede na baixa', () {
    for (final lost in [false, true]) {
      final label = lost ? 'resposta perdida' : 'antes de chegar';
      test('$label: salva no aparelho e conclui uma vez só', () async {
        backend.faults.add((request, apply) {
          if (lost) apply();
          return networkDown(request);
        });

        final first = await service.complete(_submission());
        expect(first.queued, isTrue);
        expect(queue.pendingCount, 1);

        await queue.retryNow(manual: true);
        expectDeliveredExactlyOnce();
      });
    }

    test('timeout no upload e servidor ocupado em seguida', () async {
      backend.faults
        ..add((request, _) => uploadTimeout(request))
        ..add(
          (_, _) => FaultReply.json({
            'detail': 'Servidor ocupado no momento. Tente novamente.',
          }, status: 503),
        );

      expect((await service.complete(_submission())).queued, isTrue);
      await queue.retryNow(manual: true);
      expect(queue.pendingCount, 1, reason: '503 mantém');
      await queue.retryNow(manual: true);

      expectDeliveredExactlyOnce();
      final log = ApiFailureLog.instance.export();
      expect(log, contains('ETEMPO Enviar baixa'));
      expect(log, contains('E503-OCUP Enviar baixa'));
    });

    test('sem sinal por muito tempo: nunca descarta e registra cada '
        'tentativa com etapa e referência', () async {
      backend.server.on(
        'GET',
        '/api/v1/',
        (request, _) => networkDown(request),
      );
      backend.faults.add((request, _) => networkDown(request));

      expect((await service.complete(_submission())).queued, isTrue);
      for (var attempt = 0; attempt < 6; attempt++) {
        await queue.retryNow(manual: attempt == 0);
      }

      expect(queue.pendingCount, 1, reason: 'nunca descarta');
      expect(queue.rejectedRequests, isEmpty);
      final entries = ApiFailureLog.instance.entries.value;
      expect(
        entries.every((entry) => entry.failure.requestId.startsWith('m')),
        isTrue,
      );
    });
  });

  group('resposta que não é da API', () {
    test('portal da operadora não conta como entregue', () async {
      backend.faults.add((_, _) => const FaultReply.captivePortal());

      final first = await service.complete(_submission());

      expect(first.queued, isTrue, reason: 'HTML 200 era aceito como sucesso');
      expect(backend.applied, isEmpty);
      await queue.retryNow(manual: true);
      expectDeliveredExactlyOnce();
    });

    test('portal depois de o servidor aplicar: reenvio não duplica', () async {
      backend.faults.add((_, apply) {
        apply();
        return const FaultReply.captivePortal();
      });

      expect((await service.complete(_submission())).queued, isTrue);
      await queue.retryNow(manual: true);

      expectDeliveredExactlyOnce();
    });

    test('Cloudflare bloqueando o IP da operadora fica na fila', () async {
      backend.faults.add(
        (_, _) => const FaultReply(
          403,
          body: '<html>challenge</html>',
          contentType: 'text/html',
          headers: {'cf-mitigated': 'challenge'},
        ),
      );

      expect((await service.complete(_submission())).queued, isTrue);
      await queue.retryNow(manual: true);
      expectDeliveredExactlyOnce();
    });

    test('erro interno (500) é tratado como passageiro, não apaga', () async {
      backend.faults.add(
        (_, _) => const FaultReply(
          500,
          body: '<h1>Server Error (500)</h1>',
          contentType: 'text/html',
        ),
      );

      expect((await service.complete(_submission())).queued, isTrue);
      expect(queue.pendingCount, 1);
      await queue.retryNow(manual: true);
      expectDeliveredExactlyOnce();
    });
  });

  group('recusa definitiva diz etapa, campo, motivo e referência', () {
    Future<String> refusal() async {
      try {
        await service.complete(_submission());
      } on ActiveRouteException catch (error) {
        expect(queue.pendingCount, 0);
        expect(queue.rejectedRequests, isEmpty, reason: 'já foi mostrada');
        return error.message;
      }
      fail('a baixa deveria ter sido recusada');
    }

    test('foto corrompida (400)', () async {
      backend.faults.add(
        (request, _) => _echoRef(
          request,
          FaultReply.json([
            'Foto corrompida ou em formato inválido. Tire a foto novamente.',
          ], status: 400),
        ),
      );

      final message = await refusal();

      expect(message, startsWith('Enviar baixa: Foto corrompida'));
      expect(message, matches(RegExp(r'\(E400-RECUSA · ref m[a-z2-9]{10}\)$')));
      expect(backend.applied, isEmpty);
    });

    test('baixa grande demais para o proxy (413)', () async {
      backend.faults.add(
        (_, _) => const FaultReply(
          413,
          body: '<html>413 Request Entity Too Large</html>',
          contentType: 'text/html',
        ),
      );

      expect(
        await refusal(),
        startsWith('Enviar baixa: arquivo grande demais'),
      );
    });

    test('parada transferida para outro entregador (404)', () async {
      backend.faults.add(
        (_, _) => FaultReply.json({'detail': 'Não encontrado.'}, status: 404),
      );

      expect(await refusal(), contains('Enviar baixa: Não encontrado.'));
    });

    test(
      'recusa depois, com a tela fechada, fica em "precisa de atenção"',
      () async {
        backend.faults
          ..add((request, _) => networkDown(request))
          ..add(
            (_, _) =>
                FaultReply.json({'detail': 'Não encontrado.'}, status: 404),
          );

        expect((await service.complete(_submission())).queued, isTrue);
        await queue.retryNow(manual: true);

        expect(queue.pendingCount, 0);
        expect(queue.rejectedRequests, hasLength(1));
        expect(
          queue.rejectedRequests.single.rejection,
          contains('Não encontrado'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          events.where((event) => event.type == OfflineQueueEventType.rejected),
          hasLength(1),
        );
      },
    );

    test('sessão expirada (401): espera novo login, não descarta', () async {
      backend.faults.add(
        (_, _) => FaultReply.json({
          'detail': 'Token inválido ou expirado.',
        }, status: 401),
      );

      expect((await service.complete(_submission())).queued, isTrue);
      expect(queue.status.value.needsLogin, isTrue);
      expect(queue.pendingCount, 1);
      expect(queue.rejectedRequests, isEmpty);
    });

    test('coordenadas inválidas são barradas antes da rede', () async {
      for (final (lat, lon) in [
        (double.nan, -43.0),
        (-22.8, double.infinity),
        (95.0, -43.0),
        (-22.8, 190.0),
      ]) {
        await expectLater(
          service.complete(_submission(latitude: lat, longitude: lon)),
          throwsA(isA<ActiveRouteException>()),
          reason: '$lat,$lon',
        );
      }
      expect(backend.server.seen, isEmpty);
    });
  });
}
