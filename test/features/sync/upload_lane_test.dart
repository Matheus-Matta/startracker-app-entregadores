import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/sync/mobile_sync.dart';

import '../../support/fake_delivery_server.dart';

/// Fotos da baixa subindo devagar enquanto o entregador segue a rota.
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
    directory = await Directory.systemTemp.createTemp('upload_lane');
    server = FakeDeliveryServer();
  });

  tearDown(() async {
    final uploads = server.holdUploads;
    if (uploads != null && !uploads.isCompleted) uploads.complete();
    for (final item in devices) {
      item.dispose();
    }
    devices.clear();
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> eventually(bool Function() condition) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  test('falha confirmada antes da baixa com foto: a tela não volta atrás '
      'enquanto as fotos sobem', () async {
    final app = device();
    await app.boot();
    final route = await app.routes.getRoute(20);
    await app.waves.getWaves(page: 1);
    final first = route.stops.first;
    final second = route.stops.last;

    server.online = false;
    await app.routes.complete(submissionFor(first));
    await app.routes.fail(stopId: second.stopId, reason: 'ausente', notes: '');

    server
      ..holdUploads = Completer<void>()
      ..online = true;
    unawaited(app.client.offlineRequests.retryNow(manual: true));
    await eventually(
      () => server.applied.any((fields) => fields['kind'] == SyncKind.stopFail),
    );
    expect(
      server.applied.map((fields) => fields['kind']),
      isNot(contains(SyncKind.stopComplete)),
      reason: 'a baixa com foto ainda está subindo',
    );

    // O servidor ainda vê a rota em andamento; o aparelho não volta atrás.
    final fresh = await app.routes.getRoute(20);
    expect(fresh.stops.map((stop) => stop.status), ['completed', 'failed']);
    expect(fresh.status, 'partially_completed');
    final waves = await app.waves.getWaves(page: 1, refresh: true);
    expect(waves.items.single.status, 'partially_completed');

    server.holdUploads!.complete();
    await app.flush();
    expect(app.client.offlineRequests.pendingCount, 0);
    expect(server.photosReceived, 2);
    expect(server.routeStatus, 'partially_completed');
    final settled = await app.routes.getRoute(20);
    expect(settled.status, 'partially_completed');
    expect(settled.stops.map((stop) => stop.status), ['completed', 'failed']);
  });
}
