import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_failure.dart';
import 'package:star_tracker/core/network/offline_request_queue.dart';
import 'package:star_tracker/core/network/offline_request_store.dart';
import 'package:star_tracker/features/waves/data/active_route_service.dart';
import 'package:star_tracker/features/waves/data/route_snapshot_store.dart';

import '../../../support/fault_server.dart';

const _route = '/api/v1/delivery/rotas/20/';
const _stops = '/api/v1/delivery/paradas/';
const _orders = '/api/v1/delivery/pedidos/';

Map<String, dynamic> _page(List<Object?> results) => {
  'results': results,
  'next': null,
};

/// Dados como chegam de cadastro ruim, importação ou paginação instável.
void _corruptedRoute(FaultServer server) {
  server
    ..always('GET', _route, {
      'id': '20', // id como texto
      'wave': 10,
      'route_number': 'Rota 20',
      'status': 'started',
      'path_geometry': {
        'coordinates': [
          [-43.0, -22.8],
          ['abc', -22.8], // texto
          [-43.0], // ponto incompleto
          ['NaN', 'NaN'], // passa no double.tryParse
          [-43.1, -22.9],
          [0, 0], // sem geocodificação
          [500, 95], // fora do globo
        ],
      },
      'planned_waypoints': [
        {
          'kind': 'delivery',
          'order_id': 81,
          'location': ['Infinity', -22.8],
        },
        {
          'kind': 'delivery',
          'order_id': 82,
          'location': [-43.2, -22.7],
        },
        'lixo',
      ],
    })
    ..always(
      'GET',
      _stops,
      _page([
        {
          'id': 30,
          'route': 20,
          'order': 81,
          'sequence': 2,
          'status': 'planned',
        },
        {'id': '31', 'route': '20', 'order': '82', 'sequence': '1'},
        {'id': 30, 'route': 20, 'order': 81, 'sequence': 2}, // repetida
        {'id': 32, 'route': 20, 'order': null, 'sequence': 3}, // sem pedido
        {'id': null, 'route': 20, 'order': 83},
        {'id': 33, 'route': 99, 'order': 84}, // de outra rota
        {'id': 34, 'route': 20, 'order': 85, 'status': 'cancelled'},
        {'id': 35, 'route': 20, 'order': 86, 'sequence': 4},
        {'id': 36, 'route': 20, 'order': 87, 'sequence': 5},
        'não é objeto',
        null,
      ]),
    )
    ..always(
      'GET',
      _orders,
      _page([
        {'id': 81, 'order_number': 'P81', 'lat': 'NaN', 'lon': -43.0},
        {'id': 82, 'order_number': 'P82', 'lat': '-22.7', 'lon': '-43.2'},
        {'id': 86, 'order_number': 'P86', 'lat': 0, 'lon': 0},
        {'id': 87, 'order_number': 'P87', 'lat': -43.1, 'lon': 222.0},
      ]),
    );
}

