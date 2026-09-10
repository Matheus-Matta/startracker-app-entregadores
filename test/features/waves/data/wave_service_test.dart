import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/storage/session_storage.dart';
import 'package:star_tracker/features/waves/data/pickup_label_scope.dart';
import 'package:star_tracker/features/waves/data/wave_service.dart';

void main() {
  group('PickupLabelScope.fromConfiguration', () {
    test('usa a granularidade devolvida pela configuracao da API', () {
      expect(
        PickupLabelScope.fromConfiguration({'label_granularity': 'volume'}),
        PickupLabelScope.volume,
      );
      expect(
        PickupLabelScope.fromConfiguration({'label_granularity': 'item'}),
        PickupLabelScope.item,
      );
      expect(
        PickupLabelScope.fromConfiguration({'label_granularity': 'order'}),
        PickupLabelScope.order,
      );
    });

    test('usa volume quando a API antiga nao informa a granularidade', () {
      expect(
        PickupLabelScope.fromConfiguration(const {}),
        PickupLabelScope.volume,
      );
    });
  });

  group('WaveService.displayStatus', () {
    test('prioriza rota iniciada mesmo quando a wave esta defasada', () {
      expect(WaveService.displayStatus('ready', 'started'), 'started');
    });

    test('mantem o status proprio da wave antes da rota ser iniciada', () {
      expect(WaveService.displayStatus('ready', 'released'), 'ready');
    });

    test('usa o status da rota durante a operacao normal', () {
      expect(WaveService.displayStatus('released', 'started'), 'started');
    });
  });

  group('WaveService.parsePickupProgress', () {
    test('usa os codigos e a granularidade devolvidos pelo endpoint', () {
      final progress = WaveService.parsePickupProgress({
        'wave_id': 10,
        'pickup_enabled': true,
        'barcode_source': 'order_number',
        'label_granularity': 'item',
        'total': 2,
        'picked_up': 0,
        'pending': 2,
        'is_complete': false,
        'orders': [
          {
            'order_id': 81,
            'order_number': 'PED-2026-001',
            'customer': 'Cliente Exemplo',
            'codes': [
              {
                'code': 'PED-2026-001-1',
                'scanned_at': '2026-08-22T09:14:00-03:00',
              },
              {'code': 'PED-2026-001-3', 'scanned_at': null},
            ],
            'picked_up_at': null,
          },
          {
            'order_id': 82,
            'order_number': 'PED-2026-002',
            'customer': 'Outro cliente',
            'codes': [
              {'code': 'PED-2026-002', 'scanned_at': null},
            ],
            'picked_up_at': null,
          },
        ],
      }, 99);

      expect(progress.waveId, 10);
      expect(progress.total, 2);
      expect(progress.totalLabels, 3);
      expect(progress.scannedLabels, 1);
      expect(progress.pendingLabels, 2);
      expect(progress.orders.first.totalLabels, 2);
      expect(progress.orders.first.scannedLabels, 1);
      expect(progress.orders.first.isPickedUp, isFalse);
      expect(progress.orders.first.codes.last.code, 'PED-2026-001-3');
      expect(progress.labelGranularity, PickupLabelScope.item);
    });

    test('nao inventa codigo quando orders.codes nao foi devolvido', () {
      final progress = WaveService.parsePickupProgress({
        'pickup_enabled': true,
        'orders': [
          {
            'order_id': 81,
            'order_number': 'PED-81',
            'code': 'PED-81',
            'items': [
              {'units': 3},
            ],
            'picked_up_at': null,
          },
        ],
      }, 10);

      expect(progress.totalLabels, 0);
      expect(progress.orders.single.codes, isEmpty);
    });
  });

  group('PickupOrder.matchesCode', () {
    const order = PickupOrder(
      orderId: 81,
      orderNumber: 'PED-81',
      customer: 'Cliente',
      pickedUpAt: null,
      codes: [
        PickupCode(code: 'PED-81-1', scannedAt: null),
        PickupCode(code: 'EXT ABC', scannedAt: null),
      ],
    );

    test('ignora caixa e espacos apenas nas extremidades', () {
      expect(order.matchesCode(' ped-81-1 '), isTrue);
      expect(order.matchesCode(' ext abc '), isTrue);
      expect(order.matchesCode('EXTABC'), isFalse);
    });

    test('nao deduz codigo-base pelo numero do pedido', () {
      expect(order.matchesCode('PED-81'), isFalse);
    });
  });

  test(
    'registerPickup envia somente a etiqueta lida em um unico POST',
    () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        storage: const _EmptyStorage(),
      );
      final adapter = _PickupAdapter();
      client.dio.httpClientAdapter = adapter;
      final service = WaveService(client);

      final progress = await service.registerPickup(
        waveId: 42,
        code: '  PED 100  ',
      );

      expect(adapter.requests.length, 1);
      expect(adapter.requests.single.method, 'POST');
      expect(
        adapter.requests.single.path,
        '/api/v1/delivery/waves/42/retirada/',
      );
      expect(adapter.requests.single.data, {'code': 'PED 100'});
      expect(progress.waveId, 42);
      expect(progress.labelGranularity, PickupLabelScope.order);
    },
  );

  test(
    'registerPickup rejeita codigo vazio com a mensagem do contrato',
    () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        storage: const _EmptyStorage(),
      );
      final service = WaveService(client);

      await expectLater(
        service.registerPickup(waveId: 42, code: '   '),
        throwsA(
          isA<WaveServiceException>().having(
            (error) => error.message,
            'message',
            'Informe o código da etiqueta.',
          ),
        ),
      );
    },
  );

  test(
    'detalhe nao restaura pedido transferido a partir de parada cancelada',
    () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        storage: const _EmptyStorage(),
      );
      final adapter = _TransferredOrderAdapter();
      client.dio.httpClientAdapter = adapter;
      final service = WaveService(client);

      final details = await service.getWaveDetails(
        WaveListItem(
          waveId: 10,
          routeId: 20,
          routeNumber: 'Rota 20',
          status: 'released',
          plannedDistanceMeters: 0,
          plannedStart: null,
          createdAt: null,
        ),
      );

      expect(details.orders, isEmpty);
      expect(details.pickup.total, 0);
      expect(
        adapter.requests.every(
          (request) => request.queryParameters.containsKey('_detail_refresh'),
        ),
        isTrue,
      );
    },
  );
}

