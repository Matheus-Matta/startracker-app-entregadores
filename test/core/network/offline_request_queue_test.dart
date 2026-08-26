import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/offline_request_queue.dart';
import 'package:star_tracker/core/storage/session_storage.dart';

void main() {
  late Dio dio;
  late OfflineRequestQueue queue;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
    dio.httpClientAdapter = _ReachableAdapter();
    queue = OfflineRequestQueue(
      dio,
      _MemorySessionStorage(),
      retryInterval: const Duration(hours: 1),
    );
  });

  tearDown(() => queue.dispose());

  test(
    'enfileira falha de rede e reenvia em FIFO quando o ping responde',
    () async {
      var online = false;
      final calls = <String>[];

      Future<void> operation(String name, String key) async {
        if (!online) throw _networkError();
        calls.add(name);
      }

      final first = await queue.execute<void>(
        resourceKey: 'stop:1',
        description: 'primeira',
        operation: (key) => operation('primeira', key),
      );
      final second = await queue.execute<void>(
        resourceKey: 'stop:2',
        description: 'segunda',
        operation: (key) => operation('segunda', key),
      );

      expect(first.queued, isTrue);
      expect(second.queued, isTrue);
      expect(queue.pendingCount, 2);

      online = true;
      await queue.retryNow();

      expect(calls, ['primeira', 'segunda']);
      expect(queue.pendingCount, 0);
    },
  );

  test('erro HTTP nao entra na fila', () async {
    expect(
      () => queue.execute<void>(
        resourceKey: 'stop:1',
        description: 'falha de validacao',
        operation: (_) async => throw DioException.badResponse(
          statusCode: 400,
          requestOptions: RequestOptions(path: '/mutation'),
          response: Response<void>(
            requestOptions: RequestOptions(path: '/mutation'),
            statusCode: 400,
          ),
        ),
      ),
      throwsA(isA<DioException>()),
    );
    expect(queue.pendingCount, 0);
  });
}

DioException _networkError() => DioException(
  requestOptions: RequestOptions(path: '/mutation'),
  type: DioExceptionType.connectionError,
  error: TimeoutException('offline'),
);

class _MemorySessionStorage extends SessionStorage {
  @override
  int get sessionGeneration => 0;
}

class _ReachableAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString('{}', 200);

  @override
  void close({bool force = false}) {}
}
