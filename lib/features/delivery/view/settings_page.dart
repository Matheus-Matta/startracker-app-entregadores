import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/notifications/app_notification_manager.dart';
import '../../../core/notifications/notification_preferences.dart';
import '../../../core/realtime/fleet_realtime_channel.dart';
import '../../auth/data/profile_service.dart';
import '../../auth/data/auth_service.dart';
import '../../auth/data/delivery_configuration.dart';
import '../../auth/view/login_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({this.isActive = true, super.key});

  final bool isActive;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<DeliveryProfile> _profile;
  NotificationPreferences _notificationPreferences =
      NotificationPreferences.defaults;
  bool _loadingNotificationPreferences = true;
  DriverAvailability? _availability;
  bool _loadingAvailability = false;
  String? _availabilityError;

  @override
  void initState() {
    super.initState();
    final dependencies = AppDependencies.instance;
    _profile = dependencies.profile.getProfile();
    _loadNotificationPreferences();
    _refreshAvailability();
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) _refreshAvailability();
  }

  Future<void> _refreshAvailability() async {
    if (_loadingAvailability) return;
    setState(() {
      _loadingAvailability = true;
      _availabilityError = null;
    });
    try {
      final config = await AppDependencies.instance.auth.deliveryConfig(
        refresh: true,
      );
      if (!mounted) return;
      setState(() {
        _availability = DriverAvailability.fromConfiguration(config);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _availabilityError =
              'Não foi possível atualizar sua disponibilidade.';
        });
      }
    } finally {
      if (mounted) setState(() => _loadingAvailability = false);
    }
  }

  Future<void> _updateAvailability(String value) async {
    final availability = _availability;
    if (availability == null || _loadingAvailability) return;
    setState(() {
      _loadingAvailability = true;
      _availabilityError = null;
    });
    try {
      final updated = await AppDependencies.instance.auth.updateAvailability(
        availability,
        value,
      );
      if (mounted) setState(() => _availability = updated);
    } on AuthException catch (error) {
      if (mounted) setState(() => _availabilityError = error.message);
    } finally {
      if (mounted) setState(() => _loadingAvailability = false);
    }
  }

  Future<void> _loadNotificationPreferences() async {
    final preferences = await AppDependencies.instance.storage
        .readNotificationPreferences();
    if (!mounted) return;
    setState(() {
      _notificationPreferences = preferences;
      _loadingNotificationPreferences = false;
    });
  }

  Future<void> _updateNotificationPreferences(
    NotificationPreferences preferences,
  ) async {
    setState(() => _notificationPreferences = preferences);
    await AppNotificationManager.instance.updatePreferences(
      preferences,
      requestPermissionIfNeeded: true,
    );
  }

  Future<void> _logout() async {
    final dependencies = AppDependencies.instance;
    await AppNotificationManager.instance.stop();
    await FleetRealtimeChannel.instance.stop();
    dependencies.clearSessionCaches();
    await dependencies.storage.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      children: [
        const Text(
          'Configurações',
          style: TextStyle(
            color: Color(0xFF171713),
            fontSize: 28,
            fontWeight: FontWeight.w900,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Seu perfil e preferências do aplicativo',
          style: TextStyle(color: Color(0xFF858279), fontSize: 13),
        ),
        const SizedBox(height: 20),
        FutureBuilder<DeliveryProfile>(
          future: _profile,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _Panel(
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final profile = snapshot.data;
            return _Panel(
              child: Column(
                children: [
                  const CircleAvatar(
                    radius: 32,
                    backgroundColor: Color(0xFFF8E94E),
                    child: Icon(
                      Icons.person_rounded,
                      color: Colors.black,
                      size: 34,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    profile?.name ?? 'Entregador',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    profile?.accountName ??
                        'Não foi possível carregar o perfil',
                    style: const TextStyle(
                      color: Color(0xFF858279),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _ProfileRow(
                    icon: Icons.badge_outlined,
                    label: 'Usuário',
                    value: profile?.username ?? '—',
                  ),
                  const Divider(height: 24),
                  _ProfileRow(
                    icon: Icons.mail_outline_rounded,
                    label: 'E-mail',
                    value: profile?.email ?? '—',
                  ),
                ],
              ),
            );
          },
        ),
        if (_availability?.canEdit == true) ...[
          const SizedBox(height: 14),
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Disponibilidade',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Defina se você pode receber novas cargas automáticas.',
                  style: TextStyle(color: Color(0xFF858279), fontSize: 11),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  key: ValueKey(_availability?.value),
                  initialValue:
                      _availability!.options.any(
                        (option) => option.value == _availability!.value,
                      )
                      ? _availability!.value
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFFF5F3ED),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: _loadingAvailability
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                  items: [
                    for (final option in _availability!.options)
                      DropdownMenuItem(
                        value: option.value,
                        child: Text(option.label),
                      ),
                  ],
                  onChanged:
                      _loadingAvailability || !_availability!.canBeChanged
                      ? null
                      : (value) {
                          if (value != null && value != _availability!.value) {
                            _updateAvailability(value);
                          }
                        },
                ),
                if (_availabilityError case final error?) ...[
                  const SizedBox(height: 8),
                  Text(
                    error,
                    style: const TextStyle(
                      color: Color(0xFFB42318),
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Notificações',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              _NotificationSwitch(
                title: 'Novas cargas',
                subtitle: 'Avisar quando uma carga for liberada',
                value: _notificationPreferences.newWaves,
                onChanged: _loadingNotificationPreferences
                    ? null
                    : (value) => _updateNotificationPreferences(
                        _notificationPreferences.copyWith(newWaves: value),
                      ),
              ),
              _NotificationSwitch(
                title: 'Alterações de rota',
                subtitle: 'Mudanças de paradas e sequência',
                value: _notificationPreferences.routeChanges,
                onChanged: _loadingNotificationPreferences
                    ? null
                    : (value) => _updateNotificationPreferences(
                        _notificationPreferences.copyWith(routeChanges: value),
                      ),
              ),
              _NotificationSwitch(
                title: 'Atualizações de pedidos',
                subtitle: 'Status e observações dos pedidos',
                value: _notificationPreferences.orderUpdates,
                onChanged: _loadingNotificationPreferences
                    ? null
                    : (value) => _updateNotificationPreferences(
                        _notificationPreferences.copyWith(orderUpdates: value),
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: _logout,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Sair da conta'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            foregroundColor: const Color(0xFF171713),
            side: const BorderSide(color: Color(0xFFD8D5CC)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
      side: const BorderSide(color: Color(0xFFE8E5DC)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20),
      const SizedBox(width: 12),
      Expanded(
        child: Text(label, style: const TextStyle(color: Color(0xFF858279))),
      ),
      Flexible(
        child: Text(
          value,
          textAlign: TextAlign.right,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    ],
  );
}

class _NotificationSwitch extends StatelessWidget {
  const _NotificationSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    ),
    subtitle: Text(
      subtitle,
      style: const TextStyle(fontSize: 11, color: Color(0xFF858279)),
    ),
    value: value,
    activeThumbColor: Colors.black,
    activeTrackColor: const Color(0xFFF8E94E),
    onChanged: onChanged,
  );
}
