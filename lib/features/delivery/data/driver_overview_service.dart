import '../../../core/network/api_client.dart';
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
  const DriverOverviewService(this.apiClient);

  final ApiClient apiClient;

  Future<DriverOverview> getOverview() async {
    final results = await Future.wait<dynamic>([
      ProfileService(apiClient).getProfile(),
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
