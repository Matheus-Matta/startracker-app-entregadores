import '../core/config/app_config.dart';
import '../core/network/api_client.dart';
import '../core/storage/session_storage.dart';
import '../features/auth/data/auth_service.dart';
import '../features/auth/data/profile_service.dart';
import '../features/delivery/data/active_wave_service.dart';
import '../features/delivery/data/driver_overview_service.dart';
import '../features/notifications/data/notification_service.dart';
import '../features/orders/data/order_service.dart';
import '../features/waves/data/active_route_service.dart';
import '../features/waves/data/wave_service.dart';

class AppDependencies {
  AppDependencies._() {
    apiClient = ApiClient(baseUrl: AppConfig.backendUrl, storage: storage);
    auth = AuthService(apiClient: apiClient, storage: storage);
    profile = ProfileService(apiClient);
    orders = OrderService(apiClient);
    waves = WaveService(apiClient);
    activeRoutes = ActiveRouteService(apiClient, storage: storage);
    activeWave = ActiveWaveService(apiClient);
    driverOverview = DriverOverviewService(apiClient, profileService: profile);
    notifications = NotificationService(apiClient);
  }

  static final AppDependencies instance = AppDependencies._();

  final SessionStorage storage = const SessionStorage();
  late final ApiClient apiClient;
  late final AuthService auth;
  late final ProfileService profile;
  late final OrderService orders;
  late final WaveService waves;
  late final ActiveRouteService activeRoutes;
  late final ActiveWaveService activeWave;
  late final DriverOverviewService driverOverview;
  late final NotificationService notifications;

  void clearSessionCaches() {
    apiClient.offlineRequests.clear();
    orders.invalidateCache();
    profile.invalidateCache();
    activeRoutes.invalidateCache();
    waves.invalidateCache();
  }
}
