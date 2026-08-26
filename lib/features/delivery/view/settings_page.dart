import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/notifications/app_notification_manager.dart';
import '../../../core/notifications/notification_preferences.dart';
import '../../../core/realtime/fleet_realtime_channel.dart';
import '../../auth/data/profile_service.dart';
import '../../auth/view/login_page.dart';
import '../../waves/data/pickup_label_scope.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<DeliveryProfile> _profile;
  NotificationPreferences _notificationPreferences =
      NotificationPreferences.defaults;
  bool _loadingNotificationPreferences = true;
  PickupLabelScope _labelScope = PickupLabelScope.fallback;

  @override
  void initState() {
    super.initState();
    final dependencies = AppDependencies.instance;
    _profile = dependencies.profile.getProfile();
    _loadNotificationPreferences();
    _loadLabelScope();
  }

  Future<void> _loadLabelScope() async {
    final stored = await AppDependencies.instance.storage
        .readPickupLabelScope();
    if (!mounted) return;
    setState(() => _labelScope = PickupLabelScope.fromStorage(stored));
  }

  Future<void> _updateLabelScope(PickupLabelScope scope) async {
    setState(() => _labelScope = scope);
    await AppDependencies.instance.storage.savePickupLabelScope(
      scope.storageValue,
    );
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
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Retirada',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 2),
              const Text(
                'O que uma leitura confirma na conferência da carga',
                style: TextStyle(color: Color(0xFF858279), fontSize: 12),
              ),
              const SizedBox(height: 8),
              ...PickupLabelScope.values.map(
                (scope) => _LabelScopeTile(
                  scope: scope,
                  selected: scope == _labelScope,
                  onTap: () => _updateLabelScope(scope),
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

class _LabelScopeTile extends StatelessWidget {
  const _LabelScopeTile({
    required this.scope,
    required this.selected,
    required this.onTap,
  });

  final PickupLabelScope scope;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      selected
          ? Icons.radio_button_checked_rounded
          : Icons.radio_button_unchecked_rounded,
      color: selected ? const Color(0xFF171713) : const Color(0xFF858279),
    ),
    title: Text(
      scope.label,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
    ),
    subtitle: Text(
      scope.description,
      style: const TextStyle(color: Color(0xFF858279), fontSize: 12),
    ),
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
