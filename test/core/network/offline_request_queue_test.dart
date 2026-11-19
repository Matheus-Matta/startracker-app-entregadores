import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/offline_request_queue.dart';
import 'package:star_tracker/core/network/offline_request_store.dart';
import 'package:star_tracker/core/storage/session_storage.dart';

void main() {
  group('isNetworkFailure', () {
    final request = RequestOptions(path: '/api/v1/');
    DioException withResponse(
      int status, {
      Map<String, List<String>>? headers,
    }) => DioException.badResponse(
      statusCode: status,
      requestOptions: request,
      response: Response<dynamic>(
        requestOptions: request,
        statusCode: status,
        headers: Headers.fromMap(headers ?? {}),
      ),
    );

    test('conexao cortada no meio do upload e falha de rede', () {
      expect(
        OfflineRequestQueue.isNetworkFailure(
          DioException(
            requestOptions: request,
            error: const HttpException(
              'Connection closed while receiving data',
            ),
          ),
        ),
        isTrue,
      );
      expect(
        OfflineRequestQueue.isNetworkFailure(
          DioException(
            requestOptions: request,
            error: const HandshakeException('Connection terminated'),
          ),
        ),
        isTrue,
      );
    });

    test('erros de gateway e desafio do Cloudflare sao transitorios', () {
      for (final status in [408, 429, 502, 503, 504, 522, 524]) {
        expect(
          OfflineRequestQueue.isNetworkFailure(withResponse(status)),
          isTrue,
          reason: '$status',
        );
      }
      expect(
        OfflineRequestQueue.isNetworkFailure(
          withResponse(
            403,
            headers: {
              'cf-mitigated': ['challenge'],
            },
          ),
        ),
        isTrue,
      );
    });

    test('respostas da API continuam sendo erro definitivo', () {
      for (final status in [400, 401, 403, 404, 409, 500]) {
        expect(
          OfflineRequestQueue.isNetworkFailure(withResponse(status)),
          isFalse,
          reason: '$status',
        );
      }
    });
  });

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
      retryDelays: const [Duration(hours: 1)],
    );
  });

  tearDown(() async {
    // A pasta de uma ação enviada é apagada em segundo plano; espera ela
    // terminar antes de apagar a pasta do teste.
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  });

  tearDown(() => queue.dispose());

  OfflineRequestQueue offlineQueue(
    _SwitchAdapter adapter, {
    _MemorySessionStorage? storage,
    List<Duration> retryDelays = const [Duration(milliseconds: 10)],
  }) {
    final created = OfflineRequestQueue(
      Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter,
      storage ?? _MemorySessionStorage(),
      store: OfflineRequestStore(baseDirectory: () async => tempDir),
      retryDelays: retryDelays,
    );
    addTearDown(created.dispose);
    return created;
  }

  PersistedOfflineRequest persisted([Map<String, dynamic>? payload]) =>
      PersistedOfflineRequest(
        type: 'test.action',
        payload: payload ?? const {'stop_id': 1},
        files: {
          'photo_0': Uint8List.fromList([1, 2, 3]),
        },
      );

  Future<void> eventually(bool Function() condition) async {
    for (var i = 0; i < 1000 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  group('fotos da baixa nÃ£o seguram a fila', () {
    PersistedOfflineRequest text(int stopId) => PersistedOfflineRequest(
      type: 'test.action',
      payload: {'stop_id': stopId},
    );

    test('falha de outra parada feita durante o upload sai na hora; iniciar '
        'rota e aÃ§Ã£o da mesma parada esperam o upload', () async {
      final upload = Completer<void>();
      addTearDown(() {
        if (!upload.isCompleted) upload.complete();
      });
      final sent = <String>[];
      Future<String> send(String name) async {
        sent.add(name);
        return name;
      }

      await queue.enqueue<String>(
        resourceKey: 'stop:1',
        description: 'Finalizar entrega',
        persisted: persisted(),
        operation: (_) async {
          await upload.future;
          return send('baixa 1 com foto');
        },
      );
      await eventually(() => queue.status.value.sending);

      final other = await queue.enqueue<String>(
        resourceKey: 'stop:2',
        description: 'Falha na entrega',
        persisted: text(2),
        operation: (_) => send('falha 2'),
        waitFor: const Duration(seconds: 2),
      );
      expect(other.queued, isFalse, reason: 'nÃ£o esperou o upload');
      expect(sent, ['falha 2']);

      await queue.enqueue<String>(
        resourceKey: 'stop:1',
        description: 'Mesma parada',
        persisted: text(1),
        operation: (_) => send('mesma parada 1'),
      );
      await queue.enqueue<String>(
        resourceKey: 'route:9',
        description: 'Iniciar rota',
        persisted: text(9),
        operation: (_) => send('iniciar rota 9'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sent, ['falha 2'], reason: 'dependem do upload anterior');

      upload.complete();
      await eventually(() => queue.pendingCount == 0);
      expect(sent, [
        'falha 2',
        'baixa 1 com foto',
        'mesma parada 1',
        'iniciar rota 9',
      ]);
    });

    test('uploads seguem um por vez e na ordem', () async {
      final sent = <String>[];
      final first = Completer<void>();
      var running = 0;
      var maxRunning = 0;
      Future<String> upload(String name, [Future<void>? wait]) async {
        maxRunning = max(maxRunning, ++running);
        await wait;
        running--;
        sent.add(name);
        return name;
      }

      await queue.enqueue<String>(
        resourceKey: 'stop:1',
        description: 'Finalizar entrega',
        persisted: persisted(),
        operation: (_) => upload('foto 1', first.future),
      );
      await queue.enqueue<String>(
        resourceKey: 'stop:2',
        description: 'Finalizar entrega',
        persisted: persisted({'stop_id': 2}),
        operation: (_) => upload('foto 2'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      first.complete();
      await eventually(() => queue.pendingCount == 0);
      expect(sent, ['foto 1', 'foto 2']);
      expect(maxRunning, 1);
    });

    test('upload sem sinal: nada que dependa dele Ã© enviado e tudo volta '
        'na prÃ³xima tentativa', () async {
      final adapter = _SwitchAdapter()..online = true;
      final fastQueue = offlineQueue(
        adapter,
        retryDelays: const [Duration(milliseconds: 50)],
      );
      final sent = <String>[];
      var photoOnline = false;
      await fastQueue.enqueue<String>(
        resourceKey: 'stop:1',
        description: 'Finalizar entrega',
        persisted: persisted(),
        operation: (_) async {
          if (!photoOnline) throw _networkError();
          sent.add('foto 1');
          return 'ok';
        },
      );
      // Ação de outra parada entre as fotos: enquanto ela é enviada o
      // primeiro upload já falhou, antes de o segundo ser visto.
      await fastQueue.enqueue<String>(
        resourceKey: 'stop:2',
        description: 'Falha na entrega',
        persisted: text(2),
        operation: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          sent.add('falha 2');
          return 'ok';
        },
      );
      var secondPhotoAttempts = 0;
      await fastQueue.enqueue<String>(
        resourceKey: 'stop:3',
        description: 'Finalizar entrega',
        persisted: persisted({'stop_id': 3}),
        operation: (_) async {
          if (!photoOnline) {
            // Sem sinal no upload anterior: não abre outra conexão à toa.
            secondPhotoAttempts++;
            throw _networkError();
          }
          sent.add('foto 3');
          return 'ok';
        },
      );
      await fastQueue.enqueue<String>(
        resourceKey: 'route:9',
        description: 'Iniciar rota',
        persisted: text(9),
        operation: (_) async {
          sent.add('iniciar rota 9');
          return 'ok';
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(sent, ['falha 2'], reason: 'outra parada não depende da foto');
      expect(fastQueue.pendingCount, 3);

      photoOnline = true;
      await eventually(() => fastQueue.pendingCount == 0);
      expect(secondPhotoAttempts, 0);
      expect(sent, ['falha 2', 'foto 1', 'foto 3', 'iniciar rota 9']);
    });
  });

  test('intervalos crescentes por padrao, ate 5 minutos', () {
    expect(
      OfflineRequestQueue.defaultRetryDelays.last,
      const Duration(minutes: 5),
    );
  });

  test(
    'nunca desiste: continua tentando e envia quando a rede volta',
    () async {
      final adapter = _SwitchAdapter();
      final fastQueue = offlineQueue(adapter);
      final events = <OfflineQueueEventType>[];
      fastQueue.events.listen((event) => events.add(event.type));

      final result = await fastQueue.execute<void>(
        resourceKey: 'stop:1',
        description: 'Finalizar entrega',
        operation: (_) async {
          if (!adapter.online) throw _networkError();
        },
      );
      expect(result.queued, isTrue);

      await eventually(() => fastQueue.status.value.attempts >= 5);
      expect(fastQueue.pendingCount, 1, reason: 'nada e descartado');
      expect(events, isNot(contains(OfflineQueueEventType.rejected)));

      adapter.online = true;
      // O evento sai depois de a aÃ§Ã£o ser apagada do disco.
      await eventually(() => events.contains(OfflineQueueEventType.delivered));
      expect(fastQueue.pendingCount, 0);
    },
  );

  test(
    'enqueue grava no aparelho antes da rede e responde na hora sem sinal',
    () async {
      final adapter = _SwitchAdapter();
      final fastQueue = offlineQueue(
        adapter,
        retryDelays: const [Duration(hours: 1)],
      );
      var calls = 0;
      final watch = Stopwatch()..start();

      final result = await fastQueue.enqueue<String>(
        resourceKey: 'stop:1',
        description: 'Finalizar entrega',
        persisted: persisted(),
        operation: (_) async {
          calls++;
          return 'ok';
        },
        waitFor: const Duration(seconds: 10),
      );

      expect(result.queued, isTrue);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(calls, 0, reason: 'sem sinal a operacao nem e chamada');
      final store = OfflineRequestStore(baseDirectory: () async => tempDir);
      final stored = await store.readAll();
      expect(stored, hasLength(1));
      // A listagem nÃ£o carrega as fotos na memÃ³ria; sÃ³ o envio lÃª do disco.
      expect(stored.single.request.files, isEmpty);
      expect(stored.single.request.fileKeys, ['photo_0']);
      expect((await store.readFiles(stored.single.id))['photo_0'], [1, 2, 3]);
      expect(fastQueue.pendingRequests.single.payload['stop_id'], 1);
    },
  );

  test('memÃ³ria cheia: a aÃ§Ã£o segue na fila, mas o resultado avisa que '
      'nÃ£o ficou guardada no aparelho', () async {
    final adapter = _SwitchAdapter();
    final fullDisk = OfflineRequestQueue(
      Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter,
      _MemorySessionStorage(),
      store: _FullDiskStore(),
      retryDelays: const [Duration(hours: 1)],
    );
    addTearDown(fullDisk.dispose);
    final result = await fullDisk.enqueue<String>(
      resourceKey: 'stop:1',
      description: 'Finalizar entrega',
      persisted: persisted(),
      operation: (_) async => 'ok',
      waitFor: const Duration(seconds: 2),
    );
    expect(result.queued, isTrue);
    expect(result.savedOnDevice, isFalse);
    expect(fullDisk.pendingCount, 1, reason: 'continua sendo enviada');

    final normal =
        await offlineQueue(
          _SwitchAdapter(),
          retryDelays: const [Duration(hours: 1)],
        ).enqueue<String>(
          resourceKey: 'stop:2',
          description: 'Finalizar entrega',
          persisted: persisted(),
          operation: (_) async => 'ok',
          waitFor: const Duration(seconds: 2),
        );
    expect(normal.savedOnDevice, isTrue);
  });

  test('enqueue com sinal devolve a resposta do servidor', () async {
    final result = await queue.enqueue<String>(
      resourceKey: 'stop:1',
      description: 'Finalizar entrega',
      persisted: persisted(),
      operation: (key) async => 'resposta $key',
      waitFor: const Duration(seconds: 5),
    );
    expect(result.queued, isFalse);
    expect(result.value, startsWith('resposta mobile-'));
    expect(queue.pendingCount, 0);
  });

  test('recusa definitiva fica guardada para o entregador decidir', () async {
    var accept = false;
    await queue.enqueue<void>(
      resourceKey: 'stop:1',
      description: 'Finalizar entrega',
      persisted: persisted(),
      operation: (_) async {
        if (!accept) throw _badRequest();
      },
    );
    await eventually(() => queue.rejectedRequests.length == 1);
    expect(queue.pendingCount, 0);
    expect(queue.status.value.needsAttention, isTrue);
    expect(queue.rejectedRequests.single.rejection, isNotEmpty);

    // Reaberto o app, a recusa continua lÃ¡, com as fotos.
    final reopened = OfflineRequestQueue(
      dio,
      _MemorySessionStorage(),
      store: OfflineRequestStore(baseDirectory: () async => tempDir),
    );
    addTearDown(reopened.dispose);
    var resent = 0;
    reopened.registerRestoreHandler('test.action', (_, payload, files) async {
      expect(files['photo_0'], [1, 2, 3]);
      resent++;
    });
    await reopened.restorePersisted();
    expect(reopened.rejectedRequests, hasLength(1));
    expect(reopened.pendingCount, 0);

    accept = true;
    await reopened.retryRejected(reopened.rejectedRequests.single.id);
    expect(resent, 1);
    expect(reopened.rejectedRequests, isEmpty);
    expect(
      await OfflineRequestStore(baseDirectory: () async => tempDir).readAll(),
      isEmpty,
    );
  });

  test('recusa enquanto o entregador espera volta como erro na tela', () async {
    await expectLater(
      queue.enqueue<void>(
        resourceKey: 'stop:1',
        description: 'Finalizar entrega',
        persisted: persisted(),
        operation: (_) async => throw _badRequest(),
        waitFor: const Duration(seconds: 5),
      ),
      throwsA(isA<DioException>()),
    );
    expect(queue.rejectedRequests, isEmpty, reason: 'ja foi mostrada');
  });

  test('acao de outro entregador fica guardada e nao e enviada', () async {
    final storage = _MemorySessionStorage()..identity = '1:10';
    final adapter = _SwitchAdapter();
    final first = offlineQueue(adapter, storage: storage);
    await first.enqueue<void>(
      resourceKey: 'stop:1',
      description: 'Finalizar entrega',
      persisted: persisted(),
      operation: (_) async {},
    );
    first.dispose();

    adapter.online = true;
    storage.identity = '2:10';
    final other = offlineQueue(adapter, storage: storage);
    var sent = 0;
    other.registerRestoreHandler('test.action', (_, _, _) async => sent++);
    await other.restorePersisted();
    await other.retryNow();
    expect(other.pendingCount, 0, reason: 'nao e do entregador atual');
    expect(sent, 0);

    storage.identity = '1:10';
    await other.reloadSession();
    await other.retryNow();
    expect(sent, 1);
  });

  test('sessao expirada (401) espera novo login sem descartar', () async {
    await queue.enqueue<void>(
      resourceKey: 'stop:1',
      description: 'Finalizar entrega',
      persisted: persisted(),
      operation: (_) async => throw _status(401),
    );
    await eventually(() => queue.status.value.needsLogin);
    expect(queue.pendingCount, 1);
    expect(queue.rejectedRequests, isEmpty);
  });

  test('relógio do celular voltando (hora ajustada pela rede) não inverte a '
      'ordem das ações ao reabrir o app', () async {
    final store = OfflineRequestStore(baseDirectory: () async => tempDir);
    final times = [DateTime(2026, 11, 18, 10, 5), DateTime(2026, 11, 18, 10)];
    final first = OfflineRequestQueue(
      Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = _SwitchAdapter(),
      _MemorySessionStorage(),
      store: store,
      retryDelays: const [Duration(hours: 1)],
      clock: () => times.removeAt(0),
    );
    for (final action in ['cheguei', 'iniciar']) {
      await first.enqueue<void>(
        resourceKey: 'stop:7',
        description: action,
        persisted: PersistedOfflineRequest(
          type: 'test.order',
          payload: {'action': action},
        ),
        operation: (_) async => throw _networkError(),
      );
    }
    first.dispose();

    final restored = OfflineRequestQueue(
      Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = _SwitchAdapter(),
      _MemorySessionStorage(),
      store: OfflineRequestStore(baseDirectory: () async => tempDir),
      retryDelays: const [Duration(hours: 1)],
    );
    addTearDown(restored.dispose);
    restored.registerRestoreHandler('test.order', (_, _, _) async {});
    await restored.restorePersisted();
    expect(
      [for (final item in restored.pendingRequests) item.description],
      ['cheguei', 'iniciar'],
    );
  });

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
        files: {
          'photo_0': Uint8List.fromList([1, 2, 3]),
        },
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
    restored.registerRestoreHandler('test.complete', (
      key,
      payload,
      files,
    ) async {
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

  test('erro HTTP no envio direto nao entra na fila', () async {
    expect(
      () => queue.execute<void>(
        resourceKey: 'stop:1',
        description: 'falha de validacao',
        operation: (_) async => throw _badRequest(),
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

DioException _status(int status) => DioException.badResponse(
  statusCode: status,
  requestOptions: RequestOptions(path: '/mutation'),
  response: Response<void>(
    requestOptions: RequestOptions(path: '/mutation'),
    statusCode: status,
  ),
);

DioException _badRequest() => _status(400);

class _MemorySessionStorage extends SessionStorage {
  String? identity;

  @override
  int get sessionGeneration => 0;

  @override
  Future<String?> readIdentity() async => identity;
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

class _FullDiskStore extends OfflineRequestStore {
  @override
  Future<void> save(StoredOfflineRequest stored) async =>
      throw const FileSystemException('No space left on device');
}
