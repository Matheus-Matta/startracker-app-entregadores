import 'package:flutter/foundation.dart';

abstract final class AppConfig {
  static String get backendUrl {
    const configuredUrl = String.fromEnvironment('BACKEND_URL');
    final fallback = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? 'http://10.0.2.2:8000'
        : 'http://localhost:8000';
    return validateBackendUrl(
      configuredUrl.isNotEmpty ? configuredUrl : fallback,
      releaseMode: kReleaseMode,
    );
  }

  static String validateBackendUrl(String value, {required bool releaseMode}) {
    final normalized = value.trim().replaceFirst(RegExp(r'/$'), '');
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw StateError('BACKEND_URL invalida. Informe uma URL HTTP(S) valida.');
    }
    if (releaseMode && uri.scheme != 'https') {
      throw StateError('Build release exige BACKEND_URL com HTTPS.');
    }
    return normalized;
  }

  static const notificationsEnabled = bool.fromEnvironment(
    'NOTIFICATIONS_ENABLED',
    defaultValue: true,
  );

  static const notificationChannelId = String.fromEnvironment(
    'NOTIFICATION_CHANNEL_ID',
    defaultValue: 'star_tracker_delivery_updates',
  );

  static const notificationChannelName = String.fromEnvironment(
    'NOTIFICATION_CHANNEL_NAME',
    defaultValue: 'Atualizações de entrega',
  );

  static const notificationChannelDescription = String.fromEnvironment(
    'NOTIFICATION_CHANNEL_DESCRIPTION',
    defaultValue: 'Novas cargas e alterações de pedidos e rotas',
  );

  static const fleetWebSocketPath = String.fromEnvironment(
    'FLEET_WEBSOCKET_PATH',
    defaultValue: '/ws/mobile/fleet/',
  );

  static const notificationsWebSocketPath = String.fromEnvironment(
    'NOTIFICATIONS_WEBSOCKET_PATH',
    defaultValue: '/ws/mobile/notifications/',
  );

  static Uri get fleetWebSocketUri =>
      webSocketUriFor(backendUrl, fleetWebSocketPath);

  static Uri get notificationsWebSocketUri =>
      webSocketUriFor(backendUrl, notificationsWebSocketPath);

  static Uri webSocketUriFor(String baseUrl, String path) {
    final base = Uri.parse(baseUrl);
    return Uri(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      userInfo: base.userInfo,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: path,
    );
  }
}
