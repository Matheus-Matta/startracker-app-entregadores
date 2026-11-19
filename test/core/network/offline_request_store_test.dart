import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/offline_request_store.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_store');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('releitura da fila no meio da gravação de uma baixa com fotos não a '
      'apaga como "gravação interrompida"', () async {
    final store = OfflineRequestStore(baseDirectory: () async => tempDir);
    final photo = Uint8List(4 * 1024 * 1024);
    final saving = store.save(
      StoredOfflineRequest(
        id: 'baixa-1',
        resourceKey: 'stop:31',
        description: 'Finalizar entrega',
        idempotencyKey: 'baixa-1',
        createdAt: DateTime.now(),
        request: PersistedOfflineRequest(
          type: 'mobile_sync.event',
          payload: const {'kind': 'stop.complete'},
          files: {for (var i = 0; i < 6; i++) 'photo_$i': photo},
        ),
      ),
    );
    final folder = Directory(
      '${tempDir.path}${Platform.pathSeparator}offline_queue'
      '${Platform.pathSeparator}baixa-1',
    );
    while (!folder.existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final duringSave = await store.readAll();
    await saving;

    expect(duringSave, isEmpty, reason: 'ainda sem JSON: não é lida');
    expect(store.lastDiscarded, isEmpty);
    final after = await store.readAll();
    expect(after.map((item) => item.id), ['baixa-1']);
    expect((await store.readFiles('baixa-1')).keys, hasLength(6));
  });

  test(
    'pasta sem request.json de gravação antiga continua sendo limpa',
    () async {
      final store = OfflineRequestStore(baseDirectory: () async => tempDir);
      final orphan = Directory(
        '${tempDir.path}${Platform.pathSeparator}offline_queue'
        '${Platform.pathSeparator}orfa',
      )..createSync(recursive: true);
      expect(await store.readAll(), isEmpty);
      expect(orphan.existsSync(), isFalse);
    },
  );
}
