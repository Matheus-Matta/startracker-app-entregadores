import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/network/offline_request_store.dart';
import 'package:star_tracker/core/storage/session_storage.dart';
import 'package:star_tracker/features/waves/data/active_route_service.dart';
import 'package:star_tracker/features/waves/data/route_snapshot_store.dart';

void main() {
  test('currentStop respeita a sequencia depois de adiar uma parada', () {
    final route = ActiveRoute(
      routeId: 1,
      waveId: 1,
      routeNumber: 'Rota 1',
      status: 'started',
      path: const [],
      deliveryWaypoints: const {},
      warehouse: null,
      stops: [
        _stop(id: 3, sequence: 2, status: 'planned'),
        _stop(id: 2, sequence: 3, status: 'approaching'),
      ],
    );

    expect(route.currentStop?.stopId, 3);
  });

  test('le o armazem de origem nos planned_waypoints da rota', () {
    final warehouse = ActiveRouteService.parseWarehouseWaypoint(const [
      {
        'kind': 'pickup',
        'warehouse_id': 1,
        'name': 'Centro de Distribuicao',
        'location': [-43.0027, -22.8298],
      },
    ]);

    expect(warehouse?.name, 'Centro de Distribuicao');
    expect(warehouse?.coordinate.latitude, -22.8298);
    expect(warehouse?.coordinate.longitude, -43.0027);
  });

  test('remove da rota ativa a parada cancelada por transferencia', () async {
    final client = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: const _EmptyStorage(),
    );
    client.dio.httpClientAdapter = _CancelledStopAdapter();
    final service = ActiveRouteService(client, storage: const _EmptyStorage());

    final route = await service.getRoute(20);

    expect(route.stops, isEmpty);
    expect(route.currentStop, isNull);
  });

  test('baixa sem sinal continua aparecendo depois de reabrir o app e fecha a '
      'rota pela regra do servidor', () async {
    final directory = await Directory.systemTemp.createTemp('offline_flow');
    addTearDown(() => directory.delete(recursive: true));
    ActiveRouteService open(HttpClientAdapter adapter) {
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        storage: const _EmptyStorage(),
        offlineStore: OfflineRequestStore(
          baseDirectory: () async => Directory('${directory.path}/q'),
        ),
      )..readRetryDelays = const [];
      client.dio.httpClientAdapter = adapter;
      return ActiveRouteService(
        client,
        storage: const _EmptyStorage(),
        snapshotStore: RouteSnapshotStore(
          baseDirectory: () async => Directory('${directory.path}/s'),
        ),
      );
    }

    // Com sinal: a rota é baixada e fica salva no aparelho.
    await open(_OnlineRouteAdapter()).getRoute(20);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Sem sinal: chegada e baixa ficam salvas, a tela muda na hora.
    final offline = open(_OfflineAdapter());
    await offline.apiClient.offlineRequests.restorePersisted();
    await offline.getRoute(20);
    await offline.arrive(30);
    final saved = await offline.complete(
      DeliveryProofSubmission(
        stop: _stop(id: 30, sequence: 1, status: 'arrived'),
        recipientName: 'Maria',
        recipientDocument: '',
        notes: '',
        photos: [DeliveryPhotoUpload(bytes: Uint8List(4), filename: 'a.jpg')],
        signatureBytes: null,
        latitude: null,
        longitude: null,
        itemResults: const [],
      ),
    );
    expect(saved.queued, isTrue);
    final now = offline.cachedRoute(20)!;
    expect(now.stops.single.status, 'completed');
    expect(now.stops.single.orderStatus, 'delivered');
    expect(now.status, 'completed', reason: 'última parada fecha a rota');
    expect(now.waveStatus, 'completed', reason: 'e a carga');

    // App encerrado pelo sistema e reaberto, ainda sem sinal.
    final reopened = open(_OfflineAdapter());
    await reopened.apiClient.offlineRequests.restorePersisted();
    expect(reopened.apiClient.offlineRequests.pendingCount, 2);
    final route = await reopened.getRoute(20);
    expect(route.stops.single.status, 'completed');
    expect(route.status, 'completed');
  });

  test(
    'mapa abre da copia em disco sem rede depois de o app reabrir',
    () async {
      final directory = await Directory.systemTemp.createTemp('route_snap');
      addTearDown(() => directory.delete(recursive: true));
      ActiveRouteService service(HttpClientAdapter adapter) {
        final client = ApiClient(
          baseUrl: 'https://api.example.test',
          storage: const _EmptyStorage(),
        )..readRetryDelays = const [];
        client.dio.httpClientAdapter = adapter;
        return ActiveRouteService(
          client,
          storage: const _EmptyStorage(),
          snapshotStore: RouteSnapshotStore(
            baseDirectory: () async => directory,
          ),
        );
      }

      final online = await service(_OnlineRouteAdapter()).getRoute(20);
      expect(online.stops.single.stopId, 30);
      // A gravação em disco é assíncrona; espera ela terminar.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Novo serviço = app reaberto pelo sistema, memória vazia, sem rede.
      final restored = await service(_OfflineAdapter()).getRoute(20);

      expect(restored.routeNumber, 'Rota 20');
      expect(restored.stops.single.stopId, 30);
    },
  );

  group('carga da rota no 4G', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('route_rtt');
    });
    tearDown(() async {
      // A cópia em disco é gravada em segundo plano; espera terminar.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // Windows pode segurar o arquivo por um instante; é só limpeza.
      }
    });

    ActiveRouteService service(HttpClientAdapter adapter) {
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        storage: const _EmptyStorage(),
      )..readRetryDelays = const [];
      client.dio.httpClientAdapter = adapter;
      return ActiveRouteService(
        client,
        storage: const _EmptyStorage(),
        snapshotStore: RouteSnapshotStore(baseDirectory: () async => directory),
      );
    }

    test('usa o comprovante embutido na parada e so busca fotos de baixa '
        'pela metade', () async {
      final adapter = _RecordingRouteAdapter(nestedProofs: true);

      final route = await service(adapter).getRoute(20);

      expect(adapter.paths, isNot(contains('/api/v1/delivery/comprovantes/')));
      // Só o comprovante da parada ainda aberta (31 -> prova 501).
      expect(adapter.photoProofFilters, [
        ['501'],
      ]);
      final open = route.stops.firstWhere((stop) => stop.stopId == 31);
      expect(open.existingProofId, 501);
      expect(open.existingRecipientName, 'Maria');
      expect(open.existingPhotoCount, 1);
    });

    test(
      'servidor antigo sem comprovante embutido continua consultando',
      () async {
        final adapter = _RecordingRouteAdapter(nestedProofs: false);

        final route = await service(adapter).getRoute(20);

        expect(adapter.paths, contains('/api/v1/delivery/comprovantes/'));
        expect(
          route.stops.firstWhere((stop) => stop.stopId == 31).existingProofId,
          501,
        );
      },
    );

    test('com a carga conhecida, os pedidos saem junto com a rota', () async {
      final adapter = _RecordingRouteAdapter(nestedProofs: true);
      final routes = service(adapter);
      await routes.getRoute(20);
      adapter
        ..events.clear()
        ..routeDelay = const Duration(milliseconds: 60);

      await routes.getRoute(20);

      expect(
        adapter.events.indexOf('start /api/v1/delivery/pedidos/'),
        lessThan(adapter.events.indexOf('done /api/v1/delivery/rotas/20/')),
      );
    });
  });
}

