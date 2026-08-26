import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../app/app_dependencies.dart';
import '../config/app_config.dart';
import '../network/api_client.dart';
import '../storage/session_storage.dart';
import 'authenticated_websocket.dart';

typedef FleetSocketConnector =
    WebSocketChannel Function(Uri uri, String accessToken);

class FleetRealtimeEvent {
  const FleetRealtimeEvent({
    required this.type,
    required this.data,
    this.routeId,
    this.orderId,
  });

  final String type;
  final Map<String, dynamic> data;
  final int? routeId;
  final int? orderId;

  bool get isRouteChange =>
      type == 'delivery_route_update' || type == 'delivery_route_remove';

  bool get isOrderChange =>
      type == 'delivery_order_update' || type == 'delivery_order_remove';

  bool get isConnected => type == 'connected';

  static FleetRealtimeEvent? tryParse(dynamic message) {
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
    final nested = envelope['data'] ?? envelope['payload'];
    final data = nested is Map
        ? Map<String, dynamic>.from(nested)
        : Map<String, dynamic>.from(envelope);
    final type = (envelope['type'] ?? data['type'])?.toString() ?? '';
    if (type.isEmpty) return null;

    return FleetRealtimeEvent(
      type: type,
      data: data,
      routeId: type.startsWith('delivery_route_')
          ? _resourceId(envelope, data, 'route')
          : null,
      orderId: type.startsWith('delivery_order_')
          ? _resourceId(envelope, data, 'order')
          : null,
    );
  }

  static int? _resourceId(
    Map<String, dynamic> envelope,
    Map<String, dynamic> data,
    String resource,
  ) {
    for (final value in [
      envelope['${resource}_id'],
      data['${resource}_id'],
      data['id'],
      envelope['id'],
    ]) {
      final parsed = _asInt(value);
      if (parsed != null) return parsed;
    }

    for (final container in [envelope[resource], data[resource]]) {
      final parsed = container is Map
          ? _asInt(container['id'])
          : _asInt(container);
      if (parsed != null) return parsed;
    }
    return null;
  }
}

class FleetRealtimeChannel {
  FleetRealtimeChannel({
    required Uri uri,
    required ApiClient apiClient,
    SessionStorage storage = const SessionStorage(),
    FleetSocketConnector? connector,
  }) : _socket = AuthenticatedWebSocket<FleetRealtimeEvent>(
         uri: uri,
         apiClient: apiClient,
         storage: storage,
         parser: FleetRealtimeEvent.tryParse,
         connector: connector,
       );

  factory FleetRealtimeChannel.app() {
    final dependencies = AppDependencies.instance;
    return FleetRealtimeChannel(
      uri: AppConfig.fleetWebSocketUri,
      apiClient: dependencies.apiClient,
      storage: dependencies.storage,
    );
  }

  static final FleetRealtimeChannel instance = FleetRealtimeChannel.app();

  final AuthenticatedWebSocket<FleetRealtimeEvent> _socket;

  Stream<FleetRealtimeEvent> get events => _socket.events;

  Future<void> start() => _socket.start();

  Future<void> stop() => _socket.stop();
}

int? _asInt(dynamic value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text),
  _ => null,
};
