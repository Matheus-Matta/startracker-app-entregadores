import '../network/offline_request_queue.dart';

/// Rotas e pedidos em que o próprio entregador acabou de agir.
///
/// Cada baixa/falha faz o servidor recalcular o trajeto e avisar "rota
/// atualizada" (e "rota removida" na última parada); sem este filtro o
/// celular notificava o entregador das próprias ações a cada entrega. Os
/// avisos de mudanças feitas pelo portal continuam aparecendo.
class OwnActivityFilter {
  OwnActivityFilter({
    this.quietFor = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration quietFor;
  final DateTime Function() _clock;
  final Map<String, DateTime> _recent = {};

  /// Ação na fila (já sabe o pedido) ou confirmada (traz rota e pedido).
  void record(OfflineQueueEvent event) {
    if (event.type == OfflineQueueEventType.rejected) return;
    final fields = event.payload['fields'];
    if (fields is Map) {
      _mark('order', fields['order_id']);
      _mark('route', fields['route_id']);
    }
    final result = event.result;
    if (result is Map) {
      for (final kind in const ['route', 'order']) {
        final item = result[kind];
        if (item is Map) _mark(kind, item['id']);
      }
    }
  }

  /// `true` se o aviso sobre este recurso é eco de uma ação do entregador.
  bool isOwn(String kind, int? id) {
    if (id == null) return false;
    final until = _recent['$kind:$id'];
    if (until == null) return false;
    if (_clock().isAfter(until)) {
      _recent.remove('$kind:$id');
      return false;
    }
    return true;
  }

  void clear() => _recent.clear();

  void _mark(String kind, Object? rawId) {
    final id = switch (rawId) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value),
      _ => null,
    };
    if (id == null) return;
    final now = _clock();
    _recent.removeWhere((_, until) => now.isAfter(until));
    _recent['$kind:$id'] = now.add(quietFor);
  }
}
