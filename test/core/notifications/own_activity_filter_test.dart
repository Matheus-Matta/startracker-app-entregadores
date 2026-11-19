import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/offline_request_queue.dart';
import 'package:star_tracker/core/notifications/own_activity_filter.dart';

void main() {
  var now = DateTime(2026, 11, 18, 10);
  late OwnActivityFilter filter;

  setUp(() {
    now = DateTime(2026, 11, 18, 10);
    filter = OwnActivityFilter(clock: () => now);
  });

  OfflineQueueEvent event(
    OfflineQueueEventType type, {
    Map<String, dynamic> fields = const {},
    Object? result,
  }) => OfflineQueueEvent(
    type: type,
    resourceKey: 'stop:31',
    description: 'Finalizar entrega',
    requestType: 'mobile_sync.event',
    payload: {'kind': 'stop.complete', 'fields': fields},
    result: result,
  );

  test('baixa do próprio entregador não vira "rota atualizada" nem '
      '"pedido atualizado"', () {
    filter.record(
      event(
        OfflineQueueEventType.queued,
        fields: {'stop_id': 31, 'order_id': 81},
      ),
    );
    // O aviso do servidor pode chegar antes da resposta: o pedido já conta.
    expect(filter.isOwn('order', 81), isTrue);
    filter.record(
      event(
        OfflineQueueEventType.delivered,
        result: {
          'route': {'id': 20, 'status': 'started'},
          'order': {'id': 81, 'status': 'delivered'},
        },
      ),
    );
    expect(filter.isOwn('route', 20), isTrue);
  });

  test('mudança do portal em outra rota ou pedido continua avisando', () {
    filter.record(
      event(
        OfflineQueueEventType.delivered,
        result: {
          'route': {'id': 20},
          'order': {'id': 81},
        },
      ),
    );
    expect(filter.isOwn('route', 21), isFalse);
    expect(filter.isOwn('order', 82), isFalse);
    expect(filter.isOwn('route', null), isFalse);
  });

  test('passado o intervalo, a mesma rota volta a avisar', () {
    filter.record(
      event(
        OfflineQueueEventType.delivered,
        result: {
          'route': {'id': 20},
        },
      ),
    );
    now = now.add(const Duration(minutes: 3));
    expect(filter.isOwn('route', 20), isFalse);
  });

  test('ação recusada não silencia nada', () {
    filter.record(
      event(OfflineQueueEventType.rejected, fields: {'order_id': 81}),
    );
    expect(filter.isOwn('order', 81), isFalse);
  });
}
