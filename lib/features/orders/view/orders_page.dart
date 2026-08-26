import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/async/debouncer.dart';
import '../../../core/network/paged_result.dart';
import '../../../core/realtime/fleet_realtime_channel.dart';
import '../data/order_service.dart';
import 'order_detail_page.dart';

class OrdersPage extends StatefulWidget {
  const OrdersPage({this.isActive = true, this.onOpenHome, super.key});

  final bool isActive;
  final VoidCallback? onOpenHome;

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  final _searchController = TextEditingController();
  late final OrderService _service;
  late Future<PagedResult<OrderListItem>> _result;
  int _page = 1;
  String _status = '';
  StreamSubscription<FleetRealtimeEvent>? _realtimeSubscription;
  final Debouncer _realtimeDebouncer = Debouncer(
    const Duration(milliseconds: 250),
  );
  bool _realtimeDirty = false;

  static const statuses = <String, String>{
    '': 'Todos os status',
    'created': 'Criado',
    'awaiting_geocode': 'Aguardando geocodificação',
    'outside_delivery_area': 'Fora da área',
    'waiting_wave': 'Aguardando carga',
    'ready_for_routing': 'Pronto para roteirização',
    'routing': 'Roteirizando',
    'awaiting_pickup': 'Aguardando retirada',
    'routed': 'Roteirizado',
    'released': 'Liberado',
    'out_for_delivery': 'Em entrega',
    'delivered': 'Entregue',
    'partially_delivered': 'Parcialmente entregue',
    'delivery_failed': 'Falha na entrega',
    'routing_failed': 'Falha na roteirização',
    'returned': 'Devolvido',
    'cancelled': 'Cancelado',
    'manual_assignment': 'Roteirização manual',
  };

  @override
  void initState() {
    super.initState();
    _service = AppDependencies.instance.orders;
    _result = _load();
    _realtimeSubscription = FleetRealtimeChannel.instance.events.listen((
      event,
    ) {
      if (event.isConnected || event.isOrderChange) {
        _service.invalidateCache();
        _realtimeDirty = true;
        if (widget.isActive) _scheduleRealtimeReload();
      }
    });
  }

  @override
  void didUpdateWidget(covariant OrdersPage oldWidget) {
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

  Future<PagedResult<OrderListItem>> _load() => _service.getOrders(
    page: _page,
    search: _searchController.text,
    status: _status,
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
    final nextResult = _service.getOrders(
      page: _page,
      search: _searchController.text,
      status: _status,
      refresh: refresh,
    );
    setState(() {
      _result = nextResult;
    });
    try {
      await nextResult;
    } catch (_) {
      // O FutureBuilder apresenta o erro e mantém a ação de tentar novamente.
    }
  }

  Future<void> _openDetails(OrderListItem order) async {
    final openHome = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) =>
            OrderDetailPage(orderId: order.id, initialNumber: order.number),
      ),
    );
    if (!mounted) return;
    await _reload();
    if (openHome == true) widget.onOpenHome?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
          child: Column(
            children: [
              TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _reload(firstPage: true),
                decoration: InputDecoration(
                  hintText: 'Buscar pedido ou cliente',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: IconButton(
                    onPressed: () => _reload(firstPage: true),
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
                initialValue: _status,
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
                onChanged: (value) {
                  _status = value ?? '';
                  _reload(firstPage: true);
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<PagedResult<OrderListItem>>(
            future: _result,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return _OrdersMessage(
                  icon: Icons.cloud_off_rounded,
                  title: 'Não foi possível carregar os pedidos',
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
                    Text(
                      _status.isEmpty && _searchController.text.trim().isEmpty
                          ? '${result.count} pedidos encontrados'
                          : '${result.items.length} pedidos filtrados nesta página',
                      style: const TextStyle(
                        color: Color(0xFF858279),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (result.items.isEmpty)
                      const _OrdersMessage(
                        icon: Icons.inventory_2_outlined,
                        title: 'Nenhum pedido encontrado',
                      )
                    else
                      ...result.items.map(
                        (order) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _OrderCard(
                            order: order,
                            onTap: () => _openDetails(order),
                          ),
                        ),
                      ),
                    _OrdersPagination(
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

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.onTap});
  final OrderListItem order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(21),
      child: Container(
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: const Color(0xFFE8E5DC)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFFF8E94E),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.inventory_2_outlined, size: 21),
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
                          order.number,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      _OrderStatus(status: order.status),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    order.customerName,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [order.address, '${order.city}/${order.state}']
                        .where((part) => part.replaceAll('/', '').isNotEmpty)
                        .join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF858279),
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${order.units} un. · ${(order.weightGrams / 1000).toStringAsFixed(1)} kg'
                    '${order.priority > 0 ? ' · Prioridade ${order.priority}' : ''}',
                    style: const TextStyle(
                      color: Color(0xFF858279),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderStatus extends StatelessWidget {
  const _OrderStatus({required this.status});
  final String status;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xFFF1EFE8),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      _OrdersPageState.statuses[status] ?? status,
      style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w800),
    ),
  );
}

class _OrdersPagination extends StatelessWidget {
  const _OrdersPagination({
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
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: OutlinedButton(
          onPressed: hasPrevious ? onPrevious : null,
          child: const Text('Anterior'),
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
        child: OutlinedButton(
          onPressed: hasNext ? onNext : null,
          child: const Text('Próxima'),
        ),
      ),
    ],
  );
}

class _OrdersMessage extends StatelessWidget {
  const _OrdersMessage({required this.icon, required this.title, this.onRetry});
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
