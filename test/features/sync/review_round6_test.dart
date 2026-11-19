import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/offline_deadline.dart';
import 'package:star_tracker/features/waves/data/route_snapshot_store.dart';

import '../../support/fake_delivery_server.dart';

/// Sexta rodada da revisão: busca de pedidos na rua.
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
    directory = await Directory.systemTemp.createTemp('review6');
    server = FakeDeliveryServer();
  });

  tearDown(() async {
    server.hang?.complete();
    for (final item in devices) {
      item.dispose();
    }
    devices.clear();
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  });

  test('confirmação lida do disco não sobrescreve a leitura mais nova da '
      'rota (parada cancelada no portal voltava ao mapa)', () async {
    final store = _GatedReads();
    final app = TestDevice(
      server,
      directory,
      routeSnapshots: (folder) {
        store.base = folder;
        return store;
      },
    );
    devices.add(app);
    await app.boot();
    await app.routes.getRoute(20);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // A confirmação da chegada lê a cópia antiga e fica parada aqui.
    store.gate = Completer<void>();
    await app.routes.arrive(31);
    await app.flush();
    // Enquanto isso o portal cancela a outra parada e o mapa relê a rota.
    server.stops[32] = 'cancelled';
    final fresh = await app.routes.getRoute(20);
    expect(fresh.cancelledStops.map((stop) => stop.stopId), contains(32));

    store.gate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final shown = app.routes.cachedRoute(20)!;
    expect(shown.cancelledStops.map((stop) => stop.stopId), contains(32));
    expect(
      shown.stops.firstWhere((stop) => stop.stopId == 31).status,
      'arrived',
    );
  });

  test('busca pelo número do pedido sem sinal usa a lista salva, com o '
      'status do aparelho', () async {
    final app = device();
    await app.boot();
    await app.routes.getRoute(20);
    await app.orders.getOrders(page: 1);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    server.online = false;
    await app.routes.fail(stopId: 32, reason: 'ausente', notes: '');

    final found = await app.orders.getOrders(
      page: 1,
      search: 'ped-82',
      refresh: true,
    );
    expect(found.items.map((item) => item.id), [82]);
    expect(found.items.single.status, 'delivery_failed');
  });

  test('busca com rede zumbi não espera os timeouts da conexão', () async {
    OfflineDeadline.read = const Duration(milliseconds: 200);
    addTearDown(() => OfflineDeadline.read = const Duration(seconds: 8));
    final app = device();
    await app.boot();
    await app.orders.getOrders(page: 1);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    server.hang = Completer<void>();

    final found = await app.orders
        .getOrders(page: 1, search: 'ped-81', refresh: true)
        .timeout(const Duration(seconds: 3));
    expect(found.items.map((item) => item.id), [81]);
  });

  test('"Ver pedido" sem sinal abre pedido nunca aberto antes, pela lista '
      'salva, com o status do aparelho', () async {
    final app = device();
    await app.boot();
    await app.routes.getRoute(20);
    await app.orders.getOrders(page: 1);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    server.online = false;
    await app.routes.fail(stopId: 32, reason: 'ausente', notes: '');

    final details = await app.orders.getOrderDetails(82);
    expect(details.id, 82);
    expect(details.status, 'delivery_failed');
  });

  test('"Ver pedido" do mapa sem sinal e sem nunca ter aberto a aba Pedidos: '
      'usa a rota salva', () async {
    final app = device();
    await app.boot();
    final route = await app.routes.getRoute(20);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    server.online = false;
    final orderId = route.stops.first.orderId;

    final details = await app.orders.getOrderDetails(orderId);
    expect(details.id, orderId);
    expect(details.number, route.stops.first.orderNumber);
  });
}

/// Cópia de rota cuja leitura do disco pode ser segurada depois de feita
/// (como um disco lento enquanto a rede responde).
class _GatedReads extends RouteSnapshotStore {
  _GatedReads() : super(baseDirectory: () => _base!());

  static Future<Directory> Function()? _base;
  set base(Future<Directory> Function() value) => _base = value;
  Completer<void>? gate;

  @override
  Future<Map<String, dynamic>?> read(int routeId) async {
    final data = await super.read(routeId);
    final pending = gate;
    if (pending != null && !pending.isCompleted) await pending.future;
    return data;
  }
}
