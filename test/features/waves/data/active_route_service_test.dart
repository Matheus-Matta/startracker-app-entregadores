import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/storage/session_storage.dart';
import 'package:star_tracker/features/waves/data/active_route_service.dart';
import 'package:star_tracker/features/waves/data/route_snapshot_store.dart';
import 'package:star_tracker/features/auth/data/delivery_configuration.dart';

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

  test(
    'conclui usando URL, metodo e campos publicados no contrato v6',
    () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        storage: const _EmptyStorage(),
      );
      final adapter = _CompletionAdapter();
      client.dio.httpClientAdapter = adapter;
      final service = ActiveRouteService(
        client,
        storage: const _EmptyStorage(),
      );
      final stop = _stop(id: 42, sequence: 1, status: 'delivering').copyWith();
      final configuredStop = ActiveRouteStop(
        stopId: stop.stopId,
        orderId: stop.orderId,
        sequence: stop.sequence,
        status: stop.status,
        orderStatus: stop.orderStatus,
        isManual: stop.isManual,
        plannedEta: stop.plannedEta,
        orderNumber: stop.orderNumber,
        customerName: stop.customerName,
        customerPhone: stop.customerPhone,
        fullAddress: stop.fullAddress,
        latitude: stop.latitude,
        longitude: stop.longitude,
        units: stop.units,
        weightGrams: stop.weightGrams,
        contents: stop.contents,
        proofOverrides: stop.proofOverrides,
        policy: stop.policy,
        existingProofId: stop.existingProofId,
        existingPhotoCount: stop.existingPhotoCount,
        hasSignature: stop.hasSignature,
        existingRecipientName: stop.existingRecipientName,
        existingRecipientDocument: stop.existingRecipientDocument,
        existingNotes: stop.existingNotes,
        confirmationLocation: ConfirmationLocationPolicy.fromConfiguration(
          const {
            'confirmation_location': {
              'enabled': true,
              'request_fresh_location': true,
              'complete_url_template': '/api/v1/custom/stops/{stop_id}/finish/',
              'method': 'PATCH',
              'latitude_field': 'mobile_lat',
              'longitude_field': 'mobile_lng',
            },
          },
        ),
      );

      final result = await service.complete(
        DeliveryProofSubmission(
          stop: configuredStop,
          recipientName: 'Maria',
          recipientDocument: '',
          notes: '',
          photos: const [],
          signatureBytes: null,
          latitude: -22.8301,
          longitude: -43.0402,
          itemResults: const [DeliveryItemResult(id: 9, status: 'delivered')],
        ),
      );

      expect(result.queued, isFalse);
      expect(result.value?.trackerValidationLabel, 'Compatível');
      expect(adapter.completionMethod, 'PATCH');
      expect(adapter.completionData?['mobile_lat'], -22.8301);
      expect(adapter.completionData?['mobile_lng'], -43.0402);
      expect(adapter.completionData, contains('item_results'));
      expect(adapter.completionData, isNot(contains('items')));
      expect(adapter.proofFields, isNot(contains('lat')));
      expect(adapter.proofFields, isNot(contains('lon')));
    },
  );

  test(
    'reenvio retoma comprovante e fotos ja gravados em vez de recria-los',
    () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        storage: const _EmptyStorage(),
      );
      final adapter = _FlakyCompletionAdapter();
      client.dio.httpClientAdapter = adapter;
      final service = ActiveRouteService(
        client,
        storage: const _EmptyStorage(),
      );

      final first = await service.complete(
        DeliveryProofSubmission(
          stop: _stop(id: 42, sequence: 1, status: 'delivering'),
          recipientName: 'Maria',
          recipientDocument: '',
          notes: '',
          photos: [
            DeliveryPhotoUpload(bytes: Uint8List(4), filename: 'a.jpg'),
            DeliveryPhotoUpload(bytes: Uint8List(4), filename: 'b.jpg'),
          ],
          signatureBytes: null,
          latitude: null,
          longitude: null,
          itemResults: const [],
        ),
      );
      expect(first.queued, isTrue);

      await client.offlineRequests.retryNow(manual: true);

      expect(client.offlineRequests.pendingCount, 0);
      expect(adapter.proofCreates, 1);
      expect(adapter.proofPatches, 1);
      expect(adapter.photoSequences, ['1', '2']);
      expect(adapter.completions, 1);
    },
  );

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

class _CompletionAdapter implements HttpClientAdapter {
  String? completionMethod;
  Map<String, dynamic>? completionData;
  final Set<String> proofFields = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    late final Map<String, dynamic> response;
    if (options.path == '/api/v1/delivery/comprovantes/') {
      final form = options.data as FormData;
      proofFields.addAll(form.fields.map((entry) => entry.key));
      response = {'id': 15};
    } else if (options.path == '/api/v1/custom/stops/42/finish/') {
      completionMethod = options.method;
      completionData = Map<String, dynamic>.from(options.data as Map);
      response = {
        'proof': {
          'tracker_validation_status': 'MATCH',
          'tracker_validation_label': 'Compatível',
        },
      };
    } else {
      response = {};
    }
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Simula o 4G: o comprovante e a 1a foto chegam ao servidor, a 2a foto cai.
class _FlakyCompletionAdapter implements HttpClientAdapter {
  int proofCreates = 0;
  int proofPatches = 0;
  int completions = 0;
  final List<String> photoSequences = [];
  final List<String> _storedSequences = [];
  bool _dropped = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.path;
    Object response = <String, dynamic>{};
    if (path == '/api/v1/delivery/comprovantes/' && options.method == 'POST') {
      proofCreates++;
      response = {'id': 15};
    } else if (path == '/api/v1/delivery/comprovantes/15/') {
      proofPatches++;
      response = {'id': 15};
    } else if (path == '/api/v1/delivery/fotos-comprovante/' &&
        options.method == 'POST') {
      final form = options.data as FormData;
      final sequence = form.fields
          .firstWhere((entry) => entry.key == 'sequence')
          .value;
      if (sequence == '2' && !_dropped) {
        _dropped = true;
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'Connection closed while receiving data',
        );
      }
      photoSequences.add(sequence);
      _storedSequences.add(sequence);
      response = {'id': 100 + photoSequences.length};
    } else if (path == '/api/v1/delivery/fotos-comprovante/') {
      response = {
        'results': [
          for (final sequence in _storedSequences)
            {'delivery_proof': 15, 'sequence': int.parse(sequence)},
        ],
        'next': null,
      };
    } else if (path == '/api/v1/delivery/paradas/42/') {
      response = {
        'id': 42,
        'status': 'delivering',
        'proof': {'id': 15},
      };
    } else if (path == '/api/v1/delivery/paradas/42/complete/') {
      completions++;
      response = {'status': 'completed', 'proof': <String, dynamic>{}};
    }
    return ResponseBody.fromString(
      jsonEncode(response),
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
