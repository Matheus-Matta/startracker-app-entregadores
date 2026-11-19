import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/features/waves/data/route_snapshot_store.dart';

import '../../support/fake_delivery_server.dart';

/// Registro das ações confirmadas: uma linha por confirmação (antes o
/// arquivo inteiro era regravado a cada uma e o envio de um dia sem sinal
/// gastava ~20 s só nisso).
void main() {
  late Directory directory;
  late FakeDeliveryServer server;
  final devices = <TestDevice>[];

  TestDevice device() {
    final created = TestDevice(server, directory);
    devices.add(created);
    return created;
  }

  /// O mesmo arquivo que o [TestDevice] usa para as confirmadas.
  RouteSnapshotStore confirmedStore() => RouteSnapshotStore(
    baseDirectory: () async =>
        Directory('${directory.path}${Platform.pathSeparator}confirmed'),
    folder: 'c',
    prefix: 'events',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('confirmed_log');
    server = FakeDeliveryServer();
  });

  tearDown(() async {
    for (final item in devices) {
      item.dispose();
    }
    devices.clear();
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  });

  test('confirmadas sobrevivem ao app reaberto', () async {
    final app = device();
    await app.boot();
    await app.routes.getRoute(20);
    await app.routes.arrive(31);
    await app.flush();
    expect(app.sync.confirmedEvents(), hasLength(1));

    final reopened = device();
    await reopened.boot();
    expect(reopened.sync.confirmedEvents().single.kind, 'stop.arrive');
  });

  test('app morto no meio da gravação: a linha cortada é ignorada e as '
      'outras continuam valendo', () async {
    final store = confirmedStore();
    await store.append(0, {'a': 1});
    await store.append(0, {'b': 2});
    final log = File(
      '${directory.path}${Platform.pathSeparator}confirmed'
      '${Platform.pathSeparator}c${Platform.pathSeparator}events_0.log',
    );
    await log.writeAsString('{"cortad', mode: FileMode.append);
    expect(await store.readLog(0), [
      {'a': 1},
      {'b': 2},
    ]);
  });

  test(
    'formato antigo (lista inteira num JSON) é convertido na abertura',
    () async {
      final now = DateTime.now().toUtc().toIso8601String();
      await confirmedStore().save(0, {
        'items': [
          {
            'kind': 'stop.arrive',
            'fields': {'stop_id': 31},
            'occurred_at': now,
            'confirmed_at': now,
            'response': {
              'stop': {'id': 31, 'status': 'arrived'},
            },
          },
        ],
      });
      final app = device();
      await app.boot();
      expect(app.sync.confirmedEvents().single.intField('stop_id'), 31);
      expect(await confirmedStore().read(0), isNull);
      expect(await confirmedStore().readLog(0), hasLength(1));

      final reopened = device();
      await reopened.boot();
      expect(reopened.sync.confirmedEvents(), hasLength(1));
    },
  );

  test('confirmadas vencidas saem do registro na compactação', () async {
    final old = DateTime.now()
        .subtract(const Duration(days: 3))
        .toUtc()
        .toIso8601String();
    final store = confirmedStore();
    for (var i = 0; i < 250; i++) {
      await store.append(0, {
        'kind': 'stop.arrive',
        'fields': {'stop_id': 31},
        'occurred_at': old,
        'confirmed_at': old,
        'response': const <String, dynamic>{},
      });
    }
    final app = device();
    await app.boot();
    expect(app.sync.confirmedEvents(), isEmpty);
    expect(await store.readLog(0), isEmpty);
  });
}
