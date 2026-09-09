import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../notifications/notification_preferences.dart';

class SessionStorage {
  const SessionStorage([this._storage = const FlutterSecureStorage()]);

  static const _tokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _rememberSessionKey = 'remember_session';
  static const _deliveryConfigKey = 'delivery_config';
  static const _newWaveNotificationsKey = 'notification_new_waves';
  static const _routeChangeNotificationsKey = 'notification_route_changes';
  static const _orderUpdateNotificationsKey = 'notification_order_updates';
  static const _pendingDeliveryCaptureKey = 'pending_delivery_capture';
  static String? _cachedAccessToken;
  static String? _cachedRefreshToken;
  static bool _accessTokenLoaded = false;
  static bool _refreshTokenLoaded = false;
  static Future<String?>? _accessTokenRead;
  static Future<String?>? _refreshTokenRead;
  static int _tokenCacheGeneration = 0;
  final FlutterSecureStorage _storage;

  /// Muda sempre que a identidade da sessao em memoria e alterada.
  ///
  /// Operacoes de rede longas usam este valor para impedir que uma resposta
  /// iniciada antes do logout restaure tokens de uma sessao encerrada.
  int get sessionGeneration => _tokenCacheGeneration;

  Future<void> saveToken(String token) async {
    _tokenCacheGeneration++;
    _cachedAccessToken = token;
    _accessTokenLoaded = true;
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<void> saveTokens({
    required String access,
    required String refresh,
  }) async {
    _tokenCacheGeneration++;
    _cachedAccessToken = access;
    _cachedRefreshToken = refresh;
    _accessTokenLoaded = true;
    _refreshTokenLoaded = true;
    await Future.wait([
      _storage.write(key: _tokenKey, value: access),
      _storage.write(key: _refreshTokenKey, value: refresh),
    ]);
  }

  Future<String?> readToken() async {
    if (_accessTokenLoaded) return _cachedAccessToken;
    final ongoing = _accessTokenRead;
    if (ongoing != null) return ongoing;
    final operation = _storage.read(key: _tokenKey);
    final generation = _tokenCacheGeneration;
    _accessTokenRead = operation;
    try {
      final token = await operation;
      if (generation != _tokenCacheGeneration) return _cachedAccessToken;
      _cachedAccessToken = token;
      _accessTokenLoaded = true;
      return _cachedAccessToken;
    } finally {
      if (identical(_accessTokenRead, operation)) _accessTokenRead = null;
    }
  }

  Future<String?> readRefreshToken() async {
    if (_refreshTokenLoaded) return _cachedRefreshToken;
    final ongoing = _refreshTokenRead;
    if (ongoing != null) return ongoing;
    final operation = _storage.read(key: _refreshTokenKey);
    final generation = _tokenCacheGeneration;
    _refreshTokenRead = operation;
    try {
      final token = await operation;
      if (generation != _tokenCacheGeneration) return _cachedRefreshToken;
      _cachedRefreshToken = token;
      _refreshTokenLoaded = true;
      return _cachedRefreshToken;
    } finally {
      if (identical(_refreshTokenRead, operation)) _refreshTokenRead = null;
    }
  }

  Future<void> saveRememberSession(bool remember) => _storage.write(
    key: _rememberSessionKey,
    value: remember ? 'true' : 'false',
  );

  Future<bool> shouldRememberSession() async =>
      await _storage.read(key: _rememberSessionKey) == 'true';

  Future<void> saveDeliveryConfig(Map<String, dynamic> config) =>
      _storage.write(key: _deliveryConfigKey, value: jsonEncode(config));

  Future<Map<String, dynamic>> readDeliveryConfig() async {
    final raw = await _storage.read(key: _deliveryConfigKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
    } on FormatException {
      return const {};
    }
  }

  Future<void> clearDeliveryConfig() =>
      _storage.delete(key: _deliveryConfigKey);

  Future<void> savePendingDeliveryCapture(Map<String, dynamic> draft) =>
      _storage.write(key: _pendingDeliveryCaptureKey, value: jsonEncode(draft));

  Future<Map<String, dynamic>?> readPendingDeliveryCapture() async {
    final raw = await _storage.read(key: _pendingDeliveryCaptureKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> clearPendingDeliveryCapture() =>
      _storage.delete(key: _pendingDeliveryCaptureKey);

  Future<NotificationPreferences> readNotificationPreferences() async {
    final values = await Future.wait([
      _storage.read(key: _newWaveNotificationsKey),
      _storage.read(key: _routeChangeNotificationsKey),
      _storage.read(key: _orderUpdateNotificationsKey),
    ]);
    return NotificationPreferences(
      newWaves: _storedBool(
        values[0],
        fallback: NotificationPreferences.defaults.newWaves,
      ),
      routeChanges: _storedBool(
        values[1],
        fallback: NotificationPreferences.defaults.routeChanges,
      ),
      orderUpdates: _storedBool(
        values[2],
        fallback: NotificationPreferences.defaults.orderUpdates,
      ),
    );
  }

  Future<void> saveNotificationPreferences(
    NotificationPreferences preferences,
  ) => Future.wait([
    _storage.write(
      key: _newWaveNotificationsKey,
      value: preferences.newWaves.toString(),
    ),
    _storage.write(
      key: _routeChangeNotificationsKey,
      value: preferences.routeChanges.toString(),
    ),
    _storage.write(
      key: _orderUpdateNotificationsKey,
      value: preferences.orderUpdates.toString(),
    ),
  ]);

  Future<void> clear() async {
    _tokenCacheGeneration++;
    _cachedAccessToken = null;
    _cachedRefreshToken = null;
    _accessTokenLoaded = true;
    _refreshTokenLoaded = true;
    _accessTokenRead = null;
    _refreshTokenRead = null;
    await _storage.deleteAll();
  }
}

bool _storedBool(String? value, {required bool fallback}) => switch (value) {
  'true' => true,
  'false' => false,
  _ => fallback,
};
