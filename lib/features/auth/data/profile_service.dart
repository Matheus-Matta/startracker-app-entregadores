import '../../../core/network/api_client.dart';

class DeliveryProfile {
  const DeliveryProfile({
    required this.name,
    required this.username,
    required this.email,
    required this.accountName,
  });

  final String name;
  final String username;
  final String email;
  final String accountName;
}

class ProfileService {
  ProfileService(this.apiClient);

  final ApiClient apiClient;
  DeliveryProfile? _cachedProfile;

  Future<DeliveryProfile> getProfile({bool refresh = false}) async {
    if (!refresh) {
      final cached = _cachedProfile;
      if (cached != null) return cached;
    }
    final response = await apiClient.dio.get<Map<String, dynamic>>(
      '/api/v1/auth/me/',
    );
    final data = response.data ?? const <String, dynamic>{};
    final user = data['user'] is Map
        ? Map<String, dynamic>.from(data['user'] as Map)
        : data;
    final account = data['account'] is Map
        ? Map<String, dynamic>.from(data['account'] as Map)
        : const <String, dynamic>{};
    final username = (user['username'] ?? user['identifier'] ?? 'entregador')
        .toString();

    final profile = DeliveryProfile(
      name: (user['name'] ?? user['full_name'] ?? username).toString(),
      username: username,
      email: (user['email'] ?? 'E-mail não informado').toString(),
      accountName: (account['name'] ?? 'Star Tracker').toString(),
    );
    _cachedProfile = profile;
    return profile;
  }

  void invalidateCache() => _cachedProfile = null;
}
