import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/features/waves/data/delivery_photo_recovery.dart';

void main() {
  test('preserva o rascunho da entrega durante a abertura da camera', () {
    final original = PendingDeliveryDraft(
      routeId: 25,
      stopId: 81,
      recipientName: 'Maria',
      recipientDocument: '123',
      notes: 'Portaria',
      items: const [
        DeliveryDraftItem(id: 9, status: 'delivered', reason: '', notes: ''),
      ],
      signatureBytes: Uint8List.fromList([1, 2, 3]),
    );

    final restored = PendingDeliveryDraft.fromJson(original.toJson());

    expect(restored.routeId, 25);
    expect(restored.stopId, 81);
    expect(restored.recipientName, 'Maria');
    expect(restored.items.single.status, 'delivered');
    expect(restored.signatureBytes, [1, 2, 3]);
  });
}
