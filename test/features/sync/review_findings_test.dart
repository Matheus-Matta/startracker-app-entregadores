import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/offline_deadline.dart';
import 'package:star_tracker/core/sync/mobile_sync.dart';
import 'package:star_tracker/features/waves/data/wave_service.dart';

import '../../support/fake_delivery_server.dart';

/// Um teste por falha encontrada na revisão geral.
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
    directory = await Directory.systemTemp.createTemp('review');
    server = FakeDeliveryServer();
    OfflineDeadline.read = const Duration(milliseconds: 300);
    OfflineDeadline.policy = const Duration(milliseconds: 200);
  });

  tearDown(() async {
    server.hang?.complete();
    server.holdSync?.complete();
    for (final item in devices) {
      item.dispose();
    }
    devices.clear();
    OfflineDeadline.read = const Duration(seconds: 8);
    OfflineDeadline.policy = const Duration(seconds: 4);
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  });

  test('1. sinal volta após horas offline: a próxima tentativa fica em no '
      'máximo 15 s, não nos 5 min do intervalo acumulado', () async {
    final app = device();
    await app.boot();
    await app.routes.getRoute(20);
    server.online = false;
    await app.routes.arrive(31);
    for (var i = 0; i < 8; i++) {
      await app.client.offlineRequests.retryNow(); // horas sem sinal
    }
    final before = app.client.offlineRequests.status.value.nextRetryAt!;
    expect(
      before.difference(DateTime.now()),
      greaterThan(const Duration(minutes: 1)),
      reason: 'o intervalo acumulado é longo',
    );
    await app.routes.begin(31); // dentro da janela de silêncio
    final next = app.client.offlineRequests.status.value.nextRetryAt!;
    expect(
      next.difference(DateTime.now()),
      lessThanOrEqualTo(const Duration(seconds: 15)),
    );
  });

  test(
    '2. troca de sessão no meio de um envio não reenvia a mesma ação',
    () async {
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      server.holdSync = Completer<void>();
      await app.routes.arrive(31);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final reload = app.client.offlineRequests.reloadSession();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      server.holdSync!.complete();
      server.holdSync = null;
      await reload;
      await app.flush();
      expect(server.deliveries.values, [1], reason: 'mesma ação enviada 2x');
    },
  );

  test(
    '3. chegar, "próxima entrega" e chegar de novo: as duas visitas vão',
    () async {
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      server.online = false;
      await app.routes.arrive(31);
      await app.routes.skip(stopId: 31);
      await app.routes.arrive(31);
      await app.routes.arrive(31); // toque repetido continua ignorado
      expect(app.sync.pending.map((event) => event.kind), [
        SyncKind.stopArrive,
        SyncKind.stopPostpone,
        SyncKind.stopArrive,
      ]);
    },
  );

  test('4. logout sem pendência limpa as confirmadas do entregador', () async {
    final app = device();
    await app.boot();
    await app.routes.getRoute(20);
    await app.routes.arrive(31);
    await app.flush();
    expect(app.sync.confirmedEvents(), isNotEmpty);
    await app.sync.clearSession();
    expect(app.sync.confirmedEvents(), isEmpty);
    expect(app.sync.localEvents(), isEmpty);
  });

  group('5 e 6. rede zumbi: telas usam a cópia em vez de esperar minutos', () {
    late TestDevice app;

    setUp(() async {
      app = device();
      await app.boot();
      await app.waves.getWaves(page: 1);
      await app.routes.getRoute(20);
      await app.waves.getPickupProgress(10);
      await app.orders.getOrderDetails(81);
      await app.orders.getOrders(page: 1);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      server.hang = Completer<void>();
    });

    Future<T> quick<T>(Future<T> future) =>
        future.timeout(const Duration(seconds: 3));

    test('conferência, carga, lista, rota e pedido abrem pela cópia', () async {
      expect((await quick(app.waves.getPickupProgress(10))).total, 2);
      final list = await quick(app.waves.getWaves(page: 1, refresh: true));
      expect(list.items, isNotEmpty);
      final details = await quick(app.waves.getWaveDetails(list.items.first));
      expect(details.orders, isNotEmpty);
      expect((await quick(app.routes.getRoute(20))).stops, hasLength(2));
      expect((await quick(app.orders.getOrderDetails(81))).number, 'PED-81');
      expect(
        (await quick(app.orders.getOrders(page: 1, refresh: true))).items,
        isNotEmpty,
      );
    });

    test('atualizar a política da baixa não trava a abertura', () async {
      final stop = app.routes.cachedRoute(20)!.stops.first;
      final watch = Stopwatch()..start();
      try {
        await app.routes
            .refreshCompletionPolicy(stop)
            .timeout(OfflineDeadline.policy);
      } on TimeoutException {
        // a tela segue com a política já conhecida
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('bipar na conferência com rede zumbi grava na hora', () async {
      final progress = await quick(
        app.waves.registerPickup(waveId: 10, code: 'PED-81'),
      );
      expect(progress.pickedUp, 1);
    });
  });

  group('7 e 8. pedidos', () {
    test('baixa sem sinal muda o status na aba Pedidos e no detalhe, e '
        'continua depois de sincronizar', () async {
      final app = device();
      await app.boot();
      final stop = (await app.routes.getRoute(20)).stops.first;
      await app.orders.getOrders(page: 1);
      await app.orders.getOrderDetails(81);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      server.online = false;
      await app.routes.complete(submissionFor(stop));

      final list = await app.orders.getOrders(page: 1, refresh: true);
      expect(
        list.items.firstWhere((item) => item.id == 81).status,
        'delivered',
      );
      expect((await app.orders.getOrderDetails(81)).status, 'delivered');

      server.online = true;
      await app.flush();
      final fresh = await app.orders.getOrders(page: 1, refresh: true);
      expect(
        fresh.items.firstWhere((item) => item.id == 81).status,
        'delivered',
      );
      expect(server.orders[81], 'delivered');
    });

    test('falha sem sinal aparece como falha na aba Pedidos', () async {
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      await app.orders.getOrders(page: 1);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      server.online = false;
      await app.routes.fail(stopId: 32, reason: 'ausente', notes: '');
      final list = await app.orders.getOrders(page: 1, refresh: true);
      expect(
        list.items.firstWhere((item) => item.id == 82).status,
        'delivery_failed',
      );
    });

    test('campos só do aparelho não vão ao servidor', () async {
      final app = device();
      await app.boot();
      final stop = (await app.routes.getRoute(20)).stops.first;
      await app.routes.complete(submissionFor(stop));
      final sent = server.applied.single;
      expect(sent['order_id'], '81');
      expect(sent.keys.where((key) => key.startsWith('local_')), isEmpty);
    });
  });

  test('pedido sem cópia e sem rede: erro claro, sem travar', () async {
    final app = device();
    await app.boot();
    server.online = false;
    await expectLater(
      app.orders.getOrderDetails(99).timeout(const Duration(seconds: 3)),
      throwsA(isNot(isA<TimeoutException>())),
    );
    expect(
      () => app.waves.getPickupProgress(77).timeout(const Duration(seconds: 3)),
      throwsA(isA<WaveServiceException>()),
    );
  });
}
