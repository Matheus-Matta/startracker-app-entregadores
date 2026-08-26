import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/offline_request_queue.dart';
import '../../../core/storage/session_storage.dart';

class AuthService {
  const AuthService({required this.apiClient, required this.storage});

  final ApiClient apiClient;
  final SessionStorage storage;

  Future<void> login({
    required String identifier,
    required String password,
    required bool rememberSession,
  }) async {
    try {
      final response = await apiClient.dio.post<Map<String, dynamic>>(
        '/api/v1/auth/entregadores/token/',
        data: {'identifier': identifier, 'password': password},
      );
      final data = response.data;
      final access = data?['access'] as String?;
      final refresh = data?['refresh'] as String?;

      if (access == null || refresh == null) {
        throw const AuthException('Resposta inválida do servidor.');
      }
      await storage.saveTokens(access: access, refresh: refresh);
      final deliveryConfig = _deliveryConfigFrom(data!);
      if (deliveryConfig.isEmpty) {
        // Evita reutilizar a configuração de outra conta em respostas antigas.
        await storage.clearDeliveryConfig();
      } else {
        await storage.saveDeliveryConfig(deliveryConfig);
      }
      await storage.saveRememberSession(rememberSession);
    } on DioException catch (error) {
      throw AuthException(_messageFrom(error));
    }
  }

  Future<bool> restoreSession() async {
    if (!await storage.shouldRememberSession()) {
      await storage.clear();
      return false;
    }
    final access = await storage.readToken();
    if (access == null || access.isEmpty) return false;

    try {
      await apiClient.dio.post<void>(
        '/api/v1/auth/token/verify/',
        data: {'token': access},
      );
      return true;
    } on DioException catch (error) {
      // Uma sessao lembrada continua utilizavel sem rede. A validade sera
      // confirmada (e o token renovado, se necessario) quando a API voltar.
      if (OfflineRequestQueue.isNetworkFailure(error)) return true;
      return _refreshSession();
    }
  }

  Future<bool> _refreshSession() async {
    final access = await apiClient.refreshAccessToken();
    if (access == null || access.isEmpty) {
      // O ApiClient apaga os tokens somente quando a API confirma que o
      // refresh e invalido (400/401/403). Em falhas de rede ou servidor, o
      // refresh continua armazenado e a sessao deve permanecer disponivel.
      final refresh = await storage.readRefreshToken();
      return refresh != null && refresh.isNotEmpty;
    }
    return true;
  }

  Map<String, dynamic> _deliveryConfigFrom(Map<String, dynamic> data) {
    dynamic raw = data['delivery_config'];
    if (raw is! Map && data['account'] is Map) {
      raw = (data['account'] as Map)['delivery_config'];
    }
    if (raw is! Map && data['delivery'] is Map) {
      raw = (data['delivery'] as Map)['config'];
    }
    if (raw is! Map) return const {};

    const acceptedKeys = {
      'require_photo',
      'minimum_photos',
      'maximum_photos',
      'require_signature',
      'require_recipient_name',
      'require_document',
      'require_note_on_failure',
      'capture_timestamp',
      'pickup_enabled',
      'pickup_barcode_source',
      'version',
    };
    final config = Map<String, dynamic>.from(raw);
    config.removeWhere((key, _) => !acceptedKeys.contains(key));
    return config;
  }

  String _messageFrom(DioException error) {
    final statusCode = error.response?.statusCode;
    final data = error.response?.data;

    if (data is Map) {
      for (final key in [
        'detail',
        'non_field_errors',
        'identifier',
        'password',
      ]) {
        final value = data[key];
        if (value is String && value.isNotEmpty) return value;
        if (value is List && value.isNotEmpty) return value.first.toString();
      }
    }
    if (statusCode == 401 || statusCode == 403) {
      return 'Usuário ou senha inválidos.';
    }
    if (error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout) {
      return 'Não foi possível conectar ao servidor.';
    }
    return 'Não foi possível entrar. Tente novamente.';
  }
}

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;
}
