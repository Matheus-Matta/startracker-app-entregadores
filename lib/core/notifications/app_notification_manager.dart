import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../app/app_dependencies.dart';
import '../../features/notifications/data/notification_service.dart';
import '../config/app_config.dart';
import '../network/offline_request_queue.dart';
import '../realtime/fleet_realtime_channel.dart';
import '../realtime/notification_realtime_channel.dart';
import '../storage/session_storage.dart';
import 'notification_preferences.dart';
import 'own_activity_filter.dart';

class AppNotificationManager {
  AppNotificationManager({
    this.storage = const SessionStorage(),
    FlutterLocalNotificationsPlugin? localNotifications,
    FleetRealtimeChannel? fleetChannel,
    NotificationRealtimeChannel? notificationChannel,
    this.ownActions,
    OwnActivityFilter? ownActivity,
    this.fleetNoticeDelay = const Duration(seconds: 4),
  }) : _ownActivity = ownActivity ?? OwnActivityFilter(),
       _localNotifications =
           localNotifications ?? FlutterLocalNotificationsPlugin(),
       _fleetChannel = fleetChannel ?? FleetRealtimeChannel.instance,
       _notificationChannel =
           notificationChannel ?? NotificationRealtimeChannel.instance;

  static final AppNotificationManager instance = AppNotificationManager(
    storage: AppDependencies.instance.storage,
  );

  final SessionStorage storage;
  final FlutterLocalNotificationsPlugin _localNotifications;
  final FleetRealtimeChannel _fleetChannel;
  final NotificationRealtimeChannel _notificationChannel;

  /// Ações do próprio entregador (fila de sincronização).
  final Stream<OfflineQueueEvent>? ownActions;
  final OwnActivityFilter _ownActivity;

  /// Espera antes de decidir um aviso de rota/pedido: o evento do servidor
  /// pode chegar antes da resposta da ação que o causou.
  final Duration fleetNoticeDelay;
  StreamSubscription<OfflineQueueEvent>? _ownActionsSubscription;
  final StreamController<DeliveryNotification> _personalEvents =
      StreamController<DeliveryNotification>.broadcast();

  StreamSubscription<FleetRealtimeEvent>? _fleetSubscription;
  StreamSubscription<DeliveryNotification>? _notificationSubscription;
  NotificationPreferences _preferences = NotificationPreferences.defaults;
  bool _started = false;

  /// Muda a cada start/stop: um start antigo que ainda lia as preferências
  /// ou um aviso atrasado da sessão anterior não age na sessão nova.
  int _generation = 0;
  bool _localInitialized = false;

  Stream<DeliveryNotification> get personalEvents => _personalEvents.stream;
  NotificationPreferences get preferences => _preferences;

  Future<void> start() async {
    if (_started || !AppConfig.notificationsEnabled) return;
    _started = true;
    final generation = ++_generation;
    final preferences = await storage.readNotificationPreferences();
    if (!_started || generation != _generation) return;
    _preferences = preferences;

    _ownActionsSubscription =
        (ownActions ??
                AppDependencies.instance.apiClient.offlineRequests.events)
            .listen(_ownActivity.record);
    _fleetSubscription = _fleetChannel.events.listen(_onFleetEvent);
    _notificationSubscription = _notificationChannel.events.listen(
      _onPersonalNotification,
    );
    unawaited(_notificationChannel.start());

    await _initializeLocalNotifications();
    if (_started && generation == _generation && _preferences.anyEnabled) {
      await requestPermission();
    }
  }

  Future<void> stop() async {
    _started = false;
    _generation++;
    _ownActivity.clear();
    await Future.wait([
      if (_ownActionsSubscription != null) _ownActionsSubscription!.cancel(),
      if (_fleetSubscription != null) _fleetSubscription!.cancel(),
      if (_notificationSubscription != null)
        _notificationSubscription!.cancel(),
      _notificationChannel.stop(),
    ]);
    _ownActionsSubscription = null;
    _fleetSubscription = null;
    _notificationSubscription = null;
  }

  Future<void> updatePreferences(
    NotificationPreferences preferences, {
    bool requestPermissionIfNeeded = false,
  }) async {
    _preferences = preferences;
    await storage.saveNotificationPreferences(preferences);
    if (requestPermissionIfNeeded && preferences.anyEnabled) {
      await _initializeLocalNotifications();
      await requestPermission();
    }
  }

