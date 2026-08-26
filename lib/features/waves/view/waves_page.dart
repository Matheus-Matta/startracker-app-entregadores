import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/async/debouncer.dart';
import '../../../core/network/paged_result.dart';
import '../../../core/realtime/fleet_realtime_channel.dart';
import '../data/wave_service.dart';
import 'wave_detail_page.dart';

class WavesPage extends StatefulWidget {
  const WavesPage({this.isActive = true, this.onOpenHome, super.key});

  final bool isActive;
  final VoidCallback? onOpenHome;

  @override
  State<WavesPage> createState() => _WavesPageState();
}

class _WavesPageState extends State<WavesPage> {
  final _searchController = TextEditingController();
  late final WaveService _service;
  late Future<PagedResult<WaveListItem>> _result;
  int _page = 1;
  String _status = '';
  StreamSubscription<FleetRealtimeEvent>? _realtimeSubscription;
  final Debouncer _realtimeDebouncer = Debouncer(
    const Duration(milliseconds: 250),
  );
  bool _realtimeDirty = false;

  static const _statuses = <String, String>{
    '': 'Todos os status',
    'collecting': 'Em montagem',
    'ready': 'Pronta',
    'optimizing': 'Roteirizando',
    'planned': 'Planejada',
    'released': 'Liberada',
    'accepted': 'Aceita',
    'started': 'Iniciada',
    'completed': 'Concluída',
    'partially_completed': 'Parcialmente concluída',
    'closed': 'Encerrada',
    'cancelled': 'Cancelada',
    'failed': 'Falhou',
  };

  @override
  void initState() {
    super.initState();
    _service = AppDependencies.instance.waves;
    _result = _load();
    _realtimeSubscription = FleetRealtimeChannel.instance.events.listen((
      event,
    ) {
      if (event.isConnected || event.isOrderChange || event.isRouteChange) {
        _service.invalidateCache();
        _realtimeDirty = true;
        if (widget.isActive) _scheduleRealtimeReload();
      }
    });
  }

  @override
  void didUpdateWidget(covariant WavesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive && _realtimeDirty) {
      _scheduleRealtimeReload();
    }
  }

  @override
  void dispose() {
    _realtimeDebouncer.dispose();
    _realtimeSubscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<PagedResult<WaveListItem>> _load({bool refresh = false}) =>
      _service.getWaves(
        page: _page,
        search: _searchController.text,
        status: _status,
        refresh: refresh,
      );

  void _scheduleRealtimeReload() {
    _realtimeDebouncer.run(() {
      if (!mounted || !widget.isActive || !_realtimeDirty) return;
      _realtimeDirty = false;
      unawaited(_reload());
    });
  }

  Future<void> _reload({bool firstPage = false, bool refresh = false}) async {
    if (firstPage) _page = 1;
    if (refresh) _service.invalidateCache();
    final nextResult = _load(refresh: refresh);
    setState(() {
      _result = nextResult;
    });
    try {
      await nextResult;
    } catch (_) {
      // O FutureBuilder apresenta o erro e mantém a ação de tentar novamente.
    }
  }

  Future<void> _openDetails(WaveListItem wave) async {
    final openHome = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => WaveDetailPage(wave: wave)),
    );
    if (!mounted) return;
    await _reload();
    if (openHome == true) widget.onOpenHome?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Filters(
          controller: _searchController,
          hint: 'Buscar carga ou rota',
          status: _status,
          statuses: _statuses,
          onSearch: () => _reload(firstPage: true),
          onStatusChanged: (value) {
            _status = value;
            _reload(firstPage: true);
          },
        ),
        Expanded(
          child: FutureBuilder<PagedResult<WaveListItem>>(
            future: _result,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return _Message(
                  icon: Icons.cloud_off_rounded,
                  title: 'Não foi possível carregar as cargas',
                  onRetry: () => _reload(refresh: true),
                );
              }
              final result = snapshot.data!;
              return RefreshIndicator(
                onRefresh: () => _reload(refresh: true),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
                  children: [
                    _ResultCount(
                      count: result.items.length,
                      label: 'cargas nesta página',
                    ),
                    const SizedBox(height: 10),
                    if (result.items.isEmpty)
                      const _Message(
                        icon: Icons.view_timeline_outlined,
                        title: 'Nenhuma carga encontrada',
                      )
                    else
                      ...result.items.map(
                        (wave) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _WaveCard(
                            wave: wave,
                            onTap: () => _openDetails(wave),
                          ),
                        ),
                      ),
                    _Pagination(
                      page: result.page,
                      hasPrevious: result.hasPrevious,
                      hasNext: result.hasNext,
                      onPrevious: () {
                        _page--;
                        _reload();
                      },
                      onNext: () {
                        _page++;
                        _reload();
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _WaveCard extends StatelessWidget {
  const _WaveCard({required this.wave, required this.onTap});
  final WaveListItem wave;
  final VoidCallback onTap;

  bool get _isInactive => const {
    'completed',
    'partially_completed',
    'closed',
    'cancelled',
    'superseded',
  }.contains(wave.status);

  @override
  Widget build(BuildContext context) {
    final statusStyle = _WaveStatusStyle.forStatus(wave.status);
    return Opacity(
      opacity: _isInactive ? 0.85 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(21),
          child: Ink(
            padding: const EdgeInsets.all(17),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(21),
              border: Border.all(
                color: statusStyle.foreground.withValues(alpha: .28),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: statusStyle.background,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(statusStyle.icon, color: statusStyle.foreground),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Carga #${wave.waveId}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        wave.routeNumber,
                        style: const TextStyle(
                          color: Color(0xFF858279),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 7,
                        runSpacing: 6,
                        children: [
                          _Chip(
                            label: _statusLabel(wave.status),
                            backgroundColor: statusStyle.background,
                            foregroundColor: statusStyle.foreground,
                          ),
                          if (wave.plannedDistanceMeters > 0)
                            _Chip(
                              label:
                                  '${(wave.plannedDistanceMeters / 1000).toStringAsFixed(1)} km',
                            ),
                          if (wave.plannedStart != null)
                            _Chip(label: _dateLabel(wave.plannedStart!)),
                        ],
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFFAAA79F),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _statusLabel(String status) =>
      _WavesPageState._statuses[status] ?? status;

  String _dateLabel(DateTime date) {
    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.controller,
    required this.hint,
    required this.status,
    required this.statuses,
    required this.onSearch,
    required this.onStatusChanged,
  });
  final TextEditingController controller;
  final String hint;
  final String status;
  final Map<String, String> statuses;
  final VoidCallback onSearch;
  final ValueChanged<String> onStatusChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
    child: Column(
      children: [
        TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => onSearch(),
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: IconButton(
              onPressed: onSearch,
              icon: const Icon(Icons.arrow_forward_rounded),
            ),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(17),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 9),
        DropdownButtonFormField<String>(
          initialValue: status,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.filter_alt_outlined),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(17),
              borderSide: BorderSide.none,
            ),
          ),
          items: statuses.entries
              .map(
                (entry) => DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value),
                ),
              )
              .toList(),
          onChanged: (value) => onStatusChanged(value ?? ''),
        ),
      ],
    ),
  );
}

