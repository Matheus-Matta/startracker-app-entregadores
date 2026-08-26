import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../app/app_dependencies.dart';
import '../../features/notifications/data/notification_service.dart';
import '../config/app_config.dart';
import '../network/api_client.dart';
import '../storage/session_storage.dart';
import 'authenticated_websocket.dart';

typedef NotificationSocketConnector =
    WebSocketChannel Function(Uri uri, String accessToken);

class NotificationRealtimeChannel {
  NotificationRealtimeChannel({
    required Uri uri,
    required ApiClient apiClient,
    SessionStorage storage = const SessionStorage(),
    NotificationSocketConnector? connector,
  }) : _socket = AuthenticatedWebSocket<DeliveryNotification>(
         uri: uri,
         apiClient: apiClient,
         storage: storage,
         parser: tryParseMessage,
         onConnected: () => _connectionEvents.add(null),
         connector: connector,
       );

  factory NotificationRealtimeChannel.app() {
    final dependencies = AppDependencies.instance;
    return NotificationRealtimeChannel(
      uri: AppConfig.notificationsWebSocketUri,
      apiClient: dependencies.apiClient,
      storage: dependencies.storage,
    );
  }

  static final NotificationRealtimeChannel instance =
      NotificationRealtimeChannel.app();

  static final StreamController<void> _connectionEvents =
      StreamController<void>.broadcast();

  final AuthenticatedWebSocket<DeliveryNotification> _socket;

  Stream<DeliveryNotification> get events => _socket.events;
  Stream<void> get connections => _connectionEvents.stream;

  Future<void> start() =>
      AppConfig.notificationsEnabled ? _socket.start() : Future<void>.value();

  Future<void> stop() => _socket.stop();

  void markRead(int notificationId) {
    _socket.sendJson({'action': 'mark_read', 'id': notificationId});
  }

  void markAllRead() {
    _socket.sendJson({'action': 'mark_all_read'});
  }

  static DeliveryNotification? tryParseMessage(dynamic message) {
    dynamic decoded = message;
    if (message is String) {
      try {
        decoded = jsonDecode(message);
      } on FormatException {
        return null;
      }
    }
    if (decoded is! Map) return null;
    final envelope = Map<String, dynamic>.from(decoded);
    if (envelope['type']?.toString() != 'notification') return null;
    dynamic raw =
        envelope['notification'] ??
        envelope['data'] ??
        envelope['payload'] ??
        envelope;
    if (raw is Map && raw['notification'] is Map) {
      raw = raw['notification'];
    }
    return DeliveryNotification.tryParse(raw);
  }
}
