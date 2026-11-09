import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/offline_request_queue.dart';
import '../../auth/data/profile_service.dart';

class DriverOverview {
  const DriverOverview({
    required this.name,
    required this.username,
    required this.accountName,
    required this.employeeCode,
    required this.phone,
    required this.active,
  });

  final String name;
  final String username;
  final String accountName;
  final String employeeCode;
  final String phone;
  final bool active;
}

class DriverOverviewService {
  DriverOverviewService(this.apiClient, {required this.profileService});

  /// Dados cadastrais mudam raramente; não precisam ir à API a cada
  /// atualização do painel.
  static const _cacheDuration = Duration(minutes: 5);

  final ApiClient apiClient;
  final ProfileService profileService;
  DriverOverview? _cached;
  DateTime? _cachedAt;
  Future<DriverOverview>? _operation;
  int _generation = 0;

  void invalidateCache() {
    _generation++;
    _cached = null;
    _cachedAt = null;
    _operation = null;
  }

  Future<DriverOverview> getOverview({bool refresh = false}) {
    final cached = _cached;
    final cachedAt = _cachedAt;
    if (!refresh &&
        cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _cacheDuration) {
      return Future.value(cached);
    }
    final ongoing = _operation;
    if (ongoing != null) return ongoing;
    final generation = _generation;
    final operation = () async {
      try {
        final overview = await _loadOverview();
        if (generation == _generation) {
          _cached = overview;
          _cachedAt = DateTime.now();
        }
        return overview;
      } on DioException catch (error) {
        if (cached != null && OfflineRequestQueue.isNetworkFailure(error)) {
          return cached;
        }
        rethrow;
      } finally {
        if (generation == _generation) _operation = null;
      }
    }();
    _operation = operation;
    return operation;
  }

  Future<DriverOverview> _loadOverview() async {
    final results = await Future.wait<dynamic>([
      profileService.getProfile(),
      apiClient.dio.get<dynamic>('/api/v1/delivery/entregadores/'),
    ]);
    final profile = results[0] as DeliveryProfile;
    final response = results[1];
    final data = response.data;
    final rawItems = data is Map ? data['results'] : data;
    final driver =
        rawItems is List && rawItems.isNotEmpty && rawItems.first is Map
        ? Map<String, dynamic>.from(rawItems.first as Map)
        : const <String, dynamic>{};

    return DriverOverview(
      name: profile.name,
      username: profile.username,
      accountName: profile.accountName,
      employeeCode: driver['employee_code']?.toString() ?? '',
      phone: driver['phone']?.toString() ?? '',
      active: driver['active'] != false,
    );
  }
}
