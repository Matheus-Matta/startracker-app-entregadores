import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/offline_request_store.dart';
import 'package:star_tracker/core/network/api_failure.dart';
import 'package:star_tracker/core/sync/mobile_sync.dart';
import 'package:star_tracker/features/waves/data/route_snapshot_store.dart';
import 'package:star_tracker/features/waves/data/wave_service.dart';

import '../../support/fake_delivery_server.dart';

/// Processos do entregador de ponta a ponta, com a fila gravando em disco
/// de verdade e um servidor que segue as regras da API.
void main() {
  late Directory directory;
  late FakeDeliveryServer server;
  final devices = <TestDevice>[];

  TestDevice device({TestSession? session}) {
    final created = TestDevice(server, directory, session: session);
    devices.add(created);
    return created;
  }

  /// O sistema matou o app: memória perdida, disco preservado.
  Future<TestDevice> reopen({TestSession? session}) async {
    for (final old in devices) {
      old.dispose();
    }
    final reopened = device(session: session);
    await reopened.boot();
    return reopened;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('offline_scenarios');
    server = FakeDeliveryServer();
  });

  tearDown(() async {
    for (final old in devices) {
      old.dispose();
    }
    devices.clear();
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  });

  void expectNothingPending(TestDevice app) {
    expect(app.client.offlineRequests.pendingCount, 0);
    expect(app.client.offlineRequests.rejectedRequests, isEmpty);
  }

  void expectEachEventOnce() {
    final ids = server.applied.map((fields) => fields['client_event_id']);
    expect(ids.toSet().length, ids.length, reason: 'evento aplicado 2 vezes');
  }

  group('carga inteira sem sinal', () {
    test(
      'entregas e falha sem rede: pedido, rota e carga mudam na hora, '
      'sobrevivem ao app reaberto e chegam ao servidor uma vez cada',
      () async {
        server.routeStatus = 'released';
        var app = device();
        await app.boot();
        await app.waves.getWaves(page: 1); // abriu a lista com sinal
        await app.routes.getRoute(20); // e a carga

        server.online = false;
        await app.routes.startRoute(20);
        final first = app.routes.cachedRoute(20)!.stops.first;
        await app.routes.arrive(first.stopId);
        await app.routes.begin(first.stopId);
        final saved = await app.routes.complete(submissionFor(first));
        expect(saved.queued, isTrue);
        final second = app.routes.cachedRoute(20)!.stops.last;
        await app.routes.fail(
          stopId: second.stopId,
          reason: 'ausente',
          notes: '',
        );

        var local = app.routes.cachedRoute(20)!;
        expect(local.stops.map((stop) => stop.status), ['completed', 'failed']);
        expect(local.stops.first.orderStatus, 'delivered');
        expect(local.stops.last.orderStatus, 'delivery_failed');
        expect(local.status, 'partially_completed');
        expect(local.waveStatus, 'partially_completed');
        expect(server.applied, isEmpty, reason: 'sem rede nada chega');

        // Sistema mata o app; abre de novo ainda sem sinal.
        app = await reopen();
        local = await app.routes.getRoute(20);
        expect(local.status, 'partially_completed', reason: 'não volta atrás');
        expect(local.stops.first.status, 'completed');
        expect(app.client.offlineRequests.pendingCount, 5);
        final list = await app.waves.getWaves(page: 1);
        expect(list.items.single.status, 'partially_completed');

        // Sinal volta.
        server.online = true;
        await app.flush();
        expectNothingPending(app);
        expectEachEventOnce();
        // A falha da outra parada não espera o upload das fotos da baixa.
        expect(server.applied.map((fields) => fields['kind']), [
          SyncKind.routeStart,
          SyncKind.stopArrive,
          SyncKind.stopBegin,
          SyncKind.stopFail,
          SyncKind.stopComplete,
        ]);
        expect(server.photosReceived, 2);
        expect(server.routeStatus, 'partially_completed');
        expect(server.orders.values, ['delivered', 'delivery_failed']);

        // A leitura nova do servidor bate com o que o aparelho mostrava.
        final fresh = await app.routes.getRoute(20);
        expect(fresh.status, 'partially_completed');
        expect(fresh.stops.map((stop) => stop.status), ['completed', 'failed']);
      },
    );

    test('hora registrada é a da ação, não a do envio', () async {
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      server.online = false;
      final before = DateTime.now().toUtc();
      await app.routes.arrive(31);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      server.online = true;
      await app.flush();
      final occurred = DateTime.parse(server.applied.single['occurred_at']!);
      final sent = DateTime.parse(server.applied.single['sent_at']!);
      expect(
        occurred.isBefore(before.add(const Duration(milliseconds: 200))),
        isTrue,
      );
      expect(sent.difference(occurred).inMilliseconds, greaterThan(250));
    });
  });

  group('nunca volta ao estado antigo', () {
    test('leitura que saiu antes da confirmação e chegou depois', () async {
      final app = device();
      await app.boot();
      final stop = (await app.routes.getRoute(20)).stops.first;
      server.online = false;
      await app.routes.complete(submissionFor(stop));
      server.online = true;

      // A tela pede a rota; o servidor monta a resposta (ainda sem a baixa)
      // e ela fica presa na rede...
      server.holdRouteReads = Completer<void>();
      final staleRead = app.routes.getRoute(20);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // ...enquanto a fila envia a baixa e o servidor confirma.
      final release = server.holdRouteReads!;
      server.holdRouteReads = null;
      await app.flush();
      expect(server.stops[31], 'completed');
      expectNothingPending(app);

      release.complete();
      final shown = await staleRead;
      expect(shown.stops.first.status, 'completed', reason: 'voltou atrás');
      expect(app.routes.cachedRoute(20)!.stops.first.status, 'completed');

      // E continua certo depois de reabrir o app.
      final reopened = await reopen();
      server.online = false;
      expect(
        (await reopened.routes.getRoute(20)).stops.first.status,
        'completed',
      );
    });

    test('app morto logo após a confirmação, com a cópia em disco ainda '
        'antiga: reabre sem sinal mostrando entregue', () async {
      final app = device();
      await app.boot();
      final stop = (await app.routes.getRoute(20)).stops.first;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final snapshot = File(
        '${directory.path}/snap/route_snapshots/route_20.json',
      );
      final before = snapshot.readAsStringSync(); // cópia de antes da baixa
      server.online = false;
      await app.routes.complete(submissionFor(stop));
      server.online = true;
      await app.flush();
      expectNothingPending(app);

      // O sistema mata o app antes de a cópia ser atualizada.
      snapshot.writeAsStringSync(before);
      final reopened = await reopen();
      server.online = false;
      final route = await reopened.routes.getRoute(20);
      expect(route.stops.first.status, 'completed');
      expect(reopened.client.offlineRequests.pendingCount, 0);
    });

    test('leitura antiga é gravada já com o resultado confirmado', () async {
      final app = device();
      await app.boot();
      final stop = (await app.routes.getRoute(20)).stops.first;
      server.online = false;
      await app.routes.complete(submissionFor(stop));
      server.online = true;
      server.holdRouteReads = Completer<void>();
      final staleRead = app.routes.getRoute(20);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final release = server.holdRouteReads!;
      server.holdRouteReads = null;
      await app.flush();
      release.complete();
      await staleRead;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final saved = await RouteSnapshotStore(
        baseDirectory: () async => Directory('${directory.path}/snap'),
      ).read(20);
      final stops = (saved!['stops'] as List).cast<Map>();
      expect(
        stops.firstWhere((item) => item['id'] == 31)['status'],
        'completed',
        reason: 'disco ficou com o estado antigo',
      );
    });

    test(
      'parada cancelada no portal com baixa feita sem sinal não some',
      () async {
        final app = device();
        await app.boot();
        final stop = (await app.routes.getRoute(20)).stops.first;
        server.online = false;
        await app.routes.complete(submissionFor(stop));
        // Operador cancela a parada enquanto o entregador está sem sinal.
        server.stops[31] = 'cancelled';
        server.online = true;

        final duringSync = await app.routes.getRoute(20);
        expect(
          duringSync.stops.map((item) => item.stopId),
          contains(31),
          reason: 'a entrega feita sumia da tela',
        );
        expect(
          duringSync.stops.firstWhere((item) => item.stopId == 31).status,
          'completed',
        );

        await app.flush();
        expect(
          server.stops[31],
          'completed',
          reason: 'servidor aceita a baixa',
        );
        expect(server.orders[81], 'delivered');
      },
    );

    test('retirada: leitura confirmada não volta a pendente', () async {
      final app = device();
      await app.boot();
      await app.waves.getPickupProgress(10);
      server.online = false;
      await app.waves.registerPickup(waveId: 10, code: 'ped-81');
      server.online = true;

      server.holdRouteReads = Completer<void>();
      final staleRead = app.waves.getPickupProgress(10);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final release = server.holdRouteReads!;
      server.holdRouteReads = null;
      await app.flush();
      release.complete();

      final shown = await staleRead;
      expect(
        shown.orders.firstWhere((order) => order.orderId == 81).isPickedUp,
        isTrue,
      );
    });
  });

  group('sempre chega ao servidor', () {
    test('resposta perdida no 4G e app morto: reenvia o mesmo id, '
        'servidor aplica uma vez', () async {
      var app = device();
      await app.boot();
      final stop = (await app.routes.getRoute(20)).stops.first;
      server.syncFaults.add((
        fault: (_) => DioException.connectionError(
          requestOptions: RequestOptions(path: MobileSync.endpoint),
          reason: 'Connection closed before full header was received',
        ),
        applyFirst: true,
      ));
      expect((await app.routes.complete(submissionFor(stop))).queued, isTrue);
      expect(server.stops[31], 'completed', reason: 'servidor já gravou');

      app = await reopen();
      await app.flush();
      expectNothingPending(app);
      expect(server.deliveries.values.single, 2, reason: 'reenviou');
      expect(server.timesApplied(SyncKind.stopComplete), 1);
    });

    test('erro 500 persistente numa ação não trava as outras e nunca é '
        'descartado', () async {
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      String? poisoned;
      for (var i = 0; i < 6; i++) {
        server.syncFaults.add((
          fault: (eventId) {
            poisoned ??= eventId;
            return eventId == poisoned
                ? FakeDeliveryServer.status(500, {'detail': 'erro'})
                : null;
          },
          applyFirst: false,
        ));
      }
      await app.routes.arrive(31);
      await app.routes.arrive(32);
      await app.flush();

      expect(server.timesApplied(SyncKind.stopArrive), 2);
      expectNothingPending(app);
      expectEachEventOnce();
    });

    test('portal da operadora (HTML 200) não conta como enviado', () async {
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      server.syncFaults.add((
        fault: (_) => ResponseBody.fromString(
          '<html>Recarregue seu plano</html>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html'],
          },
        ),
        applyFirst: false,
      ));
      await app.routes.arrive(31);
      await app.client.offlineRequests.retryNow(manual: true);
      expect(app.client.offlineRequests.pendingCount, 1);
      await app.flush();
      expectNothingPending(app);
    });

    test('sessão expirada (401): espera o login e envia depois', () async {
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      server.syncFaults.add((
        fault: (_) => FakeDeliveryServer.status(401, {'detail': 'expirado'}),
        applyFirst: false,
      ));
      await app.routes.arrive(31);
      await app.client.offlineRequests.retryNow(manual: true);
      expect(app.client.offlineRequests.status.value.needsLogin, isTrue);
      expect(app.client.offlineRequests.pendingCount, 1);
      await app.flush();
      expectNothingPending(app);
    });

    test('recusa definitiva fica guardada e a parada volta a pendente para '
        'refazer', () async {
      final app = device();
      await app.boot();
      final stop = (await app.routes.getRoute(20)).stops.first;
      server.online = false;
      await app.routes.complete(submissionFor(stop));
      expect(app.routes.cachedRoute(20)!.stops.first.status, 'completed');
      server.online = true;
      server.syncFaults.add((
        fault: (_) => FakeDeliveryServer.status(400, [
          'Foto corrompida ou em formato inválido. Tire a foto novamente.',
        ]),
        applyFirst: false,
      ));
      await app.client.offlineRequests.retryNow(manual: true);

      final queue = app.client.offlineRequests;
      expect(queue.pendingCount, 0);
      expect(queue.rejectedRequests, hasLength(1));
      expect(queue.rejectedRequests.single.rejection, contains('Foto'));
      expect(app.routes.cachedRoute(20)!.stops.first.status, 'planned');

      // Reaberto o app, a recusa (com as fotos) continua lá.
      final reopened = await reopen();
      final rejected = reopened.client.offlineRequests.rejectedRequests;
      expect(rejected, hasLength(1));
      await reopened.client.offlineRequests.retryRejected(rejected.single.id);
      expectNothingPending(reopened);
      expect(server.stops[31], 'completed');
      expect(server.photosReceived, 2);
    });

    test('ação de outro entregador fica no aparelho e só ele envia', () async {
      final driverA = TestSession(identity: '1:10');
      var app = device(session: driverA);
      await app.boot();
      await app.routes.getRoute(20);
      server.online = false;
      await app.routes.arrive(31);

      // A sai; B entra no mesmo aparelho, com sinal.
      server.online = true;
      app = await reopen(session: TestSession(identity: '2:10'));
      // Força envios e espera o timer da abertura (2 s) disparar.
      await app.client.offlineRequests.retryNow(manual: true);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      await app.client.offlineRequests.retryNow(manual: true);
      expect(server.applied, isEmpty, reason: 'enviou com a sessão de B');
      expect(app.client.offlineRequests.pendingCount, 0);

      app = await reopen(session: driverA);
      await app.flush();
      expect(server.timesApplied(SyncKind.stopArrive), 1);
      expectNothingPending(app);
    });
  });

  group('requisições não acumulam', () {
    test('toque repetido não duplica ação', () async {
      final app = device();
      await app.boot();
      final stop = (await app.routes.getRoute(20)).stops.first;
      server.online = false;
      for (var i = 0; i < 5; i++) {
        await app.routes.arrive(31);
        await app.routes.startRoute(20);
      }
      await app.routes.complete(submissionFor(stop));
      await app.routes.complete(submissionFor(stop));
      await app.routes.fail(stopId: 31, reason: 'x', notes: '');
      expect(app.client.offlineRequests.pendingCount, 3);

      server.online = true;
      await app.flush();
      expect(server.syncRequests, 3);
    });

    test('vários gatilhos ao mesmo tempo: cada ação vai uma vez só', () async {
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      server.online = false;
      await app.routes.arrive(31);
      await app.routes.arrive(32);
      server.online = true;
      await Future.wait([
        for (var i = 0; i < 10; i++)
          app.client.offlineRequests.retryNow(manual: i.isEven),
      ]);
      await app.flush();
      expect(server.syncRequests, 2);
      expectNothingPending(app);
    });

    test('sem sinal: tenta só a sonda leve, nenhum envio repetido', () async {
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      server.online = false;
      await app.routes.arrive(31);
      server.seenPaths.clear();
      for (var i = 0; i < 10; i++) {
        await app.client.offlineRequests.retryNow();
      }
      expect(
        server.seenPaths.where((path) => path.contains('sincronizacao')),
        isEmpty,
      );
      expect(server.seenPaths, everyElement('GET /api/v1/'));
    });

    test('com sinal: depois do primeiro contato, cada ação é uma requisição '
        'só (sem sonda antes)', () async {
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      await app.routes.arrive(31);
      await app.flush();
      server.seenPaths.clear();
      await app.routes.begin(31);
      await app.flush();
      expect(server.seenPaths, ['POST ${MobileSync.endpoint}']);
    });

    test('sem sinal: toques seguidos não viram tentativas nem enchem o '
        'histórico de falhas', () async {
      ApiFailureLog.instance.clear();
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      server.online = false;
      server.seenPaths.clear();
      await app.routes.arrive(31);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final afterFirst = server.seenPaths.length;
      expect(afterFirst, 1, reason: 'a primeira ação tenta uma vez');
      await app.routes.begin(31);
      await app.routes.arrive(32);
      await app.routes.begin(32);
      expect(
        server.seenPaths.length,
        afterFirst,
        reason: 'nova tentativa a cada toque',
      );
      expect(
        ApiFailureLog.instance.entries.value.where(
          (entry) => entry.failure.stage == 'Carregar dados',
        ),
        isEmpty,
        reason: 'a sonda empurrava a falha real para fora do histórico',
      );
      expect(app.client.offlineRequests.pendingCount, 4);
    });

    test('muitas baixas sem sinal: fotos ficam no disco, não na memória, '
        'e todas chegam em ordem', () async {
      server = FakeDeliveryServer(stopCount: 25);
      var app = device();
      await app.boot();
      final stops = (await app.routes.getRoute(20)).stops;
      server.online = false;
      for (final stop in stops) {
        await app.routes.complete(submissionFor(stop, photos: 3));
      }
      expect(app.routes.cachedRoute(20)!.status, 'completed');

      app = await reopen();
      final store = OfflineRequestStore(
        baseDirectory: () async => Directory('${directory.path}/queue'),
      );
      final stored = await store.readAll();
      expect(stored, hasLength(25));
      expect(stored.every((item) => item.request.files.isEmpty), isTrue);

      server.online = true;
      await app.flush();
      expectNothingPending(app);
      expect(server.timesApplied(SyncKind.stopComplete), 25);
      expect(server.photosReceived, 75);
      expect(server.routeStatus, 'completed');
      expect(server.applied.map((fields) => fields['stop_id']), [
        for (final stop in stops) '${stop.stopId}',
      ]);
      expect(await store.readAll(), isEmpty, reason: 'disco limpo');
    });
  });

  group('retirada sem sinal', () {
    test('mesmas regras do servidor, sobrevive ao app reaberto e envia uma '
        'vez cada', () async {
      var app = device();
      await app.boot();
      await app.waves.getPickupProgress(10);
      server.online = false;

      var progress = await app.waves.registerPickup(
        waveId: 10,
        code: ' ped-81 ',
      );
      expect(progress.pickedUp, 1);
      await expectLater(
        app.waves.registerPickup(waveId: 10, code: 'PED-81'),
        throwsA(
          isA<WaveServiceException>().having(
            (error) => error.message,
            'message',
            'O pedido PED-81 já havia sido retirado.',
          ),
        ),
      );
      await expectLater(
        app.waves.registerPickup(waveId: 10, code: 'NAO-EXISTE'),
        throwsA(isA<WaveServiceException>()),
      );
      progress = await app.waves.markOrderNotGoing(waveId: 10, orderId: 82);
      expect(progress.isComplete, isTrue);

      app = await reopen();
      progress = await app.waves.getPickupProgress(10);
      expect(progress.isComplete, isTrue, reason: 'não volta atrás');

      server.online = true;
      await app.flush();
      expectNothingPending(app);
      expect(server.timesApplied(SyncKind.pickupScan), 1);
      expect(server.timesApplied(SyncKind.pickupNotGoing), 1);
      expect((await app.waves.getPickupProgress(10)).isComplete, isTrue);
    });
  });

  group('registro danificado no aparelho', () {
    test('é avisado e não impede o envio dos outros', () async {
      final app = device();
      await app.boot();
      await app.routes.getRoute(20);
      server.online = false;
      await app.routes.arrive(31);
      await app.routes.arrive(32);
      final queueDir = Directory('${directory.path}/queue/offline_queue');
      final folders = queueDir.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      File('${folders.first.path}/request.json').writeAsStringSync('{quebrado');

      final reopened = await reopen();
      server.online = true;
      await reopened.flush();
      expect(server.timesApplied(SyncKind.stopArrive), 1);
      expect(reopened.client.offlineRequests.pendingCount, 0);
    });
  });
}