ActiveRouteStop _stop({
  required int id,
  required int sequence,
  required String status,
}) => ActiveRouteStop(
  stopId: id,
  orderId: id,
  sequence: sequence,
  status: status,
  orderStatus: 'out_for_delivery',
  isManual: false,
  plannedEta: null,
  orderNumber: 'PED-$id',
  customerName: 'Cliente $id',
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

class _EmptyStorage extends SessionStorage {
  const _EmptyStorage();

  @override
  Future<String?> readToken() async => null;

  @override
  Future<Map<String, dynamic>> readDeliveryConfig() async => const {};
}

class _CancelledStopAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = switch (options.path) {
      '/api/v1/delivery/rotas/20/' => {
        'id': 20,
        'wave': 10,
        'route_number': 'Rota 20',
        'status': 'started',
        'path_geometry': <dynamic>[],
        'planned_waypoints': <dynamic>[],
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
      _ => {'results': <dynamic>[], 'next': null},
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

class _OnlineRouteAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = switch (options.path) {
      '/api/v1/delivery/rotas/20/' => {
        'id': 20,
        'wave': 10,
        'route_number': 'Rota 20',
        'status': 'started',
        'path_geometry': <dynamic>[],
        'planned_waypoints': <dynamic>[],
      },
      '/api/v1/delivery/paradas/' => {
        'results': [
          {
            'id': 30,
            'route': 20,
            'order': 81,
            'sequence': 1,
            'status': 'planned',
          },
        ],
        'next': null,
      },
      '/api/v1/delivery/pedidos/' => {
        'results': [
          {'id': 81, 'order_number': 'PED-81', 'status': 'out_for_delivery'},
        ],
        'next': null,
      },
      _ => {'results': <dynamic>[], 'next': null},
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

class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(
    requestOptions: options,
    reason: 'Failed host lookup',
  );

  @override
  void close({bool force = false}) {}
}

class _RecordingRouteAdapter implements HttpClientAdapter {
  _RecordingRouteAdapter({required this.nestedProofs});

  final bool nestedProofs;
  final List<String> paths = [];
  final List<String> events = [];
  final List<List<String>> photoProofFilters = [];
  Duration routeDelay = Duration.zero;

  static const _proofs = {
    30: {'id': 500, 'route_stop': 30, 'recipient_name': 'Joao'},
    31: {'id': 501, 'route_stop': 31, 'recipient_name': 'Maria'},
  };

  Map<String, dynamic> _stop(int id, String status) => {
    'id': id,
    'route': 20,
    'order': id + 50,
    'sequence': id - 29,
    'status': status,
    if (nestedProofs) 'proof': _proofs[id],
  };

  Map<String, dynamic> _photos(RequestOptions options) {
    final raw = options.queryParameters['delivery_proof'];
    final filter = [
      for (final value in raw is List ? raw : [raw]) value.toString(),
    ];
    photoProofFilters.add(filter);
    return {
      'results': [
        for (final id in filter)
          {'id': 900, 'delivery_proof': int.parse(id), 'sequence': 1},
      ],
      'next': null,
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    events.add('start ${options.path}');
    if (options.path == '/api/v1/delivery/rotas/20/' &&
        routeDelay > Duration.zero) {
      await Future<void>.delayed(routeDelay);
    }
    final data = switch (options.path) {
      '/api/v1/delivery/rotas/20/' => <String, dynamic>{
        'id': 20,
        'wave': 10,
        'route_number': 'Rota 20',
        'status': 'started',
      },
      '/api/v1/delivery/paradas/' => <String, dynamic>{
        'results': [_stop(30, 'completed'), _stop(31, 'delivering')],
        'next': null,
      },
      '/api/v1/delivery/pedidos/' => <String, dynamic>{
        'results': [
          {'id': 80, 'order_number': 'PED-80', 'status': 'delivered'},
          {'id': 81, 'order_number': 'PED-81', 'status': 'out_for_delivery'},
        ],
        'next': null,
      },
      '/api/v1/delivery/comprovantes/' => <String, dynamic>{
        'results': _proofs.values.toList(),
        'next': null,
      },
      '/api/v1/delivery/fotos-comprovante/' => _photos(options),
      _ => <String, dynamic>{'results': <dynamic>[], 'next': null},
    };
    events.add('done ${options.path}');
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
