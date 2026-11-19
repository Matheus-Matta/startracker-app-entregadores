import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/offline_request_queue.dart';
import 'package:star_tracker/core/presentation/offline_queue_banner.dart';
import 'package:star_tracker/core/presentation/sync_attention_page.dart';

import '../../support/fake_delivery_server.dart';

void main() {
  late Directory directory;
  late FakeDeliveryServer server;
  late TestDevice app;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('sync_ui');
    server = FakeDeliveryServer();
    app = TestDevice(server, directory);
  });

  tearDown(() {
    app.dispose();
    try {
      directory.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget banner(
    OfflineRequestQueue queue, {
    VoidCallback? onOpen,
    VoidCallback? onLogin,
  }) => MaterialApp(
    home: OfflineQueueBanner(
      queue: queue,
      onOpenAttention: onOpen,
      onLogin: onLogin,
      child: const Scaffold(body: Text('conteúdo')),
    ),
  );

  testWidgets('sem nada pendente o banner não aparece', (tester) async {
    await tester.pumpWidget(banner(app.client.offlineRequests));
    expect(find.text('conteúdo'), findsOneWidget);
    expect(find.textContaining('salva'), findsNothing);
  });

  testWidgets('sem sinal mostra quantas ações estão salvas e "Enviar agora"', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await app.boot();
      await app.routes.getRoute(20);
      server.online = false;
      await app.routes.arrive(31);
      await app.routes.arrive(32);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpWidget(banner(app.client.offlineRequests));
    await tester.pump();
    expect(find.textContaining('2 ações salvas no aparelho'), findsOneWidget);
    expect(find.text('Enviar agora'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // para o ticker do banner
  });

  testWidgets('sessão encerrada pelo servidor: o banner leva ao login', (
    tester,
  ) async {
    var login = false;
    final queue = app.client.offlineRequests;
    queue.status.value = const OfflineQueueStatus(
      pendingCount: 2,
      needsLogin: true,
    );
    await tester.pumpWidget(banner(queue, onLogin: () => login = true));
    expect(find.textContaining('Sessão expirada'), findsOneWidget);
    expect(find.text('Enviar agora'), findsNothing);
    await tester.tap(find.text('Entrar'));
    expect(login, isTrue);
  });

  testWidgets('recusa mostra "precisa de atenção" e abre a lista', (
    tester,
  ) async {
    var opened = false;
    await tester.runAsync(() async {
      await app.boot();
      await app.routes.getRoute(20);
      server.syncFaults.add((
        fault: (_) => FakeDeliveryServer.status(400, ['Foto corrompida.']),
        applyFirst: false,
      ));
      await app.routes.arrive(31);
      await app.flush();
    });
    await tester.pumpWidget(
      banner(app.client.offlineRequests, onOpen: () => opened = true),
    );
    await tester.pump();
    expect(find.text('1 ação precisa de atenção'), findsOneWidget);
    await tester.tap(find.text('Ver'));
    expect(opened, isTrue);
  });

  testWidgets('tela de atenção: reenviar envia, descartar pede confirmação', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await app.boot();
      await app.routes.getRoute(20);
      for (var i = 0; i < 2; i++) {
        server.syncFaults.add((
          fault: (_) => FakeDeliveryServer.status(400, ['Foto corrompida.']),
          applyFirst: false,
        ));
      }
      await app.routes.arrive(31);
      await app.routes.arrive(32);
      await app.flush();
    });
    final queue = app.client.offlineRequests;
    expect(queue.rejectedRequests, hasLength(2));
    await tester.pumpWidget(MaterialApp(home: SyncAttentionPage(queue: queue)));
    expect(find.textContaining('Foto corrompida'), findsNWidgets(2));

    await tester.runAsync(() async {
      await tester.tap(find.text('Reenviar').first);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(queue.rejectedRequests, hasLength(1));
    expect(server.timesApplied('stop.arrive'), 1);

    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();
    expect(find.text('Descartar esta ação?'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(queue.rejectedRequests, hasLength(1), reason: 'cancelar não apaga');

    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Descartar').last);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(queue.rejectedRequests, isEmpty);
    expect(find.text('Nenhuma ação recusada. Tudo certo.'), findsOneWidget);
  });
}
