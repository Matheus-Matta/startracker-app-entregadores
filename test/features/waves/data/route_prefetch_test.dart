import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_delivery_server.dart';

/// O servidor roteiriza sozinho ao fim da retirada; o app precisa guardar a
/// rota liberada antes de o sinal cair, sem o entregador abrir a carga.
void main() {
  late Directory directory;
  late FakeDeliveryServer server;
  late TestDevice app;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('route_prefetch');
    server = FakeDeliveryServer()..routeStatus = 'released';
    app = TestDevice(server, directory);
    await app.boot();
  });

  tearDown(() async {
    app.dispose();
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  });

  test('lista de cargas baixa a rota liberada para abrir sem sinal', () async {
    expect(await app.routes.storedRoute(20), isNull);

    await app.waves.getWaves(page: 1, refresh: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    server.online = false;

    final stored = await app.routes.storedRoute(20);
    expect(stored, isNotNull);
    expect(stored!.stops, isNotEmpty);
    // E a rota começa sem sinal, salva no aparelho.
    await app.waves.startRoute(20);
    expect((await app.routes.storedRoute(20))!.status, 'started');
  });

  test('rota encerrada não é baixada pela lista', () async {
    server.routeStatus = 'completed';
    await app.waves.getWaves(page: 1, refresh: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await app.routes.storedRoute(20), isNull);
  });

  test(
    'rota em andamento também é baixada (outro aparelho, app reinstalado)',
    () async {
      server.routeStatus = 'started';
      await app.waves.getWaves(page: 1, refresh: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      server.online = false;
      expect((await app.routes.storedRoute(20))?.stops, isNotEmpty);
    },
  );

  test('rota alterada no portal é baixada de novo pela lista', () async {
    await app.waves.getWaves(page: 1, refresh: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect((await app.routes.storedRoute(20))!.stops, hasLength(2));

    // Operador tirou uma parada da rota.
    server
      ..stops.remove(32)
      ..routeUpdatedAt = '2026-11-16T10:00:00Z';
    await app.waves.getWaves(page: 1, refresh: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    server.online = false;
    expect((await app.routes.storedRoute(20))!.stops, hasLength(1));
  });
}
