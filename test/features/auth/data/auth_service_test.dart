import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/network/offline_deadline.dart';
import 'package:star_tracker/core/network/offline_request_store.dart';
import 'package:star_tracker/core/storage/session_storage.dart';
import 'package:star_tracker/features/auth/data/auth_service.dart';

void main() {
  test('atualiza e guarda o escopo de etiqueta retornado pela API', () async {
    final storage = _AuthStorage();
    final client = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: storage,
    );
    client.dio.httpClientAdapter = _JsonAdapter({
      'delivery_config': {
        'version': 5,
        'label_granularity': 'item',
        'campo_interno': 'nao deve ser armazenado',
      },
    });
    final auth = AuthService(apiClient: client, storage: storage);

    final config = await auth.deliveryConfig(refresh: true);

    expect(config['label_granularity'], 'item');
    expect(config, isNot(contains('campo_interno')));
    expect(storage.deliveryConfig['label_granularity'], 'item');
  });

  test('preserva disponibilidade e localizacao do contrato v6', () async {
    final storage = _AuthStorage();
    final client = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: storage,
    );
    client.dio.httpClientAdapter = _JsonAdapter({
      'delivery_config': {
        'version': 6,
        'availability': {
          'can_edit': true,
          'value': 'available',
          'options': [
            {'value': 'available', 'label': 'Disponível'},
          ],
          'update_url': '/api/v1/delivery/entregadores/7/disponibilidade/',
          'method': 'POST',
        },
        'confirmation_location': {
          'enabled': true,
          'latitude_field': 'delivery_actual_lat',
          'longitude_field': 'delivery_actual_lng',
        },
      },
    });
    final auth = AuthService(apiClient: client, storage: storage);

    final config = await auth.deliveryConfig(refresh: true);

    expect(config['version'], 6);
    expect(config['availability'], isA<Map>());
    expect(config['confirmation_location'], isA<Map>());
  });

  test('usa a ultima configuracao salva quando a atualizacao falha', () async {
    final storage = _AuthStorage()
      ..deliveryConfig = {'label_granularity': 'order'};
    final auth = _authService(storage, refreshStatus: 503);

    final config = await auth.deliveryConfig(refresh: true);

    expect(config['label_granularity'], 'order');
  });

  test('aceita o escopo no formato atual e configuracao direta', () async {
    final storage = _AuthStorage();
    final client = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: storage,
    );
    client.dio.httpClientAdapter = _JsonAdapter({
      'label_scope': 'per_order',
      'pickup_enabled': true,
    });
    final auth = AuthService(apiClient: client, storage: storage);

    final config = await auth.deliveryConfig(refresh: true);

    expect(config['label_scope'], 'per_order');
    expect(config['pickup_enabled'], isTrue);
  });

  test('mantem a sessao quando o refresh falha temporariamente', () async {
    final storage = _AuthStorage();
    final auth = _authService(storage, refreshStatus: 503);

    expect(await auth.restoreSession(), isTrue);
    expect(storage.clearCalls, 0);
    expect(await storage.readRefreshToken(), 'refresh-salvo');
  });

  group('sem "lembrar sessão"', () {
    test('app reaberto sem trabalho pendente sai da conta', () async {
      final storage = _AuthStorage()..remember = false;
      final auth = _authService(storage, refreshStatus: 503);
      expect(await auth.restoreSession(), isFalse);
      expect(storage.clearCalls, 1);
    });

    test('com foto de baixa em andamento (Android fechou o app na câmera) '
        'continua na conta', () async {
      final storage = _AuthStorage()
        ..remember = false
        ..capture = {'stop_id': 31};
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        storage: storage,
      );
      client.dio.httpClientAdapter = _OfflineAdapter();
      final auth = AuthService(apiClient: client, storage: storage);
      expect(await auth.restoreSession(), isTrue);
      expect(storage.clearCalls, 0);
    });

    test('com ação salva sem sinal continua na conta', () async {
      final directory = Directory.systemTemp.createTempSync('auth_queue');
      addTearDown(() => directory.deleteSync(recursive: true));
      final store = OfflineRequestStore(baseDirectory: () async => directory);
      await store.save(
        StoredOfflineRequest(
          id: 'a1',
          resourceKey: 'stop:31',
          description: 'Registrar chegada',
          idempotencyKey: 'a1',
          createdAt: DateTime.now(),
          request: const PersistedOfflineRequest(
            type: 'mobile_sync.event',
            payload: {'kind': 'stop.arrive'},
          ),
        ),
      );
      final storage = _AuthStorage()..remember = false;
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        storage: storage,
        offlineStore: store,
      );
      client.offlineRequests.registerRestoreHandler(
        'mobile_sync.event',
        (_, _, _) async => null,
      );
      client.dio.httpClientAdapter = _OfflineAdapter();
      final auth = AuthService(apiClient: client, storage: storage);
      expect(await auth.restoreSession(), isTrue);
      expect(storage.clearCalls, 0);
      client.offlineRequests.dispose();
    });
  });

  test('token vencido e renovação presa em rede zumbi: o app abre em '
      'segundos, sem perder a sessão', () async {
    OfflineDeadline.read = const Duration(milliseconds: 300);
    addTearDown(() => OfflineDeadline.read = const Duration(seconds: 8));
    final storage = _AuthStorage();
    final hang = Completer<void>();
    addTearDown(hang.complete);
    final refreshDio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = _HangingAdapter(hang.future);
    final client = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: storage,
      refreshClient: refreshDio,
    );
    client.dio.httpClientAdapter = const _StatusAdapter(401);
    final auth = AuthService(apiClient: client, storage: storage);

    final restored = await auth.restoreSession().timeout(
      const Duration(seconds: 3),
    );
    expect(restored, isTrue);
    expect(storage.clearCalls, 0);
  });

  test('encerra a sessao quando a API rejeita o refresh', () async {
    final storage = _AuthStorage();
    final auth = _authService(storage, refreshStatus: 401);

    expect(await auth.restoreSession(), isFalse);
    expect(storage.clearCalls, 1);
    expect(await storage.readRefreshToken(), isNull);
  });
}

