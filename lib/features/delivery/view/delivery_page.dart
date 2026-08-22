import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/paged_result.dart';
import '../../../core/storage/session_storage.dart';
import '../../notifications/view/notifications_page.dart';
import '../../orders/data/order_service.dart';
import '../../orders/view/orders_page.dart';
import '../../waves/view/waves_page.dart';
import '../../waves/view/active_wave_page.dart';
import '../data/active_wave_service.dart';
import '../data/driver_overview_service.dart';
import 'settings_page.dart';

const _ink = Color(0xFF171713);
const _cream = Color(0xFFF5F3ED);
const _yellow = Color(0xFFF8E94E);
const _muted = Color(0xFF858279);

class DeliveryPage extends StatefulWidget {
  const DeliveryPage({super.key});

  @override
  State<DeliveryPage> createState() => _DeliveryPageState();
}

class _DeliveryPageState extends State<DeliveryPage> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      body: SafeArea(
        child: Column(
          children: [
            _AppHeader(
              index: _tabIndex,
              onOpenNotifications: () => setState(() => _tabIndex = 3),
              onOpenProfile: () => setState(() => _tabIndex = 4),
            ),
            Expanded(
              child: IndexedStack(
                index: _tabIndex,
                children: [
                  _HomePage(onOpenProfile: () => setState(() => _tabIndex = 4)),
                  WavesPage(onOpenHome: () => setState(() => _tabIndex = 0)),
                  OrdersPage(onOpenHome: () => setState(() => _tabIndex = 0)),
                  const NotificationsPage(),
                  const SettingsPage(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _BottomNavigation(
        index: _tabIndex,
        onChanged: (index) => setState(() => _tabIndex = index),
      ),
    );
  }
}

class _AppHeader extends StatelessWidget {
  const _AppHeader({
    required this.index,
    required this.onOpenNotifications,
    required this.onOpenProfile,
  });

  final int index;
  final VoidCallback onOpenNotifications;
  final VoidCallback onOpenProfile;

  static const _titles = ['Home', 'Waves', 'Pedidos', 'Notificações', 'Perfil'];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            _titles[index],
            style: const TextStyle(
              color: _ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              onTap: onOpenProfile,
              customBorder: const CircleBorder(),
              child: Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                  color: _yellow,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.person_rounded, size: 23, color: _ink),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              onPressed: onOpenNotifications,
              style: IconButton.styleFrom(
                backgroundColor: _yellow,
                minimumSize: const Size(38, 38),
                maximumSize: const Size(38, 38),
                padding: EdgeInsets.zero,
              ),
              icon: Icon(
                index == 3
                    ? Icons.notifications_rounded
                    : Icons.notifications_none_rounded,
                size: 23,
                color: _ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  static const _destinations = [0, 2, 1, 4];

  static const _labels = ['Home', 'Pedidos', 'Waves', 'Perfil'];

  static const _icons = [
    Icons.home_outlined,
    Icons.inventory_2_outlined,
    Icons.route_outlined,
    Icons.person_outline_rounded,
  ];

  static const _selectedIcons = [
    Icons.home_rounded,
    Icons.inventory_2_rounded,
    Icons.route_rounded,
    Icons.person_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        color: _cream,
        padding: const EdgeInsets.fromLTRB(30, 8, 30, 13),
        child: Container(
          height: 70,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE5E2D9)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1F171713),
                blurRadius: 14,
                offset: Offset(0, 7),
              ),
            ],
          ),
          child: Row(
            children: List.generate(_icons.length, (itemIndex) {
              final destination = _destinations[itemIndex];
              final selected = index == destination;
              return Expanded(
                child: Center(
                  child: Tooltip(
                    message: _labels[itemIndex],
                    child: InkWell(
                      onTap: () => onChanged(destination),
                      customBorder: const CircleBorder(),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 190),
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: selected ? _yellow : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          selected
                              ? _selectedIcons[itemIndex]
                              : _icons[itemIndex],
                          size: 23,
                          color: selected ? _ink : const Color(0xFF999A95),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage({required this.onOpenProfile});

  final VoidCallback onOpenProfile;

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  ActiveWaveService? _activeWaveServiceCache;
  OrderService? _orderServiceCache;
  DriverOverviewService? _driverServiceCache;
  Future<ActiveWave?>? _activeWaveCache;
  Future<PagedResult<OrderListItem>>? _ordersCache;
  Future<DriverOverview>? _driverCache;

  ActiveWaveService get _activeWaveService {
    return _activeWaveServiceCache ??= _createActiveWaveService();
  }

  OrderService get _orderService {
    return _orderServiceCache ??= _createOrderService();
  }

  DriverOverviewService get _driverService {
    return _driverServiceCache ??= _createDriverService();
  }

  Future<ActiveWave?> get _activeWave {
    return _activeWaveCache ??= _activeWaveService.getActiveWave();
  }

  Future<PagedResult<OrderListItem>> get _orders {
    return _ordersCache ??= _orderService.getOrders(page: 1);
  }

  Future<DriverOverview> get _driver {
    return _driverCache ??= _driverService.getOverview();
  }

  ActiveWaveService _createActiveWaveService() {
    const storage = SessionStorage();
    return ActiveWaveService(
      ApiClient(baseUrl: AppConfig.backendUrl, storage: storage),
    );
  }

  OrderService _createOrderService() {
    const storage = SessionStorage();
    return OrderService(
      ApiClient(baseUrl: AppConfig.backendUrl, storage: storage),
    );
  }

  DriverOverviewService _createDriverService() {
    const storage = SessionStorage();
    return DriverOverviewService(
      ApiClient(baseUrl: AppConfig.backendUrl, storage: storage),
    );
  }

  void _reload() {
    setState(() {
      _activeWaveCache = _activeWaveService.getActiveWave();
      _ordersCache = _orderService.getOrders(page: 1);
      _driverCache = _driverService.getOverview();
    });
  }

  Future<void> _openActiveWave(ActiveWave wave) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ActiveWavePage(routeId: wave.routeId),
      ),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 15, 18, 28),
        children: [
          FutureBuilder<DriverOverview>(
            future: _driver,
            builder: (context, snapshot) {
              final driver = snapshot.data;
              final firstName = driver?.name.trim().split(' ').first;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    firstName == null || firstName.isEmpty
                        ? 'Minha operação'
                        : 'Olá, $firstName',
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Painel do entregador',
                    style: TextStyle(
                      color: _ink,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 15),
                  if (snapshot.connectionState != ConnectionState.done)
                    const _DriverCardLoading()
                  else if (snapshot.hasError)
                    _DriverCardError(onRetry: _reload)
                  else
                    _DriverCard(
                      driver: driver!,
                      onOpenProfile: widget.onOpenProfile,
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 23),
          const Row(
            children: [
              Expanded(
                child: Text(
                  'Operação atual',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: _muted),
            ],
          ),
          const SizedBox(height: 11),
          FutureBuilder<ActiveWave?>(
            future: _activeWave,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const _LoadingCard();
              }
              if (snapshot.hasError) {
                return _EmptyWaveCard(
                  icon: Icons.cloud_off_rounded,
                  title: 'Não foi possível consultar a wave',
                  message: 'Verifique sua conexão e tente novamente.',
                  onRetry: _reload,
                );
              }
              final wave = snapshot.data;
              if (wave == null) {
                return const _EmptyWaveCard(
                  icon: Icons.inventory_2_outlined,
                  title: 'Nenhuma wave ativa',
                  message: 'Quando uma wave for liberada, ela aparecerá aqui.',
                );
              }
              return _ActiveWaveCard(
                wave: wave,
                onTap: () => _openActiveWave(wave),
              );
            },
          ),
          const SizedBox(height: 24),
          const Text(
            'Desempenho',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          const Text(
            'Indicadores dos pedidos carregados.',
            style: TextStyle(color: _muted, fontSize: 11),
          ),
          const SizedBox(height: 13),
          FutureBuilder<PagedResult<OrderListItem>>(
            future: _orders,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const _DashboardLoading();
              }
              if (snapshot.hasError) {
                return _DashboardError(onRetry: _reload);
              }
              return _OperationalDashboard(result: snapshot.data!);
            },
          ),
        ],
      ),
    );
  }
}

class _DriverCard extends StatelessWidget {
  const _DriverCard({required this.driver, required this.onOpenProfile});

  final DriverOverview driver;
  final VoidCallback onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final identifier = driver.employeeCode.isNotEmpty
        ? driver.employeeCode
        : driver.username;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF8FFF58), Color(0xFFB9FF91)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A6EDB3E),
            blurRadius: 12,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.contactless_rounded, size: 22, color: _ink),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: driver.active
                      ? const Color(0x26000000)
                      : const Color(0x22CC0000),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  driver.active ? 'ATIVO' : 'INATIVO',
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            driver.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w900,
              letterSpacing: -.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Entregador · $identifier',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 25),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'CONTA',
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        color: Color(0x99000000),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      driver.accountName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (driver.phone.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        driver.phone,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0x99000000),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: onOpenProfile,
                style: FilledButton.styleFrom(
                  backgroundColor: _ink,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 38),
                  padding: const EdgeInsets.symmetric(horizontal: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: const Text(
                  'Ver perfil',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DriverCardLoading extends StatelessWidget {
  const _DriverCardLoading();

  @override
  Widget build(BuildContext context) => Container(
    height: 210,
    decoration: BoxDecoration(
      color: const Color(0xFFA6FF78),
      borderRadius: BorderRadius.circular(20),
    ),
    child: const Center(child: CircularProgressIndicator(color: _ink)),
  );
}

class _DriverCardError extends StatelessWidget {
  const _DriverCardError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: const Color(0xFFA6FF78),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      children: [
        const Expanded(
          child: Text(
            'Não foi possível carregar os dados do entregador.',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded)),
      ],
    ),
  );
}

class _OperationalDashboard extends StatelessWidget {
  const _OperationalDashboard({required this.result});

  final PagedResult<OrderListItem> result;

  @override
  Widget build(BuildContext context) {
    final delivered = result.items
        .where((item) => item.status == 'delivered')
        .length;
    final inProgress = result.items
        .where(
          (item) =>
              const {'released', 'out_for_delivery'}.contains(item.status),
        )
        .length;
    final issues = result.items
        .where(
          (item) => const {
            'partially_delivered',
            'delivery_failed',
            'returned',
            'cancelled',
          }.contains(item.status),
        )
        .length;
    final totalWeight = result.items.fold<int>(
      0,
      (sum, item) => sum + item.weightGrams,
    );
    final progress = result.items.isEmpty
        ? 0.0
        : delivered / result.items.length;

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE8E5DC)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'PEDIDOS REGISTRADOS',
                style: TextStyle(
                  color: _muted,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                '${result.count}',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 31,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 15),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: const Color(0xFFEAEAE6),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF46D13D)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${(progress * 100).round()}% concluídos na página atual',
                style: const TextStyle(color: _muted, fontSize: 10),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _DashboardMetric(
                label: 'Entregues',
                value: '$delivered',
                icon: Icons.check_circle_outline_rounded,
                color: const Color(0xFFB9EDCE),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _DashboardMetric(
                label: 'Em andamento',
                value: '$inProgress',
                icon: Icons.local_shipping_outlined,
                color: const Color(0xFFC9D5FF),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _DashboardMetric(
                label: 'Ocorrências',
                value: '$issues',
                icon: Icons.warning_amber_rounded,
                color: const Color(0xFFFFD1CC),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _DashboardMetric(
                label: 'Peso carregado',
                value: '${(totalWeight / 1000).toStringAsFixed(1)} kg',
                icon: Icons.scale_outlined,
                color: const Color(0xFFE8E5DC),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DashboardMetric extends StatelessWidget {
  const _DashboardMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 19),
          ),
          const SizedBox(height: 12),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: _muted, fontSize: 9.5)),
        ],
      ),
    );
  }
}

