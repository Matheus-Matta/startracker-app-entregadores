import '../../../core/sync/mobile_sync.dart';

/// Chave de comparação da etiqueta, igual à do servidor
/// (`pickup._match`: ignora caixa e todo espaço, inclusive interno).
String pickupMatchKey(String code) =>
    code.toUpperCase().replaceAll(RegExp(r'\s'), '');

/// Leitura aceita pelas regras da conferência.
class PickupMatch {
  const PickupMatch({required this.orderId, required this.code});

  final int orderId;
  final String code;
}

/// Valida a leitura com a cópia local, com as mesmas regras e mensagens de
/// `pickup.register_pickup`. Devolve a mensagem de recusa ou o pedido/código.
({PickupMatch? match, String? refusal}) matchPickupCode(
  Map<String, dynamic> raw,
  String scanned,
) {
  final code = scanned.trim();
  if (code.isEmpty) {
    return (match: null, refusal: 'Informe o código da etiqueta.');
  }
  final wanted = pickupMatchKey(code);
  for (final order in _orders(raw)) {
    for (final label in _codes(order)) {
      final candidate = label['code']?.toString() ?? '';
      if (pickupMatchKey(candidate) != wanted) continue;
      if ((order['picked_up_at']?.toString() ?? '').isNotEmpty) {
        return (
          match: null,
          refusal: 'O pedido ${order['order_number']} já havia sido retirado.',
        );
      }
      if ((label['scanned_at']?.toString() ?? '').isNotEmpty) {
        return (
          match: null,
          refusal: 'A etiqueta $candidate já havia sido lida.',
        );
      }
      return (
        match: PickupMatch(
          orderId: _asInt(order['order_id']) ?? 0,
          code: candidate,
        ),
        refusal: null,
      );
    }
  }
  return (
    match: null,
    refusal: 'Nenhum pedido desta carga corresponde ao código $code.',
  );
}

/// Cópia da conferência com as leituras e "não vai" ainda não enviados.
Map<String, dynamic> applyLocalPickup(
  Map<String, dynamic> raw,
  int waveId,
  Iterable<PendingSyncEvent> events,
) {
  final copy = _deepCopy(raw);
  // Etiqueta → pedido, montado uma vez: buscar em todos os pedidos a cada
  // leitura pendente crescia com o quadrado (300 leituras numa carga de 300
  // pedidos: cada bipe ia de 36 para 126 ms no fim da conferência).
  Map<String, (Map<String, dynamic>, Map<String, dynamic>)>? index;
  for (final event in events) {
    if (event.intField('wave_id') != waveId) continue;
    if (event.kind == SyncKind.pickupScan) {
      index ??= _labelIndex(copy);
      final found =
          index[pickupMatchKey(event.fields['code']?.toString() ?? '')];
      if (found != null) _markScanned(found.$1, found.$2, event.occurredAt);
    } else if (event.kind == SyncKind.pickupNotGoing) {
      removePickupOrder(copy, event.intField('order_id'));
    }
  }
  if (copy['orders'] is List) _recount(copy);
  return copy;
}

/// Primeira ocorrência de cada etiqueta, como em [markPickupScanned].
Map<String, (Map<String, dynamic>, Map<String, dynamic>)> _labelIndex(
  Map<String, dynamic> raw,
) {
  final index = <String, (Map<String, dynamic>, Map<String, dynamic>)>{};
  for (final order in _orders(raw)) {
    for (final label in _codes(order)) {
      index.putIfAbsent(
        pickupMatchKey('${label['code']}'),
        () => (order, label),
      );
    }
  }
  return index;
}

void _markScanned(
  Map<String, dynamic> order,
  Map<String, dynamic> label,
  DateTime at,
) {
  final stamp = at.toUtc().toIso8601String();
  if ((label['scanned_at']?.toString() ?? '').isEmpty) {
    label['scanned_at'] = stamp;
  }
  final allRead = _codes(
    order,
  ).every((item) => (item['scanned_at']?.toString() ?? '').isNotEmpty);
  if (allRead && (order['picked_up_at']?.toString() ?? '').isEmpty) {
    order['picked_up_at'] = stamp;
  }
}

/// Marca a etiqueta como lida; com todas lidas, o pedido sai da prateleira.
void markPickupScanned(Map<String, dynamic> raw, String code, DateTime at) {
  final wanted = pickupMatchKey(code);
  for (final order in _orders(raw)) {
    final codes = _codes(order);
    final label = codes
        .where((item) => pickupMatchKey('${item['code']}') == wanted)
        .firstOrNull;
    if (label == null) continue;
    _markScanned(order, label, at);
    break;
  }
  _recount(raw);
}

void removePickupOrder(Map<String, dynamic> raw, int? orderId) {
  final orders = raw['orders'];
  if (orders is List) {
    orders.removeWhere(
      (order) => order is Map && _asInt(order['order_id']) == orderId,
    );
  }
  _recount(raw);
}

/// `pickup.pickup_progress`.
void _recount(Map<String, dynamic> raw) {
  final orders = _orders(raw).toList();
  final done = orders
      .where((order) => (order['picked_up_at']?.toString() ?? '').isNotEmpty)
      .length;
  raw['total'] = orders.length;
  raw['picked_up'] = done;
  raw['pending'] = orders.length - done;
  raw['is_complete'] = orders.isNotEmpty && done == orders.length;
}

Iterable<Map<String, dynamic>> _orders(Map<String, dynamic> raw) {
  final orders = raw['orders'];
  return orders is List
      ? orders.whereType<Map<String, dynamic>>()
      : const <Map<String, dynamic>>[];
}

List<Map<String, dynamic>> _codes(Map<String, dynamic> order) {
  final codes = order['codes'];
  return codes is List
      ? codes.whereType<Map<String, dynamic>>().toList()
      : const <Map<String, dynamic>>[];
}

dynamic _copyValue(dynamic value) => switch (value) {
  Map map => _deepCopy(map),
  List list => [for (final item in list) _copyValue(item)],
  _ => value,
};

Map<String, dynamic> _deepCopy(Map raw) => {
  for (final entry in raw.entries) '${entry.key}': _copyValue(entry.value),
};

int? _asInt(dynamic value) => switch (value) {
  int number => number,
  String text => int.tryParse(text),
  _ => null,
};
