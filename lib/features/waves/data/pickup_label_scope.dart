/// Granularidade da etiqueta impressa para a conferencia de retirada.
///
/// A API sempre valida um codigo por volume (`POST waves/{id}/retirada/`). O
/// escopo diz quantos volumes uma unica etiqueta representa no armazem: ao ler
/// uma etiqueta de item ou de pedido, o aplicativo confirma de uma vez todos os
/// volumes que ela cobre.
enum PickupLabelScope {
  volume(
    apiValue: 'volume',
    label: 'Etiqueta por volume',
    shortLabel: 'Volume',
    description: 'Cada etiqueta confere um volume do pedido.',
  ),
  item(
    apiValue: 'item',
    label: 'Etiqueta por item',
    shortLabel: 'Item',
    description: 'Uma etiqueta confere todos os volumes do item.',
  ),
  order(
    apiValue: 'order',
    label: 'Etiqueta por pedido',
    shortLabel: 'Pedido',
    description: 'Uma etiqueta confere todos os volumes do pedido.',
  );

  const PickupLabelScope({
    required this.apiValue,
    required this.label,
    required this.shortLabel,
    required this.description,
  });

  final String apiValue;
  final String label;
  final String shortLabel;
  final String description;

  static const fallback = PickupLabelScope.volume;

  /// Interpreta a granularidade definida pela conta na configuracao da API.
  static PickupLabelScope fromConfiguration(Map<String, dynamic> config) {
    return tryFromConfiguration(config) ?? fallback;
  }

  /// Devolve `null` quando o payload nao informa o escopo.
  ///
  /// Aceita as variantes conhecidas do contrato para continuar funcionando
  /// durante a atualizacao entre versoes da API.
  static PickupLabelScope? tryFromConfiguration(Map<String, dynamic> config) {
    dynamic raw;
    for (final key in const [
      'label_scope',
      'pickup_label_scope',
      'label_granularity',
      'pickup_label_granularity',
      'label_print_scope',
    ]) {
      if (config[key] != null) {
        raw = config[key];
        break;
      }
    }
    if (raw is Map) {
      raw = raw['value'] ?? raw['code'] ?? raw['scope'] ?? raw['granularity'];
    }
    if (raw == null) return null;

    final value = raw
        .toString()
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s-]+'), '_')
        .replaceAll('ç', 'c');
    return switch (value) {
      'volume' ||
      'per_volume' ||
      'by_volume' ||
      'one_per_volume' ||
      'por_volume' => PickupLabelScope.volume,
      'item' ||
      'per_item' ||
      'by_item' ||
      'one_per_item' ||
      'por_item' => PickupLabelScope.item,
      'order' ||
      'pedido' ||
      'per_order' ||
      'by_order' ||
      'one_per_order' ||
      'por_pedido' => PickupLabelScope.order,
      _ => null,
    };
  }
}