class _DashboardLoading extends StatelessWidget {
  const _DashboardLoading();

  @override
  Widget build(BuildContext context) => Container(
    height: 180,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(23),
    ),
    child: const Center(child: CircularProgressIndicator(color: _ink)),
  );
}

class _DashboardError extends StatelessWidget {
  const _DashboardError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(23),
    ),
    child: Column(
      children: [
        const Icon(Icons.cloud_off_rounded, color: _muted, size: 34),
        const SizedBox(height: 8),
        const Text(
          'Não foi possível carregar os indicadores.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: onRetry,
          child: const Text('Tentar novamente'),
        ),
      ],
    ),
  );
}

class _ActiveWaveCard extends StatelessWidget {
  const _ActiveWaveCard({required this.wave, required this.onTap});

  final ActiveWave wave;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.all(17),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE8E5DC)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                      color: Color(0xFF43D13C),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'EM OPERAÇÃO',
                    style: TextStyle(
                      color: _muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.3,
                    ),
                  ),
                  const Spacer(),
                  _StatusBadge(status: wave.status),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                'Wave #${wave.waveId}',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 27,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                wave.routeNumber,
                style: const TextStyle(color: _muted, fontSize: 13),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: _WaveMetric(
                      label: 'DISTÂNCIA',
                      value: _distanceLabel(wave.plannedDistanceMeters),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _WaveMetric(
                      label: 'DURAÇÃO',
                      value: _durationLabel(wave.plannedDurationSeconds),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _WaveMetric(
                      label: 'INÍCIO',
                      value: _timeLabel(wave.plannedStart),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _distanceLabel(int meters) {
    if (meters <= 0) return '—';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String _durationLabel(int seconds) {
    if (seconds <= 0) return '—';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    return hours > 0 ? '${hours}h ${minutes}m' : '$minutes min';
  }

  String _timeLabel(DateTime? date) {
    if (date == null) return '—';
    final local = date.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      'started' => 'Iniciada',
      'accepted' => 'Aceita',
      _ => 'Liberada',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFC9F5C7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: _ink,
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _WaveMetric extends StatelessWidget {
  const _WaveMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F2EE),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: _muted, fontSize: 8)),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _ink,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyWaveCard extends StatelessWidget {
  const _EmptyWaveCard({
    required this.icon,
    required this.title,
    required this.message,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(25, 38, 25, 32),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(27),
        border: Border.all(color: const Color(0xFFE8E5DC)),
      ),
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: const BoxDecoration(
              color: _yellow,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: _ink, size: 28),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 12, height: 1.4),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 18),
            FilledButton(
              onPressed: onRetry,
              style: FilledButton.styleFrom(backgroundColor: _ink),
              child: const Text('Tentar novamente'),
            ),
          ],
        ],
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 160,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE8E5DC)),
      ),
      child: const Center(
        child: CircularProgressIndicator(color: Color(0xFF46D13D)),
      ),
    );
  }
}
