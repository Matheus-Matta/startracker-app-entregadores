// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/features/waves/data/active_route_service.dart';

import '../support/fake_delivery_server.dart';

/// Teste de carga: um dia pesado de entregador, com a lógica real do app
/// (fila, cópias em disco, regras locais) e o servidor falso instantâneo —
/// mede o custo do aparelho, não da rede.
///
/// Fora da suíte normal. Rodar com:
///   flutter test test/performance --dart-define=PERF=true
const _enabled = bool.fromEnvironment('PERF');
const _stops = 300;
const _photoBytes = 150 * 1024;

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('heavy_load');
  });

  tearDown(() async {
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  });

  test(
    'dia pesado: $_stops paradas sem sinal, 2 fotos por baixa',
    () async {
      final rssStart = ProcessInfo.currentRss;
      final server = FakeDeliveryServer(stopCount: _stops);
      final app = TestDevice(server, directory);
      await app.boot();

      // 1. Abrir a rota com sinal (montagem da rota de 300 paradas).
      var watch = Stopwatch()..start();
      final route = await app.routes.getRoute(20);
      _report('Abrir rota de $_stops paradas (1ª vez)', watch);
      expect(route.stops, hasLength(_stops));
      watch = Stopwatch()..start();
      await app.routes.getRoute(20);
      _report('Reabrir a mesma rota (com cópia)', watch);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // 2. Dia inteiro sem sinal.
      server.online = false;
      final random = Random(7);
      Uint8List photo() => Uint8List.fromList(
        List.generate(_photoBytes, (_) => random.nextInt(256)),
      );
      final arrive = <int>[];
      final begin = <int>[];
      final complete = <int>[];
      final screen = <int>[];
      final day = Stopwatch()..start();
      for (final stop in route.stops) {
        var step = Stopwatch()..start();
        await app.routes.arrive(stop.stopId);
        arrive.add(step.elapsedMicroseconds);
        step = Stopwatch()..start();
        await app.routes.begin(stop.stopId);
        begin.add(step.elapsedMicroseconds);
        step = Stopwatch()..start();
        await app.routes.complete(
          DeliveryProofSubmission(
            stop: stop,
            recipientName: 'Maria',
            recipientDocument: '',
            notes: '',
            photos: [
              DeliveryPhotoUpload(bytes: photo(), filename: 'a.jpg'),
              DeliveryPhotoUpload(bytes: photo(), filename: 'b.jpg'),
            ],
            signatureBytes: null,
            latitude: null,
            longitude: null,
            itemResults: const [],
          ),
        );
        complete.add(step.elapsedMicroseconds);
        // O que o mapa faz depois de cada baixa: mostrar o estado local.
        step = Stopwatch()..start();
        final shown = app.routes.cachedRoute(20)!;
        screen.add(step.elapsedMicroseconds);
        expect(
          shown.stops.firstWhere((item) => item.stopId == stop.stopId).status,
          'completed',
        );
      }
      day.stop();
      final pending = app.client.offlineRequests.pendingCount;
      print('');
      print('--- Dia sem sinal: $pending ações na fila ---');
      _series('Registrar chegada', arrive);
      _series('Iniciar entrega', begin);
      _series('Finalizar (2 fotos de 150 KB)', complete);
      _series('Tela do mapa após a baixa', screen);
      print(
        'Total do dia (só o custo do aparelho): ${day.elapsed.inSeconds} s',
      );
      expect(pending, _stops * 3);
      final finalRoute = app.routes.cachedRoute(20)!;
      expect(finalRoute.status, 'completed');
      final queueBytes = await _folderSize(
        Directory('${directory.path}${Platform.pathSeparator}queue'),
      );
      print(
        'Fila no disco: ${(queueBytes / 1024 / 1024).toStringAsFixed(1)} MB',
      );
      final rssDay = ProcessInfo.currentRss;

      // 3. App reaberto pelo sistema com a fila cheia.
      app.dispose();
      final reopened = TestDevice(server, directory);
      watch = Stopwatch()..start();
      await reopened.boot();
      _report('Reabrir o app com ${_stops * 3} ações na fila', watch);
      watch = Stopwatch()..start();
      final stored = await reopened.routes.storedRoute(20);
      _report('Mapa a partir da cópia do disco', watch);
      expect(stored?.status, 'completed');
      expect(reopened.client.offlineRequests.pendingCount, _stops * 3);

      // 4. O sinal volta: tudo é enviado.
      server.online = true;
      watch = Stopwatch()..start();
      for (
        var i = 0;
        i < 60 && reopened.client.offlineRequests.pendingCount > 0;
        i++
      ) {
        await reopened.client.offlineRequests.retryNow(manual: true);
      }
      _report('Enviar ${_stops * 3} ações (servidor instantâneo)', watch);
      expect(reopened.client.offlineRequests.pendingCount, 0);
      expect(server.photosReceived, _stops * 2);
      expect(server.timesApplied('stop.complete'), _stops);
      final rssEnd = ProcessInfo.currentRss;
      print(
        'Memória do processo: início ${_mb(rssStart)} · fim do dia '
        '${_mb(rssDay)} · após o envio ${_mb(rssEnd)}',
      );
      reopened.dispose();
    },
    skip: _enabled ? false : 'teste de carga: --dart-define=PERF=true',
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'conferência de $_stops pedidos sem sinal',
    () async {
      final server = FakeDeliveryServer(stopCount: _stops);
      final app = TestDevice(server, directory);
      await app.boot();
      var watch = Stopwatch()..start();
      await app.waves.getPickupProgress(10);
      _report('Abrir conferência de $_stops pedidos', watch);
      server.online = false;
      final scans = <int>[];
      for (var order = 81; order < 81 + _stops; order++) {
        final step = Stopwatch()..start();
        await app.waves.registerPickup(waveId: 10, code: 'PED-$order');
        scans.add(step.elapsedMicroseconds);
      }
      print('');
      print('--- Conferência sem sinal ---');
      _series('Bipar etiqueta', scans);
      watch = Stopwatch()..start();
      final progress = await app.waves.getPickupProgress(10);
      _report('Progresso com $_stops leituras na fila', watch);
      expect(progress.isComplete, isTrue);
      app.dispose();
    },
    skip: _enabled ? false : 'teste de carga: --dart-define=PERF=true',
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

void _report(String label, Stopwatch watch) =>
    print('$label: ${watch.elapsedMilliseconds} ms');

/// Mediana, p95 e pior caso; e o começo x o fim do dia (a fila crescendo).
void _series(String label, List<int> micros) {
  final sorted = [...micros]..sort();
  double ms(int value) => value / 1000;
  String at(double q) => ms(
    sorted[min(sorted.length - 1, (sorted.length * q).floor())],
  ).toStringAsFixed(1);
  final chunk = max(1, micros.length ~/ 10);
  double avg(Iterable<int> values) =>
      values.reduce((a, b) => a + b) / values.length / 1000;
  print(
    '$label: mediana ${at(0.5)} ms · p95 ${at(0.95)} ms · pior '
    '${ms(sorted.last).toStringAsFixed(1)} ms · início do dia '
    '${avg(micros.take(chunk)).toStringAsFixed(1)} ms → fim do dia '
    '${avg(micros.skip(micros.length - chunk)).toStringAsFixed(1)} ms',
  );
}

String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';

Future<int> _folderSize(Directory folder) async {
  var total = 0;
  if (!await folder.exists()) return 0;
  await for (final entity in folder.list(recursive: true)) {
    if (entity is File) total += await entity.length();
  }
  return total;
}