class _ResultCount extends StatelessWidget {
  const _ResultCount({required this.count, required this.label});
  final int count;
  final String label;
  @override
  Widget build(BuildContext context) => Text(
    '$count $label',
    style: const TextStyle(
      color: Color(0xFF858279),
      fontSize: 11,
      fontWeight: FontWeight.w700,
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    this.backgroundColor = const Color(0xFFF1EFE8),
    this.foregroundColor = const Color(0xFF171713),
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: foregroundColor,
        fontSize: 9,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _WaveStatusStyle {
  const _WaveStatusStyle({
    required this.background,
    required this.foreground,
    required this.icon,
  });

  final Color background;
  final Color foreground;
  final IconData icon;

  factory _WaveStatusStyle.forStatus(String status) => switch (status) {
    'collecting' => const _WaveStatusStyle(
      background: Color(0xFFFFF1C7),
      foreground: Color(0xFF8A5A00),
      icon: Icons.inventory_2_outlined,
    ),
    'ready' => const _WaveStatusStyle(
      background: Color(0xFFFFE2B8),
      foreground: Color(0xFF9A4D00),
      icon: Icons.local_shipping_outlined,
    ),
    'optimizing' => const _WaveStatusStyle(
      background: Color(0xFFEDE4FF),
      foreground: Color(0xFF6936B7),
      icon: Icons.route_rounded,
    ),
    'planned' => const _WaveStatusStyle(
      background: Color(0xFFE6EDFA),
      foreground: Color(0xFF3A5A8A),
      icon: Icons.event_available_rounded,
    ),
    'released' => const _WaveStatusStyle(
      background: Color(0xFFDDF6F4),
      foreground: Color(0xFF14756F),
      icon: Icons.lock_open_rounded,
    ),
    'accepted' => const _WaveStatusStyle(
      background: Color(0xFFDDEBFF),
      foreground: Color(0xFF1859A9),
      icon: Icons.assignment_turned_in_outlined,
    ),
    'started' => const _WaveStatusStyle(
      background: Color(0xFFDDF5E5),
      foreground: Color(0xFF15753C),
      icon: Icons.navigation_rounded,
    ),
    'completed' => const _WaveStatusStyle(
      background: Color(0xFFDDF3DF),
      foreground: Color(0xFF24723A),
      icon: Icons.check_circle_rounded,
    ),
    'partially_completed' => const _WaveStatusStyle(
      background: Color(0xFFFFE8C9),
      foreground: Color(0xFF925300),
      icon: Icons.pending_actions_rounded,
    ),
    'closed' => const _WaveStatusStyle(
      background: Color(0xFFE8E9EC),
      foreground: Color(0xFF555B66),
      icon: Icons.archive_rounded,
    ),
    'cancelled' => const _WaveStatusStyle(
      background: Color(0xFFFFE0E0),
      foreground: Color(0xFFA52424),
      icon: Icons.cancel_rounded,
    ),
    'failed' => const _WaveStatusStyle(
      background: Color(0xFFFFDADA),
      foreground: Color(0xFF8E1717),
      icon: Icons.error_rounded,
    ),
    'superseded' => const _WaveStatusStyle(
      background: Color(0xFFE9E9E7),
      foreground: Color(0xFF66645E),
      icon: Icons.swap_horiz_rounded,
    ),
    _ => const _WaveStatusStyle(
      background: Color(0xFFF1EFE8),
      foreground: Color(0xFF5E5A52),
      icon: Icons.route_rounded,
    ),
  };
}

class _Pagination extends StatelessWidget {
  const _Pagination({
    required this.page,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
  });
  final int page;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: hasPrevious ? onPrevious : null,
            icon: const Icon(Icons.chevron_left),
            label: const Text('Anterior'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            'Página $page',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: hasNext ? onNext : null,
            iconAlignment: IconAlignment.end,
            icon: const Icon(Icons.chevron_right),
            label: const Text('Próxima'),
          ),
        ),
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, this.onRetry});
  final IconData icon;
  final String title;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 55),
    child: Column(
      children: [
        Icon(icon, size: 46, color: const Color(0xFF858279)),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        if (onRetry != null) ...[
          const SizedBox(height: 14),
          FilledButton(
            onPressed: onRetry,
            child: const Text('Tentar novamente'),
          ),
        ],
      ],
    ),
  );
}
