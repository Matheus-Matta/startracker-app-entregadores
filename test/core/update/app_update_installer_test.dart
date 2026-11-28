import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/update/app_update_installer.dart';

/// Servidor do APK: devolve [body] com o status dado.
class _ApkServer implements HttpClientAdapter {
  _ApkServer(this.body, {this.status = 200});

  final List<int> body;
  final int status;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    body,
    status,
    headers: {
      Headers.contentLengthHeader: ['${body.length}'],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/app_update');
  late Directory directory;
  final calls = <MethodCall>[];
  var canInstall = true;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('app_update');
    calls.clear();
    canInstall = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'canSelfUpdate' => true,
            'canInstall' => canInstall,
            'install' => true,
            _ => null,
          };
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  });

  AppUpdateInstaller installer(List<int> body, {int status = 200}) =>
      AppUpdateInstaller(
        http: Dio()..httpClientAdapter = _ApkServer(body, status: status),
        channel: channel,
        cacheDirectory: () async => directory,
        platform: TargetPlatform.android,
      );

  final apk = [0x50, 0x4B, ...List.filled(4096, 7)];
  final url = Uri.parse('https://example.test/StarTracker-Entregas.apk');

  test('baixa o APK com progresso e entrega ao instalador', () async {
    final progress = <double?>[];
    final service = installer(apk);

    final file = await service.download(
      url,
      version: '1.1.7',
      onProgress: progress.add,
    );

    expect(file.path, endsWith('StarTracker-Entregas-1.1.7.apk'));
    expect(await file.length(), apk.length);
    expect(progress.last, 1.0);
    // Nada de arquivo parcial para trás.
    expect(File('${file.path}.part').existsSync(), isFalse);

    expect(await service.install(file), AppUpdateInstallResult.started);
    expect(calls.last.method, 'install');
    expect(calls.last.arguments, {'path': file.path});
  });

  test('página de erro no lugar do APK não vai para o instalador', () async {
    final html = '<html>${'x' * 4096}</html>'.codeUnits;
    await expectLater(
      installer(html).download(url, version: '1.1.7'),
      throwsA(isA<AppUpdateInstallException>()),
    );
    final leftovers = Directory('${directory.path}/updates').listSync();
    expect(leftovers, isEmpty);
  });

  test('falha no download vira mensagem para o entregador', () async {
    await expectLater(
      installer(const [1, 2, 3], status: 404).download(url, version: '1.1.7'),
      throwsA(isA<AppUpdateInstallException>()),
    );
  });

  test('sem a liberação de instalar, abre a configuração primeiro', () async {
    canInstall = false;
    final service = installer(apk);
    final file = await service.download(url, version: '1.1.7');

    expect(await service.install(file), AppUpdateInstallResult.needsPermission);
    expect(calls.map((call) => call.method), [
      'canInstall',
      'openInstallSettings',
    ]);
  });

  test('instaladores de versões anteriores são apagados', () async {
    final service = installer(apk);
    final old = await service.download(url, version: '1.1.6');
    await service.download(url, version: '1.1.7');
    expect(old.existsSync(), isFalse);
  });

  test('fora do Android o app não se atualiza sozinho', () async {
    final service = AppUpdateInstaller(
      channel: channel,
      platform: TargetPlatform.iOS,
    );
    expect(await service.canSelfUpdate(), isFalse);
    expect(calls, isEmpty);
  });
}
