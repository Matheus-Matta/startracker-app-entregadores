import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/realtime/authenticated_websocket.dart';
import 'package:star_tracker/core/storage/session_storage.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  late ApiClient client;
  late _Session session;
  final sockets = <AuthenticatedWebSocket<String>>[];

  setUp(() {
    session = _Session();
    final refresh = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = _OfflineAdapter();
    client = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: session,
      refreshClient: refresh,
    );
  });

  tearDown(() async {
    AuthenticatedWebSocket.readyTimeout = const Duration(seconds: 20);
    for (final socket in sockets) {
      await socket.stop();
    }
    sockets.clear();
    client.offlineRequests.dispose();
  });

  /// [open]: se cada canal criado abre (`ready`) ou fica pendurado.
  AuthenticatedWebSocket<String> socket(
    List<_FakeChannel> channels, {
    required bool Function(int index) open,
  }) {
    final created = AuthenticatedWebSocket<String>(
      uri: Uri.parse('wss://api.example.test/ws/'),
      apiClient: client,
      storage: session,
      parser: (message) => '$message',
      connector: (uri, token) {
        final channel = _FakeChannel(
          ready: open(channels.length)
              ? Future<void>.value()
              : Completer<void>().future,
        );
        channels.add(channel);
        return channel;
      },
    );
    sockets.add(created);
    return created;
  }

  test('rede zumbi: canal que nunca abre é refeito (antes ficava '
      '"conectando" para sempre)', () async {
    AuthenticatedWebSocket.readyTimeout = const Duration(milliseconds: 100);
    final channels = <_FakeChannel>[];
    await socket(channels, open: (_) => false).start();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(channels.length, greaterThanOrEqualTo(2));
  });

  test('token vencido (4401) e renovação sem sinal: volta a tentar em vez '
      'de desligar o tempo real até reabrir o app', () async {
    final channels = <_FakeChannel>[];
    await socket(channels, open: (_) => true).start();
    expect(channels, hasLength(1));
    channels.first.closeWith(4401);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(channels.length, greaterThanOrEqualTo(2));
    expect(await session.readRefreshToken(), 'refresh-ok');
  });
}

class _Session extends SessionStorage {
  @override
  Future<String?> readToken() async => 'access';

  @override
  Future<String?> readRefreshToken() async => 'refresh-ok';

  @override
  Future<void> clear() async => fail('não pode apagar a sessão sem rede');
}

class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(
    requestOptions: options,
    reason: 'Network is unreachable',
  );

  @override
  void close({bool force = false}) {}
}

class _FakeChannel implements WebSocketChannel {
  _FakeChannel({required this.ready});

  final _incoming = StreamController<dynamic>();
  int? _closeCode;

  void closeWith(int code) {
    _closeCode = code;
    unawaited(_incoming.close());
  }

  @override
  final Future<void> ready;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _FakeSink();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  @override
  void add(dynamic data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  Future<void> get done => Future<void>.value();
}
