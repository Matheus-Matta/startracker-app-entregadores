import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/network/offline_request_queue.dart';
import '../../../core/presentation/app_messages.dart';
import '../../orders/view/order_detail_page.dart';
import '../data/wave_service.dart';
import 'active_wave_page.dart';
import 'pickup_page.dart';

const _ink = Color(0xFF171713);
const _cream = Color(0xFFF5F3ED);
const _yellow = Color(0xFFF8E94E);
const _muted = Color(0xFF858279);

class WaveDetailPage extends StatefulWidget {
  const WaveDetailPage({required this.wave, super.key});

  final WaveListItem wave;

  @override
  State<WaveDetailPage> createState() => _WaveDetailPageState();
}

class _WaveDetailPageState extends State<WaveDetailPage> {
  late final WaveService _service;
  late Future<WaveDetails> _details;
  late WaveListItem _currentWave;
  late String _currentStatus;
  PickupProgress? _pickupProgress;
  bool _startingRoute = false;
  StreamSubscription<OfflineQueueEvent>? _offlineQueueSubscription;

  static const _statusLabels = <String, String>{
    'collecting': 'Carga em montagem',
    'ready': 'Pronta para roteirizar',
    'optimizing': 'Roteirizando',
    'failed': 'Falha na roteirização',
    'planned': 'Planejada',
    'released': 'Liberada',
    'accepted': 'Aceita',
    'started': 'Em andamento',
    'completed': 'Concluída',
    'partially_completed': 'Parcialmente concluída',
    'closed': 'Encerrada',
    'cancelled': 'Cancelada',
    'superseded': 'Substituída',
  };

  @override
  void initState() {
    super.initState();
    _service = AppDependencies.instance.waves;
    _currentWave = widget.wave;
    _currentStatus = _currentWave.status;
    _details = _loadDetails();
    _offlineQueueSubscription = AppDependencies
        .instance
        .apiClient
        .offlineRequests
        .events
        .listen(_onOfflineQueueEvent);
  }

  @override
  void dispose() {
    _offlineQueueSubscription?.cancel();
    super.dispose();
  }

  Future<WaveDetails> _loadDetails() {
    final request = _service.getWaveDetails(_currentWave);
    request.then<void>((details) {
      if (mounted) {
        setState(() {
          _currentStatus = details.status;
          _pickupProgress = details.pickup;
        });
      }
    }, onError: (Object _, StackTrace _) {});
    return request;
  }

  Future<void> _refresh() async {
    final nextDetails = _loadDetails();
    setState(() {
      _details = nextDetails;
    });
    try {
      await nextDetails;
    } catch (_) {
      // O FutureBuilder apresenta o estado de erro na própria página.
    }
  }

