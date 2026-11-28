import 'dart:async';

import '../core/config/app_config.dart';
import '../core/network/api_client.dart';
import '../core/notifications/app_notification_manager.dart';
import '../core/presentation/offline_queue_banner.dart';
import '../core/realtime/fleet_realtime_channel.dart';
import '../core/location/location_service.dart';
import '../core/storage/session_storage.dart';
import '../core/sync/mobile_sync.dart';
import '../core/sync/sync_status_reporter.dart';
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
    apiClient.onSessionRenewed = () async {
      await auth.deliveryConfig(refresh: true);
      activeRoutes.invalidateCache();
    };
    sync = MobileSync(apiClient);
    syncReporter = SyncStatusReporter(apiClient);
    profile = ProfileService(apiClient);
    orders = OrderService(apiClient, sync: sync);
    waves = WaveService(apiClient, sync: sync);
    activeRoutes = ActiveRouteService(apiClient, storage: storage, sync: sync);
    waves.activeRoutes = activeRoutes;
    waves.onOrdersFetched = orders.rememberOrders;
    activeRoutes.startBlocker = waves.otherRouteInProgress;
    activeWave = ActiveWaveService(apiClient, activeRoutes: activeRoutes);
    driverOverview = DriverOverviewService(apiClient, profileService: profile);
    notifications = NotificationService(apiClient);
    location = LocationService();
    unawaited(
      storage.readShowSendQueue().then(
        (show) => OfflineQueueBanner.showPending.value = show,
        onError: (Object _) {},
      ),
    );
  }

  static final AppDependencies instance = AppDependencies._();

  final SessionStorage storage = const SessionStorage();
  late final ApiClient apiClient;
  late final MobileSync sync;
  late final SyncStatusReporter syncReporter;
  late final AuthService auth;
  late final ProfileService profile;
  late final OrderService orders;
  late final WaveService waves;
  late final ActiveRouteService activeRoutes;
  late final ActiveWaveService activeWave;
  late final DriverOverviewService driverOverview;
  late final NotificationService notifications;
  late final LocationService location;

  /// Sair da conta (Configurações ou sessão encerrada pelo servidor). O que
  /// está na fila fica no aparelho e é enviado quando o entregador voltar.
  Future<void> signOut() async {
    await AppNotificationManager.instance.stop();
    await FleetRealtimeChannel.instance.stop();
    clearSessionCaches();
    await storage.clear();
  }

  void clearSessionCaches() {
    // As cópias (rota, conferência, lista) só são apagadas sem ação
    // pendente: com ela, o entregador precisa delas ao entrar de novo.
    activeRoutes.clearSessionData();
    final keepOffline = apiClient.offlineRequests.pendingCount > 0;
    waves.clearSessionData(keepOffline: keepOffline);
    if (!keepOffline) {
      unawaited(orders.clearStoredCopies());
      unawaited(sync.clearSession());
    }
    // A fila nunca é apagada aqui: o que ficou pendente continua no
    // aparelho e é enviado quando o mesmo entregador entrar.
    syncReporter.resetSession();
    unawaited(apiClient.offlineRequests.reloadSession());
    orders.invalidateCache();
    profile.invalidateCache();
    activeWave.clearSessionData(keepOffline: keepOffline);
    driverOverview.invalidateCache();
    notifications.clearCache();
    unawaited(storage.clearOpenActiveRoute());
  }
}
