import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/async/debouncer.dart';
import '../../../core/notifications/app_notification_manager.dart';
import '../../../core/realtime/notification_realtime_channel.dart';
import '../data/notification_service.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({this.isActive = true, super.key});

  final bool isActive;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  late final NotificationService _service;
  late Future<List<DeliveryNotification>> _notifications;
  StreamSubscription<DeliveryNotification>? _realtimeSubscription;
  StreamSubscription<void>? _connectionSubscription;
  final Debouncer _realtimeDebouncer = Debouncer(
    const Duration(milliseconds: 180),
  );
  bool _realtimeDirty = false;
  bool _markingAll = false;

  @override
  void initState() {
    super.initState();
    _service = AppDependencies.instance.notifications;
    _notifications = _service.getNotifications();
    _realtimeSubscription = AppNotificationManager.instance.personalEvents
        .listen((_) {
          _realtimeDirty = true;
          if (widget.isActive) _scheduleRealtimeReload();
        });
    _connectionSubscription = NotificationRealtimeChannel.instance.connections
        .listen((_) {
          // O REST reconcilia notificacoes que podem ter sido perdidas durante
          // background, troca de rede ou morte do processo.
          _realtimeDirty = true;
          if (widget.isActive) _scheduleRealtimeReload();
        });
  }

  @override
  void didUpdateWidget(covariant NotificationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive && _realtimeDirty) {
      _scheduleRealtimeReload();
    }
  }

  @override
  void dispose() {
    _realtimeDebouncer.dispose();
    _realtimeSubscription?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }

  void _scheduleRealtimeReload() {
    _realtimeDebouncer.run(() {
      if (!mounted || !widget.isActive || !_realtimeDirty) return;
      _realtimeDirty = false;
      unawaited(_reload());
    });
  }

  Future<void> _reload() async {
    final next = _service.getNotifications();
    setState(() => _notifications = next);
    await next;
  }

  Future<void> _markRead(DeliveryNotification notification) async {
    if (notification.isRead) return;
    try {
      await _service.markRead(notification.id);
      NotificationRealtimeChannel.instance.markRead(notification.id);
      await _reload();
    } on NotificationServiceException catch (error) {
      if (mounted) _message(error.message);
    }
  }

  Future<void> _markAllRead() async {
    if (_markingAll) return;
    setState(() => _markingAll = true);
    try {
      await _service.markAllRead();
      NotificationRealtimeChannel.instance.markAllRead();
      await _reload();
    } on NotificationServiceException catch (error) {
      if (mounted) _message(error.message);
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  void _message(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<DeliveryNotification>>(
        future: _notifications,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _MessageState(
              icon: Icons.cloud_off_rounded,
              title: 'Não foi possível carregar as notificações',
              message: 'Verifique sua conexão e tente novamente.',
              onRetry: _reload,
            );
          }
          final notifications = snapshot.data ?? const [];
          if (notifications.isEmpty) {
            return _MessageState(
              icon: Icons.notifications_none_rounded,
              title: 'Nenhuma notificação',
              message: 'Novas cargas e atualizações aparecerão aqui.',
              onRetry: _reload,
            );
          }
          final unread = notifications.where((item) => !item.isRead).length;
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        unread == 0
                            ? 'Tudo em dia'
                            : '$unread não lida${unread == 1 ? '' : 's'}',
                        style: const TextStyle(
                          color: Color(0xFF77746C),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: unread == 0 || _markingAll
                          ? null
                          : _markAllRead,
                      icon: const Icon(Icons.done_all_rounded, size: 18),
                      label: const Text('Marcar todas como lidas'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...notifications.map(
                  (notification) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _NotificationCard(
                      notification: notification,
                      onTap: () => _markRead(notification),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({required this.notification, required this.onTap});

  final DeliveryNotification notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: notification.isRead ? Colors.white : const Color(0xFFFFFDE8),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(
        color: notification.isRead
            ? const Color(0xFFE8E5DC)
            : const Color(0xFFF0DD32),
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _levelColor(notification.level),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(_notificationIcon(notification.icon), size: 23),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          notification.title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      if (!notification.isRead)
                        Container(
                          width: 9,
                          height: 9,
                          margin: const EdgeInsets.only(left: 8, top: 4),
                          decoration: const BoxDecoration(
                            color: Color(0xFFFF4D0A),
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  if (notification.message.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      notification.message,
                      style: const TextStyle(
                        color: Color(0xFF5F5D57),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                  if (notification.createdAt != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _dateLabel(notification.createdAt!),
                      style: const TextStyle(
                        color: Color(0xFF918E85),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  static Color _levelColor(String level) => switch (level) {
    'error' => const Color(0xFFFFDAD6),
    'warning' => const Color(0xFFFFE8B2),
    'success' => const Color(0xFFD8F3DC),
    _ => const Color(0xFFF8E94E),
  };

  static IconData _notificationIcon(String icon) => switch (icon) {
    'local_shipping' => Icons.local_shipping_rounded,
    'route' => Icons.route_rounded,
    'inventory_2' => Icons.inventory_2_rounded,
    'warning' => Icons.warning_amber_rounded,
    'check_circle' => Icons.check_circle_rounded,
    _ => Icons.notifications_rounded,
  };

  static String _dateLabel(DateTime date) {
    final local = date.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} · '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.fromLTRB(36, 100, 36, 24),
    children: [
      Icon(icon, size: 50, color: const Color(0xFF858279)),
      const SizedBox(height: 14),
      Text(
        title,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 6),
      Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFF858279),
          fontSize: 12,
          height: 1.4,
        ),
      ),
      if (onRetry != null) ...[
        const SizedBox(height: 14),
        Center(
          child: TextButton(
            onPressed: onRetry,
            child: const Text('Tentar novamente'),
          ),
        ),
      ],
    ],
  );
}