  Future<void> _startRoute() async {
    if (_startingRoute || !_canStart) return;
    final previousWave = _currentWave;
    final previousStatus = _currentStatus;
    setState(() => _startingRoute = true);
    try {
      PickupProgress latestPickup;
      try {
        latestPickup = await _service.getPickupProgress(_currentWave.waveId);
      } on WaveServiceException {
        final cached = _pickupProgress;
        if (cached == null) rethrow;
        latestPickup = cached;
      }
      if (!mounted) return;
      setState(() => _pickupProgress = latestPickup);
      if (latestPickup.enabled && !latestPickup.isComplete) {
        showAppMessage(
          context,
          'A carga mudou. Confira os pedidos transferidos antes de iniciar.',
        );
        await _openPickup();
        return;
      }
      if (_currentStatus == 'ready') {
        setState(() => _currentStatus = 'optimizing');
        final result = await _service.optimizeAndRelease(_currentWave);
        if (!mounted) return;
        if (result.queued) {
          _message('Sem internet. Preparacao da carga salva para envio.');
          return;
        }
        final prepared = result.value!;
        setState(() {
          _currentWave = prepared;
          _currentStatus = prepared.status;
        });
      }
      final routeId = _currentWave.routeId;
      if (routeId == null) {
        throw const WaveServiceException(
          'Esta carga ainda não possui uma rota para iniciar.',
        );
      }
      setState(() => _currentStatus = 'started');
      final startResult = await _service.startRoute(routeId);
      if (!mounted) return;
      if (startResult.queued) {
        _message('Sem internet. Inicio da rota salvo para envio automatico.');
        return;
      }
      showAppMessage(context, 'Rota iniciada com sucesso.');
      await _openActiveRoute();
    } on WaveServiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _currentWave = previousWave;
        _currentStatus = previousStatus;
      });
      showAppMessage(context, error.message);
      unawaited(_refresh());
    } finally {
      if (mounted) setState(() => _startingRoute = false);
    }
  }

  void _onOfflineQueueEvent(OfflineQueueEvent event) {
    final routeId = _currentWave.routeId;
    final affectsCurrent =
        event.resourceKey == 'wave:${_currentWave.waveId}' ||
        (routeId != null && event.resourceKey == 'route:$routeId');
    if (!affectsCurrent || event.type == OfflineQueueEventType.queued) return;
    if (event.type == OfflineQueueEventType.rejected) {
      _message('A API recusou a alteracao offline. O estado foi restaurado.');
    }
    unawaited(_refresh());
  }

  void _message(String text) {
    if (!mounted) return;
    showAppMessage(context, text);
  }

  Future<void> _openActiveRoute() async {
    final routeId = _currentWave.routeId;
    if (routeId == null) return;
    final openHome = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => ActiveWavePage(routeId: routeId)),
    );
    if (!mounted) return;
    await _refresh();
    if (!mounted) return;
    if (openHome == true) Navigator.of(context).pop(true);
  }

  Future<void> _openPickup() async {
    final progress = _pickupProgress;
    if (progress == null || !progress.enabled) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PickupPage(service: _service, progress: progress),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _openOrder(WaveOrderItem order) async {
    final openHome = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => OrderDetailPage(
          orderId: order.orderId,
          initialNumber: order.orderNumber,
        ),
      ),
    );
    if (!mounted) return;
    if (openHome == true) Navigator.of(context).pop(true);
  }

  bool get _pickupPending =>
      _pickupProgress?.enabled == true && _pickupProgress?.isComplete == false;

  bool get _requiresPickupBeforeStart =>
      _currentStatus != 'started' && _pickupPending;

  bool get _canStart {
    if (!const {
      'ready',
      'planned',
      'released',
      'accepted',
    }.contains(_currentStatus)) {
      return false;
    }
    final pickup = _pickupProgress;
    return pickup != null && (!pickup.enabled || pickup.isComplete);
  }

  bool get _canOpenActive => _currentStatus == 'started';

  String get _buttonLabel {
    if (_currentStatus == 'started') return 'Rota em andamento';
    if (_pickupProgress == null && _canHaveRouteAction) {
      return 'Carregando retirada...';
    }
    if (_requiresPickupBeforeStart) {
      return 'Conferir retirada (${_pickupProgress!.pickedUp}/${_pickupProgress!.total})';
    }
    return switch (_currentStatus) {
      'ready' => 'Roteirizar carga',
      'optimizing' => 'Roteirizando carga',
      'completed' => 'Rota concluída',
      'partially_completed' => 'Rota concluída parcialmente',
      'cancelled' => 'Rota cancelada',
      'superseded' => 'Rota substituída',
      _ => 'Começar a rota',
    };
  }

  bool get _canHaveRouteAction => const {
    'ready',
    'planned',
    'released',
    'accepted',
  }.contains(_currentStatus);

  String get _busyLabel =>
      _currentStatus == 'ready' ? 'Roteirizando...' : 'Iniciando rota...';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      body: SafeArea(
        child: Column(
          children: [
            _DetailHeader(
              waveId: widget.wave.waveId,
              onBack: () => Navigator.of(context).pop(false),
              onHome: () => Navigator.of(context).pop(true),
            ),
            Expanded(
              child: FutureBuilder<WaveDetails>(
                future: _details,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return _ErrorState(onRetry: _refresh);
                  }
                  return _DetailsBody(
                    details: snapshot.data!,
                    onRefresh: _refresh,
                    onOpenOrder: _openOrder,
                    onOpenPickup: _openPickup,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          color: _cream,
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
          child: SizedBox(
            height: 54,
            child: FilledButton.icon(
              onPressed: _startingRoute
                  ? null
                  : _canOpenActive
                  ? _openActiveRoute
                  : _requiresPickupBeforeStart
                  ? _openPickup
                  : _canStart
                  ? _startRoute
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: _ink,
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFD9D7D0),
                disabledForegroundColor: const Color(0xFF89867E),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(17),
                ),
              ),
              icon: _startingRoute
                  ? const SizedBox.square(
                      dimension: 19,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      _canOpenActive
                          ? Icons.navigation_rounded
                          : _requiresPickupBeforeStart
                          ? Icons.qr_code_scanner_rounded
                          : Icons.play_arrow_rounded,
                    ),
              label: Text(
                _startingRoute ? _busyLabel : _buttonLabel,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.waveId,
    required this.onBack,
    required this.onHome,
  });

  final int waveId;
  final VoidCallback onBack;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 60,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            'Carga #$waveId',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: _HeaderButton(
              tooltip: 'Voltar',
              icon: Icons.arrow_back_rounded,
              onPressed: onBack,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: _HeaderButton(
              tooltip: 'Ir para o início',
              icon: Icons.home_rounded,
              onPressed: onHome,
            ),
          ),
        ],
      ),
    ),
  );
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: _yellow,
      minimumSize: const Size(38, 38),
      maximumSize: const Size(38, 38),
      padding: EdgeInsets.zero,
    ),
    icon: Icon(icon, size: 23, color: _ink),
  );
}

