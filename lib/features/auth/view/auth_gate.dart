import 'package:flutter/material.dart';
import '../../../core/presentation/app_messages.dart';

import '../../../app/app_dependencies.dart';
import '../../delivery/view/delivery_page.dart';
import '../../waves/data/delivery_photo_recovery.dart';
import '../../waves/view/delivery_completion_page.dart';
import '../data/auth_service.dart';
import 'login_page.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final Future<_AuthBootstrap> _session;

  @override
  void initState() {
    super.initState();
    _session = _restoreSafely(AppDependencies.instance.auth);
  }

  Future<_AuthBootstrap> _restoreSafely(AuthService authService) async {
    try {
      final loggedIn = await authService.restoreSession();
      if (loggedIn) await authService.deliveryConfig(refresh: true);
      final recovery = await DeliveryPhotoRecovery(
        AppDependencies.instance.storage,
      ).recoverLostCapture();
      return _AuthBootstrap(loggedIn: loggedIn, recovery: recovery);
    } catch (_) {
      return const _AuthBootstrap(loggedIn: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_AuthBootstrap>(
      future: _session,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            backgroundColor: Colors.white,
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF020617)),
            ),
          );
        }
        final bootstrap = snapshot.data;
        if (bootstrap?.loggedIn != true) return const LoginPage();
        final recovery = bootstrap?.recovery;
        return recovery == null
            ? const DeliveryPage()
            : _RecoveredDeliveryLauncher(capture: recovery);
      },
    );
  }
}

class _AuthBootstrap {
  const _AuthBootstrap({required this.loggedIn, this.recovery});

  final bool loggedIn;
  final RecoveredDeliveryCapture? recovery;
}

class _RecoveredDeliveryLauncher extends StatefulWidget {
  const _RecoveredDeliveryLauncher({required this.capture});

  final RecoveredDeliveryCapture capture;

  @override
  State<_RecoveredDeliveryLauncher> createState() =>
      _RecoveredDeliveryLauncherState();
}

class _RecoveredDeliveryLauncherState
    extends State<_RecoveredDeliveryLauncher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openRecovery());
  }

  Future<void> _openRecovery() async {
    final dependencies = AppDependencies.instance;
    try {
      final route = await dependencies.activeRoutes.getRoute(
        widget.capture.draft.routeId,
      );
      final stop = route.stops.firstWhere(
        (item) => item.stopId == widget.capture.draft.stopId,
      );
      if (!mounted) return;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => DeliveryCompletionPage(
            routeId: route.routeId,
            stop: stop,
            service: dependencies.activeRoutes,
            recoveredCapture: widget.capture,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      showAppMessage(
        context,
        'A foto foi recuperada, mas a entrega nao pode ser carregada agora.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => const DeliveryPage();
}
