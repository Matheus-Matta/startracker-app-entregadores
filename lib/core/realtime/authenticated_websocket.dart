import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../network/api_client.dart';
import '../storage/session_storage.dart';
import 'fleet_socket_connector.dart';

typedef AuthenticatedSocketConnector =
    WebSocketChannel Function(Uri uri, String accessToken);

typedef WebSocketMessageParser<T> = T? Function(dynamic message);

class AuthenticatedWebSocket<T> {
  AuthenticatedWebSocket({
    required this.uri,
    required this.apiClient,
    required this.storage,
    required this._parser,
    this.onConnected,
    AuthenticatedSocketConnector? connector,
  }) : _connector = connector ?? connectFleetSocket;

  final Uri uri;
  final ApiClient apiClient;
  final SessionStorage storage;
  final WebSocketMessageParser<T> _parser;
  final void Function()? onConnected;
  final AuthenticatedSocketConnector _connector;
  final StreamController<T> _events = StreamController<T>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  bool _started = false;
  bool _connecting = false;
  int _attempt = 0;
  int _generation = 0;
  final Random _random = Random();

  static const int _maximumMessageLength = 256 * 1024;

  Stream<T> get events => _events.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _attempt = 0;
    await _connect(_generation);
  }

  Future<void> stop() async {
    _started = false;
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    await subscription?.cancel();
    await channel?.sink.close();
    _connecting = false;
  }

  void sendJson(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  Future<void> _connect(int generation) async {
    if (!_started || _connecting || generation != _generation) return;
    _connecting = true;
    WebSocketChannel? channel;
    try {
      final token = await storage.readToken();
      if (!_started || generation != _generation) return;
      if (token == null || token.isEmpty) {
        _started = false;
        return;
      }

      final connectedChannel = _connector(uri, token);
      channel = connectedChannel;
      _channel = connectedChannel;
      await connectedChannel.ready;
      if (!_started || generation != _generation) {
        await connectedChannel.sink.close();
        return;
      }

      _attempt = 0;
      _subscription = connectedChannel.stream.listen(
        _onMessage,
        onError: (_) => _handleDisconnect(connectedChannel, generation),
        onDone: () => _handleDisconnect(connectedChannel, generation),
        cancelOnError: true,
      );
      onConnected?.call();
    } catch (error) {
      if (identical(_channel, channel)) _channel = null;
      if (error is UnsupportedError) {
        _started = false;
        return;
      }
      _scheduleReconnect(generation);
    } finally {
      _connecting = false;
    }
  }

  void _onMessage(dynamic message) {
    if (_messageLength(message) > _maximumMessageLength) return;
    try {
      final event = _parser(message);
      if (event != null && !_events.isClosed) _events.add(event);
    } catch (_) {
      // Um payload remoto invalido nao pode encerrar o stream nem derrubar UI.
    }
  }

  Future<void> _handleDisconnect(
    WebSocketChannel disconnected,
    int generation,
  ) async {
    if (!identical(_channel, disconnected) || generation != _generation) {
      return;
    }
    _subscription = null;
    _channel = null;

    if (!_started) return;
    if (disconnected.closeCode == 4403) {
      _started = false;
      return;
    }
    if (disconnected.closeCode == 4401) {
      final refreshed = await apiClient.refreshAccessToken();
      if (!_started || generation != _generation) return;
      if (refreshed == null || refreshed.isEmpty) {
        _started = false;
        return;
      }
    }
    _scheduleReconnect(generation);
  }

  void _scheduleReconnect(int generation) {
    if (!_started || generation != _generation || _reconnectTimer != null) {
      return;
    }
    final baseMilliseconds = (1 << _attempt.clamp(0, 5)) * 1000;
    final half = baseMilliseconds ~/ 2;
    final delay = Duration(milliseconds: half + _random.nextInt(half + 1));
    _attempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      _connect(generation);
    });
  }

  static int _messageLength(dynamic message) => switch (message) {
    String value => value.length,
    List<int> value => value.length,
    _ => 0,
  };
}