class _DetailsBody extends StatelessWidget {
  const _DetailsBody({
    required this.details,
    required this.onRefresh,
    required this.onOpenOrder,
    required this.onOpenPickup,
  });

  final WaveDetails details;
  final Future<void> Function() onRefresh;
  final ValueChanged<WaveOrderItem> onOpenOrder;
  final VoidCallback onOpenPickup;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 26),
      children: [
        _RouteSummary(details: details),
        if (details.pickup.enabled) ...[
          const SizedBox(height: 13),
          _PickupProgressCard(progress: details.pickup, onTap: onOpenPickup),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Pedidos da carga',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ),
            Text(
              '${details.orders.length}',
              style: const TextStyle(
                color: _muted,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 11),
        if (details.orders.isEmpty)
          const _EmptyOrders(message: 'Nenhum pedido nesta carga')
        else
          ...details.orders.map(
            (order) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _OrderCard(
                order: order,
                pickup: details.pickup.enabled
                    ? _pickupOrder(order.orderId)
                    : null,
                onTap: () => onOpenOrder(order),
              ),
            ),
          ),
      ],
    ),
  );

  PickupOrder? _pickupOrder(int orderId) {
    for (final order in details.pickup.orders) {
      if (order.orderId == orderId) return order;
    }
    return null;
  }
}

class _PickupProgressCard extends StatelessWidget {
  const _PickupProgressCard({required this.progress, required this.onTap});

