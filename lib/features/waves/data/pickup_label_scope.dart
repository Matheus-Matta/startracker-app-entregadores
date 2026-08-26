/// Granularidade da etiqueta impressa para a conferencia de retirada.
///
/// A API sempre valida um codigo por volume (`POST waves/{id}/retirada/`). O
/// escopo diz quantos volumes uma unica etiqueta representa no armazem: ao ler
/// uma etiqueta de item ou de pedido, o aplicativo confirma de uma vez todos os
/// volumes que ela cobre.
enum PickupLabelScope {
  volume(
    storageValue: 'volume',
    label: 'Etiqueta por volume',
    shortLabel: 'Volume',
    description: 'Cada etiqueta confere um volume do pedido.',
  ),
  item(
    storageValue: 'item',
    label: 'Etiqueta por item',
    shortLabel: 'Item',
    description: 'Uma etiqueta confere todos os volumes do item.',
  ),
  order(
    storageValue: 'order',
    label: 'Etiqueta por pedido',
    shortLabel: 'Pedido',
    description: 'Uma etiqueta confere todos os volumes do pedido.',
  );

  const PickupLabelScope({
    required this.storageValue,
    required this.label,
    required this.shortLabel,
    required this.description,
  });

  final String storageValue;
  final String label;
  final String shortLabel;
  final String description;

  static const fallback = PickupLabelScope.volume;

  static PickupLabelScope fromStorage(String? value) {
    for (final scope in PickupLabelScope.values) {
      if (scope.storageValue == value) return scope;
    }
    return fallback;
  }
}
