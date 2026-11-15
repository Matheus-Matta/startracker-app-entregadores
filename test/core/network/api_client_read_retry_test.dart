import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/storage/session_storage.dart';

void main() {
  ApiClient client(_ScriptedAdapter adapter) {
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: const _NoTokenStorage(),
    )..readRetryDelays = const [Duration.zero, Duration.zero];
    api.dio.httpClientAdapter = adapter;
    return api;
  }

  test('GET repete apos 502 do proxy e queda de conexao', () async {
    final adapter = _ScriptedAdapter(['502', 'drop', '200']);

    final response = await client(adapter).dio.get<dynamic>('/api/v1/x/');

    expect(response.statusCode, 200);
    expect(adapter.calls, 3);
  });

  test('GET desiste depois das tentativas configuradas', () async {
    final adapter = _ScriptedAdapter(['502', '502', '502', '200']);

    await expectLater(
      client(adapter).dio.get<dynamic>('/api/v1/x/'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.calls, 3);
  });

  test('erro da API (400) e POST nao sao repetidos', () async {
    final readAdapter = _ScriptedAdapter(['400', '200']);
    await expectLater(
      client(readAdapter).dio.get<dynamic>('/api/v1/x/'),
      throwsA(isA<DioException>()),
    );
    expect(readAdapter.calls, 1);

    final writeAdapter = _ScriptedAdapter(['502', '200']);
    await expectLater(
      client(writeAdapter).dio.post<dynamic>('/api/v1/x/'),
      throwsA(isA<DioException>()),
    );
    expect(writeAdapter.calls, 1);
  });
}

class _NoTokenStorage extends SessionStorage {
  const _NoTokenStorage();

  @override
  Future<String?> readToken() async => null;
}

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script);

  final List<String> script;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final step = script[calls++];
    if (step == 'drop') {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection reset by peer',
      );
    }
    final status = int.parse(step);
    return ResponseBody.fromString(
      status == 502 ? '<html>Bad gateway</html>' : jsonEncode({'ok': true}),
      status,
      headers: {
        Headers.contentTypeHeader: [
          status == 502 ? 'text/html' : Headers.jsonContentType,
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
