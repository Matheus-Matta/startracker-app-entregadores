import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:star_tracker/core/update/app_update_service.dart';

void main() {
  group('versoes', () {
    test('normaliza tag com prefixo e build', () {
      expect(AppUpdateService.normalizeVersion('v1.0.55+9'), '1.0.55');
      expect(AppUpdateService.normalizeVersion('v1.0.55-build3'), '1.0.55');
      expect(AppUpdateService.normalizeVersion('1.1'), '1.1');
    });

    test('compara numericamente, nao como texto', () {
      expect(AppUpdateService.isNewer('1.0.55', '1.0.54'), isTrue);
      expect(AppUpdateService.isNewer('1.0.100', '1.0.99'), isTrue);
      expect(AppUpdateService.isNewer('1.1', '1.0.54'), isTrue);
      expect(AppUpdateService.isNewer('1.0.54', '1.0.54'), isFalse);
      expect(AppUpdateService.isNewer('1.0.53', '1.0.54'), isFalse);
      expect(AppUpdateService.isNewer('1.0', '1.0.0'), isFalse);
    });
  });

  group('Android (GitHub)', () {
    test('avisa quando a release mais nova tem o APK anexado', () async {
      final adapter = _FakeAdapter({
        'GET /releases/latest': _redirect('/releases/tag/v1.0.55'),
        'HEAD /releases/download/v1.0.55/StarTracker-Entregas.apk': _redirect(
          'https://objects.example/apk',
        ),
      });
      final update = await _service(adapter, TargetPlatform.android).check();

      expect(update, isNotNull);
      expect(update!.latestVersion, '1.0.55');
      expect(
        update.downloadUrl.toString(),
        'https://github.com/dono/repo/releases/download/v1.0.55/StarTracker-Entregas.apk',
      );
    });

    test(
      'nao avisa se o build Android falhou e a release nao tem APK',
      () async {
        final adapter = _FakeAdapter({
          'GET /releases/latest': _redirect('/releases/tag/v1.0.55'),
          'HEAD /releases/download/v1.0.55/StarTracker-Entregas.apk':
              ResponseBody.fromString('', 404),
        });
        expect(await _service(adapter, TargetPlatform.android).check(), isNull);
      },
    );

    test('nao avisa quando ja esta na ultima versao', () async {
      final adapter = _FakeAdapter({
        'GET /releases/latest': _redirect('/releases/tag/v1.0.54'),
      });
      expect(await _service(adapter, TargetPlatform.android).check(), isNull);
    });

    test('falha de rede e silenciosa', () async {
      final adapter = _FakeAdapter({});
      expect(await _service(adapter, TargetPlatform.android).check(), isNull);
    });
  });

  group('iOS (App Store)', () {
    test('leva para a pagina do app quando a loja tem versao nova', () async {
      final adapter = _FakeAdapter({
        'GET /lookup': ResponseBody.fromString(
          jsonEncode({
            'resultCount': 1,
            'results': [
              {'version': '1.1', 'trackId': 6810018617},
            ],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      });
      final update = await _service(adapter, TargetPlatform.iOS).check();

      expect(update, isNotNull);
      expect(update!.latestVersion, '1.1');
      expect(
        update.downloadUrl.toString(),
        'https://apps.apple.com/app/id6810018617',
      );
      expect(adapter.lastQuery['bundleId'], 'br.dev.star.tracker.entregas');
    });
  });
}

AppUpdateService _service(_FakeAdapter adapter, TargetPlatform platform) {
  final http = Dio(
    BaseOptions(
      followRedirects: false,
      validateStatus: (status) => status != null && status < 500,
    ),
  )..httpClientAdapter = adapter;
  return AppUpdateService(
    http: http,
    platform: platform,
    githubRepository: 'dono/repo',
    packageInfo: () async => PackageInfo(
      appName: 'StarTracker',
      packageName: 'br.dev.star.tracker.entregas',
      version: '1.0.54',
      buildNumber: '1',
    ),
  );
}

ResponseBody _redirect(String location) => ResponseBody.fromString(
  '',
  302,
  headers: {
    'location': [
      location.startsWith('http')
          ? location
          : 'https://github.com/dono/repo$location',
    ],
  },
);

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.routes);

  final Map<String, ResponseBody> routes;
  Map<String, dynamic> lastQuery = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastQuery = options.queryParameters;
    final path = options.uri.path.replaceFirst('/dono/repo', '');
    final response = routes['${options.method} $path'];
    if (response == null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'sem rede',
      );
    }
    return response;
  }

  @override
  void close({bool force = false}) {}
}
