import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/storage/session_storage.dart';

void main() {
  test('varios refresh simultaneos fazem uma unica chamada', () async {
    final storage = _MemorySessionStorage(
      access: 'access-antigo',
      refresh: 'refresh-antigo',
    );
    final adapter = _ControlledRefreshAdapter();
    final client = _client(storage, adapter);

    final first = client.refreshAccessToken();
    final second = client.refreshAccessToken();
    await adapter.started.future;
    adapter.succeed(access: 'access-novo', refresh: 'refresh-novo');

    expect(await Future.wait([first, second]), ['access-novo', 'access-novo']);
    expect(adapter.requests, 1);
    expect(storage.access, 'access-novo');
    expect(storage.refresh, 'refresh-novo');
  });

  test('resposta de refresh iniciada antes do logout e descartada', () async {
    final storage = _MemorySessionStorage(
      access: 'access-antigo',
      refresh: 'refresh-antigo',
    );
    final adapter = _ControlledRefreshAdapter();
    final client = _client(storage, adapter);

    final operation = client.refreshAccessToken();
    await adapter.started.future;
    await storage.clear();
    adapter.succeed(access: 'access-atrasado', refresh: 'refresh-atrasado');

    expect(await operation, isNull);
    expect(storage.access, isNull);
    expect(storage.refresh, isNull);
  });
}

ApiClient _client(
  _MemorySessionStorage storage,
  _ControlledRefreshAdapter adapter,
) {
  final refreshDio = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
  refreshDio.httpClientAdapter = adapter;
  return ApiClient(
    baseUrl: 'https://api.example.test',
    storage: storage,
    refreshClient: refreshDio,
  );
}

class _MemorySessionStorage extends SessionStorage {
  _MemorySessionStorage({required this.access, required this.refresh});

  String? access;
  String? refresh;
  int _generation = 0;

  @override
  int get sessionGeneration => _generation;

  @override
  Future<String?> readToken() async => access;

  @override
  Future<String?> readRefreshToken() async => refresh;

  @override
  Future<void> saveToken(String token) async {
    _generation++;
    access = token;
  }

  @override
  Future<void> saveTokens({
    required String access,
    required String refresh,
  }) async {
    _generation++;
    this.access = access;
    this.refresh = refresh;
  }

  @override
  Future<void> clear() async {
    _generation++;
    access = null;
    refresh = null;
  }
}

class _ControlledRefreshAdapter implements HttpClientAdapter {
  final started = Completer<void>();
  final _response = Completer<ResponseBody>();
  int requests = 0;

  void succeed({required String access, required String refresh}) {
    _response.complete(
      ResponseBody.fromString(
        jsonEncode({'access': access, 'refresh': refresh}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (!started.isCompleted) started.complete();
    return _response.future;
  }

  @override
  void close({bool force = false}) {}
}
