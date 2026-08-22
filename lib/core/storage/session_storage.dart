import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SessionStorage {
  const SessionStorage([this._storage = const FlutterSecureStorage()]);

  static const _tokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _rememberSessionKey = 'remember_session';
  static const _deliveryConfigKey = 'delivery_config';
  final FlutterSecureStorage _storage;

  Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  Future<void> saveTokens({
    required String access,
    required String refresh,
  }) async {
    await Future.wait([
      _storage.write(key: _tokenKey, value: access),
      _storage.write(key: _refreshTokenKey, value: refresh),
    ]);
  }

  Future<String?> readToken() => _storage.read(key: _tokenKey);

  Future<String?> readRefreshToken() => _storage.read(key: _refreshTokenKey);

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

  Future<void> clear() => _storage.deleteAll();
}