void main() {
  late Directory directory;

  setUp(() async {
    ApiFailureLog.instance.clear();
    directory = await Directory.systemTemp.createTemp('route_faults');
  });
  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Windows pode segurar o arquivo por um instante; é só limpeza.
    }
  });

  ActiveRouteService service(FaultServer server) => ActiveRouteService(
    faultClient(server),
    storage: const FakeSessionStorage(),
    snapshotStore: RouteSnapshotStore(baseDirectory: () async => directory),
  );

  test(
    'dados corrompidos nao derrubam o mapa e nada invalido chega a ele',
    () async {
      final server = FaultServer();
      _corruptedRoute(server);

      final route = await service(server).getRoute(20);

      expect(route.routeId, 20);
      expect(
        route.stops.map((stop) => stop.stopId),
        [31, 30, 35, 36],
        reason: 'só paradas válidas, sem repetição, na ordem da sequência',
      );
      final byId = {for (final stop in route.stops) stop.stopId: stop};
      expect(byId[31]!.latitude, -22.7);
      expect(byId[31]!.longitude, -43.2);
      for (final id in [30, 35, 36]) {
        expect(byId[id]!.latitude, isNull, reason: 'parada $id');
        expect(byId[id]!.longitude, isNull, reason: 'parada $id');
      }
      expect(route.path, hasLength(2));
      for (final point in route.path) {
        expect(point.latitude.isFinite && point.longitude.isFinite, isTrue);
      }
      expect(route.deliveryWaypoints.keys, [82]);
    },
  );

  test('validCoordinate recusa cada forma de coordenada invalida', () {
    final invalid = <(double?, double?)>[
      (null, -43.0),
      (-22.8, null),
      (double.nan, -43.0),
      (-22.8, double.infinity),
      (90.01, -43.0),
      (-90.01, -43.0),
      (-22.8, 180.01),
      (0, 0),
    ];
    for (final (lat, lon) in invalid) {
      expect(
        ActiveRouteService.validCoordinate(lat, lon),
        isNull,
        reason: '$lat,$lon',
      );
    }
    expect(ActiveRouteService.validCoordinate(0, -43.0), isNotNull);
    expect(ActiveRouteService.validCoordinate(90, 180), isNotNull);
  });

  test(
    'portal da operadora sem copia salva: erro diz a etapa e o motivo',
    () async {
      final server = FaultServer()
        ..always('GET', _stops, const FaultReply.captivePortal())
        ..always('GET', _route, {'id': 20, 'wave': 10});

      await expectLater(
        service(server).getRoute(20),
        throwsA(
          isA<ActiveRouteException>().having(
            (error) => error.message,
            'message',
            allOf(
              startsWith('Carregar paradas: resposta inesperada'),
              contains('ERESP'),
            ),
          ),
        ),
      );
    },
  );

  test('portal da operadora com copia salva: mapa abre da copia', () async {
    final online = FaultServer();
    _corruptedRoute(online);
    await service(online).getRoute(20);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final portal = FaultServer()
      ..on('GET', '.*', (_, _) => const FaultReply.captivePortal());
    final route = await service(portal).getRoute(20);

    expect(route.stops.map((stop) => stop.stopId), [31, 30, 35, 36]);
    expect(
      ApiFailureLog.instance.export(),
      contains('ERESP Carregar rota GET /api/v1/delivery/rotas/N/'),
    );
  });

  test('erro de permissao na carga (403) nao e mascarado pela copia', () async {
    final server = FaultServer()
      ..always(
        'GET',
        _route,
        FaultReply.json({
          'detail': 'Você não tem permissão para executar essa ação.',
        }, status: 403),
      );

    await expectLater(
      service(server).getRoute(20),
      throwsA(
        isA<ActiveRouteException>()
            .having((error) => error.statusCode, 'status', 403)
            .having(
              (error) => error.message,
              'message',
              contains('Carregar rota: Você não tem permissão'),
            ),
      ),
    );
  });

  group('fila offline com registro danificado no aparelho', () {
    Future<OfflineRequestStore> storeWith(
      Future<void> Function(OfflineRequestStore store, Directory root) arrange,
    ) async {
      final store = OfflineRequestStore(baseDirectory: () async => directory);
      await arrange(store, Directory('${directory.path}/offline_queue'));
      return store;
    }

    StoredOfflineRequest request(String id, {Map<String, Uint8List>? files}) =>
        StoredOfflineRequest(
          id: id,
          resourceKey: 'stop:$id',
          description: 'Finalizar entrega $id',
          idempotencyKey: id,
          createdAt: DateTime(2026, 11, 15),
          request: PersistedOfflineRequest(
            type: 'teste',
            payload: {'stop_id': id},
            files: files ?? const {},
          ),
        );

    test('descarta so o danificado e avisa o motivo de cada um', () async {
      final store = await storeWith((store, root) async {
        await store.save(request('ok'));
        await store.save(request('sem-foto', files: {'photo_0': Uint8List(3)}));
        File('${root.path}/sem-foto/file_0.bin').deleteSync();
        await store.save(request('json-ruim'));
        File(
          '${root.path}/json-ruim/request.json',
        ).writeAsStringSync('{"id": "json-ru');
        Directory('${root.path}/gravacao-interrompida').createSync();
      });

      final server = FaultServer();
      final client = faultClient(server);
      final queue = OfflineRequestQueue(
        client.dio,
        const FakeSessionStorage(),
        store: store,
      );
      final restored = <String>[];
      queue.registerRestoreHandler('teste', (key, payload, files) async {
        restored.add(payload['stop_id'].toString());
      });
      final events = <OfflineQueueEvent>[];
      final subscription = queue.events.listen(events.add);

      await queue.restorePersisted();
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(queue.pendingCount, 1);
      final rejected = events
          .where((event) => event.type == OfflineQueueEventType.rejected)
          .toList();
      expect(
        rejected.map((event) => event.description),
        unorderedEquals([
          'Finalizar entrega sem-foto',
          'Alteração salva offline',
        ]),
      );
      final missing = rejected.firstWhere(
        (event) => event.resourceKey == 'stop:sem-foto',
      );
      expect(
        describeFailure(missing.error),
        contains('anexo "photo_0" ausente'),
      );
      expect(ApiFailureLog.instance.export(), contains('Reabrir fila offline'));
      queue.dispose();
    });

    test('JSON valido mas sem estrutura esperada tambem e reportado', () async {
      final store = await storeWith((store, root) async {
        Directory('${root.path}/lista').createSync(recursive: true);
        File(
          '${root.path}/lista/request.json',
        ).writeAsStringSync(jsonEncode([1, 2]));
      });

      final stored = await store.readAll();

      expect(stored, isEmpty);
      expect(store.lastDiscarded.single.reason, 'registro corrompido');
    });
  });

  test('requisicao de leitura falhando em todas as tentativas usa sempre o '
      'mesmo codigo e o historico mostra cada uma', () async {
    final server = FaultServer()
      ..on(
        'GET',
        _route,
        (request, _) => DioException(
          requestOptions: request,
          type: DioExceptionType.receiveTimeout,
        ),
      );
    final client = faultClient(server);

    await expectLater(
      client.dio.get<dynamic>(_route),
      throwsA(isA<DioException>()),
    );

    final ids = server.seen.map((request) => request.requestId).toSet();
    expect(server.seen, hasLength(3));
    expect(ids, hasLength(1));
    final entries = ApiFailureLog.instance.entries.value;
    expect(entries, hasLength(3));
    expect(entries.map((entry) => entry.failure.code).toSet(), {'ETEMPO'});
  });
}
