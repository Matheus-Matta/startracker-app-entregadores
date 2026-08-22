import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/paged_result.dart';
import '../../../core/storage/session_storage.dart';
import '../data/wave_service.dart';
import 'wave_detail_page.dart';

class WavesPage extends StatefulWidget {
  const WavesPage({this.onOpenHome, super.key});

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

  static const _statuses = <String, String>{
    '': 'Todos os status',
    'ready': 'Pronta',
    'optimizing': 'Roteirizando',
    'planned': 'Planejada',
    'released': 'Liberada',
    'accepted': 'Aceita',
    'started': 'Iniciada',
    'completed': 'Concluída',
    'partially_completed': 'Parcialmente concluída',
    'cancelled': 'Cancelada',
    'failed': 'Falhou',
  };

  @override
  void initState() {
    super.initState();
    const storage = SessionStorage();
    _service = WaveService(
      ApiClient(baseUrl: AppConfig.backendUrl, storage: storage),
    );
    _result = _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<PagedResult<WaveListItem>> _load() => _service.getWaves(
    page: _page,
    search: _searchController.text,
    status: _status,
  );

  void _reload({bool firstPage = false}) {
    if (firstPage) _page = 1;
    final nextResult = _load();
    setState(() {
      _result = nextResult;
    });
  }

  Future<void> _openDetails(WaveListItem wave) async {
    final openHome = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => WaveDetailPage(wave: wave)),
    );
    if (!mounted) return;
    _reload();
    if (openHome == true) widget.onOpenHome?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Filters(
          controller: _searchController,
          hint: 'Buscar wave ou rota',
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
                  title: 'Não foi possível carregar as waves',
                  onRetry: _reload,
                );
              }
              final result = snapshot.data!;
              return RefreshIndicator(
                onRefresh: () async => _reload(),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
                  children: [
                    _ResultCount(
                      count: result.items.length,
                      label: 'waves nesta página',
                    ),
                    const SizedBox(height: 10),
                    if (result.items.isEmpty)
                      const _Message(
                        icon: Icons.view_timeline_outlined,
                        title: 'Nenhuma wave encontrada',
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
              border: Border.all(color: const Color(0xFFE8E5DC)),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8E94E),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: const Icon(Icons.route_rounded),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Wave #${wave.waveId}',
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
                          _Chip(label: _statusLabel(wave.status)),
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
  const _Chip({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xFFF1EFE8),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700),
    ),
  );
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