  final PickupProgress progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final value = progress.total == 0
        ? 0.0
        : progress.pickedUp / progress.total;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE4E1D8)),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: progress.isComplete
                          ? const Color(0xFFE9F6E7)
                          : _yellow,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      progress.isComplete
                          ? Icons.check_circle_rounded
                          : Icons.qr_code_scanner_rounded,
                      color: progress.isComplete
                          ? const Color(0xFF238636)
                          : _ink,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          progress.isComplete
                              ? 'Retirada concluída'
                              : 'Conferência da retirada',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${progress.pickedUp} de ${progress.total} pedidos · '
                          '${progress.scannedVolumes} de ${progress.totalVolumes} volumes',
                          style: const TextStyle(color: _muted, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: _muted),
                ],
              ),
              const SizedBox(height: 11),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: LinearProgressIndicator(
                  value: value.clamp(0, 1),
                  minHeight: 7,
                  backgroundColor: _cream,
                  color: progress.isComplete ? const Color(0xFF238636) : _ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RouteSummary extends StatelessWidget {
  const _RouteSummary({required this.details});

  final WaveDetails details;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(19),
    decoration: BoxDecoration(
      color: _yellow,
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [
        BoxShadow(
          color: Color(0x14171713),
          blurRadius: 18,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: _ink,
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Icon(Icons.route_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    details.routeNumber,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _WaveDetailPageState._statusLabels[details.status] ??
                        details.status,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: _Metric(
                icon: Icons.inventory_2_outlined,
                label: 'Pedidos',
                value: '${details.orders.length}',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Metric(
                icon: Icons.straighten_rounded,
                label: 'Distância',
                value: _distance(details.plannedDistanceMeters),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Metric(
                icon: Icons.schedule_rounded,
                label: 'Duração',
                value: _duration(details.plannedDurationSeconds),
              ),
            ),
          ],
        ),
        if (details.plannedStart != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.event_rounded, size: 18),
              const SizedBox(width: 7),
              Text(
                'Início previsto: ${_date(details.plannedStart!)}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );

  String _distance(int meters) =>
      meters <= 0 ? '—' : '${(meters / 1000).toStringAsFixed(1)} km';

  String _duration(int seconds) {
    if (seconds <= 0) return '—';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    return hours > 0 ? '$hours h $minutes min' : '$minutes min';
  }

  String _date(DateTime date) {
    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .7),
      borderRadius: BorderRadius.circular(15),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: _muted, fontSize: 9)),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
        ),
      ],
    ),
  );
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.onTap, this.pickup});

  final WaveOrderItem order;
  final PickupOrder? pickup;
  final VoidCallback onTap;

  static const _statusLabels = <String, String>{
    'created': 'Criado',
    'awaiting_geocode': 'Aguardando endereço',
    'awaiting_pickup': 'Aguardando retirada',
    'waiting_wave': 'Na carga',
    'ready_for_routing': 'Pronto para rota',
    'routing': 'Roteirizando',
    'routed': 'Roteirizado',
    'released': 'Liberado',
    'out_for_delivery': 'Saiu para entrega',
    'delivered': 'Entregue',
    'partially_delivered': 'Parcialmente entregue',
    'delivery_failed': 'Falha na entrega',
    'planned': 'Planejada',
    'approaching': 'Aproximando',
    'arrived': 'Chegou',
    'delivering': 'Entregando',
    'completed': 'Concluída',
    'failed': 'Falhou',
    'skipped': 'Pulada',
    'cancelled': 'Cancelada',
    'manual_assignment': 'Roteirização manual',
  };

  @override
  Widget build(BuildContext context) {
    final locality = [
      order.city,
      order.state,
    ].where((part) => part.isNotEmpty).join('/');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE8E5DC)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _ink,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '${order.sequence}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            order.customerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _StatusBadge(
                          label: pickup == null
                              ? _statusLabels[order.stopStatus] ??
                                    order.stopStatus
                              : pickup!.isPickedUp
                              ? 'Retirado'
                              : pickup!.scannedVolumes > 0
                              ? '${pickup!.scannedVolumes}/${pickup!.totalVolumes} volumes'
                              : 'Aguardando retirada',
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      order.orderNumber,
                      style: const TextStyle(color: _muted, fontSize: 10),
                    ),
                    if (order.address.isNotEmpty || locality.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.location_on_outlined,
                            size: 16,
                            color: _muted,
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              [
                                order.address,
                                locality,
                              ].where((part) => part.isNotEmpty).join(' · '),
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 11,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 7,
                      runSpacing: 6,
                      children: [
                        _SmallInfo(
                          icon: Icons.inventory_2_outlined,
                          label: '${order.units} volumes',
                        ),
                        if (order.weightGrams > 0)
                          _SmallInfo(
                            icon: Icons.monitor_weight_outlined,
                            label: _weight(order.weightGrams),
                          ),
                        if (order.plannedEta != null)
                          _SmallInfo(
                            icon: Icons.schedule_rounded,
                            label: _time(order.plannedEta!),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 5, top: 11),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: _muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _weight(int grams) =>
      grams >= 1000 ? '${(grams / 1000).toStringAsFixed(1)} kg' : '$grams g';

  String _time(DateTime date) {
    final local = date.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: _yellow,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w900),
    ),
  );
}

class _SmallInfo extends StatelessWidget {
  const _SmallInfo({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: _cream,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: _muted),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _EmptyOrders extends StatelessWidget {
  const _EmptyOrders({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 44),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      children: [
        const Icon(Icons.inventory_2_outlined, size: 38, color: _muted),
        const SizedBox(height: 10),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 44, color: _muted),
          const SizedBox(height: 12),
          const Text(
            'Não foi possível carregar esta carga',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: onRetry,
            child: const Text('Tentar novamente'),
          ),
        ],
      ),
    ),
  );
}