  Future<bool?> requestPermission() async {
    if (!_localInitialized) return null;
    return _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  Future<void> _initializeLocalNotifications() async {
    if (_localInitialized || !_supportsNativeNotifications) return;
    try {
      await _localNotifications.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_delivery'),
        ),
      );
      final android = _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          AppConfig.notificationChannelId,
          AppConfig.notificationChannelName,
          description: AppConfig.notificationChannelDescription,
          importance: Importance.high,
        ),
      );
      _localInitialized = true;
    } catch (_) {
      // A central interna e o WebSocket continuam funcionando mesmo quando o
      // sistema operacional não disponibiliza notificações nativas.
    }
  }

  bool get _supportsNativeNotifications =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void _onPersonalNotification(DeliveryNotification notification) {
    if (!_personalEvents.isClosed) _personalEvents.add(notification);
    if (!_shouldShowPersonal(notification)) return;
    unawaited(
      _show(
        id: notification.id,
        title: notification.title,
        body: notification.message,
        payload: jsonEncode({
          'notification_id': notification.id,
          'kind': notification.kind,
          if (notification.data['wave_id'] != null)
            'wave_id': notification.data['wave_id'],
          if (notification.data['route_id'] != null)
            'route_id': notification.data['route_id'],
          if (notification.data['order_id'] != null)
            'order_id': notification.data['order_id'],
        }),
      ),
    );
  }

  bool _shouldShowPersonal(DeliveryNotification notification) {
    if (notification.kind == 'wave_assigned') return _preferences.newWaves;
    if (notification.data.containsKey('route_id')) {
      return _preferences.routeChanges;
    }
    if (notification.data.containsKey('order_id')) {
      return _preferences.orderUpdates;
    }
    return _preferences.anyEnabled;
  }

  void _onFleetEvent(FleetRealtimeEvent event) {
    if (!event.isRouteChange && !event.isOrderChange) return;
    final generation = _generation;
    unawaited(
      Future<void>.delayed(
        fleetNoticeDelay,
        () => _noticeFleetEvent(event, generation),
      ),
    );
  }

  void _noticeFleetEvent(FleetRealtimeEvent event, int generation) {
    if (!_started || generation != _generation) return;
    if (event.isRouteChange &&
        _preferences.routeChanges &&
        !_ownActivity.isOwn('route', event.routeId)) {
      final route = _displayIdentifier(
        event.data,
        keys: const ['route_number', 'number', 'name'],
        fallbackId: event.routeId,
      );
      unawaited(
        _show(
          id: _eventId('route', event.routeId),
          title: event.type == 'delivery_route_remove'
              ? 'Rota removida'
              : 'Rota atualizada',
          body: route == null
              ? 'A sequência ou o trajeto da sua rota mudou.'
              : '$route recebeu uma atualização.',
          payload: jsonEncode({'route_id': event.routeId}),
        ),
      );
    }
    if (event.isOrderChange &&
        _preferences.orderUpdates &&
        !_ownActivity.isOwn('order', event.orderId)) {
      final order = _displayIdentifier(
        event.data,
        keys: const ['order_number', 'number', 'name'],
        fallbackId: event.orderId,
      );
      unawaited(
        _show(
          id: _eventId('order', event.orderId),
          title: event.type == 'delivery_order_remove'
              ? 'Pedido removido'
              : 'Pedido atualizado',
          body: order == null
              ? 'Um pedido da sua operação recebeu uma atualização.'
              : '$order recebeu uma atualização.',
          payload: jsonEncode({'order_id': event.orderId}),
        ),
      );
    }
  }

  Future<void> _show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    if (!_started || !_localInitialized || body.trim().isEmpty) return;
    try {
      await _localNotifications.show(
        id: id & 0x7fffffff,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            AppConfig.notificationChannelId,
            AppConfig.notificationChannelName,
            channelDescription: AppConfig.notificationChannelDescription,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.status,
            visibility: NotificationVisibility.private,
          ),
        ),
      );
    } catch (_) {
      // Falhas do SO não devem interromper atualizações em tempo real no app.
    }
  }

  static String? _displayIdentifier(
    Map<String, dynamic> data, {
    required List<String> keys,
    required int? fallbackId,
  }) {
    for (final key in keys) {
      final value = data[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return fallbackId == null ? null : '#$fallbackId';
  }

  // Um mesmo recurso substitui o aviso anterior em vez de acumular dezenas de
  // notificações durante uma sequência de atualizações do backend.
  static int _eventId(String resource, int? id) => Object.hash(resource, id);
}
