import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/features/orders/data/order_service.dart';

void main() {
  group('OrderService.parseOrderDetails', () {
    test('le observacao, pagamento e origem do desmembro', () {
      final order = OrderService.parseOrderDetails({
        'id': 81,
        'order_number': 'PED-2026-001',
        'customer_name': 'Cliente Exemplo',
        'payment_method': 'pix',
        'payment_value': '249.90',
        'notes': 'Entregar pela portaria dos fundos.',
        'split_from': {'id': 77},
      }, 99);

      expect(order.id, 81);
      expect(order.paymentMethod, 'pix');
      expect(order.paymentValue, 249.90);
      expect(order.hasPayment, isTrue);
      expect(order.notes, 'Entregar pela portaria dos fundos.');
      expect(order.splitFromId, 77);
    });

    test('aceita split_from como id direto', () {
      final order = OrderService.parseOrderDetails({
        'id': 82,
        'split_from': 77,
      }, 82);

      expect(order.splitFromId, 77);
    });

    test('trata pedido sem pagamento nem observacao', () {
      final order = OrderService.parseOrderDetails({
        'id': 83,
        'order_number': 'PED-2026-003',
      }, 83);

      expect(order.paymentMethod, isEmpty);
      expect(order.paymentValue, isNull);
      expect(order.hasPayment, isFalse);
      expect(order.notes, isEmpty);
      expect(order.splitFromId, isNull);
    });

    test('usa a primeira chave preenchida da observacao', () {
      final order = OrderService.parseOrderDetails({
        'id': 84,
        'notes': '   ',
        'observacao': 'Cliente pediu para ligar antes.',
      }, 84);

      expect(order.notes, 'Cliente pediu para ligar antes.');
    });
  });
}
