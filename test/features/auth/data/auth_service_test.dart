import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/storage/session_storage.dart';
import 'package:star_tracker/features/auth/data/auth_service.dart';

void main() {
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
  Future<void> clear() async {
    _generation++;
    clearCalls++;
    access = null;
    refresh = null;
  }
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
