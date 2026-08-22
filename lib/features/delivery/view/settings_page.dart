import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/session_storage.dart';
import '../../auth/data/profile_service.dart';
import '../../auth/view/login_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<DeliveryProfile> _profile;
  bool _newWaves = true;
  bool _routeChanges = true;
  bool _orderUpdates = false;

  @override
  void initState() {
    super.initState();
    const storage = SessionStorage();
    _profile = ProfileService(
      ApiClient(baseUrl: AppConfig.backendUrl, storage: storage),
    ).getProfile();
  }

  Future<void> _logout() async {
    await const SessionStorage().clear();
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
                title: 'Novas waves',
                subtitle: 'Avisar quando uma wave for liberada',
                value: _newWaves,
                onChanged: (value) => setState(() => _newWaves = value),
              ),
              _NotificationSwitch(
                title: 'Alterações de rota',
                subtitle: 'Mudanças de paradas e sequência',
                value: _routeChanges,
                onChanged: (value) => setState(() => _routeChanges = value),
              ),
              _NotificationSwitch(
                title: 'Atualizações de pedidos',
                subtitle: 'Status e observações dos pedidos',
                value: _orderUpdates,
                onChanged: (value) => setState(() => _orderUpdates = value),
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
  final ValueChanged<bool> onChanged;

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
