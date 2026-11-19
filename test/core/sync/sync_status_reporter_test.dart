import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_failure.dart';
import 'package:star_tracker/core/sync/sync_status_reporter.dart';

import '../../support/fake_delivery_server.dart';

void main() {
  late Directory directory;
  late FakeDeliveryServer server;
  late TestDevice app;
  late SyncStatusReporter reporter;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('reporter');
    server = FakeDeliveryServer();
    app = TestDevice(server, directory);
    await app.boot();
    await app.routes.getRoute(20);
    reporter = SyncStatusReporter(
      app.client,
      minInterval: const Duration(milliseconds: 300),
      debounce: const Duration(milliseconds: 20),
      heartbeat: const Duration(hours: 1),
      appVersion: () async => '9.9.9+1',
    )..start();
  });

  tearDown(() async {
    reporter.stop();
    app.dispose();
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> settle([int ms = 120]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  test('sem nada pendente nunca, não informa à toa', () async {
    await settle();
    expect(server.statusReports, isEmpty);
  });

  test(
    'informa pendências com a mais antiga e, ao esvaziar, avisa na hora',
    () async {
      server.online = false;
      await app.routes.arrive(31);
      await app.routes.arrive(32);
      server.online = true; // a fila segue sem sinal até a próxima tentativa
      await reporter.report(force: true);
      // Pode já haver um envio automático em andamento; ele é que informa.
      await settle(400);
      final pending = server.statusReports.last;
      expect(pending['pending_count'], 2);
      expect(pending['oldest_pending_at'], isNotNull);
      expect(pending['app_version'], '9.9.9+1');

      await app.flush();
      await settle(400);
      final cleared = server.statusReports.last;
      expect(cleared['pending_count'], 0);
      expect(cleared['last_delivered_at'], isNotNull);
    },
  );

  test('recusas vão com o motivo', () async {
    server.syncFaults.add((
      fault: (_) => FakeDeliveryServer.status(400, ['Foto corrompida.']),
      applyFirst: false,
    ));
    await app.routes.arrive(31);
    await app.flush();
    await settle(400);
    final report = server.statusReports.last;
    expect(report['rejected_count'], 1);
    expect((report['rejected'] as List).single['reason'], contains('Foto'));
  });

  test('muitas mudanças seguidas viram poucos envios', () async {
    server.online = false;
    for (final stop in [31, 32]) {
      await app.routes.arrive(stop);
      await app.routes.begin(stop);
    }
    server.online = true;
    await settle(1000);
    expect(server.statusReports.length, lessThanOrEqualTo(2));
    expect(server.statusReports.last['pending_count'], 4);
  });

  test('"fila vazia" que não chegou é reenviado no sinal periódico', () async {
    reporter.stop();
    final beating = SyncStatusReporter(
      app.client,
      minInterval: Duration.zero,
      debounce: const Duration(milliseconds: 20),
      heartbeat: const Duration(milliseconds: 200),
      appVersion: () async => '9.9.9+1',
    )..start();
    addTearDown(beating.stop);
    server.online = false;
    await app.routes.arrive(31);
    server.online = true;
    await beating.report(force: true);
    expect(server.statusReports.last['pending_count'], 1);
    server.statusDown = true;
    await app.flush();
    await settle(100);
    server.statusDown = false;
    await settle(500);
    expect(server.statusReports.last['pending_count'], 0);
  });

  test('sem sinal: falha ao informar não vai para o histórico', () async {
    ApiFailureLog.instance.clear();
    server.online = false;
    await app.routes.arrive(31);
    expect(await reporter.report(force: true), isFalse);
    expect(
      ApiFailureLog.instance.entries.value.where(
        (entry) =>
            entry.failure.detail.contains('situacao') ||
            entry.failure.stage.contains('Carregar'),
      ),
      isEmpty,
    );
  });
}
