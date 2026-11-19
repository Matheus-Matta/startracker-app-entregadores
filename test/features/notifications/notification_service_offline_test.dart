import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/network/offline_deadline.dart';
import 'package:star_tracker/core/storage/session_storage.dart';
import 'package:star_tracker/features/notifications/data/notification_service.dart';

void main() {
  late _Adapter adapter;
  late NotificationService service;

  setUp(() {
    adapter = _Adapter();
    final client = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: _Session(),
    )..readRetryDelays = const [];
    client.dio.httpClientAdapter = adapter;
    addTearDown(client.offlineRequests.dispose);
    service = NotificationService(client);
  });

  tearDown(() {
    OfflineDeadline.read = const Duration(seconds: 8);
    adapter.release();
  });

  test('sem sinal a central continua com a última lista', () async {
    expect((await service.getNotifications()).single.id, 7);
    adapter.mode = _Mode.offline;
    expect((await service.getNotifications()).single.id, 7);
  });

  test('rede zumbi: não fica girando até os timeouts da conexão', () async {
    OfflineDeadline.read = const Duration(milliseconds: 150);
    await service.getNotifications();
    adapter.mode = _Mode.hang;
    final list = await service.getNotifications().timeout(
      const Duration(seconds: 2),
    );
    expect(list.single.id, 7);
    await expectLater(
      service.markAllRead().timeout(const Duration(seconds: 2)),
      throwsA(isA<NotificationServiceException>()),
    );
  });

  test('sem lista salva avisa o erro (e o logout esquece a lista)', () async {
    await service.getNotifications();
    service.clearCache();
    adapter.mode = _Mode.offline;
    await expectLater(
      service.getNotifications(),
      throwsA(isA<NotificationServiceException>()),
    );
  });
}

enum _Mode { online, offline, hang }

class _Session extends SessionStorage {
  @override
  Future<String?> readToken() async => 'token';
}

class _Adapter implements HttpClientAdapter {
  _Mode mode = _Mode.online;
  final _hang = Completer<void>();

  void release() {
    if (!_hang.isCompleted) _hang.complete();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (mode == _Mode.hang) await _hang.future;
    if (mode != _Mode.online) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Network is unreachable',
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'next': null,
        'results': [
          {
            'id': 7,
            'kind': 'wave_assigned',
            'title': 'Nova carga',
            'message': 'Carga 3',
            'is_read': false,
            'created_at': '2026-11-18T08:00:00Z',
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
