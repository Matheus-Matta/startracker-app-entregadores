import 'dart:async';

import 'package:flutter/material.dart';
import '../../../core/presentation/app_messages.dart';

import '../../../app/app_dependencies.dart';
import '../../delivery/view/delivery_page.dart';
import '../../waves/data/delivery_photo_recovery.dart';
import '../../waves/view/active_wave_page.dart';
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
      final dependencies = AppDependencies.instance;
      final loggedIn = await authService.restoreSession();
      if (!loggedIn) return const _AuthBootstrap(loggedIn: false);
      await authService.deliveryConfig(refresh: true);
      // Requisições que falharam sem rede antes do app ser fechado voltam
      // para a fila e são reenviadas automaticamente.
      unawaited(dependencies.apiClient.offlineRequests.restorePersisted());
      final recovery = await DeliveryPhotoRecovery(
        dependencies.storage,
      ).recoverLostCapture();
      final openRouteId = await dependencies.storage.readOpenActiveRoute();
      return _AuthBootstrap(
        loggedIn: true,
        recovery: recovery,
        openRouteId: openRouteId,
      );
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
        if (recovery != null) {
          return _RecoveredDeliveryLauncher(capture: recovery);
        }
        final openRouteId = bootstrap?.openRouteId;
        if (openRouteId != null) {
          return _OpenRouteLauncher(routeId: openRouteId);
        }
        return const DeliveryPage();
      },
    );
  }
}

class _AuthBootstrap {
  const _AuthBootstrap({
    required this.loggedIn,
    this.recovery,
    this.openRouteId,
  });

  final bool loggedIn;
  final RecoveredDeliveryCapture? recovery;
  final int? openRouteId;
}

/// Reabre o mapa da carga quando o sistema encerrou o app com ele aberto
/// (por exemplo, por falta de memória durante a câmera).
class _OpenRouteLauncher extends StatefulWidget {
  const _OpenRouteLauncher({required this.routeId});

  final int routeId;

  @override
  State<_OpenRouteLauncher> createState() => _OpenRouteLauncherState();
}

class _OpenRouteLauncherState extends State<_OpenRouteLauncher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    final dependencies = AppDependencies.instance;
    try {
      final route = await dependencies.activeRoutes.getRoute(widget.routeId);
      if (route.currentStop == null ||
          const {'completed', 'cancelled'}.contains(route.status)) {
        await dependencies.storage.clearOpenActiveRoute();
        return;
      }
    } catch (_) {
      // Sem rede a própria tela do mapa mostra o erro e permite tentar de novo.
    }
    if (!mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ActiveWavePage(routeId: widget.routeId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const DeliveryPage();
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
    final routeId = widget.capture.draft.routeId;
    try {
      final route = await dependencies.activeRoutes.getRoute(routeId);
      final stop = route.stops.firstWhere(
        (item) => item.stopId == widget.capture.draft.stopId,
      );
      if (!mounted) return;
      final completed = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => DeliveryCompletionPage(
            routeId: route.routeId,
            stop: stop,
            service: dependencies.activeRoutes,
            recoveredCapture: widget.capture,
          ),
        ),
      );
      if (!mounted || completed != true) return;
      // Depois de finalizar, volta ao mapa da carga se ainda houver pedidos.
      final updated = await dependencies.activeRoutes.getRoute(routeId);
      final hasRemaining = updated.stops.any(
        (item) => !item.isTerminal && item.stopId != stop.stopId,
      );
      if (!mounted || !hasRemaining) return;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => ActiveWavePage(routeId: routeId),
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
