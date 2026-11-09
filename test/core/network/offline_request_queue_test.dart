import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/offline_request_queue.dart';
import 'package:star_tracker/core/network/offline_request_store.dart';
import 'package:star_tracker/core/storage/session_storage.dart';

void main() {
  late Dio dio;
  late OfflineRequestQueue queue;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_queue_test');
    dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
    dio.httpClientAdapter = _ReachableAdapter();
    queue = OfflineRequestQueue(
      dio,
      _MemorySessionStorage(),
      store: OfflineRequestStore(baseDirectory: () async => tempDir),
      retryInterval: const Duration(hours: 1),
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  tearDown(() => queue.dispose());

  test('usa intervalo de 1 minuto e no maximo 3 tentativas por padrao', () {
    final defaults = OfflineRequestQueue(dio, _MemorySessionStorage());
    expect(defaults.retryInterval, const Duration(minutes: 1));
    expect(defaults.maxAttempts, 3);
    defaults.dispose();
  });

  test(
    'para apos 3 tentativas automaticas e retoma com reenvio manual',
    () async {
      final adapter = _SwitchAdapter();
      final offlineDio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;
      final fastQueue = OfflineRequestQueue(
        offlineDio,
        _MemorySessionStorage(),
        store: OfflineRequestStore(baseDirectory: () async => tempDir),
        retryInterval: const Duration(milliseconds: 20),
      );
      addTearDown(fastQueue.dispose);
      final events = <OfflineQueueEventType>[];
      fastQueue.events.listen((event) => events.add(event.type));
      var calls = 0;

      final result = await fastQueue.execute<void>(
        resourceKey: 'stop:1',
        description: 'Finalizar entrega',
        operation: (_) async {
          calls++;
          if (!adapter.online) throw _networkError();
        },
      );
      expect(result.queued, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fastQueue.status.value.exhausted, isTrue);
      expect(fastQueue.status.value.attempts, 3);
      expect(fastQueue.pendingCount, 1, reason: 'nada e descartado');
      expect(events, contains(OfflineQueueEventType.exhausted));

      // Esgotada, a fila nao tenta mais sozinha.
      final callsWhenExhausted = calls;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, callsWhenExhausted);

      adapter.online = true;
      await fastQueue.retryNow(manual: true);
      expect(fastQueue.pendingCount, 0);
      expect(fastQueue.status.value.hasPending, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(events.last, OfflineQueueEventType.delivered);
    },
  );

  test('requisicao persistida e reenviada depois de reabrir o app', () async {
    final adapter = _SwitchAdapter();
    final offlineDio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;
    final store = OfflineRequestStore(baseDirectory: () async => tempDir);
    final first = OfflineRequestQueue(
      offlineDio,
      _MemorySessionStorage(),
      store: store,
    );
    await first.execute<void>(
      resourceKey: 'stop:7',
      description: 'Finalizar entrega',
      operation: (_) async => throw _networkError(),
      persisted: PersistedOfflineRequest(
        type: 'test.complete',
        payload: const {'stop_id': 7},
        files: {'photo_0': Uint8List.fromList([1, 2, 3])},
      ),
    );
    first.dispose();

    adapter.online = true;
    final restored = OfflineRequestQueue(
      offlineDio,
      _MemorySessionStorage(),
      store: OfflineRequestStore(baseDirectory: () async => tempDir),
    );
    addTearDown(restored.dispose);
    final received = Completer<(String, Map<String, dynamic>, List<int>)>();
    restored.registerRestoreHandler('test.complete', (key, payload, files) async {
      received.complete((key, payload, files['photo_0']!.toList()));
    });
    await restored.restorePersisted();
    expect(restored.pendingCount, 1);
    await restored.retryNow();

    final (key, payload, photo) = await received.future;
    expect(key, startsWith('mobile-'));
    expect(payload['stop_id'], 7);
    expect(photo, [1, 2, 3]);
    expect(restored.pendingCount, 0);
    expect(await store.readAll(), isEmpty);
  });

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

class _SwitchAdapter implements HttpClientAdapter {
  bool online = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!online) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: const SocketException('offline'),
      );
    }
    return ResponseBody.fromString('{}', 200);
  }

  @override
  void close({bool force = false}) {}
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
