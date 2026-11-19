import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/network/offline_deadline.dart';
import 'package:star_tracker/core/storage/session_storage.dart';
import 'package:star_tracker/core/sync/mobile_sync.dart';
import 'package:star_tracker/features/delivery/data/active_wave_service.dart';
import 'package:star_tracker/features/waves/data/active_route_service.dart';
import 'package:star_tracker/features/waves/data/route_snapshot_store.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('active_wave');
  });

  tearDown(() {
    try {
      directory.deleteSync(recursive: true);
    } catch (_) {}
  });

  ActiveWaveService service(HttpClientAdapter adapter, {String? storedStatus}) {
    final client = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: _Session(),
    )..readRetryDelays = const [];
    client.dio.httpClientAdapter = adapter;
    addTearDown(client.offlineRequests.dispose);
    RouteSnapshotStore temp(String folder) => RouteSnapshotStore(
      baseDirectory: () async => directory,
      folder: folder,
      prefix: folder,
    );
    return ActiveWaveService(
      client,
      activeRoutes: storedStatus == null
          ? null
          : _StoredRoutes(
              client,
              storedStatus,
              snapshotStore: temp('routes'),
              sync: MobileSync(client, confirmedStore: temp('confirmed')),
            ),
      store: RouteSnapshotStore(
        baseDirectory: () async => directory,
        folder: 'active_wave',
        prefix: 'routes',
      ),
    );
  }

  test('app reaberto sem sinal ainda mostra a carga em andamento', () async {
    final online = service(_RoutesAdapter());
    expect((await online.getActiveWave())?.routeId, 20);
    // A cópia é gravada em segundo plano.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final reopened = service(_OfflineAdapter());
    final wave = await reopened.getActiveWave();
    expect(wave?.routeId, 20);
    expect(wave?.status, 'started');
  });

  test(
    'rede zumbi: a tela inicial não espera os timeouts da conexão',
    () async {
      OfflineDeadline.read = const Duration(milliseconds: 200);
      addTearDown(() => OfflineDeadline.read = const Duration(seconds: 8));
      await service(_RoutesAdapter()).getActiveWave();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final hang = Completer<void>();
      addTearDown(hang.complete);
      final wave = await service(
        _HangingAdapter(hang.future),
      ).getActiveWave().timeout(const Duration(seconds: 2));
      expect(wave?.routeId, 20);
    },
  );

  test('cópia antiga da rota ainda "planejada" não esconde a carga que o '
      'servidor diz estar ativa', () async {
    final wave = await service(
      _RoutesAdapter(),
      storedStatus: 'planned',
    ).getActiveWave();
    expect(wave?.routeId, 20);
  });

  test(
    'rota fechada no aparelho (baixa ainda não enviada) sai da tela',
    () async {
      final wave = await service(
        _RoutesAdapter(),
        storedStatus: 'completed',
      ).getActiveWave();
      expect(wave, isNull);
    },
  );

  test('sem cópia e sem sinal continua avisando o erro', () async {
    await expectLater(
      service(_OfflineAdapter()).getActiveWave(),
      throwsA(isA<DioException>()),
    );
  });
}

class _StoredRoutes extends ActiveRouteService {
  _StoredRoutes(
    super.apiClient,
    this.status, {
    super.snapshotStore,
    super.sync,
  });

  final String status;

  @override
  Future<ActiveRoute?> storedRoute(int routeId) async => ActiveRoute(
    routeId: routeId,
    waveId: 3,
    routeNumber: 'W3-S1',
    status: status,
    path: const [],
    deliveryWaypoints: const {},
    warehouse: null,
    stops: const [],
  );
}

class _Session extends SessionStorage {
  @override
  Future<String?> readToken() async => 'token';
}

class _RoutesAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode({
      'next': null,
      'results': [
        {
          'id': 20,
          'wave': 3,
          'status': 'started',
          'route_number': 'W3-S1',
          'created_at': '2026-11-18T08:00:00Z',
        },
      ],
    }),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

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
    reason: 'Network is unreachable',
  );

  @override
  void close({bool force = false}) {}
}

class _HangingAdapter implements HttpClientAdapter {
  _HangingAdapter(this.until);

  final Future<void> until;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await until;
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'zumbi',
    );
  }

  @override
  void close({bool force = false}) {}
}
