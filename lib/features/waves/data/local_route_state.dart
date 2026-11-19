import '../../../core/sync/mobile_sync.dart';
import 'active_route_service.dart';

/// Status de rota em que o entregador ainda pode registrar ações.
const liveRouteStatuses = {'planned', 'released', 'accepted', 'started'};

/// Status de pedido que ainda está numa rota por fazer.
const openRouteOrderStatuses = {
  'routed',
  'released',
  'awaiting_pickup',
  'out_for_delivery',
};

/// Aplica sobre a última cópia do servidor as ações ainda não enviadas.
///
/// Espelha as regras do servidor (`execution.py`, `stop_arrival.py`,
/// `stop_sequencing.py`, `route_completion.py`) para a tela mostrar sem rede
/// o mesmo que o portal vai mostrar depois da sincronização:
/// * chegada/início/baixa/falha mudam a parada e o pedido;
/// * sem parada pendente, a rota fecha como concluída (todas entregues) ou
///   parcialmente concluída (alguma falha ou cancelada);
/// * com a rota fechada, a carga fecha como concluída se todo pedido dela foi
///   entregue, ou parcialmente concluída caso contrário.
ActiveRoute applyLocalEvents(
  ActiveRoute route,
  Iterable<PendingSyncEvent> events,
) {
  var status = route.status;
  final stops = [...route.stops];
  final cancelled = [...route.cancelledStops];
  // Posição de cada parada, e uma ordenação só no fim: antes cada ação
  // ordenava a rota inteira (com a fila de um dia sem sinal, a tela do mapa
  // ia de 2 para 20 ms por atualização).
  final positions = {
    for (final (index, stop) in stops.indexed) stop.stopId: index,
  };
  var changed = false;
  for (final event in events) {
    if (event.kind == SyncKind.routeStart) {
      if (event.intField('route_id') == route.routeId &&
          const {'planned', 'released', 'accepted'}.contains(status)) {
        status = 'started';
        changed = true;
      }
      continue;
    }
    final stopId = event.intField('stop_id');
    var index = positions[stopId] ?? -1;
    if (index < 0 &&
        (event.kind == SyncKind.stopComplete ||
            event.kind == SyncKind.stopFail)) {
      // Parada cancelada no portal enquanto o entregador estava sem sinal:
      // o servidor aceita a baixa (o entregador está com o pedido), então
      // ela volta para a tela em vez de sumir.
      final revived = cancelled.indexWhere((stop) => stop.stopId == stopId);
      if (revived >= 0) {
        stops.add(cancelled.removeAt(revived).copyWith(status: 'delivering'));
        index = stops.length - 1;
        positions[stopId!] = index;
      }
    }
    if (index < 0) continue;
    final next = _applyToStop(stops, index, event);
    if (next != null) {
      stops[index] = next;
      changed = true;
    }
  }
  if (!changed) return route;
  stops.sort((a, b) => a.sequence.compareTo(b.sequence));
  var waveStatus = route.waveStatus;
  if (liveRouteStatuses.contains(status) &&
      stops.isNotEmpty &&
      stops.every((stop) => stop.isTerminal)) {
    final allCompleted =
        cancelled.isEmpty && stops.every((stop) => stop.status == 'completed');
    status = allCompleted ? 'completed' : 'partially_completed';
    // `_finish_wave_if_terminal`: a carga só fecha quando todas as rotas
    // dela terminaram. Pedido de outra rota ainda em curso mantém a carga
    // aberta (a tela mostra a rota concluída).
    final otherRouteOpen = route.otherWaveOrderStatuses.any(
      openRouteOrderStatuses.contains,
    );
    if (!otherRouteOpen) {
      final orderStatuses = [
        for (final stop in stops) stop.orderStatus,
        ...route.otherWaveOrderStatuses,
      ];
      waveStatus = orderStatuses.every((value) => value == 'delivered')
          ? 'completed'
          : 'partially_completed';
    }
  }
  return route.copyWith(
    status: status,
    stops: stops,
    waveStatus: waveStatus,
    cancelledStops: cancelled,
  );
}

ActiveRouteStop? _applyToStop(
  List<ActiveRouteStop> stops,
  int index,
  PendingSyncEvent event,
) {
  final stop = stops[index];
  if (stop.isTerminal) return null;
  switch (event.kind) {
    case SyncKind.stopArrive:
      if (!const {'planned', 'approaching', 'arrived'}.contains(stop.status)) {
        return null;
      }
      return stop.copyWith(status: 'arrived');
    case SyncKind.stopBegin:
      if (!const {'arrived', 'approaching'}.contains(stop.status)) return null;
      return stop.copyWith(status: 'delivering');
    case SyncKind.stopPostpone:
      final pending = stops.where((item) => !item.isTerminal).toList();
      if (pending.length < 2) return null;
      final last = pending
          .map((item) => item.sequence)
          .reduce((a, b) => a > b ? a : b);
      return stop.copyWith(status: 'planned', sequence: last + 1);
    case SyncKind.stopComplete:
      return stop.copyWith(
        status: 'completed',
        orderStatus: completedOrderStatus(stop, event.fields['items']),
      );
    case SyncKind.stopFail:
      return stop.copyWith(status: 'failed', orderStatus: 'delivery_failed');
  }
  return null;
}

/// `order_split.resolve_order_completion`: só falhas → pedido falhou; mistura
/// → entregue (o que faltou vira nota nova no servidor).
String completedOrderStatus(ActiveRouteStop stop, Object? rawItems) {
  final items = rawItems is List ? rawItems : const [];
  final pending = stop.contents.where(
    (item) => item.status == 'pending' || item.status == 'failed',
  );
  if (pending.isEmpty || items.isEmpty) return 'delivered';
  final failed = {
    for (final item in items)
      if (item is Map && item['status']?.toString() == 'failed')
        item['id']?.toString(),
  };
  final otherDelivered = stop.contents.any(
    (item) => item.status == 'delivered',
  );
  final anyDelivered =
      otherDelivered ||
      pending.any((item) => !failed.contains(item.id.toString()));
  return anyDelivered ? 'delivered' : 'delivery_failed';
}