class _EmptyStorage extends SessionStorage {
  const _EmptyStorage();

  @override
  Future<String?> readToken() async => null;

  @override
  Future<String?> readRefreshToken() async => null;
}

class _PickupAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'wave_id': 42,
        'pickup_enabled': true,
        'barcode_source': 'order_number',
        'label_granularity': 'order',
        'total': 1,
        'picked_up': 1,
        'pending': 0,
        'is_complete': true,
        'orders': [
          {
            'order_id': 81,
            'order_number': 'PED 100',
            'customer': 'Cliente',
            'codes': [
              {'code': 'PED 100', 'scanned_at': '2026-09-09T10:00:00-03:00'},
            ],
            'picked_up_at': '2026-09-09T10:00:00-03:00',
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _TransferredOrderAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final data = switch (options.path) {
      '/api/v1/delivery/waves/10/retirada/' => {
        'wave_id': 10,
        'pickup_enabled': true,
        'total': 0,
        'picked_up': 0,
        'pending': 0,
        'is_complete': true,
        'orders': <dynamic>[],
      },
      '/api/v1/delivery/waves/10/' => {
        'id': 10,
        'status': 'released',
        'orders': <dynamic>[],
      },
      '/api/v1/delivery/rotas/20/' => {
        'id': 20,
        'wave': 10,
        'status': 'released',
      },
      '/api/v1/delivery/paradas/' => {
        'results': [
          {
            'id': 30,
            'route': 20,
            'order': 81,
            'sequence': 1,
            'status': 'cancelled',
          },
        ],
        'next': null,
      },
      '/api/v1/delivery/pedidos-wave/' ||
      '/api/v1/delivery/pedidos/' => {'results': <dynamic>[], 'next': null},
      _ => <String, dynamic>{},
    };
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