AuthService _authService(_AuthStorage storage, {required int refreshStatus}) {
  final refreshDio = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
  refreshDio.httpClientAdapter = _StatusAdapter(refreshStatus);
  final client = ApiClient(
    baseUrl: 'https://api.example.test',
    storage: storage,
    refreshClient: refreshDio,
  );
  client.dio.httpClientAdapter = _StatusAdapter(401);
  return AuthService(apiClient: client, storage: storage);
}

class _AuthStorage extends SessionStorage {
  String? access = 'access-expirado';
  String? refresh = 'refresh-salvo';
  int clearCalls = 0;
  Map<String, dynamic> deliveryConfig = {};
  int _generation = 0;

  @override
  int get sessionGeneration => _generation;

  bool remember = true;
  Map<String, dynamic>? capture;

  @override
  Future<bool> shouldRememberSession() async => remember;

  @override
  Future<Map<String, dynamic>?> readPendingDeliveryCapture() async => capture;

  @override
  Future<String?> readToken() async => access;

  @override
  Future<String?> readRefreshToken() async => refresh;

  @override
  Future<Map<String, dynamic>> readDeliveryConfig() async => deliveryConfig;

  @override
  Future<void> saveDeliveryConfig(Map<String, dynamic> config) async {
    deliveryConfig = Map<String, dynamic>.from(config);
  }

  @override
  Future<void> clear() async {
    _generation++;
    clearCalls++;
    access = null;
    refresh = null;
  }
}

class _JsonAdapter implements HttpClientAdapter {
  const _JsonAdapter(this.payload);

  final Map<String, dynamic> payload;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(payload),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

class _HangingAdapter implements HttpClientAdapter {
  const _HangingAdapter(this.until);

  final Future<void> until;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await until;
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'zumbi',
    );
  }

  @override
  void close({bool force = false}) {}
}

class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(
    requestOptions: options,
    reason: 'Network is unreachable',
  );

  @override
  void close({bool force = false}) {}
}

class _StatusAdapter implements HttpClientAdapter {
  const _StatusAdapter(this.statusCode);

  final int statusCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{}',
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}
