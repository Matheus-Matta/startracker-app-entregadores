import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:star_tracker/features/delivery/data/active_wave_service.dart';
import 'package:star_tracker/features/waves/data/route_snapshot_store.dart';

import '../../../support/fake_delivery_server.dart';

/// Da conferência à rota: o servidor roteiriza sozinho quando recebe a
/// última leitura. A tela da carga, aberta antes disso, não conhecia a rota e
/// "Começar a rota" dizia que não havia rota até voltar à lista.
void main() {
  late Directory directory;
  late FakeDeliveryServer server;
  late TestDevice app;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pickup_to_route');
    server = FakeDeliveryServer()
      ..routeExists = false
      ..waveStatus = 'ready';
    app = TestDevice(server, directory);
    await app.boot();
  });

  tearDown(() async {
    app.dispose();
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  });

  test('detalhe aberto antes da rota passa a trazer a rota criada', () async {
    final item = (await app.waves.getWaves(
      page: 1,
      refresh: true,
    )).items.single;
    expect(item.routeId, isNull);
    expect((await app.waves.getWaveDetails(item)).routeId, isNull);

    // Última leitura chegou: o servidor roteirizou e liberou.
    server
      ..routeExists = true
      ..waveStatus = 'released'
      ..routeStatus = 'released';

    final details = await app.waves.getWaveDetails(item);
    expect(details.routeId, 20);
    expect(details.status, 'released');
    expect(details.orders.map((order) => order.stopId), containsAll([31, 32]));
    expect((await app.waves.findWaveRoute(item))?.routeId, 20);
  });

  test('rota cancelada não conta como rota da carga', () async {
    final item = (await app.waves.getWaves(
      page: 1,
      refresh: true,
    )).items.single;
    server
      ..routeExists = true
      ..routeStatus = 'cancelled';
    expect(await app.waves.findWaveRoute(item), isNull);
  });

  test('concluir a retirada envia as leituras feitas sem sinal', () async {
    await app.waves.getPickupProgress(10);
    server.online = false;
    await app.waves.registerPickup(waveId: 10, code: 'PED-81');
    await app.waves.registerPickup(waveId: 10, code: 'PED-82');

    // Sem sinal: devolve logo, com as leituras guardadas na fila.
    final offline = await app.waves.sendPickup(
      10,
      timeout: const Duration(seconds: 2),
    );
    expect(offline, isFalse);
    expect(app.client.offlineRequests.pendingCount, 2);

    server.online = true;
    expect(await app.waves.sendPickup(10), isTrue);
    expect(server.pickupCodes[81]!['PED-81'], isNotNull);
    expect(server.pickupCodes[82]!['PED-82'], isNotNull);
  });

  test(
    'lista baixa a conferência da carga recebida para usar sem sinal',
    () async {
      await app.waves.getWaves(page: 1, refresh: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      server.online = false;

      // App reaberto pelo sistema, sem sinal: a cópia vem do disco.
      final reopened = TestDevice(server, directory);
      await reopened.boot();
      final progress = await reopened.waves.getPickupProgress(10);
      expect(progress.total, 2);
      expect(progress.orders.map((order) => order.orderNumber), [
        'PED-81',
        'PED-82',
      ]);
      reopened.dispose();
    },
  );

  test('pedido da carga ainda sem rota abre sem sinal', () async {
    final item = (await app.waves.getWaves(
      page: 1,
      refresh: true,
    )).items.single;
    await app.waves.getWaveDetails(item);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    server.online = false;

    final order = await app.orders.getOrderDetails(81);
    expect(order.number, 'PED-81');
  });

  test(
    'rota refeita pelo operador: o detalhe passa para a rota nova',
    () async {
      server
        ..routeExists = true
        ..waveStatus = 'released'
        ..routeStatus = 'started';
      final item = (await app.waves.getWaves(
        page: 1,
        refresh: true,
      )).items.single;
      expect(item.routeId, 20);

      server.replacementRoute = 21;
      final details = await app.waves.getWaveDetails(item);
      expect(details.routeId, 21);
      expect((await app.waves.findWaveRoute(item))?.routeId, 21);
    },
  );

  test('sem sinal, a tela aberta antes da rota acha a rota salva', () async {
    final item = (await app.waves.getWaves(
      page: 1,
      refresh: true,
    )).items.single;
    expect(item.routeId, isNull);
    server
      ..routeExists = true
      ..waveStatus = 'released'
      ..routeStatus = 'released';
    await app.waves.getWaves(page: 1, refresh: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    server.online = false;

    final details = await app.waves.getWaveDetails(item);
    expect(details.routeId, 20);
    expect(details.orders.map((order) => order.stopId), containsAll([31, 32]));
  });

  test(
    'tela inicial baixa a rota da carga ativa para abrir sem sinal',
    () async {
      server
        ..routeExists = true
        ..routeStatus = 'started';
      final activeWave = ActiveWaveService(
        app.client,
        activeRoutes: app.routes,
        store: RouteSnapshotStore(
          baseDirectory: () async => Directory('${directory.path}/active'),
          folder: 'a',
          prefix: 'routes',
        ),
      );
      expect((await activeWave.getActiveWave())?.routeId, 20);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      server.online = false;
      expect((await app.routes.storedRoute(20))?.stops, isNotEmpty);
    },
  );
}
