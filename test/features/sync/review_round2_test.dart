import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/network/offline_deadline.dart';
import 'package:star_tracker/core/storage/session_storage.dart';
import 'package:star_tracker/features/waves/data/active_route_service.dart';
import 'package:star_tracker/features/waves/data/wave_service.dart';

import '../../support/fake_delivery_server.dart';

/// Segunda rodada da revisão: um teste por falha encontrada.
void main() {
  late Directory directory;
  late FakeDeliveryServer server;
  final devices = <TestDevice>[];

  TestDevice device() {
    final created = TestDevice(server, directory);
    devices.add(created);
    return created;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('review2');
    server = FakeDeliveryServer();
  });

  tearDown(() async {
    server.hang?.complete();
    server.holdSync?.complete();
    for (final item in devices) {
      item.dispose();
    }
    devices.clear();
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  });

  test('troca de sessão no meio de um envio que falha: a ação continua na '
      'fila (não some até o app reabrir)', () async {
    final app = device();
    await app.boot();
    await app.routes.getRoute(20);
    server.holdSync = Completer<void>();
    await app.routes.arrive(31);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final reload = app.client.offlineRequests.reloadSession();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    server.syncFaults.add((
      fault: (_) => DioException.connectionError(
        requestOptions: RequestOptions(),
        reason: 'caiu',
      ),
      applyFirst: false,
    ));
    server.holdSync!.complete();
    server.holdSync = null;
    await reload;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(app.client.offlineRequests.pendingCount, 1);
    await app.flush();
    expect(server.timesApplied('stop.arrive'), 1);
  });

  test(
    'ação feita durante um envio segue logo depois, sem esperar o timer',
    () async {
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      server.holdSync = Completer<void>();
      await app.routes.arrive(31);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await app.routes.arrive(32);
      server.holdSync!.complete();
      server.holdSync = null;
      // Sem o timer (1º intervalo de 5 s): bem antes disso a fila esvazia.
      for (var i = 0; i < 300; i++) {
        if (app.client.offlineRequests.pendingCount == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(app.client.offlineRequests.pendingCount, 0);
      expect(server.timesApplied('stop.arrive'), 2);
    },
  );

  test('aba Pedidos: duas atualizações seguidas com rede zumbi abrem pela '
      'cópia, com o status local', () async {
    OfflineDeadline.read = const Duration(milliseconds: 300);
    addTearDown(() => OfflineDeadline.read = const Duration(seconds: 8));
    final app = device();
    await app.boot();
    await app.routes.getRoute(20);
    await app.orders.getOrders(page: 1);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    server.online = false;
    await app.routes.fail(stopId: 32, reason: 'ausente', notes: '');
    server
      ..online = true
      ..hang = Completer<void>();
    final both = await Future.wait([
      app.orders.getOrders(page: 1, refresh: true),
      app.orders.getOrders(page: 1, refresh: true),
    ]).timeout(const Duration(seconds: 3));
    for (final page in both) {
      expect(
        page.items.firstWhere((item) => item.id == 82).status,
        'delivery_failed',
      );
    }
  });

  group('uma rota em andamento por vez (regra do servidor)', () {
    test(
      'com outra rota iniciada no servidor, recusa como o servidor',
      () async {
        server
          ..routeStatus = 'released'
          ..extraRoutes[21] = 'started';
        final app = device();
        await app.boot();
        await expectLater(
          app.routes.startRoute(20),
          throwsA(
            isA<ActiveRouteException>().having(
              (error) => error.message,
              'message',
              contains('rota em andamento'),
            ),
          ),
        );
        expect(app.sync.pending, isEmpty);
      },
    );

    test(
      'sem sinal, com outra rota iniciada no aparelho, também recusa',
      () async {
        server
          ..routeStatus = 'released'
          ..extraRoutes[21] = 'released';
        final app = device();
        await app.boot();
        await app.waves.getWaves(page: 1);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        server.online = false;
        await app.routes.startRoute(21);
        await expectLater(
          app.waves.startRoute(20),
          throwsA(isA<WaveServiceException>()),
        );
      },
    );

    test('cópia antiga da outra rota ainda "liberada" não desmente o '
        'servidor dizendo que ela está em andamento', () async {
      server
        ..routeStatus = 'released'
        ..extraRoutes[21] = 'released';
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Iniciada no portal/outro aparelho depois da cópia.
      server.routeStatus = 'started';
      await expectLater(
        app.routes.startRoute(21),
        throwsA(isA<ActiveRouteException>()),
      );
      expect(app.sync.pending, isEmpty);
    });

    test('a rota anterior terminada no aparelho libera a próxima', () async {
      server.extraRoutes[21] = 'released';
      final app = device();
      await app.boot();
      final route = await app.routes.getRoute(20);
      server.online = false;
      for (final stop in route.stops) {
        await app.routes.complete(submissionFor(stop, photos: 0));
      }
      await app.routes.startRoute(21);
      expect(
        app.sync.pending.where((event) => event.kind == 'route.start'),
        hasLength(1),
      );
    });
  });

  test('token vencido e renovação sem sinal: não pede login, trata como '
      'sem rede', () async {
    final session = _RefreshableSession();
    final refresh = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = _OfflineAdapter();
    final client = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: session,
      refreshClient: refresh,
    )..readRetryDelays = const [];
    client.dio.httpClientAdapter = _StatusAdapter(401);
    Object? caught;
    try {
      await client.dio.get<dynamic>('/api/v1/delivery/rotas/');
    } on DioException catch (error) {
      caught = error;
    }
    expect(caught, isA<DioException>());
    final error = caught! as DioException;
    expect(error.response?.statusCode, isNot(401));
    expect(
      OfflineRequestQueueProbe.isNetwork(error),
      isTrue,
      reason: 'a fila e as telas tratam como sem rede, não sessão expirada',
    );
    expect(await session.readRefreshToken(), 'refresh-ok');
    client.offlineRequests.dispose();
  });
}

class OfflineRequestQueueProbe {
  static bool isNetwork(DioException error) =>
      error.type == DioExceptionType.connectionError ||
      error.type == DioExceptionType.connectionTimeout ||
      error.error is IOException;
}

class _RefreshableSession extends SessionStorage {
  @override
  Future<String?> readToken() async => 'access-vencido';

  @override
  Future<String?> readRefreshToken() async => 'refresh-ok';

  @override
  Future<void> clear() async => fail('não pode apagar a sessão sem rede');
}

class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(
    requestOptions: options,
    reason: 'Network is unreachable',
  );

  @override
  void close({bool force = false}) {}
}

class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.status);
  final int status;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{"detail":"expirado"}',
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}
