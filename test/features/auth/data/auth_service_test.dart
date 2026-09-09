import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
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

  @override
  Future<bool> shouldRememberSession() async => true;

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
